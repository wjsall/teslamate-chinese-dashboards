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

# ---------------------------------------------------------------------------
# 查询封装。这里有两个坑，都实测踩过，别改回去：
#
# 1) 老写法是 `psql ... 2>/dev/null | tr -d ...`：SQL 报错和「查出来是 NULL」都会变成
#    空字符串。于是所有「期望结果为 NULL」的断言在函数被删掉、改名、抛异常时照样打勾——
#    包括守着「电价缺口不能按 0 元算」的那条关键回归断言。实测把 compute_tou_cost 改个名，
#    6 条断言全绿。现在用 -P null=<NULL> 把 NULL 显式打印出来，报错另外输出一段
#    <SQL 出错> 前缀的文本，两者和空结果三者互不相同，断言骗不过去。
# 2) 脚本是 set -uo pipefail，**没有 -e**。夹具语句（建表、灌数据、改配置）的退出码
#    以前从没人看，装不上、写不进去全是静默的，测试照跑照绿。现在夹具一失败就直接中止。
# ---------------------------------------------------------------------------
psql_q() {
    local out
    if out=$(docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
                -tAX -P null='<NULL>' -v ON_ERROR_STOP=1 -c "$1" 2>&1); then
        printf '%s' "$out" | tr -d '[:space:]'
    else
        printf '<SQL出错>%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
    fi
}

# 夹具：跑一段 SQL，失败就整场中止（继续跑下去只会得到一串莫名其妙的断言结果）
psql_run() {
    local out
    if ! out=$(docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
                  -q -v ON_ERROR_STOP=1 2>&1); then
        echo ""
        echo "❌ 夹具 SQL 执行失败，测试中止："
        echo "$out" | sed 's/^/       /'
        exit 1
    fi
}

# 夹具：调一个函数、不关心返回值，但要求它成功
psql_call() {
    local out
    if ! out=$(docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
                  -tAX -v ON_ERROR_STOP=1 -c "$1" 2>&1); then
        echo ""
        echo "❌ 夹具调用失败，测试中止：$1"
        echo "$out" | sed 's/^/       /'
        exit 1
    fi
}

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
    psql_run <<SQL
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
assert_eq "没配任何电价 → NULL（回退原 cost）" "<NULL>" "$(psql_q 'SELECT compute_tou_cost(1)')"

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
assert_eq "电价只配到 08:00，充电跨到 09:00 → NULL（不是把缺口按 0 元算）" "<NULL>" "$GOT3"
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
assert_eq "只配 AC 电价，DC 快充 → NULL" "<NULL>" "$(psql_q 'SELECT compute_tou_cost(6)')"

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
assert_eq "只配了夏季电价，3 月充电 → NULL" "<NULL>" "$(psql_q 'SELECT compute_tou_cost(8)')"
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
psql_call "SELECT set_default_charging_rate(1.0)"
assert_eq "默认电价 1.0：无费用的那笔 → 7kWh × 1.0" "7.0000"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
assert_eq "TeslaMate 已有费用的那笔 → 保持 99，不被一口价盖掉" "99"     "$(psql_q 'SELECT effective_cost(11, (SELECT cost FROM charging_processes WHERE id=11))')"
assert_eq "原表没有被写入（cost 仍为空）" "<NULL>"     "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 10')"

# 11. 改默认电价 → 历史记录跟着重算（旧实现做不到：写进原表后就不再是 NULL）
psql_call "SELECT set_default_charging_rate(2.0)"
assert_eq "把默认电价改成 2.0 → 历史记录跟着变成 14" "14.0000"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"

# 12. 手工单价压过默认电价，且改默认价不会覆盖它
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (10, 3.33, 'manual', 0.5)
ON CONFLICT (charging_process_id) DO UPDATE SET cost = 3.33, source = 'manual', rate = 0.5;
SQL
assert_eq "手工指定 3.33 → 压过默认电价" "3.3300"     "$(psql_q 'SELECT effective_cost(10, NULL)')"
psql_call "SELECT set_default_charging_rate(5.0)"
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


