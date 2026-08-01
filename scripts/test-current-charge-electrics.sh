#!/bin/bash
# 当前充电状态及充电详情的交流输入电压/电流行为测试。
#
# 测试直接从目标 dashboard JSON 读取 rawSql，只替换 Grafana 变量/宏，
# 再把真实查询交给一次性 PostgreSQL 执行。测试覆盖 stat、gauge 和逐行曲线，
# 确保交流保留上游 V/A，直流或无效字段显示 No data。
#
# 用法：bash scripts/test-current-charge-electrics.sh
# 依赖：docker、python3
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PG_IMAGE="postgres:18-trixie"
CONTAINER="current-charge-electrics-test-$$"
PASS=0
FAIL=0

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail_test() {
    echo "❌ $1"
    FAIL=$((FAIL + 1))
}

pass_test() {
    echo "  ✅ $1"
    PASS=$((PASS + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass_test "$label"
    else
        fail_test "$label"
        echo "       期望: ${expected}"
        echo "       实际: ${actual}"
    fi
}

assert_close() {
    local label="$1" expected="$2" actual="$3" tolerance="$4"
    if awk -v expected="$expected" -v actual="$actual" -v tolerance="$tolerance" \
        'BEGIN {
            if (actual == "" || actual == "<NULL>") exit 1
            delta = actual - expected
            if (delta < 0) delta = -delta
            exit !(delta <= tolerance)
        }'; then
        pass_test "$label"
    else
        fail_test "$label"
        echo "       期望: ${expected} ± ${tolerance}"
        echo "       实际: ${actual:-<空>}"
    fi
}

assert_null() {
    local label="$1" actual="$2"
    if [ "$actual" = "<NULL>" ]; then
        pass_test "$label"
    else
        fail_test "$label"
        echo "       期望: NULL"
        echo "       实际: ${actual:-<空>}"
    fi
}

assert_row_count() {
    local label="$1" rows="$2" expected="$3" actual
    actual=$(printf '%s\n' "$rows" | awk 'NF {n++} END {print n + 0}')
    assert_eq "$label" "$expected" "$actual"
}

assert_power_identity() {
    local label="$1" power="$2" voltage="$3" current="$4" tolerance="$5"
    if awk -v power="$power" -v voltage="$voltage" -v current="$current" \
        -v tolerance="$tolerance" \
        'BEGIN {
            if (power == "" || voltage == "" || current == "" ||
                power == "<NULL>" || voltage == "<NULL>" || current == "<NULL>") exit 1
            delta = power - (voltage * current / 1000.0)
            if (delta < 0) delta = -delta
            exit !(delta <= tolerance)
        }'; then
        pass_test "$label"
    else
        fail_test "$label"
        echo "       P=${power}kW, V=${voltage}V, I=${current}A"
    fi
}

row_field() {
    local rows="$1" row="$2" column="$3"
    printf '%s\n' "$rows" | awk -F'|' -v wanted_row="$row" -v wanted_column="$column" '
        NF && ++line == wanted_row { print $wanted_column; found = 1; exit }
        END { if (!found) exit 1 }
    '
}

last_field() {
    local rows="$1"
    printf '%s\n' "$rows" | awk -F'|' 'NF { value = $NF } END { if (value != "") print value }'
}

