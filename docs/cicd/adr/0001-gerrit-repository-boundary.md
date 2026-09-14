# ADR-0001：Gerrit 托管边界

| 属性 | 值 |
|---|---|
| 状态 | Accepted |
| 日期 | 2026-09-14 |
| 决策者 | DSH Maintainer |
| 关联文档 | [架构设计](../01-architecture.md)、[Gerrit 与 Jenkins](../02-gerrit-and-jenkins.md) |

## 上下文

DSH 是以 git submodule 组织 harness 与插件的超级仓库。团队需要用 Gerrit 统一评审主仓变更，同时保留第三方项目的上游关系；`dsh-automation` 等自维护 fork 还需要承载只能由本团队维护的兼容适配。

若把所有第三方仓完整镜像并在 Gerrit 重新维护，会引入镜像同步、权限和来源真实性成本。若只把超级仓库放入 Gerrit，自维护 fork 的适配提交又会绕开统一评审和 Verified 门禁。

## 决策

1. `dsh` 超级仓库和所有自维护 fork 以 Gerrit 为权威评审入口。
2. 当前自维护 fork 至少包括 `dsh-automation`；其 Gerrit 仓库保留指向原项目的 `upstream`，同步上游必须以 Gerrit Change 进入。
3. 非自维护的第三方 submodule 继续从公开上游获取，不为 CI/CD 目的无差别镜像进 Gerrit。
4. 超级仓库只通过 gitlink 精确 SHA 消费 submodule；CI 不得把分支最新提交隐式替换为评审中的 SHA。
5. 第三方来源不可用、存在供应链风险或需要内部补丁时，必须通过新的架构决策明确是否转为受管 fork。

## 后果

正向后果：

- 主仓和内部维护代码共享 Gerrit RBAC、审计、Submit Requirements 与 Jenkins Verified 门禁。
- 外部依赖仍能保留可验证的上游提交身份，不增加全量镜像维护负担。
- fork 的上游同步与本地适配都具备可审计评审记录。

代价与风险：

- Jenkins 构建必须同时具备 Gerrit 和允许列表内外部 Git 源的只读访问。
- 外部上游故障会影响冷缓存构建，因此需要 Nexus/受控 Git 缓存与来源校验策略。
- 主仓 pin 更新与 fork 变更是两个独立 Change，合入顺序需要显式协调。

## 被否决的替代方案

- **全部仓库镜像进 Gerrit**：治理范围和同步成本大于当前收益。
- **只有超级仓库进 Gerrit**：自维护 fork 仍会绕过统一评审。
- **CI 直接跟随 submodule 分支头**：不可复现，也无法证明评审内容等于构建内容。

## 实施约束

- Gerrit 项目、权限和 Submit Requirements 必须版本化管理。
- `scripts/check-pins.sh` 继续作为稳定分支/tag 约束的事实源。
- Jenkins 记录超级仓库 commit、每个 gitlink SHA、来源 URL 和实际获取 SHA。
- `dsh-automation` 切换到 Gerrit 前，不得宣称本 ADR 已完成工程落地。
