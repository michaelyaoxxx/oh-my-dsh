---
title: DSH 超级仓库 CI/CD 总体架构
doc-version: 1.0.0
status: draft
last-updated: 2026-09-14
applies-to: dsh 超级仓库（main 分支）
---

# 总体架构：dsh 主仓 + Gerrit + Jenkins

> **标注约定**：本文每条结论都标了来源。
> **「实测」**= 读过本仓源码/脚本/工作流并核对过；**「设计」**= 目标态方案，尚未落地验证；
> **「调研」**= 来自社区资料（见 [reference/community-survey.md](reference/community-survey.md)），未经本仓验证。

---

## 1. 现状（as-is，全部实测）

### 1.1 编排入口：`Makefile` 是薄入口

七个目标，逻辑全在 `scripts/*`（[Makefile](../../Makefile)，实测）：

| 目标 | 做什么 | 落到哪 |
| --- | --- | --- |
| `make setup` | 拉 submodule + harness 构建 + 各插件依赖与构建（幂等） | `scripts/setup.sh`（222 行） |
| `make link-plugins` | 把 `plugins/*` 中可挂载的 bundle link 进 profile `dsh` | `scripts/link-plugins.sh`（208 行） |
| `make dev` | link + 启动 Web（`--profile dsh`），日志落 `log/dev-*.log` | 同上 + `pnpm dsh` |
| `make dev-tui` | link + 启动 TUI（`--profile tui`）；**刻意不落日志**（TUI 有 TTY 校验） | `scripts/link-tui.sh`（65 行） |
| `make deploy` | 部署到 `deploy/hosts` 所列服务器 | `scripts/deploy-remote.sh`（288 行） |
| `make release VERSION=` | 校验 pin → 打 tag → push | `scripts/release.sh`（107 行） |
| `make help` | 列出目标 | — |

### 1.2 CI：GitHub Actions 两条工作流（实测）

**`verify.yaml`** — 触发：push 到 `main`、任何 PR。跑在 `ubuntu-latest`（x86-64，与服务器同平台）：

```
checkout(submodules: recursive, fetch-depth: 0)
→ pnpm 11.7.0 / Node 22
→ ① pin 一致性：分支 pin 三条（dsh-web/main、mineru/master、automation/adapt-*）
              tag  pin 九条（harness + 8 个插件）
→ ② shellcheck v0.11.0 -S style（scripts/*.sh + deploy/remote-install.sh）
→ ③ make setup（真实构建，非 mock）
→ ④ scripts/link-plugins.sh
→ ⑤ 冒烟：起 `dsh --profile dsh --no-open`，轮询 127.0.0.1:3080，
     200/303/401 任一即视为就绪（401 是认证 gate 生效）
```

**`release.yaml`** — 触发：push tag `v*`。权限 `contents: write`：

```
构建 + 冒烟（与 verify 同款）
→ 生成快照清单 RELEASE_NOTES.md（11 个 submodule 的 sha + 描述）
→ softprops/action-gh-release@v2 建 GitHub Release
```

### 1.3 发布：`scripts/release.sh`（实测）

```
① 工作区必须干净（git diff / diff --cached 都为空）
② pin 校验，两种语义分别校验：
   - check_pin      （分支 pin）→ 与 origin/<branch> 比对，拦截「本地未推送 commit 被误 pin」
   - check_pin_tag  （tag pin）→ 与 <tag>^{} 比对（^{} 剥离 annotated tag；对轻量 tag 是 no-op）
③ VERSION 参数校验 + tag 已存在则拒绝
④ 生成 RELEASE_NOTES.md 快照（**当前只写 harness 与 dsh-web 两行**）
⑤ 强制要求存在名为 origin 的远端；git tag -a → git push origin <tag>
```

### 1.4 部署：`scripts/deploy-remote.sh`（实测）

每台服务器六步，任一步失败**回滚到 `$DEPLOY_DIR-snapshot`**：

