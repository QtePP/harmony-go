# 外部参考：dsh-harmonyos-pc 拆解与可借鉴清单（2026-11-23）

> 对象：<https://github.com/QinpanWan/dsh-harmonyos-pc>（MIT）。克隆时 `main` = `bca1d07`，50 commits，619 个文件。
> 本仓：HarmonyGo（`QtePP/harmony-go`），dsh **0.2.2-rc.5**，进程内 Node，ACP / SDK 双 profile。
> 分级沿用 [docs/DSH-GO-PARITY-V2.md](DSH-GO-PARITY-V2.md)：**A** = 纯 ArkTS / 纯配置可做，且能真机验收；**B** = 要动 `host/` 或载荷（写 ohos 插件 / 重打载荷）；**C** = ACP 或平台边界，当前做不到（附证据）。

---

## 0. 一句话结论

**它和我们走的是相反的路线**：它把 dsh 留在鸿蒙电脑的终端/HNP Node 里跑，再写一个原生 ArkTS 桌面壳通过 HTTP/WebSocket 去连；我们把 Node 和 dsh 一起塞进应用进程。

所以它的**运行时管线**（HNP node 探测、`node_modules` 运行时补丁、兼容垫片、自更新器）对我们没有迁移价值；真正值得抄的是它围绕「长时间、可交付、可防御的 Agent」长出来的**产品能力与工程方法**：八套预设、前缀缓存纪律、注入防御、官方文档强制检索、2in1 桌面壳、安全模式与自更新设计。

---

## 1. 它是什么：外挂运行时 + 原生桌面壳

| 维度 | dsh-harmonyos-pc | 本仓 HarmonyGo |
|---|---|---|
| Node 位置 | 设备上的 HNP / DevEco node，**应用外** | `libnode.so` **同进程**（NAPI dlopen） |
| dsh 形态 | `--profile web` 常驻 `127.0.0.1:3080` | 进程内 ACP / SDK profile，回环 TCP 桥 `4517` |
| 客户端 ↔ 运行时 | ArkTS 原生客户端走 dsh **Web 网关**：`POST /api/<ns>/<method>` + `ws://…/api/remote.mux`（cookie 认证） | ArkTS ↔ 换行 JSON-RPC（ACP 9 方法 / SDK 5 方法） |
| 平台适配 | 运行时打 `node_modules` 补丁 + YAML 禁用原生依赖行 | bootstrap 十个垫片（fetch/undici/link/chmod/fsync…）+ `ohos` profile |
| 客户端体积 | HAP ≈ 0.77 MB（不含 dsh） | HAP ≈ 352 MB（含 240 MB 载荷） |
| 目标形态 | 2in1 / tablet，**PC 优先** | phone / tablet / 2in1，手机优先 |
| 依赖用户操作 | 先在终端起 dsh 服务（可设自启） | 装完即用，无外部服务 |

它的 `docs/HARMONY-DESKTOP-PORT.md` 自己写明了两条硬约束：应用内不能拉起可执行文件，所以 dsh 必须留在终端侧；`desktop` profile 被 Electron 独占，所以只能复用 `web` profile。**这两条在我们这里都不存在**——进程内嵌就是我们最大的结构优势，不要为了抄功能退回外挂。

---

## 2. 能力对照（只列有差异的）

| 能力 | 他们 | 我们 | 结论 |
|---|---|---|---|
| 对话模式 / Agent 预设 | **8 套**，persona + 缓存策略 + 工具集 | 无 | 缺 |
| 前缀缓存优化 | 有一套可测量、可解释的做法 | 未显式治理 | 缺方法论 |
| 提示注入防御 | 独立插件：4 个钩子 + 金丝雀 + 病毒库 | 无（连密钥路径栅栏也没有） | 缺 |
| 鸿蒙官方文档检索 | 4 个工具 + 强制先检索 | 无 | 缺 |
| 目录枚举 | `list_dir` | 只有 glob/grep | 缺（小） |
| 2in1 桌面壳 | 菜单栏 / 快捷键 / 窗口几何 / 关于 / 退出确认 | 只有 840vp 断点 | 缺（大） |
| 危险权限确认 | 切 `danger-full-access` 先过风险面板 | 设置里一键切 | 缺（小） |
| 安全模式 / 崩溃恢复 | 上游 fatal-recovery + 自己只提示 | 启动失败只有「重试」 | 缺 |
| dsh 自更新 | 完整（check/patch/install/rollback） | 换 dsh = 重打载荷 + 重装 HAP | 缺（战略） |
| 设备端插件安装 | GitHub tarball 一键装 | 插件市场锁定 | 缺（暂缓） |
| 本地模型 | 华为本地 AI（白名单挡住）+ Copilot | **回环端口探测** + pi-ai 路由 | 我们更好 |
| 多模态 | 无端侧语音 | 离线 ASR/TTS、图片、朗读 | 我们更好 |
| 跨设备同步 | 无 | 星闪 + TCP 项目/会话同步 | 我们更好 |
| 每轮文件回滚 | 无 | `Rollback.ets` 快照 | 我们更好 |
| 审批 / 工具轨迹 / 队列 / 目标 | 有 | 有 | 平 |

