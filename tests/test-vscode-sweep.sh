#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# vscode-sweep.sh 回归测试
#
# 全程隔离：HOME 与 VSCODE_HOME 都指向 /tmp 下的假目录，绝不碰真实的 VS Code 数据。
# settings.json / state.vscdb / Copilot 聊天记录 / 本地历史 / 扩展本体 / 登录态
# 全部逐一断言存活；孤立工作区状态则验证三条判据（源目录消失 + 冷却期 + URI 解码）。
#
# 性能说明：造夹具一律用 /bin/mkdir 与 mkfile 这两个原生二进制，不用 mkdir/head/echo
# 这些可能被宿主 shell 代理的命令 —— 否则每建一个文件都要过一次进程代理，
# 整个套件的测试会慢到不可用。只读用例共享同一份夹具，只在真正会改动文件的
# 用例之前才重建。
#
# 用法: bash tests/test-vscode-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/vscode-sweep.sh"
[ -f "${SCRIPT}" ] || { echo "找不到脚本: ${SCRIPT}" >&2; exit 1; }

PASS=0
FAIL=0
FAILED_NAMES=""
CASE=""

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES}
    - [${CASE}] $1"; }

eq()   { [ "$1" = "$2" ] && ok || bad "$3（期望 ${2}，实得 ${1}）"; }
has()  { case "$1" in *"$2"*) ok ;; *) bad "$3（输出里没有「${2}」）" ;; esac; }
not_has() { case "$1" in *"$2"*) bad "$3（输出里不该出现「${2}」）" ;; *) ok ;; esac; }
gone() { [ ! -e "$1" ] && ok || bad "$2（仍存在: $1）"; }
keep() { [ -e "$1" ]   && ok || bad "$2（被误删: $1）"; }

nuke() {
  local p="$1"
  [ -e "${p}" ] || return 0
  env -u PYTHONPATH /usr/bin/python3 -c \
    'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "${p}" 2>/dev/null
  [ -e "${p}" ] && rm -rf "${p}"
  return 0
}

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vscode-sweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
VS="${FIX_HOME}/Library/Application Support/Code"
WS="${VS}/User/workspaceStorage"

# 原生二进制（不经宿主 shell 代理），快得多
MKDIR=/bin/mkdir
TOUCH=/usr/bin/touch

mk_file() {  # mk_file <文件> <KB>
  ${MKDIR} -p "$(dirname "$1")"
  mkfile "${2}k" "$1" 2>/dev/null
}
mk_dir() {  # mk_dir <目录> <KB>：造一个含 x.bin 的非空目录
  ${MKDIR} -p "$1"
  mkfile "${2}k" "$1/x.bin" 2>/dev/null
}
mk_big()    { mk_file "$1" "$2"; }
mk_bigdir() { mk_dir  "$1" "$2"; }

# 造一个工作区状态条目：mk_ws <目录名> <workspace.json 的键> <URI> <mtime 参数>
mk_ws() {
  local name="$1" key="$2" uri="$3" mt="$4"
  ${MKDIR} -p "${WS}/${name}"
  printf '{\n  "%s": "%s"\n}\n' "${key}" "${uri}" > "${WS}/${name}/workspace.json"
  mkfile 20k "${WS}/${name}/state.vscdb"
  mkfile 10k "${WS}/${name}/state.vscdb.backup"
  [ -n "${mt}" ] && ${TOUCH} -t "${mt}" "${WS}/${name}"
  return 0
}

