#!/usr/bin/env python3
"""
TeslaMate Dashboard 汉化 - 严格质量检查规则 v3.0
只检查UI文本，完全排除技术内容
"""

import json
import os
import re
from collections import defaultdict

BASE_PATH = "grafana/dashboards/zh-cn"

# ========== 严格规则定义 ==========

# 绝对不允许翻译的字段（技术内容）
FORBIDDEN_FIELDS = {
    # SQL相关
    'rawSql', 'sql', 'query', 
    # 数据源
    'datasource', 'uid', 'type',
    # 变量和配置
    'name',  # 变量名保持英文
    'expr', 'legendFormat',
    # JSON结构
    'id', 'refId', 'panelId',
    # 插件类型
    '__requires', 'pluginId',
}

# 只允许翻译的UI字段
ALLOWED_UI_FIELDS = {
    'title',        # 面板标题
    'description',  # 面板描述
    'label',        # 筛选器标签
    'text',         # 文本内容
    'custom',       # 自定义文本
}

# 技术术语保持英文
TECH_TERMS = [
    'PostgreSQL', 'SQL', 'JSON', 'API', 'URL', 'HTTP', 'HTTPS',
    'Grafana', 'TeslaMate', 'Docker', 'GitHub',
]

def strict_check(filepath):
    """严格检查单个文件"""
    issues = []
    safe_translations = []
    
    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    def check_node(obj, path=""):
        if isinstance(obj, dict):
            for key, value in obj.items():
                new_path = f"{path}.{key}" if path else key
                
                if isinstance(value, str):
                    has_chinese = any('\u4e00' <= c <= '\u9fff' for c in value)
                    
                    # 检查：技术字段被翻译（严重错误）
                    if key in FORBIDDEN_FIELDS and has_chinese:
                        # 特殊情况：description字段允许中文
                        if key == 'description':
                            safe_translations.append((filepath, new_path, value[:50]))
                        else:
                            issues.append({
                                'file': filepath,
                                'path': new_path,
                                'type': 'ERROR',
                                'message': f'技术字段 {key} 不应包含中文',
                                'value': value[:80]
                            })
                    
                    # 检查：SQL查询中的中文
                    if key in ['rawSql', 'sql'] and has_chinese:
                        issues.append({
                            'file': filepath,
                            'path': new_path,
                            'type': 'CRITICAL',
                            'message': 'SQL查询包含中文，必须回滚',
                            'value': value[:80]
                        })
                    
                    # 记录：安全的UI翻译
                    if key in ALLOWED_UI_FIELDS and has_chinese:
                        safe_translations.append((filepath, new_path, value[:50]))
                
                elif isinstance(value, (dict, list)):
                    check_node(value, new_path)
        
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                check_node(item, f"{path}[{i}]")
    
    check_node(data)
    return issues, safe_translations

def generate_report():
    """生成全面审查报告"""
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    all_issues = []
    all_safe = []
    
    print("="*80)
    print("TeslaMate 汉化全面审查报告 v3.0")
    print("="*80)
    print("\n审查标准：")
    print("- 技术字段( SQL/变量名/配置 )：必须保持英文")
    print("- UI字段( title/description/label )：可以翻译")
    print("="*80)
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        issues, safe = strict_check(filepath)
        all_issues.extend(issues)
        all_safe.extend(safe)
        
        if issues:
            print(f"\n❌ {filename}")
            for issue in issues[:3]:  # 只显示前3个
                print(f"   [{issue['type']}] {issue['message']}")
                print(f"   内容: {issue['value']}...")
    
    # 汇总
    critical = [i for i in all_issues if i['type'] == 'CRITICAL']
    errors = [i for i in all_issues if i['type'] == 'ERROR']
    
    print("\n" + "="*80)
    print("审查汇总")
    print("="*80)
    print(f"严重问题 (需回滚): {len(critical)} 处")
    print(f"一般错误: {len(errors)} 处")
    print(f"安全翻译: {len(all_safe)} 处")
    print(f"检查文件: {len(files)} 个")
    
    if critical:
        print("\n⚠️  发现严重问题，需要立即回滚SQL翻译！")
        for issue in critical[:5]:
            print(f"   - {issue['file']}: {issue['value'][:40]}...")
    
    return all_issues, all_safe

if __name__ == "__main__":
    issues, safe = generate_report()
    
    # 保存详细报告
    with open('i18n_audit_report.txt', 'w', encoding='utf-8') as f:
        f.write("="*80 + "\n")
        f.write("详细审查报告\n")
        f.write("="*80 + "\n\n")
        
        if issues:
            f.write("【需要修复的问题】\n")
            for issue in issues:
                f.write(f"\n文件: {issue['file']}\n")
                f.write(f"位置: {issue['path']}\n")
                f.write(f"类型: {issue['type']}\n")
                f.write(f"问题: {issue['message']}\n")
                f.write(f"内容: {issue['value']}\n")
        
        f.write(f"\n\n总计: {len(issues)} 处问题, {len(safe)} 处安全翻译")
    
    print("\n📄 详细报告已保存: i18n_audit_report.txt")
