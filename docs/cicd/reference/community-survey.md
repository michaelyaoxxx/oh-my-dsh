---
title: DSH 社区 Jenkins CI/CD 生态调研（参考资料）
doc-version: 1.0.0
status: reference
last-updated: 2026-09-14
source: 2026-09-13 单文件初稿《DeepSeek Harness 社区 Jenkins CI_CD Pipeline 方案总结报告》的调研部分（该初稿已于 2026-09-14 拆分归档，调研部分逐字迁入本文件，架构部分改写为 ../cici_architecture.md 与 ../cicd_engineering.md）
---

> **本文件是参考资料，不是本仓的方案。** 内容为对 DSH 社区 Jenkins 集成生态的调研摘录，
> 原样保留以便查阅；其中涉及的配置实例、插件清单等**未经本仓验证**。
> 本仓实际采用的方案见 [../cici_architecture.md](../cici_architecture.md) 与 [../cicd_engineering.md](../cicd_engineering.md)。

## 一、背景与现状定位

DeepSeek Harness（简称 dsh）于 2026 年 8 月 13 日以 MIT 许可证开源，在一周内斩获超过 22 万 GitHub Stars，成为史上增速最快的开源仓库之一 [1]。其核心设计哲学是"一切皆插件（Everything is a Plugin）"，基于 Cordis 组合框架构建，支持模型适配器、工具注册、会话管理、沙盒策略等全部能力以插件形式热插拔。

从 CI/CD 视角来看，dsh 的定位有两个维度需要区分：**dsh 本身作为被构建与部署的对象**（即如何用 Jenkins 对 dsh 源码进行 CI/CD），以及 **dsh 作为 CI/CD 流水线的智能增强工具**（即如何将 dsh 的 AI Agent 能力嵌入到 Jenkins 流水线中）。社区现有方案在这两个维度上均有覆盖，但成熟度存在明显差异。

---

## 二、官方 CI/CD 基础设施分析

### 2.1 GitHub Actions 工作流（主流 CI 平台）

官方仓库 `.github/workflows/` 目录下包含 21 个工作流文件 [2]，构成了 dsh 自身的完整 CI/CD 体系：

| 工作流文件 | 触发条件 | 核心职能 |
|---|---|---|
| `ci.yml` | Pull Request | 静态检查、类型校验、覆盖率测试（Node 24） |
| `ci-master.yml` | Push to master | 主干集成测试 |
| `node-addon-system.yml` | PR / Push to master | Native Addon 跨平台构建与 Docker 测试 |
| `release.yml` | Tag 推送 | 正式版本发布流程 |
| `release-publish.yml` | Tag 推送 | npm 包发布 |
| `e2e.yml` / `e2b-e2e.yml` | PR | 端到端测试 |
| `build-exe-for-python-sdk.yml` | 手动触发 | Python SDK 可执行文件构建 |
| `docs-pages.yml` | Push to master | 文档站点自动部署 |

官方 CI 的核心构建序列如下：

```yaml
# 来自官方 ci.yml 的关键步骤（简化）
- uses: pnpm/action-setup@v4
- uses: actions/setup-node@v6
  with:
    node-version: '24'
- name: Install (immutable)
  run: pnpm install --frozen-lockfile
- name: Run static gates
  run: pnpm run check:ci:static
- name: Run coverage
  run: pnpm run check:ci:coverage
```

官方 CI 的关键环境变量配置包括 `DSH_TELEMETRY_DISABLED: '1'`（禁用遥测）、`DSH_GATE_CONCURRENCY: '8'`（并发门控数量）以及 `NODE_OPTIONS: "--max-old-space-size=4096"`（防止大型 Monorepo 编译 OOM）[3]。

### 2.2 GitLab CI 配置（Python SDK 发布专用）

官方仓库根目录包含 `.gitlab-ci.yml`，但其用途高度专一，**仅用于 Python SDK 的跨平台构建与 PyPI 发布**，并非通用的 Node.js 构建流水线 [4]。该配置定义了两个 Stage：

- **build**：在 `linux-x64`、`linux-arm64`、`macos-arm64`、`macos-x64`、`windows-x64` 五个平台上分别构建 Python Runtime Wheel，并通过 Docker 在 manylinux 镜像内进行 glibc 版本兼容性验证（最高 2.28）。
- **publish**：汇聚全部 6 个 Wheel 产物，通过 `twine` 上传至 GitLab Package Registry。

