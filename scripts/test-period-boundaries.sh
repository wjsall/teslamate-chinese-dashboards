#!/bin/bash
# 周期表格的下钻边界测试。
#
# TeslaMate 的时间列是朴素 UTC。此测试锁定所有 date_from/date_to：
# 按 Grafana 本地时区分组，起点为本地零点、终点为下一本地零点（右开区间）。
# 终点必须在本地墙钟时间上加日历 interval，避免夏令时日/周/月/年少或多一小时。
#
# 用法：bash scripts/test-period-boundaries.sh
# 依赖：docker、python3
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="period-boundaries-test-$$"
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

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass_test "$label"
    else
        fail_test "$label" "$expected" "$actual"
    fi
}

psql_query() {
    local sql="$1" output_dir output
    output_dir=$(mktemp -d "${TMPDIR:-/tmp}/period-boundaries.XXXXXX") || exit 1
    if docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
        -tAX -v ON_ERROR_STOP=1 -c "$sql" >"$output_dir/stdout" 2>"$output_dir/stderr"; then
        output=$(<"$output_dir/stdout")
    else
        output=$(<"$output_dir/stdout")
        output+=$(<"$output_dir/stderr")
        rm -rf -- "$output_dir"
        printf '<SQL-error>%s' "$output"
        return
    fi
    rm -rf -- "$output_dir"
    printf '%s' "$output"
}

assert_dashboard_contract() {
    local result
    if result=$(python3 - <<'PY'
import json
from pathlib import Path

TARGETS = {
    'grafana/dashboards/zh-cn/MileageStats.json': [(10, 'A'), (27, 'A')],
    'grafana/dashboards/zh-cn/ChargingCostsStats.json': [(58, 'A'), (58, 'B'), (58, 'C')],
    'grafana/dashboards/zh-cn/statistics.json': [(2, 'A'), (2, 'B'), (2, 'C'), (2, 'D')],
}

def panels(value):
    if isinstance(value, dict):
        if 'id' in value and 'targets' in value:
            yield value
        for child in value.values():
            yield from panels(child)
    elif isinstance(value, list):
        for child in value:
            yield from panels(child)

for path, expected_targets in TARGETS.items():
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    by_id = {panel['id']: panel for panel in panels(data)}
    for panel_id, ref_id in expected_targets:
        panel = by_id.get(panel_id)
        if panel is None:
            raise SystemExit(f'{path}: 找不到 panel {panel_id}')
        matches = [target.get('rawSql', '') for target in panel.get('targets', [])
                   if target.get('refId') == ref_id]
        if len(matches) != 1:
            raise SystemExit(f'{path}: panel {panel_id} target {ref_id} 不唯一')
        sql = matches[0]
        required = (
            "timezone('UTC',",
            "'$__timezone'",
            "EXTRACT(EPOCH FROM",
            "timezone('$__timezone', timezone('$__timezone',",
            "AS date_from",
            "AS date_to",
        )
        for token in required:
            if token not in sql:
                raise SystemExit(f'{path}: panel {panel_id} target {ref_id} 缺少 {token!r}')
        if 'AS display' not in sql and 'AS "周期"' not in sql:
            raise SystemExit(f'{path}: panel {panel_id} target {ref_id} 缺少本地周期显示列')
        forbidden = (
            "date + interval '1 $period'",
            "local_period + ('1 ' || '$period')::INTERVAL",
            "date_trunc('month', local_period)",
            "local_period + ('1 ' || 'month')::INTERVAL",
        )
        for token in forbidden:
            if token in sql:
                raise SystemExit(f'{path}: panel {panel_id} target {ref_id} 仍使用带时区时间直接加 interval')
        if "to_char(timezone('$__timezone'," not in sql:
            raise SystemExit(f'{path}: panel {panel_id} target {ref_id} display 未使用本地时区')
        if path.endswith('ChargingCostsStats.json') and "'$timezone'" in sql:
            raise SystemExit(f'{path}: panel {panel_id} target {ref_id} 仍使用会话时区变量')
print('contract-ok')
PY
    ); then
        pass_test "9 条 date_from/date_to 查询均使用本地墙钟右开区间契约"
    else
        fail_test "9 条 date_from/date_to 查询均使用本地墙钟右开区间契约" "contract-ok" "$result"
    fi
}

echo "起隔离 PostgreSQL（${PG_IMAGE}）..."
if ! docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null; then
    echo "❌ 无法启动 PostgreSQL 容器"
    exit 1
