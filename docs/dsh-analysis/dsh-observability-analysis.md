# DSH 可观测性分析

> 运行时观测架构、分层观测方案与调查方法论。
> 本文是重写版：吸收了一份基于官方 master 快照 `0d1f5000` 的外部源码锚定分析中有价值的内容，
> 逐条对照本仓 pin 的 harness 源码（`fb2c4b9e`）核验后成文；核验过程与取舍记录见 §0。
> 操作层速查见姊妹篇 [dsh-observability-quickref.md](dsh-observability-quickref.md)；
> 构建细节见 [dsh-build-analysis.md](dsh-build-analysis.md)。
>
> 证据约定：**[S]** 源码锚定（`harness/` @ `fb2c4b9e`，注 `file:line`）；**[验]** 本机实测；
> **[I]** 推断（语义链成立但未实测）；**[外]** 外部报告说法，本仓未核实，已隔离不采用。

---

## 0. 对外部分析报告的核验记录（去伪存真）

外部报告的突出贡献是**证据边界意识**（明确区分「已验证 / 架构级确认 / 未验证」），以及
Profile 层叠顺序、Cordis 事件语义、构建串行性等论断——这些经本地源码核验**成立**。
但它是为「官方 master 快照 + 通用用户」写的，直接搬进本仓会把几处结论带偏。逐条处置：

| 外部论断 | 本地核验结果 | 处置 |
| --- | --- | --- |
| 应优先用 `dsh --profile web --dump-config`，`--profile dsh` 只在「本地存在名为 dsh 的自定义 profile 时」才成立 | **本仓正是这种情况**：`scripts/link-plugins.sh` 生成本仓自有 profile `dsh`（`make dev` 用它），外部报告自己也给了这条豁免 | **拒绝修正**：本仓所有命令保持 `--profile dsh`；`web` 只是官方内置模板（`apps/cli/src/args.ts:175` 硬编码 alias） |
| 根构建各分支并行 | 不成立：`scripts/build.ts:18-29` 用 `spawnSync` 严格串行，`:43-47` 顺序执行 | 采纳（修正旧认知） |
| 默认完整构建 landlock + flock | 不成立：`package.json:53` 的 `build:native-system` 带 `--host-addon-only`，`native/system/scripts/build.ts:46` 过滤掉非 Node-API 目标（landlock-run 是 static-musl，被跳过） | 采纳（修正） |
| build record 与 web build 并行写入 | 不成立：`scripts/build.ts:43-47` 先删旧 record，全部构建成功后才 `writeClientBuildRecord` | 采纳（修正） |
| record 的产物 pattern「至少含 `client.*.js(.map)`」 | **多写了**：实际只有 3 条（`harness/scripts/client-build-environment.ts:35-39`：`apps/web/dist/**/*`、`packages/*/*/lib/client.js(.map)`） | 采纳并再修正 |
| Cordis 五种事件分发模式（emit/waterfall/parallel/serial/bail）及各自语义 | 成立：`vendor/cordis/src/events.ts:32` 的 `DispatchMode` 与 `:183-243` 实现逐一吻合 | 采纳 |
| 层叠顺序 bundles → profile patch → home patch → CLI `--patch`；patch 整表替换 config | 成立，有官方原文：`docs/architecture.md:27`；实现 `vendor/include/src/index.ts:121-124`、`apps/cli/src/profile-boot.ts:328-333` | 采纳 |
| base 默认启用 config-only `dsh-hmr` | **机制描述不准**：`packages/bundle/base/cordis.patch.yml:21-25` 对**所有** profile 都 `disabled: true` 禁用 cordis-plugin-hmr；真正的 config-only 重载是 launcher 对 `patchReload: 'live'` 的 profile（web 及自定义 profile）挂 watch-only 实例（`apps/cli/src/profile-boot.ts:355-371`） | 部分采纳，机制以本地源码为准（§7） |
| 浏览器侧热更 = Vite HMR，与 Cordis HMR 是两个独立层次 | 「两个独立层次」成立；但浏览器侧实现是**自定义 reload chain**（tsdown watch 重建 → `dev-web.ts` 广播 `rebuilt` 帧 → 浏览器热刷），不是 Vite HMR API；Vite 在本仓只是前端构建工具 | 部分采纳，改名「client bundle 重载」 |
| `TSX_TSCONFIG_PATH` 仅见于 inspector debugger e2e，是否公开支持未验证 | **已核实且比报告说的更重要**：它是多个生产 launcher 的源码模式启动机制——`packages/sdk/client/src/launch.ts:107`、`packages/subprocess/subprocess-local/src/runner-launch.ts:82`、`packages/workflow/workflow-worker-thread/src/host.ts:58`、`packages/experimental/inspector/src/host/bridge/controller.ts:316`（透传），e2e 只是其一（`packages/experimental/inspector/tests/debugger.e2e.ts:102`） | 升级为源码锚定事实（[S]） |
| `--trusted-host <host[:port]>` 适用范围未确认 | 已确认归属：它不是 launcher flag 而是 **web 应用插件 flag**（`packages/bundle/web-app/src/startup.ts:51-54`）；语义 = Host/Origin 信任白名单（§10） | 采纳并补充 |
| inspector 的包形态 / 默认端口 / captureFetch 未确认 | 已确认：Cordis host 插件（`inject: ['webServer']`，无 `bin`）、默认 `127.0.0.1:9230` 且 host 被硬约束为回环、`captureFetch` 默认 true（§6 L5） | 采纳并锚定 |
| 外部材料中的 `pnpm dsh web --no-open`、`rg -n ... vendor packages` 等命令 | 本仓语境需改写：vendor 在 `harness/vendor`，运行命令要带 `DSH_HOME` 指到超级仓 `.dsh` | 采纳内容、改写命令 |

**批判性总结**：外部报告的「架构骨架」可信度高（层叠、事件、构建三条主线的核心论断全部经本地源码复核成立）；
其「修正意见」是按官方通用场景写的，落到本仓要反过来用——尤其 `--profile` 一条，照搬会把本仓
所有命令改错。凡其标注「未验证」的项，本仓凡能本地核实的均已核实（§0 表格后半），
剩下确实核不了的（如 master 快照与本地 pin 的 diff）不进入正文。

