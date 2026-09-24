#!/usr/bin/env bash
#
# workbuddy-sweep.sh — 清理 WorkBuddy 堆积的缓存 / 日志 / 追踪 / 空会话目录
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# 扫描目标：
#   1) logs/ 下早于今天的历史日期目录
#   2) logs/*.old.log 轮转旧日志
#   3) logs/ 下过期零碎日志（connector-oauth-debug.log 等）
#   4) logs/sandbox/ 沙箱会话日志  ★ 通常最大头
#        非今天的日期目录整体删；今天的按 sandbox_[center_]<pid>_* 分组，
#        仅当该 pid 已不存在（且 ≥SANDBOX_COOLDOWN_MIN 分钟无写入）才删。
#        活着的会话（当前正在跑的沙箱）一律跳过。
#   5) traces/* 窥探追踪目录（闲置 ≥TRACE_MAX_AGE_MIN 分钟）
#   6) 缓存/冗余目录：skills-marketplace / connectors-marketplace / cache /
#        file-tree-manifests / shell-snapshots / clipboard-images / blobs /
#        file-history / changes-detail
#   7) app/session/ 下 Electron 纯缓存（不动 WebStorage / IndexedDB 等登录态）
#   8) backup-memory-YYYYMMDD 过期记忆备份
#   9) 散落的 .DS_Store（限 WB_HOME 下 3 层）
#   9b) logs/ 子目录里的日期命名过期日志
#        update/update-YYYYMMDD.log、migration/migration-YYYYMMDD.log、
#        startup/startup-YYYY-MM-DD.log（早于今天的才算）
#   9c) logs/perf/ 闲置性能采样（worker-startup-*.jsonl，闲置 ≥1 天）
#   9d) logs/Crash-Log/ 过期崩溃报告（crash-report-*.json，闲置 ≥7 天；
#        .processed-crashes.json 是状态文件，永不碰）
#   9e) audit-log/ 过期审计日志（YYYY-MM-DD*.jsonl 早于今天的清；
#        manifest.jsonl / state.json / spool 是状态与暂存，永不碰）
#  10) WB_WORKSPACES（默认 ~/WorkBuddy）下的【空】会话时间目录
#        名字必须严格是 YYYY-MM-DD-HH-MM-SS，且真的一无所有。
#        名字不是这个格式的一律不碰（认不出主人，如 Claw）；
#        刚创建不足 EMPTY_SESSION_COOLDOWN_MIN 分钟的空目录也跳过
#        —— 可能是已开始但还没写文件的活跃会话。
#        ⚠️ 空目录不占空间，清它只是去杂乱，不省磁盘。
#
#   --aggressive 追加：plugins/marketplaces/（市场清单，下次打开自动重拉）
#
# 【不会】删：
#   - binaries/ 托管运行时（Python + Node，所有工具依赖）
#   - plugins/cache/ 已安装插件、plugins/installed_plugins.json
#   - projects/ 会话数据、security/ 凭据、credentials/、memory/、skills/、workspace/
#   - appearance-resources/（theme-* 是用户已安装的主题包，属于用户资产）
#   - storage/、local_storage/（应用数据与登录态）
#   - 正在写入的活跃日志：daemon.log / main.log / renderer.log / mcp-apps-diag.log /
#     file-service.log / AppStartup.log，以及 logs/ 中今天的日期目录
#   - WB_WORKSPACES 下任何非空的会话目录
#
# 用法：
#   ./workbuddy-sweep.sh                     # 扫描 → 列清单 → 交互选择要清的项
#   ./workbuddy-sweep.sh sandbox             # 只把名字/路径含 sandbox 的项列进清单
#   ./workbuddy-sweep.sh sandbox traces      # 多个关键词 = 并集（含 sandbox 或 traces）
#   ./workbuddy-sweep.sh sandbox --and 2026  # 交集（同时含两词才算）
#   ./workbuddy-sweep.sh --only sandbox,traces  # 逗号连写，等价于空格分隔
#   ./workbuddy-sweep.sh --aggressive        # 清单里额外含 plugins/marketplaces
#   ./workbuddy-sweep.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐项确认（y=移入 n=跳过 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./workbuddy-sweep.sh --clean sandbox --yes   # 跳过交互，直接清匹配项
#   ./workbuddy-sweep.sh --clean --all           # 进交互但清单是全部，仍需手输 yes
#   ⚠️ 裸 --clean（既没关键词也没 --all）拒绝执行，退出码 2 —— 手滑敲出来不会变成全删。
#   ⚠️ --yes 必须带筛选条件：--clean --all --yes 这种「一句话全清空」被刻意堵死。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「类别名 / 条目名 / 条目内任一完整路径」的子串，忽略大小写。
#   多个关键词默认「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（再给一个关键词就切回并集），可混排：a b --and c = (a 或 b) 且 c。
#   ⚠️ 交互里的编号只对「本次显示顺序」有效，每次都会重排；筛选一律按关键词走。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
#    注意：废纸篓里的东西仍占磁盘，清空废纸篓后空间才真正释放。
#
# 可调环境变量：
#   WB_HOME                     目标目录，默认 ~/.workbuddy
#   WB_WORKSPACES               会话工作目录根，默认 ~/WorkBuddy
#   TRACE_MAX_AGE_MIN           traces 闲置阈值（分钟），默认 60
#   SANDBOX_COOLDOWN_MIN        沙箱会话冷却阈值（分钟），默认 5
#   EMPTY_SESSION_COOLDOWN_MIN  空会话目录的最短年龄（分钟），默认 60
#
# ⚠️ 没有「单次上限」：选中之后清单上的项一次处理完，不会清到一半停住。
# ⚠️ 本脚本不产生任何临时文件。
# ─────────────────────────────────────────────────────────────────────────────
set -u

