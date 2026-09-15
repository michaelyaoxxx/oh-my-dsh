# 整改台账 — T 任务 × R 任务包

| 属性 | 值 |
| --- | --- |
| 用途 | 追踪 review 整改项的**状态与证据**（含已完成项） |
| T 编号来源 | 2026-09-14 评审后的第二轮整改清单（**原先只存在于对话中**，本文件是它唯一的落盘处） |
| R 编号来源 | [reviews/2026-09-14-repository-design-review.md](reviews/2026-09-14-repository-design-review.md) §6 |
| 最后更新 | 2026-09-15 |

## 与 backlog 的分工

| 文档 | 记什么 |
| --- | --- |
| **本文件** | 整改项的**全集**，含已完成项 —— 它的价值是「这件事做过没有、证据在哪」 |
| [backlog.md](backlog.md) | 只记**尚未收口**的事，完成即删除对应条目 |

两者不重复叙述：本文件回答「做过什么」，backlog 回答「还欠什么」。

## 为什么有两套编号

R1-R8 是 review 给出的**任务包划分**（按职责域）；T0-T9 是**实施切分**（按可独立提交的单元）。
两者不是一一对应——一个 R 包常被拆成多个 T，一个 T 也可能同时服务两个 R。保留双编号的理由：
T 编号对应 commit 边界，便于从台账直接跳回证据。

> ⚠️ **教训**：T 清单一度只存在于对话与 commit message 里。上下文压缩后差点丢失。
> 凡是要跨越多次会话追踪的清单，**必须落盘**——本文件就是这条教训的产物。

---

## 总表

| T | 内容 | 状态 | 证据 | 依赖 | → R |
| --- | --- | --- | --- | --- | --- |
| **T0a** | 部署守卫：危险目标硬拒绝、符号链接防护、状态不参与回滚、整批回滚、部署标识 | ✅ 完成 | `1391a20` | — | R3 |
| **T0b** | 状态迁 `/var/lib/dsh`、非 root、systemd hardening、`releases/<digest>` + current 指针 | 🔶 **阻塞** | — | 可验证的 Linux 主机 | R4 |
| **T1** | 文档权威归一（唯一架构入口）+ AGENTS 去漂移 | 🟡 **部分完成** | `5a80706`；残留见 09-15 review P1-5（README/ADR 仍指旧事实源） | — | R1 |
| **T2** | 组件目录单一事实源 + pin 语义拆分 + TUI 转 metadata-only | 🟡 **部分完成** | `8a6d9b9`；P0-1（选择器语义）已修，但字段跨约束未定义（09-15 review P1-4） | — | R2 |
| **T3** | Jenkins 信任边界（presubmit 凭据隔离、受信流水线、controller 0 executors） | ⬜ 规格可写 / **验证阻塞** | — | 第 3 个执行域（见 §T3） | R5, R6 |
| **T4** | 不可变制品 | ⬜ 阻塞 | — | 同 T0b | R4 |
| **T5** | 制品 / 发布状态机 | ⬜ 可做（纯规格） | — | — | R4, R5 |
| **T6** | 状态迁移兼容矩阵 | 🔶 **调研完成，待决策**：不能作为纯文档产出 | 见 §T6 | 需在路径 A/B/C 中选 | R4 |
| **T7** | headless 发布回归 | ⬜ **可实测** | — | 本机可跑 | R5 |
| **T8** | Gerrit / GitHub 出口模型 | ⬜ 可做（纯设计） | — | — | R1 |
| **T9** | GHA 供应链加固（SHA pin + checksum）+ 开源治理文件 | 🟡 **部分完成** | `49180d9`；release 门禁旁路已修，但治理占位符未收口（09-15 review P2-1） | — | R2, R5 |

图例：✅ 完成 ・ ⬜ 未开始 ・ 🔶 阻塞

> **T4 的编号内容待确认。** 该条原文在上下文压缩中丢失，现按 T1/T2/T3/T9 的内容反推为
> 「不可变制品」（对应 R4），**这是推断不是事实**。确认后请删掉本段。

---

## T0b · 状态与非 root 部署 {#t0b}

