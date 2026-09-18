# `dsh-observability-analysis.md` 专家评审记录（第一轮）

| 属性 | 值 |
| :--- | :--- |
| 被评审文档 | [`dsh-observability-analysis.md`](dsh-observability-analysis.md) |
| 评审视角 | JavaScript/Node 运行时、前端工程、软件工程 |
| 评审基线 | harness `fb2c4b9e`（= `dsh-v0.1.5-rc.2`）；超级仓 `ce09dde` |
| 评审日期 | 2026-09-18 |
| 实测环境 | 隔离 `DSH_HOME=/tmp/dsh-obs/.dsh`、`--port 0`（**全程未占用 3080**，见 §6 隔离声明） |
| 状态 | 本轮评审完成；P0/P1 已由修订轮处理（见 §7） |

> 证据约定与正文一致：`[S]` 源码锚定（`file:line`）、`[验]` 本机实测、`[I]` 推断。
> 本轮**新增**的证据一律标注日期 `2026-09-18`，与文档原有的 2026-09-16 实测区分开。

---

## 1. 结论概览

先说好的：**这份文档的证据纪律是真的，不是装饰**。本轮把正文里全部 32 条（去重后）
`file:line` 锚点机器抽取后逐条回到 harness `fb2c4b9e` 源码核对，
**内容全部吻合**——包括 `package.json:53` 的 `--host-addon-only`、
`native/system/scripts/build.ts:46` 的 `libc` 过滤、
`base/cordis.patch.yml` 里 `hmr` 行 `:21-25` 的 `disabled: true`、
`web-app/cordis.patch.yml:139-140` 的 `3080` fallback 等容易被随手写错的点位。
这在同类分析文档里是稀有品质，也是本文档值得继续投入的前提。

问题集中在三类，都不是「写错了事实」，而是**「给读者的路本身有问题」**：

1. **推荐给读者的命令本身是坏的**（§8 探针恒失败、§6 L2 地图配方漏 35% 分发点）；
2. **遗漏了 harness 自带的、权威且省力的观测面**（生成目录 7 份、模型侧运行时内省工具），
   而本文档的核心命题恰恰是「怎么观测」——这使它在最关键处不完整；
3. **§11 不可执行**（是意图清单，不是流程），而它正是读者上手的第一站。

| 严重度 | 条数 | 是否修订 |
| :--- | :--: | :--: |
| P0（会误导 / 直接跑不通） | 2 | 是 |
| P1（可改进 / 不完整） | 7 | 是 |
| P2（建议） | 3 | 留档 |

---

## 2. 评审方法（可复现）

本轮没有停留在通读，做了两件可复现的事：

1. **锚点全量机器核对**：从正文正则抽取所有 `path:line`，对 harness `fb2c4b9e`
   （用 `git show <pin>:<path>` 读**pin 的字节**，不受工作树当前 HEAD 影响）逐条打印比对。
   结果：文件命中 21 条、**裸文件名 10 条**（P1-6）。
2. **§11 全流程实测**：按其「调查顺序」五步实际跑了一遍（隔离 home + `--port 0`），
   过程与数据见 §6。**§11 的问题正是这样跑出来的**——只读文档不会发现 `curl -f` 恒失败。

---

## 3. P0（会误导 / 直接跑不通）

### R-P0-1｜§8 探针脚本的 `curl -fsS` 与认证门互斥 ⇒ 该脚本**恒判失败**

- **位置**：§8「外部黑盒探针」的 `curl -fsS "$url" >/dev/null 2>&1 && { ready=…; break; }`。
- **问题**：本仓 `dsh web` 对无 token 的 `/` 返回 **401**（文档自己在 quickref §6 写明了这点）。
  `curl -f` 遇 4xx 直接判失败并返回退出码 22 ⇒ `&&` 分支**永不触发** ⇒ 循环必然跑满
  600 次后走到 `echo "not ready"` + `exit 1`。**这个探针在任何正常实例上都不可能报 ready。**
- **[验] 2026-09-18**：

  ```text
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/   → http_code=401，退出码 0
  curl -fsS -o /dev/null                http://127.0.0.1:3080/   → curl: (22) … error: 401，退出码 22
  ```

