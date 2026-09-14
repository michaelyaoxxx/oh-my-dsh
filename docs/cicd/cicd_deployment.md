---
title: DSH 超级仓库 CI/CD 部署架构（物理）
doc-version: 1.0.0
status: draft
last-updated: 2026-09-14
applies-to: dsh 超级仓库（main 分支）
---

# 部署架构（物理）

> **标注约定**：**「实测」**= 本仓已存在并核对过；**「设计」**= 目标态，尚未落地；
> **「待定」**= 需要你确认的输入（本文档里的 IP / 规格 / 端口均可替换，不影响结构）。
>
> **已知前提（用户提供）**：**Jenkins 与 Gerrit 是两台各自独立的物理服务器**。
> 本文按此前提展开；机器名、地址、规格为占位，**【待定】项需按实际填写**。

配套阅读：[cicd_architecture.md](cicd_architecture.md)（逻辑架构）、[cicd_engineering.md](cicd_engineering.md)（工程细节）、[../deploy.md](../deploy.md)（DSH 目标服务器部署手册）。

---

## 1. 物理拓扑

```
                          ┌─────────────────────────────┐
                          │        GitHub（公网）        │
                          │  · harness / plugins 上游仓  │
                          │  · 现有 Actions 工作流（保留）│
                          └───────┬─────────────┬───────┘
                                  │ ① 拉 submodule│ ② tag push → Release
                                  │              │
   ┌──────────────────────────────┼──────────────┼──────────────────────────┐
   │  内网 / 私有网段              │              │                          │
   │                              ▼              │                          │
   │  ┌───────────────────────────────────┐      │                          │
   │  │  物理服务器 A：Gerrit              │      │                          │
   │  │  【待定】IP / 规格                 │      │                          │
   │  │  · superproject 权威仓（main）      │      │                          │
   │  │  · Change 评审 + 门禁标签           │      │                          │
   │  │  · SSH 29418 / HTTP 8080           │      │                          │
   │  └────────┬──────────────────┬────────┘      │                          │
   │           │ ③ Stream Events  │ ④ fetch/push  │                          │
   │  开发者   │  （事件推送）      │  （Jenkins     │                          │
   │  （Mac）──┘                  │   拉代码/回写  │                          │
   │  ② push refs/for/main        │   Verified）   │                          │
   │           ▼                  ▼               │                          │
   │  ┌───────────────────────────────────┐       │                          │
   │  │  物理服务器 B：Jenkins             │───────┘                          │
   │  │  【待定】IP / 规格                 │  ⑤ 拉 submodule                   │
   │  │  · Controller：编排 + 门禁回写      │                                  │
   │  │  · HTTP 8080                       │                                  │
   │  │  ┌─────────────────────────────┐   │                                  │
   │  │  │ 内置节点 linux-x86_64        │   │  ⑥ ssh + rsync + sudo            │
   │  │  │ （controller 本机，跑 verify │   │     部署                          │
   │  │  │   / deploy / release）       │   │                                  │
   │  │  └─────────────────────────────┘   │                                  │
   │  └───────────┬───────────────┬────────┘                                  │
   │              │ ⑥             │ ⑦                                         │
   │              ▼               ▼                                           │
   │  ┌────────────────────┐  ┌────────────────────────┐                      │
   │  │ 物理机 C：macOS     │  │ 目标服务器群（Linux x86-64）│                    │
   │  │ agent macos-arm64  │  │  deploy/hosts 所列        │                    │
   │  │ 【待定】            │  │  · systemd 托管 dsh       │                    │
   │  │ 只跑 verify（C1/C2）│  │  · web 仅绑 127.0.0.1:3080│                    │
   │  └────────────────────┘  └────────────────────────┘                      │
   └──────────────────────────────────────────────────────────────────────────┘
```

**关键点**：

- **A（Gerrit）与 B（Jenkins）是两台独立物理机**——A 不承担构建，B 不承担评审数据。
- **C（macOS agent）是必需的，不是可选**：C1/C2 要求原生依赖各平台各自构建，
  Linux 节点**无法**替代 macOS 节点的验证价值（详见 [cicd_architecture.md](cicd_architecture.md) §4.2）。
- **目标服务器群与 A/B 是不同机器**：它们跑 DSH 服务本身，由 `deploy/hosts` 列出（实测）。

---

## 2. 机器角色与规格

> 规格为**粗估**，需按实际负载调整。【待定】处按你的实际填写。

| 机器 | 角色 | 规格（粗估） | 关键负载 |
| --- | --- | --- | --- |
| **A：Gerrit 服务器** | 权威 git 仓 + Change 评审 | 【待定】；建议 4C/8G/100G+ SSD | git 存储、评审数据库（内置 H2 或外置 PG）、Stream Events 长连接 |
| **B：Jenkins 服务器** | Controller + `linux-x86_64` 内置节点 | 【待定】；**建议高配**：`make setup` 是真实构建（含 harness 原生编译，C3） | 并发构建、pnpm store 缓存、harness 原生编译（吃 CPU 与磁盘） |
| **C：macOS agent** | `macos-arm64` 构建节点 | Apple Silicon，【待定】 | 同 B 的构建负载（另一平台） |
| **目标服务器群** | 跑 DSH 服务 | 见 [../deploy.md](../deploy.md) | 服务运行 + systemd |

> ⚠️ **B 的磁盘要留足**：`make setup` 会在**每个** agent 的每个 workspace 各拉一份完整
> submodule 树 + `node_modules`（C2 禁止跨平台复用，也不能靠拷贝复用），
> 且 harness 原生编译产物不可跨 workspace 复用。建议配置 pnpm store 共享 + workspace 清理策略。

---

## 3. 网络与端口

