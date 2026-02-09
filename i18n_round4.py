#!/usr/bin/env python3
"""
第四轮汉化 - 处理 displayName 和自定义文本
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# displayName 和自定义文本翻译
custom_translations = {
    # displayName
    "Total Energy consumed (net):": "总能耗（净值）：",
    "Starting at": "开始于",
    "Energy used": "耗电量",
    "Temperature": "温度",
    "Start": "开始",
    "Date": "日期",
    "N/A": "无数据",
    "online": "在线",
    "updating": "更新中",
    "bar": "bar",
    "year": "年",
    "month": "月",
    "day": "日",
    
    # 时间线
    "🔋 Charging": "🔋 充电中",
    "🅿️ Parking": "🅿️ 停放",
    "🚗 Driving": "🚗 驾驶中",
    "💾 Updating": "💾 更新中",
    
    # 描述文本
    "Type a text contained in Location": "输入位置包含的文字",
    "Browse your charges by Geofence, Location, Type, Cost and Du": "按地理围栏、位置、类型、费用和时长浏览充电记录",
    "Type a text contained in Start or Destination Location": "输入起点或终点位置包含的文字",
    "Start or Destination Geofence": "起点或终点地理围栏",
    
    # 效率
    "(Range lost between charges * Efficiency) / Distance driven": "（充电间续航损失 × 能效）/ 行驶距离",
    "Distance of all logged drives": "所有记录行程的距离",
    "(Range lost while driving * Efficiency) / Distance driven": "（驾驶中续航损失 × 能效）/ 行驶距离",
    
    # 统计
    "When enabled \"Ø Consumption (gross)\" will be calculated via": "启用后，\"平均能耗（总值）\"将通过以下方式计算",
    "based on any data ever recorded.": "基于曾经记录的所有数据。",
    
    # 数据库
    "These statistics can help you evaluate the efficiency of you": "这些统计信息可以帮助你评估数据库效率",
    "This means you have some **Drives** or **Charges** not close": "这意味着你有一些**行程**或**充电**未正确关闭",
    
    # 其他
    "1/12 of interval": "间隔的1/12",
    "1/6 of interval": "间隔的1/6",
    "yes": "是",
    "30m": "30分钟",
    "15m": "15分钟",
    "Jo-El": "Jo-El",
}

def translate_custom_fields(data, translations):
    """翻译自定义字段"""
    if isinstance(data, dict):
        for key, value in data.items():
            if key in ['displayName', 'custom', 'text'] and isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ {key}: {value[:40]}...")
                # 部分匹配
                elif len(value) > 10:
                    for en, cn in translations.items():
                        if en in value:
                            data[key] = value.replace(en, cn)
                            print(f"  ✓ {key}: {en[:40]}...")
                            break
            elif isinstance(value, (dict, list)):
                translate_custom_fields(value, translations)
    elif isinstance(data, list):
        for item in data:
            translate_custom_fields(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第四轮汉化 - displayName和自定义文本")
    print("="*80)
    
    translated_count = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        before = json.dumps(data, ensure_ascii=False)
        translate_custom_fields(data, custom_translations)
        after = json.dumps(data, ensure_ascii=False)
        
        if before != after:
            translated_count += 1
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
    
    print(f"\n" + "="*80)
    print(f"✅ 完成！修改了 {translated_count} 个文件")
    print("="*80)

if __name__ == "__main__":
    main()
