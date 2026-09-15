# DSH 增量设计 Review（`1391a20..0cb4778`）

- Review 日期：2026-09-15
- 基线：`1391a20`（上一轮全仓 Review 时的 HEAD）
- 当前 HEAD：`0cb4778fce03bcd7b29931e377d2ecfc923280f8`
- 增量规模：24 个提交、39 个文件、`+2942/-139`
- Review 视角：Agent/协作约束、软件工程、SCM/供应链、Makefile、远程部署、日志与运维
- 本文性质：只给出审查意见、整改方案和验收标准，不实施具体修复

## 1. 结论先行

本轮增量的治理方向基本正确：引入了组件目录、拆清了 tag/branch pin 语义、加固了 GitHub Actions
供应链、补了许可证与治理文档、让 `ctx.logger` 有了控制台出口，并把 `Makefile` 进一步收敛为薄入口。

但当前状态**不能视为上一轮整改已经闭环**。本次发现 3 个需要优先阻断的缺陷：

1. `scripts/setup.sh` 只处理 `ciScope` 含 `install` 的插件，导致 6 个需要源码构建的运行时插件在全新环境被跳过；
2. legacy 部署仍会同步 Git ignored 的 macOS 原生产物与本地构建目录，远端落地内容仍不等于 Git pin 快照；
3. `scripts/t0b-alpha-probe.sh` 对用户传入目录直接执行 `rm -rf`，缺少路径安全校验。

因此建议把当前状态判定为：

| 维度 | 结论 |
| --- | --- |
| 仓库管理 / Agent 约束 | 结构明显改善，但文档权威和整改状态仍有漂移，不能仅靠 AGENTS 文字约束代替机器门禁 |
| 软件工程设计 | 组件目录方向正确，但字段语义、消费者行为和跨字段约束尚未形成完整模型 |
| SCM / 供应链 | pin 语义改善；来源 URL、authority、local origin 尚未闭环校验，发布许可证门禁存在旁路 |
| Makefile | 薄入口设计合理；问题主要在被调用脚本，以及 release 没有复用统一检查入口 |
| 远程部署 | legacy 方案仍不具备生产可行性，且当前存在宿主机原生产物跨平台同步风险 |
| 日志机制 | “完全不可见”已得到缓解；结构化、脱敏、轮转、保留、关联和审计仍未完成 |

## 2. 增量变更评价

### 2.1 值得保留的改进

- `config/components.json` 把组件、pin、运行时、制品、平台、许可证等信息放到同一目录，方向正确。
- `scripts/check-pins.sh` 将 tag pin 定义为精确相等，将 branch pin 定义为分支历史可达，避免上游分支前进后历史快照永久失效。
- `.github/workflows/*` 的 Action 已 pin 到 commit SHA，ShellCheck 下载增加 checksum，供应链基本卫生明显改善。
- `AGENTS.md` 增加了操作授权边界、验证报告格式和 CI/CD 权威入口，适合 Agent 与人工协作。
- `make check` / `scripts/check-all.sh` 提供统一的本地校验入口，离线检查与联网 pin 检查分层合理。
- `dsh-plugin-mineru` 已从 gitlink、`.gitmodules` 和当前组件目录移除，许可证政策比“默认不进”更明确。
- `mount-logger-console.yml` 让此前可能静默丢失的 `ctx.logger` 输出进入控制台；日志文件名增加 UTC 时间与 PID，降低并发碰撞。
- telemetry 开关改为 harness 实际识别的 `DSH_TELEMETRY_MODE=DISABLED`，比设置不存在的变量可靠。

### 2.2 总体设计判断

这 24 个提交主要解决了“缺少治理结构”的问题，但也暴露了下一层问题：

> 有了单一事实源，不等于已经有了单一语义；有了检查脚本，不等于所有高风险入口都实际调用了它。

当前最需要收口的不是继续增加文档，而是让 `components.json` 的每个字段有可验证语义，并保证 setup、CI、release、
remote-install、link、SBOM 等所有消费者使用同一套解析与校验逻辑。

## 3. Findings（按优先级）

