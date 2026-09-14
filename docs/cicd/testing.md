---
title: DSH 超级仓库自动化测试方案
doc-version: 1.0.0
status: draft
last-updated: 2026-09-14
applies-to: dsh 超级仓库（main 分支）
---

# 自动化测试方案

> **标注约定**：**「实测」**= 本仓已实际跑过并核对；**「设计」**= 目标态，尚未落地。
>
> 本文回答：**发布前如何自动化验证「harness 内核 + 各插件 + 它们组合起来」的功能**。
> 配套阅读：[cicd_architecture.md](cicd_architecture.md)（架构）、[cicd_engineering.md](cicd_engineering.md)（工程细节）、[deployment.md](cicd_deployment.md)（物理部署）。

---

## 1. 现状：巨大的空白（实测）

### 1.1 submodule 侧测试资产很丰富

| 仓 | 测试文件数 | 运行器 | 备注 |
| --- | --- | --- | --- |
| **harness**（内核） | **962**（265 个包带 `tests/`） | vitest | 另有 e2e / bench / snapshot / expected 多套 config |
| dsh-web | **358** | `pnpm -r test` | monorepo 递归 |
| dsh-better-sidebar | 124 | vitest | 另有 `test:mount` / `test:mount:aggregate` |
| dsh-market | 61 | vitest | 另有 `test:compat` / `test:web` |
| modlens | 44 | vitest | |
| dsh-tui | 37 | `verify:*`（~90 个脚本） | 无 `test` 脚本；覆盖在 `verify:build` 里 |
| modsearch | 27 | vitest | 另有 `test:coverage` |
| dsh-at-file | 13 | vitest | |
| dsh-agent-teams | 12 | `verify:*`（8 个脚本） | 无 `test` 脚本 |
| dsh-automation | 11 | tsx | |
| dsh-plugin-mineru | 1 | vitest | |

### 1.2 但本仓 CI **一个都没跑**（实测）

现有 `verify.yaml` 的全部内容是：

```
pin 校验 → shellcheck → make setup（构建）→ link-plugins → 冒烟（起服务，看 3080 有无响应）
```

**冒烟只验证「服务能起来」，不验证「任何功能可用」。** 上面 1600+ 个测试文件，
以及它们覆盖的 harness 内核与 10 个插件，**在本仓的发布流程里完全不可见**。

### 1.3 后果：一跑就有红的（本轮实测）

随手跑最小的那个（`dsh-plugin-mineru`，1 个文件 29 个用例）：

```
Test Files  1 failed (1)
     Tests  1 failed | 28 passed (29)
  × maybeTruncateMd > truncates and saves full content when over limit
    → expected 202 to be less than 200                      exit=1
```

**根因**（读源码确认）：截断函数的提示语**内嵌了绝对路径**——

```js
content: md.slice(0, maxChars) + `\n\n... [truncated; full content saved to ${fullMdPath}]`
```

`maxChars=100` 时：截出的 100 字 + 提示语（含 macOS 的长 tmpdir 路径，约 102 字）= **202 > 原文 200**。
「截断」反而让内容变长。

**更关键的是它平台敏感**（实测对照）：

| TMPDIR | 结果 |
| --- | --- |
| `/tmp`（短，Linux 默认） | ✅ **29 passed** |
| macOS 默认 `/var/folders/<长哈希>/T` | ❌ **1 failed** |

> 🔴 **同一个 commit，Linux 绿、macOS 红。** 这条同时说明三件事：
> ① 该实现缺少「提示语比省下的还长」时的兜底（上游缺陷，值得报）；
> ② 该测试的 fixture 不现实（`maxChars` 小于提示语长度）；
> ③ **只在 Linux 跑 CI 会掩盖这类问题**——这是「必须双平台测试」最直接的实证
> （呼应 [cicd_architecture.md](cicd_architecture.md) §4.2 与硬约束 C1/C2）。

---

## 2. 测试分层（设计）

