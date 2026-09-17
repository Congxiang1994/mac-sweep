#!/usr/bin/env bash
#
# uninstall-residue.sh — 找出已卸载 macOS 软件遗留的残留数据
#
# ─────────────────────────────────────────────────────────────────────────────
# 默认【只扫描、只报告，一个文件都不删】。加 --clean 才进入逐项确认的清理。
#
# 判定思路：
#   1. 收集当前系统真正装着哪些 App —— /Applications、/System/Applications、
#      Utilities、~/Applications、输入法目录 —— 取出它们的 bundle id、App 名、
#      以及 bundle id 里的组织段（com.<org>.<app> 的 <org>）；
#   2. 遍历 ~/Library 下最容易堆积残留的位置（Application Support / Caches /
#      Preferences / Containers / LaunchAgents / Logs / Saved Application State …）；
#   3. 任何「名字是标准 bundle id，或是某个软件的名字，却在已装 App 里找不到
#      对应物」的条目，判为疑似残留；
#   4. 把同一软件的散落残留聚合成一条，给出路径、体积、最后修改时间。
#
# 置信度：
#   高     — 名字是标准 bundle id 形式，且无任何已装 App 与之匹配
#   待确认 — 名字是普通目录名（如 Docker Desktop），且无已装 App 与之匹配
#   未识别 — 归属不到任何软件名，可能只是系统/开发工具目录（默认不显示，--all 才列出）
#
# 用法：
#   ./uninstall-residue.sh                 # 扫描并输出报告（不删任何东西）
#   ./uninstall-residue.sh --all           # 额外显示「未识别」项
#   ./uninstall-residue.sh --system        # 额外扫描 /Library（只读；清理需 sudo）
#   ./uninstall-residue.sh --min-age 180   # 只看 180 天以上没被动过的
#   ./uninstall-residue.sh --clean         # 扫描后逐项询问，确认的移入废纸篓
#   ./uninstall-residue.sh --report /tmp/r.tsv
#
# 可调环境变量：
#   EXTRA_APP_DIRS  额外参与「已装 App 指纹」的目录，冒号分隔（App 装在非常规位置时用）
#   HOME            用户主目录（测试时指向隔离目录）
#
# ⚠️ 清理走的是「移入废纸篓」（mv 到 ~/.Trash），不是 rm，随时可以拖回来。
# ─────────────────────────────────────────────────────────────────────────────
set -u
# ⚠️ 约定：变量引用一律写 ${var}，绝不写裸 $var。
#    原因：bash 在 UTF-8 locale 下会把紧跟其后的多字节字符（如全角「（」）吞进变量名，
#    在 C locale 下却不会 —— 同一份脚本不同终端行为不同，极难复现。大括号可彻底杜绝。

CLEAN=0
SHOW_ALL=0
SCAN_SYSTEM=0
MIN_AGE_DAYS=0
REPORT_FILE=""

while [ "$#" -gt 0 ]; do
  arg="$1"; shift
  case "${arg}" in
    --clean)      CLEAN=1 ;;
    --all)        SHOW_ALL=1 ;;
    --system)     SCAN_SYSTEM=1 ;;
    --min-age)    MIN_AGE_DAYS="${1:-0}"; shift || true ;;
    --report)     REPORT_FILE="${1:-}"; shift || true ;;
    -h|--help)    sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "未知参数: ${arg}（-h 查看用法）" >&2; exit 2 ;;
  esac
done

case "${MIN_AGE_DAYS}" in ''|*[!0-9]*) MIN_AGE_DAYS=0 ;; esac

LIB="${HOME}/Library"
[ -d "${LIB}" ] || { echo "找不到 ${LIB}" >&2; exit 1; }

now=$(date +%s)
if [ -z "${REPORT_FILE}" ]; then
  REPORT_FILE="./uninstall-residue-$(date +%Y%m%d-%H%M%S).tsv"
fi
TSV_TMP=""
# 中途 Ctrl-C 也不会留下半截报告
trap 'rm -f "${TSV_TMP}" 2>/dev/null' EXIT INT TERM