### P0-1：组件生命周期语义不一致，fresh setup 会跳过源码构建插件

**增量来源**：`8a6d9b9`

**证据**：

- `scripts/setup.sh:201-218` 只读取 `node scripts/check-components.mjs --list ci:install`，随后跳过所有不在该列表中的插件；
- `config/components.json` 中仅 `dsh-automation` 和 `dsh-agent-teams` 含 `ciScope: ["install", ...]`；
- `dsh-web`、`dsh-better-sidebar`、`modlens`、`dsh-market`、`dsh-at-file`、`modsearch` 均为
  `runtimeScope: required` / `buildMode: source-build`，但它们只有 `build/test/package`，没有 `install`；
- 本次集合差验证显示，除 harness 外有 6 个 required 插件不在 `ci:install` 中；
- `deploy/remote-install.sh:206-229` 又走向相反极端：不看 `ciScope`、`runtimeScope` 或 `buildMode`，安装并尝试构建所有
  `plugins/*`，包括声明为 metadata-only / no-build 的 `dsh-tui`。

**影响**：

- 全新 `make setup` 可能在依赖安装和构建之前跳过主要运行时插件；已有缓存或已提交构建产物会掩盖问题；
- GitHub verify/release 都调用 `make setup`，因此 CI 结果取决于插件仓是否碰巧携带可用产物；
- 本地与服务器对同一个组件目录给出相反解释，组件目录尚不能称为真正的执行事实源。

**修改方案**：

1. 先定义生命周期模型，不要仅靠给所有组件补一个 `install` 字符串来止血；
2. 建议以 `buildMode` 决定操作：`source-build` 必须 install + build，`prebuilt-verified` 必须执行可验证安装/产物校验，
   `no-build` 不安装不构建；`ciScope` 只表达 CI job 参与范围；
3. 抽出一个经过 schema 校验的组件查询器，由 local setup、remote build、CI 和 release 共用；
4. 增加 fresh-clone 集成测试：每个 `runtimeScope=required` 的组件必须被准备一次，excluded 组件必须为零次。

**验收标准**：

- 空缓存、空 `node_modules` 环境中 `make setup` 能准备全部 required 组件；
- local setup 与 remote-install 对相同 manifest 生成相同的组件/动作计划；
- `dsh-tui` 在当前政策下不安装、不构建、不挂载、不进 bundle。

### P0-2：部署快照检查看不到 ignored 文件，macOS 原生产物会被 rsync 到 Linux

**增量来源**：`1b52942`

**证据**：

- `scripts/deploy-remote.sh:375` 和 `:395-396` 使用 `git status --porcelain --untracked-files=all`；Git status 默认不报告 ignored 文件；
- rsync 排除项位于 `scripts/deploy-remote.sh:153-164`，没有排除所有 ignored/build 输出；
- 当前工作树存在被 Git 忽略的 `harness/native/system/packages/darwin-arm64/bin/system.node`，文件类型为
  `Mach-O 64-bit bundle arm64`；
- 用部署脚本相同排除清单做本地 `rsync -ani`，确认它还会传输：
  - `harness/.dsh-build/client-build-environment.json`；
  - `harness/native/system/packages/darwin-arm64/bin/system.node`；
  - 多个插件的 ignored `lib/` / `dist/` 构建目录。

**影响**：

- “工作树 clean”并不能证明 rsync 字节等于 Git HEAD + gitlink；
- 违反本仓“原生依赖必须按平台构建、严禁跨平台复制”的硬约束；
- Linux 服务器可能收到 macOS Mach-O 原生模块，产生难定位的加载失败或混合制品；
- 部署标识仍可能与实际落地字节不一致，P0-1/P0-2 不应登记为完全修复。

**修改方案**：

1. 正式方案使用 tracked allowlist/staging tree，而不是继续扩充 rsync 黑名单；
2. 由主仓 `git ls-files` 与每个 submodule 的精确 gitlink 生成源码快照，生成物只允许来自受控 Linux 构建阶段；
3. 原生模块必须在目标平台或受控 Linux builder 构建，并记录 digest、平台和工具链；
4. legacy 止血方案至少应拒绝/排除所有 ignored 文件，并对 `native/**/bin`、`.dsh-build`、`dist`、`lib` 做显式保护；
5. 将 `docs/remediation-plan.md` 的 P0-1/P0-2 状态改为“部分完成”，直至 allowlist 制品路径落地。

