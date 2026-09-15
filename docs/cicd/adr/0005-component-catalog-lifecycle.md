# ADR-0005：组件目录的字段语义与两阶段校验

| 属性 | 值 |
| --- | --- |
| 状态 | Accepted |
| 日期 | 2026-09-15 |
| 决策者 | DSH Maintainer |
| 关联文档 | [config/README.md](../../../config/README.md)（字段字典）、[scripts/check-components.mjs](../../../scripts/check-components.mjs)、[增量设计 Review](../../reviews/2026-09-15-incremental-design-review.md) |

## 上下文

`config/components.json` 被引入为组件的单一事实源（见 [ADR-0004](0004-intranet-control-plane-and-data-residency.md) 之后的超级仓治理改动）。但**有了单一事实源，不等于有了单一语义**：

- **字段语义没有定义处。** 15 个组件字段里，真正影响行为的只有少数几个。`ciScope` 看起来像「要不要安装这个组件」，实际语义是「CI job 参与范围」——`scripts/setup.sh` **曾据此**判断安装，**曾导致** 6 个 `runtimeScope: required` 的源码构建插件在全新环境被整批跳过（本地因旧的 `node_modules` 存在而未暴露，CI 与 release 都调 `make setup`，因此必然崩）；`deploy/remote-install.sh` 则走相反极端、完全不过滤。**同一份目录，两个消费者给出相反解释。**

  > 这两处**症状**已于 `a4bfd76` 修复（两者改用同一个具名选择器 `prepare`）。
  > 本 ADR 处理的是**根因**：为什么"选错字段"这件事没有被任何人发现——
  > 因为字段语义从来没有定义处。
- **声明与事实分叉且无人校验。** 实测 10 个组件，`dsh-agent-teams` 声明 `prebuilt-verified` 但其 `lib/` 无任何 Git 跟踪文件；`dsh-at-file` 声明的构建模式与其入口已提交的事实不符。两者都靠 `setup.sh` 里一条**内隐启发式**（「根 `main` 被 git 跟踪即跳过构建」）在默默纠正——**声明的字段从未被读过，因此错了也没人知道**。
- **「无消费者」的字段看起来像生效了的保证。** `releaseScope: ["bundle"]` 写着「进制品」，而制品链尚未实现，没有任何东西读它做决定。**一个不存在的保证比没有声明更危险**——读者会据此认为某事已被覆盖。
- **校验是 fail-open 的。** `--list` 分支绕过 `validate()`；`link-plugins.sh` 与 `remote-install.sh` 用 `2>/dev/null || true` 吞掉目录查询失败并退化为空集；生成物消费者直接解析原始 JSON。**最需要目录保护的路径，恰恰在目录解析失败时继续执行。**

## 决策

### 1. 字段按「有没有**行为或门禁**消费者」分三类

| 类别 | 定义 | 现状 |
| --- | --- | --- |
| **operational** | 影响**执行、门禁或发布结果** | `path`、`pinPolicy`、`pinRef`、`runtimeScope`、`prepareMode`、`license` |
| **declared** | 可被**展示/生成器**读取，但**无行为执行、无真实性校验**，**不构成工程保证** | `name`、`sourceAuthority`、`ciScope`、`releaseScope`、`platforms`、`testProfile`、`stateSchema`、`notes` |
| **derived** | 权威源在别处 → **从目录删除** | `packageManager`（事实源是各子仓自己的 `package.json`） |

判据是**行为/门禁消费者**，不是「有没有任何代码读它」——`gen-notices.mjs` 会读 `releaseScope` 与 `sourceAuthority` 去**生成声明**，那是展示，不构成保证。

**类别作为 schema 级元数据维护**，不给每个组件重复加标记：同一事实在 10 处重复就是 10 个漂移点，与本 ADR 要治的病同源。

### 2. 两个正交字段：`runtimeScope` 决定「要不要」，`prepareMode` 决定「怎么做」

`buildMode` 更名为 **`prepareMode`**（它描述的是**本仓采取的动作**，不是子仓的性质），并由三值扩为四值：

| prepareMode | 动作 |
| --- | --- |
| `source-build` | 安装依赖 → 执行 build → 验证输出 |
| `tracked-prebuilt` | 安装运行依赖 → **验证所有提交产物** → 不执行 build |
| `install-only` | 安装依赖，无 build |
| `none` | 不准备 |

补 `install-only` 是为了消除「`no-build` 被迫等同于 excluded」的歧义：一个**无需编译但需要安装**的运行时组件此前无处安放。

