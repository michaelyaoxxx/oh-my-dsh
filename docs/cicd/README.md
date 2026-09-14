---
title: DSH 超级仓库 CI/CD 方案（索引）
doc-version: 1.0.0
status: draft
last-updated: 2026-09-14
applies-to: dsh 超级仓库（main 分支）
---

# DSH 超级仓库 CI/CD 方案

本目录存放本仓 CI/CD 的方案文档。**目标是「dsh 主仓 + Gerrit + Jenkins」承载 CI/CD**，
GitHub Actions 工作流作为过渡期保留（开源后可能回归 GitHub Actions）。

## 导航

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| [cici_architecture.md](cici_architecture.md) | 总体架构：现状（as-is）→ 目标（to-be）、角色划分、数据流/控制流、迁移路径 | draft |
| [cicd_engineering.md](cicd_engineering.md) | 工程实施细节：Jenkinsfile、Gerrit 配置、与现有脚本的对接点、硬约束 | draft |
| [deployment.md](deployment.md) | 物理部署架构：两台独立物理服务器 + agent 的拓扑、网络端口、安装顺序、备份 | draft |
| [reference/community-survey.md](reference/community-survey.md) | 社区 Jenkins 生态调研（**参考资料，非本仓方案、未经本仓验证**） | reference |

## 读之前先知道三件事

1. **本仓现状是 GitHub Actions。** 目标态（Gerrit + Jenkins）**尚未落地**——`cici_architecture.md`
   的目标架构与 `cicd_engineering.md` 的实施细节均为设计，文档内逐条标注了「已实测 / 设计未验证」。
2. **硬约束不可绕过**：本地 macOS M4（arm64）与服务器 Linux x86-64 双平台，
   **原生 Node 依赖必须各平台各自构建，严禁跨平台拷贝 `node_modules`**。任何 CI 设计
   都必须尊重这条——这直接决定了构建节点不能只设在一种架构上。
3. **本仓大量资产可直接复用**：`Makefile` + `scripts/*` 已经把「构建、挂载、部署、发布」
   收敛成单一入口，CI 要做的是**调用它们**，而不是另起一套。

## 修订历史

| 版本 | 日期 | 变更 |
| --- | --- | --- |
| 1.0.0 | 2026-09-14 | 按本仓实际情况重构：拆为架构 / 工程 / 调研三部分；原单文件报告（2026-09-13 初稿，846 行）的社区调研部分存档至 `reference/`；总体架构与工程实施按真实脚本与工作流重写 |
