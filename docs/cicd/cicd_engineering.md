---
title: DSH 超级仓库 CI/CD 工程实施细节
doc-version: 1.0.0
status: draft
last-updated: 2026-09-14
applies-to: dsh 超级仓库（main 分支）
---

# 工程实施细节

> **标注约定**：**「实测」**= 本仓已存在且核对过；**「设计」**= 目标态，尚未落地；
> **「踩坑」**= 本仓实际发生过并已定位的问题（这类最有价值，散落各处会重复踩）。

配套阅读：[cicd_architecture.md](cicd_architecture.md)（总体架构）、[../plugin-dev.md](../plugin-dev.md)（插件开发与常见问题）。

---

## 1. 总则：CI 调用脚本，不复制逻辑

本仓 `Makefile` + `scripts/*` 已经把「构建、挂载、部署、发布」收敛成单一入口。
**CI 的职责是调用它们**——一旦在 Jenkinsfile 里重写一份逻辑，两份就会漂移。

### 1.1 已收敛：pin 清单与校验（2026-09-14 落地）

**原先的问题**：同一份 submodule pin 清单与校验逻辑写在三处、手工同步——
`verify.yaml` 的两个 loop、`release.sh` 的 `check_pin`/`check_pin_tag`、`release.yaml` 的快照列表。
新增插件时漏改一处，那条通路就**静默失守**（本次接 dsh-tui 就改了三处）。

**现已收敛到 `scripts/check-pins.sh`**，它是唯一实现：

```
scripts/check-pins.sh            # 校验全部（分支 pin 3 条 + tag pin 8 条）
scripts/check-pins.sh --list     # 枚举清单 <path>\t<kind>\t<ref>，供快照生成消费
```

三处调用点：

| 调用方 | 用法 |
| --- | --- |
| `scripts/release.sh` | `bash "$ROOT/scripts/check-pins.sh"`（发布前的 pin 门禁） |
| `.github/workflows/verify.yaml` | `run: bash scripts/check-pins.sh` |
| `.github/workflows/release.yaml` | 快照清单改为枚举 `--list`（原先硬编码 11 个 submodule） |

**顺带修掉的一处不一致**：`release.sh` 的快照原先只写 harness + dsh-web **2 行**，
而 `release.yaml` 写**全部 11 行**。现在两者都从 `--list` 枚举，随新增插件自动对齐
（即 [cicd_architecture.md](cicd_architecture.md) §4.4 记录的问题，现已消除）。

**Jenkins 侧应直接调用它**，不要复制逻辑——这样 [cicd_architecture.md](cicd_architecture.md) §9 R3
的「两套规则漂移」风险随之消失。

## 2. Jenkins 侧（设计）

### 2.1 环境变量（每个 job 都要）

```groovy
environment {
  DSH_HOME = "${WORKSPACE}/.dsh"
  CI = 'true'                              // 见 §5.1：让 pnpm 跳过 hooks 安装
  COREPACK_DEFAULT_TO_LATEST = '0'         // 解析不到 pin 的 pnpm 时宁可报错也不回落 latest
}
```

### 2.2 verify job（对应现 `verify.yaml` ①②③④⑤）

```groovy
pipeline {
  agent { label 'linux-x86_64' }           // 与服务器同平台（C1）
  stages {
    stage('Checkout') {
      steps {
        checkout([$class: 'GitSCM',
          extensions: [[$class: 'SubmoduleOption', recursiveSubmodules: true],
                       [$class: 'CloneOption', depth: 0, shallow: false]]])
      }
    }
    stage('Pin 校验') {
      steps { sh './scripts/check-pins.sh' }   // §1 建议抽出的共用脚本
    }
    stage('ShellCheck') {
      steps { sh 'shellcheck -S style scripts/*.sh deploy/remote-install.sh' }  // 固定 0.11.0
    }
    stage('构建') {
      steps { sh 'make setup' }                // 真实构建，非 mock
    }
    stage('挂载 + 冒烟') {
      steps {
        sh 'bash scripts/link-plugins.sh'
        sh '''
          (cd harness && pnpm dsh --profile dsh --no-open >/tmp/dsh.log 2>&1) &
          for i in $(seq 1 60); do
            code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/ || true)
            case "$code" in 200|303|401) exit 0 ;; esac
            sleep 2
          done
          cat /tmp/dsh.log; exit 1
        '''
      }
    }
  }
  post {
    success { /* 回写 Gerrit Verified+1 */ }
    failure { /* 回写 Verified-1 + 日志链接；cat /tmp/dsh.log */ }
  }
}
```

