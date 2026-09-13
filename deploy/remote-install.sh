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

# 不挂进本 profile 的包：dsh-tui 是**终端前端**（与 dsh-web-app 同级，cordis.patch.yml
# 覆盖 30 个 base 行），它同样声明了 dsh.bundle.patch，不排除会被下面的候选收集捞进来
# 挂到 profile dsh、把 web 环境弄坏。它跑在独立 profile，见 scripts/link-tui.sh。
SKIP_MOUNT=(plugins/dsh-tui)
cd "$ROOT"
[ -f harness/package.json ] || { echo "错误: 未找到 harness/package.json（rsync 内容不完整？）。" >&2; exit 1; }

# ---------- 1. 工具链前置校验（与 scripts/setup.sh 一致） ----------
if ! command -v node >/dev/null 2>&1; then
  echo "错误: 未找到 node。需要 Node.js ^22.19 || >=24（见 harness/package.json engines）。" >&2
  exit 1
fi
node -e 'const s=process.versions.node.split(".").map(Number);const ok=(s[0]===22&&s[1]>=19)||s[0]>=24;if(!ok){console.error("错误: Node 版本不满足 ^22.19 || >=24（harness engines），当前 "+process.versions.node);process.exit(1)}'

if ! command -v corepack >/dev/null 2>&1; then
  echo "错误: 未找到 corepack。Node >=25 已不再随发行版分发 corepack，可执行 npm install -g corepack 安装；Node <25 请安装/启用 Node.js ^22.19 || >=24 后重试。" >&2
  exit 1
fi

# harness 的 pnpm build 需为**服务器平台**编译原生插件（native/system 的 flock Node-API
# 插件）：需要 C 编译器与 Node 开发头文件。与 scripts/setup.sh 同校验；判定与 build 脚本
# 一致（头文件相对可执行文件解析）。
if ! command -v cc >/dev/null 2>&1; then
  echo "错误: 未找到 C 编译器 cc。harness 构建需为服务器平台编译原生插件：Debian/Ubuntu 执行 apt-get install -y build-essential（musl 发行版需 musl-gcc）。" >&2
  exit 1
