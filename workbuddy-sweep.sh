#!/usr/bin/env bash
#
# workbuddy-sweep.sh — 安全清理 WorkBuddy (~/.workbuddy) 下的缓存 / 日志 / 追踪垃圾
#
# ─────────────────────────────────────────────────────────────────────────────
# 默认只预览，不删；加 --apply 才真正删除。扫描 9 类目标：
#
#   1) logs/ 下早于今天的历史日期目录
#   2) logs/*.old.log 轮转旧日志
#   3) logs/ 下过期零碎日志（数月未更新）
#   4) logs/sandbox/ 沙箱会话日志  ★ 通常最大头（实测单日可达数百 MB）
#        规则：非今天的日期目录整体删；今天的按 sandbox_[center_]<pid>_* 分组，
#        仅当该 pid 已不存在（且该组 ≥SANDBOX_COOLDOWN_MIN 分钟无写入）才删。
#        活着的会话（当前正在跑的沙箱）一律跳过。
#   5) traces/* 窥探追踪目录（OpenTelemetry，纯诊断数据）
#        规则：闲置 ≥TRACE_MAX_AGE_MIN 分钟即删（不再受"今天"限制）
#   6) 缓存/冗余目录：skills-marketplace / connectors-marketplace / cache /
#        file-tree-manifests / shell-snapshots / clipboard-images / blobs /
#        file-history / changes-detail
#   7) app/session/ 下 Electron 纯缓存：Cache / Code Cache / GPUCache /
#        DawnWebGPUCache / DawnGraphiteCache / Shared Dictionary
#        （不动 WebStorage / IndexedDB / Local Storage / Partitions —— 含登录态）
#   8) backup-memory-YYYYMMDD 过期记忆备份
#   9) 散落的 .DS_Store（限 WB_HOME 下 3 层）
#
#   --aggressive 追加：plugins/marketplaces/（市场清单，下次打开自动重拉）
#
# 【不会】删：
#   - binaries/ 托管运行时（Python + Node，所有工具依赖）
#   - plugins/cache/ 已安装插件、plugins/installed_plugins.json
#   - projects/ 会话数据、security/ 凭据、credentials/、memory/、skills/、workspace/
#   - 正在写入的活跃日志：daemon.log / main.log / renderer.log / mcp-apps-diag.log /
#     file-service.log / AppStartup.log，以及 logs/ 中今天的日期目录
#
# 用法：
#   ./workbuddy-sweep.sh                  # 预览（不删）
#   ./workbuddy-sweep.sh --apply          # 执行删除
#   ./workbuddy-sweep.sh --aggressive     # 预览（额外含 plugins/marketplaces）
#   ./workbuddy-sweep.sh --apply --aggressive
#
# 可调环境变量：
#   WB_HOME               目标目录，默认 ~/.workbuddy
#   TRACE_MAX_AGE_MIN     traces 闲置阈值（分钟），默认 60
#   SANDBOX_COOLDOWN_MIN  沙箱会话冷却阈值（分钟），默认 5
# ─────────────────────────────────────────────────────────────────────────────
set -u

WB_HOME="${WB_HOME:-${HOME}/.workbuddy}"
APPLY=0
AGGRESSIVE=0

for arg in "$@"; do
  case "$arg" in
    --apply)      APPLY=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    -h|--help)    sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg（可用: --apply / --aggressive / --help）" >&2; exit 2 ;;
  esac
done

TRACE_MAX_AGE_MIN="${TRACE_MAX_AGE_MIN:-60}"
SANDBOX_COOLDOWN_MIN="${SANDBOX_COOLDOWN_MIN:-5}"

[ -d "$WB_HOME" ] || { echo "目录不存在: $WB_HOME" >&2; exit 1; }

today=$(date +%Y-%m-%d)
now=$(date +%s)

# ───────── 收集容器 ─────────
declare -a T_PATHS=()   # 路径（组则为换行分隔的多路径）
declare -a T_SIZES=()   # 大小 KB
declare -a T_LABELS=()  # 展示名
declare -a T_CATS=()    # 所属类别
TOTAL_KB=0

human() {
  awk -v kb="$1" 'BEGIN{
    if (kb >= 1048576) printf "%.2fG", kb/1048576;
    else if (kb >= 1024) printf "%.1fM", kb/1024;
    else printf "%dK", kb;
  }'
}

kb_of() {  # 单个路径的 KB
  local kb
  kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  echo "${kb:-0}"
}

kb_of_multi() {  # 多个路径合计 KB
  local kb
  kb=$(du -ck "$@" 2>/dev/null | tail -1 | cut -f1 | tr -dc '0-9')
  echo "${kb:-0}"
}

