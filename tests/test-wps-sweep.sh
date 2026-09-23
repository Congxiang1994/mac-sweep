#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# wps-sweep.sh 回归测试
#
# 全程隔离：WPS_CONTAINER 指向 /tmp 下的假容器，绝不碰真实的 WPS 数据。
# OfficeSpace（用户文档）、WPS Cloud Files、backup、字体、账号、Cookies
# 全部验证保留。
#
# 用法: bash tests/test-wps-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/wps-sweep.sh"
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

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wps-sweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
CONT="${FIX_HOME}/Library/Containers/com.kingsoft.wpsoffice.mac"
DATA="${CONT}/Data"

mk_big() { mkdir -p "$(dirname "$1")"; head -c "$(( ${2} * 1024 ))" /dev/zero > "$1"; }
mk_bigdir() { mkdir -p "$1"; head -c "$(( ${2} * 1024 ))" /dev/zero > "$1/x.bin"; }

reset_fixture() {
  nuke "${FIX_ROOT}"
  local plat="${DATA}/.kingsoft/wps/addons/data/mac-universal"

  # ── 应该进清单的 ──
  mk_bigdir "${plat}/cef/cache/qing" 400                # CEF HTTP 缓存（大头）
  mk_bigdir "${plat}/promeapps/cookie/Cache" 120        # 内嵌页渲染缓存
  mk_bigdir "${plat}/cef/globalcache/Cache" 80
  mk_bigdir "${DATA}/.kingsoft/wps/addons/pool" 300     # 插件安装包缓存
  mk_bigdir "${DATA}/Library/Application Support/Kingsoft/office6/log" 200  # 云服务日志
  mk_bigdir "${DATA}/.local/share/Kingsoft/offlinelog" 60                  # 离线埋点
  mk_bigdir "${DATA}/.kingsoft/office6/kccsdkbak" 40    # 崩溃备份
  mk_bigdir "${DATA}/.kingsoft/office6/data/onlinegradient" 30  # 推广图
  mk_bigdir "${DATA}/tmp/photo_cache" 20                # 图片缓存
  mk_bigdir "${DATA}/Library/WebKit/WebsiteData/ResourceLoadStatistics" 10  # 网页统计
  mk_bigdir "${DATA}/Library/WebKit/WebsiteData/SearchHistory" 5             # 搜索历史
  mk_bigdir "${DATA}/.kingsoft/office6/data/kpdfbackendclient" 25       # PDF 缩略图
  mk_bigdir "${DATA}/tmp/wps-cong" 15                   # HTML 转存残留
  mk_big    "${DATA}/.kingsoft/office6/data/.DS_Store" 12               # 容器内散落

  # ── 绝不能动的 ──
  mk_bigdir "${DATA}/OfficeSpace" 500                   # 用户文档
  mk_bigdir "${DATA}/Library/Containers/com.kingsoft.WPSCloudFiles" 100
  mk_bigdir "${WPS_CLOUD_ROOT:-${DATA}/.kingsoft/wps/WPS Cloud Files}" 100  # 云同步
  mk_bigdir "${DATA}/.kingsoft/office6/backup" 200      # 自动备份
  mk_big    "${DATA}/.kingsoft/office6/tokenTable.ini" 2   # 登录凭据
  mk_bigdir "${DATA}/.kingsoft/office6/fonts" 300       # 用户字体
  mk_bigdir "${DATA}/.kingsoft/office6/hiddenfonts" 10
  mk_bigdir "${DATA}/Library/Application Support/Kingsoft/office6/wpsassist/onlinetemplates" 0 2>/dev/null || true
  mk_big    "${DATA}/.kingsoft/wps/addons/data/mac-universal/promeapps/cookie/Cookies" 20  # 内嵌页登录态
  mk_bigdir "${DATA}/Library/WebKit/WebsiteData/LocalStorage" 60   # aggressive 项，非 aggressive 不动
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" WPS_CONTAINER="${CONT}" LC_ALL="${LOCALE}" \
               /bin/bash "${SCRIPT}" "$@" 2>&1)"
  RUN_RC=$?
}

