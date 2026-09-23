#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# chrome-sweep.sh 回归测试
#
# 全程隔离：HOME 指向 /tmp 下的假家目录（CHROME_SUP_DIR / CHROME_CACHE_DIR
# 显式指向 fixture），绝不碰真实的 Chrome 数据与 ~/.Trash。
# 每个用例前重建 fixture（reset_fixture）。
#
# 断言分组：
#   A. 交互默认 —— 不带任何参数时扫描 + 等确认；回车/q 一个文件都不动
#   B. 交互选择 —— yes / 编号 / pick 各自的行为
#   C. 范围闸   —— 裸 --clean / --all --yes / --yes 无筛选，全部退出码 2
#   D. --scan   —— 只报告，不进交互
#   E. 清理规则 —— Cache 清、保护名单（Cookies/Login Data 等）拦
#   F. 筛选     —— 并集 / 交集 / 无命中
#   G. 杂项     —— .DS_Store / CrashpadMetrics 等蚊子腿目标能被列出
#
# 双 locale 各跑一遍（C / en_US.UTF-8）。
#
# 用法: bash tests/test-chrome-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/chrome-sweep.sh"
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

# ⚠️ 必须真删。WorkBuddy 的 shim 会把 rm 改成「移入 ~/. Trash」，
#    于是测试的清理动作反而往用户真实废纸篓里倒一堆假家目录。
nuke() {
  local p="$1"
  [ -e "${p}" ] || return 0
  env -u PYTHONPATH /usr/bin/python3 -c \
    'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "${p}" 2>/dev/null
  [ -e "${p}" ] && rm -rf "${p}"
  return 0
}

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chrome-sweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
SUP="${FIX_HOME}/Library/Application Support/Google/Chrome"
CACHE="${FIX_HOME}/Library/Caches/Google/Chrome"

PROF="${SUP}/Default"

mk_big() {  # mk_big <路径> <KB>
  mkdir -p "$(dirname "$1")"
  head -c "$(( ${2} * 1024 ))" /dev/zero > "$1"
}
mk_bigdir() {  # mk_bigdir <路径> <KB>
  mkdir -p "$1"
  head -c "$(( ${2} * 1024 ))" /dev/zero > "$1/x.bin"
}

reset_fixture() {
  nuke "${FIX_ROOT}"
  mkdir -p "${PROF}" "${CACHE}/Default"

  # ── 应该进清单的 ──
  mk_bigdir "${CACHE}/Default/Cache" 500            # 浏览缓存（最大头）
  mk_bigdir "${CACHE}/Default/Code Cache" 100
  mk_bigdir "${SUP}/component_crx_cache" 80         # 组件升级缓存
  mk_bigdir "${SUP}/ShaderCache" 60                 # GPU 着色器
  mk_bigdir "${PROF}/GPUCache" 40
  mk_bigdir "${PROF}/DawnWebGPUCache" 40
  mk_bigdir "${SUP}/screen_ai" 200                  # AI 模型缓存
  mk_bigdir "${SUP}/Crashpad/completed" 20          # 崩溃报告
  mk_big    "${SUP}/BrowserMetrics-spare.pma" 4000
  mk_big    "${SUP}/CrashpadMetrics-active.pma" 2000
  mk_big    "${PROF}/LOG.old" 10
  mk_big    "${PROF}/DIPS-wal" 30                   # 隐私痕迹
  mk_big    "${PROF}/DIPS" 10
  mk_bigdir "${PROF}/Reporting and NEL" 50
  mk_bigdir "${SUP}/ZxcvbnData" 1600                # 实验组件
  mkdir -p "${SUP}/Crashpad"
  mk_big    "${SUP}/Crashpad/.DS_Store" 8           # 杂项

  # ── 绝不能动的（保护名单） ──
  mk_big    "${PROF}/Cookies" 1000
  mk_big    "${PROF}/Login Data" 200
  mk_big    "${PROF}/History" 1500
  mk_big    "${PROF}/Bookmarks" 100
  mk_big    "${PROF}/Preferences" 100
  mk_big    "${PROF}/Web Data" 400
  mk_bigdir "${PROF}/Local Storage" 300
  mk_bigdir "${PROF}/IndexedDB" 5000
  mk_bigdir "${PROF}/Extensions" 40000
  mk_big    "${PROF}/Favicons" 600
  mk_big    "${SUP}/Local State" 40
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" CHROME_SUP_DIR="${SUP}" CHROME_CACHE_DIR="${CACHE}" \
               LC_ALL="${LOCALE}" \
               /bin/bash "${SCRIPT}" "$@" 2>&1)"
  RUN_RC=$?
}

trash_of() {  # 废纸篓里是否存在某名字
  [ -e "${FIX_HOME}/.Trash/$1" ]
}