---

## 1. 观测对象：插件树，不是固定内核

DSH 没有「CLI → 固定 Core → 固定 Tool Manager → 固定 UI」式的传统内核。官方架构文档原文 [S]：

> Every part of the product is a plugin, **including the model adapter, the tool registry,
> the session log, and the agent loop itself**（`harness/docs/architecture.md:11`）

因此观测要沿三条主线展开，而不是去找一个中心调度器：

| 主线 | 决定什么 | 关键事实源 |
| --- | --- | --- |
| **控制面** | 装哪些插件、每个插件什么配置 | Profile / Bundle / Patch 层叠（§2） |
| **生命周期面** | 何时启动、何时卸载、依赖失效如何回滚 | Cordis Loader + inject + effect scope（§3） |
| **数据面** | 插件如何协作、执行如何追踪 | 五种事件分发 + service method + append-only session log（§3、§4） |

对应到 base bundle 的真实行（`packages/bundle/base/cordis.patch.yml`）：`tools` → `@deepseek-ai/dsh-tools`（:460）、`agent-loop` → `@deepseek-ai/dsh-agent-loop`（:472）、`session-log-deepseek`（:36）——「工具注册表、agent loop、会话日志都是插件」不是比喻，是 cordis rows。

## 2. 控制面：配置层叠与第一诊断点

### 2.1 层叠顺序（官方原文 + 本地实现双重锚定）

```text
空 entry list
  → profile 声明的 bundles，按列表顺序
  → profile 级 cordis.patch.yml
  → Harness Home 级 cordis.patch.yml
  → CLI --patch（按参数顺序）
  → effective Cordis rows
```

[S] `docs/architecture.md:27`；实现 `apps/cli/src/profile-boot.ts:328-333`（home patch 在 `:68-73`）。

**patch 是整表替换，不是深度 merge**：命中已有 row id 时替换该 row 的整个 config
（`vendor/include/src/index.ts:121-124` 逐键整体赋值）。改一个字段可能清掉同 row 的其他配置——
`patches/*.yml` 改完后必须 `dsh --profile dsh --dump-config` 旁验（本仓 AGENTS.md 的既有要求与此吻合）。

### 2.2 第一诊断点：dump-config

```sh
cd harness && DSH_HOME="$PWD/../.dsh" CI=true pnpm dsh --profile dsh --dump-config
```

配置不生效的排查清单（按代价从低到高）：

1. 目标 row 是否存在；row id 是否与 patch 精确匹配；
2. 最终 `disabled` 值（`disabled` 在每次 mount decision 时基于 loader context 求值）；
3. config 是否被更上层的 home patch / CLI `--patch` 整表覆盖；
4. 插件是否因缺失 injected service 而未激活（row 在 ≠ 插件活着）；
5. 改的是构建产物还是 runtime profile（前者要重建，后者热生效）；
6. 是否把 §7 的 config 重载误当成模块热更（反之亦然）。

## 3. 生命周期面：装载、事件、卸载

### 3.1 Cordis 装载管道

```text
配置行 → include 展开 → disabled 判定 → 插件模块解析
      → inject 依赖检查（等 service 就绪）→ config 表达式求值
      → apply / Service mount → effect scope 建立 → active
```

要点 [S]：

- **bundle 顺序 ≠ 启动顺序**。row 排得早不代表插件先就绪；真正排序靠 `inject` 声明
  （如 `inject: ['webServer']` 的 inspector 一定等 webserver 就绪）。「profile 排了但没生效」
  先查 inject 依赖，别调 row 顺序。
- 插件两种形态 [S]（`docs/cordis-primer.md:9`）：函数对象（可带 `inject`/`apply(ctx)`）或
  `Service` 子类（`vendor/cordis/src/service.ts:11`）。
- **注册必须可逆**：listener 走 `ctx.on()`、资源走 `ctx.effect()`，effect 返回 disposer
  （`harness/docs/cordis-primer.md:13,45`）。卸载 = dispose effect scope → 注销 listener/注册 → 下游 inject
  条件失效 → 依赖插件重挂载。Cordis 的可热卸载靠这个，不是从数组里删插件。

### 3.2 五种事件分发模式（最容易误判的一层）

[S] `vendor/cordis/src/events.ts:32` `DispatchMode = 'emit' | 'parallel' | 'serial' | 'bail' | 'waterfall'`，实现 `:183-243`：

| 模式 | 等待 Promise | 顺序 | 控制语义 | 观测陷阱 |
| --- | --- | --- | --- | --- |
| `emit` | 否 | 注册顺序 | 纯通知 | **dispatch 返回 ≠ 处理完成** |
| `parallel` | 是 | 并行 | 等全部 listener，拒绝聚合为 AggregateError | 总耗时 = 最慢 listener |
| `serial` | 是 | 注册顺序 | 顺序 await | 总耗时 ≈ 各 listener 之和 |
| `bail` | 否 | 注册顺序 | 第一个有效结果终止 | 要记录**谁**短路了 |
| `waterfall` | 否 | 嵌套链 | around-middleware | 最后一个参数是 `next`，不调 `next()` 即短路，返回值沿链传递 |

「工具调了没执行」「插件加载慢」这类问题，第一反应应是查 waterfall/bail listener 是否短路，
以及 emit 的「处理完成时间」根本没有被你的探针测到。

## 4. 数据面：agent loop / tools / session log

已锚定事实 [S]：

- `ctx.tools` 是真实 service key（`docs/architecture.md:63,140`；代码侧 `ctx.tools.register(...)`、
  `ctx.tools.schemas(...)`）；agent 的 prompt / reasoning / tool call / tool result 全部进
  **append-only** `SessionEvent` log → `ctx.sessions`（`harness/docs/architecture.md:61`）。
- 工具执行的典型失败分四类（表象 → 排查方向）：

| 失败点 | 表象 | 排查方向 |
| --- | --- | --- |
| resolve | unknown tool | 插件未挂载 / 名称冲突 / 注册被 dispose |
| schema 校验 | invalid arguments | 模型参数 / schema 演进 / Client-Host 版本错配 |
| policy/approval | 看似卡住 | 等人工审批 / policy waterfall 短路 |
| implementation | tool error | sandbox / 权限 / 子进程 / 网络 |

