#!/usr/bin/env bash
#
# wps-sweep.sh — 清理 WPS Office 的内核缓存 / 插件升级包 / 日志 / 崩溃备份
#
# ─────────────────────────────────────────────────────────────────────────────
# 与 workbuddy-sweep.sh 同一套交互：直接跑，扫完在终端里挑要清哪些。
# 默认【只扫描 + 等你确认】，没有你的明确输入，一个文件都不会动。
# 清理走「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可拖回。
#
# WPS 的用户数据几乎全部装在 App Sandbox 容器里：
#   ~/Library/Containers/com.kingsoft.wpsoffice.mac/Data/
# 里面藏得最深的大头是 WPS 内嵌 Chromium（CEF）的网页缓存。
#
# 扫描目标（按类别）：
#   1) CEF 内核缓存   WPS 内嵌 Chromium 浏览内核的 HTTP 缓存（★ 最大头）：
#                     addons/data/*/cef/cache/{qing,wpsoffice,yunbox}、
#                     cef/wpsplus、cef/kappconnectivity、promeapps/cookie、
#                     promebrowser/{cache,cookie} 下的 Cache / Code Cache
#   2) 插件升级缓存   addons/pool/ —— 已下载的各版本插件安装包（WPS 需要时
#                     自动重新下载），等价 Chrome 的 component_crx_cache
#   3) 运行日志       office6/log/（wpscloudsvr 云服务日志通常最大）+
#                     .local/share/Kingsoft/offlinelog/
#   4) 崩溃备份       kccsdkbak/（两处：office6 与 tmp）+ CrashReporter
#   5) 在线素材缓存   onlinegradient 运营图、docerFonts/cache 稻壳字体缓存、
#                     mediacache、wpsassist/onlinetemplates 在线模板、
#                     photo_cache、picnewprivilege
#   6) 网页统计       WebKit/WebsiteData 的 ResourceLoadStatistics +
#                     SearchHistory（WPS 内嵌网页的浏览痕迹）
#   7) 杂项小文件     data/kpdfbackendclient（PDF 缩略图缓存）、
#                     tmp/wps-cong/ksohtml（HTML 转存图片残留）、
#                     容器内散落的 .DS_Store
#
#   --aggressive 追加（有代价，确认再用）：
#     · WpsUpdate/            升级组件缓存，删后下次升级重新下载
#     · WebKit LocalStorage / IndexedDB
#                             WPS 内嵌网页的本地存储，可能丢失内嵌页登录态
#                             （需在 WPS 内嵌页面重新登录，不影响客户端账号）
#     · tmp/ 杂项             img_*.png 截图残留、cloudbusinessicons 等
#
# 【绝对不碰】—— 账号、文档备份、云同步、用户数据（脚本内有硬防线）：
#   Cookies / Cookie 数据库 / tokenTable.ini（登录令牌）/ kaccountsdk/
#   account/ / data/backup（文档自动备份！）/ OfficeSpace / WPS Cloud Files
#   （云同步状态）/ avatars / data/fonts（已下载字体）/ Preferences/
#   .config / recentfile_server / lock 文件
#
# 用法：
#   ./wps-sweep.sh                       # 扫描 → 列清单 → 交互选择
#   ./wps-sweep.sh cef                   # 只列名字/路径含 cef 的项
#   ./wps-sweep.sh cef log --and wpscloudsvr   # (cef 或 log) 且 wpscloudsvr
#   ./wps-sweep.sh --aggressive          # 清单额外含 WpsUpdate / WebKit 存储等
#   ./wps-sweep.sh --scan                # 只看报告，不进交互
#   ./wps-sweep.sh --clean <关键词> --yes # 非交互清理（必须带关键词筛选）
#   ⚠️ --clean --all --yes「一句话全清空」被刻意堵死；裸 --clean 拒绝执行。
#
# 交互提示：yes/all 全清 · 编号如 1 3 5 / 1-4 / 1,3 · pick 逐项确认 · q 结束
#
# 可调环境变量：
#   WPS_CONTAINER  默认 ~/Library/Containers/com.kingsoft.wpsoffice.mac
#
# ⚠️ 建议先退出 WPS 再清理（脚本会检测并提示）；运行中清理缓存类文件
#    通常安全，但 CEF 缓存可能个别窗口显示异常，重启 WPS 即恢复。
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
    echo "--yes 必须带筛选条件（如 --clean cef --yes）—— --all 不算筛选。" >&2
    echo "    --clean --all --yes 这种「一句话全清空」被刻意堵死了。" >&2
    exit 2
  fi
