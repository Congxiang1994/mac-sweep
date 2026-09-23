#!/usr/bin/env bash
#
# vscode-sweep.sh — 清理 VS Code 堆积的渲染缓存 / 字节码缓存 / webview 缓存 / 会话日志 / 孤立工作区状态
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# VS Code 的数据布局（本机实测 1.138.0，Electron user-data-dir）：
#   VSCODE_HOME = ~/Library/Application Support/Code               238M
#   ├── Cache / Code Cache / GPUCache / Dawn*Cache                  1.8M  Chromium 缓存
#   ├── CachedData                                                  26M  V8 字节码缓存
#   ├── CachedExtensionVSIXs                                        22M  扩展 VSIX 下载包
#   ├── clp                                                        3.2M  语言包译文缓存
#   ├── Partitions/vscode-browser/{Cache,Code Cache,GPUCache}       41M  内置浏览器缓存
#   ├── WebStorage/*/CacheStorage                                   25M  webview CacheStorage
#   ├── logs/<YYYYMMDDTHHMMSS>/                                    1.2M  每启动一次一场
#   ├── crash-logs/ + Crashpad/                                     56K
#   └── User/
#       ├── workspaceStorage/<hash>/                               85M  ★ 每个工作区一份状态
#       ├── globalStorage/                                         28M  ★ 扩展全局状态
#       ├── History/                                              628K  ★ 本地编辑历史（时间线）
#       └── settings.json / profiles / sync                      ★ 设置本体
#   另有 ~/.vscode/extensions 347M（扩展本体，绝不属于清理范围）
#
# 扫描目标（按类别）：
#   1) 渲染与 GPU 缓存（根）   Cache / Code Cache / GPUCache /
#                              DawnWebGPUCache / DawnGraphiteCache /
#                              Shared Dictionary / blob_storage
#                              —— 纯 Chromium 缓存，重开自动重建
#   2) 字节码与下载缓存        CachedData（V8 字节码）/ CachedExtensionVSIXs
#                              （已下载的扩展安装包）/ CachedProfilesData
#                              —— VS Code 按需重新生成或重新下载
#   3) Partitions 浏览缓存     每个 Partition 的 Cache / Code Cache / GPUCache /
#                              Dawn*Cache / Shared Dictionary
#                              —— 内置浏览器（webview）的 HTTP 缓存，42M 级大头
#   4) Webview CacheStorage    WebStorage/<origin>/CacheStorage
#                              —— webview 的 Cache API 存储，联网后重取
#   5) 隐私追踪残留            根目录 + 每个 Partition 的 Trust Tokens /
#                              DIPS / SharedStorage / InterestGroups
#                              —— Chromium 广告归因 API 的落盘数据，清了无副作用
#   6) 会话日志                logs/<YYYYMMDDTHHMMSS>/  整体删
#                              —— 每启动一次生成一场；**最新一场与冷却期内的不动**
#   7) 崩溃转储                Crashpad/{completed,new,pending,attachments} 非空子目录 +
#                              crash-logs/workspaces/*/.processed-crashes.json
#                              —— 保留 Crashpad/settings.dat（崩溃上报开关）
#   8) 语言包译文缓存          clp/<hash>.<locale>/
#                              —— 从语言包扩展重新生成的译文缓存
#   9) 系统级缓存              ~/Library/Caches/com.microsoft.VSCode（Electron HTTP 缓存）
#                              ~/Library/Caches/com.microsoft.VSCode.ShipIt（更新器缓存）
#  10) 杂项小文件              Session Storage/LOG.old + 散落 .DS_Store（3 层）
#
#   --aggressive 追加（有代价，确认再用）：
#     · 孤立工作区状态        User/workspaceStorage/<hash>/ 中「源目录已不存在」
#                             且闲置 ≥ VSCODE_ORPHAN_COOLDOWN_DAYS 天的条目
#                             ⚠️ 会连带删掉该工作区的 Copilot 聊天记录与扩展工作区状态
#     · Copilot 语义索引      globalStorage/github.copilot-chat/{setting,command}Embeddings.json
#                             ⚠️ 删后首次提问需重新建立索引
#     · Service Worker 缓存   Service Worker/{CacheStorage,ScriptCache}
#     · Session Storage       根目录 + 每个 Partition（会话级存储）
#     · 设置同步缓存          User/sync/（下次同步重新拉取）
#
# 【绝对不碰】—— 设置、扩展、登录态、聊天记录、编辑历史（脚本内有硬防线，命中即拒绝）：
#   - User/settings.json、keybindings.json、tasks.json、launch.json、snippets/、profiles/
#   - User/globalStorage/state.vscdb（全局状态）、storage.json、各扩展的数据目录
#   - User/globalStorage/github.copilot-chat/session-store.db（Copilot 聊天记录）
#   - User/History/（本地编辑历史，就是「时间线」）
#   - User/workspaceStorage/<hash>/ 中源目录**仍然存在**的条目（正在用的工作区状态）
#   - agentSessionData/（agent 会话库）、agent-host.db
#   - ~/.vscode/extensions（扩展本体 347M）、argv.json
#   - ~/Library/HTTPStorages/com.microsoft.VSCode（Cookies.binarycookies = 登录态）
#   - crash-logs 的目录结构、Crashpad/settings.dat、machineid、Preferences、code.lock
#
# 用法：
#   ./vscode-sweep.sh                     # 扫描 → 列清单 → 交互选择
#   ./vscode-sweep.sh log                 # 只把名字/路径含 log 的项列进清单
#   ./vscode-sweep.sh log crash           # 多个关键词 = 并集
#   ./vscode-sweep.sh --only log,crash    # 逗号连写，等价于空格分隔
#   ./vscode-sweep.sh cache --and web     # 交集：同时含两词才算
#   ./vscode-sweep.sh --aggressive        # 清单额外含孤立工作区 / Copilot 索引等
#   ./vscode-sweep.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐项确认（y=移入 n=跳过 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./vscode-sweep.sh --clean log --yes   # 跳过交互，直接清匹配项
#   ./vscode-sweep.sh --clean --all       # 进交互但清单是全部，仍需手输 yes
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
#   VSCODE_HOME                 VS Code 数据目录，
#                               默认 ~/Library/Application Support/Code
#                               （Code Insiders 用 ~/Library/Application Support/Code - Insiders）
#   VSCODE_LOG_COOLDOWN_MIN     会话日志冷却期，默认 60 分钟（更近的日志不动）
#   VSCODE_ORPHAN_COOLDOWN_DAYS 孤立工作区冷却期，默认 7 天（更近的不动）
#
# ⚠️ 建议先退出 VS Code 再清：清理时 VS Code 持有部分 LevelDB / SQLite 文件句柄，
#    运行中清理通常也安全（进程会重建），但 Session Storage 与状态库类目标
#    在退出后清理更干净。脚本检测到运行中会给出提示。
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
    echo "--yes 必须带筛选条件（如 --clean log --yes）—— --all 不算筛选。" >&2
    echo "    也就是说 --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

