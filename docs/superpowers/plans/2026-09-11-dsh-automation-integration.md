# dsh-automation 源码集成（pin tag v0.1.7）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [titanwings/dsh-automation](https://github.com/titanwings/dsh-automation)（`@dsh-external/dsh-automation`）以 git submodule 源码形式接入 `plugins/dsh-automation`，pin 上游正式 tag `v0.1.7`，经 link 挂载进 profile `dsh`。

**插件做什么**：在全新 Agent 会话中按计划跑编码任务（定时自动化），并提供工具让 Agent 自己管理自动化；Web 侧在会话视图与侧边栏页脚注册入口。

## 0. 已拍板的决策

1. **tag pin**：pin 正式 tag `v0.1.7`（**注释标签**，tag 对象 `f7854b9` → commit `5ae28f2`），与 better-sidebar / modlens / 现在的 harness 统一。
2. **不写任何 patch**：宿主 entry 自声明 `inject`（8 个服务，全是正常的服务名，非 getter 捕获模式）；客户端 entry 用 `inject = ['slots','locale','connection','sessions']` 标准注入。两者都不属于 `cannot get property "X" without inject` 那一类（见 plugin-dev.md 常见问题）。
3. **跳过构建**：根 `main` 指向的 `./lib/index.js` **被 git 跟踪**（`lib/` 整目录入库）→ 命中 setup.sh 的「入口已提交即跳过构建」判据，随 pin 自带产物。
4. **pnpm 版本首次出现分化**：本仓 `packageManager: pnpm@10.32.1+sha512.…`，**与 harness 的 11.7.0 不同**。这是仓库声明的自有 pin，`plugin_pnpm` 的路由（有 `packageManager` → 在插件目录内执行 → corepack 按本仓字段解析）正是为此设计，corepack 会下载并使用 10.32.1。

## 1. 已钉死的关键事实（侦察结论）

1. **形态**：单包仓；`dsh.bundle.patch: ./cordis.patch.yml` 落在自身目录 → link-plugins 根候选直接挂载；entry `id: dsh-automation` / `name: '@dsh-external/dsh-automation'`，**无 `disabled` guard**，且带 config 种子（`maxConcurrentRuns: 2` 等 5 项）。
2. **entry id 无冲突**：dsh-web 及其子包均无 `dsh-automation` 引用（不存在 better-sidebar 那种 AUTO-GENERATED 重复行，故无需 disable patch）。
3. **宿主 entry 注入的 8 个服务全部实存**（逐一 grep 核证）：`storageDomain` / `agents` / `sessions` / `workspaceRegistry` / `agentDefaultModel` / `agentPresets` / `tools` / `connection`。
4. **客户端 entry 注入的 4 个服务全部实存**：`slots`（`@deepseek-ai/dsh-client-ui-renderer` 的 `SlotRegistry extends Service`，`registry.ts:134` 的 `super(ctx, 'slots')`）、`locale`（`client/locale/src/client/index.ts:544`）、`connection`（`client/connection/src/client/index.ts:289`）、`sessions`（`packages/api/session-controller/src/client/sessions/service.ts:263`）。
5. **`dsh.client.inject` 里有一个不存在的包**：`@deepseek-ai/dsh-client-runtime`——harness 全仓（源码 / node_modules / lockfile / profile 解析链）都查无此包；只有名字相近的 `@deepseek-ai/dsh-client-test-runtime`（test-support，另一回事）。插件源码与 bundle 也**从未引用**它（bundle 只 `require("react")` / `require("react/jsx-runtime")`）。
6. **该悬空项不会导致失败**：客户端解析循环是 `const dependency = this.graphRows.get(packageName); if (dependency !== undefined) await …`（`client/modules/src/client/system.ts:167`，inject 循环；163 行那个是 external 循环）——**找不到就静默跳过**。实测启动图里它原样透传给浏览器（`inject` 数组未做过滤），浏览器侧忽略。
7. **UI 落点**：客户端把入口注册进 `sidebar.footer.action`（harness `packages/client/ui-sidebar` 声明）与 `conversation.view`（`client-ui-chat` / `client-ui-trajectory` 声明）两个 list 插槽——即 **harness 自带插槽**，非 better-sidebar 提供的私有插槽，因此不依赖 better-sidebar 先加载。
8. **锁文件**：`pnpm-lock.yaml` 存在（lockfileVersion 9.0，pnpm 10/11 兼容）→ frozen 安装可行。
9. **engines** `^22.19.0 || >=24.0.0`，与 harness 一致；运行时依赖仅 `luxon` + `zod`，peer `react` 可选。

