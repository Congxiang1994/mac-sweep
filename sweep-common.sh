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

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
AGGRESSIVE=0
SCAN_ONLY=0
declare -a FILTERS=()          # 关键词（类别名 / 条目名 / 路径子串）
JOIN_MODE="or"                 # or = 并集（默认）；and = 交集
LAST_JOIN="or"                 # 最近一个关键词挂的连接符，逗号展开时沿用
declare -a SWEEP_SIZE_DIRS=()  # "标签:路径"，报告区的占用统计行

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

# 词可以写成 log,crash 或 --only log,crash：按逗号拆开逐个入列
add_filter_list() {  # add_filter_list <逗号分隔的词串> [join]
  local raw="${1:-}" j="${2:-${LAST_JOIN}}" one
  [ -n "${raw}" ] || return 0
  while :; do
    case "${raw}" in
      *,*) one="${raw%%,*}"; raw="${raw#*,}" ;;
      *)   one="${raw}";     raw="" ;;
    esac
    [ -n "${one}" ] && FILTERS+=("${one}")
    [ -n "${raw}" ] || break
  done
  LAST_JOIN="${j}"
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
      add_filter_list "${2:-}"
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi ;;
    --and|--or)
      LAST_JOIN="or"
      [ "${arg}" = "--and" ] && LAST_JOIN="and"
      # 连接符只对「下一个词」生效
      if [ "${#FILTERS[@]}" -gt 0 ]; then JOIN_MODE="${LAST_JOIN}"; else JOIN_MODE="or"; fi
      shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0 ;;
    -*)
      # 未知「-」选项：先问脚本的钩子（uninstall 的 --system / --min-age 等）
      SWEEP_EXTRA_SHIFT=1
      if declare -F sweep_extra_arg >/dev/null 2>&1 && sweep_extra_arg "${arg}" "${@:2}"; then
        shift "${SWEEP_EXTRA_SHIFT}"
      else
        echo "未知参数: ${arg}（-h 查看用法）" >&2; exit 2
      fi ;;
    *)
      # 裸词 = 筛选关键词
      add_filter_list "${arg}"; shift ;;
  esac
done
unset arg SWEEP_EXTRA_SHIFT 2>/dev/null || true

# 空转的 --and（后面没跟关键词）不该生效，回落到并集
[ "${#FILTERS[@]}" -gt 0 ] || JOIN_MODE="or"

# --yes 是个放大器：只允许配合明确的筛选条件用，绝不允许「不带筛选地全删」
if [ "${ASSUME_YES}" -eq 1 ]; then
  if [ "${CLEAN}" -ne 1 ]; then
    echo "--yes 需与 --clean 一起用。" >&2; exit 2
  fi
  if ! have_filters; then
    echo "--yes 必须带筛选条件（如 --clean cache --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

today=$(date +%Y-%m-%d)
now=$(date +%s)

# ═════════════════════════════════════════════════════════════════════════════
# 输出组件
# ═════════════════════════════════════════════════════════════════════════════
UI_WIDTH=68