VSCODE_HOME="${VSCODE_HOME:-${HOME}/Library/Application Support/Code}"
VSCODE_LOG_COOLDOWN_MIN="${VSCODE_LOG_COOLDOWN_MIN:-60}"
VSCODE_ORPHAN_COOLDOWN_DAYS="${VSCODE_ORPHAN_COOLDOWN_DAYS:-7}"

# 环境变量可能是空的或被写成非数字（export VAR= / VAR=x）——回落到默认值
case "${VSCODE_LOG_COOLDOWN_MIN}" in ''|*[!0-9]*) VSCODE_LOG_COOLDOWN_MIN=60 ;; esac
case "${VSCODE_ORPHAN_COOLDOWN_DAYS}" in ''|*[!0-9]*) VSCODE_ORPHAN_COOLDOWN_DAYS=7 ;; esac

[ -d "${VSCODE_HOME}" ] || {
  echo "目录不存在: ${VSCODE_HOME}" >&2
  echo "（没装 VS Code，或是 Insiders / VSCodium？可用 VSCODE_HOME=... 指定）" >&2
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

SCAN_TOTAL=11

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

# 展示用短标签：VSCODE_HOME 内 → 相对路径；HOME 内 → ~/...；其余原样
rel_label() {
  local p="$1"
  case "${p}" in
    "${VSCODE_HOME}"/*) printf '%s' "${p#"${VSCODE_HOME}"/}" ;;
    "${HOME}"/*)        printf '~/%s' "${p#"${HOME}"/}" ;;
    *)                  printf '%s' "${p}" ;;
  esac
}

# URL 解码（workspace.json 里的路径是 file:// 形式，空格被写成 %20）
# 先替换 %XX 为 \xXX，再让 printf 解释 —— 不依赖 python / perl。
urldecode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

# 从 workspace.json 取出工作区 URI（"folder" 或 "workspace"，二者互斥）。
# 用纯参数展开解析，不用 sed：macOS 自带 BSD sed 不支持 `\(a\|b\)` 交替，
# 且不同机器上 PATH 里的 sed 可能是 toybox 等实现，行为更难预料。
get_ws_uri() {  # get_ws_uri <workspace.json 路径> → URI（取不到返回 1）
  local f="$1" line val
  [ -f "${f}" ] || return 1
  while IFS= read -r line; do
    case "${line}" in
      *'"folder"'*|*'"workspace"'*) ;;
      *) continue ;;
    esac
    val="${line#*:}"           # 砍掉键名与冒号之前
    case "${val}" in *'"'*) ;; *) continue ;; esac
    val="${val#*\"}"           # 砍掉值的起始引号之前
    val="${val%%\"*}"          # 取到下一个引号为止
    [ -n "${val}" ] || continue
    printf '%s' "${val}"
    return 0
  done < "${f}"
  return 1
}

# VS Code 是否正在运行（正在跑时清 Session Storage / 状态库不够干净）
app_running() {
  pgrep -f 'Visual Studio Code.app' >/dev/null 2>&1
}

# ───────── ★ 硬防线：用户数据保护名单 ─────────
# 任何待加入清单的路径，其 basename 命中这里 → 直接拒绝。
# 这是独立于扫描逻辑的第二道闸：就算将来扫描规则写错，也碰不到这些。
PROTECT_PATTERNS='
state.vscdb
state.vscdb.backup
storage.json
settings.json
keybindings.json
tasks.json
launch.json
snippets
profiles
history
History
chatSessions
chatEditingSessions
session-store.db
session-store.db-wal
session-store.db-shm
agent-host.db
agent-host-config.json
session.db
machineid
Preferences
code.lock
languagepacks.json
argv.json
extensions
Cookies
Cookies-journal
Local Storage
IndexedDB
'

is_protected() {  # is_protected <路径> → 命中保护名单返回 0
  local p="$1" comp line
  comp=$(basename "${p}")
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

ui_head "VS Code 清理" \
  "VSCODE_HOME   ${VSCODE_HOME}" \
  "今天          ${today}" \
  "模式          $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入孤立工作区状态 / Copilot 语义索引 / SW 缓存 / Session Storage"
if app_running; then
  ui_note "⚠️  VS Code 正在运行：清 Session Storage 与状态库类目标建议先退出应用（缓存类可随时清）"
fi
ui_note "扫描中…（进度见下方）"

# ───────── 1) 渲染与 GPU 缓存（根目录）─────────
scan_step "渲染与 GPU 缓存"
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary" "blob_storage"; do
  add_target "渲染与 GPU 缓存" "${VSCODE_HOME}/${d}"
done

# ───────── 2) 字节码与下载缓存 ─────────
scan_step "字节码与下载缓存"
for d in "CachedData" "CachedExtensionVSIXs" "CachedProfilesData"; do
  add_target "字节码与下载缓存" "${VSCODE_HOME}/${d}"
done

# ───────── 3) Partitions 浏览缓存 ─────────
scan_step "Partitions 浏览缓存"
for part in "${VSCODE_HOME}/Partitions"/*/; do
  [ -d "${part}" ] || continue
  pname=$(basename "${part}")
  for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
           "Shared Dictionary"; do
    add_target "Partitions 浏览缓存" "${part%/}/${d}" \
               "Partitions/${pname}/${d}"
  done
done

# ───────── 4) Webview CacheStorage ─────────
scan_step "Webview CacheStorage"
web_cs=()
for d in "${VSCODE_HOME}/WebStorage"/*/CacheStorage; do
  [ -e "${d}" ] || continue
  [ -n "$(ls -A "${d}" 2>/dev/null | head -1)" ] || continue
  web_cs+=("${d}")
done
if [ "${#web_cs[@]}" -gt 0 ]; then
  add_group "Webview CacheStorage" \
            "WebStorage/<origin>/CacheStorage（${#web_cs[@]} 个 origin）" \
            "$(kb_of_multi "${web_cs[@]}")" "${web_cs[@]}"
fi

# ───────── 5) 隐私追踪残留 ─────────
scan_step "隐私追踪残留"
privacy_dirs=()
for d in InterestGroups "Trust Tokens" "Trust Tokens-journal" \
         "DIPS" "DIPS-journal" "DIPS-wal" \
         "SharedStorage" "SharedStorage-wal" "SharedStorage-journal"; do
  p="${VSCODE_HOME}/${d}"
  [ -e "${p}" ] || continue
  privacy_dirs+=("${p}")
done
for part in "${VSCODE_HOME}/Partitions"/*/; do
  [ -d "${part}" ] || continue
  for d in InterestGroups "Trust Tokens" "Trust Tokens-journal" \
           "DIPS" "DIPS-journal" "DIPS-wal" \
           "SharedStorage" "SharedStorage-wal" "SharedStorage-journal"; do
    p="${part%/}/${d}"
    [ -e "${p}" ] || continue
    privacy_dirs+=("${p}")
  done
done
if [ "${#privacy_dirs[@]}" -gt 0 ]; then
  add_group "隐私追踪残留" \
            "InterestGroups/TrustTokens/DIPS/SharedStorage（${#privacy_dirs[@]} 处）" \
            "$(kb_of_multi "${privacy_dirs[@]}")" "${privacy_dirs[@]}"
fi

# ───────── 6) 会话日志 ─────────
# logs/<YYYYMMDDTHHMMSS>/：每启动一次 VS Code 生成一场。
# 判据三条：名字严格匹配时间戳格式、不是最新一场、mtime 已过冷却期。
scan_step "会话日志"
log_dirs=()
newest_log=""
if [ -d "${VSCODE_HOME}/logs" ]; then
  for d in "${VSCODE_HOME}/logs"/*/; do
    [ -d "${d}" ] || continue
    dname=$(basename "${d%/}")
    case "${dname}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;   # 非时间戳命名的目录不碰
    esac
    [ -z "${newest_log}" ] && newest_log="${dname}"
    if [ "${dname}" \> "${newest_log}" ]; then newest_log="${dname}"; fi
  done
  for d in "${VSCODE_HOME}/logs"/*/; do
    [ -d "${d}" ] || continue
    dname=$(basename "${d%/}")
    case "${dname}" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    [ "${dname}" = "${newest_log}" ] && continue    # 最新一场 = 当前实例，保留
    m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "${now}")
    case "${m}" in ''|*[!0-9]*) m="${now}" ;; esac
    [ "$(( now - m ))" -lt "$(( VSCODE_LOG_COOLDOWN_MIN * 60 ))" ] && continue
    log_dirs+=("${d%/}")
  done
