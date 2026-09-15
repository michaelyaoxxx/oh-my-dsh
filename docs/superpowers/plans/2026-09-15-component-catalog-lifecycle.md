# 组件目录生命周期模型 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `config/components.json` 的每个字段有**可验证的语义**，并让 local setup / remote build / CI / release / notices **消费同一份解析与动作计划**。

**Architecture:** 把「字段语义」从散落在各脚本的隐式假设，收敛为 `check-components.mjs` 里的一份 schema 级元数据；把「准备动作」从两处逐行同构的循环，收敛为一个共用 executor，环境差异用 policy 参数表达；把校验拆成 catalog（无需子仓）与 materialized（需子仓）两阶段，门禁路径用 `--require-materialized` 拒绝任何 skip。

**Tech Stack:** Node ESM（零依赖，须在 `make setup` 之前可运行）、Bash（`scripts/*.sh`，shellcheck `-S style` 全绿）。

**Spec:** [docs/cicd/adr/0005-component-catalog-lifecycle.md](../../cicd/adr/0005-component-catalog-lifecycle.md)（决策）、[config/README.md](../../../config/README.md)（字段字典 + 实现状态表）

## Global Constraints

以下约束对**每个任务**都成立，不再逐条重复：

- **不修改 submodule 内容**（`harness/`、`plugins/*`）。需要适配时走 fork + 分支 pin。
- **commit message 不加任何 AI 署名**；用 `git commit -F <文件>` 或 `<<'EOF'` heredoc（**不要**用双引号包裹含反引号的信息——反引号会被 shell 执行，本仓已踩两次）。
- **提交按逻辑单元切分**（scripts / config / docs 分开）。
- **`shellcheck -S style scripts/*.sh deploy/remote-install.sh` 必须全绿**（CI 固定 0.11.0）。
- **`check-components.mjs` 必须在 `make setup` 之前可运行**——不得引入对 `harness/node_modules` 或已初始化 submodule 的硬依赖。需要子仓的检查必须能"跳过并计数"，由 `--require-materialized` 决定跳过是否致命。
- **禁止 fail-open**：配置错误必须 fail closed。删除一切 `2>/dev/null || true` 形式的静默降级。
- **每完成一个任务跑 `make check`**（它调用 `scripts/check-all.sh`，是本地自检的唯一清单）。
- **报告必须区分已验证 / 未验证**，附实际命令与输出。禁止把推断写成已验证。
- **`.github/workflows/` 默认不改**；只允许"把新校验挂到门禁上"（逻辑写在 `scripts/`）。

## 文件结构

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `scripts/check-components.mjs` | catalog 的**校验器 + 查询器**。持有：schema 版本、字段分类元数据、受控词表、两阶段校验、`--list` / `--plan` | 大改 |
| `scripts/prepare-executor.sh` | **准备动作的唯一实现**。被 setup / remote-install source；动作决策树在此，环境策略由调用方以钩子注入 | 新建 |
| `scripts/probe-catalog.sh` | catalog 校验的**合成夹具测试**。仿 `probe-license-gate.sh` 模式（mktemp 内造 fixture + 断言） | 新建 |
| `config/components.json` | 组件登记。本次：schema v2、`buildMode`→`prepareMode`、删 `packageManager`、修两处存量错误 | 大改 |
| `scripts/setup.sh` | 本地：消费 `--plan`，调 executor，执行前跑 materialized 校验 | 改 |
| `deploy/remote-install.sh` | 服务器：同上（install 策略为 frozen） | 改 |
| `scripts/link-plugins.sh` | 删 fail-open 的 `\|\| true` | 改 |
| `scripts/gen-notices.mjs` | 复用 validated loader；declared 字段加免责标注 | 改 |
| `scripts/probe-license-gate.sh` | 合成 fixture 需跟上新 schema | 改 |
| `config/README.md` | 「实现状态」表逐条更新为已实现 | 改 |
| `THIRD-PARTY-NOTICES.md` | 重新生成 | 改 |

**任务依赖顺序**：T1（夹具）→ T2（schema v2）→ T3（分类）→ T4（catalog 不变量）→ T5（`--plan`）→ T6（materialized）→ T7（修 fail-open）→ T8（executor + setup）→ T9（remote-install + link-plugins）→ T10（gen-notices）→ T11（收尾与文档）→ T12（双平台验证）。

---

### Task 1: 建 catalog 校验的合成夹具与基线

**为什么先做这个**：后面每个任务都要断言"校验器会拒绝 X"。没有夹具就只能靠手工试，而手工试过的东西不会留在仓里。本仓已有这个模式的先例：`scripts/probe-license-gate.sh`。

**Files:**
- Create: `scripts/probe-catalog.sh`
- Modify: `scripts/check-all.sh`（把新探针挂进离线组）

**Interfaces:**
- Produces: `scripts/probe-catalog.sh`，接受 `--strict` 时"与预期不符即 exit 1"；默认只打印矩阵、恒 exit 0。后续任务往里加用例。

- [ ] **Step 1: 写夹具骨架与基线断言**

创建 `scripts/probe-catalog.sh`：

```bash
#!/usr/bin/env bash
# probe-catalog.sh — 组件目录校验的**合成夹具测试**
#
# 目的：check-components.mjs 的每条校验规则，都要有一条**会失败的合成样本**证明它真的会拒。
# 只读代码推断"它应该会拒"是不够的——本仓在许可证门禁上正是靠这个模式才发现
# "以为拦得住"与"真的拦得住"是两回事（见 probe-license-gate.sh）。
#
# 全程在 mktemp 出来的目录内操作，退出即清理，**不碰本仓任何文件**。
#
# 用法：bash scripts/probe-catalog.sh [--strict]
# 退出码：默认恒 0；--strict 下有用例不符则 1

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/config"
cp "$ROOT/scripts/check-components.mjs" "$TMP/scripts/"

FAILED=0

# 造一份最小 catalog。$1=components 数组的 JSON 文本
write_catalog() {
  cat > "$TMP/config/components.json" <<EOF
{
  "version": $2,
  "description": "fixture",
  "components": $1
}
EOF
}

# 造与 catalog 对应的 .gitmodules，让双向集合校验通过。
# $1=以空格分隔的 path 列表
write_gitmodules() {
  : > "$TMP/.gitmodules"
  for p in $1; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/%s.git\n' "$p" "$p" "$p" >> "$TMP/.gitmodules"
  done
}

# 一个字段齐全、值合法的组件条目。
# $1=name  $2=path  $3=overrides（JSON **对象**文本，可选；同名键**覆盖**而非追加）
#
# 为什么用合并而不是把片段拼到对象尾部：拼接会产生**重复键**（如两个 runtimeScope），
# JSON.parse 取最后一个——"能跑"，但读者无法判断哪个生效，换成严格解析器还会静默改变
# 语义。fixture 自己也该遵守「一个字段一个值」，否则它就在示范本计划要治的病。
good_component() {
  node -e '
    const base = {
      name: process.argv[1], path: process.argv[2], sourceAuthority: "github",
      pinPolicy: "tag", pinRef: "v1.0.0",
      ciScope: ["build"], releaseScope: ["bundle"], runtimeScope: "required",
      platforms: ["linux-x86_64"], prepareMode: "source-build",
      testProfile: "vitest", stateSchema: "none", license: "MIT",
    }
    const over = process.argv[3] ? JSON.parse(process.argv[3]) : {}
    process.stdout.write(JSON.stringify({ ...base, ...over }))
  ' "$1" "$2" "${3:-}"
}

run_case() { # $1=场景名  $2=期望(CAUGHT/GAP)  $3=构造函数名（调用前已设好 fixture）
  local name="$1" expect="$2" out rc got mark
  out="$(cd "$TMP" && node scripts/check-components.mjs 2>&1)"; rc=$?
  got="GAP"; [ "$rc" -ne 0 ] && got="CAUGHT"
  mark="ok"; [ "$got" != "$expect" ] && { mark="!! 与预期不符"; FAILED=$((FAILED + 1)); }
  printf '  %-44s 期望=%-6s 实测=%-6s %s\n' "$name" "$expect" "$got" "$mark"
  [ "$got" = "CAUGHT" ] && printf '       理由: %s\n' "$(printf '%s' "$out" | grep -m1 '✗' | cut -c1-80)"
}

echo "组件目录校验 覆盖夹具"
echo "  scratch: ${TMP}（退出即清理）"

echo
echo "== 0. 夹具自检（必须通过，否则下面全是假阳性）=="
write_catalog "[$(good_component ok plugins/ok)]" 1
write_gitmodules "plugins/ok"
if (cd "$TMP" && node scripts/check-components.mjs >/dev/null 2>&1); then
  printf '  %-44s %s\n' "合法的 v1 catalog 应通过" "ok"
else
  printf '  %-44s %s\n' "合法的 v1 catalog 应通过" "!! 夹具坏了——以下结果不可信"
  FAILED=$((FAILED + 1))
fi

echo
if [ "$STRICT" = 1 ] && [ "$FAILED" -ne 0 ]; then
  echo "✗ --strict：${FAILED} 项与预期不符。"
  exit 1
fi
exit 0
```

- [ ] **Step 2: 跑一次，确认夹具自检通过**

Run: `bash scripts/probe-catalog.sh`
Expected: `合法的 v1 catalog 应通过   ok`

若失败，说明 `good_component` 的字段与 `REQUIRED_FIELDS` 不匹配——**改夹具，不要改校验器**。

- [ ] **Step 3: 把探针挂进离线组**

修改 `scripts/check-all.sh`，在 `check_gate_regr` 之后加一个函数并在调用序列里加上它：

```bash
check_gate_regr()  { run "许可证门禁回归（覆盖边界未被改弱）"                               bash scripts/probe-license-gate.sh --strict; }
check_catalog()    { run "组件目录校验回归（每条规则都有会失败的样本）"                     bash scripts/probe-catalog.sh --strict; }
```

调用序列改为：

```bash
check_components
check_licenses
check_notices
check_gate_regr
check_catalog
```

并在 `--list` 的输出里加一行：

```bash
echo "  · [离线] 组件目录 / 组件许可证文件 / 第三方声明 / 许可证门禁回归 / 目录校验回归"
```

- [ ] **Step 4: 验证 `make check` 仍全绿**

Run: `make check`
Expected: `全部通过（7 项）。`（原 6 项 + 新增 1 项）

- [ ] **Step 5: 提交**

```bash
git add scripts/probe-catalog.sh scripts/check-all.sh
git commit -F - <<'EOF'
test(catalog): 建组件目录校验的合成夹具（仿许可证门禁探针）

后面每个任务都要断言「校验器会拒绝 X」。没有夹具就只能手工试，
而手工试过的东西不会留在仓里——本仓在许可证门禁上已经用这个模式
发现过「以为拦得住」与「真的拦得住」是两回事。

本任务只建骨架与基线（合法 v1 catalog 应通过），后续任务往里加用例。
已挂进 check-all.sh 的离线组，`make check` 从此会跑它。
EOF
```

---

### Task 2: schema 升到 v2 —— `prepareMode` 四值、删 `packageManager`、修两处存量

