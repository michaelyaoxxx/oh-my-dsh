# dsh 超级仓库脚手架实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 dsh 超级仓库从"仅 spec"搭成可用的编排仓库：submodule、Makefile、脚本、部署文件、CI、文档。

**Architecture:** 薄 Makefile 入口 + `scripts/*.sh` 实现；DSH 以源码运行（$DSH_HOME 指到本仓 `.dsh/`，profile 名固定 `dsh`）；部署经 rsync + 服务器侧构建 + systemd；发布打 tag，CI 校验与冒烟。

**Tech Stack:** git submodule、Makefile、bash、pnpm、Node ≥22.19、systemd、rsync、GitHub Actions

**Spec:** [2026-09-08-dsh-superproject-design.md](../specs/2026-09-08-dsh-superproject-design.md)

## Global Constraints

- 目标平台：本地 macOS M4(arm64)；远程 Linux(Ubuntu) x86-64。**原生依赖必须按平台各自构建，严禁跨平台拷贝 `node_modules`**；服务器侧用 `pnpm install --frozen-lockfile`。
- 插件默认装在主仓 `plugins/` 下，目录不存在脚本必须 `mkdir -p`，幂等。
- DSH home 指向本仓 `.dsh/`（gitignore）；profile 名固定 `dsh`；可运行插件落 `.dsh/profiles/dsh/node_modules/`。
- harness submodule → `master`；dsh-web → `main`（其默认分支是 `dev`，勿 pin dev）。
- harness: Node `^22.19.0 || >=24.0.0`, pnpm@11.7.0；dsh-web: pnpm@11.24.0。
- 主仓默认分支 `main`；commit **不加任何 AI 署名**。
- submodule 保持 detached HEAD（更新 pin 是显式动作）。
- 部署不上 CI 自动触发（`make deploy` 显式）；发布快照只追溯 pin。

---

### Task 1: 添加 submodule（harness + dsh-web）并 pin 到稳定分支最新

**Files:**
- Create: `.gitmodules`（自动）
- Modify: `.gitmodules`、`harness`、`plugins/dsh-web`（gitlink）、`.gitignore`

**Interfaces:**
- Produces: `harness/` 检出 harness@master HEAD；`plugins/dsh-web/` 检出 dsh-web@main HEAD；后续 Task 2/3 在此源码上运行 pnpm。

- [ ] **Step 1: 添加 harness submodule**

```bash
cd /Users/michaelyao/workspace/dsh
git submodule add https://github.com/deepseek-ai/deepseek-harness.git harness
```

- [ ] **Step 2: 添加 dsh-web submodule**

```bash
git submodule add https://github.com/zhu1090093659/dsh-web.git plugins/dsh-web
```

- [ ] **Step 3: pin 到各自稳定分支 HEAD（保持 detached）**

```bash
git -C harness fetch origin master && git -C harness checkout --detach origin/master
git -C plugins/dsh-web fetch origin main && git -C plugins/dsh-web checkout --detach origin/main
```

- [ ] **Step 4: 验证两个 submodule 状态与 .gitignore**

运行: `git submodule status`
期望: 两行均 `+<sha> ...` 前缀 `+`（pin 落后于远端记录）/或 ` <sha>`（已同步）；`git status` 中 harness 与 plugins/dsh-web 显示为已修改（新 pin）。

- [ ] **Step 5: 提交（无 AI 署名）**

```bash
git add .gitmodules harness plugins/dsh-web
git commit -m "chore: add harness and dsh-web submodules pinned to stable branches"
```

**测试说明**：此 task 无可自动测试，以 `git submodule status` 与后续 `make setup` 实际可建为准；CI verify 亦会校验 pin。

---

### Task 2: `scripts/setup.sh`（本地一键搭建）

**Files:**
- Create: `scripts/setup.sh`
- Modify: 无

**Interfaces:**
- Produces: `scripts/setup.sh`（可执行，幂等）：`make setup` 调它。校验本地工具链 → 递归拉 submodule → harness `pnpm install --frozen-lockfile && pnpm build` → 各插件 `pnpm install --frozen-lockfile`（dsh-web 在自身目录）。

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# setup.sh — 一键搭建本地 DSH 环境（源码运行，与 pin commit 一致）
set -euo pipefail
cd "$(dirname "$0")/.."          # 主仓根
ROOT="$PWD"

