# dsh · DeepSeek Harness 超级仓库

以 git submodule 编排 DSH 主仓库与插件仓库，承载环境搭建、部署、发布快照与插件开发。设计见 [docs/superpowers/specs/](docs/superpowers/specs/)。

## 快速上手（本地 macOS M4）

```sh
make setup     # 拉 submodule + harness 构建 + 插件依赖（含 Node/corepack 工具链校验，幂等）
make dev       # 启动 DSH Web（$DSH_HOME=./.dsh，插件 link 挂载，改插件源码热更）
```

`make dev` 先把 `plugins/*` 中可挂载的插件包 link 挂进 profile `dsh`，再启动服务，默认监听 `http://127.0.0.1:3080`（仅本机回环）。`make dev` 依赖 harness 已构建，首次使用请先 `make setup`。

- 插件开发：[docs/plugin-dev.md](docs/plugin-dev.md)
- 远程部署：[docs/deploy.md](docs/deploy.md)
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
| `harness/` | DSH 主仓库 submodule（pin tag `dsh-v0.1.5-rc.2`） |
| `plugins/` | 插件 submodule 集合（dsh-web pin `main`、dsh-better-sidebar pin tag `v0.18.1`、dsh-plugin-mineru pin `master`、modlens pin tag `v3.26.1`、dsh-automation pin 分支 `adapt/harness-0.1.5-rc.2`），插件默认安装位置 |
| `.dsh/` | DSH 运行主目录（`$DSH_HOME`，运行时生成，gitignore） |
| `scripts/` | 编排脚本（Makefile 是薄入口） |
| `deploy/` | systemd unit + 服务器安装脚本 + hosts 模板 |
| `docs/` | 部署手册、插件开发指南；`superpowers/specs/` 存设计文档 |
| `.github/workflows/` | verify（pin 校验 + 冒烟）/ release（tag → GitHub Release） |
