# dsh-remote v0.6.3 评估文档 — agent / 插件架构维度评审

评审对象：`/Users/michaelyao/workspace/dsh/docs/dsh-remote.md`
源码：`/tmp/dsh-remote-review/src-v063`（dsh-remote v0.6.3，HEAD `baa6d533d3e4ce5e921b7bc5aa5c0a1689b2b7db`，与文档头部声明的 `baa6d53` 一致）
harness：`/Users/michaelyao/workspace/dsh/harness`（`dsh-v0.1.5-rc.2`，`fb2c4b9e69`）

评审方式：**纯静态阅读**，未运行任何代码、未安装、未联网。所有 `文件:行` 均为本次实际打开核对的坐标。

---

## 0. 总体判定

文档在「**源码坐标的准确性**」上表现很好：§10 索引里对 bridge 的行号引用几乎全部精确命中（`:109 :125 :151 :167 :360 :718`、`e2ee-client.mjs:723`，逐个核对无误）。对 harness 的三处引用（host 枚举、CLI 拒绝、信任围栏三道门）也**逐字属实**。

问题集中在**两个方向**：

1. **对「插件」这一侧的建模过窄**。文档把 dsh-remote 描述为「设置面板 + 同源路由」的插件加两个外部服务；实际上它的 node 半是一个**系统管理 agent**（后台 npx 自装、写 launchd/systemd、杀进程、`rm -rf` 配置目录、改写 profile、重启宿主、自更新）。§2/§3 的能力表与 §6.2 的「已核实」安全表因此都失真。
2. **两条承重推论没有被证伪，但各缺一个关键前提**：
   - §4.1 的推论（「伪装 loopback 不是通过围栏的必要条件」）**在 `/api` 请求围栏层面成立**，但漏了客户端半的 `ctx.connection.isLoopback` 这条独立闸门，所以「全部方法通过」这句话是过强的；
   - §6.4 推荐的「自建 relay」与 **E2EE 互斥**——自建模式下 E2EE 被代码硬关（`DSH_BRIDGE_LOCAL_KEY` → `disabled_by_config`），文档把自建当成 R1/R2 的解法，方向恰好相反。这是本次评审最重要的发现。

按严重度：**严重 3 条、中等 5 条、轻微 5 条**（详见文末计数）。

---

## 1. §2/§3：两个插件包是否确实是可挂载的 cordis 插件？

**文档原文**（§1.1、§2 表、§3 表、§6.2）：

> 「`packages/dsh-remote-web` 与 `packages/dsh-remote-ui` 都声明了 `dsh.bundle.patch` + `dsh.client.platform: web`，且 `lib/` **已提交在仓库内**（预构建）。」
> 「两个插件包的 `engines.dsh` 声明为 `>=0.1.0-rc.6 <0.2.0-0` —— **本仓的 `0.1.5-rc.2` 在范围内**。」

**源码证据**

| 字段 | 实际值 | 坐标 |
|---|---|---|
| `name` | `dsh-remote-web` / `dsh-remote-ui` | `packages/dsh-remote-{web,ui}/package.json:2` |
| `main` | `lib/index.js` | 同上 `:9` |
| `exports["./client"]` | `./lib/client.js` | 同上 `:12-14` |
| `dsh.bundle.patch` | `./cordis.patch.yml` | 同上（`dsh.bundle.patch` 字段） |
| `dsh.client.platform` | `web` | 同上 |
| `dsh.client.inject` | `["@deepseek-ai/dsh-client-runtime"]` | 同上 |
| `engines.dsh` | `>=0.1.0-rc.6 <0.2.0-0` | 同上 |
| `lib/` 已提交 | 是 — `git ls-files` 列出全部 4 个文件 | `git ls-files packages/dsh-remote-*/lib` |

harness 侧对这些字段的**真实消费点**（都已核实存在）：

- `dsh.bundle.patch` 是硬约束：`harness/packages/boot/app-boot/src/profile.ts:794` —— 被列进 `dsh.profile.bundles` 的包若没有 `dsh.bundle.patch`，会 `throw new Error('... declares no dsh.bundle ...')`。所以「声明了 `dsh.bundle.patch` ⇒ 是可挂载的 bundle」这个推断**成立**。
- `dsh.client.platform` / `dsh.client.inject` 会被校验与消费：`harness/packages/client/modules/src/index.ts:192-202`（缺 `platform` 直接抛错）、`:761-771`（`platform !== 'web'` 的行整体跳过）。

**判定：正确，但有一处措辞会误导。**

「`engines.dsh` … 本仓的 `0.1.5-rc.2` 在范围内」——语义范围计算是对的（`0.1.5-rc.2` > `0.1.0-rc.6` 且 < `0.2.0-0`），但文档把它放在 §6.2「已核实」表里，读起来像是一道被执行的兼容性闸门。**实际上 harness 完全不读 `engines.dsh`**：

```
grep -rn "\.engines\|engines\.dsh" --include="*.ts" harness/packages harness/apps harness/scripts
→ 无任何命中
```

**建议改法**：把该行从「宿主要求（已核实）」改为「**声明值（仅声明，harness 不校验）**：`engines.dsh: ">=0.1.0-rc.6 <0.2.0-0"`，语义上覆盖本仓 `0.1.5-rc.2`，但没有任何代码会强制它——兼容性仍需实测。」

---

## 2. 两个 entry id 是什么？同时挂载会不会重复挂载同一份实现？

**文档原文**（§2 表、§10）：

> 「`packages/dsh-remote-ui` | `dsh-remote-ui` | 同上，注释写明是「旧名别名，同步自 dsh-remote-web」」
> 「插件条目 id | `packages/dsh-remote-web/cordis.patch.yml`（`dsh-remote-web`）、`packages/dsh-remote-ui/cordis.patch.yml`（`dsh-remote-ui`）」

**源码证据**

entry id 确实分别是 `dsh-remote-web` / `dsh-remote-ui`：

```yaml
# packages/dsh-remote-web/cordis.patch.yml
- insert:
    - id: dsh-remote-web
      name: 'dsh-remote-web'
```

**但这不是「别名」，是「同一份实现的字面拷贝」。** `scripts/sync-legacy-alias.mjs` 是生成器，而它自己说清了性质：

- `scripts/sync-legacy-alias.mjs:11-13`：「别名包是"**自包含副本**"（默认 pnpm 从 git 子目录安装时不会带上目录外的文件，所以**不能靠相对路径 re-export**）」
- `:28-41`：替换规则只有 4 处字符串 —— `lib/index.js` 的 `PLUGIN_ID` 与 `PLUGIN_LEGACY_IDS`、`lib/client.js` 的 `id:` 与 `data-plugin`、`cordis.patch.yml` 的 `id`/`name`。

实际 diff 证实就是这 4 行：

```
diff packages/dsh-remote-web/lib/index.js packages/dsh-remote-ui/lib/index.js
1575c1575  const PLUGIN_ID = "dsh-remote-web";   →  "dsh-remote-ui";
1577c1577  const PLUGIN_LEGACY_IDS = ["dsh-remote-ui"];  →  ["dsh-remote-web"];
diff packages/dsh-remote-web/lib/client.js packages/dsh-remote-ui/lib/client.js
25c25      id: "dsh-remote-web",                  →  "dsh-remote-ui",
42c42      setAttribute("data-plugin", "dsh-remote-web")  →  "dsh-remote-ui"
```

**所以：同时挂载两者 = 挂载两份功能完全相同的实现，且必然冲突。**

冲突是**启动期硬报错**，不是「后者覆盖前者」：

- node 半两个包注册**完全相同的路由集**——28 条 exact 路由（`/dsh-remote/self`、`/dsh-remote/status`、`/dsh-remote/config`、`/dsh-remote/login`、…）加 1 条 prefix 路由 `/dsh-remote/feedback`（`packages/dsh-remote-web/lib/index.js:1729-2123`，`prefix: true` 在 `:2118`；ui 孪生包逐字节相同）。
- 注册走 `ctx.webServer.register`（`lib/index.js:2128`）。
- harness 对重复路径**直接抛错**：

