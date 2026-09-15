# AGENTS.md — dsh 超级仓库

本仓库是 DeepSeek Harness（DSH）超级仓库（superproject），以 git submodule 管理 `harness/` 与
`plugins/*`，自身承载环境搭建、部署、发布快照与插件开发。

> **本文件只写稳定的仓库级约束。** 会漂移的事实（pin 版本、组件清单、分支名）不在这里复制——
> 它们的事实源是 [config/components.json](config/components.json)，并由
> `node scripts/check-components.mjs` 与 `.gitmodules` 做双向校验。

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

## 硬约束

- **从超级仓根目录启动集成任务。** `harness/` 下有多层嵌套 `AGENTS.md`（上游内容），
  从子目录启动会让指令链被截断或与超级仓规则叠加。
- **目标平台**：本地 macOS M4（arm64）；服务器 Linux（Ubuntu）x86-64。
  **原生 Node 依赖必须按平台各自构建，严禁跨平台拷贝 `node_modules`**。
- **原生构建**：harness 的 `pnpm build` 先跑 `build:native-system`，需要 C 编译器与 Node
  开发头文件；其产物（`native/system/packages/*/bin/`）已 gitignore，各平台各自构建。
- **插件安装位置**：`plugins/`（submodule 引入）；目标目录不存在时脚本必须 `mkdir -p`。
- **不修改 submodule 的内容**：`harness/` 与 `plugins/*` 是上游（或本仓 fork）的 pin。
  确有本仓特有的适配时走 fork + 分支 pin（先例：`dsh-automation`），并在组件目录把
  `sourceAuthority` 标为 `gerrit-fork`。**不要为了注入超级仓规则去改子模块的
  `AGENTS.md`。**
- **插件仓的发版**（npm publish / tag）由插件仓自行完成，本仓库不越界编排。

## 工作流

- 统一入口是 `Makefile`（薄入口），实际逻辑在 `scripts/*.sh`。
- 本地：`make setup` / `make dev` / `make dev-tui`；部署：`make deploy`；发布：`make release`。
- 部署是**显式动作、不上 CI**。⚠️ 当前 `make deploy` 为**非生产（legacy）**——
  该路径从未端到端跑通过，详见脚本头部与 [docs/backlog.md](docs/backlog.md)。
- submodule 的 detached HEAD 是特性；**更新 pin 是显式动作**，不要随手拉到远端最新。
- **改了 pin 必须同步 [config/components.json](config/components.json)**，否则 CI 第一步
  （双向校验）就会失败——这是有意的：漏登记一个组件会让它在 CI 里静默消失。

## 改动区域 → 必须跑什么

| 改动区域 | 必须做 |
| --- | --- |
| `scripts/*.sh`、`deploy/*` | `shellcheck -S style scripts/*.sh deploy/remote-install.sh` 全绿（CI 固定 0.11.0） |
| `config/components.json` / `.gitmodules` | `node scripts/check-components.mjs` + `bash scripts/check-pins.sh`；**改了组件集合或 `license` 还要** `node scripts/gen-notices.mjs`（声明文件是**合规文档**，`--check` 会拒绝过期内容） |
| `patches/*.yml` | `make link-plugins` 后 `dsh --profile dsh --dump-config`，确认没有 patch 抹掉旁键 |
| `.github/workflows/*` | Action **pin 到 commit SHA** 并注明版本；下载第三方产物必须校验 checksum |
| `docs/cicd/*` | 它是 CI/CD 规范源；改动须说明影响的阶段/Job/脚本/凭据/回滚路径 |

## Review 时重点看什么

- **是否引入了未受信任输入可触达的凭据或受信执行路径**（presubmit 尤其）；
- **是否修改了 submodule 内容**（除非走 fork 流程并登记）；
- **是否让 pin / 组件集合失去一致性**；
- **是否允许 Patchset 自定义受信流水线**（不允许：流水线骨架与 Shared Library 必须来自
  受保护的基础设施仓库或固定受信 ref，见 [docs/cicd/02-gerrit-and-jenkins.md](docs/cicd/02-gerrit-and-jenkins.md)）。

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