```
① 预检：免密 ssh（BatchMode=yes）可达；服务器需 rsync/curl/systemctl
② 快照上一版本到 $DEPLOY_DIR-snapshot（全新机器跳过）
③ rsync 主仓（含 submodule 检出内容）→ $DEPLOY_DIR
   排除 .git / .dsh / node_modules；**依赖一律服务器侧构建**
④ 服务器执行 deploy/remote-install.sh（427 行，sudo，同一 root 身份）
   —— 顺带按 $DEPLOY_DIR 渲染并安装 dsh.service
⑤ systemctl daemon-reload → enable --now → restart
⑥ 健康检查：**必须在服务器本机** curl 127.0.0.1:3080
```

> 第 ⑥ 步的限制是硬性的：web 服务默认只绑 `127.0.0.1`（`--host 0.0.0.0` 被 CLI 有意拒绝），
> 所以从外部 curl `<server>:3080` **恒失败**。

### 1.5 部署产物

| 文件 | 说明 |
| --- | --- |
| `deploy/hosts` | 服务器清单，每行 `user@host`；**已 gitignore**，模板见 `hosts.example` |
| `deploy/dsh.service` | systemd **模板**，`@DEPLOY_DIR@` 由 `remote-install.sh` 渲染。`DSH_HOME=@DEPLOY_DIR@/.dsh`，`COREPACK_DEFAULT_TO_LATEST=0`，`Restart=on-failure` |
| `deploy/remote-install.sh` | 服务器侧安装：工具链校验 + 依赖安装 + 渲染 unit |

### 1.6 硬约束（来自 [AGENTS.md](../../AGENTS.md) 与 [README.md](../../README.md)，实测）

| # | 约束 | 对 CI 设计的直接含义 |
| --- | --- | --- |
| C1 | 本地 macOS M4（arm64）、服务器 Linux x86-64 | **构建节点必须覆盖两种架构** |
| C2 | **原生 Node 依赖必须各平台各自构建，严禁跨平台拷贝 `node_modules`** | 产物**不可跨平台复用**；macOS 产物不能给服务器用 |
| C3 | harness `pnpm build` 先跑 `build:native-system`（需 C 编译器 + Node 开发头文件） | 构建节点需要完整工具链，不能是精简镜像 |
| C4 | Node `^22.19 \|\| >=24`（23 不满足）；pnpm 由 corepack 按各仓 `packageManager` 解析 | 节点工具链需预置，且**各子仓 pnpm 版本可能不同** |
| C5 | 插件以 submodule 引入 `plugins/`；**detached HEAD 是特性**，更新 pin 是显式动作 | CI 不得自动 `submodule update --remote` |
| C6 | profile 名固定 `dsh`（另有 `tui`） | 所有命令显式带 `--profile` |
| C7 | 插件仓发版（npm publish / tag）由插件仓自行完成 | 本仓 CI 不做插件发布 |

---

## 2. 目标与动机

### 2.1 为什么要在 GitHub Actions 之外引入 Gerrit + Jenkins

**实测的现状局限**：

1. **门禁只有一道**：`verify.yaml` 在 push 到 main 与 PR 时跑，但没有「提交前的评审门禁」——
   变更是先合入再验证。Gerrit 的 Change 模型恰好补这一环。
2. **仓库当前没有可用的 PR 流程承载**：本仓是**超级仓库**（1 个 harness + 10 个插件 submodule），
   跨仓变更（主仓脚本 + 插件 pin）无法用一个 PR 表达清楚。
3. **构建平台单一**：Actions 只跑 `ubuntu-latest`，**macOS 侧（C1）完全没有 CI 覆盖**——
   而 AGENTS.md 明确要求双平台各自构建。
4. **部署与 CI 脱节**：`make deploy` 是**显式本地动作、明确不上 CI**（AGENTS.md），
   部署过程没有审计记录、没有统一的执行环境。

**Gerrit 补什么**：Change-based 评审、`Change-Id` 贯穿、`Code-Review` / `Verified` 双标签门禁、
submit 规则（可强制「Verified 由 Jenkins 打」「必须 rebase 到最新」）。

