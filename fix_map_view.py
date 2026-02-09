import json
import os

BASE_PATH = "grafana/dashboards/zh-cn"
files = [
    "charging-stats.json",
    "CurrentChargeView.json", 
    "CurrentDriveView.json",
    "CurrentState.json",
    "TrackingDrives.json",
    "trip.json",
    "visited.json"
]

for filename in files:
    filepath = os.path.join(BASE_PATH, filename)
    with open(filepath, 'r') as f:
        data = json.load(f)
    
    def fix_view(obj):
        if isinstance(obj, dict):
            if obj.get('type') == 'geomap' and 'options' in obj:
                options = obj['options']
                if 'view' in options:
                    # 改为自动适配数据范围
                    options['view'] = {
                        "allLayers": True,
                        "id": "fit",  # 自动适配
                        "lat": 0,
                        "lon": 0,
                        "zoom": 15
                    }
                    print(f"✅ 修复视图: {filename}")
            for value in obj.values():
                fix_view(value)
        elif isinstance(obj, list):
            for item in obj:
                fix_view(item)
    
    fix_view(data)
    
    with open(filepath, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

print("\n🗺️  地图视图已修复为自动适配模式")
