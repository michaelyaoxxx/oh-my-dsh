# DSH 超级仓库设计 Review

| 属性 | 值 |
|---|---|
| Review 日期 | 2026-09-14 |
| 最终审查基线 | 超级仓库 `1391a20`；工作树另有未提交的 `docs/cicd/01-architecture.md` 格式改动 |
| Review 视角 | Agent 协作设计、软件工程、SCM/发布工程、部署/SRE、日志与可观测性 |
| Review 方式 | 单 Agent 静态审查；未启动 subagent；未执行真实远程部署或发布 |
| 结论状态 | 需要整改；当前 legacy 部署不得视为生产可用 |

## 1. 执行摘要

仓库的基本方向是合理的：用 superproject + gitlink SHA 管理独立上游，Makefile 保持薄入口，子仓独立发版，目标 CI/CD 采用双平台原生构建、不可变制品晋级和状态/应用分离。这些原则彼此一致，`docs/cicd/` 的目标设计也覆盖了 Gerrit、Jenkins、Nexus、staging、production、回滚、测试与运维。

但当前实现与目标设计之间仍有明显断层，不能把“设计完整”当成“工程已具备”。最重要的问题有四类：

1. 当前 `make deploy` 同步本地工作树而不是已验证制品；它没有拒绝根仓 dirty/untracked 内容，也没有递归验证 nested submodule 或检查 submodule 工作树内容。部署标识却只写主仓 `HEAD`，因此 SHA 可能与实际落地字节不一致。
2. `rsync` 不排除根 `log/`，也不按 Git tracked allowlist 取文件；本地日志、未跟踪文件或误放的敏感文件可能被同步到服务器。
3. pinned harness 的普通 profile 没有挂载 Cordis logger exporter。`ctx.logger.warn/error` 只进入内存环形缓冲区，无法进入终端、Make 日志或 journald；已有插件确实使用这条不可见路径报告调度和清理失败。
4. 文档存在两个“权威设计”：根 `README.md`/`AGENTS.md` 指向已确认的源码现场构建设计，`docs/cicd/` 又声明不可变制品目标是事实源；`docs/deploy.md` 还与刚更新的部署脚本在状态回滚语义上直接冲突。

因此总体判断是：

| 问题 | 结论 | 评级 |
|---|---|---|
| 1. 仓库管理与架构文档是否清晰 | superproject 选型合理，目标架构主线清晰；但权威源、当前态/目标态和 pin 策略不够清晰 | 有条件通过 |
| 2. Makefile 管理是否合理 | “薄 Makefile + scripts”合理；缺少统一门禁、参数安全、日志生命周期和可验证目标 | 基本合理，需补强 |
| 3. 远程部署是否可行 | 适合受控内网验证；尚不满足可追溯、原子性、最小权限和已验证生产发布要求 | 生产不可用 |
| 4. log 机制是否健全 | 当前操作日志只是 raw `tee`，关键应用日志会丢失，且无统一脱敏、轮转、关联和集中采集 | 不健全 |

## 2. 范围与验证边界

本次审查覆盖根仓治理文件、Makefile、`scripts/`、`deploy/`、GitHub Actions、`docs/cicd/`、当前部署/插件开发文档，以及 pinned harness 中与 Agent 指令、日志、profile、telemetry 相关的接口。没有逐行审查每个第三方插件的全部业务实现；第三方插件只检查其与 superproject 的安装、构建、挂载、日志和部署边界。

已执行并通过：

- `bash -n scripts/*.sh deploy/remote-install.sh`
- `node --check scripts/merge-profile-patch.mjs`
- `shellcheck -S style scripts/*.sh deploy/remote-install.sh`
- `make help`
- `git diff --check`
- 本地 submodule/gitlink/tag、递归 submodule 状态和 cached remote ref 对比

未执行：

- `scripts/check-pins.sh` 的联网 fetch 校验；
- `make setup` 全量重建和所有 submodule 测试；
- 真实 Linux x86-64 部署、回滚、并发部署、断网或磁盘故障注入；
- GitHub Actions、Gerrit、Jenkins、Nexus 或真实模型链路。

仓库自身也在 `scripts/deploy-remote.sh:4-6` 与 `docs/backlog.md:27` 明确记录：当前远程部署从未在真实服务器上端到端跑通。

