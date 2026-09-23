#!/usr/bin/env bash
#
# tencent_meeting-sweep.sh — 清理腾讯会议堆积的运行日志 / 动态资源包 / AI 模型 / WebKit 缓存
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# 腾讯会议是沙盒应用，绝大部分数据在一个容器里（本机实测 591M）：
#   TM_CONTAINER = ~/Library/Containers/com.tencent.meeting
#   └── Data/Library/
#       ├── Global/                                                    590M
#       │   ├── Data/                                                  467M
#       │   │   ├── DynamicResourcePackage/*.zip   141 个（304M）★ 下载的资源包
#       │   │   ├── DynamicResource/<hash>/         71 个（114M）★ 解压后的资源
#       │   │   ├── AudioModel/<hash>/               1 个（ 36M）★ AI 降噪模型
#       │   │   ├── TemplateResources/                       5.4M  模板资源
#       │   │   ├── AvatarModel/                             5.4M  虚拟形象模型
#       │   │   ├── Avatars/                                 2.3M  头像缓存
#       │   │   ├── CustomLayoutPreview/                     0.6M
#       │   │   └── XCast/StartUp/Timezone/WWLink/…           116K  配置类，不碰
#       │   ├── Logs/                                                  100M
#       │   │   ├── <prefix>_YYYYMMDDHH.log(.zip)  417+59 个          ★ 大头
#       │   │   │   prefix: wmp / xcast / quic / canary / lchr_meeting /
#       │   │   │           app_installer / qimei / filedelta / wwlink
#       │   │   ├── {wmp,canary,qimei,filedelta}.log.mmap3  ★ 活跃 mmap 句柄，绝不碰
#       │   │   ├── 2026-09-15.965..pere.rp / crash_count.log
#       │   │   └── im/                                             704K
#       │   │       ├── imsdk_C_YYYYMMDD-N.xlog   21 个历史归档
#       │   │       └── imsdk_C.mmap2              ★ 当前会话句柄，绝不碰
#       │   ├── Xnn/<hash>/humansegment_pc/                            19M  ★ 人像分割模型
#       │   ├── Database/                                             4.0M  ★ 聊天库等（保护）
#       │   └── Preferences/                                          292K  ★ 配置（保护）
#       ├── Users/Default/<hash>/                                     1.2M  ★ 账号数据（保护）
#       └── Caches/{Data,Temp,audio_detect_record}                      16K
#   另有容器外：
#       ~/Library/Caches/com.tencent.meeting                          2.8M  ★ WebKit/Cache.db
#       ~/Library/Caches/com.tencent.meeting.services.wmexternal      240K  ★ 共享组件缓存
#       ~/Library/Application Support/com.tencent.meeting/com.tencent.bugly  4K（崩溃上报）
#       ~/Library/HTTPStorages/com.tencent.meeting                    168K  ★ 登录态（保护）
#       ~/Documents/TencentMeeting                                     8K   ★ 会议录制（保护）
#
# 扫描目标（按类别）：
#   1) 运行日志                Global/Logs/<prefix>_YYYYMMDDHH.log(.zip)
#                              —— 每进程每小时一份；**最近 TM_LOG_KEEP_HOURS 小时的保留**
#   2) IM 历史日志             Global/Logs/im/imsdk_C_YYYYMMDD-N.xlog
#                              —— 保留最新 1 份归档（当前会话的 .mmap2 不碰）
#   3) 已解压资源包            Global/Data/DynamicResourcePackage/<hash>.zip
#                              —— 仅当 DynamicResource/<hash> 或 AudioModel/<hash>
#                                 已存在才算「已解压」；资源本体还在，删包零代价
#   4) WebKit / HTTP 缓存      ~/Library/Caches/com.tencent.meeting（Cache.db* / WebKit /
#                              RaftMonitor）+ com.tencent.meeting.services.wmexternal
#   5) 容器临时缓存            Data/Library/Caches/{Data,Temp,audio_detect_record}
#   6) 头像与崩溃上报          Global/Data/Avatars + com.tencent.bugly
#
#   --aggressive 追加（有代价，确认再用）：
#     · 未解压资源包          DynamicResourcePackage 里其余 zip
#                             ⚠️ 删后再次用到该资源时会重新下载
#     · 动态资源本体          Global/Data/DynamicResource/<hash>/
#                             ⚠️ 删后界面首次用到时重新下载解压
#     · AI 模型               Global/Data/AudioModel/ + Global/Xnn/<hash>/humansegment_pc/
#                             ⚠️ 背景降噪与人像分割模型，首次使用会重新下载
#     · 虚拟形象与模板        AvatarModel / TemplateResources / CustomLayoutPreview
#
# 【绝对不碰】—— 账号、聊天记录、配置、登录态、会议录制（脚本内有硬防线，命中即拒绝）：
#   - Global/Database/（本地聊天与会议库）、Global/Preferences/（偏好设置）
#   - Users/Default/<hash>/（账号数据：登录态、通讯录、会议记录索引）
#   - ~/Library/HTTPStorages/com.tencent.meeting（Cookies 登录态）
#   - ~/Library/Preferences/com.tencent.meeting.plist
#   - ~/Documents/TencentMeeting/（会议录制文件与转写稿）
#   - Global/{XMagic,WWLink,crash_count_down2,module_config_path.*,voiceprint_record}
#   - Global/Data/{XCast,StartUp,Timezone,Timeline,IM,WWLink}
#   - 一切 *.mmap2 / *.mmap3（日志组件的活跃内存映射文件）、imsdk_C.mmap2
#   - Global/Logs 里非 <prefix>_YYYYMMDDHH 命名的文件（.rp / crash_count.log 等）
#
# 用法：
#   ./tencent_meeting-sweep.sh                     # 扫描 → 列清单 → 交互选择
#   ./tencent_meeting-sweep.sh log                 # 只把名字/路径含 log 的项列进清单
#   ./tencent_meeting-sweep.sh log 模型            # 多个关键词 = 并集
#   ./tencent_meeting-sweep.sh --only log,cache    # 逗号连写，等价于空格分隔
#   ./tencent_meeting-sweep.sh 资源 --and zip      # 交集：同时含两词才算
#   ./tencent_meeting-sweep.sh --aggressive        # 清单额外含未解压包 / 模型 / 资源本体
#   ./tencent_meeting-sweep.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐项确认（y=移入 n=跳过 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./tencent_meeting-sweep.sh --clean 运行日志 --yes   # 跳过交互，直接清匹配项
#   ./tencent_meeting-sweep.sh --clean --all            # 进交互但清单是全部，仍需手输 yes
#   ⚠️ 裸 --clean（既没关键词也没 --all）拒绝执行，退出码 2 —— 手滑敲出来不会变成全删。
#   ⚠️ --yes 必须带筛选条件：--clean --all --yes 这种「一句话全清空」被刻意堵死。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「类别名 / 条目名 / 条目内任一完整路径」的子串，忽略大小写。
#   多个关键词默认「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（再给一个关键词就切回并集），可混排：a b --and c = (a 或 b) 且 c。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
#    注意：废纸篓里的东西仍占磁盘，清空废纸篓后空间才真正释放。
#
# 可调环境变量：
#   TM_CONTAINER         腾讯会议沙盒容器，
#                        默认 ~/Library/Containers/com.tencent.meeting
#   TM_LOG_KEEP_HOURS    运行日志保留小时数，默认 2（更近的不动）
#
# ⚠️ 建议先退出腾讯会议再清：运行中清理通常也安全（进程会重建缓存），但日志类
#    目标正被进程持有句柄，退出后清理更干净。脚本检测到运行中会给出提示。
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
    echo "--yes 必须带筛选条件（如 --clean 运行日志 --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