fi

WPS_CONTAINER="${WPS_CONTAINER:-${HOME}/Library/Containers/com.kingsoft.wpsoffice.mac}"
WPS_DATA="${WPS_CONTAINER}/Data"

if [ ! -d "${WPS_CONTAINER}" ]; then
  echo "找不到 WPS 容器目录（装过 WPS Office 吗？）：" >&2
  echo "  ${WPS_CONTAINER}" >&2
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

SCAN_TOTAL=10

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
# 任何待加入清单的路径，其 basename 命中这里 → 直接拒绝。
# 这是独立于扫描逻辑的第二道闸：就算将来扫描规则写错，也碰不到这些。
# （注意「promeapps/cookie」这类目录名虽然带 cookie，但它只是个命名糟糕的
#   浏览器 profile 目录，里面真正的凭据文件叫 Cookies，已被单独保护；
#   我们只清它下面的 Cache / Code Cache 子目录，basename 不会命中。）
PROTECT_PATTERNS='
Cookies
Cookies-journal
Cookies-wal
tokenTable.ini
backup
OfficeSpace
WPS Cloud Files
avatars
kaccountsdk
account
hiddenfonts
fonts
extend_font
Preferences
.config
recentfile_server
SystemData
SingletonLock
SingletonCookie
SingletonSocket
LOCK
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

declare -a T_PATHS=()
declare -a T_SIZES=()
declare -a T_LABELS=()
declare -a T_CATS=()
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

# 相对 Data 的路径做 label，短且可读
# ⚠️ local 的多个赋值参数是先整体展开再赋值，后续参数引用前面的变量会踩 set -u，
#    必须拆成多条 local 语句
add_rel() {  # add_rel <cat> <相对 Data 的路径> [后缀说明]
  local cat="$1"
  local rel="$2"
  local note="${3:-}"
  local path="${WPS_DATA}/${rel}"
  [ -e "${path}" ] || return 0
  _add_checked "${cat}" "${rel}${note}" "$(kb_of "${path}")" 0 "${path}"
}

# 判断 CEF 平台子目录（addons/data/<platform>、addons/pool/<platform>）
# 遍历所有平台目录，兼容 mac-universal 之外的未来平台

add_group() {  # add_group <cat> <label> <kb> <path...> —— 聚合多条路径为一项
  local cat="$1" label="$2" kb="$3"; shift 3
  _add_checked "${cat}" "${label}" "${kb}" 0 "$@"
}
wps_running() {
  pgrep -f "wpsoffice.app/Contents/MacOS/wpsoffice" >/dev/null 2>&1 && return 0
  pgrep -xq "wpsoffice" 2>/dev/null && return 0
  pgrep -f "wpscloudsvr" >/dev/null 2>&1 && return 0
  return 1
}

ui_head "WPS Office 清理" \
  "容器目录  ${WPS_CONTAINER}" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入 WpsUpdate / WebKit 本地存储 / tmp 杂项"
if wps_running; then
  ui_note "⚠️ WPS 正在运行 —— 缓存类清理一般安全，但建议清完重启 WPS"
else
  ui_note "WPS 未运行，可放心清理"
fi
ui_note "扫描中…（进度见下方）"

# CEF 数据根：addons/data/<platform>/cef 与 promeapps 等
ADDONS_DATA="${WPS_DATA}/.kingsoft/wps/addons/data"
ADDONS_POOL="${WPS_DATA}/.kingsoft/wps/addons/pool"