MAX_DELETE_PER_RUN=10   # --clean 单次最多处置多少项，防手滑

# ═════════════════════════════════════════════════════════════════════════════
# 通用工具
# ═════════════════════════════════════════════════════════════════════════════

id_lc() { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z'; }                        # 小写，保留点
norm()  { printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -dc 'a-z0-9'; }  # 只留 a-z0-9

human() {  # KB → 人类可读（纯 bash，避免每条路径都 fork 一个 awk）
  local kb="${1:-0}"
  case "${kb}" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "${kb}" -ge 1048576 ]; then
    printf '%d.%dG' "$((kb / 1048576))" "$(( (kb % 1048576) * 10 / 1048576 ))"
  elif [ "${kb}" -ge 1024 ]; then
    printf '%d.%dM' "$((kb / 1024))" "$(( (kb % 1024) * 10 / 1024 ))"
  else
    printf '%dK' "${kb}"
  fi
}

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
N_HIGH=0
N_MID=0
N_UNKNOWN=0
SCANNED=0

kb_of() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | cut -f1 | tr -dc '0-9')
  echo "${kb:-0}"
}

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

echo "已卸载软件残留扫描 · $(date '+%Y-%m-%d %H:%M')"
echo "已装 App 指纹：${#INS_NAMES[@]} 个名字 / ${#INS_IDS[@]} 个 bundle id"
echo "模式：$([ "${CLEAN}" -eq 1 ] && echo '扫描 + 逐项确认清理' || echo '只扫描，不删除任何文件')"
echo "扫描中…"