- **trace 黄金关联键**：session id、turn id、agent run id、model request id、tool call id、
  tool name、plugin row id、scope id、各阶段时间戳与耗时、result size、error class。
  当前 logger 缺这些字段时，**在外围 observer 插件补齐，不改工具实现**。
- 业务层全链路追踪另有 OTLP 通道：`plugins/loongsuite-observability`（session/agent/LLM/tool
  生命周期 → OTLP，默认 `captureContent=false` 不捕内容；规范见 `docs/observability/README.md`）。

## 5. 构建面（简述，细节见 dsh-build-analysis.md）

只记录经本地源码核验的修正后事实 [S]：

- `pnpm run build` → `tsx scripts/build.ts`，`spawnSync` **严格串行**（`scripts/build.ts:18-29`）：
  删旧 record → `build:native-system` → `build:lib`（先 host 后 client）→ `build:web` →
  **最后**才写 client build record（`:43-47`）。
- Native 阶段带 `--host-addon-only`（`package.json:53`；过滤逻辑
  `native/system/scripts/build.ts:46`）：默认只构建当前宿主匹配的 **flock Node-API addon**，
  不构建 landlock-run（static-musl）。「完整 native 构建会出 landlock + flock」只在描述
  「native 系统支持哪些 artifact」时成立。
- build record：路径是 **`harness/.dsh-build/client-build-environment.json`**——
  ⚠️ record 落在 **harness 内**，不在超级仓根（按 `.dsh-build/…` 去根目录找会扑空 [验]）。
  变量统一 `DSH_CLIENT_` 前缀（`harness/scripts/client-build-environment.ts:14`）；
  commit hash 取 `DSH_CLIENT_COMMIT_HASH` 否则 `git rev-parse HEAD`，校验后截 7 位小写
  （同文件 `:50-61`）；**产物 pattern 只有 3 条**（同文件 `:35-39`）——
  外部报告多列的 `client.*.js(.map)` 不存在，引用时勿照抄。
  [验] 2026-09-18（harness `fb2c4b9e`）实测内容：
  `{"DSH_CLIENT_COMMIT_HASH":"fb2c4b9","DSH_CLIENT_VERSION":"0.1.5-rc.2","artifacts.fileCount":234}`——
  这条 record 是 L0 里**唯一能把「Host 与 Client 是否同 commit、UI 资源是否重建」钉死**的证据。
- 前端产物伺服与默认值：`dsh web` 伺服的是构建好的 `apps/web/dist`（web-runtime 行挂到
  webserver 的 frontend-static 座，`packages/bundle/web-app/cordis.patch.yml:154-161`）；
  默认 `host/port` 回环 3080（同文件 `:139-140` 的 `!!js` fallback）。

## 6. 分层观测方案（L0–L5）

原则：**先固定装配与环境，再逐层下探**；每层都有明确的「它测得到什么、测不到什么」。

### L0 配置与装配树（永远第一步）

```sh
cd harness && DSH_HOME="$PWD/../.dsh" CI=true pnpm dsh \
  --profile dsh --dump-config > /tmp/effective-config.txt 2>&1
# 加 patch 时再来一份做 diff：
#   ... --patch /tmp/x.yml --dump-config > /tmp/effective-config+x.txt
diff -u /tmp/effective-config.txt /tmp/effective-config+x.txt
```

连同环境基线一起存档：`node/pnpm --version`、`git rev-parse HEAD`（**子模块与超级仓各一份**）、
`git status --porcelain`、`uname -a`、
**`harness/.dsh-build/client-build-environment.json`**（⚠️ 在 harness 内，不在超级仓根，见 §5）。
Host 与 Client 是否同 commit、UI 资源是否重建、改的是哪个 profile——这一层一次排除。

dump-config 的输出**自带层叠证据**：每个 bundle 段落以 `# ==` 开头，patch 命中时写明
`# == @deepseek-ai/dsh-base, patched by <哪个 patch>`（[验] 2026-09-18）。
所以「我改的 patch 到底有没有生效」在这一层就能一眼看出，不必等下钻到运行期。

### L1 Cordis 生命周期日志（应用层 logger）

机制 [S]：阈值查表「logger 名 → `default` → 门面 level → INFO」（`vendor/cordis/src/logger.ts:155`），
级别 `0=error 1=info 2=warn 3=debug`。开全 debug 用 overlay patch 覆盖 `logger-console` 的 config：

```yaml
# /tmp/verbose.yml
- id: logger-console
  config:
    colors: true
    levels: { default: 3 }
```

```sh
cd harness && DSH_HOME="$OLDPWD/.dsh" CI=true pnpm dsh \
  --profile dsh --patch /tmp/verbose.yml --no-open 2>&1 | tee /tmp/boot-verbose.log
```

⚠️ **[验] 2026-09-16 实测：别在这层耗**。该 profile 全仓只有 **4 处 debug 输出点**，
且其中**只有 3 处走 cordis logger**（受 `levels` 门控）：

| 位置 | 调用 | 受 `levels.default` 门控 |
| --- | --- | :--: |
| `packages/credentials/authorization/src/index.ts:409` | `this.ctx.logger.debug(…)`（auth 授权撤销） | 是 |
| `packages/webhook/webhook/src/index.ts:154` | `this.selfCtx.logger.debug(…)`（webhook 事后） | 是 |
| `vendor/hmr/src/index.ts:245` | `this.ctx.logger.debug(…)`（hmr 模块热重载） | 是 |
| `packages/experimental/webworker-runtime/src/transport/tunnel.ts:407` | **`console.debug(…)`**（webworker tunnel） | **否** |

最后一条是 `console.debug`，走 realm 自己的 console，**与 cordis 的 levels 查表无关**
（[验] 2026-09-18 逐条核对）——所以「开 levels 就能看到 tunnel 那条」是错的，它一直都在输出。
boot / HTTP / 触碰 patch 三窗口 `[D]` 行均为 0 的结论不受影响：**想看得细，直接下 L2/L3。**

