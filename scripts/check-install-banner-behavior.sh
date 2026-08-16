#!/usr/bin/env bash
# 安装 / 迁移「结尾横幅」行为门：把 simple-deploy.sh 和 migrate-from-official.sh 的
# 结尾横幅代码块原样抽出来，接一个真 postgres 跑两遍，断言「旧版对账视图没删掉」这件事
# 真的会把横幅从绿色变成待办，而且后果原文真的印在横幅里。
#
# 为什么静态门不够（2026-08-16 实测）：
# scripts/check-sql-trio.sh 里那道静态契约钉的是「LEGACY_VIEW_PENDING 这个变量出现过、
# 被置过 1、结尾在主流程里被读过」。它能拦住**删除**型回归（把记账整段删掉），拦不住
# **中和**型——把 simple-deploy.sh 结尾横幅条件里的
#     [ "$LEGACY_VIEW_PENDING" -eq 0 ]   改成   [ "$LEGACY_VIEW_PENDING" -ge 0 ]
# （永真，很像手滑或重构失误），变量照样出现、照样被读，静态门全绿；而真实输出在
# LEGACY_VIEW_PENDING=1 时又变回了绿色的「✅ 安装完成！」，警告消失。极性翻转
# （-eq 0 → -eq 1）同理。
# 而那段**后果原文**（4.1.1 / 反复重启 / 「重跑一次本脚本」指引）此前根本没有任何门钉住。
#
# scripts/upgrade.sh 那条路径有 scripts/check-upgrade-warn-banner.sh 真跑整段兜着；
# 另外两个脚本是 curl | bash 的单文件脚本，整段跑起来要真改用户的 docker-compose.yml、
# 拉镜像、切 grafana，没法在一道 lint 门里安全复现。所以这道门只抽「结尾横幅」这一段
# 加上「读提示、记账」那一段，用真库把两头连起来跑——缺陷正好长在这两头之间的连线上。
#
# 抽取方式：按函数名 / 语法结构定位，**不硬编码行号**（行号一漂就会静默抽错东西）。
# 任何一处定位不到，这道门直接报「定位失败」变红，绝不静默跳过。
#
# 用法：bash scripts/check-install-banner-behavior.sh
# 依赖：docker、python3
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
# 容器名**故意**不匹配 scripts/lib/detect-containers.sh 里那两条正则
# （teslamate.*database|teslamate.*postgres / teslamate.*grafana|^grafana$）：
# 这道门是把容器名直接喂给被测代码的，不需要被"检测"到；名字撞上那两条正则，反而会让
# 同一台机器上别的脚本把这个一次性夹具当成用户的真容器。
CONTAINER="tmcn-banner-fixture-$$"
MARKER="___TMCN_BANNER_BEGIN___"
# 夹具提示语**故意不含**任何一个横幅断言用的关键词（4.1.1 / 反复重启 / 留了一个尾巴 /
# 必须你亲自处理 / 重跑一次本脚本）。这样那些词只可能来自结尾横幅本身，不会被库里这句
# 提示"借"给横幅，制造假绿。
FIXTURE_NOTE="⚠ [门夹具] 数据库里还留着旧版建的对账视图 charging_processes_v，这次没能删掉。"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-banner-behavior.XXXXXX") || exit 1
FAIL=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -r -- "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    echo "❌ $1"
    exit 1
}

