#!/bin/bash
# 驾驶评分查询共享与有界扫描契约。
#
# 这道门不做性能计时；它锁定已经用真实大库验证过的结构性修复：
# - 评分卡共享一次 PostgreSQL 结果；
# - 趋势只跑一条派生查询；
# - 只有汇总、趋势、明细三条查询扫描 positions；
# - 每条重查询都用 car_id + 时间范围约束 positions。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import json
from pathlib import Path

path = Path('grafana/dashboards/zh-cn/driving-score.json')
dashboard = json.loads(path.read_text(encoding='utf-8'))
panels = {panel['id']: panel for panel in dashboard['panels'] if 'id' in panel}

expected_titles = {
    1: '综合评分',
    2: '效率分',
    3: '平稳分',
    4: '速度分',
    5: '回收分',
    6: '综合评分趋势',
    7: '行程评分明细',
    8: '驾驶风格',
}
for panel_id, title in expected_titles.items():
    panel = panels.get(panel_id)
    if panel is None or panel.get('title') != title:
        raise SystemExit(f'panel {panel_id} 标题/身份漂移，期望 {title!r}')

source = panels[1]
source_targets = source.get('targets', [])
if len(source_targets) != 1 or not source_targets[0].get('rawSql'):
    raise SystemExit('综合评分必须是唯一的 PostgreSQL 评分数据源')

score_fields = ('综合评分', '驾驶风格', '效率分', '平稳分', '速度分', '回收分')
source_sql = source_targets[0]['rawSql']
for field in score_fields:
    if f'AS "{field}"' not in source_sql:
        raise SystemExit(f'综合评分数据源缺少字段 {field}')

shared_cards = {
    2: '效率分',
    3: '平稳分',
    4: '速度分',
    5: '回收分',
    8: '驾驶风格',
}
for panel_id, field in shared_cards.items():
    panel = panels[panel_id]
    expected_ds = {'type': 'datasource', 'uid': '-- Dashboard --'}
    if panel.get('datasource') != expected_ds:
        raise SystemExit(f'panel {panel_id} 未使用 Dashboard 共享数据源')
    targets = panel.get('targets', [])
    if len(targets) != 1:
        raise SystemExit(f'panel {panel_id} 共享 target 数量不是 1')
    target = targets[0]
    if target.get('datasource') != expected_ds or target.get('panelId') != 1:
        raise SystemExit(f'panel {panel_id} 未引用 panel 1 原始结果')
    if target.get('rawSql'):
        raise SystemExit(f'panel {panel_id} 不应再携带独立 SQL')
    transformations = panel.get('transformations') or []
    names = []
    for transform in transformations:
        if transform.get('id') == 'filterFieldsByName':
            names.extend(transform.get('options', {}).get('include', {}).get('names', []))
    if names != [field]:
        raise SystemExit(f'panel {panel_id} 没有唯一筛选共享字段 {field!r}: {names!r}')

trend = panels[6]
trend_targets = trend.get('targets', [])
if len(trend_targets) != 1 or not trend_targets[0].get('rawSql'):
    raise SystemExit('综合评分趋势必须合并为一条 PostgreSQL 查询')
trend_sql = trend_targets[0]['rawSql']
for field in ('综合评分', '平稳分', '速度分', '效率分', '回收分'):
    if f'AS "{field}"' not in trend_sql:
        raise SystemExit(f'趋势查询缺少字段 {field}')

heavy = []
for panel in dashboard['panels']:
    for target in panel.get('targets') or []:
        sql = target.get('rawSql', '')
        if 'FROM positions' in sql:
            heavy.append((panel.get('id'), panel.get('title'), target.get('refId'), sql))
if len(heavy) != 3:
    summary = ', '.join(f'{pid}/{title}/{ref}' for pid, title, ref, _ in heavy)
    raise SystemExit(f'扫描 positions 的评分查询必须恰好 3 条，实际 {len(heavy)}: {summary}')

for panel_id, title, ref_id, sql in heavy:
    required = (
        'p.car_id = $car_id',
        "p.date BETWEEN ($__timeFrom()::timestamp - interval '1 day')",
        "AND ($__timeTo()::timestamp + interval '1 day')",
    )
    for token in required:
        if token not in sql:
            raise SystemExit(f'{panel_id}/{title}/{ref_id} 缺少有界 positions 扫描: {token}')

print('✅ 驾驶评分共享查询与有界扫描契约通过')
PY
