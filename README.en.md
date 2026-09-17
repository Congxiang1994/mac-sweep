<h1 align="center">🧹 workbuddy-sweep</h1>

<p align="center">
  <strong>Subtract from <code>~/.workbuddy</code> and <code>~/Library</code></strong><br>
  Scan → preview → confirm → clean. Nothing is deleted by default.
</p>

<p align="center">
  <a href="https://github.com/Congxiang1994/workbuddy-sweep"><img src="https://img.shields.io/badge/platform-macOS-000000?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="platform"></a>
  <a href="https://github.com/Congxiang1994/workbuddy-sweep"><img src="https://img.shields.io/badge/shell-bash%203.2%2B-4EAA25?style=flat-square&amp;logo=gnubash&amp;logoColor=white" alt="shell"></a>
  <a href="https://github.com/Congxiang1994/workbuddy-sweep"><img src="https://img.shields.io/badge/dependencies-0-2EA44F?style=flat-square" alt="dependencies"></a>
  <a href="https://github.com/Congxiang1994/workbuddy-sweep/tree/main/tests"><img src="https://img.shields.io/badge/tests-120%20passed-2EA44F?style=flat-square" alt="tests"></a>
  <a href="https://github.com/Congxiang1994/workbuddy-sweep"><img src="https://img.shields.io/badge/reclaim-~640MB-1D9E75?style=flat-square" alt="reclaim"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-378ADD?style=flat-square" alt="license"></a>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

---

Two scripts, two different kinds of junk:

| Script | What it looks at | When it actually acts |
|---|---|---|
| **`workbuddy-sweep.sh`** | logs, caches and finished sandbox sessions under `~/.workbuddy` | preview only by default; `--apply` to delete |
| **`uninstall-residue.sh`** | data left behind in `~/Library` by apps you uninstalled | report only by default; `--clean <scope>` then type `yes` |

---

