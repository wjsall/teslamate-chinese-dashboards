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

cd "$(dirname "$0")/.." || exit

PG_IMAGE="postgres:18-trixie"
CONTAINER="tou-behavior-test-$$"
# 升级路径断言的起点。
#
# 【语义：最后一个会创建 charging_processes_v 的版本】不是「上一个发行版」。
# 老版本建过、新版本不再建的对象只有从这里装起才会出现在库里；只测全新安装的套件对这类
# 对象是全盲的，v1.9.6 就是这么漏掉的。
#
# 所以这个值**不该随发版往前移**：下次发版后有人把它改成 v1.9.6 或更新，夹具装的那一版
# 根本不会创建 charging_processes_v，下面这一整组升级路径断言就变成空转——要么全绿但什么
# 也没验，要么被 fetch_legacy_tou_sql 的夹具自检拦下报「夹具不成立」。
# 只有当我们又引入一个新的「旧版创建、新版不再创建」的对象时，才需要重新考虑这个值该取哪个
# tag（那时多半还要再加一组以那个新对象为夹具自检的断言，而不是简单改数字）。
LEGACY_TAG="v1.9.5"
PASS=0
FAIL=0

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tou-behavior.XXXXXX") || exit 1

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -r -- "$TMP_ROOT" 2>/dev/null || true
}
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
    local capture_dir out
    capture_dir=$(mktemp -d "${TMPDIR:-/tmp}/tou-psql.XXXXXX") || {
        printf '<SQL出错>无法创建查询输出临时目录'
        return
    }
    if docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
            -tAX -P null='<NULL>' -v ON_ERROR_STOP=1 -c "$1" \
            >"$capture_dir/stdout" 2>"$capture_dir/stderr"; then
        out=$(<"$capture_dir/stdout")
        rm -r -- "$capture_dir"
        printf '%s' "$out" | tr -d '[:space:]'
    else
        out=$(printf '%s%s' "$(<"$capture_dir/stdout")" "$(<"$capture_dir/stderr")")
        rm -r -- "$capture_dir"
        printf '<SQL出错>%s' "$(printf '%s' "$out" | tr -d '[:space:]')"
    fi
}

# 与 psql_q 相同，但用于安装兼容性夹具的独立数据库。
psql_q_db() {
    local db="$1" query="$2" capture_dir out
    capture_dir=$(mktemp -d "${TMPDIR:-/tmp}/tou-psql-db.XXXXXX") || {
        printf '<SQL出错>无法创建查询输出临时目录'
        return
    }
    if docker exec -i "$CONTAINER" psql -U teslamate -d "$db" \
            -tAX -P null='<NULL>' -v ON_ERROR_STOP=1 -c "$query" \
            >"$capture_dir/stdout" 2>"$capture_dir/stderr"; then
        out=$(<"$capture_dir/stdout")
        rm -r -- "$capture_dir"
        printf '%s' "$out" | tr -d '[:space:]'
    else
        out=$(printf '%s%s' "$(<"$capture_dir/stdout")" "$(<"$capture_dir/stderr")")
        rm -r -- "$capture_dir"
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
# 判据是「目标库真的连得上」，不是 pg_isready：postgres 镜像 initdb 阶段会先起一个临时
# 服务器，那时 pg_isready 已经返回成功，而 teslamate 这个库还没建出来。实测偶发过紧接着
# 的夹具以 "database \"teslamate\" does not exist" 整场中止。
for _ in $(seq 1 60); do
    docker exec "$CONTAINER" psql -U teslamate -d teslamate -c 'SELECT 1' >/dev/null 2>&1 && break
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
  charge_energy_added NUMERIC NOT NULL,
  battery_level INT
);
-- 「✏️ 单笔充电单价」面板的下拉框会 LEFT JOIN 它取城市名，直接跑面板 SQL 时需要
CREATE TABLE addresses (id SERIAL PRIMARY KEY, city TEXT);
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
  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    ${cp},
    utc_start + (i * INTERVAL '5 minutes'),
    ${power},
    ${ph_sql},
    ${power} * i * 5 / 60.0
  FROM generate_series(0, n) AS i;
END
\$t\$;
SQL
}

# ---------------------------------------------------------------------------
# 按 TeslaMate 的**真实时序**造一笔充电，参数与 make_charge 完全一致：
#   ① 先建一条 end_date / 电量都是空的「正在充」记录
#   ② 逐条灌 charges 采样
#   ③ 最后一次 UPDATE 补上电量和 end_date，这笔才算完成
#
# 为什么非要有这个：上面的 make_charge 一条 INSERT 就把充电造成「已完成」，用它写出来的
# 用例永远是「先有充电、后设电价」。而「设完默认电价之后**新产生**的充电拿不到这个价」
# 那个 bug 只在相反的顺序下现形——电价先设好，充电后来才出现。用 make_charge 测这件事，
# 断言会绿，bug 照样在库里。
# ---------------------------------------------------------------------------
make_charge_live() {
    local cp=$1 local_start=$2 minutes=$3 power=$4 gf=${5:-} kind=${6:-ac}
    local gf_sql="NULL"; [ -n "$gf" ] && gf_sql="$gf"
    local ph_sql="3"; [ "$kind" = "dc" ] && ph_sql="NULL"
    psql_run <<SQL
DO \$t\$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '${local_start}' - INTERVAL '8 hours';
  n INT := ${minutes} / 5;
  kwh NUMERIC := ${power} * ${minutes} / 60.0;
BEGIN
  -- ① 充电刚开始：还没有 end_date，也还没有电量
  INSERT INTO charging_processes (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES (${cp}, utc_start, NULL, NULL, NULL, 1, ${gf_sql});
  -- ② 充电过程中不断写采样
  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    ${cp},
    utc_start + (i * INTERVAL '5 minutes'),
    ${power},
    ${ph_sql},
    ${power} * i * 5 / 60.0
  FROM generate_series(0, n) AS i;
  -- ③ 拔枪，这一笔才算完成
  UPDATE charging_processes
     SET end_date = utc_start + (${minutes} || ' minutes')::INTERVAL,
         charge_energy_added = kwh,
         charge_energy_used = kwh
   WHERE id = ${cp};
END
\$t\$;
SQL
}

# ---------------------------------------------------------------------------
# 从仪表盘 JSON 里取出「✏️ 单笔充电单价」表单**真正执行**的那条 SQL，把 Grafana 变量
# 换成具体值再交给 psql。
#   $1 = 'update'（保存/删除按钮那条）或 'options'（下拉框那条）
#   $2 = cp_id   $3 = 单价（空串 = 用户把单价清空了）
# 为什么要从 JSON 里读而不是在这里重写一份等价 SQL：这个面板的文案写着「清空保存即可
# 删除」，而它执行的那条语句往一个 NOT NULL 的列里写空值，每次删除都必然报错。
# 在测试里另写一条正确的 SQL，测的就是测试自己，不是用户点下去会发生什么。
# ---------------------------------------------------------------------------
charges_panel_sql() {
    python3 - "$1" "$2" "${3-}" <<'PY'
import json, sys
kind, cp_id, price = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open('grafana/dashboards/zh-cn/charges.json', encoding='utf-8'))
found = []
def walk(o):
    if isinstance(o, dict):
        if str(o.get('title', '')).startswith('✏️ 单笔充电单价'):
            if kind == 'update':
                found.append(o['options']['update']['payload']['rawSql'])
            else:
                found.append(o['targets'][0]['rawSql'])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)
if len(found) != 1:
    sys.exit('找不到唯一的「单笔充电单价」面板 SQL（找到 %d 条）' % len(found))
sql = (found[0].replace('${payload.cp_id}', cp_id)
                .replace('${payload.unit_price}', price)
                .replace('$car_id', '1'))
sys.stdout.write(sql)
PY
}

echo ""
echo "===== 断言 ====="

# psql 的 NOTICE 写 stderr。成功查询的比较值只能来自 stdout，否则任何函数新增一条提示
# 都会把原本精确的返回值断言打碎。
psql_run <<'SQL'
CREATE FUNCTION _tou_test_notice() RETURNS INT AS $$
BEGIN
  RAISE NOTICE '这条提示不属于查询返回值';
  RETURN 42;
END;
$$ LANGUAGE plpgsql;
SQL
assert_eq "成功查询只比较 stdout，不把 NOTICE 拼进返回值" \
    "42" "$(psql_q 'SELECT _tou_test_notice()')"
psql_run <<'SQL'
DROP FUNCTION _tou_test_notice();
SQL

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

# 定时充电会在真正开始前留下数小时的 0 功率等待期。23:05→00:00 丢了 55 分钟采样，
# 累计电量从 0.5833 增到 7，能确认这段确实充了电；但全天同价时电量落在哪一分钟都
# 不影响金额，不能仅凭断档把整笔费用打成 NULL。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES (NULL, 0, 24, 0.5, '统一');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-01 18:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (90, utc_start, utc_start + INTERVAL '6 hours', 7, 7, 1, NULL);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (90, utc_start,                           0, 3, 0),
    (90, utc_start + INTERVAL '5 hours',      7, 3, 0),
    (90, utc_start + INTERVAL '305 minutes',  7, 3, 0.583333),
    (90, utc_start + INTERVAL '6 hours',      0, 3, 7);
END
$t$;
SQL
assert_eq "累计值有效且全天同价：长断档仍按 7kWh × 0.5 计费" \
    "3.5000" "$(psql_q 'SELECT compute_tou_cost(90)')"

# 真正充电时丢采样，且断档跨进没有电价的时段，必须 fail-closed。真实累计值从
# 0.5833 增到 14，证明断档里有电量，不能只拿前 5 分钟代表整笔 14kWh。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES (NULL, 0, 8, 0.3, '谷');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-02 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (91, utc_start, utc_start + INTERVAL '2 hours', 14, 14, 1, NULL);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (91, utc_start,                         7, 3, 0),
    (91, utc_start + INTERVAL '5 minutes',  7, 3, 0.583333),
    (91, utc_start + INTERVAL '2 hours',    0, 3, 14);
