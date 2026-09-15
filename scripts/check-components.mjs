#!/usr/bin/env node
// check-components.mjs — 组件目录（config/components.json）的校验与枚举
//
// 为什么是 .mjs + JSON 而不是 YAML：本脚本必须在 `make setup` **之前**可运行
// （CI 的第一步就是校验组件集合），而本仓无 yq、无 python3-yaml，js-yaml 只在
// harness/node_modules 里（未构建时不存在）。JSON 由 node 原生解析，零依赖。
//
// 与 .gitmodules 做**双向集合校验**——只校验清单里手工列出的项目是不够的：
// 漏列一个新 submodule，它在 CI 里就完全不可见（既不构建也不测试，还进 bundle）。
//
// 用法：
//   node scripts/check-components.mjs [--validate]      # 双向校验 + 字段校验（默认）
//   node scripts/check-components.mjs --list prepare    # 具名：需被"准备"（安装+构建）的组件
//   node scripts/check-components.mjs --list ci:<scope> # 枚举 ciScope 含 <scope> 的组件路径
//   node scripts/check-components.mjs --list runtime:<required|excluded>
//
// 退出码：0 通过；1 校验失败

import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CATALOG = join(ROOT, 'config/components.json')

// 受控词表：拼错一个 scope 会让该组件在 CI 里静默消失，故枚举取值。
const ENUM = {
  sourceAuthority: ['github', 'gerrit-fork'],
  pinPolicy: ['tag', 'branch'],
  ciScope: ['build', 'install', 'test', 'package', 'metadata'],
  releaseScope: ['bundle', 'sbom', 'provenance'],
  runtimeScope: ['required', 'excluded'],
  prepareMode: ['source-build', 'tracked-prebuilt', 'install-only', 'none'],
  platforms: ['linux-x86_64', 'macos-arm64'],
  // SPDX 标识符。两处**刻意的排除**，都会让登记人在此停下：
  //   · 不含 `unknown` —— 本字段进 THIRD-PARTY-NOTICES.md（合规文档），「unknown」在那里
  //     等于没写。本仓实测踩过：harness 长期记作 unknown，实为 MIT。
  //   · **不含 AGPL / GPL / LGPL —— 本仓不允许 copyleft 组件**（政策，2026-09-15）。
  //     copyleft 与 Apache-2.0 只**单向**兼容，一旦进场，**整个制品**都得按它分发。
  //     确有需要时先走 ADR 并显式改本表，不要在 patch / 装配脚本里绕过。
  // 其余新许可证请显式加进本表，别绕过。
  license: [
    'MIT', 'Apache-2.0',
    'BSD-2-Clause', 'BSD-3-Clause', 'ISC', 'MPL-2.0', 'Unlicense',
  ],
}

// 字段分类：**schema 级元数据**，不是组件的属性。
//
// 为什么不给每个组件加 `status` 标记：同一个事实在 10 个组件里重复 10 遍，
// 就是 10 个漂移点——正是本 ADR 要治的病。
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

// FIELD_CLASS 的**值**是受控词表。只查字段名、不查值，是**同一形态的 fail-open**：
// 登记了字段名却把类别拼成 'operationall'，会让 `FIELD_CLASS[f] === 'operational'`
// 这类消费者把它**静默当作「非 operational」**——分类失效，却不报错。
// 实测过：没有下面那段校验时，把一条值改成 'operationall' 仍然 rc=0 通过。
//
// derived 是**合法值**（权威源在别处，本目录不持有），虽然目前无字段使用——
// 别把它当成拼写错误删掉：那会让将来第一个 derived 字段无路可走。
const FIELD_CLASS_VALUES = ['operational', 'declared', 'derived']

const REQUIRED_FIELDS = [
  'name', 'path', 'sourceAuthority', 'pinPolicy', 'pinRef',
  'ciScope', 'releaseScope', 'runtimeScope', 'platforms', 'prepareMode',
  'testProfile',
  // license 同样是必需字段：缺失会在生成的声明文件里留下空洞，而那是合规文档。
  'license',
]

const fail = (msg) => { console.error(`✗ ${msg}`); process.exitCode = 1 }

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

// 主仓的 submodule 清单（不含 submodule 内部的嵌套 submodule —— 那些由各自仓管）
function gitmodulesPaths() {
  const out = execFileSync(
    'git', ['config', '-f', '.gitmodules', '--get-regexp', '^submodule\\..*\\.path$'],
    { cwd: ROOT, encoding: 'utf8' },
  )
  return out.split('\n').filter(Boolean).map((l) => l.trim().split(/\s+/).slice(1).join(' '))
}

