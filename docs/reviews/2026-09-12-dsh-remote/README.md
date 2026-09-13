# dsh-remote 评审归档（2026-09-12）

针对 [docs/dsh-remote.md](../../dsh-remote.md) 的三路独立评审，以及**评审之后的仲裁核实**。

## 归档内容

| 文件 | 说明 |
| --- | --- |
| [agent-architecture.md](agent-architecture.md) | 评审一：agent / 插件架构维度（719 行） |
| [typescript-engineering.md](typescript-engineering.md) | 评审二：代码质量 / 包工程 / 生态维度（411 行） |
| [network-security.md](network-security.md) | 评审三：网络与密码学安全维度 |
| [CONSOLIDATED.md](CONSOLIDATED.md) | 去重、按严重度排序后的汇总（含「对文档断言的反驳」一节） |
| 本文件 | 来源、方法、**仲裁结论** |

## 来源与可复现性

| 项 | 值 |
| --- | --- |
| 评审日期 | 2026-09-12 |
| 被评对象 | `https://github.com/mrRisega/dsh-remote` |
| 源码快照 A | **v0.6.3**，commit `baa6d533d3e4ce5e921b7bc5aa5c0a1689b2b7db`（当前线） |
| 源码快照 B | **v1.0.0**，commit `e5401f533dd090229d15edafa430d59bdb11918c`（旧的独立反代线，仅用于核对文档中「属于 v1.0.0」的论断） |
| 宿主（只读参照） | 本仓 `harness/`，`dsh-v0.1.5-rc.2`，commit `fb2c4b9e698e30edb738bca4cf0618587db7d203` |
| 评审方式 | **纯静态只读**：未安装、未构建、未执行被测项目脚本、未联网 |

> 报告正文里的 `/tmp/dsh-remote-review/src-v063`、`src-v100` 是评审时的临时快照路径，**不在本仓内**。要复核某条 `文件:行`，按上表 commit 重新 checkout 即可；报告中的行号均以该快照为准。

## 这些报告怎么读（重要）

- 三份报告是**评审员的原始输出，未经过编辑**。它们各自的「已核实」是**评审员自己的判断**，不是本仓的结论。
- **存在评审员也没说准的地方**（见下节仲裁），以及评审之间的结论冲突（`CONSOLIDATED.md` 中以 ⚠️ 标出）。
- **本仓的结论以修订后的 [docs/dsh-remote.md](../../dsh-remote.md) 为准**；本文件的「仲裁结论」一节是它与三份报告之间的裁判记录。

## 仲裁结论

> 下列每一条都由本仓**亲自复核**（重跑命令、重读源码），不是转述评审。

### A. 文档说错、评审也没说准的

