#!/bin/bash
# 足迹地图的真实点与显式分段契约。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import json
from pathlib import Path

path = Path('grafana/dashboards/zh-cn/visited.json')
dashboard = json.loads(path.read_text(encoding='utf-8'))
panels = {panel['id']: panel for panel in dashboard['panels'] if 'id' in panel}
panel = panels.get(2)
if panel is None or panel.get('title') != '行驶轨迹' or panel.get('type') != 'geomap':
    raise SystemExit('足迹地图 panel 2 身份漂移')

layers = panel.get('options', {}).get('layers', [])
if [layer.get('type') for layer in layers] != ['network', 'markers']:
    raise SystemExit('足迹地图必须是 Network 层（分段轨迹）+ Markers 层（到访城市）')
if layers[0].get('filterData') != {'id': 'byRefId', 'options': '/^(Nodes|Edges)$/'}:
    raise SystemExit('Network 层必须只读取 Nodes/Edges，不能混入城市点')
if layers[1].get('filterData') != {'id': 'byRefId', 'options': 'Cities'}:
    raise SystemExit('Markers 层必须只读取 Cities')

targets = {target.get('refId'): target for target in panel.get('targets', [])}
if set(targets) != {'Nodes', 'Edges', 'Cities'}:
    raise SystemExit(f'足迹地图必须只有 Nodes/Edges/Cities 三个 target，实际 {sorted(targets)}')
cities = targets['Cities'].get('rawSql', '')
for token in (
    "lat_for_map('${map_url}', avg(latitude)::float, avg(longitude)::float) AS latitude",
    "lng_for_map('${map_url}', avg(latitude)::float, avg(longitude)::float) AS longitude",
):
    if token not in cities:
        raise SystemExit(f'城市点坐标未按底图修正: {token}')

nodes = targets['Nodes'].get('rawSql', '')
edges = targets['Edges'].get('rawSql', '')
if not nodes or not edges:
    raise SystemExit('Nodes/Edges 必须直接执行 PostgreSQL SQL')

for token in (
    'sample_ids AS MATERIALIZED',
    'MIN(p.id) AS id',
    'CROSS JOIN LATERAL',
    'WHERE p.id = s.id',
    'OFFSET 0',
    'p.id::text AS id',
    'p.drive_id IS NOT NULL',
    "lat_for_map('${map_url}', latitude, longitude) AS latitude",
    "lng_for_map('${map_url}', latitude, longitude) AS longitude",
):
    if token not in nodes:
        raise SystemExit(f'Nodes 查询缺少真实点契约: {token}')
for forbidden in ('avg(latitude)', 'avg(longitude)'):
    if forbidden.lower() in nodes.lower():
        raise SystemExit(f'Nodes 仍在生成不存在的平均坐标: {forbidden}')

for token in (
    'LEAD(id) OVER (PARTITION BY drive_id ORDER BY date)',
    'LEAD(date) OVER (PARTITION BY drive_id ORDER BY date)',
    "id || '->' || next_id AS id",
    'id AS source',
    'next_id AS target',
    "next_date - date <= interval '5 minutes'",
):
    if token not in edges:
        raise SystemExit(f'Edges 查询缺少分段契约: {token}')
for token in ('p.drive_id IS NOT NULL', '$__timeFilter(p.date)'):
    if token not in nodes or token not in edges:
        raise SystemExit(f'Nodes/Edges 未同时限定行程和时间: {token}')

print('✅ 足迹地图真实点与显式分段契约通过')
PY
