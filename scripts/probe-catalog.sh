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

run_case() { # $1=场景名  $2=期望(CAUGHT/GAP)  $3...=额外 CLI 参数（可选，原样传给校验器）
  # 只跑校验并判定；fixture 由调用方**在此之前**设好。
  # 刻意不接"构造函数名"参数——兄弟脚本 probe-license-gate.sh 的 $6 是真被调用的，
  # 若这里也写一个同名参数却不用，后续任务照注释传函数名会**静默不执行构造**，
  # 造出与被测场景不符的 fixture，用例可能假过。
  #
  # $3... 是**真的会传下去**的（D 组要用 `--list` / `--plan` 这类查询入口），
  # 不是为对齐签名而摆着：写入形参却不消费，正是上面那段警告的形态。
  # 用 shift + "$@" 而不是 `$3` 拼接：参数个数不定（`--list prepare` 是两个），
  # 且 `"$@"` 在无参数时展开为**零个词**——bash 3.2 + `set -u` 下实测安全。
  local name="$1" expect="$2"; shift 2
  local out rc got mark="ok" cerr="" nviol=0
  # 构造失败即失败：fixture 已经建好了才轮到本函数，故先收错误再判定。
  # 不收的话，坏 override 会让用例**假过**（绿的，理由却是"双向集合不符"）——
  # 断言只到"退出码非 0"的粒度挡不住这个，本任务实测踩过。
  if [ -s "$CONSTRUCT_ERR" ]; then cerr="$(cat "$CONSTRUCT_ERR")"; : > "$CONSTRUCT_ERR"; fi
  out="$(cd "$TMP" && node scripts/check-components.mjs "$@" 2>&1)"; rc=$?
  got="GAP"; [ "$rc" -ne 0 ] && got="CAUGHT"
  [ "$got" = "CAUGHT" ] && nviol="$(printf '%s' "$out" | grep -c '✗')"
  if [ "$got" != "$expect" ]; then mark="!! 与预期不符"; FAILED=$((FAILED + 1)); fi
  if [ -n "$cerr" ]; then mark="!! 构造失败——本用例结果不可信"; FAILED=$((FAILED + 1)); fi
  # ── 唯一归因：CAUGHT 的用例必须**恰好命中一条规则**（✗ 恰好 1 条）───────────
  # 为什么需要它：断言只到"退出码非 0"的粒度，于是"被旁边那条规则顺带判红"的用例
  # 是**绿的**——删掉它名字里那条规则它照样红，等于那条规则没有防退化装置。
  # 判据取 ✗ 的**条数**，不取文案（F3：文案重构不该让用例假红）。
  # 本任务实测踩过：C3 原方案如此（只改 runtimeScope，两条不变量同时命中）。
  # 0 条单列一档：那说明"判红"根本不是规则命中的（崩了？），诊断要指向这里。
  if [ "$got" = "CAUGHT" ] && [ -z "$cerr" ]; then
    if [ "$nviol" -eq 0 ]; then
      mark="!! 判红却没有 ✗——不是规则命中的（崩了？）"; FAILED=$((FAILED + 1))
    elif [ "$nviol" -ne 1 ]; then
      mark="!! 非唯一归因（命中 $nviol 条规则）"; FAILED=$((FAILED + 1))
    fi
  fi
  printf '  %-44s 期望=%-6s 实测=%-6s %s\n' "$name" "$expect" "$got" "$mark"
  [ -n "$cerr" ] && printf '       构造错误: %s\n' "$cerr"
  # 构造失败时**不打印"理由"**：那时校验器跑的是上一用例残留的 catalog，它的拒因
  # 与本用例无关，打出来会把读者引到错误的规则上（实测：会显示上一个用例的双向集合报错）。
  # 理由后面带上 ✗ 条数：唯一归因是判据，把它的实测值一并印出来，读者不必另跑一遍脚本。
  [ -z "$cerr" ] && [ "$got" = "CAUGHT" ] && printf '       理由(✗×%s): %s\n' "$nviol" "$(printf '%s' "$out" | grep -m1 '✗' | cut -c1-80)"
}

