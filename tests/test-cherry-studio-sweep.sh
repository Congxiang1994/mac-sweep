#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cherry-studio-sweep.sh 回归测试
#
# 全程隔离：CS_HOME 指向 /tmp 下的假目录，绝不碰真实的 Cherry Studio 数据。
# Data/（sqlite 主库）、IndexedDB、Local Storage、Cookies 全部验证保留。
#
# 用法: bash tests/test-cherry-studio-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/cherry-studio-sweep.sh"
[ -f "${SCRIPT}" ] || { echo "找不到脚本: ${SCRIPT}" >&2; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""
CASE=""

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - [${CASE}] $1"; }

eq()   { [ "$1" = "$2" ] && ok || bad "$3（期望 ${2}，实得 ${1}）"; }
has()  { case "$1" in *"$2"*) ok ;; *) bad "$3（输出里没有「${2}」）" ;; esac; }
not_has() { case "$1" in *"$2"*) bad "$3（输出里不该出现「${2}」）" ;; *) ok ;; esac; }
gone() { [ ! -e "$1" ] && ok || bad "$2（仍存在: $1）"; }
keep() { [ -e "$1" ]   && ok || bad "$2（被误删: $1）"; }

nuke() {
  local p="$1"
  [ -e "${p}" ] || return 0
  env -u PYTHONPATH /usr/bin/python3 -c \
    'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "${p}" 2>/dev/null
  [ -e "${p}" ] && rm -rf "${p}"
  return 0
}

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cherry-sweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
CS="${FIX_HOME}/Library/Application Support/CherryStudio"

mk_big() { mkdir -p "$(dirname "$1")"; head -c "$(( ${2} * 1024 ))" /dev/zero > "$1"; }
mk_bigdir() { mkdir -p "$1"; head -c "$(( ${2} * 1024 ))" /dev/zero > "$1/x.bin"; }

reset_fixture() {
  nuke "${FIX_ROOT}"
  mkdir -p "${CS}/Partitions/webview" "${CS}/Partitions/default" "${CS}/logs" "${CS}/Crashpad/completed"

  # ── 应该进清单的 ──
  mk_bigdir "${CS}/Cache" 300                      # Electron 渲染缓存
  mk_bigdir "${CS}/GPUCache" 60
  mk_bigdir "${CS}/Partitions/webview/Cache" 500   # 内置浏览器缓存（大头）
  mk_bigdir "${CS}/Partitions/webview/Code Cache" 100
  mk_bigdir "${CS}/InterestGroups" 20              # 隐私追踪
  mk_big    "${CS}/SharedStorage-wal" 10
  mk_big    "${CS}/Partitions/webview/Trust Tokens" 36
  mk_big    "${CS}/logs/app.2026-01-01.log" 40     # 历史日志
  mk_big    "${CS}/logs/app-error.2026-01-02.log" 30
  mk_bigdir "${CS}/Crashpad/completed" 15          # 崩溃转储
  mk_big    "${CS}/Session Storage/LOG.old" 4      # 杂项

  # ── 绝不能动的 ──
  mk_big    "${CS}/Data/cherrystudio.sqlite" 2000  # 主数据库
  mk_big    "${CS}/Data/cherrystudio.sqlite-wal" 500
  mk_bigdir "${CS}/Data/Agents" 100
  mk_bigdir "${CS}/Data/Skills" 50
  mk_bigdir "${CS}/IndexedDB" 300
  mk_bigdir "${CS}/Local Storage" 100
  mk_bigdir "${CS}/WebStorage" 80
  mk_big    "${CS}/Partitions/default/Cookies" 20  # 登录态
  mk_big    "${CS}/Partitions/webview/Cookies" 20
  mk_big    "${CS}/cache.json" 5
  mk_big    "${CS}/Crashpad/settings.dat" 1        # 崩溃上报开关配置

  # 今天的日志（保留）
  local today; today=$(date +%Y-%m-%d)
  mk_big    "${CS}/logs/app.${today}.log" 25
  mk_big    "${CS}/logs/app-error.${today}.log" 5
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" CS_HOME="${CS}" LC_ALL="${LOCALE}" \
               /bin/bash "${SCRIPT}" "$@" 2>&1)"
  RUN_RC=$?
}

