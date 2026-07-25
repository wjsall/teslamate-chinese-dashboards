#!/bin/bash
# 分时电价（TOU）行为测试：起一个隔离的 postgres，造出最小 TeslaMate 表结构，
# 装 sql/install-tou.sql，然后对 compute_tou_cost() 断言若干条业务规则。
#
# 为什么要有这个：TOU 是本项目唯一会算钱的部分，算错了用户看不出来——界面上只是一个
# 数字，没人知道它本该是多少。2026-07 的审计发现「配了一半电价时，未覆盖时段被当成
# 免费电静默低估总费用」，这个 bug 从 TOU 功能诞生起就在，四道 lint 门、五条部署冒烟
# 全都发现不了：它们只验对象在不在、容器起没起，不验**算出来的数对不对**。
#
# 这个脚本要回答的就是那类问题。它不需要真实 Tesla 账号、不碰用户任何东西，
# 只用一个一次性 postgres 容器，跑完自己删掉。
#
# 用法：bash scripts/test-tou-behavior.sh
# 依赖：docker
set -uo pipefail

cd "$(dirname "$0")/.."

PG_IMAGE="postgres:18-trixie"
CONTAINER="tou-behavior-test-$$"
PASS=0
FAIL=0

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql_q() { docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
psql_run() { docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -q -v ON_ERROR_STOP=1 >/dev/null; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✅ ${label}"
        PASS=$((PASS + 1))
    else
        echo "  ❌ ${label}"
        echo "       期望: ${expected}"
        echo "       实际: ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

echo "起隔离 postgres..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_USER=teslamate -e POSTGRES_PASSWORD=test -e POSTGRES_DB=teslamate \
    "$PG_IMAGE" >/dev/null
for _ in $(seq 1 60); do
    docker exec "$CONTAINER" pg_isready -U teslamate >/dev/null 2>&1 && break
    sleep 1
done

echo "造最小 TeslaMate 表结构 + 装 TOU SQL..."
psql_run <<'SQL'
CREATE TABLE geofences (id SERIAL PRIMARY KEY, name TEXT);
CREATE TABLE charging_processes (
  id SERIAL PRIMARY KEY,
  cost NUMERIC,
  start_date TIMESTAMP,
  end_date TIMESTAMP,
  charge_energy_added NUMERIC,
  charge_energy_used NUMERIC,
  car_id INT,
  geofence_id INT REFERENCES geofences(id),
  position_id INT,
  address_id INT
);
CREATE TABLE charges (
  id SERIAL PRIMARY KEY,
  charging_process_id INT REFERENCES charging_processes(id),
  date TIMESTAMP,
  charger_power NUMERIC,
  charger_phases INT,
  charge_energy_added NUMERIC,
  battery_level INT
);
INSERT INTO geofences (id, name) VALUES (1, '家');
SQL
docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
    < sql/install-tou.sql >/dev/null 2>&1 || { echo "❌ install-tou.sql 装失败"; exit 1; }

# ---------------------------------------------------------------------------
# 造一笔充电。时间一律用**本地时间**描述，函数内部按 Asia/Shanghai 解释，
# 所以写库时要减 8 小时转回 naive UTC。
#   $1 = cp_id
#   $2 = 本地起始 'YYYY-MM-DD HH:MM'
#   $3 = 持续分钟
#   $4 = 功率 kW
#   $5 = geofence_id（空串 = NULL）
#   $6 = 'dc' 表示直流快充（charger_phases 置 NULL）；缺省 = 交流（phases=3）
# 采样间隔 5 分钟（低于函数里 600 秒的异常 gap 阈值）。
# charge_energy_added 用积分值填，保证 GREATEST(added, used) 与采样电量自洽。
# ---------------------------------------------------------------------------
make_charge() {
    local cp=$1 local_start=$2 minutes=$3 power=$4 gf=${5:-} kind=${6:-ac}
    local gf_sql="NULL"; [ -n "$gf" ] && gf_sql="$gf"
    # charger_phases NULL = DC 快充，非 NULL = AC 慢充（compute_tou_cost 就是这样判的）
    local ph_sql="3"; [ "$kind" = "dc" ] && ph_sql="NULL"
    docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -q -v ON_ERROR_STOP=1 >/dev/null <<SQL
DO \$t\$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '${local_start}' - INTERVAL '8 hours';
  n INT := ${minutes} / 5;
  kwh NUMERIC := ${power} * ${minutes} / 60.0;
BEGIN
  INSERT INTO charging_processes (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES (${cp}, utc_start, utc_start + (${minutes} || ' minutes')::INTERVAL, kwh, kwh, 1, ${gf_sql});
  -- n 个间隔需要 n+1 个采样点（最后一个只用来给前一个提供 next_date）
  INSERT INTO charges (charging_process_id, date, charger_power, charger_phases)
  SELECT ${cp}, utc_start + (i * INTERVAL '5 minutes'), ${power}, ${ph_sql}
  FROM generate_series(0, n) AS i;
END
\$t\$;
SQL
}

echo ""
echo "===== 断言 ====="

# --- 1. 完全没配电价 → NULL（回退 TeslaMate 原 cost）---
make_charge 1 '2026-03-10 10:00' 60 7
assert_eq "没配任何电价 → NULL（回退原 cost）" "" "$(psql_q 'SELECT compute_tou_cost(1)')"

# --- 2. 全天覆盖单一电价 → kWh × rate ---
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0.5, '全天');
SQL
make_charge 2 '2026-03-10 10:00' 60 7
# 7kW × 1h = 7 kWh × 0.5 = 3.5
assert_eq "全天覆盖 0.5 元 → 7kWh 收 3.5 元" "3.5000" "$(psql_q 'SELECT compute_tou_cost(2)')"

# --- 3. 【本次修复的核心】只覆盖一半时段 → 必须 NULL，不能低估 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 8, 0.3, '谷');
SQL
# 07:00-09:00：前一小时有电价，后一小时没有
make_charge 3 '2026-03-10 07:00' 120 7
GOT3="$(psql_q 'SELECT compute_tou_cost(3)')"
assert_eq "电价只配到 08:00，充电跨到 09:00 → NULL（不是把缺口按 0 元算）" "" "$GOT3"
# 同时证明这不是"永远返回 NULL"：旧实现在这里会给出 14kWh × 0.15 = 2.1
if [ "$GOT3" = "2.1000" ]; then
    echo "       ↑ 这正是修复前的低估值，说明断言抓的就是那个 bug"
fi

# --- 4. 显式 0 元电价（免费充电桩）≠ 没配 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0, '免费');
SQL
make_charge 4 '2026-03-10 10:00' 60 7
assert_eq "明确配 0 元 → 返回 0（不能与「没配」混为一谈）" "0.0000" "$(psql_q 'SELECT compute_tou_cost(4)')"

# --- 5. 跨午夜规则 22:00→06:00 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 22, 6, 0.2, '夜谷');
SQL
make_charge 5 '2026-03-10 23:00' 60 7
assert_eq "跨午夜规则 22-6，23:00 充电 → 7kWh × 0.2 = 1.4" "1.4000" "$(psql_q 'SELECT compute_tou_cost(5)')"

# --- 6. AC/DC 区分：只配 AC，DC 充电应判为无覆盖 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, apply_to_dc, label) VALUES (NULL, 0, 24, 0.5, FALSE, '仅交流');
SQL
# 第 6 参传 dc 表示直流快充（charger_phases 置 NULL）
make_charge 6 '2026-03-10 10:00' 60 60 '' dc
assert_eq "只配 AC 电价，DC 快充 → NULL" "" "$(psql_q 'SELECT compute_tou_cost(6)')"

# --- 7. geofence 精确规则优先于全局默认 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0.9, '全局');
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (1,    0, 24, 0.1, '家里');
SQL
make_charge 7 '2026-03-10 10:00' 60 7 1
assert_eq "家里(geofence=1)有专属电价 → 用 0.1 而不是全局 0.9" "0.7000" "$(psql_q 'SELECT compute_tou_cost(7)')"

# --- 8. 季节规则：不在季节内的充电不应被该规则覆盖 ---
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, valid_from, valid_to, label)
VALUES (NULL, 0, 24, 0.7, DATE '2026-07-01', DATE '2026-09-30', '夏季');
SQL
make_charge 8 '2026-03-10 10:00' 60 7
assert_eq "只配了夏季电价，3 月充电 → NULL" "" "$(psql_q 'SELECT compute_tou_cost(8)')"
make_charge 9 '2026-08-10 10:00' 60 7
assert_eq "同一条夏季电价，8 月充电 → 7kWh × 0.7 = 4.9" "4.9000" "$(psql_q 'SELECT compute_tou_cost(9)')"

echo ""
echo "====================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ TOU 行为测试全通过（${PASS} 项）"
    exit 0
fi
echo "❌ TOU 行为测试失败 ${FAIL} 项 / 共 $((PASS + FAIL)) 项"
exit 1