# 断言一条**输出内容**用例（run_case 只管退出码，管不了"计划里到底有没有那一行"），
# 并**真的**累加 FAILED。
#
# ⚠️ 为什么不能写成 `printf ... "$(cond && echo ok || { ...; FAILED=$((FAILED+1)); })"`：
#   命令替换 `$( )` 是**子 shell**，里面的 FAILED 自增**出不去**——用例会打印 `!!`，
#   而 `--strict`（`make check` 用的正是它）**仍然 rc=0**，即「报了红但不判红」。
#   实测过：把 D3 的断言改成必然失败，`--strict` 退出码仍是 0、只留下两行 `!!`。
#   这与文件顶部 record_construct_error 记的是**同一形态**（失败发生在子 shell 里、被
#   静默吞掉），只是这次被吞掉的是**判据本身**。
#   顺带：那种写法还会触发 shellcheck SC2015 / SC2030 / SC2031，而 `-S style` 是门禁。
# 故断言与自增必须在**同一层**：调用方先跑断言命令（不开子 shell），把它的退出码传进来。
# $1=场景名  $2=断言命令的退出码（0=通过）  $3=失败说明
assert_case() {
  if [ "$2" -eq 0 ]; then
    printf '  %-44s %s\n' "$1" "ok"
  else
    printf '  %-44s %s\n' "$1" "!! $3"
    FAILED=$((FAILED + 1))
  fi
}

# 造一个最小子仓：$1=path（相对 TMP）  $2=package.json 的 JSON  $3=被 git 跟踪的入口文件名（空格分隔，可空）
#
# 为什么必须造**真的** git 仓，而不是像 A–D 组那样只写一个 package.json：
# materialized 阶段的判据是「这个文件在子仓里**被 git 跟踪**吗」（`git ls-files`），
# 用合成的目录测不出来——那正是本组用例存在的理由。
#
# $3 为空时 `for entry in $3` 展开为**零次**迭代，且随后 `git commit` 会因
# "nothing to commit" 返回 1（工作区里只有一个未跟踪的 package.json）。
# 这是**有意**的：该用例要的正是"入口**未**被跟踪"的仓。本脚本无 `set -e`，
# 故不影响后续断言；代价是 git 会向 stderr 打一段 "nothing added to commit" 的提示。
make_subrepo() {
  local d="$TMP/$1" entry
  mkdir -p "$d"
  printf '%s' "$2" > "$d/package.json"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t )
  for entry in $3; do
    mkdir -p "$d/$(dirname "$entry")"
    printf '// fixture\n' > "$d/$entry"
    ( cd "$d" && git add -f "$entry" )
  done
  ( cd "$d" && git -c commit.gpgsign=false commit -qm fixture )
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
# Object.prototype **全部 12 个** own property 名字——constructor / toString /
# hasOwnProperty / valueOf / __proto__ / isPrototypeOf / propertyIsEnumerable /
# toLocaleString / __defineGetter__ / __defineSetter__ / __lookupGetter__ / __lookupSetter__——
# 把这 12 个名字误判成"已登记分类"而**放行**，即本任务这条新规则自己有 12 个口子可绕。
# （数一遍：node -e 'console.log(Object.getOwnPropertyNames(Object.prototype).length)'）
# 这里把「必须用 hasOwn 而非 in」这个性质**钉住**：将来有人改回 `in`，本用例必须变红。
# ⚠️ 别删：它是这条规则唯一的防退化装置（实测过：改成 `in` 时 B3/B4 双双假过）。
write_catalog "[$(good_component ok plugins/ok '{"constructor":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B3 原型链名 constructor（须拒）"   CAUGHT
write_catalog "[$(good_component ok plugins/ok '{"__proto__":1}')]" 2
write_gitmodules "plugins/ok"
run_case "B4 原型链名 __proto__（须拒）"     CAUGHT

