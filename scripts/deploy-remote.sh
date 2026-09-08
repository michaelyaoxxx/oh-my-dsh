#!/usr/bin/env bash
# deploy-remote.sh — 把主仓（按 submodule pin）部署到 deploy/hosts 所列服务器（systemd 管理）
#
# 每台服务器流程（spec §4）：
#   1. 预检：免密 ssh 可达；服务器需有 rsync/curl/systemctl。
#      node/pnpm/corepack 等工具链重预检由 deploy/remote-install.sh 负责（与
#      scripts/setup.sh 同款校验），本脚本不重复实现。
#   2. 快照上一版本产物到 $DEPLOY_DIR-snapshot（全新机器跳过）。
#   3. rsync 主仓（含 submodule 检出内容）到 $DEPLOY_DIR，排除 .git/.dsh/
#      node_modules/ 等平台产物与本地状态；依赖一律服务器侧构建，
#      严禁跨平台拷贝 node_modules。rsync 经 --rsync-path 以 sudo 写 $DEPLOY_DIR。
#   4. 服务器执行 $DEPLOY_DIR/deploy/remote-install.sh（sudo，同一 root 身份），
#      该脚本顺带按 $DEPLOY_DIR 渲染并安装 dsh.service。
#   5. systemctl daemon-reload → enable --now → restart。
#   6. 健康检查：轮询 http://127.0.0.1:3080（服务器本机）。harness 的 dsh web
#      默认只绑 127.0.0.1（web-app cordis.patch.yml: host 缺省 '127.0.0.1'），
#      且 --host 0.0.0.0 被 CLI 有意拒绝，故必须服务器侧探测，本地 curl 到
#      <server>:3080 会恒失败。
#   任一步失败：回滚到 $DEPLOY_DIR-snapshot 并报错（全新机器无快照时给出明确提示）。
#
# 幂等：可重复执行（全新机器与增量更新同一路径）；快照每次部署前刷新。
# 约定：
#   - deploy/hosts 每行一台 user@host；整行 # 开头为注释；空行跳过。
#   - 部署目录由 DEPLOY_DIR 环境变量指定（默认 /opt/dsh，所有服务器同一值）；
#     DSH_HOME=$DEPLOY_DIR/.dsh；profile 名固定 dsh。
#   - 服务器侧所有写操作统一经 sudo 以 root 执行（与 dsh.service 以 root 运行
#     一致：install 期与运行期共享同一 corepack 缓存身份，服务启动无需重新
#     下载 pnpm；不使用 sudo -E，避免 HOME 留在部署账号导致缓存身份漂移）。
#     ssh 需密钥认证（预检强制 BatchMode=yes）；sudo 可交互输密码（ssh -t
#     伪终端），但 rsync 的 --rsync-path 无伪终端，其 sudo 需免密或部署账号
#     为 root（失败时给出明确提示）。
#   - --dry-run 只打印将执行的命令，不连接任何主机；HOSTS_FILE 环境变量可
#     覆盖清单路径（默认 deploy/hosts）；DEPLOY_DIR 覆盖部署目录。
# 退出码：0 成功；任何失败 1。
set -euo pipefail
cd "$(dirname "$0")/.."          # 主仓根
ROOT="$PWD"
HOSTS_FILE="${HOSTS_FILE:-deploy/hosts}"
# 服务器侧所有目标路径都从 DEPLOY_DIR 派生（快照目录取 $DEPLOY_DIR-snapshot）；
# export 使 deploy/remote-install.sh 能收到同一值（见 install_cmd 的显式传入）。
DEPLOY_DIR="${DEPLOY_DIR:-/opt/dsh}"
# 早期校验：该值将进入 rsync 目标、快照路径拼接与服务器侧 sed 模板渲染，
# 限定安全字符集（字母/数字/._/-），拒绝空白与 |、& 等破坏命令拼接的字符。
case "$DEPLOY_DIR" in
  *[!A-Za-z0-9._/-]*)
    echo "错误: DEPLOY_DIR（${DEPLOY_DIR}）含不支持的字符（仅允许字母/数字/._/-，不能含空白）。请改用安全路径。" >&2
    exit 1
    ;;
