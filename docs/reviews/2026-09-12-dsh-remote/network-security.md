# dsh-remote v0.6.3 网络与密码学安全复核

对 `docs/dsh-remote.md`（本地文档）的逐条核实与补漏。

- 评审对象：**v0.6.3**（文档 §1 表格中标注为「插件化 + 中继 + 桥」的当前线）
- 源码快照：`/tmp/dsh-remote-review/src-v063`（v0.6.3）、`/tmp/dsh-remote-review/src-v100`（v1.0.0，仅用于核对文档中声称属于 v1.0.0 的论断）
- 宿主侧：`/Users/michaelyao/workspace/dsh/harness`（0.1.5-rc.2，只读引用）
- 约束：**只读**。未修改 `/Users/michaelyao/workspace/dsh` 下任何文件；未安装、未执行被测项目的任何脚本；未联网。唯一的本地执行是我自己写的回环探针 `/tmp/redirect-probe.mjs`（只监听 127.0.0.1）。
- 判定用语：**已核实**（源码逐行确认）｜**部分成立**（结论方向对但表述/范围有误）｜**不成立**（与源码矛盾）｜**未核实**（代码不在可及范围，如闭源企业端）｜**推断**（有证据链但未端到端实测）

**结论摘要**：文档 §6 的七条「已核实项」中 5 条成立、1 条（危险原语）**不成立**、1 条（凭据落盘）需补注；风险清单 R1–R7 方向正确但 R1 低估；**加固清单第 1 条存在自相矛盾（自建中继时 E2EE 被硬禁用）**。文档**完全未覆盖**的最高危面是「插件路由无鉴权」——`/dsh-remote/*` 的 HTTP 端点既无身份校验也无 Origin/CSRF 校验，本机任意进程或一个网页即可铸出一次性登录链接、甚至改写账号绑定。

发现数：**高 4 条、中 8 条、低 5 条、信息 5 条**。

---

## ① §6 各条论断核实表

### 表 A — §6.2「已核实项」（文档 :166–176）

| # | 文档论断 | 证据（文件:行） | 判定 |
|---|---|---|---|
| A1 | 「全部代码中**只有一处** `execSync`：`clients/dsh-remote/dsh-bridge.mjs:125`（ioreg 读硬件 UUID），非恶意；无 `eval`/`new Function`」 | 后半句成立：全仓 `eval(`/`new Function` grep = 0 命中。前半句**不成立**：v0.6.3 的 `execSync(` 调用点共 **6 处 / 4 个文件** —— `dsh-setup.mjs:29`（import）、`:104`（通用 `sh()`）；`clients/dsh-remote/dsh-bridge.mjs:68`、`:125`；`packages/dsh-remote-web/lib/index.js:19`、`:37`（通用 `sh()`）、`:695`（`execSync("sleep 1")`）；`packages/dsh-remote-ui/lib/index.js` 同上（两个插件的 `lib/` 是同一构建的两份拷贝）。另有 `spawn` 执行 `npx --yes`（`dsh-setup.mjs:359`、`dsh-remote-web/lib/index.js:437,1608`）。`dsh-bridge.mjs:125` 本身的内容描述正确（`execSync("ioreg -rd1 -c IOPlatformExpertDevice")`）。**v1.0.0（`src-v100`，28 个文件）中 `execSync`/`child_process`/`eval(`/`new Function`/`require(` 全部 0 命中** —— 该论断按字面对**哪个版本都不成立**（v1.0.0 是 0 处而非 1 处） | **不成立** |
| A2 | 默认中继硬编码指向作者 SaaS | `clients/dsh-remote/dsh-bridge.mjs:111`（`https://n.risegao.cn:13443/relay-api`）；`dsh-setup.mjs:39,40`；`packages/dsh-remote-ui/lib/index.js:29,30`；`packages/dsh-remote-ui/lib/client.js:832,1897` | 已核实 |
| A3 | 配置 0600 落盘 + `.gitignore` 排除 | `dsh-bridge.mjs:151,167`、`e2ee-client.mjs:723`、`dsh-setup.mjs:141` 均为 `{ mode: 0o600 }`；`.gitignore:11,12` | **部分成立**：行号引用准确，但 `writeFileSync` 的 `mode` **只对新建文件生效**，`dsh-bridge.mjs`/`dsh-setup.mjs` 均无 `chmod` 兜底（全仓 `chmod` 只出现在插件 `lib/index.js:192-195`，作者自己在注释里写明「文件已存在时 writeFileSync 不改权限，显式 chmod 兜底」）。见 L1 |
| A4 | 设备身份 = ed25519 密钥对 + `dev-<12hex>`，持久化在 `.dsh-config.json` | `dsh-bridge.mjs:69`（import）、`:200`（`"dev-" + randomBytes(6).toString("hex")`）、`:207-218`（`generateKeyPairSync("ed25519")`，公钥/私钥写入 cfg） | 已核实（格式与落盘）。**补注**：该密钥对**从不用于认证**（见 M6），只是随设备登记上报的数据 |
| A5 | 两个插件包的 `lib/` 已提交（预构建可挂载） | `packages/dsh-remote-web/lib/index.js`、`lib/client.js`、`packages/dsh-remote-ui/lib/index.js`、`lib/client.js` 均在快照内 | 已核实（但无法核对「产物 ← 源码」一致性，文档 R7 已自陈） |
| A6 | 依赖面极小：仅 `ws`；插件包无额外运行时依赖 | `clients/dsh-remote/package.json:8`（`ws ^8.18.0`）、`packages/relay-router/package.json:18`（`ws ^8.21.3`）、两个插件包 `package.json` 无 `dependencies` 字段 | 已核实 |
| A7 | `engines.dsh: ">=0.1.0-rc.6 <0.2.0-0"`，本仓 0.1.5-rc.2 满足 | `packages/dsh-remote-web/package.json:44`、`packages/dsh-remote-ui/package.json:44` | 已核实 |