# B5：FIELD_CLASS 的**值**必须在受控词表内（operational / declared / derived）。
# 这条**无法**靠改 catalog 造出来——FIELD_CLASS 是校验器**源码里的常量**，catalog 里没有它。
# 所以改为变异**校验器副本**：只改 $TMP 里那份，**本仓源码一个字节都不动**。
# 变异必须**确认生效**：改不中就经 T1 的构造失败通道判红，而不是让用例假过——
# 若锚点将来漂移，本用例会**响亮地失败**（构造错误横幅），不会静默变绿。
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
VALIDATOR="$TMP/scripts/check-components.mjs"
sed "s/^  license: 'operational',$/  license: 'operationall',/" "$VALIDATOR" > "$VALIDATOR.mut"
# 变异是否生效，**只能**由「变异体与源文件有没有实差」判定。
# ⚠️ 别用 `grep -q "'operationall'" 副本` 来判：那根针就写在**被测文件自己的注释里**
#    （check-components.mjs 解释本用例时写着 'operationall'），于是 grep **恒真**、
#    else 分支**永不可达**——守卫写了却不真的守，正是 T1 花 5 轮评审治的同一形态；
#    且锚点漂移时只会泛泛报「期望与实测不符」，把读者引向"规则没了"这个错误方向。
if cmp -s "$ROOT/scripts/check-components.mjs" "$VALIDATOR.mut"; then
  rm -f "$VALIDATOR.mut"
  record_construct_error "B5 变异未生效：副本与源文件逐字节相同（锚点已漂移？本用例结果不可信）"
else
  mv "$VALIDATOR.mut" "$VALIDATOR"
fi
run_case "B5 FIELD_CLASS 值拼错（须拒）"    CAUGHT
# 还原副本：后面的用例必须跑在**未变异**的校验器上（否则它们会因 B5 的变异而假红）。
# 还原失败也走构造失败通道，由 B5b 哨兵认领并报出——不让它静默泄漏。
cp "$ROOT/scripts/check-components.mjs" "$VALIDATOR" \
  || record_construct_error "B5 还原失败：副本可能仍是变异体，后续用例结果不可信"
# B5b 是**还原哨兵**：B5 把校验器副本变异过，若还原失败，本用例会立刻变红
# （干净 catalog 被变异体拒掉）。
# 别删——它的价值**不随任务过期**（原先这里写的是"今天 B5 之后没有别的用例"，
# C 组加进来后那句话已经错了，但机制本身没变）：泄漏的变异体是"什么都拒"，
# 于是**所有 CAUGHT 用例都会假过**（它们只断言"退出码非 0"，而变异体就是非零退出），
# **只有排在变异之后**的 GAP 基线抓得住它。B5b 之后还有 C4 这条 GAP 用例可作第二信号，
# 但 B5b 紧邻还原那一步：它红了，原因直接指向"还原失败"，不必再去排除别的可能。
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
run_case "B5b 变异已还原（基线，应通过）"    GAP