END
$t$;
SQL
assert_eq "长断档有电量且跨进未配价时段 → NULL" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(91)')"

# 峰谷都配全时，长断档跨过切换点仍然无法知道多少电量属于哪一档，必须 fail-closed。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (NULL, 0, 11, 0.3, '谷'),
  (NULL, 11, 24, 0.6, '峰');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-03 10:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (92, utc_start, utc_start + INTERVAL '70 minutes', 8.166667, 8.166667, 1, NULL);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (92, utc_start,                          7, 3, 0),
    (92, utc_start + INTERVAL '5 minutes',   7, 3, 0.583333),
    (92, utc_start + INTERVAL '65 minutes',  7, 3, 7.583333),
    (92, utc_start + INTERVAL '70 minutes',  0, 3, 8.166667);
END
$t$;
SQL
assert_eq "长断档有电量且跨峰谷切换 → NULL" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(92)')"

# 普通充电中间丢了 45 分钟采样，但断档前后都是同一个有效电价，金额仍可精确计算。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES (NULL, 0, 24, 0.5, '统一');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-04 01:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (93, utc_start, utc_start + INTERVAL '2 hours', 14, 14, 1, NULL);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (93, utc_start,                           7, 3, 0),
    (93, utc_start + INTERVAL '30 minutes',   7, 3, 3.5),
    (93, utc_start + INTERVAL '45 minutes',   7, 3, 5.25),
    (93, utc_start + INTERVAL '60 minutes',   7, 3, 7),
    (93, utc_start + INTERVAL '105 minutes',  7, 3, 12.25),
    (93, utc_start + INTERVAL '2 hours',      0, 3, 14);
END
$t$;
SQL
assert_eq "普通充电中途丢 45 分钟采样、全天同价 → 14kWh × 0.5" \
    "7.0000" "$(psql_q 'SELECT compute_tou_cost(93)')"

# TeslaMate 的累计电量可能在同一笔充电中掉回。负增量同样证明断档里发生过充电，
# 且这里跨过 22:00 后未配置的时段，不能把整段按 21:00 的峰价计算。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (NULL, 0, 8, 0.3, '谷'),
  (NULL, 8, 22, 0.6, '峰');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-05 21:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (94, utc_start, utc_start + INTERVAL '215 minutes', 24.5, 24.5, 1, NULL);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (94, utc_start,                           7, 3, 20),
    (94, utc_start + INTERVAL '210 minutes',  7, 3, 2),
    (94, utc_start + INTERVAL '215 minutes',  0, 3, 2.6);
END
$t$;
SQL
assert_eq "累计电量掉回且长断档跨未配价时段 → NULL" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(94)')"

# 断档整段都落在未配置电价的时段时，断档起点和所有探测点的 rate 都是 NULL。
# NULL IS DISTINCT FROM NULL 为 false，不能因此把这段 20kWh 错按后面的白天价计费。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES (NULL, 6, 22, 0.5, '白天');

