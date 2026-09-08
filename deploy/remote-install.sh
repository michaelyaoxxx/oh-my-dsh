#!/usr/bin/env bash
# remote-install.sh — 服务器侧安装（源码 rsync 到服务器后由 deploy-remote.sh 调用，勿在本地直接跑）
#
# 职责：在 Linux x86-64 服务器上完成 工具链校验 → harness/插件 依赖安装与构建 →
#       把可挂载的 bundle 包经 `dsh plugin --profile dsh add link:` 装进 profile dsh。
# 幂等：全新机器与增量更新均可重复执行；所有依赖都在服务器平台构建，
#       严禁从其他平台拷贝 node_modules。
#
# 供 scripts/deploy-remote.sh 消费的接口：
#   入口：rsync 完成后在服务器执行  sudo bash $DEPLOY_DIR/deploy/remote-install.sh
#         （DEPLOY_DIR 由 deploy-remote.sh 经环境变量传入）
#   部署目录：$DEPLOY_DIR（环境变量，默认 /opt/dsh；本脚本必须位于 $DEPLOY_DIR/deploy/ 下，否则报错退出）
#   退出码：0 成功；任何失败 1（set -euo pipefail）
#   成功标志：输出最后一行是「remote-install 完成」
#   配套 unit：本脚本按 $DEPLOY_DIR 渲染 deploy/dsh.service 模板（@DEPLOY_DIR@ 占位符）
#             并安装到 /etc/systemd/system/dsh.service；ExecStart 依赖本脚本保证的
#             /usr/local/bin/pnpm corepack shim
#   约定：$DSH_HOME=$DEPLOY_DIR/.dsh（与 deploy/dsh.service、本地 .dsh 约定一致），profile 名固定 dsh
set -euo pipefail

# ---------- 0. 部署目录与平台 ----------
cd "$(dirname "$0")/.."          # 主仓根（=$DEPLOY_DIR）
ROOT="$PWD"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/dsh}"
if [ "$ROOT" != "$DEPLOY_DIR" ]; then
  echo "错误: 部署目录必须是 ${DEPLOY_DIR}（当前为 ${ROOT}）。请将仓库 rsync 到 ${DEPLOY_DIR} 后重试（deploy-remote.sh 会经 DEPLOY_DIR 环境变量传入）。" >&2
  exit 1
fi
export DEPLOY_DIR
if [ "$(uname -s)" != "Linux" ]; then
  echo "错误: remote-install.sh 只能在 Linux 服务器上执行（当前 $(uname -s)）。请勿在本地直接运行。" >&2
  exit 1
fi

export DSH_HOME="$ROOT/.dsh"
PROFILE=dsh
cd "$ROOT"
[ -f harness/package.json ] || { echo "错误: 未找到 harness/package.json（rsync 内容不完整？）。" >&2; exit 1; }

# ---------- 1. 工具链前置校验（与 scripts/setup.sh 一致） ----------
if ! command -v node >/dev/null 2>&1; then
  echo "错误: 未找到 node。需要 Node.js ^22.19 || >=24（见 harness/package.json engines）。" >&2
  exit 1
fi
node -e 'const s=process.versions.node.split(".").map(Number);const ok=(s[0]===22&&s[1]>=19)||s[0]>=24;if(!ok){console.error("错误: Node 版本不满足 ^22.19 || >=24（harness engines），当前 "+process.versions.node);process.exit(1)}'

if ! command -v corepack >/dev/null 2>&1; then
  echo "错误: 未找到 corepack（随 Node.js 分发）。请安装 Node.js ^22.19 || >=24 后重试。" >&2
  exit 1
fi