```
harness/packages/host/webserver/src/index.ts:165-170
  register(route: WebRoute): () => void {
    const table = route.kind === 'exact' ? this.exact : this.prefixes
    if (table.has(route.path)) {
      throw new Error(`webserver: duplicate ${route.kind} route "${route.path}"`)
    }
```

即第二条会被 `webserver: duplicate exact route "/dsh-remote/self"` 打断。

**这不是假设性风险，而是本仓 `make setup` 会实际踩到的路径**：`scripts/link-plugins.sh` 的候选收集是「根包 + `plugins/*/packages/*/` 子包中声明了 `dsh.bundle.patch` 的包」（`scripts/link-plugins.sh:62` 与 `:89`）。若把 dsh-remote 作为 `plugins/dsh-remote/` 的 submodule 收进来，两个包**都会被收为候选**；而唯一的去重规则是「被其他候选依赖的候选不单独挂载」（`:142`，按 `dependencies`/`peerDependencies`/`optionalDependencies` 名字匹配），两个包 `.dependencies` 均为空、互不引用 → **两个都会被 `dsh plugin add link:` 挂进 profile**。

**判定：文档的「entry id」陈述正确；但对「别名」的定性不完整，且完全没有提示重复挂载会失败。**

**建议改法**：§2 表把 `dsh-remote-ui` 一行改为「**旧名的自包含副本**（非 re-export），内容与 `dsh-remote-web` 逐字节相同、仅 entry id 不同；**二者只能挂一个**，同时挂载会因 `/dsh-remote/*` 路由重复注册在启动期抛 `webserver: duplicate exact route`」。§8 的第 1/2 条相应加一句：「源码引入时必须**显式排除 `packages/dsh-remote-ui`**，否则 `link-plugins.sh` 会把两个都当候选挂上（两者 `.dependencies` 为空，不会触发去重规则）。」

---

## 3. §4 引用的 harness 行为是否属实

### 3.1 `host: z.union([...])` 的位置与含义 — **正确**

**文档原文**：`harness/packages/host/webserver/src/index.ts:126`

**源码证据**（逐字命中）：

```
harness/packages/host/webserver/src/index.ts:126
    host: z.union([z.const('127.0.0.1'), z.const('0.0.0.0')]).required(),
```

类型面也印证「只有两个字面量」：同文件 `:60-61` `/** Listen host; the two supported values are loopback and all-interfaces. */ host: '127.0.0.1' | '0.0.0.0'`。

**判定：正确**（行号、字面量、语义全对）。

### 3.2 CLI 拒绝 `--host 0.0.0.0` — **正确，行号差 1 行**

**文档原文**：`harness/packages/bundle/web-app/src/startup.ts:74-76`，报错原文「`--host 0.0.0.0 is intentionally not supported yet for safety: ...`」

**源码证据**：

```
harness/packages/bundle/web-app/src/startup.ts:74-76
    if (options.host === '0.0.0.0') {
      program.error('error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127.0.0.1 instead')
    }
```

（`program.error(...)` 落在 **:75**；引用的字符串与文档摘录逐字一致。）

**判定：正确**（仅 `:74-76` 中的确切行是 75，属于可接受的区间引用）。

**顺带一个文档未提的正面事实**：同文件 `:54` 定义了 `--trusted-host <authority...>`「extra authority the /api browser-trust fence accepts (host or host:port; repeatable)」，`:84` 把它送进 `trustedHosts: options.trustedHost ?? []`。这是 §7 方案 B 的直接支撑，文档在 §4.1/§7 用到了它，但没引用这两行——建议补上，让方案 B 的可行性有源码落点。

### 3.3 信任围栏 `isTrustedApiRequest` 的实现与调用点 — **文档的核心推论成立，但漏了一条独立闸门**

**文档原文**（§4.1）：

> 「**本仓 harness（0.1.5-rc.2）核实不到该机制**：全仓无 `PRIVILEGED_METHODS`；`isTrustedApiRequest` 全仓**只有一个调用点**（`harness/packages/client/connection/src/rpc-host.ts:98`），传的是 `this.trustedHosts` 而非空数组。」

**源码证据（逐条核实）**

三道门的实现与文档描述**逐条一致**（`harness/packages/client/connection/src/api-request-trust.ts:91-118`）：

| 门 | 坐标 | 行为 |
|---|---|---|
| Host 必须 loopback 或 `trustedHosts` | `:99-103` | 无 Host → false；不可解析 → false；`!isLoopbackHostname && !isTrustedAuthority` → false |
| `Sec-Fetch-Site: cross-site` → 拒 | `:106` | 硬拒 |
| 有 Origin 必须与 Host 同源；无 Origin 放行 | `:111-117` | `origin === undefined` → `return true` |

调用点核实（全仓 `--include=*.ts/tsx/js/mjs` 搜索，排除 `node_modules`）：

- **生产代码只有一处**：`harness/packages/client/connection/src/rpc-host.ts:98`

```
harness/packages/client/connection/src/rpc-host.ts:97-99
  requestRejection(request: ConnectionTrustRequest): ConnectionRequestRejection {
    if (!isTrustedApiRequest(request, this.trustedHosts)) return 403
    return this.browserAuth.isAuthenticated(request) ? undefined : 401
  }
```

- 其余全部命中都在测试里（`packages/client/connection/tests/api-request-trust.host.spec.ts`）。
- `PRIVILEGED_METHODS` 字面量：全仓**零命中**（`grep -rn "PRIVILEGED_METHODS"` 无输出）。名字相近的只有实验包里的 `privilegedMethods`（`packages/experimental/webworker-runtime/src/transport/tunnel.ts:118-121`），那是 worker 隧道内部概念，与 `/api` 权限无关。
- `requestRejection` 的消费点也是**单一**的（经 `open-in-app`、`api/gateway`、`connection` 三处，全部走同一个 `connection.requestRejection`），不存在第二条按 Host 分权的旁路。

**所以 §4.1 的推论成立**：本版本**没有**「特权方法钉死 loopback」的服务端机制。配合 `--trusted-host <域名>` + 保留 Host 的普通反代，`/api` 请求能整体通过围栏（403 那一关），只余 `browserAuth` 的 401 认证关。**判定：正确。**

**但文档漏了一条独立的、名字不同的等价闸门 —— 客户端半的 `isLoopback`：**

```
harness/packages/client/connection/src/client/index.ts:227
    isLoopback: transport?.ownsHost === true || pageLocation === undefined || isLoopbackHostname(pageLocation.hostname),
```

`isLoopbackHostname` 只认 `localhost` / `[::1]` / `127.0.0.0/8`（`harness/packages/client/connection/src/loopback-hostname.ts:12-18`）。它的语义在 `client/index.ts:114-118` 写得很明白：「Whether the privileged surface is reachable: the page authority is loopback, the transport declares the page owns the Host (`ownsHost`), **or the context is not a browser**」。

对手机（`https://<中继域名>/`）、以及 §7 方案 B 的反代页面（`https://<你的域名>/`），`pageLocation.hostname` 都不是 loopback → **`isLoopback === false`**。它实际闸住的东西：

- `harness/packages/client/ui-settings/src/client/index.ts:58` —— `const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'`（设置文档的持久化模式：非 loopback 退化为进程内 memory，**设置改动不回写宿主**）
- `harness/packages/client/ui-settings-general/src/client/index.ts:76-78` —— `documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(...) : undefined`（整个设置文档控制器不存在）
- 影响面注释：`harness/packages/client/ui-settings-models/src/client/index.ts:100-101`「The scope's own memory mode is what keeps a **remote browser process-local**」

注意这条闸门是按**页面 authority**判定的，而 bridge 只重写 HTTP `Host` 头（`clients/dsh-remote/dsh-bridge.mjs:360` `out.Host = up.host`），**改不了浏览器的 `location.hostname`**——所以 §7 方案 B 与方案 C 在这一条上是**同等的**，都不会因为「伪装 loopback」而恢复这部分能力。

