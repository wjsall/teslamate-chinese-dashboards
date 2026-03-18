# 贡献指南

感谢您对 TeslaMate 中文 Dashboard 项目的关注！

## 🎯 如何贡献

### 1. 报告问题

如果您发现：
- 翻译错误或不准确
- Dashboard 显示异常
- 功能缺失

请提交 [GitHub Issue](https://github.com/wjsall/teslamate-chinese-dashboards/issues)，包含：
- 问题描述
- 截图（如有）
- 复现步骤
- 期望的改进

### 2. 改进翻译

#### 翻译流程

1. **Fork 本项目**
   ```bash
   # 点击 GitHub 页面上的 Fork 按钮
   ```

2. **克隆您的 Fork**
   ```bash
   git clone https://github.com/您的用户名/teslamate-chinese-dashboards.git
   cd teslamate-chinese-dashboards
   ```

3. **修改翻译**
   - 文件位置: `grafana/dashboards/zh-cn/*.json`
   - 修改 `title` 字段
   - 保持 JSON 格式正确

4. **提交修改**
   ```bash
   git add .
   git commit -m "fix: 改进 XX Dashboard 的翻译
   
   - 修改了 XX 面板的标题
   - 原翻译: XXX
   - 新翻译: XXX"
   
   git push origin main
   ```

5. **创建 Pull Request**
   - 访问您的 Fork 页面
   - 点击 "Contribute" → "Open pull request"
   - 填写 PR 描述

### 3. 翻译规范

#### 术语对照表

| 英文 | 建议中文 | 说明 |
|------|----------|------|
| Overview | 概览 | - |
| Status | 状态 | - |
| Charging | 充电 | - |
| Driving | 驾驶/行驶 | - |
| Consumption | 能耗 | - |
| Range | 续航里程 | - |
| Odometer | 里程表 | - |
| Temperature | 温度 | - |
| Session | 会话 | - |
| Statistics | 统计 | - |
| Summary | 汇总 | - |
| Total | 总计 | - |
| Average | 平均 | - |

#### 翻译原则

1. **准确性** - 专业术语要准确
2. **简洁性** - 控制字数，不要太长
3. **一致性** - 相同术语统一翻译
4. **可读性** - 符合中文表达习惯

#### 禁止事项

- ❌ 使用繁体中文
- ❌ 混用中英文标点
- ❌ 过长的翻译（超过15个字）
- ❌ 网络用语或口语化表达

### 4. 测试您的修改

#### 本地测试

```bash
# 1. 启动 Grafana
docker run -d \
  -p 3000:3000 \
  -v $(pwd)/grafana/dashboards/zh-cn:/etc/grafana/provisioning/dashboards/zh:ro \
  -e GF_DEFAULT_LANGUAGE=zh-Hans \
  ghcr.io/wjsall/teslamate-chinese-dashboards:latest

# 2. 访问 http://localhost:3000
# 3. 检查修改后的 Dashboard
```

#### 验证清单

- [ ] JSON 格式正确（无语法错误）
- [ ] 中文显示正常（无乱码）
- [ ] 字数适中（面板标题不超过15字）
- [ ] 术语统一（与现有翻译一致）

### 5. 提交 PR 规范

#### PR 标题格式

```
type(scope): 简短描述

# 示例:
fix(dashboard): 修复概览页面的翻译错误
feat(dashboard): 新增XX Dashboard的汉化
docs(readme): 更新安装说明
```

#### PR 描述模板

```markdown
## 修改内容
简要说明做了什么修改

## 修改原因
为什么需要这个修改

## 测试情况
- [ ] 本地测试通过
- [ ] JSON 格式验证通过
- [ ] Grafana 中显示正常

## 截图
（如有界面变化，请附截图）
```

#### Commit 规范

| 类型 | 说明 |
|------|------|
| `fix` | 修复问题 |
| `feat` | 新功能/新翻译 |
| `docs` | 文档修改 |
| `style` | 格式调整（不影响功能）|
| `refactor` | 重构 |
| `test` | 测试相关 |
| `chore` | 构建/工具相关 |

## 🔧 开发环境

### 推荐的工具

- **编辑器**: VS Code + JSON 插件
- **JSON 验证**: `python3 -m json.tool` 或 jq
- **Git 客户端**: GitHub Desktop 或命令行

### 快速验证脚本

```bash
# 验证所有 JSON 文件
for file in grafana/dashboards/zh-cn/*.json; do
    echo "检查: $file"
    python3 -m json.tool "$file" > /dev/null && echo "✅ 通过" || echo "❌ 失败"
done
```

## 📋 发布流程

维护者发布新版本时：

1. 更新 `README.md` 中的版本信息
2. 创建 Git Tag: `git tag v1.x.x`
3. 推送 Tag: `git push origin v1.x.x`
4. 在 GitHub 创建 Release

## 💬 沟通渠道

- GitHub Issues: 问题报告、功能建议
- GitHub Discussions: 一般性讨论
- PR Review: 代码审查

## 🙏 感谢

感谢所有贡献者的付出！

您的贡献将帮助更多中文用户使用 TeslaMate。