echo
echo "== C. catalog 阶段不变量 =="
write_catalog "[$(good_component c1 plugins/c1 '{"pinRef":"refs/tags/v1"}')]" 2
write_gitmodules "plugins/c1"
run_case "C1 tag pin 的 pinRef 带 refs/ 前缀"     CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"pinRef":""}')]" 2
write_gitmodules "plugins/c1"
run_case "C2 tag pin 的 pinRef 为空"              CAUGHT
# ⚠️ C3/C4/C5 的 overrides **必须同时收住旁边那个字段**，否则用例名与实测理由对不上：
#    good_component 的 base 是 `prepareMode: "source-build"` + `releaseScope: ["bundle"]`，
#    只改 runtimeScope 会让**两条**不变量同时命中，而 run_case 只打印**第一条** ✗。
#    实测（未收口时的原方案）：C4 期望 GAP 实测 CAUGHT，理由却是 prepareMode 那条；
#    C3/C5 虽 CAUGHT，但「删掉本条规则用例仍红」——那样的用例**挡不住规则被删**，
#    属"因无关原因变红"，断言不可信（T1 评审抓过同一形态）。
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded","prepareMode":"none"}')]" 2
write_gitmodules "plugins/c1"
run_case "C3 excluded 但 releaseScope 含 bundle"  CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded","releaseScope":["sbom"],"prepareMode":"none"}')]" 2
write_gitmodules "plugins/c1"
run_case "C4 excluded + 仅 sbom（应允许）"        GAP
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"excluded","prepareMode":"source-build","releaseScope":[]}')]" 2
write_gitmodules "plugins/c1"
run_case "C5 excluded 但 prepareMode != none"     CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"runtimeScope":"required","prepareMode":"none"}')]" 2
write_gitmodules "plugins/c1"
run_case "C6 required 但 prepareMode = none"      CAUGHT
# C7–C9：标量值的数组字段（三个字段各一条，各自唯一归因）。
# 它**不是**"选择子写错了"——`--list` 对数组是精确匹配的，根因是标量能通过 validate。
# 收口在 validate 里（比在选择子解析处更靠前、更根本）。
# 标量值刻意取**该字段词表内的合法值**：这样它骗过的是"字段存在 + 取值合法"两道检查，
# 只被类型不变量抓住——红得干净，不会与 ENUM 那条混淆（否则一条用例两条 ✗）。
write_catalog "[$(good_component c1 plugins/c1 '{"ciScope":"metadata"}')]" 2
write_gitmodules "plugins/c1"
run_case "C7 ciScope 写成标量（须拒）"            CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"releaseScope":"bundle"}')]" 2
write_gitmodules "plugins/c1"
run_case "C8 releaseScope 写成标量（须拒）"       CAUGHT
write_catalog "[$(good_component c1 plugins/c1 '{"platforms":"linux-x86_64"}')]" 2
write_gitmodules "plugins/c1"
run_case "C9 platforms 写成标量（须拒）"          CAUGHT

echo
echo "== D. --plan prepare（动作计划）与查询入口「先校验再查询」=="
# D1–D3：`--plan` 输出的是**动作计划**（`<path>\t<prepareMode>`），不只是路径。
# 为什么要输出动作：`--list prepare` 只统一了「准备哪些组件」这个**决策**；若 setup 与
# remote-install 各自写一套 `case "$prepareMode"` 决定**怎么准备**，漂移只会从「选哪个
# 字段」变成「怎么执行动作」——病没治好，换了个地方发作。
# 两个组件：aaa 是 required/source-build（应出现），bbb 是 excluded（不应出现）。
write_catalog "[$(good_component aaa plugins/aaa),$(good_component bbb plugins/bbb '{"runtimeScope":"excluded","prepareMode":"none","releaseScope":[]}')]" 2
write_gitmodules "plugins/aaa plugins/bbb"
# D5 是**基线**：合法目录下 `--plan` 必须退出 0。没有它，D6/D7 的 CAUGHT 可能只是
# 夹具坏了（"什么都拒"时 CAUGHT 用例全假过，同 B5b 那段注释）。
run_case "D5 合法目录 --plan（基线，应通过）" GAP --plan prepare
plan_out="$(cd "$TMP" && node scripts/check-components.mjs --plan prepare 2>&1)"
printf '%s' "$plan_out" | grep -q 'plugins/aaa.*source-build'; assert_case "D1 计划含 required 组件" $? "缺 aaa"
# D2 是**否定**断言（计划里**不能**出现 bbb），故用 `!` 取反后再交给 assert_case
# （它认 rc=0 为通过）。⚠️ 这里的 `!` 不是修饰，是**判据本身**：漏掉它就变成
# "计划里有 bbb 才通过"，与用例名相反——实测踩过（本用例立刻变红，抓住了这次改错）。
! printf '%s' "$plan_out" | grep -q 'plugins/bbb'; assert_case "D2 计划**不含** excluded 组件" $? "混入 bbb"
printf '%s' "$plan_out" | awk -F'\t' '$1=="plugins/aaa" && $2!=""{f=1} END{exit !f}'; assert_case "D3 计划带 prepareMode（制表符分隔）" $? "无制表符分隔的动作"
# D4：stdout 是**机器接口**（消费方 `IFS=$'\t' read` 或逐行取路径）。多一行摘要
# （如 validate() 的 `✓ 组件目录校验通过…`）会被当成组件路径读进去——所以计划必须
# **恰好**是那一行。D1–D3 抓不住这个：混进摘要行时它们仍然全绿（实测过）。
plan_lines="$(printf '%s\n' "$plan_out" | grep -c .)"
# 不用 `[ ... ]; assert_case ... $?`：那会触发 shellcheck SC2319（`$?` 指的是**条件**，
# 不是命令）——`-S style` 下即失败。显式 if 定性，语义也更直白。
d4_rc=0; [ "$plan_lines" -eq 1 ] || d4_rc=1
assert_case "D4 stdout 只有计划行（无摘要污染）" "$d4_rc" "stdout 有 ${plan_lines} 行"

