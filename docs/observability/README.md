# DSH Agent 可观测平台设计与实施规范

| 属性 | 值 |
| --- | --- |
| 状态 | 待评审 |
| 版本 | 0.1 |
| 最后更新 | 2026-09-15 |
| 适用范围 | DSH Web / Headless、LoongSuite 插件、内网 OTel 接入与 Agent Trace 后端 |
| 用户规模 | 约 200 名开发者 |
| 客户端平台 | macOS arm64、Ubuntu Linux x86-64 |
| 关联规范 | [CI/CD 设计](../cicd/README.md)、[安全与运维](../cicd/06-security-and-operations.md) |

## 1. 文档地位

本文是 DSH Agent 可观测平台的目标设计和实施验收依据。它定义组件边界、数据契约、
安全控制、SCM 治理、部署拓扑、故障语义、测试矩阵和分阶段上线条件。

本文描述的是**目标状态**，不是当前实现证明。任何尚未通过本文验收项的能力，不得在
发布说明、评审或运维手册中表述为已经可用。

[原始 Langfuse 调研文档](<backup/DSH+loongsuite_dsh-plugin+Langfuse 内网自建 LLM 可观测平台：完整设计方案与工程落地深度分析.md>)
仅用于追溯，不具备规范效力。原文中的部署命令、容量数据、性能结论和产品选择都必须
重新通过本文规定的验证流程。两者冲突时以本文为准；本文与仓库安全或 CI/CD 规范冲突时，
取更严格的约束。

规范用语：

- **必须**：上线或晋级的强制条件。
- **不得**：明确禁止的行为。
- **应该**：默认执行；偏离时必须在 Gerrit 评审中说明理由和补偿控制。
- **可以**：不影响设计一致性的可选实现。

## 2. 决策摘要

本设计采用以下已收口决策：

1. 保留 LoongSuite DSH 插件作为 Agent 生命周期传感器，继续使用标准
   OTLP/HTTP protobuf，不把客户端绑定到某个后端。
2. DSH 客户端不得直连 Phoenix、Langfuse 或数据库；全部 trace 先进入内网
   OpenTelemetry Collector Gateway。
3. 首选后端为 **Phoenix + PostgreSQL**。选择理由是当前没有可复用的可观测平台，
   而 Phoenix 能以一个应用和一个 SQL 数据库提供 OTLP 接收、Trace UI 和后续评估能力，
   比 Langfuse 的 Web、Worker、PostgreSQL、ClickHouse、Redis、对象存储组合更轻。
4. 第一阶段只接入 traces，LoongSuite 的 GenAI metrics 显式关闭。进入 staging 前
   必须增加最小 Prometheus + Alertmanager，只监控 Ingress、Collector、Phoenix 和
   PostgreSQL 自身；是否接收 LoongSuite GenAI metrics 另行评审。
5. Langfuse 不是首期依赖。只有 Phoenix 未通过容量、查询、权限或产品能力验收，或者
   业务正式批准 prompt/dataset/score 工作流时，才启动 Langfuse 选型 ADR。
6. 生产环境强制 captureContent=false。prompt、completion、reasoning、tool schema、
   tool 参数、tool 结果、源码和 diff 不进入 Agent Trace。
7. DSH 内置 session telemetry 在生产继续保持 DSH_TELEMETRY_MODE=DISABLED。
   Agent Trace、运行日志、Session 数据和 SCM/发布审计是四类不同数据，不得混用。
8. Prompt、Agent preset、采样规则、脱敏规则和后端配置以 Git/Gerrit 为事实源。
   任何可观测平台 UI 都不得绕过评审直接改变生产 Agent 行为。
9. 可观测性链路默认 fail-open：Collector 或后端失败不得阻止 DSH 完成用户任务。
   Trace 不是审计账本，也不承担 exactly-once 交付。

## 3. 背景与问题定义

DSH 的运行问题通常跨越 session、Agent loop、step、LLM stream 和 tool execution。
仅靠按时间排序的日志，很难回答以下问题：

- 一次 turn 的时间花在 Agent 推理、LLM 首 token、模型生成还是工具调用；
- 重试、异常和降级发生在哪个 step；
- token 使用来自哪个模型调用，是否存在重复计数；
- subagent 与父 session 的关系；
- 某个回归对应哪个 DSH、插件、配置和源码版本；
- 可观测性后端异常时，DSH 是否仍能正常工作。

当前超级仓已经以 submodule 引入
[LoongSuite](../../plugins/loongsuite-observability/README.zh-CN.md)，组件目录 pin 为
v0.1.2。该插件能生成 ENTRY → AGENT → STEP → LLM / TOOL 的 Trace 树，但存在以下
生产化边界：

- 插件默认 enabled=true，未配置端点时会使用 OpenTelemetry 默认端点；
- 默认 trace 批处理间隔为 5 秒、内存队列为 2048、export timeout 为 30 秒；
- 队列不持久化，进程异常退出或持续不可达时允许丢数据；
- captureContent 默认关闭，但仍会输出 dsh.session.cwd；生产版本必须在客户端停止生成
  该属性，Collector 删除只作为第二道防线；
- session 字段使用 gen_ai.session.id，与部分后端的一等 session 字段不一致；
- 上游支持 DSH 0.1.x，但完整验证版本与本仓当前 pin 不同；
- 插件只负责观察，不负责 prompt 获取、控制、审计或发布治理。

因此，本项目的核心不是“部署一个 Trace UI”，而是建立一条安全、可替换、可验证的
Agent 遥测数据链路。

## 4. 目标与非目标

### 4.1 目标