**Files:**
- Modify: `config/components.json`（全量）
- Modify: `scripts/check-components.mjs:28-54`（`ENUM`、`REQUIRED_FIELDS`）、`:58-71`（`loadCatalog` 校验 version）
- Modify: `scripts/probe-catalog.sh`（fixture 跟上、加用例）
- Modify: `scripts/probe-license-gate.sh`（fixture 用的字段名）

**Interfaces:**
- Produces: catalog schema v2。字段名 `prepareMode`（取值 `source-build` / `tracked-prebuilt` / `install-only` / `none`）；`packageManager` 不再存在；顶层 `version` 必须为 `2`。
- Consumes: Task 1 的 `scripts/probe-catalog.sh`。

- [ ] **Step 1: 加失败用例（先证明当前会漏）**

在 `scripts/probe-catalog.sh` 的自检之后追加：

```bash
echo
echo "== A. schema 版本 =="
write_catalog "[$(good_component ok plugins/ok)]" 1
write_gitmodules "plugins/ok"
run_case "A1 version=1（本仓只接受 2）"     CAUGHT
write_catalog "[$(good_component ok plugins/ok)]" 3
run_case "A2 version=3（未知版本拒绝）"     CAUGHT
write_catalog "[$(good_component ok plugins/ok)]" 2
run_case "A3 version=2（当前版本接受）"     GAP
```

- [ ] **Step 2: 跑，确认 A1/A2 失败（当前接受任何版本）**

Run: `bash scripts/probe-catalog.sh`
Expected: `A1` 与 `A2` 显示 `!! 与预期不符`（实测 GAP，期望 CAUGHT）——**这正是要修的**。

- [ ] **Step 3: 在 `loadCatalog` 里校验版本**

`scripts/check-components.mjs`，把 `loadCatalog` 改为：

```javascript
const SCHEMA_VERSION = 2

function loadCatalog() {
  let raw
  try {
    raw = JSON.parse(readFileSync(CATALOG, 'utf8'))
  } catch (e) {
    console.error(`✗ 无法解析 ${CATALOG}：${e.message}`)
    process.exit(1)
  }
  // 未知版本**直接拒绝**，不做尽力兼容——读一个自己不认识的结构，只会做出错误决定。
  // 迁移规则见 config/README.md 的「版本与迁移」。
  if (raw.version !== SCHEMA_VERSION) {
    console.error(
      `✗ catalog schema 版本不符：文件是 ${JSON.stringify(raw.version)}，本工具要求 ${SCHEMA_VERSION}。` +
        `\n  迁移规则见 config/README.md。不要改回旧版本号来绕过。`,
    )
    process.exit(1)
  }
  if (!Array.isArray(raw.components)) {
    console.error('✗ config/components.json 缺少 components 数组')
    process.exit(1)
  }
  return raw
}
```

- [ ] **Step 4: 跑，确认 A1/A2/A3 全过**

Run: `bash scripts/probe-catalog.sh`
Expected: A1/A2 = CAUGHT，A3 = GAP，且无 `!! 与预期不符`。

**此时 `make check` 会红**（真 catalog 还是 v1）——下一步修。

- [ ] **Step 5: 把真 catalog 改成 v2**

对 `config/components.json` 做四处修改：

1. 顶层 `"version": 1` → `"version": 2`。
2. 每个组件： `"buildMode"` → `"prepareMode"`，取值按下表换算（**注意两处不是机械换算，是修正存量错误**）：

   | 组件 | 原 `buildMode` | 新 `prepareMode` | 依据 |
   | --- | --- | --- | --- |
   | `harness` | `source-build` | `source-build` | 有 build 脚本 |
   | `dsh-web` | `source-build` | `source-build` | workspace 根，有 build 脚本 |
   | `dsh-better-sidebar` | `source-build` | `source-build` | 入口 `lib/index.js` **未**被跟踪 |
   | `modlens` | `source-build` | `source-build` | 无 `main`，有 build 脚本 |
   | `dsh-automation` | `prebuilt-verified` | `tracked-prebuilt` | 入口 `./lib/index.js` **已**被跟踪 |
   | `dsh-market` | `source-build` | `source-build` | 入口未被跟踪 |
   | **`dsh-agent-teams`** | `prebuilt-verified` | **`source-build`** | ⚠️ **存量修正**：其 `lib/` 无任何 Git 跟踪文件，`prebuilt` 无物可验 |
   | **`dsh-at-file`** | `source-build` | **`tracked-prebuilt`** | ⚠️ **存量修正**：`main`/`types`/`client`/`invariant` 入口均已跟踪，构建反而会弄脏 submodule |
   | `modsearch` | `source-build` | `source-build` | 无 `main`，有 build 脚本 |
   | `dsh-tui` | `no-build` | `none` | metadata-only |

3. 删除**所有** `"packageManager": "pnpm",` 行（10 处）。事实源是各子仓自己的 `package.json`。
4. `dsh-tui` 的 `"runtimeScope": "excluded"` 保持不变（与新的 `prepareMode: none` 一致）。

**同时**：`scripts/probe-catalog.sh` 的**夹具自检**里那一行 `write_catalog "[$(good_component ok plugins/ok)]" 1`
必须改为 `... 2`。它原先用 v1 是对的（T1 时点），但本任务加上版本校验后，**自检自身会失败**，
让下面 Step 4 的"A1/A2/A3 全过"变成一个红灯现场。

- [ ] **Step 6: 同步校验器的词表与必需字段**

`scripts/check-components.mjs`，把 `ENUM.buildMode` 一行替换为：

```javascript
  prepareMode: ['source-build', 'tracked-prebuilt', 'install-only', 'none'],
```

并把 `REQUIRED_FIELDS` 里的 `'buildMode'` 改为 `'prepareMode'`，删除 `'packageManager'`：

```javascript
const REQUIRED_FIELDS = [
  'name', 'path', 'sourceAuthority', 'pinPolicy', 'pinRef',
  'ciScope', 'releaseScope', 'runtimeScope', 'platforms', 'prepareMode',
  'testProfile',
  // license 同样是必需字段：缺失会在生成的声明文件里留下空洞，而那是合规文档。
  'license',
]
```

- [ ] **Step 7: 同步两个 fixture 的字段名**

`scripts/probe-catalog.sh` 的 `good_component()` **当前用的是 v1 字段名**（`buildMode` + `packageManager`）——
这是 T1 时点的正确状态，T1 的夹具自检依赖它。本任务把它改成 v2（见下），**不要以为它已经是对的**。

`scripts/probe-license-gate.sh` 的 `stage()` 里，把 `"buildMode": "source-build"` 改为 `"prepareMode": "source-build"`，并删掉 `"packageManager": "pnpm",`，把 `cat > ... <<EOF` 里的 `"version": 1` 改为 `"version": 2`。

**`scripts/probe-catalog.sh` 也要同步改**（T1 用 v1 字段名是对的，因为 T1 时点校验器还是 v1；本任务把校验器升到 v2，夹具必须跟上，否则它会恒红）：

- `good_component()` 的 `buildMode: "source-build"` → `prepareMode: "source-build"`
- 删掉 `good_component()` 里的 `packageManager: "pnpm",`
- 夹具自检那行 `write_catalog "[$(good_component ok plugins/ok)]" 1` 的版本参数 `1` → `2`
- `0b` 能力自检那行同样 `1` → `2`
- 删掉 `good_component()` 上方那段「这里要的是 buildMode / packageManager，**不是** prepareMode」的过渡注释——它已过期

- [ ] **Step 8: 跑全部校验**

Run: `bash scripts/probe-catalog.sh && bash scripts/probe-license-gate.sh --strict && node scripts/check-components.mjs`
Expected: 三份都通过；最后一条输出 `✓ 组件目录校验通过：<N> 个组件，与 .gitmodules 双向一致`
（`<N>` 是**实际**组件数——目前 11。**别把数字抄进断言**：组件集合会变，
计划里写死的数字正是 AGENTS.md 说的"会漂移的事实不在这里复制"。）

- [ ] **Step 9: 重新生成 notices 并跑 make check**

```bash
node scripts/gen-notices.mjs
make check
```
Expected: `make check` 全部通过。

- [ ] **Step 10: 提交**

```bash
git add config/components.json scripts/check-components.mjs scripts/probe-catalog.sh scripts/probe-license-gate.sh THIRD-PARTY-NOTICES.md
git commit -F - <<'EOF'
feat(catalog)!: schema v2 —— prepareMode 四值、删 packageManager、修两处存量错误

按 ADR-0005。schema 版本 1 → 2，**未知版本直接拒绝**（不做尽力兼容）。

字段变更：
  · buildMode → prepareMode，三值扩四值（补 install-only，消除
    「no-build 被迫等同于 excluded」的歧义）
  · 删除 packageManager —— 权威源是各子仓自己的 package.json，
    脚本读的一直是那一份，目录里这份只能漂移

**两处存量数据修正**（实测发现，声明与实际不符）：
  · dsh-agent-teams: prebuilt-verified → source-build
    其 lib/ 无任何 Git 跟踪文件，"prebuilt" 无物可验
  · dsh-at-file: source-build → tracked-prebuilt
    main/types/client/invariant 入口均已跟踪，构建反而会弄脏 submodule

这两处此前一直被 setup.sh 里那条内隐启发式（"main 被跟踪即跳过构建"）
默默纠正着——声明的字段从没被读过，所以错了也没人知道。启发式的删除在后续任务。
EOF
```

---

### Task 3: 字段三分类元数据与类别校验

**Files:**
- Modify: `scripts/check-components.mjs`（加 `FIELD_CLASS`、类别校验）
- Modify: `scripts/probe-catalog.sh`（加用例）

**Interfaces:**
- Produces: `FIELD_CLASS`（导出语义上可被 `gen-notices.mjs` 复用；本任务先只在 `check-components.mjs` 内定义并导出为具名导出）。分类取值：`operational` / `declared` / `derived`。

- [ ] **Step 1: 加失败用例**

在 `scripts/probe-catalog.sh` 的 A 组之后追加：

```bash
echo
echo "== B. 字段分类元数据 =="
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
run_case "B1 合法分类（基线，应通过）"      GAP
# 用一个未登记的字段名：它没有分类，说明有人加了字段却没登记分类
write_catalog "[$(good_component ok plugins/ok '{"untrackedField":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B2 出现未登记分类的字段"          CAUGHT
```

- [ ] **Step 2: 跑，确认 B2 失败**

Run: `bash scripts/probe-catalog.sh`
Expected: `B2` 显示 `!! 与预期不符`（实测 GAP）。

- [ ] **Step 3: 定义分类表并校验**

`scripts/check-components.mjs`，在 `ENUM` 之后加：

