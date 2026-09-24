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
#     · AI 模型               Global/Data/AudioModel/ + Global/Xnn/<hash>/ 下全部模型目录
#                             （音频降噪 / 人像分割等，Xnn 每个一级子目录整体收）
#                             ⚠️ 首次使用会重新下载
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

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

SWEEP_HOME="${TM_HOME}"
SWEEP_SIZE_DIRS=("占用:${TM_HOME}")

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
  local comp line
  comp=$(basename "$1")
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

app_running() {
  pgrep -f 'TencentMeeting.app' >/dev/null 2>&1
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

SCAN_TOTAL=7
skipped_logs=0

# ───────── 1) 运行日志 ─────────
# Logs/<prefix>_YYYYMMDDHH.log(.zip)：每个进程每小时一份。
# 判据两条：名字严格匹配 <前缀>_10位时间戳、(可选).log(.zip)；且时间戳早于阈值。
# 非该命名的文件（*.mmap2/mmap3、*.rp、crash_count.log）一律不碰 —— 可能是活跃句柄。
scan_step "运行日志"
log_files=()
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

  # 7c) AI 模型：AudioModel/<hash>/ + Xnn/<hash>/ 下所有一级子目录
  #     （Xnn 里除了人像分割还可能有别的模型目录，整级收，首次使用会重新下载）
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
      "AI 模型 AudioModel / Xnn（${#model_paths[@]} 份，降噪与人像分割等，首次使用会重新下载）" \
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

sweep_extra_notes() {
  # 真数据保护提示（不删，仅告知规模，方便确认「大头不在清理范围」）
  local live_paths=() p live_total=0
  for d in "Global/Database" "Global/Preferences" "Users" "Global/XMagic" "Global/WWLink"; do
    [ -e "${TM_HOME}/${d}" ] && live_paths+=("${TM_HOME}/${d}")
  done
  [ -e "${HOME}/Library/HTTPStorages/com.tencent.meeting" ] && \
    live_paths+=("${HOME}/Library/HTTPStorages/com.tencent.meeting")
  [ -e "${HOME}/Documents/TencentMeeting" ] && \
    live_paths+=("${HOME}/Documents/TencentMeeting")
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
  if [ "${#pkg_pending[@]}" -gt 0 ] && [ "${AGGRESSIVE}" -ne 1 ]; then
    ui_note "另有 ${#pkg_pending[@]} 个未解压资源包 $(human "$(kb_of_multi ${pkg_pending[@]+"${pkg_pending[@]}"})")（删后需重新下载，用 --aggressive 纳入）"
  fi
}

sweep_finish