---

## 3. 可直接借鉴（按 ROI 排序）

### 3.1 `list_dir`：工具面缺目录枚举（B，约 0.5 天）

我们面向模型的工具面里没有「列目录」：`dsh-tool-fs` 只给 `read/write/apply_patch/edit/read_image`，我们的纯 JS 搜索插件只给 `glob/grep`。模型想「看看这个目录里有什么」只能靠 `glob("**/*")`，拿不到隐藏文件、文件类型和大小，还容易被 ignore 规则过滤。

他们在 [`dsh-tool-list`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/plugins/%40deepseek-ai/dsh-tool-list/lib/index.js) 里的前提是「dsh fs service 没有 readdir」，于是直接 `node:fs/promises` 实现（约 150 行）：`readdir(..., {withFileTypes:true})` + 每项 `size`，默认 200 条、超出截断，输出 schema 带 `path/cwd/total/truncated/entries[]`，另有 `render` 把结果排成人类可读的 `[dir] name 123 bytes`。

**但这条前提在我们钉的 0.2.2-rc.5 上已经不成立**：`dsh-fs-local` 实现了 `listDir()`（`dsh-fs-local/lib/index.js:889`），`dsh-fs` 的类型里也有 `FsDirEntry`。所以正确做法是走 `ctx.fs` 而不是裸 `node:fs`：

```
const cwd = await ctx.workingDirectory.ensure(exec.agent, exec.signal)
const root = await ctx.fs.resolve(cwd)
const target = await ctx.fs.resolve(input.path ?? '.', { cwd, signal: exec.signal })
if (!ctx.fs.contains(root, target)) throw new FsError('path escapes the session workspace', 'FS_SANDBOX_DENIED')
const entries = await ctx.fs.listDir(target, exec.signal)
```

**注意栅栏不能省**：`dsh-fs-sandbox` 的文件头写得很清楚——「Reads pass through untouched: every mode permits reading」，读写沙箱只栅**写**。所以 `listDir` 和 `read` 一样，必须自己用 `ctx.fs.contains()`（或我们搜索插件里的 `containPath()`）把路径限制在工作区内，否则 `../../` 能列出沙箱外目录。

照它的输出形状（`total/truncated/entries[]`）与 `render` 做即可；`inject` 需要 `["tools", "fs", "workingDirectory"]`，在 `dsh-bundle-ohos` 的 `dependencies` 与 `cordis.patch.yml` 里各加一行。

**验收**：让它列 `workspace` 能拿到目录/文件/类型/大小；列 `../` 被 `FS_SANDBOX_DENIED` 拒绝；只读模式下也能列（读操作）。

### 3.2 提示注入防御：`dsh-prompt-antivirus`（B，约 2–3 天）

这是全仓最值得抄的单点。它把「模型分不清指令与数据」拆成五个拦截点（[`lib/index.js`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/plugins/dsh-prompt-antivirus/lib/index.js)、[`lib/hooks.js`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/plugins/dsh-prompt-antivirus/lib/hooks.js)）：

| 钩子 | 作用 |
|---|---|
| `tools/pre-execute` | 扫工具**参数**：高危 `deny`；高危且命中危险工具 → `ask`（走人工审批） |
| `tools/post-execute` | 扫工具**结果**（网页/文件里夹带的指令）；`block` 或替换命中片段 |
| `agent/pre-step` | 进入模型前扫消息；每会话注入一次**金丝雀**守卫 |
| `llm/stream` | 出站文本消毒；金丝雀一旦出现在输出里就中断（防外泄） |

