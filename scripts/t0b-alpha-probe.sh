#!/usr/bin/env bash
# t0b-alpha-probe.sh — T0b 第一段：发布布局与切换机制（合成 payload，不构建 DSH）
#
# 目的：在**真机、非 root** 下验证 T0b 打算采用的发布机制是否成立，而不是等实现完
# 才发现机制本身有问题。用合成 payload 是刻意的——布局机制与 payload 内容无关，
# 而真实 DSH 构建要 10-30 分钟、数 GB，不该拿它来测「符号链接切换是否原子」。
#
# 验证七件事：
#   1 建 release：staging 写完再原子改名，半成品不会以 release 名出现
#   2 current 原子切换（rename(2)，不是先 unlink 再 symlink）
#   3 回滚到 previous
#   4 部署中途失败：current 不变、staging 不残留
#   5 release 目录只读时应用仍能跑；状态写 STATE_DIR，不写代码目录
#   6 幂等：同一 digest 重跑不重建
#   7 并发切换后 current 必须指向某个**完整** release
#
# 全程只在 $SCRATCH 内操作；全部通过则清理，失败则保留供排查。
# 不碰系统路径、不装包、不改 systemd。
# 用法：bash t0b-alpha-probe.sh [scratch 目录]

set -uo pipefail

SCRATCH="${1:-$HOME/dsh-t0b-alpha}"
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
step() { printf '\n== %s\n' "$1"; }

# 合成的「应用」：报告自己的版本，并**只**往 STATE_DIR 写状态。
# 「只往 STATE_DIR 写」正是第 5 步要验的性质。
make_app() { # $1=目标目录  $2=版本
  mkdir -p "$1/bin"
  cat > "$1/bin/app" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ -n "\${STATE_DIR:-}" ] || { echo "STATE_DIR 未设置" >&2; exit 1; }
mkdir -p "\$STATE_DIR"
echo "$2" > "\$STATE_DIR/last-run-version"
printf 'app %s 启动成功，状态已写 STATE_DIR\n' "$2"
EOF
  chmod +x "$1/bin/app"
  echo "$2" > "$1/VERSION"
}

atomic_switch() { # $1=releases 下的目标名
  # 临时名必须**每次调用唯一**：bash 的 $$ 在子 shell 里不变，并发调用会撞名。
  local tmp="current.tmp.${BASHPID:-$$}.$RANDOM"
  ln -sfn "$1" "$tmp"
  mv -T "$tmp" current
}

# 最小 deploy：staging → 原子晋级 → 原子切换；失败则丢弃 staging 且不动 current。
deploy() { # $1=digest  $2=版本  $3=可选的失败注入点
  local d="$1" v="$2" inject="${3:-}"
  if [ -e "releases/$d" ]; then echo "  (skip: $d 已存在)"; return 0; fi
  local staging="releases/.staging-$d"
  rm -rf "$staging"; mkdir -p "$staging"
  make_app "$staging" "$v"
  if [ "$inject" = "fail-before-promote" ]; then
    rm -rf "$staging"; return 1                    # 晋级前失败
  fi
  mv -T "$staging" "releases/$d" || { rm -rf "$staging"; return 1; }
  atomic_switch "$d" || return 1
  return 0
}

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/releases" "$SCRATCH/state"
cd "$SCRATCH" || exit 1
echo "scratch: $SCRATCH"
echo "user: $(id -un) (uid=$(id -u))，非 root: $([ "$(id -u)" != 0 ] && echo 是 || echo 否)"

D1="$(printf 'a%.0s' {1..40})"; D2="$(printf 'b%.0s' {1..40})"

step "1 建 release（staging → 原子晋级）"
if deploy "$D1" "v1" && [ -f "releases/$D1/bin/app" ] && [ ! -e "releases/.staging-$D1" ]; then
  pass "release 以完整形态出现，staging 名已消失"
else
  fail "首次部署不成立"
fi

step "2 原子切换"
if [ -L current ] && [ "$(readlink current)" = "$D1" ]; then
  pass "current → ${D1:0:8}…"
else
  fail "current 未正确建立"
fi

