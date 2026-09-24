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
#                              （已下载的扩展安装包）/ CachedProfilesData /
#                              CachedConfigurations
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
#     · Backups/ 崩溃恢复     闲置 ≥ VSCODE_BACKUP_COOLDOWN_DAYS 天的备份
#                             ⚠️ 未保存文件的崩溃恢复数据，删后无法恢复
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
#   VSCODE_BACKUP_COOLDOWN_DAYS Backups/ 崩溃恢复冷却期，默认 7 天
#
# ⚠️ 建议先退出 VS Code 再清：清理时 VS Code 持有部分 LevelDB / SQLite 文件句柄，
#    运行中清理通常也安全（进程会重建），但 Session Storage 与状态库类目标
#    在退出后清理更干净。脚本检测到运行中会给出提示。
# ⚠️ 没有「单次上限」：选中之后清单上的项一次处理完，不会清到一半停住。
# ⚠️ 本脚本不产生任何临时文件。
# ─────────────────────────────────────────────────────────────────────────────
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

VSCODE_HOME="${VSCODE_HOME:-${HOME}/Library/Application Support/Code}"
VSCODE_LOG_COOLDOWN_MIN="${VSCODE_LOG_COOLDOWN_MIN:-60}"
VSCODE_ORPHAN_COOLDOWN_DAYS="${VSCODE_ORPHAN_COOLDOWN_DAYS:-7}"
VSCODE_BACKUP_COOLDOWN_DAYS="${VSCODE_BACKUP_COOLDOWN_DAYS:-7}"

# 环境变量可能是空的或被写成非数字（export VAR= / VAR=x）——回落到默认值
case "${VSCODE_LOG_COOLDOWN_MIN}" in ''|*[!0-9]*) VSCODE_LOG_COOLDOWN_MIN=60 ;; esac
case "${VSCODE_ORPHAN_COOLDOWN_DAYS}" in ''|*[!0-9]*) VSCODE_ORPHAN_COOLDOWN_DAYS=7 ;; esac
case "${VSCODE_BACKUP_COOLDOWN_DAYS}" in ''|*[!0-9]*) VSCODE_BACKUP_COOLDOWN_DAYS=7 ;; esac

[ -d "${VSCODE_HOME}" ] || {
  echo "目录不存在: ${VSCODE_HOME}" >&2
  echo "（没装 VS Code，或是 Insiders / VSCodium？可用 VSCODE_HOME=... 指定）" >&2
  exit 1
}

SWEEP_HOME="${VSCODE_HOME}"
SWEEP_SIZE_DIRS=("占用:${VSCODE_HOME}")

# ───────── 硬防线：用户数据保护名单 ─────────
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
  local comp line
  comp=$(basename "$1")
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    [ "${comp}" = "${line}" ] && return 0
  done <<< "${PROTECT_PATTERNS}"
  return 1
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

ui_head "VS Code 清理" \
  "VSCODE_HOME   ${VSCODE_HOME}" \
  "今天          ${today}" \
  "模式          $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入孤立工作区状态 / Copilot 语义索引 / SW 缓存 / Session Storage / Backups"
if app_running; then
  ui_note "⚠️  VS Code 正在运行：清 Session Storage 与状态库类目标建议先退出应用（缓存类可随时清）"
fi
ui_note "扫描中…（进度见下方）"

SCAN_TOTAL=11

# ───────── 1) 渲染与 GPU 缓存（根目录）─────────
scan_step "渲染与 GPU 缓存"
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary" "blob_storage"; do
  add_target "渲染与 GPU 缓存" "${VSCODE_HOME}/${d}"
done

# ───────── 2) 字节码与下载缓存 ─────────
scan_step "字节码与下载缓存"
for d in "CachedData" "CachedExtensionVSIXs" "CachedProfilesData" "CachedConfigurations"; do
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

  # 11e) Backups/ 崩溃恢复备份（未保存文件的恢复数据，闲置 ≥ 冷却期才收）
  backup_files=()
  if [ -d "${VSCODE_HOME}/Backups" ]; then
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      m=$(stat -f '%m' "${f}" 2>/dev/null || echo "${now}")
      case "${m}" in ''|*[!0-9]*) m="${now}" ;; esac
      [ "$(( now - m ))" -lt "$(( VSCODE_BACKUP_COOLDOWN_DAYS * 86400 ))" ] && continue
      backup_files+=("${f}")
    done < <(find "${VSCODE_HOME}/Backups" -maxdepth 1 -mindepth 1 2>/dev/null)
  fi
  if [ "${#backup_files[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
      "Backups/ 崩溃恢复备份（${#backup_files[@]} 个，闲置 ≥ ${VSCODE_BACKUP_COOLDOWN_DAYS} 天；删后无法恢复未保存内容）" \
      "$(kb_of_multi "${backup_files[@]}")" "${backup_files[@]}"
  fi
fi

finish_progress

sweep_extra_notes() {
  # 真数据保护提示（不删，仅告知规模，方便确认「大头不在清理范围」）
  # 口径：只统计**永不清理**的路径，避免与 aggressive 清单里的 Copilot 索引重复计算。
  local ext_kb live_paths=() p live_total=0 gs_kb
  ext_kb=0
  [ -d "${HOME}/.vscode/extensions" ] && ext_kb=$(kb_of "${HOME}/.vscode/extensions")
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
}

sweep_finish
