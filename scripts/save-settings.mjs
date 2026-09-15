#!/usr/bin/env node
/**
 * save-settings.mjs — 统一处理所有插件「自定义参数」的持久化（seed / save / 门禁）
 *
 * 事实源：config/plugin-configs/catalog.json。每行登记一个插件的配置仓：
 *   live     运行态文件路径（支持 $DSH_HOME / $HOME 展开）
 *   baseline 仓库内版本化基线文件名（config/plugin-configs/ 下）
 *   format   yaml | json（决定 save 时如何回写、seed 时是否需要头部保护）
 *   managedHeader  仅 yaml：基线 marker 之上的头部说明为手工区，save 只重写内容区
 *   secretPolicy   env-ref：秘密值允许 ${ENV}/裸环境变量名（apiKeyEnv 形态）
 *                  none：基线 / live 中秘密键不许出现非空字面值（密钥走运行时环境变量）
 *   chmod    可选的落盘权限（如 modsearch 的 0600）
 *
 * 用法：
 *   node scripts/save-settings.mjs list                       # 列出登记的插件配置仓
 *   node scripts/save-settings.mjs seed [id...]               # 缺失才铺基线，绝不覆盖 live
 *   node scripts/save-settings.mjs save [id...]               # (默认) live → 基线，带 secret 门禁
 *
 * `make link-plugins` / `deploy/remote-install.sh` 会先跑 seed：首次搭建 / 清空运行时 /
 * 服务器部署即恢复与仓库一致的插件参数；用户之后在 UI/CLI/文件里改的内容永远优先。
 * `make save-settings` 跑 save：把运行时参数固化回基线，走正常 review 提交。
 *
 * 设计取舍（每插件一文件 vs 合并一文件）：DSH 的 settings.yaml 本身就是「一个文档多个
 * 命名空间」的合并模型，走 ctx.settings 的插件（deepseek 官方 + 第三方）共用
 * dsh-settings.yaml 这一个基线文件；有独立配置仓的插件（如 modsearch 的
 * ~/.modsearch/config.json）各自一个基线文件——格式、live 路径、secret 语义都不同，
 * 强行合并会失真。catalog 把它们统一到一个调度面，脚本对外开放面不变。
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import os from 'node:os'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CONFIG_DIR = join(ROOT, 'config', 'plugin-configs')
const CATALOG = join(CONFIG_DIR, 'catalog.json')
const MARKER = '# >>> managed by make save-settings'

/** DSH 默认 .dsh（与 link-plugins.sh 的 DSH_HOME 缺省一致）。 */
const DSH_HOME = process.env.DSH_HOME || join(ROOT, '.dsh')

/** 秘密键：命中即按 secretPolicy 校验值形态。 */
const SECRET_KEY = /api[_-]?key|apikey|token|secret|passwd|password|bearer/i

/**
 * 校验并装载 catalog，fail-closed：版本或条目形状未知就拒绝。
 * @returns {Array<object>} 插件基线登记列表
 */
function loadCatalog() {
  if (!existsSync(CATALOG)) return null        // 环境态：本仓未配置插件参数基线 → 空操作，非错误
  const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'))
  if (catalog.version !== 1) {
    throw new Error(`save-settings: 不认识的 catalog version ${catalog.version}（本脚本只认 1）`)
  }
  if (!Array.isArray(catalog.plugins)) {
    throw new Error('save-settings: catalog 缺 plugins 数组')
  }
  for (const entry of catalog.plugins) {
    if (!entry.id || !entry.live || !entry.baseline || !entry.format || !entry.secretPolicy) {
      throw new Error(`save-settings: catalog 条目 ${entry.id ?? '<无 id>'} 缺必填字段`)
    }
    if (entry.format !== 'yaml' && entry.format !== 'json') {
      throw new Error(`save-settings: catalog 条目 ${entry.id} 的 format=${entry.format} 无效（yaml|json）`)
    }
    if (entry.secretPolicy !== 'env-ref' && entry.secretPolicy !== 'none') {
      throw new Error(`save-settings: catalog 条目 ${entry.id} 的 secretPolicy=${entry.secretPolicy} 无效（env-ref|none）`)
    }
  }
  return catalog.plugins
}

/** 展开 live 路径模板里的 $DSH_HOME / $HOME。 */
function expandLive(template) {
  return template
    .replaceAll('$DSH_HOME', DSH_HOME)
    .replaceAll('$HOME', process.env.HOME || os.homedir())
}

/**
 * 一个值的形态是否被 secret 门禁放行。
 * @param {string} value 键后的原始值（去引号前）
 * @param {'env-ref'|'none'} policy
 */
function isAllowedValue(value, policy) {
  let v = value.trim()
  if (v.endsWith(',')) v = v.slice(0, -1).trim()               // JSON 末尾逗号
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
    v = v.slice(1, -1).trim()
  }
  if (v === '' || v === 'null' || v === '~' || v === 'None' ||
      /^(true|false)$/i.test(v) || /^-?\d+(?:\.\d+)?$/.test(v)) return true
  if (policy === 'none') return false                          // 例：modsearch 基线不携带任何密钥
  if (/^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/.test(v)) return true    // ${ENV}
  if (/^[A-Z][A-Z0-9_]*$/.test(v)) return true                 // 裸环境变量名（apiKeyEnv 形态）
  return false
}

