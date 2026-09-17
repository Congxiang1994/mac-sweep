#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# uninstall-residue.sh 回归测试
#
# 全程在 /tmp 下用隔离 HOME 跑真实脚本，绝不触碰真实 ~/Library。
# 用 EXTRA_APP_DIRS 注入一个假 App，验「已装 / 未装」的判定分界。
#
# 断言：
#   1. 未装 App 的残留被报出，且同一软件的散落位置聚合成一组
#   2. 已装 App 的数据目录（按 App 名 / bundle id / helper 子 id 三种形态）不被误报
#   3. 白名单生效：com.apple.* 与 Group Containers 的 team id 剥壳后仍能命中白名单
#         ⭐ 回归点：team id 剥离只允许作用在 Group Containers，
#            早先放在通用位置会把 com.google.Keystone.Agent 剥成 Keystone.Agent，
#            导致整个白名单失效
#   4. Group Containers 的 <teamid>. 前缀被正确剥掉
#   5. 默认模式一个文件都不删
#   6. --clean 走「移入废纸篓」，原位置消失、废纸篓里能找到
#   7. ⭐ C locale 与 UTF-8 locale 行为一致，无 unbound variable
#
# 用法: bash tests/run-tests-uninstall-residue.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/uninstall-residue.sh"

[ -f "${SCRIPT}" ] || { echo "找不到脚本: ${SCRIPT}" >&2; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - $1"; }

has()     { printf '%s' "$2" | grep -qF -- "$1" && ok "$3" || bad "$3（输出中未见: $1）"; }
has_not() { printf '%s' "$2" | grep -qF -- "$1" && bad "$3（不应出现: $1）" || ok "$3"; }
exists()  { [ -e "$1" ] && ok "$2" || bad "$2（已丢失: $1）"; }
gone()    { [ ! -e "$1" ] && ok "$2" || bad "$2（仍存在: $1）"; }

# 造一个假的「已安装 App」，让判定有明确的对照组
make_fake_app() {
  local dir="$1"
  mkdir -p "${dir}/MyApp.app/Contents"
  cat > "${dir}/MyApp.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.example.myapp</string>
  <key>CFBundleName</key><string>MyApp</string>
</dict>
</plist>
PLIST
}

# 在隔离 HOME 下铺一份 fixture
build_fixture() {
  local H="$1"
  mkdir -p "${H}/Library/Application Support" \
           "${H}/Library/Caches" \
           "${H}/Library/Preferences" \
           "${H}/Library/Logs" \
           "${H}/Library/Group Containers"

  # ── 真残留（未装 App 的痕迹）──
  mkdir -p "${H}/Library/Application Support/GhostApp"
  head -c 30000 /dev/zero > "${H}/Library/Application Support/GhostApp/data.bin"
  head -c 8000  /dev/zero > "${H}/Library/Logs/GhostApp.log"
  mkdir -p "${H}/Library/Caches/com.ghost.software"
  head -c 12000 /dev/zero > "${H}/Library/Caches/com.ghost.software/blob"
  printf 'x' > "${H}/Library/Preferences/com.ghost.software.plist"
  mkdir -p "${H}/Library/Group Containers/ABCDE12345.com.ghostwidget.app"
  head -c 6000 /dev/zero > "${H}/Library/Group Containers/ABCDE12345.com.ghostwidget.app/db"

  # ── 已装 App 的数据（三种形态，都不该报）──
  mkdir -p "${H}/Library/Application Support/MyApp"
  head -c 9000 /dev/zero > "${H}/Library/Application Support/MyApp/store.db"
  mkdir -p "${H}/Library/Application Support/MyAppHelper"
  head -c 4000 /dev/zero > "${H}/Library/Application Support/MyAppHelper/log.txt"
  mkdir -p "${H}/Library/Caches/com.example.myapp.helper"
  head -c 7000 /dev/zero > "${H}/Library/Caches/com.example.myapp.helper/blob"

  # ── 白名单（都不该报）──
  printf 'x' > "${H}/Library/Preferences/com.apple.finder.plist"
  printf 'x' > "${H}/Library/Preferences/com.google.Keystone.Agent.plist"
}

run_case() {
  local locale_name="$1" label="$2"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  local T H APPS
  T="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-residue-test.XXXXXX")" || { bad "创建测试目录失败"; return; }
  H="${T}/home"
  APPS="${T}/apps"
  mkdir -p "${H}" "${APPS}"
  make_fake_app "${APPS}"
  build_fixture "${H}"

  local out rc
  # ── 1) 默认模式：只报告 ──
  out="$(HOME="${H}" EXTRA_APP_DIRS="${APPS}" LC_ALL="${locale_name}" \
         /bin/bash "${SCRIPT}" --report "${T}/report.tsv" 2>&1)"
  rc=$?

  [ "${rc}" = "0" ] && ok "退出码为 0" || bad "退出码应为 0，实得 ${rc}"
  if printf '%s' "${out}" | grep -q 'unbound variable'; then
    bad "无 unbound variable 报错"
    printf '%s\n' "${out}" | sed 's/^/      | /'
  else
    ok "无 unbound variable 报错"
  fi

  has "${H}/Library/Application Support/GhostApp" "${out}" "报出未装 App 的数据目录"
  has "${H}/Library/Logs/GhostApp.log"           "${out}" "报出未装 App 的日志（同组聚合）"
  has "${H}/Library/Caches/com.ghost.software"   "${out}" "报出未装 App 的 bundle id 缓存"
  has "com.ghostwidget.app"                      "${out}" "Group Containers 剥掉 team id 后仍被报出"

  has_not "MyApp/store.db"          "${out}" "已装 App 的数据目录不被误报"
  has_not "MyAppHelper"             "${out}" "已装 App 的名字前缀目录不被误报"
  has_not "com.example.myapp"       "${out}" "已装 App 的 helper 子 id 不被误报"
  has_not "com.apple.finder"        "${out}" "白名单 com.apple.* 不被误报"
  has_not "com.google.Keystone"     "${out}" "⭐ team id 剥离不越界（Keystone 仍被白名单挡住）"

  # ── 2) 默认模式必须一个文件都不动 ──
  exists "${H}/Library/Application Support/GhostApp/data.bin" "默认模式不删文件（数据）"
  exists "${H}/Library/Caches/com.ghost.software/blob"        "默认模式不删文件（缓存）"
  exists "${H}/Library/Preferences/com.ghost.software.plist"  "默认模式不删文件（偏好）"

  # ── 3) --clean：全部答 y ──
  printf 'y\ny\ny\ny\ny\ny\n' | HOME="${H}" EXTRA_APP_DIRS="${APPS}" LC_ALL="${locale_name}" \
    /bin/bash "${SCRIPT}" --clean --report "${T}/report2.tsv" >/dev/null 2>&1

  gone "${H}/Library/Application Support/GhostApp"        "清理：数据目录移出原位置"
  gone "${H}/Library/Caches/com.ghost.software"           "清理：缓存目录移出原位置"
  exists "${H}/.Trash/GhostApp"                            "清理：进了废纸篓（可还原）"
  exists "${H}/.Trash/com.ghost.software"                  "清理：缓存进了废纸篓"
  exists "${H}/Library/Application Support/MyApp/store.db" "清理：已装 App 的数据原封不动"
  exists "${H}/Library/Preferences/com.apple.finder.plist" "清理：白名单条目原封不动"

  rm -rf "${T}" 2>/dev/null
}

echo "════════ uninstall-residue 回归测试 ════════"
echo "脚本: ${SCRIPT}"

run_case "C"           "C locale 基线"
run_case "en_US.UTF-8" "UTF-8 locale（终端默认）"

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