**查询器输出动作计划**（`--plan prepare` → `path + prepareMode`）。

⚠️ **但这只统一了「决策数据」，没有统一「动作执行」。** 若 setup 与 remote-install 各自
实现一套 `case "$prepareMode"`，漂移只是从「选哪个字段」变成「怎么执行动作」——病没治好，
只是换了个地方发作。实施必须二选一：

- **（推荐）** 两者调用**同一个 prepare executor**；环境差异（本地允许非冻结安装、
  服务器必须冻结安装）作为 executor 的 **policy 参数**传入，而不是各写一套；
- 或保留两套执行器，但**必须有契约测试**证明两者对同一份计划产出等价动作。

### 3. 校验分两阶段；门禁路径必须要求 materialized

| 阶段 | 何时 | 查什么 |
| --- | --- | --- |
| `catalog` | `make setup` **之前**（保持既有约束：CI 第一步可运行） | JSON schema、`.gitmodules` 集合、内部不变量 |
| `materialized` | 子仓就绪后 | 入口/产物跟踪状态、build script 存在性等**需要读子仓**的不变量 |

**CI 与 release 使用 `--require-materialized`：任何 skip 都算失败。**

「子仓未初始化就跳过并计数」可以保留，但**不能作为最终门禁**——否则 fresh clone 上可以一项都不查就通过，那是 fail-open，正是本 ADR 要消除的形态。

### 4. 不变量清单

**catalog 阶段（只看目录）：**

- `pinPolicy: tag` ⇒ `pinRef` 非空、不带 `refs/` 前缀、形如合法 ref。
  （⚠️ **最后半句"形如合法 ref"尚未实现**——当前只查了前两条。见「实施偏离记录 **D4**」
  与 [config/README.md](../../../config/README.md) 文末的实现状态表。
  **本行是决策、保持原样**：这里的落差记在偏离记录里，不改决策。）
- `runtimeScope: excluded` ⇒ `releaseScope` **不含 `bundle`**。
  （**不**要求 `releaseScope: []`：excluded 组件未来仍可能有独立制品、SBOM 或 provenance；过强的约束会挡住合理设计。）
- `runtimeScope: required` ⇒ `prepareMode != none`。
- `runtimeScope: excluded` ⇒ `prepareMode = none`。

  > ⚠️ **实施修正（2026-09-15）**：上面两条正交约束在本 ADR 初稿里列在 **materialized 阶段**，
  > **本 ADR 与 [config/README.md](../../../config/README.md) 都错了**。它们**只看目录**即可判定
  > ——`runtimeScope` 与 `prepareMode` 是同一个组件对象上的两个字段，不需要读子仓。
  > 按本节自己的组织原则（catalog = 只看目录 / materialized = 需读子仓），它们属于 **catalog 阶段**。
  > T4 的实现（`validateCatalog()`）一开始就落在 catalog 阶段，是**文档落后于实现**。
  > 此处**只是把两条搬到正确的段**，约束本身（内容、极性、判据）**一字未改**。

**materialized 阶段（需读子仓）：**

- `prepareMode: tracked-prebuilt` ⇒ **`main`、`types`、以及所有无通配符的 `exports` 目标，均被 git 跟踪**。
  （只查 `main` 不足：`exports` 指向未跟踪文件时，fresh clone 上组件照样是坏的。）
- `prepareMode: source-build` ⇒ `package.json.scripts.build` 存在。

**一条不写成不变量、只报警告：** `source-build` 且**任何会被加载的入口**已被 git 跟踪 ⇒ 构建**可能**弄脏 submodule（重建结果与提交版本逐字节一致时 Git 不会显示 dirty，如 `dsh-market` 的 `client/client.js`），进而触发部署的快照保真检查。这是**运维后果**，不是 schema 矛盾——本仓可以出于供应链政策选择源码重建，即使子仓恰好也提交了产物。**用警告让它可见，不用规则禁止它。**

⚠️ **只查 `main` 会漏报本条自己的例子**：`dsh-market` 的 `main` 是 `lib/index.js`，它恰恰**未**被 git 跟踪；被跟踪的是 `exports["./client"] → ./client/client.js`。所以**入口的枚举方式**与上面 `tracked-prebuilt` 相同（`main` / `types` / 无通配符的 `exports` 目标）。

⚠️⚠️ **但候选集不能照搬 `tracked-prebuilt` 的全部入口——两条规则问的不是同一件事**：

