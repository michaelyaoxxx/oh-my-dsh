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
| **materialized** | `check-components.mjs --require-materialized` | 子仓就绪后——⚠️ **且只在有 git 元数据的检出上**（见下） | 需**读子仓**的不变量：产物跟踪状态、build script 存在性 |

**CI 与 release 必须用 `--require-materialized`：任何 skip 都算失败。**

「子仓未初始化就跳过并计数」可以保留，但**不能作为最终门禁**——否则 fresh clone 上
一项都不查就能通过，那是 fail-open。

### ⚠️ 部署树**跑不了** materialized——这是**树的属性**，不是配置问题

`scripts/deploy-remote.sh:184` 的 rsync 带 `--exclude '.git'`，而 `--exclude` 对**每一层路径**生效
⇒ **服务器那棵树里没有任何 git 元数据**。（`.gitmodules` **在**——它是被跟踪的普通文件，
不是 git 元数据；`.git` 不在。）materialized 阶段靠 `git ls-files` 判「入口是否被跟踪」，
在那棵树上**恒为不可判定**，所以它**永远无法**在服务器上运行。

实测（2026-09-15，忠实 rsync 副本——同一份 `--exclude` 清单，副本内 `.git` 确认不存在）：

| 命令 | 副本上的结果 |
| --- | --- |
| `check-components.mjs`（catalog） | **rc=0**；`materialized 检查：0 个已验；0 个跳过；**10 个因 git 元数据不可用而无法判定**` |
| `check-components.mjs --require-materialized` | **rc=1**；`✗ --require-materialized：10 个组件无法在 materialized 阶段校验…严格模式下不允许跳过` |
| `check-components.mjs --plan prepare` | **rc=0**，输出与本地源树**逐行一致** |

> **为什么要写这一段**：不写的话，下一个人看到「服务器上没跑 materialized 阶段」，
> 会以为那是**漏了一步**，然后去"补上"——**那会让每一次部署都失败**。
> 那个 rc=1 是**必然**的，不是"环境没配好"，**不要在服务器侧加这条。**

**故部署侧的分工是固定的，不要"修正"它：**

| 在哪跑 | 跑什么 | 为什么 |
| --- | --- | --- |
| **本地**（源树，有 git 元数据） | `--require-materialized`——`scripts/deploy-remote.sh:444` | 这是**最后能查动它**的地方；而且此时**一个字节都还没写到远端**，失败的代价只是本地退出 |
| **服务器**（部署树，无 git 元数据） | 只用 catalog 阶段的形式：`--list runtime:excluded`、`--plan prepare` | 查询路径**按设计就只跑 catalog 阶段**、不读子仓——这不是省事，是唯一跑得动的形态 |

⚠️ 查询路径（`--list` / `--plan`）**故意**只跑 catalog 阶段：`--require-materialized` 与它们并用时
**不会**因为「子仓没初始化」而失败。要严格校验就**别带** `--list` / `--plan`。

### 不变量

**catalog 阶段**（**只看目录即可判定**，不需要子仓）：

- `pinPolicy: tag` ⇒ `pinRef` 非空、不带 `refs/` 前缀、形如合法 ref
  （⚠️ **最后半句尚未实现**——当前只查了非空与 `refs/` 前缀，见文末「实现状态」表）
- `runtimeScope: excluded` ⇒ `releaseScope` **不含 `bundle`**
  （**不**要求 `releaseScope: []`：excluded 组件未来仍可能有独立制品、SBOM 或 provenance）
- `runtimeScope` × `prepareMode` **正交约束**（真值表见上）：`excluded` ⇒ `prepareMode = none`；
  `required` ⇒ `prepareMode != none`
- `license` ∈ 受控词表且**不含 copyleft**

> **`runtimeScope × prepareMode` 这一条比上面的归类更早落地。** 它**只看目录**即可判定，
> 不读子仓——按本节「需读子仓的才归 materialized」的组织原则，它属于 **catalog 阶段**。
> 本表此前把它列在 materialized 段，是**表自相矛盾**（T4 评审发现，2026-09-15 修正）。
> 实现见 `scripts/check-components.mjs` 的 `validateCatalog()`，注释标着
> 「catalog 阶段不变量（只看目录即可判定）」。

**materialized 阶段：**

- `prepareMode: tracked-prebuilt` ⇒ `main`、`types`、以及所有**无通配符**的 `exports` 目标，
  **均被 git 跟踪**（只查 `main` 不够：`exports` 指向未跟踪文件时 fresh clone 照样是坏的）
- `prepareMode: source-build` ⇒ `package.json.scripts.build` 存在