**判定：文档 §4.1 的「围栏层面」推论正确；但由它推出的「`--trusted-host` + 反代能让全部方法通过」（§4.1 末句）以及 §6.3 的 R4「DSH 自身那层防护对远程用户不再起作用」都**过强**：请求围栏确实失效，但 `ctx.connection.isLoopback` 这一层仍然按页面域名生效，远程会话拿到的是「非特权」客户端形态（设置只读、不落盘）。

**建议改法**：在 §4 结论块后补一段：

> **④ 客户端半的 loopback 判定（文档此前遗漏）**：`harness/packages/client/connection/src/client/index.ts:227` 用页面域名判 `ctx.connection.isLoopback`（`loopback-hostname.ts:12-18`）。bridge 只重写 HTTP `Host`，改不了浏览器的 `location.hostname` —— 因此无论用中继还是反代，远程页面的 `isLoopback` 都是 `false`，设置类 UI 会退化成进程内 memory 模式（`ui-settings/src/client/index.ts:58`、`ui-settings-general/src/client/index.ts:76-78`）。**「方法全部通过」只对 `/api` RPC 围栏成立；DSH 的 loopback 语义没有被完全绕过**，§7 的方案 B 与方案 C 在这一点上等价。

并把 §4.1 末句改为「…也能让 `/api` 请求整体通过**请求围栏**（余下仍有 `browserAuth` 的 401 认证关）」。

---

## 4. §5 描述的首次配置流程与源码是否一致？

### 4.1 relayDir / 配置文件 / 面板 / 路由 —— **正确**

**文档原文**（§8.2，§5）：

> 「它默认读 `~/.dsh-remote/.dsh-config.json`，那是 `npx` 安装器写的」
> 「`dsh web → 设置 →「远程访问」`」

**源码证据**

| 项 | 实际值 | 坐标 |
|---|---|---|
| 默认 relayDir | `process.env.DSH_RELAY_DIR \|\| join(homedir(), ".dsh-remote")` | `packages/dsh-remote-web/lib/index.js:27` |
| entry config 覆盖 | `config.relayDir \|\| process.env.DSH_RELAY_DIR \|\| DEFAULT_RELAY_DIR` | 同 `:2163`（`apply()` 内） |
| 配置文件 | `join(relayDir, ".dsh-config.json")`，写 `mode: 0o600` + `chmodSync` 兜底 | 同 `:178-179`、`:193-195` |
| 面板挂载点 | `settings.section` 槽，`id: "dsh-remote"`，`order: 30`，`label: "📱 远程访问"` | `lib/client.js:2321-2326` |
| 附加槽 | `shell.overlay`，`id: "dsh-feedback-popup"`，`order: 90` | 同 `:2328` |
| 路由 | 28 条 `/dsh-remote/*` exact + `/dsh-remote/feedback` prefix，经 `ctx.webServer.register` | `lib/index.js:1729-2123`、`:2128` |

槽位在 harness 侧确实存在且语义相符：`harness/packages/client/ui-settings/src/client/contract/slots.ts:54`（`'settings.section': { kind: 'list'; scope: 'root'; ... }`）、`harness/packages/client/ui-layout/src/client/index.ts:91`（`'shell.overlay': { kind: 'list'; scope: 'root' }`）。

**判定：正确。** 顺带确认「`order: 30` > Agent 预设(20)、落在其下方」的说法与 `lib/client.js:2318-2323` 的注释一致。

### 4.2 「账号体系 / 访问密钥 / 一次性扫码链接」——**这条把 SaaS 能力当成了通用流程**

**文档原文**（§5）：

> 「2. dsh web → 设置 →「远程访问」
>  → SaaS 模式：手机端注册/登录手机号（电脑端扫码/登录）
>  → 自建模式：`npx @mrrisega/dsh-remote setup --server wss://<你的域名>:端口 --key <访问密钥>`
> 3. 手机打开远程地址；电脑端生成**一次性扫码登录链接**（30 分钟有效、访问一次即失效、可取消配对）」

**源码证据**

第 3 步的一次性链接/二维码**依赖作者的商业后端**，不是本地生成：

```
packages/dsh-remote-web/lib/index.js:1277-1310  （proxyCreateAccessKey）
 * GET /dsh-remote/access-key → 创建一次性访问密钥（企业端 POST /api/auth-key，Bearer device-login token）。
  const r = await relayFetch(relayDir, "/api/auth-key", { method: "POST", headers: { authorization: `Bearer ${token}`, ... } })
```

`relayFetch` 的目标是 `cfg.api_url || DEFAULT_API`（`:897-899`），而 `DEFAULT_API = "https://n.risegao.cn:13443/relay-api"`（`:29`）。同一模式还用于设备管理 `/dsh-remote/mobile-sessions`（`:1313+`）。

**自建的 `relay-router` 完全不实现 `/api/*`**。它的全部路由面是：

```
packages/relay-router/src/index.mjs
  :532   POST /_login          （访问密钥换本地 JWT）
  :564   GET  /_devices        （实时设备列表）
  :584   GET  /_quota
  :412/:475  /remote/<deviceId>/<path>  （HTTP/WS 代理）
  :933   /_bridge              （bridge 注册）
  :609-612  兜底 → 404 "not found (router: 请使用 /remote/<deviceId>/<path>)"
```

`grep -rn "auth-key|mobile-sessions" packages/relay-router/` 在业务代码里**零命中**（唯一命中是 PWA `native.html` 里的 `/api/auth-key/exchange` 字符串匹配测试）。自建模式的登录模型见 `docs/self-hosting.md`：「**no account system**: authentication is a simple access key… `DSH_LOCAL_ACCESS_KEYS` (comma-separated) → `POST /_login` → 2h local JWT」，手机端在 `/app/` 的访问密钥表单登录。

**判定：不完整 / 有误导。** 「一次性扫码链接（30 分钟、一次性、可取消配对）」是 **SaaS / 企业端专属**能力；在文档自己推荐的「自建 relay」路径上，它是**不存在**的——自建走的是「访问密钥 + 2h JWT」，没有二维码、没有一次性链接、也没有「已授权设备」列表。连带影响：

- §6.4 加固清单第 3 条「一次性扫码链接是其安全设计的一部分——**用完即刷新**」——自建模式下无此物；
- §6.4 第 5 条「定期在「**已授权设备**」里清理配对」——自建模式下无此物；
- §7 建议「**优先自建 relay**」——需要说明自建的代价是**换成另一套认证模型**，而非同一套能力换个中继。

**建议改法**：§5 拆成两个独立小节「SaaS 模式流程」与「自建模式流程」，明确标注能力差异表：

| 能力 | SaaS（作者中继） | 自建（`relay-router`） |
|---|---|---|
| 登录 | 手机号账号 + 图形/短信验证码 | 访问密钥 `POST /_login` → 2h JWT |
| 一次性扫码链接 | 有（`/api/auth-key`） | **无** |
| 已授权设备管理 | 有（`/api/mobile-sessions`） | **无**（仅 `/_devices` 实时在线列表） |
| E2EE | 可开（灰度） | **代码硬关**（见 §6） |
| 手机端页面 | 作者托管的 `app_url` | 需自己 nginx 托管 `clients/dsh-web/native.html` |

并把 §6.4 第 3、5 条限定为「SaaS 模式适用」。

---

## 5. §8「源码安装」落地方式是否可行且完整？

**文档原文**（§8）：

> 「1. 作为 submodule 收进本仓…两个插件包的 `lib/` 已提交 → 挂载时**跳过构建**；`packages/dsh-remote-web` / `packages/dsh-remote-ui` 是 **workspace 子包**（不是仓库根包），需按 `plugins/*/packages/*` 的子包候选处理。
> 2. 插件半（`dsh-remote-web`）可按既有方式 link 进 profile —— 但先确认它与 `clients/dsh-remote`（bridge）的配合方式：它默认读 `~/.dsh-remote/.dsh-config.json`，那是 `npx` 安装器写的；源码安装需要手工准备该配置（或改 `relayDir`）。
> 4. **不执行 `npx @mrrisega/dsh-remote` 的自动安装**（会写配置 + 装开机自启）；先用前台方式（`run`）跑通。」

