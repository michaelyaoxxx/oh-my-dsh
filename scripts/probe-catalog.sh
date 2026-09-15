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

# 断言一条**警告**用例。run_case 在这里用不上：这条警告**不阻断**，没有退出码可判。
#
# 判据取**数据**（stderr 上是否出现该组件名），**不取文案**——文案重构不该让用例假红。
# 两条流**分开**收集：只断言"输出里有它"是抓不住"警告混进了 stdout"的，而 stdout 是
# **机器接口**（`--list` / `--plan` 被 setup.sh / remote-install.sh 逐行解析成路径与
# prepareMode），混进去的警告会被当成一个组件路径——那正是这条警告必须走 stderr 的理由。
#
# ⚠️ 正例（PRESENT）与反例（ABSENT）**必须成对**：只测正例挡不住"以后又对元数据喊狼来了"，
#    只测反例挡不住"警告彻底不响了"。而这条规则**不阻断**，两种退化都**不会**让任何
#    退出码变红——没有这组装置，下次重构把候选集改回"全入口集"（实测会从 3 个喊到 6 个）
#    是**静默**发生的。这是本脚本里唯一一类"没有退出码兜底"的规则，故装置只能建在这里。
#
# 用 `--require-materialized` 跑（fixture 里只有一个组件、子仓已 init ⇒ 不影响 rc），
# 为的是顺带拿一条**数据**保证：该组件**真的被读了**。否则 package.json 一旦被写成非法
# JSON（如 make_subrepo 的占位符盖掉了它），组件会走 skipped 分支——**ABSENT 用例就会因为
# "根本没查"而假过**，而那与"元数据不算构建产物"是两回事。严格模式下 skip 即 rc≠0，
# 正好把这条假过路径变成红。
# $1=场景名  $2=期望(PRESENT/ABSENT)  $3=组件名
assert_warn_case() {
  local name="$1" expect="$2" comp="$3" cerr="" bad="" verdict=0 rc=0 out err
  # 构造失败即失败（同 run_case）：不留痕的话，坏 fixture 会让用例**因错误的原因**变绿。
  if [ -s "$CONSTRUCT_ERR" ]; then cerr="$(cat "$CONSTRUCT_ERR")"; : > "$CONSTRUCT_ERR"; fi
  out="$(cd "$TMP" && node scripts/check-components.mjs --require-materialized 2>"$TMP/.warn-stderr")"; rc=$?
  err="$(cat "$TMP/.warn-stderr")"
  [ "$rc" -eq 0 ] || bad="rc=${rc}（警告不阻断、且组件已被 materialize，应通过）"
  if [ "$expect" = "PRESENT" ]; then
    printf '%s' "$err" | grep -q "$comp" || bad="${bad}；stderr 上没有出现 ${comp}（该响却没响）"
  else
    printf '%s' "$err" | grep -q "$comp" && bad="${bad}；stderr 上出现了 ${comp}（对不该脏的组件喊了狼来了）"
  fi
  printf '%s' "$out" | grep -q "$comp" && bad="${bad}；警告污染了 stdout"
  [ -n "$cerr" ] && bad="${bad}；构造失败：${cerr}"
  [ -z "$bad" ] || verdict=1
  assert_case "$name" "$verdict" "${bad:-}"
}