## 3. 做得好的设计

### 3.1 Superproject 与 SCM 边界

- Gitlink SHA 能精确表达一次组合快照；第三方仓与自维护 fork 的边界在 ADR-0001 中定义清楚。
- submodule 默认 detached HEAD、插件仓独立发版、主仓只更新 pin 的分工是合理的，避免 superproject 越权管理各插件的 npm/tag 生命周期。
- tag pin 使用 `<tag>^{}` 兼容 annotated/lightweight tag，`scripts/check-pins.sh:83-100` 的实现正确。
- `.gitmodules` 当前 11 个顶层 submodule 与 `check-pins.sh --list` 的 11 项一致；本地 tag pin 均精确指向声明 tag。
- `dsh-tui` 独立 profile，不与 Web profile 混装，边界清楚。

### 3.2 Makefile 与脚本分层

- 根 Makefile 只有入口和用户可发现帮助，复杂逻辑放在脚本中，符合本地、CI 和未来 Jenkins 复用的方向。
- `pipefail + tee` 能保留退出码，避免流水线把前序脚本失败误判成成功。
- setup 对 macOS arm64/Linux x86-64 原生依赖、Corepack、lockfile 和 package manager 差异做了大量显式防御。
- 当前 shell/Node 脚本静态语法与 ShellCheck 均通过。

### 3.3 目标 CI/CD 与部署设计

- `docs/cicd/` 明确区分当前态与目标态，提出双平台原生构建、build once、同 digest 晋级、非 root 服务、原子 `current/previous`、部署锁和 version proof，方向正确。
- 测试策略覆盖 deterministic Mock、真实 DeepSeek 小集合、headless 与 Playwright 用户旅程，而不是只看端口或单元测试。
- 状态目录与应用 release 分离、回滚不覆盖新会话/附件，是必要的不变量。
- 安全、证据、RBAC、备份、RPO/RTO 和 break-glass 已有较完整的目标框架。

### 3.4 当前部署脚本最近的安全改进

- `DEPLOY_DIR` 已限制到 `/opt/<name>` 或 `/srv/<name>`，并在远端拒绝符号链接逃逸。
- 状态 `.dsh` 已从产物快照和回滚中排除。
- 多主机任一失败会回滚本批次已成功主机，避免长期混合版本。
- 新增 `.dsh-deployed` 标识后，健康检查至少能校验磁盘标识与预期主仓 SHA。

这些改进降低了 legacy 路径风险，但没有解决“部署输入不是已验证、不可变字节”和“运行进程版本无法证明”的根问题。

## 4. 主要发现

严重度定义：P0 = 启用生产前必须阻断；P1 = 进入稳定 staging/发布链前完成；P2 = 工程质量和维护性改进。

### P0-1：实际部署内容可能不等于 `HEAD`/gitlink 快照

**证据**

- `scripts/deploy-remote.sh:148-165` 直接从 `$ROOT/` 执行 rsync。
- `scripts/deploy-remote.sh:351-370` 没有根仓 clean/untracked 检查。
- `scripts/deploy-remote.sh:354-360` 使用非递归 `git submodule status`，且该命令只识别 gitlink checkout 偏离、未初始化和冲突，不证明 submodule 工作树内容干净。
- dsh-tui 当前包含 4 个 nested submodule；非递归检查无法覆盖它们。
- `scripts/deploy-remote.sh:104-107` 只用 `git rev-parse HEAD` 生成部署标识。

**影响**

未提交的根仓脚本、submodule 内修改、nested submodule 偏离、或者 `plugins/` 下额外的未跟踪包，都可能被扫描、构建、挂载并部署。落地标识仍显示主仓 `HEAD`，破坏审计与回滚判断。

**修改方案**

短期 containment：部署前拒绝根仓 tracked/untracked 变化；使用 `git submodule status --recursive`，并对每个递归 submodule 执行 `git status --porcelain --untracked-files=all`；将实际 gitlink 与 `git ls-tree HEAD` 核对。

推荐方案：不从工作树 rsync。由干净 checkout 生成 source manifest 和 staging tree，逐项复制 Git tracked 文件与递归 submodule 的精确 gitlink 内容，再对 staging tree 计算 digest。生产路径直接实施 `docs/cicd/03-artifact-and-release.md` 的不可变 Linux runtime bundle。