# ---------------------------------------------------------------------------
# 抽取器：按结构定位三段代码，写进 $2 目录
#   warnfn.sh   print_legacy_view_warning 函数定义
#   note.sh     读 tou_settings.view_rebuild_note → 置 LEGACY_VIEW_PENDING 的那个分支
#   bannerN.sh  第 N 处结尾横幅（if 条件里出现 LEGACY_VIEW_PENDING 的那个块 + 紧跟的
#               print_legacy_view_warning / 告警项行）
# stdout 打 `COUNT <n>` 和每处横幅的 `ANCHOR <n> <行号>`，失败一律 exit 1 并说明定位失败。
# ---------------------------------------------------------------------------
extract_regions() {
    python3 - "$1" "$2" <<'PY'
import re
import sys
from pathlib import Path

src, outdir = sys.argv[1], sys.argv[2]
lines = Path(src).read_text(encoding='utf-8').split('\n')


def fail(msg):
    print(f'定位失败（{src}）：{msg}')
    raise SystemExit(1)


def is_comment(line):
    return line.lstrip().startswith('#')


def block_end(start):
    """start = 一行 `if ...`，返回配对 `fi` 的下标。"""
    depth = 0
    for i in range(start, len(lines)):
        if is_comment(lines[i]):
            continue
        s = lines[i].strip()
        # 这个抽取器只认 if/elif/else/fi。出现别的复合语句说明源码形状变了，
        # 宁可当场报定位失败让人来改抽取器，也不要按错误的括号配对抽出半截代码。
        if re.match(r'^(case|for|while|until|select)\b', s):
            fail(f'第 {i + 1} 行出现抽取器不支持的复合语句「{s[:40]}」，请更新抽取器而不是放行')
        if re.match(r'^if\b', s):
            depth += 1
        elif s in ('fi', 'fi;'):
            depth -= 1
            if depth == 0:
                return i
    fail(f'第 {start + 1} 行的 if 找不到配对的 fi')


def write(name, first, last):
    Path(outdir, name).write_text('\n'.join(lines[first:last + 1]) + '\n', encoding='utf-8')
    return '\n'.join(lines[first:last + 1])


regions = []

# --- ① print_legacy_view_warning 函数定义 --------------------------------
fn = [i for i, line in enumerate(lines)
      if re.match(r'^print_legacy_view_warning\(\)\s*\{', line)]
if len(fn) != 1:
    fail(f'期望恰好 1 个 print_legacy_view_warning 函数定义，实际 {len(fn)} 个')
fn_end = next((i for i in range(fn[0] + 1, len(lines)) if lines[i] == '}'), None)
if fn_end is None:
    fail('print_legacy_view_warning 的函数体没有第 0 列的 } 收尾')
regions.append(('warnfn.sh', write('warnfn.sh', fn[0], fn_end)))

# --- ② 读 view_rebuild_note → 记账的那个分支 ------------------------------
q = [i for i, line in enumerate(lines)
     if re.search(r'SELECT\s+view_rebuild_note\s+FROM\s+tou_settings', line, re.I)]
if len(q) != 1:
    fail(f'期望恰好 1 处 view_rebuild_note 查询，实际 {len(q)} 处')
qi = q[0]
note_start = None
for i in range(qi, max(-1, qi - 6), -1):
    if re.match(r'^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(', lines[i]):
        note_start = i
        break
if note_start is None:
    fail('找不到 view_rebuild_note 那句查询所属的赋值起点')
note_if = None
for i in range(qi + 1, min(len(lines), qi + 6)):
    if not is_comment(lines[i]) and re.match(r'^if\b', lines[i].strip()):
        note_if = i
        break
if note_if is None:
    fail('view_rebuild_note 查询之后没有紧跟着的 if 分支')
note_body = write('note.sh', note_start, block_end(note_if))
if 'LEGACY_VIEW_PENDING=1' not in note_body:
    fail('读到 view_rebuild_note 的分支里没有 LEGACY_VIEW_PENDING=1——提示只打印、没记账')
regions.append(('note.sh', note_body))

# --- ③ 结尾横幅：if 条件里出现 LEGACY_VIEW_PENDING 的块 + 紧跟的横幅尾巴 ----
anchors = [i for i, line in enumerate(lines)
           if re.match(r'^if\b', line.strip()) and 'LEGACY_VIEW_PENDING' in line]
if not anchors:
    fail('没有任何 if 条件读 LEGACY_VIEW_PENDING——结尾横幅不会因它变色')

TAIL_MAX = 12
print(f'COUNT {len(anchors)}')
for n, a in enumerate(anchors, start=1):
    end = block_end(a)
    # 横幅尾巴：紧跟其后、仍属于同一段横幅的语句（print_legacy_view_warning 调用、
    # 「告警项」那行）。空行/注释跳过但保留，遇到不相干的语句就停。
    i = end + 1
    while i < len(lines) and i <= end + TAIL_MAX:
        if not lines[i].strip() or is_comment(lines[i]):
            i += 1
            continue
        s = lines[i].strip()
        if re.match(r'^if\b', s):
            j = block_end(i)
            body = '\n'.join(lines[i:j + 1])
            if 'print_legacy_view_warning' in body or 'WARN_STEPS' in body:
                end = j
                i = j + 1
                continue
            break
        if 'print_legacy_view_warning' in s or 'WARN_STEPS' in s:
            end = i
            i += 1
            continue
        break
    body = write(f'banner{n}.sh', a, end)
    if 'print_legacy_view_warning' not in body:
        fail(f'第 {a + 1} 行那处结尾横幅里没有 print_legacy_view_warning 调用——'
             f'后果原文不会被印出来')
    regions.append((f'banner{n}.sh', body))
    print(f'ANCHOR {n} {a + 1}')

# --- 安全闸：抽出来的代码要在本机真跑，只允许 docker exec ------------------
# 抽错范围（或将来有人往横幅段落里塞 docker restart / rm）会让一道 lint 门去动
# 本机上别人的容器。scripts/check-upgrade-warn-banner.sh 就踩过同型的坑。
for name, body in regions:
    for m in re.finditer(r'\bdocker\s+([a-z][a-z-]*)', body):
        if m.group(1) != 'exec':
            fail(f'{name} 抽出的代码里有 `docker {m.group(1)}`；这道门只允许 docker exec，'
                 f'其余会改本机容器状态')
PY
}

