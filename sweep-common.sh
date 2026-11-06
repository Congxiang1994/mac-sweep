#!/usr/bin/env bash
# sweep-common.sh — mac-sweep 清理脚本公共库
#
# 被 6 支 *-sweep.sh（chrome / vscode / wps / tencent_meeting / cherry-studio /
# workbuddy）source，抽取原先在每个脚本里逐字重复的 ~350 行：
#   参数解析 · UI 组件 · 进度条 · 尺寸/废纸篓工具 · 关键词筛选 ·
#   清单存储（含可选硬防线）· 报告 · 范围闸 · 交互式清理循环
# uninstall-residue.sh 只复用其中与清单无关的部分（UI / 筛选 / 选择解析）。
#
# ── 使用约定（各 sweep 脚本）─────────────────────────────────────────────────
#   set -u
#   source "$(dirname "$0")/sweep-common.sh"    # source 时即完成参数解析
# 之后脚本自行：
#   1) 定义数据目录并校验存在；设置 SWEEP_HOME（rel_label 的基准）与
#      SWEEP_SIZE_DIRS=("标签:路径" ...) —— 报告里的占用统计行
#   2) 可选定义 is_protected()（硬防线；定义后 _add 自动逐路径检查）
#   3) 打印 ui_head / 运行检测提示，写扫描规则（scan_step + add_target/add_group）
#   4) 可选定义 sweep_extra_notes()（报告区的自定义旁注，如「保护中」规模提示）
#   5) 设好 SCAN_TOTAL（= scan_step 调用次数，进度条分母），finish_progress 后
#      调用 sweep_finish —— 筛选 → 报告 → 范围闸 → 交互清理 → 结果，一条龙
#
# 可选钩子：
#   sweep_extra_arg <arg> <剩余参数...>   未识别参数先问它；消费多个参数时设
#                                         SWEEP_EXTRA_SHIFT（默认 1），返回 0
#                                         表示已处理，返回 1 交给「未知参数」报错
#   SWEEP_REPORT_TSV=1                    --report 不再是 --scan 别名，值存入
#                                         REPORT_FILE（uninstall-residue 用）
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进
#    变量名，在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。
#    大括号可彻底杜绝。

# ── 视觉层先加载 ─────────────────────────────────────────────────────────────
# 必须排在参数解析之前：参数错误（如未知参数）也要用统一 UI 输出。
# 幂等：各脚本可能已自行 source 过，这里用 declare -F 判重。
if ! declare -F ui_banner >/dev/null 2>&1; then
  # shellcheck source=sweep-ui.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep-ui.sh"
fi

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
AGGRESSIVE=0
SCAN_ONLY=0
declare -a FILTERS=()          # 关键词（类别名 / 条目名 / 路径子串）
declare -a FILTER_JOINS=()     # 每个词前导连接符：or（默认）/ and
LAST_JOIN="or"                 # --and / --or 只对「下一个词」生效
declare -a SWEEP_SIZE_DIRS=()  # "标签:路径"，报告区的占用统计行

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

# 词可以写成 log,crash 或 --only log,crash：按逗号拆开逐个入列。
# 逗号展开的词共用同一个前导连接符；每组里只有第一个词带 and 语义。
add_filter_list() {  # add_filter_list <逗号分隔的词串> [join]
  local raw="${1:-}" j="${2:-${LAST_JOIN}}" one first=1
  [ -n "${raw}" ] || return 0
  while :; do
    case "${raw}" in
      *,*) one="${raw%%,*}"; raw="${raw#*,}" ;;
      *)   one="${raw}";     raw="" ;;
    esac
    if [ -n "${one}" ]; then
      if [ "${first}" -eq 1 ] && [ "${#FILTERS[@]}" -gt 0 ]; then
        FILTER_JOINS+=("${j}")
      else
        FILTER_JOINS+=("or")
      fi
      FILTERS+=("${one}")
      first=0
    fi
    [ -n "${raw}" ] || break
  done
  LAST_JOIN="${j}"
}

