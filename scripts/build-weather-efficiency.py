#!/usr/bin/env python3
"""
生成 grafana/dashboards/zh-cn/weather-efficiency.json
🌡️ 天气-能耗关联（中文版独有）

布局（24 宽栅格）：
  Row 1 (h=4):  标题 + 说明
  Row 2 (h=5):  4 KPI（平均温度 / 平均能耗 / 最冷月能耗 / 最热月能耗）
  Row 3 (h=10): 温度桶能耗曲线（每 2°C 一档，柱色按温度梯度）
  Row 4 (h=10): 月度温度对比能耗（双轴：蓝线温度 + 黄柱能耗）
  Row 5 (h=8):  温度区间能耗对比柱图
  Row 6 (h=8):  季节能耗对比表

跑：python3 scripts/build-weather-efficiency.py
"""
import json
from pathlib import Path

DS = {"type": "grafana-postgresql-datasource", "uid": "TeslaMate"}

# ─── Magic numbers as named constants ────────────────────────────────
# 异常值过滤：能耗范围（Wh/km）。两套范围分别用于不同 panel：
#   _LOOSE：温度区间柱图、季节对比 — 保留爬山/堵车的极端样本，让平均值反映真实驾驶
#   _TIGHT：温度桶曲线 — 收紧后趋势更清晰，去掉离群值
WH_PER_KM_LOOSE_MIN, WH_PER_KM_LOOSE_MAX = 50, 500
WH_PER_KM_TIGHT_MIN, WH_PER_KM_TIGHT_MAX = 80, 350

# KPI 阈值（参考 Model 3 LR EPA 标定，其他车型可能需要调整）
WH_PER_KM_GOOD = 180   # 低于此值 = 高效
WH_PER_KM_WARN = 220   # 偏高警示
WH_PER_KM_CRIT = 280   # 严重偏高

# 数据过滤：
MIN_DRIVE_DISTANCE_KM = 1     # 极短行程不计入（停车场掉头之类）
MIN_SAMPLES_PER_BUCKET = 3    # 温度桶最少样本数，避免单次行驶噪声主导

# 温度桶柱图配色阈值（colorByField=温度，单位 °C）
TEMP_COLOR_STEPS = [
    {"color": "blue",        "value": None},  # < 10°C 严寒
    {"color": "light-blue",  "value": 10},    # 10-20°C 凉爽
    {"color": "green",       "value": 20},    # 20-30°C 温暖（甜区）
    {"color": "orange",      "value": 30},    # 30-35°C 偏热
    {"color": "red",         "value": 35},    # ≥ 35°C 酷热
]

STD_LINKS = [
    {"asDropdown": True, "icon": "external link", "tags": ["tesla"],
     "title": "车辆信息", "type": "dashboards"},
    {"asDropdown": True, "icon": "external link", "includeVars": False, "keepTime": False,
     "tags": ["battery"], "targetBlank": False, "title": "电池", "tooltip": "",
     "type": "dashboards", "url": ""},
    {"asDropdown": True, "icon": "external link", "includeVars": False, "keepTime": False,
     "tags": ["trip"], "targetBlank": False, "title": "行驶", "tooltip": "",
     "type": "dashboards", "url": ""},
    {"asDropdown": False, "icon": "doc", "includeVars": False, "keepTime": False,
     "tags": [], "targetBlank": True, "title": "中文文档", "tooltip": "",
     "type": "link", "url": "https://github.com/wjsall/teslamate-chinese-dashboards"}
]


def text_panel(id_, title, content, gridPos):
    return {"id": id_, "type": "text", "title": title,
            "options": {"mode": "markdown", "content": content},
            "gridPos": gridPos}


def stat_panel(id_, title, sql, gridPos, unit="none", decimals=0,
               color_mode="value", thresholds=None, display_name=None,
               fixed_color="blue"):
    """单值 stat panel。
    thresholds=None → 用 mode=fixed + fixed_color；
    thresholds 给值 → 用 mode=thresholds，fixed_color 被忽略（不 emit）。
    """
    if thresholds:
        color = {"mode": "thresholds"}
    else:
        color = {"mode": "fixed", "fixedColor": fixed_color}
        thresholds = {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}
    p = {
        "id": id_, "type": "stat", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "color": color,
                "thresholds": thresholds,
            },
            "overrides": []
        },
        "options": {
            "reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""},
            "orientation": "auto", "textMode": "auto", "colorMode": color_mode,
            "graphMode": "none", "justifyMode": "auto",
        },
        "gridPos": gridPos
    }
    if display_name:
        p["fieldConfig"]["defaults"]["displayName"] = display_name
    return p


