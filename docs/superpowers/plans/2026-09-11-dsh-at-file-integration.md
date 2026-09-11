# dsh-at-file 源码集成（pin tag v0.7.0）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [FSMargoo/dsh-at-file](https://github.com/FSMargoo/dsh-at-file)（包名 `dsh-at-file`）以 git submodule 源码形式接入 `plugins/dsh-at-file`，pin 上游正式 tag `v0.7.0`，经 link 挂载进 profile `dsh`。

**插件做什么**：给 DSH Web GUI 加 Codex 风格的 `@路径` 引用——输入 `@` 时搜索工作区路径并插入引用，**不注入文件内容**（只是引用）。

## 0. 已拍板的决策

1. **tag pin**：pin `v0.7.0`（**注释标签**，tag 对象 `e2a6626` → commit `da602d1`；该 commit 也正是 `main` HEAD）。
2. **不写任何 patch**：宿主入口没有 `export const inject`；客户端 `dsh.client.inject` 列了 3 个包（`ui-input-trigger` / `ui-slots` / `dsh-client-locale`），均在 harness。无 entry id 冲突。
3. **跳过构建**：`main` 指向 `lib/index.js`，而 `lib/` **被 git 跟踪**（`lib/index.js`、`lib/client.js`、`lib/invariant.js` 及 sourcemap 均已入库）→ 命中「入口已提交即跳过构建」判据，随 pin 自带产物。
4. **不需要任何脚本改动**：本仓同时有 `pnpm-lock.yaml` 与 `pnpm-workspace.yaml`（`allowBuilds` 写在后者 = pnpm 11 认的位置）、无 `packageManager`、package.json 无 `pnpm.overrides` → 走**harness pin 的 pnpm** 正常安装，零新机制。

## 1. 已钉死的关键事实（侦察结论）

1. **形态**：单包仓（无 `packages/`）；`dsh.bundle.patch: ./cordis.patch.yml` 在自身目录 → link-plugins 根候选直接挂载；entry `id: dsh-at-file` / `name: dsh-at-file`（**无 config**、无 disabled guard）。另有 `dsh.plugin.json`（与 better-sidebar 同款，harness 运行时不读）。
2. **构建与产物**：`build: node build.mjs`（esbuild）。`lib/` 已提交 → 跳过构建；`lib/index.js` 约 599 KB、`lib/client.js` 约 614 KB。
3. **`pnpm-workspace.yaml`（仓内）**：`packages: ['.']`、`autoInstallPeers: false`、**`nodeLinker: hoisted`**（用 npm 式扁平 node_modules，非 pnpm 默认的符号链接布局）、`allowBuilds: { esbuild: true }`。
   - `allowBuilds` 写在 workspace 文件里 → `has_build_policy` 判为 true → 走「正常安装」分支（不加 `--ignore-scripts`）。实测安装成功。
4. **devDependencies 全部是 `link:../deepseek-harness/...`** —— 指向上游作者**本地同级目录**的 harness 源码（`../deepseek-harness/vendor/cordis`、`packages/core/agent` …）。
   - **pnpm 不校验 link 目标是否存在**：在我们的布局下（harness 在 `harness/`，不是 `../deepseek-harness`）安装**照样 exit 0**，只是那 15 个 devDep 变成**悬空软链**。
   - **无实际影响**：`lib/` 已提交且构建被跳过 → 从不使用这些 devDep；安装后 `git status` 干净。
5. **运行时导入只有两个 harness 包**：`lib/index.js` 里有值导入 `import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'` 与 `import { createUserMessage } from '@deepseek-ai/dsh-llm'`。两者**都在 profile 的模块回退链里**（`.dsh/profiles/node_modules/@deepseek-ai/`），**boot 实测无 `ERR_MODULE_NOT_FOUND`**——即插件内的 harness 包导入是经 DSH 的回退链解析的，不依赖插件自己的 node_modules。
   - 注意 `dependencies` 里的 `zod` **并未被 `lib/index.js` 引用**（已打包进去或不使用），所以悬空的 zod 也无影响。
