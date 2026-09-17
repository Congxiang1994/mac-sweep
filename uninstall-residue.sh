#!/usr/bin/env bash
#
# uninstall-residue.sh — 找出已卸载 macOS 软件遗留的残留数据
#
# ─────────────────────────────────────────────────────────────────────────────
# 默认【只扫描、只报告，一个文件都不删】。加 --clean 才进入逐项确认的清理。
#
# 判定思路：
#   1. 收集当前系统真正装着哪些 App —— /Applications、/System/Applications、
#      Utilities、~/Applications、输入法目录 —— 取出它们的 bundle id、App 名、
#      以及 bundle id 里的组织段（com.<org>.<app> 的 <org>）；
#   2. 遍历 ~/Library 下最容易堆积残留的位置（Application Support / Caches /
#      Preferences / Containers / LaunchAgents / Logs / Saved Application State …）；
#   3. 任何「名字是标准 bundle id，或是某个软件的名字，却在已装 App 里找不到
#      对应物」的条目，判为疑似残留；
#   4. 把同一软件的散落残留聚合成一条，给出路径、体积、最后修改时间。
#
# 报告里的标注：
#   基本确定 — 名字长得就是标准软件标识（如 com.xxx.yyy），系统里却没有这个软件
#   待确认   — 只是个普通文件夹名（如 Docker Desktop），系统里没有同名软件
#   归属不明 — 认不出属于谁，可能只是系统/开发工具目录（默认不显示，--all 才列出）
#
# 用法：
#   ./uninstall-residue.sh                 # 扫描并输出报告（不删任何东西）
#   ./uninstall-residue.sh sogou           # 只看名字/路径含 sogou 的项
#   ./uninstall-residue.sh sogou baidu     # 多个关键词 = 并集（含 sogou 或 baidu）
#   ./uninstall-residue.sh sogou --and pinyin  # 交集（同时含两词才算）
#   ./uninstall-residue.sh --only sogou,baidu  # 逗号连写，等价于空格分隔
#   ./uninstall-residue.sh --all           # 加上「归属不明」项（即「全部」）
#   ./uninstall-residue.sh --system        # 额外扫描 /Library（只读；清理需 sudo）
#   ./uninstall-residue.sh --min-age 180   # 只看 180 天以上没被动过的
#   ./uninstall-residue.sh --clean sogou   # 只清理含 sogou 的那几组
#   ./uninstall-residue.sh --clean sogou baidu        # 清理并集
#   ./uninstall-residue.sh --clean sogou --and pinyin # 只清同时含两词的
#   ./uninstall-residue.sh --clean --all   # 确定全部都要清
#   ./uninstall-residue.sh --clean sogou --yes # 跳过二次确认
#   ./uninstall-residue.sh --report /tmp/r.tsv
#
# ⚠️ --clean 必须明确范围：给关键词筛选，或者给 --all。
#    裸 --clean 什么都不会动（退出码 2）—— 手滑敲出来不会变成全量清理。
#
# ⚠️ 动手前有两道确认：先把「即将移入废纸篓的每一条路径 + 合计体积」完整列出，
#    然后要你手打 yes 才执行（回车或其它任何输入 = 取消，一个文件都不动）。
#    输入 pick 可改为逐组挑选。--yes 能跳过这道确认，但必须带筛选条件。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「组名」或「组内任一完整路径」的子串，忽略大小写。
#   多个关键词默认是「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（如 sogou --and pinyin：同时含两个词才算数）；
#   再给一个关键词就切回并集。用法可混排：a b --and c  =  (a 或 b) 且 c。
#   一个参数里可以用逗号分隔多个词：--only sogou,baidu 等价于 sogou baidu。
#   ⚠️ 报告里的编号只是给你看的，不能拿来当筛选条件 —— 筛选一律按关键词走，
#      这样不会因为清单排序变了而误删到别的项。
#
# 可调环境变量：
#   EXTRA_APP_DIRS  额外参与「已装 App 指纹」的目录，冒号分隔（App 装在非常规位置时用）
#   HOME            用户主目录（测试时指向隔离目录）
#   FORCE_PROGRESS  置 1 时即使输出被重定向也画进度条（进度条走 stderr）
#
# ⚠️ 没有「单次上限」：输入 yes 之后清单上的组一次处理完，不会清到一半停住。
#    批次控制交给你自己 —— 想小步走就带关键词筛选（--clean sogou 之类）。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
# ⚠️ 「归属不明」的项脚本永远不碰 —— 认不出主人，不替你拿主意。
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进变量名，
#    在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
SCAN_SYSTEM=0
MIN_AGE_DAYS=0
REPORT_FILE=""
ASSUME_YES=0
declare -a FILTERS=()          # 关键词（组名 / 路径子串）
JOIN_MODE="or"                 # or = 并集（默认）；and = 交集
LAST_JOIN="or"                 # 最近一个关键词挂的连接符，逗号展开时沿用

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

