# 变更记录

本文件记录值得写下来的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 变更

- **改名 HarmonyGo（2026-11-23）**：产品名 `TA Harness` → **HarmonyGo**（桌面图标名、启动页、对话页标题、
  通知文案、隐私政策、README/CONTRIBUTING 标题）；包名 `com.qtepp.taharness` → `com.qtepp.harmonygo`；
  仓库 `deepseek-harness-harmony` → `harmony-go`。
  **包名一改就是换 App**：新包不能覆盖升级旧包（沙箱数据不迁移，旧包里的会话/密钥/工作区都留在旧 App 里）；
  两者同时装着会抢 `127.0.0.1:4517`——桥是固定端口 + 单客户端，旧包在跑时新包会以 `EADDRINUSE` 起不来，
  所以先 force-stop 或卸载旧包。签名 Profile 绑 bundleName，换名后要重跑
  `devecocli signature generate --force`。构建产物的 `.app` 前缀来自本地工程目录名，
  `build-release.sh` 已改成 glob 取，不再写死。

### 新增

- **`html` 工具：A2UI 组件库写页面（2026-11-23 真机）**。此前网页由模型用 `write` 从零拼，每次重复推理
  排版/配色/移动端，产品上表现为风格漂移、偶发 CDN 外链（离线打不开）与 `window.print()` 按钮（点不动）。
  新工具 `html` 提供四个动作：`components`（16 个组件 + 可复制片段）、`create`（单文件骨架：内联样式、
  明暗两套色、移动端优先、零外链）、`fill`（放进 `<main>` 内容插槽）、`check`（外链/缺 viewport/体积/
  打印按钮/未知 class）。真机验收：模型自己按工具提示生成 9.4KB 页面（stats + steps，0 外链），
  预览正常；插件单测 19 条并入 `bash scripts/test.sh unit`；组件清单见 `docs/HTML-COMPONENTS.md`。


- **HTML 产物导出为整页长图 PNG / 单页 PDF 并分享（2026-11-23 真机）**。Web 预览新增「导出」菜单：
  `enableWholeWebPageDrawing()` + `webPageSnapshot()` 拿整页位图，PNG 直接编码；PDF 不引库，把整页
  JPEG 以 `DCTDecode` 嵌进单页 PDF（页面按原比例，长文保持一页长文档），生成后直接拉起系统分享面板。
  真机验收：健康计划页导出 **1323×16000 / 945KB** 的 PNG 与 **992.25×12000pt / 968KB** 的 PDF，
  文件取回复核、PDF 渲染正常。


- **项目文件同步：整个工作区或用勾选的文件，从一台设备发到另一台（2026-11-23 真机双向验成）**。
  和「互联」的文本消息是两套东西：消息是一行 JSON，一个项目是带二进制文件的目录树。
  新协议在 `common/ProjectSync.ets`：`[u32 headerLen][header JSON][u32 dataLen][data]` 分帧，
  `hello(code/manifest) → accept → file → chunk(32KB) → fileEnd → done`；**一次只有一块在途**做背压。
  接收端**打开「接收」才监听**、显示 6 位配对码（发送端在 hello 里重复，错码直接 deny、零字节落盘），
  文件先写 `cacheDir/sync-incoming/`，全部到齐且大小核对通过后才逐个 rename 进工作区；
  **同名不覆盖**而是列在结果里；跳过 `.git`/`node_modules`/`.hvigor`/`.build`，单文件上限 64MB。
  界面在 设置 › 互联 ›「打开项目同步…」：选项目、全部/勾选、发送（填地址+码）或接收（显示码+地址）、进度。
  真机（手机 CMM-AL10，Mac 做对端、hdc 端口转发跨网段）：设备收 3 文件/200041 字节，
  取回 `random.bin` 的 MD5 与源文件一致；设备发 3 文件/195.4 KB，Mac 端逐文件校验 OK。
  协议与传输已解耦，星闪适配只差 transport；详见 `docs/PROJECT-SYNC.md`。
  **会话也能一起带**（同一轮里补的）：手动勾选会话 → 走独立的 `sessions` 帧（JSON，`raw` 是本地存储的
  原始转录）→ 接收端并入本地会话索引，标题带「（导入）」、同 id 跳过不覆盖、图片不随行。
  真机双向验：设备→Mac 收到 778 字节（3 条消息）；Mac→设备导入后会话列表出现、点开能看到完整对话。
  **传输层现在可换**（同一轮）：协议与传输解耦成 `SyncLink` + `SyncSession`，WiFi 与**星闪（NearLink）**
  是同一协议的两种链路——星闪面板提供「搜索附近设备 / 打开广告等待连接」，分片仍 32KB（端口 MTU 65535）。
  并补了设备内 loopback 回归（`bash scripts/test.sh device` 里 3 个用例）：正常传输查字节数、
  错配对码查「零落盘」。**星闪已双机跑通**：手机 ↔ 平板各跑一半设备端用例，
  17 字节文本 + 40000 字节二进制完整落地，两端 4/4 通过（见 `docs/PROJECT-SYNC.md` §6；
  过程中修掉四个真机坑：发送端建端口、等待 CONNECTED 事件、4KB 分片、接收端 ack 后才挂断）。
  随后修掉第五个（实测发整棵工作区时报 `operation failed`）：**控制帧也要分片**——157 个文件的
  manifest ≈7KB 一帧被星闪拒收，星闪改走 v2 分片 `blob`（TCP 保持 v1 不动），122 文件 + 40KB
  二进制双机 4/4 通过；UI 同时接了星闪日志文件（`cacheDir/nl-ui.log`）便于取证。
  再修第六个：**发送方 100% / 接收方 43% 的卡死**——发送端等 `ack` 超时后吞错断链，接收端还在等尾巴；
  现在星闪必须收到 ack（30s 超时报错）、接收端 30 秒无数据触发看门狗、写入加 4ms 节流；
  1.5MB + 122 文件复测两端 4/4（`RELIABLE` 模式在该设备上会拒 4KB 写，已回退 `BASIC`）。

