#!/usr/bin/env python3
"""
完整地图配置对比报告
"""

import json
import os

ORIGINAL_PATH = "/tmp/teslamate-original/grafana/dashboards"
CHINESE_PATH = "/tmp/teslamate-chinese-dashboards/grafana/dashboards/zh-cn"

# 所有包含地图的Dashboard
MAP_DASHBOARDS = [
    "charging-stats.json",
    "CurrentChargeView.json",
    "CurrentDriveView.json",
    "CurrentState.json",
    "trip.json",
    "visited.json",
]

def get_map_panels(data):
    """获取所有地图面板"""
    panels = []
    for p in data.get('panels', []):
        if p.get('type') == 'geomap':
            panels.append(p)
        # 检查折叠行中的面板
        if p.get('type') == 'row' and 'panels' in p:
            for sub_p in p['panels']:
                if sub_p.get('type') == 'geomap':
                    panels.append(sub_p)
    return panels

def compare_layer(layer, name=""):
    """对比图层配置"""
    info = {
        'name': layer.get('name', 'N/A'),
        'type': layer.get('type', 'N/A'),
        'tooltip': layer.get('tooltip', False),
    }
    
    # 样式配置
    if 'config' in layer and 'style' in layer['config']:
        style = layer['config']['style']
        info['color'] = style.get('color', {}).get('fixed', 'N/A')
        info['opacity'] = style.get('opacity', 'N/A')
        info['lineWidth'] = style.get('lineWidth', 'N/A')
        info['size'] = style.get('size', {}).get('fixed', 'N/A')
    
    # 位置配置
    if 'location' in layer:
        loc = layer['location']
        info['location_mode'] = loc.get('mode', 'N/A')
        info['latitude_field'] = loc.get('latitude', 'N/A')
        info['longitude_field'] = loc.get('longitude', 'N/A')
    
    return info

def print_layer_info(info, indent="  "):
    """打印图层信息"""
    print(f"{indent}名称: {info['name']}")
    print(f"{indent}类型: {info['type']}")
    print(f"{indent}提示: {info['tooltip']}")
    if 'color' in info:
        print(f"{indent}颜色: {info['color']}")
    if 'opacity' in info:
        print(f"{indent}透明度: {info['opacity']}")
    if 'lineWidth' in info:
        print(f"{indent}线宽: {info['lineWidth']}")
    if 'size' in info:
        print(f"{indent}大小: {info['size']}")
    if 'location_mode' in info:
        print(f"{indent}位置模式: {info['location_mode']}")
        print(f"{indent}纬度字段: {info['latitude_field']}")
        print(f"{indent}经度字段: {info['longitude_field']}")

def compare_dashboard(filename):
    """对比单个Dashboard"""
    orig_file = f"{ORIGINAL_PATH}/{filename}"
    cn_file = f"{CHINESE_PATH}/{filename}"
    
    if not os.path.exists(orig_file):
        print(f"⚠️  原版不存在: {filename}")
        return
    if not os.path.exists(cn_file):
        print(f"⚠️  中文版不存在: {filename}")
        return
    
    with open(orig_file) as f:
        orig_data = json.load(f)
    with open(cn_file) as f:
        cn_data = json.load(f)
    
    orig_panels = get_map_panels(orig_data)
    cn_panels = get_map_panels(cn_data)
    
    print(f"\n{'='*80}")
    print(f"📊 {filename}")
    print(f"{'='*80}")
    print(f"原版地图面板数: {len(orig_panels)}")
    print(f"中文版地图面板数: {len(cn_panels)}")
    
    if len(orig_panels) != len(cn_panels):
        print(f"⚠️  面板数量不一致!")
    
    for i, (orig_p, cn_p) in enumerate(zip(orig_panels, cn_panels)):
        print(f"\n  地图面板 #{i+1}:")
        
        # basemap对比
        orig_basemap = orig_p['options'].get('basemap', {})
        cn_basemap = cn_p['options'].get('basemap', {})
        
        print(f"\n  【底图配置】")
        print(f"    原版: type={orig_basemap.get('type', 'N/A')}, name={orig_basemap.get('name', 'N/A')}")
        print(f"    中文: type={cn_basemap.get('type', 'N/A')}, name={cn_basemap.get('name', 'N/A')}")
        
        if orig_basemap != cn_basemap:
            print(f"    ⚠️  底图配置不同!")
        
        # view对比
        orig_view = orig_p['options'].get('view', {})
        cn_view = cn_p['options'].get('view', {})
        
        print(f"\n  【视图配置】")
        print(f"    原版: id={orig_view.get('id', 'N/A')}, zoom={orig_view.get('zoom', 'N/A')}")
        print(f"    中文: id={cn_view.get('id', 'N/A')}, zoom={cn_view.get('zoom', 'N/A')}")
        
        # layers对比
        orig_layers = orig_p['options'].get('layers', [])
        cn_layers = cn_p['options'].get('layers', [])
        
        print(f"\n  【图层配置】")
        print(f"    原版层数: {len(orig_layers)}")
        print(f"    中文层数: {len(cn_layers)}")
        
        if len(orig_layers) != len(cn_layers):
            print(f"    ⚠️  图层数量不一致!")
        
        # 详细对比每一层
        max_layers = max(len(orig_layers), len(cn_layers))
        for j in range(max_layers):
            print(f"\n    图层 #{j+1}:")
            
            if j < len(orig_layers):
                print(f"      原版:")
                orig_info = compare_layer(orig_layers[j], f"orig_layer_{j}")
                print_layer_info(orig_info, "        ")
            else:
                print(f"      原版: (无)")
            
            if j < len(cn_layers):
                print(f"      中文:")
                cn_info = compare_layer(cn_layers[j], f"cn_layer_{j}")
                print_layer_info(cn_info, "        ")
            else:
                print(f"      中文: (无)")
            
            # 对比差异
            if j < len(orig_layers) and j < len(cn_layers):
                orig_info = compare_layer(orig_layers[j])
                cn_info = compare_layer(cn_layers[j])
                
                differences = []
                for key in ['type', 'color', 'opacity', 'lineWidth', 'location_mode', 'latitude_field', 'longitude_field']:
                    if key in orig_info and key in cn_info:
                        if orig_info[key] != cn_info[key]:
                            differences.append(f"{key}: {orig_info[key]} → {cn_info[key]}")
                
                if differences:
                    print(f"      ⚠️  差异:")
                    for diff in differences:
                        print(f"         - {diff}")

def main():
    print("="*80)
    print("TeslaMate 地图配置完整对比报告")
    print("="*80)
    
    for filename in MAP_DASHBOARDS:
        compare_dashboard(filename)
    
    print(f"\n{'='*80}")
    print("对比完成")
    print(f"{'='*80}")

if __name__ == "__main__":
    main()