fi

ready=0
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" psql -U teslamate -d teslamate -c 'SELECT 1' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "❌ PostgreSQL 未就绪"
    exit 1
fi

assert_dashboard_contract

period_matrix_sql() {
    local session_timezone="$1"
    cat <<SQL
SET TIME ZONE '${session_timezone}';
WITH zones(zone) AS (
  VALUES ('UTC'), ('Asia/Shanghai'), ('America/Chicago'), ('Europe/Berlin')
), periods(period) AS (
  VALUES ('day'), ('week'), ('month'), ('year')
), samples(source_utc) AS (
  VALUES
    (TIMESTAMP '2024-03-10 08:30:00'),
    (TIMESTAMP '2024-06-15 12:30:00'),
    (TIMESTAMP '2024-11-03 07:30:00')
), boundaries AS (
  SELECT
    zone,
    period,
    source_utc,
    date_trunc(period, timezone('UTC', source_utc), zone) AS date_from,
    timezone(zone, timezone(zone, date_trunc(period, timezone('UTC', source_utc), zone))
      + ('1 ' || period)::INTERVAL) AS date_to
  FROM zones CROSS JOIN periods CROSS JOIN samples
)
SELECT string_agg(
  zone || '/' || period || '/' || to_char(source_utc, 'YYYYMMDDHH24MI') || ':' ||
  to_char(timezone(zone, date_from), 'YYYYMMDDHH24MI') || '-' ||
  to_char(timezone(zone, date_to), 'YYYYMMDDHH24MI'),
  E'\\n' ORDER BY zone, period, source_utc
)
FROM boundaries;
SQL
}

echo "行为断言：四个本地时区 × day/week/month/year 不依赖 PostgreSQL 会话时区"
baseline=""
for session_timezone in UTC Asia/Shanghai America/Chicago Europe/Berlin; do
    result=$(period_matrix_sql "$session_timezone" | docker exec -i "$CONTAINER" \
        psql -U teslamate -d teslamate -tAX -v ON_ERROR_STOP=1)
    if [ -z "$baseline" ]; then
        baseline="$result"
        pass_test "会话时区 ${session_timezone} 可计算本地周期"
    else
        assert_eq "会话时区 ${session_timezone} 与 UTC 结果一致" "$baseline" "$result"
    fi
done

day_bounds() {
    local zone="$1" source_utc="$2" sql
    sql=$(cat <<SQL
WITH boundary AS (
  SELECT date_trunc('day', timezone('UTC', TIMESTAMP '${source_utc}'), '${zone}') AS date_from
)
SELECT
  to_char(date_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
  to_char(timezone('${zone}', timezone('${zone}', date_from) + INTERVAL '1 day') AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
  to_char(timezone('${zone}', date_from), 'YYYY-MM-DD')
FROM boundary
SQL
)
    psql_query "$sql"
}

echo "行为断言：DST 日边界按当地零点推进"
assert_eq "Chicago 春季 DST 日长度 23 小时" \
    "2024-03-10 06:00|2024-03-11 05:00|2024-03-10" \
    "$(day_bounds America/Chicago '2024-03-10 08:30:00')"
assert_eq "Chicago 秋季 DST 日长度 25 小时" \
    "2024-11-03 05:00|2024-11-04 06:00|2024-11-03" \
    "$(day_bounds America/Chicago '2024-11-03 07:30:00')"
assert_eq "Berlin 春季 DST 日长度 23 小时" \
    "2024-03-30 23:00|2024-03-31 22:00|2024-03-31" \
    "$(day_bounds Europe/Berlin '2024-03-31 10:30:00')"
assert_eq "Berlin 秋季 DST 日长度 25 小时" \
    "2024-10-26 22:00|2024-10-27 23:00|2024-10-27" \
    "$(day_bounds Europe/Berlin '2024-10-27 10:30:00')"
assert_eq "Shanghai 无 DST 日边界" \
    "2024-03-09 16:00|2024-03-10 16:00|2024-03-10" \
    "$(day_bounds Asia/Shanghai '2024-03-10 08:30:00')"
assert_eq "UTC 日边界" \
    "2024-03-10 00:00|2024-03-11 00:00|2024-03-10" \
    "$(day_bounds UTC '2024-03-10 08:30:00')"

echo
echo "周期边界测试结果：通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "✅ 本地周期 date_from/date_to 边界测试通过"
