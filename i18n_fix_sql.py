#!/usr/bin/env python3
"""
修复SQL查询中的错误翻译
SQL查询应该保持英文，只有显示文本应该被翻译
"""

import json
import os
import re

BASE_PATH = "grafana/dashboards/zh-cn"

# SQL中不应该被翻译的模式
SQL_PATTERNS = [
    (r'as "[^"]*[^\x00-\x7F][^"]*"', 'SQL列别名'),  # 包含中文的列别名
]

def fix_sql_in_file(filepath):
    """修复文件中的SQL查询"""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 检查是否包含中文SQL
    has_chinese_sql = False
    if 'rawSql' in content or 'sql' in content:
        # 简单检查：SQL语句中包含中文
        sql_matches = re.findall(r'"rawSql":\s*"([^"]*[\u4e00-\u9fa5][^"]*)"', content)
        if sql_matches:
            has_chinese_sql = True
            print(f"  ⚠️  发现中文SQL: {filepath}")
            for match in sql_matches[:2]:  # 只显示前2个
                print(f"      {match[:60]}...")
    
    return has_chinese_sql

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("检查SQL查询中的错误翻译")
    print("="*80)
    
    problematic_files = []
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        if fix_sql_in_file(filepath):
            problematic_files.append(filename)
    
    if problematic_files:
        print(f"\n发现 {len(problematic_files)} 个文件可能包含错误翻译的SQL")
        print("建议: 手动检查这些文件，恢复SQL中的英文")
    else:
        print("\n✅ 未发现明显的SQL翻译错误")

if __name__ == "__main__":
    main()
