# STATUS.md — 真机验收与状态日志

> 本文件是 `AGENTS.md` §7 的**证据日志**：每项能力在哪台设备、哪次构建上验过、结论是什么、
> 踩了哪些坑、代价多大。**大致按时间倒序**（新的在上）。
>
> **口径不在这里**：术语、协议契约、平台约束、签名规则都在 `AGENTS.md`（唯一权威）。
> 本文件只回答「验过没有、怎么验的、发现了什么」。新增验收记录请写在这里，并在
> `AGENTS.md` §7 的摘要里更新一句——两处同一 commit 改。

- **记忆回执：本轮移除了硬约束（2026-11-26 09:12–09:21，手机 CMM-AL10）**。
  结论先行：**删一条硬约束不再静默**。原 `agent/pre-step` 只在 `overview.pinned.length === 0`
  时记 `removed`，所以删掉 `language` 而 `name`/`allergy` 还在时完全没有提示；现在比较上一次
  注入的 fact id 与当前 pinned，部分删除也会发一条 removal notice，并继续注入剩余快照。
  真机：同一会话先把 `language=中文` 注入成 3 条基线 → `forget language` → 本轮回复下出现
  **「本轮移除了硬约束」** → 下一轮模型答「语言偏好现在没有记录」。账本行
  `turn=8 step=2 n=2 removed=1`；插件单测 **53/53**。
  证据：`docs/images/screens/21-memory-removal.jpg`。
  边界：removal chip 只在 pinned 集合缩小的**事件轮**出现；删完再开新会话不会重复显示——
  新会话是 fresh baseline，只带剩余 facts 的「本轮新带入 N 条记忆」。
- **本体 v3.1：自动抽取候选 → 待确认队列，双 store import 冲突（2026-11-25 22:20–22:47，手机 CMM-AL10）**。
  结论先行：**模型没调工具的那一句，也能变成候选，但绝不直接生效**。新增 `propose` 动作 +
  `agent/turn-stopping` 的确定性抽取：只认一阶明确句式（我叫/我对…过敏/我住在…/我在做…项目，
  截止…），不调模型、不花 token；`DSH_ONTOLOGY_AUTOCAPTURE=0` 可关。候选写 `status='proposed'`，
  不进 `v_live_fact`，所以不注入、不被 `search` 返回、不参与单值取代；面板「待确认」接受/忽略，
  接受时按 `valid_from` 照常取代或写历史，忽略硬删；候选不随 bundle 同步。
  真机：发「我对芒果过敏。不要调用任何工具，只回一句话。」→ 模型答“暂时还没写进长期记忆”，
  但 turn-stopping 自动写入 `allergy=芒果`（`source_kind='model'`、
  `source_ref='session:fde52b27…'`）；`snapshot.json` 显示 `facts=3, pending=1`；面板顶部
  「待确认 · 1 条」显示芒果卡，点「接受」后变 **4 条事实 / 3 条硬约束 / 0 待确认**，芒果进入 live
  且带“来自该会话”；随后用 `ontology forget` 删除芒果，DB 回到 **3 条 live / 0 pending**。
  截图：`docs/images/screens/14-ontology-pending.jpg`。
  **双机 import 冲突**：当前只连了一台 CMM-AL10，没有第二台物理设备；用两个独立 SQLite store
  模拟双机往返——A 上海、B 北京，A→B 导入报告 `conflict: local 北京 / incoming 上海 / kept 北京`；
  B 改成深圳后 B→A 导入报告 `local 上海 / incoming 深圳 / kept 深圳`，两边 live 都等于较新值。
  单测 **50/50**（含 proposed 排队/确认/忽略/去重、双 store 冲突、自动抽取）。`devecocli build`
  BUILD SUCCESSFUL，deploy Smoke PASS；最终启动 `ontology ready version=13 facts=3`。
  **边界**：自动抽取是规则式，只覆盖 23 个谓词里的一阶明确表达；不做模型抽取、不做指代消解
  （“她对虾过敏”不会自动记到妈妈），也不会替代用户主动说的 `remember`。物理双机冲突仍待第二台设备。
  代码：`lib/auto-capture.js`、`lib/store.js`、`index.js`、`lib/render.js`、`OntologyPanel.ets`、
  `test/auto-capture.test.mjs`、`test/pending.test.mjs`；口径同步：`AGENTS.md` §2/§9、`docs/ONTOLOGY.md`。
- **本体 v3 语义层：谓词目录 / 图遍历 / 指标 / 血缘 / 覆盖度 / 冲突（2026-11-25 21:30–22:10，手机 CMM-AL10）**。
  结论先行：**借 NVIDIA Auto Ontology 的语义层纪律，不换存储**。`node:sqlite` 仍是唯一存储；
  `v_live_fact`（排除 `superseded_by` / `retired_at` / `status='proposed'`）成为“当前事实”的唯一定义，
  `v_entity_edge` 把实体值事实变成图边。工具从 8 个动作扩到 11 个：新增 `describe`（23 个谓词的
  含义/同义词/例子 + 最近邻）、`related`（1–2 跳，节点上限 50）、`metric`（`age` / `days_until` /
  `days_since` / `count`，返回 `rule` 与输入事实）。`search` 返回 `coverage`（exact/partial/none），
  空结果明确说“没记录 ≠ 为假”；`import` 返回 `conflicts`（local/incoming/kept/reason）。
  schema v3 只增量 `ALTER TABLE ADD COLUMN` 补 `source_kind` / `source_ref` / `status` / `confirmed_at`，
  并按旧 `source` 回填 migrated/import；不重建、不丢历史。工具写入的 `source_ref` 取
  `exec.agent.session.header.id`，写成 `session:<id>`；迁移写 `AGENTS.md#user-profile`；
  导入写 `bundle:<file>`。`status='proposed'` 只留给自动抽取候选，当前没有写入路径。
  本机验证：`node --test test/*.test.mjs` **40/40**（新增语义目录、proposed 排除、血缘 bundle 往返、
  `related` 方向、导入冲突、四个 metric）；`node --check` 通过；`devecocli check arkts OntologyPanel.ets`
  0 error（6 个既有 deprecated 警告）；`devecocli build` **BUILD SUCCESSFUL**。
  **真机（2026-11-25 21:47–22:08，手机 CMM-AL10）**：部署后 `ontology ready version=5 facts=3`，
  旧库原地迁移到 schema v3——`PRAGMA table_info(fact)` 已有 `source_kind` / `source_ref` / `status` /
  `confirmed_at`，`sqlite_master` 有 `v_live_fact` / `v_entity_edge`，`meta.schema_version=3`，
  原有 3 条 live 事实（林舟/花生/减脂目标）全部保留。模型实测：
  - `describe allergy` → 返回“硬性安全约束”、同义词“过敏/忌口/不能吃/吃了会不舒服/过敏原”、例子“花生/海鲜”；
  - 说“记住：我妈妈叫王芳，她对虾过敏；我在做 HarmonyGo 项目，截止 2026-12-31” → 6 步写入 4 条，
    DB 里 `source_kind='user'`、`source_ref='session:<会话id>'`，回答还顺带算了“距今 36 天”；
  - `related self` + `metric days_until` → 3 步返回“王芳（妈妈）· allergy = 虾”、
    “我 · works_on = HarmonyGo”“我 · deadline = 2026-12-31”“还剩 36 天”；
  - `search self.employer` → 2 步，coverage=none，模型只答“没有记录。”；
  - 面板「它知道什么」：7 条事实 / 3 个实体 / 3 条硬约束；王芳的虾、截止日、项目、关系显示
    “你告诉它的 · 来自该会话”，旧的林舟/花生显示“它从对话里记的”；面板截图见
    `docs/images/screens/13-ontology-v3.jpg`。
  **验收后清理**：用 `ontology forget` 删掉王芳关系/虾过敏/HarmonyGo/截止日四条，DB 回到
  **3 条 live**（林舟/花生/减脂目标）、5 条软删；没有动旧数据。
  **最终版**只把 `coverage` 也渲染进工具文本（模型能直接看到 `coverage: none`），重新
  assemble/build/deploy；启动 `ontology ready version=13 facts=3 entities=3 pinned=2`，`tools(33)`。
  代码：`lib/vocab.js`、`lib/store.js`、`lib/metrics.js`、`index.js`、`lib/render.js`、`test/semantic.test.mjs`、
  `entry/src/main/ets/view/OntologyPanel.ets`；口径同步：`AGENTS.md` §2/§9、`docs/ONTOLOGY.md`。
- **记忆回执：回复下出现「本轮新带入 2 条记忆」，点开可溯源（2026-11-25 22:26–22:28，手机 CMM-AL10）**。
  结论先行：**注入不再只存在于 prompt 里，用户能在回复下看到它带入了什么、从哪来。**
  插件在 `agent/pre-step` 真正注入 pinned 事实时，往 `<dsh-home>/ontology/injections.jsonl` 追加一行
  `{v,t,s,turn,step,n,removed,f[]}`；客户端在 ACP 的 live row 落定后按「本轮开始 → 回复」时间窗匹配，
  显示 chip；点开显示谓词、值、来源、观察日期。
  真机：新会话问「我叫什么？对什么过敏？」→ 回复「你叫林舟，对花生过敏。」→
  chip **「本轮新带入 2 条记忆」** → 展开 **过敏 / 花生**、**姓名 / 林舟**，来源均为
  「它从对话里记的 · 2026-11-24」。账本行 `s=fde52b27-… n=2`。
  **两个根因（都修了）**：① ACP 没有 SDK 的 `assistant/message` 落定事件，回复是流式写进
  `liveRow()`，最初把 attach 挂在 SDK 事件上 → ACP 永远没有 chip；② `session/prompt` 的响应
  **早于**最后一批 chunk，响应返回时 `liveAssistant` 可能还是 null，真正的回复行稍后 drain 才创建
  → 改为 `settlePersist()` 先 `drainAcpUpdates()`、再 `attachLatestMemory()`、最后 persist。
  证据：截图 `docs/images/screens/13-memory-chip.jpg`、`14-memory-provenance.jpg`；
  插件单测 **34/34** + 本地真实 pre-step 冒烟 **SMOKE PASS**。
  边界：chip 只在**真正注入的那一轮**出现（新会话或硬约束变化），不是每轮都有；
  本次构建之前生成的历史消息不会补 chip；删除记忆后下轮不再带入。
- **存储面板 + 删载荷副本：真实占用 2.10GB，先拿回 229MB（2026-11-25 20:12–20:35，手机 CMM-AL10）**。
  结论先行：**设备上真正的大头不是 HAP，是解包后的运行时（≈1.4GB）**。`Payload.ets` 原来把 rawfile 里的
  `dsh-payload.zip` 复制到 `filesDir/payload.zip` 再解包，**成功/幂等两条路径都没删副本**；本次改成
  「解包成功后删除、失败保留供诊断、旧版本遗留副本在下次 `ensure()` 幂等路径清理」。
  真机验证：重装启动后 `hdc shell ls .../files/payload.zip` 返回 **No such file**；`du -sk payload` =
  **1,507,045 KB**；`storageStatistics.getCurrentBundleStats()`：安装包 **390.3MB** + 应用数据 **1.72GB**
  （其中缓存 209.8MB）= **2.10GB**；dsh-home 8.1MB、workspace 15MB、workspaces 67MB、cacheDir 17.2MB。
  **面板首版踩了一个口径坑**：把 `appSize + dataSize + cacheSize` 相加得到 2.31GB，真机截图后才确认
  `dataSize` 已包含 `cacheSize`；改成 `total = appSize + dataSize`，并把标签写成「应用数据（含缓存）」「其中缓存」。
  第二版（总量/标签修正）与最终版（文案 + 安全删除 + 缓存保护）都已 build + install；中途设备锁屏导致两次
  `deploy.sh` 启动报 `10106102`（不是应用崩溃）。**解锁后最终版启动成功，面板截图复核**：
  **2.10GB** / 安装包 **390.3MB** / 应用数据 **1.72GB**（缓存 **209.8MB**）/ 运行时 **≈1.43GB** /
  会话 6.1MB / workspace 13.0MB / workspaces 63.3MB / 可清理缓存 17.2MB；截图存
  `docs/images/screens/12-storage.jpg`。
  首版截图曾显示 2.31GB / 运行时 1.64GB（缓存被双算）；修正后与实测一致。ArkTS check 0 error、build 成功。
  **没有触发「重建载荷」**（会重解包 1.4GB，留到下次专门验）。
  **重建路径顺手修了一个旧雷**：2026-11-24 记录过 `fs.rmdirSync(payload)` 在 1.4GB 树上
  `remove_all_impl recursion too deep` 崩溃；本轮把 `Payload.reset()` 与版本切换时的清理改成
  `removeTree()`——逐文件 `unlink`、只对空目录 `rmdir`，不再把 9.5 万文件交给平台递归删除器。
  仍**没有真机触发重建**（要重解包 1.4GB），只过了 ArkTS check + build。
  代码：`Payload.ets`（删副本）、`AppConfig.requestPayloadReset/consumePayloadReset`、`NodeHost.boot`（下次启动消费）、
  `StorageUsage.ets`（storageStatistics + 小目录扫描 + 派生运行时）、`StoragePanel.ets`、`SettingsSheet` 入口。
  口径同步：`AGENTS.md` §2/§6/§7、`docs/ARCHITECTURE.md`、`docs/BUILD.md`、`docs/MOAT-PLAN.md`
  （Footprint 目标从 1.1GB 重新校准到 ≤1.8GB）。
- **本体时间模型 v2：valid_from / valid_to / recorded_at / superseded_at + effective_at（2026-11-24 08:14–08:38，平板 MLR-AL00）**。
  结论先行：**状态现在有“现实生效时间”和“系统写入时间”两层**，不只是写入顺序。schema 直接重建
  （用户明确不用保留旧数据）：`fact` 加 `valid_from/valid_to/recorded_at/superseded_at`；
  `remember/correct` 新增 `effective_at`；单值谓词按 `valid_from` 比较——新的取代旧值并关闭旧区间，
  较早的写为历史（`valid_to = 当前 valid_from`、`superseded_by = 当前事实`），当前值不变。
  同步先比 `valid_from`，同 `valid_from` 再比 `recorded_at`；删除用 `retired_at`，删除后重新添加以新 `valid_from` 为准。
  真机：平板让模型显式调用两次 `ontology remember`，`effective_at` 分别为 2020-01-01（上海）和
  2024-01-01（北京）；工具返回第二次 `superseded 1 older value`，面板显示 **1 条事实：北京，2024-01-01 生效**，
  历史里上海 2020 仍在；随后删除北京，面板 **0 条有效 / 1 条最近删除**。单测 **29/29**。
  **部署插曲**：第一次装时间模型构建时，`Payload.ets` 的 `fs.rmdirSync(payload)` 在旧载荷树上崩溃
  （`remove_all_impl` 递归过深），与 schema 无关；清掉 `files/payload` + `payload.stamp` 后重装即恢复。
  旧库被 schema v2 重建，之前测试的删除历史已清空（本次用户同意不保留）。
- **tombstone 删除同步：删除随 bundle 传播，新写入赢过旧删除（2026-11-24 06:54–07:05，手机 CMM-AL10 / 平板 MLR-AL00）**。
  bundle v1 增加可选 `tombstones`（软删事实的稳定身份 + `retired_at`）；导出端把
  `retired_at IS NOT NULL AND superseded_by IS NULL` 的事实带上；接收端先合并活事实，再处理 tombstone：
  本地同身份事实若 `observed_at <= retired_at` 按 tombstone 时间 retire，若更新（删除后重新添加）则保留。
  单测 **26/26**：删除传播、旧 tombstone 不删新事实、删除后重加保留、迁移不覆盖更新值。
  真机：平板 0 条有效 / 2 条已删除时「导出到工作区」仍可用，生成 1.1KB bundle；通过项目同步（WiFi + `hdc fport`）
  送一份 live+tombstone 测试包，导入后仍 **0 条有效**，且「花生」的删除时间从 03:54 更新为 tombstone 的
  **2026-11-24 09:00** —— 证明导入/retire 生效（若 tombstone 被忽略，会留下 1 条 live）。
  **完整双机 NearLink 回环：尝试未完成（2026-11-24 07:41–07:56）**。平板建了 `allergy=腰果` 并导出 bundle；
  平板→手机 NearLink 发送两次（手机接收端 826465 / 167862），发送端 sheet 都回到互联页、手机仍停在
  「等待星闪对端连接」，未收到文件；原因未定位（广告超时 / UI 状态，非 tombstone 逻辑）。测试用的
  live 腰果已删除，两端回到 0 条有效。tombstone 的导出/导入/retire 已由 WiFi 项目同步和 25/25 单测证明；
  NearLink 传输层之前已用 1.3KB bundle 验过，完整删除回环仍需一次成功的「接收端保持广告 + 发送端 60s 内配对」。
- **旧 user_profile 停用 + 迁移器：本体成为唯一写入点（2026-11-24 06:40–06:46，手机 CMM-AL10 / 平板 MLR-AL00）**。
  决定：**停用旧 `user_profile`**（patch 行 `disabled: true`），模型不再写 AGENTS.md 的第二份画像；
  历史受管块用 `ontology action=migrate_profile` 迁移。boot-report 从 `tools(34/32)` 降到
  **`tools(33/31)`**，两端工具表都不再有 `user_profile`，`ontology` 仍在。
  迁移器：默认 dry-run；`apply:true` 读 `<dsh-home>/AGENTS.md` 受管块，逐条映射（姓名/过敏/饮食/语言/城市/关系→受控谓词，
  其余→带日期的 `note`），先写 `AGENTS.md.bak-*`，任一条失败就不清块；用 3 条合成块验证
  `name=林舟`、`allergy=花生`、`note=喜欢简洁的回答`，导入 3 条、清块、prose 保留；审查发现旧画像日期可能覆盖本体里更新的值，已加 `preserveNewer`（迁移时比较 `observed_at`，旧值跳过）并补单测；ontology 单测 **26/26**。
  真机：两端 `AGENTS.md` 的受管块本来都是 **0 条**（1455B 全是用户 prose），所以这次没有历史数据可迁；
  迁移器保留给旧设备/历史块。**未做**：tombstone 删除同步（下一步）。
