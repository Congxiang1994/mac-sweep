#!/usr/bin/env bash
#
# mac-sweep.sh — 整机垃圾清理：应用缓存 / 旧日志 / 开发工具缓存 / .DS_Store
#
# ─────────────────────────────────────────────────────────────────────────────
# 默认【只扫描、只报告，一个文件都不动】。加 --clean 才进入逐项确认的清理。
#
# ⚠️ 与仓库另外两支脚本不同：这支的扫描范围是【整个笔记本】。
#    所以安全模型不是「白名单之外随便清」，而是反过来 ——
#    【只有命中下方清单规则的路径】才可能进清单，规则没写的路径一个不碰。
#    另有「只报告区」：只统计体积告诉你为什么不清，--clean 时也永不进清单。
#
# 可清理的大类（每一类都可被关键词筛出）：
#
#   [dev] 开发工具缓存（可安全重建，删除代价 = 下次构建变慢）
#     1) Xcode DerivedData        ~/Library/Developer/Xcode/DerivedData/<proj>-<hash>
#        只删闲置 ≥ XCODE_DD_AGE_MIN 分钟的（60 分钟内动过 = 可能在构建）
#     2) Xcode iOS DeviceSupport  ~/Library/Developer/Xcode/iOS DeviceSupport/<ver>
#        只删闲置 ≥ IOS_SUPPORT_AGE_DAYS 天的（真机调试要用）
#     3) CoreSimulator Caches     ~/Library/Developer/CoreSimulator/Caches
#     4) npm / yarn / pnpm / pip / go-build / Gradle / CocoaPods 缓存，
#        Maven 本地仓库里的 *.lastUpdated 失败残留
#
#   [browser] 浏览器缓存（只碰 Cache 目录；Cookie / 登录态 / 历史记录绝不碰）
#     5) Chrome / Edge / Brave / Chromium / Arc / Vivaldi / Opera 的
#        <profile>/Cache 与 <profile>/Code Cache
#        ⚠️ 不含 Safari —— Safari 缓存由系统管理，没有安全的清理路径
#
#   [logs] 旧日志（只删闲置 ≥ LOG_AGE_DAYS 天的 .log / *.log.gz / .out）
#     6) ~/Library/Logs 下的日志文件（活日志太新，自然被阈值挡住）
#
#   [misc] 杂项
#     7) 整机散落 .DS_Store（HOME 下 ≤DS_MAX_DEPTH 层，Library 只扫 Logs/Caches）
#     8) node_modules 内的 .cache 子目录（不碰 node_modules 本身）
#
# 【不会】碰的（哪怕手滑写了关键词也一样）：
#   - Safari 的任何数据
#   - Cookie、Login Data、History、Preferences、Local Storage 等登录态
#   - ~/Library/Containers、~/Library/Group Containers（沙箱 App 的家）
#   - Application Support 下浏览器 Cache 之外的一切（App 数据目录整目录不碰）
#   - Desktop / Documents / Downloads / Pictures / Movies / Music / Public
#   - 任何 .git、.ssh、.gnupg、密钥 / 凭据 / plist 偏好
#   - node_modules、.venv、target、dist、build 等构建产物本体
#
# 用法：
#   ./mac-sweep.sh                        # 扫描并输出报告（不删任何东西）
#   ./mac-sweep.sh xcode                  # 只看名字/路径含 xcode 的项
#   ./mac-sweep.sh xcode logs             # 多个关键词 = 并集
#   ./mac-sweep.sh xcode --and deriveddata # 交集（同时含两词才算）
#   ./mac-sweep.sh --only browser,logs    # 逗号连写，等价于空格分隔
#   ./mac-sweep.sh --clean xcode          # 清理含 xcode 的项（输入 yes 才动手）
#   ./mac-sweep.sh --clean --all          # 列出全部清单，同样要输入 yes
#   ./mac-sweep.sh --clean xcode --yes    # 跳过二次确认（--yes 必须带筛选）
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
#
# 可调环境变量：
#   SWEEP_HOME            扫描根目录，默认 $HOME
#   XCODE_DD_AGE_MIN      DerivedData 闲置阈值（分钟），默认 60
#   IOS_SUPPORT_AGE_DAYS  iOS DeviceSupport 闲置阈值（天），默认 30
#   LOG_AGE_DAYS          旧日志闲置阈值（天），默认 14
#   DS_MAX_DEPTH          .DS_Store 扫描深度（HOME 下层数），默认 3
#
# 测试支持（正常使用无需关心）：
#   SWEEP_LOG_HOME        覆盖 ~/Library/Logs 的位置（测试注入用）
#   SWEEP_CACHE_HOME      覆盖 ~/Library/Caches 的位置（测试注入用）
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进变量名，
#    在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
declare -a FILTERS=()          # 关键词（类别名 / 条目名 / 路径子串）
JOIN_MODE="or"                 # or = 并集（默认）；and = 交集
LAST_JOIN="or"                 # 最近一个关键词挂的连接符，逗号展开时沿用

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

