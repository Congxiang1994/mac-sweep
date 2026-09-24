#!/usr/bin/env bash
#
# cherry-studio-sweep.sh — 清理 Cherry Studio 堆积的缓存 / 浏览缓存 / 追踪残留 / 历史日志 / 崩溃转储
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# 扫描目标：
#   1) Electron 渲染缓存（根目录）
#        Cache / Code Cache / GPUCache / DawnGraphiteCache / DawnWebGPUCache /
#        Shared Dictionary / blob_storage
#        —— GPU 着色器与 JS 字节码缓存，重开自动重建
#   2) 内置浏览器缓存（Partitions/webview + Partitions/default）
#        同上一组目录，外加各 Partition 的 Cache/Code Cache/GPUCache
#        —— 这是「浏览缓存」大头：webview 的 GPUCache 动辄上 MB
#   3) 隐私追踪残留（根目录 + 每个 Partition）
#        InterestGroups（广告兴趣组）/ Trust Tokens（匿名令牌）/
#        Trust Tokens-journal / DIPS（滚动指纹追踪）/ SharedStorage（分区存储）/
#        SharedStorage-wal
#        —— Chromium 广告归因 API 的落盘数据，清了无副作用
#   4) 历史日志 logs/
#        app.YYYY-MM-DD.log、app-error.YYYY-MM-DD.log（今天的保留）
#        以及 electron-log 的 .*-audit.json 审计碎片
#   5) Crashpad 崩溃转储
#        completed / new / pending / attachments 子目录整体清，
#        只保留 settings.dat（崩溃上报开关配置）
#   6) 杂项小文件
#        Session Storage/LOG.old + 散落 .DS_Store
#
#   --aggressive 追加：
#        Session Storage（会话级存储，正常退出后本就该清）
#        Service Worker/CacheStorage + ScriptCache（PWA 资源缓存，重新联网拉取）
#        .updaterId（升级器标识，下次检查更新自动重建）
#        version.log（版本记录，纯信息性）
#
# 【不会】删（Cherry Studio 的真数据，删了就是事故）：
#   - Data/ 全部：cherrystudio.sqlite 主数据库、Agents、Skills、
#     KnowledgeBase、Memory（mem0 记忆库）、Notes、Files
#   - IndexedDB/、Local Storage/、WebStorage/、Cookies（登录态与设置）
#   - Partitions/*/ 下的 Cookies / Local Storage / IndexedDB / WebStorage
#   - cache.json（窗口位置等持久状态）、Preferences、Local State
#   - Toolchain/（内置 mise 运行时）、Runtime/（本地模型目录）
#   - logs/ 里今天的日志
#
# 用法：
#   ./cherry-studio-sweep.sh                     # 扫描 → 列清单 → 交互选择
#   ./cherry-studio-sweep.sh partition           # 只把名字/路径含 partition 的项列进清单
#   ./cherry-studio-sweep.sh logs crash          # 多个关键词 = 并集
#   ./cherry-studio-sweep.sh --only logs,traces  # 逗号连写，等价于空格分隔
#   ./cherry-studio-sweep.sh --aggressive        # 清单额外含 Session Storage / SW 缓存等
#   ./cherry-studio-sweep.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐项确认（y=移入 n=跳过 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./cherry-studio-sweep.sh --clean logs --yes   # 跳过交互，直接清匹配项
#   ./cherry-studio-sweep.sh --clean --all        # 进交互但清单是全部，仍需手输 yes
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
#   CS_HOME           Cherry Studio 数据目录，
#                     默认 ~/Library/Application Support/CherryStudio
#
# ⚠️ 没有「单次上限」：选中之后清单上的项一次处理完，不会清到一半停住。
# ⚠️ 本脚本不产生任何临时文件。
# ─────────────────────────────────────────────────────────────────────────────
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

CS_HOME="${CS_HOME:-${HOME}/Library/Application Support/CherryStudio}"

[ -d "${CS_HOME}" ] || {
  echo "目录不存在: ${CS_HOME}" >&2
  echo "（没装 Cherry Studio，或装在别的位置？可用 CS_HOME=... 指定）" >&2
  exit 1
}

SWEEP_HOME="${CS_HOME}"
SWEEP_SIZE_DIRS=("占用:${CS_HOME}")

app_running() {
  pgrep -f 'CherryStudio' >/dev/null 2>&1
}

ui_head "Cherry Studio 清理" \
  "CS_HOME   ${CS_HOME}" \
  "今天      ${today}" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入 Session Storage / Service Worker 缓存 / 升级残留"
if app_running; then
  ui_note "⚠️  Cherry Studio 正在运行：GPU/渲染缓存清理后窗口可能短暂花屏，建议先退出应用再清"
fi
ui_note "扫描中…（进度见下方）"

SCAN_TOTAL=8

# ───────── 1) Electron 渲染缓存（根目录）─────────
scan_step "Electron 渲染缓存"
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary" "blob_storage"; do
  add_target "Electron 渲染缓存" "${CS_HOME}/${d}"
done