- 为 Web 和 Headless profile 提供一致的 Agent Trace。
- 在 content-free 模式下观察调用拓扑、状态、延迟、TTFT 和 token usage。
- 支持约 200 名开发者，不把后端高权限 secret 分发到客户端。
- 统一执行字段映射、脱敏、批处理、重试、限流和后端切换。
- 把 trace 与 Gerrit change、patchset、commit、Jenkins build、Nexus digest 关联。
- 在 macOS arm64 和 Linux x86-64 上分别完成运行期兼容验证。
- 后端不可用时不阻塞 DSH，并能量化队列、重试和丢弃情况。
- 所有服务、镜像、配置、凭据、数据和备份留在内网。
- 支持从 5–10 人 canary 平滑扩展到 200 人，并以实测数据确定容量。

### 4.2 非目标

- 不把 Trace 建设成完整日志平台。
- 不用 Agent Trace 替代 DSH Session 数据、Gerrit 审计或发布证据。
- 不采集真实用户 prompt、模型响应、reasoning 或工具正文。
- 不在第一阶段上线生产 LLM-as-a-Judge、动态 prompt 或自动质量门禁。
- 不要求 Trace exactly-once；允许在明确丢失预算内 at-most-once。
- 不为本项目修改第三方 submodule 内容。
- 不通过当前 legacy make deploy 部署可观测平台。
- 不在第一阶段为后端引入 Kubernetes。

## 5. 方案比较与选择

### 5.1 候选方案

| 方案 | 数据组件 | 优点 | 主要代价 | 结论 |
| --- | --- | --- | --- | --- |
| Collector + Phoenix + PostgreSQL | Collector、Phoenix、PostgreSQL | LLM Trace UI；OTLP；依赖少；后端可替换 | 大规模数据都落 SQL，容量必须实测 | **首选** |
| Collector + Langfuse v4 | 再增加 Web、Worker、ClickHouse、Redis、对象存储 | 成本、prompt、dataset、score 体验完整 | 运维、备份、升级和治理面最大 | 条件升级 |
| Collector + Jaeger 单机 | Collector、Jaeger | 最快、最轻，适合协议调试 | 无生产存储、权限和备份能力 | 仅本地/测试 |
| Collector + Tempo/Grafana/Prometheus | 多个通用观测组件 | 通用、成熟、扩展性好 | 当前无既有平台，初建成本高；LLM 语义弱 | 暂不选 |

### 5.2 选择原则

首期选 Phoenix，不代表把客户端绑定到 Phoenix。客户端只知道内部 OTLP Gateway。
后端切换只修改受控 Collector exporter，不改变 DSH profile、客户端凭据形式或 Trace
字段契约。

Phoenix 必须通过第 16 节 canary 验收后才能进入 200 人生产。若未通过，项目不直接
“加机器硬顶”，而是使用同一批匿名化样本对比 Langfuse，再形成独立 ADR。Langfuse
Docker Compose 只允许用于 PoC；其官方文档明确说明该方式不具备高可用、水平扩展和
备份能力。

## 6. 总体架构

~~~text
                          ┌──────────────────────────────────┐
                          │ Gerrit / Jenkins / Nexus         │
                          │ change / patchset / commit       │
                          │ build / artifact digest          │
                          └──────────────┬───────────────────┘
                                         │ 版本关联属性
                                         ▼
┌──────────────────┐  OTLP/HTTPS  ┌──────────────────────────┐
│ DSH Web/Headless │──────────────>│ Internal OTLP Ingress    │
│ + LoongSuite     │  ingest-only  │ TLS + auth + rate limit  │
└──────────────────┘     token     └────────────┬─────────────┘
                                                ▼
                                   ┌──────────────────────────┐
                                   │ OTel Collector Gateway   │
                                   │ sanitize / map / batch   │
                                   │ retry / queue / sampling │
                                   └───────┬───────────┬──────┘
                                           │ traces    │ internal telemetry
                                           ▼           ▼
                                ┌─────────────────┐  Prometheus*
                                │ Phoenix         │  + Alertmanager*
                                │ Trace / Eval UI │
                                └────────┬────────┘
                                         ▼
                                   PostgreSQL

DSH stdout/stderr ──> journald / operational log channel
DSH session state ──> /var/lib/dsh，受限访问且默认不外发

* Canary 可以先不长期保存平台指标；staging 和 production 必须部署。
~~~

### 6.1 四个数据面

| 数据面 | 内容 | 事实源 | 主要读者 | 是否审计 |
| --- | --- | --- | --- | --- |
| Agent Trace | span 树、状态、延迟、token、版本关联 | Phoenix/PostgreSQL | 开发、Tech Lead、SRE | 否 |
| Operational Log | 进程、插件、exporter、服务错误 | stdout/stderr、journald | SRE、开发 | 有限 |
| Session Data | 消息、工具结果、附件和上下文 | DSH 持久状态 | 获授权业务人员 | 否 |
| SCM/Release Evidence | review、测试、制品、部署和回滚 | Gerrit/Jenkins/Nexus | Reviewer、Release、审计 | 是 |

四类数据必须使用不同 schema、权限和保留策略。不得因为 Phoenix 能展示某些文本字段，
就把 Session 正文复制进 Trace。

## 7. 组件职责和边界

### 7.1 LoongSuite DSH 插件

职责：

- 监听 DSH session、turn、step、LLM stream 和 tool 生命周期；
- 生成父子 span、错误状态、延迟和 token 属性；
- 通过 OTLP/HTTP protobuf 发往唯一的内部 Gateway；
- 在 DSH dispose 时尽力 flush；
- 后端故障时保持 DSH 主流程可用。

