# 远程部署手册（Linux Ubuntu x86-64）

`make deploy` 把主仓按 submodule pin 一键部署到服务器（systemd 管理），部署目录由 `DEPLOY_DIR` 环境变量指定（默认 `/opt/dsh`，所有服务器同一值）。部署是显式动作，不上 CI。

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

1. **预检**：免密 ssh 可达；服务器有 rsync / curl / systemctl。
2. **快照**：把当前 `$DEPLOY_DIR` 整体快照到 `$DEPLOY_DIR-snapshot`（全新机器跳过），供失败时自动回滚。
3. **同步**：rsync 主仓源码（含 submodule 检出内容）到 `$DEPLOY_DIR`，排除 `.git` / `.dsh` / `node_modules` 等本地状态与平台产物，经 sudo rsync 写入。
4. **服务器侧安装**（`deploy/remote-install.sh`）：工具链校验（node / corepack / pnpm 解析）→ harness `pnpm install --frozen-lockfile` + build（原生依赖按服务器平台构建，严禁跨平台拷贝 node_modules）→ 各插件 `--frozen-lockfile` + build → 插件经 `dsh plugin --profile dsh add link:` 装入 `$DEPLOY_DIR/.dsh/profiles/dsh/` → 按 `$DEPLOY_DIR` 渲染 `dsh.service` 模板（`@DEPLOY_DIR@` 占位符）并安装到 `/etc/systemd/system/dsh.service`。
5. **服务接管**：`systemctl daemon-reload` → `enable --now` → `restart`（unit 已由上一步渲染安装）。
6. **健康检查**：在**服务器本机**轮询 `curl http://127.0.0.1:3080`（至多 60 秒），HTTP 状态码 `200/303/401` 均视为就绪——harness 对未认证请求返回 `401`（浏览器 token flow 是唯一认证路径，`401` = 认证 gate 在响应 = 服务已就绪）。DSH Web 只绑定 `127.0.0.1`（harness 有意限制，不监听外网），从外部访问请用 SSH 端口转发或反向代理。

幂等：可重复执行，全新机器与增量更新走同一路径。

## 自动回滚

部署前先把 `$DEPLOY_DIR` 快照到 `$DEPLOY_DIR-snapshot`；此后任一步（同步、服务器侧安装、服务重启、健康检查）失败，脚本自动回滚：

1. 把 `$DEPLOY_DIR-snapshot` 整体恢复回 `$DEPLOY_DIR`（含上一版本的 node_modules 与 `.dsh` 运行态）；
2. 恢复上一版本的 `dsh.service`（按 `$DEPLOY_DIR` 渲染）→ `systemctl daemon-reload` → 重启服务（重启为尽力而为，失败不影响产物已恢复的结论）。

全新机器没有快照，失败时无法自动回滚，脚本会明确提示并报错，请登录服务器检查 `$DEPLOY_DIR` 状态。

## 服务管理

```sh
ssh <host> systemctl status dsh          # 状态
ssh <host> journalctl -u dsh -f          # 日志（权限不足时可加 sudo）
ssh <host> sudo systemctl restart dsh    # 重启
```

unit 名为 `dsh`：以 root 运行，`WorkingDirectory=$DEPLOY_DIR/harness`，`ExecStart=/usr/local/bin/pnpm --dir $DEPLOY_DIR/harness dsh web --no-open`，环境变量 `DSH_HOME=$DEPLOY_DIR/.dsh`、`NODE_ENV=production`，`Restart=on-failure`。unit 由 `remote-install.sh` 按 `$DEPLOY_DIR` 渲染模板（`@DEPLOY_DIR@` 占位符）后安装到 `/etc/systemd/system/dsh.service`。