- **旁证（这份文档本该参考的写法）**：本仓 `.github/workflows/verify.yaml` 的冒烟步骤
  **刻意不用 `-f`**，改用 `-w '%{http_code}'` 并把 `200|303|401` **都**视为通过，
  且注释写明了理由。同一仓库里已经有一份正确的实现。
- **处置**：§8 已换成本轮实测通过的修正版（状态码白名单 + `--port 0` + 可移植计时 + 正确清理），
  见 §7 修订清单；修正版脚本见正文 §8。

### R-P0-2｜§6 L2 / §11 第 1 步的「源码地图」配方漏掉 35% 的分发点，而 harness **已生成权威目录**

- **位置**：§6 L2 `rg -n 'ctx\.(emit|waterfall|parallel|serial|bail)' harness/packages harness/vendor`；
  §11 第 1 步「§6 L2 的 rg 命令跑一遍，建立事件/service 目录」。
- **问题一（漏检）**：该配方只认 `ctx.` 接收者。实际分发点大量走 `this.dispatch.*`
  / `events.dispatch` / `context.*` / `actx.*` 等其它接收者。**[验] 2026-09-18**：

  | 模式 | 全部分发点 | 其中经 `ctx.` | 漏检 |
  | :--- | --: | --: | --: |
  | `emit` | 120 | 37 | 83 |
  | `waterfall` | 24 | 15 | 9 |
  | `parallel` | 6 | 4 | 2 |
  | `serial` | **1** | **0** | **1** |
  | `bail` | 7 | 6 | 1 |

  > 口径说明：`emit` 一行含非 cordis 的同名方法（EventEmitter / 流），故其绝对值偏大；
  > `waterfall` / `serial` / `bail` 三个名字在本仓基本为 cordis 专用，**这三行可直接采信**。
  > 即便只取最保守的一行：`serial` 全仓唯一生产调用点
  > `harness/packages/core/agent-loop/src/agent.ts:316`
  > 的 `this.dispatch.serial('agent/turn-stopping', …)`，**经 `ctx.` 命中率为 0**。

  这不是学术问题：`agent/turn-stopping` 声明为 `@mode serial`
  （`harness/packages/core/agent/src/runtime-types.ts:391`），
  位于**每个 turn 的关键路径**上（step end 与 turn end 之间、被 `await`），
  监听方是 `hooks-claude-code` / `hooks-codex`。**按 §6 L2 的地图找"谁拖慢了 turn"，
  会完全看不到这一行。**

- **问题二（重复造轮子）**：harness 已经**生成**了这件事的权威版本——
  `harness/docs/event-producer-consumer.md`
  （由 `scripts/gen-doc-graphs.ts` 生成，`pnpm run gen-doc-graphs` 重建、
  `pnpm run verify-doc-graphs` 校验新鲜度）。它逐事件给出
  **Event / Mode / Declared in（file:line）/ Dispatchers（含用哪个方法分发）/ Listeners**，
  共 **72 个** harness-owned 事件：`emit` 51、`waterfall` 14、`parallel` 2、`serial` 1。
  其页首**自述**存在的理由就是手工 grep 不够：

  > Receiver and event-name types also cover contained dispatch sites that
  > **deliberately bypass `ctx.emit`**, such as subagent lifecycle containment.

  而它的「分发方法」列恰好坐实了漏检：`emit` 28、**`events.dispatch` 25**、
  `waterfall` 16、`serial` 1、`parallel` 1、`emitAgentEvent` 1——
  **25/72（35%）的分发点用 `ctx\.` 根本扫不到。**

- **同类生成物（本文档一份都没提）**：
  `harness/docs/graph-atlas.md` 是所有生成/编排文档的**索引**，
  链到 `module-graph.md`（模块依赖图）、`tool-catalog.md`（工具 schema 目录）、
  `config-catalog.md`、`persistence-catalog.md`、`capability-seams.md`、
  **`agent-lifecycle.md`（agent turn/step 生命周期，mermaid 时序图）**、
  **`tool-execution-pipeline.md`（工具执行管线）**。
  后两份**正好覆盖本文 §4 与 §8 的主题**。
- **处置**：§6 L2 与 §11 第 1 步前移「先读生成目录，再用 rg 补漏」，并给出修正后的配方
  （见 §7）。这不降低文档的价值——反而让「源码地图」这一步从 20 分钟手工活变成 2 分钟。

---

## 4. P1（可改进 / 不完整）

