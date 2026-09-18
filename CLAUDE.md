# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

> 上面引入的 [AGENTS.md](AGENTS.md) 是**仓库级硬约束与工作流**（平台、pin 规则、操作授权边界、
> 提交与验证报告约定），**本文件不重复它**。这里只补两样 AGENTS.md 刻意不写的东西：
> **常用命令**与**跨文件才看得懂的架构**。
> 会漂移的事实（pin 版本、组件清单、分支名）一律不复制——事实源是
> [config/components.json](config/components.json)。

## 常用命令

统一入口是 `Makefile`（薄入口），实际逻辑全在 `scripts/*.sh`；`make help` 列出全部目标。

| 命令 | 作用 |
| --- | --- |
| `make setup` | 初始化 submodule + 依赖 + harness/插件构建（幂等）。**首次、换机器、pin 变更后必跑** |
| `make dev` | 先 `link-plugins` 再启动 DSH Web；`$DSH_HOME=./.dsh`，监听 `127.0.0.1:3080` |
| `make check` | 本地自检（= `bash scripts/check-all.sh`）。**改完任何东西先跑它** |
| `make link-plugins` | 只做挂载与 patch 合并，不起服务 |
| `make save-settings` / `make seed-configs` | 插件参数：live → 基线入版本库 / 基线 → 运行时 |
| `make deploy` / `make release VERSION=…` | ⚠️ 均需用户显式授权，见 AGENTS.md「操作授权边界」 |
| `make dev-tui` | 备选 TUI：本项目不做功能开发与测试，坏掉时没有信号 |

自检还可以更细地跑（清单的单一事实源是 [scripts/check-all.sh](scripts/check-all.sh)）：

```sh
bash scripts/check-all.sh --list                            # 只列将执行哪些检查，不跑
bash scripts/check-all.sh --offline                         # 只跑离线组（CI step 0 用的就是它）
bash scripts/check-all.sh --offline --require-materialized  # CI / release 的严格形态
```

⚠️ **模式旗标只认第一个参数**（`--list --require-materialized` 才会既列清单又严格；
反过来写成 `--require-materialized --list` 会按全量跑）。

其余按需调用的查询入口：

```sh
node scripts/check-pins.sh --list                  # 枚举 <path>\t<kind>\t<ref>（发布快照消费它）
node scripts/check-pins.sh --drift                 # branch pin 落后远端多少提交（落后本身不失败）
node scripts/check-components.mjs --plan prepare   # 每行 <path>\t<prepareMode>，即 setup 的执行计划
```

**本仓没有根级测试入口。** 它是 superproject，自己不含被测代码：`make check` 就是这道门；
`.github/workflows/verify.yaml` 也只做 pin / shellcheck / 构建 / 挂载 / HTTP 冒烟，**不跑单元测试**。
各组件的测试命令登记在 `config/components.json` 的 `testProfile` 字段（供未来的 Jenkins 车道），
要跑某个组件的测试，进它的 submodule 按该仓自己的脚本来。

两个实测过的坑：**`.mjs` 一律用 `node` 跑**（`bash x.mjs` 会以退出码 2 失败）；
`harness/` 与 `plugins/*` 未初始化时是**空目录**（`git submodule status` 行首为 `-`），先 `make setup`。

## 架构：一个关注点一个事实源

本仓**不实现 DSH，也不改 submodule**——只做编排、门禁与发布快照。
它的全部设计围绕一条原则：**每个关注点只有一个事实源，其余全部从它派生或只链接它**。
下面几条派生链就是本仓的大图；看懂它们，剩下的文件都是这条原则的实例。

### 1. 组件 → [config/components.json](config/components.json)

谁存在、pin 在哪、许可证、是否进 CI / 制品 / 运行时，只写在这一处。

- `scripts/check-components.mjs` 与 `.gitmodules` 做**双向集合校验**——漏登记一个组件 =
  它在 CI 里静默消失，所以必须双向。
- `--plan prepare` 输出的是**决策数据**（每行 `<path>\t<prepareMode>`）；
  **动作**由唯一执行器 [scripts/prepare-executor.sh](scripts/prepare-executor.sh) 实现——
  它是个被 `source` 的库，被 `setup.sh` 与 `deploy/remote-install.sh` 共用，
  调用方注入 `pe_install` / `pe_run_build` 两个钩子（环境差异只允许出现在这两个钩子里）。
  **构建与否只看 `prepareMode`**，不看「入口文件有没有被 git 跟踪」。