# 造一个最小子仓：$1=path（相对 TMP）  $2=package.json 的 JSON  $3=被 git 跟踪的入口文件名（空格分隔，可空）
#
# 为什么必须造**真的** git 仓，而不是像 A–D 组那样只写一个 package.json：
# materialized 阶段的判据是「这个文件在子仓里**被 git 跟踪**吗」（`git ls-files`），
# 用合成的目录测不出来——那正是本组用例存在的理由。
#
# $3 为空（E1/E4：要测"入口**未**被跟踪"）时**不 commit**：那种场景本就不需要 commit——
# 仓库停在"已 init、HEAD 未出生"的状态，`git ls-files --error-unmatch` 照样报未跟踪，
# 判据完全相同。这也顺手消掉了原先 `git commit` 因"nothing to commit"吐出的 8 行 stderr
# 噪音（它会混进 `make check` 与 CI 日志）。
# ⚠️ 降噪**没有**用 `git commit … 2>/dev/null`：那会把**真的**提交失败（user.email 没配上、
#    index.lock 残留、磁盘满）一起吞掉，用例会在一个"看着没事"的坏仓上**假过**。
#    这里改为：让 git 的失败照常可见（非零退出 + stderr），并经 T1 的构造失败通道上报。
#
# 构造失败**必须留痕**（同 good_component 的理由）：上面任一 git 命令失败，造出来的是一个
# **假仓**，而 `tracked()` 把任何 git 报错都当成"未跟踪"——于是"入口未跟踪"那几条用例会
# **因错误的原因变绿**。走 record_construct_error 后，下一个消费该通道的用例会判为
# "构造失败——本用例结果不可信"。
make_subrepo() {
  local d="$TMP/$1" entry rc=0
  mkdir -p "$d"
  printf '%s' "$2" > "$d/package.json"
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t ) || rc=1
  for entry in $3; do
    mkdir -p "$d/$(dirname "$entry")"
    # 已存在的文件（如 package.json）**不覆盖**：它的内容是本 fixture 声明的载荷，
    # 被占位符盖掉会让 package.json 不再是合法 JSON → 该组件走 skipped 分支 →
    # 用例"通过"的理由就变成了"根本没查"，而不是"元数据不算构建产物"。
    [ -f "$d/$entry" ] || printf '// fixture\n' > "$d/$entry"
    ( cd "$d" && git add -f "$entry" ) || rc=1
  done
  if [ -n "$3" ]; then
    ( cd "$d" && git -c commit.gpgsign=false commit -qm fixture ) || rc=1
  fi
  [ "$rc" -eq 0 ] || record_construct_error "make_subrepo($1) 构造失败：git 命令非零退出（用例结果不可信）"
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

# E7/E8 是**一对**，钉的是同一条**只警告、不阻断**的规则（ADR-0005：构建会覆盖已被 git 跟踪
# 的产物，从而弄脏 submodule，进而触发部署的快照保真检查）。这条规则**没有退出码**，
# 所以两种退化都不会让任何用例变红，必须专门建装置：
#   · E7（正例）：声明的 `.js` 入口已被跟踪 ⇒ 警告**必须响**（挡住"警告彻底不响了"）；
#   · E8（反例）：只跟踪 `package.json` / `cordis.patch.yml` 这类**元数据** ⇒ **不得**响
#     （挡住"又对元数据喊狼来了"）。
# E8 的 fixture 刻意照着真目录里被误触的那三个的长相造（dsh-better-sidebar 只有 package.json
# 被跟踪；dsh-agent-teams 是 package.json + cordis.patch.yml；loongsuite-observability 的
# 真产物 dist/* 未跟踪）——把元数据算进候选集时，实测警告面会从 3 个涨到 6 个，
# 其中恰好就是这三个，而它们的构建**从不覆盖**那两个文件。
#
# 分量（为什么候选集只取构建产物）：警告问的是"构建会**覆盖**哪个已跟踪文件"。
# 人手维护的 manifest / 配置不是构建产物 ⇒ 算进来就是对**根本不会被弄脏**的组件报警，
# 而一条喊狼来了的警告会被当噪音忽略，那它就等于没有。判据细节见 BUILDABLE_ENTRY。
make_subrepo plugins/e7 '{"name":"e7","main":"lib/index.js","exports":{"./package.json":"./package.json"},"scripts":{"build":"true"}}' "lib/index.js package.json"
write_catalog "[$(good_component e7 plugins/e7)]" 2
write_gitmodules "plugins/e7"
assert_warn_case "E7 source-build 且 .js 入口已跟踪（须警告）" PRESENT e7
# E8：声明的产物 lib/index.js **未**被跟踪（同 loongsuite 的 dist/*），被跟踪的只有元数据
make_subrepo plugins/e8meta '{"name":"e8meta","main":"lib/index.js","exports":{".":"./lib/index.js","./cordis.patch.yml":"./cordis.patch.yml","./package.json":"./package.json"},"scripts":{"build":"true"}}' "package.json cordis.patch.yml"
write_catalog "[$(good_component e8meta plugins/e8meta)]" 2
write_gitmodules "plugins/e8meta"
assert_warn_case "E8 只跟踪元数据（package.json/cordis.patch.yml）⇒ 不得警告" ABSENT e8meta