# 登记单个路径
add_target() {  # add_target <cat> <path> [label]
  local cat="$1" path="$2" label="${3:-}"
  [ -e "$path" ] || return 0
  local kb; kb=$(kb_of "$path")
  [ "$kb" -eq 0 ] && return 0
  [ -n "$label" ] || label="${path#"$WB_HOME"/}"
  T_PATHS+=("$path"); T_SIZES+=("$kb"); T_LABELS+=("$label"); T_CATS+=("$cat")
  TOTAL_KB=$((TOTAL_KB + kb))
}

# 登记一组路径（合并成一条记录）
add_group() {  # add_group <cat> <label> <kb> <path...>
  local cat="$1" label="$2" kb="$3"; shift 3
  [ "$#" -gt 0 ] || return 0
  [ "$kb" -eq 0 ] && return 0
  local joined; joined=$(printf '%s\n' "$@")
  T_PATHS+=("$joined"); T_SIZES+=("$kb"); T_LABELS+=("$label"); T_CATS+=("$cat")
  TOTAL_KB=$((TOTAL_KB + kb))
}

# 进程是否仍存在（ps 在受限环境可能不可用，用 kill -0 兜底）
proc_alive() {
  local pid="${1:-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  ps -p "$pid" >/dev/null 2>&1 && return 0
  kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

echo "WorkBuddy 清理  WB_HOME=$WB_HOME  今天=$today"
echo "模式: $([ "$APPLY" -eq 1 ] && echo '实际删除' || echo '预览/不删')$([ "$AGGRESSIVE" -eq 1 ] && echo ' + aggressive')"
echo

# ───────── 1) logs 历史日期目录 ─────────
for d in "$WB_HOME"/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "$d" ] || continue
  [ "$(basename "$d")" = "$today" ] && continue
  add_target "logs 历史日期目录" "$d"
done

# ───────── 2) logs 轮转旧日志 ─────────
for f in "$WB_HOME"/logs/*.old.log; do
  [ -f "$f" ] || continue
  add_target "logs 轮转旧日志" "$f"
done

# ───────── 3) logs 过期零碎日志 ─────────
for f in connector-oauth-debug.log file-domain-service.log debug.log \
         legacy-autolaunch-cleaner.log; do
  add_target "logs 过期零碎日志" "$WB_HOME/logs/$f"
done

# ───────── 4) logs/sandbox 沙箱会话日志 ★ ─────────
sb_root="$WB_HOME/logs/sandbox"
if [ -d "$sb_root" ]; then
  for day in "$sb_root"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -d "$day" ] || continue
    dayname=$(basename "$day")
    dayfmt="${dayname:0:4}-${dayname:4:2}-${dayname:6:2}"
    # 非今天的日期目录：整体删
    if [ "$dayfmt" != "$today" ]; then
      add_target "logs/sandbox 历史会话" "$day"
      continue
    fi
    # 今天：按沙箱进程分组，只删已结束的
    for pid in $(ls "$day" 2>/dev/null \
                 | sed -nE 's/^sandbox_(center_)?([0-9]+)(\.mmap3|_[0-9]+\.log)$/\2/p' \
                 | sort -un); do
      files=(); has_center=0
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        files+=("$day/$f")
        case "$f" in sandbox_center_*) has_center=1 ;; esac
      done < <(ls "$day" 2>/dev/null | grep -E "^sandbox_(center_)?${pid}(\.mmap3|_[0-9]+\.log)$")

      [ "${#files[@]}" -gt 0 ] || continue
      # 活着的沙箱会话 → 跳过
      proc_alive "$pid" && continue
      # 冷却：最近仍在写 → 跳过（防 pid 复用 / 竞态）
      newest=$(stat -f '%m' "${files[@]}" 2>/dev/null | sort -rn | head -1)
      if [ -n "$newest" ]; then
        [ "$(( (now - newest) / 60 ))" -lt "$SANDBOX_COOLDOWN_MIN" ] && continue
      fi
      kb=$(kb_of_multi "${files[@]}")
      [ "$has_center" -eq 1 ] && pidlabel="pid=$pid(center)" || pidlabel="pid=$pid"
      add_group "logs/sandbox 已结束会话" \
                "logs/sandbox/$dayname  $pidlabel（${#files[@]} 个文件）" \
                "$kb" "${files[@]}"
    done
  done
fi

# ───────── 5) traces 闲置追踪目录 ─────────
for d in "$WB_HOME"/traces/*/; do
  [ -d "$d" ] || continue
  m=$(stat -f '%m' "${d%/}" 2>/dev/null || echo "$now")
  age_min=$(( (now - m) / 60 ))
  [ "$age_min" -lt "$TRACE_MAX_AGE_MIN" ] && continue
  add_target "traces 闲置追踪" "${d%/}" "traces/$(basename "$d")/（闲置 ${age_min} 分钟）"
