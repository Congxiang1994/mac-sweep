#!/usr/bin/env bash
#
# workbuddy-sweep.sh — 清理 WorkBuddy 堆积的缓存 / 日志 / 追踪 / 空会话目录
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# 扫描目标：
#   1) logs/ 下早于今天的历史日期目录
#   2) logs/*.old.log 轮转旧日志
#   3) logs/ 下过期零碎日志（connector-oauth-debug.log 等）
#   4) logs/sandbox/ 沙箱会话日志  ★ 通常最大头
#        非今天的日期目录整体删；今天的按 sandbox_[center_]<pid>_* 分组，
#        仅当该 pid 已不存在（且 ≥SANDBOX_COOLDOWN_MIN 分钟无写入）才删。
#        活着的会话（当前正在跑的沙箱）一律跳过。
#   5) traces/* 窥探追踪目录（闲置 ≥TRACE_MAX_AGE_MIN 分钟）
#   6) 缓存/冗余目录：skills-marketplace / connectors-marketplace / cache /
#        file-tree-manifests / shell-snapshots / clipboard-images / blobs /
#        file-history / changes-detail
#   7) app/session/ 下 Electron 纯缓存（不动 WebStorage / IndexedDB 等登录态）
#   8) backup-memory-YYYYMMDD 过期记忆备份
#   9) 散落的 .DS_Store（限 WB_HOME 下 3 层）
#  10) WB_WORKSPACES（默认 ~/WorkBuddy）下的【空】会话时间目录
#        名字必须严格是 YYYY-MM-DD-HH-MM-SS，且真的一无所有。
#        名字不是这个格式的一律不碰（认不出主人，如 Claw）；
#        刚创建不足 EMPTY_SESSION_COOLDOWN_MIN 分钟的空目录也跳过
#        —— 可能是已开始但还没写文件的活跃会话。
#        ⚠️ 空目录不占空间，清它只是去杂乱，不省磁盘。
#
#   --aggressive 追加：plugins/marketplaces/（市场清单，下次打开自动重拉）
#
# 【不会】删：
#   - binaries/ 托管运行时（Python + Node，所有工具依赖）
#   - plugins/cache/ 已安装插件、plugins/installed_plugins.json
#   - projects/ 会话数据、security/ 凭据、credentials/、memory/、skills/、workspace/
#   - 正在写入的活跃日志：daemon.log / main.log / renderer.log / mcp-apps-diag.log /
#     file-service.log / AppStartup.log，以及 logs/ 中今天的日期目录
#   - WB_WORKSPACES 下任何非空的会话目录
#
# 用法：
#   ./workbuddy-sweep.sh                     # 扫描 → 列清单 → 交互选择要清的项
#   ./workbuddy-sweep.sh sandbox             # 只把名字/路径含 sandbox 的项列进清单
#   ./workbuddy-sweep.sh sandbox traces      # 多个关键词 = 并集（含 sandbox 或 traces）
#   ./workbuddy-sweep.sh sandbox --and 2026  # 交集（同时含两词才算）
#   ./workbuddy-sweep.sh --only sandbox,traces  # 逗号连写，等价于空格分隔
#   ./workbuddy-sweep.sh --aggressive        # 清单里额外含 plugins/marketplaces
#   ./workbuddy-sweep.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐项确认（y=移入 n=跳过 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./workbuddy-sweep.sh --clean sandbox --yes   # 跳过交互，直接清匹配项
#   ./workbuddy-sweep.sh --clean --all           # 进交互但清单是全部，仍需手输 yes
#   ⚠️ 裸 --clean（既没关键词也没 --all）拒绝执行，退出码 2 —— 手滑敲出来不会变成全删。
#   ⚠️ --yes 必须带筛选条件：--clean --all --yes 这种「一句话全清空」被刻意堵死。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「类别名 / 条目名 / 条目内任一完整路径」的子串，忽略大小写。
#   多个关键词默认「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（再给一个关键词就切回并集），可混排：a b --and c = (a 或 b) 且 c。
#   ⚠️ 交互里的编号只对「本次显示顺序」有效，每次都会重排；筛选一律按关键词走。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
#    注意：废纸篓里的东西仍占磁盘，清空废纸篓后空间才真正释放。
#
# 可调环境变量：
#   WB_HOME                     目标目录，默认 ~/.workbuddy
#   WB_WORKSPACES               会话工作目录根，默认 ~/WorkBuddy
#   TRACE_MAX_AGE_MIN           traces 闲置阈值（分钟），默认 60
#   SANDBOX_COOLDOWN_MIN        沙箱会话冷却阈值（分钟），默认 5
#   EMPTY_SESSION_COOLDOWN_MIN  空会话目录的最短年龄（分钟），默认 60
#
# ⚠️ 没有「单次上限」：选中之后清单上的项一次处理完，不会清到一半停住。
# ⚠️ 本脚本不产生任何临时文件。
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进变量名，
#    在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
AGGRESSIVE=0
SCAN_ONLY=0
declare -a FILTERS=()          # 关键词（类别名 / 条目名 / 路径子串）
JOIN_MODE="or"                 # or = 并集（默认）；and = 交集
LAST_JOIN="or"                 # 最近一个关键词挂的连接符，逗号展开时沿用

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