**Jenkins 补什么**：内网/私有构建（不依赖 GitHub 可达性）、**多架构构建节点**、
把 `make setup / link-plugins / deploy / release` 编排成可审计的流水线、以及部署的执行记录。

### 2.2 为什么保留 GitHub Actions

- **开源后可能切回**：Actions 零运维、对社区贡献者友好。保留它 = 保留一条已验证可用的通路。
- **它现在就能跑**：`verify.yaml` / `release.yaml` 均已实测可工作，拆掉是净损失。
- **两者可并存**：Gerrit 侧管内部变更门禁，GitHub 侧管 tag 发布与对外可见性。

> 因此目标态是**并存**，不是替换：**Gerrit 管代码进得来，Jenkins 管构建/部署/发布，
> GitHub Actions 作为并行通路保留**。

---

## 3. 目标架构（to-be，设计）

### 3.1 架构图

```
  开发者（本地 macOS M4）
        │  git push origin HEAD:refs/for/main     ← Gerrit Change 工作流
        ▼
 ┌──────────────────────────────────────┐
 │  Gerrit（代码评审 + 门禁）             │
 │   · Change-Id / 评审历史               │
 │   · 标签：Code-Review（人）            │
 │           Verified（Jenkins 打）       │
 │   · submit 规则：两标签齐备 + rebase 到最新 │
 └───────────────┬──────────────────────┘
                 │ Stream Events（patchset-created / change-merged）  [设计]
                 ▼
 ┌──────────────────────────────────────┐
 │  Jenkins（构建 / 部署 / 发布）         │
 │                                      │
 │  ┌── agent: linux-x86_64 ──────────┐ │
 │  │ ① verify：pin 校验 + shellcheck  │ │
 │  │           + make setup + 冒烟    │ │
 │  │ ② deploy：make deploy（仅此平台）│ │
 │  └─────────────────────────────────┘ │
 │  ┌── agent: macos-arm64 ───────────┐ │
 │  │ ① verify：make setup + 冒烟      │ │
 │  │   （C1/C2：原生依赖必须本机构建）│ │
 │  └─────────────────────────────────┘ │
 └───────────────┬──────────────────────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
  目标服务器群        制品/发布记录
  (deploy/hosts)     (tag / Release)
  systemd 托管
```

### 3.2 角色划分

| 环节 | 由谁负责 | 对应现有资产 |
| --- | --- | --- |
| 代码评审 | **Gerrit** | 当前无（GitHub PR 未启用） |
| pin 一致性门禁 | **Jenkins**（linux 节点） | `verify.yaml` ①②（实测逻辑可直接移植） |
| 静态检查 | **Jenkins**（linux 节点） | `verify.yaml` shellcheck 段 |
| 构建验证 | **Jenkins**（linux + macOS 双节点） | `make setup` |
| 冒烟 | **Jenkins**（双节点） | `verify.yaml` ⑤ 的轮询逻辑 |
| 部署 | **Jenkins**（linux 节点） | `make deploy` |
| 发布（打 tag / 建 Release） | **Jenkins**（linux 节点）+ GitHub Actions | `make release` + `release.yaml` |
| 对外可见性 | **GitHub** | `release.yaml`（保留） |

### 3.3 数据流：一次变更的生命周期（设计）

```
① 开发者本地：make setup && make dev 自测
② git push origin HEAD:refs/for/main   → 产生 Change（含 Change-Id）
③ Gerrit 触发 Stream Event → Jenkins「verify」job
④ Jenkins(linux)   ：pin 校验 → shellcheck → make setup → link → 冒烟
   Jenkins(macos)  ：make setup → link → 冒烟        ← C1/C2 要求的第二平台
⑤ 结果回写 Gerrit：成功打 Verified+1，失败 Verified-1（附日志链接）
⑥ 人工 Code-Review+2
⑦ 两标签齐备 + 已 rebase → Gerrit submit 合入 main
⑧ change-merged 事件 → Jenkins「post-merge」job
⑨ 需要发布时：make release VERSION=… → tag push
   → 触发 GitHub Actions release.yaml（保留通路）建 Release
```