# ★ D6 是**硬验收项**：目录非法时 `--list` 必须**非 0 退出**。
# 失效链是真实存在的，不是假想：deploy/remote-install.sh **没有** setup.sh:212 那样的
# 显式前置校验，直接 `PREPARE_LIST="$(node … --list prepare)"`，靠 `set -euo pipefail`
# + `$()` 传播退出码兜底——**这条链只在 --list 失败返回非 0 时才成立**。
# 若实现成"打印错误但继续、rc=0、stdout 空"，则 PREPARE_LIST 为空 → 每个插件走「跳过」
# → 部署"成功"却没装东西。修复前实测（本用例的 fixture）：`--list prepare` rc=0、stdout 空。
# ⚠️ 构造非法 catalog 时只让它命中**一条**规则（ENUM 取值非法）：run_case 以
#    「CAUGHT 用例恰好 1 条 ✗」作唯一归因判据，多命中一条就成了"因无关原因变红"。
write_catalog "[$(good_component ok plugins/ok '{"runtimeScope":"bogus"}')]" 2
write_gitmodules "plugins/ok"
run_case "D6 非法目录 ⇒ --list 须非零退出"   CAUGHT --list prepare
run_case "D7 非法目录 ⇒ --plan 须非零退出"   CAUGHT --plan prepare

# D8：`--plan` 只接受具名选择器 prepare。传一个**在 --list 下合法、但无动作定义**的选择器
# （ci:test）必须报错，不能静默输出空计划——空计划会被消费方读成"没有要准备的组件"。
write_catalog "[$(good_component ok plugins/ok)]" 2
write_gitmodules "plugins/ok"
run_case "D8 --plan 非 prepare 选择器须拒"   CAUGHT --plan ci:test

