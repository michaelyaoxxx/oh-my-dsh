
全部开关挖齐了，阈值逻辑实锤在 `vendor/cordis/src/logger.ts:155`：

```js
const targetLevel = exporter.levels?.[this.name] ?? exporter.levels?.default ?? this.level ?? LoggerLevel.INFO
if (targetLevel < level) continue
```

级别：__0=error 1=info 2=warn 3=debug__；查表顺序 =「按 logger 名字」→「`default`」→「门面 level」→「INFO」。所&#x4EE5;__&#x628A; console exporter 的 `levels.default` 设成 3，全仓 debug 就出来了__（当前默认 INFO，debug 被过滤，连内存环形缓冲都不进）。

---

# 观测开关全景（从最实用到最底层）

## ① harness/cordis 全量 debug 日志（观测启动的首选）

`logger-console` 已由本仓 `patches/mount-logger-console.yml` 挂进 profile（当前只设 `colors:false`）。用一个 __overlay patch 覆盖它的 config__ 即可打开 debug（patch 按 id 整表替换 config）：

```yaml
# /tmp/verbose.yml
- id: logger-console
  config:
    colors: true
    levels:
      default: 3          # 0 error / 1 info / 2 warn / 3 debug
```

```sh
# 入口 A：直接用 dsh 起（贴近 make dev 内部）
cd harness && DSH_HOME="$OLDPWD/.dsh" CI=true pnpm dsh --profile dsh --patch /tmp/verbose.yml --no-open 2>&1 | tee /tmp/boot-verbose.log
# 入口 B：想落到 log/，就把上面那段合并进 .dsh/profiles/dsh/cordis.patch.yml（profile 是 live reload，配置热生效[推断，可实测]）
```

启动期会立刻看到 `web-startup → webserver → web-app → client-modules → session/agent-loop → llm` 每个条目的 `[D]` 行（它们全走 `ctx.logger`，源码层：`vendor/cordis/src/logger.ts`、各包 `ctx.logger(...)`）。可按名字局部开：`levels: { 'dsh-web-app': 3, default: 1 }`。

## ② cloudflared 隧道日志（你已会，补一句机制）

`VERBOSE=1`（npm 包 `cloudflared/tunnel.js:87` 透传 stdio）+ `TUNNEL_TRANSPORT_LOGLEVEL`/`TUNNEL_LOGLEVEL`（二进制 env）——上次已实锤。

## ③ Node / V8 运行时观测（通用 Node 开关，`make dev` 环境前缀即可）

make 会把命令行变&#x91CF;__&#x5BFC;出到 recipe 环境__（Makefile release 注释已实测），所以直接前缀：

```sh
NODE_OPTIONS='--inspect' make dev                     # 挂 V8 调试器：chrome://inspect
NODE_OPTIONS='--inspect-brk' make dev                 # 首行断点，逐步看 boot
NODE_OPTIONS='--trace-warnings --trace-uncaught --stack-trace-limit=100' make dev
NODE_DEBUG=http,net,stream,tls,module,esm,vm make dev # Node 内建模块+ESM loader 的调试输出
                                                     #  → 直接看到前端请求/WS、TS 经 tsx 进 V8 的加载轨迹
NODE_OPTIONS='--prof' make dev                        # V8 CPU profile（.log → node --prof-process）
NODE_DEBUG_NATIVE=1 …                                 # C++/libuv 层
```

这套就是「观测 Node/V8 交互」主通道：DevTools 断点/内存/性能 + `module/esm/vm` 看 TS 源码如何被 ESM loader 送进 V8。

## ④ 前端 vite / HMR / 交互

- __开发热更环__（`make dev` 用 dist，不走 vite dev server）：`pnpm dsh web` 与 `pnpm run dev:web`（`harness/scripts/dev-web.ts`）一起跑 = watch 三阶段 `tsc client → tsdown → vite build → apps/web/dist`；`dsh web` 自己 __stat-poll 伺服产物并广播 `rebuilt` &#x5E27;__&#x89E6;发浏览器热刷（dev-web.ts 头注释）。
- vite 自身调试：`DEBUG=vite:*`（vite 用 `debug` 包）；网络盘用 `pnpm exec tsx scripts/dev-web.ts --poll=500`。
- 浏览器侧观测：DevTools 看 __WS（/api/remote.mux）+ Network__、boot 页 `loader-status` 显示每个 client entry 状态、`window.__DSH_BOOT__/__DSH_BOOT_READY__`；`client/connection` 的 RPC 走 `http-bridge`/`rpc.ts`。

## ⑤ harness 原生调试器：`@deepseek-ai/dsh-experimental-inspector`（CDP hub）

未默认挂载。它是个 __跨 realm 的 Chrome DevTools Protocol hub__：默认监听 __127.0.0.1:9230__，`captureFetch=true`（宿主 HTTP 抓包），并暴露 cordis 运行时树只读查询（`ctx.inspector.cordis`）。想要 V8/客户端 runtime 深度检查可挂：

```yaml
# /tmp/inspector.yml
- insert:
    - id: experimental-inspector
      name: '@deepseek-ai/dsh-experimental-inspector'
      config:
        host: '127.0.0.1'
        port: 9230
```

（配置项见 `packages/experimental/inspector/src/index.ts:74-99`。）

## ⑥ CLI / 构建设置面（非日志但排查有用）

- `dsh --profile dsh --dump-config`：装配树全貌（改配置没生效先看它）
- `--trusted-host <host[:port]>`（webStartup / fence）、`--no-open`
- 构建期 env：`DSH_BUILD_CLIENT_PROFILE`、`DSH_CLIENT_TITLE`、`DSH_CLIENT_COMMIT_HASH/…`（记录进 `.dsh-build/client-build-environment.json`）
- `TSX_TSCONFIG_PATH`：跑 `dev-web`/debugger 时要指到 `harness/tsconfig.json`（inspector 的 debugger e2e 就这么干）

## 组合建议（一次观测全程）

```sh
NODE_OPTIONS='--inspect --trace-warnings' NODE_DEBUG=http,net,module,esm \
DEBUG='vite:*' VERBOSE=1 TUNNEL_LOGLEVEL=debug \
make dev   # 建议先只开 ①的 levels.default:3 + NODE_DEBUG，别一上来全开（会刷屏）
```

## 诚实边界

- `[I]`：profile 的 live-reload 对 logger `levels` 是否真正热生效&#x6211;__&#x6CA1;实测__（大概率：HMR 是配置驱动、logger 是配置驱动），改成重启验证最稳。
- `[S]`：level 语义/查表（logger.ts:155）、logger-console 全量不过滤（shared.ts）、inspector 默认 port/开关（index.ts）、dev-web 三段 watch 与 rebuilt 广播（dev-web.ts 头注）、`make` env 导出（Makefile 注释）均源码/注释锚定。
- 官方文档站没有专门的 logging/debug 页（`/en/reference/` 只有架构目录），所以本清单&#x4EE5;__&#x6E90;码为准__。

要不要我：__(a)__ 把这份「日志与观测开关速查」追加成 `docs/dsh-deep-dive.md` 的附录；__(b)__ 实测一次「只加 `levels.default:3` 的冷启动」对比日志量给你看（需先停掉现在 3080 上那个冒烟实例）？