# 词可以写成 xcode,logs 或 --only xcode,logs：按逗号拆开逐个入列
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
    --only)       add_filter_list "${1:-}"; shift || true ;;
    --and|--or)
      LAST_JOIN="or"
      [ "${arg}" = "--and" ] && LAST_JOIN="and"
      # 连接符只对「下一个词」生效
      if [ "${#FILTERS[@]}" -gt 0 ]; then JOIN_MODE="${LAST_JOIN}"; else JOIN_MODE="or"; fi
      ;;
    --yes|-y)     ASSUME_YES=1 ;;
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
    echo "--yes 必须带筛选条件（如 --clean xcode --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

SWEEP_HOME="${SWEEP_HOME:-${HOME}}"
XCODE_DD_AGE_MIN="${XCODE_DD_AGE_MIN:-60}"
IOS_SUPPORT_AGE_DAYS="${IOS_SUPPORT_AGE_DAYS:-30}"
LOG_AGE_DAYS="${LOG_AGE_DAYS:-14}"
DS_MAX_DEPTH="${DS_MAX_DEPTH:-3}"

# 测试注入点：不设则用真实位置
LIB_LOGS="${SWEEP_LOG_HOME:-${SWEEP_HOME}/Library/Logs}"
LIB_CACHES="${SWEEP_CACHE_HOME:-${SWEEP_HOME}/Library/Caches}"

if [ ! -d "${SWEEP_HOME}" ]; then
  echo "目录不存在: ${SWEEP_HOME}" >&2
  exit 1
fi

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

# 路径最近改动时间（秒级 epoch；stat 不可用时回退 now，等于「当作很新，不删」）
mtime_of() {
  local m
  m=$(stat -f '%m' "$1" 2>/dev/null) || m="${now}"
  case "${m}" in ''|*[!0-9]*) m="${now}" ;; esac
  printf '%s' "${m}"
}