INSERT INTO charging_processes
  (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
VALUES
  (500, '2026-05-01 15:00', '2026-05-01 23:00', 27, 27, 1);

INSERT INTO charges
  (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
VALUES
  (500, '2026-05-01 15:00', 0, 3, 0),
  (500, '2026-05-01 21:30', 0, 3, 20),
  (500, '2026-05-01 22:00', 7, 3, 20),
  (500, '2026-05-01 22:30', 7, 3, 23.5),
  (500, '2026-05-01 23:00', 0, 3, 27);
SQL
assert_eq "长断档整段没有配置电价、起点 0kW → NULL" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(500)')"

# 定时充电等待期的哨兵/预热用电会让累计值轻微增长。0.3kWh 不应让整笔分时费用消失；
# 这段噪声按断档起点（峰价 0.6）计，后续 7kWh 按谷价 0.3，合计 2.28。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (NULL, 0, 8, 0.6, '峰'),
  (NULL, 8, 24, 0.3, '谷');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-06 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (96, utc_start, utc_start + INTERVAL '3 hours', 7.3, 7.3, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (96, utc_start,                         0, 3, 0),
    (96, utc_start + INTERVAL '2 hours',    7, 3, 0.3);

  -- 真正开始充电后恢复 TeslaMate 常见的 5 分钟采样，只有前面的等待期是长断档。
  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    96,
    utc_start + INTERVAL '2 hours' + i * INTERVAL '5 minutes',
    CASE WHEN i = 12 THEN 0 ELSE 7 END,
    3,
    0.3 + 7 * i / 12.0
  FROM generate_series(1, 12) AS i;
END
$t$;
SQL
assert_eq "跨峰谷等待期增加 0.3kWh → 正常计费，噪声按断档起点价" \
    "2.2800" "$(psql_q 'SELECT compute_tou_cost(96)')"

# 同样的跨价等待期若累计增加 3kWh，已经足以实质影响金额，仍须 fail-closed。
psql_run <<'SQL'
DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-07 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (97, utc_start, utc_start + INTERVAL '3 hours', 10, 10, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (97, utc_start,                         0, 3, 0),
    (97, utc_start + INTERVAL '2 hours',    7, 3, 3),
    (97, utc_start + INTERVAL '3 hours',    0, 3, 10);
END
$t$;
SQL
assert_eq "跨峰谷等待期增加 3kWh → 超过噪声界，拒绝计费" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(97)')"

# 阈值按整笔所有跨价长断档的累计电量判断：两段各 0.3kWh 不能分别钻过 0.5kWh 的绝对界。
# 除这两段外全部保持 5 分钟采样，避免别的长断档单独越界、替聚合逻辑把断言撑绿。
psql_run <<'SQL'
DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-08 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (98, utc_start, utc_start + INTERVAL '27 hours', 7.6, 7.6, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (98, utc_start,                       0, 3, 0),
    (98, utc_start + INTERVAL '2 hours',  0, 3, 0.3);

  -- 第一段之后到第二段之前没有充电，但仍每 5 分钟留一条样本。
  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    98,
    utc_start + INTERVAL '2 hours' + i * INTERVAL '5 minutes',
    0,
    3,
    0.3
  FROM generate_series(1, 264) AS i;

  -- 第二段同样只增加 0.3kWh；随后真实充电的 7kWh 也全部是 5 分钟采样。
  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (98, utc_start + INTERVAL '26 hours', 7, 3, 0.6);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    98,
    utc_start + INTERVAL '26 hours' + i * INTERVAL '5 minutes',
    CASE WHEN i = 12 THEN 0 ELSE 7 END,
    3,
    0.6 + 7 * i / 12.0
  FROM generate_series(1, 12) AS i;
END
$t$;
SQL
assert_eq "两段跨价长断档各 0.3kWh、合计 0.6kWh → 按整笔聚合后拒绝计费" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(98)')"

# 噪声豁免只处理“跨价但配置完整”的微小歧义。起点有价、断档跨进缺价时段时，
# 即使累计值只增加 0.3kWh，也必须回退，不能把“缺配置”当成“可忽略噪声”。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES (NULL, 0, 8, 0.6, '已配置');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-09 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (501, utc_start, utc_start + INTERVAL '2 hours', 0.3, 0.3, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (501, utc_start,                       0, 3, 0),
    (501, utc_start + INTERVAL '2 hours',  0, 3, 0.3);
END
$t$;
SQL
assert_eq "跨价噪声豁免不得跨进未配价时段（仅 0.3kWh 也要回退）" \
    "<NULL>" "$(psql_q 'SELECT compute_tou_cost(501)')"

# B1：19:00 插枪，等待到 23:30；等待期累计增加 0.4kWh，随后用 5 分钟采样充 40kWh。
# 峰价 0.7、谷价 0.3，真值 = 0.4×0.7 + 40×0.3 = 12.28。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (NULL, 0, 8, 0.3, '谷'),
  (NULL, 8, 22, 0.7, '峰'),
  (NULL, 22, 24, 0.3, '谷');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-10 19:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (502, utc_start, utc_start + INTERVAL '9 hours 30 minutes', 40.4, 40.4, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (502, utc_start,                               0, 3, 0),
    (502, utc_start + INTERVAL '4 hours 30 minutes', 8, 3, 0.4);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    502,
    utc_start + INTERVAL '4 hours 30 minutes' + i * INTERVAL '5 minutes',
    CASE WHEN i = 60 THEN 0 ELSE 8 END,
    3,
    0.4 + 8 * i / 12.0
  FROM generate_series(1, 60) AS i;
END
$t$;
SQL
assert_eq "B1：跨价等待期 0.4kWh + 谷时短采样 40kWh → 12.28" \
    "12.2800" "$(psql_q 'SELECT compute_tou_cost(502)')"

# B2：总电量和真值不变，但把谷时 01:00→03:00 的 14kWh 换成一段长断档。
# 这段起止同价、没有归属歧义，不应消耗前面 0.4kWh 跨价等待期的噪声预算。
psql_run <<'SQL'
DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-11 19:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (503, utc_start, utc_start + INTERVAL '9 hours 45 minutes', 40.4, 40.4, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (503, utc_start,                               0, 3, 0),
    (503, utc_start + INTERVAL '4 hours 30 minutes', 8, 3, 0.4);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    503,
    utc_start + INTERVAL '4 hours 30 minutes' + i * INTERVAL '5 minutes',
    8,
    3,
    0.4 + 8 * i / 12.0
  FROM generate_series(1, 18) AS i;

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (503, utc_start + INTERVAL '8 hours', 8, 3, 26.4);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  SELECT
    503,
    utc_start + INTERVAL '8 hours' + i * INTERVAL '5 minutes',
    CASE WHEN i = 21 THEN 0 ELSE 8 END,
    3,
    26.4 + 8 * i / 12.0
  FROM generate_series(1, 21) AS i;
END
$t$;
SQL
assert_eq "B2：另有谷时内部 14kWh 长断档 → 不吃噪声预算，仍为 12.28" \
    "12.2800" "$(psql_q 'SELECT compute_tou_cost(503)')"

# 1% 相对预算必须相对于真正参与定价的 raw_kwh。这个结构性夹具故意让 99.4kWh 的
# 短间隔累计增量与 charger_power=0 冲突：若拿 charging_processes 的 100kWh 当分母，
# 0.6kWh 跨价断档会被放过，全部 100kWh 被错误加权到 0.7 元，得到 70 元；按累计位置
# 计算的真值是 30.24 元，偏高 131.48%。选择 2% 上界，是给 1% 电量预算乘以本夹具
# 最大价差后的理论 1.33% 留出舍入余量；超过它就必须回退 NULL。
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (NULL, 0, 8, 0.7, '峰'),
  (NULL, 8, 24, 0.3, '谷');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-05-12 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id)
  VALUES
    (504, utc_start, utc_start + INTERVAL '70 minutes', 100, 100, 1);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (504, utc_start,                          0, 3, 0),
    (504, utc_start + INTERVAL '65 minutes',  0, 3, 0.6),
    (504, utc_start + INTERVAL '70 minutes',  0, 3, 100);
END
$t$;
SQL
assert_eq "大电量夹具：允许估算时偏差不得超过 2%，否则回退" \
    "回退(NULL)" "$(psql_q "WITH r AS (SELECT compute_tou_cost(504) AS cost)
      SELECT CASE
        WHEN cost IS NULL THEN '回退(NULL)'
        WHEN ABS(cost - 30.24) / 30.24 * 100 <= 2 THEN '≤2%'
        ELSE ROUND(ABS(cost - 30.24) / 30.24 * 100, 2)::text || '%'
      END
      FROM r")"

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
# 费用来源优先级：手工单价 > TeslaMate 记录的金额 > 分时电价 > 默认电价
#
# 这个顺序在 2026-07 改过一次。改之前是「手工 > 分时电价 > 默认电价 > TeslaMate 原值」，
# 也就是我们的估算排在 TeslaMate 记录的金额前面，实测出两个会算错钱的后果：
#   · 设默认电价时账单还没到，界面写 50；TeslaMate 隔天补上真实账单 120，界面还是 50，
#     重设电价、点重算都不自愈——估算值已经落库，谁也顶不掉它。
#   · charging_processes.cost 这一列没有来源标记（桩侧账单、上游按地点估的价、会话费、
#     用户自己在 TeslaMate 里填的，混在一起），我们无法可靠区分，所以只能定成
#     「任何估算都不得覆盖非空的 cp.cost」。免费超充会合法写 cost=0，连 0 都要认。
# 下面的断言既守「谁压过谁」，也守「什么时候产生的数据」——后者只有按 TeslaMate 的
# 真实时序造数据才测得出来（见 make_charge_live）。
# 以及「不写 TeslaMate 原表」这条边界——它是这套设计的核心承诺，必须有断言守着。
# ===========================================================================
echo ""
echo "===== 费用来源与优先级 ====="

psql_run <<'SQL'
DELETE FROM tou_rates;
DELETE FROM charging_process_cost_overrides;
DELETE FROM charging_processes_tou_cost;
SQL
psql_call "SELECT set_default_charging_rate(NULL)"

# 10. 默认电价：只作用于 TeslaMate 没有金额的记录，且不动原表
make_charge 10 '2026-03-10 10:00' 60 7          # cost 为空
make_charge 11 '2026-03-10 12:00' 60 7          # 下面给它一个 TeslaMate 原始费用
psql_run <<'SQL'
UPDATE charging_processes SET cost = 99 WHERE id = 11;
SQL
psql_call "SELECT set_default_charging_rate(1.0)"
assert_eq "默认电价 1.0：无费用的那笔 → 7kWh × 1.0" "7.00"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
assert_eq "TeslaMate 已有费用的那笔 → 保持 99，不被一口价盖掉" "99"     "$(psql_q 'SELECT effective_cost(11, (SELECT cost FROM charging_processes WHERE id=11))')"
assert_eq "原表没有被写入（cost 仍为空）" "<NULL>"     "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 10')"
# 默认电价改成读取时现算之后，它一行覆盖记录都不该写——写了就说明又回到「改价不生效、
# 新充电拿不到价」的老路上了
assert_eq "设默认电价不再逐笔写任何费用覆盖行" "0" "$(psql_q 'SELECT count(*) FROM charging_process_cost_overrides')"

# 10b. 【实测复现过】收藏点里的家充也要拿到默认电价
#      旧实现的条件里有 WHERE cp.geofence_id IS NULL，把所有在收藏点内的充电永久排除了。
#      而项目文档教用户先建一个叫「家」的收藏点，家充恰恰是这个功能的主力场景。
make_charge 13 '2026-03-10 16:00' 60 7 1
assert_eq "收藏点「家」里的充电 → 同样按默认电价 7.00（旧实现把围栏内的全排除了）" "7.00" \
    "$(psql_q 'SELECT effective_cost(13, (SELECT cost FROM charging_processes WHERE id=13))')"

# 10c. 【实测复现过】设完电价之后**新产生**的充电也要拿到它
#      旧实现是「设价那一刻给当时已有的充电各写一行覆盖值」，库里没有任何地方记着电价，
#      所以第二天新来的一笔家充是空的。必须用 make_charge_live 按真实时序造，
#      先造充电再设价的顺序测不出这个 bug。
make_charge_live 14 '2026-03-11 02:00' 60 7 1
assert_eq "设完电价之后新产生的充电 → 自动按默认电价 7.00" "7.00" \
    "$(psql_q 'SELECT effective_cost(14, (SELECT cost FROM charging_processes WHERE id=14))')"

# 10d. 【实测复现过】设完价之后 TeslaMate 才补上真实账单 → 下一次读取立刻显示账单
#      不重设电价、不点重算，就该自己顶上来。旧实现三条路都不自愈。
psql_run <<'SQL'
UPDATE charging_processes SET cost = 120 WHERE id = 14;
SQL
assert_eq "账单后到 → 立刻显示 120，不需要重设电价或重算" "120" \
    "$(psql_q 'SELECT effective_cost(14, (SELECT cost FROM charging_processes WHERE id=14))')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = NULL WHERE id = 14;
SQL

# 10e. cp.cost = 0（免费超充，上游会合法写 0）同样是「已有金额」，不许被估算顶掉
make_charge 15 '2026-03-11 08:00' 60 7
psql_run <<'SQL'
UPDATE charging_processes SET cost = 0 WHERE id = 15;
SQL
assert_eq "TeslaMate 记的是 0 元（免费桩）→ 显示 0，不被默认电价改成 7" "0" \
    "$(psql_q 'SELECT effective_cost(15, (SELECT cost FROM charging_processes WHERE id=15))')"

# 11. 改默认电价 → 历史立刻全部跟着变（现算的自然结果，不需要任何回填）
psql_call "SELECT set_default_charging_rate(2.0)"
assert_eq "把默认电价改成 2.0 → 历史记录立刻变成 14" "14.00"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
assert_eq "…收藏点里那笔也跟着变" "14.00"     "$(psql_q 'SELECT effective_cost(13, (SELECT cost FROM charging_processes WHERE id=13))')"

# 11b. 0 = 明确免费，NULL = 没设过，两者必须严格区分
psql_call "SELECT set_default_charging_rate(0)"
assert_eq "默认电价设成 0（这里的电免费）→ 算出 0，不是「没设过」" "0.00"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
psql_call "SELECT set_default_charging_rate(NULL)"
assert_eq "默认电价留空 → 不做任何估算，费用为空" "<NULL>"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
psql_call "SELECT set_default_charging_rate(1.0)"

# 12. 手工单价压过一切，且改默认价不会覆盖它
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (10, 3.33, 'manual', 0.5)
ON CONFLICT (charging_process_id) DO UPDATE SET cost = 3.33, source = 'manual', rate = 0.5;
SQL
assert_eq "手工指定 3.33 → 压过默认电价" "3.3300"     "$(psql_q 'SELECT effective_cost(10, NULL)')"
psql_call "SELECT set_default_charging_rate(5.0)"
assert_eq "再改默认电价 → 手工指定的那笔不受影响" "3.3300"     "$(psql_q 'SELECT effective_cost(10, NULL)')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = 88 WHERE id = 10;
SQL
assert_eq "手工单价也压过 TeslaMate 记录的金额（用户意图最强）" "3.3300"     "$(psql_q 'SELECT effective_cost(10, (SELECT cost FROM charging_processes WHERE id=10))')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = NULL WHERE id = 10;
DELETE FROM charging_process_cost_overrides WHERE charging_process_id = 10;
SQL
psql_call "SELECT set_default_charging_rate(1.0)"

# 13. TeslaMate 记录的金额压过分时电价；手工单价再压过它
#     这一条以前的断言写的是「分时电价压过 TeslaMate 原值」——那正是把真实账单顶掉的
#     那个顺序，是旧优先级留下的错误答案，现在反过来。
# 分时电价值一律让触发器自己算出来，不手工往旁路表里塞：任何一次 UPDATE
# charging_processes 都会触发重算，手工塞进去的值会被当场清掉（实测踩到过）。
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (NULL, 0, 24, 0.3, '全天');
SQL
make_charge 12 '2026-03-10 14:00' 60 7
psql_run <<'SQL'
UPDATE charging_processes SET cost = cost WHERE id = 12;   -- 让触发器在采样灌完之后重算
SQL
assert_eq "分时电价压过默认电价（默认电价排最后）" "2.1000" "$(psql_q 'SELECT effective_cost(12, NULL)')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = 33 WHERE id = 12;
SQL
assert_eq "同时有分时电价和 TeslaMate 金额 → 用 TeslaMate 的金额" "33" "$(psql_q 'SELECT effective_cost(12, (SELECT cost FROM charging_processes WHERE id=12))')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = 0 WHERE id = 12;
SQL
assert_eq "TeslaMate 记录 0 元且已有分时费用 → 仍用真实的 0 元" \
    "0" "$(psql_q 'SELECT effective_cost(12, (SELECT cost FROM charging_processes WHERE id=12))')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = NULL WHERE id = 12;
SQL
assert_eq "TeslaMate 没有金额时才轮到分时电价" "2.1000" "$(psql_q 'SELECT effective_cost(12, (SELECT cost FROM charging_processes WHERE id=12))')"
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (12, 4.44, 'manual', 0.6);
SQL
assert_eq "再加上手工指定 → 手工最优先" "4.4400" "$(psql_q 'SELECT effective_cost(12, NULL)')"

# 13b. cost_before_tou（分时电价对账面板的基准）用同一套顺序，只是抽掉分时电价那档
psql_run <<'SQL'
DELETE FROM charging_process_cost_overrides WHERE charging_process_id = 12;
UPDATE charging_processes SET cost = 33 WHERE id = 12;
SQL
assert_eq "对账基准：有 TeslaMate 金额时用它，不用分时电价" "33" "$(psql_q 'SELECT cost_before_tou(12, (SELECT cost FROM charging_processes WHERE id=12))')"
psql_run <<'SQL'
UPDATE charging_processes SET cost = NULL WHERE id = 12;
SQL
assert_eq "对账基准：没有 TeslaMate 金额时回落到默认电价（不是分时电价的 2.1）" "7.00" "$(psql_q 'SELECT cost_before_tou(12, (SELECT cost FROM charging_processes WHERE id=12))')"
psql_run <<'SQL'
DELETE FROM tou_rates;
DELETE FROM charging_processes_tou_cost WHERE charging_process_id = 12;
SQL

# ===========================================================================
# 「✏️ 单笔充电单价」面板：填得进去，也要真的删得掉
#
# 这个面板的说明写着「清空单价 + 保存 = 删除」，而它执行的是一条 INSERT，单价清空
# 就等于往一个 NOT NULL 的列里写空值——**每一次删除都必然报错**。它又是新优先级下
# 用户唯一的逃生口（想让某笔不按 TeslaMate 的金额算，只能靠它），必须真的能用。
# 下面跑的是从 charges.json 里读出来的那条 SQL 本身，不是等价重写。
# ===========================================================================
echo ""
echo "===== 单笔手工单价：能填能删 ====="

make_charge 16 '2026-03-12 10:00' 60 7
psql_run <<'SQL'
UPDATE charging_processes SET cost = 50 WHERE id = 16;
SQL
psql_call "$(charges_panel_sql update 16 0.5)"
assert_eq "面板保存单价 0.5 → 7kWh × 0.5 = 3.5，压过 TeslaMate 的 50" "3.5000" \
    "$(psql_q 'SELECT effective_cost(16, (SELECT cost FROM charging_processes WHERE id=16))')"
DELETE_OUT="$(psql_q "$(charges_panel_sql update 16 '')")"
case "$DELETE_OUT" in
    *"<SQL出错>"*) DELETE_RESULT="报错了";;
    *)             DELETE_RESULT="删掉了";;
esac
assert_eq "面板清空单价再保存 → 不报错（旧实现必然报 NOT NULL 违例）" "删掉了" "$DELETE_RESULT"
assert_eq "…覆盖行确实没了" "0" "$(psql_q 'SELECT count(*) FROM charging_process_cost_overrides WHERE charging_process_id = 16')"
assert_eq "…费用回到下一优先级（TeslaMate 记的 50）" "50" \
    "$(psql_q 'SELECT effective_cost(16, (SELECT cost FROM charging_processes WHERE id=16))')"

# 下拉框的「已填 / 空」标记必须按覆盖表判定：手工价现在写覆盖表、不写 TeslaMate 原表，
# 只看 cp.cost 的话，刚填过的充电永远显示成【空】。
psql_call "$(charges_panel_sql update 16 0.5)"
assert_eq "下拉框：刚填过单价的那笔标成「已填」" "1" \
    "$(psql_q "SELECT count(*) FROM ($(charges_panel_sql options 16 '')) q WHERE q.id = 16 AND q.display_name LIKE '已填%'")"
psql_call "$(charges_panel_sql update 16 '')"
assert_eq "下拉框：删掉手填价之后不再标「已填」" "0" \
    "$(psql_q "SELECT count(*) FROM ($(charges_panel_sql options 16 '')) q WHERE q.id = 16 AND q.display_name LIKE '已填%'")"

# 搬迁过来的那种行（original_cost 非空）删不得——原始金额只剩这一个落脚点。
# 面板要能识别它：不删行，只把它还原成没填过手工价的样子。
make_charge 17 '2026-03-12 14:00' 60 7
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate, original_cost)
VALUES (17, 7.00, 'default', 1.0, 7.00);
SQL
psql_call "$(charges_panel_sql update 17 0.9)"
assert_eq "在「存着原始金额」的那行上填手工价 → 原始金额不动" "7.0000" \
    "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 17')"
psql_call "$(charges_panel_sql update 17 '')"
assert_eq "再清空手工价 → 这行不能被删掉（删了原始金额就永久丢了）" "1" \
    "$(psql_q 'SELECT count(*) FROM charging_process_cost_overrides WHERE charging_process_id = 17')"
assert_eq "…原始金额还在" "7.0000" \
    "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 17')"
assert_eq "…手工价确实不再生效（回到默认电价 7.00）" "7.00" \
    "$(psql_q 'SELECT effective_cost(17, (SELECT cost FROM charging_processes WHERE id=17))')"


# ===========================================================================
# 默认电价 ≠ 分时电价
#
# 「设默认电价」曾经会往 tou_rates 写两条 0-24 点全天规则（AC + DC 各一条）。
# 那等于宣布「所有充电所有时段都按这个价」，于是每一笔充电都算得出分时电价费用，
# 而分时电价的优先级高于 TeslaMate 自己记录的金额——超充账单 120 元、界面显示 7 元。
# 现在默认电价只存 tou_settings 那一行、读取时现算，而且排在优先级最后；
# tou_rates 里有规则就意味着用户真的配过分时时段。
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
assert_eq "默认电价仍然作用于没有金额的那笔（7kWh × 1.0）" "7.00" "$(psql_q 'SELECT effective_cost(20, (SELECT cost FROM charging_processes WHERE id=20))')"
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
assert_eq "0 度充电、没配分时时段 → TeslaMate 的 5 元不被抹成 0" \
    "5" "$(psql_q 'SELECT effective_cost(22, (SELECT cost FROM charging_processes WHERE id=22))')"
assert_eq "…并且没有写入 0 元分时费用旁路值" \
    "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 22')"

# 升级上来的用户库里还留着旧版写的那两条全天规则。设默认电价时会把它们清掉——
# 这是在删用户数据库里的行，**必须当面告诉用户**，不能静默。
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label, apply_to_dc)
VALUES (NULL, 0, 24, 1.0, '默认(AC)', FALSE);
SQL
psql_call "SELECT * FROM backfill_all_tou()"
LEGACY_STALE_COUNT="$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost')"
assert_eq "旧版全天规则已经留下逐笔分时费用（后面的清理断言不是空跑）" \
    "1" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 20')"
LEGACY_MSG="$(psql_q "SELECT message FROM set_default_charging_rate(1.5)")"
case "$LEGACY_MSG" in
    *"移除了1条"*) LEGACY_TOLD="告诉了用户";;
    *)             LEGACY_TOLD="悄悄删掉了";;
