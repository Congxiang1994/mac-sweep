# workbuddy-sweep

🧹 清理 [WorkBuddy](https://workbuddy.cn) 在 `~/.workbuddy` 下产生的缓存、日志、追踪等垃圾文件的安全脚本。

扫描后会列出可删除项与**预计释放空间**；默认只预览、**不删除**，加 `--apply` 才真正清理。

> 安全边界：脚本只删「缓存 / 历史 / 过期」类数据，绝不碰运行时、插件、项目数据、凭据与记忆。详见下方「不会删除什么」。

## 特性

- **预览模式**：扫描并展示每一项可删文件/目录的大小、预计可释放总空间
- **删除模式**：执行删除并打印共腾出多少空间、清理后总占用
- 不删正在运行的**当日**日志（避免破坏正在写入的进程）
- **幂等**：多次运行只处理当下残留，不会重复删已删项
- **零依赖**：仅用 bash + 系统自带 `du` / `stat`（macOS）

## 会删除什么（共 6 类）

1. `logs/` 中早于今天的历史日期目录（如 `2026-08-10` … `2026-09-08`）
2. `logs/*.old.log` 轮转旧日志
3. `logs/` 下过期零碎日志：`connector-oauth-debug.log`、`file-domain-service.log`、`debug.log`、`legacy-autolaunch-cleaner.log`、`.DS_Store`
4. `traces/` 中早于今天的会话追踪目录（OpenTelemetry 诊断遥测，纯调试数据）
5. 缓存/冗余目录：`skills-marketplace`、`connectors-marketplace`、`cache`、`file-tree-manifests`、`shell-snapshots`、`clipboard-images`、`blobs`、`file-history`、`changes-detail`
6. `backup-memory-YYYYMMDD` 过期记忆备份

## 不会删除什么

- 正在运行进程实时写入的当日日志：`daemon.log`、`main.log`、`renderer.log`、`AppStartup.log`、`mcp-apps-diag.log` 及 `logs/` 中今天的日期目录
- `binaries/` 托管运行时（Python + Node，所有工具依赖，删了会坏）
- `plugins/`、`workspace/`、`projects/`、`security/`、`credentials/`、`memory/`、`skills/`、`app/` 等运行/数据目录

## 安装

```bash
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/workbuddy-sweep.sh
chmod +x workbuddy-sweep.sh
```

或直接克隆本仓库。

## 使用

```bash
./workbuddy-sweep.sh          # 预览：列出可删项 + 预计释放空间（不删）
./workbuddy-sweep.sh --apply  # 执行删除，并展示共腾出多少空间
```

预览示例输出：

```
================ 扫描结果 ================
大小   路径
8K       .../shell-snapshots
20K      .../changes-detail
------------------------------------------
预计可释放空间: 28K（共 2 项）
```

删除示例输出：

```
================ 开始删除 ================
  [DEL] .../shell-snapshots
==========================================
共腾出空间: 28K（2 项）
清理后占用: 2.5G
```

## 注意事项

- 当前仅适配 **macOS**（使用 BSD 版 `stat -f`）。Linux 需把 `stat -f '%Sm' -t '%Y-%m-%d'` 改为 GNU `stat -c '%y'` 写法。
- 删除 `blobs/`、`file-history/` 会丢失版本/编辑历史，但**不影响当前文件**。
- 建议先跑预览确认，再 `--apply`。

## License

[MIT](LICENSE)

---

# workbuddy-sweep (English)

🧹 A safe cleanup script for junk files (cache / logs / traces) that [WorkBuddy](https://workbuddy.cn) accumulates under `~/.workbuddy`. It scans, lists what can be removed with the estimated space to reclaim, and only deletes when you pass `--apply`.

## Features

- Dry-run preview: list every deletable file/dir with its size and the total estimated reclaimable space
- Apply mode: actually delete and report total freed space + remaining usage
- Never touches today's live logs (avoids breaking the running process)
- Idempotent: safe to re-run; only handles current leftovers
- Zero dependencies: bash + stock macOS `du` / `stat`

## What it deletes (6 categories)

1. `logs/` date directories older than today (e.g. `2026-08-10` … `2026-09-08`)
2. `logs/*.old.log` rotated logs
3. Stale low-traffic logs in `logs/` (`connector-oauth-debug.log`, `file-domain-service.log`, `debug.log`, `legacy-autolaunch-cleaner.log`, `.DS_Store`)
4. `traces/` session directories older than today (OpenTelemetry diagnostics, debug-only)
5. Cache/redundant dirs: `skills-marketplace`, `connectors-marketplace`, `cache`, `file-tree-manifests`, `shell-snapshots`, `clipboard-images`, `blobs`, `file-history`, `changes-detail`
6. `backup-memory-YYYYMMDD` outdated memory backups

## What it never deletes

- Today's live logs (`daemon.log`, `main.log`, `renderer.log`, `AppStartup.log`, `mcp-apps-diag.log`) and today's `logs/` date dir
- `binaries/` managed runtime (Python + Node, required by all tools)
- `plugins/`, `workspace/`, `projects/`, `security/`, `credentials/`, `memory/`, `skills/`, `app/` and other runtime/data dirs

## Install

```bash
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/workbuddy-sweep.sh
chmod +x workbuddy-sweep.sh
```

## Usage

```bash
./workbuddy-sweep.sh          # preview: list deletable items + estimated space (no deletion)
./workbuddy-sweep.sh --apply  # delete and report total freed space
```

## Notes

- macOS only for now (uses BSD `stat -f`). On Linux, replace `stat -f '%Sm' -t '%Y-%m-%d'` with GNU `stat -c '%y'` accordingly.
- Deleting `blobs/` and `file-history/` drops version/edit history but **does not affect current files**.

## License

[MIT](LICENSE)
