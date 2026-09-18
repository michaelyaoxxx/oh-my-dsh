# deepseek-harness 项目代码全景分析

> 分析日期：2026-09-16
> 分析方式：静态扫描（排除 `node_modules` / `.git` / `lib / dist / build` 构建产物、`.map` / `.d.ts` / `tsbuildinfo`）

---

## 一、项目总体规模

| 指标 | 数值 |
|---|---|
| 总代码行数（纯逻辑代码，去空行/注释） | **≈ 80.2 万** |
| 源文件总行数（TS/TSX/TS+Py 等源码） | **≈ 89.1 万** |
| 仓库文本总行数（含 JSON/Markdown/配置） | **≈ 186 万** |
| 文件总数（仓库磁盘，含依赖外全部） | **19,494** |
| 分析文本文件数 | **7,920** |
| 平均文件长度 | **≈ 235 行/文件** |
| 子目录数 | **1,634** |
| 包（package）数 | **284**（其中 54 个模块组） |

> 仓库内还含大量 Schema 快照（`docs/persistence-changes/*.schema.json`，约 60 万行）与文档，
> 故“纯代码行”与“文本总行”差距较大。若只看工程源码（TS+TSX+Python），约 89 万行。

### 顶层目录分布

| 目录 | 文本行数 | 文件数 | 占比 |
|---|---|---:|---:|
| `packages/` | 924,217 | 5,373 | **49.6%** |
| `docs/` | 706,478 | 526 | **37.9%** |
| `scripts/` | 80,753 | 286 | 4.3% |
| `apps/` | 69,287 | 490 | 3.7% |
| `snapshots/` | 64,778 | 1,042 | 3.5% |
| `python/` | 4,732 | 37 | 0.3% |
| `vendor/`（框架基座源码） | **7,810** | 73 | 0.4%（本源码占比：TS 6,191 行） |
| `native/` | 3,969 | 79 | 0.2% |
| 根目录（配置） | 3,717 | 44 | 0.2% |
| `benchmarks/` | 2,943 | 34 | 0.2% |
| `website/` | 998 | 8 | 0.1% |

> `vendor/` 是被依赖最广的框架层目录（源码 6,191 行 TS、9 个包），虽占比小但影响力全仓第一。

---

## 二、核心模块分析

`packages/` 下按业务/工程归属拆分（源码行 = TS + TSX + Python，不含构建产物）：

| # | 模块 | 源码行数 | 占比 | 职责说明 |
|---|---|---|---|---:|
| 0 | **vendor（框架基座）** | 6,191 | 0.8% | 9 个 `@deepseek-ai` 源码式 vendored 包：Cordis 插件元框架（4.0.2，被 294 包引用）、loader/include/timer/hmr/group/logger-console 插件、schemastery schema 校验器（被 132 包引用）、cosmokit 工具集；额外 19 条本地增强 |
| 1 | **client（Web/客户端 UI）** | 199,953 | 25.8% | 53 个子包：Web 前端、React UI（chat/session/settings/tool/plan/workspace 等）、客户端运行时、连接、locale、store |
| 2 | **experimental（实验性能力）** | 72,111 | 9.3% | 16 个子包：前沿/未稳定的实验特性、Inspector 等 |
| 3 | **api（API/网关）** | 46,677 | 6.0% | 网关 gateway（流式协议）、session/settings/workspace/terminal 控制器、remotes 远程端点 |
| 4 | **core（核心引擎）** | 45,850 | 5.9% | agent 核心运行时：会话状态机、事件总线、服务生命周期（基于 Cordis） |
| 5 | **session（会话管理）** | 40,830 | 5.3% | 19 个子包：会话生命周期、持久化、投影缓存、会话快照 |
| 6 | **llm（大模型接入）** | 37,058 | 4.8% | LLM Provider 抽象、DeepSeek 私有协议扩展、模拟/重放服务（llm-mock-server） |
| 7 | **subagent（子代理）** | 35,434 | 4.6% | 子 agent 派生、进程内/独立进程驱动、subagent 工具控制 |
| 8 | **extensions（扩展生态）** | 23,466 | 3.0% | 插件/扩展注册机制，everything-is-a-plugin 架构支撑 |
| 9 | **test-support（测试支撑）** | 22,476 | 2.9% | agent-loop-testkit、llm-replay、session-snapshot、remote-mock 等测试基础设施 |
| 10 | **session-query（会话查询）** | 15,477 | 2.0% | 会话历史查询、日志导出、投影查询 |
| 11 | **typert（类型系统）** | 15,314 | 2.0% | 类型模型生成/加载/注册/协议，跨进程类型契约 |
| 12 | **subprocess / fs / shell / context / budget/ssh 等** | ~89,021 | 11.5% | 进程管理、文件系统、Shell、上下文引用、SSH/沙箱等基础设施 |

> **packages 源码合计：≈ 774,364 行**（TS+TSX+Py）
> **vendor 框架基座源码：≈ 6,191 行**（TS）
> **工程源码总计 ≈ 780,555 行**（packages + vendor）

### 主要应用（apps）

