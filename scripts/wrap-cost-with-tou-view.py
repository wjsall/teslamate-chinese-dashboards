#!/usr/bin/env python3
"""
把所有引用 charging_processes 的仪表盘 SQL 里的 cost 包成 effective_cost(<id>, <cost>)，
让 cost 字段自动按分时电价 显示（没装分时电价 的用户透明回退原 cost）。

不改 FROM 子句（保留原表，避免 PG 视图破坏 PK 函数依赖导致 GROUP BY 失效）。

改写规则（按 SQL 分析后逐处替换）：
  1. <alias>.cost  →  effective_cost(<alias>.id, <alias>.cost)
     仅当 <alias> 是 charging_processes 的别名时
  2. 裸 cost      →  effective_cost(id, cost)
     仅当 SQL 里 charging_processes 没用别名（FROM charging_processes WHERE...）
  3. cost_per_kwh / cost_mileage / cost_savings 等扩展列名不动（用 \\b 保护）
  4. WHERE cost IS NULL / cost = 0 等过滤上下文不动（cost 仅在表达式/SELECT/聚合里替换）

回滚：跑 --revert，会把 effective_cost(...) 还原成原 cost 引用。

跑：
  python3 scripts/wrap-cost-with-tou-view.py --dry-run     # 预览
  python3 scripts/wrap-cost-with-tou-view.py --apply       # 应用
  python3 scripts/wrap-cost-with-tou-view.py --revert      # 回滚
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DASHBOARDS = REPO_ROOT / "grafana" / "dashboards" / "zh-cn"

SKIP_FILES = {"tou-config.json"}


def detect_format(text: str):
    return 2 if text.lstrip().startswith("{\n") else None


def find_charging_processes_aliases(sql: str) -> set:
    """找出 charging_processes 表的所有别名"""
    aliases = set()
    # FROM charging_processes [AS] alias
    for m in re.finditer(r'\bcharging_processes\s+(?:AS\s+)?([a-zA-Z_]\w*)\b(?!_)',
                         sql, re.IGNORECASE):
        alias = m.group(1)
        # 跳过 SQL 关键字
        if alias.upper() not in {'WHERE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'ON',
                                 'GROUP', 'ORDER', 'LIMIT', 'HAVING', 'UNION'}:
            aliases.add(alias)
    return aliases


def split_scopes(sql: str):
    """按子查询/CTE 边界切分 SQL。
    函数调用 sum(...)/coalesce(...) 等普通括号透明不拆，
    只有 (SELECT ...) / (WITH ...) / (VALUES ...) 这种子查询括号才作为 scope 边界。
    返回 [(piece_text, start_offset)]。"""
    pieces = []
    paren_kind = []  # 栈：'sub' 子查询括号 / 'func' 普通括号
    start = 0
    for i, c in enumerate(sql):
        if c == '(':
            ahead = sql[i + 1:i + 30].lstrip()
            is_subquery = bool(re.match(r'(SELECT|WITH|VALUES)\b', ahead, re.IGNORECASE))
            if is_subquery:
                pieces.append((sql[start:i], start))
                start = i + 1
                paren_kind.append('sub')
            else:
                paren_kind.append('func')
        elif c == ')':
            if paren_kind:
                kind = paren_kind.pop()
                if kind == 'sub':
                    pieces.append((sql[start:i], start))
                    start = i + 1
    if start < len(sql):
        pieces.append((sql[start:], start))
    return pieces


def wrap_in_scope(piece: str) -> tuple:
    """对单个 scope 内的 SQL 做 cost 替换。返回 (新 piece, 修改数)。
    仅当此 scope 含 FROM charging_processes 时才动手。"""
    if not re.search(r'\bFROM\s+charging_processes\b', piece, re.IGNORECASE):
        return piece, 0

    aliases = find_charging_processes_aliases(piece)
    has_unaliased = bool(re.search(
        r'\bFROM\s+charging_processes\s+(WHERE|GROUP|ORDER|LIMIT|HAVING|UNION|;|$)',
        piece, re.IGNORECASE | re.MULTILINE
    ))

    counter = [0]

    # 先把已经包过的 effective_cost(...) 段藏起来，避免重复包装
    marker = '\x00EC{}\x00'
    wrapped_re = re.compile(r'effective_cost\([^)]*\)(?:\s+AS\s+cost)?', re.IGNORECASE)
    wrapped_segments = wrapped_re.findall(piece)
    new = piece
    for idx, seg in enumerate(wrapped_segments):
        new = new.replace(seg, marker.format(idx), 1)

    def make_repl(alias_or_none):
        def repl(m):
            counter[0] += 1
            tail = new[m.end():m.end() + 80]
            id_ref = f'{alias_or_none}.id' if alias_or_none else 'id'
            cost_ref = f'{alias_or_none}.cost' if alias_or_none else 'cost'
            wrapped = f'effective_cost({id_ref}, {cost_ref})'
            if re.match(r'\s*,', tail):
                return wrapped + ' AS cost'
            if re.match(r'\s*\n\s*(FROM|WHERE|GROUP|ORDER|HAVING|LIMIT)', tail, re.IGNORECASE):
                return wrapped + ' AS cost'
            return wrapped
        return repl

    # <alias>.cost
    for alias in aliases:
        pattern = rf'\b{re.escape(alias)}\.cost\b(?!_)'
        new = re.sub(pattern, make_repl(alias), new)

    # 裸 cost
    if has_unaliased:
        new = re.sub(r'(?<![.\w])cost\b(?!_)', make_repl(None), new)

    # 还原已包段
    for idx, seg in enumerate(wrapped_segments):
        new = new.replace(marker.format(idx), seg, 1)

    n = counter[0]
    return new, n


def transform_sql(sql: str) -> tuple:
    """返回 (新 SQL, 修改数)。按 scope 切分后逐块处理，避免 CTE 外层引用 CTE 列名时被误改。"""
    if 'charging_processes' not in sql:
        return sql, 0

    pieces = split_scopes(sql)
    out_parts = []
    total = 0
    last_end = 0
    for text, start in pieces:
        # 把括号原文也保留：start 之前的字符是上一片之后的括号
        if start > last_end:
            out_parts.append(sql[last_end:start])
        new_piece, k = wrap_in_scope(text)
        out_parts.append(new_piece)
        total += k
        last_end = start + len(text)
    if last_end < len(sql):
        out_parts.append(sql[last_end:])
    return ''.join(out_parts), total


def revert_sql(sql: str) -> tuple:
    """把 effective_cost(<x>.id, <x>.cost) [AS cost] 还原回 <x>.cost"""
    n = 0
    # effective_cost(alias.id, alias.cost) AS cost → alias.cost
    new, k = re.subn(
        r'effective_cost\(\s*([a-zA-Z_]\w*)\.id\s*,\s*\1\.cost\s*\)\s+AS\s+cost',
        r'\1.cost', sql, flags=re.IGNORECASE)
    n += k
    # effective_cost(alias.id, alias.cost) → alias.cost
    new, k = re.subn(r'effective_cost\(\s*([a-zA-Z_]\w*)\.id\s*,\s*\1\.cost\s*\)',
                     r'\1.cost', new)
    n += k
    # effective_cost(id, cost) AS cost → cost
    new, k = re.subn(r'effective_cost\(\s*id\s*,\s*cost\s*\)\s+AS\s+cost',
                     'cost', new, flags=re.IGNORECASE)
    n += k
    # effective_cost(id, cost) → cost
    new, k = re.subn(r'effective_cost\(\s*id\s*,\s*cost\s*\)', 'cost', new)
    n += k
    return new, n


def process_dashboard(path: Path, apply: bool, revert: bool) -> dict:
    text = path.read_text()
    indent = detect_format(text)
    d = json.loads(text)

    file_changes = []
    total = 0
    for p in d.get('panels', []):
        for t in p.get('targets', []):
            sql = t.get('rawSql', '')
            if not sql:
                continue
            if revert:
                new_sql, k = revert_sql(sql)
            else:
                new_sql, k = transform_sql(sql)
            if k > 0:
                file_changes.append({
                    "panel_id": p.get('id'),
                    "ref_id": t.get('refId'),
                    "title": p.get('title', '')[:30],
                    "changes": k,
                })
                total += k
                if apply or revert:
                    t['rawSql'] = new_sql

    if (apply or revert) and total > 0:
        if indent is None:
            out = json.dumps(d, ensure_ascii=False, separators=(",", ":"))
        else:
            out = json.dumps(d, ensure_ascii=False, indent=indent)
            if text.endswith('\n'):
                out += '\n'
        path.write_text(out)

    return {"file": path.name, "total_changes": total, "panels": file_changes}


def main():
    ap = argparse.ArgumentParser()
    grp = ap.add_mutually_exclusive_group(required=True)
    grp.add_argument('--dry-run', action='store_true')
    grp.add_argument('--apply', action='store_true')
    grp.add_argument('--revert', action='store_true')
    ap.add_argument('--only')
    args = ap.parse_args()

    apply = args.apply
    revert = args.revert

    files = sorted(DASHBOARDS.glob('*.json'))
    files = [f for f in files if f.name not in SKIP_FILES]
    if args.only:
        files = [f for f in files if f.name == args.only]
        if not files:
            print(f"找不到 {args.only}")
            sys.exit(1)

    grand_total = 0
    files_with_changes = 0
    for f in files:
        r = process_dashboard(f, apply, revert)
        if r["total_changes"] > 0:
            files_with_changes += 1
            grand_total += r["total_changes"]
            print(f"\n{r['file']}: {r['total_changes']} 处")
            for p in r['panels']:
                print(f"  panel {p['panel_id']:>3} ref={p['ref_id']:<2} ({p['title']}): {p['changes']} 处")

    print()
    action = "已撤回" if revert else ("已应用" if apply else "[预览] 待应用")
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"  {action}: {grand_total} 处改动 / {files_with_changes} 个文件")
    print(f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if not (apply or revert):
        print("\n确认 OK 后跑: python3 scripts/wrap-cost-with-tou-view.py --apply")


if __name__ == '__main__':
    main()
