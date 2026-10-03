#!/bin/bash
# 「行程统计（年月日）」面板 2 的行为测试：直接执行 dashboard JSON 里的真实 SQL。
#
# 锁两件事：
#   ① 结果不随数据库会话时区变化。面板用 date_trunc(..., '$__timezone') 按用户的仪表盘时区分组，
#      数据库默认时区（TZ 环境变量、ALTER DATABASE SET timezone）只是个无关背景；
#      任何一步把带时区的时间转成无时区再隐式转回，都会让整列错一个周期，而且不报错。
#      目标 D（毛能耗）曾因此在东八区数据库上整体错位，UTC 库上完全看不出来。
#   ② 周期 total（总计）在任何会话时区下都能执行，且只给出一个汇总周期。
# 另有两条防空转：每个周期组合 A 必须返回至少 2 行（否则「各时区结果一致」是拿空结果比空结果）；
# A 的每个周期标签必须出现在 D 里（D 是同一批行程加上充电事件按周期分组，缺标签就是错位）。
#
# 数据：固定的绝对时间，刻意摆在本地零点前后（上海、芝加哥与 UTC 的日 / 周 / 月 / 年边界都不同），
# 这样时区处理出错时周期归属一定会变。
#
# 用法：bash scripts/test-statistics-period-behavior.sh [dashboard.json]
#       （可选参数用于故障注入：指向一份被改坏的 statistics.json，期望本测试变红）
# 依赖：docker、python3
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="statistics-period-test-$$"
DASHBOARD_JSON="${1:-grafana/dashboards/zh-cn/statistics.json}"
PASS=0
FAIL=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass_test() {
    echo "  ✅ $1"
    PASS=$((PASS + 1))
}

fail_test() {
    echo "  ❌ $1"
    echo "       期望: $2"
    echo "       实际: $3"
    FAIL=$((FAIL + 1))
}

if [ ! -f "$DASHBOARD_JSON" ]; then
    echo "❌ 找不到 $DASHBOARD_JSON"
    exit 1
fi

echo "起隔离 PostgreSQL（${PG_IMAGE}）..."
if ! docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null; then
    echo "❌ 无法启动 PostgreSQL 容器"
    exit 1
fi

ready=0
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U teslamate >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "❌ PostgreSQL 没有在 60 秒内就绪"
    exit 1
fi
# pg_isready 先于初始化脚本结束变绿，再等一次真正能执行语句
for _ in $(seq 1 30); do
    docker exec "$CONTAINER" psql -U teslamate -d teslamate -tAc 'select 1' >/dev/null 2>&1 && break
    sleep 1
done

# 最小表结构：只放面板 SQL 用到的列，列名与类型取自 TeslaMate 真实 schema。
# effective_cost 是分时电价函数（install-tou.sql），与时区无关，这里用桩，原值返回。
docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 -q <<'SQL' || { echo "❌ 建表失败"; exit 1; }
CREATE TABLE cars (id smallint PRIMARY KEY, efficiency double precision);
CREATE TABLE positions (
    id bigserial PRIMARY KEY, date timestamp NOT NULL, car_id smallint, drive_id integer,
    odometer double precision, ideal_battery_range_km numeric, rated_battery_range_km numeric,
    battery_level smallint, usable_battery_level smallint);
CREATE TABLE drives (
    id serial PRIMARY KEY, car_id smallint NOT NULL, start_date timestamp NOT NULL, end_date timestamp,
    duration_min smallint, distance double precision, start_km double precision, end_km double precision,
    outside_temp_avg numeric,
    start_ideal_range_km numeric, end_ideal_range_km numeric, start_rated_range_km numeric, end_rated_range_km numeric,
    start_position_id bigint, end_position_id bigint);
CREATE TABLE charging_processes (
    id serial PRIMARY KEY, car_id smallint NOT NULL, start_date timestamp NOT NULL, end_date timestamp,
    charge_energy_added numeric, charge_energy_used numeric, cost numeric, duration_min smallint,
    start_ideal_range_km numeric, end_ideal_range_km numeric, start_rated_range_km numeric, end_rated_range_km numeric,
    position_id bigint);
CREATE FUNCTION effective_cost(bigint, numeric) RETURNS numeric LANGUAGE sql AS $$ SELECT $2 $$;
SQL
docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 -q < sql/install-unit-functions.sql \
    || { echo "❌ 装单位换算函数失败"; exit 1; }

