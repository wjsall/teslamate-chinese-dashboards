#!/usr/bin/env python3
"""
生成 grafana/dashboards/zh-cn/tou-config.json 仪表盘
（Volkov Labs Form Panel v6.x 配 Postgres 数据源做 CRUD）

布局（24 宽栅格）：
  Row 1: 标题 + 说明（text panel）
  Row 2: ⏰ 24 小时电价分布（state-timeline，按所选充电点配色显示当前生效时段）
  Row 3: 📋 当前电价配置（table，read-only） + ➕ 添加一个时段（form panel）
  Row 4: 🌆 一键导入城市模板 + ✏️ 修改单价 + 🗑️ 删除整段
  Row 5: 💰 最近 10 笔家充 分时电价对账（table）

跑：python3 scripts/build-tou-dashboard.py
"""
import json
from pathlib import Path

DS = {"type": "grafana-postgresql-datasource", "uid": "TeslaMate"}

# ============================================================
# 共享常量
# ============================================================
# tou_rates 列表选择器的 SQL（修改单价 / 删除整段两个面板复用）
RATE_LIST_INITIAL_SQL = """
SELECT
  r.id,
  COALESCE(g.name, '全局') || ' ' || r.hour_start || '-' || r.hour_end || ' ' || r.label || ' ¥' || r.rate AS display_name
FROM tou_rates r
LEFT JOIN geofences g ON g.id = r.geofence_id
ORDER BY r.geofence_id NULLS FIRST, r.id
"""

# Volkov form 季节字段公共构造
_MONTH_OPTIONS = [{"id": "", "value": "", "label": "全年生效（无季节差异）"}] \
    + [{"id": str(m), "value": str(m), "label": f"{m} 月起"} for m in range(1, 13)]
_MONTH_END_OPTIONS = [{"id": str(m), "value": str(m), "label": f"{m} 月止"} for m in range(1, 13)]
_DAY_OPTIONS = [{"id": str(d), "value": str(d), "label": f"{d} 日"} for d in range(1, 32)]
_SHOW_IF_FROM_MONTH_SET = "return context.panel.elements.find(e => e.id === 'from_month')?.value !== '';"

def season_range_elements(month_tooltip=""):
    """返回 4 个 select 元素（季节起月/起日/止月/止日），用 from_month/from_day/to_month/to_day 标准 id"""
    return [
        {"id": "from_month", "type": "select", "title": "季节范围",
         "value": "", "optionsSource": "Custom", "options": _MONTH_OPTIONS,
         **({"tooltip": month_tooltip} if month_tooltip else {})},
        {"id": "from_day", "type": "select", "title": "起始日（1-31）",
         "value": "1", "optionsSource": "Custom", "options": _DAY_OPTIONS,
         "showIf": _SHOW_IF_FROM_MONTH_SET},
        {"id": "to_month", "type": "select", "title": "结束月",
         "value": "", "optionsSource": "Custom", "options": _MONTH_END_OPTIONS,
         "showIf": _SHOW_IF_FROM_MONTH_SET},
        {"id": "to_day", "type": "select", "title": "结束日（1-31）",
         "value": "31", "optionsSource": "Custom", "options": _DAY_OPTIONS,
         "showIf": _SHOW_IF_FROM_MONTH_SET},
    ]


def text_panel(id_, title, content, gridPos):
    return {
        "id": id_, "type": "text", "title": title,
        "options": {"mode": "markdown", "content": content},
        "gridPos": gridPos
    }


def table_panel(id_, title, sql, gridPos, transformations=None):
    p = {
        "id": id_, "type": "table", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}}, "overrides": []},
        "options": {"showHeader": True, "cellHeight": "sm"},
        "gridPos": gridPos
    }
    if transformations:
        p["transformations"] = transformations
    return p