# ===========================================================================
# 默认电价 ≠ 分时电价
#
# 「设默认电价」曾经会往 tou_rates 写两条 0-24 点全天规则（AC + DC 各一条）。
# 那等于宣布「所有充电所有时段都按这个价」，于是每一笔充电都算得出分时电价费用，
# 而分时电价的优先级高于 TeslaMate 自己记录的金额——超充账单 120 元、界面显示 7 元。
# 现在默认电价只写费用覆盖表，tou_rates 里有规则就意味着用户真的配过分时时段。
# ===========================================================================
echo ""
echo "===== 默认电价不再产生分时时段规则 ====="

psql_run <<'SQL'
DELETE FROM tou_rates;
DELETE FROM charging_process_cost_overrides;
DELETE FROM charging_processes_tou_cost;
SQL

make_charge 20 '2026-04-01 10:00' 60 7             # 家充，TeslaMate 没有金额
make_charge 21 '2026-04-01 14:00' 60 7 '' dc       # 超充，桩侧报了真实账单
psql_run <<'SQL'
UPDATE charging_processes SET cost = 120 WHERE id = 21;
SQL
psql_call "SELECT set_default_charging_rate(1.0)"

assert_eq "设默认电价不再往分时电价表写任何规则" "0" "$(psql_q 'SELECT count(*) FROM tou_rates')"
assert_eq "默认电价仍然作用于没有金额的那笔（7kWh × 1.0）" "7.0000" "$(psql_q 'SELECT effective_cost(20, (SELECT cost FROM charging_processes WHERE id=20))')"
assert_eq "超充的真实账单不被一口价顶掉（应为 120，不是 7）" "120" "$(psql_q 'SELECT effective_cost(21, (SELECT cost FROM charging_processes WHERE id=21))')"

# 回算是老实现真正把账单顶掉的那一步：升级脚本装完 SQL 就会跑它
psql_call "SELECT * FROM backfill_all_tou()"
assert_eq "跑完「重算所有历史」，超充账单仍然是 120" "120" "$(psql_q 'SELECT effective_cost(21, (SELECT cost FROM charging_processes WHERE id=21))')"
assert_eq "只设默认电价 → 旁路表一行都不该有" "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost')"

# 只设了默认电价的用户，配置审计要给一句人话，而不是报「12 个月全部空缺」
assert_eq "没配时段时，配置审计给的是说明" "ℹ未配分时时段" "$(psql_q 'SELECT severity FROM audit_tou_config(NULL)')"
assert_eq "…并且不会吓人地报一堆月份空缺" "0" "$(psql_q "SELECT count(*) FROM audit_tou_config(NULL) WHERE severity LIKE '%空缺%'")"

# 0 度的充电：没配分时时段时不能算出「0 元」把 TeslaMate 的金额盖掉
make_charge 22 '2026-04-02 10:00' 60 0
psql_run <<'SQL'
UPDATE charging_processes SET cost = 5 WHERE id = 22;
SQL
assert_eq "0 度充电、没配分时时段 → 不写旁路值（TeslaMate 的 5 元不被抹成 0）" "5" "$(psql_q 'SELECT effective_cost(22, (SELECT cost FROM charging_processes WHERE id=22))')"

# 升级上来的用户库里还留着旧版写的那两条全天规则。设默认电价时会把它们清掉——
# 这是在删用户数据库里的行，**必须当面告诉用户**，不能静默。
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, apply_to_dc)
VALUES (NULL, 0, 24, 1.0, '默认(AC)', FALSE);
SQL
LEGACY_MSG="$(psql_q "SELECT message FROM set_default_charging_rate(1.5)")"
case "$LEGACY_MSG" in
    *"移除了1条"*) LEGACY_TOLD="告诉了用户";;
    *)             LEGACY_TOLD="悄悄删掉了";;
esac
assert_eq "清掉旧版留下的全天规则 → 必须在返回消息里说清楚" "告诉了用户" "$LEGACY_TOLD"
assert_eq "…而且那条规则确实被删掉了" "0" "$(psql_q 'SELECT count(*) FROM tou_rates')"

# 反过来：没有旧规则可清时，别往正常路径上加噪音
case "$(psql_q "SELECT message FROM set_default_charging_rate(1.0)")" in
    *"顺带清理"*) LEGACY_QUIET="多了一段废话";;
    *)            LEGACY_QUIET="干净";;
esac
assert_eq "没有旧规则时，消息里不出现清理提示" "干净" "$LEGACY_QUIET"