## 2. 接入步骤

### 2.1 submodule + pin

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/titanwings/dsh-automation.git plugins/dsh-automation
git -C plugins/dsh-automation checkout --detach v0.1.7   # 归一化（submodule add 会停在默认分支）
git -C plugins/dsh-automation rev-parse HEAD             # 预期 5ae28f2（v0.1.7^{}）
```

### 2.2 安装（复用 setup.sh 插件循环）

```sh
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> plugins/dsh-automation 未声明可构建依赖（无 onlyBuiltDependencies/allowBuilds），以 --ignore-scripts 安装`
- `! Corepack is about to download …/pnpm-10.32.1.tgz` → `Done in 2s using pnpm v10.32.1`（**本仓自有 pin**，非 harness 的 11.7.0）
- `==> 跳过构建: plugins/dsh-automation 入口 ./lib/index.js 已提交在仓库内`
- `git submodule foreach` 六个仓均 `0 dirty`

### 2.3 Commit（C1）

```sh
git add .gitmodules plugins/dsh-automation
git commit -m "feat: 引入 dsh-automation 源码 submodule（plugins/dsh-automation，pin tag v0.1.7）"
```

## 3. 挂载 + dump 验证（本地，boot-free）

```sh
make link-plugins
cd harness && DSH_HOME=/Users/michaelyao/workspace/dsh/.dsh COREPACK_DEFAULT_TO_LATEST=0 CI=true \
  pnpm dsh --profile dsh --dump-config > /tmp/dump-automation.txt 2>&1; echo "exit=$?"
grep -n -A12 "id: dsh-automation" /tmp/dump-automation.txt
grep -i "warn\|not found" /tmp/dump-automation.txt || echo "无 warn ✓"
```

实测：exit 0、挂载数 5 → **6**、entry 带 5 项 config 种子、无 warn。

## 4. boot 验证

```sh
make dev     # 出现 dsh web: http://127.0.0.1:3080/?token=… 即成功
```

实测通过，且进一步核证了客户端半侧：

- 带 token 访问 `303`、根路径 `401`（认证 gate 正常）。
- 页面里 `window.__DSH_BOOT__` 引导图**含** `@dsh-external/dsh-automation` 条目（`inject` 数组含那个悬空包名，原样透传）。
- 其客户端 bundle 由插件路由实际提供：`/plugins/??@dsh-external/dsh-automation/client.js` → **HTTP 200、98967 字节**、内容为 `window.__ModuleLoader__.load({ id: "@dsh-external/dsh-automation", … })` 协议。

**待用户 UI 验收**：会话视图里的 Automation 入口、侧边栏页脚动作是否渲染并可交互（客户端渲染只能实机确认）。**另外必须真实跑一次自动化**——见 §4b：v0.1.7 与新 harness 有一处**只在执行时才暴露**的不兼容，boot 级验证查不出来。

## 4b. 运行时缺陷：AgentSetup 第二参数（已在本地分支修复）

### 4b.1 症状与根因

- **症状**：自动化**真正执行**时抛 `Error: automation setup has no scoped Agent`。挂载、dump、boot 全部正常——**启动阶段完全不体现**。
- **根因**：harness 在 0.1.5-rc.2 起把 Agent 作为 `setup` 回调的**第二参数**传入：

  ```ts
  // harness/packages/core/agent/src/index.ts:50
  export type AgentSetup = (agentCtx: Context, agent: Agent) => AgentSetupCommit | …
  // 调用处 harness/packages/core/agent-loop/src/index.ts:825
  const setupCommit = await raceAbort(setup?.(prepared.agent.ctx, prepared.agent), prepared.signal, id)
  ```

  unpublished Agent 的 ctx 上**已不再提供 `agent` 服务**（全仓搜不到 `provide('agent')`），所以 v0.1.7 的 `const agent = agentCtx.agent` 恒为 `undefined`，随即抛错。
- **上游状态**：`origin/main`（领先 v0.1.7 共 26 个提交）**仍是旧写法**——这不是「pin 落后」，而是新 harness 带来的真实不兼容，等上游修不可行。

### 4b.2 修复（提交在 fork 的适配分支）

上游不含这些适配（`origin/main` 领先 v0.1.7 共 26 个提交仍是旧写法），故走 fork：

```
fork：https://github.com/michaelyaoxxx/dsh-automation（upstream remote 指回 titanwings）
分支：adapt/harness-0.1.5-rc.2
  faef87a  fix(executor): 适配 DSH 的 AgentSetup 第二参数，取代 agentCtx.agent
  a2f60c1  fix(session): 改用 session.snapshotEvents()，取代已移除的 session.events
