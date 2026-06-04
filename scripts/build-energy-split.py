#!/usr/bin/env python3
"""
生成 grafana/dashboards/zh-cn/sentry-drain.json
⚡ 行车 vs 停车能耗（月度）

可靠部分：把每月用电拆成「🚗 行车」+「🅿️ 停车」（kWh），能量守恒校验过
（行车+停车 ≈ 充入电池的 95%+）。

停车再按「车有没有按时休眠」分：
  😴 休眠掉电  = 停 ~15 分钟内就休眠（车待机休眠时的正常耗电）
  ☀️ 醒着掉电  = 停了 >15 分钟还没休眠（车醒着）

【为什么「醒着掉电」不细分哨兵】
车醒着掉的电是一锅混合：你坐车里等人开着空调、座舱过热保护、远程预热/预冷、
偶尔的哨兵、以及车单纯不休眠。TeslaMate 没有「有没有人在车里」的数据，
`is_climate_on` 也只说空调开没开、说不清是谁开的。实测换不同假设，「哨兵」
能从 5 跳到 130 kWh —— 说明分不准。所以本表不强行标哨兵，改在明细表里给出
每次的「室温 / 制热制冷」，让用户自己判断（制热=冷天还开空调，基本是有人在车里）。

能量口径：kWh = (rated_range 起 − rated_range 止) × cars.efficiency。

跑：python3 scripts/build-energy-split.py
"""
import json
from pathlib import Path

DS = {"type": "grafana-postgresql-datasource", "uid": "TeslaMate"}

MIN_DRIVE_RANGE_DROP_KM = 0.1
SLEEP_MIN = 15            # 停车 <= 此分钟内休眠 = 正常休眠；超过 = 醒着
THR_H = round(SLEEP_MIN / 60.0, 4)

STD_LINKS = [
    {"asDropdown": True, "icon": "external link", "tags": ["tesla"],
     "title": "车辆信息", "type": "dashboards"},
    {"asDropdown": True, "icon": "external link", "includeVars": False, "keepTime": False,
     "tags": ["battery"], "targetBlank": False, "title": "电池", "tooltip": "",
     "type": "dashboards", "url": ""},
    {"asDropdown": False, "icon": "doc", "includeVars": False, "keepTime": False,
     "tags": [], "targetBlank": True, "title": "中文文档", "tooltip": "",
     "type": "link", "url": "https://github.com/wjsall/teslamate-chinese-dashboards"},
]

GAPS_CTE = """  gaps AS (
    SELECT d.end_date AS ps, d.end_rated_range_km AS r0,
           LEAD(d.start_date)           OVER (ORDER BY d.start_date) AS pe,
           LEAD(d.start_rated_range_km) OVER (ORDER BY d.start_date) AS r1
    FROM drives d
    WHERE d.car_id = $car_id AND d.end_date IS NOT NULL
  ),
  clean AS (
    SELECT g.ps, g.pe, GREATEST(g.r0 - g.r1, 0) AS drop_km
    FROM gaps g
    WHERE g.pe IS NOT NULL AND g.pe > g.ps
      AND NOT EXISTS (
        SELECT 1 FROM charging_processes cp
        WHERE cp.car_id = $car_id AND cp.start_date >= g.ps AND cp.start_date < g.pe)
  )"""

# 每段停车「最长单段持续在线」（小时）。> THR_H = 醒着（没及时休眠）。仅用 states，轻量。
PARK_ONLINE_CTE = """  park_online AS (
    SELECT c.ps, c.pe, c.drop_km,
      COALESCE(MAX(EXTRACT(EPOCH FROM (LEAST(s.end_date, c.pe) - GREATEST(s.start_date, c.ps))))
               FILTER (WHERE s.state = 'online'), 0) / 3600.0 AS max_online_h
    FROM clean c
    LEFT JOIN states s ON s.car_id = $car_id AND s.end_date IS NOT NULL
                       AND s.start_date < c.pe AND s.end_date > c.ps
    GROUP BY c.ps, c.pe, c.drop_km
  )"""


def sql_kpi_drive():
    return f"""SELECT ROUND(SUM((start_rated_range_km - end_rated_range_km) * c.efficiency)::numeric, 1) AS v
FROM drives d JOIN cars c ON c.id = d.car_id
WHERE d.car_id = $car_id AND d.end_date IS NOT NULL
  AND (d.start_rated_range_km - d.end_rated_range_km) >= {MIN_DRIVE_RANGE_DROP_KM}
  AND $__timeFilter(d.start_date)"""


