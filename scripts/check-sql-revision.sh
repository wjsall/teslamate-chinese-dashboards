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
#       # 契约变化时，只有 SQL_COMPAT_REVISION 已相应 bump 才允许写入；
#       # 契约未变但 revision 已按规则 bump 时，只同步 RECORDED_REVISION 与 SOURCE_DIGEST；
#       # 契约变了但 revision 没变会拒绝更新（跟直接跑默认模式一样报错），
#       # 防止有人绕过检查、只重新生成基线而不真的 bump 版本号。
#       # 唯一例外：diff 只是「新增 FUNCTION_BODY 行」**且**三组 SQL 的内容摘要
#       # （基线里的 SOURCE_DIGEST）没变——那就是只把某个已有函数加进了下面的
#       # CORE_BODY_FUNCTIONS 名单，SQL 一个字节没动，只是门变严了，不该让所有现有
#       # 用户被判成「装的 SQL 过期了」。摘要这一条不能省：新加进名单的函数在基线里
#       # 没有旧指纹，「加名单 + 同时改它的函数体」产生的是「新增」而不是「变化」，
#       # 只看行类型会把这次改动直接漂白。判定见 is_watchlist_widening()。
#       # 基线文件不存在时 --update-baseline 直接报错，**不会**替你重新生成——见下面
#       # --create-baseline 的说明。
#   bash scripts/check-sql-revision.sh --create-baseline
#       # 从无到有创建基线，只在文件确实不存在时可用（已存在会拒绝）。
#       # 为什么要跟 --update-baseline 分成两个 flag：基线缺失时无从比对，凭空生成等于
#       # 把当前 SQL 一股脑认作「已确认」，任何未经 SQL_COMPAT_REVISION 确认的改动都会
#       # 被一并洗白。也就是说「删掉基线再重新生成」本来是一条绕过 bump 的路。拆成两个
#       # flag 之后，日常那条命令碰不到这个行为，重建必须显式说出口。
#       # 重建出来的是**整个文件重写**，diff 摆在评审面前；这一步原本只靠可见性。
#       # FORMAT_VERSION 升级导致的重建属于这一类：应当由**改脚本的那个人**在同一次提交
#       # 里跑 --create-baseline，让基线 diff 跟脚本改动一起被评审看到；不要让用户各自
#       # 在自己机器上重建（那样每个人洗白的东西都不一样，而且谁都没看见）。
#
# 基线历史棘轮（默认模式额外跑的一道）：
#   光有上面那套还不够。「删掉基线文件再 --create-baseline」能在**不 bump
#   SQL_COMPAT_REVISION** 的情况下重写基线，之后所有门全绿——实测走过一次：把
#   uninstall_tou 的语义反转，走这条路只产生 4 行 diff，RECORDED_REVISION 纹丝不动。
#   所以默认模式还会把基线文件跟**上一个真正改过它的提交**比一次：
#   契约行变了、RECORDED_REVISION 却没变 → 报红。判据是机器可校验的，不依赖有没有人
#   认真看那次 diff。工作区的基线跟 HEAD 不一致时比 HEAD；已提交时用
#   `git log -n 2 -- <baseline>` 找上一个真实版本，不受中间隔了多少个无关提交影响。
#   本地拿不到上一版时明确跳过并说明原因；CI（CI / GITHUB_ACTIONS 非空）则 fail-closed，
#   防止浅克隆让棘轮失效。确有意从零建立历史时，可显式设置
#   SQL_REVISION_ALLOW_MISSING_HISTORY=1 豁免一次，并让日志保留这次选择。
#   ⚠ CI 里正常比对需要完整的基线文件历史；.github/workflows/ghcr-build.yml 的 lint job
#     已经设了 fetch-depth: 0。
#
# 退出码：0 = 契约与基线一致（或 --update-baseline / --create-baseline 成功写入）；
# 1 = 有未经 revision 确认的契约变化，或写入被拒绝。
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
import hashlib
import re
import subprocess
import sys

