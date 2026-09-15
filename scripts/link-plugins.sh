#!/usr/bin/env bash
# link-plugins.sh — 把 plugins/* 中可挂载的 bundle 包以 link 模式装进 DSH profile dsh（开发热更）
#
# 机制：`dsh plugin --profile dsh add link:<绝对路径>` 是 pnpm 转发器，会在 profile
# 目录（$DSH_HOME/profiles/dsh）里执行 `pnpm add link:<path>`，随后把声明了
# dsh.bundle.patch 的依赖同步进 package.json 的 dsh.profile.bundles 层列表。
# link: 协议装成符号链接，改插件源码即时生效，重复运行幂等。
#
# 可挂载候选：plugins/*/ 根包或 packages/*/ 子包中，声明了 dsh.bundle.patch 且
# patch 文件落在自己包目录内的包。dsh-web 根包的 patch 指向
# packages/dsh-web-all/cordis.patch.yml（包外），所以根包不是可挂载入口，
# 其聚合包 @linxin666/dsh-web-all 才是——与 dsh-web 官方开发文档一致。
# 被其他候选依赖的候选（聚合包的家族成员）不单独挂载：聚合包的 link: 会通过它
# 自己的 node_modules（workspace 链接）带出本地构建产物。独立发布的 bundle
# （如 @linxin666/dsh-client-ui-session-id）照常挂载。
#
# 插件仓若自带 scripts/link-profile.mjs（dsh-web 全家桶解析回退脚本），先按其
# 官方流程执行，把家族包与外部依赖链进 $DSH_HOME/profiles/node_modules。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PROFILE=dsh
export DSH_HOME="${DSH_HOME:-$ROOT/.dsh}"

# 不挂进本 profile 的包 —— 由**组件目录**派生（runtimeScope=excluded），不再硬编码：
# 谁进运行时由 config/components.json 说了算，避免「目录说不用、脚本却还在挂」的漂移。
# 例：dsh-tui 是终端前端，与 dsh-web-app 同级（覆盖 30 个 base 行），两个前端会抢同一批
# 行；它同样声明了 dsh.bundle.patch，不排除就会被候选收集捞进来挂到 profile dsh。
# 注意：这里用 --list runtime:excluded 直接给路径，故无需再拼 plugins/ 前缀。
# 不吞错：目录查询失败必须让脚本失败。此前用 `2>/dev/null || true`，解析失败会
# 退化为**空排除列表**——而"空列表"的含义是"没有任何组件被排除"，与失败正好相反。
# 这正是本脚本最需要目录保护的地方：dsh-tui 是唯一 runtimeScope=excluded 的组件，
# 排除集一空，它就会被下面的候选收集捞进来挂到 profile dsh、把 web 环境弄坏
# （同 deploy/remote-install.sh 里「不挂进本 profile 的包」那段注释——它写着同一件
#  "把 web 环境弄坏"的后果。**刻意不写行号**：行号会随注释增删漂移，本项目已为此踩过多次。）
# ADR-0005：高风险消费者不得 fail open。
# ⚠️ 必须用 $() 显式捕获并判 rc：`done < <(cmd)` **拿不到** cmd 的退出码
#    （进程替换的状态被丢弃），只删掉 `|| true` 只会让错误从"静默"变成"stderr 有字"，
#    脚本照样带着空排除集往下跑——实测过，别改回去。
if ! _excluded="$(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded)"; then
  echo "错误: 组件目录查询失败（原因见上）。link-plugins 拒绝在未知的排除集上继续。" >&2
  exit 1
fi
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done <<< "$_excluded"

# dsh plugin 在 profile 目录里 spawn `pnpm`，corepack 从该目录向上找
# packageManager。本仓根没有 package.json，corepack 会回落 latest（pnpm 12.x 的
# bin 布局与本机 Node 的 corepack 不兼容）。在 $DSH_HOME 放一个只含 packageManager
# 的 package.json 作锚点，钉住 harness 自己使用的 pnpm 版本。
[ -f "$ROOT/harness/package.json" ] && [ -d "$ROOT/harness/node_modules" ] || {
  echo "错误: harness 未构建，先运行 make setup" >&2
  exit 1
}
PIN="$(node -p "require('$ROOT/harness/package.json').packageManager || ''")"
[ -n "$PIN" ] || {
  echo "错误: harness/package.json 缺少 packageManager 字段，无法确定 pnpm 版本锚点。" >&2
  exit 1
}
# corepack use 生成的 pin 可能带 +sha512 后缀；版本比较统一只比版本号部分。
PIN_NO_HASH="${PIN%%+*}"
# 锚点在缺失或版本变化时都重写（harness pin bump 后保持跟随），重复运行幂等。
ANCHORED="$(node -p "try{require('$DSH_HOME/package.json').packageManager||''}catch(e){''}" 2>/dev/null || true)"
if [ "${ANCHORED%%+*}" != "$PIN_NO_HASH" ]; then
  mkdir -p "$DSH_HOME"
  node -e '
    const fs = require("fs")
    fs.writeFileSync(process.argv[1] + "/package.json",
      JSON.stringify({ name: "dsh-home", private: true, packageManager: process.argv[2] }, null, 2) + "\n")
  ' "$DSH_HOME" "$PIN"
  echo "已写入 pnpm 版本锚点: $DSH_HOME/package.json ($PIN)"