# 词可以写成 sogou,baidu 或 --only sogou,baidu：按逗号拆开逐个入列。
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
    --system)     SCAN_SYSTEM=1 ;;
    --only)       add_filter_list "${1:-}"; shift || true ;;
    --and|--or)
      LAST_JOIN="or"
      [ "${arg}" = "--and" ] && LAST_JOIN="and"
      # 连接符只对「下一个词」生效
      if [ "${#FILTERS[@]}" -gt 0 ]; then JOIN_MODE="${LAST_JOIN}"; else JOIN_MODE="or"; fi
      ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --min-age)    MIN_AGE_DAYS="${1:-0}"; shift || true ;;
    --report)     REPORT_FILE="${1:-}"; shift || true ;;
    -h|--help)    sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0 ;;
    -*)           echo "未知参数: ${arg}（-h 查看用法）" >&2; exit 2 ;;
    *)            add_filter_list "${arg}" ;;
  esac
done

# 空转的 --and（后面没跟关键词）不该生效，回落到并集
[ "${#FILTERS[@]}" -gt 0 ] || JOIN_MODE="or"

case "${MIN_AGE_DAYS}" in ''|*[!0-9]*) MIN_AGE_DAYS=0 ;; esac

# --yes 是个放大器：只允许配合明确的筛选条件用，绝不允许「不带筛选地全删」
if [ "${ASSUME_YES}" -eq 1 ]; then
  if [ "${CLEAN}" -ne 1 ]; then
    echo "--yes 需与 --clean 一起用。" >&2; exit 2
  fi
  if ! have_filters; then
    echo "--yes 必须带筛选条件（如 --clean sogou --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

LIB="${HOME}/Library"
[ -d "${LIB}" ] || { echo "找不到 ${LIB}" >&2; exit 1; }

now=$(date +%s)
if [ -z "${REPORT_FILE}" ]; then
  REPORT_FILE="./uninstall-residue-$(date +%Y%m%d-%H%M%S).tsv"
fi
TSV_TMP=""
# 中途 Ctrl-C 也不会留下半截报告
trap 'rm -f "${TSV_TMP}" 2>/dev/null' EXIT INT TERM

# ═════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═════════════════════════════════════════════════════════════════════════════

id_lc() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }                        # 小写，保留点
norm()  { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -dc 'a-z0-9'; }  # 只留 a-z0-9

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