def hour_bar_panel(id_, title, sql, gridPos):
    """24 小时电价柱图：x 轴 0-23 时（categorical 不依赖 dashboard time range），柱高=单价，颜色按阈值"""
    return {
        "id": id_, "type": "barchart", "title": title,
        "datasource": DS,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": sql, "format": "table"}],
        "fieldConfig": {
            "defaults": {
                "custom": {
                    "axisPlacement": "auto",
                    "axisLabel": "",
                    "axisColorMode": "text",
                    "fillOpacity": 80,
                    "gradientMode": "none",
                    "lineWidth": 0,
                    "axisBorderShow": False,
                },
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "yellow", "value": 0.40},
                        {"color": "orange", "value": 0.70},
                        {"color": "red", "value": 1.00},
                    ],
                },
                "unit": "none",
                "decimals": 2,
                "min": 0,
                "displayName": "${__field.name} ¥/度",
            },
            "overrides": [
                {"matcher": {"id": "byName", "options": "标签"},
                 "properties": [{"id": "custom.hideFrom", "value": {"viz": True, "tooltip": False, "legend": False}}]},
            ],
        },
        "options": {
            "orientation": "auto",
            "xField": "时点",
            "showValue": "always",
            "stacking": "none",
            "tooltip": {"mode": "single", "sort": "none"},
            "legend": {"displayMode": "hidden", "placement": "bottom", "showLegend": False},
            "barWidth": 0.9,
            "groupWidth": 0.7,
            "barRadius": 0,
        },
        "gridPos": gridPos
    }


def form_panel(id_, title, elements, update_sql, initial_sql, gridPos,
               success_msg="✅ 已保存", submit_text="保存", submit_icon="save",
               element_value_changed=""):
    """Volkov Labs Form Panel v6.x"""
    targets_sql = initial_sql or "SELECT 1"
    update_payload = {
        "refId": "A",
        "datasource": DS,
        "format": "table",
        "rawSql": update_sql,
    }
    initial_block = {"method": "-", "code": "", "highlight": False, "payloadMode": "all"}

    return {
        "id": id_,
        "type": "volkovlabs-form-panel",
        "title": title,
        "datasource": DS,
        "gridPos": gridPos,
        "targets": [{"refId": "A", "datasource": DS, "rawSql": targets_sql, "format": "table"}],
        "options": {
            "layout": {"orientation": "horizontal", "padding": 10, "variant": "single", "sectionVariant": "default"},
            "buttonGroup": {"orientation": "center", "size": "md"},
            "updateEnabled": "auto",
            "submit": {"text": submit_text, "icon": submit_icon, "variant": "primary", "foregroundColor": "white", "backgroundColor": "#1f60c4"},
            "reset": {"text": "重置", "icon": "process", "variant": "secondary", "foregroundColor": "white", "backgroundColor": "#3274d9"},
            "saveDefault": {"variant": "hidden"},
            "elements": elements,
            "initial": initial_block,
            "update": {
                "method": "datasource",
                "datasource": DS["uid"],
                "payload": update_payload,
                "payloadMode": "all",
                "code": "",
                "confirm": False,
                "highlight": False,
                "highlightColor": "red",
            },
            "resetAction": {"mode": "initial", "code": ""},
            "elementValueChanged": element_value_changed,
            "sync": True,
            "sections": [],
            "confirmModal": {
                "title": "确认", "body": "保存该项？",
                "columns": {"name": "字段", "oldValue": "原值", "newValue": "新值", "include": ["title", "value", "newValue"]},
                "elements": []
            },
            "feedback": {
                "success": {"type": "success", "title": "成功", "body": success_msg},
                "error": {"type": "error", "title": "失败", "body": "出错了，请检查输入"}
            }
        }
    }

# ============================================================
# 元素定义
# ============================================================

geofence_select = {
    "id": "geofence_id",
    "type": "select",
    "title": "充电点",
    "value": None,
    "optionsSource": "Query",
    "queryOptions": {
        "source": "A",
        "value": "id",
        "label": "name"
    },
    "showIf": "",
    "section": ""
}

# ⚡ 一键填一整个季节（5 档模式）
# 默认只露 谷 + 峰 + 平 三档（90% 用户）；勾「高级」展开 尖 + 深谷
# 谷/峰各支持 3 段（覆盖 江苏 3 段尖峰），尖/深谷 1 段（极少多段）
# 每段单独字段避免 Volkov 含逗号字符串替换 bug
_advanced_show = "return context.panel.elements.find(e => e.id === 'advanced')?.value === 'yes';"

