# ADR-0004：内网控制平面与数据驻留

| 属性 | 值 |
|---|---|
| 状态 | Accepted |
| 日期 | 2026-09-14 |
| 决策者 | DSH Maintainer |
| 关联文档 | [架构设计](../01-architecture.md)、[安全与运维](../06-security-and-operations.md) |

## 上下文

DSH 部署在可以访问互联网的企业内网。源码、评审、构建日志、制品、凭据和终端用户数据具有内部或机密属性，需要留在本地基础设施。现有 Gerrit 与 Jenkins 规划为两台不同物理服务器；GitHub Actions 只为后续开源预留，不应成为内部发布链的一部分。

若把互联网连通等同于允许数据外传，CI artifact、cache、日志或第三方插件可能形成隐蔽的数据出口。若 Gerrit 与 Jenkins 共置，一个物理故障或主机失陷会同时破坏源码权威和自动门禁。若 GitHub Actions 与内网 Jenkins 共同决定发布，又会形成难以审计的双控制平面。

## 决策

1. Gerrit 与 Jenkins Controller 分别运行在两台独立内网物理服务器，不共享宿主机或虚拟化故障域。
2. Git/Gerrit + Jenkins 是内部 CI/CD 唯一控制链；Gerrit 维护源码/评审权威，Jenkins 维护自动验证与发布编排权威。
3. GitHub Actions 仅执行显式批准公开的源码与测试兼容检查，不投 Gerrit `Verified`，不读取内网服务，不写 Nexus，不触发 staging/production，也不持有内网凭据。
4. 源码、review metadata、构建日志、制品、evidence、凭据、用户数据、备份和审计记录默认只保存在内网受控系统。
5. 内网允许受控出站访问 GitHub、依赖源和 DeepSeek 等业务服务；访问必须经过按源、目标、端口和用途划分的 allowlist，并遵循数据最小化。
6. 新增外部 SaaS、云制品仓、云日志或跨网同步属于架构边界变更，必须另行安全评审和 ADR。

## 后果

正向后果：

- 源码权威与 CI 控制器具有独立物理故障域和更清晰的权限边界。
- 内部发布结论只有一个来源，不受外部 CI 可用性或权限变化影响。
- 互联网连接可以支持上游同步和真实模型验证，同时保持敏感数据本地驻留。
- 数据出口、凭据和审计责任可以通过网络 allowlist 与本地日志统一治理。

代价与风险：

- 需要维护内网 DNS/TLS、出口代理、防火墙规则、备份和双机监控。
- 外部 API 测试必须维护合成 fixture、脱敏和预算控制。
- 未来开源同步需要显式发布流程，不能直接把内网仓库或历史日志镜像到 GitHub。
- 两台物理服务器仍可能共享机房、电源或网络故障域，需要在灾备计划中记录剩余风险。

## 被否决的替代方案

- **Gerrit 与 Jenkins 共置**：减少机器数量，但扩大单点故障和横向移动影响。
- **GitHub Actions 与 Jenkins 双主链**：门禁、凭据和发布状态可能分叉。
- **完全断网构建**：不符合第三方上游、依赖与真实 DeepSeek 验证的实际需求。
- **默认允许任意出网**：无法证明敏感数据本地留存。

## 实施约束

- Jenkins Controller 使用 `0 executors`，未受信任代码仅在隔离 Agent 运行。
- Gerrit/Jenkins/Nexus 管理端口只在内网开放，不建立来自 GitHub 托管 Runner 的入站隧道。
- 代理、DNS、防火墙、GitHub mirror 与数据驻留策略必须版本化并进入审计。
- 发布验收必须验证 GitHub workflow secret、artifact/cache、外部日志和 SaaS 中不存在内网敏感数据。
