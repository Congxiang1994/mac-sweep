<h1 align="center">🧹 mac-sweep</h1>

<p align="center">
  <strong>macOS 应用残留清理套件 —— 只清缓存与垃圾，不碰你的数据</strong><br>
  纯 Bash · 零依赖 · 只移废纸篓 · 每个目标都有测试兜底
</p>

<p align="center">
  <a href="https://github.com/Congxiang1994/mac-sweep"><img src="https://img.shields.io/badge/platform-macOS-000000?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="platform"></a>
  <a href="https://github.com/Congxiang1994/mac-sweep"><img src="https://img.shields.io/badge/shell-bash%203.2%2B-4EAA25?style=flat-square&amp;logo=gnubash&amp;logoColor=white" alt="shell"></a>
  <a href="https://github.com/Congxiang1994/mac-sweep"><img src="https://img.shields.io/badge/dependencies-0-2EA44F?style=flat-square" alt="dependencies"></a>
  <a href="https://github.com/Congxiang1994/mac-sweep/tree/main/tests"><img src="https://img.shields.io/badge/tests-910%20passed-2EA44F?style=flat-square" alt="tests"></a>
  <a href="https://github.com/Congxiang1994/mac-sweep"><img src="https://img.shields.io/badge/delete-只进废纸篓-1D9E75?style=flat-square" alt="trash only"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-378ADD?style=flat-square" alt="license"></a>
</p>

<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a>
</p>

---

## 这是什么

六支独立的清理脚本，各管一个应用，共用同一套交互模型与安全机制：

| 脚本 | 清什么 | 典型收益 |
|---|---|---|
| `workbuddy-sweep.sh` | WorkBuddy 的日志 / 缓存 / 已结束的沙箱会话 / 追踪残留 | 数百 MB ～ GB 级 |
| `chrome-sweep.sh` | Chrome 的缓存 / 组件升级包 / AI 模型缓存 / 崩溃报告 / 隐私痕迹 | 数百 MB ～ 数 GB |
| `cherry-studio-sweep.sh` | Cherry Studio 的渲染缓存 / 浏览缓存 / 追踪残留 / 历史日志 | 数百 MB |
| `wps-sweep.sh` | WPS 的 CEF 内核缓存 / 插件升级包 / 云服务日志 / 崩溃备份 | 数百 MB ～ 数 GB |
| `vscode-sweep.sh` | VS Code 的渲染缓存 / 字节码缓存 / webview 缓存 / 会话日志 / 孤立工作区状态 | 一百 MB ～ 数百 MB |
| `uninstall-residue.sh` | 已卸载软件留在 `Application Support` / `Containers` / `Caches` 里的孤儿数据 | 视卸载历史而定 |

这些目标之外的数据 —— 配置、账号、文档、记忆、数据库 —— **扫描规则根本不会生成**，不是「生成后再判断」。

## 快速上手

```bash
git clone https://github.com/Congxiang1994/mac-sweep.git
cd mac-sweep

bash workbuddy-sweep.sh          # 扫描 → 列清单 → 你选 → 移入废纸篓
```

不放心？先只看不动：

```bash
bash chrome-sweep.sh --scan      # 只出报告，零交互，不改任何文件
```

### 清单怎么选

扫完出现带编号的清单（含每项大小与路径），交互语法全系列一致：

| 输入 | 效果 |
|---|---|
| `yes` / `all` | 全部移入废纸篓 |
| `1 3 5` · `1-4` · `1,3` | 只处理这些编号（每轮重新编号） |
| `pick` | 逐项 y/n 确认 |
| `q` / 回车 | 结束，未处理的项原样不动 |

清完一轮还有剩余会继续问，直到你说结束。

### 筛选与命令行

```bash
bash wps-sweep.sh cef log          # 只列名字/路径含 cef 或 log 的项（并集）
bash wps-sweep.sh cache --and 1000 # 交集：同时含两词才算
bash wps-sweep.sh --only cef,log   # 逗号连写，等价空格分隔
bash wps-sweep.sh --clean cef --yes   # 免交互清理（必须带筛选条件）
bash cherry-studio-sweep.sh --aggressive  # 额外纳入有轻微代价的项
bash vscode-sweep.sh log crash     # 多个关键词 = 并集
bash vscode-sweep.sh --clean 会话日志 --yes   # 只清会话日志，免交互
```

## 基本原理

**扫描 → 清单 → 你选 → 废纸篓**。没有守护进程、没有配置文件，每支脚本就是一份写死的「哪里的什么东西可以安全重生成」清单。

三道安全闸，层层独立：

1. **范围闸** —— `--clean` 必须指定范围；`--yes` 必须配合筛选条件，「一句话全清空」被刻意堵死
2. **保护名单硬防线** —— 与扫描规则独立的第二道闸：任何路径 basename 命中保护名单（`Cookies`、`Preferences`、`backup`、`OfficeSpace`、`state.vscdb`、`session-store.db`…）直接拒绝入清单，扫描规则将来写错也碰不到
3. **废纸篓而非 `rm`** —— 所有删除都是 `mv` 到 `~/.Trash`，后悔了拖回来即可

其余设计细节：

- **零依赖**：只依赖 macOS 自带 bash 3.2 与 coreutils
- **双 locale 验证**：所有脚本在 `LC_ALL=C` 与 UTF-8 下行为一致（变量引用全部 `${var}`，规避 UTF-8 变量名吞噬坑）
- **运行检测**：应用运行中会提示，清理缓存类通常安全，建议清完重启应用
- **蚊子腿也扫**：`.DS_Store`、`*.wal` journal、`LOG.old` 这类小文件也纳入，但 0 字节文件自动跳过

## 回归测试

```bash
bash tests/test-workbuddy-sweep.sh        # 174 项断言
bash tests/test-uninstall-residue.sh      # 188 项断言
bash tests/test-chrome-sweep.sh           # 134 项断言
bash tests/test-cherry-studio-sweep.sh    # 104 项断言
bash tests/test-wps-sweep.sh              # 126 项断言
bash tests/test-vscode-sweep.sh           # 184 项断言
```

共 **910 项断言，全部通过**。测试全程隔离：在 `/tmp` 构造假 `HOME` 与假应用目录，绝不触碰真实数据；每支脚本对「必须保留」的项（数据库、Cookies、备份、字体、凭据）逐一断言存活。

## License

MIT