assert_file_contract() {
    local result
    if result=$(python3 - <<'PY'
import json
import re
import sys
from pathlib import Path

TARGETS = [
    ('grafana/dashboards/zh-cn/CurrentChargeView.json', 49, 'Current'),
    ('grafana/dashboards/zh-cn/CurrentChargeView.json', 47, 'Voltage'),
    ('grafana/dashboards/zh-cn/overview.json', 10, 'A'),
    ('grafana/dashboards/zh-cn/overview.json', 15, 'B'),
    ('grafana/dashboards/zh-cn/overview.json', 15, 'C'),
    ('grafana/dashboards/internal/charge-details.json', 2, 'A'),
]

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def find_panel(path, panel_id):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    matches = [value for value in walk(data) if value.get('id') == panel_id]
    if len(matches) != 1:
        raise SystemExit(f'{path} panel {panel_id} 不唯一（{len(matches)}）')
    return matches[0]

def find_target(path, panel_id, ref_id):
    panel = find_panel(path, panel_id)
    matches = [target for target in panel.get('targets', []) if target.get('refId') == ref_id]
    if len(matches) != 1 or not str(matches[0].get('rawSql', '')).strip():
        raise SystemExit(f'{path} panel {panel_id} target {ref_id} 不唯一或无 rawSql')
    return panel, matches[0]

def property_value(panel, matcher_options, property_id):
    for override in panel.get('fieldConfig', {}).get('overrides', []):
        matcher = override.get('matcher', {})
        if matcher.get('id') != 'byName' or matcher.get('options') != matcher_options:
            continue
        for prop in override.get('properties', []):
            if prop.get('id') == property_id:
                return prop.get('value')
    return None

for path, panel_id, ref_id in TARGETS:
    _, target = find_target(path, panel_id, ref_id)
    sql = target['rawSql']
    for forbidden in ('96', '2.85', '0.013', 'usable_battery_level',
                      'charger_power * 1000', 'GREATEST(0.1,'):
        if forbidden.lower() in sql.lower():
            raise SystemExit(f'{path} panel {panel_id} target {ref_id} 仍包含估算写法 {forbidden!r}')
    for required in ('charger_power > 0', 'charger_phases >= 1'):
        if required.lower() not in sql.lower():
            raise SystemExit(f'{path} panel {panel_id} target {ref_id} 缺少交流门控 {required!r}')

for panel_id in (47, 49):
    panel, _ = find_target('grafana/dashboards/zh-cn/CurrentChargeView.json', panel_id,
                           'Current' if panel_id == 49 else 'Voltage')
    description = str(panel.get('description', ''))
    for word in ('仅显示交流充电器输入', 'TeslaMate 未记录真实直流', '功率和充入电量'):
        if word not in description:
            raise SystemExit(f'CurrentChargeView panel {panel_id} description 缺少 {word!r}')

overview_10 = find_panel('grafana/dashboards/zh-cn/overview.json', 10)
overview_15 = find_panel('grafana/dashboards/zh-cn/overview.json', 15)
charge_details_2 = find_panel('grafana/dashboards/internal/charge-details.json', 2)
if overview_10.get('fieldConfig', {}).get('defaults', {}).get('max') != 260:
    raise SystemExit('overview panel 10 gauge max 不是 260')
if property_value(overview_15, '交流输入电压[V]', 'max') != 250:
    raise SystemExit('overview panel 15 交流输入电压 override max 不是 250')
if property_value(overview_15, 'charger_actual_current', 'unit') != 'amp':
    raise SystemExit('overview panel 15 电流单位不是 amp')
if property_value(charge_details_2, 'charger_voltage', 'unit') != 'volt':
    raise SystemExit('charge-details panel 2 电压单位不是 volt')
if property_value(charge_details_2, 'charger_actual_current', 'unit') != 'amp':
    raise SystemExit('charge-details panel 2 电流单位不是 amp')
for panel_id, panel in ((10, overview_10), (15, overview_15), (2, charge_details_2)):
    text = json.dumps(panel, ensure_ascii=False)
    if '估算' in text or '96' in text:
        raise SystemExit(f'目标 panel {panel_id} 仍包含估算展示')
    for word in ('TeslaMate 未记录真实直流', '功率和充入电量'):
        if word not in text:
            raise SystemExit(f'目标 panel {panel_id} 缺少直流数据说明 {word!r}')
if overview_10.get('title') != '交流输入电压':
    raise SystemExit('overview panel 10 标题不是交流输入电压')
if property_value(overview_10, '交流输入电压[V]', 'displayName') != '交流输入电压':
    raise SystemExit('overview panel 10 电压展示名不是交流输入电压')
if property_value(overview_15, 'charger_actual_current', 'displayName') != '交流输入电流':
    raise SystemExit('overview panel 15 电流展示名不是交流输入电流')
if property_value(overview_15, '交流输入电压[V]', 'displayName') != '交流输入电压':
    raise SystemExit('overview panel 15 电压展示名不是交流输入电压')
if property_value(charge_details_2, 'charger_actual_current', 'displayName') != '交流输入电流':
    raise SystemExit('charge-details panel 2 电流展示名不是交流输入电流')
if property_value(charge_details_2, 'charger_voltage', 'displayName') != '交流输入电压':
    raise SystemExit('charge-details panel 2 电压展示名不是交流输入电压')
print('contract-ok')
PY
    ); then
        pass_test "6 条目标 SQL 无估算公式，交流门控、直流 No data、名称和量程契约正确"
    else
        fail_test "6 条目标 SQL 无估算公式，交流门控、直流 No data、名称和量程契约正确"
        echo "       ${result}"
    fi
}