**范围**：`/var/lib/dsh` 状态目录、非 root 运行、systemd hardening、`releases/<digest>` + `current`
符号链接原子切换、生产机无 Node/包管理器/编译器也能启动。

**阻塞原因**：本机（macOS）没有可用的 Linux 环境（无 docker/podman/lima），且 `make deploy`
从未端到端跑通过（见 [backlog.md](backlog.md) B3）。

**已验证的边界**（在拿到主机前就应知道）：即使有一台 Linux 主机，**能给 sudo 与不能给 sudo
能验到的东西完全不同**：

| 能验（普通用户 + 任意目录） | 不能验（需 root + system-level systemd） |
| --- | --- |
| `releases/<digest>` + `current` 原子切换 | `/var/lib/dsh` 归属与权限 |
| 失败回滚到 previous | **hardening 实际效果**（`ProtectSystem`、`PrivateTmp`、`NoNewPrivileges`、`DynamicUser`、`StateDirectory=`）—— `systemd --user` 对 hardening 的支持是残缺的 |
| 真正的非 root 用户从 release 目录启动 | `systemd-analyze security` 打分 |
| 状态/代码分离（release 目录 `chmod -w` 后应用能否照跑） | `loginctl enable-linger`、开机自启 |
| Linux x86-64 原生依赖构建 | |

**方法学要求**：脚本必须把状态根**参数化**（`DSH_STATE_ROOT`，生产默认 `/var/lib/dsh`）。
否则无 sudo 的验证跑的是**另一份代码路径**，结论无效。

---

## T3 · Jenkins 信任边界 {#t3}

**必须区分的三类执行者**（review §8 强调的硬约束）：

1. Jenkins controller
2. 不可信 presubmit executor（跑任意 patchset 的代码）
3. 可信 release executor（持有签名密钥与 Nexus 凭据）

**当前资源缺口**：只有两台物理服务器，**不足以隔离这三者**。因此 T3 现在能做的是：

- ✅ 写**信任边界规格**：presubmit 不得持有可复用凭据；流水线骨架与 Shared Library 必须来自
  受保护基础设施仓或固定受信 ref（**不允许 patchset 自定义受信流水线**）；controller 0 executors
- ✅ 写**资源缺口说明**：明确「当前 2 台不满足，需第 3 个执行域」
- ❌ **不能**写「设计已完成、可以落地」——那是纸上谈兵

---

## T6 · 状态迁移兼容矩阵 {#t6}

**状态：调研已完成（2026-09-15）。结论：不能作为纯文档产出。** 证据见下。

### 调研结果

对 `$DSH_HOME`（本次实测：macOS 开发机 `.dsh/`）全部 19 个顶层条目逐项核对「谁写的」「有没有版本字段」：

| 状态路径 | 写入方 | 版本字段 |
| --- | --- | --- |
| `dsh-session-archive/{state,archive-ledger}.json` | **dsh-web** `dsh-session-archive` | `version` |
| `dsh-ssh.json` | **dsh-web** `dsh-ssh` | `version` |
| `dsh-usage/{usage-ledger,provider-snapshots}.json` | **dsh-web** `dsh-usage` | `version` |
| `.credentials.yaml` | **dsh-web** `dsh-doctor` | `version` |
| `task-board/ledger-v2.json` | **dsh-web** `dsh-task-board` | `schemaVersion` + `revision` |
| `task-board/scheduler-v2.json` | **dsh-web** `dsh-task-board` | **无**（版本只在文件名里） |
| `llm-deepseek/files-v3.json` | **harness** `llm-deepseek` | `formatVersion`（版本也在文件名里） |
| `pet.json` | **dsh-web** `dsh-pet` | **无** |
| `remote-web-ui-devices.json`、`remote-web-ui-registry/web.json` | **dsh-web** `dsh-remote-web-ui` | **无** |
| `settings.yaml` | **dsh-web** `dsh-doctor` | **无** |
| `skin-center/`、`skin-center-active.json` | **dsh-web** `dsh-session-id` 等 | **无** |
| `storages/{workspace,dsh_automation}.json` | 动态构造，字面未命中 | **无** |
| `.agent-presets/` | **dsh-web** `dsh-liangshen` | — |
| `sessions/` | harness | — |

