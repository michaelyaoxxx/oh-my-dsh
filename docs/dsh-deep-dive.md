# DSH（DeepSeek Harness）工作原理 Deep-Dive

> 本文面向 **C/C++ 背景、无 TypeScript 经验** 的开发者，从源码 + 真实日志出发，
> 讲清楚 DSH 的「编译 → bundle/profile 装配 → TS 送进 V8 → 一次 UI↔LLM 往返」全链路。
>
> - 证据纪律：文内 `[S]` = 已读源码锚定；`[I]` = 架构级推理（个别细节未逐行读，已标注）；
>   日志引用均来自本仓 `log/` 下真实产物（2026-09-15 Linux x86-64 实测）。
> - 适用 pin：harness `dsh-v0.1.5-rc.2`。

## 目录

0. [它到底是什么：宿主进程 + 动态装配的一棵树](#0-它到底是什么)
1. [TS 到 V8：谁在翻译、怎么翻译](#1-ts-到-v8谁在翻译怎么翻译)
2. [`make setup` 逐段分解](#2-make-setup-逐段分解)
3. [`make link-plugins` 逐段分解](#3-make-link-plugins-逐段分解)
4. [`make dev` / boot 逐段分解](#4-make-dev--boot-逐段分解)
5. [一次 UI→LLM→回：消息往返全链路](#5-一次-uillm回消息往返全链路)
6. [补充：不应被忽略的关键流程](#6-补充不应被忽略的关键流程)
7. [给 C/C++ 开发者的心智地图与词汇表](#7-给-cc-开发者的心智地图与词汇表)

---

## 0. 它到底是什么

DSH（DeepSeek Harness）不是「一个程序」，而是**一个宿主 Node 进程里，按配置树动态装配起来的一**
**组插件（cordis module）**。把它拆成四块：

```
┌─ 宿主进程（node，一个由 bash 拉起的进程；V8 引擎只执行 JS）
│   ├─ cordis        —— 依赖注入容器 + Fiber 生命周期（“插件的 OS”）
│   ├─ profile       —— 一棵配置树：
│   │                   dsh.profile.bundles(层顺序) + cordis.patch.yml
│   │                   + $DSH_HOME/cordis.patch.yml + --patch 覆盖层
│   ├─ loader/include/group —— 把配置树里的 entry（包名 + inject + config）
│   │                           逐个 import 并按依赖就绪顺序 apply
│   └─ webserver     —— 绑 127.0.0.1:3080，serve index.html + __DSH_BOOT__ 注入
│                        + /api/*（含 WebSocket 路 /api/remote.mux）
└─ 浏览器 web 前端 —— 也是 cordis 客户端树：__DSH_BOOT__（BootManifest）
        → client module system → uiRenderer 挂壳
```

### 给 C/C++ 开发者的第一口心智

| DSH 概念 | C/C++ 里的类比 |
| --- | --- |
| cordis Context / 插件树 | DI 框架 + 运行时动态加载器 |
| profile | 链接脚本 / 配置文件（决定把哪些模块拼起来） |
| 插件（bundle） | 可动态 loading 的共享库（.so/dll） |
| `dsh.bundle.patch` / `inject` | 模块的“导出符号 + 依赖符号表”声明 |
| loader entry | 链接器从符号表解析出的一块可执行单元 |
| `make setup` | 拿到源码、装工具链、编译出所有 .so（vram） |
| `make link-plugins` | 把编译好的 .so 注册进“可加载清单” |
| `make dev`（boot） | 加载器按清单把 .so 动态链接成最终可执行树并运行 |
| turn / step / tool call | 任务调度的一次循环 / 一次迭代 / 一次系统调用 |
| SSE / WebSocket | 流式 stdout 回给调用方 |

**一句话**：你用 `make setup/link/dev` 做的，是「备料 → 登记 → 动态链接并运行」三步，而整个产品逻辑都在这棵树里。

---
## 1. TS 到 V8：谁在翻译、怎么翻译

### 1.1 事实地基：V8 只吃 JavaScript

V8（Google 的 JS 引擎，Node 的内核）只执行 **ECMAScript**。TypeScript 里的类型注解、`interface`、
泛型、`enum` 在运行前必须被**擦掉**（type erasure）并**降级**成普通 JS。所以“把 TS 送给 V8”
不是一步，而是一条**合署工具链**：

| 工具 | 干什么 | 真实日志证据（log/setup-20260915T110859Z-258716.log） |
| --- | --- | --- |
| **tsc** | 编译期：类型检查 + `.ts → .js`（擦类型）+ 产 `.d.ts` + `.tsbuildinfo`（增量缓存） | `node --max-old-space-size=4096 ./node_modules/typescript/bin/tsc -b tsconfig.host.json` |
| **tsdown** | 把成百上千个 `.js` 模块按包**打包**成单文件（bundle），tree-shake / 代码分割，出 CJS | `ℹ [@deepseek-ai/dsh-experimental-webworker-runtime] [CJS] 2 files, total: …`；`✔ Build complete in …` |
| **vite** | 打**前端资源**（给浏览器用的最终 bundle） | `vite v6.4.3 building for production…`；`build: recorded 234 client artifact(s)` |
| **tsx** | **开发期**按需转译：对 `.ts` 在“导入时”用 esbuild 转成 JS 再交给 Node | `pnpm dsh` = `node --import tsx/esm apps/cli/src/bin.ts` |

### 1.2 合并后的管道（以 harness 的 `pnpm build` 为例，见 `harness/scripts/build.ts`）

`build.ts main()` 依次跑三件事（每步一个 `spawnSync pnpm run …`）：

```
build:native-system  → tsx native/system/scripts/build.ts --host-addon-only
                       （编 C 原生插件 .node，见 §1.4）
build:lib            → build:lib:host = tsc -b tsconfig.host.json && tsdown --env.DSH_BUILD_FACE host
                       build:lib:client = tsc -b tsconfig.client.json && tsdown --env.DSH_BUILD_FACE client
                       （TS 编译 + 打包成 CJS，host/client 两面）
build:web            → pnpm --filter @deepseek-ai/dsh-web-frontend run build（vite）
写记录              → writeClientBuildRecord：产 build record（234 artifacts + 环境值），
                      供后续 boot 把 manifest 注入 __DSH_BOOT__
```

对照日志（setup 日志第 71–76 行附近 + Build complete 段）：
`==> 构建: harness` → `$ tsx scripts/build.ts` → `$ tsx native/system/scripts/build.ts --host-addon-only` →
`build: built linux-x64/bin/glibc/system.node` → `$ pnpm run build:lib:host && pnpm run build:lib:client` → … →
`vite build` → `build: recorded 234 client artifact(s) with 2 public value(s)`。

### 1.3 两条运行形态：dev（tsx 转译）vs 产物（lib/ 纯 JS）

- **dev / 源码运行**：`pnpm dsh` 走 `node --import tsx/esm apps/cli/src/bin.ts`。Node 的 **ESM loader
  管线**里，tsx 注册了 `resolve`/`load` hook：遇到 `.ts` 就当场转译成 JS，然后**同一个 ESM loader
  把 JS 交给 V8**。所以 bin.ts 这类入口**不需要先 tsc 也能跑**——这就是“源码即运行”。
  代价：每次启动按需转译，较慢；但它保证了 dev 与源码一致。
- **产物运行**：`tsc/tsdown` 产出的 `packages/*/lib/*.js`、`apps/cli/lib` 已是**纯 JS**，生产/部署直接加载，
  不经过 tsx，也不需要类型检查。两种形态的代码路径可以不同（这正是 B10 那条“解析面不止一个”教训的土壤）。

### 1.4 V8 与 Node 运行时（C/C++ 视角）

```
node 进程
 ├─ V8    ：JS 源码 → Parser(AST) → Ignition 字节码(解释执行) → TurboFan JIT(热点编译成机器码)
 ├─ libuv ：事件循环 / 线程池（异步 IO 的真正执行者）
 ├─ node:* 内建模块（fs/http/zlib/crypto…，C++ 实现，稳定 ABI）
 └─ N-API ：原生插件与 V8 之间的稳定 C ABI（macOS 上即 node_api.h）
```

给 C/C++ 的对位：
- **tsc ≈ 编译（.o = lib/*.js）**：类型擦除 + 降级。
- **tsdown ≈ 链接**：把一堆 .js 揉成一个 CJS 模块文件 + source map（对应你的符号表/重定位）。
- **tsx ≈ “解释执行源文件”**：像 gdb 直接跑没编的 .c（背后是 esbuild 转译，进 V8 前已是 JS）。
- **Ignition/TurboFan ≈ 解释器 + JIT**：先字节码解释，跑热了编成机器码。
- **N-API `.node` ≈ 共享库**：JS 侧通过稳定 ABI 调 C 函数。

### 1.5 原生插件（本仓真实例子：flock / landlock-run）

`harness/native/system/scripts/build.ts`：
- 读取各 `native/system/packages/<name>/prebuilds.json` 的平台/二进制声明；
- **flock**（Node-API 8）：`cc -std=c11 -O2 … -fPIC -shared -DNAPI_VERSION=8 -I<node>/include/node`
  → `linux-x64/bin/glibc/system.node`（日志 `build: built linux-x64/bin/glibc/system.node`）。
  它提供文件锁等系统能力，JS 侧经 N-API 调用。
- **landlock-run**：静态 musl 可执行（需 musl-gcc），不是 .node。
- 头文件相对 `process.execPath` 解析（`dirname(execPath)/../include/node`）——setup.sh 第 30–33 行前置校验的就是它，
  缺了就报“Node-API headers missing”。

> **一句话**：TS→JS 是“编译时/导入时”做的，V8 永远只看到 JS；原生能力通过 N-API 的 C 函数补上。

---
## 2. `make setup` 逐段分解

> 依据：`scripts/setup.sh`（工具链/子模块/pnpm 解析/计划）→ `scripts/prepare-executor.sh`（准备动作唯一实现）→
> `config/components.json`（谁参与，唯一事实源）+ 日志 `log/setup-20260915T110859Z-258716.log`（4989 行，2026-09-15 Linux x86-64 实测）。
> 它回答“这 11 个仓库的源码怎么被拉下来、怎么编译出来”。

### 阶段 1：工具链前置校验（setup.sh 第 11–33 行）

依次硬性检查，缺一个就给出可执行处置后 `exit 1`：

1. `node` 存在，且 `^22.19 || >=24`（`node -e` 判 `process.versions.node`，23 不满足）。
2. `corepack` 存在（Node ≥25 不再自带，需 `npm i -g corepack`）。
3. `cc` 存在（macOS `xcode-select --install`；Debian/Ubuntu `build-essential`）。
4. Node 开发头文件存在：`dirname(execPath)/../include/node/node_api.h`（fnm/nvm 自带；发行版包另装 nodejs-dev）。

> 这四条对应第 1.4/1.5 章：harness 的 `build:native-system` 要 `cc` + node_api.h 才能编 `.node` 原生插件。

### 阶段 2：submodule 递归拉取/更新（setup.sh 第 35–42 行）

```sh
mkdir -p plugins
.git submodule sync --recursive   # 把 .gitmodules 的 URL 同步进 .git/config
```
**先 sync 再 update**：若某 submodule 的 URL 刚在 .gitmodules 改过（本仓 dsh-automation 改指过 fork），update 会先拿旧 URL 拉取而失败。
日志证据（开头几行）：`Submodule 'harness' (https://…) registered` → `Cloning into '…'` → `Submodule path '…': checked out '…'`。
结果：**全部 submodule（含嵌套）停在 pin commit（detached HEAD）**。

### 阶段 3：各仓 pnpm 版本解析（setup.sh 第 44–94 行）

关键函数：

- `expected_pnpm(dir)`：读该仓 `package.json.packageManager`（不硬编码版本，随 pin 漂移）。
- `actual_pnpm(dir)`：在仓内跑 `pnpm --version`（容忍失败返回空串）。
- `check_pnpm(dir)`：期望=实际（剥掉 `+sha512` hash 后缀）。
- `verify_all_pnpm()`：遍历 `harness plugins/*/`，任一不匹配 → 尝试 `corepack enable` 再验；
  失败则给出「网络不可达 / COREPACK_HOME 不可写 / shim 未优先」的排查提示。

日志证据（第 46–56 行）：`==> harness 使用 pnpm@11.7.0`、`plugins/dsh-automation 使用 pnpm@10.32.1`、
`plugins/loongsuite-observability 使用 pnpm@10.28.2` —— **每个仓解析到自己声明的 pnpm**，这正是“不依赖全局 pnpm”的核心。

### 阶段 4：组件目录校验 + 生成准备计划（setup.sh 第 209–305 行）

1. `node scripts/check-components.mjs`：与 `.gitmodules` **双向集合校验** + license 词表 + 与子仓 `package.json` 的 license 声明核对。
2. `node scripts/check-components.mjs --require-materialized`：**严格模式**——子仓未初始化即失败（fail-closed）。
3. `node scripts/check-components.mjs --plan prepare`：按具名选择器 `prepare`（= `runtimeScope: required`）
   输出 `<path>\t<prepareMode>` 计划；dsh-tui（`runtimeScope: excluded`）不在计划里。
4. **空计划断言**（fail-closed）：计划为空直接报错退出（防止“目录写错导致一个都不装”被当成成功）。

日志证据：`✓ 组件目录校验通过：11 个组件，与 .gitmodules 双向一致`（license 11 一致；materialized 10 已验；dsh-tui excluded）。

### 阶段 5：逐个组件准备（prepare-executor.sh `prepare_component`）

`setup.sh` source 了 `scripts/prepare-executor.sh`，并注入两个**环境策略钩子**（B11 里说的“唯一该有差异”）：

- `pe_install <rel> <frozen|nonfrozen>`（setup.sh 254–272）：
  - **harness** → `local CI=true; export CI`：以「submodule 无 hooks」为由跳过 lefthook postinstall（该钩子在 harness 作为 submodule 时必然失败）。
  - **插件** → `local TMPDIR=/tmp; export TMPDIR`：绕某插件的 unix socket 长路径（macOS 的 sun_path 104 字节限制；Linux 本来就是 /tmp）。
  - 有 `pnpm-lock.yaml` → `install --frozen-lockfile`；只有 `package-lock.json` → `npm ci`；都没有 → 非冻结 `pnpm install` + 告警。
- `pe_run_build <rel>`：非 harness 时同样设 `TMPDIR=/tmp`；对 `source-build` 组件执行 `pnpm run build`。

`prepare_component`（prepare-executor.sh 18–48）按 `prepareMode` 四值派发：
`none` 跳过 / `install-only` 只装 / `source-build` 装+构建 / `tracked-prebuilt` 只装运行依赖、**不构建**
（入口跟踪状态由 `check-components.mjs` 校验，不在这里重复实现）。

底层安装函数（setup.sh）：`plugin_install`（含 `has_build_policy` 判定；无 build 政策加 `--ignore-scripts`；
被 pnpm 拦 `ERR_PNPM_IGNORED_BUILDS` 时重试；`overrides` 写在 package.json（pnpm≤10 位置）的仓走 legacy `pnpm@10.33.0`）。

### 阶段 5 日志走读（真实顺序，setup 日志）

```
==> 安装依赖: harness（nonfrozen）
==> 构建: harness
$ tsx scripts/build.ts
$ tsx native/system/scripts/build.ts --host-addon-only
build: built linux-x64/bin/glibc/system.node
$ pnpm run build:lib:host && pnpm run build:lib:client
$ tsc -b tsconfig.host.json / tsdown --env.DSH_BUILD_FACE host   # 反复 Build complete × N 包
… vite build → build: recorded 234 client artifact(s) with 2 public value(s)
==> 安装依赖: plugins/dsh-web（nonfrozen）      # 16 家族包并行 build
==> 安装依赖: plugins/dsh-better-sidebar …
==> plugins/dsh-market 使用 npm（package-lock.json）…
==> plugins/dsh-agent-teams overrides 写在 package.json…经 pnpm@10.33.0 执行
==> 跳过构建: plugins/dsh-automation/…（tracked-prebuilt）
setup 完成。运行 make dev 启动 DSH Web。
```

**阶段 5 结论**：setup 把每个仓“准备好”（源码在 pin + 依赖装好 + 需要构建的构建完），但**不装配 profile**。

---
## 3. `make link-plugins` 逐段分解

> 依据：`scripts/link-plugins.sh` + `apps/cli/src/plugin.ts`（`dsh plugin` 转发器）+ 日志
> `log/link-plugins-20260915T111629Z-328055.log`（122 行）。它回答“源码插件怎么被登记进 profile 的 bundles 层”。

### 阶段 1：排除集（link-plugins.sh 40–47 行）

`node scripts/check-components.mjs --list runtime:excluded` → SKIP_MOUNT。
日志第 2 行：`==> 跳过挂载: plugins/dsh-tui（runtimeScope=excluded，原因见 config/components.json）`。
> ⚠️ 这里的**判据是 `runtimeScope=excluded`**，不是 `prepareMode=none`；查询失败必须 exit（fail-closed，曾用 `|| true` 退化成空排除集把 web 环境弄坏）。

### 阶段 2：前置 + corepack 锚点（link-plugins.sh 53–76 行）

- 检查 `harness/package.json` 与 `harness/node_modules` 存在（没构建就先 `make setup`）。
- 在 `$DSH_HOME/package.json` 写 `packageManager` **锚点**：`dsh plugin` 在 profile 目录里 spawn `pnpm`，
  corepack 向上找不到 package.json 会回落 latest（坏版本），锚点钉住 harness 自己用的 pnpm 版本。
- `export COREPACK_DEFAULT_TO_LATEST=0`：宁可报错也不回落 latest。

### 阶段 3：候选收集与“是否可挂载”判定

遍历 `plugins/*` 根 + `packages/*` 子包；`own_patch(dir, …子包…)`（一个 node 脚本）判：
`dsh.bundle.patch` 声明存在，且 patch 文件落在**该包自己目录内**、且不落在任意子包目录内。
dsh-web 根包的 patch 指向 `packages/dsh-web-all/cordis.patch.yml`（包外）→ 根包不是挂载入口，其聚合包 `@linxin666/dsh-web-all` 才是。

### 阶段 4：逐一 `dsh plugin --profile dsh add link:<绝对路径>`

这是**真正把插件装进 profile** 的一步，链路过 `apps/cli/src/plugin.ts`：

1. `runPlugin(profile, args)`（plugin.ts 120–163）：`resolveProfileDir` 找 `.dsh/profiles/dsh/`；首用则 `initProfile`（模板 bundles/patchReload）。
2. `anchorPathSpec(arg, cwd)`（104–112）：把相对路径 spec（`.`/`..`）锚到**调用方目录**，防 `add .` 把 profile 自己 link 进去；`link:`/`file:` 前缀保留。
3. `spawnSync('pnpm', ['add','link:/abs/…'], { cwd: profileDir })`：pnpm 以 `link:` 协议装成**符号链接**（改源码即时生效）。
4. `reconcilePlugins(before, dir)`（59–91）：**按已装状态对账**——对每个已装依赖 `exportsPatch(name, dir)`（`resolveBundleDir` 找到包 + 读 `manifest.dsh.bundle.patch`），
   声明了 `dsh.bundle` 的 → append 进 `dsh.profile.bundles`；声明没了/被删的 → 从 bundles 移出；模板 bundle（dsh-base 等）不受影响。

日志证据：每条 `==> link <name> <- <路径>` → `$ dsh plugin --profile dsh add link:…` → `+ <name> link:/abs/…` → `Done in …ms using pnpm v11.7.0`。
共 10 条（agent-teams / at-file / automation / better-sidebar / market / session-id / web-all / loongsuite / modlens / modsearch）。

### 阶段 5：家族成员跳过

`DEP_NAMES` 收集所有候选的 dependencies/peerDependencies/optionalDependencies 包名；
同仓 workspace 子包若被某个**已挂载的聚合包**引用 → 不单独挂载（聚合包 link: 会经其 node_modules 带出本地构建）。
日志 121 行：`跳过 16 个家族成员…`。

### 阶段 6：合并托管 patches

`node scripts/merge-profile-patch.mjs "$DSH_HOME/profiles/dsh"`：把 `patches/*.yml`（禁用插件/注入/补旁键）幂等合并进 profile 的 `cordis.patch.yml`。
日志 119 行：`已合并 patches/*.yml → …/profiles/dsh/cordis.patch.yml`。
> ⚠️ patch 的 `config`/`inject` 是**整表替换**非深合并——这正是 modsearch 曾整表替换 web 行配置、要靠
> `restore-web-fetch-provider.yml` 补旁键的坑（见 §6.2）。

### 阶段 7：保证 web 宿主在 bundles 里

node 小脚本把 `@deepseek-ai/dsh-web-app` splice 到 `dsh-base` 之后（缺失时组合树没有 webserver，boot 完不绑 3080）。
日志 120 行：`已确保宿主 bundle @deepseek-ai/dsh-web-app 在 profile bundles（base 之后）`。

**完成标志**：日志 122 行 `完成: 已挂载 10 个 bundle 到 profile dsh（DSH_HOME=…/.dsh）`。

---
## 4. `make dev` / boot 逐段分解

> 依据：Makefile `dev` 目标 + `apps/cli/src/bin.ts`/`args.ts` + `apps/cli/src/profile-boot.ts` +
> `packages/boot/app-boot/src/index.ts` + `packages/client/web/src/boot.ts` + dev 日志样本
> `log/dev-20260915T111700Z-sample.log`（即为 2026-09-15 实测 boot：`dsh web: http://127.0.0.1:3080/?token=…`）。

### 阶段 0：Makefile dev 到底跑了什么

```sh
mkdir -p log
{ bash scripts/link-plugins.sh && \
  cd harness && DSH_HOME="$(CURDIR)/.dsh" CI=true pnpm dsh --profile dsh --no-open; } 2>&1 | tee log/dev-*.log
```
先 **link-plugins**（保证挂载最新），再以 `DSH_HOME=./.dsh` 启动。`CI=true` 与 setup 同理（跳过 submodule 下失效的 hooks）。
`--no-open` 不自动开浏览器；`pnpm dsh` 的实义见下。

### 阶段 1：命令解析（apps/cli/src/bin.ts + args.ts）

```ts
// bin.ts runCli()
const invocation = parseDshArgs(process.argv.slice(2), readVersion())
switch (invocation.mode) {
  case 'profile': await runProfile({ environment: loadLayeredEnv('dsh'), profile: 'dsh', … })
  case 'plugin'   …  case 'dump-config' …
}
```
- 进程入口：`node --import tsx/esm apps/cli/src/bin.ts`（§1.3 说的 dev/tsx 形态）。
- `parseDshArgs`：launcher 只解析自己的旗标（`--profile`/`--patch`/`--dump-config`…），
  之后的参数**原样**留给被装配进树的应用插件（各自解析、各自 `--help`）。

### 阶段 2：环境分层（app-boot loadLayeredEnv + resolveDshHome）

继承 env > 项目 `.env` > `$DSH_HOME/.env`（不覆盖已存在的）；bootstrap-only 变量禁在 .env 里写（会拒）。
结果是一份**冻结的环境快照**，通过 `ctx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, …)` 给大家读同一份。

### 阶段 3：boot 与“把配置树拼成树”

`profile-boot.ts runProfile` 关键装配：
- `resolveProfileDir(profile)` → 缺则 `initProfile`（模板）。
- 收集 patch 层（顺序=层叠语义，后层覆盖前列）：`bundlePatches`（按 `dsh.profile.bundles` 序，每层 = 包的 cordis.patch.yml）→
  profile `cordis.patch.yml` → `$DSH_HOME/cordis.patch.yml`（机器级偏好）→ `--patch` 覆盖层；
  用 `structuredClone` 深克隆防“insert 行被后续 patch 原地改”的别名问题。
- `boot(NAME, rootConfig='[]', patches, …)`（app-boot）：新建 cordis `Context`，装 **Loader/Include/Group**，
  在空根配置上**逐层 apply patch**，挂上 `provideCmdline`（args/exit/ready），随后 `loader.await()` 等树稳定。
- 若 `patchReload: 'live'`：额外装 `cordis-plugin-hmr`（watch-only，root 空）并 watch 两个用户 patch 文件 → 改 `cordis.patch.yml` 热生效。

### 阶段 4：cordis 树怎么“活”起来（Fiber / inject）

每个 entry 一个 **Fiber**：声明 `inject: [服务名]` 的，等对应 service 就绪才 apply；`provide` 的服务可被注入。
这层是**插件依赖拓扑的执行引擎**，也是我们踩过的 B13 竞态的所在层（见 §6.7）。

### 阶段 5：web 宿主与 boot 注入

装配后树里出现（对照 `--dump-config`）：`web-startup`（host/port 默认 127.0.0.1:3080）→ `webserver`（@deepseek-ai/dsh-host-webserver）→
`web-runtime`/@deepseek-ai/dsh-web-app（openBrowser/printUrl/trustedHosts）→ `client-modules`（@deepseek-ai/dsh-client-modules，
扫描 client 包、合成 `__DSH_BOOT__` manifest、把 `/plugins` 路由挂到 webserver）。
日志样本：`dsh web: http://127.0.0.1:3080/?token=1mQX…`。
认证语义：`/` 无 token → **401**（认证 gate 在即服务就绪）；带 `?token=` → 303/200；token 每次启动轮换。

### 阶段 6：浏览器侧 boot（packages/client/web/src/boot.ts）

`AppWebEntry.run()`：等 `__DSH_BOOT_READY__` → `win.__ModuleLoader__.create({ boot })`（ClientModuleSystem，
能按名加载字节）→ 建 cordis Context + `ctx.plugin(Loader)`、`loader.internal = modules` → 按 manifest 逐 entry `loader.create` →
`loader.await()` → `assertEntriesActive` → `ctx.inject(['uiRenderer'], scope.effect(….mount(container)))` 挂壳。
**浏览器里也跑一套 cordis client 树**，与宿主共享同一份 manifest —— 这就是“前端即插件的客户端镜像”。

---
## 5. 一次 UI→LLM→回：消息往返全链路

> 标注：`[S]` 已读源码锚定；`[I]` 架构级推理（个别 RPC 细节未逐行读，标出供复核）。
> 相关包：`client/ui-chat`、`client/connection`、`api/gateway`、`api/session-controller`、`core/agent-loop`、
> `core/agent`、`llm/llm-deepseek`、`session` / `session-query-sqlite`。

```
[1] 浏览器：ui-chat 输入框 → client-connection（rpc.ts / http-bridge.ts，含 browser-auth）
[2] 传输：经 webserver → 同源 WebSocket 路 /api/remote.mux（Typert Remote 流；帧 ready/emit/waterfall/cancel）
[3] 会话：api/session-controller（sessions/manager + agent.ts：createOrAdopt / composeAgent / agents.create）
[4] 执行：core/agent-loop（AgentLoop implements AgentFactory → ReactLoopAgent：inbox→assistant-stream→loop）
[5] LLM：llm/llm-deepseek adapter.ts：fetch(baseURL + /chat/completions, accept: text/event-stream) → parseSse
[6] 回程：assistant 增量 → 事件帧经 WS 下行 → ui-chat 流式渲染（tool 卡片、增量）
[7] 状态：dsh-session 事件日志（SessionSeq）→ session-query-sqlite；OTLP/用量挂在事件上
```

### 步骤细节与源码锚点

1. **[S] 浏览器端**：`packages/client/web/src/boot.ts` `AppWebEntry.run()` 把 UI 树跑起来后，输入走
   `@deepseek-ai/dsh-client-connection`。连接层含 `rpc.ts`（RPC 请求/响应）、`http-bridge.ts`（HTTP 管线）、
   `browser-auth`（把 boot 得到的 token 附到请求上）。

2. **[I/S] 传输（Typert Remote 流）**：`packages/api/gateway/src/stream-protocol.ts` 定义 WebSocket 复用路
   `REMOTE_STREAM_MUX_PATH = '/api/remote.mux'`（第 6 行），帧分 `ready` / `emit`（宿主→客户端事件）/ `waterfall`
   （宿主要客户端“回调”某事件）/ `cancel` / result。这就是 host↔client 的双向流式总线。
   > [I] 具体“发消息”的 HTTP/WS 端点（session-controller 的 run/resume 入口）未逐行读实现，
   > 只锚定了它所属的包与 gateway 的帧协议；要精确到方法名可再深一寸。

3. **[S] 会话→Agent**：`packages/api/session-controller/src/agent.ts`：`createOrAdopt(sessionId, cwd, presetId)`
   → 查 live Agent / 持久化身份（`cwd`/`preset` 冲突就抛）→ `composeAgent(preset)` 组 Agent 装配
   （`installModelSelection` + preset 的 setup）→ `this.ctx.agents.create/resume`。模型取自
   `ctx.agentDefaultModel.currentSelection()` → `{ provider, model }`（`agentOptions()`，第 490–493 行）。

4. **[S] AgentLoop（执行循环）**：`packages/core/agent-loop/src/index.ts`：`AgentLoop extends Service implements AgentFactory`
   （第 359 行）→ `packages/core/agent-loop/src/agent.ts` 的 `ReactLoopAgent`：inbox 收请求 → assistant-stream 增量 →
   循环调 LLM；期间发 `turn/start`、`step/start`、`step/end`、`turn/end` 事件
   （对应 `turnBoundaryProjectionDefinition`，index.ts:56–94，写进 Session 事件日志）。

5. **[S] LLM 调用**：`packages/llm/llm-deepseek/src/adapter.ts`：`fetch("${connection.baseURL}/chat/completions", …)`
   （第 651 行），请求头 `accept: text/event-stream`（第 542 行）→ `response.body` 走 `parseSse`（sse.ts）把 SSE 行流
   解析 → `translate` 成 assistant 事件流（async generator）。上层 `llm/llm` 提供抽象、`retry-policy`、错误归一化。
   **baseURL / apiKey 来自 profile 配置（dsh-settings / 凭据），不在本文展开。**

6. **[I/S] 回程**：assistant 增量经 gateway 的 `emit` 帧从 WS 下行回浏览器（Typert Remote 的“事件流”），
   `ui-chat` 用流增量渲染（token、tool 卡片、reasoning），不需要整条消息结束后才显示。

7. **[S] 持久化/查询**：`packages/session`（事件日志 + SessionSeq 序号）、`packages/session-query/session-query-sqlite`
   （会话查询）、`packages/session/session-title-*`（LLM 起标题）、loongsuite 插件把 session/agent/LLM/tool
   生命周期转 OTLP（见 §6.4）。

### 与 C/C++ 的对位

第 3–5 步等价于“事件驱动调度器 + 任务循环”：host 侧 cordis 事件总线 = 消息队列/订阅发布；AgentLoop =
任务调度循环（每次 turn 一个任务，step 是迭代）；tool call = 可扩展的系统调用；SSE/WS = 流式 stdout 回给调用方。

---
## 6. 补充：不应被忽略的关键流程

### 6.1 组件目录 / 门禁闭环（改任何“谁参与”之前）

`config/components.json` 是唯一事实源。`scripts/check-components.mjs` 与 `.gitmodules` **双向集合校验**；
改组件集合或 license 后必须 `node scripts/gen-notices.mjs` 重出声明（`THIRD-PARTY-NOTICES.md` 是合规文档，
`make check` 的 `--check` 会拒绝过期版本）。license 走**受控词表**，登记 AGPL/GPL 直接拒。
`make check` = 离线组（目录/license/notices/两道门禁回归）+ 联网 pin + shellcheck（0.9.0）。

### 6.2 patches 的“整表替换”语义

`cordis.patch.yml` 的 `config`/`inject` 是**整表替换非深合并**。坑的实例：modsearch 的 patch 整表替换 web 行
配置，抹掉旁键 → 靠 `patches/restore-web-fetch-provider.yml` 补回。改 patches 后要
`dsh --profile dsh --dump-config` 核对，别只看 boot 没炸。

### 6.3 profile 模块回退链

`healProfilesModuleFallback` + `$DSH_HOME/profiles/node_modules`（NODE_PATH 式回退）：
@deepseek-ai/dsh-web-app 宿主、cordis 系列（group/include/loader/hmr）从这里解析，不装成 profile 依赖。
`@deepseek-ai/dsh…web-app` 是符号链接指向 `harness/apps/cli/node_modules/…`，拷贝 DSH_HOME 到别处会断（见 plugin-dev.md）。



### 6.4 可观测与 telemetry

- 宿主内建 `session-telemetry-otel`（`DSH_TELEMETRY_MODE` 控制，生产默认 DISABLED）。
- `plugins/loongsuite-observability`（pin v0.1.2）：把 session/agent/LLM/tool 生命周期转 OTLP/HTTP protobuf 外发；
  `captureContent` 默认 false（不外发提示词/结果）。生产化边界见 `docs/observability/README.md`。

### 6.5 TUI / 部署两个旁支

- **TUI**：`make dev-tui` → `scripts/link-tui.sh` 建**独立 profile `tui`**（两个前端抢同一批 base 行，不能同 profile）。
- **部署**：`make deploy` → `deploy/remote-install.sh`（Linux 服务器）——与 setup **共用** `prepare-executor.sh`；
  B11 指出“动作原语仍两份”（setup 与 remote-install 各一份、无门禁保证同步）。当前 `make deploy` 从未端到端跑通（backlog B3）。

### 6.6 pin 语义与发版

tag pin：gitlink SHA 必须等于 `<tag>^{}`；branch pin：必须可从 origin/<branch> 到达（不要求等于分支头，
避免“落后即失败”）。漂移由 `--drift` 报告不阻断（dsh-web 落后 231 提交是信息不是错误）。
`make release` 由你手动执行（校验 pin→打 tag→push）；CI 冒烟通过后出 GitHub Release（预留通路）。

### 6.7 已知坑（2026-09-15 实测）

- **B13 boot 竞态**：`ClientModuleRegistry` 只 `inject ['loader']`，但构造时若 `webServer` 已就绪就走 else 分支
  属性访问 → `cannot get property "webServer" without inject`（`harness/packages/client/modules/src/index.ts:570-577`）。
  偶发、非平台特有；**重跑一次 boot 即可**。
- **B10 解析面**：vendor 包按裸名注册，`barePackageManifest` 解析不到就 throw 且不进日志（已用 patch 禁用肇事插件）。

---

## 7. 给 C/C++ 开发者的心智地图与词汇表

### 词汇表

| 词 | 含义 |
| --- | --- |
| TS / tsc | TypeScript 源码 / 编译成 JS+声明文件的编译器 |
| tsdown / rolldown | 打包器：把 N 个 JS 模块合成单文件（CJS/ESM）+ 产物 |
| vite | 前端资源打包/开发服务器（web client） |
| tsx | dev 期按需转译 .ts 再喂给 Node ESM loader |
| V8 | 真正执行 JS 的引擎（Ignition 解释 + TurboFan JIT） |
| ESM / CJS | JS 的两种模块系统（import/require）；本仓打包成 CJS 产物 |
| Node-API(.node) | 原生插件与 V8 的稳定 C ABI（N-API 8） |
| cordis | DI 容器 + Fiber 生命周期（插件树） |
| profile | 一棵配置树（bundles 层 + cordis.patch.yml + 用户层） |
| bundle | 声明了 `dsh.bundle.patch` 的可装配插件层 |
| inject / provide | “依赖哪些服务” / “提供哪些服务” |
| entry / loader | 配置树里的装配单元 / 加载器 |
| turn / step | 一次任务循环 / 一次迭代（事件流里的编排单位） |
| SSE / WebSocket | 流式下行 / 双向实时通道 |
| Typert Remote | 本仓 host↔client 的流式 RPC 帧协议（/api/remote.mux） |
| OTLP | OpenTelemetry 传输协议（可观测出口） |

### 排查心智：三层叠

```
① 源码形态（tsx 转译面）   —— boot 里 import .ts 时
② 产物形态（lib/ 纯 JS）   —— tsc/tsdown 产物，直接加载
③ 装配形态（配置树 + inject）—— cordis/loader 决定谁先 apply
```
同样一个“加载失败/缺服务”，在①②③ 三个面长得三样（B10/B13 分别演示了②③）。
先分清你看到的是哪一面的错，再往对应面查：①查 tsx/tsc ②查 bundle 产物路径 ③查 `dsh --dump-config` 与 inject 声明。

---

## 附：关键证据索引

- 日志：`log/setup-20260915T110859Z-258716.log`（4989 行）、`log/link-plugins-20260915T111629Z-328055.log`（122 行）、
  `log/dev-20260915T111700Z-sample.log`（boot 样本，含 `dsh web: http://127.0.0.1:3080/?token=…`）。
- 脚本：`scripts/setup.sh`、`scripts/link-plugins.sh`、`scripts/prepare-executor.sh`、`scripts/check-components.mjs`。
- harness 源码：`apps/cli/src/{bin,args,plugin,profile-boot}.ts`、`packages/boot/app-boot/src/index.ts`、
  `packages/client/{web/src/boot.ts,modules/src/index.ts,connection/src/*}`、`packages/api/gateway/src/stream-protocol.ts`、
  `packages/api/session-controller/src/agent.ts`、`packages/core/agent-loop/src/{index,agent,inbox,assistant-stream}.ts`、
  `packages/llm/llm-deepseek/src/{adapter,sse}.ts`。
- 本文所有“已验证”均指 2026-09-15 在 Linux x86-64（Ubuntu 24.04）真实执行 + 真读源码得到；
  标 `[I]` 处请以源码复核为准。
