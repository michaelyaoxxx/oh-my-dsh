# AGENTS.md — dsh 超级仓库

本仓库是 DeepSeek Harness（DSH）超级仓库（superproject），以 git submodule 管理 `harness/`
（DSH 内核）与 `plugins/*`（插件），自身承载环境搭建、部署、发布快照与插件 pin。
**本仓基本不含产品代码**——产品代码在 submodule 里，本仓自己的代码是 `Makefile`（薄入口）、
`scripts/`（编排与门禁脚本，bash + Node `.mjs`）、`deploy/`、`patches/`、`config/`、`docs/`。

> **本文件只写稳定的仓库级约束。** 会漂移的事实（pin 版本、组件清单、分支名）不在这里复制——
> 它们的事实源是 [config/components.json](config/components.json)（字段语义见
> [config/README.md](config/README.md)），并由 `node scripts/check-components.mjs` 与
> `.gitmodules` 做双向校验。

## 权威入口

| 想知道什么 | 看哪 |
| --- | --- |
| **CI/CD 设计与实施规范** | [docs/cicd/README.md](docs/cicd/README.md)（Gerrit + Jenkins + Nexus） |
| **谁是组件、pin 在哪、谁进制品** | [config/components.json](config/components.json) |
| 当前仓库结构与文档索引 | [README.md](README.md) |
| 插件开发与常见问题（**改脚本前必读**） | [docs/plugin-dev.md](docs/plugin-dev.md) |
| 部署手册 / 远程访问 | [docs/deploy.md](docs/deploy.md) / [docs/remote-access.md](docs/remote-access.md) |
| 未收口事项（还欠什么） | [docs/backlog.md](docs/backlog.md) |
| **整改项状态与证据（T×R 台账，做过什么）** | [docs/remediation-plan.md](docs/remediation-plan.md) |
| 贡献流程与安全策略 | [CONTRIBUTING.md](CONTRIBUTING.md) / [SECURITY.md](SECURITY.md) |

`docs/superpowers/specs/` 下的旧设计文档已标注**历史、非权威**，不得作为实施依据。

## 技术栈与运行时架构

- **工具链**：Node.js `^22.19 || >=24`（**需含开发头文件**，部分发行版要另装
  `nodejs-dev` / `node-headers`）、C 编译器（`cc`，构建原生插件用）、corepack。
  **不依赖全局 pnpm**——每个子仓按其 `package.json` 的 `packageManager` 字段由 corepack
  解析各自 pin 的 pnpm（harness 当前 pin `pnpm@11.7.0`）。`dsh-market` 只有
  `package-lock.json`，`setup.sh` 对它自动走 `npm ci`。
- **harness（submodule）**：pnpm workspace monorepo（`apps/*`、`packages/*/*`、
  `native/system` 等），上游用 vitest / tsdown / oxlint / tsx。`pnpm build` 先跑
  `build:native-system` 为本机平台编译 Node-API 原生插件（flock）。
- **本仓脚本**：bash（`scripts/*.sh`，受 shellcheck 门禁）+ Node `.mjs`
  （**一律用 `node` 跑，用 bash 跑 .mjs 会以退出码 2 失败**）。本仓根目录没有
  `package.json`，`.mjs` 脚本只用 Node 标准库。
- **运行时**：`make dev` 先把可挂载的 `plugins/*` 以 link 挂进 profile `dsh`（
  `scripts/link-plugins.sh`，patch 合并逻辑在 `scripts/merge-profile-patch.mjs`），
  再启动 DSH Web，默认监听 `http://127.0.0.1:3080`（仅回环）；运行时主目录
  `$DSH_HOME=./.dsh`（gitignore）。TUI 是独立 profile `tui`（见下方「TUI 不是当前重点」）。
- **插件配置基线**：`config/plugin-configs/`，seed/save 统一入口
  `scripts/save-settings.mjs`（`make seed-configs` / `make save-settings`），详见
  [docs/plugin-dev.md](docs/plugin-dev.md)。

## 硬约束

- **从超级仓根目录启动集成任务。** `harness/` 下有多层嵌套 `AGENTS.md`（上游内容），
  从子目录启动会让指令链被截断或与超级仓规则叠加。
- **目标平台**：本地开发支持 macOS M4（arm64）与 Linux（Ubuntu）x86-64（后者 2026-09-15 已
  完整闭环验证：setup / link / 冒烟 / `make check` 全绿）；服务器 Linux（Ubuntu）x86-64。
  **原生 Node 依赖必须按平台各自构建，严禁跨平台拷贝 `node_modules`**。