### 三条结论

**① 有 **4 种**互不兼容的版本约定**：`version`（4 个包一致）、`formatVersion`（harness）、
`schemaVersion`+`revision`（dsh-task-board）、**版本只写在文件名里**（`files-v3`、`ledger-v2`、
`scheduler-v2`）。**8 个状态文件完全没有版本字段**。

**② 归属几乎全在 dsh-web**——一个第三方 submodule（pin `main`）。按本仓硬约束**我们不能改**。
harness 那一个同样归上游。**即：本仓对绝大多数状态 schema 没有修改权。**

**③ 这与 T1 期间的 P1-1 同构**：看着是文档任务，一查发现是上游依赖。
不做调研就写出来的兼容矩阵会是编的——所以这份台账到此为止，**没有**去写那份矩阵。

### 可选路径（需决策，我不代选）

| 路径 | 代价 |
| --- | --- |
| **A. 报上游**，请 dsh-web / harness 统一 schema 版本约定 | 慢、不可控；但这是唯一能真正解决问题的方向 |
| **B. 本仓做适配层/迁移脚本** | 对 8 个**无版本字段**的文件只能靠内容启发式或文件名判断，**很脆弱**；且每次上游改动都可能打破 |
| **C. 降级目标：不承诺 schema 迁移，承诺「状态不跨大版本兼容」** | 升级时要求清空/重建 `$DSH_HOME`。把问题从「迁移」降级为「重建」——**早期是合理且诚实的**，代价是用户丢本地会话/配置 |

**倾向 C 作为当前承诺**（诚实、零成本、可立即写清边界），**同时把 A 作为上游诉求**记入待报清单。
B 只在某个具体状态被证明有真实迁移需求时才做。

---

## T7 · headless 发布回归 {#t7}

**为什么先量再定**：[backlog.md](backlog.md) B7 记录 CI **一个 submodule 测试都没跑**，
而 harness 有 962 个测试文件、10 个插件合计 700+。当前**完全不知道**：

- 全量跑要多久？
- 哪些是 flaky 的？
- 裸 CI runner 跑得动吗？

**不量就写「回归策略」，里面的数字都是编的。** 先在本机跑一遍候选集，量出真实的**时间**与
**flaky 率**，再定回归集。

---

## T8 · Gerrit / GitHub 出口模型 {#t8}

**必须先定的技术选择**：同一个提交同时走 Gerrit（内部评审）与 GitHub PR 时，**谁是权威？**

双向镜像（Gerrit 复制到 GitHub + GitHub 反向拉取）会**双写冲突**。必须先定**单向权威 + 单向镜像**，
否则这个模型不自洽。

---

## 2026-09-15 增量 review 的处置

详见 [reviews/2026-09-15-incremental-design-review.md](reviews/2026-09-15-incremental-design-review.md)。
**逐条核实后判定：无一条不合理。** 三个 P0 与六条 P1 全部成立（含若干条是本轮**自己引入**的回归）。