**验收**

- 任一根仓/submodule/nested submodule 修改或额外文件都会在远端写入前失败；
- 部署 manifest 能列出主仓、全部递归 submodule SHA 和整体 artifact digest；
- 服务器 version proof 与输入 digest 一致。

### P0-2：本地日志和任意未跟踪文件可能被同步到服务器

**证据**

- `Makefile:4-5` 把日志写入根 `log/`。
- `.gitignore:16-17` 只让 Git 忽略 `log/`，不影响 rsync。
- `scripts/deploy-remote.sh:148-152` 的 rsync exclude 没有 `log/`、`.env`、临时文件或 Git tracked allowlist。
- 本次审查时 `log/` 已有 44 个文件、约 5.2 MiB。

**影响**

本地开发日志、隧道 URL、错误栈、路径、未跟踪配置或误放凭据可能进入服务器应用目录和服务器快照。`.gitignore` 不能作为发布内容策略。

**修改方案**

立即把 `log/`、`.env*`、临时文件和本地 evidence 纳入拒绝/排除；但不要长期维护 exclude 黑名单。最终改为 manifest/allowlist 驱动的制品打包，并在上传前做 secret scan、绝对路径扫描和文件清单核对。

**验收**

- 在根仓、插件和 nested submodule 放置 canary untracked 文件，部署包中均不存在；
- `log/`、credential、session、attachment、Git object database 不在 artifact 中；
- artifact 文件清单可复现并受测试保护。

### P0-3：应用关键告警没有可见 exporter

**证据**

- pinned harness `vendor/cordis/src/logger.ts:195-221` 默认只注册一个内存 ring-buffer exporter。
- `harness/packages/experimental/webworker-runtime/src/worker-host.ts:289-300` 明确说明普通 profile 没有挂载 exporter，`ctx.logger.warn(...)` 不会输出。
- `harness/packages/bundle/base/cordis.patch.yml` 和 `web-app/cordis.patch.yml` 没有 `logger-console` 或其他 operational exporter。
- `plugins/dsh-automation/src/service.ts:360-453` 等关键 scheduler/admission/persistence failure 使用 `ctx.logger.warn(...)`。
- `deploy/dsh.service` 没有另行接入应用 logger；journald 只能捕获实际 stdout/stderr。

**影响**

自动化调度、清理、插件装载等失败可能只留在进程内存，服务重启后消失。当前 `make dev` 的 tee 日志和 `journalctl -u dsh` 都不能被视为完整应用日志。

**修改方案**

为正式 profile 挂载独立 operational logger exporter，至少把 warn/error 输出为无 ANSI 的 JSON Lines 到 stdout/stderr；生产由 journald/集中采集接管。不要把 session-telemetry exporter 当成 operational logger：它承载的是敏感 Session 事件，语义和权限完全不同。

**验收**

- 注入一个 `ctx.logger.warn` 和一个 Error 后，可在本地日志、journald 与集中平台按 event/logger 查询；
- exporter 异常不得阻塞主进程；
- 日志不包含 prompt、tool payload、credential 或真实用户正文；
- 对关键失败有自动化测试，证明消息不是只留在 ring buffer。

### P0-4：默认 session telemetry 与“敏感数据留内网”目标缺少部署决策

**证据**

- `harness/packages/bundle/base/cordis.patch.yml:168-196` 默认启用 `FEEDBACK_ONLY`，并把 OTLP URL 指向外部 `harness-telemetry.deepseeksvc.com`。
- `harness/packages/session/session-telemetry-otel/README.md` 说明，经用户反馈授权的前缀可包含消息、工具参数/结果、system prompt、todo、摘要和 cwd；部署方负责 redaction。
- 当前 `deploy/dsh.service` 没有设置 `DSH_TELEMETRY_DISABLED` 或内部 OTLP endpoint，也没有挂载部署侧 redaction rule。
- ADR-0004 要求源码、日志、evidence 和用户数据默认留在内网，新增外部日志/SaaS 需单独安全评审。

**影响**

普通活动不会自动上传，但用户一旦提交反馈，就可能触发包含内部路径或工作内容的 Session 前缀出网。当前生产模板与目标数据驻留原则之间缺少明确一致的默认值。

**修改方案**

