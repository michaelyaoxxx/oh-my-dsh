# AGENTS.md — dsh 超级仓库

本仓库是 DeepSeek Harness（DSH）超级仓库（superproject），以 git submodule 方式管理 harness 与插件仓库，承载环境搭建、部署、发布快照与插件开发。整体设计见 `docs/superpowers/specs/` 下最新的 spec 文档。

## 硬约束

- **目标平台**：本地 macOS M4（arm64）；远程服务器 Linux（Ubuntu）x86-64。原生 Node 依赖必须按平台各自构建，严禁跨平台拷贝 `node_modules`。
- **插件安装位置**：插件默认装在 `plugins/` 目录下（submodule 引入）；目标目录不存在时脚本必须 `mkdir -p` 自动创建。
- **稳定分支**：harness → 正式 tag `dsh-v0.1.5-rc.2`（tag pin；注意上游 tag 带 `dsh-` 前缀）；dsh-web → `main`（注意 dsh-web 默认分支是 `dev`，不要 pin `dev`）；dsh-better-sidebar → 正式 tag `v0.18.1`（tag pin；verify.yaml 与 release.sh 以 tag 比对校验）；dsh-plugin-mineru → `master`；modlens → 正式 tag `v3.26.1`（tag pin）。
- **原生构建**：harness 的 `pnpm build` 会先跑 `build:native-system`，为本机平台编译 `native/system` 的 Node-API 插件。需要 C 编译器与 Node 开发头文件；**严禁跨平台拷贝该产物**（`native/system/packages/*/bin/` 已 gitignore，各平台各自构建）。

## 工作流

- 统一入口是 `Makefile`（薄入口），实际逻辑在 `scripts/*.sh`。
- 本地：`make setup` / `make dev`；部署：`make deploy`（显式动作，不上 CI）；发布：`make release`。
- 插件开发在 submodule 内切分支进行，push 回插件仓后回主仓更新 pin 并走 PR；`verify.yaml` 会校验 pin 一致性。
- submodule 的 detached HEAD 是特性；更新 pin 是显式动作，不要随意把 submodule 拉到远端最新。
- 插件仓的发版（npm publish / tag）由插件仓自行完成，本仓库不越界编排。

## Git 约定

- 主仓默认分支 `main`。
- commit message **不加任何 AI 署名**（包括 `Co-Authored-By: Claude Code`）。
