# DSH 多层级观测操作速查

> 面向「想细致观测 DeepSeek Harness 启动 / 前端 / 后台 / V8 / Node 交互」的开发者。
> 证据约定：`[验]` 本机实测（2026-09-16 隔离实例）；`[S]` 源码锚定；`[I]` 推断。

## 0. 按问题选通道（速查主表）

| 你「想看什么」 | 首选 | 备选 |
| :--- | :--- | :--- |
| 装配/启动细节（哪些 entry 就绪、谁先 apply） | boot 页 `loader-status` + `make dev` 日志 + `--dump-config` | ③ 浏览器 DevTools |
| 宿主 JS 内部（HTTP / WS / 模块加载 / V8） | **`NODE_DEBUG`** + **`NODE_OPTIONS=--inspect`** | ④ tsx/ESM loader |
| TS 源码是如何被送进 V8 的（loader 层） | `NODE_DEBUG=esm,module,vm` | tsx 的 `TSX_TSCONFIG_PATH` |
| 前端 vite（构建 / 热更 / 资源） | `DEBUG=vite:*` + `dev:web` 双跑 | 浏览器 Network/WS |
| 隧道 / 远端接入 | `VERBOSE=1` + `TUNNEL_TRANSPORT_LOGLEVEL=debug` | `TUNNEL_LOGLEVEL=debug` + `/ready` |
| 业务层 `logger.debug` | ⚠️ 当前 ≈ 无（见 §1） | 转用上面各层 |
| 深度调试器（断点/内存/请求抓包） | `experimental-inspector`（CDP，9230） | `NODE_OPTIONS=--inspect` |
| **事件 / 工具 / 配置的权威目录** | **`harness/docs/` 生成物（见下）** | 手工 rg（**会漏 35%**） |
| 运行时内省（缺哪个注入服务、插件清单） | `tool-cordis`（§8.1，默认未挂载） | `--dump-config` + 源码推 |

> **先读生成目录，再动手 rg**（[验] 2026-09-18）。`harness/docs/` 下有 7 份由
> `pnpm run gen-doc-graphs` 生成的目录（`pnpm run verify-doc-graphs` 校验新鲜度），
> 入口索引是 `harness/docs/graph-atlas.md`：
>
> | 文件 | 给你什么 |
> | --- | --- |
> | `harness/docs/event-producer-consumer.md` | **72 个事件**的 Mode / Declared in(`file:line`) / Dispatchers（含**用哪个方法**）/ Listeners |
> | `harness/docs/tool-catalog.md` | 模型可见工具 schema 目录 |
> | `harness/docs/config-catalog.md` | 插件配置项目录 |
> | `harness/docs/agent-lifecycle.md` / `harness/docs/tool-execution-pipeline.md` | turn/step 时序、工具执行管线 |
> | `harness/docs/module-graph.md` / `harness/docs/capability-seams.md` | 模块依赖、能力缝 |
>
> ⚠️ **别只搜 `ctx.`**：72 个事件里有 **25 个（35%）**由 `events.dispatch` 一类
> 非 `ctx.` 接收者发出，`ctx\.emit` 一族**完全扫不到**。
> 全仓唯一的 `serial` 分发（`agent/turn-stopping`，在每个 turn 关键路径上）就是这样漏掉的。
> 配方：`rg -n '\.(emit|waterfall|parallel|serial|bail)\(' harness/packages harness/vendor -g '!**/tests/**' -g '!*.spec.*'`

---

## 1. cordis logger（应用层日志）—— 开不了多少，先知道代价

- **机制**：profile 挂了 `@deepseek-ai/cordis-plugin-logger-console`（见 `patches/mount-logger-console.yml`，`colors:false`）；
  阈值按「logger 名 → `default` → 门面 level → INFO」查表（`vendor/cordis/src/logger.ts:155`）。
- **级别**：`0=error 1=info 2=warn 3=debug`。
- **要开全 debug**（overlay，不落盘）：
  ```yaml
  # /tmp/verbose.yml
  - id: logger-console
    config:
      colors: true
      levels:
        default: 3
  ```
  ```sh
  cd harness && DSH_HOME="$PWD/../.dsh" CI=true pnpm dsh --profile dsh --patch /tmp/verbose.yml --no-open
  ```