esac
assert_eq "清掉旧版留下的全天规则 → 必须在返回消息里说清楚" "告诉了用户" "$LEGACY_TOLD"
assert_eq "…而且那条规则确实被删掉了" "0" "$(psql_q 'SELECT count(*) FROM tou_rates')"
assert_eq "…按旧规则算出的逐笔费用也立即清掉" \
    "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 20')"
case "$LEGACY_MSG" in
    *"清除了${LEGACY_STALE_COUNT}笔"*) LEGACY_RECALC_TOLD="报了清除笔数";;
    *)                               LEGACY_RECALC_TOLD="没报清除笔数";;
esac
assert_eq "…返回消息包含重算清除的准确笔数" "报了清除笔数" "$LEGACY_RECALC_TOLD"

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
# 这一组要看的是「分时电价旧值被清掉之后费用回退成空」。默认电价现在是读取时现算的，
# 留着上一组设的价会让费用回退成一个默认电价的数，把这条断言的锋芒磨掉。清空它。
psql_call "SELECT set_default_charging_rate(NULL)"

psql_run <<'SQL'
INSERT INTO geofences (id, name) VALUES (30, '缺口计数测试');
SQL
make_charge 30 '2026-03-12 07:00' 120 7 30         # 07:00-09:00，14 kWh；独立地点便于精确计数
psql_run <<'SQL'
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (30, 0, 24, 0.5, '全天');
SQL
psql_call "SELECT * FROM backfill_all_tou()"
assert_eq "全天电价 → 回算写入 14kWh × 0.5 = 7" "7.0000" "$(psql_q 'SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = 30')"

# 把电价改成只覆盖 0-8 点，这笔充电跨到 09:00 → 算不出来
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (30, 0, 8, 0.3, '谷');
SQL
psql_call "SELECT * FROM backfill_all_tou()"
assert_eq "改成只覆盖一半 → 回算必须清掉旧值" "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 30')"
assert_eq "清掉之后费用回退，不再显示那个算错的 7" "<NULL>" "$(psql_q 'SELECT effective_cost(30, NULL)')"
assert_eq "回算计数：目标充电精确记为 1 笔 gapped，不借用其他夹具凑数" \
    "1" "$(psql_q 'SELECT gapped FROM backfill_all_tou()')"

