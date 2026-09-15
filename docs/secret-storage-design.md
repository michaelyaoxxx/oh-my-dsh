# 密钥静态存储设计（非明文）

> 状态：**设计稿（未实现）**。对应遗留问题 [Backlog B14](backlog.md#二-仓库整体)。
> 目标读者：接手部署/运维/改 `save-settings` 的人。文档很短，只回答两件事——
> **现状密钥落在哪**、**怎么在不明文静置的前提下继续往前走**。

## 1. 目标与边界

- **目标（至少）**：密钥在**磁盘上（静态，at-rest）不以明文长期存在**——备份、rsync、快照、
  审计日志、意外的版本库提交，都不该带走密钥。
- **不阻断当前功能**：过渡期内允许明文存于 **0600** 的 live 文件（见 B14 约定），工具/门禁不拦。
- **明确的非目标**：不防「运行中的进程自己把密钥读进内存」——用户本来就能在 UI/CLI 里读写
  自己的配置；也不防 **root**（root 能读一切，讨论的是「非蓄意/非 root 读者」与磁盘载体）。

## 2. 现状盘点（2026-09-15，本地实证）

| 载体 | 位置 / 权限 | 现在是什么 |
| --- | --- | --- |
| DSH 自有凭据 | `.dsh/.credentials.yaml`（0600） | `version/records/refs` 结构，`CredentialRef→string` 映射，**明文**；harness 的 `dsh-credentials-local` 会热重载并合并并发写（`credentials-local/src/index.ts` 头注释） |
| modsearch | `~/.modsearch/config.json`（0600） | 可含字面 `tavily.apiKey`；原生支持 `TAVILY_API_KEY` 等 env（优先级高于文件） |
| modlens | `~/.modlens/config.json`（0600） | 可含字面 `providers.openai.apiKey`；原生支持 `OPENAI_API_KEY` 等 env（CLI flags > env > 文件 > built-ins） |
| 环境变量 | 进程内存 | 唯一的「不落盘」载体 |
| 版本库侧 | `config/plugin-configs/catalog.json` | `secretPolicy: env-ref / none` 已强制基线**不带字面密钥**；`save-settings.mjs` 对含字面密钥的 live **拒绝导出**（rc=1）——这是刻意的边界 |
| 服务器 | `deploy/dsh.service` | 目前只有 `Environment=…`，**没有** `EnvironmentFile=` / `LoadCredential=`；rsync 已排除 `.env*` 与 `log/` |

## 3. 方案分级（成本递增，每级都够用、都可单独上）

### 3.1 环境变量注入（首选，服务器的零代码路径）

密钥只存在于**进程内存 + 部署者可控的一个 0600 文件**，不随其他配置文件落盘。

- **systemd 侧**（`deploy/dsh.service` 加一行，不改 harness/插件）：
  `EnvironmentFile=/etc/dsh-secrets.env`（root:root 0600），`ExecStart` 前不落盘到任何
  `$DSH_HOME` 或插件 live 文件。更严格的形态是 **`LoadCredential=`**：systemd 在服务激活时
  注入、服务停即释放、只给 service user 经 `$CREDENTIALS_DIRECTORY` 读取、
  **不沿进程树传播**（systemd.io/CREDENTIALS）；可选 TPM2/`/var` 派生密钥加密存
  `/etc/credstore.encrypted/`。
- **modsearch/modlens**：它们的 env layer 原生读 `TAVILY_API_KEY` / `OPENAI_API_KEY`，
  文件里不写 key 即可。
- 代价：区分「部署者的机器」与「运行中的服务」；同一用户下任意同 uid 进程都能读环境变量
  ——但我们的服务是单一 root/systemd，威胁面可接受。

### 3.2 sops + age 加密配置（密钥要随 git 走时）

适用：希望「一份可提交、可审计、可复现部署的配置」且密钥非明文。

- **sops**（getsops.io）：加密**值**、保留键名与结构（YAML/JSON/ENV/INI），
  AES-256-GCM 加密值、会话密钥由身份加密；后端支持 age/PGP（离线）与 KMS/Vault（在线）。
  因此 `config/plugin-configs/` 里可以放一份 `.secrets.enc.yaml`（键名可见、值是密文），
  正常进版本库。
- **age**（github.com/FiloSottile/age）：比 PGP 简单的文件加密工具，
  `age-keygen` 生成 `AGE-SECRET-KEY-1…`（私钥）+ `age1…`（公钥）；
  age 私钥**不进仓库**（root-only 文件 / 独立机器 / U 盘）。
- 与现有工具的衔接（这是**将来**的扩展，今天不实现）：
  - catalog 条目加 `secretEngine: env | sops | keyring`（缺省 `env`）与一条 `secretRef`；
  - `save-settings.mjs save` 对命中 `secretPolicy` 的字段走 `sops set` 写密文，
    `seed` 时 `sops decrypt` 到 0600 live 文件或直接注入 env；
  - 门禁不变：**仓库里永远只允许密文/env 引用，不允许明文**。

### 3.3 OS keyring（本地交互式桌面可选）

- `@napi-rs/keyring`：macOS Keychain / Linux Secret Service(libsecret) / Windows
  Credential Manager。
- ⚠️ **headless Linux 不可用**：systemd 服务没有 D-Bus 会话 / gnome-keyring，
  `libsecret` 等于空转——所以**不用于服务器**，只作为桌面开发机的可选增强。
  （在线调研此库时 github/npm 抓取超时，维持这条基于既有工程共识的结论，落地前需再验证。）

### 3.4 远程 secret 管理（多机/多身份再上）

- Vault / 云 KMS / 云 Secret Manager；sops 已原生支持这些后端，届时只换身份源，不换流程。

## 4. 推荐路径与实施顺序

1. **过渡期（现状，B14 已登记）**：明文只在 0600 live 文件与 env；脚本/仓库/日志零密钥；
   `make save-settings` 对含密钥的 live 照旧拒绝导出（这是特性不是缺陷）。
2. **本周即可做（服务器零代码）**：`dsh.service` 加 `EnvironmentFile=/etc/dsh-secrets.env`
   （0600 root）或 `LoadCredential=`，把 modsearch/modlens/DSH 的密钥全部改为 env 注入，
   删除 live 文件里的字面 key。
3. **密钥要进 git 时**：引入 sops+age，`config/plugin-configs/*.secrets.enc.yaml`；
   等 `save-settings.mjs` 的 `secretEngine` 扩展。
4. **桌面本地**：可按需加 `@napi-rs/keyring`；服务器不用。
5. **多机**：换 Vault/KMS 后端。

## 5. 验收标准与「不做什么」

- **验收**：`grep -rnE '(sk-|tvly-|api[_-]?key[:=]|token[:=])' config/ scripts/ deploy/ log/ .dsh-* 2>/dev/null`
  （排除 `.dsh/` 与 `~/.modsearch`、`~/.modlens` 的 **live** 文件）应为空或只有占位符；
  备份/rsync/快照不含解密形态的密钥。
- **不做什么**：
  - 不 fork submodule 改 modsearch/modlens 的读取路径（那相当于让他们支持加密文件，负担大且
    上游一更新就错位）；
  - 不在本仓/本机脚本里存 age 主密钥（放 root-only 或独立机）；
  - 本轮**不实现** 3.2/3.3 的代码，只定方向。

## 6. 关联

- 遗留：[docs/backlog.md](backlog.md) B14
- 现状工具：`scripts/save-settings.mjs` + `config/plugin-configs/catalog.json`（`secretPolicy`）
- 凭据机制：`harness/packages/credentials/credentials-local`
- 服务器模板：`deploy/dsh.service`（`Environment=`；将来加 `EnvironmentFile=/LoadCredential=`）
