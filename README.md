# dsh · DeepSeek Harness 超级仓库

以 git submodule 编排 DSH 主仓库与插件仓库，承载环境搭建、部署、发布快照与插件开发。设计见 [docs/superpowers/specs/](docs/superpowers/specs/)。

## 快速上手（本地 macOS M4）

```sh
make setup     # 拉 submodule + harness 构建 + 插件依赖（含 Node/corepack 工具链校验，幂等）
make dev       # 启动 DSH Web（$DSH_HOME=./.dsh，插件 link 挂载，改插件源码热更）
```

`make dev` 先把 `plugins/*` 中可挂载的插件包 link 挂进 profile `dsh`，再启动服务，默认监听 `http://127.0.0.1:3080`（仅本机回环）。`make dev` 依赖 harness 已构建，首次使用请先 `make setup`。

- 插件开发：[docs/plugin-dev.md](docs/plugin-dev.md)
- 远程部署：[docs/deploy.md](docs/deploy.md)（操作手册）・ ⚠️ 接手部署先读 [docs/deploy-handoff.md](docs/deploy-handoff.md)（**该路径从未跑通**）
- 远程访问（在外用手机/另一台电脑）：[docs/remote-access.md](docs/remote-access.md)（含第三方方案尽调 [docs/dsh-remote.md](docs/dsh-remote.md)）
- 遗留问题：[docs/backlog.md](docs/backlog.md)（**还欠什么**，完成即删）
- 整改台账：[docs/remediation-plan.md](docs/remediation-plan.md)（**做过什么**，T×R 映射与证据）
- **CI/CD 权威入口**：[docs/cicd/README.md](docs/cicd/README.md)（Gerrit + Jenkins + Nexus；当前目标是内网主链，GitHub Actions 仅作开源预留）
- 组件清单：[config/components.json](config/components.json)（谁参与 CI、谁进制品的事实源）
- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md) ・ 安全策略：[SECURITY.md](SECURITY.md)
- 发布快照：`make release VERSION=v0.1.0`（校验 pin → 打 tag 并推送，CI 冒烟通过后生成 GitHub Release）
- 全部目标：`make help`

## 平台与约定

- 本地 macOS M4（arm64）、服务器 Linux x86-64；原生 Node 依赖按平台各自构建，严禁跨平台拷贝 `node_modules`。
- Node 版本要求 `^22.19 || >=24`（23 不满足）；pnpm 无需全局安装，由 corepack 按各仓库 `packageManager` 字段解析 pin 版本。
- 插件仓发版（npm publish / tag）由插件仓自行完成，本仓只做 pin 快照。
- 主仓默认分支 `main`；harness pin 正式 tag `dsh-v0.1.5-rc.2`（tag pin，上游 tag 带 `dsh-` 前缀），dsh-web 稳定分支 `main`（其默认分支是 `dev`，不要 pin `dev`）。

## 结构

| 目录 | 说明 |
| --- | --- |
| `harness/` | DSH 主仓库 submodule。**pin 不在此复制**——见 [config/components.json](config/components.json) |
| `plugins/` | 插件 submodule 集合，插件默认安装位置。**各插件的 pin / 许可证 / 是否进制品与运行时，一律以 [config/components.json](config/components.json) 为准**（`node scripts/check-components.mjs` 会与 `.gitmodules` 做双向校验） |
| `.dsh/` | DSH 运行主目录（`$DSH_HOME`，运行时生成，gitignore） |
| `scripts/` | 编排脚本（Makefile 是薄入口） |
| `deploy/` | systemd unit + 服务器安装脚本 + hosts 模板 |
| `docs/` | 部署手册、插件开发指南、远程访问；`superpowers/specs/` 存设计文档 |
| `.github/workflows/` | verify（pin 校验 + 冒烟）/ release（tag → GitHub Release） |

## 许可

本仓（superproject 自身的 `Makefile`、`scripts/`、`deploy/`、`patches/`、`config/`、`docs/`、`.github/`）
以 **Apache License 2.0** 授权，全文见 [LICENSE](LICENSE)。

`harness/` 与 `plugins/*` 是 **submodule**——它们各自携带自己的许可证，**不**由本仓的 LICENSE 覆盖。
各组件许可证、来源与是否进制品见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)（自动生成，勿手改）。

> ⚠️ 含 **AGPL-3.0** 组件的制品，整个制品须按 AGPL-3.0 分发（AGPL 与 Apache-2.0 只单向兼容）。
> 当前 AGPL 组件的制品状态见上方声明文件。
