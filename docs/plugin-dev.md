# 插件开发指南

插件以 submodule 收在本仓 `plugins/<name>/`（源码形态），可运行形态经 DSH profile `dsh` 以 link 挂载进 `.dsh/profiles/dsh/`（符号链接，改源码即时生效）。

开发前先在本仓跑一次 `make setup`（初始化 submodule + harness/插件依赖构建），之后日常开发不需要重跑。

## 挂载机制（`make dev` 做了什么）

`make dev` 先执行 `scripts/link-plugins.sh`：对 `plugins/*` 中声明了 `dsh.bundle.patch` 且 patch 落在自己包目录内的包，执行 `dsh plugin --profile dsh add link:<绝对路径>`，以 pnpm `link:` 协议把插件装进 `.dsh/profiles/dsh/`（profile 内含 `package.json` 插件清单 + `node_modules`）。link 是符号链接，改插件源码即时生效，重复运行幂等。

- dsh-web 根包的 patch 指向包外的子包文件，因此根包不是挂载入口，其聚合包才是（与 dsh-web 官方开发文档一致）。
- 被其他可挂载包依赖的包（聚合包的家族成员）不单独挂载，由聚合包的 `link:` 带出本地构建。

## 在 submodule 内开发（以 dsh-web 为例）

```sh
# 一次性：切到稳定分支（submodule 默认 detached HEAD 是特性）
# 注意：dsh-web 默认分支是 dev，稳定分支是 main，本仓只 pin main，不要 pin dev
cd plugins/dsh-web && git checkout main && cd ../..

# 日常循环：link 挂载 + 改源码即时生效（服务监听 http://127.0.0.1:3080）
make dev
cd plugins/dsh-web && git add -A && git commit -m "feat: ..." && git push

# 回主仓更新 pin（先 push 插件仓再更新 pin；提交走 PR，verify CI 校验 pin 与远端 main 一致）
cd ../.. && git add plugins/dsh-web
git commit -m "chore: bump dsh-web pin" && git push
```

## 约定

- submodule 默认保持 detached HEAD：主仓只认 pin 的 commit，开发时才切分支。
- 插件发版（npm publish / tag）由插件仓按自身机制完成，主仓只做 pin 快照，不越界编排。
- 新插件加入：`git submodule add <repo> plugins/<name>`（目录不存在会自动创建），随后 `git -C plugins/<name> checkout --detach` 归一化——`submodule add` 会让新仓停在默认分支上，且 `git submodule update` 在 HEAD 已等于 pin 时会跳过、不会 detach。
- 要部署到服务器的插件仓必须提交 `pnpm-lock.yaml`：服务器侧构建强制 `--frozen-lockfile`，缺失会部署失败。
- 插件仓缺 `packageManager` 字段时，本地 `link-plugins.sh` 硬错误退出，而服务器侧 `remote-install.sh` 静默跳过锚点写入——这是有意分歧（本地锚点必须钉住 harness 的 pnpm 版本，缺字段无法确定；服务器侧与其 pnpm 校验同语义，视为可跳过）。

## 接入新插件的 checklist（三轮集成固化的流程，setup/link 已自动化大半）

1. **侦察**（clone tag 到 /tmp，别直接加 submodule）：包名；仓形态（单包 / monorepo）；`packageManager` 有无；lockfile 有无；根 `main` 是否被 git 跟踪（决定构建还是跳过）；`dsh.bundle.patch` 是否声明且落在自身目录（决定 link 自动挂载）；entry 怎么用宿主服务——自声明 `export const inject` 或 scoped `ctx.inject` 则无需 patch，getter 捕获 `this.ctx` 则需 patches 补 inject；peer 依赖与 harness pin 的兼容面；entry id 与现有仓（尤其 dsh-web 聚合的 AUTO-GENERATED 行）是否冲突。
2. **接入**：`git submodule add <repo> plugins/<name>` → `git -C plugins/<name> checkout --detach <pin>`（tag 或分支）→ 主仓 `git add`。
3. **安装构建**：全部交给 `scripts/setup.sh` 插件循环——`plugin_pnpm`（无 packageManager 经 harness pin）、`plugin_install`（无构建策略声明则 `--ignore-scripts`）、跳过构建判据（入口被跟踪）。验证：跑循环 + `git submodule foreach` 全 0 dirty + 产物存在。
4. **挂载**：bundle patch 在自身目录即自动挂载；需要禁用/注入时写 `patches/*.yml`（顶层数组、`inject` 整表替换）。
5. **dump 验证**：`pnpm dsh --profile dsh --dump-config` 出现新 section、inject 全解析、无 warn。
6. **CI/docs 五处**：`verify.yaml`（分支 loop 或 tag loop）、`release.yaml` 快照清单、`release.sh` `check_pin`/`check_pin_tag`、`AGENTS.md` 稳定分支行、`README.md` plugins 行、spec 子仓清单/目录树/校验行。**tag pin 用 `rev-parse <tag>^{}`**——注释标签直接 rev-parse 返回标签对象哈希，与 HEAD 比对必假。
7. **收尾**：集成手册（`docs/superpowers/plans/YYYY-MM-DD-<name>-integration.md`）+ 新踩坑按症状补进下方常见问题；提交按 pin / scripts / ci / docs / 手册切分；最后用户跑 `make dev` 做 UI 验收。

