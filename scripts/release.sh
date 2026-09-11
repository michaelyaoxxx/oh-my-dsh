#!/usr/bin/env bash
# release.sh — 校验 pin → 生成快照清单 → 打 tag → push（发布主仓快照）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# 1. 工作区干净
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "工作区有未提交修改，先提交再发布" >&2
  exit 1
fi

# 2. 子模块 pin 与稳定分支一致（防本地未推送 commit 被误 pin）
check_pin() { # $1=path  $2=stable_branch
  local sub="$1" branch="$2"
  local pinned remote
  if ! pinned=$(git -C "$sub" rev-parse HEAD 2>/dev/null); then
    echo "错误: 无法读取 ${sub} 的 pin（submodule 未初始化或目录缺失？）。请先运行 make setup 初始化 submodule。" >&2
    exit 1
  fi
  if ! git -C "$sub" fetch origin "$branch" >/dev/null 2>&1; then
    echo "错误: ${sub} fetch origin ${branch} 失败，无法核对 pin。请检查网络后手动执行: git -C ${sub} fetch origin ${branch}" >&2
    exit 1
  fi
  if ! remote=$(git -C "$sub" rev-parse "origin/$branch"); then
    echo "错误: ${sub} 缺少远端分支 origin/${branch}，无法核对 pin。请确认远端存在该分支并手动执行: git -C ${sub} fetch origin ${branch}" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 $branch($remote) 不一致" >&2
    echo "如已推送，请先 git submodule update --remote 或显式更新 pin 再发布" >&2
    exit 1
  fi
}
check_pin plugins/dsh-web main
check_pin plugins/dsh-plugin-mineru master

# tag-pin 校验：submodule pin 与远端正式 tag 一致（dsh-better-sidebar 等按 tag 发布的插件仓；
# tag 存在于远端即已发布，与分支比对的「防本地未推送 commit 被误 pin」同语义）。
check_pin_tag() { # $1=path  $2=tag
  local sub="$1" tag="$2"
  local pinned remote
  if ! pinned=$(git -C "$sub" rev-parse HEAD 2>/dev/null); then
    echo "错误: 无法读取 ${sub} 的 pin（submodule 未初始化或目录缺失？）。请先运行 make setup 初始化 submodule。" >&2
    exit 1
  fi
  if ! git -C "$sub" fetch origin "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "错误: ${sub} fetch origin tag ${tag} 失败，无法核对 pin。请检查网络后手动执行: git -C ${sub} fetch origin refs/tags/${tag}" >&2
    exit 1
  fi
  # ^{} 剥离 annotated tag：rev-parse <tag> 对注释标签返回标签对象哈希（≠ commit），
  # 与 HEAD（commit）比对必假；^{} 对轻量标签是 no-op，两者兼容。
  if ! remote=$(git -C "$sub" rev-parse "${tag}^{}"); then
    echo "错误: ${sub} 缺少 tag ${tag}，无法核对 pin。请确认远端存在该 tag 并手动执行: git -C ${sub} fetch origin refs/tags/${tag}" >&2
    exit 1
  fi
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 tag ${tag}($remote) 不一致" >&2
    echo "如已发布，请显式更新 pin 再发布" >&2
    exit 1
  fi
}
check_pin_tag harness dsh-v0.1.5-rc.2
check_pin_tag plugins/dsh-better-sidebar v0.18.1
check_pin_tag plugins/modlens v3.26.1

# 3. 版本号
VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "用法: make release VERSION=v0.1.0 或 bash scripts/release.sh v0.1.0" >&2; exit 1; }
case "$VERSION" in v*) ;; *) VERSION="v$VERSION";; esac
git tag -l "$VERSION" | grep -q . && { echo "tag $VERSION 已存在（若上次推送失败：git tag -d $VERSION 后重试）" >&2; exit 1; }

# 4. 快照清单
SNAPSHOT="$ROOT/RELEASE_NOTES.md"
echo "# Release $VERSION 快照清单" > "$SNAPSHOT"
echo "" >> "$SNAPSHOT"
snapshot_row() { # $1=path（名称取 basename，与 release.yaml 的 manifest 一致）
  local sub="$1" name sha ver=""
  name="$(basename "$1")"
  sha=$(git -C "$sub" rev-parse HEAD)
  # describe 失败且 package.json 无 version 字段时 node -p 会打印 "undefined" 且 exit 0，
  # `|| echo "-"` 兜底不触发；用 || '-' 让兜底在版本缺失时生效。
  ver=$(git -C "$sub" describe --tags --abbrev=0 2>/dev/null || node -p "require('./$sub/package.json').version || '-'" 2>/dev/null || echo "-")
  echo "- $name: \`$sha\` ($ver)" >> "$SNAPSHOT"
}
snapshot_row harness
snapshot_row plugins/dsh-web
cat "$SNAPSHOT"

# 5. tag + push（RELEASE_NOTES 只作记录，不入库）
# 只认 origin：其他名字的远端即使存在也无法保证 push 目标，须在打 tag 前拦截。
if ! git remote | grep -qx '^origin$'; then
  echo "错误: 主仓未配置 origin 远端，无法推送发布 tag。" >&2
  echo "请先创建远端仓（如 GitHub 私有仓 dsh）并执行: git remote add origin <url>，再重跑本脚本。" >&2
  echo "注: 本次运行未打 tag、未推送；快照清单已写入 RELEASE_NOTES.md（未提交，可删除）。" >&2
  exit 1
fi
git tag -a --cleanup=verbatim "$VERSION" -F "$SNAPSHOT"
git push origin "$VERSION"
echo "已发布 $VERSION"