def sql_kpi_park():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
{GAPS_CTE}
SELECT ROUND((SUM(drop_km) * (SELECT e FROM eff))::numeric, 1) AS v
FROM clean WHERE $__timeFilter(ps)"""


def sql_kpi_park_pct():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
  drv AS (
    SELECT SUM((start_rated_range_km - end_rated_range_km) * (SELECT e FROM eff)) AS kwh
    FROM drives WHERE car_id = $car_id AND end_date IS NOT NULL
      AND (start_rated_range_km - end_rated_range_km) >= {MIN_DRIVE_RANGE_DROP_KM}
      AND $__timeFilter(start_date)
  ),
{GAPS_CTE},
  pk AS (SELECT SUM(drop_km) * (SELECT e FROM eff) AS kwh FROM clean WHERE $__timeFilter(ps))
SELECT ROUND(((SELECT kwh FROM pk) / NULLIF((SELECT kwh FROM drv) + (SELECT kwh FROM pk), 0) * 100)::numeric, 1) AS v"""


def sql_kpi_awake_count():
    return f"""WITH {GAPS_CTE.replace('  gaps', 'gaps', 1)},
{PARK_ONLINE_CTE}
SELECT COUNT(*) AS v FROM park_online WHERE max_online_h > {THR_H} AND $__timeFilter(ps)"""


def sql_monthly_drive_park():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
  drive_m AS (
    SELECT date_trunc('month', timezone('UTC', d.start_date), '$__timezone') AS m,
           SUM((d.start_rated_range_km - d.end_rated_range_km) * (SELECT e FROM eff)) AS kwh
    FROM drives d
    WHERE d.car_id = $car_id AND d.end_date IS NOT NULL
      AND (d.start_rated_range_km - d.end_rated_range_km) >= {MIN_DRIVE_RANGE_DROP_KM}
      AND $__timeFilter(d.start_date)
    GROUP BY 1
  ),
{GAPS_CTE},
  park_m AS (
    SELECT date_trunc('month', timezone('UTC', ps), '$__timezone') AS m,
           SUM(drop_km * (SELECT e FROM eff)) AS kwh
    FROM clean WHERE $__timeFilter(ps) GROUP BY 1
  )
SELECT to_char(COALESCE(dr.m, pk.m), 'YYYY-MM') AS "月份",
       ROUND(COALESCE(dr.kwh, 0)::numeric, 1) AS "行车电耗",
       ROUND(COALESCE(pk.kwh, 0)::numeric, 1) AS "停车电耗"
FROM drive_m dr FULL JOIN park_m pk ON dr.m = pk.m
ORDER BY 1"""


def sql_monthly_awake_split():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
{GAPS_CTE},
{PARK_ONLINE_CTE},
  m AS (
    SELECT date_trunc('month', timezone('UTC', ps), '$__timezone') AS m,
           SUM(drop_km) FILTER (WHERE max_online_h >  {THR_H}) AS awake_km,
           SUM(drop_km) FILTER (WHERE max_online_h <= {THR_H}) AS sleep_km
    FROM park_online WHERE $__timeFilter(ps) GROUP BY 1
  )
SELECT to_char(m, 'YYYY-MM') AS "月份",
       ROUND((COALESCE(awake_km, 0) * (SELECT e FROM eff))::numeric, 1) AS "☀️ 醒着掉电",
       ROUND((COALESCE(sleep_km, 0) * (SELECT e FROM eff))::numeric, 1) AS "😴 休眠掉电"
FROM m ORDER BY 1"""


def sql_pie_overall():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
  drv AS (
    SELECT SUM((start_rated_range_km - end_rated_range_km) * (SELECT e FROM eff)) AS kwh
    FROM drives WHERE car_id = $car_id AND end_date IS NOT NULL
      AND (start_rated_range_km - end_rated_range_km) >= {MIN_DRIVE_RANGE_DROP_KM}
      AND $__timeFilter(start_date)
  ),
{GAPS_CTE}
SELECT
  ROUND((SELECT kwh FROM drv)::numeric, 1) AS "🚗 行车",
  ROUND((COALESCE((SELECT SUM(drop_km) FROM clean WHERE $__timeFilter(ps)), 0) * (SELECT e FROM eff))::numeric, 1) AS "🅿️ 停车" """


def sql_awake_table():
    return f"""WITH eff AS (SELECT efficiency AS e FROM cars WHERE id = $car_id),
{GAPS_CTE},
{PARK_ONLINE_CTE}
SELECT
  to_char(timezone('$__timezone', timezone('UTC', ps)), 'YYYY-MM-DD HH24:MI') AS "停车开始",
  ROUND((EXTRACT(EPOCH FROM (pe - ps)) / 3600)::numeric, 1) AS "停车时长(h)",
  ROUND((max_online_h * 60)::numeric, 0) AS "醒着(分钟)",
  ROUND(((cs.n_clim::numeric / NULLIF(cs.n, 0)) * max_online_h * 60)::numeric, 0) AS "空调约开(分钟)",
  ROUND(cs.out_t::numeric, 0) AS "室温℃",
  CASE
    WHEN cs.n_clim::float / NULLIF(cs.n, 0) < 0.15 THEN '空调基本没开·可能哨兵'
    WHEN cs.in_clim > cs.out_clim + 2 THEN '制热·可能有人在车'
    ELSE '制冷·过热或开AC'
  END AS "判断",
  ROUND((drop_km * (SELECT e FROM eff))::numeric, 2) AS "停车电耗(kWh)"
