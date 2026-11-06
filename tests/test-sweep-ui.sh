#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sweep-ui.sh 回归测试 —— 统一视觉层（色彩开关 / 版式 / 列对齐）
#
# 关键约定（回归点）：
#   1) 默认（管道 / 重定向 / NO_COLOR）→ 输出**纯文本**，不含任何 ANSI 转义
#   2) SWEEP_COLOR=always / FORCE_COLOR=1 → 必须带 ANSI 色彩
#   3) SWEEP_COLOR=never / NO_COLOR → 即使是 TTY 也不上色
#   4) 颜色必须只影响「装饰」，不能把文案拆散（grep 断言必须仍然成立）
#   5) 中英文混排的列必须按**显示宽度**对齐（CJK 占 2 列）
#   6) 每个组件单独输出时不能多行/少行（printf 占位符配对的老 bug）
#
# 用法: bash tests/test-sweep-ui.sh
# ─────────────────────────────────────────────────────────────────────────────
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UI="${ROOT}/sweep-ui.sh"
[ -f "${UI}" ] || { echo "找不到 UI 层: ${UI}" >&2; exit 1; }

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

# ── 在隔离子 shell 里跑一段 bash，返回 stdout ────────────────────────────────
ui_run() {  # ui_run <环境赋值...> -- <bash 代码>
  local envs="$1"; shift
  [ "$1" = "--" ] && shift
  env -u NO_COLOR -u FORCE_COLOR -u SWEEP_COLOR $envs \
    /bin/bash -c "source '${UI}'; $1" 2>&1
}

# ── ANSI 转义探测 ───────────────────────────────────────────────────────────
has_ansi() {  # has_ansi <文本>
  case "$1" in
    *$'\033['*) return 0 ;;
    *) return 1 ;;
  esac
}
no_ansi() {  # no_ansi <文本>
  case "$1" in
    *$'\033['*) return 1 ;;
    *) return 0 ;;
  esac
}

echo "════════ sweep-ui 视觉层回归测试 ════════"
echo "脚本: ${UI}"

# ═════════════════════════════════════════════════════════════════════════════
# A. 颜色开关
# ═════════════════════════════════════════════════════════════════════════════
CASE="颜色开关"
out=$(ui_run "" -- 'echo "[$(ui_banner "标题")]"; echo "[$(ui_item 01 4K 名称)]"')
no_ansi "${out}" && ok "默认无色：输出不含 ANSI 转义" || bad "默认输出里有 ANSI 转义"
has "${out}" "标题" "默认输出保留文案"

CASE="颜色开关"
out=$(ui_run "SWEEP_COLOR=always" -- 'ui_item 01 4K 名称')
has_ansi "${out}" && ok "SWEEP_COLOR=always 上色" || bad "SWEEP_COLOR=always 没上色"
has "${out}" "名称" "上色后文案仍完整可 grep"

CASE="颜色开关"
out=$(ui_run "FORCE_COLOR=1" -- 'ui_item 01 4K 名称')
has_ansi "${out}" && ok "FORCE_COLOR=1 上色" || bad "FORCE_COLOR=1 没上色"

CASE="颜色开关"
out=$(ui_run "NO_COLOR=1" -- 'ui_item 01 4K 名称')
no_ansi "${out}" && ok "NO_COLOR 生效：无色" || bad "NO_COLOR 没生效"

CASE="颜色开关"
out=$(ui_run "SWEEP_COLOR=never" -- 'ui_item 01 4K 名称')
no_ansi "${out}" && ok "SWEEP_COLOR=never 无色" || bad "SWEEP_COLOR=never 仍有色"

CASE="颜色开关"
# NO_COLOR 优先级最高：即便 FORCE_COLOR=1 也不该上色
out=$(ui_run "NO_COLOR=1 FORCE_COLOR=1" -- 'ui_item 01 4K 名称')
no_ansi "${out}" && ok "NO_COLOR 优先于 FORCE_COLOR" || bad "NO_COLOR 未优先"

CASE="颜色开关"
# SWEEP_COLOR=always 覆盖 NO_COLOR（显式指定优先）
out=$(ui_run "NO_COLOR=1 SWEEP_COLOR=always" -- 'ui_item 01 4K 名称')
has_ansi "${out}" && ok "SWEEP_COLOR=always 覆盖 NO_COLOR" || bad "SWEEP_COLOR=always 未覆盖 NO_COLOR"

# ═════════════════════════════════════════════════════════════════════════════
# B. 组件单行性（printf 占位符配对的老 bug）
# ═════════════════════════════════════════════════════════════════════════════
CASE="组件单行性"
for comp in 'ui_banner "标题"' \
            'ui_kv "键" "值"' \
            'ui_rule' \
            'ui_note "旁注"' \
            'ui_warn "警告"' \
            'ui_ok "成功"' \
            'ui_item "01" "4K" "名称"' \
            'ui_item_cat "02" "4K" "名称" "类别"' \
            'ui_path "~/a/b"' \
            'ui_hint_kv "yes" "全部"' \
            'ui_sum "前缀" "数字"' \
            'ui_done "完成"' \
            'ui_muted "说明"' \
            'ui_error "错误"'; do
  out=$(ui_run "" -- "${comp}")
  lines=$(printf '%s\n' "${out}" | wc -l | tr -d ' ')
  eq "${lines}" "1" "${comp} 应只输出 1 行"
done

