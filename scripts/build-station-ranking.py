#!/usr/bin/env python3
"""
生成 grafana/dashboards/zh-cn/station-ranking.json
🏆 充电桩性价比排行榜（分时电价感知）

布局（24 宽栅格）：
  Row 1 (h=4): KPI（总次数 / 总费用 / 最便宜桩 / 最贵桩 / 平均功率）
  Row 2 (h=14): 排行榜表格（按 ¥/度 升序，色阶绿黄红）
  Row 3 (h=10): 散点图 ¥/度 vs 平均功率 + 月度趋势对比
  Row 4 (h=10): 地图（按 ¥/度 着色 + 大小=次数）

跑：python3 scripts/build-station-ranking.py
"""
import json
from pathlib import Path

DS = {"type": "grafana-postgresql-datasource", "uid": "TeslaMate"}

# 充电桩 ¥/度 色阶阈值（绿黄橙红）：0.6 家充谷段 / 1.0 平段 / 1.5 超充
# 三处面板（柱图、地图、表格）共用，避免漂移
RATE_THRESHOLDS = {"mode": "absolute", "steps": [
    {"color": "green",  "value": None},
    {"color": "yellow", "value": 0.6},
    {"color": "orange", "value": 1.0},
    {"color": "red",    "value": 1.5},
]}


def text_panel(id_, title, content, gridPos):
    return {"id": id_, "type": "text", "title": title,
            "options": {"mode": "markdown", "content": content},
            "gridPos": gridPos}


def stat_panel(id_, title, sql, gridPos, unit="none", display_name=None,
               color_mode="value", thresholds=None, decimals=2):
    p = {
        "id": id_, "type": "stat", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "color": {"mode": "thresholds" if thresholds else "fixed",
                          "fixedColor": "blue"},
                "thresholds": thresholds or {"mode": "absolute",
                                              "steps": [{"color": "blue", "value": None}]},
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


def table_panel(id_, title, sql, gridPos, overrides=None):
    return {
        "id": id_, "type": "table", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {"custom": {"align": "auto"}},
            "overrides": overrides or []
        },
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
        "gridPos": gridPos
    }


def hbar_panel(id_, title, sql, gridPos):
    """横向 bar chart：x=充电点名称（categorical），y=¥/度，颜色按阈值"""
    return {
        "id": id_, "type": "barchart", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "custom": {"axisPlacement": "auto", "fillOpacity": 80, "lineWidth": 0},
                "color": {"mode": "thresholds"},
                "thresholds": RATE_THRESHOLDS,
                "unit": "none", "decimals": 3, "min": 0,
                "displayName": "${__field.name}"
            },
            "overrides": []
        },
        "options": {
            "orientation": "horizontal",
            "xField": "充电点",
            "showValue": "always", "stacking": "none",
            "tooltip": {"mode": "single"},
            "legend": {"displayMode": "hidden", "showLegend": False},
            "barWidth": 0.85, "groupWidth": 0.7
        },
        "gridPos": gridPos
    }


def geomap_panel(id_, title, sql, gridPos):
    return {
        "id": id_, "type": "geomap", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {"unit": "none", "decimals": 2,
                         "thresholds": RATE_THRESHOLDS},
            "overrides": []
        },
        "options": {
            "view": {"id": "coords", "lat": 35, "lon": 105, "zoom": 4},
            "controls": {"showZoom": True, "mouseWheelZoom": True, "showAttribution": True,
                         "showScale": False, "showMeasure": False, "showDebug": False},
            "basemap": {
                "type": "xyz", "name": "Layer 0",
                "config": {
                    "url": "${map_url}",
                    "attribution": "${map_url:text} contributors",
                    "minZoom": 3,
                    "maxZoom": 18
                }
            },
            "layers": [{
                "type": "markers",
                "name": "充电桩",
                "config": {
                    "style": {
                        "color": {"field": "¥/度", "fixed": "dark-green"},
                        "size": {"field": "充电次数", "min": 4, "max": 20, "fixed": 6},
                        "opacity": 0.8,
                        "symbol": {"fixed": "img/icons/marker/circle.svg", "mode": "fixed"}
                    },
                    "showLegend": True
                },
                "location": {"mode": "coords",
                             "latitude": "latitude", "longitude": "longitude"},
                "tooltip": True
            }]
        },
        "gridPos": gridPos
    }


