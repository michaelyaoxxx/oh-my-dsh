# dsh-plugin-mineru 源码集成 —— 手动执行手册

> 执行方式：**逐条手动执行**，每步有命令、预期与验证点；每个 commit 在 IDE 中审查后再提交。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。
> 机制基线：better-sidebar 集成（同仓手册）已就位——profile dsh 运行时、宿主 ensure、patches 托管合并、根目录候选豁免均已生效，本插件复用现成机制。

## 0. 已拍板的决策

1. **源码接管**：`dsh-plugin-mineru` 以 git submodule 加入 `plugins/dsh-plugin-mineru`。
2. **pin 策略（用户已选）**：上游**无正式 tag**（只有 `master` 与 `adapt/v0.1.2-alpha.1` 两个分支），pin **master HEAD = `67abfedd`**（v0.2.4；adapt 分支对应旧 harness 基线 0.1.2-alpha.1，本仓 harness pin 是 0.1.3-alpha.2，master 更匹配）。按分支 pin 惯例校验（verify/release）。
3. **无冲突、无 disable patch**：web-all aggregate 不引用 mineru（已 grep 核实），bundle patch 单行 `id: dsh-mineru` 且无 guard——link-plugins 现成机制自动挂载，无需 disable。
4. **但需新增一条 inject patch**：首次 `make dev` 实测暴露 harness 侧 `connection.rpc.handle` 的 webServer 作用域缺陷（根因见 §1.8，处置见 §3b），`patches/` 新增 `inject-webserver-dsh-connection.yml`。

## 1. 已钉死的关键事实

1. **仓库形态**：单包仓 `@huanlin/dsh-plugin-mineru` v0.2.4；`dsh.bundle.patch: ./cordis.patch.yml`；`dsh.client.inject` 6 个 @deepseek-ai client 包 + platform web；deps 仅 `schemastery`；peerDeps 10 项（8 个 @deepseek-ai + cordis + react）。
2. **host 侧依赖面极小**：lib/index.js 实际只 import `@deepseek-ai/dsh-tools`——安装回退链已有（✓ 已核实）；lib/client.js 无 @deepseek-ai 直接 import（client.inject 走浏览器侧、从 harness 安装解析，与 better-sidebar 同机制，运行中已验证可行）。profile node_modules 缺失的 4 个 client peer 不影响 host 加载。
3. **lib/ 已提交在仓库内**（含 lib/client.js，无 prepare 脚本）→ link 挂载即可用，无需先 build。
4. **配置**：cordis.patch.yml 的 config 只有 `baseURL: 'http://localhost:18000'` 首启种子；真实配置在 DSH GUI 设置页（MinerU section：baseURL + 可选 API key + 解析默认值）。运行时解析功能依赖**用户自备的 MinerU FastAPI 服务**（上游要求 v3.4.4 / protocol v2）——无服务时工具调用报连接错误属预期，不影响插件挂载与设置页出现。
5. **坑：无 `packageManager` 字段**（better-sidebar 有 pnpm@11.8.0，mineru 没有）。在插件仓目录直接跑 `pnpm install` 时 corepack 向上找不到 pin 会回落 latest——本机 corepack 缓存里的 12.3.4 是坏的（MODULE_NOT_FOUND 已实测）。**修复**：经 harness 目录解析 pin 的 pnpm 执行：`cd harness && pnpm --dir ../plugins/dsh-plugin-mineru install --frozen-lockfile`（corepack 在 harness 目录按 harness pin=11.7.0 解析；`--dir` 让它在插件仓内安装，插件仓自己的 pnpm-workspace.yaml / lockfile 生效）。此坑需通用修复进 setup.sh / remote-install.sh（Step 2），否则 `make setup` 与服务器部署必炸。
6. **上游安装姿势**（README）：registry 版 `dsh plugin --profile web add @huanlin/dsh-plugin-mineru`——同样基于官方 web profile，本仓按惯例统一挂进 profile dsh。
7. **无 .github**：上游无 CI；插件仓 lockfile 存在（lockfileVersion 9.0，pnpm 11.7.0 兼容），服务器 frozen 安装前提成立。
8. **host 侧 RPC 注册缺陷（首次 `make dev` 实测）**：`ctx.connection.rpc.handle(...)` 注册路由时，`owner.webServer` 的解析发生在 **connection 服务自身的 fiber 作用域**，而非调用方 ctx 的作用域——`HostConnectionService.rpc` 捕获 `const owner = this.ctx`（`packages/client/connection/src/rpc-host.ts:80`），而 `this.ctx` 是 Service 构造时存入的服务自身 ctx；cordis 服务解析 walk 的起点是 `(ctx[symbols.shadow] ?? ctx).fiber`（`vendor/cordis/src/reflect.ts:155`）。profile dsh 里 `connection` entry 的 inject 只有 `webRuntime`（`--dump-config` 可查），webServer 由兄弟 entry 提供、不在其 fiber 链上 → 任何 host 侧插件调用 `connection.rpc.handle` 都抛 `cannot get property "webServer" without inject`（`packages/client/connection/src/rpc-host.ts:179`）；mineru 的 `registerRpc`（`lib/index.js:743`）正是第一个这样的调用方。**给 mineru 自己加 inject 无用**（实测其 `fiber.inject`/`fiber.store` 已含 webServer 仍报错，walk 不走它），处置见 §3b。