SQL_FILES = [
    "sql/install-coord-functions.sql",
    "sql/install-unit-functions.sql",
    "sql/install-tou.sql",
]
BASELINE_PATH = "scripts/sql-contract-baseline.txt"
VERSIONS_ENV_PATH = "config/versions.env"
# 2 = 基线文件多了一行必需的 SOURCE_DIGEST（三组 SQL 的内容摘要）。老版本脚本读不懂
# 这一行，所以加字段必须同时 +1。
FORMAT_VERSION = 2


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
                # 折叠函数体是有意为之（函数体只是实现，改措辞不该算契约变化）。
                # 但 `DO $tag$ ... $tag$` 不是函数体，而是一条会真正建对象的顶层语句——
                # install-tou.sql 就把视图重建放在 DO 块里（要在里面处理"用户建了依赖对象"
                # 的异常）。把 DO 体一起折叠掉，里面创建的对象就从契约里凭空消失了，
                # 门会把"什么都没改"报成"移除了一个对象"。所以 DO 体保留、继续扫描。
                # 折叠的判据是「这是不是函数体」，而不是「是不是 dollar-quote」。
                # 函数体一定跟在 AS 后面（CREATE FUNCTION ... AS $$ ... $$），折叠它是有意
                # 为之：改函数实现不该算契约变化。而 `DO $tag$ ... $tag$` 是会真正建对象的
                # 顶层语句，`EXECUTE $tag$ ... $tag$` 是它里面要执行的 SQL——install-tou.sql
                # 就把视图重建放在 DO + EXECUTE 里（要在里面处理"用户建了依赖对象"的异常）。
                # 把这两种也折叠掉，里面创建的对象就从契约里凭空消失，门会把"什么都没改"
                # 报成"移除了一个对象"。
                # 不折叠的分支要递归骨架化，不能原样塞回去：原样塞回去的话体内的 `--` 注释
                # 没被清理，注释里写的「CREATE VIEW xxx」会被后面的对象正则当成真对象
                # （实测能造出幽灵对象让门误报新增）。
                if not re.search(r'\bAS\s*$', ''.join(out)[-16:], re.IGNORECASE):
                    out.append(skeletonize(inner))
                    i = end_tag_idx + len(tag)
                    continue
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


# ---------------------------------------------------------------------------
# 核心函数的「函数体指纹」
#
# 对象契约（表列 / 函数签名 / 视图 / 触发器 / 索引）刻意不管函数体——改个 RAISE NOTICE
# 措辞就要求 bump revision，会让这个机制变成噪音，很快就没人当真。
#
# 但有一类函数体的改动是必须让老用户重装 SQL 的：**算钱和算数的那几个**。
# 2026-07 的实例：compute_tou_cost 里把「没匹配到电价的时段」从当 0 元改成整笔回退，
# 这是行为的实质变化（会改变用户看到的费用），签名却一个字没动 —— 契约门完全看不见。
# 只换镜像不重装 SQL 的用户（方法 C / Watchtower）会一直用着旧算法，而 diagnose 说一切正常。
#
# 所以对下面这几个函数额外记一个**规范化后的函数体指纹**：去掉注释、压缩空白、
# 抹掉 RAISE NOTICE/WARNING 的文案（那是给人看的提示，改措辞不该触发 bump）。
# 指纹变了就必须 bump SQL_COMPAT_REVISION，跟契约变化同等对待。
CORE_BODY_FUNCTIONS = {
    'compute_tou_cost',          # 单笔 TOU 费用的核心算法
    'lookup_tou_rate',           # 时段/地点/AC-DC → 电价 的匹配规则
    'effective_cost',            # 仪表盘取费用的统一入口（11 个仪表盘在用）
    'cost_before_tou',           # 「不按分时电价时显示多少钱」——对账面板的比较基准
    '_tou_default_cost',         # 默认兜底费用公式；只改电量口径/舍入也会改变历史显示金额
    'backfill_all_tou',          # 历史费用回算
    'set_default_charging_rate', # 默认电价（决定它会不会顶掉真实账单）
    'trigger_compute_tou',       # 充电完成时自动算/清分时电价费用
    'adopt_legacy_default_costs',# 老数据迁移，会改 charging_processes.cost，改错就丢数据
    'uninstall_tou',             # 卸载，会把覆盖表里的 TeslaMate 原值写回原表，改错就丢/串数据
    '_tou_has_matching_rate',    # 「这笔充电有没有电价规则可用」——compute_tou_cost 用它决定
                                 # 算 TOU 还是回退原 cost，改这里就等于改用户看到的费用，
                                 # 而 compute_tou_cost 自己的函数体一个字都不用动
    '_tou_sample_raw_kwh',       # 计费、断档噪声预算和回算归因共用的单区间电量口径；
                                 # 漂移会让失败原因和实际金额再次互相矛盾
    '_tou_long_gap_kind',        # 长采样断档是配置缺口还是纯采样问题，并决定是否拒绝计费
}

