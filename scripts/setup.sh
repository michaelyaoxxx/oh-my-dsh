#!/usr/bin/env bash
# setup.sh — 一键搭建本地 DSH 环境（源码运行，与 pin commit 一致）
# 幂等：可重复执行；依赖安装用 --frozen-lockfile，构建产物可覆盖重建。
# 约定：不依赖全局 pnpm（全局 10.x 与 harness pin 的 pnpm@11.7.0 major 不匹配），
#       统一走 corepack：每个仓库按其 package.json 的 packageManager 字段解析各自 pin 的 pnpm。
set -euo pipefail
cd "$(dirname "$0")/.."          # 主仓根

# ---------- 1. 工具链前置校验 ----------
if ! command -v node >/dev/null 2>&1; then
  echo "错误: 未找到 node。需要 Node.js ^22.19 || >=24（见 harness/package.json engines）。" >&2
  exit 1
fi
node -e 'const s=process.versions.node.split(".").map(Number);const ok=(s[0]===22&&s[1]>=19)||s[0]>=24;if(!ok){console.error("错误: Node 版本不满足 ^22.19 || >=24（harness engines），当前 "+process.versions.node);process.exit(1)}'

if ! command -v corepack >/dev/null 2>&1; then
  echo "错误: 未找到 corepack。Node.js >=25 已不再随发行版分发 corepack，可执行 npm install -g corepack 安装；其他版本请启用 Node.js ^22.19 || >=24 后重试（如 fnm use / nvm use）。" >&2
  exit 1
fi

# harness 的 pnpm build 会先跑 build:native-system（native/system/scripts/build.ts
# --host-addon-only），为**本机平台**编译 flock 的 Node-API 插件：需要 C 编译器和 Node
# 开发头文件。缺失时错误发生在构建深处且难以定位，故前置校验并给出可执行处置。
# 判定与 build 脚本一致：头文件相对可执行文件解析（dirname(process.execPath)/../include/node）。
if ! command -v cc >/dev/null 2>&1; then
  echo "错误: 未找到 C 编译器 cc。harness 构建需为本机平台编译原生插件（native/system）：macOS 执行 xcode-select --install；Debian/Ubuntu 安装 build-essential（musl 发行版需 musl-gcc）。" >&2
  exit 1
fi
if ! node -e 'const {dirname,resolve}=require("node:path");const h=resolve(dirname(process.execPath),"..","include","node","node_api.h");process.exit(require("node:fs").existsSync(h)?0:1)'; then
  echo "错误: 未找到 Node 开发头文件（node_api.h，位于 node 可执行文件同级的 ../include/node/）。harness 的原生插件构建需要它：官方 tarball / fnm / nvm 安装的 Node 自带；部分发行版包需另装 nodejs-dev 或 node-headers。" >&2
  exit 1
fi

# ---------- 2. 递归拉取/更新 submodule（插件目录不存在则创建，幂等） ----------
mkdir -p plugins
git submodule update --init --recursive
git submodule sync --recursive

# ---------- 3. 校验各仓库 pin 的 pnpm 能正确解析 ----------
# 期望值取自各仓库 package.json 的 packageManager 字段（不硬编码版本号，随 submodule pin 漂移）。
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
  # 若当前 node 目录下已有非 corepack 的 pnpm，corepack enable 会用 shim 替换它，先明确提示。
  PNPM_BIN="$(command -v pnpm 2>/dev/null || true)"
  NODE_BIN_DIR="$(dirname "$(command -v node)")"
  if [ -n "$PNPM_BIN" ] && [ "$(dirname "$PNPM_BIN")" = "$NODE_BIN_DIR" ] \
     && ! head -c 400 "$PNPM_BIN" | grep -qi 'corepack'; then
    echo "注意: 当前 node 目录（$NODE_BIN_DIR）下有非 corepack 的 pnpm（$(pnpm --version 2>/dev/null || echo 未知)），corepack enable 会将其替换为 corepack shim（shim 会按各仓库 packageManager 解析版本）。"
  fi
  if ! corepack enable; then
    echo "错误: corepack enable 失败。请手动执行 corepack enable（必要时加 sudo，或 corepack enable --install-directory <某目录> 并把该目录加入 PATH），然后重开终端重试。" >&2
    exit 1
  fi
  if ! verify_all_pnpm; then
    echo "错误: corepack enable 后仍无法解析 pin 的 pnpm。可能原因：网络不可达（corepack 需下载 pin 版本）；corepack 缓存（COREPACK_HOME）不可写或指向异常目录；corepack 的 pnpm shim 未在 PATH 中或未优先于全局 pnpm（which pnpm 应指向 node 安装目录下的 shim）。请排查后重开终端重试。" >&2
    exit 1
  fi
