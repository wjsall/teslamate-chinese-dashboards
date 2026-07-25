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

# ===========================================================================
# 费用来源优先级（手工 > 分时电价 > 默认电价 > TeslaMate 原值）
# 以及「不写 TeslaMate 原表」这条边界——它是这套设计的核心承诺，必须有断言守着。
# ===========================================================================
echo ""
echo "===== 费用来源与优先级 ====="

psql_run <<'SQL'
DELETE FROM tou_rates;
DELETE FROM charging_process_cost_overrides;
DELETE FROM charging_processes_tou_cost;
SQL

# 10. 默认电价：只覆盖 TeslaMate 没有费用的记录，且不动原表
make_charge 10 '2026-03-10 10:00' 60 7          # cost 为空
make_charge 11 '2026-03-10 12:00' 60 7          # 下面给它一个 TeslaMate 原始费用
psql_run <<'SQL'
UPDATE charging_processes SET cost = 99 WHERE id = 11;
SQL
psql_q "SELECT set_default_charging_rate(1.0)" >/dev/null
assert_eq "默认电价 1.0：无费用的那笔 → 7kWh × 1.0" "7.0000"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
assert_eq "TeslaMate 已有费用的那笔 → 保持 99，不被一口价盖掉" "99"     "$(psql_q 'SELECT effective_cost(11, (SELECT cost FROM charging_processes WHERE id=11))')"
assert_eq "原表没有被写入（cost 仍为空）" ""     "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 10')"

# 11. 改默认电价 → 历史记录跟着重算（旧实现做不到：写进原表后就不再是 NULL）
psql_q "SELECT set_default_charging_rate(2.0)" >/dev/null
assert_eq "把默认电价改成 2.0 → 历史记录跟着变成 14" "14.0000"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"

# 12. 手工单价压过默认电价，且改默认价不会覆盖它
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (10, 3.33, 'manual', 0.5)
ON CONFLICT (charging_process_id) DO UPDATE SET cost = 3.33, source = 'manual', rate = 0.5;
SQL
assert_eq "手工指定 3.33 → 压过默认电价" "3.3300"     "$(psql_q 'SELECT effective_cost(10, NULL)')"
psql_q "SELECT set_default_charging_rate(5.0)" >/dev/null
assert_eq "再改默认电价 → 手工指定的那笔不受影响" "3.3300"     "$(psql_q 'SELECT effective_cost(10, NULL)')"

# 13. 分时电价压过默认电价、但让位于手工
psql_run <<'SQL'
DELETE FROM charging_process_cost_overrides WHERE charging_process_id = 12;
SQL
make_charge 12 '2026-03-10 14:00' 60 7
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (12, 1.11, 'default', 0.1);
INSERT INTO charging_processes_tou_cost (charging_process_id, cost_tou) VALUES (12, 2.22);
SQL
assert_eq "同时有默认价和分时电价 → 用分时电价" "2.2200" "$(psql_q 'SELECT effective_cost(12, NULL)')"
psql_run <<'SQL'
UPDATE charging_process_cost_overrides SET cost = 4.44, source = 'manual' WHERE charging_process_id = 12;
SQL
assert_eq "再加上手工指定 → 手工最优先" "4.4400" "$(psql_q 'SELECT effective_cost(12, NULL)')"

# 14. 老数据迁移：只认算得出来的行，其余一律不碰
# 夹具要清干净：上一组把默认电价设成 5.0，那会往 tou_rates 写规则，
# 后面 UPDATE cost 会触发 TOU 重算并写进旁路表——而分时电价优先级高于默认电价，
# 于是这一组读到的是 TOU 的值而不是迁移进来的值。清掉才能只测迁移本身。
psql_run <<'SQL'
DELETE FROM charging_process_cost_overrides;
DELETE FROM tou_rates;
DELETE FROM charging_processes_tou_cost;
SQL
make_charge 13 '2026-03-11 10:00' 60 7
make_charge 14 '2026-03-11 12:00' 60 7
psql_run <<'SQL'
-- 13：模拟当年按 1.0 元/度写进原表的值（7kWh × 1.0 = 7.00）
UPDATE charging_processes SET cost = 7.00 WHERE id = 13;
-- 14：TeslaMate 自己报的费用，对不上这个乘法，不该被搬走
UPDATE charging_processes SET cost = 6.66 WHERE id = 14;
SQL
assert_eq "迁移试算：只认出 1 笔" "试算：有1笔充电的费用与「1.0元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空。去掉第二个参数即可实际执行。"     "$(psql_q "SELECT message FROM adopt_legacy_default_costs(1.0, TRUE)")"
assert_eq "试算不改任何东西（原表仍是 7.00）" "7.00" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 13')"
psql_q "SELECT message FROM adopt_legacy_default_costs(1.0)" >/dev/null
assert_eq "实际执行后：算得出来的那笔原表恢复为空" "" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 13')"
assert_eq "费用仍然显示 7（已搬进覆盖表）" "7.0000" "$(psql_q 'SELECT effective_cost(13, NULL)')"
assert_eq "对不上的那笔完全没动" "6.66" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 14')"

echo ""
echo "====================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ TOU 行为测试全通过（${PASS} 项）"
    exit 0
fi
echo "❌ TOU 行为测试失败 ${FAIL} 项 / 共 $((PASS + FAIL)) 项"
exit 1