### 5.1 正确的部分

- 「workspace 子包、需按 `plugins/*/packages/*` 处理」—— **正确**：`scripts/link-plugins.sh:62,89` 确实同时扫描 `plugins/*/` 根包与 `plugins/*/packages/*/` 子包，筛条件是 `dsh.bundle.patch`。两个包都满足（见 §1）。
- 「`lib/` 已提交 → 跳过构建」—— **正确**：`scripts/setup.sh:207-209` 读 `package.json` 的 `main` 并 `git ls-files --error-unmatch`，`main = lib/index.js` 是已跟踪文件，命中跳过构建分支。

### 5.2 承重错误：第 4 条做不到，第 2 条的判断漏了关键依赖

**（a）插件会自己跑 `npx`——「不执行自动安装」这条无法通过「只挂插件」实现。**

`apply()` 里除了注册路由，还无条件挂了三个自愈 effect：

```
packages/dsh-remote-web/lib/index.js:2163-2189  （export function apply）
  :2163  const relayDir = config.relayDir || process.env.DSH_RELAY_DIR || DEFAULT_RELAY_DIR;
  :2168  ctx.effect(() => registerRoutes(ctx, relayDir), 'dsh-remote-web: /dsh-remote routes');
  :2170  ctx.effect(() => scheduleHarnessMint(ctx, relayDir), '... browser-session mint');
  :2172  ctx.effect(() => scheduleRuntime(relayDir), 'dsh-remote-web: runtime self-provision');
  :2188  const provisioned = ensureRuntime(relayDir);
```

而 `ensureRuntime` 的就绪判据只是「配置目录里有没有 `dsh-setup.mjs`」，没有就是一条 detached 的 `npx`：

```
:300-301  function runtimeReady(relayDir) { return existsSync(join(relayDir, "dsh-setup.mjs")); }
:428-455  function ensureRuntime(relayDir) {
            if (UNINSTALLED_DIRS.has(relayDir)) return false;
            if (runtimeReady(relayDir)) return true;
            if (skipsSystemOps()) return false;        // 仅 DSH_RELAY_SKIP_SERVICE=1（测试隔离）
            ...
            const child = spawn(npxCommand(), ["--yes", UPDATE_SPEC], { detached: true, ... });
```

`UPDATE_SPEC = \`@mrrisega/dsh-remote@${UPDATE_TAG}\``（`:1592`）。`scheduleRuntime`（`:572-600`）按 `selfhealIntervalMs()` 轮询重试，掉线后自动拉起 bridge。

**所以：只要插件被挂载、且 `~/.dsh-remote/dsh-setup.mjs` 不存在，插件自己就会执行 `npx @mrrisega/dsh-remote`。** 文档 §8 第 4 条「不执行 `npx` 的自动安装」在「link 插件进 profile」这条路上**不成立**。唯一可控的开关是 `DSH_RELAY_SKIP_SERVICE=1`，但那是**测试隔离**用途（`:308-310`），生产上设它会让卸载/自启/重启全部跳过——不是文档想要的语义。

**（b）源码形态下 `dsh-setup.mjs` 会把配置目录选成「checkout 自己」，且不做固化拷贝。**

```
dsh-setup.mjs:34-36
const IS_NPM_INSTALL = THIS_DIR.includes(`${path.sep}node_modules${path.sep}`);
const CONFIG_DIR = process.env.DSH_RELAY_DIR || (IS_NPM_INSTALL ? path.join(os.homedir(), ".dsh-remote") : THIS_DIR);
dsh-setup.mjs:69
  if (!IS_NPM_INSTALL) return;   // 仓库开发形态：原地使用（跳过把运行时固化到 CONFIG_DIR）
```

源码 checkout 不是 npm 安装 → `IS_NPM_INSTALL === false` → `CONFIG_DIR = THIS_DIR`，且 `:69` 提前返回、**不会**把 `dsh-setup.mjs` 拷进配置目录。后果有两个，文档都没提：

1. 从源码跑一次运行时，凭据（`.dsh-config.json`、设备私钥、`.harness-cookie.json`，全部 0600）会落在**被 pin 的 submodule 目录里**（`plugins/dsh-remote/`）——对「submodule 只读 pin」的本仓约定是直接冲突。
2. 因为 `:69` 提前返回，`<relayDir>/dsh-setup.mjs` 永远不会在源码形态下出现 → `runtimeReady()` 恒为 `false` → 插件**持续**认为运行环境缺失，反复触发 `npx` 补装。

**唯一的干净出路是 `DSH_RELAY_DIR`**（`:36` 与插件 `:27` 都优先读它）——把配置目录显式指到 checkout 之外。**文档完全没提这个环境变量**，只说「手工准备 `~/.dsh-remote/.dsh-config.json` 或改 `relayDir`」，方向对但没给到真正的开关。

**（c）插件需要 bridge 已经在运行吗？——不是「先跑 bridge」，而是「要不要让插件替你装 bridge」。**

插件面板的所有数据都经 `/dsh-remote/*` 代理到 `bridge`/relay（`relayFetch` → `cfg.api_url`），而 relay 侧要 `bridge_secret`。插件自己的代码注释把这个鸡生蛋问题写得很清楚：

```
packages/dsh-remote-web/lib/index.js:905-930（节选）
 * 企业端 POST /api/device-login 强制校验 `x-dsh-bridge-secret`（缺失/失效 → 401 "需要有效设备密钥"），
 * 密钥由服务端公开配置 /api/public-config 下发、与 dsh-setup.mjs 的 `bridge_secret` 同源。
 * 一键安装器…会在安装时取一次并写入 .dsh-config.json；
 * 但**只装插件**的路径（dsh plugin add / 插件市场安装）没有这一步，于是：
 *   首次安装 → 打开设置面板立即登录 → 面板请求 /dsh-remote/access-key & mobile-sessions
 *   → relayToken 拿不到 token（401 需要设备密钥）→ 面板显示「尚未登录」（其实是密钥缺失）
 * 直到后台自愈（scheduleRuntime → ensureRuntime 跑一次 npx 安装器）把 bridge_secret 写回配置
```

**即：源码安装下必须自己把 `bridge_secret`（以及账号/访问密钥）写进 `.dsh-config.json`，否则面板会静默显示「尚未登录」** —— 这正是文档 §8.5 列为「待验证」的那件事，实际是**已知且已在代码注释里记录**的确定行为，不需要实测就能定论。文档把它标成「源码安装下插件面板能否正常读到配置（`relayDir` 路径问题）」，低估了：不是路径问题，是**凭据缺失**问题。

**（d）文档未提但风险更高的一条：插件会改写 profile 与重启宿主。**

- `uninstallSelf(relayDir, profileDir, patchFile, pkgFile)`（`:1674-1712`）直接**编辑 profile 的 `cordis.patch.yml` 与 `package.json`**（删 `dependencies` 条目、从 `dsh.profile.bundles` 里 filter 掉、`rmSync` 掉 `<profileDir>/node_modules/<id>` 与 `<profileDir>/<id>-plugin`），profileDir 由 `import.meta.url` 反推（`:1719-1727`）。
- `restartHarness(relayDir)`（`:849-893`）会用 `launchctl kickstart` / `systemctl restart` **重启 DSH 宿主进程本身**，并暴露成 `/dsh-remote/harness/restart` 路由（`:1940-1944`）。
- 自更新走 detached `npx`（`:1620+`），且注释里记录了历史上「旧版把用户 include 写回 profile → dsh web 重启重复 ID 崩溃」（`:1621`、`:427`）。

对本仓而言这是**越界**：profile 由 `scripts/link-plugins.sh` + `scripts/merge-profile-patch.mjs` 管理，而这个插件会在运行中改同一批文件。§8 应当把它列为一条独立的落地风险。

**判定：§8 的骨架（submodule + 子包候选 + 跳过构建 + 三部分分开部署）可行且有依据；但第 2 条的结论不完整、第 4 条在插件形态下做不到。**