**验收标准**：

- 任意 ignored 文件均不能无声明进入部署 payload；
- Linux payload 中不存在 `darwin-arm64`、Mach-O 或本机绝对路径；
- 可由 manifest 重建 payload 文件清单，并验证清单 digest 与部署 digest 一致。

### P0-3：T0b 探针允许对任意参数目录执行 `rm -rf`

**增量来源**：`ad22dd3`

**证据**：

- `scripts/t0b-alpha-probe.sh:23` 接受任意 `$1` 作为 `SCRATCH`；
- `:67` 在创建目录前执行 `rm -rf "$SCRATCH"`，`:161` 成功后再次删除；
- 没有 `realpath`、路径深度、允许前缀、根目录、HOME、符号链接或 owner 校验。

**影响**：

误传 HOME、工作区或其他已有目录会造成不可恢复的数据删除。即便脚本不是正式部署入口，作为可重跑证据保留在仓内后，
它也必须满足与部署脚本相同的破坏性操作边界。

**修改方案**：

- 默认用 `mktemp -d` 创建唯一目录并通过 trap 清理；
- 最好取消自定义 destructive target；若必须允许自定义目录，只允许位于固定测试根下的新建子目录；
- 拒绝 `/`、HOME、仓库根、系统目录、已有非空目录和符号链接，删除前再次校验 canonical path；
- 并发测试应收集每个后台 job 的退出状态，而不只检查最终链接目标。

**验收标准**：

- `/`、HOME、仓库根、已存在目录、符号链接参数均在删除前失败；
- 默认运行只删除本次由脚本创建且 owner 匹配的临时目录；
- 任一后台切换失败时探针整体失败。

### P1-1：release 入口绕过了新增的许可证内容门禁

**增量来源**：`ff0ee87`、`7ff7d80`

**证据**：

- verify 的 step 0 调用 `bash scripts/check-all.sh --offline`；
- `.github/workflows/release.yaml:28-34` 只运行组件目录、notices 和 pins，没有运行
  `check-licenses.mjs` / `probe-license-gate.sh --strict`；
- `scripts/release.sh:13-17` 也只调用 `check-pins.sh`；
- tag push 独立触发 release，并不天然继承普通 verify 的结果。

**影响**：

一个目录声明和 `package.json` 都伪装为 MIT、但 LICENSE 内容为 GPL 的 tag，仍可能越过 release 路径创建 GitHub Release。
这说明“检查清单单一事实源”目前只覆盖部分入口。

**修改方案**：

- release 在任何 tag/上传动作前调用统一的 release preflight；
- preflight 至少复用 `scripts/check-all.sh --offline`，再单独执行联网 pin、构建、SBOM、provenance 检查；
- 增加测试，证明 B1 合成投毒样例同时被 verify 和 release 拒绝。

**验收标准**：所有对外发布入口使用同一份门禁清单，不能在 workflow 中再维护第二份手工检查列表。

### P1-2：许可证政策文档是 fail-closed，实际脚本仍多处 fail-open

**增量来源**：`dc426bc`、`2d2b871`、`ff0ee87`

**证据**：

- `docs/cicd/03-artifact-and-release.md:106-114` 规定无许可证/自定义条款拒绝准入；
- `scripts/check-components.mjs:86-106` 对未初始化组件、无 `package.json` 或无 license 声明静默跳过；
- `scripts/check-licenses.mjs:19-23`、`:88-96` 把目录不存在和缺 LICENSE 作为非阻断项；
- `scripts/check-licenses.mjs:46-73` 只读取第一个匹配的 LICENSE/COPYING 文件；
- 当前门禁不覆盖 workspace 子包与依赖树，严格 probe 反而把这些缺口登记成预期行为。

**影响**：

