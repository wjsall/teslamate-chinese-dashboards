#!/usr/bin/env bash
# CI 强制门：三组兼容性 SQL（坐标转换 / 单位换算 / 分时电价）的「对象契约」变了，
# config/versions.env 的 SQL_COMPAT_REVISION 必须跟着 bump —— 否则拒绝合并。
#
# 背景（issue #33 同类教训）：SQL_COMPAT_REVISION 是 scripts/diagnose.sh 判断
# 「镜像要求的 SQL 版本」vs「数据库里实际装的版本」是否一致的唯一事实源（见
# config/versions.env 顶部注释）。这个数字目前完全靠人工记得改，迟早会像 #33 的
# LABEL version 一样滞后。
#
# 但绝不能拿"文件内容变了"当触发条件：install-tou.sql 42KB / 22 个函数，改注释、
# 改 RAISE NOTICE 文案很频繁，用文件 hash 会导致纯文案改动也强制 bump，把所有
# 方法 C 用户标成 DEGRADED，噪音化到用户学会无视——机制直接作废。
#
# 所以本脚本不比对文件内容，而是从三组 SQL 里解析出「对象契约」再比对：
#   TABLE     表名 + 列名 + 列类型（忽略 DEFAULT / CHECK / REFERENCES 等约束细节）
#   FUNCTION  函数名 + 参数名 + 参数类型 + 是否带 DEFAULT + 返回类型
#             （RETURNS TABLE(...) 按同样规则展开列出）
#   VIEW      视图名（列表由底层表 SELECT * 展开，不可靠地追踪，只认存在性）
#   TRIGGER   触发器名 + 挂载表 + 触发时机/事件 + WHEN 条件 + 关联函数名
#   INDEX     索引名 + UNIQUE 标记 + 挂载表 + 列/表达式列表
# 一律忽略：函数体（AS $$...$$ 之间的全部内容）、-- 行注释、/* */ 块注释、
# RAISE NOTICE/WARNING 文案、纯空白/换行差异、大小写。
#
# 用法：
#   bash scripts/check-sql-revision.sh                # 只读比对，CI 用
#   bash scripts/check-sql-revision.sh --update-baseline
#       # 把当前契约写入 scripts/sql-contract-baseline.txt。
#       # 仅当「契约无变化」或「契约变了且 SQL_COMPAT_REVISION 已相应 bump」时才允许写入；
#       # 契约变了但 revision 没变会拒绝更新（跟直接跑默认模式一样报错），
#       # 防止有人绕过检查、只重新生成基线而不真的 bump 版本号。
#
# 退出码：0 = 契约与基线一致（或 --update-baseline 成功写入）；1 = 有未经 revision
# 确认的契约变化，或 --update-baseline 被拒绝。
#
# 已知局限（诚实挂账，不假装覆盖）：
#   - 函数重载（同名不同参数类型）按「函数名」为 key，后出现的定义会覆盖前一个的
#     记录。当前三组 SQL 里没有任何函数重载，真出现时本脚本不会分别追踪两个重载，
#     只会看到"最后一次定义"的签名。
#   - 只精确解析本项目这三份 SQL 实际用到的语法子集（在下面 KNOWN LIMITATIONS
#     测试过的类型/写法），不是通用 SQL/PLpgSQL 解析器。新增 SQL 文件或引入未覆盖
#     的写法（如嵌套 $tag$ 字符串、CREATE TYPE、CREATE SCHEMA）时，务必先用
#     --update-baseline 生成一次基线并人工检查内容看起来是否合理。

set -e
cd "$(dirname "$0")/.."

python3 - "$@" <<'PYEOF'
import os
import re
import sys

SQL_FILES = [
    "sql/install-coord-functions.sql",
    "sql/install-unit-functions.sql",
    "sql/install-tou.sql",
]
BASELINE_PATH = "scripts/sql-contract-baseline.txt"
VERSIONS_ENV_PATH = "config/versions.env"
FORMAT_VERSION = 1


# ---------------------------------------------------------------------------
# 第一层：把源码「骨架化」——去掉注释、把函数体（dollar-quoted body）折叠成占位符，
# 但保留其中的换行数量（对报错行号定位没有硬需求，这里只是求稳，不影响正确性）。
# 骨架化之后，剩下的文本只含 CREATE TABLE/FUNCTION/VIEW/TRIGGER/INDEX 的「头部」，
# 后续所有正则/括号平衡扫描都在这份干净文本上做，不用再操心注释/函数体内容干扰。
# ---------------------------------------------------------------------------

_DOLLAR_TAG_RE = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$')