fi
if ! node -e 'const {dirname,resolve}=require("node:path");const h=resolve(dirname(process.execPath),"..","include","node","node_api.h");process.exit(require("node:fs").existsSync(h)?0:1)'; then
  echo "错误: 未找到 Node 开发头文件（node_api.h，位于 node 可执行文件同级的 ../include/node/）。harness 的原生插件构建需要它：请改用自带头文件的 Node 发行版（官方 tarball / fnm / nvm），或另装 nodejs-dev / node-headers。" >&2
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
# 服务器侧硬性要求可复现安装：pnpm-lock.yaml 走 --frozen-lockfile，package-lock.json
# 走 npm ci；两者都没有则直接失败（不静默降级为 unfrozen install）。此处有意比
# scripts/setup.sh 更严格——本地开发允许无 lock 的插件跑普通 install。
# 无 packageManager 的插件仓（如 dsh-plugin-mineru）corepack 在仓内回落 latest 不可靠；
# 经 harness 目录解析 harness pin 的 pnpm（服务器上 corepack 同样按 harness packageManager
# 解析），--dir 让命令仍在插件仓内执行。install 与 build 同此路径——按调用点各写一遍判定
# 曾漏掉 build，故收敛成一个入口。
has_package_manager() {
  node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager?0:1)' "$1/package.json"
}
# pnpm 11 不再读 package.json 里的 pnpm.overrides（迁到 pnpm-workspace.yaml）。仍把 overrides
# 写在该位置、又没声明 packageManager 的仓（如 dsh-agent-teams），其 lockfile 由 pnpm 10 生成：
# pnpm 11 看到的 overrides 为空，frozen 安装被拒（ERR_PNPM_LOCKFILE_CONFIG_MISMATCH），且
# pnpm run 前的依赖校验会重新触发安装、让 build 也一并失败。此类仓回退用 pnpm 10——
# corepack 支持 `corepack pnpm@<version>`，无需仓内声明。版本可用 DSH_LEGACY_PNPM 覆盖。
LEGACY_PNPM="${DSH_LEGACY_PNPM:-10.33.0}"
has_package_json_overrides() { # 0 = overrides 写在 package.json 的 pnpm 字段（pnpm ≤10 的位置）
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.exit(p.pnpm&&p.pnpm.overrides?0:1)' "$1/package.json" 2>/dev/null
}
plugin_pnpm() {
  local d="$1"; shift
  if has_package_manager "$d"; then
    ( cd "$d" && pnpm "$@" )
  elif has_package_json_overrides "$d"; then
    echo "==> ${d%/} overrides 写在 package.json（pnpm ≤10 的位置），经 pnpm@${LEGACY_PNPM} 执行: pnpm $*"
    ( cd "$d" && corepack "pnpm@${LEGACY_PNPM}" "$@" )
  else
    echo "==> ${d%/} 无 packageManager，经 harness pin 的 pnpm 执行: pnpm $*"
    ( cd harness && pnpm --dir "../$d" "$@" )
  fi
}
# 与 scripts/setup.sh 同机制。包管理器选择：仓内有 pnpm-lock.yaml 用 pnpm；只有 npm 的
# package-lock.json 的仓（如 dsh-market）用 npm ci——两者都是可复现安装，服务器部署同样接受。
has_npm_lock() { [ -f "$1/package-lock.json" ]; }
plugin_run() { # 选定包管理器并在插件目录内执行：$1=目录，其余为命令与参数
  local d="$1"; shift
  if has_npm_lock "$d"; then
    ( cd "$d" && npm "$@" )
  else
    plugin_pnpm "$d" "$@"
  fi
}
# 与 scripts/setup.sh 同机制（预判 + 回退双层）：未声明 onlyBuiltDependencies/allowBuilds
# 的插件仓直接以 --ignore-scripts 安装（先做普通安装会留下 pendingBuilds 状态与
# approve-builds 脚手架）；声明了策略的仓正常安装，仍被拦截则回退 --ignore-scripts。
has_build_policy() { # 0 = 插件仓声明了依赖构建放行策略
  local d="$1"
  if [ -f "$d/pnpm-workspace.yaml" ] && grep -qE '^\s*(onlyBuiltDependencies|allowBuilds)\s*:' "$d/pnpm-workspace.yaml"; then
    return 0
  fi
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const b=p.pnpm||{};process.exit(b.onlyBuiltDependencies||b.allowBuilds?0:1)' "$d/package.json" 2>/dev/null
}
plugin_install() { # $1=目录 $2=安装子命令（pnpm 用 install，npm 用 ci），其后为额外参数
  local d="$1" cmd="$2"; shift 2
  local errfile ret scaffold_was=0 scaffold_tracked=0
  if ! has_build_policy "$d"; then
    echo "==> ${d%/} 未声明可构建依赖（无 onlyBuiltDependencies/allowBuilds），以 --ignore-scripts 安装"
    plugin_run "$d" "$cmd" "$@" --ignore-scripts
    return
  fi
  [ -e "$d/pnpm-workspace.yaml" ] && scaffold_was=1
  git -C "$d" ls-files --error-unmatch pnpm-workspace.yaml >/dev/null 2>&1 && scaffold_tracked=1
  errfile="$(mktemp)"
  # ERR_PNPM_IGNORED_BUILDS 打在 stdout 上（stderr 为空），必须合并两流才抓得到。
  if plugin_run "$d" "$cmd" "$@" >"$errfile" 2>&1; then
    rm -f "$errfile"
    return 0
  fi
  ret=$?
  if ! grep -q "ERR_PNPM_IGNORED_BUILDS" "$errfile"; then
    rm -f "$errfile"
    return "$ret"
  fi
  rm -f "$errfile"
  echo "==> ${d%/} 声明了构建策略但仍被 pnpm 拦截，以 --ignore-scripts 重试"
  plugin_run "$d" "$cmd" "$@" --ignore-scripts
  if [ "$scaffold_was" -eq 0 ] && [ "$scaffold_tracked" -eq 0 ] && [ -e "$d/pnpm-workspace.yaml" ]; then
    rm -f "$d/pnpm-workspace.yaml"
  fi
}

for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  if [ -f "$d/pnpm-lock.yaml" ]; then
    plugin_install "$d" install --frozen-lockfile
  elif has_npm_lock "$d"; then
    echo "==> ${d%/} 使用 npm（package-lock.json，可复现安装）"
    plugin_install "$d" ci
  else
    echo "错误: 插件 ${d%/} 既无 pnpm-lock.yaml 也无 package-lock.json，服务器侧构建要求可复现安装（--frozen-lockfile / npm ci）。请在插件仓提交 lockfile 后重试。" >&2
    exit 1
  fi
  # 入口文件已提交在仓库内的插件自带构建产物（pin 的一部分）→ 跳过 build：本地重建会因
  # 绝对路径哈希（如 CSS module 类名）产生与 pin 不同的产物，弄脏 submodule。源码形态的单包
  # 仓（入口未提交，如 dsh-better-sidebar）与 workspace 根（无 main，如 dsh-web）需要构建。
  main_entry="$(node -e 'const fs=require("fs");process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).main||"")' "$d/package.json")"
  if [ -n "$main_entry" ] && git -C "$d" ls-files --error-unmatch "${main_entry#./}" >/dev/null 2>&1; then
    echo "==> 跳过构建: ${d%/} 入口 ${main_entry} 已提交在仓库内"
  elif node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).scripts?.build?0:1)' "$d/package.json" 2>/dev/null; then
    echo "==> 构建插件: $d"
    # run build 而非裸 build：npm 只认 run，pnpm 两者等价
    plugin_run "$d" run build
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
  _skip=0
  for _s in ${SKIP_MOUNT[@]+"${SKIP_MOUNT[@]}"}; do [ "$root_dir" = "$_s" ] && _skip=1; done
  if [ "$_skip" = 1 ]; then
    echo "==> 跳过挂载: ${root_dir}（终端前端，属独立 profile）"
    continue
  fi
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

echo "remote-install 完成"