| 规则 | 它问的问题 | 候选集合 |
| --- | --- | --- |
| `tracked-prebuilt` 不变量 | fresh clone 上**组件还能用吗** | **所有**声明入口（`package.json` 也算：缺了它组件直接坏） |
| 本条警告 | **构建会覆盖哪个已跟踪文件** | **只有构建产物**（代码模块），**排除人手维护的 manifest / 配置** |

`package.json` 与 `cordis.patch.yml` 这类文件被跟踪，但**构建从不写它们**。
把它们算进来，警告会对**根本不会被弄脏**的组件喊狼来了——
而**一条喊狼来了的警告会被忽略**，等于没有。
（**实测快照**，2026-09-15、当时 11 个组件：照搬全入口集会喊 **6** 个、其中 3 个是假的；
只算构建产物则恰好触发 `dsh-market`、`modlens`、`modsearch` 三个。⚠️ **这组数字是当时的测量**，
组件集合一变就漂——别当当前值用。）

## 后果

**正面**

- 字段语义有唯一定义处（[config/README.md](../../../config/README.md)），新增消费者有章可循，不再靠读脚本反推。
- `prepareMode` 成为**显式的政策选择**而非内隐启发式；两处启发式随之删除，声明的与实际执行的从此是同一个东西。
- 两阶段 + `--require-materialized` 把「fresh clone 上什么都没查就通过」这条 fail-open 路径堵死。
- 「声明待用」被显式标注，读者不会把 `releaseScope: ["bundle"]` 误读成已生效的保证。

**负面 / 代价**

- **`declared` 字段的价值下降了**：它们不再能被当作"已经声明过所以有人管"。这正是意图，但它们需要有人定期回看是否该转为 operational 或删除。
- **`--require-materialized` 会让 CI 更慢**（要读全部子仓），且**在子仓缺失时直接失败**——这是刻意的，但要求 CI 的 checkout 步骤必须带 submodule。
- **schema 升到 2 是一次破坏性变更**：所有读取方必须同步；旧版本被显式拒绝而不是尽力兼容。
- **`prepareMode` 的行为变更会真实改变构建**（`dsh-agent-teams` 开始构建、`dsh-at-file` 停止构建），必须在两个平台各验证一次。

## 被否决的替代方案

**① 给所有组件补上 `install` 字符串（止血）。**
否决：那会把「`ciScope` 到底是什么意思」这个真问题掩盖过去，并让一个本就是「CI job 参与范围」的字段承担「要不要安装」的语义。字段语义仍无定义处，下一个消费者会再犯一次。

**② 保留 `buildMode` 命名。**
否决：`buildMode` 读起来像「这个仓是怎么构建的」（子仓的性质），而实际要表达的是「**本仓对它采取什么动作**」。`install-only` / `none` 两个取值根本不是"构建模式"。命名与语义不符正是本次要治的病。

**③ 不变量「`source-build` ⇒ 该仓的 `main` 未被 git 跟踪」（曾作为 V2 提出，**已否决**）。**
否决理由：`prepareMode` 是**本仓选择的动作**，不是子仓的性质。一个仓完全可能提交 fallback 产物，而本仓仍出于供应链政策选择源码重建。若把这条写成不变量，等于把 `prepareMode` 重新退化成「`main` 是否被跟踪」这条启发式的别名——**那就等于没有建模**。相关的运维风险（构建弄脏 submodule）改为**警告**呈现。

**④ 给每个组件加 `status: declared` 标记。**
否决：同一个事实在 10 个组件里重复 10 遍，就是 10 个漂移点。类别属于**字段**的元数据，不是组件的属性。

**⑤ 只在文档里写清语义，不改 schema、不加校验。**
否决：这正是上一次的做法，其结果就是本 ADR 上下文里列的那几条。**文字约束不能代替机器门禁。**

**⑥ 把本设计落在 `docs/superpowers/specs/`。**
否决：该路径已被 [AGENTS.md](../../../AGENTS.md) 定义为**历史、非权威**（"不得作为实施依据"）。新规范落进去会自相矛盾。字段字典进 `config/README.md`，设计取舍进本 ADR。

## 实施约束

