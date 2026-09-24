#!/usr/bin/env bash
#
# wps-sweep.sh — 清理 WPS Office 的内核缓存 / 插件升级包 / 日志 / 崩溃备份
#
# ─────────────────────────────────────────────────────────────────────────────
# 与其他 *-sweep.sh 同一套交互：直接跑，扫完在终端里挑要清哪些。
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
#   8) 容器外缓存     ~/Library/Caches/com.kingsoft.wpsoffice.mac（系统级缓存）、
#                     ~/Library/Saved Application State/...savedState（窗口状态残留）
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

WPS_CONTAINER="${WPS_CONTAINER:-${HOME}/Library/Containers/com.kingsoft.wpsoffice.mac}"
WPS_DATA="${WPS_CONTAINER}/Data"

if [ ! -d "${WPS_CONTAINER}" ]; then
  echo "找不到 WPS 容器目录（装过 WPS Office 吗？）：" >&2
  echo "  ${WPS_CONTAINER}" >&2
  exit 1
fi

SWEEP_HOME="${WPS_DATA}"
SWEEP_SIZE_DIRS=("容器总占用:${WPS_CONTAINER}")

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
  local comp line
  comp=$(basename "$1")
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
}

wps_running() {
  pgrep -f "wpsoffice.app/Contents/MacOS/wpsoffice" >/dev/null 2>&1 && return 0
  pgrep -xq "wpsoffice" 2>/dev/null && return 0
  pgrep -f "wpscloudsvr" >/dev/null 2>&1 && return 0
  return 1
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
  _add "${cat}" "${rel}${note}" "$(kb_of "${path}")" 0 "${path}"
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

SCAN_TOTAL=11

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
          _add "CEF 内核缓存" \
            "${prof#"${WPS_DATA}"/}/${sub}" \
            "$(kb_of "${prof}/${sub}")" 0 "${prof}/${sub}"
      done
    done
    # promebrowser/cache（独立缓存目录）
    [ -d "${plat}/promebrowser/cache" ] && \
      _add "CEF 内核缓存" \
        "${plat#"${WPS_DATA}"/.kingsoft/wps/addons/data}/../promebrowser/cache" \
        "$(kb_of "${plat}/promebrowser/cache")" 0 "${plat}/promebrowser/cache"
    # globalcache：全局缓存（不含 Cookies；Visited Links 是浏览记录痕迹）
    gc="${plat}/cef/globalcache"
    [ -d "${gc}" ] || continue
    for sub in "Cache" "Code Cache" "GPUCache" "Visited Links" "blob_storage"; do
      [ -d "${gc}/${sub}" ] && \
        _add "CEF 内核缓存" "…/cef/globalcache/${sub}" \
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
    _add "网页统计痕迹" "Library/WebKit/WebsiteData/${sub}" \
      "$(kb_of "${WK}/${sub}")" 0 "${WK}/${sub}"
done

# ───────── 7) 杂项小文件（蚊子腿） ─────────
scan_step "杂项小文件"
# kpdfbackendclient：PDF 打开时的页面缩略图/转存图片，按需重建
add_rel "杂项小文件" ".kingsoft/office6/data/kpdfbackendclient" "（PDF 缩略图缓存）"
# wps-cong/ksohtml：网页/文档另存 HTML 时的图片转存残留
[ -d "${WPS_DATA}/tmp/wps-cong" ] && \
  _add "杂项小文件" "tmp/wps-cong/（HTML 转存图片残留）" \
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

# ───────── 8) 容器外缓存 ─────────
scan_step "容器外缓存"
add_target "容器外缓存" "${HOME}/Library/Caches/com.kingsoft.wpsoffice.mac" \
           "~/Library/Caches/com.kingsoft.wpsoffice.mac（系统级缓存）"
add_target "容器外缓存" \
           "${HOME}/Library/Saved Application State/com.kingsoft.wpsoffice.mac.savedState" \
           "~/Library/Saved Application State/...savedState（窗口状态残留）"

# ───────── 9) aggressive ─────────
scan_step "aggressive 项"
if [ "${AGGRESSIVE}" -eq 1 ]; then
  add_rel "aggressive" ".kingsoft/WpsUpdate" \
          "（升级组件缓存，下次升级重新下载）"
  # WebKit 本地存储：可能丢内嵌页登录态，只放进 aggressive
  for sub in "LocalStorage" "IndexedDB" "Default"; do
    [ -d "${WK}/${sub}" ] && \
      _add "aggressive" "Library/WebKit/WebsiteData/${sub}（可能含内嵌页登录态）" \
        "$(kb_of "${WK}/${sub}")" 0 "${WK}/${sub}"
  done
  # tmp 杂项：截图残留等（kccsdkbak / photo_cache / picnewprivilege 已在前面单独列）
  if [ -d "${WPS_DATA}/tmp" ]; then
    for f in "${WPS_DATA}"/tmp/img_*.png "${WPS_DATA}/tmp/cloudbusinessicons" \
             "${WPS_DATA}/tmp/WebKit/MediaCache"; do
      [ -e "${f}" ] || continue
      _add "aggressive" "tmp/$(basename "${f}")" \
        "$(kb_of "${f}")" 0 "${f}"
    done
  fi
fi

# ───────── 10) 占用统计 ─────────
# 容器总占用在报告区由 SWEEP_SIZE_DIRS 统一统计，这里只推进进度条
scan_step "占用统计"

finish_progress

sweep_finish