# 1. 工具链前置校验
command -v node >/dev/null || { echo "错误: 需要 Node.js ≥22.19 (见 harness package.json engines)"; exit 1; }
command -v pnpm >/dev/null || { echo "错误: 需要 pnpm (harness 用 11.7.0)"; exit 1; }
node -e "const s=process.versions.node.split('.').map(Number);const ok=(s[0]>22||(s[0]===22&&s[1]>=19)||s[0]>=24);if(!ok){console.error('Node 版本不满足 ^22.19 || >=24, 当前 '+process.versions.node);process.exit(1)}"

# 2. 递归拉取/更新 submodule（插件目录不存在则创建，幂等）
mkdir -p plugins
git submodule update --init --recursive
git submodule sync --recursive

# 3. harness：安装依赖 + 构建
echo "==> 构建 harness"
( cd harness && pnpm install --frozen-lockfile && pnpm build )

# 4. 各插件：安装依赖 + 构建（使可挂载 bundle 的 lib/ 产物就绪）
#    dsh-web 是 pnpm workspace（autoInstallPeers:false, linkWorkspacePackages:true），
#    有自带 pnpm-lock.yaml → --frozen-lockfile 可行；根 package.json 有 build（pnpm -r build）。
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  ( cd "$d" && pnpm install --frozen-lockfile )
  # 该插件是 monorepo 或需构建才可挂载时执行其 build
  if node -e "process.exit(require('./$d/package.json').scripts?.build ? 0 : 1)" 2>/dev/null; then
    echo "==> 构建插件: $d"
    ( cd "$d" && pnpm build )
  fi
done

echo "setup 完成。运行 make dev 启动 DSH Web。"
```

- [ ] **Step 2: 加可执行位**

```bash
chmod +x scripts/setup.sh
```

- [ ] **Step 3: 验证幂等 + 主仓无新修改**

运行: `bash scripts/setup.sh`（首次真实构建，耗时较长）随后再跑一次 `bash scripts/setup.sh`
期望: 两次均 exit 0；第二次不报错（`--frozen-lockfile` 一致）。

- [ ] **Step 4: 提交**

```bash
git add scripts/setup.sh
git commit -m "feat: add setup.sh for one-shot local DSH bootstrap"
```

---

### Task 3: `Makefile` 薄入口 + `scripts/link-plugins.sh` + `make dev`

**Files:**
- Create: `Makefile`、`scripts/link-plugins.sh`
- Modify: 无

**Interfaces:**
- Consumes: Task 2 的 `setup.sh`。
- Produces:
  - `Makefile` 目标：`setup`、`dev`、`deploy`、`release`、`link-plugins`、`help`
  - `link-plugins.sh`：把 `plugins/*/` 的包以 link 模式装进 profile `dsh`（`dsh plugin --profile dsh add file:...`），供 `make dev` 调用。

- [ ] **Step 1: 写 Makefile**

```make
.PHONY: setup dev deploy release link-plugins help

help: ## 显示可用目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

setup: ## 一键搭建本地环境（submodule + 依赖 + harness 构建）
	bash scripts/setup.sh

link-plugins: ## 把 plugins/* 以 link 挂进 DSH profile dsh
	bash scripts/link-plugins.sh

dev: link-plugins ## 启动 DSH Web（$DSH_HOME=./.dsh，--no-open 可加）
	cd harness && DSH_HOME="$(CURDIR)/.dsh" pnpm dsh web --no-open

deploy: ## 部署到远程服务器（读 deploy/hosts）
	bash scripts/deploy-remote.sh

release: ## 校验 pin → 打 tag → push（发布快照）
	bash scripts/release.sh
```

- [ ] **Step 2: 写 link-plugins.sh**

```bash
#!/usr/bin/env bash
# link-plugins.sh — 把 plugins/* 中声明 dsh.bundle 的子包以 link 挂进 DSH profile dsh（开发热更）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PROFILE=dsh
export DSH_HOME="${DSH_HOME:-$ROOT/.dsh}"

[ -x harness/node_modules/.bin/dsh ] || { echo "错误: harness 未构建，先运行 make setup"; exit 1; }
mkdir -p "$DSH_HOME/profiles"

# 每个插件仓（monorepo 则找 packages/* 中声明 dsh.bundle.patch 的子包）add 进 profile。
# 例：dsh-web 的可挂载入口是 packages/dsh-web-all（npm 名 @linxin666/dsh-web-all）。
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  # 该仓根本身是 bundle？(整仓即单插件时成立)
  if node -e "process.exit(require('./$d/package.json').dsh?.bundle?.patch ? 0 : 1)" 2>/dev/null; then
    echo "==> link (root) $d"
    harness/node_modules/.bin/dsh plugin --profile "$PROFILE" add "file:${ROOT}/$d"
    continue
  fi
  # monorepo：遍历子包，挂所有声明 bundle 的（如 dsh-web-all 聚合包）
  for sub in "$d"packages/*/; do
    [ -f "$sub/package.json" ] || continue
    if node -e "process.exit(require('./$sub/package.json').dsh?.bundle?.patch ? 0 : 1)" 2>/dev/null; then
      name=$(node -p "require('./$sub/package.json').name")
      echo "==> link $name <- $sub"
      harness/node_modules/.bin/dsh plugin --profile "$PROFILE" add "file:${ROOT}/${sub%/}"
    fi
  done