> **冒烟判据 `200|303|401` 是实测结论**（`verify.yaml:65-68` 注释）：
> harness 对未认证请求返回 **401**——认证 gate 在响应即说明服务已就绪；303 跳认证页亦正常。
> **不要**改成只认 200，会恒失败。

**macOS 节点的差异（设计）**：同样的 stages，`agent { label 'macos-arm64' }`。
**唯一实质区别是产物不共享**（C2）——两个节点各跑一次完整 `make setup`。

### 2.3 deploy job（设计，人工触发）

```groovy
pipeline {
  agent { label 'linux-x86_64' }
  parameters { choice(name: 'HOSTS', choices: ['deploy/hosts'], description: '服务器清单') }
  stages {
    stage('预检')  { steps { sh 'bash scripts/deploy-remote.sh --dry-run' } }   // 先试运行
    stage('部署')  { steps { sh 'make deploy' } }
  }
}
```

> **保持「部署是显式动作」**（[AGENTS.md](../../AGENTS.md)）：Jenkins 提供**可手动执行**的
> deploy job（带审计与统一环境），但**不由 merge 自动触发**。见 [cicd_architecture.md](cicd_architecture.md) §4.5。

### 2.4 release job（设计）

```groovy
stage('发布') {
  steps {
    withCredentials([string(credentialsId: 'dsh-release-token', variable: 'GIT_PUSH_TOKEN')]) {
      sh 'make release VERSION=${VERSION}'
    }
  }
}
```

> ⚠️ **`release.sh` 第 ⑤ 步强制要求存在名为 `origin` 的远端**（实测，`release.sh:99-104`）。
> 引入 Gerrit 后 origin 的指向必须重新确认，否则可能把 tag 推到 Gerrit——
> 见 [cicd_architecture.md](cicd_architecture.md) §4.3。

### 2.5 Jenkins 插件与凭据（设计）

**所需插件**（最小集）：

| 插件 | 用途 | 备注 |
| --- | --- | --- |
| **Pipeline**（workflow-aggregator） | Jenkinsfile 流水线 | 必需 |
| **Git** | 拉仓库 | 必需 |
| **Git submodule**（`git-submodule`） | 递归拉 submodule | 或用 `sh 'git submodule update --init --recursive'` 手工替代 |
| **Gerrit Trigger**（`gerrit-trigger`） | 订阅 Gerrit 事件 + 回写标签 | 也可用 **Gerrit Code Review / Gerrit REST** 自行实现，取决于版本兼容性 |
| **Credentials Binding** | 凭据注入 | 通常随 Pipeline 带 |
| **SSH Agent** | 部署用的 ssh key | `deploy-remote.sh` 需密钥认证（实测 `BatchMode=yes`） |
| **Workspace Cleanup** | 清理 workspace | **建议装**：每次 `make setup` 体积很大（见 [deployment.md](cicd_deployment.md) §2 的磁盘提示） |
| **Timestamper** | 构建日志加时间戳 | 排查耗时用 |

**凭据清单**（与 [cicd_architecture.md](cicd_architecture.md) §6.2 对应）：

