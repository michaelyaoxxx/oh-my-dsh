# modlens 源码集成（pin tag v3.26.1）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [liustack/modlens](https://github.com/liustack/modlens)（`@liustack/modlens`）以 git submodule 源码形式接入 `plugins/modlens`，pin 上游正式 tag `v3.26.1`，经 link 挂载进 profile `dsh`——与 dsh-better-sidebar / dsh-plugin-mineru 同姿势。

## 0. 已拍板的决策

1. **源码接管**：`@liustack/modlens` 以 git submodule 加入 `plugins/modlens`，pin 正式 tag `v3.26.1`（tag pin，同 better-sidebar 惯例；上游默认分支 main，tag = 提交时 main HEAD `a1923d0`）。
2. **无需任何 profile patch**：插件 entry 自声明 `inject = ['tools','agents','attachments','llm']`；`webServer` 经 scoped `ctx.inject(['webServer'], scope => …)` 守卫（无 web 宿主时跳过、try/catch 兜底），是**正确的 cordis 用法**，与 mineru/connection 那次「getter 捕获 this.ctx」的坑无关。`patches/` 无新增文件。
3. **必须构建**（与 mineru 相反）：入口 `dsh/index.js` 虽然被 git 跟踪，但它 spawww 的引擎 `../dist/main.js` 是 `vite build` 产物（gitignored）。setup.sh 的「根 `main` 被跟踪即跳过」判据对 modlens **不命中**（它没有 `main` 字段，exports 指 `./dsh/index.js`），走 `elif scripts.build` 正常构建——恰好正确；`dist/` 被 .gitignore 覆盖，构建不弄脏 submodule。
4. **无 `packageManager` 字段**：与 mineru 同类，`setup.sh`/`remote-install.sh` 的 `plugin_pnpm` 自动经 harness pin（pnpm@11.7.0）执行。lockfile 存在（lockfileVersion 9.0，11.7.0 兼容）→ frozen 安装可行。
5. **依赖构建脚本被 pnpm 拦截（本轮新发现）**：modlens 未声明 `onlyBuiltDependencies`/`allowBuilds`，pnpm 11.7 默认拦截全部依赖构建脚本——安装以 `ERR_PNPM_IGNORED_BUILDS` 失败（**该消息打在 stdout**、退出码 1），并在仓内生成 approve-builds 脚手架（`pnpm-workspace.yaml` 模板）弄脏 submodule。更隐蔽的是：被拦截的安装会留下 **pendingBuilds 状态**，使后续 `pnpm build` 前的依赖校验自动重跑 `pnpm install`——经 PATH 上的 corepack shim 在无 packageManager 的仓内回落坏版本 12.3.4 必炸。修复（进 `setup.sh`/`remote-install.sh`）：`has_build_policy` 预判——未声明策略的仓**直接**以 `--ignore-scripts` 安装（无声明即无脚本需执行；esbuild 这类校验型 postinstall 不影响功能，平台二进制走 optionalDependencies），不做注定被拦截的普通安装；声明了策略的仓正常安装，仍被拦截则回退并清理脚手架。回退（先普通安装再重试）被证明无效：pendingBuilds 清不掉。
5. **UI 面无 tab、无 DSH 设置 section**：工具型插件（注册 `modlens_read_image` 工具给模型）；浏览器半侧经 `ctx.slots` 贡献一张配置卡 + paste-to-path（粘贴图片→写入临时文件路径进输入框）。配置本体在 `~/.modlens/config.json`（CLI `modlens config` 管理）。

## 1. 已钉死的关键事实（防再踩坑）