## 2. Step 1 —— submodule + pin master HEAD + 安装依赖

### 1.1 添加 submodule（默认即落在 master HEAD，即 pin 目标）

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/HuanLinOTO/dsh-plugin-mineru.git plugins/dsh-plugin-mineru
```

### 1.2 核对形态（验证点）

```sh
cd plugins/dsh-plugin-mineru
git status --short --branch    # 实测：## master...origin/master（见下方说明）
node -p "require('./package.json').version"          # 0.2.4
ls pnpm-lock.yaml cordis.patch.yml                   # frozen-lockfile 前提 + bundle 声明
git log -1 --format="%h %s"                          # 67abfedd fix(i18n): better-locale 接入…
```

核对 `.gitmodules` 新增条目与现有格式一致（path/url）。**不手动改 pin**。

> **实测差异（2026-09-09）**：`git submodule add` 克隆后 HEAD 停在默认分支上（`## master...origin/master`），
> 并非手册原先写的 detached HEAD；`git submodule update --init --recursive` 在「HEAD 已等于 pin」时会跳过、
> 不会 detach（harness/dsh-web 当初被 detach，是因为 update 时 HEAD ≠ pin）。pin commit 本身正确
> （`67abfedd` = `origin/master`），CI 校验比的是 `rev-parse HEAD` vs `origin/master`，两种状态都通过——
> 但按 AGENTS.md「submodule 的 detached HEAD 是特性」的约定，统一归一化。

### 1.2b 归一化为 detached HEAD（约定）

```sh
cd /Users/michaelyao/workspace/dsh
git -C plugins/dsh-plugin-mineru checkout --detach          # HEAD 不动（仍 67abfedd），只脱离分支
git -C plugins/dsh-plugin-mineru status --short --branch    # 预期：## HEAD (no branch)
```

### 1.3 安装依赖（关键：经 harness pnpm，绕开 corepack 回落 latest）

```sh
cd /Users/michaelyao/workspace/dsh/harness
pnpm --dir ../plugins/dsh-plugin-mineru install
```

预期：`Done in Xs using pnpm v11.7.0`（**不是** 12.x——若出现 12.x 或 MODULE_NOT_FOUND，说明没从 harness 目录跑）。产物：插件仓 `node_modules/`（含 schemastery 与 dev 工具链）。

### 1.4 Commit（C1）