run_locale() {
  local locale_name="$1" label="$2"
  LOCALE="${locale_name}"
  echo
  echo "── ${label} (LC_ALL=${locale_name}) ──"

  # A. 容器不存在 -----------------------------------------------------------
  CASE="容器缺失"
  nuke "${FIX_ROOT}"; mkdir -p "${FIX_HOME}"
  run_script ""
  eq "${RUN_RC}" "1" "无容器退出码 1"
  has "${RUN_OUT}" "找不到 WPS 容器目录" "给出明确提示"

  # B. 交互默认 --------------------------------------------------------------
  CASE="交互默认"
  reset_fixture
  run_script ""
  eq "${RUN_RC}" "0" "默认模式退出码 0"
  has "${RUN_OUT}" "要清理哪些？" "默认模式给出选择提示"
  has "${RUN_OUT}" "结束，未处理的项原样不动" "回车 = 结束"
  keep "${DATA}/.kingsoft/wps/addons/data/mac-universal/cef/cache/qing" "⭐ 默认模式不动 CEF 缓存"
  keep "${DATA}/OfficeSpace" "⭐ 用户文档始终不动"

  CASE="交互默认"
  reset_fixture
  run_script "q"
  keep "${DATA}/.kingsoft/wps/addons/pool" "⭐ 输入 q 后文件仍然存在"

  CASE="交互默认"
  reset_fixture
  run_script "abc"
  has "${RUN_OUT}" "看不懂这个输入" "乱输入给出提示"
  keep "${DATA}/.kingsoft/wps/addons/pool" "⭐ 乱输入后文件仍然存在"

  # C. 交互选择 --------------------------------------------------------------
  CASE="交互选择"
  reset_fixture
  run_script "yes"
  eq "${RUN_RC}" "0" "交互输入 yes 后退出码 0"
  gone "${DATA}/.kingsoft/wps/addons/data/mac-universal/cef/cache" "⭐ CEF HTTP 缓存被移走"
  gone "${DATA}/.kingsoft/wps/addons/data/mac-universal/promeapps/cookie/Cache" "内嵌页渲染缓存被移走"
  gone "${DATA}/.kingsoft/wps/addons/pool" "插件包缓存被移走"
  gone "${DATA}/Library/Application Support/Kingsoft/office6/log" "云服务日志被移走"
  gone "${DATA}/.local/share/Kingsoft/offlinelog" "离线埋点被移走"
  gone "${DATA}/.kingsoft/office6/kccsdkbak" "崩溃备份被移走"
  gone "${DATA}/.kingsoft/office6/data/onlinegradient" "推广图被移走"
  gone "${DATA}/.kingsoft/office6/data/kpdfbackendclient" "PDF 缩略图缓存被移走"
  gone "${DATA}/tmp/wps-cong" "HTML 转存残留被移走"
  gone "${DATA}/.kingsoft/office6/data/.DS_Store" "容器内 .DS_Store 被移走"
  keep "${FIX_HOME}/.Trash/cache" "废纸篓里能看到移走的目录（不是真删）"
  keep "${DATA}/OfficeSpace" "⭐ 用户文档原样未动"
  keep "${DATA}/.kingsoft/wps/WPS Cloud Files" "⭐ 云同步目录原样未动"
  keep "${DATA}/.kingsoft/office6/backup" "⭐ 自动备份原样未动"
  keep "${DATA}/.kingsoft/office6/tokenTable.ini" "⭐ 登录凭据原样未动"
  keep "${DATA}/.kingsoft/office6/fonts" "⭐ 用户字体原样未动"
  keep "${DATA}/.kingsoft/office6/hiddenfonts" "⭐ 隐藏字体原样未动"
  keep "${DATA}/.kingsoft/wps/addons/data/mac-universal/promeapps/cookie/Cookies" "⭐ 内嵌页 Cookies 原样未动"

  CASE="交互选择"
  reset_fixture
  run_script "1" "运行日志"
  gone "${DATA}/Library/Application Support/Kingsoft/office6/log" "编号选择清日志"
  keep "${DATA}/.kingsoft/wps/addons/pool" "⭐ 未选中的项不动"

  CASE="多轮循环"
  reset_fixture
  run_script "all
all
q" "杂项" "日志"
  gone "${DATA}/Library/Application Support/Kingsoft/office6/log" "多轮：第 1 轮清日志"
  gone "${DATA}/.kingsoft/office6/data/kpdfbackendclient" "多轮：第 2 轮清杂项"
  gone "${DATA}/.kingsoft/office6/data/.DS_Store" "多轮：.DS_Store 一并清"
  keep "${DATA}/.kingsoft/wps/addons/pool" "⭐ 筛选外的项保留"

  # D. 范围闸 ---------------------------------------------------------------
  CASE="范围闸"
  reset_fixture
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${DATA}/.kingsoft/wps/addons/pool" "裸 --clean 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${DATA}/.kingsoft/wps/addons/pool" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  reset_fixture
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  # E. --scan ---------------------------------------------------------------
  CASE="只扫描"
  reset_fixture
  run_script "" --scan
  eq "${RUN_RC}" "0" "--scan 退出码 0"
  has "${RUN_OUT}" "只扫描模式（--scan）" "--scan 报告完直接结束"
  not_has "${RUN_OUT}" "要清理哪些？" "--scan 不进交互"
  keep "${DATA}/.kingsoft/wps/addons/pool" "--scan 不动任何文件"

  # F. 筛选 -----------------------------------------------------------------
  CASE="筛选"
  reset_fixture
  run_script "" cef
  has "${RUN_OUT}" "CEF 内核缓存" "筛选命中 cef 项"
  not_has "${RUN_OUT}" "离线埋点" "筛选未命中日志项"

  CASE="筛选"
  reset_fixture
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  reset_fixture
  run_script "" --clean "日志" --yes
  eq "${RUN_RC}" "0" "--clean 日志 --yes 退出码 0"
  gone "${DATA}/Library/Application Support/Kingsoft/office6/log" "云服务日志被清"
  gone "${DATA}/.local/share/Kingsoft/offlinelog" "离线埋点被清"
  keep "${DATA}/.kingsoft/wps/addons/pool" "⭐ 未命中的插件包缓存原样未动"
  keep "${DATA}/OfficeSpace" "⭐ 用户文档原样未动"

  # G. aggressive ------------------------------------------------------------
  CASE="aggressive"
  reset_fixture
  run_script "" --scan --aggressive
  has "${RUN_OUT}" "LocalStorage" "aggressive 下 WebKit 本地存储进清单"
  keep "${DATA}/Library/WebKit/WebsiteData/LocalStorage" "⭐ --scan 本身不动文件"

  CASE="aggressive"
  reset_fixture
  run_script "" --scan
  not_has "${RUN_OUT}" "LocalStorage" "默认模式 WebKit 本地存储不进清单"

  # H. 蚊子腿目标 -----------------------------------------------------------
  CASE="蚊子腿"
  reset_fixture
  run_script "" --scan
  has "${RUN_OUT}" "kpdfbackendclient" "PDF 缩略图缓存进清单"
  has "${RUN_OUT}" "wps-cong" "HTML 转存残留进清单"
  has "${RUN_OUT}" ".DS_Store" "容器内散落 .DS_Store 进清单"
  not_has "${RUN_OUT}" "OfficeSpace" "⭐ 用户文档绝不进清单"
  not_has "${RUN_OUT}" "tokenTable.ini" "⭐ 登录凭据绝不进清单"
  not_has "${RUN_OUT}" "backup（" "⭐ 自动备份绝不进清单"
}

echo "════════ wps-sweep 回归测试 ════════"
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
