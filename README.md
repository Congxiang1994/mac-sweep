# workbuddy-sweep

🧹 清理 [WorkBuddy](https://workbuddy.cn) 在 `~/.workbuddy` 下产生的缓存、日志、追踪等垃圾文件的安全脚本。

扫描后会列出可删除项与**预计释放空间**；默认只预览、**不删除**，加 `--apply` 才真正清理。

> 安全边界：只删「缓存 / 历史 / 已结束会话」类数据，绝不碰运行时、已装插件、项目数据、凭据与记忆。详见「不会删除什么」。

## 特性

- **预览模式**：列出每一项的大小、累计可释放空间、清理前总占用
- **删除模式**：执行删除并报告腾出空间与清理后占用
- **按进程存活判定沙箱日志**：`logs/sandbox/` 逐沙箱会话检查 PID 是否还在，活着的会话一律跳过（含 5 分钟写入冷却兜底）
- **按闲置时间回收 traces**：不再受「今天/昨天」限制，闲置超阈值即回收
- **幂等**：多次运行只处理当下残留
- **零依赖**：bash + 系统自带 `du` / `stat` / `ps`

## 会删除什么（9 类 + 1 个可选）

| # | 类别 | 规则 | 实测收益 |
|---|---|---|---|
| 1 | `logs/` 历史日期目录 | 早于今天 | 3.4M |
| 2 | `logs/*.old.log` | 轮转旧日志 | 5.0M |
| 3 | `logs/` 过期零碎日志 | `connector-oauth-debug.log` 等 | — |
| 4 | **`logs/sandbox/` 沙箱会话日志** | **PID 已不存在** 且 ≥5 分钟无写入；非今天的日期目录整体删 | **420M** |
| 5 | `traces/*` 追踪目录 | 闲置 ≥ 60 分钟（`TRACE_MAX_AGE_MIN`） | 45M |
| 6 | 缓存/冗余目录 | `skills-marketplace` `connectors-marketplace` `cache` `file-tree-manifests` `shell-snapshots` `clipboard-images` `blobs` `file-history` `changes-detail` | 62M |
| 7 | **`app/session/` Electron 纯缓存** | `Cache` `Code Cache` `GPUCache` `DawnWebGPUCache` `DawnGraphiteCache` `Shared Dictionary` | 57M |
| 8 | `backup-memory-YYYYMMDD` | 过期记忆备份 | — |
| 9 | 散落 `.DS_Store` | WB_HOME 下 3 层内 | 408K |
| ⚡ | `plugins/marketplaces/` | 仅 `--aggressive`，下次打开自动重拉 | 146M |

> 收益为 2026-09-16 在作者本机的实测值。第 4 类随沙箱使用强度波动，通常是最大头。

## 不会删除什么

- **活着的沙箱会话**：`sandbox_<pid>_*` 中 PID 仍存在于进程表的一律跳过
- 正在写入的活跃日志：`daemon.log`、`main.log`、`renderer.log`、`mcp-apps-diag.log`、`file-service.log`、`AppStartup.log` 及 `logs/` 中今天的日期目录
- `binaries/` 托管运行时（Python + Node，所有工具依赖）
- `plugins/cache/` 已安装插件、`plugins/installed_plugins.json`
- `app/session/` 中 `WebStorage`、`IndexedDB`、`Local Storage`、`Session Storage`、`Partitions`（含登录态）
- `projects/`、`security/`、`credentials/`、`memory/`、`skills/`、`workspace/`、`storage/`、`local_storage/`、`audit-log/`

## 安装

```bash
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/workbuddy-sweep.sh
chmod +x workbuddy-sweep.sh
```

或直接克隆本仓库。

## 使用

```bash
./workbuddy-sweep.sh              # 预览：列出可删项 + 预计释放空间（不删）
./workbuddy-sweep.sh --apply      # 执行删除
./workbuddy-sweep.sh --aggressive # 预览时额外纳入 plugins/marketplaces（146M 级）
./workbuddy-sweep.sh --apply --aggressive
```

可调环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WB_HOME` | `~/.workbuddy` | 目标目录（便于在副本上试跑） |
| `TRACE_MAX_AGE_MIN` | `60` | `traces/` 闲置多少分钟即回收 |
| `SANDBOX_COOLDOWN_MIN` | `5` | 沙箱会话多少分钟无写入才认定已结束 |

预览示例输出：

```
================ 扫描结果 ================

[logs/sandbox 已结束会话]
  128.7M   logs/sandbox/20260916  pid=6721（14 个文件）
  100.3M   logs/sandbox/20260916  pid=6445(center)（10 个文件）

[traces 闲置追踪]
  14.0M    traces/5550/（闲置 197 分钟）

[Electron 渲染缓存]
  53.6M    app/session/Cache
------------------------------------------
预计可释放空间: 588.8M（共 84 项）
清理前占用: 1.8G
```

## 注意事项

- 仅适配 **macOS**（BSD `stat -f`）。Linux 需把 `stat -f '%m'` / `stat -f '%Sm' -t ...` 改为 GNU `stat -c '%Y'` / `stat -c '%y'`。
- 沙箱存活判定优先用 `ps -p`，在受限（沙箱内）环境会自动回退到 `kill -0`。
- 删除 `blobs/`、`file-history/` 会丢失版本/编辑历史，但**不影响当前文件**。
- `--aggressive` 删除 `plugins/marketplaces/` 后，插件市场列表会短暂为空，下次打开自动重拉。
- 建议先跑预览确认，再 `--apply`。
- ⚠️ **脚本内变量一律写 `${var}`，不要写裸 `$var`。** bash 在 UTF-8 locale 下会把 `$var` 后面紧跟的多字节字符（如全角「（」）吞进变量名，在 `C` locale 下却不会 —— 同一份脚本在你的终端报 `unbound variable`、在别处却正常，极难定位。已有测试覆盖此场景。

## 回归测试

```bash
bash tests/run-tests.sh
```

在 `/tmp` 下建隔离目录跑真实脚本，分别在 **`C` locale** 与 **`en_US.UTF-8` locale** 下断言 8 项：退出码、无 `unbound variable`、已结束会话被删、**存活 PID 会话被保留**、历史沙箱目录被删、闲置 traces 被回收、散落 `.DS_Store` 被删。改动脚本后跑一次即可。

## License

[MIT](LICENSE)

---

# workbuddy-sweep (English)

🧹 A safe cleanup script for junk files (cache / logs / traces) that [WorkBuddy](https://workbuddy.cn) accumulates under `~/.workbuddy`. It scans, lists what can be removed with the estimated space to reclaim, and only deletes when you pass `--apply`.

## Features

- Dry-run preview listing every deletable item, total reclaimable space, and current usage
- Apply mode reporting freed space and remaining usage
- PID-aware sandbox log collection: `logs/sandbox/` is grouped per sandbox session and skipped while its PID is still alive (plus a 5-minute write cooldown)
- Idle-based trace reclamation instead of "today vs. yesterday"
- Idempotent and dependency-free (bash + stock `du` / `stat` / `ps`)

## What it deletes (9 categories + 1 optional)

| # | Category | Rule | Measured |
|---|---|---|---|
| 1 | `logs/` dated dirs | older than today | 3.4M |
| 2 | `logs/*.old.log` | rotated logs | 5.0M |
| 3 | stale `logs/` files | `connector-oauth-debug.log` etc. | — |
| 4 | **`logs/sandbox/` session logs** | **PID gone** and idle ≥5 min; whole dirs older than today | **420M** |
| 5 | `traces/*` | idle ≥ 60 min (`TRACE_MAX_AGE_MIN`) | 45M |
| 6 | cache/redundant dirs | see list above | 62M |
| 7 | **`app/session/` Electron caches** | `Cache`, `Code Cache`, `GPUCache`, Dawn variants, `Shared Dictionary` | 57M |
| 8 | `backup-memory-YYYYMMDD` | outdated memory backups | — |
| 9 | stray `.DS_Store` | within 3 levels of WB_HOME | 408K |
| ⚡ | `plugins/marketplaces/` | only with `--aggressive`, auto re-pulled | 146M |

## What it never deletes

- Live sandbox sessions (`sandbox_<pid>_*` whose PID still exists)
- Active logs (`daemon.log`, `main.log`, `renderer.log`, `mcp-apps-diag.log`, `file-service.log`, `AppStartup.log`) and today's `logs/` dated dir
- `binaries/` managed runtime, `plugins/cache/` installed plugins, `projects/`, `security/`, `credentials/`, `memory/`, `skills/`, `workspace/`, `storage/`, `local_storage/`, `audit-log/`
- `app/session/` state dirs: `WebStorage`, `IndexedDB`, `Local Storage`, `Session Storage`, `Partitions`

## Usage

```bash
./workbuddy-sweep.sh              # preview only
./workbuddy-sweep.sh --apply      # delete
./workbuddy-sweep.sh --aggressive # preview including plugins/marketplaces
```

Environment overrides: `WB_HOME`, `TRACE_MAX_AGE_MIN` (default 60), `SANDBOX_COOLDOWN_MIN` (default 5).

## Notes

- macOS only (BSD `stat -f`). On Linux, switch to GNU `stat -c`.
- Sandbox liveness uses `ps -p` with a `kill -0` fallback for restricted environments.
- Deleting `blobs/` and `file-history/` drops version/edit history but not current files.
- `--aggressive` empties the plugin marketplace listing until it is re-pulled on next launch.
- ⚠️ **Always write `${var}`, never a bare `$var`.** Under a UTF-8 locale bash swallows a following multibyte character (e.g. the fullwidth `（`) into the variable name; under the `C` locale it does not. The same script then fails with `unbound variable` in one terminal and runs fine in another — extremely hard to reproduce. Covered by the test suite.

## Testing

```bash
bash tests/run-tests.sh
```

Builds an isolated fixture under `/tmp` and runs the real script under both **`C`** and **`en_US.UTF-8`** locales, asserting 8 properties: exit code, no `unbound variable`, dead sessions removed, **live-PID sessions preserved**, historical sandbox dirs removed, idle traces reclaimed, stray `.DS_Store` removed.

## License

[MIT](LICENSE)