```sh
cd /Users/michaelyao/workspace/dsh
git add .gitmodules plugins/dsh-plugin-mineru
git commit -m "feat: 引入 dsh-plugin-mineru 源码 submodule（plugins/dsh-plugin-mineru，pin master）"
```

## 3. Step 2 —— setup.sh / remote-install.sh 通用修复（无 packageManager 的插件仓）

> 全部改动在主仓 `scripts/`、`deploy/`。**不动**任何 submodule。

### 2.1 修改 `scripts/setup.sh` 插件循环

循环里 install 与 build 两处各自内联了同一个「pnpm 该从哪解析」的判定。C2 只改了 install 那一处，build 仍是 `( cd "$d" && pnpm build )`——无 packageManager 的仓照样回落 12.3.4，`make setup` 在 `==> 构建插件: plugins/dsh-plugin-mineru/` 处炸（实测 `Cannot find module '…/corepack/v1/pnpm/12.3.4/bin/pnpm.cjs'`）。故收敛成两个 helper，install/build 共用同一个入口：

```bash
# 无 packageManager 的插件仓（如 dsh-plugin-mineru）corepack 在仓内向上找不到 pin 会回落
# latest（本机缓存的 12.3.4 已损坏）；统一经 harness 目录解析 harness pin 的 pnpm，--dir 让
# 命令仍在插件仓内执行（仓内 pnpm-workspace.yaml / lockfile 生效）。install 与 build 同此
# 路径——按调用点各写一遍判定曾漏掉 build，故收敛成一个入口。
has_package_manager() {
  node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager?0:1)' "$1/package.json"
}
plugin_pnpm() {
  local d="$1"; shift
  if has_package_manager "$d"; then
    ( cd "$d" && pnpm "$@" )
  else
    echo "==> ${d%/} 无 packageManager，经 harness pin 的 pnpm 执行: pnpm $*"
    ( cd harness && pnpm --dir "../$d" "$@" )
  fi
}
```

循环体改为：

```bash
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  if [ -f "$d/pnpm-lock.yaml" ]; then
    plugin_pnpm "$d" install --frozen-lockfile
  else
    echo "注意: ${d%/} 无 pnpm-lock.yaml，将执行非冻结安装（pnpm install），可能在插件 submodule 内生成或改动文件（如 lockfile）。如需可复现安装，请在插件仓提交 pnpm-lock.yaml。"
    plugin_pnpm "$d" install
  fi
  # 入口文件已提交在仓库内的插件自带构建产物（pin 的一部分）→ 跳过 build：本地重建会因
  # 绝对路径哈希（如 CSS module 类名）产生与 pin 不同的产物，弄脏 submodule。源码形态的单包
  # 仓（入口未提交，如 dsh-better-sidebar）与 workspace 根（无 main，如 dsh-web）需要构建。
  main_entry="$(node -e 'const fs=require("fs");process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).main||"")' "$d/package.json")"
  if [ -n "$main_entry" ] && git -C "$d" ls-files --error-unmatch "${main_entry#./}" >/dev/null 2>&1; then
    echo "==> 跳过构建: ${d%/} 入口 ${main_entry} 已提交在仓库内"
  elif node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).scripts?.build?0:1)' "$d/package.json" 2>/dev/null; then
    echo "==> 构建插件: $d"
    plugin_pnpm "$d" build
  fi
done
```

> **跳过构建的判据**：根 `main` 入口文件被 git 跟踪 ⇒ 该仓随 pin 自带产物，构建只会弄脏 submodule。mineru 的 `lib/client.js` 内嵌了由**绝对源码路径**派生的 CSS module 类名哈希（pin 里是 `D:\Projects\deepseek-harness\dsh-mineru\…`，本机是 `/Users/michaelyao/…`），本地重建**永远**对不上 pin。better-sidebar 不跟踪 `lib/`（入口未提交，必须构建），dsh-web 是 workspace 根（无 `main`，必须构建）。

