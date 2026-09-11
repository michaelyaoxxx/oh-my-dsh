# dsh-agent-teams 源码集成（pin tag v0.1.17-rc.1）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)（包名 `@nanmicoder/dsh-agent-teams`）以 git submodule 源码形式接入 `plugins/dsh-agent-teams`，pin 上游正式 tag `v0.1.17-rc.1`，经 link 挂载进 profile `dsh`。

**插件做什么**：多智能体团队协作（captain + members + 带依赖的任务 + 消息传递），用自然语言驱动；宿主侧把 `agent_teams_*` 工具注册进 `tools`、并往全局 system prompt 注入一段用法说明，Web 侧提供树状监视器。

## 0. 已拍板的决策

1. **tag pin**：pin `v0.1.17-rc.1`（**注释标签**，tag 对象 `3e53d07` → commit `2e59da1`）。注意上游**没有** `v0.1.17` 这个 tag，最新即 `v0.1.17-rc.1`。
2. **从上游直接安装，不 fork**（用户明确）：本仓的特殊需求一律**改脚本**而不是改插件仓——与 dsh-market 的处理方式一致。
3. **包管理器走 pnpm 10**（本轮唯一需要用户拍板的点，已确认）：见 §1.2。
4. **必须构建**：`main` 指向 `lib/index.js`，而 `lib/` **未被 git 跟踪**（`.gitignore` 有 `lib/`）→ 不命中「入口已提交即跳过构建」，走 `run build`。

## 1. 已钉死的关键事实（侦察结论）

1. **形态**：单包仓（无 `packages/`）；`dsh.bundle.patch: ./cordis.patch.yml` 在自身目录 → link-plugins 根候选直接挂载；entry `id: agent-teams` / `name: '@nanmicoder/dsh-agent-teams'`，带 config 种子（`stateDir: .agent-teams`、`memberProvider: spawn`）。
2. **`pnpm.overrides` 写在 package.json（pnpm ≤10 的位置），且未声明 `packageManager`** —— 这是本轮的核心问题：
   - **pnpm 11 不再读 package.json 的 `pnpm.overrides`**（该设置迁到了 `pnpm-workspace.yaml`；harness 自己就写在 workspace 文件里）。
   - 于是 pnpm 11 看这个仓的 overrides 是**空**，与 lockfile 里记录的 234 条不符 → frozen 安装被拒：`ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`。
   - **实测**：pnpm 11.7.0 / 11.8.0 / 11.24.0 **全部失败**（是整个 11.x 的行为），只有 pnpm **10.32.1 / 10.33.0 成功**。
   - 上游 CI 正是靠 `npm install --global pnpm@10.33.0` 绕开的（因为仓里没有 `packageManager`，只能在 CI 里硬装）。
3. **`pnpm run` 也会被拖下水**：pnpm 11 跑脚本前的依赖校验（`runDepsStatusCheck`）会重新触发安装，撞同一个 mismatch → **build 也失败**。所以路由必须同时覆盖 install 与 build，落在 `plugin_pnpm` 这**单一入口**上（实测确认）。
4. **插件自带运行时兼容层**（`src/harness-compat.ts`）：按**契约探测 + 回退**适配多个 harness 版本，不按版本号判断——`compatibility.json` 只被它自己的脚本读，运行时不读。它需要的现代契约我们的 harness 都有：
   - `session.ownEvents()` ✓（`core/session/src/index.ts:649`）；无则回退 `events` + `seedLength`
   - `runtime[Symbol.for('dsh.subagent.deliverPrompt')]` ✓（`subagent/src/index.ts:267` 的 `private [deliverSubagentPrompt](…)`，Symbol 键运行时可达）与 `runtime.sendMessage` ✓
   - `setup(agent.ctx, agent)`（现代两参形态）✓ —— 正是我们给 dsh-automation 打过补丁的那处，**这个插件自己就处理了**
   - `registerContinuableSetup` 在 harness 中不存在 → 走 `agent/session-start` 监听的回退路径，逻辑自洽
   - **注意**：`compatibility.json` 的 `supportedHosts` **不含 0.1.5-rc.2**（最高是 `0.1.5-rc.1` recommended），但运行时不做版本比对，实测 boot 无 `unsupported Harness subagent contract`。
