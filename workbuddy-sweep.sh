#!/usr/bin/env bash
#
# workbuddy-sweep.sh — 清理 WorkBuddy 堆积的缓存 / 日志 / 追踪 / 空会话目录
#
# ─────────────────────────────────────────────────────────────────────────────
# 默认【只扫描、只报告，一个文件都不动】。加 --clean 才进入逐项确认的清理。
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
#   ./workbuddy-sweep.sh                          # 扫描并输出报告（不删任何东西）
#   ./workbuddy-sweep.sh sandbox                  # 只看名字/路径含 sandbox 的项
#   ./workbuddy-sweep.sh sandbox traces           # 多个关键词 = 并集（含 sandbox 或 traces）
#   ./workbuddy-sweep.sh sandbox --and 20260916   # 交集（同时含两词才算）
#   ./workbuddy-sweep.sh --only sandbox,traces    # 逗号连写，等价于空格分隔
#   ./workbuddy-sweep.sh --aggressive             # 报告里额外含 plugins/marketplaces
#   ./workbuddy-sweep.sh --clean sandbox          # 清理含 sandbox 的项（输入 yes 才动手）
#   ./workbuddy-sweep.sh --clean --all            # 列出全部清单，同样要输入 yes
#   ./workbuddy-sweep.sh --clean --all --aggressive
#   ./workbuddy-sweep.sh --clean sandbox --yes    # 跳过二次确认（--yes 必须带筛选）
#
# ⚠️ --clean 必须明确范围：给关键词筛选，或者给 --all。
#    裸 --clean 什么都不会动（退出码 2）—— 手滑敲出来不会变成全量清理。
#
# ⚠️ 动手前有两道确认：先把「即将移入废纸篓的每一条路径 + 合计体积」完整列出，
#    然后要你手打 yes 才执行（回车或其它任何输入 = 取消，一个文件都不动）。
#    输入 pick 可改为逐项挑选。--yes 能跳过这道确认，但必须带筛选条件。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
#    注意：废纸篓里的东西仍占磁盘，清空废纸篓后空间才真正释放。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「类别名 / 条目名 / 条目内任一完整路径」的子串，忽略大小写。
#   多个关键词默认「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（再给一个关键词就切回并集），可混排：a b --and c = (a 或 b) 且 c。
#   ⚠️ 报告里的编号只是给你看的，不能拿来当筛选条件 —— 筛选一律按关键词走，
#      这样不会因为清单排序变了而误删到别的项。
#
# 可调环境变量：
#   WB_HOME                     目标目录，默认 ~/.workbuddy
#   WB_WORKSPACES               会话工作目录根，默认 ~/WorkBuddy
#   TRACE_MAX_AGE_MIN           traces 闲置阈值（分钟），默认 60
#   SANDBOX_COOLDOWN_MIN        沙箱会话冷却阈值（分钟），默认 5
#   EMPTY_SESSION_COOLDOWN_MIN  空会话目录的最短年龄（分钟），默认 60
#   MAX_DELETE_PER_RUN          单次最多处理多少项，默认 20
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进变量名，
#    在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
AGGRESSIVE=0
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
MAX_DELETE_PER_RUN="${MAX_DELETE_PER_RUN:-20}"

[ -d "${WB_HOME}" ] || { echo "目录不存在: ${WB_HOME}" >&2; exit 1; }

today=$(date +%Y-%m-%d)
now=$(date +%s)

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

echo "WorkBuddy 清理  WB_HOME=${WB_HOME}  今天=${today}"
echo "模式：$([ "${CLEAN}" -eq 1 ] && echo '扫描 + 逐项确认清理（移入废纸篓）' || echo '只扫描，不删除任何文件')"
have_filters && echo "筛选：只处理名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && echo "aggressive：额外纳入 plugins/marketplaces"
echo

# ───────── 1) logs 历史日期目录 ─────────
for d in "${WB_HOME}"/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "${d}" ] || continue
  [ "$(basename "${d}")" = "${today}" ] && continue
  add_target "logs 历史日期目录" "${d}"
done

# ───────── 2) logs 轮转旧日志 ─────────
for f in "${WB_HOME}"/logs/*.old.log; do
  [ -f "${f}" ] || continue
  add_target "logs 轮转旧日志" "${f}"
done

# ───────── 3) logs 过期零碎日志 ─────────
for f in connector-oauth-debug.log file-domain-service.log debug.log \
         legacy-autolaunch-cleaner.log; do
  add_target "logs 过期零碎日志" "${WB_HOME}/logs/${f}"
done

# ───────── 4) logs/sandbox 沙箱会话日志 ★ ─────────
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
for d in "${WB_HOME}"/traces/*/; do
  [ -d "${d}" ] || continue
  m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "${now}")
  age_min=$(( (now - m) / 60 ))
  [ "${age_min}" -lt "${TRACE_MAX_AGE_MIN}" ] && continue
  add_target "traces 闲置追踪" "${d%/}" "traces/$(basename "${d}")/（闲置 ${age_min} 分钟）"
done