- `scripts/check-pins.sh` 只读 `path` / `pinPolicy` / `pinRef`，且**先过校验器再读目录**：
  catalog 非法时它拒绝工作（fail-closed）——否则「单独跑它」会假绿。
- `scripts/gen-notices.mjs` → `THIRD-PARTY-NOTICES.md`（**合规文档**，改组件集合或 license 后必须先重生成）。
- `verify.yaml` / `release.yaml` / `release.sh` 的快照清单都从它派生，不再手工抄 submodule 列表。

### 2. 自检清单 → [scripts/check-all.sh](scripts/check-all.sh)

「本地该跑什么」只写在这里；`make check` 与 CI 的 step 0 调**同一条命令**。

- **离线组**（不联网、不依赖构建，故能也应当最先失败）：组件目录 → 许可证内容 →
  声明文件是否过期 → 两道**门禁自身的回归**。
- **全量额外**：pin 校验（要联网 fetch）+ shellcheck（要工具链）。
- `--require-materialized` 与「离线 / 全量」是**正交**维度：它把「子仓未初始化 ⇒ 跳过」
  变成**失败**。CI 与 release 必须带，否则 fresh clone 上可以一项都不查就通过（fail-open）。

> 改了 `check-components.mjs` / `check-licenses.mjs` 的**判定逻辑**，就必须跑
> [scripts/probe-license-gate.sh](scripts/probe-license-gate.sh) 与
> [scripts/probe-catalog.sh](scripts/probe-catalog.sh)——它们是这两道门的**回归基线**，
> 防的是「门被改弱了却没人发现」。

### 3. 插件挂载与 patch 分层

```text
插件自带的 cordis.patch.yml          # bundle 层（写在 submodule 里，本仓不改）
      ↓ 之后应用
.dsh/profiles/<profile>/cordis.patch.yml   # 用户 patch 层，分两区：
      ├─ managed 区：由 scripts/merge-profile-patch.mjs 从 patches/*.yml（文件名序）幂等重写
      └─ 标记之外的用户手写区：原样保留
```

插件源码经 `dsh plugin --profile dsh add link:<绝对路径>` 以符号链接挂进
`.dsh/profiles/dsh/`，改源码即时生效。**根包不一定是挂载入口**（`dsh-web` 的聚合子包才是）。

⚠️ **`config` 与 `inject` 都是整表替换**：patch 只列自己关心的键，同行的其余旁键就被抹掉。
本仓多数 `patches/*.yml` 存在的原因正是这个——每个文件头部注释写明了它防的是什么、
以及 base 变化时它需要同步补什么。

### 4. 插件参数 → [config/plugin-configs/catalog.json](config/plugin-configs/catalog.json)

唯一入口是 `scripts/save-settings.mjs`（子命令 `seed` / `save` / `list`）：
`seed` 只在 live 缺失时铺、**绝不覆盖**；`save`（= `make save-settings`）把 live 导出回基线。
`link-plugins.sh` 与 `deploy/remote-install.sh` 共用同一次 `seed` 调用。

### 5. 运行时与发布

- `$DSH_HOME=.dsh` 是**一次性、gitignore 的运行时目录**：里面的东西都不是权威，权威在 `config/`。
  清空 / 换机器 / 部署后由基线 `seed` 恢复。
- 部署走 `scripts/deploy-remote.sh`（当前为**非生产 legacy**，从未端到端跑通）；
  发布走 `scripts/release.sh`（pin 校验 → tag → push）。两者都是**显式动作**。

## 排查问题先看哪

[docs/plugin-dev.md](docs/plugin-dev.md) 的「常见问题」按**症状**归档了本仓踩过的坑
（挂载失败、`without inject`、patch 抹掉旁键、pnpm 版本与 lockfile 分歧、submodule 变脏……），
**改脚本前必读**。未收口事项看 [docs/backlog.md](docs/backlog.md)（还欠什么），
已做过什么与证据看 [docs/remediation-plan.md](docs/remediation-plan.md)。