psql_do() {
    docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 -q "$@"
}

assert_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "    ✓ ${label}"
    else
        echo "    ✗ ${label}：横幅里找不到「${needle}」"
        FAIL=1
    fi
}

assert_not_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "    ✗ ${label}：横幅里**出现了**「${needle}」"
        FAIL=1
    else
        echo "    ✓ ${label}"
    fi
}

# ---------------------------------------------------------------------------
# 站点表：每处结尾横幅一行
#   源文件 | 第几处 | 人话标签 | 一切正常时的绿色横幅文案 | 待办时必须出现的告警项文案 | 退出码变量
# 「绿色横幅文案」会在抽取后先核一遍在不在抽出的代码块里，改了文案而没同步这张表 =
# 报定位失败，不会静默放行。
# ---------------------------------------------------------------------------
SITES=(
  "simple-deploy.sh|1|升级路径|✅ 升级完成||UPGRADE_EXIT"
  "simple-deploy.sh|2|全新安装路径|✅ 安装完成！||INSTALL_EXIT"
  "migrate-from-official.sh|1|只补 SQL 路径|✓ 完成|旧版对账视图未清理|"
  "migrate-from-official.sh|2|完整迁移路径|🎉 迁移完成|旧版对账视图未清理|"
)
FILES=(simple-deploy.sh migrate-from-official.sh)

# ---------------------------------------------------------------------------
# 抽取
# ---------------------------------------------------------------------------
for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "找不到 $f"
    reg="$TMP_ROOT/$(echo "$f" | tr '/.' '__')"
    mkdir -p "$reg"
    echo "抽取 ${f} 的结尾横幅代码块..."
    if ! manifest=$(extract_regions "$f" "$reg"); then
        echo "$manifest" | sed 's/^/  /'
        die "从 ${f} 抽不出结尾横幅代码块（定位失败，不是跳过）"
    fi
    echo "$manifest" | sed 's/^/  /'
    got=$(printf '%s\n' "$manifest" | awk '/^COUNT /{print $2}')
    want=0
    for row in "${SITES[@]}"; do
        [ "${row%%|*}" = "$f" ] && want=$((want + 1))
    done
    [ "$got" = "$want" ] \
        || die "${f} 里读 LEGACY_VIEW_PENDING 的结尾横幅有 ${got} 处，站点表登记了 ${want} 处；新增/删除了横幅就同步这张表"
done

# 站点表登记的绿色横幅文案必须真的在抽出的代码块里（防"改了文案、门还在断旧词"）
for row in "${SITES[@]}"; do
    IFS='|' read -r f idx label green warn_needle exit_var <<EOF
