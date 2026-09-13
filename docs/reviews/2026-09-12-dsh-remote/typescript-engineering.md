# 评审报告：`docs/dsh-remote.md` 在「代码质量 / 包工程 / 生态」维度的准确性

- 评审对象文档：`/Users/michaelyao/workspace/dsh/docs/dsh-remote.md`
- 被评源码：`/tmp/dsh-remote-review/src-v063`（v0.6.3）、`/tmp/dsh-remote-review/src-v100`（v1.0.0）
- 参照物：`/Users/michaelyao/workspace/dsh/plugins/*`（本仓既有插件）
- 评审方式：只读静态核实（grep / wc / diff / md5 / 本地 semver 计算）。**未执行安装、构建、联网**。
- 日期：2026-09-12

**总体判定**：文档在「架构 / 安全 / 方案对比」维度质量较高（多处 file:line 出处可复核且准确），但在「代码规模 / 包工程 / 生态契约」维度存在**实质性错误**，且**漏掉了 5 个会直接影响本仓集成决策的工程问题**。最严重的一条是 §6.2 把「只有一处 `execSync`」列为「已核实」，实际有 3 个文件 5 处。

问题计数：**高 6 条 / 中 5 条 / 低 3 条 / 额外遗漏 2 条**（详见文末汇总）。

---

## 0. 行数与代码构成的准确基线（后续多条论断引用此表）

文档全文没有给出构成拆分，只有 §6.1 一句「约 9100 行」。我实测的准确构成如下（`wc -l`，v0.6.3，排除 `.git` 与 `node_modules`）：

| 类别 | 行数 | 文件数 | 说明 |
|---|---|---|---|
| 手写源码（client / relay / scripts，不含测试） | **4,651** | 10 | `clients/dsh-remote/{dsh-bridge,e2ee-client,e2ee-shim,mobile-adapter,e2ee-shim-script}`、`clients/dsh-remote/src/lifecycle.mjs`、`packages/relay-router/src/{index,jwt,quotas}.mjs`、`scripts/sync-legacy-alias.mjs` |
| 安装器（bin） | **791** | 1 | `dsh-setup.mjs` ← **文档全文 0 次提及** |
| 插件包 `lib/`（`dsh-remote-web` 一份） | **4,564** | 2 | `lib/index.js` 2193 + `lib/client.js` 2371 |
| 插件包 `lib/`（`dsh-remote-ui` 别名副本） | **4,564** | 2 | 与上一行仅差 7 行（plugin id 字符串） |
| 测试 | **7,376** | 32 | `clients/dsh-remote/test/` 2433、`packages/dsh-remote-web/test/` 4254、`packages/relay-router/test/` 689 |
| **`.mjs`+`.js` 全仓合计** | **21,946** | 49 | 另有 markdown 1,622 行 |

**手写、去重后的真实审计面** = 4,651 + 791 + 4,564 = **10,006 行**；计入测试为 **17,382 行**。

关于「9100」这个数字的来源，我做了反向拟合：`clients/dsh-remote`（非测试，3,287）+ `packages/relay-router/src`（1,252）+ **一份** `lib/`（4,564）= **9,103** —— 与文档的「约 9100」几乎完全吻合（另一可能来源是两份 `lib/` 之和 9,128）。

---

## 1. 【高】「约 9100 行」把手写源码与仓内插件 bundle 混在一个口径里

**文档原文**（§6.1，`docs/dsh-remote.md:163`）：

> 我**通读了** v1.0.0（约 1000 行）并逐项核对了它的安全声明；**v0.6.3 约 9100 行**（`clients/dsh-remote` + `packages/relay-router` + 两个插件包的 `lib/`），**我只做了定向扫描，没有做完整审计**。

**证据**：见 §0 表。该口径下 9,103 行里有 **4,564 行（50.1%）是 `packages/*/lib/`**。

**判定**：
- **数字本身可复现**（9,103 ≈ 9100），不是编造。
- **但口径是误导性的**：文档在 §3（`docs/dsh-remote.md:89`）、§6.2（`:174`）和 R7（`:188`）三处把 `lib/` 定性为「**预构建产物**」「无法从本仓核对源码与产物的一致性」。也就是说，这个「9100 行」里有**一半是文档自己声明"无法核对"的东西**——用"无法审计的部分"充大"待审计规模"，逻辑上自相矛盾。
- 同时**漏掉了 7,376 行测试**与 **791 行安装器**。安装器漏得尤其不该（见 §4）。

**建议怎么改文档**：把 §6.1 的一句话换成 §0 那样的四行拆分表，并明确写出「手写源码 5,442 行（含安装器）/ 插件 bundle 4,564 行 / 测试 7,376 行」。「9100」这个单一数字无论如何都不该继续用。

---

## 2. 【高】`lib/` 不是「预构建产物」，而是**手写源码**——R7 的核心结论说反了

**文档原文**：

> §1（`:24`）：`lib/` **已提交在仓库内**（预构建）
> §3（`:89`）：插件的 `lib/` **已提交（预构建）** → 命中「跳过构建」判据
> R7（`:188`）：插件包 `lib/` 是**预构建产物（无法从本仓核对源码与产物的一致性）**
> §6.2（`:174`）：两个插件包的 `lib/index.js`、`lib/client.js` **已提交**（预构建，无需构建即可挂载）

**证据**：