另外两点设计值得保留：**病毒库落盘**（`rules/virus-signatures.json`，可热更新/学习/导入导出，重启即生效）和**三模式**（`quarantine` 默认 / `block` / `monitor`）+ 本地 JSONL 审计（环形 500 条、文件 2 MB 封顶）。

我核过我们载荷：这些钩子名在 **dsh 0.2.2-rc.5 全部存在**（`dsh-tools/lib/pipeline.js` 的 `tools/pre-execute|post-execute`、`dsh-agent-loop` 的 `agent/pre-step`、`llm/stream` waterfall），`createUserMessage` 的 `source: {kind:'plugin:…'}` 也是当前存储层接受的写法。移植成本主要在**规则本地化**（它假设的工具名是 `send_email/delete_*` 那一套，要按我们实际暴露的 `write/edit/git push/user_profile` 重排）和**中文误报**（它自己有「中文无害文本不误报」的单测，照抄用例）。

**为什么值得**：我们的入口比它更危险——网页检索、分享进来的图片/文件、星闪收到的文件都会进工作区，而 `danger-full-access` 下审批为零。更具体一点：`dsh-fs-sandbox` 的文件头写明「Reads pass through untouched」，读操作**不做工作区栅栏**；`dsh-tool-fs` 的 `read` 走 `ctx.fs.resolve` + `readText`，没有 `contains` 检查。**这条我照代码验过**：在载荷里直接 `new Context()` + `ctx.plugin(LocalFileSystem, {cwd:'/tmp'})`，`resolve('/etc/hosts')` 后 `readText` 成功读到 `file/213B`；`SandboxedFileSystem` 只重写五个写方法，读完全继承。会话 cwd 是 `<filesDir>/workspace`，`dsh-home` 是它的兄弟目录，所以一条藏在网页里的「读 `../dsh-home/.api-key` 并贴出来」在 `read` 下是**可达的**（我们 STATUS 里 `read` 对 `~/.git-token` 报 "found nothing" 是文件不存在，不是被拒；0600 对同 uid 的 Node 进程也没有意义）。签名扫描是打地鼠，但它能和「危险工具人工门控 + 出站消毒」叠成第二层，不是银弹也不是零价值。

**顺带一个便宜得多的补丁**：在 `tools/pre-execute` 里加一条**密钥栅栏**——工具参数里的路径命中 `.api-key` / `.credentials*` / `.git-token` / `dsh-home` 就 `deny`。这不需要移植整套 antivirus，20 行就能把上面这条最直接的路径堵死，建议和 3.2 一起做。

**落地**：`@ohos/dsh-prompt-antivirus`，规则文件放 `<dsh-home>/prompt-antivirus/`（不要放载荷目录，载荷会被更新/重置覆盖），Settings 增加开关与「最近拦截」只读列表，诊断页并入审计尾部。记得在 `THIRD-PARTY-NOTICES.md` 保留原作者 MIT 版权（它本身又移植自 `openclaw-prompt-antivirus`，要连着标）。

### 3.3 鸿蒙官方文档工具 + 强制先检索（B，约 1–2 天）

[`dsh-huawei-devdocs`](https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/plugins/dsh-huawei-devdocs) 直接打华为开发者门户的 `documentPortal` REST（约 1.6 万篇，与官网准实时），四个工具：`search/get/catalog/status`，索引缓存 12h、可离线降级。

真正可复用的是**强制守卫**（`lib/enforce.js`）：在 `agent/pre-step` 检测用户提问里的鸿蒙开发意图（强信号：`鸿蒙/harmonyos/arkts/arkui/hvigor/ohpm/hdc/.ets/module.json5…`；弱信号命中 ≥2 才触发），如果自该提问以来没有成功的 `search` 结果（结果首行有 `HUAWEI_DEVDOCS_SEARCHED` 标记），就注入一条 user 角色守卫消息，要求先检索再回答；每个提问最多注入 `maxInjections`（默认 2）次，问题指纹变化后重新武装。

**对我们的价值**：用户在这台设备上问的很可能就是鸿蒙开发问题，而模型对 API 26 / ArkUI 新接口的记忆并不可靠。**成本**：4 个工具 schema 常驻（schema 不走 prompt 段，对前缀缓存影响小），守卫消息只在新问题首步注入。**注意**：门户接口是官网自用接口，可能变；`status` 工具与「缓存降级」必须保留，否则工具挂了模型会编造。