### 3.4 控制流：门禁位置

| # | 门禁 | 位置 | 拦什么 |
| --- | --- | --- | --- |
| G1 | `Change-Id` 存在 | Gerrit commit-msg hook | 无法追踪的提交 |
| G2 | pin 与远端一致 | Jenkins verify | 本地未推送 commit 被误 pin（现 `release.sh` ②的语义） |
| G3 | shellcheck 全绿 | Jenkins verify | 脚本静态缺陷 |
| G4 | `make setup` 成功 | Jenkins verify（双平台） | 构建破坏、跨平台假设 |
| G5 | 冒烟通过 | Jenkins verify（双平台） | 启动即崩、profile 组合树损坏 |
| G6 | `Code-Review+2` | Gerrit | 未经人工评审 |
| G7 | `Verified+1` | Jenkins 回写 | 未经 CI |
| G8 | 工作区干净 + pin 校验 | `release.sh`（**现有逻辑，不改**） | 带着脏工作区或错误 pin 发布 |

---

## 4. 关键设计决策

### 4.1 submodule 托管：Gerrit 只托管超级仓库（设计，本次最重要的决策）

本仓有 **11 个 submodule**（harness + 10 个插件），它们指向 **GitHub 上的不同远端**。
Gerrit 通常托管单个 git 仓库。三种做法：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A（推荐）** | **Gerrit 只托管超级仓库**；submodule 仍从 GitHub 拉 | Jenkins 节点需能访问 GitHub；内网需代理或镜像 |
| B | 把 11 个 submodule 全部镜像进 Gerrit | 运维重；且这些是**上游第三方仓**，镜像后与上游同步复杂 |
| C | 内网做 GitHub 只读镜像，`insteadOf` 改写 URL | 多一层运维，但对外网依赖最小 |

> **建议先走 A**：本仓的设计意图就是「superproject 编排上游 pin」（见
> [spec](../superpowers/specs/2026-09-08-dsh-superproject-design.md)），
> submodule 本就指向上游。B/C 只在「Jenkins 节点无外网」时才需要。

### 4.2 双平台构建：产物不共享，只共享结论

C1+C2 决定：**macOS 产物不能给 Linux 用**（反之亦然）。因此：

- Jenkins 需要**两类 agent**，各自跑完整的 `make setup`；
- 共享的是**验证结论**（Verified 标签），**不是产物**；
- 部署只面向 Linux（`deploy-remote.sh` 服务的是服务器，实测）；
- macOS 节点的价值在于**提前发现只在 arm64/macOS 上出现的构建问题**。

### 4.3 `origin` 的语义要重新定义（设计，易踩）

`release.sh` **强制要求存在名为 `origin` 的远端**（实测，第 99-104 行），否则拒绝发布。
引入 Gerrit 后，`origin` 很可能被指到 Gerrit，于是：

- `check_pin` 拉的是 `origin/<branch>` —— 变成从 Gerrit 拉子仓分支，**而子仓根本不在 Gerrit 上**；
- `git push origin <tag>` —— 会把 tag 推到 Gerrit，而不是 GitHub。

**处置（择一）**：① 保留 `origin` 指 GitHub，Gerrit 用另一个远端名（如 `gerrit`）；
② 改造 `release.sh`，把发布目标远端显式参数化。**建议 ①**——不动已验证的脚本。

### 4.4 发布快照清单的两处不一致（实测发现）

| | 快照包含 |
| --- | --- |
| `release.sh` 生成 | **仅 harness + dsh-web** 两行 |
| `release.yaml` 生成 | **11 个 submodule 全部** |

两者不一致：本地 `make release` 打的 tag 注解里只有两条，而 GitHub Release 的 body 有十一条。
引入 Jenkins 后如果由 Jenkins 执行发布，**必须先统一**（建议以 `release.yaml` 的 11 条为准）。

### 4.5 部署仍应是显式动作（沿用 AGENTS.md）