# 固定的 UTC 时间点，刻意落在本地零点前后。
#   2025-12-31 10:00 UTC = 上海 12-31 18:00（仍是 2025 年）；2025-12-31 17:30 UTC = 上海 2026-01-01 01:30（跨年）；2026-08-31 17:00 UTC = 上海 09-01 01:00（跨月）
#   2026-09-30 15:30 / 16:30 UTC = 上海 09-30 23:30 / 10-01 00:30；2026-09-01 03:00 UTC = 芝加哥 08-31 22:00
#   2026-09-06 17:00 UTC = 上海周一 09-07 01:00（跨周）；2026-09-02 / 09-03 / 09-04 平日各一次
docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 -q <<'SQL' || { echo "❌ 灌数据失败"; exit 1; }
INSERT INTO cars VALUES (1, 0.153);
DO $$
DECLARE
    stamps timestamp[] := ARRAY[
        '2025-12-31 10:00', '2025-12-31 17:30', '2026-07-15 10:00', '2026-08-15 04:00', '2026-08-31 17:00', '2026-09-01 03:00',
        '2026-09-02 12:00', '2026-09-03 23:00', '2026-09-04 08:00', '2026-09-06 17:00', '2026-09-09 01:00',
        '2026-09-30 15:30', '2026-09-30 16:30', '2026-10-02 06:00']::timestamp[];
    i int; t timestamp; did int; p1 bigint; p2 bigint; odo double precision := 10000; rng numeric := 420;
BEGIN
    FOR i IN 1 .. array_length(stamps, 1) LOOP
        t := stamps[i];
        INSERT INTO drives (car_id, start_date, end_date, duration_min, distance, start_km, end_km, outside_temp_avg,
                            start_ideal_range_km, end_ideal_range_km, start_rated_range_km, end_rated_range_km)
        VALUES (1, t, t + interval '30 minutes', 30, 20 + i, odo, odo + 20 + i, 10 + i,
                rng, rng - 15 - i, rng * 0.95, (rng - 15 - i) * 0.95)
        RETURNING id INTO did;
        INSERT INTO positions (date, car_id, drive_id, odometer, ideal_battery_range_km, rated_battery_range_km, battery_level, usable_battery_level)
        VALUES (t, 1, did, odo, rng, rng * 0.95, 80, 80) RETURNING id INTO p1;
        INSERT INTO positions (date, car_id, drive_id, odometer, ideal_battery_range_km, rated_battery_range_km, battery_level, usable_battery_level)
        VALUES (t + interval '30 minutes', 1, did, odo + 20 + i, rng - 15 - i, (rng - 15 - i) * 0.95, 70, 70) RETURNING id INTO p2;
        UPDATE drives SET start_position_id = p1, end_position_id = p2 WHERE id = did;
        INSERT INTO charging_processes (car_id, start_date, end_date, charge_energy_added, charge_energy_used, cost, duration_min,
                                        start_ideal_range_km, end_ideal_range_km, start_rated_range_km, end_rated_range_km, position_id)
        VALUES (1, t + interval '2 hours', t + interval '3 hours', 12 + i, 13 + i, 5 + i, 60,
                rng - 15 - i, rng, (rng - 15 - i) * 0.95, rng * 0.95, p2);
        odo := odo + 20 + i;
    END LOOP;
END $$;
SQL