- **schema `version` 从 1 升到 2，未知版本拒绝**（不尽力兼容）。
- 同步更新 `scripts/probe-license-gate.sh` 的合成 fixture（它构造 catalog，字段变了会失配）。
- 重新生成 `THIRD-PARTY-NOTICES.md`。
- **删除三处 fail-open**：`check-components.mjs` 的 `--list`/`--plan` 分支必须先跑 `validate()`；`link-plugins.sh` 与 `remote-install.sh` 的 `2>/dev/null || true` 必须去掉；`gen-notices.mjs` 复用同一个 validated loader，不再直接解析原始 JSON。
- **两处旧启发式必须删除**（`setup.sh` 与 `remote-install.sh` 里的「`main` 被跟踪即跳过构建」），由 `prepareMode` 取代。
- **必须有统一的 prepare 执行器**（或契约测试）——见「决策 2」的说明。只改查询器不改执行，漂移不解决。
- **`gen-notices.mjs` 必须给 declared 字段标注免责**：当前生成物用「来源」「进制品」这类**事实性表头**，
  读者无从知道这些列只是声明。分类若只活在字段字典里，生成物的读者仍会误解——**而生成物正是对外的那一份**。
- **`setup.sh` 必须在子仓就绪后、执行动作计划之前调用 materialized 严格校验**：否则
  「本机准备」这条路径上，materialized 类不变量永远不会被执行。
- 存量修正：`dsh-agent-teams` → `source-build`；`dsh-at-file` → `tracked-prebuilt`；删除 `packageManager`。
- **命名诚实性**：`tracked-prebuilt` 只声称「产物已被 git 跟踪」，**不声称「已验证」**。真正的验证（入口完整性、最小加载/冒烟）是后续工作，不得用当前命名暗示已经做到。
- 新的动作计划必须在 **macOS arm64 与 Linux x86-64 两个平台**分别验证。
- 顺带修正 [README.md](../../../README.md) 中把 `docs/superpowers/specs/` 称为"设计"的表述（与 AGENTS.md 冲突）。

---

## 实施偏离记录（2026-09-15）

> **本节只追加，不改写上面任何结论。** 实施中与「实施约束」字面不同的地方记在这里，
> 附**当时的依据**与**现在是否仍然成立**——因为依据会随代码演进而过期，而结论不会。

### D1. `--require-materialized` 在服务器侧**不可用**——它的落点改到**本地**

**字面约束**：「CI 与 release 使用 `--require-materialized`：任何 skip 都算失败。」

**偏离**：`deploy/remote-install.sh`（跑在**服务器**上）**不**跑 materialized 阶段，
只用 catalog 阶段口径（`--plan prepare` 查询路径自带的 `validateCatalog`）；
materialized 严格校验改由 `scripts/deploy-remote.sh:444` 在**本地**执行。

**依据（树的属性，不是配置问题）**：`scripts/deploy-remote.sh:184` 的 rsync 带
`--exclude '.git'`，而 `--exclude` 对**每一层路径**生效 ⇒ **部署树里没有任何 git 元数据**。
materialized 阶段靠 `git ls-files` 判「入口是否被跟踪」，在那棵树上**恒为不可判定**。

> **为什么必须记住这件事**：不知道的人看到「服务器没跑 materialized」，
> 会以为那是**漏了一步**，然后去"补上"——**那会让每一次部署都失败。**

**本节写明的验收事实**（2026-09-15 实测，忠实 rsync 副本：同一份 `--exclude` 清单，
副本内 `.git` 确认不存在）：

| 命令 | 副本上的结果 |
| --- | --- |
| `check-components.mjs`（catalog） | **rc=0**；`0 个已验；0 个跳过；10 个因 git 元数据不可用而无法判定` |
| `check-components.mjs --require-materialized` | **rc=1**（严格模式下「无法判定」即失败） |
| `check-components.mjs --plan prepare` | **rc=0**，输出与本地源树逐行一致 |

⚠️ **不要把 D1 理解成「约束被放松了」。** 它只是**换了执行位置**：从「服务器上、写坏之后」
换到「本地、**一个字节都还没写到远端**之前」。本地那棵树有 git 元数据，查得动；
而且失败时 `rsync --delete` 根本没开始跑。**这是加强，不是豁免。**

### D2. 警告候选集收窄——已就地记录，此处只作索引

「构建弄脏 submodule」这条警告的**候选集**从「全入口集」收窄为「**只算构建产物**」，
理由与实测数字见上面「决策 4」的两条 ⚠️。**那是结论的一部分，改在正文里；本节不重复。**

### D3. ~~⚠️ 一处**过期依据**仍留在代码注释里（未修，仅记录）~~ → **已由 `3e56b7f` 修正**

> **本条已收口，保留在此是因为"它曾经挂着"这件事本身有信息量**：
> 读到这里的人应该知道它**为什么**曾被写成"未修"，而不是以为这只是一条普通的历史注记。

