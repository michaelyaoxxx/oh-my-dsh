#!/usr/bin/env bash
# check-pins.sh — 组件 pin 校验（清单来自 config/components.json，单一事实源）
#
# 清单不再写在本文件里：新增/移除 submodule 时改 config/components.json 一处即可
# （scripts/check-components.mjs 会与 .gitmodules 做双向校验，防止漏登记）。
#
# 两类 pin 语义（2026-09-15 拆开，见下）：
#   tag pin    → gitlink SHA 必须**等于** <tag>^{}。tag 不可变，等于即身份确认。
#   branch pin → gitlink SHA 必须**可从 origin/<branch> 到达**（祖先关系）。
#
# ⚠️ **为什么 branch pin 不再要求「等于分支头」**：
#   那样一来，上游分支一推进，**历史超级仓提交就永远校验失败、无法重建**。
#   本仓实际踩到过：dsh-web 的 pin 落后 origin/main 191 个提交 → CI 恒红，
#   而那个 pin 本身完全正确。这是把「可重现性」和「是否最新」混为一谈。
#   现在：构建/发布门禁只要求「这个 commit 真实存在于该分支的历史上」；
#   「落后多少」是**漂移信息**，由 --drift 报告，不阻断构建。
#
# 用法：
#   bash scripts/check-pins.sh            # 校验（构建/发布门禁；不一致则 exit 1）
#   bash scripts/check-pins.sh --drift    # 只报告各 branch pin 落后多少提交（恒 exit 0）
#   bash scripts/check-pins.sh --list     # 枚举 <path>\t<kind>\t<ref>（供 snapshot 生成消费）
#
# 退出码：0 通过；1 任一不一致或无法核对
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# 读清单：config/components.json → 每行 <path>\t<kind>\t<ref>
read_pins() {
  node -e '
    const c = require(process.argv[1])
    for (const x of c.components) console.log([x.path, x.pinPolicy, x.pinRef].join("\t"))
  ' "$ROOT/config/components.json"
}

if [ "${1:-}" = "--list" ]; then
  read_pins
  exit 0
fi

# 读 pin：submodule 未初始化或目录缺失时给可执行的提示，而不是裸报错。
pinned_sha() { # $1=path
  local sha
  if ! sha=$(git -C "$1" rev-parse HEAD 2>/dev/null); then
    echo "错误: 无法读取 $1 的 pin（submodule 未初始化或目录缺失？）。请先运行 make setup。" >&2
    exit 1
  fi
  printf '%s' "$sha"
}

# tag pin：必须等于 <tag>^{}
check_pin_tag() { # $1=path  $2=tag
  local sub="$1" tag="$2" pinned remote
  pinned="$(pinned_sha "$sub")"
  if ! git -C "$sub" fetch origin "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "错误: $sub fetch origin tag $tag 失败。请检查网络后手动执行: git -C $sub fetch origin refs/tags/$tag" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "${tag}^{}"); then
    echo "错误: $sub 缺少 tag ${tag}。请确认远端存在该 tag。" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 tag ${tag}($remote) 不一致" >&2
    echo "如已发布，请显式更新 pin 再发布" >&2
    exit 1
  fi
  echo "  ok  ${sub}  →  tag ${tag}"
}

# branch pin：必须**可从** origin/<branch> 到达（祖先关系，不要求等于分支头）
check_pin_branch() { # $1=path  $2=branch
  local sub="$1" branch="$2" pinned remote
  pinned="$(pinned_sha "$sub")"
  if ! git -C "$sub" fetch origin "$branch" >/dev/null 2>&1; then
    echo "错误: $sub fetch origin $branch 失败。请检查网络后手动执行: git -C $sub fetch origin $branch" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "origin/$branch"); then
    echo "错误: $sub 缺少远端分支 origin/${branch}。" >&2
    exit 1
  fi
  # ① pin 必须是一个真实存在的 commit 对象
  if ! git -C "$sub" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
    echo "警告: $sub 的 pin($pinned) 在本地不是一个 commit 对象（submodule 未完整拉取？）" >&2
    exit 1
  fi
  # ② 必须能从 origin/<branch> 到达 —— 这排除了「本地未推送的 commit 被误 pin」
  if ! git -C "$sub" merge-base --is-ancestor "$pinned" "$remote" 2>/dev/null; then
    echo "警告: $sub 的 pin($pinned) 不是 origin/${branch}($remote) 的历史提交" >&2
    echo "可能原因：pin 的是本地未推送的 commit，或该分支已被 force-push 重写。" >&2
    exit 1
  fi
  local behind
  behind=$(git -C "$sub" rev-list --count "${pinned}..${remote}" 2>/dev/null || echo "?")
  if [ "$behind" = "0" ]; then
    echo "  ok  ${sub}  →  branch ${branch}（与分支头一致）"
  else
    echo "  ok  ${sub}  →  branch ${branch}（可达；落后 ${behind} 个提交，见 --drift）"
  fi
}

# 漂移报告：只报信息，恒 exit 0
drift_report() {
  echo "==> 分支 pin 漂移报告（仅信息，不阻断）"
  local any=0
  while IFS=$'\t' read -r sub kind ref; do
    [ "$kind" = "branch" ] || continue
    any=1
    local pinned remote behind
    pinned="$(git -C "$sub" rev-parse HEAD 2>/dev/null || echo '?')"
    if ! git -C "$sub" fetch origin "$ref" >/dev/null 2>&1; then
      echo "  ?  ${sub}: 无法 fetch origin/${ref}"
      continue
    fi
    remote="$(git -C "$sub" rev-parse "origin/$ref" 2>/dev/null || echo '?')"
    behind=$(git -C "$sub" rev-list --count "${pinned}..${remote}" 2>/dev/null || echo '?')
    if [ "$behind" = "0" ]; then
      echo "  ✓  ${sub}: 与 origin/${ref} 一致"
    else
      echo "  ↑  ${sub}: 落后 origin/${ref} ${behind} 个提交（pin=${pinned:0:7} → ${remote:0:7}）"
    fi
  done < <(read_pins)
  [ "$any" = 1 ] || echo "  （无 branch pin 组件）"
  echo "提示：落后不代表错误。仅当需要吸收上游修复时才更新 pin（更新后须重跑构建与测试）。"
}

if [ "${1:-}" = "--drift" ]; then
  drift_report
  exit 0
fi

# ── 默认：校验 ──
n_tag=0; n_branch=0
while IFS=$'\t' read -r sub kind ref; do
  case "$kind" in tag) n_tag=$((n_tag+1));; branch) n_branch=$((n_branch+1));; esac
done < <(read_pins)

echo "==> 校验组件 pin（清单：config/components.json；tag ${n_tag} 条 / branch ${n_branch} 条）"
while IFS=$'\t' read -r sub kind ref; do
  case "$kind" in
    tag)    check_pin_tag "$sub" "$ref" ;;
    branch) check_pin_branch "$sub" "$ref" ;;
    *) echo "错误: 未知 pinPolicy '${kind}'（组件 ${sub}）" >&2; exit 1 ;;
  esac
done < <(read_pins)
echo "✓ 全部 pin 校验通过"