# 筛选词是否有判别力：--yes 放大器不允许「/」「.」「e」这类几乎命中一切的平凡词。
# 与「不带筛选全清」等价，正是范围闸要堵的东西。
is_meaningful_filter() {
  local f="${1:-}"
  # 平凡词 = 只由分隔符/点组成，或恰好是路径里必然出现的单字符，
  # 这类词会命中一切，等价于 --clean --all --yes。
  # 「IM」「日志」「隐私」等短词是有效筛选，不能按长度一刀切。
  case "${f}" in
    ''|*/*|*.*) return 1 ;;
  esac
  # 去掉空白与常见标点后若为空，说明无任何判别力（中文词不受影响）
  local stripped
  stripped=$(printf '%s' "${f}" | LC_ALL=C tr -d '[:space:]._-')
  [ -n "${stripped}" ] || return 1
  return 0
}
filters_are_meaningful() {
  local f
  for f in "${FILTERS[@]}"; do
    is_meaningful_filter "${f}" && return 0
  done
  return 1
}

# ── 参数解析（source 时立即执行）─────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  arg="$1"
  case "${arg}" in
    --clean)      CLEAN=1; shift ;;
    --all)        SHOW_ALL=1; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --scan|--dry-run) SCAN_ONLY=1; shift ;;
    --report)
      if [ "${SWEEP_REPORT_TSV:-0}" -eq 1 ]; then
        REPORT_FILE="${2:-}"
        if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      else
        SCAN_ONLY=1; shift
      fi ;;
    --only)
      # 不能把紧随其后的选项吞成关键词（--clean --only --yes 曾静默改模式）
      case "${2:-}" in
        ''|-*) ui_error "--only 需要一个筛选词（不能是选项）"; exit 2 ;;
      esac
      add_filter_list "${2:-}"
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi ;;
    --and|--or)
      [ "${arg}" = "--and" ] && LAST_JOIN="and" || LAST_JOIN="or"
      shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed '/^#$/d' | sed '1{/^#!/d;}'; exit 0 ;;
    -*)
      # 未知「-」选项：先问脚本的钩子（uninstall 的 --system / --min-age 等）
      SWEEP_EXTRA_SHIFT=1
      if declare -F sweep_extra_arg >/dev/null 2>&1 && sweep_extra_arg "${arg}" "${@:2}"; then
        shift "${SWEEP_EXTRA_SHIFT}"
      else
        ui_error "未知参数: ${arg}（-h 查看用法）"; exit 2
      fi ;;
    *)
      # 裸词 = 筛选关键词
      add_filter_list "${arg}"; shift ;;
  esac
done
unset arg SWEEP_EXTRA_SHIFT 2>/dev/null || true

# --yes 是个放大器：只允许配合有判别力的筛选条件用，绝不允许「不带筛选地全删」
if [ "${ASSUME_YES}" -eq 1 ]; then
  if [ "${CLEAN}" -ne 1 ]; then
    ui_error "--yes 需与 --clean 一起用。"; exit 2
  fi
  if ! have_filters || ! filters_are_meaningful; then
    ui_error "--yes 必须带有判别力的筛选条件（如 --clean cache --yes）—— --all 不算筛选。"
    ui_muted "「/」「.」「e」这类平凡词会命中一切，等价于 --clean --all --yes，同样堵死。"
    exit 2
  fi
fi

today=$(date +%Y-%m-%d)
now=$(date +%s)

# ═════════════════════════════════════════════════════════════════════════════
# 输出组件
#   色彩与版式全部来自 sweep-ui.sh（统一视觉层），这里只保留兼容旧调用的薄封装。
#   颜色开关：SWEEP_COLOR=always|never|auto / NO_COLOR / FORCE_COLOR
# ═════════════════════════════════════════════════════════════════════════════

# ui_head <标题> [键 值...] —— 兼容旧签名：旧调用传的是「键␣␣值」整行
ui_head() {
  local title="$1"; shift
  ui_banner "${title}"
  local l key val
  for l in "$@"; do
    [ -n "${l}" ] || continue
    # 旧格式是「键␣␣值」，拆开后交给新的 ui_kv 做列对齐
    case "${l}" in
      *"  "*)
        key="${l%%  *}"
        val="${l#*  }"
        # 去掉值前面的残留空格（列宽由 ui_kv 统一负责）
        while :; do
          case "${val}" in
            " "*) val="${val# }" ;;
            *) break ;;
          esac
        done
        ui_kv "${key}" "${val}"
        ;;
      *) ui_kv "${l}" "" ;;
    esac
  done
  ui_rule
}


# ── 进度条（写 stderr，stdout 保持干净的报告文本）──
SHOW_PROGRESS=0
{ [ -t 2 ] || [ -n "${FORCE_PROGRESS:-}" ]; } && SHOW_PROGRESS=1

PROG_TOTAL=0
PROG_DONE=0
PROG_NEXT=0
PROG_LABEL=""
PROG_SPIN=0    # 转轮帧计数器（draw_progress 每次推进）
SCAN_TOTAL=0   # 各脚本设为 scan_step 的调用次数（进度条分母）

draw_progress() {  # draw_progress <done> <total> <label>
  [ "${SHOW_PROGRESS}" -eq 1 ] || return 0
  local done="$1" total="$2" label="$3"
  local width=24 pct filled bar i cut
  [ "${total}" -gt 0 ] || total=1
  [ "${done}" -gt "${total}" ] && done="${total}"
  pct=$(( done * 100 / total ))
  filled=$(( pct * width / 100 ))
  bar=""
  i=0
  while [ "${i}" -lt "${filled}" ]; do bar="${bar}#"; i=$((i + 1)); done
  while [ "${i}" -lt "${width}" ]; do bar="${bar}."; i=$((i + 1)); done
  # 标签太长会顶穿行宽，只留尾部（纯 bash 截断，不 fork）
  if [ "${#label}" -gt 34 ]; then
    cut=$(( ${#label} - 33 ))
    label="…${label:${cut}}"
  fi
  # 动画：旋转轮 + 颜色（轮在进度条尾部转，完成后变对勾）
  PROG_SPIN=$(( (PROG_SPIN + 1) % 10 ))
  local frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local spin tick
  if [ "${pct}" -ge 100 ]; then
    tick="${C_OK}✔${C_RESET}"
  else
    tick="${C_SIZE}${frames:${PROG_SPIN}:1}${C_RESET}"
  fi
  local pct_col="${C_BOLD}"
  [ "${pct}" -ge 100 ] && pct_col="${C_OK}"
  printf '\r  %s[%s%s%s]%s %s%3d%%%s  %s\033[K' \
    "${C_DIM}" "${C_NUM}" "${bar}" "${C_RESET}" "${C_DIM}" \
    "${pct_col}" "${pct}" "${C_RESET}" "${label} ${tick}" >&2
}

scan_step() {  # scan_step <label>：每完成一个扫描段落推进一格
  PROG_DONE=$((PROG_DONE + 1))
  # 分母以 max(声明值, 实际推进数) 为准，手工 SCAN_TOTAL 写小了也不会卡在 94%
  local total="${SCAN_TOTAL}"
  [ "${PROG_DONE}" -gt "${total}" ] && total="${PROG_DONE}"
  draw_progress "${PROG_DONE}" "${total}" "$1"
}

progress_tick() {  # progress_tick <label>：每 20 条或换了目录时重画一次（uninstall 用）
  PROG_DONE=$((PROG_DONE + 1))
  if [ "${PROG_DONE}" -ge "${PROG_NEXT}" ] || [ "$1" != "${PROG_LABEL}" ]; then
    draw_progress "${PROG_DONE}" "${PROG_TOTAL}" "$1"
    PROG_NEXT=$((PROG_DONE + 20))
    PROG_LABEL="$1"
  fi
}

finish_progress() {
  [ "${SHOW_PROGRESS}" -eq 1 ] || return 0
  # PROG_TOTAL 默认 0（已设值，:- 不会回落），必须用实际推进数收尾，
  # 否则会画出 0% 的「扫描完成」把刚跑到 100% 的进度条打回去。
  local total="${PROG_DONE}"
  [ "${total}" -gt 0 ] || total="${SCAN_TOTAL}"
  [ "${total}" -gt 0 ] || total=1
  draw_progress "${total}" "${total}" "扫描完成"
  printf '\n' >&2
}

# ═════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═════════════════════════════════════════════════════════════════════════════

human() {  # KB → 人类可读（纯 bash，避免每条路径都 fork 一个 awk）
  local kb="${1:-0}"
  case "${kb}" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "${kb}" -ge 1048576 ]; then
    printf '%d.%dG' "$((kb / 1048576))" "$(( (kb % 1048576) * 10 / 1048576 ))"
  elif [ "${kb}" -ge 1024 ]; then
    printf '%d.%dM' "$((kb / 1024))" "$(( (kb % 1024) * 10 / 1024 ))"
  else
    printf '%dK' "${kb}"
  fi
}

id_lc() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }

kb_of() {  # 单个路径的 KB
  local kb
  kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  printf '%s' "${kb:-0}"
}

kb_of_multi() {  # 多个路径合计 KB
  local kb
  kb=$(du -ck "$@" 2>/dev/null | tail -1 | cut -f1 | tr -dc '0-9')
  printf '%s' "${kb:-0}"
}

# 展示用短标签：SWEEP_HOME 内 → 相对路径；HOME 内 → ~/...；其余原样
rel_label() {
  local p="$1"
  case "${p}" in
    "${SWEEP_HOME}"/*)  printf '%s' "${p#"${SWEEP_HOME}"/}" ;;
    "${HOME}"/*)        printf '~/%s' "${p#"${HOME}"/}" ;;
    *)                  printf '%s' "${p}" ;;
  esac
}

# 进程是否仍存在（ps 在受限环境可能不可用，用 kill -0 兜底）
proc_alive() {
  local pid="${1:-}"
  case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
  ps -p "${pid}" >/dev/null 2>&1 && return 0
  kill -0 "${pid}" 2>/dev/null && return 0
  return 1
}

# 移入废纸篓（不是 rm，随时可以拖回来）
trash_path() {
  local p="$1" base dest trash="${HOME}/.Trash" n=0
  # 断链符号链接 [ -e ] 为假，但它是真实存在的目录项，必须一并处理
  [ -e "${p}" ] || [ -L "${p}" ] || return 0
  mkdir -p "${trash}" 2>/dev/null || return 1
  base=$(basename "${p}")
  dest="${trash}/${base}"
  # 同名冲突用递增序号避让：秒级时间戳在同一秒内多个同名项会撞车并互相覆盖。
  while [ -e "${dest}" ] || [ -L "${dest}" ]; do
    n=$((n + 1))
    dest="${trash}/${base} $(date +%Y%m%d-%H%M%S)-${n}"
  done
  mv "${p}" "${dest}"
  if [ -e "${p}" ] || [ -L "${p}" ]; then return 1; fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# 选择解析
# ═════════════════════════════════════════════════════════════════════════════

select_prompt() {  # select_prompt <剩余项数>
  printf '\n%s要清理哪些？%s\n' "${C_BOLD}" "${C_RESET}"
  ui_hint_kv "yes / all" "全部移入废纸篓"
  ui_hint_kv "编号" "如 1 3 5、1-4、1,3（只处理这些）"
  ui_hint_kv "pick" "逐项确认（y=移入 n=跳过 q=结束）"
  ui_hint_kv "q 或回车" "结束，未处理的项原样不动"
  ui_prompt
}

# 解析输入 → ACT（all|some|pick|cancel），编号存 CHOICE_NUMS
parse_choice() {  # parse_choice <输入> <最大编号>
  local input="$1" max="$2" tok a b i
  CHOICE_NUMS=()
  ACT=""
  input=$(printf '%s' "${input}" | LC_ALL=C tr ',' ' ')
  if [ -z "${input}" ]; then ACT="cancel"; return 0; fi
  for tok in ${input}; do
    case "${tok}" in
      all|ALL|All|yes|YES|Yes) ACT="all";  return 0 ;;
      pick|PICK|Pick)          ACT="pick"; return 0 ;;
      q|Q|quit|QUIT|none|NONE) ACT="cancel"; return 0 ;;
    esac
    # 先严格校验形态：只允许纯数字，或恰含一个连字符的 a-b。
    # 挡住 -1 / 1- / 1-2-3 / 前导零 / 超大整数（bash 3.2 的 [ 会对超 64 位报错）。
    case "${tok}" in
      *[!0-9-]*|''|*-*-*|-*|*-|*--*) return 1 ;;
    esac
    case "${tok}" in
      *-*)
        a="${tok%%-*}"; b="${tok##*-}"
        [ "${#a}" -gt 9 ] || [ "${#b}" -gt 9 ] && return 1
        a=$((10#${a})); b=$((10#${b}))
        if [ "${a}" -lt 1 ] || [ "${b}" -gt "${max}" ] || [ "${a}" -gt "${b}" ]; then return 1; fi
        i="${a}"
        while [ "${i}" -le "${b}" ]; do CHOICE_NUMS+=("${i}"); i=$((i + 1)); done ;;
      *)
        [ "${#tok}" -gt 9 ] && return 1
        tok=$((10#${tok}))
        if [ "${tok}" -lt 1 ] || [ "${tok}" -gt "${max}" ]; then return 1; fi
        CHOICE_NUMS+=("${tok}") ;;
    esac
  done
  if [ "${#CHOICE_NUMS[@]}" -eq 0 ]; then ACT="cancel"; return 0; fi
  ACT="some"
  return 0
}

# 编号去重（同一项被写两次也只处理一遍）
dedupe_nums() {  # dedupe_nums <编号...> → UNIQ_NUMS
  UNIQ_NUMS=()
  local n seen one
  for n in "$@"; do
    seen=0
    for one in ${UNIQ_NUMS[@]+"${UNIQ_NUMS[@]}"}; do
      [ "${one}" = "${n}" ] && seen=1 && break
    done
    [ "${seen}" -eq 0 ] && UNIQ_NUMS+=("${n}")
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# 筛选匹配
#   · 每个词带自己的前导连接符（FILTER_JOINS[i]），按序求值：
#       a b --and c  =  (a 或 b) 且 c
#       a --and b c  =  a 且 (b 或 c)   ← 连接符只作用于紧随其后的那个词
#   · --or 只是把「下一个词」的前导连接符设回 or，不会改变前面已算出的结果
# ═════════════════════════════════════════════════════════════════════════════

word_hits() {  # word_hits <lname> <litems> <小写词>；命中返回 0
  case "$1" in *"$3"*) return 0 ;; esac
  case "$2" in *"$3"*) return 0 ;; esac
  return 1
}

matches_filters() {  # matches_filters <name> <items>；无关键词时恒真
  ! have_filters && return 0
  local lname litems
  lname=$(id_lc "$1")
  litems=$(printf '%s' "$2" | LC_ALL=C tr 'A-Z' 'a-z')
  local i=0 n=${#FILTERS[@]} hit j
  # 按连接符切成若干「或组」：连续 or 词归一组，and 词另起一组，组间求交
  while [ "${i}" -lt "${n}" ]; do
    hit=0
    j="${i}"
    while [ "${j}" -lt "${n}" ]; do
      if [ "${j}" -gt "${i}" ] && [ "${FILTER_JOINS[$j]:-or}" = "and" ]; then break; fi
      word_hits "${lname}" "${litems}" "$(id_lc "${FILTERS[$j]}")" && hit=1
      j=$((j + 1))
    done
    [ "${hit}" -eq 1 ] || return 1
    i="${j}"
  done
  return 0
}

filters_desc() {
  local out="" n=${#FILTERS[@]} i=0
  while [ "${i}" -lt "${n}" ]; do
    if [ -n "${out}" ]; then
      out="${out} "
      if [ "${FILTER_JOINS[$i]:-or}" = "and" ]; then out="${out}且 "; else out="${out}或 "; fi
    fi
    out="${out}\"${FILTERS[$i]}\""
    i=$((i + 1))
  done
  printf '%s' "${out}"
}

# ═════════════════════════════════════════════════════════════════════════════
# 清单存储
# ═════════════════════════════════════════════════════════════════════════════

# ═════════════════════════════════════════════════════════════════════════════
# 硬防线：用户数据保护名单（全系列共用的 Chromium / Electron 基线）
#   各脚本可追加自己的业务项：PROTECT_PATTERNS="${PROTECT_PATTERNS}
# 自定义项"
#   ⚠️ _add 会对每条路径及其目录内部做检查，扫描规则写错也碰不到这些。
# ═════════════════════════════════════════════════════════════════════════════
PROTECT_PATTERNS='
Cookies
Cookies-journal
Cookies-wal
Cookies-shm
Login Data
Login Data-journal
Login Data-wal
Login Data-shm
Web Data
Web Data-journal
Bookmarks
Bookmarks.bak
History
History-journal
History-wal
History-shm
Sessions
Session Storage
Session Store
IndexedDB
Local Storage
WebStorage
Preferences
Secure Preferences
Favicons
Top Sites
Shortcuts
Trust Tokens
Trust Tokens-journal
Local State
state.vscdb
state.vscdb.backup
storage.json
settings.json
session-store.db
session-store.db-wal
session-store.db-shm
backup
OfficeSpace
WPS Cloud Files
tokenTable.ini
'

# is_protected <路径> → basename 命中保护名单返回 0。
# 各脚本若需自定义，在 source 之后重新定义本函数即可（declare -F 判断的是最终版本）。
is_protected() {
  local comp line
  comp=$(basename "$1")
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
}

# 目录内部是否含受保护的子项（WPS cef/cache 整目录清曾把内层 Cookies 一起带走）。
# ⚠️ 只对脚本显式声明的目录生效：PROTECT_RECURSE_DIRS=("关键字"...)，路径含关键字才查。
#    不能无差别递归 —— vscode 的「孤立工作区」本身就是主动要清的目录，
#    里面的 state.vscdb 属于工作区状态，正是清理目标，不该被当保护层。
declare -a PROTECT_RECURSE_DIRS=()
dir_has_protected() {
  local d="$1" f pat hit=0
  [ -d "${d}" ] || return 1
  for pat in ${PROTECT_RECURSE_DIRS[@]+"${PROTECT_RECURSE_DIRS[@]}"}; do
    case "${d}" in *"${pat}"*) hit=1; break ;; esac
  done
  [ "${hit}" -eq 1 ] || return 1
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    is_protected "${f}" && return 0
  done < <(find "${d}" -maxdepth 2 -mindepth 1 \( -type f -o -type d \) 2>/dev/null)
  return 1
}

declare -a T_PATHS=()   # 路径（组则为换行分隔的多路径）
declare -a T_SIZES=()   # 大小 KB
declare -a T_LABELS=()  # 展示名
declare -a T_CATS=()    # 所属类别
TOTAL_KB=0
PROTECTED_SKIPPED=0

# _add：加入清单。硬防线逐路径检查（含目录内部），命中即剔除；
# 组里部分路径被剔除后按剩余路径重算大小，避免报告「合计」虚报。
_add() {  # _add <cat> <label> <kb> <keep_zero> <路径...>
  local cat="$1" label="$2" kb="$3" keep="$4"; shift 4
  [ "$#" -gt 0 ] || return 0
  local clean_list=() p bad=0
  for p in "$@"; do
    if is_protected "${p}" || dir_has_protected "${p}"; then
      PROTECTED_SKIPPED=$((PROTECTED_SKIPPED + 1))
      bad=1
    else
      clean_list+=("${p}")
    fi
  done
  [ "${bad}" -eq 1 ] && [ "${#clean_list[@]}" -eq 0 ] && return 0
  if [ "${bad}" -eq 1 ]; then
    set -- "${clean_list[@]}"
    kb=$(kb_of_multi "$@")
  fi
  [ "${kb}" -eq 0 ] && [ "${keep}" -ne 1 ] && return 0
  local joined; joined=$(printf '%s\n' "$@")
  T_PATHS+=("${joined}"); T_SIZES+=("${kb}")
  T_LABELS+=("${label}"); T_CATS+=("${cat}")
  TOTAL_KB=$((TOTAL_KB + kb))
}

add_target() {  # add_target <cat> <path> [label]
  local cat="$1" path="$2" label="${3:-}"
  [ -e "${path}" ] || return 0
  [ -n "${label}" ] || label=$(rel_label "${path}")
  _add "${cat}" "${label}" "$(kb_of "${path}")" 0 "${path}"
}

add_group() {  # add_group <cat> <label> <kb> <path...> —— 聚合多条路径为一项
  local cat="$1" label="$2" kb="$3"; shift 3
  _add "${cat}" "${label}" "${kb}" 0 "$@"
}

# 尺寸为 0 也要保留（空目录不占空间，但列表里得有它）
add_group_keep0() {  # add_group_keep0 <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add "${cat}" "${label}" "${kb}" 1 "$@"
}

# 占用统计行：遍历 SWEEP_SIZE_DIRS 打 "标签: 大小"
sweep_print_sizes() {  # sweep_print_sizes <前缀>
  local entry label path sz pre
  pre="$1"
  [ -n "${pre}" ] || pre=""
  for entry in ${SWEEP_SIZE_DIRS[@]+"${SWEEP_SIZE_DIRS[@]}"}; do
    label="${entry%%:*}"
    path="${entry#*:}"
    sz=$(du -sh "${path}" 2>/dev/null | cut -f1)
    [ -n "${sz}" ] || sz="不存在"
    if [ -n "${pre}" ]; then
      printf '  %s%s%s %s: %s\n' "${C_KEY}" "${pre}" "${C_RESET}" "${label}" "${sz}"
    else
      printf '  %s%s: %s%s\n' "${C_KEY}" "${label}" "${sz}" "${C_RESET}"
    fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# sweep_finish：筛选 → 报告 → 范围闸 → 交互清理 → 结果
# 调用前提：扫描已完成（finish_progress 已调用），可选的 sweep_extra_notes
# 已定义，SWEEP_SIZE_DIRS 已设置。
# ═════════════════════════════════════════════════════════════════════════════
sweep_finish() {

  # ── 应用筛选 ──
  declare -a S_IDX=()
  local i
  i=0
  while [ "${i}" -lt "${#T_PATHS[@]}" ]; do
    if matches_filters "${T_CATS[$i]} ${T_LABELS[$i]}" "${T_PATHS[$i]}"; then
      S_IDX+=("${i}")
    fi
    i=$((i + 1))
  done

  local n_sel=${#S_IDX[@]}
  local sel_kb=0
  for i in ${S_IDX[@]+"${S_IDX[@]}"}; do
    sel_kb=$((sel_kb + ${T_SIZES[$i]}))
  done

  # ── 报告 ──
  ui_section "扫描结果"

  if [ "${n_sel}" -eq 0 ]; then
    if [ "${#T_PATHS[@]}" -eq 0 ]; then
      ui_ok "没有可清理的垃圾（已经干净）。"
    else
      ui_muted "没有匹配「$(filters_desc)」的项（清单里共 ${#T_PATHS[@]} 项）。"
      ui_muted "去掉关键词即可看到完整清单。"
    fi
    sweep_print_sizes ""
    echo
    ui_done "包含扫描在内，未删除任何文件。"
    exit 0
  fi

  local prev_cat="" num=0
  for i in "${S_IDX[@]}"; do
    num=$((num + 1))
    if [ "${T_CATS[$i]}" != "${prev_cat}" ]; then
      ui_cat "${T_CATS[$i]}"
      prev_cat="${T_CATS[$i]}"
    fi
    ui_item "[$(printf '%02d' "${num}")]" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}"
  done

  echo
  ui_end
  ui_sum "命中" "${n_sel} 项 / 预计释放 $(human "${sel_kb}")"
  if have_filters && [ "${n_sel}" -lt "${#T_PATHS[@]}" ]; then
    ui_muted "另有 $(( ${#T_PATHS[@]} - n_sel )) 项未命中筛选，未计入"
  fi
  sweep_print_sizes "清理前 "

  if [ "${PROTECTED_SKIPPED}" -gt 0 ]; then
    ui_note "🛡️  硬防线拦截：${PROTECTED_SKIPPED} 处命中用户数据保护名单，已强制排除"
  fi
  declare -F sweep_extra_notes >/dev/null 2>&1 && sweep_extra_notes

  # ── 只扫描模式 / --scan：报告完就结束 ──
  if [ "${SCAN_ONLY}" -eq 1 ]; then
    echo
    ui_done "只扫描模式（--scan）：未删除任何文件。"
    exit 0
  fi

  # ── 范围闸：裸 --clean 什么都不会动 ────────────────────────────────────────
  # 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
  # 要么给关键词筛选，要么显式写 --all。
  if [ "${CLEAN}" -eq 1 ] && ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
    echo >&2
    ui_error "没有指定范围，本次不会动任何文件。"
    ui_muted "只清几项：    bash $0 --clean <关键词>     # 多个词用空格或逗号"
    ui_muted "全部都要清：  bash $0 --clean --all"
    exit 2
  fi

  # ── 交互式清理：列剩余清单 → 选 → 移入废纸篓 → 还有剩余就再问，直到结束 ──

  render_brief() {  # render_brief <显示编号> <内部索引>
    ui_item_cat "[$(printf '%02d' "$1")]" "$(human "${T_SIZES[$2]}")" \
                "${T_LABELS[$2]}" "${T_CATS[$2]}"
  }

  render_paths() {  # render_paths <内部索引>
    local one
    while IFS= read -r one; do
      [ -n "${one}" ] || continue
      ui_path "${one}"
    done <<< "${T_PATHS[$1]}"
  }

  move_group() {  # move_group <内部索引> → 全部成功返回 0，否则 1
    local idx="$1" one one_kb gfail=0
    while IFS= read -r one; do
      [ -n "${one}" ] || continue
      one_kb=$(kb_of "${one}")   # 移动前实测，成功才计入释放空间
      if trash_path "${one}"; then
        FREED_KB=$((FREED_KB + one_kb))
        printf '  %s[废纸篓]%s %s\n' "${C_OK}" "${C_RESET}" "${one}"
      else
        printf '  %s[失败]%s   %s\n' "${C_ERR}" "${C_RESET}" "${one}"
        gfail=$((gfail + 1))
      fi
    done <<< "${T_PATHS[$idx]}"
    [ "${gfail}" -eq 0 ]
  }

  declare -a REM_IDX=( ${S_IDX[@]+"${S_IDX[@]}"} )   # 待处理（显示顺序 = 数组顺序）
  declare -a CHOSEN=()
  declare -a UNIQ_NUMS=()
  CHOICE_NUMS=()
  ACT=""
  ok=0; fail=0; moved_paths=0; round=0; FREED_KB=0
  local n c one one_kb a2 a3 hit moved_now

  while [ "${#REM_IDX[@]}" -gt 0 ]; do
    round=$((round + 1))

    local rem_kb=0
    for i in "${REM_IDX[@]}"; do rem_kb=$((rem_kb + ${T_SIZES[$i]})); done

    ui_section "第 ${round} 轮 · 待处理 ${#REM_IDX[@]} 项 / 预计释放 $(human "${rem_kb}")（编号以本轮为准）"
    n=0
    for i in "${REM_IDX[@]}"; do
      n=$((n + 1))
      render_brief "${n}" "${i}"
    done

    # --yes（必须带筛选）：跳过交互，直接处理全部
    if [ "${ASSUME_YES}" -eq 1 ] && [ "${round}" -eq 1 ]; then
      ACT="all"; CHOSEN=( ${REM_IDX[@]+"${REM_IDX[@]}"} )
    else
      select_prompt "${#REM_IDX[@]}"
      local ans=""
      read -r ans || ans=""
      if ! parse_choice "${ans}" "${#REM_IDX[@]}"; then
        ui_warn "看不懂这个输入（可用：yes / 编号 / 1-4 / 1,3 / pick / q）。本次没有处理任何项。"
        continue
      fi
      case "${ACT}" in
        cancel)
          ui_muted "结束，未处理的项原样不动。"
          break ;;
        all)
          CHOSEN=( ${REM_IDX[@]+"${REM_IDX[@]}"} ) ;;
        pick)
          CHOSEN=()
          n=0
          for i in "${REM_IDX[@]}"; do
            n=$((n + 1))
            ui_item_cat "[$(printf '%02d' "${n}")]" "$(human "${T_SIZES[$i]}")" \
                        "${T_LABELS[$i]}" "${T_CATS[$i]}"
            render_paths "${i}"
            printf '      %s移入废纸篓？%s [y/N/s/q] ' "${C_BOLD}" "${C_RESET}"
            a2=""
            read -r a2 || a2="q"
            case "${a2}" in
              y|Y) CHOSEN+=("${i}") ;;
              q|Q) ui_muted "结束逐项确认。"; break ;;
              s|S)
                # ⚠️ 先把路径收进数组：herestring 的重定向作用于整个循环体，
                #    循环体里的交互 read 会去读 EOF 的 herestring，必须先收进数组。
                declare -a sp=() left=()
                while IFS= read -r one; do
                  [ -n "${one}" ] || continue
                  sp+=("${one}")
                done <<< "${T_PATHS[$i]}"
                for one in ${sp[@]+"${sp[@]}"}; do
                  printf '        %s%s%s ? [y/N] ' "${C_DIM}" "${one}" "${C_RESET}"
                  a3=""
                  read -r a3 || a3="n"
                  case "${a3}" in
                  y|Y) one_kb=$(kb_of "${one}")
                       if trash_path "${one}"; then
                         FREED_KB=$((FREED_KB + one_kb))
                         printf '          %s[废纸篓]%s 已移入\n' "${C_OK}" "${C_RESET}"
                         moved_paths=$((moved_paths + 1))
                       else
                         printf '          %s[失败]%s   无法移动（可能需要权限）\n' "${C_ERR}" "${C_RESET}"
                         fail=$((fail + 1))
                         left+=("${one}")
                       fi ;;
                  *)  left+=("${one}") ;;   # ⭐ 答 n / 默认跳过：原样留在清单里
                  esac
                done
                # 只把「剩余未处理路径」写回该组；绝不能再把整组交给 move_group，
                # 否则用户答 n 的路径会被随后的全组 mv 一起移走（旧版真 bug）。
                if [ "${#left[@]}" -gt 0 ]; then
                  T_PATHS[$i]=$(printf '%s\n' "${left[@]}")
                  T_SIZES[$i]=$(kb_of_multi "${left[@]}")
                else
                  T_PATHS[$i]=""
                fi
                ;;
              *) ui_muted "跳过" ;;
            esac
          done
          ;;
        some)
          CHOSEN=()
          dedupe_nums ${CHOICE_NUMS[@]+"${CHOICE_NUMS[@]}"}
          n=0
          for i in "${REM_IDX[@]}"; do
            n=$((n + 1))
            for one in ${UNIQ_NUMS[@]+"${UNIQ_NUMS[@]}"}; do
              [ "${one}" = "${n}" ] && CHOSEN+=("${i}") && break
            done
          done ;;
      esac
    fi

    if [ "${#CHOSEN[@]}" -eq 0 ]; then
      continue
    fi

    # ── 执行 ──
    ui_section "移入废纸篓"
    declare -a NEXT_REM=()
    moved_now=0
    # 执行阶段进度条：分母 = 本轮待处理项数（只在实际移入时推进）
    local n_total=0 n_done=0
    for i in "${REM_IDX[@]}"; do
      [ -n "${T_PATHS[$i]}" ] || continue
      local c2; for c2 in "${CHOSEN[@]}"; do [ "${c2}" = "${i}" ] && n_total=$((n_total + 1)) && break; done
    done
    for i in "${REM_IDX[@]}"; do
      # pick 的 s 模式若把该组所有路径都处理完，清单被清空，不必再执行
      [ -n "${T_PATHS[$i]}" ] || continue
      hit=0
      for c in "${CHOSEN[@]}"; do
        [ "${c}" = "${i}" ] && hit=1 && break
      done
      if [ "${hit}" -eq 1 ]; then
        n_done=$((n_done + 1))
        # 单行动画进度条：移入中 (n/total) + 转轮，处理完该项后再画下一帧。
        # 走 stderr、\r 原地刷新；stdout 仍保持干净（清单行照常输出）。
        if [ "${SHOW_PROGRESS}" -eq 1 ]; then
          local sp frames="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
          PROG_SPIN=$(( (PROG_SPIN + 1) % 10 ))
          sp="${frames:${PROG_SPIN}:1}"
          printf '\r  %s移入中%s %s%s/%s%s  %s  %s%s%s\033[K' \
            "${C_BOLD}" "${C_RESET}" \
            "${C_NUM}" "${n_done}" "${n_total}" "${C_RESET}" \
            "$(human "${T_SIZES[$i]}")" \
            "${C_SIZE}" "${sp}" "${C_RESET}" >&2
        fi
        ui_item_cat "" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}" "${T_CATS[$i]}"
        if move_group "${i}"; then
          ok=$((ok + 1))
          moved_now=$((moved_now + 1))
        else
          fail=$((fail + 1))
          # 部分失败：留在剩余清单里，下一轮可重试（旧版会无条件下架）
          NEXT_REM+=("${i}")
        fi
        echo
      else
        NEXT_REM+=("${i}")
      fi
    done
    # 清掉执行进度行，结果区不被残影污染（非 TTY 时 SHOW_PROGRESS=0，无副作用）
    [ "${SHOW_PROGRESS}" -eq 1 ] && printf '\r\033[K' >&2
    REM_IDX=( ${NEXT_REM[@]+"${NEXT_REM[@]}"} )
    ui_sum "本轮处理" "${moved_now} 项；剩余待处理 ${#REM_IDX[@]} 项"
  done

  # ── 收尾 ──
  ui_section "结果"
  ui_sum "成功" "${ok} 项"
  [ "${fail}" -gt 0 ] && ui_sum "失败" "${fail} 项"
  [ "${#REM_IDX[@]}" -gt 0 ] && ui_sum "剩余未处理" "${#REM_IDX[@]} 项"
  [ "${moved_paths}" -gt 0 ] && ui_sum "其中逐条确认移入" "${moved_paths} 个文件"
  [ "${FREED_KB}" -gt 0 ] && ui_sum "移入废纸篓合计" "$(human "${FREED_KB}")"
  sweep_print_sizes "清理后 "
  if [ "${ok}" -gt 0 ] || [ "${moved_paths}" -gt 0 ]; then
    ui_muted "这些内容现在在 ${HOME}/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。"
  else
    ui_muted "未移动任何文件。"
  fi
  ui_end
}
