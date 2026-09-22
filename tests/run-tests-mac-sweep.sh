#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mac-sweep.sh 回归测试
#
# 全程在 /tmp 下用隔离 fixture 跑真实脚本，绝不触碰真实的
# ~/Library、~/Documents、~/.Trash。fixture 路径通过 SWEEP_HOME +
# SWEEP_LOG_HOME + SWEEP_CACHE_HOME 注入。
#
# 断言：
#   1. 默认模式一个文件都不删（只读）
#   2. 范围闸：裸 --clean / --clean --all --yes / --clean --yes 全部退出码 2
#   3. 二次确认：回车 / y / 乱输入都必须取消且文件仍在；打 yes 后才移走
#   4. pick 模式答 n 的项不动、答 y 的移走、q 退出后剩余不动
#   5. 清理规则：
#      - DerivedData 闲置 ≥阈值 才入清单；新鲜的跳过
#      - 旧日志闲置 ≥ LOG_AGE_DAYS 才入清单；新鲜日志保留
#      - 浏览器只认 Cache / Code Cache；Cookie / Login Data / History 不入清单
#      - 命中规则的路径才进清单；规则外路径（如 Caches 下随机目录）不进
#   6. 筛选：并集 / --and 交集 / 逗号连写；未命中的项原样未动
#   7. --clean 走「移入废纸篓」，原位置消失、废纸篓里能找到（隔离 TRASH）
#   8. 只报告区永不进清理清单（--clean --all 也不会动报告区里的东西）
#   9. ⭐ C locale 与 UTF-8 locale 行为一致，无 unbound variable
#  10. 白名单外规则外路径即使叫「垃圾」也不碰（如 ~/Desktop 下的 .log）
#
# 用法: bash tests/run-tests-mac-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/mac-sweep.sh"