# 触发器路径（充电完成/费用变更时自动算）也必须会清
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (30, 0, 24, 0.5, '全天');
UPDATE charging_processes SET cost = cost WHERE id = 30;
SQL
assert_eq "触发器：电价配全时写入 7" "7.0000" "$(psql_q 'SELECT cost_tou FROM charging_processes_tou_cost WHERE charging_process_id = 30')"
psql_run <<'SQL'
DELETE FROM tou_rates;
INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label) VALUES (30, 0, 8, 0.3, '谷');
UPDATE charging_processes SET cost = cost WHERE id = 30;
SQL
assert_eq "触发器：算不出来时同样清掉旧值" "0" "$(psql_q 'SELECT count(*) FROM charging_processes_tou_cost WHERE charging_process_id = 30')"

psql_run <<'SQL'
DELETE FROM tou_rates;
SQL
assert_eq "一条规则都没配 → 全部算「没配」，gapped 为 0" "0" "$(psql_q 'SELECT gapped FROM backfill_all_tou()')"

# 配置完整但采样断档跨峰谷时，不能再记成「配置缺口」。用独立地点把两个计数钉死。
psql_run <<'SQL'
INSERT INTO geofences (id, name) VALUES (31, '采样断档计数测试');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-03-13 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (31, utc_start, utc_start + INTERVAL '2 hours', 14, 14, 1, 31);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (31, utc_start,                         7, 3, 0),
    (31, utc_start + INTERVAL '5 minutes',  7, 3, 0.583333),
    (31, utc_start + INTERVAL '2 hours',    0, 3, 14);
END
$t$;

INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (31, 0, 8, 0.3, '谷'),
  (31, 8, 24, 0.6, '峰');
SQL
assert_eq "回算计数：配置完整但跨价断档 → 配置缺口 0，采样断档 1" \
    "0,1" "$(psql_q "SELECT gapped || ',' || sampling_gapped FROM backfill_all_tou()")"
psql_run <<'SQL'
DELETE FROM tou_rates;
SQL

# 同一笔里既有跨价长断档，又有一段实际电量落在未配置时段。用户能修的是配置缺口，
# 所以 gapped 必须压过 sampling_gapped，不能告诉用户“不需要修改配置”。
psql_run <<'SQL'
INSERT INTO geofences (id, name) VALUES (32, '配置缺口优先级测试');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-03-14 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (32, utc_start, utc_start + INTERVAL '15 hours 5 minutes', 15.166667, 15.166667, 1, 32);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (32, utc_start,                              7, 3, 0),
    (32, utc_start + INTERVAL '5 minutes',       7, 3, 0.583333),
    (32, utc_start + INTERVAL '2 hours',         0, 3, 14),
    (32, utc_start + INTERVAL '14 hours 55 minutes', 7, 3, 14),
    (32, utc_start + INTERVAL '15 hours',        7, 3, 14.583333),
    (32, utc_start + INTERVAL '15 hours 5 minutes', 0, 3, 15.166667);
END
$t$;

INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (32, 0, 8, 0.3, '谷'),
  (32, 8, 22, 0.6, '峰');
SQL
assert_eq "同笔既有跨价断档又有未配价电量 → 记 gapped，不记 sampling_gapped" \
    "1,0" "$(psql_q "SELECT gapped || ',' || sampling_gapped FROM backfill_all_tou()")"
assert_eq "回算计数守恒：processed = updated + skipped + gapped + sampling_gapped + failed" \
    "1" "$(psql_q "SELECT (processed = updated + skipped + gapped + sampling_gapped + failed)::int FROM backfill_all_tou()")"
psql_run <<'SQL'
DELETE FROM tou_rates;
SQL

# 真因是跨价采样断档；同一笔另有一段“累计电量没涨，但残留功率非零”的未配价长间隔。
# compute_tou_cost 对后者按累计差值取 0，回算归因必须使用同一口径，不能误报配置缺口。
psql_run <<'SQL'
INSERT INTO geofences (id, name) VALUES (33, '残留功率归因测试');

DO $t$
DECLARE
  utc_start TIMESTAMP := TIMESTAMP '2026-03-15 07:00' - INTERVAL '8 hours';
BEGIN
  INSERT INTO charging_processes
    (id, start_date, end_date, charge_energy_added, charge_energy_used, car_id, geofence_id)
  VALUES
    (33, utc_start, utc_start + INTERVAL '16 hours', 14, 14, 1, 33);

  INSERT INTO charges
    (charging_process_id, date, charger_power, charger_phases, charge_energy_added)
  VALUES
    (33, utc_start,                                7, 3, 0),
    (33, utc_start + INTERVAL '5 minutes',         7, 3, 0.583333),
    (33, utc_start + INTERVAL '2 hours',           0, 3, 14),
    (33, utc_start + INTERVAL '14 hours 55 minutes', 0, 3, 14),
    (33, utc_start + INTERVAL '15 hours',          7, 3, 14),
    (33, utc_start + INTERVAL '16 hours',          0, 3, 14);
END
$t$;

INSERT INTO tou_rates (geofence_id, hour_start, hour_end, rate, label)
VALUES
  (33, 0, 8, 0.3, '谷'),
  (33, 8, 22, 0.6, '峰');
SQL
assert_eq "真因是采样断档，另有零电量残留功率落在缺价时段 → 不误报配置缺口" \
    "0,1" "$(psql_q "SELECT gapped || ',' || sampling_gapped FROM backfill_all_tou()")"
psql_run <<'SQL'
DELETE FROM tou_rates;
SQL

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
make_charge 46 '2026-03-11 17:00' 60 7             # 上游重算后 used 从 7 抬到 8
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
-- 46：旧版按 added=7kWh × 1.0 写入 7 元；上游迁移随后只把 used 抬高到 8kWh。
UPDATE charging_processes SET cost = 7.00, charge_energy_used = 8.00 WHERE id = 46;
SQL

assert_eq "试算：认出 2 笔可搬（含上游重算电量的旧行）、1 笔因已有指定价搬不动" \
    "试算：有2笔充电的费用与「1.0元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空；另有1笔虽然对得上、但你已经给它们指定过价格，不会被动。去掉第二个参数即可实际执行。" \
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
assert_eq "实际执行报的是真搬走的笔数，并说明默认电价被顺带补上了" "✅已把2笔按「1.0元/度」生成的费用搬进覆盖表，TeslaMate原始记录恢复为空。这些充电以后按默认电价显示费用；卸载分时电价功能时，原始金额会原样写回TeslaMate记录。｜顺带把默认电价设成了1.0元/度（原先是空的），这批充电才显示得出费用；随时可以到「默认电价」面板改。" \
    "$(psql_q "SELECT message FROM adopt_legacy_default_costs(1.0)")"
assert_eq "搬走的那笔：TeslaMate 记录恢复为空" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 40')"
assert_eq "搬走的那笔：费用仍然显示 7（改由默认电价现算）" "7.00" "$(psql_q 'SELECT effective_cost(40, NULL)')"
assert_eq "搬走的那笔：原值另存了一份，卸载时要用" "7.0000" "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"
assert_eq "对不上电价的那笔完全没动" "6.66" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 41')"
assert_eq "已有手工指定价的那笔：TeslaMate 原值必须还在（老实现会把它清空）" "7.00" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 42')"
assert_eq "已有手工指定价的那笔：显示的还是手工价" "1.2300" "$(psql_q 'SELECT effective_cost(42, NULL)')"
assert_eq "上游抬高 used 后：旧行仍被认领，TeslaMate 记录恢复为空" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 46')"
assert_eq "上游抬高 used 后：迁移前金额已备份，可在卸载时还原" "7.0000" "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 46')"

# 0 度充电：0 = 0 对任何电价都成立，填个离谱的价也不能把它认领走
assert_eq "0 度充电不会被任意电价「认领」（试算 0 笔）" \
    "试算：有0笔充电的费用与「999元/度」完全吻合，会被搬进覆盖表并把原始费用恢复为空；另有0笔虽然对得上、但你已经给它们指定过价格，不会被动。去掉第二个参数即可实际执行。" \
    "$(psql_q "SELECT message FROM adopt_legacy_default_costs(999, TRUE)")"
psql_call "SELECT message FROM adopt_legacy_default_costs(999)"
assert_eq "0 度充电的原值没被清空" "0" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 43')"

# ===========================================================================
# 升级迁移：旧版逐笔写下的「默认电价」要搬进新的存储，一个都不能猜错
#
# 上一版的默认电价没存在任何地方，只留下一批 source='default' 的逐笔覆盖行，
# 每行的 rate 记着当时用的电价。升级后不管的话，用户的默认电价凭空消失。
# 这里模拟出那种库的形状，再**真的重跑一次 sql/install-tou.sql**（就是用户升级时
# 发生的事），看迁移做得对不对。
# ===========================================================================
echo ""
echo "===== 升级迁移：默认电价搬进新的存储 ====="

reinstall_tou() {
    docker exec -i "$CONTAINER" psql -U teslamate -d teslamate -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1 \
        || { echo "❌ 重跑 install-tou.sql 失败（模拟升级）"; exit 1; }
}