simple_form_elements = [
    geofence_select,
    # 谷时段：3 段
    {"id": "valley_range_1", "type": "string",
     "title": "谷时段 1（如 22-7 跨夜，或 0-7）",
     "value": "22-7",
     "tooltip": "支持跨夜（如 22-7 = 22 点到次日 7 点）"},
    {"id": "valley_range_2", "type": "string",
     "title": "谷时段 2（可选，用不到留空）",
     "value": ""},
    {"id": "valley_range_3", "type": "string",
     "title": "谷时段 3（可选）",
     "value": ""},
    {"id": "valley_rate", "type": "number", "title": "谷价 ¥/度",
     "value": 0.24, "min": 0, "step": 0.01},
    # 峰时段：3 段
    {"id": "peak_range_1", "type": "string",
     "title": "峰时段 1（如 11-18；两档电网无峰留空）",
     "value": "11-18"},
    {"id": "peak_range_2", "type": "string",
     "title": "峰时段 2（可选，如 20-22）",
     "value": ""},
    {"id": "peak_range_3", "type": "string",
     "title": "峰时段 3（可选，江苏式 3 段尖峰）",
     "value": ""},
    {"id": "peak_rate", "type": "number", "title": "峰价 ¥/度（无峰填 0）",
     "value": 0.86, "min": 0, "step": 0.01},
    # 平价（自动）
    {"id": "mid_rate", "type": "number", "title": "平价 ¥/度（自动占剩余时段）",
     "value": 0.55, "min": 0, "step": 0.01},
    # 高级 toggle
    {"id": "advanced", "type": "radio", "title": "高级（启用尖/深谷档？）",
     "value": "no",
     "optionsSource": "Custom",
     "options": [
         {"id": "no",  "value": "no",  "label": "否（标准 3 档：谷/峰/平）"},
         {"id": "yes", "value": "yes", "label": "是（5 档：+ 尖 + 深谷）"},
     ]},
    # 尖时段（高级，1-2 段）
    {"id": "sharp_range_1", "type": "string",
     "title": "尖时段 1（如夏季 13-15）", "value": "",
     "showIf": _advanced_show},
    {"id": "sharp_range_2", "type": "string",
     "title": "尖时段 2（可选）", "value": "",
     "showIf": _advanced_show},
    {"id": "sharp_rate", "type": "number",
     "title": "尖价 ¥/度（无尖填 0）", "value": 0, "min": 0, "step": 0.01,
     "showIf": _advanced_show},
    # 深谷时段（高级，1 段）
    {"id": "deep_range_1", "type": "string",
     "title": "深谷时段（如 2-5 凌晨深谷，可选）", "value": "",
     "showIf": _advanced_show},
    {"id": "deep_rate", "type": "number",
     "title": "深谷价 ¥/度（无深谷填 0）", "value": 0, "min": 0, "step": 0.01,
     "showIf": _advanced_show},
    *season_range_elements(),
]

# ➕ 添加单条时段：5 字段 + 可选季节，比批量表单清爽
add_segment_elements = [
    geofence_select,
    {"id": "hour_start", "type": "number", "title": "起始小时 (0-23)",
     "value": 22, "min": 0, "max": 23},
    {"id": "hour_end", "type": "number", "title": "结束小时 (1-24，跨午夜如 22→8)",
     "value": 8, "min": 1, "max": 24},
    {"id": "rate", "type": "number", "title": "单价 ¥/度",
     "value": 0.30, "min": 0, "step": 0.01},
    {"id": "label", "type": "select", "title": "标签",
     "value": "谷",
     "optionsSource": "Custom",
     "options": [
         {"id": "尖", "value": "尖", "label": "尖（最贵）"},
         {"id": "峰", "value": "峰", "label": "峰"},
         {"id": "平", "value": "平", "label": "平"},
         {"id": "谷", "value": "谷", "label": "谷"},
         {"id": "深谷", "value": "深谷", "label": "深谷（最便宜）"},
         {"id": "夏尖", "value": "夏尖", "label": "夏尖（季节性）"},
         {"id": "冬尖", "value": "冬尖", "label": "冬尖（季节性）"},
     ]},
    *season_range_elements(month_tooltip="夏冬季节性电价才选月份，普通用户保持「全年」"),
]

# 城市模板表单
city_elements = [
    {"id": "city", "type": "select", "title": "选城市", "value": "beijing",
     "optionsSource": "Custom",
     "options": [
         {"id": "beijing", "value": "beijing", "label": "北京"},
         {"id": "shanghai", "value": "shanghai", "label": "上海"},
         {"id": "shenzhen", "value": "shenzhen", "label": "深圳"},
         {"id": "guangzhou", "value": "guangzhou", "label": "广州"},
         {"id": "zhejiang", "value": "zhejiang", "label": "浙江/杭州"},
         {"id": "jiangsu", "value": "jiangsu", "label": "江苏/南京"},
     ]},
    {**geofence_select, "title": "应用到充电点"},
]

