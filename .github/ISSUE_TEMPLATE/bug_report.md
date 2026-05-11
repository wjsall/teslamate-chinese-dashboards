---
name: Bug 报告 / 问题求助
about: 报告 dashboard 显示问题、安装/升级失败、容器异常等
title: ''
labels: ''
assignees: ''
---

## 我做过的尝试

- [ ] 我已经按 [先问 AI 自助排查 prompt](https://github.com/wjsall/teslamate-chinese-dashboards/blob/main/docs/ai-troubleshooting-prompt.md) 把项目背景 + 我的日志发给 AI 问过，AI 没解决或判断是项目 bug

## 问题描述

<!-- 一句话说清楚：哪个面板 / 哪个步骤 / 看到什么 -->

## 复现步骤

<!-- 1. 我执行了 xxx； 2. 看到 xxx； 3. 期望是 xxx -->

## 安装方式

- [ ] 全新安装（simple-deploy.sh）
- [ ] 从官方版迁移（migrate-from-official.sh）
- [ ] 从旧版升级（scripts/upgrade.sh）
- [ ] 其他（请在下方注明）：

## 环境信息

- 项目版本：<!-- 例：v1.7.1（看 Releases 页面或 docker image tag） -->
- 部署平台：<!-- 例：群晖 NAS DSM 7.2 / Ubuntu 22.04 / 其他 -->

## 完整日志

**必填。** 不带日志的 issue 维护者会先要求补全才能开始排查。任选相关一项粘贴：

- Grafana 报错：`docker compose logs grafana --tail 200`
- 容器起不来：`docker compose ps` + `docker compose logs --tail 100`
- SQL 报错：psql 查询的完整输出

```
（在这里粘贴日志）
```

## AI 诊断结论

<!-- 贴 AI 给出的判断（即使没解决也贴，让维护者跳过重复排查） -->

## 截图（可选）

<!-- 拖图到这里。面板报错最好附面板检查（点 ⋮ → 检查（Inspect）→ 查询（Query））标签页截图，含完整 SQL 和返回数据 -->
