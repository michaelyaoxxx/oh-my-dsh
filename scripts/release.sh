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

# 1.5 离线门禁：与 verify **同一份清单**（唯一事实源 scripts/check-all.sh）。
#     此前这里只跑 check-pins —— **许可证内容检查被整条绕过**：一个目录与
#     package.json 都伪装成 MIT、LICENSE 内容却是 GPL 的 tag，可以走 release 路径。
#     见 docs/reviews/2026-09-15-incremental-design-review.md P1-1。
#
#     ⚠️ `--require-materialized` 不能省：ADR-0005 §3 与 config/README.md 都写
#     「**CI 与 release 必须用**」，verify.yaml / release.yaml 也都带了它。少了这个旗标，
#     两条路径**不是同一道门**：子仓未初始化 / 无 git 元数据的检出上，materialized 阶段
#     会被**静默跳过**并照常通过——正是 ADR 决策 3 要在 release 路径上堵掉的 fail-open。
#     （实务上第 2 步的 check-pins.sh 与第 4 步的 snapshot_row 在子仓缺失时也会 exit 1，
#     但那是**另一道门**在兜底，与「release 用严格校验」是两回事。）
bash "$ROOT/scripts/check-all.sh" --offline --require-materialized

# 2. 子模块 pin 与远端一致（分支 pin / tag pin 两种语义）
#    清单与校验逻辑收敛在 scripts/check-pins.sh —— 与 GitHub Actions 的
#    verify.yaml、Jenkins 侧共用同一实现，避免三份手工同步（新增插件时漏改一处即静默失守）。
#    该脚本同时提供 --list，供第 4 步生成快照清单，避免再抄一遍 submodule 列表。
bash "$ROOT/scripts/check-pins.sh"

# 3. 版本号
VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "用法: make release VERSION=v0.1.0 或 bash scripts/release.sh v0.1.0" >&2; exit 1; }
# 版本号**权威校验**（Makefile 侧那条是纵深防御，不是这里可以省的理由）。
# 校验的是「能不能安全地当 tag 与文件名用」，不是严格 SemVer——本仓的 tag 形态
# 由各上游仓决定（如 harness 的 `dsh-v0.1.5-rc.2`），强行套 SemVer 会误伤。
# 这里拒绝的是空白、引号、`$`、反引号、`;` 等一切会在 shell/文件名/ref 名里
# 改变语义的字符：git ref 本身也有禁用字符集，宁可在源头拦。
case "$VERSION" in
  *[!A-Za-z0-9._-]*)
    echo "错误: VERSION 含非法字符：'${VERSION}'" >&2
    echo "  只允许字母/数字/点/下划线/连字符（如 v0.1.0、dsh-v0.1.5-rc.2）。" >&2
    exit 1 ;;
esac
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
# 清单来自 check-pins.sh --list（与 pin 校验同一事实来源）：原先这里只写
# harness + dsh-web 两行，而 release.yaml 的同名清单写全部 11 行——两者口径
# 不一致。改为从同一清单枚举，两边随新增插件自动对齐。
while IFS=$'\t' read -r sub _kind _ref; do
  [ -n "$sub" ] && snapshot_row "$sub"
done < <(bash "$ROOT/scripts/check-pins.sh" --list)
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
