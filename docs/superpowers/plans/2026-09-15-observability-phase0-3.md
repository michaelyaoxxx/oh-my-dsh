# 可观测平台 Phase 0–3 实施方案

> 依据：[`docs/observability/README.md`](../../observability/README.md)（目标态规范，待评审）
> ＋ [`docs/reviews/2026-09-15-observability-design-review.md`](../../reviews/2026-09-15-observability-design-review.md)（评审，7 条必修）
> 基线台账：[`docs/remediation-plan.md`](../../remediation-plan.md)（T0–T12）
>
> **本方案只回答「在本仓怎么做、现在能不能做」。** 规范定义的目标态不在此复述。

## 0. 总览：三个阶段的可达性

| 阶段 | 本机可做 | 需基础设施 | 需上游 | 需授权 | 现在能开始吗 |
| --- | --- | --- | --- | --- | --- |
| **Phase 0** | 大部分 | 一项（Collector） | 两项 | 否 | ✅ **能，且部分已完成** |
| **Phase 1** | 少量 | 大部分 | — | ✅ 需要 | ⚠️ 需先有 Linux VM 与授权 |
| **Phase 2** | 纯规格 | 全部 | — | ✅ 需要 | ❌ **阻塞**：依赖 T3/T4/T5 |
| **Phase 3** | — | — | — | ✅ 需要 | ❌ 依赖 Phase 2 |

**一句话**：Phase 0 可以现在做完；Phase 1 卡在"没有可用的部署目标 + 未授权"；
Phase 2/3 卡在本仓 CI/CD 主链**尚未实现**（T3 Jenkins 信任边界、T4 不可变制品、T5 制品状态机
在台账里都是"未开始"，其中 T4「一行都没实现」）。

**所以本方案把 Phase 2/3 写成依赖清单而非执行步骤**——写了执行步骤也跑不了，
那正是本仓"声称 Linux 绿却从未在 Linux 上跑过"的同一形态。

---

## Phase 0：安全停用与契约基线

### P0-0（前置）先修规范的契约条款

评审 A1–A7 里，**A1/A2/A5 是 Phase 0 的直接输入**：契约清单错了，后面的 denylist 与
contract test 就是照错的靶子练。建议顺序：

1. 按评审 A1 用实测清单冻结 §9.2（36 键，交集 14 的差集 22 项必须补）；
2. 按 A2 把 `host.name` 列入 §9.3，并补 `context: resource` 的 transform 规则；
3. 按 A5 把 span name 改成实测字面名（或显式标注"语义层 vs 字面层"）；
4. A3/A4/A6/A7 同批修。

> 这是**改规范文档**，不改代码。产出：`docs/observability/README.md` 的 v0.2。

### P0-1 默认停用（规范 §17 第一项）

**规范要求**：release profile 显式 `enabled=false`。
**本仓现状**：没有 "release profile"——`make release` 是源码快照 + tag，`make deploy` 是
legacy 且从未跑通（backlog B3）。所以这一项要**先定义形态**。

**候选形态（推荐 a）**：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **a. patch + `!!js` 条件** | `patches/loongsuite-observability-default-off.yml` 里写 `enabled: !!js process.env.DSH_OTEL_ENABLED === 'true'` | profile patch 的 `!!js` 求值时机**未验证**，要先验 |
| b. 默认 off + 新 Makefile 目标 | 默认 `enabled: false`，新增 `make dev-otel` 在启动前改写 profile patch | 多一个目标；改写运行时文件，与"配置走 Git"冲突 |
| c. 独立 profile | 生产用独立 profile 名，dev profile 保持现状 | 本仓实际使用的 profile 只有 `dsh`（`make dev`）与 `tui`（`make dev-tui`，且 TUI 非重点）；新建一个等于多一套要维护的组合 |

**验收**：`dsh --profile dsh --dump-config` 里该 entry 的 `enabled` 为 false（或不存在），
且插件日志**不出现** `loaded; traces=…`。

> ⚠️ 注意：即便 `enabled: true` 而没有任何 endpoint，插件会静默对着
> `http://localhost:4318` 空发失败（实测：日志零行）。所以"停用"必须是**显式**的，
> 不能靠"没配端点"来隐式达成。

