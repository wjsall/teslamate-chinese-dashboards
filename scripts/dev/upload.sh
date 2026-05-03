#!/bin/bash
# 一键上传脚本 - 使用 GitHub CLI

# 请先安装 gh: https://cli.github.com/

echo "======================================"
echo "TeslaMate 中文 Dashboard 一键上传"
echo "======================================"
echo ""

# 检查 gh 是否安装
if ! command -v gh &> /dev/null; then
    echo "❌ 请先安装 GitHub CLI:"
    echo "   https://cli.github.com/"
    echo ""
    echo "安装命令:"
    echo "  macOS: brew install gh"
    echo "  Ubuntu: sudo apt install gh"
    echo "  Windows: winget install --id GitHub.cli"
    exit 1
fi

# 检查是否登录
if ! gh auth status &> /dev/null; then
    echo "🔐 请先登录 GitHub:"
    echo "   gh auth login"
    exit 1
fi

REPO_NAME="teslamate-chinese-dashboards"

echo "将要创建仓库: $REPO_NAME"
echo ""

# 创建仓库
echo "📦 创建 GitHub 仓库..."
gh repo create "$REPO_NAME" \
    --public \
    --description "TeslaMate 中文 Grafana Dashboard - 简体中文汉化版" \
    --source=. \
    --remote=origin \
    --push

echo ""
echo "======================================"
echo "✅ 完成！"
echo "======================================"
echo ""
echo "仓库地址: https://github.com/$(gh api user -q .login)/$REPO_NAME"
echo ""
echo "下一步:"
echo "1. 访问仓库页面"
echo "2. 点击 Settings → Topics"
echo "3. 添加标签: teslamate, grafana, dashboard, chinese, i18n"
echo "4. 分享到 TeslaMate 社区"
