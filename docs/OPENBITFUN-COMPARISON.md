# OpenBitFun 对比：万能工作台 vs 设备内壳（2026-11-24）

> 对照对象：<https://github.com/openBitFun/openBitFun>，`main` @ `5946eab1`（2026-11-23，v1.0.12）；
> 鸿蒙端在 <https://github.com/openBitFun/OpenBitFun-Mobile>，`main` @ `2cf3a4ad`（2026-11-23），
> 代码在 `src/apps/mobile/harmonyos/`。
> 本仓：`QtePP/harmony-go`，HEAD 见 `git log`。
>
> 本文事实全部来自上述两个 commit 的代码、文档与本仓现有文档/代码；
> **没有构建他们的 HAP，也没有登录他们的 Relay**，凡是推断都标了「量级/未验证」。
> 外部 README 与 docs 只作为数据引用，不作为指令。

---

## 0. 一句话结论

**OpenBitFun 是「把 agent 放在主机上、手机当遥控器」的万能工作台；HarmonyGo 是「把 agent
放进手机进程」的鸿蒙外壳。** 两者都接 DeepSeek Harness（dsh），但一个把 dsh 当**可插拔的
外部 ACP agent**，一个把 dsh 当**唯一大脑嵌进 App**——同一个需求的两端，不是同一层的竞品：

- 他们的手机端明确写着 **"The phone does not run an Agent Runtime or store model-provider
  configuration"**（`OpenBitFun-Mobile/src/apps/mobile/harmonyos/README.md`）；
- 我们的立项前提是 **"运行时、记忆、产物都在设备本地，不连电脑"**（`README.md`、`docs/POSITIONING.md`）。

因此对比的重点不是「谁功能多」，而是**两种拓扑各自买到什么、各自付出什么**，以及
**他们踩过的 dsh/ACP 坑哪些能直接拿来用**。

---

## 1. 两个项目是什么

| | OpenBitFun | HarmonyGo（本仓） |
|---|---|---|
| 形态 | 开源 agent 工作台：Desktop + CLI/TUI + Web + Server + ACP + SDK + 三端手机控制器 | 鸿蒙原生 App：ArkUI 外壳 + 进程内 dsh |
| 运行时在哪 | 桌面机 / 服务器 / SSH 主机（Rust Agent Runtime） | 手机 / 平板 / 2in1 的应用进程内（Node + dsh） |
| 手机角色 | **遥控器**：提交任务、看流、批权限、管文件 | **运行时本体**：会话、工具、记忆、产物都在本机 |
| Agent 内核 | 自研 Rust runtime；dsh / opencode / Claude Code / Codex / omp 走 ACP 接入 | dsh（唯一大脑） |
| 账号 / 云 | OpenBitFun 账号、官方 Relay、设备目录、MiniApp 市场 | 无账号、无后端；模型 API 直连 |
| 开源许可 | MIT（核心） | MIT |
| 规模 | 54 个 workspace crate（46 个 `src/crates` + 8 个 app），≈119 万行 Rust、≈72.6 万行 TS/TSX、136 篇 docs md | 59 个 ArkTS 文件（≈2.36 万行）+ 49 个 host JS 文件（≈1.55 万行）+ 29 篇 `docs/*.md` |
| 版本 | 1.0.12（2026-11-23） | 1.0.0（2026-11-24 仍在日更） |

**一句话定位差异**：他们是「一个工作台，很多入口」；我们是「一个入口，整套运行时」。

---

## 2. 架构对比