# ===========================================================================
# 算不出分时电价时，必须把旁路表里的旧值删掉
#
# 老实现「算出来非 NULL 才写」、从不删：电价配全时算出一个数存进去，用户改成只覆盖一半
# 之后 compute_tou_cost 正确地拒绝计算，旧值却原封不动留着，界面继续显示一个已知算错的
# 数字，点多少次「重算历史」都不会变。「电价缺口按 0 元算」那个 bug 的受害者正是这批人。
# ===========================================================================
echo ""
echo "===== 算不出分时电价时清掉旧值 ====="

psql_run <<'SQL'
DELETE FROM tou_rates;
DELETE FROM charging_process_cost_overrides;
DELETE FROM charging_processes_tou_cost;
SQL

make_charge 30 '2026-03-12 07:00' 120 7            # 07:00-09:00，14 kWh
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0.5, '全天');
SQL
psql_call "SELECT * FROM backfill_all_tou()"
assert_eq "全天电价 → 回算写入 14kWh × 0.5 = 7" "7.0000" "$(psql_q 'SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = 30')"

# 把电价改成只覆盖 0-8 点，这笔充电跨到 09:00 → 算不出来
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 8, 0.3, '谷');
SQL
psql_call "SELECT * FROM backfill_all_tou()"
assert_eq "改成只覆盖一半 → 回算必须清掉旧值" "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 30')"
assert_eq "清掉之后费用回退，不再显示那个算错的 7" "<NULL>" "$(psql_q 'SELECT effective_cost(30, NULL)')"
assert_eq "回算计数：「配了但这笔有缺口」记在 gapped，不跟「没配」混在一起" "true" "$(psql_q 'SELECT (gapped > 0)::text FROM backfill_all_tou()')"

# 触发器路径（充电完成/费用变更时自动算）也必须会清
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0.5, '全天');
UPDATE charging_processes SET cost = cost WHERE id = 30;
SQL
assert_eq "触发器：电价配全时写入 7" "7.0000" "$(psql_q 'SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = 30')"
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 8, 0.3, '谷');
UPDATE charging_processes SET cost = cost WHERE id = 30;
SQL
assert_eq "触发器：算不出来时同样清掉旧值" "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 30')"

psql_run <<'SQL'
DELETE FROM tou_rates;
SQL
assert_eq "一条规则都没配 → 全部算「没配」，gapped 为 0" "0" "$(psql_q 'SELECT gapped FROM backfill_all_tou()')"

# ===========================================================================
# 老数据迁移：只认算得出来的行，且一行都不能丢
# ===========================================================================
echo ""
echo "===== 老数据迁移的安全边界 ====="

psql_run <<'SQL'
DELETE FROM charging_process_cost_overrides;
DELETE FROM tou_rates;
DELETE FROM charging_processes_tou_cost;
SQL
make_charge 40 '2026-03-11 10:00' 60 7
make_charge 41 '2026-03-11 12:00' 60 7
make_charge 42 '2026-03-11 14:00' 60 7
make_charge 43 '2026-03-11 16:00' 60 0             # 0 度充电
psql_run <<'SQL'
-- 40：模拟当年按 1.0 元/度写进 TeslaMate 记录的值（7kWh × 1.0 = 7.00）
UPDATE charging_processes SET cost = 7.00 WHERE id = 40;
-- 41：TeslaMate 自己报的费用，对不上这个乘法，不该被搬走
UPDATE charging_processes SET cost = 6.66 WHERE id = 41;
-- 42：金额对得上，但用户已经手工指定过单价 —— 搬不动，原值必须留在 TeslaMate 记录里
UPDATE charging_processes SET cost = 7.00 WHERE id = 42;
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (42, 1.23, 'manual', 0.2);
-- 43：0 度 0 元。0 = 0 对任何电价都成立，不加保护就会被任意电价「认领」并清空
UPDATE charging_processes SET cost = 0 WHERE id = 43;
SQL

assert_eq "试算：认出 1 笔可搬、1 笔因已有指定价搬不动" \
    "试算：有1笔充电的费用与「1.0元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空；另有1笔虽然对得上、但你已经给它们指定过价格，不会被动。去掉第二个参数即可实际执行。" \
    "$(psql_q "SELECT message FROM adopt_legacy_default_costs(1.0, TRUE)")"
assert_eq "试算不改任何东西（原表仍是 7.00）" "7.00" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 40')"

