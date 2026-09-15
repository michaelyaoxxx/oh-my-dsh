#!/usr/bin/env bash
# probe-license-gate.sh — 实测许可证门禁的**实际覆盖边界**（两道门分开报）
#
# 目的：门禁到底拦得住什么？读代码推断出的覆盖矩阵是**猜测**——本脚本用合成样本
# 逐条实测，把「以为拦得住」和「真的拦得住」分开。
#
# 两道门分别判定，**不合并成一列**——合并会掩盖内容层（L2）究竟补上了什么：
#   L1 = scripts/check-components.mjs  声明层：license 词表 + 与 package.json 的一致性
#   L2 = scripts/check-licenses.mjs    内容层：真去读 <组件>/LICENSE* 判是不是 copyleft
#
# 为什么用合成样本：要测的是**判定逻辑**，与被测组件的真实内容无关。且必须在隔离
# 目录里造——往本仓塞 GPL 样本会把测试手段变成事故。
# 全程在 mktemp 出来的目录内操作，退出即清理，**不碰本仓任何文件**。
#
# ── 两种用法，别混淆 ─────────────────────────────────────────────────────────
# 它是**证据生成器**（回答「门禁覆盖什么」），同时可当**门禁的回归测试**用。
#
#   默认      打印覆盖矩阵，**恒 exit 0**。用于人读——改门禁逻辑或新引入组件时
#             跑一次，把矩阵贴进 commit / PR。
#   --strict  有用例与预期不符就 **exit 1**。供 `make check` 与 CI 把它当
#             **门禁回归测试**：门禁被改弱时（该拦的拦不住），某个用例会由
#             CAUGHT 翻成 GAP，从而失败。
#
# 为什么 --strict 值得进 CI：它防的是**门禁被静默改弱**——本项目明确要防
# 「引入 copyleft」，而最省事的绕过就是改门禁本身。期望值在合理政策变动下
# 是稳定的（都是「copyleft 被拒」，例如将来允许 LGPL 也不会翻转任何用例），
# 所以摩擦很小。
# ⚠️ 但它**防不住蓄意攻击者**：攻击者能改被评审树里的门禁，也能改本脚本。
#    真正的解法是门禁脚本从**受信 ref** 取——见 AGENTS.md 的 Review 清单。
#
# 用法：
#   bash scripts/probe-license-gate.sh            # 证据：看覆盖矩阵
#   bash scripts/probe-license-gate.sh --strict   # 回归测试：不符即 exit 1
# 退出码：默认恒 0；--strict 下不符则 1

# 刻意**不用** set -e：本脚本要逐用例收集失败并继续，而非首个失败就退出。
# 代价是 cd 这类前置失败不会被自动中止，故显式 || exit（shellcheck SC2164）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/config"
cp "$ROOT/scripts/check-components.mjs" "$TMP/scripts/"
cp "$ROOT/scripts/check-licenses.mjs" "$TMP/scripts/"

GPL_TEXT="                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>"

# 造最小可校验形态：1 个 submodule + 1 个组件目录条目 + 该组件的 package.json。
# $1=目录声明的 license  $2=package.json 的 license（"-" 表示省略该字段）
stage() {
  rm -rf "$TMP/config" "$TMP/.gitmodules" "$TMP/plugins"
  mkdir -p "$TMP/config" "$TMP/plugins/evil"
  printf '[submodule "plugins/evil"]\n\tpath = plugins/evil\n\turl = https://example.invalid/evil.git\n' > "$TMP/.gitmodules"
  cat > "$TMP/config/components.json" <<EOF
{
  "version": 2,
  "components": [
    {
      "name": "evil", "path": "plugins/evil", "sourceAuthority": "github",
      "pinPolicy": "tag", "pinRef": "v1.0.0",
      "ciScope": ["build"], "releaseScope": ["bundle"], "runtimeScope": "required",
      "platforms": ["linux-x86_64"], "prepareMode": "source-build",
      "testProfile": "vitest", "license": "$1"
    }
  ]
}
EOF
  if [ "$2" = "-" ]; then
    printf '{"name":"evil"}' > "$TMP/plugins/evil/package.json"
  else
    printf '{"name":"evil","license":"%s"}' "$2" > "$TMP/plugins/evil/package.json"
  fi
}

