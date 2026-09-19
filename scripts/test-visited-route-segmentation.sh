#!/bin/bash
# 足迹地图真实点与分段边行为测试。
# 直接执行 dashboard JSON 中的 Nodes/Edges SQL，防止测试复制一份“正确实现”自测。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="visited-route-test-$$"
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
    local ref_id="$1"
    python3 - "$ref_id" <<'PY'
import json
import re
import sys
from pathlib import Path

ref_id = sys.argv[1]
data = json.loads(Path('grafana/dashboards/zh-cn/visited.json').read_text(encoding='utf-8'))
panel = next(panel for panel in data['panels'] if panel.get('id') == 2)
target = next(target for target in panel['targets'] if target.get('refId') == ref_id)
sql = target['rawSql']
sql = sql.replace('$car_id', '1')
sql = sql.replace('${map_url}', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png')
sql = re.sub(
    r'\$__timeFilter\(p\.date\)',
    "p.date >= timestamp '2026-01-01 00:00:00' AND p.date < timestamp '2026-01-02 00:00:00'",
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
CREATE TABLE positions (
  id integer PRIMARY KEY,
  car_id integer NOT NULL,
  drive_id integer,
  date timestamp without time zone NOT NULL,
  latitude numeric,
  longitude numeric
);
INSERT INTO positions (id, car_id, drive_id, date, latitude, longitude) VALUES
  -- 同一分钟的两个真实点；旧 avg 坐标会生成并不存在的 (0, 1)。
  (1, 1, 10, '2026-01-01 00:00:05', 0, 0),
  (2, 1, 10, '2026-01-01 00:00:40', 0, 2),
  (3, 1, 10, '2026-01-01 00:01:05', 2, 2),
  -- 同一 drive 内的大断档必须断线。
  (4, 1, 10, '2026-01-01 00:10:00', 3, 3),
  -- 第二段行程绝不能与第一段连接。
  (5, 1, 20, '2026-01-01 00:00:10', 10, 10),
  (6, 1, 20, '2026-01-01 00:01:10', 10, 11),
  -- 非行程点和其他车辆必须排除。
  (7, 1, NULL, '2026-01-01 00:02:00', 20, 20),
  (8, 2, 30, '2026-01-01 00:02:00', 30, 30);
SQL
docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U teslamate -d teslamate \
    < sql/install-coord-functions.sql >/dev/null

nodes=$(render_target Nodes | docker exec -i "$CONTAINER" \
    psql -X -q -tA -F '|' -v ON_ERROR_STOP=1 -U teslamate -d teslamate)
edges=$(render_target Edges | docker exec -i "$CONTAINER" \
    psql -X -q -tA -F '|' -v ON_ERROR_STOP=1 -U teslamate -d teslamate)

assert_eq "每个行程/分钟只选择一个真实点" \
    $'1|0|0\n5|10|10\n3|2|2\n6|10|11\n4|3|3' "$nodes"
assert_eq "只创建同一行程且不超过 5 分钟的边" \
    $'1->3|1|3\n5->6|5|6' "$edges"

echo
echo "足迹地图分段行为测试：通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
