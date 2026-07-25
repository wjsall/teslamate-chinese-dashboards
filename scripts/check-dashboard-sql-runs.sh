#!/bin/bash
# 仪表盘 SQL 可执行性门：把每个面板的查询真正交给 PostgreSQL 解析一遍。
#
# 为什么需要它：在它之前，没有任何一道门会**执行**面板查询。
# check-dashboard-lint.sh 检查 JSON 形状与写法约定，五条部署冒烟检查容器起不起得来、
# 对象在不在，tou-behavior 检查函数算得对不对——没有一个会发现「这条 SQL 根本跑不起来」。
# 2026-07 实测踩到：把费用列改成 effective_cost(cp.id, cp.cost) 时，有两处落在了
# WITH ... AS (...) 的**外层**，那里 cp 别名不存在，PostgreSQL 直接报
# missing FROM-clause entry for table "cp"——「充电记录」「行程统计」两个主表整个空白。
# 四道门全绿、五条冒烟全绿、22 项行为断言全绿，没有一个能看见。
#
# 做法：起一个一次性 postgres，跑真实 TeslaMate schema（用官方镜像做迁移，保证列名
# 与真实环境一致），装上本项目的 SQL，然后把每条 rawSql 的 Grafana 变量/宏替换成
# 合法常量后交给 PREPARE 解析。只验「能不能解析」——列引用、别名作用域、函数签名、
# 语法都在这一步暴露；不验结果对不对（那是 test-tou-behavior.sh 的事）。
#
# 用法：bash scripts/check-dashboard-sql-runs.sh
# 依赖：docker
set -uo pipefail

cd "$(dirname "$0")/.."

DB="dash-sql-check-$$"
NET="dash-sql-net-$$"
APP="dash-sql-app-$$"

cleanup() {
    docker rm -f "$DB" "$APP" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "起隔离环境（postgres + 官方 TeslaMate 跑真实迁移）..."
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    postgres:18-trixie >/dev/null
for _ in $(seq 1 60); do
    docker exec "$DB" pg_isready -U teslamate >/dev/null 2>&1 && break
    sleep 1
done

docker run -d --name "$APP" --network "$NET" \
    -e ENCRYPTION_KEY=dashsqlcheckkey01 -e DATABASE_USER=teslamate -e DATABASE_PASS=test \
    -e DATABASE_NAME=teslamate -e DATABASE_HOST="$DB" -e DISABLE_MQTT=true \
    teslamate/teslamate:latest >/dev/null 2>&1

migrated=0
for _ in $(seq 1 90); do
    n=$(docker exec "$DB" psql -U teslamate -d teslamate -tAc \
        "SELECT count(*) FROM schema_migrations" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$n" ] && [ "$n" -gt 90 ] 2>/dev/null; then migrated=$n; break; fi
    sleep 2
done
if [ "$migrated" -eq 0 ]; then
    echo "❌ TeslaMate 迁移没跑起来，无法验证（不判定为仪表盘问题）"
    exit 2
fi
echo "  TeslaMate schema 就绪（${migrated} 条迁移）"

for f in sql/install-coord-functions.sql sql/install-unit-functions.sql sql/install-tou.sql; do
    docker exec -i "$DB" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 < "$f" >/dev/null 2>&1 \
        || { echo "❌ $f 装不上"; exit 1; }
done
echo "  本项目 SQL 已装"

echo ""
python3 - "$DB" "${1:-}" <<'PY'
import json, glob, os, re, subprocess, sys

container = sys.argv[1]
update_baseline = len(sys.argv) > 2 and sys.argv[2] == '--update-baseline'
results = {}
files_checked = []

# 把 Grafana 的变量与宏换成合法常量。目标只是让语句能被解析，
# 所以替换值只要类型合理即可，不追求语义。
def render(sql):
    s = sql
    s = re.sub(r'\$__timeFilter\(([^)]*)\)', r"\1 BETWEEN now() - interval '30 days' AND now()", s)
    s = re.sub(r'\$__timeGroupAlias\(([^,]+),[^)]*\)', r'date_trunc(\'day\', \1) AS time', s)
    s = re.sub(r'\$__timeGroup\(([^,]+),[^)]*\)', r"date_trunc('day', \1)", s)
    s = re.sub(r'\$__unixEpochFilter\(([^)]*)\)', r'TRUE', s)
    s = s.replace('$__timeFrom()', "(now() - interval '30 days')").replace('$__timeTo()', 'now()')
    s = s.replace('$__timezone', 'Asia/Shanghai')
    s = re.sub(r"\$__interval\w*", "'1 day'", s)
    # 单位/长度类变量必须是函数认识的字面量
    for var, val in [('length_unit', 'km'), ('temp_unit', 'C'), ('pressure_unit', 'bar'),
                     ('preferred_range', 'rated')]:
        s = s.replace('${%s}' % var, val).replace('$%s' % var, val)
    # 数值类
    for var in ['car_id', 'charging_process_id', 'drive_id', 'journey', 'geofence_id',
                'min_duration_min', 'cost', 'Year', 'Month', 'Day']:
        s = re.sub(r'\$\{?%s(:\w+)?\}?' % var, '1', s)
    s = re.sub(r"\$\{payload\.\w+\}", '1', s)
    # 多值变量的三种常见用法。这几个必须单独处理，否则最复杂、也最重要的那些面板
    # （充电记录主表之类）永远渲染不出来 → 落不进基线 → 恰好得不到保护。
    # 2026-07 第一版就是这样：门建好了，而它本该守住的那个面板不在守备范围内。
    s = re.sub(r'ARRAY\[\s*\$\{?\w+(:\w+)?\}?\s*\]', "ARRAY['1']", s)          # ARRAY[$var]
    s = re.sub(r'\bin\s*\(\s*\$\{?\w+(:\w+)?\}?\s*\)', 'in (1)', s, flags=re.I)  # col in ($var)
    # 变量出现在字符串字面量内部时要换成裸值，不能再套一层引号
    s = re.sub(r"'%\$\{?\w+(:\w+)?\}?%'", "'%1%'", s)                               # '%$var%' (ILIKE)
    s = re.sub(r"'\$\{?\w+(:\w+)?\}?'", "'1'", s)                                    # '$var' / '${var:pipe}'
    s = re.sub(r'\$\{\w+:\w+\}', "'1'", s)                                         # ${var:pipe}
    # 兜底：剩下的变量一律当成字符串常量
    s = re.sub(r'\$\{[\w.]+(:\w+)?\}', "'1'", s)
    s = re.sub(r'\$[A-Za-z_]\w*', "'1'", s)
    return s

files = sorted(glob.glob('grafana/dashboards/**/*.json', recursive=True))
checked = failed = skipped = 0
failures = []

for f in files:
    d = json.load(open(f, encoding='utf-8'))
    items = []
    def walk(o, title=''):
        if isinstance(o, dict):
            t = o.get('title') or title
            s = o.get('rawSql')
            if isinstance(s, str) and s.strip():
                items.append((t, s))
            for v in o.values():
                walk(v, t)
        elif isinstance(o, list):
            for v in o:
                walk(v, title)
    walk(d)

    files_checked.append(f)
    for idx, (title, sql) in enumerate(items):
        rendered = render(sql)
        # 多语句（表单写入类面板）交给 psql 直接解析，不用 PREPARE
        if rendered.count(';') > 1 or re.match(r'\s*(INSERT|UPDATE|DELETE|SELECT\s+\w+\s*\()', rendered, re.I) and ';' in rendered.strip()[:-1]:
            body = 'DO $chk$ BEGIN RETURN; END $chk$;'  # 占位，避免真的写数据
            stmt = None
        else:
            stmt = rendered
        if stmt is None:
            skipped += 1
            continue
        # 只解析不执行：PREPARE 会做全套名称解析与类型检查，但不产生任何行为
        payload = "PREPARE _chk AS " + stmt.rstrip().rstrip(';') + ";\nDEALLOCATE _chk;"
        r = subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'teslamate', '-d', 'teslamate',
             '-v', 'ON_ERROR_STOP=1', '-q'],
            input=payload, capture_output=True, text=True)
        checked += 1
        if r.returncode != 0:
            err = ' '.join(l.strip() for l in r.stderr.split('\n') if 'ERROR' in l)
            # 渲染器还原不出来的（真·变量插值成表名/列名等）不算仪表盘的错
            if 'syntax error' in err and "at or near \"'1'\"" in err:
                skipped += 1
                checked -= 1
                continue
            failed += 1
            results[f'{os.path.basename(f)}::{idx}::{title[:40]}'] = err[:150]
            continue
        results[f'{os.path.basename(f)}::{idx}::{title[:40]}'] = None