### 表 B — §6.3 风险清单（文档 :178–188）

| # | 文档论断 | 证据 | 判定 |
|---|---|---|---|
| R1 | 中继是新的信任方；E2EE 只保护**内容**，**路由元数据（路径/大小/时间/是否加密）可见** | `packages/relay-router/src/index.mjs:177-204`（`STRIP_FWD_HEADERS` 不剥 `content-type`，也不剥 `x-dsh-e2ee`）、`:190-193`（按标记识别加密）、`:637`（`noteE2ee`）；协议 `docs/e2ee-protocol.md:22,99` | 已核实，但**低估**：中继还能看到 `content-type` 与前缀路径（可推断「用户在发消息/传文件」），且 desktop-intro 路径下中继**能看到 MK 本身**（H1），此时 R1 的「内容不可见」前提不成立 |
| R2 | E2EE 默认关闭（灰度）＝明文回退，未开启时中继可读内容 | `docs/e2ee-protocol.md:289`、`README.md` §安全与隐私；bridge 侧门控 `dsh-bridge.mjs:229-233`、`:1014-1021` | 已核实（**并加强**：即使「开启」，仍存在静默明文回退路径，见 M1/M2） |
| R3 | 电脑端 `.dsh-config.json`（0600）保存账号密码用于自动登录，等同账号解密权 | `dsh-bridge.mjs:167`（写入 cfg，含 `password`）；`dsh-setup.mjs:141`、`:359`（以 `DSH_BRIDGE_PASSWORD` 环境变量传给子进程） | 已核实。**补注两点**：密码是**明文**（非派生值）；它还以环境变量形式存在于 bridge 进程里，同用户进程可读（`ps -E`） |
| R4 | 与 v1.0.0 同样的 loopback 伪装，DSH 围栏对远程用户失效 | `dsh-bridge.mjs:237-247`（`STRIP_REQ_HEADERS` 剥 `host/origin/referer/sec-fetch-*`）、`:360`（`out.Host = up.host`）、`:441-443`（fetch 自动 Host + 注入 harness cookie）；harness 侧 `harness/packages/client/connection/src/api-request-trust.ts:91-118`、`rpc-host.ts:97-100` | 已核实。**文档此处漏了一道门**：`/api` 除 `isTrustedApiRequest` 外还要过 `browserAuth.isAuthenticated`（`rpc-host.ts:99` → `browser-auth.ts:289-302`，校验 authority 绑定 + 签名的会话 cookie），bridge 靠 `dsh-bridge.mjs:442-443` 注入 `.harness-cookie.json` 里的 cookie 才通过 —— 见 M6 |
| R5 | bridge 以 launchd/systemd 常驻 + 开机自启 | `dsh-setup.mjs:189`（`~/Library/LaunchAgents/com.dshremote.bridge.plist`）、`:191`（`~/.config/systemd/user/dsh-bridge.service`）、`:205-208`（`RunAtLoad`/`KeepAlive`/日志 `.dsh-bridge.log`） | 已核实（用户级，无需 root） |
| R6 | 许可证 PolyForm Noncommercial + 官方 SaaS 收费 | `LICENSE`、`COMMERCIAL-LICENSE.md`；具体价格未核实（不在代码内） | 已核实（许可证）；价格 **未核实** |
| R7 | 审计深度不足；插件 `lib/` 预构建无法核对源码一致性 | 自陈 | 已核实（诚实） |

### 表 C — §6.4 加固清单（文档 :190–197）

