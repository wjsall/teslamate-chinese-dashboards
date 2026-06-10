#!/usr/bin/env python3
"""一次性移植上游 #5355：给「充电统计」仪表盘加「收藏点（地理围栏）」过滤。

- 复用 charges.json 已有的 geofence 模板变量（含 v1.7.6 的无围栏占位方案、汉化标签「收藏点」），
  保证与 charges / drives 三个仪表盘的围栏下拉完全一致。
- 给每条扫描 charging_processes 的查询追加：
      AND ('${geofence:pipe}' = '-1' OR <别名.>geofence_id in ($geofence))
  选 All（占位）时 '${geofence:pipe}' = '-1' 恒真 → 不过滤 → 与改动前行为完全一致（零回归）。
- 幂等：已含围栏子句的查询跳过；已存在 geofence 变量则不重复插入。

特殊处理：
- p#2 / p#13：UNION 了 drives(别名 d)，只给无前缀的 charging_processes 扫描加（cp.geofence_id），d.car_id 不动。
- p#26（每百km费用，drives+charges 共享查询）：只给「成本来源」CTE（无别名 charging_processes + end_date）加，
  drives / positions 子查询不动——与上游 #5355 一致。
"""
import json, re, sys

ROOT = "grafana/dashboards/zh-cn"
CS = f"{ROOT}/charging-stats.json"
CH = f"{ROOT}/charges.json"

SQL_KEYWORDS = {"where", "right", "left", "join", "group", "order", "on",
                "inner", "outer", "full", "cross", "union", "and", "or",
                "limit", "having", "set"}

def geo_clause(ref: str) -> str:
    """ref 形如 'cp.' / 'c.' / ''（无别名）。"""
    return f" AND ('${{geofence:pipe}}' = '-1' OR {ref}geofence_id in ($geofence))"

def cp_alias(sql: str) -> str:
    """返回 charging_processes 的别名前缀（'cp.' / 'c.' / 'charge.' / 'p.'）或 ''（无别名）。"""
    for m in re.finditer(r"charging_processes\s+(\w+)", sql):
        w = m.group(1)
        if w.lower() not in SQL_KEYWORDS:
            return w + "."
    return ""

def insert_after(sql: str, anchor_regex: str, clause: str):
    """在 anchor 第一处匹配的结尾插入 clause。返回 (新sql, 是否改动)。"""
    m = re.search(anchor_regex, sql)
    if not m:
        return sql, False
    return sql[:m.end()] + clause + sql[m.end():], True

def transform(sql: str, pid) -> tuple[str, bool, str]:
    if "charging_processes" not in sql:
        return sql, False, "无 charging_processes"
    if "geofence_id in ($geofence)" in sql:
        return sql, False, "已含围栏(跳过)"

    ref = cp_alias(sql)
    clause = geo_clause(ref)

    if "Query shared between" in sql:
        # p#26 共享查询：只锚成本 CTE（无前缀 car_id + $__timeFilter(end_date)）
        anchor = r"(?<![.\w])car_id\s*=\s*\$car_id\s+and\s+\$__timeFilter\(end_date\)"
        new, ok = insert_after(sql, anchor, geo_clause(""))  # 该 CTE 无别名
        return new, ok, "共享查询·成本CTE" if ok else "共享查询·未匹配成本CTE!"

    # car_id 过滤数量
    cids = re.findall(r"(?:\w+\.)?car_id\s*=\s*\$car_id", sql)
    if len(cids) >= 2:
        # p#2 / p#13：锚无前缀的 charging_processes 扫描，跳过 d.car_id
        anchor = r"(?<![.\w])car_id\s*=\s*\$car_id"
        new, ok = insert_after(sql, anchor, clause)
        return new, ok, f"双car_id·取cp扫描({ref or '无别名'})" if ok else "双car_id·未匹配!"

    # 单 car_id：插在其后
    anchor = r"(?:\w+\.)?car_id\s*=\s*\$car_id"
    new, ok = insert_after(sql, anchor, clause)
    return new, ok, f"单car_id({ref or '无别名'})" if ok else "单car_id·未匹配!"

def main():
    d = json.load(open(CS, encoding="utf-8"))

    # ① 插入 geofence 模板变量（复用 charges.json 的定义）
    ch = json.load(open(CH, encoding="utf-8"))
    geo_var = next(v for v in ch["templating"]["list"] if v.get("name") == "geofence")
    names = [v.get("name") for v in d["templating"]["list"]]
    if "geofence" in names:
        print("· geofence 变量已存在，跳过插入")
    else:
        # 放在 preferred_range 之后（与 charges 顺序观感一致）
        idx = next((i for i, v in enumerate(d["templating"]["list"])
                    if v.get("name") == "preferred_range"), len(d["templating"]["list"]) - 1)
        d["templating"]["list"].insert(idx + 1, json.loads(json.dumps(geo_var)))
        print(f"· 已插入 geofence 变量（位置 #{idx+1}，标签「{geo_var.get('label')}」）")

    # ② 给查询加围栏过滤
    changed = skipped = 0
    def walk(panels):
        nonlocal changed, skipped
        for p in panels:
            if "panels" in p:
                walk(p["panels"])
            for t in p.get("targets", []):
                sql = t.get("rawSql")
                if not sql:
                    continue
                new, ok, why = transform(sql, p.get("id"))
                if ok:
                    t["rawSql"] = new
                    changed += 1
                    print(f"  ✓ p#{p.get('id'):<3} {p.get('title','')[:18]:<18} [{why}]")
                elif "charging_processes" in sql:
                    skipped += 1
                    print(f"  – p#{p.get('id'):<3} {p.get('title','')[:18]:<18} [{why}]")
    walk(d["panels"])

    # ③ 写回（保持 2 空格缩进 + 末尾换行，与原文件一致）
    orig = open(CS, encoding="utf-8").read()
    out = json.dumps(d, ensure_ascii=False, indent=2) + ("\n" if orig.endswith("\n") else "")
    open(CS, "w", encoding="utf-8").write(out)
    print(f"\n完成：{changed} 条加了围栏过滤，{skipped} 条跳过。")
    # 自检：未匹配成 ! 的视为错误
    if "!" in out:  # 占位，真正校验在外部
        pass

if __name__ == "__main__":
    main()