# 文档教用户「先试算再执行」，两次调用必须能在同一个事务里跑（老实现用临时表，第二次直接报错）
REPEAT_OUT="$(psql_q "SELECT message FROM adopt_legacy_default_costs(1.0, TRUE); SELECT message FROM adopt_legacy_default_costs(1.0, TRUE);")"
case "$REPEAT_OUT" in
    *"<SQL出错>"*) REPEAT_RESULT="报错";;
    *)             REPEAT_RESULT="没报错";;
esac
assert_eq "同一个事务里连着调两次 → 不报错" "没报错" "$REPEAT_RESULT"

# 下面这条断言自己就是「实际执行」那一次，不要在它前面再跑一遍：
# 搬完之后再调一次，报的当然是 0 笔，断言就成了走过场
assert_eq "实际执行报的是真搬走的笔数" "✅已把1笔按「1.0元/度」生成的费用搬进覆盖表，TeslaMate原始记录恢复为空。以后改默认电价，这些记录会跟着重算；卸载分时电价功能时，这些值会原样写回TeslaMate记录。" \
    "$(psql_q "SELECT message FROM adopt_legacy_default_costs(1.0)")"
assert_eq "搬走的那笔：TeslaMate 记录恢复为空" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 40')"
assert_eq "搬走的那笔：费用仍然显示 7（已在覆盖表里）" "7.0000" "$(psql_q 'SELECT effective_cost(40, NULL)')"
assert_eq "搬走的那笔：原值另存了一份，卸载时要用" "7.0000" "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"
assert_eq "对不上电价的那笔完全没动" "6.66" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 41')"
assert_eq "已有手工指定价的那笔：TeslaMate 原值必须还在（老实现会把它清空）" "7.00" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 42')"
assert_eq "已有手工指定价的那笔：显示的还是手工价" "1.2300" "$(psql_q 'SELECT effective_cost(42, NULL)')"

# 0 度充电：0 = 0 对任何电价都成立，填个离谱的价也不能把它认领走
assert_eq "0 度充电不会被任意电价「认领」（试算 0 笔）" \
    "试算：有0笔充电的费用与「999元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空；另有0笔虽然对得上、但你已经给它们指定过价格，不会被动。去掉第二个参数即可实际执行。" \
    "$(psql_q "SELECT message FROM adopt_legacy_default_costs(999, TRUE)")"
psql_call "SELECT message FROM adopt_legacy_default_costs(999)"
assert_eq "0 度充电的原值没被清空" "0" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 43')"

# ===========================================================================
# 卸载：费用显示完全回到 TeslaMate 自己的数据
#
# 搬迁之后，TeslaMate 的原值只存在于覆盖表里。直接删表 = 把 TeslaMate 自己的数据也删了，
# 与「卸载之后费用完全回到 TeslaMate 自己的数据」正好相反。
# 同时反过来也要成立：默认电价 / 手工单价算出来的数**不能**被写进 TeslaMate 记录。
# ⚠ 这一组会拆掉所有分时电价对象，必须放在最后。
# ===========================================================================
echo ""
echo "===== 卸载后回到 TeslaMate 自己的数据 ====="

make_charge 44 '2026-03-11 18:00' 60 7             # TeslaMate 没有金额，靠默认电价显示
psql_call "SELECT set_default_charging_rate(2.0)"
assert_eq "改默认电价会重算搬迁那笔的显示金额（7kWh × 2.0）" "14.0000" "$(psql_q 'SELECT cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"
assert_eq "…但 TeslaMate 的原值单独存着，没被重算覆盖" "7.0000" "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"

psql_call "SELECT uninstall_tou()"
assert_eq "卸载后：分时电价的表都没了" "<NULL>" "$(psql_q "SELECT to_regclass('public.tou_rates')::text")"
assert_eq "卸载后：搬走的那笔原值回到了 TeslaMate 记录（是 7，不是重算出来的 14）" "7.0000" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 40')"
assert_eq "卸载后：默认电价算出来的数没被写进 TeslaMate 记录" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 44')"
assert_eq "卸载后：手工指定的价格也没被写进 TeslaMate 记录" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 30')"
assert_eq "卸载后：TeslaMate 自己报的费用原样不动" "6.66" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 41')"

echo ""
echo "====================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ TOU 行为测试全通过（${PASS} 项）"
    exit 0
fi
echo "❌ TOU 行为测试失败 ${FAIL} 项 / 共 $((PASS + FAIL)) 项"
exit 1