| 证据 | 位置 | 内容 |
|---|---|---|
| 文件头自述 | `packages/dsh-remote-web/lib/client.js:1` | `// dsh-remote-web — browser half（手写 bundle，无需构建）` |
| 文件头自述 | `packages/dsh-remote-web/lib/client.js:3` | `// 格式遵循 dsh 浏览器插件约定（双半插件，bundle 手写无构建）：` |
| 无打包器特征 | `packages/dsh-remote-web/lib/{index,client}.js` | `grep -c "__commonJS\|__toESM\|__require\|esbuild\|rollup\|tsdown"` = **0 / 0** |
| 无压缩痕迹 | 同上 | client.js 平均行宽 **55.7** 字符、最长 **413** 字符（压缩产物应远超此） |
| 全仓无构建配置 | `find` 全仓 | **0** 个 `tsconfig*.json` / `vite.config.*` / `tsdown.config.*` / `rollup.config.*` / `esbuild` 配置 |
| 无 sourcemap | `grep -c sourceMappingURL` | 0 / 0 |
| 唯一"构建"步骤 | 根 `package.json` 的 `check` 脚本 | `node --check .../lib/index.js && node --check .../lib/client.js` —— **只是语法检查** |

**判定**：**术语错误，且结论方向反了。**

- 事实是：仓库里**不存在**「源码 → 产物」的分离。`lib/` 就是唯一源码，且是可读的（有注释、有 JSDoc、未压缩）。
- 因此 R7 的「无法从本仓核对源码与产物的一致性」**不成立**——不存在一致性问题。真实情况正好相反：**这份代码是可以在仓内直接审阅的**，文档不该用它当"不可审计"的理由。
- 「命中跳过构建判据」这个**操作结论仍然对**，但理由错了：不是"因为已预构建"，而是"**因为整个项目根本没有构建管线**"。
- 真正该由此得出的结论是：**没有类型、没有类型检查、没有 lint、没有构建期校验**（见 §11）。

**建议怎么改文档**：删除所有「预构建」措辞，改为：「插件代码以**手写 ESM bundle** 形式直接提交在 `lib/`，仓库内不存在任何构建配置；质量闸门只有 `node --check`（语法）与 `node --test`。R7 应改为『我没有审计这 4,564 行插件代码』，而不是『无法核对一致性』。」

---

## 3. 【高】§6.2「全部代码中只有一处 `execSync`」——实际是 3 个文件 5 处

**文档原文**（§6.2「已核实项」表，`docs/dsh-remote.md:170`）：

> | 危险原语 | 全部代码中**只有一处** `execSync`：`clients/dsh-remote/dsh-bridge.mjs:125` 执行 `ioreg -rd1 -c IOPlatformExpertDevice`（macOS 读硬件 UUID 作设备身份），**非恶意**；无 `eval` / `new Function` |

**证据**（`grep -rn "execSync"` 全仓，排除 `node_modules`）：

| # | 位置 | 内容 | 文档是否提及 |
|---|---|---|---|
| 1 | `dsh-setup.mjs:104` | 通用 `sh(cmd, timeoutMs, cwd)` 包装：`execSync(cmd, {...})` | ❌ 未提及 |
| 2 | `clients/dsh-remote/dsh-bridge.mjs:125` | `execSync("ioreg -rd1 -c IOPlatformExpertDevice", ...)` | ✅ 就是这条 |
| 3 | `packages/dsh-remote-web/lib/index.js:37` | 通用 `sh(cmd)` 包装：`execSync(cmd, {... timeout: 15000})` | ❌ 未提及 |
| 4 | `packages/dsh-remote-web/lib/index.js:695` | `execSync("sleep 1", { timeout: 3000 })` | ❌ 未提及 |
| 5 | `packages/dsh-remote-ui/lib/index.js:37,695` | 同 3、4 的同步副本 | ❌ 未提及 |

**判定**：**错误，且方向是"低估风险"**。

- 文档漏掉的 #1 与 #3 都是**通用 shell 执行包装**（接受任意命令字符串），不是一个写死的 `ioreg`。它们的调用点我逐条查过（`packages/dsh-remote-web/lib/index.js` 共 **16 处** `sh(...)` 调用，绝大多数是 `launchctl` / `systemctl` / `pgrep` / `ps` 常量命令，`:339,:376,:515,:552,:553,:555,:556,:606` 用 `${target}` / `${pid}` / `${q(plistPath)}` 插值），**我未发现外部可控输入直接进入命令字符串的证据**——所以我不主张这里有命令注入，但**"只有一处 execSync，且是个无害的 ioreg"这个描述确实是错的**，而文档把它列在「已核实」栏里。
- 值得注意的因果：文档漏掉的 `dsh-setup.mjs` 正好在它自己的行数口径之外（§6.1 只列了 `clients/dsh-remote` + `relay-router` + `lib/`）——**口径的遗漏直接导致了"已核实"结论的错误**。
- **「无 `eval` / `new Function`」这半句我核实为真**：严格 grep（`\beval\s*\(`、`Function\s*\(`、字符串形式 `setTimeout`/`setInterval`、`vm.`、动态 `require`）在非测试代码中**全部 0 命中**。

**建议怎么改文档**：改为「`execSync` 出现在 3 个文件：安装器 `dsh-setup.mjs:104`、bridge `dsh-bridge.mjs:125`、插件 host 半 `lib/index.js:37,695`（另有一份同步副本）。其中 `dsh-setup.mjs:104` 与 `lib/index.js:37` 是通用 shell 执行包装 `sh(cmd)`，调用参数以 `launchctl`/`systemctl` 常量与内部路径为主，未见外部可控输入直接拼入；无 `eval` / `new Function`（已核实）。」