| # | 文档建议 | 判定 | 说明 |
|---|---|---|---|
| 1 | 「能自建就自建（避免内容经第三方）」＋「用 SaaS 则务必确认 E2EE 已真正开启」 | **不成立（自相矛盾）** | 两条建议在当前版本上**互斥**：自建模式（设置 `DSH_BRIDGE_LOCAL_KEY`）时 bridge **硬编码禁用 E2EE** —— `dsh-bridge.mjs:1016`（`const localMode = Boolean(process.env.DSH_BRIDGE_LOCAL_KEY);`）、`:1018`（`const allowed = !localMode && !userDisabled;`）、`:1021`（传入 `E2eeService.init({..., allowed})`）；协议文档自己也把「自建中继 + 访问密钥 → E2EE」列为 vNext（`docs/e2ee-protocol.md:405`）。用户按第 1 条操作会得到「自建但永远无 E2EE」，却以为两者兼得 |
| 2 | 保护电脑端 `.dsh-config.json` | 成立但不足 | 同机的**任何**进程/页面都能经插件路由间接使用这份凭据（H3），保护文件不等于保护能力；另外文档没提第二份凭据 `.harness-cookie.json`（M6） |
| 3 | 一次性扫码链接是安全设计（30 分钟、一次性、可取消），用完即刷新 | **未核实**（企业端闭源）＋客户端行为与之矛盾 | 客户端面板在停留时**每 25 秒自动铸一把新的一次性密钥**：`packages/dsh-remote-web/lib/client.js:1251`（`KEY_AUTO_REFRESH_MS = 25000`，注释「约每 25s 自动轮换一把新的一次性密钥」）、`:1526`（`setInterval(loadAccessKey, KEY_AUTO_REFRESH_MS)`）；UI 文案写着「30 分钟有效、用一次即失效」（`client.js:1995`）。「用完即刷新」的动作不改变面板持续铸造的事实 → 见 M7 |
| 4 | 只在能看到 `dsh web` 的机器上装 bridge；不要暴露 3080 | 方向正确，但**不充分** | 「不暴露 3080」挡不住 DNS rebinding 与 CSRF（H3）——围栏只保护 `/api`，插件路由 `/dsh-remote/*` 无任何来源校验（`packages/dsh-remote-web/lib/index.js:2127-2151`、harness `packages/host/webserver/src/index.ts:221-237`） |
| 5 | 定期清理配对；改密使旧会话失效 | 未核实（企业端闭源） | 客户端确有 revoke/delete/purge 端点（`lib/index.js:1853-1881`），服务端是否真正拉黑 jti 无法确认 |
| 6 | 在意第三方中继则评估 §7 方案 A/B | 成立 | 方案 B 的「零第三方」依赖 §4.1 的推论，文档已自陈「尚未端到端实测」，标注恰当 |

### 表 D — §4 / §4.1 / §10 引用核对

| 文档引用 | 核实结果 | 判定 |
|---|---|---|
| `webserver/src/index.ts:126`（只接受两个字面量） | 一致 | 已核实 |
| `bundle/web-app/src/startup.ts:74-76`（拒绝 0.0.0.0） | 一致 | 已核实 |
| `api-request-trust.ts:91-118`（三道门，「无 Origin 放行」） | 一致 | 已核实 |
| `rpc-host.ts:98`（围栏唯一调用点，传 `this.trustedHosts`） | 一致，但**遗漏了紧邻的 :99 `browserAuth.isAuthenticated`（401）** | 部分成立 |
| §4.1「本仓全仓无 `PRIVILEGED_METHODS`」 | 全仓 grep = 0 命中 | 已核实 |
| `dsh-bridge.mjs:718,956`（bridge 只外连） | `:718` `new WebSocket(url, { headers, followRedirects: false })`、`:956` `new WebSocket(endpoint, { followRedirects: false })` | 已核实 |
| `dsh-bridge.mjs:239,245`（伪装 loopback / 剥头） | `:243-247` 才是 `STRIP_REQ_HEADERS` 集合（`:239`/`:245` 分别落在注释行与集合中段） | 部分成立（行号漂 1–4 行） |
| `dsh-bridge.mjs:360`（WS 写入 Host） | `:360` `out.Host = up.host;` 精确命中 | 已核实 |
| `dsh-bridge.mjs:109`（上游默认地址） | `:109` `const UPSTREAM = process.env.DSH_BRIDGE_UPSTREAM \|\| "http://127.0.0.1:3080";` | 已核实 |
| `dsh-bridge.mjs:125`（唯一 execSync） | 行号对，但「唯一」错（见 A1） | 不成立 |
| `dsh-bridge.mjs:151,167`、`e2ee-client.mjs:723`（0600） | 三处行号全部精确命中 | 已核实 |

---

## ② 文档遗漏的发现（按严重度）

### 高

#### H1. desktop-intro 把派生 MK 以明文经中继下发（「中继看不到内容」在该路径上不成立）

**证据**
- 端点在 bridge 本地应答，不连上游：`clients/dsh-remote/dsh-bridge.mjs:497-500`（`POST /_e2ee/intro` → `answerIntro`）。
- 回包正文直接带 MK：`dsh-bridge.mjs:563`（`body = { ok: true, v: 2, grant: "desktop-intro", mk: g.mk, profile: g.profile, epoch: g.epoch, ts: Date.now() }`），以普通 `http` 帧、`body: Buffer.from(JSON.stringify(body)).toString("base64")` 发出（`:571-578`），**没有** `application/vnd.dsh.e2ee-v2` 信封标记。
- MK 的出口：`e2ee-client.mjs:603-608`（`introGrant()` 返回 `mk: this.mk.toString("base64url")`）。
- 中继对该帧只是透明转发（`packages/relay-router/src/index.mjs:636-658` 组帧上行、`:189-193` 只对信封标记计数），因此**能**读到的正是这段明文 JSON。
- 协议文档自述矛盾：`docs/e2ee-protocol.md:334`（字段表明确列出 `mk:<派生MK base64url>`）对照 `:337`（「转发层可见『存在一次引导』，看不到内容语义之外的东西」）；`:340` 又承认「中继理论上存在『引导瞬间主动冒充电脑端』的主动攻击窗口」。