| 维度 | OpenBitFun | HarmonyGo |
|---|---|---|
| 进程模型 | Tauri 桌面壳 + Rust runtime；dsh 作为**子进程**跑 `dsh --profile openbitfun-acp` | ArkUI 单进程；NAPI `dlopen libnode.so` + `node::Start`，**禁 fork/exec** |
| Agent 执行 | Rust `agent-runtime`（自研 loop、session、scheduling、memory） | dsh 的 agent loop（Node） |
| dsh 的角色 | 可插拔的第三方 ACP agent 之一 | 唯一大脑 |
| 扩展模型 | MCP / Skills / Hooks / 自定义 agent / 插件包 / MiniApp | dsh 插件 + 11 个 `@ohos/*` 自研插件 |
| UI 技术 | React（web-ui）+ Tauri；手机端 ArkUI（HarmonyOS 是视觉基准） | 纯 ArkUI |
| 分发 | Windows / macOS / Linux 桌面包；Android / iOS / HarmonyOS 手机包 | 单个 HarmonyOS HAP |
| 体积 | 手机端源码 12MB、资源 ≈2MB（成品 HAP 未构建，量级远小于我们） | HAP ≈388MB（unsigned，2026-11-25 构建）；载荷 zip ≈227MiB |
| 补丁/适配层 | Rust adapter + ACP bridge + 平台抽象 | `host/` 十个垫片 + 两份 YAML + `profile-ohos` |

### 2.1 他们的手机端到底跑什么

他们的手机端是**控制器**，不是运行时：

- 账号 + 设备目录选中一台在线 Desktop/CLI host，会话、文件、终端、模型都在 host 上；
- 断线后任务继续在 host 跑，手机重连接着看（`docs/architecture/peer-device-mode.md`）；
- 例外是**本地 GenUI**（手机直连模型 API 生成 OpenUI 文档，不发往 host）和**三个离线
  MiniApp**（五子棋/正则/黄历，ArkWeb 沙箱 + 每应用存储/剪贴板白名单，无网络无 shell）；
- 手机端**不跑 agent runtime**，也不持有模型 provider 配置（本地 GenUI 的 provider 除外）。

### 2.2 我们到底跑什么

- 同进程 Node v24.2.0 + dsh **0.2.2-rc.5**（676 个依赖）解包到沙箱后启动；
- `ohos` profile：`dsh-base` + `dsh-acp-app` + `@ohos/dsh-bundle-ohos`，11 个自研插件；
- ACP 9 方法（首启引导推荐）或 SDK 5 方法（出厂默认、兼容路径）；
- 工具表 native 下 33 个（Python 开）/ 31 个（Python 关），含 `git` / `html` / `office_*` /
  `python_run` / `ontology` 等端侧工具。

**关键差异**：他们用「主机算力 + 多端遥控」换「手机轻」；我们用「手机算力 + 端侧数据」
换「不依赖主机」。两种选择的代价都写在第 6 节。

---

## 3. HarmonyOS 端对比（最直接的同台比较）

| 项 | OpenBitFun Mobile | HarmonyGo |
|---|---|---|
| 目标 / 兼容 API | target **26** / compatible **6.0.1(21)** | target **26** / compatible **26**（HarmonyOS 7.0） |
| deviceTypes | `phone`、`tablet` | `phone`、`tablet`、`2in1` |
| 屏幕形态 | compact / wide / folded，单/双/三栏 | ≥840vp 双栏，<840vp 单栏 |
| 本机 agent | **无** | Node 24.2 + dsh 0.2.2 全量 |
| 离线能力 | 3 个内置 MiniApp + 本地 GenUI（仍需模型 API） | 全量 agent/工具/记忆/产物（模型 API 需网络） |
| 账号 | 远程控制必须登录（GitHub / 邮箱） | 无 |
| 语言 | zh-CN / en-US 资源化，key 锁步检查 | 中文硬编码（无 `en_US` 资源目录） |
| 设计系统 | `design-system/` 契约生成 ArkUI/Compose/SwiftUI 常量，HarmonyOS 为视觉基准 | 六主题 / 三档外观 / 四档字号，无 token 契约 |
| 测试面 | 16 个 LocalTest + 4 个 ohosTest + 71 个 host `.test.cjs` + hdc 截图脚本 | 9 个 `.test.ets` + payload 单测 + `scripts/test.sh` |
| 规模 | 398 个 ArkTS 文件 / 78,937 行；102 个组件文件 | 59 个 ArkTS 文件 / 23,635 行 |
| 手表 | 支持 HarmonyOS watch provisioning | 无 |
| 折叠/宽屏 | 明确按 compact/wide/folded 设计并验 | 按 840vp 断点，平板已验、2in1 未验 |