# ── 进度条 ────────────────────────────────────────────────────────────────────
# 扫描阶段会给成千上万个目录挨个 du，耗时几十秒，得让人看见「在动」。
# 进度条一律写 stderr：stdout 保持干净的报告文本，方便重定向成文件或走管道。
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
  # 路径太长会顶穿行宽，只留尾部（纯 bash 截断，不 fork）
  if [ "${#label}" -gt 34 ]; then
    cut=$(( ${#label} - 33 ))
    label="…${label:${cut}}"
  fi
  printf '\r  [%s] %3d%%  %s\033[K' "${bar}" "${pct}" "${label}" >&2
}

progress_tick() {  # progress_tick <label>：每 20 条或换了目录时重画一次
  PROG_DONE=$((PROG_DONE + 1))
  if [ "${PROG_DONE}" -ge "${PROG_NEXT}" ] || [ "$1" != "${PROG_LABEL}" ]; then
    draw_progress "${PROG_DONE}" "${PROG_TOTAL}" "$1"
    PROG_NEXT=$((PROG_DONE + 20))
    PROG_LABEL="$1"
  fi
}

finish_progress() {
  [ "${SHOW_PROGRESS}" -eq 1 ] || return 0
  draw_progress "${PROG_TOTAL}" "${PROG_TOTAL}" "扫描完成"
  printf '\n' >&2
}

# ── 筛选 ──────────────────────────────────────────────────────────────────────
# 匹配「组名」或「组内任一完整路径」的子串（忽略大小写）。
#
# 多关键词语义：
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

  # JOIN_MODE=and 时最后一个词是「且」条件，其余参与「或」
  #   a b --and c  =  (a 或 b) 且 c
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

# 词元：小写、按非字母数字切分、去掉通用词与 <4 字符的词
# 通用词若不剔除，「Docker Desktop」「yuque-desktop」「x.desktop」会被误判成同一软件
#   ⚠️ 必须写成单行：awk -v 不接受带换行的取值
STOPWORDS="desktop helper agent daemon service services server updater update client electron framework crashpad crashreporter preferences settings setting cache caches support storage workflow open install installer uninstall launcher runner macos macintosh"

tokens_of() {
  printf '%s' "$1" \
    | LC_ALL=C tr 'A-Z' 'a-z' \
    | LC_ALL=C tr -c 'a-z0-9' '\n' \
    | awk -v sw="${STOPWORDS}" '
        BEGIN { n = split(sw, arr, " "); for (i = 1; i <= n; i++) if (arr[i] != "") stop[arr[i]] = 1 }
        length($0) >= 4 && !($0 in stop) { print }
      '
}

# 两个词元集合是否有「相等」或「一方是另一方前缀（长度 ≥6）」的关系
# ⚠️ 两条都是踩出来的：
#    · 不用「任意子串」—— 否则 sparkle-project 与 qtproject 会因 project 粘成一组
#    · 前缀门槛取 6 而非 5 —— 否则 tencent.qq.share 的 share 会吞掉 SharedDefaults
tokens_related() {
  local a b
  while IFS= read -r a; do
    [ -n "${a}" ] || continue
    while IFS= read -r b; do
      [ -n "${b}" ] || continue
      [ "${a}" = "${b}" ] && return 0
      if [ "${#a}" -ge 6 ]; then case "${b}" in "${a}"*) return 0 ;; esac; fi
      if [ "${#b}" -ge 6 ]; then case "${a}" in "${b}"*) return 0 ;; esac; fi
    done <<< "$2"
  done <<< "$1"
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. 已装 App 指纹
# ═════════════════════════════════════════════════════════════════════════════

APP_DIRS=(
  "/Applications"
  "/Applications/Utilities"
  "/System/Applications"
  "/System/Applications/Utilities"
  "/System/Library/CoreServices/Applications"
  "${HOME}/Applications"
  "/Library/Input Methods"
  "${HOME}/Library/Input Methods"
  "/Library/PreferencePanes"
)

# 额外指纹目录（冒号分隔）：App 装在非常规位置时可用，测试也靠它注入假 App
if [ -n "${EXTRA_APP_DIRS:-}" ]; then
  old_ifs="${IFS}"; IFS=':'
  for extra_dir in ${EXTRA_APP_DIRS}; do
    [ -n "${extra_dir}" ] && APP_DIRS+=("${extra_dir}")
  done
  IFS="${old_ifs}"
fi

declare -a INS_IDS=()          # bundle id（小写，保留点）
declare -a INS_NAMES=()        # App 名（归一化）
declare -a INS_TOKENS=()       # App 名的词元 + bundle id 组织段，用于宽松匹配

collect_installed() {
  local dir app name id seg tok
  for dir in "${APP_DIRS[@]}"; do
    [ -d "${dir}" ] || continue
    for app in "${dir}"/*.app; do
      [ -d "${app}" ] || continue
      name=$(basename "${app}" .app)

      local nn; nn=$(norm "${name}")
      [ -n "${nn}" ] && INS_NAMES+=("${nn}")

      while IFS= read -r tok; do
        [ -n "${tok}" ] && INS_TOKENS+=("${tok}")
      done <<< "$(tokens_of "${name}")"

      id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
             "${app}/Contents/Info.plist" 2>/dev/null || true)
      [ -n "${id}" ] || continue
      INS_IDS+=("$(id_lc "${id}")")

      # 组织段：com.<org>.<app> 取第 2 段；com.tinyspeck.slackmacgap 取倒数第 2 段
      seg=$(printf '%s' "${id}" | awk -F. 'NF>=3{print $2}')
      [ -n "${seg}" ] && [ "${#seg}" -ge 4 ] && INS_TOKENS+=("$(norm "${seg}")")
      seg=$(printf '%s' "${id}" | awk -F. 'NF>=2{print $(NF-1)}')
      [ -n "${seg}" ] && [ "${#seg}" -ge 4 ] && INS_TOKENS+=("$(norm "${seg}")")
    done
  done
}

collect_installed

# 已装 App 的 bundle id 是否覆盖它（自身 / 父级 / 子级）
is_installed_id() {
  local v; v=$(id_lc "$1")
  [ -n "${v}" ] || return 1
  [ "${#INS_IDS[@]}" -gt 0 ] || return 1
  local a
  for a in "${INS_IDS[@]}"; do
    [ "${v}" = "${a}" ] && return 0
    case "${v}" in "${a}".*) return 0 ;; esac   # 残留是已装 id 的子级，如 xxx.helper
    case "${a}" in "${v}".*) return 0 ;; esac   # 残留是已装 id 的父级
  done
  return 1
}

# 目录名是否对应某个已装 App：整体相等，或词元命中（Code ← Visual Studio Code）
is_installed_name() {
  local n; n=$(norm "$1")
  [ -n "${n}" ] || return 1
  local a
  if [ "${#INS_NAMES[@]}" -gt 0 ]; then
    for a in "${INS_NAMES[@]}"; do
      [ "${n}" = "${a}" ] && return 0
    done
  fi
  local toks; toks=$(tokens_of "$1")
  [ -n "${toks}" ] || return 1
  local t
  while IFS= read -r t; do
    [ -n "${t}" ] || continue
    if [ "${#INS_TOKENS[@]}" -gt 0 ]; then
      for a in "${INS_TOKENS[@]}"; do
        [ "${t}" = "${a}" ] && return 0
        # 前缀：WorkBuddyExtension ← WorkBuddy（≥5 字符，避免 code 吞掉 CodeBuddyExtension）
        if [ "${#a}" -ge 5 ]; then case "${t}" in "${a}"*) return 0 ;; esac; fi
      done
    fi
  done <<< "${toks}"
  return 1
}

# bundle id 兜底：整体或末段能对上某个已装 App 名（draw.io ← draw.io.app）
is_installed_id_as_name() {
  local v; v=$(norm "$1")
  [ -n "${v}" ] || return 1
  local a last; last=$(norm "${1##*.}")
  if [ "${#INS_NAMES[@]}" -gt 0 ]; then
    for a in "${INS_NAMES[@]}"; do
      [ "${v}" = "${a}" ] && return 0
      [ -n "${last}" ] && [ "${last}" = "${a}" ] && return 0
    done
  fi
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# 2. 白名单 —— 这些名字不是「卸载残留」，不要误报
# ═════════════════════════════════════════════════════════════════════════════

# 2a. 前缀级：Apple 自家命名空间，以及各家常驻更新器（对应 App 还在时需要它）
IGNORE_ID_PREFIXES=(
  "com.apple."
  "com.google."
  "com.microsoft.autoupdate"
  "com.microsoft.office.licensing"
  "com.adobe.arm"
)

# 2b. 名字级：系统与共享目录（归一化后精确匹配）
IGNORE_NAMES=(
  # macOS 自带
  addressbook addressbookmeta callhistorydb callhistorytransactions
  clouddocs knowledge mobilesync syncservices crashreporter diagnosticreports
  differentialprivacy diskimages fileprovider animoji caches
  icdd homeenergyd familycircled locationaccessstored networkserviceproxy
  unknown loginconfig wwlinksetting
  # 纯配置散件 / 系统内置服务（不是卸载残留）
  icloud tvappservicescontainer isworkflowmyapp loginconfigjson
  settingjson wwlinksettingjson sharedfilelist
  # 开发工具 / SDK 的公共数据目录（不属于某个 App）
  iosentry cef ultralytics
)

is_ignored_id() {
  local v; v=$(id_lc "$1")
  local p
  for p in "${IGNORE_ID_PREFIXES[@]}"; do
    case "${v}" in "${p}"*) return 0 ;; esac
  done
  # 任何一段是 apple 的都算系统（覆盖 systemgroup.com.apple.* / groups.com.apple.*）
  case "${v}" in
    *.apple.*|apple.*) return 0 ;;
  esac
  return 1
}

is_ignored_name() {
  local n; n=$(norm "$1")
  [ -n "${n}" ] || return 1
  local a
  [ "${#IGNORE_NAMES[@]}" -gt 0 ] || return 1
  for a in "${IGNORE_NAMES[@]}"; do
    [ "${n}" = "${a}" ] && return 0
  done
  return 1
}

# 标准 bundle id 形状：至少两段，只含字母数字与 - _
is_bundleid_like() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$'
}

# ═════════════════════════════════════════════════════════════════════════════
# 3. 扫描位置
#    格式 "路径|模式|后缀"
#      模式 id  = 只接受 bundle id 形状的名字（Caches/Containers 之类噪音多，收紧）
#      模式 any = bundle id 与普通目录名都接受
#      后缀     = 只收该扩展名的条目，并把扩展名剥掉当标识
# ═════════════════════════════════════════════════════════════════════════════

declare -a LOCATIONS=(
  "${LIB}/Application Support|any|"
  "${LIB}/Caches|id|"
  "${LIB}/Preferences|id|plist"
  "${LIB}/Logs|any|"
  "${LIB}/Saved Application State|id|savedState"
  "${LIB}/Containers|id|"
  "${LIB}/Group Containers|gid|"
  "${LIB}/WebKit|id|"
  "${LIB}/HTTPStorages|id|binarycookies"
  "${LIB}/Cookies|id|binarycookies"
  "${LIB}/LaunchAgents|id|plist"
  "${LIB}/Application Scripts|any|"
  "${LIB}/Services|any|"
)

if [ "${SCAN_SYSTEM}" -eq 1 ]; then
  LOCATIONS+=(
    "/Library/Application Support|any|"
    "/Library/Caches|id|"
    "/Library/Preferences|id|plist"
    "/Library/Logs|any|"
    "/Library/LaunchAgents|id|plist"
    "/Library/LaunchDaemons|id|plist"
  )
fi

# 先数一遍条目总数，进度条才有分母（纯 glob 数数很便宜，耗时全在下面的 du）
PROG_TOTAL=0
for spec in "${LOCATIONS[@]}"; do
  loc="${spec%%|*}"
  [ -d "${loc}" ] || continue
  for entry in "${loc}"/*; do
    [ -e "${entry}" ] && PROG_TOTAL=$((PROG_TOTAL + 1))
  done
done

# ═════════════════════════════════════════════════════════════════════════════
# 4. 聚合容器（bash 3.2 无关联数组，用平行数组 + 线性查找）
#    每条路径统一存成 "${kb}<TAB>${path}"，多行即为多条
# ═════════════════════════════════════════════════════════════════════════════

declare -a G_NAME=()     # 组显示名
declare -a G_CONF=()     # high / mid
declare -a G_KB=()       # 合计 KB
declare -a G_MTIME=()    # 最近修改 epoch
declare -a G_ITEMS=()    # 换行分隔的 "kb<TAB>path"
declare -a G_TOKENS=()   # 已用词元（换行分隔）
declare -a G_UNKNOWN=()  # 1 = 未识别

TOTAL_KB=0
N_ITEMS=0
N_UNKNOWN=0
SCANNED=0

kb_of() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  echo "${kb:-0}"
}

add_hit() {  # add_hit <identity> <path> <kb> <mtime> <conf>
  local ident="$1" path="$2" kb="$3" mt="$4" conf="$5"
  local toks; toks=$(tokens_of "${ident}")
  local idx="" i
  for i in "${!G_NAME[@]}"; do
    if [ "${G_UNKNOWN[$i]}" -eq 0 ] && [ -n "${toks}" ] \
       && tokens_related "${toks}" "${G_TOKENS[$i]}"; then
      idx="${i}"; break
    fi
  done

  if [ -z "${idx}" ]; then
    G_NAME+=("${ident}"); G_CONF+=("${conf}"); G_KB+=("${kb}")
    G_MTIME+=("${mt}");   G_ITEMS+=("${kb}	${path}"); G_TOKENS+=("${toks}"); G_UNKNOWN+=(0)
  else
    G_KB[$idx]=$(( ${G_KB[$idx]} + kb ))
    [ "${mt}" -gt "${G_MTIME[$idx]}" ] && G_MTIME[$idx]="${mt}"
    G_ITEMS[$idx]="${G_ITEMS[$idx]}
${kb}	${path}"
    G_TOKENS[$idx]="${G_TOKENS[$idx]}
${toks}"
    # 普通目录名比 bundle id 更适合当组标题
    if [ "${G_CONF[$idx]}" = "mid" ] && [ "${conf}" = "high" ]; then
      case "${ident}" in *.*) : ;; *) G_NAME[$idx]="${ident}" ;; esac
    fi
  fi
}

add_unknown() {  # add_unknown <path> <kb> <mtime>
  G_UNKNOWN+=(1); G_NAME+=("$1"); G_CONF+=("low")
  G_KB+=("$2"); G_MTIME+=("$3"); G_ITEMS+=("$2	$1"); G_TOKENS+=("")
}

# ═════════════════════════════════════════════════════════════════════════════
# 5. 扫描
# ═════════════════════════════════════════════════════════════════════════════

echo "已卸载软件残留扫描 · $(date '+%Y-%m-%d %H:%M')"
echo "已装 App 指纹：${#INS_NAMES[@]} 个名字 / ${#INS_IDS[@]} 个 bundle id"
echo "模式：$([ "${CLEAN}" -eq 1 ] && echo '扫描 + 逐项确认清理' || echo '只扫描，不删除任何文件')"
[ "$(have_filters && echo 1 || echo 0)" = "1" ] && echo "筛选：只处理名字或路径含「$(filters_desc)」的项"
echo "扫描中…"

for spec in "${LOCATIONS[@]}"; do
  loc="${spec%%|*}"
  rest="${spec#*|}"
  mode="${rest%%|*}"
  suffix="${rest#*|}"

  [ -d "${loc}" ] || continue
  case "${loc}" in "${HOME}"*) loc_short="~${loc#"${HOME}"}" ;; *) loc_short="${loc}" ;; esac

  for entry in "${loc}"/*; do
    [ -e "${entry}" ] || continue
    progress_tick "${loc_short}"
    name=$(basename "${entry}")

    if [ -n "${suffix}" ]; then
      case "${name}" in
        *".${suffix}") name="${name%".${suffix}"}" ;;
        *) continue ;;
      esac
    fi

    # Group Containers 的形态是 <10 位 team id>.<bundle id>，剥掉 team id 与 "group."
    # ⚠️ 只在这一类位置剥：放在通用位置时，会把 com.google.Keystone.Agent 的前 10 个
    #    字符当 team id 误剥成 Keystone.Agent，导致整个白名单失效
    if [ "${mode}" = "gid" ]; then
      case "${name}" in
        ??????????.*) name="${name#??????????.}" ;;
      esac
      case "${name}" in
        group.*) name="${name#group.}" ;;
      esac
    fi

    [ -n "${name}" ] || continue
    SCANNED=$((SCANNED + 1))

    conf=""; unknown=0
    if is_bundleid_like "${name}"; then
      is_ignored_id "${name}" && continue
      is_ignored_name "${name}" && continue
      is_installed_id "${name}" && continue
      is_installed_id_as_name "${name}" && continue
      conf="high"
    else
      [ "${mode}" = "id" ] && continue
      is_ignored_name "${name}" && continue
      is_installed_name "${name}" && continue
      if printf '%s' "${name}" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]*$' \
         && [ "${#name}" -ge 3 ]; then
        conf="mid"
      else
        unknown=1
      fi
    fi

    kb=$(kb_of "${entry}")
    [ "${kb}" -gt 0 ] || continue

    mt=$(stat -f '%m' "${entry}" 2>/dev/null || echo "${now}")
    case "${mt}" in ''|*[!0-9]*) mt="${now}" ;; esac

    if [ "${MIN_AGE_DAYS}" -gt 0 ]; then
      [ "$(( (now - mt) / 86400 ))" -lt "${MIN_AGE_DAYS}" ] && continue
    fi

    if [ "${unknown}" -eq 1 ]; then
      add_unknown "${entry}" "${kb}" "${mt}"
      N_UNKNOWN=$((N_UNKNOWN + 1))
    else
      add_hit "${name}" "${entry}" "${kb}" "${mt}" "${conf}"
      N_ITEMS=$((N_ITEMS + 1))
    fi
    TOTAL_KB=$((TOTAL_KB + kb))
  done
done

finish_progress

echo "扫描 ${SCANNED} 个条目，命中 ${N_ITEMS} 处（合计 $(human "${TOTAL_KB}")）。"
echo

# ═════════════════════════════════════════════════════════════════════════════
# 6. 排序 + 输出
# ═════════════════════════════════════════════════════════════════════════════

declare -a ORDER=()
i=0
while [ "${i}" -lt "${#G_NAME[@]}" ]; do
  if [ "${G_UNKNOWN[$i]}" -eq 0 ] || [ "${SHOW_ALL}" -eq 1 ]; then
    ORDER+=("${i}")
  fi
  i=$((i + 1))
done

# 按体积降序（插入排序，条目量级只有几十）
if [ "${#ORDER[@]}" -gt 1 ]; then
  j=1
  while [ "${j}" -lt "${#ORDER[@]}" ]; do
    key="${ORDER[$j]}"
    k=$((j - 1))
    while [ "${k}" -ge 0 ] && [ "${G_KB[${ORDER[$k]}]}" -lt "${G_KB[${key}]}" ]; do
      ORDER[$((k + 1))]="${ORDER[$k]}"
      k=$((k - 1))
    done
    ORDER[$((k + 1))]="${key}"
    j=$((j + 1))
  done
fi

echo "================ 疑似残留（按软件聚合）================"
echo

if [ "${#ORDER[@]}" -eq 0 ]; then
  echo "没有发现疑似残留。"
  echo
  exit 0
fi

# 编号固定在排序之后定死：加了关键词筛选也不会变，同一个编号永远指同一条。
declare -a SHOW_IDX=()
declare -a SHOW_NUM=()
k=0
while [ "${k}" -lt "${#ORDER[@]}" ]; do
  idx="${ORDER[$k]}"
  if matches_filters "${G_NAME[$idx]}" "${G_ITEMS[$idx]}"; then
    SHOW_IDX+=("${idx}")
    SHOW_NUM+=("$((k + 1))")
  fi
  k=$((k + 1))
done

if [ "${#SHOW_IDX[@]}" -eq 0 ]; then
  echo "没有匹配「$(filters_desc)」的项。"
  echo "看一眼完整清单（不加筛选条件）：  bash $0"
  echo
  exit 0
fi

TSV_TMP=""
if [ -n "${REPORT_FILE}" ]; then
  TSV_TMP="${REPORT_FILE}.tmp"
  printf 'index\tsoftware\tconfidence\tsize_kb\tlast_modified\tpaths\n' > "${TSV_TMP}" 2>/dev/null \
    || { REPORT_FILE=""; TSV_TMP=""; }
fi

SEL_KB=0; SEL_HIGH=0; SEL_MID=0
n=0
while [ "${n}" -lt "${#SHOW_IDX[@]}" ]; do
  idx="${SHOW_IDX[$n]}"
  num="${SHOW_NUM[$n]}"
  label="${G_NAME[$idx]}"
  case "${G_CONF[$idx]}" in
    high) tag="基本确定" ;;
    mid)  tag="待确认" ;;
    *)    tag="归属不明" ;;
  esac
  mtd=$(date -r "${G_MTIME[$idx]}" '+%Y-%m-%d' 2>/dev/null || echo "?")

  printf '[%02d] %s\n' "${num}" "${label}"
  printf '     %s · 合计 %s · 最近改动 %s\n' "${tag}" "$(human "${G_KB[$idx]}")" "${mtd}"

  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    printf '       %8s  %s\n' "$(human "${ikb}")" "${ipath}"
  done <<< "${G_ITEMS[$idx]}"
  echo

  if [ -n "${TSV_TMP}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${num}" "${label}" "${tag}" "${G_KB[$idx]}" "${mtd}" \
      "$(printf '%s' "${G_ITEMS[$idx]}" | cut -f2- | tr '\n' '|')" >> "${TSV_TMP}"
  fi

  SEL_KB=$((SEL_KB + ${G_KB[$idx]}))
  case "${G_CONF[$idx]}" in
    high) SEL_HIGH=$((SEL_HIGH + 1)) ;;
    mid)  SEL_MID=$((SEL_MID + 1)) ;;
  esac
  n=$((n + 1))
done

if [ -n "${TSV_TMP}" ]; then
  if mv "${TSV_TMP}" "${REPORT_FILE}" 2>/dev/null; then
    TSV_TMP=""
  else
    rm -f "${TSV_TMP}" 2>/dev/null
    REPORT_FILE=""
  fi
fi

echo "------------------------------------------------------"
if have_filters; then
  printf '筛选「%s」：' "$(filters_desc)"
fi
printf '共 %d 项（基本确定 %d / 待确认 %d），合计 %s\n' \
       "${#SHOW_IDX[@]}" "${SEL_HIGH}" "${SEL_MID}" "$(human "${SEL_KB}")"
echo "标注意思：基本确定 = 名字是标准软件标识；待确认 = 只是个普通目录名"
if [ "${SHOW_ALL}" -eq 0 ] && [ "${N_UNKNOWN}" -gt 0 ]; then
  printf '另有 %d 处归属不明未列出（--all 查看）\n' "${N_UNKNOWN}"
fi
[ -n "${REPORT_FILE}" ] && echo "TSV 报告已存：${REPORT_FILE}"
echo

# ═════════════════════════════════════════════════════════════════════════════
# 7. 清理（可选）—— 移入废纸篓，不真删
# ═════════════════════════════════════════════════════════════════════════════

trash_path() {
  local p="$1" base dest trash="${HOME}/.Trash"
  mkdir -p "${trash}" 2>/dev/null || return 1
  base=$(basename "${p}")
  dest="${trash}/${base}"
  [ -e "${dest}" ] && dest="${trash}/${base} $(date +%Y%m%d-%H%M%S)"
  mv "${p}" "${dest}" 2>/dev/null
  [ -e "${p}" ] && return 1
  return 0
}

if [ "${CLEAN}" -ne 1 ]; then
  echo "以上仅为报告，未删除任何文件。"
  echo "只想处理其中几项时，把关键词接在 --clean 后面："
  if have_filters; then
    echo "  bash $0 --clean $(filters_desc)          # 列出清单，输入 yes 才动手"
    echo "  bash $0 --clean $(filters_desc) --yes    # 跳过二次确认（--yes 必须带筛选）"
  else
    echo "  bash $0 --clean sogou        # 只清理含 sogou 的那几组"
    echo "  bash $0 --clean sogou baidu  # 多个关键词 = 并集（sogou 或 baidu）"
    echo "确定全部都要清时（得显式写出来）："
    echo "  bash $0 --clean --all        # 列出全部清单，同样要输入 yes"
  fi
  exit 0
fi

# ── 范围闸：裸 --clean 什么都不会动 ──────────────────────────────────────────
# 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
#   给关键词筛选 ＝ 只清那几项；给 --all ＝ 确认全部都要清。
if ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
  echo "⚠️  没有指定范围，本次不会动任何文件。"
  echo "    只清几项：    bash $0 --clean <关键词>          # 多个词用空格或逗号"
  echo "    全部都要清：  bash $0 --clean --all"
  echo "    上面那份报告就是完整清单，照着名字挑关键词即可。"
  exit 2
fi

# ── 先摆清单，再确认：删除前把「即将动到的每一条」原样列出 ────────────────────
# 「归属不明」的项认不出主人，一律不进程清理清单 —— 哪怕带了 --all
declare -a DEL_IDX=() DEL_NUM=()
n=0
while [ "${n}" -lt "${#SHOW_IDX[@]}" ]; do
  idx="${SHOW_IDX[$n]}"
  if [ "${G_UNKNOWN[$idx]}" -ne 1 ]; then
    DEL_IDX+=("${idx}")
    DEL_NUM+=("${SHOW_NUM[$n]}")
  fi
  n=$((n + 1))
done
N_UNKNOWN_SEL=$(( ${#SHOW_IDX[@]} - ${#DEL_IDX[@]} ))

echo "================ 即将移入废纸篓 ================"
echo

DEL_KB=0; DEL_PATHS=0
n=0
while [ "${n}" -lt "${#DEL_IDX[@]}" ]; do
  idx="${DEL_IDX[$n]}"
  printf '[%02d] %s  ·  %s  ·  %s\n' "${DEL_NUM[$n]}" "${G_NAME[$idx]}" \
         "$(human "${G_KB[$idx]}")" \
         "$([ "${G_CONF[$idx]}" = "high" ] && echo '基本确定' || echo '待确认')"
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    printf '       %8s  %s\n' "$(human "${ikb}")" "${ipath}"
    DEL_KB=$((DEL_KB + ${ikb}))
    DEL_PATHS=$((DEL_PATHS + 1))
  done <<< "${G_ITEMS[$idx]}"
  echo
  n=$((n + 1))
done

printf '合计 %d 组 / %d 处 / %s\n' "${#DEL_IDX[@]}" "${DEL_PATHS}" "$(human "${DEL_KB}")"
if [ "${N_UNKNOWN_SEL}" -gt 0 ]; then
  printf '另有 %d 处「归属不明」不在清单里 —— 认不出属于谁，脚本不替你动\n' "${N_UNKNOWN_SEL}"
fi
echo

if [ "${#DEL_IDX[@]}" -eq 0 ]; then
  echo "没有可处理的项。"
  [ "${N_UNKNOWN_SEL}" -gt 0 ] && echo "（选中的都是「归属不明」项 —— 认不出属于谁，脚本不替你动。）"
  exit 0
fi

# ── 二次确认：必须手打 yes，回车/其它输入一律取消 ─────────────────────────────
if [ "${ASSUME_YES}" -eq 1 ]; then
  echo "⚠️  --yes：跳过二次确认，直接按上面的清单执行（仍在废纸篓里，随时可拖回）"
  MODE="all"
else
  echo "以上就是要移入废纸篓的全部内容。"
  echo "  yes  = 确认，全部移入废纸篓"
  echo "  pick = 逐组挑选"
  echo "  其它 = 取消（什么都不做）"
  printf '> '
  read -r gate || gate=""
  case "${gate}" in
    yes|YES|Yes)    MODE="all" ;;
    pick|PICK|Pick) MODE="pick" ;;
    *) echo "已取消，未删除任何文件。"; exit 0 ;;
  esac
fi
echo

deleted=0; skipped=0; failed=0

if [ "${MODE}" = "all" ]; then
  echo "================ 开始移入废纸篓 ================"
  n=0
  while [ "${n}" -lt "${#DEL_IDX[@]}" ]; do
    idx="${DEL_IDX[$n]}"
    while IFS= read -r item; do
      [ -n "${item}" ] || continue
      p="${item#*	}"
      if trash_path "${p}"; then
        echo "  [废纸篓] ${p}"; deleted=$((deleted + 1))
      else
        echo "  [失败]   ${p}"; failed=$((failed + 1))
      fi
    done <<< "${G_ITEMS[$idx]}"
    n=$((n + 1))
  done
else
  echo "================ 逐组挑选 ================"
  echo "y=整组移入  n=跳过  s=逐条挑  q=退出"
  echo
  n=0
  while [ "${n}" -lt "${#DEL_IDX[@]}" ]; do
    idx="${DEL_IDX[$n]}"
    printf '── [%02d] %s  ·  %s  ·  %s\n' "${DEL_NUM[$n]}" "${G_NAME[$idx]}" \
           "$(human "${G_KB[$idx]}")" \
           "$([ "${G_CONF[$idx]}" = "high" ] && echo '基本确定' || echo '待确认')"
    while IFS= read -r item; do
      [ -n "${item}" ] || continue
      echo "     ${item#*	}"
    done <<< "${G_ITEMS[$idx]}"

    printf '   移入废纸篓？[y/N/s/q] '
    read -r ans || ans="q"
    case "${ans}" in
      y|Y)
        while IFS= read -r item; do
          [ -n "${item}" ] || continue
          p="${item#*	}"
          if trash_path "${p}"; then
            echo "     [废纸篓] ${p}"; deleted=$((deleted + 1))
          else
            echo "     [失败]   ${p}"; failed=$((failed + 1))
          fi
        done <<< "${G_ITEMS[$idx]}"
        ;;
      s|S)
        while IFS= read -r item; do
          [ -n "${item}" ] || continue
          p="${item#*	}"
          printf '     %s ? [y/N] ' "${p}"
          read -r a2 || a2="n"
          case "${a2}" in
            y|Y)
              if trash_path "${p}"; then
                echo "       [废纸篓] 已移入"; deleted=$((deleted + 1))
              else
                echo "       [失败]   无法移动（可能需要权限）"; failed=$((failed + 1))
              fi
              ;;
          esac
        done <<< "${G_ITEMS[$idx]}"
        ;;
      q|Q)
        echo "已退出。"; break
        ;;
      *)
        skipped=$((skipped + 1)) ;;
    esac
    echo
    n=$((n + 1))
  done
fi

echo "------------------------------------------------------"
printf '移入废纸篓 %d 处，整组跳过 %d 组，失败 %d 处\n' "${deleted}" "${skipped}" "${failed}"
echo "全在废纸篓里，确认无误后再清空；拖回来即可还原。"