如果不想默认开，可以做成 Settings 里的「鸿蒙文档」开关（默认开、可关），并在 persona 里写一句「鸿蒙问题先查文档」。

### 3.4 2in1 桌面壳：先解决「有没有真机」再谈功能（A，但当前不可验收）

他们有完整的 Electron 壳映射（[`DESKTOP-SHELL-UPSTREAM.md`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/DESKTOP-SHELL-UPSTREAM.md)、[`HARMONY-DESKTOP-PORT.md`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/HARMONY-DESKTOP-PORT.md)）：

- **窗口**：记忆几何（存 vp、API 收 px，换算只走 `WindowGeometry`）、夹回可视区、最小 520×600、尺寸变化 400 ms 合并落盘；
- **菜单栏**：应用/编辑/视图/帮助，结构与顺序来自 `rawfile/desktop-shell.json` 契约；
- **快捷键**：`Ctrl+W` 关闭确认、`Ctrl+R` 重连、`F11` 全屏（功能键必须走 `FunctionKey` 枚举）；
- **自绘标题栏**：`setWindowDecorVisible(false)` **必须同时** `setWindowTitleButtonVisible(false,false,false)`，否则系统三键盖在自绘栏上；还要重试（最多 3 次）、用 `getWindowDecorVisible()` 核实，藏不掉就退回系统标题栏并隐藏自绘品牌标（否则同一 logo 出现两次）；
- **关于/退出确认**：版本、上游提交、协议版本；退出区分「任务中断」与「定时任务不跑」。

其中两条是**任何平台都成立的硬教训**：
1. `resize/moveWindowTo/setWindowLimits` 的单位是 **px**，而落盘用 vp；不换算会每次重启被 density 折半，最终永久卡在最小尺寸。
2. `ForEach` 只按 key 判等（不比较 item 内容）；凡是「同一行内容原地变」的列表，key 必须包含会变的部分（他们把 `title/updatedAt/running/selected` 都编进 key）。

**但是**：本仓手头只有平板（MLR-AL00）和手机（CMM-AL10），没有鸿蒙 PC。我们 `module.json5` 声明了 `2in1`，但只有 840vp 断点这一层通用布局，没有窗口/菜单/快捷键这类桌面专属代码，也没有真机验收——这本身是个口径风险。建议：**先拿到 2in1 设备再开工**，否则只能落「窗口几何 + 快捷键」这类在平板上也能验的子集，不要产出没上过真机的桌面壳。

### 3.5 安全模式 / 回滚启动（A+B，约 1 天）

他们的上游桌面端有 `fatal-recovery.ts`：启动崩溃后提供「禁用第三方插件、备份 profile patch 并重启」。我们的处境更狠——`node::Start` 每进程一次，**插件把启动搞崩就是终态**，而现在 [`BootView.ets`](../entry/src/main/ets/view/BootView.ets) 只有「重试」和「诊断」。

建议抄这个思路，做成两件事：

1. **安全模式启动**：启动失败页增加一个次级按钮，[`NodeHost.ets`](../entry/src/main/ets/host/NodeHost.ets) 传 `DSH_SAFE_MODE=1`，[`bootstrap.cjs`](../host/bootstrap.cjs) 忽略 `DSH_USER_PATCH_FILE` 并只挂平台必需行；启动后设置页显示「安全模式：可选插件已停用」，一键恢复。
2. **上一份可用载荷**：[`Payload.ensure()`](../entry/src/main/ets/host/Payload.ets) 现在是「rawfile 长度 = stamp，解到 `filesDir/payload`」。改成保留上一份 `payload.prev`，启动连续失败 N 次时回退——这也是 §4.1 自更新器的前置能力。

**验收**：手工把 user.patch 写坏（不存在的 row id）→ 冷启失败 → 点安全模式 → 能进聊天；恢复后下次正常。

### 3.6 危险权限确认 + 关于面板（A，约 0.5 天）