### 2.3 基于 Gerrit 的 CI/CD 集成原理与配置实例

Gerrit 是 Google 开源的代码审查系统，广泛应用于 Android、Chromium、OpenStack 等大型私有化工程团队。其与 Jenkins 的集成是企业私有化 CI/CD 的经典范式，也是本报告 DSH 私有化部署方案的核心基础设施选型。

#### 2.3.1 Gerrit + Jenkins 集成核心原理

Gerrit 与 Jenkins 的集成依赖一个关键机制：**`stream-events` SSH 长连接**。Jenkins 侧安装的 Gerrit Trigger 插件通过 SSH 连接到 Gerrit 服务器（默认端口 29418），执行 `gerrit stream-events` 命令，建立一条持久化的事件流通道 [11]。Gerrit 将服务器上发生的所有代码审查事件以 JSON 格式实时推送到该通道，Jenkins 插件解析事件后触发对应的 Pipeline 构建。

整个集成的核心工作流围绕两个 Gerrit 标签（Label）运转：

- **`Verified`**（由 Jenkins 机器人写入）：取值范围 `-1 / 0 / +1`，表示自动化 CI 验证结果。`-1` 表示构建或测试失败，阻止合并；`+1` 表示 CI 通过，允许进入人工审查阶段。
- **`Code-Review`**（由人工审查者写入）：取值范围 `-2 / -1 / 0 / +1 / +2`，表示代码质量评审结果。`+2` 是合并的最终授权。

Gerrit 的 Submit Rules 通常配置为：`Verified ≥ +1 AND Code-Review ≥ +2` 时才允许自动合并（Submit）。这确保了每一次合并都经过机器验证和人工审查的双重把关。

#### 2.3.2 Gerrit 服务端权限配置

在 Gerrit 服务端，需要为 Jenkins 机器人账号（建议加入 `Service Users` 组）配置以下权限 [12]：

```
# Gerrit Access Rights 配置（在 All-Projects 或目标仓库的 Access 页面设置）
Reference: refs/*
  Read: ALLOW for Service Users

Reference: refs/heads/*
  Label Verified: -1, +1 for Service Users
  Label Code-Review: -1, +1 for Service Users  # 可选，仅需 Verified 时可省略

# Stream Events 全局能力（在 Global Capabilities 中配置）
Stream Events: ALLOW for Service Users
```

> **注意**：Gerrit v3.3 之前，CI 专用组名为 `Non-Interactive Users`；v3.3 起统一改名为 `Service Users` [12]。

#### 2.3.3 Jenkins 侧 Gerrit Trigger 插件配置

**Step 1：安装插件**

在 Jenkins 插件管理中安装 `Gerrit Trigger`（当前版本 `3.1993.vdb_00c7b_551a_5`，安装率约 2.36%）[12]。

**Step 2：配置服务器连接**（`Manage Jenkins → Gerrit Trigger`）

```
Server Name:    my-gerrit
Hostname:       gerrit.example.com
Frontend URL:   http://gerrit.example.com:8080
SSH Port:       29418
Username:       jenkins-bot
SSH Key File:   /var/jenkins_home/.ssh/id_rsa_gerrit
```

配置完成后点击 `Test Connection` 验证 SSH 连通性，然后在 `Control` 区域启动连接。

**Step 3：配置 Missed Events Playback（可选但推荐）**

为防止 Jenkins 重启期间错过事件，需在 Gerrit 服务端安装 `events-log` 插件，并在 Jenkins 的 Gerrit 服务器配置中填入 HTTP 用户名和密码（用于 REST API 回放）[12]。

**Step 4：在 Pipeline Job 中配置触发器**

```groovy
// Jenkinsfile 中的触发器配置（Declarative Pipeline）
pipeline {
    triggers {
        gerrit(
            serverName: 'my-gerrit',
            gerritProjects: [[
                compareType: 'PLAIN',
                pattern: 'deepseek-harness-custom',
                branches: [[compareType: 'ANT', pattern: '**']]
            ]],
            triggerOnEvents: [patchsetCreated(), changeMerged()]
        )
    }
    // ...
}
```

#### 2.3.4 Gerrit 环境变量在 Pipeline 中的使用

Gerrit Trigger 插件触发构建时，会向 Jenkins 注入一系列标准环境变量 [13]，这些变量是在 Pipeline 中检出正确代码版本的关键：