---

## 4. 【高】文档全文遗漏 `dsh-setup.mjs`（791 行）——而它是最有特权的组件

**文档原文**：`grep -c "dsh-setup" docs/dsh-remote.md` = **0**。§2 的「仓库内组件」表（`:68-77`）只列了 5 项，没有它。

**证据**：

| 事实 | 位置 |
|---|---|
| 它是本包的**官方入口**（`npx @mrrisega/dsh-remote` 落地的就是这个文件） | 根 `package.json`：`"bin": { "dsh-remote": "dsh-setup.mjs" }` |
| 写 macOS LaunchAgent plist | `dsh-setup.mjs:189`（路径）、`:199-211`（内容 + `writeFileSync`） |
| 写 Linux systemd user unit | `dsh-setup.mjs:191`、`:217-220` |
| 执行 `launchctl bootout/bootstrap/unload/load` | `dsh-setup.mjs:241-248` |
| 执行 `systemctl --user restart/is-active` | `dsh-setup.mjs:262-264` |
| 写配置（0600） | `dsh-setup.mjs:140-141` |
| "运行时自物化"：把 `ws` 等依赖固化进配置目录 | `dsh-setup.mjs:43-86` |

**判定**：**重大遗漏**，且与文档自身的叙述冲突——§3（`:88`）和 §5（`:145`）都提到官方安装方式是 `npx @mrrisega/dsh-remote`，§5 还描述了它会"创建开机自启服务"，但**从没指出这条命令的实现就在仓内、有 791 行、`execSync` 就在里面**。文档把它当成了一个外部黑盒（"作者的官方方式"），实际它是被评代码的一部分。

**建议怎么改文档**：§2 组件表增加一行 `dsh-setup.mjs`（安装器 / `bin` / 791 行，负责写配置、装 launchd/systemd 自启、执行 npx）；§6.1 的口径把它算进审计面；§6.2 §6.3 的 execSync 相关条目引用它。

---

## 5. 【高】`engines.dsh` 兼容性结论只在一种消费路径下成立

**文档原文**：

> §2（`:78`）：两个插件包的 `engines.dsh` 声明为 `>=0.1.0-rc.6 <0.2.0-0` —— **本仓的 `0.1.5-rc.2` 在范围内**。
> §6.2（`:176`）：`engines.dsh: ">=0.1.0-rc.6 <0.2.0-0"` —— 本仓 `0.1.5-rc.2` **满足**

**证据**（三条消费路径，结论各不相同）：

1. **声明位置与生态惯例不同**：`packages/dsh-remote-web/package.json` 把它放在**顶层** `engines.dsh`；而本仓生态的惯例是 `dsh.engines.dsh`（`plugins/dsh-web/scripts/family-dsh-engines.test.mjs:22` 断言 `pkg.dsh.engines.dsh`）。读取方 `dshRequirementOf`（`plugins/dsh-web/packages/dsh-plugin-manager/src/core/version.ts:123-131`）会回退到顶层，**所以能读到**——不是致命问题，但属惯例偏离。

2. **npm/semver 默认语义下【不满足】**：用本仓 `plugins/dsh-at-file/node_modules/semver` 实测：
   ```
   semver.satisfies('0.1.5-rc.2', '>=0.1.0-rc.6 <0.2.0-0')                          => false
   semver.satisfies('0.1.5-rc.2', '>=0.1.0-rc.6 <0.2.0-0', {includePrerelease:true}) => true
   ```
   原因即 npm 的 prerelease 规则：预发布版本只有在范围内**某个 comparator 的 major.minor.patch 与它相同**时才可能满足，而 `0.1.5` 不在任何 comparator 里。任何用裸 `semver.satisfies()` 做检查的工具都会判「不兼容」。

3. **dsh-market 路径【满足】**：`plugins/dsh-market/src/discovery-compatibility.ts:129` 的 `rangeResult` 显式传 `{ includePrerelease: true }` → 通过。

4. **dsh-web 的 plugin-manager 路径【无法判定 → fail-closed】**：
   - `plugins/dsh-web/packages/dsh-plugin-manager/src/core/version.ts:90`：
     `const MINIMUM_RANGE_PATTERN = /^>=\s*(v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/`
   - `>=0.1.0-rc.6 <0.2.0-0` 含**两个 comparator**，**不匹配**该正则；
   - `meetsMinimumDsh()`（同文件 `:99-108`）因此返回 `undefined`；
   - 同文件 `:99-108` 的文档注释写明：`callers treat undefined as "cannot verify" and **fail closed** for declared requirements`（见 `:4-13` 的模块注释与 issue #754 说明）。
   - 出人意料的是，这个检查**刻意避开了 `semver.satisfies`**（`:7-11` 注释：「npm's prerelease rule only allows a prerelease version to satisfy a comparator set carrying a prerelease on the same major.minor.patch tuple, which would reject a newer host line…」），所以第 2 条的 false 在这里反而不适用——它是因为**区间形式**而非 prerelease 规则而失败。

**判定**：文档把「在范围内/满足」写成了**无条件事实**，实际它**依赖消费者**：market 通过、plugin-manager fail-closed、裸 semver 为 false。这是文档在「生态」维度上最应该讲清楚而没讲清的一条。

