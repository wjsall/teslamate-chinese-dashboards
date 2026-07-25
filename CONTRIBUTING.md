# 贡献指南

感谢您对 TeslaMate 中文仪表盘项目的关注！

## 🎯 如何贡献

### 1. 报告问题

如果您发现：
- 翻译错误或不准确
- 仪表盘显示异常
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

4. **新建分支提交（不要直接 push 到 fork 的 main，方便后续维护）**
   ```bash
   # 在你 fork 的本地仓库：
   git checkout -b fix/xx-dashboard-translation
   git add grafana/dashboards/zh-cn/<your-edited>.json
   git commit -m "fix: improve XX dashboard translation"
   git push origin fix/xx-dashboard-translation
   ```

5. **创建 Pull Request**
   - 访问你的 Fork 页面 → 自动出现「Compare & pull request」按钮
   - Base repository 选 `wjsall/teslamate-chinese-dashboards` `main`
   - Head 选你刚 push 的分支
   - 填写 PR 描述（原翻译 → 新翻译，为什么改）

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

推荐用 `docker compose` 跑完整 stack 测：

```bash
# 仓库根目录跑
docker compose -f docker-compose.dev.yml up -d
```

开发环境也需要坐标、单位换算、分时电价和性能索引四组 SQL 对象。面向用户的安装顺序与失败处理只在 [故障排查手册的权威循环](TROUBLESHOOTING.md#repair-sql-install) 维护；本地调试当前分支时，把其中的 `docker compose` 改为 `docker compose -f docker-compose.dev.yml`，并把远程 `curl` 输入替换为当前工作树对应的 `sql/*.sql` 文件。任一文件失败都应停止。

然后访问 `http://localhost:3000`，找到你修改的仪表盘验证翻译。

如果只想验证 JSON 语法：

```bash
jq . grafana/dashboards/zh-cn/<your-edited>.json > /dev/null && echo "JSON OK"
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
feat(dashboard): 新增 XX 仪表盘的汉化
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

### 提交前本地检查

改动 `grafana/dashboards/` 下的 JSON 或 `sql/`/安装脚本前，提交 PR 前先在本地跑一遍这 5 个检查（`lint` job 跑的就是这 5 项；push main 时会先跑 lint、全绿后再构建镜像；本地先过能少一轮来回）：

```bash
bash scripts/check-dashboard-lint.sh && bash scripts/check-sql-trio.sh && bash scripts/check-sql-revision.sh \
  && bash scripts/check-sql-gate-consistency.sh && bash scripts/check-dashboards-clean.sh
```

## 📋 发布流程

维护者发布新版本时：

1. 把 `CHANGELOG.md` 的 `[Unreleased]` 定版成 `[vX.Y.Z] - 日期`
2. 本地跑一遍门禁（CI 也会跑，本地先跑省一轮往返）：
   ```bash
   for s in check-dashboard-lint check-sql-trio check-dashboards-clean \
            check-sql-revision check-sql-gate-consistency; do bash scripts/$s.sh; done
   ```
3. 提交并推送 `main`
4. **紧接着**打 tag 并推送：`git tag vX.Y.Z && git push origin vX.Y.Z`
   —— 两步之间不要留窗口：`latest` 只在 tag 构建时更新，只推 main 的话新用户会拿到旧版本
5. `gh release create vX.Y.Z`，说明取 CHANGELOG 对应小节

### CI 是怎么保证发出去的镜像被测过的

tag 推送后，流水线的关键顺序是**串行**的（先构建候选 → 各道门测的都是这一份 → 全绿才提升），
不是"构建和测试一起跑"：

```
lint
  → build-candidate          构建镜像，只推一个 candidate-<run_id> 临时 tag
  → 五条部署冒烟             全部按 digest 拉这一份候选镜像来测
    分时电价行为测试          算钱正确性，只需要 lint，与冒烟并行
    仪表盘 SQL 可执行性       面板 SQL 真交给 PostgreSQL 解析，同上
  → publish                  以上七个 job 全绿，才把同一个 digest 提升成
                             vX.Y.Z / latest / main
  → cleanup-candidate-tag    删掉 candidate-<run_id> 临时 tag；`if: always()`，
                             前面挂了也照删
```

三条硬保证：

- **任一门失败，正式 tag 不会出现**——`publish` 的 `needs` 列了全部五条部署冒烟，外加
  分时电价行为测试（`tou-behavior`）和仪表盘 SQL 可执行性（`dashboard-sql`）。
- **发出去的就是被测的那一份**——提升用 `docker buildx imagetools create` 纯复制 manifest，
  不重新构建；`publish` 最后还会回验每个正式 tag 指向的 digest 等于被测 digest。
- **临时 tag 不会残留**——清理是独立 job，`needs` 列了所有用到候选镜像的 job（删早了会
  把它们正在拉的镜像删掉），配 `if: always()`，所以某条门失败、`publish` 被跳过时它照样
  跑。清理曾经写在 `publish` 里，正好在失败时不执行，每次失败都往公开的 GHCR 包里留一个
  谁都能拉的候选镜像。

这道门是 2026-07-25 补的。在那之前 `build` 与冒烟并行，v1.9.0 发布那次四条冒烟挂着、
镜像照样推了出去——冒烟当时只是发布后的报警器。

## 💬 沟通渠道

- GitHub Issues: 问题报告、功能建议
- GitHub Discussions: 一般性讨论
- PR Review: 代码审查

## 🙏 感谢

感谢所有贡献者的付出！

您的贡献将帮助更多中文用户使用 TeslaMate。
