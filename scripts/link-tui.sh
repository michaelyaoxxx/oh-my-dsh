#!/usr/bin/env bash
# link-tui.sh — 把 dsh-tui（终端前端）挂进独立 profile tui
#
# 为什么不走 link-plugins.sh：dsh-tui 是**终端前端**，与 `@deepseek-ai/dsh-web-app` 同级。
# 它的 cordis.patch.yml 覆盖 30 个 base 行（system-prompt / llm-deepseek / agent-loop /
# 工具 / 策略…），两个前端塞进同一 profile 会抢同一批行、把 web 环境弄坏。因此
# link-plugins.sh 把它列进了 SKIP_MOUNT，由本脚本单独建 profile。
#
# profile tui 的组成由 `dsh plugin add` 自动铺好：@deepseek-ai/dsh-base 作宿主层，
# dsh-tui 叠在其上（正是它 cordis.patch.yml 头部所述的「over the dsh-base layer」）。
# 本仓 patches/*.yml（better-sidebar / connection inject / web fetch provider）都是
# web 栈专用的，**不并入**本 profile。
#
# 用法：make dev-tui（或 bash scripts/link-tui.sh 只做挂载）

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PROFILE=tui
PLUGIN="$ROOT/plugins/dsh-tui"
export DSH_HOME="${DSH_HOME:-$ROOT/.dsh}"

dsh() {
  ( cd "$ROOT/harness" && CI=true pnpm dsh "$@" )
}

# SC2015：右支 { echo 错误; exit 1; } 必然退出，故"A && B || C" 的潜在副作用
# （A 为真时 C 也可能执行）在此不构成问题——C 真执行了也是报错退出，语义等价
# 「守卫失败即退出」。窄范围豁免。
# shellcheck disable=SC2015
[ -f "$ROOT/harness/package.json" ] && [ -d "$ROOT/harness/node_modules" ] || {
  echo "错误: harness 未构建，先运行 make setup" >&2
  exit 1
}
[ -d "$PLUGIN" ] || {
  echo "错误: $PLUGIN 不存在（submodule 未拉取？先运行 make setup）" >&2
  exit 1
}
[ -f "$PLUGIN/lib/types/index.js" ] || {
  echo "错误: dsh-tui 未构建（缺 $PLUGIN/lib/types/index.js），先运行 make setup" >&2
  exit 1
}

# pnpm 版本锚点：与 link-plugins.sh 同一份 $DSH_HOME/package.json（本脚本可单独运行，
# 故这里也要确保它在）。理由见 link-plugins.sh 内注释：本仓根没有 package.json，
# corepack 会回落 latest（pnpm 12.x 的 bin 布局与本机 Node 的 corepack 不兼容）。
PIN="$(node -p "require('$ROOT/harness/package.json').packageManager || ''")"
[ -n "$PIN" ] || {
  echo "错误: harness/package.json 缺少 packageManager 字段，无法确定 pnpm 版本锚点。" >&2
  exit 1
}
PIN_NO_HASH="${PIN%%+*}"
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
export COREPACK_DEFAULT_TO_LATEST=0

# 幂等：profile 已存在时 `add` 只更新 link 与 bundles 列表。
echo "==> 挂载 dsh-tui 到 profile ${PROFILE}"
dsh plugin --profile "$PROFILE" add "link:$PLUGIN"

echo "完成: profile ${PROFILE} 已就绪 → cd harness && DSH_HOME=$DSH_HOME pnpm dsh --profile ${PROFILE}"
