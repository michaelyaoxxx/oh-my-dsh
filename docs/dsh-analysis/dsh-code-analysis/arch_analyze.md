# deepseek-harness 项目架构与代码影响分析

> 分析日期：2026-09-16
> 数据口径：源码统计排除 `node_modules/.git/lib/dist` 构建产物与 `.map/.d.ts`；
> Git 分析窗口近 12 个月（仓库实际历史 2026-06-10 ~ 2026-09-15，共 17,177 commits / 58 贡献者）

---

## 一、项目分层架构识别

`deepseek-harness`（`dsh`）是 DeepSeek AI 开源的 **agent harness**，采用 everything-is-a-plugin 架构（基于 Cordis），所有能力（模型适配、工具注册、会话日志、agent loop 本身）都是插件。

```mermaid
flowchart TD
    subgraph 输入层
      UI[Web / 桌面 UI<br/>apps/web, client/*]
      CLI[dsh CLI<br/>apps/cli]
      ACP[ACP / SDK<br/>bundle/acp-app, sdk-app]
      WEBHOOK[Webhook<br/>packages/webhook]
    end
    subgraph 网关层
      GW[api/gateway 流式网关<br/>session/snapshot/event streams]
      CTL[API 控制器<br/>session/workspace/terminal/settings]
      BOOT[app-boot 装配<br/>profile+bundle]
    end
    subgraph 核心处理层
      CORE[core: agent/agent-loop<br/>session/system-prompt/tools/scope]
      LLM[llm: 模型适配与流式]
      SESS[session 持久化与投影]
      SUB[subagent 子代理]
    end
    subgraph 工具执行层
      TOOLS[Tools 注册表<br/>core/tools + 工具包]
      EXEC[工具执行管道<br/>fs/shell/subprocess/terminal/web]
      SAFE[沙箱与安全<br/>sandbox/ssh/guard/preset]
    end
    subgraph 外部系统层
      EXT[LLM 供应商<br/>OpenAI 兼容 / DeepSeek 协议扩展]
      FILES[文件系统 / SSH]
      NET[外部网络<br/>web-search/mcp]
      STORE[存储 / 凭证]
    end

    UI --> GW
    CLI --> GW
    ACP --> GW
    WEBHOOK --> GW
    GW --> BOOT --> CORE
    CORE --> LLM
    CORE --> SESS
    CORE --> SUB
    CORE --> TOOLS --> EXEC
    EXEC --> SAFE
    EXEC --> EXT
    EXEC --> FILES
    EXEC --> NET
    EXEC --> STORE

    subgraph 框架基座（Layer 0）
      CORDIS[@deepseek-ai/cordis 4.0.2<br/>插件元框架]
      LOADER[loader 加载器<br/>include 配置包含]
      SCHEMA[schemastery<br/>类型驱动 schema]
      UTIL[cosmokit / timer / hmr<br/>logger-console / group]
    end

    UI -.-> CORDIS
    GW -.-> CORDIS
    CORE -.-> CORDIS
    EXEC -.-> CORDIS
    BOOT --> LOADER --> SCHEMA
    BOOT --> CORDIS
    BOOT --> UTIL
```

### 分层清单

| layer_id | layer_name | description | responsibility |
|---|---|---|---|
| 0 | Framework Foundation（框架基座） | `vendor/`：源码式 vendored 的 Cordis 框架层（9 个 `@deepseek-ai` 包） | 提供插件元框架、事件总线、配置 schema、加载器/HMR/Include 等基础能力，被全部业务层依赖 |
| 1 | Input Sources（输入层） | 用户请求与事件输入：Web/桌面 UI、CLI、ACP/SDK、Webhook | 接收任务并把请求翻译为会话输入 |
| 2 | Gateway（网关层） | API 网关、远程流式协议、应用装配（profile/bundle） | 路由流量、建立会话、装配插件树 |
| 3 | Core Processing（核心处理层） | Agent 运行时、会话日志、系统提示、模型适配、子代理 | 驱动 agent loop、维护会话状态、编排模型调用 |
| 4 | Tool Execution（工具执行层） | 工具注册与执行管道、沙箱与权限 | 按需执行工具并安全地访问宿主能力 |
| 5 | External Systems（外部系统层） | LLM 供应商、文件/SSH、网络服务、存储凭证 | 对接外部能力并返回结果 |

> **框架层说明**：`vendor/` 是本项目的框架基座（layer 0），以源码形式 vendored 的 Cordis 框架及其基础库，
> 而非 npm 直接依赖——使 harness 完全拥有其框架层（可审计、可打补丁、锁定版本）。所有业务层（1–5）最终都编译到这层之上。