内网 production 默认设置 `DSH_TELEMETRY_DISABLED=1`。如果业务决定保留反馈 telemetry，应新增 ADR，改发内部 OTLP collector，并在 exporter 前实现、测试和版本化 redaction；UI 中明确告知范围和接收方。

**验收**

- 默认 production 断言没有到外部 telemetry endpoint 的连接；
- 启用模式下，canary secret/prompt/path 经测试不会离开进程；
- telemetry 与 operational logs 使用不同 endpoint、schema、RBAC 和保留策略。

### P1-1：当前远程部署只适合验证，不具备生产发布原子性

**证据**

- 代码和文档已自标为 legacy、未端到端验证。
- rsync 和 `remote-install.sh` 直接改写 live `$DEPLOY_DIR`；旧服务在安装/构建期间仍引用同一目录。
- 全新机器失败没有 previous，可留下半安装目录。
- 没有部署锁，并发 deploy/rollback 会竞争同一目录和单一 snapshot。
- `rollback_one` 对重启使用 `systemctl restart dsh || true`，可能在服务未恢复时仍报告产物已回滚。
- systemd unit 没有 `User=`，服务以 root 运行；代码、状态和 profile 同处 `/opt/dsh`。
- HTTP 200/303/401 + 磁盘 SHA 不能证明运行进程加载的是新版本，脚本注释也承认这一点。

**修改方案**

不要继续把 legacy 路径逐步包装成生产系统。只做必要 containment 和一次隔离 staging E2E；生产直接实施目标 runbook：非 root `dsh`、`/opt/dsh/releases/<digest>`、`/var/lib/dsh`、host/environment lock、incoming 目录、离线 preflight、原子 symlink、进程 version proof、previous 回滚再健康检查。

### P1-2：branch pin 校验把“可追溯 pin”误写成“必须追最新 HEAD”

**证据**

- `scripts/check-pins.sh:63-80` 要求 pinned SHA 与 `origin/<branch>` 完全相等。
- 本地 cached refs 显示 `dsh-web` pin 落后 `origin/main` 231 个提交，`dsh-plugin-mineru` 落后 `origin/master` 7 个提交；`docs/backlog.md:25-26` 也记录了相同类型漂移。
- `verify.yaml:24-25` 对每个 push/PR 执行该等值校验。

**影响**

上游分支一推进，未改一行的 superproject 就会从“有效”变成“CI 必失败”；发布已验证旧组合前，团队被迫先吸收未评审的全部上游变化。这与 immutable gitlink 和可回滚旧版本的 SCM 目标冲突。

**修改方案**

把两种政策拆开：

- 合入/发布阻断规则：pin 必须是允许 remote/ref 可达的 commit，URL 在 allowlist，gitlink 精确；tag pin 继续精确等值。
- 新鲜度规则：scheduled drift report 计算 behind count、风险和 owner，创建更新 change，但不让上游移动使现有 commit 自动失效。

若某个仓确实要求“总是 branch HEAD”，必须在 machine-readable policy 中单独声明 `tracking: head`，不能把它作为所有 branch pin 的默认语义。

### P1-3：pin 清单仍不是真正完整的单一事实源

`scripts/check-pins.sh` 已让三条执行通路共享一份列表，这是改进；但列表本身仍手写，脚本没有断言 `.gitmodules` 的 path 集合与 pin policy 一一对应。新增 submodule 时如果忘记加入数组，它不会被校验或进入 release manifest。

同时 pin 版本又重复在 `AGENTS.md:9`、`README.md:27-34`、旧 spec 和插件开发文档中。`docs/plugin-dev.md:45` 仍要求手工修改已经被 `check-pins.sh` 取代的三个清单，证明文档已漂移。

建议建立 `config/submodules.yaml` 或同等 machine-readable manifest，包含 path、canonical URL、authority、pin kind、allowed ref、build/test adapter 和 owner；校验器断言它与 `.gitmodules`/gitlink 集合完全相等，文档表格自动生成或只链接该清单。

### P1-4：架构文档有双权威和当前/目标混淆

**证据**