**建议怎么改文档**：把 §2 `:78` 与 §6.2 `:176` 改为条件式：「声明形式为双 comparator 区间。在本仓 `dsh-market` 的兼容性判定（`includePrerelease: true`）下通过；但该形式**不满足** `dsh-web` plugin-manager 的 `MINIMUM_RANGE_PATTERN`（只接受 `>=X.Y.Z[-prerelease]` 单形式），按该模块注释会被判为『无法验证 → fail-closed』。若采用，建议上游把声明改写为单 comparator 形式（如 `>=0.1.0-rc.6`），以同时兼容两条路径。」

**未核实**：我没有端到端跑 plugin-manager 对 dsh-remote 的实际判定（需安装），因此「fail-closed 的具体用户可见后果」未实测；上文的结论严格限于 `version.ts` 的代码语义。

---

## 6. 【高】两个插件包会被本仓 `link-plugins.sh` **同时挂载**（文档只说了一半）

**文档原文**（§8.1–8.2，`docs/dsh-remote.md:225-227`）：

> 两个插件包的 `lib/` 已提交 → 挂载时**跳过构建**；
> `packages/dsh-remote-web` / `packages/dsh-remote-ui` 是 **workspace 子包**（不是仓库根包），需按 `plugins/*/packages/*` 的子包候选处理。
> **插件半**（`dsh-remote-web`）可按既有方式 link 进 profile

**证据**：

1. 候选收集（`scripts/link-plugins.sh:89-105`）：遍历 `plugins/*/packages/*/`，凡 `package.json` 声明 `dsh?.bundle?.patch` 者一律加入 `RAW`。
2. 两个包**都**声明了：`packages/dsh-remote-web/package.json` 与 `packages/dsh-remote-ui/package.json` 的 `"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }`。
3. 唯一去重规则（`scripts/link-plugins.sh:163-170`）：仅当某**子包候选**的 `name` 出现在**其它候选**的 `dependencies`/`peerDependencies`/`optionalDependencies` 中时才跳过——而该判断依赖 `DEP_NAMES`（收集于 `:146-152`）。
4. **去重不会触发**：`packages/dsh-remote-web/package.json` **完全没有** `dependencies` / `peerDependencies` / `optionalDependencies` 字段；`packages/dsh-remote-ui/package.json` 由它同步生成，同样没有。两者**互不引用**，因此 `DEP_NAMES` 里不含任何一个的名字。
5. 结果：两个包都进 `CANDIDATES`（`:130-136`），都执行 `dsh plugin --profile "$PROFILE" add "link:$c"`（`:172`）。
6. 两者的 `cordis.patch.yml` 各自 `insert` 一条：`packages/dsh-remote-web/cordis.patch.yml:6-7`（`id: dsh-remote-web`）与 `packages/dsh-remote-ui/cordis.patch.yml:6-7`（`id: dsh-remote-ui`）——**两条都会生效于同一 profile**，都注册同源 `/dsh-remote/*` 路由与同一设置页栏目。

**判定**：文档把它写成了「两个包都算子包候选」（对）＋「插件半 dsh-remote-web 可按既有方式 link」（只提了一个），**漏掉了必然结果：本仓的现有脚本会把两份都挂上去**。这会在 `make dev` 时产生重复路由 / 重复设置页栏目 / 两套 launchd 控制逻辑并存。

**建议怎么改文档**：§8.1 增补一句：「注意：本仓 `scripts/link-plugins.sh:89-105` 会收集 **所有** 声明了 `dsh.bundle.patch` 的 `packages/*/` 子包，而其去重规则（`:163-170`）依赖候选间的 `dependencies` 引用——两个包互不引用，因此**会被同时挂载**（挂载动作在 `:172`）。收进本仓时必须显式二选一：要么在 vendored 副本中移除 `packages/dsh-remote-ui` 的 `dsh.bundle.patch`，要么删除该目录。」

---

## 7. 【中】`packages/dsh-remote-ui` 双份代码的维护风险（文档零覆盖）

**文档原文**（§2 表，`docs/dsh-remote.md:73`）：仅一句「同上，注释写明是「旧名别名，同步自 dsh-remote-web」」。§6、§8 均未展开。

### 7.1 两份 `lib/` 是否逐字节相同？——否，但差异精确且可解释

`md5` 不同（`dsh-remote-web/lib/index.js` = `75e7c0c0…` vs `dsh-remote-ui/lib/index.js` = `40536b1e…`），但 `diff` 显示**差异只有 4 处、共 7 行**，全部是 plugin id 字符串：

```
packages/dsh-remote-web/lib/index.js:1575  < const PLUGIN_ID = "dsh-remote-web";
packages/dsh-remote-ui/lib/index.js:1575   > const PLUGIN_ID = "dsh-remote-ui";
packages/dsh-remote-web/lib/index.js:1577  < const PLUGIN_LEGACY_IDS = ["dsh-remote-ui"];
packages/dsh-remote-ui/lib/index.js:1577   > const PLUGIN_LEGACY_IDS = ["dsh-remote-web"];
packages/dsh-remote-web/lib/client.js:25   <   id: "dsh-remote-web",
packages/dsh-remote-ui/lib/client.js:25    >   id: "dsh-remote-ui",
packages/dsh-remote-web/lib/client.js:42   <     styleEl.setAttribute("data-plugin", "dsh-remote-web");
packages/dsh-remote-ui/lib/client.js:42    >     styleEl.setAttribute("data-plugin", "dsh-remote-ui");
```

**判定**：当前**处于同步状态**（`screenshots.json` 逐字节相同；`cordis.patch.yml` 只差 id 与首行注释）。**但 md5 不同这一点本身容易误导复核者**——文档如果只是"看一眼 md5"会得出"已经漂移"的错误结论。这正好是文档应该写清楚的。