rate_select = {
    "id": "rate_id",
    "type": "select",
    "title": "选要操作的时段",
    "value": None,
    "optionsSource": "Query",
    "queryOptions": {
        "source": "A",
        "value": "id",
        "label": "display_name"
    },
}

modify_elements = [
    rate_select,
    {"id": "new_rate", "type": "number", "title": "新的单价 ¥/度", "value": 0.30, "min": 0, "step": 0.01},
]

delete_elements = [
    rate_select,
    {
        "id": "confirm",
        "type": "radio",
        "title": "确认删除该时段？",
        "value": "no",
        "optionsSource": "Custom",
        "options": [
            {"id": "no",  "value": "no",  "label": "取消"},
            {"id": "yes", "value": "yes", "label": "✓ 确认删除"},
        ],
    },
]

# ============================================================
# Panels
# ============================================================
panels = [
    text_panel(1, "", """
# ⚡ 分时电价配置

**最快 3 步：**
1. 「**🌆 一键导入城市模板**」选你城市（90% 用户够用）
2. **不够用** → 用「**⚡ 一键填一整季节**」：只填**谷时段 + 峰时段 + 3 档单价**，平段自动占满剩余
3. 看「**⏰ 24 小时电价分布**」 + 「**⚠ 配置审计**」核对覆盖

> 时段格式：`22-7`（跨夜）或 `0-7, 23-24`（多段用逗号）。**两档电网**：峰时段留空、峰价填 0。
""", {"x": 0, "y": 0, "w": 24, "h": 4}),

    # ⏰ 24 小时电价柱图：每小时 1 根柱，柱高=单价，颜色按阈值 0/0.4/0.7/1
    # 用 categorical x 轴（"00 时" "01 时" ...）避免依赖 dashboard time range
    hour_bar_panel(2, "⏰ 24 小时电价分布（按所选充电点 + 今日）", """
WITH hours AS (
  SELECT generate_series(0, 23) AS h
),
active AS (
  SELECT hour_start, hour_end, rate, label, valid_from, valid_to
  FROM tou_rates
  WHERE apply_to_dc = FALSE
    AND geofence_id = NULLIF('$geofence_filter', '')::INT
    AND _tou_in_season((NOW() AT TIME ZONE 'Asia/Shanghai')::DATE, valid_from, valid_to)
)
SELECT
  lpad(h.h::TEXT, 2, '0') || ' 时' AS "时点",
  COALESCE(
    (SELECT rate
     FROM active
     WHERE (
       (hour_start <= hour_end AND h.h >= hour_start AND h.h < hour_end) OR
       (hour_start >  hour_end AND (h.h >= hour_start OR h.h < hour_end))
     )
     ORDER BY (CASE WHEN valid_from IS NOT NULL THEN 0 ELSE 1 END), rate DESC
     LIMIT 1),
    0
  ) AS "单价",
  COALESCE(
    (SELECT label
     FROM active
     WHERE (
       (hour_start <= hour_end AND h.h >= hour_start AND h.h < hour_end) OR
       (hour_start >  hour_end AND (h.h >= hour_start OR h.h < hour_end))
     )
     ORDER BY (CASE WHEN valid_from IS NOT NULL THEN 0 ELSE 1 END), rate DESC
     LIMIT 1),
    '未配置'
  ) AS "标签"
FROM hours h
ORDER BY h.h
""", {"x": 0, "y": 4, "w": 24, "h": 8}),

    # ⚠ 配置审计：自动检查时段空缺/重叠/月份空缺
    # 用 UNION ALL 加 placeholder 让 0 问题时也显示「✓ 配置完整」而不是「无数据」
    table_panel(20, "⚠ 配置审计", """
WITH issues AS (
  SELECT severity, season, detail FROM audit_tou_config(NULLIF('$geofence_filter', '')::INT)
)
SELECT severity AS "严重程度", season AS "季节", detail AS "详情" FROM issues
UNION ALL
SELECT '✓ 配置完整', '-', '24 小时全覆盖、无重叠、月份完整'
WHERE NOT EXISTS (SELECT 1 FROM issues)
""", {"x": 0, "y": 12, "w": 24, "h": 6}),

    table_panel(3, "📋 当前电价配置", """
SELECT
  r.id AS "编号",
  COALESCE(g.name, '(全局)') AS "充电点",
  r.hour_start || ':00 - ' || r.hour_end || ':00' AS "时段",
  r.rate AS "单价 ¥/度",
  r.label AS "标签",
  CASE WHEN r.apply_to_dc THEN '快充' ELSE '慢充' END AS "类型",
  CASE WHEN r.valid_from IS NULL AND r.valid_to IS NULL THEN '全年'
       ELSE COALESCE(to_char(r.valid_from, 'MM/DD'), '?') || ' ~ ' || COALESCE(to_char(r.valid_to, 'MM/DD'), '?') END AS "季节"
FROM tou_rates r
LEFT JOIN geofences g ON g.id = r.geofence_id
ORDER BY r.geofence_id NULLS FIRST, r.id
""", {"x": 0, "y": 18, "w": 14, "h": 28}),

    # ⚡ 主入口：极简三档（谷峰平），平段自动占剩余
    form_panel(4, "⚡ 一键填一整季节（只填谷+峰时段，平自动）", simple_form_elements,
               # NULLIF + ::INT 强转防 SQL 注入：恶意 ${payload.geofence_id} 含单引号会触发 cast 错误而非拼出新语句
               update_sql="""
SELECT apply_tou_simple(
  NULLIF('${payload.geofence_id}', '')::INT,
  CONCAT_WS(',',
    NULLIF(NULLIF('${payload.valley_range_1}', ''), 'undefined'),
    NULLIF(NULLIF('${payload.valley_range_2}', ''), 'undefined'),
    NULLIF(NULLIF('${payload.valley_range_3}', ''), 'undefined')),
  '${payload.valley_rate}',
  CONCAT_WS(',',
    NULLIF(NULLIF('${payload.peak_range_1}', ''), 'undefined'),
    NULLIF(NULLIF('${payload.peak_range_2}', ''), 'undefined'),
    NULLIF(NULLIF('${payload.peak_range_3}', ''), 'undefined')),
  '${payload.peak_rate}',
  '${payload.mid_rate}',
  CONCAT_WS(',',
    NULLIF(NULLIF('${payload.sharp_range_1}', ''), 'undefined'),
    NULLIF(NULLIF('${payload.sharp_range_2}', ''), 'undefined')),
  '${payload.sharp_rate}',
  COALESCE(NULLIF(NULLIF('${payload.deep_range_1}', ''), 'undefined'), ''),
  '${payload.deep_rate}',
  '${payload.from_month}', '${payload.from_day}',
  '${payload.to_month}',   '${payload.to_day}'
) AS inserted
""",
               initial_sql="SELECT id, name FROM geofences ORDER BY name",
               gridPos={"x": 14, "y": 18, "w": 10, "h": 28},
               success_msg="✅ 24 小时全覆盖。刷新看左侧表格、上方状态条、审计面板",
               submit_text="⚡ 一键应用", submit_icon="bolt"),

    form_panel(5, "🌆 一键导入城市模板", city_elements,
               update_sql="SELECT apply_city_template('${payload.city}', NULLIF('${payload.geofence_id}', '')::INT) AS inserted",
               initial_sql="SELECT id, name FROM geofences ORDER BY name",
               gridPos={"x": 0, "y": 46, "w": 8, "h": 8},
               success_msg="✅ 模板已应用",
               submit_text="🌆 应用模板", submit_icon="apps"),

    form_panel(6, "✏️ 修改单价", modify_elements,
               update_sql="UPDATE tou_rates SET rate = NULLIF('${payload.new_rate}', '')::NUMERIC WHERE id = NULLIF('${payload.rate_id}', '')::INT",
               submit_text="✏️ 更新单价", submit_icon="edit",
               initial_sql=RATE_LIST_INITIAL_SQL,
               gridPos={"x": 8, "y": 46, "w": 8, "h": 8},
               success_msg="✅ 单价已更新"),

    form_panel(7, "🗑️ 删除整段", delete_elements,
               update_sql="DELETE FROM tou_rates WHERE id = NULLIF('${payload.rate_id}', '')::INT AND '${payload.confirm}' = 'yes'",
               initial_sql=RATE_LIST_INITIAL_SQL,
               gridPos={"x": 16, "y": 46, "w": 8, "h": 8},
               success_msg="✅ 已删除（如未删除请确认你选了「✓ 确认删除」）",
               submit_text="🗑️ 删除", submit_icon="trash-alt"),

    # 🔄 一键重算历史：改了 分时电价配置后跑一下，把所有历史充电按新价更新
    form_panel(9, "🔄 重算所有历史充电（按当前 分时电价配置）",
               elements=[{
                   "id": "confirm",
                   "type": "radio",
                   "title": "改完 分时电价配置后，要把历史充电按新价重新计算吗？",
                   "value": "no",
                   "optionsSource": "Custom",
                   "options": [
                       {"id": "no",  "value": "no",  "label": "暂不重算"},
                       {"id": "yes", "value": "yes", "label": "✓ 立即重算所有历史"},
                   ],
               }],
               update_sql="""
SELECT
  CASE WHEN '${payload.confirm}' = 'yes'
    THEN (SELECT processed FROM backfill_all_tou())
    ELSE 0 END AS done
""",
               initial_sql="SELECT 1",
               gridPos={"x": 0, "y": 54, "w": 24, "h": 6},
               success_msg="✅ 历史已按新 分时电价重算！刷新「最近 10 笔对账」面板和外部仪表盘看效果",
               submit_text="🔄 一键重算", submit_icon="sync"),

    table_panel(8, "💰 最近 10 笔家充电费对账", """
SELECT
  cp.id AS "充电编号",
  (cp.start_date AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai')::timestamp(0) AS "本地时间",
  ROUND(cp.charge_energy_added::numeric, 2) AS "充电度数",
  cp.cost AS "原费用 ¥",
  compute_tou_cost(cp.id) AS "分时电价费用 ¥",
  ROUND((compute_tou_cost(cp.id) - cp.cost)::numeric, 2) AS "差额 ¥",
  COALESCE(g.name, '(无)') AS "充电点"
FROM charging_processes cp
LEFT JOIN geofences g ON g.id = cp.geofence_id
WHERE cp.car_id = $car_id
  AND cp.geofence_id IN (SELECT DISTINCT geofence_id FROM tou_rates WHERE geofence_id IS NOT NULL)
ORDER BY cp.start_date DESC
LIMIT 10
""", {"x": 0, "y": 60, "w": 24, "h": 10}),
]

