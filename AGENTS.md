# AGENTS.md — HarmonyGo 多智能体协作公约与统一语言

> 本文件面向在本仓库工作的所有 AI 代理（deveco code、workbuddy、GitHub Copilot 等）与人类协作者。
> 它是**统一语言（ubiquitous language）与口径的唯一权威**：与 docs/、历史对话或任何 agent 的
> 会话记忆冲突时，以本文件与当前代码为准；口径变更必须同一 commit 修订本文件。
> 最后对齐：2026-11-23（改名 HarmonyGo）。

## 1. 项目身份（一句话口径）

**HarmonyGo 是 dsh 的鸿蒙外壳，dsh 是这个仓库唯一的大脑。**
（产品名/应用显示名 **HarmonyGo**，包名 `com.qtepp.harmonygo`；旧名 TA Harness / `com.qtepp.taharness` 仅出现在历史记录里。）

- 仓库：<https://github.com/QtePP/harmony-go>（MIT；2026-11-23 由 `deepseek-harness-harmony` 改名，GitHub 旧地址会重定向）
- 镜像与站点：<https://atomgit.com/qtepp/harmony-go>（同步推送：`scripts/push-all.sh`）；落地页 <https://qtepp.github.io/harmony-go/>（GitHub Pages，从 `main` 的 `/docs` 发布；入口 `docs/index.html`）
- 形态：原生 ArkUI 客户端 + **同一应用进程内**的 dsh 运行时；不套壳浏览器、不投屏、不连电脑。
- 覆盖形态：`deviceTypes` = phone / tablet / **2in1**（鸿蒙电脑），840vp 布局断点切换单/双栏。
- 目标平台：API 26 / HarmonyOS 7.0.0，arm64-v8a，minAPI 26（装不上 HarmonyOS 6.x）。
- 类比：VS Code 与其进程内扩展引擎；或 Electron 之于 Chromium+Node。

## 2. 统一语言（术语表）

