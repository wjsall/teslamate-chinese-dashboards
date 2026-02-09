#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化翻译脚本 - 第二步：翻译筛选器标签
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 标签翻译词典
label_translations = {
    # 通用标签
    "Car": "车辆",
    "Geofence": "地理围栏",
    "Location": "地点",
    "Address": "地址",
    "Period": "周期",
    "Action": "操作",
    
    # 充电相关
    "Power >=": "功率 >=",
    "Power <=": "功率 <=",
    "SOC >=": "电量 >=",
    "SOC <=": "电量 <=",
    "Carrier": "运营商",
    "Bucket Width": "分桶宽度",
    "High Precision": "高精度",
    
    # 行程相关
    "Distance >=": "距离 >=",
    "Avg Speed >=": "平均速度 >=",
    "Journey": "旅程",
    
    # 单位设置
    "length unit": "长度单位",
    "temp unit": "温度单位",
    "pressure_unit": "胎压单位",
    "speed_unit": "速度单位",
    "charge_type": "充电类型",
    "terrain_type": "地形类型",
    "preferred_range": "首选续航",
    
    # 其他
    "Address Filter": "地址筛选",
    "Include Moving Average / Percentiles": "包含移动平均线/百分位数",
    "Moving Average / Percentiles Width": "移动平均线/百分位数宽度",
}

def translate_labels(data, translations):
    """翻译所有标签"""
    if isinstance(data, dict):
        for key, value in data.items():
            if key == 'label' and isinstance(value, str):
                # 精确匹配
                if value in translations:
                    data[key] = translations[value]
                    print(f"  ✓ 翻译标签: {value} → {translations[value]}")
            elif isinstance(value, (dict, list)):
                translate_labels(value, translations)
    elif isinstance(data, list):
        for item in data:
            translate_labels(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("第二步：翻译筛选器标签")
    print("="*80)
    
    total_translated = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n处理: {filename}")
        # 记录翻译前的数量
        import copy
        before = copy.deepcopy(data)
        translate_labels(data, label_translations)
        
        # 检查是否有变化
        if before != data:
            total_translated += 1
        
        # 保存
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("\n" + "="*80)
    print(f"✅ 筛选器标签汉化完成！处理了 {total_translated} 个文件")
    print("="*80)

if __name__ == "__main__":
    main()