# 把文件/目录的 mtime 往前拨（测试造「闲置已久」的 fixture 用）
age_path() {  # age_path <path> < days>
  local p="$1" days="$2"
  touch -t "$(date -v-${days}d +%Y%m%d0000)" "${p}" 2>/dev/null
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
# 只报告区：只统计、说明「为什么不清」，永不进清理清单
# ═════════════════════════════════════════════════════════════════════════════
# 存在意义：让你看到「这台机器上还剩什么没清、为什么不清」，
# 并用体积证明「脚本没有把大头藏起来」。--clean 时也原样输出。

INFO_LINES=()
add_info() { INFO_LINES+=("$1"); }

# ═════════════════════════════════════════════════════════════════════════════
# 扫描
# ═════════════════════════════════════════════════════════════════════════════

declare -a T_PATHS=()   # 路径（组则为换行分隔的多路径）
declare -a T_SIZES=()   # 大小 KB
declare -a T_LABELS=()  # 展示名
declare -a T_CATS=()    # 所属类别
declare -a T_PREVIEW=() # 报告页的路径预览（空串 = 不预览）
TOTAL_KB=0

_add() {  # _add <cat> <label> <kb> <keep_zero> <路径...>
  local cat="$1" label="$2" kb="$3" keep="$4"; shift 4
  [ "$#" -gt 0 ] || return 0
  [ "${kb}" -eq 0 ] && [ "${keep}" -ne 1 ] && return 0
  local joined; joined=$(printf '%s\n' "$@")
  T_PATHS+=("${joined}"); T_SIZES+=("${kb}")
  T_LABELS+=("${label}"); T_CATS+=("${cat}")
  T_PREVIEW+=("")
  TOTAL_KB=$((TOTAL_KB + kb))
}

# 组的路径预览：报告页最多显示 max 条，多则给省略行
build_preview() {  # build_preview <max> <路径...>
  local max="$1"; shift
  local n="$#" shown=0 out="" p
  for p in "$@"; do
    shown=$((shown + 1))
    [ "${shown}" -gt "${max}" ] && break
    if [ -n "${out}" ]; then out="${out}
${p}"; else out="${p}"; fi
  done
  if [ "${n}" -gt "${max}" ]; then
    out="${out}
…还有 $(( n - max )) 个（--clean 确认页可见全部路径）"
  fi
  printf '%s' "${out}"
}

add_target() {  # add_target <cat> <path> [label]
  local cat="$1" path="$2" label="${3:-}"
  [ -e "${path}" ] || return 0
  [ -n "${label}" ] || label="${path#"${SWEEP_HOME}"/}"
  _add "${cat}" "${label}" "$(kb_of "${path}")" 0 "${path}"
}

add_group() {  # add_group <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add "${cat}" "${label}" "${kb}" 0 "$@"
}

echo "整机垃圾清理  SWEEP_HOME=${SWEEP_HOME}  今天=${today}"
echo "模式：$([ "${CLEAN}" -eq 1 ] && echo '扫描 + 逐项确认清理（移入废纸篓）' || echo '只扫描，不删除任何文件')"
have_filters && echo "筛选：只处理名字或路径含「$(filters_desc)」的项"
echo

# ───────── 1) Xcode DerivedData（闲置 ≥ XCODE_DD_AGE_MIN 分钟）────────────
# 目录名形如 MyApp-abcdef1234。阈值内动过 = 可能正在构建，不碰。
dd_root="${SWEEP_HOME}/Library/Developer/Xcode/DerivedData"
dd_found=0; dd_kept_active=0
if [ -d "${dd_root}" ]; then
  for d in "${dd_root}"/*/; do
    [ -d "${d}" ] || continue
    dd_found=$((dd_found + 1))
    m=$(mtime_of "${d%/}")
    age_min=$(( (now - m) / 60 ))
    if [ "${age_min}" -lt "${XCODE_DD_AGE_MIN}" ]; then
      dd_kept_active=$((dd_kept_active + 1))
      continue
    fi
    add_target "Xcode DerivedData" "${d%/}" \
      "DerivedData/$(basename "${d}")/（闲置 ${age_min} 分钟）"
  done
  [ "${dd_found}" -gt 0 ] && \
    add_info "Xcode DerivedData: 共 ${dd_found} 个项目数据，${dd_kept_active} 个闲置不足 ${XCODE_DD_AGE_MIN} 分钟已跳过（可能在构建）"
fi

# ───────── 2) Xcode iOS DeviceSupport（闲置 ≥ IOS_SUPPORT_AGE_DAYS 天）────
# 真机调试时从设备拉出来的系统符号。升级 iOS 后旧版本就用不上了。
ios_root="${SWEEP_HOME}/Library/Developer/Xcode/iOS DeviceSupport"
ios_found=0; ios_kept_recent=0
if [ -d "${ios_root}" ]; then
  for d in "${ios_root}"/*/; do
    [ -d "${d}" ] || continue
    ios_found=$((ios_found + 1))
    m=$(mtime_of "${d%/}")
    age_days=$(( (now - m) / 86400 ))
    if [ "${age_days}" -lt "${IOS_SUPPORT_AGE_DAYS}" ]; then
      ios_kept_recent=$((ios_kept_recent + 1))
      continue
    fi
    add_target "iOS DeviceSupport" "${d%/}" \
      "iOS DeviceSupport/$(basename "${d}")/（闲置 ${age_days} 天）"
  done
  [ "${ios_found}" -gt 0 ] && \
    add_info "iOS DeviceSupport: 共 ${ios_found} 个版本符号，${ios_kept_recent} 个闲置不足 ${IOS_SUPPORT_AGE_DAYS} 天已跳过（真机调试要用）"
fi

# ───────── 3) CoreSimulator Caches ──────────────────────────────────────────
add_target "模拟器缓存" "${SWEEP_HOME}/Library/Developer/CoreSimulator/Caches"

# ───────── 4) 各语言包管理器缓存 ───────────────────────────────────────────
# 这些目录本身就是「可随时删的缓存」，删掉只影响下次下载/构建速度。
for d in "${SWEEP_HOME}/.npm" \
         "${SWEEP_HOME}/.yarn/cache" \
         "${SWEEP_HOME}/Library/pnpm/cache" \
         "${LIB_CACHES}/pip" \
         "${SWEEP_HOME}/.cache/pip" \
         "${SWEEP_HOME}/.cache/go-build" \
         "${SWEEP_HOME}/.gradle/caches" \
         "${LIB_CACHES}/CocoaPods"; do
  [ -e "${d}" ] || continue
  add_target "包管理器缓存" "${d}"
done

# ───────── 4b) Maven *.lastUpdated 失败下载残留 ────────────────────────────
if [ -d "${SWEEP_HOME}/.m2/repository" ]; then
  ml=()
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    ml+=("${f}")
  done < <(find "${SWEEP_HOME}/.m2/repository" -name '*.lastUpdated' -type f 2>/dev/null)
  if [ "${#ml[@]}" -gt 0 ]; then
    kb=$(kb_of_multi "${ml[@]}")
    T_PATHS+=("$(printf '%s\n' "${ml[@]}")"); T_SIZES+=("${kb}")
    T_LABELS+=("Maven *.lastUpdated（${#ml[@]} 个）"); T_CATS+=("Maven 失败下载残留")
    T_PREVIEW+=("$(build_preview 6 "${ml[@]}")")
    TOTAL_KB=$((TOTAL_KB + kb))
  fi
fi

# ───────── 5) 浏览器缓存（只碰 Cache / Code Cache）─────────────────────────
# 硬编码白名单路径：Cache 之外的东西（Cookie、Login Data、History）
# 连清单都进不了 —— 这是「白名单优先于规则」的落地。
for prof_root in \
  "${SWEEP_HOME}/Library/Application Support/Google/Chrome" \
  "${SWEEP_HOME}/Library/Application Support/Microsoft Edge" \
  "${SWEEP_HOME}/Library/Application Support/BraveSoftware/Brave-Browser" \
  "${SWEEP_HOME}/Library/Application Support/Chromium" \
  "${SWEEP_HOME}/Library/Application Support/Arc/User Data" \
  "${SWEEP_HOME}/Library/Application Support/Vivaldi" \
  "${SWEEP_HOME}/Library/Application Support/com.operasoftware.Opera"; do
  [ -d "${prof_root}" ] || continue
  while IFS= read -r prof; do
    [ -n "${prof}" ] || continue
    for sub in "Cache" "Code Cache"; do
      add_target "浏览器缓存" "${prof}/${sub}"
    done
  done < <(find "${prof_root}" -maxdepth 1 -type d \( -name 'Default' -o -name 'Profile *' \) 2>/dev/null)
done

# ───────── 6) 旧日志（闲置 ≥ LOG_AGE_DAYS 天）──────────────────────────────
# 只删 .log / .log.gz / .out；活日志太新，被阈值自然挡住。
if [ -d "${LIB_LOGS}" ]; then
  keep_logs=(); total_logs=0
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    total_logs=$((total_logs + 1))
    age_days=$(( (now - $(mtime_of "${f}")) / 86400 ))
    [ "${age_days}" -ge "${LOG_AGE_DAYS}" ] && keep_logs+=("${f}")
  done < <(find "${LIB_LOGS}" -type f \( -name '*.log' -o -name '*.log.gz' -o -name '*.out' \) 2>/dev/null)
  if [ "${#keep_logs[@]}" -gt 0 ]; then
    kb=$(kb_of_multi "${keep_logs[@]}")
    T_PATHS+=("$(printf '%s\n' "${keep_logs[@]}")"); T_SIZES+=("${kb}")
    T_LABELS+=("闲置 ≥ ${LOG_AGE_DAYS} 天的日志（${#keep_logs[@]} 个）")
    T_CATS+=("旧日志")
    T_PREVIEW+=("$(build_preview 6 "${keep_logs[@]}")")
    TOTAL_KB=$((TOTAL_KB + kb))
  fi
  skipped_logs=$(( total_logs - ${#keep_logs[@]} ))
  [ "${skipped_logs}" -gt 0 ] && \
    add_info "旧日志: 另有 ${skipped_logs} 个日志闲置不足 ${LOG_AGE_DAYS} 天，已保留"
fi

# ───────── 7) 散落 .DS_Store ────────────────────────────────────────────────
# HOME 下 ≤ DS_MAX_DEPTH 层；Library 只扫 Logs/Caches 两处（其他区域不进）。
ds_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  ds_files+=("${f}")
done < <(find "${SWEEP_HOME}" -maxdepth "${DS_MAX_DEPTH}" -name '.DS_Store' -type f \
             -not -path "*/Library/*" 2>/dev/null; \
         find "${LIB_LOGS}" "${LIB_CACHES}" -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  kb=$(kb_of_multi "${ds_files[@]}")
  T_PATHS+=("$(printf '%s\n' "${ds_files[@]}")"); T_SIZES+=("${kb}")
  T_LABELS+=("散落 .DS_Store（${#ds_files[@]} 个）"); T_CATS+=("散落 .DS_Store")
  T_PREVIEW+=("$(build_preview 6 "${ds_files[@]}")")
  TOTAL_KB=$((TOTAL_KB + kb))
fi

# ───────── 8) node_modules 内的 .cache ─────────────────────────────────────
# 不碰 node_modules 本体（重装代价大），只收里面的 .cache 子目录。
nm_cache=()
while IFS= read -r d; do
  [ -n "${d}" ] || continue
  nm_cache+=("${d}")
done < <(find "${SWEEP_HOME}" -maxdepth 4 -type d -name node_modules \
             -not -path "*/Library/*" -print 2>/dev/null \
           | while IFS= read -r nm; do
               find "${nm}" -maxdepth 2 -type d -name '.cache' -print 2>/dev/null
             done)
if [ "${#nm_cache[@]}" -gt 0 ]; then
  kb=$(kb_of_multi "${nm_cache[@]}")
  T_PATHS+=("$(printf '%s\n' "${nm_cache[@]}")"); T_SIZES+=("${kb}")
  T_LABELS+=("node_modules 内的 .cache（${#nm_cache[@]} 个）"); T_CATS+=("node_modules .cache")
  T_PREVIEW+=("$(build_preview 6 "${nm_cache[@]}")")
  TOTAL_KB=$((TOTAL_KB + kb))
fi

# ═════════════════════════════════════════════════════════════════════════════
# 只报告区统计
# ═════════════════════════════════════════════════════════════════════════════

kb_dir() {  # 目录 KB（不存在返回 0）
  local kb=0
  [ -d "$1" ] && kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  printf '%s' "${kb:-0}"
}

as_kb=$(kb_dir "${SWEEP_HOME}/Library/Application Support")
dev_kb=$(kb_dir "${SWEEP_HOME}/Library/Developer")
cnt_kb=$(kb_dir "${SWEEP_HOME}/Library/Containers")
gcnt_kb=$(kb_dir "${SWEEP_HOME}/Library/Group Containers")
caches_kb=$(kb_dir "${LIB_CACHES}")

# Application Support 里已纳入清单的浏览器缓存体积（算差值用）
browser_in_list=0
i=0
while [ "${i}" -lt "${#T_PATHS[@]}" ]; do
  if [ "${T_CATS[$i]}" = "浏览器缓存" ]; then
    browser_in_list=$((browser_in_list + T_SIZES[$i]))
  fi
  i=$((i + 1))
done

add_info "Application Support: 共 $(human "${as_kb}")（浏览器缓存之外的一切整目录不碰；其中浏览器缓存已入清单 $(human "${browser_in_list}")）"
add_info "  绝不碰的登录态文件: Cookie / Login Data / History / Web Data / Preferences / Local Storage / Sessions / Sync Data"
add_info "Library/Developer: 共 $(human "${dev_kb}")（DerivedData / DeviceSupport / 模拟器缓存之外的部分不碰，如模拟器设备运行时）"
add_info "Library/Containers + Group Containers: 共 $(human "$(( cnt_kb + gcnt_kb ))")（沙箱 App 的家，整区域不碰）"
add_info "Library/Caches: 共 $(human "${caches_kb}")（脚本只认领上面清单列到的具体子目录；Caches 下没列到的一律不碰）"
add_info "Safari 数据 / Desktop / Documents / Downloads 等用户目录 / .git / .ssh / 密钥凭据: 永不在扫描范围"

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
  else
    echo "没有匹配「$(filters_desc)」的项（清单里共 ${#T_PATHS[@]} 项）。"
    echo "去掉关键词即可看到完整清单。"
  fi
else
  prev_cat=""; num=0
  for i in "${S_IDX[@]}"; do
    num=$((num + 1))
    if [ "${T_CATS[$i]}" != "${prev_cat}" ]; then
      echo
      echo "[${T_CATS[$i]}]"
      prev_cat="${T_CATS[$i]}"
    fi
    printf '  [%02d] %8s  %s\n' "${num}" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}"
    if [ -n "${T_PREVIEW[$i]}" ]; then
      printf '%s\n' "${T_PREVIEW[$i]}" | sed 's/^/          /'
    fi
  done

  echo
  echo "------------------------------------------"
  printf '命中 %d 项 / %d 处 / 合计 %s\n' "${n_sel}" "${sel_paths}" "$(human "${sel_kb}")"
  if have_filters && [ "${n_sel}" -lt "${#T_PATHS[@]}" ]; then
    printf '（清单里另有 %d 项未命中筛选，未计入，也不会被清理）\n' "$(( ${#T_PATHS[@]} - n_sel ))"
  fi
fi

# 只报告区：永远显示，永不清理
if [ "${#INFO_LINES[@]}" -gt 0 ]; then
  echo
  echo "=============== 以下不清理（只报告） ==============="
  for line in "${INFO_LINES[@]}"; do
    printf '  · %s\n' "${line}"
  done
fi

echo
echo "以上仅为报告，未删除任何文件。"

# ── 未加 --clean：报告完就结束 ──
if [ "${CLEAN}" -ne 1 ]; then
  echo
  echo "清楚了要清哪些，就把关键词接在 --clean 后面："
  if have_filters; then
    echo "  bash $0 --clean $(filters_desc)          # 列出清单，输入 yes 才动手"
    echo "  bash $0 --clean $(filters_desc) --yes    # 跳过二次确认（--yes 必须带筛选）"
  else
    echo "  bash $0 --clean xcode        # 只清含 xcode 的项"
    echo "  bash $0 --clean xcode logs   # 多个关键词 = 并集"
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

if [ "${n_sel}" -eq 0 ]; then
  echo
  echo "没有可清理的项，本次不执行任何操作。"
  exit 0
fi

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

ok=0; fail=0

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
    if move_group "${i}"; then
      printf '  [OK]  %s\n' "${T_LABELS[$i]}"
      ok=$((ok + 1))
    else
      printf '  [ERR] %s —— 有文件没能移入废纸篓\n' "${T_LABELS[$i]}"
      fail=$((fail + 1))
    fi
  done
  echo "=============================================="

elif [ "${MODE}" = "pick" ]; then
  echo "================ 逐项挑选 ================"
  echo "y=移入  n=跳过  q=退出"
  echo
  num=0
  for i in "${S_IDX[@]}"; do
    num=$((num + 1))
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
              ok=$((ok + 1))
            else
              echo "  [ERR] 有文件没能移入"
              fail=$((fail + 1))
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
printf '成功 %d 项，失败 %d 项\n' "${ok}" "${fail}"
echo
echo "这些内容现在在 ${HOME}/.Trash 里，可随时拖回。"
echo "确认无误后清空废纸篓，磁盘空间才会真正释放。"
