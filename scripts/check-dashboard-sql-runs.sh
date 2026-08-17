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

cd "$(dirname "$0")/.." || exit

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

# 等 TeslaMate 把迁移跑完。判据是「迁移条数连续 STABLE_SAMPLES 次采样不变」，
# 不是「条数超过某个数」。
#
# 原来写的是 `-gt 90`，而 TeslaMate 当前有 100 条迁移——也就是说脚本可能在第 91 条
# 就往下走。实测确实见过 95 和 100 两种结果。剩下几条迁移新增的列这时还不存在，
# 用到它们的面板会解析失败，门就报一次假红。这道门的全部价值是「它响的时候可信」，
# 假红比慢几秒糟糕得多。
#
# 用「不再增长」当判据的额外好处：将来 TeslaMate 加迁移，这里不用跟着改数字。
STABLE_SAMPLES=5   # ×2 秒 ≈ 10 秒没有新迁移才算跑完
migrated=0
stable=0
last=-1
for _ in $(seq 1 120); do
    n=$(docker exec "$DB" psql -U teslamate -d teslamate -tAc \
        "SELECT count(*) FROM schema_migrations" 2>/dev/null | tr -d '[:space:]')
    # 表还没建好 / psql 报错时拿到的是空串或非数字，一律当 0 继续等
    case "${n:-x}" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ] && [ "$n" -eq "$last" ]; then
        stable=$((stable + 1))
        if [ "$stable" -ge "$STABLE_SAMPLES" ]; then migrated=$n; break; fi
    else
        stable=0
    fi
    last=$n
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
python3 - "$DB" "$@" <<'PY'
import json, glob, os, re, subprocess, sys

container = sys.argv[1]
_flags = set(sys.argv[2:])
update_baseline = '--update-baseline' in _flags
force_baseline = '--force' in _flags
results = {}

