# deepseek-harness 关键路径流程图

> 生成日期：2026-09-16
> 依据：`packages/client/web/src/boot.ts`、`.zread/wiki` 架构文档（web-client-architecture / microkernel-design / event-producer-consumer-matrix / tool-registry-and-execution-pipeline）

---

## 1. Web UI 启动流程（Web UI Start）

> 依据：`docs/30-web-client-architecture.md`、`packages/client/web/src/boot.ts`
> 关键点：Host 注入 `WebBootGraph`（`window.__DSH_BOOT__`）→ 无框架启动内核 → 懒加载模块系统 → Cordis 插件激活 → UI Renderer 水合交接。

```mermaid
flowchart TD
    subgraph Host["Node Host 进程"]
        HW["Web Server /api routes"]
        CM["dsh-client-modules 扫描 dsh.client 清单"]
        BOOT2["生成 __DSH_BOOT__ WebBootGraph"]
        COMBO["生成 revisioned combo scripts<br/>SHA-1 内容寻址 + immutable 缓存"]
    end

    subgraph Browser["浏览器"]
        subgraph BootKernel["无框架启动内核 AppWebEntry"]
            READY["等待 __DSH_BOOT_READY__ gate"]
            ML["ClientModuleSystem<br/>window.__ModuleLoader__"]
            PREFETCH["并行预取 immediately 条目"]
            CL["挂载 vendored Cordis Loader"]
            CREATE["创建每条 plugin entry (fiber)"]
            ACTIVE["等待全部 entry 达 active 态"]
        end

        subgraph Seed["平台种子表（frozen shell-static）"]
            SEED["React / Cordis / store<br/>ui-slots / ui-primitives / dockkit"]
        end

        subgraph Mount["应用挂载"]
            RENDERER["uiRenderer.mount(container)<br/>依赖 fiber: scope.effect"]
            HYDRATE["捕获 data-dsh-boot DOM<br/>水合为初始 React 渲染"]
            LAYOUT["首次 useLayoutEffect<br/>替换为真实应用树"]
        end
    end

    BOOT2 -->|注入 __DSH_BOOT__| READY
    CM --> BOOT2
    HW -->|提供 /api| CONN["Client Connection RPC<br/>/api/{channel}/{endpoint}"]
    COMBO -->|按需加载 bundle| ML
    SEED -->|共享进每个 bundle| ML
    READY --> ML
    ML --> PREFETCH
    PREFETCH --> CL
    CL --> CREATE
    CREATE --> ACTIVE
    ACTIVE -->|dependency fiber 注入 uiRenderer| RENDERER
    RENDERER --> HYDRATE
    HYDRATE --> LAYOUT
    CONN -.-> HW
```

### 1.2 时序图（Web UI Start Sequence）

```mermaid
sequenceDiagram
    autonumber
    participant Server as Node Host
    participant Boot as AppWebEntry 启动内核
    participant ML as ClientModuleSystem
    participant Loader as Cordis Loader
    participant Renderer as uiRenderer
    participant App as React 应用树

    Server->>Boot: 注入 __DSH_BOOT__ WebBootGraph 与 __ModuleLoader__ 门面
    Boot->>Boot: 等待 __DSH_BOOT_READY__ gate
    Boot->>ML: 构建 ClientModuleSystem<br/>（分发表 + 静态种子表 + transport）
    Boot->>ML: 并行预取 immediately 条目
    ML-->>Boot: 按需加载 combo scripts<br/>（SHA-1 内容寻址 + immutable 缓存）
    Boot->>Loader: 挂载 vendored Cordis Loader
    Loader->>Loader: 创建每条 plugin entry（fiber 注入）
    Loader-->>Boot: 全部 entry 达 active 态
    Boot->>Renderer: dependency fiber 注入 uiRenderer<br/>并调用 mount(container)
    Renderer->>Renderer: 捕获 data-dsh-boot DOM 水合初始渲染
    Renderer->>App: 首次 useLayoutEffect 替换真实应用树
    App-->>Renderer: 应用就绪
```

