# 插件开发指南

插件以 submodule 收在本仓 `plugins/<name>/`（源码形态），可运行形态经 DSH profile `dsh` 以 link 挂载进 `.dsh/profiles/dsh/`（符号链接，改源码即时生效）。

开发前先在本仓跑一次 `make setup`（初始化 submodule + harness/插件依赖构建），之后日常开发不需要重跑。

## 挂载机制（`make dev` 做了什么）

`make dev` 先执行 `scripts/link-plugins.sh`：对 `plugins/*` 中声明了 `dsh.bundle.patch` 且 patch 落在自己包目录内的包，执行 `dsh plugin --profile dsh add link:<绝对路径>`，以 pnpm `link:` 协议把插件装进 `.dsh/profiles/dsh/`（profile 内含 `package.json` 插件清单 + `node_modules`）。link 是符号链接，改插件源码即时生效，重复运行幂等。

- dsh-web 根包的 patch 指向包外的子包文件，因此根包不是挂载入口，其聚合包才是（与 dsh-web 官方开发文档一致）。
- 被其他可挂载包依赖的包（聚合包的家族成员）不单独挂载，由聚合包的 `link:` 带出本地构建。

## 在 submodule 内开发（以 dsh-web 为例）

```sh
# 一次性：切到稳定分支（submodule 默认 detached HEAD 是特性）
# 注意：dsh-web 默认分支是 dev，稳定分支是 main，本仓只 pin main，不要 pin dev
cd plugins/dsh-web && git checkout main && cd ../..

# 日常循环：link 挂载 + 改源码即时生效（服务监听 http://127.0.0.1:3080）
make dev
cd plugins/dsh-web && git add -A && git commit -m "feat: ..." && git push

# 回主仓更新 pin（先 push 插件仓再更新 pin；提交走 PR，verify CI 校验 pin 与远端 main 一致）
cd ../.. && git add plugins/dsh-web
git commit -m "chore: bump dsh-web pin" && git push
```

## 约定

- submodule 默认保持 detached HEAD：主仓只认 pin 的 commit，开发时才切分支。
- 插件发版（npm publish / tag）由插件仓按自身机制完成，主仓只做 pin 快照，不越界编排。
- 新插件加入：`git submodule add <repo> plugins/<name>`（目录不存在会自动创建）。
- 要部署到服务器的插件仓必须提交 `pnpm-lock.yaml`：服务器侧构建强制 `--frozen-lockfile`，缺失会部署失败。
- 插件仓缺 `packageManager` 字段时，本地 `link-plugins.sh` 硬错误退出，而服务器侧 `remote-install.sh` 静默跳过锚点写入——这是有意分歧（本地锚点必须钉住 harness 的 pnpm 版本，缺字段无法确定；服务器侧与其 pnpm 校验同语义，视为可跳过）。

## 常见问题

- `make dev` 报 harness 未构建：先跑一次 `make setup`。
- 主仓提交后 verify CI 报「pin 与 main 不一致」：插件仓的最新 commit 还没 push 到远端 `main`，先 push 插件仓再更新 pin。
- 本地已 push 插件仓但 CI 仍报 pin 不一致：上游稳定分支已推进过 pin，执行 `git submodule update --remote` 拉到远端最新后重新 `git add plugins/<name>` 提交 pin。
- 改了插件代码但不生效：确认改的是被 link 挂载的那个包（根包不是挂载入口时改聚合包），并确认 `make dev` 输出里有 `link <包名> <- <路径>`。