# 把 Grafana 的变量与宏换成合法常量。目标只是让语句能被解析，
# 所以替换值只要类型合理即可，不追求语义。
#
# filler = 认不出来的变量最后兜底成什么。同一条 SQL 会用两种兜底各渲染一次：
#   "'1'"  字符串常量——变量用在 WHERE name = $var 这类字符串比较里时需要它
#   "1"    裸数值——变量参与算术（$car_cost、$fuel_price、$depreciated_value、
#          $loss_rate 之类）时需要它；一律加引号会让 PostgreSQL 报
#          operator does not exist: text - numeric，那些面板于是解析失败、
#          进不了基线 → 恰好是几个算钱的面板得不到保护。
# 任一种能解析就算这条查询通过，这样不必维护一份「哪些变量是数值」的名单。
def render(sql, filler="'1'"):
    s = sql
    s = re.sub(r'\$__timeFilter\(([^)]*)\)', r"\1 BETWEEN now() - interval '30 days' AND now()", s)
    s = re.sub(r'\$__timeGroupAlias\(([^,]+),[^)]*\)', r'date_trunc(\'day\', \1) AS time', s)
    s = re.sub(r'\$__timeGroup\(([^,]+),[^)]*\)', r"date_trunc('day', \1)", s)
    s = re.sub(r'\$__unixEpochFilter\(([^)]*)\)', r'TRUE', s)
    # $__time(col) / $__timeEpoch(col)：Grafana 把它们展开成时间序列要的那一列。
    # 不认这两个宏时，它们会掉进最后的通用兜底、变成 '1'(col) —— 报 syntax error at or
    # near "("，而这个报错撞的不是占位符本身，is_render_artifact() 认不出来，于是这些面板
    # 既进不了基线、也不算失败，静静地一条规则都跑不到。实测：全仓 40 条用了 $__time()，
    # 40 条全在基线之外，占未覆盖总数的绝大部分。
    # 注意先后无所谓：$__timeFilter( / $__timeGroup( 里 "time" 后面不是左括号，匹配不上。
    # 与上游逐字对齐（v13.1.3 pkg/tsdb/grafana-postgresql-datasource/macros.go）：
    #   case "__time":      return fmt.Sprintf("%s AS \"time\"", args[0])
    #   case "__timeEpoch": return fmt.Sprintf("extract(epoch from %s) as \"time\"", args[0])
    # 两点必须照抄，写歪了就是把「其实跑不通的 SQL」冻进基线、门从此保护一个错误的形状：
    #   ① **不加 ::bigint**。PG14+ 的 extract() 返回 numeric，加了 cast 会把类型变掉：
    #      `extract(epoch from x)::bigint & 1` 能解析，而上游真实展开的 numeric 版本报
    #      operator does not exist: numeric & integer。
    #   ② 上游对参数 `strings.Split(groups[2], ",")` 后**只取 args[0]**，多余参数丢掉。
    def _first_arg(match):
        return match.group(1).split(',')[0].strip()
    s = re.sub(r'\$__timeEpoch\(([^)]*)\)',
               lambda m: 'extract(epoch from %s) as "time"' % _first_arg(m), s)
    s = re.sub(r'\$__time\(([^)]*)\)', lambda m: '%s AS "time"' % _first_arg(m), s)
    s = s.replace('$__timeFrom()', "(now() - interval '30 days')").replace('$__timeTo()', 'now()')
    s = s.replace('$__timezone', 'Asia/Shanghai')
    s = re.sub(r"\$__interval\w*", "'1 day'", s)
    # ${__from:date:seconds} / ${__to:date:seconds} = 时间范围两端的 Unix 秒，是数字。
    # 下面通用的 ${var:pipe} 规则只认一个冒号，认不出这两个两段格式的内置变量，于是
    # 一个 $ 会原样留下来、整条 SQL 报 syntax error at or near "$"，
    # 面板（如「每百 $length_unit 费用」）也就进不了基线。
    s = re.sub(r'\$\{__from:date:seconds\}', '1700000000', s)
    s = re.sub(r'\$\{__to:date:seconds\}', '1800000000', s)
    # 单位/长度/时间粒度类变量必须是函数认识的字面量。
    # period 尤其重要：它出现在 date_trunc('$period', …) 和 interval '1 $period' 里，
    # 换成通用占位符会得到 date_trunc('1', …) / interval '1 1'，两种兜底都解析不了，
    # 「每${period}」那几个统计面板于是全部落在基线之外。
    for var, val in [('length_unit', 'km'), ('temp_unit', 'C'), ('pressure_unit', 'bar'),
                     ('preferred_range', 'rated'), ('period', 'month')]:
        s = s.replace('${%s}' % var, val).replace('$%s' % var, val)
    # 数值类
    for var in ['car_id', 'charging_process_id', 'drive_id', 'journey', 'geofence_id',
                'min_duration_min', 'cost', 'Year', 'Month', 'Day']:
        s = re.sub(r'\$\{?%s(:\w+)?\}?' % var, '1', s)
    s = re.sub(r"\$\{payload\.\w+\}", '1', s)
    # 多值变量的三种常见用法。这几个必须单独处理，否则最复杂、也最重要的那些面板
    # （充电记录主表之类）永远渲染不出来 → 落不进基线 → 恰好得不到保护。
    # 2026-07 第一版就是这样：门建好了，而它本该守住的那个面板不在守备范围内。
    s = re.sub(r'ARRAY\[\s*\$\{?\w+(:\w+)?\}?\s*\]', 'ARRAY[%s]' % filler, s)   # ARRAY[$var]
    s = re.sub(r'\bin\s*\(\s*\$\{?\w+(:\w+)?\}?\s*\)', 'in (1)', s, flags=re.I)  # col in ($var)
    # 变量出现在字符串字面量内部时要换成裸值，不能再套一层引号
    s = re.sub(r"'%\$\{?\w+(:\w+)?\}?%'", "'%1%'", s)                               # '%$var%' (ILIKE)
    s = re.sub(r"'\$\{?\w+(:\w+)?\}?'", "'1'", s)                                    # '$var' / '${var:pipe}'
    s = re.sub(r'\$\{\w+:\w+\}', filler, s)                                        # ${var:pipe}
    # 兜底：剩下的变量按 filler 处理（调用方会把两种兜底都试一遍）
    s = re.sub(r'\$\{[\w.]+(:\w+)?\}', filler, s)
    s = re.sub(r'\$[A-Za-z_]\w*', filler, s)
    return s


FILLERS = ["'1'", '1']


def parse_once(container, stmt):
    """把一条语句交给 PostgreSQL 解析。返回 None = 通过，否则返回错误摘要。
    只解析不执行：PREPARE 会做全套名称解析与类型检查，但不产生任何行为。"""
    payload = "PREPARE _chk AS " + stmt.rstrip().rstrip(';') + ";\nDEALLOCATE _chk;"
    r = subprocess.run(
        ['docker', 'exec', '-i', container, 'psql', '-U', 'teslamate', '-d', 'teslamate',
         '-v', 'ON_ERROR_STOP=1', '-q'],
        input=payload, capture_output=True, text=True)
    if r.returncode == 0:
        return None
    return ' '.join(l.strip() for l in r.stderr.split('\n') if 'ERROR' in l)[:150]