echo
echo "== F. 消费者的 fail-open（目录查询失败必须 fail closed）=="
# 这一组测的是**消费方**：`--list` 已经在 D6 里证明"非法目录 ⇒ 非零退出"，但消费方若把
# 这个非零退出丢掉，D6 就白搭了——fail closed 是**两段**都要成立的事，缺任何一段，
# "配置错了还照跑"就还在。
#
# F2 起是**行为断言**（真跑一次消费者，断言它的**后果**），不是源码文本匹配。
# 为什么必须换成行为：
#   · 文本判据会**漏**——`done <<< "$(…)"` 去掉 `if !` 守卫同样是 fail-open（命令替换的
#     退出码不进入 `done` 的状态），而源码里没有任何"吞错"字样；
#   · 文本判据会**误伤**——注释里出现示例字符串也会命中。
# 行为判据只有一句：**目录非法时，消费者必须非零退出、且一次挂载都不发生**，
# 不管实现写成 `< <()`、`<<<` 还是 `| while`。
#
# 为什么行为断言到这里才可行（简报曾判定"必假绿"）：`link-plugins.sh` 在本仓会因为
# harness 未构建而失败，夹具里必然缺 `$ROOT/harness/node_modules`——**但那是可以造的**。
# 造出来脚本就能跑到底；挂载最终经 `dsh` → `pnpm` 发生，于是把一个**只记录调用**的
# stub `pnpm` 放到 PATH 最前，"挂载调用次数"就成了可断言的**数据**（不是文案）。
#
# ⚠️ DSH_HOME 一律显式指向 $TMP 下的目录，且由**构造**保证：consumer_run 只接受一个
#    标签、自己拼在 $CONSUMER_DSH_BASE 下，调用方拿不到传绝对路径的机会。脚本会往
#    $DSH_HOME 写 pnpm 锚点、profile、cordis.patch.yml——传错就会改写开发者真仓的
#    `.dsh/`（评审做同类夹具时就踩到过一次，已还原）。
CONSUMER_DIR="$TMP/consumer"
CONSUMER_STUB="$TMP/consumer-stub"
CONSUMER_DSH_BASE="$TMP/consumer-dsh"
export CONSUMER_PNPM_LOG="$TMP/.consumer-pnpm.log"
mkdir -p "$CONSUMER_STUB"
cat > "$CONSUMER_STUB/pnpm" <<'SH'
#!/usr/bin/env bash
# stub：只记录调用，不安装任何东西。CONSUMER_PNPM_LOG 缺失时**响亮失败**——静默退出 0
# 会让"零挂载"变成假绿（反例会因"stub 根本没跑"而通过）。
: "${CONSUMER_PNPM_LOG:?stub pnpm 缺少 CONSUMER_PNPM_LOG（夹具环境没传进来）}"
printf '%s\n' "$*" >> "$CONSUMER_PNPM_LOG"
exit 0
SH
chmod +x "$CONSUMER_STUB/pnpm"

# 两个 catalog：broken 由 valid **改一处**派生（`["sbom"]` → `["bundle"]`，命中 C3
# 不变量：不进运行时却进制品）。派生而非各写一份，是为了让"两模式只差一处"由构造保证。
cat > "$TMP/catalog-valid.json" <<'JSON'
{ "version": 2, "description": "consumer fixture (valid)",
  "components": [
    { "name": "bundle-a", "path": "plugins/bundle-a", "sourceAuthority": "github",
      "pinPolicy": "tag", "pinRef": "v1", "ciScope": ["build"],
      "releaseScope": ["bundle"], "runtimeScope": "required", "prepareMode": "source-build",
      "platforms": [], "testProfile": "none", "stateSchema": "none", "license": "MIT" },
    { "name": "dsh-tui", "path": "plugins/dsh-tui", "sourceAuthority": "github",
      "pinPolicy": "tag", "pinRef": "v1", "ciScope": ["build"],
      "releaseScope": ["sbom"], "runtimeScope": "excluded", "prepareMode": "none",
      "platforms": [], "testProfile": "none", "stateSchema": "none", "license": "MIT" }
  ] }
JSON
sed 's/\["sbom"\]/["bundle"]/' "$TMP/catalog-valid.json" > "$TMP/catalog-broken.json"