不得承担：

- 后端鉴权密钥管理；
- 集中脱敏策略；
- 可靠持久队列；
- prompt 下发；
- 审计、告警和发布授权。

生产启用前必须显式配置以下值，不能依赖插件默认值：

~~~yaml
- id: loongsuite-observability
  config:
    enabled: true
    traceEndpoint: https://otel-gateway.corp.example/v1/traces
    serviceName: dsh-agent
    captureContent: false
    exportMetrics: false
    maxExportBatchSize: 512
    maxQueueSize: 2048
    traceExportIntervalMs: 5000
    exportTimeoutMs: 3000
    debug: false
~~~

该片段只定义结构，不是可直接使用的生产域名。真正 endpoint 由环境配置层注入并经
Gerrit 评审；Authorization 不得写进 YAML 或 Git。

在 Phase 0 完成前，release profile 必须显式设置 enabled=false，或者不挂载该 bundle。
原因是当前上游默认 enabled=true，且超级仓的 required 组件会被 link 流程自动挂载。

用于生产的 LoongSuite 版本必须在 span 创建前省略 dsh.session.cwd，而不是只依赖
Collector 收到数据后再删除。该能力优先通过上游发布获得；上游不能按期提供时，按
第 11.1 节建立 Gerrit fork。Collector 的 delete 规则仍然保留，用于防止版本回退或
其他 producer 再次发送该字段。

### 7.2 Internal OTLP Ingress

Ingress 是无状态 TLS 和认证边界，可以使用企业已有负载均衡；没有可复用设施时使用
最小化的内网 Nginx/Envoy 实例。

它必须：

- 只开放 HTTPS 443；
- 校验由内部 Secret/PKI 系统签发的 ingest-only 凭据；
- 把请求转发到 Collector 的内部 OTLP/HTTP receiver；
- 设置请求体上限、连接超时和每身份限流；
- 不记录 Authorization header 或请求 body；
- 禁止公网路由和公网 DNS 依赖；
- 记录匿名 client ID、状态码、字节数和延迟。

首期客户端认证采用每设备或小批次独立的短期 Bearer token。token 只允许写入 Collector，
不能读取 Phoenix、查询数据或访问后端数据库。支持验证后可以迁移到 mTLS，但 mTLS
不是首期阻塞项。

### 7.3 OpenTelemetry Collector Gateway

Collector 是稳定的数据契约和后端隔离层，必须使用官方或经批准的 contrib 发行版，
并固定镜像 digest。

处理管线至少包含：

- memory_limiter；
- resource/attribute transform；
- content denylist 和 cwd 删除；
- session 字段映射；
- batch；
- retry_on_failure；
- sending_queue；
- 可选 file_storage WAL；
- 后端 OTLP exporter；
- Collector 自身健康和队列指标。

核心转换逻辑的语义为：

~~~yaml
processors:
  transform/dsh_sanitize:
    trace_statements:
      - context: span
        statements:
          - delete_key(attributes, "dsh.session.cwd")
          - set(attributes["session.id"], attributes["gen_ai.session.id"])
            where attributes["gen_ai.session.id"] != nil
  batch: {}
~~~

正式配置还必须删除第 9.3 节的全部禁止字段。上例只说明不可缺少的两个转换，不应被
复制为完整生产配置。

后端 Authorization secret 只存在于 Collector/Vault，不进入客户端。Collector 必须
限制管理和 metrics 端口只能被管理网访问。

### 7.4 Phoenix

Phoenix 负责：

- Trace 树查看和属性检索；
- LLM/tool 调用延迟和 token 分析；
- 人工标注与后续离线评估；
- 项目和用户访问控制。

Phoenix 不负责：

- 接受来自开发机的直接流量；
- 存储原始 prompt、代码或 tool payload；
- 动态控制生产 prompt；
- 生成发布门禁结论。

内网部署必须设置 PHOENIX_ALLOW_EXTERNAL_RESOURCES=false，并配置持久 PostgreSQL；
生产不得使用临时 SQLite。UI 必须置于 SSO 或企业反向代理认证之后，不开放自助公开
注册。

### 7.5 PostgreSQL

PostgreSQL 是首期唯一有业务数据的持久组件。要求：

- 使用受支持的 PostgreSQL 版本；
- 独立数据库和最小权限账号；
- TLS 连接；
- 数据盘加密；
- 连接池、磁盘和慢查询监控；
- 30 天初始 Trace 保留策略；
- 每日备份和季度恢复演练；
- Phoenix 版本升级前完成可恢复快照。

### 7.6 生产指标与告警面

首期 LoongSuite exportMetrics=false。Phoenix Trace 已能回答 Agent 调用拓扑、延迟、
错误和 token 问题，不为“看起来完整”提前增加时序数据库。

Canary 阶段可以通过短期 scrape、结构化日志和验收报告收集基线；进入 staging 前必须
部署最小 Prometheus + Alertmanager，至少覆盖：

- 5 分钟级检测 Collector queue、drop 和 send failure；
- Ingress 认证失败、限流和 5xx；
- Phoenix health、摄取失败和查询延迟；
- PostgreSQL 连接、磁盘、WAL、锁和备份新鲜度；
- 告警去重、分级和路由。

这套时序面只服务平台自监控。LoongSuite 的 gen_ai.client.operation.duration 和
gen_ai.client.token.usage 继续关闭，除非新增 ADR 证明 Phoenix Trace 聚合不能满足
业务分析。高基数字段不得成为 metric label。

## 8. 数据流

