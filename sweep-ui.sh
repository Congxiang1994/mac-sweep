#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════════
# sweep-ui.sh — mac-sweep 统一视觉层（色彩 + 版式）
#
# 被 sweep-common.sh source。设计目标：
#   1) 全系列 7 支脚本同一套颜色语义与排版，扫一眼就懂
#   2) 颜色只在真终端生效；管道 / 重定向 / NO_COLOR 时输出纯文本（可 diff、可 grep）
#   3) 零依赖：纯 bash，不 fork awk/sed 做宽度计算
#
# ── 颜色开关（优先级从高到低）──────────────────────────────────────────────
#   SWEEP_COLOR=always|never|auto   显式指定（默认 auto）
#   NO_COLOR=<任意非空>             业界约定，等价 SWEEP_COLOR=never
#   FORCE_COLOR=1                  强制开色（用于演示 / CI 里看效果）
#
# ── 颜色语义（所有脚本统一）──────────────────────────────────────────────────
#   标题/分节    青色   —— 结构
#   键名         灰蓝   —— 标签
#   路径         暗灰   —— 次要信息
#   大小         黄色   —— 数字，最需要扫一眼的信息
#   编号         绿色   —— 可选中的项
#   类别         品红   —— 分组
#   成功         绿色   —— 已移入废纸篓
#   警告         红色   —— 运行中 / 有代价
#   提示         蓝色   —— 旁注
#   错误         红色   —— 失败
# ─────────────────────────────────────────────────────────────────────────────

# ── 开关判定 ─────────────────────────────────────────────────────────────────
case "${SWEEP_COLOR:-auto}" in
  always) SWEEP_COLOR_ON=1 ;;
  never)  SWEEP_COLOR_ON=0 ;;
  *)
    if [ -n "${NO_COLOR:-}" ]; then
      SWEEP_COLOR_ON=0
    elif [ -n "${FORCE_COLOR:-}" ]; then
      SWEEP_COLOR_ON=1
    elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
      SWEEP_COLOR_ON=1
    else
      SWEEP_COLOR_ON=0
    fi
    ;;
esac

# ── ANSI 序列（只定义一次，开色时才真正输出）────────────────────────────────
if [ "${SWEEP_COLOR_ON}" -eq 1 ]; then
  C_RESET=$'\033[0m'
  C_TITLE=$'\033[1;36m'      # 亮青
  C_SECTION=$'\033[36m'      # 青
  C_KEY=$'\033[90m'          # 亮黑（灰）
  C_DIM=$'\033[2m'           # 暗
  C_SIZE=$'\033[33m'         # 黄
  C_NUM=$'\033[32m'          # 绿
  C_CAT=$'\033[35m'          # 品红
  C_OK=$'\033[32m'           # 绿
  C_WARN=$'\033[31m'         # 红
  C_HINT=$'\033[34m'         # 蓝
  C_ERR=$'\033[1;31m'        # 亮红
  C_BOLD=$'\033[1m'
else
  C_RESET=''; C_TITLE=''; C_SECTION=''; C_KEY=''; C_DIM=''
  C_SIZE=''; C_NUM=''; C_CAT=''; C_OK=''; C_WARN=''; C_HINT=''; C_ERR=''; C_BOLD=''
fi