- **产出的文件可以直接分享给别的 App（长按文件 / 预览页「分享」）**：模型写的文件以前只有两条出口——预览页把它
  当内容看、消息分享卡把它当截图看，想把 `weekly-training-plan.html` 发给微信得先打开再截图。现在
  **项目文件面板长按**任意文件弹 `分享到其他应用 / 打开 / 复制文件路径 / 删除`（目录则是 `展开·收起 / 复制目录路径`），
  **预览页右上角**多了「分享」。类型走 `uniformTypeDescriptor.getUniformDataTypeByFilenameExtension()` 查平台 UTD，
  查空或抛错才落静态表（png/jpeg/pdf/md/html/txt，其余 `general.file`）——类型报错面板会筛掉本该能收的 App
  （PNG 报成 `general.file` 就没有图库目标）。URI **必须**来自 `fileUri.getUriFromPath()`：手拼 `file://` 能构造成功，
  但 `show()` 会以 `IPC data is oversized` 拒绝。沙箱外的文件（用户授权的绑定目录）先复制进 `cacheDir` 再分享——
  那份授权属于本应用且会失效，直接递 URI 会变成「分享成功、对方打不开」。
  真机（手机 CMM-AL10，1320×2848）：面板显示正确的文件名、HTML 类型图标、大小，目标是
  华为分享 / WeLink / 微信 / QQ / QQ邮箱 / 备忘录 / 打印 / 另存为 / 复制 / 小艺帮记 / 添加至中转站。
  LocalUnit 47 → **55**（`FileShare` 8 条：扩展名解析、点号在目录名里、尾点、静态类型表、`nameOf`）。

- **设置页可以填 GitHub Token（`git push` 的凭据入口）**：`push` 早就实现了，但设备上没有 shell，token 无处可放。
  设置页新增 GitHub Token 字段（密码框），存 preferences 并**镜像到 `dsh-home/.git-token`**——`push` 唯一读的路径；
  **不进 env**（`node-bridge` 把子进程环境 dump 进 `node.log`），`bootstrap.cjs` 下次启动把它收到 **0600**
  （ArkTS 没有 chmod）。写入走临时文件 + rename，避免半截 token 被 `push` 读到。
  真机（手机 CMM-AL10）：填假 token → 保存 → `dsh-home/.git-token` 出现且内容一致；冷启后
  `bridge.log` 打出 `key: .git-token tightened to 0600 (was 644)`；清空后保存 → 文件被删除。