- **[验] 2026-09-16 实测**：该 profile 只有 **4 处 debug 输出点，其中仅 3 处受 `levels` 门控**——
  `logger.debug()` 三处：`credentials/authorization/src/index.ts:409`（auth 授权撤销）、
  `webhook/webhook/src/index.ts:154`（webhook 事后）、`vendor/hmr/src/index.ts:245`（模块热重载）；
  **`console.debug()` 一处**：`experimental/webworker-runtime/src/transport/tunnel.ts:407`（webworker tunnel）。
  boot / HTTP / 触碰 patch 三窗口 `[D]` 均 = 0。**想看得细，别在这层耗**。
- ⚠️ [验] 2026-09-18：**最后那条 `console.debug` 与 cordis levels 无关**（走 realm 自己的 console），
  开 `levels.default=3` **看不到它有任何变化**——它本来就在输出。别把它当成「levels 生效了」的证据。

---

## 2. Node / V8（宿主运行时）—— 主通道

make 会把命令行前缀导出到 recipe 环境，直接堆在 `make dev` 前即可：

| 目标 | 命令 |
| :--- | :--- |
| Node 内建模块调试（HTTP / WS / TLS / 流 / 事件） | `NODE_DEBUG=http,net,stream,tls,events make dev` |
| TS→V8 的加载轨迹（ESM loader / module / VM） | `NODE_DEBUG=module,esm,vm make dev` |
| C++/libuv 层 | `NODE_DEBUG_NATIVE=1 make dev` |
| 挂 V8 调试器（DevTools） | `NODE_OPTIONS='--inspect' make dev`（默认 `127.0.0.1:9229`） |
| 首行断点逐步看 boot | `NODE_OPTIONS='--inspect-brk' make dev` |
| 追未捕获异常 / 深堆栈 | `NODE_OPTIONS='--trace-warnings --trace-uncaught --stack-trace-limit=100' make dev` |
| V8 CPU profile | `NODE_OPTIONS='--prof' make dev` 然后 `node --prof-process` |
| GC 观测 | `NODE_OPTIONS='--trace-gc' make dev` |

> **[验] 端口安全**：`NODE_OPTIONS=--inspect` 默认 9229，与 experimental-inspector 默认 9230 不冲突（2026-09-16 隔离实例确认 9229 监听）。

---

## 3. tsx / ESM loader（TS 进 V8 的翻译面）

- `pnpm dsh` 本质 = `node --import tsx/esm apps/cli/src/bin.ts`：tsx（esbuild 内核）按需转译 `.ts` 后交 Node ESM loader → V8。
- 看 loader 行为：`NODE_DEBUG=esm,module,vm`（比 tsx 自带输出更有效）。
- 工具链一致：需要时 `TSX_TSCONFIG_PATH=<repo>/harness/tsconfig.json`（inspector 的 debugger 测试即如此）。

---

## 4. 前端 / Vite

- `make dev` 用的是**已构建 dist**（无 vite dev server）；前端热更走「双跑」：
  ```sh
  # 终端 1：宿主
  cd harness && DSH_HOME="$PWD/../.dsh" CI=true pnpm dsh --profile dsh --no-open
  # 终端 2：watch 构建（tsc client → tsdown → vite build → dsh web 广播 rebuilt）
  cd harness && pnpm exec tsx scripts/dev-web.ts [--poll=500]   # 网络盘加 --poll
  ```
- vite 自身调试：
  ```sh
  DEBUG='vite:*' pnpm --filter @deepseek-ai/dsh-web-frontend run build
  pnpm --filter @deepseek-ai/dsh-web-frontend run build -- --debug
  ```