def is_render_artifact(err, filler):
    """报错就报在我们填进去的那个占位符上 = 渲染器还原不出这个变量（它其实被插在
    表名/列名之类的标识符位置），不是仪表盘的错。"""
    return 'syntax error' in err and ('at or near "%s"' % filler) in err

files = sorted(glob.glob('grafana/dashboards/**/*.json', recursive=True))
skipped = 0  # 渲染不出来 / 不适合 PREPARE 的，不纳入校验，也就不会进基线

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

    for idx, (title, sql) in enumerate(items):
        # key 用**完整路径**而不是文件名：grafana/dashboards 下有 internal/ 和 zh-cn/
        # 两个目录，只用文件名的话，两边一旦出现同名文件，两个不同面板会挤进同一个 key，
        # 后写的静默覆盖先写的——基线少一条、而且少的那条谁都看不出来。
        # 今天还没有重名，但这道门的判据不该依赖「以后也不会重名」。
        key = f'{f}::{idx}::{title[:40]}'
        rendered = render(sql)
        # 多语句（表单写入类面板）不做解析——PREPARE 只接一条语句，而真跑会写数据
        if rendered.count(';') > 1 or re.match(r'\s*(INSERT|UPDATE|DELETE|SELECT\s+\w+\s*\()', rendered, re.I) and ';' in rendered.strip()[:-1]:
            skipped += 1
            continue
        # 两种兜底渲染各试一次（见 render 的注释），任一能解析就算通过
        errors = []
        for filler in FILLERS:
            err = parse_once(container, render(sql, filler))
            if err is None:
                errors = None
                break
            errors.append((filler, err))
        if errors is None:
            results[key] = None
            continue
        # 每种兜底都只是撞在占位符上 = 渲染器还原不出这条 SQL，不算仪表盘的错
        real = [e for filler, e in errors if not is_render_artifact(e, filler)]
        if not real:
            skipped += 1
            continue
        results[key] = real[0]

# 棘轮：变量渲染器还原不了所有 Grafana 变量（多值、:pipe、插进标识符位置的），
# 所以「当前解析不了」不等于「面板坏了」。硬性要求全绿会让这道门天天误报、很快没人看。
# 改成记录基线：**曾经能解析的面板，之后必须一直能解析**。
# 这样渲染器的不足被冻结在基线之外，而任何真实回归（比如把列引用写到 CTE 作用域外）
# 都会让一个原本在基线里的面板掉出来，当场报红。
#
# 判据是「基线里的每个 key 都必须重新出现在**通过**集合里」，而不是「基线里的 key 没有
# 出现在失败集合里」。差别是致命的：key 形如 文件名::序号::标题，改标题或在前面插一个
# 面板都会让 key 变样，于是同一次提交里「改标题 + 改坏查询」「插面板 + 改坏查询」两种
# 组合下，坏掉的那条查询换了个 key，基线里的旧 key 凭空消失——既不在通过集合也不在
# 失败集合，按旧判据直接被忽略，门给绿灯。这恰好就是这道门被建出来要挡的事故形状。
# 现在 key 消失一律报红，并尽量指出它是「改名了」还是「移位了」，方便区分
# 「这个面板坏了」和「这个面板只是重构了，跑 --update-baseline 收进基线」。
BASELINE = 'scripts/dashboard-sql-baseline.txt'

passing = {k for k in results if results[k] is None}
failing = {k: v for k, v in results.items() if v is not None}

if update_baseline:
    # 棘轮不能被自己清零。原来这里是无条件改写：渲染器一旦坏掉（改一行正则就够），
    # passing 塌成一小撮，跑一次 --update-baseline 就把基线冻在塌掉的状态，此后永远绿。
    # 两道闸，抄的是 check-dashboard-lint.sh 里 k 基线那套：
    #   ① 当前树还有解析失败的，先修完再收基线；
    #   ② 新基线比旧基线少，八成是渲染器退化而不是真删了面板 —— 要缩必须显式 --force。
    old_baseline = set()
    if os.path.exists(BASELINE):
        old_baseline = {l.strip() for l in open(BASELINE, encoding='utf-8')
                        if l.strip() and not l.startswith('#')}
    if failing:
        print(f'  拒绝更新基线：当前树还有 {len(failing)} 条解析失败，先修完再收基线')
        for k, v in sorted(failing.items())[:10]:
            print(f'    {k}\n      {v}')
        sys.exit(1)
    if len(passing) < len(old_baseline) and not force_baseline:
        print(f'  拒绝更新基线：新基线 {len(passing)} 条 < 旧基线 {len(old_baseline)} 条，'
              f'缩水 {len(old_baseline) - len(passing)} 条。')
        print('    基线缩水通常意味着渲染器退化（而不是真删了面板），收进去就等于把退化冻成新常态。')
        print('    确认是有意删除面板，再加 --force 重跑。掉出来的是：')
        for k in sorted(old_baseline - passing)[:10]:
            print(f'      {k}')
        sys.exit(1)
    with open(BASELINE, 'w', encoding='utf-8') as fh:
        fh.write('# 自动生成——跑 `bash scripts/check-dashboard-sql-runs.sh --update-baseline` 重建。\n')
        fh.write('# 列出「能被 PostgreSQL 解析」的面板查询。不在表里的多半是变量渲染器还原不了，\n')
        fh.write('# 不代表面板有问题；在表里的每一条都必须再次通过校验，否则门报红——\n')
        fh.write('# 解析失败要报，key 整个消失（面板改名/移位/删除）同样要报。\n')
        for k in sorted(passing):
            fh.write(k + '\n')
    print(f'  基线已更新：{len(passing)} 条可解析的查询')
    sys.exit(0)

