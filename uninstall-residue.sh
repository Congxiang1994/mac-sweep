#!/usr/bin/env bash
#
# uninstall-residue.sh — 找出已卸载 macOS 软件遗留的残留数据
#
# ─────────────────────────────────────────────────────────────────────────────
# 一个入口：直接跑，扫完在终端里挑要清哪些。默认【只扫描 + 等你确认】，
# 没有你的明确输入，一个文件都不会动。
#
# 判定思路：
#   1. 收集当前系统真正装着哪些 App —— /Applications、/System/Applications、
#      Utilities、~/Applications、输入法目录 —— 取出它们的 bundle id、App 名、
#      以及 bundle id 里的组织段（com.<org>.app 的 <org>）；
#   2. 遍历 ~/Library 下最容易堆积残留的位置（Application Support / Caches /
#      Preferences / Containers / LaunchAgents / Logs / Saved Application State …）；
#   3. 任何「名字是标准 bundle id，或是某个软件的名字，却在已装 App 里找不到
#      对应物」的条目，判为疑似残留；
#   4. 把同一软件的散落残留聚合成一条，给出路径、体积、最后修改时间。
#
# 报告里的标注：
#   基本确定 — 名字长得就是标准软件标识（如 com.xxx.yyy），系统里却没有这个软件
#   待确认   — 只是个普通文件夹名（如 Docker Desktop），系统里没有同名软件
#   归属不明 — 认不出属于谁，可能只是系统/开发工具目录（默认不显示，--all 才列出）
#
# 用法：
#   ./uninstall-residue.sh                     # 扫描 → 列清单 → 交互选择要清的项
#   ./uninstall-residue.sh sogou               # 只把名字/路径含 sogou 的项列进清单
#   ./uninstall-residue.sh sogou baidu         # 多个关键词 = 并集（含 sogou 或 baidu）
#   ./uninstall-residue.sh sogou --and pinyin  # 交集（同时含两词才算）
#   ./uninstall-residue.sh --only sogou,baidu  # 逗号连写，等价于空格分隔
#   ./uninstall-residue.sh --all               # 加上「归属不明」项（即「全部」）
#   ./uninstall-residue.sh --system            # 额外扫描 /Library（只读；清理需 sudo）
#   ./uninstall-residue.sh --min-age 180       # 只看 180 天以上没被动过的
#   ./uninstall-residue.sh --scan              # 只看报告，不进交互（适合重定向存文件）
#   ./uninstall-residue.sh --report /tmp/r.tsv # 另存一份 TSV 报告（默认不落盘）
#
# 交互提示可以输入：
#   yes / all          全部移入废纸篓
#   1 3 5 / 1-4 / 1,3  只处理这些编号
#   pick               逐组确认（y=整组移入 n=跳过 s=逐条挑 q=结束）
#   q 或回车           结束，未处理的项原样不动
# 处理完还有剩余项时，会再把剩余清单摆出来继续问，直到你说结束。
#
# 非交互用法（脚本化 / CI，仍然有范围闸）：
#   ./uninstall-residue.sh --clean sogou --yes   # 跳过交互，直接清匹配项
#   ./uninstall-residue.sh --clean --all         # 进交互但清单是全部，仍需手输 yes
#   ⚠️ 裸 --clean（既没关键词也没 --all）拒绝执行，退出码 2 —— 手滑敲出来不会变成全删。
#   ⚠️ --yes 必须带筛选条件：--clean --all --yes 这种「一句话全清空」被刻意堵死。
#
# 筛选（--only 或位置参数，可重复给）：
#   匹配「组名」或「组内任一完整路径」的子串，忽略大小写。
#   多个关键词默认是「并集」——任意一个命中就算命中。
#   想取「交集」用 --and（如 sogou --and pinyin：同时含两个词才算数）；
#   再给一个关键词就切回并集。用法可混排：a b --and c  =  (a 或 b) 且 c。
#   一个参数里可以用逗号分隔多个词：--only sogou,baidu 等价于 sogou baidu。
#   ⚠️ 交互里的编号只对「本次显示顺序」有效，每次都会重排；筛选一律按关键词走。
#
# 「归属不明」的项脚本永远不碰 —— 认不出主人，不替你拿主意。
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
#    注意：废纸篓里的东西仍占磁盘，清空废纸篓后空间才真正释放。
#
# 可调环境变量：
#   EXTRA_APP_DIRS  额外参与「已装 App 指纹」的目录，冒号分隔（App 装在非常规位置时用）
#   HOME            用户主目录（测试时指向隔离目录）
#   FORCE_PROGRESS  置 1 时即使输出被重定向也画进度条（进度条走 stderr）
#
# ⚠️ 没有「单次上限」：选中之后清单上的组一次处理完，不会清到一半停住。
# ⚠️ 默认不产生任何文件（清单直接打在屏幕上）；只有显式 --report 才写 TSV。
# ─────────────────────────────────────────────────────────────────────────────
set -u