### 2.2 修改 `deploy/remote-install.sh` 插件安装循环（服务器侧同一机制）

步骤 4 各插件循环：lockfile 硬性检查保留不变，pnpm 判定与构建跳过规则与 setup.sh 完全同形（同两个 helper，同 `main_entry` 跳过判据）——服务器侧无 packageManager 的仓同样会回落 latest，且服务器上重建 mineru 同样会弄脏 submodule。

```bash
has_package_manager() {
  node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager?0:1)' "$1/package.json"
}
plugin_pnpm() {
  local d="$1"; shift
  if has_package_manager "$d"; then
    ( cd "$d" && pnpm "$@" )
  else
    echo "==> ${d%/} 无 packageManager，经 harness pin 的 pnpm 执行: pnpm $*"
    ( cd harness && pnpm --dir "../$d" "$@" )
  fi
}

for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  if [ ! -f "$d/pnpm-lock.yaml" ]; then
    echo "错误: 插件 ${d%/} 缺少 pnpm-lock.yaml，服务器侧构建要求 --frozen-lockfile 可复现安装。请在插件仓提交 lockfile 后重试。" >&2
    exit 1
  fi
  plugin_pnpm "$d" install --frozen-lockfile
  main_entry="$(node -e 'const fs=require("fs");process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).main||"")' "$d/package.json")"
  if [ -n "$main_entry" ] && git -C "$d" ls-files --error-unmatch "${main_entry#./}" >/dev/null 2>&1; then
    echo "==> 跳过构建: ${d%/} 入口 ${main_entry} 已提交在仓库内"
  elif node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).scripts?.build?0:1)' "$d/package.json" 2>/dev/null; then
    echo "==> 构建插件: $d"
    plugin_pnpm "$d" build
  fi
done
```

> remote-install.sh 的 `check_pnpm`（工具链校验）对无 packageManager 的仓本就是跳过（「未声明 packageManager 的仓库跳过校验」），无需改动。

### 2.3 验证（本机，静态检查 + 插件循环实跑）

```sh
cd /Users/michaelyao/workspace/dsh
bash -n scripts/setup.sh && bash -n deploy/remote-install.sh
shellcheck -S style scripts/setup.sh deploy/remote-install.sh
# 把改动的第 5 段单独跑一遍（等价于 make setup 的插件部分，不重跑 harness）
sed -n '/^# ---------- 5\. 各插件/,/^done$/p' scripts/setup.sh > /tmp/plugin-loop.sh && bash /tmp/plugin-loop.sh
git submodule foreach --quiet 'echo "$name: $(git status --short | wc -l | tr -d " ") dirty"'
```

预期（实测通过）：三个插件各自 install 成功，其中

- `==> plugins/dsh-plugin-mineru 无 packageManager，经 harness pin 的 pnpm 执行: pnpm install --frozen-lockfile` → `Done in 166ms using pnpm v11.7.0`（**不是** 12.x）
- `==> 跳过构建: plugins/dsh-plugin-mineru 入口 ./lib/index.js 已提交在仓库内`
- better-sidebar / dsh-web 走 `==> 构建插件: …` 正常构建
- 无 `MODULE_NOT_FOUND`；`git submodule foreach` 四个仓均 `0 dirty`（mineru 不再出现 ` M lib/client.js`）

### 2.4 Commit（C2）

```sh
git add scripts/setup.sh deploy/remote-install.sh
git commit -m "fix(scripts): 无 packageManager 的插件仓经 harness pin 的 pnpm 安装（setup/remote-install）"
```

### 2.5 追加修复（C2c）——构建同样走 helper + 入口已提交则跳过构建

首次 `make setup` 在构建 mineru 时仍炸（§2.1 开头），修复为上面的 helper 收敛 + `main_entry` 跳过判据：