---

## 二、模块识别（按层）

### 第 0 层：Framework Foundation（框架基座，`vendor/`）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| @deepseek-ai/cordis | `vendor/cordis` | 插件元框架核心（4.0.2，被 294 个包引用） | 输入：插件注册；输出：服务/事件/效果；依赖：cosmokit、schemastery |
| @deepseek-ai/cordis-plugin-loader | `vendor/loader` | 插件加载器（1.0.3，被 67 个包引用） | 输入：入口配置；输出：加载并挂载插件树；依赖：cordis、include |
| @deepseek-ai/schemastery | `vendor/schemastery` | 类型驱动 schema 校验器（3.18.2，被 132 个包引用） | 输入：配置声明；输出：校验后的配置；依赖：cosmokit |
| @deepseek-ai/cordis-plugin-include | `vendor/include` | 配置包含与 Patch 应用（1.0.7，被 44 个包引用） | 输入：include/`!!js` 配置；输出：展开的入口表；依赖：loader、js-yaml |
| @deepseek-ai/cosmokit | `vendor/cosmokit` | 通用工具集（1.8.3） | 输入：—；输出：常量/工具函数；依赖：无 |
| @deepseek-ai/cordis-plugin-timer | `vendor/timer` | 定时器服务（1.1.4） | 输入：定时任务声明；输出：到点回调；依赖：cordis |
| @deepseek-ai/cordis-plugin-hmr | `vendor/hmr` | 热模块替换（1.0.17） | 输入：模块变更事件；输出：热重载；依赖：cordis、esbuild |
| @deepseek-ai/cordis-plugin-group | `vendor/group` | 嵌套插件组（1.0.2） | 输入：插件组声明；输出：分组的生命周期；依赖：cordis |
| @deepseek-ai/cordis-plugin-logger-console | `vendor/logger-console` | 控制台日志导出（1.0.2） | 输入：日志事件；输出：控制台输出；依赖：cordis |

> 本地增强：vendor 层带 19 条本地修改记录（对上游的定制），涵盖 fiber 生命周期加固、懒配置解析、
> 配置写回 EACCES/EBUSY 重试、Node 兼容运行时形状检测等。（详见 `vendor/README.md`）

### 第 1 层：Input Sources（输入层）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| Web Frontend（Web UI） | `apps/web`, `packages/client/*` | 浏览器端应用与 React UI 组件集 | 输入：用户消息；输出：会话请求事件；依赖：client 运行时、core 事件 |
| CLI | `apps/cli` | `dsh` 命令行入口 | 输入：终端命令；输出：装配 profile 并启动进程；依赖：boot/app-boot、bundle |
| Desktop | `apps/desktop`, `apps/desktop-host` | Electron 桌面壳与 host | 输入：桌面交互；输出：经 IPC/管道接入后端；依赖：desktop-host、client 图 |
| ACP / SDK | `bundle/acp-app`, `bundle/sdk-app`, `python/sdk` | ACP 自动化端点与 SDK 服务 | 输入：ACP/JSON-RPC 请求；输出：agent 调用；依赖：sdk、base bundle |
| Webhook | `packages/webhook` | 认证投递与 Workspace Session 创建 | 输入：外部 webhook；输出：会话创建；依赖：api、core |

### 第 2 层：Gateway（网关层）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| api/gateway | `packages/api/gateway` | 流式远程协议（snapshot/event/journal/remote stream） | 输入：客户端连接；输出：会话/事件/快照流；依赖：core、session |
| API 控制器 | `packages/api/{session,workspace,terminal,settings}-controller` | HTTP/JSON 控制器 | 输入：REST 请求；输出：领域操作；依赖：core、gateway |
| app-boot / 装配 | `packages/boot/app-boot`, `bundle/*` | profile+bundle 插件树装配 | 输入：profile 声明；输出：运行中插件树；依赖：cordis、全部 bundle 行 |

### 第 3 层：Core Processing（核心处理层）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| core/agent + agent-loop | `packages/core/agent`, `packages/core/agent-loop` | Agent 接口与默认驱动（turn/step 状态机） | 输入：会话写入；输出：模型请求与工具调度；依赖：session、llm、system-prompt、tools |
| core/session | `packages/core/session` | 追加式 `SessionEvent` 日志与内存存储（被依赖 157 包） | 输入：领域事件；输出：持久化事件流；依赖：storage |
| core/system-prompt | `packages/core/system-prompt` | Prompt 段落与工具 schema 装配 | 输入：会话状态；输出：渲染后系统提示；依赖：session |
| llm | `packages/llm/llm` | 消息/流词汇与适配器接缝（被依赖 125 包） | 输入：模型历史；输出：LLM 流；依赖：core（事件）、协议扩展 |
| session 持久化 | `packages/session/*` | 会话投影、快照、压缩（compaction） | 输入：会话事件；输出：投影/历史；依赖：core、storage |
| subagent | `packages/subagent` | 子代理派生与进程驱动 | 输入：父 agent 请求；输出：子任务执行流；依赖：core、subprocess |

