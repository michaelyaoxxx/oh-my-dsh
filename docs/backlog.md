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
| B2 | **`plugins/dsh-plugin-mineru` pin 落后上游 7 个提交** | 同上，`pin vs origin/master` = behind 7 | 同上 |
| B3 | **`make deploy` 从未实际执行过** | 脚本与 systemd unit 已写好，但部署路径**一次都没跑通** | 找一台 Linux x86-64 实跑一遍（注意：原生依赖必须在该平台各自构建） |
| B4 | **新装插件的 UI 验收未做** | modsearch（搜索 + fetch）、dsh-at-file、dsh-agent-teams、dsh-market、modlens 等挂上了但未逐个走查 | 在 `make dev` 里逐个过主要交互 |
| B5 | **dsh-TUI 未做 UI 验收** | submodule + pin `v0.10.1` + 独立 profile `tui` 都已就绪，但 `make dev-tui` 需真 TTY，**从未实际启动过 TUI 界面** | `make dev-tui` 跑一次。详见[集成手册](superpowers/plans/2026-09-13-dsh-tui-integration.md) |
| B6 | **dsh-TUI 的 macOS 路径长度缺陷应报上游** | 其 `scripts/verify-inject-channel.mjs` 用 `os.tmpdir()`，macOS 下 unix socket 路径达 105 字节 > `sun_path` 上限 104 → `listen EINVAL`。本仓已用 `TMPDIR=/tmp` 绕行 | 报给 ccch1mneyyy/dsh-TUI（建议短路径或建 socket 前检查长度） |
| B7 | **本仓 CI 不跑任何 submodule 测试** | 实测：harness 962 个测试文件、10 个插件合计 700+，而 CI 里一个都没跑（只有 pin / shellcheck / 构建 / 冒烟） | 按 [CI/CD 测试策略](cicd/04-test-strategy.md) 与[迁移阶段](cicd/01-architecture.md#12-迁移与验收阶段)落地版本化测试 catalog、根仓测试入口和发布回归 |
| B8 | **dsh-plugin-mineru 截断函数在长 TMPDIR 下「越截越长」** | 实测：`lib/index.js:219` 的 `maybeTruncateMd` 把绝对路径嵌进提示语，macOS 长 tmpdir 下 202 > 原文 200 → 其自测 1 failed；`TMPDIR=/tmp` 则 29 passed | 报上游（建议加兜底：提示语长于截断量时不做截断）；同时是「必须双平台测试」的实证 |
| B10 | **`link-plugins.sh` 只挂不摘** | 组件从 `runtimeScope: required` 改成 `excluded` 后，profile 里上一轮的 link **仍留着**，于是组件目录说「不进运行时」而实际照样加载。已加**告警**（2026-09-15，实测对 mineru 命中、对未挂载的 dsh-tui 不误报），但**不自动摘除** | 查明 `dsh plugin` 是否有 remove 子命令（未验证前不动用户的 profile），有则在脚本里对 excluded 组件做幂等摘除；否则文档化「删 profile 目录重跑」为正式处置路径 |
| B9 | **可选自装组件（mineru）的安装路径未文档化** | 2026-09-15 起 mineru 因 AGPL 边界移出默认 profile 与制品（`runtimeScope: excluded`），本地 `make dev` 与远程部署**都不再挂它**；但「想用的人怎么装」还没写成文档 | 在 [plugin-dev.md](plugin-dev.md) 补一节：给出**实测过**的安装命令（`dsh plugin --profile dsh add …`；dsh-market 的 registry 快照里出现过 `github:HuanLinOTO/dsh-plugin-mineru` 形式，**须实测确认**），并说明它不在默认组合里、不进制品 |

---

## 已收口（仅作索引，勿在此展开）

- 插件依赖解析族问题（pnpm 解析、构建脚本拦截、npm lockfile、legacy pnpm 路由）→ 已固化进 `scripts/setup.sh` 与 [plugin-dev.md](plugin-dev.md) 的「常见问题」
- modsearch 的 `web` 行 patch 抹掉旁键 → `patches/restore-web-fetch-provider.yml`
- dsh-automation 的 harness 0.1.5-rc.2 适配 → fork `michaelyaoxxx/dsh-automation`，pin 分支 `adapt/harness-0.1.5-rc.2`