# ───────── 1) CEF 内核缓存（★ 最大头） ─────────
scan_step "CEF 内核缓存"
# 1a. cef/cache/<biz>/ —— 内嵌 Chromium 的 HTTP 缓存（qing 云协作 200M 级）
if [ -d "${ADDONS_DATA}" ]; then
  for plat in "${ADDONS_DATA}"/*; do
    [ -d "${plat}" ] || continue
    pname=$(basename "${plat}")
    # 整个 cef/cache 一把清（里面只有 HTTP 缓存，无凭据）
    add_rel "CEF 内核缓存" ".kingsoft/wps/addons/data/${pname}/cef/cache" \
            "（内嵌 Chromium HTTP 缓存）"
    # 各内嵌页 profile 的 Cache / Code Cache（只取缓存子目录，避开 Cookies）
    for prof in "${plat}/cef/wpsplus" "${plat}/cef/kappconnectivity" \
                "${plat}/cef/kwebaireference" "${plat}/cef/kwebdoccloudsync" \
                "${plat}/cef/ktaskpanelcopilot" "${plat}/cef/klingxidockpanel" \
                "${plat}/promeapps/cookie" "${plat}/promebrowser/cookie"; do
      [ -d "${prof}" ] || continue
      for sub in "Cache" "Code Cache" "GPUCache" "ShaderCache"; do
        [ -d "${prof}/${sub}" ] && \
          _add_checked "CEF 内核缓存" \
            "${prof#"${WPS_DATA}"/}/${sub}" \
            "$(kb_of "${prof}/${sub}")" 0 "${prof}/${sub}"
      done
    done
    # promebrowser/cache（独立缓存目录）
    [ -d "${plat}/promebrowser/cache" ] && \
      _add_checked "CEF 内核缓存" \
        "${plat#"${WPS_DATA}"/.kingsoft/wps/addons/data}/../promebrowser/cache" \
        "$(kb_of "${plat}/promebrowser/cache")" 0 "${plat}/promebrowser/cache"
    # globalcache：全局缓存（不含 Cookies；Visited Links 是浏览记录痕迹）
    gc="${plat}/cef/globalcache"
    [ -d "${gc}" ] || continue
    for sub in "Cache" "Code Cache" "GPUCache" "Visited Links" "blob_storage"; do
      [ -d "${gc}/${sub}" ] && \
        _add_checked "CEF 内核缓存" "…/cef/globalcache/${sub}" \
          "$(kb_of "${gc}/${sub}")" 0 "${gc}/${sub}"
    done
  done
fi

# ───────── 2) 插件升级缓存 ─────────
scan_step "插件升级缓存"
if [ -d "${ADDONS_POOL}" ]; then
  add_rel "插件升级缓存" ".kingsoft/wps/addons/pool" \
          "（已下载的插件安装包，WPS 按需重新下载）"
fi

# ───────── 3) 运行日志 ─────────
scan_step "运行日志"
add_rel "运行日志" "Library/Application Support/Kingsoft/office6/log" \
        "（wpscloudsvr 云服务日志通常最大）"
add_rel "运行日志" ".local/share/Kingsoft/offlinelog" "（离线埋点日志）"

# ───────── 4) 崩溃备份 ─────────
scan_step "崩溃备份"
add_rel "崩溃备份" ".kingsoft/office6/kccsdkbak" "（崩溃 SDK 备份）"
add_rel "崩溃备份" "tmp/kccsdkbak" "（崩溃 SDK 备份 tmp 副本）"
add_rel "崩溃备份" "Library/Application Support/CrashReporter"

# ───────── 5) 在线素材缓存 ─────────
scan_step "在线素材缓存"
add_rel "在线素材缓存" ".kingsoft/office6/data/onlinegradient" "（运营推广图）"
add_rel "在线素材缓存" ".kingsoft/office6/docerFonts/cache" "（稻壳字体缓存）"
add_rel "在线素材缓存" ".kingsoft/office6/mediacache"
add_rel "在线素材缓存" "Library/Application Support/Kingsoft/office6/wpsassist/onlinetemplates" \
        "（在线模板缓存，按需重新下载）"
add_rel "在线素材缓存" "tmp/photo_cache"
add_rel "在线素材缓存" "tmp/picnewprivilege"

# ───────── 6) 网页统计痕迹 ─────────
scan_step "网页统计痕迹"
WK="${WPS_DATA}/Library/WebKit/WebsiteData"
for sub in "ResourceLoadStatistics" "SearchHistory" "MediaKeys" "MediaKeysHashSalts" \
           "DeviceIdHashSalts" "ResourceMonitorThrottler"; do
  [ -d "${WK}/${sub}" ] && \
    _add_checked "网页统计痕迹" "Library/WebKit/WebsiteData/${sub}" \
      "$(kb_of "${WK}/${sub}")" 0 "${WK}/${sub}"
done

# ───────── 7) 杂项小文件（蚊子腿） ─────────
scan_step "杂项小文件"
# kpdfbackendclient：PDF 打开时的页面缩略图/转存图片，按需重建
add_rel "杂项小文件" ".kingsoft/office6/data/kpdfbackendclient" "（PDF 缩略图缓存）"
# wps-cong/ksohtml：网页/文档另存 HTML 时的图片转存残留
[ -d "${WPS_DATA}/tmp/wps-cong" ] && \
  _add_checked "杂项小文件" "tmp/wps-cong/（HTML 转存图片残留）" \
    "$(kb_of "${WPS_DATA}/tmp/wps-cong")" 0 "${WPS_DATA}/tmp/wps-cong"
# 容器内散落 .DS_Store（限 4 层，避开备份与云目录）
ds_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  ds_files+=("${f}")
done < <(find "${WPS_DATA}" -maxdepth 4 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  add_group "杂项小文件" ".DS_Store（${#ds_files[@]} 个）" \
            "$(kb_of_multi "${ds_files[@]}")" "${ds_files[@]}"
fi

# ───────── 8) aggressive ─────────
scan_step "aggressive 项"
if [ "${AGGRESSIVE}" -eq 1 ]; then
  add_rel "aggressive" ".kingsoft/WpsUpdate" \
          "（升级组件缓存，下次升级重新下载）"
  # WebKit 本地存储：可能丢内嵌页登录态，只放进 aggressive
  for sub in "LocalStorage" "IndexedDB" "Default"; do
    [ -d "${WK}/${sub}" ] && \
      _add_checked "aggressive" "Library/WebKit/WebsiteData/${sub}（可能含内嵌页登录态）" \
        "$(kb_of "${WK}/${sub}")" 0 "${WK}/${sub}"
  done
  # tmp 杂项：截图残留等（kccsdkbak / photo_cache / picnewprivilege 已在前面单独列）
  if [ -d "${WPS_DATA}/tmp" ]; then
    for f in "${WPS_DATA}"/tmp/img_*.png "${WPS_DATA}/tmp/cloudbusinessicons" \
             "${WPS_DATA}/tmp/WebKit/MediaCache"; do
      [ -e "${f}" ] || continue
      _add_checked "aggressive" "tmp/$(basename "${f}")" \
        "$(kb_of "${f}")" 0 "${f}"
    done
  fi
fi

# ───────── 9) 占用统计 ─────────
scan_step "占用统计"
container_total=$(du -sh "${WPS_CONTAINER}" 2>/dev/null | cut -f1)

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
  echo "   容器总占用: ${container_total}"
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
printf '   清理前容器占用: %s\n' "${container_total}"

if [ "${PROTECTED_SKIPPED}" -gt 0 ]; then
  ui_note "🛡️  硬防线拦截：${PROTECTED_SKIPPED} 个路径命中用户数据保护名单（账号/备份/云同步），已强制排除"
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
printf '   清理后容器占用: %s\n' "$(du -sh "${WPS_CONTAINER}" 2>/dev/null | cut -f1)"
if [ "${ok}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。\n' "${HOME}"
  printf '   建议：清完后重启一次 WPS，让缓存与插件按需重新加载。\n'
else
  printf '   未移动任何文件。\n'
fi
ui_end