# D9：选择器名来自 **argv**（用户可控）。`--list constructor` / `--list __proto__` 这类
# **原型链名字**必须**非零退出**——要点是**不能静默放行**（rc=0 + 空集才是危险形态：
# 消费方会把"拒绝工作"读成"没有要处理的组件"）。失败时 stdout 也必须为空（✗ 走 stderr）。
# ⚠️ 本用例**刻意只断言行为（rc / stdout），不断言报错文案与形态**：本夹具的通则是
# 「判据取 ✗ 的条数/退出码，不取文案」（F3 立的规矩）——断言「报错里必须出现某某字样」
# 会让**纯改文案**（行为完全不变）假红，而那正是 F3 要避免的。
# 代价要知道：修复前（`NAMED_SELECTORS[selector] ?? selector`，原型查找）这 5 个名字
# 也是 rc=1 + stdout 空，所以本用例**不是**那次修复的防退化装置——它钉的是"不得静默
# 放行"这条**行为**。那次修复的价值在**诊断质量**（干净报错 vs 未捕获的 TypeError 裸栈），
# 按 F3 不为它写文案断言（评审裁定 M2；同 M4：诊断质量问题不为此加复杂度）。
d9_bad=""
for sel in constructor toString __proto__ valueOf hasOwnProperty; do
  out="$(cd "$TMP" && node scripts/check-components.mjs --list "$sel" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then d9_bad="${sel}:rc=0（静默放行）"
  elif [ -n "$out" ]; then d9_bad="${sel}:rc≠0 但 stdout 非空"
  fi
  [ -n "$d9_bad" ] && break
done
d9_rc=0; [ -z "$d9_bad" ] || d9_rc=1
assert_case "D9 原型链选择器名（须非零退出）" "$d9_rc" "${d9_bad:-}"

# D10：**等价性**——`--plan prepare` 与 `--list prepare` 必须选出**同一批组件**。
# 分量：两个入口回答的是同一个问题（"要准备哪些组件"），同一份目录必须给同一个答案。
# 这正是 09-15 review P0-1 的同一根病：同一份 manifest，两个消费者给出相反解释。
# 修复前的形态是 plan() 自己硬编码 `runtimeScope !== 'required'`，与
# NAMED_SELECTORS.prepare（'runtime:required'）是**同一条语义的两处副本**——只改一边，
# 两个入口就静默分歧，而没有任何用例会红。现在两者都走 selectComponents()（唯一判定处），
# 本用例就是钉住这件事的**装置**。
# 判据取**集合相等**（plan 取第 1 字段后排序，与 list 排序后逐字节比），不取文案：
# 两边本来就不该长得一样（plan 多一列 prepareMode），该一样的是**选出的组件集合**。
write_catalog "[$(good_component aaa plugins/aaa),$(good_component bbb plugins/bbb '{"runtimeScope":"excluded","prepareMode":"none","releaseScope":[]}')]" 2
write_gitmodules "plugins/aaa plugins/bbb"
eq_plan="$(cd "$TMP" && node scripts/check-components.mjs --plan prepare 2>&1 | awk -F'\t' 'NF{print $1}' | sort)"
eq_list="$(cd "$TMP" && node scripts/check-components.mjs --list prepare 2>&1 | sort)"
d10_rc=0
# 空集不能算"相等"：两个入口一起坏（如都返回空）时，等式仍然成立——那是**假过**。
[ -n "$eq_plan" ] || d10_rc=1
[ "$eq_plan" = "$eq_list" ] || d10_rc=1
assert_case "D10 --plan 与 --list 选出同一批组件" "$d10_rc" "plan=[$(printf '%s' "$eq_plan" | tr '\n' ' ')]list=[$(printf '%s' "$eq_list" | tr '\n' ' ')]"