- **面板「最近删除」：把软删事实还给用户看（2026-11-24 06:20–06:29，手机 CMM-AL10 / 平板 MLR-AL00）**。
  结论先行：**聊天里的「已记住」是当时的回执，删除后不会回头改写；面板现在能证明这条事实曾经写入、什么时候被删**。
  `snapshot.json` 增加 `deleted`（最近 10 条软删，按 subject/predicate/object/qualifier 去重，取最新 `retired_at`），
  面板底部显示「最近删除 · N 条」，默认收起，展开是灰色卡片 +「已删除」徽章 + **本地时间**，并注明「已删除的事实不再注入模型」。
  真机：手机 0 条有效 / **5 条已删除**（测试重复写入去重后），平板 0 条有效 / **2 条已删除**；两端展开都能看到
  「姓名 林舟」「过敏 花生」和本地删除时间（手机 2026-11-24 04:01，平板 03:54）。单测 19/19（新增 deletedFacts 去重/排除 superseded）。
  **边界**：只读历史，不提供恢复/彻底清除；硬删（`hard:true`）的事实不会出现在这里；`deleted` 只取最近 10 条。
- **本体跨设备同步：星闪把 1.3KB bundle 从手机送到平板，导入后新会话记得（2026-11-24 03:33–03:59，手机 CMM-AL10 ↔ 平板 MLR-AL00）**。
  结论先行：**同步的不是 SQLite 文件，是可合并的 bundle**。手机面板「导出到工作区」写
  `workspace/ontology/ontology-bundle-<时间戳>.json`（2 条事实 1.3KB）→ 项目同步只勾
  `ontology` 目录、传输选星闪、搜到「niika的MatePad Mini 悦读版」、配对码 235902 →
  平板接收 **100% / 已接收 1 个文件 · 1.3KB** → 平板面板「导入最新同步包」→
  **2 条事实 · 1 个实体 · 2 条硬约束**；新会话问「我叫什么/对什么过敏」零工具答
  「林舟 / 花生」。两端随后把测试事实删回 0 条。
  合并规则：实体按 name/alias 对齐；只合并活事实；单值谓词按 `observed_at` 新的赢；
  多值追加；重复导入幂等；**删除不传播**（bundle v2 再做 tombstone）。导入成功后 bundle
  改名 `.imported`，避免再点一次把删掉的事实复活。
  **踩坑**：①导出时把 workspace 当成 `dsh-home/workspace`，实际是 `<filesDir>/workspace`
  （`HOME` 的兄弟目录）；②导入路径校验只允许 `dsh-home`，把 workspace 拒了；现在允许
  app files 根下的两类路径。③项目同步「同名不覆盖」⇒ bundle 必须带时间戳。
  **边界**：明文、配对码；不自动导入（同步进来的文件不自动进模型）；导入成功后 bundle
  改名 `.imported`，手机端再次点「导入最新同步包」仍为 0 条（真机复验，未复活事实）；
  bundle 超过 64MB 单文件上限时会被项目同步报出来。设计与合并细节见 `docs/ONTOLOGY.md` §5.1。
- **端侧用户本体 v1：SQLite + pinned 注入 + 设置面板（2026-11-23 22:30–22:51，手机 CMM-AL10）**。
  结论先行：**模型能写、会话能记、用户能删**。`@ohos/dsh-ontology` 用 `node:sqlite` 存
  `<dsh-home>/ontology/ontology.db`（entity/fact/meta），受控词表（23 个谓词）、单值谓词
  supersede、删除软 retire；`agent/pre-step` 只在 pinned 签名变化时注入硬约束；设置里新增
  「它知道什么」全屏面板，读 `snapshot.json`、删除写 `commands/*.json`、分享 `summary.md`。
  真机链路：一句「Remember: 我叫林舟、对花生过敏、不吃辣」→ 模型调用 `ontology`，3 条事实
  （version 3，全部 pinned）；**新建会话**问「我叫什么/对什么过敏，不要调用工具」→ 直接答
  「林舟 / 花生」，无工具调用（注入生效）；面板显示 3 条，逐条删除后空态；删除过敏后新会话
  改答「没有记录，不等于过敏」（删除传播生效）；分享打开系统面板，`summary.md` 420B；
  多次 force-stop 重启事实仍在。`snapshot.json` 为 0600，hdc shell 已读不到（mode 生效）。
  system-prompt section 已注册，但**主动记忆（不说“记住”）未单独验收**，真机测试都用显式指令触发。
  **踩坑**：实现中一次 `deploy.sh` 在旧进程还活着时安装，新进程 `dlopen libnode.so` 报
  `Operation not permitted`；先 `aa force-stop` 再装、或装完重装一次即恢复。**未验/边界**：
  平板（双栏）的面板/导入/注入已验（2026-11-24 同步条目）；无静态加密；`user_profile` 旧区块未迁移；快照上限 400 条、10k+ 行未压测；
  本体同步已接（2026-11-24 条目）。设计与全部真机数据见 `docs/ONTOLOGY.md`。
- **SQLite 探针：`node:sqlite` 在应用进程里跑通 WAL，force-stop 后数据仍在（2026-11-23 21:50–21:52，平板 MLR-AL00）**。
  结论先行：**端侧能用 SQLite**——设备内嵌 Node v24.2.0 的 `libnode.so` 编进了 `node:sqlite`
  （`node_use_sqlite: true` / `_register_sqlite`），`--jitless` 下建 `STRICT` 表、写、查都正常；
  真机 SQLite **3.50.0**。`PRAGMA journal_mode = WAL` 生效，目录里出现 `spike.db-wal`(90672B) /
  `spike.db-shm`(32768B)，force-stop 后重启 boot #2 读到 `facts=2`，WAL 重放成功。
  探针插件 `@ohos/dsh-ontology-spike` 每次 boot 写一条 `spike.boot` 并注册 `ontology_spike` 工具；
  boot-report `tools(32)` 含它（Python 关闭时基线 31）。首开含建表+写+报告 **125–176ms**。
  模型侧也闭环：真机发 prompt 后模型调用 `add`，回 `added one fact (total 3) at
  2026-11-23T13:54:58.141Z`，`facts` 2→3；这一轮暴露报告文件 `recent` 在 `add` 后没刷新
  （`facts` 新、`recent` 旧），已修成写前重新查询（源码 + 构建产物；第二次装机时平板已断开，
  未在真机复验该字段）。
  两个真机发现：①`mkdir(0700)` 落成 **0755**、SQLite 文件 **0644**（与 `.git-token` 的 0600
  同源问题，owner-only 不能只靠 mode 位）；②`node:sqlite` 仍是 experimental，启动打
  `ExperimentalWarning`，不影响运行。**未验**：多连接并发、10k+ 行批量、备份、静态加密。
  代价：一次 240MB 载荷装配 + 一次增量 HAP 构建（约 3s）+ 装机，无新依赖、未改 dsh 源码。
  设计与下一步（工具 / `agent.inject` / AGENTS.md 投影、OWL 边界）见 `docs/ONTOLOGY.md`。
- **本机窄意图 gate：问候/身份/感谢/告别不调用大模型（2026-11-23 22:06，代码+LocalUnit；真机待验）**。
  在 `Index.dispatchSend` 最前面做精确匹配（`LocalGate.ets`）：命中就写用户消息 + 本机回复（note `本机规则`），
  **不开 dsh session、不发 `session/prompt`、不产生 token**；任务型消息（如「你好，帮我写周报」）和带附件消息
  一律落到真实 agent。LocalUnit 新增 8 组用例（问候/身份/感谢/告别/帮助/时间日期/四则运算/不吞任务），覆盖率 **16.9%**。
  **真机验成（2026-11-23 22:17，CMM-AL10）**：解锁后发 `你是谁` / `1+1`，立即出现本机回复并显示 `本机规则 · 未调用云端模型`；`1+1 = 2` 在界面确认。
  dsh session 日志里没有 `本机规则` / `1+1 = 2` / 身份回复。注意并行会话会写同一个 `sessions` 目录，文件大小不能当本 gate 的判据。
  同日补 **规则缓存**：`<filesDir>/local-gate-cache.json` 写入
  `{"version":1,"hits":1,"misses":0,"entries":[{"key":"1+1","count":1,"intent":"math","hit":true}]}`，
  设置 → 诊断的 `--- local gate ---` 显示 hits/misses 与未命中前 5 条；只做候选提示，
  **不自动回放模型答案**。
  此前的「Application process died」是 **17:59 的旧 `THREAD_BLOCK_6S`** smoke 日志 + 锁屏导致的启动失败，
  与本次构建无关。
- **端侧 Python spike：Pyodide 3.13.2 + pandas 在隐藏 WebView 的 Worker 里跑通（2026-11-23 20:00–20:55，手机 CMM-AL10）**。
  结论先行：**“禁 fork/exec”不等于不能跑 Python**——解释器可以像 libnode 一样嵌进进程。
  Pyodide 0.29（CPython 3.13.2）core 约 11.7MiB 放进 rawfile；`resource://rawfile` 不能承载动态
  import / wasm fetch（真机报 `Failed to fetch dynamically imported module`），改由 ArkTS 起
  **127.0.0.1 只读 HTTP server** 提供资产后通过。链路是 1×1 隐藏 `Web` → `javaScriptProxy` →
  `<DSH_HOME>/python/{req,res}` 文件桥 ← `@ohos/dsh-tool-python` 的 `python_run`。
  **两轮迭代的关键教训**：第一版把 Pyodide 放主线程，`while True: pass` 会把整个 WebView（定时器、
  导航、桥）一起冻住，`controller.refresh()` 和换 `src` 都排不进去；改成 **Web Worker** 后，主线程
  用 `terminate()` 掐掉死循环，下一次调用重新加载解释器即可恢复。
  真机数据：`sys.version` + `print(1+1)` 3225ms；`pandas 2.3.2` groupby **7735ms**（含加载）；
  `files:["data.csv"]` → `/workspace/data.csv` → `read_csv` 成功；死循环 `timeout_ms=3000` 3.1s
  返回、下一次正常调用 **2476ms** 恢复；后台 `sleep(20)` 切后台 25s 实测 **40.2s**（仍会冻结）。
  HAP **387MB**（Pyodide core+pandas 375MB；pybot 样本 +12MB）；整进程 RSS pandas **601MB / 680MB**、pybot **648MB / 684MB**（含 Node）；12 个插件单测；默认关闭开关验成：关闭时 boot-report `tools(32)` 且不挂隐藏 WebView，Settings 开启 + 重启后 `tools(34)`、`python_run` 跑出 `opt-in-ok 2`。
  **pybot 压测样本**（Hugging Face / Apache-2.0，非 DeepSeek 官方；12MB zip 内置，`packages: []`）：
  冷启 **25.7s**、热回答 **0.8–4.0s**（`pybot_reply` 工具：answers 777ms / memory_store 4002ms）、
  多轮记忆 `You're Sam.` 成功；冷启 ≤60s / RSS ≤900MB 两个门槛过，热回答在 2–8s 估算内；它不增加 dsh 工具能力，26% 胜率也不适合当离线兜底。
  boot-report `tools(34)` 含 `python_run` / `pybot_reply`。
  **已补**：默认关闭的 Settings 实验开关 + `PythonHost` 门控——关闭时 `tools(32)` 且不挂隐藏
  WebView，开启并重启后 `tools(34)`、`python_run` 跑出 `opt-in-ok 2`。
  **没过的/没做的**：① 输出文件桥（Python 不能写回工作区）；② 5MB base64 压测（只验了小 CSV，
  上限按 8 文件/5MB/15MB 设计）；③ micropip 离线装包；④ CSP/禁网/桥最小权限——WebView 仍可联网，
  脚本可经 Pyodide 的 JS 桥访问 `fetch`；⑤ 后台保活。因此这只是 **spike**，不按产品能力宣传；
  产品化清单见 `docs/PYTHON.md` §6。

- **产物栏不能左右滑动 → Row 的 `width('100%')` 把 Scroll 内容量成一屏（2026-11-23 19:00，手机 CMM-AL10）**。
  现象：产物超过 3 个时第 4、5 个被裁掉，左右滑动没有反应。根因：横向 `Scroll` 里的 `Row` 写了
  `.width('100%')`，Scroll 按一屏宽度测量内容，卡片溢出但没有可滚动范围。修法：去掉 Row 的
  100% 宽，让它按内容撑开；真机用 5 个产物左右滑动，能滚到最后一个 `one-hour-fitness-plan.html`。
- **Office 端侧闭环：纯 JS docx/xlsx 生成 + 读取 + 原生预览（2026-11-23 18:30–18:45，手机 CMM-AL10）**。
  模型按提示直接调用 `office_write_docx` / `office_write_xlsx`，在工作区 `reports/` 生成
  `office-test.docx`（3097B）与 `office-test.xlsx`（2348B），只回复两个路径；产物面板「全屏」打开
  `FileViewer`：docx 标题/正文/表格、xlsx Sheet1（列字母/行号/名称数量、数字右对齐）均正确。
  把设备生成的文件拉回宿主，插件 `readDocx/readXlsx` 读回内容与写入一致。
  验证：`dsh-tool-office` 单测 40/40（含 `--jitless`）、LocalUnit 15.2%、`--dump-config` 有
  `tool-office-ohos`、boot-report `tools(31)`（含 3 个 `office_*`）。
  踩坑：①xlsx 内联字符串是 `<t>` 不是 `<w:t>`，首轮 LocalUnit 失败；②`Scroll` 的单子节点会垂直居中，
  docx/表格要 `.align(Alignment.TopStart)` 才贴顶；③ZIP central directory 的 external attrs 为 0 会让
  `unzip` 解出 000 权限文件，写 ZIP 时必须给 0644；④设备被并行会话占用时 UI 自动化会互相抢焦点，
  验收要固定一台设备/一个会话。
  未验/边界：`office_read` 已由单测 + 设备文件回读覆盖，但未单独让模型在真机上调用一次；PPTX/旧格式
  明确不支持（见 `docs/OFFICE.md`）。
- **星闪传输卡在 43% → 发送端等 ack、接收端看门狗、写入节流（2026-11-23 16:30，手机 CMM-AL10 ↔ 平板 MLR-AL00）**。
  真机现象：发送端显示「已发送 154 个文件 · 3.2MB / 100%」，接收端停在 **43%** 不动。
  根因：发送端把最后一帧 `writeData` 的成功当成传完，`ack` 等 10 秒没到就把错误吞掉并断开链路；
  接收端还在等接下来的字节，永久停在 43%。另外持续高速写会把接收端队列冲爆（BASIC 模式无重传）。
  修法：①星闪链路必须收到 `ack` 才算成功，30s 超时后报「对方没有确认接收完成」；②接收端 30 秒无新数据
  触发看门狗，报「传输中断：30 秒没有收到新数据」；③每次写入后 4ms 节流。
  试过 `TransferMode.RELIABLE`：这台设备上反而拒绝 4KB 写入（`1009700099`），已回退 BASIC。
  复测：设备端用例加到 **1.5MB 二进制 + 122 文件**（约 2MB），两端 `Tests run: 4, Pass: 4`，
  接收端 `files=122 error=[]`，耗时约 13 秒。

- **星闪发送整棵工作区失败 → 控制帧分片修好（2026-11-23 16:12，手机 CMM-AL10 ↔ 平板 MLR-AL00）**。
  用户按操作路径发整棵工作区，界面报「发送失败 operation failed」。真机日志定位：
  `createPort` / `dataTransfer.connect` 都 success，但 **`DataTransfer.WriteData callTimes=4 success=2
  errorCodeCount=2`**——失败的是大帧，不是连接。原因：157 个文件的 manifest ≈7KB，
  星闪一包只吃 4KB，`hello` 帧被拒。
  修法：TCP 保持 v1（manifest 内联在 hello，宿主机对端脚本无需改）；星闪走 v2——hello 只带
  `manifestChunks`/`sessionsChunks`，清单与会话改用 `blob` 分片帧，接收端拼齐再回 `accept`。
  同时给 UI 接了 `setNearLinkLog` 写 `cacheDir/nl-ui.log`（下次失败可直接 `hdc shell cat` 取证），
  并把 `Operation failed.` 的提示改成可行动的话。
  验证：设备端用例扩到 **122 个文件**（其中 120 个小文件把 manifest 顶过 4KB）+ 40KB 二进制，
  两端 `Tests run: 4, Pass: 4`，接收端 `files=122 error=[]`；`arkts/local/device` 全绿。

- **星闪双机端到端跑通（2026-11-23 15:38，手机 CMM-AL10 ↔ 平板 MLR-AL00）**。设备端用例
  `entry/src/ohosTest/ets/test/NearLink.test.ets` 两台各跑一半（`-s role receiver|sender`，
  用 `-s peerName MatePad` 按名字选对端），两端都 `Tests run: 4, Failure: 0, Error: 0, Pass: 4`：
  **手机经星闪把 17 字节 `note.txt` + 40000 字节 `big.bin` 传到平板**，接收端日志
  `receiver finished files=2 error=[]`，`big.bin` 大小 40000 校验通过，会话/分帧/TCP 同一套代码。
  四个真机才暴露的坑（均已修，注释在 `NearLinkSync.ets`）：①发送端必须自己 `createPort`，
  否则 `connect` 报 `1009700099`；②`connect()` resolve 后约 10 秒通道才 `STATE_CONNECTED`，
  早写的帧全丢——发送端改为等事件；③星闪把 32KB 写截成 ~7.2KB 并断链——星闪分片固定 4KB；
  ④最后一帧后立刻 disconnect 会丢尾巴——加 `ack` 帧，星闪发送端等接收端落盘确认再关链路。
  **诊断通道也换了**：hilog 取不到测试进程日志、测试的 `filesDir` 指向不存在的模块目录 ⇒ 改用
  `setNearLinkLog()` 注入写 `context.cacheDir` 的 sink，`hdc shell cat` 取证（关键事实
  「CONNECTED 迟到 10 秒」「7253 字节截断」都是它给的）。
  回归：`bash scripts/test.sh arkts local` 与 `device`（4 用例）全绿。

