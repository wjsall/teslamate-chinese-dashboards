#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化检查脚本
提取所有需要汉化的英文内容
"""

import json
import os
from collections import defaultdict

BASE_PATH = "grafana/dashboards/zh-cn"

def find_english_content(data, path="", results=None):
    """递归查找所有英文内容"""
    if results is None:
        results = defaultdict(list)
    
    if isinstance(data, dict):
        for key, value in data.items():
            new_path = f"{path}.{key}" if path else key
            
            # 检查特定字段
            if key in ['title', 'description', 'label', 'name', 'text'] and isinstance(value, str):
                # 判断是否包含英文字母（排除纯中文、变量、URL等）
                if contains_english(value) and not should_skip(value):
                    results[key].append((new_path, value))
            
            elif isinstance(value, (dict, list)):
                find_english_content(value, new_path, results)
    
    elif isinstance(data, list):
        for i, item in enumerate(data):
            find_english_content(item, f"{path}[{i}]", results)
    
    return results

def contains_english(s):
    """检查字符串是否包含英文字母"""
    return any(c.isalpha() and ord(c) < 128 for c in s)

def should_skip(s):
    """判断是否应跳过的内容"""
    # 跳过变量
    if s.startswith('$'):
        return True
    # 跳过 SQL 关键字
    if s.upper() in ['SQL', 'SELECT', 'FROM', 'WHERE', 'AND', 'OR']:
        return True
    # 跳过已翻译的中文
    if all('\u4e00' <= c <= '\u9fff' or c in ' ()[]{},.:-_0123456789$\\/\'"' for c in s):
        return True
    # 跳过 PostgreSQL
    if 'PostgreSQL' in s:
        return True
    return False

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    all_descriptions = []
    all_labels = []
    
    print("="*80)
    print("TeslaMate Dashboard 汉化检查报告")
    print("="*80)
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        results = find_english_content(data)
        
        # 收集描述
        if 'description' in results:
            for path, value in results['description']:
                all_descriptions.append((filename, path, value))
        
        # 收集标签
        if 'label' in results:
            for path, value in results['label']:
                all_labels.append((filename, path, value))
    
    # 输出描述统计
    print(f"\n📋 面板描述 (共 {len(all_descriptions)} 处)")
    print("-"*80)
    seen = set()
    for filename, path, value in all_descriptions[:10]:
        key = (filename, value[:50])
        if key not in seen:
            seen.add(key)
            print(f"\n文件: {filename}")
            print(f"内容: {value[:80]}{'...' if len(value) > 80 else ''}")
    if len(all_descriptions) > 10:
        print(f"\n... 还有 {len(all_descriptions) - 10} 处 ...")
    
    # 输出标签统计
    print(f"\n\n📋 筛选器标签 (共 {len(all_labels)} 处)")
    print("-"*80)
    unique_labels = sorted(set([v for _, _, v in all_labels]))
    for label in unique_labels[:15]:
        print(f"  • {label}")
    if len(unique_labels) > 15:
        print(f"  ... 还有 {len(unique_labels) - 15} 个 ...")
    
    print("\n" + "="*80)
    print(f"总计: {len(all_descriptions)} 处描述 + {len(all_labels)} 处标签")
    print("="*80)

if __name__ == "__main__":
    main()
