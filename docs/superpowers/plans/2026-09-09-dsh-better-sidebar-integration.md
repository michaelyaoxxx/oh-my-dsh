# dsh-better-sidebar 源码集成 + 运行时统一 profile dsh —— 手动执行手册

> 执行方式：**逐条手动执行**，每步有命令、预期与验证点；每个 commit 在 IDE 中审查后再提交。
> 可见输出用中文；commit message **不加任何 AI 署名**（含 `Co-Authored-By`）。

## 0. 已拍板的决策

1. **源码接管**：`dsh-better-sidebar` 以 git submodule 加入 `plugins/dsh-better-sidebar`（源码版本接管 registry 0.18.0 的运行位）。
2. **profile 层写入**：repo 内 versioned patch 文件（`patches/disable-web-ui-better-sidebar.yml`），由 `link-plugins.sh` / `remote-install.sh` 幂等合并进 profile `dsh` 的 `cordis.patch.yml`（禁用 dsh-web-all 的 AUTO-GENERATED 外部行 `web-ui-better-sidebar`）。
3. **安装位置**：`plugins/dsh-better-sidebar`。
4. **（本次调查新增，已拍板）运行时统一到 profile `dsh`**：`make dev` / `dsh.service` / CI 冒烟从 `pnpm dsh web --no-open` 改为 `pnpm dsh --profile dsh --no-open`。理由见 §1.1、§1.9。
5. **（用户新定）pin 正式版 tag**：dsh-better-sidebar 不 pin main HEAD，pin 上游正式发布 tag `v0.18.0`（commit `9e1a034`，已核对为 origin/main 祖先、bundle 事实与 §1.6 一致）。这是对「稳定分支 pin」惯例的例外（tag pin 比分支 HEAD 更稳）；`verify.yaml` / `release.sh` 的 pin 校验需增加 tag 比对模式（Step 4）。

## 1. 已钉死的关键事实（防再踩坑）