**当时的记录**：`deploy/remote-install.sh` 的 D1 理由注释里写着

```
#    （实测：服务器树模拟下 validate() rc=1、`--plan` rc=0，见 task-9-report.md。）
```

其中 `validate() rc=1` **不成立**——忠实副本上 `validate()`（非严格）实测 **rc=0**。
原因是那条测量发生在 `80f301a`（「查不了」不再说成「坏了」）**之前**：当时
`trackedState()` 是布尔的，git 元数据不可用被当成「确认未被跟踪」，于是对
`tracked-prebuilt` 组件报出 13 条 `✗ …**未被 git 跟踪**——fresh clone 上该组件是坏的`。
`80f301a` 引入 `GIT_UNKNOWN` 三分之后，同样的树改为报「因 git 元数据不可用而无法判定」。

**结论不变，依据的措辞过期了**：D1 成立的理由是「**无法判定**」，不是「一定失败」。
`--require-materialized` 在这一侧 rc=1 依然成立（严格模式下「无法判定」即失败），
`--plan` rc=0 也依然成立——**只有 `validate()` 那半句需要更新**。
本 ADR **不改 `scripts/`**（超出本 ADR 的范围），故当时只在此登记、并留了一句
「下次有人改 `deploy/remote-install.sh` 时请顺手把那半句换掉」。

**现状（2026-09-15 复核）**：那个"下次"已经发生了。后继提交 **`3e56b7f`** 把该注释
整段改写为实测措辞（「**无法判定**（不是"一律失败"）」），并补了一句
「**别把它当成"漏了一步"去补**」。复核命令与预期：

```bash
grep -c "task-9-report\|validate() rc=1" deploy/remote-install.sh   # → 0
```

**顺带关掉的一处**：上面那段引文里的 `见 task-9-report.md` 指向 `.superpowers/`
——**那是被 gitignore 的草稿目录，别人 clone 根本看不到**。
`3e56b7f` 的改动理由之一正是"去掉指向草稿目录的引用"，改为指向
[config/README.md](../../../config/README.md) 的「⚠️ 部署树**跑不了** materialized」一节。
**于是本 ADR 成了最后一个**还会把读者引向那个不可见路径的地方，故此处同步改指仓内文档：
**要复核 D1 的实测数字、命令与"本地查 / 服务器只查 catalog"的分工表，看 `config/README.md`。**

> **这条偏离记录本身的教训**：把一次实测的**数字**写进长期文档，数字会随代码过期；
> 写清**判据**（「那棵树没有 git 元数据 ⇒ 该阶段在那里不可判定」）才不会过期。
> 上面的表之所以把命令与 rc 一起列出来，就是为了下次能**重跑**而不是**照抄**。

### D4. catalog 不变量「`pinRef` 形如合法 ref」**整条未实现**（登记，不裁决）

**字面约束**（「决策 4 · catalog 阶段」的第一条）：`pinPolicy: tag` ⇒ `pinRef`
非空、不带 `refs/` 前缀、**形如合法 ref**。

**偏离**：第三条**没有实现**。`scripts/check-components.mjs` 的 `validateCatalog()`
只查了前两条（非空 + `refs/` 前缀），**没有任何 ref 形态校验**。

> **与 D3 的区别（别混为一谈）**：D3 是「依据的**措辞**过期，结论不变」；
> D4 是「**一条决策整条没有落地**」。两者都记在偏离记录里，但严重程度不同——
> 前者是文档问题，后者是**门禁缺口**。

**后果（这是为什么要登记它）**：`pinRef: "???"`、`pinRef: "a b"` 这类值能**通过 catalog 阶段**，
直到 `scripts/check-pins.sh` 拿它去 `git fetch` 才暴露。也就是说这条不变量当前由
**下游的联网步骤**兜底，而不是由声明它成立的那道门保证。

**状态**：**未实现，且不打算在本轮补**。已在 [config/README.md](../../../config/README.md)
文末的实现状态表里如实标 ❌，`docs/remediation-plan.md` 的逐项结果同标 ❌——
**不是被藏起来，而是本 ADR 的「实施偏离记录」漏登了它**。本节补上这个缺口
（该机制是**专为**这类落差设的，一条整条未实现的不变量不该只在别处被提到）。

**为什么记在这里而不是改决策**：本 ADR 是**决策文档**，写的是「应该是什么」；
`config/README.md` 是**实现状态**，写的是「现在是什么」。**落差记在偏离记录里，决策保持原样**——
这样下一个读者既能知道目标形态，也能知道当前边界在哪。