### 7.2 靠脚本同步是否可靠？——**部分可靠，有一个明确的盲区**

`scripts/sync-legacy-alias.mjs` 的设计比我预期的好：

**做得对的地方**：
- `SUBS`（`:28-41`）对每个待替换片段做「命中不到即报错」（`:78-81`：`problems.push('… 源包结构可能已变，请更新 sync 脚本')`），**防的是静默漂移**——这段注释（`:27`：`必须命中的替换（命中不到即报错，避免静默漂移）`）说明作者是清醒的。
- `emit()`（`:49-60`）在 `--check` 模式下只比对不写入。
- 覆盖范围：`lib/index.js`、`lib/client.js`、`cordis.patch.yml`（`:28-41`）+ `package.json`、`screenshots.json`、`README.md`（`:73,91,92`）= **6 个文件**。

**盲区（文档未提）**：
- **新增文件不会被同步，也不会报错**。脚本没有任何"目录清单比对"：若源包新增 `lib/foo.js`、或 `package.json` 里新增一个 `exports` 子路径指向新文件，别名包会**静默缺失该文件**——`--check` 只重算这 6 个已知路径，发现不了"少了一个文件"。
- `cordis.patch.yml` 的首行注释替换用的是正则 `/^# dsh-remote-web/m`（`:85`），**这是全脚本唯一一处"匹配不到也不报错"的替换**（对比 `SUBS` 的 `problems.push`）。属小的不一致，风险低（注释行而已）。
- 别名包**没有自己的测试目录**（`packages/dsh-remote-ui/` 下无 `test/`，见 `find` 结果），测试全部针对 `packages/dsh-remote-web/test/*.test.mjs`（根 `package.json` 的 `test:plugin` 脚本：`node --test --concurrency=1 packages/dsh-remote-web/test/*.test.mjs`）——**即别名包这份代码从不被测试**。

### 7.3 漂移了会怎样？——CI 只在一条路径上拦得住

- `--check` 通过 `npm run check` → `check:alias` 触发，而 `npm run check` 在 `.github/workflows/ci.yml` 的 `Syntax check` 步骤里跑；
- `.github/workflows/ci.yml` 的触发条件是 `push: branches: [main]` / `pull_request: branches: [main]`；
- **`.github/workflows/release-tarballs.yml` 不跑 `npm run check`**：它直接 `cd packages/$pkg && npm pack`（`:66-70`），只校验包内 `version` 与 `VERSION` 一致（`:79-88`）。
- ⇒ **可以在别名包未同步的情况下打 tag 并发布**。而别名包恰恰是"市场旧条目"指向的可安装产物（其 `package.json` description 自述：`kept installable while the renamed entry is pending review`）——漂移后，从旧条目安装的用户拿到的会是与新名条目**不一致**的代码。

**建议怎么改文档**：新增一节「双份代码的维护风险」，写清三点：(1) 当前两份 `lib/` 只差 7 行 id 字符串、md5 不同是预期的；(2) 同步脚本覆盖 6 个固定文件，新增文件不会被同步也不会报错；(3) CI 只在 main 分支校验，发布工作流不校验，漂移可被发布出去。

---

## 8. 【中】`@dsh-remote/client` 的 `main` 指向一个不存在的文件

**文档原文**：文档对 `package.json` 工程质量**完全没有评估**（只在 §2 `:78` 和 §6.2 `:176` 引用 `engines.dsh`）。

**证据**：

| 项 | `clients/dsh-remote/package.json` | 判定 |
|---|---|---|
| `"main": "src/index.js"` | `clients/dsh-remote/src/` 下**只有 `lifecycle.mjs`（3 行）**，**没有 `index.js`** | ❌ **悬空入口** |
| `exports` | 缺失 | ⚠️ 现代 Node 会用 `main` 回退，但 `./src/lifecycle.mjs` 无法被子路径导入 |
| `files` | 缺失 | ⚠️ 若发布，会带上 `test/`（2433 行） |
| `engines` | 缺失 | ⚠️ |
| `private` | 缺失（但同时有 `license`） | ⚠️ |

**判定**：`main` 指向不存在的文件是**确定的包工程缺陷**。它现在没炸，是因为没有任何代码 `import '@dsh-remote/client'` —— bridge 是由 `dsh-setup.mjs` 直接 spawn `.mjs` 文件运行的。一旦有人按包名消费它，resolve 立即失败。

**建议怎么改文档**：§3 或新增的「包工程」小节记录此项；行动上建议上游把 `main` 指向 `dsh-bridge.mjs`，或直接删掉该字段并标 `private: true`。

---

## 9. 【中】两个插件包缺 `publishConfig` / `engines.node` / **LICENSE**；发布的 tarball 不带许可证正文

**文档原文**（§9，`docs/dsh-remote.md:237-246`）：讨论了许可类型与义务（"须保留 `Required Notice` 署名"），但未涉及发布物本身。

**证据**：

| 项 | `packages/dsh-remote-web` | `packages/dsh-remote-ui` | 参照：`plugins/dsh-at-file` |
|---|---|---|---|
| `LICENSE` 文件在包目录 | ❌ 无（目录只有 `cordis.patch.yml`、`lib/`、`package.json`、`README.md`、`screenshots.json`、`test/`） | ❌ 无 | ✅ `plugins/dsh-at-file/LICENSE` 存在 |
| `files` 白名单含 `LICENSE` | ❌ `["lib","cordis.patch.yml","screenshots.json","README.md"]` | ❌ 同 | ✅ `files` 含 `"LICENSE"` |
| `publishConfig` | ❌ 缺失（根有 `"access":"public"`） | ❌ 缺失 | — |
| `engines.node` | ❌ 缺失 | ❌ 缺失 | — |
| `exports` | ✅ 有（`.` / `./client` / `./package.json`）—— **文档没有说它缺，实测也确实不缺** | ✅ 同 | ✅ 有，且带 `types` 条件 |