// 组件目录里的 license 是**我们的声明**；组件自己的 package.json 是**它的声明**。
// 不一致时错的多半是我们：实测 harness 长期记作 unknown，而其 package.json 与
// LICENSE 都明确是 MIT。这个字段会进 THIRD-PARTY-NOTICES.md——一份合规文档，
// 错了没人会发现，所以必须有机器校验。
//
// 子仓未初始化 / 组件无 package.json 时**静默跳过**：本检查不引入「先跑 make setup」
// 的前置依赖（同 check-components.mjs 顶部那条设计约束）。
function checkLicenseDeclarations(components) {
  let checked = 0
  let skipped = 0
  for (const c of components) {
    if (!c.license) continue
    let pkg
    try {
      pkg = JSON.parse(readFileSync(join(ROOT, c.path, 'package.json'), 'utf8'))
    } catch {
      skipped++
      continue
    }
    const declared =
      pkg.license ??
      (Array.isArray(pkg.licenses) ? pkg.licenses.map((l) => l?.type).filter(Boolean).join(' OR ') : undefined)
    if (declared === undefined) {
      skipped++
      continue
    }
    checked++
    if (declared !== c.license) {
      fail(
        `组件 ${c.name} 的 license 不一致：组件目录=${c.license}，其 package.json=${declared}。` +
          `以组件自己的声明为准修正 config/components.json（该字段会进 THIRD-PARTY-NOTICES.md）。`,
      )
    }
  }
  return { checked, skipped }
}

// 校验 FIELD_CLASS **自身**（schema 级元数据），与组件数据无关，故在组件循环之前跑。
// 文案刻意与「字段名未登记」区分开：**这是两个不同错因**（名字没登记 vs 类别拼错），
// 合并成一条会把读者引去改错地方。
function checkFieldClassValues() {
  for (const [field, cls] of Object.entries(FIELD_CLASS)) {
    if (!FIELD_CLASS_VALUES.includes(cls)) {
      fail(
        `FIELD_CLASS 里字段 ${JSON.stringify(field)} 的**类别值**非法: ${JSON.stringify(cls)}。` +
          `允许：${FIELD_CLASS_VALUES.join(' / ')}。` +
          `（注意这**不是**"字段名未登记"——字段名已登记，是它的类别拼错了。）`,
      )
    }
  }
}

// ── catalog 阶段的校验：**只看组件目录即可判定** ─────────────────────────────
// 不读**子仓**（那要等 `make setup`）——故本函数在 fresh clone 上就能跑，
// CI 的第一步就是它。判据的单一事实源见 config/README.md 的「校验：两个阶段」。
//
// 抽成独立函数，是为了让**查询**入口也能复用它：`--list` / `--plan` 此前
// 直接查询、绕过 validate()，于是一个字段非法的目录照样能被消费，调用方据此
// 执行——正是 fail-open。两个入口都必须在查询之前跑它。
//
// ⚠️ 复用它的人**必须检查返回值/退出码**：校验失败时 stdout 是**空的**（✗ 走 stderr），
// 只看输出的消费方会把「拒绝工作」读成「没有需要处理的组件」——那是把 fail-open
// 搬了个地方。`setup.sh` 是先跑一次无参校验再 `--list`，那个顺序是对的。
//
// 成功时**不打印任何东西**：`--list` / `--plan` 的输出是**机器接口**
// （消费方 `IFS=$'\t' read` / 逐行取路径），stdout 多一行摘要就会被当成
// 组件路径读进去。失败仍走 fail()（→ stderr）。成功摘要留在 validate() 里。
//
// 返回 boolean，供调用方决定是否继续（fail closed）。
function validateCatalog(catalog) {
  const { components } = catalog
  const seen = new Set()

  checkFieldClassValues()

  for (const c of components) {
    const where = c?.name ? `组件 ${c.name}` : '（无名组件）'
    for (const f of REQUIRED_FIELDS) {
      if (!(f in c)) fail(`${where} 缺字段 ${f}`)
    }
    // ⚠️ 判据必须用 Object.hasOwn，**不能用 `f in FIELD_CLASS`**。
    // 理由是实测的、不是洁癖：`in` 会**沿原型链**查找，于是 Object.prototype 的**全部 12 个**
    // own property 名字（constructor / toString / hasOwnProperty / valueOf / __proto__ /
    // isPrototypeOf / propertyIsEnumerable / toLocaleString / __defineGetter__ / __defineSetter__ /
    // __lookupGetter__ / __lookupSetter__）会被判成"已登记分类"
    // 而**静默放行**——正好绕过本规则要拦的那件事，规则就没兑现它承诺的事。
    // 这不是理论风险：`constructor` / `toString` 是人会真取的字段名；且实测它们能一路
    // 穿过 `{...base, ...over}` + JSON 往返，作为**组件自己的键**进到这里。
    // 防退化装置是 probe-catalog.sh 的 B3/B4——改回 `in` 它们会立刻变红。
    for (const f of Object.keys(c)) {
      if (!Object.hasOwn(FIELD_CLASS, f)) {
        fail(
          `${where} 出现未登记分类的字段 ${JSON.stringify(f)}。` +
            `新增字段必须在 FIELD_CLASS 里声明它是 operational 还是 declared（见 config/README.md）。`,
        )
      }
    }
    for (const [field, allowed] of Object.entries(ENUM)) {
      const v = c[field]
      if (v === undefined) continue
      const values = Array.isArray(v) ? v : [v]
      for (const one of values) {
        if (!allowed.includes(one)) fail(`${where} 的 ${field} 取值非法: ${JSON.stringify(one)}（允许：${allowed.join(' / ')}）`)
      }
    }
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
    if (seen.has(c.path)) fail(`组件路径重复: ${c.path}`)
    seen.add(c.path)
  }

  // 双向集合校验
  const inCatalog = new Set(components.map((c) => c.path))
  const inGitmodules = new Set(gitmodulesPaths())

  for (const p of inGitmodules) {
    if (!inCatalog.has(p)) fail(`.gitmodules 有 ${p}，但组件目录未收录（该 submodule 会脱离 CI 视野：不构建、不测试，却仍可能进 bundle）`)
  }
  for (const p of inCatalog) {
    if (!inGitmodules.has(p)) fail(`组件目录有 ${p}，但 .gitmodules 未收录（组件已被移除？请同步删除该条）`)
  }

  return !process.exitCode
}