| credential id（建议） | 类型 | 给谁用 | 注意 |
| --- | --- | --- | --- |
| `gerrit-jenkins-ssh` | SSH username with private key | Jenkins → Gerrit 拉代码 / 回写标签 | **专用账号**，勿用个人 key |
| `dsh-deploy-ssh` | SSH username with private key | `deploy-remote.sh` 连目标服务器 | 目标侧 sudo 需免密或账号为 root（实测约束） |
| `dsh-release-token` | Secret text（或 SSH key） | `release.sh` 推 tag | 见 [cicd_architecture.md](cicd_architecture.md) §4.3 的 origin 语义 |
| `deepseek-api-key` | Secret text | **仅当**引入 `dsh-headless` 时 | 目前不需要（见 [cicd_architecture.md](cicd_architecture.md) §5） |

> ⚠️ **`JENKINS_HOME/secrets/` 必须纳入备份**——它加密上述全部凭据，
> 丢了要全部重配（见 [deployment.md](cicd_deployment.md) §5）。

---

## 3. Gerrit 侧（设计 + 调研）

**本仓未部署过 Gerrit**，以下为设计要点；配置实例见
[reference/community-survey.md](reference/community-survey.md) §2.3（调研资料，未经本仓验证）。

| 项 | 要点 |
| --- | --- |
| commit-msg hook | 提供 `Change-Id`（G1）；开发者 `make setup` 后需手动安装一次 |
| Access Rights | 在 `All-Projects` 或目标仓配置；`refs/heads/main` 设 `Submit` 权限 |
| 标签 | `Code-Review`（人工）、`Verified`（Jenkins 回写）—— 两者齐备才可 submit（G6/G7） |
| submit 规则 | 建议强制 rebase 到最新（避免 pin 校验基于过期 base 通过） |
| Stream Events | 供 Jenkins 订阅 `patchset-created` / `change-merged`（[cicd_architecture.md](cicd_architecture.md) §3.3 ③⑧） |
| 推送路径 | `git push origin HEAD:refs/for/main` |

### 3.1 `.gitmodules` 的 URL 该指向哪（设计，必须先定）

引入 Gerrit 后 `.gitmodules` 里的 URL **不要改**——11 个 submodule 的上游本就在 GitHub，
本仓的设计意图就是「superproject 编排上游 pin」。改指向 Gerrit 意味着要镜像全部上游。

**只有当 [cicd_architecture.md](cicd_architecture.md) §4.1 选了方案 B/C 时**才需要改，
届时用 `git config --global url.<镜像>.insteadOf https://github.com/`（方案 C）
**比改 `.gitmodules` 更好**：不污染仓库内容，且对本地开发与 CI 一致生效。

### 3.2 submodule 变更如何走 `refs/for/` 评审（设计，本方案最不确定处）

本仓的变更**几乎总会**同时改「主仓文件」与「submodule 的 gitlink」（如接一个新插件）。
在 Gerrit 的 Change 模型下：

| 变更类型 | 做法 |
| --- | --- |
| 只改主仓文件 | 常规 `push refs/for/main`，无特殊处理 |
| 改 gitlink（pin 更新） | gitlink 是一个**普通文件条目**，会随 Change 一起评审——**机制上可行** |
| 同时改插件源码 + 主仓 pin | **跨仓变更，Gerrit 单个 Change 无法表达**。需要：先评审并合入插件仓（其自己的流程），再在主仓发起只含 pin 的 Change |

> 🔴 **R1 风险正在于此**：Gerrit 对 submodule 的支持不像 GitHub 那样有成熟流程。
> `refs/for/` 工作流下 gitlink 变更的评审、以及 `submodule update` 在 Change 检出后的行为，
> **都必须实测验证**，不能假设可用。**这是 P1 阶段的第一优先验证项。**

> 🔴 **最不确定的一点**：Gerrit 与 **git submodule** 的组合。本仓有 11 个 submodule（见
> [cicd_architecture.md](cicd_architecture.md) §4.1），而 Gerrit 的 `refs/for/` 工作流对 submodule 的
> pin 变更评审没有成熟流程。**必须在 P1 阶段专门验证**，不要假设它能像 GitHub 那样工作。

---

## 4. 硬约束在 CI 中的落地