- **星闪双机：连接握手通了，卡在接收端回帧（2026-11-23 15:10，手机 CMM-AL10 + 平板 MLR-AL00）**。
  在 14:50 那条之后又推进了一层，结论修正：**不是配对、不是地址过期、不是 mtu、不是时序**——
  ① `getPairingState()` 两台都返回 **3（已配对）**；② 同一次 run 内重新扫描，平板地址与上次一致；
  ③ `mtu` 512 与 65535 都报 `1009700099`；④ 20 次 × 2s 重试全失败。
  **真正的缺陷是发送端没建自己的端口**：`createPort(uuid)` 原来只在接收端调用。
  在 `NearLinkSyncLink.connect()` 里补上 `createPort` + `disconnect` 时 `destroyPort` 之后，
  `connect()` **成功**，错误变成 `对方没有回应（可能不在接收模式）`（`waitFor(T_ACCEPT)` 超时）——
  即 SLE 链路已建、hello 已发、接收端没回 accept。
  下一步卡点：接收端 `readData` 没触发（接收端测试仍在等待数据）。这轮没能加诊断，因为测试进程的
  `filesDir` 指向 `haps/entry_test/files`（不存在），`diag()` 的写盘异常被静默 catch；下轮先把
  诊断写到 `context.filesDir` 之外的确定路径，再判断是「接收端没收到帧」还是「收到但 `writeData`
  回不去」。代码改动未提交前已在真机上验证过连接语义，见 `docs/PROJECT-SYNC.md` §6。

- **星闪双机：发现/广告通，`connect()` 卡在地址解析（2026-11-23 14:50，手机 CMM-AL10 + 平板 MLR-AL00）**。
  把星闪对传做成可重复的设备端用例 `entry/src/ohosTest/ets/test/NearLink.test.ets`：用
  `aa test … -s role receiver|sender|scan` 在两台机器上各跑一半（receiver 开端口+广告等 90s，
  scan 只扫并打印，sender 连上去发一个 18 字节文件）。过程中确认了三件事：
  ① `-s` 参数在 `AbilityDelegatorArgs.parameters` 里的键是 **`-s role`** 原样字符串（日志实测 key 列表），
  裸 `role` 读不到——这解释了一开始的「用例 0.2s 就过」；② 扫描真的能找到对端
  （`NEARLINK-PEER 70:1D:79:0D:23:A9 name=niika的MatePad Mini 悦读版 rssi=-57`）；
  ③ 拿这个地址 `dataTransfer.connect()` 直接抛 `Operation failed.`，同时 nearlink_service 打
  `GetEncryptAddr:31 addr is invalid`——扫描地址是解析/加密过的形式，connect 要的是可解析身份地址，
  或需先做系统级星闪配对。**结论：卡点在平台连接语义，不在协议**；下一步先配对（或用
  `manager.getPairedDevices()` 的地址）再验字节通道。为此新增的测试用例默认无 `role` 参数时直接通过，
  不拖累 `bash scripts/test.sh device`。

- **「本机事实」写进 dsh-home/AGENTS.md，让模型别再拿 shell 去猜（2026-11-23 17:20–17:45，手机 CMM-AL10）**。
  上一轮把四条失败的**文案**修好了（轨迹行显示原因），但那是事后解释；这一轮治根：模型之所以去叫 `bash`、去 `~/.git-token`
  乱找，是因为**它不知道这台设备的规矩**。`@deepseek-ai/dsh-agent-instructions` 每次会话第一条请求前会把
  **`$DSH_HOME/AGENTS.md`**（代码里就叫 user-global 目录，`lib/index.js` 第 175 行判的就是这个路径）拼进 durable 上下文，
  所以 `host/bootstrap.cjs` 在开机时**只在该文件不存在时**写一份四行事实：没有 shell（bash/pwsh/jobs 未注册）、
  文件工具只能进工作区、仓库落在 `repos/<owner>-<name>`、push 的 token 由 git 工具自己从 `dsh-home/.git-token` 读。
  **不覆盖**已有文件——同一个文件是 `@ohos/dsh-tool-user-profile` 的受管区块所在地，每次启动重写会把用户画像抹掉。
  证据：手机 `dsh-home/AGENTS.md` 782 B、**0600**，平板同大小但落成 **0644**（同一份代码 —— 与 `.git-token` 那个
  「`chmodSync` 在某些文件上静默失效」是同源问题；内容不含密钥，只是可被其他应用读到）；`bridge.log` 有
  `instructions: seeded platform notes into AGENTS.md`；
  指令候选清单与 `$DSH_HOME/AGENTS.md` 的 user-global 判定都在插件源码里核实过。**行为效果要看下一次新会话**，
  本轮没在真机上跑一轮完整对话去对比（上一次跑的时候 UI 自动化又把点击吃掉了）。

- **轨迹里的「失败」逐条查清了：四条都不是工具坏了（2026-11-23 17:15–17:35，手机 CMM-AL10）**。
  用户报：git clone/push 那一轮轨迹里有失败。把设备上的 `preferences/dsh_sessions` 拉下来逐条读，真实文案是：
  ① `调用 git` → `repos/qtepp-harmony-go is not cloned yet; use action "clone" or "snapshot"`（模型先问 status、后 clone，时序错）；
  ② `执行 bash` → `unknown tool "bash"`（平台补丁把 `tool-bash` 关了，模型照自己习惯叫了一次）；
  ③ `查找 glob /data/storage/el2/base/haps/entry/files` → `glob path escapes the session workspace`（它在工作区外找 token）；
  ④ `读取 …/.git/packed-refs` → `not found`（clone 出来的 refs 没打包，这个文件本来就不存在）。
  另一条会话里还有 `git → Error: tool call aborted`——那一轮被中断，是 dsh 自己的收尾文案。
  **都不是「工具挂了」**，但轨迹只写「失败」，用户只能这么理解。改了三处：
  - **轨迹行**：失败时折叠行显示**失败原因**（取 `output` 首行、去掉 `Error: ` 前缀），不再是参数 JSON ——
    现在一眼看到 `repos/qtepp-harmony-go is …` / `unknown tool "bash"`，不用展开；
  - **git 工具的 action 清单漏了 `commit | push`**（描述里却在讲 push 要 token）：补全，并写明 token 由工具自己从
    `<dsh-home>/.git-token` 读、没有 shell 可查。载荷已重建（`assemble-payload.mjs --skip-install`），
    git 用例 **49/49** 仍全绿；
  - `AGENTS.md` §4.2 纠错：原文「bash 工具存在但必然失败」是错的，实际是**根本没注册**。
  真机验证：手机重新解包载荷（`payload.stamp` 239930689 → 239948646，`grep` 确认新描述已在设备树上）后，
  轨迹里那两行从 `{"action":"status",…}` / `ls -la ~/.git-token …` 变成
  `repos/qtepp-harmony-go is …` 与 `unknown tool "bash"`。

- **克隆仓库里的文件点不开：「它不在当前项目的可访问目录内」（2026-11-23 17:10–17:25，手机 CMM-AL10）**。
  现象（用户报）：消息里的 `docs/STATUS.md` 引用、以及「产物」卡片，点了打不开，提示找不到；
  文件当时就在设备上（`hdc find` 实查：`files/workspace/repos/qtepp-harmony-go/docs/STATUS.md` 与
  `files/workspaces/0651af59…/repos/qtepp-harmony-go/docs/STATUS.md` 都在）。
  根因：`Index.candidatePaths()` 只把「引用」拼到各个**项目工作区根**上（`<root>/docs/STATUS.md`），
  而模型说的是**仓库相对路径**——文件实际在 `<root>/repos/<slug>/docs/STATUS.md`。中间那层 `repos/<slug>/`
  没人补，所以**克隆下来的仓库里任何文件都解析不到**。
  修法：`candidatePaths()` 在每个根上再展开一层 `repos/*/<relative>`（`repoCandidates()`，只列 `repos/` 下的目录，
  不做递归搜索——这是 git 工具自己的固定布局，确定且便宜）。
  真机验证：手机「Coding」项目的 git 会话里，「产物 · 2」两张卡从「目录未挂载」变成「点击预览」，
  点 `STATUS.md` 直接打开文内预览，内容就是 `docs/STATUS.md` 的正文（`# STATUS.md — 真机验收与状态日志`）；
  消息里的 `docs/STATUS.md` 引用同理。

- **输入框不再有内嵌控件：语音挪到左边、图片挪到环与发送之间（2026-11-23 17:05–17:15，手机 CMM-AL10 + 平板 MLR-AL00）**。
  用户要的顺序是「语音在输入框左边；图片在输入框外面、上下文环右边、发送左边」。现在一行是
  `[🎤] [输入框] [上下文环] [🖼] [发送]`（输入法=左边，发送前动作=右边，上下文环留在两个动作之间）。
  **代码上的收益比排版大**：这排控件以前是**叠在输入框里**的，靠给 `TextArea` 一个右侧内边距让位，
  那个内边距换过两次推导方式还是魔数；控件全挪出去以后 `composerInset()` 整段删掉，输入框不再需要任何留白，
  「文字被按钮盖住」这类问题从结构上不可能再出现。
  真机验证：手机（无环，4 个控件：`[🎤][框][🖼][发送]`）与平板（有环，5 个控件）都按上述顺序排好；
  手机输入 6 行草稿时输入框向上生长，两个按钮留在原位不遮挡。`Smoke: PASS`。

- **长按菜单三处统一成同一个浮层（2026-11-23 17:00–17:20，平板 MLR-AL00 + 手机 CMM-AL10）**。
  用户反馈：产物/文件长按、消息长按弹出来的 UI 很丑，不如会话长按那个。
  **原本是两套东西**：会话用的是自定义 `bindPopup`（`@Builder` 画的行 + 分隔线 + 危险区，锚在被按的那一行）；
  消息与文件用的是系统 `UIContext.showActionSheet`——它自带标题/说明/取消行、样式由系统定、而且**永远从底部升起**，
  所以跟会话菜单完全不是一个产品。**这套「锚在被按元素上的自定义浮层」在 iOS 里叫 `UIContextMenu`（长按上下文菜单），
  在鸿蒙 API 里就是 `bindPopup` + 自定义 `@Builder`**；ActionSheet 是「操作表」，不是同一个东西。
  修法：抽出 `common/PopoverMenu.ets`（`MenuAction{id,label,accent?,danger?,note?}` + 一个面板组件），
  消息气泡、文件行、目录行全部改成 `bindPopup`；危险项放在分隔线之后、红色、并带一行后果说明
  （回撤会删消息 + 还原文件，一个「回撤」二字说不清）。
  **两次真机崩溃（记下来，别再踩）**：把 `@Component` 或**全局 `@Builder` 直接写在 `bindPopup` 的 lambda 里**，
  运行时直接被杀 —— 先是 `class constructor cannot called without 'new'`，改成全局 builder 后变成
  `Cannot read property observeComponentCreation2 of undefined`，两次堆栈都指到 `ChatView.ets:2047`（那行就是调用）。
  **正确形态**：lambda 里只调一个 **`@Builder` 方法**，组件在该方法里实例化（= `bindSheet` 那边一直在用的写法）。
  真机验证：手机消息菜单（7 项，红色「回撤到这条消息之前」+ 后果说明）、手机文件行菜单
  （分享到其他应用 / 打开 / 复制文件路径 / 删除）、平板消息菜单；带指示箭头的浮层贴在**被按的那个元素**上，
  不再从底部升起。

- **输入框长文本被按钮遮挡：控件从输入框里挪进顶栏（2026-11-23 16:40–17:00，平板 MLR-AL00 + 手机 CMM-AL10）**。
  现象（用户报）：输入框文字一多，正文就被「模型 / 推理强度 / 语音 / 图片」这排按钮压住。
  根因：这排按钮是**叠在输入框右边缘**上的，靠给 `TextArea` 一个右侧内边距让位；而那个内边距写死成
  `showModelPicker ? 86 : 48`，控件条实际宽 **80–165vp**（模型 28 + 间隔 6 + 强度胶囊 + 语音 34 + 图片 34 + 边距 6），
  还会随着加控件继续变宽 ⇒ 常数永远追不上，长文本必然钻到按钮底下。
  修法两步：
  ①**模型与推理强度挪到顶栏**（用户提的方案），放在「会话 / 文件 / 设置」三个图标左边——它们是**会话级设置**，
  不是每条消息的动作，挪走后输入框的横向空间整条还给正文；
  ②右侧内边距改成 `composerInset()`，由「控件条到底渲染哪些按钮」的**同一组条件**推导（语音可用才 +40vp），
  代码里不再留会漂移的魔数。
  真机验证：手机新会话顶栏从左到右是 `[模型图标][High][会话][文件][设置]`；手机 7 行、平板 3 行草稿**完整可见**，
  语音/图片按钮贴在右侧留白上，一个字都没被盖。装机走 `scripts/deploy.sh`，`Smoke: PASS`。
  **试过但放弃的方案**：把控件条改成卡片内第二行（`Column`：正文在上、控件在下）。真机上只要键盘弹起，
  页面只给输入区约 118px，而卡片需要 200px，内部 `Column` 声明的高度没有被 `layoutWeight(1)` 的会话列表还回来，
  控件条被压成 15px —— 两行方案在「键盘 + 页面高度预算」这条既有约束下不成立，所以回到单行、把控件挪走。
  **边界**：顶栏多两个控件后标题可用宽度从 ~290vp 降到 ~190vp（标题本来就截断、点一下可展开）。
  **既有行为（非本次引入）**：`configOptions` 只在 `session/new` 后返回，所以这两个控件**只在新会话里出现**，
  恢复历史会话时它们是隐藏的。

- **两台真机之间的 WiFi 直连传输：仍未端到端跑通；顺手修了接收页两个缺陷（2026-11-23 14:30–15:05，平板 MLR-AL00 + 手机 CMM-AL10）**。
  目标：用户接上第二台设备后，验一次「手机 → 平板」的真实传输（157 个文件 / 7.9 MB + 1 个会话）。
  构建口径：手机在 **13:54** 的那份 HAP 上；平板 **14:31** 用 `scripts/deploy.sh` 重新构建并装上（含下面两条修复，`Smoke: PASS`）。
  两份 HAP 不是逐字节相同，但改的只是接收页的按钮标签与地址刷新，**线协议未动**，不影响两端对上。
  **接收端这条腿是真验过的**：点「开始接收」后 `cat /proc/net/tcp` 出现 `00000000:11A7 … 0A`（`0.0.0.0:4519` LISTEN，
  uid = 应用自身），界面给出 6 位配对码；再点「停止接收」监听消失。
  **发送端没走完**：手机侧每次都卡在「设置 → 互联 → 项目同步」这三层面板上，最远走到在「项目同步」里勾好仓库目录 + 会话、
  填好 `10.93.130.59:4519`，就差按「开始发送」——然后要么面板被一次误点关掉，要么应用进程被系统回收
  （这一小时里手机端 pid 至少换了 5 次、平板 3 次），面板状态全丢。
  **不是代码问题**：同一份发送代码在宿主机经 `hdc fport` 已双向验过整棵 156 文件 / 7.9 MB 工作区与一个会话
  （`docs/PROJECT-SYNC.md` §4）；两台设备之间的差异只剩「地址」，而两台设备确实在同一个 `10.93.128.0/23` 里
  （`10.93.129.185` / `10.93.130.59`，`ifconfig` 实查）。**这一条留作未验**：需要人手工点三下，或等 UI 自动化更稳。
  **两条修复（平板真机验过）**：
  ①「开始接收」原来读**非 @State** 的 `receiver` 字段——监听已起、配对码已显示，按钮却仍写「开始接收」；再点一次会
  `new` 第二个 receiver 并在 `open()` 上抛错，用户也没有「停止接收」的入口。改成 `@State receiving`，在 open 成功 /
  停止 / finished / 异常 / `aboutToDisappear` 五处同步；实测点一次即变「停止接收」，再点监听消失。
  ②「接收」页的 `receiveAddress` 只在 `startReceive()` 里赋值，所以**第一次**切到「接收」必然显示
  「本机不在局域网内，接收方需要同一 WiFi」——其实 WiFi 上就有 `10.93.130.59`。改成 `aboutToAppear` + 切「接收」页各刷一次，
  实测切过去直接显示地址与端口。
  **UI 自动化的新坑（省下一次用）**：`uitest uiInput drag` 起点落在 TextInput 上会**聚焦并弹键盘**，把面板顶走；滚动用
  `dircFling 2`（向上）。嵌套 bindSheet（项目同步挂在设置面板里）**点偏一次就连带关掉父面板**，状态全丢。设置面板首屏是半高、
  内容要滚才会出现「互联」；`uitest dumpLayout` 能看到设置面板、以及稳定后的部分同步面板节点（可拿精确 bounds），
  面板动画未稳时读不到。**结论**：双机 UI 自动化在这两台设备上不可靠，双机验收要么手工点 3 下，要么继续走
  `entry/src/ohosTest/ets/test/ProjectSync.test.ets` 的设备内 loopback。

- **项目同步：传输层抽成 `SyncLink` + 设备内 loopback 回归，星闪适配就位（2026-11-23 14:30，手机 CMM-AL10）**。
  `ProjectSync.ets` 拆成 `SyncLink`（send/close/onBytes/onClosed）+ `SyncSession`（收帧、配对码、staging→rename），
  TCP 只是其中一个实现；星闪链路 `common/NearLinkSync.ets`（scan / connect+writeData / createPort+startAdvertising）
  与 UI 的「传输：WiFi 直连 / 星闪」已接上，两台设备都报 `canIUse(SystemCapability.Communication.NearLink.Core)` 为真。
  **验证方式换了**：两台设备同时操作 UI 的自动化点击不稳定（设置面板被反复关掉），所以把「协议两半是否对得上」
  做成设备内 loopback 测试 `entry/src/ohosTest/ets/test/ProjectSync.test.ets`，进 `bash scripts/test.sh device`：
  接收端监听 127.0.0.1、发送端连过去，断言 2 文件 + **4096/22 字节**（staging 写空文件也能过文件数断言，所以查字节）；
  第二条用错码，断言发送端抛错、接收端报「配对码不对」、目标目录零文件。本轮实测 **3 个用例全过**。
  星闪**字节通道尚未双机跑通**（需要两台设备同时开收发，见 `docs/PROJECT-SYNC.md` §6），只验到端口/广告/扫描这条腿。

