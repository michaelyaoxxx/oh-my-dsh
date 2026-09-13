# dsh-TUI 源码集成（pin tag v0.10.1）—— 执行手册

上游：[ccch1mneyyy/dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI)（`@deepseek-harness-tui/dsh-tui`，MIT）
pin：正式 tag `v0.10.1`（commit `78081ce`）。**轻量 tag**（`git cat-file -t v0.10.1` 返回 `commit`，非 `tag`）——本仓 CI 统一用 `rev-parse <tag>^{}`，对轻量 tag 只是无副作用的恒等操作，两种都安全。
日期：2026-09-13

## 0. 已拍板的决策

| 决策点 | 结论 | 理由 |
| --- | --- | --- |
| 挂到哪个 profile | **独立 profile `tui`** | 它是**终端前端**，与 `dsh-web-app` 同级（见 §2），塞进 `dsh` 会抢同一批 base 行 |
| 构建失败怎么办 | 照常构建，失败就记问题 | 用户决策；实际只遇到一个 macOS 路径长度问题，已修（§3.2） |

## 1. 已钉死的关键事实（侦察结论）

| 项 | 值 |
| --- | --- |
| 包名 / 版本 / 许可 | `@deepseek-harness-tui/dsh-tui` / `0.10.1` / **MIT** |
| 仓形态 | 单包（根即包），但带 **3 个嵌套 submodule** |
| `packageManager` | `pnpm@11.21.0` ✓ 已声明（无需走 harness pin 回落） |
| lockfile | `pnpm-lock.yaml` ✓ |
| 根 `main` | `lib/types/index.js` —— **未被 git 跟踪 → 需要构建** |
| `dsh.bundle.patch` | `./cordis.patch.yml` ✓ 声明在自身目录内 → 本会被 link 自动挂载 |
| `dsh.client` | **无** → 纯 host 侧（TUI 没有浏览器半区） |
| 构建 | `npm run compile`（vendor/dsh-std 7 包 → dsh-auth → clean → tsc）**再** `npm run verify:build`（**70 个** verify 脚本） |
| 构建策略声明 | `pnpm-workspace.yaml` 有 `allowBuilds:` → `setup.sh` 的 `has_build_policy` 为真 → 走**真安装**（非 `--ignore-scripts`） |

**嵌套 submodule（4 个检出）**：

| 路径 | 上游 |
| --- | --- |
| `dsh-auth` | ccch1mneyyy/dsh-auth |
| `dsh-ecosystem-spec` | T-Auto/dsh-ecosystem-spec |
| `vendor/dsh-std` | Yan-Zero/dsh-std |
| `dsh-ecosystem-spec/vendor/dsh-std` | 同上（嵌在 spec 里的一份） |

## 2. 与之前插件的机制差异（本次最重要的一点）

**它不是叶子插件，是前端。** 它的 `cordis.patch.yml`（453 行）覆盖了 **30 个 base 行**：

```
system-prompt  llm-deepseek  agent-loop  session-telemetry-otel
plugin-package-inventory-deepseek  agent-instructions  command-compact
compaction-basic  plan-mode  skill-filesystem  tool-bash  tool-fs
tool-fs-search  command-goal  tool-goal  tool-jobs  tool-pwsh  tool-ralph
tool-result-pruner  tool-skill  tool-subagent  tool-subagent-control
tool-subagent-fork  tool-subagent-list-agents  tool-todo  tool-web
tool-workflow  workflow-worker-thread  sandbox-policy  approval
session-persistence-jsonl
```

这与 `@deepseek-ai/dsh-web-app` 是**同级关系**（两个前端都改同一批 base 行）。作者的 README 也写明用法是：

```sh
dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui
# 之后 dsh-tui 与 dsh --profile dsh-tui 等价
```

**因此本仓必须做两件事**（缺一就会把 web 环境弄坏）：

1. `scripts/link-plugins.sh` **与 `deploy/remote-install.sh`** 的候选口径都是「`plugins/*/` 里声明了 `dsh.bundle.patch` 的包」——**它同样声明了**，两处都加了 `SKIP_MOUNT=(plugins/dsh-tui)`；否则本地 `make dev` 与服务器部署都会把终端前端挂进 profile `dsh`。
2. 单独建 profile `tui`（`scripts/link-tui.sh` + `make dev-tui`）。`dsh plugin add` 会自动把 `@deepseek-ai/dsh-base` 铺成宿主层，无需手工补。

本仓 `patches/*.yml`（better-sidebar / connection inject / web fetch provider）都是 **web 栈专用，不并入** profile `tui`。

## 3. 接入步骤

### 3.1 加 submodule 并 pin

```sh
git submodule add https://github.com/ccch1mneyyy/dsh-TUI.git plugins/dsh-tui
git -C plugins/dsh-tui checkout --detach v0.10.1           # 78081ce
git -C plugins/dsh-tui submodule update --init --recursive # 4 个嵌套检出
git add plugins/dsh-tui                                    # ← 关键，见下
```

