#!/usr/bin/env bash
# deploy-remote.sh — 把主仓（按 submodule pin）部署到 deploy/hosts 所列服务器（systemd 管理）
#
# ⚠️ **非生产（legacy）**：本路径**从未在真实服务器上端到端执行过**（见 docs/backlog.md B3），
#    且仍以 root 运行服务、应用与状态同目录。生产启用前必须先完成安全评审（见
#    docs/cicd/05-deployment-runbook.md）。当前仅用于内网验证性部署。
#
# 安全约束（本脚本对目标执行 `rsync --delete`，误配不可逆）：
#   · DEPLOY_DIR 必须在 /opt/ 或 /srv/ 下，且拒绝根目录、父目录跳转、系统目录；
#   · 服务器侧再验一次目标不是符号链接（防写穿）；
#   · **状态（$DEPLOY_DIR/.dsh）不参与快照，也不参与回滚**——回滚只退回产物，
#     永远不覆盖发布期间产生的会话与附件；
#   · 任一主机失败 → 整批回滚已成功的主机（避免集群混合版本）。
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
#   6. 健康检查：轮询 http://127.0.0.1:3080（服务器本机）。dsh --profile dsh 启动的 web 服务
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
# ── 危险目标硬拒绝（本脚本会对其执行 `rsync --delete`，误配即不可逆）───────────
# 仅有字符集白名单是不够的：`/`、`..`、`/etc`、`/usr` 用的全是合法字符。
# 依次拒绝：① 非法字符 ② 空/根/相对路径 ③ 父目录跳转 ④ 系统目录 ⑤ 过浅路径
#          ⑥ 不在允许前缀下
case "$DEPLOY_DIR" in
  *[!A-Za-z0-9._/-]*)
    echo "错误: DEPLOY_DIR（${DEPLOY_DIR}）含不支持的字符（仅允许字母/数字/._/-，不能含空白）。" >&2
    exit 1
    ;;