机器门禁不能证明规范中声明的“无许可证拒绝”和“bundle 无策略禁止许可证”。多许可证仓、workspace 子包或依赖树仍可绕过。

**修改方案**：

1. 对 `runtimeScope=required` 或进入 release bundle 的组件强制要求可验证的许可证来源；
2. 扫描所有根级 LICENSE/COPYING 文件；多许可时要求 catalog 使用明确 SPDX expression 并验证一致性；
3. 在制品阶段生成 SBOM 并对依赖许可证做真正的 release gate；
4. 将 probe 中“缺许可证不阻断”的预期改为 shippable 组件必须失败；
5. 文案应精确定义禁用的是 GPL-family/强 copyleft/网络 copyleft，还是所有 copyleft。当前 allowlist 包含
   MPL-2.0，而 MPL-2.0 通常被归为弱/file-level copyleft，“不接纳任何 copyleft”与 allowlist 不一致；
6. 对 `docs/cicd/03-artifact-and-release.md:116-119` 的法律结论做专业合规复核，避免把所有组合/聚合分发一概描述成整个制品自动改许可证。

补充：`LICENSE:204` 把版权行追加在 Apache-2.0 附录示例之后，不建议修改标准许可证全文；版权声明宜放 NOTICE 或源码头。

### P1-3：组件目录没有校验真实来源 URL，SCM authority 可被本地 origin 替换

**增量来源**：`8a6d9b9`、`dc426bc`

**证据**：

- `config/components.json` 只有枚举式 `sourceAuthority`，没有 canonical URL / owner / 当前 fetch URL；
- `check-components.mjs` 只双向比较 path 集合，不校验 `.gitmodules` URL 或 submodule local origin；
- `check-pins.sh:51-76` 直接 fetch 每个 submodule 当前名为 `origin` 的远端；
- `dsh-automation` 声明 `sourceAuthority: gerrit-fork`，但 `.gitmodules` 与当前 `origin` 都是 GitHub URL；
- 生成的 `THIRD-PARTY-NOTICES.md` 以 `gerrit-fork` 为标签，却链接 GitHub URL。

**影响**：

pin 校验能够证明“某 SHA 属于当前 origin 的 tag/branch”，但不能证明这个 origin 是组织批准的权威来源。误改或恶意替换 local
origin 后仍可能通过；当前状态与未来 Gerrit 目标状态也被混在一个字段中。

**修改方案**：

- catalog 增加 canonical fetch URL、owner、当前 authority、目标 authority/迁移状态；
- 校验 catalog、`.gitmodules`、本地 remote 与制品 provenance 中的 URL 一致；
- pin 校验只 fetch 已校验的 URL，不信任任意本地 `origin`；
- fork 同时记录 upstream URL 和同步策略；Gerrit 尚未落地时不要把当前 GitHub fork标为已是 Gerrit authority。

### P1-4：manifest 消费者 fail-open，schema 与跨字段约束不足

**增量来源**：`8a6d9b9`、`132495b`

**证据**：

- `check-components.mjs:174-182` 在 `--list` 模式直接查询，没有先执行 `validate()`；
- `scripts/link-plugins.sh:30-33` 与 `deploy/remote-install.sh:42-45` 使用 `2>/dev/null || true`，目录解析失败会退化为空排除列表；
- 对 excluded 组件的幂等摘除在 `scripts/link-plugins.sh:88-93` 命中第一个 package 后 `break`，多包组件可能残留；
- schema 未校验 name 唯一性、非空值、URL、字段关系，以及 `source-build ⇒ install/build plan` 等跨字段不变量；
- `config/components.json:3` 指向不存在的 `config/README.md`；
- `--list` 的错误提示声称支持 `runtime`，实际 selector 需要 `runtime:required` 或 `runtime:excluded`。

**影响**：

最需要组件目录保护的部署和挂载路径，反而会在目录解析失败时继续执行；P0-1 正是缺少跨字段约束导致的回归。

**修改方案**：