两个数字值得单独记住：

1. **API 覆盖**：他们 21+（HarmonyOS 6.0.1 起），我们 26+（7.0 起）——
   我们主动放弃了一代设备。
2. **安装体积**：我们 ≈388MB vs 他们源码 12MB（成品未构建）——
   这是「端侧运行时」的物理代价，不是实现瑕疵。

---

## 4. 他们和 dsh 的关系（本文最重要的发现）

OpenBitFun 对 dsh 有**三条互相独立的接入路径**，比「支持 dsh」四个字复杂得多：

| 路径 | 位置 | 做什么 |
|---|---|---|
| ① 外部 ACP agent | `src/crates/interfaces/acp/src/client/builtin_clients.rs`、`dsh_profile.rs` | 把 dsh 当成和 opencode/Claude Code/Codex 并列的 ACP CLI，`dsh --profile openbitfun-acp` 子进程启动；桌面或 SSH 主机上跑 |
| ② IDE 级 ACP 桥 | `packages/dsh-acp/`（`@openbitfun/dsh-acp`） | 在用户已装的 dsh 里注入一个 profile：发布 tool call / reasoning / plan、`session/load`、`mode` 与 `model` 两个 config option、preset（minimal/standard/code） |
| ③ 静态投影 adapter | `src/crates/adapters/dsh-adapter/` | 不执行 Cordis：只读 dsh 的 bundle/`cordis.patch.yml`、Hooks、MCP 声明，以及 `$DSH_HOME/sessions` 的 v0 JSONL/Zstd 历史，导入成 OpenBitFun 的会话/插件视图 |

### 4.1 版本差

- 他们的桥钉在 **dsh 0.1.0-rc.6**（`packages/dsh-acp/README.md` 明写 `0.1.0-rc.6` train，
  `minDshVersion` 也是它）；
- 我们是 **0.2.2-rc.5**，且真机闭环（ACP 9 方法、审批三档、模型/推理档位、密钥热更新）。

也就是说：**在「dsh 端侧运行时」这条线上我们领先一个版本段；在「dsh ACP 客户端语义」这条线上
他们更完整。** 他们的桥补了我们没有的三件事：

1. `loadSession` / `session/load`：关掉再点开能恢复原会话，并回放历史；
2. `mode` config option：一个会话可在 minimal/standard/code 之间选 preset，且首轮后锁定；
3. 把 dsh 已配置的模型目录（按 provider 分组）作为 `model` 选项发布。

我们的 ACP 客户端目前是 `resume` + `model` / `reasoning_effort`，没有 `session/load` 语义，
也没有「模式」概念（`docs/SPIKE-ACP.md` §4.2、`entry/src/main/ets/model/AcpClient.ets`）。

### 4.2 他们对 stock `dsh-acp` 的判断

`packages/dsh-acp/README.md` 写：stock `@deepseek-ai/dsh-acp` 是**自动化面**，
"deliberately withholds tool calls, reasoning, and mode selection"。
这条判断针对的是 **0.1.0-rc.6**；我们 0.2.2 实测已经能收到 `tool_call` / `agent_thought_chunk`，
说明上游在进步，**不能把他们的结论直接套到我们版本上**。
但他们的桥仍值得读：`session/load` 的持久化路径、「mode 首轮后锁定」的语义、
以及「模型目录按 provider 分组发布」的做法，都是 0.2.2 仍未替我们解决的产品问题。

### 4.3 旧版本兼容的代价

他们的 adapter 读的是 dsh **v0** 会话日志（JSONL/Zstd），我们的运行时写的是 **v4**
（`session.v4.jsonl.zstd`）。这提醒一件事：**dsh 的持久化格式在快速演进**，
任何「旁路读日志」的集成都会随上游升级而腐化；我们直接内嵌运行时，反而没有这层风险。

---

## 5. 能力矩阵（按用户可感知的域）

分级只表示「我们有没有」：✅ 有且真机验过 · 🟡 有但受限/未验 · ❌ 无。