esac
SNAPSHOT_DIR="${DEPLOY_DIR}-snapshot"
export DEPLOY_DIR

DRY_RUN=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "错误: 未知参数 ${arg}（仅支持 --dry-run）" >&2
      exit 1
      ;;
  esac
done
if [ -n "$DRY_RUN" ]; then
  echo "==> 试运行模式（--dry-run）：只打印将执行的命令，不连接任何主机"
fi

# 所有 ssh 调用共享同一组选项：BatchMode 禁交互输密码（部署要求密钥认证），
# ConnectTimeout 防网络挂起无限阻塞（失败须在有限时间内转入回滚）。
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# 服务器侧命令统一经 sudo bash -c 以 root 执行（同一 sudo 身份，见文件头）。
# ssh 带 -t 分配伪终端：sudo 需输密码时可交互输入；免密 sudo 或 root 登录则无提示。
# POSIX 单引号包裹（' → '\''）转义：任何远程登录 shell（bash/dash）都能原样解析，
# UTF-8 字节原样通过（不依赖 bash 的 $'...' ANSI-C 引号）。
shell_quote() { # $1=命令字符串 → 输出 '...' 包裹的单个 shell 单词
  local s="$1" q="'" esc="'\\''" # 替换串 '\''（POSIX 单引号包裹内转义单引号；
                                  # bash 3.2 的 ${//} 替换串对字面引号解析敏感，用变量拼接）
  s="${s//\'/$esc}"
  printf '%s%s%s' "$q" "$s" "$q"
}

remote_sudo() { # $1=target；$2=服务器命令（单字符串）
  local t="$1" cmd="$2"
  if [ -n "$DRY_RUN" ]; then
    printf '  [dry-run] ssh %s -t %s sudo bash -c %s\n' "${SSH_OPTS[*]}" "$t" "$(shell_quote "$cmd")"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" -t "$t" "sudo bash -c $(shell_quote "$cmd")"
}

# rsync 参数单一来源：dry-run 打印与真实执行不漂移；-e 复用 SSH_OPTS 防挂起。
RSYNC_ARGS=(
  -az --delete --rsync-path='sudo rsync'
  --exclude '.git' --exclude '.dsh/' --exclude 'node_modules/'
  --exclude 'deploy/hosts' --exclude '.superpowers/' --exclude '.DS_Store'
  -e "ssh ${SSH_OPTS[*]}"
)

sync_tree() { # $1=target
  local t="$1"
  # 命令存单一变量：dry-run 打印与真实执行共用同一份参数，不漂移。
  local cmd=( rsync "${RSYNC_ARGS[@]}" "$ROOT/" "$t:${DEPLOY_DIR}/" )
  if [ -n "$DRY_RUN" ]; then
    printf '  [dry-run]'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    return 0
  fi
  "${cmd[@]}"
}

# 健康检查：轮询服务器本机 http://127.0.0.1:3080，至多 60s（30 次 × 2s）。
health_check() { # $1=target
  local t="$1" i
  local check_cmd="curl -sf http://127.0.0.1:3080 >/dev/null 2>&1"
  echo "==> 健康检查 http://127.0.0.1:3080（服务器本机轮询，至多 60s）"
  for ((i = 1; i <= 30; i++)); do
    if [ -n "$DRY_RUN" ]; then
      printf '  [dry-run] ssh %s %s %s\n' "${SSH_OPTS[*]}" "$t" "$check_cmd"
      return 0
    fi
    # shellcheck disable=SC2029 # 远端命令按设计在服务器侧执行；单源变量保证 dry-run 打印与真实执行一致
    if ssh "${SSH_OPTS[@]}" "$t" "$check_cmd"; then
      echo "健康检查通过: ${t}"
      return 0
    fi
    sleep 2
  done
  echo "错误: 健康检查失败（60s 内 3080 未就绪）: ${t}" >&2
  return 1
}

