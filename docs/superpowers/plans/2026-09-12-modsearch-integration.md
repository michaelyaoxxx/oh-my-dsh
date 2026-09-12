# modsearch 源码集成（pin tag v5.10.2）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [liustack/modsearch](https://github.com/liustack/modsearch)（包名 `@liustack/modsearch`）以 git submodule 源码形式接入 `plugins/modsearch`，pin 上游正式 tag `v5.10.2`，经 link 挂载进 profile `dsh`。

**插件做什么**：给 DSH 的 web seam 提供**搜索**能力（`src` 是 CLI 侧），并带一个 Web 半侧。它是 modlens 的姊妹插件——modlens 文档里写明「视觉解析只归 modlens，网页搜索与抓取归 modsearch」。

## 0. 已拍板的决策

1. **tag pin**：`v5.10.2`（**注释标签**，tag 对象 `529e1a9` → commit `7c16451`）。
2. **需要一条本仓 profile patch**：见 §2——不是因为要补 inject，而是该插件改写了 `web` 行的 config 且**漏列了一个键**。
3. **零脚本改动**：本仓无 `packageManager`、无 `pnpm.overrides` → 走 harness pin 的 pnpm；`lib`/`dsh` 入口已提交但 `dist/` 需要构建（无 `main` 字段 → 跳过构建的判据不命中 → 正常构建）。

## 1. 已钉死的关键事实（侦察结论）

1. **形态**：单包仓（无 `packages/`）；`dsh.bundle.patch: ./cordis.patch.yml` 在自身目录 → link-plugins 根候选直接挂载。
2. **它的 patch 做两件事**（这是本轮的核心）：

   ```yaml
   - id: web
     config:
       searchProvider: modsearch
   - insert:
       - id: modsearch
         name: '@liustack/modsearch'
   ```

   —— 除了插入自己，还**改写 base 的 `web` 行**，把搜索 provider 路由到自己。entry id `modsearch` 与现有树无冲突。
3. **缺陷：漏列 base 的另一个 config 键**。dsh-base 在 0.1.5-rc.2 的 `web` 行有**两个**键：

   ```yaml
   - id: web
     name: '@deepseek-ai/dsh-web'
     config:
       searchProvider: deepseek-official
       fetchProvider: http
   ```

   而 modsearch 的 patch 注释断言「`searchProvider` is that row's only base key」（对更早的 harness 版本可能成立）。patch 的 `config` 是**整表替换**，于是 `fetchProvider` 被抹掉——**实测 dump 印证**：

   ```
   装前： searchProvider: deepseek-official / fetchProvider: http
   装后： searchProvider: modsearch                      ← fetchProvider 消失
   ```

   **dump 仍 exit 0（静默）**，因为 `WebRuntimeConfig` 的两个字段都是 optional。
4. **今天为何无害、为何仍然要修**：`dsh-web` 的 provider 选择契约是「未配置且**恰好一个**可用 provider 时自动选择」。树里只有一个 fetch provider（`web-fetch-http`），所以自动选对了。**但一旦出现第二个 fetch provider，取 fetch 会报 `WEB_PROVIDER_AMBIGUOUS`**，而根因（少了一个键）极难从症状反推。故用本仓 `patches/` 机制把整份 config 显式补齐。
5. **modsearch 只注册搜索 provider，不注册 fetch**：源码 `dsh/index.js:53` 只调 `registerSearchProvider`，且 `:115` 处显式守卫 `ctx.web?.registerSearchProvider` 不存在时打日志跳过。所以它不会与 `web-fetch-http` 争抢 fetch。
6. **客户端半侧存在**：`dsh.client = { inject: [], platform: 'web', immediately: true }`，exports `./client → ./dsh/client.js`（已提交）——`inject` 为空是它与 modlens 一致的「零依赖」姿态，不是没有客户端。
7. **依赖面最干净的一个**：**无 peerDependencies**；deps 仅 `commander` + `undici`；devDeps 仅 biome/types/vitest/vite/typescript。engines `>=22.13`（harness 要求 `^22.19 || >=24`，本机 24.3 满足）。
8. **产物**：`dsh/index.js`（36 KB，已提交）与 `dist/main.js`（122 KB，vite build **产物、gitignored、工具运行时 spawn 它**，必须构建）。

## 2. 本轮新增：`patches/restore-web-fetch-provider.yml`