| 术语 | 定义 | 锚点 |
|---|---|---|
| **dsh** | 唯一的「大脑」：npm 包 `@deepseek-ai/dsh`（**0.2.2-rc.5**，依赖树 **676 包**，npm install 实测 added 计数）。会话、工具调用、插件、模型适配、持久化全部来自它；本仓库不含任何 AI 能力 | 载荷内 node_modules |
| **HarmonyGo / 外壳** | 产品名（应用显示名）**HarmonyGo**，包名 `com.qtepp.harmonygo`；本仓库自身：ArkUI 界面 + 宿主适配层。**旧名 TA Harness / `com.qtepp.taharness`** 只留在历史记录里，代码/资源/运维命令一律用新名 | 本仓库 |
| **Payload / 载荷** | `dsh-payload.zip`（≈240MB 十进制 / 227 MiB）：dsh 及其依赖打进 HAP rawfile，首启解包到沙箱（**解包后 ≈1.4GB**，2026-11-25 CMM-AL10 实测；解包成功即删除沙箱副本） | `scripts/assemble-payload.mjs`、`entry/.../host/Payload.ets` |
| **Bridge / 桥** | 127.0.0.1:4517 回环 TCP，承载 newline-delimited JSON-RPC 2.0；bootstrap 把 socket 伪装成 dsh 的 stdio。**单客户端**：新连接 `replacing previous client` 顶掉旧连接 | `host/bootstrap.cjs`、`entry/.../model/DshClient.ets` |
| **Host 层** | 把 Node 拉进鸿蒙进程的适配层：NAPI dlopen `libnode.so` + `node::Start` | `entry/.../host/NodeHost.ets`、`@fellow99/node-bridge` |
| **Profile SDK / ACP** | dsh 两条程序接口，都是 stdio 上的换行 JSON-RPC、流均可注入。**SDK**：5 个方法，出厂默认、真机验收过，但**是降级路径**（不挂 ohos 插件）。**ACP**：9 个方法 + 流式 update + 服务端发起审批，进程内可跑（spike 已证）、2026-10 起真机闭环；**首次启动会问一次用哪个**（`AppConfig.profilePrompted`，答案决定当次启动，不用重启）。出局的只是「宿主 spawn dsh」，不是 ACP 本身 | `host/bootstrap.cjs`、`docs/SPIKE-ACP.md` |
| **ohos profile / 纯 JS 搜索** | 自定义 profile（`host/profile-ohos/profiles/ohos`，随载荷分发）：bundle `dependencies` 声明插件（路由表按 bundle 依赖闭包构建，漏声明 = 永不 mount）+ bundle patch 顶层 `- insert:` 挂 `@ohos/dsh-tool-fs-search-js`（纯 JS glob/grep，模型工具名不变）并禁 stock `tool-fs-search`；bootstrap 按内容哈希戳幂等安装到 `$DSH_HOME/profiles/ohos` 并把 `acp` 重映射为 `ohos`（缺模板回落 stock acp）。ACP 方法集不变 | `host/bootstrap.cjs`、`docs/GAP-ANALYSIS.md` §7.1 |
| **Session / 会话** | 客户端生成 UUID 作 id；服务端持久日志 `session.v4.jsonl.zstd`（按初始化 cwd 的 slug 存放，id 全局可查）；本地 `SessionStore` 只存 UI 索引与消息缓存（最近 200 条） | `entry/.../model/ChatModel.ets` |
| **Project / 项目** | 对话分类：命名桶 + 独立 workspace；`default` 为默认项目，兼容全部历史会话与旧路径 | `entry/.../model/ProjectModel.ets` |
| **Workspace** | 默认项目 = `filesDir/workspace`（initialize 的 cwd，向后兼容）；其他项目 = `filesDir/workspaces/<projectId>` | `ProjectStore.workspaceDir()` |
| **Plugin patch / 补丁** | 两份 YAML 经双 `--patch` 传入：平台补丁 `ohos.patch.yml` + 用户补丁 `user.patch.yml`（Settings 能力开关生成；后者后传，覆盖前者同名行） | `host/patches/`、`entry/.../common/PluginConfig.ets` |
| **jitless / fetch-shim** | 无 JIT ACL ⇒ `--jitless` ⇒ 无 WebAssembly ⇒ 内置 undici 失效 ⇒ 纯 JS fetch 垫片接管（`install()` 用 defineProperty 把 fetch/Headers/Response/Request/FormData 全家族换成 shim——dsh 启动期会读全局 Headers（account-platform），只换 fetch 会触发惰性物化 WASM undici 而崩溃） | `host/fetch-shim.cjs`、`host/undici-esm.mjs` |
| **link-fallback** | 沙箱禁 hardlink（EACCES）⇒ `copyFile(COPYFILE_EXCL)` 降级，装配期注入 | `bootstrap.cjs` `installLinkFallback()` |
| **840vp 断点** | ≥840vp：会话栏 + 对话双栏；<840vp：单栏，rail 收进 sheet | `entry/.../pages/Index.ets` |
| **dsh-home** | 沙箱内运行时主目录：`bridge.log`、`bridge-status.json`、`sessions/`、`storages/` 等 | `NodeHost.ets` |
| **ptc-runtime-vm / run_code** | in-process PTC 运行时（`@ohos/dsh-ptc-runtime-vm`，worker_threads + `node:vm`，随载荷分发）：**`tools.mode` 在 0.2.2 已被删除**（schema 变 `z.never()`，写它直接启动失败）；改由 `tool-executor-native` 行承担，base 默认挂载、`tool-executor-ptc` 默认禁用（2026-11-15 升级实测）。**native 下模型工具表 33 个直出工具（dsh 自带 25 个 —— glob/grep/read/write/web_search/web_fetch/edit/skill/subagent/todo_write 等 —— 加上我们插的 `git`、`html`、`office_*` 三个、`python_run`、`pybot_reply` 与 `ontology`；`user_profile` 已 disabled），`run_code` 不在其中**——dsh-tools 只在非 native 模式把 run_code 注入可见表（`dsh-tools/lib/index.js` view()：`mode !== "native"` 才 `visible.set(RUN_CODE_NAME)`）；`mode: ptc` 则反过来：wire 上**只有 run_code**（wireSchemas 过滤掉其余 schema），其余工具只能经程序内 `tools.*` SDK。boot-report 的 `tools(N)` 用 `ctx.tools.schemas()`（注册表视图），ptc 模式下计 34（全部 + run_code），native 下计 33（含 `git` / `html` / `office_*` / `python_run` / `pybot_reply` / `ontology`；0.2.2 时为 25，0.2.1 时是 21）。ptc-runtime-vm 仍挂载（提供 `ctx.ptcRuntime`），未来 preset 可经 `dsh-agent-tool-presentation` 行（`tool-presentation`，preset 级 `presentAs`）opt-in PTC；worker 不可用时优雅 `worker-exit` | `host/profile-ohos/.../@ohos/dsh-ptc-runtime-vm`、`.build/payload/node_modules/@deepseek-ai/dsh-tools/lib/index.js` |
| **credentials-live / 密钥热更新** | `@ohos/dsh-credentials-live`（随载荷分发，ohos profile 专属）：目录级 fs.watch + 1.5s 轮询 `<dsh-home>/.api-key`，变化经 `credentials.set()/unset()` 热发布。dsh 启动期冻结 env 快照（`loadLayeredEnv` 拷 `process.env`），运行中改 env 永远无效——这是唯一热路径；Settings 保存密钥 ~2s 生效无需重启（ACP 路径；SDK profile 无此插件，重启生效） | `host/profile-ohos/.../@ohos/dsh-credentials-live` |
| **time-context / 时间上下文** | `@deepseek-ai/dsh-time-context`（dsh 自带、随载荷分发）：把当前时间作为 durable 注入写进请求历史（默认 10 分钟一次），模型据此知道"今天"。**它不是工具**，桌面/SDK profile 由 `dsh-sdk-app` 挂载，`dsh-acp-app` 不含 → ohos bundle 自己 insert 一行；缺它时模型对相对日期的推理全是猜 | `@ohos/dsh-bundle-ohos/cordis.patch.yml` |
| **tool-git / 纯 JS 仓库** | `@ohos/dsh-tool-git`（ohos profile 专属）：一个工具的**八个**动作 `clone` / `snapshot` / `pull` / `log` / `diff` / `status` / `commit` / `push`，用 isomorphic-git（纯 JS，packfile 走 pako，**零 WASM**）经 HTTPS 把仓库落到 `repos/<slug>`，之后交给 `glob`/`grep`/`read` 分析——**仓库在手机上 ≠ 推理在手机上**，推理仍在云端。**HTTP 客户端是自己写的**（`http.js`：`node:https` 流式 + 字节计数 + 中途 abort），不用 `isomorphic-git/http/web`：后者经全局 fetch（我们的 shim）会全量缓冲，且进度只报**对象数**不是字节。三条实测硬约束：内存 ≈ 100MB + 11 × pack（92MB 仓峰值 1.1GB）⇒ `maxPackMb` 默认 50、**传输中途** abort（不是先验拒绝——文案必须这么写，否则模型会转述成「没下载任何字节」）；shallow 仓**不能 pull**（js-git 抛 `TypeError`）⇒ `snapshot` 标只读、`pull` 按名字拒绝；**`resolveRef` 不认 ancestry 语法**——`HEAD~1`/`HEAD^` 在全量 clone 上也抛 `NotFoundError`（本地 128-commit 实测），所以 `diff` 自己走父链（`resolveRev`）并逐步校验父提交在库里（shallow 的 commit **记录**父 oid 但父不在库）。`commit` 只暂存 **`repos/<slug>` 内**的路径（`guardPaths` 拒绝 `..`、绝对路径——`write`/`edit` 能写到工作区任意位置，这是唯一栅栏），`push` 需要 `<dsh-home>/.git-token`（**不进 env**：bridge 会把env dump 进 `node.log`），无 token 时先报 `GIT_NO_TOKEN` 而不是等 GitHub 回 403。**设备上没有 `rm`/`bash`**，删不掉的后果是死路 ⇒ `clone`/`snapshot` 收 `force: true` 由工具自己删，且**先克隆到 `.qtepp-<slug>.incoming` 再换入**（第一版先删后克隆，真机撞上一次 GitHub 超时就把唯一副本弄没了——破坏性操作不验失败路径等于没验）。包从**载荷**的 node_modules 加载（`DSH_PAYLOAD_ROOT`），因为 profile 树在 dsh-home 下解析不到它 | `host/profile-ohos/.../@ohos/dsh-tool-git` |
| **tool-user-profile / 跨会话画像（已停用）** | `@ohos/dsh-tool-user-profile`（ohos profile 专属）：**2026-11-24 起 `disabled: true`，不再挂载**；代码/测试保留，旧受管块用 `ontology` 的 `migrate_profile` 迁移。一个工具的四个动作 `add` / `replace` / `forget` / `list`，把模型学到的**用户特征**追加进 `<DSH_HOME>/AGENTS.md` 的**受管区块**（`<!-- dsh:user-profile:begin/end -->`）。区块外的用户自己写的 prose 一字不动。**为什么是文件不是数据库**：dsh 没有任何画像 seam，唯一跨会话的通道是 `dsh-agent-instructions`——它在每次会话第一条请求前把 `$DSH_HOME/AGENTS.md` + `$DSH_AGENTS_HOME/AGENTS.md` + 项目链（含 `AGENTS.local.md`）拼成 durable 上下文，实测成型（`<system-reminder>` 里逐文件原样渲染）。**每条带学习日期**（`- 2026-11-20 — …`）：画像会漂移（今天"喜欢简洁"、明天"喜欢详细"），带日期就能看出哪条过期，`replace` 是显式取代而不是两条并存。硬约束：事实 80 条上限（超了丢最旧）、单条 400 字符、受管区块 12KB 上限（超了**拒绝写**而不是静默截断）、写入走 stage+rename 原子替换、`fileName` 必须是 home 内相对路径（绝对路径直接拒）。读写走 `node:fs/promises` 而非 `ctx.fs`：目标是 harness home（工作区外），`ctx.fs` 会被 `workspace-write` 栅栏拒绝。**真机已闭环（2026-11-20）**：模型自己 `add`×2 → 冷启 force-stop 后新开会话仍答得出两条，`replace` 是取代而非并存 | `host/profile-ohos/.../@ohos/dsh-tool-user-profile` |
| **tool-ontology / 端侧用户本体** | `@ohos/dsh-ontology`（ohos profile 专属）：`node:sqlite` 把用户本体存在 `<DSH_HOME>/ontology/ontology.db`（`entity`/`fact`/`meta`；`superseded_by`/`retired_at` 保历史，`pinned` 由谓词决定）。一个工具 `ontology` 十二个动作 `remember` / `propose` / `correct` / `forget` / `search` / `list` / `describe` / `related` / `metric` / `export` / `import` / `migrate_profile`；23 个受控谓词写在 `lib/vocab.js`（每条带 `about` / `synonyms` / `examples`，`describe` 暴露给模型，未知谓词报错并给最近邻）。**硬约束注入**：`agent/pre-step` 比较 `meta.version` 与 pinned 的 sha1 签名，只有身份/语言/过敏/饮食/沟通偏好变化时才注入一条 `source.kind='ontology'` 的 durable 消息；非 pinned 事实只走工具查询，不占每轮 prompt。**v3 语义层（2026-11-25）**：`v_live_fact` / `v_entity_edge` 视图把“当前事实”和“实体边”各定义一次；`describe` 暴露谓词含义/同义词；`related` 走 1–2 跳图；`metric` 用代码算 `age`/`days_until`/`days_since`/`count`；`search` 返回 `coverage`（none ≠ false）；`import` 返回 `conflicts`；`fact` 加 `source_kind` / `source_ref` / `status` / `confirmed_at`（`proposed` 不进 live 视图）。**v3.1 候选队列**：`propose` + `agent/turn-stopping` 的确定性抽取（`lib/auto-capture.js`，不调模型；`DSH_ONTOLOGY_AUTOCAPTURE=0` 可关）写 `status='proposed'`，面板「待确认」接受/忽略；确认按 `valid_from` 取代/写历史，忽略硬删；候选不注入、不被 `search` 返回、不随 bundle 同步。**为什么不是 AGENTS.md**：要关系、时间、取代、审计与按需查询；旧的 `user_profile` 已停用，历史块用 `migrate_profile` 迁移。**App 面板**：设置 → 它知道什么，读 `snapshot.json`，删除写 `commands/*.json`（fs.watch + 1.5s 轮询），分享 `summary.md`（ShareKit）；文件 0600。**最近删除**：快照带 `deleted`（最多 10 条软删、按谓词/值/角色去重、本地时间），面板底部可展开；证明「已记住」曾经写入、何时被删。**旧画像迁移**：`migrate_profile` 默认 dry-run，`apply:true` 读 AGENTS.md 受管块、备份、映射进本体并清块（明确模式→硬约束，其余→带日期的 `note`）。**时间**：`fact` 带 `observed_at` / `valid_from` / `valid_to` / `recorded_at` / `superseded_at` / `retired_at`；`effective_at` 写现实生效时间，单值按 `valid_from` 新者胜，较早写历史；同步同级再比 `recorded_at`；**v2 旧库重建，v3 只增量 `ALTER TABLE` 补列**。**跨设备同步**：面板导出 bundle 到 `workspace/ontology/`，项目同步（星闪/WiFi）携带，接收端面板导入合并（按 name/alias；活事实 + tombstone；单值按 `valid_from` 新者胜；删除按 `retired_at` 传播，删除后重新添加以新时间为准）；不传 live SQLite 文件。**真机闭环 2026-11-23 手机 CMM-AL10**：模型写入 3 条 → 新会话无工具答出姓名/过敏 → 面板删除 → 新会话不再说花生；**2026-11-24 手机↔平板**星闪 1.3KB bundle 导入后平板新会话零工具答出姓名/过敏。边界：无静态加密；OWL 只导出不做 DL 推理；平板同步/导入/注入已验 | `host/profile-ohos/.../@ohos/dsh-ontology`、`entry/src/main/ets/view/OntologyPanel.ets`、`docs/ONTOLOGY.md` |
| **tool-html / A2UI 组件库** | `@ohos/dsh-tool-html`（ohos profile 专属）：一个工具 `html`，四个动作 `components`（返回 **28 个组件**的清单与可复制片段：hero / card / grid / stats / steps / checklist / table / **table-sortable** / callout / timeline / compare / bars / kv / fold / quote / code / divider + 展示类 **chart-bars / chart-donut / chart-stack / chart-hbars / chart-line（静态 SVG）/ chart-heat / section-head / figure / gallery / avatars / plans**，并附**令牌表**（`--accent`、`--c1…--c5`、`--gap*`、`--radius*`、`--page-max`、`--fs-*` 等）与**修饰符表**（`card.flat/tinted/accent`、`stat.hero`、`steps.compact`、`table.compact`、`tr.hi`、`grid-2/3/4`、`wrap.narrow/wide`、`body.density-*`、间距/语义色工具类）——**观感靠改令牌和组合修饰符，不靠重写 CSS**）、`create`（写单文件骨架，样式内联、明暗两套色、移动端优先、**零外链**；支持 `tokens` 覆盖任意令牌 + `theme=auto|light|dark`、`width=narrow|wide`、`density=compact|roomy`）、`fill`（把片段放进 `<main>` 的内容插槽；`mode=append` 追加 section）、`check`（外链、缺 viewport、体积、打印按钮、组件库外的 class、**正文里写死的十六进制颜色**都报出来，并与**上一次同页检查的基线**比较：体积变化、组件增减、问题数，写 `.dsh-html/<page>.json`；若与本项目默认令牌不一致会报「主题漂移」）、`preset`（`.dsh-html/presets.json` 存/列/删命名主题，`default:true` 设为项目默认，之后每个 `create` 自动继承——同一项目页面统一观感）、`chart`（吃 CSV/TSV/JSON（inline 或 `dataFile`）直接生成图表段落：柱/横条/堆叠/折线/热力/环形，百分比、坐标、viewBox 全由工具算，模型不手写数字）。**为什么要有它**：从零写页面每次都在重复推理排版/配色/移动端，产出的两页像两个产品，还容易带 CDN 外链（设备离线打不开）和 `window.print` 按钮（嵌入式 Web 点不动）；把设计沉淀成组件库后，模型只做「选组件 + 填内容」 | `host/profile-ohos/.../@ohos/dsh-tool-html` |
| **tool-office / 端侧 Office** | `@ohos/dsh-tool-office`（ohos profile 专属）：三个工具 `office_read`（docx→Markdown / xlsx→每表 TSV，公式显示 `=…`、日期转 ISO）、`office_write_docx`（Markdown 子集→Word）、`office_write_xlsx`（CSV/TSV→单表工作簿，数字/公式/首行表头加粗冻结）。**为什么不用 dsh 自带 Office**：`skill-office` 要 Python+shell、`office-kit` 要原生 LibreOffice 或 WASM，手机三条都没有；这里用 Node 内置 zlib（编译 C，非 WASM）+ 自写 ZIP + OOXML，`--jitless` 下 40/40 通过。路径经 `ctx.fs.resolve/contains` 栅栏、写入 staging+rename，`read-only` 直接拒绝；旧格式与 pptx 明确报不可用。App 侧 `FileViewer` 用 `@ohos.zlib` 解包 + 纯 ArkTS 解析，原生渲染 docx/xlsx（只读，版式简化，300 行×40 列上限） | `host/profile-ohos/.../@ohos/dsh-tool-office`、`entry/src/main/ets/common/OfficePreview.ets`、`docs/OFFICE.md` |
| **tool-python / 端侧 Python（实验）** | `@ohos/dsh-tool-python`（ohos profile 专属）：两个工具 `python_run` 与 `pybot_reply`，在**隐藏 WebView 的 Worker** 里跑 Pyodide 0.29 / CPython 3.13.2，带 numpy 2.2.5 + pandas 2.3.2；Node 侧经 `<dsh-home>/python/{req,res}` 文件桥调用，ArkTS 用 127.0.0.1 只读 HTTP 提供 Pyodide 资产（`resource://rawfile` 不能承载动态 import/wasm fetch）。输入文件走 `files`（`/workspace/<basename>`，8 个/5MB/15MB 上限），输出只回 stdout。Python 放 Worker 是为了能 `terminate()`：主线程跑死循环会冻住整个 WebView；超时后 Worker 重启，下一次调用重新加载解释器（实测 2.5s 恢复）。**这是 spike，不是产品**：后台会冻结（`sleep(20)` 切后台 25s 实测 40.2s），没有输出文件桥、没有 CSP/禁网；**默认关闭**（Settings「Python 运行时（实验）」开启后重启；已验证关闭时 `tools(31)`、开启时 `tools(33)`）；另内置 **pybot**（Hugging Face / Apache-2.0，非 DeepSeek 官方）并暴露为 `pybot_reply` 工具：冷启 25.7s、热回答 0.8–4.0s、RSS 648MB，按 `thread` 缓存记忆，不作为产品能力；真机验收见 `docs/PYTHON.md` | `host/profile-ohos/.../@ohos/dsh-tool-python`、`entry/src/main/ets/common/PythonRuntime.ets`、`entry/src/main/ets/view/PythonHost.ets`、`docs/PYTHON.md` |
| **boot-report / 能力自检** | `@ohos/dsh-boot-report`（ohos profile 专属）：启动 5s 后把已注册工具名与 web search/fetch 就绪写进 `bridge.log`。就绪由 provider 注册表推导（该 dsh **没有** `searchReady()/fetchReady()`）：配置 id 优先 → 按 `dsh-web` 的**路由偏好**（DeepSeek 路由 → `deepseek-official`，其它 → `deepseek-search-api`）→ 最后才是「唯一可用」。0.2.2-rc.5 起基础组合不再钉 `searchProvider`，所以**两个 provider 可用不再算歧义**，按偏好判定即可。`web` 用 `ctx.get('web')` 而非 inject 读取，seam 整体缺失时也要报出来 | `host/profile-ohos/.../@ohos/dsh-boot-report` |

