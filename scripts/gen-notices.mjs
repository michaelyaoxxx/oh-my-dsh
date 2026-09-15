#!/usr/bin/env node
// gen-notices.mjs — 由组件目录生成 THIRD-PARTY-NOTICES.md
//
// **为什么生成而不是手写**：本仓有 11 个组件、4 种许可证，且组件集合会变。
// 手写的声明一定会漂移——本仓在 pin 清单上已经被同样的问题咬过（11 处手工复制的
// pin，见 AGENTS.md 的去漂移说明）。声明文件漂移的后果比 pin 更糟：它是**合规文档**，
// 写错了没人会发现。故：单一事实源（config/components.json）→ 生成。
//
// **为什么只读 components.json + .gitmodules，不读 submodule 内容**：
// 与 check-components.mjs 同一条理由——必须在 `make setup` **之前**可运行。
// 读子仓文件会在 CI 第一步就依赖「submodule 已初始化」，那是最脆弱的假设。
// （许可证与子仓自身声明的一致性由 check-components.mjs 校验，那是另一层。）
//
// 用法：
//   node scripts/gen-notices.mjs           # 生成/覆盖 THIRD-PARTY-NOTICES.md
//   node scripts/gen-notices.mjs --check   # 只校验磁盘上的文件是否最新（CI 用；过期则 exit 1）
//
// 退出码：0 通过；1 校验失败

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
// 复用 check-components.mjs 的**已校验** loader 与字段分类表。
// 本文件此前直连 JSON.parse，**不看 version**——实测（T2 评审）：version=1 时
// check-components.mjs 拒绝（rc=1），而本文件 rc=0 静默接受、照样生成。
// 这不只是"少一道检查"：schema 再升一版时字段会搬家，盲读旧结构的生成器会产出
// **看似正常**的合规文档——**静默的错，不是响的错**。而生成物是**对外**的那一份。
import { FIELD_CLASS, loadCatalogValidated } from './check-components.mjs'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'THIRD-PARTY-NOTICES.md')

// .gitmodules 的 name → url / path，再由 path 反查 url
function gitmodulesUrls() {
  const read = (re) =>
    execFileSync('git', ['config', '-f', '.gitmodules', '--get-regexp', re], { cwd: ROOT, encoding: 'utf8' })
      .split('\n')
      .filter(Boolean)
      .map((l) => {
        const [key, ...rest] = l.trim().split(/\s+/)
        return [key.split('.').slice(1, -1).join('.'), rest.join(' ')]
      })
  const nameToUrl = new Map(read('^submodule\\..*\\.url$'))
  const nameToPath = new Map(read('^submodule\\..*\\.path$'))
  const byPath = new Map()
  for (const [name, p] of nameToPath) byPath.set(p, nameToUrl.get(name) ?? '')
  return byPath
}

// 许可证 → SPDX 全称（表头用短名，正文用全称，便于非工程读者）
const FULL_NAME = {
  'MIT': 'MIT License',
  'Apache-2.0': 'Apache License 2.0',
  'AGPL-3.0': 'GNU Affero General Public License v3.0',
}

// ⚠️ 取全称必须用 Object.hasOwn，**不能**写成 `FULL_NAME[lic] ?? 兜底`。
// 理由是实测的、同 check-components.mjs 里 FIELD_CLASS / NAMED_SELECTORS 那两处：
// `FULL_NAME` 是对象字面量，下标访问会**沿原型链**查找，于是 `FULL_NAME['constructor']`
// 命中 Object 的构造器（**真值**）→ `??` 不触发兜底 → **把一个函数渲染进合规文档**。
// （`toString` / `valueOf` / `__proto__` 同理。）
// 诚实说明两点：① 本函数**没有**专门的防退化装置（G1 只 grep 免责字样，管不到这里）；
// ② 换了上面的 loadCatalogValidated 之后，license 已被 ENUM 约束，原型链名字**目前
// 到不了这里**——所以这是**纵深防御**，不是当前唯一的堵口。两者都别当成"已测"。
const fullNameOf = (lic) => (Object.hasOwn(FULL_NAME, lic) ? FULL_NAME[lic] : '（未登记全称）')