# ── 一个 locale 下的完整用例集 ────────────────────────────────────────────────
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
  has "${RUN_OUT}" "交互式确认清理" "默认模式声明要交互确认"
  has "${RUN_OUT}" "要清理哪些？" "默认模式给出选择提示"
  has "${RUN_OUT}" "结束，未处理的项原样不动" "回车 = 结束，不给确认"
  keep "${CACHE}/Default/Cache" "⭐ 默认模式不动 Cache"
  keep "${PROF}/Cookies" "⭐ 默认模式不动 Cookies"

  CASE="交互默认"
  reset_fixture
  run_script "q"
  has "${RUN_OUT}" "结束，未处理的项原样不动" "输入 q = 结束"
  keep "${CACHE}/Default/Cache" "⭐ 输入 q 后文件仍然存在"

  CASE="交互默认"
  reset_fixture
  run_script "abc"
  has "${RUN_OUT}" "看不懂这个输入" "乱输入给出提示"
  keep "${CACHE}/Default/Cache" "⭐ 乱输入后文件仍然存在"

  # B. 交互选择 --------------------------------------------------------------
  CASE="交互选择"
  reset_fixture
  run_script "yes"
  eq "${RUN_RC}" "0" "交互输入 yes 后退出码 0"
  gone "${CACHE}/Default/Cache" "⭐ 交互输入 yes 后 Cache 被移走"
  keep "${FIX_HOME}/.Trash/Cache" "Cache 出现在废纸篓（不是真删）"
  gone "${SUP}/component_crx_cache" "组件升级缓存一起被清"
  keep "${PROF}/Cookies" "⭐ Cookies 原样未动"
  keep "${PROF}/Login Data" "⭐ Login Data 原样未动"
  keep "${PROF}/History" "⭐ History 原样未动"
  keep "${PROF}/Bookmarks" "⭐ Bookmarks 原样未动"
  keep "${PROF}/Local Storage" "⭐ Local Storage 原样未动"
  keep "${PROF}/IndexedDB" "⭐ IndexedDB 原样未动"
  keep "${PROF}/Extensions" "⭐ Extensions 原样未动"
  keep "${SUP}/Local State" "⭐ Local State 原样未动"

  CASE="交互选择"
  reset_fixture
  run_script "1" "崩溃报告"
  gone "${SUP}/Crashpad/completed" "输入编号 1 → 崩溃报告被移走"
  keep "${CACHE}/Default/Cache" "⭐ 未进清单的项不动"

  CASE="多轮循环"
  reset_fixture
  run_script "all
all
q" "隐私" "杂项"
  gone "${PROF}/DIPS-wal" "多轮：第 1 轮清隐私痕迹"
  gone "${PROF}/DIPS" "多轮：第 1 轮清隐私痕迹（DIPS 本体）"
  gone "${SUP}/Crashpad/.DS_Store" "多轮：第 2 轮清杂项"
  keep "${CACHE}/Default/Cache" "⭐ 筛选外的项保留"

  # C. 范围闸 ---------------------------------------------------------------
  CASE="范围闸"
  reset_fixture
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${CACHE}/Default/Cache" "裸 --clean 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${CACHE}/Default/Cache" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  # D. --scan ---------------------------------------------------------------
  CASE="只扫描"
  reset_fixture
  run_script "" --scan
  eq "${RUN_RC}" "0" "--scan 退出码 0"
  has "${RUN_OUT}" "只扫描，不删除任何文件" "--scan 声明不删除"
  not_has "${RUN_OUT}" "要清理哪些？" "--scan 不进交互"
  keep "${CACHE}/Default/Cache" "--scan 不动任何文件"

  # E. 清理规则：保护名单硬防线 ---------------------------------------------
  CASE="硬防线"
  reset_fixture
  run_script "yes" --clean --all
  keep "${PROF}/Cookies" "⭐ --clean --all 也不动 Cookies"
  keep "${PROF}/Login Data" "⭐ 不动 Login Data"
  keep "${PROF}/Preferences" "⭐ 不动 Preferences"
  keep "${PROF}/Web Data" "⭐ 不动 Web Data"
  keep "${PROF}/Favicons" "⭐ 不动 Favicons"
  keep "${PROF}/History" "⭐ 不动 History"
  keep "${PROF}/Bookmarks" "⭐ 不动 Bookmarks"
  keep "${PROF}/Local Storage" "⭐ 不动 Local Storage"
  keep "${PROF}/IndexedDB" "⭐ 不动 IndexedDB"
  keep "${PROF}/Extensions" "⭐ 不动 Extensions"
  keep "${SUP}/Local State" "⭐ 不动 Local State"

  # F. 筛选 -----------------------------------------------------------------
  CASE="筛选"
  reset_fixture
  run_script "" cache
  has "${RUN_OUT}" "Cache" "筛选命中 cache 项"
  not_has "${RUN_OUT}" "screen_ai" "筛选未命中 AI 模型项"

  CASE="筛选"
  reset_fixture
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  reset_fixture
  run_script "" --clean cache --yes
  eq "${RUN_RC}" "0" "--clean cache --yes 退出码 0"
  gone "${CACHE}/Default/Cache" "筛选命中的项被清掉"
  keep "${SUP}/screen_ai" "⭐ 未命中的 AI 模型缓存原样未动"

  CASE="筛选"
  reset_fixture
  run_script "yes" --clean "崩溃报告" "隐私" --yes
  gone "${SUP}/Crashpad/completed" "并集命中崩溃报告"
  gone "${PROF}/DIPS" "并集命中隐私痕迹"
  keep "${CACHE}/Default/Cache" "并集未命中 Cache，保留"

  # G. 蚊子腿目标必须出现在清单里 -------------------------------------------
  CASE="蚊子腿"
  reset_fixture
  run_script "" --scan
  has "${RUN_OUT}" "CrashpadMetrics-active.pma" "CrashpadMetrics 进清单"
  has "${RUN_OUT}" "ZxcvbnData" "实验组件进清单"
  has "${RUN_OUT}" "DIPS-wal" "隐私痕迹 wal 进清单"
  has "${RUN_OUT}" "Reporting and NEL" "Reporting and NEL 进清单"
  has "${RUN_OUT}" ".DS_Store" "散落 DS_Store 进清单"
  has "${RUN_OUT}" "LOG.old" "LOG.old 进清单"
  not_has "${RUN_OUT}" "Cookies（" "⭐ Cookies 绝不进清单"
  not_has "${RUN_OUT}" "Login Data（" "⭐ Login Data 绝不进清单"
}

echo "════════ chrome-sweep 回归测试 ════════"
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