- **电脑端接收器可用了，并修掉两个「静默毁数据」的 bug**：`scripts/sync-peer.mjs` 原来只是测试对端，
  现在补成正式电脑端：**路径校验**（`..`、`.`、绝对路径、空段一律拒，与设备端 `resolveInside` 同规则）、
  **staging + 原子换入**、**不覆盖已有文件**（跳过并列出）、`watch` 子命令可预览清单、
  可被 `import` 而不产生副作用（测试可以驱动真实接收器）。
  **两个 bug 都是「报告成功但数据是错的」**，只有查 MD5 才会发现：
  ①`fileEnd` 里 `stream.end()` 是**异步**的，紧接着 `commit()` 就 `renameSync`——文件在被 flush 前
  就被搬走，**收到的每个文件都是 0 字节**（空文件 MD5 `d41d8cd9…`）；
  ②`currentRel`/`declared` 是**共享的处理函数状态**，在异步回调里读取，结果**三个文件全被记成最后一个的
  名字**，前面两个静默丢失。
  修法：`end()` 的回调里再校验磁盘大小、按文件捕获变量，`done` 帧等所有流关闭后才 `commit()`。
  **验证（本机回环，真实收发）**：3 个文件（含 200000 字节随机二进制）大小与 MD5 全部一致；
  错配对码 → `DENIED` 且**写入 0 个文件**；三条穿越路径（`../x`、`/etc/x`、`a/../../b`）→
  接收端 `REFUSED`、目标内外**都没有文件落地**。新增 `scripts/sync-peer.test.mjs` 8 条
  （分帧重组、坏帧不重同步、路径规则、真实接收器上的穿越防御），已并入 `scripts/test.sh unit`。

- **模型目录诊断进了「设置 → 诊断」，并直接显示在模型选择器下方**：`[boot-report] models:` 这行原来
  只在 `bridge.log` 里，用户没 shell 就看不到。现在 `NodeHost.bridgeReport()` 把它读出来，诊断页有
  `--- boot report ---` 段；同时设置页模型列表下方会以小号等宽字显示同一行，这样「列表是空的」
  旁边就有「为什么」。
  **真机验成（手机 CMM-AL10 / `com.qtepp.harmonygo`）**：诊断页读到的正是
  `[boot-report] models: deepseek-official=2, deepseek-account=0`——官方 provider 有 2 个模型、
  账号 provider 没有，这就是「为什么某些 provider 不出现在列表里」的答案。
  **同一轮修掉一个自己的 bug**：`bridge.log` 是**跨启动累积**的，我第一版按「最后 6 行」截取，
  结果诊断页里并排出现了两次启动的记录（03:41 与 03:46 各半套）。改为按 `tools(` 作为每轮起点
  切块、只取最后一块——旧失败才不会读成当前状态。

- **思考深度（reasoning effort）可选了**：`configOptions` 里一直有 `reasoning_effort`（`dsh-acp` 用
  `resolveModelInfo` 的 `defaultEffort` + `efforts` 生成，含「Provider default」一项），但客户端只
  读了 `model`，**这个通道被整个丢掉**——用户只能接受 provider 默认值。现在：`applyAcpConfig`
  一并接管 effort，输入框旁出现短标签按钮（`思考/低/中/高/最高`），点开是完整列表（带说明与「当前」），
  选中走 `session/set_config_option('reasoning_effort')`，**响应里的 configOptions 是权威列表**，
  照旧整份重建。模型不支持 reasoning 时后端不推这个选项 ⇒ 按钮**整个消失**（不留死控件）。
  协议词 `off/low/high` 不直接给人看（与 dsh-go 的 `effortLabel` 同因）。

- **逐 provider 的「为什么没模型」有答案了**：`dsh-acp` 的 per-provider `catch` **把错误对象扔了**
  （只留 `options: []`），随后 `groups.filter(group => group.options.length > 0)` 又把空组**整组删除**
  ——所以客户端收到的 `configOptions` 里，故障 provider **连空组都不存在**，不是「列出来但没模型」。
  纯客户端不可能知道原因。修法在运行时侧：`@ohos/dsh-boot-report` 新增 `describeProviders()`，在
  过滤器之前逐个 `llm.listModels(provider.id)`，输出
  `[boot-report] models: deepseek-official=0, deepseek-account=0` 或
  `id=failed(原因)`（单行、120 字符截断）。本地 runtime 实测已给出真实结论：**两个 provider 都是 0**。
  单测 20 → **25**（计数、保留原因、多行压平并截断、非 Error 拒绝、零 provider）。