| 约束 | 落地做法 |
| --- | --- |
| C1 双平台 | Jenkins 两类 agent：`linux-x86_64`（与服务器同平台，`verify.yaml:9` 注释即此意）+ `macos-arm64` |
| C2 禁止跨平台拷贝 `node_modules` | **每个节点各自 `make setup`**；CI 缓存只能缓存**下载物**（pnpm store），**不能缓存 `node_modules`** |
| C3 原生构建需工具链 | 节点镜像必须含 C 编译器 + Node 开发头文件（`harness` 的 `pnpm build` 先跑 `build:native-system`）；**不能用精简镜像** |
| C4 Node/pnpm 版本 | 预置 Node `^22.19 \|\| >=24`（23 不满足）；**pnpm 由 corepack 按各仓 `packageManager` 解析**，各子仓版本可能不同（见 §6.2） |
| C5 submodule detached HEAD | CI **不得**执行 `git submodule update --remote`；pin 更新是显式动作 |
| C6 profile 名 | 所有命令显式 `--profile dsh`（TUI 用 `--profile tui`） |
| C7 插件发版不越界 | CI 不做 `npm publish`，只做本仓 pin 快照 |

---

## 5. 环境与命令细节

### 5.1 `CI=true` 不是可选项（实测）

`make dev` 的注释写明了原因（实测，`Makefile:22-26`）：**pnpm 11 跑脚本前默认校验依赖，
脏时会自动先 `pnpm install`**，而重装会触发 harness 根 `postinstall`（`install-lefthook.mjs`），
**在 submodule 环境必然失败**。`export CI=true` 使其跳过 hooks 安装（与 GitHub Actions 全局
`CI=true` 一致）。

**CI 侧本来就是 `CI=true`**，所以本地能跑通而 CI 失败（或反之）时，先看这一条。

### 5.2 `TMPDIR` 要用短路径（踩坑）

`scripts/setup.sh` 的插件循环前统一 `export TMPDIR=/tmp`。原因：macOS 的 `os.tmpdir()` 是
`/var/folders/<长哈希>/T`，某些插件的 unix socket 路径会超过 **macOS `sun_path` 上限 104 字节**
→ `listen EINVAL`。实测 dsh-TUI 的 `verify:inject-channel` 因此失败（路径 105 字节）。

**Linux 节点本来就用 `/tmp`**，所以这条只在 macOS 节点上生效——但两边都设，行为一致。

### 5.3 健康检查必须在本机（实测）

`deploy-remote.sh` 第 ⑥ 步**必须在服务器本机** curl `127.0.0.1:3080`：
web 服务默认只绑回环，且 `--host 0.0.0.0` 被 CLI **有意拒绝**（安全设计）。
从 Jenkins 节点直接 curl `<server>:3080` **恒失败**。

---

## 6. 已知失败模式与排查（本仓实测积累）

> 这些是本仓实际发生过、已定位的问题。散落在各手册里易重复踩，集中在此。
> 更细的插件侧问题见 [../plugin-dev.md](../plugin-dev.md)「常见问题」。

### 6.1 pnpm 解析族

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| `MODULE_NOT_FOUND …/corepack/v1/pnpm/12.3.4/…` | 插件仓没声明 `packageManager`，corepack 向上找不到 pin → 回落坏版本 | `setup.sh` 已有分支（`plugin_pnpm` 经 harness pin 执行）；CI 侧**不要**绕过 `setup.sh` 自己 `pnpm install` |
| `[ERR_PNPM_IGNORED_BUILDS]`（**打在 stdout、退出码 1**） | 仓没声明构建策略，pnpm 11 默认拦截依赖构建脚本 | `setup.sh` 自动处理（无声明即 `--ignore-scripts`）。**注意别用「先普通安装再重试」**——被拦截的安装留下 `pendingBuilds`，会让随后的 `pnpm build` 自动重跑 install |
| `[ERR_PNPM_LOCKFILE_CONFIG_MISMATCH]` | `overrides` 写在 `package.json` 的 `pnpm` 字段（pnpm ≤10 的位置），pnpm 11 不再读 | `setup.sh` 自动路由到 `corepack pnpm@10.33.0` |
| 插件仓只有 `package-lock.json` | pnpm 会忽略它并生成 `pnpm-lock.yaml` **弄脏 submodule** | `setup.sh` 自动走 `npm ci` |