# 读取目标 JSON 中一条真实 rawSql，并只替换测试需要的 Grafana 变量/宏。
target_sql() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path

path, panel_id_text, ref_id = sys.argv[1:]
panel_id = int(panel_id_text)
data = json.loads(Path(path).read_text(encoding='utf-8'))
found = []

def walk(value):
    if isinstance(value, dict):
        if value.get('id') == panel_id:
            found.extend(target.get('rawSql', '') for target in value.get('targets', [])
                         if target.get('refId') == ref_id)
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(data)
if len(found) != 1 or not found[0].strip():
    raise SystemExit(f'{path} panel {panel_id} target {ref_id} 找不到唯一 rawSql（{len(found)} 条）')

sql = found[0]
sql = sql.replace('$__timeFilter(date)',
                  "date BETWEEN TIMESTAMP '2026-08-01 00:00:00' AND TIMESTAMP '2026-08-01 23:59:59'")
sql = sql.replace('$__timeEpoch(date)', 'date')
sql = sql.replace('$__time(date)', 'date')
sql = sql.replace('$__time(c.date)', 'c.date')
sql = sql.replace('${preferred_range}', 'rated')
sql = sql.replace('${length_unit}', 'km').replace('$length_unit', 'km')
sql = sql.replace('${determine_phases:sqlstring}', "'2'")
sql = sql.replace('${temp_unit}', 'C').replace('$temp_unit', 'C')
sql = sql.replace('$car_id', '1')
sql = sql.replace('$charging_processes', '1')
sql = sql.replace('$charging_process_id', '1')
sql = sql.replace('$__interval', "'1 hour'")
print(sql)
PY
}

psql_fixture() {
    local output
    if ! output=$(docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
        -q -v ON_ERROR_STOP=1 2>&1); then
        echo "❌ 夹具 SQL 执行失败，测试中止："
        printf '       %s\n' "${output//$'\n'/$'\n       '}"
        exit 1
    fi
}

psql_exec() {
    local sql="$1" mode="${2:-scalar}" output_dir output
    local -a args=(-tA -P 'null=<NULL>' -v ON_ERROR_STOP=1)
    if [ "$mode" = "rows" ]; then
        args+=(-F '|')
    fi
    output_dir=$(mktemp -d "${TMPDIR:-/tmp}/current-charge-psql.XXXXXX") || exit 1
    if docker exec -i "$CONTAINER" psql -U teslamate -d teslamate \
        "${args[@]}" -c "$sql" >"$output_dir/stdout" 2>"$output_dir/stderr"; then
        output=$(<"$output_dir/stdout")
    else
        output=$(<"$output_dir/stdout")
        output+=$(<"$output_dir/stderr")
        rm -rf -- "$output_dir"
        echo "❌ dashboard SQL 执行失败：${output}" >&2
        exit 1
    fi
    rm -rf -- "$output_dir"
    printf '%s' "$output"
}

psql_query() {
    local output
    output=$(psql_exec "$1" scalar)
    printf '%s' "$output" | tr -d '[:space:]'
}

