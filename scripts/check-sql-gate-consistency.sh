#!/bin/bash
# 校验四个脚本里内联的「三组兼容性 SQL 对象校验」判据完全一致。
#
# 为什么需要这道门：simple-deploy.sh 和 migrate-from-official.sh 是 curl-piped 单文件脚本，
# 不能 source 公共库，所以这段判据在四个文件里各有一份拷贝：
#   simple-deploy.sh / migrate-from-official.sh / scripts/upgrade.sh   → sql_trio_objects_present()
#   scripts/diagnose.sh                                               → 第 4 节的三处检查
# 四份漂移的后果是静默的：安装脚本认为装好了、诊断脚本认为没装（或反过来），用户拿到互相
# 矛盾的结论，而任何单元测试都不会响。2026-07 已经吃过一次亏——「单位换算函数」那一腿四处
# 一致地写错（数上游也会建的函数名，恒真），一致地错等于没人能发现。
#
# 校验的是「判据」而不只是「那句 SQL」：SQL 只是判据的一半，另一半是拿结果做的比较
# （grep -qx 5 / grep -qx 4 之类的阈值）。阈值同样是四处复制的，改一处漏三处一样会让
# 两个脚本对同一个库给出相反结论——第一版本门只比 SQL，把阈值 5 改成 4 它照样报
# 「一致」，等于漏掉半个判据。
#
# 另：只在**去掉注释之后**的正文里找。否则把判据原文抄进注释、正文却改掉，这道门就被骗过去了。
set -euo pipefail

cd "$(dirname "$0")/.."

FILES=(simple-deploy.sh migrate-from-official.sh scripts/upgrade.sh scripts/diagnose.sh)

KEYS=(
    "lat_for_map"
    "convert_tire_pressure"
    "relname='tou_rates'"
)
LABELS=(
    "坐标转换函数"
    "单位换算函数"
    "分时电价表"
)

fail=0

extract() {
    # $1=文件 $2=特征片段
    # 输出：规范化后的「SQL 正文 + 紧随其后的 grep 判定」，即完整判据。
    python3 - "$1" "$2" <<'PY'
import re, sys

path, key = sys.argv[1], sys.argv[2]
raw = open(path, encoding='utf-8').read()

# ① 先接续行，② 再逐行剥掉 `#` 注释（判据里不含 # 字符，直接砍安全），
# 这样注释里抄一份判据原文骗不过这道门。
joined = raw.replace('\\\n', ' ')
lines = []
for line in joined.split('\n'):
    stripped = line.lstrip()
    if stripped.startswith('#'):
        continue
    lines.append(line)
body = '\n'.join(lines)

out = []
for line in body.split('\n'):
    if key not in line or '"SELECT' not in line:
        continue
    m = re.search(r'"(SELECT[^"]*)"', line)
    if not m:
        continue
    sql = re.sub(r'\s+', ' ', m.group(1)).strip()
    # 判据的另一半：这一行里对结果做的 grep 判定（阈值就在这里）
    g = re.findall(r"grep\s+-[A-Za-z]+\s+'?[^|;&\s']+'?", line)
    verdict = re.sub(r'\s+', ' ', ' '.join(g)).strip()
    out.append(f'{sql}  ||  {verdict}')

for s in sorted(set(out)):
    print(s)
PY
}

for idx in "${!KEYS[@]}"; do
    key="${KEYS[$idx]}"
    label="${LABELS[$idx]}"
    ref=""
    ref_file=""
    for f in "${FILES[@]}"; do
        got=$(extract "$f" "$key")
        if [ -z "$got" ]; then
            echo "❌ ${label}：在 $f 的正文里没找到判据（改写法了？或者只剩注释里有？四份必须同步）"
            fail=1
            continue
        fi
        if [ -z "$ref" ]; then
            ref="$got"
            ref_file="$f"
        elif [ "$got" != "$ref" ]; then
            echo "❌ ${label}：判据在两个文件之间不一致"
            echo "   $ref_file:"
            printf '     %s\n' "$ref"
            echo "   $f:"
            printf '     %s\n' "$got"
            fail=1
        fi
    done
done

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "四份判据（SQL + 判定阈值）必须逐字一致。改任何一处都要同步全部四个文件："
    printf '  %s\n' "${FILES[@]}"
    exit 1
fi

echo "✅ 四个脚本的 SQL 对象判据一致（3 组判据 × ${#FILES[@]} 个文件，含判定阈值）"