- **模型不再硬编码：按 API Key 拉 `GET /models` 再选（并修掉一个不存在的默认 id）**。根因有两个：
  ①`AppConfig.MODEL` 写死 **`deepseek-v4-flash`**，而 dsh 的 provider 目录里只有 **`deepseek-flash`**
  （DeepSeek-V4.1-Flash，唯一 inputModalities 含 image 的）与 **`deepseek-v4-pro`**——SDK profile 的
  `initialize` 一直在送一个 provider 不认识的 id，设置页还把它显示成「当前模型」；
  ②设置页「模型」是**自由文本框**，没有校验、没有来源，谁也不知道账号实际能用什么。
  现在：新增 `common/ModelCatalog.ets`，用保存的 Key 请求 **`https://api.deepseek.com/models`**
  （与 dsh 自己 `new URL("/models", origin)` 同一端点），设置页显示「刷新列表」+ 真实清单（名称 /
  说明 / id / 「当前」），选中即写入；打开设置时若已有 Key 会自动拉一次；拉取失败**保留原有选择**
  （列表是用来帮人选的，不该变成新的锁死方式）。默认值改为 `deepseek-flash`，只在拉取成功前兜底。
  `modelsFromBody()` 是纯函数，4 条单测（名称回落 id、无 id 丢弃、重复去重、空/坏 body 返回空）。
  **边界**：列表来自账号，不是随包发布；ACP 的会话内选择器仍以 `configOptions` 为权威（两者一致）。
  **旧值会被改写**：`deepseek-v4-flash` 当过出厂默认，那段时间点过「保存」的设备 preferences 里都留着它；
  `AppConfig.load()` 现在用 `normalizeModelId()` 把它规范化并**回写一次**，所以老用户升级后第一次启动就换掉，
  `initialize` 不再送这个 id（`save()` 同样规范化，避免旧值被再写回去）。`normalizeModelId` 另有 2 条单测。
  真机实证（同一台手机）：临时构建把 preferences 写成 `deepseek-v4-flash`（模拟老用户）→ 装正式构建 →
  启动后 `dsh_settings` 变成 `deepseek-flash`；设置页选 `deepseek-v4-pro` → 保存 → preferences 变
  `deepseek-v4-pro`；再选回 flash → 保存 → 落盘为 `deepseek-flash`。

- **`push` 修两个真 bug（真 token 直连验成）**：①推**新分支**必须 `force: true`，工具此前没传，
  于是只能推远端已存在的分支；②`push` 一个「远端有、本地没有」的 ref，js-git 在联网前就抛
  `NotFoundError: Could not find <ref>`——读起来像网络故障，其实是本地没有该分支。现在先
  `listBranches` 预检，报 `GIT_NO_LOCAL_REF` 并列出本地分支名。真 token 直连验证：推探针分支
  → `ok:true`，GitHub API 侧确认分支存在，随后删除（`204`/`404`）。单测 47 → 49。

- **GitHub token 可在设置页填，`push` 能读到（真机验成）**：新增「GitHub Token（用于 git push）」输入框，
  存 preferences 并镜像到 `dsh-home/.git-token`。设备实证：输入 → 点「保存」→ `stat` 到
  `.git-token` 23 字节、内容与输入一致。`readToken()` 补 4 条单测（优先 `.git-token`、回落
  `.api-key`、空白文件继续找、都没有返回空）。**未验证**：真实 token 的 push 成功（手上是假 token）。
  **一处存疑必须写明**：`bootstrap.cjs` 打了 `git-token tightened to 0600 (was 644)`，但 `stat` 仍是
  **644**；同一段代码的 `.api-key` 是 600。`chmodSync` 可能对某些文件静默无效，故**不再宣称 0600**，
  记为待查（影响有限：沙箱按 uid 隔离）。
- **设置面板把「保存」挤出屏幕（真机发现）**：加了 token 字段后内容变长，`SheetSize.LARGE` 只给到
  约半屏，`保存` 落到面板下沿之外，且面板不滚动 ⇒ **按钮不可达**，不是「看不见」而已。改为
  `height: '92%'`。中间试过「滚动区 + 底部固定操作栏」，反而把滚动区压到约 190px，已回滚并在注释里
  写明，免得后人重犯。**UI 自动化三个坑**（详见 STATUS）：`ui layout` 默认只 dump 底层窗口（模态盖住
  时坐标全错，必须 `--all-windows`）；软键盘弹出时面板只有 1606 高且手势只改尺寸不滚动；只有
  `ui drag` 能可控滚动（`swipe` 滚不动、`dircfling` 会过头）。