| 环境变量 | 示例值 | 说明 |
|---|---|---|
| `GERRIT_REFSPEC` | `refs/changes/39/4039/1` | 待审 Patchset 的 Git Refspec |
| `GERRIT_CHANGE_NUMBER` | `4039` | Change 编号 |
| `GERRIT_PATCHSET_NUMBER` | `1` | Patchset 版本号 |
| `GERRIT_PATCHSET_REVISION` | `03d9debf16a0...` | Patchset 的 Git SHA1 |
| `GERRIT_PROJECT` | `deepseek-harness-custom` | Gerrit 项目名 |
| `GERRIT_BRANCH` | `main` | 目标分支 |
| `GERRIT_CHANGE_URL` | `http://gerrit.example.com/4039` | Change 页面 URL |
| `GERRIT_EVENT_TYPE` | `patchset-created` | 触发事件类型 |

在 Pipeline 中使用这些变量检出代码：

```groovy
stage('Checkout') {
    steps {
        git url: "ssh://jenkins-bot@gerrit.example.com:29418/${GERRIT_PROJECT}"
        sh "git fetch origin ${GERRIT_REFSPEC}:change-${GERRIT_CHANGE_NUMBER}-${GERRIT_PATCHSET_NUMBER}"
        sh "git checkout change-${GERRIT_CHANGE_NUMBER}-${GERRIT_PATCHSET_NUMBER}"
    }
}
```

#### 2.3.5 Verified 标签回写

构建完成后，Jenkins 需要通过 SSH 将构建结果写回 Gerrit 的 `Verified` 标签。Gerrit Trigger 插件会自动完成此操作，但也可以在 Pipeline 的 `post` 块中手动控制：

```groovy
post {
    success {
        // 方式一：通过 Gerrit Trigger 插件的 setGerritReview step
        setGerritReview(successVote: 1, failureVote: -1)

        // 方式二：直接通过 SSH 命令（更灵活，可附加详细消息）
        sh """
            ssh -p 29418 jenkins-bot@gerrit.example.com gerrit review \
                ${GERRIT_CHANGE_NUMBER},${GERRIT_PATCHSET_NUMBER} \
                --verified +1 \
                --message "CI passed: ${BUILD_URL}"
        """
    }
    failure {
        sh """
            ssh -p 29418 jenkins-bot@gerrit.example.com gerrit review \
                ${GERRIT_CHANGE_NUMBER},${GERRIT_PATCHSET_NUMBER} \
                --verified -1 \
                --message "CI failed at stage '${STAGE_NAME}': ${BUILD_URL}"
        """
    }
}
```

#### 2.3.6 现代替代方案：Gerrit Code Review 插件（HTTP Checks API）

对于 Gerrit 3.x 及以上版本，官方推荐使用基于 HTTP Checks API 的 **Gerrit Code Review Plugin**（`gerrit-code-review-plugin`）作为 Gerrit Trigger 的现代替代方案 [14]。该插件通过 Multibranch Pipeline 自动发现 Gerrit Changes，无需手动配置 SSH stream-events，并提供原生的 Jenkinsfile DSL 步骤：

```groovy
// 使用 Gerrit Code Review Plugin 的 Declarative Pipeline
pipeline {
    agent any
    stages {
        stage('Build & Test') {
            steps {
                gerritReview labels: [Verified: 0]  // 标记构建进行中
                sh 'pnpm install --frozen-lockfile && pnpm run build && pnpm run test'
            }
        }
    }
    post {
        success {
            gerritReview labels: [Verified: 1], message: 'CI passed'
            gerritCheck checks: ['dsh-ci:build': 'SUCCESSFUL']
        }
        failure {
            gerritReview labels: [Verified: -1], message: 'CI failed'
            gerritCheck checks: ['dsh-ci:build': 'FAILED']
        }
    }
}
```

两种方案的对比如下：

| 维度 | Gerrit Trigger Plugin（SSH） | Gerrit Code Review Plugin（HTTP） |
|---|---|---|
| **触发机制** | SSH `stream-events` 长连接 | HTTP Webhook / Gerrit Checks API |
| **稳定性** | SSH 连接可能断开，需重连机制 | HTTP 无状态，更稳定 |
| **配置复杂度** | 高（服务端 + Jenkins 双端配置） | 低（仅需 HTTP 凭证） |
| **Multibranch 支持** | 有限 | 原生支持 |
| **Jenkinsfile DSL** | `setGerritReview` | `gerritReview` / `gerritComment` / `gerritCheck` |
| **适用场景** | Gerrit 2.x / 私有网络隔离环境 | Gerrit 3.x+ / 现代化部署 |