$row
EOF
    reg="$TMP_ROOT/$(echo "$f" | tr '/.' '__')"
    grep -qF -- "$green" "$reg/banner${idx}.sh" \
        || die "站点表说 ${f} 第 ${idx} 处横幅的成功文案是「${green}」，但抽出的代码块里没有这句；文案改了就同步站点表"
done

# 容器名不能撞上真容器检测正则（否则这个一次性夹具会被同机别的脚本当成用户的真容器）
printf '%s\n' "$CONTAINER" \
    | grep -qiE 'teslamate.*database|teslamate.*postgres|^database$|^postgres$|teslamate.*grafana|^grafana$' \
    && die "夹具容器名 ${CONTAINER} 撞上了 detect_*_container 的正则，换个名字"

# ---------------------------------------------------------------------------
# 真 postgres
# ---------------------------------------------------------------------------
echo
echo "起隔离 postgres（${CONTAINER}）..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null || die "无法启动隔离 postgres"

ready=0
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" psql -U teslamate -d teslamate -c 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" -eq 1 ] || die "postgres 60 秒内没就绪"

# tou_settings 的形状与 sql/install-tou.sql 一致（id 是单行布尔主键）
psql_do -c "CREATE TABLE tou_settings (
              id BOOLEAN PRIMARY KEY,
              legacy_default_note TEXT,
              view_rebuild_note TEXT
            );
            INSERT INTO tou_settings (id) VALUES (TRUE);" >/dev/null 2>"$TMP_ROOT/fixture.err" \
    || { sed 's/^/   /' "$TMP_ROOT/fixture.err"; die "夹具表 tou_settings 建不起来"; }

set_state() {
    if [ "$1" -eq 1 ]; then
        psql_do -c "UPDATE tou_settings SET view_rebuild_note = \$note\$${FIXTURE_NOTE}\$note\$" >/dev/null \
            || die "无法写入夹具提示"
    else
        psql_do -c "UPDATE tou_settings SET view_rebuild_note = NULL" >/dev/null \
            || die "无法清空夹具提示"
    fi
}

# 夹具自检：先证实验有效——两种状态下这一列真的读得出 / 读不出
set_state 1
[ -n "$(docker exec "$CONTAINER" psql -U teslamate -d teslamate -At \
        -c 'SELECT view_rebuild_note FROM tou_settings WHERE view_rebuild_note IS NOT NULL')" ] \
    || die "夹具不成立：置位后查不到 view_rebuild_note"
set_state 0
[ -z "$(docker exec "$CONTAINER" psql -U teslamate -d teslamate -At \
        -c 'SELECT view_rebuild_note FROM tou_settings WHERE view_rebuild_note IS NOT NULL')" ] \
    || die "夹具不成立：清空后仍查得到 view_rebuild_note"

# ---------------------------------------------------------------------------
# 跑：每处横幅 × 两种库状态
# ---------------------------------------------------------------------------
run_site() {
    local f="$1" idx="$2" state="$3" exit_var="$4" out="$5"
    local reg runner slug
    slug=$(echo "$f" | tr '/.' '__')
    reg="$TMP_ROOT/$slug"
    runner="$TMP_ROOT/run-${slug}-${idx}-${state}.sh"

    {
        echo 'set -e'
        echo 'set -o pipefail'
        echo '# 桩：抽出来的代码块引用的外部变量，真值由这道门提供'
        echo "db_container=\"$CONTAINER\"   # simple-deploy.sh run_tou_backfill 的形参"
        echo "DB_CONTAINER=\"$CONTAINER\"   # migrate-from-official.sh"
        echo 'DB_USER=teslamate'
        echo 'DB_NAME=teslamate'
        echo 'SQL_ERR_LOG=/dev/null'
        echo 'LEGACY_VIEW_PENDING=0'
        echo 'SQL_OK=1'
        echo 'UPGRADE_SQL_OK=1'
        echo 'WARN_STEPS=()'
        echo 'FAILED_STEPS=()'
        cat "$reg/warnfn.sh"
        echo '# ↓ 真库在这里被读：LEGACY_VIEW_PENDING / WARN_STEPS 由 view_rebuild_note 决定'
        cat "$reg/note.sh"
        printf 'echo "%s"\n' "$MARKER"
        cat "$reg/banner${idx}.sh"
        [ -n "$exit_var" ] && printf 'echo "__EXIT_VAR__=${%s:-未设置}"\n' "$exit_var"
    } >"$runner"

    set_state "$state"
    bash "$runner" </dev/null >"$TMP_ROOT/raw.log" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "    ✗ 抽出的代码块跑挂了（退出码 ${rc}）："
        sed 's/^/       /' "$TMP_ROOT/raw.log"
        FAIL=1
    fi
    # 只对 MARKER 之后的部分做断言：MARKER 之前是库里那句提示的原文，不算横幅
    sed -n "/${MARKER}/,\$p" "$TMP_ROOT/raw.log" | grep -vF "$MARKER" >"$out"
}

