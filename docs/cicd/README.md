# DSH CI/CD 设计与实施文档

| 属性 | 值 |
|---|---|
| 状态 | 已批准设计，尚未完成工程实施 |
| 版本 | 1.0 |
| 最后更新 | 2026-09-14 |
| 适用范围 | 内网 `dsh` 超级仓库、自维护 fork、Gerrit、Jenkins、Nexus、staging 与 production |
| 目标平台 | macOS arm64；Ubuntu Linux x86-64 |

## 1. 文档目的

本目录是 DSH CI/CD 的设计与实施事实源。它定义目标架构、质量门禁、制品模型、自动化回归、部署与运维要求；流水线或脚本不得另行复制同一规则。

本设计遵循以下边界：

1. Gerrit 托管并评审 `dsh` 主仓与自维护 fork；第三方 submodule 继续以 GitHub 为上游。
2. Jenkins 在 Linux x86-64 与 macOS arm64 上分别原生构建，禁止跨平台共享 `node_modules` 或原生产物。
3. staging 自动部署并运行发布回归；production 只接受人工批准后的同一制品 digest。
4. 发布测试验证终端用户旅程，不以“进程能启动”或单元测试通过替代功能验收。
5. Gerrit 与 Jenkins Controller 分别运行在两台内网物理服务器；环境可受控访问互联网，但源码、凭据、制品、证据和用户数据默认留在内网。
6. GitHub Actions 只保留未来开源兼容检查，不参与内部 `Verified`、制品晋级、部署或发布授权。
7. TUI 是后期 feature，当前不纳入 CI/CD 构建、门禁、制品或回归范围。

## 2. 文档导航

| 文档 | 读者 | 内容 |
|---|---|---|
| [01-architecture.md](01-architecture.md) | 架构师、平台工程师 | 现状、目标、逻辑/物理架构、系统边界、数据流和控制流 |
| [02-gerrit-and-jenkins.md](02-gerrit-and-jenkins.md) | Gerrit/Jenkins 管理员、开发者 | 评审门禁、事件、Job、Pipeline、并发与失败处理 |
| [03-artifact-and-release.md](03-artifact-and-release.md) | Release Manager、平台工程师 | Nexus、制品格式、版本、晋级、签名、供应链证据 |
| [04-test-strategy.md](04-test-strategy.md) | QA、插件维护者、开发者 | headless、Playwright、核心和插件发布回归矩阵 |
| [05-deployment-runbook.md](05-deployment-runbook.md) | SRE、值班人员 | staging/production 部署、健康检查、回滚和应急操作 |
| [06-security-and-operations.md](06-security-and-operations.md) | 安全、SRE、管理员 | 权限、凭据、网络、审计、SLO、备份与灾备 |
| [adr/](adr/) | 所有人 | 已批准且需要长期保留的架构决策 |
| [backup/](backup/) | 维护者 | 重构前历史文档原文；仅用于追溯，不具备规范效力 |

`reference/` 只保存调研材料，不具备规范效力。设计冲突时以编号文档和 ADR 为准。

## 3. 当前状态与目标状态

### 3.1 当前状态

截至 2026-09-14，仓库事实如下：

- 根仓以 `Makefile` 为薄入口，实际逻辑位于 `scripts/*.sh`。
- GitHub Actions 的 `verify.yaml` 只在 Ubuntu 上执行 pin、ShellCheck、构建、插件挂载和 HTTP 就绪冒烟；它是未来开源预留，不是内部发布事实源。
- 当前没有 `Jenkinsfile`，也没有 Gerrit 项目配置或 Nexus 发布实现。
- `scripts/release.sh` 在本地校验 pin 后创建并推送 tag；GitHub tag workflow 生成 Release。
- `scripts/deploy-remote.sh` 通过 rsync 同步源码，在目标 Linux 主机重新安装和构建，再由 systemd 启动。
- harness 已提供 `dsh-headless`、Mock LLM、keyless E2E 和真实模型 E2E 资产，但根仓发布门禁尚未编排这些用户旅程。

### 3.2 目标状态

目标链路为：

```text
Gerrit patchset
  -> Jenkins 双平台 presubmit
  -> Verified 投票
  -> merge commit 干净构建
  -> Nexus candidate
  -> staging 自动部署与混合回归
  -> Release Manager 人工批准
  -> 同 digest 晋级 Nexus release
  -> production 原子部署
  -> 部署证明或自动回滚
```