# 词可以写成 sandbox,traces 或 --only sandbox,traces：按逗号拆开逐个入列
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

while [ "$#" -gt 0 ]; do
  arg="$1"; shift
  case "${arg}" in
    --clean)      CLEAN=1 ;;
    --all)        SHOW_ALL=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    --scan|--dry-run|--report) SCAN_ONLY=1 ;;
    --only)       add_filter_list "${1:-}"; shift || true ;;
    --and|--or)
      LAST_JOIN="or"
      [ "${arg}" = "--and" ] && LAST_JOIN="and"
      # 连接符只对「下一个词」生效
      if [ "${#FILTERS[@]}" -gt 0 ]; then JOIN_MODE="${LAST_JOIN}"; else JOIN_MODE="or"; fi
      ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --apply)
      echo "参数 --apply 已改名为 --clean，且必须明确范围：" >&2
      echo "  bash $0 --clean --all         # 全部清单（仍需输入 yes）" >&2
      echo "  bash $0 --clean <关键词>      # 只清匹配的项" >&2
      exit 2 ;;
    -h|--help)    sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0 ;;
    -*)           echo "未知参数: ${arg}（-h 查看用法）" >&2; exit 2 ;;
    *)            add_filter_list "${arg}" ;;
  esac
done

# 空转的 --and（后面没跟关键词）不该生效，回落到并集
[ "${#FILTERS[@]}" -gt 0 ] || JOIN_MODE="or"

# --yes 是个放大器：只允许配合明确的筛选条件用，绝不允许「不带筛选地全删」
if [ "${ASSUME_YES}" -eq 1 ]; then
  if [ "${CLEAN}" -ne 1 ]; then
    echo "--yes 需与 --clean 一起用。" >&2; exit 2
  fi
  if ! have_filters; then
    echo "--yes 必须带筛选条件（如 --clean sandbox --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

WB_HOME="${WB_HOME:-${HOME}/.workbuddy}"
WB_WORKSPACES="${WB_WORKSPACES:-${HOME}/WorkBuddy}"
TRACE_MAX_AGE_MIN="${TRACE_MAX_AGE_MIN:-60}"
SANDBOX_COOLDOWN_MIN="${SANDBOX_COOLDOWN_MIN:-5}"
EMPTY_SESSION_COOLDOWN_MIN="${EMPTY_SESSION_COOLDOWN_MIN:-60}"

[ -d "${WB_HOME}" ] || { echo "目录不存在: ${WB_HOME}" >&2; exit 1; }

today=$(date +%Y-%m-%d)
now=$(date +%s)

# ═════════════════════════════════════════════════════════════════════════════
# 输出组件（与 uninstall-residue.sh 保持逐字一致，改一处必须同步另一处）
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

ui_section() {  # ui_section <标题>
  echo
  printf '── %s %s\n' "$1" "$(ui_dashes "$1")"
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
  draw_progress "${PROG_DONE}" "${PROG_TOTAL}" "$1"
}

finish_progress() {
  [ "${SHOW_PROGRESS}" -eq 1 ] || return 0
  draw_progress "${PROG_TOTAL}" "${PROG_TOTAL}" "扫描完成"
  printf '\n' >&2
}

SCAN_TOTAL=12

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
# 选择解析（与 uninstall-residue.sh 逐字一致）
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

# ───────── 筛选匹配 ─────────
#   · 默认并集（or）——任意一个词命中即算命中
#   · --and 之后的那一个词改为「且」条件，与前面已算出的结果求交
#     a b --and c  =  (a 或 b) 且 c
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
# 扫描
# ═════════════════════════════════════════════════════════════════════════════