5. **`.npmrc`（仓内）**：`auto-install-peers=true`、`strict-peer-dependencies=false`。
6. **lockfile 规模**：`pnpm-lock.yaml` 8388 行，含 **726 个 `@deepseek-ai/*` 条目**（devDeps 把整个 DSH 包集拉下来做类型/构建依赖）。安装约 16s（本机，缓存已热），体积可观但一次到位。
7. **依赖面全绿**：`cordis ^4.0.2`（harness 是 **4.0.2** ✓）；客户端注入的 7 个包（locale / ui-conversation / ui-layout / ui-model-selection / api-session-controller / ui-session / ui-chat）均在 harness。

## 2. 本轮新增的通用修复：package.json overrides 的仓走 pnpm 10

### 2.1 实现（`scripts/setup.sh` 与 `deploy/remote-install.sh` 同形）

```bash
LEGACY_PNPM="${DSH_LEGACY_PNPM:-10.33.0}"
has_package_json_overrides() { # 0 = overrides 写在 package.json 的 pnpm 字段（pnpm ≤10 的位置）
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.exit(p.pnpm&&p.pnpm.overrides?0:1)' "$1/package.json" 2>/dev/null
}
plugin_pnpm() {
  local d="$1"; shift
  if has_package_manager "$d"; then
    ( cd "$d" && pnpm "$@" )
  elif has_package_json_overrides "$d"; then
    echo "==> ${d%/} overrides 写在 package.json（pnpm ≤10 的位置），经 pnpm@${LEGACY_PNPM} 执行: pnpm $*"
    ( cd "$d" && corepack "pnpm@${LEGACY_PNPM}" "$@" )
  else
    echo "==> ${d%/} 无 packageManager，经 harness pin 的 pnpm 执行: pnpm $*"
    ( cd harness && pnpm --dir "../$d" "$@" )
  fi
}
```

要点：
- 分支顺序决定了**只有未声明 `packageManager` 的仓**才可能走到 legacy 分支——声明了的仓仍按仓内 corepack 解析（各自 pin 优先）。
- `corepack pnpm@<version>` 是 corepack 的官方用法，**不需要仓内声明** `packageManager`，也不需要全局装。
- 版本可用 `DSH_LEGACY_PNPM` 覆盖。
- 位置选在 `plugin_pnpm`（而非 install 分支）是**必须**的：install 与 build 都经此入口，只改 install 会让 build 再次撞上 §1.3 的依赖校验。

### 2.2 回归验证（关键）

谓词对既有 6 个插件**全部为 false**（它们的 `pnpm.overrides` 都在 `pnpm-workspace.yaml` 或不存在），路由不变。跑完整插件循环确认：

| 插件 | 安装/构建决策 | 是否变化 |
| --- | --- | --- |
| dsh-agent-teams | **经 pnpm@10.33.0** | 新增 |
| dsh-automation | 跳过构建（入口已提交） | 不变 |
| dsh-better-sidebar | 仓内 pnpm（自带 packageManager） | 不变 |
| dsh-market | **npm ci**（package-lock.json） | 不变 |
| dsh-plugin-mineru | 跳过构建 | 不变 |
| dsh-web | 仓内 pnpm | 不变 |
| modlens | harness pin 的 pnpm | 不变 |

**8 个 submodule 全部 0 dirty。**