- 所有 list/query 前强制完整 schema + relationship 校验；
- 删除高风险消费者中的 `|| true`，配置错误必须 fail closed；
- 提供 JSON Schema 或受测的统一 Node 模块，不让 shell 脚本各自解释字段；
- 补 `config/README.md`，明确每个字段、允许值、消费者、默认值和组合不变量；
- 对 excluded 组件移除所有匹配包，并验证 profile 最终状态。

### P1-5：文档权威归一与整改台账存在“提前完成”

**增量来源**：`5a80706`、`b761e09`、`d4dc1eb`

**证据**：

- `README.md:3` 仍把历史 `docs/superpowers/specs/` 写成“设计”；`:41` 也未标出其非权威；
- `README.md:30` 仍复制当前 pin/tag/branch 等漂移事实；
- `docs/cicd/01-architecture.md:64` 与 `docs/cicd/adr/0001-gerrit-repository-boundary.md:47` 仍把
  `scripts/check-pins.sh` 写成 pin 事实源，和 `config/components.json` 冲突；
- `docs/remediation-plan.md:36-37` 将 T1/T2 标为完成，`:174-181` 将上一轮 P0-1/P0-2/P1-4 标为已修，
  与本次发现不一致；
- T4 内容仍由上下文反推且待确认，却进入正式整改总表。

**影响**：

Agent 和新人可能沿历史文档实施，或把“有部分守卫”误解成风险已经闭环。整改台账失去审计可信度后，会比没有台账更危险。

**修改方案**：

- 将上述完成状态改为“部分完成”，并链接本 Review；
- README 只保留权威入口，不复制 pin 值；所有历史 spec 在目录索引和文件头双重标注；
- 增加文档 lint：禁止活动文档把 `docs/superpowers/specs` 称为当前设计，禁止在非 catalog 文件复制 pin 事实；
- 未确认编号/内容必须保持“待确认”，不要以推断填充正式工程承诺。

### P1-6：Git 历史泄露目标机信息，且已有提交信息被 shell 替换破坏

**增量来源**：`ad22dd3`、`1b52942`

**证据**：

- `ad22dd3` 的提交正文包含真实账号与内网 IP，而 `docs/deploy-handoff.md:46-47` 明确禁止把真实主机写进提交；
- `1b52942` 的提交正文被意外插入整段 `git submodule status` 输出；
- `ad22dd3` 正文中“不是”缺失，也符合反引号在双引号 commit message 中被 shell 执行后的破坏特征；
- 当前分支跟踪 `origin/main`，上述历史已经进入远端分支。

**影响**：

内网拓扑和账号进入不可变历史；提交记录作为审计证据的质量下降。私网 IP 不是凭据，但仍属于不必要的信息披露。

**修改方案**：

- 后续统一用 `git commit -F` 或安全的编辑器流程；
- pre-push/CI 扫描提交正文中的 host、IP、凭据模式和异常长命令输出；
- 不要自动改写已共享历史：若仓库尚未被他人消费，可经团队明确批准后协调 rebase/force-push；否则保留 SHA，追加纠正文档并轮换真正敏感信息。

### P2-1：治理文件仍有未解析占位符

- `SECURITY.md:8` 的安全联系邮箱仍是待填；
- `.github/CODEOWNERS:6` 仍写“待填”，但规则已填入具体账号，状态含混；
- 仓库既已推送到 GitHub，这些治理入口应在宣称 T9 完成前确认。

建议：确认 owner 与私密报告渠道，删除占位符；为 CODEOWNERS/高风险路径保护增加平台侧实际配置证据。

### P2-2：GitHub workflow 仍保留重复的内联实现

verify/release 仍分别内联 ShellCheck 下载与 HTTP 轮询。它不影响当前 Gerrit + Jenkins + Nexus 的目标主链判断，
但与 `AGENTS.md` 所述“workflow 只调用 scripts”存在已知张力，也会继续造成 release/verify 漂移。

建议：把下载校验和 smoke readiness 移入 `scripts/`，workflow 只做版本化调用；同时避免把 `ubuntu-latest` 和 Node 大版本
当成严格可复现环境。

## 4. 对用户四个问题的增量回答

### 4.1 整仓管理方式和架构文档是否清晰？

**比基线清晰，但尚未闭环。**

