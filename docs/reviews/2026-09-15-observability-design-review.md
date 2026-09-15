# `docs/observability/README.md` 设计评审

| 属性 | 值 |
| --- | --- |
| 评审对象 | `docs/observability/README.md`（v0.1，状态「待评审」） |
| 评审日期 | 2026-09-15 |
| 评审依据 | **实测**：本会话对 LoongSuite 插件的真实运行（101 个 span，macOS arm64，DSH 0.1.5-rc.2，Web + Headless 双 profile）；**阅读**：插件源码、harness 源码、本仓组件目录与台账 |

> 与 `2026-09-14-repository-design-review.md` 同体例：**每条结论都标证据来源**。
> 凡标「实测」的，都可复现（原始 protobuf 与解码器见 §附录）。

## 0. 总评

规范的结构、边界划分与风险意识**明显高于本仓平均水平**：四数据面分离、fail-open/fail-closed
的分工写得很准，§12 主动声明容量数字不是承诺，§19 把「文档容量数字被当事实」列为风险——
这几条正是本仓反复被咬的形态，规范自己先堵上了。

**但它对「插件实际发什么」的描述与实测有系统性偏差**，且偏差集中在最要命的地方（§9 数据契约）。
照现在的清单直接实施 allowlist/denylist，会**删掉大量正常字段**，同时**漏掉两个真实的敏感字段**。

以下 7 条是**必须改**的，另 3 条是阶段可达性问题。

---

## A. 必须修正（会导致实施失败或数据泄露）

### A1 §9.2「允许字段」清单与实测严重不符 —— 按现状实施会误删

实测一次 13 步工具循环产生 **36 个 span 属性键**，与 §9.2 清单的**交集只有 14 个** ——
即 **22 个实测字段不在允许清单里**。缺失的包括：

`dsh.step` · `dsh.turn.end_reason` · `gen_ai.step.id` · `dsh.llm.attempt` ·
`gen_ai.react.round` · `gen_ai.react.finish_reason` · `gen_ai.tool.type` ·
`gen_ai.usage.total_tokens` · **`gen_ai.usage.cache_creation.input_tokens`** ·
`gen_ai.agent.id` · `gen_ai.agent.system` · `gen_ai.conversation.id` ·
`gen_ai.provider.name` · `gen_ai.request.reasoning_effort` · `gen_ai.span.kind` ·
`gen_ai.response.finish_reasons` · `gen_ai.response.time_to_first_token` · `gen_ai.turn.id` …

§16.1 要求「未登记 attribute 必须被拒绝或删除」。二者合起来的后果是：**正常 trace 会被删残**。

> 证据：实测（`inventory.mjs` 输出，见附录；交集 14 为逐键比对，非估计）。
> 建议：§9.2 改为「以实测清单为基线冻结」，并把那份清单直接放进文档（36 键，可粘贴）。

> **附带的命名层次问题**：§9.2 写的是 `session.id`，而插件实测发的是 `gen_ai.session.id`
> 与 `dsh.session.id`，**都不是 `session.id`**。§7.3 的 transform 负责把前者映射成
> `session.id`，所以契约在**两个层次上各有一份名字**。规范应显式区分「插件发出的名字」与
> 「Collector 之后的名字」，否则写 contract test 的人不知道该断言哪一侧。

### A2 §9.3 禁止清单漏了 `host.name`，且它落在**资源属性**上，§7.3 的 transform 删不到

实测资源属性里 `host.name = Michaels-MacBook-Pro.local` —— 含**用户名**。§9.3 禁「用户名、
邮箱、主目录和绝对路径」，却没有点名 `host.name`。

更要命的是上下文：`dsh.session.cwd` 是 **span** 属性（101/101，§7.3 的 `context: span` 能删），
而 `host.name` 与 `service.instance.id` 是 **resource** 属性 —— §7.3 给的 transform 示例只有
`context: span`，**对它们完全无效**。

> 证据：实测。
> 建议：§9.3 加入 `host.name`；§7.3 至少补一条 `context: resource` 的示例，并说明
> 「敏感字段分布在 span 与 resource 两个 context，只写 span 规则会漏」。

### A3 §9.1 要求 `service.instance.id` 做 HMAC，实测是 SDK 默认值

