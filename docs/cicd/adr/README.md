# DSH CI/CD 架构决策记录

本目录记录已经批准、会长期约束 CI/CD 实施的架构决策。ADR 只描述“为什么选择”，具体配置、命令和验收条件仍以父目录编号文档为准。

| ADR | 状态 | 决策 |
|---|---|---|
| [ADR-0001](0001-gerrit-repository-boundary.md) | Accepted | Gerrit 托管主仓与自维护 fork，第三方仓保持外部上游 |
| [ADR-0002](0002-immutable-artifact-promotion.md) | Accepted | staging 与 production 晋级同一不可变制品 digest |
| [ADR-0003](0003-hybrid-end-to-end-regression.md) | Accepted | 确定性 Mock 回归与小规模真实 DeepSeek 验证并用 |
| [ADR-0004](0004-intranet-control-plane-and-data-residency.md) | Accepted | 内网双物理控制平面、敏感数据本地驻留、GitHub Actions 非发布权威 |
| [ADR-0005](0005-component-catalog-lifecycle.md) | Accepted | 组件目录字段三分类、`prepareMode` 四值、校验分 catalog/materialized 两阶段 |

## 维护规则

- ADR 一经 Accepted 不直接改写结论；决策变化时新增 ADR 并将旧 ADR 标记为 Superseded。
- 仅修正错字、失效链接或补充不改变结论的澄清。
- 每个 ADR 必须写清上下文、决策、后果、替代方案和实施约束。
- 实现与 ADR 冲突时，先完成架构评审，不得以临时 Jenkins 配置绕过。