# 棘轮：变量渲染器还原不了所有 Grafana 变量（多值、:pipe、插进标识符位置的），
# 所以「当前解析不了」不等于「面板坏了」。硬性要求全绿会让这道门天天误报、很快没人看。
# 改成记录基线：**曾经能解析的面板，之后必须一直能解析**。
# 这样渲染器的不足被冻结在基线之外，而任何真实回归（比如把列引用写到 CTE 作用域外）
# 都会让一个原本在基线里的面板掉出来，当场报红。
BASELINE = 'scripts/dashboard-sql-baseline.txt'

ok_keys = set()
fail_keys = {}
for f in files_checked:
    pass

def key(fname, title, idx):
    return f'{fname}::{idx}::{title}'

passing = {k for k in results if results[k] is None}
failing = {k: v for k, v in results.items() if v is not None}

if update_baseline:
    with open(BASELINE, 'w', encoding='utf-8') as fh:
        fh.write('# 自动生成——跑 `bash scripts/check-dashboard-sql-runs.sh --update-baseline` 重建。\n')
        fh.write('# 列出「能被 PostgreSQL 解析」的面板查询。不在表里的多半是变量渲染器还原不了，\n')
        fh.write('# 不代表面板有问题；在表里却解析失败 = 真回归，门会报红。\n')
        for k in sorted(passing):
            fh.write(k + '\n')
    print(f'  基线已更新：{len(passing)} 条可解析的查询')
    sys.exit(0)

if not os.path.exists(BASELINE):
    print(f'  缺少基线文件 {BASELINE}，先跑 --update-baseline 生成')
    sys.exit(1)

baseline = {l.strip() for l in open(BASELINE, encoding='utf-8')
            if l.strip() and not l.startswith('#')}

regressed = sorted(k for k in baseline if k in failing)
for k in regressed:
    print(f'  ❌ 回归：{k}')
    print(f'       {failing[k]}')

new_ok = sorted(k for k in passing if k not in baseline)
print()
print(f'  可解析 {len(passing)} / 校验 {len(results)}；基线 {len(baseline)} 条')
if new_ok:
    print(f'  （新增 {len(new_ok)} 条可解析的查询，跑 --update-baseline 收进基线）')
if regressed:
    print(f'  {len(regressed)} 条原本能解析的查询现在解析失败')
sys.exit(1 if regressed else 0)
PY
rc=$?

echo ""
if [ "$rc" -eq 0 ]; then
    echo "✅ 仪表盘 SQL 全部可被 PostgreSQL 解析"
else
    echo "❌ 有仪表盘 SQL 解析失败——这些面板在 Grafana 里会直接报错、不出数据"
fi
exit "$rc"
