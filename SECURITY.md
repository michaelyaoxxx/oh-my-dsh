# 安全策略

## 报告漏洞

**请不要开公开 issue。** 通过以下任一私密渠道报告：

- GitHub Security Advisory（仓库 → Security → Report a vulnerability）
- 邮件：**【待填：安全联系邮箱】**

请在报告中包含：受影响组件与版本（或 commit SHA）、复现步骤、影响评估、以及你已知的缓解方式。

**响应时限（目标值，非承诺）**：3 个工作日内确认收到；10 个工作日内给出初步评估。

## 范围

本仓是 **superproject**，通过 git submodule 编排上游仓库。这一点决定了漏洞该报给谁：

| 位置 | 归属 | 报告去向 |
| --- | --- | --- |
| `harness/` | DSH 内核（上游 submodule） | **上游 `deepseek-ai/deepseek-harness`**，本仓只 pin |
| `plugins/*` | 各插件上游（见 [config/components.json](config/components.json) 的 `sourceAuthority`） | **各自上游**；本仓 fork 的（`dsh-automation`）报本仓 |
| `scripts/`、`deploy/`、`.github/`、`config/` | **本仓** | 报本仓 |

> 本仓**不修改上游 submodule 的内容**，因此上游代码的漏洞无法在本仓修复——只能通过升级 pin 吸收上游修复。

## 本仓自身的高风险面（已识别）

| # | 面 | 现状 |
| --- | --- | --- |
| 1 | `scripts/deploy-remote.sh` 对目标执行 `rsync --delete` | 已有危险路径硬拒绝 + 服务器侧符号链接防护（2026-09-15）；**仍以 root 运行、应用与状态同目录**，生产启用前需完成安全评审 |
| 2 | 远程访问插件（`plugins/dsh-web` 内的 `dsh-remote-web-ui`）可把实例暴露到公网 | 见 [docs/remote-access.md](docs/remote-access.md)：控制端点仅限 loopback（已实测），但隧道开通即被公网扫描器枚举（已实测） |
| 3 | 未受信任输入的流水线 | 见 [docs/cicd/06-security-and-operations.md](docs/cicd/06-security-and-operations.md)；**presubmit 不得持有可复用凭据**（该文档已列为 P0） |

## 不在范围内

- 需要物理接触本机或已获得本机 root 的攻击
- 依赖上游 submodule 自身已公开的已知漏洞（请报上游）
- 社会工程