AGENTS.md 明确「部署是显式动作、不上 CI」。引入 Jenkins 后**建议维持这一语义**：
Jenkins 提供**可执行的 deploy job**（带审计与统一环境），但**不由 merge 自动触发**——
由人工点按钮。这样既拿到审计，又不改变「部署是显式决定」的约定。

---

## 5. 与现有资产的复用关系

**不要另起一套**——现有脚本已经是收敛后的单一入口，CI 的职责是调用与编排：

| 现有资产 | 在目标架构中的位置 | 改动 |
| --- | --- | --- |
| `scripts/setup.sh` | Jenkins 双节点 verify 的核心步骤 | 无 |
| `scripts/link-plugins.sh` | verify 的冒烟前置 | 无 |
| `scripts/release.sh` | Jenkins release job 调用 | 见 §4.3（origin 语义） |
| `scripts/deploy-remote.sh` | Jenkins deploy job 调用 | 无 |
| `deploy/remote-install.sh` | 不变（服务器侧执行） | 无 |
| `.github/workflows/verify.yaml` | **保留**；其 pin 校验与冒烟逻辑**移植**进 Jenkinsfile | 无（保留原样） |
| `.github/workflows/release.yaml` | **保留**；开源后的对外发布通路 | 见 §4.4（快照口径统一） |

---

## 6. 迁移路径（设计，分四阶段）

| 阶段 | 做什么 | 验收标准 | 风险 |
| --- | --- | --- | --- |
| **P0 准备** | 确定 Jenkins agent 拓扑（linux + macos 各一）；确定 submodule 拉取路径（§4.1 方案 A/B/C） | 两个节点都能跑通 `make setup` | 外网可达性 |
| **P1 Gerrit 接入** | 部署 Gerrit；超级仓库迁入；配置 Access Rights 与 submit 规则（G1/G6） | 能走通 `push refs/for/main` → 评审 → submit | 团队工作流切换成本 |
| **P2 Jenkins verify** | 移植 `verify.yaml` 的 ①②⑤ 到 Jenkinsfile；接 Stream Events；回写 Verified（G2-G5、G7） | **GitHub Actions 与 Jenkins 并行跑，结论一致** | 双跑期间的资源开销 |
| **P3 部署/发布** | 加 deploy job（人工触发）与 release job；统一快照口径（§4.4） | `make deploy` 与 Jenkins deploy 结果一致 | 部署语义变更需团队确认 |

> **P2 的「双跑一致」是本方案的关键验收点**：在拆掉任何 GitHub Actions 之前，
> 必须先证明 Jenkins 侧得到**相同结论**。这也符合本仓一贯做法——
> 新通路先与已验证通路并行，一致后再切换。

---

## 7. 未决与风险

| # | 事项 | 状态 |
| --- | --- | --- |
| U1 | Jenkins agent 的 macos-arm64 节点从哪来（物理机 / 云 / 自建） | **未决** |
| U2 | 内网能否直连 GitHub（决定 §4.1 走 A 还是 B/C） | **未决** |
| U3 | Gerrit 的 submit 规则细则（是否强制 rebase、是否允许 bypass） | **未决** |
| U4 | `release.sh` 的 origin 语义改造方式（§4.3） | **未决**，建议方案 ① |
| U5 | 双跑（Actions + Jenkins）持续多久后切换 | **未决** |
| R1 | **Gerrit + submodule 组合是本方案最不确定的部分**：Gerrit 对 submodule 的支持不像 GitHub 那样有成熟流程，`refs/for/` 工作流下 submodule 的 pin 变更评审需要实测验证 | **风险，需 P1 阶段专门验证** |
| R2 | Jenkins 双节点意味着**构建时间翻倍**（`make setup` 是真实构建，含 harness 原生编译） | 需实测耗时后决定是否只在 PR 上跑双平台 |
| R3 | 迁移期两套 CI 并行，**pin 不一致可能被两套规则分别判定**（如 Actions 的 tag loop 与 Jenkins 的实现漂移） | 建议让 Jenkins 直接调用同一份校验脚本，而非复制逻辑 |