# ---------- 2. 校验各仓库 pin 的 pnpm 能正确解析（不依赖全局 pnpm） ----------
# 期望值取自各仓库 package.json 的 packageManager 字段（不硬编码版本号，随 pin 漂移）。
expected_pnpm() {
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const m=p.packageManager||"";console.log(m.startsWith("pnpm@")?m.slice(5):m)' "$1/package.json"
}
actual_pnpm() {
  ( cd "$1" && pnpm --version 2>/dev/null || true )
}
check_pnpm() {
  local dir="$1" expected actual
  expected="$(expected_pnpm "$dir")"
  [ -n "$expected" ] || return 0   # 未声明 packageManager 的仓库跳过校验
  actual="$(actual_pnpm "$dir")"
  # expected 可能带 +sha512 后缀（corepack use 生成的 hash pin）；pnpm --version
  # 只输出版本号，比较前把后缀剥掉，避免对 hash pin 误报校验失败。
  [ "$actual" = "${expected%%+*}" ]
}
verify_all_pnpm() {
  local ok=1 d
  for d in harness plugins/*/; do
    [ -f "$d/package.json" ] || continue
    if ! check_pnpm "$d"; then
      echo "校验失败: ${d%/} 期望 pnpm@$(expected_pnpm "$d")（packageManager 字段），实际解析为 '$(actual_pnpm "$d")'。" >&2
      ok=0
    fi
  done
  return $(( 1 - ok ))
}

if ! verify_all_pnpm; then
  echo "==> pnpm 解析不正确，尝试启用 corepack（让每个仓库按 packageManager 解析各自 pin 的 pnpm）"
  if ! corepack enable; then
    echo "错误: corepack enable 失败。请手动执行 corepack enable（必要时加 sudo，或 corepack enable --install-directory <某目录> 并把该目录加入 PATH），然后重试。" >&2
    exit 1
  fi
  if ! verify_all_pnpm; then
    echo "错误: corepack enable 后仍无法解析 pin 的 pnpm。请确认 corepack 的 pnpm shim 在 PATH 中优先于全局 pnpm，然后重试。" >&2
    exit 1
  fi
fi

mkdir -p plugins "$DSH_HOME/profiles"

# ---------- 3. harness：安装依赖 + 构建（服务器平台，frozen-lockfile） ----------
# CI=true 原因与 scripts/setup.sh 相同：harness 作为 submodule 时其 postinstall
# （lefthook 安装）会因公共 config 的 core.worktree 拒绝迁移而让 install 失败；
# 按其自带开关 CI=true 跳过 hooks 安装。build 内部嵌套的 pnpm install 同样需要
# 继承 CI=true（export 到整个 harness 步骤），否则嵌套 install 会再次触发该失败。
echo "==> 构建 harness"
( cd harness && export CI=true && pnpm install --frozen-lockfile && pnpm build )

# ---------- 4. 各插件：安装依赖 + 构建（服务器平台产物） ----------
# 服务器侧构建硬性要求 --frozen-lockfile（可复现安装）。此处有意比 scripts/setup.sh
# 更严格：本地开发允许无 lock 的插件跑普通 install，服务器部署一律要求插件仓提交
# pnpm-lock.yaml，缺失直接失败（不静默降级为 unfrozen install）。
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  if [ ! -f "$d/pnpm-lock.yaml" ]; then
    echo "错误: 插件 ${d%/} 缺少 pnpm-lock.yaml，服务器侧构建要求 --frozen-lockfile 可复现安装。请在插件仓提交 lockfile 后重试。" >&2
    exit 1
  fi
  ( cd "$d" && pnpm install --frozen-lockfile )
  # 该插件是 monorepo 或需构建才可挂载时执行其 build
  if node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).scripts?.build?0:1)' "$d/package.json" 2>/dev/null; then
    echo "==> 构建插件: $d"
    ( cd "$d" && pnpm build )
  fi
done

# ---------- 5. pnpm 版本锚点（与 scripts/link-plugins.sh 机制一致） ----------
# dsh plugin 会在 profile 目录里 spawn pnpm，corepack 从该目录向上找 packageManager；
# $DEPLOY_DIR 根没有 package.json，corepack 会回落 latest。在 $DSH_HOME 放一个只含
# packageManager 的 package.json 作锚点，钉住 harness 使用的 pnpm 版本，并禁止回落。
PIN="$(node -p "require('$ROOT/harness/package.json').packageManager || ''")"
# corepack use 生成的 pin 可能带 +sha512 后缀；版本比较统一只比版本号部分，
# 防 hash pin 形式（pnpm@x.y.z+sha512.…）在字符串相等比较下失效。
PIN_NO_HASH="${PIN%%+*}"
ANCHORED="$(node -p "try{require('$DSH_HOME/package.json').packageManager||''}catch(e){''}" 2>/dev/null || true)"
# 缺 packageManager 与前置 pnpm 校验同语义（视为可跳过）：不写锚点、不报错，
# 避免把 "undefined" 写进 $DSH_HOME/package.json。
if [ -n "$PIN" ] && [ "${ANCHORED%%+*}" != "$PIN_NO_HASH" ]; then
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

# dsh CLI 只能从 harness 源码运行（根脚本 `pnpm dsh`；harness/node_modules/.bin 下
# 没有 dsh）。corepack 在 harness 目录内解析其钉住的 pnpm 版本。
dsh() {
  ( cd "$ROOT/harness" && CI=true pnpm dsh "$@" )
}

# ---------- 6. 服务入口 shim（供 deploy/dsh.service 使用） ----------
# systemd 的 ExecStart 要求绝对路径，unit 固定使用 /usr/local/bin/pnpm。
# corepack enable 只把 shim 放进 node 所在目录，这里确保 /usr/local/bin 下也有
# 一个能解析出 harness pin 版本的 pnpm（存在且版本正确则不动，幂等）。
# 无论 plugins/ 下有没有可挂载的 bundle，dsh.service 都要能启动，故放在挂载之前。
if ! ( cd harness && /usr/local/bin/pnpm --version 2>/dev/null | grep -qxF "${PIN_NO_HASH#pnpm@}" ); then
  PNPM_SHIM="$(command -v pnpm 2>/dev/null || true)"
  if [ -n "$PNPM_SHIM" ] && ln -sf "$PNPM_SHIM" /usr/local/bin/pnpm; then
    echo "已创建/更新 corepack pnpm shim: /usr/local/bin/pnpm -> $PNPM_SHIM"
  else
    echo "错误: 无法创建 /usr/local/bin/pnpm（deploy/dsh.service 的 ExecStart 依赖该路径）。请以 sudo 执行: sudo ln -sf \$(command -v pnpm) /usr/local/bin/pnpm" >&2
    exit 1
  fi
fi
NODE_DIR="$(dirname "$(command -v node)")"
case "$NODE_DIR" in
  /usr/bin|/usr/local/bin) ;;
  *) echo "警告: node 位于 ${NODE_DIR}，不在系统默认 PATH 中；systemd 启动 dsh.service 时可能找不到 node。" >&2 ;;
esac

# ---------- 7. 渲染并安装 systemd unit ----------
# deploy/dsh.service 是模板（@DEPLOY_DIR@ 占位符）：systemd 无法把 Environment= 变量
# 展开进 WorkingDirectory/ExecStart，故在服务器侧按 $DEPLOY_DIR 渲染真实 unit 后安装
# （服务器侧渲染可避免本地 sed 路径转义跨 ssh/sudo 多层 shell）。unit 落点
# /etc/systemd/system/dsh.service 不变。
UNIT_SRC="$ROOT/deploy/dsh.service"
[ -f "$UNIT_SRC" ] || { echo "错误: 未找到 deploy/dsh.service（rsync 内容不完整？）。" >&2; exit 1; }
sed "s|@DEPLOY_DIR@|${DEPLOY_DIR}|g" "$UNIT_SRC" > /etc/systemd/system/dsh.service \
  || { echo "错误: 渲染/安装 dsh.service 失败（写入 /etc/systemd/system/dsh.service 需要 root 权限）。" >&2; exit 1; }
echo "已渲染并安装 unit: /etc/systemd/system/dsh.service（DEPLOY_DIR=${DEPLOY_DIR}）"

# ---------- 8. 挂载 bundle：把可挂载的插件包以 link 装进 profile dsh ----------
# 机制与 scripts/link-plugins.sh 一致（同一套探测/筛选逻辑，服务器侧执行）：
# 可挂载候选 = plugins/*/ 根包或 packages/*/ 子包中声明了 dsh.bundle.patch 且 patch
# 落在自己包目录内的包；被其他候选依赖的候选（聚合包的家族成员）不单独挂载。
RAW=()
SUBDIRS=()
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  root_dir="${d%/}"
  # 插件仓若自带 scripts/link-profile.mjs（dsh-web 全家桶解析回退脚本），先按其
  # 官方流程执行，把家族包与外部依赖链进 $DSH_HOME/profiles/node_modules。
  # 该脚本写死 ~/.dsh 约定，用 HOME 重定向到服务器的 DSH_HOME；幂等可重跑。
  # 注意必须用绝对路径调用：link-profile.mjs 以 resolvePath(argv[1])===import.meta.url
  # 判定「直接执行」，相对路径在符号链接布局下会不匹配而静默跳过 main()。
  if [ -f "$d/scripts/link-profile.mjs" ]; then
    echo "==> 链接解析回退（$root_dir/scripts/link-profile.mjs → ${DSH_HOME}/profiles/node_modules）"
    HOME="$(dirname "$DSH_HOME")" node "$ROOT/$d/scripts/link-profile.mjs"
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
# bash 3.2 在 set -u 下展开空数组会报 unbound variable，用 + 形式防护（服务器 bash 4/5 同样兼容）。
for c in ${RAW[@]+"${RAW[@]}"}; do
  if own_patch "$c" ${SUBDIRS[@]+"${SUBDIRS[@]}"}; then
    CANDIDATES+=("$c")
  fi
done

[ "${#CANDIDATES[@]}" -gt 0 ] || {
  echo "提示: plugins/ 下没有找到可挂载的 bundle 包（需要 dsh.bundle.patch 声明）"
  echo "remote-install 完成"
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
  if printf '%s\n' "$DEP_NAMES" | grep -qxF "$name"; then
    SKIPPED+=("$name")
    continue
  fi
  echo "==> link $name <- $c"
  dsh plugin --profile "$PROFILE" add "link:$c"
  MOUNTED=$((MOUNTED + 1))
done

[ "${#SKIPPED[@]}" -gt 0 ] && echo "跳过 ${#SKIPPED[@]} 个家族成员（由挂载的聚合包带出本地构建）: ${SKIPPED[*]}"
echo "完成: 已挂载 ${MOUNTED} 个 bundle 到 profile ${PROFILE}（DSH_HOME=${DSH_HOME}）"

echo "remote-install 完成"