reset_fixture() {
  nuke "${FIX_ROOT}"

  # ── 应该进清单的 ──
  mk_bigdir "${VS}/Cache" 300                              # 渲染缓存
  mk_bigdir "${VS}/GPUCache" 60
  mk_bigdir "${VS}/CachedData" 400                         # V8 字节码缓存
  mk_bigdir "${VS}/CachedExtensionVSIXs" 200               # 扩展 VSIX
  mk_bigdir "${VS}/Partitions/vscode-browser/Cache" 500    # 内置浏览器缓存（大头）
  mk_bigdir "${VS}/Partitions/vscode-browser/Code Cache" 100
  mk_bigdir "${VS}/WebStorage/10/CacheStorage" 300         # webview CacheStorage
  mk_bigdir "${VS}/clp/aaaa.zh-cn" 90                      # 语言包译文缓存
  mk_big    "${VS}/DIPS" 36                                # 隐私追踪
  mk_big    "${VS}/SharedStorage-wal" 10
  mk_big    "${VS}/crash-logs/workspaces/workspace_demo_abc/.processed-crashes.json" 4
  mk_big    "${VS}/Session Storage/LOG.old" 6              # 杂项
  mk_big    "${VS}/.DS_Store" 8
  mk_big    "${FIX_HOME}/Library/Caches/com.microsoft.VSCode/Cache.db" 48   # 系统级缓存
  mk_big    "${FIX_HOME}/Library/Caches/com.microsoft.VSCode.ShipIt/upd.bin" 8

  # 会话日志：最新一场 + 冷却期内的保留，其余按时间戳目录清理
  local now_stamp; now_stamp=$(date +%Y%m%dT%H%M%S)
  mk_bigdir "${VS}/logs/20200101T000000" 200; ${TOUCH} -t 202001010000 "${VS}/logs/20200101T000000"
  mk_bigdir "${VS}/logs/20200102T000000" 150; ${TOUCH} -t 202001020000 "${VS}/logs/20200102T000000"
  mk_bigdir "${VS}/logs/20200103T000000" 120                       # 冷却期内（mtime = 现在）
  mk_bigdir "${VS}/logs/${now_stamp}" 100                          # 最新一场，恒保留
  mk_bigdir "${VS}/logs/notatimestamp" 50                          # 非时间戳命名，不碰

  # 孤立工作区状态（--aggressive）
  mk_ws "orphanA" "folder"    "file://${FIX_ROOT}/gone-project"        "202001010000"
  mk_ws "liveB"   "folder"    "file://${FIX_ROOT}/live-project"        "202001010000"
  mk_ws "spaceC"  "folder"    "file://${FIX_ROOT}/live%20project"      "202001010000"
  mk_ws "freshD"  "folder"    "file://${FIX_ROOT}/gone-fresh"          ""
  mk_ws "wsKeyF"  "workspace" "file://${FIX_ROOT}/gone.code-workspace" "202001010000"
  ${MKDIR} -p "${WS}/nojE"; mkfile 5k "${WS}/nojE/state.vscdb"     # 无 workspace.json → 不碰

  # 上面两条 workspace.json 指向的真实目录
  ${MKDIR} -p "${FIX_ROOT}/live-project" "${FIX_ROOT}/live project"

  # ── 绝不能动的 ──
  mk_big    "${VS}/User/settings.json" 4
  mk_big    "${VS}/User/keybindings.json" 2
  mk_big    "${VS}/User/globalStorage/state.vscdb" 860
  mk_big    "${VS}/User/globalStorage/storage.json" 84
  mk_big    "${VS}/User/globalStorage/github.copilot-chat/session-store.db" 40
  mk_big    "${VS}/User/globalStorage/github.copilot-chat/settingEmbeddings.json" 13000
  mk_big    "${VS}/User/globalStorage/github.copilot-chat/commandEmbeddings.json" 12000
  mk_big    "${VS}/User/History/deadbeef/entries.json" 30
  mk_big    "${VS}/User/profiles/-profile1/state.vscdb" 12
  mk_big    "${VS}/User/sync/settings/lastSyncsettings.json" 9
  mk_big    "${VS}/agentSessionData/11111111-2222/session.db" 22
  mk_big    "${VS}/Partitions/vscode-browser/Cookies" 20
  mk_big    "${VS}/Partitions/vscode-browser/Local Storage/leveldb/x.ldb" 15
  mk_big    "${VS}/Partitions/vscode-browser/Session Storage/LOG" 8   # 只允许 aggressive 清
  mk_big    "${VS}/Crashpad/settings.dat" 1
  mk_big    "${VS}/Service Worker/CacheStorage/abc.bin" 30            # 只允许 aggressive 清
  mk_big    "${FIX_HOME}/Library/HTTPStorages/com.microsoft.VSCode/Cookies.binarycookies" 12
  mk_big    "${FIX_HOME}/.vscode/extensions/some.ext/package.json" 3
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" VSCODE_HOME="${VS}" LC_ALL="${LOCALE}" \
               /bin/bash "${SCRIPT}" "$@" 2>&1)"
  RUN_RC=$?
}