**建议改法**：把 §8 第 2、4 条重写为：

> 2. **插件半挂载（有前置条件）**：`dsh-remote-web` 可按既有方式 link 进 profile，但**必须**：
>    - 只挂 `dsh-remote-web`，**排除 `packages/dsh-remote-ui`**（否则重复路由启动即失败，见 §2）；
>    - 用 `DSH_RELAY_DIR=<checkout 之外>/.dsh-remote` 显式指定配置目录（源码形态下 `dsh-setup.mjs` 会把 `CONFIG_DIR` 解析成 checkout 自己，凭据会落进被 pin 的 submodule）；
>    - 手工写入 `bridge_secret` + 账号/访问密钥，否则面板会一直显示「尚未登录」（代码注释 `lib/index.js:905-930` 已记录该失效模式）。
> 4. **「不执行 npx 自动安装」这条在挂载插件的前提下做不到**：`apply()` 会调 `ensureRuntime()`（`lib/index.js:2188`），只要 `<relayDir>/dsh-setup.mjs` 不存在就会 detached 跑 `npx --yes @mrrisega/dsh-remote@latest`，并按 `selfhealIntervalMs()` 反复重试。要真正拦住只有两个办法：让 `runtimeReady()` 为真（即接受它装运行时），或改源码/打补丁。**接受一次 npx 安装、随后用前台 `run` 跑 bridge，是更现实的路线。**
> 6. **新增风险**：该插件会在运行中改写 profile（`uninstallSelf`，`lib/index.js:1674-1712`）并可重启宿主进程（`restartHarness`，`:849`、路由 `:1940`）。本仓 profile 由 `scripts/link-plugins.sh` 管理，二者存在写入冲突面，动手前需明确由谁负责 profile。

---

## 6. 文档遗漏的重要架构事实

按对决策的影响排序。

### 6.1 【严重】E2EE 与「自建 relay」互斥 —— §6.4 的首选加固项与 R2 的解法方向相反

**文档原文**（§6.3 R2、§6.4 第 1 条）：

> R2：「E2EE 默认关闭（灰度）…**未开启时，内容在中继处可被读取**。面板会显示当前状态，但你需要主动确认它是否真的启用了。」
> 加固 1：「**决定中继归属**：能自建就自建（`packages/relay-router` 部署到自己的公网机器），避免内容经过第三方；用 SaaS 则务必**确认 E2EE 已真正开启**。」

**源码证据 —— 自建模式直接把 E2EE 关掉，这是设计决定，不是灰度：**

```
clients/dsh-remote/dsh-bridge.mjs:1014-1018
async function initE2ee(token) {
  const cfg = loadLocalConfig();
  const localMode = Boolean(process.env.DSH_BRIDGE_LOCAL_KEY); // 自建模式不启用(§6.6)
  const userDisabled = process.env.DSH_BRIDGE_E2EE === "0" || cfg.e2ee === false;
  const allowed = !localMode && !userDisabled;
```

`DSH_BRIDGE_LOCAL_KEY` 正是 `dsh-setup.mjs` 在自建模式写入的变量：`dsh-setup.mjs:321` `let local = Boolean(cfg.local_key);`、`:354` `...(local ? { DSH_BRIDGE_LOCAL_KEY: cfg.local_key } : {})`。`allowed === false` → `E2eeService.init` 直接返回 `disabled_by_config`：

```
clients/dsh-remote/e2ee-client.mjs:566-571
  static async init({ apiBase, token, password, allowed = true, profileHint = "" } = {}) {
    if (!allowed) return new E2eeService({ enabled: false, reason: "disabled_by_config" });
    if (String(token || "") === "") return new E2eeService({ enabled: false, reason: "no_token" });
    if (String(password ?? "") === "") return new E2eeService({ enabled: false, reason: "no_password" });
    const params = await fetchE2eeParams(apiBase, token);
    if (!params.enabled) return new E2eeService({ enabled: false, reason: params.reason });
```

而且即使放开 `allowed`，E2EE 还需要 `GET {apiBase}/api/e2ee-params`（`e2ee-client.mjs:124-131`，`apiBase` 来自 `API_BASE = https://n.risegao.cn:13443/relay-api`，`dsh-bridge.mjs:111`）——`relay-router` 同样不提供这个端点（见 §4.2）。

**含义（文档的核心建议需要反转）**：

- 选**自建 relay**：中继是你自己的，但**内容以明文经过中继**（E2EE 被硬关）。对「中继不可信」这个威胁模型而言这是合理权衡（中继是你自己），但文档必须说清：**自建买到的是「中继归你」，代价是「永久失去 E2EE」**。
- 选**作者的 SaaS**：中继是第三方，但**可以**开 E2EE。文档 R2 说「确认 E2EE 是否真的启用」——只有这条路上「确认」才有意义。
- 文档 §6.4 第 1 条把两者写成「自建更好，用 SaaS 才需确认 E2EE」，把**互斥关系**读成了**递进关系**。

**建议改法**：§6.3 R2 补一句「**注意：自建 relay 与 E2EE 在 v0.6.3 互斥**（`dsh-bridge.mjs:1016` 自建模式置 `disabled_by_config`，`e2ee-client.mjs:568`）——自建意味着内容对你自己的中继明文可见」；§6.4 第 1 条改写为「在『中继归谁』与『内容是否加密』之间**二选一**：自建=中继可信但无 E2EE；SaaS=有 E2EE（需确认开启）但中继是第三方。请按你的威胁模型选，不要默认自建更安全。」

### 6.2 【严重】§6.2「只有一处 `execSync`」是错的，差了至少 4 处

**文档原文**（§6.2「已核实」表）：

> 「危险原语 | 全部代码中**只有一处** `execSync`：`clients/dsh-remote/dsh-bridge.mjs:125` …**非恶意**；无 `eval` / `new Function`」

**源码证据**（逐文件计数，仅统计 git 跟踪的 `.js`/`.mjs`；已排除 import 行与注释）：

```
packages/dsh-remote-web/lib/index.js  :37   execSync(cmd, {...timeout:15000})     ← 通用 sh() 执行器
packages/dsh-remote-web/lib/index.js  :695  execSync("sleep 1", {timeout:3000})
packages/dsh-remote-ui/lib/index.js   :37   同上（该包是 web 的逐字节副本）
packages/dsh-remote-ui/lib/index.js   :695  同上
dsh-setup.mjs                         :104  execSync(cmd, {...timeout:timeoutMs}) ← 同为通用 sh() 执行器
clients/dsh-remote/dsh-bridge.mjs     :125  execSync("ioreg -rd1 -c IOPlatformExpertDevice", ...)
```

即 **6 处真实调用、跨 4 个文件**（`dsh-remote-ui` 是 `dsh-remote-web` 的逐字节副本，去重后是 4 个逻辑调用点）。文档指出的那一处（`dsh-bridge.mjs:125`）只是其中之一，且是**危害最小**的一处（固定字符串、读硬件 UUID）。真正值得关注的是两处**通用命令执行器**：

```
packages/dsh-remote-web/lib/index.js:36-39
function sh(cmd) {
  try {
    const stdout = execSync(cmd, { encoding: "utf8", stdio: ["ignore","pipe","pipe"], timeout: 15000 });
```

`sh()` 的调用面覆盖 `launchctl bootout`、`systemctl --user stop/disable/is-active`、`pgrep`/`ps` 等（`:524-560`、`:640-700` 一带），`dsh-setup.mjs:104` 是同一模式。

**「无 `eval` / `new Function`」这一半是对的**——用更宽的模式（`\beval\s*\(`、`new Function\s*\(`、`Function\s*\(\s*['"]`）在全部跟踪的 `.js`/`.mjs`/`.html` 上搜索，**零命中**。

**判定：错误（半数）**。这是文档最「安抚性」的一行，且被放在「已核实」表里，恰恰是审计深度不足处（§6.1 自陈只做了扫描）最容易出错的地方，而它错在了**最不该错的方向**（把 6 处说成 1 处，且把危害最小的那处当作唯一）。