CLEAN=0
SHOW_ALL=0
SCAN_SYSTEM=0
MIN_AGE_DAYS=0
REPORT_FILE=""
ASSUME_YES=0

# --report 是 TSV 输出（不是 --scan 别名），公共库把值存进 REPORT_FILE
SWEEP_REPORT_TSV=1

# 未识别参数先问这里：--system / --min-age 由本脚本消费
sweep_extra_arg() {
  case "$1" in
    --system)
      SCAN_SYSTEM=1
      return 0 ;;
    --min-age)
      MIN_AGE_DAYS="${2:-0}"
      if [ "$#" -ge 2 ]; then SWEEP_EXTRA_SHIFT=2; else SWEEP_EXTRA_SHIFT=1; fi
      return 0 ;;
  esac
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sweep-common.sh
source "${SCRIPT_DIR}/sweep-common.sh"

case "${MIN_AGE_DAYS}" in ''|*[!0-9]*) MIN_AGE_DAYS=0 ;; esac

LIB="${HOME}/Library"
[ -d "${LIB}" ] || { echo "找不到 ${LIB}" >&2; exit 1; }

# ⚠️ 默认不落盘：清单直接打在屏幕上。只有显式 --report <路径> 时才写 TSV。
TSV_TMP=""
trap 'rm -f "${TSV_TMP}" 2>/dev/null' EXIT INT TERM

# ═════════════════════════════════════════════════════════════════════════════
# 通用词元工具（本脚本独有：残留聚合的宽松匹配）
# ═════════════════════════════════════════════════════════════════════════════

norm()  { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -dc 'a-z0-9'; }  # 只留 a-z0-9

# 词元：小写、按非字母数字切分、去掉通用词与 <4 字符的词
# 通用词若不剔除，「Docker Desktop」「yuque-desktop」「x.desktop」会被误判成同一软件
#   ⚠️ 必须写成单行：awk -v 不接受带换行的取值
STOPWORDS="desktop helper agent daemon service services server updater update client electron framework crashpad crashreporter preferences settings setting cache caches support storage workflow open install installer uninstall launcher runner macos macintosh"

tokens_of() {
  printf '%s' "$1" \
    | LC_ALL=C tr 'A-Z' 'a-z' \
    | LC_ALL=C tr -c 'a-z0-9' '\n' \
    | awk -v sw="${STOPWORDS}" '
        BEGIN { n = split(sw, arr, " "); for (i = 1; i <= n; i++) if (arr[i] != "") stop[arr[i]] = 1 }
        length($0) >= 4 && !($0 in stop) { print }
      '
}

# 两个词元集合是否有「相等」或「一方是另一方前缀（长度 ≥6）」的关系
# ⚠️ 两条都是踩出来的：
#    · 不用「任意子串」—— 否则 sparkle-project 与 qtproject 会因 project 粘成一组
#    · 前缀门槛取 6 而非 5 —— 否则 tencent.qq.share 的 share 会吞掉 SharedDefaults
tokens_related() {
  local a b
  while IFS= read -r a; do
    [ -n "${a}" ] || continue
    while IFS= read -r b; do
      [ -n "${b}" ] || continue
      [ "${a}" = "${b}" ] && return 0
      if [ "${#a}" -ge 6 ]; then case "${b}" in "${a}"*) return 0 ;; esac; fi
      if [ "${#b}" -ge 6 ]; then case "${a}" in "${b}"*) return 0 ;; esac; fi
    done <<< "$2"
  done <<< "$1"
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# 1. 已装 App 指纹
# ═════════════════════════════════════════════════════════════════════════════

APP_DIRS=(
  "/Applications"
  "/Applications/Utilities"
  "/System/Applications"
  "/System/Applications/Utilities"
  "/System/Library/CoreServices/Applications"
  "${HOME}/Applications"
  "/Library/Input Methods"
  "${HOME}/Library/Input Methods"
  "/Library/PreferencePanes"
)

# 额外指纹目录（冒号分隔）：App 装在非常规位置时可用，测试也靠它注入假 App
if [ -n "${EXTRA_APP_DIRS:-}" ]; then
  old_ifs="${IFS}"; IFS=':'
  for extra_dir in ${EXTRA_APP_DIRS}; do
    [ -n "${extra_dir}" ] && APP_DIRS+=("${extra_dir}")
  done
  IFS="${old_ifs}"
fi

declare -a INS_IDS=()          # bundle id（小写，保留点）
declare -a INS_NAMES=()        # App 名（归一化）
declare -a INS_TOKENS=()       # App 名的词元 + bundle id 组织段，用于宽松匹配