# 场景用的附加构造：**必须在 stage 之后、检查之前**跑，否则会被下一个用例的 stage 清掉。
#
# 下面三个由 run_case 经 `$6` 变量**间接调用**，shellcheck 看不见这种调用，
# 会报 SC2329「函数从未被调用」——是假阳性，不是死代码。
# （实测：本文件末尾**有没有** `exit 0` 会翻转这条报告的触发，属 linter 分析边界，
#   不是代码问题。保留显式 exit 0，用窄范围豁免而不是靠"别写 exit"绕开。）
# shellcheck disable=SC2329
x_gpl_license() { printf '%s\n' "$GPL_TEXT" > "$TMP/plugins/evil/LICENSE"; }
# shellcheck disable=SC2329
x_embedded_gpl() {
  mkdir -p "$TMP/plugins/evil/src"
  printf '/* This program is free software: you can redistribute it and/or modify it\n   under the terms of the GNU General Public License as published by the FSF. */\nexport const x = 1\n' \
    > "$TMP/plugins/evil/src/index.js"
}
# shellcheck disable=SC2329
x_gpl_dep() {
  mkdir -p "$TMP/plugins/evil/node_modules/gpltrap"
  printf '{"name":"gpltrap","license":"GPL-3.0"}' > "$TMP/plugins/evil/node_modules/gpltrap/package.json"
}

FAILED=0
verdict() { # $1=脚本名 → CAUGHT / GAP
  local rc
  (cd "$TMP" && node "scripts/$1" >/dev/null 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then printf 'CAUGHT'; else printf 'GAP'; fi
}

run_case() { # $1=场景  $2=L1期望  $3=L2期望  $4=目录 license  $5=pkg license  [$6=附加构造]
  local name="$1" e1="$2" e2="$3" extra="${6:-}" g1 g2 mark="ok"
  stage "$4" "$5"
  if [ -n "$extra" ]; then "$extra"; fi
  g1="$(verdict check-components.mjs)"
  g2="$(verdict check-licenses.mjs)"
  if [ "$g1" != "$e1" ]; then mark="!! L1 与预期不符"; fi
  if [ "$g2" != "$e2" ]; then mark="$mark !! L2 与预期不符"; fi
  if [ "$mark" != "ok" ]; then FAILED=$((FAILED + 1)); fi
  printf '  %-40s L1=%-6s(期望%-6s) L2=%-6s(期望%-6s) %s\n' "$name" "$g1" "$e1" "$g2" "$e2" "$mark"
}

echo "许可证门禁覆盖边界实测（L1=声明层 / L2=内容层）"
echo "  scratch: ${TMP}（退出即清理）"

echo
echo "== 0. 夹具自检（必须通过，否则下面全是假阳性）=="
stage "MIT" "MIT"
if (cd "$TMP" && node scripts/check-components.mjs >/dev/null 2>&1 && node scripts/check-licenses.mjs >/dev/null 2>&1); then
  printf '  %-40s %s\n' "干净的 MIT 样本应通过两道门" "ok"
else
  printf '  %-40s %s\n' "干净的 MIT 样本应通过两道门" "!! 夹具坏了——以下结果不可信"
  FAILED=$((FAILED + 1))
fi

echo
echo "== A. 声明层（L1 的职责）=="
run_case "A1 目录直接声明 GPL-3.0"            CAUGHT GAP "GPL-3.0" "GPL-3.0"
run_case "A2 目录写 MIT，package.json 写 GPL" CAUGHT GAP "MIT"     "GPL-3.0"
run_case "A3 目录写 MIT，package.json 无字段" GAP    GAP "MIT"     "-"

echo
echo "== B. 内容层（L2 的职责；B2/B3 是已知缺口）=="
run_case "B1 LICENSE 文件是 GPL，声明层全 MIT" GAP CAUGHT "MIT" "MIT" x_gpl_license
run_case "B2 源码内嵌 GPL 头，声明层全 MIT"    GAP GAP    "MIT" "MIT" x_embedded_gpl
run_case "B3 依赖树里有 GPL 包，声明层全 MIT"  GAP GAP    "MIT" "MIT" x_gpl_dep
run_case "B4 声明层全 MIT，但没有任何 LICENSE" GAP GAP    "MIT" "MIT"

echo
echo "== C. 门禁自身的完整性（结构性，非样本可测）=="
printf '  %-40s L1=%-6s          L2=%-6s\n' "C1 门禁脚本位于被评审的树内" "GAP" "GAP"
echo "       证据: scripts/check-{components,licenses}.mjs 均由 git 跟踪，"
echo "             且 verify.yaml 跑的就是树里这一份 → 能提 PR 的人也能改它们"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "全部用例与预期一致。"
else
  echo "$FAILED 项与预期不符（见上）。"
fi

# --strict：把「与预期不符」变成失败。默认不——它是证据生成器，不是门禁。
# 归因提示：不符最多的情况是**门禁被改弱**（CAUGHT 翻成 GAP），那正是它要抓的；
# 其次是**期望值本身需要更新**（政策变了），此时应同步改上面的用例表。
if [ "${1:-}" = "--strict" ] && [ "$FAILED" -ne 0 ]; then
  echo
  echo "✗ --strict：$FAILED 项与预期不符。"
  echo "  若是**门禁被改弱**（该拦的拦不住了）→ 这是真回归，修门禁。"
  echo "  若是**政策变更**导致期望值过期 → 同步更新本脚本的用例表，并在 commit 里说明。"
  exit 1
fi
exit 0
