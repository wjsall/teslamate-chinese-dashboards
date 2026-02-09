#!/usr/bin/env python3
"""
全面修复图表中的英文标签
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 图表标签翻译
chart_label_translations = {
    # 能耗相关
    "Energy": "能耗",
    "Consumption": "能耗",
    "Consumption gross": "总能耗",
    "Ø Consumption (net):": "平均能耗（净值）：",
    "Ø Consumption (gross):": "平均能耗（总值）：",
    "Avg. Consumption": "平均能耗",
    "Energy Diff": "能耗差异",
    
    # 距离相关
    "Distance": "距离",
    "Avg. Distance": "平均距离",
    "Total Distance logged:": "总行驶里程：",
    
    # 速度相关
    "Speed": "速度",
    "Avg. Speed": "平均速度",
    "Speed (km/h)": "速度 (km/h)",
    "Speed (mi/h)": "速度 (mi/h)",
    
    # 功率相关
    "Power": "功率",
    "Power (kW)": "功率 (kW)",
    
    # 其他
    "Temperature": "温度",
    "Efficiency": "能效",
    "Current": "当前",
    "Average": "平均",
    "Total": "总计",
    "Duration": "持续时间",
    "Cost": "费用",
}

def fix_chart_labels(data, translations):
    """修复图表标签"""
    if isinstance(data, dict):
        for key, value in data.items():
            # 检查 value 字段（在 overrides 或 mappings 中）
            if key == 'value' and isinstance(value, str):
                for en, cn in translations.items():
                    if value == en:
                        data[key] = cn
                        print(f"  ✓ value: {en} → {cn}")
                        break
            # 检查 custom 字段
            elif key == 'custom' and isinstance(value, dict):
                for k, v in value.items():
                    if isinstance(v, str):
                        for en, cn in translations.items():
                            if v == en:
                                value[k] = cn
                                print(f"  ✓ custom.{k}: {en} → {cn}")
                                break
            elif isinstance(value, (dict, list)):
                fix_chart_labels(value, translations)
    elif isinstance(data, list):
        for item in data:
            fix_chart_labels(item, translations)

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("修复图表英文标签")
    print("="*80)
    
    count = 0
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        print(f"\n📄 {filename}")
        before = json.dumps(data, ensure_ascii=False)
        fix_chart_labels(data, chart_label_translations)
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
