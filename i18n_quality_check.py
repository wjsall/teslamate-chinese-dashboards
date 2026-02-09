#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化质量检查
检查是否有不该翻译的内容被翻译了
"""

import json
import os
import re

BASE_PATH = "grafana/dashboards/zh-cn"

# 不应该翻译的内容（需要保持英文的）
SHOULD_KEEP_ENGLISH = [
    # SQL关键字
    r'\bSELECT\b', r'\bFROM\b', r'\bWHERE\b', r'\bAND\b', r'\bOR\b',
    r'\bGROUP BY\b', r'\bORDER BY\b', r'\bLIMIT\b', r'\bJOIN\b',
    # 技术术语
    r'\bSQL\b', r'\bPostgreSQL\b', r'\bJSON\b', r'\bAPI\b',
    r'\bURL\b', r'\bHTTP\b', r'\bHTTPS\b',
    # 变量名（不应该出现在翻译后的文本中）
    r'\$\w+',  # 如 $car_id
    # Grafana 特定术语
    r'\bAnnotations\b.*\bAlerts\b',  # 这个应该翻译
]

# 检查是否有翻译错误
def check_translation_quality(filepath):
    """检查单个文件的翻译质量"""
    issues = []
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
        data = json.load(open(filepath, 'r', encoding='utf-8'))
    
    def check_value(obj, path=""):
        if isinstance(obj, dict):
            for key, value in obj.items():
                new_path = f"{path}.{key}" if path else key
                
                if isinstance(value, str):
                    # 检查是否翻译了不该翻译的内容
                    if key in ['name', 'uid', 'datasource', 'type']:
                        # 这些字段不应该被翻译
                        if any('\u4e00' <= c <= '\u9fff' for c in value):
                            issues.append((filepath, new_path, f"字段 {key} 不应该包含中文", value))
                    
                    # 检查 SQL 查询是否被翻译
                    if key in ['rawSql', 'sql', 'query']:
                        if any('\u4e00' <= c <= '\u9fff' for c in value):
                            issues.append((filepath, new_path, "SQL 查询不应该被翻译", value[:50]))
                
                elif isinstance(value, (dict, list)):
                    check_value(value, new_path)
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                check_value(item, f"{path}[{i}]")
    
    check_value(data)
    return issues

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("汉化质量检查报告")
    print("="*80)
    
    all_issues = []
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        issues = check_translation_quality(filepath)
        all_issues.extend(issues)
        
        if issues:
            print(f"\n⚠️  {filename}")
            for file, path, reason, value in issues[:3]:  # 只显示前3个
                print(f"   问题: {reason}")
                print(f"   位置: {path}")
                print(f"   内容: {value[:50]}...")
    
    if all_issues:
        print(f"\n" + "="*80)
        print(f"发现 {len(all_issues)} 处潜在问题")
        print("="*80)
    else:
        print(f"\n" + "="*80)
        print("✅ 质量检查通过！未发现明显问题")
        print("="*80)
    
    # 统计翻译情况
    print("\n📊 翻译内容统计")
    print("-"*80)
    
    total_titles = 0
    total_descriptions = 0
    chinese_titles = 0
    chinese_descriptions = 0
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        def count_fields(obj):
            nonlocal total_titles, total_descriptions, chinese_titles, chinese_descriptions
            if isinstance(obj, dict):
                for key, value in obj.items():
                    if isinstance(value, str):
                        has_chinese = any('\u4e00' <= c <= '\u9fff' for c in value)
                        if key == 'title':
                            total_titles += 1
                            if has_chinese:
                                chinese_titles += 1
                        elif key == 'description':
                            total_descriptions += 1
                            if has_chinese:
                                chinese_descriptions += 1
                    elif isinstance(value, (dict, list)):
                        count_fields(value)
            elif isinstance(obj, list):
                for item in obj:
                    count_fields(item)
        
        count_fields(data)
    
    print(f"面板标题: {chinese_titles}/{total_titles} ({chinese_titles/total_titles*100:.1f}% 已汉化)")
    print(f"面板描述: {chinese_descriptions}/{total_descriptions} ({chinese_descriptions/total_descriptions*100:.1f}% 已汉化)")

if __name__ == "__main__":
    main()