- **`git` 的 `force` 与 `HEAD~1` 已真机验成（失败路径优先）**：`snapshot`（2.0 MB / 8.7s）→
  `clone` 一个不存在的仓库 `force=true`（传输失败）→ `status` 仍报 `clean (164 paths)`（快照没被动）→
  `clone force=true`（4.4 MB / 13.0s）→ `diff` 不传 `base`/`head` 得到 `4 paths changed in
  HEAD~1..HEAD`。设备 `repos/` 无 `.incoming` 残留、无 `.git/shallow`。

- **`git` 新增 `commit` 与 `push`（八个动作）**：此前只能读，模型改了 `repos/<slug>` 里的文件也存不进去。
  现在 `commit` 走 `statusMatrix` → `add`/`remove` → `commit`（删除要 `remove` 而不是 `add`，
  否则只提交索引里的旧状态）；`push` 走 `git.push` + `onAuth`/`onAuthFailure`。
  **两条安全口径**：①`commit` 只暂存**仓库内**路径，`guardPaths` 拒绝 `..`、绝对路径、`a/../../b`
  ——`write`/`edit` 能写到工作区任意地方，这是唯一栅栏；②token 只从 `<dsh-home>/.git-token`
  （或已有的 `.api-key`）读，**绝不进 env**——`node-bridge` 会把 env dump 进 `node.log`。
  无 token 时先报 `GIT_NO_TOKEN` 并说明该放哪个文件，而不是等 GitHub 回一个裸 403。
  实测（真实 clone + 真实 js-git，`--jitless`）：改文件 + 新增文件 → `commit` → 工作树 clean、
  日志 2 条；删文件 → `commit` → 同样 clean；三条越界路径全部 `GIT_BAD_PATH`；嵌套路径放行。
  单测 38 → **43**。

- **`git` 跟随设备的系统代理（不再假设能直连 GitHub）**：平板上确实能直连（`github.com` →
  `20.247.166.64`，92–182ms），但这不是保证——同一天就撞过两次超时。而 HarmonyOS 只把系统代理暴露
  给 ArkTS（`connection.getDefaultHttpProxy()`），Node 完全不知道它存在，`http.js` 也不认代理，于是
  「用户在设置里开了代理」对 `git` 毫无作用。现在：ArkTS 读系统代理 → `DSH_HTTPS_PROXY` 环境变量 →
  `proxyFromEnv()` → 自建 **`ProxyTunnelAgent`**（CONNECT 隧道 + 端到端 TLS）。**零依赖本机**：
  平板自己就能走代理，Mac 不进链路。实测（本地 CONNECT 代理，`--jitless`）：代理收到
  `CONNECT github.com:443` ×2、克隆成功 2.1MB；死代理与 407 都**立即报错而不是挂起**；
  直连（无代理）仍正常。`bridge.log` 新增一行 `git network: direct|proxy …`，演示时一眼可见。
  **三个踩过的坑**：①请求级 `createConnection` 会被 Node 静默忽略（钩子在 Agent 上），第一版
  「代理支持」因此**从未生效**，而直连恰好能通，测试于是「通过」了——假证据；②`createConnection`
  必须**同步**返回 socket，返回 Promise 会得到 `s.on is not a function`，异步建连只能放 `addRequest`；
  ③socket 尚未 attach 时 `request.destroy(error)` **不触发 error 事件**，请求永久挂起（三条代码就能复现），
  需先挂一个死 socket 再 destroy。`proxyFromEnv` 另有 5 条单测（含拒绝 socks、坏 URL 不抛）。

- **`force` 删了才克隆，一次超时就把唯一副本弄没了（真机发现，严重）**：第一版 `force` 是「先删、
  再 clone」。平板上一跑，GitHub 超时，仓库从 `repos/` 里**彻底消失**，随后的 `log`/`diff` 只能报
  「not cloned yet」。现改为**先克隆到同级临时目录 `.qtepp-<slug>.incoming`，成功后才删旧的再
  `rename`**：失败时旧副本原封不动。本地 `--jitless` 的对照实验（真实 GitHub + 一个不存在的仓库）：
  失败后旧副本仍在（1 commit），成功后换入全量历史（128 commits）且临时目录不残留。

