#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化 - 补充翻译（第二轮）
自动处理遗漏的英文内容
"""

import json
import os
import re

BASE_PATH = "grafana/dashboards/zh-cn"

# 补充翻译词典（第二轮）
supplemental_translations = {
    # 描述翻译（长文本）
    "For this section, it's important that you have geo-fences called \"Home\" and \"Work\" with costs configured for accurate cost calculations.": 
        "此部分需要配置名为\"家\"和\"公司\"的地理围栏并设置费用，以便准确计算充电成本。",
    
    "This dashboard is meant to have a look of all the charges in a given period (last 30 days by default).": 
        "本仪表盘用于查看指定时间段内的所有充电记录（默认为最近30天）。",
    
    "Use the dropdown at the top to  choose the Geofence to display energy added from": 
        "使用顶部下拉菜单选择地理围栏，以显示在该地点添加的电量",
    
    "Gross is all consumption (including while idle, phantom drains, sentry mode, etc.)": 
        "总能耗（包括怠速、幽灵耗电、哨兵模式等）",
    
    "This dashboard is meant to have a look of the charging curve sessions on Tesla Superchargers and other DC chargers.": 
        "本仪表盘用于查看特斯拉超级充电站和其他直流充电站的充电曲线。",
    
    "This dashboard has a table with all the trips you've made between charges sessions.": 
        "本仪表盘显示每次充电之间的所有行程。",
    
    "Load this dashboard to while you are in a charging session. When you open this dashboard, it will automatically refresh every minute.": 
        "充电时加载此仪表盘查看实时状态。打开后会自动每分钟刷新。",
    
    "This is a special dashboard to load while driving. When you open this dashboard, it will automatically refresh every minute.": 
        "驾驶时加载此特殊仪表盘。打开后会自动每分钟刷新。",
    
    "This dasboard is just to see the current state of the car with the last data received.": 
        "本仪表盘用于查看车辆当前状态及最新接收的数据。",
    
    "Carrier Name": "运营商名称",
    
    "Time Resolution": "时间分辨率",
    "temperature unit": "温度单位",
}

def smart_translate(data, translations):
    """智能翻译 - 支持部分匹配"""
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ 翻译: {value[:40]}...")
                # 部分匹配（针对截断的文本）
                elif key in ['description', 'label']:
                    for en, cn in translations.items():
                        if value in en or en in value:
                            data[key] = cn
                            print(f"  ✓ 翻译: {value[:40]}...")
                            break
            elif isinstance(value, (dict, list)):
                smart_translate(value, translations)
    elif isinstance(data, list):
        for item in data:
            smart_translate(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第二轮补充汉化")
    print("="*80)
    
    total_changes = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # 检查是否包含未翻译的英文
        has_english = False
        for en_text in supplemental_translations.keys():
            if en_text[:50] in content:  # 只检查前50个字符
                has_english = True
                break
        
        if has_english:
            print(f"\n处理: {filename}")
            data = json.loads(content)
            before = content
            smart_translate(data, supplemental_translations)
            after = json.dumps(data, ensure_ascii=False)
            
            if before != after:
                total_changes += 1
                with open(filepath, 'w', encoding='utf-8') as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("\n" + "="*80)
    print(f"✅ 补充汉化完成！修改了 {total_changes} 个文件")
    print("="*80)

if __name__ == "__main__":
    main()