### L2 事件管道与 dispatch site

⚠️ **不要一上手就 rg**。harness **已经把这份地图生成好了**，而且比手工 grep 全。
先读生成目录，再用 rg 补漏——顺序反了就会漏掉三分之一（下表）。

**第一步：读生成目录**（都在 `harness/docs/`，由 `pnpm run gen-doc-graphs` 生成，
`pnpm run verify-doc-graphs` 校验新鲜度；入口索引是
`harness/docs/graph-atlas.md`）：

| 文件 | 给你什么 | 对应本文 |
| --- | --- | --- |
| `harness/docs/event-producer-consumer.md` | **事件矩阵**：Event / Mode / Declared in(`file:line`) / Dispatchers（含**用哪个方法**分发）/ Listeners。共 72 个 harness-owned 事件 | §3.2、§4、§11 |
| `harness/docs/tool-catalog.md` | 模型可见工具的 schema 目录与包映射 | §4 |
| `harness/docs/config-catalog.md` | 各插件配置项目录 | §2 |
| `harness/docs/agent-lifecycle.md` | agent turn/step 生命周期时序图 | §4、§8 |
| `harness/docs/tool-execution-pipeline.md` | 工具执行管线 | §4 |
| `harness/docs/module-graph.md`、`harness/docs/capability-seams.md` | 模块依赖与能力缝 | §1 |

事件矩阵的 `Mode` 列 = §3.2 那张表的**实例化**；`Dispatchers` 列直接告诉你
「这个事件是谁、用什么方法发的」，`Listeners` 列告诉你「谁会因此被唤醒」。
按 §3.2 的语义陷阱，**先看 Mode 再决定怎么埋点**（emit 无完成时间、serial 要算总耗时、
bail/waterfall 要记谁短路）。

**第二步：rg 补漏**——⚠️ 只搜 `ctx\.` 会漏掉大量分发点：

```sh
# ❌ 只认 ctx. 接收者：实测漏掉 35% 的分发方法（events.dispatch 一族全不可见）
rg -n 'ctx\.(emit|waterfall|parallel|serial|bail)' harness/packages harness/vendor

# ✅ 不限接收者名（ctx / this.dispatch / context / actx / events.dispatch / emitAgentEvent …）
rg -n '\.(emit|waterfall|parallel|serial|bail)\(' harness/packages harness/vendor \
   -g '!**/tests/**' -g '!*.spec.*'

# 其余两条不变
rg -n 'ctx\.tools' harness/packages
rg -n 'plugin-manager|reload.*plugin' harness/packages harness/apps
```

**为什么必须放宽**（[验] 2026-09-18，harness `fb2c4b9e`）：

| 模式 | 全部分发点 | 其中经 `ctx.` | 漏检 |
| :--- | --: | --: | --: |
| `emit` | 120 | 37 | 83 |
| `waterfall` | 24 | 15 | 9 |
| `parallel` | 6 | 4 | 2 |
| `serial` | **1** | **0** | **1** |
| `bail` | 7 | 6 | 1 |

> 口径：`emit` 一行含非 cordis 的同名方法（EventEmitter/流），绝对值偏大；
> `waterfall`/`serial`/`bail` 基本为 cordis 专用，可直接采信。

生成目录的 `Dispatchers` 列把这件事量化得更干净：72 个事件的分发方法为
`emit` 28、**`events.dispatch` 25**、`waterfall` 16、`serial` 1、`parallel` 1、
`emitAgentEvent` 1——**25/72（35%）用 `ctx\.` 根本扫不到**。该文件页首也自述了这一点：

> Receiver and event-name types also cover contained dispatch sites that
> **deliberately bypass `ctx.emit`**, such as subagent lifecycle containment.

**一个具体代价**：全仓唯一的 `serial` 分发是
`harness/packages/core/agent-loop/src/agent.ts:316`
的 `this.dispatch.serial('agent/turn-stopping', …)`——它在**每个 turn 的关键路径**上
（step end 与 turn end 之间、被 `await`，监听方 `hooks-claude-code` / `hooks-codex`）。
**按旧配方找「谁拖慢了 turn」，这一行完全不在视野里。**

对每个关心的事件建一张矩阵：事件名 | dispatch 模式 | dispatch site（file:line）| listener 数 |
注册顺序 | 耗时 | 是否短路。注意 §3.2 的语义陷阱（emit 无完成时间、bail/waterfall 要记谁短路）。

### L3 Node / V8 运行时（宿主内部的主通道）

以**环境变量前缀**方式传入即可堆在 `make dev` 前——make 会把自身环境透传给 recipe
（[验]，详见 quickref §2）。
> 注意成因：这条走的是**环境继承**，与「make 命令行变量（`make VAR=value`）会被导出」
> 是两种机制（Makefile 里 `release` 那条注释讨论的是后者）。两者在绝大多数情况下等效，
> 但不要据此以为 `make NODE_DEBUG=…` 与 `NODE_DEBUG=… make` 是同一件事。

| 目标 | 开关 |
| --- | --- |
| Node 内建模块调试（HTTP/WS/TLS/流/ESM loader） | `NODE_DEBUG=http,net,stream,tls,events,module,esm,vm` |
| 挂 V8 调试器（chrome://inspect） | `NODE_OPTIONS='--inspect'`（默认 9229）/ `--inspect-brk` 首行断点 |
| 追未捕获异常 / 深堆栈 | `--trace-warnings --trace-uncaught --stack-trace-limit=100` |
| V8 CPU profile | `--prof`（→ `node --prof-process`）或 `--cpu-prof --cpu-prof-dir=…` |
| GC 观测 / 泄漏判断 | `--trace-gc`；重复 load/unload 后看 old-space 基线是否持续上升 |
| 源码模式 paths 解析 | `TSX_TSCONFIG_PATH=<repo>/harness/tsconfig.json`（[S] 多个生产 launcher 同款，§0） |

安全边界：inspector 只绑回环；**不要**为排障把调试端口暴露到外部网络。

### L4 WebServer、前端产物与浏览器