优点是 AGENTS、README、CI/CD 入口、组件目录、backlog、remediation ledger 已形成导航层级。主要问题是：

- README/ADR 仍指向旧事实源或复制漂移数据；
- components 的字段词汇有了，但操作语义和跨字段规则没定义完整；
- 台账多处把“局部保护”登记成“完全修复”；
- Agent 约束写得很好，但高风险边界仍需由代码和测试强制。

结论：信息架构可用，工程权威性仍是“部分完成”。

### 4.2 Makefile 管理是否合理？

**Makefile 本身基本合理，薄入口方向应保留。**

本轮 VERSION 传递、日志命名、`make check` 都是正向改进。主要问题不在 Makefile 语法，而在入口下游：

- `make setup` 调用的组件筛选逻辑存在 P0 回归；
- `make release` 没有消费统一的离线门禁；
- local setup 与 remote-install 仍复制大量安装/构建逻辑并产生语义分叉。

建议继续保持 Makefile 只做参数校验和脚本路由，把“组件动作计划”收敛为一个受测模块。

### 4.3 远程部署方案是否可行？

**legacy 路径可作为受限实验入口，但当前不适合作为生产部署方案。**

新增的 dirty、gitlink、telemetry 守卫有价值，但 ignored 文件仍能进入 rsync，已经实证会携带 macOS Mach-O；
remote-install 也没有正确消费组件生命周期。T0b 的 release/current/state 分离机制方向可行，但本次只从 Git 历史看到合成探针
的真机通过记录，本 Review 没有在远端复验；探针自身还存在 destructive target 风险。

生产可行性的最低门槛仍是：Linux 构建不可变制品、digest promotion、非 root、状态外置、原子切换、自动回滚、受控 systemd、
制品/SBOM/provenance 验证，而不是继续增强源代码 rsync 黑名单。

### 4.4 日志机制是否健全？

**可见性有改善，但离“健全的生产日志机制”仍有明显距离。**

当前已有：

- `ctx.logger` console exporter；
- 本地 raw log 独立目录；
- UTC + PID 文件名；
- 部署排除 `log/` 和散落 `*.log`。

仍缺：

- 结构化 JSON schema 和稳定字段；
- request/session/deploy digest/trace 关联；
- 凭据、token、URL query、用户内容与绝对路径脱敏；
- systemd/journald 与本地文件的职责边界；
- rotation、retention、磁盘水位、采集失败策略；
- 告警/SLO、审计日志、崩溃与部署事件关联；
- 自动化测试证明 exporter 存在、敏感字段不落盘、日志不会被打进制品。

因此上一轮 P0“告警完全不可见”可以视为方向上缓解，但 P1-7/P2-3 仍应保持未完成。本次没有运行服务做 A/B 复验，
不能把历史提交中的实测说明当成本轮已验证。

## 5. 建议的整改顺序

| 顺序 | 整改包 | 目标 | 建议状态 |
| --- | --- | --- | --- |
| 1 | I0：安全止血 | 修 T0b scratch 删除边界；部署立即拒绝 ignored/native 宿主机构建物 | 阻断其他部署实验 |
| 2 | I1：组件生命周期模型 | 定义 schema/跨字段规则，统一 local/remote/CI/release 消费者 | 阻断 fresh setup 与 release |
| 3 | I2：部署 payload allowlist | Git tracked snapshot → Linux builder → immutable artifact → digest promotion | 取代 source rsync 黑名单 |
| 4 | I3：release 合规门禁 | verify/release 共用许可证、notice、SBOM、provenance 门禁 | 对外发布前完成 |
| 5 | I4：SCM authority | URL/owner/upstream/current-target authority 校验，锁定可信 fetch 来源 | Gerrit 迁移前完成 |
| 6 | I5：文档与台账纠偏 | T1/T2/P0-1/P0-2 改为部分完成，清理旧入口与复制 pin | 与 I1/I2 同步 |
| 7 | I6：日志协议 | schema、脱敏、关联、轮转、采集、告警与测试 | 生产启用前完成 |
| 8 | I7：治理与历史卫生 | 安全联系方式、CODEOWNERS 实配、commit-message 扫描 | 发布前完成 |