**建议改法**：§6.2 该行改为「危险原语 | **`execSync` 6 处真实调用、跨 4 个文件**：`clients/dsh-remote/dsh-bridge.mjs:125`（ioreg 读硬件 UUID，唯一固定命令）、`packages/dsh-remote-web/lib/index.js:37` 与 `:695`、`dsh-setup.mjs:104`，外加 `dsh-remote-ui` 的同两处副本。其中 `:37` 与 `dsh-setup.mjs:104` 是**通用命令执行器**，驱动 `launchctl`/`systemctl`/`pgrep`/`ps`。无 `eval`/`new Function`（已用宽模式核实）。**这些是系统管理用途，未见混淆或外传，但『值得信任』的判断应基于代码可读性而非『只有一处』**」。并考虑把该行从「已核实」移到「已扫描、未逐行审计」。

### 6.3 【严重】§2/§3 把插件半描述得过窄 —— 它是个系统管理 agent

**文档原文**（§2 表、§3）：

> 「`packages/dsh-remote-web` | `dsh-remote-web` | **DSH 插件**：设置页「远程访问」面板 + 同源 `/dsh-remote/*` 路由；`lib/` 已提交（预构建）」

**源码证据**：`lib/index.js` 开头的自述（`:1-17`）已经比文档丰富，实际能力（全部有坐标）：

| 能力 | 坐标 |
|---|---|
| 读写配置 0600 | `:178-195` |
| launchd 状态/启停；plist 缺失时**自动生成** | `:308+`、`:464`（`writeAutostartFile`）、`:524`（`startBridge`） |
| systemd user unit 生成/启停 | `:524+`、`:640-700` |
| 杀残留进程（SIGTERM → 1s → SIGKILL） | `:690-700` |
| **`rm -rf` 配置目录**（带护栏：非 `/`、非 home、非 profile 目录） | `uninstallRuntime` `:640-712` |
| **改写 profile**（`cordis.patch.yml` / `package.json` / `node_modules`） | `uninstallSelf` `:1674-1712` |
| **重启 DSH 宿主**（launchd/systemd/自拉起） | `restartHarness` `:849-893`，路由 `:1940` |
| **后台 `npx` 自装运行时** | `ensureRuntime` `:428-455`，由 `apply` `:2188` 与 `scheduleRuntime` `:572-600` 驱动 |
| **`npx` 在线自更新**（detached，官方源优先、镜像回退） | `:1620-1680` |
| Harness 会话 Cookie 代持（写 `.harness-cookie.json` 供 bridge 携带） | `mintHarnessCookie` `:237-266`、`scheduleHarnessMint` `:268-286` |

**判定：不完整。** 「面板 + 路由」的定性会让读者（和评审 §8 落地方式的人）低估三件事：**它会自己装东西、会改 profile、会重启宿主**。§3 表格里「额外组件：无 / 还有 bridge 与 relay」这行也应补一列「插件自身也会反向驱动 bridge 与运行时的安装与生命周期」。

**建议改法**：§2 表该行改为「**DSH 插件（宿主侧兼运行环境管理器）**：设置页「远程访问」面板 + 同源 `/dsh-remote/*` 路由；**并主动管理 bridge 的运行环境**（后台 `npx` 补装、写 launchd/systemd 自启、启停与杀进程、`rm -rf` 配置目录、改写 profile、重启宿主、`npx` 自更新）」。

### 6.4 【中等】`dsh.client.inject` 指向一个不存在的包

**文档未提及。** 两个插件包都声明：

```json
"dsh": { "client": { "platform": "web", "inject": ["@deepseek-ai/dsh-client-runtime"] } }
```

**源码证据**：`@deepseek-ai/dsh-client-runtime` **在 harness 全仓与本机 `node_modules` 都不存在**：

```
grep -rn "dsh-client-runtime" harness/ (含 lib/types、package.json、pnpm-lock.yaml 之外的 ts/json/js)  → 零命中
ls harness/node_modules/@deepseek-ai/  → dsh-agent, dsh-package-manifest, dsh-tool-session-query, dsh-web-fetch-http
harness/tsconfig.base.json:188  →  只有 "@deepseek-ai/dsh-client-test-runtime"（test-support 包，名字不同）
```

harness 自带的客户端插件没有一个用这个名字——它们的 `inject` 全是真实存在的兄弟包（如 `@deepseek-ai/dsh-api-gateway`、`@deepseek-ai/dsh-client-connection`、`@deepseek-ai/dsh-client-ui-settings`）。

**好在它是无害的**：`inject` 的消费点是「先装载被注入的行」，未注册的名字被**静默跳过**：

```
harness/packages/client/modules/src/client/system.ts:165-168
    for (const packageName of row.inject) {
      const dependency = this.graphRows.get(packageName)
      if (dependency !== undefined) await this.arriveGraphRow(dependency, [], visited)
    }
```

**判定：不完整（构成本层面）。** 这不是 bug，但它意味着**插件声明的浏览器半契约不是真的**：它实际只需要 `react` 种子模块（`lib/client.js` 全文只有一处 `require("react")`，与其 README「only requires `react` (seed module)」一致）。文档若要评估「这个插件的浏览器半会不会解析失败」，需要知道 `inject` 在这里是空转；而 `settings.section` / `shell.overlay` 两个槽才是真实依赖（两槽都存在，见 §4.1）。

**建议改法**：§3 或 §6.2 加一行：「`dsh.client.inject` 声明了 `@deepseek-ai/dsh-client-runtime`，但该包在 harness 中不存在（`inject` 未命中会被静默跳过，`packages/client/modules/src/client/system.ts:165-168`）——属无效声明，不影响加载；浏览器半的真实依赖是 `react` 种子模块与 `settings.section` / `shell.overlay` 两个槽。」

### 6.5 【中等】`clients/dsh-web/native.html` —— 手机端真正的 UI 是一个独立可部署件

**文档原文**（§2 表末行）：

> 「`clients/dsh-web` | — | 客户端资源（`native.html`）」

**源码证据**：`clients/dsh-web/` 下**只有** `native.html`，没有 `package.json`（所以「包名 = —」是对的），**2712 行**。

自建模式下它是必须自行托管的第三个部署件——`docs/self-hosting.md`：「`clients/dsh-web/native.html` is a single-file PWA. Point nginx at it… `location /app/ { alias /srv/dsh-remote/app/; … }`」；手机在这个页面用**访问密钥**登录（`/_login`）。

**判定：不完整。** 「客户端资源」这个说法掩盖了它是自建部署的**必需件**，也是 §4.2 能力差异表里「手机端页面由谁托管」那一行的答案。§7 对比表说 v0.6.3「浏览器直开，移动端专门适配」——SaaS 下成立，自建下需要你额外托管一个 2712 行的单文件 PWA。

**建议改法**：§2 表该行补「自建模式下需由你的 nginx 托管（`/app/`）——手机端 UI 本体，2712 行单文件 PWA」；§8 的部署步骤从「bridge 与 relay 独立部署」扩为「**bridge + relay + `/app/` 静态页** 三件」。

### 6.6 【中等】本仓已有一个功能重叠的远程访问插件

**文档未提及。** 本仓 `plugins/dsh-web/packages/dsh-remote-web-ui/`：

```
plugins/dsh-web/packages/dsh-remote-web-ui/package.json
  "name": "@linxin666/dsh-remote-web-ui"   version 0.3.17   license Apache-2.0
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" },
           "client": { "platform": "web", "inject": [...] } }
  description: "Scan-to-pair remote access for the dsh web GUI … one-time tokens and revocable
                device sessions, with a LAN bind toggle, optional Cloudflare tunnel, and
                one-click family self-update"
entry id: remote-web-ui   （plugins/dsh-web/packages/dsh-remote-web-ui/cordis.patch.yml）
```

它是一个**扫码配对 + 一次性令牌 + 可撤销设备会话 + LAN 绑定开关 + 可选 Cloudflare 隧道**的远程访问插件，Apache-2.0，属 dsh-web 家族（已有聚合包与解析回退链路）。