def scatter_panel(id_, title, sql, gridPos,
                  x_field="温度 (°C)", y_field="能耗 (Wh/km)"):
    """xychart 散点图：x_field / y_field 必须跟 SQL 输出列名匹配。"""
    return {
        "id": id_, "type": "xychart", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "axisBorderShow": False, "axisCenteredZero": False,
                    "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto",
                    "fillOpacity": 70,
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                    "pointShape": "circle",
                    "pointSize": {"fixed": 5},
                    "pointStrokeWidth": 1,
                    "scaleDistribution": {"type": "linear"},
                    "show": "points"
                },
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "green", "value": 0}, {"color": "red", "value": 80}
                ]}
            },
            "overrides": []
        },
        "options": {
            "mapping": "manual",
            "series": [{
                "frame": {"matcher": {"id": "byIndex", "options": 0}},
                "x": {"matcher": {"id": "byName", "options": x_field}},
                "y": {"matcher": {"id": "byName", "options": y_field}}
            }],
            "tooltip": {"hideZeros": False, "mode": "single", "sort": "none"},
            "legend": {"calcs": [], "displayMode": "list",
                       "placement": "bottom", "showLegend": False}
        },
        "pluginVersion": "12.4.0",
        "gridPos": gridPos
    }


def timeseries_panel(id_, title, sql, gridPos, overrides=None):
    """通用 timeseries panel；dual y-axis 由 caller 通过 overrides 配置。

    Wide-table format（time + N value columns）→ 用 format='table'，timeseries
    panel 自动找 time 列；matcher 走 byName。
    """
    return {
        "id": id_, "type": "timeseries", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "custom": {
                    "drawStyle": "line",
                    "lineWidth": 2,
                    "fillOpacity": 0,
                    "pointSize": 5,
                    "showPoints": "auto",
                    "axisPlacement": "auto",
                },
                "color": {"mode": "palette-classic"},
                "unit": "none"
            },
            "overrides": overrides or []
        },
        "options": {
            "tooltip": {"mode": "multi"},
            "legend": {"showLegend": True, "displayMode": "list", "placement": "bottom"}
        },
        "gridPos": gridPos
    }


def bar_panel(id_, title, sql, gridPos, x_field="区间",
              color_by_x_field=False, thresholds_steps=None,
              value_size=None, description=None):
    """barchart。
    color_by_x_field=True：colorByField=x_field（按 X 上色）；
      thresholds_steps：对应 X 字段的颜色断点（数值在 X 单位下解释）。
    color_by_x_field=False：默认按 Y 值上色，thresholds_steps 在 Y 单位下解释。
    value_size：柱顶数字字号（None=Grafana 默认）。
    """
    if thresholds_steps is None:
        thresholds_steps = [
            {"color": "green",  "value": None},
            {"color": "yellow", "value": WH_PER_KM_GOOD},
            {"color": "orange", "value": WH_PER_KM_WARN},
            {"color": "red",    "value": WH_PER_KM_CRIT},
        ]
    options = {
        "orientation": "auto",
        "xField": x_field,
        "showValue": "always" if value_size else "auto",
        "stacking": "none",
        "tooltip": {"hideZeros": False, "mode": "single", "sort": "none"},
        "legend": {"calcs": [], "displayMode": "list",
                   "placement": "bottom", "showLegend": False},
        "barWidth": 0.85, "groupWidth": 0.7,
    }
    if color_by_x_field:
        options["colorByField"] = x_field
    if value_size:
        options["text"] = {"valueSize": value_size, "titleSize": 14}
    p = {
        "id": id_, "type": "barchart", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "custom": {
                    "axisBorderShow": False, "axisCenteredZero": False,
                    "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto",
                    "fillOpacity": 80, "gradientMode": "none",
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                    "lineWidth": 1,
                    "scaleDistribution": {"type": "linear"},
                    "thresholdsStyle": {"mode": "off"}
                },
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": thresholds_steps},
                "unit": "none",
                "decimals": 0,
                "min": 0,
            },
            "overrides": []
        },
        "options": options,
        "pluginVersion": "12.4.0",
        "gridPos": gridPos
    }
    if description:
        p["description"] = description
    # 当 colorByField 是温度列时，给该列加 °C 单位（X 轴标签更清晰）
    if color_by_x_field and "°C" in x_field:
        p["fieldConfig"]["overrides"].append({
            "matcher": {"id": "byName", "options": x_field},
            "properties": [{"id": "unit", "value": "celsius"}]
        })
    return p


