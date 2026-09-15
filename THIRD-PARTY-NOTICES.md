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

| 组件 | 许可证 | 来源 | 进制品 | 默认运行时 |
| --- | --- | --- | --- | --- |
| `harness` | MIT | [`github`](https://github.com/deepseek-ai/deepseek-harness.git) | bundle, sbom, provenance | 包含 |
| `dsh-web` | Apache-2.0 | [`github`](https://github.com/zhu1090093659/dsh-web.git) | bundle, sbom | 包含 |
| `dsh-better-sidebar` | MIT | [`github`](https://github.com/omdsh-dev/DSH-better-sidebar.git) | bundle, sbom | 包含 |
| `dsh-plugin-mineru` | AGPL-3.0 | [`github`](https://github.com/HuanLinOTO/dsh-plugin-mineru.git) | — | **排除** |
| `modlens` | MIT | [`github`](https://github.com/liustack/modlens.git) | bundle, sbom | 包含 |
| `dsh-automation` | MIT | [`gerrit-fork`](https://github.com/michaelyaoxxx/dsh-automation.git) | bundle, sbom | 包含 |
| `dsh-market` | MIT | [`github`](https://github.com/dsh-market/dsh-market.git) | bundle, sbom | 包含 |
| `dsh-agent-teams` | MIT | [`github`](https://github.com/NanmiCoder/dsh-agent-teams.git) | bundle, sbom | 包含 |
| `dsh-at-file` | MIT | [`github`](https://github.com/FSMargoo/dsh-at-file.git) | bundle, sbom | 包含 |
| `modsearch` | MIT | [`github`](https://github.com/liustack/modsearch.git) | bundle, sbom | 包含 |
| `dsh-tui` | MIT | [`github`](https://github.com/ccch1mneyyy/dsh-TUI.git) | — | **排除** |

## 按许可证聚合

### AGPL-3.0 — GNU Affero General Public License v3.0

1 个组件：`dsh-plugin-mineru`

### Apache-2.0 — Apache License 2.0

1 个组件：`dsh-web`

### MIT — MIT License

9 个组件：`harness`、`dsh-better-sidebar`、`modlens`、`dsh-automation`、`dsh-market`、`dsh-agent-teams`、`dsh-at-file`、`modsearch`、`dsh-tui`

## Copyleft 边界（AGPL / GPL）

以下组件为 copyleft 许可，按下列状态生效：

- `dsh-plugin-mineru`（AGPL-3.0）：不进制品；不在默认运行时

**当前没有任何 copyleft 组件进制品** —— 制品不承载 AGPL/GPL 义务。

> 这一状态是**刻意维持**的：AGPL-3.0 与 Apache-2.0 只**单向**兼容——Apache-2.0 代码可以并入
> AGPL 作品，**反之不行**（Apache-2.0 的专利与赔偿条款对 AGPL 构成附加限制）。
> 因此一旦任何 AGPL 组件进入 bundle 制品，**整个制品实际只能按 AGPL-3.0 分发**，
> 其中所有 Apache-2.0 组件也随之被覆盖。改动 `releaseScope` 前须先过 ADR 与法务确认。

## 重新生成

```sh
node scripts/gen-notices.mjs          # 覆盖本文件
node scripts/gen-notices.mjs --check  # 校验是否最新（CI 用）
```