### P0-2 契约测试与断言（规范 §16.1 + §16.2 的可离线部分）

**这是本阶段最实的一块，且工具已经存在**（本会话为排查真实故障做的，已验证）。

| 交付物 | 本仓落地形态 | 状态 |
| --- | --- | --- |
| OTLP receiver（受控接收端） | `scripts/otel-sink.mjs` | 已有原型（`/tmp/dsh-otel-trial/sink.mjs`），**需入库** |
| OTLP protobuf 解码器 | `scripts/otel-decode.mjs` | 已有原型，**需入库**；与 SDK 原生 span 交叉验证过 |
| 字段清单（冻结契约） | `scripts/otel-contract.mjs` + `config/trace-contract.json` | 原型 `inventory.mjs`，需转成"断言"而非"打印" |
| span 树断言 | 断言 `enter_ai_application_system → invoke_agent … → react step → {chat, execute_tool}` | 待写 |

**建议的接法**：`config/trace-contract.json` 冻结允许/禁止键；一个**离线**断言脚本
（fixture 驱动）挂进 `scripts/check-all.sh --offline` 组，这样 `make check` 与 CI 的
step 0 自动覆盖它——不需要网络、不需要构建、不需要 Collector。

**验收**：`make check` 里出现该断言项；故意在 fixture 里加一个禁止键，断言必须变红
（与 `scripts/probe-*.sh` 同体例：**每条规则都要有会失败的样本**）。

### P0-3 本地端到端 smoke（规范 §16.4 的 macOS 半侧）

**已经完成**（本会话实测）：

| 项 | 结果 |
| --- | --- |
| macOS arm64 + Web profile + DSH 0.1.5-rc.2 | ✅ 真实 turn，13 步工具循环，trace 完整 |
| macOS arm64 + Headless profile + DSH 0.1.5-rc.2 | ✅ 真实 turn，trace 完整 |

**剩余**：Ubuntu Linux x86-64 的 Web/Headless —— 见 Phase 1 的前置。

### P0-4 ingest token 生命周期设计（规范 §10.4）

纯规格，本机可做。产出：token 签发/轮换/撤销流程 + 与 Secret 系统的接口 + 90 天轮换演练方案。
**注意**：规范要求 token 不得进 YAML/Git/日志/dump-config——`dsh --profile dsh --dump-config`
会打印 entry 的 config，所以**任何写进 config 的 secret 都会出现在 dump 里**。设计必须只用
环境变量注入，并在验收里加一条"dump-config 输出无 secret"。

### P0-5 Collector 最小配置（规范 §7.3）—— **部分阻塞**

配置文本可以现在写（OTTL 语句、denylist、batch、retry、queue），但：

- `otelcol validate` 需要 Collector 二进制 → 本机**没有 docker**（实测）；
- 所以"配置校验"这一项**只能写不能验**，除非装 docker 或拿一台机器。

**处置**：先写配置 + 写校验脚本（`scripts/check-collector-config.sh`，调用 `otelcol validate`），
把"未验证"标注清楚；等有环境再跑。

### P0-6 依赖上游的两项（规范 §17 的第 7、8 项）—— **外部依赖**

- 客户端停止生成 `dsh.session.cwd`（实测：**101/101 span 都带**）；
- 客户端 queue-drop / 导出失败可观测（实测+源码确认：**无计数、无回调、未注册 diag**）。

**处置**：先提上游 issue（本仓已有"待报上游"清单的体例）。建议同时按评审 C4
**写明 fork 触发时限**——否则这两项会无限期挂着，而它们是生产 Gate。

---

## Phase 1：5–10 人 Canary

### 前置（都是硬前置，缺一不可）

| # | 前置 | 现状 |
| --- | --- | --- |
| 1 | 一台隔离 Linux VM（规范 §12.1：8 vCPU / 32 GiB / 500 GiB） | 有目标机 `10.126.126.128`（Ubuntu 24.04 / x86_64 / 1.8T 盘 / 125G 内存），**资源远超要求**；但 `sudo` 需要密码 → 装服务需用户操作 |
| 2 | 安装 Ingress / Collector / Phoenix / PostgreSQL | **需授权**（AGENTS.md：在目标机上安装软件必须显式授权） |
| 3 | Phase 0 的 P0-1/P0-2/P0-6 完成 | P0-2 可做；P0-1 待定形态；P0-6 待上游 |
| 4 | Linux x86-64 的 Web/Headless smoke | 未做 |