done
```

- [ ] **Step 3: 可执行位 + 冒烟验证**

```bash
chmod +x scripts/link-plugins.sh
bash scripts/setup.sh            # 确保 harness + dsh-web 构建过（含 packages/dsh-web-all 的 lib/）
bash scripts/link-plugins.sh
```

期望: 输出 link 了 `@linxin666/dsh-web-all`（取自 `plugins/dsh-web/packages/dsh-web-all`）；`$ROOT/.dsh/profiles/dsh/node_modules/@linxin666/` 出现 dsh-web-all 链接（node_modules 实际落 .dsh 内）。若 `dsh plugin add file:` 语法与官方不符，按 `harness/node_modules/.bin/dsh plugin --help` 调整。

- [ ] **Step 4: 验证 make 目标可用（不真起服务）**

运行: `make help`，并预览 dev 命令：`make -n dev`（打印将执行的命令，不执行）
期望: help 列出 setup/dev/deploy/release/link-plugins/help；`make -n dev` 打印 link-plugins 脚本调用 + harness 下 `pnpm dsh web --no-open`（带 DSH_HOME）。

> 注：`make dev --dry-run` 不会触发前置 link-plugins（make 的 dry-run 不执行配方），真实热更验证放 CI/手动 `make dev`。

- [ ] **Step 5: 提交**

```bash
git add Makefile scripts/link-plugins.sh
git commit -m "feat: add Makefile entrypoints and plugin link script"
```

**测试说明**：真实 `make dev` 会阻塞起服务，放 CI/手动验收；本 task 以 link 后 `.dsh/profiles/dsh/node_modules` 出现链接为可测交付物。

---

### Task 4: 部署文件（deploy/hosts.example、dsh.service、remote-install.sh）

**Files:**
- Create: `deploy/hosts.example`、`deploy/dsh.service`、`deploy/remote-install.sh`（可执行）

**Interfaces:**
- Produces: `deploy/remote-install.sh`（在服务器侧执行，幂等）；`deploy/dsh.service`（systemd unit）；`deploy/hosts.example`（模板，真实 hosts 被 gitignore）。供 Task 5 的 `deploy-remote.sh` rsync 后调用。

- [ ] **Step 1: hosts.example**

```ini
# deploy/hosts — 每行一台服务器，严格两列，不要行内注释：
#   user@host  deploy_dir(默认 /opt/dsh)
# 复制为 deploy/hosts（被 gitignore）并填写。整行以 # 开头才是注释。
# 示例（勿提交真实凭据）：
# deploy@1.2.3.4  /opt/dsh
```

- [ ] **Step 2: dsh.service**

```ini
[Unit]
Description=DeepSeek Harness (DSH) Web
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/dsh/harness
# $DSH_HOME 必须与 remote-install.sh 一致：插件/配置都落 /opt/dsh/.dsh
Environment=DSH_HOME=/opt/dsh/.dsh
Environment=NODE_ENV=production
# 与 spec 一致：源码运行（pnpm dsh web）。pnpm 位于 /opt/dsh（corepack 或 PATH）。
ExecStart=/opt/dsh/harness/node_modules/.bin/dsh web --no-open
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```
> 注：ExecStart 用构建后 harness 的 `node_modules/.bin/dsh`（源码运行入口，pnpm build 产物）；若该 bin 不存在说明 harness 未构建，remote-install.sh 会在 systemctl start 前完成构建。若偏好 pnpm 入口，可改 `/usr/local/bin/pnpm --dir /opt/dsh/harness dsh web --no-open`（需服务器 PATH 有 pnpm）。

- [ ] **Step 3: remote-install.sh（在服务器执行）**

```bash
#!/usr/bin/env bash
# remote-install.sh — 服务器侧安装（随源码 rsync 后调用，勿在本地直接跑）
set -euo pipefail
ROOT=/opt/dsh
export DSH_HOME="$ROOT/.dsh"
PROFILE=dsh
cd "$ROOT"