if not os.path.exists(BASELINE):
    print(f'  缺少基线文件 {BASELINE}，先跑 --update-baseline 生成')
    sys.exit(1)

baseline = {l.strip() for l in open(BASELINE, encoding='utf-8')
            if l.strip() and not l.startswith('#')}

def split_key(k):
    parts = k.split('::', 2)
    return (parts[0], parts[1], parts[2]) if len(parts) == 3 else (k, '', '')


# 基线里的 key 没有重新出现在通过集合里 = 门不通过。分两类报，两类的处理方式不一样。
regressed = sorted(k for k in baseline if k in failing)       # key 还在，查询解析失败了
vanished = sorted(k for k in baseline if k not in passing and k not in failing)

for k in regressed:
    print(f'  ❌ 查询解析失败：{k}')
    print(f'       {failing[k]}')
    print('       这个面板在 Grafana 里会直接报错、不出数据。')

if vanished:
    # 面板改名 / 挪位置都会让 key 变样。找出「同一文件里同标题」或「同一文件里同序号」的
    # 面板当候选，方便一眼分清「这个面板只是重构了」和「这个面板坏了、顺带还改了名」。
    by_title = {}
    by_pos = {}
    for k in list(passing) + list(failing):
        fname, idx, title = split_key(k)
        by_title.setdefault((fname, title), []).append(k)
        by_pos.setdefault((fname, idx), []).append(k)

    def pick(pool, k):
        cands = sorted((c for c in pool if c != k), key=lambda c: (c in failing, c))
        return cands[0] if cands else None

    for k in vanished:
        fname, idx, title = split_key(k)
        print(f'  ❌ 基线里的这条查询没有再通过校验：{k}')
        cand = pick(by_title.get((fname, title), []), k)
        why = '标题没变、序号变了 = 面板顺序调整过'
        if cand is None:
            cand = pick(by_pos.get((fname, idx), []), k)
            why = '序号没变、标题变了 = 面板改名过'
        if cand is None:
            print('       本次校验里找不到对应的面板：它可能被删掉了，也可能改名和移位同时发生，')
            print('       还可能是它的查询现在连渲染都渲染不出来。请先确认面板本身是好的，')
            print('       再跑 --update-baseline 重建基线。')
        elif cand in failing:
            print(f'       它现在很可能是 {cand}（{why}），而那条查询解析失败了：')
            print(f'         {failing[cand]}')
            print('       所以这不只是改名——先把查询修好；确认面板恢复正常后再 --update-baseline。')
        else:
            print(f'       它现在很可能是 {cand}（{why}），那条查询解析正常。')
            print('       确认这就是同一个面板的话，跑 --update-baseline 把新 key 收进基线。')

new_ok = sorted(k for k in passing if k not in baseline)
print()
print(f'  可解析 {len(passing)} / 校验 {len(results)}（另有 {skipped} 条渲染不出来，未纳入校验）；'
      f'基线 {len(baseline)} 条')
if new_ok:
    print(f'  （新增 {len(new_ok)} 条可解析的查询，跑 --update-baseline 收进基线）')
if regressed:
    print(f'  {len(regressed)} 条原本能解析的查询现在解析失败')
if vanished:
    print(f'  {len(vanished)} 条基线里的查询没有再出现在通过集合里')
sys.exit(1 if (regressed or vanished) else 0)
PY
rc=$?

echo ""
if [ "$rc" -eq 0 ]; then
    echo "✅ 仪表盘 SQL 全部可被 PostgreSQL 解析"
else
    echo "❌ 门未通过：基线里的面板查询没能全部再次通过校验（见上面逐条说明）"
fi
exit "$rc"