psql_rows() {
    psql_exec "$1" rows
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

echo "建立最小 TeslaMate charges/charging_processes 夹具..."
psql_fixture <<'SQL'
CREATE TABLE charging_processes (
  id INTEGER PRIMARY KEY,
  car_id INTEGER NOT NULL,
  start_date TIMESTAMP NOT NULL,
  end_date TIMESTAMP
);
CREATE TABLE charges (
  id BIGSERIAL PRIMARY KEY,
  charging_process_id INTEGER NOT NULL,
  date TIMESTAMP NOT NULL,
  charger_power NUMERIC,
  charger_voltage NUMERIC,
  charger_actual_current NUMERIC,
  charger_phases NUMERIC,
  charger_pilot_current NUMERIC,
  usable_battery_level NUMERIC,
  battery_level NUMERIC,
  rated_battery_range_km NUMERIC,
  battery_heater_on BOOLEAN,
  battery_heater BOOLEAN,
  outside_temp NUMERIC,
  charge_energy_added NUMERIC
);
CREATE FUNCTION convert_km(value NUMERIC, unit TEXT)
RETURNS NUMERIC LANGUAGE SQL IMMUTABLE AS $$ SELECT value $$;
CREATE FUNCTION convert_celsius(value NUMERIC, unit TEXT)
RETURNS NUMERIC LANGUAGE SQL IMMUTABLE AS $$ SELECT value $$;
SQL

CURRENT_SQL=$(target_sql grafana/dashboards/zh-cn/CurrentChargeView.json 49 Current) || exit 1
VOLTAGE_SQL=$(target_sql grafana/dashboards/zh-cn/CurrentChargeView.json 47 Voltage) || exit 1
OVERVIEW_GAUGE_SQL=$(target_sql grafana/dashboards/zh-cn/overview.json 10 A) || exit 1
OVERVIEW_CURRENT_CURVE_SQL=$(target_sql grafana/dashboards/zh-cn/overview.json 15 B) || exit 1
OVERVIEW_VOLTAGE_CURVE_SQL=$(target_sql grafana/dashboards/zh-cn/overview.json 15 C) || exit 1
CHARGE_DETAILS_SQL=$(target_sql grafana/dashboards/internal/charge-details.json 2 A) || exit 1

echo "行为断言：A 交流原始 V/A 保留（222V / 32A / 7kW，phases=1）"
psql_fixture <<'SQL'
TRUNCATE charges, charging_processes;
INSERT INTO charging_processes (id, car_id, start_date, end_date)
VALUES (1, 1, '2026-08-01 07:00:00', NULL);
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 7.0, 222, 32, 1, 32, NULL, 50, 250, false, false, 20, 1);
SQL
ac_current=$(psql_query "$CURRENT_SQL")
ac_voltage=$(psql_query "$VOLTAGE_SQL")
assert_close "A 当前电流保持 Tesla 原始值" "32" "$ac_current" "0.001"
assert_close "A 当前电压保持 Tesla 原始值" "222" "$ac_voltage" "0.001"
assert_power_identity "A 交流 V/A 与功率一致" "7" "$ac_voltage" "$ac_current" "0.2"

echo "行为断言：B 直流快充 V/A 缺失时返回 NULL（2V / 0A / 68kW，phases=NULL）"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 68.0, 2, 0, NULL, 0, 80, 80, 250, false, false, 20, 10);
SQL
dc_missing_current=$(psql_query "$CURRENT_SQL")
dc_missing_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "B 当前电流为 NULL" "$dc_missing_current"
assert_null "B 当前电压为 NULL" "$dc_missing_voltage"

echo "行为断言：C 即使直流 V/A 看似有效也返回 NULL（400V / 170A / 68kW，phases=NULL）"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 68.0, 400, 170, NULL, 0, NULL, 80, 250, false, false, 20, 10);
SQL
dc_valid_current=$(psql_query "$CURRENT_SQL")
dc_valid_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "C 当前电流为 NULL" "$dc_valid_current"
assert_null "C 当前电压为 NULL" "$dc_valid_voltage"

echo "行为断言：F 直流原始电压有效但无相数时仍返回 NULL（400V / 0A / 68kW）"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 68.0, 400, 0, NULL, 0, NULL, 80, 250, false, false, 20, 10);
SQL
dc_voltage_only_current=$(psql_query "$CURRENT_SQL")
dc_voltage_only_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "F 当前电流为 NULL" "$dc_voltage_only_current"
assert_null "F 当前电压为 NULL" "$dc_voltage_only_voltage"

echo "行为断言：G 异常 AC（phases=1、V/I 无效）不得套 DC 模型，应为 NULL"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 7.0, 2, 0, 1, 32, 80, 80, 250, false, false, 20, 1);
SQL
ac_invalid_current=$(psql_query "$CURRENT_SQL")
ac_invalid_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "G 异常 AC 电流为 NULL" "$ac_invalid_current"
assert_null "G 异常 AC 电压为 NULL" "$ac_invalid_voltage"

echo "行为断言：G2 AC 仅电压有效时按字段独立处理（222V / 0A / 7kW）"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 7.0, 222, 0, 1, 32, 80, 80, 250, false, false, 20, 1);
SQL
ac_voltage_only_current=$(psql_query "$CURRENT_SQL")
ac_voltage_only_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "G2 AC 电流缺失为 NULL" "$ac_voltage_only_current"
assert_close "G2 AC 电压独立保留原值" "222" "$ac_voltage_only_voltage" "0.001"

echo "行为断言：D2 较新直流采样不回退到较早交流样本"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 68.0, 400, 170, NULL, 0, NULL, 80, 250, false, false, 20, 10),
  (1, '2026-08-01 08:05:00', 68.0, 2, 0, NULL, 0, NULL, 80, 250, false, false, 20, 10);