# 前置: 工具链
command -v node >/dev/null && command -v pnpm >/dev/null || { echo "需要 node/pnpm"; exit 1; }

mkdir -p plugins "$DSH_HOME/profiles"

# 1. harness 依赖 + 构建（服务器平台，frozen-lockfile）
( cd harness && pnpm install --frozen-lockfile && pnpm build )

# 2. 各插件：安装依赖 + 构建（服务器平台产物）
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  echo "==> 安装插件依赖: $d"
  ( cd "$d" && pnpm install --frozen-lockfile )
  if node -e "process.exit(require('./$d/package.json').scripts?.build ? 0 : 1)" 2>/dev/null; then
    ( cd "$d" && pnpm build )
  fi
done

# 3. 把声明 dsh.bundle 的子包经 dsh plugin add file: 装进 profile（链接到服务器侧已构建源码）
for d in plugins/*/; do
  [ -f "$d/package.json" ] || continue
  if node -e "process.exit(require('./$d/package.json').dsh?.bundle?.patch ? 0 : 1)" 2>/dev/null; then
    harness/node_modules/.bin/dsh plugin --profile "$PROFILE" add "file:${ROOT}/${d%/}" || true
    continue
  fi
  for sub in "$d"packages/*/; do
    [ -f "$sub/package.json" ] || continue
    if node -e "process.exit(require('./$sub/package.json').dsh?.bundle?.patch ? 0 : 1)" 2>/dev/null; then
      harness/node_modules/.bin/dsh plugin --profile "$PROFILE" add "file:${ROOT}/${sub%/}" || true
    fi
  done
done
echo "remote-install 完成"
```

- [ ] **Step 4: 语法检查 + 可执行位**

```bash
bash -n deploy/remote-install.sh
chmod +x deploy/remote-install.sh
```

- [ ] **Step 5: 提交**

```bash
git add deploy/
git commit -m "feat: add deploy assets (hosts example, systemd unit, remote install script)"
```

---

### Task 5: `scripts/deploy-remote.sh`（rsync + 服务器安装 + systemd + 健康检查/回滚）

**Files:**
- Create: `scripts/deploy-remote.sh`
- Modify: 无

**Interfaces:**
- Consumes: Task 4 的 `deploy/remote-install.sh`、`deploy/dsh.service`、`deploy/hosts`。
- Produces: `make deploy` 的完整实现：逐台服务器执行前置检查 → rsync（含子模块，排除 .dsh/.git/node_modules 等平台产物）→ 服务器 `remote-install.sh` → 安装/重启 systemd → 健康检查 3080；失败回滚到上一产物。

- [ ] **Step 1: 写脚本（骨架含 rsync 排除与健康轮询）**

```bash
#!/usr/bin/env bash
# deploy-remote.sh — 部署到 deploy/hosts 所列服务器（systemd 管理）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
HOSTS_FILE="${HOSTS_FILE:-deploy/hosts}"