# 建一个空库 + 最小 TeslaMate 表结构。装当前版本、装老版本都从这里起步。
#   $1 库名
#   $2 建表 / 装 SQL 用的角色（默认 teslamate）
#   $3 库本身的属主，默认与 $2 相同。只有要构造「装 SQL 的角色不是库/schema 属主」时才传：
#      库属主是 pg_database_owner 的成员、也就是 public schema 的属主，PostgreSQL 允许它删掉
#      schema 里属于别人的对象——用它当安装角色就永远构造不出「权限不足删不掉」那种库。
create_fixture_db() {
    local db="$1" db_owner="${2:-teslamate}" database_owner="${3:-}"
    [ -n "$database_owner" ] || database_owner="$db_owner"
    docker exec -i "$CONTAINER" psql -U teslamate -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE ${db} OWNER ${database_owner}" >/dev/null \
        || { echo "❌ 无法创建安装兼容性夹具数据库 ${db}"; exit 1; }
    if [ "$database_owner" != "$db_owner" ]; then
        docker exec -i "$CONTAINER" psql -U teslamate -d "$db" -v ON_ERROR_STOP=1 \
            -c "GRANT CREATE ON SCHEMA public TO ${db_owner}" >/dev/null \
            || { echo "❌ 无法给 ${db_owner} 授予 ${db} 的建表权限"; exit 1; }
    fi
    docker exec -i "$CONTAINER" psql -U "$db_owner" -d "$db" -v ON_ERROR_STOP=1 >/dev/null <<'SQL' \
        || { echo "❌ 无法创建安装兼容性最小表结构"; exit 1; }
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
  charge_energy_added NUMERIC NOT NULL,
  battery_level INT
);
SQL
}

# 建一个已完成首次安装、但刻意删掉后半段函数的数据库。重跑安装后检查这两个函数，
# 可以证明脚本没有被前半段的对象兼容分支提前中止。
prepare_install_fixture() {
    local db="$1" db_owner="${2:-teslamate}"
    create_fixture_db "$db" "$db_owner"
    docker exec -i "$CONTAINER" psql -U "$db_owner" -d "$db" -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1 \
        || { echo "❌ 安装兼容性夹具首次安装失败"; exit 1; }
    docker exec -i "$CONTAINER" psql -U "$db_owner" -d "$db" -v ON_ERROR_STOP=1 \
        -c "DROP FUNCTION effective_cost(INT, NUMERIC);
            DROP FUNCTION backfill_all_tou();" >/dev/null \
        || { echo "❌ 无法准备安装完整性夹具"; exit 1; }
}

# 把上一个发行版的 install-tou.sql 取到临时文件。取不到就整场中止：
# 悄悄跳过等于把「升级路径」这一整类断言变成走过场，而这正是 v1.9.6 漏掉 P0 的形状。
LEGACY_TOU_SQL="$TMP_ROOT/install-tou-${LEGACY_TAG}.sql"
fetch_legacy_tou_sql() {
    if ! git show "${LEGACY_TAG}:sql/install-tou.sql" >"$LEGACY_TOU_SQL" 2>"$TMP_ROOT/git-show.err"; then
        echo ""
        echo "❌ 取不到 ${LEGACY_TAG} 的 sql/install-tou.sql，升级路径断言无法进行："
        sed 's/^/       /' "$TMP_ROOT/git-show.err"
        echo "       浅克隆（fetch-depth: 1）不带 tag，CI 里这个 job 的 checkout 需要 fetch-depth: 0。"
        exit 1
    fi
    # 夹具自检：老版本必须真的会建那个视图，否则「升级后视图没了」是空欢喜一场。
    if ! grep -q 'VIEW charging_processes_v' "$LEGACY_TOU_SQL"; then
        echo ""
        echo "❌ ${LEGACY_TAG} 的 install-tou.sql 里找不到 charging_processes_v，夹具不成立"
        exit 1
    fi
}

# 建一个「装着上一个发行版」的库——用户升级前的真实形状。
prepare_legacy_upgrade_fixture() {
    local db="$1" db_owner="${2:-teslamate}" database_owner="${3:-}"
    create_fixture_db "$db" "$db_owner" "$database_owner"
    docker exec -i "$CONTAINER" psql -U "$db_owner" -d "$db" -v ON_ERROR_STOP=1 \
        <"$LEGACY_TOU_SQL" >"$TMP_ROOT/legacy-install.log" 2>&1 \
        || { echo "❌ ${LEGACY_TAG} 的 install-tou.sql 在夹具库 ${db} 装失败"
             sed 's/^/       /' "$TMP_ROOT/legacy-install.log" | tail -20
             exit 1; }
    # 与 prepare_install_fixture 同一个道理，但在升级夹具上更要紧：老版本也装过这两个函数，
    # 不先删掉的话，「其余部分照常装完」那条断言在安装中途夭折时照样是绿的——它看到的是
    # 老版本留下的那两个函数，不是这次装进去的。
    docker exec -i "$CONTAINER" psql -U teslamate -d "$db" -v ON_ERROR_STOP=1 \
        -c "DROP FUNCTION effective_cost(INT, NUMERIC);
            DROP FUNCTION backfill_all_tou();" >/dev/null \
        || { echo "❌ 无法准备升级路径的安装完整性夹具"; exit 1; }
}

# 在指定库上重跑当前版本的 install-tou.sql，把退出码回填到 $INSTALL_RC。
INSTALL_RC=0
install_current_tou() {
    local db="$1" db_user="${2:-teslamate}"
    if docker exec -i "$CONTAINER" psql -U "$db_user" -d "$db" -v ON_ERROR_STOP=1 \
            < sql/install-tou.sql >"$TMP_ROOT/current-install.log" 2>&1; then
        INSTALL_RC=0
    else
        INSTALL_RC=$?
    fi
}

# 上游迁移兼容：新装的 SQL 不能再创建对账视图，触发器也不能用 UPDATE OF 钉住列。
# 最后一条在独立库里原样执行 TeslaMate v4.1.1 的 cost 精度迁移，作为端到端证明。
prepare_install_fixture tou_upstream_alter
assert_eq "新装 TOU SQL 不再创建 charging_processes_v" \
    "<NULL>" "$(psql_q_db tou_upstream_alter "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "tou_recalc 不再用 UPDATE OF 列清单建立硬依赖" \
    "0" "$(psql_q_db tou_upstream_alter "SELECT cardinality(tgattr) FROM pg_trigger WHERE tgname = 'tou_recalc'")"
assert_eq "端到端：装 TOU SQL 后上游 cost 精度迁移成功" \
    "ALTERTABLE" "$(psql_q_db tou_upstream_alter 'ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)')"
assert_eq "触发器不再阻挡上游修改 end_date 类型" \
    "ALTERTABLE" "$(psql_q_db tou_upstream_alter 'ALTER TABLE charging_processes ALTER COLUMN end_date TYPE timestamp without time zone')"
assert_eq "移除对账视图后，上游可修改 charging_processes.id 类型" \
    "ALTERTABLE" "$(psql_q_db tou_upstream_alter 'ALTER TABLE charging_processes ALTER COLUMN id TYPE integer')"

# ===========================================================================
# 升级路径：老版本建过、新版本不再建的对象，必须由这次安装主动清掉
#
# 上面那一组只证明「全新安装不再创建对账视图」。绝大多数用户不是全新安装——他们库里
# 那个 charging_processes_v 是上一版建的，新版本「不再创建」一句话救不了他们：视图
# 原样留着，TeslaMate 升到 4.1.1 时那句
#   ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)
# 照样被 PostgreSQL 拒绝，TeslaMate 起不来、容器反复重启、行车充电全部停止记录。
# 所以下面每一条都从**真的装一遍上一个发行版**开始，这才是用户升级时的库。
# ===========================================================================
echo ""
echo "===== 升级路径：清掉旧版留下的对账视图 ====="

fetch_legacy_tou_sql

# ---- 核心回归锁：升级完视图必须没了，上游那句 ALTER 必须成功 ----
prepare_legacy_upgrade_fixture tou_legacy_view
assert_eq "夹具成立：装完 ${LEGACY_TAG} 库里确实有 charging_processes_v" \
    "charging_processes_v" \
    "$(psql_q_db tou_legacy_view "SELECT to_regclass('public.charging_processes_v')::text")"
install_current_tou tou_legacy_view
assert_eq "从 ${LEGACY_TAG} 升级：重跑当前版本安装退出码 0" "0" "$INSTALL_RC"
assert_eq "从 ${LEGACY_TAG} 升级：旧版留下的 charging_processes_v 已被删掉" \
    "<NULL>" \
    "$(psql_q_db tou_legacy_view "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "从 ${LEGACY_TAG} 升级：上游 cost 精度迁移成功（这条在 v1.9.6 上是红的）" \
    "ALTERTABLE" \
    "$(psql_q_db tou_legacy_view 'ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)')"
assert_eq "从 ${LEGACY_TAG} 升级：视图删干净了就不留待办给用户" \
    "<NULL>" "$(psql_q_db tou_legacy_view 'SELECT view_rebuild_note FROM tou_settings')"

# ---- 有用户对象依赖它：不许删（会连用户的东西一起没），改成留话 ----
# v1.9.2 的更新说明明确承诺过「你基于 charging_processes_v 建的查询或视图会保留」。
# DROP ... CASCADE 会把下面这个 my_charging_report 一起删掉，那是数据丢失。
prepare_legacy_upgrade_fixture tou_legacy_view_dep
docker exec -i "$CONTAINER" psql -U teslamate -d tou_legacy_view_dep -v ON_ERROR_STOP=1 \
    -c "CREATE VIEW my_charging_report AS
          SELECT id, cost_effective, cost_mode FROM charging_processes_v" >/dev/null \
    || { echo "❌ 无法创建依赖对账视图的用户视图夹具"; exit 1; }
install_current_tou tou_legacy_view_dep
assert_eq "有用户对象依赖时：安装退出码仍是 0（不许因为删不掉就整份中止）" "0" "$INSTALL_RC"
assert_eq "有用户对象依赖时：用户自己建的视图必须还在" \
    "my_charging_report" \
    "$(psql_q_db tou_legacy_view_dep "SELECT to_regclass('public.my_charging_report')::text")"