# ui_cat / ui_section 是唯一的多行组件（前面带一个空行做视觉分隔），
# 但它们自身的内容行数必须固定，否则说明格式串写坏了
CASE="组件多行"
out=$(ui_run "" -- 'ui_cat "类别"')
lines=$(printf '%s\n' "${out}" | grep -c . )
eq "${lines}" "1" "ui_cat 内容行恰好 1 行（外加 1 个分隔空行）"

CASE="组件多行"
out=$(ui_run "" -- 'ui_section "分节"')
lines=$(printf '%s\n' "${out}" | grep -c . )
eq "${lines}" "2" "ui_section 内容行恰好 2 行（标题 + 下划线）"

# ═════════════════════════════════════════════════════════════════════════════
# C. 显示宽度与列对齐（CJK 占 2 列）
# ═════════════════════════════════════════════════════════════════════════════
CASE="显示宽度"
out=$(ui_run "" -- 'disp_width "abc"')
eq "${out}" "3" "纯 ASCII 宽度 = 字符数"

CASE="显示宽度"
out=$(ui_run "" -- 'disp_width "数据目录"')
eq "${out}" "8" "4 个汉字宽度 = 8 列"

CASE="显示宽度"
out=$(ui_run "" -- 'disp_width "VSCODE_HOME"')
eq "${out}" "11" "英文键名宽度 = 字符数"

CASE="显示宽度"
out=$(ui_run "" -- 'disp_width ""')
eq "${out}" "0" "空串宽度 = 0"

CASE="列对齐"
# 两个键名一个中文一个英文，补白后显示宽度必须一致
out=$(ui_run "" -- 'disp_width "$(pad "数据目录" 13)"')
eq "${out}" "13" "中文键名补白到 13 列"

CASE="列对齐"
out=$(ui_run "" -- 'disp_width "$(pad "VSCODE_HOME" 13)"')
eq "${out}" "13" "英文键名补白到 13 列"

CASE="列对齐"
# 超宽内容不该被截断（pad 只补白不裁剪）
out=$(ui_run "" -- 'disp_width "$(pad "非常非常长的中文键名" 5)"')
eq "${out}" "20" "超宽文本保持原样不裁剪"

# ═════════════════════════════════════════════════════════════════════════════
# D. 颜色不破坏文案可 grep 性
# ═════════════════════════════════════════════════════════════════════════════
CASE="文案完整性"
out=$(ui_run "SWEEP_COLOR=always" -- 'ui_item "01" "888K" "Caches/Google/Chrome/Default/Cache"')
has "${out}" "Caches/Google/Chrome/Default/Cache" "上色后路径完整可 grep"
has "${out}" "888K" "上色后大小完整可 grep"
has "${out}" "01" "上色后编号完整可 grep"

CASE="文案完整性"
out=$(ui_run "SWEEP_COLOR=always" -- 'ui_warn "Chrome 正在运行"')
has "${out}" "Chrome 正在运行" "上色后警告文案完整可 grep"

CASE="文案完整性"
out=$(ui_run "SWEEP_COLOR=always" -- 'ui_sum "命中" "2 项 / 合计 884K"')
has "${out}" "2 项 / 合计 884K" "上色后摘要完整可 grep"

CASE="文案完整性"
out=$(ui_run "SWEEP_COLOR=always" -- 'ui_error "没有指定范围，本次不会动任何文件。"')
has "${out}" "没有指定范围" "上色后错误文案完整可 grep"

# ═════════════════════════════════════════════════════════════════════════════
# E. 真实脚本：无色时输出纯净、上色时才有 ANSI
# ═════════════════════════════════════════════════════════════════════════════
CASE="脚本集成"
FIX=$(mktemp -d "${TMPDIR:-/tmp}/sweep-ui-test.XXXXXX")
SUP="${FIX}/home/Library/Application Support/Google/Chrome"
CACHE="${FIX}/home/Library/Caches/Google/Chrome"
mkdir -p "${SUP}/Default/Cache" "${CACHE}/Default"
head -c 4096 /dev/zero > "${SUP}/Default/Cache/x.bin"

run_chrome() {  # run_chrome <环境赋值...>
  local envs="$1"; shift
  env -u NO_COLOR -u FORCE_COLOR -u SWEEP_COLOR $envs \
    HOME="${FIX}/home" CHROME_SUP_DIR="${SUP}" CHROME_CACHE_DIR="${CACHE}" \
    /bin/bash "${ROOT}/chrome-sweep.sh" --scan 2>&1
}

out=$(run_chrome "")
no_ansi "${out}" && ok "chrome 默认输出纯净（无 ANSI）" || bad "chrome 默认输出含 ANSI 转义"
has "${out}" "扫描结果" "chrome 输出保留关键文案"

out=$(run_chrome "FORCE_COLOR=1")
has_ansi "${out}" && ok "chrome 在 FORCE_COLOR=1 时带色" || bad "chrome 在 FORCE_COLOR=1 时无色"
has "${out}" "扫描结果" "chrome 上色后文案仍完整"

out=$(run_chrome "NO_COLOR=1")
no_ansi "${out}" && ok "chrome 在 NO_COLOR=1 时无色" || bad "chrome 在 NO_COLOR=1 时仍有色"

# 上色输出里不应出现「半个 ANSI 序列」残留
out=$(run_chrome "FORCE_COLOR=1")
case "${out}" in
  *$'\033[0m'*) ok "上色输出以 C_RESET 收尾" ;;
  *) bad "上色输出缺少 C_RESET 收尾" ;;
esac

/bin/rm -rf "${FIX}"

echo
echo "════════════════ 结果 ════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败清单:${FAILED_NAMES}"
  exit 1
fi
echo "全部通过 ✓"
