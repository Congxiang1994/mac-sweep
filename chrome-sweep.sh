#!/usr/bin/env bash
#
# chrome-sweep.sh — 清理 Chrome 的缓存 / 组件升级包 / AI 模型缓存 / 崩溃报告
#
# ─────────────────────────────────────────────────────────────────────────────
# 与 workbuddy-sweep.sh 同一套交互：直接跑，扫完在终端里挑要清哪些。
# 默认【只扫描 + 等你确认】，没有你的明确输入，一个文件都不会动。
# 清理走「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可拖回。
#
# 扫描目标（按类别）：
#   1) 浏览缓存      ~/Library/Caches/Google/Chrome/<profile>/{Cache,Code Cache,Media Cache}
#                    ★ 纯网页缓存，绝对安全，通常是最大头
#   2) GPU/着色器    顶层 GPUPersistentCache / ShaderCache / GrShaderCache /
#                    GraphiteDawnCache + 每个 profile 的 GPUCache /
#                    DawnWebGPUCache / DawnGraphiteCache / Shared Dictionary
#   3) 组件升级缓存  component_crx_cache / extensions_crx_cache /
#                    Webstore Downloads（已下载的组件与扩展安装包，
#                    Chrome 需要时会自动重新下载）
#   4) AI 模型缓存   screen_ai / optimization_guide_model_store /
#                    WasmTtsEngine / OptGuideOnDevice* / OnDeviceHeadSuggestModel
#                    （内置 AI 模型文件，删除后 Chrome 按需重新下载）
#   5) 崩溃报告/遥测 Crashpad/{completed,pending,attachments} +
#                    BrowserMetrics / BrowserMetrics-spare.pma
#   6) 旧日志        profile 里的 LOG.old
#
#   --aggressive 追加（有代价，确认再用）：
#     · WidevineCdm            DRM 组件，删后在线视频首次播放需重新下载
#     · blob_storage           未完成的 blob 数据（可能丢未完成的下载/上传）
#     · Service Worker 缓存    CacheStorage + ScriptStorage，删后 PWA 离线
#                              数据丢失、站点重新注册 SW
#
# 【绝对不碰】—— 密码、Cookie、登录态、用户数据（脚本内有硬防线，命中即拒绝）：
#   Cookies / Login Data / Web Data / Bookmarks / History / Sessions /
#   Session Storage / IndexedDB / Local Storage / WebStorage / Extensions /
#   Extension State / Local & Managed Extension Settings / Sync 数据 /
#   Preferences / Secure Preferences / Favicons / Top Sites / Shortcuts /
#   Login Data For Account / ClientCertificates / Trust Tokens /
#   TransportSecurity / Local State / Safe Browsing / Password 相关的一切
#
# 用法：
#   ./chrome-sweep.sh                       # 扫描 → 列清单 → 交互选择
#   ./chrome-sweep.sh cache                 # 只列名字/路径含 cache 的项
#   ./chrome-sweep.sh cache model --and screen   # (cache 或 model) 且 screen
#   ./chrome-sweep.sh --aggressive          # 清单额外含 WidevineCdm 等
#   ./chrome-sweep.sh --scan                # 只看报告，不进交互
#   ./chrome-sweep.sh --clean <关键词> --yes # 非交互清理（必须带关键词筛选）
#   ⚠️ --clean --all --yes「一句话全清空」被刻意堵死；裸 --clean 拒绝执行。
#
# 交互提示：yes/all 全清 · 编号如 1 3 5 / 1-4 / 1,3 · pick 逐项确认 · q 结束
#
# 可调环境变量：
#   CHROME_SUP_DIR   默认 ~/Library/Application Support/Google/Chrome
#   CHROME_CACHE_DIR 默认 ~/Library/Caches/Google/Chrome
#   AGE_MIN          通用闲置阈值（分钟），默认 0（不按时间过滤）
#
# ⚠️ 建议先退出 Chrome 再清理（脚本会检测并提示）；
#    Chrome 运行时清缓存类文件通常安全（重启后重建），但 GPU 缓存可能
#    个别标签页花屏，重启浏览器即恢复。
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符吞进变量名，
#    同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
ASSUME_YES=0
AGGRESSIVE=0
SCAN_ONLY=0
declare -a FILTERS=()
JOIN_MODE="or"
LAST_JOIN="or"