declare -a T_PATHS=()   # 路径（组则为换行分隔的多路径）
declare -a T_SIZES=()   # 大小 KB
declare -a T_LABELS=()  # 展示名
declare -a T_CATS=()    # 所属类别
TOTAL_KB=0

_add() {  # _add <cat> <label> <kb> <keep_zero> <路径...>
  local cat="$1" label="$2" kb="$3" keep="$4"; shift 4
  [ "$#" -gt 0 ] || return 0
  [ "${kb}" -eq 0 ] && [ "${keep}" -ne 1 ] && return 0
  local joined; joined=$(printf '%s\n' "$@")
  T_PATHS+=("${joined}"); T_SIZES+=("${kb}")
  T_LABELS+=("${label}"); T_CATS+=("${cat}")
  TOTAL_KB=$((TOTAL_KB + kb))
}

add_target() {  # add_target <cat> <path> [label]
  local cat="$1" path="$2" label="${3:-}"
  [ -e "${path}" ] || return 0
  [ -n "${label}" ] || label="${path#"${WB_HOME}"/}"
  _add "${cat}" "${label}" "$(kb_of "${path}")" 0 "${path}"
}

# 尺寸为 0 也要保留（空目录不占空间，但列表里得有它）
add_group_keep0() {  # add_group_keep0 <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add "${cat}" "${label}" "${kb}" 1 "$@"
}

add_group() {  # add_group <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add "${cat}" "${label}" "${kb}" 0 "$@"
}

ui_head "WorkBuddy 清理" \
  "WB_HOME   ${WB_HOME}" \
  "会话目录  ${WB_WORKSPACES}" \
  "今天      ${today}" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入 plugins/marketplaces"
ui_note "扫描中…（进度见下方）"

# ───────── 1) logs 历史日期目录 ─────────
scan_step "logs 历史日期目录"
for d in "${WB_HOME}"/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "${d}" ] || continue
  [ "$(basename "${d}")" = "${today}" ] && continue
  add_target "logs 历史日期目录" "${d}"
done

# ───────── 2) logs 轮转旧日志 ─────────
scan_step "logs 轮转旧日志"
for f in "${WB_HOME}"/logs/*.old.log; do
  [ -f "${f}" ] || continue
  add_target "logs 轮转旧日志" "${f}"
done

# ───────── 3) logs 过期零碎日志 ─────────
scan_step "logs 过期零碎日志"
for f in connector-oauth-debug.log file-domain-service.log debug.log \
         legacy-autolaunch-cleaner.log; do
  add_target "logs 过期零碎日志" "${WB_HOME}/logs/${f}"
done

# ───────── 4) logs/sandbox 沙箱会话日志 ★ ─────────
scan_step "logs/sandbox 沙箱会话"
sb_root="${WB_HOME}/logs/sandbox"
if [ -d "${sb_root}" ]; then
  for day in "${sb_root}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -d "${day}" ] || continue
    dayname=$(basename "${day}")
    dayfmt="${dayname:0:4}-${dayname:4:2}-${dayname:6:2}"
    # 非今天的日期目录：整体删
    if [ "${dayfmt}" != "${today}" ]; then
      add_target "logs/sandbox 历史会话" "${day}"
      continue
    fi
    # 今天：按沙箱进程分组，只删已结束的
    for pid in $(ls "${day}" 2>/dev/null \
                 | sed -nE 's/^sandbox_(center_)?([0-9]+)(\.mmap3|_[0-9]+\.log)$/\2/p' \
                 | sort -un); do
      files=(); has_center=0
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        files+=("${day}/${f}")
        case "${f}" in sandbox_center_*) has_center=1 ;; esac
      done < <(ls "${day}" 2>/dev/null | grep -E "^sandbox_(center_)?${pid}(\.mmap3|_[0-9]+\.log)$")

      [ "${#files[@]}" -gt 0 ] || continue
      # 活着的沙箱会话 → 跳过
      proc_alive "${pid}" && continue
      # 冷却：最近仍在写 → 跳过（防 pid 复用 / 竞态）
      newest=$(stat -f '%m' "${files[@]}" 2>/dev/null | sort -rn | head -1)
      if [ -n "${newest}" ]; then
        [ "$(( (now - newest) / 60 ))" -lt "${SANDBOX_COOLDOWN_MIN}" ] && continue
      fi
      if [ "${has_center}" -eq 1 ]; then
        pidlabel="pid=${pid}(center)"
      else
        pidlabel="pid=${pid}"
      fi
      add_group "logs/sandbox 已结束会话" \
                "logs/sandbox/${dayname}  ${pidlabel}（${#files[@]} 个文件）" \
                "$(kb_of_multi "${files[@]}")" "${files[@]}"
    done
  done
fi

# ───────── 5) traces 闲置追踪目录 ─────────
scan_step "traces 闲置追踪"
for d in "${WB_HOME}"/traces/*/; do
  [ -d "${d}" ] || continue
  m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "${now}")
  age_min=$(( (now - m) / 60 ))
  [ "${age_min}" -lt "${TRACE_MAX_AGE_MIN}" ] && continue
  add_target "traces 闲置追踪" "${d%/}" "traces/$(basename "${d}")/（闲置 ${age_min} 分钟）"
