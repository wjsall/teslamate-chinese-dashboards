#!/usr/bin/env python3
"""
优化 Grafana 地图配置
添加轨迹线、标记点、更好的缩放设置
"""

import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"

# 优化的地图配置
OPTIMIZED_BASEMAP = {
    "config": {
        "server": "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
        "attribution": "&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a> contributors"
    },
    "name": "OpenStreetMap",
    "type": "xyz"
}

# 轨迹线图层配置
ROUTE_LAYER = {
    "config": {
        "arrow": 0,
        "style": {
            "color": {
                "fixed": "dark-blue"
            },
            "lineWidth": 3,
            "opacity": 0.8,
            "rotation": {
                "fixed": 0,
                "max": 360,
                "min": -360,
                "mode": "mod"
            },
            "size": {
                "fixed": 4,
                "max": 15,
                "min": 2
            },
            "symbol": {
                "fixed": "img/icons/marker/circle.svg",
                "mode": "fixed"
            },
            "symbolAlign": {
                "horizontal": "center",
                "vertical": "center"
            },
            "textConfig": {
                "fontSize": 12,
                "offsetX": 0,
                "offsetY": 0,
                "textAlign": "center",
                "textBaseline": "middle"
            }
        }
    },
    "location": {
        "latitude": "lat",
        "longitude": "long",
        "mode": "auto"
    },
    "name": "行驶轨迹",
    "tooltip": True,
    "type": "route"
}

# 标记点图层
MARKER_LAYER = {
    "config": {
        "showLegend": True,
        "style": {
            "color": {
                "fixed": "red"
            },
            "opacity": 0.8,
            "rotation": {
                "fixed": 0,
                "max": 360,
                "min": -360,
                "mode": "mod"
            },
            "size": {
                "fixed": 6,
                "max": 15,
                "min": 4
            },
            "symbol": {
                "fixed": "img/icons/marker/location.svg",
                "mode": "fixed"
            },
            "symbolAlign": {
                "horizontal": "center",
                "vertical": "center"
            },
            "textConfig": {
                "fontSize": 12,
                "offsetX": 0,
                "offsetY": -10,
                "textAlign": "center",
                "textBaseline": "bottom"
            }
        }
    },
    "location": {
        "mode": "auto"
    },
    "name": "位置标记",
    "tooltip": True,
    "type": "markers"
}

def optimize_map(data):
    """优化地图配置"""
    if isinstance(data, dict):
        # 检查是否是geomap面板
        if data.get('type') == 'geomap' and 'options' in data:
            options = data['options']
            
            # 优化basemap
            if 'basemap' in options:
                options['basemap'] = OPTIMIZED_BASEMAP
                print("  ✓ 优化地图源")
            
            # 优化视图设置
            if 'view' in options:
                options['view']['zoom'] = 12  # 默认缩放级别
                options['view']['id'] = 'zero'  # 从零开始而不是fit
                print("  ✓ 优化视图设置")
            
            # 优化图层
            if 'layers' in options:
                # 保留第一个图层（通常是轨迹）
                # 优化其样式
                for i, layer in enumerate(options['layers']):
                    if layer.get('type') == 'route':
                        layer['name'] = '行驶轨迹'
                        layer['tooltip'] = True
                        if 'config' in layer and 'style' in layer['config']:
                            layer['config']['style']['lineWidth'] = 3
                            layer['config']['style']['opacity'] = 0.8
                        print(f"  ✓ 优化轨迹图层")
                    elif layer.get('type') == 'markers':
                        layer['name'] = '位置点'
                        layer['tooltip'] = True
                        print(f"  ✓ 优化标记图层")
        
        # 递归处理
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                optimize_map(value)
    
    elif isinstance(data, list):
        for item in data:
            optimize_map(item)

def main():
    files_with_maps = [
        'charging-stats.json',
        'CurrentChargeView.json',
        'CurrentDriveView.json',
        'CurrentState.json',
        'TrackingDrives.json',
        'trip.json',
        'visited.json'
    ]
    
    print("="*80)
    print("优化地图配置")
    print("="*80)
    
    for filename in files_with_maps:
        filepath = os.path.join(BASE_PATH, filename)
        if os.path.exists(filepath):
            with open(filepath, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            print(f"\n📄 {filename}")
            optimize_map(data)
            
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("\n" + "="*80)
    print("✅ 地图优化完成！")
    print("改进内容:")
    print("- 优化地图源配置")
    print("- 调整默认缩放级别")
    print("- 启用轨迹线提示")
    print("- 优化图层样式")
    print("="*80)

if __name__ == "__main__":
    main()