```sh
git add scripts/setup.sh deploy/remote-install.sh
git commit -m "fix(scripts): 插件构建同经 harness pin 的 pnpm；入口已提交的插件跳过构建"
```

## 3b. Step 2b —— 修复启动失败：connection 侧 webServer 作用域（新增 `patches/`）

### 2b.1 症状

首次 `make dev` 在 boot 阶段失败（`log/dev-2026-09-09-21:31:25.log`）：

```
Error: dsh: plugin tree failed to load: failed to apply loader entry dsh-mineru
(@huanlin/dsh-plugin-mineru): cannot get property "webServer" without inject
    at Fiber.<anonymous> (packages/client/connection/src/rpc-host.ts:179:19)
    at Proxy.register (packages/client/connection/src/rpc-host.ts:178:18)
    at Object.handle (packages/client/connection/src/rpc-host.ts:82:42)
    at registerRpc (plugins/dsh-plugin-mineru/lib/index.js:743:21)
```

根因见 §1.8：这是 harness 侧的作用域行为，**不修 submodule**（harness、插件仓都是 pin 仓），在主仓 patch 层处置。

### 2b.2 新增 `patches/inject-webserver-dsh-connection.yml`

内容（详见文件内注释）：

```yaml
- id: connection
  inject:
    - webRuntime
    - webServer
```

> **`inject` 是整表替换，不是合并**：`applyEntryPatches` 逐 key 赋值（`vendor/include/src/index.ts:121-124`），
> 故必须把原有的 `webRuntime` 一并列出——该 entry 的 `config: !!js ctx.webRuntime.trustedHosts` 依赖它。
> 维护注意：上游 bundle 若给 `connection` entry 新增 inject 项，本 patch 会整表覆盖掉，需同步补列。
> 副作用：`connection` 现在等待 webServer 就绪后才加载，故 profile dsh 必须始终带 web 宿主 bundle
> （`link-plugins.sh` 已幂等 ensure `@deepseek-ai/dsh-web-app`）。

### 2b.3 验证（boot 不再失败）

```sh
cd /Users/michaelyao/workspace/dsh
bash scripts/link-plugins.sh          # 合并 patch 进 profile
make dev                              # 出现 dsh web: http://127.0.0.1:3080/?token=… 即成功，Ctrl-C 退出
```

预期：不再出现 `cannot get property "webServer" without inject`；HTTP 端返回 303（重定向进应用）。

### 2b.4 Commit（C2b）

```sh
cd /Users/michaelyao/workspace/dsh
git add patches/inject-webserver-dsh-connection.yml
git commit -m "fix(profile): connection 入口补 webServer 注入，修复 host 侧 rpc.handle 注册失败"
```

## 4. Step 3 —— 挂载 + dump 验证（本地，boot-free）

### 3.1 挂载

```sh
cd /Users/michaelyao/workspace/dsh
make link-plugins     # 输出经 tee 落盘 log/link-plugins-*.log（Makefile 日志改造已生效）
```

预期关键行：

- `==> link @huanlin/dsh-plugin-mineru <- /Users/michaelyao/workspace/dsh/plugins/dsh-plugin-mineru`
- 跳过名单仍是 16 个家族成员（mineru 不在其中）
- `完成: 已挂载 4 个 bundle 到 profile dsh`

### 3.2 检查 profile 落盘

```sh
node -p "JSON.stringify(require('/Users/michaelyao/workspace/dsh/.dsh/profiles/dsh/package.json'),null,1)" | grep -A9 '"bundles"'
```

预期 bundles = base / web-app / session-id / web-all / dsh-better-sidebar / **@huanlin/dsh-plugin-mineru**（6 项）；dependencies 含 `"@huanlin/dsh-plugin-mineru": "link:…/plugins/dsh-plugin-mineru"`。

### 3.3 dump 组合树验证