## 常见问题

- `make dev` 报 harness 未构建：先跑一次 `make setup`。
- 主仓提交后 verify CI 报「pin 与 main 不一致」：插件仓的最新 commit 还没 push 到远端 `main`，先 push 插件仓再更新 pin。
- 本地已 push 插件仓但 CI 仍报 pin 不一致：上游稳定分支已推进过 pin，执行 `git submodule update --remote` 拉到远端最新后重新 `git add plugins/<name>` 提交 pin。
- 改了插件代码但不生效：确认改的是被 link 挂载的那个包（根包不是挂载入口时改聚合包），并确认 `make dev` 输出里有 `link <包名> <- <路径>`。
- `make dev` 停在 SQLite ExperimentalWarning、没有 `dsh web: http://127.0.0.1:3080/` 行、3080 无监听：profile 组合树缺 web 宿主。先 `make link-plugins`（其 ensure 步骤会把 `@deepseek-ai/dsh-web-app` 插到 `dsh-base` 之后），再 `cd harness && pnpm dsh --profile dsh --dump-config` 确认树里有 `webserver` 条目。
- 插件 entry 加载失败、报 `cannot get property "X" without inject`：该服务是在**提供方插件的 fiber 作用域**上解析的，不是调用方——harness 里服务 getter 若捕获 `this.ctx`（如 `connection.rpc`，`harness/packages/client/connection/src/rpc-host.ts:80`），随后 `owner.<service>` 只在提供方 fiber 链上找。**给调用方插件加 `inject` 无效**；应在 `patches/*.yml` 给**提供方 entry** 补 `inject`（样例 `patches/inject-webserver-dsh-connection.yml`，根因见 mineru 手册 §1.8）。注意 patch 的 `inject` 是整表替换，该 entry 原有注入项必须一并列出。
- 插件仓里直接 `pnpm install` / `pnpm build` 报 pnpm 12.x 或 `MODULE_NOT_FOUND`：该仓没声明 `packageManager`，corepack 向上找不到 pin 回落到了坏版本。改走 harness 目录：`cd harness && pnpm --dir ../plugins/<name> install`（`scripts/setup.sh` 与 `deploy/remote-install.sh` 已把 install 与 build 收敛到同一分支）。
- 跑完 `make setup` 插件 submodule 变脏（如 mineru 的 `lib/client.js`）：本地重建产物与 pin 自带的产物必然不同（CSS module 类名哈希由绝对源码路径派生）。入口文件已提交在仓内的插件不该本地构建——`setup.sh`/`remote-install.sh` 已按「根 `main` 被 git 跟踪即跳过构建」处理；误改后 `git -C plugins/<name> checkout -- <file>` 还原。
- 插件仓 `pnpm install` 报 `[ERR_PNPM_IGNORED_BUILDS] Ignored build scripts`（**打在 stdout**、退出码 1）且仓内多出未跟踪的 `pnpm-workspace.yaml`：该仓没声明 `onlyBuiltDependencies`/`allowBuilds`，pnpm 11 默认拦截依赖构建脚本；那个 yaml 是 pnpm 生成的 approve-builds 脚手架。`setup.sh`/`remote-install.sh` 已自动处理（无声明即 `--ignore-scripts` 直装，无脚本需要执行）。手工装：`cd harness && pnpm --dir ../plugins/<name> install --frozen-lockfile --ignore-scripts`。注意别用「先普通安装再重试」的套路——被拦截的安装会留下 pendingBuilds 状态，使随后的 `pnpm build` 自动重跑 install（经 corepack 在无 `packageManager` 的仓内回落坏版本，报 `MODULE_NOT_FOUND …/pnpm/12.3.4/…`）。
- 插件仓声明的 `packageManager` 与 harness 不同版本（如 dsh-automation 是 `pnpm@10.32.1`，harness 是 `11.7.0`）：**这是正常的**，不是冲突。corepack 按 cwd 向上解析，在插件目录内自然用插件自己的 pin；`setup.sh`/`remote-install.sh` 的 `plugin_pnpm` 对有 `packageManager` 的仓就在仓内执行，于是各仓各用各的。首次会看到 `! Corepack is about to download …/pnpm-10.32.1.tgz`（需网络）。`check_pnpm` 比对时已剥离 `+sha512…` 后缀。
- `make dev` 报 `listen EADDRINUSE: address already in use 127.0.0.1:3080`：上一次的 DSH 进程还活着。**停掉后台任务只杀 `make` 包装进程，`pnpm dsh … --no-open` 的 `node` 子进程会残留**并继续占端口，容易误判成「新插件导致启动失败」。定位并清理：`lsof -nP -iTCP:3080 -sTCP:LISTEN -t` → `kill <pid>`（确认释放后再启动）。
- 插件的 `dsh.client.inject` 列了一个**不存在的包**（如 dsh-automation 的 `@deepseek-ai/dsh-client-runtime`）：客户端解析是宽松的——`client/modules/src/client/system.ts` 里 `if (dependency !== undefined)`，**找不到就静默跳过**，不影响加载（boot 图里该名字原样透传给浏览器）。排查客户端插件不生效时，别先怀疑这里；先看 `window.__DSH_BOOT__` 里有没有该条目、以及 `/plugins/??<包名>/client.js` 是否返回 200。