### 2.1 英文口径（对外文案用，勿自创）

一句话定位：**HarmonyGo — a native shell for running DeepSeek Harness locally on HarmonyOS devices.**
（`oh-package.json5` 的 `description` 是另一套同义表述：`native ArkUI client with an in-process Node runtime`。）

展开句：*No WebView, no screen mirroring, no tethering to a computer — the whole runtime lives inside the app process.*

易错译法（每条都是口径错误，不是风格问题）：

- ❌ `native port of dsh` / `dsh rewritten for HarmonyOS` → dsh 未被移植或改写，本仓库只是外壳
- ❌ `spawns a Node subprocess` → 禁 fork/exec，Node 同进程内嵌
- ❌ `offline` → 它要联网调模型 API；本意是「不连电脑」= standalone on-device / no tethering
- ✅ 不套壳浏览器 = `not a WebView wrapper`；不投屏 = `no screen mirroring`

## 3. 架构口径（四层关系）

1. **依赖**：AI 能力 100% 来自 npm dsh；`assemble-payload.mjs` 装配为载荷随 HAP 分发。
2. **运行**：同进程内嵌，不是子进程。出局的只是「宿主 spawn dsh」这一形态（禁 fork/exec）；
   **ACP 服务器本身进程内可跑**（2026-10-26 spike 实测：PassThrough 劫持 stdio + `runCli()`，
   零 spawn，`docs/SPIKE-ACP.md`）。出厂默认仍是 SDK，但**首启引导**会让用户在第一次启动时选一次
   （ACP 有流式/审批/纯 JS 搜索/密钥热更新；SDK 是兼容模式）；答案落 `preferences` 的
   `profile` + `profile_prompted`，只问一次，之后在设置里切。