- 产物与伺服：`harness/apps/web/dist/**`（`dsh web` 伺服）；`dist/assets/*.js.map` 供断点。
- **浏览器侧四条抓手**（[验/S] 2026-09-18 扩充）：
  1. **WS 协议有类型定义**——DevTools → Network → WS 过滤 `/api/remote.mux`；
     常量与帧类型在 `harness/packages/api/gateway/src/stream-protocol.ts`：
     `REMOTE_STREAM_MUX_PATH`(`:7`)、内部端点 `$events` / `$events/result`、
     **首帧 `{ type: 'ready' }`**（`RemoteEventReadyFrame`，带 `clientId` 与 `host.home`）。
     **先确认首帧是 `ready`**，否则不必看业务帧。
  2. boot 页 `loader-status` 逐 entry 状态。
  3. `window.__DSH_BOOT__` / `__DSH_BOOT_READY__`——**生产通道**，合成方是双面包
     `harness/packages/client/modules`（node 半边合成入口图，
     浏览器半边是懒加载 CJS 模块表）；浏览器侧解析失败**直接 throw**
     （`src/client/manifest.ts:169`）⇒「白屏 + 这条错」= 注入丢了，不是插件问题。
     ⚠️ `apps/web` 单独跑 Vite 起不来是**有意**的（`apps/web/vite.config.ts:9`：只有 `dsh web` 注入它）。
  4. 判断边界：TTFB → Host/WebServer；下载 → bundle/网络；求值 → Client CPU；
     API pending → Host readiness；WS 反复断 → 热更/生命周期。
- ⚠️ **「同 API 重复请求」别只归因订阅泄漏**：三因——render-then-subscribe 竞争
  （`client/resources/src/client/resources.ts:8` 注释）、StrictMode 重挂载、真泄漏。
  但**生产壳 `apps/web/src/main.ts` 不包 `StrictMode`** ⇒ prod 上先排第三因，别被带偏。

---

## 5. 隧道 / 远端（dsh-remote-web-ui + cloudflared）

```sh
VERBOSE=1 TUNNEL_TRANSPORT_LOGLEVEL=debug make dev   # 传输层：TCP/UDP connectivity、TLS handshake、edge 连接
VERBOSE=1 TUNNEL_LOGLEVEL=debug make dev             # 通用：Registered tunnel connection、每连接/请求
curl -s http://127.0.0.1:20241/ready                 # cloudflared 自报 readyConnections（进程活着≠链路通）
```
- 层级 `[S]`：`VERBOSE` 由 npm 包 `cloudflared/lib/tunnel.js:87` 透传 stdio；`TUNNEL_*` 由 cloudflared **二进制**读（内嵌字符串证实）。

---

## 6. harness CLI / 装配

```sh
cd harness && DSH_HOME="$PWD/../.dsh" CI=true pnpm dsh --profile dsh --dump-config   # 装配树全貌
… --patch /tmp/x.yml         # 临时注入（不落盘）
… --trusted-host host:port   # /api fence 额外信任
… --no-open                  # 不自动开浏览器，只打 URL
… --port 0                   # ⭐ 让 OS 分配端口：**起排障实例时永远加这个**
```
- 认证语义 `[验]`：`/` 无 token → 401；`?token=` → 303/200；token 每次重启轮换。
- ⚠️ **起实例前先隔离**（[验] 2026-09-18）：
  1. `pgrep -af 'apps/cli/src/bin.ts'` + `ss -ltnp | grep node` 先看待跑的端口上有没有既有实例；
  2. 用**独立 `$DSH_HOME`**（如 `/tmp/dsh-obs/.dsh`），别拿既有 home 做实验——两个实例并发写同一会话库有风险；
  3. **一定加 `--port 0`**。撞端口后的 `EADDRINUSE` 看起来像「新插件导致启动失败」，极易误判；
  4. 顺带一条语义理由：**另起服务不会更新既有页面**（harness 注入的系统提示原文
     "Starting another server does not update this GUI."）——你起第二个实例，看到的仍是第一个的 UI。
- **装配树自带层叠证据**：dump-config 每个 bundle 段以 `# ==` 开头，patch 命中会写成
  `# == @deepseek-ai/dsh-base, patched by <哪个 patch>`——「我的 patch 生效了吗」这一步就能答。

---

## 7. 可观测平台（OTLP，业务追踪）

- `plugins/loongsuite-observability`：session/agent/LLM/tool 生命周期 → OTLP/HTTP protobuf；`captureContent=false` 默认（不捕 prompt/结果）。
- 宿主 telemetry：`DSH_TELEMETRY_MODE`（生产默认 DISABLED）。
- 规范：`docs/observability/README.md`。

---

## 8. experimental-inspector（CDP hub，实验性）

- 默认 `127.0.0.1:9230`、`captureFetch=true`（宿主 HTTP 抓包）、cordis 运行时树只读查询（`inspector.cordis`）。
- 挂载（overlay）：
  ```yaml
  - insert:
      - id: experimental-inspector
        name: '@deepseek-ai/dsh-experimental-inspector'
        config: { host: '127.0.0.1', port: 9230 }
  ```