- **本仓开发环没有 Vite dev server**：`make dev` 伺服已构建的 `apps/web/dist`；
  前端热更走「双跑」——另开 `pnpm exec tsx scripts/dev-web.ts` 做
  `tsc client → tsdown → vite build` 三段 watch，由 `dsh web` stat-poll 产物并广播 `rebuilt`
  帧触发浏览器热刷（[S] `harness/scripts/dev-web.ts` 头注释）。网络盘加 `--poll=500`。
- vite 自身调试：`DEBUG=vite:*`。

**浏览器侧的四条抓手**（[验/S]）：

1. **WS 通道与其协议**：DevTools → Network → WS 过滤 **`/api/remote.mux`**。
   别只看 URL——协议是**有类型定义**的，`[S]`
   `harness/packages/api/gateway/src/stream-protocol.ts`：

   | 常量 | 值 | 含义 |
   | --- | --- | --- |
   | `REMOTE_STREAM_MUX_PATH` (`:7`) | `/api/remote.mux` | 承载**所有** Remote 流的唯一 WS 路由 |
   | `REMOTE_EVENT_STREAM_ENDPOINT` | `$events` | 应用选定 cordis 事件的转发流 |
   | `REMOTE_EVENT_RESULT_ENDPOINT` | `$events/result` | 单次 Remote Event 结局的 unary 端点 |
   | `REMOTE_EVENT_STREAM_READY` | `{ type: 'ready' }` | **首帧**，证明 Host 事件源已就绪 |

   排查 WS 的第一件事：**首帧是不是 `ready`**（`RemoteEventReadyFrame` 还带 `clientId` 与
   `host.home`）。没有 `ready` 就不必往下看业务帧了。四个 e2e
   （`apps/web/tests/lifecycle-chrome.e2e.ts` 等）都直接打这条路由，可当**可执行样例**读。
2. **boot 页**：`loader-status` 逐 entry 状态。
3. **`window.__DSH_BOOT__`**：不是测试专用，是**生产通道**——其合成方在网络半边，`[S]`
   `harness/packages/client/modules` 是**双面**包
   （其 `package.json` description 自述："node half composes the `__DSH_BOOT__` entry graph
   … browser half is the lazy-CJS module table the vendored cordis Loader consumes"）。
   浏览器半边**解析失败直接 throw**（`src/client/manifest.ts:169`
   `'client-modules: window.__DSH_BOOT__ is missing or not an object'`），
   所以「页面白屏 + 这条错」= 注入丢了，而不是插件问题。
   ⚠️ 顺带一提：**`apps/web` 单独跑 Vite 起不来**是有意的——
   `apps/web/vite.config.ts:9` 的 `STANDALONE_ERROR` 明说
   "only dsh web injects window.__DSH_BOOT__"。
4. **判断边界**：HTML TTFB 慢 → Host/WebServer；JS 下载慢 → bundle/网络；
   JS evaluation 慢 → Client CPU；API pending → Host service/readiness；
   WS 反复断开 → 热更/生命周期。

**⚠️ 关于「同 API 重复请求」——别只归因订阅泄漏**（三因，[S] 2026-09-18 修正）：

| 因 | 证据 | 适用面 |
| --- | --- | --- |
| **render-then-subscribe 竞争** | `packages/client/resources/src/client/resources.ts:8` 注释明写 "React's render-then-subscribe window and a StrictMode remount" | 全部 |
| **StrictMode 重挂载** | `packages/client/ui-renderer/tests/bind.client.spec.tsx:89` 有 `is StrictMode-safe and cleans up subscriptions on unmount` 回归 | **仅开发/测试**——生产壳 `harness/apps/web/src/main.ts` 不包 `StrictMode` |
| 真正的订阅泄漏（缺 disposer） | §3.1「注册必须可逆」 | 全部 |

**先把第三因排掉再怀疑前两因**：生产环境**不存在** StrictMode 双挂载，
把它当主因会把排查带偏。

### L5 harness 原生 inspector（CDP hub，实验性）

[S] `packages/experimental/inspector`：`@deepseek-ai/dsh-experimental-inspector`，
形态 = **Cordis host 插件**（`inject: ['webServer']`，无 `bin`，不是 CLI）+ 跨 realm CDP hub。
默认 `127.0.0.1:9230` 且 host 被 schema 钉死为 `z.const('127.0.0.1')`
（`packages/experimental/inspector/src/index.ts:74-76`），**Worker host 亦被硬约束为回环**
（同包 `src/shared/bridge/control-codec.ts:23`）；
`captureFetch` 默认 true（宿主 HTTP 抓包）；暴露 cordis 运行时树只读查询
（`CORDIS_TREE_TOPIC = 'cordis/tree'`，host/client 双树）。

挂载（overlay，默认未挂载）：

```yaml
- insert:
    - id: experimental-inspector
      name: '@deepseek-ai/dsh-experimental-inspector'
      config: { host: '127.0.0.1', port: 9230 }
```

⚠️ 实验性质；挂载前先 `--dump-config` 验解析（profile resolver 解析面风险，同 backlog B10 族）。
与 `NODE_OPTIONS=--inspect`（9229）不冲突 [验]。
> 为何要「验解析」：本仓已有先例——`logger-console` 是 vendor 包，**loader 解析得到、
> 但 `createRequire` 一族解析不到**，直接导致每个 DeepSeek 请求失败且**不进任何日志**
> （见 `docs/plugin-dev.md`「解析面不止一个」条）。挂载任何非常规形态的包前，
> 都要假设存在多个解析面。

### L6 模型侧运行时内省（`tool-cordis`，**本轮新增**）

L0–L5 全是**外部**手段（dump / 日志 / 探针 / DevTools）。harness 还自带一条**从内部看内部**
的通道，且**不需要重启、不需要改仓库**：

[S] `@deepseek-ai/dsh-tool-cordis`（`harness/packages/extensions/tool-cordis`）——
面向模型的 Cordis 运行时工具，导出的查询面（`src/inspect.ts`）：