| 条目 | 核实 | 处置 |
| --- | --- | --- |
| **P0-1** setup 用 `ci:install` 选组件，跳过 6 个 required 插件 | ✅ 成立（本轮在 T2 引入；本地靠 T2 前的 `node_modules` 掩盖，**全新环境必炸**） | ✅ 已修：改为具名选择器 `prepare`（`runtimeScope` 驱动），`setup.sh` 与 `remote-install.sh` **共用同一个** |
| **P0-2** rsync 同步 ignored 产物（macOS Mach-O 到 Linux） | ✅ 成立（实测同步 31,626 条，含 `darwin-arm64/bin/system.node` 与 `.dsh-build/`） | ✅ 已修：排除清单**由 git 动态派生**（656 条），实测降到 19,945 条且危险项全排除 |
| **P0-3** t0b 探针 `rm -rf "$1"` 无校验 | ✅ 成立（本轮引入） | ✅ 已修：**取消自定义路径**，改 mktemp + 删前校验；7 个危险输入实测全拒 |
| **P1-1** release 绕过许可证内容门禁 | ✅ 成立（本轮引入） | ✅ 已修：verify / release.yaml / release.sh 三门同用 `check-all.sh --offline` |
| **P1-2** 政策 fail-closed 而脚本 fail-open；MPL-2.0 与「不接纳任何 copyleft」矛盾 | ✅ 成立 | ⬜ 未修（见下） |
| **P1-3** catalog 无 canonical URL，`gerrit-fork` 标签配 GitHub URL | ✅ 成立 | ⬜ 未修（见下） |
| **P1-4** manifest 消费者 fail-open；`config/README.md` 不存在；`--list runtime` 文档错 | ✅ 成立 | ✅ 已修（`--list` 缺值改为报错、具名选择器）；`config/README.md` 与跨字段 schema **已在 2026-09-15 组件目录轮收口**，见下节 |
| **P1-5** README/ADR 旧事实源、台账「提前完成」 | ✅ 成立 | 🟡 台账本次已纠偏；README/ADR 待改 |
| **P1-6** 提交信息泄露内网主机 / 被 shell 替换破坏 | ✅ 成立（`ad22dd3` 含真实账号+IP；`1b52942` 正文被插入 11 行 `git submodule status`） | ⬜ 历史已推送，不改写；待补扫描（见下） |

### 本轮新发现（review 未提，核实代码时发现）

- **`dsh-agent-teams` 的 `buildMode: prebuilt-verified` 与事实不符**：该字段意为「入口已提交」，
  但它的 `lib/` 是 **gitignored**（0 个跟踪文件，与确实提交了 `lib/` 的 `dsh-automation` 不同）。
  这正是 P1-4 说的「字段语义没有定义处」的实例——目录说的和仓库实际状态不一致，而没有任何校验发现它。

### 未修项的理由（本轮范围外，需先定模型）

**P1-2 / P1-3 / P1-6 与 P1-4 的 schema 部分**都要先回答「字段语义是什么」——
即 review 说的 I1「组件生命周期模型」。逐条打补丁会制造新的不一致（P0-1 就是这么来的：
给某个脚本改一个字符串选择器，而不是先定义「哪个字段决定什么」）。故合并为一批设计任务，
不在这轮顺手改。

> ✅ **P1-4 的 schema 部分已于 2026-09-15 收口**（ADR-0005 + `config/README.md` + 两阶段校验），
> 见上方「2026-09-15 组件目录生命周期轮」。**P1-2 / P1-3 / P1-6 仍未修**——
> 它们要的是制品链与共享脚本库的接口，与本轮的字段语义不是同一件事。

**P1-6 的历史泄露不可撤销**：`ad22dd3` 已在远端。私网 IP 不是凭据，且仓库当前为私有；
处理方式是**补扫描防再犯**（提交正文检测 host/IP/凭据模式）而不是改写已共享历史。

## 2026-09-15 组件目录生命周期轮（ADR-0005，收口 P1-4 的 schema 部分）

**范围**：把 [ADR-0005](cicd/adr/0005-component-catalog-lifecycle.md) 从「决策」推到「实现」。
12 个任务的计划见 [plans/2026-09-15-component-catalog-lifecycle.md](superpowers/plans/2026-09-15-component-catalog-lifecycle.md)，
实施过程（含每次评审）见 `.superpowers/sdd/2026-09-15-component-catalog-lifecycle/`。
**提交范围**：`bd7d265..`（49 个提交，ADR 起算）。

> ⚠️ **本节 T 编号与上方总表的 T 编号不是同一套。** 总表的 T0a-T9 来自 2026-09-14 review
> 的第二轮整改清单；本节的 T1-T11 是**组件目录这一轮自己的任务切分**。
> 两者只是恰好都用了 "T"——**不要交叉引用**。

### 逐项结果（以实现后的实测为准，不照抄计划）