1. **`dsh web` 是 harness 硬编码别名 = `--profile web`**（[args.ts:163,175](harness/apps/cli/src/args.ts#L163-L175)），boot 官方模板 profile（`PROFILE_TEMPLATES.web`，首次使用自动初始化，见 profile.ts）。**`make dev` 加 `--profile dsh` 之前，link-plugins 挂载的 profile `dsh`（web-all 全家桶）从未被启动过**——market/task-board/session-id 从未在运行 UI 加载。
2. **loader patch 的 disable 语法 = id 定位 override**，`- disable:` 块无效（会被 include 当无 id patch 跳过并 warn）。官方样例 [desktop.cordis.patch.yml:4](harness/apps/desktop-host/config/desktop.cordis.patch.yml#L4)：
   ```yaml
   - id: web-ui-better-sidebar
     name: dsh-better-sidebar     # name 作 mismatch 防护：dsh-web 若改行会 warn
     disabled: true
   ```
3. **profile patch 文件 = 顶层 YAML 数组**：`[]`（空模板）后直接追加顶层条目是**非法 YAML**（两个顶层节点）。托管合并必须整体重写，不得 append（见 §4.1）。
4. **profile dsh 组合基线**（本手册写作时实测）：`--profile dsh --dump-config` = 104 entries、3 个 bundle section（`@deepseek-ai/dsh-base`、`@linxin666/dsh-client-ui-session-id`、`@linxin666/dsh-web-all`），外部行 `web-ui-better-sidebar`（name `dsh-better-sidebar`）在树中第 407-409 行；加 disable patch 后组合树出现 `disabled: true`，dump 正常、无 warn。
5. **merge 脚本三条路径已回归**（空 patches / 恢复 disable / 全新文件）：输出恒为合法顶层数组、幂等（重复执行逐字节不变）、保留 harness 模板注释头与用户手工条目。
6. **dsh-better-sidebar 上游形态**：单包仓，root `package.json` 声明 `dsh.bundle.patch: ./cordis.patch.yml`，自带 `pnpm-lock.yaml`（服务器 `--frozen-lockfile` 前提成立）与 build script（tsdown）；patch 内源行 `id: better-sidebar` 带 guard（`!!js` 表达式：存在其他启用且同名的 entry 时 self-disable）。
7. **link-plugins 现状**：skip 逻辑把「出现在任一候选 dependencies 里」的候选一律跳过（DEP_NAMES 命中），`dsh-better-sidebar` 因在 dsh-web-all deps 里会被误 skip——必须豁免「根目录独立候选」（不在任何 `packages/*/` 子目录下的候选，即外部单包仓）。
8. `.dsh/profiles/web/`（今天 10:26 auto-init、14:11 手动装入 better-sidebar 0.18.0）是 `dsh web` 别名的产物，**弃用**（清理可选，见 Step 0.3）。
9. **web 宿主来自官方 bundle `@deepseek-ai/dsh-web-app`**（web 模板 bundles = [base, web-app]，dump 中它提供 `webserver`/`web-runtime` 条目）。**profile dsh 原 bundles（[base, session-id, web-all]）没有宿主**——组合树无 webserver，boot 完后事件循环空转「卡住」不绑 3080（已实测：进程 S+ 0% CPU 卡 71s+，kevent 空等）。修复 = bundles 中 base 之后插入 `@deepseek-ai/dsh-web-app`（从安装回退链 `.dsh/profiles/node_modules/@deepseek-ai/dsh-web-app` 解析，无需作为依赖安装；dry-run 组合验证通过：webserver/web-runtime 条目出现、无 warn）。
10. **v0.18.0 tag 已核对**（用户定 pin 正式版）：上游 tag `v0.18.0` = commit `9e1a034`，是 origin/main（`d88dcfc`）的**祖先**（正式发布 tag）；tag 上 package.json = name `dsh-better-sidebar` / version `0.18.0` / `dsh.bundle.patch: ./cordis.patch.yml` / platform `web`，cordis.patch.yml 源行 `id: better-sidebar`（guard 同 §1.6），`pnpm-lock.yaml` 存在——§1.6 全部事实在 pin 版本上成立。

## 2. Step 0 —— 预检：停旧实例 + boot 形态实证（先于一切改动）

> 关键实证已得出：原 profile dsh 缺 web 宿主会卡住；补上 `@deepseek-ai/dsh-web-app` 后 boot 正常。**此步不产生 commit**。

### 0.1 停掉运行中的旧实例（你正在跑的 `make dev`，boot 的是 web profile）

```sh
pgrep -fl "dsh web"        # 确认进程（预期看到 pnpm dsh web --no-open）
```

在跑 `make dev` 的终端 Ctrl+C 停掉；无法访问终端时：

```sh
# 谨慎：只 kill 你自己确认过的 pnpm dsh 进程树（含 --no-open 字样），别误伤
pkill -f "dsh web --no-open"
```

确认 3080 已释放：`curl -s -m 2 http://127.0.0.1:3080/ || echo "已释放"`

### 0.2 boot 形态实证（已执行一半：暴露宿主缺口 → 修复 → 复验）

**已观察（2026-09-09）**：`pnpm dsh --profile dsh --no-open` 首次实跑，输出停在 SQLite ExperimentalWarning 后不再往下——进程 S+ 0% CPU、3080 无监听。原因见 §1.9：profile dsh 原 bundles 没有 web 宿主 `@deepseek-ai/dsh-web-app`，组合树无 webserver 条目，boot 完事件循环空转。

**0.2a 停掉卡住的进程**（在你正跑它的终端 Ctrl+C；或另开终端确认）：

```sh
pgrep -fl "bin.ts --profile dsh"   # 预期列出进程；Ctrl+C 后应无输出
```

**0.2b 补宿主 bundle**（本地运行态直接改，一次生效；持久化由 Step 2 的脚本 ensure 步骤接管）：

```sh
cd /Users/michaelyao/workspace/dsh
node -e '
const fs=require("fs"),p=".dsh/profiles/dsh/package.json"
const m=JSON.parse(fs.readFileSync(p,"utf8"))
const b=m.dsh.profile.bundles
if(!b.includes("@deepseek-ai/dsh-web-app")){
  b.splice(b.indexOf("@deepseek-ai/dsh-base")+1,0,"@deepseek-ai/dsh-web-app")
  fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")
}
console.log("bundles:",JSON.stringify(m.dsh.profile.bundles))'
```

预期输出 bundles = `["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","@linxin666/dsh-client-ui-session-id","@linxin666/dsh-web-all"]`。

**0.2c 复验 boot**：

```sh
cd /Users/michaelyao/workspace/dsh/harness
DSH_HOME=/Users/michaelyao/workspace/dsh/.dsh CI=true pnpm dsh --profile dsh --no-open
```

预期与检查点：

- 正常起服务、不弹浏览器（宿主是官方 web-app bundle，`--no-open` 与 web 模板同族；dry-run 组合已验证 webserver/web-runtime 条目无 warn）。
- UI 打开后（token flow 同现状）：顶部/侧栏应出现 **session-id、market、task-board** 等入口（web-all 全家桶第一次真正运行）。
- 此阶段 **不会**出现 better-sidebar（dsh profile 还没挂源码 bundle；registry 0.18.0 只装在已弃用的 web profile）。
- 验证完 Ctrl+C。

> 若 web profile 下你习惯的官方 UI 功能在 web-all 下有差异，这正是要提前发现的点——统一形态后以 web-all 为准。

### 0.3 （可选）清理弃用的 web profile 残留

```sh
rm -rf /Users/michaelyao/workspace/dsh/.dsh/profiles/web
```

留着的后果：误跑 `dsh web`（不带 --profile）会 auto-init 重建并 boot 官方模板 + registry 0.18.0，与统一后的形态混淆。建议删。**不要动** `.dsh/profiles/node_modules`（两个 profile 共用的解析回退链，link-profile.mjs 产物）。

## 3. Step 1 —— submodule 加入 plugins/dsh-better-sidebar

### 1.1 添加 submodule（`submodule add` 默认落在 main HEAD，随后切到 tag）

```sh
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/omdsh-dev/DSH-better-sidebar.git plugins/dsh-better-sidebar
```

### 1.1b pin 正式版 tag `v0.18.0`（用户指定，取代 main HEAD）

```sh
cd /Users/michaelyao/workspace/dsh/plugins/dsh-better-sidebar
git fetch origin --tags          # 拉取 tag（submodule add 只拉了 main 历史；已拉过则 no-op）
git checkout v0.18.0             # detached HEAD 到正式 tag（detached 是特性）
git log -1 --format="%h %s"      # 预期 9e1a034（= v0.18.0，origin/main 祖先）
cd /Users/michaelyao/workspace/dsh
git add plugins/dsh-better-sidebar   # 重新暂存 gitlink：submodule add 暂存的是 main HEAD
```

### 1.2 核对形态（验证点）

```sh
cd plugins/dsh-better-sidebar
git status --short --branch    # detached HEAD at 9e1a034（预期；detached 是特性）
node -p "require('./package.json').version"          # 0.18.0（正式版）
ls pnpm-lock.yaml cordis.patch.yml dsh.plugin.json   # frozen-lockfile 前提 + bundle 声明
git log -1 --format="%h %s"
```

核对 `.gitmodules` 新增条目与现有格式一致（path/url）。**不手动改 pin**。

### 1.3 本地依赖安装（开发机，普通 install）

```sh
pnpm install     # corepack 依插件仓 packageManager 解析（与 harness 版本锚点无关）
```

> 插件以 link: 挂载后，其依赖从插件自身 node_modules（真实路径 parent-walk）解析，必须在本仓先装好。
> 无需 approve-builds：v0.18.0 自带 `pnpm-workspace.yaml` 已 `allowBuilds`（node-pty/protobufjs）预放行；上游 CI 裸跑 `pnpm install --frozen-lockfile`（与服务器 remote-install.sh 同姿势），预期一次成功。上游 README 的 approve-builds 补救只针对「装进 profile 目录」的 registry 路径，源码安装不适用。

### 1.4 Commit（C1）

```sh
cd /Users/michaelyao/workspace/dsh
git add .gitmodules plugins/dsh-better-sidebar
git commit -m "feat: 引入 dsh-better-sidebar 源码 submodule（plugins/dsh-better-sidebar，pin tag v0.18.0）"
```

> submodule add 会把检出内容整体加入 index（不含其 `.git`）。

## 4. Step 2 —— 挂载机制：外部单包仓豁免 + patches/*.yml 托管合并

> 全部改动在主仓 `scripts/` + 新增 `patches/`、`scripts/merge-profile-patch.mjs`。**不动** `harness/`、`plugins/dsh-web/`、`plugins/dsh-better-sidebar/`。

### 4.1 新建 `scripts/merge-profile-patch.mjs`（内容已逐字节回归验证）

```sh
mkdir -p scripts   # 已存在则跳过
```

文件内容（直接创建）：

```js
#!/usr/bin/env node
// merge-profile-patch.mjs — 把 patches/*.yml 幂等合并进 profile 的 cordis.patch.yml（用户 patch 层）
// 用法: node scripts/merge-profile-patch.mjs <profile-dir> [patches-dir]
// 协议:
//   1. 目标文件的 managed 区由成对标记注释界定，标记间内容完全由本脚本按 patches/*.yml
//      （文件名序）重写；标记之外的内容（用户手工条目）原样保留在其上方。
//   2. 模板形态的孤立 `[]` 占位行被移除；输出顶层恒为合法 YAML 数组（无条目时以 [] 收尾）。
//   3. 幂等：重复执行输出逐字节不变。
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const [profileDir, patchesDirArg] = process.argv.slice(2)
if (!profileDir) { console.error('用法: merge-profile-patch.mjs <profile-dir> [patches-dir]'); process.exit(1) }
const patchesDir = patchesDirArg ?? join(dirname(fileURLToPath(import.meta.url)), '..', 'patches')
const target = join(profileDir, 'cordis.patch.yml')

const BEGIN = '# >>> managed by merge-profile-patch.mjs: patches/*.yml 合并区（幂等重写，勿手改）>>>'
const END = '# <<< end managed <<<'
const DEFAULT_HEADER = '# 该 profile 的用户 patch 层（在每个 bundle 层之后应用）：顶层为 loader patch 条目\n# 数组（id 定位的 overrides、disables、insert 列表；允许 !!js）。\n'

// 1. patches/*.yml（文件名序）→ 合并体；每文件视为一个 loader patch 条目列表片段
let merged = []
if (existsSync(patchesDir)) {
  for (const f of readdirSync(patchesDir).filter(f => f.endsWith('.yml')).sort()) {
    const text = readFileSync(join(patchesDir, f), 'utf8')
    merged.push(`# --- from ${f} ---`, ...text.replace(/\s+$/, '').split('\n'), '')
  }
}
while (merged.length && merged[merged.length - 1] === '') merged.pop()

