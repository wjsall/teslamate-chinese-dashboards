#!/usr/bin/env bash
# 校验 SQL 安装文件（install-coord-functions / install-unit-functions / install-tou / install-indexes）
# 在所有用户可见入口中都被引用，避免日后加新 SQL 时漏改某处。
#
# 跑：bash scripts/check-sql-trio.sh
# 退出码：0 = 全 OK；1 = 有遗漏（输出哪个文件少了哪个 SQL）。
#
# 加新 SQL 文件时：
#   1. 加 sql/install-<NEW>.sql（本脚本会自动枚举）
#   2. 在各入口的实际安装循环 / 命令中加 install-<NEW>
#   3. 重跑本脚本验证

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

# 以 sql/install-*.sql 为单一数据源，避免校验数组本身也漂移。
SQL_INSTALLS=()
for path in sql/install-*.sql; do
    [[ -f "$path" ]] || continue
    name=${path##*/}
    SQL_INSTALLS+=("${name%.sql}")
done

if [[ ${#SQL_INSTALLS[@]} -eq 0 ]]; then
    echo "❌ sql/ 下没有 install-*.sql"
    exit 1
fi

# 入口必须在实际安装命令 / 安装循环中引用所有 SQL 文件。
ENTRY_POINTS=(
    "simple-deploy.sh"
    "migrate-from-official.sh"
    "scripts/upgrade.sh"
    "README.md"
    "QUICKSTART.md"
    "TROUBLESHOOTING.md"
    "docs/ai-troubleshooting-prompt.md"
)

# Markdown 按「标题分节」校验；shell 仍按整份文件校验（一个脚本 = 一条安装流程，不需要分节）。
#
# 背景（P1-5 修复）：旧版「整份 Markdown 任意位置出现权威锚点/循环，就当整份文件已委托」按文件粒度
# 判定，会被同文件里其他小节的合规循环掩盖——TROUBLESHOOTING.md 曾出现「群晖 Container Manager」
# 新装小节自己漏了 SQL 四件套，但因为同文件另一处有权威循环，整份文件仍被判定通过（假绿）。
#
# 新逻辑按标题（# ~ ######）切分 section，一个 section 被判定为「需要 SQL 四件套」当它满足：
#   a) Bash 代码块同时含 install-*.sql 和 psql/docker exec 安装命令（循环或逐条命令均可）；或
#   b) 含完整的全新部署 compose 模板（出现 `image: teslamate/teslamate`，即从零起 TeslaMate 容器的模板）
# 命中以上任一条件的 section，必须在本 section 内部四个 SQL 全部出现，或本 section 内出现到
# #repair-sql-install 权威锚点的真实 Markdown 链接；否则判定该 section 遗漏（不再靠文件内别处的循环兜底）。
check_markdown_sections() {
    local file="$1"
    awk -v names="${SQL_INSTALLS[*]}" '
        BEGIN {
            n = split(names, arr, " ")
            heading = "(文件开头)"
            # 必须锚定 "image:" 前缀，只匹配真的部署模板（image: teslamate/teslamate）；
            # 不能只认裸字符串 "teslamate/teslamate"，否则「完全卸载」章节的
            # `docker rmi teslamate/teslamate` 会被误判成一个全新部署模板。
            tmpl = "image:[[:space:]]*teslamate/teslamate"
        }
        function flush_section() {
            if (relevant) {
                missing = ""
                for (i = 1; i <= n; i++) {
                    if (index(install_text, arr[i]) == 0) {
                        missing = missing (missing == "" ? "" : ",") arr[i]
                    }
                }
                if (missing != "" && !has_anchor) {
                    printf "MISSING\t%s\t%s\n", heading, missing
                }
            }
        }
        {
            raw = $0
            line = raw
            sub(/^[[:space:]]*>[[:space:]]?/, "", line)
            sub(/^[[:space:]]+/, "", line)

            if (raw ~ tmpl) relevant = 1

            # in_fence 覆盖任意语言的代码块（```yaml / ```bash / 裸```），不仅是 bash。
            # 标题检测必须挡在所有代码块外——否则 yaml 里的 "# 备选 GHCR" 这种行内注释、
            # bash 里的 "# 容器名不是..." 这种注释都会被误判成 Markdown 标题，把一个 section
            # 从中间切断，导致后半段（含四件套循环/锚点链接）被错误地归到一个不存在的假标题下。
            # 只有 fence_is_bash 的代码块才把内容累积进 block，用于安装命令判定。
            if (in_fence) {
                if (line ~ /^```/) {
                    if (fence_is_bash && block ~ /install-[[:alnum:]-]+/ && block ~ /[.]sql/ && block ~ /(psql|docker[[:space:]]+exec)/) {
                        install_text = install_text block
                        relevant = 1
                    }
                    in_fence = 0
                    fence_is_bash = 0
                } else if (fence_is_bash) {
                    block = block line ORS
                }
                next
            }

            # 只接受代码块外真实 Markdown 链接中的权威锚点；普通文字或代码里的裸字符串不算委托。
            if (raw ~ /\]\([^)]*#repair-sql-install\)/) has_anchor = 1

            if (line ~ /^#{1,6}[[:space:]]/) {
                flush_section()
                heading = line
                relevant = 0
                install_text = ""
                has_anchor = 0
                next
            }

            if (line ~ /^```/) {
                in_fence = 1
                fence_is_bash = (line ~ /^```(bash|sh|shell)[[:space:]]*$/) ? 1 : 0
                block = ""
            }
        }
        END { flush_section() }
    ' "$file"
}

# shell：整份文件抓可执行 SQL 引用行（不分节）。
extract_shell_installation_text() {
    awk '
        /install-[[:alnum:]-]+\.sql/ &&
        ($0 ~ /(curl|raw\.githubusercontent|<)[[:space:]]*[^#]*install-/ || $0 ~ /SQL_BASE\/install-/) &&
        $0 !~ /^[[:space:]]*#/ { print }
    ' "$1"
}

fail=0
echo "校验 SQL 安装文件引用一致性..."
echo "  期待: ${SQL_INSTALLS[*]}"
echo

for entry in "${ENTRY_POINTS[@]}"; do
    if [[ ! -f "$entry" ]]; then
        echo "  ✗ $entry: 文件不存在"
        fail=1
        continue
    fi

    case "$entry" in
        *.md)
            missing_sections=$(check_markdown_sections "$entry")
            if [[ -z "$missing_sections" ]]; then
                echo "  ✓ $entry"
            else
                echo "  ✗ $entry 有章节遗漏 SQL 四件套（且未链接权威锚点）："
                while IFS=$'\t' read -r _ heading missing; do
                    echo "      - [$heading] 漏: $missing"
                done <<< "$missing_sections"
                fail=1
            fi
            ;;
        *)
            install_text=$(extract_shell_installation_text "$entry")
            missing=()
            for sql in "${SQL_INSTALLS[@]}"; do
                if ! grep -q "$sql" <<< "$install_text"; then
                    missing+=("$sql")
                fi
            done
            if [[ ${#missing[@]} -eq 0 ]]; then
                echo "  ✓ $entry"
            else
                echo "  ✗ $entry 漏掉: ${missing[*]}"
                fail=1
            fi
            ;;
    esac
done

# 同时检查 sql/ 目录下是否真的有这些文件
echo
echo "校验 sql/ 目录..."
for sql in "${SQL_INSTALLS[@]}"; do
    if [[ -f "sql/${sql}.sql" ]]; then
        echo "  ✓ sql/${sql}.sql"
    else
        echo "  ✗ sql/${sql}.sql 不存在"
        fail=1
    fi
done

# 三条安装路径都会在装完分时电价 SQL 后调用 backfill_all_tou()。psql 默认遇到单条 SQL
# 错误仍可能退出 0；每一处回算命令都必须显式启用 ON_ERROR_STOP，成功提示才可信。
echo
echo "校验历史分时费用回算的错误退出设置..."
BACKFILL_PATHS=(simple-deploy.sh migrate-from-official.sh scripts/upgrade.sh)
for entry in "${BACKFILL_PATHS[@]}"; do
    if detail=$(python3 - "$entry" <<'PY'
import sys

path = sys.argv[1]
lines = open(path, encoding='utf-8').read().splitlines()
calls = [i for i, line in enumerate(lines) if 'FROM backfill_all_tou();' in line]
if not calls:
    print('找不到 backfill_all_tou() 的实际调用')
    raise SystemExit(1)

for line_no in calls:
    start = line_no
    floor = max(0, line_no - 12)
    while start >= floor and 'docker exec' not in lines[start]:
        start -= 1
    if start < floor:
        print(f'第 {line_no + 1} 行回算调用找不到对应的 docker exec psql 命令')
        raise SystemExit(1)
    command = '\n'.join(lines[start:line_no + 1])
    if '-v ON_ERROR_STOP=1' not in command:
        print(f'第 {line_no + 1} 行回算调用缺少 -v ON_ERROR_STOP=1')
        raise SystemExit(1)
PY
    ); then
        echo "  ✓ $entry"
    else
        echo "  ✗ $entry: $detail"
        fail=1
    fi
done

echo
if [[ $fail -eq 0 ]]; then
    echo "✅ 全部 SQL 安装文件引用一致，sql/ 文件都存在"
    exit 0
else
    echo "❌ 发现引用遗漏 / 文件缺失，发版前必须修复"
    echo
    echo "修复指引："
    echo "  - 入口文件漏 SQL：在那个文件的实际安装循环 / 命令里加上 sql/<missing>.sql"
    echo "  - Markdown 章节漏 SQL：给漏掉的那个标题小节补四件套安装循环，或加一条到 TROUBLESHOOTING.md#repair-sql-install 的链接（同文件内其他小节合规不能替它兜底）"
    echo "  - SQL 清单来自 sql/install-*.sql；不再需要手动维护数组"
    exit 1
fi
