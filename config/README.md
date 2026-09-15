# config/ — 组件目录的字段字典

本目录的 [`components.json`](components.json) 是**组件元数据的单一登记源**。

⚠️ **"登记"不等于"保证"**：每个字段是否构成工程保证，取决于它的**分类**（下表）与
**实现状态**（文末）。例如 `releaseScope` 与 `ciScope` 目前是 `declared`——
它们记录意图，**没有任何东西读它们做决定**。

**本文是字段语义的唯一定义处。** 新增消费者时先读这里，不要靠读脚本反推——
`scripts/setup.sh` 曾把 `ciScope` 当成「要不要安装」，而它的真实语义是「CI job 参与范围」，
导致 6 个运行时插件在全新环境被整批跳过。**字段读错不会报错，只会静静地做错事。**

> 设计取舍与理由见 [ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md)。

## 字段三分类

判据是「**有没有行为或门禁消费者**」——不是「有没有任何代码读它」。
展示类消费者（如 `gen-notices.mjs` 渲染声明）**不构成工程保证**。

| 类别 | 含义 | 读它意味着 |
| --- | --- | --- |
| **operational** | 影响**执行、门禁或发布结果** | 它是真的在起作用；改它必须同步消费者 |
| **declared** | 可被**展示/生成器**读取，但**无行为执行、无真实性校验** | ⚠️ **不构成任何保证**。它记录意图，不改变行为 |
| **derived** | 权威源在别处 | 本目录不持有；需要时去权威源读 |

⚠️ **declared 字段的常见误读**：看到 `releaseScope: ["bundle"]` 就以为"这个组件会进制品"。
在制品链落地之前，**没有任何东西读它做决定**。它记录的是设计意图，不是当前行为。

## 字段字典

### 顶层

| 字段 | 类别 | 说明 |
| --- | --- | --- |
| `version` | schema 元数据 | catalog schema 版本。**未知版本直接拒绝**，不做尽力兼容。见下方「版本与迁移」 |
| `description` | schema 元数据 | 本文件用途的人读说明 |

### 组件字段

| 字段 | 类别 | 取值 | 消费者 | 它**保证**什么 | 它**不**保证什么 |
| --- | --- | --- | --- | --- | --- |
| `name` | **declared** | 自由文本 | 诊断输出、notices（**均属展示**） | 组件在报告里的可读名 | 机器身份——**真正的机器身份是 `path`**；也不保证唯一或与子仓 `package.json` 的 `name` 一致 |
| `path` | operational | 相对路径 | 所有 `--list` / `--plan` 调用点 | 组件在主仓的位置 | 该目录存在（未初始化时不存在） |
| `pinPolicy` | operational | `tag` / `branch` | `check-pins.sh` | 用哪种语义比对 pin | 该 ref 在远端存在（那要联网查） |
| `pinRef` | operational | tag 名或分支名 | `check-pins.sh` | 比对的目标 ref | 它指向的 commit（那由 gitlink 决定） |
| `runtimeScope` | operational | `required` / `excluded` | `--plan prepare`、`--list runtime:excluded` | **是否属于我们的运行时组合** | 它是否可用（那要看 `prepareMode` 与构建是否成功） |
| `prepareMode` | operational | 见下 | 构建动作计划 | **本仓对该组件采取什么准备动作** | 该动作会成功；也**不**描述子仓自身的性质 |
| `license` | operational | SPDX 标识符（受控词表） | 词表校验、与 `package.json` 声明的一致性、notices | 声明值**在受控词表内**；materialized 时与子仓 `package.json` 的 `license` **声明一致** | **真实许可证身份**，以及依赖树的合规性。`check-licenses.mjs` 只做**有限的反向风险检测**（认得出 copyleft 特征串就拒），**不是**许可证识别器 |
| `sourceAuthority` | **declared** | `github` / `gerrit-fork` | 仅 notices 渲染 | 记录来源归属的**意图** | 当前 fetch URL 是什么（**目录里没有 URL**）；也未校验本地 `origin` |
| `ciScope` | **declared** | `build` / `install` / `test` / `package` / `metadata` | 无行为消费者 | 记录该组件参与哪些 CI 阶段的**意图** | 真的会有对应的 CI job；更**不**表示"要不要安装" |
| `releaseScope` | **declared** | `bundle` / `sbom` / `provenance` | 仅 notices 渲染 | 记录制品归属的**意图** | 制品链尚未实现——**目前没有任何东西读它做决定** |
| `platforms` | **declared** | `linux-x86_64` / `macos-arm64` | 无 | 记录支持的平台**意图** | 平台矩阵是否真的在跑 |
| `testProfile` | **declared** | 自由文本 | 无 | 记录测试怎么跑的**意图** | 测试是否被执行 |
| `stateSchema` | **declared** | `harness-owned` / `none` / `n/a` | 无 | 记录状态 schema 归属的**意图** | 迁移兼容性（详见 [docs/remediation-plan.md](../docs/remediation-plan.md) §T6） |
| `notes` | **declared** | 自由文本 | 仅人读 | 补充说明与踩坑提示 | 任何机器行为 |