[ -f "$HOSTS_FILE" ] || { echo "缺少 $HOSTS_FILE（可复制 deploy/hosts.example）"; exit 1; }

# 健康检查：轮询 http://host:3080 至多 60s
health_check() { # $1=host
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://$1:3080" >/dev/null 2>&1; then echo "健康检查通过: $1"; return 0; fi
    sleep 2
  done
  echo "健康检查失败: $1"; return 1
}

deploy_one() { # $1=user@host  $2=deploy_dir
  local target="$1" dir="${2:-/opt/dsh}" host="${1#*@}"   # 剥掉 user@ 前缀
  [ "$host" = "$1" ] && host="$1"                          # 无 @ 时整串即 host
  echo "==> 部署到 $target ($dir)"
  ssh "$target" "command -v node >/dev/null && command -v pnpm >/dev/null && command -v systemctl >/dev/null" \
    || { echo "服务器缺 node/pnpm/systemd"; return 1; }
  ssh "$target" "mkdir -p '$dir'"
  # rsync 源码（含 submodule 检出），排除平台产物与本地状态
  rsync -az --delete \
    --exclude '.git/' --exclude '.dsh/' --exclude 'node_modules/' \
    --exclude 'deploy/hosts' \
    -e ssh "$ROOT/" "$target:$dir/"
  ssh "$target" "cd '$dir' && bash deploy/remote-install.sh"
  ssh "$target" "cp deploy/dsh.service /etc/systemd/system/dsh.service && systemctl daemon-reload && systemctl enable --now dsh && systemctl restart dsh"
  health_check "$host" || { echo "回滚提示: 服务器保留上一 node_modules/产物，可 systemctl 重置"; return 1; }
}

# 读 hosts（严格格式：每行 "user@host [deploy_dir]"；跳过空行与整行 # 注释）
while read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  set -- $line
  [ $# -ge 1 ] || continue
  deploy_one "$1" "${2:-/opt/dsh}" || exit 1
done < "$HOSTS_FILE"
echo "全部部署完成"
```

- [ ] **Step 2: 语法检查 + 可执行位 + 幂等说明**

```bash
bash -n scripts/deploy-remote.sh && chmod +x scripts/deploy-remote.sh
echo "真机部署需真实服务器，脚本已含前置校验与回滚提示（放到集成验收）"
```

- [ ] **Step 3: 提交**

```bash
git add scripts/deploy-remote.sh
git commit -m "feat: add deploy-remote.sh orchestrator (rsync + systemd + health check)"
```

**测试说明**：无服务器时以 `bash -n` 与阅读验收；有真实 Ubuntu x86-64 服务器后跑 `make deploy`（含 spec 成功标准 2）。不写死服务器 IP，hosts.example 提供模板。

---

### Task 6: `scripts/release.sh` + tag 流程

**Files:**
- Create: `scripts/release.sh`

**Interfaces:**
- Produces: `make release` 实现：校验工作区干净 → 校验每个 submodule pin 与远端稳定分支一致 → 生成快照清单（名称/SHA/可读版本，tag 优先于 package.json version）→ `git tag v<semver>` → push tags。

- [ ] **Step 1: 写脚本**

```bash
#!/usr/bin/env bash
# release.sh — 校验 pin → 生成快照清单 → 打 tag → push（发布主仓快照）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# 1. 工作区干净
git diff --quiet && git diff --cached --quiet || { echo "工作区有未提交修改，先提交再发布"; exit 1; }

# 2. 子模块 pin 与稳定分支一致（防本地未推送 commit 被误 pin）
check_pin() { # $1=path  $2=stable_branch
  local sub="$1" branch="$2"
  local pinned remote
  pinned=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" fetch origin "$branch" >/dev/null 2>&1
  remote=$(git -C "$sub" rev-parse "origin/$branch")
  if [ "$pinned" != "$remote" ]; then
    echo "警告: $sub pin($pinned) 与 $branch($remote) 不一致"
    echo "如已推送，请先 git submodule update --remote 或显式更新 pin 再发布"; exit 1
  fi
}
check_pin harness master
check_pin plugins/dsh-web main

# 3. 版本号
VERSION="${1:-}"
[ -z "$VERSION" ] && { echo "用法: make release VERSION=v0.1.0 或 bash scripts/release.sh v0.1.0"; exit 1; }
case "$VERSION" in v*) ;; *) VERSION="v$VERSION";; esac
git tag -l "$VERSION" | grep -q . && { echo "tag $VERSION 已存在"; exit 1; }

