#!/usr/bin/env node
// check-licenses.mjs — 组件**许可证文件**内容检查（copyleft 门禁）
//
// 与 check-components.mjs 的分工（两者互补，不重叠）：
//   check-components.mjs → 目录**声明**层：license 词表 + 与组件自身 package.json 的一致性
//   check-licenses.mjs   → 组件**内容**层：真的去读 <组件>/LICENSE* 文件，判它是不是 copyleft
//
// 为什么需要这一层：实测（scripts/probe-license-gate.sh）证明，只有声明层时，
// 「package.json 与目录都写 MIT，但 LICENSE 文件是 GPL」**完全拦不住**——
// 而那是比改声明字段更省事的投毒方式。
//
// ── 判定策略（刻意的取舍）────────────────────────────────────────────────────
// **只判「是不是 copyleft」，不判「是哪个许可证」。** 识别全文（MIT vs BSD vs Apache）
// 容易误判；识别 copyleft 特征串很稳。我们只关心「有没有 copyleft」，所以够用。
//
// **命中任一特征串即失败**：AGPL 全文里**含** "GNU GENERAL PUBLIC LICENSE" 字样，
// 所以不区分 AGPL/GPL，命中即拒——方向偏严，对门禁是正确的偏向。
//
// **认不出来放行（fail-open），认得是 copyleft 必拒（fail-closed）**：反过来会把
// dsh-web 那种首行为空行的 Apache 文本误伤（实测其 LICENSE 第一行就是空的）。
//
// **找不到许可证文件 = 警告，不阻断**：很多组件只在 package.json 里声明许可证，
// 那已由 check-components.mjs 覆盖。但「文件缺失」本身值得提醒——它是未决问题。
//
// ⚠️ 扫描范围**只限组件目录内的许可证文件**，绝不全文扫仓库：本仓的政策文档
// （如本文件、docs/cicd/03-artifact-and-release.md）**自己就写着这些字样**，
// 全仓扫会自己命中自己。
//
// 不覆盖（已知缺口，见 probe 的 B2/B3）：
//   · 源码里**内嵌**的 GPL 代码（没有声明头时任何静态检查都难认）
//   · **依赖树**（node_modules）里的 GPL —— 属制品门禁，见 docs/cicd/03-artifact-and-release.md §11
//
// 用法：
//   node scripts/check-licenses.mjs          # 门禁：发现 copyleft 即 exit 1
//   node scripts/check-licenses.mjs --list   # 只列判定结果，恒 exit 0
//
// 退出码：0 通过；1 发现 copyleft

import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
// 复用 check-components.mjs 的 loader，而不是自己 JSON.parse：本文件此前直连
// readFileSync，**不看 version**——schema 再升一版时字段会搬家，而它会照旧结构读，
// 产出**看似正常**的结果（静默的错，不是响的错）。实测（T2 评审）：version=1 时
// check-components.mjs 拒绝（rc=1），而本文件 rc=0 静默接受。
//
// ⚠️ 这里刻意用 loadCatalog()（**schema 门槛**）而不是 loadCatalogValidated()（**全套不变量**），
//    理由是**别把两道门耦合起来**，不是放水：
//      · 本文件（L2 内容层）读的是 <组件>/LICENSE* 文件，与目录的其余不变量无关；
//      · 若要求"目录完全合法"，它会在 L1 拒绝的**任何**目录上一并拒绝——而
//        probe-license-gate.sh 的全部价值就是**分开**测这两道门（"不合并成一列"）。
//        实测（本任务）：用 validated 时夹具 A1（目录声明 GPL-3.0，ENUM 必然拒绝）的
//        L2 由 GAP 翻成 CAUGHT——那不是"内容层拦住了 copyleft"，而是"内容层拒绝工作"，
//        覆盖矩阵会把前者当成后者读，等于在**证据文件**里写下一句不成立的话。
//      · 版本不符 / 形状不对 ⇒ 仍然直接拒绝（这正是那条威胁模型：看不懂的目录不许照读）。
//    两处的分工见 check-components.mjs 里那两个 export 的注释。
import { loadCatalog } from './check-components.mjs'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

// 许可证文件的常见命名。按此顺序取**第一个存在的**——同一个仓里有多个时，
// 取到的应该是主许可证（LICENSE 优于 COPYING 优于 LICENCE）。
const LICENSE_NAMES = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'COPYING', 'COPYING.md']

// copyleft 特征串（大小写不敏感）。命中任一即判为 copyleft。
// 覆盖：GPL v1-v3、LGPL（含旧名 Library GPL）、AGPL、GFDL。
const COPYLEFT_MARKERS = [
  'GNU AFFERO GENERAL PUBLIC LICENSE',
  'GNU LESSER GENERAL PUBLIC LICENSE',
  'GNU LIBRARY GENERAL PUBLIC LICENSE',
  'GNU GENERAL PUBLIC LICENSE',
  'GNU FREE DOCUMENTATION LICENSE',
]

const isCopyleft = (text) => {
  const upper = text.toUpperCase()
  return COPYLEFT_MARKERS.find((m) => upper.includes(m)) ?? null
}

function licenseFileOf(componentDir) {
  for (const name of LICENSE_NAMES) {
    const p = join(componentDir, name)
    if (existsSync(p)) return { name, path: p }
  }
  // 没有标准名时，退一步找任何以 LICENSE/LICENCE/COPYING 开头的文件
  try {
    const hit = readdirSync(componentDir).find((f) => /^(LICEN[CS]E|COPYING)/i.test(f))
    if (hit) return { name: hit, path: join(componentDir, hit) }
  } catch {
    /* 目录不存在（submodule 未初始化）——由调用方按 existsSync 处理 */
  }
  return null
}

const catalog = loadCatalog()
const listOnly = process.argv.includes('--list')
let failed = 0
const warnings = []

console.log(`==> 许可证内容检查（${catalog.components.length} 个组件，读各自的 LICENSE 文件）`)
for (const c of catalog.components) {
  const dir = join(ROOT, c.path)
  if (!existsSync(dir)) {
    console.log(`  ?   ${c.name}：目录不存在（submodule 未初始化？）`)
    continue
  }
  const f = licenseFileOf(dir)
  if (!f) {
    warnings.push(`${c.name}：找不到许可证文件（目录声明为 ${c.license}）`)
    console.log(`  !   ${c.name}：无许可证文件（目录声明 ${c.license}）`)
    continue
  }
  const text = readFileSync(f.path, 'utf8')
  const marker = isCopyleft(text)
  if (marker) {
    failed++
    console.error(`  ✗   ${c.name}：${f.name} 命中 copyleft 特征串「${marker}」`)
    console.error(`        目录声明为 ${c.license}，但许可证文件不是宽松许可——本仓不接纳 copyleft。`)
  } else {
    console.log(`  ok  ${c.name}：${f.name}（目录声明 ${c.license}）`)
  }
}

if (warnings.length) {
  console.log(`\n警告（${warnings.length} 条，不阻断）：无许可证文件不等于有问题，但属未决项——`)
  for (const w of warnings) console.log(`  · ${w}`)
}

if (!listOnly && failed) {
  console.error(`\n✗ ${failed} 个组件的许可证文件是 copyleft，本仓不接纳（政策见 docs/cicd/03-artifact-and-release.md §3.3）。`)
  process.exit(1)
}
if (listOnly) {
  console.log('\n（--list 模式：仅列出，不作为门禁）')
} else {
  console.log('\n✓ 未发现 copyleft 许可证文件')
}