> **`packageManager` 已删除**（derived）。权威源是**各子仓自己的** `package.json`——
> `setup.sh` / `remote-install.sh` 读的一直是那一份。目录里再存一份只能是漂移的副本。

## `runtimeScope` × `prepareMode` 真值表

两个字段是**正交**的：`runtimeScope` 决定**要不要准备**，`prepareMode` 决定**怎么准备**。

| `runtimeScope` | `prepareMode` | 允许 | 说明 |
| --- | --- | --- | --- |
| `required` | `source-build` | ✅ | 装依赖并执行 build |
| `required` | `tracked-prebuilt` | ✅ | 装运行依赖并校验入口已被跟踪，**不**执行 build |
| `required` | `install-only` | ✅ | 装依赖，无构建步骤 |
| `required` | `none` | ❌ | 矛盾：说它属于运行时，却不准备 |
| `excluded` | `none` | ✅ | 不属于运行时，不准备 |
| `excluded` | 其余三值 | ❌ | 矛盾：不属于运行时，却要准备 |

**`prepareMode` 的四个取值**（「可判定动作」列 = 当前**有校验支撑**的部分）：

| 值 | 动作 | 当前**可判定**的动作 | 常见于 |
| --- | --- | --- | --- |
| `source-build` | 安装依赖 → 执行 build | 存在 `package.json.scripts.build` | 入口未提交的仓、workspace 根 |
| `tracked-prebuilt` | 安装运行依赖 → 校验运行入口 → **不**执行 build | `main`、`types`、无通配符 `exports` 目标**均被 git 跟踪** | 入口与产物已提交在子仓里的仓 |
| `install-only` | 安装依赖，无 build | —（无额外校验） | 无需编译的运行时组件 |
| `none` | 不准备 | — | metadata-only / 不属于运行时 |

⚠️ **命名与措辞的诚实性**：`tracked-prebuilt` 只声称「**声明的运行入口已被 git 跟踪**」，
**不声称「所有产物已验证」**。当前**没有**统一的"输出契约"，
所以"验证输出""验证所有产物"这类说法**没有可执行判据**，本文不使用。
完整的产物校验（含最小加载/冒烟）是后续工作。

## 校验：两个阶段

| 阶段 | 命令 | 何时 | 查什么 |
| --- | --- | --- | --- |
| **catalog** | `check-components.mjs` | `make setup` **之前**即可运行 | JSON schema、`.gitmodules` 双向集合、内部不变量 |
| **materialized** | `check-components.mjs --require-materialized` | 子仓就绪后 | 需**读子仓**的不变量：产物跟踪状态、build script 存在性 |

**CI 与 release 必须用 `--require-materialized`：任何 skip 都算失败。**

「子仓未初始化就跳过并计数」可以保留，但**不能作为最终门禁**——否则 fresh clone 上
一项都不查就能通过，那是 fail-open。

### 不变量

**catalog 阶段：**

- `pinPolicy: tag` ⇒ `pinRef` 非空、不带 `refs/` 前缀、形如合法 ref
- `runtimeScope: excluded` ⇒ `releaseScope` **不含 `bundle`**
  （**不**要求 `releaseScope: []`：excluded 组件未来仍可能有独立制品、SBOM 或 provenance）