发布路径：`.github/workflows/release-tarballs.yml:66-70` 在 `packages/$pkg` 目录内执行 `npm pack`，因此打进 tarball 的就是上面的 `files` 白名单 —— **许可证正文不在其中**。

**判定**：
- **`exports` 字段并不缺失**（我在核实前怀疑的方向被证伪，如实记录）。
- **真正的缺口是 LICENSE**：代码为 PolyForm-Noncommercial-1.0.0（非 OSI 许可，条款要求随附 "Required Notice" 与许可文本），而**分发给用户的 tarball 里没有许可文本**。对照本仓 `plugins/modlens/LICENSE`、`plugins/dsh-at-file/LICENSE` 都随包发布。文档 §9 花了一整节讲许可义务，却没注意到发布物里没有许可正文。
- `publishConfig.access` 对**非 scoped** 包名（`dsh-remote-web`）不是必需的，属可选，不必当作缺陷上报。

**建议怎么改文档**：§9 末尾补一句「注意：两个插件包的发布 tarball（`files` 白名单）**不含 LICENSE 文件**，包目录内也不存在 LICENSE；PolyForm-Noncommercial 要求随附许可与 Required Notice，建议要求上游补齐。」

---

## 10. 【中】`.mjs` 侧的健壮性：一处**认证前可达**的无界内存累积（relay 与 bridge 同构）

**文档原文**：§6 只评估了**保密性**面（E2EE、中继信任、凭据落盘、loopback 伪装），**完全没有评估可用性 / 资源耗尽面**。

**证据**（分块重组缓冲无上界）：

- 两份**同构**实现，注释也承认同构（`packages/relay-router/src/index.mjs:228`：`// ---------- 分块信封重装(与 bridge makeFrameReceiver 同构) ----------`）：
  - `packages/relay-router/src/index.mjs:231-259`
  - `clients/dsh-remote/dsh-bridge.mjs:304-326`
- 关键片段（relay 版，`:244-254`）：
  ```js
  if (obj && obj.__chunk) {
    const c = obj.__chunk;
    let acc = bufs.get(c.id);
    if (!acc) { acc = { n: c.n, parts: [] }; bufs.set(c.id, acc); }   // :246-249
    acc.parts[c.i] = c.data;                                         // :250
    if (acc.parts.filter(Boolean).length === acc.n) {                // :251
      bufs.delete(c.id);                                             // :253 ← 唯一删除点
  ```
- **`c.id` / `c.n` / `c.i` 无任何校验**（无类型检查、无上界、无条目数上限）。`c.id` 由对端完全控制，`bufs` 是普通 `Map`，`:253` 是唯一删除点，**连接关闭时也没有清理**。发送 `{"__chunk":{"id":"<随机串>","n":1000000000,"i":0,"data":"x"}}`，`parts.filter(Boolean).length` 永远到不了 `1e9`，该条目**永久驻留** ⇒ 每条消息泄漏一个 Map 条目 ⇒ 内存耗尽。
- **挂载点在对端认证之前**：relay 的 `const receive = makeFrameReceiver()`（`:699`）挂在 tunnel `ws` 的 message 处理上；bridge 的（`dsh-bridge.mjs:980`）同样直接挂在 `ws.on("message", ...)`（`:979`）。注意 bridge 侧隧道是**长期常驻**连接（README 与文档 §3 都强调 bridge 常驻 + 开机自启），所以 Map 的生命周期≈进程生命周期。
- **放大因素**：`packages/relay-router/src/index.mjs:172`
  ```js
  const WS_MAX_PAYLOAD = 256 * 1024 * 1024;
  ```
  用于 `:685,:686` 两个 `WebSocketServer` 的 `maxPayload`——**单帧 256 MB**。`maxPayload` 只约束**单帧**，不约束上述**跨帧累积**。
- **反证（说明这是遗漏而非设计取舍）**：仓库对限流是有意识的——`packages/relay-router/src/quotas.mjs`（179 行）专门实现带宽/流量配额。但配额在 HTTP 层，不覆盖 WS 分块累积路径。

**判定**：这是一个**具体的、有 file:line 依据的资源耗尽面**，且落在公网中继上（自建时则落在你自己的公网机器上）。文档 §7 把「自建 relay」列为推荐方案，却没有提示这个面。

**我不断言的部分**：我没有构造 PoC、没有实测利用，以上是静态分析结论；实际可达性取决于 tunnel 建立前是否有其它屏障（我未逐行追完 relay 的握手鉴权流程，标为未核实，见文末）。

**建议怎么改文档**：§6.3 风险清单增加一条「R8：可用性/资源耗尽未评估」，并写明 relay 的单帧上限 256 MB 与分块缓冲无界这两点；§6.1 的"只做定向扫描"声明里点名"未评估 DoS 面"。

---

## 11. 【中】质量闸门薄弱：无类型 / 无 lint / 无构建，CI 的 audit 永不失败

**文档原文**（§3 对比表，`docs/dsh-remote.md:89`）：只有「构建 | 视包而定（有的跳过）| 插件的 `lib/` 已提交（预构建）→ 命中「跳过构建」判据」一行。文档标题是「技术评估」，但**没有任何一行评估类型/lint/覆盖率等质量闸门**。

