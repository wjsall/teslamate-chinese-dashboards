#!/usr/bin/env python3
"""
全面自动检查 - 找出所有遗漏的英文
"""

import json
import os
import re

BASE_PATH = "grafana/dashboards/zh-cn"

# 应该保留的英文（技术字段、单位、人名等）
KEEP_ENGLISH = [
    'car_id', 'date', 'time', 'latitude', 'longitude', 'speed', 'power',
    'odometer', 'battery_level', 'usable_battery_level', 'charger_power',
    'charge_energy_added', 'charge_energy_used', 'rated_range', 'ideal_range',
    'efficiency', 'voltage', 'current', 'frequency', 'phases', 'cost',
    'start_date', 'end_date', 'duration', 'distance', 'position_id',
    'outside_temp', 'inside_temp', 'tire_pressure', 'is_climate_on',
    'locked', 'sentry_mode', 'windows_open', 'doors_open', 'trunk_open',
    'frunk_open', 'software_version', 'update_available', 'version',
    'bar', 'km', 'mi', 'kWh', 'kW', 'A', 'V', 'Hz', 'psi', 'kPa',
    '°C', '°F', 'km/h', 'mph', 'Wh', 'Wh/km', 'Wh/mi', '%',
    'min', 'h', 'd', 'y', 'true', 'false', 'null', 'yes', 'no',
    'online', 'offline', 'asleep', 'driving', 'charging', 'parking',
    'unknown', 'missing', 'N/A', 'Jo-El', 'total', 'avg', 'max', 'min',
    'mean', 'sum', 'count', 'stddev', 'variance', 'percentile',
    'row_number', 'rank', 'lag', 'lead', 'first_value', 'last_value',
    'date_trunc', 'date_bin', 'timezone', 'extract', 'to_timestamp',
    'now', 'current_timestamp', 'interval', 'asc', 'desc', 'nulls',
    'first', 'last', 'over', 'partition', 'by', 'order', 'range',
    'between', 'preceding', 'following', 'unbounded', 'current', 'row',
    'mode', 'within', 'group', 'greatest', 'least', 'coalesce', 'nullif',
    'case', 'when', 'then', 'else', 'end', 'and', 'or', 'not', 'is',
    'in', 'any', 'all', 'some', 'exists', 'distinct', 'from', 'where',
    'having', 'limit', 'offset', 'union', 'intersect', 'except',
    'inner', 'outer', 'left', 'right', 'full', 'join', 'on', 'using',
    'natural', 'cross', 'lateral', 'as', 'with', 'recursive', 'values',
    'insert', 'update', 'delete', 'select', 'create', 'drop', 'alter',
    'table', 'view', 'index', 'trigger', 'function', 'procedure',
    'database', 'schema', 'sequence', 'user', 'role', 'grant', 'revoke',
    'commit', 'rollback', 'savepoint', 'transaction', 'isolation',
    'level', 'read', 'write', 'only', 'deferrable', 'immediate',
    'initially', 'constraint', 'primary', 'key', 'foreign', 'references',
    'unique', 'check', 'default', 'not', 'null', 'auto_increment',
    'serial', 'bigserial', 'uuid', 'varchar', 'char', 'text', 'bytea',
    'integer', 'bigint', 'smallint', 'decimal', 'numeric', 'real',
    'double', 'precision', 'float', 'boolean', 'date', 'time',
    'timestamp', 'timestamptz', 'interval', 'json', 'jsonb', 'array',
    'enum', 'range', 'domain', 'composite', 'type', 'cast', 'convert',
    'encode', 'decode', 'encrypt', 'decrypt', 'sign', 'verify',
    'compress', 'decompress', 'hash', 'uuid_generate_v4', 'gen_random_uuid',
]

def is_keep_english(text):
    """判断是否应该保留英文"""
    text_lower = text.lower().strip()
    
    # 纯技术字段
    if text_lower in [k.lower() for k in KEEP_ENGLISH]:
        return True
    
    # 变量名格式（下划线连接）
    if re.match(r'^[a-z_][a-z0-9_]*$', text_lower):
        return True
    
    # SQL关键字
    if text_lower in ['select', 'from', 'where', 'and', 'or', 'as', 'group', 'order', 'by', 'having', 'limit']:
        return True
    
    # 变量占位符
    if text.startswith('$') or text.startswith('${') or text.startswith('__'):
        return True
    
    # URL
    if text.startswith('http://') or text.startswith('https://'):
        return True
    
    # 邮箱
    if '@' in text:
        return True
    
    # 纯数字
    if text.replace('.', '').replace('-', '').replace('+', '').isdigit():
        return True
    
    # 时间格式
    if re.match(r'^\d{4}-\d{2}-\d{2}', text):
        return True
    
    return False

def find_all_english(data, path='', results=None):
    """递归查找所有英文内容"""
    if results is None:
        results = []
    
    if isinstance(data, dict):
        for key, value in data.items():
            new_path = f'{path}.{key}' if path else key
            
            # 检查字符串值
            if isinstance(value, str):
                # 只检查UI相关字段
                ui_fields = ['title', 'description', 'label', 'text', 'displayName', 
                            'custom', 'name', 'header', 'footer', 'placeholder',
                            'tooltip', 'hint', 'message', 'alert', 'error']
                
                if key in ui_fields or 'name' in key.lower() or 'label' in key.lower():
                    if len(value) > 1 and not is_keep_english(value):
                        # 检查是否包含英文
                        has_english = any(c.isalpha() and ord(c) < 128 for c in value)
                        has_chinese = any('\u4e00' <= c <= '\u9fff' for c in value)
                        
                        # 如果纯英文或英文为主
                        if has_english and not has_chinese:
                            results.append((new_path, value))
                        elif has_english and has_chinese:
                            # 混合内容，检查英文比例
                            english_chars = sum(1 for c in value if c.isalpha() and ord(c) < 128)
                            chinese_chars = sum(1 for c in value if '\u4e00' <= c <= '\u9fff')
                            if english_chars > chinese_chars:
                                results.append((new_path, value))
            
            elif isinstance(value, (dict, list)):
                find_all_english(value, new_path, results)
    
    elif isinstance(data, list):
        for i, item in enumerate(data):
            find_all_english(item, f'{path}[{i}]', results)
    
    return results

def main():
    files = sorted([f for f in os.listdir(BASE_PATH) if f.endswith('.json')])
    
    print("="*80)
    print("全面英文检查报告")
    print("="*80)
    
    all_findings = {}
    
    for filename in files:
        filepath = os.path.join(BASE_PATH, filename)
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        findings = find_all_english(data)
        if findings:
            all_findings[filename] = findings
    
    # 输出结果
    if not all_findings:
        print("\n✅ 未发现遗漏的英文UI内容！")
        return
    
    for filename, findings in sorted(all_findings.items()):
        print(f"\n📄 {filename} ({len(findings)}处)")
        for path, text in findings[:10]:  # 只显示前10个
            text_display = text[:60] + '...' if len(text) > 60 else text
            print(f"   [{path.split('.')[-1]}] {text_display}")
        if len(findings) > 10:
            print(f"   ... 还有 {len(findings)-10} 处 ...")
    
    total = sum(len(f) for f in all_findings.values())
    print(f"\n" + "="*80)
    print(f"总计: {len(all_findings)} 个文件, {total} 处英文需要翻译")
    print("="*80)

if __name__ == "__main__":
    main()