一次 DSH turn 的正常数据流：

1. LoongSuite 创建 ENTRY trace，并在同一 trace 内创建 AGENT、STEP、LLM 和 TOOL span。
2. 插件在内存中批处理 span，按 5 秒或 batch 上限发往 OTLP Ingress。
3. Ingress 完成身份校验、限流和 TLS 终止，将请求交给 Collector。
4. Collector 删除禁止字段，补充环境属性，映射 session ID，再进行 batch。
5. Collector 使用发送队列和有限重试写入 Phoenix。
6. Phoenix 持久化到 PostgreSQL 并更新查询视图。
7. 用户通过 SSO 进入 Phoenix UI，只能访问所属环境和项目。

后端故障时：

1. Collector 在限定时间内重试，并使用内存队列或 WAL 缓冲。
2. 队列达到水位时触发告警；达到硬上限后允许丢弃最旧或新到数据，具体行为由固定版本
   配置和故障测试证明。
3. 客户端插件自身队列仍可能丢 span，但不得抛出导致 Agent turn 失败的异常。
4. 后端恢复后，Collector 排空可恢复队列；不可恢复部分进入丢失报告。
5. 故障期间 DSH 任务继续执行，Trace UI 可以暂时不可用。

## 9. Trace 数据契约

### 9.1 Resource 属性

每个进程必须提供：

| 字段 | 示例 | 规则 |
| --- | --- | --- |
| service.name | dsh-agent | 固定受控值 |
| service.version | 0.1.5-rc.2 | DSH 版本 |
| telemetry.sdk.language | nodejs | OTel 自动提供 |
| deployment.environment.name | canary | development/canary/staging/production |
| host.arch | arm64 | 允许 |
| os.type | darwin | 允许 |
| dsh.plugin.version | 0.1.2 | LoongSuite 版本 |
| dsh.profile | web | 受控枚举 |
| dsh.config.sha256 | sha256:… | 配置内容摘要，不含 secret |
| service.instance.id | HMAC 后的设备 ID | 只用于 trace 查询，不作 metric label |

### 9.2 Trace 与 Span 属性

允许字段：

- session.id；
- gen_ai.agent.name；
- gen_ai.operation.name；
- gen_ai.request.model；
- gen_ai.response.model；
- gen_ai.usage.input_tokens；
- gen_ai.usage.output_tokens；
- gen_ai.usage.reasoning_tokens；
- gen_ai.usage.cache_read.input_tokens；
- dsh.turn；
- dsh.session.parent_id；
- dsh.session.origin；
- dsh.session.delegation_depth；
- dsh.agent.preset 的受控枚举；
- tool name、call ID、duration 和 status；
- error.type 和脱敏后的低基数 error category；
- dsh.repo.id；
- dsh.scm.revision；
- dsh.scm.dirty；
- gerrit.change、gerrit.patchset、jenkins.build_id 和 artifact.sha256，仅在对应环境存在时。

token 聚合必须只选择 LLM span，或者只选择 AGENT 聚合 span，不得同时相加。
cache read token 使用 gen_ai.usage.cache_read.input_tokens，不能使用原始调研中的错误拼写。

### 9.3 禁止字段和内容

以下内容不得离开 DSH 进程；Collector denylist 是第二道防线：

- gen_ai.input.messages；
- gen_ai.output.messages；
- prompt、completion 和 reasoning 全文；
- tool schema、arguments 和 results；
- source code、patch、diff、附件和截图；
- Authorization、Cookie、API key、SSH key 和环境变量；
- dsh.session.cwd；
- 用户名、邮箱、主目录和绝对路径；
- 原始仓库 URL、内部域名和未分类项目名称；
- stack trace 中的绝对路径；
- 任意未登记的高基数自定义属性。

repo ID、设备 ID 和用户关联 ID 必须使用不同用途的 HMAC key，避免跨系统拼接身份。
HMAC key 位于 Vault，至少每年轮换；轮换后允许查询维度断代，不要求可逆。

### 9.4 Subagent 关联

当前 LoongSuite 为 subagent 建立独立 trace，并通过 parent session、origin 和 delegation
depth 关联。首期接受这种模型，不要求跨 trace Span Link。

Phoenix 必须能按 session.parent_id 找到子 trace；若不能直接筛选，Collector 应同时
写入规范化的 dsh.parent_session.id。任何新增字段都需更新本节、测试夹具和查询手册。

## 10. 隐私、安全和权限

### 10.1 数据分级

| 数据 | 分级 | 默认处理 |
| --- | --- | --- |
| 结构、耗时、token、低基数状态 | 内部 | 可进入 Trace |
| 匿名 session/device/repo ID | 内部受限 | 可进入 Trace |
| 用户、路径、repo URL、分支名 | 机密 | 删除或 HMAC |
| prompt、响应、reasoning、代码、tool payload | 高度机密 | 禁止采集 |
| API key、token、cookie、SSH key | Secret | 禁止采集并触发事件 |

### 10.2 信任边界

- Developer 设备是不完全受信任的遥测生产者，不能携带 Phoenix 管理凭据。
- Ingress 只验证 ingest 身份，不授予读取能力。
- Collector 是集中策略执行点，只有平台管理员可修改配置。
- Phoenix UI 只对内网和 SSO 用户开放。
- PostgreSQL 不对开发网开放。
- 未评审的 Gerrit patchset 不能读取生产遥测凭据。
- GitHub Actions 不得连接内部 Collector、Phoenix 或数据库。

### 10.3 RBAC