| 论断 | 文档原文 | 评审说法 | **仲裁实测** |
| --- | --- | --- | --- |
| `execSync` 数量 | 「全部代码中**只有一处**」 | 「实际有 3 个文件 5 处」 | **4 个文件 6 处**：`dsh-setup.mjs:104`、`dsh-bridge.mjs:125`、`dsh-remote-web/lib/index.js:37`+`:695`、`dsh-remote-ui/lib/index.js:37`+`:695`。把生成的别名包 `dsh-remote-ui` 视为 `dsh-remote-web` 的副本时，去重后为 **3 个逻辑文件 5 处**——这大概是评审数字的来源。**v1.0.0 为 0 处**。 |
| `lib/` 的性质 | 「预构建产物，**无法**核对源码与产物的一致性」 | — | **`lib/` 就是手写源码，可直接审计**：`package.json` 的 `scripts` 为 `{}`、无任何打包器配置、`files` 直接发布 `lib`，且文件头是带日期的中文变更注释（"2026-09 由 dsh-remote-ui 更名 dsh-remote-web"、"0.4.7 起回归真正「未安装」状态"）。**结论（挂载时跳过构建）成立，但文档给的理由是错的。** |
| 代码规模 | 「约 9100 行」 | 见 `CONSOLIDATED.md` | **21,946 行**（非测试 14,570 / 15 个文件；测试 7,376 / 32 个文件）。其中两个插件包的 `lib/` 是**同一份代码的两份副本**，去重后独特代码 ≈ **10,006 行**。 |
| §6.4 加固建议 | 「能自建就自建」+「用 SaaS 则务必确认 E2EE 已开启」 | 网络安全评审指出自相矛盾 | **确认自相矛盾，二者不可兼得**：`dsh-bridge.mjs:1016` `const localMode = Boolean(process.env.DSH_BRIDGE_LOCAL_KEY); // 自建模式不启用(§6.6)`，`:1018` `const allowed = !localMode && !userDisabled;` → **自建中继时 E2EE 被硬禁用**（`e2ee-client.mjs:567` → `reason: "disabled_by_config"`）；插件 UI 对该 reason 的中文标签正是「当前为普通安全连接（HTTPS）」。 |
| **`engines.dsh` 兼容性** | 「`>=0.1.0-rc.6 <0.2.0-0` —— 本仓的 `0.1.5-rc.2` **在范围内**」（§2、§6.2） | TS 判「三条消费路径结论不同」；网络判「已核实」（**两者冲突**） | **TS 对，网络错**。实测：① `semver.satisfies("0.1.5-rc.2", ">=0.1.0-rc.6 <0.2.0-0")` → **`false`**（范围内唯一预发布比较子是 `0.1.0-rc.6`，与本版 `0.1.5` 不同 patch；`0.1.5` 正式版才是 `true`）。② dsh-web plugin-manager 的 `MINIMUM_RANGE_PATTERN`（`core/version.ts:90`）只接受**单个** `>=X.Y.Z[-pre]`，本插件的多比较子形状 → 返回 `undefined` → 该模块注释明确写「callers … **fail closed**」→ **拒绝**。③ harness **完全不读** `engines.dsh`（全仓 grep 零命中）→ submodule 挂载不被拦。 |
| **§9 许可证** | 「本仓其余插件**均为 MIT**」 | 架构评审指出不成立 | **确认不成立**。实测各插件 `license` 字段：`dsh-plugin-mineru` = **AGPL-3.0**、`dsh-web` = **Apache-2.0**（另含 BSD-3-Clause），其余 7 个为 MIT。本仓**本来就是混合许可**，引入 PolyForm-Noncommercial 不构成「MIT → 非 MIT」的突变；真正的点是 PolyForm-Noncommercial **比 AGPL-3.0 更严**（非 OSI 开源、禁商用）。 |
| **§4.1 推论** | 「`--trusted-host` 配合保留 Host 的普通反代**也能让全部方法通过**」，据此推荐方案 B | 架构 + 网络安全评审指出漏闸门 | **确认推论过强**。实测 `rpc-host.ts:97-100`：`if (!isTrustedApiRequest(...)) return 403; return this.browserAuth.isAuthenticated(request) ? undefined : 401` —— 围栏之后**还有一道浏览器认证**（`browser-auth.ts:289-302`，要求与请求 Host **权威绑定**的签名 cookie，无回环豁免）。**过围栏是必要但不充分**。方案 B 结论仍成立，但需**两件事**：`--trusted-host` **加上**一次性 `?token=` 交换拿到绑定该域名的 cookie。 |
| **§2 组件表** | 全文**未提 `dsh-setup.mjs`**（仓库根 791 行的安装器） | TS 评审列为高 | **确认遗漏**：`grep -c "dsh-setup" docs/dsh-remote.md` = **0**。已补进组件表与审计边界（它同时是 `execSync` 的调用方之一）。 |
| **§8 第 2 条（我加的）** | 初稿写「挂两份的后果是面板重复、路由重复注册」（措辞偏软） | 架构 + TS 评审给出更硬的后果 | **应升级为「启动即失败」**。实测：`scripts/link-plugins.sh:62,65,89` 的候选口径确实是「根包 + `packages/*/` 子包中声明 `dsh.bundle.patch` 的包」，**两个包都会被捞出来**；`harness/packages/host/webserver/src/index.ts:165-170` 的 `register()` 对重复 `(kind, path)` **直接 `throw`**（"a collision is a misconfiguration"）。已改写该条。 |
| **`DSH_RELAY_DIR`** | §8 初稿只说「源码安装需要手工准备该配置（或改 `relayDir`）」 | 架构评审给出机制 | **确认是两半默认目录不一致**：`dsh-setup.mjs:34-36` 在**非 node_modules 形态**（即 submodule/checkout）下 `CONFIG_DIR = THIS_DIR` → **凭据写进被 pin 的 submodule**；而 `lib/index.js:27` 插件侧默认 `~/.dsh-remote`。不显式设 `DSH_RELAY_DIR` 时安装器与插件**看的不是同一个目录** → 面板静默显示「尚未登录」。已补进 §8 第 3 条。 |