make_consumer_fixture() { # $1=valid|broken
  rm -rf "$CONSUMER_DIR"
  mkdir -p "$CONSUMER_DIR/scripts" "$CONSUMER_DIR/config" \
           "$CONSUMER_DIR/harness/node_modules" \
           "$CONSUMER_DIR/plugins/bundle-a" "$CONSUMER_DIR/plugins/dsh-tui"
  cp "$ROOT/scripts/check-components.mjs" "$CONSUMER_DIR/scripts/"
  cp "$ROOT/scripts/merge-profile-patch.mjs" "$CONSUMER_DIR/scripts/"
  cp "$ROOT/scripts/link-plugins.sh" "$CONSUMER_DIR/scripts/"   # 被测对象：逐字节复制
  # 两个插件都声明 dsh.bundle.patch ⇒ 都**可挂载**。"零挂载"因此是有意义的断言：
  # 排除集一旦变空，dsh-tui 就会真的被挂上——线上正是这个后果（web 环境被弄坏）。
  for _p in bundle-a dsh-tui; do
    # `scripts.build` 是**必需**的：bundle-a 是 prepareMode=source-build，会命中 T6 那条
    # 「source-build ⇒ 须有 scripts.build」（materialized 阶段）。实测踩到过：不带它，
    # **valid** 模式都会判红，F0b 当场变红——那正是 F0 这层自检存在的意义。
    printf '{"name":"%s","scripts":{"build":"true"},"dsh":{"bundle":{"patch":"cordis.patch.yml"}}}\n' "$_p" \
      > "$CONSUMER_DIR/plugins/$_p/package.json"
    printf '[]\n' > "$CONSUMER_DIR/plugins/$_p/cordis.patch.yml"
  done
  printf '{"name":"harness","packageManager":"pnpm@11.7.0"}\n' > "$CONSUMER_DIR/harness/package.json"
  # .gitmodules 两个模式**相同**（都与目录双向一致）：合法性差异全部落在 catalog 上。
  # 于是正例与反例跑在同一棵树、同一个脚本、同一个 stub 下，唯一变量是目录合不合法。
  printf '[submodule "plugins/bundle-a"]\n\tpath = plugins/bundle-a\n\turl = https://example.invalid/bundle-a.git\n[submodule "plugins/dsh-tui"]\n\tpath = plugins/dsh-tui\n\turl = https://example.invalid/dsh-tui.git\n' > "$CONSUMER_DIR/.gitmodules"
  cp "$TMP/catalog-$1.json" "$CONSUMER_DIR/config/components.json"
}

CONSUMER_RC=0
CONSUMER_CALLS=0
consumer_run() { # $1=被测脚本（绝对路径）  $2=标签（在 $CONSUMER_DSH_BASE 下拼成 DSH_HOME）
  local home="$CONSUMER_DSH_BASE/$2"
  rm -rf "$home"
  mkdir -p "$home/profiles/dsh"
  printf '{"name":"dsh-profile","private":true,"dependencies":{}}\n' > "$home/profiles/dsh/package.json"
  : > "$CONSUMER_PNPM_LOG"
  CONSUMER_RC=0
  ( cd "$CONSUMER_DIR" && DSH_HOME="$home" PATH="$CONSUMER_STUB:$PATH" bash "$1" ) \
    >"$TMP/.consumer-out" 2>&1 || CONSUMER_RC=$?
  CONSUMER_CALLS="$(wc -l < "$CONSUMER_PNPM_LOG" | tr -d ' ')"
}
consumer_refused_last() { [ "$CONSUMER_RC" -ne 0 ] && [ "$CONSUMER_CALLS" -eq 0 ]; }

# ── F0：夹具自检（不通过则整组结论不可信）────────────────────────────────────
# 同第 0 节的理由：夹具坏了会让**反例假过**（"目录非法"其实是"目录合法"）或**正例假红**。
cat_d_n="$(diff "$TMP/catalog-valid.json" "$TMP/catalog-broken.json" | grep -c '^[<>]')"
f0a_rc=0; [ "$cat_d_n" -eq 2 ] || f0a_rc=1
assert_case "F0a 夹具自检：两模式只差 catalog 一处" "$f0a_rc" "catalog 差异 ${cat_d_n} 行（期望 2）"
make_consumer_fixture valid
f0b_rc=0
(cd "$CONSUMER_DIR" && node scripts/check-components.mjs >/dev/null 2>&1) || f0b_rc=1
assert_case "F0b 夹具自检：valid 模式目录校验通过" "$f0b_rc" "valid catalog 竟被拒——F3 的结论不可信"
make_consumer_fixture broken
cat_out="$(cd "$CONSUMER_DIR" && node scripts/check-components.mjs 2>&1)"; cat_rc_v=$?
cat_n="$(printf '%s' "$cat_out" | grep -c '✗')"
f0c_rc=0
[ "$cat_rc_v" -ne 0 ] || f0c_rc=1
[ "$cat_n" -eq 1 ] || f0c_rc=1
assert_case "F0c 夹具自检：broken 模式恰好 1 条 ✗" "$f0c_rc" "rc=${cat_rc_v}、✗×${cat_n}（期望 rc≠0 且恰 1 条）"

