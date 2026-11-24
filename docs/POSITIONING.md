# POSITIONING.md — 对外口径与边界（唯一文案来源）

> 状态：**2026-11-24 定稿**，仓库所有者的对外表述以此为准。新增对外文案（README、发布说明、
> 应用介绍、路演材料）先看这里，避免同一件事出现两种说法。中文为主，英文口径见 §7。

## 1. 一句话

> **鸿蒙不是 Personal Agent 的孤岛。**

**HarmonyGo 把完整的 dsh agent 运行时（Node v24.2.0 + 676 个依赖）装进 HarmonyOS 应用进程**
—— 手机、平板、2in1 不连电脑就能跑 agent；记忆（端侧本体）、文档（Office / HTML 产物）、
代码（纯 JS git）、计算（实验性 Python + 内置 pybot）、设备间同步（WiFi / 星闪）也都在设备
本地完成，不经过云端会话。

仓库：[GitHub](https://github.com/QtePP/harmony-go) · [AtomGit](https://atomgit.com/qtepp/harmony-go)

## 2. 三句话（对外介绍）

1. **运行时**：同进程内嵌 Node 与 dsh，用纯 JS 垫片绕开鸿蒙「禁 fork/exec、无 WASM」的宿主限制
   —— **让鸿蒙第一次能原生承载现代 agent 运行时**（模型 API 仍联网）。
2. **记忆**：端侧 SQLite 个人本体，身份 / 过敏 / 偏好等「硬约束」跨会话自动带上，其余按需查询；
   可面板查看删除、可导出 bundle、可跨设备合并。
3. **协作面与工具**：项目文件、会话缓存、本体 bundle 可经 **WiFi 或星闪** 在两台设备间同步；
   产物是原生 HTML / Office 文件，可导出长图 / PDF 再分享；另有纯 JS `git`（无 git 二进制）
   与实验性 Python（Pyodide + 内置 pybot）。

## 3. 内核与价值（DNA → FAB）

- **DNA**：把桌面级 agent 运行时挤进手机沙箱 —— 不是套壳浏览器，也不是远程调用。
- **FAB**：因为运行时、记忆、Office/Python、产物导出与同步都在本机 →
  不用带电脑、不用 Office 订阅、不用把上下文搬到云端 →
  **掏出手机就能把活干完，并把结果直接发出去**。

## 4. 头号功能（Key Feature）

> **端侧个人本体（Ontology）**：SQLite 存身份、过敏、语言、沟通偏好等硬约束，跨会话自动注入；
> 其余事实按需查询，不占每轮上下文；可查看、删除、分享，可导出并对端合并。

## 5. 为什么是现在（SCP：场景 - 冲突 - 承诺）

- **场景**：出门在外只有手机，临时要定位报错、改文档、写周报。
- **冲突**：电脑不在、Office 不在、云端 agent 记不住你，跨设备传文件还得来回倒。
- **承诺**：HarmonyGo 在设备本地跑 agent、带着你的本体记忆，直接产出可分享的 HTML / Office
  产物，还能用 WiFi 或星闪同步到另一台设备。

## 6. 能这么说 / 别这么说

| 想表达 | ✅ 可以这样说 | ❌ 不要这样说 |
|---|---|---|
| 宿主限制被绕开 | 「绕开鸿蒙禁 fork/exec、无 WASM 的宿主限制」；私下可叫「运行时隔离」 | 「突破了生殖隔离」（比喻，对外像营销话术，且容易被追问） |
| 先进 agent | 「能承载 **Node 生态的 agent 运行时**；dsh 已真机闭环，Claude Code 这类 Node CLI 原则上可承载（**未验证**）」 | 「能跑 codex / claude」（Codex CLI 是 **Rust 二进制**，当前架构不能直接运行；Claude Code 未验证） |
| 多端 | 「每台设备各自跑一套同构运行时；手机 / 平板 / 2in1 三种形态」 | 「共同运行时」（会被理解成云端共享会话） |
| 开源 | 「App 侧 MIT 开源；dsh 本体是 npm 第三方包，随载荷分发」 | 「全部代码都是我们写的」 |
| 同步 | 「手动发送 / 接收，配对码保护，不覆盖已有文件」 | 「实时协同」 |
| Python | 「内嵌 Pyodide 的**实验**运行时，默认关闭」 | 「完整 Python 支持」 |
| pybot | 「内置的**实验**小模型，不作为产品能力」 | 「自带本地大模型」 |

## 7. English

> **HarmonyOS is not an island for Personal Agents.**
>
> HarmonyGo embeds a full dsh agent runtime — Node v24.2.0 and its dependency tree — inside a
> HarmonyOS app process, so phones, tablets and 2in1 devices run an agent on-device without
> tethering. Memory (an on-device SQLite ontology), documents (native Office and HTML artifacts),
> code (pure-JS git), compute (experimental Python and the bundled pybot), and device-to-device
> sync (Wi-Fi / NearLink) all happen locally rather than through a cloud session.
>
> Repositories: [GitHub](https://github.com/QtePP/harmony-go) · [AtomGit](https://atomgit.com/qtepp/harmony-go)

## 8. 能力状态（对外承诺前先看这张表）

| 状态 | 能力 | 证据锚点 |
|---|---|---|
| **已验证（真机）** | 同进程 Node v24.2.0 + dsh 0.2.2-rc.5（ACP 9 方法）；phone CMM-AL10 / tablet MLR-AL00 | `docs/STATUS.md`、`docs/SPIKE-ACP.md` |
| **已验证（真机）** | HTML 产物：组件库生成、整页长图 PNG、单页 PDF、亮/暗双导出、系统分享 | `docs/STATUS.md`（2026-11-23/24 条） |
| **已验证（真机）** | Office：`office_write_docx` / `office_write_xlsx` / `office_read`，App 内原生只读预览 | `docs/OFFICE.md` |
| **已验证（真机）** | 端侧个人本体：SQLite、pinned 注入、面板查看/删除/最近删除、bundle 导入导出、跨设备同步 | `docs/ONTOLOGY.md` |
| **已验证（真机）** | 项目同步：TCP（局域网）与星闪（NearLink）两条传输，文件 + 会话 + 本体 bundle | `docs/PROJECT-SYNC.md` |
| **已验证（真机）** | 纯 JS `git`（clone/snapshot/pull/log/diff/status/commit/push），无 git 二进制 | `docs/GAP-ANALYSIS.md`、插件测试 |
| **实验（默认关闭 / 非产品）** | 端侧 Python（Pyodide 3.13 + numpy/pandas，Worker 隔离，Settings 开启）、`pybot_reply` | `docs/PYTHON.md` |
| **实验** | 本机窄意图 gate（问候/身份/时间/算术等精确规则，不开 session 不调模型） | `docs/LOCAL-GATE.md` |
| **未验证** | 鸿蒙 PC（2in1）真机：窗口缩放、键鼠、安装与签名 | §10、`docs/ROADMAP.md` §6 |
| **不支持** | fork/exec、原生 `.node` 模块、WebAssembly（jitless）、OWL 2 DL 推理、Codex CLI（Rust 二进制） | `AGENTS.md` §5、§7.2 |

## 9. 与「先进 agent」的关系（诚实版）

- 本仓库交付的是**运行时**，不是某个 agent 品牌：`dsh` 是唯一的大脑，agent 能力来自它。
- 同为 Node 生态的 CLI（如 Claude Code）**原则上**可以走同一套机制（同进程 Node + 无 WASM 依赖），
  但**未在本仓库验证**，不要当成已支持。
- Codex CLI 是 Rust 编译产物，没有 JS 入口，当前「禁 fork/exec + 无原生模块」的架构**不能直接运行**；
  要做只能重写或改造其协议层，属于另一个项目。
- 一旦某个 Node agent 在设备上跑通，应在 `docs/STATUS.md` 留下真机证据，再更新本节与 README。

## 10. 鸿蒙 PC（2in1）迁移

**目标**：把「手机 / 平板已验证」扩到「手机 / 平板 / 2in1 三形态已验证」。

**现状口径**：`deviceTypes` 已声明 `2in1`，UI 已按 840vp 断点自适应，但**从未在鸿蒙 PC 真机验收**
——对外只能说「三形态支持，2in1 待真机验收」，不能说「已支持鸿蒙 PC」。

**验收清单**（细节与预判改动见 `docs/ROADMAP.md` §6）：安装与签名、载荷解包、运行时同构、
窗口缩放（≥840vp 双栏 / 窄窗单栏）、键盘（Enter 发送、Shift+Enter 换行、Esc 关面板）、
鼠标/触控板（悬停、点击、滚轮）、文件与产物（预览/导出/分享）、星闪与 WiFi 同步、
Office 原生预览、Python 开关。

**验收后**：把本文件 §8「未验证」改为「已验证（真机）」，并在 `docs/STATUS.md` 追加设备型号与
证据（不写序列号）。
