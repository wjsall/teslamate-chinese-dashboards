#!/usr/bin/env python3
"""
批量修复SQL中的中文翻译错误
"""

import json
import os
import re

BASE_PATH = "grafana/dashboards/zh-cn"

def fix_sql_chinese(filepath):
    """修复文件中的SQL中文"""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    original = content
    
    # 替换SQL中的中文列别名
    sql_replacements = [
        ('as "初始电量"', 'as "Start SoC"'),
        ('as "结束电量"', 'as "End SoC"'),
        ('as "充电量"', 'as "Added"'),
        ('AS "左前"', 'AS "FL"'),
        ('AS "右前"', 'AS "FR"'),
        ('AS "左后"', 'AS "RL"'),
        ('AS "右后"', 'AS "RR"'),
        ('AS "当前胎压"', 'AS "Current"'),
        ('AS "上次胎压"', 'AS "Last"'),
    ]
    
    for old, new in sql_replacements:
        content = content.replace(old, new)
    
    if content != original:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("批量修复SQL中的中文")
    print("="*80)
    
    fixed_files = []
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        if fix_sql_chinese(filepath):
            fixed_files.append(filename)
            print(f"  ✅ 修复: {filename}")
    
    print(f"\n共修复 {len(fixed_files)} 个文件")

if __name__ == "__main__":
    main()