```javascript
// 字段分类：**schema 级元数据**，不是组件的属性。
//
// 为什么不给每个组件加 `status` 标记：同一个事实在每个组件里重复一遍，
// 就多一个漂移点——正是本 ADR 要治的病。（**不写具体条数**：组件集合会变。）
//
// 判据是「有没有**行为或门禁**消费者」，不是「有没有任何代码读它」：
// gen-notices.mjs 会读 releaseScope/sourceAuthority 去**渲染声明**，那是展示，不构成保证。
export const FIELD_CLASS = {
  // operational：影响执行、门禁或发布结果。改它必须同步消费者。
  path: 'operational',
  pinPolicy: 'operational',
  pinRef: 'operational',
  runtimeScope: 'operational',
  prepareMode: 'operational',
  license: 'operational',
  // declared：可被展示/生成器读取，但无行为执行、无真实性校验，**不构成工程保证**。
  name: 'declared',
  sourceAuthority: 'declared',
  ciScope: 'declared',
  releaseScope: 'declared',
  platforms: 'declared',
  testProfile: 'declared',
  stateSchema: 'declared',
  notes: 'declared',
}
```

在 `validate()` 的组件循环内、`REQUIRED_FIELDS` 检查之后加：

```javascript
    for (const f of Object.keys(c)) {
      if (!(f in FIELD_CLASS)) {
        fail(
          `${where} 出现未登记分类的字段 ${JSON.stringify(f)}。` +
            `新增字段必须在 FIELD_CLASS 里声明它是 operational 还是 declared（见 config/README.md）。`,
        )
      }
    }
```

- [ ] **Step 4: 跑，确认 B1/B2 全过**

Run: `bash scripts/probe-catalog.sh`
Expected: 无 `!! 与预期不符`。

- [ ] **Step 5: 跑 make check**

Run: `make check`
Expected: 全部通过（真 catalog 的字段都在分类表内）。

- [ ] **Step 6: 提交**

```bash
git add scripts/check-components.mjs scripts/probe-catalog.sh
git commit -F - <<'EOF'
feat(catalog): 字段三分类元数据 + 未登记字段即拒绝

按 ADR-0005。判据是「有没有**行为或门禁**消费者」，不是「有没有任何代码读它」——
gen-notices 渲染 releaseScope/sourceAuthority 属于展示，不构成保证。

分类表是 **schema 级元数据**，不给每个组件加 status 标记：同一事实重复 10 遍
就是 10 个漂移点，正是本 ADR 要治的病。

新增校验：出现未登记分类的字段即失败。防止有人加字段却不让任何人知道
它是保证还是仅声明——agent-teams 的 buildMode 就是这么错的。
EOF
```

---

### Task 4: catalog 阶段不变量

**Files:**
- Modify: `scripts/check-components.mjs`（`validate()` 加不变量）
- Modify: `scripts/probe-catalog.sh`（加用例）

**Interfaces:**
- Consumes: Task 3 的 `FIELD_CLASS`。
- Produces: `validateCatalog(catalog)` —— 不需要子仓的那部分校验（本任务把现有 `validate` 中不依赖子仓的部分抽成此函数，供 T5/T7 复用）。

- [ ] **Step 1: 加失败用例**

追加：

```bash
echo
echo "== C. catalog 阶段不变量 =="
write_catalog "[$(good_component c1 plugins/c1 '{"pinRef":"refs/tags/v1"}')]" 2
write_gitmodules "plugins/c1"
run_case "C1 tag pin 的 pinRef 带 refs/ 前缀"     CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"pinRef":""}')]" 2
write_gitmodules "plugins/c1"
run_case "C2 tag pin 的 pinRef 为空"              CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded"}')]" 2
write_gitmodules "plugins/c1"
run_case "C3 excluded 但 releaseScope 含 bundle"  CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded","releaseScope":["sbom"]}')]" 2
write_gitmodules "plugins/c1"
run_case "C4 excluded + 仅 sbom（应允许）"        GAP
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded","prepareMode":"source-build"}')]" 2
write_gitmodules "plugins/c1"
run_case "C5 excluded 但 prepareMode != none"     CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"required","prepareMode":"none"}')]" 2
write_gitmodules "plugins/c1"
run_case "C6 required 但 prepareMode = none"      CAUGHT
```

- [ ] **Step 2: 跑，确认 C1–C7 中除 C4 外全部失败**

Run: `bash scripts/probe-catalog.sh`
Expected: C1/C2/C3/C5/C6/C7 = `!! 与预期不符`；C4 = ok。

- [ ] **Step 3: 抽出 `validateCatalog` 并加不变量**

`scripts/check-components.mjs`：把 `validate()` 里**不依赖子仓**的部分抽为 `validateCatalog(catalog)`，并在组件循环内加：

```javascript
    // ── catalog 阶段不变量（只看目录即可判定）────────────────────────────────
    // pinRef 非空：空 ref 会让 check-pins.sh 拿一个空串去 fetch。
    if (!c.pinRef || String(c.pinRef).trim() === '') fail(`${where} 的 pinRef 为空`)
    if (c.pinPolicy === 'tag' && c.pinRef.startsWith('refs/')) fail(`${where} tag pin 的 pinRef 不应带 refs/ 前缀`)
    // excluded ⇒ releaseScope 不含 bundle。**不**要求 releaseScope 为空：
    // excluded 组件未来仍可能有独立制品/SBOM/provenance，过强的约束会挡住合理设计。
    if (c.runtimeScope === 'excluded' && Array.isArray(c.releaseScope) && c.releaseScope.includes('bundle')) {
      fail(`${where} 的 runtimeScope=excluded，但 releaseScope 含 bundle —— 不进运行时却进制品，自相矛盾`)
    }
    // runtimeScope 与 prepareMode 的正交约束（真值表见 config/README.md）
    if (c.runtimeScope === 'excluded' && c.prepareMode !== 'none') {
      fail(`${where} 的 runtimeScope=excluded，但 prepareMode=${c.prepareMode} —— 不属于运行时却要准备`)
    }
    if (c.runtimeScope === 'required' && c.prepareMode === 'none') {
      fail(`${where} 的 runtimeScope=required，但 prepareMode=none —— 属于运行时却不准备`)
    }
    // ── 类型不变量：这三个字段必须是**数组** ────────────────────────────────
    // 写成标量（如 `ciScope: "metadata"`）能骗过"字段存在"检查，却会让
    // `--list ci:data` 这类选择子按**子串**误命中（`"metadata".includes("data")` 为真），
    // 返回本不该返回的组件。数组形态下匹配是精确的——**根因是标量，不是选择子**。
    // （T3 评审实测：标量 + `--list ci:data` → rc=0 返回了组件；已核实数组形态 `ci:meta` 返回空。）
    for (const f of ['ciScope', 'releaseScope', 'platforms']) {
      if (!Array.isArray(c[f])) {
        fail(`${where} 的 ${f} 必须是数组（收到 ${JSON.stringify(c[f])}）`)
      } else if (c[f].some((x) => typeof x !== 'string')) {
        fail(`${where} 的 ${f} 元素必须都是字符串`)
      }
    }
```

并在夹具 C 组加一条：`write_catalog "[$(good_component c1 plugins/c1 '{"ciScope":"metadata"}')]" 2`
→ `run_case "C7 ciScope 写成标量（须拒）" CAUGHT`。

删除原来那一行 `if (c.pinPolicy === 'tag' && c.pinRef.startsWith('refs/')) ...`（已被上面取代）。

- [ ] **Step 4: 跑，确认 C1–C7 全过**

Run: `bash scripts/probe-catalog.sh && node scripts/check-components.mjs`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add scripts/check-components.mjs scripts/probe-catalog.sh
git commit -F - <<'EOF'
feat(catalog): catalog 阶段不变量（无需子仓即可判定）

新增：
  · pinRef 非空（空串会让 check-pins.sh 拿空 ref 去 fetch）
  · excluded ⇒ releaseScope 不含 bundle
    （**不**要求 releaseScope 为空——excluded 组件未来仍可能有独立
     制品/SBOM/provenance，过强的约束会挡住合理设计）
  · runtimeScope 与 prepareMode 的正交真值表

同时把 validate() 中不依赖子仓的部分抽为 validateCatalog()，
供后续的 --list/--plan 复用（它们此前绕过了校验）。
EOF
```

---

### Task 5: `--plan prepare` 输出动作计划

**Files:**
- Modify: `scripts/check-components.mjs`（加 `--plan`）
- Modify: `scripts/probe-catalog.sh`（加用例）

**Interfaces:**
- Produces: `node scripts/check-components.mjs --plan prepare` → 每行 `<path>\t<prepareMode>`，只含 `runtimeScope: required` 的组件。消费方是 T8/T9 的 prepare executor。
- Consumes: Task 4 的 `validateCatalog`。

> ⚠️ **验收项（必须显式验，不是"顺带"）：目录非法时，`--list` 与 `--plan` 必须返回非 0。**
>
> 为什么单列：`deploy/remote-install.sh` **没有** `setup.sh:212` 那样的显式前置校验，直接
> `PREPARE_LIST="$(node … --list prepare)"`。它靠 `set -euo pipefail` + `$()` 传播退出码来兜底
> ——**这条链只在 `--list` 失败时返回非 0 才成立**。若实现成"打印错误但继续、rc=0、stdout 空"，
> 则 `PREPARE_LIST` 为空 → 每个插件走「跳过」→ **部署"成功"却没装东西**。
>
> T4 评审提出该风险、控制器修正了它的方向（`set -e` 下现在确实是 fail-closed），
> 但**它成立的前提写在 T5 这一侧**：请用例明确覆盖"非法目录下 `--list` rc≠0"。
> （T9 会把 remote-install 的显式前置校验补上，让两边对称、不再依赖这条微妙语义。）

- [ ] **Step 1: 加失败用例**

追加（注意：`--plan` 的输出是**制表符分隔**，断言要匹配）：

```bash
echo
echo "== D. --plan prepare =="
# 两个组件：一个 required/source-build，一个 excluded（不应出现在计划里）
write_catalog "[$(good_component aaa plugins/aaa),$(good_component bbb plugins/bbb '{"runtimeScope":"excluded","prepareMode":"none","releaseScope":[]}')]" 2
write_gitmodules "plugins/aaa plugins/bbb"
plan_out="$(cd "$TMP" && node scripts/check-components.mjs --plan prepare 2>&1)"
printf '  %-44s %s\n' "D1 计划含 required 组件" "$(printf '%s' "$plan_out" | grep -q 'plugins/aaa.*source-build' && echo ok || { echo '!! 缺 aaa'; FAILED=$((FAILED+1)); })"
printf '  %-44s %s\n' "D2 计划**不含** excluded 组件" "$(printf '%s' "$plan_out" | grep -q 'plugins/bbb' && { echo '!! 混入 bbb'; FAILED=$((FAILED+1)); } || echo ok)"
printf '  %-44s %s\n' "D3 计划带 prepareMode（不是只有路径）" "$(printf '%s' "$plan_out" | awk -F'\t' '$1=="plugins/aaa" && $2!=""{f=1} END{exit !f}' && echo ok || { echo '!! 无制表符分隔的动作'; FAILED=$((FAILED+1)); })"
```

- [ ] **Step 2: 跑，确认 D1–D3 失败**

Run: `bash scripts/probe-catalog.sh`
Expected: D1/D2/D3 至少一项 `!!`（`--plan` 尚不存在，node 会把它当未知参数走 `validate()`）。

- [ ] **Step 3: 实现 `--plan`**

`scripts/check-components.mjs`，在 `list()` 之后加：

```javascript
// --plan <named-selector>：输出**动作计划**而不只是路径。
//
// 为什么要输出动作而不只是路径：`--list prepare` 只统一了「准备哪些组件」这个**决策**。
// 若 setup 与 remote-install 各自实现一套 `case "$prepareMode"` 去决定**怎么准备**，
// 漂移只会从「选哪个字段」变成「怎么执行动作」——病没治好，换了个地方发作。
// 但**这仍然只是决策数据**：动作的**执行**必须共用同一个 executor（见 prepare-executor.sh）。
function plan(catalog, selector) {
  if (selector !== 'prepare') {
    console.error(`✗ --plan 只支持具名选择器 prepare（收到 ${JSON.stringify(selector)}）`)
    process.exit(1)
  }
  for (const c of catalog.components) {
    if (c.runtimeScope !== 'required') continue
    console.log(`${c.path}\t${c.prepareMode}`)
  }
}
```

把文件末尾的参数分发改为：

```javascript
const args = process.argv.slice(2)
const catalog = loadCatalog()

