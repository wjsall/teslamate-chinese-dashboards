#!/usr/bin/env python3
"""
修复地图配置 - 移除多余的透明markers层
"""

import json
import os

BASE_PATH = "/tmp/teslamate-chinese-dashboards/grafana/dashboards/zh-cn"

# 需要修复的文件
FILES_TO_FIX = ["trip.json", "visited.json"]

def fix_map_layers(filepath):
    """修复地图图层配置"""
    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    modified = False
    
    for panel in data.get('panels', []):
        if panel.get('type') == 'geomap':
            layers = panel['options'].get('layers', [])
            
            # 如果有多层，检查是否有透明的markers层
            if len(layers) > 1:
                # 找出有效的route层
                route_layers = [l for l in layers if l.get('type') == 'route']
                marker_layers = [l for l in layers if l.get('type') == 'markers']
                
                # 如果有markers层且是透明的，删除它
                if marker_layers:
                    marker = marker_layers[0]
                    style = marker.get('config', {}).get('style', {})
                    opacity = style.get('opacity', 1)
                    color = style.get('color', {}).get('fixed', '')
                    
                    if opacity == 0 or color == 'transparent':
                        # 删除透明的markers层
                        new_layers = [l for l in layers if l != marker]
                        panel['options']['layers'] = new_layers
                        modified = True
                        print(f"  ✓ 移除透明的markers层: {marker.get('name', 'N/A')}")
                        print(f"    剩余 {len(new_layers)} 层")
    
    return data, modified

def main():
    print("="*60)
    print("修复地图配置")
    print("="*60)
    
    for filename in FILES_TO_FIX:
        filepath = os.path.join(BASE_PATH, filename)
        print(f"\n📄 {filename}")
        
        data, modified = fix_map_layers(filepath)
        
        if modified:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            print("  ✅ 已修复")
        else:
            print("  ℹ️  无需修复")
    
    print(f"\n{'='*60}")
    print("修复完成")
    print(f"{'='*60}")

if __name__ == "__main__":
    main()