# ── F1：查询器（F2 的**前提**）──────────────────────────────────────────────
# 造一个 catalog 非法、但子仓齐备的最小仓库：与主 fixture（$TMP）分开，因为要测的是
# **查询器自身**的契约，与任何消费者无关（消费者另有一棵功能完整的树，见上）。
make_subrepo_broken() { # 造一个 catalog 非法、但子仓齐备的最小仓库
  mkdir -p "$TMP/broken/scripts" "$TMP/broken/config" "$TMP/broken/plugins/bad"
  cp "$ROOT/scripts/check-components.mjs" "$TMP/broken/scripts/"
  # runtimeScope=excluded 但 releaseScope 含 bundle —— catalog 阶段不变量即失败
  cat > "$TMP/broken/config/components.json" <<'JSON'
{ "version": 2, "description": "broken fixture",
  "components": [ { "name": "bad", "path": "plugins/bad", "sourceAuthority": "github",
    "pinPolicy": "tag", "pinRef": "v1", "ciScope": ["build"],
    "releaseScope": ["bundle"], "runtimeScope": "excluded", "prepareMode": "none",
    "platforms": [], "testProfile": "none", "stateSchema": "none", "license": "MIT" } ] }
JSON
  printf '[submodule "plugins/bad"]\n\tpath = plugins/bad\n\turl = https://example.invalid/bad.git\n' > "$TMP/broken/.gitmodules"
  printf '{"name":"bad","license":"MIT"}' > "$TMP/broken/plugins/bad/package.json"
}
make_subrepo_broken

# 消费者能 fail closed 的唯一依据，是它们 `$()` 捕获到的那条非零退出**真的存在**。若
# `--list` 改成"打印错误但 rc=0、stdout 空"，消费者再怎么写都会拿到空集。
# 判据取 rc + ✗ 的**条数**（不取文案，同 run_case），并确认恰好 1 条 ✗ ——非零退出必须
# 是**那条不变量**判的，不是崩了。
f1_out="$(cd "$TMP/broken" && node scripts/check-components.mjs --list runtime:excluded 2>&1)"; f1_rc=$?
f1_n="$(printf '%s' "$f1_out" | grep -c '✗')"
if [ "$f1_rc" -eq 0 ]; then
  printf '  %-44s %s\n' "F1 非法目录下 --list 必须失败" "!! 竟然成功（fail-open）"; FAILED=$((FAILED + 1))
elif [ "$f1_n" -ne 1 ]; then
  printf '  %-44s %s\n' "F1 非法目录下 --list 必须失败" "!! 非零退出但非唯一归因（✗×${f1_n}）"; FAILED=$((FAILED + 1))
else
  printf '  %-44s %s\n' "F1 非法目录下 --list 必须失败" "ok"
  printf '       理由(✗×%s): %s\n' "$f1_n" "$(printf '%s' "$f1_out" | grep -m1 '✗' | cut -c1-80)"
fi

# ── F2：行为（反例）—— 目录非法 ⇒ 必须拒绝执行，且一次挂载都不发生 ──────────────
# 断言取**后果**（退出码 + 挂载调用次数），不取文案。零挂载这一半才是要点：只在查询处
# 报个错、却照样把 dsh-tui 挂进 profile，是**没有**修好（实测过这个形态）。
make_consumer_fixture broken
consumer_run "$CONSUMER_DIR/scripts/link-plugins.sh" broken
f2_rc_v=$CONSUMER_RC; f2_n_v=$CONSUMER_CALLS
consumer_refused_last; assert_case "F2 非法目录 ⇒ 拒绝执行且零挂载（行为）" $? "实测 rc=${f2_rc_v}、挂载 ${f2_n_v} 次——目录非法却照跑"
printf '       实测: rc=%s、挂载调用=%s 次\n' "$f2_rc_v" "$f2_n_v"

