#!/usr/bin/env bash
# dashboard JSON 静态 lint 门：把本项目踩过的真实坑变成可执行检查。
# 扫描范围：grafana/dashboards/zh-cn/*.json 和 grafana/dashboards/internal/*.json 全部
# （历史教训：v1.8.0 大审计只扫了 zh-cn 45 个，internal/ 3 个被漏审，#31 用户报的
#  中文面板就在 internal/ 里 grep 不到——绝不能只扫 zh-cn）。
#
# 跑：bash scripts/check-dashboard-lint.sh
# 退出码：0 = 全绿；1 = 有命中（打印 文件 :: 面板id/变量名 :: 规则字母 :: 摘要片段）
#
# 规则清单（字母对应下面 WHITELIST 条目的 rule）：
#   0 JSON 合法性             — json.load 失败即报错
#   a 裸点平均当均速           — 代码 token 含 AVG(speed)/AVG(p.speed)，包括冗余括号；
#                                分桶内均值仅在同一 target 确有 GROUP BY speed_bin 时放行。
#   b SQL 字符串字面量含 --    — Grafana 13.0.1 postgres 数据源会误剥字符串里的 --；
#                                检查单引号/E 字符串/dollar-quote 的字面量内容。
#   c 模板变量查询用 $__timezone — 模板变量查询中会解析成字面量 browser。
#   d timezone('$__timezone', X) 且 X≠NOW() — TeslaMate 朴素 UTC 列不能直接转；
#                                仅按白名单表达式放行 timezone('UTC', …) 或同一 SQL 中
#                                三参数 date_trunc(..., timezone('UTC', …), '$__timezone')
#                                产生的别名。
#   e 禁用自动换算单位         — lengthkm/lengthmi/short/kwatth；历史 drill-down 例外
#                                按 defaults 或具体 override matcher + value 精确放行。
#   f FROM settings WHERE id = $car_id — settings 是单行全局表；同时识别 schema 和
#                                双引号限定（public.settings / "settings"）。
#   g '${payload.X}' 裸强转     — 未填表单会产生 'undefined'；同时识别 ::TYPE 与
#                                CAST(expr AS TYPE)，TYPE 覆盖常用 PostgreSQL 数值类型。
#   h 老式 regex 抽 text/value — Grafana 9+/13 不再跨 /g 匹配拼接命名捕获组。
#   i 写表单无二次确认         — volkovlabs-form-panel 写操作必须 confirm=true。
#   j 用户可见文本汉化完整性   — title/displayName/变量 label/description/row 标题须含 CJK，
#                                或整串属于单位、术语、品牌、占位符、数字/符号白名单；
#                                只验证“至少一个 CJK”，不判断中英混排文本是否已完整汉化。
#   k 最终字段契约 / 孤儿基线  — table/stat 的 byName matcher 经查询复用、变量别名与 transformations
#                                推导后分为 PRESENT/ABSENT/DYNAMIC/UNKNOWN；只有 ABSENT 进入精确多重集
#                                基线，新增或过期基线均阻断。
#   l 自研函数存在性           — 形似项目自研的调用必须由 sql/install-*.sql 定义。
#   m dashboard 跳转 UID       — panel link/dataLink 中 /d/<uid> 必须指向仓内 dashboard。
#   n [报告档] timeseries 查询格式 — timeseries target 使用 format=table 时提示；被同面板
#                                configRefId 引用的配置帧明确豁免并打印说明。
#   o 柱状图趋势线             — drawStyle=bars 不得挂 regression/trendline transformation。
#   p 秒数/取模规范             — 禁止代码 token 中的 mod(...) 与 DATE_PART('epoch', ...)。
#   q [报告档] 可空列直等      — geofence_id =（排除 JOIN ON）可能破坏 NULL 全局语义。
#   r [报告档] 朴素 UTC 列     — NOW() - interval 邻域中的 date/start_date/end_date 应显式 UTC。
#   s 老变量语法               — rawSql 或模板变量内容不得包含 [[...]]。
#   t panel id 唯一性          — 同一 dashboard 内含 row 子面板的 panel id 不得重复。
#   u SQL target 数据源        — rawSql target 只允许 TeslaMate、继承值或模板变量 datasource。
#   v 分桶无序+首末聚合       — stat/gauge/bargauge 使用首末 reduce calc 时，
#                                只看最外层查询（括号深度 0）：外层有 GROUP BY 必须同时有
#                                外层 ORDER BY；CTE 主体/子查询内的 GROUP BY / ORDER BY 不算。
#   w reduceOptions.fields 与最终显示名失配 — stat/gauge/bargauge 非空 reduceOptions.fields
#                                正则复用 k 同款字段契约，套用 byName displayName override 后
#                                必须至少匹配一个最终显示名；只匹配改名前旧别名、匹配不到改名后
#                                显示名时单独报错（CurrentChargeView panel 47 案）。契约整体
#                                DYNAMIC/UNKNOWN（无任何具体字段）的面板跳过，--verbose-k 计数。
#
# a/d/f/g/l/p/q/r/v 共用一次 PostgreSQL-lite 词法扫描后的代码 token 流（注释已剔除，字符串保留为
# 有类型 token）；b 只检查同一扫描产出的字符串字面量内容。白名单不是 panel 级开关：
# 每条都带可校验条件；本次扫描未命中的条目视为过期白名单并直接失败。

set -e
cd "$(dirname "$0")/.."

python3 - "$@" <<'PYEOF'
import glob
import hashlib
import json
import os
import re
import sys
import tempfile
from collections import Counter, namedtuple
from urllib.parse import urlsplit


_DRILLDOWN = (
    "单次会话/单车详情类有界小值；v1.6.8 已决定保留上游单位写法"
)


def entry(file_rel, subject, rule, condition, reason):
    return {
        'file': file_rel,
        'subject': subject,
        'rule': rule,
        'condition': condition,
        'reason': reason,
    }


# 白名单条目必须描述“哪一次命中为何允许”，而不是给整个 panel 关闭规则。
WHITELIST = [
    entry(
        'grafana/dashboards/zh-cn/SpeedRates.json', 2, 'a',
        {'kind': 'group_by_speed_bin', 'target_refs': ('A',)},
        "target A 的 AVG(speed) 与 GROUP BY speed_bin 同处一个 target，是桶内均值",
    ),

    entry(
        'grafana/dashboards/zh-cn/battery-health.json', 28, 'd',
        {'kind': 'timezone_utc', 'target_refs': ('预计续航', '中位数')},
        "X 必须精确匹配 timezone('UTC', …)",
    ),
    entry(
        'grafana/dashboards/zh-cn/charging-stats.json', 29, 'd',
        {'kind': 'timezone_utc', 'target_refs': ('A',)},
        "X 必须精确匹配 timezone('UTC', …)",
    ),
    entry(
        'grafana/dashboards/zh-cn/sentry-drain.json', 9, 'd',
        {'kind': 'timezone_utc', 'target_refs': ('A',)},
        "X 必须精确匹配 timezone('UTC', …)",
    ),
    entry(
        'grafana/dashboards/zh-cn/statistics.json', 2, 'd',
        {'kind': 'date_trunc_alias', 'target_refs': ('A', 'B', 'C', 'D')},
        "X 必须是同一 target 内三参数 date_trunc(..., timezone('UTC', …), "
        "'$__timezone') 的别名",
    ),
]