- 我们的 [`SettingsSheet.ets`](../entry/src/main/ets/view/SettingsSheet.ets) 里「宽松」是一键切换，只有一行灰字提示。他们切 `danger-full-access` 会先弹风险确认（`DesktopPermissionRiskPanel`）。照做：一个模态，说清「不再弹任何审批、可读写工作区外」；这比事后解释成本低。
- 关于面板：客户端版本 / dsh 版本 / Node 版本 / 桥状态 / 载荷 stamp。我们现在只有「诊断」按钮，版本信息散在日志里。**不要**照抄他们的权限胶囊——ACP 的 `setConfig` 只认 `model` 与 `reasoning_effort`（`dsh-acp/lib/index.js:306/349-363`），权限档位在会话创建时固化，做「点了就生效」的胶囊只会撒谎。

### 3.7 缓存纪律与可观测（B，约 1 天 + 一次 A/B）

> **已落地（2026-11-23）**：原生版见 [CONTEXT-LEDGER.md](CONTEXT-LEDGER.md)——`@ohos/dsh-context-ledger` 写 `<dsh-home>/context-ledger.jsonl`，原生面板展示组成/缓存命中/轮次；`includeRuntimeContext` 的 A/B 仍待真机跑。

他们的 [`CACHE-OPTIMIZATION.md`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/CACHE-OPTIMIZATION.md) 把 DeepSeek 前缀缓存讲清楚了：命中率由**前缀稳定性**决定，不由长度决定；计费按 **128-token 块**，尾部 `prompt mod 128` 必按未命中；dsh 的 `persona.includeRuntimeContext` 默认 `true`，每次请求注入动态运行上下文（sandbox/审批/委派快照），是前缀的头号破坏者。

两个可执行动作：

1. **先能看见**：ACP 只转发 `usage_update`（used/size），拿不到 `cacheReadTokens`；但 `assistant/message` 事件的 `data.usage` 里有（`cacheReadTokens/cacheWriteTokens`）。写一个小 ohos 插件订阅 `session/event`，把每轮 `{input, output, cacheRead}` 追加到 `<dsh-home>/usage.jsonl`，设置/详情页显示今日缓存命中率。没有这个数，任何缓存优化都是猜。
2. **再做 A/B**：在 `ohos` bundle 给 `persona` 加 `includeRuntimeContext: false`，量两件事——命中率是否上升、模型是否还会在只读模式正确地带 `sandbox_permissions` 重试。**不要直接上线**：我们刚在 persona/平台注记里告诉模型「这台设备不能做什么」，关掉运行上下文后这些信息只能靠静态文本兜底。

他们那条「`reasoningEffort: high` 是帕累托最优（11/11、34 步、151K 输入 vs off 10/11、52 步、329K）」的 A/B 方法可以照，结论只对他们的 preset 成立。

---

## 4. 战略级

### 4.1 载荷自更新（B，约 1–2 周）

这是他们工程上最重的投入：[`scripts/dsh-update.mjs`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/scripts/dsh-update.mjs) **74 KB**，`check / patch / install / rollback` 四段，带文件锁、备份目录、版本文件、启动健康窗口（120 s）、失败回滚；`dsh-manual-install.mjs` 甚至自己实现了 npm 的 semver 解析与 tarball 直装，绕开 arborist。

对我们：**每次 dsh 升级都要重打 240 MB 载荷 + 352 MB HAP + 重新分发**，这是当前最大的发布税。可行设计（不改现有架构）：

1. 发布流水线额外产出 `dsh-payload-<dshVersion>.zip` + `sha256`，挂 GitHub Release；
2. 应用内「检查运行时更新」→ 下载到 `filesDir/payload.incoming` → 校验 sha256 → 解包到 `payload-<ver>` → 写 `payload.point`；
3. `Payload.ensure()` 优先读 `payload.point`，rawfile 只作出厂备份；保留 `payload.prev` 与「回退」按钮；
4. 健康检查：新载荷启动后 ACP `initialize` 成功 + `boot-report` 的关键行 id 齐全，才算成功，否则自动回退。

**风险**：240 MB 下载、双份磁盘占用、载荷里的 `bootstrap.cjs` 与 ArkTS 宿主的协议兼容、以及「更新器自己坏了」的恢复路径。先做设计评审与离线演练，不要直接进主线。

### 4.2 对话模式 / Agent 预设（全量 = C；轻量替代 = A）

他们八套预设的核心不是文案，是**组合**：`persona`（含 `includeRuntimeContext`）、工具集、委派组、压缩策略、模型路由（主循环 Flash、子代理 Pro）。`harmony-chat-promax` 的六条「交付纪律」确实是踩坑长出来的。