# ============================================================
# Variables
# ============================================================
car_id_variable = {
    "current": {},
    "datasource": DS,
    "definition": "SELECT\n    id as __value,\n    CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text \nFROM cars\nORDER BY display_priority ASC, name ASC, vin ASC;",
    "includeAll": False,
    "label": "车辆",
    "name": "car_id",
    "options": [],
    "query": "SELECT\n    id as __value,\n    CASE WHEN COUNT(id) OVER (PARTITION BY name) > 1 AND name IS NOT NULL THEN CONCAT(name, ' - ', RIGHT(vin, 6)) ELSE COALESCE(name, CONCAT('VIN ', vin)) end as __text \nFROM cars\nORDER BY display_priority ASC, name ASC, vin ASC;",
    "refresh": 1,
    "regex": "",
    "type": "query",
    "regexApplyTo": "value",
}

# 充电点过滤器（给状态条用）：列出有 分时电价配置的围栏
geofence_filter_variable = {
    "current": {},
    "datasource": DS,
    "definition": "SELECT g.id AS __value, g.name AS __text FROM geofences g WHERE g.id IN (SELECT DISTINCT geofence_id FROM tou_rates WHERE geofence_id IS NOT NULL) ORDER BY g.name",
    "includeAll": False,
    "label": "充电点",
    "name": "geofence_filter",
    "options": [],
    "query": "SELECT g.id AS __value, g.name AS __text FROM geofences g WHERE g.id IN (SELECT DISTINCT geofence_id FROM tou_rates WHERE geofence_id IS NOT NULL) ORDER BY g.name",
    "refresh": 1,
    "regex": "",
    "type": "query",
    "regexApplyTo": "value",
}

dashboard = {
    "title": "⚡ 分时电价配置",
    "uid": "tou-config",
    "tags": ["tesla", "tou", "config"],
    "schemaVersion": 41,
    "version": 1,
    "timezone": "browser",
    "time": {"from": "now-30d", "to": "now"},
    "refresh": "",
    "editable": True,
    "graphTooltip": 0,
    "fiscalYearStartMonth": 0,
    "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
    "templating": {"list": [car_id_variable, geofence_filter_variable]},
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
    ],
}

out = Path("grafana/dashboards/zh-cn/tou-config.json")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2))
print(f"✓ 写入 {out} ({out.stat().st_size} bytes)")