fi
if [ "${#log_dirs[@]}" -gt 0 ]; then
  add_group "会话日志" \
            "logs/ 历史会话日志（${#log_dirs[@]} 场，最新一场与 ${VSCODE_LOG_COOLDOWN_MIN} 分钟内的保留）" \
            "$(kb_of_multi "${log_dirs[@]}")" "${log_dirs[@]}"
fi

# ───────── 7) 崩溃转储 ─────────
scan_step "崩溃转储"
crash_paths=()
for d in completed new pending attachments; do
  p="${VSCODE_HOME}/Crashpad/${d}"
  [ -d "${p}" ] || continue
  # 只收非空目录（空目录删了也无意义）
  [ -n "$(ls -A "${p}" 2>/dev/null | head -1)" ] && crash_paths+=("${p}")
done
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  crash_paths+=("${f}")
done < <(find "${VSCODE_HOME}/crash-logs/workspaces" -maxdepth 2 \
           -name '.processed-crashes.json' -type f 2>/dev/null)
if [ "${#crash_paths[@]}" -gt 0 ]; then
  add_group "崩溃转储" "Crashpad / crash-logs 崩溃记录（${#crash_paths[@]} 处）" \
            "$(kb_of_multi "${crash_paths[@]}")" "${crash_paths[@]}"