在所有 P0-P5 验收项完成前，本文中的目标命令、Job 和目录均是实施契约，不得表述为已经可用。阶段定义见 [01-architecture.md](01-architecture.md#12-迁移与验收阶段)。

## 4. 已批准决策

1. 采用“分层编排式”架构：仓库脚本承载业务逻辑，Jenkins Pipeline 只负责编排和门禁。
2. Gerrit 托管主仓及自维护 fork；当前自维护 fork 至少包括 `dsh-automation`。
3. 第三方仓继续从 GitHub 按精确 gitlink SHA 获取。
4. Jenkins 长期提供 Linux x86-64 与 macOS arm64 两类 Agent。
5. 使用 Nexus Repository 保存 snapshot、candidate、release 与测试证据。
6. staging 自动部署，production 需要 Release Manager 人工批准。
7. 回归使用确定性 Mock LLM 和少量真实 DeepSeek 请求的混合模式。
8. 第一期继续使用 systemd/SSH，不引入 Kubernetes。
9. Gerrit 和 Jenkins Controller 使用两台独立内网物理服务器，二者不在同一宿主机或同一虚拟化故障域。
10. Git/Gerrit + Jenkins 是唯一内部 CI/CD 主链；GitHub Actions 不持有内网凭据，也不产生发布授权结论。
11. dsh-tui 及其独立 profile 延后到单独 feature 设计，本期不设相关 required lane。

ADR 索引：

- [ADR-0001：Gerrit 托管边界](adr/0001-gerrit-repository-boundary.md)
- [ADR-0002：不可变制品晋级](adr/0002-immutable-artifact-promotion.md)
- [ADR-0003：混合端到端回归](adr/0003-hybrid-end-to-end-regression.md)
- [ADR-0004：内网控制平面与数据驻留](adr/0004-intranet-control-plane-and-data-residency.md)

## 5. 规范用语

- **必须**：上线或晋级的强制条件。
- **不得**：明确禁止的行为。
- **应该**：默认执行；偏离时必须在评审中说明原因和补偿措施。
- **可以**：不影响设计一致性的可选实现。

## 6. 角色

| 角色 | 主要责任 |
|---|---|
| Developer | 提交 patchset、维护测试、处理失败 |
| Reviewer | 完成人工设计/代码评审，不替代 CI |
| Plugin Maintainer | 定义插件用户旅程与兼容性边界 |
| CI Administrator | 维护 Jenkins、Agent、Shared Library 与凭据域 |
| Release Manager | 审阅 staging 证据、批准生产发布 |
| SRE | 部署、回滚、备份、恢复和事件响应 |
| Security Administrator | Gerrit/Nexus/Jenkins 权限、签名密钥和审计策略 |

同一个人可以承担多个角色，但 CI 服务账号、Release Manager 和普通开发者权限不得因此合并。

## 7. 设计参考

- [Gerrit Submit Requirements](https://gerrit-review.googlesource.com/Documentation/config-submit-requirements.html)
- [Jenkins Gerrit Trigger](https://plugins.jenkins.io/gerrit-trigger)
- [Jenkins Pipeline Shared Libraries](https://www.jenkins.io/doc/book/pipeline/shared-libraries/)
- [Jenkins Credentials](https://www.jenkins.io/doc/book/security/credentials/)
- [Sonatype Nexus Repository Staging](https://help.sonatype.com/en/staging.html)
- [Playwright CI](https://playwright.dev/docs/ci)
- [Playwright Trace Viewer](https://playwright.dev/docs/trace-viewer)

外部资料只说明产品能力；本目录定义 DSH 的实际采用方式。

## 8. 变更流程

对本目录的规范性变更必须：

1. 说明影响的阶段、Job、脚本、凭据和回滚路径；
2. 同步更新受影响的 ADR 或新增 ADR；
3. 更新 `tests/release-regression/catalog.yaml` 中对应门禁（该文件落地后）；
4. 经平台工程师和至少一名代码所有者评审；
5. 在 staging 验证后再改变 production 流程。

只修改 Jenkins UI 而不更新版本化配置和文档，视为配置漂移。