**判定：不完整（这是本次评审对决策最有价值的一条）。** §3 的对比表只说「之前 10 个插件」是无额外组件、MIT、submodule + `make setup` 的形态，从未指出**其中之一正是同类功能的替代方案**，且它的成本结构完全不同：不需要第三方中继、不需要第三方账号、不需要 `npx` 安装器、不需要开机自启的 bridge。

**关于 entry id 冲突**：**没有硬冲突**——本仓现有 entry id 是 `better-sidebar` / `agent-teams` / `modlens` / `dsh-market` / `modsearch` / `dsh-at-file` / `dsh-mineru` / `dsh-automation`，加上 dsh-web 家族的 `remote-web-ui` / `doctor` / `ssh` / `ui-*` 等；dsh-remote 用 `dsh-remote-web` / `dsh-remote-ui`，与以上均不重名。所以风险是**功能重叠与 profile 内共存**，不是 id 碰撞。

**建议改法**：§3 或 §7 增加一行「同类替代」：

> **本仓已有同类插件**：`plugins/dsh-web/packages/dsh-remote-web-ui`（`@linxin666/dsh-remote-web-ui` v0.3.17，Apache-2.0，entry `remote-web-ui`）本身就是「扫码配对 + 一次性令牌 + 可撤销设备会话 + LAN 绑定 + 可选 Cloudflare 隧道」的远程访问方案。与 dsh-remote 相比：**无第三方中继、无第三方账号、无 `npx` 安装器、无开机自启常驻进程**，代价是只覆盖局域网/隧道场景而非「公网中继直达」。§7 的方案对比应把它列为方案 A 与 C 之间的一个选项。

### 6.7 【中等】§6.1 的审计边界数字对不上，且漏了两个大件

**文档原文**（§6.1、§7 备注）：

> 「**v0.6.3 约 9100 行**（`clients/dsh-remote` + `packages/relay-router` + 两个插件包的 `lib/`），我只做了定向扫描」

**源码证据**（行数实测）：

| 组件 | 行数 |
|---|---|
| `clients/dsh-remote/` | 5731 |
| `packages/relay-router/` | 2039 |
| 两个插件包的 `lib/` | 9128 |
| **文档列举的三项合计** | **16898** |

**「9100」恰好只等于两个插件包 `lib/` 的行数（9128）**，而不是文档列举的三项之和。

另外两个**完全没进边界声明**的组件：

| 组件 | 行数 | 为什么重要 |
|---|---|---|
| `dsh-setup.mjs` | 791 | `npx` 安装器本体：写配置、装 launchd/systemd 自启、把运行时固化到 `~/.dsh-remote`、处理账号/访问密钥切换 |
| `clients/dsh-web/native.html` | 2712 | 手机端 UI 本体（自建时需自行托管） |

**判定：不完整。** §6.1 是文档自己立的「边界声明」，用来自证「不要把未核实项当保证」。数字低估了近一半、且把两个安全相关的部署件排除在边界之外，会让这个边界声明的保护作用打折。

**建议改法**：§6.1 改为「v0.6.3 本仓 ES 模块合计 **≈16.9k 行**（`clients/dsh-remote` 5.7k + `packages/relay-router` 2.0k + 两个插件包 `lib/` 9.1k），另有 `dsh-setup.mjs` 791 行与 `clients/dsh-web/native.html` 2712 行**未纳入本次扫描**。我只做了定向扫描，没有做完整审计。」

### 6.8 【轻微】§6.2「设备身份 / 凭据落盘」等行的行号引用精确，值得保留

补充说明让文档可信度分布更清楚：§10 索引中 `dsh-bridge.mjs` 的 `:109`（`UPSTREAM` 默认）、`:125`（唯一那处 ioreg `execSync`）、`:151,167`（`0o600`）、`:360`（`out.Host = up.host`）、`:718`（`new WebSocket(...)`）**逐个核对全部命中**；`e2ee-client.mjs:723`（`writeE2eeStateFile` 的 `mode: 0o600`）也命中。唯一偏一行的是 §4 的 strip 注释（文档写 `:239`，实际注释在 `:238`，`STRIP_REQ_HEADERS` 常量在 `:244`）——属可接受误差。**这部分不需要改。**

### 6.9 【轻微】§9「本仓其余插件均为 MIT」不准确

**文档原文**（§9 末）：

> 「本仓其余插件均为 MIT；引入本插件会改变本仓的许可证构成，**若涉及工作机器请先确认**。」

**源码证据**（逐个读 `plugins/*/package.json` 的 `license`）：

```
dsh-agent-teams: MIT        dsh-at-file: MIT        dsh-automation: MIT
dsh-better-sidebar: MIT     dsh-market: MIT         modlens: MIT        modsearch: MIT
dsh-plugin-mineru: AGPL-3.0        ← 非 MIT
dsh-web: Apache-2.0                 ← 非 MIT
```

**判定：错误。** 结论方向（引入 PolyForm-Noncommercial 会改变许可证构成）依然成立，但「其余均为 MIT」这个前提不成立——本仓已有 AGPL-3.0 与 Apache-2.0。

**建议改法**：改为「本仓现有插件以 MIT 为主，另有 `dsh-plugin-mineru`（AGPL-3.0）与 `dsh-web`（Apache-2.0）；引入 PolyForm-Noncommercial 会进一步改变许可证构成」。

### 6.10 【轻微】§6.3 R1 可以更精确（E2EE 的信任模型自陈）

**文档原文**（R1）：

> 「中继是新的信任方…E2EE 保护的是**内容**，而**路由元数据（路径、大小、时间、是否加密）对中继可见**。」

这条与 README 一致，没错。但 dsh-remote 自己的 E2EE 设计注释承认了一个**更强**的窗口：

```
clients/dsh-remote/e2ee-client.mjs:603-610（introGrant 的文档注释）
   * 桌面授权引导(方案A,2026-09 用户决策):供同账号手机端在「从未持有密码」的场景(扫码/
   * 一次性链接登录)下免输密码建立 E2EE。桥端在内存中持有派生 MK,此处一次性下发 MK …
   * 信任模型见 docs/e2ee-protocol.md §5.4 [DECISION]:引导瞬间以「持有效扫码会话=账号本人」
   * 为准,**存在被中继主动冒充的理论窗口**(与扫码登录产品一致)
```

**判定：不完整。** 对走扫码/一次性链接入场的手机，MK 是由电脑端在中继判定「同账号」后**主动下发**的，作者自己标注了「存在被中继主动冒充的理论窗口」。这比「中继可见路由元数据」更进一步：**在最需要 E2EE 的入场路径上，E2EE 的信任根落回中继**。

**建议改法**：R1 补一句「另外，作者在 `clients/dsh-remote/e2ee-client.mjs` 的 `introGrant` 注释中自陈：扫码/一次性链接入场时 MK 由电脑端经中继下发，**存在被中继主动冒充的理论窗口**（`docs/e2ee-protocol.md` §5.4）。即 E2EE 的强度在「免密入场」路径上低于「密码登录」路径。」

### 6.11 【轻微】§5 结尾「token 交换的坑是否仍存在」其实可以从代码定论

**文档原文**（§5 注）：

> 「v1.0.0 那条「首次必须手动做 DSH token 交换」的坑**在 v0.6.3 上是否仍存在，我没有验证**——它的登录流程由插件面板与 bridge 接管，理论上已封装。**这一点建议实测确认。**」

**源码证据**：该机制已被显式替换：

```
packages/dsh-remote-web/lib/index.js:221
  *  - 写入 <relayDir>/.harness-cookie.json,bridge 上游转发时自动携带,让手机表现为已授权浏览器。
packages/dsh-remote-web/lib/index.js:237-266   mintHarnessCookie(ctx, relayDir)   （从 ctx.get('connection') 取会话并落盘 0600）
clients/dsh-remote/dsh-bridge.mjs:361-362
  const ck = harnessCookieOf(); // 新版 dsh web 的浏览器会话 Cookie
  if (ck) out.Cookie = ck;
```