| 角色 | 权限 |
| --- | --- |
| Developer | 查看自己或所属项目的 canary/development Trace |
| Tech Lead | 查看所属团队聚合和异常 Trace |
| SRE | 查看全环境运行状态；不能查看禁止正文 |
| Platform Admin | 管理 Collector/Phoenix；不能绕过 Gerrit 改生产配置 |
| Security Admin | 审核权限、脱敏、secret scan 和访问事件 |
| Auditor | 只读访问变更和发布证据；不以 Trace 代替审计 |

若所选 Phoenix 版本不能原生表达上述隔离，必须由 SSO reverse proxy 按环境拆分实例或
路由；仍无法满足时 Phoenix 视为未通过选型验收。

### 10.4 Secret 管理

- 客户端 ingest token 通过企业 Secret 管理或设备配置系统注入环境变量。
- token 不得写入 cordis.patch.yml、Git、命令行参数、日志或 dump-config 输出。
- token 按设备或小批次签发，最长 90 天轮换，可单独撤销。
- Phoenix/PostgreSQL secret 只在服务端 Vault/Jenkins credential 域使用。
- 轮换演练必须证明旧 token 失效且客户端可无停机切换。

### 10.5 网络

- 开发网只允许访问 Ingress 443，不允许直连 Collector 管理端口、Phoenix 数据入口或数据库。
- UI 仅允许办公网/管理网经 SSO 访问。
- PostgreSQL 只允许 Phoenix 和备份节点访问。
- 所有服务默认拒绝出网；导入镜像走 Nexus。
- Phoenix 设置 PHOENIX_ALLOW_EXTERNAL_RESOURCES=false。
- DNS、NTP、CA、SSO 和 Nexus 是允许的内网基础依赖。

## 11. SCM、配置和供应链治理

### 11.1 仓库边界

| 内容 | 权威仓库 |
| --- | --- |
| DSH profile 接入、插件 pin、contract test | 当前 dsh 超级仓 |
| Collector、Ingress、Phoenix、PostgreSQL 部署配置 | 新建 Gerrit 项目 dsh-observability-infra |
| Jenkins Shared Library | 受保护的基础设施仓 |
| 上游 LoongSuite 源码 | GitHub 上游 tag/commit |
| 本仓特有 LoongSuite 改动 | Gerrit fork，精确 pin |

不得在超级仓直接修改 plugins/loongsuite-observability。若必须新增 drop 指标、删除 cwd
或修正字段，顺序是：

1. 先提交上游 issue/PR；
2. 能等待上游发布则升级 tag pin；
3. 不能等待则建立 Gerrit fork 和评审分支；
4. 更新 gitlink、config/components.json、SBOM 和兼容性证据；
5. sourceAuthority 改为 gerrit-fork。

### 11.2 配置晋级

配置必须走：

~~~text
Gerrit patchset
  → schema/privacy/unit tests
  → canary 自动部署
  → 兼容、故障和敏感数据验收
  → main merge
  → Nexus immutable candidate
  → staging 自动验证
  → Release Manager 人工批准
  → 同 digest 晋级 production
~~~

不得让 patchset 自带的 Jenkinsfile 获得生产凭据。生产 Collector 配置、镜像和 Phoenix
版本必须记录 SHA-256、SBOM、provenance 和部署证据。

### 11.3 Prompt 与评估治理

- 生产 prompt 和 Agent preset 必须在 Git 中版本化。
- Trace 只记录 prompt/config SHA，不记录正文。
- Phoenix/Langfuse 中的实验 prompt 不直接供生产 DSH 拉取。
- 实验结果要进入生产，必须回写 Git、经过 Gerrit review 和回归测试。
- 确定性编译、单测、静态分析和 headless journey 是发布主门禁。
- LLM-as-a-Judge 仅允许作用于经过批准的合成/脱敏数据集，首期不阻断发布。

## 12. 物理部署与初始容量

### 12.1 Canary 拓扑

Canary 可以部署在一台隔离 Linux VM，但容器/服务仍要使用独立账号、持久卷和固定镜像
digest：

- Ingress；
- OTel Collector；
- Phoenix；
- PostgreSQL。

建议起始资源仅用于获得实测基线，不是生产容量承诺：

| 资源 | 起始值 |
| --- | ---: |
| CPU | 8 vCPU |
| 内存 | 32 GiB |
| 数据盘 | 500 GiB NVMe/SSD |
| Trace 保留 | 7 天 |
| 用户 | 5–10 |

### 12.2 生产拓扑

通过 canary 后的最低生产拓扑：

- 2 个独立 Collector/Ingress 实例，位于不同故障域；
- 每个 Collector 使用独立本地 WAL 卷；
- 1 个 Phoenix 应用实例，由 systemd/container runtime 自动恢复；
- 1 个独立 PostgreSQL 实例或企业托管 PostgreSQL；
- 独立备份目标，不能与数据库位于同一故障域；
- 内网负载均衡为客户端提供一个稳定 endpoint。

Phoenix 是非业务关键系统，首期接受单活应用，目标 RTO 4 小时；Collector 双实例和 WAL
吸收短期应用停机。若业务要求 UI 99.9% 或零人工恢复，必须另立 HA ADR，不在本规范中
默认为已实现。

建议生产采购下限：

| 组件 | CPU | 内存 | 本地磁盘 |
| --- | ---: | ---: | ---: |
| Collector/Ingress × 2 | 各 2 vCPU | 各 4 GiB | 各 20 GiB WAL |
| Phoenix | 4 vCPU | 8 GiB | 20 GiB 系统盘 |
| PostgreSQL | 8 vCPU | 32 GiB | 1 TiB SSD 起步 |