- ⚠️ 实验性质、默认未挂载；其包出于 profile resolver 的解析面风险同 B10 族——**挂载前先 `--dump-config` 验能否解析**。

### 8.1 tool-cordis（模型侧运行时内省，**默认未挂载**）

[S] `@deepseek-ai/dsh-tool-cordis`（`harness/packages/extensions/tool-cordis`）——
从**内部**看内部，且**不需重启、不改仓库**：

| 查询 | 回答什么 |
| --- | --- |
| `missingServices(ctx, fiber)` | **该插件缺哪个注入服务**（row 在 ≠ 插件活着） |
| `providedServices` / `describePlugins` / `describeTools` / `describeEvents` / `describeApi` / `describeDynamic` | 服务、插件清单、工具注册表、事件 API、动态包 |

还能创建/运行/停止/更新/删除**临时动态包**（host 代码、浏览器代码或两者），
只存在于进程内存、重启即消失，**不写仓库文件、不装依赖、不改 `cordis.yml`**——
等于「就地植入观测插件」的正规通道。

- [验] 2026-09-18 装配事实：底座 `@deepseek-ai/dsh-cordis-host-runner` **已在** web-app bundle
  （`packages/bundle/web-app/cordis.patch.yml:122-123`，装配树可见）；
  但 `dsh-tool-cordis` **未挂载**，其 `lib/index.js` 已构建 ⇒ 启用成本 = 一条 patch：

  ```yaml
  - insert:
      - id: tool-cordis
        name: '@deepseek-ai/dsh-tool-cordis'
  ```

- ⚠️ 它是**模型可见**能力。生产 profile 上开 = 把运行时内省与「创建临时包」交给模型，
  **只在排障实例上开**；同 §8，挂载前先 `--dump-config` 验解析。

---

## 9. 日志落盘

- 本地：`make dev` 经 `tee` 落 `log/dev-*.log`；`NODE_DEBUG / VERBOSE / NODE_OPTIONS=--trace-*` 的输出也进同一管道（都是 stdout/stderr 透传）。
- 部署：`remote-install.sh` 由 systemd 托管，logger-console stdout → journald（`journalctl -u dsh`）。

---

## 10. 证据与边界

**两轮 `[验]` 出处分开记**（详见[评审文档](dsh-observability-analysis-review.md) §6）：

| 轮次 | 日期 | 环境 | 内容 |
| --- | --- | --- | --- |
| 第一轮 | 2026-09-16 | 隔离实例 | V7（9229 inspect 监听）、V2（`[D]=0`）、隧道/认证各条 |
| 第二轮 | 2026-09-18 | 隔离实例 `--port 0` + `/tmp/dsh-obs/.dsh`（**未占用在跑的 3080**） | debug 源逐条核对（3 `logger.debug` + 1 `console.debug`）、生成目录与漏检量化（25/72）、启动基线 11 轮（冷启 16.7 s vs 预热均值 14.87 s，URL 与 HTTP 就绪间隔稳定 54–61 ms）、`tool-cordis` 装配事实 |

- `[S]`：`vendor/cordis/src/logger.ts:155`、`cloudflared/lib/tunnel.js:87`（+二进制 strings）、
  `packages/experimental/inspector/src/index.ts:74-76`、`packages/experimental/inspector/src/shared/bridge/control-codec.ts:23`、
  `harness/scripts/dev-web.ts` 头注、`harness/apps/web/vite.config.ts`（`STANDALONE_ERROR`）、
  `packages/api/gateway/src/stream-protocol.ts:7`、`packages/client/modules/src/client/manifest.ts:169`、
  `packages/bundle/web-app/src/index.ts:134-144`（系统提示里的热更契约）。
- `[I]`：tsx 自身日志细节、HMR 对 logger levels 的热生效（语义链成立但本 profile 无 debug 源可证）、
  `date +%s%N` 在 macOS 不可用（本机无 macOS）、`tool-cordis` 实挂后的信息面（只读了 README 与导出签名）。
- **未覆盖**：启动耗时不是基准（11 次样本、单机）；浏览器端（Performance / WS 帧）本轮未取数。
