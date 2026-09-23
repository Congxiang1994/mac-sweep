#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tencent_meeting-sweep.sh 回归测试
#
# 全程隔离：HOME 与 TM_CONTAINER 都指向 /tmp 下的假目录，绝不碰真实的腾讯会议数据。
# 数据库 / 偏好设置 / 账号数据 / 登录态 / 会议录制 / 活跃 mmap 句柄 全部逐一断言存活；
# 日志按文件名时间戳判定（最近 N 小时保留），动态资源包按「解压产物是否存在」判定。
#
# 性能说明：造夹具一律用 /bin/mkdir 与 mkfile 这两个原生二进制，不用 mkdir/head/echo
# 这些可能被宿主 shell 代理的命令 —— 否则每建一个文件都要过一次进程代理，
# 整个套件的测试会慢到不可用。只读用例共享同一份夹具，只在真正会改动文件的
# 用例之前才重建。
#
# 用法: bash tests/test-tencent_meeting-sweep.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/tencent_meeting-sweep.sh"
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

FIX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tm-sweep-test.XXXXXX")"
FIX_HOME="${FIX_ROOT}/home"
TM="${FIX_HOME}/Library/Containers/com.tencent.meeting"
TM_HOME="${TM}/Data/Library"
G="${TM_HOME}/Global"
D="${G}/Data"
L="${G}/Logs"

# 原生二进制（不经宿主 shell 代理），快得多
MKDIR=/bin/mkdir
TOUCH=/usr/bin/touch

mk_file() {  # mk_file <文件> <KB>
  ${MKDIR} -p "$(dirname "$1")"
  mkfile "${2}k" "$1" 2>/dev/null
}

# 当前小时戳与上一小时戳（日志按文件名时间戳判定，mtime 不参与）
STAMP_NOW="$(date +%Y%m%d%H)"
STAMP_1H="$(date -v-1H +%Y%m%d%H 2>/dev/null || echo "${STAMP_NOW}")"
STAMP_5H="$(date -v-5H +%Y%m%d%H 2>/dev/null || echo "2020010100")"