def skeletonize(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '$':
            m = _DOLLAR_TAG_RE.match(text, i)
            if m:
                tag = m.group(0)
                start_content = m.end()
                end_tag_idx = text.find(tag, start_content)
                if end_tag_idx == -1:
                    out.append(text[i:])
                    break
                inner = text[start_content:end_tag_idx]
                out.append(' $BODY$ ')
                out.append('\n' * inner.count('\n'))
                i = end_tag_idx + len(tag)
                continue
            out.append(c)
            i += 1
            continue
        if c == "'":
            j = i + 1
            closed = False
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    closed = True
                    break
                j += 1
            if not closed:
                j = n
            out.append(text[i:j])
            i = j
            continue
        if c == '-' and i + 1 < n and text[i + 1] == '-':
            j = text.find('\n', i)
            if j == -1:
                i = n
            else:
                out.append('\n')
                i = j + 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            if j == -1:
                i = n
            else:
                out.append('\n' * text[i:j + 2].count('\n'))
                i = j + 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def read_balanced(text, open_idx):
    """text[open_idx] must be '('. 返回 (括号内内容, 紧跟右括号之后的下标)。"""
    assert text[open_idx] == '('
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i + 1
        i += 1
    return text[open_idx + 1:], n  # 未闭合，兜底


def statement_upto_semicolon(text, start):
    """从 start 开始扫到 paren-depth==0 时的第一个分号（不含），用于取 CREATE TABLE /
    INDEX / TRIGGER / VIEW 这类没有 dollar-quoted body、用 ; 结尾的完整语句。"""
    depth = 0
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif c == ';' and depth == 0:
            return text[start:i]
        i += 1
    return text[start:]


def split_top_level(content):
    """按 paren-depth==0 的逗号切分，返回去掉首尾空白的非空片段列表。"""
    parts = []
    depth = 0
    current = []
    for c in content:
        if c == '(':
            depth += 1
            current.append(c)
        elif c == ')':
            depth -= 1
            current.append(c)
        elif c == ',' and depth == 0:
            parts.append(''.join(current))
            current = []
        else:
            current.append(c)
    if current:
        parts.append(''.join(current))
    return [p.strip() for p in parts if p.strip()]


def _normalize_type(s):
    s = s.upper()
    s = re.sub(r'\s*\(\s*', '(', s)
    s = re.sub(r'\s*,\s*', ',', s)
    s = re.sub(r'\s*\)\s*', ')', s)
    return s.strip()


_STOP_WORDS = {
    'DEFAULT', 'CHECK', 'REFERENCES', 'NOT', 'PRIMARY', 'UNIQUE',
    'CONSTRAINT', 'GENERATED', 'COLLATE',
}
_TABLE_CONSTRAINT_STARTERS = {'CONSTRAINT', 'CHECK', 'UNIQUE', 'PRIMARY', 'FOREIGN'}
_PARAM_MODES = {'IN', 'OUT', 'INOUT', 'VARIADIC'}


def parse_table_columns(content):
    """CREATE TABLE (...) 括号内内容 -> [(col_name, type_str), ...]，跳过表级约束条目。"""
    cols = []
    for entry in split_top_level(content):
        tokens = entry.split()
        if not tokens:
            continue
        if tokens[0].upper() in _TABLE_CONSTRAINT_STARTERS:
            continue
        name = tokens[0].lower()
        type_tokens = []
        for tok in tokens[1:]:
            bare = re.sub(r'[^A-Za-z0-9_]', '', tok).upper()
            if bare in _STOP_WORDS:
                break
            type_tokens.append(tok)
        cols.append((name, _normalize_type(' '.join(type_tokens))))
    return cols


def parse_param_entry(entry):
    """单个函数参数 / RETURNS TABLE 列条目 -> (name, mode, type_str, has_default) 或 None。"""
    tokens = entry.split()
    if not tokens:
        return None
    idx = 0
    mode = 'IN'
    if tokens[0].upper() in _PARAM_MODES:
        mode = tokens[0].upper()
        idx = 1
    if idx >= len(tokens):
        return None
    name = tokens[idx].lower()
    idx += 1
    type_tokens = []
    has_default = False
    for tok in tokens[idx:]:
        bare = re.sub(r'[^A-Za-z0-9_]', '', tok).upper()
        if bare == 'DEFAULT' or tok == ':=' or tok == '=':
            has_default = True
            break
        type_tokens.append(tok)
    return name, mode, _normalize_type(' '.join(type_tokens)), has_default


_RETURNS_HEAD_RE = re.compile(r'\s*RETURNS\s+(SETOF\s+)?', re.I)
_TABLE_KW_RE = re.compile(r'\s*TABLE\s*\(', re.I)
_TRIGGER_KW_RE = re.compile(r'\s*TRIGGER\b', re.I)
_SIMPLE_TYPE_RE = re.compile(
    r'\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?)', re.I
)
# PostgreSQL 里由多个关键字组成的内建类型名（词间可有任意空白）。只精确列出这三组 SQL
# 实际可能用到的几个，不追求覆盖全部 PostgreSQL 类型目录。
_MULTIWORD_TYPES = [
    'DOUBLE PRECISION',
    'CHARACTER VARYING',
    'TIMESTAMP WITHOUT TIME ZONE',
    'TIMESTAMP WITH TIME ZONE',
    'TIME WITHOUT TIME ZONE',
    'TIME WITH TIME ZONE',
    'BIT VARYING',
]
_MULTIWORD_TYPE_RES = [
    (phrase, re.compile(r'\s*' + r'\s+'.join(re.escape(w) for w in phrase.split()), re.I))
    for phrase in _MULTIWORD_TYPES
]


def _match_simple_return_type(text, pos):
    """匹配 RETURNS 子句里的基础类型名，优先识别多词内建类型（如 DOUBLE PRECISION），
    避免被单词版正则截断成 'DOUBLE'。返回 (归一化类型, 匹配结束下标) 或 (None, pos)。"""
    for phrase, pattern in _MULTIWORD_TYPE_RES:
        pm = pattern.match(text, pos)
        if pm:
            return phrase, pm.end()
    ms = _SIMPLE_TYPE_RE.match(text, pos)
    if ms:
        return _normalize_type(ms.group(1)), ms.end()
    return None, pos


def parse_returns(header_text, pos):
    """header_text[pos:] 起解析 RETURNS 子句 -> 归一化字符串（如 'INT'/'TRIGGER'/
    'TABLE(a:INT,b:TEXT)'），解析不出时返回 'UNKNOWN'。"""
    m = _RETURNS_HEAD_RE.match(header_text, pos)
    if not m:
        return 'UNKNOWN'
    setof = bool(m.group(1))
    p2 = m.end()
    if _TRIGGER_KW_RE.match(header_text, p2):
        return 'TRIGGER'
    mtab = _TABLE_KW_RE.match(header_text, p2)
    if mtab:
        open_idx = header_text.index('(', p2, mtab.end())
        content, _after = read_balanced(header_text, open_idx)
        cols = []
        for entry in split_top_level(content):
            parsed = parse_param_entry(entry)
            if parsed:
                cols.append(f'{parsed[0]}:{parsed[2]}')
        prefix = 'SETOF TABLE' if setof else 'TABLE'
        return f'{prefix}(' + ','.join(cols) + ')'
    t, _end = _match_simple_return_type(header_text, p2)
    if t is not None:
        return ('SETOF ' + t) if setof else t
    return 'UNKNOWN'


_TABLE_RE = re.compile(
    r'\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\(',
    re.I,
)
_FUNC_RE = re.compile(
    r'\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\(',
    re.I,
)
_VIEW_RE = re.compile(
    r'\bCREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?',
    re.I,
)
_TRIGGER_RE = re.compile(
    r'\bCREATE\s+TRIGGER\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?',
    re.I,
)
_INDEX_RE = re.compile(
    r'\bCREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?'
    r'(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s+ON\s+(?:ONLY\s+)?(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?',
    re.I,
)


def extract_from_file(path, current):
    """把 path 里的对象契约解析进 current 字典：key=(kind, name) -> (value, defined_in集合)。"""
    with open(path, encoding='utf-8') as f:
        raw = f.read()
    skel = skeletonize(raw)

    for m in _TABLE_RE.finditer(skel):
        name = m.group(1).lower()
        open_idx = m.end() - 1
        content, _after = read_balanced(skel, open_idx)
        cols = parse_table_columns(content)
        value = '(' + ','.join(f'{n}:{t}' for n, t in cols) + ')'
        _record(current, 'TABLE', name, value, path)

    for m in _FUNC_RE.finditer(skel):
        name = m.group(1).lower()
        open_idx = m.end() - 1
        params_content, after_params = read_balanced(skel, open_idx)
        params = [p for p in (parse_param_entry(e) for e in split_top_level(params_content)) if p]
        returns_repr = parse_returns(skel, after_params)
        sig_parts = []
        for pname, pmode, ptype, has_default in params:
            sig_parts.append(f'{pmode}:{pname}:{ptype}{"=D" if has_default else ""}')
        value = '(' + ','.join(sig_parts) + ') RETURNS ' + returns_repr
        _record(current, 'FUNCTION', name, value, path)

    for m in _VIEW_RE.finditer(skel):
        name = m.group(1).lower()
        _record(current, 'VIEW', name, 'EXISTS', path)

    for m in _TRIGGER_RE.finditer(skel):
        name = m.group(1).lower()
        stmt_rest = statement_upto_semicolon(skel, m.end())
        value = ' '.join(stmt_rest.split()).upper()
        _record(current, 'TRIGGER', name, value, path)

    for m in _INDEX_RE.finditer(skel):
        unique = bool(m.group(1))
        name = m.group(2).lower()
        table = m.group(3).lower()
        stmt = statement_upto_semicolon(skel, m.start())
        # 找 "ON table" 之后的第一个 '(' 作为列/表达式列表起点
        rest = stmt[m.end() - m.start():]
        paren_pos_in_rest = rest.find('(')
        if paren_pos_in_rest == -1:
            cols_norm = 'UNKNOWN'
        else:
            abs_pos = m.end() + paren_pos_in_rest
            content, _after = read_balanced(skel, abs_pos)
            cols_norm = _normalize_type(content)
        prefix = 'UNIQUE ' if unique else ''
        value = f'{prefix}ON {table}({cols_norm})'
        _record(current, 'INDEX', name, value, path)


def _record(current, kind, name, value, path):
    key = (kind, name)
    current[key] = value  # 同名后定义覆盖前一个，等价于 psql 顺序执行后的最终状态
    current.setdefault('__defined_in__', {}).setdefault(key, set()).add(path)


def extract_contract(files):
    current = {'__defined_in__': {}}
    for path in files:
        extract_from_file(path, current)
    defined_in = current.pop('__defined_in__')
    return current, defined_in


# ---------------------------------------------------------------------------
# 基线文件读写
# ---------------------------------------------------------------------------

def read_current_revision():
    if not os.path.exists(VERSIONS_ENV_PATH):
        print(f"找不到 {VERSIONS_ENV_PATH}", file=sys.stderr)
        sys.exit(2)
    with open(VERSIONS_ENV_PATH, encoding='utf-8') as f:
        content = f.read()
    m = re.search(r'^SQL_COMPAT_REVISION=(.+)$', content, re.M)
    if not m:
        print(f"无法从 {VERSIONS_ENV_PATH} 读取 SQL_COMPAT_REVISION", file=sys.stderr)
        sys.exit(2)
    return m.group(1).strip()


def load_baseline():
    """返回 (contract_dict, recorded_revision) 或 (None, None) 若文件不存在。"""
    if not os.path.exists(BASELINE_PATH):
        return None, None
    contract = {}
    recorded_rev = None
    fmt_ver = None
    with open(BASELINE_PATH, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            if line.startswith('FORMAT_VERSION='):
                fmt_ver = line.split('=', 1)[1].strip()
                continue
            if line.startswith('RECORDED_REVISION='):
                recorded_rev = line.split('=', 1)[1].strip()
                continue
            parts = line.split('\t')
            if len(parts) != 3:
                print(f"基线文件格式错误（期待 3 个 tab 分隔字段）：{line!r}", file=sys.stderr)
                sys.exit(2)
            kind, name, value = parts
            contract[(kind, name)] = value
    if fmt_ver != str(FORMAT_VERSION):
        print(
            f"基线文件版本无效：期待 FORMAT_VERSION={FORMAT_VERSION}，"
            f"实际 {fmt_ver!r}。请用 --update-baseline 重新生成。",
            file=sys.stderr,
        )
        sys.exit(2)
    if recorded_rev is None:
        print(f"基线文件缺少 RECORDED_REVISION 字段：{BASELINE_PATH}", file=sys.stderr)
        sys.exit(2)
    return contract, recorded_rev


def write_baseline(contract, revision):
    lines = [
        f"# {BASELINE_PATH}",
        "# 自动生成——不要手改。跑 `bash scripts/check-sql-revision.sh --update-baseline` 重新生成。",
        "# 记录 sql/install-coord-functions.sql / install-unit-functions.sql / install-tou.sql",
        "# 三组 SQL 的对象契约快照（表列/函数签名/视图名/触发器/索引），配合",
        "# config/versions.env 的 SQL_COMPAT_REVISION 做 CI 强制门（issue #33 同类教训）。",
        f"FORMAT_VERSION={FORMAT_VERSION}",
        f"RECORDED_REVISION={revision}",
    ]
    for key in sorted(contract):
        kind, name = key
        lines.append(f"{kind}\t{name}\t{contract[key]}")
    tmp_path = BASELINE_PATH + '.tmp'
    with open(tmp_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    os.replace(tmp_path, BASELINE_PATH)


def diff_contracts(current, baseline):
    current_keys = set(current)
    baseline_keys = set(baseline)
    added = sorted(current_keys - baseline_keys)
    removed = sorted(baseline_keys - current_keys)
    changed = sorted(k for k in (current_keys & baseline_keys) if current[k] != baseline[k])
    return added, removed, changed


def print_diff(current, baseline, defined_in, added, removed, changed):
    def where(key):
        files = defined_in.get(key)
        if not files:
            return ''
        return '（' + ', '.join(sorted(files)) + '）'

    if added:
        print(f"  新增 {len(added)} 个对象：")
        for k in added:
            print(f"    + {k[0]} {k[1]}{where(k)}")
            print(f"        {current[k]}")
    if removed:
        print(f"  移除 {len(removed)} 个对象：")
        for k in removed:
            print(f"    - {k[0]} {k[1]}")
            print(f"        {baseline[k]}")
    if changed:
        print(f"  签名变化 {len(changed)} 个对象：")
        for k in changed:
            print(f"    ~ {k[0]} {k[1]}{where(k)}")
            print(f"        基线: {baseline[k]}")
            print(f"        现在: {current[k]}")


def main():
    args = sys.argv[1:]
    update = False
    for a in args:
        if a == '--update-baseline':
            update = True
        else:
            print(f"未知参数: {a}", file=sys.stderr)
            print("用法: bash scripts/check-sql-revision.sh [--update-baseline]", file=sys.stderr)
            sys.exit(2)

    for path in SQL_FILES:
        if not os.path.exists(path):
            print(f"找不到 {path}", file=sys.stderr)
            sys.exit(2)

    current, defined_in = extract_contract(SQL_FILES)
    current_rev = read_current_revision()
    baseline, recorded_rev = load_baseline()

    if baseline is None:
        if not update:
            print(f"缺少基线文件 {BASELINE_PATH}；请先运行 --update-baseline 创建", file=sys.stderr)
            sys.exit(1)
        write_baseline(current, current_rev)
        print(f"✅ 基线已创建：{BASELINE_PATH}（revision={current_rev}，{len(current)} 个对象）")
        sys.exit(0)

    added, removed, changed = diff_contracts(current, baseline)
    has_diff = bool(added or removed or changed)

    if update:
        if not has_diff:
            print(f"契约与基线一致（{len(current)} 个对象），无需更新。基线文件未改动。")
            sys.exit(0)
        if current_rev == recorded_rev:
            print(
                "❌ 拒绝更新基线：SQL 对象契约有变化，但 config/versions.env 的 "
                f"SQL_COMPAT_REVISION 仍是 {current_rev}（与基线记录一致，说明没有 bump）。"
            )
            print()
            print_diff(current, baseline, defined_in, added, removed, changed)
            print()
            print("请先按 config/versions.env 顶部注释 bump 这个数字，再重跑 --update-baseline。")
            sys.exit(1)
        write_baseline(current, current_rev)
        print(
            f"✅ 基线已更新：{BASELINE_PATH}（revision {recorded_rev} → {current_rev}，"
            f"{len(current)} 个对象）"
        )
        print()
        print_diff(current, baseline, defined_in, added, removed, changed)
        sys.exit(0)

    # 默认模式：只读比对，CI 用
    if not has_diff:
        print(f"✅ SQL 对象契约与基线一致（{len(current)} 个对象，revision={current_rev}）")
        sys.exit(0)

    print("❌ SQL 对象契约相对基线有变化：")
    print()
    print_diff(current, baseline, defined_in, added, removed, changed)
    print()
    if current_rev == recorded_rev:
        print(
            f"config/versions.env 的 SQL_COMPAT_REVISION 仍是 {current_rev}"
            "（与基线记录一致）——契约变了就必须 bump 这个数字（规则见文件顶部注释），"
            "然后本地跑："
        )
        print("  bash scripts/check-sql-revision.sh --update-baseline")
        print("并把 config/versions.env 和 scripts/sql-contract-baseline.txt 一起提交。")
    else:
        print(
            f"SQL_COMPAT_REVISION 已从基线记录的 {recorded_rev} 变为 {current_rev}，"
            f"但 {BASELINE_PATH} 还没跟着刷新。本地跑："
        )
        print("  bash scripts/check-sql-revision.sh --update-baseline")
        print("并把更新后的基线文件一起提交。")
    sys.exit(1)


if __name__ == '__main__':
    main()
PYEOF