- `license` ∈ 受控词表且**不含 copyleft**

**materialized 阶段：**

- `prepareMode: tracked-prebuilt` ⇒ `main`、`types`、以及所有**无通配符**的 `exports` 目标，
  **均被 git 跟踪**（只查 `main` 不够：`exports` 指向未跟踪文件时 fresh clone 照样是坏的）
- `runtimeScope: required` ⇒ `prepareMode != none`
- `runtimeScope: excluded` ⇒ `prepareMode = none`
- `prepareMode: source-build` ⇒ `package.json.scripts.build` 存在

**一条只报警告、不阻断的：** `source-build` 且**任何会被加载的入口**已被 git 跟踪 ⇒
构建会**弄脏 submodule**，进而触发部署的快照保真检查。这是**运维后果**，不是 schema 矛盾——
本仓可以出于供应链政策选择源码重建，即使子仓恰好也提交了产物。

⚠️ **入口的枚举方式**与上面 `tracked-prebuilt` 相同（`main` / `types` / 无通配符 `exports` 目标）——
**只查 `main` 会漏报**：`dsh-market` 的 `main` 未被跟踪，被跟踪的是 `exports["./client"]`。

⚠️ **但候选集只算「构建产物」（代码模块），要排除 `package.json`、`cordis.patch.yml` 这类
人手维护的 manifest / 配置**——构建从不写它们。照搬全入口集会让警告对不会被弄脏的组件喊狼来了
（10 个组件里触发 6 个），而喊狼来了的警告会被忽略；只算构建产物则恰好 3 个。

## 版本与迁移

`version` 描述 **catalog schema** 的版本，与组件自身的版本无关。

- **未知版本直接拒绝**，不做尽力兼容：读一个自己不认识的结构，只会做出错误决定。
- 升版本时**必须同步所有读取方**，并在本文件记录迁移规则。
- 历史：
  - **v1 → v2**（[ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md)）：
    `buildMode` 更名 `prepareMode` 并扩为四值；删除 `packageManager`；
    引入字段三分类与两阶段校验。

## 实现状态

> ⚠️ **本文件描述的是模型（ADR-0005 采纳后应有的样子），不等于已经实现。**
> 逐项核对当前实现，避免把设计读成保证：

| 模型中的东西 | 当前实现状态 |
| --- | --- |
| 字段三分类 | **已定义**（本文）；`check-components.mjs` 尚未按类别校验 |
| `prepareMode` 四值 | **未实现**——字段当前仍叫 `buildMode`，只有三值 |
| `--plan prepare` | **未实现**——查询器目前只输出路径（`--list`） |
| 两阶段校验 + `--require-materialized` | **未实现**——materialized 类不变量尚未落地 |
| 删除 `packageManager` | **未实现** |
| `version: 1 → 2` | **未实现** |
| 删除 `setup.sh` / `remote-install.sh` 的 `main` 被跟踪启发式 | **未实现**——两处启发式仍在 |
| 三处 fail-open（`--list` 绕过 `validate()`、两处 `2>/dev/null \|\| true`） | **未修复** |
| **`gen-notices` 对 declared 字段标注免责** | **未实现**——生成物仍用「来源」「进制品」等**事实性表头**，读者无从知道这些列只是声明 |
| **统一的 prepare 执行器** | **未实现**——`--plan` 只统一**决策数据**；动作执行仍是 setup 与 remote-install 两套 |
| **setup 在子仓就绪后、执行计划前调用 materialized 严格校验** | **未实现** |

实现计划见 [ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md) 的「实施约束」。
**本表在实现推进后必须同步更新**——留着过期的状态表，比没有状态表更危险。

## 相关

| 想知道 | 看哪 |
| --- | --- |
| 为什么这样设计 | [ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md) |
| 校验怎么跑 | `node scripts/check-components.mjs`（`--list` / `--plan` / `--require-materialized`） |
| 许可证怎么判 | `scripts/check-licenses.mjs`（读 `LICENSE` 文件）＋ [03-artifact §3.3](../docs/cicd/03-artifact-and-release.md) |
| 未收口事项 | [docs/backlog.md](../docs/backlog.md) · [docs/remediation-plan.md](../docs/remediation-plan.md) |