```sh
cd /Users/michaelyao/workspace/dsh/harness
DSH_HOME=/Users/michaelyao/workspace/dsh/.dsh COREPACK_DEFAULT_TO_LATEST=0 CI=true \
  pnpm dsh --profile dsh --dump-config > /tmp/dump-mineru.txt 2>&1; echo "exit=$?"
grep -n "^# ==" /tmp/dump-mineru.txt        # 新增 section: @huanlin/dsh-plugin-mineru
grep -n -A5 "id: dsh-mineru" /tmp/dump-mineru.txt   # 预期 baseURL: 'http://localhost:18000' 种子
grep -i "warn\|not found" /tmp/dump-mineru.txt || echo "无 warn ✓"
```

### 3.4 幂等回归

```sh
cd /Users/michaelyao/workspace/dsh
cp .dsh/profiles/dsh/cordis.patch.yml /tmp/p1
bash scripts/link-plugins.sh >/dev/null
diff /tmp/p1 .dsh/profiles/dsh/cordis.patch.yml && echo "幂等 ✓"
```

## 5. Step 4 —— CI/校验/文档修正

改动点清单：

| 文件                                            | 改动                                                                                                                                          |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/verify.yaml` pin 检查 loop | `"harness master" "plugins/dsh-web main"` → 追加 `"plugins/dsh-plugin-mineru master"`                                                    |
| `.github/workflows/release.yaml` 快照清单循环 | `for sub in harness plugins/dsh-web plugins/dsh-better-sidebar` → 追加 `plugins/dsh-plugin-mineru`                                       |
| `scripts/release.sh`                          | `check_pin plugins/dsh-web main` 之后追加 `check_pin plugins/dsh-plugin-mineru master`                                                    |
| `AGENTS.md` 稳定分支行                        | 追加`；dsh-plugin-mineru → \`master\``                                                                                                     |
| `README.md` plugins 行                        | 追加`、dsh-plugin-mineru pin \`master\``                                                                                                    |
| `docs/superpowers/specs/…-design.md`         | ① 子仓清单加 mineru 行（pin`master`）；② 目录树 plugins/ 加分支；③ setup 语义补「无 packageManager 的插件仓经 harness pin 的 pnpm 安装」 |
| `docs/plugin-dev.md`                         | 「约定」补 submodule add 后需 `checkout --detach`；「常见问题」补 4 条症状→处置（宿主缺失 / 服务注入作用域 / 无 packageManager / 本地重建弄脏 submodule），把本轮踩坑按**症状**归档 |

### Commit 切分

```sh
git add .github/workflows/verify.yaml .github/workflows/release.yaml scripts/release.sh
git commit -m "ci: verify/release 校验加入 dsh-plugin-mineru（pin master）"

git add AGENTS.md README.md docs/superpowers/specs/2026-09-08-dsh-superproject-design.md
git commit -m "docs: 记录 dsh-plugin-mineru（AGENTS/README/spec）"

git add docs/plugin-dev.md
git commit -m "docs(plugin-dev): 补集成踩坑的症状→处置（宿主缺失/服务注入作用域/无 packageManager）"

git add docs/superpowers/plans/2026-09-09-dsh-plugin-mineru-integration.md
git commit -m "docs(plans): 记录 dsh-plugin-mineru 集成手册"
```

## 6. Step 5 —— make dev 端到端验证

```sh
cd /Users/michaelyao/workspace/dsh
make dev     # 输出经 tee 落盘 log/dev-*.log
```

逐项核对：

0. **boot 成功**：出现 `dsh web: http://127.0.0.1:3080/?token=…`，无 `cannot get property`（§3b 已修复；若复现回看 §1.8/§3b）。
1. 前置 link-plugins 输出同 §3.1（4 个挂载，含 mineru）。
2. UI：**DSH 设置页出现 MinerU section**（baseURL + 可选 API key + 解析默认值）——mineru 是工具型插件（5 个文档解析工具暴露给模型），**不会**在侧边栏新增 tab，属预期。
3. 硬刷新浏览器后设置页可见即通过挂载验收；工具端到端（PDF→Markdown）需要真实 MinerU 服务（baseURL 指向你的 MinerU FastAPI，协议 v2），无服务时工具报连接错误属预期。

