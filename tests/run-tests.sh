#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# workbuddy-sweep.sh 回归测试
#
# 在 /tmp 下建隔离目录跑真实脚本，断言：
#   1. 已结束的沙箱会话被删；存活 PID 的文件完整保留
#   2. 历史日期沙箱目录、闲置 traces、散落 .DS_Store 被删
#   3. 退出码为 0，且无 "unbound variable" 类报错
#   4. ⭐ 在 C locale 与 UTF-8 locale 下行为一致
#      （bash 在 UTF-8 locale 下会把 $var 后紧跟的多字节字符吞进变量名，
#        裸 $var 写法会导致 "pidlabel: unbound variable"，此测试专防这类回归）
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

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - $1"; }

# 断言的三种基本形态
assert_file_gone() { [ ! -e "$1" ] && ok "$2" || bad "$2（仍存在: $1）"; }
assert_file_keep() { [ -e "$1" ]  && ok "$2" || bad "$2（被误删: $1）"; }
assert_eq()        { [ "$1" = "$2" ] && ok "$3" || bad "$3（期望 $2，实得 $1）"; }

today="$(date +%Y%m%d)"
if date -v-1d +%Y%m%d >/dev/null 2>&1; then
  yesterday="$(date -v-1d +%Y%m%d)"     # macOS
else
  yesterday="$(date -d 'yesterday' +%Y%m%d)"   # GNU
fi

LIVE_PID="$(pgrep -x Finder 2>/dev/null | head -1)"
[ -n "${LIVE_PID}" ] || LIVE_PID="$(pgrep -x launchd 2>/dev/null | head -1)"
[ -n "${LIVE_PID}" ] || { echo "无法取得一个存活 PID，测试无法进行" >&2; exit 1; }

DEAD_PID=999999
CENTER_PID=888888

# ── 单个 locale 的完整用例 ────────────────────────────────────────────────────
run_case() {
  local locale_name="$1"
  local label="$2"

  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  local T
  T="$(mktemp -d "${TMPDIR:-/tmp}/wbsweep-test.XXXXXX")" || { bad "创建测试目录失败"; return; }

  mkdir -p "${T}/logs/sandbox/${today}" \
           "${T}/logs/sandbox/${yesterday}" \
           "${T}/app/session/Cache" \
           "${T}/traces/11112222" \
           "${T}/cache"

  # 今天：dead pid / center 会话 / 存活 pid
  head -c 90000 /dev/zero > "${T}/logs/sandbox/${today}/sandbox_${DEAD_PID}_000.log"
  head -c 40000 /dev/zero > "${T}/logs/sandbox/${today}/sandbox_center_${CENTER_PID}_000.log"
  head -c 20000 /dev/zero > "${T}/logs/sandbox/${today}/sandbox_${LIVE_PID}_000.log"
  # 历史日期目录（整目录回收）
  head -c 30000 /dev/zero > "${T}/logs/sandbox/${yesterday}/sandbox_777777_000.log"
  # 闲置 traces（mtime 拉老）
  head -c 25000 /dev/zero > "${T}/traces/11112222/trace.json"
  touch -t 202001010000 "${T}/traces/11112222" "${T}/traces/11112222/trace.json" 2>/dev/null
  # 散落 .DS_Store
  head -c 9000 /dev/zero > "${T}/.DS_Store"

  local out rc
  out="$(WB_HOME="${T}" SANDBOX_COOLDOWN_MIN=0 TRACE_MAX_AGE_MIN=1 \
         LC_ALL="${locale_name}" /bin/bash "${SCRIPT}" --apply 2>&1)"
  rc=$?

  assert_eq "${rc}" "0" "退出码为 0"
  if printf '%s' "${out}" | grep -q 'unbound variable'; then
    bad "无 unbound variable 报错（实际输出见下）"
    printf '%s\n' "${out}" | sed 's/^/      | /'
  else
    ok "无 unbound variable 报错"
  fi

  assert_file_gone "${T}/logs/sandbox/${today}/sandbox_${DEAD_PID}_000.log" "已结束会话被删除"
  assert_file_gone "${T}/logs/sandbox/${today}/sandbox_center_${CENTER_PID}_000.log" "已结束 center 会话被删除"
  assert_file_keep "${T}/logs/sandbox/${today}/sandbox_${LIVE_PID}_000.log" "⭐ 存活 PID 会话被保留"
  assert_file_gone "${T}/logs/sandbox/${yesterday}" "历史日期沙箱目录被删除"
  assert_file_gone "${T}/traces/11112222" "闲置 traces 被回收"
  assert_file_gone "${T}/.DS_Store" "散落 .DS_Store 被删除"

  rm -rf "${T}" 2>/dev/null
}

echo "════════ workbuddy-sweep 回归测试 ════════"
echo "脚本: ${SCRIPT}"
echo "今天: ${today}   昨天: ${yesterday}   存活 PID: ${LIVE_PID}"

run_case "C"          "C locale 基线"
run_case "en_US.UTF-8" "UTF-8 locale（终端默认）"

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