// 2. 读目标：标记前为用户区（保留），标记对之间整体替换
const oldText = existsSync(target) ? readFileSync(target, 'utf8') : ''
const oldLines = oldText.split('\n')
const beginIdx = oldLines.findIndex(l => l.trim() === BEGIN)
const userLines = oldLines.slice(0, beginIdx === -1 ? oldLines.length : beginIdx)
  .filter(l => !/^\[\s*\]$/.test(l.trim()))   // 剔除模板占位 [] 行
  .map(l => l.replace(/\s+$/, ''))
while (userLines.length && userLines[userLines.length - 1] === '') userLines.pop()

// 3. 组装：用户区 + managed 区
const out = []
if (userLines.length) out.push(...userLines, '')
if (merged.length) out.push(BEGIN, ...merged, END)
if (oldText === '' && !userLines.length) out.unshift(DEFAULT_HEADER)
// 顶层必须是合法 YAML 数组：没有任何条目时以 [] 收尾（注释不算条目）
if (!out.some(l => l.trim() !== '' && !l.trim().startsWith('#'))) out.push('[]')
writeFileSync(target, out.join('\n') + '\n')
console.log(`已合并 patches/*.yml → ${target}`)
```

### 4.2 新建 `patches/disable-web-ui-better-sidebar.yml`

```sh
mkdir -p patches
```

内容：

```yaml
# dsh-web-all 的 AUTO-GENERATED 外部行（web-ui-better-sidebar，name dsh-better-sidebar）会经
# 聚合包依赖带出 registry 版（0.18.0）；源码 submodule（bundle 行 id: better-sidebar）接管后
# 必须禁用该行，否则同一插件被两个 entry 加载。name 作 mismatch 防护：dsh-web 若改行会 warn。
- id: web-ui-better-sidebar
  name: dsh-better-sidebar
  disabled: true