| 函数 | 回答什么问题 | 对应本文 |
| --- | --- | --- |
| `missingServices(ctx, fiber)` | **该插件缺哪个注入服务**（row 在 ≠ 插件活着） | §2.2 第 4 条 |
| `providedServices(ctx, fiber)` | 它提供了什么 | §3.1 |
| `describePlugins(ctx)` | 当前插件清单与状态 | §9 不变量差分 |
| `describeTools(ctx, scope?)` | 工具注册表现状 | §4 |
| `describeEvents(events, name?)` | 事件 API 清单 | §3.2 |
| `describeApi` / `describeDynamic(ctx, agent?)` | 服务 API / 动态包 | §3、§9 |

它还能**创建、运行、停止、更新、删除临时动态包**（host 代码 / 浏览器代码 / 两者），
包版本不可变（改错就加新版本再切），定义**只存在于进程内存、重启即消失**，
**不写仓库文件、不装依赖、不改 `cordis.yml`**（[S] 其 README 自述）。
⇒ 这是**就地植入观测插件**的正规通道：想给某个事件加 listener、想包一层 service,
不必改任何 submodule，也不必像 §9 那样走「改了再 reload」的重路径。

**启用成本 = 一条 patch**（[验] 2026-09-18 装配事实）：

- 底座 `@deepseek-ai/dsh-cordis-host-runner` **已在** web-app bundle
  （`packages/bundle/web-app/cordis.patch.yml:122-123`）——本轮 dump 的装配树第 422-423 行可见；
- 但 `dsh-tool-cordis` **未挂载**（不在任何 bundle 的 `cordis.patch.yml`，也不在装配树里），
  其 `lib/index.js` 已构建 ⇒ 与 L5 挂 inspector 的形态完全一样：

```yaml
# /tmp/tool-cordis.yml
- insert:
    - id: tool-cordis
      name: '@deepseek-ai/dsh-tool-cordis'
```

⚠️ 同 L5：挂载前先 `--dump-config` 验解析；且它是**模型可见**的能力，
在生产 profile 上开等于把运行时内省与「创建临时包」的权限交给模型——**只在排障实例上开**。

## 7. 两层「热更新」的真相（修正外部材料）

本仓存在**两条独立**的重载路径，名字里都带 HMR，极易混：

| | config 重载（host 侧） | client bundle 重载（浏览器侧） |
| --- | --- | --- |
| 触发 | launcher watch profile/home patch 文件 | `dev-web.ts` 的 tsdown watch 重建完成 |
| 范围 | 配置行（`disabled`、config 值） | `apps/web/dist` 前端产物 |
| 机制 [S] | `patchReload: 'live'` 的 profile（web 模板及本仓自定义 profile `dsh`）由 `apps/cli/src/profile-boot.ts:355-371` 挂 watch-only hmr 实例（`root: []`，只为配置行）；headless/sdk/acp/sdk-minimal 是 `'startup'`（`packages/boot/app-boot/src/profile.ts:110-131`） | `rebuilt` 帧广播 → 浏览器热刷（`harness/scripts/dev-web.ts` 头注） |
| **不是** | 模块代码热替换：`cordis-plugin-hmr` 被 base 对所有 profile `disabled: true`（`packages/bundle/base/cordis.patch.yml:21-25`） | **Vite HMR**：Vite 只是构建工具（`apps/web` 的 `dev` script 用它起 dev server），这条链与 Vite HMR API 无关 |

**harness 自己也这么讲**——而且是对**模型**讲的（[S] 2026-09-18 新增）：
`packages/bundle/web-app/src/index.ts:136-138` 定义了随每次 web 会话注入的系统提示片段
`updateContract`，原文把两条链的边界说死了：

> The client-plugin HMR receiver is active, but client-plugin changes reload **without a refresh
> only while `pnpm run dev:web` is also running from this same checkout** to rebuild their bundles;
> verify that watcher before promising automatic updates. **Every other change** — the apps/web shell
> and plain packages — **requires rebuilding the affected Web artifacts and verifying this existing
> URL after a page refresh.**

同一函数（`:134` `webSurfacePrompt`）还补了一句排障相关的事实：
"Starting another server does not update this GUI."（另起一个服务不会更新当前页面——
这正是 §11 强调「不要抢占端口、用 `--port 0` 隔离」的**语义**理由，不只是礼貌问题）。

推论：config 改动「热生效」与前端代码改动「热刷新」是两条链；「改了配置没反应」先确认走的是哪条、
patch 层级是否被覆盖（§2.2），「UI 行为旧」先确认 dist 重建与浏览器缓存（L4）。

## 8. 启动耗时分解

`time dsh web` 只测进程生命周期，测不到 readiness。正确做法是**外部探针 + 内部分段**。

外部黑盒探针（测到第一个**成功响应**为止，不含浏览器首屏）。

⚠️ **上一版这段脚本是坏的**（2026-09-18 修正），四处缺陷，逐条对应下面的写法：

| 缺陷 | 后果 |
| --- | --- |
| `curl -fsS "$url"` | `/` 无 token 返回 **401**，`-f` 判失败（退出码 22）⇒ `&&` **永不触发** ⇒ 脚本**必然**报 not ready。CI 冒烟与本文件 §10 都写明 401 属正常，唯此处漏了 |
| `date +%s%N` | GNU 扩展。本仓**官方支持 macOS M4**，BSD `date` 无 `%N` ⇒ 计时变 `…N`，算术直接报错 |
| 硬编码 `3080` | 撞上正在运行的实例；且**另起服务不会更新既有页面**（§7） |
| `wait "$pid"` / `kill "$pid"` | 杀的是 pnpm 包装进程，**`node` 子进程残留并继续占端口**（`docs/plugin-dev.md` 已记录该坑） |