- **`git` 工具：`diff` 在任何仓库上都失败（严重，已被上一轮的「修复」掩盖）**：
  `isomorphic-git` 的 `resolveRef` **不实现 ancestry 语法**——`HEAD~1`、`HEAD^` 在**128 个 commit
  的全量 clone** 上也抛 `NotFoundError`（本地 `--jitless` 实测）。上一轮把「`diff` 默认失败」误诊成
  depth-1 快照的问题，于是加了一条只认快照的守卫，还把「clone 全量历史」当成解决办法——两处都错。
  现在自己走父链（`resolveRev`），并逐步校验父提交确实在对象库里（shallow clone 的 commit 对象
  **记录**父 oid、但父不在库里）。实测：全量 clone 上 `HEAD` / `HEAD~1` / `HEAD~3` / `main` 全部可解析，
  `HEAD~1..HEAD` 给出 4 条真实改动路径；快照上立刻报 `GIT_NO_HISTORY` 并说明只有一个 commit。

- **`git` 工具加 `force`：设备上没有别的办法删仓库**：上一轮的文案让模型「删掉再重跑」，但工具表
  26 个里没有 `rm`、没有 `bash`、没有 shell——模型和用户都做不到。`clone`/`snapshot` 现在接受
  `force: true`，由建目录的人自己删。实测 snapshot（1 commit）→ `force` clone（**128 commits**）。

- **`git` 工具的三处拒绝文案（真机发现）**：设备上让模型自己调这个工具，它把三条错误**原样复述**给
  用户，于是文案的错变成我们对用户说错话。①`GIT_TOO_LARGE` 原来写「needs more than 50 MB」，模型
  读成「事先探测后拒绝」，对用户说「没有下载任何 pack 字节」——实测是真流式中途 abort（5MB 上限下
  在 6,299,474 字节断连，16.5s），现改为 `exceeded the N MB limit after X of transfer … aborted
  mid-stream and the partial tree was deleted`；②`pull` 让人「删了重 clone」而 `clone` 让人「用 pull」，
  对 depth-1 副本是死循环，现在两处各自说清该走哪条（刷新 snapshot / 要历史才 clone）；
  ③`diff` 默认 `HEAD~1` 在单 commit 副本上抛 `Could not find HEAD~1`，像仓库坏了，现在提前报
  `GIT_NO_HISTORY` 并指明显式传 `base`/`head`。三条文案抽成可测函数（`tooLargeMessage` /
  `existsMessage` / `shallowMessage`），单测 20 → 25。

- **验收日志独立成 `docs/STATUS.md`**：`AGENTS.md` §7 长出 37KB 的逐条验收记录后，整份文件
  超过了 agent 指令预算（65536 B），加载时尾部被截断——也就是说「Skill 路由」那一节读不到。
  把**证据日志**（哪台设备、哪次构建、验了什么、代价多大、踩了什么坑）原文搬到 `docs/STATUS.md`，
  §7 只留两张摘要表（现在跑通什么 / 卡在平台上的）+ 签名口径与已知边界等**规则**。
  `AGENTS.md` 66KB → 35KB，规则与历史各归其位；新增验收记录写 STATUS，摘要同步改 §7。

- **`git` 工具（纯 JS，真机闭环）**：`@ohos/dsh-tool-git` 用 isomorphic-git（pako 解析 packfile，
  **零 WASM**）把仓库经 HTTPS 落到 `repos/<slug>`，六个动作 `clone` / `snapshot` / `pull` / `log` /
  `diff` / `status`，之后交给 `glob` / `grep` / `read` 分析。工具表 25 → **26**。
  两条实测约束写进了代码：内存 ≈ 100MB + 11 × pack ⇒ `maxPackMb` 默认 50 且**中途 abort**；
  shallow 仓**不能 pull**（js-git 抛 `TypeError`）⇒ `snapshot` 标只读、`pull` 按名字拒绝。
  HTTP 客户端自己写（`node:https` 流式 + 字节计数），不用 `isomorphic-git/http/web`——后者经
  fetch 垫片会全量缓冲、且进度只报对象数。真机：`clone` 本仓库一次超时后重试成功。

- **`docs/API-AND-SEQUENCE.md`：接口清单 + 时序图**。此前**没有一份集中的 API 文档**，时序图只有
  `ARCHITECTURE.md` 里那段 ASCII 步骤（不可渲染）。本文补上：①能力域总览（9 个域，42 文件 / 15,447 行）；
  ②ACP 9 个方法与 SDK 5 个方法的签名表；③内部模块导出符号表（17 个模块）；④**6 张 mermaid 时序图**
  ——冷启动、一轮对话（含 `settlePersist` 的顺序理由）、审批、断线重连、LAN 直连、语音降级；
  ⑤文档缺口清单（含「`ARCHITECTURE.md` 的协议面已过时」这条）。

