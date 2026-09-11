# dsh 主框架（harness）升级到 dsh-v0.1.5-rc.2 —— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 harness submodule 从 `c389f96b`（`dsh-v0.1.3-alpha.2-133-gc389f96bf3`）升到正式 tag `dsh-v0.1.5-rc.2`（`fb2c4b9e`），跨度 **713 个提交、2900 个文件（+64042/−17387）**；同时把 harness 的 pin 语义从「分支 pin（master）」改为「tag pin」，CI 校验随之从分支 loop 移到 tag loop。

## 0. 已拍板的决策

1. **tag pin 取代分支 pin**（用户指定「pin 到 v0.1.5-rc.2」）：harness 不再 pin `master` 的 HEAD，pin 正式发布 tag。核证：`dsh-v0.1.5-rc.2` 是 `origin/master` 的**祖先**（纯发布节点，master 又领先它 139 个提交）。这与 better-sidebar / modlens 的 tag pin 惯例统一，但**违反 AGENTS.md 原有的「harness → master」硬约束**，故 AGENTS.md / spec / verify.yaml / release.sh 需同步改写。
2. **CI 校验换轨**：`verify.yaml` 的 harness 从「分支 loop」移到「tag loop」；`release.sh` 的 `check_pin harness master` 改为 `check_pin_tag harness dsh-v0.1.5-rc.2`。tag 比对用 `rev-parse <tag>^{}`（该 tag 是轻量标签，`^{}` 对其为 no-op，与 modlens 的注释标签兼容写法一致）。
3. **不改任何 submodule 之外的上游文件**：mainline 同步只通过 pin 完成；`harness/` 内不做本地修改。
4. **原生构建就地各自进行**：新版本引入 `native/system`（`build:native-system`），本机 macOS arm64 构建 `system.node`，服务器 Linux x86-64 各自构建——符合 AGENTS.md「原生依赖严禁跨平台拷贝」硬约束。

## 1. 已钉死的关键事实（防再踩坑）

1. **tag 名带 `dsh-` 前缀**：上游发布 tag 是 `dsh-v0.1.5-rc.2`，不是 `v0.1.5-rc.2`（`git tag --list "v0.1.5*"` 返回空，易误判为「tag 不存在」）。当前 pin 的 describe 是 `dsh-v0.1.3-alpha.2-133-gc389f96bf3`。
2. **跨度与规模**：713 commits、2900 files、+64042/−17387；新增顶层目录 `native/`（其余为 M/A/D/R）。
3. **集成面（我们依赖的接口）逐一核证未变**：
   - `package.json` 的 `packageManager: pnpm@11.7.0`、`engines.node: ^22.19.0 || >=24.0.0` —— **均未变**（corepack 解析与前置校验不受影响）。
   - `packages/bundle/web-app/cordis.patch.yml` 的 `connection` 入口**逐字节相同**（仍 `inject: [webRuntime]`、`config.trustedHosts: !!js ctx.webRuntime.trustedHosts`）→ `patches/inject-webserver-dsh-connection.yml` **仍然必要且仍然成立**（`rpc-host.ts` 两版零差异，`const owner = this.ctx` 捕获 + `owner.webServer` 用法原样）。
   - `dsh-web-app` bundle 仍提供 `webserver` / `webRuntime` 条目 → link-plugins 的宿主 ensure 步骤仍成立。
   - CLI 接口：`apps/cli/src/{bin,args,dump-config,plugin}.ts` 俱在，`--profile` / `dump-config` / `plugin add link:` 语义未变（`dsh.profile.bundles` 仍是层栈驱动，`add` 后仍 reconcile bundles）。
   - 插件清单字段 `dsh.bundle.patch`、`dsh.client.{inject,platform,immediately}` 仍受支持（`packages/client/modules/src/index.ts`）。
5. **新增原生构建步骤**：`scripts/build.ts` 第 44 行无条件先跑 `build:native-system` = `tsx native/system/scripts/build.ts --host-addon-only`。它只构建**宿主平台**的 Node-API 插件（`flock`），跳过静态 musl 的 `landlock-run`；前置要求 = **C 编译器**（macOS `cc` / Linux glibc `cc`）**+ Node 开发头文件**（`dirname(process.execPath)/../include/node/node_api.h`），缺失时抛 `Node-API headers missing …; use a Node installation with development headers`。
6. **原生产物已被 ignore**：`native/system/.gitignore` 有 `packages/*/bin/`，构建产物 `native/system/packages/darwin-arm64/bin/system.node` 不会弄脏 submodule（与 mineru 的 `lib/client.js` 情形相反）。
7. **profile 层栈新增 home 级 patch 层**：新版本组合顺序为 bundles → profile `cordis.patch.yml` → **`$DSH_HOME/cordis.patch.yml`（机器本地偏好，优先于逐 profile 层）** → `--patch` 覆盖层。我们的 `merge-profile-patch.mjs`（写 profile 级）仍有效。

## 2. 升级步骤

### 2.1 抓取并核证 tag

```sh
cd /Users/michaelyao/workspace/dsh
git -C harness fetch origin --tags          # 网络抖动时需重试（见 §3.2）
git -C harness tag --list "dsh-v0.1.5*"     # 注意 dsh- 前缀
git -C harness rev-parse dsh-v0.1.5-rc.2^{} # 预期 fb2c4b9e…
git -C harness merge-base --is-ancestor HEAD dsh-v0.1.5-rc.2^{} && echo "纯前进"
```

### 2.2 checkout + 重装 + 构建

```sh
git -C harness checkout --detach dsh-v0.1.5-rc.2
( cd harness && export CI=true && pnpm install --frozen-lockfile && pnpm build )
```