### 6.2 各子仓 pnpm 版本可以不同（不是冲突）

corepack 按 cwd 向上解析，各仓各用各的 `packageManager`。首跑会看到
`! Corepack is about to download …/pnpm-10.x.tgz`——**需要网络**。CI 节点应预热 corepack 缓存。

### 6.3 构建产物与 pin 不一致（踩坑）

`git submodule add` 记录的是**克隆当时的默认分支 HEAD**；随后手工 `checkout --detach <tag>`
**只改工作树，不改已记录的 gitlink**。而 `make setup` 会跑 `git submodule update --init --recursive`，
把工作树**顶回记录的 gitlink**——手工 checkout 被静默冲掉。

**后果**：pin 指 A，产物却来自 B。

**正确顺序**：`checkout --detach <tag>` → **`git add plugins/<name>` 并提交** → 再跑 `make setup`。
（本次接 dsh-TUI 时实际踩到：pin 成了 `main` HEAD，产物也是错的，已修正。）

### 6.4 submodule 被构建弄脏

入口已提交在仓内的插件**不该本地构建**——本地重建产物与 pin 自带的不同
（如 CSS module 类名哈希由绝对路径派生），会弄脏 submodule 并让 `release.sh` 的干净度检查拒绝。
`setup.sh` 已按「根 `main` 被 git 跟踪即跳过构建」处理。误改后 `git -C plugins/<name> checkout -- <file>` 还原。

### 6.5 `package.json` 的 `pnpm.overrides` 与 pnpm 11

pnpm 11 已不读 `package.json` 里的 `pnpm.overrides`（迁到 `pnpm-workspace.yaml`）。
`setup.sh` 已按「无 `packageManager` 且 `package.json` 有 `pnpm.overrides` → 用 pnpm 10」路由。

### 6.6 插件 patch 整表替换 config，会抹掉旁键（踩坑）

`cordis.patch.yml` 的 `config` 是**整表替换**而非深合并。某插件只列了自己要改的键，
其余旁键就被抹掉（如 modsearch 抹掉 `web` 行的 `fetchProvider`）。
**dump 与 boot 都可能全绿**（被抹的键恰好有回退），要靠**对比装前装后的 dump** 才发现。
处置见 `patches/restore-web-fetch-provider.yml`。

### 6.7 端口占用会伪装成「新插件导致启动失败」

`lsof -nP -iTCP:3080 -sTCP:LISTEN -t | xargs kill`。**停后台任务只杀 `make` 包装进程，
`pnpm dsh` 的 `node` 子进程会残留**并继续占端口。

---

## 7. 部署链细节（`deploy/remote-install.sh` 九步，实测）

服务器侧脚本按序执行：

| 步 | 内容 |
| --- | --- |
| 0 | 部署目录与平台判定（`DEPLOY_DIR` 默认 `/opt/dsh`） |
| 1 | 工具链前置校验（与 `scripts/setup.sh` 同款） |
| 2 | 校验各仓 pin 的 pnpm 能正确解析（不依赖全局 pnpm） |
| 3 | harness：安装依赖 + 构建（**服务器平台**产物，`frozen-lockfile`） |
| 4 | 各插件：安装依赖 + 构建（服务器平台产物） |
| 5 | pnpm 版本锚点（与 `link-plugins.sh` 同机制） |
| 6 | 服务入口 shim（供 `dsh.service` 使用） |
| 7 | 渲染并安装 systemd unit（`@DEPLOY_DIR@` 占位符替换） |
| 8 | 挂载 bundle：把可挂载的插件包 link 进 profile `dsh` |