# ============================================================
# 通用 SQL 片段：从 charging_processes 拿桩信息
# ============================================================
# 排除：
#   - 没 cost 的（free / 数据缺失）
#   - kwh 太少的（<= 1，可能是误触发）
# 用 effective_cost(cp.id, cp.cost) 让家充按分时电价 算

STATION_BASE_CTE = """
WITH stations AS (
  SELECT
    cp.id,
    COALESCE(g.name, a.display_name, '未知地点') AS station,
    cp.geofence_id,
    cp.address_id,
    p.latitude AS lat_raw,
    p.longitude AS lng_raw,
    cp.charge_energy_added,
    effective_cost(cp.id, cp.cost) AS cost,
    cp.cost AS cost_orig,
    cp.duration_min,
    cp.start_date,
    cp.end_date
  FROM charging_processes cp
  LEFT JOIN positions p ON p.id = cp.position_id
  LEFT JOIN geofences g ON g.id = cp.geofence_id
  LEFT JOIN addresses a ON a.id = cp.address_id
  WHERE cp.car_id = $car_id
    AND cp.charge_energy_added > 1
    AND effective_cost(cp.id, cp.cost) IS NOT NULL
    AND cp.duration_min >= 3
    AND $__timeFilter(cp.start_date)
)
"""

# ============================================================
# Panels
# ============================================================
panels = [
    text_panel(1, "", """
# 🏆 充电桩性价比榜

按 **¥/度（实际单价）** 排序所有充电点。家充自动按你配的分时电价计算（配了用分时，没开用原价）。

**怎么看：**
- **绿色 = 便宜（< ¥0.6/度，多半是家充谷段）**
- 黄色 = 中等（0.6-1.0）
- 橙色/红色 = 贵（超充和高峰电）
- 圆点大小 = 充电次数（越大去得越多）
""", {"x": 0, "y": 0, "w": 24, "h": 4}),

    # ─────── Row: KPI ───────
    stat_panel(2, "📊 总充电次数",
        f'{STATION_BASE_CTE} SELECT COUNT(*) AS "次" FROM stations',
        {"x": 0, "y": 4, "w": 4, "h": 5},
        unit="none", decimals=0),

    stat_panel(3, "💰 总充电费用",
        f'{STATION_BASE_CTE} SELECT ROUND(SUM(cost)::numeric, 2) AS "¥" FROM stations',
        {"x": 4, "y": 4, "w": 5, "h": 5},
        unit="none", decimals=2),

    table_panel(4, "🟢 最便宜 3 个桩",
        f"""{STATION_BASE_CTE}
SELECT
  station AS "充电点",
  ROUND((SUM(cost)/SUM(charge_energy_added))::numeric, 3) AS "¥/度 (分时)"
FROM stations GROUP BY station
HAVING COUNT(*) >= 2 AND SUM(charge_energy_added) > 0
ORDER BY SUM(cost)/SUM(charge_energy_added) ASC LIMIT 3""",
        {"x": 9, "y": 4, "w": 7, "h": 5}),

    table_panel(5, "🔴 最贵 3 个桩",
        f"""{STATION_BASE_CTE}
SELECT
  station AS "充电点",
  ROUND((SUM(cost)/SUM(charge_energy_added))::numeric, 3) AS "¥/度 (分时)"
FROM stations GROUP BY station
HAVING COUNT(*) >= 2 AND SUM(charge_energy_added) > 0
ORDER BY SUM(cost)/SUM(charge_energy_added) DESC LIMIT 3""",
        {"x": 16, "y": 4, "w": 8, "h": 5}),

    # ─────── Row: 排行榜表格 ───────
    table_panel(6, "🏆 充电桩排行榜（按 ¥/度 升序，分时 = 按你配的峰平谷算的真实价；原价 = TeslaMate 简单平均）",
        f"""{STATION_BASE_CTE}
SELECT
  ROW_NUMBER() OVER (ORDER BY SUM(cost)/NULLIF(SUM(charge_energy_added),0) ASC) AS "排名",
  station AS "充电点",
  COUNT(*) AS "次数",
  ROUND(SUM(cost)::numeric, 2) AS "累计费用 ¥",
  ROUND(SUM(charge_energy_added)::numeric, 1) AS "累计电量 kWh",
  ROUND((SUM(cost)/NULLIF(SUM(charge_energy_added),0))::numeric, 3) AS "¥/度 (分时)",
  ROUND((SUM(cost_orig)/NULLIF(SUM(charge_energy_added),0))::numeric, 3) AS "¥/度 (原价)",
  ROUND(AVG(duration_min)::numeric, 0) AS "平均时长 (分)",
  ROUND((AVG(charge_energy_added * 60.0 / NULLIF(duration_min, 0)))::numeric, 1) AS "平均功率 kW",
  ROUND((SUM(cost)/NULLIF(COUNT(*),0))::numeric, 2) AS "次均费用 ¥",
  TO_CHAR(MAX(start_date) AT TIME ZONE 'UTC' AT TIME ZONE '$__timezone', 'YYYY-MM-DD') AS "最近一次"
FROM stations
GROUP BY station
HAVING COUNT(*) >= 1
ORDER BY SUM(cost)/NULLIF(SUM(charge_energy_added),0) ASC
""",
        {"x": 0, "y": 9, "w": 24, "h": 14},
        overrides=[
            {"matcher": {"id": "byName", "options": "¥/度 (分时)"},
             "properties": [
                 {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "gradient"}},
                 {"id": "thresholds", "value": RATE_THRESHOLDS}
             ]},
            {"matcher": {"id": "byName", "options": "排名"},
             "properties": [{"id": "custom.width", "value": 60}]},
            {"matcher": {"id": "byName", "options": "充电点"},
             "properties": [{"id": "custom.width", "value": 250}]}
        ]),

    # ─────── Row: Top 10 ¥/度 排名条形图 ───────
    hbar_panel(7, "💎 ¥/度 Top 10 桩（绿=便宜，红=贵）",
        f"""{STATION_BASE_CTE}
SELECT
  station AS "充电点",
  ROUND((SUM(cost)/NULLIF(SUM(charge_energy_added),0))::numeric, 3) AS "¥/度"
FROM stations
GROUP BY station
HAVING COUNT(*) >= 2 AND SUM(charge_energy_added) > 0
ORDER BY SUM(cost)/SUM(charge_energy_added) ASC
LIMIT 10
""", gridPos={"x": 0, "y": 23, "w": 12, "h": 10}),

    # ─────── Row: 月度对比（涨价/降价提醒） ───────
    table_panel(8, "📈 最近 30 天 vs 之前的桩单价对比（红 = 涨价，绿 = 降价）",
        f"""{STATION_BASE_CTE},
recent AS (
  SELECT station,
    SUM(cost)/NULLIF(SUM(charge_energy_added),0) AS rate_recent,
    COUNT(*) AS n_recent
  FROM stations
  WHERE start_date > NOW() - INTERVAL '30 days'
  GROUP BY station
  HAVING COUNT(*) >= 1
),
older AS (
  SELECT station,
    SUM(cost)/NULLIF(SUM(charge_energy_added),0) AS rate_old,
    COUNT(*) AS n_old
  FROM stations
  WHERE start_date <= NOW() - INTERVAL '30 days'
  GROUP BY station
  HAVING COUNT(*) >= 1
)
SELECT
  COALESCE(r.station, o.station) AS "充电点",
  ROUND(o.rate_old::numeric, 3) AS "之前 ¥/度",
  ROUND(r.rate_recent::numeric, 3) AS "近 30 天 ¥/度",
  ROUND(((r.rate_recent - o.rate_old) / NULLIF(o.rate_old, 0) * 100)::numeric, 1) AS "变化 %",
  o.n_old AS "之前次数",
  r.n_recent AS "近 30 天次数"
FROM recent r FULL OUTER JOIN older o USING (station)
WHERE r.station IS NOT NULL AND o.station IS NOT NULL
  AND ABS(r.rate_recent - o.rate_old) / NULLIF(o.rate_old, 0) > 0.05
ORDER BY ((r.rate_recent - o.rate_old) / NULLIF(o.rate_old, 0)) DESC
""",
        {"x": 12, "y": 23, "w": 12, "h": 10},
        overrides=[
            {"matcher": {"id": "byName", "options": "变化 %"},
             "properties": [
                 {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}},
                 {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                     {"color": "green", "value": None},
                     {"color": "transparent", "value": -5},
                     {"color": "transparent", "value": 0},
                     {"color": "red", "value": 5}
                 ]}}
             ]}
        ]),

    # ─────── Row: 地图 ───────
    geomap_panel(9, "🗺️ 充电桩地图（颜色=¥/度，大小=去过的次数）",
        f"""{STATION_BASE_CTE}
SELECT
  station AS "充电点",
  AVG(lat_for_map(lat_raw, lng_raw)) AS "latitude",
  AVG(lng_for_map(lat_raw, lng_raw)) AS "longitude",
  ROUND((SUM(cost)/NULLIF(SUM(charge_energy_added),0))::numeric, 3) AS "¥/度",
  COUNT(*) AS "充电次数",
  ROUND(SUM(cost)::numeric, 2) AS "累计费用"
FROM stations
WHERE lat_raw IS NOT NULL AND lng_raw IS NOT NULL
GROUP BY station
HAVING COUNT(*) >= 1
""".replace("lat_for_map(lat_raw, lng_raw)",
            "lat_for_map('${map_url}', lat_raw, lng_raw)").replace(
            "lng_for_map(lat_raw, lng_raw)",
            "lng_for_map('${map_url}', lat_raw, lng_raw)"),
        {"x": 0, "y": 33, "w": 24, "h": 22}),
]