run_locale() {
  local locale_name="$1" label="$2"
  LOCALE="${locale_name}"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  # A. 交互默认（只读，共享一份夹具）-----------------------------------------
  reset_fixture
  CASE="交互默认"
  run_script ""
  eq "${RUN_RC}" "0" "默认模式退出码 0"
  has "${RUN_OUT}" "要清理哪些？" "默认模式给出选择提示"
  has "${RUN_OUT}" "结束，未处理的项原样不动" "回车 = 结束"
  keep "${VS}/Cache" "⭐ 默认模式不动 Cache"
  keep "${VS}/User/settings.json" "⭐ settings.json 始终不动"

  CASE="交互默认"
  run_script "q"
  keep "${VS}/Partitions/vscode-browser/Cache" "⭐ 输入 q 后文件仍然存在"

  CASE="交互默认"
  run_script "abc"
  has "${RUN_OUT}" "看不懂这个输入" "乱输入给出提示"
  keep "${VS}/Partitions/vscode-browser/Cache" "⭐ 乱输入后文件仍然存在"

  # B. 范围闸（全部不会改动文件，共享一份夹具）-----------------------------
  reset_fixture
  CASE="范围闸"
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${VS}/Cache" "裸 --clean 不删任何东西"

  CASE="范围闸"
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${VS}/Cache" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  CASE="只扫描"
  run_script "" --scan
  eq "${RUN_RC}" "0" "--scan 退出码 0"
  has "${RUN_OUT}" "只扫描模式（--scan）" "--scan 报告完直接结束"
  not_has "${RUN_OUT}" "要清理哪些？" "--scan 不进交互"
  keep "${VS}/Cache" "--scan 不动任何文件"
  has "${RUN_OUT}" "保护中" "报告显示保护中数据的规模"
  has "${RUN_OUT}" ".vscode/extensions 扩展本体" "报告交代扩展本体的规模"
  has "${RUN_OUT}" "globalStorage" "报告交代 globalStorage 口径"

  # C. 保护名单（只读断言，复用同一份夹具）---------------------------------
  CASE="保护名单"
  run_script "" --scan
  not_has "${RUN_OUT}" "settings.json" "⭐ settings.json 绝不进清单"
  not_has "${RUN_OUT}" "session-store.db" "⭐ Copilot 聊天记录绝不进清单"
  not_has "${RUN_OUT}" "Cookies" "⭐ Cookies 绝不进清单"
  not_has "${RUN_OUT}" "state.vscdb" "⭐ 状态库绝不进清单"
  not_has "${RUN_OUT}" "孤立工作区状态" "⭐ 非 aggressive 不列出孤立工作区"
  not_has "${RUN_OUT}" "Copilot 语义索引" "⭐ 非 aggressive 不列出 Copilot 索引"

  CASE="保护名单"
  run_script "" --aggressive --scan
  not_has "${RUN_OUT}" "settings.json" "⭐ aggressive 下 settings.json 仍不进清单"
  not_has "${RUN_OUT}" "entries.json" "⭐ aggressive 下本地历史仍不进清单"
  has "${RUN_OUT}" "孤立工作区状态 workspaceStorage（2 个" "只认出 2 个真孤立条目"

  # D. 筛选（前两条只读，第三条只清隐私）-----------------------------------
  CASE="筛选"
  run_script "" cache
  has "${RUN_OUT}" "Cache" "筛选命中 cache 项"
  not_has "${RUN_OUT}" "会话日志" "筛选未命中日志项"

  CASE="筛选"
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  run_script "" --clean cache --and web --yes
  has "${RUN_OUT}" "且" "交集模式在报告里显式打出「且」"
  keep "${VS}/Cache" "⭐ 交集未命中时不删（Cache 不含 web）"

  CASE="筛选"
  run_script "" --clean 隐私 --yes
  eq "${RUN_RC}" "0" "--clean 隐私 --yes 退出码 0"
  gone "${VS}/DIPS" "隐私追踪被清"
  gone "${VS}/SharedStorage-wal" "SharedStorage-wal 被清"
  keep "${VS}/Cache" "⭐ 未命中的 Cache 原样未动"
  keep "${VS}/Partitions/vscode-browser/Cookies" "⭐ Cookies 原样未动"

  # E. 交互整轮清理 ---------------------------------------------------------
  reset_fixture
  CASE="交互选择"
  run_script "yes"
  eq "${RUN_RC}" "0" "交互输入 yes 后退出码 0"
  gone "${VS}/Cache" "⭐ 渲染缓存被移走"
  gone "${VS}/Partitions/vscode-browser/Cache" "webview 浏览缓存被移走"
  gone "${VS}/CachedData" "CachedData 被移走"
  gone "${VS}/CachedExtensionVSIXs" "扩展 VSIX 缓存被移走"
  gone "${VS}/WebStorage/10/CacheStorage" "webview CacheStorage 被移走"
  gone "${VS}/DIPS" "隐私追踪被移走"
  gone "${VS}/clp/aaaa.zh-cn" "语言包译文缓存被移走"
  gone "${VS}/.DS_Store" "散落 .DS_Store 被移走"
  keep "${FIX_HOME}/.Trash/Cache" "Cache 出现在废纸篓（不是真删）"
  keep "${VS}/User/settings.json" "⭐ settings.json 原样未动"
  keep "${VS}/User/keybindings.json" "⭐ keybindings.json 原样未动"
  keep "${VS}/User/globalStorage/state.vscdb" "⭐ 全局状态库原样未动"
  keep "${VS}/User/globalStorage/storage.json" "⭐ storage.json 原样未动"
  keep "${VS}/User/globalStorage/github.copilot-chat/session-store.db" "⭐ Copilot 聊天记录原样未动"
  keep "${VS}/User/History/deadbeef/entries.json" "⭐ 本地编辑历史原样未动"
  keep "${VS}/User/profiles/-profile1/state.vscdb" "⭐ profiles 原样未动"
  keep "${VS}/agentSessionData/11111111-2222/session.db" "⭐ agent 会话库原样未动"
  keep "${VS}/Partitions/vscode-browser/Cookies" "⭐ Cookies 原样未动"
  keep "${VS}/Partitions/vscode-browser/Local Storage/leveldb/x.ldb" "⭐ Local Storage 原样未动"
  keep "${VS}/Crashpad/settings.dat" "⭐ Crashpad settings.dat 原样未动"
  keep "${FIX_HOME}/Library/HTTPStorages/com.microsoft.VSCode/Cookies.binarycookies" "⭐ 登录态原样未动"
  keep "${FIX_HOME}/.vscode/extensions/some.ext/package.json" "⭐ 扩展本体原样未动"
  keep "${WS}/liveB" "⭐ 源目录仍存在的工作区状态原样未动"
  keep "${VS}/User/globalStorage/github.copilot-chat/settingEmbeddings.json" "⭐ Copilot 索引非 aggressive 不动"
  keep "${VS}/logs/notatimestamp" "⭐ 非时间戳命名的日志目录恒不动"

  # F. 会话日志（同一份夹具连做两轮，第二轮应已无命中）---------------------
  reset_fixture
  CASE="会话日志"
  run_script "" --clean 会话日志 --yes
  eq "${RUN_RC}" "0" "--clean 会话日志 --yes 退出码 0"
  gone "${VS}/logs/20200101T000000" "⭐ 旧会话日志被清"
  gone "${VS}/logs/20200102T000000" "⭐ 次旧会话日志被清"
  keep "${VS}/logs/notatimestamp" "⭐ 非时间戳命名的目录不碰"

  CASE="会话日志"
  run_script "" --clean 会话日志 --yes
  local newest; newest=$(ls "${VS}/logs" | LC_ALL=C sort | tail -1)
  keep "${VS}/logs/${newest}" "⭐ 最新一场会话日志恒保留"
  keep "${VS}/logs/20200103T000000" "⭐ 冷却期内的会话日志保留"
  keep "${VS}/Cache" "⭐ 筛选外的项不动"

  # G. aggressive 四类目标 + 系统级缓存（一份夹具，顺序执行）---------------
  reset_fixture
  CASE="孤立工作区"
  run_script "" --aggressive --clean 孤立工作区 --yes
  eq "${RUN_RC}" "0" "--aggressive --clean 孤立工作区 --yes 退出码 0"
  gone "${WS}/orphanA" "⭐ 孤立工作区（folder 键）被清"
  gone "${WS}/wsKeyF" "⭐ 孤立工作区（workspace 键）被清"
  keep "${WS}/liveB" "⭐ 源目录存在 → 保留"
  keep "${WS}/spaceC" "⭐ URI 里的 %20 解码后源目录存在 → 保留"
  keep "${WS}/freshD" "⭐ 未过冷却期的孤立条目保留"
  keep "${WS}/nojE" "⭐ 无 workspace.json 的条目保留"
  keep "${VS}/User/globalStorage/github.copilot-chat/settingEmbeddings.json" "⭐ 未选中的 aggressive 项不动"

  CASE="aggressive"
  run_script "" --aggressive --clean Copilot --yes
  gone "${VS}/User/globalStorage/github.copilot-chat/settingEmbeddings.json" "Copilot 语义索引被清"
  gone "${VS}/User/globalStorage/github.copilot-chat/commandEmbeddings.json" "Copilot 命令索引被清"
  keep "${VS}/User/globalStorage/github.copilot-chat/session-store.db" "⭐ Copilot 聊天记录原样未动"

  CASE="aggressive"
  run_script "" --aggressive --clean Service --yes
  gone "${VS}/Service Worker/CacheStorage/abc.bin" "aggressive：SW 缓存被清"

  CASE="系统级缓存"
  run_script "" --clean 系统级缓存 --yes
  eq "${RUN_RC}" "0" "--clean 系统级缓存 --yes 退出码 0"
  gone "${FIX_HOME}/Library/Caches/com.microsoft.VSCode/Cache.db" "Electron HTTP 缓存被清"
  keep "${FIX_HOME}/Library/HTTPStorages/com.microsoft.VSCode/Cookies.binarycookies" "⭐ 登录态原样未动"

  # H. 多轮循环 -------------------------------------------------------------
  reset_fixture
  CASE="多轮循环"
  run_script "all
all
q" "隐私" "杂项"
  gone "${VS}/DIPS" "多轮：第 1 轮清隐私"
  gone "${VS}/Session Storage/LOG.old" "多轮：第 2 轮清杂项"
  keep "${VS}/Cache" "⭐ 筛选外的项保留"
}

echo "════════ vscode-sweep 回归测试 ════════"
echo "脚本: ${SCRIPT}"
echo "隔离 HOME: ${FIX_ROOT}"

run_locale "C"           "C locale 基线"
run_locale "en_US.UTF-8" "UTF-8 locale（终端默认）"

nuke "${FIX_ROOT}"

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