### 交付物 → 本仓形态

| 规范交付物 | 本仓形态 | 备注 |
| --- | --- | --- |
| 单 VM 四件套 | 部署清单 + systemd unit（**不用** `make deploy`——规范 §4.2 已声明不用 legacy deploy） | 与 T0a 的部署守卫同族，可复用其危险路径守卫 |
| 7 天 retention | PostgreSQL 侧配置 | |
| 100% trace | 无采样 | |
| 双平台 canary | macOS 已就绪，Linux 待做 | |
| 隐私/故障/负载/恢复报告 | **报告体例**建议复用本仓的「已验证/未验证」格式 | |

### 退出条件（规范 §17）

第 16.6 节 Backend Gate 全部满足 + 连续 10 个工作日无 P0/P1。**这一条无法加速**。

---

## Phase 2：Staging —— **阻塞，依赖本仓未实现的 CI/CD 主链**

规范 §17 Phase 2 的交付物与它们的真实依赖：

| 规范要求 | 依赖 | 台账状态 |
| --- | --- | --- |
| `dsh-observability-infra` Gerrit 项目 | Gerrit 可用 | 主链未起 |
| Jenkins trusted pipeline | **T3** Jenkins 信任边界 | ⬜ 未开始，且**验证阻塞**（只 2 台物理服务器，不足以隔离三类执行者） |
| Nexus immutable images/config/SBOM/provenance | **T4** 不可变制品 | ⬜ 未开始，**一行都没实现** |
| 同 digest 自动部署 staging | **T5** 制品/发布状态机 | ⬜ 未开始 |
| 双 Collector + WAL | 上述制品链 | 阻塞 |
| Prometheus + Alertmanager | 上述 | 阻塞 |

**结论**：Phase 2 **不可能在 T3/T4/T5 落地前完成**。建议在规范的 §17 显式标注这条依赖——
否则 Phase 2 会变成一纸空文，而本仓已经有 `make deploy` 这个"写了但从未跑通"的先例。

**本机现在能做的**：把 Phase 2 需要的**规格**写出来（制品清单、digest 晋级流程、回滚路径），
作为 T4/T5 的输入。这是纯规格，不阻塞。

---

## Phase 3：200 人 Production

依赖 Phase 2。**本方案不写执行步骤**——写了也是编的。

唯一现在能做的准备：定义**分批扩大的度量口径**（规范 §17 的六项复查指标），
并确认这些指标在 Phase 1 的采集手段里**都拿得到**。拿不到的（例如"客户端 drop 为零"——
P0-6 未完成前根本测不到），应当**提前暴露**，而不是等到扩批时才发现。

---

## 建议的执行顺序（依赖排序）

~~~text
P0-0 修规范契约条款        ← 现在就能做，且是后面一切的前置
  ├── P0-2 契约测试入库    ← 工具已存在，转成断言挂进 make check
  ├── P0-1 默认停用形态     ← 需先验 profile patch 的 !!js 求值
  ├── P0-4 token 设计       ← 纯规格
  └── P0-5 Collector 配置   ← 写得了、验不了（无 docker）
P0-6 提上游 issue（含 fork 时限）
  └── Phase 1 前置：Linux smoke + 授权 + 装服务
        └── Phase 2 前置：T3/T4/T5
              └── Phase 3
~~~

## 未验证与已知缺口

- **profile patch 的 `!!js` 求值时机**：未验证。P0-1 若走方案 a，必须先验。
- **Collector / Phoenix / PostgreSQL 本机一个都没跑过**：无 docker，未验证。
- **Linux x86-64 侧全部未验证**。
- **`make check` 依赖联网 fetch**：本会话已两次遇到瞬时失败（dsh-automation、dsh-web）
  导致 rc≠0。这是 `check-pins.sh` 的设计（pin 校验必须联系 origin），但排查时要知道
  "红"未必是代码问题——**先重试再下结论**。