car_id_variable = {
    "current": {},
    "datasource": DS,
    "definition": "SELECT id as __value, CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text FROM cars ORDER BY display_priority ASC, name ASC, vin ASC;",
    "includeAll": False, "label": "车辆", "name": "car_id", "options": [],
    "query": "SELECT id as __value, CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text FROM cars ORDER BY display_priority ASC, name ASC, vin ASC;",
    "refresh": 1, "regex": "", "type": "query", "regexApplyTo": "value"
}

# 地图源切换变量（与其他地图仪表盘一致 — 必须用完整 URL 不是短码）
_OSM = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
_AMAP = "https://wprd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x={x}&y={y}&z={z}"
_AMAP_SAT = "https://webst01.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}"
_GOOGLE = "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}"
_GOOGLE_SAT = "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}"
_CARTO = "https://cartodb-basemaps-c.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png"
map_url_variable = {
    "current": {"selected": False, "text": "OpenStreetMap", "value": _OSM},
    "description": "🌏 地图源切换 — 6 种瓦片一键切换。中国大陆推荐：高德地图。",
    "hide": 0, "includeAll": False, "multi": False,
    "label": "地图源", "name": "map_url",
    "options": [
        {"selected": True, "text": "OpenStreetMap", "value": _OSM},
        {"selected": False, "text": "高德地图", "value": _AMAP},
        {"selected": False, "text": "高德卫星", "value": _AMAP_SAT},
        {"selected": False, "text": "谷歌地图", "value": _GOOGLE},
        {"selected": False, "text": "谷歌卫星", "value": _GOOGLE_SAT},
        {"selected": False, "text": "Carto 浅色", "value": _CARTO}
    ],
    "query": f"OpenStreetMap : {_OSM},高德地图 : {_AMAP},高德卫星 : {_AMAP_SAT},谷歌地图 : {_GOOGLE},谷歌卫星 : {_GOOGLE_SAT},Carto 浅色 : {_CARTO}",
    "queryValue": "", "skipUrlSync": False, "type": "custom"
}

dashboard = {
    "title": "🏆 充电桩性价比榜",
    "uid": "station-ranking",
    "tags": ["tesla", "tou", "charging", "ranking"],
    "schemaVersion": 41, "version": 1, "timezone": "browser",
    "time": {"from": "now-1y", "to": "now"},
    "refresh": "", "editable": True, "graphTooltip": 0, "fiscalYearStartMonth": 0,
    "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
    "templating": {"list": [car_id_variable, map_url_variable]},
    "panels": panels,
    "links": [
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
}

def main():
    out = Path("grafana/dashboards/zh-cn/station-ranking.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n")
    print(f"✓ 写入 {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