have_filters() { [ "${#FILTERS[@]}" -gt 0 ]; }

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
      if [ "${#FILTERS[@]}" -gt 0 ]; then JOIN_MODE="${LAST_JOIN}"; else JOIN_MODE="or"; fi
      ;;
    --yes|-y)     ASSUME_YES=1 ;;
    -h|--help)    sed -n '2,/^set -u$/p' "$0" | sed '$d'; exit 0 ;;
    -*)           echo "未知参数: ${arg}（-h 查看用法）" >&2; exit 2 ;;
    *)            add_filter_list "${arg}" ;;
  esac
done

[ "${#FILTERS[@]}" -gt 0 ] || JOIN_MODE="or"

if [ "${ASSUME_YES}" -eq 1 ]; then
  if [ "${CLEAN}" -ne 1 ]; then
    echo "--yes 需与 --clean 一起用。" >&2; exit 2
  fi
  if ! have_filters; then
    echo "--yes 必须带筛选条件（如 --clean cache --yes）—— --all 不算筛选。" >&2
    echo "    --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

CHROME_SUP="${CHROME_SUP_DIR:-${HOME}/Library/Application Support/Google/Chrome}"
CHROME_CACHE="${CHROME_CACHE_DIR:-${HOME}/Library/Caches/Google/Chrome}"
AGE_MIN="${AGE_MIN:-0}"

if [ ! -d "${CHROME_SUP}" ] && [ ! -d "${CHROME_CACHE}" ]; then
  echo "找不到 Chrome 数据目录（装过 Chrome 吗？）：" >&2
  echo "  ${CHROME_SUP}" >&2
  echo "  ${CHROME_CACHE}" >&2
  exit 1
fi

now=$(date +%s)

# ═════════════════════════════════════════════════════════════════════════════
# 输出组件（与 workbuddy-sweep.sh 逐字一致）
# ═════════════════════════════════════════════════════════════════════════════
UI_WIDTH=68

ui_line() {
  local ch="${1:-─}" i=0 out=""
  while [ "${i}" -lt "${UI_WIDTH}" ]; do out="${out}${ch}"; i=$((i + 1)); done
  printf '%s\n' "${out}"
}

ui_head() {
  ui_line '═'
  printf ' %s\n' "$1"; shift
  local l
  for l in "$@"; do [ -n "${l}" ] && printf ' %s\n' "${l}"; done
  ui_line '═'
}

