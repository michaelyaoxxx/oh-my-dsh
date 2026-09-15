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

# ── 构造失败通道 ─────────────────────────────────────────────────────────────
# 为什么走**文件**而不是变量：构造发生在 `$(good_component ...)` 里，而命令替换是
# **子 shell**——函数在里面设的变量出不来，失败会被静默吞掉。实测过的后果：
# override 写坏 → good_component 抛错 → 命令替换为空 → catalog 变成 [] → 而
# .gitmodules 非空 → 校验器因"双向集合不符"退出 1 → 期望 CAUGHT 的用例**假过**
# （绿的，且理由是错的）。文件跨子 shell 存活，故失败经它上报，由 run_case 判为
# **该用例失败**——这就是"构造失败即失败"。
CONSTRUCT_ERR="$TMP/.construct-error"
record_construct_error() { printf '%s\n' "$1" >> "$CONSTRUCT_ERR"; }

# 造一份最小 catalog。$1=components 数组的 JSON 文本  $2=version
# ⚠️ 两个参数都**必需**：$2 原先只在注释里写过 $1。实测单参调用的后果（不是推测）：
#    `set -u` 报 `$2: unbound variable`，写出的 catalog 无法解析，校验器以 rc≠0 退出
#    → 期望 CAUGHT 的用例**假过**。构造失败通道现在会把它抓住并判为**本用例失败**。
# 用 printf 而不是 heredoc：非引用 heredoc 会展开载荷里的 $ / 反引号 / 反斜杠，
# 静默写入与预期不同的 JSON；改成 <<'EOF' 又会让 $1 / $2 不再展开。两条都不行。
write_catalog() {
  [ -n "${1:-}" ] || { record_construct_error "write_catalog 缺 \$1（components 载荷）"; return 1; }
  [ -n "${2:-}" ] || { record_construct_error "write_catalog 缺 \$2（version）"; return 1; }
  printf '{\n  "version": %s,\n  "description": "fixture",\n  "components": %s\n}\n' "$2" "$1" \
    > "$TMP/config/components.json"
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
  local out
  # 构造失败**必须留痕**：node 抛错（如 override 不是合法 JSON）时命令替换是空串，
  # 调用方的 `[$(...)]` 就会写成空数组 [] ——见 record_construct_error 的注释。
  if ! out="$(node -e '
    // 字段 = 当前校验器的 REQUIRED_FIELDS，取值形状对齐真实 config/components.json。
    // ⚠️ fixture 的字段名必须跟**当前**校验器，不跟 config/README.md 描述的目标态——
    //    否则 schema 再升一版时，这里会先于校验器失效。
    //    改字段前先跑一次本脚本的自检——夹具写错会让下面所有用例假过。
    const base = {
      name: process.argv[1], path: process.argv[2], sourceAuthority: "github",
      pinPolicy: "tag", pinRef: "v1.0.0",
      ciScope: ["build"], releaseScope: ["bundle"], runtimeScope: "required",
      platforms: ["linux-x86_64"], prepareMode: "source-build",
      testProfile: "vitest",
      stateSchema: "none", license: "MIT",
    }
    const over = process.argv[3] ? JSON.parse(process.argv[3]) : {}
    process.stdout.write(JSON.stringify({ ...base, ...over }))
  ' "$1" "$2" "${3:-}" 2>"$TMP/.gc-stderr")"; then
    local why
    why="$(grep -m1 -i 'error' "$TMP/.gc-stderr")"
    [ -n "$why" ] || why="$(head -1 "$TMP/.gc-stderr")"
    record_construct_error "good_component(name=$1 path=$2 overrides=${3:-}) 构造失败: $why"
    return 1
  fi
  printf '%s' "$out"
}