- **语音输入原来是「引擎空转」：补上 AudioCapturer 才真的出字（2026-11-23 16:45，手机 CMM-AL10 + 平板 MLR-AL00）**。
  用户报「语音识别输入还是不支持」。查下来不是权限、不是引擎：`MICROPHONE` 已授予、`createEngine` 成功、
  `startListening` 返回 success、离线模型（`encoder_chn.ms`/`decjoint_chn.ms`）也在加载，
  但整段话**一条 `onResult` 都没有**。
  根因：**CoreSpeechKit 的识别引擎自己不录音**——`startListening` 只是准备一个会话，音频必须由应用用
  `AudioCapturer` 采 16 kHz 单声道 PCM，再按 **640 / 1280 字节**切片调 `writeAudio` 喂进去。
  我们之前只调了 `startListening`，引擎一直饿着，所以"启动成功但永远识别不出字"。
  修法（`common/Speech.ets`）：`startListening` 之后创建 `AudioCapturer`
  （`SAMPLE_FORMAT_S16LE` / `CHANNEL_1` / `16000` / `ENCODING_TYPE_RAW` / `SOURCE_TYPE_MIC`），
  `on('readData')` 里攒数据按 1280 字节切片 `writeAudio`，结束前把余量补零成 1280 一并发出去；
  `stop()`/`release()` 统一停录并释放录音器。
  真机验证方式：Mac 用 `say -v` 生成中文语音并 `afplay` 播放，手机点麦克风 → 输入框出现
  **「。今天天气不错。」**，日志同时出现 `Infer runModel [Decjoint]` 与 `VadInferEvad`（VAD 在跑）。
  这台设备上之前那条「离线语音引擎验成」只证明了**引擎能启动**，不证明识别出字，本条更正。

- **HTML 里的「打印」按钮：先桥接、后按产品意见撤掉（2026-11-23 18:01，手机 CMM-AL10 + 平板 MLR-AL00）**。
  现象：生成的网页自带一个 `onclick="window.print()"` 的按钮（页面本身是"可打印的计划"，按钮是模型加的，
  **不是外壳加的**），在嵌入式 Web 里点了没反应。
  先做了完整桥接：`javaScriptProxy` 暴露 `printPage()`、`onPageEnd` 重写 `window.print`，宿主把整页导出成
  单页 PDF 再 `print.print` 拉起系统打印面板；中间踩到 `ohos.permission.PRINT` 没声明 → PrintKit 报
  `E_PRINT_NO_PERMISSION(201)`（表现同样是"点了没反应"），补上权限后打印面板与「另存为 pdf」都通了。
  **随后按产品意见撤掉**：预览页已经有「导出（整页长图 PNG / 单页 PDF）+ 分享」，页面里再放打印按钮是多余的
  入口。改动：移除桥接与 `ohos.permission.PRINT`；改为在 `PLATFORM_NOTES`（seed 到 `dsh-home/AGENTS.md`）里
  写明「生成的网页不要自带打印按钮」，并且 seed 逻辑改成**幂等追加缺失条目**（原来文件存在就跳过，
  老安装升级拿不到新条目）。
  真机验证：两台设备的 `dsh-home/AGENTS.md` 都从 782B 变成 **1025B**、新条目各一条（手机 18:01、平板 18:00，
  都是升级后重新启动时追加的）。

- **HTML 产物导出长图 PNG / 单页 PDF 并分享（2026-11-23 17:45，手机 CMM-AL10）**。
  需求：生成的可视化网页（长页面）想直接发出去，截图只有一屏。
  实现：`FileViewer` 的 Web 预览新增「导出」菜单（长图 PNG / PDF），走
  `webview.WebviewController.enableWholeWebPageDrawing()` + `webPageSnapshot()`
  （**整页绘制开关必须在 Web 创建期间打开**，否则只能拿到视口大小的图，且不会报错）；
  输出写到 `haps/entry/cache/exports/` 后直接调 `shareFile()` 拉起系统分享面板。
  PDF 不引任何库：把整页 JPEG 按 `DCTDecode` 嵌进单页 PDF，页面尺寸按图片原比例
  （96dpi→pt）算，长文就是一页长文档，不会被切成多张 A4。
  真机验证（`one-hour-fitness-plan.html`，健康计划页）：PNG **1323×16000 像素 / 945KB**、
  PDF **MediaBox 992.25×12000pt / 968KB**，两份文件都从设备取回校验（PDF 用 `qlmanage` 渲染缩略图
  确认整页内容在），每次导出后系统分享面板正常弹出（「分享 1 项」）。

- **项目主题预设 + 数据驱动图表 + 亮/暗双导出（2026-11-23 19:37，手机 CMM-AL10）**。
  ① **项目主题预设**：`.dsh-html/presets.json`（`html` 工具新动作 `preset`：`save` / `default` / `remove` / 列表）。
  `create` 的解析顺序是「显式参数 > 命名预设 > 项目默认」；`check` 会拿页面 `<html style>` 里声明的令牌
  与项目默认比对，不一致就报「主题漂移」。真机验证：模型先 `preset save name=brand default=true
  tokens {--accent:#0f766e,--c2:#b45309}`，再不带任何主题参数 `create preset-page.html` —— 产物
  `<html ... style="--accent:#0f766e;--c2:#b45309">` 直接继承了项目默认，`presets.json` 里 brand 与 default
  都在。
  ② **图表数据驱动**：新动作 `chart`，吃 CSV/TSV 或 JSON（数组对象 / `{labels,series}`，也可 `dataFile`），
  工具自己算百分比、坐标与 viewBox（kind = bars / hbars / stack / line / heat / donut）。真机：模型给
  `周,完成 / W1,18 / W2,21 / W3,16 / W4,24` 生成折线，SVG 里 `M24,55.5 …`（18/24 → y=55.5，验算正确），
  `viewBox="0 0 320 180"`，check 0 warn 0 error。
  ③ **亮/暗双导出**：预览页「导出」菜单新增「导出长图（亮 + 暗）」——对同一页强制 `data-theme` 为
  light/dark 各截一张整页长图（`webPageSnapshot`），只截一次页面状态、不自动分享（分享面板一次只收一个
  文件，文件面板可分别发）。真机验证（preset-page.html）：生成 `preset-page-长图-亮.png`（106,746B）与
  `preset-page-长图-暗.png`（105,545B），**两张同尺寸 1323×2451**，像素采样 亮底 `#f7f7f5` / 暗底
  `#14140f`，暗色长图里折线与强调色仍是项目预设的青色 —— 说明主题确实被强制切换而不是同一张图截两次。
  **已知边界**：旧版组件库生成的页面没有 `html[data-theme="dark"]` 规则，强制切换对它们无效（两张会一样）；
  从本版起生成的页面都成立。
  验证：插件单测 **41 条**全绿（预设解析/继承/覆盖、漂移检测、CSV/JSON 解析、六种图表的百分比/坐标/
  热力档位/环形占比、坏数据被拒）；`arkts` + `local` 全绿；两台设备已装本版。

- **组件库改成「令牌驱动 + 修饰符」，并补 9 个展示组件（2026-11-23 19:10，手机 CMM-AL10）**。
  背景：原组件库把颜色/间距/字号/宽度写死在组件里，虽然能拼页面，但换观感就要重写 CSS —— 等于用框架
  限制了可视化表达。改法：
  ① **令牌化**：`--accent`、`--c1…--c5`（图表色序）、`--bg/--surface/--surface-2`、`--text/--muted/--line`、
  `--ok/--warn/--danger`、`--radius*`、`--gap*`、`--page-max`、`--fs-*`、`--line-height` 全部可覆盖；
  `create` 新增 `tokens`（任意变量，如 `{"--accent":"#c2410c"}`）+ `theme=auto|light|dark`、
  `width=narrow|wide`、`density=compact|roomy`；显式 `data-theme` 优先于系统偏好（暗色块加
  `html:not([data-theme="light"])` 兜底）。
  ② **修饰符**：`card.flat/tinted/accent`、`stat.hero`、`steps.compact`、`table.compact`、`tr.hi`、
  `badge.ok/warn`、`grid-2/3/4`、`wrap.narrow/wide`、`body.density-*`，以及间距/语义色/`row` 工具类 ——
  组合现有组件即可变体，不新增硬编码样式。
  ③ **展示组件 +9**：`chart-stack`（堆叠柱）、`chart-hbars`（横向条形）、`chart-line`（**静态 SVG**，
  坐标 viewBox 320×180）、`chart-heat`（热力格 l1–l5）、`section-head`、`figure`、`gallery`、`avatars`、
  `plans`；图表全部纯 CSS/静态 SVG，导出长图/PDF 不走样。
  ④ `check` 新增「正文写死的十六进制颜色」告警（超过 3 个就提示改用令牌），把「别写死」变成可检查的规则。
  验证：单测 **33 条**全绿（令牌/主题/宽窄/密度生效、显式主题优先、坏参数被拒、写死颜色被告警、新组件类
  都有样式）；Node 冒烟（dark+wide+compact+tokens 生成 21.4KB 页面，check 通过）；真机让模型生成
  `v2-visual.html` —— **22.6KB、0 外链、`--accent:#c2410c` 生效**，暗色下堆叠柱/横向条/折线（含虚线
  对照线与面积填充）/热力格/方案卡/人物行全部按令牌渲染；基线文件记录 8 个组件、0 warn 0 error。
- **`html` 组件库补三类能力：图表、可排序表格、检查基线（2026-11-23 18:35，Node 冒烟 + 真机装包）**。
  ① **图表（纯 CSS，零脚本）**：`chart-bars`（柱状，柱高写百分比）与 `chart-donut`（`conic-gradient`
  环形 + 中心 `--p` 百分比）；导出的长图/PDF 与预览完全一致，因为不依赖 JS。
  ② **`table-sortable`**：表头点击排序（`data-type=number|text`）、`data-page-size` 分页，全部是**页面内联脚本**
  的渐进增强——脚本不可用时表格照样完整显示，导出时会带上当前排序与分页状态；`check` 只把**外链脚本**判为错误。
  ③ **质量回归**：`check` 现在会把「体积 / 用到的组件 / warn+error 数」写成 `.dsh-html/<page>.json` 基线，
  下一次检查输出 `baseline: 体积 8KB → 12KB（+4KB, +50%）`、`baseline: 新增组件 stats` 这类行，
  让风格漂移和体积膨胀在模型还能改的时候就被指出来。
  验证：插件单测 **27 条**全绿（含「图表片段不含 script」「可排序片段不含外链」「inline script 不算错误」
  「基线首次/对比/持平」，以及**用假 DOM 直接跑页面内联脚本**证明表头点击按升序/降序/再升序排列）；
  Node 冒烟走 create→fill(三种组件)→check→append→check，两次检查分别输出首次基线与持平结论。
  真机（手机 CMM-AL10）：让模型用工具生成 `kit-test.html` —— **14.6KB、0 外链**，check 同时写出
  `.dsh-html/kit-test.html.json` 基线（`components: [table, table-sortable, chart-bars, chart-donut]`，
  `warnings: 0, errors: 0`）；预览页确认柱状图（W1–W4 带数值）、72% 环形进度、可排序表格都按组件样式渲染。

- **新增 `html` 工具：用组件库写页面，而不是每次从零推理（2026-11-23 18:25，手机 CMM-AL10）**。
  背景：页面是模型用通用 `write` 工具从零拼出来的——排版/配色/移动端宽度每次重新推理，两页像两个产品，
  还常带 CDN 外链（设备上离线打不开）和 `window.print()` 按钮（嵌入式 Web 点不动）。
  做法：新增 `@ohos/dsh-tool-html`，注册成工具 `html`，四个动作：`components` 返回 **16 个组件**的清单与
  可复制片段（hero / card / grid / stats / steps / checklist / table / callout / timeline / compare / bars /
  kv / fold / quote / code / divider）、`create` 写单文件骨架（样式内联、`prefers-color-scheme` 明暗两套、
  移动端 viewport、零外链、无页面级按钮）、`fill` 往内容插槽放片段、`check` 报外链/缺 viewport/体积/
  打印按钮/组件库外 class。接线到 bundle 依赖 + `cordis.patch.yml` insert 行，并进 `scripts/test.sh unit`
  （新增 19 条单测，全绿）。
  **两个真机坑**：① `defineTool` 的 `render` 必须在 `output: { schema, render }` 下，放顶层会让插件挂载失败
  （`node.log`: `TypeError: Cannot read properties of undefined (reading 'render')`），表现为工具不出现、
  `tools(27)` 不变；② `append` 原本插到页面末尾，落在 `<footer>` 之后、`<main>` 之外（真机产物可见），
  改成模板里有 `<!-- dsh:content -->` / `<!-- dsh:content:end -->` 双标记，replace 与 append 都留在 `<main>` 内。
  真机验收：两台设备 boot-report 都出现 `html`（`tools(31)` 列表里有 `html`）；让手机上的模型按提示用工具
  生成 `demo-plan.html`：**9.4KB、stats(4 处 stat-value) + steps(5 处 step-num)、保留插槽标记、
  0 个外链**，预览页渲染正常（组件样式生效）。`docs/HTML-COMPONENTS.md` 是组件清单快照。

> 载荷里的 `payload/docs/` 是构建期快照（`assemble-payload.mjs` 的 `stageDocs()` 拷 `docs/*.md`），
> 权威副本始终是本文件。

---

- **上下文账本与原生面板真机闭环（2026-11-23 19:25，手机 CMM-AL10）**。输入框小环从「弹 toast」改为打开原生面板：
  窗口占用（83.6k/1.0M，8%）、系统/工具/消息组成（622 / 6.2k / 55.9k）、前缀缓存命中（95%，1.5M 走缓存）、
  最近 3 轮（第 4/5/6 轮，含 8/1/11 步与每轮输入输出）。数据来自新插件
  `@ohos/dsh-context-ledger` 写的 `<filesDir>/dsh-home/context-ledger.jsonl`（真机 20 行，`tail` 可见
  `turn:6 step:11` 的原始记录）。force-stop 冷启后重开面板数字不变；返回键先关面板、不退应用。
  **过程里撞到一次与本题无关的冷启布局异常**：产物 6 个时 ArtifactDock 的渐隐层 `height('100%')`
  把 dock 撑满、输入行被挤出屏幕；同轮 ChatView 的 strip 改动已修掉，复测冷启列表/输入行正常。
  单测：插件 6/6；LocalUnit 新增 ContextLedger 10/10；`bash scripts/test.sh unit local` 全绿；`devecocli build` 成功。


- **`push` 已用真 token 验成；顺手修了两个真 bug（2026-11-23，手机 CMM-AL10 / HarmonyGo）**。
  用户在设置页填入真实细粒度 PAT（`QtePP`，对 `QtePP/harmony-go` 有 `admin/push`）。设备侧
  `.git-token` 落盘 **93 字节**（= token 长度），说明「设置页 → 文件」这条链真的通了。
  但**真机上的 `push` 没验成**：UI 自动化反复把焦点让给「项目同步 / 互联」面板（我几次点输入框都
  命中它们），`clone` 也被中断过一次。**改用同一份代码路径在宿主机直连验证**：用工具自己的
  `http.js` + `isomorphic-git` + 真 token 推一个探针分支 → `{"ok":true,"refs":{"refs/heads/
  harmonygo-probe":{"ok":true}}}`，GitHub API 侧确认分支存在（`e1713f2`，message `probe`），
  随后**删除探针分支**（`204`，复查 `404`）。
  **由此抓到两个真 bug**：①推**新分支**必须 `force: true`，工具原来没传 ⇒ 只能推已有分支；
  ②`push` 一个远端有、本地没有的 ref 时，js-git 在联网前就抛 `NotFoundError: Could not find <ref>`
  ——读起来像网络故障，实际是本地没有这个分支；现在提前查 `listBranches` 并报
  `GIT_NO_LOCAL_REF` 且列出本地分支名。单测 47 → **49**，八个套件全绿。
  **未验**：真机上点「保存」之后由模型完成 `push` 的完整回合——卡在 UI 自动化，不是代码。
  **安全**：该 PAT 明文出现在聊天记录里，**已视为泄漏，用户需自行撤销/轮换**（我只写进 0600 临时
  文件与设备沙箱，未提交仓库、未写进文档）。

- **模型清单真机闭环（2026-11-23，手机 CMM-AL10 / `com.qtepp.harmonygo` 新包）**：设置页打开即用
  已保存的 Key 拉一次 `GET https://api.deepseek.com/models`，`ui layout` 读到**真实两项**：
  `DeepSeek-V4.1-Flash`（id `deepseek-flash`，标「当前」）、`DeepSeek-V4-Pro`（id `deepseek-v4-pro`）。
  点 Pro → 标记与「当前：」立刻跟到 `deepseek-v4-pro` → 点「保存」→ 面板关闭、`.api-key` 时间戳更新，
  并从设备 preferences（`haps/entry/preferences/dsh_settings`）读到
  `<string key="model">deepseek-v4-pro</string>`。**反证也验到了**：中途只选不保存，重开面板回到
  `deepseek-flash`——未保存的选择不会持久化，符合预期。
  **同一轮给出的口径**：列表来自**账号**不是随包发布；ACP 的会话内选择器仍以服务端 `configOptions`
  为权威（`dsh-acp` 用 `llm.listModels`），两者应当一致，不一致时以 ACP 返回的为准。
  **同时纠正一条旧记录**：catalog 里 `deepseek-flash` 才是 DeepSeek-V4.1-Flash，
  `deepseek-v4-flash` 从来不是合法 id；旧文档曾把它当「纯文本」写进补丁注释，已改。

- **项目同步的失败路径与边界（2026-11-23 12:26，同一台手机 + Mac 对端）**。补测 v1 最该担心的几条：
  ①**配对码错** → 接收端 `deny`、界面「配对码不对，已拒绝」、工作区零字节变化，且接收端随即关闭监听
  （下次要重新点「开始接收」拿新码，这是单次配对的设计）；②**同一棵树重复发** → 三个文件全部跳过，
  设备侧 mtime 仍是第一次的时间；③**中文路径 + 嵌套目录** 原样落盘，Mac 端 `diff -r` 子树一致；
  ④**5MB 二进制** MD5 与源一致（`249a76a3…`）；⑤**整棵真实工作区 156 文件 / 7.9MB**（含一个
  clone 下来的 git 仓库）设备→Mac 全绿（`DONE files=156 bytes=8286575`，Mac 端 156 个文件）。
  顺带修了一个真问题：分帧的 UTF-8 编解码原来用 `util.TextEncoder/Decoder`，而它在 host 单测里是桩，
  帧在测试里被当成损坏（三条 framing 单测一开始全红）；改成自己实现的 UTF-8 编解码后 3 条单测通过
  （跨读拼帧、一次读多帧、异常长度），协议也因此在设备外可测。