3. **集成点**：全部集中在 `host/` 适配层（bootstrap / fetch-shim / undici 别名 / 装配期补丁 /
   `profile-ohos` 自定义 profile 模板），不改 dsh 源码。
4. **版本耦合**：协议契约是实测所得（2026-10-25），写死在 `DshClient.ets`；dsh 升级若改协议，此处假设即失效。

## 4. 协议口径（以 `model/Protocol.ets` + `DshClient.ets` 为准）

**两条 profile 并存**：`DSH_PROFILE=sdk`（出厂默认，真机验收过）/ `acp`（首启引导推荐，真机闭环）。
桥本身与 profile 无关——两者都是 newline-delimited JSON-RPC over stdio，差异在方法集。

### 4.1 SDK profile（默认路径）

客户端 → 服务端 **5 个请求**：

| 方法 | 语义 | 超时 |
|---|---|---|
| `initialize` | 固定 cwd/provider/model；**必须等到它的响应后才能发 prompt** | 180s |
| `session/prompt` | 入队回执（不是答案）；未知 id 懒创建 agent | 30s |
| `session/resume` | 从 .zstd 日志恢复服务端上下文；日志按 id 全局查找 | 30s |
| `session/working-directory/set` | 换会话 cwd；目录必须已存在；持久化进日志、resume 后依然生效 | 30s |
| `shutdown` | 排空退出 | 10s |

服务端 → 客户端 **4 个通知**：`session.event`（全运行时会话，客户端按 sessionId 过滤）、
`session.status`（running/idle）、`subagent.started` / `subagent.finished`。

实测契约（勿凭直觉改）：

- 事件信封 `{type, seq, time, data}`，**字段在 `data` 下**（读扁平结构 = 永远空列表）。
- 空 `reasoning` 块很常见，渲染必须跳过。
- 会话打开策略（`Index.ensureSessionOpen`）：先 `resume`（"not found" 静默落新建路径）；
  非默认项目在首次 prompt 前先 `working-directory/set` 指向项目 workspace。

### 4.2 ACP profile（`DSH_PROFILE=acp`，首启引导推荐；设置里切后需重启）

客户端 → 服务端：

| 方法 | 语义 |
|---|---|
| `initialize` | `{protocolVersion:1, clientCapabilities}`；**可重复调用**（重连后再发一次不会报错） |
| `session/new` | `{cwd, mcpServers}` → **服务端生成 sessionId** + `configOptions` |
| `session/list` | 只返回**已关闭/已持久化**的会话；活跃会话不在其中 |
| `session/resume` | `{sessionId, cwd, mcpServers}`；**对活跃会话报 `session is already active`** |
| `session/close` | 关闭后该会话才进入 `session/list`，之后可 resume |
| `session/prompt` | `{sessionId, prompt:[{type:'text',text}]}` → `{stopReason}`（`end_turn` / `cancelled`） |
| `session/set_config_option` | `{sessionId, configId, value}` → 返回**更新后的 configOptions**。`configId` 取 `model` / `reasoning_effort` |
| `session/cancel` | **通知，不是请求**（无 `id`，无响应）。发出后当前轮的 `session/prompt` 响应变为 `{stopReason:"cancelled"}` |

服务端 → 客户端：通知 `session/update`（`agent_message_chunk` / `agent_thought_chunk` /
`tool_call` / `tool_call_update` / `usage_update`），以及**服务端发起的请求**
`session/request_permission`（**snake_case，不是 ACP 规范的 `requestPermission`**）。

ACP 实测契约（勿凭直觉改）：

- 审批选项固定两键：`allow-once` / `reject-once`，应答
  `{outcome:{outcome:'selected', optionId:'allow-once'}}`；答错/空应答 → 工具 `failed`（fail-closed）。
- **方法名全部是 snake_case，不要按 ACP 规范猜 camelCase**：`session/setConfigOption`、
  `session/set_model`、`session/set_mode` 实测均 `Method not found`；`session/cancel` 若作为
  **请求**（带 id）发送同样是 `Method not found`，它是通知。
- `session/set_config_option` 的 `value` 对 `model` 是**JSON 数组字符串**
  （`'["deepseek-official","deepseek-v4-pro"]'`），不是对象；传错会静默不改。
- **set_config_option 后选项集会收缩**（真机实测）：切到 `deepseek-flash` 后
  `deepseek-v4-flash` 从选项中消失，切回被 `-32602 unknown model option` 拒绝。响应里的
  `configOptions` 是**新的权威列表**，选择器不得缓存旧列表；默认模型一旦切走，该会话无法
  切回（唯一途径是新建会话）；`-32602` 是「选项已不可用」，不是传输错误。
- 帧必须带 `"jsonrpc":"2.0"`：缺失时预校验直接回 `-32600 Invalid request`（`id:null`，
  data 回显原帧），到不了方法分发。
- **断线重连**：桥保持流不关闭，重连后 `initialize` 幂等，**直接对旧 sessionId 发 prompt 即可**；
  不要 resume（会撞 `already active`）。
- **断线时正在跑的那一轮**：服务端继续跑，且 `session/update` 会投给新连接；但原 `session/prompt`
  的响应**永久丢失**，且 update 帧里没有 turn/message id，无法关联——**客户端无从判断它何时结束**。
  因此重连应走「重置语义」：`initialize` → `session/close`（掐掉孤儿轮）→ `session/resume` →
  把那条消息标为「已中断」让用户决定是否重发。细节见 `docs/SPIKE-ACP.md` §11。