```

### 4.3 修改 `scripts/link-plugins.sh`

**改动 a —— skip 豁免根目录独立候选**。把挂载循环（现约 155-170 行，从 `mkdir -p "$DSH_HOME/profiles"` 到 `done`）整段替换为：

```bash
mkdir -p "$DSH_HOME/profiles"
MOUNTED=0
SKIPPED=()
for c in "${CANDIDATES[@]}"; do
  name="$(node -p "require('$c/package.json').name")"
  # 跳过仅适用于「同仓 workspace 子包」：聚合包的 link: 会经其 node_modules 的
  # workspace 链接带出本地构建。根目录独立候选（外部单包仓，如 dsh-better-sidebar）
  # 即使被聚合包以 registry 依赖引用（dsh-web-all deps）也必须单独挂载源码版本。
  in_subdirs=
  for s in ${SUBDIRS[@]+"${SUBDIRS[@]}"}; do
    [ "$s" = "$c" ] && in_subdirs=1
  done
  if [ -n "$in_subdirs" ] && printf '%s\n' "$DEP_NAMES" | grep -qxF "$name"; then
    SKIPPED+=("$name")
    continue
  fi
  echo "==> link $name <- $c"
  dsh plugin --profile "$PROFILE" add "link:$c"
  MOUNTED=$((MOUNTED + 1))