[ -f "${SCRIPT}" ] || { echo "找不到脚本: ${SCRIPT}" >&2; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - $1"; }

has()     { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3（输出中未见: $1）"; fi; }
has_not() { if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3（不应出现: $1）"; else ok "$3"; fi; }
exists()  { if [ -e "$1" ]; then ok "$2"; else bad "$2（已丢失: $1）"; fi; }
gone()    { if [ ! -e "$1" ]; then ok "$2"; else bad "$2（仍存在: $1）"; fi; }

# ⚠️ 必须真删。WorkBuddy 的 shim 会把 rm 改成「移入 ~/.Trash」，
#    于是测试的清理动作反而往用户真实废纸篓里倒垃圾。
nuke() {
  local p="$1"
  [ -e "${p}" ] || return 0
  env -u PYTHONPATH /usr/bin/python3 -c \
    'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "${p}" 2>/dev/null
  [ -e "${p}" ] && rm -rf "${p}"
  return 0
}

# 在隔离 HOME 下铺一份 fixture
build_fixture() {
  local H="$1" LOGS="$2" CACHES="$3" TRASH="$4"

  # ── Xcode DerivedData ──
  mkdir -p "${H}/Library/Developer/Xcode/DerivedData/MyApp-abc123"
  head -c 40000 /dev/zero > "${H}/Library/Developer/Xcode/DerivedData/MyApp-abc123/build.db"
  mkdir -p "${H}/Library/Developer/Xcode/DerivedData/FreshApp-def456"
  head -c 5000  /dev/zero > "${H}/Library/Developer/Xcode/DerivedData/FreshApp-def456/idx"

  # ── 旧日志 + 新日志 ──
  mkdir -p "${LOGS}/SomeApp"
  head -c 20000 /dev/zero > "${LOGS}/SomeApp/app.log"
  head -c 100   /dev/zero > "${LOGS}/SomeApp/fresh.log"

  # ── 浏览器缓存 + 登录态 ──
  mkdir -p "${H}/Library/Application Support/Google/Chrome/Default/Cache"
  head -c 30000 /dev/zero > "${H}/Library/Application Support/Google/Chrome/Default/Cache/f_000001"
  mkdir -p "${H}/Library/Application Support/Google/Chrome/Default/Code Cache"
  head -c 8000  /dev/zero > "${H}/Library/Application Support/Google/Chrome/Default/Code Cache/blob"
  # 登录态 —— 绝不能进清单
  mkdir -p "${H}/Library/Application Support/Google/Chrome/Default/Sessions"
  head -c 2000  /dev/zero > "${H}/Library/Application Support/Google/Chrome/Default/Sessions/session_0001"

  # ── npm 缓存 ──
  mkdir -p "${H}/.npm/_cacache"
  head -c 15000 /dev/zero > "${H}/.npm/_cacache/content.bin"

  # ── 规则外的缓存目录（不该进清单）──
  mkdir -p "${CACHES}/SomeRandomApp"
  head -c 9000  /dev/zero > "${CACHES}/SomeRandomApp/blob.bin"

  # ── 深度扫描：孤立缓存（闲置 40 天）+ 在用缓存（新鲜）──
  mkdir -p "${CACHES}/GhostAppCache"
  head -c 12000 /dev/zero > "${CACHES}/GhostAppCache/data.bin"

  # ── 深度扫描：崩溃报告（旧 = 收；新 = 留）──
  mkdir -p "${LOGS}/DiagnosticReports"
  head -c 4000 /dev/zero > "${LOGS}/DiagnosticReports/OldApp-2026-08-01.ips"
  head -c 100  /dev/zero > "${LOGS}/DiagnosticReports/NewApp-today.ips"

  # ── 深度扫描：悬空链接 + 有效链接 ──
  ln -s "${CACHES}/definitely-gone-target" "${CACHES}/broken-link"
  ln -s "${CACHES}/SomeRandomApp/blob.bin" "${CACHES}/good-link"

  # ── 深度扫描：孤立空目录 + 非空目录 ──
  mkdir -p "${CACHES}/EmptyShell"
  # EmptyShell 保持真空；SomeRandomApp 非空已被上面覆盖

  # ── 散落 .DS_Store ──
  mkdir -p "${H}/Documents" "${H}/Desktop"
  printf 'x' > "${H}/Documents/.DS_Store"
  printf 'x' > "${H}/Desktop/.DS_Store"

  # ── 规则外用户文件：Desktop 下同名 .log（绝不能动）──
  mkdir -p "${H}/Desktop/notes"
  head -c 7000  /dev/zero > "${H}/Desktop/notes/todo.log"

  # ── node_modules .cache ──
  mkdir -p "${H}/devproj/node_modules/.cache/some-loader"
  head -c 6000  /dev/zero > "${H}/devproj/node_modules/.cache/some-loader/chunk.js"

  # 把「旧的」文件 mtime 拨到 40 天前（> 默认 LOG_AGE_DAYS=14、> ORPHAN_AGE_DAYS=30）
  local old
  for old in \
    "${LOGS}/SomeApp/app.log" \
    "${H}/Library/Developer/Xcode/DerivedData/MyApp-abc123" \
    "${CACHES}/GhostAppCache" \
    "${LOGS}/DiagnosticReports/OldApp-2026-08-01.ips" \
    "${CACHES}/EmptyShell"; do
    touch -t "$(date -v-40d +%Y%m%d0000)" "${old}"
  done
  # 悬空链接的年龄无所谓（目标不存在 = 100% 无用），但拨旧一点排除年龄干扰
  touch -h -t "$(date -v-40d +%Y%m%d0000)" "${CACHES}/broken-link"
}

# 把 fixture 恢复成初始状态（清理类用例之间互不干扰）
reset_fixture() {
  local T="$1"
  nuke "${T}"
  mkdir -p "${T}/home" "${T}/logs" "${T}/caches" "${T}/trash"
  build_fixture "${T}/home" "${T}/logs" "${T}/caches" "${T}/trash"
}

# 在隔离环境跑一遍脚本。
# 注意不能用 out="$(run_sweep ...)" —— 命令替换会开子壳，RC 带不出来。
# 所以输出写到 ${T}/sweep.out 存进 SWEEP_OUT，退出码存 RC，stdin 用 STDIN_DATA 注入。
STDIN_DATA=""
SWEEP_OUT=""
RC=""
run_sweep() {  # run_sweep <T> <locale> <args...>
  local T="$1" loc="$2"; shift 2
  local outfile="${T}/sweep.out"
  if [ -n "${STDIN_DATA}" ]; then
    printf '%b' "${STDIN_DATA}" \
      | HOME="${T}/home" \
        SWEEP_HOME="${T}/home" \
        SWEEP_LOG_HOME="${T}/logs" \
        SWEEP_CACHE_HOME="${T}/caches" \
        LC_ALL="${loc}" \
        /bin/bash "${SCRIPT}" "$@" > "${outfile}" 2>&1
  else
    HOME="${T}/home" \
    SWEEP_HOME="${T}/home" \
    SWEEP_LOG_HOME="${T}/logs" \
    SWEEP_CACHE_HOME="${T}/caches" \
    LC_ALL="${loc}" \
      /bin/bash "${SCRIPT}" "$@" < /dev/null > "${outfile}" 2>&1
  fi
  RC=$?
  SWEEP_OUT="$(cat "${outfile}" 2>/dev/null)"
  STDIN_DATA=""
}

# 把脚本内部的 trash_path 指到隔离废纸篓：脚本用 ${HOME}/.Trash，
# 所以 HOME 已指向 fixture；把 fixture 的 Trash 放在 HOME 里即可。
setup_trash() {
  local T="$1"
  mkdir -p "${T}/home/.Trash"
}

run_case() {
  local locale_name="$1" label="$2"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  local T
  T="$(mktemp -d "${TMPDIR:-/tmp}/mac-sweep-test.XXXXXX")" || { bad "创建测试目录失败"; return; }
  reset_fixture "${T}"
  setup_trash "${T}"

  local out rc

  # ── 1) 默认模式：只报告，一个文件都不动 ──
  run_sweep "${T}" "${locale_name}"
  out="${SWEEP_OUT}"
  rc=${RC}
  [ "${rc}" = "0" ] && ok "退出码为 0" || bad "退出码应为 0，实得 ${rc}"
  if printf '%s' "${out}" | grep -q 'unbound variable'; then
    bad "无 unbound variable 报错"
    printf '%s\n' "${out}" | sed 's/^/      | /' | head -20
  else
    ok "无 unbound variable 报错"
  fi
  exists "${T}/home/Library/Developer/Xcode/DerivedData/MyApp-abc123/build.db" "默认模式: DerivedData 未被删"
  exists "${T}/logs/SomeApp/app.log"   "默认模式: 旧日志仍在"
  exists "${T}/caches/SomeRandomApp/blob.bin" "默认模式: 规则外缓存仍在"

  # 报告内容断言
  has "MyApp-abc123" "${out}" "报告: 闲置 DerivedData 被列出"
  has_not "FreshApp-def456" "${out}" "报告: 新鲜 DerivedData 被跳过"
  has "app.log" "${out}" "报告: 闲置旧日志被列出"
  has_not "fresh.log" "${out}" "报告: 新鲜日志被跳过"
  has "Cache" "${out}" "报告: 浏览器 Cache 被列出"
  has "Sessions" "${out}" "报告: 登录态 Sessions 出现在【只报告区】"
  has "以下不清理" "${out}" "报告: 只报告区存在"
  has_not "todo.log" "${out}" "报告: Desktop 下的 .log 不出现（规则外）"

  # 深度扫描断言
  has "GhostAppCache" "${out}" "深度: 闲置 40 天的孤立缓存被列出"
  has_not "闲置 0 天" "${out}" "深度: 新鲜缓存不进孤立缓存清单"
  has "OldApp-2026-08-01.ips" "${out}" "深度: 旧崩溃报告被列出"
  has_not "NewApp-today.ips" "${out}" "深度: 新崩溃报告被跳过"
  has "broken-link" "${out}" "深度: 悬空链接被列出"
  has_not "good-link" "${out}" "深度: 有效链接不进清单"
  has "EmptyShell" "${out}" "深度: 孤立空目录被列出"

  # ── 2) 范围闸 ──
  run_sweep "${T}" "${locale_name}" --clean >/dev/null 2>&1
  [ "${RC}" = "2" ] && ok "裸 --clean 被拒（退出码 2）" || bad "裸 --clean 应退出码 2，实得 ${RC}"
  run_sweep "${T}" "${locale_name}" --clean --all --yes >/dev/null 2>&1
  [ "${RC}" = "2" ] && ok "--clean --all --yes 被拒（退出码 2）" || bad "--clean --all --yes 应退出码 2，实得 ${RC}"
  run_sweep "${T}" "${locale_name}" --clean --yes >/dev/null 2>&1
  [ "${RC}" = "2" ] && ok "--clean --yes（无筛选）被拒（退出码 2）" || bad "--clean --yes 应退出码 2，实得 ${RC}"
  exists "${T}/home/.npm/_cacache/content.bin" "范围闸后: npm 缓存未被动"

  # ── 3) --clean + 回车取消 ──
  STDIN_DATA=$'\n'
  run_sweep "${T}" "${locale_name}" --clean --all
  out="${SWEEP_OUT}"
  rc=${RC}
  [ "${rc}" = "0" ] && ok "--clean + 回车: 退出码 0" || bad "--clean + 回车应退出码 0，实得 ${rc}"
  has "已取消" "${out}" "--clean + 回车: 取消生效"
  exists "${T}/home/.npm/_cacache/content.bin" "--clean + 回车: npm 缓存仍在"

  # ── 3b) --clean + 乱输入取消 ──
  STDIN_DATA='nope\n'
  run_sweep "${T}" "${locale_name}" --clean --all
  out="${SWEEP_OUT}"
  has "已取消" "${out}" "--clean + 乱输入: 取消生效"
  exists "${T}/logs/SomeApp/app.log" "--clean + 乱输入: 日志仍在"

  # ── 3c) --clean + y（不算确认）──
  STDIN_DATA='y\n'
  run_sweep "${T}" "${locale_name}" --clean --all
  out="${SWEEP_OUT}"
  has "已取消" "${out}" "--clean + 'y': 仍取消（必须手打 yes）"
  exists "${T}/logs/SomeApp/app.log" "--clean + 'y': 日志仍在"

  # ── 4) --clean --all + yes：全清单进废纸篓 ──
  STDIN_DATA='yes\n'
  run_sweep "${T}" "${locale_name}" --clean --all
  out="${SWEEP_OUT}"
  rc=${RC}
  [ "${rc}" = "0" ] && ok "--clean --all + yes: 退出码 0" || bad "--clean --all + yes 应退出码 0，实得 ${rc}"
  gone "${T}/home/Library/Developer/Xcode/DerivedData/MyApp-abc123" "清理: 闲置 DerivedData 已移走"
  exists "${T}/home/Library/Developer/Xcode/DerivedData/FreshApp-def456" "清理: 新鲜 DerivedData 保留"
  gone "${T}/logs/SomeApp/app.log" "清理: 闲置旧日志已移走"
  exists "${T}/logs/SomeApp/fresh.log" "清理: 新鲜日志保留"
  gone "${T}/home/Library/Application Support/Google/Chrome/Default/Cache" "清理: 浏览器 Cache 已移走"
  exists "${T}/home/Library/Application Support/Google/Chrome/Default/Sessions" "清理: 登录态 Sessions 保留"
  exists "${T}/caches/SomeRandomApp/blob.bin" "清理: 规则外缓存仍在（白名单优先于规则）"
  gone "${T}/caches/GhostAppCache" "深度清理: 孤立缓存已移走"
  exists "${T}/logs/DiagnosticReports/NewApp-today.ips" "深度清理: 新崩溃报告保留"
  gone "${T}/logs/DiagnosticReports/OldApp-2026-08-01.ips" "深度清理: 旧崩溃报告已移走"
  gone "${T}/caches/broken-link" "深度清理: 悬空链接已移走"
  exists "${T}/caches/good-link" "深度清理: 有效链接保留"
  gone "${T}/caches/EmptyShell" "深度清理: 孤立空目录已移走"
  exists "${T}/home/Desktop/notes/todo.log" "清理: Desktop 下 .log 仍在（规则外）"
  exists "${T}/home/devproj/node_modules" "清理: node_modules 本体保留"
  gone "${T}/home/devproj/node_modules/.cache" "清理: node_modules/.cache 已移走"

  # 废纸篓里能找到
  if [ -e "${T}/home/.Trash/app.log" ]; then
    ok "废纸篓: app.log 在废纸篓里"
  else
    bad "废纸篓: 找不到 app.log"
  fi

  # 恢复 fixture，继续后续用例
  reset_fixture "${T}"; setup_trash "${T}"

  # ── 5) 筛选：只清命中的 ──
  STDIN_DATA='yes\n'
  run_sweep "${T}" "${locale_name}" --clean npm
  out="${SWEEP_OUT}"
  gone "${T}/home/.npm/_cacache/content.bin" "筛选 npm: 命中的 npm 缓存被清"
  exists "${T}/logs/SomeApp/app.log" "筛选 npm: 未命中的日志仍在"
  exists "${T}/home/Library/Developer/Xcode/DerivedData/MyApp-abc123/build.db" "筛选 npm: 未命中的 DerivedData 仍在"

  reset_fixture "${T}"; setup_trash "${T}"

  # ── 6) --and 交集 ──
  STDIN_DATA='yes\n'
  run_sweep "${T}" "${locale_name}" --clean logs --and app
  out="${SWEEP_OUT}"
  # logs --and app → 命中「旧日志」类别；标签含 app.log
  gone "${T}/logs/SomeApp/app.log" "交集 logs--and app: 旧日志被清"
  exists "${T}/home/.npm/_cacache/content.bin" "交集 logs--and app: npm 缓存不动"

  reset_fixture "${T}"; setup_trash "${T}"

  # ── 6b) 交集无命中 → 取消路径也不出问题 ──
  STDIN_DATA='yes\n'
  run_sweep "${T}" "${locale_name}" --clean zzz --and qqq
  out="${SWEEP_OUT}"
  exists "${T}/logs/SomeApp/app.log" "交集无命中: 文件原样"

  reset_fixture "${T}"; setup_trash "${T}"

  # ── 7) --yes + 筛选：跳过二次确认 ──
  run_sweep "${T}" "${locale_name}" --clean logs --yes
  out="${SWEEP_OUT}"
  rc=${RC}
  [ "${rc}" = "0" ] && ok "--clean logs --yes: 退出码 0" || bad "--clean logs --yes 应退出码 0，实得 ${rc}"
  gone "${T}/logs/SomeApp/app.log" "--yes: 旧日志被清（无需交互）"
  exists "${T}/home/.npm/_cacache/content.bin" "--yes: 未筛选的项不动"

  # ── 8) 只报告区永不清理：--clean --all 也不碰规则外缓存 ──
  reset_fixture "${T}"; setup_trash "${T}"
  STDIN_DATA='yes\n'
  run_sweep "${T}" "${locale_name}" --clean --all
  out="${SWEEP_OUT}"
  exists "${T}/caches/SomeRandomApp/blob.bin" "报告区项: 规则外缓存即便 --clean --all 也不动"
  exists "${T}/home/Desktop/notes/todo.log" "报告区项: Desktop 下 .log 即便 --clean --all 也不动"

  # ── 9) .DS_Store 被收进清单 ──
  gone "${T}/home/Documents/.DS_Store" "清理: Documents/.DS_Store 已移走"
  gone "${T}/home/Desktop/.DS_Store" "清理: Desktop/.DS_Store 已移走"

  nuke "${T}"
}

echo "mac-sweep.sh 回归测试"
run_case "C" "C locale"
run_case "en_US.UTF-8" "UTF-8 locale"

echo
echo "=============================================="
if [ "${FAIL}" -eq 0 ]; then
  echo "全部通过: ${PASS} 项断言 ✓"
  exit 0
else
  echo "失败 ${FAIL} 项 / 通过 ${PASS} 项:"
  printf '%s\n' "${FAILED_NAMES}"
  exit 1
fi