for spec in "${LOCATIONS[@]}"; do
  loc="${spec%%|*}"
  rest="${spec#*|}"
  mode="${rest%%|*}"
  suffix="${rest#*|}"

  [ -d "${loc}" ] || continue

  for entry in "${loc}"/*; do
    [ -e "${entry}" ] || continue
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
      if [ "${conf}" = "high" ]; then N_HIGH=$((N_HIGH + 1)); else N_MID=$((N_MID + 1)); fi
    fi
    TOTAL_KB=$((TOTAL_KB + kb))
    N_ITEMS=$((N_ITEMS + 1))
  done
done

echo "扫描 ${SCANNED} 个条目，命中 ${N_ITEMS} 个。"
echo

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

echo "================ 疑似残留（按软件聚合）================"
echo

if [ "${#ORDER[@]}" -eq 0 ]; then
  echo "没有发现疑似残留。"
  echo
  exit 0
fi

TSV_TMP=""
if [ -n "${REPORT_FILE}" ]; then
  TSV_TMP="${REPORT_FILE}.tmp"
  printf 'index\tsoftware\tconfidence\tsize_kb\tlast_modified\tpaths\n' > "${TSV_TMP}" 2>/dev/null \
    || { REPORT_FILE=""; TSV_TMP=""; }
fi

n=0
for idx in "${ORDER[@]}"; do
  n=$((n + 1))
  label="${G_NAME[$idx]}"
  case "${G_CONF[$idx]}" in
    high) tag="高置信" ;;
    mid)  tag="待确认" ;;
    *)    tag="未识别" ;;
  esac
  mtd=$(date -r "${G_MTIME[$idx]}" '+%Y-%m-%d' 2>/dev/null || echo "?")

  printf '[%02d] %s\n' "${n}" "${label}"
  printf '     %s · 合计 %s · 最近改动 %s\n' "${tag}" "$(human "${G_KB[$idx]}")" "${mtd}"

  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    ikb="${item%%	*}"
    ipath="${item#*	}"
    printf '       %8s  %s\n' "$(human "${ikb}")" "${ipath}"
  done <<< "${G_ITEMS[$idx]}"
  echo

  if [ -n "${TSV_TMP}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${n}" "${label}" "${tag}" "${G_KB[$idx]}" "${mtd}" \
      "$(printf '%s' "${G_ITEMS[$idx]}" | cut -f2- | tr '\n' '|')" >> "${TSV_TMP}"
  fi
done

if [ -n "${TSV_TMP}" ]; then
  if mv "${TSV_TMP}" "${REPORT_FILE}" 2>/dev/null; then
    TSV_TMP=""
  else
    rm -f "${TSV_TMP}" 2>/dev/null
    REPORT_FILE=""
  fi
fi

echo "------------------------------------------------------"
printf '共 %d 项（高置信 %d / 待确认 %d），合计 %s' \
       "${N_ITEMS}" "${N_HIGH}" "${N_MID}" "$(human "${TOTAL_KB}")"
if [ "${SHOW_ALL}" -eq 0 ] && [ "${N_UNKNOWN}" -gt 0 ]; then
  printf '；另有 %d 项归属不明未列出（--all 查看）' "${N_UNKNOWN}"
fi
echo
[ -n "${REPORT_FILE}" ] && echo "TSV 报告已存：${REPORT_FILE}"
echo

# ═════════════════════════════════════════════════════════════════════════════
# 7. 清理（可选）—— 移入废纸篓，不真删
# ═════════════════════════════════════════════════════════════════════════════

trash_path() {
  local p="$1" base dest trash="${HOME}/.Trash"
  mkdir -p "${trash}" 2>/dev/null || return 1
  base=$(basename "${p}")
  dest="${trash}/${base}"
  [ -e "${dest}" ] && dest="${trash}/${base} $(date +%Y%m%d-%H%M%S)"
  mv "${p}" "${dest}" 2>/dev/null
  [ -e "${p}" ] && return 1
  return 0
}

if [ "${CLEAN}" -ne 1 ]; then
  echo "以上仅为报告，未删除任何文件。"
  echo "确认无误后运行：  bash $0 --clean"
  exit 0
fi

echo "================ 逐项确认 ================"
echo "y=移入废纸篓  n=整组跳过  s=逐条挑选  q=退出（单次上限 ${MAX_DELETE_PER_RUN} 项）"
echo

deleted=0; skipped=0; failed=0; touched=0
for idx in "${ORDER[@]}"; do
  [ "${G_UNKNOWN[$idx]}" -eq 1 ] && continue
  [ "${touched}" -ge "${MAX_DELETE_PER_RUN}" ] && break

  echo "── ${G_NAME[$idx]}  ·  $(human "${G_KB[$idx]}")  ·  $([ "${G_CONF[$idx]}" = "high" ] && echo '高置信' || echo '待确认')"
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    echo "     ${item#*	}"
  done <<< "${G_ITEMS[$idx]}"

  printf '   移入废纸篓？[y/N/s/q] '
  read -r ans || ans="q"
  case "${ans}" in
    y|Y)
      while IFS= read -r item; do
        [ -n "${item}" ] || continue
        [ "${touched}" -ge "${MAX_DELETE_PER_RUN}" ] && break
        p="${item#*	}"
        if trash_path "${p}"; then
          echo "     [废纸篓] ${p}"; deleted=$((deleted + 1))
        else
          echo "     [失败]   ${p}"; failed=$((failed + 1))
        fi
        touched=$((touched + 1))
      done <<< "${G_ITEMS[$idx]}"
      ;;
    s|S)
      while IFS= read -r item; do
        [ -n "${item}" ] || continue
        [ "${touched}" -ge "${MAX_DELETE_PER_RUN}" ] && break
        p="${item#*	}"
        printf '     %s ? [y/N] ' "${p}"
        read -r a2 || a2="n"
        case "${a2}" in
          y|Y)
            if trash_path "${p}"; then
              echo "       [废纸篓] 已移入"; deleted=$((deleted + 1))
            else
              echo "       [失败]   无法移动（可能需要权限）"; failed=$((failed + 1))
            fi
            touched=$((touched + 1))
            ;;
        esac
      done <<< "${G_ITEMS[$idx]}"
      ;;
    q|Q)
      echo "已退出。"; break
      ;;
    *)
      skipped=$((skipped + 1)) ;;
  esac
  echo
done

echo "------------------------------------------------------"
printf '移入废纸篓 %d 项，整组跳过 %d 组，失败 %d 项\n' "${deleted}" "${skipped}" "${failed}"
echo "全在废纸篓里，确认无误后再清空；拖回来即可还原。"