FROM park_online
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS n,
         COUNT(*) FILTER (WHERE p.is_climate_on) AS n_clim,
         AVG(p.outside_temp) AS out_t,
         AVG(p.inside_temp)  FILTER (WHERE p.is_climate_on) AS in_clim,
         AVG(p.outside_temp) FILTER (WHERE p.is_climate_on) AS out_clim
  FROM positions p
  WHERE p.car_id = $car_id AND p.date >= park_online.ps AND p.date <= park_online.pe
) cs ON TRUE
WHERE max_online_h > {THR_H} AND $__timeFilter(ps)
ORDER BY drop_km DESC
LIMIT 30"""


# ───────────────────────── panel 构造 ─────────────────────────
def text_panel(id_, content, gridPos):
    return {"id": id_, "type": "text", "title": "",
            "options": {"mode": "markdown", "content": content}, "gridPos": gridPos}


def stat_panel(id_, title, sql, gridPos, decimals=1, fixed_color="blue"):
    return {
        "id": id_, "type": "stat", "title": title, "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {"defaults": {
            "unit": "none", "decimals": decimals,
            "color": {"mode": "fixed", "fixedColor": fixed_color},
            "thresholds": {"mode": "absolute", "steps": [{"color": fixed_color, "value": None}]},
        }, "overrides": []},
        "options": {
            "reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
            "orientation": "auto", "textMode": "value", "colorMode": "value",
            "graphMode": "none", "justifyMode": "auto",
        },
        "gridPos": gridPos,
    }


def stacked_bar(id_, title, sql, gridPos, colors, description=None):
    overrides = [{"matcher": {"id": "byName", "options": name},
                  "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": col}}]}
                 for name, col in colors]
    p = {
        "id": id_, "type": "barchart", "title": title, "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {"defaults": {
            "color": {"mode": "palette-classic"},
            "custom": {
                "axisBorderShow": False, "axisCenteredZero": False, "axisColorMode": "text",
                "axisLabel": "kWh", "axisPlacement": "auto", "fillOpacity": 85,
                "gradientMode": "none", "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                "lineWidth": 1, "scaleDistribution": {"type": "linear"},
                "thresholdsStyle": {"mode": "off"},
            },
            "mappings": [], "unit": "none", "decimals": 1, "min": 0,
            "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
        }, "overrides": overrides},
        "options": {
            "orientation": "auto", "xField": "月份", "showValue": "auto",
            "stacking": "normal", "barWidth": 0.9, "groupWidth": 0.7,
            "tooltip": {"mode": "multi", "sort": "desc", "hideZeros": False},
            "legend": {"calcs": ["sum"], "displayMode": "table",
                       "placement": "bottom", "showLegend": True},
        },
        "pluginVersion": "12.4.0", "gridPos": gridPos,
    }
    if description:
        p["description"] = description
    return p


def pie_panel(id_, title, sql, gridPos, colors, description=None):
    overrides = [{"matcher": {"id": "byName", "options": name},
                  "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": col}}]}
                 for name, col in colors]
    p = {
        "id": id_, "type": "piechart", "title": title, "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {"defaults": {
            "unit": "none", "decimals": 1,
            "color": {"mode": "palette-classic"},
            "custom": {"hideFrom": {"legend": False, "tooltip": False, "viz": False}},
            "mappings": [],
        }, "overrides": overrides},
        "options": {
            "reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
            "pieType": "donut",
            "tooltip": {"mode": "single", "sort": "desc"},
            "legend": {"displayMode": "table", "placement": "bottom",
                       "showLegend": True, "values": ["value", "percent"]},
            "displayLabels": [],
        },
        "pluginVersion": "12.4.0", "gridPos": gridPos,
    }
    if description:
        p["description"] = description
    return p


def table_panel(id_, title, sql, gridPos, description=None):
    p = {
        "id": id_, "type": "table", "title": title, "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": [
            {"matcher": {"id": "byName", "options": "停车电耗(kWh)"},
             "properties": [{"id": "custom.cellOptions",
                             "value": {"type": "color-background", "mode": "gradient"}},
                            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                                {"color": "yellow", "value": None}, {"color": "orange", "value": 1},
                                {"color": "red", "value": 3}]}}]},
            {"matcher": {"id": "byName", "options": "判断"},
             "properties": [{"id": "custom.cellOptions", "value": {"type": "color-text"}},
                            {"id": "mappings", "value": [
                                {"type": "value", "options": {"制热·可能有人在车": {"color": "orange", "index": 0}}},
                                {"type": "value", "options": {"制冷·过热或开AC": {"color": "blue", "index": 1}}},
                                {"type": "value", "options": {"空调基本没开·可能哨兵": {"color": "red", "index": 2}}}]}]},
        ]},
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [{"displayName": "停车电耗(kWh)", "desc": True}]},
        "gridPos": gridPos,
    }
    if description:
        p["description"] = description
    return p


NOTE = (
    "## ⚡ 行车 vs 停车能耗（月度）\n"
    f"每月用电分 **🚗 行车** / **🅿️ 停车**；停车再分 **☀️ 醒着掉电**（停 >{SLEEP_MIN} 分钟没休眠）/ "
    "**😴 休眠掉电**（车待机休眠时的正常耗电）。\n"
    "> 「醒着掉电」混了坐车里、空调、预热、偶尔哨兵，分不清。判断哨兵看下方明细表的 **「空调状态」**："
    "制热≈有人在车，制冷≈过热/A/C，空调关≈可能哨兵。"
)


def build_panels():
    P = []
    P.append(text_panel(1, NOTE, {"x": 0, "y": 0, "w": 24, "h": 4}))
    P.append(stat_panel(2, "🚗 行车电耗 (kWh)", sql_kpi_drive(), {"x": 0, "y": 4, "w": 6, "h": 4}, fixed_color="blue"))
    P.append(stat_panel(3, "🅿️ 停车电耗 (kWh)", sql_kpi_park(), {"x": 6, "y": 4, "w": 6, "h": 4}, fixed_color="orange"))
    P.append(stat_panel(4, "🅿️ 停车占总能耗 (%)", sql_kpi_park_pct(), {"x": 12, "y": 4, "w": 6, "h": 4}, fixed_color="orange"))
    P.append(stat_panel(5, "☀️ 醒着(未及时休眠)停车 (次)", sql_kpi_awake_count(), {"x": 18, "y": 4, "w": 6, "h": 4}, decimals=0, fixed_color="red"))
    P.append(pie_panel(6, "🥧 总能耗去向", sql_pie_overall(),
                       {"x": 0, "y": 8, "w": 8, "h": 9},
                       colors=[("🚗 行车", "blue"), ("🅿️ 停车", "orange")]))
    P.append(stacked_bar(7, "📊 月度能耗：行车 vs 停车 (kWh)", sql_monthly_drive_park(),
                         {"x": 8, "y": 8, "w": 16, "h": 9},
                         colors=[("行车电耗", "blue"), ("停车电耗", "orange")]))
    P.append(stacked_bar(8, "🅿️ 月度停车拆分：醒着掉电 vs 休眠掉电 (kWh)", sql_monthly_awake_split(),
                         {"x": 0, "y": 17, "w": 24, "h": 9},
                         colors=[("☀️ 醒着掉电", "red"), ("😴 休眠掉电", "blue")],
                         description="醒着掉电 = 停车 >15 分钟没休眠时掉的电（你坐车里/空调/预热/哨兵的混合）；休眠掉电 = 车正常休眠待机时的耗电。"))
    P.append(table_panel(9, "🔍 醒着停车明细（停 >15 分钟没休眠）",
                         sql_awake_table(), {"x": 0, "y": 26, "w": 24, "h": 10},
                         description="「空调约开(分钟)」= 估算空调实际开了多久（≠醒着时长）。判断：空调开得久且制热≈有人在车；制冷≈过热/AC；空调基本没开但车长时间醒着≈可能哨兵或车不休眠。"))
    return P


def main():
    car_id_variable = {
        "current": {}, "datasource": DS, "definition": "车辆选择器（来自 cars 表）",
        "includeAll": False, "label": "车辆", "name": "car_id", "options": [],
        "query": "SELECT\n    id as __value,\n    CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text \nFROM cars\nORDER BY display_priority ASC, name ASC, vin ASC;",
        "refresh": 1, "regex": "", "type": "query", "regexApplyTo": "value",
    }
    dashboard = {
        "title": "⚡ 行车 vs 停车能耗（月度）",
        "uid": "sentry-drain-cn",
        "tags": ["tesla", "battery", "efficiency"],
        "schemaVersion": 41, "version": 1, "timezone": "browser",
        "time": {"from": "now-1y", "to": "now"},
        "refresh": "", "editable": True, "graphTooltip": 0, "fiscalYearStartMonth": 0,
        "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
        "templating": {"list": [car_id_variable]},
        "panels": build_panels(),
        "links": STD_LINKS,
    }
    out = Path("grafana/dashboards/zh-cn/sentry-drain.json")
    out.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2))
    print(f"✓ 写入 {out} ({out.stat().st_size} bytes, {len(dashboard['panels'])} panels)")


if __name__ == "__main__":
    main()