done
```

**改动 b —— 挂载后合并 patches**。在替换段之后、`[ "${#SKIPPED[@]}" ...` 输出行之前插入：

```bash
# patches/*.yml（repo 内 versioned 的用户 patch 片段，如 disable web-ui-better-sidebar）
# 幂等合并进 profile 的 cordis.patch.yml：挂载结果与托管 patch 同时生效。
node "$ROOT/scripts/merge-profile-patch.mjs" "$DSH_HOME/profiles/$PROFILE"
```

**改动 c —— ensure 宿主 bundle**。在改动 b 之后插入（挂载循环已保证 profile 目录存在；幂等，缺失时才写）：

```bash
# 确保官方 web 宿主在 bundles 列表中（base 之后、插件之前）：profile dsh 是本仓
# 运行态 profile，宿主与 web 模板一致（@deepseek-ai/dsh-web-app），从安装回退链
# （$DSH_HOME/profiles/node_modules）解析，无需作为依赖安装。缺失宿主时组合树
# 没有 webserver，boot 完事件循环空转不绑 3080（集成手册 §1.9）。
node -e '
  const fs = require("fs"), p = process.argv[1] + "/package.json"
  const m = JSON.parse(fs.readFileSync(p, "utf8"))
  const b = m.dsh?.profile?.bundles ?? []
  if (!b.includes("@deepseek-ai/dsh-web-app")) {
    b.splice(b.indexOf("@deepseek-ai/dsh-base") + 1, 0, "@deepseek-ai/dsh-web-app")
    fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n")
    console.log("已确保宿主 bundle @deepseek-ai/dsh-web-app 在 profile bundles（base 之后）")
  }
' "$DSH_HOME/profiles/$PROFILE"
```

### 4.4 修改 `deploy/remote-install.sh`（**延后**——用户决定：本机验证通过后再改）

- 挂载循环（现约 273-285 行，`mkdir -p "$DSH_HOME/profiles"` 起）整段替换为与 4.3-a 相同的代码（`SUBDIRS` 数组在 remote-install.sh 中同样存在，`${SUBDIRS[@]+...}` 防护兼容服务器 bash 4/5）。
- 在替换段后、`[ "${#SKIPPED[@]}" ...` 输出行前插入与 4.3-b、4.3-c 相同的代码（`$ROOT/scripts/merge-profile-patch.mjs` 随 rsync 同步到服务器，路径一致；ensure 步骤用 `$DSH_HOME/profiles/$PROFILE`，服务器上同路径）。
- **状态：已完成（C6，与 link-plugins.sh 同机制，shellcheck 通过）。**

### 4.5 Commit（C2，本次不含 remote-install.sh）

```sh
cd /Users/michaelyao/workspace/dsh
git add scripts/link-plugins.sh scripts/merge-profile-patch.mjs patches/
git commit -m "feat(scripts): 挂载豁免根目录外部单包仓 + ensure web 宿主 bundle + patches/*.yml 托管合并进 profile patch 层"
```

## 5. Step 3 —— 挂载 + dump 验证（本地，boot-free）

> `.dsh/` 是 gitignored 运行态；当前 dsh profile 的 cordis.patch.yml 已是 disable 生效的托管态（写作时预合并），本节重跑验证幂等。

### 3.1 挂载

```sh
cd /Users/michaelyao/workspace/dsh
bash scripts/link-plugins.sh
```

预期输出关键行：

- `==> link dsh-better-sidebar <- /Users/michaelyao/workspace/dsh/plugins/dsh-better-sidebar`（**不再**出现在跳过名单）
- 跳过名单仍为 16 个家族成员（数量不变）
- （首次）`已确保宿主 bundle @deepseek-ai/dsh-web-app 在 profile bundles（base 之后）`（幂等：已存在则无此行）
- `已合并 patches/*.yml → .../profiles/dsh/cordis.patch.yml`
- `完成: 已挂载 3 个 bundle 到 profile dsh`

### 3.2 检查 profile 落盘

```sh
node -p "JSON.stringify(require('/Users/michaelyao/workspace/dsh/.dsh/profiles/dsh/package.json'),null,1)" | grep -A8 '"bundles"'
```

预期 bundles = `["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","@linxin666/dsh-client-ui-session-id","@linxin666/dsh-web-all","dsh-better-sidebar"]`；dependencies 含 `"dsh-better-sidebar": "link:/Users/michaelyao/workspace/dsh/plugins/dsh-better-sidebar"`（宿主 `@deepseek-ai/dsh-web-app` **不在** dependencies——它从安装回退链解析，不是依赖安装）。

### 3.3 dump 组合树验证

```sh
cd /Users/michaelyao/workspace/dsh/harness
DSH_HOME=/Users/michaelyao/workspace/dsh/.dsh COREPACK_DEFAULT_TO_LATEST=0 CI=true \
  pnpm dsh --profile dsh --dump-config > /tmp/dump-final.txt 2>&1; echo "exit=$?"
grep -n "^# ==" /tmp/dump-final.txt        # 预期 5 个 section：base / web-app / session-id / web-all / dsh-better-sidebar（web-app 层还会生成多行 `base, patched by web-app` 标题，属正常）
grep -n -A3 "id: web-ui-better-sidebar" /tmp/dump-final.txt   # 预期含 disabled: true
grep -n -A3 "id: better-sidebar" /tmp/dump-final.txt          # 源行（guard 表达式原样，boot 时才求值）
grep -i "warn\|not found" /tmp/dump-final.txt || echo "无 warn ✓"
```

> 注意 shell 续行：以上命令逐条执行，第二条起不需要 `cd`。

### 3.4 幂等回归

```sh
bash scripts/link-plugins.sh >/dev/null && \
  git diff --no-index <(cat .dsh/profiles/dsh/cordis.patch.yml) /dev/null >/dev/null 2>&1; \
  cp .dsh/profiles/dsh/cordis.patch.yml /tmp/p1 && bash scripts/link-plugins.sh >/dev/null && \
  diff /tmp/p1 .dsh/profiles/dsh/cordis.patch.yml && echo "幂等 ✓"
```

## 6. Step 4 —— 启动层统一 --profile dsh + 文档/CI 修正

改动点清单（行号为写作时实测）：

| 文件:行                                                             | 现值                                | 改为                                                                                                                                                           |
| ------------------------------------------------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Makefile:16`                                                     | `pnpm dsh web --no-open`          | `pnpm dsh --profile dsh --no-open`（dev recipe 注释补一句：`dsh web` 别名 boot 官方模板 web profile，挂载目标是 dsh，故显式 `--profile dsh`）            |
| `deploy/dsh.service:20`                                           | `... dsh web --no-open`           | `... dsh --profile dsh --no-open`                                                                                                                            |
| `.github/workflows/verify.yaml:49`                                | `pnpm dsh web --no-open`          | `pnpm dsh --profile dsh --no-open`                                                                                                                           |
| `.github/workflows/release.yaml:30`                               | 同上                                | 同上                                                                                                                                                           |
| `docs/deploy.md:61`                                               | ExecStart 描述`dsh web --no-open` | `dsh --profile dsh --no-open`                                                                                                                                |
| `docs/deploy.md:63-73`                                            | 运行形态节                          | 补一段「profile 显式化」：`dsh web` 是 harness 别名（= `--profile web` 官方模板，auto-init 且非挂载目标）；统一后显式 `--profile dsh` 使挂载与 boot 一致 |
| `docs/superpowers/specs/2026-09-08-dsh-superproject-design.md:74` | `pnpm dsh web` 运行               | `pnpm dsh --profile dsh`（spec 修订待你审阅，见 §8）                                                                                                        |
| `AGENTS.md:9`                                                     | 稳定分支行                          | 追加`；dsh-better-sidebar → 正式 tag \`v0.18.0\`（tag pin，校验见下方代码块）`                                                                              |
| `README.md:30-31`                                                 | 结构表 plugins 行                   | plugins 行更新 + 新增`dsh-better-sidebar` 行（pin tag `v0.18.0`）                                                                                          |
| `.github/workflows/verify.yaml:23-31`                             | pin 检查 2 对（分支比对）           | 分支对保留；新增独立 tag 校验 step（代码块见下）                                                                                                               |
| `scripts/release.sh:13-36`                                        | check_pin 分支比对                  | 新增`check_pin_tag` 函数 + 调用（代码块见下）                                                                                                                |
| `scripts/deploy-remote.sh:15`                                     | 注释 "dsh web"                      | （可选）措辞对齐                                                                                                                                               |

**verify.yaml 新增 step**（紧跟现有「Check submodule pins」step 之后，同一 job）：

```yaml
      # 1b. tag-pin 一致性（dsh-better-sidebar pin 正式发布 tag；tag 存在于远端即已发布，
      #     与分支比对的「拦截本地未推送 commit」同语义）
      - name: Check tag-pinned submodules
        run: |
          set -e
          for pair in "plugins/dsh-better-sidebar v0.18.0"; do
            set -- $pair
            git -C "$1" fetch origin "refs/tags/$2"
            [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse "$2")" ] \
              || { echo "$1 pin 与 tag $2 不一致（可能未推送）"; exit 1; }
          done
```

**release.sh 新增函数 + 调用**（紧跟现有 `check_pin plugins/dsh-web main` 之后）：

```bash
# tag-pin 校验：submodule pin 与远端正式 tag 一致（dsh-better-sidebar 等按 tag 发布的插件仓）
check_pin_tag() { # $1=path  $2=tag
  local sub="$1" tag="$2"
  local pinned remote
  if ! pinned=$(git -C "$sub" rev-parse HEAD 2>/dev/null); then
    echo "错误: 无法读取 ${sub} 的 pin（submodule 未初始化或目录缺失？）。请先运行 make setup 初始化 submodule。" >&2
    exit 1
  fi
  if ! git -C "$sub" fetch origin "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "错误: ${sub} fetch origin tag ${tag} 失败，无法核对 pin。请检查网络后手动执行: git -C ${sub} fetch origin refs/tags/${tag}" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "${tag}"); then
    echo "错误: ${sub} 缺少 tag ${tag}，无法核对 pin。请确认远端存在该 tag 并手动执行: git -C ${sub} fetch origin refs/tags/${tag}" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 tag ${tag}($remote) 不一致" >&2
    echo "如已发布，请显式更新 pin 再发布" >&2
    exit 1
  fi
}
check_pin_tag plugins/dsh-better-sidebar v0.18.0
```

### Commit 切分（C3 / C3b / C4）

```sh
git add Makefile deploy/dsh.service .github/workflows/verify.yaml .github/workflows/release.yaml
git commit -m "fix: 启动统一 --profile dsh（make dev / deploy 模板 / CI 冒烟对齐挂载目标）"

git add scripts/release.sh
git commit -m "ci: pin 校验支持 tag 模式（dsh-better-sidebar → v0.18.0；verify 同批已并入上一提交）"

git add AGENTS.md README.md docs/deploy.md scripts/deploy-remote.sh
git commit -m "docs: 记录 dsh-better-sidebar 与 --profile dsh 运行形态"
```

> verify.yaml 的 tag step 与启动行同文件，并入 C3；release.sh 单独成 C3b。

> `docs/superpowers/plans/2026-09-09-dsh-better-sidebar-integration.md`（本手册）是否入库由你决定——建议并入 C4 或在执行完成后单独留档。

## 7. Step 5 —— make dev 端到端验证

```sh
cd /Users/michaelyao/workspace/dsh
make dev
```

逐项核对：

1. `link-plugins` 前置输出同 §5.3.1 预期（含 dsh-better-sidebar、merge 提示）。
2. UI 起来后：**session-id / market / task-board / better-sidebar 同时出现**——若 sidebar 出现两份或重复入口，说明 disable 未生效（回到 §5.3.3 检查 dump）。
3. **硬刷新浏览器**（Cmd/Ctrl+Shift+R，client 改动缓存）。
4. 侧边栏功能抽查（better-sidebar 工作台）。
5. **接管证明（源码 vs registry）**：客户端入口是 `lib/` 构建产物（package.json exports → `lib/client.js`），**改 src 需重建才到浏览器**。三种姿势任选：a) submodule 里 `pnpm watch` 常驻（tsdown 持续重建），改 `src/client/*` 后硬刷新看改动；b) 改 src 后单次 `pnpm build` 再硬刷新；c) 零构建——直接往 `lib/client.js` 塞一行 `console.log('SOURCE-OK')`，硬刷新看浏览器控制台（lib 是 gitignore 产物，验证后 `pnpm build` 重新生成即复原）。看到改动即证明：UI 加载的文件来自 `plugins/dsh-better-sidebar`（link 挂载目录），而非 web-all node_modules 里的 registry 0.18.0 拷贝（物理上另一个目录，不可能受我们的改动影响）。host 侧改动（lib/index.js 一类）则需重启服务。

确认无误后即完成本地集成。远程部署在你有真实服务器时走 `make deploy`（remote-install.sh 已含同款机制；服务器侧 dsh-better-sidebar `pnpm install --frozen-lockfile` + build 由现有插件循环自动覆盖——插件仓 lockfile 已提交，满足 frozen 前提）。

## 8. spec 修订（待你审阅后执行，独立 commit）

`docs/superpowers/specs/2026-09-08-dsh-superproject-design.md` 需要动 3 处（对应事实变化）：

1. **§4/启动形态（74 行附近）**：`pnpm dsh web` → `pnpm dsh --profile dsh`；补充「`dsh web` 是 harness 的 `--profile web` 别名（官方模板，非挂载目标），超级仓库统一显式 boot 挂载目标 profile `dsh`」。
2. **结构段（50-53 行附近）**：plugins 树加 `dsh-better-sidebar` 子模块行。
3. **挂载机制（79 行附近）**：link-plugins 描述补两条语义——根目录外部单包仓候选豁免「被聚合包依赖即跳过」；`patches/*.yml` 由脚本幂等托管合并进 profile patch 层（含 disable 示例与 merge 脚本指针）。
4. **宿主 bundle（新增）**：profile dsh 的 bundles 以 base + 官方 web 宿主 `@deepseek-ai/dsh-web-app` 开头（web 模板同款；link-plugins/remote-install 幂等 ensure，从安装回退链解析、不作依赖安装）。
5. **tag pin（新增）**：外部单包插件仓允许 pin 正式发布 tag（dsh-better-sidebar → `v0.18.0`），替代「稳定分支 HEAD」；`verify.yaml` / `release.sh` 的 pin 校验增加 tag 比对模式（远端存在且指向 pin 的 tag = 已发布，与分支比对同语义）。

## 9. 风险与兜底

| 风险                                       | 症状                            | 处置                                                                                              |
| ------------------------------------------ | ------------------------------- | ------------------------------------------------------------------------------------------------- |
| 宿主 bundle 缺失                           | boot 后卡住不绑 3080            | 执行 §0.2b 或重跑`bash scripts/link-plugins.sh`（ensure 步骤兜底）                             |
| dump 出现`warn: patch: ...`              | disable 或 guard 行行为不符     | 检查 patches/ 内容与目标行 id/name 是否与 dump 一致（web-all bump 改行会触发 name mismatch warn） |
| link-plugins 跳过名单含 dsh-better-sidebar | §5.3.1 预期不符                | 确认 4.3-a 替换段生效（`in_subdirs` 检查）                                                      |
| 重复 sidebar / 双实例行为                  | Step 5 UI 异常                  | disable 未生效；回到 §5.3.3 验证`disabled: true` 存在                                          |
| cordis.patch.yml 被手改破坏                | dump 报 YAML 错                 | 重跑`bash scripts/link-plugins.sh`（幂等重写）；用户条目保留在 managed 标记上方                 |
| `.dsh/profiles/web` 误 boot              | 官方 UI + registry sidebar 出现 | 已弃用；建议执行 §0.3 删除                                                                       |

## 10. Commit 汇总（全部无 AI 署名）

| #            | Message 建议                                                                                                     |
| ------------ | ---------------------------------------------------------------------------------------------------------------- |
| C1           | `feat: 引入 dsh-better-sidebar 源码 submodule（plugins/dsh-better-sidebar，pin tag v0.18.0）`                  |
| C2           | `feat(scripts): 挂载豁免根目录外部单包仓 + ensure web 宿主 bundle + patches/*.yml 托管合并进 profile patch 层` |
| C3           | `fix: 启动统一 --profile dsh + verify tag-pin 校验（make dev / deploy 模板 / CI 冒烟对齐挂载目标）`            |
| C3b          | `ci: pin 校验支持 tag 模式（dsh-better-sidebar → v0.18.0）`                                                   |
| C4           | `docs: 记录 dsh-better-sidebar 与 --profile dsh 运行形态`                                                      |
| C5（待审）   | `docs(spec): 修订启动 profile、tag pin 与外部插件挂载语义`                                                     |
| C6（部署前） | `feat(deploy): remote-install.sh 同步豁免/ensure/merge 三处（本机验证通过后执行）`                             |
| C7         | `docs(plans): 记录 better-sidebar 集成手册（boot 宿主与 tag pin 语义）`                                        |