**影响**
- 谁能利用：SaaS 中继运营方、中继主机被攻破者、以及任何能看到该转发流量的中间人；使用「扫码 / 一次性链接」进入的用户**必然**走这条路（这正是产品主推路径）。
- 前提：bridge 端 `e2ee.enabled`（否则 intro 返回 409，本来也无 E2EE 可言）。
- 后果：一次引导即泄露 MK。由于 SHK 由 `HKDF(MK, salt=sha256(a‖b))` 派生且 a、b 在明文 hello/ack 中传输（`e2ee-client.mjs:199-215`、`:662`），**MK 泄露 = 该账号全部历史与会话内容可解**（无前向保密，见 H2），并且 MK 还会被写进手机 `localStorage`（协议 `:292,:298` 的 DECISION）。

**建议缓解**：短期在协议与 README 中如实写明「引导路径下中继在理论上/实际上可获知 MK」，并把 §6.4 的建议改为「要防中继必须用 §5.1 人工密码解锁，不能用扫码引导」；中期改为一次性 ECDH 封套（bridge 临时密钥对，公钥经中继，MK 由双方 nonce 经 HKDF 导出）或直接上 PAKE/OPAQUE（协议 §8.5 已列）。

#### H2. 无前向保密：一次 MK 泄露覆盖全部历史流量

**证据**：`e2ee-client.mjs:199-215`（`saltH = sha256(a‖b)`；`SHK = HKDF-SHA256(ikm=MK, salt=saltH, info="dsh-e2ee/v1\0shk")`）；`:662-663`（握手时以明文 a、b 调用）；`docs/e2ee-protocol.md:474`（MK 定义，PBKDF2 600k）。会话密钥不落盘、会话 TTL 24h（协议 §5.3），但**根密钥 MK 是长期、跨会话、跨设备唯一的**。

**影响**：中继/攻击者录下密文后，一旦在任意时刻（引导、手机 XSS、本机凭据读取）拿到 MK，即可**回溯解密此前全部**被录流量；反之，任何单次 MK 泄露的影响面不是「一个会话」而是「这个账号的一切」。文档 R1/R2 只讨论「中继是否能看到当前内容」，没有点出这个放大效应。

**建议缓解**：文档如实写明「E2EE 的信任根是 MK，且 MK 无轮换、无前向保密」；协议层引入每会话 ECDH（哪怕只做「临时密钥 + MK 签名」的混合模式），并把 MK 泄露的处置建议写成「改密 + 重置设备」而不是仅「退出登录」。

#### H3. `/dsh-remote/*` 插件路由无鉴权、无 Origin/CSRF 校验：本机任意进程或一个网页即可夺取完整远程控制

**证据**
- 路由注册与分发：`packages/dsh-remote-web/lib/index.js:1717-2123`（路由表）、`:2127-2151`（dispatcher 仅比对 `method` + `pathname`，**没有**任何身份、Origin、Referer、`Sec-Fetch-*` 校验）。
- harness 侧不兜底：`harness/packages/host/webserver/src/index.ts:221-237`（`handle()` 把插件路由直接分发出去，Host/Origin 围栏只作用于 `/api`）。
- 关键端点：
  - `GET /dsh-remote/access-key`（`lib/index.js:1844-1849` → `proxyCreateAccessKey` `:1280-1304`）：用本机保存的凭据向企业端铸**一次性登录链接**，响应里含 `url`、`key`、`qr_data_url`。**不需要攻击者提供任何凭据。**
  - `POST /dsh-remote/config`（`:1883-1924`）：写入 `phone`/`password`（SaaS）或 `local_key`+`tunnel_url`（自建），随后 `startBridge` 重启 bridge —— 把设备重新绑定到**攻击者控制的账号**，攻击者随即在自己手机上看到这台 PC 并完全控制它。
  - `POST /dsh-remote/self/update`（`:1750`）与 `POST /dsh-remote/self/uninstall`（`:1764`）、`mobile-sessions/revoke|delete|purge`（`:1861-1881`）。
- 攻击面不需要「读取响应」也能生效：`readJsonBody` 不校验 `Content-Type`（`:155-164`），因此一个 `enctype="text/plain"` 的表单跨站 POST 即可触发 `self/uninstall`、`self/update`、`mobile-sessions/revoke`；要**读取**（例如拿到登录链接）则需要 DNS rebinding（攻击者域名解析到 127.0.0.1，页面与 3080 同源）。`sendJson`（`:167-174`）未设任何 CORS 头，普通跨源读取被同源策略挡住，但 rebinding 场景不受此限。

**影响**
- 谁能利用：能向 `127.0.0.1:3080` 发请求的**任何**东西 —— 同机其他用户进程、沙箱化的本地应用、以及**用户自己浏览器里打开的任意网页**（rebinding / 简单表单）。
- 前提：bridge 在跑（否则无 3080 可打）；多数场景需诱导用户访问一个页面（rebinding）或本机已有可发 HTTP 的沙箱进程。若本机已有全权代码执行，危害升级有限（本来就能读 `.dsh-config.json`）；**但「网页 → 本机 loopback」这一跳是本发现的核心价值**。
- 后果：拿到一次性登录链接 = 拿到手机端的全部能力 = 任意命令执行（dsh web 的语义就是本机 RCE）；或改写账号绑定 = 直接把受害 PC 交给攻击者账号。**这是本次评审危害最高的一条**，文档 §6.4 第 4 条「不要暴露 3080」完全不足以覆盖。