for row in "${SITES[@]}"; do
    IFS='|' read -r f idx label green warn_needle exit_var <<EOF
$row
EOF
    echo
    echo "【${f} 第 ${idx} 处结尾横幅 — ${label}】"

    # ① 对照组：库里没有待办 → 必须是干净的成功横幅
    tag=$(echo "$f" | tr '/.' '__')
    out0="$TMP_ROOT/out-${tag}-${idx}-0.log"
    run_site "$f" "$idx" 0 "$exit_var" "$out0"
    echo "  ① 视图删得掉（view_rebuild_note 为空）"
    assert_contains "打的是成功横幅「${green}」" "$out0" "$green"
    assert_not_contains "没有多余的待办提示" "$out0" "留了一个尾巴"
    assert_not_contains "没有多余的「必须你亲自处理」" "$out0" "必须你亲自处理"
    [ -n "$warn_needle" ] && assert_not_contains "没有多余的告警项" "$out0" "告警项"

    # ② 实验组：库里留着待办 → 横幅必须变，且后果原文必须在横幅里
    out1="$TMP_ROOT/out-${tag}-${idx}-1.log"
    run_site "$f" "$idx" 1 "$exit_var" "$out1"
    echo "  ② 视图删不掉（view_rebuild_note 非空）"
    assert_not_contains "**不再**是成功横幅「${green}」" "$out1" "$green"
    assert_contains "横幅改口说留了待办" "$out1" "留了一个尾巴"
    assert_contains "点名要用户亲自处理" "$out1" "必须你亲自处理"
    # 后果原文三个关键点——此前没有任何门钉住，删一句就会静默丢失
    assert_contains "写明后果：TeslaMate 升到 4.1.1 会启动失败" "$out1" "4.1.1"
    assert_contains "写明后果：容器反复重启" "$out1" "反复重启"
    assert_contains "给出处理完要重跑的指引" "$out1" "重跑一次本脚本"
    [ -n "$warn_needle" ] && assert_contains "告警项写的是人话「${warn_needle}」" "$out1" "$warn_needle"

    if [ -n "$exit_var" ]; then
        # 警告档不是失败档：该装的都装完了，退出码仍是 0，否则自动化会把一次好的安装当失败回滚
        assert_contains "${exit_var} 仍是 0（警告档，不是失败档）" "$out1" "__EXIT_VAR__=0"
    fi

    if ! diff -q "$out0" "$out1" >/dev/null 2>&1; then
        echo "    ✓ 两种库状态下横幅确实不同（不是空跑）"
    else
        echo "    ✗ 两种库状态下横幅一模一样——这道门没测到任何东西"
        FAIL=1
    fi
done

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✅ 结尾横幅行为契约通过：旧对账视图删不掉时，两条安装路径都不再打绿，且横幅里写着后果和处理办法"
    exit 0
fi
echo "❌ 结尾横幅行为契约失败"
for row in "${SITES[@]}"; do
    IFS='|' read -r f idx _ _ _ _ <<EOF
$row
EOF
    echo "   ── ${f} 第 ${idx} 处，视图删不掉时的横幅实际输出 ──"
    tag=$(echo "$f" | tr '/.' '__')
    sed 's/^/     /' "$TMP_ROOT/out-${tag}-${idx}-1.log" 2>/dev/null
done
exit 1