- **项目文件同步：真机双向验成（2026-11-23 11:49，手机 CMM-AL10 + Mac 对端）**。新功能：把项目工作区
  （整目录或勾选顶层条目）发到另一台设备。**协议**：长度前缀分帧 + manifest + 32KB 分片 + 一次一块背压；
  **落盘**：接收端先写 `cacheDir/sync-incoming/`，整棵树到齐且逐文件大小核对后才 rename 进工作区，
  同名不覆盖、列在结果里；**配对**：接收端生成 6 位码，发送端 hello 里带上，错码直接拒绝、不落任何字节。
  **取证方式**：设备与 Mac 不在同一网段（`10.93.129.185` vs `192.168.43.4`），用 `hdc fport/rport`
  把 4519 桥过去，Mac 上写了一段 `sync-peer.mjs` 当对端。①设备接收：`fport tcp:4519 tcp:4519`，
  Mac 发 `readme.md` + `sub/note.txt` + `sub/random.bin`（200000 字节随机）→ 设备工作区三个文件都在，
  取回 `random.bin` 与源文件 **MD5 都是 `ce4d0bf5060a6903b3ce744a5908e1a1`**，界面「已接收 3 个文件」；
  ②设备发送：`rport tcp:4519 tcp:4520`，Mac 监听 4520/码 `123456` → 设备界面「已发送 3 个文件 · 195.4 KB」，
  Mac 日志 `file … OK` ×3 + `DONE files=3 bytes=200041`。
  **顺手确认**：`hdc shell` 能**删除**应用沙箱里的文件（测试文件就是用 `rm -rf` 清掉的），但不能创建
  （`touch` 报 Permission denied）——清理设备上的同步测试数据时有用。
  **会话同步（同一轮补上并验）**：勾选会话 → `sessions` 帧（JSON，`raw` 为本地存储的原始转录）→
  接收端并入本地索引。设备→Mac：Mac 收到 `sessions frame 778 bytes`，解析出 3 条消息、标题「你好」；
  Mac→设备：用一个改过 id 的会话反向发，设备侧出现「来自 Mac 的会话（导入）」，点开完整对话可读，
  `dsh_sessions` 里 `session.<id>` 与索引行都在。**边界**：只带本地缓存消息（最近 200 条），
  dsh 的服务端日志不随行 ⇒ 接收端 resume 会新建服务端会话；图片不随会话；同 id 不覆盖。
  **未做**：星闪 transport（协议已解耦，只差适配；需两台支持星闪的设备同验，用户说第二台稍后接入）、
  断点续传、加密。

- **星闪与数据代理两条探测从「两红」到「两绿」：三处用法错误（2026-11-23 11:18，手机 CMM-AL10）**。
  用户贴的设置页截图里两条都是红的：`星闪：不可用 — createPort 失败 401: Invalid parameter`、
  `数据代理：不可用 — 数据代理不可用 15700011: The URI is not exist.`。逐条查 SDK 后发现三条都属于
  **我们的调用错**，不是平台不给：
  ①`dataTransfer.createPort(uuid)` 文档要求 uuid 是 **16 字节、8-4-4-4-12 书写**
  （例 `FFFFFFFF-FC70-11EA-B720-000078951234`），我们传的是 32 位裸 hex ⇒ **401**；
  ②`ACCESS_NEARLINK` 是 **user_grant**，没申请就调 ⇒ **201 Permission denied**（改前第二次实测就是 201，
  说明格式修对之后才走到权限这一层）；探测现在先 `requestPermissionsFromUser(['ohos.permission.ACCESS_NEARLINK'])`
  再建端口，用户拒绝就报「未授予权限」而不是「不可用」；
  ③DataShare 共享配置的 URI 是 **`datashareproxy://<bundle>/<path>`**，用 `datashare:///…`（extension 的
  scheme）去读，必然 **15700011 URI 不存在**；换成正确 scheme 后又撞 **15700014「参数格式不对」**——
  因为单值记录得用 `get()` 读，`getValues()` 只服务 `isMultiValues: true` 的记录（这个错误码的文案会让你
  去查 URI，其实是 API 配错）。改成 `publish` 一条 `probe` → `get([uri])` 读回 → `delete` 清理。
  修完后真机两条都绿：**星闪：可用 — 端口创建成功（可继续做配对与传输）**、
  **数据代理：可用 — 共享配置可用（发布 + 读回「probe」，已清理）**（截图在应用内该面板）。
  **教训**：探测类功能报错时，先把「错误码文档里的可能原因」逐条对上我们的调用，再谈平台限制——
  这两条通道在 `docs/INTEROP-APIS.md` 里原来都写着「视机型 / 需要对方是提供方」，实测都更宽松。

- **语音输入/朗读起不来是参数写错，不是缺语音包——旧结论被真机推翻（2026-11-23 10:50，手机 CMM-AL10）**。
  用户贴的 toast 是「语音引擎启动失败（1002200001）」，旧记录（2026-11-16，平板与手机各一次）把它
  归因为**缺离线中文语音包**。这次**先查 SDK 声明再下结论**：`@hms.ai.speechRecognizer.d.ts` 里
  `CreateEngineParams.online` 写的是「**1**: offline. Currently, only the offline mode is supported」，
  而我们的 `Speech.ets` / `ReadAloud.ets` 传的是 **0**（那个并不存在的在线模式）——`createEngine`
  于是回 `1002200001`；官方错误码文档把「**模式不支持**」列在同一码的可能原因里，与「资源不存在」
  **共用一个码**，这就是它被误记成「缺语音包」两个月的原因。改成 `online: 1` 后真机实测：
  ①设置 ›「语音输入 → 重试」→ 回对话，麦克风回来（旧标志 `speech_asr_usable=false` 清掉了）；
  ②点麦克风**不再弹错**，按钮转蓝常亮，系统日志 `com.huawei.hmsapp.hiai.voice` 出现
  `PipalEngine: Infer Model [Encoder] load cost = 603, verify cost = 224` 与 `ServerInnerMonitor` 心跳
  ——离线识别模型真的在跑（设备上并不缺语音包）；③长按模型回复 →「朗读这条回复」→ 系统 TTS 出声，
  我们侧日志 `AI_TEXT: [(TtsReleaseSync)]Succeeded in releasing tts engine, engineName: , online: 1.00`
  （`online: 1.00` 就是新参数），紧跟着 `HiAI_PcmSoundPlayer: release success`。
  同时改掉三处误导文案：toast、设置页「装好离线语音包后点右边重试」、`speechAsrUsable` 的注释。
  **教训**：一个错误码覆盖多种原因时，「最像的那个解释」不能直接当结论——这次是靠读 SDK 声明
  加一次「只改一个参数」的对拍推翻的。

- **设置里的模型名修正之后，把老设备里存的假 id 迁移掉（2026-11-23 10:23，手机 CMM-AL10）**。
  同一天的 `6da2e63` 把「模型」从写死的假 id 换成按 Key 拉 `/models` 的列表，但它**没处理已经存进
  preferences 的旧值**：那个月点过「保存」的设备，`dsh_settings` 里仍然是 `deepseek-v4-flash`，
  设置页照旧显示它、SDK 的 `initialize` 照旧送它。本次补迁移：`ModelCatalog.normalizeModelId()`
  把 provider 目录里不存在的 id 映射成真实的（`deepseek-v4-flash` → `deepseek-flash`），
  `AppConfig.load()` 规范化后**回写一次**、`save()` 同样规范化。单测 +2（旧 id 带首尾空格也改写；
  真实/未知/空 id 原样返回）。
  **真机取证用两段式**（列表已经选不出假 id，只能自己造出老状态）：先用一个临时构建把
  `deepseek-v4-flash` 写进 preferences（代码里明确标 `TEMP-SEED`，验完删掉、不进 commit），
  再装正式构建——启动后 `dsh_settings` 从 `deepseek-v4-flash` 变成 `deepseek-flash`。
  同一轮还验了列表的写入路径：选中 `deepseek-v4-pro` → 保存 → preferences 变 `deepseek-v4-pro`；
  再选回 flash → 保存 → `deepseek-flash`。设置页显示 `DeepSeek-V4.1-Flash` / `DeepSeek-V4-Pro`
  两个真实条目（名称来自 `/models`）与「当前」标记。

- **品牌标记换成平行四边形横杠，SVG 与所有位图图标的几何原本是两套（2026-11-23，手机 CMM-AL10）**。
  用户要求「闪电上面那一横的左右两边改成斜向下的平行线，那一横变成平行四边形」。
  改动：`bolt.svg` 与 `logo.svg` 里的 `<rect x=3.2 y=3.2 w=17.6 h=2.6 rx=1.3>`（圆头胶囊）换成
  `M4.3 3.2 H20.8 L19.7 5.8 H3.2 Z`——**包围盒一字未动**（3.2…20.8 × 3.2…5.8），只有左右两边
  改成互相平行、向下左倾 1.1 单位 / 2.6 单位高（≈23°）。选这个斜率的理由：闪电左上肩线
  （12.5,5.5 → 9.2,13.2）本身是 0.42 的斜率，同角之后整枚标记的斜线只有一个方向。
  形心仍在 x=12：SVG 侧实测字重 **0.1497 → 0.1472**（墨量，−1.7%）、暗像素质心只下移 **1.3 px / 512**，
  基本是同一个分量——换形状不换浓度，所以启动页与空会话卡片看起来只是「圆头变斜头」。
  **但桌面图标确实变淡了**：旧 PNG 的墨量是 **0.1916**，新 PNG 是 **0.1547**（−19%），
  原因不在换形状，而在下面那条漂移修正（旧 PNG 的横杠比 SVG 高了 0.6 单位）。
  **顺手发现的一处漂移**：四个位图图标（`entry/.../{foreground,startIcon,app_logo}.png` +
  `AppScope/.../foreground.png`，四份原本 md5 完全相同）是**旧版标记**的渲染——横杠实测 **3.23**
  单位高，而 SVG 里写的是 **2.6**。也就是说改图形时改 SVG 时代就与打包图标脱钩了，没人发现。
  新增 `scripts/make-mark-icons.py` 把几何收敛成一处：脚本里写死与 SVG 相同的多边形，一次性
  重画四张 512×512 灰度 PNG（两层高斯阴影参数照抄 `logo.svg` 的 far/near）。
  **验证**：脚本幂等（连跑两次 md5 相同）；`logo.svg` 经系统光栅化后与新 PNG 平均差 **2.5/255**
  （p95 14），即两边现在是同一个几何；`devecocli build` 成功；`.hap` 内 `foreground/startIcon/app_logo`
  各 **19229 字节**且与源文件 md5 一致；真机（CMM-AL10）启动页、空会话卡片、**桌面图标**三处
  目视确认——桌面图标与旧 `TA Harness` 并排时能看到胶囊 vs 平行四边形的差别。
  **负结果/待办**：`docs/images/*.png` 里的旧截图（如 `home.png`）还是旧标记，本次没有重画；
  对比图存在 `docs/images/brand-mark-parallelogram.png`。`scripts/make-store-shots.py` 读的是
  `AppScope/.../foreground.png`，所以应用商店截图下次生成时自动跟着新标记走，无需改动。

- **「现在的模型不对」——根因是两个，不是一个（2026-11-23，手机 CMM-AL10）**。用户反馈模型不对，要求
  「按 API Key 取有什么模型再选」。取证后发现：
  1. **默认 id 是错的**：`AppConfig.MODEL = 'deepseek-v4-flash'`，而 dsh 0.2.2-rc.5 的
     `dsh-llm-deepseek` 目录里 `DEFAULT_MODELS` 只有 **`deepseek-flash`**（DeepSeek-V4.1-Flash，
     唯一 `inputModalities` 含 image）与 **`deepseek-v4-pro`**。该常量只用于 **SDK profile** 的
     `initialize`（`NodeHost.ets:185`），等于一直送一个 provider 不认识的 id；设置页又把它显示成
     「当前模型」，看起来像权威值。
  2. **设置页「模型」是自由文本框**，没有来源也没有校验（真机 `ui layout` 读到
     `TextInput "deepseek-v4-flash"`）。
  **注意 ACP 路径本来是对的**：会话内选择器由 `session/new` 返回的 `configOptions` 驱动，而
  `configOptions` 来自 `this.llm.listModels(provider.id)`（`dsh-acp/lib/index.js:393`）——即服务端
  实时清单。所以「不对」的是 SDK 默认值与设置页，不是 ACP。
  **修法**：新增 `common/ModelCatalog.ets`，用 Key 打 `https://api.deepseek.com/models`
  （dsh 自己用 `new URL("/models", origin)`，baseURL 是 `https://api.deepseek.com/anthropic`，
  origin 相同），设置页改成「刷新列表 + 真实清单（名称/说明/id/当前）」，打开即自动拉一次；
  拉取失败保留原选择。默认值改 `deepseek-flash`。`modelsFromBody()` 纯函数 4 条单测。
  **验证**：ArkTS 48 文件通过、`hvigorw test` 0 断言失败、`devecocli build` 成功。
  **未做真机验证**：拉取需要真实 Key，而并发改名（`com.qtepp.harmonygo`）后新包是新 prefs，
  旧包的 Key 不会带过去；等新包首次填入 Key 时再看一次清单。

- **设置页填 GitHub token → `push` 能读到：真机闭环（2026-11-23，手机 CMM-AL10）**。设置页新增
  「GitHub Token（用于 git push）」输入框，存 preferences 并镜像到 `dsh-home/.git-token`。真机实证：
  输入 23 字符 → 点「保存」→ 设备上 `stat` 到 **`.git-token` 23 字节、内容 `ghp_plumbing_probe_1123`**
  （与输入一致）。`readToken()` 另有 4 条单测（优先 `.git-token`、回落 `.api-key`、空白文件继续找、
  都没有返回空）。**未验证**：真实 token 的 push 成功——手上的 token 是假的，且不该拿真 token 试。
  **一个必须记下的矛盾**：`bootstrap.cjs` 的 `tightenKeyFile()` 明明打了
  `key: .git-token tightened to 0600 (was 644)`，但同一时刻 `stat -c %a` 给的是 **644**；
  而同一段代码处理的 `.api-key` 是 **600**。hdc 侧 `chmod` 一律 `Operation not permitted`（已知）。
  也就是说**「收紧到 0600」对 `.git-token` 没能证实**，`chmodSync` 可能在某些文件上静默无效。
  影响有限（应用沙箱按 uid 隔离，别的 App 读不到），但**口径里不能写「0600」**，先记为待查。
  **UI 自动化的三个坑（白耗了一小时）**：①`ui layout` 默认**只 dump 底层窗口**，模态面板盖在上面时
  看到的是错误的坐标——必须加 `--all-windows`；②面板在**软键盘弹出时只有 1606 高**，此时手势只改变
  面板尺寸、**不滚动内容**，键盘收起后才是 2848 且可滚；③`ui swipe` 滚不动（还会被当成下拉关闭），
  `dircfling` 会过头到顶/底，**只有 `ui drag` 能可控滚动**。另外 dump 偶发
  `Empty dumpLayout response from device`，别当成「面板已关闭」。

- **改名 HarmonyGo：显示名与新包名在手机上闭环（2026-11-23 10:00，Mate 90 Pro Max）**。
  产品名 `TA Harness` → **HarmonyGo**、包名 `com.qtepp.taharness` → **`com.qtepp.harmonygo`**、
  仓库 `deepseek-harness-harmony` → `harmony-go`。
  真机链路：`devecocli signature generate --force`（**profile 绑 bundleName，换包名必须重签**，否则装不上）
  → 构建 → `com.qtepp.harmonygo` 安装启动成功。证据：启动页显示 **HarmonyGo**；
  `bridge-status.json` = `state: running / profile: ohos / port: 4517 / node: v24.2.0`；
  `boot-report` 仍 `tools(27)`（含 `git` / `user_profile`），`web: search=auto … fetch=ready`。
  **改名特有的坑（真机撞到）**：旧包 `com.qtepp.taharness` 还装着，我先 force-stop 它，
  它**又自己起来了**（21:00:08 的进程，`bridge-status` 也报 `running / 4517`）——桥是**固定端口 + 单客户端**，
  谁先抢到 4517 谁活；新包那一次启动卡在载荷解包之后（`dsh-home/` 都没建），
  把旧包再 force-stop 后才正常 boot。**所以改名后要卸载旧包**
  （`hdc shell bm uninstall -n com.qtepp.taharness`，注意连旧沙箱数据一起删）**或者严格一次只开一个**。
  另外 `.app` 产物前缀来自本地工程目录名，`scripts/build-release.sh` 已改成 glob 取，不再写死 `dshharmony-`；
  本地仓库目录仍叫 `dshharmony`（会话工作区），改名留给用户自己 `mv`。