```sh
#!/usr/bin/env bash
# 隔离实例启动探针：不占既有端口、状态码白名单、可移植计时、干净清理
set -uo pipefail
export DSH_HOME="${DSH_HOME:-/tmp/dsh-obs/.dsh}"   # ⚠️ 显式，勿用 $OLDPWD
export CI=true
LOG=/tmp/boot-$(date -u +%Y%m%dT%H%M%SZ).log
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }   # 可移植（BSD/GNU 通用）

start=$(now_ms)
( cd harness && pnpm dsh --profile dsh --no-open --port 0 ) >"$LOG" 2>&1 &   # --port 0：OS 分配
wrapper=$!

# 1) 从日志取 OS 实际分配的端口（--port 0 下事先不知道端口）
port=""
for _ in $(seq 1 1200); do
  port=$(grep -oE 'http://127\.0\.0\.1:[0-9]+' "$LOG" 2>/dev/null | head -1 | sed 's/.*://') || true
  [ -n "$port" ] && break
  sleep 0.05
done
[ -n "$port" ] || { echo "FAIL: 未打印 URL"; kill "$wrapper" 2>/dev/null; exit 1; }
t_url=$(now_ms)

# 2) 探针：200 / 303 / 401 均视为就绪（认证 gate 在响应 = 服务已就绪，同 CI 冒烟口径）
ready=""
for _ in $(seq 1 1200); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" || true)
  case "$code" in 200|303|401) ready=$(now_ms); break ;; esac
  sleep 0.05
done
[ -n "$ready" ] || { echo "FAIL: 未就绪"; kill "$wrapper" 2>/dev/null; exit 1; }
echo "port=$port url=$(( t_url - start ))ms http_ready=$(( ready - start ))ms code=$code"

# 3) 清理：按端口反查**真实 node pid**（只杀 wrapper 会留下 node 占端口）
node_pid=$(ss -ltnp 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$node_pid" ] && kill "$node_pid" 2>/dev/null
kill "$wrapper" 2>/dev/null
```

[验] 2026-09-18：该脚本在隔离 home（`/tmp/dsh-obs/.dsh`）上连续跑通，
每次端口由 OS 分配（43229 / 37297 / 41619 / 36801 / 33737 / 34679 …），**无一为 3080**；
输出形如 `port=43229 url=14299ms http_ready=14355ms code=401`。

覆盖项：进程拉起 + profile 装配 + 插件挂载 + web 绑定 + 首个响应。**不含**前端资源传输、
JS 求值、API bootstrap、首屏渲染——那部分用浏览器 Performance/Network 补（L4）。

内部分段 marker 建议：`cli.start` → `profile.resolve` → `layers.apply` → `loader` →
每插件 `mount.begin/end`（注意表观耗时 = 模块解析 + inject 等待 + config 求值 + apply +
异步 ready，**只记 apply 会漏掉大头**）→ `services.ready` → `web.listen` → `web.fence.ready` →
`client.js.evaluated` → `client.api.connected` → `first.stable.render`。

profiler 本身会显著扰动启动耗时：性能基准与功能诊断**分两轮**，基准至少跑 10 次、首轮 cold run
单独统计。

## 9. 插件加载/卸载专项

每轮 load/unload 的不变量（回到基线才算干净）：

- plugin instance / service key / listener / tool 注册数量回到基线；
- timer / socket / child process 无残留；GC 后 old-space 回到稳定区间；
- UI subscription 与 WS handler 不重复；append-only session log 不因 reload 重放副作用。

常见症状 → 高概率根因：

| 症状 | 根因方向 |
| --- | --- |
| 每次 reload 越来越慢 | listener/effect 泄漏、重复文件 watcher |
| 工具被调两次 | tool 注册未 dispose |
| 卸载后仍收事件 | listener 注册在错误的 scope |
| reload 一直 pending | disposer 等待未终止的后台任务 |
| 端口占用 / 进程退不出 | socket/timer/child process 未 close |
| config 改动无效 | patch 层级覆盖 / row id 不匹配（§2.2） |
| Host 已更新 UI 行为旧 | `apps/web/dist` 未重建或浏览器缓存（L4） |
| 热更后状态重复 | §7 两条链同时触发两个重建路径 |

## 10. 远端访问与 fence（`--trusted-host`）

[S] `--trusted-host` 不是 launcher flag，是 **web 应用插件 flag**
（`packages/bundle/web-app/src/startup.ts:51-54`，经 `cmdlineArgs` 传入），解析进
`ctx.webStartup.trustedHosts`，供 `web-runtime` / `connection` 行用作 Host/Origin 信任白名单
（`packages/bundle/web-app/cordis.patch.yml:161,188`）。同目录 `src/startup.ts:74-75`
拒绝 `--host 0.0.0.0`（理由写在错误消息里：那等于把远程代码执行暴露到网络）。

SSH 转发 / 反代 / Web IDE 场景排障清单：浏览器实际发送的 `Host`（含不含端口）、热更帧用的
host/port、反代是否重写 Host、fence 是否在等一个永远不会被信任的 URL、`127.0.0.1` 与
`localhost` 与转发 host 是否按同一规则匹配。**不要**为排障信任通配 Host——那是
DNS rebinding / Host header 攻击面。

## 11. 调查顺序（推荐，可执行版）