# D11/D12：守卫**只**在查询路径上先行退出，默认路径仍跑完整 validate()。
# 为什么钉：把守卫写成无条件的 `if (!validateCatalog(catalog)) process.exit(1)`，默认路径
# 也被短路——同一份 catalog 同时有 catalog 阶段错误 + license 不一致时，**默认路径**从
# 2 条 ✗ 掉到 1 条 ✗（rc 都是 1，不是 fail-open；掉的是**诊断完整性**：用户得改一处、
# 重跑、才看见下一处）。而查询路径**必须**恰好 1 条 ✗——run_case 的唯一归因判据依赖它。
# 两条路径的 ✗ 条数都是契约，故各一条用例（判据取**条数**，不取文案）。
# fixture：一个 ENUM 取值非法（catalog 阶段）+ 一个 license 与其 package.json 不一致
# （materialized 阶段，只有默认路径才会跑到）。
# ⚠️ 那个 package.json **必须**带 scripts.build：本用例的判据是"✗ 的条数 = 跑过的阶段数"
#    （catalog 阶段 1 条 + materialized 阶段 1 条 = 2）。它的 prepareMode 取默认的
#    source-build，若没有 build 脚本，T6 新增的「source-build ⇒ 须有 scripts.build」
#    会在 materialized 阶段**再**命中一条，条数变 3——那不是"守卫少报了"，
#    却会让本用例红得与名字无关。实测过：T6 实现后本用例正是这样变红的（✗×3）。
write_catalog "[$(good_component ok plugins/ok '{"runtimeScope":"bogus"}')]" 2
write_gitmodules "plugins/ok"
mkdir -p "$TMP/plugins/ok"
printf '{"name":"ok","license":"Apache-2.0","scripts":{"build":"true"}}\n' > "$TMP/plugins/ok/package.json"
d11_n="$(cd "$TMP" && node scripts/check-components.mjs 2>&1 | grep -c '✗')"
d11_rc=0; [ "$d11_n" -eq 2 ] || d11_rc=1
assert_case "D11 默认路径 ✗=2（不因守卫而少报）" "$d11_rc" "✗×${d11_n}（期望 2）"
d12_n="$(cd "$TMP" && node scripts/check-components.mjs --list prepare 2>&1 | grep -c '✗')"
d12_rc=0; [ "$d12_n" -eq 1 ] || d12_rc=1
assert_case "D12 查询路径 ✗=1（唯一归因不变）" "$d12_rc" "✗×${d12_n}（期望 1）"

echo
echo "== E. materialized 阶段不变量 =="
# E 组与 A–D 组的**根本差别**：它读的是子仓（package.json + git 追踪状态），
# 故 fixture 必须是**真的 git 仓**（make_subrepo）。A–D 组只写文件即可，这里写文件不够。
#
# E1–E6 走 run_case，理由与 A–D 组相同：它们是**阻断**型不变量，**退出码就是判据**，
# 且受 run_case 的唯一归因约束（CAUGHT ⇒ 恰好 1 条 ✗）——"被旁边那条规则顺带判红"
# 的用例挡不住规则被删，本计划已为此返工过一次（见 run_case 那段注释）。
# ⚠️ 简报给的 printf + `$(cond && A || { …; FAILED=$((FAILED+1)); })` 形态**没有采用**：
#    那个自增在**命令替换的子 shell**里，出不来——用例会打印 `!!` 而 `--strict`
#    （`make check` 用的正是它）**仍然 rc=0**，即"报了红但不判红"。这正是本文件
#    assert_case 那段注释记的形态；E5/E6 因此改用 run_case，E7 用 assert_case。
# 预期 CAUGHT 的用例都会打印理由（✗ 原文，见 run_case 末尾），据它确认"红的是对应那条规则"。
# E1: tracked-prebuilt 但入口未被跟踪 → 必须失败
make_subrepo plugins/e1 '{"name":"e1","main":"lib/index.js"}' ""
write_catalog "[$(good_component e1 plugins/e1 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e1"
run_case "E1 tracked-prebuilt 但入口未跟踪"        CAUGHT
# E2: tracked-prebuilt 且入口已跟踪 → 通过
# 它是 E1/E3 的**基线**：没有它，E1 的 CAUGHT 可能只是"凡 tracked-prebuilt 必拒"（判据写反了）。
make_subrepo plugins/e2 '{"name":"e2","main":"lib/index.js"}' "lib/index.js"
write_catalog "[$(good_component e2 plugins/e2 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e2"
run_case "E2 tracked-prebuilt 且入口已跟踪"        GAP
# E3: tracked-prebuilt 且 main 已跟踪，但 exports 指向未跟踪文件 → 必须失败
# 分量：**只查 main 是不够的**。fresh clone 上会不会坏，取决于"任何会被加载的入口"，
# 而不是 package.json 里那一行 main。ADR 自己举的例子（dsh-market）正是 main 未跟踪、
# 被跟踪的是 exports["./client"]——只查 main 会把那个例子整个漏掉。
make_subrepo plugins/e3 '{"name":"e3","main":"lib/index.js","exports":{".":"./lib/index.js","./extra":"./lib/extra.js"}}' "lib/index.js"
write_catalog "[$(good_component e3 plugins/e3 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e3"
run_case "E3 exports 目标未跟踪（只查 main 不够）"  CAUGHT
# E4: source-build 但无 build 脚本 → 必须失败
# 分量：一个"要构建"的组件没有任何东西可执行构建，就永远是没构建过的状态，
# 而它在 catalog 里却是 runtimeScope=required（属于运行时组合）。
make_subrepo plugins/e4 '{"name":"e4"}' ""
write_catalog "[$(good_component e4 plugins/e4)]" 2
write_gitmodules "plugins/e4"
run_case "E4 source-build 但无 build 脚本"          CAUGHT
# E5/E6 是**同一 fixture 的两种模式**，一对必须一起看：
# E5 未初始化子仓 + --require-materialized → 必须失败（skip 不再是免死金牌）
write_catalog "[$(good_component e5 plugins/e5 '{"prepareMode":"tracked-prebuilt"}')]" 2
write_gitmodules "plugins/e5"
run_case "E5 未初始化子仓 + --require-materialized" CAUGHT --require-materialized
# E6 同一 fixture 不加 --require-materialized → 允许跳过
run_case "E6 未初始化子仓（非严格模式，应通过）"   GAP