1. **上游形态**（tag `v3.26.1` = commit `a1923d0`，clone 实测）：单包仓，root `package.json` 声明 `dsh.bundle.patch: ./cordis.patch.yml`（patch 在自己包目录内 → link-plugins 根候选直接挂载，不需豁免——它不在任何候选的 dependencies 里，skip 逻辑不命中）。`cordis.patch.yml` 为顶层 `- insert: id: modlens, name: '@liustack/modlens'`，无 guard、无 inject 追加。
2. **运行时形态**：`exports["."] = "./dsh/index.js"`（手写 JS，零构建、零 @deepseek-ai 依赖）；`dsh/client.js` 走 lazy-CJS bundle 协议（`window.__ModuleLoader__.load`），同样零构建。两者均**随 pin 自带**。
3. **引擎产物**：`vite build`（`src/main.ts` → `dist/main.js`，ES 格式，external commander/undici + 全部 node 内建，`outDir: dist` 且 gitignore）。插件工具 spawww `dist/main.js`（包内路径，无 PATH/npx 依赖）——**不构建则工具报「engine 缺失」**。
4. **无 peerDependencies、无 @deepseek-ai/\* 依赖**：运行时 deps 仅 commander + undici；engines `node >=22.19` 满足本仓前置校验。与 harness pin 的版本兼容面为零冲突。
5. **视觉提供方**：antigravity-cli 为零配置默认；gemini-api/openai/anthropic 走 API key；kimi-cli 按名启用。工具端到端需可用提供方（真实 quota），无提供方时工具报连接错误——与 mineru「需真实服务」同类验收口径。
6. **幂等形态**：`make setup` 后 submodule 必须 0 dirty（`dist/`、`node_modules/` 均 gitignore）；link 是符号链接，改 `dsh/*.js` 即时生效，改 `src/*` 需重建（与 better-sidebar 的 src→lib 关系同构）。
7. **上游 CI 用 pnpm 10 的 action-setup 直装二进制**（不经 corepack），所以同样的无声明仓在上游 CI 不炸；我们的 corepack shim 按 cwd 解析才踩回落坑——同 §0.5 的 pendingBuilds 叠加成双重陷阱。

## 2. Step 1 —— submodule + pin tag + 安装构建

### 1.1 添加 submodule 并归一化 detached HEAD

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/liustack/modlens.git plugins/modlens
git -C plugins/modlens checkout --detach v3.26.1     # submodule add 落在默认分支，须归一化
git -C plugins/modlens describe --tags               # 预期 v3.26.1
```

### 1.2 安装依赖 + 构建（复用 setup.sh 插件循环）

```sh
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> plugins/modlens 未声明可构建依赖（无 onlyBuiltDependencies/allowBuilds），以 --ignore-scripts 安装`
- `==> plugins/modlens 无 packageManager，经 harness pin 的 pnpm 执行: pnpm install --frozen-lockfile --ignore-scripts` → `Done in Xs using pnpm v11.7.0`（**不是** 12.x）
- `==> 构建插件: plugins/modlens/` 后无 error；`plugins/modlens/dist/main.js` 存在（~200KB）
- 其他插件不受影响：better-sidebar / dsh-web 声明了 `allowBuilds`，走正常安装（无 ignore-scripts 行）
- `git submodule foreach` 五个仓均 `0 dirty`；`plugins/modlens/pnpm-workspace.yaml` 不存在（无脚手架残留）

### 1.2b 通用修复：`scripts/setup.sh` / `deploy/remote-install.sh`（C2）

`plugin_install` + `has_build_policy`：未声明构建放行策略的仓直接 `--ignore-scripts` 安装（原理见 §0.5）；声明了策略的仓正常安装，仍被拦截则回退 `--ignore-scripts` 并清理 pnpm 生成的脚手架。两个脚本同形。

### 1.3 Commit（C1/C2）

```sh
git add .gitmodules plugins/modlens
git commit -m "feat: 引入 modlens 源码 submodule（plugins/modlens，pin tag v3.26.1）"

