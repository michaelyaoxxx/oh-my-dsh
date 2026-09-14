#!/usr/bin/env bash
# check-pins.sh — submodule pin 的**单一事实来源**：清单 + 校验 + 枚举
#
# 为什么存在：这份清单与校验逻辑原本在三处各写一遍——
#   scripts/release.sh               （check_pin / check_pin_tag）
#   .github/workflows/verify.yaml    （分支 loop + tag loop）
#   .github/workflows/release.yaml   （快照清单的 sub 列表）
# 三份手工同步，**新增插件时漏改一处，那条通路就静默失守**。
# 本脚本是唯一实现，三处都调它。
#
# 两类 pin 语义：
#   branch —— 与 origin/<branch> 比对；拦截「本地未推送的 commit 被误 pin」
#   tag    —— 与 <tag>^{} 比对；tag 存在于远端即已发布，与分支比对同语义
#             （^{} 剥离 annotated tag：直接 rev-parse <tag> 返回标签对象哈希，
#              与 HEAD 的 commit 比对必假；对轻量 tag 是 no-op，两者兼容）
#
# 用法：
#   bash scripts/check-pins.sh            # 校验全部（CI 与 release 都调它）
#   bash scripts/check-pins.sh --list     # 枚举清单，每行 <path>\t<kind>\t<ref>
#                                         # （供 release.sh / release.yaml 生成快照，避免再抄一遍列表）
#
# 退出码：0 全部一致；1 任一不一致或无法核对
set -euo pipefail
cd "$(dirname "$0")/.."

# ── 清单：唯一事实来源 ────────────────────────────────────────────────
# 格式 <path>:<kind>:<ref>；kind ∈ {branch, tag}
# 分支 pin 的仓库（其稳定分支会推进，故按分支比对）
BRANCH_PINS=(
  "plugins/dsh-web:main"
  "plugins/dsh-plugin-mineru:master"
  # dsh-automation pin 自己 fork 上的适配分支（上游不含 harness 0.1.5-rc.2 所需的适配）
  "plugins/dsh-automation:adapt/harness-0.1.5-rc.2"
)
# tag pin 的仓库（发行 tag 不可变，故按 tag 比对）
TAG_PINS=(
  "harness:dsh-v0.1.5-rc.2"
  "plugins/dsh-better-sidebar:v0.18.1"
  "plugins/modlens:v3.26.1"
  "plugins/dsh-market:v1.45.1"
  "plugins/dsh-agent-teams:v0.1.17-rc.1"
  "plugins/dsh-at-file:v0.7.0"
  "plugins/modsearch:v5.10.2"
  "plugins/dsh-tui:v0.10.1"
)

if [ "${1:-}" = "--list" ]; then
  for p in "${BRANCH_PINS[@]}"; do printf '%s\tbranch\t%s\n' "${p%%:*}" "${p#*:}"; done
  for p in "${TAG_PINS[@]}"; do printf '%s\ttag\t%s\n' "${p%%:*}" "${p#*:}"; done
  exit 0
fi

# 读 pin：submodule 未初始化或目录缺失时给可执行的提示，而不是裸报错。
pinned_sha() { # $1=path
  local sha
  if ! sha=$(git -C "$1" rev-parse HEAD 2>/dev/null); then
    echo "错误: 无法读取 $1 的 pin（submodule 未初始化或目录缺失？）。请先运行 make setup 初始化 submodule。" >&2
    exit 1
  fi
  printf '%s' "$sha"
}

# 分支 pin：与 origin/<branch> 比对
check_pin() { # $1=path  $2=branch
  local sub="$1" branch="$2" pinned remote
  pinned="$(pinned_sha "$sub")"
  if ! git -C "$sub" fetch origin "$branch" >/dev/null 2>&1; then
    echo "错误: $sub fetch origin $branch 失败，无法核对 pin。请检查网络后手动执行: git -C $sub fetch origin $branch" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "origin/$branch"); then
    echo "错误: $sub 缺少远端分支 origin/$branch，无法核对 pin。请确认远端存在该分支并手动执行: git -C $sub fetch origin $branch" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 $branch($remote) 不一致" >&2
    echo "如已推送，请先 git submodule update --remote 或显式更新 pin 再发布" >&2
    exit 1
  fi
  echo "  ok  $sub  →  $branch"
}

# tag pin：与 <tag>^{} 比对
check_pin_tag() { # $1=path  $2=tag
  local sub="$1" tag="$2" pinned remote
  pinned="$(pinned_sha "$sub")"
  if ! git -C "$sub" fetch origin "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "错误: $sub fetch origin tag $tag 失败，无法核对 pin。请检查网络后手动执行: git -C $sub fetch origin refs/tags/$tag" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "${tag}^{}"); then
    echo "错误: $sub 缺少 tag $tag，无法核对 pin。请确认远端存在该 tag 并手动执行: git -C $sub fetch origin refs/tags/$tag" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 tag $tag($remote) 不一致" >&2
    echo "如已发布，请显式更新 pin 再发布" >&2
    exit 1
  fi
  echo "  ok  $sub  →  $tag"
}

echo "==> 校验 submodule pin（分支 ${#BRANCH_PINS[@]} 条 / tag ${#TAG_PINS[@]} 条）"
for p in "${BRANCH_PINS[@]}"; do check_pin "${p%%:*}" "${p#*:}"; done
for p in "${TAG_PINS[@]}";    do check_pin_tag "${p%%:*}" "${p#*:}"; done
echo "✓ 全部 pin 与远端一致"
