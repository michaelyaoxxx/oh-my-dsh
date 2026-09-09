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
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  # 无 packageManager 的插件仓（如 dsh-plugin-mineru）corepack 在仓内向上找不到 pin
  # 会回落 latest（本机 corepack 缓存的 latest 已坏，必炸）；统一经 harness 目录解析
  # harness pin 的 pnpm 执行（--dir 让它在插件仓内安装，仓内 pnpm-workspace.yaml 生效）。
  if node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).packageManager?0:1)' "$d/package.json"; then
    if [ -f "$d/pnpm-lock.yaml" ]; then
      ( cd "$d" && pnpm install --frozen-lockfile )
    else
      echo "注意: ${d%/} 无 pnpm-lock.yaml，将执行非冻结安装（pnpm install），可能在插件 submodule 内生成或改动文件（如 lockfile）。如需可复现安装，请在插件仓提交 pnpm-lock.yaml。"
      ( cd "$d" && pnpm install )
    fi
  else
    echo "==> ${d%/} 无 packageManager，经 harness pin 的 pnpm 安装"
    if [ -f "$d/pnpm-lock.yaml" ]; then
      ( cd harness && pnpm --dir "../$d" install --frozen-lockfile )
    else
      ( cd harness && pnpm --dir "../$d" install )
    fi
  fi
  # 该插件是 monorepo 或需构建才可挂载时执行其 build
  if node -e 'const fs=require("fs");process.exit(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).scripts?.build?0:1)' "$d/package.json" 2>/dev/null; then
    echo "==> 构建插件: $d"
    ( cd "$d" && pnpm build )
  fi
done

echo "setup 完成。运行 make dev 启动 DSH Web。"