**一条只报警告、不阻断的：** `source-build` 且**任何会被加载的入口**已被 git 跟踪 ⇒
构建会**弄脏 submodule**，进而触发部署的快照保真检查。这是**运维后果**，不是 schema 矛盾——
本仓可以出于供应链政策选择源码重建，即使子仓恰好也提交了产物。

⚠️ **入口的枚举方式**与上面 `tracked-prebuilt` 相同（`main` / `types` / 无通配符 `exports` 目标）——
**只查 `main` 会漏报**：`dsh-market` 的 `main` 未被跟踪，被跟踪的是 `exports["./client"]`。

⚠️ **但候选集只算「构建产物」（代码模块），要排除 `package.json`、`cordis.patch.yml` 这类
人手维护的 manifest / 配置**——构建从不写它们。照搬全入口集会让警告对不会被弄脏的组件喊狼来了，
而喊狼来了的警告会被忽略。
（**实测快照**，2026-09-15、当时 11 个组件：照搬全入口集喊 **6** 个、其中 3 个是假的；
只算构建产物则**恰好 3 个**。⚠️ 这组数字是**当时**的测量，组件集合一变就会漂——
**别把它当当前值用**，要复核就跑 `make check` 看警告面。）

## 版本与迁移

`version` 描述 **catalog schema** 的版本，与组件自身的版本无关。

- **未知版本直接拒绝**，不做尽力兼容：读一个自己不认识的结构，只会做出错误决定。
- 升版本时**必须同步所有读取方**，并在本文件记录迁移规则。
- 历史：
  - **v1 → v2**（[ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md)）：
    `buildMode` 更名 `prepareMode` 并扩为四值；删除 `packageManager`；
    引入字段三分类与两阶段校验。

## 实现状态

> ⚠️ **本文其余部分描述的是模型（ADR-0005 采纳后应有的样子），不等于已经实现。**
> 下表**逐项**核对当前实现。**每行都必须附上能证明它的命令**——判据是跑出来的，不是读出来的。
>
> ⚠️ **注意有一行极性相反**：「删除 `packageManager`」的实现判据是**字符串不存在**。
> 对其余各行「grep 到了 = 已实现」成立，对那一行**不成立**。判据要按**语义**定，不能一律套 `grep`。