---

## 2. Profile / Bundle / Patch 集成流程

> 依据：`docs/7-microkernel-design-profiles-bundles-and-composition.md`
> 关键点：三层模型 —— **profile**（运行什么）、**bundle**（如何分发/修补）、**组合后的 Cordis 树**（用哪些插件）；`applyEntryPatches` 将各层补丁按序叠到空根部。

```mermaid
flowchart TB
    subgraph Launcher[启动器 dsh CLI]
        CLI[dsh]
        ARGS[parseDshArgs<br/>--profile &lt;name&gt;]
    end

    subgraph Profile["Profile `$DSH_HOME/profiles/<name>`"]
        MANIFEST[package.json<br/>dsh.profile.bundles 有序数组]
        PATCH[用户 cordis.patch.yml]
        PNODE[profile node_modules<br/>外部插件]
    end

    subgraph Bundles[Bundle 包 @deepseek-ai/dsh-*]
        BASE[dsh-base<br/>~65 行插件：llm/session/agent/<br/>sandbox/tools/credentials...]
        WEB[dsh-web-app<br/>重述 system-prompt/tools +<br/>浏览器栈/server/controllers]
        HEAD[dsh-headless 一次性运行器]
        ACP[dsh-acp-app ACP stdio 桥]
        SDK[dsh-sdk-app JSON-RPC 服务]
    end

    subgraph Composition[补丁组合]
        ROOT[空 cordis.yml 根部]
        LAYERS[applyEntryPatches<br/>bundle → profile → home → --patch overlay]
        ENTRYINDEX[insert 行建立 id 索引<br/>后续 patch 可 configure/disable]
        JS[!!js 表达式由 Loader<br/>启动时求值]
        TREE[生效的 Cordis EntryTree]
    end

    CLI --> ARGS
    ARGS -->|profile 解析（双锚点）| MANIFEST
    MANIFEST -->|bundles 顺序| BASE
    MANIFEST -->|bundles 顺序| WEB
    MANIFEST -->|bundles 顺序| HEAD
    MANIFEST -->|bundles 顺序| ACP
    MANIFEST -->|bundles 顺序| SDK
    BASE -->|cordis.patch.yml insert| ROOT
    WEB -->|cordis.patch.yml 重述/insert| ROOT
    PATCH --> ROOT
    PNODE -.->|out-of-tree 插件| ROOT
    ROOT --> LAYERS
    LAYERS --> ENTRYINDEX
    LAYERS --> JS
    ENTRYINDEX --> TREE
    JS --> TREE
    TREE -->|启动并运行| RUN[应用进程]
```

> 说明：bundle 可声明 `patchReload`（`live` 热重组 / `startup` 启动时一次性应用）；`web` profile 为 `live`，`headless/acp/sdk/sdk-minimal` 为 `startup`。
> 组合顺序：空入口表 → 各 bundle 按 profile 中顺序 → profile 的 `cordis.patch.yml` → home 级 → `--patch` 覆盖层。某一行的插入会建立 id 索引，同层后续 patch 可配置或禁用该行。

### 2.2 时序图（Profile / Bundle / Patch Composition Sequence）

```mermaid
sequenceDiagram
    autonumber
    participant A as CLI<br/>dsh 启动器
    participant B as Profile 目录<br/>$DSH_HOME/profiles/(name)
    participant C as Bundle 包<br/>dsh-base / web-app / ...
    participant D as Cordis Loader
    participant E as 生效 Cordis EntryTree

    A->>A: parseDshArgs 解析 --profile
    A->>B: 读取 package.json 的 dsh.profile.bundles
    B-->>A: 返回 bundle 列表 + patchReload 模式
    loop 按 profile 中顺序遍历 bundles
        A->>C: 解析 bundle 名（双锚点：安装目录 → profile 目录）
        C-->>A: 返回 cordis.patch.yml（insert/重述补丁）
        A->>D: 收集补丁文档
    end
    A->>B: 读取用户 cordis.patch.yml
    A->>A: 叠加 home 级补丁 + --patch 覆盖层
    A->>D: applyEntryPatches 应用到空 cordis.yml 根部
    D->>D: insert 行建立 id 索引，允许后续 configure/disable
    D->>D: 求值 !!js 表达式（如 sandbox mode）
    D->>E: 生成并激活 EntryTree
    E-->>A: 应用进程启动就绪
```

