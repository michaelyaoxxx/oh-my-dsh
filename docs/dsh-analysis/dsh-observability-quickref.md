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
- **[验] 2026-09-16 实测**：该 profile 只有 **4 处 `logger.debug()`**（auth 授权撤销 / webworker tunnel / webhook 事后 / `vendor/hmr:245` 模块热重载路径）——
  boot / HTTP / 触碰 patch 三窗口 `[D]` 均 = 0。**想看得细，别在这层耗**。

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
- **浏览器侧**：DevTools → **Network / WS（`/api/remote.mux`）**；boot 页 `loader-status` 逐 entry 状态；`window.__DSH_BOOT__`、`__DSH_BOOT_READY__`。

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
… --patch /tmp/x.yml     # 临时注入（不落盘）
… --trusted-host host:port   # /api fence 额外信任
… --no-open              # 不自动开浏览器，只打 URL
```
- 认证语义 `[验]`：`/` 无 token → 401；`?token=` → 303/200；token 每次重启轮换。

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

---

## 9. 日志落盘

- 本地：`make dev` 经 `tee` 落 `log/dev-*.log`；`NODE_DEBUG / VERBOSE / NODE_OPTIONS=--trace-*` 的输出也进同一管道（都是 stdout/stderr 透传）。
- 部署：`remote-install.sh` 由 systemd 托管，logger-console stdout → journald（`journalctl -u dsh`）。

---

## 10. 证据与边界

- `[验]`：V7（9229 inspect 监听）、V2（`[D]=0`，全仓仅 4 处 debug 源，隔离实例 2026-09-16）。
- `[S]`：`logger.ts:155`、`cloudflared/lib/tunnel.js:87`（+二进制 strings）、`experimental-inspector/src/index.ts:76`、`scripts/dev-web.ts` 头注、`apps/web/vite.config.ts`（`rejectStandaloneServe`）。
- `[I]`：tsx 自身日志细节、HMR 对 logger levels 的热生效（语义链成立但本 profile 无 debug 源可证）。