- **长按文件就能分享；设置面板在手机上重新够得到（2026-11-23 09:15，Mate 90 Pro Max）**。
  换到**手机**形态：`const.product.name` = HUAWEI Mate 90 Pro Max 典藏版、`model` = CMM-AL10、
  `devicetype` = phone、HarmonyOS 7.0.0.111、1320×2848 —— 本仓**第一次在 <840vp 单栏**上验
  （之前只有 MatePad Mini 平板）。新设备不在旧调试 profile 的 UDID 里 ⇒ 先
  `devecocli signature generate --force`（CLI 自己打印 ACL 申请 `FILE_ACCESS_PERSIST`），装完
  `git checkout build-profile.json5` 还原开源口径；载荷在旧沙箱里已存在，首启没有重新解包。
  **分享（本次改动）**：打开「项目文件」→ **长按** `weekly-training-plan.html`（22.2 KB）→ 弹
  `分享到其他应用 / 打开 / 复制文件路径 / 删除`；点分享 → 系统面板标题「分享」，卡片是
  **文件名 + HTML 类型图标 + 22.76 KB**，目标有 华为分享 / WeLink / 微信 / QQ / QQ邮箱 / 备忘录 /
  打印 / 另存为 / 复制 / 小艺帮记 / 添加至中转站。**两个 KB 不是两份文件**：设备侧 `ls -l`
  `/data/app/el2/100/base/com.qtepp.taharness/haps/entry/files/workspaces/4f1e78ea-…/` 给的真实大小是
  **22757 B**，我们的列表标签按 1024 进制一位小数显示 22.2 KB，系统面板按 1000 进制两位小数显示
  22.76 KB。预览页右上角的「分享」走同一个 `shareFile()`（平板上一轮已验过同一路径）。
  **设置面板（0bb8f02）**：`SheetSize.LARGE` 在这台手机上只有约半屏，加了 GitHub Token 字段后
  `保存` 落到屏外且面板不滚——`height: '92%'` 之后 `Scroll` 占满 `[0,348,1320,2848]`，滚到底
  `保存`/`诊断` 在 y=1181–1316 可见可点，Token 字段与「写入 dsh-home/.git-token」说明都在首屏。
  **Token 字段在设备上完整往返（09:21–09:24）**：填一个假 token `ghp_faketoken_verify_1234` →
  保存 → 设备侧 `dsh-home/.git-token` 立刻出现、内容就是那 25 字节；`aa force-stop` 冷启后
  `bridge.log` 打出 `key: .git-token tightened to 0600 (was 644)`，`ls -l` 确认变成 `-rw-------`，
  设置页重启后仍回填该 token（preferences 往返），`.api-key` 的 0600 不受影响。
  再用「长按输入框 → 全选 → DEL」清空 → 保存 → 文件被 `unlink`（`ls` 报
  `No such file or directory`）——**清空路径也验了**：填错 token 若不能改，用户只能重装应用，
  这是这个功能最容易漏的失败路径。
  **四个坑**：(1) `devecocli ui longclick`（约 500ms 按压）在这台手机上**不触发**
  `LongPressGesture`，`hdc shell uitest uiInput longClick x y` 才触发——手机上写 UI 自动化直接用
  uitest；(2) `uinput -K -d 2 -u 2` 在这套系统上是 **BACK**，用来收键盘不会把 App 踢到后台
  （平板上同一个键是 HOME，别照抄）；(3) 顶部常驻通知横幅会盖住 header，测试中途另一个 App
  （「手表离线地图」）抢了前台，用 `aa start -a EntryAbility -b com.qtepp.taharness` 拉回来；
  (4) 面板的**类型**决定它给哪些目标：`uniformTypeDescriptor.getUniformDataTypeByFilenameExtension()`
  查平台，查空或抛错才落静态表——类型报粗了，本该能收的 App 会被面板筛掉；
  (5) 顺带确认 **`hdc shell` 能读应用沙箱、不能写**：`ls -l`/`cat`/`grep`
  `/data/app/el2/100/base/com.qtepp.taharness/haps/entry/files/dsh-home/…` 都成功，
  排查 `.git-token`、`.api-key`、`bridge.log` 不必只靠应用内「诊断」页。

- **`git` 走设备自己的系统代理（2026-11-20 16:20，MatePad Mini）**。起因是用户问「我的手机没翻墙
  你咋拉代码」——我先取证再回答，结论与我原来的假设相反：**平板是直连的，没走我的 Mac**。
  证据：平板 `wlan0` = `10.93.118.222`，我的 Mac `en0` = `7.246.173.82`；平板 **0 个** `tun/utun/ppp`
  接口；系统代理参数为空；`node.log`/`bridge.log` 无 `*_PROXY`；我们的 `http.js` **只认 hostname/port**。
  平板把 `github.com` 解析到 `20.247.166.64`、`codeload` 到 `20.6.7.16`，92–182ms 可达
  ——是**运营商/DNS 侧给的可用出口**，不是翻墙。旁证：同一条命令 `ping 110.242.68.66`（百度）
  **100% 丢包**，说明「通不通」按目标分化，不能拿「能不能上网」一个标准判断。
  **所以真正的缺口是**：一旦那条出口不通，`git` 就废了——工具表没有 `bash`/`curl`/`wget`
  （`toybox` 连 `tr` 都不给），且 `http.js` 不认代理，**在平板上开代理 App 对它无效**。
  **做法（不依赖本机，符合「演示要看平板自己」）**：ArkTS `connection.getDefaultHttpProxy()` →
  `DSH_HTTPS_PROXY` → `proxyFromEnv()` → 自建 `ProxyTunnelAgent`（CONNECT + 端到端 TLS）。
  真机实证：`bridge.log` 出 `git network: direct (no system proxy)`——本机确实没配代理，
  而**这条链路已经在设备上跑通了**；配了代理就会显示 `proxy host:port`。
  本地三条路径全验（`--jitless`）：经隧道克隆成功（代理收到 2 次 `CONNECT github.com:443`，2.1MB）、
  死代理立即报 `ECONNREFUSED`、407 立即报 `answered CONNECT … 407`、无代理直连正常。
  单测 `proxyFromEnv` 5 条（socks 明确拒绝而不是假装能隧道、坏 URL 不抛）。git 套件 33 → **38**。
  **三个坑（都记进 CHANGELOG）**：请求级 `createConnection` 被 Node 静默忽略（第一版代理**从未生效**，
  因直连恰好通而「测试通过」——假证据）；`createConnection` 必须同步返回 socket（异步建连放 `addRequest`）；
  socket 未 attach 时 `destroy(error)` 不触发 error、请求永久挂起。

- **`user_profile` 交付并真机闭环：跨会话画像第一次有了通道（2026-11-20 16:10 本地 / 16:27 真机）**。
  起点是一个问题：「切了对话，它还记得我吗」。答案原来是**不记得**——搜遍载荷，
  `dsh-persona` 是部署方写死的 persona 前缀、`dsh-personalized-recommendations` 推的是插件卡片，
  **没有任何插件写用户画像**；唯一跨会话的通道是 `dsh-agent-instructions`。
  **先取证再写代码**：直接 import 它的公开函数实测，没有靠 README 推断——
  `discoverBaselineInstructionFiles({cwd, dshHome, agentsHome})` 返回
  `$DSH_HOME/AGENTS.md` → `AGENTS.md` → `AGENTS.local.md`，`loadBaselineInstructions` 渲染出的
  `<system-reminder>` 里**三个文件的正文原样都在**；补测确认**没有 `.git` 目录也能找到项目根**
  （`findProjectRoot` 一路失败就返回 cwd），也就是工作区里放一份 `AGENTS.md` 就够。
  这也推翻了一个容易想当然的前提：指令文件不是「模型要主动去读」，是**每次会话第一条请求前系统自动拼进上下文**。
  实现 `@ohos/dsh-tool-user-profile`：写 `<DSH_HOME>/AGENTS.md` 里一个**受管区块**
  （`<!-- dsh:user-profile:begin/end -->`），区块外的用户 prose 一字不动；四个动作
  `add`/`replace`/`forget`/`list`；**每条带学习日期**（`- 2026-11-20 — …`），因为画像会漂移，
  日期让「哪条过期」可见，`replace` 是显式取代而不是两条并存。硬约束：80 条上限、单条 400 字符、
  受管区块 12KB（超了**拒写**不是静默截断）、stage+rename 原子替换、`fileName` 绝对路径直接拒
  （`join` 会把 `/etc/passwd` 悄悄折成 `<home>/etc/passwd`，第一版就是这么漏的，单测抓到）。
  验证：单测 **26/26**（含 `--jitless`）、`bash scripts/test.sh unit` 六套全绿（38/22/8/20/38/26）、
  `--dump-config` 新行命中、冒烟 `tools(27)` 里出现 `user_profile`；端到端再走一遍
  **写 → 下一轮上下文读到**（用户自己的「回答用中文」与新写的两条画像同时在），日期串也在。
  **真机闭环（2026-11-20 16:27，MatePad Mini / MLR-AL00，`deploy.sh` 调试签名）**：
  装机后 `bridge.log` 的 `tools(27)` 里出现 `user_profile`（其余 26 个不变）。用 `hdc fport` 从电脑
  直接驱动设备端 ACP，不走界面——
  ①让模型自己调工具：两轮 `tool_call` 各一次 `add`，模型答「两条都已记录成功」；
  设备上 `dsh-home/AGENTS.md` 落盘 508 字节，两条带 `2026-11-20` 日期，权限 644（应用 uid 所有）；
  ②**新开会话**问「你对我了解什么」→ 答「只有两条（来自会话加载的用户画像，记录于 2026-11-20）」，
  两条内容复述正确 —— 证明 `dsh-agent-instructions` 真的把它拼进了新会话的首条请求；
  ③测 `replace`：`match="HarmonyOS tablet"` 取代成更长的版本，设备文件里**旧行消失、只有新行**，
  不是并存 —— 这正是「画像会漂移」那条设计要的行为；
  ④**force-stop 冷启**后再开新会话，仍然答得出两条（含 replace 后的新措辞），
  `bridge-status.json` 为 `state: running / profile: ohos / node: v24.2.0` —— 跨重启成立。
  **一条顺带取证的平台事实**：`hdc shell` 写不进 `dsh-home/`（`cp` 报 `Permission denied`），
  说明沙箱边界在；而工具能写，是因为它跑在应用进程内、用的是 `node:fs` 而不是 `ctx.fs` 栅栏。
  另：`fport` 建立的隧道在 force-stop 后失效（`TCP Port listen failed`），重连要先重开转发。

---

- **`git` 真机第四轮：暂存式 `force` 与自解析 `~N` 双双闭环（2026-11-20 15:44，MatePad Mini）**。
  部署带「先克隆到临时目录再换入」+ `resolveRev` 的版本后，让模型按**失败路径优先**的顺序跑四步，
  原始返回全部从 `session.v4.jsonl.zstd` 取出（不看模型复述）：
  ①`snapshot qtepp/deepseek-harness-harmony` → `snapshot … (2.0 MB, 8.7s)`，8.7s 一次成功；
  ②`clone qtepp/no-such-repo-zzz-999 force=true` → 传输失败（`HTTP Error: 401 Unauthorized`，
  不存在的仓库被 GitHub 这样回），**关键在于第 ③ 步**；
  ③`status qtepp/deepseek-harness-harmony` → **`clean (164 paths)`**——证明 ② 的失败**没有动到**
  ①的快照。上一版正是在这里把仓库弄丢的；
  ④`clone … force=true` → `cloned … (4.4 MB, 13.0s)`，随后 `diff`（**不传 base/head**）→
  **`4 paths changed in HEAD~1..HEAD`** 并列出四条真实路径。设备侧核对：`repos/` 下只有正式目录、
  **没有 `.incoming` 残留**，`.git/shallow` 已不存在（全量历史）。
  **这一轮把三个此前只有本地证据的东西搬到了真机**：`force` 的失败安全性、`force` 的成功换入、
  以及 `HEAD~1` 在真机上的解析（js-git 自己不会）。

- **`git` 真机第三轮：`force` 把仓库弄丢了（2026-11-20 15:35–15:37，MatePad Mini）**。部署带
  `force` + `resolveRev` 的版本后，让模型走 `clone force=true → diff → log`。剧情是坏的：
  **第一次 `clone force=true` 撞上 `request to github.com timed out`**，而第一版 `force` 的实现是
  「先 `rm -rf` 再 clone」——于是平板上的唯一副本**直接消失**，后续两次调用只能报
  `repos/qtepp-deepseek-harness-harmony is not cloned yet`。这是我在**同一次会话里**先加 `force`、
  后加 `resolveRev`，却只本地验了「成功后」的路径，没验「失败时」。修法：`force` 改为
  **克隆到同级 `.qtepp-<slug>.incoming` 临时目录，成功后才删旧的再 `rename`**；失败时 `rm` 临时目录。
  本地对照实验（真实 GitHub + 一个不存在的仓库名）：失败后旧副本完好（1 commit，仍 shallow），
  成功后换入 128 commits、`.git/shallow` 消失、临时目录不残留。单测 33/33（新增 1 条 staging 断言）。
  **方法论**：破坏性操作只验 happy path 等于没验——`force` 的语义是「替换」，它的失败情形正是
  「用户丢数据」那一种，必须先把这条路径做出来再部署。

- **`git` 工具真机第二轮：又两个缺陷，其中一个是「上一轮修错了」（2026-11-20 15:22，MatePad Mini）**。
  把上一轮的三条文案改进重新部署后再让模型跑一遍，并从设备会话日志（`session.v4.jsonl.zstd`）取**原始
  返回文本**核对，不只看模型复述：
  - 三条文案确实变了（`diff` → `GIT_NO_HISTORY` 带根因；`pull` → 指明 `snapshot` + `force=true`；
    `clone` 已存在 → 同样指向 `force`），`log limit=3` 仍返回 `1 commit … 228436f`。
  - **新缺陷 1：文案让模型「删掉再重跑」，但设备上没有删目录的手段。** 26 个工具里没有 `rm`、没有
    `bash`、没有 shell——模型做不到，用户也做不到，而我们自己写的话把死路说成了出路。修法：`git`
    工具自己加 `force` 开关（它建的目录它自己删），三条文案全部改指 `force=true`。
  - **新缺陷 2（严重，上一轮改错的正是它）：`diff` 的默认 `HEAD~1` 在任何仓库上都不成立**，不是只有
    depth-1 快照。本地 `--jitless` 探针在 **128 个 commit 的全量 clone** 上直接证明：
    `isomorphic-git` 的 `resolveRef` **根本不实现 ancestry 语法**——`HEAD~1`、`HEAD^` 都抛
    `NotFoundError`；同一条提交用 oid 或 `main` 都能解析。也就是说上一轮「提前报 GIT_NO_HISTORY、
    建议 clone 全量历史」的诊断和建议**双双错误**：全量 clone 照样失败。
    修法：自己走父链（`resolveRev`），并**逐步校验父提交真的在对象库里**——shallow clone 的 commit
    对象**仍记录父 oid，但父本身不在库里**（实测 `parent NOT in object store: NotFoundError`），
    盲目跟指针会得到一个「能查出 oid、稍后在 js-git 里才炸且不报原因」的引用。
  **验证（本地，`--jitless`）**：全量 clone 上 `HEAD`/`HEAD~1`/`HEAD~3`/`main` 全部解析成功，
  `HEAD~1..HEAD` 走出 **4 条真实改动路径**；depth-1 快照上 `HEAD~1` 立刻给
  `GIT_NO_HISTORY: HEAD has fewer than 1 commit of history here …`。`force` replace 也实测：
  snapshot（shallow=true, 1 commit）→ `force` clone（shallow=false, **128 commits**）。
  单测 25 → **32**（6 条 `resolveRev` 用例，含「父提交不在库里」这一条）；六套件合计 **120**。
  **方法论教训**：上一轮我接受了模型对文案的解读就改代码，没在本地跑一遍 `diff` 的真实路径——
  于是把「所有仓库都失败」误诊成「只有快照失败」。**给模型的建议本身也是代码，必须实测**，
  不能靠读起来合理。

- **`git` 工具真机端到端：三个缺陷（2026-11-20 14:58–15:03，MatePad Mini）**。这一轮全部通过**模型**
  亲口触发（不是脚本调 API），共四轮：
  ①`log limit=3` → `1 commit in qtepp-deepseek-harness-harmony` + `228436f 2026-11-20 Instrument …`；
  ②`status` → `qtepp-deepseek-harness-harmony is clean (159 paths)`；
  ③三条守卫按名触发，错误都是单行、无堆栈——`pull` → `GIT_SHALLOW`、`clone` 已存在 → `GIT_EXISTS`、
  `action=sync` → `GIT_BAD_ACTION`（错误里列全 6 个合法 action）；
  ④`snapshot microsoft/vscode` → `GIT_TOO_LARGE`，`repos/` 下**没有**留下 `microsoft-vscode/` 半成品，
  前一份 depth-1 副本完好（159 路径 / 228436f），平板没被撑爆。
  **模型从错误文案里读出了三个真问题**（它写进了回答，我们据此改代码，这是本轮最有价值的产出）：
  - **超限发生在传输中途，文案却写成先验判断**。原文案 `needs more than 50 MB of packfile` 被理解成
    「事先探测到大小再拒绝」，模型据此对用户说「没有下载任何 pack 字节」。实测（本地 `--jitless` 探针，
    上限 5MB）是**真流式 abort**：`cap hit at 6299474 bytes` / 16.5s，即越过 6,291,456 之后立刻断连。
    改法：`tooLargeMessage()` 明说 `exceeded the N MB limit after X of transfer, so the connection was
    aborted mid-stream and the partial tree was deleted`，且删掉 `needs more than` 措辞。
  - **`pull` 与 `clone` 的建议互相打架**：`pull` 说「delete it and clone again」，`clone` 说「use action
    pull」。对一个 depth-1 副本，这条闭环是死的。改法：两处文案各自说清分支（full history → pull；
    snapshot → 删了重跑 snapshot；确实需要历史才 clone），并加 `existsMessage()` / `shallowMessage()`
    两个纯函数 + 5 条断言（含「不许出现 needs more than」）。
  - **`diff` 默认 `HEAD~1` 在 depth-1 副本上必然失败**，报的还是 `Could not find HEAD~1`——看起来像仓库坏了。
    改法：默认 base 且存在 `.git/shallow` 时提前抛 `GIT_NO_HISTORY`，说明「只有一个 commit，没有 HEAD~1，
    请显式传 base=/head=，或 clone 全量历史」。**未改默认行为**（显式传 base/head 仍然可用，模型当场验过）。
  单测 20 → **25**；六套件合计 108 → **113**。**契约**：这类"给模型看的拒绝文案"属于产品表面，
  必须可测——模型会把它们复述给用户，措辞错了就是我们在骗用户。

- **平板重装新载荷（2026-11-20 14:56，MatePad Mini / tablet）**：`assemble-payload` 重打后 zip
  **239,893,674 B**（+17.3KB；相对上一份的唯一变化是 `glob` 描述与新增的 `docs/STATUS.md`），
  `deploy.sh` 覆盖安装直接成功——**签名没再轮换，所以没有 `9568332`**；安装保留数据 ⇒
  **没有首启提问**（`profile_prompted` 仍在）。解包后逐项核对：`payload.stamp` = 新长度；
  `payload/docs` = **18 个**（含 STATUS.md）；设备上 `dsh-tool-fs-search-js/index.js` 已含新描述；
  `bridge-status.json` 仍 `profile: ohos` / `node: v24.2.0` / `wasm: false`；`bridge.log` 给
  **`tools(26)`（含 `git`）** 与 `search=auto (deepseek-official for deepseek-official)`。
  界面实拍：双栏成立，上一轮 git 会话原样还在（轨迹条「有失败 · 9 步 · 17.0s」就是那次超时重试）。