- **原生构建**：harness 的 `pnpm build` 先跑 `build:native-system`，需要 C 编译器与 Node
  开发头文件；其产物（`native/system/packages/*/bin/`）已 gitignore，各平台各自构建。
- **插件安装位置**：`plugins/`（submodule 引入）；目标目录不存在时脚本必须 `mkdir -p`。
- **不修改 submodule 的内容**：`harness/` 与 `plugins/*` 是上游（或本仓 fork）的 pin。
  确有本仓特有的适配时走 fork + 分支 pin（先例：`dsh-automation`），并在组件目录把
  `sourceAuthority` 标为 `gerrit-fork`。**不要为了注入超级仓规则去改子模块的
  `AGENTS.md`。**
- **插件仓的发版**（npm publish / tag）由插件仓自行完成，本仓库不越界编排。

## 工作流（构建 / 运行 / 发布）

统一入口是 `Makefile`（薄入口），实际逻辑在 `scripts/*.sh`。全部目标见 `make help`。

| 命令 | 作用 |
| --- | --- |
| `make setup` | 一键搭建：工具链校验 → 拉 submodule → harness 构建 → 插件依赖（幂等） |
| `make check` | **本地自检基线**（见下节） |
| `make dev` | 启动 DSH Web（link 插件 → 起服务；依赖 harness 已构建，首次先 `make setup`） |
| `make dev-tui` | 启动 DSH TUI（备选交互，需真 TTY；默认不测试，见下） |
| `make link-plugins` / `make seed-configs` / `make save-settings` | 插件挂载 / 配置基线 seed / 回存 |
| `make deploy` | 部署到远程（读 `deploy/hosts`）。⚠️ **非生产（legacy），从未端到端跑通过**，见脚本头部与 [docs/backlog.md](docs/backlog.md) |
| `make release VERSION=v0.1.0` | 校验 pin → 打 tag → push（发布快照；**需显式授权**，见下） |

- 部署是**显式动作、不上 CI**。
- submodule 的 detached HEAD 是特性；**更新 pin 是显式动作**，不要随手拉到远端最新。
- **改了 pin 必须同步 [config/components.json](config/components.json)**，否则 CI 第一步
  （双向校验）就会失败——这是有意的：漏登记一个组件会让它在 CI 里静默消失。
- make 日志落盘在 `log/`（gitignore），每次调用按 UTC 时间戳 + PID 区分。

## 测试与自检

**基线是 `make check`**——它跑完整个自检清单，清单的单一事实源是
[`scripts/check-all.sh`](scripts/check-all.sh)（`--list` 可列出）；CI 的 step 0 调同一条
命令的 `--offline`。当前清单：

- **离线组**（不联网、不依赖构建，最先失败）：组件目录双向校验（`check-components.mjs`）、
  组件许可证内容检查（`check-licenses.mjs`）、第三方声明未过期（`gen-notices.mjs --check`）、
  许可证门禁回归（`probe-license-gate.sh --strict`）、组件目录校验回归
  （`probe-catalog.sh --strict`）；
- **联网/工具链组**：submodule pin 校验（`check-pins.sh`，需联网 fetch）、
  `shellcheck -S style scripts/*.sh deploy/remote-install.sh`（本地用已装版本，缺失则跳过；
  CI 固定 0.9.0）。

**改完先跑 `make check`**。`make setup` 不是它的前置——离线组在 setup 之前就能跑。

组件自身的测试（harness 与各插件）**不在本仓跑**：怎么测记录在各组件的 `testProfile`
字段（多为 vitest；`dsh-agent-teams` 无 test 脚本、覆盖在 `verify:*` 系列），由组件仓
自己与 CI 执行。注意 catalog 里 `ciScope` / `testProfile` 等是 **declared 字段**——
记录意图，**没有东西读它做决定**（字段三分类见 [config/README.md](config/README.md)）。

### CI/CD 载体

CI/CD 的载体是 **Gerrit（评审 + 门禁）+ Jenkins（构建 / 部署）+ Nexus（制品）**，
设计与实施规范见 [docs/cicd/README.md](docs/cicd/README.md)。
**`.github/workflows/` 只是开源后的预留通路**（现有 `verify.yaml`：pin 校验 + 冒烟；
`release.yaml`：tag → GitHub Release），不是当前主链。

