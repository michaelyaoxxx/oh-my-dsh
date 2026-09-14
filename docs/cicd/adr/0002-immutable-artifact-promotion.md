# ADR-0002：不可变制品晋级

| 属性 | 值 |
|---|---|
| 状态 | Accepted |
| 日期 | 2026-09-14 |
| 决策者 | DSH Maintainer |
| 关联文档 | [制品与发布](../03-artifact-and-release.md)、[部署手册](../05-deployment-runbook.md) |

## 上下文

当前远程部署会把源码同步到目标机后重新安装与构建。这会让 staging 验证的内容与 production 实际运行内容受到网络、依赖解析、编译器和目标机状态影响，也无法可靠回答“哪一个二进制/原生模块通过了测试”。

DSH 同时包含 Node 依赖和平台原生模块。Linux production 只能使用 Linux x86-64 节点构建的产物，macOS arm64 的验证结果不能替代 Linux 运行制品。

## 决策

1. merge commit 在干净 Linux x86-64 Agent 上只构建一次可部署 runtime bundle。
2. bundle、manifest、SBOM、provenance 和测试证据进入 Nexus，并以 SHA-256 digest 标识。
3. staging 自动部署 candidate；通过所有发布门禁并经 Release Manager 批准后，以同一 digest 晋级 release。
4. production 只下载并校验该 release digest，不重新运行包管理器、编译器或源码构建。
5. 部署目录使用 digest 标识，并通过原子切换 `current`/`previous` 完成发布与回滚。
6. 生产部署验证成功后才创建/推送发布 tag；tag 必须反向指向 manifest 中的 merge commit。

## 后果

正向后果：

- staging 测到的字节与 production 运行的字节一致。
- 发布可按 commit、gitlink、digest、测试证据和部署记录双向追溯。
- production 不再依赖公网、包注册表或本机编译工具链，故障面和权限面更小。
- 回滚无需重新构建，只需切换到已验证的 previous digest。

代价与风险：

- 需要定义可重定位 bundle，并验证绝对路径、native ABI 与 Node runtime。
- Nexus OSS 不具备原生 staging 工作流时，需要由脚本执行带校验的 copy/promote；该脚本必须保持幂等。
- candidate、release 和 evidence 的保留策略会增加存储占用。

## 被否决的替代方案

- **每个环境重新构建**：无法保证字节级一致，也扩大目标机权限。
- **只用 Git tag 作为发布物**：tag 标识源码，不能证明依赖、原生模块和运行时字节。
- **production 从 candidate 仓直接运行**：削弱了人工晋级边界与保留策略。

## 实施约束

- artifact identity 至少包含 bundle SHA-256、merge commit、全部 submodule SHA、Node/pnpm 版本和目标平台。
- Jenkins 必须在上传后重新下载并校验 digest，部署端必须再次校验。
- Nexus release 仓不可覆盖；相同版本不同 digest 必须拒绝。
- production 节点上的持久化状态与 runtime release 目录必须分离。
