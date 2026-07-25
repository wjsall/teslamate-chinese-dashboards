#!/bin/bash
# 校验四个脚本里内联的「三组兼容性 SQL 对象校验」谓词完全一致。
#
# 为什么需要这道门：simple-deploy.sh 和 migrate-from-official.sh 是 curl-piped 单文件脚本，
# 不能 source 公共库，所以这段判据在四个文件里各有一份拷贝：
#   simple-deploy.sh / migrate-from-official.sh / scripts/upgrade.sh   → sql_trio_objects_present()
#   scripts/diagnose.sh                                               → 第 4 节的三处检查
# 四份漂移的后果是静默的：安装脚本认为装好了、诊断脚本认为没装（或反过来），用户拿到互相
# 矛盾的结论，而任何单元测试都不会响。2026-07 已经吃过一次亏——「单位换算函数」那一腿四处
# 一致地写错（数上游也会建的函数名，恒真），一致地错等于没人能发现。
#
# 校验方式：把每个文件里的判据 SQL 抽出来规范化（去掉换行/续行/多余空白）后比对字符串。
# 只认 SQL 本身，不管周围的 shell 写法（各脚本的容器变量名、颜色输出本来就不同）。
set -euo pipefail

cd "$(dirname "$0")/.."

FILES=(simple-deploy.sh migrate-from-official.sh scripts/upgrade.sh scripts/diagnose.sh)

# 三条判据各自的特征片段（用足够长的唯一子串定位，避免误抓别处的 SQL）
declare -a KEYS=(
    "lat_for_map"
    "convert_tire_pressure"
    "relname='tou_rates'"
)
declare -a LABELS=(
    "坐标转换函数"
    "单位换算函数"
    "分时电价表"
)

fail=0

extract() {
    # $1=文件 $2=特征片段 → 打印规范化后的 SQL（该行及其续行合并、压缩空白）
    python3 - "$1" "$2" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
# 先把 shell 续行接起来，判据 SQL 常写成多行
joined = text.replace('\\\n', ' ')
out = []
for line in joined.split('\n'):
    if key in line and '"SELECT' in line:
        m = re.search(r'"(SELECT[^"]*)"', line)
        if m:
            out.append(re.sub(r'\s+', ' ', m.group(1)).strip())
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
            echo "❌ ${label}：在 $f 里没找到判据 SQL（是不是改写法了？四份必须同步）"
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
    echo "四份判据必须逐字一致。改任何一处都要同步全部四个文件："
    printf '  %s\n' "${FILES[@]}"
    exit 1
fi

echo "✅ 四个脚本的 SQL 对象判据一致（3 组判据 × ${#FILES[@]} 个文件）"