```
L0  静态检查          shellcheck / lint / typecheck                ← 快，已有部分
L1  各 submodule 自测  每个仓跑自己的 test 脚本（1600+ 用例）        ← 最大空白
L2  组合层冒烟        make setup + link + 起服务                    ← 已有
L3  组合层功能验收     通过组合后的 profile 实际调功能                ← 本仓特有，完全缺失
L4  端到端（E2E）     真机/真模型跑通一条主链路                      ← 最贵，按需
```

### 2.1 L0 静态（部分已有）

| 项 | 现状 |
| --- | --- |
| shellcheck（`-S style`，固定 0.11.0） | ✅ 已有（`verify.yaml`） |
| pin 校验 | ✅ 已有（`scripts/check-pins.sh`） |
| harness `lint`（oxlint）/ `typecheck` | ❌ **未跑**——harness 自带这两个脚本（实测） |

### 2.2 L1 各 submodule 自测（**最大缺口，优先补**）

**统一入口就是各仓自己的 `test` 脚本**（实测：运行器不统一，vitest / tsx / `pnpm -r` / `verify:*` 都有，
但**入口统一**）。编排思路与 `scripts/setup.sh` 的插件循环一致：

```
for 每个 submodule（harness + plugins/*）:
    若有 test 脚本 → 执行；无则跳过并记录（dsh-tui / dsh-agent-teams 用 verify:* 覆盖）
```

**前置依赖**：必须先 `make setup`（测试要 `node_modules`）。

**注意（实测）**：
- harness 的 `test` 是 `pnpm run build:native-system && vitest run` —— **需要 C 编译器**（硬约束 C3），不能是精简镜像。
- dsh-tui 的覆盖在 `verify:build`（~90 个脚本），而它的**构建过程本身就会跑**——`make setup` 已间接覆盖。
- **建议给这一步加 `TMPDIR=/tmp`**：本轮实测证明 macOS 的长 tmpdir 会让部分测试假红
  （见 §1.3）。`scripts/setup.sh` 已有同款处置（[cicd_engineering.md](cicd_engineering.md) §5.2）。

### 2.3 L2 组合层冒烟（已有）

即现有 `verify.yaml` 的 ⑤：起 `dsh --profile dsh --no-open`，轮询 3080，
`200/303/401` 任一即视为就绪。**保持原样**——它验证的是「profile 组合树没坏」。

### 2.4 L3 组合层功能验收（**本仓特有，完全缺失**）

**为什么必须有**：本仓的价值在于**组合**（profile bundles + `patches/*.yml` + 插件协同）。
**各仓自测全绿 ≠ 组合可用**——实例（本仓实测积累）：

- modsearch 的 patch 抹掉了 base `web` 行的 `fetchProvider`（整表替换语义），
  **各仓自测与冒烟全绿**，取 fetch 时才会报 `WEB_PROVIDER_AMBIGUOUS`
  （见 `patches/restore-web-fetch-provider.yml`）。
- dsh-better-sidebar 曾被两个 entry 加载（同一插件挂两次），需要 `disabled` patch 消解。
- dsh-remote-web-ui 的 LAN bind 块与 `merge-profile-patch.mjs` 打架，**要重启两次才生效**。

**这些都不在任何 submodule 的测试里**，因为它们只在组合后才出现。

**建议的最小验收集**（设计）：

| # | 验收项 | 怎么验 | 现状 |
| --- | --- | --- | --- |
| F1 | profile 组合树正确 | `dsh --profile dsh --dump-config` 无 warn，关键 section 齐全 | 手工做过，未自动化 |
| F2 | 补丁未抹掉旁键 | **对比装前/装后的 dump**（§2.4 的 modsearch 教训） | ❌ 无 |
| F3 | 插件面板可见 | 起服务后查路由/资源返回 200 | ❌ 无 |
| F4 | 端到端一条链路 | headless 跑一个真任务，断言退出码（见 §4） | ❌ 无 |