fi
# 锚点意外丢失时宁可报错也不回落 latest。
export COREPACK_DEFAULT_TO_LATEST=0

# dsh CLI 只能从 harness 源码运行（根脚本 `pnpm dsh`，harness/node_modules/.bin 下
# 没有 dsh）。corepack 在 harness 目录内解析其钉住的 pnpm 版本。
# CI=true 与 setup.sh 同理：harness 作为 submodule 时其 postinstall（lefthook 安装）
# 会因公共 config 的 core.worktree 拒绝迁移而失败，按 harness 自带开关跳过 hooks 安装。
dsh() {
  ( cd "$ROOT/harness" && CI=true pnpm dsh "$@" )
}

# 反向收敛：**已挂载但现已 excluded** 的包。
# 本脚本原本只做「跳过添加」，从不摘除——某个组件从 required 改成 excluded 后，profile
# 里上一轮留下的 link 仍在，于是组件目录说「不进运行时」而实际照样被加载。这正是本仓
# 反复被咬的「配置一套、实际一套」，且**覆盖面很广**：dsh-tui 就属 excluded，
# 未来把任何组件改判 excluded 都会踩到。
# 故这里做**幂等摘除**：excluded 即「不属于本 profile」，留在里面就是错的。
#
# 摘除走 `dsh plugin --profile <p> remove <name>` —— `plugin` 子命令把参数**逐字转发给
# profile 目录里的 pnpm**（harness/apps/cli/src/args.ts:190 的 help 明列 remove），
# 是官方支持的路径，不是我们自己摸黑改 package.json。
PROFILE_PKG="$DSH_HOME/profiles/$PROFILE/package.json"
if [ -f "$PROFILE_PKG" ]; then
  for _s in ${SKIP_MOUNT[@]+"${SKIP_MOUNT[@]}"}; do
    # 按**路径后缀**匹配而非解析符号链接：profile 里的 link: 值就是 <ROOT>/<相对路径>，
    # 后缀比对对 ROOT 是否含符号链接都不敏感。包名也从这里取，因而**不依赖**该
    # submodule 是否已初始化（excluded 组件可能本就没拉下来）。
    _stale="$(node -e '
      const p = require(process.argv[1])
      const rel = process.argv[2]
      for (const [name, v] of Object.entries(p.dependencies ?? {})) {
        if (String(v).replace(/^link:/, "").endsWith("/" + rel)) { console.log(name); break }
      }
    ' "$PROFILE_PKG" "$_s")"
    [ -n "$_stale" ] || continue
    echo "==> 摘除 ${_stale}（${_s} 声明 runtimeScope=excluded，却仍挂在 profile ${PROFILE} 中）"
    dsh plugin --profile "$PROFILE" remove "$_stale"
  done
fi