# E7: source-build 且入口已被跟踪 → **不阻断**（期望 GAP），但**必须**在 stderr 上出现该组件。
# 分量（为什么这条警告值得钉）：它是 ADR-0005 承诺过、却一直没人实现的那条——
# 构建会覆盖**已被 git 跟踪**的产物，从而弄脏 submodule，进而触发部署的快照保真检查。
# 判据取**数据**（stderr 上出现该组件名），**不取文案**：文案重构不该让用例假红。
# 两条流**分开**收集：只断言"输出里有 e7"是抓不住"警告混进了 stdout"的，而 stdout 是
# **机器接口**（`--list` / `--plan` 被 setup.sh / remote-install.sh 逐行解析成路径与
# prepareMode），混进去的警告会被当成一个组件路径——那正是这条警告必须走 stderr 的理由。
# 故本用例走 assert_case 而不是 run_case：run_case 的判据是退出码，而这条**不阻断**。
make_subrepo plugins/e7 '{"name":"e7","main":"lib/index.js","scripts":{"build":"true"}}' "lib/index.js"
write_catalog "[$(good_component e7 plugins/e7)]" 2
write_gitmodules "plugins/e7"
e7_out="$(cd "$TMP" && node scripts/check-components.mjs 2>"$TMP/.e7-err")"; e7_rc=$?
e7_err="$(cat "$TMP/.e7-err")"
e7_bad=""
[ "$e7_rc" -eq 0 ] || e7_bad="rc=${e7_rc}（警告不阻断，应通过）"
printf '%s' "$e7_err" | grep -q 'e7' || e7_bad="${e7_bad}；stderr 上无 e7 警告"
printf '%s' "$e7_out" | grep -q 'e7' && e7_bad="${e7_bad}；警告污染了 stdout"
e7_verdict=0; [ -z "$e7_bad" ] || e7_verdict=1
assert_case "E7 source-build 且入口已跟踪（警告不阻断）" "$e7_verdict" "${e7_bad:-}"

echo
if [ "$STRICT" = 1 ] && [ "$FAILED" -ne 0 ]; then
  echo "✗ --strict：${FAILED} 项与预期不符。"
  exit 1
fi
exit 0