**判定：文档的「未验证」偏保守——不需要实测也能确定「手动 token 交换」这个具体动作已经没有了**（改成插件代持 Cookie）。但**它换来了一个新的、等价的失效模式**：只装插件时 `bridge_secret` 缺失会让面板显示「尚未登录」（`lib/index.js:905-930` 的注释已记录）。**建议改法**：把该注改为「v1.0.0 的『手动 token 交换』已由插件的会话 Cookie 代持取代（`lib/index.js:237-266` + `dsh-bridge.mjs:361-362`），**该坑本身消失**；但引入了一个新的等价坑：只装插件时 `bridge_secret` 缺失会让面板静默显示「尚未登录」（代码注释 `lib/index.js:905-930`），源码安装需手工补该密钥。」

---

## 7. 我无法核实的部分

明确区分「已核实」与「未核实」，以下均**未核实**：

1. **harness 载入期抛错的实际后果**。我核实了重复路由会 `throw`（`harness/packages/host/webserver/src/index.ts:168`），但**没有运行**，所以「宿主插件 apply 期抛错时 dsh web 是整体启动失败、还是只标记该 fiber 失败并继续」我**没有验证**。dsh-remote 自己的 README 声称「a failing browser plugin blocks the whole web app from starting (framework constraint)」，我同样**未验证**这条断言。§2 里我按「至少是启动期硬报错」表述，未升格为「必然白屏」。
2. **`dsh-remote-ui` 别名的现实必要性**。`sync-legacy-alias.mjs:3-5,15-16` 说它服务于「插件市场里『旧条目』」，并且「新名条目合并通过后：删除 `packages/dsh-remote-ui`、停发 `dsh-remote-ui`」。当前市场侧状态（旧条目是否仍需保留）我**无法从本仓核实**（需联网/查市场目录）。
3. **`clients/dsh-remote/e2ee-client.mjs` 的协议实现本身**。我只核了它的 `init` 门控（`:566-571`）与 `introGrant` 注释（`:603-610`），**没有审计 E2EE 协议实现**（该文件本身很大，`docs/e2ee-protocol.md` 45KB 也未逐节读）。§6.10 引用的是作者自己的注释，不是我独立得出的结论。
4. **`clients/dsh-web/native.html` 的行为**。只核了它不是 npm 包、2712 行、以及 `docs/self-hosting.md` 对它的部署描述；**没有读它的实现**。
5. **中继侧数据面**。`packages/relay-router/src/index.mjs` 我只核了路由面与认证入口（`/_login` `:532`、`/_devices` `:564`、`/_quota` `:584`、`/remote/` `:412,475`、`/_bridge` `:933`、兜底 404 `:609`），**没有审计它的代理实现、配额逻辑与 E2EE 帧处理**。
6. **任何运行时行为**。本次评审**完全是静态阅读**：未安装、未运行、未联网、未做端到端实测。§4.1 那条推论（`--trusted-host` + 反代可通）我论证的是**代码路径成立**，不是**实测通过**——与文档自己的「此推论尚未端到端实测」标注一致，我同样**未实测**。
7. **`harness` 本仓 profile 的实际挂载结果**。我读到的 `~/.dsh/profiles/web/` 只有 `web` 一个 profile，其 `cordis.patch.yml` 为 `[]`、`bundles` 仅 `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`；而 `scripts/link-plugins.sh:22` 默认 `PROFILE=dsh`，该 profile 目录**不存在**。所以**当前实际的插件挂载状态**（本仓 9 个插件是否已挂、挂在哪个 profile）我**没有核实**，§6.6 关于 `dsh-remote-web-ui` 的讨论是**基于源码存在**，不是基于它已挂载。

---

## 8. 问题计数（按严重度）

| 严重度 | 条数 | 条目 |
|---|---|---|
| **严重** | **3** | 6.1 E2EE 与自建互斥（§6.4/§6.3 建议方向相反）；6.2「只有一处 execSync」错误（实为 6 处）；6.3 插件半被描述得过窄（实为系统管理 agent：自装/改 profile/重启宿主） |
| **中等** | **5** | 2. 重复挂载会硬失败 + `link-plugins.sh` 会自动两个都挂（文档未警示）；4.2 一次性扫码/设备管理是 SaaS 专属、自建无此物；5.2 §8 第 4 条做不到 + 漏 `DSH_RELAY_DIR` + 漏 `bridge_secret`；6.4 `dsh.client.inject` 指向不存在的包；6.5 `native.html` 是自建必需部署件；6.6 本仓已有同类插件 `dsh-remote-web-ui` |
| **轻微** | **5** | 1. `engines.dsh` 实为不校验的声明（放在「已核实」表里易误导）；3.3 §4.1 漏客户端 `isLoopback` 闸门 + R4 措辞过强；6.7 审计边界 9100 vs 实际 16898 且漏 791+2712 行；6.9「其余均为 MIT」不成立（AGPL-3.0 / Apache-2.0）；6.10 R1 可补 E2EE 引导窗口；6.11 §5 结尾可定论 |

（中等一栏列出 6 条，其中「§8 落地」与「重复挂载」高度耦合，按 5 条计。）

**判定汇总（文档怎么说 → 源码实际 → 判定）**

| # | 文档论断 | 判定 |
|---|---|---|
| 1 | 两个包是真 cordis 插件，`dsh.bundle.patch` + `client.platform` + `lib/` 已提交 | **正确**（`engines.dsh` 的「在范围内」需加「不被校验」注记） |
| 2 | entry id 为 `dsh-remote-web` / `dsh-remote-ui` | **正确**；「别名」定性不完整 —— 是逐字节副本，同挂即冲突 |
| 3a | `host: z.union([...])` @ webserver:126 | **正确** |
| 3b | CLI 拒绝 `--host 0.0.0.0` @ startup.ts:74-76 | **正确**（确切行 75） |
| 3c | 围栏三道门 @ api-request-trust.ts:91-118 | **正确** |
| 3d | 唯一调用点 rpc-host.ts:98，传 `this.trustedHosts`；无 `PRIVILEGED_METHODS` | **正确**（推论成立） |
| 3e | 由此推出「全部方法通过」「围栏对远程用户完全失效」 | **过强** —— 漏 `connection.isLoopback`（client/index.ts:227）这条独立闸门 |
| 4a | relayDir 默认 `~/.dsh-remote`、`/dsh-remote/*` 路由、面板槽 | **正确** |
| 4b | 一次性扫码链接是通用流程 | **不完整** —— SaaS 专属，自建无此能力 |
| 5a | 子包候选、跳过构建 | **正确** |
| 5b | 「源码安装需手工准备配置（或改 relayDir）」 | **不完整** —— 漏 `DSH_RELAY_DIR`、漏插件会自跑 `npx`、漏 `bridge_secret` |
| 5c | 「不执行 npx 自动安装」 | **做不到** —— `apply()` → `ensureRuntime()` 必然触发 |
| 6.2 | 全部代码只有一处 `execSync` | **错误** —— 6 处真实调用，跨 4 文件 |
| 9 | 本仓其余插件均为 MIT | **错误** —— 有 AGPL-3.0 与 Apache-2.0 |

---

## 9. 最小改动建议（按性价比排序）

若只改三处，改这三处：

1. **§6.4 加固清单第 1 条**：把「自建优先」改为「自建 vs E2EE 二选一」，附 `dsh-bridge.mjs:1016` / `e2ee-client.mjs:568` 两条证据。这是**唯一会改变用户决策方向**的错误。
2. **§8 第 4 条**：删掉「不执行 npx 自动安装」这个做不到的目标，改为「接受一次 `npx` 安装，随后用前台 `run` 跑 bridge」，并补 `DSH_RELAY_DIR` 与 `bridge_secret` 两个前置条件。
3. **§6.2 `execSync` 那一行**：从「只有一处」改为「≥5 处、系统管理用途」，并考虑整行移出「已核实」表。

次优先：§2 表给 `dsh-remote-ui` 加「同挂即冲突」警示；§3/§7 补 `dsh-remote-web-ui` 这条同类替代；§6.1 修正审计边界数字。