> **第 3/4 步是「服务器平台产物」的落点**——这正是 C2 的体现：本地 macOS 的
> `node_modules` 在 [cicd_architecture.md](cicd_architecture.md) §1.4 的 rsync 里被**排除**，依赖全部在服务器侧重装重编。

**systemd unit 要点**（`deploy/dsh.service`，实测）：`DSH_HOME=@DEPLOY_DIR@/.dsh`、
`COREPACK_DEFAULT_TO_LATEST=0`、`ExecStart=/usr/local/bin/pnpm --dir @DEPLOY_DIR@/harness dsh --profile dsh --no-open`、
`Restart=on-failure` / `RestartSec=3`。

---

## 8. 迁移验证清单（设计）

每个阶段落地时**逐项验证**，不要跳。★ 为**必须先做**的验证项。

### 8.1 P1（Gerrit 接入）

| # | 验证项 | 通过标准 |
| --- | --- | --- |
| ★1 | **submodule 在 Gerrit 上的行为**（§3.2 R1） | 检出 Change 后 `git submodule update --init --recursive` 能拉到正确 pin；gitlink 变更能被评审 |
| ★2 | `.gitmodules` URL 策略（§3.1） | 开发者本地与 CI 都能拉到 submodule |
| 3 | commit-msg hook | 新提交带 `Change-Id` |
| 4 | Access Rights | 无权限者推不进 `refs/heads/main`；`refs/for/main` 可用 |
| 5 | submit 规则 | 缺 `Verified` 或 `Code-Review` 时无法 submit |

### 8.2 P2（Jenkins verify 并行）

| # | 验证项 | 通过标准 |
| --- | --- | --- |
| ★1 | **双跑结论一致**（本阶段的核心验收点） | 同一 commit，Jenkins 与 GitHub Actions **结论相同** |
| 2 | pin 校验 | Jenkins 调 `scripts/check-pins.sh`，与 Actions 同源同结果 |
| 3 | shellcheck 版本 | 固定 `0.11.0 -S style`，与 Actions 一致 |
| 4 | macOS 节点 | `make setup` + 冒烟在 macOS 节点通过 |
| 5 | 冒烟判据 | `200/303/401` 均视为就绪（**勿改成只认 200**，§6） |
| 6 | 标签回写 | 成功→`Verified+1`；失败→`Verified-1` 且附日志链接 |

### 8.3 P3（部署 / 发布）

| # | 验证项 | 通过标准 |
| --- | --- | --- |
| ★1 | **deploy job 与手工 `make deploy` 等价** | 同一 `deploy/hosts`，结果一致（含快照回滚路径） |
| 2 | origin 语义（§4.3） | `release.sh` 不会把 tag 推到 Gerrit |
| 3 | 快照口径 | `release.sh` 与 `release.yaml` 出的清单**行数与内容一致**（现均为 11 行，§1.1） |
| 4 | 发布回滚演练 | 删 tag + 处理 GitHub Release 的流程**实际演练一次**（现无机制，见 [cicd_architecture.md](cicd_architecture.md) §6.4） |
| 5 | 凭据备份恢复 | `JENKINS_HOME/secrets/` 恢复后凭据可用（[deployment.md](cicd_deployment.md) §5） |

---

## 9. 待补齐（与 [cicd_architecture.md](cicd_architecture.md) §9 对应）

| 事项 | 归属 |
| --- | --- |
| ~~`scripts/check-pins.sh` 抽出并三处共用~~ | ✅ **2026-09-14 已完成**（见 §1.1） |
| ~~统一发布快照口径~~ | ✅ **2026-09-14 已完成**（两者均改为枚举 `--list`，见 §1.1） |
| Gerrit + submodule 的评审流程实测 | 风险，P1 阶段 |
| macos-arm64 Jenkins 节点 | 未决，[cicd_architecture.md](cicd_architecture.md) §9 U1 |
| Jenkins 双节点构建耗时实测（决定是否只在 PR 上跑双平台） | 未决，[cicd_architecture.md](cicd_architecture.md) §9 R2 |