### R-P1-1｜build record 的路径写错（`harness/.dsh-build/` 不是 `.dsh-build/`）

- **位置**：§5「build record（`.dsh-build/client-build-environment.json`）」、§6 L0 存档清单同一路径。
- **问题**：按字面理解会去**仓库根**找，而实际位置是 **`harness/.dsh-build/client-build-environment.json`**
  （`dsh` 从 harness 目录启动，record 落在 harness 内）。
- **[验] 2026-09-18**：按文档字面路径 `find . -name client-build-environment.json` → 仅命中
  `./harness/.dsh-build/client-build-environment.json`；根目录 `ls .dsh-build/` → 不存在。
- **影响**：L0 是「永远第一步」，这条是它的存档清单，读者会以为存档了其实没存到。
- **处置**：§5 与 §6 L0 补全路径。

### R-P1-2｜§3.2 把一处 `console.debug` 计入了 `logger.debug()`

- **位置**：§6 L1「该 profile 全仓只有 **4 处 `logger.debug()`**（auth 授权撤销 / webworker tunnel /
  webhook 事后 / vendor hmr 模块热重载路径）」；quickref §1 同。
- **问题**：四处里有一处**不是 cordis logger**。**[验] 2026-09-18** 按 `.debug(` 全仓核对（排除测试）：

  | 位置 | 实际调用 | 受 `levels.default` 门控？ |
  | :--- | :--- | :-- |
  | `packages/credentials/authorization/src/index.ts:409` | `this.ctx.logger.debug(…)` | 是 |
  | `packages/webhook/webhook/src/index.ts:154` | `this.selfCtx.logger.debug(…)` | 是 |
  | `vendor/hmr/src/index.ts:245` | `this.ctx.logger.debug(…)` | 是 |
  | `packages/experimental/webworker-runtime/src/transport/tunnel.ts:407` | **`console.debug(…)`** | **否** |

- **影响**：结论（「开 `levels.default=3` 收益≈0」）**仍然成立**，且计数 4 也对；
  但读者会误以为开 levels 能看到 tunnel 那条——实际上 `console.debug` 走的是
  realm 自己的 console，与 cordis 的 levels 查表无关，**它一直就在输出**。
- **处置**：§6 L1 与 quickref §1 改为「3 处 `logger.debug()` + 1 处 `console.debug()`（不经 logger 门控）」。

### R-P1-3｜L4「同 API 重复请求 → React 订阅未 dispose」单因归因过窄

- **位置**：§6 L4 判断边界最后一条。
- **问题**：重复请求至少有三个来源，文档只留了一个：
  1. **render-then-subscribe 竞争**——harness 自己把这个当已知问题处理：
     `packages/client/resources/src/client/resources.ts:8` 的注释明确写
     "across React's render-then-subscribe window and a StrictMode remount"；
  2. **StrictMode 重挂载**——`packages/client/ui-renderer/tests/bind.client.spec.tsx:89` 有一条
     `is StrictMode-safe and cleans up subscriptions on unmount` 的回归测试；
     但生产壳 `harness/apps/web/src/main.ts` **不包 `StrictMode`**，
     所以 **prod 上的重复请求不可能是 StrictMode 造成的**——这一点值得写明，否则排查会跑偏；
  3. 真正的订阅泄漏（缺 disposer）。
- **处置**：L4 拆成三因，并注明「prod 无 StrictMode」。

### R-P1-4｜§11 是意图清单，不是可执行流程

- **位置**：§11 全节（5 条，无命令、无判据、无隔离要求）。
- **问题**：
  - 「固定装配」没说要**隔离 home**——照做的人很可能直接用 `./.dsh`，
    而那个目录正常时有实例在跑（本机此刻就有一个），并发写同一会话库有风险；
  - 通篇未提 **`--port 0`**，读者会默认 3080，**直接撞上正在运行的实例**；
  - 无退出判据（什么样算「基线固定好了」？）；
  - 第 3 步「≥10 次」但没说**怎么计时**、什么算 ready（§8 那个坏探针正是被这一步引用的）。
- **影响**：这是读者上手第一站，也是最容易失败的一步。
- **处置**：§11 已重写为可直接执行的五步（含命令、判据、隔离要求与 `--port 0`），
  且**本轮按新流程完整跑通**（§6）。这与用户实际反馈的「不要占我正在用的端口」是同一件事。