export CONTAINER DASHBOARD_JSON
result=$(python3 - <<'PY'
import itertools, json, os, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

CONTAINER = os.environ['CONTAINER']
data = json.loads(Path(os.environ['DASHBOARD_JSON']).read_text(encoding='utf-8'))
panel = next(p for p in data['panels'] if p.get('id') == 2)
TARGETS = {t['refId']: t['rawSql'] for t in panel['targets']}
assert sorted(TARGETS) == ['A', 'B', 'C', 'D'], f'面板 2 的 target 变了：{sorted(TARGETS)}'

FROM, TO = '2025-12-01T00:00:00Z', '2026-12-31T00:00:00Z'
FROM_MS, TO_MS = 1764547200000, 1798675200000
SESSION_TZ = ['UTC', 'Asia/Shanghai', 'America/Chicago', 'Europe/Berlin']
DASH_TZ = ['Asia/Shanghai', 'America/Chicago']
PERIODS = ['day', 'week', 'month', 'year']


def render(sql, period, dash_tz):
    sql = re.sub(r'\$__timeFilter\(([^)]*)\)', lambda m: f"{m.group(1)} BETWEEN '{FROM}' AND '{TO}'", sql)
    values = {'$__timezone': dash_tz, '$__from': str(FROM_MS), '$__to': str(TO_MS), '$period': period,
              '${preferred_range}': 'ideal', '$length_unit': 'km', '$temp_unit': 'C', '$car_id': '1',
              '$high_precision': '0'}
    for key in sorted(values, key=len, reverse=True):
        sql = sql.replace(key, values[key])
    leftovers = re.findall(r'\$[A-Za-z_{][\w}]*', re.sub(r"'[^']*'", '', sql))
    if leftovers:
        raise SystemExit(f'渲染后仍有未替换的变量 {sorted(set(leftovers))}，测试脚本需要跟进')
    return sql


def run(sql, session_tz):
    script = (f"BEGIN READ ONLY; SET LOCAL timezone='{session_tz}'; "
              f"COPY ({sql.rstrip().rstrip(';')}) TO STDOUT WITH CSV HEADER; ROLLBACK;")
    proc = subprocess.run(['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'teslamate', '-d', 'teslamate',
                           '-v', 'ON_ERROR_STOP=1', '-q'], input=script, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, proc.stderr.strip()[:300]
    out = proc.stdout.strip()
    # date 列是 timestamptz，CSV 里的文本会随会话时区变（同一时刻写成 +00 或 +08）。
    # 比较的是「同一时刻」，所以统一换算成 UTC 再比。
    def to_utc(match):
        moment = datetime.fromisoformat(match.group(0).replace(' ', 'T'))
        return moment.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    out = re.sub(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?[+-]\d\d(?::\d\d)?', to_utc, out)
    return out, None


def rows_of(out):
    lines = out.splitlines()
    return lines[1:]


def display_labels(out):
    import csv
    rows = list(csv.DictReader(out.splitlines()))
    return {row['display'] for row in rows}


report = []
for dash_tz, period in itertools.product(DASH_TZ, PERIODS):
    label = f'仪表盘时区 {dash_tz} / 周期 {period}'
    outputs = {}
    problems = []
    for ref in 'ABCD':
        for session_tz in SESSION_TZ:
            out, err = run(render(TARGETS[ref], period, dash_tz), session_tz)
            if err:
                problems.append(f'target {ref} 会话时区 {session_tz} 报错：{err}')
            else:
                outputs[(ref, session_tz)] = out
    for ref in 'ABCD':
        variants = {session_tz: outputs.get((ref, session_tz)) for session_tz in SESSION_TZ}
        if len({v for v in variants.values() if v is not None}) > 1:
            groups = {}
            for session_tz, out in variants.items():
                groups.setdefault(out, []).append(session_tz)
            problems.append(f'target {ref} 结果随数据库会话时区变化，分成 {len(groups)} 组：' +
                            ' | '.join('/'.join(tzs) for tzs in groups.values()))
    a_out = outputs.get(('A', 'UTC'))
    d_out = outputs.get(('D', 'UTC'))
    if a_out is not None and len(rows_of(a_out)) < 2:
        problems.append(f'target A 只返回 {len(rows_of(a_out))} 行，比较不出任何东西（种子数据需要跟进）')
    if a_out is not None and d_out is not None:
        missing = display_labels(a_out) - display_labels(d_out)
        if missing:
            problems.append(f'target A 的周期标签 {sorted(missing)} 在 D 里不存在'
                            '（D 对同一批行程再加上充电事件分组，A 的每个周期都应出现在 D 里）')
    report.append((label, problems))

for dash_tz in DASH_TZ:
    label = f'仪表盘时区 {dash_tz} / 周期 total'
    problems = []
    for ref in 'ABCD':
        outs = {}
        for session_tz in SESSION_TZ:
            out, err = run(render(TARGETS[ref], 'total', dash_tz), session_tz)
            if err:
                problems.append(f'target {ref} 会话时区 {session_tz} 报错：{err}')
            else:
                outs[session_tz] = out
        if len(set(outs.values())) > 1:
            problems.append(f'target {ref} 的总计结果随数据库会话时区变化')
        for session_tz, out in outs.items():
            if display_labels(out) != {'总计'}:
                problems.append(f'target {ref} 会话时区 {session_tz} 的周期标签应只有「总计」，实际 {sorted(display_labels(out))}')
                break
    report.append((label, problems))

for label, problems in report:
    print('OK\t' + label if not problems else 'FAIL\t' + label + '\t' + ' ;; '.join(problems[:3]) + (f' ;; …另有 {len(problems) - 3} 条' if len(problems) > 3 else ''))
PY
)
status=$?
if [ "$status" -ne 0 ]; then
    echo "❌ 测试脚本自身出错（退出码 $status）："
    echo "$result"
    exit 1
fi

while IFS=$'\t' read -r verdict label detail; do
    [ -z "$verdict" ] && continue
    if [ "$verdict" = "OK" ]; then
        pass_test "$label：A–D 四条查询在 4 个数据库会话时区下结果一致"
    else
        fail_test "$label" "A–D 在 UTC / Asia/Shanghai / America/Chicago / Europe/Berlin 会话下结果一致" "$detail"
    fi
done <<EOF
$result
EOF

echo ""
echo "统计页周期行为测试结果：通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "✅ 统计页各周期（含总计）不随数据库会话时区变化"