# 收集原始候选：根包 + packages/*/ 子包中声明了 dsh.bundle.patch 的包。
RAW=()
SUBDIRS=()
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  root_dir="${d%/}"
  _skip=0
  for _s in ${SKIP_MOUNT[@]+"${SKIP_MOUNT[@]}"}; do [ "$root_dir" = "$_s" ] && _skip=1; done
  if [ "$_skip" = 1 ]; then
    # 理由不写死在这里：excluded 的原因不止一种（如 dsh-tui 是终端前端、跑独立 profile）。
    # 原因写在组件目录的 notes 里，那里是事实源。
    echo "==> 跳过挂载: ${root_dir}（runtimeScope=excluded，原因见 config/components.json）"
    continue
  fi
  # 聚合包经 link: 挂载时 pnpm 不装它的依赖，而 loader 从 profile 目录解析 patch 行
  # 名（如 '@linxin666/dsh-i18n'、'dsh-better-sidebar'）。官方方案是把全家桶链进
  # profiles/node_modules 作解析回退（dsh-web 自带 scripts/link-profile.mjs 写死
  # ~/.dsh 约定，用 HOME 重定向到本仓的 DSH_HOME；幂等可重跑）。该脚本对任何带有
  # 它的插件仓无条件执行：解析回退链是聚合包可挂载的前提，与候选筛选结果无关。
  if [ -f "$d/scripts/link-profile.mjs" ]; then
    # HOME 重定向要求 DSH_HOME 形如 <目录>/.dsh（~ 即其父目录），否则静默落错位置。
    case "$DSH_HOME" in
      */.dsh) ;;
      *) echo "错误: DSH_HOME（${DSH_HOME}）不是 <目录>/.dsh 形状，无法用 HOME 重定向 link-profile.mjs 写死的 ~/.dsh 约定。" >&2
         exit 1 ;;
    esac
    echo "==> 链接解析回退（$root_dir/scripts/link-profile.mjs → ${DSH_HOME}/profiles/node_modules）"
    HOME="$(dirname "$DSH_HOME")" node "$d/scripts/link-profile.mjs"
  fi
  if node -e '
    const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
    process.exit(p.dsh?.bundle?.patch ? 0 : 1)
  ' "$d/package.json"; then
    RAW+=("$ROOT/$root_dir")
  fi
  for sub in "$d"packages/*/; do
    [ -f "$sub/package.json" ] || continue
    sub_dir="${sub%/}"
    # 所有子包目录都进入 containment 防护（不限于声明 patch 的子包候选）：
    # 根包 patch 指向任何子包目录都属退化配置，一律排除，防止漏判挂载。
    SUBDIRS+=("$ROOT/$sub_dir")
    if node -e '
      const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
      process.exit(p.dsh?.bundle?.patch ? 0 : 1)
    ' "$sub/package.json"; then
      RAW+=("$ROOT/$sub_dir")
    fi
  done
done

# 候选是否可挂载：patch 必须落在自己包目录内，且不落在任何子包目录内（SUBDIRS
# 为全部 packages/*/ 子包）。dsh-web 根包的 patch 指向
# packages/dsh-web-all/cordis.patch.yml（子包目录内），因此根包不是可挂载入口
# ——dsh-web-all 才是，与官方开发文档一致。
own_patch() { # $1: 候选目录；其余: 全部子包目录
  local dir="$1"
  shift
  node -e '
    const fs = require("fs"), path = require("path")
    const dir = process.argv[1]
    const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"))
    const patch = pkg.dsh?.bundle?.patch
    if (!patch) process.exit(1)
    const abs = path.resolve(dir, patch)
    const rel = path.relative(dir, abs)
    if (rel === "" || rel.startsWith("..")) process.exit(1)
    for (const o of process.argv.slice(2)) {
      if (o === dir) continue
      const r = path.relative(o, abs)
      if (r !== "" && !r.startsWith("..")) process.exit(1)
    }
    process.exit(0)
  ' "$dir" "$@"
}

CANDIDATES=()
# bash 3.2（macOS 自带）在 set -u 下展开空数组会报 unbound variable，用 + 形式防护。
for c in ${RAW[@]+"${RAW[@]}"}; do
  if own_patch "$c" ${SUBDIRS[@]+"${SUBDIRS[@]}"}; then
    CANDIDATES+=("$c")
  fi
done

[ "${#CANDIDATES[@]}" -gt 0 ] || {
  echo "提示: plugins/ 下没有找到可挂载的 bundle 包（需要 dsh.bundle.patch 声明）"
  exit 0
}

# 被其他候选依赖的候选（家族成员）不单独挂载——聚合包的 link: 会带出本地构建。
# 依赖名覆盖 dependencies/peerDependencies/optionalDependencies 三种声明，
# 只查 dependencies 会漏掉以 peer 形式声明的家族成员。
DEP_NAMES=""
for c in "${CANDIDATES[@]}"; do
  DEP_NAMES+="$(node -e "
    const p = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))
    const deps = { ...(p.dependencies ?? {}), ...(p.peerDependencies ?? {}), ...(p.optionalDependencies ?? {}) }
    console.log(Object.keys(deps).join('\n'))
  " "$c/package.json")"
  DEP_NAMES+=$'\n'
done

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

# patches/*.yml（repo 内 versioned 的用户 patch 片段，如 disable web-ui-better-sidebar）
# 幂等合并进 profile 的 cordis.patch.yml：挂载结果与托管 patch 同时生效。
node "$ROOT/scripts/merge-profile-patch.mjs" "$DSH_HOME/profiles/$PROFILE"

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

[ "${#SKIPPED[@]}" -gt 0 ] && echo "跳过 ${#SKIPPED[@]} 个家族成员（由挂载的聚合包带出本地构建）: ${SKIPPED[*]}"
echo "完成: 已挂载 ${MOUNTED} 个 bundle 到 profile ${PROFILE}（DSH_HOME=${DSH_HOME}）"
