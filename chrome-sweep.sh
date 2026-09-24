#!/usr/bin/env bash
#
# chrome-sweep.sh — 清理 Chrome 的缓存 / 组件升级包 / AI 模型缓存 / 崩溃报告
#
# ─────────────────────────────────────────────────────────────────────────────
# 与其他 *-sweep.sh 同一套交互：直接跑，扫完在终端里挑要清哪些。
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
#                    WasmTtsEngine / OptGuideOnDevice* / OnDeviceHeadSuggestModel /
#                    segmentation_platform（顶层与 profile 内的可重下模型）
#   5) 崩溃报告/遥测 Crashpad/{completed,pending,attachments} +
#                    BrowserMetrics / BrowserMetrics-spare.pma /
#                    CrashpadMetrics-active.pma
#   6) 旧日志        profile 里的 LOG.old
#   7) 实验种子/组件  VariationsSeed{,Safe}V2（实验分组种子，重启重取）、
#                    ZxcvbnData（密码强度词典）、CertificateRevocation、
#                    SSLErrorAssistant、Subresource Filter、MEIPreload、
#                    OriginTrials、first_party_sets.db（均可按需重新下载）
#   8) 隐私痕迹      profile 里的 DIPS / DIPS-wal（滚动指纹追踪）、
#                    Reporting and NEL（网络错误上报）
#   9) 杂项          Chrome 数据目录与 Crashpad 下的 .DS_Store
#  10) profile 遥测/可重建数据
#                    AutofillAiModelCache / Segmentation Platform /
#                    optimization_guide_hint_cache_store / Search Logos /
#                    VideoDecodeStats / WebrtcVideoStats /
#                    Feature Engagement Tracker / Translate Ranker Model /
#                    chrome_cart_db / commerce_subscription_db /
#                    discount_infos_db / discounts_db / parcel_tracking_db
#                    （购物/统计/模型类数据库，Chrome 按需重建）
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

CHROME_SUP="${CHROME_SUP_DIR:-${HOME}/Library/Application Support/Google/Chrome}"
CHROME_CACHE="${CHROME_CACHE_DIR:-${HOME}/Library/Caches/Google/Chrome}"
AGE_MIN="${AGE_MIN:-0}"

if [ ! -d "${CHROME_SUP}" ] && [ ! -d "${CHROME_CACHE}" ]; then
  echo "找不到 Chrome 数据目录（装过 Chrome 吗？）：" >&2
  echo "  ${CHROME_SUP}" >&2
  echo "  ${CHROME_CACHE}" >&2
  exit 1
fi

SWEEP_HOME="${CHROME_SUP}"
SWEEP_SIZE_DIRS=("数据目录:${CHROME_SUP}" "缓存目录:${CHROME_CACHE}")

# ───────── ★ 硬防线：用户数据保护名单 ─────────
# 任何待加入清单的路径，其 basename 命中这里 → 直接拒绝。
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
  local comp line
  comp=$(basename "$1")
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
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

collect_profiles
n_profiles=${#PROFILES[@]}

SCAN_TOTAL=12

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
         "OnDeviceHeadSuggestModel" "segmentation_platform"; do
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
add_target "崩溃报告/遥测" "${CHROME_SUP}/CrashpadMetrics-active.pma" \
           "CrashpadMetrics-active.pma（崩溃指标活动快照，重启重建）"

# ───────── 5b) 实验种子 / 可重下组件（蚊子腿） ─────────
scan_step "实验种子/组件"
for d in "VariationsSeed" "VariationsSeedV2" "VariationsSafeSeedV2" "Variations" \
         "ZxcvbnData" "CertificateRevocation" "SSLErrorAssistant" \
         "Subresource Filter" "MEIPreload" "OriginTrials" \
         "first_party_sets.db" "first_party_sets.db-journal"; do
  add_target "实验种子/组件" "${CHROME_SUP}/${d}" \
             "${d}（实验数据/安全组件，Chrome 按需重新下载）"
done

# ───────── 5c) profile 隐私痕迹（蚊子腿） ─────────
scan_step "隐私痕迹"
i=0
while [ "${i}" -lt "${n_profiles}" ]; do
  pd="${PROFILES[$i]}"
  pname=$(basename "${pd}")
  for sub in "DIPS" "DIPS-wal" "Reporting and NEL"; do
    add_target "隐私痕迹" "${pd}/${sub}" "Profile[${pname}] ${sub}（滚动指纹/网络上报痕迹）"
  done
  i=$((i + 1))
done

# ───────── 5d) profile 遥测 / 购物 / 可重建数据（蚊子腿） ─────────
# 全部是 Chrome 自建的统计/模型/购物功能数据，没有用户输入内容，按需重建。
scan_step "profile 遥测数据"
PROFILE_TELEMETRY=(
  "AutofillAiModelCache" "Segmentation Platform" "optimization_guide_hint_cache_store"
  "Search Logos" "VideoDecodeStats" "WebrtcVideoStats"
  "Feature Engagement Tracker" "Translate Ranker Model"
  "chrome_cart_db" "commerce_subscription_db" "discount_infos_db"
  "discounts_db" "parcel_tracking_db"
)
i=0
while [ "${i}" -lt "${n_profiles}" ]; do
  pd="${PROFILES[$i]}"
  pname=$(basename "${pd}")
  for sub in "${PROFILE_TELEMETRY[@]}"; do
    add_target "profile 遥测/可重建" "${pd}/${sub}" "Profile[${pname}] ${sub}（按需重建）"
  done
  i=$((i + 1))
done

# ───────── 5e) 杂项：.DS_Store（蚊子腿） ─────────
scan_step "DS_Store 杂项"
ds_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  ds_files+=("${f}")
done < <(find "${CHROME_SUP}" "${CHROME_CACHE}" -maxdepth 3 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  add_group "DS_Store 杂项" ".DS_Store（${#ds_files[@]} 个）" \
            "$(kb_of_multi "${ds_files[@]}")" "${ds_files[@]}"
fi

# ───────── 6) 旧日志 ─────────
scan_step "旧日志"
i=0
while [ "${i}" -lt "${n_profiles}" ]; do
  pd="${PROFILES[$i]}"
  pname=$(basename "${pd}")
  add_target "旧日志" "${pd}/LOG.old" "Profile[${pname}] LOG.old"
  add_target "旧日志" "${pd}/Session Storage/LOG.old" "Profile[${pname}] Session Storage/LOG.old"
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

sweep_finish