git add scripts/setup.sh deploy/remote-install.sh
git commit -m "fix(scripts): 未声明构建策略的插件仓以 --ignore-scripts 安装（setup/remote-install）"
```

## 3. Step 2 —— 挂载 + dump 验证（本地，boot-free）

```sh
make link-plugins
cd harness && DSH_HOME=/Users/michaelyao/workspace/dsh/.dsh COREPACK_DEFAULT_TO_LATEST=0 CI=true \
  pnpm dsh --profile dsh --dump-config > /tmp/dump-modlens.txt 2>&1; echo "exit=$?"
```

预期：

- link 输出新增 `==> link @liustack/modlens <- …/plugins/modlens`，挂载数 4 → 5
- dump 出现 `# == @liustack/modlens` section：`- id: modlens`、`name: '@liustack/modlens'`
- `grep -i "warn\|not found" /tmp/dump-modlens.txt` 无输出（entry 的 inject 全部可解析）

## 4. Step 3 —— CI/校验/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | `"plugins/dsh-better-sidebar v0.18.1"` 后追加 `"plugins/modlens v3.26.1"` |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/modlens` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/modlens v3.26.1` |
| `AGENTS.md` 稳定分支行 | 追加 `；modlens → 正式 tag \`v3.26.1\`（tag pin）` |
| `README.md` plugins 行 | 追加 `modlens pin tag \`v3.26.1\`` |
| `docs/superpowers/specs/…-design.md` | ① 子仓清单加 modlens 行；② 目录树 plugins/ 加分支；③ release 校验行 tag 部分补 modlens |

### Commit 切分

```sh
git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 modlens（pin tag v3.26.1）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 modlens（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（依赖构建脚本被 pnpm 拦截）"

git add docs/superpowers/plans/2026-09-10-dsh-modlens-integration.md
git commit -m "docs(plans): 记录 modlens 集成手册"
```

## 5. Step 4 —— make dev 端到端验证（用户手动）

```sh
make dev     # 输出经 tee 落盘 log/dev-*.log
```

逐项核对：

0. **boot 成功**：`dsh web: http://127.0.0.1:3080/?token=…`，无 `cannot get property`。
1. 前置 link-plugins 输出 5 个挂载（含 modlens）。
2. UI：无新 tab、无 DSH 设置 section 属预期；粘贴图片应触发 paste-to-path（输入框出现临时文件路径文本，而非「模型不支持图片」拒绝）。
3. 工具端到端（`modlens_read_image` → 视觉解析）需要可用提供方（antigravity-cli 零配置默认 / API key）；无提供方时工具报连接错误属预期。

## 6. 风险与兜底

| 风险 | 症状 | 处置 |
| --- | --- | --- |
| 未构建即挂载 | 工具调用报 engine（`dist/main.js`）缺失 | 跑 `make setup`（构建必经）；dist/ gitignored 不会脏 |
| 插件仓内直接 pnpm | corepack 回落 12.x / MODULE_NOT_FOUND | 同 mineru：`cd harness && pnpm --dir ../plugins/modlens install`；setup/remote-install 已自动分支 |
| 上游 tag 前移 / 新 tag | verify/release 拦截（pin≠tag） | 显式更新 pin：`git -C plugins/modlens fetch origin --tags && git -C plugins/modlens checkout --detach <新tag>` → 主仓 `git add` + commit |
| 提供方 quota / CLI 缺失 | 工具返回连接或配置错误 | 属预期；`modlens doctor`（dist/main.js 直接 node 运行）离线诊断 |

## 7. Commit 汇总（全部无 AI 署名）

| # | Message 建议 |
| -- | --- |
| C1 | `feat: 引入 modlens 源码 submodule（plugins/modlens，pin tag v3.26.1）` |
| C2 | `fix(scripts): 未声明构建策略的插件仓以 --ignore-scripts 安装（setup/remote-install）` |
| C3 | `ci: verify/release 校验加入 modlens（pin tag v3.26.1）` |
| C4 | `docs: 记录 modlens（AGENTS/README/spec）` |
| C4b | `docs(plugin-dev): 补症状→处置（依赖构建脚本被 pnpm 拦截）` |
| C5 | `docs(plans): 记录 modlens 集成手册` |