_COMMENT_LINE_RE = re.compile(r'--[^\n]*')
_BLOCK_COMMENT_RE = re.compile(r'/\*.*?\*/', re.S)
_RAISE_TEXT_RE = re.compile(r"(RAISE\s+(?:NOTICE|WARNING|INFO|LOG)\s+)'(?:[^']|'')*'", re.I)


def normalize_body(text):
    """把函数体归一化成「只剩逻辑」的形式：去注释、抹掉 RAISE 文案、压空白。"""
    t = _BLOCK_COMMENT_RE.sub(' ', text)
    t = _COMMENT_LINE_RE.sub(' ', t)
    t = _RAISE_TEXT_RE.sub(r"\1'<msg>'", t)
    t = re.sub(r'\s+', ' ', t)
    return t.strip().lower()


def extract_core_body_prints(raw_text, path, current):
    """在**未骨架化**的原文里找核心函数的 dollar-quoted 函数体，记录其指纹。"""
    for m in _FUNC_RE.finditer(raw_text):
        name = m.group(1).lower()
        if name not in CORE_BODY_FUNCTIONS:
            continue
        tag_m = _DOLLAR_TAG_RE.search(raw_text, m.end())
        if not tag_m:
            continue
        tag = tag_m.group(0)
        end_idx = raw_text.find(tag, tag_m.end())
        if end_idx == -1:
            continue
        body = raw_text[tag_m.end():end_idx]
        digest = hashlib.sha256(normalize_body(body).encode('utf-8')).hexdigest()[:16]
        _record(current, 'FUNCTION_BODY', name, digest, path)


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

    extract_core_body_prints(raw, path, current)

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


def revision_number(value, source):
    """Revision 是只增不减的十进制整数；拒绝词法比较和含糊格式。"""
    if not re.fullmatch(r'[0-9]+', value):
        print(f"{source} 里的 SQL revision 不是非负整数：{value!r}", file=sys.stderr)
        sys.exit(2)
    return int(value)


def compute_source_digest(files):
    """三组 SQL 文件内容的摘要——回答的是「SQL 文件到底动没动」，不是「契约变没变」。

    刻意不做归一化（不去注释、不压空白）：这里要的就是「一个字节都没变」这个强判据，
    它是 is_watchlist_widening() 放行的前提，宁可严也不能松。
    唯一的例外是把 CRLF 归一成 LF——换行风格不同的检出不该被当成 SQL 改动。
    """
    h = hashlib.sha256()
    for path in files:
        with open(path, 'rb') as f:
            data = f.read().replace(b'\r\n', b'\n')
        h.update(path.encode('utf-8'))
        h.update(b'\0')
        h.update(hashlib.sha256(data).digest())
    return h.hexdigest()


def parse_baseline_text(text, strict=True):
    """把基线文件的内容解析成 (contract_dict, recorded_rev, source_digest, fmt_ver)。

    strict=False 用于解析**历史版本**的基线（git show 出来的）：格式对不上时返回
    None 让调用方跳过，而不是像解析当前文件那样直接退出。历史版本解析失败只意味着
    「没法比对」，不意味着「有人洗白」——见 ratchet_against_history() 里对假红的态度。
    """
    contract = {}
    recorded_rev = None
    recorded_digest = None
    fmt_ver = None
    for line in text.split('\n'):
        line = line.rstrip('\r')
        if not line or line.startswith('#'):
            continue
        if line.startswith('FORMAT_VERSION='):
            fmt_ver = line.split('=', 1)[1].strip()
            continue
        if line.startswith('RECORDED_REVISION='):
            recorded_rev = line.split('=', 1)[1].strip()
            continue
        if line.startswith('SOURCE_DIGEST='):
            recorded_digest = line.split('=', 1)[1].strip()
            continue
        parts = line.split('\t')
        if len(parts) != 3:
            if not strict:
                return None
            print(f"基线文件格式错误（期待 3 个 tab 分隔字段）：{line!r}", file=sys.stderr)
            sys.exit(2)
        kind, name, value = parts
        contract[(kind, name)] = value
    return contract, recorded_rev, recorded_digest, fmt_ver