assert_eq "有用户对象依赖时：用户的视图还能查（不是个空壳）" \
    "0" "$(psql_q_db tou_legacy_view_dep 'SELECT count(*) FROM my_charging_report')"
assert_eq "有用户对象依赖时：旧视图保留不动，等用户自己处理" \
    "charging_processes_v" \
    "$(psql_q_db tou_legacy_view_dep "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "有用户对象依赖时：留一句话给用户，说清会挡住 TeslaMate 升级、要先删依赖" \
    "1" \
    "$(psql_q_db tou_legacy_view_dep "SELECT (
        view_rebuild_note LIKE '%charging_processes_v%'
        AND view_rebuild_note LIKE '%4.1.1%'
        AND view_rebuild_note LIKE '%依赖%'
      )::int FROM tou_settings")"
assert_eq "有用户对象依赖时：分时电价其余部分照常装完（不被这个视图连坐）" \
    "1" "$(psql_q_db tou_legacy_view_dep "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"
# 用户删掉自己的对象再跑一次 → 视图清掉、提示跟着撤销（否则每次升级都被吓一回）
docker exec -i "$CONTAINER" psql -U teslamate -d tou_legacy_view_dep -v ON_ERROR_STOP=1 \
    -c "DROP VIEW my_charging_report" >/dev/null \
    || { echo "❌ 无法删除用户视图夹具"; exit 1; }
install_current_tou tou_legacy_view_dep
assert_eq "用户删掉依赖对象后重跑：视图被清掉" \
    "<NULL>" \
    "$(psql_q_db tou_legacy_view_dep "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "用户删掉依赖对象后重跑：那句提示也跟着撤掉" \
    "<NULL>" "$(psql_q_db tou_legacy_view_dep 'SELECT view_rebuild_note FROM tou_settings')"
assert_eq "用户删掉依赖对象后重跑：上游 cost 精度迁移成功" \
    "ALTERTABLE" \
    "$(psql_q_db tou_legacy_view_dep 'ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)')"

# ---- 这个名字被别的类型的对象占着：也不许动，同样只留话 ----
prepare_legacy_upgrade_fixture tou_legacy_view_kind
docker exec -i "$CONTAINER" psql -U teslamate -d tou_legacy_view_kind -v ON_ERROR_STOP=1 \
    -c "DROP VIEW charging_processes_v;
        CREATE MATERIALIZED VIEW charging_processes_v AS
          SELECT id, cost FROM charging_processes" >/dev/null \
    || { echo "❌ 无法创建同名物化视图夹具"; exit 1; }
install_current_tou tou_legacy_view_kind
assert_eq "同名对象是物化视图：安装退出码仍是 0" "0" "$INSTALL_RC"
assert_eq "同名对象是物化视图：不删它（不确定是不是用户自己的东西）" \
    "charging_processes_v" \
    "$(psql_q_db tou_legacy_view_kind "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "同名对象是物化视图：留话说明它不是普通视图、需要用户自己确认" \
    "1" "$(psql_q_db tou_legacy_view_kind "SELECT (
        view_rebuild_note LIKE '%不是普通视图%'
        AND view_rebuild_note LIKE '%4.1.1%'
      )::int FROM tou_settings")"
assert_eq "同名对象是物化视图：分时电价其余部分照常装完" \
    "1" "$(psql_q_db tou_legacy_view_kind "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

# ---- 视图归属别的数据库角色：删不动，同样只留话 ----
docker exec -i "$CONTAINER" psql -U teslamate -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL' \
    || { echo "❌ 无法创建对账视图所有权夹具角色"; exit 1; }
CREATE ROLE tou_legacy_installer LOGIN;
CREATE ROLE tou_legacy_view_owner;
SQL
prepare_legacy_upgrade_fixture tou_legacy_view_owned tou_legacy_installer teslamate
docker exec -i "$CONTAINER" psql -U teslamate -d tou_legacy_view_owned -v ON_ERROR_STOP=1 \
    -c "ALTER VIEW charging_processes_v OWNER TO tou_legacy_view_owner" >/dev/null \
    || { echo "❌ 无法把对账视图转给别的角色"; exit 1; }
# 夹具自检：视图确实归别人、装 SQL 的角色确实不是 public schema 的属主。
# 两条有一条不成立，下面的断言就变成走过场（安装角色是 schema 属主时删得动别人的对象）。
if [ "$(psql_q_db tou_legacy_view_owned "SELECT pg_get_userbyid(c.relowner) FROM pg_class c WHERE c.relname = 'charging_processes_v'")" \
        != "tou_legacy_view_owner" ]; then
    echo "❌ 对账视图所有权夹具不正确"
    exit 1
fi
if [ "$(psql_q_db tou_legacy_view_owned "SELECT pg_has_role('tou_legacy_installer', n.nspowner, 'USAGE')::int FROM pg_namespace n WHERE n.nspname = 'public'")" \
        != "0" ]; then
    echo "❌ 对账视图所有权夹具不成立：安装角色仍是 public schema 的属主，删得动别人的对象"
    exit 1
fi
install_current_tou tou_legacy_view_owned tou_legacy_installer
assert_eq "视图归属别的角色：安装退出码仍是 0" "0" "$INSTALL_RC"
assert_eq "视图归属别的角色：视图保留不动" \
    "charging_processes_v" \
    "$(psql_q_db tou_legacy_view_owned "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "视图归属别的角色：留话请用户用属主身份删" \
    "1" "$(psql_q_db tou_legacy_view_owned "SELECT (
        view_rebuild_note LIKE '%属主%'
        AND view_rebuild_note LIKE '%4.1.1%'
      )::int FROM tou_settings")"
assert_eq "视图归属别的角色：分时电价其余部分照常装完" \
    "1" "$(psql_q_db tou_legacy_view_owned "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

# ---- 卸载：安装期删不掉的视图，用户主动要求卸载时必须真的拆掉 ----
# 卸载是用户亲口说「把这套东西全部拆掉」，这时 CASCADE 是他要的语义。
#
# 夹具刻意把视图改成**不引用旁路表**的形状：用户自己改过这个视图就是这样。
# 卸载里那句 DROP TABLE charging_processes_tou_cost CASCADE 于是连坐不到它——
# 必须有一句显式的 DROP VIEW charging_processes_v CASCADE，视图才真的会消失。
# 少了那一句，视图留在库里继续挡 TeslaMate 升级，用户以为已经卸载干净了。
prepare_legacy_upgrade_fixture tou_legacy_view_uninstall
docker exec -i "$CONTAINER" psql -U teslamate -d tou_legacy_view_uninstall -v ON_ERROR_STOP=1 \
    -c "DROP VIEW charging_processes_v;
        CREATE VIEW charging_processes_v AS SELECT id, cost FROM charging_processes;
        CREATE VIEW my_charging_report AS SELECT id FROM charging_processes_v" >/dev/null \
    || { echo "❌ 无法创建卸载夹具的用户视图"; exit 1; }
assert_eq "卸载夹具：视图确实不引用旁路表（否则删表的 CASCADE 会替它兜底，测不到那句显式 DROP）" \
    "0" "$(psql_q_db tou_legacy_view_uninstall "SELECT count(*) FROM pg_depend d
             JOIN pg_rewrite r ON r.oid = d.objid
             JOIN pg_class v ON v.oid = r.ev_class
             JOIN pg_class t ON t.oid = d.refobjid
            WHERE v.relname = 'charging_processes_v'
              AND t.relname = 'charging_processes_tou_cost'")"
install_current_tou tou_legacy_view_uninstall
assert_eq "卸载夹具：升级后视图仍在（有用户对象依赖）" \
    "charging_processes_v" \
    "$(psql_q_db tou_legacy_view_uninstall "SELECT to_regclass('public.charging_processes_v')::text")"
UNINSTALL_OUT="$(psql_q_db tou_legacy_view_uninstall "SELECT uninstall_tou()")"
case "$UNINSTALL_OUT" in
    *"<SQL出错>"*) UNINSTALL_RESULT="报错";;
    *"已卸载"*)    UNINSTALL_RESULT="卸载成功";;
    *)             UNINSTALL_RESULT="输出异常：${UNINSTALL_OUT}";;
esac
assert_eq "卸载夹具：uninstall_tou() 调用本身成功" "卸载成功" "$UNINSTALL_RESULT"
assert_eq "卸载后：旧版对账视图真的没了" \
    "<NULL>" \
    "$(psql_q_db tou_legacy_view_uninstall "SELECT to_regclass('public.charging_processes_v')::text")"
assert_eq "卸载后：上游 cost 精度迁移成功" \
    "ALTERTABLE" \
    "$(psql_q_db tou_legacy_view_uninstall 'ALTER TABLE charging_processes ALTER COLUMN cost TYPE numeric(14,2)')"

# 把仍会创建的 tou_rates_geofence_idx 换成其他同名对象。CREATE INDEX IF NOT EXISTS
# 必须安全跳过同名对象，且后半段函数仍要装完整。
prepare_index_name_fixture() {
    local db="$1" object_kind="$2" object_sql

    prepare_install_fixture "$db"
    docker exec -i "$CONTAINER" psql -U teslamate -d "$db" -v ON_ERROR_STOP=1 \
        -c "DROP INDEX tou_rates_geofence_idx;" >/dev/null \
        || { echo "❌ 无法删除安装兼容性夹具索引"; exit 1; }

    case "$object_kind" in
        materialized)
            object_sql="CREATE MATERIALIZED VIEW tou_rates_geofence_idx AS SELECT 1::INT AS id"
            ;;
        table)
            object_sql="CREATE TABLE tou_rates_geofence_idx (id INT)"
            ;;
        sequence)
            object_sql="CREATE SEQUENCE tou_rates_geofence_idx"
            ;;
        index)
            object_sql="CREATE INDEX tou_rates_geofence_idx ON charging_processes(id)"
            ;;
        view)
            object_sql="CREATE VIEW tou_rates_geofence_idx AS SELECT 1::INT AS id"
            ;;
        *)
            echo "❌ 未知的索引同名对象夹具类型：${object_kind}"
            exit 1
            ;;
    esac
    docker exec -i "$CONTAINER" psql -U teslamate -d "$db" -v ON_ERROR_STOP=1 \
        -c "$object_sql" >/dev/null \
        || { echo "❌ 无法创建 ${object_kind} 索引同名对象夹具"; exit 1; }
}

