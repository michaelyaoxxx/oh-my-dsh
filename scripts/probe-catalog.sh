#!/usr/bin/env bash
# probe-catalog.sh — 组件目录校验的**合成夹具测试**
#
# 目的：check-components.mjs 的每条校验规则，都要有一条**会失败的合成样本**证明它真的会拒。
# 只读代码推断"它应该会拒"是不够的——本仓在许可证门禁上正是靠这个模式才发现
# "以为拦得住"与"真的拦得住"是两回事（见 probe-license-gate.sh）。
#
# 全程在 mktemp 出来的目录内操作，退出即清理，**不碰本仓任何文件**。
#
# 用法：bash scripts/probe-catalog.sh [--strict]
# 退出码：默认恒 0；--strict 下有用例不符则 1

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/config"
cp "$ROOT/scripts/check-components.mjs" "$TMP/scripts/"

FAILED=0

# 造一份最小 catalog。$1=components 数组的 JSON 文本
write_catalog() {
  cat > "$TMP/config/components.json" <<EOF
{
  "version": $2,
  "description": "fixture",
  "components": $1
}
EOF
}

# 造与 catalog 对应的 .gitmodules，让双向集合校验通过。
# $1=以空格分隔的 path 列表
write_gitmodules() {
  : > "$TMP/.gitmodules"
  for p in $1; do
    printf '[submodule "%s"]\n\tpath = %s\n\turl = https://example.invalid/%s.git\n' "$p" "$p" "$p" >> "$TMP/.gitmodules"
  done
}

# 一个字段齐全、值合法的组件条目。
# $1=name  $2=path  $3=overrides（JSON **对象**文本，可选；同名键**覆盖**而非追加）
#
# 为什么用合并而不是把片段拼到对象尾部：拼接会产生**重复键**（如两个 runtimeScope），
# JSON.parse 取最后一个——"能跑"，但读者无法判断哪个生效，换成严格解析器还会静默改变
# 语义。fixture 自己也该遵守「一个字段一个值」，否则它就在示范本计划要治的病。
good_component() {
  node -e '
    // 字段 = 当前校验器的 REQUIRED_FIELDS，取值形状对齐真实 config/components.json。
    // ⚠️ 这里要的是 buildMode / packageManager，**不是** config/README.md 里的
    //    prepareMode：后者是 T2 引入的 schema v2 才有的（届时删 packageManager、
    //    并把本行同步改掉）。夹具跟的是**当前**校验器，不是目标态。
    //    改字段前先跑一次本脚本的自检——夹具写错会让下面所有用例假过。
    const base = {
      name: process.argv[1], path: process.argv[2], sourceAuthority: "github",
      pinPolicy: "tag", pinRef: "v1.0.0",
      ciScope: ["build"], releaseScope: ["bundle"], runtimeScope: "required",
      platforms: ["linux-x86_64"], buildMode: "source-build",
      packageManager: "pnpm", testProfile: "vitest",
      stateSchema: "none", license: "MIT",
    }
    const over = process.argv[3] ? JSON.parse(process.argv[3]) : {}
    process.stdout.write(JSON.stringify({ ...base, ...over }))
  ' "$1" "$2" "${3:-}"
}

run_case() { # $1=场景名  $2=期望(CAUGHT/GAP)
  # 只跑校验并判定；fixture 由调用方**在此之前**设好。
  # 刻意不接"构造函数名"参数——兄弟脚本 probe-license-gate.sh 的 $6 是真被调用的，
  # 若这里也写一个同名参数却不用，后续任务照注释传函数名会**静默不执行构造**，
  # 造出与被测场景不符的 fixture，用例可能假过。
  local name="$1" expect="$2" out rc got mark
  out="$(cd "$TMP" && node scripts/check-components.mjs 2>&1)"; rc=$?
  got="GAP"; [ "$rc" -ne 0 ] && got="CAUGHT"
  mark="ok"; [ "$got" != "$expect" ] && { mark="!! 与预期不符"; FAILED=$((FAILED + 1)); }
  printf '  %-44s 期望=%-6s 实测=%-6s %s\n' "$name" "$expect" "$got" "$mark"
  [ "$got" = "CAUGHT" ] && printf '       理由: %s\n' "$(printf '%s' "$out" | grep -m1 '✗' | cut -c1-80)"
}

echo "组件目录校验 覆盖夹具"
echo "  scratch: ${TMP}（退出即清理）"

echo
echo "== 0. 夹具自检（必须通过，否则下面全是假阳性）=="
write_catalog "[$(good_component ok plugins/ok)]" 1
write_gitmodules "plugins/ok"
if (cd "$TMP" && node scripts/check-components.mjs >/dev/null 2>&1); then
  printf '  %-44s %s\n' "合法的 v1 catalog 应通过" "ok"
else
  printf '  %-44s %s\n' "合法的 v1 catalog 应通过" "!! 夹具坏了——以下结果不可信"
  FAILED=$((FAILED + 1))
fi

echo
echo "== 0b. 夹具能力自检：能产出 CAUGHT（不只会说 ok）=="
# 组件在 catalog 里、却不在 .gitmodules 里 —— 这是**现有**校验器就会抓的双向集合校验。
# 用它证明夹具能识别"该拒的确实被拒"，而不只是"该过的过了"。
# 顺带：这条用例让 run_case 真的被调用——否则会触发 SC2329 报告
# （「函数未被调用」+ 文件末尾有 exit 0），-S style 下即失败。删它之前先想清楚这一点。
write_catalog "[$(good_component ok plugins/ok),$(good_component ghost plugins/ghost)]" 1
write_gitmodules "plugins/ok"
run_case "组件在 catalog 但不在 .gitmodules" CAUGHT

echo
if [ "$STRICT" = 1 ] && [ "$FAILED" -ne 0 ]; then
  echo "✗ --strict：${FAILED} 项与预期不符。"
  exit 1
fi
exit 0