**默认不修改 `.github/workflows/`。** 例外只有两类：

1. **供应链安全修复**（Action 钉 commit SHA、下载第三方产物校 checksum）；
2. **把新的校验挂到门禁上**——校验逻辑本身写在 `scripts/`，workflow 只负责调用。

**任何「在 workflow 里写新逻辑」的改动一律拒绝**：那不是例外，是走错了地方，改写到 `scripts/`。

> 这条界线的理由：只要 workflow 里还有内联逻辑，就必然需要改，「默认不改」会被自己击穿。
> 当前 `verify.yaml` 仍有**两处内联**（shellcheck 下载 + checksum、冒烟 curl 轮询），
> 是这条政策的不稳定点——理想是把它们也搬进 `scripts/`。
>
> **范围**：只管**本仓**的 `.github/workflows/`。submodule 各自的 GitHub Actions
> 是它们自己的事，本仓不干预。

### TUI 不是当前重点

`make dev-tui` 与 `plugins/dsh-tui` 只是**备选交互方式**，默认**不做功能性测试、不做功能修改**
（组件目录里它已是 `ciScope: ["metadata"]` / `releaseScope: []` / `runtimeScope: "excluded"`）。

⚠️ **代价要知道**：它不构建、不测试、不挂载，**坏掉时没有任何信号**——
别把「它没报错」当成「它还能用」。

⚠️ **范围**：`scripts/link-tui.sh` 在 `scripts/` 下，**仍受 shellcheck 门禁覆盖**。
「不修改」指不做功能开发与测试，**不是**「CI 报错也不修」。
报上游缺陷（如 [docs/backlog.md](docs/backlog.md) B6）不受此限。

## 改动区域 → 必须跑什么

下表只列 `make check` 基线**之外**的额外要求。

| 改动区域 | 必须做（额外的） |
| --- | --- |
| `scripts/*.sh`、`deploy/*` | `shellcheck -S style scripts/*.sh deploy/remote-install.sh` 全绿（CI 固定 0.9.0） |
| `config/components.json` / `.gitmodules` | 改了**组件集合或 license** 时**先** `node scripts/gen-notices.mjs` 重新生成声明文件——它是**合规文档**，不改就会让 `make check` 的 `--check` 失败（有意的） |
| `scripts/check-licenses.mjs`（许可证门禁逻辑本身） | ⚠️ 改了判定逻辑就**必须**跑 `bash scripts/probe-license-gate.sh` 确认覆盖边界没退化——它是这道门的**回归基线**（人读用默认模式；`make check` 已用 `--strict` 把它纳入，不符即失败） |
| `scripts/check-components.mjs`（目录校验逻辑本身） | 同上，回归基线是 `bash scripts/probe-catalog.sh`（每条规则都有会失败的样本）。⚠️ 探针防不住**蓄意**攻击者：能改门禁的人也能改探针，真正的解法是门禁脚本从受信 ref 取 |
| `patches/*.yml` | `make link-plugins` 后 `dsh --profile dsh --dump-config`，确认没有 patch 抹掉旁键（整表替换语义，见 plugin-dev.md） |
| `.github/workflows/*`（**默认不改**，仅上方「CI/CD 载体」列的两类例外） | 例外改动时：Action **pin 到 commit SHA** 并注明版本；下载第三方产物必须校验 checksum |
| `docs/cicd/*` | 它是 CI/CD 规范源；改动须说明影响的阶段/Job/脚本/凭据/回滚路径 |

## 代码与脚本风格约定

- **注释用中文**，且大量记录「为什么」与历史踩坑（含实测证据与日期）——这是本仓的
  刻意风格，新写脚本保持同样密度；改行为时同步更新注释，别留下描述旧行为的注释。
- bash 脚本开头 `set -euo pipefail`（或刻意不用 `-e` 时在注释里说明理由）；
  落盘日志用 `set -o pipefail … | tee log/…`。
- Make recipe 里**绝不写 `$(VERSION)` 这类会插值进 shell 文本的用户输入**——
  走环境变量（`$$VAR`）传值，权威校验放脚本里。Makefile 头部有实测过的注入教训。
- 写文档/判据时**引用符号（函数名）而非行号**——行号会漂且没有信号
  （`config/README.md` 与 `probe-catalog.sh` 都立过这条规矩）。

## Review 时重点看什么（安全）