```yaml
- id: web
  config:
    searchProvider: modsearch
    fetchProvider: http
```

- 本层在 **profile bundles 之后**应用（层序：bundles → profile `cordis.patch.yml` → home 级 → `--patch`），故能覆盖 modsearch 的 bundle patch。
- 因 `config` 是整表替换，**两个键都必须列**——只写 `fetchProvider` 会把 `searchProvider` 抹回默认。
- **维护注意**（已写进 patch 注释）：dsh-base 若再给 `web` 行加 config 键，本 patch 会整表覆盖，需同步补列；该文件是「插件上游缺陷」的临时补丁，上游修好后即可删除。

**合并幂等已实测**（重复 `link-plugins` 后 profile patch 逐字节不变），托管区确认含该行。

## 3. 接入步骤

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/liustack/modsearch.git plugins/modsearch
git -C plugins/modsearch checkout --detach v5.10.2   # 归一化
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> plugins/modsearch 无 packageManager，经 harness pin 的 pnpm 执行: pnpm install --frozen-lockfile --ignore-scripts`
- `==> 构建插件: plugins/modsearch/` → `pnpm run build`（vite build）
- `git submodule foreach` **十个仓**均 `0 dirty`

## 4. 挂载 + dump + boot 验证

| 项 | 结果 |
| --- | --- |
| 挂载 | ✓ `==> link @liustack/modsearch <- …`；**10 个 bundle** |
| dump（打 patch 前） | ✓ exit 0、**`fetchProvider` 已被抹掉**（缺陷实证） |
| dump（打 patch 后） | ✓ exit 0、`web` 行恢复为 `searchProvider: modsearch` + `fetchProvider: http`、**180 条目**、无 warn |
| boot（宿主） | ✓ 隔离实例（`--port 0`）`dsh web: http://127.0.0.1:63376/?token=…`，日志 **0 错误**、无 `WEB_PROVIDER_AMBIGUOUS` |
| 客户端半侧 | ✓ 引导图含 `@liustack/modsearch/client.js`（10 个 bundle 的客户端条目全部在）；该 bundle → **HTTP 200、42614 字节** |

boot 用**隔离实例**（复制 `DSH_HOME` 到 /tmp + `--port 0` + 改写副本内相对符号链接为绝对路径），不干扰用户正在运行的 3080 实例——做法同 dsh-market 手册 §4。

**待用户 UI 验收**：真实发起一次 web 搜索（走 `modsearch` provider）与一次页面抓取（走 `web-fetch-http`），确认两条能力都可用——尤其是抓取，它是本次被 patch 救回来的那条。

## 5. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | 追加 `"plugins/modsearch v5.10.2"`（并更新注释清单） |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/modsearch` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/modsearch v5.10.2` |
| `AGENTS.md` / `README.md` / spec | 稳定分支行、plugins 行、子仓清单/目录树/校验行同步 |

## 6. Commit 切分

```sh
git add patches/restore-web-fetch-provider.yml
git commit -m "fix(profile): 补回 web 行被 modsearch patch 抹掉的 fetchProvider"

git add .gitmodules plugins/modsearch
git commit -m "feat: 引入 modsearch 源码 submodule（plugins/modsearch，pin tag v5.10.2）"

git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 modsearch（pin tag v5.10.2）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 modsearch（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（bundle patch 整表覆盖 config 抹掉旁键）"

git add docs/superpowers/plans/2026-09-12-modsearch-integration.md
git commit -m "docs(plans): 记录 modsearch 集成手册"
```

## 7. 与之前插件的机制差异

| 维度 | 之前 | modsearch | 影响 |
| --- | --- | --- | --- |
| **bundle patch 改写 base 行** | 多数只 `insert` 自己（better-sidebar 的 patch 带 `disabled` guard） | **改写 base 的 `web` 行 config** 以路由搜索 provider | 首次因「插件的 patch 覆盖了 base 的旁键」而需要本仓补丁 |
| **缺陷的可见性** | inject 缺失 → 启动即报 `cannot get property` | **dump/boot 全绿**，缺陷只在「第二个 fetch provider 出现」时才炸 | 静默型；靠读 config 语义（optional + auto-select）才判断得出 |
| **依赖面** | 各有 peer/devDeps | **无 peerDependencies** | 最干净 |
| **客户端** | 多数有 | 有，但 `inject: []` + `immediately: true`（同 modlens） | — |
