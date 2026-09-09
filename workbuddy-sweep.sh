#!/usr/bin/env bash
#
# clean-workbuddy.sh — 清理 WorkBuddy (~/.workbuddy) 的垃圾文件
# 编写依据：2026-09-09 对 ~/.workbuddy 各目录的逐项排查结论。
#
# ─────────────────────────────────────────────────────────────────────────────
# 脚本会删什么（共 6 类）：
#   1) logs/ 下早于「今天」的历史日期目录（如 2026-08-10 … 2026-09-08）
#        —— 之前每天的会话日志，今天不再写入，可删
#   2) logs/*.old.log —— 轮转旧日志（daemon.old.log / main.old.log / renderer.old.log）
#        —— 已被对应的 .log 取代，可删
#   3) logs/ 下过期零碎日志（数月未更新）：
#        connector-oauth-debug.log(2026-06-30) / file-domain-service.log(2026-06-30)
#        / debug.log(2026-05-07) / legacy-autolaunch-cleaner.log / .DS_Store
#   4) traces/ 下早于「今天」的会话追踪目录
#        —— OpenTelemetry 诊断遥测，纯调试数据，删了不影响功能；只保留今天（在写）
#   5) 缓存/冗余目录（整个删掉，不影响功能，必要时会自动重建）：
#        skills-marketplace/  技能市场目录缓存（下次打开重新拉取）
#        connectors-marketplace/  连接器市场目录缓存
#        cache/               产品配置等缓存
#        file-tree-manifests/ 文件树索引缓存（重新建索引）
#        shell-snapshots/     shell 快照缓存
#        clipboard-images/   剪贴板图片历史（丢失历史截图，不影响当前）
#        blobs/               文件内容 blob 存储（丢失版本 diff 历史，当前文件不受影响）
#        file-history/        文件编辑历史（丢失撤销/历史记录）
#        changes-detail/      变更明细缓存
#   6) backup-memory-YYYYMMDD/  过期记忆备份（当前记忆已在顶层，冗余）
#
# 脚本【不会】删（保持功能/数据安全）：
#   - 正在运行进程实时写入的当日日志：daemon.log / main.log / renderer.log /
#     AppStartup.log / mcp-apps-diag.log，以及 logs/ 中今天的日期目录
#   - binaries/ 托管运行时（Python+Node，所有工具依赖，删了会坏）
#   - plugins/ 已装插件、workspace/ Node 包、projects/ 项目数据
#   - security/ 凭据密钥、credentials/、memory/ 记忆、skills/ 已装技能、app/ 等运行数据
#
# 用法：
#   bash clean-workbuddy.sh          # 预览：扫描并展示可删项 + 预计释放空间，不真删
#   bash clean-workbuddy.sh --apply  # 执行删除，并展示共腾出多少空间
# ─────────────────────────────────────────────────────────────────────────────
set -u

WB_HOME="${HOME}/.workbuddy"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

today=$(date +%Y-%m-%d)

# 待删目标收集：路径 + 大小(KB)
declare -a T_PATHS=()
declare -a T_SIZES=()
TOTAL_KB=0

# KB -> 人类可读（用 awk，避免依赖 bc）
human() {
  awk -v kb="$1" 'BEGIN{
    if (kb >= 1048576) printf "%.2fG", kb/1048576;
    else if (kb >= 1024) printf "%.1fM", kb/1024;
    else printf "%dK", kb;
  }'
}

# 登记一个待删目标（不存在则忽略，并累计大小）
add_target() {
  local path="$1"
  [ -e "$path" ] || return 0
  local kb
  kb=$(du -sk "$path" 2>/dev/null | cut -f1)
  kb=${kb:-0}
  T_PATHS+=("$path")
  T_SIZES+=("$kb")
  TOTAL_KB=$((TOTAL_KB + kb))
}

echo "WorkBuddy 垃圾清理  WB_HOME=$WB_HOME  今天=$today"
echo "模式: $([ "$APPLY" -eq 1 ] && echo 实际删除 || echo 预览/不删)"
echo

echo "== 1) logs：删除历史日期目录（早于今天）=="
for d in "$WB_HOME"/logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -d "$d" ] || continue
  [ "$(basename "$d")" = "$today" ] && continue   # 保留今天的日志目录
  add_target "$d"
done

echo "== 2) logs：删除轮转旧日志 *.old.log =="
for f in "$WB_HOME"/logs/*.old.log; do
  [ -f "$f" ] || continue
  add_target "$f"
done

echo "== 3) logs：删除过期零碎日志（数月未更新）=="
for f in "$WB_HOME"/logs/connector-oauth-debug.log \
         "$WB_HOME"/logs/file-domain-service.log \
         "$WB_HOME"/logs/debug.log \
         "$WB_HOME"/logs/legacy-autolaunch-cleaner.log \
         "$WB_HOME"/logs/.DS_Store; do
  add_target "$f"
done

echo "== 4) traces：删除早于今天的会话追踪目录（纯诊断遥测）=="
for d in "$WB_HOME"/traces/*/; do
  [ -d "$d" ] || continue
  # 跳过 mtime 是今天的目录（可能正在写入）
  [ "$(stat -f '%Sm' -t '%Y-%m-%d' "$d")" = "$today" ] && continue
  add_target "$d"
done

echo "== 5) 缓存/冗余目录（可安全删，必要时自动重建）=="
for d in skills-marketplace connectors-marketplace cache file-tree-manifests \
         shell-snapshots clipboard-images blobs file-history changes-detail; do
  add_target "$WB_HOME/$d"
done

echo "== 6) 过期记忆备份 backup-memory-YYYYMMDD =="
for d in "$WB_HOME"/backup-memory-*; do
  [ -d "$d" ] || continue
  add_target "$d"
done

# ───────── 扫描结果展示 ─────────
echo
echo "================ 扫描结果 ================"
if [ "${#T_PATHS[@]}" -eq 0 ]; then
  echo "没有可删除的垃圾文件（已清理干净）。"
  exit 0
fi
printf "%-7s  %s\n" "大小" "路径"
for i in "${!T_PATHS[@]}"; do
  printf "%-7s  %s\n" "$(human "${T_SIZES[$i]}")" "${T_PATHS[$i]}"
done
echo "------------------------------------------"
printf "预计可释放空间: %s（共 %d 项）\n" "$(human "$TOTAL_KB")" "${#T_PATHS[@]}"

# 预览模式：到此结束
if [ "$APPLY" -ne 1 ]; then
  echo
  echo "预览模式，未删除。用  bash $0 --apply  执行删除。"
  exit 0
fi

# ───────── 正式删除 ─────────
echo
echo "================ 开始删除 ================"
for p in "${T_PATHS[@]}"; do
  rm -rf "$p" && echo "  [DEL] $p"
done
echo "=========================================="
printf "共腾出空间: %s（%d 项）\n" "$(human "$TOTAL_KB")" "${#T_PATHS[@]}"
echo "清理后占用: $(du -sh "$WB_HOME" 2>/dev/null | cut -f1)"