- `configOptions` 是模型列表的权威来源，客户端不要硬编码模型。
- **权限三档（dsh 具名预设，沙箱+审批捆绑）**：`DSH_PERMISSION_MODE` = `read-only` /
  `workspace-write`（默认）/ `danger-full-access`，审批策略 `=== 'danger-full-access' ?
  'never' : 'ask'`。read-only：裸写先被沙箱拒（无审批请求），agent 带
  `sandbox_permissions`+`justification` 重试才触发审批；workspace-write：工作区内直写、
  越区升级才问；danger-full-access：全放行零审批（三档均真机闭环）。
- **档位随会话创建固化**：会话创建即写 `permission/preset`、`sandbox/mode`、
  `approval/policy`；切档需重启 App（env 启动期）且只影响新会话。
- **完全不答审批 → turn 无限挂起**（failopen 探针实测 10+ 分钟无决定、文件不落盘），
  非工具 failed；服务端无自动放行。
- **跑动中不能发第二条 prompt**：`session/prompt` 在 inflight 时被服务端拒绝
  （`a prompt is already in flight for this session`，`packages/acp/acp/src/session.ts`），
  ACP 没有 steering 通道 ⇒ **「插话」在 ACP 下不可得**，客户端只能排队、回合结束
  （含 `session/cancel` 触发的 `cancelled`）后续发。别按 dsh-go 的 Web API 语义实现插话。
- 该 profile 下 **`bash` 根本没有注册**（平台补丁把 `tool-bash` 设为 `disabled: true`，`--dump-config` 可验），
  模型如果照着自己的习惯去调，拿到的是 `unknown tool "bash"`——不是「命令执行失败」，别按「无 exec 所以失败」理解。
  同理 `~/.git-token` 这类家目录路径在沙箱外，`glob`/`read` 会报 `escapes the session workspace` / `not found`。

## 5. 平台硬约束（六条，各有对策）

| 约束 | 对策 |
|---|---|
| 禁 fork/exec | 同进程 Node；无 `git`/`rg` 等二进制工具面 |
| `node::Start` 每进程一次 | 崩溃即终态，UI 明示重启应用 |
| jitless ⇒ 无 WebAssembly | `fetch-shim.cjs` + undici ESM 别名 |
| 原生 `.node` 模块不可用 | 装配 `--ignore-scripts`，koffi 等不进载荷 |
| 文件系统禁 hardlink | `installLinkFallback`（copyFile COPYFILE_EXCL） |
| 零受限 ACL 安装 | 默认 `--jitless`，无 JIT 权限也能跑 |

## 6. 环境与版本口径（易混点，统一说法）

- **内嵌运行时 Node = v24.2.0**（libnode.so，设备端 `bridge-status.json` 的 `node` 字段）。
- **本地装配/测试 Node = PATH 上的 `node`**（这台机器是 homebrew 的 **v25.9.0**；DevEco 自带
  `…/tools/node/bin/node` = **v24.14.1**，跑「与设备同大版本」的验证时用它）。**设备内嵌 v24.2.0**。
  三个数字并存不是笔误；`scripts/*.sh` 没有钉 PATH，用的是调用者环境里的 node。