- **是否引入了未受信任输入可触达的凭据或受信执行路径**（presubmit 尤其）；
- **是否修改了 submodule 内容**（除非走 fork 流程并登记）；
- **是否让 pin / 组件集合失去一致性**；
- **是否允许 Patchset 自定义受信流水线**（不允许：流水线骨架与 Shared Library 必须来自
  受保护的基础设施仓库或固定受信 ref，见 [docs/cicd/02-gerrit-and-jenkins.md](docs/cicd/02-gerrit-and-jenkins.md)）。
- 本仓**不接纳 copyleft 组件**（AGPL / GPL / LGPL），由 `check-components.mjs` 的
  许可证受控词表机器强制，登记即被拒。理由见 [docs/cicd/03-artifact-and-release.md](docs/cicd/03-artifact-and-release.md) §3.3。

## 操作授权边界

以下动作**必须由用户显式授权**后才执行，不得因为「顺手」或「显然该做」而自行发起：

- `make deploy`（默认对远端执行 `rsync --delete`，误配不可逆）；
- `make release`、`git push`、打 tag；
- 任何远程写入、生产操作、或对非本机环境的改动；
- 在目标机上安装软件、改 systemd、写系统路径。

**动手前先看脏没脏**：根仓 `git status --porcelain`，以及
`git submodule foreach --recursive 'git status --porcelain'`。发现与本任务无关的
改动要**原样保留**，不要顺手提交、还原或清理——那是别人的工作区。

## 验证报告格式

报告改动结果时**必须区分已验证与未验证**，并附证据：

```text
已验证：<实际跑过的命令> → <结果/退出码>
未验证：<事项>（原因：<缺什么条件>）
```

**禁止**把「推断」「按设计应该成立」「上次跑过」写成「已验证」。本仓有过声称
「Linux 绿」而从未在 Linux 上跑过的先例；也有过拿 `createRequire` 反推运行期
解析、差点删掉一个可用修复的先例。**推断就写推断。**

## Git 约定

- 主仓默认分支 `main`。
- commit message **不加任何 AI 署名**（包括 `Co-Authored-By: Claude Code`）。
- 提交按逻辑单元切分（pin / scripts / ci / docs 分开）。
- ⚠️ **不要用双引号包裹含反引号的提交信息**。`git commit -m "…\`cmd\`…"` 里的反引号
  是 **shell 命令替换**，会被**真的执行**：输出混进终端（看起来像"莫名其妙的报错"），
  而提交信息里留下**空洞**。本仓实际踩过两次——`` `ln -sfn` ``（报 usage）与
  `` `bash scripts/check-components.mjs` ``（报一堆 //: is a directory），都被误判成
  工具链问题查了很久。**用 `git commit -F <文件>` 或 `<<'EOF'` heredoc。**
- ⚠️ **`git commit` 提交的是整个索引，不是你刚 `git add` 的那个文件。** 本仓用 submodule，
  而 **`git submodule add` 会自动把 `.gitmodules` 与 gitlink 放进暂存区**（之后很可能一直
  留在那里，因为登记组件时还要改 `config/components.json`，那份是未暂存的）。
  于是**任何一次裸 `git commit` 都会把别人没提交完的 submodule 改动卷进来**——
  本仓实际踩过一次：一个只改文档的提交里混进了 `.gitmodules` 与 gitlink，
  而 catalog 的对应登记**没**进来，那个提交的**双向校验必然失败**（fresh clone 上 CI 第一步就红）。

  两条防线，**提交前都做**：

  ```bash
  git diff --cached --name-only            # 只应出现你自己的文件
  git commit --only <file1> <file2> -F -   # 只提交列出的路径，不动别人的暂存状态
  ```

  `--only` 是关键：它按**工作区内容**提交指定路径、**忽略索引里别人的东西**，
  且提交后别人的暂存状态原封不动。❌ **不要用 `git reset` 去"清理"索引**——
  那会动到别人的工作区，而本仓明确要求无关改动原样保留。

## 许可

本仓自身（`Makefile`、`scripts/`、`deploy/`、`patches/`、`config/`、`docs/`、`.github/`）
以 **Apache License 2.0** 授权（[LICENSE](LICENSE)）。`harness/` 与 `plugins/*` 各自携带
自己的许可证，不受本仓 LICENSE 覆盖；组件级清单见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)（**自动生成，勿手改**——由
`node scripts/gen-notices.mjs` 生成）。