- `AGENTS.md:3` 和 `README.md:3` 指向 `docs/superpowers/specs/` 下“最新 spec”。
- `docs/superpowers/specs/2026-09-08-dsh-superproject-design.md:4` 标为“已确认”，其远程方案仍是源码 rsync、目标机构建。
- `docs/cicd/README.md:13` 又声明 `docs/cicd/` 是 CI/CD 设计与实施事实源，并明确最终目标是不可变制品。
- `docs/deploy.md:36-49` 仍写 snapshot/rollback 包含 `.dsh`，而 `scripts/deploy-remote.sh:277-280`、`:219-221` 已排除 `.dsh`。

**影响**

人工维护者或 Agent 都可能选择错误文档，按旧语义评审、部署或修改脚本。ADR 自身清楚，但根入口没有把用户导向 ADR/当前状态矩阵。

**修改方案**

新增唯一架构入口，例如 `docs/architecture/README.md`：

- `current`：当前能执行什么、验证状态和已知限制；
- `target`：指向 `docs/cicd/`；
- `decision`：ADR；
- `history`：旧 spec、plans、reviews、backup，明确非规范；
- `status matrix`：P0-P6 每阶段 owner、状态、证据链接、下一 gate。

根 README/AGENTS 只链接该入口。旧 spec 顶部增加 Superseded/Baseline 标识，不删除历史。`docs/deploy.md` 必须与当前脚本同提交更新。

### P1-5：当前 CI/Release 不能证明“已测试发布快照”

- GitHub verify 只跑 pin、ShellCheck、构建、挂载和 HTTP readiness；`docs/backlog.md:31` 已承认没有运行任何 submodule 测试。
- 只有 Linux runner，不能覆盖声明支持的 macOS arm64 原生构建。
- 多个插件因 committed `main` 入口而跳过 build，当前门禁也不执行其源码/产物一致性或上游自测。
- `release.sh` 先推 tag，再由 tag workflow 重建；CI 失败时 tag 已发布，只是没有 GitHub Release。
- `release.sh:19-23` 只补 `v` 前缀，不校验 SemVer、main 可达性或 upstream；本次审查的本地 checkout 也没有 `origin`，当前 `make release` 在此环境必然拒绝。
- GitHub Actions 使用 mutable action tags；ShellCheck tarball 通过 `wget | tar` 下载但不校验 checksum。

建议在目标 Jenkins/Nexus 落地前，至少增加根 `make check`/`make test-smoke`，执行递归 source/pin contract、相关 submodule 自测和组合用户旅程；release tag 只能由受控 bot 在通过的 candidate/digest 上创建。GitHub Actions 固定 action commit SHA、工具 checksum、exact Node 版本、timeout 和失败 evidence 上传。

### P1-6：安装/挂载逻辑重复且依赖启发式规则

`scripts/setup.sh` 与 `deploy/remote-install.sh` 复制了 package manager、legacy pnpm、build policy、安装与构建选择；`link-plugins.sh` 与 remote installer 又复制候选发现和挂载逻辑。文件已分别达到约 222、427、208 行，后续修复很容易只改一份。

“入口已 tracked 就跳过 build”“未声明 build policy 就 `--ignore-scripts`”“扫描任意 `plugins/*/package.json`”都是基于当前插件集合的启发式规则，新插件可能静默走错路径。

建议把纯探测和 policy 读入共享脚本库，平台相关副作用仍保留在本地/远程入口；更稳妥的是让 machine-readable submodule manifest 显式声明 install/build/test/mount adapter，未知插件默认拒绝而不是猜测。

### P1-7：日志目标设计有字段，但缺少可执行协议

`docs/cicd/06-security-and-operations.md` 已给出保留期、字段、指标和告警，但尚未定义：

- operational、audit/deployment、session、telemetry 四类数据的明确分流；
- JSON schema/version、severity、event name/error code；
- logger/request/session/build/deployment correlation 传播方式；
- journald 与 `/var/log/dsh` 谁是 source of record；
- collector、缓冲/背压、断网行为、轮转和容量上限；
- redaction 在格式化前还是采集后执行，以及可测试规则；
- audit event 的不可篡改/append-only 实现；
- 告警去重、升级、恢复通知和 runbook 链接。

因此它是良好的 observability requirements 草案，还不是可落地的日志设计。

### P2-1：Makefile 入口合理，但缺少安全和工程目标

建议保留薄 Makefile，不把 bash 逻辑塞回 recipe。需要补齐：