# ⚠️ --apply 兼容提示先于公共库注册：source 时公共库的参数解析会调用本钩子
sweep_extra_arg() {
  case "$1" in
    --apply)
      echo "参数 --apply 已改名为 --clean，且必须明确范围：" >&2
      echo "  bash $0 --clean --all         # 全部清单（仍需输入 yes）" >&2
      echo "  bash $0 --clean <关键词>      # 只清匹配的项" >&2
      exit 2 ;;
  esac
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

WB_HOME="${WB_HOME:-${HOME}/.workbuddy}"
WB_WORKSPACES="${WB_WORKSPACES:-${HOME}/WorkBuddy}"
TRACE_MAX_AGE_MIN="${TRACE_MAX_AGE_MIN:-60}"
SANDBOX_COOLDOWN_MIN="${SANDBOX_COOLDOWN_MIN:-5}"
EMPTY_SESSION_COOLDOWN_MIN="${EMPTY_SESSION_COOLDOWN_MIN:-60}"

[ -d "${WB_HOME}" ] || { echo "目录不存在: ${WB_HOME}" >&2; exit 1; }

SWEEP_HOME="${WB_HOME}"
SWEEP_SIZE_DIRS=("占用:${WB_HOME}")

ui_head "WorkBuddy 清理" \
  "WB_HOME   ${WB_HOME}" \
  "会话目录  ${WB_WORKSPACES}" \
  "今天      ${today}" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${AGGRESSIVE}" -eq 1 ] && ui_note "aggressive：额外纳入 plugins/marketplaces"
ui_note "扫描中…（进度见下方）"

SCAN_TOTAL=17

# ───────── 1) logs 历史日期目录 ─────────
scan_step "logs 历史日期目录"
for d in "${WB_HOME}"/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "${d}" ] || continue
  [ "$(basename "${d}")" = "${today}" ] && continue
  add_target "logs 历史日期目录" "${d}"
done