[WorkBuddy](https://workbuddy.cn) writes logs, sandbox sessions, traces and caches into `~/.workbuddy` every day. Give it a few weeks and it grows from a few hundred megabytes to several gigabytes.

`workbuddy-sweep` takes that space back. It only touches three kinds of data — **cache, history, and finished sessions**. Runtime, installed plugins, project data, credentials and memory are never touched.

```diff
  ~/.workbuddy   1.9G
-    ├─ logs/sandbox/            420M   finished sandbox session logs
-    ├─ plugins/marketplaces/    146M   unzipped marketplace manifests
-    ├─ app/session/Cache/        57M   Electron renderer cache
-    └─ traces/                   45M   debug telemetry
+ ~/.workbuddy   1.3G   ← after a default cleanup
```

## Where the space goes

Measured breakdown of the default cleanup list (author's machine, 2026-09-16):

```
logs/sandbox/     ██████████████████████████████   420.0M   finished sessions
cache dirs        ████                              62.0M   redundant dirs
app/session/      ████                              57.0M   Electron caches
traces/           ███                               45.0M   idle telemetry
logs/             ▌                                  8.4M   rotated logs
.DS_Store         ▏                                  0.4M   stray markers
──────────────────────────────────────────────────────────────
                                    total ≈ 588.8M (84 items)
plugins/marketplaces/  ██████████                  146.0M   ⚡ --aggressive
```

> [!NOTE]
> `logs/sandbox/` usually dominates. Those files are written **today**, so traditional "delete logs older than today" rules never catch a single one — which is the whole reason this script exists.

## Decision logic

```mermaid
flowchart TD
    A(["Scan ~/.workbuddy"]) --> B{"Matches a cleanup rule?"}
    B -- "no" --> KEEP(["Leave alone"])
    B -- "yes" --> C{"Sandbox session log?"}
    C -- "no" --> DEL(["Add to delete list"])
    C -- "yes" --> D{"PID still in process table?"}
    D -- "yes" --> LIVE(["Skip · session alive"])
    D -- "no" --> E{"Written within 5 minutes?"}
    E -- "yes" --> LIVE
    E -- "no" --> DEL
```

Two gates plus a cooldown: **if the process is alive, nothing is touched**. Neither is anything just written. Everything else goes on the list.

## What it deletes

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
| 9 | stray `.DS_Store` | within 3 levels of `WB_HOME` | 408K |
| ⚡ | `plugins/marketplaces/` | only with `--aggressive`; auto re-pulled on next launch | 146M |

## What it never deletes

- **Live sandbox sessions** — any `sandbox_<pid>_*` whose PID still exists in the process table is skipped
- **Active logs being written** — `daemon.log`, `main.log`, `renderer.log`, `mcp-apps-diag.log`, `file-service.log`, `AppStartup.log`, plus today's dated dir under `logs/`
- **`binaries/`** — the managed Python + Node runtime that every tool depends on
- **`plugins/cache/`** — where installed plugins actually live (`installed_plugins.json` points its `installPath` here)
- **Login state** — `WebStorage`, `IndexedDB`, `Local Storage`, `Session Storage`, `Partitions` under `app/session/`
- **Your data** — `projects/`, `security/`, `credentials/`, `memory/`, `skills/`, `workspace/`, `storage/`, `local_storage/`, `audit-log/`

## Install

```bash
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/workbuddy-sweep.sh
curl -O https://raw.githubusercontent.com/Congxiang1994/workbuddy-sweep/main/uninstall-residue.sh
chmod +x workbuddy-sweep.sh uninstall-residue.sh
```

Or just clone this repository.

## Usage

```bash
./workbuddy-sweep.sh                        # preview: list removable items + estimated space
./workbuddy-sweep.sh --apply                # perform the deletion
./workbuddy-sweep.sh --aggressive           # preview including plugins/marketplaces
./workbuddy-sweep.sh --apply --aggressive   # clean it all in one go
```

> [!TIP]
> Run the preview without flags first, confirm the list looks right, then pass `--apply`. To rehearse on a throwaway copy, use `WB_HOME=/tmp/fake bash workbuddy-sweep.sh --apply`.

<details>
<summary><b>Environment overrides</b></summary>

<br>

| Variable | Default | Description |
|---|---|---|
| `WB_HOME` | `~/.workbuddy` | Target directory — handy for dry runs on a copy |
| `TRACE_MAX_AGE_MIN` | `60` | Minutes of idleness before a `traces/` dir is reclaimed |
| `SANDBOX_COOLDOWN_MIN` | `5` | Minutes without writes before a sandbox session counts as finished |

</details>

<details>
<summary><b>Sample output</b></summary>

<br>

The preview phase:

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

After `--apply`, the tail reports the actual freed space and the resulting usage:

```
================ 开始删除 ================
  [DEL] logs/sandbox/20260916  pid=6721（14 个文件）
  [DEL] traces/5550/
==========================================
成功 84 项，失败 0 项
实际释放空间: 588.8M（预计 588.8M）
清理后占用: 1.3G
```

*(The script's own output is Chinese.)*

</details>

## Design notes

<details>
<summary><b>Why sandbox logs are gated on PID liveness</b></summary>

<br>

Files under `logs/sandbox/` are named `sandbox_[center_]<pid>_{NNN.log,mmap3}`. If the PID is still in the process table the session hasn't ended, and its `.mmap3` is a memory-mapped file being written to right now — deleting it would break the session.

The liveness chain: `ps -p <pid>` first, falling back to `kill -0 <pid>` in restricted environments (inside an agent sandbox, `ps` fails outright with `operation not permitted`). When neither is conclusive, the `SANDBOX_COOLDOWN_MIN` cooldown is the backstop — anything written recently is skipped.

</details>

<details>
<summary><b>Why there is not a single bare <code>$var</code> in the script</b></summary>

<br>

bash decides where a variable name ends using **the locale-dependent `isalnum()`**. Under a UTF-8 locale, a multibyte character immediately following `$var` (such as the fullwidth `（`) gets swallowed into the variable name:

```bash
printf 'set -u\npidlabel="OK"\necho "值=$pidlabel（测试）"\n' > /tmp/t.sh
LC_ALL=C           /bin/bash /tmp/t.sh   # 值=OK（测试）                  exit 0
LC_ALL=en_US.UTF-8 /bin/bash /tmp/t.sh   # pidlabel: unbound variable     exit 1
```

The same script dies in your terminal and runs fine elsewhere — a nightmare to pin down. So this project uses `${var}` throughout, and the test suite covers it.

</details>

<details>
<summary><b>Why <code>plugins/cache</code> is sacred but <code>plugins/marketplaces</code> is fair game</b></summary>

<br>

- `plugins/cache/` (81M) is **where installed plugins actually live** — `installed_plugins.json` points its `installPath` straight at it. Delete it and your plugins are gone.
- `plugins/marketplaces/` (146M) is the unzipped marketplace manifest, has no `.git`, and is `autoUpdate: true`, so it is re-pulled the next time you open the marketplace. The only cost is an briefly empty listing — which is why it sits behind the `--aggressive` flag instead of the default list.

</details>

## The other half: `uninstall-residue.sh`

Uninstalling an app just drags a `.app` to the Trash — none of the data it accumulated under `~/Library` goes with it. A few months later you're staring at a pile of unfamiliar names in `Application Support`.

This script digs them out. **It only reports; it deletes nothing.** Findings are grouped by software, with every path and its size — you decide what stays.

Real output from the author's machine (2026-09-17):

```
[09] Docker Desktop
     待确认 · 合计 320K · 最近改动 2026-06-11
           232K  ~/Library/Application Support/Docker Desktop
             4K  ~/Library/Preferences/com.electron.dockerdesktop.plist
            84K  ~/Library/Group Containers/group.com.docker

[11] com.tencent.bugly
     基本确定 · 合计 36K · 最近改动 2026-09-17
             4K  ~/Library/Application Support/com.tencent.bugly
             4K  ~/Library/Preferences/com.tencent.tds.bugly.plist
             …

------------------------------------------------------
共 24 项（基本确定 19 / 待确认 5），合计 154.8M
```

> The footer counts **software entries** (traces of one app count as one), while the "hit 41" line counts **paths** — the two numbers are meant to differ.

### How it decides "uninstalled"

macOS offers no API for "is the owner of this directory still around?", so the script fingerprints instead:

1. **Collect what is actually installed** — walk `/Applications`, `/System/Applications`, `Utilities`, `~/Applications` and the input-method directories, reading each app's bundle id, name and bundle-id org segment via `PlistBuddy`;
2. **Walk the `~/Library` locations where residue piles up**;
3. Anything whose name is a standard bundle id — or looks like a software name — with no match in that fingerprint set is flagged as suspected residue.

### Scan coverage

The scan draws a progress bar (0 → 100%, with the directory it is currently walking) on `stderr`, so the report on `stdout` can still be redirected to a file.

| Location | Contents |
|---|---|
| `Application Support` | the big one; most app data lives here |
| `Caches` / `WebKit` / `HTTPStorages` | caches and WebKit storage |
| `Preferences` | `*.plist` preferences |
| `Containers` / `Group Containers` | sandbox containers (the 10-char team-id prefix is stripped) |
| `Logs` / `Saved Application State` | logs and window state |
| `LaunchAgents` / `Cookies` / `Application Scripts` / `Services` | odds and ends |

`--system` additionally scans `/Library` (read-only; cleaning there needs sudo).

### The three labels

| Label | Meaning |
|---|---|
| **基本确定** (certain) | the name is a standard software identifier (`com.xxx.yyy`), and no such software is installed |
| **待确认** (check it) | just a plain folder name (e.g. `Docker Desktop`), with no software of that name installed |
| **归属不明** (unattributed) | can't be attributed to any software — likely a system or dev-tool directory; hidden unless you pass `--all` |

### Usage

```bash
./uninstall-residue.sh                 # scan + report (deletes nothing)
./uninstall-residue.sh sogou           # only items whose name or path contains sogou
./uninstall-residue.sh --only 3        # only item #3 from the report
./uninstall-residue.sh --all           # include "unattributed" entries
./uninstall-residue.sh --min-age 180   # only items untouched for 180+ days
./uninstall-residue.sh --system        # also scan /Library
./uninstall-residue.sh --clean sogou   # list what will go → type yes → clean those groups
./uninstall-residue.sh --clean --all   # list everything → type yes → clean it all
./uninstall-residue.sh --clean 3 --yes # skip the confirmation, clean item #3
```

### Cleaning only part of it

Most of the time you want a few entries gone, not the whole list — put a **name** or a **report number** after `--clean`:

```bash
./uninstall-residue.sh --clean sogou     # group name or any path contains sogou
./uninstall-residue.sh --clean 3         # item #3 in the report
./uninstall-residue.sh --clean --only 3 --only 7
```

Filters are **case-insensitive substring** matches against the group name or any full path inside the group, and you can pass several.

> [!IMPORTANT]
> Numbers are assigned **after sorting but before filtering**: dropping other entries never renumbers anything. So you can read the full report, pick a number, then re-run with a filter — `--only 3` means the same entry in every combination, and no change of arguments can make it delete the wrong thing.

### Three gates — there is no "wipe it all" one-liner

**① The scope must be spelled out.** A bare `--clean` refuses to run (exit code 2):

```
⚠️  没有指定范围，本次不会动任何文件。
    只清几项：    bash uninstall-residue.sh --clean <名字 或 编号>
    全部都要清：  bash uninstall-residue.sh --clean --all
```

**② The list comes first.** Before confirming, every path about to be trashed is printed with its size, followed by a total:

```
================ 即将移入废纸篓 ================

[01] GhostApp  ·  40K  ·  待确认
            32K  ~/Library/Application Support/GhostApp
             8K  ~/Library/Logs/GhostApp.log

[02] com.ghost.software  ·  12K  ·  基本确定
            12K  ~/Library/Caches/com.ghost.software

合计 2 组 / 3 处 / 52K
```

**③ You must type `yes`.** Enter, `y`, or anything else cancels — not a single file is touched:

```
  yes  = 确认，全部移入废纸篓
  pick = 逐组挑选
  其它 = 取消（什么都不做）
```

`--yes` skips this gate, but it **requires a filter** (`--all` does not count), so `--clean --all --yes` — the "wipe everything in one command" case — is deliberately blocked (exit code 2).

### Cleaning moves to Trash, never `rm`

Confirmed items are `mv`'d into `~/.Trash` — **drag them back to restore**. At most 20 groups per run (`MAX_DELETE_PER_RUN` is overridable).

In `pick` mode you answer per group: `y` to move the whole group, `n` to skip, `s` to pick entries one by one, `q` to quit.

> [!NOTE]
> Entries labelled **归属不明** (unattributed) are **never** touched, even with `--all`. The script can't tell who owns them, so it doesn't decide for you.

### Whitelist

System directories and resident updaters are never reported: `com.apple.*`, `com.google.*`, `com.microsoft.autoupdate*`, plus shared dirs like `AddressBook`, `CloudDocs`, `MobileSync`, `Knowledge`. The lists live at the top of the script as `IGNORE_ID_PREFIXES` / `IGNORE_NAMES` — edit them to taste.

> [!NOTE]
> Detection is inherently approximate: the same directory can be "residue of an uninstalled app" or "cache of a tool you still use". So this script **hands you paths and evidence, not verdicts** — every entry carries its size and last-modified date, which is usually enough to decide at a glance.

## Testing

```bash
bash tests/run-tests.sh                      # workbuddy-sweep.sh      16 assertions
bash tests/run-tests-uninstall-residue.sh    # uninstall-residue.sh   104 assertions
```

Both build an isolated fixture under `/tmp` and run the real scripts under **both the `C` and `en_US.UTF-8` locales**.

**`workbuddy-sweep.sh`** (8 × 2 locales):

- Exit code 0, no `unbound variable`
- Finished sessions removed, **live-PID sessions preserved**
- Historical sandbox dirs removed, idle traces reclaimed, stray `.DS_Store` removed

**`uninstall-residue.sh`** (52 × 2 locales, fully isolated `HOME` — the real `~/Library` is never touched):

- Residue of uninstalled apps is reported, and traces scattered across locations are grouped into one entry
- Data belonging to installed apps (app name / bundle id / helper sub-id) is **not** falsely reported
- The whitelist holds, and **team-id stripping stays inside Group Containers**
- The progress bar goes to `stderr`, reaches 100%, and **never pollutes `stdout`**
- Filters list and touch only matching groups
- **Bare `--clean` is refused**, **`--clean --all --yes` is refused**, `--yes` without a filter is refused
- Two-step confirmation: list first → Enter cancels and touches nothing → only `yes` proceeds
- In `pick` mode, groups answered `y` move, groups answered `n` stay
- Cleaning by report number stays aligned with the unfiltered report
- Default mode deletes nothing; after `--clean` the original path is gone and the Trash entry exists

## Notes

> [!WARNING]
> Deleting `blobs/` and `file-history/` drops file version / edit history (**current files are unaffected**). Everything else is rebuilt automatically by WorkBuddy, invisibly.

- **macOS only** (relies on BSD `stat -f`, `PlistBuddy`, `du -sk`). On Linux, switch `stat -f '%m'` / `stat -f '%Sm' -t ...` to GNU `stat -c '%Y'` / `stat -c '%y'` — and `PlistBuddy` has no counterpart.
- Repeated runs are idempotent — each run only handles whatever residue exists at that moment.
- Zero dependencies: only bash and the stock `du` / `stat` / `ps` / `PlistBuddy`.
- Neither script touches the network, calls sudo, or changes any system setting.
- `uninstall-residue.sh` writes its report to the current directory (`uninstall-residue-<timestamp>.tsv`); override with `--report <path>` or by editing the `REPORT_FILE` default.

## License

[MIT](LICENSE)