## 3. 接入步骤

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/NanmiCoder/dsh-agent-teams.git plugins/dsh-agent-teams
git -C plugins/dsh-agent-teams checkout --detach v0.1.17-rc.1   # 归一化
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> plugins/dsh-agent-teams 未声明可构建依赖（无 onlyBuiltDependencies/allowBuilds），以 --ignore-scripts 安装`
- `==> plugins/dsh-agent-teams overrides 写在 package.json（pnpm ≤10 的位置），经 pnpm@10.33.0 执行: pnpm install --frozen-lockfile --ignore-scripts`
- `==> 构建插件: plugins/dsh-agent-teams/` → 同样经 pnpm@10.33.0 → `lib/index.js`（27 KB）+ `lib/client.js`（198 KB）
- `git submodule foreach` **八个仓**均 `0 dirty`

## 4. 挂载 + dump + boot 验证

| 项 | 结果 |
| --- | --- |
| 挂载 | ✓ `==> link @nanmicoder/dsh-agent-teams <- …`；**8 个 bundle** |
| dump | ✓ exit 0、`id: agent-teams` 带 2 项 config 种子、无 warn |
| boot（宿主） | ✓ 隔离实例（`--port 0`）`dsh web: http://127.0.0.1:56315/?token=…`，日志 **0 错误**、**无** `unsupported Harness subagent contract` |
| 客户端半侧 | ✓ 引导图含 `dsh-agent-teams/client.js`；`/plugins/??@nanmicoder/dsh-agent-teams/client.js&rev=…` → **HTTP 200、197799 字节** |

boot 用**隔离实例**（复制 `DSH_HOME` 到 /tmp + `--port 0`，并把副本里相对路径的符号链接改写为绝对路径），避免干扰用户正在运行的 3080 实例——做法同 dsh-market 手册 §4。

**待用户 UI 验收**：会话里用自然语言驱动 AgentTeams 是否可用；Web 树状监视器是否渲染。

## 5. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | 追加 `"plugins/dsh-agent-teams v0.1.17-rc.1"`（并更新注释清单） |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/dsh-agent-teams` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/dsh-agent-teams v0.1.17-rc.1` |
| `AGENTS.md` / `README.md` / spec | 稳定分支行、plugins 行、子仓清单/目录树/校验行同步 |

## 6. Commit 切分

```sh
git add scripts/setup.sh deploy/remote-install.sh
git commit -m "feat(scripts): package.json overrides 的插件仓经 pnpm 10 执行（setup/remote-install）"

git add .gitmodules plugins/dsh-agent-teams
git commit -m "feat: 引入 dsh-agent-teams 源码 submodule（plugins/dsh-agent-teams，pin tag v0.1.17-rc.1）"

git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 dsh-agent-teams（pin tag v0.1.17-rc.1）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 dsh-agent-teams（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（pnpm 11 不读 package.json overrides）"

git add docs/superpowers/plans/2026-09-11-dsh-agent-teams-integration.md
git commit -m "docs(plans): 记录 dsh-agent-teams 集成手册"
```

## 7. 与之前插件的机制差异

| 维度 | 之前 | dsh-agent-teams | 影响 |
| --- | --- | --- | --- |
| **pnpm 版本需求** | 无 packageManager 的仓一律用 harness pin（11.7.0） | **必须 pnpm 10**（overrides 写在 package.json，pnpm 11 不读该位置） | 首次触达：`plugin_pnpm` 新增 legacy 分支，install 与 build 都改走 pnpm@10.33.0 |
| **harness 版本适配** | dsh-automation 需要我们**本地打补丁**（setup 第二参数、snapshotEvents） | 插件**自带运行时兼容层**（契约探测 + 回退），无需补丁 | 首个「自己处理跨版本适配」的插件；其 `compatibility.json` 声明支持到 0.1.5-rc.1，但运行时不校验版本号，0.1.5-rc.2 实测通过 |
| **依赖规模** | 数十个包 | lockfile 含 **726 个 `@deepseek-ai/*`**（devDeps 拉整个 DSH 包集做类型依赖） | 安装明显更重，但一次到位、仍可复现 |
| **UI 落点** | 侧边栏 / 设置页 / 插槽 | `tools` 注册 + 全局 system prompt 注入 + Web 树状监视器 | 会改变所有会话的 prompt（插件设计如此） |
