#!/bin/bash
# 驾驶评分共享查询行为测试。
# 直接执行 dashboard JSON 的汇总、趋势、明细查询，锁定共享结果的数值一致性。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="driving-score-test-$$"
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

render_target() {
    local panel_id="$1" ref_id="$2"
    python3 - "$panel_id" "$ref_id" <<'PY'
import json
import re
import sys
from pathlib import Path

panel_id = int(sys.argv[1])
ref_id = sys.argv[2]
data = json.loads(Path('grafana/dashboards/zh-cn/driving-score.json').read_text(encoding='utf-8'))
panel = next(panel for panel in data['panels'] if panel.get('id') == panel_id)
target = next(target for target in panel['targets'] if target.get('refId') == ref_id)
sql = target['rawSql']
sql = sql.replace('$car_id', '1')
sql = sql.replace('$__timezone', 'Asia/Shanghai')
sql = sql.replace('$__timeFrom()', "timestamp '2026-01-01 00:00:00'")
sql = sql.replace('$__timeTo()', "timestamp '2026-01-02 00:00:00'")
sql = re.sub(
    r'\$__timeFilter\((d\.)?start_date\)',
    lambda match: (match.group(1) or '') +
        "start_date >= timestamp '2026-01-01 00:00:00' AND " +
        (match.group(1) or '') + "start_date < timestamp '2026-01-02 00:00:00'",
    sql,
)
print(sql)
PY
}

echo "起隔离 PostgreSQL（${PG_IMAGE}）..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U teslamate >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$CONTAINER" pg_isready -U teslamate >/dev/null 2>&1 || {
    echo "❌ PostgreSQL 未就绪"
    exit 1
}

docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U teslamate -d teslamate <<'SQL'
CREATE TABLE drives (
  id integer PRIMARY KEY,
  car_id integer NOT NULL,
  start_date timestamp without time zone NOT NULL,
  end_date timestamp without time zone,
  distance double precision,
  start_ideal_range_km numeric,
  end_ideal_range_km numeric,
  outside_temp_avg numeric,
  duration_min integer,
  speed_max integer
);
CREATE TABLE positions (
  id integer PRIMARY KEY,
  car_id integer NOT NULL,
  drive_id integer,
  date timestamp without time zone NOT NULL,
  speed integer,
  power integer,
  latitude numeric,
  longitude numeric
);
INSERT INTO drives VALUES
  (10, 1, '2026-01-01 01:00:00', '2026-01-01 01:10:00', 10, 200, 190, 20, 10, 60),
  (20, 1, '2026-01-01 02:00:00', '2026-01-01 02:20:00', 20, 200, 170, 20, 20, 145),
  -- 其他车辆必须被排除。
  (30, 2, '2026-01-01 03:00:00', '2026-01-01 03:10:00', 5, 100, 95, 20, 10, 40);
INSERT INTO positions VALUES
  (1, 1, 10, '2026-01-01 01:00:00',   0,  10, 0.0000, 0.0000),
  (2, 1, 10, '2026-01-01 01:00:01',  20,  -5, 0.0000, 0.0001),
  (3, 1, 10, '2026-01-01 01:00:02',  40,  10, 0.0001, 0.0001),
  (4, 1, 10, '2026-01-01 01:00:03',  20,   0, 0.0001, 0.0002),
  (5, 1, 20, '2026-01-01 02:00:00', 100,  30, 1.0000, 1.0000),
  (6, 1, 20, '2026-01-01 02:00:01', 140, -10, 1.0000, 1.0001),
  (7, 1, 20, '2026-01-01 02:00:02', 145,  20, 1.0000, 1.0002),
  (8, 1, 20, '2026-01-01 02:00:03', 100,   0, 1.0000, 1.0003),
  (9, 2, 30, '2026-01-01 03:00:00',  20,   5, 2.0000, 2.0000),
  (10,2, 30, '2026-01-01 03:00:01',  20,   5, 2.0000, 2.0001);
CREATE INDEX ON positions (car_id, date);
SQL

source_result=$(render_target 1 A | docker exec -i "$CONTAINER" \
    psql -X -q -tA -F '|' -v ON_ERROR_STOP=1 -U teslamate -d teslamate)
trend_result=$(render_target 6 A | docker exec -i "$CONTAINER" \
    psql -X -q -tA -F '|' -v ON_ERROR_STOP=1 -U teslamate -d teslamate)
detail_result=$(render_target 7 A | docker exec -i "$CONTAINER" \
    psql -X -q -tA -F '|' -v ON_ERROR_STOP=1 -U teslamate -d teslamate)

if printf '%s\n' "$source_result" | awk -F'|' '
    NF != 6 { exit 1 }
    { for (i=1; i<=6; i++) if ($i == "" || $i < 0 || $i > 100) exit 1 }
'; then
    pass_test "共享汇总一次返回六个 0–100 评分"
else
    fail_test "共享汇总一次返回六个 0–100 评分" "六个有效评分" "$source_result"
fi

source_projection=$(printf '%s\n' "$source_result" | awk -F'|' \
    '{print $1 "|" $4 "|" $5 "|" $3 "|" $6}')
trend_projection=$(printf '%s\n' "$trend_result" | awk -F'|' \
    'NF {print $2 "|" $3 "|" $4 "|" $5 "|" $6}')
assert_eq "单日趋势与共享汇总的五项公共评分一致" \
    "$source_projection" "$trend_projection"

detail_shape=$(printf '%s\n' "$detail_result" | awk -F'|' '
    NF { rows++; if (NF != 11) bad=1; for (i=7; i<=11; i++) if ($i == "") bad=1 }
    END { print rows "|" (bad ? "bad" : "ok") }
')
assert_eq "行程明细返回两行完整评分" "2|ok" "$detail_shape"

echo
echo "驾驶评分行为测试：通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "$FAIL" -ne 0 ]; then
    echo "汇总: $source_result"
    echo "趋势: $trend_result"
    echo "明细: $detail_result"
    exit 1
fi