**建议缓解**：所有 `/dsh-remote/*` 端点加 `Host`/`Origin`/`Sec-Fetch-Site` 校验（至少拒绝带 Origin 的跨站请求，与 `/api` 围栏同源）；铸凭据类端点改 POST + 一次性 CSRF token（DSH 插件可从首屏注入 token）；`GET /dsh-remote/access-key` 这类「读一下就出凭据」的设计应改为显式用户动作（面板按钮 + 二次确认）。文档侧应在 §6.4 增列此条，并提示「装 bridge 的机器上不要用浏览器随意冲浪」。

#### H4. 设备隧道可被顶替（注册无归属校验）：自建模式下等于没有多租户隔离

**证据**
- `packages/relay-router/src/index.mjs:703-741`：`const existing = devices.get(deviceId)` → `:725-732` **无条件** `existing.ws.close(4000, "replaced by new connection")` + `cleanupDevice(existing)`，随后 `:733-741` 才写入 `userId: String(claims.sub)`。**没有任何 `existing.userId === claims.sub` 检查**。
- 对照 HTTP 路径**有**归属校验：`:508-517`（`authorizeRemote` 中 `String(dev.userId) !== String(claims.sub)` → `forbidden`）。
- 自建模式把所有访问密钥映射到同一个身份：`:549-555`（`LOCAL_ACCESS_KEYS.includes(key)` → `signLocalJwt("local", "pro_max")`）。因此**任一**访问密钥持有者与其他人 `sub` 都是 `"local"`，互相之间既无隔离也无从区分。

**影响**
- 谁能利用 / 前提：同一自建 relay 上的另一个访问密钥持有者（家庭/小团队共享场景）**只需知道 deviceId**（它出现在手机 URL `/remote/dev-<12hex>/…`、设备列表与日志里）即可注册同名设备，把合法 bridge 踢下线并接管该设备的隧道：手机后续流量会打到攻击者的 bridge（可看到密文信封、可返回任意伪造内容、可发起假冒 intro——协议 §5.4 已承认该窗口），同时构成持续 DoS。SaaS 模式下同样成立，但前提更难（需要合法账号 + 受害者的 deviceId）。
- 严重度：**自建部署下为高**（§6.4 恰恰在推荐自建）；SaaS 多租户下为中。

**建议缓解**：注册时若 `existing` 存在且 `existing.userId !== claims.sub`，拒绝并回 `tunnel-register-err`（不要顶替）；自建模式为每个访问密钥分配独立 `sub`（`key → sub` 映射），而不是一律 `"local"`；把 deviceId 纳入用户可见的「设备管理」并支持改名/轮换。

### 中

#### M1. E2EE 静默降级路径（明文回退时不报警）

**证据**：`clients/dsh-remote/e2ee-shim-script.js:402`（`if (!ctx || !ctx.sess) return origFetch(input, init)`）、`:410-420`（`req.bodyUsed`、流式 body、`clone()` 失败、`arrayBuffer()` 失败 → 直接明文 `origFetch`，**均未调用 `seNotifyFail`**）、`:439`（`if (!seIsEnvelopeResponse(res)) return res; // router/桥端明文错误页原样透传`）、`:502`（`if (!env || … || env.k !== "w") { this._deliver(raw, false); return; } // 明文帧透传(不应出现)`）。
**影响**：用户在「已加密」的心理预期下实际走明文，且没有任何提示。触发条件不需要攻击者：上游错误页、协议不匹配、流式响应（协议 §4.5 明确 SSE 走明文）都会命中。与协议 §2.4「不静默」的承诺冲突。
**建议缓解**：所有「降级为明文」的分支统一走告警徽标 + 控制通道告知；服务端/文档把「哪些响应类型保证加密」写成明确清单。

#### M2. 宽屏（>820px）下不显示任何告警徽标

**证据**：`e2ee-shim-script.js:644-648`（`if (mode !== "ok" && window.innerWidth > 820) return;`，注释称与 mobile-adapter 的「桌面零打扰」契约一致）。
**影响**：在电脑/平板上经远端打开镜像页时，明文/降级/失败**完全不可见**——与 M1 叠加即「无声明文」。文档 §6.4 让用户「确认 E2EE 已真正开启（面板状态为准）」，而这个面板恰恰在最容易发生降级的宽屏下不显示状态。
**建议缓解**：降级/失败态在宽屏也保留一个最小指示（例如标题栏一个点），或至少在控制台/控制通道留下可查记录。

#### M3. E2EE 开启判定与 KDF 参数来自与隧道同一来源的 `/api/e2ee-params`，无签名：中继可单方面关闭 E2EE，也可把 PBKDF2 迭代降到 1