- `doctor`：只读检查 OS/arch/Node/Corepack/工具/remote/hosts；
- `pins` 或 `manifest`：打印组合输入与 drift，不修改 submodule；
- `check`：静态检查、文档链接、manifest coverage、shell tests；
- `test-smoke`：根仓组合 smoke；
- `deploy-plan`：不联网、不写远端的确定性计划；
- `logs`/`clean-logs`：查询与受控保留；
- 目标 CI 需要的 `ci-*` 入口，但只能在实现后加入帮助。

具体问题：

- `Makefile:39` 的 `$(VERSION)` 未加引号，带 shell 元字符的 Make 变量会改变命令语义；应改为显式参数校验并安全传递。
- `dev` 帮助写“`--no-open` 可加”，recipe 实际已固定 `--no-open`，且没有参数通道。
- deploy 的 `--dry-run` 不能通过统一 Make 入口调用。
- 日志 recipe 重复，文件名使用本地时区、无 run ID，且同秒并发存在碰撞可能。

### P2-2：根 `AGENTS.md` 对 Agent 安全边界仍不够

当前优点是短、明确、不让 Agent随意跟随 submodule remote。但一条超长 pin 清单容易陈旧，“最新 spec”不确定，且缺少以下机器协作规则：

- 未经用户明确授权，不执行 deploy、release、tag、push、远程写入或生产操作；
- 修改前检查根仓和递归 submodule dirty 状态，保留无关改动；
- 根 AGENTS 管理 superproject/SCM，nested AGENTS 管理子仓代码；冲突时的优先级和允许修改范围；
- 不把 submodule `node_modules`/build output 跨平台复制；已有该规则，但应链接到可执行检查；
- 按改动类型给出最小验证矩阵和“已验证/未验证”报告格式；
- current/target/history 文档权威顺序。

建议 AGENTS 只保留稳定规则和精确链接，动态 pin/version 由 manifest 生成，不再手抄。

### P2-3：当前 raw log 生命周期不可控

Make 日志全部永久落在 ignored `log/`：没有最大文件大小、保留天数/数量、压缩、latest 指针、按 target/run/host 分割或 secret scan。CI 的 `/tmp/dsh.log` 只在 readiness 超时时 `cat`，没有统一 failure artifact。

建议本地日志默认保留 7-14 天或最近 N 次，失败日志保留更久；每次运行生成 UTC `RUN_ID` 和 summary JSON；原始日志与脱敏 evidence 分开；CI 无论失败阶段都上传最小 evidence，成功只保存摘要。

## 5. 建议的日志分层

| 数据流 | 内容 | 默认落点 | 敏感级别 | 保留建议 |
|---|---|---|---|---|
| Operational log | 启动、插件装载、scheduler、provider/网络/存储错误 | JSON stdout/stderr → journald → 内网 collector | 内部；禁止正文和 secret | production 30-90 天 |
| Deployment/audit event | 谁在何时对哪个 digest 做了 build/promote/deploy/rollback | append-only audit store + Nexus evidence | 内部/审计 | 长期或至少 1 年 |
| Session log | 模型可见事件、工具调用、消息与状态 | `/var/lib/dsh/sessions` | 机密业务数据 | 按业务数据策略 |
| Feedback telemetry | 用户显式授权的反馈相关 Session 前缀 | 默认禁用；如启用则内部 OTLP + redaction | 机密 | 独立审批和保留 |
| Local developer run | setup/dev/link/check 原始输出 | `log/<run-id>/` | 可能敏感 | 最近 N 次/7-14 天 |

Operational log 最小字段建议：

```text
schemaVersion timestamp level service component logger event errorCode
environment runId requestId sessionId buildId commit artifactSha256 deploymentId hostAlias
```

字段必须是 allowlist；默认不序列化任意 Error context、环境变量、请求 body、prompt、tool args/result 或用户路径。需要排障的详细敏感内容进入权限更高、短保留的 evidence，而不是常规服务日志。

## 6. 建议拆分给实施人员的任务包

以下任务包彼此边界清楚，可以分别派遣；P0 包应先于生产部署，目标制品链可以与 legacy containment 并行设计，但不得混用发布结论。

### R1：文档权威与 Agent 治理

**范围**：根 `AGENTS.md`、`README.md`、架构索引、旧 spec 状态、`docs/deploy.md`、`docs/plugin-dev.md`。