SQL
fallback_current=$(psql_query "$CURRENT_SQL")
fallback_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "D2 当前电流为 NULL" "$fallback_current"
assert_null "D2 当前电压为 NULL" "$fallback_voltage"

echo "行为断言：D 当前 stat 的最后零功率尾样本返回 NULL"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 40.0, 2, 0, NULL, 0, 70, 70, 250, false, false, 20, 5),
  (1, '2026-08-01 08:05:00', 68.0, 2, 0, NULL, 0, 80, 80, 250, false, false, 20, 10),
  (1, '2026-08-01 08:10:00', 0.0, 0, 0, NULL, 0, 80, 80, 250, false, false, 20, 10);
SQL
latest_current=$(psql_query "$CURRENT_SQL")
latest_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "D 当前电流为 NULL" "$latest_current"
assert_null "D 当前电压为 NULL" "$latest_voltage"

echo "行为断言：E 只有零功率/NULL 时 stat 返回 NULL"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 0.0, 222, 32, 1, 32, 80, 80, 250, false, false, 20, 0),
  (1, '2026-08-01 08:05:00', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
SQL
no_data_current=$(psql_query "$CURRENT_SQL")
no_data_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "E 当前电流无有效有功样本为 NULL" "$no_data_current"
assert_null "E 当前电压无有效有功样本为 NULL" "$no_data_voltage"

echo "行为断言：E2 全部有功样本均为直流时返回 NULL"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 68.0, 2, 0, NULL, 0, NULL, 80, 250, false, false, 20, 10);
SQL
all_invalid_current=$(psql_query "$CURRENT_SQL")
all_invalid_voltage=$(psql_query "$VOLTAGE_SQL")
assert_null "E2 当前电流为 NULL" "$all_invalid_current"
assert_null "E2 当前电压为 NULL" "$all_invalid_voltage"

echo "行为断言：H overview panel 10 gauge 仅保留交流原始电压"
psql_fixture <<'SQL'
TRUNCATE charges, charging_processes;
INSERT INTO charging_processes (id, car_id, start_date, end_date)
VALUES (1, 1, '2026-08-01 07:00:00', NULL);
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, usable_battery_level, battery_level)
VALUES
  (1, '2026-08-01 08:00:00', 40.0, 2, 0, NULL, 70, 70),
  (1, '2026-08-01 08:05:00', 68.0, 2, 0, NULL, 80, 80),
  (1, '2026-08-01 08:10:00', 0.0, 0, 0, NULL, 80, 80);
SQL
gauge_dc_rows=$(psql_rows "$OVERVIEW_GAUGE_SQL")
gauge_dc_voltage=$(last_field "$gauge_dc_rows")
assert_row_count "H overview gauge 返回最近充电过程的一个样本" "$gauge_dc_rows" "1"
assert_null "H overview gauge 直流电压为 NULL" "$gauge_dc_voltage"

psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, usable_battery_level, battery_level)
VALUES
  (1, '2026-08-01 08:20:00', 7.0, 222, 32, 1, NULL, 50);
SQL
gauge_ac_rows=$(psql_rows "$OVERVIEW_GAUGE_SQL")
gauge_ac_voltage=$(last_field "$gauge_ac_rows")
assert_close "H overview gauge 保持 AC 原始电压" "222" "$gauge_ac_voltage" "0.001"

psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, usable_battery_level, battery_level)
VALUES
  (1, '2026-08-01 08:30:00', 68.0, 400, 170, NULL, NULL, 80),
  (1, '2026-08-01 08:35:00', 68.0, 2, 0, NULL, NULL, 80);
SQL
gauge_fallback_rows=$(psql_rows "$OVERVIEW_GAUGE_SQL")
gauge_fallback_voltage=$(last_field "$gauge_fallback_rows")
assert_row_count "H2 overview gauge 返回最新直流样本" "$gauge_fallback_rows" "1"
assert_null "H2 overview gauge 不回退到较早样本" "$gauge_fallback_voltage"

psql_fixture <<'SQL'
UPDATE charging_processes SET end_date = '2026-08-01 08:40:00' WHERE id = 1;
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, usable_battery_level, battery_level)
VALUES
  (1, '2026-08-01 08:35:00', 68.0, 2, 0, NULL, NULL, 80);
SQL
gauge_ended_rows=$(psql_rows "$OVERVIEW_GAUGE_SQL")
assert_null "H3 overview 已结束过程为 NULL" "$(last_field "$gauge_ended_rows")"