# 回滚：把 $DEPLOY_DIR-snapshot（上一版本产物，含 node_modules 与 .dsh 运行态）整体
# rsync 回 $DEPLOY_DIR，恢复上一版本 unit 后 daemon-reload 并重启服务（重启为尽力而为，
# 失败不影响产物已恢复的结论）。快照内的 deploy/dsh.service 是上一版本模板，
# 恢复时按当前 DEPLOY_DIR 重新渲染后安装到 /etc/systemd/system/dsh.service。
rollback_one() { # $1=target
  local t="$1"
  echo "==> 回滚 ${t} 到上一版本快照（${SNAPSHOT_DIR}）"
  # 回滚命令存单一变量：dry-run 打印与真实执行同一份内容。
  local rollback_cmd="rsync -a --delete ${SNAPSHOT_DIR}/ ${DEPLOY_DIR}/ && sed 's|@DEPLOY_DIR@|${DEPLOY_DIR}|g' ${SNAPSHOT_DIR}/deploy/dsh.service > /etc/systemd/system/dsh.service && systemctl daemon-reload && { systemctl restart dsh || true; }"
  if [ -n "$DRY_RUN" ]; then
    remote_sudo "$t" "$rollback_cmd"
    return 0
  fi
  # shellcheck disable=SC2029 # 路径为本地派生的 SNAPSHOT_DIR，按设计在客户端展开
  if ! ssh "${SSH_OPTS[@]}" "$t" "test -d ${SNAPSHOT_DIR}"; then
    echo "错误: 服务器无上一版本快照（${SNAPSHOT_DIR}），无法回滚。请登录 ${t} 检查 ${DEPLOY_DIR} 状态。" >&2
    return 1
  fi
  if ! remote_sudo "$t" "$rollback_cmd"; then
    echo "错误: 回滚失败（快照恢复或 unit 安装出错）。请登录 ${t} 检查 ${DEPLOY_DIR} 与 systemctl status dsh。" >&2
    return 1
  fi
  echo "已回滚: ${t} 恢复为上一版本产物（服务已尽力按上一版本重启，可登录执行 systemctl status dsh 确认）"
}