esac
case "$DEPLOY_DIR" in
  ""|/|.|./*)
    echo "错误: DEPLOY_DIR 不得为空、根目录或相对路径（当前：'${DEPLOY_DIR}'）。本脚本对其执行 rsync --delete。" >&2
    exit 1
    ;;
esac
# 父目录跳转：任何 `..` 段落一律拒绝（含 `a/../b` 这类看似正常的写法——
# 它在服务器侧展开后可能指向意料之外的位置，不值得为便利承担风险）。
case "/${DEPLOY_DIR}/" in
  */../*)
    echo "错误: DEPLOY_DIR 不得含 '..' 路径段（当前：${DEPLOY_DIR}）。" >&2
    exit 1
    ;;
esac
# 系统目录：即使写成 /etc/dsh 也拒绝——本脚本用 --delete 覆盖目标，
# 不允许把系统目录树置于可被整棵覆盖的位置。
case "$DEPLOY_DIR" in
  /bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/usr|/usr/*|/etc|/etc/*| \
  /boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*| \
  /home|/home/*|/root|/root/*|/var|/var/*)
    echo "错误: DEPLOY_DIR 不得位于系统目录下（当前：${DEPLOY_DIR}）。请改用 /opt/<name> 或 /srv/<name>。" >&2
    exit 1
    ;;
esac
# 允许前缀 + 最小深度：必须形如 /opt/<name> 或 /srv/<name>（第三段非空）。
case "$DEPLOY_DIR" in
  /opt/?*|/srv/?*)
    case "$DEPLOY_DIR" in
      */*/*) ;;
      *) echo "错误: DEPLOY_DIR 过浅（当前：${DEPLOY_DIR}）。请使用 /opt/<name> 或 /srv/<name> 形式。" >&2
         exit 1 ;;
    esac
    ;;
  *)
    echo "错误: DEPLOY_DIR 必须在 /opt/ 或 /srv/ 下（当前：${DEPLOY_DIR}）。这是硬约束：本脚本对目标执行 rsync --delete。" >&2
    exit 1
    ;;
esac
SNAPSHOT_DIR="${DEPLOY_DIR}-snapshot"
export DEPLOY_DIR

# 本次要发布的超级仓库 commit —— 写入服务器侧部署标识，供健康检查比对（见 health_check）。
# 未在 git 工作区（如从 tarball 部署）时留空，健康检查会退化为「只要有标识即可」的宽松判据。
LOCAL_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
export LOCAL_SHA

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

# ── 由 git **动态派生** ignored 路径清单，喂给 rsync ─────────────────────────
# 为什么不能靠手写黑名单：rsync 同步的是**工作树**，而「工作树 clean」的判据
# （`git status` 不带 `--ignored`）**看不见 ignored 文件**。本仓实测后果：
#   harness/native/system/packages/darwin-arm64/bin/system.node（Mach-O arm64）
#   与 harness/.dsh-build/ 都会被同步到 Linux —— 直接违反本仓硬约束
#   「原生依赖必须按平台各自构建，严禁跨平台拷贝」。
# 黑名单按定义就不完整（新增工具 = 新增遗漏），故改由 **git 自己列出** ignored 路径。
#
# 用**默认模式**（不加 -uall）：它给目录级条目（harness 573 条）；
# 而 -uall 会把 ignored 目录里每个文件都展开（harness 80622 条），对 rsync 不实用。
# 输出形如 `harness/.dsh-build/`、`harness/native/system/packages/darwin-arm64/bin/`。
#
# ⚠️ 这仍是 **containment，不是发布内容策略**。根治是 tracked allowlist 驱动的制品
# 打包（见 docs/cicd/03-artifact-and-release.md）；在那之前本派生清单保证
# 「ignored 的东西不会无声明进 payload」。
build_ignored_excludes() {
  # `[`、`*`、`?` 在 git 路径里是普通字符，但会被 rsync 当**通配符**——转义掉，
  # 否则一个含 `[` 的目录名会意外排除掉一批无关文件。
  # 前缀 `/` 把模式锚定到传输根，避免 `lib` 这类模式匹配到任意层级的同名目录。
  local esc='s/[][*?]/\\&/g'
  git -C "$ROOT" status --ignored --porcelain 2>/dev/null \
    | sed -n 's|^!! ||p' | sed "$esc" | sed 's|^|/|'
  # 各 submodule（递归），路径前缀成相对主仓根
  # $displaypath 由 git submodule foreach 注入并展开，不是 bash 变量（故保持单引号）。
  # shellcheck disable=SC2016
  git -C "$ROOT" submodule foreach --recursive --quiet \
    'git status --ignored --porcelain 2>/dev/null | sed -n "s|^!! ||p" | sed "s|[][*?]|\\\\&|g" | sed "s|^|/$displaypath/|"' 2>/dev/null
}

IGNORED_EXCLUDES="$(mktemp)"
trap 'rm -f "$IGNORED_EXCLUDES"' EXIT
build_ignored_excludes > "$IGNORED_EXCLUDES"
echo "==> 已由 git 派生 $(wc -l < "$IGNORED_EXCLUDES" | tr -d ' ') 条 ignored 路径排除项（含递归 submodule）"

# rsync 参数单一来源：dry-run 打印与真实执行不漂移；-e 复用 SSH_OPTS 防挂起。
RSYNC_ARGS=(
  -az --delete --rsync-path='sudo rsync'
  --exclude '.git' --exclude '.dsh/' --exclude 'node_modules/'
  --exclude 'deploy/hosts' --exclude '.superpowers/' --exclude '.DS_Store'
  # 本地开发日志：含隧道 URL、错误栈、绝对路径，且 Makefile 每次运行都追加
  --exclude 'log/'
  # 凭据与本地工具状态
  --exclude '.env' --exclude '.env.*' --exclude '.claude/' --exclude '.netrc'
  # 散落的日志与编辑器/系统垃圾
  --exclude '*.log' --exclude '*.swp' --exclude '*~'
  # git 派生的 ignored 清单（见上）——这是「ignored 不进 payload」的保证
  --exclude-from "$IGNORED_EXCLUDES"
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
# harness 对未认证请求返回 401（浏览器 token flow 是唯一认证路径，401 = 认证 gate
# 在响应 = 服务已就绪），部分路径 303 跳认证页亦属正常，故 200/303/401 均视为通过；
# 连接失败或其他状态码为不通过。
health_check() { # $1=target
  local t="$1" i
  # shellcheck disable=SC2016 # 单引号有意保留 $()/$code 供服务器侧 shell 展开（远端命令字符串）
  # 健康检查 = ① HTTP 就绪 ② 部署标识与预期 SHA 一致。
  #   ① 200/303/401 任一即视为就绪（harness 对未认证请求返回 401，认证 gate 生效即服务已起）。
  #   ② 部署标识由本脚本在安装后写入 ${DEPLOY_DIR}/.dsh-deployed（见 mark_deployed），
  #      比对它可证明**落地的树就是本次要发的那个 commit**——否则「服务起来了」可能
  #      只是上一次部署的残留进程。
  #   ⚠️ 局限：这证明的是「磁盘上的树正确」，**不等于**「运行中的进程加载的就是它」——
  #      后者需要服务自身暴露版本端点（DSH 目前没有，属设计项，不在此假装做到）。
  local check_cmd='code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/ || true); case "$code" in 200|303|401) ;; *) echo "HTTP 未就绪: $code"; exit 1 ;; esac; if [ -f '"${DEPLOY_DIR}"'/.dsh-deployed ]; then got=$(sed -n "s/^sha=//p" '"${DEPLOY_DIR}"'/.dsh-deployed); if [ "$got" != '"${LOCAL_SHA:-}"' ]; then echo "部署标识不符: 磁盘=$got 预期='"${LOCAL_SHA:-}"'"; exit 1; fi; else echo "缺少部署标识 '"${DEPLOY_DIR}"'/.dsh-deployed"; exit 1; fi; exit 0'
  echo "==> 健康检查 http://127.0.0.1:3080（服务器本机轮询，至多 60s；200/303/401 视为就绪）"
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

# 回滚：把 $DEPLOY_DIR-snapshot（上一版本**产物**）整体 rsync 回 $DEPLOY_DIR，恢复
# 上一版本 unit 后 daemon-reload 并重启服务（重启为尽力而为，失败不影响产物已恢复的结论）。
# 快照内的 deploy/dsh.service 是上一版本模板，恢复时按当前 DEPLOY_DIR 重新渲染后安装。
#
# **状态不参与回滚**：命令带 `--exclude '.dsh/'`。即使旧快照里含状态（本约束生效前的
# 快照就是），也绝不覆盖回当前状态——发布期间产生的新会话与附件不能因回滚而丢失。
# 写部署标识：证明「磁盘上的树 = 本次要发的 commit」。健康检查会比对它。
# 放在安装之后、重启之前——重启后的健康检查就能立刻用它区分「新版本起来了」
# 与「旧进程还活着」。
mark_deployed() { # $1=target
  local t="$1"
  [ -n "$LOCAL_SHA" ] || { echo "  （非 git 工作区，跳过部署标识写入）"; return 0; }
  remote_sudo "$t" "printf 'sha=%s\nts=%s\n' '${LOCAL_SHA}' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > ${DEPLOY_DIR}/.dsh-deployed"
}

rollback_one() { # $1=target
  local t="$1"
  echo "==> 回滚 ${t} 到上一版本快照（${SNAPSHOT_DIR}）"
  # 回滚命令存单一变量：dry-run 打印与真实执行同一份内容。
  # 回滚同样排除 `$DEPLOY_DIR/.dsh`：即使旧快照里含状态（本版本之前的快照就是），
  # 也**绝不**把它覆盖回当前状态——这是硬规则（见文件头「状态不参与回滚」）。
  local rollback_cmd="rsync -a --delete --exclude '.dsh/' ${SNAPSHOT_DIR}/ ${DEPLOY_DIR}/ && sed 's|@DEPLOY_DIR@|${DEPLOY_DIR}|g' ${SNAPSHOT_DIR}/deploy/dsh.service > /etc/systemd/system/dsh.service && systemctl daemon-reload && { systemctl restart dsh || true; }"
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
    # ---- 1b. 符号链接逃逸防护（服务器侧）----
    # 本地校验无法知道服务器上目标的实际文件类型：若 ${DEPLOY_DIR} 是一个指向
    # 别处的符号链接，rsync --delete 会写穿到链接目标（可能是 /etc、/ 等）。
    # 故在服务器侧再验一次：两个目标都不得是符号链接、也不得经链接解析后改变路径。
    # 该检查在**快照与同步之前**执行——两者都会对被拒目标造成破坏。
    # shellcheck disable=SC2029 # 路径为本地派生的常量，按设计在客户端展开
    if ! ssh "${SSH_OPTS[@]}" "$target" "
      for p in '${DEPLOY_DIR}' '${SNAPSHOT_DIR}'; do
        if [ -L \"\$p\" ]; then echo \"拒绝: \$p 是符号链接（rsync --delete 会写穿到链接目标）\"; exit 1; fi
        if [ -e \"\$p\" ]; then
          real=\$(readlink -f \"\$p\" 2>/dev/null || echo \"\$p\")
          if [ \"\$real\" != \"\$p\" ]; then echo \"拒绝: \$p 实际解析为 \$real\"; exit 1; fi
          case \"\$real\" in /opt/?*|/srv/?*) ;; *) echo \"拒绝: \$p 解析后不在 /opt 或 /srv 下（\${real}）\"; exit 1 ;; esac
        fi
      done
    "; then
      echo "错误: 服务器 ${target} 的目标路径未通过安全校验（见上方服务器侧输出）。部署已中止，未做任何写入。" >&2
      return 1
    fi
  fi

  # ---- 2. 快照上一版本产物（全新机器跳过；spec §4「部署前快照」）----
  # 服务器侧命令按实际分支打印「已快照」或「无上一版本，跳过快照」，本地不再预打印 banner。
  # 快照排除 `$DEPLOY_DIR/.dsh`（运行时状态：会话/附件/凭据/插件数据）。
  # 理由：状态不属于「上一版本产物」，快照它既昂贵又危险——回滚时会把发布期间
  # 产生的**新**会话与附件一并覆盖回去。状态的生命周期由它自己管理，不由部署编排。
  if ! remote_sudo "$target" "if [ ! -d ${DEPLOY_DIR} ]; then echo 无上一版本，跳过快照; else rsync -a --delete --exclude '.dsh/' ${DEPLOY_DIR}/ ${SNAPSHOT_DIR}/ && echo 已快照: ${SNAPSHOT_DIR}; fi"; then
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

  # ---- 4b. 写部署标识（供随后的健康检查证明「落地的树 = 本次要发的 commit」）----
  if ! mark_deployed "$target"; then
    echo "错误: 写部署标识失败（${DEPLOY_DIR}/.dsh-deployed）。健康检查无法证明版本，按失败处理。" >&2
    rollback_one "$target" || true
    return 1
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
# ── 快照保真：部署的是 **pin 快照**，任何偏离都在写入远端之前拒绝 ──────────────
# 为什么必须拦：rsync 同步的是**工作树**，而部署标识只写主仓 HEAD（见下方 LOCAL_SHA）。
# 若工作树与 HEAD 不一致，落地的字节与标识就对不上——审计与回滚判断同时失效。
#
# 三层，逐层收紧；后两层**必须 --recursive**（仓内含嵌套 submodule 的，只看顶层会漏）：
#   ① 根仓工作树：tracked 改动 + untracked 文件
#   ② 各 submodule 的 **gitlink** 是否偏离 pin（`+` 偏离 / `-` 未初始化 / `U` 冲突）
#   ③ 各 submodule 的**工作树内容** —— ②只看 gitlink 指向，改了文件没提交时 gitlink 仍是 pin
# ①用 --ignore-submodules=dirty：让根仓的报错只讲根仓的事，submodule 的问题由 ②③ 报，
# 否则用户会在「主仓不干净」的提示下找半天，实际是某个插件有未提交改动。
ROOT_DIRTY="$(git status --porcelain --untracked-files=all --ignore-submodules=dirty 2>/dev/null || true)"
if [ -n "$ROOT_DIRTY" ]; then
  echo "错误: 主仓工作树不干净，拒绝部署（部署的是 pin 快照，不是当前工作树）：" >&2
  printf '%s\n' "$ROOT_DIRTY" | sed 's/^/  /' >&2
  echo "请先提交或还原后重试。" >&2
  exit 1
fi

# 未初始化的空目录会被 rsync 同步上去，remote-install 静默跳过 → 假成功，必须拦下。
SUB_STATUS="$(git submodule status --recursive 2>/dev/null || true)"
if printf '%s\n' "$SUB_STATUS" | grep -q '^[+-U]'; then
  echo "错误: submodule 状态偏离 pin 快照，拒绝部署：" >&2
  printf '%s\n' "$SUB_STATUS" | grep '^[+-U]' | sed 's/^/  /' >&2
  echo "请先处理 submodule（未初始化则运行 make setup；有改动则提交或还原）后重试。" >&2
  exit 1
fi

# $displaypath 由 `git submodule foreach` 注入并展开，不是 bash 变量。改成双引号会被
# bash 先展开成空串，反而丢掉「是哪个 submodule」——故此处必须保持单引号。
# shellcheck disable=SC2016
SUB_DIRTY="$(git submodule foreach --recursive --quiet \
  'git status --porcelain --untracked-files=all | sed "s|^|$displaypath: |"' 2>/dev/null || true)"
if [ -n "$SUB_DIRTY" ]; then
  echo "错误: submodule 工作树内容不干净，拒绝部署（gitlink 对了不代表内容就是 pin）：" >&2
  printf '%s\n' "$SUB_DIRTY" | sed 's/^/  /' >&2
  echo "请到对应 submodule 内提交或还原后重试。" >&2
  exit 1
fi
# ── 组件 materialized 校验：把服务器侧的**永久盲区**降级为部署前必查 ──────────────
# 为什么必须在这里（**本地、上传之前**）做：同步到服务器的是**没有 git 元数据的树**
# （RSYNC_ARGS 带 `--exclude '.git'`），而 `tracked-prebuilt` 组件的
# 「声明的运行入口确实被 git 跟踪」这条不变量要对子仓跑 `git ls-files`——在没有 .git 的
# 树上**一律失败**，所以服务器侧**永远**跑不了它（deploy/remote-install.sh 的口径因此
# 有意只到 catalog 阶段）。本脚本恰好是**本地执行、有 git、且在 rsync 之前**：同一份不变量
# 在这里查得动，失败的代价也从「服务器已 --delete」降到「本地退出、远端一个字节没动」。
# 与上面三条快照保真检查同属「写入远端之前必须成立」的前提，故放在同一段、任何主机之前。
# （Task 9 原本把这条校验放在服务器侧的 remote-install.sh；因上述原因它收窄到 catalog 阶段，
#  这条不变量的落点就是本行——评审 T9-3 的建议。）
node "$ROOT/scripts/check-components.mjs" --require-materialized || {
  echo "错误: 组件 materialized 校验失败（见上）。本地树不满足 fresh-clone 不变量（例如 tracked-prebuilt 组件的入口未被 git 跟踪），拒绝部署。" >&2
  echo "请按提示修正后重试（子仓未初始化则先运行 make setup）。这是服务器侧无法复查的不变量，不能留到部署后再发现。" >&2
  exit 1
}

[ -f "$HOSTS_FILE" ] || {
  echo "错误: 缺少 ${HOSTS_FILE}（真实服务器清单，已被 gitignore）。请复制 deploy/hosts.example 为 ${HOSTS_FILE} 并填写 user@host。" >&2
  exit 1
}
[ -f "$ROOT/harness/package.json" ] || {
  echo "错误: 本地 harness/ 未检出（rsync 会把空目录同步到服务器）。请先运行 make setup 初始化 submodule。" >&2
  exit 1
}

# 读 hosts：跳过空行与整行 # 注释；格式违规即报错。
#
# 失败语义：**任一主机失败即回滚本批次内所有已成功的主机**，而不是把它们留在新版本上。
# 理由：多主机部署面向的是「一组同类服务器」（同一版本、同一套负载均衡）。若第 2 台失败
# 而第 1 台留在新版本，集群会处于**混合版本**状态——这通常比「整批退回旧版本」更难排查，
# 且健康检查通过的第 1 台会持续接收流量、放大不一致。故整批一起退。
# 单主机失败时，deploy_one 内部已自行回滚过该主机；此处再滚一次是幂等的 no-op。
DEPLOYED=0
SUCCEEDED=()          # 本批次已成功的主机，用于失败时整批回滚
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
  if deploy_one "$line"; then
    DEPLOYED=$((DEPLOYED + 1))
    SUCCEEDED+=("$line")
    continue
  fi
  # ── 本台失败：整批回滚 ──
  echo "" >&2
  echo "错误: ${line} 部署失败。" >&2
  if [ "${#SUCCEEDED[@]}" -gt 0 ]; then
    echo "本批次已有 ${#SUCCEEDED[@]} 台部署成功，为避免集群混合版本，现整批回滚：" >&2
    rc_fail=0
    for h in "${SUCCEEDED[@]}"; do
      echo "  → 回滚 ${h}" >&2
      rollback_one "$h" || { echo "    回滚失败，需人工介入: ${h}" >&2; rc_fail=1; }
    done
    [ "$rc_fail" -eq 0 ] && echo "整批已回到上一版本。" >&2 || echo "⚠️ 部分主机回滚失败，请登录检查（见上方逐台输出）。" >&2
  else
    echo "本批次无已成功主机，无需整批回滚。" >&2
  fi
  exit 1
done < "$HOSTS_FILE"

if [ "$DEPLOYED" -eq 0 ]; then
  echo "错误: ${HOSTS_FILE} 中没有有效服务器行（每行一台 user@host，整行 # 开头才是注释），未部署任何主机。" >&2
  exit 1
fi

echo "全部部署完成（共 ${DEPLOYED} 台）"
