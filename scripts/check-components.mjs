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
//   node scripts/check-components.mjs --list ci:<scope> # 枚举 ciScope 含 <scope> 的组件路径
//   node scripts/check-components.mjs --list runtime    # 枚举 runtimeScope=required 的组件路径
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
  buildMode: ['source-build', 'prebuilt-verified', 'no-build'],
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
const REQUIRED_FIELDS = [
  'name', 'path', 'sourceAuthority', 'pinPolicy', 'pinRef',
  'ciScope', 'releaseScope', 'runtimeScope', 'platforms', 'buildMode',
  'packageManager', 'testProfile',
  // license 同样是必需字段：缺失会在生成的声明文件里留下空洞，而那是合规文档。
  'license',
]

const fail = (msg) => { console.error(`✗ ${msg}`); process.exitCode = 1 }

function loadCatalog() {
  let raw
  try {
    raw = JSON.parse(readFileSync(CATALOG, 'utf8'))
  } catch (e) {
    console.error(`✗ 无法解析 ${CATALOG}：${e.message}`)
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

function validate(catalog) {
  const { components } = catalog
  const seen = new Set()

  for (const c of components) {
    const where = c?.name ? `组件 ${c.name}` : '（无名组件）'
    for (const f of REQUIRED_FIELDS) {
      if (!(f in c)) fail(`${where} 缺字段 ${f}`)
    }
    for (const [field, allowed] of Object.entries(ENUM)) {
      const v = c[field]
      if (v === undefined) continue
      const values = Array.isArray(v) ? v : [v]
      for (const one of values) {
        if (!allowed.includes(one)) fail(`${where} 的 ${field} 取值非法: ${JSON.stringify(one)}（允许：${allowed.join(' / ')}）`)
      }
    }
    if (c.pinPolicy === 'tag' && c.pinRef.startsWith('refs/')) fail(`${where} tag pin 的 pinRef 不应带 refs/ 前缀`)
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

  const lic = checkLicenseDeclarations(components)

  if (!process.exitCode) {
    console.log(`✓ 组件目录校验通过：${components.length} 个组件，与 .gitmodules 双向一致`)
    console.log(`  （license 与组件自身声明核对：${lic.checked} 个一致；${lic.skipped} 个跳过——子仓未初始化或无 package.json）`)
    const excluded = components.filter((c) => c.runtimeScope === 'excluded')
    if (excluded.length) console.log(`  （runtimeScope=excluded：${excluded.map((c) => c.name).join(', ')}）`)
  }
  return !process.exitCode
}

function list(catalog, selector) {
  const [kind, value] = selector.includes(':') ? selector.split(':', 2) : ['runtime', selector]
  const hit = catalog.components.filter((c) => {
    if (kind === 'ci') return c.ciScope.includes(value)
    if (kind === 'runtime') return c.runtimeScope === value
    if (kind === 'release') return c.releaseScope.includes(value)
    console.error(`✗ 未知选择器 ${selector}（支持 ci:<scope> / release:<scope> / runtime）`)
    process.exit(1)
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