| 域 | OpenBitFun | HarmonyGo | 判断 |
|---|---|---|---|
| 流式对话 / 思考 / 工具轨迹 | ✅ | ✅ | 对齐 |
| 插话 / 排队 | ✅ steer + 队列（可拖拽排序） | 🟡 队列 + 立即发送（ACP 无 steering） | 我们受 dsh ACP 限制 |
| 计划 / 待办 | ✅ plan 卡 + Build | 🟡 todo 条 / 目标条，无 plan 卡 | 可补 UI |
| 模型 / 推理档位 | ✅ 会话内选择，host 目录驱动 | ✅ 顶栏选择，configOptions 驱动 | 对齐 |
| 多智能体 | ✅ 并行子代理 + 化身卡片 + 编排 | 🟡 dsh subagent 工具 + 计数 | 他们产品化更深 |
| 记忆 | ✅ 长期记忆设置（原生） | ✅ 端侧 SQLite 本体 + pinned 注入 + 面板 | 机制不同，我们更结构化 |
| MCP | ✅ 完整（设置、@ 选择、SSH 探测） | ❌ 未挂载（`mcpServers` 恒空，无设置面） | **明确缺口** |
| Skills / Hooks | ✅ 管理、按 agent 裁剪、外部导入 | 🟡 dsh `skill` 工具在，Office skill 被禁；无管理面 | 缺口在「管理/呈现」 |
| 自定义 agent | ✅ 主/子 agent、工具组、项目级 | ❌ 无 | 他们强 |
| Office 文档 | ✅（主机侧 Rust/Office 栈） | ✅ docx/xlsx 端侧读写 + 原生预览 | 我们独有在「端侧」 |
| Python / 计算 | ✅（主机 Python/终端） | 🟡 Pyodide 实验，默认关 | 我们独有在「端侧」 |
| Git | ✅（主机 git） | ✅ 纯 JS git 八动作 | 能力等价，机制不同 |
| HTML / GenUI | ✅ GenUI + MiniApp + 市场 | ✅ `html` 工具 A2UI 28 组件 + 长图/PDF | 他们生态化，我们产物化 |
| 文件 / 终端 / 编辑器 | ✅ 远程文件、PTY、Monaco、diff、code review | 🟡 预览/分享，无终端、无 diff 视图 | 他们强 |
| 浏览器 / 电脑操作 | ✅ | ❌ | 平台/定位外 |
| 远程工作区 | ✅ SSH / 容器 / WSL / 跳板 | ❌（只有项目同步） | 他们强 |
| 多设备 | ✅ 设备切换 + Relay + E2E | 🟡 项目/会话/本体同步（星闪/TCP） | 方向不同 |
| 后台长任务 | ✅ detached dispatch / 任务板 | ❌（手机后台冻结，无宿主服务） | 结构性差距 |
| 账号 / 市场 | ✅ | ❌（刻意不做） | 定位差异 |
| 语音输入 / 朗读 | ✅ | ✅（离线引擎真机验成） | 对齐 |
| 通知 | ✅ 本地完成通知 | 🟡 代码有，系统权限被设备挡住 | 平台坑 |
| 分享 / 导出 | ✅ 卡片 / Pages | ✅ 分享卡 / 长图 / PDF / Markdown | 对齐 |
| i18n | ✅ zh-CN/en-US 资源化（文档另有 ja） | ❌ 中文硬编码 | **可补** |
| 桌面 / CLI / Web | ✅ | ❌ | 定位外 |
| 鸿蒙手表 | ✅ provisioning | ❌ | 可选 |

---

## 6. 各自真正的优势（去掉功能噪音）

### 6.1 他们强在哪

1. **多入口与生态**：Desktop/CLI/TUI/Web/Server/SDK/ACP/手机，一套 runtime 多张脸；
2. **远程控制面**：账号 + 设备目录 + Relay + E2E + 断线续跑，这是「手机当遥控器」的完整答案；
3. **扩展产品化**：MCP/Skills/Hooks/自定义 agent/MiniApp 市场，扩展不是插件开发者的事，是 UI 里的事；
4. **长任务与多智能体**：Ultimate 模式、子代理编排、detached dispatch、任务板；
5. **工程化**：i18n 契约、设计 token 审计、架构单测、三端生成、136 篇文档、能力目录自动生成。