ui_line() {  # ui_line：一条横向分隔线
  local ch="${1:-─}" i=0 out=""
  while [ "${i}" -lt "${UI_WIDTH}" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s\n' "${out}"
}

ui_head() {  # ui_head <标题> [副标题行...]
  ui_line '═'
  printf ' %s\n' "$1"; shift
  local l
  for l in "$@"; do [ -n "${l}" ] && printf ' %s\n' "${l}"; done
  ui_line '═'
}

ui_dashes() {  # 补足分节线长度（中文按 2 列估算）
  local i=0 width=$(( (UI_WIDTH - 8) / 2 ))  # 扣掉「── 」与前后空格
  local len=$(( ${#1} ))
  local need=$(( width - len ))
  local out=""
  [ "${need}" -lt 0 ] && need=0
  while [ "${i}" -lt "${need}" ]; do out="${out}─"; i=$((i + 1)); done
  printf '%s' "${out}"
}

ui_section() {  # ui_section <标题>
  echo
  printf '── %s %s\n' "$1" "$(ui_dashes "$1")"
}

ui_kv() { printf '   %-14s %s\n' "$1" "$2"; }
ui_note() { printf '   · %s\n' "$1"; }
ui_end() { ui_line '─'; }

# ── 进度条（写 stderr，stdout 保持干净的报告文本）──
SHOW_PROGRESS=0
{ [ -t 2 ] || [ -n "${FORCE_PROGRESS:-}" ]; } && SHOW_PROGRESS=1

PROG_TOTAL=0
PROG_DONE=0
PROG_NEXT=0
PROG_LABEL=""
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
  printf '\r  [%s] %3d%%  %s\033[K' "${bar}" "${pct}" "${label}" >&2
}

scan_step() {  # scan_step <label>：每完成一个扫描段落推进一格
  PROG_DONE=$((PROG_DONE + 1))
  draw_progress "${PROG_DONE}" "${SCAN_TOTAL}" "$1"
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
  draw_progress "${PROG_TOTAL:-${SCAN_TOTAL}}" "${PROG_TOTAL:-${SCAN_TOTAL}}" "扫描完成"
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
  local p="$1" base dest trash="${HOME}/.Trash"
  [ -e "${p}" ] || return 0
  mkdir -p "${trash}" 2>/dev/null || return 1
  base=$(basename "${p}")
  dest="${trash}/${base}"
  [ -e "${dest}" ] && dest="${trash}/${base} $(date +%Y%m%d-%H%M%S)"
  mv "${p}" "${dest}" 2>/dev/null
  [ -e "${p}" ] && return 1
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# 选择解析
# ═════════════════════════════════════════════════════════════════════════════

select_prompt() {  # select_prompt <剩余项数>
  printf '\n要清理哪些？\n'
  printf '   yes / all        全部移入废纸篓\n'
  printf '   编号             如 1 3 5、1-4、1,3（只处理这些）\n'
  printf '   pick             逐项确认（y=移入 n=跳过 q=结束）\n'
  printf '   q 或回车         结束，未处理的项原样不动\n'
  printf '> '
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
      *[!0-9-]*)               return 1 ;;
    esac
    case "${tok}" in
      *-*)
        a="${tok%%-*}"; b="${tok##*-}"
        case "${a}${b}" in ''|*[!0-9]*) return 1 ;; esac
        if [ "${a}" -lt 1 ] || [ "${b}" -gt "${max}" ] || [ "${a}" -gt "${b}" ]; then return 1; fi
        i="${a}"
        while [ "${i}" -le "${b}" ]; do CHOICE_NUMS+=("${i}"); i=$((i + 1)); done ;;
      *)
        case "${tok}" in ''|*[!0-9]*) return 1 ;; esac
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
#   · 默认并集（or）——任意一个词命中即算命中
#   · --and 之后的那一个词改为「且」条件，与前面已算出的结果求交
#     a b --and c  =  (a 或 b) 且 c
# ═════════════════════════════════════════════════════════════════════════════

word_hits() {  # word_hits <lname> <litems> <小写词>；命中返回 0
  case "$1" in *"$3"*) return 0 ;; esac
  case "$2" in *"$3"*) return 0 ;; esac
  return 1
}