| 应用 | 源码行 | 说明 |
|---|---:|---|
| `apps/web` | 33,602 | Web 前端（主要 UI 载体） |
| `apps/cli` | 11,474 | CLI（`dsh` 命令入口） |
| `apps/desktop` | 8,515 | 桌面端（Electron） |
| `apps/desktop-host` | 804 | 桌面 Host 层 |

---

## 三、编程语言统计（按文本行）

| 语言 | 行数 | 占比 | 主要用途 |
|---|---:|---:|---|
| **TypeScript (+TSX)** | 890,969 | 47.9% | 主语言：核心引擎、前后端、CLI |
| **JSON** | 677,493 | 36.4% | 持久化 Schema 快照、依赖清单、i18n、manifest |
| **Markdown** | 220,678 | 11.9% | 文档体系（i18n 多语言，约 329 篇） |
| **CSS** | 22,136 | 1.2% | Web 样式 |
| **YAML** | 13,808 | 0.7% | CI/CD、配置 |
| **Python** | 9,488 | 0.5% | Python SDK / sdk-runtime |
| **JavaScript** | 6,401 | 0.3% | 脚本、.github 自动化 |
| **C / C++** | 670 | <0.1% | native/landlock-run 沙箱 |
| **Shell** | 406 | <0.1% | 构建/运维脚本 |

> 若仅统计“逻辑代码”（去 JSON/Markdown/配置）：TypeScript 约 **77 万行**，占比 **~96%**，
> 是绝对的工程语言主体。
>
> **vendor 层语言构成**：TS 6,191 行（34 文件，占比 79%）、Markdown 823 行（12 文件）、JSON 598 行（18 文件）——纯 TypeScript 的框架层。

---

## 四、工程规模指标

| 指标 | 数值 |
|---|---:|
| 总代码行数（逻辑代码） | ≈ 801,650 行（TS 为主，含 vendor 6,191 行） |
| 总文件数 | 7,920（分析口径） / 19,494（含构建产物） |
| 平均文件长度 | ≈ 235 行 |
| 模块数（包） | 284 个包（54 个模块组）+ **vendor 9 个框架包** |
| 子目录数 | 1,634 |
| Service 数量 | 38（含 client service.ts 12 + 后端服务） |
| API 数量 | 69 个 controller/router/route 入口 + 7 个 API 包（含 gateway 流式网关） |
| Docker 相关文件 | 0（客户端/SDK 仓库，无容器部署配置） |
| CI/CD 配置数量 | **22**（20 个 GitHub Actions workflow + `.gitlab-ci.yml` + `dependabot.yml`） |
| 测试文件数 | 1,221（`.spec.ts` / `.test.ts`） |
| 文档 .md 篇数 | 329（含多种语言翻译） |
| 框架基座（vendor） | 9 包、源码 6,191 行、被全部仓库包依赖（cordis 294 / schemastery 132 / loader 67 / include 44） |

---

## 五、架构要点

- **Monorepo**：pnpm workspace（`packages/*/*`、`apps/*`、`python/sdk`、`native/system`、`website`、`vendor`）
- **everything-is-a-plugin**：所有能力以插件形式注册，基于 **Cordis** 框架
- **框架自持（vendor）**：`vendor/` 以源码形式 vendored Cordis 框架及基础库（9 个 `@deepseek-ai` 包），可审计、可打补丁、锁定版本；含 19 条本地增强（fiber 生命周期加固、懒配置解析、配置写回重试、Node 兼容检测等）
- **双面构建**：host（后端/Node）与 client（前端/浏览器）两套 TypeScript 构建面
- **产物拓扑**：packages（库）→ apps（产品装配）→ bundle（打包组合：web/sdk/headless/acp）
- **远程协议**：`api/gateway` 提供流式通信协议（snapshot/event/stream）
- **安全沙箱**：`native/landlock-run`（C 实现的 Landlock 沙箱启动器）
- **Python 生态**：`python/sdk` 与 `python/sdk-runtime`（单文件 exe 分发）
- **测试策略**：vitest 多配置（unit / e2e / bench / web / snapshot / expected），agent-loop 测试工具包

---

## 六、项目亮点（管理层摘要）

0. **框架自持（vendor 基座）**：`vendor/` 源码级 vendored Cordis 框架层（9 包、6,191 行 TS），`@deepseek-ai/cordis` 被 294 个包引用、`schemastery` 被 132 个包引用，位居全仓包级被依赖前二；19 条本地增强实现对框架层的完全掌控。
1. **体量对标一线 Agent 平台**：28 万行级工程、284 个包、54 大模块，覆盖核心引擎到 Web/CLI/桌面三端，工程复杂度完整。
2. **API/网关与流式协议自研**：`api/gateway` 实现会话/事件/快照流式传输，7 个 API 包 + 69 个路由入口，为多端远程协做（SSH/Web）提供统一底座。
3. **测试与质量基建厚实**：1,221 个测试文件、agent-loop 测试工具包、22 条 CI/CD 流水线、快照回归体系，质量保障体系成熟。
4. **多语言 SDK 与生态**：TypeScript 主体之外提供 Python SDK、桌面端与 Web 端，支持插件生态（dsh-plugin），产品化与开放程度高。
5. **安全与沙箱内建**：Landlock 原生沙箱（C 实现）+ SSH 沙箱 + 权限预设，从架构层面内置安全隔离，适合生产级交付。
