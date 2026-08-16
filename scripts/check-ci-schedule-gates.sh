#!/usr/bin/env bash
# CI schedule 契约门：定时触发必须运行关键只读验证，同时继续禁止构建或推送镜像。
# 纯静态检查 workflow 的 job 级 if 与 lint 命令，避免 cron 再次悄悄变成空壳。
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 <<'PY'
import re
import sys
from pathlib import Path

workflow_path = Path('.github/workflows/ghcr-build.yml')
text = workflow_path.read_text(encoding='utf-8')
lines = text.splitlines()

try:
    jobs_start = next(i for i, line in enumerate(lines) if line == 'jobs:')
except StopIteration:
    print('❌ workflow 缺少 jobs:')
    sys.exit(1)

job_starts = []
for i in range(jobs_start + 1, len(lines)):
    match = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', lines[i])
    if match:
        job_starts.append((match.group(1), i))

jobs = {}
for pos, (name, start) in enumerate(job_starts):
    end = job_starts[pos + 1][1] if pos + 1 < len(job_starts) else len(lines)
    jobs[name] = '\n'.join(lines[start:end])


def job_if(name):
    block = jobs.get(name)
    if block is None:
        return None
    block_lines = block.splitlines()
    for i, line in enumerate(block_lines):
        match = re.match(r'^    if:\s*(.*)$', line)
        if not match:
            continue
        parts = [match.group(1)]
        for following in block_lines[i + 1:]:
            if re.match(r'^    [A-Za-z0-9_-]+:', following):
                break
            if following.startswith('      '):
                parts.append(following.strip())
        return ' '.join(parts)
    return ''


failures = []

if not re.search(r'^  schedule:\s*$', '\n'.join(lines[:jobs_start]), re.M):
    failures.append('workflow 没有 schedule 触发器')

readonly_jobs = ('lint', 'tou-behavior', 'dashboard-sql')
for name in readonly_jobs:
    condition = job_if(name)
    if condition is None:
        failures.append(f'缺少只读 job: {name}')
    elif "github.event_name != 'schedule'" in condition:
        failures.append(f'{name} 仍在 schedule 时跳过')

image_jobs = (
    'build-candidate',
    'smoke-fresh-install',
    'smoke-upgrade-from-old',
    'smoke-migrate-official',
    'smoke-manual-compose-degraded',
    'smoke-plugin-volume-shadow',
    'publish',
)
for name in image_jobs:
    condition = job_if(name)
    if condition is None:
        failures.append(f'缺少镜像 job: {name}')
    elif "github.event_name != 'schedule'" not in condition:
        failures.append(f'{name} 缺少 schedule 禁止构建/发布守卫')

lint_block = jobs.get('lint', '')
for command in (
    'bash scripts/check-upstream-alter-compat.sh',
    # 上游升级端到端：起 postgres → 老版 TeslaMate 迁移 → 装上一个发行版的 SQL →
    # 装当前版本 → 新版 TeslaMate 迁移。逐列 ALTER 那道门是模拟，这道是真跑；
    # 两道都要在，少一道就会重演「只测全新安装、升级路径全盲」。
    'bash scripts/check-upstream-migration-e2e.sh',
    # 升级结尾横幅：真跑一遍 upgrade.sh，断言「旧对账视图删不掉」不会以绿色收场。
    # 那个缺陷不在任何单独一行里，而在「echo 提示的地方」和「结尾判分支的地方」之间的
    # 连线上，静态 grep 抓不到，必须整段跑。
    'bash scripts/check-upgrade-warn-banner.sh',
    # 另外两条安装路径（simple-deploy.sh / migrate-from-official.sh）是 curl | bash
    # 单文件脚本，整段跑不了；这道门把它们的结尾横幅代码块抽出来接真库跑。
    # 少了它，那两个脚本的横幅只剩语法门——把 -eq 0 改成 -ge 0 这种"中和"型回归
    # （变量还在、静态契约照样绿）就会一路溜进发布。
    'bash scripts/check-install-banner-behavior.sh',
    'bash scripts/check-ci-schedule-gates.sh',
):
    if command not in lint_block:
        failures.append(f'lint 没有执行 {command}')

required_comment = 'schedule 跑只读门，不构建/不推送镜像'
if required_comment not in text:
    failures.append(f'workflow 缺少说明：{required_comment}')

upgrade_block = jobs.get('smoke-upgrade-from-old', '')
fixture_match = re.search(
    r'INSERT INTO cars\s*\((?P<columns>[^)]*)\)\s*'
    r'SELECT\s+(?P<values>.*?)\s+FROM\s+s;',
    upgrade_block,
    re.S,
)
if fixture_match is None:
    failures.append('旧版升级缺少合成车辆夹具')
else:
    columns = [column.strip() for column in fixture_match.group('columns').split(',')]
    values = [value.strip() for value in fixture_match.group('values').split(',')]
    if len(columns) != len(values):
        failures.append('旧版升级合成车辆夹具的列和值数量不一致')
    elif 'vin' not in columns:
        failures.append('旧版升级合成车辆夹具缺少 VIN')
    else:
        vin_value = values[columns.index('vin')]
        vin_match = re.fullmatch(r"'([A-Z0-9]{17})'", vin_value)
        if vin_match is None or not vin_match.group(1).startswith('TESTVIN'):
            failures.append('旧版升级合成车辆夹具必须使用明显的 17 位测试 VIN')

if failures:
    print('❌ CI schedule 契约失败：')
    for failure in failures:
        print(f'  - {failure}')
    sys.exit(1)

print('✅ CI schedule 契约通过：lint / TOU / dashboard SQL 定时运行；镜像 job 定时禁用')
PY