fi
for d in harness plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> ${d%/} 使用 pnpm@$(actual_pnpm "$d")"
done

# ---------- 4. harness：安装依赖 + 构建 ----------
# dsh CLI 的源码运行入口是 harness 根脚本 pnpm dsh（node --import tsx/esm apps/cli/src/bin.ts），
# 构建产物（apps/cli/lib 等）使其无需编译即可运行。
# harness 根 postinstall（scripts/install-lefthook.mjs）要在 git 公共 config 上启用
# extensions.worktreeConfig 并安装 lefthook hooks；但 harness 作为 submodule 时
# core.worktree 位于公共 config（.git/modules/harness/config），该脚本会拒绝迁移并让
# install 失败。submodule 的 hooks 本就不参与主仓提交，故按其自带开关 CI=true 跳过
# hooks 安装（该脚本是 harness 中唯一读取 CI 的 lifecycle 脚本，不影响其他 postinstall）。
# 注意: build（pnpm run build:lib/web）内部嵌套的 pnpm 调用会做 deps 校验并自动补跑
# pnpm install，必须让整个 harness 步骤都继承 CI=true（export），否则嵌套 install
# 会再次触发 lefthook postinstall 失败。
echo "==> 构建 harness"
( cd harness && export CI=true && pnpm install --frozen-lockfile && pnpm build )

# ---------- 5. 各插件：安装依赖 + 构建 ----------
#    dsh-web 是 pnpm workspace，自带 pnpm-lock.yaml → --frozen-lockfile 可行；
#    根 package.json 有 build（pnpm -r build）。
# 无 packageManager 的插件仓（如 dsh-plugin-mineru）corepack 在仓内向上找不到 pin 会回落
# latest（本机缓存的 12.3.4 已损坏）；统一经 harness 目录解析 harness pin 的 pnpm，--dir 让
# 命令仍在插件仓内执行（仓内 pnpm-workspace.yaml / lockfile 生效）。install 与 build 同此路径
# ——按调用点各写一遍判定曾漏掉 build，故收敛成一个入口。
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
# 包管理器选择：优先 pnpm（仓内有 pnpm-lock.yaml，或由 harness pin 兜底）。只有 npm 的
# package-lock.json 的仓（如 dsh-market，上游工具链就是 npm）改用 npm ci——用 pnpm 会忽略
# 该 lockfile（版本解析不可复现），并在仓内生成未跟踪的 pnpm-lock.yaml 弄脏 submodule。
# npm 随 node 分发，不存在 corepack 按 packageManager 解析的回落问题。
has_npm_lock() { [ -f "$1/package-lock.json" ]; }
plugin_run() { # 选定包管理器并在插件目录内执行：$1=目录，其余为命令与参数
  local d="$1"; shift
  if has_npm_lock "$d"; then
    ( cd "$d" && npm "$@" )
  else
    plugin_pnpm "$d" "$@"
  fi
}
# 依赖构建脚本放行策略：pnpm 11 默认拦截全部依赖构建脚本。声明了
# onlyBuiltDependencies/allowBuilds 的仓（better-sidebar 的 node-pty 等）正常安装；
# 未声明的仓（如 modlens）直接以 --ignore-scripts 安装——无声明即无脚本需要执行
# （esbuild 这类校验型 postinstall 不影响功能：平台二进制走 optionalDependencies）。
# 不能先做注定被拦截的普通安装再重试：被拦截的安装会留下 pendingBuilds 状态，使后续
# pnpm build 前自动重跑 install（corepack 在无 packageManager 的仓内回落坏版本必炸），
# 且 pnpm 会在仓内生成 approve-builds 脚手架（pnpm-workspace.yaml 模板）弄脏 submodule。
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

# 插件构建统一用短 TMPDIR。macOS 的 os.tmpdir() 是 /var/folders/<长哈希>/T（本次实测
# 某插件的 unix socket 路径因此达到 105 字节，超过 macOS sun_path 上限 104 → listen EINVAL）。
# /tmp 在 macOS 与 Linux 都存在且足够短；只作用于插件循环，不动 harness 构建。
export TMPDIR=/tmp

for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  if [ -f "$d/pnpm-lock.yaml" ]; then
    plugin_install "$d" install --frozen-lockfile
  elif has_npm_lock "$d"; then
    echo "==> ${d%/} 使用 npm（package-lock.json，可复现安装）"
    plugin_install "$d" ci
  else
    echo "注意: ${d%/} 无 pnpm-lock.yaml 也无 package-lock.json，将执行非冻结安装（pnpm install），可能在插件 submodule 内生成或改动文件（如 lockfile）。如需可复现安装，请在插件仓提交 lockfile。"
    plugin_install "$d" install
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

echo "setup 完成。运行 make dev 启动 DSH Web。"