# ───────── 2) logs 轮转旧日志 ─────────
scan_step "logs 轮转旧日志"
for f in "${WB_HOME}"/logs/*.old.log; do
  [ -f "${f}" ] || continue
  add_target "logs 轮转旧日志" "${f}"
done

# ───────── 3) logs 过期零碎日志 ─────────
scan_step "logs 过期零碎日志"
for f in connector-oauth-debug.log file-domain-service.log debug.log \
         legacy-autolaunch-cleaner.log; do
  add_target "logs 过期零碎日志" "${WB_HOME}/logs/${f}"
done

# ───────── 4) logs/sandbox 沙箱会话日志 ★ ─────────
scan_step "logs/sandbox 沙箱会话"
sb_root="${WB_HOME}/logs/sandbox"
if [ -d "${sb_root}" ]; then
  for day in "${sb_root}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -d "${day}" ] || continue
    dayname=$(basename "${day}")
    dayfmt="${dayname:0:4}-${dayname:4:2}-${dayname:6:2}"
    # 非今天的日期目录：整体删
    if [ "${dayfmt}" != "${today}" ]; then
      add_target "logs/sandbox 历史会话" "${day}"
      continue
    fi
    # 今天：按沙箱进程分组，只删已结束的
    for pid in $(ls "${day}" 2>/dev/null \
                 | sed -nE 's/^sandbox_(center_)?([0-9]+)(\.mmap3|_[0-9]+\.log)$/\2/p' \
                 | sort -un); do
      files=(); has_center=0
      while IFS= read -r f; do
        [ -n "${f}" ] || continue
        files+=("${day}/${f}")
        case "${f}" in sandbox_center_*) has_center=1 ;; esac
      done < <(ls "${day}" 2>/dev/null | grep -E "^sandbox_(center_)?${pid}(\.mmap3|_[0-9]+\.log)$")

      [ "${#files[@]}" -gt 0 ] || continue
      # 活着的沙箱会话 → 跳过
      proc_alive "${pid}" && continue
      # 冷却：最近仍在写 → 跳过（防 pid 复用 / 竞态）
      newest=$(stat -f '%m' "${files[@]}" 2>/dev/null | sort -rn | head -1)
      if [ -n "${newest}" ]; then
        [ "$(( (now - newest) / 60 ))" -lt "${SANDBOX_COOLDOWN_MIN}" ] && continue
      fi
      if [ "${has_center}" -eq 1 ]; then
        pidlabel="pid=${pid}(center)"
      else
        pidlabel="pid=${pid}"
      fi
      add_group "logs/sandbox 已结束会话" \
                "logs/sandbox/${dayname}  ${pidlabel}（${#files[@]} 个文件）" \
                "$(kb_of_multi "${files[@]}")" "${files[@]}"
    done
  done
fi

# ───────── 5) traces 闲置追踪目录 ─────────
scan_step "traces 闲置追踪"
for d in "${WB_HOME}"/traces/*/; do
  [ -d "${d}" ] || continue
  m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "${now}")
  age_min=$(( (now - m) / 60 ))
  [ "${age_min}" -lt "${TRACE_MAX_AGE_MIN}" ] && continue
  add_target "traces 闲置追踪" "${d%/}" "traces/$(basename "${d}")/（闲置 ${age_min} 分钟）"
done

# ───────── 6) 缓存 / 冗余目录 ─────────
scan_step "缓存 / 冗余目录"
for d in skills-marketplace connectors-marketplace cache file-tree-manifests \
         shell-snapshots clipboard-images blobs file-history changes-detail; do
  add_target "缓存/冗余目录" "${WB_HOME}/${d}"
done

# ───────── 7) app/session Electron 纯缓存 ─────────
scan_step "Electron 渲染缓存"
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary"; do
  add_target "Electron 渲染缓存" "${WB_HOME}/app/session/${d}"
done

# ───────── 8) 过期记忆备份 ─────────
scan_step "过期记忆备份"
for d in "${WB_HOME}"/backup-memory-*; do
  [ -d "${d}" ] || continue
  add_target "过期记忆备份" "${d}"
done

