#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# workbuddy-sweep.sh 回归测试
#
# 全程隔离：HOME 指向 /tmp 下的假家目录，绝不碰真实的 ~/.workbuddy、
# ~/WorkBuddy 与 ~/.Trash。每个用例前重建 fixture（reset_fixture），
# 否则前一个用例删掉的东西会让后一个用例假通过。
#
# 断言分四组：
#   A. 只读默认 —— 不带 --clean 时一个文件都不动
#   B. 范围闸   —— 裸 --clean / --all --yes / --yes 无筛选，全部退出码 2
#   C. 二次确认 —— 回车或 y 都必须取消；打 yes 才动手；pick 答 n 的项不动
#   D. 清理规则 —— 存活 PID 会话保留；空会话目录只清「老的 + 空的 + 时间命名的」
#
# 双 locale 各跑一遍（C / en_US.UTF-8）：bash 在 UTF-8 locale 下会把裸 $var
# 后面紧跟的多字节字符吞进变量名，这类 bug 单 locale 测不出来。
#
# 用法: bash tests/run-tests.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/workbuddy-sweep.sh"
[ -f "${SCRIPT}" ] || { echo "找不到脚本: ${SCRIPT}" >&2; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""
CASE=""

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - [${CASE}] $1"; }

# ── 断言 ─────────────────────────────────────────────────────────────────────
eq()   { [ "$1" = "$2" ] && ok || bad "$3（期望 ${2}，实得 ${1}）"; }
has()  { case "$1" in *"$2"*) ok ;; *) bad "$3（输出里没有「${2}」）" ;; esac; }
not_has() { case "$1" in *"$2"*) bad "$3（输出里不该出现「${2}」）" ;; *) ok ;; esac; }
gone() { [ ! -e "$1" ] && ok || bad "$2（仍存在: $1）"; }
keep() { [ -e "$1" ]   && ok || bad "$2（被误删: $1）"; }

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wbsweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
WB="${FIX_HOME}/.workbuddy"
WS="${FIX_HOME}/WorkBuddy"

TODAY="$(date +%Y%m%d)"
NEWEST_EMPTY="$(date +%Y-%m-%d-%H-%M-%S)"     # 刚创建的空目录 → 必须跳过
OLD_EMPTY_A="2026-09-14-08-24-08"
OLD_EMPTY_B="2026-09-15-09-26-56"
NONEMPTY="2026-09-16-10-09-02"               # 有内容 → 必须保留
ODD_NAME="Claw"                              # 非时间命名 → 必须保留

LIVE_PID="$(pgrep -x Finder 2>/dev/null | head -1)"
[ -n "${LIVE_PID}" ] || LIVE_PID="$(pgrep -x launchd 2>/dev/null | head -1)"
[ -n "${LIVE_PID}" ] || { echo "无法取得存活 PID，测试无法进行" >&2; exit 1; }

reset_fixture() {
  rm -rf "${FIX_ROOT}"
  mkdir -p "${WB}/logs/sandbox/${TODAY}" "${WB}/logs/sandbox/20260915" \
           "${WB}/app/session/Cache" "${WB}/traces/5550" \
           "${WS}/${OLD_EMPTY_A}" "${WS}/${OLD_EMPTY_B}" "${WS}/${NEWEST_EMPTY}" \
           "${WS}/${ODD_NAME}" "${WS}/${NONEMPTY}"

  head -c 90000 /dev/zero > "${WB}/logs/sandbox/${TODAY}/sandbox_999999_000.log"
  head -c 40000 /dev/zero > "${WB}/logs/sandbox/${TODAY}/sandbox_center_888888_000.log"
  head -c 20000 /dev/zero > "${WB}/logs/sandbox/${TODAY}/sandbox_${LIVE_PID}_000.log"
  head -c 30000 /dev/zero > "${WB}/logs/sandbox/20260915/sandbox_777777_000.log"
  head -c 50000 /dev/zero > "${WB}/app/session/Cache/x.bin"
  head -c 25000 /dev/zero > "${WB}/traces/5550/t.json"
  echo "report" > "${WS}/${NONEMPTY}/report.md"

  touch -t 202001010000 "${WB}/traces/5550"
  touch -t 202609140900 "${WS}/${OLD_EMPTY_A}"
  touch -t 202609150930 "${WS}/${OLD_EMPTY_B}"
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  # 一律补一个换行：模拟真实终端里「打完字按回车」，也让多次 read 能逐行消费
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" SANDBOX_COOLDOWN_MIN=0 LC_ALL="${LOCALE}" \
               /bin/bash "${SCRIPT}" "$@" 2>&1)"
  RUN_RC=$?
}