reset_fixture() {
  nuke "${FIX_ROOT}"

  # ── 应该进清单的：运行日志 ──
  mk_file "${L}/wmp_2020010100.log" 200                      # 老日志
  mk_file "${L}/wmp_2020010101.log.zip" 150                  # 老日志（zip 形态）
  mk_file "${L}/xcast_2020010100.log" 120
  mk_file "${L}/quic_2020010100.log.zip" 90
  mk_file "${L}/canary_2020010100.log.zip" 60
  mk_file "${L}/lchr_meeting_2020010100.log.zip" 40          # 前缀自带下划线
  mk_file "${L}/app_installer_2020010100.log.zip" 30
  mk_file "${L}/qimei_2020010100.log" 20
  mk_file "${L}/filedelta_2020010100.log.zip" 10
  mk_file "${L}/wmp_${STAMP_5H}.log" 70                      # 5 小时前 → 超冷却期，该清
  mk_file "${L}/wmp_${STAMP_1H}.log" 50                      # 1 小时前 → 冷却期内，保留
  mk_file "${L}/wmp_${STAMP_NOW}.log" 80                     # 当前小时，恒保留

  # ── 绝不能碰的：Logs 里的活跃句柄 / 非时间戳命名 ──
  mk_file "${L}/wmp.log.mmap3" 152
  mk_file "${L}/canary.log.mmap3" 152
  mk_file "${L}/qimei.log.mmap3" 152
  mk_file "${L}/filedelta.log.mmap3" 152
  mk_file "${L}/crash_count.log" 52
  mk_file "${L}/2020-01-01.965..pere.rp" 4
  mk_file "${L}/wwlink_202001010000_encrypt.log" 24          # 尾部非时间戳，不碰

  # ── IM 日志 ──
  mk_file "${L}/im/imsdk_C.mmap2" 152                        # 活跃句柄，恒不碰
  mk_file "${L}/im/imsdk_C_20200101-100.xlog" 20
  mk_file "${L}/im/imsdk_C_20200102-200.xlog" 24
  mk_file "${L}/im/imsdk_C_20200103-300.xlog" 28             # 最新一份，保留

  # ── 动态资源包：aaa/bbb 解压到 DynamicResource，ccc 解压到 AudioModel ──
  mk_file "${D}/DynamicResourcePackage/aaaa1111.zip" 500     # 已解压
  mk_file "${D}/DynamicResourcePackage/bbbb2222.zip" 400     # 已解压
  mk_file "${D}/DynamicResourcePackage/cccc3333.zip" 300     # 已解压（落在 AudioModel）
  mk_file "${D}/DynamicResourcePackage/dddd4444.zip" 200     # 未解压
  mk_file "${D}/DynamicResource/aaaa1111/asset.bin" 600
  mk_file "${D}/DynamicResource/bbbb2222/asset.bin" 450
  mk_file "${D}/AudioModel/cccc3333/model.bin" 350

  # ── 其他可清项 ──
  mk_file "${D}/Avatars/av1.png" 30
  mk_file "${D}/AvatarModel/amodel.bin" 60
  mk_file "${D}/TemplateResources/tr.bin" 50
  mk_file "${D}/CustomLayoutPreview/clp.bin" 10
  mk_file "${G}/Xnn/deadbeef/humansegment_pc/model.bin" 190
  mk_file "${TM_HOME}/Caches/Temp/t.bin" 4
  mk_file "${TM_HOME}/Caches/Data/Images/i.png" 16
  mk_file "${TM_HOME}/Caches/audio_detect_record/r.dat" 4
  mk_file "${FIX_HOME}/Library/Caches/com.tencent.meeting/Cache.db" 48
  mk_file "${FIX_HOME}/Library/Caches/com.tencent.meeting/WebKit/w.bin" 20
  mk_file "${FIX_HOME}/Library/Caches/com.tencent.meeting.services.wmexternal/Cache.db" 12
  mk_file "${FIX_HOME}/Library/Application Support/com.tencent.meeting/com.tencent.bugly/v1/x.bin" 4

  # ── 绝不能动的 ──
  mk_file "${G}/Database/2d1073b1683f3db487c68ad1fbe3e89c.db" 480
  mk_file "${G}/Database/wemeet.db" 860
  mk_file "${G}/Preferences/pref__5c552085.tv" 256
  mk_file "${TM_HOME}/Users/Default/bb6bb9eb26e88e55a366a30f6b0d25d3/Database/user.db" 972
  mk_file "${G}/crash_count_down2" 1
  mk_file "${G}/module_config_path.tv" 16
  mk_file "${G}/voiceprint_record/vp.dat" 1
  mk_file "${G}/XMagic/xm.bin" 8
  mk_file "${G}/WWLink/ww.bin" 8
  mk_file "${D}/XCast/xc.bin" 8
  mk_file "${D}/StartUp/su.bin" 8
  mk_file "${D}/Timezone/tz.bin" 8
  mk_file "${D}/Timeline/tl.bin" 8
  mk_file "${D}/IM/im.bin" 8
  mk_file "${FIX_HOME}/Library/HTTPStorages/com.tencent.meeting/httpstorages.sqlite" 40
  mk_file "${FIX_HOME}/Library/Preferences/com.tencent.meeting.plist" 2
  mk_file "${FIX_HOME}/Documents/TencentMeeting/2026-01-28 14.56.47 例会 756344037/rec.mp4" 900
}