// 先校验再查询：`--list` 此前**直接查询、绕过 validate()**，于是一个字段非法的
// catalog 能让查询器照常输出，调用方据此执行——正是 fail-open。
if (!validateCatalog(catalog)) process.exit(1)

const li = args.indexOf('--list')
const pl = args.indexOf('--plan')
if (li !== -1) {
  const sel = args[li + 1]
  if (!sel) { console.error('✗ --list 需要一个选择器，如 ci:test'); process.exit(1) }
  list(catalog, sel)
} else if (pl !== -1) {
  const sel = args[pl + 1]
  if (!sel) { console.error('✗ --plan 需要一个具名选择器，如 prepare'); process.exit(1) }
  plan(catalog, sel)
} else {
  validate(catalog)
}
```

**注意**：`validate()` 现在需要调 `validateCatalog()` 之外的子仓检查；把它改为先调 `validateCatalog(catalog)`，再跑 `checkLicenseDeclarations()` 等需要子仓的部分。

- [ ] **Step 4: 跑，确认 D1–D3 全过**

Run: `bash scripts/probe-catalog.sh`
Expected: 无 `!!`。

- [ ] **Step 5: 验证 `--plan` 在真 catalog 上的输出**

Run: `node scripts/check-components.mjs --plan prepare`
Expected: 9 行，每行形如 `plugins/dsh-web<TAB>source-build`；**不含** `plugins/dsh-tui`。

- [ ] **Step 6: 提交**

```bash
git add scripts/check-components.mjs scripts/probe-catalog.sh
git commit -F - <<'EOF'
feat(catalog): --plan prepare 输出动作计划；--list/--plan 先校验再查询

--plan 输出 `<path>\t<prepareMode>`，让 setup 与 remote-install 消费同一份
**决策数据**，而不是各自实现一套「怎么准备」的 case。

同时修一处 fail-open：`--list` 此前直接查询、**绕过 validate()**，
于是一个字段非法的 catalog 仍能让查询器照常输出、调用方据此执行。
现在两个查询入口都先跑 validateCatalog。

注意：--plan 只统一了决策数据。动作的**执行**仍需共用 executor（后续任务），
否则漂移只是从「选哪个字段」变成「怎么执行动作」。
EOF
```

---

### Task 6: materialized 阶段不变量与 `--require-materialized`

**Files:**
- Modify: `scripts/check-components.mjs`
- Modify: `scripts/probe-catalog.sh`（加用例；需要一个"伪子仓"）

**Interfaces:**
- Produces: `check-components.mjs --require-materialized`；任何 skip 变为失败。`validate()` 默认仍允许跳过（保持 `make setup` 之前可运行）。
- Consumes: Task 4 的 `validateCatalog`。

- [ ] **Step 1: 在夹具里造一个可控的伪子仓**

追加到 `scripts/probe-catalog.sh` 的辅助函数区：

```bash
# 造一个最小子仓：$1=path（相对 TMP）  $2=package.json 的 JSON  $3=被 git 跟踪的入口文件名（空格分隔，可空）
make_subrepo() {
  local d="$TMP/$1" entry
  mkdir -p "$d"
  printf '%s' "$2" > "$d/package.json"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t )
  for entry in $3; do
    mkdir -p "$d/$(dirname "$entry")"
    printf '// fixture\n' > "$d/$entry"
    ( cd "$d" && git add -f "$entry" )
  done
  ( cd "$d" && git -c commit.gpgsign=false commit -qm fixture )
}
```

- [ ] **Step 2: 加失败用例**

```bash
echo
echo "== E. materialized 阶段不变量 =="
# E1: tracked-prebuilt 但入口未被跟踪 → 必须失败
make_subrepo plugins/e1 '{"name":"e1","main":"lib/index.js"}' ""
write_catalog "[$(good_component e1 plugins/e1 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e1"
run_case "E1 tracked-prebuilt 但入口未跟踪"        CAUGHT
# E2: tracked-prebuilt 且入口已跟踪 → 通过
make_subrepo plugins/e2 '{"name":"e2","main":"lib/index.js"}' "lib/index.js"
write_catalog "[$(good_component e2 plugins/e2 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e2"
run_case "E2 tracked-prebuilt 且入口已跟踪"        GAP
# E3: tracked-prebuilt 且 main 已跟踪，但 exports 指向未跟踪文件 → 必须失败
make_subrepo plugins/e3 '{"name":"e3","main":"lib/index.js","exports":{".":"./lib/index.js","./extra":"./lib/extra.js"}}' "lib/index.js"
write_catalog "[$(good_component e3 plugins/e3 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e3"
run_case "E3 exports 目标未跟踪（只查 main 不够）"  CAUGHT
# E4: source-build 但无 build 脚本 → 必须失败
make_subrepo plugins/e4 '{"name":"e4"}' ""
write_catalog "[$(good_component e4 plugins/e4)]" 2
write_gitmodules "plugins/e4"
run_case "E4 source-build 但无 build 脚本"          CAUGHT
# E5: 未初始化子仓 + --require-materialized → 必须失败（skip 不再是免死金牌）
write_catalog "[$(good_component e5 plugins/e5 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e5"
out="$(cd "$TMP" && node scripts/check-components.mjs --require-materialized 2>&1)"; rc=$?
printf '  %-44s %s\n' "E5 未初始化子仓 + --require-materialized" "$([ $rc -ne 0 ] && echo 'CAUGHT  ok' || { echo '!! 竟然通过'; FAILED=$((FAILED+1)); })"
# E6: 同一 fixture 不加 --require-materialized → 允许跳过
out="$(cd "$TMP" && node scripts/check-components.mjs 2>&1)"; rc=$?
printf '  %-44s %s\n' "E6 未初始化子仓（非严格模式，应通过）" "$([ $rc -eq 0 ] && echo 'GAP     ok' || { echo '!! 竟然失败'; FAILED=$((FAILED+1)); })"
```

- [ ] **Step 3: 跑，确认 E1–E6 中 E2/E6 通过、其余失败**

Run: `bash scripts/probe-catalog.sh`
Expected: E1/E3/E4/E5 = `!!`；E2/E6 = ok。

- [ ] **Step 4: 实现 materialized 校验**

`scripts/check-components.mjs`，加：

```javascript
const REQUIRE_MATERIALIZED = process.argv.includes('--require-materialized')