matches_filters() {  # matches_filters <name> <items>；无关键词时恒真
  ! have_filters && return 0
  local name="$1" items="$2" f
  local lname litems
  lname=$(id_lc "${name}")
  litems=$(printf '%s' "${items}" | LC_ALL=C tr 'A-Z' 'a-z')

  local n=${#FILTERS[@]} i=0 last_or_ok=0
  if [ "${n}" -gt 1 ] && [ "${JOIN_MODE}" = "and" ]; then
    while [ "${i}" -lt "$((n - 1))" ]; do
      if word_hits "${lname}" "${litems}" "$(id_lc "${FILTERS[$i]}")"; then last_or_ok=1; break; fi
      i=$((i + 1))
    done
    [ "${last_or_ok}" -eq 1 ] || return 1
    word_hits "${lname}" "${litems}" "$(id_lc "${FILTERS[$((n - 1))]}")" && return 0
    return 1
  fi

  for f in "${FILTERS[@]}"; do
    word_hits "${lname}" "${litems}" "$(id_lc "${f}")" && return 0
  done
  return 1
}

filters_desc() {
  local out="" n=${#FILTERS[@]} i=0
  while [ "${i}" -lt "${n}" ]; do
    if [ -n "${out}" ]; then
      out="${out} "
      if [ "${JOIN_MODE}" = "and" ] && [ "${i}" -eq "$((n - 1))" ]; then out="${out}且 "; else out="${out}或 "; fi
    fi
    out="${out}\"${FILTERS[$i]}\""
    i=$((i + 1))
  done
  printf '%s' "${out}"
}

# ═════════════════════════════════════════════════════════════════════════════
# 清单存储
# ═════════════════════════════════════════════════════════════════════════════

declare -a T_PATHS=()   # 路径（组则为换行分隔的多路径）
declare -a T_SIZES=()   # 大小 KB
declare -a T_LABELS=()  # 展示名
declare -a T_CATS=()    # 所属类别
TOTAL_KB=0
PROTECTED_SKIPPED=0

# _add：加入清单；脚本若定义了 is_protected()（硬防线），逐路径检查，命中即丢弃
_add() {  # _add <cat> <label> <kb> <keep_zero> <路径...>
  local cat="$1" label="$2" kb="$3" keep="$4"; shift 4
  [ "$#" -gt 0 ] || return 0
  if declare -F is_protected >/dev/null 2>&1; then
    local clean_list=() p bad=0
    for p in "$@"; do
      if is_protected "${p}"; then
        PROTECTED_SKIPPED=$((PROTECTED_SKIPPED + 1))
        bad=1
      else
        clean_list+=("${p}")
      fi
    done
    [ "${bad}" -eq 1 ] && [ "${#clean_list[@]}" -eq 0 ] && return 0
    if [ "${bad}" -eq 1 ]; then set -- "${clean_list[@]}"; fi
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
  local entry label path
  for entry in ${SWEEP_SIZE_DIRS[@]+"${SWEEP_SIZE_DIRS[@]}"}; do
    label="${entry%%:*}"
    path="${entry#*:}"
    printf '   %s%s: %s\n' "$1" "${label}" "$(du -sh "${path}" 2>/dev/null | cut -f1)"
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
      echo "   没有可清理的垃圾（已经干净）。"
    else
      echo "   没有匹配「$(filters_desc)」的项（清单里共 ${#T_PATHS[@]} 项）。"
      echo "   去掉关键词即可看到完整清单。"
    fi
    sweep_print_sizes ""
    echo
    echo "包含扫描在内，未删除任何文件。"
    exit 0
  fi

  local prev_cat="" num=0
  for i in "${S_IDX[@]}"; do
    num=$((num + 1))
    if [ "${T_CATS[$i]}" != "${prev_cat}" ]; then
      printf '\n   [%s]\n' "${T_CATS[$i]}"
      prev_cat="${T_CATS[$i]}"
    fi
    printf '   [%02d] %8s  %s\n' "${num}" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}"
  done

  echo
  ui_end
  printf '   命中 %d 项 / 合计 %s' "${n_sel}" "$(human "${sel_kb}")"
  if have_filters && [ "${n_sel}" -lt "${#T_PATHS[@]}" ]; then
    printf '（另有 %d 项未命中筛选，未计入）' "$(( ${#T_PATHS[@]} - n_sel ))"
  fi
  printf '\n'
  sweep_print_sizes "清理前 "

  if [ "${PROTECTED_SKIPPED}" -gt 0 ]; then
    ui_note "🛡️  硬防线拦截：${PROTECTED_SKIPPED} 处命中用户数据保护名单，已强制排除"
  fi
  declare -F sweep_extra_notes >/dev/null 2>&1 && sweep_extra_notes

  # ── 只扫描模式 / --scan：报告完就结束 ──
  if [ "${SCAN_ONLY}" -eq 1 ]; then
    echo
    echo "只扫描模式（--scan）：未删除任何文件。"
    exit 0
  fi

  # ── 范围闸：裸 --clean 什么都不会动 ────────────────────────────────────────
  # 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
  # 要么给关键词筛选，要么显式写 --all。
  if [ "${CLEAN}" -eq 1 ] && ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
    echo >&2
    echo "⚠️  没有指定范围，本次不会动任何文件。" >&2
    echo "    只清几项：    bash $0 --clean <关键词>     # 多个词用空格或逗号" >&2
    echo "    全部都要清：  bash $0 --clean --all" >&2
    exit 2
  fi

  # ── 交互式清理：列剩余清单 → 选 → 移入废纸篓 → 还有剩余就再问，直到结束 ──

  render_brief() {  # render_brief <显示编号> <内部索引>
    printf '   [%02d] %8s  %s  ·  %s\n' "$1" "$(human "${T_SIZES[$2]}")" \
           "${T_LABELS[$2]}" "${T_CATS[$2]}"
  }

  render_paths() {  # render_paths <内部索引>
    local one
    while IFS= read -r one; do
      [ -n "${one}" ] || continue
      printf '          %s\n' "${one}"
    done <<< "${T_PATHS[$1]}"
  }

  move_group() {  # move_group <内部索引> → 全部成功返回 0，否则 1
    local idx="$1" one one_kb gfail=0
    while IFS= read -r one; do
      [ -n "${one}" ] || continue
      one_kb=$(kb_of "${one}")   # 移动前实测，成功才计入释放空间
      if trash_path "${one}"; then
        FREED_KB=$((FREED_KB + one_kb))
        printf '   [废纸篓] %s\n' "${one}"
      else
        printf '   [失败]   %s\n' "${one}"
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

    ui_section "第 ${round} 轮 · 待处理 ${#REM_IDX[@]} 项 / 合计 $(human "${rem_kb}")（编号以本轮为准）"
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
        echo "   看不懂这个输入（可用：yes / 编号 / 1-4 / 1,3 / pick / q）。本次没有处理任何项。"
        continue
      fi
      case "${ACT}" in
        cancel)
          echo "   结束，未处理的项原样不动。"
          break ;;
        all)
          CHOSEN=( ${REM_IDX[@]+"${REM_IDX[@]}"} ) ;;
        pick)
          CHOSEN=()
          n=0
          for i in "${REM_IDX[@]}"; do
            n=$((n + 1))
            printf '\n   [%02d] %8s  %s  ·  %s\n' "${n}" "$(human "${T_SIZES[$i]}")" \
                   "${T_LABELS[$i]}" "${T_CATS[$i]}"
            render_paths "${i}"
            printf '      移入废纸篓？[y/N/s/q] '
            a2=""
            read -r a2 || a2="q"
            case "${a2}" in
              y|Y) CHOSEN+=("${i}") ;;
              q|Q) echo "      结束逐项确认。"; break ;;
              s|S)
                # ⚠️ 先把路径收进数组：`while read ... done <<< "值"` 的重定向作用于
                #    整个循环体，循环体里的交互 read 会去读 herestring（已 EOF）而不是
                #    用户输入 —— 收进数组后用 for 遍历，read 才能正常读 stdin。
                declare -a sp=()
                while IFS= read -r one; do
                  [ -n "${one}" ] || continue
                  sp+=("${one}")
                done <<< "${T_PATHS[$i]}"
                for one in ${sp[@]+"${sp[@]}"}; do
                  printf '        %s ? [y/N] ' "${one}"
                  a3=""
                  read -r a3 || a3="n"
                  case "${a3}" in
                  y|Y) one_kb=$(kb_of "${one}")
                       if trash_path "${one}"; then
                         FREED_KB=$((FREED_KB + one_kb))
                         printf '          [废纸篓] 已移入\n'; moved_paths=$((moved_paths + 1))
                         else
                           printf '          [失败]   无法移动（可能需要权限）\n'; fail=$((fail + 1))
                         fi ;;
                  esac
                done
                # 逐条处理完也算处理过（已移走的不再重复出现在剩余清单里）
                CHOSEN+=("${i}")
                ;;
              *) echo "      跳过" ;;
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
    for i in "${REM_IDX[@]}"; do
      hit=0
      for c in "${CHOSEN[@]}"; do
        [ "${c}" = "${i}" ] && hit=1 && break
      done
      if [ "${hit}" -eq 1 ]; then
        printf ' [%s] %s  ·  %s\n' "${T_CATS[$i]}" "${T_LABELS[$i]}" "$(human "${T_SIZES[$i]}")"
        if move_group "${i}"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
        fi
        moved_now=$((moved_now + 1))
        echo
      else
        NEXT_REM+=("${i}")
      fi
    done
    REM_IDX=( ${NEXT_REM[@]+"${NEXT_REM[@]}"} )
    echo "   本轮处理 ${moved_now} 项；剩余待处理 ${#REM_IDX[@]} 项"
  done

  # ── 收尾 ──
  ui_section "结果"
  printf '   成功 %d 项，失败 %d 项，剩余未处理 %d 项\n' "${ok}" "${fail}" "${#REM_IDX[@]}"
  [ "${moved_paths}" -gt 0 ] && \
    printf '   其中逐条确认移入 %d 个文件\n' "${moved_paths}"
  [ "${FREED_KB}" -gt 0 ] && \
    printf '   移入废纸篓合计 %s\n' "$(human "${FREED_KB}")"
  sweep_print_sizes "清理后 "
  if [ "${ok}" -gt 0 ] || [ "${moved_paths}" -gt 0 ]; then
    printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
  else
    printf '   未移动任何文件。\n'
  fi
  ui_end
}