| 模型中的东西 | 结果 | 证据 |
| --- | --- | --- |
| 字段三分类 | ✅ | `check-components.mjs` 的 `FIELD_CLASS` + `checkFieldClassValues()`；`probe-catalog.sh` B3/B4/B5 |
| `prepareMode` 四值 | ✅ | `ENUM.prepareMode`；⚠️ 11 个组件实际只用到三个，`install-only` 允许但暂无使用者 |
| `--plan prepare` | ✅ | `node scripts/check-components.mjs --plan prepare` → rc=0，10 行 |
| 两阶段校验 + `--require-materialized` | ✅ | 两条命令 rc=0（`10 个已验；0 个跳过`） |
| 删除 `packageManager` | ✅ | ⚠️ **判据极性相反**：`"packageManager" in 组件` → `false` |
| `version: 1 → 2` | ✅ | `"version": 2` |
| 删两处 `main` 被跟踪启发式 | ✅ | `setup.sh` / `remote-install.sh` 的剩余 `ls-files` 只服务 `pnpm-workspace.yaml` 脚手架判定 |
| 三处 fail-open | ✅ | `check-components.mjs:670`；`link-plugins.sh:38`；`remote-install.sh:60` |
| `gen-notices` 对 declared 字段免责 | ✅ | 生成物表头「（声明，未验证）」+ `assertColumnClasses()` 双向钉住 |
| **统一的 prepare 执行器** | 🟡 **部分** | 统一了**决策**（`prepare-executor.sh`）；**动作原语仍是两份** → [backlog.md](backlog.md) **B11** |
| setup 计划前调 materialized 严格校验 | ✅ | `scripts/setup.sh:218`（在 `:223` 取计划之前） |
| **`pinRef` 形如合法 ref** | ❌ **未实现** | 只查了非空与不带 `refs/` 前缀（`check-components.mjs:443-444`） |
| **完整的产物校验（最小加载/冒烟）** | ❌ **未实现** | 无可执行判据；`tracked-prebuilt` 只声称「入口被 git 跟踪」 |

**两处仍未实现，均已在 [config/README.md](../config/README.md) 的实现状态表里如实标出**——
不因为"大部分做了"而藏起来。

### 本轮修正的两处文档错误

**① 阶段归属错误（表自相矛盾）。** `runtimeScope × prepareMode` 正交约束被列在 **materialized**
阶段，但它**只看目录**即可判定——按该表自己的组织原则（"需读子仓的才归 materialized"）
属于 **catalog** 阶段。T4 的实现一开始就在 catalog 阶段，是**文档落后于实现**。
`config/README.md` 与 ADR-0005 的正文都改了（ADR 侧带「实施修正」标记，约束内容一字未改）。

**② 部署树的物理事实。** `scripts/deploy-remote.sh:184` 的 rsync 带 `--exclude '.git'`
⇒ **服务器树没有任何 git 元数据** ⇒ materialized 阶段在那里**永远无法运行**。
这**不是配置问题，是那棵树的属性**。已写进 `config/README.md` 与 ADR-0005 的「实施偏离记录 D1」。

> **为什么这条必须落盘**：不写的话，下一个人看到「服务器没跑 materialized 阶段」，
> 会以为那是**漏了一步**，然后"补上"——**那会让每一次部署都失败**。

### ⚠️ 本轮暴露的一条方法学教训：实测数字会过期，判据不会

计划里（以及 `deploy/remote-install.sh` 的注释里）写着服务器树模拟的实测结果是
「`validate()` rc=1、13 条 ✗」。**2026-09-15 复测不成立**：忠实 rsync 副本上
`validate()`（非严格）实测 **rc=0**。

原因是那条测量发生在 `80f301a`（「查不了」不再说成「坏了」）**之前**——当时
`trackedState()` 是布尔的，git 元数据不可用被误报成「确认未被跟踪」。三分法落地后，
同一棵树改为报「**因 git 元数据不可用而无法判定**」。

**结论（服务器侧不能用 materialized）不变，变的是依据的措辞**：

| 命令 | 忠实副本上的实测（2026-09-15 复测） |
| --- | --- |
| `check-components.mjs` | rc=0；`0 个已验；0 个跳过；10 个因 git 元数据不可用而无法判定` |
| `check-components.mjs --require-materialized` | **rc=1**（"无法判定"在严格模式下即失败） |
| `check-components.mjs --plan prepare` | rc=0，与本地逐行一致 |