**证据**：`e2ee-client.mjs:110-119`（`normalizeKdf` 对非法/缺失输入回落到默认，但**接受任何 `iter >= 1`**）、`:160`（握手参数中的 `kdf` 直接 `normalizeKdf(e2.kdf)` 采用）；协议 `docs/e2ee-protocol.md:289`（shim 依 `/api/e2ee-params` 决定是否启用）。
**影响**：掌握 TLS 终点（中继/企业端后台被改）的一方可返回 `enabled:false` → 全部明文（叠加 M1 的无声回退）；或返回 `iter:1` 使 MK 派生近乎免费，配合「密码明文存电脑端/登录时经手服务端」的现实，离线爆破变得可行。
**建议缓解**：E2EE 参数改由 bridge 在信封内（或经带内控制通道）权威下发，或客户端校验 `iter` 下限并把 profile 与本地策略不一致视为错误；协议文档明确「参数来源必须与隧道分离」。

#### M4. 桥端 HTTP 转发默认跟随重定向 → 从「电脑所在网络位置」发起的 SSRF（无凭据外泄）

**证据**：`dsh-bridge.mjs:449`（`fetch(url, { ...init, signal })`，**未设** `redirect: "manual"`），对照 WS 路径显式 `followRedirects: false`（`:718`、`:956`）。我用回环探针 `/tmp/redirect-probe.mjs` 实测 undici 行为：跨 port 的 302 **被跟随**，但 `cookie` 与 `authorization` 被剥掉（探针输出 `{ "url": "/stolen", "cookie": null, "auth": null, "host": "127.0.0.1:55293" }`）。
**影响**：能触达该转发路径的人（手机端使用者，或经 H3 的本机攻击者）可让 bridge 向 PC 可达的任意地址发起 GET/POST —— 内网探测、以 PC 身份触发内网设备动作。`safePath`（`:387-…`）只约束路径形态，不约束目标（目标恒为 `UPSTREAM`，但重定向可以把它带去别处）。因 undici 剥凭据，未发现凭据泄露。
**建议缓解**：`fetch(..., { redirect: "manual" })` 并对 3xx 直接回给客户端；或把重定向目标限制在同一 origin。文档侧把「bridge 只外连」的说法细化为「HTTP 转发可能被上游重定向」。
**说明**：文档提到的 `followRedirects: false` 指的是 **ws 库** 的选项（`:718`、`:956`），与 HTTP 转发无关——两者容易被混为一谈，建议在文档里写明。

#### M5. 第二份凭据 `.harness-cookie.json` 文档完全未提；且 bridge/setup 写配置时无 chmod 兜底

**证据**：`dsh-bridge.mjs:175-181`（从 `<relayDir>/.harness-cookie.json` 读取）、`:361-362`、`:442-443`（作为 `Cookie` 注入上游）；写入方 `packages/dsh-remote-web/lib/index.js:221-224`、`:260`（`{ mode: 0o600 }`）；它绕过的正是 harness 的第二道门 `rpc-host.ts:99` → `browser-auth.ts:289-302`（authority 绑定 + 签名 + 有效期）。
**影响**：该文件等于「已授权浏览器」的通行证；拿到它就等于手机端的浏览器身份（有效期由 harness 的 `maxAgeMilliseconds` 决定）。文档把 `.dsh-config.json` 列为唯一「等同解密权」的文件，遗漏了这一份。
**建议缓解**：文档补列；bridge 读取前校验其权限（非 0600 则告警）。
**附**：`dsh-bridge.mjs:167` 与 `dsh-setup.mjs:141` 写 `.dsh-config.json` 时**没有** chmod 兜底（只有插件 `lib/index.js:192-195` 做了），所以「0600」仅对新建文件成立 → 见 L1。

#### M6. ed25519 设备密钥不参与认证：它是「身份装饰」而非凭证

**证据**：`dsh-bridge.mjs:207-218`（生成并持久化），`:915`（`resolveDevicePubKey()` 的结果只用于设备登记上报），全仓无任何用私钥签名/验签的调用点；隧道注册用的是 JWT（`:966` 的 `tunnel-register` 携带 `token`），验证在 `relay-router/src/index.mjs:705`。
**影响**：文档 §6.2 把「ed25519 密钥对 + deviceId」列为设备身份，容易让人以为设备侧有密码学绑定（从而抵抗 H4 的顶替）。实际上是纯账号/JWT 绑定，deviceId 只是一个可被冒名的名字。
**建议缓解**：文档如实描述；若要真做设备身份，让 bridge 用私钥对隧道注册做挑战-应答签名，中继侧校验公钥与账号的绑定关系。

#### M7. 一次性登录链接的「一次性」在客户端被持续轮换削弱

**证据**：`packages/dsh-remote-web/lib/client.js:1251`（`KEY_AUTO_REFRESH_MS = 25000`）、`:1526`（定时器每 25s 调 `loadAccessKey` → `GET /dsh-remote/access-key`）、`:1995`（UI 文案「扫码即进入，30 分钟有效、用一次即失效。」）。
**影响**：用户坐在面板前时，每 25 秒就有一把新的有效链接被铸造；文档 §6.4 第 3 条「用完即刷新」并不能减少暴露面（旧的 30 分钟窗口仍开着）。同时这些链接经 H3 的未授权端点可被本机任意请求者取走。
**建议缓解**：文档改为「面板打开期间会持续铸新链接，离开时关闭面板」；客户端改为按需铸造（用户点击「生成」才铸一把）。