# ── F3：行为（正例）—— 目录合法 ⇒ 成功，且只挂非 excluded 的那个 ────────────────
# F3 不是装饰：它证明**这棵树真的能跑到挂载那一步**。没有它，F2 的"零挂载"可能只是
# "夹具根本跑不起来"（那正是简报判"行为断言必假绿"的形态）；有了它，F2 的非零退出与
# 零挂载就只能是目录非法造成的。顺手把排除语义也钉住：excluded 的 dsh-tui 不得被挂。
make_consumer_fixture valid
consumer_run "$CONSUMER_DIR/scripts/link-plugins.sh" valid
f3_rc_v=$CONSUMER_RC; f3_n_v=$CONSUMER_CALLS
f3_log="$(cat "$CONSUMER_PNPM_LOG")"
f3_bad=""
[ "$f3_rc_v" -eq 0 ] || f3_bad="应成功，实测 rc=${f3_rc_v}"
[ "$f3_n_v" -eq 1 ] || f3_bad="${f3_bad}；应恰好 1 次挂载，实测 ${f3_n_v} 次"
printf '%s' "$f3_log" | grep -q 'plugins/bundle-a' || f3_bad="${f3_bad}；挂载调用里没有 bundle-a"
printf '%s' "$f3_log" | grep -q 'plugins/dsh-tui' && f3_bad="${f3_bad}；excluded 的 dsh-tui 被挂载了"
f3_rc=0; [ -z "$f3_bad" ] || f3_rc=1
assert_case "F3 合法目录 ⇒ 成功且只挂 bundle-a（正例）" "$f3_rc" "$f3_bad"
printf '       实测: rc=%s、挂载调用=%s 次\n' "$f3_rc_v" "$f3_n_v"

# ── F4：装置自测 —— 三个真实的 fail-open 形态**必须都被判红** ───────────────────
# 不带这条，F2 可能是个恒绿的摆设：判据写得再漂亮，只要它抓不住任何一种真形态，就没有
# 兑现"防回退"的作用。故把本次任务里出现过的三种形态各注入一次，逐个跑，断言装置
# 判它们"没拒绝"。锚点未命中（源文件改过）⇒ 本用例判红，绝不静默变成"变异已生效"。
write_mutant_block() { # $1=形态名 → 写 $TMP/mut-<名>.txt
  case "$1" in
    no-guard)  # 保留 $() 与 herestring，只删掉 `if !` 守卫（两段式被"一行化"的常见产物）
      cat > "$TMP/mut-no-guard.txt" <<'MUT'
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done <<< "$(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded)"
MUT
      ;;
    swallow)   # 原形态：连 stderr 带退出码一起吞
      cat > "$TMP/mut-swallow.txt" <<'MUT'
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done < <(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded 2>/dev/null || true)
MUT
      ;;
    naked)     # "只删掉 || true"：错误不静默了，但退出码照样进不了 done 的状态
      cat > "$TMP/mut-naked.txt" <<'MUT'
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done < <(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded)
MUT
      ;;
  esac
}
make_consumer_mutant() { # $1=目标文件  $2=形态名；锚点必须命中
  cat > "$TMP/.mut-old.txt" <<'OLD'
if ! _excluded="$(node "$ROOT/scripts/check-components.mjs" --list runtime:excluded)"; then
  echo "错误: 组件目录查询失败（原因见上）。link-plugins 拒绝在未知的排除集上继续。" >&2
  exit 1
fi
SKIP_MOUNT=()
while IFS= read -r _p; do
  [ -n "$_p" ] && SKIP_MOUNT+=("$_p")
done <<< "$_excluded"
OLD
  write_mutant_block "$2"
  node -e '
    const fs = require("fs")
    const [src, dst, oldF, newF] = process.argv.slice(1)
    const t = fs.readFileSync(src, "utf8"), o = fs.readFileSync(oldF, "utf8")
    if (!t.includes(o)) { console.error("锚点未命中（被测脚本已改过？）"); process.exit(1) }
    fs.writeFileSync(dst, t.replace(o, fs.readFileSync(newF, "utf8")))
  ' "$CONSUMER_DIR/scripts/link-plugins.sh" "$1" "$TMP/.mut-old.txt" "$TMP/mut-$2.txt" 2>"$TMP/.mut-err"
}

