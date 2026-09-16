# workbuddy-sweep

[简体中文](README.md) | **English**

🧹 A safe cleanup script for the junk files (cache / logs / traces) that [WorkBuddy](https://workbuddy.cn) accumulates under `~/.workbuddy`.

It scans first and lists every removable item with the **estimated space to reclaim**. By default it only previews and **deletes nothing** — pass `--apply` to actually clean up.

> Safety boundary: it only removes "cache / history / finished-session" data. Runtime, installed plugins, project data, credentials and memory are never touched. See [What it never deletes](#what-it-never-deletes).

## Features

- **Preview mode** — lists each item's size, cumulative reclaimable space, and total usage before cleanup
- **Apply mode** — performs the deletion and reports freed space and usage afterwards
- **PID-aware sandbox log collection** — `logs/sandbox/` is checked per sandbox session; sessions whose PID is still alive are always skipped (with a 5-minute write cooldown as a backstop)
- **Idle-based trace reclamation** — no longer tied to "today vs. yesterday"; anything idle past the threshold is collected
- **Idempotent** — repeated runs only handle whatever residue exists at that moment
- **Zero dependencies** — bash + the stock `du` / `stat` / `ps`

## What it deletes (9 categories + 1 optional)

| # | Category | Rule | Measured |
|---|---|---|---|
| 1 | `logs/` dated dirs | older than today | 3.4M |
| 2 | `logs/*.old.log` | rotated logs | 5.0M |
| 3 | stale `logs/` files | `connector-oauth-debug.log` etc. | — |
| 4 | **`logs/sandbox/` session logs** | **PID gone** and idle ≥5 min; whole dirs dated before today | **420M** |
| 5 | `traces/*` | idle ≥ 60 min (`TRACE_MAX_AGE_MIN`) | 45M |
| 6 | cache / redundant dirs | `skills-marketplace` `connectors-marketplace` `cache` `file-tree-manifests` `shell-snapshots` `clipboard-images` `blobs` `file-history` `changes-detail` | 62M |
| 7 | **`app/session/` Electron caches** | `Cache` `Code Cache` `GPUCache` `DawnWebGPUCache` `DawnGraphiteCache` `Shared Dictionary` | 57M |
| 8 | `backup-memory-YYYYMMDD` | outdated memory backups | — |
| 9 | stray `.DS_Store` | within 3 levels of WB_HOME | 408K |
| ⚡ | `plugins/marketplaces/` | only with `--aggressive`; auto re-pulled on next launch | 146M |

> Figures measured on the author's machine on 2026-09-16. Category 4 fluctuates with sandbox usage and is usually the biggest chunk.

## What it never deletes

- **Live sandbox sessions** — any `sandbox_<pid>_*` whose PID still exists in the process table is skipped
- Active logs being written — `daemon.log`, `main.log`, `renderer.log`, `mcp-apps-diag.log`, `file-service.log`, `AppStartup.log`, and today's dated dir under `logs/`
- `binaries/` managed runtime (Python + Node, which every tool depends on)
- `plugins/cache/` installed plugins and `plugins/installed_plugins.json`
- `app/session/` state dirs — `WebStorage`, `IndexedDB`, `Local Storage`, `Session Storage`, `Partitions` (they hold your login state)
- `projects/`, `security/`, `credentials/`, `memory/`, `skills/`, `workspace/`, `storage/`, `local_storage/`, `audit-log/`

## Install

```bash
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/workbuddy-sweep.sh
chmod +x workbuddy-sweep.sh
```

Or just clone this repository.

## Usage

```bash
./workbuddy-sweep.sh              # preview: list removable items + estimated space (deletes nothing)
./workbuddy-sweep.sh --apply      # perform the deletion
./workbuddy-sweep.sh --aggressive # preview including plugins/marketplaces (~146M)
./workbuddy-sweep.sh --apply --aggressive
```

Environment overrides:

| Variable | Default | Description |
|---|---|---|
| `WB_HOME` | `~/.workbuddy` | Target directory (handy for dry runs on a copy) |
| `TRACE_MAX_AGE_MIN` | `60` | Minutes of idleness before a `traces/` dir is reclaimed |
| `SANDBOX_COOLDOWN_MIN` | `5` | Minutes without writes before a sandbox session counts as finished |

Sample preview output (the script's own output is Chinese):

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

## Notes

- **macOS only** (BSD `stat -f`). On Linux, switch `stat -f '%m'` / `stat -f '%Sm' -t ...` to GNU `stat -c '%Y'` / `stat -c '%y'`.
- Sandbox liveness prefers `ps -p` and automatically falls back to `kill -0` in restricted (sandboxed) environments.
- Deleting `blobs/` and `file-history/` drops version/edit history but **does not affect current files**.
- `--aggressive` empties the plugin marketplace listing until it is re-pulled on the next launch.
- Run the preview first, confirm, then `--apply`.
- ⚠️ **Inside the script, always write `${var}` — never a bare `$var`.** Under a UTF-8 locale bash swallows a following multibyte character (such as the fullwidth `（`) into the variable name; under the `C` locale it does not. The very same script then dies with `unbound variable` in your terminal while running fine elsewhere — extremely hard to pin down. Covered by the test suite.

## Testing

```bash
bash tests/run-tests.sh
```

Builds an isolated fixture under `/tmp` and runs the real script under both the **`C`** and **`en_US.UTF-8`** locales, asserting 8 properties: exit code, no `unbound variable`, finished sessions removed, **live-PID sessions preserved**, historical sandbox dirs removed, idle traces reclaimed, stray `.DS_Store` removed. Run it after every script change.

## License

[MIT](LICENSE)