done

# ───────── 6) 缓存 / 冗余目录 ─────────
for d in skills-marketplace connectors-marketplace cache file-tree-manifests \
         shell-snapshots clipboard-images blobs file-history changes-detail; do
  add_target "缓存/冗余目录" "$WB_HOME/$d"
done

# ───────── 7) app/session Electron 纯缓存 ─────────
for d in "Cache" "Code Cache" "GPUCache" "DawnWebGPUCache" "DawnGraphiteCache" \
         "Shared Dictionary"; do
  add_target "Electron 渲染缓存" "$WB_HOME/app/session/$d"
done

# ───────── 8) 过期记忆备份 ─────────
for d in "$WB_HOME"/backup-memory-*; do
  [ -d "$d" ] || continue
  add_target "过期记忆备份" "$d"
done

# ───────── 9) 散落 .DS_Store ─────────
ds_files=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  ds_files+=("$f")
done < <(find "$WB_HOME" -maxdepth 3 -name '.DS_Store' -type f 2>/dev/null)
if [ "${#ds_files[@]}" -gt 0 ]; then
  add_group "散落 .DS_Store" "散落 .DS_Store（${#ds_files[@]} 个）" \
            "$(kb_of_multi "${ds_files[@]}")" "${ds_files[@]}"
fi

# ───────── 10) aggressive：插件市场清单 ─────────
if [ "$AGGRESSIVE" -eq 1 ] && [ -d "$WB_HOME/plugins/marketplaces" ]; then
  add_target "插件市场清单(aggressive)" "$WB_HOME/plugins/marketplaces" \
             "plugins/marketplaces/（下次打开自动重拉）"
fi

# ───────── 扫描结果 ─────────
echo "================ 扫描结果 ================"
if [ "${#T_PATHS[@]}" -eq 0 ]; then
  echo "没有可删除的垃圾文件（已清理干净）。"
  echo
  echo "当前占用: $(du -sh "$WB_HOME" 2>/dev/null | cut -f1)"
  exit 0
fi

prev_cat=""
for i in "${!T_PATHS[@]}"; do
  if [ "${T_CATS[$i]}" != "$prev_cat" ]; then
    echo
    echo "[${T_CATS[$i]}]"
    prev_cat="${T_CATS[$i]}"
  fi
  printf "  %-8s %s\n" "$(human "${T_SIZES[$i]}")" "${T_LABELS[$i]}"
done

echo
echo "------------------------------------------"
printf "预计可释放空间: %s（共 %d 项）\n" "$(human "$TOTAL_KB")" "${#T_PATHS[@]}"
echo "清理前占用: $(du -sh "$WB_HOME" 2>/dev/null | cut -f1)"

# 活跃日志提示（不删，仅告知）
live_total=0
for f in daemon.log main.log renderer.log mcp-apps-diag.log file-service.log AppStartup.log; do
  [ -f "$WB_HOME/logs/$f" ] || continue
  live_total=$((live_total + $(kb_of "$WB_HOME/logs/$f")))
done
if [ "$live_total" -gt 20480 ]; then
  echo "提示: 正在写入的活跃日志另有 $(human "$live_total")（未删除；如需回收可重启 WorkBuddy 后手动截断）"
fi

# 预览模式结束
if [ "$APPLY" -ne 1 ]; then
  echo
  echo "预览模式，未删除。用  bash $0 --apply  执行删除。"
  exit 0
fi

# ───────── 正式删除 ─────────
echo
echo "================ 开始删除 ================"
ok=0; fail=0
for i in "${!T_PATHS[@]}"; do
  p="${T_PATHS[$i]}"
  # 组记录按行拆分成多个路径
  if printf '%s' "$p" | grep -q $'\n'; then
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      rm -rf "$one" 2>/dev/null || fail=$((fail+1))
    done <<< "$p"
    echo "  [DEL] ${T_LABELS[$i]}"
  else
    if rm -rf "$p" 2>/dev/null; then
      echo "  [DEL] ${T_LABELS[$i]}"
    else
      echo "  [ERR] ${T_LABELS[$i]}"
      fail=$((fail+1))
    fi
  fi
  ok=$((ok+1))
done
echo "=========================================="
printf "共腾出空间: %s（%d 项）\n" "$(human "$TOTAL_KB")" "${#T_PATHS[@]}"
[ "$fail" -gt 0 ] && echo "有 $fail 项删除失败（可能被运行中的进程占用）"
echo "清理后占用: $(du -sh "$WB_HOME" 2>/dev/null | cut -f1)"