#### M8. 无人值守执行 `npx --yes @mrrisega/dsh-remote@latest`（插件自动跑），无完整性校验

**证据**：`packages/dsh-remote-web/lib/index.js:424-448`（`ensureRuntime()`：运行环境缺失时**自动** `spawn(npxCommand(), ["--yes", UPDATE_SPEC], { detached: true, env: { npm_config_registry: "https://registry.npmjs.org" } })`）、`:1588-1589`（`UPDATE_SPEC = @mrrisega/dsh-remote@${UPDATE_TAG}`，默认 `latest`，可被 `DSH_UPDATE_TAG` 改）、`:1605-1610`（self/update 同样的 spawn）。`dsh-setup.mjs:675` 也提示用 npx 重装。
**影响**：供应链信任完全落在 npm 账号与 dist-tag 上：包被劫持或 latest 被推恶意版本时，**下一次插件装载**（无需用户点击）就以用户身份执行任意代码并落自启。文档 §8 只说「不执行 npx 一键安装」，没提插件自身会后台自动跑 npx，会误导按 §8 谨慎安装的读者。
**建议缓解**：文档写明这一行为；安装时用固定版本 tag（`DSH_UPDATE_TAG=<version>`）、或在受控环境禁用更新端点；上游建议加 `--ignore-scripts` 与 npm provenance 校验。

### 低

- **L1** `writeFileSync(..., { mode: 0o600 })` 对已存在文件不改变权限，`dsh-bridge.mjs:167` 与 `dsh-setup.mjs:141` 都没有 chmod 兜底（插件在 `lib/index.js:192-195` 有）。若 `.dsh-config.json` 曾被以宽松权限创建/恢复，文档声称的 0600 不成立。缓解：写入后统一 `chmodSync(path, 0o600)`。
- **L2** `/_login` 用 `LOCAL_ACCESS_KEYS.includes(key)` 做非常量时间比较，且**无速率限制**（`relay-router/src/index.mjs:548-555`）；访问密钥足够长时在线爆破不现实，但共享密钥场景下建议加恒定时间比较 + 限速。
- **L3** 配额/用量为进程内存态，重启清零（`quotas.mjs:88-92,99-107`；`README`/`SECURITY.md` 亦自陈）；自建模式下所有访问密钥共享一个 `sub`，因此共享额度、共享 8Mbps 速率（`:508-517`、`:555`）。属于可用性/计费一致性问题。
- **L4** `relay-router` 的 deviceId 正则是宽松的 `^(dev-[0-9a-f]{12}|[a-z0-9][a-z0-9-]{1,63})$`（`index.mjs:167-168`），与 bridge 的 `dev-<12hex>` 不一致；宽松形态便于伪造好记的 id（与 H4 叠加，降低顶替门槛）。
- **L5** 仓库根 `package-lock.json` 陈旧且解析到镜像站：`package-lock.json:3,9` 仍是 `0.6.1-beta.1`（`package.json:3` 已是 `0.6.3`），`:51` `resolved` 指向 `https://registry.npmmirror.com/ws/-/ws-8.21.3.tgz`。文档 §6.2 的「依赖面」「可复现」印象需打折：锁文件与版本不同步，`npm ci` 会取镜像站内容。

### 信息

- **I1** 全仓 `eval` / `new Function` 0 命中（文档该半句成立）。
- **I2** 中继对 E2EE 帧确为透明转发（不解密、不重压），`relay-router/src/index.mjs:189-193`、`:636-637`；与协议一致。
- **I3** JWT 校验质量不错：仅 HS256、`alg` 校验、`timingSafeEqual`、`exp` 必填（`relay-router/src/jwt.mjs:15-38`），无 `alg:none` 或 HS/RS 混用路径（该问题在本次评审中**未发现**）。
- **I4** 上游响应头被剥 `content-encoding/content-length`（`dsh-bridge.mjs:255-260` 的 `STRIP_RES_HEADERS`），避免了 undici 已解压却又声明 gzip 的错配；文档未提，属于做对的地方。
- **I5** 官方 SaaS 域名页面（`clients/dsh-web/native.html:293-303`）在 `location.hostname === "n.risegao.cn"` 时注入百度统计脚本 `https://hm.baidu.com/hm.js?...`；而手机端的 MK 存在同源 `localStorage`（协议 `:292`）→ 同源第三方脚本理论上可读。是否实际加载需在真实域名验证（**未核实**），但文档未提这一同源关系。

---

## ③ 我无法核实的部分

