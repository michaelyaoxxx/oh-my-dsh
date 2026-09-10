# dsh 超级仓库设计

- 日期：2026-09-08
- 状态：已确认（2026-09-08，五节逐节确认）

## 1. 背景与目标

以 `/Users/michaelyao/workspace/dsh` 为 git 超级仓库（superproject），以 submodule 方式管理 DeepSeek Harness（DSH）主仓库与插件仓库。主仓承载 DSH 的环境搭建、部署、发布快照与插件开发编排。

- 主仓：GitHub 私有仓 `dsh`，默认分支 `main`
- 子仓（submodule，固定 commit）：
  - `harness/` ← [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)，稳定分支 `master`
  - `plugins/dsh-web/` ← [zhu1090093659/dsh-web](https://github.com/zhu1090093659/dsh-web)，稳定分支 `main`（注意：该仓默认分支为 `dev`，稳定分支是 `main`）
  - `plugins/dsh-better-sidebar/` ← [omdsh-dev/DSH-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar)，正式 tag `v0.18.1`（tag pin：pin 正式发布 tag 而非分支 HEAD）
  - `plugins/dsh-plugin-mineru/` ← [HuanLinOTO/dsh-plugin-mineru](https://github.com/HuanLinOTO/dsh-plugin-mineru)，稳定分支 `master`
- 后续插件仓一律以 submodule 加入 `plugins/<name>/`

### 目标平台（硬约束）

- 本地开发机：macOS + Apple Silicon（M4，arm64）
- 远程部署机：Linux(ubuntu) + x86-64

两平台架构不同：**原生 Node 依赖必须按平台各自构建，严禁跨平台拷贝 `node_modules`**。服务器侧构建必须使用 `pnpm install --frozen-lockfile`。

### 插件安装位置约定（硬约束）

插件默认安装在主仓 `plugins/` 目录下。若 `plugins/` 或目标目录不存在，脚本必须自动创建（`mkdir -p`），不允许因目录缺失而失败。setup/deploy 脚本在全新环境必须幂等可用。

### DSH 运行目录（已定死，依据 harness 官方源码查证）

- **DSH 主目录（home）**：默认 `~/.dsh`，可用 `$DSH_HOME` 环境变量覆盖；所有用户数据（配置、profile、已安装插件）都在此根下（`packages/util/home-paths/src/index.ts`）。
- **Profile**：`$DSH_HOME/profiles/<name>/`，内含 `package.json`（插件依赖 + `dsh.profile.bundles` 清单）、`cordis.patch.yml`（用户 patch 层）与 pnpm 管理的 `node_modules`（`packages/boot/app-boot/src/profile.ts`）。
- **可运行插件安装位置**：`dsh plugin --profile <name> add <pkg>` 在 profile 目录内执行 pnpm，插件作为依赖装入 `$DSH_HOME/profiles/<name>/node_modules/<pkg>`。
- **本仓约定**：本地与服务器都通过 `$DSH_HOME` 把 DSH 主目录指到本仓 `.dsh/`（gitignore），即插件实际落在 `dsh/.dsh/profiles/dsh/node_modules/<pkg>`——满足"插件默认安装在该文件夹下"。profile 名固定为 `dsh`。

### 非目标（Non-goals）

- 不编排插件仓的发版（npm publish、插件仓 tag 由插件仓按其现有机制自行完成）
- 部署不上 CI 自动触发；`make deploy` 是显式动作（后续需要再加）
- 不引入 Docker 作为环境载体

## 2. 目录结构

```
dsh/                          # 主仓 (superproject, GitHub 私有仓 dsh)
├── .gitmodules
├── .gitignore                # 含 .dsh/、deploy/hosts
├── .dsh/                     # DSH 运行主目录（$DSH_HOME 指向此处，gitignore，运行时生成）
│   └── profiles/dsh/         #   固定 profile：package.json + cordis.patch.yml + node_modules/（可运行插件在此）
├── README.md                 # 总体说明 + 快速上手
├── Makefile                  # 统一入口：setup / dev / deploy / release（薄入口，~20 行）
├── harness/                  # [submodule] deepseek-ai/deepseek-harness，pin master
├── plugins/
│   ├── dsh-web/              # [submodule] zhu1090093659/dsh-web，pin main
│   ├── dsh-better-sidebar/   # [submodule] omdsh-dev/DSH-better-sidebar，pin tag v0.18.1
│   └── dsh-plugin-mineru/    # [submodule] HuanLinOTO/dsh-plugin-mineru，pin master
├── scripts/                  # 具体实现脚本（Makefile 是薄入口）
│   ├── setup.sh              # 拉取/更新 submodule + 安装 Node 依赖
│   ├── link-plugins.sh       # 把 plugins/* 挂载进 DSH profile（开发模式）
│   ├── deploy-remote.sh      # 部署到远程服务器（systemd 管理）
│   └── release.sh            # 校验 pin → 打 tag → 推送
├── deploy/
│   ├── dsh.service           # systemd unit
│   ├── remote-install.sh     # 随源码同步到服务器，在服务器侧执行安装
│   └── hosts.example         # 服务器清单模板（真实清单 hosts 被 gitignore）
├── docs/
│   ├── deploy.md             # 部署手册
│   ├── plugin-dev.md         # 插件开发指南
│   └── superpowers/specs/    # 设计文档
└── .github/workflows/
    ├── verify.yaml           # push/PR：pin 一致性校验 + setup 冒烟
    └── release.yaml          # tag：干净构建验证通过后创建 GitHub Release
```

## 3. 环境搭建（本地 macOS M4）

- **运行方式选源码**：harness 本身就是 submodule 源码，本地直接 `pnpm install && pnpm build` 后 `pnpm dsh --profile dsh` 运行——与 pin 的 commit 严格一致，并为插件联调提供源码。harness 的 `dsh web` 是 `--profile web` 硬编码别名（boot 官方模板 profile，非本仓挂载目标）；超级仓库统一显式 boot 挂载目标 profile `dsh`（bundles = base + 官方 web 宿主 `@deepseek-ai/dsh-web-app` + 本仓插件，宿主由 link-plugins 幂等 ensure）。
- `make setup`：
  1. `git submodule update --init --recursive`（对每个插件目录先 `mkdir -p`）
  2. harness：按 harness 仓库 README 安装依赖并构建（pnpm）
  3. 各插件：安装依赖并构建。pnpm 按插件仓 `packageManager` 字段解析；未声明该字段的仓（如 dsh-plugin-mineru）经 harness 目录解析 harness pin 的 pnpm（`pnpm --dir`），避免 corepack 向上找不到 pin 而回落 latest。根 `main` 入口已提交在仓内的插件自带构建产物（pin 的一部分），跳过构建——本地重建会因绝对路径派生的产物哈希与 pin 不一致而弄脏 submodule；入口未提交的单包仓与 workspace 根才构建。服务器侧同机制，且强制 `--frozen-lockfile`。
- `make dev`：以 `$DSH_HOME=./.dsh` 启动 DSH Web（默认 `http://127.0.0.1:3080`，支持 `--no-open`），并先经 `link-plugins.sh` 把 `plugins/*` 的包以 link 模式挂进 profile `dsh`（`dsh plugin --profile dsh add link:...`），改插件源码即时生效。link-plugins.sh 另做三项幂等维护：根目录独立单包仓（外部插件，如 dsh-better-sidebar）豁免「被聚合包依赖即跳过」、单独挂载源码版本；`patches/*.yml`（repo 版用户 patch 片段，如 disable web-ui-better-sidebar）由 `scripts/merge-profile-patch.mjs` 托管合并进 profile 的 cordis.patch.yml；确保官方 web 宿主 bundle 在 bundles 中（base 之后）。
- Node 版本：以 harness 与插件仓各自的 `package.json` engines / README 为准，`setup.sh` 前置校验版本。

## 4. 远程部署（Linux x86-64）

`make deploy`（本地 Mac 发起）→ `scripts/deploy-remote.sh`：

1. **前置检查**：服务器需有 Node.js（`^22.19 || >=24`，带 corepack）与 systemd；pnpm 无需预装（corepack 按各仓库 `packageManager` 字段解析 pin 版本），git 亦不需要（rsync 同步不依赖服务器侧 git）；读 `deploy/hosts`（真实服务器清单，gitignore，仓库只留 `hosts.example`）。
2. **同步源码**：rsync 主仓（含 submodule 检出内容）到服务器工作目录 `$DEPLOY_DIR`（环境变量指定，默认 `/opt/dsh`），按 pin 的内容整体同步。
3. **服务器侧构建**：随源码同步过去的 `deploy/remote-install.sh` 在服务器上执行：`mkdir -p` 插件目录 → harness `pnpm install --frozen-lockfile` + build → 插件按 pin 从各自仓库构建后经 `dsh plugin --profile dsh add` 装进 `$DSH_HOME/profiles/dsh/node_modules/`（服务器上 `$DSH_HOME=$DEPLOY_DIR/.dsh`，**不跨平台拷贝 node_modules**）。
4. **服务接管**：安装/更新 `dsh.service`（systemd unit）→ `daemon-reload` → `restart`。
5. **健康检查**：在服务器本机轮询 `http://127.0.0.1:3080`（harness 只绑定回环地址），HTTP 状态码 `200/303/401` 均视为通过——未认证请求 harness 返回 `401`（浏览器 token flow 是唯一认证路径，`401` = 认证 gate 在响应 = 服务已就绪）；连接失败或其他状态码不通过。通过才算成功；失败回滚到上一次产物并报错。

要点：

- **幂等**：脚本可重复执行，全新机器与增量更新同一路径。
- **可回滚**：服务器保留上一版本产物目录，部署前快照。
- **只从 pin 出发**：远程部署不读 submodule 远端最新，保证"服务器跑的就是主仓快照"。

## 5. 发布 + CI

发布 = 主仓打 tag 生成"已验证部署快照"（插件仓自己的发版机制不动）。

### 手动触发（`make release`，本地执行）

1. `release.sh` 校验：工作区干净；每个 submodule 的 pin 与远端对应分支（harness→master，dsh-web→main，dsh-plugin-mineru→master）上真实存在的 commit 一致（拦截"本地未推送的 commit 被误 pin"）；tag-pin 子仓（dsh-better-sidebar→`v0.18.1`）以远端正式 tag 比对（tag 存在于远端即已发布，同语义）。
2. 生成快照清单：每个 submodule 的名称、pin commit SHA、可读版本号（优先取 pin commit 所在分支可及的最新 tag，无 tag 则取 `package.json` 的 `version`）。
3. `git tag v<semver>` → `git push origin v<semver>`（只推本次发布 tag）。

### CI 自动执行

**`release.yaml`（tag 触发）**：从 tag 做一次干净构建 + 冒烟验证，**通过才**创建 GitHub Release（notes 附快照清单）；失败则不发布并告警。快照清单用于追溯"某版本部署了什么 commit"。

**`verify.yaml`（push/PR 触发）**：

1. **pin 一致性校验**：同 `release.sh` 的校验逻辑（含 tag-pin 比对），PR 中 pin 了未推送的 commit 会被拦截。
2. **冒烟测试**：干净环境 `submodule init --recursive` → `make setup` → 启动 DSH Web（`--no-open`）→ 健康检查 3080 → 退出。CI runner 为 Linux x86-64，与生产服务器同平台。

## 6. 插件开发工作流（在 submodule 内开发）

以 dsh-web 为例（后续插件仓流程相同）：

```sh
# 一次性：把 submodule 切到开发分支（submodule 默认处于 detached HEAD）
cd plugins/dsh-web && git checkout main && cd ../..

# 日常循环
make dev                          # DSH Web + 插件 link 挂载，改插件源码即时生效
cd plugins/dsh-web && git add -A && git commit -m "..." && git push   # 推回插件仓
cd ../.. && git add plugins/dsh-web                # 回主仓更新 pin
git commit -m "chore: bump dsh-web pin to <sha>" && git push   # 走 PR，verify CI 校验
```

约定：

- submodule 默认 detached HEAD 是特性——主仓只认 pin 的 commit；要开发才切分支。
- 插件发版在插件仓自己的仓库里按它现有机制完成，主仓不越界编排。
- 主仓更新 pin 走 PR + `verify.yaml` 校验，防止"服务器快照与本地不一致"。
- 新插件加入：`git submodule add <repo> plugins/<name>`，目录不存在则自动创建。
- `docs/plugin-dev.md` 写清以上流程，README 快速上手指向它。

## 7. 成功标准

1. 全新 macOS M4 机器：`make setup && make dev` 一键搭起可运行的 DSH + dsh-web，插件源码改动即时生效。
2. 全新 Linux x86-64 服务器：`make deploy` 一键部署成功，健康检查通过；重复执行幂等；失败可回滚。
3. 主仓 tag + GitHub Release 携带快照清单，可追溯每个 submodule 的 pin commit。
4. CI 能拦截"pin 了远端不存在的 commit"的 PR；release 流程在冒烟失败时不发布。