collect_installed() {
  local dir app name id seg tok
  for dir in "${APP_DIRS[@]}"; do
    [ -d "${dir}" ] || continue
    for app in "${dir}"/*.app; do
      [ -d "${app}" ] || continue
      name=$(basename "${app}" .app)

      local nn; nn=$(norm "${name}")
      [ -n "${nn}" ] && INS_NAMES+=("${nn}")

      while IFS= read -r tok; do
        [ -n "${tok}" ] && INS_TOKENS+=("${tok}")
      done <<< "$(tokens_of "${name}")"

      id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
             "${app}/Contents/Info.plist" 2>/dev/null || true)
      [ -n "${id}" ] || continue
      INS_IDS+=("$(id_lc "${id}")")

      # 组织段：com.<org>.<app> 取第 2 段；com.tinyspeck.slackmacgap 取倒数第 2 段
      seg=$(printf '%s' "${id}" | awk -F. 'NF>=3{print $2}')
      [ -n "${seg}" ] && [ "${#seg}" -ge 4 ] && INS_TOKENS+=("$(norm "${seg}")")
      seg=$(printf '%s' "${id}" | awk -F. 'NF>=2{print $(NF-1)}')
      [ -n "${seg}" ] && [ "${#seg}" -ge 4 ] && INS_TOKENS+=("$(norm "${seg}")")
    done
  done
}

collect_installed

# 已装 App 的 bundle id 是否覆盖它（自身 / 父级 / 子级）
is_installed_id() {
  local v; v=$(id_lc "$1")
  [ -n "${v}" ] || return 1
  [ "${#INS_IDS[@]}" -gt 0 ] || return 1
  local a
  for a in "${INS_IDS[@]}"; do
    [ "${v}" = "${a}" ] && return 0
    case "${v}" in "${a}".*) return 0 ;; esac   # 残留是已装 id 的子级，如 xxx.helper
    case "${a}" in "${v}".*) return 0 ;; esac   # 残留是已装 id 的父级
  done
  return 1
}

# 目录名是否对应某个已装 App：整体相等，或词元命中（Code ← Visual Studio Code）
is_installed_name() {
  local n; n=$(norm "$1")
  [ -n "${n}" ] || return 1
  local a
  if [ "${#INS_NAMES[@]}" -gt 0 ]; then
    for a in "${INS_NAMES[@]}"; do
      [ "${n}" = "${a}" ] && return 0
    done
  fi
  local toks; toks=$(tokens_of "$1")
  [ -n "${toks}" ] || return 1
  local t
  while IFS= read -r t; do
    [ -n "${t}" ] || continue
    if [ "${#INS_TOKENS[@]}" -gt 0 ]; then
      for a in "${INS_TOKENS[@]}"; do
        [ "${t}" = "${a}" ] && return 0
        # 前缀：WorkBuddyExtension ← WorkBuddy（≥5 字符，避免 code 吞掉 CodeBuddyExtension）
        if [ "${#a}" -ge 5 ]; then case "${t}" in "${a}"*) return 0 ;; esac; fi
      done
    fi
  done <<< "${toks}"
  return 1
}

# bundle id 兜底：整体或末段能对上某个已装 App 名（draw.io ← draw.io.app）
is_installed_id_as_name() {
  local v; v=$(norm "$1")
  [ -n "${v}" ] || return 1
  local a last; last=$(norm "${1##*.}")
  if [ "${#INS_NAMES[@]}" -gt 0 ]; then
    for a in "${INS_NAMES[@]}"; do
      [ "${v}" = "${a}" ] && return 0
      [ -n "${last}" ] && [ "${last}" = "${a}" ] && return 0
    done
  fi
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# 2. 白名单 —— 这些名字不是「卸载残留」，不要误报
# ═════════════════════════════════════════════════════════════════════════════

# 2a. 前缀级：Apple 自家命名空间，以及各家常驻更新器（对应 App 还在时需要它）
IGNORE_ID_PREFIXES=(
  "com.apple."
  "com.google."
  "com.microsoft.autoupdate"
  "com.microsoft.office.licensing"
  "com.adobe.arm"
)

# 2b. 名字级：系统与共享目录（归一化后精确匹配）
IGNORE_NAMES=(
  # macOS 自带
  addressbook addressbookmeta callhistorydb callhistorytransactions
  clouddocs knowledge mobilesync syncservices crashreporter diagnosticreports
  differentialprivacy diskimages fileprovider animoji caches
  icdd homeenergyd familycircled locationaccessstored networkserviceproxy
  unknown loginconfig wwlinksetting
  # 纯配置散件 / 系统内置服务（不是卸载残留）
  icloud tvappservicescontainer isworkflowmyapp loginconfigjson
  settingjson wwlinksettingjson sharedfilelist
  # 开发工具 / SDK 的公共数据目录（不属于某个 App）
  iosentry cef ultralytics
)

is_ignored_id() {
  local v; v=$(id_lc "$1")
  local p
  for p in "${IGNORE_ID_PREFIXES[@]}"; do
    case "${v}" in "${p}"*) return 0 ;; esac
  done
  # 任何一段是 apple 的都算系统（覆盖 systemgroup.com.apple.* / groups.com.apple.*）
  case "${v}" in
    *.apple.*|apple.*) return 0 ;;
  esac
  return 1
}

is_ignored_name() {
  local n; n=$(norm "$1")
  [ -n "${n}" ] || return 1
  local a
  [ "${#IGNORE_NAMES[@]}" -gt 0 ] || return 1
  for a in "${IGNORE_NAMES[@]}"; do
    [ "${n}" = "${a}" ] && return 0
  done
  return 1
}

# 标准 bundle id 形状：至少两段，只含字母数字与 - _
is_bundleid_like() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$'
}

# ═════════════════════════════════════════════════════════════════════════════
# 3. 扫描位置
#    格式 "路径|模式|后缀"
#      模式 id  = 只接受 bundle id 形状的名字（Caches/Containers 之类噪音多，收紧）
#      模式 any = bundle id 与普通目录名都接受
#      后缀     = 只收该扩展名的条目，并把扩展名剥掉当标识
# ═════════════════════════════════════════════════════════════════════════════

declare -a LOCATIONS=(
  "${LIB}/Application Support|any|"
  "${LIB}/Caches|id|"
  "${LIB}/Preferences|id|plist"
  "${LIB}/Logs|any|"
  "${LIB}/Saved Application State|id|savedState"
  "${LIB}/Containers|id|"
  "${LIB}/Group Containers|gid|"
  "${LIB}/WebKit|id|"
  "${LIB}/HTTPStorages|id|binarycookies"
  "${LIB}/Cookies|id|binarycookies"
  "${LIB}/LaunchAgents|id|plist"
  "${LIB}/Application Scripts|any|"
  "${LIB}/Services|any|"
)

if [ "${SCAN_SYSTEM}" -eq 1 ]; then
  LOCATIONS+=(
    "/Library/Application Support|any|"
    "/Library/Caches|id|"
    "/Library/Preferences|id|plist"
    "/Library/Logs|any|"
    "/Library/LaunchAgents|id|plist"
    "/Library/LaunchDaemons|id|plist"
  )
fi

ui_head "已卸载软件残留扫描" \
  "主目录    ${HOME}" \
  "系统级    $([ "${SCAN_SYSTEM}" -eq 1 ] && echo '一并扫描 /Library（只读；清理需 sudo）' || echo '不扫描（--system 可加）')" \
  "已装指纹  ${#INS_NAMES[@]} 个名字 / ${#INS_IDS[@]} 个 bundle id" \
  "时间      $(date '+%Y-%m-%d %H:%M')" \
  "模式      $([ "${SCAN_ONLY}" -eq 1 ] && echo '只扫描，不删除任何文件' || echo '扫描 → 交互式确认清理（移入废纸篓）')"
have_filters && ui_note "筛选：只列名字或路径含「$(filters_desc)」的项"
[ "${MIN_AGE_DAYS}" -gt 0 ] && ui_note "只看闲置 ≥ ${MIN_AGE_DAYS} 天的条目"
ui_note "扫描中…（进度见下方）"

# 先数一遍条目总数，进度条才有分母（纯 glob 数数很便宜，耗时全在下面的 du）
PROG_TOTAL=0
for spec in "${LOCATIONS[@]}"; do
  loc="${spec%%|*}"
  [ -d "${loc}" ] || continue
  for entry in "${loc}"/*; do
    [ -e "${entry}" ] && PROG_TOTAL=$((PROG_TOTAL + 1))
  done
done

# ═════════════════════════════════════════════════════════════════════════════
# 4. 聚合容器（bash 3.2 无关联数组，用平行数组 + 线性查找）
#    每条路径统一存成 "${kb}<TAB>${path}"，多行即为多条
# ═════════════════════════════════════════════════════════════════════════════

declare -a G_NAME=()     # 组显示名
declare -a G_CONF=()     # high / mid
declare -a G_KB=()       # 合计 KB
declare -a G_MTIME=()    # 最近修改 epoch
declare -a G_ITEMS=()    # 换行分隔的 "kb<TAB>path"
declare -a G_TOKENS=()   # 已用词元（换行分隔）
declare -a G_UNKNOWN=()  # 1 = 未识别

TOTAL_KB=0
N_ITEMS=0
N_UNKNOWN=0
SCANNED=0

add_hit() {  # add_hit <identity> <path> <kb> <mtime> <conf>
  local ident="$1" path="$2" kb="$3" mt="$4" conf="$5"
  local toks; toks=$(tokens_of "${ident}")
  local idx="" i
  for i in "${!G_NAME[@]}"; do
    if [ "${G_UNKNOWN[$i]}" -eq 0 ] && [ -n "${toks}" ] \
       && tokens_related "${toks}" "${G_TOKENS[$i]}"; then
      idx="${i}"; break
    fi
  done

  if [ -z "${idx}" ]; then
    G_NAME+=("${ident}"); G_CONF+=("${conf}"); G_KB+=("${kb}")
    G_MTIME+=("${mt}");   G_ITEMS+=("${kb}	${path}"); G_TOKENS+=("${toks}"); G_UNKNOWN+=(0)
  else
    G_KB[$idx]=$(( ${G_KB[$idx]} + kb ))
    [ "${mt}" -gt "${G_MTIME[$idx]}" ] && G_MTIME[$idx]="${mt}"
    G_ITEMS[$idx]="${G_ITEMS[$idx]}
${kb}	${path}"
    G_TOKENS[$idx]="${G_TOKENS[$idx]}
${toks}"
    # 普通目录名比 bundle id 更适合当组标题
    if [ "${G_CONF[$idx]}" = "mid" ] && [ "${conf}" = "high" ]; then
      case "${ident}" in *.*) : ;; *) G_NAME[$idx]="${ident}" ;; esac
    fi
  fi
}

add_unknown() {  # add_unknown <path> <kb> <mtime>
  G_UNKNOWN+=(1); G_NAME+=("$1"); G_CONF+=("low")
  G_KB+=("$2"); G_MTIME+=("$3"); G_ITEMS+=("$2	$1"); G_TOKENS+=("")
}

# ═════════════════════════════════════════════════════════════════════════════
# 5. 扫描
# ═════════════════════════════════════════════════════════════════════════════

for spec in "${LOCATIONS[@]}"; do
  loc="${spec%%|*}"
  rest="${spec#*|}"
  mode="${rest%%|*}"
  suffix="${rest#*|}"

  [ -d "${loc}" ] || continue
  case "${loc}" in "${HOME}"*) loc_short="~${loc#"${HOME}"}" ;; *) loc_short="${loc}" ;; esac

  for entry in "${loc}"/*; do
    [ -e "${entry}" ] || continue
    progress_tick "${loc_short}"
    name=$(basename "${entry}")

    if [ -n "${suffix}" ]; then
      case "${name}" in
        *".${suffix}") name="${name%".${suffix}"}" ;;
        *) continue ;;
      esac
    fi

    # Group Containers 的形态是 <10 位 team id>.<bundle id>，剥掉 team id 与 "group."
    # ⚠️ 只在这一类位置剥：放在通用位置时，会把 com.google.Keystone.Agent 的前 10 个
    #    字符当 team id 误剥成 Keystone.Agent，导致整个白名单失效
    if [ "${mode}" = "gid" ]; then
      case "${name}" in
        ??????????.*) name="${name#??????????.}" ;;
      esac
      case "${name}" in
        group.*) name="${name#group.}" ;;
      esac
    fi

    [ -n "${name}" ] || continue
    SCANNED=$((SCANNED + 1))

    conf=""; unknown=0
    if is_bundleid_like "${name}"; then
      is_ignored_id "${name}" && continue
      is_ignored_name "${name}" && continue
      is_installed_id "${name}" && continue
      is_installed_id_as_name "${name}" && continue
      conf="high"
    else
      [ "${mode}" = "id" ] && continue
      is_ignored_name "${name}" && continue
      is_installed_name "${name}" && continue
      if printf '%s' "${name}" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]*$' \
         && [ "${#name}" -ge 3 ]; then
        conf="mid"
      else
        unknown=1
      fi
    fi

    kb=$(kb_of "${entry}")
    [ "${kb}" -gt 0 ] || continue

    mt=$(stat -f '%m' "${entry}" 2>/dev/null || echo "${now}")
    case "${mt}" in ''|*[!0-9]*) mt="${now}" ;; esac

    if [ "${MIN_AGE_DAYS}" -gt 0 ]; then
      [ "$(( (now - mt) / 86400 ))" -lt "${MIN_AGE_DAYS}" ] && continue
    fi

    if [ "${unknown}" -eq 1 ]; then
      add_unknown "${entry}" "${kb}" "${mt}"
      N_UNKNOWN=$((N_UNKNOWN + 1))
    else
      add_hit "${name}" "${entry}" "${kb}" "${mt}" "${conf}"
      N_ITEMS=$((N_ITEMS + 1))
    fi
    TOTAL_KB=$((TOTAL_KB + kb))
  done
done

finish_progress

# ═════════════════════════════════════════════════════════════════════════════
# 6. 排序 + 输出
# ═════════════════════════════════════════════════════════════════════════════

declare -a ORDER=()
i=0
while [ "${i}" -lt "${#G_NAME[@]}" ]; do
  if [ "${G_UNKNOWN[$i]}" -eq 0 ] || [ "${SHOW_ALL}" -eq 1 ]; then
    ORDER+=("${i}")
  fi
  i=$((i + 1))
done

# 按体积降序（插入排序，条目量级只有几十）
if [ "${#ORDER[@]}" -gt 1 ]; then
  j=1
  while [ "${j}" -lt "${#ORDER[@]}" ]; do
    key="${ORDER[$j]}"
    k=$((j - 1))
    while [ "${k}" -ge 0 ] && [ "${G_KB[${ORDER[$k]}]}" -lt "${G_KB[${key}]}" ]; do
      ORDER[$((k + 1))]="${ORDER[$k]}"
      k=$((k - 1))
    done
    ORDER[$((k + 1))]="${key}"
    j=$((j + 1))
  done
fi

ui_section "扫描结果"

if [ "${#ORDER[@]}" -eq 0 ]; then
  echo "   没有发现疑似残留。"
  echo
  echo "包含扫描在内，未删除任何文件。"
  exit 0
fi

# 编号固定在排序之后定死：加了关键词筛选也不会变，同一个编号永远指同一条。
declare -a SHOW_IDX=()
declare -a SHOW_NUM=()
k=0
while [ "${k}" -lt "${#ORDER[@]}" ]; do
  idx="${ORDER[$k]}"
  if matches_filters "${G_NAME[$idx]}" "${G_ITEMS[$idx]}"; then
    SHOW_IDX+=("${idx}")
    SHOW_NUM+=("$((k + 1))")
  fi
  k=$((k + 1))
done

if [ "${#SHOW_IDX[@]}" -eq 0 ]; then
  echo "   没有匹配「$(filters_desc)」的项。"
  echo "   去掉关键词即可看到完整清单：bash $0"
  echo
  echo "包含扫描在内，未删除任何文件。"
  exit 0
fi

# TSV 只在显式 --report 时写；写完就 mv 到位，中途 Ctrl-C 由 trap 清掉半截文件
if [ -n "${REPORT_FILE}" ]; then
  TSV_TMP="${REPORT_FILE}.tmp"
  printf 'index	software	confidence	size_kb	last_modified	paths
' > "${TSV_TMP}" 2>/dev/null \
    || { REPORT_FILE=""; TSV_TMP=""; }
fi

SEL_KB=0; SEL_HIGH=0; SEL_MID=0
n=0
while [ "${n}" -lt "${#SHOW_IDX[@]}" ]; do
  idx="${SHOW_IDX[$n]}"
  num="${SHOW_NUM[$n]}"
  label="${G_NAME[$idx]}"
  case "${G_CONF[$idx]}" in
    high) tag="基本确定" ;;
    mid)  tag="待确认" ;;
    *)    tag="归属不明" ;;
  esac
  mtd=$(date -r "${G_MTIME[$idx]}" '+%Y-%m-%d' 2>/dev/null || echo "?")

  printf '
   [%02d] %s
' "${num}" "${label}"
  printf '        %s · 合计 %s · 最近改动 %s
' "${tag}" "$(human "${G_KB[$idx]}")" "${mtd}"

  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    printf '          %8s  %s
' "$(human "${ikb}")" "${ipath}"
  done <<< "${G_ITEMS[$idx]}"

  if [ -n "${TSV_TMP}" ]; then
    printf '%s	%s	%s	%s	%s	%s
' \
      "${num}" "${label}" "${tag}" "${G_KB[$idx]}" "${mtd}" \
      "$(printf '%s' "${G_ITEMS[$idx]}" | cut -f2- | tr '\n' '|')" >> "${TSV_TMP}"
  fi

  SEL_KB=$((SEL_KB + ${G_KB[$idx]}))
  case "${G_CONF[$idx]}" in
    high) SEL_HIGH=$((SEL_HIGH + 1)) ;;
    mid)  SEL_MID=$((SEL_MID + 1)) ;;
  esac
  n=$((n + 1))
done

if [ -n "${TSV_TMP}" ]; then
  if mv "${TSV_TMP}" "${REPORT_FILE}" 2>/dev/null; then
    TSV_TMP=""
  else
    rm -f "${TSV_TMP}" 2>/dev/null
    REPORT_FILE=""
  fi
fi

echo
ui_end
printf '   扫描 %d 个条目，命中 %d 处（合计 %s）
' "${SCANNED}" "${N_ITEMS}" "$(human "${TOTAL_KB}")"
if have_filters; then
  printf '   筛选「%s」：
' "$(filters_desc)"
fi
printf '   共 %d 项（基本确定 %d / 待确认 %d），合计 %s
' \
       "${#SHOW_IDX[@]}" "${SEL_HIGH}" "${SEL_MID}" "$(human "${SEL_KB}")"
printf '   标注意思：基本确定 = 名字是标准软件标识；待确认 = 只是个普通目录名
'
if [ "${SHOW_ALL}" -eq 0 ] && [ "${N_UNKNOWN}" -gt 0 ]; then
  printf '   另有 %d 处归属不明未列出（--all 查看）
' "${N_UNKNOWN}"
fi
[ -n "${REPORT_FILE}" ] && printf '   TSV 报告已存：%s
' "${REPORT_FILE}"

# ── 只扫描模式 / --scan：报告完就结束 ──
if [ "${SCAN_ONLY}" -eq 1 ]; then
  echo
  echo "只扫描模式（--scan）：未删除任何文件。"
  exit 0
fi

# ── 范围闸：裸 --clean 什么都不会动 ──────────────────────────────────────────
# 手滑敲出 --clean 就进全量清理太危险，所以必须显式声明范围：
#   给关键词筛选 ＝ 只清那几项；给 --all ＝ 确认全部都要清。
if [ "${CLEAN}" -eq 1 ] && ! have_filters && [ "${SHOW_ALL}" -eq 0 ]; then
  echo
  echo "⚠️  没有指定范围，本次不会动任何文件。" >&2
  echo "    只清几项：    bash $0 --clean <关键词>          # 多个词用空格或逗号" >&2
  echo "    全部都要清：  bash $0 --clean --all" >&2
  echo "    上面那份报告就是完整清单，照着名字挑关键词即可。" >&2
  exit 2
fi

# ═════════════════════════════════════════════════════════════════════════════
# 7. 交互式清理：列剩余清单 → 选 → 移入废纸篓 → 还有剩余就再问，直到结束
#    「归属不明」的项认不出主人，一律不进候选 —— 哪怕带了 --all
# ═════════════════════════════════════════════════════════════════════════════

# 候选池：显示清单里排除「归属不明」之后的部分
declare -a REM_IDX=()
n=0
while [ "${n}" -lt "${#SHOW_IDX[@]}" ]; do
  idx="${SHOW_IDX[$n]}"
  [ "${G_UNKNOWN[$idx]}" -eq 1 ] || REM_IDX+=("${idx}")
  n=$((n + 1))
done
N_UNKNOWN_SEL=$(( ${#SHOW_IDX[@]} - ${#REM_IDX[@]} ))

if [ "${#REM_IDX[@]}" -eq 0 ]; then
  echo
  echo "没有可处理的项。"
  [ "${N_UNKNOWN_SEL}" -gt 0 ] && echo "（选中的都是「归属不明」项 —— 认不出属于谁，脚本不替你动。）"
  exit 0
fi

render_brief() {  # render_brief <显示编号> <内部索引>
  printf '   [%02d] %8s  %s  ·  %s
' "$1" "$(human "${G_KB[$2]}")" "${G_NAME[$2]}" \
         "$([ "${G_CONF[$2]}" = "high" ] && echo '基本确定' || echo '待确认')"
}

render_paths() {  # render_paths <内部索引>
  local item ikb ipath
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    printf '          %8s  %s
' "$(human "${ikb}")" "${ipath}"
  done <<< "${G_ITEMS[$1]}"
}

move_group() {  # move_group <内部索引> → 全部成功返回 0，否则 1
  local idx="$1" item ikb ipath gfail=0
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    if trash_path "${ipath}"; then
      FREED_KB=$((FREED_KB + ikb))   # 移入成功才计入释放空间
      printf '   [废纸篓] %s
' "${ipath}"
    else
      printf '   [失败]   %s
' "${ipath}"
      gfail=$((gfail + 1))
    fi
  done <<< "${G_ITEMS[$idx]}"
  [ "${gfail}" -eq 0 ]
}

declare -a CHOSEN=()
declare -a UNIQ_NUMS=()
CHOICE_NUMS=()
ACT=""
ok=0; fail=0; moved_paths=0; round=0; FREED_KB=0

while [ "${#REM_IDX[@]}" -gt 0 ]; do
  round=$((round + 1))

  rem_kb=0
  for i in "${REM_IDX[@]}"; do rem_kb=$((rem_kb + ${G_KB[$i]})); done

  ui_section "第 ${round} 轮 · 待处理 ${#REM_IDX[@]} 项 / 合计 $(human "${rem_kb}")（编号以本轮为准）"
  n=0
  for i in "${REM_IDX[@]}"; do
    n=$((n + 1))
    render_brief "${n}" "${i}"
  done
  if [ "${N_UNKNOWN_SEL}" -gt 0 ]; then
    printf '   · 另有 %d 处「归属不明」不在候选里 —— 认不出属于谁，脚本不替你动
' "${N_UNKNOWN_SEL}"
  fi

  # --yes（必须带筛选）：跳过交互，直接处理全部
  if [ "${ASSUME_YES}" -eq 1 ] && [ "${round}" -eq 1 ]; then
    ACT="all"; CHOSEN=( ${REM_IDX[@]+"${REM_IDX[@]}"} )
  else
    select_prompt "${#REM_IDX[@]}"
    ans=""
    read -r ans || ans=""
    if ! parse_choice "${ans}" "${#REM_IDX[@]}"; then
      echo "   看不懂这个输入（可用：yes / 编号 / 1-4 / 1,3 / pick / q）。本次没有处理任何项。"
      continue
    fi
    case "${ACT}" in
      cancel)
        echo "   结束，未处理的项原样不动。"
        break ;;
      all)
        CHOSEN=( ${REM_IDX[@]+"${REM_IDX[@]}"} ) ;;
      pick)
        CHOSEN=()
        n=0
        for i in "${REM_IDX[@]}"; do
          n=$((n + 1))
          printf '
   [%02d] %8s  %s  ·  %s
' "${n}" "$(human "${G_KB[$i]}")" \
                 "${G_NAME[$i]}" \
                 "$([ "${G_CONF[$i]}" = "high" ] && echo '基本确定' || echo '待确认')"
          render_paths "${i}"
          printf '      移入废纸篓？[y/N/s/q] '
          a2=""
          read -r a2 || a2="q"
          case "${a2}" in
            y|Y) CHOSEN+=("${i}") ;;
            q|Q) echo "      结束逐项确认。"; break ;;
            s|S)
              # ⚠️ 先把路径收进数组：`while read ... done <<< "值"` 的重定向作用于
              #    整个循环体，循环体里的交互 read 会去读 herestring（已 EOF）而不是
              #    用户输入 —— 收进数组后用 for 遍历，read 才能正常读 stdin。
              declare -a sp=()
              while IFS= read -r item; do
                [ -n "${item}" ] || continue
                sp+=("${item#*	}")
              done <<< "${G_ITEMS[$i]}"
              for ipath in ${sp[@]+"${sp[@]}"}; do
                printf '        %s ? [y/N] ' "${ipath}"
                a3=""
                read -r a3 || a3="n"
                case "${a3}" in
                  y|Y) one_kb=$(kb_of "${ipath}")
                       if trash_path "${ipath}"; then
                         FREED_KB=$((FREED_KB + one_kb))
                         printf '          [废纸篓] 已移入
'; moved_paths=$((moved_paths + 1))
                       else
                         printf '          [失败]   无法移动（可能需要权限）
'; fail=$((fail + 1))
                       fi ;;
                esac
              done
              # 逐条处理完也算处理过（已移走的不再重复出现在剩余清单里）
              CHOSEN+=("${i}")
              ;;
            *) echo "      跳过" ;;
          esac
        done ;;
      some)
        CHOSEN=()
        dedupe_nums ${CHOICE_NUMS[@]+"${CHOICE_NUMS[@]}"}
        n=0
        for i in "${REM_IDX[@]}"; do
          n=$((n + 1))
          for one in ${UNIQ_NUMS[@]+"${UNIQ_NUMS[@]}"}; do
            [ "${one}" = "${n}" ] && CHOSEN+=("${i}") && break
          done
        done ;;
    esac
  fi

  [ "${#CHOSEN[@]}" -gt 0 ] || continue

  # ── 执行 ──
  ui_section "移入废纸篓"
  declare -a NEXT_REM=()
  moved_now=0
  for i in "${REM_IDX[@]}"; do
    hit=0
    for c in "${CHOSEN[@]}"; do
      [ "${c}" = "${i}" ] && hit=1 && break
    done
    if [ "${hit}" -eq 1 ]; then
      printf ' [%s] %s  ·  %s
' "$([ "${G_CONF[$i]}" = "high" ] && echo '基本确定' || echo '待确认')" \
             "${G_NAME[$i]}" "$(human "${G_KB[$i]}")"
      if move_group "${i}"; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
      moved_now=$((moved_now + 1))
      echo
    else
      NEXT_REM+=("${i}")
    fi
  done
  REM_IDX=( ${NEXT_REM[@]+"${NEXT_REM[@]}"} )
  echo "   本轮处理 ${moved_now} 项；剩余待处理 ${#REM_IDX[@]} 项"
done

# ── 收尾 ──
ui_section "结果"
printf '   成功 %d 项，失败 %d 项，剩余未处理 %d 项
' "${ok}" "${fail}" "${#REM_IDX[@]}"
if [ "${moved_paths}" -gt 0 ]; then
  printf '   其中逐条确认移入 %d 个文件
' "${moved_paths}"
fi
if [ "${FREED_KB}" -gt 0 ]; then
  printf '   移入废纸篓合计 %s
' "$(human "${FREED_KB}")"
fi
if [ "${ok}" -gt 0 ] || [ "${moved_paths}" -gt 0 ]; then
  printf '   这些内容现在在 %s/.Trash 里，可随时拖回；清空废纸篓后磁盘空间才真正释放。
' "${HOME}"
else
  printf '   未移动任何文件。
'
fi
ui_end