### 第 4 层：Tool Execution（工具执行层）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| core/tools | `packages/core/tools` | 作用域工具注册表与守卫执行管道（被依赖 67 包） | 输入：工具调用事件 tool/call；输出：tool/result；依赖：core、scope |
| 工具包 | `packages/fs`, `packages/shell`, `packages/subprocess`, `packages/terminal`, `packages/web`, `packages/mcp`, `packages/lsp`, `packages/computer-use` 等 | 各类宿主能力工具 | 输入：工具参数；输出：执行结果；依赖：core/tools、sandbox |
| 沙箱与安全 | `packages/sandbox`, `packages/ssh`, `packages/guard`, `packages/preset`, `native/landlock-run` | 沙箱执行、SSH 沙箱、权限预设、审批 | 输入：工具执行请求；输出：受控执行；依赖：subprocess、credentials |

### 第 5 层：External Systems（外部系统层）

| module_name | path | description | 职责 / 输入 / 输出 / 依赖 |
|---|---|---|---|
| LLM 供应商 | `packages/llm/llm-pi-ai` 等 + `vendor/*` | OpenAI 兼容与 DeepSeek 私有协议扩展 | 输入：模型请求；输出：流式补全；依赖：llm |
| 文件/SSH | `packages/fs`, `packages/ssh` | 本地与远端文件系统 | 输入：FS 调用；输出：文件结果；依赖：sandbox |
| 网络服务 | `packages/web/web-search-*`, `packages/webhook` | 搜索、抓取、webhook 投递 | 输入：搜索/抓取请求；输出：外部数据；依赖：web、api |
| 存储与凭证 | `packages/storage`, `packages/credentials` | 持久化存储与凭证管理 | 输入：读写请求；输出：安全存储；依赖：util/crypto、core |

---

## 三、代码规模统计（核心模块）

> packages 源码合计 ≈ 774,364 行（TS+TSX）
> vendor 框架层源码合计 ≈ **6,191 行**（TS，9 个包）

| 模块 | 代码行数 | 占比 |
|---|---:|---:|
| client（UI + 客户端运行时） | 199,953 | 25.82% |
| experimental（实验能力） | 72,111 | 9.31% |
| api（网关 + 控制器） | 46,677 | 6.03% |
| core（核心引擎） | 45,850 | 5.92% |
| session（会话管理） | 40,830 | 5.27% |
| llm（模型接入） | 37,058 | 4.79% |
| subagent（子代理） | 35,434 | 4.58% |
| extensions（扩展） | 23,466 | 3.03% |
| test-support（测试支撑） | 22,476 | 2.90% |
| session-query（会话查询） | 15,477 | 2.00% |
| typert（类型系统） | 15,314 | 1.98% |
| subprocess（子进程） | 15,258 | 1.97% |
| fs（文件系统） | 14,350 | 1.85% |
| context（上下文） | 12,590 | 1.63% |
| shell（Shell 工具） | 12,561 | 1.62% |
| 其余基础设施（sandbox/storage/util 等） | 244,559 | 31.58% |

### 框架基座（vendor）代码明细

| 包 | 代码行数（src TS） | 占比（vendor 内） |
|---|---:|---:|
| @deepseek-ai/cordis | 2,693 | 43.5% |
| @deepseek-ai/cordis-plugin-loader | 961 | 15.5% |
| @deepseek-ai/schemastery | 902 | 14.6% |
| @deepseek-ai/cosmokit | 477 | 7.7% |
| @deepseek-ai/cordis-plugin-hmr | 463 | 7.5% |
| @deepseek-ai/cordis-plugin-include | 343 | 5.5% |
| @deepseek-ai/cordis-plugin-timer | 147 | 2.4% |
| @deepseek-ai/cordis-plugin-logger-console | 145 | 2.3% |
| @deepseek-ai/cordis-plugin-group | 3 | <0.1% |
| **vendor 合计** | **6,191** | 100% |

> vendor 文件数：73（非 `node_modules`/`lib`），含构建产物 217 个。整体规模小、精干，作为被全仓引用的框架底座。

---

## 四、Git 修改热度分析（近 12 个月）

