#!/usr/bin/env bash
# check-all.sh — 本地自检的**统一入口**（检查清单的单一事实源）
#
# 为什么要有它：「本地该跑什么」此前散在三处——CONTRIBUTING 的自检片段、
# verify.yaml 的 step 0、以及各脚本自己的注释。三份手工副本必然漂移，本仓
# 已经漂过一次：check-licenses.mjs 上线时进了 CI 却漏在本地清单里。
# 现在清单**只在本文件里**，`make check` 与 CI 都调它。
#
# 用法：
#   bash scripts/check-all.sh             # 全跑（离线组 + pin + shellcheck）
#   bash scripts/check-all.sh --offline   # 只跑**离线组**：不联网、不依赖构建、最快。
#                                         # CI 的 step 0 用它——它必须最先失败。
#   bash scripts/check-all.sh --list      # 只列将执行哪些检查（不跑）
#   --require-materialized                # **可与上面任一形式并用**（`--offline --require-materialized`）：
#                                         # 把 materialized 阶段的"子仓未初始化 ⇒ 跳过"变成失败。
#                                         # CI 与 release 用它——否则 fresh clone 上可以一项都不查
#                                         # 就通过（fail-open）。单独出现时按**全量**模式跑：
#                                         # "严格"与"联网/离线"是正交的两个维度。
#                                         # ⚠️ 顺序是 `<模式> --require-materialized`：模式旗标只认
#                                         # 第一个参数（本脚本既有约定，如 `--offline --list` 也只认
#                                         # 前者）。故 `--require-materialized --list` 会按全量跑，
#                                         # 要列清单请写成 `--list --require-materialized`。
#
# 退出码：0 全过；1 任一项失败

# 刻意不用 set -e：要跑完全部检查再汇总，而非首个失败就退出（一处失败掩盖其余更糟）。
# 代价是 cd 这类前置失败不会自动中止，故显式 || exit（shellcheck SC2164）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE="full"
case "${1:-}" in
  --offline) MODE="offline" ;;
  --list)    MODE="list" ;;
  --require-materialized) MODE="full" ;;
  "")        MODE="full" ;;
  *) echo "错误: 未知参数 ${1}（支持 --offline / --list / --require-materialized）" >&2; exit 1 ;;
esac

# 旗标**扫全部参数**（不只看 $1）：CI 与 release 传的是 `--offline --require-materialized`，
# 只认 $1 会让这个旗标静默失效——而它静默失效的后果正是 fail-open，
# 也就是它本身要堵的那件事。
REQUIRE_MAT=""
for a in "$@"; do [ "$a" = "--require-materialized" ] && REQUIRE_MAT=1; done

FAILED=0
PASSED=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }

run() { # $1=描述  $2...=命令
  local desc="$1"; shift
  printf '\n==> %s\n' "$desc"
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# ── 离线组 ───────────────────────────────────────────────────────────────────
# 不联网、不依赖构建（`make setup` 之前也能跑），故可以也应当**最先失败**。
# CI 的 step 0 就跑这一组。顺序：先声明层（最便宜）→ 内容层 → 生成物 → 门禁回归。
check_components() { run "组件目录（声明层：双向集合 + license 词表 + 与 package.json 核对）" node scripts/check-components.mjs ${REQUIRE_MAT:+--require-materialized}; }
check_licenses()   { run "组件许可证文件（内容层：读 LICENSE 判 copyleft）"                 node scripts/check-licenses.mjs; }
check_notices()    { run "第三方声明未过期（合规文档）"                                     node scripts/gen-notices.mjs --check; }
check_gate_regr()  { run "许可证门禁回归（覆盖边界未被改弱）"                               bash scripts/probe-license-gate.sh --strict; }
check_catalog()    { run "组件目录校验回归（每条规则都有会失败的样本）"                     bash scripts/probe-catalog.sh --strict; }

# ── 全量额外项 ───────────────────────────────────────────────────────────────
# pin 校验**要联网**（fetch 各 submodule 的远端 ref），故与离线组分开——
# 合并会让「不联网的便宜门」被网络问题拖住，破坏「最便宜的最先失败」。
# 静态检查（shellcheck）在下方以内联方式处理：本地用已装版本，缺失则跳过；
# CI 用固定 0.9.0 的下载 + checksum 校验，故不并入本脚本的命令清单。
check_pins() { run "submodule pin 校验（需联网 fetch）" bash scripts/check-pins.sh; }
check_shellcheck() {
  printf '\n==> shellcheck -S style（CI 固定 0.9.0；本地用已安装版本）\n'
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  \033[33m—\033[0m shellcheck 未安装，跳过（CI 会跑固定版本，见 verify.yaml）\n'
    return 0
  fi
  if shellcheck -S style scripts/*.sh deploy/remote-install.sh; then
    ok "shellcheck $(shellcheck --version | awk '/version:/{print $2}')"
  else
    bad "shellcheck"
  fi
}

if [ "$MODE" = "list" ]; then
  echo "将执行以下检查（mode=${MODE}）："
  echo "  · [离线] 组件目录 / 组件许可证文件 / 第三方声明 / 许可证门禁回归 / 目录校验回归"
  if [ "$MODE" != "offline" ]; then
    echo "  · [联网] submodule pin 校验"
    echo "  · [工具链] shellcheck -S style scripts/*.sh deploy/remote-install.sh"
  fi
  exit 0
fi

echo "== dsh 本地自检（mode=${MODE}）=="
if [ "$MODE" = "offline" ]; then
  echo "   --offline：只跑不联网、不依赖构建的检查（CI 的 step 0 用同一条命令）"
fi

check_components
check_licenses
check_notices
check_gate_regr
check_catalog

if [ "$MODE" = "full" ]; then
  check_pins
  check_shellcheck
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "全部通过（${PASSED} 项）。"
  exit 0
else
  echo "${FAILED} 项失败 / ${PASSED} 项通过（详见上）。" >&2
  exit 1
fi