**结论**：官方并未提供面向 Jenkins 的 Jenkinsfile 模板，其 CI/CD 基础设施完全基于 GitHub Actions 和 GitLab CI，Jenkins 集成完全依赖社区贡献。

---

## 四、社区 Jenkins 集成方案全景

### 4.1 dsh-jenkins：DSH 内置 Jenkins 管理插件（直接集成方向）

**仓库**：[jsoncode/dsh-jenkins](https://github.com/jsoncode/dsh-jenkins) [5]

这是目前社区中**唯一专门针对 Jenkins 集成**的 DSH 插件，由社区开发者 jsoncode 于 2026 年 8 月开发，截至报告日已累计 101 次提交。其核心定位是：**将 Jenkins 的构建触发能力引入 DSH 的 AI Agent 工作流**，而非为 dsh 源码构建提供 Jenkinsfile 模板。

该插件的主要功能如下：多服务器集中管理（URL、用户名、API Token，支持 TLS 跳过验证）、一键触发参数化构建（实时追踪 `queued → building → result` 状态，10 分钟超时）、构建日志查看与取消、跨工作区构建历史记录（最近 50 次）。

**工作区配置示例**（`dsh-jenkins.json`）：

```json
[
  {
    "job": "build-app",
    "server": "http://uat.example.com",
    "environments": { "BRANCH": "main", "DEPLOY": false }
  },
  {
    "job": "build-app",
    "server": "http://prod.example.com",
    "environments": { "BRANCH": "release-1.0", "DEPLOY": true }
  }
]
```

**安装方式**：

```shell
dsh plugin --profile web add dsh-jenkins
```

### 4.2 dsh-headless：官方 CI 接入基础（Headless 模式）

官方提供的 `headless` Profile 是将 DSH 嵌入 CI 流水线的**标准接入机制** [6]。Headless 模式运行单次任务，打印最终 Assistant 回复到 stdout，返回语义化退出码（0 = 成功，非 0 = 失败），无 GUI、无 Server、无浏览器，适合脚本和 CI 环境。

### 4.3 dsh-headless-json：结构化 CI 输出插件

**仓库**：[JohnXu22786/headless-json](https://github.com/JohnXu22786/headless-json) [7]

该插件将 dsh 的 Headless 会话输出转化为 CI 系统可直接消费的结构化产物，包括 JUnit XML 报告（可被 Jenkins、GitLab CI、Azure DevOps 直接解析）、完整 JSON 事务报告、实时 NDJSON 事件流和语义化退出码。

### 4.4 deepseek-harness-action：GitHub Actions 集成方案（架构参考）

**仓库**：[Lixiaoyiao/deepseek-harness-action](https://github.com/Lixiaoyiao/deepseek-harness-action) [8]

虽然该项目基于 GitHub Actions 而非 Jenkins，但其凭证隔离的 DSH Worker 设计、受信任的 Controller 发布变更机制，对构建 Jenkins 同类集成具有直接的设计参考意义。

### 4.5 dsh-webhook：事件驱动的 CI 触发适配器

**仓库**：[omdsh-dev/dsh-webhook](https://github.com/omdsh-dev/dsh-webhook) [9]

该插件为 DSH 提供持久化的入站 Webhook 触发能力，可与 Jenkins 的 Webhook 触发机制形成双向集成：Jenkins 构建完成后通过 Webhook 通知 DSH 触发 AI 分析任务，DSH Agent 也可通过 `dsh-jenkins` 插件主动触发 Jenkins 构建。

---

## 五、综合集成方案矩阵

| 方案 | 类型 | 成熟度 | 适用场景 | 关键依赖 |
|---|---|---|---|---|
| **官方 GitHub Actions** | dsh 源码 CI | ★★★★★ | 官方/Fork 仓库的 PR 验证 | GitHub 托管 Runner |
| **官方 GitLab CI** | Python SDK 发布 | ★★★★☆ | Python 包跨平台构建 | GitLab Runner（多平台） |
| **Gerrit + Jenkins（本方案）** | 私有化 CI/CD | ★★★★☆ | 企业私有化 + 深度定制构建 | Jenkins Agent（Node 24+）+ Gerrit |
| **dsh-jenkins 插件** | AI 触发 Jenkins | ★★★☆☆ | AI Agent 驱动 Jenkins 构建 | DSH Web Profile |
| **Headless + JUnit XML** | DSH 嵌入 Jenkins | ★★★☆☆ | Jenkins 流水线中运行 AI 任务 | DSH Headless Profile |
| **dsh-webhook** | 事件驱动集成 | ★★☆☆☆ | Jenkins 与 DSH 双向事件联动 | dsh-automation 插件 |

---

## 六、关键风险与注意事项

dsh 目前处于 **Developer Preview** 阶段，官方明确声明会有 Breaking Changes [10]。在 Gerrit + Jenkins 集成中需特别注意以下风险：

**版本锁定**：在 `pnpm install --frozen-lockfile` 之外，还需在 Jenkinsfile 中显式固定 Node.js 版本和 pnpm 版本（通过 Corepack 的 `packageManager` 字段），防止环境漂移导致构建不可复现。

**Gerrit SSH 连接稳定性**：Gerrit Trigger 插件依赖的 SSH `stream-events` 长连接在网络不稳定时可能断开。建议启用 `Missed Events Playback` 功能（需在 Gerrit 服务端安装 `events-log` 插件），确保 Jenkins 重启或网络中断后能回放错过的事件 [12]。

**Headless 模式的 LLM 非确定性**：在 Jenkins 测试阶段直接调用真实大模型 API 会导致测试结果不稳定、成本高昂。建议使用 Mock LLM Proxy 模拟固定的 Token 流，实现零网络开销的确定性 Agent 状态机测试。

**Native Addon 兼容性**：`node-pty` 等 C/C++ 扩展的 `.node` 二进制与 glibc 版本强绑定。建议 Jenkins Agent 与生产运行环境使用相同的 OS 镜像，或将整个构建产物打包为 Docker 镜像。

**社区插件稳定性**：`dsh-jenkins`（1 Star）和 `headless-json`（1 Star）均为早期社区项目，尚未经过大规模生产验证。在关键流水线中使用前，建议 Fork 并固定到具体 Commit SHA，而非直接依赖浮动的 `main` 分支。

---

## 参考资料

[1]: https://github.com/deepseek-ai/deepseek-harness "deepseek-ai/deepseek-harness — GitHub 官方仓库"
[2]: https://github.com/deepseek-ai/deepseek-harness/tree/master/.github/workflows "deepseek-harness/.github/workflows — GitHub Actions 工作流目录"
[3]: https://github.com/deepseek-ai/deepseek-harness/blob/master/.github/workflows/ci.yml "deepseek-harness ci.yml — 官方 CI 工作流"
[4]: https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/.gitlab-ci.yml "deepseek-harness .gitlab-ci.yml — GitLab CI 配置（Python SDK 发布）"
[5]: https://github.com/jsoncode/dsh-jenkins "jsoncode/dsh-jenkins — DSH Jenkins 管理插件"
[6]: https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md "dsh-headless — 官方 Headless Bundle 文档"
[7]: https://github.com/JohnXu22786/headless-json "JohnXu22786/headless-json — DSH 结构化 CI 输出插件"
[8]: https://github.com/Lixiaoyiao/deepseek-harness-action "Lixiaoyiao/deepseek-harness-action — 社区 GitHub Action"
[9]: https://github.com/omdsh-dev/dsh-webhook "omdsh-dev/dsh-webhook — DSH 入站 Webhook 触发适配器"
[10]: https://www.atlascloud.ai/blog/tips/how-to-install-deepseek-harness "How to Install DeepSeek Harness in 10 Minutes — Atlas Cloud"
[11]: https://github.com/jenkinsci/gerrit-trigger-plugin "jenkinsci/gerrit-trigger-plugin — Gerrit Trigger Plugin GitHub 仓库"
[12]: https://plugins.jenkins.io/gerrit-trigger/ "Gerrit Trigger | Jenkins plugin — 官方插件文档"
[13]: https://wiki.amarulasolutions.com/ci/gerrit_trigger.html "Gerrit trigger — Amarula Solutions Developer Portal"
[14]: https://github.com/jenkinsci/gerrit-code-review-plugin "jenkinsci/gerrit-code-review-plugin — Gerrit Code Review Plugin GitHub 仓库"