# ───────── 9) 散落 .DS_Store ─────────
scan_step "散落 .DS_Store"
ds_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  ds_files+=("${f}")
done < <(find "${WB_HOME}" -maxdepth 3 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  add_group "散落 .DS_Store" "散落 .DS_Store（${#ds_files[@]} 个）" \
            "$(kb_of_multi "${ds_files[@]}")" "${ds_files[@]}"
fi

# ───────── 9b) logs/ 子目录里的日期命名过期日志 ─────────
# update/update-YYYYMMDD.log · migration/migration-YYYYMMDD.log ·
# startup/startup-YYYY-MM-DD.log —— 早于今天的整体清，今天的保留
scan_step "logs 子目录过期日志"
sub_dated=()
for f in "${WB_HOME}"/logs/update/update-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].log \
         "${WB_HOME}"/logs/migration/migration-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].log \
         "${WB_HOME}"/logs/startup/startup-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log; do
  [ -f "${f}" ] || continue
  case "${f}" in
    *update-*)      fdate="${f##*update-}";    fdate="${fdate%.log}"; fdate="${fdate:0:4}-${fdate:4:2}-${fdate:6:2}" ;;
    *migration-*)   fdate="${f##*migration-}"; fdate="${fdate%.log}"; fdate="${fdate:0:4}-${fdate:4:2}-${fdate:6:2}" ;;
    *startup-*)     fdate="${f##*startup-}";   fdate="${fdate%.log}" ;;
  esac
  [ "${fdate}" = "${today}" ] && continue
  sub_dated+=("${f}")
done
if [ "${#sub_dated[@]}" -gt 0 ]; then
  add_group "logs 子目录过期日志" \
            "logs/{update,migration,startup}/ 过期日志（${#sub_dated[@]} 个，今天的保留）" \
            "$(kb_of_multi "${sub_dated[@]}")" "${sub_dated[@]}"
fi

# ───────── 9c) logs/perf/ 闲置性能采样 ─────────
# worker-startup-*.jsonl 每次启动都写，闲置 ≥1 天即可回收（老旧文件无分析价值）
scan_step "perf 闲置采样"
PERF_MAX_AGE_MIN="${PERF_MAX_AGE_MIN:-1440}"
perf_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  m=$(stat -f '%m' "${f}" 2>/dev/null || echo "${now}")
  [ "$(( (now - m) / 60 ))" -lt "${PERF_MAX_AGE_MIN}" ] && continue
  perf_files+=("${f}")
done < <(find "${WB_HOME}/logs/perf" -maxdepth 1 -type f -name 'worker-startup-*.jsonl' 2>/dev/null)
if [ "${#perf_files[@]}" -gt 0 ]; then
  add_group "perf 闲置采样" \
            "logs/perf/ 性能采样（${#perf_files[@]} 个，闲置 ≥$(( PERF_MAX_AGE_MIN / 60 )) 小时）" \
            "$(kb_of_multi "${perf_files[@]}")" "${perf_files[@]}"
fi

# ───────── 9d) logs/Crash-Log/ 过期崩溃报告 ─────────
# crash-report-*.json 闲置 ≥7 天即清；.processed-crashes.json 是状态文件，永不碰
scan_step "过期崩溃报告"
CRASHLOG_MAX_AGE_MIN="${CRASHLOG_MAX_AGE_MIN:-10080}"
crash_files=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  m=$(stat -f '%m' "${f}" 2>/dev/null || echo "${now}")
  [ "$(( (now - m) / 60 ))" -lt "${CRASHLOG_MAX_AGE_MIN}" ] && continue
  crash_files+=("${f}")
done < <(find "${WB_HOME}/logs/Crash-Log" -maxdepth 1 -type f -name 'crash-report-*.json' 2>/dev/null)
if [ "${#crash_files[@]}" -gt 0 ]; then
  add_group "过期崩溃报告" \
            "logs/Crash-Log/ 崩溃报告（${#crash_files[@]} 个，闲置 ≥$(( CRASHLOG_MAX_AGE_MIN / 1440 )) 天）" \
            "$(kb_of_multi "${crash_files[@]}")" "${crash_files[@]}"
fi

# ───────── 9e) audit-log/ 过期审计日志 ─────────
# audit-log/YYYY-MM-DD*.jsonl 按天滚动，早于今天的清；
# manifest.jsonl（索引）/ state.json（状态）/ spool/（暂存队列）永不碰。
scan_step "过期审计日志"
audit_files=()
for f in "${WB_HOME}"/audit-log/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.jsonl; do
  [ -f "${f}" ] || continue
  fname=$(basename "${f}")
  [ "${fname:0:10}" = "${today}" ] && continue
  audit_files+=("${f}")
