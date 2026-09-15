# 贡献指南

本仓是 **DSH superproject**：以 git submodule 编排 `harness/`（DSH 内核）与 `plugins/*`（插件），
自身只承载环境搭建、部署、发布快照与插件 pin。

## 先读这两份

| 文档 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | **硬约束与工作流**（平台、pin 规则、插件位置、提交约定） |
| [docs/plugin-dev.md](docs/plugin-dev.md) | 插件开发与**常见问题**（踩坑按症状归档，改脚本前务必读） |

CI/CD 设计的权威入口是 [docs/cicd/README.md](docs/cicd/README.md)。

> ⚠️ **集成类任务必须从超级仓根目录启动**：`harness/` 下有多层嵌套 `AGENTS.md`
> （上游内容），从子目录启动会让指令链被截断或叠加。

## 改哪里的代码

| 你想改的东西 | 改哪里 | 怎么进本仓 |
| --- | --- | --- |
| DSH 内核 | **上游** `deepseek-ai/deepseek-harness` | 本仓只升级 pin，不直接改 |
| 某个插件 | **该插件上游** | 同上；本仓 fork 的（`dsh-automation`）改 fork |
| 本仓脚本/部署/CI/文档 | **本仓** | 直接改，走下面的流程 |

**本仓不修改 submodule 的内容**——`plugins/*` 是上游第三方仓的 pin（`harness/` 同理）。
确有本仓特有的适配需要时，走 fork + 分支 pin（先例：`dsh-automation`），
并在 [config/components.json](config/components.json) 里把 `sourceAuthority` 标为 `gerrit-fork`。

## 提交前自检

```sh
make check     # 一次跑完：组件目录 / 许可证 / 第三方声明 / pin / shellcheck
```

**清单不在这份文档里**，它的单一事实源是 [`scripts/check-all.sh`](scripts/check-all.sh)
（`bash scripts/check-all.sh --list` 可列出将跑哪些）。CI 的 step 0 调同一条命令的
`--offline` 模式——**本地与 CI 跑的是同一份清单**，这是刻意的：此前两者各写一份手工
副本，已经漂过一次（`check-licenses.mjs` 上了 CI 却漏在本地清单里）。

`make setup` 不是自检的前置——`--offline` 那组在 `make setup` 之前也能跑。

> 历史教训：这条自检曾写作 `bash scripts/check-components.mjs`，
> **用 bash 跑 .mjs 会以退出码 2 失败**（bash 把 JS 当 shell 解释）。凡 `.mjs` 一律 `node`。

改了 submodule 的 pin 时，**必须同步更新 [config/components.json](config/components.json)**——
否则 CI 会在第一步就失败（双向校验会指出哪个组件对不上）。

## 改动区域 → 需要跑什么

| 改动区域 | 必须做 |
| --- | --- |
| `scripts/*.sh`、`deploy/*` | 上面的自检全跑；shellcheck 必须全绿（CI 用 `-S style`，固定 0.9.0） |
| `config/components.json` | 改了组件集合 / `license` 时**先** `node scripts/gen-notices.mjs` 重新生成声明——它是**合规文档**，不改就会让 `make check` 的 `--check` 失败（有意的） |
| `scripts/check-components.mjs` / `check-licenses.mjs`（**门禁逻辑本身**） | ⚠️ 改了判定逻辑**必须**跑 `bash scripts/probe-license-gate.sh` 确认覆盖边界没退化（它是这两道门的**回归基线**；`make check` 已用 `--strict` 纳入）。⚠️ 它防不住**蓄意**攻击者：能改门禁的人也能改它，真正的解法是门禁脚本从受信 ref 取 |
| `patches/*.yml` | `make link-plugins` 后 `dsh --profile dsh --dump-config`，确认**没有** patch 抹掉旁键（整表替换语义，见 plugin-dev.md） |
| `.github/workflows/*`（**默认不改**） | CI/CD 载体是 Gerrit + Jenkins，`.github/workflows/` 只是开源预留通路。只有两类例外可改：供应链安全修复、把新校验挂到门禁上（**逻辑写在 `scripts/`**）。例外改动时另需：YAML 能解析；Action **pin 到 commit SHA** 并注明版本 |
| `docs/cicd/*` | 它是 CI/CD 的规范源；改动需说明影响的阶段/Job/脚本/凭据/回滚路径 |

## 提交约定

- **commit message 不加任何 AI 署名**（包括 `Co-Authored-By`）。
- 提交按**逻辑单元切分**（pin / scripts / ci / docs 分开），不要把无关改动塞进同一个 commit。
- 主仓默认分支 `main`。
- **submodule 的 detached HEAD 是特性**：更新 pin 是显式动作，不要随手把 submodule 拉到远端最新。

## 评审

内部开发使用 **Gerrit**（`git push origin HEAD:refs/for/main`）；GitHub PR 作为开源后的通路保留。
评审中会特别关注：

- 是否引入了未受信任输入可触达的凭据或受信执行路径；
- 是否修改了 submodule 内容（除非走 fork 流程并登记）；
- 是否让 pin/组件集合失去一致性（漏登记组件 = 该组件在 CI 里静默消失）。
