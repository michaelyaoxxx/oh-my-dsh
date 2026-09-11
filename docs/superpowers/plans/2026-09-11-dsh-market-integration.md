# dsh-market 源码集成（pin tag v1.45.1）—— 执行手册

> 执行方式：自动化执行，仅「必须用户确认」处停下；每个 commit 在 IDE 中审查。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

**目标**：把 [dsh-market/dsh-market](https://github.com/dsh-market/dsh-market)（包名 `dshmarket`）以 git submodule 源码形式接入 `plugins/dsh-market`，pin 上游正式 tag `v1.45.1`，经 link 挂载进 profile `dsh`。

**插件做什么**：DSH 内的可视化插件市场——浏览、搜索、一键安装社区插件；宿主侧在 webServer 上挂 HTTP 路由并在设置页提供开关。

## 0. 已拍板的决策

1. **tag pin**：pin 正式 tag `v1.45.1`（commit `1664cae`；该 tag 是**轻量标签**，比对仍统一用 `rev-parse <tag>^{}`）。
2. **不写任何 patch**：宿主入口没有 `export const inject`，而是用 **scoped `ctx.inject(['webServer','loader'], hostCtx => …)`**（与 modlens 同一姿势）——按 plugin-dev.md 的判据，这**不属于** `cannot get property "X" without inject` 那一类，无需补 patch。其余服务经 `ctx.get('agents')` 之类惰性取用。
3. **包管理器改用 npm**（本轮唯一需要用户拍板的点，已确认）：该仓**只有 `package-lock.json`（npm），没有 `pnpm-lock.yaml`**，而上游工具链本身就是 npm（`npm run build`、`prepare`/`prepack` 脚本）。用 pnpm 会忽略该 lockfile（版本解析不可复现）并在仓内生成未跟踪的 `pnpm-lock.yaml` 弄脏 submodule，且 `remote-install.sh` 会因缺 pnpm-lock **硬失败**、服务器无法部署。故给两个脚本加 npm 分支（见 §1.3）。
4. **必须构建**：`main` 指向 `lib/index.js`，而 `lib/` **未被 git 跟踪**（`.gitignore` 有 `lib/`）→ 不命中「入口已提交即跳过构建」，走 `run build`。

## 1. 已钉死的关键事实（侦察结论）

1. **形态**：单包仓（无 `packages/`）；`dsh.bundle.patch: ./cordis.patch.yml` 在自身目录 → link-plugins 根候选直接挂载；patch 只有一行 `- insert: id: dsh-market, name: 'dshmarket'`，无 guard、无 config。
2. **包名与 entry**：包名 `dshmarket`（**非 scoped**），entry `id: dsh-market` / `name: 'dshmarket'`，插件 `name = 'dsh-market'`。
3. **与 dsh-web 的 market 不冲突**：dsh-web 的是 `packages/dsh-market`（包名 `@linxin666/dsh-client-ui-market`），entry id 为 `ui-market`，聚合包再包一层 `web-ui-market`——与本插件的 `dsh-market` **三者 id 互不相同**。但两者**功能重叠**（都是「市场」UI），会同屏并存，属产品选择而非技术冲突。
4. **无 `packageManager` 字段** → 若走 pnpm，会由 `plugin_pnpm` 经 harness pin（11.7.0）执行；现在走 npm 分支，不涉及。
5. **lockfile**：仅 `package-lock.json`；`npm ci --ignore-scripts` 实测**可复现且不产生任何额外文件**。
6. **构建可复现**：`npm run build`（`tsc -p tsconfig.json && npm run build:client`，后者 `tsdown && node scripts/normalize-client-banner.mjs`）产物 `lib/index.js`（4.1 KB）与 `client/client.js`（567 KB）；其中 `client/client.js` **虽被跟踪**，但重建后与已提交版本**逐字节一致**（banner 脚本会归一化路径、排序 class-map），所以本地构建**不会弄脏** submodule——与 mineru 的绝对路径哈希情形相反。
7. **`prepare` / `prepack` 生命周期脚本**：`prepare: npm run build`。用 `--ignore-scripts` 跳过（否则安装期就触发一次构建），随后由脚本循环显式 `run build`，语义与 pnpm 侧一致。
8. **客户端注入的三个包均在 harness**：`@deepseek-ai/dsh-client-locale`（`client/locale`）、`dsh-client-ui-settings`（`client/ui-settings`）、`dsh-client-ui-theme`（`client/ui-theme`）。
9. **peer 依赖**：`@deepseek-ai/cordis: ^4.0.1`（harness 的 cordis 是 **4.0.2** ✓）、`@deepseek-ai/dsh-settings`（harness 存在，其 range 写的是 `^0.1.0-rc.7 || ^0.1.1-rc.2 || ^0.1.2-alpha.2`，**未含 0.1.5-rc.2**）、`@deepseek-ai/schemastery`。按既有结论，这类 range 在本仓解析链下**不做 npm 校验**（插件解析到 harness workspace 包），不构成阻断。
10. **`dsh-client-runtime` 是 npm 上的包**：本仓把它列为 devDependency（`^0.1.0-rc.7`）——这解释了 dsh-automation 为何会在 `dsh.client.inject` 里写它（harness 仓库内无此包，但 npm 上有）。

## 2. 本轮新增的通用修复：脚本支持 npm lockfile

### 2.1 动机（实测）

在隔离克隆里跑 `pnpm install`：

```
+ typescript 7.0.2 … Done in 12.5s using pnpm v11.7.0
$ git status --short
?? pnpm-lock.yaml          ← 未跟踪的新文件，脏化 submodule
```

且 `deploy/remote-install.sh` 当时对缺 pnpm-lock 的插件直接 `exit 1`（"服务器侧构建要求 --frozen-lockfile"）——**服务器无法部署**。

而 `npm ci --ignore-scripts`：exit 0、`git status` 干净、版本由**已提交的 package-lock.json** 钉死（可复现）。

### 2.2 实现（`scripts/setup.sh` 与 `deploy/remote-install.sh` 同形）

```bash
has_npm_lock() { [ -f "$1/package-lock.json" ]; }
plugin_run() { # 选定包管理器并在插件目录内执行：$1=目录，其余为命令与参数
  local d="$1"; shift
  if has_npm_lock "$d"; then
    ( cd "$d" && npm "$@" )
  else
    plugin_pnpm "$d" "$@"
  fi
}
# plugin_install 改为 $1=目录 $2=安装子命令（pnpm 用 install，npm 用 ci）
plugin_install() { local d="$1" cmd="$2"; shift 2; … plugin_run "$d" "$cmd" "$@" … }
```

循环体：

```bash
  if [ -f "$d/pnpm-lock.yaml" ]; then
    plugin_install "$d" install --frozen-lockfile
  elif has_npm_lock "$d"; then
    echo "==> ${d%/} 使用 npm（package-lock.json，可复现安装）"
    plugin_install "$d" ci
  else
    echo "注意: … 无 pnpm-lock.yaml 也无 package-lock.json …"
    plugin_install "$d" install
  fi
```

- 构建统一改成 `plugin_run "$d" run build`（npm 只认 `run`，pnpm 两者等价）。
- **服务器侧契约放宽**：`remote-install.sh` 原先「缺 pnpm-lock.yaml 即失败」，现改为「pnpm-lock.yaml 走 `--frozen-lockfile`，package-lock.json 走 `npm ci`，**两者都没有才失败**」——仍保持「服务器必须可复现安装」这条底线。
- npm 随 node 分发，不存在 corepack 按 `packageManager` 解析的回落问题。

## 3. 接入步骤

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/dsh-market/dsh-market.git plugins/dsh-market
git -C plugins/dsh-market checkout --detach v1.45.1   # 归一化
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
```

预期关键行（实测通过）：

- `==> plugins/dsh-market 使用 npm（package-lock.json，可复现安装）`
- `==> plugins/dsh-market 未声明可构建依赖（无 onlyBuiltDependencies/allowBuilds），以 --ignore-scripts 安装`
- `==> 构建插件: plugins/dsh-market/`（`tsdown && node scripts/normalize-client-banner.mjs`）
- `git submodule foreach` **七个仓**均 `0 dirty`

> 安装期会出现 `npm warn EBADENGINE`：`tsdown@0.22.14` 的传递依赖 `rolldown-plugin-dts@0.27.14` 要求 `node ^22.18.0 || >=24.11.0`，本机 v24.3.0 不在范围内。**仅警告**，构建实测通过；若日后构建报错，先把 Node 升到 24.11+ 再排查。

## 4. 挂载 + dump + boot 验证

```sh
make link-plugins      # 预期 "已挂载 7 个 bundle"
cd harness && DSH_HOME=… /tmp/… pnpm dsh --profile dsh --dump-config | grep -A2 "id: dsh-market"
```

实测：

| 项 | 结果 |
| --- | --- |
| 挂载 | ✓ `==> link dshmarket <- …/plugins/dsh-market`；**7 个 bundle** |
| dump | ✓ exit 0、`id: dsh-market` / `name: dshmarket`、无 warn |
| boot（宿主） | ✓ 隔离实例（`--port 0`）`dsh web: http://127.0.0.1:63278/?token=…`，日志 **0 个错误** |
| 客户端半侧 | ✓ 引导图含 `dshmarket/client.js`；`/plugins/??dshmarket/client.js&rev=…` → **HTTP 200、567583 字节** |

**boot 验证的隔离做法**（本轮新增，供以后复用）：用户实例占着 3080 时，**不要**抢占或共用 DSH_HOME。改用
`DSH_HOME=/tmp/dsh-verify` + `--port 0`（OS 分配空闲端口）。注意：`.dsh` 整树复制后，profile 的 `node_modules` 里有**相对路径的符号链接**（如 `@linxin666/dsh-client-ui-session-id -> ../../../../../plugins/…`），一旦搬离原位置就断，表现为
`cannot resolve profile bundle "…"`。修法：把副本里的链接重写为指向原目标的绝对路径：

```sh
cd <原 DSH_HOME>/profiles/dsh/node_modules
find . -type l | while read -r l; do tgt=$(realpath "$l") && ln -sfn "$tgt" "/tmp/dsh-verify/profiles/dsh/node_modules/$l"; done
```

**待用户 UI 验收**：设置页里的 Market 入口/内容是否渲染；「一键安装插件」是否可用（会写入 profile，属真实副作用）。

## 5. 过程记录

### 5.1 端口/实例冲突（沿用上一轮教训，本轮主动规避）

`make dev` 无法在 3080 被用户实例占用时验证。本轮**没有**停用户实例、也没有共用其 DSH_HOME（并发写同一会话库有风险），而是走隔离副本 + `--port 0`。第一次隔离副本失败（见 §4 的相对符号链接），修好后一次通过。

### 5.2 与 dsh-web 的「市场」功能重叠

技术上无冲突（entry id 三个都不同），但 UI 上会同时出现 dsh-web 的 Market 设置段与本插件的市场。属产品取舍，留给用户决定是否要 disable 掉其中一个。

## 6. CI/文档修正

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/verify.yaml` tag loop | 追加 `"plugins/dsh-market v1.45.1"`（并更新注释里的清单） |
| `.github/workflows/release.yaml` 快照清单循环 | 追加 `plugins/dsh-market` |
| `scripts/release.sh` | 追加 `check_pin_tag plugins/dsh-market v1.45.1` |
| `AGENTS.md` 稳定分支行 | 追加 `；dsh-market → 正式 tag \`v1.45.1\`（tag pin）` |
| `README.md` plugins 行 | 追加 `dsh-market pin tag \`v1.45.1\`` |
| `docs/superpowers/specs/…-design.md` | 子仓清单、目录树、release 校验行同步 |

## 7. Commit 切分

```sh
git add scripts/setup.sh deploy/remote-install.sh
git commit -m "feat(scripts): 支持 npm lockfile（package-lock.json 走 npm ci，服务器侧同）"

git add .gitmodules plugins/dsh-market
git commit -m "feat: 引入 dsh-market 源码 submodule（plugins/dsh-market，pin tag v1.45.1）"

git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 dsh-market（pin tag v1.45.1）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 dsh-market（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补症状→处置（npm-only 插件仓 / 隔离 boot 验证）"

git add docs/superpowers/plans/2026-09-11-dsh-market-integration.md
git commit -m "docs(plans): 记录 dsh-market 集成手册"
```

## 8. 与之前插件的机制差异

| 维度 | 之前 | dsh-market | 影响 |
| --- | --- | --- | --- |
| **包管理器** | 全部 pnpm（有的仓自带 pin，有的经 harness pin） | **npm**（仓内只有 package-lock.json，上游工具链也是 npm） | 首次触达：脚本新增 npm 分支；服务器部署契约放宽为「任一 lockfile」 |
| **入口 inject** | 自声明 `inject`（mineru/dsh-automation）或 scoped `ctx.inject`（modlens） | 无 `export const inject`，scoped `ctx.inject(['webServer','loader'])` | 无需 patch（与 modlens 同类） |
| **构建产物** | mineru 提交 `lib/`（重建会脏化）；better-sidebar/modlens 不提交 | `lib/` 未提交（须构建），`client/client.js` 提交且**重建可复现** | 必须构建但不脏化——三种形态里最理想的一种 |
| **命名** | 均为 scoped 包名 | **非 scoped**（`dshmarket`） | link 与 entry name 都用裸名，验证无误 |