# 4. 快照清单
SNAPSHOT="$ROOT/RELEASE_NOTES.md"
echo "# Release $VERSION 快照清单" > "$SNAPSHOT"
echo "" >> "$SNAPSHOT"
snapshot_row() { # $1=path $2=name
  local sub="$1" name="$2" sha ver=""
  sha=$(git -C "$sub" rev-parse HEAD)
  ver=$(git -C "$sub" describe --tags --abbrev=0 2>/dev/null || node -p "require('./$sub/package.json').version" 2>/dev/null || echo "-")
  echo "- $name: \`$sha\` ($ver)" >> "$SNAPSHOT"
}
snapshot_row harness deepseek-harness
snapshot_row plugins/dsh-web dsh-web
cat "$SNAPSHOT"

# 5. tag + push（RELEASE_NOTES 只作记录，不入库）
git tag -a "$VERSION" -F "$SNAPSHOT"
git push origin "$VERSION"
echo "已发布 $VERSION"
```

- [ ] **Step 2: 语法 + 可执行位**

```bash
bash -n scripts/release.sh && chmod +x scripts/release.sh
```

- [ ] **Step 3: 只测校验段（不真 push）**

先临时把脚本最后两行 `git tag -a ...` 与 `git push ...` 注释掉（或复制脚本去掉 push），运行:
`bash scripts/release.sh v9.9.9-test`
期望: 通过 pin 校验 → 生成 `RELEASE_NOTES.md` 快照清单 → **不产生远端 tag**。
随后清理：
```bash
git tag -d v9.9.9-test 2>/dev/null || true
rm -f RELEASE_NOTES.md          # 快照清单不入库
git checkout -- scripts/release.sh   # 还原被注释的 push 行
```
> 注：切勿带 push 行跑测试 tag，否则会真的推到远端私有仓。真实发布在确认无误后执行。

- [ ] **Step 4: 提交**

```bash
git add scripts/release.sh
git commit -m "feat: add release.sh (pin check + snapshot manifest + tag)"
```

---

### Task 7: CI（verify.yaml + release.yaml）

**Files:**
- Create: `.github/workflows/verify.yaml`、`.github/workflows/release.yaml`

**Interfaces:**
- Consumes: Task 2 setup.sh、Task 6 校验逻辑；Task 1 的 submodule。
- Produces: push/PR 自动跑 pin 一致性 + 冒烟（Linux x86-64，含 `make setup` + 起 DSH 健康检查 3080）；tag 触发干净验证，通过才建 GitHub Release 附快照。

- [ ] **Step 1: verify.yaml**

```yaml
name: verify
on:
  push:
    branches: [main]
  pull_request:

jobs:
  verify:
    runs-on: ubuntu-latest          # x86-64，与服务器同平台
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive      # 带 submodule 检出
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
        with:
          version: 11.7.0
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm
      # 1. pin 一致性（复用 release.sh 校验逻辑；未推送 commit 会失败）
      - name: Check submodule pins match remote stable branches
        run: |
          set -e
          for pair in "harness master" "plugins/dsh-web main"; do
            set -- $pair
            [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/$2)" ] \
              || { echo "$1 pin 与 $2 不一致（可能未推送）"; exit 1; }
          done
      # 2. 冒烟：make setup（真实构建）+ link 插件 + 起服务健康检查
      - name: Setup
        run: make setup
      - name: Link plugins into profile
        run: bash scripts/link-plugins.sh
      - name: Smoke test DSH Web
        run: |
          (cd harness && DSH_HOME="$GITHUB_WORKSPACE/.dsh" pnpm dsh web --no-open >/tmp/dsh.log 2>&1) &
          for i in $(seq 1 60); do
            curl -sf http://127.0.0.1:3080 && exit 0
            sleep 2
          done
          cat /tmp/dsh.log; exit 1