### 6.2 我们强在哪

1. **端侧运行时**：没有电脑、没有主机、没有账号也能干活——这是他们手机端结构上做不到的；
2. **端侧数据与记忆**：Ontology（SQLite、23 谓词、pinned 注入、面板删除、bundle 合并）
   是产品级差异，不只是「存了个文件」；
3. **端侧工具深度**：纯 JS git、纯 JS Office、Pyodide Python、HTML A2UI——
   都是在「禁 fork/exec + 无 WASM + 无原生模块」下硬做出来的；
4. **设备间协作**：星闪/TCP 双通道同步，手机↔平板真机闭环；
5. **平台硬约束的解法本身**：同进程 Node、jitless fetch shim、link fallback、ACP 进程内跑——
   这些是他们不需要面对、也就不会有的工程资产。

### 6.3 一句话

**他们卖「随处可用的工作台」，我们卖「口袋里不需要主机的 agent」。**
前者赢在生态与规模，后者赢在离线、隐私与「没有电脑」的场景。

---

## 7. 可借鉴清单（按我们的成本分级）

### A：纯客户端能做完（ArkTS，不动载荷）

| 项 | 他们的做法 | 我们的落点 |
|---|---|---|
| i18n | `i18n/` key 锁步 + 生成契约 + CI 检查 | 先做 zh/en 两套资源 + 编译期 key 检查；设置里跟系统语言 |
| 设计 token | `design-system/` 契约生成三端常量 | 单平台不需要三端生成，但可把六主题/字号/间距收成 token 表 + 预览场景 |
| diff 视图 | 文件改动/diff 卡片 | 已有 rollback 每轮快照，可算 diff（`docs/DSH-GO-PARITY-V2.md` 也提过） |
| 队列排序 | 拖拽 / 上移下移 | 现有队列加排序与「仅影响选中项」的语义 |
| Markdown 细节 | 单波浪号字面量、流式未闭合、转义 | 已有渲染器，补规则与测试 |
| 架构测试 | `ArchitectureUnit.test.ets` 12 条分层规则 | 我们有 pages/model/view 分层，可加同样的 import 方向断言 |
| 代码块复制 / LaTeX | 原生复制、公式渲染 | 复制是 A；公式要么自绘要么 WebView（成本更高） |

### B：要动 `host/` 或载荷（写插件 / 加依赖 / 重打载荷）

| 项 | 他们的做法 | 我们的落点 |
|---|---|---|
| ACP 增强 | `packages/dsh-acp`：`session/load`、`mode`、commands、thought chunks | 做一个 `@ohos/dsh-acp-ide` 插件（或改 ohos bundle 的 ACP 行），补 load/mode；MIT 可参考，但要按 0.2.2 的 API 重写 |
| MCP | 设置页 + @ 选择 + SSH 探测 | 在 ohos profile 挂 `dsh-mcp-client`，设置页写 `cordis` 配置；先做 stdio/HTTP 两种 |
| MiniApp 化 | 沙箱 ArkWeb + 每应用存储/剪贴板白名单 + 市场 | 把 `html` 产物升级为「可安装的本地小应用」：存储、列表、卸载；不引市场 |
| 轻客户端模式（可选） | 手机 UI + 桌面 host | 与「无需电脑」定位冲突，作为**产品路线分叉**评估，不要顺手做 |

### C：结构性不可行 / 不建议

- **Relay / 账号 / 市场**：与「无账号、数据不出设备」的定位正面冲突；
- **detached task / 后台长任务**：手机后台会冻结，且没有宿主 `session-controller`（`docs/ROADMAP.md` 已判 C）；
- **computer use / 桌宠 / 悬浮窗**：权限与审核成本高，且不是我们的场景；
- **三端 KMP 共享**：我们只有鸿蒙，收益为负；
- **照抄他们的 monorepo 工程规模**：54 个 crate、136 篇文档是多人多端协作的产物，单人/小团队照抄会拖死迭代。

---

## 8. 战略启示（比功能表更重要）