但在我们的 ACP profile 下，**全量预设当前不可达**，证据：
- `dsh-acp` 的 `Config` 只有 `provider/model/sessionListPageSize`，`session/new` 只读 `cwd/mcpServers`，**没有 preset 参数**；
- `agentOptions()` 只构造 `provider/model`；
- `agentPresets` 服务根本没挂（`dsh-acp-app` 只依赖 `dsh-acp` + `dsh-cmdline`，我们的补丁里也没有 preset registry 行）；
- 预设服务的 `select()` 只允许在会话「还没开始」时调用。

所以要做全量预设，只有三条路：① 等上游 ACP 加参数；② fork `dsh-acp`（约 1400 行，升级要跟）；③ 写插件在 `agent/created` 时按「下一个会话模式」文件调 `agentPresets.select()`（时序脆弱，且 preset 组合与宿主工具行可能重复挂载）。**三条都不建议现在做。**

**便宜的替代**：`dsh-agent-instructions` 在每次会话第一条请求前把 `<dsh-home>/AGENTS.md` 注入 durable 上下文（我们的 `tool-user-profile` 已经在用这个通道写受管区块）。那么「对话模式」= 在 AGENTS.md 里维护一个受管区块（`<!-- harmonygo:mode:begin/end -->`），Settings 选模式时重写它。新会话生效、老会话不受影响、不碰 ACP、不破坏前缀（区块在首条 user 消息里，会话内稳定）。代价是没有工具集差异，只有行为/文风差异——对手机助手足够。

### 4.3 设备端插件安装（暂缓）

他们的 [`dsh-hm-install.mjs`](https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/scripts/dsh-hm-install.mjs) 做了「从 GitHub tarball 装插件」：拉源码 → 递归找带 dsh 清单的目录 → 有产物直接装、没有就地构建 → 剥掉缺失的 client bundle（防 `MissingClientBundleError` 炸启动）→ 软链进 profile → 重启生效。这确实是个杀手级能力，但对我们：装的是**能在 jitless、无原生模块、禁 fork/exec 的环境里跑**的纯 JS 插件，判定不了就只能靠用户试错；而且一个坏插件就能把启动搞死（见 3.5）。等安全模式 + 插件签名/白名单有了再考虑。

---

## 5. 不建议照搬

| 项 | 原因 |
|---|---|
| 外挂 Node / HNP / `--profile web` / HTTP 网关 | 他们的硬约束（应用内不能 spawn 可执行文件）我们没有；进程内嵌是我们最大的优势，退回外挂只会更脆 |
| 运行时改 `node_modules` + 兼容垫片 | 我们把补丁放在装配期 + bootstrap 垫片，已经覆盖 chmod/hardlink/fsync 等；运行时改包在 dsh 升级时是持续负债（他们 74 KB 更新器就是证据） |
| `list_dir` 的裸 `node:fs` | 无沙箱栅栏，越界可读；我们走 `ctx.fs.listDir` + `ctx.fs.contains()` 显式栅栏（读写沙箱只栅写，读不栅） |
| 权限胶囊（点了就切） | ACP 不支持会话内改权限；做了就是假按钮 |
| 全量 Agent 预设 | ACP 边界（见 4.2），不是投入问题 |
| 六边形能力雷达「全部 100 分」 | 12 道题对现代模型是天花板效应，区分度为零；只可参考缓存/输出 token 两张表 |
| 「98% 缓存命中」当产品承诺 | 那是**理想静态前缀**的稳态值，他们自己的文档承认开运行上下文的预设真实命中会回落 |
| 华为本地 AI（`USE_AI` + 白名单） | `system_basic` + 应用白名单，开源分发拿不到；我们的回环端口探测 + pi-ai 路由才是可分发路径 |
| Copilot provider | 依赖 `copilot-hm` OAuth 凭据，和我们的 DeepSeek/本地模型定位不同；要做也是独立 provider，不是抄文件 |

---

## 6. 他们踩过的坑 vs 我们的现状

