# dsh-remote 评估与远程访问方案

> **状态：仅评估，尚未安装。** 本文档评估 [mrRisega/dsh-remote](https://github.com/mrRisega/dsh-remote) 并给出远程访问本机 DSH 的方案对比。
> **评估版本：`v0.6.3`**（2026-09-12，commit `baa6d53`）；本仓 harness pin `dsh-v0.1.5-rc.2`。
> **本文档已经过三路独立评审并仲裁修订**，评审原文归档在 [docs/reviews/2026-09-12-dsh-remote/](reviews/2026-09-12-dsh-remote/)。正文中标注「评审」的条目出自该归档；标注「已实测」的条目是本仓亲自跑出来的。

> ## ⚠️ 先看这个：本仓已有现成方案
>
> 如果你的需求是「电脑放在家里、人在外面用手机访问它」，**先看 [docs/remote-access.md](remote-access.md)**——本仓已 pin、已挂载的 `@linxin666/dsh-remote-web-ui` 走 Cloudflare 隧道即可满足，**无需引入任何第三方组件、无需常驻进程、无需账号**。
>
> 本文档的价值在于：**如果你确实需要 dsh-remote 的「账号体系 + 手机 App 式界面 + 设备管理 + 固定域名」这套完整体验**，它告诉你要付出什么代价。两者的对比见 [remote-access.md §1](remote-access.md)。

## ⚠️ 版本更正说明（务必先读）

本文档最初按 **`v1.0.0`** 撰写，那是一个**不同且更旧**的产品线。核实后的时间线：

| tag | 提交日期 | 形态 |
|---|---|---|
| `v1.0.0` | **2026-08-20** | 旧的**独立反向代理**：扁平 `lib/`+`bin/`，零依赖，1,093 行，**不是 DSH 插件** |
| `v0.6.2` | 2026-09-11 | 当前线的稳定版（README 称 `latest`） |
| **`v0.6.3`** | **2026-09-12（今天）** | **当前线**：monorepo，**含 1 个 DSH 插件包**（`dsh-remote-web`；`dsh-remote-ui` 是它的生成别名，见 §2），21,946 行 |

**版本号看起来倒退，但日期与 CHANGELOG 都表明 0.6.x 是当前线**，`v1.0.0` 是更早的独立实现。

**因此基于 v1.0.0 的结论作废**，尤其是这一条：v1.0.0「没有 `cordis.patch.yml`、不是插件」——**对 v0.6.3 不成立**（见 §3）。

---

## 1. 结论（TL;DR）

1. **它是真正的 DSH 插件**（外加两个独立服务）。`packages/dsh-remote-web` 声明了 `dsh.bundle.patch` + `dsh.client.platform: web`（`dsh-remote-ui` 是它的**生成别名**，不是第二个插件，见 §2），且 `lib/` **已提交在仓库内**——注意 `lib/` **是手写源码，不是构建产物**（见 §6.2）。
2. **架构正好切中「电脑放家里、在外面用」**：电脑侧 bridge **只向外连**（`new WebSocket(中继地址)`，不监听任何端口）→ **家里无需公网 IP、无需端口映射**。这是它相对「端口转发/反代」的最大优势。
3. **但它引入了一个中继**：流量路径是 `手机 → 中继 → 你家的 bridge → dsh web`。默认中继是**作者的 SaaS**（`n.risegao.cn:13443`）；自建则需你自己在公网机器上跑 `relay-router`。
4. **安全上有四个必须知道的前提**：
   - **`/dsh-remote/*` 的 28 条路由对调用方没有任何鉴权**（已核实，见 §6.3 R0）——里面有 `self/uninstall`（彻底卸载）、`self/update`（在线更新）、`harness/restart`（重启宿主）、`start`/`stop`（控制 bridge）、`mobile-sessions/revoke` 等控制面，且**不检查 Origin/CSRF**。这是本项评估中**最高危**的一条。
   - **中继能看到路由元数据**；正文的端到端加密（E2EE）是**灰度功能且默认关闭**（README 原话：默认关闭 = 走 HTTPS 明文回退）。
   - **电脑端的 `.dsh-config.json`（0600）会保存你的账号密码用于自动登录**，README 自己说明这「等于该账号内容的解密权」。
   - 它**仍沿用「伪装 loopback」**访问本机 `dsh web`（重写 Host、剥离 Origin/Cookie 等），因此 **DSH 自身那层防护对远程用户不再起作用**。
5. **代码规模与审计边界**：全仓 **21,946 行**（非测试 14,570 / 15 个文件；测试 7,376 / 32 个文件），其中两个插件包的 `lib/` 是**同一份代码的两份副本**，去重后独特代码 ≈ **10,006 行**（远大于 v1.0.0 的 1,093 行）。本文档已由三路独立评审（agent 架构 / TypeScript 工程 / 网络安全）复核并仲裁，边界声明见 §6.1。
6. **许可证**：PolyForm-Noncommercial-1.0.0（个人非商业免费，商业需付费）；另有一个**付费 SaaS** 版本。

**建议（**已按评审重写**）**：
1. **先评估 [docs/remote-access.md](remote-access.md) 里本仓已有的方案**——它已 pin、已挂载、Apache-2.0、无常驻进程，且控制端点**实测仅限 loopback**。多数「在外面用自己的电脑」的需求到这一步就够了。
2. 若确认需要 v0.6.3 独有的整套（账号体系 + 固定域名 + 手机 App 式界面 + 设备管理）：它**优于**自行端口转发，但先做三件事——**正视 R0（装了无法关闭的零鉴权路由）**、决定**中继归属**（SaaS + 开 E2EE ／ 自建但明文，二选一）、并按 §6.3 加固。
3. 它的形态也确实**优于**把 3080 直接暴露出去（bridge 只外连、家里不开端口）——但**不等于**「比 Tailscale 更安全」。

---

## 2. 它是什么（v0.6.3 架构）

```
   手机浏览器
      │  HTTPS / WSS
      ▼
 ┌──────────────────────────┐
 │  中继 relay-router        │   公网可达的一台机器
 │  （@dsh-remote/router）    │   · 默认 = 作者的 SaaS：n.risegao.cn:13443
 │                           │   · 或你在自己公网机器上自建
 └────────────┬─────────────┘
              │  bridge 主动向外建立的 WebSocket 隧道
              │  （方向：家 → 公网；家里不开任何端口）
              ▼
 ┌──────────────────────────────────────┐
 │  你家的电脑                            │
 │  ┌────────────────────────────────┐  │
 │  │ bridge（@dsh-remote/client）    │  │  ← dsh-bridge.mjs，常驻，开机自启
 │  │   · 只外连，不监听                │  │
 │  │   · 重写 Host → 127.0.0.1:3080    │  │
 │  │   · 剥离 Origin/Cookie/Referer 等 │  │
 │  └───────────────┬────────────────┘  │
 │                  ▼                    │
 │  ┌────────────────────────────────┐  │
 │  │ DSH 进程（web 只监听 127.0.0.1）  │  │
 │  │  + 插件 dsh-remote-web           │  │  ← 设置页「远程访问」面板
 │  └────────────────────────────────┘  │
 └──────────────────────────────────────┘
```

**仓库内组件**（`v0.6.3`）：

| 路径 | 包名 | 性质 |
|---|---|---|
| `packages/dsh-remote-web` | `dsh-remote-web` | **DSH 插件（正式包）**：设置页「远程访问」面板 + 同源 `/dsh-remote/*` 路由；`lib/` 已提交，且**是手写源码**（见 §6.2） |
| `packages/dsh-remote-ui` | `dsh-remote-ui` | ⚠️ **不是第二个插件**，是上一行的**生成别名包**：由 `scripts/sync-legacy-alias.mjs` 从 `dsh-remote-web` 复制并替换 `PLUGIN_ID`/包名而来，供插件市场的**旧条目**继续可装（脚本注释：「新名条目合并通过后：删除 packages/dsh-remote-ui」） |
| `packages/relay-router` | `@dsh-remote/router` | **中继**：自建时部署在公网机器上 |
| `clients/dsh-remote` | `@dsh-remote/client` | **bridge**：电脑端守护进程（`dsh-bridge.mjs`）+ E2EE 实现 |
| `dsh-setup.mjs`（**仓库根，初版整份遗漏**） | — | **安装器 / 最有权力的组件**（791 行）：`npx @mrrisega/dsh-remote` 的入口，负责写配置、装开机自启、跑系统命令。初版文档**全文一次都没提到它**（`grep -c "dsh-setup" docs/dsh-remote.md` = 0），而它同时是 `execSync` 的调用方之一——**这是初版审计边界的实质性缺口**。 |
| `clients/dsh-web` | — | 客户端资源 `native.html`：**自建模式下必须自行托管的第三个部署件**（2,712 行单文件 PWA，内含移动适配与 E2EE shim），初版仅标为「客户端资源」 |

依赖面很小：`ws`（bridge 与 relay 各一份）。插件包的 `engines.dsh` 声明为 `>=0.1.0-rc.6 <0.2.0-0`。

> ⚠️ **初版写「本仓的 `0.1.5-rc.2` 在范围内」——已实测证伪，见 §6.2「宿主要求」行。**

---

## 3. 与之前 10 个插件的区别

| 维度 | 之前 10 个插件 | **dsh-remote v0.6.3** |
|---|---|---|
| 是否 cordis 插件 | 是 | **是**（两个包都有 `dsh.bundle.patch` + `client.platform: web`）——**但只是它的一部分** |
| 额外组件 | 无 | **还有 bridge（电脑端守护进程）与 relay（公网中继）**，这两者不是插件，不进 profile |
| 安装方式 | submodule + `make setup` 构建 + link 挂载 | 作者的官方方式是 **`npx @mrrisega/dsh-remote`**（一条命令装 bridge + 插件 + 配置 + **开机自启**）；源码安装需分别处理三部分 |
| 构建 | 视包而定（有的跳过） | 插件的 `lib/` **已提交、且它就是源码本身**（手写，非构建产物）→ 跳过构建；也因此**可以直接审计** |
| 网络暴露 | 只在本机 | **电脑侧零入站端口**；但流量经**中继**（默认是第三方 SaaS） |
| 配置 | 无或 profile patch | **必须**：中继地址 + 访问密钥（自建）或账号（SaaS）；`~/.dsh-remote/.dsh-config.json` |
| 许可证 | 全部 MIT | **PolyForm-Noncommercial-1.0.0** + 付费 SaaS |
| 运行时 | 无额外进程 | **bridge 常驻 + 开机自启**（launchd/systemd） |

**一句话**：它是「一个插件 + 两个服务」的组合，比之前的插件重得多；但也正因为 bridge 是**外连**的，它解决了「家里没有公网 IP / 不想开端口」这个痛点。

---

## 4. 为什么还要「伪装 loopback」——DSH 的网络约束（已核实）

```
① DSH 的 webserver 只接受两个字面量
   harness/packages/host/webserver/src/index.ts:126
     host: z.union([z.const('127.0.0.1'), z.const('0.0.0.0')]).required(),
   → 无法绑定某个具体内网 IP

② CLI 显式拒绝 0.0.0.0
   harness/packages/bundle/web-app/src/startup.ts:74-76
     program.error('--host 0.0.0.0 is intentionally not supported yet for safety:
       it would expose remote code execution to the network; use 127.0.0.1 instead')

③ /api 的浏览器信任围栏
   harness/packages/client/connection/src/api-request-trust.ts:91-118
     · Host 必须是 loopback 或 trustedHosts
     · Sec-Fetch-Site: cross-site → 拒
     · 有 Origin 时必须与 Host 同源；**「无 Origin」放行**
```

**净效果：DSH 实际只能监听 `127.0.0.1`**，任何远程访问都必须在前面接一层。bridge 的做法与 v1.0.0 同源：

```
clients/dsh-remote/dsh-bridge.mjs
  :239  转发时 Host 取上游 authority（127.0.0.1:3080）→ 通过 loopback 围栏
  :245  剥离 host / origin / referer / cookie / connection / upgrade 等
  :360  WebSocket 显式写入 out.Host = "127.0.0.1:3080"
```

> ⚠️ **同样提醒**：这意味着 DSH 自身的 Host/Origin 围栏对远程用户失效，安全性落在「中继 + bridge + 账号体系」上。

### 4.1 一处与作者文档不符（本版本）

作者**旧版 DESIGN.md**（v1.0.0 线）声称「特权方法在 trusted-host 部署下仍被钉死在 loopback」，引用 `PRIVILEGED_METHODS` + `isTrustedApiRequest(req, [])`。

**本仓 harness（0.1.5-rc.2）核实不到该机制**：全仓无 `PRIVILEGED_METHODS`；`isTrustedApiRequest` 全仓**只有一个调用点**（`harness/packages/client/connection/src/rpc-host.ts:98`），传的是 `this.trustedHosts` 而非空数组。

**含义（**已修正**，原推论过强）**：初版由此推出「`--trusted-host <你的域名>` 配合保留 Host 的普通反代**也能让全部方法通过**」——**这一步跳过了第二道闸门**。实测 `harness/packages/client/connection/src/rpc-host.ts:97-100`：

```ts
requestRejection(request) {
  if (!isTrustedApiRequest(request, this.trustedHosts)) return 403
  return this.browserAuth.isAuthenticated(request) ? undefined : 401
}
```

围栏之后**还有一道浏览器认证**（`browser-auth.ts:289-302`：要求携带由本机激活密钥签发、且**与请求 Host 权威绑定**的 cookie，无回环豁免）。所以通过 Host/Origin 围栏是**必要但不充分**的。

**结论修正**：方案 B 仍然可行，但要做**两件事**——`--trusted-host <你的域名>` **加上**走一遍一次性 `?token=` 交换、拿到绑定该域名的 cookie（即 §5 注里那条「DSH token 交换」）。**该推论仍未端到端实测。**

---

## 5. 首次配置的实际流程（v0.6.3）

官方路径（`npx @mrrisega/dsh-remote`）：

```
1. 电脑端执行 npx @mrrisega/dsh-remote
   → 安装 bridge + dsh web 插件、写配置、创建开机自启服务
2. dsh web → 设置 →「远程访问」
   → SaaS 模式：手机端注册/登录手机号（电脑端扫码/登录）
   → 自建模式：npx @mrrisega/dsh-remote setup --server wss://<你的域名>:端口 --key <访问密钥>
3. 手机打开远程地址；电脑端生成**一次性扫码登录链接**（30 分钟有效、访问一次即失效、可取消配对）
   ⚠️ 评审指出这一步是 **SaaS 专属**（自建 relay 上没有这套；见 §6.5）——**本仓未复核**。
```

**与 v1.0.0 的流程完全不同**：v1.0.0 是「网关口令 + 手动做 DSH token 交换」；v0.6.3 是**账号体系（云）或访问密钥（自建）+ 一次性扫码链接**，且插件面板里内置了版本更新与彻底卸载入口。

> 注（**已修正**）：初版说 v1.0.0 那条「首次必须手动做 DSH token 交换」的坑**未验证是否仍存在**。现在可以说清它的去向：**坑没有了，但换成了等价物**——DSH 的 `?token=` 一次性交换仍然存在（§4.1），只是**由插件与 bridge 代持**：插件侧 `scheduleHarnessMint` 去换 harness 的浏览器会话 cookie 并落盘（评审指出落在**第二份凭据文件 `.harness-cookie.json`**，`dsh-bridge.mjs:175-181`——**未复核**），bridge 再带着它访问本机 `dsh web`。所以「手机点设备不再 401 白页」是靠代持实现的，**代价是多了一份落盘凭据**。

---

## 6. 安全评估

### 6.1 边界声明（重要）

- 我**通读了** v1.0.0（1,093 行）并逐项核对了它的安全声明；**v0.6.3 共 21,946 行**（非测试 14,570 / 测试 7,376；构成见 §1 第 5 条），初版本文档**只做了定向扫描，没有做完整审计**。
- **初版的多条「已核实」断言经三路独立评审后发现有误**（`execSync` 计数、`lib/` 的性质、行数、§6.4 的自相矛盾），已在本版逐条修正；评审原文与仲裁记录见 [docs/reviews/2026-09-12-dsh-remote/](reviews/2026-09-12-dsh-remote/)。**本节的「已核实」现在指本仓亲自复核过**（重跑命令 / 重读源码），不再是照抄原分析。
- 下表区分「已核实」与「未核实」，请勿把后者当作保证。

### 6.2 已核实项

| 项 | 结论 |
|---|---|
| 危险原语（**已修正**） | **`execSync` 共 6 处、分布在 4 个文件**（初版称「只有一处」，是错的）：<br>① `dsh-bridge.mjs:125` — `ioreg -rd1 -c IOPlatformExpertDevice`（macOS 读硬件 UUID 作设备身份）<br>② `dsh-setup.mjs:104` — 通用命令执行器（安装器）<br>③④ `dsh-remote-web/lib/index.js:37`、`:695` — 前者是通用 `sh(cmd)` helper（`launchctl`/`systemctl`/`pgrep` 等系统服务管理），后者是**卸载流程**里 `execSync("sleep 1")` 等被杀进程退出再 SIGKILL<br>⑤⑥ `dsh-remote-ui/lib/index.js:37`、`:695` — ③④ 的别名副本<br>（去掉别名副本后为 **3 个逻辑文件 5 处**。）全部**无 `eval` / `new Function`**（已核实）。 |
| 默认中继地址 | 硬编码指向作者 SaaS：`n.risegao.cn`、`n.risegao.cn:13443/app/`、`n.risegao.cn:13443/relay-api` |
| 凭据落盘 | `.dsh-config.json` 与相关文件以 `mode: 0o600` 写入（`dsh-bridge.mjs:151,167`、`e2ee-client.mjs:723`）；`.gitignore` 已排除 `.dsh-config.json` |
| 设备身份 | 生成 ed25519 密钥对 + `dev-<12hex>` deviceId，持久化在 `.dsh-config.json` |
| 插件产物（**已修正**） | 插件包的 `lib/index.js`、`lib/client.js` **已提交**——且它们是**手写源码本身**（见 R7），不是构建产物，因此**无需构建**即可挂载，**也**可以直接审计 |
| 依赖面 | 极小：仅 `ws`（bridge 与 relay）；插件包本身无额外运行时依赖 |
| 宿主要求（**已修正**） | `engines.dsh: ">=0.1.0-rc.6 <0.2.0-0"`。初版称「本仓 `0.1.5-rc.2` 满足」——**是错的**。实测三条消费路径：<br>① **裸 semver**：`semver.satisfies("0.1.5-rc.2", ">=0.1.0-rc.6 <0.2.0-0")` → **`false`**（该范围里唯一的预发布比较子是 `0.1.0-rc.6`，与本版的 `0.1.5` 不同 patch，按 semver 规则预发布版本不匹配；`0.1.5`（正式版）才是 `true`）。<br>② **dsh-web plugin-manager**：`meetsMinimumDsh` 的 `MINIMUM_RANGE_PATTERN` 只接受**单个** `>=X.Y.Z[-pre]`，本插件的**多比较子范围形状不支持** → 返回 `undefined` → 按该模块注释「callers treat undefined as can't-verify and **fail closed**」→ **拒绝**。<br>③ **harness 本身**：**完全不读 `engines.dsh`**（全仓 grep 零命中）→ 走 submodule 挂载**不会被拦**。<br>**净效果**：这个字段只在 dsh-web 的**市场/plugin-manager 安装路径**上有约束力；本仓若按 submodule 收编，它不构成阻塞，但**别把它当成「版本兼容」的证据**。 |

### 6.3 风险清单

| # | 风险 | 说明 |
|---|---|---|
| **R0** | 🔴 **插件路由对调用方零鉴权（本项最高危，已核实）** | `packages/dsh-remote-web/lib/index.js:1729-2150` 注册了 **28 条 `/dsh-remote/*` 路由**，其分发逻辑（`:2129-2150`）**只做 path/method 匹配**——没有 cookie 校验、没有 Origin/CSRF 校验、没有身份判断。其中包含 `self/uninstall`（彻底卸载：清 profile 插件 + 停自启 + 删 plist/unit + 杀进程 + 清空 `~/.dsh-remote`）、`self/update`（后台 `npx` 在线更新）、`harness/restart`（重启宿主）、`start`/`stop`（控制 bridge）、`config`（读写 `.dsh-config.json`）、`login`/`register`/`password/reset`（账号绑定）、`mobile-sessions/revoke|delete|purge`（设备管理）。<br>**绕过了 harness 的围栏**：harness 的 `/api` 浏览器信任围栏只作用于 `/api`（`rpc-host.ts:98` 是 `isTrustedApiRequest` 全仓唯一调用点），而这些路由挂在 `webServer` 上、**不经过该围栏**。<br>**后果**：本机任意进程可调用；更麻烦的是**用户访问的任意网页都能发跨站请求**（POST 且不校验 Origin），可铸出一次性登录链接、改写账号绑定、甚至触发彻底卸载。 |
| **R1** | **中继是新的信任方** | 默认中继是**第三方 SaaS**。README 明确：E2EE 保护的是**内容**，而**路由元数据（路径、大小、时间、是否加密）对中继可见**。 |
| **R2** | **E2EE 默认关闭（灰度）** | README 原话：「默认关闭 = 走 HTTPS 明文回退」。**未开启时，内容在中继处可被读取**。面板会显示当前状态，但你需要主动确认它是否真的启用了。 |
| **R3** | **电脑端保存账号密码** | `.dsh-config.json`（0600）保存账号密码用于自动登录；README 自陈这「等于该账号内容的解密权」。**电脑被他人使用时等于内容可被解密**（README 建议此时退出登录）。 |
| **R4** | **仍绕过 DSH 自身防护（**已修正**，原表述过强）** | 与 v1.0.0 同样的 loopback 伪装（§4）。初版说「DSH 的围栏对远程用户**失效**」——**过强**：围栏之外还有 `browserAuth` 那道 401（见 §4.1 修正）。准确说法是：**Host/Origin 围栏被绕过，但浏览器认证 cookie 那道门仍在**；bridge 正是靠代持该 cookie（`scheduleHarnessMint`）才让手机不白页。 |
| **R5** | **常驻 + 开机自启** | bridge 以 launchd/systemd 常驻并自启（v0.6.2 的 CHANGELOG 专门修过「崩溃循环 / 自愈停摆」问题）。 |
| **R6** | **许可证 + 付费线** | 代码为 PolyForm Noncommercial；官方 SaaS 为付费商业服务（**价格「¥19–49/月」出自 README，本仓未核实**）。个人非商业自用不受限。 |
| **R7** | **审计深度不足（已修正）** | 21,946 行，初版只做了定向扫描；现已补三路独立评审。插件包 `lib/` **不是预构建产物、就是源码本身**（`scripts: {}`、无打包器配置、`files` 直接发布 `lib`、文件头为带日期的手写变更注释），因此**可以直接审计**——初版称「无法核对源码与产物一致性」的理由不成立。真正缺的是**未做端到端实测**。 |

### 6.4 加固清单

1. **决定中继归属——但要知道这是个二选一，不是「既要又要」（已修正）**：
   - 初版在这里自相矛盾（同时建议「自建中继」和「确认 E2EE 已开启」）。**二者不可兼得**：`dsh-bridge.mjs:1016` 有 `const localMode = Boolean(process.env.DSH_BRIDGE_LOCAL_KEY); // 自建模式不启用(§6.6)`，`:1018` `const allowed = !localMode && !userDisabled;` → **一旦走自建中继，E2EE 就被硬禁用**（`e2ee-client.mjs:567` 返回 `reason: "disabled_by_config"`；插件面板对该 reason 的中文标签正是「当前为普通安全连接（HTTPS）」）。
   - 所以真实选项是：**(a) 用 SaaS + 开启 E2EE** → 内容加密，但中继仍是信任方、元数据可见，且 E2EE 是灰度功能；**(b) 自建中继** → 路径上无第三方，但**中继处是明文**（你自己的机器能看到全部内容）。
   - 自建只有在「你更信任自己的公网机器 + 传输链路，且不接受元数据外泄」时才更优。**别再假设自建还能顺带保住 E2EE。**
2. **正视 R0（插件路由零鉴权）**：这是**装了就存在**的问题，没有配置项能关掉。可行的缓解只有两条：**（a）不装**——改用 [docs/remote-access.md](remote-access.md) 里本仓已有的方案（其控制端点已实测仅限 loopback）；**（b）装了就别在浏览器里乱逛**，并意识到「本机任意进程」也能调这些接口。若最后仍要装，至少**不要让它和「会被别人用的账号」放在同一台机器上**。
3. **保护电脑端的 `.dsh-config.json`**：它等同于账号解密权；`0600` 之外，考虑是否真的需要「自动登录」。
4. **一次性扫码链接**（30 分钟、一次性、可取消配对）是其安全设计的一部分——但**两点修正（评审指出，本仓未复核）**：① 它是 **SaaS 专属能力**，自建 relay 上不存在；② 面板停留时**每 25 秒自动铸一把新的**，所以「用完即刷新」既不必要、也不收敛暴露面（暴露面由 R0 决定，不由刷新频率决定）。
5. **只在能看到 `dsh web` 的机器上装 bridge**；不要把 3080 暴露出去。
6. **定期在「已授权设备」里清理配对**；改密会使旧会话失效（README 说明）。
7. 若在意第三方中继：优先评估 §7 的方案 A/B。

### 6.5 评审发现、**本仓未复核**的高危项

> 以下条目出自三路评审，**本仓只做了整理、没有亲自复核**（未重跑命令、未读源码）。列在这里是因为它们**若成立会改变决策**，且都带 `file:line` 可供日后查证。完整清单（42 条）与逐条证据见 [评审归档 CONSOLIDATED.md](reviews/2026-09-12-dsh-remote/CONSOLIDATED.md)。

| 评审项 | 评审结论（未复核） | 证据（评审给出） |
| --- | --- | --- |
| **E2EE 在引导路径上被明文下发** | desktop-intro 引导路径会把派生的主密钥（MK）**以明文经中继**下发——「中继看不到内容」在该路径上不成立 | `dsh-bridge.mjs:497-500,563,571-578`；`e2ee-client.mjs:603-608` |
| **无前向保密** | 一次 MK 泄露可解密该账号的**全部历史**流量 | `e2ee-client.mjs:199-215,662-663`；`docs/e2ee-protocol.md:474` |
| **设备隧道可被顶替** | 隧道注册无归属校验；**自建模式下等于没有多租户隔离** | `packages/relay-router/src/index.mjs:703-741,725-732` |
| **插件半实为「系统管理 agent」** | 不止于面板：能自装、**改写 profile、重启宿主进程**、`rm -rf` 式清理——初版把它描述得过窄 | `lib/index.js:1674-1712,849-893,1940,428-455` |
| **E2EE 静默降级 + 宽屏不告警** | 明文回退不报警；且**宽屏（>820px）下不显示任何告警徽标**——降级恰恰在最容易发生的场景下不可见 | `e2ee-shim-script.js:402,410-420,439,502`；`:644-648` |
| **认证前的资源耗尽面** | 分块信封重组缓冲**无上界**，relay 单帧上限 256 MB | `relay-router/src/index.mjs:172,231-259,699`；`dsh-bridge.mjs:304-326,980` |
| **第二份凭据未文档化** | `.harness-cookie.json` 是第二份落盘凭据，初版完全没提 | `dsh-bridge.mjs:175-181,361-362,442-443` |
| **桥端 SSRF** | HTTP 转发默认**跟随重定向** → 可从电脑所在网络位置发起 SSRF（评审称无凭据外泄） | `dsh-bridge.mjs:449,387`（对照 `:718,956`） |
| **ed25519 不参与认证** | 设备密钥对是「身份装饰」而非凭证 | `dsh-bridge.mjs:207-218,915,966` |

**另有一条涉及它与本仓契约是否对齐**：评审称插件 `dsh.client.inject` 声明的某个包在 harness 中并不存在（`packages/dsh-remote-{web,ui}/package.json` 的 `inject` 列表 vs `harness/packages/client/modules/src/client/system.ts:165-168`）——若属实，挂载后客户端注入会解析失败。**未复核。**

---

## 7. 远程访问方案对比（针对「电脑在家、人在外面」）

| | **0. 本仓已有的 remote-web-ui** | **A. VPN / 隧道（Tailscale、WireGuard、SSH 反向隧道）** | **B. 裸反代 + `--trusted-host`** | **C. dsh-remote v0.6.3** |
|---|---|---|---|---|
| 安装状态 | **已 pin、已挂载，开箱可用** | 需装 VPN 客户端 | 需自建反代 | 需引 submodule + bridge + relay |
| 家里开端口 | **否**（Cloudflare 隧道出站） | **否** | 否（反代在公网机器上） | **否**（bridge 只外连） |
| 需要公网机器 / 账号 | **否** | 否（Tailscale 等）/ 是（SSH 隧道需跳板） | **是**（Nginx 入口） | 自建则**是**；用 SaaS 则否 |
| 是否有第三方经手流量 | Cloudflare 隧道；固定域名中继**可关** | 否（或你的 Tailscale 账号） | 否 | **是**（SaaS 中继；自建可避免） |
| 控制端点鉴权 | **仅限 loopback（已实测）** | 由 VPN 提供 | 无，需自行加 | 🔴 **无鉴权（已核实，见 R0）** |
| 常驻进程 / 自启 | **无** | VPN 守护进程 | 无 | 有（bridge + 开机自启） |
| DSH 改动 | **零** | **零** | 加 `--trusted-host` | 零（它绕过围栏） |
| 自带账号/口令体系 | 一次性二维码配对 + 设备管理 | 由 VPN 提供 | 无，需自行加 | **有**（账号 + 一次性扫码 + 设备管理 + PWA 手机界面） |
| 手机端体验 | 浏览器直开，**竖屏移动适配层** | 需装 VPN 客户端 | 浏览器直开 | **浏览器直开，移动端专门适配** |
| 许可证 | **Apache-2.0** | 无 | 无 | **非商业** |

**建议**：
- **先评估方案 0。** 只要需求是「在外面用自己的电脑」，本仓已有的 `@linxin666/dsh-remote-web-ui` 已经够了，且**许可证干净、无常驻进程、控制端点已实测仅限 loopback**——详见 [docs/remote-access.md](remote-access.md)（含实测记录与配置流程）。
- 方案 0 不够、但你能接受装 VPN 客户端 → **方案 A** 最省心、零第三方。
- 已有 Nginx + 域名、能自行加认证 → 方案 B 最少侵入（依赖 §4.1 的推论，建议先实测）。
- **只有在明确需要 v0.6.3 独有的一套**（账号体系 + 固定域名 + 手机 App 式界面 + 跨重启书签）时才选 C；此时按 §6.4 的二选一决定中继归属，并**正视 R0 无鉴权路由**。

---

## 8. 若决定安装：建议的落地方式（待确认）

v0.6.3 是「插件 + 服务」的混合体，**不能照搬既有插件流程**，也不能直接套用它的 `npx` 一键安装（那会写配置并装开机自启）。建议：

1. **作为 submodule 收进本仓**：`https://github.com/mrRisega/dsh-remote.git`，pin `v0.6.3`；
   - 插件包的 `lib/` 已提交**且就是源码本身** → 挂载时**跳过构建**；
   - `packages/dsh-remote-web` 是 **workspace 子包**（不是仓库根包），需按 `plugins/*/packages/*` 的子包候选处理。
2. 🔴 **只能挂 `dsh-remote-web` 一个，必须显式排除 `dsh-remote-ui`——否则启动即失败（已核实，不是「可能重复」）**：
   - `dsh-remote-ui` 是前者的**生成别名包**（`scripts/sync-legacy-alias.mjs`），id 不同、**却注册同一套 `/dsh-remote/*` 路由与同一个设置面板、共用一个 bridge**。
   - 本仓 `scripts/link-plugins.sh:62,65,89` 的候选口径正是「根包 + **`packages/*/` 子包**中声明了 `dsh.bundle.patch` 的包」，而**两个包都声明了** → **两个都会被捞出来挂上**。
   - `harness/packages/host/webserver/src/index.ts:165-170`：`register()` 对重复的 `(kind, path)` **直接 `throw new Error('webserver: duplicate ... route ...')`**（注释：「route patterns are a composition-level contract, so a collision is a misconfiguration」）。
   - 净效果：**重复注册 `/dsh-remote/*` 会在启动期抛错**，不是「面板出现两次」这么温和。处置方式与本仓在 dsh-better-sidebar 上踩过的同类问题一致——像 `patches/disable-web-ui-better-sidebar.yml` 那样显式禁掉一个。
3. **必须显式设 `DSH_RELAY_DIR`（已核实的安装陷阱）**：两半的默认配置目录**不一致**——
   - `dsh-setup.mjs:34-36`：`IS_NPM_INSTALL ? ~/.dsh-remote : THIS_DIR` → **仓库/submodule 形态下默认用 checkout 自己**，即 `.dsh-config.json`（0600，含账号密码或访问密钥）会**落进被 pin 的 submodule 工作区**；
   - `packages/dsh-remote-web/lib/index.js:27`：插件侧默认 `~/.dsh-remote`。
   - 后果：不设环境变量时，**安装器把凭据写进 submodule，插件却去 `~/.dsh-remote` 找 → 找不到 → 面板静默显示「尚未登录」**。源码安装务必两个进程都设同一个 `DSH_RELAY_DIR`（并把它加进 `.gitignore` 保险）。
4. **插件半**（`dsh-remote-web`）可按既有方式 link 进 profile —— 但**先确认它与 `clients/dsh-remote`（bridge）的配合方式**：它默认读 `~/.dsh-remote/.dsh-config.json`，那是 `npx` 安装器写的；源码安装需要手工准备该配置（配合上一条的 `DSH_RELAY_DIR`）。
5. 🔴 **注意「挂载即触发自装」——「不执行 npx 自动安装」这个目标做不到**：`apply()` 末尾会调 `scheduleRuntime(relayDir)` 与 `ensureRuntime(relayDir)`（`lib/index.js` 中「运行时自愈」「market 安装路径的第一步」两段注释明确写着「**插件加载即后台补装桌面运行环境（bridge + 自启动）**」），**不等用户登录**。评审进一步指出它后台跑的是 `npx --yes @mrrisega/dsh-remote@latest`（**评审声称，本仓未复核**）。所以源码挂载同样会触发自装——**必须在流程里预先决定是否接受，而不是假设「我不跑 npx 就不会装」**。
6. **bridge 与 relay 独立部署**：不进 profile、不走 profile 流程；relay 部署到你的公网机器，bridge 在电脑上跑。
7. **同步修改 CI 的插件清单**：本仓 `.github/workflows/verify.yaml` / `release.yaml` 里的插件清单是**硬编码**的（评审指出 `verify.yaml:39`；**未复核**），收 submodule 后不同步改，pin 不会被校验。
8. **动手前先做的小验证**（成本低、决定路线）：
   - §7 方案 B 是否成立（决定要不要引入第三方中继）——注意现在已知它需要**围栏 + 浏览器 cookie 两道**（§4.1）；
   - **评估 R0 的可接受性**——这是唯一一条「装了就无法关闭」的风险；
   - ~~自建 relay 下 E2EE 能否开启~~ —— **已有答案，不必再试**：自建模式**硬禁用 E2EE**（§6.4 第 1 条）；
   - ~~源码安装下面板能否读到配置~~ —— **机制已查明**：是 `DSH_RELAY_DIR` 不一致导致的（上面第 3 条），设对即可，不必试探。

---

## 9. 许可证

| 场景 | 许可 | 费用 |
|---|---|---|
| 个人学习 / 研究 / 非商业 | PolyForm-Noncommercial-1.0.0 | 免费（须保留 `Required Notice` 署名） |
| 个人修改、二次开发 | 同上 | 免费（须署名） |
| 商业用途（含公司生产环境、商业产品集成、SaaS） | 商业授权 | **付费** |
| 使用官方云服务版 | 商业服务 | 免费额度 + ¥19/月起 |

**已修正**：初版这里写「本仓其余插件均为 MIT」，**是错的**。实测各插件声明的许可证：

| 插件 | 许可证 |
| --- | --- |
| dsh-plugin-mineru | **AGPL-3.0** |
| dsh-web | **Apache-2.0**（另含 BSD-3-Clause 组件） |
| dsh-agent-teams / dsh-at-file / dsh-automation / dsh-better-sidebar / dsh-market / modlens / modsearch | MIT |

所以本仓**本来就是混合许可**，引入 PolyForm-Noncommercial 并不构成「从 MIT 变成非 MIT」的突变。真正需要注意的是：**PolyForm-Noncommercial 比 AGPL-3.0 更严**（后者仍是 OSI 认可的开源许可，前者不是），且它禁止商业用途——**若涉及工作机器请先确认**。

---

## 10. 代码出处索引（便于复核）

| 论断 | 出处 |
|---|---|
| DSH 只能绑两个字面量 | `harness/packages/host/webserver/src/index.ts:126` |
| `--host 0.0.0.0` 被拒及理由 | `harness/packages/bundle/web-app/src/startup.ts:74-76` |
| 信任围栏三道门 | `harness/packages/client/connection/src/api-request-trust.ts:91-118` |
| 围栏唯一调用点（传 `trustedHosts`） | `harness/packages/client/connection/src/rpc-host.ts:98` |
| **围栏之后的第二道门**（浏览器认证 401，权威绑定 cookie） | `harness/packages/client/connection/src/rpc-host.ts:99` → `browser-auth.ts:289-302` |
| **submodule 挂载不会被 `engines.dsh` 拦**（harness 不读该字段） | harness 全仓 grep `engines.dsh` 零命中；对照 `plugins/dsh-web/packages/dsh-plugin-manager/src/core/version.ts:90,99-108` |
| **两插件包同挂会启动即抛错** | `scripts/link-plugins.sh:62,65,89` + `harness/packages/host/webserver/src/index.ts:165-170`（`register()` 对重复 `(kind,path)` throw） |
| **两半默认配置目录不一致** | `dsh-setup.mjs:34-36`（checkout 形态 = `THIS_DIR`）vs `packages/dsh-remote-web/lib/index.js:27`（`~/.dsh-remote`） |
| bridge 只外连（WebSocket 客户端） | `clients/dsh-remote/dsh-bridge.mjs:718,956` |
| bridge 伪装 loopback / 剥离头 | `clients/dsh-remote/dsh-bridge.mjs:239,245,360` |
| 上游默认地址 | `clients/dsh-remote/dsh-bridge.mjs:109` |
| `execSync` 6 处（4 个文件） | `clients/dsh-remote/dsh-bridge.mjs:125`、`dsh-setup.mjs:104`、`packages/dsh-remote-web/lib/index.js:37,695`、`packages/dsh-remote-ui/lib/index.js:37,695` |
| 配置落盘 0600 | `clients/dsh-remote/dsh-bridge.mjs:151,167`、`e2ee-client.mjs:723` |
| 插件包清单（bundle patch / client platform / engines.dsh） | `packages/dsh-remote-web/package.json` |
| 插件条目 id | `packages/dsh-remote-web/cordis.patch.yml`（`dsh-remote-web`）、`packages/dsh-remote-ui/cordis.patch.yml`（`dsh-remote-ui`，生成别名） |
| **28 条 `/dsh-remote/*` 路由表** | `packages/dsh-remote-web/lib/index.js:1729`（数组起点） |
| **路由分发仅做 path/method 匹配、无鉴权**（R0） | `packages/dsh-remote-web/lib/index.js:2129-2150` |
| **别名包生成脚本**（`dsh-remote-ui` 的来源） | `scripts/sync-legacy-alias.mjs`（首部注释说明用途与删除时机） |
| **自建模式硬禁用 E2EE** | `clients/dsh-remote/dsh-bridge.mjs:1016,1018` → `clients/dsh-remote/e2ee-client.mjs:567`（`reason: "disabled_by_config"`）；面板文案 `packages/dsh-remote-web/lib/client.js:1111` |
| **挂载即后台自装运行环境** | `packages/dsh-remote-web/lib/index.js`（`apply()` 内 `scheduleRuntime` / `ensureRuntime` 两段，含「插件加载即后台补装桌面运行环境」注释） |
| **`lib/` 是手写源码而非构建产物** | `packages/dsh-remote-web/package.json`（`scripts: {}`、`files` 含 `lib`）；`lib/index.js` 首部日期化变更注释 |
| 默认中继（作者 SaaS） | `n.risegao.cn` / `n.risegao.cn:13443/relay-api`（全仓 grep） |
| 两个版本的定位与安全说明 | `README.md` §「两个版本」「安全与隐私」 |
| E2EE 协议 | `docs/e2ee-protocol.md` |
| 三路评审原文与仲裁记录 | [docs/reviews/2026-09-12-dsh-remote/](reviews/2026-09-12-dsh-remote/) |