---

## 3. 事件分发流程（Event Distribution）

> 依据：`docs/9-event-producer-consumer-matrix.md`
> 关键点：一套词汇、三种分发面（`ctx` / `ctx.events.dispatch()` / `emitAgentEvent` 融合调度器）；四种分发模式（emit / waterfall / parallel / serial）；**作用域过滤**使一个逻辑事件多对多路由。

```mermaid
flowchart TD
    subgraph Decl["事件声明层"]
        DECL["declare module '@deepseek-ai/cordis'<br/>typed + @mode 契约"]
        SURF1["ctx: emit / waterfall / serial / parallel"]
        SURF2["ctx.events.dispatch() 低层<br/>过滤回调+容纳单监听失败"]
        SURF3["emitAgentEvent 融合代理调度器<br/>注入 agent subject（作用域路由+主体不分裂）"]
    end

    subgraph Modes["四种分发模式 = 语义契约"]
        M1["emit 即发即弃观察<br/>无返回值"]
        M2["waterfall 环绕中间件<br/>可替换/短路: next()"]
        M3["parallel 等待扇出<br/>无否决"]
        M4["serial 顺序链<br/>聚合结果"]
    end

    subgraph Routing["作用域过滤投递"]
        SCOPED["Scoped 载体 scopeTarget<br/>沿 owner 链向上流动，绝不向下"]
        UNFILTER["tools/change, system-prompt/change<br/>故意全局 unfiltered"]
    end

    subgraph Splines["系统接缝脊柱"]
        AGENTSPINE["agent/* 循环扩展脊柱<br/>pre-step/request/turn-stopping"]
        TOOLSPINE["tools/* 执行管道策略脊柱<br/>pre-execute/execute/post-execute/result"]
        SESSIONSPINE["session/* 持久化投影脊柱<br/>flush/event"]
        OTHERS["system-prompt/* llm/* workflow/*<br/>各子系统接缝"]
        INTERNAL["internal/* Cordis 内部总线<br/>compaction/HMR/modules 监听"]
    end

    DECL --> SURF1
    DECL --> SURF2
    DECL --> SURF3
    SURF1 --> M1
    SURF1 --> M2
    SURF1 --> M3
    SURF1 --> M4
    SURF2 --> M1
    SURF3 --> M2
    SURF3 --> M4

    M1 --> AGENTSPINE
    M2 --> TOOLSPINE
    M2 --> OTHERS
    M3 --> SESSIONSPINE
    M4 --> AGENTSPINE

    SCOPED -.->|agent/* 按 agent 路由| AGENTSPINE
    UNFILTER -.->|全局变更| TOOLSPINE
    SURF2 -.->|events.dispatch 通知| INTERNAL
```

> 事件清单速览（部分）：
> - **agent 生命周族**：`agent/created`、`agent/status`（emit）、`agent/pre-step`（waterfall）、`agent/request`（waterfall）、`agent/turn-stopping`（serial）
> - **tool 门控链**：`tools/pre-execute`、`tools/execute`、`tools/post-execute`（waterfall）、`tools/result`（emit）、`tools/change`（全局）
> - **session 持久化**：`session/event` 追加流、`session/flush`（parallel）
> - **llm**：`llm/stream`（waterfall），重试/重放/路由
> - **框架内部**：`internal/dispatch`、`internal/plugin`、`internal/service`、`internal/status`

### 3.2 时序图（Event Dispatch Sequence）