# ───────── 6) 缓存 / 冗余目录 ─────────
for d in skills-marketplace connectors-marketplace cache file-tree-manifests \
         shell-snapshots clipboard-images blobs file-history changes-detail; do
  add_target "缓存/冗余目录" "${WB_HOME}/${d}"
done

# ───────── 7) app/session Electron 纯缓存 ─────────
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary"; do
  add_target "Electron 渲染缓存" "${WB_HOME}/app/session/${d}"
done

# ───────── 8) 过期记忆备份 ─────────
for d in "${WB_HOME}"/backup-memory-*; do
  [ -d "${d}" ] || continue
  add_target "过期记忆备份" "${d}"
done

# ───────── 9) 散落 .DS_Store ─────────
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
if [ "${AGGRESSIVE}" -eq 1 ] && [ -d "${WB_HOME}/plugins/marketplaces" ]; then
  add_target "插件市场清单(aggressive)" "${WB_HOME}/plugins/marketplaces" \
             "plugins/marketplaces/（下次打开自动重拉）"
fi

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
sel_kb=0; sel_paths=0
for i in "${S_IDX[@]+"${S_IDX[@]}"}"; do
  sel_kb=$((sel_kb + ${T_SIZES[$i]}))
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    sel_paths=$((sel_paths + 1))
  done <<< "${T_PATHS[$i]}"
done

# ═════════════════════════════════════════════════════════════════════════════
# 报告
# ═════════════════════════════════════════════════════════════════════════════

echo "================ 扫描结果 ================"

if [ "${n_sel}" -eq 0 ]; then
  echo
  if [ "${#T_PATHS[@]}" -eq 0 ]; then
    echo "没有可清理的垃圾（已干净）。"
    echo "当前占用: $(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)"
    exit 0
  fi
  echo "没有匹配「$(filters_desc)」的项（清单里共 ${#T_PATHS[@]} 项）。"
  echo "去掉关键词即可看到完整清单。"
  exit 0
fi

prev_cat=""; num=0
for i in "${S_IDX[@]}"; do
  num=$((num + 1))
  if [ "${T_CATS[$i]}" != "${prev_cat}" ]; then
    echo
    echo "[${T_CATS[$i]}]"
    prev_cat="${T_CATS[$i]}"
  fi
  printf '  [%02d] %8s  %s\n' "${num}" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}"
done

echo
echo "------------------------------------------"
printf '命中 %d 项 / %d 处 / 合计 %s\n' "${n_sel}" "${sel_paths}" "$(human "${sel_kb}")"
if have_filters && [ "${n_sel}" -lt "${#T_PATHS[@]}" ]; then
  printf '（清单里另有 %d 项未命中筛选，未计入，也不会被清理）\n' "$(( ${#T_PATHS[@]} - n_sel ))"
fi
echo "清理前占用: $(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)"

# 空会话目录的旁注：说清楚什么被跳过了、为什么
if [ "${ws_nonempty}" -gt 0 ] || [ "${ws_skipped_recent}" -gt 0 ] || [ "${ws_other}" -gt 0 ]; then
  printf '空会话目录旁注: %d 个非空已保留；%d 个创建不足 %s 分钟跳过；%d 个命名不符跳过（%s）\n' \
         "${ws_nonempty}" "${ws_skipped_recent}" "${EMPTY_SESSION_COOLDOWN_MIN}" \
         "${ws_other}" "${WB_WORKSPACES}"
fi

# 活跃日志提示（不删，仅告知）
live_total=0
for f in daemon.log main.log renderer.log mcp-apps-diag.log file-service.log AppStartup.log; do
  [ -f "${WB_HOME}/logs/${f}" ] || continue
  live_total=$((live_total + $(kb_of "${WB_HOME}/logs/${f}")))
done
if [ "${live_total}" -gt 20480 ]; then
  echo "提示: 正在写入的活跃日志另有 $(human "${live_total}")（未删除；如需回收可重启 WorkBuddy 后手动截断）"
fi

# ── 未加 --clean：报告完就结束 ──
if [ "${CLEAN}" -ne 1 ]; then
  echo
  echo "以上仅为报告，未删除任何文件。"
  echo "清楚了要清哪些，就把关键词接在 --clean 后面："
  if have_filters; then
    echo "  bash $0 --clean $(filters_desc)          # 列出清单，输入 yes 才动手"
    echo "  bash $0 --clean $(filters_desc) --yes    # 跳过二次确认（--yes 必须带筛选）"
  else
    echo "  bash $0 --clean sandbox      # 只清含 sandbox 的项"
    echo "  bash $0 --clean sandbox traces   # 多个关键词 = 并集"
  fi
  echo "确定全部都要清时（得显式写出来）："
  echo "  bash $0 --clean --all        # 列出全部清单，同样要输入 yes"
  exit 0
fi

# ── 范围闸：裸 --clean 什么都不会动 ──────────────────────────────────────────
# 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
# 要么给关键词筛选，要么显式写 --all。
if ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
  echo >&2
  echo "⚠️  没有指定范围，本次不会动任何文件。" >&2
  echo "    只清几项：    bash $0 --clean <关键词>     # 多个词用空格或逗号" >&2
  echo "    全部都要清：  bash $0 --clean --all" >&2
  exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 二次确认：先摆清单，再要手打 yes