RUN_OUT=""
RUN_RC=0
run_script() {  # run_script <stdin> <参数...>
  local stdin_data="$1"; shift
  RUN_OUT="$(printf '%s\n' "${stdin_data}" \
             | HOME="${FIX_HOME}" TM_CONTAINER="${TM}" LC_ALL="${LOCALE}" \
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
  keep "${L}/wmp_2020010100.log" "⭐ 默认模式不动日志"
  keep "${G}/Database/wemeet.db" "⭐ 数据库始终不动"

  CASE="交互默认"
  run_script "q"
  keep "${D}/DynamicResourcePackage/aaaa1111.zip" "⭐ 输入 q 后文件仍然存在"

  CASE="交互默认"
  run_script "abc"
  has "${RUN_OUT}" "看不懂这个输入" "乱输入给出提示"
  keep "${D}/DynamicResourcePackage/aaaa1111.zip" "⭐ 乱输入后文件仍然存在"

  # B. 范围闸（全部不会改动文件，共享一份夹具）-----------------------------
  reset_fixture
  CASE="范围闸"
  run_script "" --clean
  eq "${RUN_RC}" "2" "裸 --clean 退出码 2"
  has "${RUN_OUT}" "没有指定范围" "裸 --clean 明确拒绝"
  keep "${L}/wmp_2020010100.log" "裸 --clean 不删任何东西"

  CASE="范围闸"
  run_script "" --clean --all --yes
  eq "${RUN_RC}" "2" "--clean --all --yes 退出码 2"
  keep "${L}/wmp_2020010100.log" "--clean --all --yes 不删任何东西"

  CASE="范围闸"
  run_script "" --clean --yes
  eq "${RUN_RC}" "2" "--clean --yes（无筛选）退出码 2"

  CASE="只扫描"
  run_script "" --scan
  eq "${RUN_RC}" "0" "--scan 退出码 0"
  has "${RUN_OUT}" "只扫描模式（--scan）" "--scan 报告完直接结束"
  not_has "${RUN_OUT}" "要清理哪些？" "--scan 不进交互"
  keep "${L}/wmp_2020010100.log" "--scan 不动任何文件"
  has "${RUN_OUT}" "保护中" "报告显示保护中数据的规模"
  has "${RUN_OUT}" "会议录制" "报告交代会议录制的归属"
  has "${RUN_OUT}" "非时间戳命名的文件" "报告交代活跃 mmap 句柄被跳过"
  has "${RUN_OUT}" "未解压资源包" "报告交代 aggressive 才能清的未解压包"
  not_has "${RUN_OUT}" "未解压的下载包" "⭐ 非 aggressive 不列出未解压包"
  not_has "${RUN_OUT}" "AI 模型" "⭐ 非 aggressive 不列出 AI 模型"
  not_has "${RUN_OUT}" "动态资源本体" "⭐ 非 aggressive 不列出动态资源本体"

  # C. 保护名单（只读断言，复用同一份夹具）---------------------------------
  CASE="保护名单"
  run_script "" --scan
  not_has "${RUN_OUT}" "wemeet.db" "⭐ 会议数据库绝不进清单"
  not_has "${RUN_OUT}" "pref__5c552085" "⭐ 偏好设置绝不进清单"
  not_has "${RUN_OUT}" "user.db" "⭐ 账号数据绝不进清单"
  not_has "${RUN_OUT}" "httpstorages.sqlite" "⭐ 登录态绝不进清单"
  not_has "${RUN_OUT}" "rec.mp4" "⭐ 会议录制绝不进清单"
  not_has "${RUN_OUT}" "mmap3" "⭐ 活跃 mmap 句柄绝不进清单"
  not_has "${RUN_OUT}" "imsdk_C.mmap2" "⭐ IM 会话句柄绝不进清单"
  not_has "${RUN_OUT}" "crash_count.log" "⭐ crash_count.log 绝不进清单"
  not_has "${RUN_OUT}" "pere.rp" "⭐ .rp 文件绝不进清单"
  not_has "${RUN_OUT}" "encrypt" "⭐ wwlink 加密日志绝不进清单"
  not_has "${RUN_OUT}" "XCast" "⭐ XCast 配置目录绝不进清单"
  not_has "${RUN_OUT}" "voiceprint_record" "⭐ 声纹记录绝不进清单"

  CASE="保护名单"
  run_script "" --aggressive --scan
  not_has "${RUN_OUT}" "wemeet.db" "⭐ aggressive 下数据库仍不进清单"
  not_has "${RUN_OUT}" "rec.mp4" "⭐ aggressive 下会议录制仍不进清单"
  not_has "${RUN_OUT}" "mmap3" "⭐ aggressive 下活跃句柄仍不进清单"
  has "${RUN_OUT}" "未解压的下载包（1 个" "只认出 1 个真·未解压包"
  has "${RUN_OUT}" "已解压的下载包（3 个" "只认出 3 个已解压包"

  # D. 筛选（只读）----------------------------------------------------------
  CASE="筛选"
  run_script "" log
  has "${RUN_OUT}" "运行日志" "筛选命中日志项"
  not_has "${RUN_OUT}" "WebKit" "筛选未命中 WebKit 缓存"

  CASE="筛选"
  run_script "" zzz-nothing-here
  eq "${RUN_RC}" "0" "无命中退出码 0"
  has "${RUN_OUT}" "没有匹配" "无命中给出明确提示"

  CASE="筛选"
  run_script "" --aggressive --scan 资源包 --and 已解压
  has "${RUN_OUT}" "且" "交集模式在报告里显式打出「且」"
  has "${RUN_OUT}" "已解压的下载包" "交集命中已解压包"
  not_has "${RUN_OUT}" "未解压的下载包" "⭐ 交集把未解压包排除在外"

  # E. 运行日志（只读一轮）--------------------------------------------------
  CASE="运行日志"
  run_script "" --clean 运行日志 --yes
  eq "${RUN_RC}" "0" "--clean 运行日志 --yes 退出码 0"
  gone "${L}/wmp_2020010100.log" "⭐ 老日志被清"
  gone "${L}/wmp_2020010101.log.zip" "⭐ 老日志 zip 形态被清"
  gone "${L}/xcast_2020010100.log" "⭐ xcast 老日志被清"
  gone "${L}/quic_2020010100.log.zip" "⭐ quic 老日志被清"
  gone "${L}/lchr_meeting_2020010100.log.zip" "⭐ 前缀自带下划线的日志被清"
  gone "${L}/app_installer_2020010100.log.zip" "⭐ app_installer 日志被清"
  gone "${L}/wmp_${STAMP_5H}.log" "⭐ 超冷却期的日志被清"
  keep "${L}/wmp_${STAMP_NOW}.log" "⭐ 当前小时的日志恒保留"
  keep "${L}/wmp_${STAMP_1H}.log" "⭐ 冷却期内的日志保留"
  keep "${L}/wmp.log.mmap3" "⭐⭐ 活跃 mmap 句柄原样未动"
  keep "${L}/canary.log.mmap3" "⭐ 活跃 mmap 句柄原样未动"
  keep "${L}/crash_count.log" "⭐ 非时间戳命名的 crash_count.log 原样未动"
  keep "${L}/2020-01-01.965..pere.rp" "⭐ .rp 文件原样未动"
  keep "${L}/wwlink_202001010000_encrypt.log" "⭐ 尾部非时间戳的日志原样未动"
  keep "${FIX_HOME}/.Trash/wmp_2020010100.log" "日志出现在废纸篓（不是真删）"
  keep "${G}/Database/wemeet.db" "⭐ 数据库原样未动"

  # F. IM 日志（紧接上轮，夹具已部分清理）---------------------------------
  CASE="IM 日志"
  run_script "" --clean IM --yes
  eq "${RUN_RC}" "0" "--clean IM --yes 退出码 0"
  gone "${L}/im/imsdk_C_20200101-100.xlog" "⭐ IM 旧归档被清"
  gone "${L}/im/imsdk_C_20200102-200.xlog" "⭐ IM 次旧归档被清"
  keep "${L}/im/imsdk_C_20200103-300.xlog" "⭐ IM 最新归档恒保留"
  keep "${L}/im/imsdk_C.mmap2" "⭐⭐ IM 会话句柄原样未动"

  # G. 已解压资源包（重建夹具）--------------------------------------------
  reset_fixture
  CASE="已解压资源包"
  run_script "" --clean 已解压资源包 --yes
  eq "${RUN_RC}" "0" "--clean 已解压资源包 --yes 退出码 0"
  gone "${D}/DynamicResourcePackage/aaaa1111.zip" "⭐ 已解压（DynamicResource 有产物）的包被清"
  gone "${D}/DynamicResourcePackage/bbbb2222.zip" "⭐ 已解压的包被清"
  gone "${D}/DynamicResourcePackage/cccc3333.zip" "⭐ 落在 AudioModel 的已解压包被清"
  keep "${D}/DynamicResourcePackage/dddd4444.zip" "⭐⭐ 未解压的包保留"
  keep "${D}/DynamicResource/aaaa1111/asset.bin" "⭐⭐ 资源本体原样未动"
  keep "${D}/AudioModel/cccc3333/model.bin" "⭐⭐ AI 模型本体非 aggressive 不动"

  # H. 系统级缓存（接着上轮夹具）------------------------------------------
  CASE="WebKit 缓存"
  run_script "" --clean WebKit --yes
  eq "${RUN_RC}" "0" "--clean WebKit --yes 退出码 0"
  gone "${FIX_HOME}/Library/Caches/com.tencent.meeting" "WebKit/HTTP 缓存被清"
  keep "${FIX_HOME}/Library/HTTPStorages/com.tencent.meeting/httpstorages.sqlite" "⭐ 登录态原样未动"
  keep "${FIX_HOME}/Library/Preferences/com.tencent.meeting.plist" "⭐ 偏好 plist 原样未动"

  CASE="扩展组件缓存"
  run_script "" --clean wmexternal --yes
  gone "${FIX_HOME}/Library/Caches/com.tencent.meeting.services.wmexternal" "共享组件缓存被清"

  # I. aggressive -----------------------------------------------------------
  reset_fixture
  CASE="aggressive"
  run_script "" --aggressive --clean 未解压 --yes
  gone "${D}/DynamicResourcePackage/dddd4444.zip" "aggressive：未解压包被清"
  keep "${D}/DynamicResourcePackage/aaaa1111.zip" "⭐ 未选中的已解压包保留"
  keep "${D}/DynamicResource/aaaa1111/asset.bin" "⭐ 未选中的资源本体保留"

  CASE="aggressive"
  run_script "" --aggressive --clean 动态资源本体 --yes
  gone "${D}/DynamicResource/aaaa1111/asset.bin" "aggressive：动态资源本体被清"
  keep "${D}/AudioModel/cccc3333/model.bin" "⭐ 未选中的 AI 模型保留"

  CASE="aggressive"
  run_script "" --aggressive --clean 模型 --yes
  eq "${RUN_RC}" "0" "--aggressive --clean 模型 --yes 退出码 0"
  gone "${D}/AudioModel/cccc3333/model.bin" "aggressive：音频降噪模型被清"
  gone "${G}/Xnn/deadbeef/humansegment_pc/model.bin" "aggressive：人像分割模型被清"
  keep "${G}/Database/wemeet.db" "⭐ 数据库原样未动"

  CASE="aggressive"
  run_script "" --aggressive --clean 虚拟形象 --yes
  gone "${D}/AvatarModel/amodel.bin" "aggressive：虚拟形象模型被清"
  gone "${D}/TemplateResources/tr.bin" "aggressive：模板资源被清"
  gone "${D}/CustomLayoutPreview/clp.bin" "aggressive：自定义布局预览被清"

  # J. 交互整轮清理 ---------------------------------------------------------
  reset_fixture
  CASE="交互选择"
  run_script "yes"
  eq "${RUN_RC}" "0" "交互输入 yes 后退出码 0"
  gone "${L}/wmp_2020010100.log" "⭐ 老日志被移走"
  gone "${L}/im/imsdk_C_20200101-100.xlog" "IM 旧归档被移走"
  gone "${D}/DynamicResourcePackage/aaaa1111.zip" "已解压资源包被移走"
  gone "${D}/Avatars/av1.png" "头像缓存被移走"
  gone "${FIX_HOME}/Library/Caches/com.tencent.meeting/Cache.db" "WebKit 缓存被移走"
  keep "${FIX_HOME}/.Trash/wmp_2020010100.log" "日志出现在废纸篓（不是真删）"
  keep "${L}/wmp.log.mmap3" "⭐ 活跃 mmap 句柄原样未动"
  keep "${L}/wwlink_202001010000_encrypt.log" "⭐ 尾部非时间戳的日志原样未动"
  keep "${G}/Database/wemeet.db" "⭐ 数据库原样未动"
  keep "${G}/Preferences/pref__5c552085.tv" "⭐ 偏好设置原样未动"
  keep "${TM_HOME}/Users/Default/bb6bb9eb26e88e55a366a30f6b0d25d3/Database/user.db" "⭐ 账号数据原样未动"
  keep "${G}/crash_count_down2" "⭐ crash_count_down2 原样未动"
  keep "${G}/module_config_path.tv" "⭐ module_config_path 原样未动"
  keep "${G}/voiceprint_record/vp.dat" "⭐ 声纹记录原样未动"
  keep "${G}/XMagic/xm.bin" "⭐ XMagic 原样未动"
  keep "${G}/WWLink/ww.bin" "⭐ WWLink 原样未动"
  keep "${D}/XCast/xc.bin" "⭐ XCast 原样未动"
  keep "${D}/StartUp/su.bin" "⭐ StartUp 原样未动"
  keep "${D}/Timezone/tz.bin" "⭐ Timezone 原样未动"
  keep "${D}/Timeline/tl.bin" "⭐ Timeline 原样未动"
  keep "${D}/IM/im.bin" "⭐ IM 目录原样未动"
  keep "${FIX_HOME}/Library/HTTPStorages/com.tencent.meeting/httpstorages.sqlite" "⭐ 登录态原样未动"
  keep "${FIX_HOME}/Library/Preferences/com.tencent.meeting.plist" "⭐ 偏好 plist 原样未动"
  keep "${FIX_HOME}/Documents/TencentMeeting/2026-01-28 14.56.47 例会 756344037/rec.mp4" "⭐⭐ 会议录制原样未动"
  keep "${D}/DynamicResourcePackage/dddd4444.zip" "⭐ 未解压包非 aggressive 不动"
  keep "${D}/DynamicResource/aaaa1111/asset.bin" "⭐ 资源本体非 aggressive 不动"
  keep "${D}/AudioModel/cccc3333/model.bin" "⭐ AI 模型非 aggressive 不动"
  keep "${G}/Xnn/deadbeef/humansegment_pc/model.bin" "⭐ 人像分割模型非 aggressive 不动"

  # K. 多轮循环 -------------------------------------------------------------
  reset_fixture
  CASE="多轮循环"
  run_script "all
all
q" "运行日志" "IM"
  gone "${L}/wmp_2020010100.log" "多轮：第 1 轮清运行日志"
  gone "${L}/im/imsdk_C_20200101-100.xlog" "多轮：第 2 轮清 IM 日志"
  keep "${D}/DynamicResourcePackage/aaaa1111.zip" "⭐ 筛选外的项保留"
}

echo "════════ tencent_meeting-sweep 回归测试 ════════"
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