> 🔴 **顺序陷阱（本次实际踩到）**：`git submodule add` 记录的是**克隆当时的默认分支 HEAD**
> （此处 `f5cb232`，比 v0.10.1 还晚 3 个提交）；随后手工 `checkout --detach <tag>` **只改工作树，
> 不改已记录的 gitlink**。而 `make setup` 会执行 `git submodule update --init --recursive`，把工作树
> **顶回记录的 gitlink** —— 于是手工 checkout 被静默冲掉，最终 pin 成了 `main` HEAD 而非 tag，
> **且构建产物也来自那个错误提交**。
>
> **正确顺序**：`checkout --detach <tag>` → **`git add plugins/dsh-tui` 并提交** → 再跑 `make setup`
> （此时 update 顶回的就是刚提交的 tag gitlink，工作树不再被改）。

### 3.2 构建：macOS unix socket 路径长度（本次唯一的真问题）

首次 `make setup` 在 `verify:inject-channel` 失败：

```
channel error: inject channel: socket error: Error: listen EINVAL: invalid argument
/var/folders/h_/sqt93qdj0lz29bbj_8k3phch0000gn/T/dsh-inject-Ijom00/.dsh-tui/inject/test-session-1234.sock
at scripts/verify-inject-channel.mjs:82:18
make: *** [setup] Error 1
```

**根因**：该路径 **105 字节**，而 **macOS 的 `sun_path` 上限是 104** → `listen(2)` 返回 `EINVAL`。插件脚本用 `os.tmpdir()`，在 macOS 上就是 `/var/folders/<长哈希>/T`。作者 CI 跑 Linux（`/tmp`，短）故未暴露。

**这不是本仓的问题，是插件脚本在 macOS 上的可移植性缺陷**（值得报上游）。

**处置**：`scripts/setup.sh` 的插件循环前统一 `export TMPDIR=/tmp`（62 字节，余量充足）。实测同一条链 **70 个 verify 脚本全过、exit 0**。

> ⚠️ **`compile` 与 `verify:build` 是两段**：失败发生在 `verify:build`，此时 `lib/` **已经构建完成**（1629 个文件、根入口 `lib/types/index.js` 在位）。所以「构建失败」≠「产物没出来」——排查时先看产物，再看 verify。

### 3.3 挂载（独立 profile）

```sh
bash scripts/link-tui.sh     # 或 make dev-tui
```

`dsh plugin --profile tui add link:.../plugins/dsh-tui` 生成：

```json
{ "dependencies": { "@deepseek-harness-tui/dsh-tui": "link:.../plugins/dsh-tui" },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-harness-tui/dsh-tui"] } } }
```

## 4. 验证结果

| 项 | 结果 |
| --- | --- |
| `make setup` | ✅ exit 0（修 TMPDIR 后）；70 个 verify 脚本全过 |
| submodule 干净度 | ✅ `git -C plugins/dsh-tui status --porcelain` 为空（`lib/` 被 gitignore） |
| `make link-plugins` | ✅ 输出 `跳过挂载: plugins/dsh-tui`，且 profile `dsh` 仍是 **10 个 bundle**（web 环境未受影响） |
| `deploy/remote-install.sh` | ✅ 同源改动已加；**但 `make deploy` 本身从未实跑过**（见 [backlog.md](../../backlog.md) B3） |
| `dsh --profile tui --dump-config` | ✅ exit 0、542 行、无 warn；树里有 `dsh-base`(32) 与 `dsh-tui`(42)，**`webserver` 为 0 处**（正确——终端 profile 不带 web 宿主） |

> ⚠️ **`make dev-tui` 不能用 `tee`**：TUI 插件有 TTY 校验，管道会让 stdout 不是 TTY 而启动失败。故该目标不落盘日志（与其他目标不同）。

## 5. CI/文档修正（六处）

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` | tag loop 加 `"plugins/dsh-tui v0.10.1"` |
| `scripts/release.sh` | 加 `check_pin_tag plugins/dsh-tui v0.10.1` |
| `.github/workflows/release.yaml` | 快照清单加 `plugins/dsh-tui` |
| `AGENTS.md` | 稳定分支行加 `dsh-tui → 正式 tag v0.10.1`（注明是终端前端、独立 profile） |
| `README.md` | plugins 行加 `dsh-tui pin tag v0.10.1` |
| `docs/superpowers/specs/2026-09-08-…-design.md` | 子仓清单 / 目录树 / 校验行三处 |

## 6. Commit 切分

1. **pin**：submodule + `.gitmodules` + gitlink
2. **scripts**：`setup.sh`（TMPDIR）、`link-plugins.sh` + `deploy/remote-install.sh`（SKIP_MOUNT）、`link-tui.sh`（新增）、`Makefile`（dev-tui）
3. **ci**：verify.yaml / release.yaml / release.sh
4. **docs**：AGENTS / README / spec / 本手册

## 7. 遗留

- **上游可报**：`scripts/verify-inject-channel.mjs` 未处理 macOS 长 `os.tmpdir()`；建议改用短路径或 `mkdtemp` 后检查长度。
- **本仓临时绕行**：`setup.sh` 的 `TMPDIR=/tmp` 是**全局插件构建**生效（非只针对本插件）——若将来某插件的构建依赖 macOS 默认 tmpdir 语义，需回看此处。
- **UI 验收未做**：`make dev-tui` 需真 TTY，本仓未实际启动过 TUI 界面。
