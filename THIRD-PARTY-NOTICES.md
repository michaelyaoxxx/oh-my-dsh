# 第三方组件声明

本文件由 `node scripts/gen-notices.mjs` **自动生成**，请勿手工编辑——
改动会在 CI 的 `--check` 步骤被拒绝。要改内容请改 [config/components.json](config/components.json)。

## 本仓自身的许可

本仓库（superproject：`Makefile`、`scripts/`、`deploy/`、`patches/`、`config/`、`docs/`、`.github/`）
以 **Apache License 2.0** 授权，全文见 [LICENSE](LICENSE)。

## 本仓与下方组件的许可边界

本仓通过 **git submodule** 编排下列组件：每个组件在**自己的仓库里**携带自己的许可证，
本仓只固定其 commit（pin）。**LICENSE 的 Apache-2.0 不覆盖下列任何组件**，反之亦然。

> 曾出现的误解：因为本仓有 `LICENSE`，就以为整个 superproject（含 submodule 内容）都按它授权。
> 不是。gitlink 是指针，各子仓的授权只由其自身决定。

## 组件清单

> ⚠️ **「来源」「进制品」是 catalog 的声明值，未经校验。**
> 其中「进制品」对应的 `releaseScope` 目前**没有行为消费者**（制品链尚未实现）——
> 它记录意图，不构成保证。字段分类见 [config/README.md](config/README.md)。

| 组件 | 许可证 | 来源（声明，未验证） | 进制品（声明，未验证） | 默认运行时 |
| --- | --- | --- | --- | --- |
| `harness` | MIT | [`github`](https://github.com/deepseek-ai/deepseek-harness.git) | bundle, sbom, provenance | 包含 |
| `dsh-web` | Apache-2.0 | [`github`](https://github.com/zhu1090093659/dsh-web.git) | bundle, sbom | 包含 |
| `dsh-better-sidebar` | MIT | [`github`](https://github.com/omdsh-dev/DSH-better-sidebar.git) | bundle, sbom | 包含 |
| `modlens` | MIT | [`github`](https://github.com/liustack/modlens.git) | bundle, sbom | 包含 |
| `dsh-automation` | MIT | [`gerrit-fork`](https://github.com/michaelyaoxxx/dsh-automation.git) | bundle, sbom | 包含 |
| `dsh-market` | MIT | [`github`](https://github.com/dsh-market/dsh-market.git) | bundle, sbom | 包含 |
| `dsh-agent-teams` | MIT | [`github`](https://github.com/NanmiCoder/dsh-agent-teams.git) | bundle, sbom | 包含 |
| `dsh-at-file` | MIT | [`github`](https://github.com/FSMargoo/dsh-at-file.git) | bundle, sbom | 包含 |
| `modsearch` | MIT | [`github`](https://github.com/liustack/modsearch.git) | bundle, sbom | 包含 |
| `loongsuite-observability` | Apache-2.0 | [`github`](https://github.com/loongsuite/dsh-plugin.git) | bundle, sbom | 包含 |
| `dsh-tui` | MIT | [`github`](https://github.com/ccch1mneyyy/dsh-TUI.git) | — | **排除** |

## 按许可证聚合

### Apache-2.0 — Apache License 2.0

2 个组件：`dsh-web`、`loongsuite-observability`

### MIT — MIT License

9 个组件：`harness`、`dsh-better-sidebar`、`modlens`、`dsh-automation`、`dsh-market`、`dsh-agent-teams`、`dsh-at-file`、`modsearch`、`dsh-tui`

## Copyleft 边界（AGPL / GPL）

当前组件集合中**没有** AGPL/GPL 组件，制品不承载 copyleft 义务。

## 重新生成

```sh
node scripts/gen-notices.mjs          # 覆盖本文件
node scripts/gen-notices.mjs --check  # 校验是否最新（CI 用）
```