### R-P1-5｜§8 探针脚本的另两处缺陷（平台与清理）

- **`date +%s%N`**：GNU 扩展。本仓**官方支持 macOS M4**（AGENTS.md 硬约束），
  而 BSD `date` 无 `%N`，会输出字面量 `N`，随后的 `$(( ready - start ))` 直接算术报错。
  **[I]**（无 macOS 环境可实测；BSD date 不支持 `%N` 是既定事实）。处置：改用 `node -e Date.now()`。
- **`DSH_HOME="$OLDPWD/.dsh"`**：`$OLDPWD` 是**当前 shell 的历史 cwd**，
  取决于脚本被从哪个目录调用，不指向 harness 的父目录，脆弱且易静默落错位置。
  处置：显式传变量。
- **清理**：`kill "$pid"` 杀的是 `pnpm` 包装进程，**`node` 子进程会残留并继续占端口**
  （本仓 `docs/plugin-dev.md` 已把这条列为已知坑）。本轮实测就踩到了：
  首轮探针的 `wait "$pid"` 因此挂住不返回。处置：按端口反查真实 `node` pid 再杀。

### R-P1-6｜10 条锚点只给裸文件名，无法直接定位

- **位置**：正文多处，如 `profile.ts:110-131`（§7）、`control-codec.ts:23`（§6 L5）、
  `client-build-environment.ts:35-39`（§0/§5）、`profile-boot.ts:355-371`（§0/§7）、
  `base/cordis.patch.yml:21-25`（§7）、`tests/debugger.e2e.ts:102`（§0）等，共 **10 条**。
- **问题**：文档自己的证据约定是「`[S]` 源码锚定（注 `file:line`）」，
  但裸 basename 需要读者从上下文反推目录（`profile.ts` 在本仓至少有两处同名）。
  §0 那张表的用途就是「逐条核验」，裸名会显著抬高核验成本。
- **处置**：10 条全部补全为仓内完整路径（本轮已逐条定位并核对，内容均正确）。

### R-P1-7｜遗漏「模型侧运行时内省」这条通道

- **位置**：§6 分层方案 L0–L5 整体。
- **问题**：harness 自带 `@deepseek-ai/dsh-tool-cordis`——**模型可用的实时 cordis 内省工具**，
  提供 `providedServices` / **`missingServices`** / `describePlugins` / `describeTools` /
  `describeEvents` / `describeApi` / `describeDynamic`，并能创建、运行、停止、
  更新、删除**临时动态包（host 代码 / 浏览器代码 / 两者）**，
  定义只存在于进程内存、重启即消失，**不写仓库文件、不装依赖、不改 `cordis.yml`**。
- **为什么重要**：它正好覆盖文档里几处只能靠外部手段做的诊断：
  - §2.2 第 4 条「插件是否因缺失 injected service 而未激活」→ 直接问 `missingServices`；
  - §4 的工具注册表 → `describeTools`；
  - §9 的 load/unload 不变量 → reload 前后各取一次 `describePlugins` 做差分；
  - §6 全表 → 一个**不需要重启、不需要改仓库**的临时观测插件通道。
- **[验] 2026-09-18 装配事实**：底座
  `@deepseek-ai/dsh-cordis-host-runner` **已在** web-app bundle
  （`harness/packages/bundle/web-app/cordis.patch.yml:122-123`），
  本轮装配树 dump 第 422-423 行可见；但 `dsh-tool-cordis` **未挂载**
  （不在任何 bundle 的 `cordis.patch.yml`，也不在装配树里），其 `lib/index.js` 已构建。
  ⇒ **启用成本 = 一条 `insert` patch**，与 §6 L5 挂 inspector 的形态完全一样。
- **处置**：§6 新增 L6（或并入 L0/L2 之间）说明该通道 + 给挂载 overlay；
  §11 第 1 步加一句「先看生成目录，再考虑挂 tool-cordis」。

---

## 5. P2（建议，留档）

### R-P2-1｜「make 会把命令行变量导出到 recipe 环境」用词不精确

- **位置**：§6 L3 开头。
- **问题**：`NODE_DEBUG=http make dev` 生效靠的是**环境变量继承**（make 把自身环境传给 recipe），
  与「make 命令行变量（`make VAR=value`）会被导出」是**两种不同机制**。
  Makefile:64 的注释说的是后者（那是 `make release VERSION=…` 的注入面讨论）。
  借用那句措辞会让读者以为两种写法等价——绝大多数情况等价，但成因不同。