// validate() = catalog 阶段（上面那个）+ materialized 阶段（需读子仓的部分）。
//
// 为什么**不**把 checkLicenseDeclarations 也放进 validateCatalog：它读的是
// `join(ROOT, c.path, 'package.json')`——**子仓里**的文件，未初始化时读不到。
// 判据是「会不会读子仓」，不是「要不要联网」；`.gitmodules` 是**主仓**的文件，
// 故双向集合校验属于 catalog 阶段（config/README.md 的「两个阶段」表同此分法）。
function validate(catalog) {
  const { components } = catalog

  validateCatalog(catalog)

  const lic = checkLicenseDeclarations(components)

  if (!process.exitCode) {
    console.log(`✓ 组件目录校验通过：${components.length} 个组件，与 .gitmodules 双向一致`)
    console.log(`  （license 与组件自身声明核对：${lic.checked} 个一致；${lic.skipped} 个跳过——子仓未初始化或无 package.json）`)
    const excluded = components.filter((c) => c.runtimeScope === 'excluded')
    if (excluded.length) console.log(`  （runtimeScope=excluded：${excluded.map((c) => c.name).join(', ')}）`)
  }
  return !process.exitCode
}

// 具名选择器：把「这个语义该读哪个字段」编码在**唯一一处**，供所有消费者共用。
//
// 为什么需要它：本仓出过一个 P0——`setup.sh` 用 `--list ci:install` 判断「要不要
// 安装这个插件」，而 `ciScope` 表达的是**CI job 参与范围**：绝大多数插件只声明
// `build/test/package`，于是被整批跳过（6 个 required 插件）；同时
// `remote-install.sh` 又完全不过滤。**同一份目录，两个消费者给出相反解释。**
// 根因不是"某个脚本写错了选择器"，而是**字段语义没有定义处**——所以在这里定义。
const NAMED_SELECTORS = {
  // 需要在本地/服务器上被"准备"（安装依赖 + 按需构建）的组件。
  // 驱动字段是 runtimeScope（"是否属于我们的运行时组合"），**不是** ciScope。
  prepare: 'runtime:required',
}

function list(catalog, selector) {
  const resolved = NAMED_SELECTORS[selector] ?? selector
  const [kind, value] = resolved.includes(':') ? resolved.split(':', 2) : [resolved, undefined]
  if (!['ci', 'runtime', 'release'].includes(kind)) {
    console.error(`✗ 未知选择器 ${selector}。具名：${Object.keys(NAMED_SELECTORS).join(' / ')}；或 ci:<scope> / release:<scope> / runtime:<required|excluded>`)
    process.exit(1)
  }
  // 缺值必须**报错**，不能静默返回空集：`--list runtime` 曾因此悄悄不匹配任何
  // 组件，而调用方把空集当成「没有需要处理的组件」——正是 fail-open 的形态。
  if (!value) {
    console.error(`✗ 选择器 ${selector} 缺少取值（如 runtime:required）。不支持"列出全部"——那会被误用成"全部都处理"。`)
    process.exit(1)
  }
  const hit = catalog.components.filter((c) => {
    if (kind === 'ci') return c.ciScope.includes(value)
    if (kind === 'runtime') return c.runtimeScope === value
    return c.releaseScope.includes(value)
  })
  for (const c of hit) console.log(c.path)
}

const args = process.argv.slice(2)
const catalog = loadCatalog()
const li = args.indexOf('--list')
if (li !== -1) {
  const sel = args[li + 1]
  if (!sel) { console.error('✗ --list 需要一个选择器，如 ci:test'); process.exit(1) }
  list(catalog, sel)
} else {
  validate(catalog)
}