# ───────── 2) 内置浏览器缓存（Partitions）─────────
scan_step "内置浏览器缓存"
for part in "${CS_HOME}/Partitions"/*/; do
  [ -d "${part}" ] || continue
  pname=$(basename "${part}")
  for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
           "Shared Dictionary"; do
    add_target "内置浏览器缓存" "${part%/}/${d}" \
               "Partitions/${pname}/${d}"
  done
done

# ───────── 3) 隐私追踪残留 ─────────
scan_step "隐私追踪残留"
privacy_dirs=()
for d in "${CS_HOME}/InterestGroups" "${CS_HOME}/Trust Tokens" "${CS_HOME}/Trust Tokens-journal" \
         "${CS_HOME}/DIPS" "${CS_HOME}/DIPS-journal" "${CS_HOME}/DIPS-wal" \
         "${CS_HOME}/SharedStorage" "${CS_HOME}/SharedStorage-wal" "${CS_HOME}/SharedStorage-journal"; do
  [ -e "${d}" ] || continue
  privacy_dirs+=("${d}")
done
for part in "${CS_HOME}/Partitions"/*/; do
  [ -d "${part}" ] || continue
  for d in "InterestGroups" "Trust Tokens" "Trust Tokens-journal" \
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

# ───────── 4) 历史日志 ─────────
scan_step "历史日志"
log_files=()
if [ -d "${CS_HOME}/logs" ]; then
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    log_files+=("${f}")
  done < <(find "${CS_HOME}/logs" -maxdepth 1 -type f \( \
             -name 'app.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log' -o \
             -name 'app-error.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log' -o \
             -name '.*-audit.json' \) 2>/dev/null \
           ! -name "app.${today}.log" ! -name "app-error.${today}.log")
fi
if [ "${#log_files[@]}" -gt 0 ]; then
  add_group "历史日志" "logs/ 历史日志（${#log_files[@]} 个，今天的保留）" \
            "$(kb_of_multi "${log_files[@]}")" "${log_files[@]}"
fi

# ───────── 5) Crashpad 崩溃转储 ─────────
scan_step "崩溃转储"
crash_dirs=()
for d in completed new pending attachments; do
  p="${CS_HOME}/Crashpad/${d}"
  [ -d "${p}" ] || continue
  # 只收非空目录（空目录删了也无意义）
  [ -n "$(ls -A "${p}" 2>/dev/null | head -1)" ] && crash_dirs+=("${p}")
done
if [ "${#crash_dirs[@]}" -gt 0 ]; then
  add_group "崩溃转储" "Crashpad 崩溃转储（${#crash_dirs[@]} 个非空子目录）" \
            "$(kb_of_multi "${crash_dirs[@]}")" "${crash_dirs[@]}"
fi

# ───────── 6) 杂项小文件（蚊子腿） ─────────
# Session Storage/LOG.old（LevelDB 旧日志）+ 散落 .DS_Store
scan_step "杂项小文件"
misc_files=()
[ -f "${CS_HOME}/Session Storage/LOG.old" ] && misc_files+=("${CS_HOME}/Session Storage/LOG.old")
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  misc_files+=("${f}")
done < <(find "${CS_HOME}" -maxdepth 2 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#misc_files[@]}" -gt 0 ]; then
  add_group "杂项小文件" "LOG.old / .DS_Store（${#misc_files[@]} 个）" \
            "$(kb_of_multi "${misc_files[@]}")" "${misc_files[@]}"
fi

# ───────── 7) aggressive：Session Storage / SW 缓存 / 升级残留 ─────────
scan_step "aggressive 项"
aggr_paths=()
if [ "${AGGRESSIVE}" -eq 1 ]; then
  for p in "${CS_HOME}/Session Storage" \
           "${CS_HOME}/Service Worker/CacheStorage" \
           "${CS_HOME}/Service Worker/ScriptCache" \
           "${CS_HOME}/.updaterId" \
           "${CS_HOME}/version.log"; do
    [ -e "${p}" ] || continue
    aggr_paths+=("${p}")
  done
  for part in "${CS_HOME}/Partitions"/*/; do
    [ -d "${part}" ] || continue
    p="${part%/}/Session Storage"
    [ -e "${p}" ] && aggr_paths+=("${p}")
  done
  if [ "${#aggr_paths[@]}" -gt 0 ]; then
    add_group "aggressive 项" \
              "Session Storage / SW 缓存 / 升级残留（${#aggr_paths[@]} 处）" \
              "$(kb_of_multi "${aggr_paths[@]}")" "${aggr_paths[@]}"
  fi
fi

finish_progress

sweep_extra_notes() {
  # 真数据保护提示（不删，仅告知规模，方便确认「大头不在清理范围」）
  local live_total=0
  for d in Data IndexedDB "Local Storage" WebStorage Cookies; do
    [ -e "${CS_HOME}/${d}" ] || continue
    live_total=$((live_total + $(kb_of "${CS_HOME}/${d}")))
  done
  if [ "${live_total}" -gt 0 ]; then
    ui_note "保护中: Data/IndexedDB/Local Storage/WebStorage/Cookies 共 $(human "${live_total}")（会话与设置，永不清理）"
  fi
}

sweep_finish