**证据**：

| 项 | dsh-remote v0.6.3 | `plugins/dsh-at-file` | `plugins/modlens` |
|---|---|---|---|
| 语言 | **纯 JS**（42 `.mjs` + 5 `.js`，**0 个 `.ts`**） | TypeScript | TypeScript |
| 类型检查 | ❌ 无 | ✅ `"typecheck": "tsc --noEmit"` | ✅ `"typecheck": "tsc --noEmit"` |
| lint | ❌ 无 | —— | ✅ `"lint": "biome check src scripts dsh"` |
| 构建 | ❌ 无（无任何构建配置） | ✅ `"build": "node build.mjs"` | ✅ `"build": "vite build"` |
| 测试框架 | ✅ `node --test`（原生） | ✅ `vitest run` | ✅ `vitest run --coverage` |
| `exports.types` | ❌ 无 | ✅ `./lib/types/*.d.ts` | ✅ |
| 静态检查步骤 | `node --check`（语法级）+ `bash -n` | tsc | tsc + biome |

（dsh-remote 的 `check` 脚本全文：`node --check` 5 个文件 + `bash -n deploy/install-open.sh` + `npm run check:alias`。**没有类型、没有 lint、没有构建**。）

CI 侧（`.github/workflows/ci.yml`）：
- `audit` job 的命令是 `npm audit --audit-level=high || true` —— **`|| true` 使其永不失败**，等于没有审计门禁。
- CI 矩阵跑 Node 20 与 22。

**判定**：文档 §3 的「构建」一行只谈到"跳过构建"这个**操作便利**，没有指出它同时意味着**放弃了所有编译期保证**。在"JS 无类型靠什么保证契约"这个问题的答案上，实际答案是：**靠 7,376 行测试 + `node --check`**，没有任何类型层保证。文档没有回答这个问题。

**建议怎么改文档**：§3 表增加一行「质量闸门 | dsh-remote：`node --check` + `node --test`（**无类型、无 lint、无构建**）| 对比插件：tsc + lint + 构建」；并在 §6 明确「JS 无类型，契约靠测试保证，无编译期检查」。

---

## 【低】三处小问题

### L1. `package-lock.json` 陈旧且把依赖钉在第三方镜像

`package-lock.json` 的 root `version` 是 `0.6.1-beta.1`（`package.json` 是 `0.6.3`）；`packages/dsh-remote-web` 记 `0.6.1-beta.1`、`packages/dsh-remote-ui` 记 `0.6.0`（实际都是 `0.6.3`）；含三个**已删除** workspace 的 `extraneous` 条目（`packages/protocol`、`packages/relay-core`、`packages/relay-free`）；`node_modules/ws` 的 `resolved` 是 `https://registry.npmmirror.com/ws/-/ws-8.21.3.tgz`（第三方镜像，非 `registry.npmjs.org`）。

文档 §8 计划"源码安装"，而 `ci.yml` 的安装步骤正是 `npm ci`（依赖 lockfile）——**锁文件与 manifest 脱节**是明确的源码安装风险，且文档 §6.2 把「依赖面极小：仅 ws」列为优点时，没提这个 ws 的来源是第三方镜像。

**未核实**：我没有执行 `npm ci`，无法断言它一定失败（npm 对 version 字段不一致的容忍度随版本而异）。

### L2. 行号引用精度

**准确**的引用（复核通过）：`dsh-bridge.mjs:109`（`UPSTREAM` 默认）、`:360`（`out.Host = up.host`）、`:718,:956`（`new WebSocket(...)` 只外连）、`:125`（ioreg）、`e2ee-client.mjs:723`（`mode: 0o600`）、`lib/index.js:29-30` 与 `dsh-bridge.mjs:107`（`n.risegao.cn` 默认中继）、`dsh-bridge.mjs:200,211`（`dev-<12hex>` / ed25519）。

**近似**：§4 的 `:239` 与 `:245` 落在 `dsh-bridge.mjs:238-246` 的**注释块**内（`STRIP_REQ_HEADERS` 实际定义在 `:246-253`）。属可接受的近似，不构成错误。

### L3. `engines.node` 三处不一致

根 `package.json`：`"node": ">=20"`；`packages/relay-router/package.json`：`">=22.13.0"`；两个插件包：无声明。而宿主 harness 是 `"^22.19.0 || >=24.0.0"`（`/Users/michaelyao/workspace/dsh/harness/package.json`）。

文档 §2 讲「依赖面很小」时未提 Node 版本要求；§8 计划自建 relay 时，其前置条件是 **Node ≥22.13**，文档未提。

---

## 文档遗漏的工程问题（汇总，按对决策的影响排序）

