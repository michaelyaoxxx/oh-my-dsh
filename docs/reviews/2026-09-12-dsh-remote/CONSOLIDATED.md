# dsh-remote 评审汇总（三份报告去重后）

> 来源：`reports/agent-architecture.md`（下称 **架构**）、`reports/typescript-engineering.md`（下称 **TS**）、`reports/network-security.md`（下称 **网络**）。
> 被评对象：dsh-remote **v0.6.3**（commit `baa6d53`）；`v1.0.0`（commit `e5401f5`）仅在报告明确提及时出现。
> 严重度映射：架构的「严重/中等/轻微」→ 高/中/低；TS 的「高/中/低」与网络的「高/中/低/信息」原样采用。**合并条目取三份中的最高评级**，并在详情里注明各自评级。
> 去重原则：同一底层问题合并为一条，标注三份中哪几份提到；两份报告结论相反时标 ⚠️ 并并列两方证据，不做仲裁。所有 `file:line` 与引文均按报告原文照抄。
> 计数：**高 12 条 / 中 21 条 / 低 9 条**（另有 5 处正面核实见文末）。

---

## 按严重度排序

| # | 严重度 | 标题（一句话） | 涉及版本 | 证据（file:line） | 三份报告的哪几份提到 |
|---|--------|----------------|----------|-------------------|----------------------|
| 1 | 高 | `/dsh-remote/*` 插件路由无鉴权、无 Origin/CSRF 校验，本机任意进程或一个网页即可夺取完整远程控制 | v0.6.3 | `packages/dsh-remote-web/lib/index.js:1717-2123`、`:2127-2151`、`:1844-1849`、`:1883-1924`；`harness/packages/host/webserver/src/index.ts:221-237` | 网络 |
| 2 | 高 | 自建 relay 与 E2EE 互斥：§6.4 加固第 1 条自相矛盾，方向恰好相反 | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:1016`、`:1018`、`:1021`；`clients/dsh-remote/e2ee-client.mjs:568` | 架构 + 网络 |
| 3 | 高 | 「全部代码中只有一处 `execSync`」错误：4 个文件 6 处（v1.0.0 是 0 处） | v0.6.3 | `dsh-setup.mjs:104`；`clients/dsh-remote/dsh-bridge.mjs:125`；`packages/dsh-remote-web/lib/index.js:37`、`:695`（+ui 副本） | 架构 + TS + 网络 |
| 4 | 高 | 两个插件包会被本仓 `link-plugins.sh` 同时挂载 → 启动期重复路由硬报错 | v0.6.3 | `scripts/link-plugins.sh:89-105`、`:163-170`、`:172`（架构另引 `:62`、`:89`、`:142`）；`harness/packages/host/webserver/src/index.ts:165-170` | 架构 + TS |
| 5 | 高 | desktop-intro 引导路径把派生 MK 以明文经中继下发，「中继看不到内容」在该路径上不成立 | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:497-500`、`:563`、`:571-578`；`e2ee-client.mjs:603-608` | 网络 + 架构 |
| 6 | 高 | 无前向保密：一次 MK 泄露覆盖该账号全部历史流量 | v0.6.3 | `clients/dsh-remote/e2ee-client.mjs:199-215`、`:662-663`；`docs/e2ee-protocol.md:474` | 网络 |
| 7 | 高 | 设备隧道注册无归属校验，可被顶替（自建模式下等于没有多租户隔离） | v0.6.3 | `packages/relay-router/src/index.mjs:703-741`、`:725-732`、`:508-517`、`:549-555` | 网络 |
| 8 | 高 | 文档全文遗漏 `dsh-setup.mjs`（791 行）——而它是最有特权的组件 | v0.6.3 | `docs/dsh-remote.md`（`grep -c "dsh-setup"` = 0）；`dsh-setup.mjs:189`、`:199-211`、`:241-248`、`:262-264`、`:140-141`、`:43-86` | TS + 架构 |
| 9 | 高 ⚠️ | `lib/` 不是「预构建产物」而是手写源码，R7 的核心结论说反了 | v0.6.3 | `packages/dsh-remote-web/lib/client.js:1`、`:3`；根 `package.json` 的 `check` 脚本 | TS（网络判「已核实」；⚠️ 见详情） |
| 10 | 高 | 「约 9100 行」口径把预构建 bundle 与手写源码混在一起，且低估近一半 | v0.6.3 | `docs/dsh-remote.md:163`（另见 `:14`、`:31`） | TS + 架构 |
| 11 | 高 ⚠️ | `engines.dsh` 的「在范围内/满足」只在一条消费路径上成立 | v0.6.3 | `packages/dsh-remote-web/package.json`（顶层 `engines.dsh`）；`plugins/dsh-web/packages/dsh-plugin-manager/src/core/version.ts:90`、`:99-108`；`plugins/dsh-market/src/discovery-compatibility.ts:129` | TS + 架构（网络判「已核实」；⚠️ 见详情） |
| 12 | 高 | 插件半被描述得过窄：它实际是一个系统管理 agent（自装 / 改 profile / 重启宿主 / rm -rf） | v0.6.3 | `packages/dsh-remote-web/lib/index.js:1674-1712`、`:849-893`、`:1940`、`:428-455`、`:1620-1680`、`:640-712` | 架构 |
| 13 | 中 | 插件挂载后必然自动跑 `npx --yes @mrrisega/dsh-remote@latest`，「不执行 npx 安装」这条做不到 | v0.6.3 | `packages/dsh-remote-web/lib/index.js:428-455`、`:2188`、`:572-600`、`:1592`、`:1588-1589` | 架构 + 网络 |
| 14 | 中 | 「一次性扫码链接 / 已授权设备管理」是 SaaS 专属能力，自建 relay 上不存在 | v0.6.3 | `packages/dsh-remote-web/lib/index.js:1277-1310`、`:1313+`；`packages/relay-router/src/index.mjs:532`、`:564`、`:584`、`:609-612` | 架构 |
| 15 | 中 | 面板停留时每 25 秒自动铸一把新的一次性链接，「用完即刷新」不收敛暴露面 | v0.6.3 | `packages/dsh-remote-web/lib/client.js:1251`、`:1526`、`:1995` | 网络 |
| 16 | 中 | 只装插件时 `bridge_secret` 缺失 → 面板静默显示「尚未登录」；§5 的「未验证」其实可从代码定论 | v0.6.3 | `packages/dsh-remote-web/lib/index.js:905-930`、`:237-266`；`clients/dsh-remote/dsh-bridge.mjs:361-362` | 架构 |
| 17 | 中 | 源码形态下配置目录被解析为 checkout 自己，凭据落进被 pin 的 submodule；文档未提 `DSH_RELAY_DIR` | v0.6.3 | `dsh-setup.mjs:34-36`、`:69`；`packages/dsh-remote-web/lib/index.js:27`、`:2163` | 架构 |
| 18 | 中 | 插件会在运行中改写 profile 并重启 DSH 宿主进程 | v0.6.3 | `packages/dsh-remote-web/lib/index.js:1674-1712`、`:849-893`、`:1940-1944` | 架构 |
| 19 | 中 | `dsh.client.inject` 指向一个在 harness 中不存在的包 | v0.6.3 | `packages/dsh-remote-{web,ui}/package.json`；`harness/packages/client/modules/src/client/system.ts:165-168` | 架构 |
| 20 | 中 | 别名包同步脚本有明确盲区：新增文件不同步也不报错；发布工作流不跑 `--check` | v0.6.3 | `scripts/sync-legacy-alias.mjs:28-41`、`:49-60`、`:78-81`、`:85`；`.github/workflows/release-tarballs.yml:66-70` | TS |
| 21 | 中 | `@dsh-remote/client` 的 `main` 指向不存在的文件 | v0.6.3 | `clients/dsh-remote/package.json`（`"main": "src/index.js"`） | TS |
| 22 | 中 | 两个插件包目录内无 LICENSE，发布 tarball 也不含许可正文 | v0.6.3 | 两个包 `package.json` 的 `files` 白名单；`.github/workflows/release-tarballs.yml:66-70` | TS |
| 23 | 中 | 分块信封重组缓冲无上界 + relay 单帧上限 256 MB（认证前可达的资源耗尽面） | v0.6.3 | `packages/relay-router/src/index.mjs:172`、`:231-259`、`:244-254`、`:699`；`clients/dsh-remote/dsh-bridge.mjs:304-326`、`:980` | TS |
| 24 | 中 | 质量闸门薄弱：无类型 / 无 lint / 无构建；CI 的 audit 因 `\|\| true` 永不失败 | v0.6.3 | 根 `package.json` `scripts.check`；`.github/workflows/ci.yml` | TS |
| 25 | 中 | E2EE 静默降级路径（明文回退不报警） | v0.6.3 | `clients/dsh-remote/e2ee-shim-script.js:402`、`:410-420`、`:439`、`:502` | 网络 |
| 26 | 中 | 宽屏（>820px）下不显示任何告警徽标，降级状态不可见 | v0.6.3 | `clients/dsh-remote/e2ee-shim-script.js:644-648` | 网络 |
| 27 | 中 | E2EE 开启判定与 KDF 参数来自与隧道同一来源的 `/api/e2ee-params`，无签名 | v0.6.3 | `clients/dsh-remote/e2ee-client.mjs:110-119`、`:160`；`docs/e2ee-protocol.md:289` | 网络 |
| 28 | 中 | 桥端 HTTP 转发默认跟随重定向 → 从电脑所在网络位置发起的 SSRF（无凭据外泄） | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:449`、`:387`；对照 `:718`、`:956` | 网络 |
| 29 | 中 | 第二份凭据 `.harness-cookie.json` 文档完全未提 | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:175-181`、`:361-362`、`:442-443`；`packages/dsh-remote-web/lib/index.js:221-224`、`:260` | 网络 |
| 30 | 中 | ed25519 设备密钥不参与认证：它是「身份装饰」而非凭证 | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:207-218`、`:915`、`:966`；`packages/relay-router/src/index.mjs:705` | 网络 |
| 31 | 中 | `clients/dsh-web/native.html` 是自建模式下必须自行托管的第三个部署件 | v0.6.3 | `clients/dsh-web/native.html`（2712 行）；`docs/self-hosting.md` | 架构 |
| 32 | 中 | 本仓已有一个功能重叠的远程访问插件 `@linxin666/dsh-remote-web-ui` | v0.6.3 | `plugins/dsh-web/packages/dsh-remote-web-ui/package.json`、`cordis.patch.yml` | 架构 |
| 33 | 中 | CI 的插件清单是硬编码的，收 submodule 后必须同步修改，否则 pin 不被校验 | v0.6.3 | `.github/workflows/verify.yaml:39`、`:27`；`.github/workflows/release.yaml:44` | TS |
| 34 | 低 | §4.1 的「全部方法通过 / 围栏对远程用户失效」过强：漏了 `browserAuth` 401 与 `connection.isLoopback` 两道独立闸门 | v0.6.3 / harness 0.1.5-rc.2 | `harness/packages/client/connection/src/rpc-host.ts:99`、`browser-auth.ts:289-302`；`harness/packages/client/connection/src/client/index.ts:227`、`loopback-hostname.ts:12-18` | 架构 + 网络 |
| 35 | 低 | `writeFileSync(..., { mode: 0o600 })` 只对新建文件生效，bridge/setup 无 chmod 兜底 | v0.6.3 | `clients/dsh-remote/dsh-bridge.mjs:167`；`dsh-setup.mjs:141`；对照 `packages/dsh-remote-web/lib/index.js:192-195` | 网络 |
| 36 | 低 | §9「本仓其余插件均为 MIT」不成立（已有 AGPL-3.0 与 Apache-2.0） | v0.6.3 | `plugins/dsh-plugin-mineru/package.json`、`plugins/dsh-web/package.json` | 架构 |
| 37 | 低 | `package-lock.json` 陈旧且把 `ws` 钉在第三方镜像 | v0.6.3 | `package-lock.json:3,9`、`:51`（ns 侧 `package-lock.json:3,9`、`:51`） | TS + 网络 |
| 38 | 低 | `engines.node` 三处不一致；自建 relay 的前置是 Node ≥22.13，文档未提 | v0.6.3 | 根 `package.json`、`packages/relay-router/package.json`、两个插件包 `package.json` | TS |
| 39 | 低 | `/_login` 用非常量时间比较，且无速率限制 | v0.6.3 | `packages/relay-router/src/index.mjs:548-555` | 网络 |
| 40 | 低 | 配额/用量为进程内存态，重启清零；自建下所有访问密钥共享一个 `sub` 与额度 | v0.6.3 | `packages/relay-router/src/quotas.mjs:88-92`、`:99-107`；`index.mjs:508-517`、`:555` | 网络 |
| 41 | 低 | relay 的 deviceId 正则比 bridge 宽松，便于伪造好记 id（与第 7 条叠加） | v0.6.3 | `packages/relay-router/src/index.mjs:167-168` | 网络 |
| 42 | 低 | 官方 SaaS 域名页面注入第三方统计脚本，而同源 `localStorage` 里存着 MK | v0.6.3 | `clients/dsh-web/native.html:293-303`；`docs/e2ee-protocol.md:292` | 网络 |

---

## 逐条详情

### 1. `/dsh-remote/*` 插件路由无鉴权、无 Origin/CSRF 校验
- **严重度**：高（网络评「高」，为本次评审危害最高的一条；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js:2127-2151`、`harness/packages/host/webserver/src/index.ts:221-237`
  > 路由注册与分发：`packages/dsh-remote-web/lib/index.js:1717-2123`（路由表）、`:2127-2151`（dispatcher 仅比对 `method` + `pathname`，**没有**任何身份、Origin、Referer、`Sec-Fetch-*` 校验）。
  > `GET /dsh-remote/access-key`（`lib/index.js:1844-1849` → `proxyCreateAccessKey` `:1280-1304`）：用本机保存的凭据向企业端铸**一次性登录链接**，响应里含 `url`、`key`、`qr_data_url`。**不需要攻击者提供任何凭据。**
  > `POST /dsh-remote/config`（`:1883-1924`）：写入 `phone`/`password`（SaaS）或 `local_key`+`tunnel_url`（自建），随后 `startBridge` 重启 bridge。
  > `readJsonBody` 不校验 `Content-Type`（`:155-164`），因此一个 `enctype="text/plain"` 的表单跨站 POST 即可触发 `self/uninstall`、`self/update`、`mobile-sessions/revoke`。
- **影响**：拿到一次性登录链接 = 拿到手机端的全部能力 = 任意命令执行（dsh web 的语义就是本机 RCE）；或改写账号绑定 = 直接把受害 PC 交给攻击者账号。文档 §6.4 第 4 条「不要暴露 3080」完全不足以覆盖。
- **评审员是否声称亲自验证过**：部分——代码路径为「已核实」（静态逐行）；端到端可利用性自陈为「推断」
  > 端到端可利用性：DNS rebinding 能否实际打到 `/dsh-remote/*`（依赖浏览器 PNA/Sec-Fetch 策略与 3080 的响应头）、CSRF 表单能否在目标浏览器上完成（我在报告中按「推断」标注）
- **复现或验证方式**：报告未给出可执行 PoC（未构造、未实测）；给出的静态核验坐标即上列 `file:line`。

### 2. 自建 relay 与 E2EE 互斥（文档 §6.4 第 1 条自相矛盾）⚠️ 两份报告同一结论，措辞不同
- **严重度**：高（架构评「严重」——并称「这是本次评审最重要的发现」；网络评「不成立（自相矛盾）」并入高）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:1016`、`:1018`、`:1021`；`clients/dsh-remote/e2ee-client.mjs:568`
  > `dsh-bridge.mjs:1014-1018`：`const localMode = Boolean(process.env.DSH_BRIDGE_LOCAL_KEY); // 自建模式不启用(§6.6)` / `const allowed = !localMode && !userDisabled;`（架构引）
  > `e2ee-client.mjs:566-571`：`if (!allowed) return new E2eeService({ enabled: false, reason: "disabled_by_config" });`（架构引）
  > 「两条建议在当前版本上**互斥**：自建模式（设置 `DSH_BRIDGE_LOCAL_KEY`）时 bridge **硬编码禁用 E2EE**」（网络）
  > 「用户按第 1 条操作会得到「自建但永远无 E2EE」，却以为两者兼得」（网络；协议文档把「自建中继 + 访问密钥 → E2EE」列为 vNext，`docs/e2ee-protocol.md:405`）
- **影响**：文档把「中继归谁」与「内容是否加密」的**互斥关系**读成**递进关系**，按 §6.4 第 1 条操作会得到与预期相反的结果。
- **评审员是否声称亲自验证过**：是（两份均为静态逐行核实；「自建 + 开 E2EE 当前不可兼得」为代码确定行为，未运行时实测）
- **复现或验证方式**：报告未给出运行命令；验证方式为上列 `file:line` 的静态核验。

### 3. 「全部代码中只有一处 `execSync`」错误（4 文件 6 处；v1.0.0 为 0 处）
- **严重度**：高（架构评「严重」；TS 评「高」；网络评「不成立」）
- **涉及版本**：v0.6.3
- **证据**（三份报告的计数口径略有出入，原文并列）：
  > 架构：`packages/dsh-remote-web/lib/index.js :37 execSync(cmd, {...timeout:15000})` / `:695 execSync("sleep 1", {timeout:3000})` / 两个包逐字节副本 + `dsh-setup.mjs :104 execSync(cmd, {...timeout:timeoutMs})` + `clients/dsh-remote/dsh-bridge.mjs :125 execSync("ioreg -rd1 -c IOPlatformExpertDevice", ...)` ——「即 **6 处真实调用、跨 4 个文件**」
  > TS：表列 5 行 —— `dsh-setup.mjs:104`、`clients/dsh-remote/dsh-bridge.mjs:125`、`packages/dsh-remote-web/lib/index.js:37`、`:695`、`packages/dsh-remote-ui/lib/index.js:37,695` ——「实际是 3 个文件 5 处」
  > 网络：「v0.6.3 的 `execSync(` 调用点共 **6 处 / 4 个文件** —— `dsh-setup.mjs:29`（import）、`:104`；`clients/dsh-remote/dsh-bridge.mjs:68`、`:125`；`packages/dsh-remote-web/lib/index.js:19`、`:37`、`:695`；两个插件的 `lib/` 是同一构建的两份拷贝」；「**v1.0.0 中 `execSync`/`child_process`/`eval(`/`new Function`/`require(` 全部 0 命中** —— 该论断按字面对**哪个版本都不成立**」
- **计数口径差异（不仲裁）**：架构与网络记「6 处（网络含 import 行）」，TS 记「5 处」；三份对「不止一处」这一结论一致。
- **影响**：这是文档最「安抚性」的一行，且被放在「已核实」表里——`sh(cmd)` 是通用命令执行器（架构注明其调用面覆盖 `launchctl bootout`、`systemctl --user stop/disable/is-active`、`pgrep`/`ps`），「值得信任」的判断不应建立在「只有一处」上。
- **评审员是否声称亲自验证过**：是（三份均为全仓 grep + 逐文件计数；「无 `eval`/`new Function`」这半句三份都核实为真）
- **复现或验证方式**：`grep -rn "execSync"` 全仓（排除 `node_modules`）；TS 另用宽模式 `\beval\s*\(`、`new Function\s*\(`、`Function\s*\(\s*['"]` 搜索。

### 4. 两个插件包会被 `link-plugins.sh` 同时挂载 → 启动期重复路由硬报错
- **严重度**：高（架构评「中等」；TS 评「高」；取高）
- **涉及版本**：v0.6.3
- **证据**：`scripts/link-plugins.sh`（TS 引 `:89-105`、`:163-170`、`:172`；架构引 `:62`、`:89`、`:142`）；`harness/packages/host/webserver/src/index.ts:165-170`
  > `harness/packages/host/webserver/src/index.ts:165-170`：`if (table.has(route.path)) { throw new Error(\`webserver: duplicate ${route.kind} route "${route.path}"\`) }` ——「即第二条会被 `webserver: duplicate exact route "/dsh-remote/self"` 打断」（架构）
  > 「去重不会触发：`packages/dsh-remote-web/package.json` **完全没有** `dependencies` / `peerDependencies` / `optionalDependencies` 字段……两者**互不引用**」（TS）
  > 「node 半两个包注册**完全相同的路由集**——28 条 exact 路由加 1 条 prefix 路由（`packages/dsh-remote-web/lib/index.js:1729-2123`，`prefix: true` 在 `:2118`；ui 孪生包逐字节相同）」（架构）
- **影响**：收 submodule 后 `make setup` / `make dev` 会实际踩到（架构：「这不是假设性风险，而是本仓 `make setup` 会实际踩到的路径」）；TS 判其后果为「重复路由 / 重复设置页栏目 / 两套 launchd 控制逻辑并存」。落地方式必须显式二选一。
- **评审员是否声称亲自验证过**：部分——两份都核对了脚本与 harness 代码；架构明确声明**未运行**：「我核实了重复路由会 `throw`……但**没有运行**，所以『宿主插件 apply 期抛错时 dsh web 是整体启动失败、还是只标记该 fiber 失败并继续』我**没有验证**」
- **复现或验证方式**：报告未给出命令；架构给出的路径推演为「`plugins/dsh-remote/packages/*` 两个包都会被收为候选 → 都会被 `dsh plugin add link:` 挂进 profile」。

### 5. desktop-intro 引导路径把派生 MK 明文经中继下发 ⚠️ 架构与网络对同一机制给出不同严重度
- **严重度**：高（网络评「高」；架构评「轻微」，仅要求给 R1 补一句注释；取高）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:563`、`:571-578`；`e2ee-client.mjs:603-608`
  > 网络：`dsh-bridge.mjs:563`（`body = { ok: true, v: 2, grant: "desktop-intro", mk: g.mk, profile: g.profile, epoch: g.epoch, ts: Date.now() }`），以普通 `http` 帧发出，**没有** `application/vnd.dsh.e2ee-v2` 信封标记
  > 架构引作者注释 `clients/dsh-remote/e2ee-client.mjs:603-610`：「引导瞬间以「持有效扫码会话=账号本人」为准,**存在被中继主动冒充的理论窗口**(与扫码登录产品一致)」
  > 网络引协议文档：「协议文档自述矛盾：`docs/e2ee-protocol.md:334`（字段表明确列出 `mk:<派生MK base64url>`）对照 `:337`（「转发层可见『存在一次引导』，看不到内容语义之外的东西」）」
- **影响**：使用「扫码 / 一次性链接」进入的用户**必然**走这条路；一次引导即泄露 MK，而 MK 泄露 = 该账号全部历史与会话内容可解（与第 6 条叠加）。
- **评审员是否声称亲自验证过**：网络：是（静态逐行核实）；架构：是（但引的是作者注释，「§6.10 引用的是作者自己的注释，不是我独立得出的结论」）
- **复现或验证方式**：报告未给出运行方式；网络给出的核验坐标为上列 `file:line`。

### 6. 无前向保密：一次 MK 泄露覆盖全部历史流量
- **严重度**：高（网络评「高」；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/e2ee-client.mjs:199-215`、`:662-663`；`docs/e2ee-protocol.md:474`
  > `e2ee-client.mjs:199-215`（`saltH = sha256(a‖b)`；`SHK = HKDF-SHA256(ikm=MK, salt=saltH, info="dsh-e2ee/v1\0shk")`）；`:662-663`（握手时以明文 a、b 调用）；`docs/e2ee-protocol.md:474`（MK 定义，PBKDF2 600k）
  > 会话密钥不落盘、会话 TTL 24h（协议 §5.3），但**根密钥 MK 是长期、跨会话、跨设备唯一的**。
- **影响**：任何单次 MK 泄露的影响面不是「一个会话」而是「这个账号的一切」，且可**回溯解密此前全部**被录流量；文档 R1/R2 只讨论「中继是否能看到当前内容」，没点出这个放大效应。
- **评审员是否声称亲自验证过**：是（静态逐行核实）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 7. 设备隧道注册无归属校验，可被顶替
- **严重度**：高（网络评「高」；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/relay-router/src/index.mjs:703-741`、`:725-732`、`:508-517`、`:549-555`
  > `:725-732` **无条件** `existing.ws.close(4000, "replaced by new connection")` + `cleanupDevice(existing)`，随后 `:733-741` 才写入 `userId: String(claims.sub)`。**没有任何 `existing.userId === claims.sub` 检查**。
  > 对照 HTTP 路径**有**归属校验：`:508-517`（`authorizeRemote` 中 `String(dev.userId) !== String(claims.sub)` → `forbidden`）。
  > 自建模式把所有访问密钥映射到同一个身份：`:549-555`（`LOCAL_ACCESS_KEYS.includes(key)` → `signLocalJwt("local", "pro_max")`）。
- **影响**：同一自建 relay 上的另一个访问密钥持有者只需知道 deviceId（出现在手机 URL `/remote/dev-<12hex>/…`、设备列表与日志里）即可注册同名设备、把合法 bridge 踢下线并接管隧道；**自建部署下为高**（§6.4 恰恰在推荐自建）。
- **评审员是否声称亲自验证过**：是（静态逐行核实）
- **复现或验证方式**：报告未给出 PoC；核验坐标为上列 `file:line`。

### 8. 文档全文遗漏 `dsh-setup.mjs`（791 行）
- **严重度**：高（TS 评「高」；架构在 §5.2(b) 与 §6.7 给出同向证据，评「中等/轻微」；取高）
- **涉及版本**：v0.6.3
- **证据**：`dsh-setup.mjs:189`、`:199-211`、`:241-248`（TS 引全文 `grep -c "dsh-setup" docs/dsh-remote.md` = **0**）；架构引 `dsh-setup.mjs:34-36`、`:69`
  > 「它是本包的**官方入口**（`npx @mrrisega/dsh-remote` 落地的就是这个文件）| 根 `package.json`：`"bin": { "dsh-remote": "dsh-setup.mjs" }`」（TS）
  > 「§3（`:88`）和 §5（`:145`）都提到官方安装方式是 `npx @mrrisega/dsh-remote`，§5 还描述了它会『创建开机自启服务』，但**从没指出这条命令的实现就在仓内、有 791 行、`execSync` 就在里面**」（TS）
- **影响**：文档把它当外部黑盒（「作者的官方方式」），实际它是被评代码的一部分，且是安装期最有特权、`execSync` 所在处；口径遗漏直接导致第 3 条「已核实」结论错误（TS 的因果判断）。
- **评审员是否声称亲自验证过**：是（静态读取 + `grep -c`）
- **复现或验证方式**：`grep -c "dsh-setup" docs/dsh-remote.md` 与 `find`/逐文件读取，均为报告给出的静态核验。

### 9. `lib/` 不是「预构建产物」而是手写源码 ⚠️ 两份报告结论冲突
- **严重度**：高（TS 评「高」；网络表 A A5 与表 B R7 判「已核实」——需人工仲裁）
- **涉及版本**：v0.6.3
- **⚠️ 冲突记录**：TS 主张 R7「结论方向反了」；网络把同一 R7 判为「已核实（诚实）」，未独立核验 `lib/` 是否为构建产物。
- **证据**：`packages/dsh-remote-web/lib/client.js:1`、`:3`；根 `package.json` 的 `check` 脚本
  > TS：文件头自述 `// dsh-remote-web — browser half（手写 bundle，无需构建）`；`// 格式遵循 dsh 浏览器插件约定（双半插件，bundle 手写无构建）：`
  > TS：`grep -c "__commonJS\|__toESM\|__require\|esbuild\|rollup\|tsdown"` = **0 / 0**；client.js 平均行宽 **55.7** 字符；全仓 **0** 个 `tsconfig*.json` / `vite.config.*` / `tsdown.config.*` / `rollup.config.*` / `esbuild` 配置；唯一「构建」步骤是 `node --check`（语法检查）
  > TS 判定：「因此 R7 的『无法从本仓核对源码与产物的一致性』**不成立**——不存在一致性问题……真实情况正好相反：**这份代码是可以在仓内直接审阅的**」
  > 网络判定（相反方向）：「A5 | 两个插件包的 `lib/` 已提交（预构建可挂载） | …… | 已核实（但无法核对「产物 ← 源码」一致性，文档 R7 已自陈）」；「R7 | 审计深度不足；插件 `lib/` 预构建无法核对源码一致性 | 自陈 | 已核实（诚实）」
- **影响**：影响 R7 的表述与「这份插件代码能不能在仓内直接审」的判断，进而影响第 10、24 条。
- **评审员是否声称亲自验证过**：TS：是（md5/grep/wc/diff 静态核实）；网络：未针对该点独立验证（仅接受文档自陈）
- **复现或验证方式**：TS 给出 `grep -c "__commonJS\|__toESM\|__require\|esbuild\|rollup\|tsdown"`、`find` 全仓构建配置、读根 `package.json` 的 `check` 脚本。

### 10. 「约 9100 行」口径错误且低估近一半
- **严重度**：高（TS 评「高」；架构评「中等」；取高）
- **涉及版本**：v0.6.3
- **证据**：`docs/dsh-remote.md:163`（另见 `:14`、`:31`）
  > 文档原文：「我**通读了** v1.0.0（约 1000 行）……**v0.6.3 约 9100 行**（`clients/dsh-remote` + `packages/relay-router` + 两个插件包的 `lib/`），**我只做了定向扫描，没有做完整审计**。」
  > TS §0 实测（`wc -l`）：手写源码（不含测试）**4,651** + 安装器 **791** + 一份 `lib/` **4,564** + 别名副本 **4,564** + 测试 **7,376** = `.mjs`+`.js` 全仓合计 **21,946**；「手写、去重后的真实审计面 = 4,651 + 791 + 4,564 = **10,006 行**；计入测试为 **17,382 行**」
  > TS 反向拟合：「`clients/dsh-remote`（非测试，3,287）+ `packages/relay-router/src`（1,252）+ **一份** `lib/`（4,564）= **9,103** —— 与文档的「约 9100」几乎完全吻合（另一可能来源是两份 `lib/` 之和 9,128）」
  > 架构实测：「`clients/dsh-remote/` 5731 / `packages/relay-router/` 2039 / 两个插件包的 `lib/` 9128 → 文档列举的三项合计 **16898**」；「『9100』恰好只等于两个插件包 `lib/` 的行数（9128）」
- **口径差异（不仲裁）**：架构按 `wc -l` 全量（含测试）计，TS 区分「含测试 / 不含测试」；两份对**文档数字口径误导且低估**这一结论一致，对「9100 从哪来」给出两种不同拟合。
- **影响**：§6.1 是文档自立的「边界声明」，数字低估近一半且把 `dsh-setup.mjs` 791 行、`native.html` 2712 行排除在边界外，会让这个边界声明的保护作用打折；TS 另指出「9100」里有一半是文档自己声明「无法核对」的 `lib/`。
- **评审员是否声称亲自验证过**：是（两份均为 `wc -l` 实测）
- **复现或验证方式**：`wc -l`（排除 `.git` 与 `node_modules`）。

### 11. `engines.dsh` 的兼容性结论只在一条消费路径上成立 ⚠️ 两份报告结论冲突
- **严重度**：高（TS 评「高」；架构评「轻微」——只要求加「不被校验」注记；网络表 A A7 判「已核实」；取高）
- **涉及版本**：v0.6.3
- **⚠️ 冲突记录**：网络判「已核实」（`packages/dsh-remote-web/package.json:44`、`packages/dsh-remote-ui/package.json:44`）；TS 用本仓 `semver` 实测为 `false`，并指出 plugin-manager 路径 fail-closed。架构则称 harness **完全不读** `engines.dsh`。三方证据并列如下。
- **证据**：
  > 文档原文（`:78`）：「两个插件包的 `engines.dsh` 声明为 `>=0.1.0-rc.6 <0.2.0-0` —— **本仓的 `0.1.5-rc.2` 在范围内**。」（`:176` 同）
  > TS：`semver.satisfies('0.1.5-rc.2', '>=0.1.0-rc.6 <0.2.0-0')` => **false**；加 `{includePrerelease:true}` => **true**
  > TS：`plugins/dsh-web/packages/dsh-plugin-manager/src/core/version.ts:90`：`const MINIMUM_RANGE_PATTERN = /^>=\s*(v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/` → 双 comparator 不匹配 → `meetsMinimumDsh()` 返回 `undefined` → 「callers treat undefined as "cannot verify" and **fail closed**」
  > 架构：`grep -rn "\.engines\|engines\.dsh" --include="*.ts" harness/packages harness/apps harness/scripts` → **无任何命中**
- **影响**：同一句声明在 `dsh-market`（`discovery-compatibility.ts:129` 显式 `includePrerelease: true`，通过）、dsh-web plugin-manager（fail-closed）、裸 `semver.satisfies`（false）三条路径上结论不同；文档把它写成**无条件事实**。
- **评审员是否声称亲自验证过**：TS：是（用本仓 `plugins/dsh-at-file/node_modules/semver` 实跑，读 `version.ts` 源码）；架构：是（全仓 grep）；网络：仅引用包内字段，未验证消费路径
- **复现或验证方式**：TS 给出 semver 实测表达式；并注明「我没有端到端跑 plugin-manager 对 dsh-remote 的实际判定（需安装），因此『fail-closed 的具体用户可见后果』未实测」。

### 12. 插件半被描述得过窄：它实际是一个系统管理 agent
- **严重度**：高（架构评「严重」；TS、网络未单独评此项）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js`（架构给出的能力—坐标表节选）
  > 「后台 `npx` 自装运行时 | `ensureRuntime` `:428-455`，由 `apply` `:2188` 与 `scheduleRuntime` `:572-600` 驱动」
  > 「**改写 profile**（`cordis.patch.yml` / `package.json` / `node_modules`） | `uninstallSelf` `:1674-1712`」
  > 「**重启 DSH 宿主**（launchd/systemd/自拉起） | `restartHarness` `:849-893`，路由 `:1940`」
  > 「**`rm -rf` 配置目录**（带护栏：非 `/`、非 home、非 profile 目录） | `uninstallRuntime` `:640-712`」
- **影响**：文档「面板 + 路由」的定性会让读者（和评审 §8 落地方式的人）低估三件事：**它会自己装东西、会改 profile、会重启宿主**。
- **评审员是否声称亲自验证过**：是（静态逐行核实；未运行）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 13. 插件挂载后必然自动跑 `npx --yes …@latest`
- **严重度**：中（架构评「中等」——「§8 第 4 条做不到」；网络评「中」M8；取中）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js:428-455`、`:2188`、`:1592`、`:572-600`；`dsh-setup.mjs:675`
  > 架构：`apply()` 内 `:2188 const provisioned = ensureRuntime(relayDir);`；`:428-455`「`if (runtimeReady(relayDir)) return true; …… const child = spawn(npxCommand(), ["--yes", UPDATE_SPEC], { detached: true, ... });」；`:1592 UPDATE_SPEC = \`@mrrisega/dsh-remote@${UPDATE_TAG}\``
  > 网络：`:424-448`（`ensureRuntime()`：运行环境缺失时**自动** `spawn(npxCommand(), ["--yes", UPDATE_SPEC], { detached: true, env: { npm_config_registry: "https://registry.npmjs.org" } })`）、`:1588-1589`（默认 `latest`，可被 `DSH_UPDATE_TAG` 改）
  > 架构补充：唯一可控开关 `DSH_RELAY_SKIP_SERVICE=1` 是**测试隔离**用途（`:308-310`），生产上设它会让卸载/自启/重启全部跳过
- **影响**：供应链信任完全落在 npm 账号与 dist-tag 上；包被劫持或 `latest` 被推恶意版本时，**下一次插件装载（无需用户点击）**就以用户身份执行任意代码并落自启。文档 §8 第 4 条「不执行 `npx` 自动安装」在「link 插件进 profile」这条路上**不成立**。
- **评审员是否声称亲自验证过**：是（两份均为静态逐行核实；未运行）
- **复现或验证方式**：报告未给出运行命令；架构提出的验证路径为「插件被挂载且 `<relayDir>/dsh-setup.mjs` 不存在」。

### 14. 「一次性扫码链接 / 已授权设备管理」是 SaaS 专属能力
- **严重度**：中（架构评「中等」；TS、网络未提同一角度，网络 M7 从轮换角度另立一条）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js:1277-1310`、`:1313+`；`packages/relay-router/src/index.mjs:532`、`:564`、`:584`、`:609-612`
  > `packages/dsh-remote-web/lib/index.js:1277-1310`（`proxyCreateAccessKey`）：「GET /dsh-remote/access-key → 创建一次性访问密钥（企业端 POST /api/auth-key，Bearer device-login token）」
  > 自建的 `relay-router` 全部路由面：`:532 POST /_login`、`:564 GET /_devices`、`:584 GET /_quota`、`:412/:475 /remote/<deviceId>/<path>`、`:933 /_bridge`、`:609-612` 兜底 → 404
  > `grep -rn "auth-key|mobile-sessions" packages/relay-router/` 在业务代码里**零命中**
- **影响**：文档自己推荐的「自建 relay」路径上不存在二维码、一次性链接与「已授权设备」列表；连带使 §6.4 第 3、5 条与 §7「优先自建 relay」的建议失真。
- **评审员是否声称亲自验证过**：是（静态核验；注明「当前市场侧状态……我无法从本仓核实」属另一件事）
- **复现或验证方式**：报告给出的验证为 `grep -rn "auth-key|mobile-sessions" packages/relay-router/` 与读 `docs/self-hosting.md`。

### 15. 面板每 25 秒自动铸一把新的一次性链接
- **严重度**：中（网络评「中」M7；架构未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/client.js:1251`、`:1526`、`:1995`
  > `:1251`（`KEY_AUTO_REFRESH_MS = 25000`，注释「约每 25s 自动轮换一把新的一次性密钥」）、`:1526`（`setInterval(loadAccessKey, KEY_AUTO_REFRESH_MS)`）；UI 文案写着「30 分钟有效、用一次即失效」（`:1995`）
- **影响**：用户坐在面板前时每 25 秒就有一把新的有效链接被铸造；文档 §6.4 第 3 条「用完即刷新」并不能减少暴露面（旧的 30 分钟窗口仍开着），且这些链接经第 1 条的未授权端点可被本机任意请求者取走。
- **评审员是否声称亲自验证过**：是（静态核验）；「是否实际加载需在真实域名验证」属另一条（第 42 条）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 16. `bridge_secret` 缺失 → 面板静默显示「尚未登录」
- **严重度**：中（架构评「中等」为主，§6.11 部分评「轻微」；TS、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js:905-930`（作者自己的代码注释）、`:237-266`；`clients/dsh-remote/dsh-bridge.mjs:361-362`
  > 「**只装插件**的路径（dsh plugin add / 插件市场安装）没有这一步，于是：首次安装 → 打开设置面板立即登录 → 面板请求 `/dsh-remote/access-key` & `mobile-sessions` → relayToken 拿不到 token（401 需要设备密钥）→ 面板显示「尚未登录」（其实是密钥缺失）」
  > 「2021-… v1.0.0 那条「首次必须手动做 DSH token 交换」的坑……该机制已被显式替换：`lib/index.js:237-266 mintHarnessCookie(ctx, relayDir)`（从 `ctx.get('connection')` 取会话并落盘 0600）；`dsh-bridge.mjs:361-362 if (ck) out.Cookie = ck;`」
- **影响**：这是文档 §8.5 列为「待验证」的事，实际是**已知且已在代码注释里记录**的确定行为——不是路径问题，而是凭据缺失；源码安装必须手工补 `bridge_secret`。
- **评审员是否声称亲自验证过**：是（静态读取作者注释与调用点；未运行）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 17. 源码形态下配置目录被解析为 checkout 自己
- **严重度**：中（架构评「中等」；TS §4/O3 提到安装器但未提此解析行为；网络未提）
- **涉及版本**：v0.6.3
- **证据**：`dsh-setup.mjs:34-36`、`:69`；`packages/dsh-remote-web/lib/index.js:27`
  > `dsh-setup.mjs:34-36`：`const IS_NPM_INSTALL = THIS_DIR.includes(\`${path.sep}node_modules${path.sep}\`);` / `const CONFIG_DIR = process.env.DSH_RELAY_DIR || (IS_NPM_INSTALL ? path.join(os.homedir(), ".dsh-remote") : THIS_DIR);`
  > `dsh-setup.mjs:69`：`if (!IS_NPM_INSTALL) return;   // 仓库开发形态：原地使用（跳过把运行时固化到 CONFIG_DIR）`
  > 「唯一的干净出路是 `DSH_RELAY_DIR`……**文档完全没提这个环境变量**」
- **影响**：凭据（`.dsh-config.json`、设备私钥、`.harness-cookie.json`，全部 0600）会落在**被 pin 的 submodule 目录**（`plugins/dsh-remote/`），与本仓「submodule 只读 pin」约定直接冲突；且 `<relayDir>/dsh-setup.mjs` 永不出现 → `runtimeReady()` 恒为 false → 插件持续反复触发 `npx`（与第 13 条叠加）。
- **评审员是否声称亲自验证过**：是（静态逐行核实）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 18. 插件会在运行中改写 profile 并重启 DSH 宿主
- **严重度**：中（架构评「中等」；TS 未提；网络未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-web/lib/index.js:1674-1712`、`:849-893`、`:1940-1944`
  > `uninstallSelf(relayDir, profileDir, patchFile, pkgFile)`（`:1674-1712`）直接**编辑 profile 的 `cordis.patch.yml` 与 `package.json`**（删 `dependencies` 条目、从 `dsh.profile.bundles` 里 filter 掉、`rmSync` 掉 `<profileDir>/node_modules/<id>` 与 `<profileDir>/<id>-plugin`）
  > `restartHarness(relayDir)`（`:849-893`）会用 `launchctl kickstart` / `systemctl restart` **重启 DSH 宿主进程本身**，并暴露成 `/dsh-remote/harness/restart` 路由（`:1940-1944`）
- **影响**：对本仓而言是**越界**——profile 由 `scripts/link-plugins.sh` + `scripts/merge-profile-patch.mjs` 管理，而该插件会在运行中改同一批文件，存在写入冲突面。
- **评审员是否声称亲自验证过**：是（静态逐行核实；未运行）
- **复现或验证方式**：报告未给出命令；核验坐标为上列 `file:line`。

### 19. `dsh.client.inject` 指向一个不存在的包
- **严重度**：中（架构评「中等」；TS、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/dsh-remote-{web,ui}/package.json`；`harness/packages/client/modules/src/client/system.ts:165-168`
  > `"dsh": { "client": { "platform": "web", "inject": ["@deepseek-ai/dsh-client-runtime"] } }` —— 「`@deepseek-ai/dsh-client-runtime` **在 harness 全仓与本机 `node_modules` 都不存在**」
  > `harness/packages/client/modules/src/client/system.ts:165-168`：`for (const packageName of row.inject) { const dependency = this.graphRows.get(packageName); if (dependency !== undefined) await this.arriveGraphRow(...) }` —— 未注册的名字被**静默跳过**
- **影响**：不是 bug，但意味着插件声明的浏览器半契约不是真的；浏览器半的真实依赖是 `react` 种子模块与 `settings.section` / `shell.overlay` 两个槽。
- **评审员是否声称亲自验证过**：是（全仓 grep + 读 harness 消费点）
- **复现或验证方式**：报告给出的验证为 `grep -rn "dsh-client-runtime" harness/` 与 `ls harness/node_modules/@deepseek-ai/`。

### 20. 别名包同步脚本的盲区 + 发布工作流不校验
- **严重度**：中（TS 评「中」，并入 O2；架构 §2 从「同挂即冲突」角度提到同一目录；网络未提）
- **涉及版本**：v0.6.3
- **证据**：`scripts/sync-legacy-alias.mjs:28-41`、`:49-60`、`:78-81`、`:85`；`.github/workflows/release-tarballs.yml:66-70`
  > 「**新增文件不会被同步，也不会报错**。脚本没有任何「目录清单比对」：若源包新增 `lib/foo.js`……别名包会**静默缺失该文件**」
  > 「`cordis.patch.yml` 的首行注释替换用的是正则 `/^# dsh-remote-web/m`（`:85`），**这是全脚本唯一一处「匹配不到也不报错」的替换**」
  > 「**`.github/workflows/release-tarballs.yml` 不跑 `npm run check`**：它直接 `cd packages/$pkg && npm pack`（`:66-70`）……⇒ **可以在别名包未同步的情况下打 tag 并发布**」
  > 正面：「`SUBS`（`:28-41`）对每个待替换片段做「命中不到即报错」（`:78-81`：`problems.push('… 源包结构可能已变，请更新 sync 脚本')`）……说明作者是清醒的」
- **影响**：漂移后，从旧条目安装的用户拿到的会是与新名条目**不一致**的代码；本仓计划长期收 submodule，双份代码的漂移是长期成本。
- **评审员是否声称亲自验证过**：是（读脚本与 workflow 文件）；「CI 的实际执行历史 —— 未联网，未查 GitHub Actions 运行记录」
- **复现或验证方式**：报告未给出执行命令；验证为读 `.github/workflows/*.yml` 与 `sync-legacy-alias.mjs`。

### 21. `@dsh-remote/client` 的 `main` 指向不存在的文件
- **严重度**：中（TS 评「中」，另列 O7；架构、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/package.json`
  > `"main": "src/index.js"` ——「`clients/dsh-remote/src/` 下**只有 `lifecycle.mjs`（3 行）**，**没有 `index.js`** | ❌ **悬空入口**」
  > 「它现在没炸，是因为没有任何代码 `import '@dsh-remote/client'` —— bridge 是由 `dsh-setup.mjs` 直接 spawn `.mjs` 文件运行的。」
- **影响**：一旦有人按包名消费它，resolve 立即失败；同表另列 `exports` / `files` / `engines` / `private` 均缺失（`exports` 缺失会使 `./src/lifecycle.mjs` 无法被子路径导入）。
- **评审员是否声称亲自验证过**：是（读 `package.json` 与列目录）
- **复现或验证方式**：报告未给出命令；验证为读 `clients/dsh-remote/package.json` 与 `find clients/dsh-remote/src`。

### 22. 两个插件包无 LICENSE，发布 tarball 不含许可正文
- **严重度**：中（TS 评「中」，另列 O6；架构 §6.9 从「许可证构成」角度提到；网络未提）
- **涉及版本**：v0.6.3
- **证据**：两个包 `package.json` 的 `files` 白名单；`.github/workflows/release-tarballs.yml:66-70`
  > 「`files` 白名单含 `LICENSE` | ❌ `["lib","cordis.patch.yml","screenshots.json","README.md"]`」（对照 `plugins/dsh-at-file` ✅ `files` 含 `"LICENSE"`）
  > 「代码为 PolyForm-Noncommercial-1.0.0（非 OSI 许可，条款要求随附 "Required Notice" 与许可文本），而**分发给用户的 tarball 里没有许可正文**」
- **影响**：§9 花了一整节讲许可义务，却没注意到发布物里没有许可正文。
- **评审员是否声称亲自验证过**：是（读包目录与 workflow）
- **复现或验证方式**：报告未给出命令；验证为读两个包 `package.json` 的 `files` 与 workflow 文件。**同节另注（报告自我否证）**：「`exports` 字段并不缺失（我在核实前怀疑的方向被证伪，如实记录）」；「`publishConfig.access` 对**非 scoped** 包名（`dsh-remote-web`）不是必需的，属可选，不必当作缺陷上报」。

### 23. 分块信封重组缓冲无上界 + relay 单帧 256 MB
- **严重度**：中（TS 评「中」，另列 O5；架构、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/relay-router/src/index.mjs:172`、`:231-259`、`:244-254`、`:699`；`clients/dsh-remote/dsh-bridge.mjs:304-326`、`:980`
  > `:246-249`：`if (!acc) { acc = { n: c.n, parts: [] }; bufs.set(c.id, acc); }` / `:250` `acc.parts[c.i] = c.data;` / `:251` `if (acc.parts.filter(Boolean).length === acc.n) {` / `:253` `bufs.delete(c.id);` ← 唯一删除点
  > 「**`c.id` / `c.n` / `c.i` 无任何校验**……发送 `{"__chunk":{"id":"<随机串>","n":1000000000,"i":0,"data":"x"}}`，`parts.filter(Boolean).length` 永远到不了 `1e9`，该条目**永久驻留**」
  > `:172` `const WS_MAX_PAYLOAD = 256 * 1024 * 1024;` ——「**单帧 256 MB**。`maxPayload` 只约束**单帧**，不约束上述**跨帧累积**」
- **影响**：这是一个具体的、有 file:line 依据的资源耗尽面，且落在公网中继上（自建时则落在你自己的公网机器上）；§7 推荐自建 relay 却没提示。
- **评审员是否声称亲自验证过**：部分——「我没有构造 PoC、没有实测利用，以上是静态分析结论；实际可达性取决于 tunnel 建立前是否有其它屏障（我未逐行追完 relay 的握手鉴权流程，标为未核实）」
- **复现或验证方式**：报告未给出 PoC；给出的静态核验坐标为上列 `file:line`。

### 24. 质量闸门薄弱：无类型 / 无 lint / 无构建；CI audit 恒不失败
- **严重度**：中（TS 评「中」，另列 O4；架构、网络未提）
- **涉及版本**：v0.6.3
- **证据**：根 `package.json` `scripts.check`；`.github/workflows/ci.yml`
  > 「（dsh-remote 的 `check` 脚本全文：`node --check` 5 个文件 + `bash -n deploy/install-open.sh` + `npm run check:alias`。**没有类型、没有 lint、没有构建**。）」
  > 「`audit` job 的命令是 `npm audit --audit-level=high \|\| true` —— **`\|\| true` 使其永不失败**，等于没有审计门禁。」
  > 对照表：`plugins/dsh-at-file` / `plugins/modlens` 均有 `"typecheck": "tsc --noEmit"`，modlens 另有 biome lint 与 `vite build`；dsh-remote 为**纯 JS**（42 `.mjs` + 5 `.js`，**0 个 `.ts`**）
- **影响**：文档 §3 的「构建」一行只谈「跳过构建」这个操作便利，没指出它同时意味着**放弃了所有编译期保证**；「JS 无类型靠什么保证契约」的答案是「靠 7,376 行测试 + `node --check`」。
- **评审员是否声称亲自验证过**：是（读 `package.json`、workflow 与既有插件对照）
- **复现或验证方式**：报告未给出命令；验证为读根 `package.json` 与 `.github/workflows/ci.yml`。

### 25. E2EE 静默降级路径
- **严重度**：中（网络评「中」M1；架构 §6.11 从另一角度提到 E2EE 状态；TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/e2ee-shim-script.js:402`、`:410-420`、`:439`、`:502`
  > `:402`（`if (!ctx || !ctx.sess) return origFetch(input, init)`）、`:410-420`（`req.bodyUsed`、流式 body、`clone()` 失败、`arrayBuffer()` 失败 → 直接明文 `origFetch`，**均未调用 `seNotifyFail`**）、`:439`（`if (!seIsEnvelopeResponse(res)) return res; // router/桥端明文错误页原样透传`）、`:502`（`if (!env || … || env.k !== "w") { this._deliver(raw, false); return; } // 明文帧透传(不应出现)`）
- **影响**：用户在「已加密」的心理预期下实际走明文，且没有任何提示；触发条件不需要攻击者（上游错误页、协议不匹配、流式响应都会命中），与协议 §2.4「不静默」的承诺冲突。
- **评审员是否声称亲自验证过**：是（静态逐行核实）
- **复现或验证方式**：报告未给出运行方式；核验坐标为上列 `file:line`。

### 26. 宽屏（>820px）下不显示任何告警徽标
- **严重度**：中（网络评「中」M2；架构未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/e2ee-shim-script.js:644-648`
  > `if (mode !== "ok" && window.innerWidth > 820) return;`，注释称与 mobile-adapter 的「桌面零打扰」契约一致
- **影响**：在电脑/平板上经远端打开镜像页时，明文/降级/失败**完全不可见**——与第 25 条叠加即「无声明文」；而文档 §6.4 恰恰让用户「确认 E2EE 已真正开启（面板状态为准）」，这个面板在最容易发生降级的宽屏下不显示状态。
- **评审员是否声称亲自验证过**：是（静态核验）
- **复现或验证方式**：报告未给出命令。

### 27. E2EE 参数与 KDF 来自与隧道同一来源、无签名
- **严重度**：中（网络评「中」M3；架构未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/e2ee-client.mjs:110-119`、`:160`；`docs/e2ee-protocol.md:289`
  > `:110-119`（`normalizeKdf` 对非法/缺失输入回落到默认，但**接受任何 `iter >= 1`**）、`:160`（握手参数中的 `kdf` 直接 `normalizeKdf(e2.kdf)` 采用）
- **影响**：掌握 TLS 终点的一方可返回 `enabled:false` → 全部明文（叠加第 25 条的无声回退）；或返回 `iter:1` 使 MK 派生近乎免费，配合「密码明文存电脑端/登录时经手服务端」的现实，离线爆破变得可行。
- **评审员是否声称亲自验证过**：部分——「`iter` 下限：我确认客户端接受 `iter >= 1`……但服务端实际下发什么值、是否会下发异常低值，**未核实**」
- **复现或验证方式**：报告未给出命令。

### 28. 桥端 HTTP 转发默认跟随重定向 → SSRF
- **严重度**：中（网络评「中」M4；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:449`、`:387`；对照 `:718`、`:956`
  > `dsh-bridge.mjs:449`（`fetch(url, { ...init, signal })`，**未设** `redirect: "manual"`），对照 WS 路径显式 `followRedirects: false`（`:718`、`:956`）
  > 实测（报告作者自写回环探针 `/tmp/redirect-probe.mjs`）：跨 port 的 302 **被跟随**，但 `cookie` 与 `authorization` 被剥掉（探针输出 `{ "url": "/stolen", "cookie": null, "auth": null, "host": "127.0.0.1:55293" }`）
- **影响**：能触达该转发路径的人可让 bridge 向 PC 可达的任意地址发起 GET/POST——内网探测、以 PC 身份触发内网设备动作；因 undici 剥凭据，未发现凭据泄露。
- **评审员是否声称亲自验证过**：部分——「我用回环探针 `/tmp/redirect-probe.mjs` 实测 undici 行为」；但「`undici` 的重定向行为我只在本地独立探针（当前 Node）上验证，与 bridge 目标运行环境可能有版本差异，**推断**」
- **复现或验证方式**：报告给出的是作者自写探针 `/tmp/redirect-probe.mjs`（只监听 127.0.0.1）；未给出仓库内命令。**术语提示**：报告建议文档区分——`followRedirects: false` 是 **ws 库**的选项，与 HTTP 转发无关。

### 29. 第二份凭据 `.harness-cookie.json` 未提
- **严重度**：中（网络评「中」M5；架构 §6.11 提到该机制但作为「坑已消失」的正面证据，未视为风险）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:175-181`、`:361-362`、`:442-443`；`packages/dsh-remote-web/lib/index.js:221-224`、`:260`
  > 「它绕过的正是 harness 的第二道门 `rpc-host.ts:99` → `browser-auth.ts:289-302`（authority 绑定 + 签名 + 有效期）」
  > 「该文件等于「已授权浏览器」的通行证；拿到它就等于手机端的浏览器身份（有效期由 harness 的 `maxAgeMilliseconds` 决定）」
- **影响**：文档把 `.dsh-config.json` 列为唯一「等同解密权」的文件，遗漏了这一份。
- **评审员是否声称亲自验证过**：是（静态核验）；「harness `browserAuth` 的 cookie 生成/续期策略细节……因此 M5 的「有效期」表述为「由 harness 的 maxAge 决定」，未给具体数值」
- **复现或验证方式**：报告未给出命令。

### 30. ed25519 设备密钥不参与认证
- **严重度**：中（网络评「中」M6；架构 §1 表只确认字段存在；TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:207-218`、`:915`、`:966`；`packages/relay-router/src/index.mjs:705`
  > 「`dsh-bridge.mjs:207-218`（生成并持久化），`:915`（`resolveDevicePubKey()` 的结果只用于设备登记上报），全仓无任何用私钥签名/验签的调用点；隧道注册用的是 JWT（`:966` 的 `tunnel-register` 携带 `token`），验证在 `relay-router/src/index.mjs:705`」
- **影响**：文档 §6.2 把「ed25519 密钥对 + deviceId」列为设备身份，容易让人以为设备侧有密码学绑定（从而抵抗第 7 条的顶替）；实际上是纯账号/JWT 绑定，deviceId 只是一个可被冒名的名字。
- **评审员是否声称亲自验证过**：是（静态核验）
- **复现或验证方式**：报告未给出命令。

### 31. `clients/dsh-web/native.html` 是自建必需部署件
- **严重度**：中（架构评「中等」；TS §0 只把它计入行数（2,712 未纳入扫描）；网络 I5 从统计脚本角度另计一条）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-web/native.html`（2712 行）；`docs/self-hosting.md`
  > 「自建模式下它是必须自行托管的第三个部署件——`docs/self-hosting.md`：「`clients/dsh-web/native.html` is a single-file PWA. Point nginx at it… `location /app/ { alias /srv/dsh-remote/app/; … }`」」
- **影响**：文档 §2 表「客户端资源」的说法掩盖了它是自建部署的**必需件**；§7 对比表说 v0.6.3「浏览器直开，移动端专门适配」——SaaS 下成立，自建下需要额外托管一个 2712 行的单文件 PWA。
- **评审员是否声称亲自验证过**：部分——「只核了它不是 npm 包、2712 行、以及 `docs/self-hosting.md` 对它的部署描述；**没有读它的实现**」
- **复现或验证方式**：报告未给出命令。

### 32. 本仓已有一个功能重叠的远程访问插件
- **严重度**：中（架构评「中等」，并称「本次评审对决策最有价值的一条」；TS、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`plugins/dsh-web/packages/dsh-remote-web-ui/package.json`、`cordis.patch.yml`
  > `"name": "@linxin666/dsh-remote-web-ui"   version 0.3.17   license Apache-2.0`
  > `description: "Scan-to-pair remote access for the dsh web GUI … one-time tokens and revocable device sessions, with a LAN bind toggle, optional Cloudflare tunnel, and one-click family self-update"`
  > 「**没有硬冲突**——本仓现有 entry id 是 `better-sidebar` / `agent-teams` / `modlens` / `dsh-market` / `modsearch` / `dsh-at-file` / `dsh-mineru` / `dsh-automation`……dsh-remote 用 `dsh-remote-web` / `dsh-remote-ui`，与以上均不重名」
- **影响**：§3 的对比表只说「之前 10 个插件」是无额外组件、MIT 的形态，从未指出其中之一正是同类功能的替代方案（**无第三方中继、无第三方账号、无 `npx` 安装器、无开机自启常驻进程**）。
- **评审员是否声称亲自验证过**：是（读源码）；但「**当前实际的插件挂载状态**（本仓 9 个插件是否已挂、挂在哪个 profile）我**没有核实**」
- **复现或验证方式**：报告未给出命令；验证为读 `plugins/dsh-web/packages/dsh-remote-web-ui/` 下的 `package.json` 与 `cordis.patch.yml`。

### 33. CI 的插件清单硬编码，收 submodule 后必须同步修改
- **严重度**：中（TS 评「中」，列 O8；架构、网络未提）
- **涉及版本**：v0.6.3
- **证据**：`.github/workflows/verify.yaml:39`、`:27`；`.github/workflows/release.yaml:44`
  > 「**CI 的插件清单是硬编码的**，收 submodule 后必须同步修改，否则 pin 不被校验」——「与 AGENTS.md 的硬约束『tag pin 以 verify.yaml / release.sh 比对校验』直接相关；文档 §8 只说了『作为 submodule 收进本仓，pin v0.6.3』，漏了这一步」
- **影响**：不修改清单则 pin 一致性校验对新 submodule 不生效。
- **评审员是否声称亲自验证过**：是（读 workflow 文件）；「CI 的实际执行历史 —— 未联网，未查 GitHub Actions 运行记录」
- **复现或验证方式**：报告未给出命令。

### 34. §4.1 的结论过强：漏了两道独立闸门 ⚠️ 两份报告分别指出不同的漏项（不冲突，但需并列）
- **严重度**：低（架构评「轻微」；网络未单独评级，仅在表 D 标「部分成立」/「漏了一道门」）
- **涉及版本**：v0.6.3（harness 0.1.5-rc.2）
- **证据**：
  > 网络（漏服务端认证门）：`harness/packages/client/connection/src/rpc-host.ts:99` → `browser-auth.ts:289-302` ——「文档此处漏了一道门：`/api` 除 `isTrustedApiRequest` 外还要过 `browserAuth.isAuthenticated`……bridge 靠 `dsh-bridge.mjs:442-443` 注入 `.harness-cookie.json` 里的 cookie 才通过」
  > 架构（漏客户端 loopback 门）：`harness/packages/client/connection/src/client/index.ts:227` ——`isLoopback: transport?.ownsHost === true || pageLocation === undefined || isLoopbackHostname(pageLocation.hostname)`；`loopback-hostname.ts:12-18` 只认 `localhost` / `[::1]` / `127.0.0.0/8`
  > 架构：「bridge 只重写 HTTP `Host` 头（`clients/dsh-remote/dsh-bridge.mjs:360 out.Host = up.host`），**改不了浏览器的 `location.hostname`**——所以 §7 方案 B 与方案 C 在这一条上是**同等的**」
- **影响**：文档「`--trusted-host <你的域名>` 配合保留 Host 的普通反代也能让全部方法通过」「DSH 的围栏对远程用户失效」两句过强；远程会话实际拿到的是「非特权」客户端形态（设置只读、不落盘：`ui-settings/src/client/index.ts:58`、`ui-settings-general/src/client/index.ts:76-78`）。
- **评审员是否声称亲自验证过**：是（两份均为静态逐行核实；均未端到端实测）
- **复现或验证方式**：报告未给出命令；架构的方法为全仓 `grep` 调用点（生产代码只有 `rpc-host.ts:98` 一处，其余命中都在测试里）。

### 35. `writeFileSync(..., { mode: 0o600 })` 只对新建文件生效
- **严重度**：低（网络评「低」L1，另在表 A A3 判「部分成立」；架构在 §5.2(b) 提到凭据 0600 但未提该缺陷；TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-remote/dsh-bridge.mjs:167`；`dsh-setup.mjs:141`；对照 `packages/dsh-remote-web/lib/index.js:192-195`
  > 「`writeFileSync` 的 `mode` **只对新建文件生效**，`dsh-bridge.mjs`/`dsh-setup.mjs` 均无 `chmod` 兜底（全仓 `chmod` 只出现在插件 `lib/index.js:192-195`，作者自己在注释里写明「文件已存在时 writeFileSync 不改权限，显式 chmod 兜底」）」
- **影响**：若 `.dsh-config.json` 曾被以宽松权限创建/恢复，文档声称的 0600 不成立。
- **评审员是否声称亲自验证过**：是（静态核验）
- **复现或验证方式**：报告未给出命令。

### 36. §9「本仓其余插件均为 MIT」不成立
- **严重度**：低（架构评「轻微」；TS 未提；网络未提）
- **涉及版本**：v0.6.3
- **证据**：`plugins/dsh-plugin-mineru/package.json`、`plugins/dsh-web/package.json`（逐个读 `plugins/*/package.json` 的 `license`）
  > 「dsh-plugin-mineru: AGPL-3.0        ← 非 MIT / dsh-web: Apache-2.0                 ← 非 MIT」
  > 「结论方向（引入 PolyForm-Noncommercial 会改变许可证构成）依然成立，但「其余均为 MIT」这个前提不成立——本仓已有 AGPL-3.0 与 Apache-2.0。」
- **影响**：结论方向不变，但前提陈述有误。
- **评审员是否声称亲自验证过**：是（逐个读 `package.json`）
- **复现或验证方式**：报告未给出命令；验证为读 `plugins/*/package.json`。

### 37. `package-lock.json` 陈旧且把 `ws` 钉在第三方镜像
- **严重度**：低（TS 评「低」L1；网络评「低」L5）
- **涉及版本**：v0.6.3
- **证据**：`package-lock.json:3,9`、`:51`
  > TS：「root `version` 是 `0.6.1-beta.1`（`package.json` 是 `0.6.3`）；`packages/dsh-remote-web` 记 `0.6.1-beta.1`、`packages/dsh-remote-ui` 记 `0.6.0`……含三个**已删除** workspace 的 `extraneous` 条目（`packages/protocol`、`packages/relay-core`、`packages/relay-free`）；`node_modules/ws` 的 `resolved` 是 `https://registry.npmmirror.com/ws/-/ws-8.21.3.tgz`（第三方镜像，非 `registry.npmjs.org`）」
  > 网络：「文档 §6.2 的「依赖面」「可复现」印象需打折：锁文件与版本不同步，`npm ci` 会取镜像站内容。」
- **影响**：文档 §8 的源码安装路径依赖 lockfile（`ci.yml` 的安装步骤正是 `npm ci`），锁文件与 manifest 脱节是明确的源码安装风险。
- **评审员是否声称亲自验证过**：部分——「我没有执行 `npm ci`，无法断言它一定失败（npm 对 version 字段不一致的容忍度随版本而异）」
- **复现或验证方式**：报告未给出命令；验证为读 `package-lock.json`。

### 38. `engines.node` 三处不一致
- **严重度**：低（TS 评「低」L3；架构、网络未提）
- **涉及版本**：v0.6.3
- **证据**：根 `package.json`、`packages/relay-router/package.json`、两个插件包 `package.json`
  > 「根 `package.json`：`"node": ">=20"`；`packages/relay-router/package.json`：`">=22.13.0"`；两个插件包：无声明。而宿主 harness 是 `"^22.19.0 || >=24.0.0"`」
- **影响**：§8 计划自建 relay 时，其前置条件是 **Node ≥22.13**，文档未提。
- **评审员是否声称亲自验证过**：是（读 `package.json`）
- **复现或验证方式**：报告未给出命令。

### 39. `/_login` 非常量时间比较且无速率限制
- **严重度**：低（网络评「低」L2；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/relay-router/src/index.mjs:548-555`
  > 「`/_login` 用 `LOCAL_ACCESS_KEYS.includes(key)` 做非常量时间比较，且**无速率限制**……访问密钥足够长时在线爆破不现实，但共享密钥场景下建议加恒定时间比较 + 限速」
- **影响**：共享密钥场景下的在线爆破面（对照信息项：JWT 校验本身用了 `timingSafeEqual`，质量不错）。
- **评审员是否声称亲自验证过**：是（静态核验）
- **复现或验证方式**：报告未给出命令。

### 40. 配额/用量为进程内存态
- **严重度**：低（网络评「低」L3；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/relay-router/src/quotas.mjs:88-92`、`:99-107`；`packages/relay-router/src/index.mjs:508-517`、`:555`
  > 「配额/用量为进程内存态，重启清零……自建模式下所有访问密钥共享一个 `sub`，因此共享额度、共享 8Mbps 速率」
- **影响**：可用性/计费一致性问题；与第 7 条同源（自建下所有人一个 `sub`）。
- **评审员是否声称亲自验证过**：是（静态核验 + README/SECURITY.md 自陈）
- **复现或验证方式**：报告未给出命令。

### 41. relay 的 deviceId 正则宽松
- **严重度**：低（网络评「低」L4；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`packages/relay-router/src/index.mjs:167-168`
  > 「deviceId 正则是宽松的 `^(dev-[0-9a-f]{12}|[a-z0-9][a-z0-9-]{1,63})$`，与 bridge 的 `dev-<12hex>` 不一致；宽松形态便于伪造好记的 id（与 H4 叠加，降低顶替门槛）」
- **影响**：与第 7 条叠加。
- **评审员是否声称亲自验证过**：是（静态核验）
- **复现或验证方式**：报告未给出命令。

### 42. 官方 SaaS 域名页面注入第三方统计脚本，而同源 `localStorage` 存着 MK
- **严重度**：低（网络归类为「信息」I5；架构、TS 未提）
- **涉及版本**：v0.6.3
- **证据**：`clients/dsh-web/native.html:293-303`；`docs/e2ee-protocol.md:292`
  > 「在 `location.hostname === "n.risegao.cn"` 时注入百度统计脚本 `https://hm.baidu.com/hm.js?...`；而手机端的 MK 存在同源 `localStorage`（协议 `:292`）→ 同源第三方脚本理论上可读」
- **影响**：是否实际加载需在真实域名验证——「**未核实**，但文档未提这一同源关系」。
- **评审员是否声称亲自验证过**：否（明确标为未核实）
- **复现或验证方式**：报告未给出命令；需真实域名验证。

---

## 对 docs/dsh-remote.md 断言的反驳

> 仅收录「报告认为文档（或其分析）把事实搞错 / 说过头」的地方；纯遗漏项已在上表中。两份报告结论相反者标 ⚠️，两方证据并列，不仲裁。

| # | 文档断言（原文 + 位置） | 报告的反驳 |
|---|---|---|
| A | §6.2 `:170`：「危险原语 \| 全部代码中**只有一处** `execSync`：`clients/dsh-remote/dsh-bridge.mjs:125` 执行 `ioreg -rd1 -c IOPlatformExpertDevice`……**非恶意**；无 `eval` / `new Function`」 | 三份一致反驳。架构：「**6 处真实调用、跨 4 个文件**」；TS：「实际是 3 个文件 5 处」；网络：「**不成立**……该论断按字面对**哪个版本都不成立**（v1.0.0 是 0 处而非 1 处）」。三份均确认「无 `eval` / `new Function`」这半句为真 |
| B | §1.1 `:24`「`lib/` **已提交在仓库内**（预构建）」；§3 `:89`「插件的 `lib/` **已提交（预构建）** → 命中「跳过构建」判据」；§6.2 `:174`「**已提交**（预构建，无需构建即可挂载）」；R7 `:188`「插件包 `lib/` 是**预构建产物（无法从本仓核对源码与产物的一致性）**」 | ⚠️ **TS**：「术语错误，且结论方向反了……仓库里**不存在**「源码 → 产物」的分离」；「无打包器特征 `grep -c "__commonJS\|__toESM\|__require\|esbuild\|rollup\|tsdown"` = **0 / 0**」；「【操作结论仍然对，但理由错了】……真正该由此得出的结论是：**没有类型、没有类型检查、没有 lint、没有构建期校验**」。**网络**：表 A A5 判「已核实（但无法核对「产物 ← 源码」一致性，文档 R7 已自陈）」，表 B R7 判「已核实（诚实）」——未独立核验该定性 |
| C | §9 末 `:246`：「本仓其余插件均为 MIT；引入本插件会改变本仓的许可证构成」 | **架构**：「**错误。**……「其余均为 MIT」这个前提不成立——本仓已有 AGPL-3.0 与 Apache-2.0」（逐个读 `plugins/*/package.json` 的 `license`） |
| D | §6.1 `:163`（及 `:14`）：「**v0.6.3 约 9100 行**（`clients/dsh-remote` + `packages/relay-router` + 两个插件包的 `lib/`）」 | **TS**：「口径是误导性的……这个「9100 行」里有**一半是文档自己声明"无法核对"的东西**——用"无法审计的部分"充大"待审计规模"，逻辑上自相矛盾」；实测反向拟合 9,103。**架构**：实测「文档列举的三项合计 **16898**」，「『9100』恰好只等于两个插件包 `lib/` 的行数（9128）」。两份拟合不同（见第 10 条口径差异） |
| E | §2 `:78`「两个插件包的 `engines.dsh` 声明为 `>=0.1.0-rc.6 <0.2.0-0` —— **本仓的 `0.1.5-rc.2` 在范围内**」；§6.2 `:176`「本仓 `0.1.5-rc.2` **满足**」 | ⚠️ **TS**：「文档把「在范围内/满足」写成了**无条件事实**，实际它**依赖消费者**：market 通过、plugin-manager fail-closed、裸 semver 为 false」；实测 `semver.satisfies('0.1.5-rc.2', '>=0.1.0-rc.6 <0.2.0-0')` => **false**。**架构**：「**实际上 harness 完全不读 `engines.dsh`**」（全仓 grep 无命中）。**网络**：表 A A7 判「已核实」 |
| F | §4.1 `:136`：「`--trusted-host <你的域名>` 配合保留 Host 的普通反代也能让**全部方法通过**」；R4 `:185`：「DSH 的围栏对远程用户失效」 | **架构**：「§4.1 的「围栏层面」推论正确；但由它推出的……以及 §6.3 的 R4……都**过强**：请求围栏确实失效，但 `ctx.connection.isLoopback` 这一层仍然按页面域名生效，远程会话拿到的是「非特权」客户端形态（设置只读、不落盘）」。**网络**：「已核实。**文档此处漏了一道门**：`/api` 除 `isTrustedApiRequest` 外还要过 `browserAuth.isAuthenticated`（`rpc-host.ts:99`）……见 M6」（同向，两报告指出的漏项不同，见第 34 条） |
| G | §6.2 `:172`：「凭据落盘 \| `.dsh-config.json` 与相关文件以 `mode: 0o600` 写入（`dsh-bridge.mjs:151,167`、`e2ee-client.mjs:723`）」 | **网络**：「**部分成立**：行号引用准确，但 `writeFileSync` 的 `mode` **只对新建文件生效**，`dsh-bridge.mjs`/`dsh-setup.mjs` 均无 `chmod` 兜底」；另「文档把 `.dsh-config.json` 列为唯一「等同解密权」的文件，遗漏了这一份（`.harness-cookie.json`）」 |
| H | §6.4 第 1 条 `:192`：「**决定中继归属**：能自建就自建……用 SaaS 则务必**确认 E2EE 已真正开启**」 | **架构**：「**严重** …… 文档把两者写成「自建更好，用 SaaS 才需确认 E2EE」，把**互斥关系**读成了**递进关系**」。**网络**：「**不成立（自相矛盾）**……用户按第 1 条操作会得到「自建但永远无 E2EE」，却以为两者兼得」 |
| I | §5 第 3 步 `:150`：「电脑端生成**一次性扫码登录链接**（30 分钟有效、访问一次即失效、可取消配对）」 | **架构**：「**不完整 / 有误导。**「一次性扫码链接（30 分钟、一次性、可取消配对）」是 **SaaS / 企业端专属**能力；在文档自己推荐的「自建 relay」路径上，它是**不存在**的」 |
| J | §6.4 第 3 条 `:194`：「**一次性扫码链接**是其安全设计的一部分（30 分钟、一次性、可取消配对）——**用完即刷新**」 | **网络**：「**未核实**（企业端闭源）＋客户端行为与之矛盾 ……「用完即刷新」的动作不改变面板持续铸造的事实」；**架构**：「自建模式下无此物」。**网络**另在 §6.4 第 5 条（`:196`「定期在「已授权设备」里清理配对」）判「未核实（企业端闭源）」 |
| K | §6.4 第 4 条 `:195`：「**只在能看到 `dsh web` 的机器上装 bridge**；不要把 3080 暴露出去。」 | **网络**：「方向正确，但**不充分**——「不暴露 3080」挡不住 DNS rebinding 与 CSRF（H3）——围栏只保护 `/api`，插件路由 `/dsh-remote/*` 无任何来源校验」 |
| L | §8 第 4 条 `:229`：「**不执行 `npx @mrrisega/dsh-remote` 的自动安装**（会写配置 + 装开机自启）；先用前台方式（`run`）跑通。」 | **架构**：「**做不到** —— `apply()` → `ensureRuntime()` 必然触发」；**网络**：「文档 §8 只说「不执行 npx 一键安装」，没提插件自身会后台自动跑 npx，会误导按 §8 谨慎安装的读者」 |
| M | §2 表 `:76`：「`clients/dsh-web` \| — \| 客户端资源（`native.html`）」 | **架构**：「**不完整。**「客户端资源」这个说法掩盖了它是自建部署的**必需件**」 |
| N | §2 表 `:73`：「`packages/dsh-remote-ui` \| `dsh-remote-ui` \| 同上，注释写明是「旧名别名，同步自 dsh-remote-web」」 | **架构**：「entry id 陈述正确；但对「别名」的定性不完整 …… **这不是「别名」，是「同一份实现的字面拷贝」**…… 同时挂载两者 = 挂载两份功能完全相同的实现，且必然冲突」（TS 同向，见第 4、20 条） |
| O | §6.2 `:173`：「设备身份 \| 生成 ed25519 密钥对 + `dev-<12hex>` deviceId，持久化在 `.dsh-config.json`」 | **网络**：「已核实（格式与落盘）。**补注**：该密钥对**从不用于认证**（见 M6），只是随设备登记上报的数据」——属「表述易误导」而非事实错误 |
| P | R1 `:182`：「E2EE 保护的是**内容**，而**路由元数据（路径、大小、时间、是否加密）对中继可见**」 | **网络**：「已核实，但**低估**…… desktop-intro 路径下中继**能看到 MK 本身**（H1），此时 R1 的「内容不可见」前提不成立」。**架构**同向：作者注释自陈「**存在被中继主动冒充的理论窗口**」 |
| Q | R2 `:183`：「面板会显示当前状态，但你需要主动确认它是否真的启用了。」 | **网络**：「在电脑/平板上经远端打开镜像页时，明文/降级/失败**完全不可见**（M2）——而 §6.4 让用户「确认 E2EE 已真正开启（面板状态为准）」，这个面板恰恰在最容易发生降级的宽屏下不显示状态」 |
| R | §4.1 `:134`：「`isTrustedApiRequest` 全仓**只有一个调用点**（`rpc-host.ts:98`），传的是 `this.trustedHosts` 而非空数组。」 | **网络**：「一致，但**遗漏了紧邻的 :99 `browserAuth.isAuthenticated`（401）**」 |
| S | §6.2 `:175`「依赖面 \| 极小：仅 `ws`（bridge 与 relay）；插件包本身无额外运行时依赖」；§2 `:78`「依赖面很小：`ws`（bridge 与 relay 各一份）」 | **TS / 网络**：字段本身已核实，但「文档 §6.2 的「依赖面」「可复现」印象需打折：锁文件与版本不同步，`npm ci` 会取镜像站内容」（网络 L5；TS L1 同向）。**TS 另注**：「`exports` 字段并不缺失（我在核实前怀疑的方向被证伪，如实记录）」 |
| T | §5 注 `:155`：「v1.0.0 那条「首次必须手动做 DSH token 交换」的坑**在 v0.6.3 上是否仍存在，我没有验证**……**这一点建议实测确认。**」 | **架构**：「文档的「未验证」偏保守——不需要实测也能确定「手动 token 交换」这个具体动作已经没有了……但**它换来了一个新的、等价的失效模式**：只装插件时 `bridge_secret` 缺失会让面板显示「尚未登录」（`lib/index.js:905-930`）」 |
| U | §7 对比表 `:210`：「手机端体验 …… **浏览器直开，移动端专门适配**」 | **架构**：「SaaS 下成立，自建下需要你额外托管一个 2712 行的单文件 PWA」（见第 31 条） |
| V | §8 第 1 条 `:224`：「**作为 submodule 收进本仓**……pin `v0.6.3`」 | **TS（O8）**：遗漏了「CI 的插件清单是硬编码的，收 submodule 后必须同步修改，否则 pin 不被校验」（见第 33 条） |

**报告明确为文档『记功』的部分（无需修改）**：架构核实 §10 索引中 bridge 的行号（`:109 :125 :151 :167 :360 :718`、`e2ee-client.mjs:723`）与 harness 三处引用「逐个核对全部命中」「逐字属实」；TS 核实文档「版本更正说明」中关于 v1.0.0 的两条论断为真（v1.0.0 的 `bin/dsh-remote.js`(86) + `lib/{auth,config,proxy,server}.js`(135+122+229+426) = **998 行**，「不是 DSH 插件」也准确）；网络明确「本次未发现文档**过于悲观**的实质论断」。

---

## 仅涉及 v1.0.0（不阻塞 v0.6.3 决策）

**无。** 三份报告均未提出仅针对 v1.0.0（旧的独立反向代理）的问题。v1.0.0 只在两处作为证据出现，均已并入上表：

- 第 3 条：网络核实「v1.0.0 中 `execSync`/`child_process`/`eval(`/`new Function`/`require(` 全部 0 命中」，因此文档「只有一处」的说法对两个版本都不成立（**这一条是对文档不利的补充，不是 v1.0.0 自身的缺陷**）。
- 对文档断言的反驳表「记功」行：TS 核实文档对 v1.0.0 的两条论断（998 行、不是 DSH 插件）为真。

---

## 无具体锚点的顾虑

- **闭源企业端（`n.risegao.cn:13443` / `/relay-api`）不可及**（网络，明确列为「我无法核实的部分」）：`dsh_token` cookie 属性、JWT 签发参数与有效期、一次性链接是否真的「30 分钟 / 用一次即失效 / 可取消」、服务端限速与 jti 拉黑是否落地、`bridge_secret` 的校验方式、反馈接口是否上报未脱敏手机号、`/api/e2ee-params` 的权威性——**均未核实**。
- **SaaS 的实际 E2EE 开启状态与灰度策略**（网络）：需真实账号与真机验证，未核实。
- **官方 SaaS 定价（¥19–49/月）**（网络表 B R6）：具体价格未核实（不在代码内）。
- **`native.html` 在真实域名下的行为 / 官方前端断线与降级行为**（网络、架构）：静态壳未运行，无对应版本前端源码可比对。
- **端到端可利用性**（网络）：DNS rebinding 能否实际打到 `/dsh-remote/*`、CSRF 表单能否在目标浏览器完成——报告自标「推断」，未实测。
- **harness 载入期抛错的实际后果**（架构）：重复路由会 `throw` 已核实，但「宿主插件 apply 期抛错时是整体启动失败还是只标记该 fiber 失败」未运行验证（影响第 4 条的后果强度）。
- **本仓当前的实际插件挂载状态**（架构）：`scripts/link-plugins.sh:22` 默认 `PROFILE=dsh`，但本机 `~/.dsh/profiles/web/` 的 `cordis.patch.yml` 为 `[]`、`bundles` 仅 `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`；第 32 条是「基于源码存在」而非「基于已挂载」。

---

## 附：三份报告共同核实为真、无需行动的点（不计入问题数）

1. 文档 §10 索引与 harness 三处引用的行号逐个核对命中（架构、TS 均复核；唯二偏差：`startup.ts` 的 `program.error` 落在 `:75` 而文档写 `:74-76`；`dsh-bridge.mjs` 的 strip 注释文档写 `:239` 实际在 `:238`、`STRIP_REQ_HEADERS` 常量在 `:244`/`:243-247`——三份均判为「可接受的区间引用」）。
2. 全仓 `eval` / `new Function` **0 命中**（三份一致）。
3. `isTrustedApiRequest` 生产代码只有 `rpc-host.ts:98` 一个调用点；全仓无 `PRIVILEGED_METHODS`（架构、网络一致）。
4. relay 的 JWT 校验质量不错：仅 HS256、`alg` 校验、`timingSafeEqual`、`exp` 必填（`relay-router/src/jwt.mjs:15-38`），无 `alg:none` 或 HS/RS 混用路径（网络 I3）。
5. 上游响应头被剥 `content-encoding/content-length`（`dsh-bridge.mjs:255-260` 的 `STRIP_RES_HEADERS`），避免 undici 已解压却又声明 gzip 的错配；中继对 E2EE 帧确为透明转发（网络 I2、I4）。
