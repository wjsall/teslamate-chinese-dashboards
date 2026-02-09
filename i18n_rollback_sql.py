#!/usr/bin/env python3
"""
回滚SQL翻译 - 只恢复技术字段，保留UI翻译
"""

import json
import os
import subprocess

BASE_PATH = "grafana/dashboards/zh-cn"

# 需要恢复英文的字段
SQL_FIELDS = ['rawSql', 'sql', 'query']
TECH_FIELDS = ['name', 'uid', 'datasource', 'type']

def get_original_value(filepath, field_path):
    """从Git历史获取原始值"""
    try:
        # 获取汉化前的版本 (15857ae 是第一次汉化提交之前)
        result = subprocess.run(
            ['git', 'show', '15857ae~1:' + filepath],
            capture_output=True,
            text=True,
            cwd='/tmp/teslamate-chinese-dashboards'
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            # 解析字段路径
            keys = field_path.split('.')
            for key in keys:
                if '[' in key:
                    # 处理数组索引
                    base_key, idx = key.split('[')
                    idx = int(idx.rstrip(']'))
                    data = data[base_key][idx]
                else:
                    data = data[key]
            return data
    except Exception as e:
        print(f"  ⚠️  无法获取原始值: {e}")
    return None

def rollback_sql_translations():
    """回滚所有SQL相关翻译"""
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("回滚SQL翻译")
    print("="*80)
    
    rollback_count = 0
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        
        with open(filepath, 'r', encoding='utf-8') as f:
            current_data = json.load(f)
        
        # 检查是否有SQL字段被修改
        has_sql_changes = False
        
        def check_and_rollback(obj, path=""):
            nonlocal has_sql_changes
            
            if isinstance(obj, dict):
                for key, value in obj.items():
                    new_path = f"{path}.{key}" if path else key
                    
                    # 如果是SQL字段且有中文，需要回滚
                    if key in SQL_FIELDS and isinstance(value, str):
                        if any('\u4e00' <= c <= '\u9fff' for c in value):
                            print(f"\n📄 {filename}")
                            print(f"   位置: {new_path}")
                            print(f"   当前: {value[:60]}...")
                            
                            # 尝试从Git恢复
                            original = get_original_value(filepath.replace(BASE_PATH + '/', ''), new_path)
                            if original:
                                obj[key] = original
                                print(f"   恢复: {original[:60]}...")
                                has_sql_changes = True
                                rollback_count += 1
                            else:
                                print(f"   ⚠️  无法自动恢复，需要手动处理")
                    
                    elif isinstance(value, (dict, list)):
                        check_and_rollback(value, new_path)
            
            elif isinstance(obj, list):
                for i, item in enumerate(obj):
                    check_and_rollback(item, f"{path}[{i}]")
        
        check_and_rollback(current_data)
        
        if has_sql_changes:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(current_data, f, ensure_ascii=False, indent=2)
            print(f"   ✅ 已保存")
    
    print(f"\n" + "="*80)
    print(f"共回滚 {rollback_count} 处SQL翻译")
    print("="*80)

if __name__ == "__main__":
    rollback_sql_translations()
