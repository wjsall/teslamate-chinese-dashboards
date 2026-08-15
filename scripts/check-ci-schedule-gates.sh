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
    'bash scripts/check-ci-schedule-gates.sh',
):
    if command not in lint_block:
        failures.append(f'lint 没有执行 {command}')

required_comment = 'schedule 跑只读门，不构建/不推送镜像'
if required_comment not in text:
    failures.append(f'workflow 缺少说明：{required_comment}')

if failures:
    print('❌ CI schedule 契约失败：')
    for failure in failures:
        print(f'  - {failure}')
    sys.exit(1)

print('✅ CI schedule 契约通过：lint / TOU / dashboard SQL 定时运行；镜像 job 定时禁用')
PY