def table_panel(id_, title, sql, gridPos, overrides=None):
    return {
        "id": id_, "type": "table", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {"custom": {"align": "auto"}},
            "overrides": overrides or []
        },
        "options": {"showHeader": True, "cellHeight": "sm"},
        "gridPos": gridPos
    }


# ============================================================
# 通用 SQL 片段
# 公式：(start_ideal_range_km - end_ideal_range_km) * efficiency * 1000 / distance
# 参考 efficiency.json "温度 – 能效" 面板（公式来源同一份），
# 本文件保留简化版（无 $length_unit / 坡度修正）。若上游 efficiency 改公式，本文件也要同步。
# ============================================================
DRIVES_BASE_CTE = f"""
WITH d AS (
  SELECT
    drives.start_date,
    drives.outside_temp_avg AS temp,
    drives.distance,
    drives.duration_min,
    ((drives.start_ideal_range_km - drives.end_ideal_range_km)
       * c.efficiency * 1000.0 / NULLIF(drives.distance, 0)) AS wh_per_km
  FROM drives
  JOIN cars c ON c.id = drives.car_id
  WHERE drives.car_id = $car_id
    AND drives.distance > {MIN_DRIVE_DISTANCE_KM}
    AND drives.outside_temp_avg IS NOT NULL
    AND drives.start_ideal_range_km IS NOT NULL
    AND drives.end_ideal_range_km IS NOT NULL
    AND drives.end_date IS NOT NULL
    AND $__timeFilter(drives.start_date)
)
"""

# panel 4/5 共用：按月聚合（与 ORDER BY 方向区分冷月/热月）
MONTHLY_CTE = """,
m AS (
  SELECT date_trunc('month', start_date AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone') AS mo,
    AVG(temp) AS avg_temp, AVG(wh_per_km) AS avg_wh
  FROM d GROUP BY 1
)
"""


