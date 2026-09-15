# 遗留问题

> 尚未收口的事项。**完成即删除对应条目**——本文档只记录"还没做/还没查清"的事，不记历史。
> 每条都写了「下一步」，方便下次直接接手。
>
> 整改项的**全集与证据**（含已完成项）在 [remediation-plan.md](remediation-plan.md)；
> 本文档只回答「还欠什么」，那份回答「做过什么」。

最后更新：2026-09-15

---

## 一、远程访问（详见 [remote-access.md](remote-access.md)）

| # | 问题 | 现状 | 下一步 |
| --- | --- | --- | --- |
| R1 | **隧道间歇性连不上，原因未查明** | 三种归因（GFW / Clash TUN / Clash `mode`）**均被实测证伪**；能连上的样本覆盖了 Clash 的各种状态 | 再复现时用 `VERBOSE=1 TUNNEL_TRANSPORT_LOGLEVEL=debug make dev` 抓实时报错；查 Clash 状态走 mihomo API（`127.0.0.1:9097`）读**运行时**值，**别读配置文件**（那是过期的） |
| R2 | **#11 固定域名中继未再尝试** | 打开它可让手机不必每次重启重配对；上次试时被 Cloudflare 挑战挡下（`cf-mitigated: challenge`），但当时网络状态与现在不同 | 在面板点开 #11，看日志里 `relay registration failed (HTTP 403)` 是否仍出现 |
| R3 | **局域网模式那条路从未实测** | 全程走的隧道；`lanAvailable` 一直为 `false`，webserver 只绑 `127.0.0.1` | 开 #12 → **`make dev` 跑两次**（已知的合并冲突）→ 手机走 `http://<内网IP>:3080`。这是排查 UI 问题时最干净的路径（无隧道/无代理/无扫描器） |
| R4 | **插件改写白名单不完整** | boot 脚本只改写部分路径：`/remote/sidebar/ws/agent-terminals` 被正确改写，但 `/sidebar/ws/agent-opens`（→ EOF）与 `/plugins/<pkg>/state`（→ 403）**没被覆盖** | 要么向作者报，要么确认这些调用是否本就该走别处 |
| R5 | **两条值得报上游的插件缺陷** | ① relay 开启时**无条件**改写 Host（应挂在"注册成功"而非"relay 开关"上），导致注册失败时整条隧道被自己的栅栏 403；② `--protocol http2` **写死**，而 QUIC 在部分网络下才是通的那条 | 整理成 issue（英文）发给插件作者 |
| R6 | **隧道地址每次重启都变** | quick tunnel 固有；手机每次要重新配对 | 依赖 R2 解决 |

## 二、仓库整体