fi

# ───────── 8) 语言包译文缓存 ─────────
# clp/<hash>.<locale>/：从语言包扩展（ms-ceintl.vscode-language-pack-*）
# 重新生成的译文缓存，删除后重新打开即重建。
scan_step "语言包译文缓存"
clp_dirs=()
for d in "${VSCODE_HOME}/clp"/*/; do
  [ -d "${d}" ] || continue
  clp_dirs+=("${d%/}")
done
if [ "${#clp_dirs[@]}" -gt 0 ]; then
  add_group "语言包译文缓存" "clp/ 语言包译文缓存（${#clp_dirs[@]} 个语言）" \
            "$(kb_of_multi "${clp_dirs[@]}")" "${clp_dirs[@]}"
fi

# ───────── 9) 系统级缓存（~/Library/Caches）─────────
scan_step "系统级缓存"
add_target "系统级缓存" "${HOME}/Library/Caches/com.microsoft.VSCode"
add_target "系统级缓存" "${HOME}/Library/Caches/com.microsoft.VSCode.ShipIt"

# ───────── 10) 杂项小文件 ─────────
scan_step "杂项小文件"
misc_files=()
[ -f "${VSCODE_HOME}/Session Storage/LOG.old" ] && \
  misc_files+=("${VSCODE_HOME}/Session Storage/LOG.old")
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  misc_files+=("${f}")
done < <(find "${VSCODE_HOME}" -maxdepth 3 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#misc_files[@]}" -gt 0 ]; then
  add_group "杂项小文件" "LOG.old / .DS_Store（${#misc_files[@]} 个）" \
            "$(kb_of_multi "${misc_files[@]}")" "${misc_files[@]}"
fi

# ───────── 11) aggressive 项 ─────────
scan_step "aggressive 项"
if [ "${AGGRESSIVE}" -eq 1 ]; then
  # 11a) 孤立工作区状态：workspace.json 指向的目录已不存在，且闲置够久
  orphan_dirs=()
  ws_store="${VSCODE_HOME}/User/workspaceStorage"
  if [ -d "${ws_store}" ]; then
    for d in "${ws_store}"/*/; do
      [ -d "${d}" ] || continue
      dj="${d%/}/workspace.json"
      [ -f "${dj}" ] || continue          # 判不出归属的条目一律不碰
      uri=$(get_ws_uri "${dj}")
      [ -n "${uri}" ] || continue
      case "${uri}" in
        file://*) wpath=$(urldecode "${uri#file://}") ;;
        *)        wpath="${uri}" ;;
      esac
      [ -n "${wpath}" ] || continue
      [ -e "${wpath}" ] && continue       # 源目录还在 = 正在用，保留
      m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "${now}")
      case "${m}" in ''|*[!0-9]*) m="${now}" ;; esac
      [ "$(( now - m ))" -lt "$(( VSCODE_ORPHAN_COOLDOWN_DAYS * 86400 ))" ] && continue
      orphan_dirs+=("${d%/}")
    done
  fi
  if [ "${#orphan_dirs[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "孤立工作区状态 workspaceStorage（${#orphan_dirs[@]} 个：源目录已不存在且闲置 ≥ ${VSCODE_ORPHAN_COOLDOWN_DAYS} 天）" \
      "$(kb_of_multi "${orphan_dirs[@]}")" "${orphan_dirs[@]}"
  fi

  # 11b) Copilot 语义索引（按需重建，删后首次提问会重新建索引）
  cop_idx=()
  for f in settingEmbeddings.json commandEmbeddings.json; do
    p="${VSCODE_HOME}/User/globalStorage/github.copilot-chat/${f}"
    [ -f "${p}" ] || continue
    cop_idx+=("${p}")
  done
  if [ "${#cop_idx[@]}" -gt 0 ]; then
    add_group "aggressive 项" "Copilot 语义索引（${#cop_idx[@]} 个，按需重建）" \
              "$(kb_of_multi "${cop_idx[@]}")" "${cop_idx[@]}"
  fi

  # 11c) Service Worker 缓存 + Session Storage（根 + 各 Partition）
  sw_paths=()
  for p in "${VSCODE_HOME}/Service Worker/CacheStorage" \
           "${VSCODE_HOME}/Service Worker/ScriptCache" \
           "${VSCODE_HOME}/Session Storage"; do
    [ -e "${p}" ] || continue
    sw_paths+=("${p}")
  done
  for part in "${VSCODE_HOME}/Partitions"/*/; do
    [ -d "${part}" ] || continue
    p="${part%/}/Session Storage"
    [ -e "${p}" ] && sw_paths+=("${p}")
  done
  if [ "${#sw_paths[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
              "Service Worker 缓存 / Session Storage（${#sw_paths[@]} 处）" \
              "$(kb_of_multi "${sw_paths[@]}")" "${sw_paths[@]}"
  fi

  # 11d) 设置同步缓存（下次同步重新拉取）
  if [ -d "${VSCODE_HOME}/User/sync" ]; then
    add_group "aggressive 项" "User/sync 设置同步缓存（下次同步重新拉取）" \
              "$(kb_of "${VSCODE_HOME}/User/sync")" "${VSCODE_HOME}/User/sync"
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
  echo "   当前占用: $(du -sh "${VSCODE_HOME}" 2>/dev/null | cut -f1)"
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
printf '   清理前占用: %s\n' "$(du -sh "${VSCODE_HOME}" 2>/dev/null | cut -f1)"

# 真数据保护提示（不删，仅告知规模，方便确认「大头不在清理范围」）
# 口径：只统计**永不清理**的路径，避免与 aggressive 清单里的 Copilot 索引重复计算。
ext_kb=0
[ -d "${HOME}/.vscode/extensions" ] && ext_kb=$(kb_of "${HOME}/.vscode/extensions")
live_paths=()
for d in "User/profiles" "User/History" "agentSessionData" \
         "User/globalStorage/state.vscdb" "User/globalStorage/state.vscdb.backup" \
         "User/globalStorage/storage.json" \
         "User/globalStorage/github.copilot-chat/session-store.db" \
         "User/globalStorage/github.copilot-chat/session-store.db-wal" \
         "User/globalStorage/github.copilot-chat/session-store.db-shm"; do
  [ -e "${VSCODE_HOME}/${d}" ] && live_paths+=("${VSCODE_HOME}/${d}")
done
[ -e "${HOME}/Library/HTTPStorages/com.microsoft.VSCode" ] && \
  live_paths+=("${HOME}/Library/HTTPStorages/com.microsoft.VSCode")
live_total=0
for p in ${live_paths[@]+"${live_paths[@]}"}; do live_total=$((live_total + $(kb_of "${p}"))); done

if [ "${ext_kb}" -gt 0 ]; then
  ui_note "保护中: ~/.vscode/extensions 扩展本体 $(human "${ext_kb}")（永不清理）"
fi
if [ "${live_total}" -gt 0 ]; then
  ui_note "保护中: profiles/History/agentSessionData/状态库/聊天记录/登录态 共 $(human "${live_total}")（永不清理）"
fi
# globalStorage 其余部分是各扩展自有数据，不属于「永不清理」也不属于缓存 —— 单独交代清楚
gs_kb=$(kb_of "${VSCODE_HOME}/User/globalStorage")
if [ "${gs_kb}" -gt 0 ]; then
  ui_note "globalStorage 共 $(human "${gs_kb}")：扩展自有数据，除 aggressive 列出的 Copilot 索引外一律不碰"
fi
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
printf '   清理后占用: %s\n' "$(du -sh "${VSCODE_HOME}" 2>/dev/null | cut -f1)"
if [ "${ok}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
else
  printf '   未移动任何文件。\n'
fi
ui_end
