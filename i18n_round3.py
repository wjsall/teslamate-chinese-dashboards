#!/usr/bin/env python3
"""
第三轮汉化 - 处理剩余的描述和标题
只翻译安全的UI字段
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 剩余的UI翻译
REMAINING_TRANSLATIONS = {
    # 描述（长文本）
    "For this section, it's important that you have geo-fences called \"Home\" and \"Work\" with costs configured for accurate cost calculations.":
        "此部分需要配置名为\"家\"和\"公司\"的地理围栏并设置费用，以便准确计算充电成本。",
    
    "This dashboard is meant to have a look of all the charges in a given period (last 30 days by default).":
        "本仪表盘用于查看指定时间段内的所有充电记录（默认为最近30天）。",
    
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
    
    "With this dashboard you may analize your mileage and number of drives per day/week/month/year.":
        "使用本仪表盘可以分析每日/周/月/年的里程和行程次数。",
    
    "This dashboard is meant to analize a drive based on a date you select.":
        "本仪表盘用于分析选定日期的行程。",
    
    "Data used to calculate Moving Average / Percentiles is unevenly distributed, results may be inaccurate.":
        "用于计算移动平均线/百分位数的数据分布不均匀，结果可能不准确。",
    
    # 标题（包含变量）
    "免费充电里程 (no cost)": "免费充电里程（无费用）",
    "Current $preferred_range efficiency（标准能耗）": "当前 $preferred_range 标准能效",
}

def translate_remaining(data, translations):
    """翻译剩余内容"""
    if isinstance(data, dict):
        for key, value in data.items():
            if key in ['title', 'description'] and isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ {key}: {value[:40]}...")
                # 部分匹配长文本
                elif key == 'description' and len(value) > 50:
                    for en, cn in translations.items():
                        if en[:50] in value or value[:50] in en:
                            data[key] = cn
                            print(f"  ✓ {key}: {value[:40]}...")
                            break
            elif isinstance(value, (dict, list)):
                translate_remaining(value, translations)
    elif isinstance(data, list):
        for item in data:
            translate_remaining(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第三轮汉化 - 剩余UI文本")
    print("="*80)
    
    translated_count = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        before = json.dumps(data, ensure_ascii=False)
        translate_remaining(data, REMAINING_TRANSLATIONS)
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