- dsh **0.2.2-rc.5**（钉在 `scripts/assemble-payload.mjs` 的 `PINNED_DSH_VERSION`，**默认不再解析 `latest`**）；载荷 zip ≈**240MB**（剪掉 332MB 外国平台包后），**解包后 ≈1.4GB**；HAP ≈**388MB**（unsigned，2026-11-25 构建）；桥端口 4517。
- `hdc` 不在 PATH：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`。
- **设备身份（两台，按型号区分，别混）**：
  · **平板** HUAWEI MatePad Mini 悦读版 —— `model` = **MLR-AL00**、`devicetype` = **tablet**、
    API 26、2560×1600，走 ≥840vp **双栏**；本文件绝大多数历史验收在它身上。`wm size` 在它
    shell 里不可用（`inaccessible or not found`），分辨率从 `param`/`hidumper` 取。
  · **手机** HUAWEI Mate 90 Pro Max 典藏版 —— `model` = **CMM-AL10**、`devicetype` = **phone**、
    HarmonyOS 7.0.0.111、1320×2848，走 <840vp **单栏**（2026-11-23 起用它验单栏形态、
    分享面板与设置面板）。
  **单栏只在手机上验过、双栏只在平板上验过**；旧记录里把平板写成「手机」的是笔误
  （当时没跑 `param get const.product.devicetype`），以本条为准。
- **序列号不进本仓库**（§8.5）：需要用序列号定位设备时记在本地记忆或命令行现场查
  （`hdc list targets`），本文件只按「型号 + 形态」识别设备。
- 设备侧文件路径两种视角同目录：hdc shell `/data/app/el2/100/base/<bundle>/haps/entry/files/…`
  ⇄ App 内 `/data/storage/el2/base/haps/entry/files/…`（`context.filesDir`）。

## 7. 当前状态（2026-11-20）

**验收记录与踩坑日志搬到了 `docs/STATUS.md`**——那里按时间倒序逐条记「哪台设备、哪次构建、
验了什么、代价多大、犯了什么错」。本文件只管**口径**与**现在的结论**。新增验收记录写进
`docs/STATUS.md`，并在这里的摘要行补一句；两处同一 commit。

### 7.1 现在真机跑通的东西

| 域 | 状态 |
|---|---|
| 运行时 | 同进程 Node **v24.2.0** + dsh **0.2.2-rc.5** + `ohos` profile：**十一个自研插件**（含 `html`、`office`、`python` 与 `ontology`），boot-report 实测 `tools(33)`（Python 开启时；关闭时 31） |
| 双 profile | SDK 5 方法（兼容路径）/ ACP 9 方法（首启引导推荐）；首启问一次，答案决定当次启动 |
| 对话体验 | 流式气泡 + 思考折叠 + 工具轨迹、插话队列、待办条 / 目标条、上下文小环、重新回答、完成摘要；**模型与思考深度在顶栏**（会话级设置，不占输入框）；输入行是 `[语音][输入框][上下文环][图片][发送]` —— 输入框里不再叠任何控件，长文本不会被按钮遮挡 |
| 记忆回执 | 新会话/硬约束变化时，回复下显示「本轮新带入 N 条记忆」，点开显示谓词 / 值 / 来源 / 日期（读 `injections.jsonl`）；ACP 在 settle drain 后 attach，2026-11-25 手机 CMM-AL10 截图验成 |
| 上下文洞察 | 点输入框右侧小环 → 原生面板：窗口占用、系统/工具/消息组成、前缀缓存命中、最近 12 轮；`@ohos/dsh-context-ledger` 写 `<dsh-home>/context-ledger.jsonl`（只记计数）。真机 CMM-AL10 验成：会话累计 83.6k/1.0M、缓存 95%（最近 3 轮），force-stop 重进数据仍在，返回键关面板 |
| 会话管理 | 列表 / 标题与内容搜索、置顶、归档、多选批量归档、未读标记、每轮用量账本、详情页、导出；**长按菜单三处统一**（会话 / 消息 / 文件行都是 `bindPopup` 自定义浮层，锚在被按元素上，危险项独立成区） |
| 文件与产物 | 预览（网页 / 图片 / 文本）、`@` 引用、图片存相册、分享卡、导出 Markdown；**长按文件 → 分享到其他应用**（系统 ShareKit，类型先查 UTD、查不到落静态表）；**HTML 产物可导出为整页长图 PNG 或单页 PDF 再分享**（`webPageSnapshot` + 整页绘制开关，真机验成）；**网页由 `html` 工具从内置 A2UI 组件库拼装**（components → create → fill → check，真机端到端验成；**项目默认主题存 `.dsh-html/presets.json`、图表可由 CSV/JSON 直接生成**）；**导出菜单多一项「导出长图（亮 + 暗）」**（强制 data-theme 各截一张整页长图，真机验成：1323×2451 两张，暗底 #14140f / 亮底 #f7f7f5）；**生成的网页不再自带「打印」按钮**（平台说明写进 seed 的 `AGENTS.md`，模型不再生成 `window.print()` 按钮；打印需求走预览页的导出）；**项目文件同步 + 会话同步**（manifest + 分片 + staging 原子落盘 + 配对码；TCP 经 `hdc fport` 与宿主机对端双向验成；**星闪（NearLink）双机端到端验成**：手机 → 平板 17B 文本 + 40000B 二进制完整落地，两端用例 4/4，见 `docs/PROJECT-SYNC.md` §4/§6 与 `docs/STATUS.md` 2026-11-23 条） |
| 本机 gate | 问候/身份/感谢/告别由 `LocalGate.ets` 精确匹配，`dispatchSend` 直接回本机消息并标 `本机规则`，不开 dsh session、不调用云端模型；任务型/带附件消息不拦截；LocalUnit 8 组（问候/身份/感谢/告别/帮助/时间日期/四则运算/不吞任务），真机验成（`1+1 = 2` + 本机规则标记） |
| Python（实验） | **spike**：内嵌 Pyodide 3.13 + numpy/pandas；`python_run` 可跑 pandas groupby、经 `files` 读工作区 CSV；Worker 超时重启；`pybot_reply` 按 thread 记忆；后台会冻结、无输出文件桥、无 CSP/禁网；**默认关闭**，Settings 开启后重启才挂载。详见 `docs/PYTHON.md` |
| Office | **生成/读取 `.docx` / `.xlsx`**（`office_write_docx` / `office_write_xlsx` / `office_read`，纯 JS ZIP+OOXML，零原生/零 WASM），**App 内原生只读预览**（解包 + ArkTS 解析 + ArkUI 渲染；docx 标题/段落/列表/表格/强调，xlsx 工作表/列字母/行号/数字右对齐/日期）；旧格式与 `.pptx` 明确不支持并引导分享到系统 Office/WPS；真机验收 2026-11-23（手机 CMM-AL10），详见 `docs/OFFICE.md` |
| 输入与外观 | 语音输入 / 朗读（**离线引擎真机验成**：识别引擎加载模型、朗读出声；`CreateEngineParams.online` 必须是 `1`=离线，写 `0` 会以 `1002200001` 失败）、六套主题色、外观三档、对话字号四档 |
| 沙箱与审批 | 四层沙箱 + 权限三档（只读 / 平衡 / 宽松），三档均真机闭环 |
| 联网与仓库 | `web_search` 走服务端 Messages 搜索；`git` 纯 JS clone/snapshot/pull/log/diff/status/**commit**/**push**（父链自解析、`force` 重置、传输中途限流、跟随设备系统代理），真机端到端走过超时重试；`push` 的 token 在设置页填，写 `dsh-home/.git-token`（**不进 env**；0600 收紧未证实，见 STATUS） |
| 稳定性 | 断线重连 120s 退避实测夺回客户端槽位；崩溃即终态（`node::Start` 每进程一次） |
| 存储 | 设置 → 存储：安装包 / 应用数据（含缓存）/ 缓存 + 明细（payload、sessions、workspaces、cache）；2026-11-25 手机 CMM-AL10 最终版截图复核：安装包 390.3MB + 应用数据 1.72GB = **2.10GB**；解包成功后删除沙箱 `payload.zip`（**−229MB**，老副本在下次启动幂等清理）；「清理缓存」「重建载荷」入口就位 |
| 品牌 | 闪电标记的横杠是**平行四边形**（斜边与闪电肩线同角，`logo.svg` / `bolt.svg`）；四张位图图标由 `scripts/make-mark-icons.py` 从同一份几何生成，改标记必须重跑（2026-11-23 前它们一直是旧胶囊版，见 STATUS） |

### 7.2 没成 / 卡在平台上的

- **系统通知不出卡片**：hilog 给的是 `invalid creatorUserId: 100`（当前用户 101），公开 API 没有
  这个字段可覆盖——设备的用户态问题。换单用户设备、并补 `notificationSlotType` 再验。
- **自动化任务（schedule）不可行**：缺宿主 `session-controller` 服务（32 个 peer 依赖，含整套
  HTTP 面），不是补个插件能补的。
- **ACP 无 steering**：跑动中不能插话，只能排队或 `cancel`（§4.2）。
- **端侧 OWL 推理不可行**：OWL 2 DL 要 Java（HermiT/ELK）或 WASM（Konclude），设备无 JVM、禁 fork、`--jitless` 无 WebAssembly；本体只导出 Turtle，不做推理。
- **本体无静态加密**：`node:sqlite` 没有 SQLCipher，只有应用沙箱 + 0600 文件；要加密只能改 ArkTS `relationalStore`（Node 侧要过桥）。
- **首次运行的 `.credentials.yaml` 是 644**：只能在 Node 起来后收紧，靠下一次启动修好。
  其余已知边界见本节末「已知边界」。

签名口径（开源卫生）：

- 仓库内 `build-profile.json5` 的 `signingConfigs` 为空；真实签名在本地
  `build-profile.signing.json5`（gitignored）。
- `scripts/deploy.sh` 自动处理：检出备份或 `devecocli signature generate` → 构建 → 结束时
  还原无签名版本（trap 兜底；新生成的材料自动存回备份）。
- 调试 Profile 用带 ACL 的试用版 `~/key_taharness/taharnessDebug.p7b`（本地
  `build-profile.signing.json5` 指向它，2026-10-31 起）：老自动签名 Profile 的 `acls`
  为空，而 module.json5 自 03a252d 起声明 `FILE_ACCESS_PERSIST`，空 ACL 的包装不上；
  试用 Profile 与老 .p12 同证书（指纹一致，hvigor 签名链不变）、含该 ACL、绑手机/平板 UDID。
  **2026-11-16 更新**：这条老坑在当前 CLI 上**已不成立**——新手机（SGT-AL10）不在旧 profile 的
  3 个 UDID 里，装机报 `code:9568423 device is unauthorized`；跑 `devecocli signature generate --force`
  后自动生成的新 profile **含 4 个 UDID 且带 `FILE_ACCESS_PERSIST` ACL**（CLI 自己打印
  「You are applying for restricted ACL permissions: FILE_ACCESS_PERSIST」），装上了。
  **所以换新设备时不必再手工找 AGC 加 UDID，先跑这条命令。**
  注意它会把签名内联写进受版本控制的 `build-profile.json5`——装完必须 `git checkout build-profile.json5`。
- 发布签名走 `scripts/build-release.sh`（三步，签名在 hvigor 之外）：`--build-mode release
  --assemble-type assembleApp` 一次构建出未签名 HAP 与 .app → DevEco SDK 的
  `hap-sign-tool sign-app` 以明文密码给 HAP 本地签名（签名链自检用，见下）→ `hap-sign-tool
  sign-app -inForm zip` 给 .app **容器整体**签名（= hvigor SignApp 任务的 CLI 等价），
  `verify-app` 对独立 HAP 与 .app 容器各校验一次。绕开 hvigor SignHap/SignApp 的原因：
  它们只收 DevEco 加密密码（≥32 字符 `000000...` 密文），明文报 `00303116`。材料八字段
  （含明文密码）在 `build-profile.release.json5`（gitignored）。
- **AGC 提交（含测试轨道）只收 App Pack（.app），文件选择器过滤 .hap；且校验的是 .app
  容器签名**——2026-10-31 实测：容器未签名的 .app 被测试轨道 991「非法软件包/未检测」
  拒收，与包内 HAP 是否签名无关。**包内 HAP 本来就该是未签名的**（hvigor PackageApp
  源码实证：所有 `getModuleTargetOutputFileName` 调用都传 signed=false；SignApp 只签
  容器；AGC 分发时再拆包重签——官方 FAQ「其中的HAP包没有签名」说的就是这个设计）。
  上传 `build/outputs/default/<工程目录名>-default-signed.app`（容器已签名；前缀取本地工程目录名，见 `scripts/build-release.sh` 的 glob）。
- **发布 Profile 签的 HAP 平台禁止 hdc 直装**（2026-10-31 真机实测：`code:9568322
  signature verification failed due to not trusted app source`；官方 FAQ「手动签名失败的
  常见问题」场景六——发布证书签名的应用不能通过 hdc 安装运行）。发布包只走 AGC 分发；
  真机装机一律走 `scripts/deploy.sh` 调试签名路径；独立签名 HAP 仅作签名链自检保留。
- 手动命令行构建的合并/还原配方见 `docs/BUILD.md`。

已知边界（诚实清单）：无 token 级流式；无二进制工具（`rg`/`bash` 仍无，`git` 已由纯 JS 插件替代）；密钥若随 rawfile 分发
仅适合自用/内测（优先级：设置页 > `secrets.json`）；**设备端不做图片降采样**——请求图按原尺寸上传
（`sharp` 桩只能直通），由服务端投影到视觉网格，仅影响上传体积，不影响模型看到的内容。

**密钥不得走 env**：`@fellow99/node-bridge` 在启动时把子进程环境 dump 进 `node.log`
（`[node_bridge] env DEEPSEEK_API_KEY=…`）。因此 `NodeHost` 把 key 写成 `dsh-home/.api-key`（0600），
通过 `DSH_KEY_FILE` 传路径，由 `bootstrap.cjs` 在桥打完日志之后赋给 `process.env.DEEPSEEK_API_KEY`。
新增任何敏感变量时沿用这个模式，别直接放进 `env`。

## 8. Agent 工作流约定

1. **顺序**：改 `.ets` → ArkTS 静态检查 `devecocli check arkts [files...]`（**需 CLI ≥ 1.3.10**，
   一次传全部改动文件；旧版 1.3.0/1.3.4 没有这个子命令，只能退到 `devecocli check lint`）→
   `devecocli build` → `devecocli run --skip-build --device <serial>`。构建成功前任务不算完成。
2. **载荷迭代**（仅当 `host/` 或依赖变化才需要）：`node scripts/assemble-payload.mjs`
   （`--skip-install` 可复用 staging）→ 再 build。
3. **部署**：`bash scripts/deploy.sh [serial]`（查设备 → 登录 → 签名缺失时生成 → 构建 → 装+启动，
   结束自动还原签名口径）。CLI 解析优先级：`DEVECO_CLI` 环境变量 > 仓库内 `.deveco-cli-path`
   钉死的绝对路径（gitignored，本机专用）> PATH。**本机装有多份 devecocli，PATH 顺序会漂**，
   需要时 `echo /path/to/devecocli > .deveco-cli-path` 钉死一份。
4. **验证**：`devecocli log`（支持 `--crash` / `--level` / `--bundle-name` / `--tail` / `--follow`）；
   应用内 设置 → 诊断；无头 UI 断言用 `devecocli ui layout|screenshot|click|swipe|text`
   （封装好过手拼 `hdc shell uitest dumpLayout`，后者参数名跨版本变过）。
   本地三段验证（装机前先过一遍，全绿再部署）。**一条命令即可全跑**：
   `bash scripts/test.sh`（= payload 单测 + ArkTS 检查 + LocalUnit + 设备端 ohosTest；
   子集用 `unit` / `arkts` / `local` / `device` / `ui "<自然语言计划>"`）。
   **同一个 `unit` 也在 CI 上跑**：`.github/workflows/payload.yml` 在 `host/**` / `scripts/**`
   变更时触发，`assemble-payload.mjs --skip-pack` 装好钉死的 dsh 后跑六个插件套件 + 一次
   `--dump-config` 行 id 校验。它**不需要 DevEco、不需要设备、不需要签名**——只证明「我们写的
   那部分在钉死的 dsh 上仍然通过」。载荷 zip 与 HAP 都是**构建产物，不进 git**。
   **两个坑写死在脚本里，手工跑时同样要小心**：
   (1) `hvigorw test` 断言失败时**仍 exit 0**，失败只表现为日志里的
   `ERROR: Error in <用例>` —— 不能靠退出码判断；
   (2) 恢复 `build-profile.json5` **只能用 `git checkout`**，用文件备份会把已注入的
   storePassword/keyPassword 写回受版本控制的文件。
   以下是脚本内部各段的原始命令：
   - **单测**：必须在**载荷树内**跑——插件 `index.js` 依赖 `@deepseek-ai/schemastery` 等包，
     只有载荷根能解析，在仓库源目录直接跑会 `ERR_MODULE_NOT_FOUND`：
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-fs-search-js && node --test test/*.test.mjs`（38/38）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ptc-runtime-vm && node --test test/*.test.mjs`（22/22，
     加 `--jitless` 再跑一遍证明无 WASM 路径）；
     `cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-credentials-live && node --test test/*.test.mjs`（8/8）；
    - **配置层**：`DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos --patch .build/payload/patches/ohos.patch.yml --dump-config`
      → `tool-bash`/`tool-pwsh`/`tool-jobs`/`tool-fs-search`/`ptc-runtime` 均为 `disabled: true`；
      `tools` 行 `config.mode: native`；末尾有 `- id: tool-fs-search-ohos`、`- id: ptc-runtime-vm`、
      `- id: credentials-live-ohos`、`- id: time-context` 与 `- id: boot-report-ohos`。
     **`--profile ohos` 读的是 `$DSH_HOME/profiles/ohos`（不自动安装）**：模板变更后必须先
     `rm -rf .build/ohos-e2e/profiles/ohos && cp -R .build/payload/profile-ohos/profiles/ohos .build/ohos-e2e/profiles/ohos`
     再跑 dump，否则读到旧模板出现假阴性。
     同一条命令对 `sdk` profile 会报 `patch: entry "skill-office" not found`——那是**预期噪音**：
     `skill-office` 只存在于 sdk 树，平台补丁两 profile 共用，不要为消警告删该行。
   - **启动冒烟**：`printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}\n' | DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos`
     → 返回 `agentInfo.name = deepseek-harness-acp`。注意用管道喂帧；用 `spawn` 脚本发帧在本机偶发
     零帧（时序问题，不是启动失败）。
5. **安全红线**：`secrets.json`、签名材料、设备序列号不进公开仓库；公开文档不出现密钥；
   发现泄漏立即提醒轮换。
6. **口径同步**：改了协议/架构/流程，必须同一 commit 更新本文件与相关 docs/。
7. **Token 预算**：**无上限**。仓库所有者正在对 agent 做极限测试——不要吝惜 Token，随意花费：
   详细探索、多轮验证、完整取证永远优先于省 Token；宁可多花，不可省略。

## 9. 文档地图

| 文件 | 内容 |
|---|---|
| `docs/STATUS.md` | **真机验收与状态日志**（`AGENTS.md` §7 的证据侧）：时间倒序逐条记哪台设备、哪次构建、验了什么、代价多大、踩了什么坑；新增验收记录写这里，§7 只留摘要与口径 |
| `docs/API-AND-SEQUENCE.md` | **接口清单 + 时序图**：能力域总览（42 文件 / 15.4k 行）、ACP 9 方法与 SDK 5 方法签名、内部模块导出符号表、6 张 mermaid 时序图（冷启动 / 一轮对话 / 审批 / 断线重连 / LAN 直连 / 语音降级）、文档缺口清单 |
| `docs/ARCHITECTURE.md` | **架构权威文本**（2026-11-20 重写）：进程剖面、运行时五条硬事实、宿主适配层三段（含十个垫片与三份 YAML）、SDK/ACP 双 profile 对照与契约摘要、事件渲染映射、沙箱四层、平台约束十条、已知边界。排版版 `docs/on-device-architecture.html`。逐行走读看 `BOOT.md`，协议矩阵看 `SPIKE-ACP.md` |
| `docs/BREAKTHROUGHS.md` | **突破清单 + 代价**：四条判据（平台说不行/无方案可抄/真机闭环/用户可感知）筛出的六件平台级突破——同进程 Node、进程内 ACP、jitless fetch、自定义 profile、三条降级链、可观测性，每件带证据与代价；另含协议契约、方法论、以及诚实的「什么不算突破」。排版版 `docs/breakthroughs.html`（与 `docs/on-device-architecture.html` 同一套设计，后者讲「现在长什么样」，前者讲「哪些是硬啃下来的」） |
| `docs/BOOT.md` | **启动链路走读**：点开图标 → EntryAbility → NodeHost.boot → dlopen/node::Start → bootstrap.cjs 十个垫片 → runCli/profile 挂载；含「哪些脚本在什么时候跑」的分类表与 6 个文件的阅读顺序 |
| `docs/HTML-COMPONENTS.md` | **HTML 组件库（A2UI）**：`html` 工具内置的 **28 个组件 + 令牌/修饰符**清单与可复制片段（含柱状/堆叠/横向/折线/热力图表、可排序分页表格、图与方案卡；快照，权威来源是插件的 `components` 动作），以及「只选组件、观感改令牌」的用法约定 |
| `docs/DEMO-E2E.md` | **三条端到端验收（手工）**：A 生活管家（语音写入本体 → pandas 真算 → HTML → 导出/朗读）、B 故障急救（图片多模态读截图 → 纯 JS git 修提交 → 文件+会话同步到平板）、C 办公周报（Python 汇总 → docx/xlsx 原生预览 → HTML 长图 → 本体 bundle 跨设备）；含前置开关、逐条验收清单、覆盖矩阵与结果记录模板 |
| `docs/LOCAL-GATE.md` | **本机窄意图 gate**：问候/身份/感谢/告别/帮助/时间日期/四则运算的精确规则在 `dispatchSend` 最前面直接回复，不开 session、不调用云端模型、不产生 token；任务型消息不拦截，本地回复带 `本机规则` note；`LocalGateCache` 记 hits/misses 与未命中候选（诊断页），不自动回放模型答案；8 组 LocalUnit，真机验成 |
| `docs/PYTHON.md` | **端侧 Python（实验）**：Pyodide-in-WebView 架构、loopback HTTP、Worker 隔离与超时重启、文件输入桥、pandas/numpy 实测、后台冻结/安全/默认关闭开关/pybot 压测 |
| `docs/OFFICE.md` | **端侧 Office**：为什么自带 Office 栈在手机上不可用、`office_*` 三个工具的输入输出、纯 JS ZIP/OOXML 结构、FileViewer 原生预览的解析与上限、真机验收与已知边界 |
| `docs/CONTEXT-LEDGER.md` | **上下文账本与原生面板**：`@ohos/dsh-context-ledger` 写 `<dsh-home>/context-ledger.jsonl`（系统/工具/消息组成、缓存读写、每轮用量），`ContextPanel` 从输入框小环打开；记录格式、写入约束、已知边界与验收步骤 |
| `docs/ONTOLOGY.md` | **端侧用户本体**：SQLite schema v3（`v_live_fact`/`v_entity_edge`、`source_kind`/`source_ref`/`status`）/ 23 个受控谓词（含义/同义词/例子）/ `ontology` 工具十二动作（含 `propose`、`describe`、`related`、`metric`、bundle 导入、旧画像迁移）/ 时间模型（valid_from/recorded_at）/ `agent/pre-step` 只注入 pinned / `search` 覆盖度与导入冲突 / 设置面板的查看-删除-分享/导出导入/最近删除通道 / OWL 只导出的边界 / 手机 CMM-AL10 真机数据与拆除步骤 |
| `docs/PROJECT-SYNC.md` | **项目同步**：能做什么（文件 + 可选会话 + 本体 bundle，两条传输）、线协议（分帧/manifest/分片/背压/ack）、安全边界（配对码、只写工作区、不覆盖）、TCP 与星闪的真机取证与踩坑、尚未做的（断点续传 / 加密） |
| `docs/BUILD.md` | 构建、签名、装机、排障（含受限环境坑） |
| `docs/ROADMAP.md` | 路线图：ACP 切换评估（流式/审批/取消）等 |
| `docs/PLUGIN-MIGRATION.md` | 客户端插件迁移分级（P0/P1/P2/不迁） |
| `docs/INTEROP-PRODUCT.md` | **互联的产品面**：三条真通道各自创造什么需求与心智（LAN 直连=「递手机」的数字化、中继=实时版分享链接、剪贴板=零门槛兜底）、四条暂缓通道及原因、必须守住的四条产品红线（不装账号体系/默认不监听/收到的内容不自动进对话/说清对方能看到什么） |
| `docs/INTEROP-APIS.md` | **与其他应用/用户通信的能力盘点**：已用的 6 条（TCP 桥/HTTP/ShareKit/通知/Want/Web）+ 可加的 15 条（WebSocket、局域网 TCP、分布式数据对象、BLE/SPP、星闪、RPC、DataShare…）+ 4 条权限卡死（短信/设备发现/通知控制器/悬浮窗）+ 三条落地路线与成本 |
| `docs/DSH-GO-PARITY-V2.md` | **现行**对齐矩阵：以 dsh-go **v1.1.0（`1c465301`，2026-11-15）** 为基准，逐域列 A/B/C + 证据；含硬边界 7 条（终端/网页版/自动化/回放链接/桌宠/图标/手机操控）与性价比排序 |
| `docs/DSH-GO-PARITY.md` | **历史版**（基于 dsh-go 旧快照，无远程/桌宠/插件 UI）。保留作演进记录；结论以 V2 为准 |
| `docs/OPENBITFUN-COMPARISON.md` | **OpenBitFun 对比**（2026-11-24）：以 openBitFun `5946eab1` / OpenBitFun-Mobile `2cf3a4ad` 为基准，逐域对比两种拓扑（主机 agent + 手机遥控 vs 端侧运行时）、HarmonyOS 端（API 21+ / 12MB 源码 vs API 26 / 388MB HAP）、他们接 dsh 的三条路径（ACP agent / IDE 桥 / 静态 adapter）与 A/B/C 可借鉴清单 |
| `docs/MOAT-PLAN.md` | **护城河加深方案**（2026-11-25）：三个主攻（Ontology 2.0 记忆 / Continuity 2.0 多设备 / Artifact Studio 产物）+ 三个地基（Footprint 2.1GB→≤1.8GB、Trust Console 网络账本、MCP/i18n）+ 24 周路线、指标与 kill criteria |
| `docs/OPEN-SOURCE-STRATEGY.md` | **开源策略**（2026-11-25 讨论稿）：MIT 保留、代码/数据/服务边界、BDFL+DCO 治理、插件 SDK 优先于市场、只卖交付不卖数据、90 天合规与发布路线 |
| `docs/PERSONAL-AGENT.md` | 个人 Agent 与卡片演进方案（Agent Pack / CardSpec / 与 Muse 对比）。**§3–§6 的「垂域卡片做进外壳」方向已停**，文首有 2026-11-12 勘误；保留的是可复用的分析（Muse 对比、度量指标、风险表） |
| 垂域仓（不在本仓） | <https://github.com/QtePP/Harmony-harness-game>（私有）。游戏的三层——裁判引擎 `@ohos/dsh-sanguo`、棋盘 `SanguoBoard*`、五个 agent pack——都在那边。**本仓不引用它们**：外壳只提供会话/文件/审批/设置，不认识任何垂域概念 |
| `.workbuddy-ai/memory/` | 本地会话记忆（gitignored，不提交） |

## 10. Skill 路由（UI 设计）

本仓库的 **UI 设计 / 界面改动**任务，动笔前必须先用 `skill` 工具加载两个精选 skill（**都加载，不问**）：

1. `swiftui-patterns` —— 当 **ArkUI 范式与状态管理参考**读（范式映射，不是让写 SwiftUI）；
2. `make-interfaces-feel-better` —— 间距 / 字级 / 阴影 / 动效 / 命中区等**界面细节打磨**。

其余任务（PDF、TDD、onboarding、ponytail 等）的路由查全局路由 skill `dsh-skill-router`。