### B. 文档说对了、复核后维持原判的

| 论断 | 复核结果 |
| --- | --- |
| 全仓无 `PRIVILEGED_METHODS` | ✓ 确认不存在 |
| `isTrustedApiRequest` 全仓唯一调用点 | ✓ `harness/packages/client/connection/src/rpc-host.ts:98`，传 `this.trustedHosts`（非空数组） |
| DSH 只能绑两个字面量 / CLI 显式拒绝 `0.0.0.0` | ✓ `webserver/src/index.ts:126`、`web-app/src/startup.ts:74-76` |
| `--trusted-host` 机制存在（§7 方案 B 的依据） | ✓ `web-app/src/startup.ts:54` 定义了该选项 → **机制成立；但端到端可用性仍未实测** |
| bridge 只外连（不开入站端口） | ✓ |
| 凭据以 `0600` 落盘 | ✓ |
| 无 `eval` / `new Function` | ✓ 确认全仓无 |

### C. 归档时新发现（三份评审都未提及）

**`packages/dsh-remote-ui` 不是第二个插件，而是 `packages/dsh-remote-web` 的生成别名包。**

- 由 `scripts/sync-legacy-alias.mjs` 生成：注释原文「灰度兼容：把 packages/dsh-remote-web（正式包）同步生成一份旧名别名包 …使插件市场里"旧条目"在新名审核通过前依旧可安装」，它会把 `PLUGIN_ID` 与包名替换回 `dsh-remote-ui`。
- 两个包各自声明 `cordis.patch.yml`（id 分别为 `dsh-remote-web` / `dsh-remote-ui`），**都提供设置页面板与同源 `/dsh-remote/*` 路由**，且共用一个 bridge。
- **集成含义：只能挂一个，否则 `make dev` 启动即失败**（不是「面板出现两次」这么温和）。已核实的三步因果：
  1. `scripts/link-plugins.sh:62,65,89` 的候选口径是「根包 + `packages/*/` 子包中声明了 `dsh.bundle.patch` 的包」——两个包**都**符合 → **都会被挂上**；
  2. 两者注册**同一批** `/dsh-remote/*` 路由；
  3. `harness/packages/host/webserver/src/index.ts:165-170` 的 `register()` 对重复的 `(kind, path)` **直接 `throw new Error('webserver: duplicate ... route ...')`**（注释：「route patterns are a composition-level contract, so a collision is a misconfiguration」）。
- 这与本仓在 **dsh-better-sidebar** 上踩过的「同一插件被两个 entry 加载」是同一类问题，处置方式也一样——像 `patches/disable-web-ui-better-sidebar.yml` 那样显式禁掉一个（此处应排除 `dsh-remote-ui`）。

## 文档修订去向

本归档对应的修订落在 [docs/dsh-remote.md](../../dsh-remote.md)：

- 修正了 A 组**全部 7 条**（`execSync` 计数、`lib/` 性质、代码规模、§6.4 自相矛盾、`engines.dsh`、§9 许可证、§4.1 推论）；
- 新增 **§6.5「评审发现、本仓未复核的高危项」**——把 9 条高严重度但**本仓未亲自复核**的评审结论单列，逐条标出证据坐标，避免它们被当成已核实的结论；
- 新增 **R0**（插件路由零鉴权，本项最高危）、把 R4/R7 的过强表述改准、修正 §8 的落地方式（新增「只能挂一个」「`DSH_RELAY_DIR` 必须显式设」「挂载即自装」三条已核实约束）；
- 开头加「**先评估本仓已有的 `remote-web-ui`**」的前置结论（详见 [docs/remote-access.md](../../remote-access.md)），§7 对比表加了「方案 0」一列。

**仲裁原则**：凡本仓重跑过命令 / 重读过源码的，写进正文并标「已核实 / 已实测」；凡只来自评审、本仓没验的，一律标「评审声称 / 未复核」。`CONSOLIDATED.md` 里两处 ⚠️ 冲突（`lib/` 性质、`engines.dsh`）已在 A 组中仲裁完毕——**两处都是 TS 评审对、网络评审错**。