实测 `service.instance.id = deepseek-harness@Michaels-MacBook-Pro.local:12276` ——
这是 OTel SDK 的默认形式（`<service.name>@<hostname>:<pid>`），**裸主机名 + PID，无任何 HMAC**。

规范的要求是对的，但没写「必须覆盖 SDK 默认值」；不写就会被默认值静默满足（看起来有值），
而实际泄露主机名。

### A4 实测存在上游 SDK 自带的 `acs.arms.service.feature`，两个清单都没覆盖

资源属性里有 `acs.arms.service.feature = genai_app` —— 阿里云 ARMS 的供应商标识，
来自 `@loongsuite/otel-util-genai`，**不在 §9.1 允许清单、也不在 §9.3 禁止清单**。

它在 §16.1「未登记 attribute 必须被拒绝或删除」下应当被拒，但**没人会想到去禁它**——
因为没人知道上游 SDK 会自带。建议 §9.3 增加一条通则：**「非本规范 §9.1/§9.2 枚举的
resource 属性一律删除」**，而不是逐条列举。

### A5 span 名字与规范用的名字**不一致** —— 按字面写 contract test 必失败

| 规范 §8 / §16.2 的写法 | 实测的 span name |
| --- | --- |
| `ENTRY` | `enter_ai_application_system` |
| `AGENT` | `invoke_agent <agent preset>` |
| `STEP` | `react step` |
| `LLM` | `chat <model>` |
| `TOOL` | `execute_tool <tool>` |

规范那套是**语义层**的说法（README 里也是一张概念图），不是字面名。§16.2 要求
「验证 ENTRY → AGENT → STEP → LLM/TOOL 父子关系」，照字面实现会找不到 span。

> 附带发现：**span name 里嵌了 agent preset 名**（`invoke_agent standard`）。
> 若 preset 名不可控，span name 就是高基数字段。规范 §9.2 只约束了属性（`dsh.agent.preset`
> 的受控枚举），没约束 span name —— 而多数后端把 span name 当一等索引字段。

### A6 插件**不发 span event**，规范暗示的证据面不存在

实测所有 span 的 `events` 为空。§16.2 要求验「abort、timeout、stream error 和 dispose
都关闭 span」—— 可查的只有 **status**，而 status message 是**包装后**的。

实测例：一次失败 turn 的 status message 是 `DeepSeek request extension preparation failed`，
**底层的 `cause` 完全不出现在遥测里**（我追这个错误时，最终是从 session 库的
`turn/end.reason` 拿到同样包装过的消息，`cause` 始终不可得）。

> 建议：§16.2 写明「错误证据只有 span status；status 是**包装层**消息，不含 cause」，
> 免得验收人去找 exception event，或误以为拿到了根因。

### A7 §15 的「没有 queue-drop 可观测接口」属实，但**漏了同级的一条**：导出失败完全静默

- §15 的说法 ✅ 实测+源码确认：插件只有 `maxQueueSize` 配置，**没有 drop 计数、没有回调**。
- **但**：插件**不注册 OTel `diag`**（源码确认）。后果是**导出失败没有任何输出** ——
  实测：接收端未监听时，插件照常 `loaded`、照常每 5 秒尝试导出、**日志零行**。

§15 的故障表写「客户端内存队列有限重试」，但**运维看不见重试，也看不见失败**。这不是
队列深度问题，是**可观测性为零**。建议把它与 drop 并列为 Phase 0 的生产 Gate：
「导出失败必须可见（diag 或 drop counter）」，否则 §14.2 的「exporter sent/failed/dropped」
在客户端侧永远拿不到。

---

## B. 阶段可达性（规范与本仓现状冲突）

### B1 §17 Phase 0 的「release profile 显式 enabled=false」在本仓没有对应物

本仓 `make release` 是**源码快照 + tag**，不是运行 profile；`make deploy` 是 legacy、
**从未端到端跑通**（backlog B3）。所以「release profile」在本仓语境下需要定义：
是指 `patches/*.yml` 合并进 profile `dsh` 的那一层？还是指将要新建的部署 profile？
不定义清楚，Phase 0 的头号交付物无法验收。

> 可执行的最小形态（本仓现成机制）：新增 `patches/disable-loongsuite-by-default.yml`，
> 用 profile 用户 patch 层把 `enabled` 置 false。这是本仓**已有**的表达方式
> （先例 `patches/disable-plugin-package-inventory.yml`）。