最终容量必须按 canary 数据重算；采购下限不能替代压测。

### 12.3 容量模型

必须测得：

- A：日活开发者；
- T：每人每天 turn 数；
- S：每 turn 平均/p95 span 数；
- B：每 span 平均/p95 持久化字节；
- P：峰值 spans/second；
- R：保留天数；
- F：索引、WAL、VACUUM 和安全余量系数。

计算：

~~~text
daily_spans = A × T × S
daily_storage = daily_spans × B
provisioned_storage = daily_storage × R × F
~~~

F 不得低于 2。磁盘持续使用超过 60% 进入扩容预警，超过 75% 阻止扩大用户范围。
生产压测必须承受 canary 实测峰值的 2 倍，持续 30 分钟。

### 12.4 采样

- Canary 使用 100% trace，避免因采样掩盖数据契约问题。
- 如果 30 天全量保留能满足容量和查询 SLO，生产继续全量，不增加采样复杂度。
- 只有全量不满足时才启用 tail sampling。
- tail sampling 必须保留 error、abort、timeout、慢 trace 和选定 canary 身份；
  普通成功 trace 按 trace ID 做概率采样。
- 多 Collector 执行 tail sampling 时，必须按 trace ID 路由，确保同一 trace 的全部 span
  进入同一处理实例。
- 采样规则是版本化生产配置，不能只在 UI 中修改。

## 13. 保留、备份和恢复

### 13.1 保留策略

| 数据 | Canary | Production |
| --- | ---: | ---: |
| Agent Trace | 7 天 | 30 天 |
| Collector operational log | 7 天 | 30 天 |
| Phoenix/PostgreSQL audit/access log | 30 天 | 180 天 |
| 脱敏评估数据集 | 不自动产生 | 经审批后按数据集策略 |
| 备份 | 7 天 | 每日增量 30 天、每周全量 12 周 |

禁止通过直接修改 Phoenix 数据库表结构实现 retention。使用所选版本支持的 retention
接口；数据库和应用升级必须一起验证删除行为。

### 13.2 恢复目标

- Agent Trace 平台 RPO：24 小时；
- UI/查询 RTO：4 小时；
- Collector 单实例故障：不影响接入；
- 后端短时故障缓冲目标：至少 15 分钟实测峰值；
- 备份恢复演练：每季度一次。

恢复演练必须证明：

- Phoenix 能连接恢复后的 PostgreSQL；
- 随机抽取的 trace 父子关系和 token 字段完整；
- RBAC 和 SSO 限制仍生效；
- retention job 恢复；
- 禁止字段和 canary secret 不存在于数据库、备份和日志。

## 14. SLO、指标和告警

### 14.1 Agent Trace 服务等级目标

| 指标 | 初始目标 |
| --- | ---: |
| DSH 任务因观测链路失败数 | 0 |
| DSH turn 延迟增幅 p95 | < 2% 或 < 50 ms，取更宽者 |
| Trace 从 turn 结束到 UI 可见 p95 | < 30 秒 |
| 正常状态 Collector send failure | 0 |
| 正常状态 Collector queue drop | 0 |
| Trace 版本关联完整率 | 100% |
| 禁止内容检出 | 0 |
| Phoenix 常用查询 p95 | < 3 秒 |
| 平台月可用性 | 99.0% |

前 30 个有效 canary 工作日可以校准性能阈值，但“禁止内容为零”“不影响 DSH”“版本关联
完整率 100%”不能放宽。

### 14.2 必须可观察的运行信号

- Ingress request、401/403、429、5xx、bytes 和 latency；
- Collector receiver accepted/refused；
- exporter queue size/capacity；
- exporter sent/failed/dropped；
- retry 次数和 WAL 使用；
- Phoenix health、ingestion error 和 query latency；
- PostgreSQL connection、CPU、内存、磁盘、WAL、lock 和慢查询；
- 备份新鲜度和最近恢复演练结果。

Canary 中 Prometheus/Alertmanager 尚未引入前，这些信号由短期 scrape、systemd
health、结构化日志和每日自动验收报告覆盖；该方式只允许用于 Phase 1。Phase 2 起必须
由第 7.6 节的 Prometheus + Alertmanager 自动告警，不能以人工巡视作为长期方案。

## 15. 故障语义和降级

| 故障 | DSH 行为 | 平台行为 | 运维动作 |
| --- | --- | --- | --- |
| Ingress 不可达 | turn 正常完成 | 客户端内存队列有限重试 | 检查网络/证书 |
| 单 Collector 失败 | 经 LB 切换 | 另一实例继续；故障实例 WAL 待恢复 | 替换实例 |
| Phoenix 不可用 | turn 正常完成 | Collector queue/WAL 缓冲 | 恢复应用 |
| PostgreSQL 不可用 | turn 正常完成 | Phoenix 失败；Collector 缓冲 | 恢复 DB |
| 客户端队列满 | turn 正常完成 | 允许丢 trace | 产生 drop 证据并扩容/采样 |
| 认证失效 | turn 正常完成 | 返回 401；不降级匿名写入 | 轮换 token |
| 脱敏规则异常 | 拒绝进入后端 | fail-closed 于遥测数据，fail-open 于 DSH | 回滚配置 |
| 磁盘超过 75% | turn 正常完成 | 停止扩大用户；按保留策略清理 | 扩容/降采样 |

“遥测数据 fail-closed、用户任务 fail-open”是强制语义：字段无法分类或脱敏失败时宁可
丢弃该 span，也不能把原始内容写入后端；同时不能让该错误中断 Agent。