for _m in no-guard swallow naked; do
  make_consumer_fixture broken
  if ! make_consumer_mutant "$CONSUMER_DIR/scripts/link-plugins.$_m.sh" "$_m"; then
    assert_case "F4 变异 $_m 必须生效" 1 "变异注入失败（$(head -1 "$TMP/.mut-err")）——本组自测不可信"
    continue
  fi
  consumer_run "$CONSUMER_DIR/scripts/link-plugins.$_m.sh" "mut-$_m"
  # `!` 在这里**是判据本身**（同 D2）：装置必须把这个形态判成"没拒绝"。判成"拒绝"就说明
  # F2 是恒绿的摆设——那正是本组存在的理由。
  ! consumer_refused_last; mut_rc=$?
  assert_case "F4 变异 $_m 形态必须被判红" "$mut_rc" "装置没抓住（rc=${CONSUMER_RC}、挂载 ${CONSUMER_CALLS} 次）"
  printf '       该形态实测: rc=%s、挂载调用=%s 次（装置判红 ⇒ 二者至少一项非"拒绝"）\n' "$CONSUMER_RC" "$CONSUMER_CALLS"
done

# ── F5：静态补充（**不是**唯一判据）──────────────────────────────────────────
# F2 已经从**行为**上覆盖了本组要防的东西；这条留着只因它能更早、更精确地指出"问题在
# 查询那一行"，而不必去读运行输出。
# ⚠️ 它是静态检查：挡不住 `2>/dev/null || :` 这类改写，也**只会多报不会漏报**——理论上
#    存在别的机制把退出码补回来的写法会被它误判红。故它**不能**单独当门禁判据。
# ⚠️ 判据只作用于**目录查询那一行**，不是文件级裸串匹配：两个文件里各有别处也含
#    `2>/dev/null || true`，却与目录查询无关、失败方向相反（读不到锚点 ⇒ 重写锚点，是
#    安全方向），且不在本任务范围内。按名称找是这几处（**刻意不写行号**——上一版写死的
#    行号在本任务落地后全部失效，按图索骥会落到无关行上）：
#      · link-plugins.sh / remote-install.sh 的 pnpm 版本锚点读取（ANCHORED=…）
#      · remote-install.sh 的 pnpm 解析探测（pnpm --version）与 shim 定位（command -v pnpm）
#    恒红的用例不区分"修好了"与"没修"，等于没有装置。
for f in scripts/link-plugins.sh deploy/remote-install.sh; do
  # 只认**调用行**：文件里的注释也提到过 `--list runtime:excluded`，但它不含脚本名，
  # 故用 `check-components.mjs … --list runtime:excluded` 作判据，注释不会误命中。
  f5_call="$(grep -E 'check-components\.mjs.*--list runtime:excluded' "$ROOT/$f" 2>/dev/null)"
  f5_bad=""
  if [ -z "$f5_call" ]; then
    f5_bad="文件里找不到该目录查询调用（用例过时，须复核）"
  elif printf '%s\n' "$f5_call" | grep -q '2>/dev/null'; then
    f5_bad="目录查询行仍吞错：$(printf '%s' "$f5_call" | tr -s ' ' | cut -c1-60)"
  # 第二条判据：查询走进程替换。**没有已知的** `< <(…)` 写法能拿到该命令的退出码
  # （`< <(cmd; echo $? > f)` 这类把 rc 写进文件的写法能拿到值，但它**仍会被本条判红**：
  # 判据只会**多报**、不会漏报，方向安全）。
  elif printf '%s\n' "$f5_call" | grep -qE '<[[:space:]]*<\('; then
    f5_bad="目录查询仍走进程替换（退出码被丢弃，等同 fail open）：$(printf '%s' "$f5_call" | tr -s ' ' | cut -c1-60)"
  fi
  if [ -n "$f5_bad" ]; then
    printf '  %-44s %s\n' "F5 $f 目录查询行形态（静态补充）" "!! $f5_bad"; FAILED=$((FAILED + 1))
  else
    printf '  %-44s %s\n' "F5 $f 目录查询行形态（静态补充）" "ok"
  fi
done

echo
if [ "$STRICT" = 1 ] && [ "$FAILED" -ne 0 ]; then
  echo "✗ --strict：${FAILED} 项与预期不符。"
  exit 1
fi
exit 0