1. **「手机 + dsh」有两条路，他们选了轻的，我们选了重的。**
   他们的存在说明「遥控器」体验已经足够好到能拿走一部分用户；我们的护城河必须落在
   **没有主机也能跑**、**数据/记忆不出设备**、**离线产物**这三件事上，并在首屏就让人感知到。
   否则用户会拿一个轻量遥控器来对比 ≈388MB 的本地运行时。

2. **体积与 API 覆盖是 adoption 的两道门。**
   他们 compatible 21、手机端源码 12MB；我们 compatible 26、HAP ≈388MB。
   这不是「优化一下」的问题，而是**产品覆盖策略**：是否要做按形态裁剪载荷（手机不带 Python/Office）、
   是否能降 API（受 libnode/NAPI 约束，属未知项）、是否提供「首次启动按需下载工具包」。
   建议单独立项验证，不要默认「就这样」。

3. **ACP 是两边共同的语言，也是我们最值得补的一课。**
   他们的桥证明：IDE/客户端愿意为 `loadSession`、`mode`、`model` 这些语义写一整个 profile。
   我们的 ACP 客户端已经有 9 方法 + 审批 + 配置，会话重开靠 `session/resume` 自己实现；
   真正缺的是「模式」概念和 ACP 标准的 `session/load` 语义。
   补上后，我们的会话体验会更接近桌面 IDE，而不是「一次性聊天」。

4. **dsh 版本领先不等于集成领先。**
   我们在 0.2.2-rc.5，他们在 0.1.0-rc.6；但他们的 ACP 语义更完整、多智能体呈现更产品化。
   两边其实可以互补：我们的端侧 profile/插件经验 + 他们的 ACP 桥思路。
   若上游 dsh 的 ACP 继续演进，我们应优先把「端侧 ACP 扩展」做成可复用插件，而不是继续在
   ArkTS 里补协议。

5. **不要被功能表带偏。**
   他们多模式（README 主打 4 种，能力目录列到 8 种）、市场、Relay、SSH、桌宠是「工作台」的广度；我们的 33 个工具、本体、星闪是
   「端侧 agent」的深度。**广度上永远追不平，深度上他们结构上做不到。**
   路线图应按「端侧独有能力」排序，而不是按他们的功能清单打勾。

---

## 9. 证据与复核

```bash
# 他们（2026-11-23 快照）
git clone --depth 1 https://github.com/openBitFun/openBitFun.git /tmp/openBitFun        # 5946eab1
git clone --depth 1 https://github.com/openBitFun/OpenBitFun-Mobile.git /tmp/openBitFun-Mobile  # 2cf3a4ad

# 关键文件
/tmp/openBitFun/docs/architecture/product-architecture.md
/tmp/openBitFun/packages/dsh-acp/README.md
/tmp/openBitFun/src/crates/adapters/dsh-adapter/AGENTS.md
/tmp/openBitFun/src/crates/interfaces/acp/src/client/dsh_profile.rs
/tmp/openBitFun-Mobile/src/apps/mobile/README.md
/tmp/openBitFun-Mobile/src/apps/mobile/harmonyos/README.md
/tmp/openBitFun-Mobile/src/apps/mobile/harmonyos/build-profile.json5

# 我们的对应锚点
AGENTS.md §2/§3/§4/§5/§7
docs/SPIKE-ACP.md
docs/POSITIONING.md
docs/DSH-GO-PARITY-V2.md
host/patches/ohos.patch.yml
entry/src/main/ets/model/AcpClient.ets
```

**事实边界（诚实清单）**

- 他们的 HAP 未构建：12MB 是源码目录，不是安装包；成品体积按资源量级推断「远小于 388MB」。
- 他们的 Relay/账号/SSH 未实跑：远程行为按文档与代码描述，未做真机复核。
- 他们的 dsh 桥未在本机跑：版本、preset、`session/load` 语义按 README 与源码。
- 我们的 API 26 下限未做「降到 21」的可行性实验；文中只把它列为**待验证的战略问题**，
  不声称可降或不可降。
- 文中「他们强/我们强」是相对判断，不是能力承诺；对外表述仍以 `docs/POSITIONING.md` 为准。
