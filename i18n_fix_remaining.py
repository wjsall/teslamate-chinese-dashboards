#!/usr/bin/env python3
"""
全面修复遗漏的英文
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 图表类型名称翻译
chart_type_translations = {
    "Annotations & Alerts": "标注与警报",
    "Bar chart": "柱状图",
    "Bar gauge": "条形仪表盘",
    "Pie chart": "饼图",
    "XY Chart": "XY图表",
    "Time series": "时间序列",
    "Stat": "统计值",
    "Gauge": "仪表盘",
    "Table": "表格",
    "Text": "文本",
    "Logs": "日志",
    "Traces": "追踪",
    "Node Graph": "节点图",
    "Dashboard list": "Dashboard列表",
    "Alert list": "警报列表",
    "Annotations list": "标注列表",
    "News": "新闻",
    "Plugin list": "插件列表",
    "Getting Started": "入门指南",
    "Canvas": "画布",
    "Flame Graph": "火焰图",
    "Geomap": "地理地图",
    "Heatmap": "热力图",
    "Histogram": "直方图",
    "Candlestick": "K线图",
    "Trend": "趋势图",
}

# 坐标轴标签翻译
axis_label_translations = {
    "Projected Range": "预计续航",
    "Energy": "能耗",
    "Power": "功率",
    "Speed": "速度",
    "Distance": "距离",
    "Duration": "持续时间",
    "Temperature": "温度",
    "Efficiency": "能效",
    "Consumption": "能耗",
    "Voltage": "电压",
    "Current": "电流",
}

# 其他UI文本
tooltip_translations = {
    "Show Current Charge Data": "显示当前充电数据",
    "Adjust to current drive": "调整至当前驾驶",
}

# 描述文本补充翻译
description_additions = {
    "in order to have an accurate Total o": "以便有准确的总数",
    "d.\nIf so, you may follow the offic": "。\n如果是这样，你可以按照官方",
    "r indexes.\n\nIf your database experiences a": "索引。\n\n如果你的数据库经历",
    " Positions instead of Charging Proces": " 位置数据而不是充电过程",
    " between charges": " 在充电之间",
}

def fix_remaining_english(data):
    """修复剩余英文"""
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, str):
                # 图表类型名称
                if key == 'name' and value in chart_type_translations:
                    data[key] = chart_type_translations[value]
                    print(f"  ✓ name: {value} → {chart_type_translations[value]}")
                # 坐标轴标签
                elif key == 'axisLabel' and value in axis_label_translations:
                    data[key] = axis_label_translations[value]
                    print(f"  ✓ axisLabel: {value} → {axis_label_translations[value]}")
                # 提示文本
                elif key == 'tooltip' and value in tooltip_translations:
                    data[key] = tooltip_translations[value]
                    print(f"  ✓ tooltip: {value} → {tooltip_translations[value]}")
                # 描述文本（补充未翻译部分）
                elif key == 'description':
                    for en, cn in description_additions.items():
                        if en in value:
                            data[key] = value.replace(en, cn)
                            print(f"  ✓ description: ...{en[:30]}... → ...{cn[:30]}...")
                            break
            elif isinstance(value, (dict, list)):
                fix_remaining_english(value)
    elif isinstance(data, list):
        for item in data:
            fix_remaining_english(item)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("全面修复遗漏英文")
    print("="*80)
    
    count = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        before = json.dumps(data, ensure_ascii=False)
        fix_remaining_english(data)
        after = json.dumps(data, ensure_ascii=False)
        
        if before != after:
            count += 1
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
    
    print(f"\n" + "="*80)
    print(f"✅ 完成！修改了 {count} 个文件")
    print("="*80)

if __name__ == "__main__":
    main()
