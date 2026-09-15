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
//   node scripts/check-components.mjs --plan prepare    # **动作计划**：每行 <path>\t<prepareMode>
//
// `--require-materialized` 可与上面任一形式并用：它把 materialized 阶段的
// "子仓未初始化 ⇒ 跳过"变成**失败**（CI 与 release 用它，见 validate() 那段的说明）。
// ⚠️ 它**只对默认（validate）路径有效**：查询路径（--list / --plan）按设计只跑 catalog
//    阶段、不读子仓（见下方守卫那段），故 `--list prepare --require-materialized`
//    不会因"子仓没初始化"而失败。要严格校验就**别带** --list / --plan。
//
// 退出码：0 通过；1 校验失败（**含 --list / --plan**：两个查询入口都先校验再查询）

import { readFileSync, existsSync, realpathSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join, isAbsolute } from 'node:path'

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

// ⚠️ 警告走 **stderr**。stdout 是机器接口——`--list` / `--plan` 的输出被
// setup.sh / remote-install.sh **逐行解析**成路径与 prepareMode。警告混进 stdout
// 会被当成一个组件路径。人也一样：stdout 是结果，stderr 是评论。
const warn = (msg) => { console.error(`  ⚠️  ${msg}`) }

const SCHEMA_VERSION = 2