/**
 * 扫描文本里形如 `<key>: <value>` 的标量行（YAML 与缩进 JSON 通用），
 * key 命中秘密键且值不被门禁放行时记为违规。
 * @returns {string[]} 违规行（带行号）
 */
function secretViolations(text, policy) {
  const bad = []
  const lineRe = /^(\s*)"?([A-Za-z0-9_.-]+)"?(?=\s*:)\s*:\s*(.*)$/
  text.split(/\r?\n/).forEach((line, index) => {
    const m = lineRe.exec(line)
    if (!m || !SECRET_KEY.test(m[2])) return
    if (!isAllowedValue(m[3], policy)) bad.push(`  ${line}  （第 ${index + 1} 行）`)
  })
  return bad
}

/** 从 live 取「内容体」：若来自 seed 而带 marker/头部，剥掉只留顶层映射内容。 */
function bodyFromLive(text) {
  let body = text
  const i = body.indexOf(MARKER)
  if (i !== -1) body = body.slice(body.indexOf('\n', i) + 1)
  if (!body.endsWith('\n')) body += '\n'
  return body
}

/** seed：每项目标的 live 缺失时才从基线铺（绝不覆盖已有 live），并做基线门禁。 */
function seed(ids, plugins) {
  let ok = true
  for (const entry of plugins) {
    if (ids.length > 0 && !ids.includes(entry.id)) continue
    const live = expandLive(entry.live)
    if (existsSync(live)) {
      console.log(`  seed: ${entry.id}: 已存在 ${live}，跳过（绝不覆盖 live）`)
      continue
    }
    const base = join(CONFIG_DIR, entry.baseline)
    if (!existsSync(base)) {
      console.log(`  seed: ${entry.id}: 基线缺失 ${base}，跳过该插件（其余继续——seed 是补铺，不让单条缺席拖垮整体）`)
      continue
    }
    const violations = secretViolations(readFileSync(base, 'utf8'), entry.secretPolicy)
    if (violations.length > 0) {
      console.error(`  seed: ${entry.id}: 基线含疑似字面密钥，拒绝 seed（密钥请走环境变量/apiKeyEnv）：\n${violations.join('\n')}`)
      ok = false
      continue
    }
    mkdirSync(dirname(live), { recursive: true })
    writeFileSync(live, readFileSync(base))
    if (entry.chmod) chmodSync(live, parseInt(entry.chmod, 8))
    console.log(`  seed: ${entry.id}: ${live}（自 ${entry.baseline}${entry.chmod ? `，chmod ${entry.chmod}` : ''}）`)
  }
  return ok
}

/** save：live → baseline（yaml 只重写 marker 内容区、保留头部；全体先过门禁）。 */
function save(ids, plugins) {
  let ok = true
  for (const entry of plugins) {
    if (ids.length > 0 && !ids.includes(entry.id)) continue
    const live = expandLive(entry.live)
    if (!existsSync(live)) {
      console.log(`  save: ${entry.id}: 无 live 文件 ${live}，跳过`)
      continue
    }
    const raw = readFileSync(live, 'utf8')
    const violations = secretViolations(raw, entry.secretPolicy)
    if (violations.length > 0) {
      console.error(`  save: ${entry.id}: live 含疑似字面密钥，拒绝导出（密钥走环境变量/apiKeyEnv，别进版本库）：\n${violations.join('\n')}`)
      ok = false
      continue
    }
    const dst = join(CONFIG_DIR, entry.baseline)
    if (entry.format === 'json') {
      writeFileSync(dst, raw)                                   // JSON 无注释，整文件替换
    } else {
      const body = bodyFromLive(raw)
      let out = body
      if (existsSync(dst)) {
        const current = readFileSync(dst, 'utf8')
        const j = current.indexOf(MARKER)
        if (j !== -1) out = current.slice(0, j) + MARKER + '\n' + body  // 保留基线头部说明
      }
      writeFileSync(dst, out)
    }
    console.log(`  save: ${entry.id}: ${dst}`)
  }
  return ok
}

/** 列出登记项，便于审计与新增。 */
function list(plugins) {
  console.log('config/plugin-configs/catalog.json 登记的插件配置仓：')
  for (const entry of plugins) {
    console.log(`  ${entry.id.padEnd(14)} format=${entry.format}  live=${entry.live}`)
    console.log(`    baseline=${entry.baseline}  secretPolicy=${entry.secretPolicy}${entry.chmod ? `  chmod=${entry.chmod}` : ''}  ${entry.desc ?? ''}`)
  }
}

const [subcommand, ...ids] = process.argv.slice(2)
const command = subcommand ?? 'save'

let plugins
try {
  plugins = loadCatalog()
} catch (error) {
  console.error(String(error.message ?? error))
  process.exit(2)
}
if (plugins === null) {
  const verb = command === 'list' ? '无可列出' : '无事可做'
  console.log(`save-settings: 未找到 ${CATALOG}——本仓未配置插件参数基线，${verb}（rc=0）`)
  process.exit(0)
}

let ok = true
if (command === 'seed') {
  ok = seed(ids, plugins)
} else if (command === 'save') {
  ok = save(ids, plugins)
} else if (command === 'list') {
  list(plugins)
} else {
  console.error(`save-settings: 未知子命令 ${command}（seed | save | list）`)
  process.exit(2)
}
process.exit(ok ? 0 : 1)