| 模型中的东西 | 当前实现状态 |
| --- | --- |
| 字段三分类 | **已实现**（不只"已定义"）。`scripts/check-components.mjs:63` 的 `FIELD_CLASS` 声明每个字段的类别；`checkFieldClassValues()`（同文件 `:376`）校验类别**值**也在受控词表内；未登记分类的字段直接拒绝。验证：`node scripts/check-components.mjs` → rc=0；`bash scripts/probe-catalog.sh` 的 B3/B4/B5 钉住三条退化路径 |
| `prepareMode` 四值 | **已实现**。字段已更名，`ENUM.prepareMode` 列出四值。验证：`grep -n "prepareMode: \['source-build'" scripts/check-components.mjs` → `:41` 含全部四值。⚠️ **当前 11 个组件只用到其中三个**（`source-build` / `tracked-prebuilt` / `none`），`install-only` 是**允许但暂无使用者**的取值——别把"没人用"读成"不支持" |
| `--plan prepare` | **已实现**。验证：`node scripts/check-components.mjs --plan prepare` → rc=0，**10 行** `<path>\t<prepareMode>`（`prepareMode: none` 的 `dsh-tui` 不在计划里） |
| 两阶段校验 + `--require-materialized` | **已实现**。验证：`node scripts/check-components.mjs` → rc=0（`materialized 检查：10 个已验；0 个跳过`）；`node scripts/check-components.mjs --require-materialized` → rc=0 且严格模式措辞生效（`0 个跳过——子仓未初始化（严格模式，跳过即失败）`） |
| 删除 `packageManager` | **已实现**——⚠️ **本行判据是"字符串不存在"**。验证：`node -e 'const c=require("./config/components.json");console.log(c.components.some(x=>"packageManager" in x))'` → `false`。⚠️ 全仓仍有 `packageManager` 字样（`scripts/setup.sh`、`deploy/remote-install.sh`）——那些读的是**子仓自己的** `package.json`，正是本表声明的权威源。**它们不是本行要删的东西** |
| `version: 1 → 2` | **已实现**。验证：`grep -n '"version"' config/components.json` → `"version": 2` |
| 删除 `setup.sh` / `remote-install.sh` 的 `main` 被跟踪启发式 | **已实现**。两处脚本已无该启发式；跟踪判定改由 materialized 阶段统一做（`trackedState()`）。验证：`grep -n 'ls-files' scripts/setup.sh deploy/remote-install.sh` → 剩余命中**只有** `pnpm-workspace.yaml` 的脚手架判定，与本启发式无关 |
| 三处 fail-open | **已修复**。① 查询路径绕过校验：`scripts/check-components.mjs:670` 改为分发**之前** `validateCatalog()` + `process.exit(1)`；② `scripts/link-plugins.sh:38`；③ `deploy/remote-install.sh:60`——后两处改为 `if ! _excluded="$(…)"` **显式判 rc**（只删 `\|\| true` 不够：`done < <(cmd)` 拿不到退出码，见两处注释） |
| **`gen-notices` 对 declared 字段标注免责** | **已实现**。生成物表头为「来源（声明，未验证）」「进制品（声明，未验证）」，且**双向**钉住：`assertColumnClasses()` 要求带后缀的列在 `FIELD_CLASS` 里**真是** `declared`，不带后缀的列**不是**。验证：`grep -n "声明，未验证" THIRD-PARTY-NOTICES.md`；`node scripts/gen-notices.mjs --check` → rc=0 |
| **统一的 prepare 执行器** | 🟡 **部分实现**。`scripts/prepare-executor.sh` 统一了**决策**（`case "$prepareMode"` 全仓仅一份，被 `scripts/setup.sh:285` 与 `deploy/remote-install.sh:299` 共同 source）。⚠️ **但动作原语仍是两份**：从 `plugin_install` 起的一整段（含带分支的 35 行 `plugin_install`）在两个调用方**逐字节相同**，**没有任何门禁保证它们同步**——见 [docs/backlog.md](../docs/backlog.md) **B11**。这笔账已经付过一次代价：`ret=$?` 的 fail-open 要修**两次**才对齐（`a4a3808` + `a25af8b`）。**别把本行读成"已实现"** |
| **setup 在子仓就绪后、执行计划前调用 materialized 严格校验** | **已实现**。验证：`scripts/setup.sh:218` 的 `node scripts/check-components.mjs --require-materialized \|\| { …; exit 1; }`，在 `:223` 取计划**之前** |
| **`pinRef` 形如合法 ref（而不只是非空）** | ❌ **未实现**。当前只查了**非空**与**不带 `refs/` 前缀**（`scripts/check-components.mjs:443-444`），**没有** ref 形态校验。⇒ `pinRef: "???"`、`pinRef: "a b"` 这类值能通过 catalog 阶段，直到 `check-pins.sh` 拿它去 fetch 才暴露。**这一项是上游不变量清单（本文件 `catalog 阶段` 那段）里唯一还没落地的一条** |
| **完整的产物校验（最小加载 / 冒烟）** | ❌ **未实现**。`tracked-prebuilt` 只声称「**声明的运行入口已被 git 跟踪**」——那是一个**可执行判据**；"验证输出""验证所有产物"目前**没有**可执行判据，故本文件不使用这些说法（见上方「命名与措辞的诚实性」）。要落地得先定义"输出契约" |

实现计划见 [ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md) 的「实施约束」。
**本表在实现推进后必须同步更新**——留着过期的状态表，比没有状态表更危险。

> ⚠️ **本表更新时请连判据一起更新。** 本表曾整表过期（11 行全部停在实现之前），
> 而其中一行的**极性**（「删除 `packageManager`」）与其余各行相反——
> 照抄"grep 到了就是已实现"的判据会把它判反。**先想清楚"证明它成立的那条命令是什么"，再去跑。**

> ⚠️ **「已实现」不等于「已在部署平台验证」。** 上表各行的证据**只在 macOS arm64 上跑过**；
> Linux x86-64（部署目标）的**双平台验证尚未完成**——`prepareMode` 会真实改变构建
> （`dsh-agent-teams` 开始构建、`dsh-at-file` 停止构建），而本仓硬约束是
> 「原生依赖必须按平台各自构建」。**只在一个平台验证等于没验证。**
> 当前状态、待授权后一次跑完的命令与验收判据见
> [docs/remediation-plan.md](../docs/remediation-plan.md) 的 **§T12**。

## 相关

| 想知道 | 看哪 |
| --- | --- |
| 为什么这样设计 | [ADR-0005](../docs/cicd/adr/0005-component-catalog-lifecycle.md) |
| 校验怎么跑 | `node scripts/check-components.mjs`（`--list` / `--plan` / `--require-materialized`） |
| 许可证怎么判 | `scripts/check-licenses.mjs`（读 `LICENSE` 文件）＋ [03-artifact §3.3](../docs/cicd/03-artifact-and-release.md) |
| 未收口事项 | [docs/backlog.md](../docs/backlog.md) · [docs/remediation-plan.md](../docs/remediation-plan.md) |