（`CI=true` 理由同前：submodule 环境下跳过 lefthook postinstall。）

### 2.3 提交（C1）

```sh
git add harness
git commit -m "chore: bump harness pin 到 dsh-v0.1.5-rc.2（自 dsh-v0.1.3-alpha.2-133，713 commits）"
```

## 3. 过程记录（本轮遇到的问题）

### 3.1 `git tag --list "v0.1.5*"` 返回空 → 误判「tag 不存在」

上游发布 tag 带 `dsh-` 前缀。**教训**：`git fetch --tags` 的输出里 `[new tag]` 行才是权威；先看 fetch 输出再下结论。

### 3.2 网络抖动致 fetch 失败

`LibreSSL SSL_connect: SSL_ERROR_SYSCALL` —— 首次 `fetch --tags` 直接失败。处置：重试循环（3 次、间隔 3s）后成功。

### 3.3 zsh 下 `git show $T:path` 报 `bad substitution`

`$T:scripts/build.ts` 在 zsh 中被解析为参数展开修饰符（`:s`）。处置：写成 `${T}:scripts/build.ts`。**与本仓无关的通用 shell 坑**，但会干扰侦察命令。

### 3.4 pin 语义变更的连锁影响

checkout tag 后，`verify.yaml` 的 `"harness master"` 分支比对必然失败（pin≠master HEAD）。这不是缺陷而是 pin 语义变更的必然结果，须一并改 CI（§4）。**若无脑升 pin 不改 CI，CI 会永久红且看起来像「pin 有问题」。**

## 4. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` | 分支 loop 移除 `"harness master"`；tag loop 追加 `"harness dsh-v0.1.5-rc.2"` |
| `scripts/release.sh` | `check_pin harness master` → `check_pin_tag harness dsh-v0.1.5-rc.2` |
| `AGENTS.md` 稳定分支行 | `harness → master` → `harness → 正式 tag \`dsh-v0.1.5-rc.2\`（tag pin）` |
| `README.md` | harness 行注明 pin tag |
| `docs/superpowers/specs/…-design.md` | 子仓清单、release 校验行同步 |

## 5. 验证（本机 macOS arm64，实测记录）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 安装 | `cd harness && CI=true pnpm install --frozen-lockfile` | ✓ `Done in 31.3s using pnpm v11.7.0`（**未变**，仍是 pin 的 11.7.0） |
| 原生构建 | `pnpm build` 第一段 | ✓ `build: built darwin-arm64/bin/system.node` |
| 宿主+客户端构建 | `pnpm build` 完整 | ✓ `build: recorded 236 client artifact(s)`，exit 0，无 `error TS` |
| submodule 清洁 | `git -C harness status --short` | ✓ 空（原生产物被 `native/system/.gitignore` 的 `packages/*/bin/` 覆盖） |
| 挂载 | `make link-plugins` | ✓ 5 个 bundle（dsh-better-sidebar / mineru / session-id / web-all / modlens），"已挂载 5 个 bundle 到 profile dsh" |
| 组合树 | `pnpm dsh --profile dsh --dump-config` | ✓ exit 0、**175 条目**、无 warn |
| patch 仍生效 | 同上，查 connection entry | ✓ `inject: [webRuntime, webServer]`（整表替换后仍正确） |
| 5 个挂载 entry 俱在 | 同上 | ✓ `connection` / `web-ui-better-sidebar`(disabled) / `better-sidebar` / `dsh-mineru`(含 baseURL 种子) / `modlens` |
| 启动 | `make dev` | ✓ `dsh web: http://127.0.0.1:3080/?token=…`，无 `cannot get property` |
| HTTP | 带 token / 无 token | ✓ 303 → `/`；401（认证 gate 生效） |
| 运行时错误 | 日志全文 | ✓ 无插件加载失败（组合、解析、启动失败均会非零退出） |

日志：`log/dev-2026-09-11-10:33:41.log`。

**待用户验收**：浏览器 UI（侧边栏渲染、MinerU 设置 section、modlens 粘贴路径）——客户端半侧的协议兼容只能靠实机渲染确认。

## 6. Commit 切分

```sh
git add harness
git commit -m "chore: bump harness pin 到 dsh-v0.1.5-rc.2（自 dsh-v0.1.3-alpha.2-133，713 commits）"

git add scripts/setup.sh deploy/remote-install.sh
git commit -m "feat(scripts): 前置校验 C 编译器与 Node 开发头文件（harness 原生构建前置）"

git add .github/workflows/verify.yaml scripts/release.sh
git commit -m "ci: harness 改按 tag pin 校验（dsh-v0.1.5-rc.2）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: harness pin 语义改为 tag pin（AGENTS/README/spec）"

git add docs/superpowers/plans/2026-09-11-harness-upgrade-v0.1.5-rc.2.md
git commit -m "docs(plans): 记录 harness 升级 v0.1.5-rc.2 手册"
```

## 6. 风险与兜底

| 风险 | 症状 | 处置 |
| --- | --- | --- |
| 服务器无 C 编译器或 Node 头文件 | `pnpm build` 在 `build:native-system` 阶段失败 | 服务器安装 `build-essential`（或 `gcc`）并确保 Node 发行版带头文件（`node-gyp` 可用） |
| 插件与新 harness 运行时不兼容 | 挂载/boot 报错或 UI 异常 | 见 §6 验证记录；`patches/*.yml` 的 inject 是整表替换，上游若改 connection 入口需同步补列 |
| 上游 master 继续前移 | 无影响（tag pin 不比 master） | 需要跟随主线时显式 pin 新 tag |