1. **闭源企业端（`n.risegao.cn:13443` / `/relay-api`）**：`dsh_token` cookie 的属性（HttpOnly/Secure/SameSite）、JWT 签发参数与有效期、一次性链接是否真的「30 分钟 / 用一次即失效 / 可取消」、服务端限速与 jti 拉黑是否真正落地、`bridge_secret` 的校验方式（是否可绕过验证码/注册限制）、反馈接口是否上报未脱敏手机号、`/api/e2ee-params` 的权威性与是否可被运营方单方面改。以上均**未核实**（代码不在快照内）。
2. **SaaS 的实际 E2EE 开启状态**与灰度策略：需要真实账号与真机验证，**未核实**。
3. **官方 dsh web 前端在断线/错误页/SSE 场景下的重连与降级行为**：`clients/dsh-web/native.html` 只是静态壳，我没有运行它，也没有对应版本的前端源码可比对，**未核实**。
4. **端到端可利用性**：DNS rebinding 能否实际打到 `/dsh-remote/*`（依赖浏览器 PNA/Sec-Fetch 策略与 3080 的响应头）、CSRF 表单能否在目标浏览器上完成（我在报告中按「推断」标注）；`undici` 的重定向行为我只在本地独立探针（当前 Node）上验证，与 bridge 目标运行环境可能有版本差异，**推断**。
5. **`iter` 下限**：我确认客户端接受 `iter >= 1`（`e2ee-client.mjs:110-119`），但服务端实际下发什么值、是否会下发异常低值，**未核实**。
6. **harness `browserAuth` 的 cookie 生成/续期策略细节**（我看的是校验侧 `browser-auth.ts:289-302` 与调用点，未追签发侧），因此 M5 的「有效期」表述为「由 harness 的 maxAge 决定」，未给具体数值。

---

## ④ 对文档的修改建议

1. **§6.2 危险原语行重写**（这是唯一一条事实性错误）。改为：「v0.6.3 的 `execSync` 出现在 4 个文件、6 个调用点（`dsh-setup.mjs:29,104`；`dsh-bridge.mjs:68,125`；两个插件包 `lib/index.js:19,37,695`，其中 `:695` 是 `sleep 1`）；另有 `spawn` 执行 `npx --yes @mrrisega/dsh-remote@latest`（`lib/index.js:437,1608`）。`dsh-bridge.mjs:125` 的 `ioreg` 读取本身非恶意。无 `eval`/`new Function`。**注意 v1.0.0 线是 0 处 `execSync`，原句『全部代码中只有一处』对两个版本都不成立。**」
2. **§6.4 第 1 条必须拆开写**：自建 relay（`DSH_BRIDGE_LOCAL_KEY`）下 E2EE **被硬禁用**（`dsh-bridge.mjs:1016-1021`），所以「自建 + 开 E2EE」当前不可兼得。建议改写为：「二选一 —— (a) 自建 relay：内容以明文经你自己的中继，无 E2EE；(b) 用 SaaS + E2EE：内容在转发层加密，但引导路径会把 MK 交给中继（见 R1 补注 / 新 R8）。两者都要，需等 vNext（协议 §8.5）。」
3. **§6.3 增加 R8（未授权本地 HTTP 面）**：`/dsh-remote/*` 插件路由无鉴权、无 Origin/CSRF 校验，`GET /dsh-remote/access-key` 可铸登录链接、`POST /dsh-remote/config` 可改绑账号（`lib/index.js:1844-1849,1883-1924,2127-2151`；harness 围栏只覆盖 `/api`）。建议把 §6.4 第 4 条升级为：「装 bridge 的机器等同于把 dsh web 的 RCE 面挂到 loopback 上；在修补前，不要把该机器当作可随意上网的桌面使用」。
4. **R1 补一句「例外」**：在 desktop-intro（扫码/无密码路径）下，MK 以明文经中继下发（`dsh-bridge.mjs:563`、`e2ee-client.mjs:603-608`），因此该路径下「中继看不到内容」不成立；文档应与协议 §5.4 的 `[DECISION]` 保持一致口径。
5. **新增一条「无前向保密」说明**：SHK 由长期 MK 派生（`e2ee-client.mjs:199-215`），MK 泄露 = 历史全解；并说明手机端 MK 写 `localStorage`（协议 `:292,:298`）与 M1/M2 的静默降级叠加效果。
6. **§6.2 凭据落盘行加注**：`mode: 0o600` 仅对新建文件生效，bridge/setup 无 chmod 兜底；并补列第二份凭据 `.harness-cookie.json`（`dsh-bridge.mjs:178-181,442-443`）。
7. **§6.4 第 3 条改为**：「面板打开期间每 25 秒自动铸一把新链接（`client.js:1251,1526`），『用完即刷新』并不收敛暴露面；请离开面板时关闭它，并在服务端能确认『单次有效』之前把它当作长期有效凭据对待。」
8. **§8 加一条**：插件的 `ensureRuntime` 会在运行环境缺失时**自动**执行 `npx --yes …@latest`（`lib/index.js:424-448`），因此「不执行 npx 一键安装」不足以避免自动下载执行；建议固定 `DSH_UPDATE_TAG` 或在隔离环境安装。
9. **§10 索引修正**：`:125` 的「唯一」改为「该文件内」；`:239/:245` 改为 `:243-247`；补 `rpc-host.ts:99`（`browserAuth` 那一道门）。
10. **术语澄清**：`followRedirects: false` 是 **ws 库**的选项（`:718,:956`），HTTP 转发（`doHttp:449`）**跟随重定向**——建议在 §6/§4 明确区分，避免读者以为整条链路都不跟随。
11. **文档中被证伪/过悲观的点**（按要求也列出）：本次未发现文档**过于悲观**的实质论断；R7「审计深度不足」是恰当的自陈。§4.1 的推论（本版本无 `PRIVILEGED_METHODS`）经核实成立，但需补上 `browserAuth`（401）那道门，否则方案 B 的评估前提不完整。