| 模块 | Commits | 贡献者 | 文件改动次数 | 热度 |
|---|---:|---:|---:|---|
| client | 3,420 | 39 | 22,100 | **HIGH** |
| core | 1,885 | 24 | 5,533 | **HIGH** |
| subagent | 1,113 | 22 | 4,086 | **HIGH** |
| host | 1,038 | 25 | 3,569 | **HIGH** |
| llm | 858 | 23 | 3,329 | **HIGH** |
| extensions | 625 | 26 | 782 | MEDIUM |
| bundle | 555 | 23 | 1,252 | MEDIUM |
| fs | 507 | 23 | 1,817 | MEDIUM |
| context | 490 | 18 | 1,239 | MEDIUM |
| session | 477 | 15 | 2,938 | MEDIUM |
| api | 459 | 20 | 1,864 | MEDIUM |
| code-runtime | 370 | 9 | — | MEDIUM |
| experimental | 359 | 16 | 1,956 | MEDIUM |
| subprocess | 346 | 16 | 1,592 | MEDIUM |
| goal | 332 | 17 | 907 | MEDIUM |
| test-support | 321 | 16 | 1,263 | MEDIUM |
| session-query | 316 | 18 | 1,057 | MEDIUM |
| hooks | 308 | 14 | 954 | MEDIUM |
| skill | 300 | 15 | 691 | MEDIUM |
| sandbox | 299 | 16 | 948 | MEDIUM |
| workflow | 274 | 13 | 933 | MEDIUM |
| util | 260 | 16 | 1,120 | MEDIUM |
| vendor（框架底座） | 85 | 9 | — | LOW |
| 其余（todo/preset/sdk/boot/acp 等） | — | — | — | LOW |

> 分类标准：commits ≥ 800 或改动次数 > 3,000 → HIGH；100 ≤ commits < 800 → MEDIUM；其余 → LOW。

---

## 五、影响面分析

| 模块 | impact_level | reason |
|---|---|---|
| core | **HIGH** | 被 454 个依赖关联引用、改动频繁（1,885 commits），且是 agent 生命周期的枢纽 |
| client | **HIGH** | 改动最频繁（3,420 commits / 22,100 文件改动），横跨 UI 与运行时，依赖面最广（out_degree 246） |
| session | **HIGH** | 被 147 个依赖引用，会话持久化是多数模块的输入来源 |
| llm | **HIGH** | 被 125 个依赖引用且持续演进（858 commits），模型接入面牵动全部 agent 流程 |
| api | **MEDIUM-HIGH** | 网关承担全部入口流量，稳定性关键（be 80 / out 112） |
| subagent | **MEDIUM-HIGH** | 1,113 commits 高频修改且向上承接 agent、向下依赖 subprocess |
| util / test-support | **MEDIUM** | util 被 223 个依赖引用（低层基础），test-support 影响测试全链路 |
| vendor（框架底座） | **MEDIUM-HIGH** | 被全仓 294 个包依赖（`@deepseek-ai/cordis`），底层框架任何变更都会波及全部业务层；本仓库已做源码级控制并带 19 条本地修改，属关键基础设施 |

---

## 六、数据流分析（主要调用链）

### 主流程（请求流向）
```text
Input Sources (Web UI / CLI / ACP / SDK / Webhook)
   → api/gateway (streaming) + app-boot (profile 装配)
   → core/agent agent-loop (turn/step 状态机)
   → llm/llm (model request → stream)
   → core/tools (tool/call → tools/pre-execute → tools/execute → tools/post-execute → tool/result)
   → 工具执行层 (fs/shell/subprocess/web/sandbox)
   → External Systems (LLM 供应商 / 文件 / 网络 / 存储)
```

### 事件异步流
- **Session events**（持久化事实）：追加至 `SessionEvent` 日志，经 `session/event` 广播，是跨 `turn/step/system|user|assistant/message/tool/*` 的持久事件（可重载保留）。
- **Agent events**（活体）：`agent/inbox|step|status|request|continuation`，携带 live Agent，obs 工作流中状态。
- **流式事件**：`agent/assistant-stream` 为进程内 start → chunk* → end 帧；completion 后一次性提交为单条消息或日志尝试；Web session-follow 是唯一远端消费者。
- **瀑布事件**（须 next() 委托）：`agent/pre-step`、`agent/request`、`llm/stream`、`tools/*`。

### 消息流向
- 输入经单个 inbox 进入驱动；注入的上下文在 inbox 中等待直到有消息唤醒。
- 每个 **step** = 一次模型请求 + 其调用的工具；每个 **turn** = 零或多个 step，输入被认领前打开、无欠债时关闭。
- 模型历史 `deriveMessages()` 从会话日志投影；`agent/assistant-stream` 提供 UI 增量。