- 已交付并真机验证：冷启动恢复、会话 resume、文件预览（网页/图片/文本）、能力开关、
  项目分类（创建/切换真机验证，每项目独立 workspace）。
- **聊天体验对齐 dsh-go（2026-11-12，纯客户端，无协议改动）**：①**插话队列**——跑动中发送
  改为入队（`Index.queued` + `flushQueue()`），输入框上方排队条可单条撤回，「立即发送」先
  `session/cancel` 再续发（ACP 无 steering，见 §4.2）；②**待办条**——`todo_write` 参数投影成
  `TodoItem[]`（`model/TodoModel.ets`），常驻输入框上方，冷启动/切会话按持久化轨迹
  `refreshTodos()` 重建，不依赖服务端投影通道；③**上下文小环**——从 `usage_update` 的
  「上下文 used/size」注记算占用率（70%/90% 两档变色），点开 toast 给精确值；④**引用追问**
  ——长按消息 ›「引用到输入框」生成 `>` 引用块；⑤**会话搜索**——会话栏顶部按标题过滤；
  ⑥**目标条（只读）**——`create_goal`/`update_goal` 参数投影（`model/GoalModel.ets`），与待办条
  同法重建，编辑动作在 ACP 无通道故只读；⑦**重新回答**——保留到该问题前的历史，新会话重发，
  原会话不动（ACP 服务端上下文从本轮重启，toast 明说）；⑧**完成摘要**——轨迹条收成
  「已完成 · N 步 · 8.4s」，失败/中断分别转红与标注；⑨**凭据遮挡**——`common/SecretMask.ets`
  只遮挡渲染（前 8 位 + 可展开），存储/复制/重发保真；⑩**系统通知**——后台时一轮完成/出错/
  待审批发本地通知（`common/Notify.ets`，前台不发、首次用才要授权）；⑪**图片存相册**——
  全屏查看器用 `SaveButton` 安全组件换临时媒体写权限再 `createAsset`，不申请受限权限
  （`common/Gallery.ets`）；⑫**斜杠命令面板**——`/` 只映射本地动作（8 条），引擎命令 ACP 无通道
  故不列（含 `导出对话`：`model/Export.ets` 把转录写成 Markdown 存进 `workspace/exports/`，
  因为 ACP 没有 `session/export`）；⑬**`@` 文件引用**——`common/WorkspaceFiles.ets` 索引工作区（深度 3 / 300 条 / 跳过
  node_modules 等），4s TTL，插入相对路径；⑭**六套主题色**——`common/Theme.ets` +
  `AppStorage['accent']`，9 个组件 `@StorageLink('accent')` 绑定，只换强调色、背景保持中性。
  **语音输入 / 朗读：上一版结论已勘误（2026-11-15）**。旧文写「本机 SDK 不含 `@kit.CoreSpeechKit`」，
  实测**存在**：`<DevEco>/sdk/default/hms/ets/kits/@kit.CoreSpeechKit.d.ts` 提供
  `speechRecognizer`（离线、中文、since 4.1.0）与 `textToSpeech`（中英、三种音色）；
  写一个 `import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit'` 的探针文件，
  `devecocli check arkts` 直接通过。**因此语音输入与朗读是 A 级（纯客户端可做），不是 C 级**，
  真机还需确认设备带 `SystemCapability.AI.SpeechRecognizer` / `SystemCapability.AI.TextToSpeech`。
  旧结论错在只看 `openharmony/ets/kits`，没看 `hms/ets/kits`。
  **已实现并真机验（2026-11-16，平板 MatePad Mini）**：`common/Speech.ets` + `common/ReadAloud.ets`。
  （该设备当时记为「手机」，2026-11-20 查明是平板，见 §6 设备身份。）
  真机结论：**syscap 在、引擎起不来**——麦克风按钮渲染出来了（说明 `canIUse` 为真）、授权弹窗与
  我们写的理由串正常显示，但 `createEngine` 返回 **1002200001**（设备日志 `AI_COMMON:
  CreateEngineErrorByCallback Failed to create engine [callback]`）；朗读同样，
  `AI_TEXT: Create Engine Error! engineNo 0`。两者都指向**离线中文语音包/系统语音包未安装**
  （模型是单独下载项，不在 App 内）。**降级已验证**：识别失败后按钮立刻隐藏，并把
  `speech_asr_usable=false` 写进 preferences，重启后不再出现（实测 force-stop 重启后按钮消失）；
  toast 文案「语音引擎启动失败（1002200001）：可能缺少离线中文语音包」。
  **复位入口（已真机验，2026-11-16，CMM-AL10 / API 26）**：设置页在 `!speechAsrUsable` 时显示「语音输入 / 重试」一行，点重试清标志并写
  `AppStorage['speechAsrUsable']`——`ChatView` 用 `@StorageLink` 绑这个 key，所以装好语音包后
  **不用重装 App**，回对话就有麦克风。**设备限制记录**：另一台旧平板装不上
  （`code:9568297 install failed due to older sdk version`），只有手机能跑。
  **重试流程已真机验**：点麦克风 → 授权 → 引擎失败 → 输入框麦克风消失 → 设置出现
  「语音输入 / 上次引擎启动失败，装好离线语音包后点右边重试 [重试]」→ 点重试 → 该行消失 →
  回对话麦克风回来（**未重装、未重启**）。
  **工具表差异的结论**：新手机 boot-report 是 `tools(21)`、缺 `read/write/edit/read_image`，
  一度怀疑是升级回归；查 `files/patches/user.patch.yml` 发现是本机**能力开关把 `tool-fs` 关了**
  （`- id: tool-fs / disabled: true`）——不是 bug，是开关生效。旧手机那份 patch 没关，所以 25 个。
  麦克风按钮仅在 `canIUse('SystemCapability.AI.SpeechRecognizer')` 为真时渲染；朗读入口在长按菜单，
  同样先查 `SystemCapability.AI.TextToSpeech`。**API 签名坑**：`startListening` 的 `StartParams`
  必填 `audioInfo{audioType:'pcm',sampleRate:16000,soundChannel:1,sampleBit:16}`；
  `finish(sessionId)` 必须传回会话 id；`speak(text,{requestId})` 的回调挂在 `engine.setListener` 上
  （不是 speak 的第二个参数）。`spokenForm()` 5 个单测。真机验收待设备在线。
  本地验证：`bash scripts/test.sh arkts local` 全绿（arkts 40 文件 + LocalUnit 通过；
  `entry/src/test/LocalUnit.test.ets` 覆盖 `SecretMask` / `Typography` / `TodoModel` / `GoalModel` /
  `TimelineNode` / `Rollback`（纯函数部分）六个模块，共 27 个用例）。
  **真机验收（2026-11-12，手机，ACP profile，`scripts/deploy.sh` 调试签名）**：冷启与安装正常；
  通过的有——`/` 命令面板（9 条）、`@` 文件选择与插入（相对路径）、`/导出对话`（真实写出
  `workspace/exports/<标题>-<时间>.md`，模型随后能读到）、待办条（3/3 全绿）、目标条
  （进行中 → 已完成）、完成摘要（`已完成 · N 步 · 2.6s`）、上下文小环、凭据遮挡
  （`sk-abcde…` + 「已隐藏 1 处凭据」）、排队（跑动中入队、settle 后自动发出，模型确认收到）、
  主题切换（琥珀，重启后保持）、重新回答（新会话「· 重答」）、长按菜单五项。
  **外观三档（跟随系统/浅色/深色）已真机验成**：浅色与深色均重启后保持；**暗色必须在启动期应用**
  ——运行中 `setColorMode` 会重建窗口并让 ArkUI 树变黑屏（真机实测），因此 `EntryAbility.onCreate`
  用 `getPreferencesSync` 先读 `appearance` 再 `loadContent`，设置页只落盘 + 提示重启。
  **桌面快捷方式「新对话」**：`shortcuts.json`（profile）+ `ohos.ability.shortcuts` 元数据 +
  `AppStorage['pendingShortcut']` 交给页面；`aa start --ps shortcutId new_chat` 实测打开「新会话」。
  桌面长按菜单未显示该条目（启动器行为），功能路径已验证。
  **图片存相册已真机验成（真手）**：长按对话图片 → 全屏查看器（修了父手势吞子手势与顶栏落进
  状态栏两个真机缺陷）→ 点「保存图片」→ 弹出系统授权框 → toast「已保存到相册」。
  **自动化点不动它**：`SaveButton` 是安全组件，`uitest` 注入点击不触发授权，只能真手验。
  **分享卡已真机验成**：长按回复 ›「分享为图片」→ 系统分享面板显示「分享 1 项 · 16.82 KB」；
  记录一条契约：`SharedRecord.uri` 必须用 `fileUri.getUriFromPath()`，手拼 `file:///data/...`
  会被 `show()` 以 `IPC data is oversized` 拒绝。
  **对话字号四档已真机验成**：设置 › 对话字号切「特大」后气泡文字高度 52px → 68px（1.3×），
  Markdown 正文与代码块同步放大，按钮/说明文字不变。
  **重启丢回复已修（真机发现，严重）**：`session/prompt` 响应与 `session/update` 流分帧到达，
  回合结束的 `persist()` 早于回复行创建 ⇒ 落盘只有提问。改为 `settlePersist()`（先
  `drainAcpUpdates()` 再存）+ `drainAcpUpdates()` 在 `!turnInFlight` 时补存。日志取证：
  修前 `n=8 u=8 a=0`，修后 `n=12 u=11 a=1`，重启后回复仍在。
  **子代理独立成类已真机验成**：`subagent` 调用有专属动词/颜色/图标，回合摘要显示
  「已完成 · 5 步 · 1 子代理 · 3.3s」，展开轨迹里那一行写着「子代理 | subagent」。
  **会话未读标记（渲染与清除已真机验成）**：停应用后往真实 preferences 的 index 行写
  `unread: true`，重启打开 rail → 该行右侧出现强调色圆点；点开该会话 → 圆点消失，存储里
  `unread` 变回 `false`。**自动置位那一半（回合进行中切走）只有代码路径，未真机复现**——
  多次尝试都赶在回合结束之后。
  **会话置顶已真机验成**：长按 ›「置顶」后该会话跳到列表首位、标题前出现「置顶」标签；排序为
  「置顶优先、再按更新时间」。**记录一条设备契约**：`sys.symbol.pin` 编译期能解析、运行期不绘制
  （`person_2` 等其它符号正常），凡是「图标缺失就看不出来」的语义都不要只靠 SymbolGlyph。
  **会话归档已真机验成**：长按 ›「归档」后该会话从默认列表消失、标题旁出现「已归档 1」；
  点它切到归档视图（标题变「已归档」、旁边「返回」），里面只有被归档的那条；长按 ›「取消归档」
  后归档视图变空并提示「没有已归档的会话」，返回默认列表该会话已复原。归档是视图过滤，
  转录与工作区文件不动。
  **每轮用量已真机验成**：注记显示「上下文 5126/1048576 · 本轮 +92」；上下文小环仍然渲染
  （`Progress` 节点存在即证明解析没被后缀打断）。**契约**：注记是「前缀 + 数字/数字 + 可选后缀」，
  任何解析它的地方都必须只取开头数字（`leadingNumber`），别用 `Number()` 整段转换。
  **会话多选已真机验成（批量归档方向）**：标题旁「选择」→ 行首出现勾选圈、底部「归档 0 / 删除 0」
  置灰；勾两行 → 「已选 2」、按钮变「归档 2 / 删除 2」并可点；点「归档 2」→ 两条从列表消失、
  标题旁变「已归档 2」。随后在归档视图里逐条「取消归档」，恢复原状、归档视图显示
  「没有已归档的会话」。**批量「取消归档」走同一按钮（归档视图里即取消）但未单独点过**；
  批量删除未点过（会真删数据，留给用户自己决定）。
  **会话内容搜索已真机验成**：搜「微内核」→ 标题无匹配、内容匹配 1 条（答 · 图片请求 +
  「…鸿蒙微内核、Linux 内核与 LiteOS…」），点结果进入该会话。**边界写死**：只扫
  `SessionStore` 缓存（每会话 200 条），不读服务端 zstd 日志——UI 上不要暗示「全部历史」。
  **自动化任务（schedule）已实测关闭为「不可行」**：把 `schedule` + `tool-schedule` 两行插进
  ohos bundle 后重打载荷、本地起 runtime，日志给的是
  `schedule (@deepseek-ai/dsh-schedule): pending (waiting for service: sessionController)`——
  它依赖 `@deepseek-ai/dsh-api-session-controller`（32 个 peer 依赖，含 `dsh-api-gateway` 整套
  HTTP 面），不是「补个插件」能补的，缺的是宿主服务。两行已回滚、载荷已重打、本地启动回到
  零警告。**方法论**：先本地 `--profile ohos` 起一次 runtime 看挂载结果，再决定要不要装机。
  **消息文件 chip 重复已修（用户真机发现）**：同一文件在消息里被写成
  `file:///data/…/x.html` 与 `x.html` 时出了三个 chip（chip 只显示 basename，看起来一模一样）。
  `refsFromText` 原来只按完整路径字符串去重，现在「一条是另一条的 `/` 边界后缀」即折叠；
  同名不同目录仍分开。**契约**：chip 展示的是 basename，所以去重键必须比展示名更粗——按路径
  精确去重等于没去重。真机验成：该会话从 3 个 chip 变 1 个。
  **会话详情已真机验（2026-11-16）**：`/会话详情` 弹出，读到「上下文 39508 / 1048576（4%）」
  「9 步」「没有待办」「没有目标」「1 个：grandpa-fitness-plan.html」。
  **会话详情（原记录）**：`/会话详情` → `detailSheet()`，一页汇总上下文 / 轨迹（步数·失败·子代理）/
  待办 / 目标 / **改动文件**（复用 `pathsInToolInput`，与回撤同一批路径）/ 产物数。纯只读，无协议改动。
  **用量统计已真机验（2026-11-16）**：发一轮后设备 preferences `dsh_usage` 里是
  `<string key="ledger">[{"day":"2026-11-16","tokens":573,"turns":1}]</string>`，与注记
  「本轮 +573」一致；装后首启显示「还没有记录」（空态正确）。
  **用量统计（原记录）**：`model/Usage.ets` 把每轮 `usage_update` 的 delta 累计成日账本
  （preferences `dsh_usage`，保留 60 天，跨会话），设置页显示「今天 +X · 近 7 天 +Y」。
  **契约**：delta≤0 时只计轮次、不计 token——上下文注记本来就只在真实增长时报 delta，
  记 0 会造出「有轮次没用量」的空行。7 个单测；真机验收待设备在线。
  **本地模型扫描（2026-11-16 真机验成一半）**：设置 ›「本地模型」›「扫描」在 CMM-AL10 上跑通——
  按钮进入「扫描中…」、逐个探 12 个端口、结束后渲染结论。本机结论是
  「没有发现：端口 8080 / 8000 / 11434 / 1234 等都没有响应 /v1/models」，与 hdc 侧取证一致
  （该机监听端口只有 4517/33985/51108 和几个系统随机口，306 个应用里无本地推理 App）。
  **接入路径未验**：没有真实服务可接，`llm-pi-ai` 路由写入后「模型出现在选择器」这一步只有代码、
  没有证据。**契约**：`llm-pi-ai` 由 dsh-base 挂载但空转（`providers` 为空则零路由），
  block 里 `api: openai-completions` 是本地服务通用协议；`apiKeyEnv` **不要写**——环回服务不鉴权，
  编一个运行期读不到的 env 名反而会让路由校验失败。
  **`.credentials.yaml` 权限导致启动失败（2026-11-19 真机发现，严重）**：升级到 0.2.2 后
  `dsh-credentials-local` 载入时 `assertOwnerOnly` 拒绝 644 的文件，报
  `dsh: startup failed: 1 required plugin did not activate` / `Failed plugins (1): credentials`，
  于是**每次启动都失败**。根因是它自己首次写盘用的默认 mode 644。
  修法：`bootstrap.cjs` 的 `tightenKeyFile()` 从只收 `.api-key` 扩展到同时收 `.credentials.yaml`
  并打印原 mode。**契约**：ArkTS 没有 chmod API，这个窗口只能在 Node 起来后关，
  所以**首次运行仍会留下 644**，靠下一次启动修好；hdc 侧也 chmod 不了（`Operation not permitted`）。
  **通知未验成**：设备 `allowEnableNotification=false`，`requestEnableNotification` 既不弹框
  也不改状态，需在 系统设置 › 通知 › TA Harness 手动打开后再验。真机暴露并修掉的 4 个缺陷见
  `CHANGELOG.md`（手机端回调缺失、`@` 缓存键、重答标题/多余提示、通知授权时机）。
- **0.2.2-rc.5 + 首启引导已真机闭环（2026-11-20，手机）**：装机后首启弹出「选择运行模式」，
  点「用 ACP」→ **同一次启动**即以 `--profile ohos` 挂载（`bridge-status.json` 的
  `profile: ohos`、`node: v24.2.0`、`wasm: false`），**不需要重启**——提问发生在 `boot()` 之前。
  `bridge.log` 两条关键行与本地一致：`tools(25)` 与
  `web: search=auto (deepseek-official for deepseek-official)`（不再误报 ambiguous）。
  **真实一轮搜索跑通**：`web_search`×4 + `web_fetch`×1，模型给出带来源的一句话结论；会话日志里
  `web/deepseek-search-llm-request` **出现 10 次**、端点是 `https://api.deepseek.com/anthropic/v1/messages`
  ——证明 rc.5 的**服务端 Messages 搜索**路径在设备上成立（旧 Search API 不会追加该事件），
  且 fetch-shim 扛得住这个新请求形态。同轮快照：`sandbox/mode=workspace-write`、`approval/policy=ask`。
  **装机坑（新设备必踩）**：`build-profile.signing.json5` 里的 DevEco 加密密码会与
  `~/.ohos/config/` 下的 `.p12` 失配（报 `11014003 Init keystore failed / keystore password was
  incorrect`）。修法是 `devecocli signature generate --force` 重新生成，然后把新的
  `build-profile.json5` 覆盖到 `build-profile.signing.json5` 备份、再 `git checkout
  build-profile.json5`。注意它复用了同一组文件名（哈希后缀相同）——**覆盖的是内容**，这正是旧
  备份密文对不上的原因。