```

改动 `src/executor.ts` / `src/index.ts`（改用新 API）、`src/types/dsh.d.ts`（本地声明补 `Agent`，沿用本仓既有的 `declare module` 模式）与重建产物 `lib/index.js`。

**产物一致性已验证**：把工作树复制到 /tmp 用 `scripts/build.mjs` 重建，`lib/index.js` 与工作区版本**逐字节一致**；`lib/client.js` 未变（修复只在宿主侧）。

**主仓侧同步**：`.gitmodules` 的 url 改为 fork；pin 指向 `a2f60c1`；`verify.yaml` 与 `release.sh` 把 dsh-automation 从 **tag 校验** 移到 **分支校验**（分支 pin 便于后续继续追加适配，不必每次造新 tag）。

### 4b.3 剩余断裂点的系统排查（避免打地鼠）

两次断裂都是「加载期正常、执行期才炸」，逐个跑出来代价高。故对插件用到的**整个 harness API 面**做了逐项比对：

| 核对面 | 结果 |
| --- | --- |
| 从 harness 包导入的 11 个符号（`createUserMessage`/`defineTool`/`installModelSelection`/`SessionId`/`setApprovalPolicy`/`setSandboxMode`/`WorkspaceId` + 4 个类型） | 全部仍导出 ✓ |
| ctx 服务方法（`agents.create/get/roots/withoutInitiator`、`agentPresets.mount/composedPreset`、`agentDefaultModel.currentSelection`、`workspaceRegistry.archivedSessionIds/archiveSession/get/resolveByPath`、`sessions.flush`、`tools.register/guard`、`storageDomain.open`、`connection.rpc`） | 全部存在 ✓ |
| `CreateAgentOptions` 字段、`AgentSetup` 签名 | 匹配 ✓ |
| Session 成员（`header` 含 `cwd`/`agentPreset`、`requestHeader()`、`seq`、`snapshotEvents()`） | ✓ |
| Agent 成员（`session`/`ctx`/`id`/`cancel`/`followup`/`whenIdle`） | ✓ |
| `domain.table()/close()`、workspace `status()/path/attachSession()` | ✓ |

**结论**：已修的两处即完整集合。注意这只覆盖「存在性与签名形状」，语义变化静态查不出——**最终仍以真跑一次自动化为准**。

### 4b.4 操作要点

- `make setup` 的 `git submodule update` 会把 submodule 检出到 pin 提交；因为 pin 现在**就是**分支提交，工作树与 pin 一致，不再有「修复失效」问题。
- 后续要再追加适配：在分支上提交 → `git push` → 主仓 `git add plugins/dsh-automation` 更新 pin（`verify.yaml` 的分支校验要求 pin 与远端分支一致）。

> 4b.1–4b.3 描述的「本地分支 + 工作树与 pin 不一致」阶段已经结束——fork 落定后主仓 `git status` 干净，`make release` 的干净度检查也恢复通过。

## 5. 过程记录：集成期遇到的两个问题

> 第三个问题（运行时缺陷）性质不同——它不在集成流程里，而是集成**之后**用真实执行才暴露出来的，单列于 §4b。

### 5.1 端口被上一次验证的残留进程占用（EADDRINUSE）

症状：`make dev` 直接失败——`failed to apply loader entry webserver (@deepseek-ai/dsh-host-webserver): listen EADDRINUSE: address already in use 127.0.0.1:3080`。

根因：**停止后台任务只杀掉 `make` 包装进程，`scripts/link-plugins.sh && … pnpm dsh` 链里最终那个 `node --import tsx/esm apps/cli/src/bin.ts --profile dsh --no-open` 子进程会存活**并继续占着 3080（上一轮 harness 升级验证留下的，已存活 14 分钟）。

处置：`lsof -nP -iTCP:3080 -sTCP:LISTEN -t` 定位 → `kill <pid>` → 确认释放后重启。**这是操作卫生问题，不是插件缺陷**；但它会伪装成「新插件导致启动失败」，排查时先看 3080 是否被占。

### 5.2 误把「tag 不存在」当结论（沿用上一轮的教训，本轮提前避开）

`git ls-remote --tags` 首次因 `LibreSSL SSL_ERROR_SYSCALL` 失败；重试后才拿到 tags。上一轮 harness 升级的教训（网络抖动 + 命名前缀）在本轮直接命中：重试循环取 tags，并确认 `v0.1.7` 是**注释标签**（`f7854b9` 是 tag 对象、`5ae28f2` 是 commit），故 tag 比对必须用 `rev-parse <tag>^{}`（FAQ 已有此条，CI 早已按此写）。

## 6. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | 追加 `"plugins/dsh-automation v0.1.7"` |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/dsh-automation` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/dsh-automation v0.1.7` |
| `AGENTS.md` 稳定分支行 | 追加 `；dsh-automation → 正式 tag \`v0.1.7\`（tag pin）` |
| `README.md` plugins 行 | 追加 `dsh-automation pin tag \`v0.1.7\`` |
| `docs/superpowers/specs/…-design.md` | 子仓清单、目录树、release 校验行同步 |

