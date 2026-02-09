#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化翻译脚本 - 第一步：翻译面板描述
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 描述翻译词典
desc_translations = {
    # ChargingCostsStats.json
    "For this section, it's important that you have geo-fences called \"Home\" and \"Work\" with costs configured for accurate cost calculations.": 
        "此部分需要配置名为\"家\"和\"公司\"的地理围栏并设置费用，以便准确计算充电成本。",
    
    "This dashboard is meant to have a look of all the charges in a given period (last 30 days by default).": 
        "本仪表盘用于查看指定时间段内的所有充电记录（默认为最近30天）。",
    
    "Use the dropdown at the top to  choose the Geofence to display energy added from.": 
        "使用顶部下拉菜单选择地理围栏，以显示在该地点添加的电量。",
    
    "Net is the efficiency while driving": 
        "净能效（行驶中）",
    
    "Gross is all consumption (including while idle, phantom drains, sentry mode, etc.)": 
        "总能耗（包括怠速、幽灵耗电、哨兵模式等）",
    
    "Geofence to display energy added at": 
        "显示充电地点的地理围栏",
    
    # ChargingCurveStats.json
    "This dashboard is meant to have a look of the charging curve sessions on Tesla Superchargers and other DC chargers.": 
        "本仪表盘用于查看特斯拉超级充电站和其他直流充电站的充电曲线。",
    
    # ContinuousTrips.json
    "This dashboard has a table with all the trips you've made between charges sessions.": 
        "本仪表盘显示每次充电之间的所有行程。",
    
    # CurrentChargeView.json
    "Load this dashboard to while you are in a charging session. When you open this dashboard, it will automatically refresh every minute.": 
        "充电时加载此仪表盘查看实时状态。打开后会自动每分钟刷新。",
    
    # CurrentDriveView.json
    "A high level overview of your car": 
        "车辆整体概览",
    
    # CurrentState.json
    "Overview of the current state of your car": 
        "车辆当前状态概览",
    
    # DCChargingCurvesByCarrier.json
    "This dashboard is meant to have a look of the charging curve sessions by carrier.": 
        "本仪表盘用于按运营商查看充电曲线。",
    
    # drives.json
    "This dashboard is meant to have a look of all the drives in a given period (last 30 days by default).": 
        "本仪表盘用于查看指定时间段内的所有行程（默认为最近30天）。",
    
    # efficiency.json
    "Efficiency of your car based on various factors": 
        "基于各种因素的车辆能效分析",
    
    # IncompleteData.json
    "Incomplete data that needs to be fixed": 
        "需要修复的不完整数据",
    
    # locations.json
    "Locations where you have charged your car": 
        "您充电过的地点",
    
    # mileage.json
    "Mileage over time": 
        "里程变化趋势",
    
    # projected-range.json
    "Projected range based on various factors": 
        "基于各种因素的预计续航里程",
    
    # SpeedRates.json
    "Efficiency at different speeds": 
        "不同速度下的能效",
    
    # statistics.json
    "Statistics of your car usage": 
        "车辆使用统计",
    
    # timeline.json
    "Timeline of your car usage": 
        "车辆使用时间线",
    
    # tire-pressure.json
    "Tire pressure over time": 
        "胎压变化趋势",
    
    # TrackingDrives.json
    "Track your drives on the map": 
        "在地图上追踪您的行程",
    
    # trip.json
    "Detailed view of a trip": 
        "行程详细视图",
    
    # updates.json
    "Software updates history": 
        "软件更新历史",
    
    # vampire-drain.json
    "Energy consumed while the car is parked": 
        "停车时消耗的能量（幽灵耗电）",
    
    # visited.json
    "Places you have visited": 
        "您访问过的地方",
}

def translate_descriptions(data, translations):
    """翻译所有描述"""
    if isinstance(data, dict):
        for key, value in data.items():
            if key == 'description' and isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ 翻译描述: {value[:50]}...")
            elif isinstance(value, (dict, list)):
                translate_descriptions(value, translations)
    elif isinstance(data, list):
        for item in data:
            translate_descriptions(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第一步：翻译面板描述")
    print("="*80)
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n处理: {filename}")
        translate_descriptions(data, desc_translations)
        
        # 保存
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("\n" + "="*80)
    print("✅ 面板描述汉化完成！")
    print("="*80)

if __name__ == "__main__":
    main()
