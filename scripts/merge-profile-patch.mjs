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
