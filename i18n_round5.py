#!/usr/bin/env python3
"""
第五轮汉化 - 最终清理
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 最终翻译
final_translations = {
    # 状态值
    "driving": "驾驶中",
    "charging": "充电中",
    "offline": "离线",
    "asleep": "休眠中",
    "online": "在线",
    
    # 时间
    "week": "周",
    
    # 描述文本（长）
    "Browse your charges by Geofence, Location, Type, Cost and Duration":
        "按地理围栏、位置、类型、费用和时长浏览充电记录",
    
    "Type a text contained in Location":
        "输入位置包含的文字",
    
    "Start or Destination Geofence":
        "起点或终点地理围栏",
    
    "Type a text contained in Start or Destination Location":
        "输入起点或终点位置包含的文字",
    
    "(Range lost while driving * Efficiency) / Distance driven":
        "（驾驶中续航损失 × 能效）/ 行驶距离",
    
    "(Range lost between charges * Efficiency) / Distance driven":
        "（充电间续航损失 × 能效）/ 行驶距离",
    
    "Distance of all logged drives":
        "所有记录行程的距离",
    
    "based on any data ever recorded.":
        "基于曾经记录的所有数据。",
    
    "When enabled \"Ø Consumption (gross)\" will be calculated via":
        "启用后，\"平均能耗（总值）\"将通过以下方式计算",
    
    "This means you have some **Drives** or **Charges** not closed properly":
        "这意味着你有一些**行程**或**充电**未正确关闭",
    
    "These statistics can help you evaluate the efficiency of your database":
        "这些统计信息可以帮助你评估数据库效率",
    
    # 其他
    "❓ Missing": "❓ 缺失",
    "Jo-El": "Jo-El",
    "bar": "bar",
}

def translate_final(data, translations):
    if isinstance(data, dict):
        for key, value in data.items():
            if key in ['text', 'description', 'custom'] and isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ {key}: {value[:40]}...")
                # 部分匹配长文本
                elif len(value) > 20:
                    for en, cn in translations.items():
                        if en in value:
                            data[key] = value.replace(en, cn)
                            print(f"  ✓ {key}: {en[:40]}...")
                            break
            elif isinstance(value, (dict, list)):
                translate_final(value, translations)
    elif isinstance(data, list):
        for item in data:
            translate_final(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第五轮汉化 - 最终清理")
    print("="*80)
    
    count = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        before = json.dumps(data, ensure_ascii=False)
        translate_final(data, final_translations)
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