## 6. 建议更新整改台账

| 当前项 | 当前状态 | 建议状态 | 原因 |
| --- | --- | --- | --- |
| T1 文档权威归一 | ✅ 完成 | 🟡 部分完成 | README/ADR 仍存在旧入口与事实源 |
| T2 组件目录 | ✅ 完成 | 🟡 部分完成 | setup/remote 生命周期语义分叉、query fail-open |
| T9 GHA/治理 | ✅ 完成 | 🟡 部分完成 | release 许可证门禁旁路、治理占位符未收口 |
| P0-1 部署内容 = HEAD | ✅ 已修 | 🟡 部分完成 | ignored 文件不在 dirty 检查中且会被 rsync |
| P0-2 本地产物排除 | ✅ 已修 | 🟡 部分完成 | 仍会同步 `.dsh-build`、Mach-O、插件 ignored build 输出 |
| P0-3 logger exporter | ✅ 已修 | 保留“可见性修复” | 但不要据此关闭 P1-7/P2-3 |
| P1-4 文档冲突 | ✅ 已修 | 🟡 部分完成 | 当前权威入口仍有残余冲突 |

## 7. 验证记录

已验证：

- `git merge-base --is-ancestor 1391a20 HEAD` → 退出码 0，增量基线有效；
- `git log --format='%h %s' 1391a20..HEAD` / `git diff --stat 1391a20..HEAD` → 24 个提交、39 个文件、`+2942/-139`；
- `git status --porcelain=v1` 与 `git submodule foreach --recursive 'git status --porcelain=v1'` → 根仓和递归 submodule 无未提交改动；
- `bash scripts/check-all.sh --offline` → 4/4 通过；
- `shellcheck -S style scripts/*.sh deploy/remote-install.sh` → 退出码 0；
- 对新增/修改的主要 `.mjs` 执行 `node --check` → 退出码 0；
- 比较 `runtime:required`、`ci:install`、`ci:build` 列表 → 6 个 required 源码插件不在 setup 使用的 install 列表；
- `git check-ignore` + `file harness/native/system/packages/darwin-arm64/bin/system.node` → 文件被忽略且为 macOS arm64 Mach-O；
- 用 `scripts/deploy-remote.sh` 相同 exclude 集做本地 `rsync -ani` → 确认上述 Mach-O、`.dsh-build` 和多个 ignored `lib/dist` 会被同步；
- 检查 `release.yaml`、`release.sh` 与 `check-all.sh` 的调用关系 → release 未消费许可证内容检查和严格 probe；
- 检查 `.gitmodules`、catalog 与 `dsh-automation` remotes → 当前 fetch/origin 为 GitHub，catalog 标签为 `gerrit-fork`；
- `make check` → 4 项通过、1 项失败，失败项为联网 fetch 的 pin 校验；shellcheck 仍通过。当前受限网络下不能将其报告为全绿。

未验证：

- fresh clone 上完整 `make setup`（原因：会安装/构建大量依赖；本次通过集合与控制流静态验证确认回归）；
- GitHub Actions verify/release 实际运行（原因：未触发远端 workflow）；
- `make deploy`、远端安装、systemd、回滚（原因：属于显式授权的远程写入，本次未执行）；
- T0b 在目标 Linux 主机的 13 项历史结果（原因：本次只审查 commit 记录与脚本，未远端复验）；
- logger-console 的运行时 A/B、脱敏与并发压力（原因：未启动服务）；
- 在线 pin 完整校验（原因：当前执行环境无法完成所有 submodule fetch）。

## 8. 最终建议

不建议继续把当前增量按“上一轮问题已全部处置”向下传递。先由后续修改任务完成 P0-1/P0-2/P0-3，随后再收口 release
合规、SCM authority 和文档台账。修复时应把每个整改包拆为独立提交，并为组件动作计划、部署 payload 文件清单和 release
preflight 各自补自动化回归；否则下一轮仍会出现“文档单一事实源已经成立，但执行入口各自解释”的同类问题。