```

- [ ] **Step 2: release.yaml**

```yaml
name: release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
        with:
          version: 11.7.0
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm
      # 干净构建 + link + 冒烟，通过才建 Release
      - name: Build & smoke
        run: |
          make setup
          bash scripts/link-plugins.sh
          (cd harness && DSH_HOME="$GITHUB_WORKSPACE/.dsh" pnpm dsh web --no-open >/tmp/dsh.log 2>&1) &
          for i in $(seq 1 60); do
            curl -sf http://127.0.0.1:3080 && exit 0
            sleep 2
          done
          cat /tmp/dsh.log; exit 1
      - name: Build snapshot manifest
        run: |
          {
            echo "# Release ${{ github.ref_name }}"
            echo ""
            for sub in harness plugins/dsh-web; do
              sha=$(git -C "$sub" rev-parse HEAD)
              name=$(basename "$sub")
              ver=$(git -C "$sub" describe --tags --abbrev=0 2>/dev/null || node -p "require('./$sub/package.json').version")
              echo "- $name: \`$sha\` ($ver)"
            done
          } > RELEASE_NOTES.md
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          body_path: RELEASE_NOTES.md
```

- [ ] **Step 3: YAML 校验（无真实 runner 时）**

运行: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/verify.yaml','.github/workflows/release.yaml']]; print('YAML OK')"`
期望: `YAML OK`

- [ ] **Step 4: 提交**

```bash
git add .github/workflows/
git commit -m "ci: add verify (pin check + smoke) and release (tag → release) workflows"
```

**测试说明**：push 到 GitHub 私有仓后触发 verify 验证；打 tag 触发 release。本地以 YAML 语法检查为闸。

---

### Task 8: 文档 + README（含快速上手指向 plugin-dev.md / deploy.md）

**Files:**
- Create: `README.md`、`docs/plugin-dev.md`、`docs/deploy.md`

**Interfaces:**
- Consumes: Task 2-6 的全部目标名。
- Produces: 面向用户的快速上手、插件开发指南、部署手册（含 hosts 配置、回滚说明）。

- [ ] **Step 1: README.md**

```markdown
# dsh · DeepSeek Harness 超级仓库

以 git submodule 编排 DSH 主仓库与插件仓库，承载环境搭建、部署、发布快照与插件开发。设计见 `docs/superpowers/specs/`。

## 快速上手（本地 macOS）

```sh
make setup     # 拉 submodule + harness 构建 + 插件依赖
make dev       # 启动 DSH Web（$DSH_HOME=./.dsh，插件 link 挂载，热更）
```

- 插件开发：[docs/plugin-dev.md](docs/plugin-dev.md)
- 远程部署：[docs/deploy.md](docs/deploy.md)
- 发布快照：`make release VERSION=v0.1.0`

## 结构

| 目录 | 说明 |
| --- | --- |
| `harness/` | DSH 主仓库 submodule（pin master） |
| `plugins/` | 插件 submodule 集合（dsh-web pin main），默认安装位置 |
| `.dsh/` | DSH 运行主目录（$DSH_HOME，运行时生成，gitignore） |
| `scripts/` | 编排脚本（Makefile 薄入口） |
| `deploy/` | systemd unit + 服务器安装脚本 + hosts 模板 |
| `.github/workflows/` | verify（pin+冒烟）/ release（tag→Release） |
```

- [ ] **Step 2: docs/plugin-dev.md**（含 submodule 开发循环：切分支 → make dev → push 回插件仓 → 主仓更新 pin → PR）

```markdown
# 插件开发指南

插件以 submodule 收在本仓 `plugins/<name>/`（源码），可运行形态经 DSH profile 装进 `.dsh/profiles/dsh/`。

## 在 submodule 内开发（dsh-web 为例）

```sh
# 一次性切到稳定分支（submodule 默认 detached HEAD 是特性）
cd plugins/dsh-web && git checkout main && cd ../..

# 日常循环：link 挂载 + 改源码即时生效
make dev
cd plugins/dsh-web && git add -A && git commit -m "feat: ..." && git push