| # | 问题 | 位置 | 为什么影响决策 |
|---|---|---|---|
| **O1** | **两个插件包会被本仓 `link-plugins.sh` 同时挂载**（重复路由 + 重复设置页栏目） | `scripts/link-plugins.sh:89-105,163-170,172` + 两份 `cordis.patch.yml` | 直接决定 §8 的 submodule 落地方式必须做二选一，文档的"按子包候选处理"会踩坑 |
| **O2** | **别名包同步的盲区**：新增文件不被同步也不报错；发布工作流不跑 `--check`，可在未同步状态下打 tag 发布 | `scripts/sync-legacy-alias.mjs:28-41,49-60,85`；`.github/workflows/release-tarballs.yml:66-70` | §8 计划收 submodule 长期维护，双份代码的漂移是长期成本 |
| **O3** | **`dsh-setup.mjs`（791 行，安装器 / `bin`）全文未被提及**，而它是安装期最有特权、且 `execSync` 所在处 | 根 `package.json` `bin`；`dsh-setup.mjs:104,140-141,189-220,241-264` | §5 §8 讨论 npx 安装与"不执行自动安装"时，缺了这个对象 |
| **O4** | **质量闸门薄弱**（无类型 / 无 lint / 无构建；CI audit 恒不失败） | 根 `package.json` `scripts.check`；`.github/workflows/ci.yml` | 「JS 无类型靠什么保证」这个问题文档没回答，而这正是长期维护成本所在 |
| **O5** | **分块重组缓冲无界 + relay 单帧上限 256 MB**（认证前可达的资源耗尽面） | `packages/relay-router/src/index.mjs:172,231-259,244-254,699`；`clients/dsh-remote/dsh-bridge.mjs:304-326,980` | §7 推荐自建 relay，却没提示这个面 |
| **O6** | 插件包发布 tarball **不含 LICENSE**（PolyForm-Noncommercial 要求随附许可与 Required Notice） | 两个包的 `files` 白名单；`.github/workflows/release-tarballs.yml:66-70` | §9 整节讲许可义务，却漏了发布物本身 |
| **O7** | `@dsh-remote/client` 的 `main` 指向不存在的 `src/index.js` | `clients/dsh-remote/package.json` | 包工程缺陷，一旦按包名消费即失败 |
| **O8** | **CI 的插件清单是硬编码的**，收 submodule 后必须同步修改，否则 pin 不被校验 | `.github/workflows/verify.yaml:39`（tag-pin 数组）、`:27`（branch-pin 数组）、`.github/workflows/release.yaml:44` | 与 AGENTS.md 的硬约束「tag pin 以 verify.yaml / release.sh 比对校验」直接相关；文档 §8 只说了"作为 submodule 收进本仓，pin v0.6.3"，漏了这一步 |
| **O9** | `package-lock.json` 陈旧（记 `0.6.1-beta.1`）且 `ws` 钉在 npmmirror | `package-lock.json` | §8 的源码安装路径依赖 lockfile |

---

## 我无法核实的部分

诚实标注边界，以下均**未**核实：

1. **`npm ci` 是否真的失败** —— L1 的锁文件陈旧问题只有静态证据（版本字段与 workspace 集合不一致）。未执行安装。
2. **plugin-manager fail-closed 的实际用户可见后果**（§5）—— 结论严格限于 `version.ts` 的代码语义；未端到端跑过 dsh-web plugin-manager 对 dsh-remote 的判定，也不确定用户的实际安装路径是否经过它（本仓同时存在 `dsh-market`，其判定为"通过"）。
3. **分块缓冲 DoS 的实际可利用性**（§10）—— 未构造 PoC、未实测。且我**没有**逐行追完 relay 的 tunnel 握手鉴权流程，因此"认证前可达"这一判断基于 `makeFrameReceiver` 的挂载位置（`:699`），未确认其前面是否还有其它屏障。
4. **`sh(cmd)` 的 10 个 `lib/index.js` 调用点是否存在可达的命令注入** —— 我逐条看过调用点（`:339,353,369,376,515,552-556,606,672-682,802`），参数以 `launchctl`/`systemctl`/`pgrep`/`ps` 常量与内部路径变量为主，**未发现外部可控输入直接拼入**，但这是"未发现"，不是"证明不存在"。
5. **v1.0.0 的安全论断** —— 不属于本次评审范围（本次聚焦代码质量/包工程/生态），只核对了 §「版本更正说明」的两条事实性论断（见下）。
6. **CI 的实际执行历史** —— 未联网，未查 GitHub Actions 运行记录；§7.3「发布工作流不跑 check」的结论仅来自 workflow 文件内容。

**已核实为真的两条历史论断**（§「版本更正说明」，`docs/dsh-remote.md:12`）：
- v1.0.0「扁平 `lib/`+`bin/`，零依赖，约 1000 行」→ **准确**：`bin/dsh-remote.js`(86) + `lib/{auth,config,proxy,server}.js`(135+122+229+426) = **998 行**；`package.json` 的 `dependencies` 为 `{}`。
- v1.0.0「**不是 DSH 插件**」→ **准确**：其 `package.json` 无 `dsh` 字段，无 `cordis.patch.yml`；且 `description` 自述 `loopback masquerading`，与文档 §4「v1.0.0 同源」的判断一致。

---

## 附：对文档的最小修改清单

若只做最小改动，建议按此优先级：

1. **§6.2 的 `execSync` 行**（`:170`）—— 事实错误，且列在「已核实」栏，必须改。
2. **§6.1 的「约 9100 行」**（`:163`）—— 换成构成拆分表，并补上测试 7,376 行与 `dsh-setup.mjs` 791 行。
3. **§6.2 R7 与 §3 的「预构建」措辞**（`:174,:188,:89,:24`）—— 改为「无构建管线，手写 bundle 即源码」。
4. **§2 `:78` 与 §6.2 `:176` 的 `engines.dsh` 结论** —— 改为按消费者分情况的条件式结论。
5. **§8 新增两条**：O1（双份会被同时挂载，必须二选一）、O8（verify.yaml / release.yaml 的硬编码清单需同步修改）。
6. **新增一节「包工程与双份代码维护风险」**：覆盖 O2、O6、O7、O4。