| # | 问题 | 现状 | 下一步 |
| --- | --- | --- | --- |
| B1 | **`plugins/dsh-web` pin 落后上游 191 个提交** | 实测（2026-09-13）：`pin vs origin/main` = behind 191 | 动 CI / 发版前先与上游同步，并跑一遍完整回归 |
| B3 | **`make deploy` 从未实际执行过** | 脚本与 systemd unit 已写好，但部署路径**一次都没跑通** | 找一台 Linux x86-64 实跑一遍（注意：原生依赖必须在该平台各自构建） |
| B4 | **新装插件的 UI 验收未做** | modsearch（搜索 + fetch）、dsh-at-file、dsh-agent-teams、dsh-market、modlens 等挂上了但未逐个走查 | 在 `make dev` 里逐个过主要交互 |
| B6 | **dsh-TUI 的 macOS 路径长度缺陷应报上游** | 其 `scripts/verify-inject-channel.mjs` 用 `os.tmpdir()`，macOS 下 unix socket 路径达 105 字节 > `sun_path` 上限 104 → `listen EINVAL`。本仓已用 `TMPDIR=/tmp` 绕行 | 报给 ccch1mneyyy/dsh-TUI（建议短路径或建 socket 前检查长度） |
| B7 | **本仓 CI 不跑任何 submodule 测试** | 实测：harness 962 个测试文件、9 个插件合计 700+，而 CI 里一个都没跑（只有 pin / shellcheck / 构建 / 冒烟） | 按 [CI/CD 测试策略](cicd/04-test-strategy.md) 与[迁移阶段](cicd/01-architecture.md#12-迁移与验收阶段)落地版本化测试 catalog、根仓测试入口和发布回归 |
| B10 | **`mount-logger-console` 挂的 vendor 包按裸名注册，任何用 `createRequire` 遍历 entry 的 harness 组件都会再撞** | 已撞到一个：`plugin-package-inventory-deepseek` 的 `barePackageManifest` 解析不到 `@deepseek-ai/cordis-plugin-logger-console` → throw → **每个 DeepSeek 请求都失败**，且错误**不进任何日志**（2026-09-15 实测，靠 loongsuite 插件的 OTLP span 才发现）。已用 [patches/disable-plugin-package-inventory.yml](../patches/disable-plugin-package-inventory.yml) 禁用该插件消除故障。**但只知道这一个 consumer**，没有系统性排查手段——见 [plugin-dev.md](plugin-dev.md) 常见问题同名条目 | 二选一：① 把该 entry 改成**路径形式**挂载（`barePackageName` 对含 `/` 的返回 `undefined` → 走 `nearestManifest`、**不抛**）；障碍是绝对路径不可移植（本地 macOS 与服务器 Linux 共用同一份 patch），需先验 loader 接受哪种写法。② 上报 harness，请其让 `barePackageManifest` 走 loader 的解析根。⚠️ **出现「与插件无关的功能莫名失败」时先怀疑这条**：`dsh --dump-config` 看该 entry 有没有被牵进去 |

---

| B11 | **两个调用方各持一份逐字节相同的「动作原语」（11 个函数）** | `scripts/setup.sh` 与 `deploy/remote-install.sh` 里从 `plugin_install` 起的动作原语段**逐字节相同**（含带分支的 35 行 `plugin_install`），**没有任何门禁保证它们同步**。`prepare-executor.sh` 只统一了**决策**（`case "$prepareMode"` 全仓仅一份），**动作**仍是两份。**成本已经发生过一次**：`ret=$?` 的 fail-open 必须修两次才对齐（`a4a3808` + `a25af8b`） | 把动作原语也收进共用实现，让两处只剩**真正的**环境差异（install 策略 `frozen`/`nonfrozen`、harness 的 `CI=true`）。⚠️ 这是**接口变更**，该单独走 ADR 级思考，不要在收尾阶段顺手动。当前只在两处各留了互相指向的注释作**提醒**（不是装置，挡不住漂移） |

## 暂缓（**有意不做，非遗漏**）

> 与「已收口」的区别：这些**没做完**，是按决策**不做**。列在这里是为了让后来者知道
> 它是被权衡掉的，而不是没人想到——同时保留「什么条件下该重启它」。

| 事项 | 为什么暂缓 | 重启条件 |
| --- | --- | --- |
| **dsh-TUI 的 UI 验收**（原 B5） | `make dev-tui` 与 `plugins/dsh-tui` 只是**备选交互方式**，非当前重点（组件目录里已是 `ciScope: ["metadata"]` / `runtimeScope: "excluded"`）。详见 [AGENTS.md](../AGENTS.md) 的「TUI 不是当前重点」 | 用户明确要求把 TUI 提到重点时。⚠️ 注意代价：它不构建不测试，**坏掉时没有任何信号**，别把「没报错」当「还能用」 |

## 已收口（仅作索引，勿在此展开）

- 插件依赖解析族问题（pnpm 解析、构建脚本拦截、npm lockfile、legacy pnpm 路由）→ 已固化进 `scripts/setup.sh` 与 [plugin-dev.md](plugin-dev.md) 的「常见问题」
- modsearch 的 `web` 行 patch 抹掉旁键 → `patches/restore-web-fetch-provider.yml`
- dsh-automation 的 harness 0.1.5-rc.2 适配 → fork `michaelyaoxxx/dsh-automation`，pin 分支 `adapt/harness-0.1.5-rc.2`