prepare_index_name_fixture tou_install_matview materialized
if docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_matview -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1; then
    MATVIEW_INSTALL_RC=0
else
    MATVIEW_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 是物化视图 → 重跑安装退出码 0" \
    "0" "$MATVIEW_INSTALL_RC"
assert_eq "物化视图同名冲突后 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_matview "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

prepare_index_name_fixture tou_install_table table
if docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_table -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1; then
    TABLE_INSTALL_RC=0
else
    TABLE_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 是普通表 → 重跑安装退出码 0" \
    "0" "$TABLE_INSTALL_RC"
assert_eq "普通表同名冲突后 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_table "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

prepare_index_name_fixture tou_install_sequence sequence
if docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_sequence -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1; then
    SEQUENCE_INSTALL_RC=0
else
    SEQUENCE_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 是序列 → 重跑安装退出码 0" \
    "0" "$SEQUENCE_INSTALL_RC"
assert_eq "序列同名冲突后 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_sequence "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

prepare_index_name_fixture tou_install_index index
if docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_index -v ON_ERROR_STOP=1 \
        < sql/install-tou.sql >/dev/null 2>&1; then
    INDEX_INSTALL_RC=0
else
    INDEX_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 已是其他索引 → 重跑安装退出码 0" \
    "0" "$INDEX_INSTALL_RC"
assert_eq "索引同名冲突后 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_index "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

# 普通视图与索引同处 relation 名字空间，也必须跳过而不截断后半段安装。
prepare_index_name_fixture tou_install_view view
if docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_view \
        -v ON_ERROR_STOP=1 < sql/install-tou.sql >/dev/null 2>&1; then
    VIEW_NAME_INSTALL_RC=0
else
    VIEW_NAME_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 是普通视图 → 重跑安装退出码 0" \
    "0" "$VIEW_NAME_INSTALL_RC"
assert_eq "普通视图同名冲突后 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_view "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

# 用普通安装角色建完整套对象，再把索引转给另一个角色。重跑时 IF NOT EXISTS 应跳过
# 他人拥有的同名对象，并继续创建后半段函数。
docker exec -i "$CONTAINER" psql -U teslamate -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL' \
    || { echo "❌ 无法创建索引所有权夹具角色"; exit 1; }
CREATE ROLE tou_fixture_installer LOGIN;
CREATE ROLE tou_fixture_index_owner;
SQL
prepare_install_fixture tou_install_owned_index tou_fixture_installer
docker exec -i "$CONTAINER" psql -U teslamate -d tou_install_owned_index \
    -v ON_ERROR_STOP=1 >/dev/null <<'SQL' \
    || { echo "❌ 无法准备外部角色索引夹具"; exit 1; }
DROP INDEX tou_rates_geofence_idx;
CREATE TABLE tou_fixture_owned_index_table (id INT);
ALTER TABLE tou_fixture_owned_index_table OWNER TO tou_fixture_index_owner;
CREATE INDEX tou_rates_geofence_idx ON tou_fixture_owned_index_table(id);
SQL
if [ "$(psql_q_db tou_install_owned_index "SELECT pg_get_userbyid(c.relowner) FROM pg_class c WHERE c.relname = 'tou_rates_geofence_idx'")" \
        != "tou_fixture_index_owner" ]; then
    echo "❌ 外部角色索引夹具所有权不正确"
    exit 1
fi
if docker exec -i "$CONTAINER" psql -U tou_fixture_installer -d tou_install_owned_index \
        -v ON_ERROR_STOP=1 < sql/install-tou.sql >/dev/null 2>&1; then
    OWNED_INDEX_INSTALL_RC=0
else
    OWNED_INDEX_INSTALL_RC=$?
fi
assert_eq "tou_rates_geofence_idx 归属别的角色 → 重跑安装退出码 0" \
    "0" "$OWNED_INDEX_INSTALL_RC"
assert_eq "外部角色拥有索引时 → effective_cost / backfill_all_tou 仍装完整" \
    "1" "$(psql_q_db tou_install_owned_index "SELECT (
        to_regprocedure('effective_cost(integer,numeric)') IS NOT NULL
        AND to_regprocedure('backfill_all_tou()') IS NOT NULL
      )::int")"

# 情形一：库里存着好几个不同的电价 → 不许猜，留空并留一句话给安装脚本讲给用户听。
# 现有的 40 号是搬迁来的行（rate 1.0，original_cost 非空），再塞两条 1.6 的派生行。
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (20, 11.20, 'default', 1.6), (30, 22.40, 'default', 1.6)
ON CONFLICT (charging_process_id) DO UPDATE
  SET cost = EXCLUDED.cost, source = 'default', rate = EXCLUDED.rate, original_cost = NULL;
UPDATE tou_settings
   SET default_rate = NULL, legacy_default_migrated_at = NULL, legacy_default_note = NULL
 WHERE id;
SQL
reinstall_tou
assert_eq "有多个不同的旧电价 → 默认电价留空，不瞎猜" "<NULL>" "$(psql_q 'SELECT default_rate FROM tou_settings')"
MIG_NOTE="$(psql_q "SELECT COALESCE(legacy_default_note, '<无>') FROM tou_settings")"
case "$MIG_NOTE" in
    *"重新设一次"*) MIG_TOLD="留了话给用户";;
    *)              MIG_TOLD="什么都没说";;
esac
assert_eq "…并且留下一句话请用户重新设一次（安装脚本会打出来）" "留了话给用户" "$MIG_TOLD"
assert_eq "…两个电价都写在话里了" "1" \
    "$(psql_q "SELECT (legacy_default_note LIKE '%1、1.6%')::int FROM tou_settings")"
assert_eq "迁移会清掉纯派生的覆盖行（它们的值改由现算接管）" "0" \
    "$(psql_q "SELECT count(*) FROM charging_process_cost_overrides WHERE source='default' AND original_cost IS NULL")"
assert_eq "存着 TeslaMate 原始金额的那行绝不能被清掉" "7.0000" \
    "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"
assert_eq "手工指定的那行也原样保留" "1.2300" \
    "$(psql_q "SELECT cost FROM charging_process_cost_overrides WHERE charging_process_id = 42 AND source='manual'")"

# 情形二：只有一个电价 → 直接迁进来，用户升级后默认电价不会消失。
# 上一步已经把派生行清掉了，现在库里只剩 40 号那条 rate=1.0。
psql_run <<'SQL'
UPDATE tou_settings
   SET default_rate = NULL, legacy_default_migrated_at = NULL
 WHERE id;
SQL
reinstall_tou
assert_eq "只有一个旧电价 → 直接迁进新的存储" "1.0000" "$(psql_q 'SELECT default_rate FROM tou_settings')"
assert_eq "…迁成功之后那句「请重新设置」的话要撤掉" "<NULL>" "$(psql_q 'SELECT legacy_default_note FROM tou_settings')"

# 情形三：用户自己把默认电价清空之后再升级，不许把旧值偷偷迁回来
psql_call "SELECT set_default_charging_rate(NULL)"
reinstall_tou
assert_eq "用户主动清空默认电价后再升级 → 保持清空，不被迁移撤销" "<NULL>" "$(psql_q 'SELECT default_rate FROM tou_settings')"

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
make_charge 45 '2026-03-11 19:00' 60 7             # TeslaMate 没有金额，用户单独指定了手工价
psql_run <<'SQL'
INSERT INTO charging_process_cost_overrides (charging_process_id, cost, source, rate)
VALUES (45, 3.50, 'manual', 0.5);
SQL
psql_call "SELECT set_default_charging_rate(2.0)"
assert_eq "改默认电价 → 搬迁那笔的显示金额跟着变（7kWh × 2.0）" "14.00" "$(psql_q 'SELECT effective_cost(40, (SELECT cost FROM charging_processes WHERE id=40))')"
assert_eq "…但 TeslaMate 的原值单独存着，没被重算覆盖" "7.0000" "$(psql_q 'SELECT original_cost FROM charging_process_cost_overrides WHERE charging_process_id = 40')"
assert_eq "卸载前：专用夹具仍保留 source=manual 的手工覆盖行" \
    "3.5000" "$(psql_q "SELECT cost FROM charging_process_cost_overrides WHERE charging_process_id = 45 AND source = 'manual'")"

psql_call "SELECT uninstall_tou()"
assert_eq "卸载后：分时电价的表都没了" "<NULL>" "$(psql_q "SELECT to_regclass('public.tou_rates')::text")"
assert_eq "卸载后：搬走的那笔原值回到了 TeslaMate 记录（是 7，不是重算出来的 14）" "7.0000" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 40')"
assert_eq "卸载后：默认电价算出来的数没被写进 TeslaMate 记录" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 44')"
assert_eq "卸载后：手工指定的价格也没被写进 TeslaMate 记录" "<NULL>" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 45')"
assert_eq "卸载后：TeslaMate 自己报的费用原样不动" "6.66" "$(psql_q 'SELECT cost FROM charging_processes WHERE id = 41')"

echo ""
echo "====================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ TOU 行为测试全通过（${PASS} 项）"
    exit 0
fi
echo "❌ TOU 行为测试失败 ${FAIL} 项 / 共 $((PASS + FAIL)) 项"
exit 1