step "3 回滚到 previous"
PREV="$(readlink current)"
deploy "$D2" "v2" >/dev/null
if [ "$(readlink current)" = "$D2" ]; then pass "已切到 ${D2:0:8}…"; else fail "切换失败"; fi
atomic_switch "$PREV"
if [ "$(readlink current)" = "$D1" ]; then pass "已回滚到 ${D1:0:8}…"; else fail "回滚失败"; fi

step "4 部署中途失败：current 不变、staging 不残留"
BEFORE="$(readlink current)"
D3="$(printf 'c%.0s' {1..40})"
if deploy "$D3" "v3" "fail-before-promote"; then
  fail "失败注入未生效（deploy 返回 0）"
else
  if [ "$(readlink current)" = "$BEFORE" ]; then
    pass "current 未变（仍指向 ${BEFORE:0:8}…）"
  else
    fail "失败影响了 current"
  fi
  if [ ! -e "releases/$D3" ]; then pass "失败未留下 release 目录"; else fail "失败留下了 releases/$D3"; fi
  if [ ! -e "releases/.staging-$D3" ]; then pass "失败未留下 staging 残留"; else fail "staging 残留未清理"; fi
fi

step "5 release 只读时应用仍能跑；状态不写代码目录"
deploy "$D2" "v2" >/dev/null; atomic_switch "$D2"
SNAP="$(find "releases/$D2" -type f -printf '%p %s\n' | sort | md5sum)"
chmod -R a-w "releases/$D2"
out="$(STATE_DIR="$SCRATCH/state" "releases/$D2/bin/app" 2>&1)"; rc=$?
chmod -R u+w "releases/$D2"
if [ "$rc" -eq 0 ]; then pass "只读 release 下应用退出码 0（${out}）"; else fail "只读 release 下应用失败 rc=${rc}：${out}"; fi
if [ -f "$SCRATCH/state/last-run-version" ]; then
  pass "状态落在 STATE_DIR（值=$(cat "$SCRATCH/state/last-run-version")）"
else
  fail "状态未写入 STATE_DIR"
fi
NOW="$(find "releases/$D2" -type f -printf '%p %s\n' | sort | md5sum)"
if [ "$SNAP" = "$NOW" ]; then
  pass "release 目录内容逐字节未变——代码与状态确实分离"
else
  fail "release 目录被改动（文件清单/大小变化）"
fi

step "6 幂等：同一 digest 重跑不重建"
INO_BEFORE="$(stat -c '%i' "releases/$D2")"
MTIME_BEFORE="$(stat -c '%Y' "releases/$D2")"
deploy "$D2" "v2-should-not-apply" >/dev/null
INO_AFTER="$(stat -c '%i' "releases/$D2")"; MTIME_AFTER="$(stat -c '%Y' "releases/$D2")"
if [ "$INO_BEFORE" = "$INO_AFTER" ] && [ "$MTIME_BEFORE" = "$MTIME_AFTER" ]; then
  pass "inode 与 mtime 均未变——未重建"
else
  fail "digest 被重建（inode/mtime 变化）"
fi
if [ "$(cat "releases/$D2/VERSION")" = "v2" ]; then
  pass "内容未被覆盖（VERSION 仍为 v2，非 v2-should-not-apply）"
else
  fail "内容被覆盖"
fi
if ls -d releases/.staging-* >/dev/null 2>&1; then fail "重跑留下了 staging 残留"; else pass "无 staging 残留"; fi

step "7 并发切换"
atomic_switch "$D1" & atomic_switch "$D2" &
wait
target="$(readlink current)"
if [ "$target" = "$D1" ] || [ "$target" = "$D2" ]; then
  pass "并发后 current 指向完整 release（${target:0:8}…），无半成品"
else
  fail "并发后 current 指向意外目标：$target"
fi
if ls -d current.tmp.* >/dev/null 2>&1; then fail "并发留下临时链接残留"; else pass "无临时链接残留"; fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "全部通过。清理 scratch。"
  rm -rf "$SCRATCH"
  exit 0
else
  echo "$FAILED 项失败。保留 $SCRATCH 供排查。"
  exit 1
fi