- **第二次装机（2026-11-20，含 docs 载荷 + 通知诊断）**：重打包后 `payload/docs/` 带 **17 个
  markdown**（当时计数；本文件搬进来后是 **18**。构建期快照，权威副本仍在仓库；`assemble-payload.mjs`
  的 `stageDocs()` 拷 `docs/*.md`）。
  重装后**首启不再问运行模式**（`profile_prompted` 跨重装保留），`bridge-status.json` 仍是
  `profile: ohos`，`tools(25)` / `search=auto (…)` 不变。**踩到一个装机的顺序坑**：`aa start` 对
  **仍在后台运行**的应用只是「拉到前台」，不会重跑 `Index.init()` ⇒ 新载荷解包不会发生
  （`payload.stamp` 仍是旧 zip 长度）。换载荷后必须 `aa force-stop` 再启动，或从桌面冷启。
  **通知：发得出去，进不了当前用户的列表**。hilog 实证系统侧收到了它——
  `NotificationParserFactory: Parse notification __100_20020319_com.qtepp.taharness__4517 … appLabel:"TA Harness"`、
  `NotificationDataManager: SaveNtf …, isUpdate: true`——但紧接着
  `Parse … failed, invalid creatorUserId: 100`（`currentUserId: 101`，`errorCodes:[999]`，`check data fail`），
  通知面板里因此看不到卡片。根因是**设备的用户态**：应用 uid `20020319`（user 100）与当前界面用户 101 不一致，
  公开 API 里**没有** `creatorUserId` 字段可以覆盖，我们改不了。待确认的一处：我们的请求没设
  `notificationSlotType`（日志 `slotType: 65535`），下一轮换一台单用户设备时顺手补上再验。
  为定位这类「静默丢弃」，`Notify.publish()` 现在会 `hilog` 一行 attempt/enabled/published。

- **`git` 工具已交付（2026-11-20，本地闭环 + 平板真机闭环）**：HarmonyOS 没有 `git` 二进制，也不可能有
  （禁 fork/exec），但"把仓库搬到手机上"这一步可以用纯 JS 补上。spike 先证明可行——`node --jitless`
  下 `wasm: false`，2MB 与 **92MB** packfile 都 clone 成功——再按实测设计成 `@ohos/dsh-tool-git`
  （六动作，`repos/<slug>`，走 bundle-insert）。**三个 spike 结论写进了代码**：内存 ≈100MB + 11×pack
  ⇒ `maxPackMb` 默认 50 且**中途 abort**（vscode 在 1MB 上限下 6.1s 触发 `GIT_TOO_LARGE` 并清掉半成品）；
  shallow 仓 pull 会撞 js-git 的 `TypeError` ⇒ `GIT_SHALLOW` 提前拒绝；js-git 的 `onProgress` 只报
  **对象数**不是字节 ⇒ HTTP 客户端自己写（`http.js`，字节计数 + 冲刷 + 超时），顺带解除了"必须靠全局
  fetch-shim"的耦合。**挂载实证**：`--profile ohos` 冒烟从 `tools(25)` 变 **`tools(26)`**，`git` 在表里；
  `--dump-config` 有 `- id: tool-git`。**本地验证**：插件单测 20/20（六个套件合计 108）+ 真实网络
  端到端（snapshot 2.0MB/7s、log 1 条、status 159 条目 clean、4 条守卫全部按预期失败）。
  **两处踩过的坑**：①`ctx.systemPrompt.getSectionOrder("TOOL_GIT")` 返回 undefined，section API 直接
  拒绝（`order must be a finite number`）⇒ 整个插件没挂载、工具表停在 25——所以不写 systemPrompt 段，
  引导语移进工具 description；②`Span`/`Text` 之外这次是**参数归一化**：`repo.git/` 要先剥斜杠再剥
  `.git`，否则网盘式地址会带后缀进 slug（单测抓到）。**真机闭环见下一条平板记录**：`clone` 一次
  `request to github.com timed out` 后重试成功（真实流量走过超时/重试路径），随后 `glob`/`read` 完成分析。

- **平板整机重装 + 链接点击 + `git` 端到端（2026-11-20，MatePad Mini / tablet / API 26）**：
  换设备后装不上，报 `code:9568332 install sign info inconsistent`——`signature generate --force`
  轮换过签名身份，机上旧包与新证书不同源。**契约：改过签名就不能覆盖安装，必须先卸**：
  `hdc shell bm uninstall -n com.qtepp.taharness`（带 `-k` 保留数据；不带 `-k` 全清）。
  本次按用户选择**全清重装**，因此 `profile_prompted` 也被清掉 ⇒ 首启重新问了一次运行模式（预期行为，
  不是回归）。重装后归档：`bridge-status.json` 给 `profile: ohos` / `node: v24.2.0` / `wasm: false`；
  `bridge.log` 给 **`tools(26)`（含 `git`）** 与 `search=auto (deepseek-official for deepseek-official)`，
  与之前设备记录一致；`devicetype=tablet` ⇒ ≥840vp 双栏（会话栏 + 对话）成立。
  **`git` 真机端到端**：模型自己 `git clone` 本仓库到 `repos/qtepp-deepseek-harness-harmony`
  （首次 `Error: request to github.com timed out`，重试成功——超时/重试路径被真实流量走过），
  随后用 `glob`/`read` 分析并答出沙箱四层；回答里把这次 clone 描述成「depth-1 snapshot，不能 pull」，
  与 `snapshot` 的语义一致。
  **`glob` 锚点语义由此写进 description（同一 commit）**：带分隔符的 pattern 锚在**会话工作区**，
  `path` 只缩小搜索范围、不改变锚点；两者同用时按「`path` 相对」理解会漏文件。
  **链接点击两条路径真机验成**：单链接（`m.pcpop.com/article_6958496.html`）→ 直接交给系统浏览器打开；
  一句多链接（转载 / 凤凰网 / 人民政协网）→ 弹「打开链接」选择框（标题下写明「这段文字里有多个链接」），
  选「凤凰网」后打开该文。**契约**：`Span` 没有 onClick、ArkUI 也没有 span 级命中测，只能用整段
  `Text` 接管点击；`linksOf()` 返回 1 条直开、≥2 条才弹框，否则就是「点了没反应」或「选错」。

- **官方 dsh 上游已核对（2026-11-15）**：`deepseek-ai/deepseek-harness` master `39163dd3`
  = `dsh` **0.2.2-rc.3**，我们载荷钉的是 0.2.1-rc.4。**ACP 协议面没变**（9 方法 +
  `$/cancel_request`、5 种 `session/update`、`session/request_permission`），客户端无需改动。
  官方 ACP README 明确写「intentionally exposes only the standard ACP v1 surface」，
  并点名 DSH 专有的 cards / plans / titles / todos / terminal views **不在 ACP 里**——
  这为我们「从 tool_call 反推待办/目标」的做法提供了官方依据。工具面差异与新工具见
  `docs/DSH-GO-PARITY-V2.md` §11.5。
- **升级后工具表已本地实测（2026-11-15，不需要设备）**：本地起 `--profile ohos` 并等 boot-report，
  `bridge.log` 给出 **`tools(25)`**：`create_goal, edit, exit_plan_mode, get_goal, glob, grep,
  list_agents, read, read_image, send_message, skill, subagent, subagent_fork, team_task_create,
  team_task_get, team_task_list, team_task_update, todo_write, update_goal, wait_agent, web_fetch,
  web_search, workflow, working_directory, write`。
  **真机复验（2026-11-16）**：设备 `bridge.log` 同样是 `tools(25)`，与本地完全一致。
  **这条证据替代了「必须真机确认工具表」的担心**：native executor 生效、`glob`/`grep` 仍是纯 JS 实现、
  没有 `bash`/`job_*`/`run_code`，符合预期。**0.2.2 白送的新工具**：`workflow`（多智能体编排）、
  `team_task_*` 四个（agent-team）、`read_image`、`exit_plan_mode`、`working_directory`、`wait_agent`。
  工具数从 21 → 25。
- **in-process PTC 运行时已交付并真机闭环（2026-10-27，P1①）**：
  `@ohos/dsh-ptc-runtime-vm`（worker_threads + `node:vm`）挂进 `ohos` profile，
  `dsh-bundle-ohos` patch 禁 stock `ptc-runtime`；`tools` 行现为 `mode: native`
  （2026-10-29 起，此前短暂为 `mode: ptc`）——native 下 21 个工具直出（glob/grep/read/web
  等），run_code 不在模型工具表（源码契约：仅非 native 注入）；ptc 模式则 wire 上只有
  run_code，其余经程序内 `tools.*` SDK。
  真机（手机 2026-10-27）全绿：worker_threads 在 arm64/`--jitless` 可用；模型一个 run_code
  程序内 `tools.write`×3 + `tools.glob` 计数正确答 "4"；contain-probe 回归——程序内
  `grep` path=`..` 仍被收口拒绝（`grep path escapes the session workspace`）。本地：
  单测 22/22（含 `--jitless`）+ dump-config + 冒烟 + 真实模型 E2E（`tools.glob` → "3"）。
  三条实测契约写死在 `docs/GAP-ANALYSIS.md` §L2：dsh-tools binding 是 resolve=值/reject=错误
  （不是 settle 对象）；cordis traceable 下 service 类禁 `#private` 字段（方法 `this` 是
  Proxy，品牌检查必炸，用普通属性）；amaro TS 擦除依赖 WASM ⇒ jitless 下设备不能跑 TS，
  executionInstructions 明示写纯 JS。
- **API 密钥热更新已交付并真机闭环（2026-10-27）**：`@ohos/dsh-credentials-live`
  挂进 `ohos` profile（bundle `dependencies` + `cordis.patch.yml` insert 双登记），真机
  bridge.log 实证 `[credentials-live] watching <dsh-home>/.api-key (dir-watch + poll every
  1500ms)` + `boot: ohos runtime mounted`——目录级 fs.watch（inotify）在应用沙箱可用。
  根因链：dsh 启动期 `loadLayeredEnv` 冻结 env 快照 ⇒ 运行中改 `process.env` 无效；外部改
  `.credentials.yaml` 需 0600/锁配合（`assertOwnerOnly`）且有竞态——都不如暂存文件轮询 +
  `credentials.set()`（provider 自身 set/unset 直更内存快照 + notifyUpdated，不经 watcher）。
  ArkTS 侧：`AppConfig.save` 以 temp+rename 原子写 `.api-key`（清 key 删文件）；`NodeHost`
  启动对空 key 删陈旧暂存（修跨重启清 key 失效 bug）；Settings 保存 toast 按 `host.isAcp()`
  分「即将生效」/「重启生效」。单测 8/8（载荷树内）+ 回归 fs-search 38/38、ptc 22/22
  （含 `--jitless`）+ dump-config（`credentials-live-ohos` 挂载、五处 disabled、`mode: native`）
  + 冒烟。
- **纯 JS 搜索插件已交付并真机闭环（2026-10-26，P0）**：自定义 `ohos` profile + bootstrap
  模板安装/acp→ohos 重映射；真机模型轮 `glob`/`grep` 真实命中（`danger-tablet-test.txt`），
  模型工具表无 bash/job_kill/job_list/job_output（P0a），权限三档快照不受影响；插件纯函数
  单测 37/37。根因（bundle 依赖声明）与机制：`docs/GAP-ANALYSIS.md` §7.1。
- fetch-shim 全家族替换修复已真机闭环（Gate 0，2026-10-26）：启动即 `boot: sdk runtime
  mounted`，0 fatal / 0 CRASH，桥 running，UI「dsh 已就绪」；启动期仍有一条良性
  `WebAssembly is not defined` unhandled rejection（与旧可用版本同类，不致命）。
- ACP 切换（Stage 1）已过 spike（`docs/SPIKE-ACP.md`，workbuddy）：进程内 PassThrough 劫持
  stdio + `runCli()` 零 spawn 可行；审批线上方法名 `session/request_permission`（snake_case）。
- `feature/acp` 分支（workbuddy，2026-10-26）：`host/bootstrap.cjs` 引入 `DSH_PROFILE`
  开关（默认 `sdk`，未改动 SDK 路径），`bridge-status.json` 增加 `profile` 字段；两个 profile
  均通过本地桥 smoke（sdk `initialize → serverInfo`；acp `initialize + session/new → sessionId`）。
  断线重连契约已实测并写入 §4.2。
- ACP 协议矩阵已在真机闭环（2026-10-26，fport 外部驱动 + `DSH_PERMISSION_MODE=read-only`
  测试构建）：initialize / session/new / set_config_option / prompt（审批 `allow-once` 放行
  后工具真实落盘）/ cancel（通知）/ 断线重连 / close / list / resume 全部实机通过；新发现
  set_config_option 选项集收缩契约（§4.2）。详见 `docs/SPIKE-ACP.md` §9。
- ArkTS ACP 客户端已交付（2026-10-26，手机+平板真机验证）：AcpProtocol/AcpClient + 审批
  弹窗 + 流式气泡 + usage + 停止（cancel 通知）+ 模型选择器（选项集收缩适配）+ resume
  降级 + **权限三档选择器**（只读/平衡/宽松；danger-full-access 平板端到端零审批落盘，
  三档快照写入 session log）。审批弹窗为根 Stack 固定覆盖层（不在 transcript 流内，
  早期「渲染进滚动流」记录是未提交中间态，已勘误）。
- **AcpClient 断线重连已交付并真机闭环（2026-10-27）**：客户端只报掉线（`onDisconnect`
  单发，error/close 同一掉线只报一次），恢复编排在 `Index.ets`——首退避 120s、×2、
  cap 300s、6 次尝试；无在跑轮次直接复附（对旧 sessionId prompt），孤儿轮走重置语义
  （`session/close` 掐孤儿轮 → `session/resume` → 标记「已中断」由用户决定重发，见 §4.2
  与 `docs/SPIKE-ACP.md` §11）。真机验证（手机）：断连 06:38:59.044 → 重连 06:40:59.076，
  **精确 120.03s** 按设计夺回客户端槽位，断连/复附消息均落 `dsh_sessions` 缓存。
  探针窗口注意：桥为**单客户端**（新连接 `replacing previous client` 顶掉旧连接），
  App 会在 2 分钟内自动回连抢回槽位——外部 fport 探针单轮（≤2min）不受影响，更长的
  外部实验须先 force-stop App，否则探针会被 App 的自动重连顶掉。
- 真机序列号等本地信息只记在本地记忆（`.workbuddy-ai/memory/`，gitignored），**不写进公开仓库**。
- **图片识别已修（2026-10-29）**：根因是**请求期投影**而非网络——dsh 把每张请求图投影到 DeepSeek 视觉网格
  （14px patch、3:1 下采样、1024 token），源图超预算就要 sharp 重编码；设备上 sharp 只有 darwin-arm64 +
  wasm32（jitless 无 WASM），`host/sharp-stub.cjs` 的编码阶梯 fail-closed，抛出的普通 Error 被
  `dsh-llm-deepseek` 统一包成 `DeepSeek Messages transport failed`/`TRANSPORT`（重试 5 次全白跑，请求未发出）。
  修法：桩的 `.jpeg()` 改为**原字节直通**并回报**源尺寸**（`toBuffer({resolveWithObject})` 契约），投影退化为
  no-op、由服务端自己下采样，代价只是上传变大；WebP/PNG/TIFF/GIF 仍 fail-closed（其字节不能冒充 JPEG）。
  本地验证：同一张 1320×2848 图 `readRequestImageFile` 从 `SharpStubError` 变为直通；ACP 端到端（无效 key）
  已到达服务端并返回 401 鉴权错误，不再是 TRANSPORT。单测 17/17。
- **dsh 升到 0.2.2-rc.5（2026-11-20，本地闭环，真机待验）**：从 rc.3 只隔两个补丁级 RC。
  逐包 diff 后**真正改动的代码只有三处**：①`dsh-web` / `dsh-web-search-deepseek`——搜索提供方
  改为按模型路由自动选，DeepSeek 路由走服务端 Messages 搜索（不按次收费、按 token 计费），
  端点固定 `https://api.deepseek.com/anthropic/v1`、**不跟随 provider baseURL**；②`dsh-llm-deepseek`
  ——新增 `stop_reason: 'refusal'` → `CONTENT_REFUSED`（先报已耗 token 再抛）；③
  `dsh-session-persistence-jsonl/lib/worker.cjs`——错误码表加一项。其余 13 个直接依赖的包
  **只动了 `package.json` 版本号**。组合配置 diff 只有一行：`web.searchProvider` 消失。
  包数 676 不变、工具表 25 不变、ACP 9 方法不变（`dsh-acp` 只改版本号）。载荷 zip **240MB**。
  **boot-report 同步修**：`describeCapability()` 原来只做「配置优先 / 唯一可用」，rc.5 下两个
  provider 可用就误报 `search=ambiguous`；现按 `dsh-web` 的路由偏好判定（`preferredSearchProvider()`，
  路由取自 `ctx.get('agentDefaultModel').currentSelection().provider`），输出
  `search=auto (deepseek-official for deepseek-official)`。单测 11 → 20。
  **版本钉死**：`assemble-payload.mjs` 的 `PINNED_DSH_VERSION = '0.2.2-rc.5'`，默认不再解析 `latest`
  （此前重打载荷会在不知情下换大脑）。
  本地验证：四组载荷单测 38 / 22 / 8 / 20（ptc 另跑 `--jitless` 22/22）+ `--dump-config`
  （12 行 disabled、5 行 insert 命中、`web` 行只剩 `fetchProvider`）+ 冒烟（`tools(25)`、
  `search=auto (…)`）+ `bash scripts/test.sh arkts local` 全绿（46 个文件 / LocalUnit 通过）。
  **真机未验**：重装后需确认一次真实 `web_search` 走服务端搜索能返回结果。