当前 LoongSuite 没有已验证的客户端 queue-drop 可观测接口。生产扩大到 200 人前，
必须通过上游版本或 Gerrit fork 提供 drop counter/限频告警；只调大 maxQueueSize
不能替代这个要求。

## 16. 测试与验收

### 16.1 单元和配置测试

- LoongSuite 配置必须显式断言 enabled、captureContent 和 exportMetrics；
- Collector OTTL 配置做语法检查；
- 对每个允许字段和禁止字段建立输入/输出 fixture；
- session.id 映射必须有 contract test；
- token 聚合查询不得双计 AGENT 与 LLM；
- 未登记 attribute 必须被拒绝或删除；
- 生产配置不得出现明文 Authorization。

### 16.2 OTLP Contract Test

使用本地受控 OTLP receiver 接收真实 LoongSuite protobuf，验证：

- ENTRY → AGENT → STEP → LLM/TOOL 父子关系；
- retry 产生独立 LLM span；
- tool call/result 按 call ID 关联；
- abort、timeout、stream error 和 dispose 都关闭 span；
- subagent 带 parent/origin/delegation 属性；
- cache read 和 reasoning token 字段名正确；
- Phoenix 能按 session、model、tool、status、版本筛选。

### 16.3 隐私测试

构造唯一 canary 值，分别放入：

- prompt；
- completion；
- reasoning；
- tool schema；
- tool arguments/results；
- cwd、用户名和 repo URL；
- Authorization 和环境变量；
- stack trace 绝对路径。

测试必须搜索 Ingress log、Collector log/WAL、Phoenix、PostgreSQL、备份和导出证据。
任一命中即失败并阻止扩大用户范围。

### 16.4 兼容和用户旅程

至少覆盖：

- macOS arm64 + Web profile；
- macOS arm64 + Headless profile；
- Ubuntu Linux x86-64 + Web profile；
- Ubuntu Linux x86-64 + Headless profile；
- DSH 当前 pin + LoongSuite 当前 pin；
- Mock LLM 的确定性 journey；
- 少量凭据/预算隔离的真实 DeepSeek RC journey；
- normal、tool error、shell non-zero、LLM retry、abort、subagent。

shell non-zero 如果当前插件不能可靠识别，必须记录为已知限制并提供测试证据，不能把
“未标错”解释成工具成功。

### 16.5 故障和负载测试

- Ingress 拒绝、token 过期和 token 轮换；
- Collector kill/restart；
- Phoenix 停机 15 分钟后恢复；
- PostgreSQL 停机和连接耗尽；
- Collector queue/WAL 达到 50%、80%、100%；
- 客户端 queue 超限；
- 2 倍 canary 峰值持续 30 分钟；
- PostgreSQL 30 天投影数据量下的常用查询；
- 备份恢复；
- 版本升级和回滚。

### 16.6 Backend 选型 Gate

Phoenix 进入生产必须同时满足：

1. 数据契约和隐私测试全部通过；
2. 2 倍峰值下无正常状态 drop；
3. 常用查询 p95 < 3 秒；
4. 30 天容量投影保留至少 40% 空闲；
5. SSO/RBAC 能实现第 10.3 节；
6. 备份、恢复、升级和回滚全部实测；
7. 平台故障不影响 DSH journey；
8. SRE 接受日常运维和故障排查复杂度。

任一条未满足，Phoenix 不进入 200 人生产。此时使用相同 fixture 和负载测试 Langfuse；
只有 Langfuse 满足 Gate 且运维/EE 成本被正式接受，才替换 backend exporter。

## 17. 分阶段实施

### Phase 0：安全停用和契约基线

目标：组件可以构建，但在配置、脱敏和测试完成前不发送生产数据。

交付物：

- release profile 显式 enabled=false；
- Agent Trace schema 和 denylist 测试；
- Collector 最小配置和配置校验；
- ingest token 生命周期设计；
- 本地 OTLP receiver contract test；
- DSH 0.1.5-rc.2 的 Web/Headless smoke；
- 客户端不再生成 dsh.session.cwd 的上游版本或 Gerrit fork；
- 客户端 drop 可观测性的上游或 fork 决策。

退出条件：无默认外发、无 secret 入库、兼容 smoke 通过。

### Phase 1：5–10 人 Canary

目标：用真实但 content-free 的开发行为建立容量和体验基线。

交付物：

- 单 VM Ingress/Collector/Phoenix/PostgreSQL；
- 7 天 retention；
- 100% trace；
- macOS/Linux 双平台 canary；
- 隐私、故障、负载和恢复报告；
- Phoenix 与 Langfuse 是否需要对比的证据结论。

退出条件：第 16.6 节全部满足，连续 10 个工作日无 P0/P1 数据或稳定性事故。

### Phase 2：Staging

目标：建立可重复发布、双 Collector、备份和告警闭环。

交付物：

- dsh-observability-infra Gerrit 项目；
- Jenkins trusted pipeline；
- Nexus immutable images/config bundle/SBOM/provenance；
- 双 Collector/Ingress 和 WAL；
- Prometheus + Alertmanager 平台自监控；
- 30 天 retention；
- SSO/RBAC；
- 自动 health、queue、drop、backup 检查；
- 同 digest 自动部署 staging。

退出条件：故障、备份恢复、升级回滚和 2 倍峰值测试通过。

### Phase 3：200 人 Production

目标：分批扩大到全体用户。

批次：

1. 25 人，至少 5 个工作日；
2. 50 人，至少 5 个工作日；
3. 100 人，至少 5 个工作日；
4. 200 人。