# ── 显示宽度（纯 bash，不 fork）──────────────────────────────────────────────
# CJK / 全角字符占 2 列，ASCII 占 1 列。用于让带颜色的列也能对齐。
disp_width() {  # disp_width <字符串> → 显示列数
  local s="$1" i=0 n w=0 c cb
  local LC_ALL=C
  local bl=${#s}      # 字节数
  unset LC_ALL
  n=${#s}             # 字符数
  [ "${bl}" -eq "${n}" ] && { printf '%s' "${n}"; return 0; }   # 纯 ASCII 快路径
  while [ "${i}" -lt "${n}" ]; do
    c="${s:$i:1}"
    local LC_ALL=C
    cb=${#c}
    unset LC_ALL
    if [ "${cb}" -ge 3 ]; then w=$((w + 2)); else w=$((w + 1)); fi
    i=$((i + 1))
  done
  printf '%s' "${w}"
}

# pad <文本> <列宽> —— 按显示宽度右侧补空格（中文对齐的关键）
pad() {  # pad <文本> <显示列宽>
  local s="$1" want="$2" w
  w=$(disp_width "${s}")
  while [ "${w}" -lt "${want}" ]; do
    s="${s} "
    w=$((w + 1))
  done
  printf '%s' "${s}"
}

# ═════════════════════════════════════════════════════════════════════════════
# 版式组件
# ═════════════════════════════════════════════════════════════════════════════
UI_WIDTH=72
UI_KEY_W=13        # 横幅里键名的列宽

# ui_line <字符> —— 一条横向分隔线
ui_line() {
  local ch="${1:-─}" i=0 out=""
  while [ "${i}" -lt "${UI_WIDTH}" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s%s%s\n' "${C_DIM}" "${out}" "${C_RESET}"
}

# ui_banner <标题> —— 脚本顶部横幅第一行
ui_banner() {
  printf '%s%s%s\n' "${C_TITLE}" "  $1" "${C_RESET}"
}

# ui_kv <键> <值> —— 横幅里的键值行（键上色、值正常、键列自动对齐）
ui_kv() {
  printf '  %s%s%s  %s\n' "${C_KEY}" "$(pad "$1" "${UI_KEY_W}")" "${C_RESET}" "$2"
}

# ui_rule —— 横幅下的淡色横线
ui_rule() {
  printf '  %s' "${C_DIM}"
  local i=0
  while [ "${i}" -lt "${UI_WIDTH}" ]; do printf '─'; i=$((i + 1)); done
  printf '%s\n' "${C_RESET}"
}

# ui_section <标题> —— 分节标题（青色竖条 + 淡色横线）
ui_section() {
  printf '\n%s▌%s %s\n' "${C_SECTION}" "${C_RESET}" "$1"
  printf '%s' "${C_DIM}"
  local i=0 w
  w=$(disp_width "$1")
  while [ "${i}" -lt "${w}" ]; do printf '─'; i=$((i + 1)); done
  printf '%s\n' "${C_RESET}"
}

# ui_note <文本> —— 旁注（蓝色圆点）
ui_note() { printf '  %s·%s %s\n' "${C_HINT}" "${C_RESET}" "$1"; }

# ui_warn <文本> —— 警告（红色三角）
ui_warn() { printf '  %s⚠%s  %s\n' "${C_WARN}" "${C_RESET}" "$1"; }

# ui_ok <文本> —— 成功提示（绿色对勾）
ui_ok() { printf '  %s✔%s  %s\n' "${C_OK}" "${C_RESET}" "$1"; }

# ui_end —— 收尾横线
ui_end() { ui_line '─'; }

# ui_item <编号> <大小> <名称> —— 清单里的一行（编号绿、大小黄）
ui_item() {  # ui_item <显示编号> <大小文本> <名称>
  printf '  %s%s%s  %s%s%s  %s\n' \
    "${C_NUM}" "$1" "${C_RESET}" \
    "${C_SIZE}" "$(pad "$2" 9)" "${C_RESET}" \
    "$3"
}

# ui_item_cat <编号> <大小> <名称> <类别> —— 带类别后缀的清单行
ui_item_cat() {  # ui_item_cat <编号> <大小> <名称> <类别>
  if [ -n "$1" ]; then
    printf '  %s%s%s  ' "${C_NUM}" "$1" "${C_RESET}"
  else
    printf '    '
  fi
  printf '%s%s%s  %s  %s·%s%s\n' \
    "${C_SIZE}" "$(pad "$2" 9)" "${C_RESET}" \
    "$3" "${C_CAT}" "$4" "${C_RESET}"
}

# ui_cat <类别名> —— 清单里的类别分组标题
ui_cat() { printf '\n  %s[%s]%s\n' "${C_CAT}" "$1" "${C_RESET}"; }

# ui_path <路径> —— 次要路径（暗灰）
ui_path() { printf '    %s%s%s\n' "${C_DIM}" "$1" "${C_RESET}"; }

# ui_prompt —— 交互输入提示（醒目）
ui_prompt() { printf '%s>%s ' "${C_BOLD}${C_NUM}" "${C_RESET}"; }

# ui_hint_kv <键> <说明> —— 交互提示里的选项说明（键高亮）
ui_hint_kv() {
  printf '   %s%s%s  %s\n' "${C_NUM}" "$(pad "$1" 16)" "${C_RESET}" "$2"
}

# ui_sum <前缀> <数字> —— 结果区摘要行（键列对齐、值紧跟）
ui_sum() {
  printf '  %s%s%s %s\n' "${C_KEY}" "$1" "${C_RESET}" "$2"
}

# ui_done <文字> —— 「完成 / 未删除任何文件」这类收尾句
ui_done() { printf '  %s%s%s\n' "${C_OK}" "$1" "${C_RESET}"; }

# ui_muted <文字> —— 次要说明文字
ui_muted() { printf '  %s%s%s\n' "${C_DIM}" "$1" "${C_RESET}"; }

# ui_error <文字> —— 错误
ui_error() { printf '%s✗ %s%s\n' "${C_ERR}" "$1" "${C_RESET}"; }