---

## 七、依赖网络分析（Top 10）

### 被依赖最多模块（in_degree，组级）

| 排名 | module | in_degree | out_degree |
|---|---|---|---|
| 1 | core | 454 | 36 |
| 2 | util | 223 | 1 |
| 3 | llm | 154 | 63 |
| 4 | session | 147 | 72 |
| 5 | client | 107 | 246 |
| 6 | test-support | 101 | 57 |
| 7 | api | 80 | 112 |
| 8 | sandbox | 62 | 16 |
| 9 | subprocess | 54 | 6 |
| 10 | runtime-diagnostics | 47 | 0 |

### 依赖最多模块（out_degree，组级）

| 排名 | module | out_degree | in_degree |
|---|---|---|---|
| 1 | client | 246 | 107 |
| 2 | bundle | 206 | 2 |
| 3 | experimental | 160 | 0 |
| 4 | subagent | 143 | 30 |
| 5 | api | 112 | 80 |
| 6 | shell | 82 | 27 |
| 7 | session | 72 | 147 |
| 8 | llm | 63 | 154 |
| 9 | context | 60 | 12 |
| 10 | test-support | 57 | 101 |

### 中心模块（in+out 综合）

| 排名 | module | in_degree | out_degree | total | 定位 |
|---|---:|---:|---:|---:|---|
| 1 | core | 454 | 36 | 490 | 系统枢纽 |
| 2 | client | 107 | 246 | 353 | 消费/UI 枢纽 |
| 3 | util | 223 | 1 | 224 | 底层基石 |
| 4 | session | 147 | 72 | 219 | 核心状态层 |
| 5 | llm | 154 | 63 | 217 | 模型接缝 |
| 6 | bundle | 2 | 206 | 208 | 装配入口 |
| 7 | api | 80 | 112 | 192 | 网关 |
| 8 | subagent | 30 | 143 | 173 | 子代理枢纽 |
| 9 | test-support | 101 | 57 | 158 | 测试基建 |
| 10 | experimental | 0 | 160 | 160 | 实验层 |

> 包级细节：被依赖最多的单个包为 `@deepseek-ai/cordis`（**294**，来自 vendor 框架层）、`core/session`（157）、`@deepseek-ai/schemastery`（**132**，vendor）、`llm/llm`（125）、`core/agent`（102）。
> **vendor 框架层引用全景**：cordis 294、schemastery 132、loader 67、include 44、cosmokit 8、timer 7、group 4、hmr 3、logger-console 1。
> 即 `@deepseek-ai/cordis` 与 `@deepseek-ai/schemastery` 是全仓被依赖最多的两个单包，框架底座影响力远超业务包。

---

## 八、管理层摘要

1. **vendor 框架底座是全仓影响力最大的层**：`@deepseek-ai/cordis` 被 294 个包依赖、`schemastery` 被 132 个包依赖，位居包级被依赖榜前二；采用源码式 vendor + 19 条本地增强，实现对框架层的完全掌控。
2. **core 是业务层最核心模块**：被 454 个依赖关联引用（in_degree 第一），承担 agent 生命周期、会话日志与工具管道，是架构枢纽。
3. **client 占总代码量 25.8%（约 20 万行）**：53 个子包覆盖 Web/桌面 UI 与客户端运行时，是最大的产品面。
4. **api/gateway 承担所有入口流量**：流式协议 + 6 个 API 控制器包，是稳定性关键组件，建议重点保障。
5. **Git 近 12 个月高度活跃**：17,177 commits、58 贡献者，集中在 client/core/subagent/host/llm 五个模块（热度 HIGH）。
6. **everything-is-a-plugin 架构成熟**：基于自有 vendor Cordis，核心能力均可通过插件替换，extensions/profile/bundle 三层支撑扩展生态。
7. **依赖分层清晰**：vendor/框架 + core/util 为底层基石（被依赖榜前列），bundle/client 为装配/消费入口，依赖方向单向可靠。
8. **测试与质量基建投入大**：1,221 个测试文件 + agent-loop 测试工具包，test-support 被 101 个包依赖。
9. **安全体系内建**：sandbox/ssh/guard/preset + 原生 Landlock 沙箱，工具执行层默认受控。
10. **多端产品矩阵完整**：Web、CLI、桌面、ACP/SDK、Python SDK 五条产品线共用同一 harness 内核。
11. **项目具备典型 Agent 平台架构特征**：框架层→输入层→网关→核心处理→工具执行→外部系统的六层结构清晰，事件驱动 + 插件化，具备平台化演进基础。