done

# ───────── 6) 缓存 / 冗余目录 ─────────
scan_step "缓存 / 冗余目录"
for d in skills-marketplace connectors-marketplace cache file-tree-manifests \
         shell-snapshots clipboard-images blobs file-history changes-detail; do
  add_target "缓存/冗余目录" "${WB_HOME}/${d}"
done

# ───────── 7) app/session Electron 纯缓存 ─────────
scan_step "Electron 渲染缓存"
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary"; do
  add_target "Electron 渲染缓存" "${WB_HOME}/app/session/${d}"
done

# ───────── 8) 过期记忆备份 ─────────
scan_step "过期记忆备份"
for d in "${WB_HOME}"/backup-memory-*; do
  [ -d "${d}" ] || continue
  add_target "过期记忆备份" "${d}"
done

# ───────── 9) 散落 .DS_Store ─────────
scan_step "散落 .DS_Store"
ds_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  ds_files+=("${f}")
done < <(find "${WB_HOME}" -maxdepth 3 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  add_group "散落 .DS_Store" "散落 .DS_Store（${#ds_files[@]} 个）" \
            "$(kb_of_multi "${ds_files[@]}")" "${ds_files[@]}"
fi

# ───────── 10) WB_WORKSPACES 下的空会话时间目录 ─────────
# 只认严格的时间命名，且真的一无所有；非空 / 命名不符 / 刚创建的都不碰。
scan_step "空会话目录"
empty_dirs=(); ws_skipped_recent=0; ws_nonempty=0; ws_other=0
if [ -d "${WB_WORKSPACES}" ]; then
  for d in "${WB_WORKSPACES}"/*; do
    [ -e "${d}" ] || continue            # 纯 glob 无匹配时跳过，不 fork
    [ -d "${d}" ] || continue            # 只处理目录
    [ -L "${d}" ] && continue            # 符号链接不碰
    case "$(basename "${d}")" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) ws_other=$((ws_other + 1)); continue ;;   # 认不出主人 → 不碰
    esac
    if [ -n "$(ls -A "${d}" 2>/dev/null | head -1)" ]; then
      ws_nonempty=$((ws_nonempty + 1)); continue   # 有东西 → 不是空目录
    fi
    m=$(stat -f '%m' "${d}" 2>/dev/null || echo "${now}")
    if [ "$(( (now - m) / 60 ))" -lt "${EMPTY_SESSION_COOLDOWN_MIN}" ]; then
      ws_skipped_recent=$((ws_skipped_recent + 1)); continue   # 可能是在跑的会话
    fi
    empty_dirs+=("${d}")
  done
fi
if [ "${#empty_dirs[@]}" -gt 0 ]; then
  add_group_keep0 "空会话目录" \
    "会话工作目录空目录（${#empty_dirs[@]} 个，不占空间）" \
    "$(kb_of_multi "${empty_dirs[@]}")" "${empty_dirs[@]}"
fi

# ───────── 11) aggressive：插件市场清单 ─────────
scan_step "插件市场清单"
if [ "${AGGRESSIVE}" -eq 1 ] && [ -d "${WB_HOME}/plugins/marketplaces" ]; then
  add_target "插件市场清单(aggressive)" "${WB_HOME}/plugins/marketplaces" \
             "plugins/marketplaces/（下次打开自动重拉）"
fi

# ───────── 12) 活跃日志统计（只提示，不清理）─────────
scan_step "活跃日志统计"
live_total=0
for f in daemon.log main.log renderer.log mcp-apps-diag.log file-service.log AppStartup.log; do
  [ -f "${WB_HOME}/logs/${f}" ] || continue
  live_total=$((live_total + $(kb_of "${WB_HOME}/logs/${f}")))
done

finish_progress

# ═════════════════════════════════════════════════════════════════════════════
# 应用筛选
# ═════════════════════════════════════════════════════════════════════════════

declare -a S_IDX=()
i=0
while [ "${i}" -lt "${#T_PATHS[@]}" ]; do
  if matches_filters "${T_CATS[$i]} ${T_LABELS[$i]}" "${T_PATHS[$i]}"; then
    S_IDX+=("${i}")
  fi
  i=$((i + 1))
done

n_sel=${#S_IDX[@]}
sel_kb=0
for i in ${S_IDX[@]+"${S_IDX[@]}"}; do
  sel_kb=$((sel_kb + ${T_SIZES[$i]}))
done

# ═════════════════════════════════════════════════════════════════════════════
# 报告
# ═════════════════════════════════════════════════════════════════════════════

ui_section "扫描结果"

if [ "${n_sel}" -eq 0 ]; then
  if [ "${#T_PATHS[@]}" -eq 0 ]; then
    echo "   没有可清理的垃圾（已经干净）。"
  else
    echo "   没有匹配「$(filters_desc)」的项（清单里共 ${#T_PATHS[@]} 项）。"
    echo "   去掉关键词即可看到完整清单。"
  fi
  echo "   当前占用: $(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)"
  echo
  echo "包含扫描在内，未删除任何文件。"
  exit 0
fi

prev_cat=""; num=0
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
printf '   清理前占用: %s\n' "$(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)"

# 空会话目录的旁注：说清楚什么被跳过了、为什么
if [ "${ws_nonempty}" -gt 0 ] || [ "${ws_skipped_recent}" -gt 0 ] || [ "${ws_other}" -gt 0 ]; then
  ui_note "空会话目录旁注: ${ws_nonempty} 个非空已保留；${ws_skipped_recent} 个创建不足 ${EMPTY_SESSION_COOLDOWN_MIN} 分钟跳过；${ws_other} 个命名不符跳过（${WB_WORKSPACES}）"
fi

# 活跃日志提示（不删，仅告知）
if [ "${live_total}" -gt 20480 ]; then
  ui_note "提示: 正在写入的活跃日志另有 $(human "${live_total}")（不清理；如需回收可重启 WorkBuddy 后手动截断）"
fi

# ── 只扫描模式 / --scan：报告完就结束 ──
if [ "${SCAN_ONLY}" -eq 1 ]; then
  echo
  echo "只扫描模式（--scan）：未删除任何文件。"
  exit 0
fi

# ── 范围闸：裸 --clean 什么都不会动 ──────────────────────────────────────────
# 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
# 要么给关键词筛选，要么显式写 --all。
if [ "${CLEAN}" -eq 1 ] && ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
  echo >&2
  echo "⚠️  没有指定范围，本次不会动任何文件。" >&2
  echo "    只清几项：    bash $0 --clean <关键词>     # 多个词用空格或逗号" >&2
  echo "    全部都要清：  bash $0 --clean --all" >&2
  exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 交互式清理：列剩余清单 → 选 → 移入废纸篓 → 还有剩余就再问，直到结束
# ═════════════════════════════════════════════════════════════════════════════

# 渲染器：把「内部索引」渲染成带编号的清单 / 完整路径
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
  local idx="$1" one gfail=0
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    if trash_path "${one}"; then
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
ok=0; fail=0; skipped=0; moved_paths=0; round=0

while [ "${#REM_IDX[@]}" -gt 0 ]; do
  round=$((round + 1))

  rem_kb=0
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
    ans=""
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
                  y|Y) if trash_path "${one}"; then
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
        # pick 里已经逐条处理过（含 s），这里只处理整组被选中的
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
    [ "${ACT}" = "pick" ] && continue
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
      skipped=$((skipped + 1))
    fi
  done
  REM_IDX=( ${NEXT_REM[@]+"${NEXT_REM[@]}"} )
  echo "   本轮处理 ${moved_now} 项；剩余待处理 ${#REM_IDX[@]} 项"
done

# ── 收尾 ──
ui_section "结果"
printf '   成功 %d 项，失败 %d 项，剩余未处理 %d 项\n' "${ok}" "${fail}" "${#REM_IDX[@]}"
printf '   清理后占用: %s\n' "$(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)"
if [ "${ok}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
else
  printf '   未移动任何文件。\n'
fi
ui_end