// 从一个 package.json 里取出「本仓承诺会随 pin 一起交付」的入口文件清单。
// 只取**无通配符**的目标：带 * 的 exports 无法静态判定，不在本检查范围内。
function declaredEntries(pkg) {
  const out = new Set()
  if (typeof pkg.main === 'string') out.add(pkg.main)
  if (typeof pkg.types === 'string') out.add(pkg.types)
  const walk = (v) => {
    if (typeof v === 'string') { if (!v.includes('*')) out.add(v) }
    else if (v && typeof v === 'object') for (const x of Object.values(v)) walk(x)
  }
  walk(pkg.exports)
  // 归一化：去掉前导 './'，便于与 git ls-files 的输出比较
  return [...out].map((p) => p.replace(/^\.\//, '')).filter(Boolean)
}

// materialized 阶段：需要读子仓。子仓未初始化时**跳过并计数**——
// 本检查不得引入「先跑 make setup」的前置依赖。
// 但 --require-materialized 下，skip 本身即失败：CI 与 release 用它，
// 否则 fresh clone 上可以一项都不查就通过（fail-open）。
function checkMaterialized(components) {
  let checked = 0
  const skipped = []
  for (const c of components) {
    if (c.prepareMode === 'none' || c.prepareMode === 'install-only') continue
    const dir = join(ROOT, c.path)
    let pkg
    try {
      pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    } catch {
      skipped.push(c.name)
      continue
    }
    checked++
    const tracked = (rel) => {
      try {
        execFileSync('git', ['-C', dir, 'ls-files', '--error-unmatch', rel], { stdio: 'ignore' })
        return true
      } catch { return false }
    }
    if (c.prepareMode === 'tracked-prebuilt') {
      const entries = declaredEntries(pkg)
      if (!entries.length) {
        fail(`组件 ${c.name} 的 prepareMode=tracked-prebuilt，但其 package.json 未声明任何入口（main/types/exports）——无物可验`)
      }
      for (const e of entries) {
        if (!tracked(e)) {
          fail(`组件 ${c.name} 的 prepareMode=tracked-prebuilt，但声明的入口 ${e} **未被 git 跟踪**——fresh clone 上该组件是坏的`)
        }
      }
    }
    if (c.prepareMode === 'source-build' && !pkg.scripts?.build) {
      fail(`组件 ${c.name} 的 prepareMode=source-build，但其 package.json 没有 scripts.build`)
    }
  }
  if (skipped.length && REQUIRE_MATERIALIZED) {
    fail(`--require-materialized：${skipped.length} 个组件的子仓未初始化（${skipped.join(', ')}）——严格模式下不允许跳过。请先 make setup 或确保 checkout 带 submodule。`)
  }
  return { checked, skipped }
}
```

在 `validate()` 里，`checkLicenseDeclarations` 之后加 `const mat = checkMaterialized(components)`，并把成功输出改为：

```javascript
    console.log(`  （materialized 检查：${mat.checked} 个已验；${mat.skipped.length} 个跳过——子仓未初始化${REQUIRE_MATERIALIZED ? '（严格模式，跳过即失败）' : ''}）`)
```

- [ ] **Step 5: 跑，确认 E1–E6 全过**

Run: `bash scripts/probe-catalog.sh`
Expected: 无 `!!`。

- [ ] **Step 6: 在真 catalog 上验证两个模式**

```bash
node scripts/check-components.mjs --require-materialized
```
Expected: 通过（本机子仓已初始化），输出含 `materialized 检查：<N> 个已验；0 个跳过`
（`<N>` = 实际组件数，目前 11；**0 个跳过**才是要点——有跳过说明有子仓没初始化）。

- [ ] **Step 7: 把 `--require-materialized` 挂进 CI 与 release**

`.github/workflows/verify.yaml`，把 `bash scripts/check-all.sh --offline` 改为：

```yaml
        run: bash scripts/check-all.sh --offline --require-materialized
```

`.github/workflows/release.yaml` 的 preflight 同样加 ` --require-materialized`。

`scripts/check-all.sh` 接受并把该旗标透传给 `check-components.mjs`：

```bash
# 在 OFFLINE 调用处
check_components() { run "组件目录（声明层：双向集合 + license 词表 + 与 package.json 核对）" node scripts/check-components.mjs ${REQUIRE_MAT:+--require-materialized}; }
```

并在参数解析处加：

```bash
REQUIRE_MAT=""
for a in "$@"; do [ "$a" = "--require-materialized" ] && REQUIRE_MAT=1; done
```

- [ ] **Step 8: 实现「构建可能弄脏 submodule」的警告（不阻断）**

**为什么在这里补**：ADR-0005 承诺了这条警告，但**此前没有任何任务实现它**（2026-09-15 T2 评审发现）。
它只能在 materialized 阶段做——只有那里读得到子仓的 `package.json` 与 git 追踪状态。

判据**必须复用 `declaredEntries`**（与 `tracked-prebuilt` 同一个集合）。
⚠️ **只查 `main` 是错的**：ADR 自己举的那个例子 `dsh-market`，其 `main`（`lib/index.js`）
恰恰**未**被跟踪，被跟踪的是 `exports["./client"] → ./client/client.js`——
按 `main` 判定会把**唯一的例子**漏掉。按全入口集判定，当前应触发的是
`dsh-market`、`modlens`、`modsearch` 三个。

在 `checkMaterialized` 的循环里、`tracked-prebuilt` 分支**之后**加：

```javascript
    // ADR-0005：这一条**不写成不变量，只报警告**——本仓可以出于供应链政策选择源码重建，
    // 即使子仓恰好也提交了产物。故**不调用 fail()**，不影响退出码。
    if (c.prepareMode === 'source-build') {
      const dirtyable = declaredEntries(pkg).filter((e) => tracked(e))
      if (dirtyable.length) {
        warn(`组件 ${c.name} 是 source-build，但入口 ${dirtyable.join(', ')} 已被 git 跟踪——构建可能弄脏 submodule，进而触发部署的快照保真检查`)
      }
    }
```

`warn()` 若尚不存在，加在 `fail()` 旁边。**必须写 stderr，不能写 stdout**：

```javascript
// ⚠️ 警告走 **stderr**。stdout 是机器接口——`--list` / `--plan` 的输出被
// setup.sh / remote-install.sh **逐行解析**成路径与 prepareMode。警告混进 stdout
// 会被当成一个组件路径。人也一样：stdout 是结果，stderr 是评论。
function warn(msg) { console.error(`  ⚠️  ${msg}`) }
```

- [ ] **Step 9: 加警告的夹具用例 E7**

警告不阻断，所以**不能**用只看退出码的 `run_case`——要断言 stderr 上出现了该组件。

```bash
# E7: source-build 且入口已被跟踪 → 通过（GAP），但**必须**在 stderr 上出现警告
make_subrepo plugins/e7 '{"name":"e7","main":"lib/index.js","scripts":{"build":"true"}}' "lib/index.js"
write_catalog "[$(good_component e7 plugins/e7)]" 2
write_gitmodules "plugins/e7"
out="$(cd "$TMP" && node scripts/check-components.mjs 2>&1 >/dev/null)"; rc=$?
printf '  %-44s %s\n' "E7 source-build 且入口已跟踪（警告不阻断）" \
  "$([ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'e7' && echo 'GAP     ok（且已警告）' || { echo '!! 未通过或未警告'; FAILED=$((FAILED+1)); })"
```

断言的是**组件名**（数据），不是错误文案——文案重构不应让用例假红。

- [ ] **Step 10: 跑，确认 E1–E7 全过**

Run: `bash scripts/probe-catalog.sh`
Expected: 无 `!!`。E7 显示 `GAP ok（且已警告）`。

- [ ] **Step 11: 提交**

```bash
git add scripts/check-components.mjs scripts/probe-catalog.sh scripts/check-all.sh .github/workflows/verify.yaml .github/workflows/release.yaml
git commit -F - <<'EOF'
feat(catalog): materialized 阶段校验 + --require-materialized

新增需要读子仓的不变量：
  · tracked-prebuilt ⇒ main/types/无通配符 exports 目标**均被 git 跟踪**
    （只查 main 不够：exports 指向未跟踪文件时 fresh clone 照样是坏的）
  · source-build ⇒ 存在 scripts.build

**fail-open 的堵法**：子仓未初始化时跳过并计数（保持"make setup 之前可运行"
这条既有约束），但 `--require-materialized` 下**skip 本身即失败**。
CI 与 release 用严格模式——否则 fresh clone 上可以一项都不查就通过，
那正是 09-15 review 诊断出的 fail-open 形态。

带通配符的 exports 目标无法静态判定，明确不在本检查范围内。

另加一条**只警告、不阻断**的（ADR-0005 承诺过、此前无人实现）：
  source-build ⇒ 若任何会被加载的入口已被 git 跟踪，构建可能弄脏 submodule。
  判据与 tracked-prebuilt 同一个集合——**只查 main 会漏掉 ADR 自己举的
  dsh-market 那个例子**（它的 main 未跟踪，被跟踪的是 exports["./client"]）。
  警告走 stderr：stdout 是机器接口（--list/--plan 被脚本逐行解析），不能混入。
EOF
```

---

### Task 7: 删掉 link-plugins 与 remote-install 的 `2>/dev/null || true`

**Files:**
- Modify: `scripts/link-plugins.sh:30-33`
- Modify: `deploy/remote-install.sh:42-45`

**Interfaces:**
- Consumes: Task 5 的 `--list`（现在会先校验，失败即非零退出）。

- [ ] **Step 1: 加失败用例（证明当前是 fail-open）**

追加到 `scripts/probe-catalog.sh`：

```bash
echo
echo "== F. 消费者的 fail-open =="
# **行为断言，不是 grep 源码。**
# grep 断言"某个字符串不存在"是"断言了等于没断言"：改写成 `2>/dev/null || :`
# 照样通过，而 fail-open 还在。这里造一个**目录非法**的 fixture，让消费者实际跑一次，
# 断言它**非零退出**——只看退出码，不看错误文案（文案重构不该让用例假红）。
make_subrepo_broken() { # 造一个 catalog 非法、但子仓齐备的最小仓库
  mkdir -p "$TMP/broken/scripts" "$TMP/broken/config" "$TMP/broken/plugins/bad"
  cp "$ROOT/scripts/check-components.mjs" "$TMP/broken/scripts/"
  # runtimeScope=excluded 但 releaseScope 含 bundle —— catalog 阶段不变量即失败
  cat > "$TMP/broken/config/components.json" <<'JSON'
{ "version": 2, "description": "broken fixture",
  "components": [ { "name": "bad", "path": "plugins/bad", "sourceAuthority": "github",
    "pinPolicy": "tag", "pinRef": "v1", "ciScope": ["build"],
    "releaseScope": ["bundle"], "runtimeScope": "excluded", "prepareMode": "none",
    "platforms": [], "testProfile": "none", "stateSchema": "none", "license": "MIT" } ] }
JSON
  printf '[submodule "plugins/bad"]\n\tpath = plugins/bad\n\turl = https://example.invalid/bad.git\n' > "$TMP/broken/.gitmodules"
  printf '{"name":"bad","license":"MIT"}' > "$TMP/broken/plugins/bad/package.json"
}
make_subrepo_broken

# 断言：查询器在目录非法时必须**非零退出**（而不是照常吐出结果）
if (cd "$TMP/broken" && node scripts/check-components.mjs --list runtime:excluded >/dev/null 2>&1); then
  printf '  %-44s %s\n' "F1 非法目录下 --list 必须失败" "!! 竟然成功（fail-open）"; FAILED=$((FAILED + 1))
else
  printf '  %-44s %s\n' "F1 非法目录下 --list 必须失败" "ok"
fi

# 断言：两个消费者不再使用吞错写法。
# ⚠️ **这是静态检查，不是行为证明**——它挡不住 `2>/dev/null || :` 这类改写。
#    原本想做成行为断言（拿非法目录跑一次消费者、断言非零退出），**但那是假绿**：
#    link-plugins.sh 在 `$ROOT/harness/node_modules` 缺失时本来就会失败，
#    夹具里必然缺这个目录 → 无论 fail-open 修没修，它都"非零退出"。
#    真正的行为保证在 Step 4 的 `make link-plugins`（真环境、真目录）。
for f in scripts/link-plugins.sh deploy/remote-install.sh; do
  if grep -q '2>/dev/null || true' "$ROOT/$f"; then
    printf '  %-44s %s\n' "F2 $f 仍含吞错写法（静态检查）" "!! fail-open 未修"; FAILED=$((FAILED + 1))
  else
    printf '  %-44s %s\n' "F2 $f 已无吞错写法（静态检查）" "ok"
  fi
done
```

- [ ] **Step 2: 跑，确认 F1/F2 失败**

Run: `bash scripts/probe-catalog.sh`
Expected: `F1 ... !! 竟然成功（fail-open）`；两行 `F2 ... !! fail-open 未修`。

- [ ] **Step 3: 去掉吞错——⚠️ 不是简单删掉 `|| true`**

**先看这个陷阱**（已实测，别再踩）：把 `|| true` 删掉**不解决问题**——
`done < <(cmd)` 里 **`cmd` 的退出码不进入 `done` 的状态**（进程替换的状态被丢弃）。
删掉后脚本**照样**带着空 `SKIP_MOUNT` 继续跑，只是错误从"静默"变成"stderr 有字"。
而 `set -e` 对 `$()` **生效**、对 `<()` **不生效**（两条都已实测）。

`scripts/link-plugins.sh`，把这一整段：

```bash
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done < <(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded 2>/dev/null || true)
```

改为（**显式捕获 + 判 rc**）：

```bash
# 不吞错：目录查询失败必须让脚本失败。此前用 `2>/dev/null || true`，解析失败会
# 退化为**空排除列表**——而"空列表"的含义是"没有任何组件被排除"，与失败正好相反。
# 高风险消费者不能在配置错误后继续执行（ADR-0005）。
# ⚠️ 必须用 $() 显式捕获并判 rc：`done < <(cmd)` 拿不到 cmd 的退出码。
if ! _excluded="$(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded)"; then
  echo "错误: 组件目录查询失败（原因见上）。link-plugins 拒绝在未知的排除集上继续。" >&2
  exit 1
fi
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done <<< "$_excluded"
```

`deploy/remote-install.sh` 同样处理它那一处（同源代码，改法一致）。

- [ ] **Step 4: 跑，确认 F1 通过**

Run: `bash scripts/probe-catalog.sh && make link-plugins`
Expected: F1 两行 ok；`make link-plugins` 退出码 0、`完成: 已挂载 <N> 个 bundle`（`<N>` = 实际挂载数，目前 10；**别把数字抄进断言**——组件集合会变），且输出含 `跳过挂载: plugins/dsh-tui`（排除集**非空**才是要点：
这正是本任务要保的性质——排除集一旦为空，dsh-tui 会被挂进 profile dsh）。

- [ ] **Step 5: 提交**

```bash
git add scripts/link-plugins.sh deploy/remote-install.sh scripts/probe-catalog.sh
git commit -F - <<'EOF'
fix: 去掉 link-plugins 与 remote-install 的目录查询 fail-open

两处都用 `2>/dev/null || true` 吞掉 `--list runtime:excluded` 的失败。
后果是**语义反转**：解析失败退化为空排除列表，而空列表的含义是
"没有任何组件被排除"——正好相反。最需要目录保护的路径，恰恰在
目录解析失败时继续执行。

ADR-0005：禁止 fail-open，配置错误必须 fail closed。
EOF
```

---

### Task 8: 共用 prepare executor，接入 setup.sh

**Files:**
- Create: `scripts/prepare-executor.sh`
- Modify: `scripts/setup.sh`（把 `INSTALL_LIST=` 到对应 `done` 的整段换成消费 `--plan` + 调 executor；**按锚点定位，别按行号**）
- Modify: `scripts/check-all.sh`（executor 在 `scripts/*.sh` 内，已被 shellcheck 覆盖——无需改）

**Interfaces:**
- Produces: `prepare_component <rel> <prepareMode> <frozen|nonfrozen>`。**调用方必须先定义两个钩子**：`pe_install <rel> <frozen|nonfrozen>`、`pe_run_build <rel>`。
- Consumes: Task 5 的 `--plan`、Task 2 的 `prepareMode` 四值。

- [ ] **Step 1: 先看清两处循环同构到什么程度**

Run（**用锚点而不是行号**——行号会随注释增删漂移，本计划已经漂过一次）：
```bash
diff <(sed -n '/^INSTALL_LIST=/,/^done/p' scripts/setup.sh) \
     <(sed -n '/^PREPARE_LIST=/,/^done/p' deploy/remote-install.sh)
```
Expected: 主体逐行同构，差异只在 install 策略（本地容忍缺 lockfile、服务器直接报错）。**这同构正是 P0-1 的土壤**，也是本任务存在的理由。

- [ ] **Step 2: 写 executor**

创建 `scripts/prepare-executor.sh`：

```bash
# prepare-executor.sh — 组件准备动作的**唯一实现**（被 setup.sh 与 remote-install.sh source）
#
# 为什么必须共用：`--plan prepare` 只统一了「准备哪些组件、各用什么模式」这份**决策数据**。
# 若两处各自实现一套 `case "$prepareMode"` 去决定**怎么准备**，漂移只会从
# 「选哪个字段」变成「怎么执行动作」——病没治好，换个地方发作。
# 此前两处循环逐行同构，正是 09-15 review 的 P0-1 的土壤。
#
# 本文件**不自己执行**，它是被 source 的库。调用方必须先定义两个钩子，
# 把**环境策略差异**注入进来（这正是唯一该有差异的地方）：
#
#   pe_install <rel> <frozen|nonfrozen>   # 安装依赖
#   pe_run_build <rel>                    # 执行构建
#
# 两者都应在失败时自行退出（调用方已有的 plugin_install / plugin_run 即符合）。

# shellcheck shell=bash

prepare_component() { # $1=rel(paths 形如 plugins/<name>)  $2=prepareMode  $3=frozen|nonfrozen
  local rel="$1" mode="$2" install_policy="$3"

  case "$mode" in
    none)
      echo "==> 跳过准备: ${rel}（prepareMode=none）"
      return 0
      ;;
    install-only|source-build|tracked-prebuilt) ;;
    *)
      echo "错误: ${rel} 的 prepareMode 取值非法: '${mode}'（允许 source-build / tracked-prebuilt / install-only / none）。这是组件目录与执行器不一致，拒绝继续。" >&2
      return 1
      ;;
  esac

  echo "==> 安装依赖: ${rel}（${install_policy}）"
  pe_install "$rel" "$install_policy" || return 1

  if [ "$mode" = "source-build" ]; then
    echo "==> 构建: ${rel}"
    pe_run_build "$rel" || return 1
  fi

  if [ "$mode" = "tracked-prebuilt" ]; then
    # 产物的**跟踪状态**由 check-components.mjs --require-materialized 校验；
    # 这里只声明动作，不重复实现校验逻辑（那会是第二份事实源）。
    echo "==> 跳过构建: ${rel}（prepareMode=tracked-prebuilt；入口跟踪状态由 check-components.mjs 校验）"
  fi

  return 0
}
```

- [ ] **Step 3: 把 setup.sh 的循环换成 executor**

把 `scripts/setup.sh` 里从 `INSTALL_LIST="$(node scripts/check-components.mjs --list prepare)"` 到对应 `done` 的整段，替换为：

```bash
# 计划由**查询器**给出（path + prepareMode），动作由**共用 executor** 执行。
# 两处各写一套「怎么准备」的 case 会让漂移从"选哪个字段"变成"怎么执行动作"（ADR-0005）。
#
# 先跑 materialized 严格校验：本机到这一步子仓已就绪，没有理由再容忍 skip。
node scripts/check-components.mjs --require-materialized || {
  echo "错误: 组件目录的 materialized 校验失败（见上）。修正后重试。" >&2
  exit 1
}

PREPARE_PLAN="$(node scripts/check-components.mjs --plan prepare)"

# ── 环境策略钩子（本地）─────────────────────────────────────────────────────
# 本地容忍缺 lockfile（非冻结安装），服务器不允许——这是**唯一**该有差异的地方。
pe_install() { # $1=rel  $2=frozen|nonfrozen
  local rel="$1" d="$1/"
  if [ -f "${d}pnpm-lock.yaml" ]; then
    plugin_install "$d" install --frozen-lockfile
  elif has_npm_lock "$d"; then
    echo "==> ${rel} 使用 npm（package-lock.json，可复现安装）"
    plugin_install "$d" ci
  else
    echo "注意: ${rel} 无 pnpm-lock.yaml 也无 package-lock.json，将执行非冻结安装（pnpm install），可能在插件 submodule 内生成或改动文件（如 lockfile）。如需可复现安装，请在插件仓提交 lockfile。"
    plugin_install "$d" install
  fi
}
pe_run_build() { plugin_run "$1/" run build; }

# shellcheck source=scripts/prepare-executor.sh
. "$ROOT/scripts/prepare-executor.sh"

while IFS=$'\t' read -r rel mode; do
  [ -n "$rel" ] || continue
  prepare_component "$rel" "$mode" nonfrozen || exit 1
done <<< "$PREPARE_PLAN"
```

**注意**：`setup.sh` 顶部有 `cd "$(dirname "$0")/.."` 但没有定义 `ROOT`——本任务需在文件靠前处加 `ROOT="$PWD"`（若已存在则复用）。

- [ ] **Step 4: 删掉旧启发式**

确认 `scripts/setup.sh` 里已不存在这段（它随整段替换被删掉）：

```bash
main_entry="$(node -e '...').main||""' "$d/package.json")"
if [ -n "$main_entry" ] && git -C "$d" ls-files --error-unmatch "${main_entry#./}" >/dev/null 2>&1; then
```

Run: `grep -c 'ls-files --error-unmatch "${main_entry' scripts/setup.sh`
Expected: `0`

- [ ] **Step 5: 验证 setup 的计划与执行一致**

Run: `bash -c 'bash scripts/setup.sh 2>&1 | grep -E "跳过准备|安装依赖|构建:|跳过构建" | head -30'`
Expected: **`<N>` 个组件各出现一次**（`<N>` = `node scripts/check-components.mjs --plan prepare | wc -l`，目前 10；
**别把数字写进断言**——组件集合会变）；`plugins/dsh-tui` **不出现*在准备输出里***
（即不得有 `安装依赖: plugins/dsh-tui` / `构建: plugins/dsh-tui` / `跳过构建: plugins/dsh-tui`）；
`dsh-agent-teams` 有 `构建:` 行（存量修正后它是 source-build）；`dsh-at-file` 是 `跳过构建:`。

> ⚠️ **`dsh-tui` 仍会出现在别处，那三处是正常的**，别为了"让它不出现"去改：
> ① `git submodule sync` 的输出；② pnpm 版本报告循环（`==> plugins/dsh-tui 使用 pnpm@…`，
> 它对**所有** subrepo 报 corepack 解析，与是否进入准备无关）；③ 校验器的 `runtimeScope=excluded` 诊断。
> （实测：`make setup` 输出里 dsh-tui 共出现 8 次，全部属于这三处。）

> ⚠️ 若不想真跑完整 setup（会重装依赖），改为只验证计划：
> `node scripts/check-components.mjs --plan prepare` 应输出 `<N>` 行（目前 10），其中
> `plugins/dsh-agent-teams<TAB>source-build`、`plugins/dsh-at-file<TAB>tracked-prebuilt`。
> **但要知道代价**：这条替代**只验了计划数据、没验执行路径**——而本任务改的正是执行路径。
> 若走替代，**必须在报告里写明 setup 的端到端执行未验证**。

- [ ] **Step 6: shellcheck**

Run: `shellcheck -S style scripts/*.sh deploy/remote-install.sh`
Expected: 退出码 0。

- [ ] **Step 7: 提交**

```bash
git add scripts/prepare-executor.sh scripts/setup.sh
git commit -F - <<'EOF'
refactor(setup): 抽出共用 prepare executor，删除 main-tracked 启发式

`--plan prepare` 只统一了「准备哪些组件、各用什么模式」这份**决策数据**。
若 setup 与 remote-install 各自实现一套 `case "$prepareMode"` 去决定
**怎么准备**，漂移只会从"选哪个字段"变成"怎么执行动作"。

故新增 scripts/prepare-executor.sh：动作决策树只此一份，**环境策略**由调用方
以两个钩子注入（pe_install / pe_run_build）——本地容忍缺 lockfile、
服务器必须冻结安装，这是唯一该有差异的地方。

同时**删除 `main` 被跟踪即跳过构建的启发式**：它一直在默默纠正
dsh-agent-teams 与 dsh-at-file 两处声明错误，从而让错误永远不被发现。
现在 prepareMode 是显式的政策选择，声明与执行是同一个东西。

并在执行计划**之前**跑 --require-materialized：本机到这一步子仓已就绪，
没有理由再容忍 skip。
EOF
```

---

### Task 9: remote-install 接入 executor 并改冻结策略

**Files:**
- Modify: `deploy/remote-install.sh:206-241`

**Interfaces:**
- Consumes: Task 8 的 `prepare_component`。

- [ ] **Step 1: 替换循环**

把 `deploy/remote-install.sh` 里从 `PREPARE_LIST="$(node ...)"` 到对应 `done` 的整段替换为：

```bash
# 与 scripts/setup.sh **同一个 executor**（scripts/prepare-executor.sh），
# 同一份动作计划（--plan prepare）。差异只在 install 策略：服务器必须可复现安装。
node "$ROOT/scripts/check-components.mjs" --require-materialized || {
  echo "错误: 组件目录的 materialized 校验失败（见上）。修正后重试。" >&2
  exit 1
}

PREPARE_PLAN="$(node "$ROOT/scripts/check-components.mjs" --plan prepare)"

# ── 环境策略钩子（服务器）───────────────────────────────────────────────────
pe_install() { # $1=rel  $2=frozen|nonfrozen
  local rel="$1" d="$1/"
  if [ -f "${d}pnpm-lock.yaml" ]; then
    plugin_install "$d" install --frozen-lockfile
  elif has_npm_lock "$d"; then
    echo "==> ${rel} 使用 npm（package-lock.json，可复现安装）"
    plugin_install "$d" ci
  else
    echo "错误: 插件 ${rel} 既无 pnpm-lock.yaml 也无 package-lock.json，服务器侧构建要求可复现安装（--frozen-lockfile / npm ci）。请在插件仓提交 lockfile 后重试。" >&2
    return 1
  fi
}
pe_run_build() { plugin_run "$1/" run build; }

# shellcheck source=scripts/prepare-executor.sh
. "$ROOT/scripts/prepare-executor.sh"

while IFS=$'\t' read -r rel mode; do
  [ -n "$rel" ] || continue
  prepare_component "$rel" "$mode" frozen || exit 1
done <<< "$PREPARE_PLAN"
```

- [ ] **Step 2: 确认旧启发式已消失**

Run: `grep -c 'ls-files --error-unmatch "${main_entry' deploy/remote-install.sh`
Expected: `0`

- [ ] **Step 2b: 补上与 `setup.sh` 对称的显式前置校验（T4 评审发现）**

**问题**：`scripts/setup.sh:212` 在读组件列表**之前**有一段显式校验：

```bash
node scripts/check-components.mjs || {
  echo "错误: 组件目录校验失败（见上）。请先修正 config/components.json 与 .gitmodules 的一致性。" >&2
  exit 1
}
```

`deploy/remote-install.sh` **没有**这一段，直接 `PREPARE_LIST="$(node … --list prepare)"`。
它靠 `set -euo pipefail` + `$()` 传播退出码兜底——**这条链只在 `--list` 失败时返回非 0 才成立**，
是**隐式依赖**。任何人日后把那行包进 `|| true`（T7 正在别处删这种写法）就立刻变成 fail-open：
`PREPARE_LIST` 为空 → 每个插件走「跳过」→ **部署"成功"却没装东西**。

**改法**：在 `deploy/remote-install.sh` 的 `PREPARE_LIST=` 之前插入**同一段**校验
（文案可随部署语境微调，但要 `exit 1`）。要点是**两条路径对称**，
且**不依赖 `set -e` 的微妙传播语义**。

- [ ] **Step 2c: 验证前置校验真的兜得住**

Run（在**副本**上造非法目录，不要动真仓）：
```bash
T="$(mktemp -d)"; cp -R deploy scripts config .gitmodules "$T"/ 2>/dev/null
# 把版本改成非法，使校验必然失败
sed "s/\"version\": 2/\"version\": 99/" config/components.json > "$T/config/components.json"
(cd "$T" && bash deploy/remote-install.sh) ; echo "rc=$?"
```
Expected: **非 0，且报的是"组件目录校验失败"**，而不是继续往下走。
⚠️ 若它因**别的原因**失败（如缺 `harness/`），那是**假绿**——必须确认失败**发生在校验那一步**。

- [ ] **Step 3: 确认两个消费者产出一致**

Run: `diff <(node scripts/check-components.mjs --plan prepare) <(node deploy/../scripts/check-components.mjs --plan prepare)`
Expected: 无差异（两者调的是同一个查询器；本步是形式化确认）。

- [ ] **Step 4: shellcheck**

Run: `shellcheck -S style scripts/*.sh deploy/remote-install.sh`
Expected: 退出码 0。

- [ ] **Step 5: 提交**

```bash
git add deploy/remote-install.sh
git commit -F - <<'EOF'
refactor(remote-install): 接入共用 prepare executor，删旧启发式

与 setup.sh 用**同一个** executor 与**同一份**动作计划，
差异只在 install 策略钩子（服务器必须冻结安装，缺 lockfile 直接失败）。

删除 main-tracked 启发式后，本地与服务器对同一份组件目录
给出完全一致的动作计划——这是 09-15 review P0-1
「同一份 manifest 两个消费者相反解释」的收口。
EOF
```

---

### Task 10: 所有 catalog 读取方复用 validated loader + declared 字段免责

**Files:**
- Modify: `scripts/gen-notices.mjs`
- Modify: `scripts/check-licenses.mjs`（改为复用 validated loader）
- Modify: `scripts/check-pins.sh`（读目录前先验证，fail-closed）
- Modify: `scripts/check-components.mjs`（`tracked()` 改成三分，见 Step 3b）
- Modify: `scripts/probe-catalog.sh`（加用例断言生成物含免责标注 + 所有读取方 fail-closed + 三分语义）

**Interfaces:**
- Consumes: `check-components.mjs` 的具名导出 `FIELD_CLASS`。
- Produces: `THIRD-PARTY-NOTICES.md` 的表头与 AGPL 节明确标注哪些列是**声明**。

- [ ] **Step 1: 加失败用例**

```bash
echo
echo "== G. 生成物对 declared 字段的免责 =="
if grep -q '声明，未验证' "$ROOT/THIRD-PARTY-NOTICES.md" 2>/dev/null; then
  printf '  %-44s %s\n' "G1 生成物标注了 declared 字段未经校验" "ok"
else
  printf '  %-44s %s\n' "G1 生成物标注了 declared 字段未经校验" "!! 未标注"; FAILED=$((FAILED + 1))
fi

echo
echo "== H. 所有 catalog 读取方都必须 fail-closed =="
# 夹具目前只拷了 check-components.mjs（见脚本顶部的 cp），H2 要用到第二个：
cp "$ROOT/scripts/check-licenses.mjs" "$TMP/scripts/"
# 造一个**版本非法**的 catalog，逐个读取方跑：谁静默接受，谁就是 fail-open。
# 背景（2026-09-15 T2 评审实测）：check-components.mjs 会拒绝，但
# check-licenses.mjs 与 gen-notices.mjs **rc=0 静默接受**，check-pins.sh 同理。
printf '{\n  "version": 1,\n  "components": []\n}\n' > "$TMP/config/components.json"
for f in check-components.mjs check-licenses.mjs; do
  if (cd "$TMP" && node "scripts/$f" >/dev/null 2>&1); then
    printf '  %-44s %s\n' "H $f 拒绝 version=1" "!! 静默接受"; FAILED=$((FAILED + 1))
  else
    printf '  %-44s %s\n' "H $f 拒绝 version=1" "ok"
  fi
done
```

- [ ] **Step 2: 跑，确认 G1 失败**

Run: `bash scripts/probe-catalog.sh`
Expected: `G1 ... !! 未标注`。

- [ ] **Step 3: 让 gen-notices 复用 validated loader**

> ⚠️ **本步的范围是「所有 catalog 读取方」，不止 gen-notices。**
> 2026-09-15 T2 评审实测：`check-components.mjs` 对 `version: 1` 会拒绝（rc=1），
> 但 `check-licenses.mjs`、`gen-notices.mjs`、`check-pins.sh` **都 rc=0 静默接受**——
> 它们直连 `JSON.parse` / `require`，**不看 `version`**。
> `gen-notices` 原在本任务范围内；**另两个在计划里无人负责**，现一并收口。
> 这不只是"少一道检查"：schema 再升一版时，字段可能搬家，而这些读取方会**照旧结构读**，
> 产出**看似正常**的结果——静默的错，不是响的错。

`scripts/gen-notices.mjs` 顶部，把直接解析 JSON 改为：

```javascript
import { FIELD_CLASS, loadCatalogValidated } from './check-components.mjs'
```

**`scripts/check-licenses.mjs`**（同一种改法）——把顶层那行
`const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'))` 换成：

```javascript
import { loadCatalogValidated } from './check-components.mjs'
// …
const catalog = loadCatalogValidated()
```

> ⚠️ **顺带一处同形缺陷（T3 评审发现，在此一并收口）**：`gen-notices.mjs` 里
> `FULL_NAME[lic] ?? 兜底` —— `FULL_NAME` 是对象字面量，**`FULL_NAME['constructor']` 会命中
> `Object` 的构造器**（真值），`??` 不触发兜底，于是把**一个函数**渲染进**合规文档**。
> 改法：`Object.hasOwn(FULL_NAME, lic) ? FULL_NAME[lic] : 兜底`。
> 它与本任务「读取方要 fail-closed」是同一件事：读之前先确认键**真的是自己的**。

**`scripts/check-pins.sh`**（bash，不能 import）——在 `ROOT="$PWD"` 之后、**任何读目录之前**
加一道验证并直接退出。顺序刻意放在最前：版本非法时**根本不联网**。

```bash
# 先过校验器再读目录：本脚本只读 path/pinPolicy/pinRef，直连 require() 会让
# **未知 schema 版本**的目录静默通过。fail-closed。
if ! node scripts/check-components.mjs >/dev/null; then
  echo "错误: 组件目录未通过校验，check-pins 拒绝在其上工作（原因见上）。" >&2
  exit 1
fi
```

并在 `check-components.mjs` 里加具名导出：

```javascript
// 供其它生成器复用的**已校验** loader。直连 JSON.parse 会让生成物
// 在目录非法时照样产出——而生成物是**对外**的那一份。
export function loadCatalogValidated() {
  const catalog = loadCatalog()
  if (!validateCatalog(catalog)) process.exit(1)
  return catalog
}
```

**注意**：`check-components.mjs` 目前是"顶层直接执行"的脚本，被 import 会连带执行它的参数分发。必须先用 `import.meta.url === pathToFileURL(process.argv[1]).href` 包住末尾的执行块：

```javascript
import { pathToFileURL } from 'node:url'

// 只有直接运行本文件时才执行参数分发；被 import 时只提供导出。
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2)
  const catalog = loadCatalog()
  if (!validateCatalog(catalog)) process.exit(1)
  /* ...原有分发... */
}
```

- [ ] **Step 3b: `tracked()` 改成三分——别把「查不了」说成「坏了」**

> **背景（T9 实测发现，不是本任务的问题，但同一主题）**：`scripts/deploy-remote.sh:184` 的 rsync 带
> `--exclude '.git'`，服务器树**没有 git 元数据**。用同一套 rsync 参数造的忠实副本上，
> 当前输出是：
> ```
> ✗ 组件 dsh-automation 的 prepareMode=tracked-prebuilt，但声明的入口 lib/index.js
>   **未被 git 跟踪**——fresh clone 上该组件是坏的
> ```
> **这是把"查不了"说成了"坏了"**：那些文件**就在那儿**（rsync 过来的），只是 `git ls-files` 无法运行。
> **这正是 AGENTS.md 禁止的形态**（把推断写成已验证）——只不过这次是**工具对用户**说的。

**根因**：`tracked()` 把**任何** git 失败都当作"未被跟踪"（`catch { return false }`）。
真正的语义是**三分**：**已跟踪 / 确认未被跟踪 / 查不了**。

**改法**：`tracked()` 返回三态（或用两个函数），并在调用点区分：
- **查不了**（该目录没有 git 元数据，如 `!existsSync(join(dir, '.git'))`）⇒ 与"子仓未初始化"**同类**，
  计入 `skipped`，**不得**输出"fresh clone 上该组件是坏的"这种未经验证的结论。
- **确认未被跟踪** ⇒ 照旧 `fail()`（这是真的坏）。
- `--require-materialized` 下 **skip 仍然即失败**（严格语义不变）。

**加夹具用例**（E 组）：
- **E9**：子仓存在、`package.json` 可读、但**没有 `.git`** ⇒ 非严格模式**应通过且计入 skipped**，
  且输出**不得**出现"未被 git 跟踪"或"fresh clone 上该组件是坏的"字样。
- **E10**：同一形态 + `--require-materialized` ⇒ **必须失败**（严格下 skip 即失败）。

⚠️ **不要**用"看起来像 git 错误就跳过"这种宽泛判据——那会把真正的"未被跟踪"也吞掉。
判据要**具体**：该目录**不存在 git 元数据**才算"查不了"。

- [ ] **Step 4: 加免责标注**

`gen-notices.mjs` 的 `render()` 里，把组件清单表头改为：

```javascript
  p('| 组件 | 许可证 | 来源 | 进制品 | 默认运行时 |')
  p('| --- | --- | --- | --- | --- |')
```

改为先吐一段说明：

```javascript
  p('> ⚠️ **「来源」「进制品」「默认运行时」是 catalog 的声明值，未经校验。**')
  p('> 其中「进制品」对应的 `releaseScope` 目前**没有行为消费者**（制品链尚未实现）——')
  p('> 它记录意图，不构成保证。字段分类见 [config/README.md](config/README.md)。')
  p()
  p('| 组件 | 许可证 | 来源 | 进制品（声明，未验证） | 默认运行时 |')
  p('| --- | --- | --- | --- | --- |')
```

并给 `sourceAuthority` 列的表头也加上同样的后缀。

- [ ] **Step 5: 重新生成并跑用例**

```bash
node scripts/gen-notices.mjs
bash scripts/probe-catalog.sh
```
Expected: G1 = ok；无 `!!`。

- [ ] **Step 6: 提交**

```bash
git add scripts/check-components.mjs scripts/gen-notices.mjs scripts/check-licenses.mjs scripts/check-pins.sh THIRD-PARTY-NOTICES.md scripts/probe-catalog.sh
git commit -F - <<'EOF'
fix(notices): 所有 catalog 读取方复用 validated loader + declared 字段免责

三个问题：

① **读取方不校验目录**：check-licenses.mjs / gen-notices.mjs 直接 JSON.parse、
   check-pins.sh 直接 require，**都不看 version**——目录非法时照样干活。
   实测：version=1 时 check-components.mjs 拒绝，而这三个 rc=0 静默接受。
   改为复用 check-components.mjs 的 loadCatalogValidated()；bash 那份在读目录前
   先跑一次校验器并直接退出（版本非法时根本不联网）。
   为此把 check-components.mjs 改成"直接运行才执行分发"，使其可被 import。
   ⚠️ 危害不在"少一道检查"：schema 再升版时字段会搬家，盲读旧结构的读取方
   会产出**看似正常**的结果——是静默的错。

② **免责只活在字段字典里**：生成物用「来源」「进制品」这类**事实性表头**，
   读者无从知道那只是声明。而分类若只在 config/README.md 里可见，
   生成物的读者仍会误解——**而生成物才是对外的那一份**。
   现给相关列标注「声明，未验证」并加一段说明。
EOF
```

---

### Task 11: 收尾 —— 更新实现状态表、重新生成声明、跑全量

**Files:**
- Modify: `config/README.md`（「实现状态」表逐条更新）
- Modify: `docs/remediation-plan.md`（记录本轮）
- Modify: `docs/cicd/adr/0005-*.md`（若实施中有偏离，追加说明而非改写结论）

- [ ] **Step 1: 逐条核对实现状态**

Run: `for i in "prepareMode" "--plan" "require-materialized" "packageManager"; do printf '%-24s ' "$i"; grep -rl "$i" config/components.json scripts/check-components.mjs >/dev/null 2>&1 && echo "存在" || echo "不存在"; done`
Expected: 用实际结果更新下表，**不要照抄计划**。

- [ ] **Step 2: 更新 `config/README.md` 的实现状态表**

把每一条已实现的从「**未实现**」改为「**已实现**」，并附上验证命令。例如：

```markdown
| `prepareMode` 四值 | **已实现**——`node scripts/check-components.mjs --list prepare` 与新字段一致 |
```

**仍未实现的必须保留在表里并说明原因**（如"完整的产物校验（最小加载/冒烟）"）。

- [ ] **Step 2b: 修正 README 里的「阶段归属」错误（T4 评审发现）**

`config/README.md` 把 **`runtimeScope × prepareMode` 正交约束**列在 **materialized 阶段**，
但 T4 把它实现进了 **catalog 阶段**（更早、更严）。按该表**自己的组织原则**（"需读子仓的才归 materialized"），
**是表自相矛盾**——该约束只看目录即可判定，不需要子仓。

改法：把这一条从 materialized 段**移到 catalog 段**，并加一句说明"实现比本表更早落地；
表格按'需读子仓'组织，本约束无需子仓"。

**同时补一行到状态表**：「`pinRef` 形如合法 ref（而不只是非空）」——**尚未实现**，
当前只查了非空与 `refs/` 前缀（T4 实现）。不要因为"大部分做了"就把它藏起来。

**再记一条部署树的物理事实**（T9 实测），写进两阶段校验的说明里：

> `scripts/deploy-remote.sh:184` 的 rsync 带 `--exclude '.git'` ⇒ **服务器树没有 git 元数据**
> ⇒ materialized 阶段在那里**永远无法运行**。这**不是配置问题，是那棵树的属性**
> （实测：忠实 rsync 副本上 `validate()` rc=1、13 条 ✗，而 `--plan prepare` rc=0）。
> 故部署侧只能用 catalog 阶段口径。

**必须写进文档的理由**：不写的话，下一个人看到"服务器没跑 materialized 阶段"，
会以为那是**漏了一步**，然后"补上"——而那会让每次部署都失败。

- [ ] **Step 3: 跑全量自检**

```bash
make check
```
Expected: 全部通过（项数比计划开始时多 1：新增的目录校验回归）。

- [ ] **Step 4: 跑一次真实的两阶段校验**

```bash
node scripts/check-components.mjs                       # catalog 阶段
node scripts/check-components.mjs --require-materialized  # materialized 阶段
```
Expected: 两条都通过；第二条输出 `materialized 检查：<N> 个已验；0 个跳过`（`<N>` = 实际组件数，目前 11）。

- [ ] **Step 5: 提交**

```bash
git add config/README.md docs/remediation-plan.md docs/cicd/adr/0005-component-catalog-lifecycle.md
git commit -F - <<'EOF'
docs: 按实现结果更新组件目录的实现状态表

ADR-0005 落地后，config/README.md 的「实现状态」表逐条核对并更新——
**留着过期的状态表比没有状态表更危险**（本仓的老毛病：把设计读成保证）。

仍未实现的条目保留在表里并说明原因，不因为"大部分做完了"就整表撤掉。
EOF
```

---

### Task 12: 双平台验证

**为什么单独一个任务**：`prepareMode` 的行为变更会**真实改变构建**（`dsh-agent-teams` 开始构建、`dsh-at-file` 停止构建）。本仓硬约束是「原生依赖必须按平台各自构建」，而 macOS arm64 与 Linux x86-64 的构建路径不同——只在一个平台验证等于没验证。

**Files:** 无（验证任务，不产出代码；结果写进 Task 11 的状态表）

- [ ] **Step 1: macOS arm64（本机）**

```bash
node scripts/check-components.mjs --require-materialized
node scripts/check-components.mjs --plan prepare
```
Expected: 通过；计划 9 行，含 `plugins/dsh-agent-teams	source-build` 与 `plugins/dsh-at-file	tracked-prebuilt`。

- [ ] **Step 2: 在目标 Linux 主机上验证计划**

```bash
ssh <host> 'bash -s' <<'EOF'
set -eu
cd ~/dsh   # 或该机上的仓库路径
node scripts/check-components.mjs --plan prepare
EOF
```
Expected: **与 macOS 输出逐行一致**（同一份目录 → 同一份计划，这正是 P0-1 的收口验收）。

> ⚠️ 若该机尚无仓库副本，本步改为：把 `config/components.json` 与 `scripts/check-components.mjs` 两个文件拷到该机的临时目录，跑 `node check-components.mjs --plan prepare`。**只需这两个文件**——查询器零依赖。

- [ ] **Step 3: 记录结果**

把两个平台的输出贴进 `config/README.md` 实现状态表对应行，或写进 `docs/remediation-plan.md`。

- [ ] **Step 4: 提交**

```bash
git add config/README.md docs/remediation-plan.md
git commit -F - <<'EOF'
docs: 记录组件动作计划的双平台验证结果

prepareMode 的行为变更会真实改变构建（agent-teams 开始构建、at-file 停止构建），
而本仓硬约束是「原生依赖必须按平台各自构建」。只在一个平台验证等于没验证。

验收点：两个平台对**同一份组件目录**给出**逐行一致**的动作计划——
这是 09-15 review P0-1「同一份 manifest 两个消费者相反解释」的最终收口。
EOF
```

---

## 自审记录

**Spec 覆盖检查**（逐条对 `ADR-0005` 的「决策」与「实施约束」）：

| Spec 要求 | 落在哪个任务 |
| --- | --- |
| 字段三分类 + 判据 | T3 |
| `buildMode` → `prepareMode` 四值 | T2 |
| `--plan` 输出动作计划 | T5 |
| 两阶段校验 + `--require-materialized` | T4（catalog）/ T6（materialized） |
| 删 `packageManager` | T2 |
| schema v1 → v2 | T2 |
| 删两处旧启发式 | T8 / T9 |
| 修三处 fail-open | T5（`--list` 绕过 validate）/ T7（两处 `\|\| true`） |
| 统一 prepare executor | T8（实现）/ T9（第二消费者） |
| gen-notices declared 免责 + validated loader | T10 |
| 两处存量 `buildMode` 修正 | T2 |
| 双平台验证 | T12 |
| probe fixture 更新 | T2 / T6 |
| 重新生成 notices | T2 / T10 |
| README 实现状态表更新 | T11 |

**无遗漏。**

**占位符扫描**：本文无 TBD / TODO / "实现细节略" / "参考上文"。每个代码步骤都给了完整代码。

**类型一致性**：`prepareMode` 取值在 T2（ENUM）、T4（不变量）、T5（`--plan`）、T6（materialized）、T8/T9（executor 的 `case`）中**逐字一致**：`source-build` / `tracked-prebuilt` / `install-only` / `none`。钩子名 `pe_install` / `pe_run_build` / `prepare_component` 在 T8 定义、T9 复用，签名一致。查询器输出格式 `<path>\t<prepareMode>` 在 T5 定义、T8/T9 的 `IFS=$'\t' read -r rel mode` 消费，一致。

**一处刻意的顺序**：T7（删 fail-open）排在 T8/T9（接 executor）**之前**——因为 executor 依赖 `--list`/`--plan` 的失败能真的传播上来；若消费者还吞着错，executor 拿到空计划会静默地什么都不做。