> **F2 是关键补丁**：它是唯一能抓住「patch 整表替换抹旁键」这类静默缺陷的手段，
> 成本却很低（存一份 dump 基线 + diff）。

### 2.5 L4 端到端（按需）

真机 + 真模型跑通一条主链路。**成本高**（要 API key、会产生费用、结果不确定），
**不建议放进每次 CI**；建议作为**发布前的最终验收**，人工触发。

`dsh-headless` 正是为此设计的（[cicd_architecture.md](cicd_architecture.md) §5）：
一次性任务、语义化退出码，天然适合做这个角色。

---

## 3. 「需要修改各个 submodule」的连带影响（**必须先定**）

前提：发布前要对插件与 harness 内核做功能性验证，**理论上需要改 submodule 子仓**。
这件事**改变了本仓与上游的关系**，必须先定策略。

### 3.1 现状：submodules 是上游第三方仓的 pin

`plugins/*` 现在 pin 的是**别人写的代码**（MIT / Apache-2.0 / AGPL-3.0）。
我们**不能**直接把修改提交到 pin 上（detached HEAD，提交会丢）。

### 3.2 本仓已有的先例：fork + 分支 pin

`dsh-automation` 已经这么做过了（[AGENTS.md](../../AGENTS.md) 记在硬约束里）：

```
plugins/dsh-automation → url 指向本仓 fork michaelyaoxxx/dsh-automation
                       → pin 分支 adapt/harness-0.1.5-rc.2
                       → upstream remote 指回 titanwings 以便同步上游
```

**理由**：上游不含 harness 0.1.5-rc.2 所需的适配，适配提交只能留在 fork 上。

### 3.3 若推广到更多 submodule，连锁改动清单

| # | 改动 | 位置 |
| --- | --- | --- |
| 1 | `plugins/<name>` 的 URL 改为本仓 fork | `.gitmodules` |
| 2 | pin 语义从 **tag pin 改为分支 pin** | `scripts/check-pins.sh`（tag → branch 分组） |
| 3 | CI 的 tag loop / `check_pin_tag` 条目相应变化 | 由 `check-pins.sh` 统一，故**只改一处**（这正是收敛的收益） |
| 4 | 上游同步成为**常态化任务**（fork 会落后） | 新增流程，见 §3.4 |
| 5 | fork 的 divergence 要在 README/AGENTS 记录 | `AGENTS.md` 稳定分支行 |

> ✅ **一个好消息**：因为 pin 清单已收敛到 `scripts/check-pins.sh`（[cicd_engineering.md](cicd_engineering.md) §1.1），
> 第 2/3 项只需改**一个文件**。若在上次收敛之前做这件事，就得同时改三处。

### 3.4 上游同步流程（设计，新增）

fork 之后必须定期吸收上游，否则修复永远拿不到：

```
① 在 fork 内：git fetch upstream && git merge/rebase upstream/<branch>
② 本地：git -C plugins/<name> push origin <适配分支>
③ 主仓：git add plugins/<name> 更新 pin → 走评审
④ 跑 L1 + L3 测试确认没有回归
```

**建议**：把「fork 落后上游多少」也纳入 `check-pins.sh` 的输出或一个独立检查——
本仓已有这个需求的实例（[../backlog.md](../backlog.md) B1/B2：dsh-web 落后 191、mineru 落后 7）。

### 3.5 一个必须先回答的问题

> **哪些 submodule 真的需要改？**

本次实测的 mineru 截断缺陷（§1.3）**完全可以上游报修**，不需要我们改。
**只有当上游不接受、或改动是本仓特有的适配时，才应该 fork。**

建议逐个分类，而不是默认「都改成 fork」：

| 类别 | 处置 | 例 |
| --- | --- | --- |
| 上游缺陷 | **报上游**，等修 | mineru 截断（§1.3） |
| 本仓特有适配 | **fork + 分支 pin** | dsh-automation 的 harness 0.1.5-rc.2 适配 |
| 上游已废弃但我们需要 | fork + 长期维护 | （暂无） |