deploy_one() { # $1=target（user@host）
  local target="$1" install_log install_cmd
  echo "==> 部署到 ${target}（${DEPLOY_DIR}）"

  # ---- 1. 预检：免密 ssh 可达；服务器需有 rsync/curl/systemctl ----
  if [ -n "$DRY_RUN" ]; then
    echo "  [dry-run] 跳过服务器连通性与 rsync/curl/systemctl 预检"
  else
    ssh "${SSH_OPTS[@]}" "$target" "exit 0" || {
      echo "错误: 无法免密 ssh 连接 ${target}（连接失败、主机密钥未确认或密钥未配置）。请确认已 ssh-copy-id 到该服务器。" >&2
      return 1
    }
    ssh "${SSH_OPTS[@]}" "$target" "command -v rsync >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1" || {
      echo "错误: 服务器 ${target} 缺少 rsync、curl 或 systemctl（同步与健康检查需要）。可执行: sudo apt-get install rsync curl" >&2
      return 1
    }
  fi

  # ---- 2. 快照上一版本产物（全新机器跳过；spec §4「部署前快照」）----
  # 服务器侧命令按实际分支打印「已快照」或「无上一版本，跳过快照」，本地不再预打印 banner。
  if ! remote_sudo "$target" "if [ ! -d ${DEPLOY_DIR} ]; then echo 无上一版本，跳过快照; else rsync -a --delete ${DEPLOY_DIR}/ ${SNAPSHOT_DIR}/ && echo 已快照: ${SNAPSHOT_DIR}; fi"; then
    echo "错误: 快照失败（${DEPLOY_DIR} → ${SNAPSHOT_DIR}）。请检查 ${target} 磁盘空间后重试。" >&2
    return 1
  fi

  # ---- 3. rsync 源码（含 submodule 检出内容）到 $DEPLOY_DIR ----
  echo "==> 同步源码到 ${target}:${DEPLOY_DIR}/"
  if ! sync_tree "$target"; then
    echo "错误: rsync 同步失败。请确认 ${target} 的 sudo 可免密执行 rsync（--rsync-path 无伪终端，无法交互输 sudo 密码），或部署账号为 root。" >&2
    rollback_one "$target" || true
    return 1
  fi

  # ---- 4. 服务器侧安装（remote-install.sh 在同一 root 身份下执行）----
  # 接口契约（deploy/remote-install.sh 文件头）：退出码 0 成功 / 1 失败；
  # 成功时输出最后一行恒为「remote-install 完成」。CI=true 由 remote-install.sh
  # 内部处理，本脚本不绕过。
  echo "==> 服务器侧安装（deploy/remote-install.sh）"
  # DEPLOY_DIR 经 sudo 的 VAR=value 前缀显式传入（sudo 默认清空环境，不用 sudo -E）。
  install_cmd="sudo DEPLOY_DIR=${DEPLOY_DIR} bash ${DEPLOY_DIR}/deploy/remote-install.sh"
  if [ -n "$DRY_RUN" ]; then
    printf '  [dry-run] ssh %s -t %s %s（校验 exit 0 且最后一行「remote-install 完成」）\n' "${SSH_OPTS[*]}" "$target" "$install_cmd"
  else
    install_log="$(mktemp "${TMPDIR:-/tmp}/dsh-deploy.XXXXXX")"
    if ! ssh "${SSH_OPTS[@]}" -t "$target" "$install_cmd" 2>&1 | tr -d '\r' | tee "$install_log"; then
      echo "错误: remote-install.sh 在 ${target} 执行失败（exit 非 0）。完整输出见本地临时日志 ${install_log}。" >&2
      rollback_one "$target" || true
      return 1
    fi
    if [ "$(tail -n 1 "$install_log")" != "remote-install 完成" ]; then
      echo "错误: remote-install.sh 输出最后一行不是成功标志「remote-install 完成」。完整输出见本地临时日志 ${install_log}。" >&2
      rollback_one "$target" || true
      return 1
    fi
    rm -f "$install_log"
  fi

  # ---- 5. 启用并重启 systemd 服务（spec §4 第 4 步；unit 已由 remote-install.sh 渲染安装）----
  echo "==> 启用并重启 systemd 服务 dsh"
  if ! remote_sudo "$target" "systemctl daemon-reload && systemctl enable --now dsh && systemctl restart dsh"; then
    echo "错误: dsh 服务启用或重启失败。可登录 ${target} 执行 systemctl status dsh 排查。" >&2
    rollback_one "$target" || true
    return 1
  fi

  # ---- 6. 健康检查（spec §4 第 5 步）----
  if ! health_check "$target"; then
    rollback_one "$target" || true
    return 1
  fi

  echo "==> ${target} 部署完成"
  return 0
}

# hosts 行合法格式：恰好一个 @、两侧非空、无空白（Ruling 2：单列 user@host）。
valid_target() { # $1=hosts 行
  case "$1" in
    *@*@*|*@|@*|*[[:space:]]*) return 1 ;;
    *@*) return 0 ;;
  esac
  return 1
}

# ---- 本地预检 ----
command -v rsync >/dev/null 2>&1 || { echo "错误: 本地未找到 rsync（同步需要）。" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "错误: 本地未找到 ssh（部署需要）。" >&2; exit 1; }
[ -f "$HOSTS_FILE" ] || {
  echo "错误: 缺少 ${HOSTS_FILE}（真实服务器清单，已被 gitignore）。请复制 deploy/hosts.example 为 ${HOSTS_FILE} 并填写 user@host。" >&2
  exit 1
}
[ -f "$ROOT/harness/package.json" ] || {
  echo "错误: 本地 harness/ 未检出（rsync 会把空目录同步到服务器）。请先运行 make setup 初始化 submodule。" >&2
  exit 1
}

# 读 hosts：跳过空行与整行 # 注释；格式违规即报错；任一服务器失败即整体报错退出。
while IFS= read -r line; do
  line="${line%$'\r'}"                              # 容忍 Windows 行尾
  line="${line#"${line%%[![:space:]]*}"}"           # 去前导空白
  line="${line%"${line##*[![:space:]]}"}"           # 去尾部空白
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  if ! valid_target "$line"; then
    echo "错误: ${HOSTS_FILE} 行格式无效: ${line}（每行一台 user@host，参考 deploy/hosts.example）" >&2
    exit 1
  fi
  deploy_one "$line" || exit 1
done < "$HOSTS_FILE"

echo "全部部署完成"