**验证记录（2026-09-09）**：

- 0/1 项实测通过：`==> link @huanlin/dsh-plugin-mineru <- …` 与 `dsh web: http://127.0.0.1:3080/?token=…` 均出现，无 `cannot get property`；带 token 访问 303、根路径 401（无 token 属预期）。日志 `log/dev-2026-09-09-21:59:06.log`。
- 第 2 项人工确认：DSH 设置页可见 MinerU section（baseURL + 可选 API key + 解析默认值），侧边栏无新增 tab（预期）。
- 第 3 项（真实 MinerU 服务端到端）未验证——需要可用的 MinerU FastAPI 服务。

## 7. 风险与兜底

| 风险                                     | 症状                                      | 处置                                                                                                                                 |
| ---------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| boot 报`cannot get property "webServer" without inject` | dsh-mineru entry 加载失败、进程退出      | §3b 的 patch 缺失或被整表覆盖：确认 `patches/inject-webserver-dsh-connection.yml` 存在、且 `link-plugins.sh` 已合并（`grep -A3 "id: connection" .dsh/profiles/dsh/cordis.patch.yml` 应见 `- webServer`） |
| 插件仓内直接`pnpm install` 回落 latest | 12.3.4 MODULE_NOT_FOUND                   | 一律经 harness pnpm：`cd harness && pnpm --dir ../plugins/dsh-plugin-mineru install`；C2/C2c 已把 setup/remote-install 的 install 与 build 都修成同姿势（`plugin_pnpm` 单一入口） |
| 本地构建弄脏 mineru submodule            | ` M lib/client.js`（CSS module 类名哈希来自绝对源码路径） | C2c 起入口已提交的插件跳过构建（`main_entry` 判据）；若已被弄脏：`git -C plugins/dsh-plugin-mineru checkout -- lib/client.js` |
| dump 出现`warn: … not found`          | 某 peer 解析失败                          | 贴 dump 给我；host 侧只依赖 dsh-tools（已核实回退链有），若报其他名字再查                                                            |
| MinerU 工具调用报连接错误                | 无 MinerU 服务或 baseURL 不对             | 属预期；在 DSH 设置 MinerU section 配置真实服务地址                                                                                  |
| 上游 master 前移                         | verify/release 拦截（pin≠origin/master） | 显式更新 pin：`cd plugins/dsh-plugin-mineru && git fetch origin master && git checkout origin/master` → 主仓 `git add` + commit |

## 8. Commit 汇总（全部无 AI 署名）

| #  | Message 建议                                                                                    |
| -- | ----------------------------------------------------------------------------------------------- |
| C1 | `feat: 引入 dsh-plugin-mineru 源码 submodule（plugins/dsh-plugin-mineru，pin master）`        |
| C2 | `fix(scripts): 无 packageManager 的插件仓经 harness pin 的 pnpm 安装（setup/remote-install）` |
| C2b | `fix(profile): connection 入口补 webServer 注入，修复 host 侧 rpc.handle 注册失败`           |
| C2c | `fix(scripts): 插件构建同经 harness pin 的 pnpm；入口已提交的插件跳过构建`                     |
| C3 | `ci: verify/release 校验加入 dsh-plugin-mineru（pin master）`                                 |
| C4 | `docs: 记录 dsh-plugin-mineru（AGENTS/README/spec）`                                          |
| C4b | `docs(plugin-dev): 补集成踩坑的症状→处置（宿主缺失/服务注入作用域/无 packageManager/构建弄脏 submodule）` |
| C5 | `docs(plans): 记录 dsh-plugin-mineru 集成手册`                                                |
