# DSH + @loongsuite/dsh-plugin + Langfuse 内网自建 LLM 可观测平台：完整设计方案与工程落地深度分析

> **适用场景**：200 人规模研发团队，以 DeepSeek Harness（DSH）作为内部 AI 编码 Agent，数据安全要求严格，所有遥测数据须在内网闭环，不得上传公网。

---

## 目录

1. [背景与问题定义](#1-背景与问题定义)
2. [技术栈全景与组件定位](#2-技术栈全景与组件定位)
3. [架构设计方案（High-Level）](#3-架构设计方案high-level)
4. [@loongsuite/dsh-plugin 插件深度解析](#4-loongsuitedsh-plugin-插件深度解析)
5. [Langfuse 自建服务技术原理与内网部署](#5-langfuse-自建服务技术原理与内网部署)
6. [端到端数据流与控制流](#6-端到端数据流与控制流)
7. [工程落地细节：完整配置规程](#7-工程落地细节完整配置规程)
8. [容量规划与性能调优](#8-容量规划与性能调优)
9. [安全加固与数据零出网保障](#9-安全加固与数据零出网保障)
10. [可观测能力矩阵：能看到什么](#10-可观测能力矩阵能看到什么)
11. [分阶段实施路线图](#11-分阶段实施路线图)
12. [常见问题与故障排查](#12-常见问题与故障排查)
13. [参考资料](#13-参考资料)

---

## 1. 背景与问题定义

### 1.1 为什么日志不够用

DeepSeek Harness（DSH）是 DeepSeek 开源的编码 Agent 运行时，采用"一切皆插件"的 Cordis 架构，内置完整的 Session 事件流记录——包含 Turn、Step、工具调用、模型消息和流式增量 [1]。这些 append-only 的结构化日志非常适合审计、复盘和事实排查，但它们是一串按时间排列的扁平事件，本质上无法直接回答以下问题：

- 这一轮任务为什么花了 47 秒？时间卡在模型推理阶段还是工具执行等待？
- 同一个 Step 中模型是否触发了重试？每次重试的 Token 消耗分别是多少？
- 主 Agent 与 Subagent 之间的执行关系和成本占比如何分布？
- 过去 7 天，DeepSeek-R1 的 P95 延迟曲线走势是什么？

回答这些问题需要的是**一棵带父子关系和时间区间的调用树（Trace）**，而不是一串时间点（Log）。Logs 与 Trace 不是二选一的关系，而是回答不同问题的两种数据形态：日志保留完整事件账本，Trace 提供适合性能、错误和成本分析的结构化投影 [2]。

### 1.2 团队约束与核心需求

本方案面向的团队具有以下约束条件：

| 约束维度 | 具体要求 |
| :--- | :--- |
| **团队规模** | 约 200 名研发工程师，日常使用 DSH 作为 AI 编码助手 |
| **网络隔离** | 单向出网隔离：有下行通路（可拉取镜像），但所有遥测数据不得上传公网 |
| **数据主权** | Prompt、Completion、工具参数、Token 统计等全部数据须留存内网 |
| **侵入性** | 业务代码零修改，通过插件配置完成接入 |
| **运维负担** | 可接受维护一套内网服务集群，但希望架构尽量精简 |

基于上述约束，技术选型的核心判断是：选择**路线 A——@loongsuite/dsh-plugin 独立插件直发 OTLP**，而非需要额外部署本地 daemon 进程的路线 B（LoongSuite Pilot）[2]。

---

## 2. 技术栈全景与组件定位

本方案涉及三个核心技术组件，它们在整个可观测管道中扮演截然不同的角色。

### 2.1 组件角色映射

```
┌─────────────────────────────────────────────────────────────────┐
│                     数据生产端（客户端）                          │
│                                                                 │
│  DSH Agent Runtime                                              │
│  ├── Cordis 插件体系                                             │
│  └── @loongsuite/dsh-plugin  ← 传感器：采集、构建 Trace 树        │
│       └── OTel BatchSpanProcessor（内存环形缓冲区）               │
└──────────────────────────┬──────────────────────────────────────┘
                           │ OTLP/HTTP (protobuf)
                           │ 内网直连，无中间代理
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                     数据消费端（服务端）                          │
│                                                                 │
│  Langfuse 自建集群（内网）                                        │
│  ├── Web/API Server  ← 接收 OTLP，鉴权，入队                     │
│  ├── Worker          ← 解析 GenAI 语义，计算成本，落盘            │
│  ├── Redis           ← 削峰填谷消息队列                           │
│  ├── ClickHouse      ← 海量 Trace/Span OLAP 存储                 │
│  ├── PostgreSQL      ← 元数据、API Key、Prompt 版本               │
│  └── MinIO           ← 超大 Payload 对象存储                     │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 三组件技术定位对比

| 组件 | 本质定位 | 在本方案中的角色 | 关键技术特性 |
| :--- | :--- | :--- | :--- |
| **DSH** | AI 编码 Agent 运行时 | 被观测对象，提供生命周期事件钩子 | Cordis 插件体系，支持热更新 |
| **@loongsuite/dsh-plugin** | DSH 原生 Cordis 插件（Apache-2.0） | 数据生产者：在 DSH 进程内构建标准 GenAI Trace 树 | 无侵入、后端无关、OTel 标准 OTLP 输出 |
| **Langfuse（自建）** | LLM 垂直工程平台（MIT 开源） | 数据消费者：接收 OTLP、持久化、可视化、评估 | ClickHouse OLAP + Postgres，原生理解 GenAI 语义 |

### 2.3 为什么不需要 OTel Collector

在本方案中，**刻意省略了 OTel Collector 中间层**，这是一个有意识的架构决策。OTel Collector 的核心价值在于：多后端分流（Fan-out）、数据脱敏（PII Masking）、跨网络安全边界传输，以及多 Agent 数据聚合。而在本场景中：

- 只有 DSH 一种 Agent，无需多 Agent 聚合
- 内网环境无跨 VPC 安全边界问题
- 脱敏可在插件层（`captureContent: false`）完成
- 引入 Collector 会增加一个需要维护的有状态进程

因此，插件直连 Langfuse 是链路最短、运维负担最低的选择 [2]。

---

## 3. 架构设计方案（High-Level）

### 3.1 网络拓扑与安全边界

整个系统分为两个网络区域，通过防火墙实现单向隔离：

```mermaid
flowchart TD
    subgraph DevZone["研发内网区（200 人客户端）"]
        direction TB
        Dev1["工程师 A\nDSH + @loongsuite/dsh-plugin"]
        Dev2["工程师 B\nDSH + @loongsuite/dsh-plugin"]
        DevN["工程师 N\nDSH + @loongsuite/dsh-plugin"]
    end

    subgraph FW["网络边界控制"]
        Firewall["防火墙\n出公网流量全部 DROP\n仅允许下行（镜像拉取）"]
    end

    subgraph ServerZone["内网可观测服务区"]
        direction TB
        LB["Nginx 内网反向代理\n:3000 Web UI\n:3000/api/public/otel OTLP 接收"]
        
        subgraph LFCore["Langfuse 核心服务"]
            LFWeb["Langfuse Web/API Server\n(Next.js)"]
            LFWorker["Langfuse Worker\n(GenAI 语义解析 + 成本计算)"]
            Redis[("Redis\nBullMQ 队列")]
        end

        subgraph Storage["私有化混合存储"]
            PG[("PostgreSQL\n用户、API Key、Prompt 版本")]
            CK[("ClickHouse\nTraces、Spans、Token 统计\nOLAP 列式压缩存储")]
            MinIO[("MinIO\n超大 Payload 对象存储\nS3 兼容")]
        end

        LB --> LFWeb
        LFWeb --> Redis
        Redis --> LFWorker
        LFWorker --> CK
        LFWorker --> PG
        LFWorker --> MinIO
        LFWeb --> PG
        LFWeb --> CK
    end

    Dev1 -->|"内网 OTLP/HTTP\n批处理直连"| LB
    Dev2 -->|"内网 OTLP/HTTP\n批处理直连"| LB
    DevN -->|"内网 OTLP/HTTP\n批处理直连"| LB

    DevZone -.->|"禁止出公网"| Firewall
```

### 3.2 核心设计原则

本方案遵循三条核心设计原则，每条原则都有明确的工程实现对应：

**原则一：数据零外溢（Data Sovereignty）**。所有遥测数据的生命周期从 DSH 进程内的内存缓冲区开始，经内网 TCP 连接到达 Langfuse 服务端，最终落盘于内网 ClickHouse 和 PostgreSQL，全程不经过任何公网节点。这一原则通过两项配置强制保障：Langfuse 服务端设置 `TELEMETRY_ENABLED=false` 禁止向 PostHog Cloud 发送匿名统计 [3]；客户端 OTLP 端点硬编码为内网地址，防火墙层面阻断所有出公网流量。

**原则二：客户端零侵入（Zero Application Intrusion）**。工程师的业务代码无需任何修改。接入通过两个配置文件完成：DSH Profile 目录下的 `cordis.patch.yml` 声明插件配置，系统级环境变量文件注入 OTLP 端点和鉴权信息。整个接入过程对 DSH 的 Agent 核心循环完全透明，插件的导出失败会被隔离，不会影响模型调用和工具执行 [1]。

**原则三：计算与 I/O 解耦（Async Decoupling）**。客户端插件内置 OTel BatchSpanProcessor，在后台线程维护内存环形缓冲区，按时间窗口（默认约 1 秒）或容量阈值批量推送，将遥测对 Agent 决策延迟的影响压缩至微秒级。服务端通过 Redis（BullMQ）队列进一步削峰，Ingestion API 完成鉴权后立即返回 HTTP 202，不阻塞客户端。

---

## 4. @loongsuite/dsh-plugin 插件深度解析

### 4.1 插件定位与设计哲学

`@loongsuite/dsh-plugin` 是阿里云可观测团队基于 LoongSuite 框架为 DSH 开发的独立开源插件，于 2026 年 8 月 17 日发布正式版 `0.1.1` [1]，并已被 DSH 社区插件市场收录。其设计哲学体现在以下几个关键决策上：

该插件与 DSH 官方内置的 `dsh-session-telemetry-otel` 插件存在本质区别。官方插件输出的是 **OTLP Logs**（结构化事件流），适合保留权威的 Session 事件账本；而 `@loongsuite/dsh-plugin` 输出的是 **OTLP Traces**（父子 Span 树），专门补齐 Agent/Step/LLM/Tool 的层级关系、Trace Context 传播和 GenAI Metrics [1]。两者可以同时运行，互不干扰，分别回答不同维度的问题。

### 4.2 Trace 树结构与 Span 语义

插件直接监听 DSH 的 Session、Turn、Step、`llm/stream` 和 Tool 生命周期事件，在 DSH 进程内构建标准的五层 GenAI Trace 树 [4]：

```
enter_ai_application_system          (ENTRY)  ← 一次 Turn 的根 Span，计时整轮耗时
  └── invoke_agent deepseek-harness  (AGENT)  ← Agent 循环，汇总 Turn 级 Token 总量
       ├── react step                (STEP)   ← 一次推理轮次（ReAct 循环单次迭代）
       │    ├── chat deepseek-r1     (LLM)    ← 一次真实模型调用（含 TTFT、Token）
       │    └── execute_tool bash    (TOOL)   ← 一次工具执行（含耗时、错误状态）
       └── react step                (STEP)   ← 下一次推理轮次
            └── chat deepseek-r1    (LLM)    ← 每次真实调用独立 Span，重试可见
```

每个 LLM Span 携带完整的 OpenTelemetry GenAI Semantic Conventions 标准属性 [5]：

| 标准属性键 | 数据类型 | 含义 |
| :--- | :--- | :--- |
| `gen_ai.system` | string | 模型服务标识（如 `deepseek`） |
| `gen_ai.request.model` | string | 请求的模型名称 |
| `gen_ai.response.model` | string | 实际响应的模型规格 |
| `gen_ai.usage.input_tokens` | int | Prefill 阶段处理的 Prompt Token 数 |
| `gen_ai.usage.output_tokens` | int | Decode 阶段生成的 Token 数 |
| `gen_ai.usage.reasoning_tokens` | int | 思考链（CoT）消耗的中间 Token |
| `gen_ai.usage.cache_read_input_tokens` | int | 命中 KV Cache 节省的输入 Token |
| `gen_ai.response.time_to_first_token` | double | 首 Token 延迟（TTFT，毫秒） |
| `gen_ai.response.finish_reasons` | string[] | 生成结束原因（stop/length/tool_calls） |
| `gen_ai.span.kind` | string | Span 类型（ENTRY/AGENT/STEP/LLM/TOOL） |
| `dsh.session.id` | string | DSH Session 标识符 |
| `dsh.session.cwd` | string | Agent 工作目录（即使关闭内容采集也会记录） |

**重要注意事项**：AGENT Span 会重复汇总其下所有 LLM Span 的 Token 总量，因此在 Langfuse 中进行 Token 聚合查询时，必须添加过滤条件 `gen_ai.span.kind = 'LLM'`，否则会产生 2 倍的重复计数 [4]。

### 4.3 内容采集的隐私边界

插件的 `captureContent` 配置项控制是否将 Prompt、Completion、工具定义、参数和结果写入 Span 属性。**默认值为 `false`**，这是一个对内网安全场景友好的保守默认值。

关闭内容采集后，单次 Turn 的 Span payload 从约 73,078 字节降至约 6,350 字节（约 11.6 倍压缩）[4]，这对于 200 人高频使用场景下的网络带宽和存储成本都有显著意义。在数据不出内网的场景下，可以根据需要开启内容采集，但需要注意 `dsh.session.cwd` 字段始终会记录工作目录，即使内容采集关闭。

---

## 5. Langfuse 自建服务技术原理与内网部署

### 5.1 为什么选择 Langfuse 而非通用 APM

Langfuse 与 Jaeger、Grafana Tempo、SigNoz 等通用 APM 工具的本质区别在于**对 LLM 业务语义的原生理解能力**。通用 APM 对 Span 的理解止步于"一根横条和一堆 Key-Value 标签"，无法计算 Token 成本、无法折叠思考链、无法按模型维度聚合 P95 延迟。Langfuse 在 ClickHouse 和 PostgreSQL 之上构建了专门针对 AI 工作流的数据模型，天然理解 Chat/Generation/Tool Execution 的语义区别 [6]。

此外，Langfuse 于 2026 年 1 月被 ClickHouse 收购后，核心平台仍保持 MIT 许可证完全开源，自建部署无软件成本 [7]。

### 5.2 核心技术架构

Langfuse 的内部架构由五个层次组成，各层职责严格分离：

**接入层**：Langfuse Web/API Server（Next.js）暴露两个关键端点：`/api/public/otel`（OTLP 接收端点，接受 HTTP/protobuf 和 HTTP/JSON，**不支持 gRPC** [8]）和 `:3000`（Web UI）。完成 API Key 鉴权后，Ingestion API 将 Payload 压入 Redis 队列并立即返回 HTTP 202，端到端延迟通常在 10ms 以内。

**缓冲层**：Redis（BullMQ）作为削峰填谷的消息队列，解耦 Ingestion API 与后端处理，保障服务端在 200 人高并发写入时不压垮数据库。

**处理层**：Langfuse Worker 从 Redis 消费任务，执行三项核心操作：解析 `gen_ai.*` GenAI 语义标签、匹配模型计费字典计算成本（`Total Cost = Input Tokens × Input Rate + Output Tokens × Output Rate + Reasoning Tokens × Reasoning Rate`）、提取 Trace/Span 树级拓扑与 ParentID。

**存储层**：采用双存储引擎分工策略——PostgreSQL 负责强一致性事务场景（用户、API Key、Prompt 版本等元数据）；ClickHouse 承载所有高频分析型检索（Trace 过滤、Token 成本聚合、P95 延迟时序）。ClickHouse 的列式存储通常能实现 5:1 到 10:1 的压缩比，并通过向量化执行引擎（SIMD）实现亿级 Span 的秒级聚合 [6]。

**对象存储层**：MinIO（S3 兼容）存储超大 Payload（单次超过 1MB 的 Prompt/Completion 文本）和批量导出文件。

### 5.3 OTLP 接入端点规范（v4）

Langfuse v4 对 OTLP 接入做了重要升级，引入了实时摄入机制 [8]：

- **端点路径**：`http://<host>:3000/api/public/otel`（基础路径）
- **Trace 子路径**：`/api/public/otel/v1/traces`
- **鉴权方式**：HTTP Basic Auth，格式为 `base64(public_key:secret_key)`
- **实时摄入头**：必须携带 `x-langfuse-ingestion-version: 4`，否则数据可能延迟最多 10 分钟才出现在 UI 中

### 5.4 内网隔离部署的关键配置

在内网隔离场景下，Langfuse 自建部署有几个必须关注的配置项：

Langfuse OSS 版本默认会向 PostHog Cloud 发送匿名的聚合使用统计（包含版本号、项目数、Trace 总量等，**不包含原始 Trace 数据**）[3]。在内网隔离环境中，必须在所有 Langfuse 容器上设置 `TELEMETRY_ENABLED=false` 来禁用此行为。需要注意的是，Enterprise 版本的遥测用于许可证合规，无法禁用；因此本方案选用 OSS（MIT）版本。

此外，官方部署模板默认使用 `docker.langfuse.com/langfuse/langfuse` 作为镜像地址，该域名会统计镜像拉取次数。在内网环境中，应替换为 `docker.io/langfuse/langfuse`（即 Docker Hub 直连），并通过具有下行通路的堡垒机预先拉取后推入内网私有镜像仓库 [3]。

---

## 6. 端到端数据流与控制流

### 6.1 数据流（Data Plane）：Trace 从产生到落盘

以下是一次完整 DSH Turn 的遥测数据从产生到在 Langfuse UI 可见的完整时序：

```mermaid
sequenceDiagram
    autonumber
    participant DSH as DSH Agent Runtime
    participant Plugin as @loongsuite/dsh-plugin
    participant Buf as OTel BatchSpanProcessor<br/>(内存环形缓冲区)
    participant LFApi as Langfuse Web/API<br/>(Next.js)
    participant Redis as Redis (BullMQ)
    participant Worker as Langfuse Worker
    participant CK as ClickHouse OLAP
    participant PG as PostgreSQL

    DSH->>Plugin: Session Turn 开始（Hook 触发）
    Note over Plugin: 创建 ENTRY Span，记录 TraceID
    DSH->>Plugin: LLM 调用完成（含 Token 统计）
    Note over Plugin: 创建 LLM Span，填充 gen_ai.* 属性
    DSH->>Plugin: Tool 执行完成（含耗时、错误状态）
    Note over Plugin: 创建 TOOL Span，设置错误状态
    DSH->>Plugin: Turn 结束
    Note over Plugin: 关闭 ENTRY Span，Span 进入缓冲区

    Plugin->>Buf: Span 入队（内存环形缓冲区）
    Note over Buf: 等待时间窗口（~1s）或容量阈值

    Buf->>LFApi: POST /api/public/otel/v1/traces<br/>(OTLP/HTTP protobuf 批量推送)
    Note over LFApi: 验证 Basic Auth API Key<br/>快速返回 HTTP 202
    LFApi->>Redis: 将 Payload 压入 Ingestion Queue

    Redis->>Worker: 消费遥测任务
    Note over Worker: 1. 解析 gen_ai.* 语义标签<br/>2. 匹配模型计费字典，计算 Cost<br/>3. 提取 Trace/Span 父子拓扑

    par 并行落盘
        Worker->>CK: 批量写入 traces/observations 表
        Worker->>PG: 更新会话摘要元数据
    end
```

### 6.2 控制流（Control Plane）：Prompt 管理与评估回环

Langfuse 的控制流使其超越了单纯的日志查看器，形成了完整的 LLM 质量治理闭环：

```mermaid
sequenceDiagram
    autonumber
    participant Admin as Tech Lead / SRE
    participant PG as PostgreSQL
    participant Worker as Langfuse Eval Worker
    participant JudgeLLM as 评估模型（内网部署）
    participant CK as ClickHouse OLAP

    Note over Admin, CK: 场景 1：Prompt 版本管理与动态下发
    Admin->>PG: 在 Web 界面发布新版 System Prompt（v2.1）
    Note over PG: 版本控制，支持生产/测试分支

    Note over Admin, CK: 场景 2：LLM-as-a-Judge 自动评估
    Admin->>PG: 创建评估规则（检测 Agent 输出是否包含幻觉）
    CK-->>Worker: 新 Trace 写入触发评估任务
    Worker->>PG: 读取激活的评估规则与打分 Prompt
    Worker->>JudgeLLM: 调用评估模型（输入：Trace 的 Prompt + Completion）
    JudgeLLM-->>Worker: 返回评分（Score: 0.92, Reason: "逻辑闭环"）
    Worker->>CK: 将评分持久化写入 Scores 表（挂载到 TraceID）
    Admin->>CK: UI 展示评估大盘趋势与异常 Trace 告警
```

---

## 7. 工程落地细节：完整配置规程

### 7.1 前置准备：离线镜像交付（Air-Gapped）

由于内网无法直接访问公网 Docker Registry，需要通过具有下行通路的堡垒机完成镜像的拉取和转推。以下是需要准备的完整镜像清单：

| 镜像 | 用途 | 建议版本 |
| :--- | :--- | :--- |
| `docker.io/langfuse/langfuse` | Langfuse Web/API Server | latest（v4+） |
| `docker.io/langfuse/langfuse-worker` | Langfuse 后台 Worker | latest（v4+） |
| `clickhouse/clickhouse-server` | OLAP 数据库 | 24.3-alpine |
| `postgres` | 元数据存储 | 16-alpine |
| `redis` | 消息队列与缓存 | 7-alpine |
| `minio/minio` | S3 兼容对象存储 | RELEASE.2024-xx |

在堡垒机上执行镜像转推：

```bash
# 拉取并重新标记为内网镜像仓库地址
docker pull docker.io/langfuse/langfuse:latest
docker tag docker.io/langfuse/langfuse:latest registry.corp.local/langfuse/langfuse:latest
docker push registry.corp.local/langfuse/langfuse:latest
# 对其余镜像重复上述操作
```

### 7.2 服务端部署：生产级 Docker Compose

以下是针对内网隔离场景优化的完整 `docker-compose.yml` 配置，所有关键安全配置均已内联注释：

```yaml
version: '3.8'

services:
  langfuse-server:
    image: registry.corp.local/langfuse/langfuse:latest
    restart: always
    ports:
      - "3000:3000"    # Web UI 与 OTLP 接收端点（/api/public/otel）
    environment:
      # 数据库连接
      - DATABASE_URL=postgresql://lf_user:${PG_PASSWORD}@postgres:5432/langfuse
      - CLICKHOUSE_MIGRATION_URL=clickhouse://clickhouse:9000
      - CLICKHOUSE_URL=http://clickhouse:8123
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=${CK_PASSWORD}
      - CLICKHOUSE_CLUSTER_ENABLED=false     # 单节点部署必须设为 false
      - REDIS_CONNECTION_STRING=redis://redis:6379
      # MinIO 对象存储（S3 兼容）
      - LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse-events
      - LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=http://minio:9000
      - LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}
      - LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}
      - LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true   # MinIO 必须开启
      - LANGFUSE_S3_MEDIA_UPLOAD_BUCKET=langfuse-media
      - LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT=http://minio:9000
      - LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}
      - LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}
      - LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE=true
      # 认证配置
      - NEXTAUTH_URL=http://langfuse-internal.corp.local:3000
      - NEXTAUTH_SECRET=${NEXTAUTH_SECRET}   # 随机高熵字符串，至少 32 位
      - AUTH_DISABLE_SIGNUP=true             # 关闭公开注册，仅管理员可创建账号
      # 关键安全配置：禁止向公网发送匿名统计
      - TELEMETRY_ENABLED=false
    depends_on:
      - postgres
      - clickhouse
      - redis
      - minio

  langfuse-worker:
    image: registry.corp.local/langfuse/langfuse-worker:latest
    restart: always
    environment:
      - DATABASE_URL=postgresql://lf_user:${PG_PASSWORD}@postgres:5432/langfuse
      - CLICKHOUSE_URL=http://clickhouse:8123
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=${CK_PASSWORD}
      - CLICKHOUSE_CLUSTER_ENABLED=false
      - REDIS_CONNECTION_STRING=redis://redis:6379
      - LANGFUSE_S3_EVENT_UPLOAD_BUCKET=langfuse-events
      - LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=http://minio:9000
      - LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}
      - LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}
      - LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE=true
      - TELEMETRY_ENABLED=false
    depends_on:
      - redis
      - postgres
      - clickhouse

  clickhouse:
    image: registry.corp.local/infra/clickhouse-server:24.3-alpine
    restart: always
    environment:
      - CLICKHOUSE_DB=default
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=${CK_PASSWORD}
    volumes:
      - /data/clickhouse:/var/lib/clickhouse
      - ./clickhouse-config.xml:/etc/clickhouse-server/config.d/custom.xml:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144

  postgres:
    image: registry.corp.local/infra/postgres:16-alpine
    restart: always
    environment:
      - POSTGRES_USER=lf_user
      - POSTGRES_PASSWORD=${PG_PASSWORD}
      - POSTGRES_DB=langfuse
    volumes:
      - /data/postgres:/var/lib/postgresql/data

  redis:
    image: registry.corp.local/infra/redis:7-alpine
    restart: always
    volumes:
      - /data/redis:/data

  minio:
    image: registry.corp.local/infra/minio:latest
    restart: always
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=${MINIO_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${MINIO_SECRET_KEY}
    volumes:
      - /data/minio:/data
    ports:
      - "9090:9000"    # MinIO API（仅内网访问）
      - "9001:9001"    # MinIO Console（仅内网访问）
```

配套的 `.env` 文件（**不得提交到代码仓库**）：

```bash
PG_PASSWORD=<随机高熵密码，至少 24 位>
CK_PASSWORD=<随机高熵密码，至少 24 位>
MINIO_ACCESS_KEY=<随机 Access Key>
MINIO_SECRET_KEY=<随机 Secret Key，至少 32 位>
NEXTAUTH_SECRET=<随机高熵字符串，至少 32 位>
```

### 7.3 ClickHouse 性能调优配置

针对 200 人规模的写入压力，需要创建 `clickhouse-config.xml` 进行参数优化：

```xml
<clickhouse>
  <profiles>
    <default>
      <!-- 防止单次聚合查询耗尽内存 -->
      <max_memory_usage>20000000000</max_memory_usage>
      <!-- 优化批量写入性能，防止 Too Many Parts 异常 -->
      <max_insert_block_size>1048576</max_insert_block_size>
      <parts_to_delay_insert>150</parts_to_delay_insert>
      <parts_to_throw_insert>300</parts_to_throw_insert>
    </default>
  </profiles>
  <max_server_memory_usage>21474836480</max_server_memory_usage>
</clickhouse>
```

服务启动并完成初始化后，为 Trace 数据表配置 30 天 TTL 自动清理策略（可根据合规要求调整）：

```sql
-- 连接到 ClickHouse 执行（Langfuse 会自动创建这些表）
ALTER TABLE observations MODIFY TTL created_at + INTERVAL 30 DAY;
ALTER TABLE traces MODIFY TTL timestamp + INTERVAL 30 DAY;
```

### 7.4 MinIO 存储桶初始化

Langfuse 启动前需要预先创建必要的存储桶：

```bash
# 使用 MinIO Client（mc）初始化存储桶
docker run --rm --network host \
  minio/mc:latest \
  alias set local http://localhost:9090 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}

docker run --rm --network host minio/mc:latest mb local/langfuse-events
docker run --rm --network host minio/mc:latest mb local/langfuse-media
```

### 7.5 客户端插件安装与配置

**步骤一：安装插件到 DSH Profile**

```bash
# 为 Web Profile 安装（浏览器界面模式）
dsh plugin --profile web add @loongsuite/dsh-plugin

# 为 headless Profile 安装（命令行/自动化模式）
dsh plugin --profile headless add @loongsuite/dsh-plugin

# 验证安装
dsh --profile web --dump-config | grep loongsuite
# 应输出：id: loongsuite-observability
```

**步骤二：配置 OTLP 端点（cordis.patch.yml 方式，推荐）**

在 `$DSH_HOME/profiles/web/cordis.patch.yml`（默认 `~/.dsh/profiles/web/cordis.patch.yml`）中添加：

```yaml
- id: loongsuite-observability
  config:
    # 指定完整 Trace 端点（Langfuse 不接收 OTLP Metric，因此使用 traceEndpoint）
    traceEndpoint: http://langfuse-internal.corp.local:3000/api/public/otel/v1/traces
    serviceName: dsh-agent
    headers:
      # 鉴权：echo -n "pk-lf-xxx:sk-lf-xxx" | base64 -w 0
      Authorization: "Basic <Base64(public_key:secret_key)>"
      # 启用 v4 实时摄入，避免数据延迟
      x-langfuse-ingestion-version: "4"
    # 内网场景可按需开启内容采集（开启后 payload 增大约 11 倍）
    captureContent: false
    # Langfuse 不接收 OTLP Metric
    exportMetrics: false
    # 资源属性：用于在 Langfuse 中区分工程师和环境
    resourceAttributes:
      deployment.environment.name: production
```

**步骤三：全局分发（200 人规模自动化配置）**

对于 200 人团队，建议通过基础设施自动化工具统一分发配置，避免人工操作错误：

```bash
# 方式 A：Ansible Playbook（推荐）
# 在 ansible/roles/dsh_telemetry/tasks/main.yml 中
- name: 配置 DSH loongsuite 插件（Web Profile）
  copy:
    content: |
      - id: loongsuite-observability
        config:
          traceEndpoint: http://langfuse-internal.corp.local:3000/api/public/otel/v1/traces
          serviceName: dsh-agent
          headers:
            Authorization: "Basic {{ langfuse_auth_b64 }}"
            x-langfuse-ingestion-version: "4"
          captureContent: false
          exportMetrics: false
    dest: "{{ ansible_env.HOME }}/.dsh/profiles/web/cordis.patch.yml"
    mode: '0600'

# 方式 B：开发机基础镜像预置（适合容器化开发环境）
# 在 Dockerfile 中
COPY dsh-cordis.patch.yml /root/.dsh/profiles/web/cordis.patch.yml
```

---

## 8. 容量规划与性能调优

### 8.1 并发负载模型量化

基于 200 人团队的使用模式，建立以下量化负载模型：

| 参数 | 估算值 | 说明 |
| :--- | :--- | :--- |
| 日活工程师 | 160 人（80% 日活率） | 工作日高峰期 |
| 高峰并发 Session | 30~50 个 | 约 20~30% 同时处于活跃 Agent 循环 |
| 每次 Turn 的 Span 数量 | 15~30 个 | 含 ENTRY/AGENT/STEP/LLM/TOOL |
| 峰值写入速率 | 200~500 Spans/s | 高峰期估算 |
| 单 Span 网络 payload | 6~73 KB | 关闭/开启内容采集 |
| 峰值网络带宽需求 | 2~8 MB/s | 关闭内容采集时约 2MB/s |
| 日 Span 总量 | 约 200~500 万条 | 工作日 8 小时估算 |

### 8.2 硬件选型建议

针对 200 人规模，推荐以下服务器规格（单台宿主机足以支撑，无需集群）：

| 组件 | 最低规格 | 推荐规格 | 关键说明 |
| :--- | :--- | :--- | :--- |
| **CPU** | 8 核 | 16 核 | ClickHouse 向量化执行受益于多核 |
| **内存** | 32 GB | 64 GB | ClickHouse 聚合查询内存消耗较大 |
| **系统盘** | 100 GB SSD | 200 GB NVMe | 操作系统和容器镜像 |
| **数据盘** | 500 GB NVMe | 1 TB NVMe | ClickHouse 数据（列式压缩后约 50~100 GB/月） |
| **网络** | 1 Gbps | 10 Gbps | 高并发写入时网络不应成为瓶颈 |

**存储估算**：以每日 300 万条 Span、关闭内容采集（平均 6 KB/Span）为基准，原始数据约 18 GB/天。ClickHouse 列式压缩比约 5:1，实际落盘约 3.6 GB/天。配合 30 天 TTL，稳定存储占用约 108 GB。开启内容采集后数据量增大约 11 倍，需相应扩容。

### 8.3 ClickHouse 关键调优参数

除了前述的 `clickhouse-config.xml` 配置外，还需关注以下运行时参数：

```sql
-- 查看当前 Part 数量（Too Many Parts 的预警指标）
SELECT table, count() as parts, sum(rows) as total_rows
FROM system.parts
WHERE active AND database = 'default'
GROUP BY table
ORDER BY parts DESC;

-- 如果 parts 数量持续超过 100，说明写入批次过小，需要增大 Worker 的批量写入阈值
-- 在 Langfuse Worker 环境变量中调整：
-- LANGFUSE_INGESTION_BATCH_SIZE=1000  （默认值，可适当增大）
```

---

## 9. 安全加固与数据零出网保障

### 9.1 四层防御体系

本方案构建了四层递进式的数据安全防御体系：

**第一层：网络层隔离**。在防火墙/安全组层面，对所有内网主机配置出公网流量全部 DROP 的规则。仅保留特定 IP（如堡垒机）的出网权限用于镜像拉取。这是最根本的数据不出网保障，即使应用层配置出现错误，网络层也能兜底。

**第二层：应用层配置**。在 Langfuse 服务端强制设置 `TELEMETRY_ENABLED=false`，禁止向 PostHog Cloud 发送任何统计数据 [3]。在插件端保持 `captureContent: false`，避免将 Prompt/Completion 原文写入 Span，从源头减少敏感数据的流转范围。

**第三层：访问控制**。设置 `AUTH_DISABLE_SIGNUP=true` 关闭公开注册，仅允许管理员通过 Langfuse 后台创建账号。为 DSH 配置专用的 Ingestion Project（如 `dsh-internal-prod`），生成独立的 `pk-*/sk-*` 密钥对，开发机仅拥有数据写入权限，Web UI 的分析和管理功能仅对 Tech Lead 和 SRE 开放。

**第四层：凭据安全**。API Key 的 Base64 编码值通过 Ansible Vault 或密钥管理系统（KMS）分发，不得明文写入代码仓库。`cordis.patch.yml` 文件权限设置为 `0600`，防止其他用户读取。

### 9.2 敏感信息脱敏策略

即使在内网环境中，也建议对以下类型的敏感信息进行脱敏处理，防止内部数据泄露风险：

```yaml
# 在 cordis.patch.yml 中，通过 captureContent: false 默认关闭内容采集
# 如果需要开启内容采集进行调试，建议同时配置内容长度限制
- id: loongsuite-observability
  config:
    captureContent: true      # 仅在调试环境开启
    contentMaxChars: 2000     # 限制单个属性的字符数，防止超大 Prompt 泄露
```

对于工具调用参数中可能包含的敏感信息（如数据库连接字符串、API Key），建议在 DSH 的工具配置层面进行参数过滤，而不是依赖遥测层的后置脱敏。

### 9.3 数据零出网验证清单

在系统上线前，应执行以下验证步骤确认数据不出网：

```bash
# 1. 验证 Langfuse 服务端无出网连接
# 在 Langfuse 服务器上执行，启动后等待 5 分钟
ss -tnp | grep -E "ESTABLISHED.*langfuse"
# 预期：只有内网 IP 的连接（192.168.x.x 或 10.x.x.x），无公网 IP

# 2. 验证 OTLP 数据确实到达内网 Langfuse
# 在开发机上运行一次 DSH 任务后
curl -s http://langfuse-internal.corp.local:3000/api/public/traces \
  -H "Authorization: Basic <AUTH_STRING>" | jq '.data | length'
# 预期：返回大于 0 的数字

# 3. 验证插件未向公网发送数据
# 在开发机上抓包验证
tcpdump -i any -n 'port 443 or port 80' -c 100 2>/dev/null | grep -v "192.168\|10\."
# 预期：DSH 运行期间无公网 HTTP/HTTPS 连接（除模型 API 调用外）

# 4. 验证 Langfuse 遥测已禁用
docker logs langfuse-server-1 2>&1 | grep -i "telemetry\|posthog"
# 预期：出现 "Telemetry disabled" 或无相关日志
```

---

## 10. 可观测能力矩阵：能看到什么

### 10.1 Langfuse UI 核心视图

接入完成后，Langfuse Web UI 提供以下核心分析能力：

**Trace 详情视图**：每次 DSH Turn 对应一棵完整的调用树。以一次典型的复杂任务为例，可以直接读出：17.42 秒的总耗时中，第 3、4 个 STEP 各占 5 秒以上；单次 LLM 调用最长 4.38 秒；`web_search` 工具连续两次 ERROR 后，模型改用 `bash` 完成任务——错误状态收敛在对应的 TOOL Span 上，无需在日志中逐行查找 [2]。

**Sessions 视图**：通过 `gen_ai.session.id` 和 `gen_ai.turn.id` 属性，将一个会话的多轮 Turn 串联展示，呈现完整的多轮对话轨迹和累计 Token 消耗。

**模型分析大盘**：按模型维度聚合 P95/P99 延迟、Token 吞吐率（Tokens/s）、成本曲线。支持时间范围过滤，可对比不同时段的性能变化。

**评估大盘**：配置 LLM-as-a-Judge 评估规则后，可展示 Agent 输出质量的长期趋势，自动标记低质量 Trace 供人工复核。

### 10.2 可观测能力全景矩阵

| 观测维度 | 具体指标 | 数据来源 | 查询方式 |
| :--- | :--- | :--- | :--- |
| **延迟分析** | Turn 总耗时、STEP 耗时分布、LLM TTFT、工具执行耗时 | LLM/TOOL Span 的 duration | Trace 瀑布图、P95 聚合 |
| **Token 成本** | 每次调用的 Input/Output/Reasoning Token | `gen_ai.usage.*` 属性 | 按模型/用户/时间聚合 |
| **KV Cache 效率** | Cache 命中率（`cache_read_input_tokens / input_tokens`） | `gen_ai.usage.cache_read_input_tokens` | 自定义指标计算 |
| **错误分析** | 工具失败率、模型调用失败原因、重试次数 | TOOL Span 错误状态、`gen_ai.response.finish_reasons` | 按工具/错误类型过滤 |
| **Subagent 归因** | 主 Agent vs Subagent 的 Token 和耗时占比 | `dsh.session.parent_id`、`dsh.session.delegation_depth` | 按 session 属性关联 |
| **用户行为** | 每位工程师的 Token 消耗、任务类型分布 | `user.name` Resource 属性 | 按用户维度聚合 |
| **模型质量** | 输出幻觉率、任务完成率（LLM-as-a-Judge） | Langfuse Scores 表 | 评估大盘 |
| **Prompt 版本效果** | 不同 Prompt 版本的质量对比 | Prompt 版本 ID 关联 | A/B 对比分析 |

### 10.3 已知局限性

当前版本存在以下已知局限，需要在实际使用中注意：

**Subagent Trace 孤立问题**：当 DSH 派生 Subagent 时，Subagent 会开启自己独立的 Trace，而不是嵌套在父 Agent 的 Trace 下。两者之间没有 Span Link。目前的解决方案是通过属性关联：Subagent 的 Span 携带 `dsh.session.parent_id`、`dsh.session.origin = 'subagent'` 和 `dsh.session.delegation_depth`，可以在 Langfuse 中通过这些属性手动关联父子会话 [4]。

**工具错误计数不准确**：只有显式报告失败的工具（如 MCP 工具返回 `isError`）才会将 Span 状态设为 ERROR。Shell 命令以非零退出码结束时，对应的 TOOL Span 仍记录为成功状态，因此基于 Span 状态的工具错误率统计会低估实际错误数量 [4]。

**Langfuse 不接收 OTLP Metric**：`@loongsuite/dsh-plugin` 导出的两个 Metric（`gen_ai.client.operation.duration` 和 `gen_ai.client.token.usage`）无法被 Langfuse 接收，必须在插件配置中设置 `exportMetrics: false`，否则会产生无效的导出尝试 [4]。

---

## 11. 分阶段实施路线图

### 第一阶段：服务端基座搭建（第 1 天）

目标是在内网指定服务器上完成 Langfuse 集群的部署和初始化。

首先，通过堡垒机完成所有依赖镜像的拉取和内网镜像仓库的推送。然后在目标服务器上准备数据目录（`/data/clickhouse`、`/data/postgres`、`/data/redis`、`/data/minio`），确保磁盘挂载正确。使用上述 `docker-compose.yml` 和 `.env` 文件启动服务栈，等待约 3 分钟直到 `langfuse-web-1` 容器日志出现 "Ready"。

完成后，通过浏览器访问 `http://langfuse-internal.corp.local:3000`，创建 Admin 账号，建立 `dsh-internal-prod` 项目，生成 Ingestion API Key，并记录 `pk-lf-*` 和 `sk-lf-*` 密钥对。

### 第二阶段：灰度验证（第 2 天）

选取 2~3 名核心研发工程师的机器进行灰度接入验证。按照 7.5 节的步骤安装插件并配置 `cordis.patch.yml`，运行一次复杂的 DSH 任务（建议选择包含多次工具调用和至少一次 Subagent 派生的任务）。

验证清单：
- Langfuse UI 中是否出现 `enter_ai_application_system` 根 Span
- Trace 树是否正确展示 ENTRY → AGENT → STEP → LLM/TOOL 层级
- `gen_ai.usage.*` 字段是否正确渲染为 Token 消耗数字
- 在开发机上执行网络监控，确认无公网 TCP 连接产生

### 第三阶段：全量推广（第 3 天）

灰度验证通过后，通过 Ansible Playbook 或开发机基础镜像更新，将插件配置推送至全部 200 名工程师的开发环境。同时，为 Tech Lead 和 SRE 团队创建 Langfuse 账号，分配只读分析角色，培训 Trace 查看和 Token 成本分析的基本操作。

### 第四阶段：评估体系建立（第 1~2 周）

在基础可观测能力稳定运行后，逐步建立 LLM 质量评估体系：配置 LLM-as-a-Judge 评估规则（建议从幻觉检测和任务完成率两个维度入手），建立 Prompt 版本管理流程，设置关键指标的告警阈值（如 P95 延迟超过 60 秒、工具失败率超过 5%）。

---

## 12. 常见问题与故障排查

### 12.1 插件安装后 Langfuse 无数据

**最常见原因**：API Key 配置错误。`@loongsuite/dsh-plugin` 的导出失败是静默的——DSH 正常完成任务并退出，但遥测数据未发送成功，终端不会有任何错误提示 [4]。

**排查步骤**：

```bash
# 1. 直接测试 Langfuse OTLP 端点连通性
curl -i -X POST \
  "http://langfuse-internal.corp.local:3000/api/public/otel/v1/traces" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic <AUTH_STRING>" \
  -H "x-langfuse-ingestion-version: 4" \
  -d '{"resourceSpans":[]}'
# 预期：返回 200 或 202

# 2. 开启插件调试日志
# 在 cordis.patch.yml 中添加 debug: true
- id: loongsuite-observability
  config:
    debug: true
    ...
# 重启 DSH 后，插件生命周期事件会输出到 DSH 日志

# 3. 验证插件是否正确加载
dsh --profile web --dump-config | grep loongsuite
# 预期：出现 id: loongsuite-observability
```

### 12.2 ClickHouse Too Many Parts 错误

**原因**：写入批次过小，导致 ClickHouse 产生大量小 Part 文件，触发写入限速。

**解决方案**：检查 Langfuse Worker 的批量写入配置，并确认 `clickhouse-config.xml` 中的 `parts_to_delay_insert` 和 `parts_to_throw_insert` 参数已正确应用。如果问题持续，可以手动触发 ClickHouse 合并：

```sql
OPTIMIZE TABLE observations FINAL;
OPTIMIZE TABLE traces FINAL;
```

### 12.3 Subagent Trace 在 Langfuse 中找不到

**原因**：Subagent 创建独立 Trace，不嵌套在父 Agent 下。

**解决方案**：在 Langfuse Trace 搜索中，使用 `dsh.session.parent_id = <父会话 ID>` 过滤条件查找 Subagent 的 Trace。或者通过 `dsh.session.origin = 'subagent'` 过滤所有 Subagent 产生的 Trace。

### 12.4 数据实时性问题（延迟超过 10 分钟）

**原因**：未携带 `x-langfuse-ingestion-version: 4` 请求头。

**解决方案**：确认 `cordis.patch.yml` 中的 `headers` 配置包含该头，或在环境变量 `OTEL_EXPORTER_OTLP_HEADERS` 中添加 `x-langfuse-ingestion-version=4` [8]。

---

## 13. 参考资料

[1]: https://github.com/deepseek-ai/deepseek-harness/discussions/1699 "LoongSuite OpenTelemetry GenAI Observability Plugin for DeepSeek Harness - GitHub Discussion #1699"
[2]: https://higress.ai/blog/higress-mmse_awbbpb_zrrortwthoddrv3v/ "DeepSeek Harness 全景可观测实践 - Higress 官方博客"
[3]: https://langfuse.com/self-hosting/security/telemetry "Telemetry (self-hosted) - Langfuse 官方文档"
[4]: https://signoz.io/docs/deepseek-harness-observability/ "DeepSeek Harness Observability & Monitoring with OpenTelemetry - SigNoz 文档"
[5]: https://opentelemetry.io/docs/specs/semconv/attributes-registry/gen-ai/ "OpenTelemetry GenAI Semantic Conventions"
[6]: https://langfuse.com/self-hosting "Self-host Langfuse - 官方自建部署文档"
[7]: https://pub.towardsai.net/i-self-hosted-langfuse-so-my-llm-traces-would-stop-living-on-someone-elses-bill-165f4eff65e1 "I Self-Hosted Langfuse so My LLM Traces Would Stop Living on Someone Else's Bill"
[8]: https://langfuse.com/integrations/native/opentelemetry "OpenTelemetry (OTEL) for LLM Observability - Langfuse 官方文档"
[9]: https://langfuse.com/self-hosting/deployment/docker-compose "Docker Compose Deployment (Self-Hosted) - Langfuse 官方文档"
[10]: https://langfuse.com/self-hosting/configuration "Configuration via Environment Variables (self-hosted) - Langfuse 官方文档"
[11]: https://github.com/alibaba/loongsuite-pilot "alibaba/loongsuite-pilot - GitHub 仓库"