### Commit 切分

```sh
git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 dsh-automation（pin tag v0.1.7）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 dsh-automation（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（pnpm 版本分化 / 端口残留 / 悬空 client inject）"

git add docs/superpowers/plans/2026-09-11-dsh-automation-integration.md
git commit -m "docs(plans): 记录 dsh-automation 集成手册"
```

## 7. 与前几个插件的机制差异（本轮新出现）

| 维度 | 前几个插件 | dsh-automation | 影响 |
| --- | --- | --- | --- |
| **pnpm 版本** | 无 `packageManager`（mineru/modlens，走 harness pin 11.7.0）或与 harness 同版本（better-sidebar 11.8.0） | **pnpm@10.32.1**，与 harness 的 11.7.0 不同 | 首次验证「各仓自有 pin」这条设计确实生效：corepack 按本仓字段下载并使用 10.32.1，互不干扰 |
| **构建产物形态** | mineru 提交 `lib/` 且本地重建会脏化；better-sidebar/modlens 不提交、必须构建 | 提交 `lib/`（含 `lib/types/**`），构建脚本是自写 `scripts/build.mjs`（tsc 产 d.ts + esbuild 打包） | 命中「入口已提交即跳过构建」，不会脏化 |
| **客户端注入** | modlens 无 inject；better-sidebar 注入 4 个**包**名 | `dsh.client.inject` 里有一个**不存在的包** `@deepseek-ai/dsh-client-runtime` | 客户端对 inject 采用「找不到就跳过」的宽松语义（`system.ts:167`），非致命；若换成严格语义就会成为阻断项 |
| **UI 落点** | better-sidebar 自带侧边栏；mineru 走设置页；modlens 走 slots 配置卡 | 注册进 harness 自带的 `conversation.view` / `sidebar.footer.action` 插槽 | 依赖 harness 的插槽契约而非某个插件的私有服务，耦合面更小 |
| **宿主注入** | mineru/connection 出过「getter 捕获 this.ctx」的坑，需 patch | 8 个服务全部自声明、全部实存 | 无需 patch；也再次印证 FAQ 那条判据（自声明 → 不用补） |
| **harness API 漂移** | 前几个插件的耦合面（服务名、插槽、bundle 协议）在 0.1.5-rc.2 上未变 | `setup` 回调签名变了（Agent 改走第二参数），v0.1.7 与新 harness **运行时**不兼容 | **首个需要本地分支承载修复的插件**：boot/dump 级验证全绿也查不出来，只有真跑一次才暴露；修复无法上游（上游未修），只能本地分支 + 日后 fork |
| **pin 与工作树的语义** | pin = 工作树检出的提交，两者一致 | 修复在分支上，**pin(v0.1.7) ≠ 工作树 HEAD(faef87a)** | 主仓显示 ` M plugins/dsh-automation`；`make setup` 会把工作树拉回 pin（修复失效但提交仍在分支上）；`release.sh` 的干净度检查会拒绝 |

## 8. Commit 汇总（全部无 AI 署名）

| # | Message 建议 |
| -- | --- |
| C1 | `feat: 引入 dsh-automation 源码 submodule（plugins/dsh-automation，pin tag v0.1.7）` |
| C2 | `ci: verify/release 校验加入 dsh-automation（pin tag v0.1.7）` |
| C3 | `docs: 记录 dsh-automation（AGENTS/README/spec）` |
| C4 | `docs(plugin-dev): 补症状→处置（pnpm 版本分化 / 端口残留 / 悬空 client inject）` |
| C5 | `docs(plans): 记录 dsh-automation 集成手册` |
| C6 | 主仓：`docs(plans): 补 dsh-automation 运行时缺陷与本地分支修复（§4b）` |
| — | submodule 内（不在主仓）：`fix(executor): 适配 DSH 的 AgentSetup 第二参数，取代 agentCtx.agent`（分支 `adapt/harness-0.1.5-rc.2`，`faef87a`） |