# 回主仓更新 pin（提交到主仓触发 verify 校验）
cd ../.. && git add plugins/dsh-web
git commit -m "chore: bump dsh-web pin" && git push   # 走 PR
```

## 约定

- submodule 默认保持 detached（主仓只认 pin commit）；开发才切分支。
- 插件发版（npm publish/tag）由插件仓自行完成，主仓只做 pin 快照。
- 新插件加入：`git submodule add <repo> plugins/<name>`（目录不存在会自动创建）。
```

- [ ] **Step 3: docs/deploy.md**

```markdown
# 远程部署手册（Linux Ubuntu x86-64）

前置：服务器装有 Node ≥22.19、pnpm 11.x、git、systemd；本地有 rsync 与 SSH 访问。

## 配置服务器清单

```sh
cp deploy/hosts.example deploy/hosts   # 真实 hosts 被 gitignore
# 每行: user@host /opt/dsh
```

## 部署

```sh
make deploy
```

流程：rsync 源码（含 submodule pin，排除 .dsh/node_modules 等平台产物）→ 服务器侧 `pnpm install --frozen-lockfile` + build（原生依赖按服务器平台构建）→ 插件经 `dsh plugin --profile dsh add` 装入 `.dsh/profiles/dsh/` → systemd 接管 → 健康检查 3080。幂等可重复；失败保留上一产物可回滚（systemctl 重置）。

## 服务管理

```sh
ssh <host> systemctl status dsh     # 状态
ssh <host> journalctl -u dsh -f     # 日志
```
```

- [ ] **Step 4: 提交**

```bash
git add README.md docs/
git commit -m "docs: add README quickstart, plugin-dev and deploy guides"
```

---

### Task 9: 收尾核对（self-check，可并行读文档与脚本）

**Files:**
- 无改动（只读核对）

**Interfaces:**
- Consumes: 前述全部。

- [ ] **Step 1: 核对 spec 成功标准**

逐条对照 spec 第 7 节：本计划交付了 scaffold（脚本/CI/文档/部署资产）。**本机真实 `make setup` 需较长构建时间**，作为 Task 2 的验证；`make deploy`/Release 触发依赖真实服务器与 GitHub 私有仓推送，属部署验收，计划中已留对应步骤。

- [ ] **Step 2: 全仓一致性检查**

```bash
git status --short
bash -n scripts/setup.sh scripts/link-plugins.sh scripts/deploy-remote.sh scripts/release.sh deploy/remote-install.sh
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/verify.yaml','.github/workflows/release.yaml']]"
```

期望: 无未提交改动（除 .dsh 产物，gitignore）；脚本与 YAML 语法全过。

---

## Self-Review（对照 spec）

- **Spec 2 目录结构** → Task 1/3/4/8 覆盖（.gitmodules、Makefile、scripts、deploy、.github、docs、README；`.dsh/` 运行时生成不入库）。
- **Spec 3 环境搭建** → Task 2（setup.sh 幂等 + 工具链校验 + frozen-lockfile）+ Task 3（link-plugins + make dev + $DSH_HOME=./.dsh）。
- **Spec 4 远程部署** → Task 4（dsh.service/hosts.example/remote-install.sh 服务器侧构建）+ Task 5（rsync 排除平台产物、systemd、健康检查、回滚提示、幂等）。
- **Spec 5 发布 + CI** → Task 6（release.sh：pin 校验/快照清单/tag）+ Task 7（verify pin+冒烟 / release tag 冒烟通过才建 Release）。
- **Spec 6 插件工作流** → Task 8 的 plugin-dev.md（含 AGENTS 约定）、README 指向。
- **Spec 非目标** → 未引入 Docker、未让部署上 CI、未编排插件发版 ✓。
- **硬约束** → setup/remote-install 均 `--frozen-lockfile`；插件目录 `mkdir -p`；DSH_HOME 定死 `.dsh/`；commit 无 AI 署名；submodule 保持 detached ✓。

**遗留外部依赖**（非本计划范围，需用户环境具备）：GitHub 私有仓 `dsh` 已创建并加 remote；`deploy/hosts` 真实服务器条目；GitHub token/权限使 Actions 可跑（私有仓默认可用）。