// ── 导出给其它 catalog 读取方的 loader：**两个**，用途不同，别混用 ─────────────
//
// 两者的差别是「要读懂」还是「要认证」：
//   loadCatalog()           → 只要求**能被理解**：JSON 可解析 + schema 版本相符 + 形状对。
//   loadCatalogValidated()  → 还要求**合法**：跑完整套不变量（ENUM / 双向集合 / 正交约束）。
//
// ⚠️ 选哪一个不是风格问题，会改变**门禁之间的耦合**，故按用途定：
//   · 生成物 / 合规文档（gen-notices.mjs）用 **validated**：它要把 license 之类的值
//     渲进对外文档，目录不合法时产出的一定是**看似正常**的错东西。
//   · 内容层门禁（check-licenses.mjs）用 **loadCatalog()**：它读的是 <组件>/LICENSE*
//     文件，**与目录的其余不变量无关**。若让它要求"目录完全合法"，它就会在 L1 拒绝的
//     任何目录上一起拒绝——两道门从此**耦合**。而 probe-license-gate.sh 的全部价值
//     就在于**分开**测这两道门（它头几行就写着"两道门分别判定，不合并成一列"）。
//     实测（本任务）：用 validated 时，夹具 A1（目录声明 GPL-3.0）的 L2 由 GAP 翻成
//     CAUGHT——那不是"内容层拦住了 copyleft"，而是"内容层拒绝工作"，矩阵会把前者
//     当成后者读。故这里是**分层**，不是放水：版本不符仍然直接拒绝。
export function loadCatalog() {
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

const REQUIRE_MATERIALIZED = process.argv.includes('--require-materialized')

// 从一个 package.json 里取出「本仓承诺会随 pin 一起交付」的入口文件清单。
// 只取**无通配符**的目标：带 * 的 exports 无法静态判定，不在本检查范围内。
//
// ⚠️ `./package.json` 这类子路径导出也在清单里（多数组件的 exports 都带它）。
//    它是**真的**会被 `require('<pkg>/package.json')` 加载的入口，且确实必须随 pin
//    交付，故对 tracked-prebuilt 那条不变量而言它是对的判据。
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

// 「会被构建覆盖的入口」≠ declaredEntries 的**全**集——两条规则问的不是同一件事：
//   · tracked-prebuilt 那条**不变量**问的是"fresh clone 上组件还能用吗" ⇒ **所有**声明入口
//     都算候选：package.json 缺了组件直接坏，它必须留在候选里。
//   · **本常量服务的警告**问的是"构建会**覆盖**哪个已跟踪文件" ⇒ 候选只有**构建产物**。
// package.json / cordis.patch.yml 是**人手维护的 manifest / 配置**，构建从不写它们：
// 把元数据算进来，就是对着**根本不会被弄脏**的组件喊狼来了——而一条喊狼来了的警告会被当成
// 噪音忽略，那它就等于没有（**实测快照** 2026-09-15、当时 11 个组件：不排除元数据时 6 个喊，
// 其中 3 个是假的。⚠️ 组件集合一变这组数字就漂，别当当前值用）。
// 故这里只保留**代码模块**（构建真正会 emit 的东西：.js / .mjs / .cjs / .jsx / .ts / .tsx /
// .d.ts——`.d.ts` 以 `ts` 结尾，故被同一条覆盖）。
// ⚠️ 别为了"少一个常量"把这段过滤并进 declaredEntries：那会让 tracked-prebuilt 那条**阻断**
//    规则不再检查 package.json，等于**悄悄放宽一条会拒人的规则**。两条规则的候选集**必须**
//    分开（E 组有用例分别钉住两边：不变量那边是 E1/E2，警告这边是 E7/E8）。
// 边界（有意）：非代码的构建产物（如 .css / .map）不在候选内——本仓当前没有这种声明入口，
// 真出现时按本节注释的理由扩展本常量，而不是退回"全入口集"。
const BUILDABLE_ENTRY = /\.(?:[cm]?js|jsx|[cm]?ts|tsx)$/

// ── 「这个入口被 git 跟踪吗」的判据：**三分**，不是布尔 ─────────────────────────
//
// 为什么不是布尔：`git ls-files` 有**两种**不同的失败——「确认没被跟踪」与「根本查不了」。
// 把它们并成一类，就是把**查不了说成坏了**（AGENTS.md 禁止的形态，只不过这次是
// **工具对用户**说的）。触发场景是实测的、不是假想：scripts/deploy-remote.sh 的 rsync 带
// `--exclude '.git'`，服务器树上**没有任何 git 元数据**；在那棵树上跑校验，旧实现输出
//
//   ✗ 组件 X 的 prepareMode=tracked-prebuilt，但声明的入口 lib/index.js
//     **未被 git 跟踪**——fresh clone 上该组件是坏的
//
// ——而那些文件**就在那儿**（rsync 过来的），只是 `git ls-files` 跑不了。
//
// ⚠️ 判据必须**具体**：只有「该目录**没有可用的** git 元数据」才算 unknown。
//    别写成"git 报错就当查不了"——那会把真正的"未被跟踪"也吞掉，而拦下它正是本检查
//    存在的理由（E1/E3 钉的就是"确认未被跟踪必须拒"）。
//
// **「没有可用的元数据」是两档，都要盖住**（漏掉第二档，它就会退化成"确认未被跟踪"，
// 于是又输出那句未经验证的"组件是坏的"）：
//   ① 根本没有 —— `.git` 不存在（rsync 出来的树；夹具 E9）
//   ② 有但**不可用** —— `.git` 是**文件**（子仓 / worktree 的 gitlink），内容形如
//      `gitdir: <path>`，而那个 path **不存在**（工作区被搬走后 `.git/modules` 那侧没跟过来、
//      或被清理）。夹具 E11。
// 判据取"`.git` 是目录（普通检出）/ 是文件且其 `gitdir:` 指向**存在**的东西"——
// 两条都是**可判定的具体事实**，不是"跑一下 git 试试看报不报错"。
const GIT_TRACKED = 'tracked'
const GIT_UNTRACKED = 'untracked'
const GIT_UNKNOWN = 'unknown'

// 解析 `.git` 指向的 git 目录；取不到（不存在 / 不是 gitlink 格式 / 目标不存在）返回 null。
// 边界（有意）：只判**存在性**，不验它是否真是一个完整的 git 目录（有没有 HEAD/objects）
// ——那会把判据变成"跑一下 git 试试"，正是本节开头禁止的形态。保守方向是安全的：
// 拿不准 ⇒ unknown ⇒ 计入 skipped，而**不会**去指控某个组件"坏了"。
function usableGitDir(dir) {
  const dotGit = join(dir, '.git')
  let st
  try {
    st = statSync(dotGit)
  } catch {
    return null // ① 根本没有元数据
  }
  if (st.isDirectory()) return dir // 普通检出：`.git` 就是目录本身
  let text
  try {
    text = readFileSync(dotGit, 'utf8') // ② 子仓 / worktree：`.git` 是 gitlink 文件
  } catch {
    return null
  }
  const m = /^gitdir:[ \t]*(.+?)[ \t]*$/m.exec(text)
  if (!m) return null // 文件在、但不是 gitlink 格式（写坏了）
  // 相对路径按 `.git` 文件**所在目录**解析——git 自己就是这么做的
  const target = isAbsolute(m[1]) ? m[1] : join(dir, m[1])
  return existsSync(target) ? target : null // 悬空 gitlink ⇒ 不可用
}

// 「能不能判」的唯一判据。组件级（跳过分类）与入口级（三态）共用它，
// 免得同一个事实写出两个副本（本仓一路在治的病）。
const hasUsableGitMetadata = (dir) => usableGitDir(dir) !== null

function trackedState(dir, rel) {
  if (!hasUsableGitMetadata(dir)) return GIT_UNKNOWN
  try {
    execFileSync('git', ['-C', dir, 'ls-files', '--error-unmatch', rel], { stdio: 'ignore' })
    return GIT_TRACKED
  } catch { return GIT_UNTRACKED }
}

// materialized 阶段：需要读子仓。子仓未初始化时**跳过并计数**——
// 本检查不得引入「先跑 make setup」的前置依赖。
// 但 --require-materialized 下，skip 本身即失败：CI 与 release 用它，
// 否则 fresh clone 上可以一项都不查就通过（fail-open）。
function checkMaterialized(components) {
  let checked = 0
  // ⚠️ **两类跳过分开计数**，因为成因不同、可执行的动作也不同。合成一条会逼出一句
  //    在某一类上**不成立**的话（"子仓未初始化"在 rsync 出来的服务器树上就是假的：
  //    树是完整的，缺的是 git 元数据）。与 tracked() 那条修的是同一件事：
  //    **不得把"查不了"说成某个具体结论**。
  const skipped = [] // 子仓未初始化 / 读不到 package.json
  const skippedNoGit = [] // 目录在、package.json 可读，但 git 元数据**没有或不可用**（如 rsync 出来的树、悬空 gitlink）
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
    // git 元数据缺失 ⇒ **与"子仓未初始化"同类**：计入 skipped，且**不得**据此宣称
    // 组件坏了（那些文件可能一个不少，只是 `git ls-files` 跑不了）。
    // 判据刻意放在 package.json 读成功**之后**：走到这里说明目录**在**，故"缺元数据"
    // 说的是一件确定的事，而不是"什么都没读到"。
    // ⚠️ 这个 `git` **只用于"跳过分类/已验计数"**，不用来给下面的判据当开关：
    //    那会是同一个事实的第二个副本，且会让 trackedState() 的第三态变成摆设。
    const git = hasUsableGitMetadata(dir)
    if (git) checked++
    else skippedNoGit.push(c.name)

    // 下面两条判据都不依赖 git（`source-build ⇒ 须有 scripts.build` 与子仓的 git 状态
    // 无关），故不因"另一个判据查不了"而一起放过——那才是 fail-open。
    // 「查不了」（GIT_UNKNOWN）时**不猜**：它既不算 tracked 也不算 untracked，
    // 于是两条判据都自然不生效，而该组件已经在上面的 skippedNoGit 里被记了一笔。
    if (c.prepareMode === 'tracked-prebuilt') {
      const entries = declaredEntries(pkg)
      if (!entries.length) {
        fail(`组件 ${c.name} 的 prepareMode=tracked-prebuilt，但其 package.json 未声明任何入口（main/types/exports）——无物可验`)
      }
      for (const e of entries) {
        if (trackedState(dir, e) === GIT_UNTRACKED) {
          fail(`组件 ${c.name} 的 prepareMode=tracked-prebuilt，但声明的入口 ${e} **未被 git 跟踪**——fresh clone 上该组件是坏的`)
        }
      }
    }
    if (c.prepareMode === 'source-build' && !pkg.scripts?.build) {
      fail(`组件 ${c.name} 的 prepareMode=source-build，但其 package.json 没有 scripts.build`)
    }
    // ADR-0005：这一条**不写成不变量，只报警告**——本仓可以出于供应链政策选择源码重建，
    // 即使子仓恰好也提交了产物。故**不调用 fail()**，不影响退出码。
    //
    // ⚠️ 判据必须用**全入口集**（declaredEntries）里的**构建产物**（BUILDABLE_ENTRY），
    //    **不能只查 main**：ADR 自己举的那个例子 dsh-market 的 main（lib/index.js）恰恰**未**被
    //    跟踪，被跟踪的是 exports["./client"] → ./client/client.js——只查 main 会把**唯一的
    //    例子**整个漏掉。也**不能**把声明的元数据（package.json / cordis.patch.yml）算进来：
    //    它们不是构建产物，算进来就是对不会被弄脏的组件喊狼来了（理由见 BUILDABLE_ENTRY）。
    if (c.prepareMode === 'source-build') {
      const dirtyable = declaredEntries(pkg).filter((e) => BUILDABLE_ENTRY.test(e) && trackedState(dir, e) === GIT_TRACKED)
      if (dirtyable.length) {
        warn(`组件 ${c.name} 是 source-build，但入口 ${dirtyable.join(', ')} 已被 git 跟踪——构建可能弄脏 submodule，进而触发部署的快照保真检查`)
      }
    }
  }
  const skippedAll = [...skipped, ...skippedNoGit]
  if (skippedAll.length && REQUIRE_MATERIALIZED) {
    fail(
      `--require-materialized：${skippedAll.length} 个组件无法在 materialized 阶段校验` +
        `（${skippedAll.join(', ')}）——严格模式下不允许跳过。` +
        `子仓未初始化的请先 make setup；git 元数据缺失或不可用的（如带 --exclude '.git' 的 rsync 树、悬空的 gitlink）须换到可用的检出上跑。`,
    )
  }
  return { checked, skipped, skippedNoGit }
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

// 供其它生成器复用的**已校验** loader。直连 JSON.parse 会让生成物
// 在目录非法时照样产出——而生成物是**对外**的那一份。
//
// 为什么导出的是「读 + 校验」而不是让调用方自己 `loadCatalog() + validateCatalog()`：
// 那是同一条不变量的两处副本，只改一边（如将来校验器改名/分阶段）就会让某个读取方
// **静默退回盲读**——正是本函数要治的病。读取方要的就是"一份合法目录"，给这一个入口。
//
// 失败即 `process.exit(1)`（**不是** return null）：调用方是 Bash / node 脚本，
// 它们只认退出码；返回 null 会诱使调用方 `?? {}` 兜底，那又把 fail-open 请回来了。
export function loadCatalogValidated() {
  const catalog = loadCatalog()
  if (!validateCatalog(catalog)) process.exit(1)
  return catalog
}

// validate() = catalog 阶段（上面那个）+ materialized 阶段（需读子仓的部分）。
// 为什么**不**把 checkLicenseDeclarations 也放进 validateCatalog：它读的是
// `join(ROOT, c.path, 'package.json')`——**子仓里**的文件，未初始化时读不到。
// 判据是「会不会读子仓」，不是「要不要联网」；`.gitmodules` 是**主仓**的文件，
// 故双向集合校验属于 catalog 阶段（config/README.md 的「两个阶段」表同此分法）。
function validate(catalog) {
  const { components } = catalog

  validateCatalog(catalog)

  const lic = checkLicenseDeclarations(components)
  const mat = checkMaterialized(components)

  if (!process.exitCode) {
    console.log(`✓ 组件目录校验通过：${components.length} 个组件，与 .gitmodules 双向一致`)
    console.log(`  （license 与组件自身声明核对：${lic.checked} 个一致；${lic.skipped} 个跳过——子仓未初始化或无 package.json）`)
    // 两类跳过的**成因不同**，故分行报。合成一句"子仓未初始化"会在 rsync 出来的
    // 服务器树上说一句不成立的话——那里树是全的，缺的只是 git 元数据。
    // 这一类**列出组件名**：在服务器树上可能一次跳掉大半个集合，使用者需要知道
    // **具体哪些没验**（只说个数字，等于把"没验"藏起来）。
    const noGit = mat.skippedNoGit.length
      ? `；${mat.skippedNoGit.length} 个因 git 元数据不可用而无法判定（${mat.skippedNoGit.join(', ')}）`
      : ''
    console.log(`  （materialized 检查：${mat.checked} 个已验；${mat.skipped.length} 个跳过——子仓未初始化${noGit}${REQUIRE_MATERIALIZED ? '（严格模式，跳过即失败）' : ''}）`)
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

// 「选择子 → 组件集合」的**唯一判定处**。`list()` 与 `plan()` 都必须走它。
//
// 为什么必须抽出来（而不是让各入口自己写过滤条件）：`NAMED_SELECTORS.prepare`
// （'runtime:required'）与 plan() 里曾经硬编码的 `runtimeScope !== 'required'`
// 是**同一条语义的两处副本**——只改一边，两个查询入口就**静默分歧**，而没有任何用例会红。
// 那正是本项目一路在治的形态（同一事实写两处 = 两个漂移点，见本文件 FIELD_CLASS 那段）。
// 抽成一处后，「改一处不会让两个入口分歧」是**结构上**成立的，不由注释保证。
// 防退化装置是 probe-catalog.sh 的 D10——它断言两个入口选出的**组件集合相等**。
function selectComponents(catalog, selector) {
  // ⚠️ 判据必须用 Object.hasOwn，**不能**写成 `NAMED_SELECTORS[selector] ?? selector`。
  // selector 来自 argv，是**用户可控**的；下标访问会在**原型链**上查找，于是
  // constructor / toString / __proto__ / valueOf / hasOwnProperty 命中的是
  // Object.prototype 上的函数——resolved 成了函数，下一行 `.includes` 抛**未捕获的**
  // `TypeError: resolved.includes is not a function`（裸堆栈，rc=1）。
  // 它 fail-closed（不会静默返回空集），故**不是安全洞**，但诊断形态很差：用户看到的是
  // 内部堆栈，而不是"这个选择器不存在"。与上面 FIELD_CLASS 那处是同一手法。
  const resolved = Object.hasOwn(NAMED_SELECTORS, selector) ? NAMED_SELECTORS[selector] : selector
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
  return catalog.components.filter((c) => {
    if (kind === 'ci') return c.ciScope.includes(value)
    if (kind === 'runtime') return c.runtimeScope === value
    return c.releaseScope.includes(value)
  })
}

function list(catalog, selector) {
  for (const c of selectComponents(catalog, selector)) console.log(c.path)
}

// --plan <named-selector>：输出**动作计划**而不只是路径。
//
// 为什么要输出动作而不只是路径：`--list prepare` 只统一了「准备哪些组件」这个**决策**。
// 若 setup 与 remote-install 各自实现一套 `case "$prepareMode"` 去决定**怎么准备**，
// 漂移只会从「选哪个字段」变成「怎么执行动作」——病没治好，换了个地方发作。
// 但**这仍然只是决策数据**：动作的**执行**必须共用同一个 executor（见 prepare-executor.sh）。
//
// 输出契约与 list() 相同：成功时 stdout **只有**机器接口本身（每行 `<path>\t<prepareMode>`），
// 失败走 stderr + 非 0。消费方按制表符切分，多一行摘要就会被当成组件路径读进去。
//
// 选哪些组件**不在这里判断**：走 selectComponents()，与 `--list prepare` 同源。
function plan(catalog, selector) {
  // 只认具名选择器：`--plan ci:test` 这类**在 --list 下合法但无动作定义**的选择器必须报错。
  // 静默输出空计划会被消费方读成「没有要准备的组件」——fail-open 的同一形态。
  if (selector !== 'prepare') {
    console.error(`✗ --plan 只支持具名选择器 prepare（收到 ${JSON.stringify(selector)}）`)
    process.exit(1)
  }
  for (const c of selectComponents(catalog, selector)) {
    console.log(`${c.path}\t${c.prepareMode}`)
  }
}

// 只有**直接运行本文件**时才执行参数分发；被 import 时只提供导出。
//
// 为什么必须分开：`check-licenses.mjs` / `gen-notices.mjs` 要复用上面的
// loadCatalogValidated()，而此前本文件是"顶层直接执行"的脚本——被 import 会连带
// 执行下面的参数分发（读 argv → 当成自己被传了参数 → 打印/退出），调用方拿到的是
// **另一个进程的行为**，而不是一个库。
//
// ⚠️ 判据必须比 **realpath**，不能只比字面路径——这不是洁癖，是实测的坑：
//    node 会把**模块 URL** 解析成真实路径，而 `process.argv[1]` 是调用方给的那一串。
//    macOS 上 `mktemp -d` 给的是 `/var/folders/...`，而 `/var` 是 `-> /private/var`
//    的 symlink，于是 `node "$PWD/scripts/check-components.mjs"`（**绝对**路径）下两者
//    逐字符不等 → 守卫把"直接运行"判成"被 import" → 脚本**什么都不做、rc=0**。
//    这正是 fail-open 的形态，而且是**静默**的：调用方拿到空集，会读成"没有要处理的组件"。
//    probe-catalog.sh 的 F2/F3 当场变红（消费方拿到空排除集，照样去挂载）。
//    ⚠️ 换成**相对**路径调用恰好不触发——所以这个坑按调用方式时好时坏，极易漏过。
//    （原方案是 `import.meta.url === pathToFileURL(process.argv[1]).href`，就栽在这里。）
//
// 判据取"两个 realpath 相等"，不用 `argv[1].endsWith('check-components.mjs')` 之类：
// 后者会把"恰好同名的另一个文件"也算成自己。
function isDirectRun() {
  const entry = process.argv[1]
  if (!entry) return false // `node -e` / REPL：没有入口脚本，当然不是"直接运行本文件"
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(entry)
  } catch {
    // realpath 取不到（路径不存在、权限不足）⇒ **判不了**。这里取"按直接运行处理"：
    // 宁可多跑一次校验，也不静默什么都不做。
    //
    // ⚠️ 如实说明这个选择的代价（评审实测过，别把它当成"安全的兜底"）：
    //    本分支当前**不可达**——能执行到这里，说明模块文件与 argv[1] 都真实存在。
    //    而一旦可达，两种走法**都会出错**，方向相反：
    //      · 判 false（当作被 import）⇒ CLI **静默 no-op、rc=0**。实测：强制走本分支、
    //        经 symlink 调用（argv[1] 与 realpath 字面不等）时正是这样，输出为空、
    //        rc=0 —— 调用方会把"拒绝工作"读成"没有要处理的组件"，是 **fail-open**。
    //      · 判 true（当作直接运行）⇒ 若真是 import，会**多跑一次参数分发**：
    //        多打几行摘要，或在 `--list` 下提前 exit 1。**响的错，不是静默的错。**
    //    本仓的取舍一贯是后者（fail closed：宁可响，不许静默放行），故不改成
    //    "字面比较"那种看着保守、实则会在 symlink 路径下静默 no-op 的写法。
    return true
  }
}

if (isDirectRun()) {
  const args = process.argv.slice(2)
  const catalog = loadCatalog()

  // 先校验再查询：`--list` 此前**直接查询、绕过 validate()**，于是一个字段非法的
  // catalog 能让查询器照常输出，调用方据此执行——正是 fail-open。
  // 这不是假想风险，实测过：把某个组件的 runtimeScope 改成非法值（如 "bogus"），修复前
  // `--list prepare` 的 rc=0 且 stdout 为空。而 deploy/remote-install.sh **没有**
  // setup.sh:212 那样的显式前置校验，直接 `PREPARE_LIST="$(node … --list prepare)"`，
  // 靠 `set -euo pipefail` + `$()` 传播退出码兜底——**这条链只在失败返回非 0 时才成立**。
  // 一旦 rc=0 而输出为空，PREPARE_LIST 就是空的 → 每个插件走「跳过」→
  // **部署"成功"却没装东西**。所以守卫必须在**分发之前**，且用 process.exit **立即**终止。
  //
  // ⚠️ 守卫**只作用于查询路径**。默认路径由 validate() 跑完整两阶段（catalog 阶段 +
  //    materialized 阶段），若在这里**无条件**先行退出，同一份 catalog 同时有 catalog 阶段
  //    错误与 license 不一致时只会报出**第一条**——用户得改一处、重跑、才看见下一处。
  //    rc 仍是 1（不是 fail-open），掉的是**诊断完整性**。
  //    两条路径的 ✗ 条数都是契约，各有夹具钉住：probe-catalog.sh 的 D11（默认路径 2 条）
  //    与 D12（查询路径 1 条——run_case 的唯一归因判据依赖它）。
  //    别把 process.exit(1) 改成 process.exitCode = 1：那会让查询路径也打印两遍 ✗。
  const wantsQuery = args.includes('--list') || args.includes('--plan')
  if (wantsQuery && !validateCatalog(catalog)) process.exit(1)

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
}
