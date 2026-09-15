# 远程部署手册（Linux Ubuntu x86-64）

`make deploy` 把主仓按 submodule pin 一键部署到服务器（systemd 管理），部署目录由 `DEPLOY_DIR` 环境变量指定（默认 `/opt/dsh`，所有服务器同一值）。部署是显式动作，不上 CI。

> ⚠️ **该路径从未端到端跑通过**（见 [backlog.md](backlog.md) B3），且**非生产形态**（以 root 运行、
> 应用与状态同目录）。若你是接手部署的人，**先读 [deploy-handoff.md](deploy-handoff.md)**
> ——那里有现状、已知会挡路的坑与验收标准。本文只讲**怎么操作**。

## 前置条件

- **本地（发起部署的机器）**：装有 `rsync`、`ssh`；能免密 SSH 登录服务器（密钥认证，先 `ssh-copy-id` 配置好）；已跑过 `make setup`（本地 `harness/` 需已检出，否则部署脚本会拒绝执行）。
- **服务器（Linux x86-64 + systemd）**：
  - Node.js `^22.19 || >=24`（23 不满足），并带 corepack（Node <25 随发行版内置；≥25 不再分发，需 `npm install -g corepack`）。**不需要预装 pnpm**：corepack 按各仓库 `packageManager` 字段解析 pin 的 pnpm 版本（以 `harness/package.json` 的 `packageManager` 字段为准），`remote-install.sh` 在服务器侧校验（比较时剥离 `+sha512` 后缀），并在 `/usr/local/bin` 维护 pnpm shim 供 systemd 服务使用。
  - `rsync`、`curl`（同步与健康检查需要）。
  - root 的 sudo PATH（`secure_path`）需包含 Node：nvm 等用户级安装的 node 不在 root 的 `secure_path` 里，服务器侧会得到误导性的「未找到 node」报错。
- **部署账号需要免密 sudo**（或部署账号本身是 root）：rsync 经 `--rsync-path='sudo rsync'` 写 `$DEPLOY_DIR`，无伪终端、无法交互输密码。
- 插件仓必须提交 `pnpm-lock.yaml`：服务器侧构建强制 `--frozen-lockfile` 可复现安装，缺失直接失败。

## 配置服务器清单

```sh
cp deploy/hosts.example deploy/hosts   # 真实 hosts 被 gitignore，不提交
```

`deploy/hosts` 每行一台服务器，格式为 `user@host`；整行以 `#` 开头才是注释，空行跳过。部署目录由 `DEPLOY_DIR` 指定（默认 `/opt/dsh`），不在清单中配置。可用环境变量 `HOSTS_FILE` 覆盖清单路径、`DEPLOY_DIR` 覆盖部署目录；`--dry-run` 只打印将执行的命令、不连接任何主机：

```sh
bash scripts/deploy-remote.sh --dry-run
```

## 部署

```sh
make deploy
```

对每台服务器的流程（任一台失败则整体报错退出）：

1. **预检**：免密 ssh 可达；服务器有 rsync / curl / systemctl。以及**快照保真三层检查**——
   rsync 同步的是**工作树**，而部署标识只写主仓 `HEAD`，两者不一致时落地字节与标识就对不上，
   审计与回滚判断同时失效。故在写入远端**之前**逐层拒绝：

   | 层 | 检查 | 为什么不能省 |
   | --- | --- | --- |
   | ① | 根仓工作树（tracked + untracked） | 未提交的脚本会被同步上去 |
   | ② | 各 submodule 的 gitlink 是否偏离 pin（`+` / `-` / `U`），**`--recursive`** | 未初始化的空目录会被同步上去，服务器侧静默跳过 → 假成功 |
   | ③ | 各 submodule 的**工作树内容**，**`--recursive`** | ② 只看 gitlink **指向**；改了文件没提交时 gitlink 仍是 pin |

2. **快照**：把当前 `$DEPLOY_DIR` 整体快照到 `$DEPLOY_DIR-snapshot`（全新机器跳过），供失败时自动回滚。**快照排除 `.dsh/`**（状态不参与回滚，见下）。
3. **同步**：rsync 主仓源码（含 submodule 检出内容）到 `$DEPLOY_DIR`，经 sudo rsync 写入。排除清单见脚本 `RSYNC_ARGS`——**它不只是 `.git` / `.dsh` / `node_modules`**：还包括 `log/`（本地开发日志，含隧道 URL、错误栈、绝对路径）、`.env*`、`.claude/`、`.netrc`、`*.log`。⚠️ `.gitignore` 只约束 Git，**对 rsync 无效**；新增任何会落地的本地目录时必须同步加进那里。
4. **服务器侧安装**（`deploy/remote-install.sh`）：工具链校验（node / corepack / pnpm 解析）→ harness `pnpm install --frozen-lockfile` + build（原生依赖按服务器平台构建，严禁跨平台拷贝 node_modules）→ 各插件 `--frozen-lockfile` + build → 插件经 `dsh plugin --profile dsh add link:` 装入 `$DEPLOY_DIR/.dsh/profiles/dsh/` → 按 `$DEPLOY_DIR` 渲染 `dsh.service` 模板（`@DEPLOY_DIR@` 占位符）并安装到 `/etc/systemd/system/dsh.service`。
5. **服务接管**：`systemctl daemon-reload` → `enable --now` → `restart`（unit 已由上一步渲染安装）。
6. **健康检查**：在**服务器本机**轮询 `curl http://127.0.0.1:3080`（至多 60 秒），HTTP 状态码 `200/303/401` 均视为就绪——harness 对未认证请求返回 `401`（浏览器 token flow 是唯一认证路径，`401` = 认证 gate 在响应 = 服务已就绪）。DSH Web 只绑定 `127.0.0.1`（harness 有意限制，不监听外网），从外部访问请用 SSH 端口转发或反向代理。