| 源 | 目标 | 端口/协议 | 用途 | 备注 |
| --- | --- | --- | --- | --- |
| 开发者 Mac | A: Gerrit | **SSH 29418** | `git push refs/for/main` | 需 SSH key 注册 |
| 开发者 Mac | A: Gerrit | HTTPS 8080（或 443 反代） | Web 评审界面 | |
| A: Gerrit | B: Jenkins | **HTTPS 8080** | Stream Events 推送 | Gerrit 主动推事件；需网络可达 |
| B: Jenkins | A: Gerrit | SSH 29418 / REST | 拉代码、回写 `Verified` | 用**专用账号**，勿用个人凭据 |
| B: Jenkins | GitHub | HTTPS 443 | 拉 submodule（§5 见 [cicd_architecture.md](cicd_architecture.md) §4.1） | **若内网不通，需镜像/代理** |
| B: Jenkins | 目标服务器群 | **SSH 22**（免密，`BatchMode=yes` 实测） | 部署 | sudo 需免密或部署账号为 root（实测约束） |
| B: Jenkins | C: macOS agent | SSH 22 或 JNLP | agent 接入 | |
| 任意 | 目标服务器 3080 | **不通** | — | web 仅绑 `127.0.0.1`，健康检查必须本机（实测） |

> 🔴 **网络可达性是本方案最大的落地风险**（[cicd_architecture.md](cicd_architecture.md) §9 U2）。
> 特别是 **B → GitHub**：若 Jenkins 服务器在纯内网，`make setup` 拉不到 submodule，
> 必须走 §4.1 的方案 B（镜像）或 C（`insteadOf` 改写）。

---

## 4. 安装与初始化顺序（设计）

顺序有依赖关系，不要打乱：

```
① C（macOS agent）接入 Jenkins —— 先做，因为它是验证链的一环
② A（Gerrit）
   a. 安装 Gerrit（【待定】版本；需 Java 运行时）
   b. 创建 superproject 仓库
   c. 配置 Access Rights（refs/heads/main 的 Submit 权限）
   d. 开放 Stream Events
   e. 分发 commit-msg hook（开发者本地安装一次）
③ B（Jenkins）
   a. 安装 Jenkins + 所需插件（见 cicd_engineering.md §2.5）
   b. 配置凭据（Gerrit 账号、ssh deploy key、目标服务器 ssh）
   c. 建 verify / deploy / release 三个 job
   d. 接入 Stream Events → verify job
④ 超级仓库迁入 A
   a. 从 GitHub 或本地克隆，推入 A
   b. 验证 submodule 在 A 上的行为（★ 本方案最不确定的一点，见 §6）
⑤ 与现有 Actions 并行跑，结论比对（迁移阶段 P2 的验收点）
```

---

## 5. 备份与恢复

| 对象 | 内容 | 建议 |
| --- | --- | --- |
| A: Gerrit 仓库 | git 数据 + 评审元数据（`refs/changes/*`、账户、权限） | 定期快照；**评审元数据不在 git 对象里**，别只备份 bare repo |
| A: Gerrit 配置 | `etc/gerrit.config`、`etc/secure.config`、SSH host key | 与数据分开备份 |
| B: Jenkins | `JENKINS_HOME`（job 定义、构建历史、凭据） | **凭据加密密钥（`secrets/`）必须一起备份**，否则恢复后凭据作废 |
| C: macOS agent | 基本无状态（workspace 可重建） | 记录工具链版本即可 |
| 目标服务器群 | `$DEPLOY_DIR` + `$DEPLOY_DIR-snapshot`（实测） | 已有快照机制，见 [../deploy.md](../deploy.md) |

> ⚠️ **B 的 `JENKINS_HOME/secrets/` 与 A 的 `secure.config` 是两处最容易漏的**——
> 它们不在常规 git 备份里，丢了要重配所有凭据。

---

## 6. 与目标服务器部署的关系（不要混淆）

本仓有**两套完全不同的「部署」**，文档里容易混：

| | 本文件讲的 | [../deploy.md](../deploy.md) 讲的 |
| --- | --- | --- |
| 部署什么 | **CI/CD 基础设施**（Gerrit + Jenkins + agent） | **DSH 服务本身** |
| 目标机器 | A / B / C | `deploy/hosts` 所列服务器群 |
| 执行者 | 人工（一次性） | `make deploy` → `deploy-remote.sh` |
| 频率 | 一次 + 偶尔升级 | 每次发版 |
| 脚本 | 无（本文为设计） | `scripts/deploy-remote.sh` + `deploy/remote-install.sh`（实测） |

> **注意**：CI/CD 基础设施本身**也**可以用 Jenkins 管（"管 CI 的 CI"），
> 但那会让故障域自噬（Jenkins 挂了就修不了 Jenkins）。**建议保持人工运维**。

---

## 7. 待定项（需要你提供实际值）

| # | 项 | 影响 |
| --- | --- | --- |
| D1 | A / B / C 的**实际 IP 与主机名** | 网络配置、证书 CN、SSH known_hosts |
| D2 | 三台机器的**实际规格** | 并发构建数、pnpm store 大小 |
| D3 | 内网**能否直连 GitHub** | 决定 submodule 策略（§3 的 🔴） |
| D4 | Gerrit 版本与**账户后端**（内置 H2 / LDAP / 外部 PG） | 影响评审数据备份方式（§5） |
| D5 | Jenkins 的**认证源**（本地 / LDAP / OIDC） | 影响谁能操作 deploy job |
| D6 | **证书**：自签 / 内网 CA / 公网证书 | Gerrit 与 Jenkins 的 HTTPS 配置 |
| D7 | C（macOS agent）是**专用 Mac mini** 还是复用某台开发机 | 复用开发机 = 构建受人为中断影响 |