### B2 Phase 2 依赖 Gerrit/Jenkins/Nexus，而这条链在本仓**尚未实现**

规范 §11.2 的晋级链、§12 的 Nexus digest、§17 Phase 2 的「Jenkins trusted pipeline」
都假定 CI/CD 主链已就绪。实际上（见 `docs/remediation-plan.md`）：

| 依赖 | 台账状态 |
| --- | --- |
| T3 Jenkins 信任边界 | 未开始，且**验证阻塞**（只有 2 台物理服务器） |
| T4 不可变制品（digest/SBOM/签名） | 未开始，**一行都没实现** |
| T5 制品/发布状态机 | 未开始 |

规范把 Phase 2 写成可执行，实际是**依赖未落地的前置**。建议在 §17 显式标注依赖，
否则 Phase 2 会像本仓过去的「声称 Linux 绿」一样，停留在纸面。

### B3 §11.1 的 `dsh-observability-infra` 仓库不存在

「新建 Gerrit 项目」是 Phase 2 的交付物，但 §11.1 已把它当作权威仓库引用。前后措辞
需要对齐（是「将新建」还是「已存在」）。

---

## C. 建议改进（不致命，但会埋坑）

### C1 §7.1 的 config 片段没写「整表替换」语义 —— 本仓已被这个咬过

patch 的 `config` 是**整表替换、不是深合并**。本仓为此专门留了
`patches/restore-web-fetch-provider.yml`（modsearch 的 patch 只列了一个键，把
`fetchProvider` 抹掉，而 dump 与 boot 都全绿）。

§7.1 的片段列了 10 个键、插件 schema 有 **16** 个。**当前是安全的**（插件自己的 insert 没带
config，替换无损失）—— 但规范应在片段旁点名这条语义，否则后来者加一个键就会静默抹掉其它键。

### C2 §3 关于 `dsh.session.cwd` 的判断**实测属实**（值得肯定）

「captureContent 默认关闭，但仍会输出 dsh.session.cwd」—— 实测 **101/101 span 都有该属性**，
在 `captureContent: false` 下。这是全篇与实测最吻合、也最有价值的一条判断。

### C3 §16.4 的 macOS 兼容性**已经验过一半了**

规范要求「macOS arm64 + Web」「macOS arm64 + Headless」。实测（本会话）：

- macOS arm64 / DSH `0.1.5-rc.2` / Web profile → 真实 turn，13 步工具循环，trace 完整 ✅
- macOS arm64 / DSH `0.1.5-rc.2` / Headless profile → 真实 turn，trace 完整 ✅

即 §17 Phase 0 的「DSH 0.1.5-rc.2 的 Web/Headless smoke」**macOS 侧已完成**，
只剩 Linux x86-64。规范可以直接引用这个结论，不必从零开始。

> ⚠️ 但注意：上游 README 声称只对 `0.1.0-rc.6` 做全量验证。我们在 `0.1.5-rc.2` 上的通过
> 是本仓自测，建议同时报上游更新其兼容表（这也是本仓「待报上游」清单里可以加的一条）。

### C4 §17 Phase 0 的两项交付物**完全依赖上游**，建议写明 fork 触发时限

「客户端不再生成 dsh.session.cwd」与「客户端 drop 可观测性」都指望上游发版。规范自己说
「上游不能按期提供时走 Gerrit fork」（§11.1），但**没有时限**。没有时限的 Gate 会无限期挂着。
建议写明：**Phase 0 启动后 N 周无上游承诺，即启动 fork 流程**。

---

## 附录：证据与复现

| 项 | 位置 |
| --- | --- |
| 真实 protobuf 载荷 | `/tmp/dsh-live/`（含 13 步工具循环的完整 trace） |
| 字段清单脚本 | `/tmp/dsh-otel-trial/inventory.mjs`（本评审 §A1/A2/A4/A5 的数据源） |
| OTLP 解码器 | `/tmp/dsh-otel-trial/decode.mjs`（与 SDK 原生 span 交叉验证过） |
| 101 span 的汇总 | 见本评审各条引用的计数 |

> ⚠️ 以上都在 `/tmp`，会被系统清理。若本评审要长期作为依据，需把解码器与清单脚本
> 纳入仓内（见 `docs/backlog.md` 的同类考虑）。