# ============================================================
# Panels
# ============================================================
def build_panels():
    return [
        text_panel(1, "", """
# 🌡️ 天气-能耗关联

国内特斯拉车主 #1 痛点：「冬天到底掉多少电」。这个仪表盘用 TeslaMate 已记录的每次行驶外部温度 + 续航损耗，**量化温度对能耗的真实影响**。

**怎么看**：
- **温度桶曲线** — 每 2°C 一档，柱高=该桶中位能耗，柱色按温度冷蓝→热红
- **月度双轴** — 蓝线月均温度 与 黄柱月均能耗，反相关一目了然
- **温度区间柱图** — 5 个温度档位的平均 Wh/km，估算续航差距
- **季节对比** — 量化「冬季比夏季多耗 X%」
""", {"x": 0, "y": 0, "w": 24, "h": 4}),

        # ─────── Row: KPI ───────
        stat_panel(2, "🌡 平均温度",
            f'{DRIVES_BASE_CTE} SELECT ROUND(AVG(temp)::numeric, 1) AS "°C" FROM d',
            {"x": 0, "y": 4, "w": 6, "h": 5}, decimals=1, unit="celsius"),

        stat_panel(3, "⚡ 平均能耗",
            f'{DRIVES_BASE_CTE} SELECT ROUND(AVG(wh_per_km)::numeric, 0) AS "Wh/km" FROM d',
            {"x": 6, "y": 4, "w": 6, "h": 5}, decimals=0, unit="none"),

        stat_panel(4, "❄ 最冷月平均能耗",
            f'''{DRIVES_BASE_CTE}{MONTHLY_CTE}
SELECT ROUND(avg_wh::numeric, 0) AS "Wh/km" FROM m ORDER BY avg_temp ASC LIMIT 1''',
            {"x": 12, "y": 4, "w": 6, "h": 5}, decimals=0, unit="none",
            # 最冷月 = 通常最耗能 → 配色"高 = 红"，跟 panel 5 同方向
            thresholds={"mode": "absolute", "steps": [
                {"color": "yellow", "value": None},
                {"color": "orange", "value": WH_PER_KM_WARN},
                {"color": "red",    "value": WH_PER_KM_CRIT},
            ]}),

        stat_panel(5, "☀ 最热月平均能耗",
            f'''{DRIVES_BASE_CTE}{MONTHLY_CTE}
SELECT ROUND(avg_wh::numeric, 0) AS "Wh/km" FROM m ORDER BY avg_temp DESC LIMIT 1''',
            {"x": 18, "y": 4, "w": 6, "h": 5}, decimals=0, unit="none",
            thresholds={"mode": "absolute", "steps": [
                {"color": "green",  "value": None},
                {"color": "yellow", "value": WH_PER_KM_GOOD},
            ]}),

        # ─────── Row: 温度桶能耗曲线 ───────
        bar_panel(6, "📊 温度桶能耗曲线（每 2°C 一档，柱色：冷蓝→热红）",
            f'''{DRIVES_BASE_CTE}
SELECT
  (FLOOR(temp / 2.0) * 2)::int AS "温度 (°C)",
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY wh_per_km)::numeric, 0) AS "中位 (Wh/km)"
FROM d
WHERE wh_per_km BETWEEN {WH_PER_KM_TIGHT_MIN} AND {WH_PER_KM_TIGHT_MAX}
GROUP BY 1
HAVING COUNT(*) >= {MIN_SAMPLES_PER_BUCKET}
ORDER BY 1''',
            {"x": 0, "y": 9, "w": 24, "h": 10},
            x_field="温度 (°C)",
            color_by_x_field=True,
            thresholds_steps=TEMP_COLOR_STEPS,
            value_size=22,
            description=f"每 2°C 分一桶，画该桶里所有行驶的中位能耗。比散点更能看出趋势，柱顶数字仅在样本数 ≥{MIN_SAMPLES_PER_BUCKET} 时显示。"),

        # ─────── Row: 月度双轴 ───────
        timeseries_panel(7, "📈 月度温度对比能耗（蓝线=温度，黄柱=能耗）",
            f'''{DRIVES_BASE_CTE}
SELECT
  date_trunc('month', start_date AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone') AS time,
  ROUND(AVG(temp)::numeric, 1) AS "月均温度 (°C)",
  ROUND(AVG(wh_per_km)::numeric, 0) AS "月均能耗 (Wh/km)"
FROM d
GROUP BY 1
ORDER BY 1''',
            {"x": 0, "y": 19, "w": 24, "h": 10},
            overrides=[
                {"matcher": {"id": "byName", "options": "月均温度 (°C)"},
                 "properties": [
                     {"id": "color", "value": {"mode": "fixed", "fixedColor": "blue"}},
                     {"id": "unit", "value": "celsius"}
                 ]},
                {"matcher": {"id": "byName", "options": "月均能耗 (Wh/km)"},
                 "properties": [
                     {"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}},
                     {"id": "custom.drawStyle", "value": "bars"},
                     {"id": "custom.fillOpacity", "value": 70},
                     {"id": "custom.axisPlacement", "value": "right"},
                     {"id": "unit", "value": "none"}
                 ]}
            ]),

        # ─────── Row: 温度区间分桶柱图 ───────
        bar_panel(8, "🌡 温度区间能耗对比（每桶平均 Wh/km）",
            f'''{DRIVES_BASE_CTE}
SELECT
  bucket AS "区间",
  ROUND(AVG(wh_per_km)::numeric, 0) AS "平均能耗 (Wh/km)"
FROM (
  SELECT wh_per_km,
    CASE
      WHEN temp <= 0 THEN '❄ ≤ 0°C 严寒'
      WHEN temp <= 10 THEN '🥶 0-10°C 寒冷'
      WHEN temp <= 20 THEN '😊 10-20°C 凉爽'
      WHEN temp <= 30 THEN '☀ 20-30°C 温暖'
      ELSE '🔥 > 30°C 酷热'
    END AS bucket,
    CASE
      WHEN temp <= 0 THEN 1
      WHEN temp <= 10 THEN 2
      WHEN temp <= 20 THEN 3
      WHEN temp <= 30 THEN 4
      ELSE 5
    END AS sort_order
  FROM d
  WHERE wh_per_km BETWEEN {WH_PER_KM_LOOSE_MIN} AND {WH_PER_KM_LOOSE_MAX}
) sub
GROUP BY bucket, sort_order
ORDER BY sort_order''',
            {"x": 0, "y": 29, "w": 12, "h": 8}, x_field="区间"),

        # ─────── Row: 季节对比 ───────
        # EXTRACT(MONTH ...) 算一次（month_local），后面 CASE 复用 — 大表上比重复 8 次省几百 ms
        table_panel(9, "🍂 季节能耗对比（北半球，按月份分）",
            f'''{DRIVES_BASE_CTE},
filtered AS (
  SELECT temp, wh_per_km, distance,
    EXTRACT(MONTH FROM start_date AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone')::int AS month_local
  FROM d
  WHERE wh_per_km BETWEEN {WH_PER_KM_LOOSE_MIN} AND {WH_PER_KM_LOOSE_MAX}
),
seasonal AS (
  SELECT
    CASE
      WHEN month_local IN (12,1,2) THEN '🥶 冬 (12-2月)'
      WHEN month_local IN (3,4,5)  THEN '🌸 春 (3-5月)'
      WHEN month_local IN (6,7,8)  THEN '☀ 夏 (6-8月)'
      ELSE '🍂 秋 (9-11月)'
    END AS season,
    CASE
      WHEN month_local IN (12,1,2) THEN 1
      WHEN month_local IN (3,4,5)  THEN 2
      WHEN month_local IN (6,7,8)  THEN 3
      ELSE 4
    END AS sort_order,
    temp, wh_per_km, distance
  FROM filtered
),
overall AS (SELECT AVG(wh_per_km) AS avg_filtered FROM seasonal)
SELECT
  season AS "季节",
  COUNT(*) AS "行程数",
  ROUND(SUM(distance)::numeric, 0) AS "总里程 (km)",
  ROUND(AVG(temp)::numeric, 1) AS "平均温度 (°C)",
  ROUND(AVG(wh_per_km)::numeric, 0) AS "平均能耗 (Wh/km)",
  ROUND(((AVG(wh_per_km) - (SELECT avg_filtered FROM overall)) / (SELECT avg_filtered FROM overall) * 100)::numeric, 1) AS "相对均值 %"
FROM seasonal
GROUP BY season, sort_order
ORDER BY sort_order''',
            {"x": 12, "y": 29, "w": 12, "h": 8},
            overrides=[
                {"matcher": {"id": "byName", "options": "相对均值 %"},
                 "properties": [
                     {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
                     # [-3, 3] 区间不染色（接近全年均值不告警）
                     {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                         {"color": "green",       "value": None},
                         {"color": "transparent", "value": -3},
                         {"color": "transparent", "value": 0},
                         {"color": "orange",      "value": 3},
                         {"color": "red",         "value": 10},
                     ]}}
                 ]}
            ]),
    ]