每批扩大前重新检查：

- 禁止内容零命中；
- 正常状态 drop 为零；
- 客户端和 Collector 开销；
- PostgreSQL 磁盘增长和查询 p95；
- 告警噪声；
- 用户问题和权限越界。

任何 P0 立即回到上一批次或全局 enabled=false；P1 连续两次触发时暂停扩大。

### Phase 4：可选质量评估

只在 Trace 平台稳定后启动：

- 建立合成或人工脱敏数据集；
- 确定性完成率和工具正确性优先；
- LLM-as-a-Judge 仅为辅助分数；
- judge model、prompt、版本和结果全部可追溯；
- 生产 prompt 仍通过 Gerrit/Jenkins/Nexus 晋级。

## 18. 发布、回滚和紧急停用

### 18.1 发布

- staging 自动部署已签名 candidate；
- Release Manager 检查隐私、负载、恢复和兼容证据；
- production 只晋级同一 digest；
- 部署后运行 synthetic DSH journey 并验证 trace；
- 记录插件、Collector、Phoenix、PostgreSQL 和配置版本。

### 18.2 回滚

回滚优先级：

1. 将 DSH profile 中 LoongSuite enabled=false，立即停止新数据；
2. 回滚 Collector 配置；
3. 回滚 Phoenix 应用镜像；
4. 数据库只使用官方兼容迁移或从可恢复快照恢复；
5. 撤销泄漏或异常的 ingest/backend token。

关闭采集不能删除或覆盖 DSH session state。应用回滚与 PostgreSQL 数据恢复分开执行。

### 18.3 Break-glass

出现疑似敏感内容外发时：

1. 全局禁用 LoongSuite；
2. 吊销 ingest token；
3. 停止 Collector 向后端导出但保全访问审计；
4. 确定受影响 trace、数据库、WAL 和备份范围；
5. 由 Security 批准删除或隔离；
6. 修复 denylist 和测试后从 canary 重新开始。

## 19. 风险登记

| 风险 | 级别 | 控制 |
| --- | --- | --- |
| 插件默认启用且默认 OTLP 端点 | P0 | Phase 0 显式停用；配置测试 |
| cwd 和身份信息泄漏 | P0 | 客户端停止生成 + Collector 删除 + canary secret |
| 客户端 queue drop 不可见 | P0 | 上游修复或 Gerrit fork；生产 Gate |
| Phoenix/PostgreSQL 容量不足 | P1 | canary 实测、2 倍峰值、30 天投影、可换 Langfuse |
| 后端 secret 下发客户端 | P0 | 客户端只有 ingest token；backend secret 仅 Collector |
| Trace 被误当审计 | P1 | 四数据面分离；Gerrit/Jenkins/Nexus 为审计源 |
| 动态 prompt 绕过评审 | P0 | 生产只认 Git/Gerrit 版本 |
| Subagent trace 难关联 | P1 | parent session 字段规范化和 contract test |
| token 双计 | P1 | 查询只取 LLM 或 AGENT 单一层 |
| 后端故障拖慢 DSH | P0 | 3 秒 export timeout、fail-open、故障测试 |
| 文档容量数字被当事实 | P1 | 统一使用第 12.3 节实测模型 |
| 第三方版本升级漂移 | P1 | 精确 pin、SBOM、双平台回归、同 digest 晋级 |

## 20. 完成定义

只有同时满足以下条件，才能声明“DSH Agent 可观测平台生产可用”：

- Phase 0–3 全部退出条件满足；
- 200 人批次完成且连续 10 个工作日无 P0/P1；
- macOS arm64 和 Linux x86-64 用户旅程通过；
- 禁止内容在在线数据、日志、WAL 和备份中零命中；
- 客户端 drop 可观测，正常运行 drop 为零；
- Prometheus + Alertmanager 已覆盖平台自身健康、队列、丢弃、数据库和备份；
- Phoenix Backend Gate 全部通过，或已有正式 ADR 批准替代后端；
- SSO/RBAC、token 轮换、备份恢复、升级回滚已实测；
- 所有生产镜像和配置以 Nexus digest 交付；
- staging 自动验证、production 人工批准且使用同一 digest；
- 运维手册、告警路由、责任人和 incident 流程已评审；
- 当前仓库和 dsh-observability-infra 仓库的门禁全绿。

## 21. 参考资料

- [LoongSuite DSH plugin](https://github.com/loongsuite/dsh-plugin)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OpenTelemetry Gateway deployment pattern](https://opentelemetry.io/docs/collector/deploy/gateway/)
- [OpenTelemetry Collector resiliency](https://opentelemetry.io/docs/collector/resiliency/)
- [Phoenix self-hosting](https://arize.com/docs/phoenix/self-hosting/deploying-phoenix)
- [Phoenix Docker deployment](https://arize.com/docs/phoenix/self-hosting/deployment-options/docker)
- [Phoenix configuration](https://arize.com/docs/phoenix/self-hosting/configuration)
- [Langfuse OpenTelemetry integration](https://langfuse.com/integrations/native/opentelemetry)
- [Langfuse self-hosting](https://langfuse.com/self-hosting)
- [Langfuse Docker Compose limitations](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Langfuse self-hosted license features](https://langfuse.com/self-hosting/license-key)
- [Langfuse data masking](https://langfuse.com/self-hosting/security/data-masking)
- [Langfuse data retention](https://langfuse.com/docs/administration/data-retention)

外部资料只说明产品能力；本文定义 DSH 的实际采用方式。实施时必须固定具体版本并保存
离线文档或配置证据，不能假定网页内容长期不变。