// ⚠️ 下列两列的免责标注（「声明，未验证」）**假定**它们在 FIELD_CLASS 里属于 declared 类。
// 分类若改了，标注就成了一句假话——而 G1 只 grep 一个字面串，**抓不住**这件事。
// 故显式断言、fail closed：生成物是**对外**的那一份，宁可不生成，也不生成一句不成立的话。
function assertDeclared(fields) {
  for (const f of fields) {
    if (!Object.hasOwn(FIELD_CLASS, f) || FIELD_CLASS[f] !== 'declared') {
      console.error(
        `✗ 生成物的免责标注假定 ${f} 属于 declared 类，但 FIELD_CLASS 里它是 ` +
          `${Object.hasOwn(FIELD_CLASS, f) ? JSON.stringify(FIELD_CLASS[f]) : '未登记'}。` +
          `标注与分类必须一致：要么同步改 render() 里那张表头，要么先改分类。`,
      )
      process.exit(1)
    }
  }
}

const cell = (s) => String(s).replace(/\|/g, '\\|')

function render(catalog, urls) {
  const { components } = catalog
  const L = []
  const p = (s = '') => L.push(s)

  p('# 第三方组件声明')
  p()
  p('本文件由 `node scripts/gen-notices.mjs` **自动生成**，请勿手工编辑——')
  p('改动会在 CI 的 `--check` 步骤被拒绝。要改内容请改 [config/components.json](config/components.json)。')
  p()
  p('## 本仓自身的许可')
  p()
  p('本仓库（superproject：`Makefile`、`scripts/`、`deploy/`、`patches/`、`config/`、`docs/`、`.github/`）')
  p('以 **Apache License 2.0** 授权，全文见 [LICENSE](LICENSE)。')
  p()
  p('## 本仓与下方组件的许可边界')
  p()
  p('本仓通过 **git submodule** 编排下列组件：每个组件在**自己的仓库里**携带自己的许可证，')
  p('本仓只固定其 commit（pin）。**LICENSE 的 Apache-2.0 不覆盖下列任何组件**，反之亦然。')
  p()
  p('> 曾出现的误解：因为本仓有 `LICENSE`，就以为整个 superproject（含 submodule 内容）都按它授权。')
  p('> 不是。gitlink 是指针，各子仓的授权只由其自身决定。')
  p()

  const excluded = components.filter((c) => c.runtimeScope === 'excluded')
  p('## 组件清单')
  p()
  // 免责**必须长在生成物上**，不能只活在 config/README.md 的字段字典里：
  // 读者拿到的是这一份（对外的那一份），用「来源」「进制品」这类**事实性表头**，
  // 他无从知道那些列只是 catalog 的声明值。分类只在别处可见 = 读者仍会误解。
  p('> ⚠️ **「来源」「进制品」「默认运行时」是 catalog 的声明值，未经校验。**')
  p('> 其中「进制品」对应的 `releaseScope` 目前**没有行为消费者**（制品链尚未实现）——')
  p('> 它记录意图，不构成保证。字段分类见 [config/README.md](config/README.md)。')
  p()
  p('| 组件 | 许可证 | 来源（声明，未验证） | 进制品（声明，未验证） | 默认运行时 |')
  p('| --- | --- | --- | --- | --- |')
  for (const c of components) {
    const rel = c.releaseScope.length ? c.releaseScope.join(', ') : '—'
    const run = c.runtimeScope === 'excluded' ? '**排除**' : '包含'
    const url = urls.get(c.path)
    const src = url ? `[\`${c.sourceAuthority}\`](${url})` : `\`${c.sourceAuthority}\``
    p(`| \`${c.name}\` | ${c.license} | ${src} | ${cell(rel)} | ${run} |`)
  }
  p()

  // 按许可证聚合
  const byLic = new Map()
  for (const c of components) {
    if (!byLic.has(c.license)) byLic.set(c.license, [])
    byLic.get(c.license).push(c)
  }
  p('## 按许可证聚合')
  p()
  for (const [lic, list] of [...byLic].sort()) {
    p(`### ${lic} — ${fullNameOf(lic)}`)
    p()
    p(`${list.length} 个组件：${list.map((c) => `\`${c.name}\``).join('、')}`)
    p()
  }

  // copyleft（AGPL/GPL）边界。规则与裁决理由见 docs/cicd/03-artifact-and-release.md §3.3。
  const COPYLEFT = ['AGPL-3.0', 'GPL-3.0']
  const copyleft = components.filter((c) => COPYLEFT.includes(c.license))
  const shipped = copyleft.filter((c) => c.releaseScope.length)
  p('## Copyleft 边界（AGPL / GPL）')
  p()
  if (!copyleft.length) {
    p('当前组件集合中**没有** AGPL/GPL 组件，制品不承载 copyleft 义务。')
  } else {
    p('以下组件为 copyleft 许可，按下列状态生效：')
    p()
    for (const c of copyleft) {
      const inRel = c.releaseScope.length ? `**进制品**（${c.releaseScope.join(', ')}）` : '不进制品'
      const inRun = c.runtimeScope === 'excluded' ? '不在默认运行时' : '**在默认运行时**'
      p(`- \`${c.name}\`（${c.license}）：${inRel}；${inRun}`)
    }
    p()
    if (!shipped.length) {
      p(`**当前没有任何 copyleft 组件进制品** —— 制品不承载 AGPL/GPL 义务。`)
      p()
      p('> 这一状态是**刻意维持**的：AGPL-3.0 与 Apache-2.0 只**单向**兼容——Apache-2.0 代码可以并入')
      p('> AGPL 作品，**反之不行**（Apache-2.0 的专利与赔偿条款对 AGPL 构成附加限制）。')
      p('> 因此一旦任何 AGPL 组件进入 bundle 制品，**整个制品实际只能按 AGPL-3.0 分发**，')
      p('> 其中所有 Apache-2.0 组件也随之被覆盖。改动 `releaseScope` 前须先过 ADR 与法务确认。')
    } else {
      p('> ⚠️ **有 copyleft 组件进制品，整个制品按该 copyleft 许可分发**：须附全文、提供完整')
      p('> 对应源码；AGPL 另触发 §13 的「网络交互用户可获取对应源码」义务。')
      p('> **对外分发前必须复核。**')
    }
  }
  p()
  p('## 重新生成')
  p()
  p('```sh')
  p('node scripts/gen-notices.mjs          # 覆盖本文件')
  p('node scripts/gen-notices.mjs --check  # 校验是否最新（CI 用）')
  p('```')
  p()

  return L.join('\n')
}

assertDeclared(['sourceAuthority', 'releaseScope'])

const catalog = loadCatalogValidated()
const expected = render(catalog, gitmodulesUrls())

if (process.argv.includes('--check')) {
  if (!existsSync(OUT)) {
    console.error('✗ THIRD-PARTY-NOTICES.md 不存在。运行 node scripts/gen-notices.mjs 生成。')
    process.exit(1)
  }
  const actual = readFileSync(OUT, 'utf8')
  if (actual !== expected) {
    console.error('✗ THIRD-PARTY-NOTICES.md 与组件目录不一致（内容已过期）。')
    console.error('  这是一份**合规文档**，过期即错误。运行以下命令重新生成并提交：')
    console.error('    node scripts/gen-notices.mjs')
    process.exit(1)
  }
  console.log('✓ THIRD-PARTY-NOTICES.md 与组件目录一致')
} else {
  writeFileSync(OUT, expected)
  console.log(`✓ 已生成 THIRD-PARTY-NOTICES.md（${catalog.components.length} 个组件）`)
}