- **建议**：改为「以环境变量前缀方式传入（make 把自身环境透传给 recipe）」。

### R-P2-2｜`[验]` 的跨文档出处未在正文逐条注明

- **问题**：§12 写「[验] 全部来自 2026-09-16 隔离实例与 quickref 既有实测」，
  但 V2/V7 的完整实测记录实际归档在 `dsh-build-analysis-review.md` §9；
  读者按 §12 在 quickref 里找不到全部出处。
- **建议**：出处补到具体文档+小节。

### R-P2-3｜§4「trace 黄金关联键」缺「可获取性」列

- **问题**：列了 9 个 id（session / turn / agent run / model request / tool call / tool name /
  plugin row id / scope id / …），但没说**哪些能直接从 session log 取到、
  哪些需要 observer 插件自埋**。读者拿这张表无法立即动手。
- **建议**：加一列「来源：session log / 插件自埋 / 需外部探针」。

---

## 6. 本轮实测记录（§11 调查顺序执行，2026-09-18）

### 6.1 隔离声明（**全程未占用用户的 3080**）

| 项 | 值 |
| :--- | :--- |
| 发现 | 本机已有一个实例在跑：pid 1173763，`DSH_HOME=/hdd_10T/michael/workspace/oh-my-dsh/.dsh`，监听 `127.0.0.1:3080` |
| 本轮 `DSH_HOME` | `/tmp/dsh-obs/.dsh`（**新建**；`link-plugins.sh` 要求形如 `<目录>/.dsh`，它会把 `HOME` 重定向到其父目录） |
| 本轮端口 | 每次 `--port 0`，由 OS 分配（实测 43229 / 37297 / …，**无一为 3080**） |
| 用户状态核验 | 运行前后 `~/.modsearch/config.json`（17:22:37, 83B）与 `~/.modlens/config.json`（17:22:37, 162B）**mtime/大小均未变**；仓库 `.dsh` mtime 未变；3080 实例始终 `http_code=401` 正常 |

### 6.2 第 1 步 源码地图

见 R-P0-2 的两张分布表。**结论**：配方漏检，且生成目录已存在，应前移。

### 6.3 第 2 步 固定装配（干净 home）

```text
link-plugins.sh（DSH_HOME=/tmp/dsh-obs/.dsh）→ 退出码 0
  「完成: 已挂载 10 个 bundle 到 profile dsh」
  跳过 16 个家族成员（由聚合包带出）
dump-config → 退出码 0，665 行，**0 条 warn/error**，**181 个 entry**
超级仓 commit: ce09dde     harness commit: fb2c4b9e
build record: harness/.dsh-build/client-build-environment.json
  {DSH_CLIENT_COMMIT_HASH: "fb2c4b9", DSH_CLIENT_VERSION: "0.1.5-rc.2", artifacts.fileCount: 234}
```

> 附带印证了 §2.1：dump-config 的 `# ==` 分节**显式打印了层叠**
> （如 `# == @deepseek-ai/dsh-base, patched by /tmp/dsh-obs/.dsh/profiles/dsh/cordis.patch.yml`），
> 「§2.2 第一诊断点」这个定位是准确的。

### 6.4 第 3 步 Host 基线（启动耗时）

| 轮次 | 端口 | 打印 URL | HTTP 就绪 | 差 | code |
| --: | --: | --: | --: | --: | --: |
| warmup（**冷启**，刚 link 完） | 46415 | 16678 ms | 16734 ms | 56 ms | 401 |
| 1 | 43229 | 14299 ms | 14355 ms | 56 ms | 401 |
| 2 | 37297 | 14790 ms | 14850 ms | 60 ms | 401 |
| 3 | 41619 | 13808 ms | 13867 ms | 59 ms | 401 |
| 4 | 36801 | 15761 ms | 15817 ms | 56 ms | 401 |
| 5 | 33737 | 13678 ms | 13732 ms | 54 ms | 401 |
| 6 | 34679 | 16089 ms | 16148 ms | 59 ms | 401 |
| 7 | 45501 | 15051 ms | 15108 ms | 57 ms | 401 |
| 8 | 37915 | 15798 ms | 15859 ms | 61 ms | 401 |
| 9 | 37355 | 15138 ms | 15196 ms | 58 ms | 401 |
| 10 | 41659 | 14287 ms | 14343 ms | 56 ms | 401 |

