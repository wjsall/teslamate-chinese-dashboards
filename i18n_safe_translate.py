#!/usr/bin/env python3
"""
安全的UI翻译 - 只翻译UI字段，严格避开SQL和技术字段
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 安全翻译词典（只包含UI文本）
SAFE_TRANSLATIONS = {
    # 面板标题
    "Current Charge View": "当前充电状态",
    "Current Drive View": "当前驾驶状态", 
    "Current State": "最近车辆状态",
    "Tire Pressure": "胎压",
    
    # 筛选器标签
    "Car": "车辆",
    "Geofence": "地理围栏",
    "Address": "地址",
    "Location": "地点",
    "Action": "操作",
    "Period": "周期",
    "Bucket Width": "分桶宽度",
    "High Precision": "高精度",
    "length unit": "长度单位",
    "temp unit": "温度单位",
    "temperature unit": "温度单位",
    "Time Resolution": "时间分辨率",
    
    # 描述文本
    "Load this dashboard to while you are in a charging session. When you open this dashboard, it will automatically refresh every minute.":
        "充电时加载此仪表盘查看实时状态。打开后会自动每分钟刷新。",
    
    "This is a special dashboard to load while driving. When you open this dashboard, it will automatically refresh every minute.":
        "驾驶时加载此特殊仪表盘。打开后会自动每分钟刷新。",
    
    "This dasboard is just to see the current state of the car with the last data received.":
        "本仪表盘用于查看车辆当前状态及最新接收的数据。",
    
    "Overview of the current state of your car":
        "车辆当前状态概览",
    
    "Tire pressure over time":
        "胎压变化趋势",
}

def safe_translate_ui(data, translations):
    """只翻译安全的UI字段"""
    if isinstance(data, dict):
        for key, value in data.items():
            # 只处理安全的UI字段
            if key in ['title', 'description', 'label'] and isinstance(value, str):
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ {key}: {value[:40]}... → {translations[value][:40]}...")
            elif isinstance(value, (dict, list)):
                safe_translate_ui(value, translations)
    elif isinstance(data, list):
        for item in data:
            safe_translate_ui(item, translations)

def main():
    # 只处理有问题的3个文件
    target_files = ['CurrentChargeView.json', 'CurrentState.json', 'tire-pressure.json']
    
    print("="*80)
    print("安全的UI翻译（第二轮）")
    print("只翻译: title, description, label")
    print("不翻译: SQL查询, 变量名, 技术字段")
    print("="*80)
    
    for filename in target_files:
        filepath = os.path.join(BASE_PATH, filename)
        
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        safe_translate_ui(data, SAFE_TRANSLATIONS)
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("\n" + "="*80)
    print("✅ 安全翻译完成！")
    print("="*80)

if __name__ == "__main__":
    main()