echo "行为断言：I overview panel 15 两条曲线仅保留交流原始 V/A"
psql_fixture <<'SQL'
TRUNCATE charges;
INSERT INTO charges
  (charging_process_id, date, charger_power, charger_voltage, charger_actual_current,
   charger_phases, charger_pilot_current, usable_battery_level, battery_level,
   rated_battery_range_km, battery_heater_on, battery_heater, outside_temp, charge_energy_added)
VALUES
  (1, '2026-08-01 08:00:00', 7.0, 222, 32, 1, 30, NULL, 50, 250, false, false, 20, 1),
  (1, '2026-08-01 08:05:00', 68.0, 2, 0, NULL, 40, 80, 80, 250, false, false, 20, 10),
  (1, '2026-08-01 08:10:00', 68.0, 400, 0, NULL, 50, NULL, 80, 250, false, false, 20, 10),
  (1, '2026-08-01 08:15:00', 7.0, 2, 0, 1, 60, 80, 80, 250, false, false, 20, 1),
  (1, '2026-08-01 08:20:00', 0.0, 222, 32, 1, 70, 80, 80, 250, false, false, 20, 1);
SQL
curve_current_rows=$(psql_rows "$OVERVIEW_CURRENT_CURVE_SQL")
curve_voltage_rows=$(psql_rows "$OVERVIEW_VOLTAGE_CURVE_SQL")
assert_row_count "I overview 电流曲线逐行保留 5 个样本" "$curve_current_rows" "5"
assert_row_count "I overview 电压曲线逐行保留 5 个样本" "$curve_voltage_rows" "5"
assert_close "I1 overview AC 电流原值" "32" "$(row_field "$curve_current_rows" 1 4)" "0.001"
assert_close "I1 overview AC 电压原值" "222" "$(row_field "$curve_voltage_rows" 1 2)" "0.001"
assert_null "I2 overview 直流电流为 NULL" "$(row_field "$curve_current_rows" 2 4)"
assert_null "I2 overview 直流电压为 NULL" "$(row_field "$curve_voltage_rows" 2 2)"
assert_null "I3 overview 无相数电流为 NULL" "$(row_field "$curve_current_rows" 3 4)"
assert_null "I3 overview 无相数电压为 NULL" "$(row_field "$curve_voltage_rows" 3 2)"
assert_null "I4 overview 异常 AC 电流为 NULL" "$(row_field "$curve_current_rows" 4 4)"
assert_null "I4 overview 异常 AC 电压为 NULL" "$(row_field "$curve_voltage_rows" 4 2)"
assert_null "I5 overview 无功率电流为 NULL" "$(row_field "$curve_current_rows" 5 4)"
assert_null "I5 overview 无功率电压为 NULL" "$(row_field "$curve_voltage_rows" 5 2)"

echo "行为断言：J internal charge-details panel 2 保留其他序列并逐行筛除直流 V/A"
detail_rows=$(psql_rows "$CHARGE_DETAILS_SQL")
assert_row_count "J internal 充电详情逐行返回 5 个样本" "$detail_rows" "5"
assert_close "J1 internal AC 电压原值" "222" "$(row_field "$detail_rows" 1 6)" "0.001"
assert_close "J1 internal AC 电流原值" "32" "$(row_field "$detail_rows" 1 8)" "0.001"
assert_null "J2 internal 直流电压为 NULL" "$(row_field "$detail_rows" 2 6)"
assert_null "J2 internal 直流电流为 NULL" "$(row_field "$detail_rows" 2 8)"
assert_null "J3 internal 无相数电压为 NULL" "$(row_field "$detail_rows" 3 6)"
assert_null "J3 internal 无相数电流为 NULL" "$(row_field "$detail_rows" 3 8)"
assert_null "J4 internal 异常 AC 电压为 NULL" "$(row_field "$detail_rows" 4 6)"
assert_null "J4 internal 异常 AC 电流为 NULL" "$(row_field "$detail_rows" 4 8)"
assert_null "J5 internal 无功率电压为 NULL" "$(row_field "$detail_rows" 5 6)"
assert_null "J5 internal 无功率电流为 NULL" "$(row_field "$detail_rows" 5 8)"
assert_eq "J internal pilot current 序列保持原值" "30" "$(row_field "$detail_rows" 1 9)"
assert_eq "J internal phase inference 序列仍执行" "2" "$(row_field "$detail_rows" 1 7)"

assert_file_contract

echo
echo "专项测试结果：通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "✅ 当前充电状态/充电详情交流输入电压电流行为测试通过"