run_locale() {
  local locale_name="$1" label="$2"
  LOCALE="${locale_name}"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  # A. 交互默认 --------------------------------------------------------------
  CASE="交互默认"
  reset_fixture
  run_script ""
  eq "${RUN_RC}" "0" "默认模式退出码 0"
  has "${RUN_OUT}" "要清理哪些？" "默认模式给出选择提示"
  has "${RUN_OUT}" "结束，未处理的项原样不动" "回车 = 结束"
  keep "${CS}/Cache" "⭐ 默认模式不动 Cache"
  keep "${CS}/Data/cherrystudio.sqlite" "⭐ 主数据库始终不动"

  CASE="交互默认"
  reset_fixture
  run_script "q"
  keep "${CS}/Partitions/webview/Cache" "⭐ 输入 q 后文件仍然存在"

  CASE="交互默认"
  reset_fixture
  run_script "abc"
  has "${RUN_OUT}" "看不懂这个输入" "乱输入给出提示"
  keep "${CS}/Partitions/webview/Cache" "⭐ 乱输入后文件仍然存在"

  # B. 交互选择 --------------------------------------------------------------
  CASE="交互选择"
  reset_fixture
  run_script "yes"
  eq "${RUN_RC}" "0" "交互输入 yes 后退出码 0"
  gone "${CS}/Cache" "⭐ Electron 缓存被移走"
  gone "${CS}/Partitions/webview/Cache" "webview 缓存被移走"
  gone "${CS}/InterestGroups" "隐私追踪被移走"
  keep "${FIX_HOME}/.Trash/Cache" "Cache 出现在废纸篓（不是真删）"
  keep "${CS}/Data/cherrystudio.sqlite" "⭐ 主数据库原样未动"
  keep "${CS}/Data/cherrystudio.sqlite-wal" "⭐ WAL 原样未动"
  keep "${CS}/IndexedDB" "⭐ IndexedDB 原样未动"
  keep "${CS}/Local Storage" "⭐ Local Storage 原样未动"
  keep "${CS}/WebStorage" "⭐ WebStorage 原样未动"
  keep "${CS}/Partitions/default/Cookies" "⭐ Cookies 原样未动"
  keep "${CS}/Partitions/webview/Cookies" "⭐ webview Cookies 原样未动"
  keep "${CS}/cache.json" "⭐ cache.json 原样未动"
  keep "${CS}/Crashpad/settings.dat" "⭐ settings.dat 原样未动"

  CASE="交互选择"
  reset_fixture
  run_script "1" "历史日志"
  gone "${CS}/logs/app.2026-01-01.log" "历史日志被清"
  keep "${CS}/logs/app.$(date +%Y-%m-%d).log" "⭐ 今天的日志保留"
  keep "${CS}/GPUCache" "⭐ 未进清单的项不动"

  CASE="多轮循环"
  reset_fixture
  run_script "all
all
q" "隐私" "杂项"
  gone "${CS}/InterestGroups" "多轮：第 1 轮清隐私"
  gone "${CS}/Session Storage/LOG.old" "多轮：第 2 轮清杂项"
  keep "${CS}/Cache" "⭐ 筛选外的项保留"

  # C. 范围闸 ---------------------------------------------------------------
  CASE="范围闸"
  reset_fixture
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${CS}/Cache" "裸 --clean 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${CS}/Cache" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  # D. --scan ---------------------------------------------------------------
  CASE="只扫描"
  reset_fixture
  run_script "" --scan
  eq "${RUN_RC}" "0" "--scan 退出码 0"
  has "${RUN_OUT}" "只扫描模式（--scan）" "--scan 报告完直接结束"
  not_has "${RUN_OUT}" "要清理哪些？" "--scan 不进交互"
  keep "${CS}/Cache" "--scan 不动任何文件"

  CASE="保护提示"
  reset_fixture
  run_script "" --scan
  has "${RUN_OUT}" "保护中" "报告显示保护中数据的规模"

  # E. 筛选 -----------------------------------------------------------------
  CASE="筛选"
  reset_fixture
  run_script "" cache
  has "${RUN_OUT}" "Cache" "筛选命中 cache 项"
  not_has "${RUN_OUT}" "历史日志" "筛选未命中日志项"

  CASE="筛选"
  reset_fixture
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  reset_fixture
  run_script "yes" --clean "隐私" --yes
  eq "${RUN_RC}" "0" "--clean 隐私 --yes 退出码 0"
  gone "${CS}/InterestGroups" "隐私追踪被清"
  gone "${CS}/SharedStorage-wal" "SharedStorage-wal 被清"
  keep "${CS}/Cache" "⭐ 未命中的 Cache 原样未动"
  keep "${CS}/Partitions/default/Cookies" "⭐ Cookies 原样未动"

  # F. 蚊子腿目标 -----------------------------------------------------------
  # 注：隐私类目标聚合展示为「InterestGroups/TrustTokens/DIPS/SharedStorage（N 处）」
  CASE="蚊子腿"
  reset_fixture
  run_script "" --scan
  has "${RUN_OUT}" "InterestGroups/TrustTokens/DIPS/SharedStorage" "wal/TrustTokens 聚合进隐私清单"
  has "${RUN_OUT}" "LOG.old" "LOG.old 进清单"
  not_has "${RUN_OUT}" "cherrystudio.sqlite" "⭐ 主数据库绝不进清单"
  not_has "${RUN_OUT}" "Cookies（" "⭐ Cookies 绝不进清单"
}

echo "════════ cherry-studio-sweep 回归测试 ════════"
echo "脚本: ${SCRIPT}"
echo "隔离 HOME: ${FIX_ROOT}"

run_locale "C"           "C locale 基线"
run_locale "en_US.UTF-8" "UTF-8 locale（终端默认）"

nuke "${FIX_ROOT}"

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
