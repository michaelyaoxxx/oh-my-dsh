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
- **harness 升级后插件「挂载正常、一用就炸」**：harness 的插件 API 会跨版本漂移，而挂载/dump/boot 都属于**加载期**验证，查不出**执行期**的不兼容。实例：dsh-automation v0.1.7 用 `const agent = agentCtx.agent` 取 Agent，但 harness 0.1.5-rc.2 起 `AgentSetup = (agentCtx, agent) => …`，Agent 改走**第二参数**、ctx 上不再有 `agent` 服务，于是每次自动化执行都抛 `automation setup has no scoped Agent`。**处置**：先确认签名（`harness/packages/core/agent/src/index.ts` 的 `AgentSetup` 类型 + `harness/packages/core/agent-loop/src/index.ts` 里 `setup?.(prepared.agent.ctx, prepared.agent)` 的调用），改插件源码后**重建产物**。**教训**：升级 harness 后，接入的插件不能只验「能起来」，要真跑一次主功能。
- 插件仓**只有 npm 的 `package-lock.json`**（如 dsh-market），没有 `pnpm-lock.yaml`：不要用 pnpm 装——它会**忽略该 lockfile**（版本解析不可复现）并在仓内生成未跟踪的 `pnpm-lock.yaml` **弄脏 submodule**。`setup.sh` / `remote-install.sh` 已按「有 pnpm-lock 走 pnpm，只有 package-lock 走 `npm ci`」自动分支；手工装用 `( cd plugins/<name> && npm ci --ignore-scripts )`。服务器侧同样接受两种 lockfile（都没有才失败）。注意 npm 分支下构建要写 `npm run build`（`plugin_run "$d" run build` 已统一）。
- 插件仓 `pnpm install --frozen-lockfile` 报 `[ERR_PNPM_LOCKFILE_CONFIG_MISMATCH]`（**且 build 也跟着失败**——pnpm 跑脚本前的依赖校验会重新触发安装）：该仓把 `overrides` 写在 package.json 的 `pnpm` 字段（**pnpm ≤10 的位置**），而 **pnpm 11 已不再读该位置**（迁到了 `pnpm-workspace.yaml`，harness 自己就写在 workspace 文件里）。于是 pnpm 11 看到的 overrides 为空、与 lockfile 里记录的不符而拒绝 frozen 安装；实测 11.7.0 / 11.8.0 / 11.24.0 全部失败，pnpm 10 正常。`setup.sh`/`remote-install.sh` 已按「无 packageManager 且 package.json 有 pnpm.overrides → 用 `corepack pnpm@10.33.0`」自动路由（install 与 build 同一入口，版本可用 `DSH_LEGACY_PNPM` 覆盖）。手工装：`cd plugins/<name> && corepack pnpm@10.33.0 install --frozen-lockfile`。
- 插件仓的 `devDependencies` 写成 **`link:../<某个同级目录>/...`**（如 dsh-at-file 全部指向作者本地的 `../deepseek-harness/...`）：这是**开发者本地布局**，在我们的目录结构下不存在。**pnpm 不校验 link 目标**，所以安装照样 exit 0，只是那些依赖变成**悬空软链**。判断有没有影响看两点：① 根 `main` 是否已提交（已提交则跳过构建、devDeps 永不被用）；② 运行时 `lib/` 里的 harness 包导入能否解析——实测**会**经 DSH 的 profile 模块回退链（`.dsh/profiles/node_modules`）解析成功，boot 无 `ERR_MODULE_NOT_FOUND`。两者都满足就无需处理；若真的需要那些 devDep（例如必须构建），得造出对应路径（如把 `harness/` 另做一个同名软链）或改用 fork 修正依赖。
- **`npm ci` 报 `EBADENGINE` 警告但成功**：传递依赖要求的 Node 版本高于本机（如 rolldown-plugin-dts 要 `^22.18.0 || >=24.11.0`，本机 v24.3.0）。属**警告不阻断**；若随之出现真实构建报错，先把 Node 升到要求的下限再排查。
- **想验证 boot 但 3080 被自己另一个实例占着**：不要抢占端口、也不要共用同一个 `DSH_HOME`（两个实例并发写同一会话库有风险）。改用 `--port 0`（OS 分配空闲端口）+ 复制一份 `DSH_HOME` 到 /tmp 做隔离实例。**注意**：复制后 profile 的 `node_modules` 里那些**相对路径**符号链接（如 `@linxin666/dsh-client-ui-session-id -> ../../../../../plugins/…`）会断，表现为 `cannot resolve profile bundle "…"`；把副本里的链接重写成指向原目标的绝对路径即可：
  ```sh
  cd <原 DSH_HOME>/profiles/dsh/node_modules
  find . -type l | while read -r l; do tgt=$(realpath "$l") && ln -sfn "$tgt" "/tmp/dsh-verify/profiles/dsh/node_modules/$l"; done
  ```
- **插件的修复没法上游、只能在本地背着**（如 dsh-automation 的 `setup` 适配）：在 submodule 内**建分支**提交——submodule 平时处于 detached HEAD，在那里提交虽然也能成 commit，但**没有任何分支指向它**，HEAD 一移动就只剩 reflog 可寻（之后被 gc）。建分支后再提交，恢复与代价：
  ```sh
  git -C plugins/dsh-automation checkout -b adapt/<harness 版本>   # 建分支后提交
  git -C plugins/dsh-automation checkout adapt/<harness 版本>      # make setup 顶掉后恢复
  ```
  - `make setup` 会执行 `git submodule update --init --recursive`，把工作树检出到 pin 提交（detached）——**修复在分支上活着，但工作树里失效**，需按上面第二条命令恢复。
  - 主仓会一直显示 ` M plugins/<name>`，`release.sh` 的干净度检查（`git diff --quiet`，见 `scripts/release.sh:8`）会拒绝发布，直到 fork + push + 更新 pin。
  - 这是 submodule「pin 是显式快照」语义的正常体现：**pin ≠ 工作树 HEAD 时，所有干净度检查都会亮**。