幂等：可重复执行，全新机器与增量更新走同一路径。

## 自动回滚

部署前先把 `$DEPLOY_DIR` 快照到 `$DEPLOY_DIR-snapshot`；此后任一步（同步、服务器侧安装、服务重启、健康检查）失败，脚本自动回滚：

1. 把 `$DEPLOY_DIR-snapshot` 整体恢复回 `$DEPLOY_DIR`（含上一版本的 `node_modules` 与代码）。
   ⚠️ **`.dsh/` 不在回滚范围内**（快照与恢复都带 `--exclude '.dsh/'`）：那是**状态**，
   回滚代码不应该回滚用户数据。该约束在本仓的 `deploy-remote.sh` 与 `remote-install.sh`
   里同时生效，**不是**「快照里恰好包含了运行态」。
2. 恢复上一版本的 `dsh.service`（按 `$DEPLOY_DIR` 渲染）→ `systemctl daemon-reload` → 重启服务。
   ⚠️ **重启是尽力而为的**（`systemctl restart dsh || true`）。因此「产物已回滚」**不等于**
   「服务已恢复」——脚本不会为此假装成功，也不会证明运行中的进程加载的就是恢复后的那一份。
   服务未能拉起时需人工介入。

全新机器没有快照，失败时无法自动回滚，脚本会明确提示并报错，请登录服务器检查 `$DEPLOY_DIR` 状态。

## 服务管理

```sh
ssh <host> systemctl status dsh          # 状态
ssh <host> journalctl -u dsh -f          # 日志（权限不足时可加 sudo）
ssh <host> sudo systemctl restart dsh    # 重启
```

unit 名为 `dsh`：以 root 运行，`WorkingDirectory=$DEPLOY_DIR/harness`，`ExecStart=/usr/local/bin/pnpm --dir $DEPLOY_DIR/harness dsh --profile dsh --no-open`，环境变量 `DSH_HOME=$DEPLOY_DIR/.dsh`、`NODE_ENV=production`，`Restart=on-failure`。unit 由 `remote-install.sh` 按 `$DEPLOY_DIR` 渲染模板（`@DEPLOY_DIR@` 占位符）后安装到 `/etc/systemd/system/dsh.service`。

## 运行形态（为什么是源码态入口，而非全局 CLI / 二进制）

服务与本地 `make dev` 跑同一个官方入口 `pnpm dsh`（harness 根 `package.json` 的 script：`node --import tsx/esm apps/cli/src/bin.ts`）。这里的「源码态」比直觉轻得多：

- tsx 只转译 **CLI 壳层**（`apps/cli/src` 下相对 import 的少量文件）；各 workspace 子包的 `main` 都指向 `lib/` 编译产物（`pnpm build` 产出，setup/remote-install 每次部署都执行）。运行主体是编译后的 JS，TS 源码与 sourcemap 不进运行热路径，稳态运行速度与入口无关。
- 真正的体积大头是 285 个 workspace 包的全量依赖树（node_modules 约 1.5 GB），与运行入口形态无关——换成任何 npm 安装形态都省不掉。
- tsx 壳的唯一成本是进程启动时的一次性转译（约几百 ms）：常驻 systemd 服务只在启动时付一次；CLI 交互命令（如 `dsh plugin add`）每次调用付一次，现阶段无感。

为何不换成全局 CLI / 预编译二进制：harness 不发布 standalone CLI 二进制（`/bin/dsh` 形态不存在）；它唯一的安装产物形态是 npm 包 `@deepseek-ai/dsh`（`bin` 指向 `lib/bin.js`——与 git 源码态同一个 CLI 壳的构建产物）。本仓按 spec 走 git 源码消费（快照可审 + pin 一致性校验），服务器侧 `--frozen-lockfile` 按平台构建已锁死可复现性——与预编译产物想解决的「环境漂移」等价，且不引入第三方分发的信任面。

为何 ExecStart 不直接 `node …/apps/cli/lib/bin.js`（免 tsx 壳）：省下的只是每次启动几百 ms 的转译，对常驻服务无感；`pnpm dsh` 是 harness 根 script 的稳定契约，pin bump 时语义跟随上游，而 lib 直跑是自维护分叉。若将来 CLI 交互调用频率高到在意这开销，再单独评估。

为何显式 `--profile dsh` 而不是 `dsh web`：harness 的 `dsh web` 是 `--profile web` 的硬编码别名，boot 官方模板 web profile（首次使用自动初始化，且只含官方 base + web-app）；而插件挂载目标（link-plugins.sh / remote-install.sh）是 profile `dsh`（本仓的插件与 patch 托管层）。统一显式 boot `dsh` 使「挂载的」与「运行的」是同一个 profile，否则挂载内容永不进入运行实例。