TM_CONTAINER="${TM_CONTAINER:-${HOME}/Library/Containers/com.tencent.meeting}"
TM_LOG_KEEP_HOURS="${TM_LOG_KEEP_HOURS:-2}"

# 环境变量可能是空的或被写成非数字（export VAR= / VAR=x）——回落到默认值
case "${TM_LOG_KEEP_HOURS}" in ''|*[!0-9]*) TM_LOG_KEEP_HOURS=2 ;; esac

# 容器内的 Data/Library 才是数据根，展示路径时以它为基准，读起来最短
TM_HOME="${TM_CONTAINER}/Data/Library"

[ -d "${TM_HOME}" ] || {
  echo "目录不存在: ${TM_HOME}" >&2
  echo "（没装腾讯会议，或者是别的通道版本？可用 TM_CONTAINER=... 指定容器根）" >&2
  exit 1
}

today=$(date +%Y-%m-%d)
now=$(date +%s)

# ═════════════════════════════════════════════════════════════════════════════
# 输出组件（与 workbuddy-sweep.sh 保持一致，改一处建议同步另一处）
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

SCAN_TOTAL=7

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

# 展示用短标签：容器内 → 相对 Data/Library 的路径；HOME 内 → ~/...；其余原样
rel_label() {
  local p="$1"
  case "${p}" in
    "${TM_HOME}"/*)  printf '%s' "${p#"${TM_HOME}"/}" ;;
    "${HOME}"/*)     printf '~/%s' "${p#"${HOME}"/}" ;;
    *)               printf '%s' "${p}" ;;
  esac
}

# 腾讯会议是否正在运行（运行中日志被进程持有句柄，退出后清更干净）
app_running() {
  pgrep -f 'TencentMeeting.app' >/dev/null 2>&1
}

# ───────── ★ 硬防线：用户数据保护名单 ─────────
# 任何待加入清单的路径，其 basename 命中这里 → 直接拒绝。
# 这是独立于扫描逻辑的第二道闸：就算将来扫描规则写错，也碰不到这些。
# ⚠️ 用「整段相等」而非子串匹配，所以 'AVATARS'（要清的缓存）不会挡住 'Avatars' 之外的任何东西。
PROTECT_PATTERNS='
Database
Preferences
Users
HTTPStorages
TencentMeeting
Documents
voiceprint_record
module_config_path.tv
module_config_path.tk
crash_count_down2
crash_count.log
XMagic
WWLink
XCast
StartUp
Timezone
Timeline
IM
imsdk_C.mmap2
canary.log.mmap3
wmp.log.mmap3
qimei.log.mmap3
filedelta.log.mmap3
'

is_protected() {  # is_protected <路径> → 命中保护名单返回 0
  local p="$1" comp line
  comp=$(basename "${p}")
  # 活跃 mmap 句柄：任何 *.mmap2 / *.mmap3 一律不放行（日志组件的内存映射）
  case "${comp}" in
    *.mmap2|*.mmap3) return 0 ;;
  esac
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
}

PROTECTED_SKIPPED=0

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
# 选择解析（与 workbuddy-sweep.sh 逐字一致）
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

_add_checked() {  # _add_checked <cat> <label> <kb> <keep_zero> <路径...>
  local cat="$1" label="$2" kb="$3" keep="$4"; shift 4
  [ "$#" -gt 0 ] || return 0
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
  [ "${kb}" -eq 0 ] && [ "${keep}" -ne 1 ] && return 0
  local joined; joined=$(printf '%s\n' "${clean_list[@]}")
  T_PATHS+=("${joined}"); T_SIZES+=("${kb}")
  T_LABELS+=("${label}"); T_CATS+=("${cat}")
  TOTAL_KB=$((TOTAL_KB + kb))
}

add_target() {  # add_target <cat> <path> [label]
  local cat="$1" path="$2" label="${3:-}"
  [ -e "${path}" ] || return 0
  [ -n "${label}" ] || label=$(rel_label "${path}")
  _add_checked "${cat}" "${label}" "$(kb_of "${path}")" 0 "${path}"
}

add_group() {  # add_group <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add_checked "${cat}" "${label}" "${kb}" 0 "$@"
}

# ───────── 腾讯会议路径常量 ─────────
TM_GLOBAL="${TM_HOME}/Global"
TM_DATA="${TM_GLOBAL}/Data"
TM_LOGS="${TM_GLOBAL}/Logs"
TM_PKG="${TM_DATA}/DynamicResourcePackage"
TM_RES="${TM_DATA}/DynamicResource"
TM_AUDIO="${TM_DATA}/AudioModel"

# 日志保留阈值：比当前时间早 TM_LOG_KEEP_HOURS 的整点。YYYYMMDDHH 定宽，字典序即时间序。
# BSD date 的 -v 在 macOS 上可用；取不到就置空 → 日志一段整体跳过（宁可不清，不可清错）。
_cutoff_raw=$(date -v-"${TM_LOG_KEEP_HOURS}"H +%Y%m%d%H 2>/dev/null) || _cutoff_raw=""
LOG_CUTOFF="${_cutoff_raw}"

ui_head "腾讯会议 清理" \
  "容器           ${TM_CONTAINER}" \
  "今天           ${today}" \
  "模式           $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入未解压资源包 / 动态资源本体 / AI 模型 / 虚拟形象模板"
if app_running; then
  ui_note "⚠️  腾讯会议正在运行：日志类目标被进程持有句柄，退出应用后清理更干净（缓存类可随时清）"
fi
ui_note "扫描中…（进度见下方）"

# ───────── 1) 运行日志 ─────────
# Logs/<prefix>_YYYYMMDDHH.log(.zip)：每个进程每小时一份。
# 判据两条：名字严格匹配 <前缀>_10位时间戳、(可选).log(.zip)；且时间戳早于阈值。
# 非该命名的文件（*.mmap2/mmap3、*.rp、crash_count.log）一律不碰 —— 可能是活跃句柄。
scan_step "运行日志"
log_files=()
skipped_logs=0
if [ -d "${TM_LOGS}" ] && [ -n "${LOG_CUTOFF}" ]; then
  for f in "${TM_LOGS}"/*; do
    [ -f "${f}" ] || continue
    b=$(basename "${f}")
    case "${b}" in
      *.log.zip) stem="${b%.log.zip}" ;;
      *.log)     stem="${b%.log}" ;;
      *)         skipped_logs=$((skipped_logs + 1)); continue ;;   # mmap / rp / 其他
    esac
    ts="${stem##*_}"        # 取最后一个下划线之后的部分
    case "${ts}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) skipped_logs=$((skipped_logs + 1)); continue ;;          # 前缀带下划线但尾部非时间戳
    esac
    # 阈值与冷却期内的保留
    [ "${ts}" \< "${LOG_CUTOFF}" ] || continue
    log_files+=("${f}")
  done
fi
if [ "${#log_files[@]}" -gt 0 ]; then
  add_group "运行日志" \
            "Global/Logs 历史运行日志（${#log_files[@]} 份，最近 ${TM_LOG_KEEP_HOURS} 小时的保留）" \
            "$(kb_of_multi "${log_files[@]}")" "${log_files[@]}"
fi

# ───────── 2) IM 历史日志 ─────────
# Logs/im/imsdk_C_YYYYMMDD-N.xlog：按天归档，保留最新 1 份。
# imsdk_C.mmap2 是当前会话的内存映射，恒不碰（保护名单里也有一道）。
scan_step "IM 日志"
im_logs=()
newest_im_date=""
if [ -d "${TM_LOGS}/im" ]; then
  for f in "${TM_LOGS}/im"/*.xlog; do
    [ -f "${f}" ] || continue
    b=$(basename "${f}")
    case "${b}" in
      imsdk_C_*) rest="${b#imsdk_C_}" ;;
      *) continue ;;
    esac
    d="${rest%%-*}"
    case "${d}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    if [ -z "${newest_im_date}" ] || [ "${d}" \> "${newest_im_date}" ]; then
      newest_im_date="${d}"
    fi
  done
  for f in "${TM_LOGS}/im"/*.xlog; do
    [ -f "${f}" ] || continue
    b=$(basename "${f}")
    case "${b}" in
      imsdk_C_*) rest="${b#imsdk_C_}" ;;
      *) continue ;;
    esac
    d="${rest%%-*}"
    case "${d}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    [ "${d}" = "${newest_im_date}" ] && continue      # 最新一份归档保留
    im_logs+=("${f}")
  done
fi
if [ "${#im_logs[@]}" -gt 0 ]; then
  add_group "IM 日志" \
            "Global/Logs/im 历史归档（${#im_logs[@]} 份，最新一份保留）" \
            "$(kb_of_multi "${im_logs[@]}")" "${im_logs[@]}"
fi

# ───────── 3) 已解压资源包 ─────────
# DynamicResourcePackage/<hash>.zip 是下载下来的资源包；解压产物落在
# DynamicResource/<hash>/ 或 AudioModel/<hash>/。**只有解压产物已存在时才算零代价**
# —— 资源本体还在，包纯粹是留着的下载残留。
scan_step "已解压资源包"
pkg_done=()
pkg_pending=()
if [ -d "${TM_PKG}" ]; then
  for f in "${TM_PKG}"/*.zip; do
    [ -f "${f}" ] || continue
    h=$(basename "${f}" .zip)
    if [ -d "${TM_RES}/${h}" ] || [ -d "${TM_AUDIO}/${h}" ]; then
      pkg_done+=("${f}")
    else
      pkg_pending+=("${f}")
    fi
  done
fi
if [ "${#pkg_done[@]}" -gt 0 ]; then
  add_group "已解压资源包" \
            "DynamicResourcePackage 已解压的下载包（${#pkg_done[@]} 个，资源本体已就位）" \
            "$(kb_of_multi "${pkg_done[@]}")" "${pkg_done[@]}"
fi

# ───────── 4) WebKit / HTTP 缓存 ─────────
scan_step "WebKit / HTTP 缓存"
add_target "WebKit / HTTP 缓存" "${HOME}/Library/Caches/com.tencent.meeting"
add_target "WebKit / HTTP 缓存" "${HOME}/Library/Caches/com.tencent.meeting.services.wmexternal"

# ───────── 5) 容器临时缓存 ─────────
scan_step "容器临时缓存"
tmp_paths=()
for d in "Temp" "Data" "audio_detect_record"; do
  p="${TM_HOME}/Caches/${d}"
  [ -e "${p}" ] || continue
  tmp_paths+=("${p}")
done
if [ "${#tmp_paths[@]}" -gt 0 ]; then
  add_group "容器临时缓存" \
            "Caches/ 容器临时文件（${#tmp_paths[@]} 处）" \
            "$(kb_of_multi "${tmp_paths[@]}")" "${tmp_paths[@]}"
fi

# ───────── 6) 头像与崩溃上报 ─────────
scan_step "头像与崩溃上报"
add_target "头像与崩溃上报" "${TM_DATA}/Avatars"
add_target "头像与崩溃上报" "${HOME}/Library/Application Support/com.tencent.meeting/com.tencent.bugly"

# ───────── 7) aggressive 项 ─────────
scan_step "aggressive 项"
if [ "${AGGRESSIVE}" -eq 1 ]; then
  # 7a) 未解压资源包
  if [ "${#pkg_pending[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "DynamicResourcePackage 未解压的下载包（${#pkg_pending[@]} 个，再次用到时重新下载）" \
      "$(kb_of_multi "${pkg_pending[@]}")" "${pkg_pending[@]}"
  fi

  # 7b) 动态资源本体（解压产物）
  res_dirs=()
  if [ -d "${TM_RES}" ]; then
    for d in "${TM_RES}"/*/; do
      [ -d "${d}" ] || continue
      res_dirs+=("${d%/}")
    done
  fi
  if [ "${#res_dirs[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "DynamicResource 动态资源本体（${#res_dirs[@]} 份，界面首次用到时重新下载解压）" \
      "$(kb_of_multi "${res_dirs[@]}")" "${res_dirs[@]}"
  fi

  # 7c) AI 模型：音频降噪模型 + 人像分割模型
  model_paths=()
  if [ -d "${TM_AUDIO}" ]; then
    for d in "${TM_AUDIO}"/*/; do
      [ -d "${d}" ] || continue
      model_paths+=("${d%/}")
    done
  fi
  if [ -d "${TM_GLOBAL}/Xnn" ]; then
    for d in "${TM_GLOBAL}/Xnn"/*/; do
      [ -d "${d}" ] || continue
      model_paths+=("${d%/}")
    done
  fi
  if [ "${#model_paths[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "AI 模型 AudioModel / Xnn（${#model_paths[@]} 份，背景降噪与人像分割，首次使用会重新下载）" \
      "$(kb_of_multi "${model_paths[@]}")" "${model_paths[@]}"
  fi

  # 7d) 虚拟形象与模板资源
  theme_paths=()
  for d in "AvatarModel" "TemplateResources" "CustomLayoutPreview"; do
    p="${TM_DATA}/${d}"
    [ -e "${p}" ] || continue
    theme_paths+=("${p}")
  done
  if [ "${#theme_paths[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "虚拟形象与模板资源（${#theme_paths[@]} 处，按需重新下载）" \
      "$(kb_of_multi "${theme_paths[@]}")" "${theme_paths[@]}"
  fi
fi

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
  echo "   当前占用: $(du -sh "${TM_HOME}" 2>/dev/null | cut -f1)"
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
printf '   清理前占用: %s\n' "$(du -sh "${TM_HOME}" 2>/dev/null | cut -f1)"

# 真数据保护提示（不删，仅告知规模，方便确认「大头不在清理范围」）
live_paths=()
for d in "Global/Database" "Global/Preferences" "Users" "Global/XMagic" "Global/WWLink"; do
  [ -e "${TM_HOME}/${d}" ] && live_paths+=("${TM_HOME}/${d}")
done
[ -e "${HOME}/Library/HTTPStorages/com.tencent.meeting" ] && \
  live_paths+=("${HOME}/Library/HTTPStorages/com.tencent.meeting")
[ -e "${HOME}/Documents/TencentMeeting" ] && \
  live_paths+=("${HOME}/Documents/TencentMeeting")
live_total=0
for p in ${live_paths[@]+"${live_paths[@]}"}; do live_total=$((live_total + $(kb_of "${p}"))); done

if [ "${live_total}" -gt 0 ]; then
  ui_note "保护中: 数据库/配置/账号/登录态/会议录制 共 $(human "${live_total}")（永不清理）"
fi
if [ -d "${HOME}/Documents/TencentMeeting" ]; then
  ui_note "Global 之外的会议录制与转写稿在 ~/Documents/TencentMeeting，从不纳入扫描"
fi
if [ "${skipped_logs}" -gt 0 ]; then
  ui_note "Global/Logs 有 ${skipped_logs} 个非时间戳命名的文件（mmap / rp 等活跃句柄），一律不碰"
fi
[ "${#pkg_pending[@]}" -gt 0 ] && [ "${AGGRESSIVE}" -ne 1 ] && \
  ui_note "另有 ${#pkg_pending[@]} 个未解压资源包 $(human "$(kb_of_multi ${pkg_pending[@]+"${pkg_pending[@]}"})")（删后需重新下载，用 --aggressive 纳入）"
[ "${PROTECTED_SKIPPED}" -gt 0 ] && \
  ui_note "保护名单拦下 ${PROTECTED_SKIPPED} 处（独立于扫描逻辑的硬防线）"

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
printf '   清理后占用: %s\n' "$(du -sh "${TM_HOME}" 2>/dev/null | cut -f1)"
if [ "${ok}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
else
  printf '   未移动任何文件。\n'
fi
ui_end