```mermaid
sequenceDiagram
    autonumber
    participant Producer as 事件生产者<br/>agent-loop / tools / session
    participant Bus as Cordis 事件总线<br/>ctx / events.dispatch / emitAgentEvent
    participant Scope as 作用域过滤器 Scoped
    participant L1 as 监听器 A<br/>agent-instructions
    participant L2 as 监听器 B<br/>compaction
    participant L3 as 监听器 C<br/>webhook / UI 投影

    Producer->>Bus: dispatch 事件（agent/* 或 tools/* 或 session/*）
    Bus->>Bus: 按声明 @mode 选择契约<br/>emit / waterfall / parallel / serial
    alt waterfall 事件（如 agent/pre-step、tools/pre-execute）
        Bus->>L1: next() 委托
        L1-->>Bus: 允许 / 改写 / 短路
        Bus->>L2: next() 委托
        L2-->>Bus: 允许 / 拒绝
        Bus-->>Producer: 返回聚合结果
    else emit 事件（如 agent/status、tools/result）
        Bus->>Scope: 作用域过滤（沿 owner 链向上）
        Scope->>L1: 命中 scope 才投递
        Scope->>L2: 命中 scope 才投递
        Scope->>L3: 命中 scope 才投递
        L1-->>Bus: 观察 / 持久化（fire-and-forget）
    else parallel 事件（如 session/flush）
        Bus->>L1: 并发触发（无否决）
        Bus->>L2: 并发触发（无否决）
        L1-->>Bus: 排空完成
        L2-->>Bus: 排空完成
        Bus-->>Producer: 全部就绪后才继续
    end
```

---

## 4. 工具注册与执行管道（Tool Registry & Execution Pipeline）

> 依据：`docs/13-tool-registry-and-execution-pipeline.md`、`packages/core/tools/src/index.ts`
> 关键点：注册表（`@deepseek-ai/dsh-tools`）为中央权威；`ToolDefinition`（作者视角）→ `ToolSchema`（模型视角，仅 name/description/parameters）；作用域可见性解析；七阶段流水线。

```mermaid
flowchart TD
    subgraph Register["注册与可见性"]
        DEF["ToolDefinition<br/>schema + execute + output 契约<br/>+ finalizeContent + timeoutMs"]
        DSL["defineTool DSL 编译<br/>→ JsonSchemaNode 严格子集"]
        SCOPE["ctx.tools.register 作用域层<br/>全局 + 祖先 + 自身 shadow"]
        MASK["ctx.tools.restrict<br/>allow/deny 掩码链上交叉"]
        VIEW["ToolRuntime.view 投影<br/>→ ToolSchema: name/desc/params"]
        RESERVED["保留 run_code<br/>mode ≠ native 时注入"]
    end

    subgraph Pipeline["七阶段执行管道"]
        S1["Stage1 执行物化<br/>参数无损 JSON 快照/深冻结<br/>opaque 关联令牌 + PTC 折叠检查"]
        S2["Stage2 tools/pre-execute 瀑布<br/>allow/deny/ask 策略 + 审批接缝"]
        G["Stage3 单调守卫<br/>同步返回拒绝原因，不可被撤销"]
        S4["Stage4 tools/execute 环绕<br/>仅可替换 exec.signal + 超时策略"]
        BODY["Tool execute 主体<br/>resolveExecution 重应用可见映射"]
        NORM["规范化: snapshot-validate-render<br/>→ ToolExecutionResult"]
        S5["Stage5 tools/post-execute 瀑布<br/>accept / block / 附加 context"]
        S6["Stage6 finalizeContent<br/>最终仅内容不变式（恰好一次）"]
        S7["Stage7 tools/result 同步通知<br/>深冻结权威快照，不可变"]
    end

    subgraph Outcome["结果落账"]
        TOR["Session event: tool/result<br/>单一面相模型结果"]
        ADDCTX["additionalContexts FIFO<br/>注入下一模型请求"]
        UI["UI 卡片重建<br/>presentationMeta → presentCall/Result"]
        ERROR["错误码: TOOL_TIMEOUT<br/>ABORTED 或 ABORTED_BEFORE_DISPATCH"]
    end

    DEF --> DSL
    DSL --> SCOPE
    SCOPE --> MASK
    MASK --> VIEW
    VIEW --> RESERVED

    RESERVED --> S1
    S1 --> S2
    S2 -->|deny/approval 拒绝| ERROR
    S2 --> G
    G -->|denied| ERROR
    G --> S4
    S4 --> BODY
    BODY --> NORM
    NORM --> S5
    S5 --> S6
    S6 --> S7
    S7 --> TOR
    S7 --> UI
    S5 --> ADDCTX
    BODY -.->|PTC 嵌套调用折叠| VIEW
```