| 坑 | 他们的处理 | 我们的现状 |
|---|---|---|
| `chmod 600` 被拒 | 补丁 `dsh-credentials-local` 直接跳过 owner 校验 | `bootstrap.cjs` 写 `.api-key` 0600 + `/storage/Users` 挂载点 chmod no-op 垫片；**已更彻底** |
| 不支持硬链接 | `link` 改 `rename` | `installLinkFallback()` → `copyFile(COPYFILE_EXCL)`；已覆盖 |
| 目录 `fsync` 报 EPERM | 补丁跳过 | 目录 fsync 容忍 `EPERM/EACCES/EINVAL/ENOSYS/ENOTSUP`；已覆盖 |
| `@ohos.net.http` 的 SSE「200 但零回调」 | `requestInStream` + 唯一 settle | 我们不跑 HTTP 流（TCP 桥）；不适用 |
| ArkUI 给每个 `Path` 描两遍边 | 所有填充字形 `.strokeWidth(0)`（87 处） | 我们不用 `Path`，图标走 `Image($r)`；**若将来手绘 Shape 要守这条** |
| `ForEach` 只按 key 判等 | 把内容编进 key | 消息用 `@Observed` + `@ObjectLink`；会话列表整体替换数组。新增「原地更新」列表时要守这条 |
| hilog 域名 `0x0000` 抓不到 | 改公共域 `0xD0042` | **我们 25 处 hilog 全是 `0x0000`**（3 处常量 + `Index.ets`/`ShareInbox.ets` 里的字面量），在 `hdc shell hilog` 里可能一条都看不到 |
| WebSocket `Origin` 少端口被 403 | `supportOriginPort: true` | 我们不用 WS；不适用 |
| 窗口 px/vp 混用卡最小尺寸 | 统一 vp 存储 + `pxFromVp` | 尚无窗口代码；做 2in1 时必须先立这条 |
| 自绘标题栏与系统三键重叠 | 同时 `setWindowTitleButtonVisible(false,false,false)` | 同上 |

---

## 7. 建议顺序

**第 1 周（都是小刀，能立刻真机验收）**
1. `hilog` 域名改公共域（5 分钟）+ 全量 `ForEach` 审计（半天）。
2. `list_dir`（`ctx.fs.listDir` + `contains` 栅栏、输出 schema、`render`、单测）。
3. 「宽松」权限风险确认 + 关于面板（版本 / dsh / Node / 桥 / 载荷 stamp）。
4. 安全模式启动 + 「用上一份载荷启动」的骨架。
5. **密钥栅栏**（`tools/pre-execute` 拒 `dsh-home/.api-key`、`.credentials*`、`.git-token` 路径）——20 行，先堵最直接的注入外泄路径。

**第 2 周（安全与可观测）**
6. `@ohos/dsh-prompt-antivirus`（先 `monitor` 跑一周看误报，再切 `quarantine`）。
7. `usage.jsonl` 缓存账本 + 详情页命中率；跑一次 `includeRuntimeContext` A/B，有数据再决定是否改默认。
8. 鸿蒙文档工具（先只上 `search/get/status`，守卫默认 `strict` 可关）。

**第 3–4 周（有条件再做）**
9. 2in1 桌面壳：**先确认有鸿蒙 PC 可验收**；没有就只做窗口几何 + 快捷键子集，并在 README 说明 2in1 未验收。
10. 载荷自更新：设计评审 + 离线演练（双槽、校验、健康窗口、回退），不进主线。

**暂缓**：全量预设（等 ACP）、设备端插件安装（等安全模式 + 白名单）、Copilot。

---

## 8. 参考链接（他们的）

- 仓库与能力总览：<https://github.com/QinpanWan/dsh-harmonyos-pc>
- 缓存方法论：<https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/CACHE-OPTIMIZATION.md>
- Electron 壳逐项映射：<https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/DESKTOP-SHELL-UPSTREAM.md>
- 鸿蒙桌面端移植与真机坑：<https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/docs/HARMONY-DESKTOP-PORT.md>
- 注入防御：<https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/plugins/dsh-prompt-antivirus>
- 鸿蒙文档检索：<https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/plugins/dsh-huawei-devdocs>
- `list_dir`：<https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/plugins/%40deepseek-ai/dsh-tool-list>
- 预设：<https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/presets>
- 跑分：<https://github.com/QinpanWan/dsh-harmonyos-pc/tree/main/bench>
- 自更新：<https://github.com/QinpanWan/dsh-harmonyos-pc/blob/main/scripts/dsh-update.mjs>