- **星闪与数据代理：从「说了没有」改成「真的试一次」**。设置 ›「互联」里多了两个按钮，
  点下去会真的调 API，把返回码原样打出来——因为 `canIUse` 回答的是「系统声明了这项能力」，
  和「这个应用能不能打开它」是两个问题，只有调一次才分得清。
  `probeNearLink()` 走 `@kit.NearLinkKit` 的 `dataTransfer.createPort/destroyPort`（不配对、不扫描）；
  `probeDataShare()` 走 `@kit.ArkData` 的 `dataShare.createDataProxyHandle()` 读自己的共享配置。
  两条都不写数据、不改设置。**`ACCESS_NEARLINK` 是 user_grant/normal**，所以这条通道对三方应用是开着的。

### 修复

- **生成的网页不再带「打印」按钮（2026-11-23 真机）**。模型生成的页面常常自带一个 `window.print()`
  打印按钮，嵌入式 Web 组件不会处理它，点了没反应；而预览页已经有「导出（整页长图 PNG / 单页 PDF）+ 分享」，
  这个入口本来就是多余的。处理：把「生成的网页不要自带打印按钮」写进 seed 的 `dsh-home/AGENTS.md`
  （模型每次会话都会读到），seed 逻辑同时改成幂等追加缺失条目；期间完整实现过的 `window.print` 桥接与
  `ohos.permission.PRINT` 一并撤掉，不留无用权限与死代码。

### 新增

- **用量统计**：每轮的「+N」token 增量现在累计成账本（`model/Usage.ets`，preferences 存
  `dsh_usage`，保留 60 天），设置页顶部显示「今天 +1.2k · 近 7 天 +8.4k」。
  账本**按天、跨会话**——手机上问「今天用了多少」从来不是问某一个会话。
  7 个单测覆盖：首次建行/同日累加、跨日排序、不改入参、delta≤0 只计轮次不计 token、
  只累加最近 N 行、日期补零、大数压缩。

- **载荷升级到 dsh 0.2.2-rc.3**（从 0.2.1-rc.4）。三处真机/本地踩到的坑，都写进了脚本与文档：
  1. **`tools.mode` 被官方删除**：0.2.2 的 schema 是 `z.never()`（"Mount a native or PTC tool
     executor instead"）。我们 bundle 里那行 `tools: {mode: native}` 直接让启动失败
     （`$.mode expected nullable but got native`）。已删掉，改由 base 默认的
     `tool-executor-native` 承担，`tool-executor-ptc` 保持禁用。
  2. **载荷从 225MB 涨到 353MB**：0.2.2 带进 LibreOffice 的 darwin-arm64（159MB）+ wasm（153MB）
     和 darwin 版 sherpa/sharp。这些在鸿蒙上永远跑不起来（原生预编译进不了签名域、jitless 无 WASM）。
     新增 `pruneForeignPlatformPackages()` 剪掉，**332MB → 载荷回到 240MB**。
  3. **剪枝差点剪断启动**：`dsh-subprocess-local` 会**静态 import** `@deepseek-ai/dsh-win32-process`，
     按名字剪掉后启动报「2 required plugins did not activate」。已把该包从剪枝名单移除，
     并在脚本注释里写死「只剪惰性加载/永不加载的包，改完必须跑启动冒烟」。
  验证：`--dump-config` 106 行、`tool-fs-search` 仍禁用 + `tool-fs-search-ohos` 仍挂载、
  本地起 runtime 读 boot-report 得到 **`tools(25)`**（含 `glob`/`grep` 纯 JS 实现，无 `bash`/`job_*`/`run_code`），
  启动冒烟**零警告**、插件单测 fs-search 38/38、ptc 22/22（含 `--jitless`）、credentials 8/8、
  ArkTS 40 文件 + LocalUnit 全绿、HAP 构建通过（352MB）。

- **核对官方 dsh 上游**（`39163dd3` = 0.2.2-rc.3，我们钉 0.2.1-rc.4）：**ACP 协议面未变**
  （9 方法 + `$/cancel_request`、5 种 `session/update`），客户端不需要改。官方 README 明确
  「只暴露标准 ACP v1 面」，并点名 cards/plans/titles/todos/terminal views 不在其中——
  这解释了为什么待办只能从 `tool_call` 反推。载荷比官方少 5 个工具包（agent-team/lsp/office/
  subagent-oar/worktree），但 schedule/jobs/terminal 其实都有，卡的是宿主服务。