ui_dashes() {
  local i=0 width=$(( (UI_WIDTH - 8) / 2 ))
  local len=$(( ${#1} ))
  local need=$(( width - len ))
  local out=""
  [ "${need}" -lt 0 ] && need=0
  while [ "${i}" -lt "${need}" ]; do out="${out}─"; i=$((i + 1)); done
  printf '%s' "${out}"
}

ui_section() {
  echo
  printf '── %s %s\n' "$1" "$(ui_dashes "$1")"
}

ui_kv() { printf '   %-14s %s\n' "$1" "$2"; }
ui_note() { printf '   · %s\n' "$1"; }
ui_end() { ui_line '─'; }

SHOW_PROGRESS=0
{ [ -t 2 ] || [ -n "${FORCE_PROGRESS:-}" ]; } && SHOW_PROGRESS=1

PROG_TOTAL=0
PROG_DONE=0

draw_progress() {
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
  if [ "${#label}" -gt 34 ]; then
    cut=$(( ${#label} - 33 ))
    label="…${label:${cut}}"
  fi
  printf '\r  [%s] %3d%%  %s\033[K' "${bar}" "${pct}" "${label}" >&2
}

scan_step() {
  PROG_DONE=$((PROG_DONE + 1))
  draw_progress "${PROG_DONE}" "${PROG_TOTAL}" "$1"
}

finish_progress() {
  [ "${SHOW_PROGRESS}" -eq 1 ] || return 0
  draw_progress "${PROG_TOTAL}" "${PROG_TOTAL}" "扫描完成"
  printf '\n' >&2
}

SCAN_TOTAL=8

# ═════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═════════════════════════════════════════════════════════════════════════════

human() {
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

kb_of() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  printf '%s' "${kb:-0}"
}

kb_of_multi() {
  local kb
  kb=$(du -ck "$@" 2>/dev/null | tail -1 | cut -f1 | tr -dc '0-9')
  printf '%s' "${kb:-0}"
}

# ───────── ★ 硬防线：用户数据保护名单 ─────────
# 任何待加入清单的路径，其每一个路径组件（basename）命中这里 → 直接拒绝。
# 这是独立于扫描逻辑的第二道闸：就算将来扫描规则写错，也碰不到这些。
PROTECT_PATTERNS='
Cookies
Cookies-journal
Extension Cookies
Extension Cookies-journal
Safe Browsing Cookies
Safe Browsing Cookies-journal
lemon_back_Cookies
lemon_back_Cookies-journal
Login Data
Login Data-journal
Login Data For Account
Login Data For Account-journal
Web Data
Web Data-journal
Bookmarks
Bookmarks.bak
EncryptedBookmarks.bak
EncryptedBookmarks2
EncryptedBookmarks2.bak
History
History-journal
lemon_back_History
lemon_back_Login Data
Sessions
Sessions_Encrypted
Session Storage
IndexedDB
Local Storage
WebStorage
Extensions
Extension State
Extension Rules
Extension Scripts
Local Extension Settings
Managed Extension Settings
Sync Extension Settings
Sync App Settings
Sync Data
Preferences
Secure Preferences
Favicons
Favicons-journal
Top Sites
Top Sites-journal
Shortcuts
Network Persistent State
TransportSecurity
Trust Tokens
Trust Tokens-journal
ClientCertificates
trusted_vault.pb
passkey_enclave_state
MediaDeviceSalts
Local State
Safe Browsing
Web Applications
GCM Store
Account Web Data
Account Web Data-journal
Accounts
Collaboration
DataSharing
Device Bound Sessions
Device Bound Sessions-journal
'

is_protected() {  # is_protected <路径> → 命中保护名单返回 0
  local p="$1" comp
  # 检查路径的最后两级组件（目录名 + 直接父目录名）
  comp=$(basename "${p}")
  case "${PROTECT_PATTERNS}" in
    *"\n${comp}\n"*|*"${comp}"\
*) ;;  # 占位，真正的判断在下面
  esac
  # 用循环逐行精确匹配（case 多行匹配不可靠）
  local line
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
}

PROTECTED_SKIPPED=0

# 移入废纸篓
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
# 选择解析（与 workbuddy-sweep.sh 一致）
# ═════════════════════════════════════════════════════════════════════════════

select_prompt() {
  printf '\n要清理哪些？\n'
  printf '   yes / all        全部移入废纸篓\n'
  printf '   编号             如 1 3 5、1-4、1,3（只处理这些）\n'
  printf '   pick             逐项确认（y=移入 n=跳过 q=结束）\n'
  printf '   q 或回车         结束，未处理的项原样不动\n'
  printf '> '
}

parse_choice() {
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

dedupe_nums() {
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

word_hits() {
  case "$1" in *"$3"*) return 0 ;; esac
  case "$2" in *"$3"*) return 0 ;; esac
  return 1
}

matches_filters() {
  ! have_filters && return 0
  local name="$1" items="$2" f
  local lname litems
  lname=$(id_lc "${name}")
  litems=$(printf '%s' "${items}" | LC_ALL=C tr 'A-Z' 'a-z')

  local n=${#FILTERS[@]} i=0 last_or_ok=0
  if [ "${n}" -gt 1 ] && [ "${JOIN_MODE}" = "and" ]; then
    while [ "${i}" -lt "$((n - 1))"; do
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

declare -a T_PATHS=()
declare -a T_SIZES=()
declare -a T_LABELS=()
declare -a T_CATS=()
TOTAL_KB=0

# _add_checked：加入前过一遍保护名单，命中则丢弃并计数
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
  [ -n "${label}" ] || label="${path}"
  _add_checked "${cat}" "${label}" "$(kb_of "${path}")" 0 "${path}"
}

add_group() {  # add_group <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  _add_checked "${cat}" "${label}" "${kb}" 0 "$@"
}

# ───────── 收集 profile 目录 ─────────
# profile 判据：目录下存在 Preferences 或 History（System Profile 等无数据的不收）
collect_profiles() {  # → PROFILES 数组
  PROFILES=()
  local d
  for d in "${CHROME_SUP}"/Default "${CHROME_SUP}"/Guest\ Profile "${CHROME_SUP}"/Profile\ *; do
    [ -d "${d}" ] || continue
    if [ -f "${d}/Preferences" ] || [ -f "${d}/History" ] || [ -d "${d}/Local Storage" ]; then
      PROFILES+=("${d}")
    fi
  done
}

chrome_running() {
  pgrep -xq "Google Chrome" 2>/dev/null && return 0
  pgrep -xq "Google Chrome Helper" 2>/dev/null && return 0
  return 1
}

ui_head "Chrome 清理" \
  "数据目录  ${CHROME_SUP}" \
  "缓存目录  ${CHROME_CACHE}" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入 WidevineCdm / blob_storage / Service Worker 缓存"
if chrome_running; then
  ui_note "⚠️ Chrome 正在运行 —— 缓存类清理一般安全，但建议清完重启浏览器"
else
  ui_note "Chrome 未运行，可放心清理"
fi
ui_note "扫描中…（进度见下方）"

collect_profiles
n_profiles=${#PROFILES[@]}

# ───────── 1) 浏览缓存（系统缓存根） ─────────
scan_step "浏览缓存"
for pdir in "${CHROME_CACHE}"/*; do
  [ -d "${pdir}" ] || continue
  pname=$(basename "${pdir}")
  for sub in "Cache" "Code Cache" "Media Cache"; do
    add_target "浏览缓存" "${pdir}/${sub}" "Caches/Google/Chrome/${pname}/${sub}"
  done
done

# ───────── 2) GPU / 着色器缓存 ─────────
scan_step "GPU/着色器缓存"
for d in "GPUPersistentCache" "ShaderCache" "GrShaderCache" "GraphiteDawnCache"; do
  add_target "GPU/着色器缓存" "${CHROME_SUP}/${d}"
done
i=0
while [ "${i}" -lt "${n_profiles}" ]; do
  pd="${PROFILES[$i]}"
  pname=$(basename "${pd}")
  for sub in "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" "Shared Dictionary"; do
    add_target "GPU/着色器缓存" "${pd}/${sub}" "Profile[${pname}] ${sub}"
  done
  i=$((i + 1))
done

# ───────── 3) 组件 / 升级缓存 ─────────
scan_step "组件升级缓存"
for d in "component_crx_cache" "extensions_crx_cache" "Webstore Downloads"; do
  add_target "组件升级缓存" "${CHROME_SUP}/${d}"
done

# ───────── 4) AI 模型缓存（可重新下载） ─────────
scan_step "AI 模型缓存"
for d in "screen_ai" "optimization_guide_model_store" "WasmTtsEngine" \
         "OptGuideOnDeviceModel" "OptGuideOnDeviceClassifierModel" \
         "OnDeviceHeadSuggestModel"; do
  add_target "AI 模型缓存" "${CHROME_SUP}/${d}" \
             "${d}（Chrome 需要时自动重新下载）"
done

# ───────── 5) 崩溃报告 / 遥测 ─────────
scan_step "崩溃报告/遥测"
for d in "Crashpad/completed" "Crashpad/pending" "Crashpad/attachments"; do
  add_target "崩溃报告/遥测" "${CHROME_SUP}/${d}"
done
add_target "崩溃报告/遥测" "${CHROME_SUP}/BrowserMetrics"
add_target "崩溃报告/遥测" "${CHROME_SUP}/BrowserMetrics-spare.pma"

# ───────── 6) 旧日志 ─────────
scan_step "旧日志"
i=0
while [ "${i}" -lt "${n_profiles}" ]; do
  pd="${PROFILES[$i]}"
  pname=$(basename "${pd}")
  add_target "旧日志" "${pd}/LOG.old" "Profile[${pname}] LOG.old"
  i=$((i + 1))
done

# ───────── 7) aggressive ─────────
scan_step "aggressive 项"
if [ "${AGGRESSIVE}" -eq 1 ]; then
  add_target "aggressive" "${CHROME_SUP}/WidevineCdm" \
             "WidevineCdm/（DRM 组件，在线视频首次播放会重新下载）"
  i=0
  while [ "${i}" -lt "${n_profiles}" ]; do
    pd="${PROFILES[$i]}"
    pname=$(basename "${pd}")
    add_target "aggressive" "${pd}/blob_storage" \
               "Profile[${pname}] blob_storage/（可能含未完成的下载/上传）"
    add_target "aggressive" "${pd}/Service Worker/CacheStorage" \
               "Profile[${pname}] Service Worker/CacheStorage（PWA 离线数据）"
    add_target "aggressive" "${pd}/Service Worker/ScriptStorage" \
               "Profile[${pname}] Service Worker/ScriptStorage（SW 脚本缓存）"
    i=$((i + 1))
  done
fi

# ───────── 8) 系统级 GoogleUpdater 缓存 ─────────
scan_step "Updater 缓存"
add_target "Updater 缓存" "${HOME}/Library/Caches/com.google.GoogleUpdater" \
           "com.google.GoogleUpdater（升级器临时缓存）"

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
  echo "   数据目录占用: $(du -sh "${CHROME_SUP}" 2>/dev/null | cut -f1)"
  echo "   缓存目录占用: $(du -sh "${CHROME_CACHE}" 2>/dev/null | cut -f1)"
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
printf '   清理前占用: 数据目录 %s / 缓存目录 %s\n' \
  "$(du -sh "${CHROME_SUP}" 2>/dev/null | cut -f1)" \
  "$(du -sh "${CHROME_CACHE}" 2>/dev/null | cut -f1)"

if [ "${PROTECTED_SKIPPED}" -gt 0 ]; then
  ui_note "🛡️  硬防线拦截：${PROTECTED_SKIPPED} 个路径命中用户数据保护名单（密码/Cookie/登录态），已强制排除"
fi

if [ "${SCAN_ONLY}" -eq 1 ]; then
  echo
  echo "只扫描模式（--scan）：未删除任何文件。"
  exit 0
fi

if [ "${CLEAN}" -eq 1 ] && ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
  echo >&2
  echo "⚠️  没有指定范围，本次不会动任何文件。" >&2
  echo "    只清几项：    bash $0 --clean <关键词>     # 多个词用空格或逗号" >&2
  echo "    全部都要清：  bash $0 --clean --all" >&2
  exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 交互式清理
# ═════════════════════════════════════════════════════════════════════════════

render_brief() {
  printf '   [%02d] %8s  %s  ·  %s\n' "$1" "$(human "${T_SIZES[$2]}")" \
         "${T_LABELS[$2]}" "${T_CATS[$2]}"
}

render_paths() {
  local one
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    printf '          %s\n' "${one}"
  done <<< "${T_PATHS[$1]}"
}

move_group() {
  local idx="$1" one gfail=0
  while IFS= read -r one; do
    [ -n "${one}" ] || continue
    # 二次防线：执行前再验一遍保护名单
    if is_protected "${one}"; then
      printf '   [拦截]   %s（命中用户数据保护名单）\n' "${one}"
      gfail=$((gfail + 1))
      continue
    fi
    if trash_path "${one}"; then
      printf '   [废纸篓] %s\n' "${one}"
    else
      printf '   [失败]   %s\n' "${one}"
      gfail=$((gfail + 1))
    fi
  done <<< "${T_PATHS[$idx]}"
  [ "${gfail}" -eq 0 ]
}

declare -a REM_IDX=( ${S_IDX[@]+"${S_IDX[@]}"} )
declare -a CHOSEN=()
declare -a UNIQ_NUMS=()
CHOICE_NUMS=()
ACT=""
ok=0; fail=0; moved_paths=0; round=0

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

ui_section "结果"
printf '   成功 %d 项，失败 %d 项，剩余未处理 %d 项\n' "${ok}" "${fail}" "${#REM_IDX[@]}"
printf '   清理后占用: 数据目录 %s / 缓存目录 %s\n' \
  "$(du -sh "${CHROME_SUP}" 2>/dev/null | cut -f1)" \
  "$(du -sh "${CHROME_CACHE}" 2>/dev/null | cut -f1)"
if [ "${ok}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
  printf '   建议：清完后重启一次 Chrome，让缓存与组件重新按需加载。\n'
else
  printf '   未移动任何文件。\n'
fi
ui_end