> 本节 2026-09-18 重写：原版是意图清单（无命令、无判据、无隔离要求），照做很容易
> **直接撞上正在运行的实例**。改后五步**已按原样完整跑通过一遍**（记录见
> [评审文档 §6](dsh-observability-analysis-review.md#6-本轮实测记录11-调查顺序执行2026-09-18)）。

### 第 0 步（新增，先做）：隔离——别动正在跑的那个实例

```sh
# 0.1 先看本机有没有在跑的实例；有的话，它的 DSH_HOME 和端口是多少
pgrep -af 'apps/cli/src/bin.ts'
ss -ltnp | grep -E 'node'            # 或 lsof -nP -iTCP -sTCP:LISTEN

# 0.2 准备一个**独立 home**（⚠️ link-plugins.sh 要求形如 <目录>/.dsh，
#     它会把 HOME 重定向到该目录的父目录）
export DSH_HOME=/tmp/dsh-obs/.dsh
mkdir -p "$(dirname "$DSH_HOME")"

# 0.3 装一套隔离装配（不是复制既有 home——既有 home 可能正被写入）
DSH_HOME="$DSH_HOME" CI=true bash scripts/link-plugins.sh
```

**判据**：`link-plugins.sh` 退出码 0 且末行形如「完成: 已挂载 N 个 bundle 到 profile dsh」。

**为什么必须隔离**（三条，都不是「礼貌」，是正确性）：

1. 两个实例并发写同一 `$DSH_HOME` 的会话库有风险；
2. **另起服务不会更新既有页面**——§7 引的官方系统提示原文：
   "Starting another server does not update this GUI." 你起第二个实例，
   打开的仍是第一个的 UI，于是「改了没生效」会变成假象；
3. 后文所有探针一律 **`--port 0`**（OS 分配），**不要硬编码 3080**：会撞端口，
   而且撞了之后的报错（`EADDRINUSE`）看起来像「新插件导致启动失败」，极易误判。

### 第 1 步：源码地图——**先读生成目录，再 rg 补漏**

§6 L2 已改写。要点：`harness/docs/event-producer-consumer.md` 等 7 份生成目录**已经**是
你要建的那张地图（72 个事件，含 Mode / Declared in / Dispatchers / Listeners）；
手工 rg 只用来补生成物覆盖不到的地方，且**必须放宽接收者名**（只搜 `ctx\.` 漏 35%）。

**判据**：你能对任一关心的事件说出它的 `Mode` 与全部 listener——说不出来才需要 rg。

### 第 2 步：固定装配 + 存档

```sh
cd harness && DSH_HOME=/tmp/dsh-obs/.dsh CI=true pnpm dsh \
  --profile dsh --dump-config > /tmp/effective-config.txt 2>&1      # §6 L0
```

**判据（本轮实测基线，可作对照）**：退出码 0、**0 条 warn/error**、约 180 个 entry
（[验] 2026-09-18：665 行 / 181 entry）。
一并存档：`git rev-parse HEAD`（**超级仓与 harness 各一份**）、`git status --porcelain`、
`node/pnpm --version`、`uname -a`、
**`harness/.dsh-build/client-build-environment.json`**（⚠️ 在 harness 内，见 §5）。

> 顺带：dump-config 的 `# ==` 分节**自带层叠证据**（`patched by <哪个 patch>`），
> 「我改的 patch 生效了吗」在这一步就能答，不必下钻。

### 第 3 步：Host 基线

用 §8 的修正探针，**`--port 0` + 独立 home**。建议 ≥10 轮，**首轮 cold run 单独统计**
（[验] 2026-09-18：冷启 16.7s vs 预热 ~14.4s）。
一次只加一个观测手段，各自单独一轮：无 profiler → `--trace-gc` → `--cpu-prof` → inspector。
⚠️ **profiler 本身显著扰动耗时**：性能基准与功能诊断**分两轮**。

**判据**：每轮都能报告 `url` 与 `http_ready` 两个毫秒数，且端口非既有实例端口。
拿不到 `code=401/200/303` ⇒ 先查是不是被 `curl -f`（或端口占用）骗了。

### 第 4 步：插件增量（每次只变一个因素）

加 bundle / 加 patch row / enable / disable / reload / unload，一次一个，做差分。
**差分含依赖激活与并发效应**，必须结合 per-plugin marker 解读，不能只看总耗时。
可选：第 1 步若发现 `tool-cordis`（§6 L6）适合，在这一步挂上——
它能直接给出 `missingServices` / `describePlugins`，比外部推快得多。

**判据**：每次改动前后各留一份 dump-config + 一份 `describePlugins` 快照。

### 第 5 步：端到端（前端段）

浏览器 Performance + Network，按 §6 L4 的四条抓手：WS 首帧是否 `ready`、boot 页
`loader-status`、`window.__DSH_BOOT__` 是否存在、TTFB/下载/求值的边界划分。

**判据**：能把 §8 覆盖不到的段（资源传输 / JS 求值 / API bootstrap / 首屏）各自归位。

## 12. 诚实边界

**两轮证据要分开看**——本文的 `[验]` 来自两次独立实测，出处不同：

| 轮次 | 日期 | 环境 | 支撑哪些结论 | 详细记录 |
| --- | --- | --- | --- | --- |
| 第一轮 | 2026-09-16 | 隔离实例 | §6 L1 的 `[D]=0`、L3 的 9229 端口、quickref 各条 | quickref §10；V2/V7 的完整记录在 [`dsh-build-analysis-review.md`](dsh-build-analysis-review.md) §9 |
| 第二轮 | 2026-09-18 | 隔离实例 `--port 0` + `/tmp/dsh-obs/.dsh`（**未占用在跑的 3080**） | §6 L1 的 debug 源逐条核对、L2 漏检量化、§8 探针修正、§11 全流程、L6 装配事实、§5 build record 路径 | [评审文档 §6](dsh-observability-analysis-review.md#6-本轮实测记录11-调查顺序执行2026-09-18) |

其余边界：

- [I] config 重载对 logger `levels` 是否真正热生效（语义链成立，未实测；重启验证最稳）。
- [I] §8 内部 marker 表是建议方案，DSH 当前源码未内建这些 marker，需要插件/外围手段实现。
- [I] §8 修正探针里 `date +%s%N` 在 macOS 不可用系推断（本机无 macOS；BSD `date` 无 `%N` 是既定事实），
  修正版已改用 `node -e Date.now()` 规避。
- [I] §6 L6 的 `tool-cordis` 信息面来自其 README 与 `src/inspect.ts` 的导出签名，**未实挂验证**。
- [验] 启动耗时样本仅 11 次（含 1 次冷启）、单机单次会话，**不是性能基准**；
  按 §8 要求，正式基准应 ≥10 次并剔除首轮。
- [外] 外部报告基于 master `0d1f5000`，本仓 pin `fb2c4b9e`；两快照之间在观测相关路径上
  是否有行为差异，未做 diff 核验（§0 已把可本地核验项全部核完，剩余此项不影响本文结论）。
- 工具执行各阶段的精确事件名、插件管理器 IPC、前端 Store 调用链：架构级成立，逐 symbol
  未核，本文不引用具体名（避免伪造锚点）。
  > 补注（2026-09-18）：**要具体名，现在有权威来源了**——`harness/docs/tool-catalog.md`
  > 与 `agent-lifecycle.md`（生成物）给出了工具 schema 与 turn/step 时序，
  > §6 L2 的生成目录清单里已列出。本文不引用是为避免锚点漂移，不代表这些名不可知。
- **未覆盖**：§6 L4 的前端段（浏览器 Performance / WS 帧）本轮未取数；
  §11 第 4 步（插件增量差分）本轮未做单因素实验。