---

## 4. 编排方案（设计）

### 4.1 落点

| 层 | 落在哪 | 触发 |
| --- | --- | --- |
| L0 | Jenkins verify / GitHub Actions | 每次 push / Change |
| **L1** | Jenkins verify（**双平台**） | 每次 push / Change |
| L2 | 同现有冒烟 | 每次 push / Change |
| **L3** | Jenkins verify（至少 linux 平台） | 每次 push / Change |
| L4 | Jenkins 独立 job | **发布前人工触发** |

### 4.2 新增脚本（与现有收敛思路一致）

```
scripts/test-plugins.sh    # L1：遍历 submodule，跑各自的 test 脚本；输出汇总
scripts/test-compose.sh    # L3：dump 对比（F2）+ 路由可达（F3）+ 可选 headless（F4）
make test                  # L0+L1+L2+L3 的本地入口
```

**为什么做成脚本而不是写进 Jenkinsfile**：同 [cicd_engineering.md](cicd_engineering.md) §1 ——
GitHub Actions 与 Jenkins 都要用，写两份必然漂移。

### 4.3 耗时与成本（**需实测**）

**目前没有实测数据**（本轮只跑了 1 个插件，255ms）。已知的量级参考：

- harness 962 个测试文件 + 需先 `build:native-system`（编译原生模块）——**预计是最慢的一环**
- dsh-web 358 个文件、`pnpm -r test` 递归整个 monorepo
- 双平台 = **两倍**

> ⚠️ 建议先做一次全量计时，再决定：是否全跑、是否只在 PR/Change 上跑双平台、
> 是否对慢仓做「仅跑受影响包」的裁剪。**不要在没有耗时数据的情况下设计并发策略。**

---

## 5. 风险与注意（设计）

| # | 风险 | 说明 |
| --- | --- | --- |
| T1 | **平台敏感测试** | §1.3 已实证一例（TMPDIR 长度）。**双平台跑是唯一解法**，但也意味着「一个平台红」就要定位是缺陷还是环境 |
| T2 | **网络依赖** | harness 的 e2e / 部分测试可能要网络或外部服务；CI 环境需评估 |
| T3 | **时间敏感 / 不确定测试** | 600+ 测试文件里大概率存在。需建立 **quarantine 名单**，而不是简单重试掩盖 |
| T4 | **测试要 node_modules** | 必须先 `make setup`（C2：各平台各自构建），不能靠缓存 `node_modules` |
| T5 | **L1 全绿 ≠ 组合可用** | §2.4 的三个实例已证明。**L3 不可省** |
| T6 | **成本** | 双平台 × (harness 962 + 插件 700+) 的构建与测试；§4.3 需先测耗时 |
| T7 | 子仓测试脚本本身可能是**半成品** | 例如某仓 `test` 为空但有 `verify:*`（dsh-tui / dsh-agent-teams）——编排要能跳过并**明确报告「跳过」**，不要静默当通过 |

---

## 6. 落地顺序建议

| 阶段 | 做什么 | 依赖 |
| --- | --- | --- |
| **A（可立即做）** | `scripts/test-plugins.sh` + `make test`，**本地先跑通**；同时计时（§4.3） | 无，**不依赖 Gerrit/Jenkins** |
| **B** | L3 的 F2（dump 对比基线）—— 成本最低、收益最高的一条 | A |
| **C** | 接进 GitHub Actions 的 verify（先单平台），观察稳定性 | A、B |
| **D** | 接进 Jenkins，加 macOS 平台（T1 要求） | Gerrit/Jenkins 落地 |
| **E** | 定 submodule 修改策略（§3），逐个分类 | 需先回答 §3.5 |

> **建议从 A 开始**：它不依赖任何 CI 基础设施，今天就能做，而且能立刻暴露
> 「跑起来才知道有多少红」的真实规模——**在知道规模之前，谈并发与平台策略都是空谈**。