def load_baseline():
    """返回 (contract_dict, recorded_revision, recorded_source_digest)；
    文件不存在时返回 (None, None, None)。"""
    if not os.path.exists(BASELINE_PATH):
        return None, None, None
    with open(BASELINE_PATH, encoding='utf-8') as f:
        contract, recorded_rev, recorded_digest, fmt_ver = parse_baseline_text(f.read())
    if fmt_ver != str(FORMAT_VERSION):
        print(
            f"基线文件版本无效：期待 FORMAT_VERSION={FORMAT_VERSION}，实际 {fmt_ver!r}。\n"
            "格式升级后的重建应当由**改本脚本的那个人**在同一次提交里做完，让基线 diff 跟"
            "脚本改动一起被评审看到：\n"
            f"  rm {BASELINE_PATH} && bash scripts/check-sql-revision.sh --create-baseline\n"
            "如果你只是拉到了别人的改动却看到这条消息，说明脚本和基线没被一起提交，"
            "请找改动的作者补，不要在自己机器上重建——那会把你本地的 SQL 状态直接认作基线。",
            file=sys.stderr,
        )
        sys.exit(2)
    if recorded_rev is None:
        print(f"基线文件缺少 RECORDED_REVISION 字段：{BASELINE_PATH}", file=sys.stderr)
        sys.exit(2)
    if recorded_digest is None:
        print(f"基线文件缺少 SOURCE_DIGEST 字段：{BASELINE_PATH}", file=sys.stderr)
        sys.exit(2)
    return contract, recorded_rev, recorded_digest