**交付**：唯一架构入口、current/target/history 状态矩阵、Agent 操作授权边界、去重后的 pin 导航、与当前脚本一致的 legacy runbook。

**验收**：根入口不存在“最新文档”歧义；旧文档有 Superseded/Baseline 标识；文档链接与关键事实门禁通过。

### R2：Submodule/SCM manifest 与 pin policy

**范围**：machine-readable submodule manifest、`.gitmodules` coverage、递归 gitlink/source/dirty 校验、branch freshness report。

**交付**：一个 manifest；一个阻断式 source validator；一个非阻断 drift reporter；release source manifest 生成器。

**验收**：新增/删除/重复/未知 submodule 均失败；旧但允许 ref 可达的 branch pin 不因上游推进而失败；tag pin 必须精确相等。

### R3：Legacy deploy containment

**范围**：只降低当前验证路径风险，不宣称生产化。

**交付**：clean/recursive guard、tracked staging tree、敏感文件拒绝、部署锁、失败时真实回滚验证、每主机 summary、与脚本同步的文档。

**验收**：dirty/untracked/nested 偏离、并发、首装失败、重启失败、磁盘满、健康超时都有自动测试或受控故障注入证据。

### R4：不可变制品与生产部署

**范围**：实施 ADR-0002 和目标 runbook，不复用 live source build。

**交付**：Linux runtime bundle、source/release manifest、checksum/signature、Nexus lifecycle、非 root systemd、原子 release、version proof、schema migration contract。

**验收**：staging/production 同 digest；生产无 Node/package manager/compiler 也能启动；失败 5 分钟内回到健康 previous；状态不回滚。

### R5：根仓测试与 Release gate

**范围**：根 `make check/test-smoke`、相关 submodule tests、双平台门禁、candidate catalog、tag 权限。

**交付**：最小 presubmit、完整 candidate 回归、macOS arm64 lane、失败 evidence、bot-only release tag。

**验收**：required missing/skip/flaky-green 均阻断；每个随发布插件至少一条用户旅程；tag 只在 production proof 后创建。

### R6：Operational logging

**范围**：Cordis logger exporter、JSON schema、systemd/journald、关联 ID、redaction、集中采集、告警。

**交付**：正式 profile exporter、日志契约、collector 配置、rotation/retention、secret canary tests、关键错误告警与 runbook。

**验收**：`ctx.logger.warn/error` 可查询；普通日志没有敏感正文；collector 不可用不阻塞服务；deploymentId 能贯穿 Jenkins、部署和主机日志。

### R7：Telemetry 数据驻留

**范围**：feedback telemetry 与 operational logging 分离。

**交付**：production 默认禁用；或经新 ADR 批准的内部 OTLP/redaction/consent/retention 实现。

**验收**：默认无外部 telemetry 流量；启用时 canary secret 永不出网；配置与审计证据可追溯。

### R8：Makefile UX 与本地日志

**范围**：不改变薄入口原则。

**交付**：安全参数传递、doctor/check/pins/deploy-plan/logs targets、统一 logged runner、UTC run ID、清理策略。

**验收**：`make help` 与实际参数一致；带特殊字符的 VERSION 被拒绝而非解释为 shell；并发日志不碰撞；清理有 dry-run。

## 7. 推荐实施顺序

1. 立即完成 R1、R2、R6、R7，并冻结 `make deploy` 的生产用途。
2. 完成 R3，只把 legacy 路径提升到“可重复的 staging 验证工具”。
3. 并行推进 R5 与 R4；先有可验证 candidate，再开放 production deploy。
4. R8 随 R2/R3/R6 一起收口，避免重复造 runner 和日志协议。
5. 达到 `docs/cicd/01-architecture.md` 的 P0-P5 证据后，才把根文档中的状态改为 production-ready。

## 8. 最终意见

不建议推翻现有 superproject 或薄 Makefile 设计；真正需要改变的是“事实源、发布输入和可观测性”。目标 CI/CD 文档已经给出了大部分正确方向，最有效的路线是：先消除双权威和不可见日志，堵住工作树直传的风险，再尽快从目标机现场构建迁移到不可变制品部署。

在完成 P0 项和至少一次受控 Linux staging 端到端演练前，`make deploy` 应继续明确标注为 legacy/validation-only，不能作为生产发布依据。