def main():
    car_id_variable = {
        "current": {},
        "datasource": DS,
        "definition": "车辆选择器（来自 cars 表）",
        "includeAll": False,
        "label": "车辆",
        "name": "car_id",
        "options": [],
        "query": "SELECT\n    id as __value,\n    CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text \nFROM cars\nORDER BY display_priority ASC, name ASC, vin ASC;",
        "refresh": 1, "regex": "", "type": "query", "regexApplyTo": "value",
    }

    panels = build_panels()

    # Self-check：每个非 text panel 的 rawSql 都应包含 DRIVES_BASE_CTE 第一行（防止漏粘贴）
    cte_marker = "WITH d AS ("
    for p in panels:
        if p.get("type") == "text":
            continue
        sqls = [t.get("rawSql", "") for t in p.get("targets", [])]
        if not any(cte_marker in s for s in sqls):
            raise SystemExit(
                f"[build self-check] panel id={p['id']} title='{p.get('title')}' "
                f"missing {cte_marker!r} — likely a copy/paste regression"
            )

    dashboard = {
        "title": "🌡️ 天气-能耗关联",
        "uid": "weather-efficiency",
        "tags": ["tesla", "trip", "efficiency", "weather"],
        "schemaVersion": 41, "version": 1, "timezone": "browser",
        "time": {"from": "now-1y", "to": "now"},
        "refresh": "", "editable": True, "graphTooltip": 0, "fiscalYearStartMonth": 0,
        "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
        "templating": {"list": [car_id_variable]},
        "panels": panels,
        "links": STD_LINKS
    }

    out = Path("grafana/dashboards/zh-cn/weather-efficiency.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2))
    print(f"✓ 写入 {out} ({out.stat().st_size} bytes, {len(panels)} panels)")


if __name__ == "__main__":
    main()