# ── 一个 locale 下的完整用例集 ────────────────────────────────────────────────
run_locale() {
  local locale_name="$1" label="$2"
  LOCALE="${locale_name}"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  # A. 默认只读 --------------------------------------------------------------
  CASE="默认只读"
  reset_fixture
  run_script ""
  eq "${RUN_RC}" "0" "默认模式退出码 0"
  has "${RUN_OUT}" "只扫描，不删除任何文件" "默认模式声明不删除"
  has "${RUN_OUT}" "以上仅为报告" "默认模式给出下一步提示"
  keep "${WB}/app/session/Cache" "默认模式不动 Cache"
  keep "${WB}/logs/sandbox/${TODAY}/sandbox_999999_000.log" "默认模式不动沙箱日志"
  keep "${WS}/${OLD_EMPTY_A}" "默认模式不动空会话目录"

  # B. 范围闸 ---------------------------------------------------------------
  CASE="范围闸"
  reset_fixture
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${WB}/app/session/Cache" "裸 --clean 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${WB}/app/session/Cache" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  CASE="范围闸"
  reset_fixture
  run_script "" --apply
  eq "${RUN_RC}" "2" "旧参数 --apply 退出码 2"
  has "${RUN_OUT}" "已改名为 --clean" "旧参数给出改名提示"

  # C. 二次确认 -------------------------------------------------------------
  CASE="二次确认"
  reset_fixture
  run_script "" --clean --all              # 空 stdin ≈ 直接回车
  eq "${RUN_RC}" "0" "回车后退出码 0"
  has "${RUN_OUT}" "已取消" "回车被识别为取消"
  keep "${WB}/app/session/Cache" "⭐ 回车后文件仍然存在"
  keep "${WS}/${OLD_EMPTY_A}" "回车后空会话目录仍然存在"

  CASE="二次确认"
  reset_fixture
  run_script "y" --clean --all             # y 不是确认词
  eq "${RUN_RC}" "0" "输入 y 后退出码 0"
  has "${RUN_OUT}" "已取消" "输入 y 被识别为取消（y 不算确认）"
  keep "${WB}/app/session/Cache" "⭐ 输入 y 后文件仍然存在"

  CASE="二次确认"
  reset_fixture
  run_script "nope" --clean --all
  keep "${WB}/app/session/Cache" "乱输后文件仍然存在"

  CASE="二次确认"
  reset_fixture
  run_script "yes" --clean --all
  eq "${RUN_RC}" "0" "输入 yes 后退出码 0"
  has "${RUN_OUT}" "开始移入废纸篓" "输入 yes 才进入执行"
  gone "${WB}/app/session/Cache" "⭐ 输入 yes 后 Cache 被移走"
  keep "${FIX_HOME}/.Trash/Cache" "Cache 出现在废纸篓（不是真删）"
  gone "${WB}/logs/sandbox/${TODAY}/sandbox_999999_000.log" "已结束会话被移走"
  keep "${WB}/logs/sandbox/${TODAY}/sandbox_${LIVE_PID}_000.log" "⭐ 存活 PID 会话被保留"

  CASE="二次确认"
  reset_fixture
  run_script "pick
n
q" --clean --all
  eq "${RUN_RC}" "0" "pick 模式退出码 0"
  has "${RUN_OUT}" "逐项挑选" "pick 进入逐项流程"
  keep "${WB}/app/session/Cache" "⭐ pick 答 n 的项不动"

  # D. 清理规则 -------------------------------------------------------------
  CASE="空会话目录"
  reset_fixture
  run_script "yes" --clean --all
  gone "${WS}/${OLD_EMPTY_A}" "老的空会话目录被清掉"
  gone "${WS}/${OLD_EMPTY_B}" "老的空会话目录被清掉（第二个）"
  keep "${WS}/${NEWEST_EMPTY}" "⭐ 刚创建的空会话目录被跳过"
  keep "${WS}/${ODD_NAME}" "⭐ 非时间命名的空目录不碰（认不出主人）"
  keep "${WS}/${NONEMPTY}" "⭐ 非空会话目录保留"
  keep "${WS}/${NONEMPTY}/report.md" "非空目录里的文件保留"
  has "${RUN_OUT}" "空会话目录旁注" "给出空会话目录的跳过说明"

  # E. 筛选 ----------------------------------------------------------------
  CASE="筛选"
  reset_fixture
  run_script "" sandbox
  eq "${RUN_RC}" "0" "只读筛选退出码 0"
  has "${RUN_OUT}" "sandbox" "筛选命中 sandbox 项"
  not_has "${RUN_OUT}" "Electron 渲染缓存" "筛选未命中 Cache 项"

  CASE="筛选"
  reset_fixture
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  reset_fixture
  run_script "" traces --and 5550
  has "${RUN_OUT}" "traces/5550" "交集命中"
  not_has "${RUN_OUT}" "Electron 渲染缓存" "交集未命中 Cache 项"

  CASE="筛选"
  reset_fixture
  run_script "yes" --clean traces --yes
  eq "${RUN_RC}" "0" "--clean <关键词> --yes 退出码 0"
  gone "${WB}/traces/5550" "筛选命中的项被清掉"
  keep "${WB}/app/session/Cache" "⭐ 未命中的项原样未动"
  keep "${WB}/logs/sandbox/${TODAY}/sandbox_999999_000.log" "⭐ 未命中的沙箱日志原样未动"

  CASE="筛选"
  reset_fixture
  run_script "yes" --clean sandbox traces --yes
  gone "${WB}/traces/5550" "并集命中 traces"
  gone "${WB}/logs/sandbox/20260915" "并集命中 sandbox"
  keep "${WB}/app/session/Cache" "并集未命中 Cache，保留"
}

echo "════════ workbuddy-sweep 回归测试 ════════"
echo "脚本: ${SCRIPT}"
echo "隔离 HOME: ${FIX_HOME}"
echo "今天: ${TODAY}  存活 PID: ${LIVE_PID}"

run_locale "C"           "C locale 基线"
run_locale "en_US.UTF-8" "UTF-8 locale（终端默认）"

rm -rf "${FIX_ROOT}" 2>/dev/null

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