6. **依赖面**：peer `@deepseek-ai/cordis: ^4.0.1-rc.1`（harness 是 4.0.2 ✓）；其余 peer 均为 `*` 或 optional；客户端注入的 3 个包均在 harness（`client/ui-input-trigger`、`client/ui-slots`、`client/locale`）。
7. **`main` 字段没有 `./` 前缀**（`"lib/index.js"`）：跳过构建的判据用 `${main_entry#./}` 归一化，实测命中 ✓。

## 2. 接入步骤

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/FSMargoo/dsh-at-file.git plugins/dsh-at-file
git -C plugins/dsh-at-file checkout --detach v0.7.0   # 归一化
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> 安装插件依赖: plugins/dsh-at-file/`（安装输出在成功时被捕获丢弃，属既有行为）
- `==> 跳过构建: plugins/dsh-at-file 入口 lib/index.js 已提交在仓库内`
- `git submodule foreach` **九个仓**均 `0 dirty`

> 安装成功但**无任何输出**是正常的：`plugin_install` 在成功路径上丢弃捕获的输出（只有失败或走回退分支才打印）。

## 3. 挂载 + dump + boot 验证

| 项 | 结果 |
| --- | --- |
| 挂载 | ✓ `==> link dsh-at-file <- …`；**9 个 bundle** |
| dump | ✓ exit 0、`id: dsh-at-file` / `name: dsh-at-file`、无 warn |
| boot（宿主） | ✓ 隔离实例（`--port 0`）`dsh web: http://127.0.0.1:57755/?token=…`，日志 **0 错误**、**无 `ERR_MODULE_NOT_FOUND`**（证明两个 harness 值导入经回退链解析成功） |
| 客户端半侧 | ✓ 引导图含 `dsh-at-file/client.js`；`/plugins/??dsh-at-file/client.js&rev=…` → **HTTP 200、614068 字节** |

boot 用**隔离实例**（复制 `DSH_HOME` 到 /tmp + `--port 0` + 改写副本内相对符号链接为绝对路径），不干扰用户正在运行的 3080 实例——做法同 dsh-market 手册 §4。

**待用户 UI 验收**：在输入框敲 `@` 是否弹出工作区路径搜索、选中后是否正确插入引用（且**不注入文件内容**）。

## 4. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | 追加 `"plugins/dsh-at-file v0.7.0"`（并更新注释清单） |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/dsh-at-file` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/dsh-at-file v0.7.0` |
| `AGENTS.md` / `README.md` / spec | 稳定分支行、plugins 行、子仓清单/目录树/校验行同步 |

## 5. Commit 切分

```sh
git add .gitmodules plugins/dsh-at-file
git commit -m "feat: 引入 dsh-at-file 源码 submodule（plugins/dsh-at-file，pin tag v0.7.0）"

git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 dsh-at-file（pin tag v0.7.0）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 dsh-at-file（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（devDeps 指向作者本地布局的 link:）"

git add docs/superpowers/plans/2026-09-11-dsh-at-file-integration.md
git commit -m "docs(plans): 记录 dsh-at-file 集成手册"
```

## 6. 与之前插件的机制差异

| 维度 | 之前 | dsh-at-file | 影响 |
| --- | --- | --- | --- |
| **devDependencies 形态** | 从 registry 解析 | **全部 `link:../deepseek-harness/...`**（指向作者本地布局） | 首次触达：pnpm 不校验 link 目标 → 悬空软链但**安装照样成功**；因 `lib/` 已提交、跳过构建，这些 devDep 永不被使用，无实际影响 |
| **node_modules 布局** | pnpm 默认（符号链接 + 虚拟store） | 仓内 `pnpm-workspace.yaml` 声明 **`nodeLinker: hoisted`** | 无影响（我们只借用它的 node_modules，不依赖布局） |
| **运行时 harness 导入** | 各插件都自带 node_modules 提供 | 两个值导入（`dsh-typert-protocol`、`dsh-llm`）**靠 DSH 的 profile 模块回退链解析** | 实证：boot 无 `ERR_MODULE_NOT_FOUND`；也解释了为何插件 node_modules 里的悬空链接不影响运行 |
| **脚本改动** | 每个新插件多多少少要动脚本 | **零改动** | 本轮纯粹是既有机制的正确命中 |