- **重做 dsh-go 对齐矩阵（v1.1.0 基准）**：dsh-go 已从单工程长成 monorepo（`app/packages/runtime/sdk/services/market/site/tooling`，
  123 个页面、v1.1.0），旧矩阵过时。新文档 `docs/DSH-GO-PARITY-V2.md` 按九个域逐条对照，
  每条给 A/B/C 与证据，并列出 7 条硬边界。
- **勘误：语音输入不是不可做**。旧文写「SDK 不含 `@kit.CoreSpeechKit`」，实测
  `hms/ets/kits/@kit.CoreSpeechKit.d.ts` 存在，`speechRecognizer` + `textToSpeech` 编译通过；
  语音输入与朗读从 C 级改为 **A 级**。错因：只查了 `openharmony/ets/kits`，漏了 `hms/ets/kits`。

- **自动化任务（schedule）实测判定为不可行**：dsh 自带 `dsh-schedule` + `dsh-tool-schedule`，
  但插进 ohos profile 后 runtime 报 `pending (waiting for service: sessionController)`——它要的是
  `dsh-api-session-controller`（32 个 peer 依赖、含整套 HTTP API 网关）提供的服务。这不是写个
  插件能补的缺口，因此两行已回滚、载荷重打，parity 里该项从「B 级待做」改成「C 级不可行」。
  **这次是先本地起 runtime 看挂载结果，再决定装不装机**——省掉了一次 225MB 的无效装机。

- **本地单测覆盖纯函数模块**：`SecretMask`（遮挡/计数/不误伤 `sk-short` 这类词）、`Typography`
  （档位映射、半磅取整）、`TodoModel`（整表解析、未知状态丢弃、摘要与当前步）、`GoalModel`
  （create / pause / complete / edit、`get_goal` 不改状态）。这些模块的 bug 都是静默的——
  遮错一段、清单解析成空、目标忘了已暂停——所以放进装机前必跑的 LocalUnit。
  **写测试时抓到自己算错**：`scaled(12, 0.9)` 我先写了 10.5，实际 12×0.9=10.8 取半磅是 11。
- **单测补到轨迹分类与回撤路径**：`TimelineNode`（读/写/查/联网/子代理分类、`todo_write` 不算
  「改了你的文件」、未知状态标签留空）、`Rollback`（哪些工具算写、从 XML 式参数里取 `<path>`、
  相对路径按 cwd 解析、**拿不准的标记值宁可不快照**、读工具即便带 path 也不返回）。合计 27 个用例。

- **包名** `com.example.dshharmony` → `com.qtepp.taharness`（`com.example` 是保留域名，
  AGC 不收）。`vendor` 改为 `qtepp`。
- **发布构建脚本** `scripts/build-release.sh`：校验 profile 与 bundleName 一致 → 注入发布签名 →
  `--build-mode release` → `trap` 兜底还原。
- **文档**：README 补首次启动必做两步（填 Key、切 ACP 并重启）、单实例限制、发布签名不能
  `hdc` 直装等边界；新增 `CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、
  `THIRD-PARTY-NOTICES.md`、Issue 模板。

## [1.0.0] - 2026-10-31

首个版本：在鸿蒙设备上本地运行 DeepSeek Harness 的原生外壳。

### 包含

- 原生 ArkUI 客户端，覆盖手机 / 平板 / 2in1，840vp 断点切换单双栏
- 同进程内嵌 Node v24.2.0（NAPI `dlopen libnode.so` + `node::Start`），回环 TCP 桥
- 流式对话、工具轨迹（按功能分类、失败高亮）、产物面板与内嵌预览
- 回合回撤（并还原该轮写入的文件）、会话分支
- 项目隔离（每项目独立 workspace）、多模态图片输入
- API 密钥热更新、权限三档（沙箱与审批捆绑）
- 纯 JS 搜索套件（`glob`/`grep`，替代需要 spawn 的 stock 实现）
- 自定义 `ohos` profile：纯 JS 搜索、PTC 运行时、密钥热更新、时间上下文、能力自检

### 已知边界

- 无 token 级流式；无二进制工具面（`git`/`rg`/`bash`）
- `run_code` 仅支持 JavaScript，且当前默认未启用
- 设备端不做图片降采样，原尺寸上传由服务端投影
- 发布证书签名的 HAP 平台禁止 `hdc` 直装，只能经 AGC 分发

[Unreleased]: https://github.com/QtePP/harmony-go/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/QtePP/harmony-go/releases/tag/v1.0.0