def write_baseline(contract, revision, source_digest):
    lines = [
        f"# {BASELINE_PATH}",
        "# 自动生成——不要手改。跑 `bash scripts/check-sql-revision.sh --update-baseline` 重新生成。",
        "# 记录 sql/install-coord-functions.sql / install-unit-functions.sql / install-tou.sql",
        "# 三组 SQL 的对象契约快照（表列/函数签名/视图名/触发器/索引），配合",
        "# config/versions.env 的 SQL_COMPAT_REVISION 做 CI 强制门（issue #33 同类教训）。",
        "# SOURCE_DIGEST 是这三个文件内容的摘要，只用来判断「SQL 文件本身动没动」，",
        "# 是 CORE_BODY_FUNCTIONS 名单扩容豁免的前提（见 is_watchlist_widening）。",
        f"FORMAT_VERSION={FORMAT_VERSION}",
        f"RECORDED_REVISION={revision}",
        f"SOURCE_DIGEST={source_digest}",
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


def is_watchlist_widening(added, removed, changed, recorded_digest, current_digest):
    """diff 是不是「只把某个已有函数纳入了核心函数体指纹的监视名单」。

    这种改动只会让门对以后的改动更严，不改变任何用户已经装好的 SQL，因此不该 bump
    SQL_COMPAT_REVISION：bump 了等于告诉所有现有用户「你装的 SQL 过期了，去重装」，
    那是假警报，正是 config/versions.env 顶部反复强调要避免的噪音。

    两个条件缺一不可：

    1. diff 里只有**新增**的 FUNCTION_BODY 行。移除是把门改松，变化说明被监视的函数体
       真的动了，两者都不放行。

    2. 三个 SQL 文件的 SOURCE_DIGEST 与基线记录的一致，也就是 SQL 文件一个字节都没动。
       这一条不能省。FUNCTION_BODY 行只对名单里的函数产生，所以一个原本不在名单里的
       函数，在基线里**没有**旧的 FUNCTION_BODY 行——把它加进名单的同时改掉它的函数体，
       那一行是「新增」而不是「变化」，只看条件 1 会直接放行，而写进基线的已经是**改过
       之后**的指纹。后果正是这道门要防的：老用户库里装的是旧函数体，diagnose.sh 却
       告诉他们 SQL 是最新的。摘要把「SQL 文件本身没变」从注释里的前提变成机器判据。

    代价：SQL 有任何字节改动（哪怕只是改注释）又同时扩容名单时，豁免不适用、照常要求
    bump。这个方向是安全的——宁可多 bump 一次，不能放过一次真改动。
    """
    if not (bool(added) and not removed and not changed):
        return False
    if not all(kind == 'FUNCTION_BODY' for kind, _name in added):
        return False
    return recorded_digest is not None and recorded_digest == current_digest


def _git_show(spec):
    """git show <spec> 的内容；拿不到（不是仓库 / 没这个提交 / 文件不在）返回 None。"""
    try:
        r = subprocess.run(['git', 'show', spec],
                           capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return r.stdout


def _git_commits_for_path(path, limit):
    """按新到旧返回真正修改过 path 的提交；拿不到历史时返回 None。"""
    try:
        r = subprocess.run(
            ['git', 'log', '--format=%H', '-n', str(limit), '--', path],
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if r.returncode != 0:
        return None
    return [line for line in r.stdout.splitlines() if line]


def history_unavailable(reason):
    """本地允许说明后跳过；CI 默认拒绝，除非显式声明这次没有可比历史。"""
    in_ci = bool(os.environ.get('CI') or os.environ.get('GITHUB_ACTIONS'))
    waiver = os.environ.get('SQL_REVISION_ALLOW_MISSING_HISTORY') == '1'
    if not in_ci:
        return True, reason
    if waiver:
        return True, (
            f'{reason}；CI 已显式设置 SQL_REVISION_ALLOW_MISSING_HISTORY=1，'
            '本次允许跳过历史棘轮'
        )

    print("❌ CI 中无法取得上一版 SQL 契约基线，历史棘轮不能安全执行。")
    print(f"   原因：{reason}")
    print("   请使用完整 checkout（fetch-depth: 0），并确保上一个真实基线版本可读取。")
    print(
        "   只有确实在建立全新基线、且本次变更已经另行核验时，才可显式设置 "
        "SQL_REVISION_ALLOW_MISSING_HISTORY=1。"
    )
    return False, None


def ratchet_against_history():
    """棘轮：基线文件里的契约行相对上一版变了、RECORDED_REVISION 却没变 → 报红。

    为什么单靠上面那套比对不够：--update-baseline 会检查 bump，但「删掉基线文件再
    --create-baseline」绕开了它——重建出来的基线把当前 SQL 原样认作已确认，
    RECORDED_REVISION 纹丝不动，之后所有门全绿。实测走过一次这条路：把 uninstall_tou
    的语义反转，只产生 4 行 diff，门一声不吭。--create-baseline 那条路靠的是「整文件
    diff 摆在评审面前」，也就是靠人看；这里补的是机器判据。

    判据：拿当前基线文件跟它的上一个真实版本比。
      · 工作区的基线跟 HEAD 里的不一样 → 上一版就是 HEAD 里的那份（还没提交的改动）
      · 一样 → 从真正修改过基线的提交中取前两个，第二个才是上一版
    契约行有增删改、而 RECORDED_REVISION 两版相同 → 报红。
    （「把函数纳入核心函数体指纹监视范围」那条豁免同样适用，判据与 --update-baseline
    完全一致，否则那条合法路径会在这里假红。）

    本地拿不到上一版时明确跳过并说明原因；CI 必须拿到历史，否则 fail-closed。新仓库或
    首次加入基线的 CI 可用 SQL_REVISION_ALLOW_MISSING_HISTORY=1 显式豁免一次。
    FORMAT_VERSION 变化本身不豁免契约变化：两版仍能解析时照常比较契约行。

    返回 (ok: bool, skipped_reason: str|None)。
    """
    if not os.path.exists(BASELINE_PATH):
        return history_unavailable('基线文件不存在')

    with open(BASELINE_PATH, encoding='utf-8') as f:
        cur_text = f.read()

    head_text = _git_show('HEAD:' + BASELINE_PATH)
    if head_text is None:
        return history_unavailable(
            '取不到 HEAD 里的基线文件（不在 git 仓库里跑？基线是这次新加的？）'
        )

    if head_text != cur_text:
        prev_text = head_text
        prev_label = 'HEAD（已提交的那一版）'
    else:
        baseline_commits = _git_commits_for_path(BASELINE_PATH, 2)
        if baseline_commits is None or len(baseline_commits) < 2:
            return history_unavailable(
                '取不到上一个真正修改过基线文件的提交（基线只有一个版本？'
                'CI 没有拉取完整历史？）'
            )
        previous_baseline_commit = baseline_commits[1]
        prev_text = _git_show(previous_baseline_commit + ':' + BASELINE_PATH)
        prev_label = (
            f'{previous_baseline_commit[:12]}'
            '（上一个真正修改基线文件的提交）'
        )
        if prev_text is None:
            return history_unavailable(
                f'取不到 {prev_label} 里的基线文件（CI 没有拉取完整历史？）'
            )

    parsed = parse_baseline_text(prev_text, strict=False)
    if parsed is None:
        return history_unavailable(f'{prev_label} 里的基线文件格式解析不了')
    prev_contract, prev_rev, prev_digest, prev_fmt = parsed
    if prev_rev is None:
        return history_unavailable(f'{prev_label} 里的基线没有 RECORDED_REVISION 字段')

    cur_parsed = parse_baseline_text(cur_text, strict=False)
    if cur_parsed is None:
        return False, None
    cur_contract, cur_rev, cur_digest, cur_fmt = cur_parsed

    added, removed, changed = diff_contracts(cur_contract, prev_contract)
    if not (added or removed or changed):
        return True, None
    if cur_rev != prev_rev:
        return True, None
    if is_watchlist_widening(added, removed, changed, prev_digest, cur_digest):
        return True, None

    print(f"❌ 基线文件的契约行相对{prev_label}变了，但 RECORDED_REVISION 还是 {cur_rev}。")
    if cur_fmt != prev_fmt:
        print(
            f"   FORMAT_VERSION 同时从 {prev_fmt!r} 变为 {cur_fmt!r}，"
            "但格式升级不能替代 SQL_COMPAT_REVISION 对契约变化的确认。"
        )
    print()
    print_diff(cur_contract, prev_contract, {}, added, removed, changed)
    print()
    print("契约变了就必须 bump config/versions.env 的 SQL_COMPAT_REVISION（规则见那个文件顶部），")
    print("否则装了旧 SQL 的用户会被 scripts/diagnose.sh 判成「已经是最新」，而实际不是。")
    print("正确流程：改 SQL → bump SQL_COMPAT_REVISION → bash scripts/check-sql-revision.sh"
          " --update-baseline → 一起提交。")
    print()
    print("如果你是用「删掉基线再 --create-baseline」重建的：那条路不检查 revision，")
    print("这道门就是专门补它的。即使 FORMAT_VERSION 同时升级，只要契约变了，")
    print("仍需 bump SQL_COMPAT_REVISION；纯格式重建且契约行没变则不会报错。")
    return False, None


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
    create = False
    usage = ("用法: bash scripts/check-sql-revision.sh "
             "[--update-baseline | --create-baseline]")
    for a in args:
        if a == '--update-baseline':
            update = True
        elif a == '--create-baseline':
            create = True
        else:
            print(f"未知参数: {a}", file=sys.stderr)
            print(usage, file=sys.stderr)
            sys.exit(2)
    if update and create:
        print("--update-baseline 和 --create-baseline 不能一起用："
              "前者更新已有基线（会检查 SQL_COMPAT_REVISION），"
              "后者只负责从无到有创建。", file=sys.stderr)
        print(usage, file=sys.stderr)
        sys.exit(2)

    for path in SQL_FILES:
        if not os.path.exists(path):
            print(f"找不到 {path}", file=sys.stderr)
            sys.exit(2)

    current, defined_in = extract_contract(SQL_FILES)
    current_rev = read_current_revision()
    current_digest = compute_source_digest(SQL_FILES)

    # --create-baseline 自己判断文件在不在，不走 load_baseline()：FORMAT_VERSION 不匹配时
    # load_baseline() 会直接退出，而「格式升级后重建」正是这个 flag 要服务的场景之一。
    if create:
        if os.path.exists(BASELINE_PATH):
            print(f"❌ 拒绝创建基线：{BASELINE_PATH} 已经存在。", file=sys.stderr)
            print("   --create-baseline 只负责「从无到有」。对已有基线的任何更新都走 "
                  "--update-baseline，", file=sys.stderr)
            print("   那条路会检查 SQL_COMPAT_REVISION。如果这个 flag 也能覆盖已有基线，"
                  "两个 flag 合起来", file=sys.stderr)
            print("   又变成一条「不用 bump 就能重写基线」的路，等于白拆。", file=sys.stderr)
            sys.exit(1)
        write_baseline(current, current_rev, current_digest)
        print(f"✅ 基线已创建：{BASELINE_PATH}（revision={current_rev}，{len(current)} 个对象）")
        print()
        print("⚠ 这是**整个基线文件的重新生成**，不是增量更新：它把当前 SQL 的契约原样认作")
        print("  「已确认」，没有跟任何旧记录比对过，所以这一步不检查 SQL_COMPAT_REVISION。")
        print("  请把这个文件和触发重建的那次改动放进同一次提交，并在评审时确认：")
        print(f"    - RECORDED_REVISION={current_rev} 是否确实是当前 SQL 应有的 revision")
        print("    - 契约行相对上一版只有你预期中的变化（整文件 diff 一眼可见）")
        sys.exit(0)

    baseline, recorded_rev, recorded_digest = load_baseline()

    if baseline is None:
        print(f"❌ 找不到基线文件 {BASELINE_PATH}。", file=sys.stderr)
        print("   它是仓库里跟踪的文件，正常情况下不会缺——多半是被误删了。先找回来：",
              file=sys.stderr)
        print(f"     git checkout -- {BASELINE_PATH}", file=sys.stderr)
        print(file=sys.stderr)
        print("   --update-baseline 刻意不在这里替你重新生成：基线缺失时无从比对，凭空生成",
              file=sys.stderr)
        print("   等于把当前 SQL 一股脑认作「已确认」，任何未经 SQL_COMPAT_REVISION 确认的",
              file=sys.stderr)
        print("   改动都会被一并洗白。", file=sys.stderr)
        print("   确实需要从零重建（例如脚本的 FORMAT_VERSION 升了级），用 --create-baseline，",
              file=sys.stderr)
        print("   并把整个文件的 diff 放进同一次提交交给评审。", file=sys.stderr)
        sys.exit(1)

    current_rev_number = revision_number(current_rev, VERSIONS_ENV_PATH)
    recorded_rev_number = revision_number(recorded_rev, BASELINE_PATH)

    # --update-baseline 的 revision-only 同步也是写路径，必须遵守单调性。否则把 config
    # 从 9 误写成 8 后运行同步，会把基线也降到 8，并把这次倒退伪装成“两边一致”。
    if update and current_rev_number < recorded_rev_number:
        print(
            "❌ 拒绝更新基线：SQL_COMPAT_REVISION 不能倒退，"
            f"{VERSIONS_ENV_PATH} 是 {current_rev}，"
            f"{BASELINE_PATH} 已记录 {recorded_rev}。"
        )
        print("   请恢复 config 中的 revision；需要发布新 SQL 行为时只能在已记录值上递增。")
        sys.exit(1)

    # 默认只读模式必须先确认两个 revision 单一事实源一致。否则只改基线里的
    # RECORDED_REVISION 就能让后面的契约比对和历史棘轮都误判为已经确认。
    if not update and current_rev != recorded_rev:
        print(
            "❌ SQL revision 不一致："
            f"{VERSIONS_ENV_PATH} 记录 {current_rev}，"
            f"{BASELINE_PATH} 记录 {recorded_rev}。"
        )
        print(
            "   请确认应有的 SQL_COMPAT_REVISION：基线记录被误改就恢复它；"
            "config 确实已 bump 且契约有变化时，再运行 "
            "bash scripts/check-sql-revision.sh --update-baseline。"
        )
        sys.exit(1)

    added, removed, changed = diff_contracts(current, baseline)
    has_diff = bool(added or removed or changed)
    widening = is_watchlist_widening(added, removed, changed, recorded_digest, current_digest)
    # 只新增 FUNCTION_BODY 行、但 SQL 文件动过 —— 豁免不适用，报错时要说清楚为什么，
    # 否则看的人会以为「我只改了名单，怎么还要我 bump」。
    widening_blocked_by_source = (
        not widening
        and bool(added) and not removed and not changed
        and all(kind == 'FUNCTION_BODY' for kind, _name in added)
        and recorded_digest != current_digest
    )

    if update:
        if not has_diff:
            if current_rev == recorded_rev:
                print(f"契约与基线一致（{len(current)} 个对象），无需更新。基线文件未改动。")
                sys.exit(0)
            write_baseline(current, current_rev, current_digest)
            print(
                f"✅ 基线已更新：{BASELINE_PATH}（revision {recorded_rev} → {current_rev}，"
                f"{len(current)} 个对象）"
            )
            print("   本次只同步 revision，契约未变；SOURCE_DIGEST 已刷新。")
            sys.exit(0)
        if current_rev == recorded_rev and not widening:
            print(
                "❌ 拒绝更新基线：SQL 对象契约有变化，但 config/versions.env 的 "
                f"SQL_COMPAT_REVISION 仍是 {current_rev}（与基线记录一致，说明没有 bump）。"
            )
            print()
            print_diff(current, baseline, defined_in, added, removed, changed)
            print()
            if widening_blocked_by_source:
                print(
                    "注意：diff 看起来只是「把函数纳入核心函数体指纹的监视范围」，但三组 SQL 的"
                    "内容摘要与基线记录不一致，说明 SQL 文件本身也改动了。"
                )
                print(
                    "  新纳入监视的函数在基线里没有旧指纹，这时候记下的会是**改动之后**的函数体，"
                    "等于把这次改动直接漂白，所以这条豁免不适用。"
                )
                print()
            print("请先按 config/versions.env 顶部注释 bump 这个数字，再重跑 --update-baseline。")
            sys.exit(1)
        write_baseline(current, current_rev, current_digest)
        if current_rev == recorded_rev:
            print(
                f"✅ 基线已更新：{BASELINE_PATH}（revision 保持 {current_rev}，"
                f"{len(current)} 个对象）"
            )
            print(
                "   本次只是把下面这些函数纳入「核心函数体指纹」的监视范围，SQL 文件本身没变，"
                "所以不用 bump SQL_COMPAT_REVISION。"
            )
        else:
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
        # 上面那句只说明「SQL 跟基线对得上」。基线文件本身可能是被重写过的——
        # 「删掉基线再 --create-baseline」就能在不 bump revision 的情况下把改动洗白，
        # 之后这里照样打勾。所以再跟基线文件的上一版对一次。
        ratchet_ok, skipped = ratchet_against_history()
        if not ratchet_ok:
            sys.exit(1)
        if skipped:
            print(f"ℹ 基线历史棘轮这次跳过：{skipped}")
        else:
            print("✅ 基线文件相对上一版没有未经 revision 确认的契约变化")
        sys.exit(0)

    print("❌ SQL 对象契约相对基线有变化：")
    print()
    print_diff(current, baseline, defined_in, added, removed, changed)
    print()
    if widening:
        print(
            "以上只是把某些函数纳入「核心函数体指纹」的监视范围（SQL 文件本身没变），"
            f"不用 bump SQL_COMPAT_REVISION（保持 {current_rev} 即可）。本地跑："
        )
        print("  bash scripts/check-sql-revision.sh --update-baseline")
        print(f"并把更新后的 {BASELINE_PATH} 一起提交。")
    elif current_rev == recorded_rev:
        if widening_blocked_by_source:
            print(
                "注意：diff 看起来只是「把函数纳入核心函数体指纹的监视范围」，但三组 SQL 的"
                "内容摘要与基线记录不一致，说明 SQL 文件本身也改动了。"
            )
            print(
                "  新纳入监视的函数在基线里没有旧指纹，这时候记下的会是**改动之后**的函数体，"
                "等于把这次改动直接漂白，所以这条豁免不适用。"
            )
            print()
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