# (文件, panel, scope, matcher id, matcher options, unit, 理由)
# scope=defaults 时 matcher 两项必须为 None；override 条目按 matcher+value 精确匹配。
_E_WHITELIST = [
    ('grafana/dashboards/internal/charge-details.json', 2, 'override', 'byRegexp', '.*_km$', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/internal/charge-details.json', 2, 'override', 'byRegexp', '.*_mi$', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/internal/charge-details.json', 8, 'defaults', None, None, 'kwatth', _DRILLDOWN),
    ('grafana/dashboards/internal/charge-details.json', 14, 'override', 'byRegexp', '/.*_km/', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/internal/charge-details.json', 14, 'override', 'byRegexp', '/.*_mi/', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 6, 'defaults', None, None, 'short', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 10, 'override', 'byName', 'km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 10, 'override', 'byName', 'mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 12, 'defaults', None, None, 'kwatth', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 32, 'defaults', None, None, 'short', _DRILLDOWN),
    ('grafana/dashboards/internal/drive-details.json', 40, 'defaults', None, None, 'kwatth', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentDriveView.json', 14, 'override', 'byName', 'range_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentDriveView.json', 14, 'override', 'byName', 'range_mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentState.json', 69, 'override', 'byName', 'range_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentState.json', 69, 'override', 'byName', 'range_mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentState.json', 70, 'override', 'byName', 'range_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/CurrentState.json', 70, 'override', 'byName', 'range_mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/TrackingDrives.json', 12, 'override', 'byName', 'km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/TrackingDrives.json', 12, 'override', 'byName', 'mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/TrackingDrives.json', 16, 'defaults', None, None, 'kwatth', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/charges.json', 6, 'override', 'byName', 'range_added_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/charges.json', 6, 'override', 'byName', 'range_added_mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/drive-stats.json', 8, 'override', 'byName', 'distance_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/drive-stats.json', 26, 'override', 'byName', 'distance_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/overview.json', 25, 'override', 'byName', 'range_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/overview.json', 25, 'override', 'byName', 'range_mi', 'lengthmi', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/trip.json', 36, 'override', 'byName', 'range_added_km', 'lengthkm', _DRILLDOWN),
    ('grafana/dashboards/zh-cn/trip.json', 36, 'override', 'byName', 'range_added_mi', 'lengthmi', _DRILLDOWN),
]

for file_rel, panel_id, scope, matcher_id, matcher_options, unit, reason in _E_WHITELIST:
    WHITELIST.append(entry(
        file_rel, panel_id, 'e',
        {
            'kind': 'unit',
            'scope': scope,
            'matcher_id': matcher_id,
            'matcher_options': matcher_options,
            'value': unit,
        },
        reason,
    ))


BANNED_UNITS = {'lengthkm', 'lengthmi', 'short', 'kwatth'}
NUMERIC_TYPES = {
    'int', 'integer', 'bigint', 'smallint', 'numeric', 'decimal', 'real', 'float',
}
DASHBOARD_GLOBS = [
    'grafana/dashboards/zh-cn/*.json',
    'grafana/dashboards/internal/*.json',
]
SQL_INSTALL_GLOB = 'sql/install-*.sql'
K_BASELINE_PATH = 'scripts/dashboard-lint-baseline.json'
K_BASELINE_VERSION = 1
K_STATES = ('PRESENT', 'ABSENT', 'DYNAMIC', 'UNKNOWN')
REPORT_RULES = {'n', 'q', 'r'}

# j 的“整串”通用白名单。这里只放跨 dashboard 稳定成立的类别；具体历史例外仍进入
# WHITELIST，并继续受“本次未命中即过期”的约束。
VISIBLE_TEXT_EXACT_ALLOWLIST = {
    # 单位：Grafana 有些字段只显示括号中的单位，语义仍完整。
    'km', 'km/h', 'wh/km', 'kwh', 'kwh/km', '%', 'v', 'a', 'kw', 'min', 'h', '(km)',
    # 领域/技术术语。
    'soc', 'vin', 'ac', 'dc', 'lfp', 'api', 'ip', 'url', 'ota', 'tpms',
    'autopilot', 'fsd',
    # 品牌/专名：不应机械翻译。
    'tesla', 'teslamate', 'grafana', 'openstreetmap', 'google maps', '高德地图',
}
# 设计取舍：j 只把“至少出现一个 CJK 字符”当作已汉化的低成本信号；因此像
# “Battery Health中”这种中英混排会通过。完整翻译质量留给人工审校，避免静态规则误伤专名。
CJK_RE = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
GRAFANA_PLACEHOLDER_RE = re.compile(
    r'^(?:\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^{}]+\}|\{\{[^{}]+\}\}|\[\[[^\[\]]+\]\])$'
)
REGEX_PLACEHOLDER_RE = re.compile(r'^/(?:\\.|[^/])+/[A-Za-z]*$')
CUSTOM_FUNCTION_FAMILY_RE = re.compile(
    r'^(?:convert_.*|.*_for_map|effective_.*|apply_.*|tou_.*|_tou_.*|audit_.*|'
    r'backfill_.*|lookup_.*|compute_.*|is_outside_.*|set_.*|list_.*|dedup_.*|'
    r'trigger_.*|uninstall_.*|wgs84_to_.*)$', re.I
)
# 与上述自研命名族碰撞的 PostgreSQL 内置函数必须放行，避免 l 把数据库标准能力误报。
POSTGRES_BUILTIN_FUNCTIONS = {
    'convert_from', 'convert_to', 'is_normalized',
    'set_bit', 'set_byte', 'set_config', 'set_masklen',
}
DASHBOARD_PATH_RE = re.compile(r'(?:^|/)d/([A-Za-z0-9_-]+)(?=/|$)')
NAIVE_DATE_COLUMNS = {'date', 'start_date', 'end_date'}
# $__time/$__timeEpoch/$__timeGroupAlias 展开后固定带 `... AS "time"`；裸 $__timeGroup
# 不带别名，本仓用法均自行写 AS，交由显式别名分支处理，不在此列。
TIME_ALIAS_MACROS = {'$__time', '$__timeepoch', '$__timegroupalias'}
REDUCE_FIELD_PANEL_TYPES = {'stat', 'gauge', 'bargauge'}
FIELD_REGEX_WRAPPED_RE = re.compile(r'^/(?P<pattern>.*)/(?P<flags>[a-zA-Z]*)$')
EDGE_REDUCE_CALCS = {'last', 'lastNotNull', 'first', 'firstNotNull'}

Token = namedtuple('Token', 'kind value start end')
SqlContext = namedtuple('SqlContext', 'sql target_ref target_path')
PAYLOAD_LITERAL_RE = re.compile(r'^\$\{payload\.[^}]+\}$', re.I)
DOLLAR_TAG_RE = re.compile(r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$')


def tokenize_sql(sql):
    """一次 PostgreSQL-lite 扫描：返回去注释的代码 token 流和字符串字面量列表。

    支持标准/E 单引号字符串、dollar-quote、双引号标识符、-- 注释和可嵌套块注释。
    字符串在代码流中保留为有类型 token，供 cast 结构检查；b 使用单独的内容列表。
    """
    tokens = []
    literals = []
    i = 0
    n = len(sql)

    def scan_single_quote(quote_pos, escape_backslash, token_start):
        j = quote_pos + 1
        buf = []
        while j < n:
            if sql[j] == "'":
                if j + 1 < n and sql[j + 1] == "'":
                    buf.append("'")
                    j += 2
                    continue
                return ''.join(buf), j + 1
            if escape_backslash and sql[j] == '\\' and j + 1 < n:
                buf.extend((sql[j], sql[j + 1]))
                j += 2
                continue
            buf.append(sql[j])
            j += 1
        return ''.join(buf), n

    while i < n:
        c = sql[i]

        if c.isspace():
            i += 1
            continue

        if sql.startswith('--', i):
            newline = sql.find('\n', i + 2)
            i = n if newline == -1 else newline + 1
            continue

        if sql.startswith('/*', i):
            depth = 1
            i += 2
            while i < n and depth:
                if sql.startswith('/*', i):
                    depth += 1
                    i += 2
                elif sql.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        if c in 'Ee' and i + 1 < n and sql[i + 1] == "'" and (
            i == 0 or not (sql[i - 1].isalnum() or sql[i - 1] in '_$')
        ):
            value, end = scan_single_quote(i + 1, True, i)
            tokens.append(Token('string', value, i, end))
            literals.append(value)
            i = end
            continue

        if c == "'":
            value, end = scan_single_quote(i, False, i)
            tokens.append(Token('string', value, i, end))
            literals.append(value)
            i = end
            continue

        if c == '$':
            tag_match = DOLLAR_TAG_RE.match(sql, i)
            if tag_match:
                tag = tag_match.group(0)
                content_start = tag_match.end()
                close = sql.find(tag, content_start)
                end = n if close == -1 else close + len(tag)
                value = sql[content_start:] if close == -1 else sql[content_start:close]
                tokens.append(Token('string', value, i, end))
                literals.append(value)
                i = end
                continue
            if i + 1 < n and sql[i + 1] == '{':
                close = sql.find('}', i + 2)
                end = n if close == -1 else close + 1
                tokens.append(Token('variable', sql[i:end], i, end))
                i = end
                continue
            m = re.match(r'\$[A-Za-z_][A-Za-z0-9_]*', sql[i:])
            if m:
                end = i + len(m.group(0))
                tokens.append(Token('variable', m.group(0), i, end))
                i = end
                continue

        if c == '"':
            j = i + 1
            buf = []
            while j < n:
                if sql[j] == '"':
                    if j + 1 < n and sql[j + 1] == '"':
                        buf.append('"')
                        j += 2
                        continue
                    j += 1
                    break
                buf.append(sql[j])
                j += 1
            tokens.append(Token('quoted_identifier', ''.join(buf), i, j))
            i = j
            continue

        if c.isalpha() or c == '_' or ord(c) >= 128:
            j = i + 1
            while j < n:
                # Grafana 的 ${var} 可出现在未加引号的 SQL 标识符中，替换后才交给 PostgreSQL。
                if sql.startswith('${', j):
                    close = sql.find('}', j + 2)
                    if close != -1:
                        j = close + 1
                        continue
                if sql[j].isalnum() or sql[j] in '_$' or ord(sql[j]) >= 128:
                    j += 1
                    continue
                break
            tokens.append(Token('identifier', sql[i:j], i, j))
            i = j
            continue

        if c.isdigit():
            j = i + 1
            while j < n and (sql[j].isalnum() or sql[j] in '._'):
                j += 1
            tokens.append(Token('number', sql[i:j], i, j))
            i = j
            continue

        operator = next((op for op in ('::', '<=', '>=', '<>', '!=', '||', '->>') if sql.startswith(op, i)), None)
        if operator:
            tokens.append(Token('symbol', operator, i, i + len(operator)))
            i += len(operator)
            continue

        tokens.append(Token('symbol', c, i, i + 1))
        i += 1

    return tokens, literals


def identifier_value(token):
    if token.kind in ('identifier', 'quoted_identifier'):
        return token.value.lower()
    return None


def token_is(token, value):
    ident = identifier_value(token)
    return ident == value.lower() if ident is not None else token.value.lower() == value.lower()


def has_sql_clause(tokens, first, second):
    """只在代码关键字中识别两段式 SQL 子句，且只认最外层查询（括号深度 0）；
    字符串、引号标识符、CTE 主体/子查询内的同名子句均不计。"""
    depths = token_depths(tokens)
    return any(
        depths[index] == 0 and depths[index + 1] == 0
        and left.kind == right.kind == 'identifier'
        and left.value.lower() == first
        and right.value.lower() == second
        for index, (left, right) in enumerate(zip(tokens, tokens[1:]))
    )


def matching_paren(tokens, open_index):
    depth = 0
    for index in range(open_index, len(tokens)):
        if tokens[index].value == '(':
            depth += 1
        elif tokens[index].value == ')':
            depth -= 1
            if depth == 0:
                return index
    return None


def strip_outer_parens(tokens):
    result = list(tokens)
    while len(result) >= 2 and result[0].value == '(':
        close = matching_paren(result, 0)
        if close != len(result) - 1:
            break
        result = result[1:-1]
    return result


def split_top_level_tokens(tokens, separator=','):
    parts = []
    start = 0
    depth = 0
    for index, token in enumerate(tokens):
        if token.value == '(':
            depth += 1
        elif token.value == ')':
            depth -= 1
        elif depth == 0 and token.value.lower() == separator.lower():
            parts.append(tokens[start:index])
            start = index + 1
    parts.append(tokens[start:])
    return parts


def find_function_calls(tokens, name):
    """返回 (参数 token, 函数名 index, 右括号 index)，包含嵌套调用。"""
    calls = []
    for index in range(len(tokens) - 1):
        if identifier_value(tokens[index]) != name.lower() or tokens[index + 1].value != '(':
            continue
        close = matching_paren(tokens, index + 1)
        if close is not None:
            calls.append((tokens[index + 2:close], index, close))
    return calls


def function_call_names(tokens):
    """复用 token 流提取所有调用名；SQL 关键字即使形似调用，也过不了 l 的命名模式。"""
    return {
        identifier_value(tokens[index])
        for index in range(len(tokens) - 1)
        if identifier_value(tokens[index]) is not None and tokens[index + 1].value == '('
    }


def installed_function_names():
    """从 install SQL 的 CREATE [OR REPLACE] FUNCTION 自动提取项目函数名。"""
    names = set()
    for path in sorted(glob.glob(SQL_INSTALL_GLOB)):
        with open(path, encoding='utf-8') as handle:
            tokens, _ = tokenize_sql(handle.read())
        index = 0
        while index < len(tokens):
            if identifier_value(tokens[index]) != 'create':
                index += 1
                continue
            cursor = index + 1
            if cursor + 1 < len(tokens) and identifier_value(tokens[cursor]) == 'or' and identifier_value(tokens[cursor + 1]) == 'replace':
                cursor += 2
            if cursor >= len(tokens) or identifier_value(tokens[cursor]) != 'function':
                index += 1
                continue
            cursor += 1
            parts = []
            while cursor < len(tokens):
                ident = identifier_value(tokens[cursor])
                if ident is None:
                    break
                parts.append(ident)
                if cursor + 1 >= len(tokens) or tokens[cursor + 1].value != '.':
                    break
                cursor += 2
            if parts:
                names.add(parts[-1])
            index = cursor + 1
    return names


def derived_custom_function_prefixes(function_names):
    """从 install SQL 已定义函数自动派生首段命名族前缀，显式族清单作为稳定下限。"""
    prefixes = set()
    for name in function_names:
        match = re.match(r'^_?[a-z0-9]+_', name, re.I)
        if match:
            prefixes.add(match.group(0).lower())
    return prefixes


def looks_like_custom_function(name, derived_prefixes):
    lowered = name.lower()
    if lowered in POSTGRES_BUILTIN_FUNCTIONS:
        return False
    return (
        CUSTOM_FUNCTION_FAMILY_RE.fullmatch(lowered) is not None
        or any(lowered.startswith(prefix) for prefix in derived_prefixes)
    )


def exact_function_args(tokens, name):
    expr = strip_outer_parens(tokens)
    calls = find_function_calls(expr, name)
    if not calls:
        return None
    args, start, close = calls[0]
    if start == 0 and close == len(expr) - 1:
        return split_top_level_tokens(args)
    return None


def is_speed_expression(tokens):
    expr = strip_outer_parens(tokens)
    if len(expr) == 1:
        return identifier_value(expr[0]) == 'speed'
    if len(expr) == 3 and expr[1].value == '.':
        return identifier_value(expr[0]) is not None and identifier_value(expr[2]) == 'speed'
    return False


def avg_speed_calls(tokens):
    matches = []
    for args, start, close in find_function_calls(tokens, 'avg'):
        parts = split_top_level_tokens(args)
        if len(parts) == 1 and is_speed_expression(parts[0]):
            matches.append((start, close))
    return matches


def has_group_by_speed_bin(tokens):
    for index in range(len(tokens) - 2):
        if identifier_value(tokens[index]) != 'group' or identifier_value(tokens[index + 1]) != 'by':
            continue
        depth = 0
        for token in tokens[index + 2:]:
            if token.value == '(':
                depth += 1
            elif token.value == ')':
                depth -= 1
            elif depth == 0 and identifier_value(token) in {'having', 'order', 'limit', 'union'}:
                break
            elif identifier_value(token) == 'speed_bin':
                return True
    return False


def is_now_call(tokens):
    return exact_function_args(tokens, 'now') == [[]]


def string_arg_equals(tokens, expected):
    expr = strip_outer_parens(tokens)
    return len(expr) == 1 and expr[0].kind == 'string' and expr[0].value.lower() == expected.lower()


def is_timezone_utc_expression(tokens):
    args = exact_function_args(tokens, 'timezone')
    return args is not None and len(args) == 2 and string_arg_equals(args[0], 'UTC')


def date_trunc_aliases(tokens):
    aliases = set()
    for args, _, close in find_function_calls(tokens, 'date_trunc'):
        parts = split_top_level_tokens(args)
        if len(parts) != 3:
            continue
        if not is_timezone_utc_expression(parts[1]) or not string_arg_equals(parts[2], '$__timezone'):
            continue
        alias_index = close + 1
        if alias_index < len(tokens) and identifier_value(tokens[alias_index]) == 'as':
            alias_index += 1
        if alias_index < len(tokens) and identifier_value(tokens[alias_index]) is not None:
            aliases.add(identifier_value(tokens[alias_index]))
    return aliases


def is_date_trunc_alias_expression(arg_tokens, all_tokens):
    expr = strip_outer_parens(arg_tokens)
    return len(expr) == 1 and identifier_value(expr[0]) in date_trunc_aliases(all_tokens)


def settings_car_id_matches(tokens):
    matches = []
    for index, token in enumerate(tokens):
        if identifier_value(token) != 'from':
            continue
        cursor = index + 1
        names = []
        if cursor >= len(tokens) or identifier_value(tokens[cursor]) is None:
            continue
        names.append(identifier_value(tokens[cursor]))
        cursor += 1
        while cursor + 1 < len(tokens) and tokens[cursor].value == '.' and identifier_value(tokens[cursor + 1]) is not None:
            names.append(identifier_value(tokens[cursor + 1]))
            cursor += 2
        if names[-1] != 'settings':
            continue
        end = next((j for j in range(cursor, len(tokens)) if tokens[j].value == ';'), len(tokens))
        where = next((j for j in range(cursor, end) if identifier_value(tokens[j]) == 'where'), None)
        if where is None:
            continue
        for j in range(where + 1, end - 2):
            if identifier_value(tokens[j]) != 'id':
                continue
            if tokens[j + 1].value == '=' and tokens[j + 2].kind == 'variable' and tokens[j + 2].value.lower() == '$car_id':
                matches.append((index, j + 2))
    return matches


def payload_literal(tokens):
    expr = strip_outer_parens(tokens)
    return len(expr) == 1 and expr[0].kind == 'string' and PAYLOAD_LITERAL_RE.match(expr[0].value)


def numeric_type(tokens):
    expr = strip_outer_parens(tokens)
    if not expr or identifier_value(expr[0]) is None:
        return None
    first = identifier_value(expr[0])
    if first == 'double' and len(expr) > 1 and identifier_value(expr[1]) == 'precision':
        return 'double precision'
    if first in NUMERIC_TYPES:
        return first
    return None


def payload_cast_matches(tokens):
    matches = []
    for index, token in enumerate(tokens):
        if token.kind != 'string' or not PAYLOAD_LITERAL_RE.match(token.value):
            continue
        if index + 2 < len(tokens) and tokens[index + 1].value == '::' and numeric_type(tokens[index + 2:]):
            matches.append((index, index + 2))

    for args, start, close in find_function_calls(tokens, 'cast'):
        depth = 0
        as_index = None
        for index, token in enumerate(args):
            if token.value == '(':
                depth += 1
            elif token.value == ')':
                depth -= 1
            elif depth == 0 and identifier_value(token) == 'as':
                as_index = index
        if as_index is None:
            continue
        if payload_literal(args[:as_index]) and numeric_type(args[as_index + 1:]):
            matches.append((start, close))
    return matches


GRAFANA_VARIABLE_RE = re.compile(
    r'\$(?:\{[A-Za-z_][A-Za-z0-9_]*(?::[^{}]+)?\}|[A-Za-z_][A-Za-z0-9_]*)'
)
RAW_SQL_VARIABLE_RE = re.compile(
    r'^\s*\$\{[A-Za-z_][A-Za-z0-9_]*:raw\}\s*;?\s*$', re.I
)


class FieldContract:
    """面板某一阶段的字段抽象；dynamic_patterns 中 None 表示任意运行时字段名。"""

    def __init__(
        self, fields=None, dynamic_patterns=None, dynamic_reasons=None, unknown_reasons=None,
        variable_domains=None, pure_variable_reasons=None,
    ):
        self.fields = set(fields or ())
        self.dynamic_patterns = set(dynamic_patterns or ())
        self.dynamic_reasons = set(dynamic_reasons or ())
        self.unknown_reasons = set(unknown_reasons or ())
        self.variable_domains = dict(variable_domains or {})
        self.pure_variable_reasons = set(pure_variable_reasons or ())

    def copy(self):
        return FieldContract(
            self.fields, self.dynamic_patterns, self.dynamic_reasons, self.unknown_reasons,
            self.variable_domains, self.pure_variable_reasons,
        )

    def merge(self, other):
        self.fields.update(other.fields)
        self.dynamic_patterns.update(other.dynamic_patterns)
        self.dynamic_reasons.update(other.dynamic_reasons)
        self.unknown_reasons.update(other.unknown_reasons)
        self.variable_domains.update(other.variable_domains)
        self.pure_variable_reasons.update(other.pure_variable_reasons)
        return self


def grafana_variable_name(token):
    value = token[2:-1].split(':', 1)[0] if token.startswith('${') else token[1:]
    return value


def field_template_patterns(field, variable_domains=None):
    """返回字段模板可能匹配的正则；纯变量不可枚举时以 None 表示。"""
    matches = list(GRAFANA_VARIABLE_RE.finditer(field))
    if not matches:
        return None, False
    variable_domains = variable_domains or {}
    pure_variable = len(matches) == 1 and matches[0].span() == (0, len(field))
    if pure_variable:
        name = grafana_variable_name(matches[0].group(0))
        options = variable_domains.get(name)
        if options is None:
            return {None}, True
        return {'^' + re.escape(value) + '$' for value in options}, False

    parts = []
    cursor = 0
    for match in matches:
        parts.append(re.escape(field[cursor:match.start()]))
        options = variable_domains.get(grafana_variable_name(match.group(0)))
        if options is None:
            parts.append(r'.+')
        else:
            parts.append('(?:' + '|'.join(re.escape(value) for value in options) + ')')
        cursor = match.end()
    parts.append(re.escape(field[cursor:]))
    return {'^' + ''.join(parts) + '$'}, False


def field_template_regex(field):
    """兼容调用方：非纯变量模板返回单个形状正则。"""
    patterns, _ = field_template_patterns(field)
    if not patterns or None in patterns:
        return None
    return next(iter(patterns))


def add_contract_field(contract, field, reason):
    if not isinstance(field, str) or not field:
        return
    patterns, unbounded_pure_variable = field_template_patterns(
        field, contract.variable_domains
    )
    if patterns is None:
        contract.fields.add(field)
    else:
        contract.dynamic_patterns.update(patterns)
        contract.dynamic_reasons.add(f"{reason}: {field}")
        if unbounded_pure_variable:
            warning = f"纯变量模板 {field!r} 不可枚举，任意 matcher 只能判为 DYNAMIC"
            contract.pure_variable_reasons.add(warning)
            contract.dynamic_reasons.add(warning)


def dynamic_contract_matches(contract, matcher):
    if None in contract.dynamic_patterns:
        return True
    return any(re.fullmatch(pattern, matcher) for pattern in contract.dynamic_patterns)


def intersect_dynamic_patterns(patterns, filter_pattern):
    """把 fullmatch 动态域与 Grafana/Python search 过滤器做正则交集。"""
    intersected = set()
    for pattern in patterns:
        source_pattern = r'[\s\S]*' if pattern is None else pattern
        intersected.add(
            f'(?={source_pattern})(?=[\\s\\S]*(?:{filter_pattern}))[\\s\\S]*'
        )
    return intersected


def trim_select_expression(expression):
    result = list(expression)
    while result and result[-1].value == ';':
        result.pop()
    return [token for token in result if identifier_value(token) not in {'distinct', 'all'}]


IMPLICIT_ALIAS_FORBIDDEN = {
    'all', 'and', 'asc', 'between', 'case', 'desc', 'distinct', 'else', 'end',
    'false', 'filter', 'from', 'in', 'is', 'like', 'not', 'null', 'or', 'over',
    'then', 'true', 'when', 'where', 'within',
}
IMPLICIT_ALIAS_OPERATORS = {
    '.', '::', '+', '-', '*', '/', '%', '^', '=', '<', '>', '<=', '>=', '<>',
    '!=', '||', '->', '->>', '#>', '#>>', '~', '!~', '~*', '!~*',
}


def select_expression_alias(expression):
    """返回 (alias, 去别名表达式, alias_kind)，支持 AS 与 PostgreSQL 裸别名。"""
    expr_depth = 0
    for offset, current in enumerate(expression[:-1]):
        if current.value == '(':
            expr_depth += 1
        elif current.value == ')':
            expr_depth -= 1
        elif expr_depth == 0 and identifier_value(current) == 'as':
            alias_token = expression[offset + 1]
            if alias_token.kind == 'quoted_identifier':
                return alias_token.value, expression[:offset], 'AS'
            if alias_token.kind == 'identifier':
                return alias_token.value.lower(), expression[:offset], 'AS'

    if len(expression) < 2:
        return None, expression, None
    alias_token = expression[-1]
    alias_identifier = identifier_value(alias_token)
    if alias_token.kind not in {'identifier', 'quoted_identifier'}:
        return None, expression, None
    if alias_identifier in IMPLICIT_ALIAS_FORBIDDEN:
        return None, expression, None
    if expression[-2].value in IMPLICIT_ALIAS_OPERATORS:
        return None, expression, None
    alias = alias_token.value if alias_token.kind == 'quoted_identifier' else alias_token.value.lower()
    return alias, expression[:-1], 'implicit'


def normalize_sql_expression(expression):
    """忽略空白和未引号标识符大小写，保留字面量/引号身份。"""
    normalized = []
    for token in expression:
        value = token.value.lower() if token.kind == 'identifier' else token.value
        normalized.append(f"{token.kind}:{value}")
    return ' '.join(normalized)


def sql_field_contract(sql, target_ref='?', variable_domains=None):
    """推导 PostgreSQL 查询最终 SELECT 的列名；无法封闭证明时保守降级。"""
    contract = FieldContract(variable_domains=variable_domains)
    if RAW_SQL_VARIABLE_RE.fullmatch(sql):
        contract.dynamic_patterns.add(None)
        contract.dynamic_reasons.add(f"target {target_ref} 的整段 SQL 来自 :raw 变量")
        return contract

    try:
        tokens, _ = tokenize_sql(sql)
    except Exception as error:
        contract.unknown_reasons.add(f"target {target_ref} SQL 解析失败: {error}")
        return contract

    balance = 0
    select_index = None
    for index, token in enumerate(tokens):
        if token.value == '(':
            balance += 1
        elif token.value == ')':
            balance -= 1
            if balance < 0:
                break
        elif balance == 0 and identifier_value(token) == 'select':
            select_index = index
            break
    if balance < 0 or select_index is None:
        contract.unknown_reasons.add(f"target {target_ref} SQL 无可解析的顶层 SELECT")
        return contract

    depth = 0
    end = select_index + 1
    while end < len(tokens):
        current = tokens[end]
        if current.value == '(':
            depth += 1
        elif current.value == ')':
            depth -= 1
        elif depth == 0 and identifier_value(current) == 'from':
            break
        end += 1
    if depth != 0:
        contract.unknown_reasons.add(f"target {target_ref} SQL 括号不平衡")
        return contract

    expressions = split_top_level_tokens(tokens[select_index + 1:end])
    if not expressions:
        contract.unknown_reasons.add(f"target {target_ref} SELECT 列表为空")
        return contract

    for raw_expression in expressions:
        expression = trim_select_expression(raw_expression)
        if not expression:
            contract.unknown_reasons.add(f"target {target_ref} SELECT 含空表达式")
            continue
        alias, expression, alias_kind = select_expression_alias(expression)
        if alias is not None:
            add_contract_field(contract, alias, f"target {target_ref} {alias_kind} 别名")
            continue

        expr = strip_outer_parens(expression)
        if expr and expr[-1].value == '*' and (
            len(expr) == 1 or (len(expr) == 3 and expr[1].value == '.')
        ):
            contract.unknown_reasons.add(f"target {target_ref} SELECT * 依赖数据库 schema")
            continue
        if len(expr) == 1 and expr[0].kind in {'identifier', 'quoted_identifier'}:
            value = expr[0].value if expr[0].kind == 'quoted_identifier' else expr[0].value.lower()
            add_contract_field(contract, value, f"target {target_ref} 变量列名")
            continue
        if (
            len(expr) == 3 and expr[1].value == '.'
            and expr[0].kind in {'identifier', 'quoted_identifier'}
            and expr[2].kind in {'identifier', 'quoted_identifier'}
        ):
            value = expr[2].value if expr[2].kind == 'quoted_identifier' else expr[2].value.lower()
            add_contract_field(contract, value, f"target {target_ref} 变量列名")
            continue
        # Grafana 时间宏无显式 AS 时自带隐式别名 "time"，必须先于下面的默认列名兜底识别，
        # 否则会被误判成不可预测的 ?column?（宏名是 variable token，不是 identifier）。
        if (
            expr and expr[0].kind == 'variable'
            and expr[0].value.lower() in TIME_ALIAS_MACROS
            and len(expr) > 1 and expr[1].value == '('
        ):
            add_contract_field(contract, 'time', f"target {target_ref} Grafana 时间宏隐式别名")
            continue
        # PostgreSQL 对未起别名的函数/CASE 使用稳定的函数名/"case" 作为列名。
        first = identifier_value(expr[0])
        if first and (first == 'case' or (len(expr) > 1 and expr[1].value == '(')):
            add_contract_field(contract, first, f"target {target_ref} 默认列名")
            continue
        # 其余未命名表达式由 PostgreSQL 报为 ?column?，名称本身仍是封闭的。
        add_contract_field(contract, '?column?', f"target {target_ref} 默认表达式列名")

    # 旧式 time_series 三列语义：metric 列的数据值会成为系列字段名。
    return contract


def target_field_contract(target, panel_index, panel_cache, stack, variable_domains=None, pretransform_cache=None):
    ref_id = target.get('refId', '?')
    raw_sql = target.get('rawSql')
    if isinstance(raw_sql, str) and raw_sql.strip():
        contract = sql_field_contract(raw_sql, ref_id, variable_domains)
        result_format = target.get('format') or target.get('resultFormat')
        if result_format == 'time_series' and any(name.lower() == 'metric' for name in contract.fields):
            contract.dynamic_patterns.add(None)
            contract.dynamic_reasons.add(
                f"target {ref_id} 为 time_series，metric 数据值会成为系列字段名"
            )
        return contract

    source_panel_id = target.get('panelId')
    datasource = target.get('datasource') or {}
    datasource_uid = datasource.get('uid') if isinstance(datasource, dict) else datasource
    if source_panel_id is not None and datasource_uid == '-- Dashboard --':
        source = panel_index.get(source_panel_id)
        if source is None:
            return FieldContract(unknown_reasons={f"dashboard datasource 引用不存在的 panel {source_panel_id}"})
        # Grafana 的 DashboardDatasource 默认拿源面板 SceneDataTransformer *之前* 的原始查询
        # 结果，只有 target.withTransforms=true 才会拿变换后的结果（源码见 grafana/grafana
        # public/app/plugins/datasource/dashboard/datasource.ts：
        # `if (!query.withTransforms && sourceDataProvider instanceof SceneDataTransformer)
        #    sourceDataProvider = sourceDataProvider.state.$data;`）。
        # 本仓没有任何 target 设置 withTransforms，默认必须用「预变换」契约，否则源面板自身的
        # organize/exclude 会被误当成对下游可见——曾把 locations.json 三个按维度取数的面板、
        # trip.json joinByField 依赖的 metric/value 列误判成 ABSENT。
        if target.get('withTransforms') is True:
            return panel_field_contract(
                source, panel_index, panel_cache, stack, variable_domains, pretransform_cache
            ).copy()
        cache = pretransform_cache if pretransform_cache is not None else {}
        return panel_pretransform_field_contract(
            source, panel_index, panel_cache, cache, stack, variable_domains
        ).copy()

    return FieldContract(unknown_reasons={f"target {ref_id} 没有可静态解释的 rawSql"})


def panel_pretransform_field_contract(panel, panel_index, panel_cache, pretransform_cache, stack=(), variable_domains=None):
    """面板 targets 合并后、面板自身 transformations 应用前的契约；dashboard 数据源默认取的
    正是这个阶段（见上面 target_field_contract 内的源码引用）。"""
    panel_id = panel.get('id', '?')
    if panel_id in pretransform_cache:
        return pretransform_cache[panel_id]
    if panel_id in stack:
        return FieldContract(unknown_reasons={f"dashboard datasource panel 引用成环: {panel_id}"})

    contract = FieldContract(variable_domains=variable_domains)
    targets = [target for target in (panel.get('targets') or []) if isinstance(target, dict)]
    if not targets:
        contract.unknown_reasons.add(f"panel {panel_id} 没有 target")
    for target in targets:
        contract.merge(target_field_contract(
            target, panel_index, panel_cache, stack + (panel_id,), variable_domains, pretransform_cache
        ))
    pretransform_cache[panel_id] = contract
    return contract


def calc_operand_names(options):
    binary = options.get('binary') or {}
    names = []
    for side in ('left', 'right'):
        operand = binary.get(side)
        if isinstance(operand, dict):
            matcher = operand.get('matcher') or {}
            if matcher.get('id') == 'byName' and isinstance(matcher.get('options'), str):
                names.append(matcher['options'])
        elif isinstance(operand, str) and not re.fullmatch(r'-?\d+(?:\.\d+)?', operand):
            names.append(operand)
    return names


def transform_field_contract(contract, transformation):
    result = contract.copy()
    transform_id = transformation.get('id')
    options = transformation.get('options') or {}

    if transform_id in {'merge', 'seriesToColumns', 'joinByField', 'sortBy', 'convertFieldType', 'configFromData'}:
        return result

    if transform_id == 'organize':
        excluded = {name for name, value in (options.get('excludeByName') or {}).items() if value is True}
        included = {name for name, value in (options.get('includeByName') or {}).items() if value is True}
        fields = result.fields - excluded
        if included:
            fields &= included
        renames = options.get('renameByName') or {}
        result.fields = {renames.get(name) or name for name in fields}
        rewritten_patterns = set()
        if included:
            for name in included:
                if name in excluded or not dynamic_contract_matches(contract, name):
                    continue
                renamed = renames.get(name) or name
                rewritten_patterns.add('^' + re.escape(renamed) + '$')
            result.dynamic_patterns = rewritten_patterns
            return result
        for pattern in result.dynamic_patterns:
            if pattern is None:
                rewritten_patterns.add(None)
                continue
            matched_keys = {name for name in set(excluded) | set(renames) | included if re.fullmatch(pattern, name)}
            if not matched_keys:
                rewritten_patterns.add(pattern)
                continue
            if not any(pattern == '^' + re.escape(name) + '$' for name in matched_keys):
                rewritten_patterns.add(pattern)
            for name in matched_keys:
                if name in excluded or (included and name not in included):
                    continue
                renamed = renames.get(name) or name
                rewritten_patterns.add('^' + re.escape(renamed) + '$')
        result.dynamic_patterns = rewritten_patterns
        # 对无法对应到显式字段名的动态来源继续保守保留；能对应的则同步 exclude/rename。
        return result

    if transform_id == 'filterFieldsByName':
        include = options.get('include') or {}
        names = include.get('names')
        pattern = include.get('pattern')
        if isinstance(names, list):
            wanted = {name for name in names if isinstance(name, str)}
            result.fields &= wanted
            possible_dynamic = {
                '^' + re.escape(name) + '$'
                for name in wanted if dynamic_contract_matches(contract, name)
            }
            result.dynamic_patterns = possible_dynamic
            return result
        if isinstance(pattern, str):
            try:
                regex = re.compile(pattern)
            except re.error as error:
                result.unknown_reasons.add(f"filterFieldsByName 正则解析失败: {error}")
                return result
            result.fields = {name for name in result.fields if regex.search(name)}
            result.dynamic_patterns = intersect_dynamic_patterns(
                result.dynamic_patterns, pattern
            )
            return result
        result.unknown_reasons.add("filterFieldsByName 缺少可解释的 include")
        return result

    if transform_id == 'calculateField':
        alias = options.get('alias')
        if not alias:
            binary = options.get('binary') or {}
            left = binary.get('left')
            right = binary.get('right')
            def operand_label(value):
                if isinstance(value, dict):
                    return ((value.get('matcher') or {}).get('options') or value.get('fixed'))
                return value
            left_label = operand_label(left)
            right_label = operand_label(right)
            if left_label is not None and right_label is not None:
                alias = f"{left_label} {binary.get('operator', '?')} {right_label}"
        operands = calc_operand_names(options)
        missing = [name for name in operands if name not in result.fields]
        if options.get('replaceFields') is True:
            result.fields.clear()
            result.dynamic_patterns.clear()
        if isinstance(alias, str) and alias:
            if not missing:
                add_contract_field(result, alias, "calculateField 变量 alias")
            elif any(dynamic_contract_matches(contract, name) for name in missing):
                patterns, _ = field_template_patterns(alias, result.variable_domains)
                result.dynamic_patterns.update(
                    patterns or {'^' + re.escape(alias) + '$'}
                )
                result.dynamic_reasons.add(f"calculateField {alias!r} 的输入字段动态")
            else:
                result.unknown_reasons.add(
                    f"calculateField {alias!r} 的输入字段无法确认: {', '.join(missing)}"
                )
        else:
            result.unknown_reasons.add("calculateField 无法确定输出 alias")
        return result

    if transform_id == 'groupBy':
        grouped = FieldContract(
            dynamic_patterns=result.dynamic_patterns,
            dynamic_reasons=result.dynamic_reasons,
            unknown_reasons=result.unknown_reasons,
            variable_domains=result.variable_domains,
            pure_variable_reasons=result.pure_variable_reasons,
        )
        for name, config in (options.get('fields') or {}).items():
            if name not in result.fields:
                continue
            if config.get('operation') == 'groupby':
                grouped.fields.add(name)
            elif config.get('operation') == 'aggregate':
                for aggregation in config.get('aggregations') or ():
                    grouped.fields.add(f"{name} ({aggregation})")
        return grouped

    if transform_id == 'groupingToMatrix':
        matrix = FieldContract(
            dynamic_patterns={None},
            dynamic_reasons=result.dynamic_reasons | {
                f"groupingToMatrix 的列名来自 {options.get('columnField')!r} 数据值"
            },
            unknown_reasons=result.unknown_reasons,
            variable_domains=result.variable_domains,
            pure_variable_reasons=result.pure_variable_reasons,
        )
        row_field = options.get('rowField')
        if row_field in result.fields:
            matrix.fields.add(row_field)
        elif isinstance(row_field, str):
            matrix.unknown_reasons.add(f"groupingToMatrix rowField {row_field!r} 无法确认")
        return matrix

    if transform_id == 'renameByRegex':
        try:
            regex = re.compile(options.get('regex', ''))
            replacement = options.get('renamePattern', '')
            # Grafana 使用 $1；Python 使用 \g<1>。
            replacement = re.sub(r'\$(\d+)', r'\\g<\1>', replacement)
            result.fields = {regex.sub(replacement, name) for name in result.fields}
        except (re.error, TypeError) as error:
            result.unknown_reasons.add(f"renameByRegex 解析失败: {error}")
        return result

    if transform_id == 'reduce':
        return result

    # regression 等现存但字段命名由插件版本决定的变换，不制造 ABSENT 假阳性。
    result.unknown_reasons.add(f"transformation {transform_id!r} 的字段流无法封闭解释")
    return result


def panel_field_contract(panel, panel_index, panel_cache, stack=(), variable_domains=None, pretransform_cache=None):
    panel_id = panel.get('id', '?')
    if panel_id in panel_cache:
        return panel_cache[panel_id]
    if panel_id in stack:
        return FieldContract(unknown_reasons={f"dashboard datasource panel 引用成环: {panel_id}"})

    contract = FieldContract(variable_domains=variable_domains)
    targets = [target for target in (panel.get('targets') or []) if isinstance(target, dict)]
    if not targets:
        contract.unknown_reasons.add(f"panel {panel_id} 没有 target")
    for target in targets:
        contract.merge(target_field_contract(
            target, panel_index, panel_cache, stack + (panel_id,), variable_domains, pretransform_cache
        ))
    for transformation in panel.get('transformations') or []:
        if isinstance(transformation, dict):
            contract = transform_field_contract(contract, transformation)
    panel_cache[panel_id] = contract
    return contract


def classify_contract_matcher(contract, matcher):
    if matcher in contract.fields:
        return 'PRESENT'
    if dynamic_contract_matches(contract, matcher):
        return 'DYNAMIC'
    if contract.unknown_reasons:
        return 'UNKNOWN'
    return 'ABSENT'


def parse_grafana_field_regex(value):
    """reduceOptions.fields 是 JS 正则；本仓一律写 /pattern/flags，裸字符串按整串正则兜底。"""
    match = FIELD_REGEX_WRAPPED_RE.match(value)
    pattern, flags_str = (match.group('pattern'), match.group('flags')) if match else (value, '')
    flags = re.IGNORECASE if 'i' in flags_str else 0
    try:
        return re.compile(pattern, flags)
    except re.error:
        return None


def panel_byname_rename_map(panel):
    """byName override 的 displayName 链；同名 override 出现多次时最后一个生效，
    与 Grafana 按数组顺序逐条应用 fieldConfig.overrides 的行为一致。"""
    rename_map = {}
    field_config = panel.get('fieldConfig', {}) or {}
    for override in field_config.get('overrides', []) or []:
        matcher = override.get('matcher') or {}
        if matcher.get('id') != 'byName':
            continue
        original = matcher.get('options')
        if not isinstance(original, str):
            continue
        for prop in override.get('properties', []) or []:
            if prop.get('id') == 'displayName' and isinstance(prop.get('value'), str) and prop.get('value'):
                rename_map[original] = prop['value']
    return rename_map


def reduce_field_display_names(contract, rename_map):
    """把契约字段套用 byName displayName override，得到 (最终显示名集合, 曾被改名的原始别名集合)。"""
    finals = set()
    renamed_originals = set()
    for name in contract.fields:
        final = rename_map.get(name, name)
        finals.add(final)
        if final != name:
            renamed_originals.add(name)
    return finals, renamed_originals


def classify_reduce_fields_matcher(contract, rename_map, fields_pattern):
    """规则 w 核心判定。

    返回 (verdict, detail)：
      SKIP_UNKNOWN / SKIP_DYNAMIC — 契约整体没有任何具体字段，无法判定，跳过（--verbose-k 计数）
      REGEX_ERROR   — reduceOptions.fields 本身不是合法正则
      MATCH         — 正则命中至少一个最终显示名，绿
      STALE_ALIAS   — 正则只命中「改名前」的原始别名、命中不了改名后的最终显示名（47 案）
      NO_MATCH      — 正则命中不了任何原始别名或最终显示名
    """
    if not contract.fields and contract.unknown_reasons:
        return 'SKIP_UNKNOWN', sorted(contract.unknown_reasons)
    if not contract.fields and contract.dynamic_patterns:
        return 'SKIP_DYNAMIC', sorted(contract.dynamic_reasons)
    regex = parse_grafana_field_regex(fields_pattern)
    if regex is None:
        return 'REGEX_ERROR', fields_pattern
    finals, renamed_originals = reduce_field_display_names(contract, rename_map)
    if any(regex.search(name) for name in finals):
        return 'MATCH', sorted(finals)
    if any(regex.search(name) for name in renamed_originals):
        return 'STALE_ALIAS', sorted(renamed_originals)
    return 'NO_MATCH', sorted(finals)


def dashboard_variable_domains(dashboard):
    """只信任 Grafana 已静态列出的 custom/interval options；query 型不可枚举。"""
    domains = {}
    variables = ((dashboard.get('templating') or {}).get('list') or [])
    for variable in variables:
        if not isinstance(variable, dict) or variable.get('type') not in {'custom', 'interval'}:
            continue
        name = variable.get('name')
        if not isinstance(name, str) or not name:
            continue
        values = []
        for option in variable.get('options') or []:
            value = option.get('value') if isinstance(option, dict) else option
            if isinstance(value, (str, int, float)) and not isinstance(value, bool):
                values.append(str(value))
        if values:
            domains[name] = tuple(sorted(set(values)))
    return domains


def mod_or_date_part_matches(tokens):
    matches = []
    for _, start, close in find_function_calls(tokens, 'mod'):
        matches.append((start, close, 'mod(...)'))
    for args, start, close in find_function_calls(tokens, 'date_part'):
        parts = split_top_level_tokens(args)
        if parts and string_arg_equals(parts[0], 'epoch'):
            matches.append((start, close, "DATE_PART('epoch', ...)"))
    return matches


def has_legacy_variable_code_token(tokens):
    """只识别代码流中相邻的 [[；注释已被 tokenizer 丢弃，字符串保留为单个 token。"""
    return any(
        left.value == '[' and right.value == '[' and left.end == right.start
        for left, right in zip(tokens, tokens[1:])
    )


def token_depths(tokens):
    depths = []
    depth = 0
    for token in tokens:
        depths.append(depth)
        if token.value == '(':
            depth += 1
        elif token.value == ')':
            depth = max(0, depth - 1)
    return depths


def in_join_on_context(tokens, index, depths):
    depth = depths[index]
    saw_on = False
    for cursor in range(index - 1, -1, -1):
        # ON (a.geofence_id = b.geofence_id) 的 ON 位于更浅一层；只跳过更深层 token。
        if depths[cursor] > depth:
            continue
        ident = identifier_value(tokens[cursor])
        if ident in {'where', 'having', 'group', 'order', 'union', 'limit'} or tokens[cursor].value == ';':
            return False
        if ident == 'on':
            saw_on = True
            continue
        if saw_on and ident == 'join':
            return True
    return False


def geofence_equality_matches(tokens):
    depths = token_depths(tokens)
    matches = []

    def is_geofence_reference(expression):
        expression = strip_outer_parens(expression)
        if len(expression) == 1:
            return identifier_value(expression[0]) == 'geofence_id'
        return (
            len(expression) == 3
            and identifier_value(expression[0]) is not None
            and expression[1].value == '.'
            and identifier_value(expression[2]) == 'geofence_id'
        )

    def operand_before(equals_index):
        for start in range(equals_index - 1, max(-1, equals_index - 8), -1):
            if is_geofence_reference(tokens[start:equals_index]):
                return start, equals_index - 1
        return None

    def operand_after(equals_index):
        for end in range(equals_index + 2, min(len(tokens), equals_index + 9) + 1):
            if is_geofence_reference(tokens[equals_index + 1:end]):
                return equals_index + 1, end - 1
        return None

    for equals_index, token in enumerate(tokens):
        if token.value != '=':
            continue
        left = operand_before(equals_index)
        if left is None:
            continue
        # JOIN 两侧用同一关联键是正常关联条件，即使外围有括号也不属于 q。
        if operand_after(equals_index) is not None:
            continue
        if not in_join_on_context(tokens, left[0], depths):
            matches.append((left[0], equals_index))
    return matches


def has_utc_timezone_after_column(tokens, column_index, window_end):
    suffix = tokens[column_index + 1:min(window_end, column_index + 6)]
    return (
        len(suffix) >= 4
        and identifier_value(suffix[0]) == 'at'
        and identifier_value(suffix[1]) == 'time'
        and identifier_value(suffix[2]) == 'zone'
        and suffix[3].kind == 'string'
        and suffix[3].value.lower() == 'utc'
    )


def naive_now_interval_matches(tokens):
    matches = []
    for _, start, close in find_function_calls(tokens, 'now'):
        if close + 2 >= len(tokens) or tokens[close + 1].value != '-' or identifier_value(tokens[close + 2]) != 'interval':
            continue
        window_start = max(0, start - 24)
        window_end = min(len(tokens), close + 10)
        naive = []
        for index in range(window_start, window_end):
            name = identifier_value(tokens[index])
            if name in NAIVE_DATE_COLUMNS and not has_utc_timezone_after_column(tokens, index, window_end):
                naive.append(name)
        if naive:
            matches.append((start, close + 2, tuple(sorted(set(naive)))))
    return matches


def visible_text_allowed(value):
    stripped = value.strip()
    if CJK_RE.search(value):
        return True
    if stripped.lower() in VISIBLE_TEXT_EXACT_ALLOWLIST:
        return True
    if not stripped or stripped.isdecimal():
        return True
    if GRAFANA_PLACEHOLDER_RE.fullmatch(stripped) or REGEX_PLACEHOLDER_RE.fullmatch(stripped):
        return True
    # 纯符号（可含数字）允许；一旦出现字母或下划线，就必须由上面的显式类别放行。
    return not any(character.isalpha() or character == '_' for character in stripped)


def output_field_matches(matcher, field):
    """Grafana 变量替换后的动态别名也视为可确定输出，如 distance_$length_unit → distance_km。"""
    if matcher == field:
        return True
    parts = []
    cursor = 0
    variable_re = re.compile(r'\$(?:\{[A-Za-z_][A-Za-z0-9_]*(?::[^{}]+)?\}|[A-Za-z_][A-Za-z0-9_]*)')
    for match in variable_re.finditer(field):
        parts.append(re.escape(field[cursor:match.start()]))
        parts.append(r'[A-Za-z0-9_]+')
        cursor = match.end()
    if not parts:
        return False
    parts.append(re.escape(field[cursor:]))
    return re.fullmatch(''.join(parts), matcher) is not None


def override_properties_hash(properties):
    """属性数组按“多重集合”规范化；属性顺序不影响键，重复属性仍会保留。"""
    canonical_properties = sorted(
        json.dumps(prop, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        for prop in (properties or [])
    )
    canonical = json.dumps(canonical_properties, ensure_ascii=False, separators=(',', ':'))
    return 'sha256:' + hashlib.sha256(canonical.encode('utf-8')).hexdigest()


def k_key(file_rel, panel_id, matcher_value, properties_hash):
    return file_rel, panel_id, matcher_value, properties_hash


def k_key_sort_key(key):
    file_rel, panel_id, matcher_value, properties_hash = key
    return file_rel, str(panel_id), matcher_value, properties_hash


def format_k_key(key, count=1):
    file_rel, panel_id, matcher_value, properties_hash = key
    count_suffix = f" × {count}" if count != 1 else ''
    return (
        f"{file_rel} :: panel {panel_id} :: k :: override byName={matcher_value!r} "
        f"propertiesHash={properties_hash}{count_suffix}"
    )


def load_k_baseline(allow_missing=False):
    if not os.path.exists(K_BASELINE_PATH):
        if allow_missing:
            return Counter()
        raise ValueError(
            f"缺少 k 基线文件 {K_BASELINE_PATH}；请显式运行 --update-baseline 创建"
        )

    try:
        with open(K_BASELINE_PATH, encoding='utf-8') as handle:
            document = json.load(handle)
    except Exception as error:
        raise ValueError(f"无法读取 k 基线文件 {K_BASELINE_PATH}: {error}") from error

    if not isinstance(document, dict) or document.get('version') != K_BASELINE_VERSION:
        raise ValueError(
            f"k 基线版本无效：期待 version={K_BASELINE_VERSION}"
        )
    entries = document.get('entries')
    if not isinstance(entries, list):
        raise ValueError("k 基线格式无效：entries 必须是数组")

    baseline = Counter()
    for index, item in enumerate(entries):
        if not isinstance(item, dict):
            raise ValueError(f"k 基线 entries[{index}] 必须是对象")
        file_rel = item.get('file')
        panel_id = item.get('panelId')
        matcher_value = item.get('matcher')
        properties_hash = item.get('propertiesHash')
        count = item.get('count')
        if (
            not isinstance(file_rel, str)
            or not isinstance(panel_id, (int, str))
            or isinstance(panel_id, bool)
            or not isinstance(matcher_value, str)
            or not isinstance(properties_hash, str)
            or not properties_hash.startswith('sha256:')
            or not isinstance(count, int)
            or isinstance(count, bool)
            or count < 1
        ):
            raise ValueError(f"k 基线 entries[{index}] 字段或 count 无效")
        key = k_key(file_rel, panel_id, matcher_value, properties_hash)
        if key in baseline:
            raise ValueError(f"k 基线含重复键（应合并 count）：{format_k_key(key)}")
        baseline[key] = count
    return baseline


def write_k_baseline(current):
    document = {
        'version': K_BASELINE_VERSION,
        'key': ['file', 'panelId', 'matcher', 'propertiesHash'],
        'entries': [
            {
                'file': key[0],
                'panelId': key[1],
                'matcher': key[2],
                'propertiesHash': key[3],
                'count': current[key],
            }
            for key in sorted(current, key=k_key_sort_key)
        ],
    }
    directory = os.path.dirname(K_BASELINE_PATH) or '.'
    with tempfile.NamedTemporaryFile(
        mode='w', encoding='utf-8', dir=directory, prefix='.dashboard-lint-baseline.', delete=False
    ) as handle:
        json.dump(document, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
        temporary_path = handle.name
    os.replace(temporary_path, K_BASELINE_PATH)


def recursive_strings(value, path=''):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f'{path}.{key}' if path else key
            yield from recursive_strings(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from recursive_strings(child, f'{path}[{index}]')
    elif isinstance(value, str):
        yield path, value


def dashboard_link_occurrences(panel):
    for path, value in recursive_strings({key: val for key, val in panel.items() if key != 'panels'}):
        if not (path.endswith('.url') or path == 'url' or path.endswith('.href') or path == 'href'):
            continue
        try:
            parsed = urlsplit(value)
        except ValueError:
            continue
        # 绝对外链（含 //host/path）不属于仓内 dashboard UID 完整性检查。
        if parsed.scheme or parsed.netloc:
            continue
        for match in DASHBOARD_PATH_RE.finditer(parsed.path):
            yield path, match.group(1), value


def config_ref_ids(panel):
    """收集同面板所有 configRefId；不下钻 row 的 child panels。"""
    refs = set()

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == 'panels':
                    continue
                if key == 'configRefId' and isinstance(child, str):
                    refs.add(child)
                else:
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(panel)
    return refs


def draw_styles(panel):
    styles = []
    field_config = panel.get('fieldConfig', {}) or {}
    defaults = field_config.get('defaults', {}) or {}
    custom = defaults.get('custom', {}) or {}
    if custom.get('drawStyle') is not None:
        styles.append(('fieldConfig.defaults.custom.drawStyle', custom.get('drawStyle')))
    for index, override in enumerate(field_config.get('overrides', []) or []):
        for prop_index, prop in enumerate(override.get('properties', []) or []):
            if prop.get('id') == 'custom.drawStyle':
                styles.append((f'fieldConfig.overrides[{index}].properties[{prop_index}]', prop.get('value')))
    return styles


def datasource_uid(value):
    if isinstance(value, dict):
        return value.get('uid')
    return value


def datasource_allowed(value):
    uid = datasource_uid(value)
    if uid in (None, ''):
        return True
    if not isinstance(uid, str):
        return False
    return uid == 'TeslaMate' or GRAFANA_PLACEHOLDER_RE.fullmatch(uid) is not None


def find_rawsql_in_panel(panel):
    """递归找 rawSql，并携带所属 target refId；不下钻 child panels。"""
    found = []

    def walk(obj, path='', target_ref=None, target_path=None):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key == 'panels':
                    continue
                child_path = f'{path}.{key}' if path else key
                if key == 'targets' and isinstance(value, list):
                    for index, target in enumerate(value):
                        ref_id = target.get('refId') if isinstance(target, dict) else None
                        walk(target, f'{child_path}[{index}]', ref_id, f'{child_path}[{index}]')
                elif key == 'rawSql' and isinstance(value, str) and value.strip():
                    found.append(SqlContext(value, target_ref, target_path))
                else:
                    walk(value, child_path, target_ref, target_path)
        elif isinstance(obj, list):
            for index, value in enumerate(obj):
                walk(value, f'{path}[{index}]', target_ref, target_path)

    walk(panel)
    return found


def whitelist_candidates(file_rel, subject, rule):
    return [
        (index, item) for index, item in enumerate(WHITELIST)
        if item['file'] == file_rel and item['subject'] == subject and item['rule'] == rule
    ]


def context_target_allowed(context, condition):
    return context.target_path is not None and context.target_ref in condition['target_refs']


def allow_a(file_rel, subject, context, tokens, used):
    for index, item in whitelist_candidates(file_rel, subject, 'a'):
        condition = item['condition']
        if condition['kind'] == 'group_by_speed_bin' and context_target_allowed(context, condition) and has_group_by_speed_bin(tokens):
            used.add(index)
            return True
    return False


def allow_d(file_rel, subject, context, arg2, tokens, used):
    for index, item in whitelist_candidates(file_rel, subject, 'd'):
        condition = item['condition']
        if not context_target_allowed(context, condition):
            continue
        if condition['kind'] == 'timezone_utc' and is_timezone_utc_expression(arg2):
            used.add(index)
            return True
        if condition['kind'] == 'date_trunc_alias' and is_date_trunc_alias_expression(arg2, tokens):
            used.add(index)
            return True
    return False


def allow_e(file_rel, subject, occurrence, used):
    for index, item in whitelist_candidates(file_rel, subject, 'e'):
        if item['condition'] == occurrence:
            used.add(index)
            return True
    return False


def allow_exact(file_rel, subject, rule, condition, used):
    """新规则沿用同一份细粒度白名单：条件必须整项相等，不能 panel 级放行。"""
    for index, item in whitelist_candidates(file_rel, subject, rule):
        if item['condition'] == condition:
            used.add(index)
            return True
    return False


def sql_snippet(sql, tokens, start, end):
    if not tokens:
        return ''
    char_start = max(0, tokens[start].start - 20)
    char_end = min(len(sql), tokens[end].end + 20)
    return sql[char_start:char_end].replace('\n', ' ')


def run_k_self_test():
    """不碰 dashboard 文件的四态与 lint 判定失败路径故障注入。"""
    present = sql_field_contract('SELECT 1 AS known', 'P')
    absent = sql_field_contract('SELECT 1 AS known', 'A')
    dynamic = target_field_contract(
        {
            'refId': 'D',
            'format': 'time_series',
            'rawSql': "SELECT now() AS time, 'driver' AS metric, 1 AS value",
        },
        {}, {}, (),
    )
    unknown = sql_field_contract('SELECT * FROM runtime_schema.table_name', 'U')
    cases = [
        ('PRESENT', classify_contract_matcher(present, 'known')),
        ('ABSENT', classify_contract_matcher(absent, 'missing')),
        ('DYNAMIC', classify_contract_matcher(dynamic, 'runtime_name')),
        ('UNKNOWN', classify_contract_matcher(unknown, 'schema_field')),
    ]
    failures = [(expected, actual) for expected, actual in cases if expected != actual]
    if failures:
        raise AssertionError(f"k 四态故障注入失败: {failures}")
    raw_dynamic = sql_field_contract('${runtime_query:raw}', 'D-raw')
    if classify_contract_matcher(raw_dynamic, 'Calls') != 'DYNAMIC':
        raise AssertionError("k :raw 动态 SQL 故障注入失败")

    bare_alias = sql_field_contract('SELECT 1 foo, (1 + 2) bar', 'bare-alias')
    if classify_contract_matcher(bare_alias, 'foo') != 'PRESENT':
        raise AssertionError("k 裸别名 SELECT expr alias 故障注入失败")
    if classify_contract_matcher(bare_alias, 'bar') != 'PRESENT':
        raise AssertionError("k 裸别名 SELECT (…) alias 故障注入失败")

    enumerable_template = sql_field_contract(
        'SELECT 1 AS "$length_unit"', 'pure-enumerable',
        {'length_unit': ('km', 'mi')},
    )
    enumerable_cases = {
        'km': 'DYNAMIC',
        'mi': 'DYNAMIC',
        'car_id': 'ABSENT',
    }
    for matcher, expected in enumerable_cases.items():
        actual = classify_contract_matcher(enumerable_template, matcher)
        if actual != expected:
            raise AssertionError(
                f"k 可枚举纯变量模板故障注入失败: {matcher} {actual} != {expected}"
            )

    include_contract = transform_field_contract(
        FieldContract(dynamic_patterns={None}),
        {'id': 'organize', 'options': {'includeByName': {'km': True}}},
    )
    if classify_contract_matcher(include_contract, 'car_id') != 'ABSENT':
        raise AssertionError("k organize.includeByName None 收窄故障注入失败")
    if classify_contract_matcher(include_contract, 'km') != 'DYNAMIC':
        raise AssertionError("k organize.includeByName None 保留故障注入失败")

    filter_contract = transform_field_contract(
        FieldContract(dynamic_patterns={None}),
        {'id': 'filterFieldsByName', 'options': {'include': {'pattern': '^km$'}}},
    )
    if classify_contract_matcher(filter_contract, 'car_id') != 'ABSENT':
        raise AssertionError("k filterFieldsByName 动态交集收窄故障注入失败")
    if classify_contract_matcher(filter_contract, 'km') != 'DYNAMIC':
        raise AssertionError("k filterFieldsByName 动态交集保留故障注入失败")

    print("k 四态故障注入：PRESENT/ABSENT/DYNAMIC/UNKNOWN 各 1 例，全部通过")
    print("k 判定失败路径故障注入：裸别名/纯变量模板/includeByName None/filter 动态收窄，全部通过")


def _w_panel(rename_from, rename_to, sql_alias, fields_pattern, extra_target_sql=None):
    """构造规则 w 自测用的最小 stat 面板：单 target、单 byName displayName override。"""
    targets = [{'refId': 'A', 'rawSql': f'SELECT avg(x) AS "{sql_alias}" FROM charges'}]
    if extra_target_sql:
        targets.append({'refId': 'B', 'rawSql': extra_target_sql})
    overrides = []
    if rename_from is not None:
        overrides.append({
            'matcher': {'id': 'byName', 'options': rename_from},
            'properties': [{'id': 'displayName', 'value': rename_to}],
        })
    return {
        'id': 999,
        'type': 'stat',
        'title': 'w-self-test',
        'fieldConfig': {'overrides': overrides},
        'options': {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': fields_pattern, 'values': False}},
        'targets': targets,
    }


def run_w_self_test():
    """不碰 dashboard 文件：47 案原样复现必红、修复后写法必绿、动态字段面板不误报。"""
    panel_index, cache = {}, {}

    # 47 案原样复现：override 已把「电压」改名成「充电器电压」，但 reduceOptions.fields
    # 还停在改名前的 /^电压$/ —— 必须判定 STALE_ALIAS（红）。
    stale_panel = _w_panel('电压', '充电器电压', '电压', '/^电压$/')
    stale_contract = panel_field_contract(stale_panel, panel_index, cache)
    stale_rename_map = panel_byname_rename_map(stale_panel)
    verdict, _ = classify_reduce_fields_matcher(stale_contract, stale_rename_map, '/^电压$/')
    if verdict != 'STALE_ALIAS':
        raise AssertionError(f"w 47 案复现故障注入失败：期待 STALE_ALIAS，实得 {verdict}")

    # 修复写法：正则同时兼容改名前后两个名字 —— 必须判定 MATCH（绿）。
    fixed_panel = _w_panel('电压', '充电器电压', '电压', '/^(电压|充电器电压)$/')
    fixed_contract = panel_field_contract(fixed_panel, {}, {})
    fixed_rename_map = panel_byname_rename_map(fixed_panel)
    verdict, _ = classify_reduce_fields_matcher(fixed_contract, fixed_rename_map, '/^(电压|充电器电压)$/')
    if verdict != 'MATCH':
        raise AssertionError(f"w 修复写法故障注入失败：期待 MATCH，实得 {verdict}")

    # 动态字段面板不误报：整段 SQL 来自 :raw 变量，契约给不出任何具体字段名 —— 必须跳过
    # （SKIP_DYNAMIC），不能被误判成 STALE_ALIAS/NO_MATCH 拉violations。
    dynamic_panel = {
        'id': 998, 'type': 'stat', 'title': 'w-self-test-dynamic',
        'fieldConfig': {'overrides': []},
        'options': {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '/^whatever$/', 'values': False}},
        'targets': [{'refId': 'A', 'rawSql': '${runtime_query:raw}'}],
    }
    dynamic_contract = panel_field_contract(dynamic_panel, {}, {})
    verdict, _ = classify_reduce_fields_matcher(dynamic_contract, {}, '/^whatever$/')
    if verdict != 'SKIP_DYNAMIC':
        raise AssertionError(f"w 动态字段不误报故障注入失败：期待 SKIP_DYNAMIC，实得 {verdict}")

    # UNKNOWN 同理不误报（SELECT * 依赖 schema，静态分析给不出字段名）。
    unknown_panel = {
        'id': 997, 'type': 'gauge', 'title': 'w-self-test-unknown',
        'fieldConfig': {'overrides': []},
        'options': {'reduceOptions': {'calcs': ['lastNotNull'], 'fields': '/^whatever$/', 'values': False}},
        'targets': [{'refId': 'A', 'rawSql': 'SELECT * FROM runtime_schema.t'}],
    }
    unknown_contract = panel_field_contract(unknown_panel, {}, {})
    verdict, _ = classify_reduce_fields_matcher(unknown_contract, {}, '/^whatever$/')
    if verdict != 'SKIP_UNKNOWN':
        raise AssertionError(f"w UNKNOWN 不误报故障注入失败：期待 SKIP_UNKNOWN，实得 {verdict}")

    # 完全无关：正则既不匹配改名前也不匹配改名后 —— 与 STALE_ALIAS 区分为 NO_MATCH。
    unrelated_panel = _w_panel('电压', '充电器电压', '电压', '/^voltage$/')
    unrelated_contract = panel_field_contract(unrelated_panel, {}, {})
    verdict, _ = classify_reduce_fields_matcher(unrelated_contract, panel_byname_rename_map(unrelated_panel), '/^voltage$/')
    if verdict != 'NO_MATCH':
        raise AssertionError(f"w 完全无关故障注入失败：期待 NO_MATCH，实得 {verdict}")

    # 非法正则单独识别为 REGEX_ERROR，不混进 NO_MATCH。
    broken_panel = _w_panel(None, None, '电压', '/^(unterminated$/')
    broken_contract = panel_field_contract(broken_panel, {}, {})
    verdict, _ = classify_reduce_fields_matcher(broken_contract, {}, '/^(unterminated$/')
    if verdict != 'REGEX_ERROR':
        raise AssertionError(f"w 非法正则故障注入失败：期待 REGEX_ERROR，实得 {verdict}")

    print("w 故障注入：47 案复现(STALE_ALIAS)/修复写法(MATCH)/动态跳过(SKIP_DYNAMIC)/"
          "UNKNOWN跳过(SKIP_UNKNOWN)/完全无关(NO_MATCH)/非法正则(REGEX_ERROR)，全部通过")


def main():
    verbose_k = False
    update_baseline = False
    k_contract_json = None
    self_test_k = False
    self_test_w = False
    arguments = iter(sys.argv[1:])
    for argument in arguments:
        if argument == '--verbose-k':
            verbose_k = True
        elif argument == '--update-baseline':
            update_baseline = True
        elif argument == '--k-contract-json':
            try:
                k_contract_json = next(arguments)
            except StopIteration:
                print("--k-contract-json 缺少路径", file=sys.stderr)
                sys.exit(2)
        elif argument == '--self-test-k':
            self_test_k = True
        elif argument == '--self-test-w':
            self_test_w = True
        elif argument in {'-h', '--help'}:
            print(
                "用法: bash scripts/check-dashboard-lint.sh "
                "[--verbose-k] [--update-baseline] [--k-contract-json PATH] "
                "[--self-test-k] [--self-test-w]"
            )
            return
        else:
            print(f"未知参数: {argument}", file=sys.stderr)
            sys.exit(2)

    if self_test_k:
        run_k_self_test()
        return

    if self_test_w:
        run_w_self_test()
        return

    violations = []
    warnings = []
    exemptions = []
    k_occurrences = []
    k_results = []
    w_results = []
    used_whitelist = set()
    n_files = 0
    n_panels = 0
    n_vars = 0

    all_files = []
    for pattern in DASHBOARD_GLOBS:
        all_files.extend(sorted(glob.glob(pattern)))

    if not all_files:
        print("未找到任何 dashboard JSON 文件（检查 grafana/dashboards/{zh-cn,internal}/ 是否存在）")
        sys.exit(1)

    dashboards = {}
    for file_rel in all_files:
        n_files += 1
        try:
            with open(file_rel, encoding='utf-8') as file_handle:
                dashboards[file_rel] = json.load(file_handle)
        except Exception as error:
            violations.append(f"{file_rel} :: (整份文件) :: 0 :: JSON 解析失败: {error}")

    dashboard_uids = {
        dashboard.get('uid')
        for dashboard in dashboards.values()
        if isinstance(dashboard.get('uid'), str) and dashboard.get('uid')
    }
    project_functions = installed_function_names()
    custom_function_prefixes = derived_custom_function_prefixes(project_functions)

    def collect_panels(value, result):
        if not isinstance(value, dict):
            return
        if 'id' in value and ('targets' in value or 'type' in value):
            result.setdefault(value.get('id'), value)
        for child in value.get('panels', []) or []:
            collect_panels(child, result)

    panel_indexes = {}
    panel_contract_caches = {}
    panel_pretransform_caches = {}
    variable_domains_by_file = {}
    for file_rel, dashboard in dashboards.items():
        panel_index = {}
        for panel in dashboard.get('panels', []) or []:
            collect_panels(panel, panel_index)
        panel_indexes[file_rel] = panel_index
        panel_contract_caches[file_rel] = {}
        panel_pretransform_caches[file_rel] = {}
        variable_domains_by_file[file_rel] = dashboard_variable_domains(dashboard)

    def record(file_rel, subject, rule, condition, message):
        if allow_exact(file_rel, subject, rule, condition, used_whitelist):
            return
        if rule in REPORT_RULES:
            warnings.append(f"[report-mode] {file_rel} :: {message}")
        else:
            violations.append(f"{file_rel} :: {message}")

    def check_sql(file_rel, subject, label, context):
        sql = context.sql
        tokens, literals = tokenize_sql(sql)

        for start, end in avg_speed_calls(tokens):
            if not allow_a(file_rel, subject, context, tokens, used_whitelist):
                violations.append(f"{file_rel} :: {label} :: a :: ...{sql_snippet(sql, tokens, start, end)}...")

        for literal in literals:
            if '--' in literal:
                violations.append(f"{file_rel} :: {label} :: b :: 字面量含 --: {literal[:60]!r}")

        for args, _, _ in find_function_calls(tokens, 'timezone'):
            parts = split_top_level_tokens(args)
            if len(parts) != 2 or not string_arg_equals(parts[0], '$__timezone') or is_now_call(parts[1]):
                continue
            if not allow_d(file_rel, subject, context, parts[1], tokens, used_whitelist):
                arg_text = sql[parts[1][0].start:parts[1][-1].end] if parts[1] else ''
                violations.append(
                    f"{file_rel} :: {label} :: d :: timezone('$__timezone', {arg_text[:40]}) 且非允许表达式"
                )

        for start, end in settings_car_id_matches(tokens):
            violations.append(f"{file_rel} :: {label} :: f :: {sql_snippet(sql, tokens, start, end)!r}")

        for start, end in payload_cast_matches(tokens):
            violations.append(
                f"{file_rel} :: {label} :: g :: 未加 NULLIF(NULLIF(...)) 守护: "
                f"...{sql_snippet(sql, tokens, start, end)}"
            )

        for name in sorted(function_call_names(tokens)):
            if name in project_functions or not looks_like_custom_function(name, custom_function_prefixes):
                continue
            condition = {
                'kind': 'undefined_custom_function',
                'target_path': context.target_path,
                'value': name,
            }
            record(
                file_rel, subject, 'l', condition,
                f"{label} :: l :: 调用了未定义的自研函数: {name}()",
            )

        for start, end, kind in mod_or_date_part_matches(tokens):
            snippet = sql_snippet(sql, tokens, start, end)
            condition = {
                'kind': 'banned_sql_function',
                'target_path': context.target_path,
                'value': kind,
                'snippet': snippet,
            }
            record(
                file_rel, subject, 'p', condition,
                f"{label} :: p :: 禁止 {kind}: ...{snippet}...",
            )

        for start, end in geofence_equality_matches(tokens):
            snippet = sql_snippet(sql, tokens, start, end)
            condition = {
                'kind': 'nullable_geofence_equality',
                'target_path': context.target_path,
                'snippet': snippet,
            }
            record(
                file_rel, subject, 'q', condition,
                f"{label} :: q :: 可空列 geofence_id 使用直等: ...{snippet}...",
            )

        for start, end, columns in naive_now_interval_matches(tokens):
            snippet = sql_snippet(sql, tokens, start, end)
            condition = {
                'kind': 'naive_date_now_interval',
                'target_path': context.target_path,
                'columns': columns,
                'snippet': snippet,
            }
            record(
                file_rel, subject, 'r', condition,
                f"{label} :: r :: NOW() - interval 邻域含朴素列 {','.join(columns)} 且无 AT TIME ZONE 'UTC': "
                f"...{snippet}...",
            )

        if has_legacy_variable_code_token(tokens):
            condition = {'kind': 'legacy_variable_syntax', 'target_path': context.target_path}
            record(
                file_rel, subject, 's', condition,
                f"{label} :: s :: rawSql/query 含老变量语法 [[",
            )

    for file_rel, dashboard in dashboards.items():
        seen_panel_ids = {}

        def check_panel(panel, panel_path):
            nonlocal n_panels
            n_panels += 1
            panel_id = panel.get('id', '?')
            title = panel.get('title') or ''
            label = f"panel {panel_id}" + (f" {title!r}" if title else "")

            if panel_id != '?':
                if panel_id in seen_panel_ids:
                    condition = {
                        'kind': 'duplicate_panel_id',
                        'value': panel_id,
                        'first_path': seen_panel_ids[panel_id],
                        'duplicate_path': panel_path,
                    }
                    record(
                        file_rel, panel_id, 't', condition,
                        f"{label} :: t :: panel id 重复；首次 {seen_panel_ids[panel_id]}，再次 {panel_path}",
                    )
                else:
                    seen_panel_ids[panel_id] = panel_path

            sql_contexts = find_rawsql_in_panel(panel)
            panel_config_refs = config_ref_ids(panel)
            for context in sql_contexts:
                check_sql(file_rel, panel_id, label, context)

            visible_values = [
                ('title', panel.get('title')),
                ('description', panel.get('description')),
            ]

            field_config = panel.get('fieldConfig', {}) or {}
            defaults = field_config.get('defaults', {}) or {}
            visible_values.append(('fieldConfig.defaults.displayName', defaults.get('displayName')))
            default_unit = defaults.get('unit')
            if default_unit in BANNED_UNITS:
                occurrence = {
                    'kind': 'unit', 'scope': 'defaults', 'matcher_id': None,
                    'matcher_options': None, 'value': default_unit,
                }
                if not allow_e(file_rel, panel_id, occurrence, used_whitelist):
                    violations.append(
                        f"{file_rel} :: {label} :: e :: fieldConfig.defaults.unit = {default_unit!r}"
                    )

            for override_index, override in enumerate(field_config.get('overrides', []) or []):
                matcher = override.get('matcher') or {}
                for prop_index, prop in enumerate(override.get('properties', []) or []):
                    unit = prop.get('value')
                    if prop.get('id') == 'displayName':
                        visible_values.append((
                            f'fieldConfig.overrides[{override_index}].properties[{prop_index}].displayName',
                            prop.get('value'),
                        ))
                    if prop.get('id') != 'unit' or unit not in BANNED_UNITS:
                        continue
                    occurrence = {
                        'kind': 'unit', 'scope': 'override', 'matcher_id': matcher.get('id'),
                        'matcher_options': matcher.get('options'), 'value': unit,
                    }
                    if not allow_e(file_rel, panel_id, occurrence, used_whitelist):
                        violations.append(
                            f"{file_rel} :: {label} :: e :: "
                            f"override[{matcher.get('id')!r}, {matcher.get('options')!r}].unit = {unit!r}"
                        )

            for visible_path, value in visible_values:
                if not isinstance(value, str) or visible_text_allowed(value):
                    continue
                condition = {'kind': 'visible_text', 'path': visible_path, 'value': value}
                record(
                    file_rel, panel_id, 'j', condition,
                    f"{label} :: j :: {visible_path} 未含 CJK 且未整串命中通用白名单: {value!r}",
                )

            if panel.get('type') in {'table', 'stat'}:
                contract = panel_field_contract(
                    panel, panel_indexes[file_rel], panel_contract_caches[file_rel],
                    variable_domains=variable_domains_by_file[file_rel],
                    pretransform_cache=panel_pretransform_caches[file_rel],
                )
                for override_index, override in enumerate(field_config.get('overrides', []) or []):
                    matcher = override.get('matcher') or {}
                    matcher_value = matcher.get('options')
                    if matcher.get('id') != 'byName' or not isinstance(matcher_value, str):
                        continue
                    properties_hash = override_properties_hash(override.get('properties', []) or [])
                    key = k_key(file_rel, panel_id, matcher_value, properties_hash)
                    state = classify_contract_matcher(contract, matcher_value)
                    reasons = []
                    if state == 'DYNAMIC':
                        reasons = sorted(contract.dynamic_reasons)
                    elif state == 'UNKNOWN':
                        reasons = sorted(contract.unknown_reasons)
                    message = (
                        f"{file_rel} :: {label} :: k :: {state} byName={matcher_value!r} "
                        f"propertiesHash={properties_hash}；最终确定字段={sorted(contract.fields)!r}"
                    )
                    if reasons:
                        message += f"；原因={reasons!r}"
                    result = {
                        'file': file_rel,
                        'panelId': panel_id,
                        'panelTitle': title,
                        'panelType': panel.get('type'),
                        'matcher': matcher_value,
                        'propertiesHash': properties_hash,
                        'properties': override.get('properties', []) or [],
                        'state': state,
                        'fields': sorted(contract.fields),
                        'dynamicReasons': sorted(contract.dynamic_reasons),
                        'pureVariableReasons': sorted(contract.pure_variable_reasons),
                        'unknownReasons': sorted(contract.unknown_reasons),
                    }
                    k_results.append(result)
                    if state == 'ABSENT':
                        k_occurrences.append((key, message))

            if panel.get('type') in REDUCE_FIELD_PANEL_TYPES:
                reduce_options = ((panel.get('options') or {}).get('reduceOptions')) or {}
                fields_pattern = reduce_options.get('fields')
                if isinstance(fields_pattern, str) and fields_pattern.strip():
                    contract = panel_field_contract(
                        panel, panel_indexes[file_rel], panel_contract_caches[file_rel],
                        variable_domains=variable_domains_by_file[file_rel],
                        pretransform_cache=panel_pretransform_caches[file_rel],
                    )
                    rename_map = panel_byname_rename_map(panel)
                    verdict, detail = classify_reduce_fields_matcher(contract, rename_map, fields_pattern)
                    w_results.append({
                        'file': file_rel,
                        'panelId': panel_id,
                        'panelTitle': title,
                        'panelType': panel.get('type'),
                        'fieldsPattern': fields_pattern,
                        'verdict': verdict,
                        'detail': detail,
                    })
                    if verdict == 'STALE_ALIAS':
                        condition = {
                            'kind': 'reduce_fields_stale_alias',
                            'fields_pattern': fields_pattern,
                        }
                        record(
                            file_rel, panel_id, 'w', condition,
                            f"{label} :: w :: reduceOptions.fields={fields_pattern!r} 只匹配改名前的原始"
                            f"别名 {detail!r}，套用 byName displayName override 后的最终显示名"
                            f"{sorted(reduce_field_display_names(contract, rename_map)[0])!r} 匹配不到"
                            "（同 CurrentChargeView panel 47 案：override 改名后 reduceOptions.fields 未同步）",
                        )
                    elif verdict == 'NO_MATCH':
                        condition = {
                            'kind': 'reduce_fields_no_match',
                            'fields_pattern': fields_pattern,
                        }
                        record(
                            file_rel, panel_id, 'w', condition,
                            f"{label} :: w :: reduceOptions.fields={fields_pattern!r} 未匹配任何最终显示名 "
                            f"{detail!r}",
                        )
                    elif verdict == 'REGEX_ERROR':
                        condition = {
                            'kind': 'reduce_fields_regex_error',
                            'fields_pattern': fields_pattern,
                        }
                        record(
                            file_rel, panel_id, 'w', condition,
                            f"{label} :: w :: reduceOptions.fields={fields_pattern!r} 不是合法正则",
                        )

            for target_index, target in enumerate(panel.get('targets', []) or []):
                if not isinstance(target, dict) or not isinstance(target.get('rawSql'), str) or not target.get('rawSql').strip():
                    continue
                ref_id = target.get('refId', '?')
                reduce_calcs = set(
                    ((panel.get('options') or {}).get('reduceOptions') or {}).get('calcs') or []
                )
                if panel.get('type') in {'stat', 'gauge', 'bargauge'} and reduce_calcs & EDGE_REDUCE_CALCS:
                    target_tokens, _ = tokenize_sql(target['rawSql'])
                    if has_sql_clause(target_tokens, 'group', 'by') and not has_sql_clause(target_tokens, 'order', 'by'):
                        violations.append(
                            f"{file_rel} :: {label} :: v :: target {ref_id!r} "
                            "分桶无序+首末聚合=非确定值"
                        )
                if panel.get('type') == 'timeseries' and target.get('format') == 'table':
                    if ref_id in panel_config_refs:
                        exemptions.append(
                            f"{file_rel} :: {label} :: n :: target {ref_id!r} format='table' "
                            "被 configRefId 引用，按配置帧豁免"
                        )
                    else:
                        condition = {'kind': 'timeseries_table_format', 'target_index': target_index, 'ref_id': ref_id}
                        record(
                            file_rel, panel_id, 'n', condition,
                            f"{label} :: n :: target {ref_id!r} format='table'",
                        )

                effective_datasource = target.get('datasource')
                if effective_datasource is None:
                    effective_datasource = panel.get('datasource')
                if not datasource_allowed(effective_datasource):
                    uid = datasource_uid(effective_datasource)
                    condition = {
                        'kind': 'rawsql_datasource',
                        'target_index': target_index,
                        'ref_id': ref_id,
                        'uid': uid,
                    }
                    record(
                        file_rel, panel_id, 'u', condition,
                        f"{label} :: u :: rawSql target {ref_id!r} 写死非 TeslaMate datasource uid={uid!r}",
                    )

            bar_paths = [path for path, value in draw_styles(panel) if value == 'bars']
            transformation_ids = [
                str(item.get('id', ''))
                for item in panel.get('transformations', []) or []
                if isinstance(item, dict)
            ]
            trend_ids = [
                value for value in transformation_ids
                if 'regression' in value.lower() or 'trendline' in value.lower()
            ]
            if bar_paths and trend_ids:
                condition = {
                    'kind': 'bars_trendline',
                    'draw_style_paths': tuple(bar_paths),
                    'transformations': tuple(trend_ids),
                }
                record(
                    file_rel, panel_id, 'o', condition,
                    f"{label} :: o :: drawStyle='bars' 同时挂趋势变换 {trend_ids!r}",
                )

            for link_path, uid, url in dashboard_link_occurrences(panel):
                if uid in dashboard_uids:
                    continue
                condition = {'kind': 'missing_dashboard_uid', 'path': link_path, 'uid': uid}
                record(
                    file_rel, panel_id, 'm', condition,
                    f"{label} :: m :: {link_path} 跳转 uid={uid!r} 不在仓内 {len(dashboard_uids)} 个 dashboard：{url!r}",
                )

            if panel.get('type') == 'volkovlabs-form-panel':
                update = (panel.get('options') or {}).get('update') or {}
                if update.get('method') and update.get('confirm') is False:
                    violations.append(
                        f"{file_rel} :: {label} :: i :: options.update.confirm = false（写操作无二次确认）"
                    )

            for child_index, child in enumerate(panel.get('panels', []) or []):
                check_panel(child, f'{panel_path}.panels[{child_index}]')

        for panel_index, panel in enumerate(dashboard.get('panels', []) or []):
            check_panel(panel, f'panels[{panel_index}]')

        for variable_index, variable in enumerate(dashboard.get('templating', {}).get('list', []) or []):
            n_vars += 1
            name = variable.get('name', '?')
            label = f"var {name}"
            variable_label = variable.get('label')
            if isinstance(variable_label, str) and not visible_text_allowed(variable_label):
                condition = {'kind': 'visible_text', 'path': 'label', 'value': variable_label}
                record(
                    file_rel, name, 'j', condition,
                    f"{label} :: j :: templating.list[{variable_index}].label 未含 CJK 且未整串命中通用白名单: "
                    f"{variable_label!r}",
                )
            if variable.get('type') == 'query':
                query = variable.get('query', '') or ''
                check_sql(file_rel, name, label, SqlContext(query, None, None))
                if '$__timezone' in query:
                    violations.append(
                        f"{file_rel} :: {label} :: c :: 模板变量 query 含 $__timezone（会解析成字面量 browser）"
                    )

            regex = variable.get('regex', '') or ''
            if '(?<text>' in regex or '(?<value>' in regex:
                violations.append(f"{file_rel} :: {label} :: h :: regex 用老式命名捕获组: {regex[:60]!r}")

            for variable_path, value in recursive_strings(variable):
                if variable_path == 'query' or not has_legacy_variable_code_token(tokenize_sql(value)[0]):
                    continue
                condition = {'kind': 'legacy_variable_syntax', 'path': variable_path}
                record(
                    file_rel, name, 's', condition,
                    f"{label} :: s :: 变量字段 {variable_path} 含老变量语法 [[",
                )

    expired = [
        (index, item) for index, item in enumerate(WHITELIST)
        if index not in used_whitelist
    ]

    state_counts = Counter(result['state'] for result in k_results)
    print(
        "k 四态统计：" + " / ".join(
            f"{state} {state_counts[state]}" for state in K_STATES
        )
    )

    w_verdict_counts = Counter(result['verdict'] for result in w_results)
    w_skip_count = w_verdict_counts['SKIP_DYNAMIC'] + w_verdict_counts['SKIP_UNKNOWN']
    print(
        f"w reduceOptions.fields 统计：MATCH {w_verdict_counts['MATCH']} / "
        f"STALE_ALIAS {w_verdict_counts['STALE_ALIAS']} / NO_MATCH {w_verdict_counts['NO_MATCH']} / "
        f"REGEX_ERROR {w_verdict_counts['REGEX_ERROR']} / 跳过(DYNAMIC+UNKNOWN) {w_skip_count}"
    )

    if verbose_k:
        pure_variable_entries = [
            result for result in k_results
            if result['state'] == 'DYNAMIC' and result['pureVariableReasons']
        ]
        print()
        print(f"k 纯变量模板警示（{len(pure_variable_entries)} 条）：")
        print()
        for result in pure_variable_entries:
            print(
                f"  {result['file']} :: panel {result['panelId']} :: "
                f"byName={result['matcher']!r}；"
                f"原因={result['pureVariableReasons']!r}"
            )
        for state in K_STATES:
            entries = [result for result in k_results if result['state'] == state]
            print()
            print(f"k {state} 明细（{len(entries)} 条）：")
            print()
            for result in entries:
                reason_values = (
                    result['dynamicReasons'] if state == 'DYNAMIC' else result['unknownReasons']
                )
                reason = f"；原因={reason_values!r}" if reason_values else ''
                print(
                    f"  {result['file']} :: panel {result['panelId']} :: "
                    f"byName={result['matcher']!r}；字段={result['fields']!r}{reason}"
                )

        print()
        print(f"w 跳过明细（DYNAMIC/UNKNOWN 无具体字段，{w_skip_count} 条）：")
        print()
        for result in w_results:
            if result['verdict'] not in ('SKIP_DYNAMIC', 'SKIP_UNKNOWN'):
                continue
            print(
                f"  {result['file']} :: panel {result['panelId']} :: "
                f"fields={result['fieldsPattern']!r}；{result['verdict']}；原因={result['detail']!r}"
            )

    if k_contract_json:
        contract_document = {
            'version': 1,
            'states': list(K_STATES),
            'stateCounts': {state: state_counts[state] for state in K_STATES},
            'entries': sorted(
                k_results,
                key=lambda item: (
                    item['file'], str(item['panelId']), item['matcher'], item['propertiesHash']
                ),
            ),
        }
        directory = os.path.dirname(os.path.abspath(k_contract_json)) or '.'
        with tempfile.NamedTemporaryFile(
            mode='w', encoding='utf-8', dir=directory, prefix='.k-contract.', delete=False
        ) as handle:
            json.dump(contract_document, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write('\n')
            contract_temporary_path = handle.name
        os.replace(contract_temporary_path, k_contract_json)

    current_k = Counter(key for key, _ in k_occurrences)
    result_states_by_key = {
        k_key(
            result['file'], result['panelId'], result['matcher'], result['propertiesHash']
        ): result['state']
        for result in k_results
    }
    try:
        baseline_k = load_k_baseline(allow_missing=update_baseline)
    except ValueError as error:
        violations.append(f"{K_BASELINE_PATH} :: k :: {error}")
        baseline_k = Counter()

    baseline_update_refused = update_baseline and bool(violations or expired)
    if baseline_update_refused:
        print(
            "拒绝更新 k 基线：当前树仍有阻断档违规或过期白名单；"
            "基线文件保持不变"
        )
    elif update_baseline:
        added_before_update = current_k - baseline_k
        removed_before_update = baseline_k - current_k
        reclassified = Counter()
        for key, count in removed_before_update.items():
            reclassified[result_states_by_key.get(key, 'DELETED_OR_CHANGED')] += count
        write_k_baseline(current_k)
        print(
            "k 基线更新："
            f"新增 {sum(added_before_update.values())} 条，"
            f"删除 {sum(removed_before_update.values())} 条，"
            f"现有 {sum(current_k.values())} 条"
        )
        print(
            "k 基线 diff 摘要：旧 ABSENT → "
            f"PRESENT {reclassified['PRESENT']} / "
            f"DYNAMIC {reclassified['DYNAMIC']} / "
            f"UNKNOWN {reclassified['UNKNOWN']} / "
            f"删除或属性变更 {reclassified['DELETED_OR_CHANGED']}；"
            f"新 ABSENT {sum(added_before_update.values())}"
        )
        baseline_k = current_k.copy()

    baseline_remaining = baseline_k.copy()
    baseline_messages = []
    added_messages = []
    for key, message in k_occurrences:
        if baseline_remaining[key] > 0:
            baseline_messages.append(message)
            baseline_remaining[key] -= 1
        else:
            added_messages.append(message)
    expired_k = baseline_k - current_k
    baseline_inside_count = sum((current_k & baseline_k).values())

    print(f"k 基线内 {baseline_inside_count} 条，新增 {len(added_messages)} 条")
    if added_messages:
        print()
        print("k 基线外新增（必须修复或显式更新基线）：")
        print()
        for message in added_messages:
            print("  " + message)

    if expired_k:
        print()
        print("k 过期基线（当前树已消失，必须显式 --update-baseline 收缩）：")
        print()
        for key in sorted(expired_k, key=k_key_sort_key):
            print("  " + format_k_key(key, expired_k[key]))

    if violations:
        print("dashboard lint 发现违规：")
        print()
        for violation in violations:
            print("  " + violation)

    if exemptions:
        if violations:
            print()
        print("dashboard lint 豁免说明：")
        print()
        for exemption in exemptions:
            print("  " + exemption)

    if warnings:
        if violations or exemptions:
            print()
        print("dashboard lint 报告档发现：")
        print()
        for warning in warnings:
            print("  " + warning)

    if expired:
        if violations:
            print()
        print("过期白名单（允许条件本次扫描未命中，必须删除或按现状更新）：")
        print()
        for _, item in expired:
            print(
                f"  {item['file']} :: {item['subject']} :: {item['rule']} :: "
                f"{item['condition']} :: {item['reason']}"
            )

    if violations or expired or added_messages or expired_k:
        print()
        print(
            f"共 {len(violations)} 处违规 / {len(expired)} 条过期白名单 / "
            f"{len(added_messages)} 条新增 k / {sum(expired_k.values())} 条过期 k 基线"
        )
        sys.exit(1)

    report_suffix = f"；报告档 {len(warnings)} 条 WARNING" if warnings else ""
    print(f"✓ dashboard lint 全绿：扫了 {n_files} 文件 / {n_panels} 面板 / {n_vars} 变量{report_suffix}")


if __name__ == '__main__':
    main()
PYEOF