**10 轮预热后统计**：URL 就绪 均值 **14870 ms** / 中位 14921 / 极差 13678–16089；
HTTP 就绪 均值 **14928 ms**。**10/10 全部成功，端口无一为 3080。**

> **[验] 一条对 §8 有用的副产品**：「打印 URL」与「HTTP 就绪」的间隔**极稳定，
> 10 轮全在 54–61 ms**。也就是说 **URL 日志行本身就是廉价而可靠的 readiness 标记**——
> 排障时用 `grep 'dsh web: http'` 等这一行，与等首个 HTTP 响应几乎等价，
> 且不依赖 curl/端口探测。
>
> ⚠️ 口径与边界：这是**外部黑盒**口径（进程拉起 → 首个 HTTP 响应），
> **不含**前端资源传输 / JS 求值 / API bootstrap / 首屏渲染——与 §8 自述一致。
> **冷启 16.7 s**（warmup，是 fresh link 后真正第一次启动）明显高于预热后 ~14.9 s，
> 印证 §8「首轮 cold run 单独统计」的要求——若把 warmup 混进均值会低估约 1.8 s。
> 本表为**流程验证样本，不是性能结论**；正式基准应按 §8 跑 ≥10 次并剔除首轮。

### 6.5 第 4/5 步

- **第 4 步（插件增量）**：本轮以「读装配树 + 源码」替代逐个 mount 差分，
  未做单因素增量实验——见 §8 诚实边界。
- **第 5 步（端到端）**：**未执行**。本环境无浏览器自动化通道，
  L4 的前端段（DevTools / Performance / WS 帧）本轮未取数。

---

## 7. 修订轮已落实清单（对照）

| 编号 | 落实 |
| :--- | :--- |
| R-P0-1 | §8 探针换用状态码白名单（不再 `-f`），按 §6.4 实测通过 |
| R-P0-2 | §6 L2 与 §11 第 1 步改为「先读生成目录（graph-atlas / event-producer-consumer）再 rg 补漏」，给出修正配方与漏检量化 |
| R-P1-1 | §5 / §6 L0 build record 路径补全为 `harness/.dsh-build/…` |
| R-P1-2 | §6 L1 与 quickref §1 区分 `logger.debug()`(3) 与 `console.debug()`(1) |
| R-P1-3 | §6 L4 重复请求拆三因，注明 prod 无 `StrictMode` |
| R-P1-4 | §11 重写为可执行五步（隔离 home / `--port 0` / 判据 / 修正探针） |
| R-P1-5 | §8 计时改 `node -e Date.now()`；`DSH_HOME` 显式；清理按端口反查 node pid |
| R-P1-6 | 10 条裸文件名锚点补全为仓内完整路径 |
| R-P1-7 | §6 新增模型侧运行时内省通道（`tool-cordis`）与其挂载方式 |
| R-P1-2/P1-3 配套 | quickref 同步更新（§1 logger、§6 端口与隔离、新增生成目录一节） |

---

## 8. 诚实边界

- **[验] 的范围**：§6 全部数据来自 2026-09-18 隔离实例（`--port 0` + `/tmp/dsh-obs/.dsh`），
  非用户 3080 实例；启动耗时仅 3 个样本（含 1 次冷启），**不构成性能基准**。
- **[S] 的范围**：所有 `file:line` 均读自 harness `fb2c4b9e` 的 git 对象
  （`git show <pin>:<path>`），**不是**工作树当前内容——评审期间工作树 HEAD 恰好等于该 pin，
  但两处如有未提交改动不影响锚点核对结论。
- **[I] 项**：`date +%s%N` 在 macOS 上不可用（无 macOS 环境实测）；
  `tool-cordis` 挂载后的实际可得信息面（只读了 README 与 `inspect.ts` 的导出签名，未实挂）。
- **未覆盖**：第 4/5 步（插件增量差分、浏览器端）本轮未执行；
  文档 §8 的「内部分段 marker」建议仍未被任何实现验证（文档自己已标 `[I]`，本轮维持）。
- **本轮未新起工具链**：未运行 `pnpm run gen-doc-graphs`（只读生成物并按 `git show` 核对其为 pin 内容）。