教训：**写进长期文档的应该是判据（那棵树没有 git 元数据 ⇒ 该阶段不可判定），
而不是某次运行的数字。** 数字要连同命令一起写，好让下一个人**重跑**而不是**照抄**。

---

## 2026-09-14 review 的逐条处置

对 `docs/reviews/2026-09-14-repository-design-review.md` §4 的全部 P0/P1/P2 逐条核实后的处置。
**没有一条被判定为不合理**，但优先级差别很大。

| 条目 | 核实 | 处置 |
| --- | --- | --- |
| **P0-1** 部署内容 ≠ HEAD | 成立（`git submodule status` 非递归、无根仓 clean 检查） | ✅ 已修：快照保真三层检查 |
| **P0-2** `log/` 会被同步 | 成立（exclude 列表确实没有它） | ✅ 已修：补 `log/`、`.env*`、`.claude/` 等 |
| **P0-3** 告警无 exporter | 成立；且 harness **自带** logger-console 只是没挂 | ✅ 已修：profile patch + **A/B 实测**证明生效 |
| **P0-4** telemetry 默认值 | 成立，但**处方有误** | ✅ 已修：真实开关是 `DSH_TELEMETRY_MODE` |
| **P1-1** 部署无原子性 | 成立 | 部分（T0a）；根治归 T0b/T4 |
| **P1-2** branch pin 语义 | 成立 | ✅ 已修（`8a6d9b9`） |
| **P1-3** pin 非单一事实源 | 成立（README 与 plugin-dev 仍手工） | ✅ 已修：改指 `config/components.json` |
| **P1-4** 双权威 / 文档冲突 | 成立（`deploy.md` 与脚本直接矛盾） | ✅ 已修：`deploy.md` 对齐脚本 |
| **P1-5** CI 不能证明已测 | 成立 | 部分（T9）；测试门禁归 **T7** |
| **P1-6** 安装逻辑重复 | 成立 | ⬜ **未修**——需设计（见下） |
| **P1-7** 日志协议 | 成立 | ⬜ **未修**——P0-3 是它的前置，见下 |
| **P2-1** Makefile | 成立，且版本号那条**比 review 说的更严重** | ✅ 已修：改走环境变量，终结验证过注入不生效 |
| **P2-2** AGENTS 边界 | 成立 | ✅ 已修：补授权边界 + **验证报告格式** |
| **P2-3** raw log 生命周期 | 成立 | ⬜ **未修**——与 P1-7 同一套设计 |

### 未修三项的理由

**P1-6（`setup.sh` / `remote-install.sh` / `link-plugins.sh` 三处重复安装逻辑）**
与 **P2-3（Make 日志无生命周期）** 都不是「加个检查」能解决的，而是要先定接口：
前者要决定「共享脚本库的边界在哪、平台相关副作用怎么留」，后者要定「run ID、
保留策略、evidence 与原始日志如何分离」。**归入 T5/T7 一起设计**，避免现在拍一个
和后面冲突的接口。

**P1-7（日志协议）** 依赖 P0-3 已建立的 exporter 通道——现在只做到「可见」，
还没到「结构化」。要写 JSON schema / correlation / redaction / 采集契约，
是**独立设计任务**，不宜混在修复里顺手做。

> 另：**P0-4 的 review 处方是错的**，值得记一笔——它要求设 `DSH_TELEMETRY_DISABLED=1`，
> 而该变量在 harness 里**不存在**（grep 零命中）。设了不会报错，只会静静地不生效。
> 教训：**照 review 的字面去改之前，先验证它引用的标识符真实存在。**

## 推荐顺序

```
落盘本台账                    ✅ 已完成（b761e09）
   ↓
T6 调研                       ✅ 已完成 —— 结论是不能作为纯文档产出，待选路径 A/B/C
   ↓
T8 + T5 规格（并行）           纯设计，本机可完成
T7 实测（并行）                本机可完成，产出真实数字
   ↓
T3 规格 + 资源缺口说明          只写不吹
   ↓
（等基础设施）T3 验证 / T4+T0b 实现 / T5 制品链 / T7 双平台 lane
```