# ═════════════════════════════════════════════════════════════════════════════

echo
echo "================ 即将移入废纸篓 ================"
echo

DEL_KB=0; DEL_PATHS=0; num=0
for i in "${S_IDX[@]}"; do
  num=$((num + 1))
  printf '[%02d] %s  ·  %s\n' "${num}" "${T_LABELS[$i]}" "$(human "${T_SIZES[$i]}")"
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    printf '       %s\n' "${one}"
    DEL_PATHS=$((DEL_PATHS + 1))
  done <<< "${T_PATHS[$i]}"
  DEL_KB=$((DEL_KB + ${T_SIZES[$i]}))
  echo
done

printf '合计 %d 项 / %d 处 / %s\n' "${n_sel}" "${DEL_PATHS}" "$(human "${DEL_KB}")"
printf '（这些都会进 %s/.Trash，不是真删，随时可拖回来）\n' "${HOME}"
echo

if [ "${ASSUME_YES}" -eq 1 ]; then
  echo "⚠️  --yes：跳过二次确认，直接按上面的清单执行"
  MODE="all"
else
  echo "以上就是要移入废纸篓的全部内容。"
  echo "  yes  = 确认，全部移入废纸篓"
  echo "  pick = 逐项挑选"
  echo "  其它 = 取消（什么都不做）"
  printf '> '
  gate=""
  # read 在「无换行就 EOF」时返回 1 但变量已被赋值，所以要先置空再读，别把值冲掉
  read -r gate || gate=""
  case "${gate}" in
    yes|YES|Yes)    MODE="all" ;;
    pick|PICK|Pick) MODE="pick" ;;
    *) echo "已取消，未删除任何文件。"; exit 0 ;;
  esac
fi
echo

# ═════════════════════════════════════════════════════════════════════════════
# 执行
# ═════════════════════════════════════════════════════════════════════════════

ok=0; fail=0; groups_done=0; paths_done=0; capped=0

move_group() {  # move_group <idx> → 全部成功返回 0，否则 1
  local idx="$1" one gfail=0
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    trash_path "${one}" || gfail=$((gfail + 1))
  done <<< "${T_PATHS[$idx]}"
  [ "${gfail}" -eq 0 ]
}

if [ "${MODE}" = "all" ]; then
  echo "================ 开始移入废纸篓 ================"
  for i in "${S_IDX[@]}"; do
    if [ "${groups_done}" -ge "${MAX_DELETE_PER_RUN}" ]; then
      capped=1
      break
    fi
    if move_group "${i}"; then
      printf '  [OK]  %s\n' "${T_LABELS[$i]}"
      ok=$((ok + 1)); groups_done=$((groups_done + 1))
    else
      printf '  [ERR] %s —— 有文件没能移入废纸篓\n' "${T_LABELS[$i]}"
      fail=$((fail + 1)); groups_done=$((groups_done + 1))
    fi
  done
  echo "=============================================="

elif [ "${MODE}" = "pick" ]; then
  echo "================ 逐项挑选 ================"
  echo "y=移入  n=跳过  q=退出（单次上限 ${MAX_DELETE_PER_RUN} 项）"
  echo
  num=0
  for i in "${S_IDX[@]}"; do
    num=$((num + 1))
    if [ "${groups_done}" -ge "${MAX_DELETE_PER_RUN}" ]; then
      printf '已达单次上限 %s 项，剩下的重跑一次即可继续。\n' "${MAX_DELETE_PER_RUN}"
      capped=1
      break
    fi
    printf '[%02d] %s  ·  %s\n' "${num}" "${T_LABELS[$i]}" "$(human "${T_SIZES[$i]}")"
    while IFS= read -r one; do
      [ -n "${one}" ] || continue
      printf '     %s\n' "${one}"
    done <<< "${T_PATHS[$i]}"
    printf '  移入废纸篓? [y/N/s/q] > '
    ans=""
    read -r ans || ans=""
    case "${ans}" in
      y|Y)  if move_group "${i}"; then
              echo "  [OK] 已移入"
              ok=$((ok + 1)); groups_done=$((groups_done + 1))
            else
              echo "  [ERR] 有文件没能移入"
              fail=$((fail + 1)); groups_done=$((groups_done + 1))
            fi ;;
      q|Q)  echo "  已退出。剩余项原样未动。"; break ;;
      * )   echo "  跳过" ;;
    esac
    echo
  done
  echo "=========================================="
fi

# ── 收尾 ──
echo
after_home=$(du -sh "${WB_HOME}" 2>/dev/null | cut -f1)
printf '成功 %d 项，失败 %d 项\n' "${ok}" "${fail}"
printf '清理后占用: %s\n' "${after_home}"
if [ "${capped}" -eq 1 ]; then
  printf '⚠️  已达单次上限 %s 项，清单里剩下的原样未动，重跑一次继续。\n' "${MAX_DELETE_PER_RUN}"
fi
echo
echo "这些内容现在在 ${HOME}/.Trash 里，可随时拖回。"
echo "确认无误后清空废纸篓，磁盘空间才会真正释放。"