> 说明：
> - 无论入口路径（原生 loop / API 代理 / PTC 桥）都走同一七阶段管线；有序策略阶段串行，环绕调度/主体对并行调用可重叠。
> - 取消为协作式：主体调用前取消 → `ABORTED_BEFORE_DISPATCH`；主体启动后 → `ABORTED`（仅替换成功结局）。
> - PTC 模式（`ptc` presentation）：模型直接调用除 `run_code` 外工具 → `UNKNOWN_TOOL` 错误并给出替代路由提示。

### 4.2 时序图（Tool Registry Execution Pipeline Sequence）

```mermaid
sequenceDiagram
    autonumber
    participant Model as 模型 / agent-loop
    participant Registry as 工具注册表<br/>@deepseek-ai/dsh-tools
    participant Policy as pre-execute 策略<br/>hooks / 权限 / sandbox
    participant Guard as 单调守卫
    participant Wrapper as execute 环绕<br/>timeout / retry
    participant Tool as 工具 execute 主体
    participant Post as post-execute 监听

    Model->>Registry: execute(call) 进入管线
    Registry->>Registry: Stage1 物化参数快照/深冻结<br/>分配关联令牌 + PTC 折叠检查
    Registry->>Policy: tools/pre-execute 瀑布
    alt deny 或 approval 拒绝
        Policy-->>Registry: deny 结果（附明确原因）
        Registry-->>Model: TOOL_ERROR / UNKNOWN_TOOL
    else ask 需审批
        Policy-->>Registry: 请求审批接缝<br/>无审批服务降级为 deny
    else 通过
        Policy-->>Registry: allow
        Registry->>Guard: Stage3 单调守卫（不可撤销）
        alt 任一守卫 denied
            Guard-->>Registry: 拒绝
            Registry-->>Model: 结构化错误
        else 全部 abstain
            Guard-->>Registry: 放行
            Registry->>Wrapper: tools/pre-execute 环绕<br/>仅可替换 exec.signal + 超时
            Wrapper->>Tool: Stage4 execute 主体<br/>(resolveExecution 重应用可见映射)
            Tool-->>Wrapper: 返回规范无损 JSON 值
            Wrapper-->>Registry: 快照-验证-渲染 → ToolExecutionResult
            Registry->>Post: Stage5 tools/post-execute
            alt accept / 替换内容
                Post-->>Registry: 接受或改写
            else block
                Post-->>Registry: 转为纠正性错误
            end
            Registry->>Registry: Stage6 finalizeContent（恰好一次的仅内容不变式）
            Registry->>Model: Stage7 tools/result 深冻结同步通知
            Registry->>Registry: additionalContexts FIFO 注入下轮请求
        end
    end
```

---

## 附录：四条关键路径的关系

```mermaid
flowchart LR
    A[1 Web UI Start<br/>浏览器 boot → UI mount] --> B[2 Profile/Bundle/Patch<br/>装配 Cordis 插件树]
    A --> C[3 Event Distribution<br/>事件总线驱动 UI 状态]
    B --> D[4 Tool Registry Pipeline<br/>agent loop 内工具执行]
    C --> D
```

1. **Web UI Start** 提供前端与浏览端运行时；
2. **Profile/Bundle/Patch** 决定 Host 端装配哪些插件层（含 `dsh-base` 里注册的工具）。
3. 运行后，**Event Distribution** 广播 agent/session/tool 事件驱动 UI 增量与持久化；
4. 每一轮 agent loop 内模型请求触发 **Tool Registry** 七阶段执行管道。
