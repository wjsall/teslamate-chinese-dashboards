#!/usr/bin/env python3
"""
地图配置对比和修复
"""

import json

ORIGINAL_PATH = "/tmp/teslamate-original/grafana/dashboards"
CHINESE_PATH = "/tmp/teslamate-chinese-dashboards/grafana/dashboards/zh-cn"

def compare_visited():
    """对比 visited.json 地图配置"""
    with open(f"{ORIGINAL_PATH}/visited.json") as f:
        orig = json.load(f)
    with open(f"{CHINESE_PATH}/visited.json") as f:
        cn = json.load(f)
    
    orig_panel = [p for p in orig['panels'] if p['type'] == 'geomap'][0]
    cn_panel = [p for p in cn['panels'] if p['type'] == 'geomap'][0]
    
    print("="*80)
    print("visited.json 地图配置对比")
    print("="*80)
    
    print("\n【basemap 差异】")
    print(f"原版: {orig_panel['options']['basemap']}")
    print(f"中文: {cn_panel['options']['basemap']}")
    
    print("\n【layers 差异】")
    print(f"原版层数: {len(orig_panel['options']['layers'])}")
    print(f"中文层数: {len(cn_panel['options']['layers'])}")
    
    for i, layer in enumerate(orig_panel['options']['layers']):
        print(f"\n原版 Layer {i}: {layer.get('name', 'N/A')} (type: {layer.get('type', 'N/A')})")
        print(f"  - tooltip: {layer.get('tooltip', 'N/A')}")
        print(f"  - location: {layer.get('location', 'N/A')}")
    
    for i, layer in enumerate(cn_panel['options']['layers']):
        print(f"\n中文 Layer {i}: {layer.get('name', 'N/A')} (type: {layer.get('type', 'N/A')})")
        print(f"  - tooltip: {layer.get('tooltip', 'N/A')}")
        print(f"  - location: {layer.get('location', 'N/A')}")
        if 'style' in layer.get('config', {}):
            style = layer['config']['style']
            print(f"  - style.color: {style.get('color', 'N/A')}")
            print(f"  - style.opacity: {style.get('opacity', 'N/A')}")
    
    print("\n【问题诊断】")
    print("1. 中文版添加了额外的 markers 层（位置点）")
    print("2. markers 层的颜色是 transparent，opacity 是 0（完全透明）")
    print("3. 这可能导致地图显示异常或详情减少")
    
    print("\n【修复建议】")
    print("方案1: 移除多余的 markers 层，只保留 route 层（与原版一致）")
    print("方案2: 修复 markers 层的样式配置")

if __name__ == "__main__":
    compare_visited()