run_case() { # $1=场景名  $2=期望(CAUGHT/GAP)
  # 只跑校验并判定；fixture 由调用方**在此之前**设好。
  # 刻意不接"构造函数名"参数——兄弟脚本 probe-license-gate.sh 的 $6 是真被调用的，
  # 若这里也写一个同名参数却不用，后续任务照注释传函数名会**静默不执行构造**，
  # 造出与被测场景不符的 fixture，用例可能假过。
  local name="$1" expect="$2" out rc got mark="ok" cerr=""
  # 构造失败即失败：fixture 已经建好了才轮到本函数，故先收错误再判定。
  # 不收的话，坏 override 会让用例**假过**（绿的，理由却是"双向集合不符"）——
  # 断言只到"退出码非 0"的粒度挡不住这个，本任务实测踩过。
  if [ -s "$CONSTRUCT_ERR" ]; then cerr="$(cat "$CONSTRUCT_ERR")"; : > "$CONSTRUCT_ERR"; fi
  out="$(cd "$TMP" && node scripts/check-components.mjs 2>&1)"; rc=$?
  got="GAP"; [ "$rc" -ne 0 ] && got="CAUGHT"
  if [ "$got" != "$expect" ]; then mark="!! 与预期不符"; FAILED=$((FAILED + 1)); fi
  if [ -n "$cerr" ]; then mark="!! 构造失败——本用例结果不可信"; FAILED=$((FAILED + 1)); fi
  printf '  %-44s 期望=%-6s 实测=%-6s %s\n' "$name" "$expect" "$got" "$mark"
  [ -n "$cerr" ] && printf '       构造错误: %s\n' "$cerr"
  # 构造失败时**不打印"理由"**：那时校验器跑的是上一用例残留的 catalog，它的拒因
  # 与本用例无关，打出来会把读者引到错误的规则上（实测：会显示上一个用例的双向集合报错）。
  [ -z "$cerr" ] && [ "$got" = "CAUGHT" ] && printf '       理由: %s\n' "$(printf '%s' "$out" | grep -m1 '✗' | cut -c1-80)"
}

echo "组件目录校验 覆盖夹具"
echo "  scratch: ${TMP}（退出即清理）"

echo
echo "== 0. 夹具自检（必须通过，否则下面全是假阳性）=="
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
if (cd "$TMP" && node scripts/check-components.mjs >/dev/null 2>&1); then
  printf '  %-44s %s\n' "合法的当前版本 catalog 应通过" "ok"
else
  printf '  %-44s %s\n' "合法的当前版本 catalog 应通过" "!! 夹具坏了——以下结果不可信"
  FAILED=$((FAILED + 1))
fi

echo
echo "== 0b. 夹具能力自检：能产出 CAUGHT（不只会说 ok）=="
# 组件在 catalog 里、却不在 .gitmodules 里 —— 这是**现有**校验器就会抓的双向集合校验。
# 用它证明夹具能识别"该拒的确实被拒"，而不只是"该过的过了"。
# 顺带：这条用例让 run_case 真的被调用——否则会触发 SC2329 报告
# （「函数未被调用」+ 文件末尾有 exit 0），-S style 下即失败。删它之前先想清楚这一点。
write_catalog "[$(good_component ok plugins/ok),$(good_component ghost plugins/ghost)]" 2
write_gitmodules "plugins/ok"
run_case "组件在 catalog 但不在 .gitmodules" CAUGHT

echo
echo "== A. schema 版本 =="
write_catalog "[$(good_component ok plugins/ok)]" 1
write_gitmodules "plugins/ok"
run_case "A1 version=1（本仓只接受 2）"     CAUGHT
write_catalog "[$(good_component ok plugins/ok)]" 3
run_case "A2 version=3（未知版本拒绝）"     CAUGHT
write_catalog "[$(good_component ok plugins/ok)]" 2
run_case "A3 version=2（当前版本接受）"     GAP

echo
echo "== B. 字段分类元数据 =="
# B1 是**基线**：它证明 B2 的红色来自新规则，而不是"任何 catalog 都被拒"。
# 没有它，B2 的 CAUGHT 可能只是夹具坏了（工具坏了也全红）。
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
run_case "B1 合法分类（基线，应通过）"      GAP
# 用一个未登记的字段名：它没有分类，说明有人加了字段却没登记分类
write_catalog "[$(good_component ok plugins/ok '{"untrackedField":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B2 出现未登记分类的字段"          CAUGHT

# B3/B4：**原型链名字**。判据若写成 `f in FIELD_CLASS`，`in` 会沿原型链命中
# Object.prototype 的成员（constructor / toString / hasOwnProperty / valueOf / __proto__），
# 把这 5 个名字误判成"已登记分类"而**放行**——即本任务这条新规则自己有 5 个口子可绕。
# 这里把「必须用 hasOwn 而非 in」这个性质**钉住**：将来有人改回 `in`，本用例必须变红。
# ⚠️ 别删：它是这条规则唯一的防退化装置（实测过：改成 `in` 时 B3/B4 双双假过）。
write_catalog "[$(good_component ok plugins/ok '{"constructor":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B3 原型链名 constructor（须拒）"   CAUGHT
write_catalog "[$(good_component ok plugins/ok '{"__proto__":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B4 原型链名 __proto__（须拒）"     CAUGHT

echo
if [ "$STRICT" = 1 ] && [ "$FAILED" -ne 0 ]; then
  echo "✗ --strict：${FAILED} 项与预期不符。"
  exit 1
fi
exit 0