done
if [ "${#audit_files[@]}" -gt 0 ]; then
  add_group "过期审计日志" \
            "audit-log/ 过期审计日志（${#audit_files[@]} 个，今天的保留）" \
            "$(kb_of_multi "${audit_files[@]}")" "${audit_files[@]}"
fi

# ───────── 10) WB_WORKSPACES 下的空会话时间目录 ─────────
# 只认严格的时间命名，且真的一无所有；非空 / 命名不符 / 刚创建的都不碰。
scan_step "空会话目录"
empty_dirs=(); ws_skipped_recent=0; ws_nonempty=0; ws_other=0
if [ -d "${WB_WORKSPACES}" ]; then
  for d in "${WB_WORKSPACES}"/*; do
    [ -e "${d}" ] || continue            # 纯 glob 无匹配时跳过，不 fork
    [ -d "${d}" ] || continue            # 只处理目录
    [ -L "${d}" ] && continue            # 符号链接不碰
    case "$(basename "${d}")" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) ws_other=$((ws_other + 1)); continue ;;   # 认不出主人 → 不碰
    esac
    if [ -n "$(ls -A "${d}" 2>/dev/null | head -1)" ]; then
      ws_nonempty=$((ws_nonempty + 1)); continue   # 有东西 → 不是空目录
    fi
    m=$(stat -f '%m' "${d}" 2>/dev/null || echo "${now}")
    if [ "$(( (now - m) / 60 ))" -lt "${EMPTY_SESSION_COOLDOWN_MIN}" ]; then
      ws_skipped_recent=$((ws_skipped_recent + 1)); continue   # 可能是在跑的会话
    fi
    empty_dirs+=("${d}")
  done
fi
if [ "${#empty_dirs[@]}" -gt 0 ]; then
  add_group_keep0 "空会话目录" \
    "会话工作目录空目录（${#empty_dirs[@]} 个，不占空间）" \
    "$(kb_of_multi "${empty_dirs[@]}")" "${empty_dirs[@]}"
fi

# ───────── 11) aggressive：插件市场清单 ─────────
scan_step "插件市场清单"
if [ "${AGGRESSIVE}" -eq 1 ] && [ -d "${WB_HOME}/plugins/marketplaces" ]; then
  add_target "插件市场清单(aggressive)" "${WB_HOME}/plugins/marketplaces" \
             "plugins/marketplaces/（下次打开自动重拉）"
fi

# ───────── 12) 活跃日志统计（只提示，不清理）─────────
scan_step "活跃日志统计"
live_total=0
for f in daemon.log main.log renderer.log mcp-apps-diag.log file-service.log AppStartup.log; do
  [ -f "${WB_HOME}/logs/${f}" ] || continue
  live_total=$((live_total + $(kb_of "${WB_HOME}/logs/${f}")))
done

finish_progress

sweep_extra_notes() {
  # 空会话目录的旁注：说清楚什么被跳过了、为什么
  if [ "${ws_nonempty}" -gt 0 ] || [ "${ws_skipped_recent}" -gt 0 ] || [ "${ws_other}" -gt 0 ]; then
    ui_note "空会话目录旁注: ${ws_nonempty} 个非空已保留；${ws_skipped_recent} 个创建不足 ${EMPTY_SESSION_COOLDOWN_MIN} 分钟跳过；${ws_other} 个命名不符跳过（${WB_WORKSPACES}）"
  fi
  # 活跃日志提示（不删，仅告知）
  if [ "${live_total}" -gt 20480 ]; then
    ui_note "提示: 正在写入的活跃日志另有 $(human "${live_total}")（不清理；如需回收可重启 WorkBuddy 后手动截断）"
  fi
  ui_note "appearance-resources/ 是用户已安装的主题包（theme-*），storage/ 是应用数据 —— 一律不清理"
}

sweep_finish
