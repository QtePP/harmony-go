# ONTOLOGY.md — 端侧用户本体（SQLite + 注入 + 面板）

> **状态：v1 真机闭环（2026-11-23，手机 CMM-AL10）。** 不再是探针：模型能写、新会话能自动带上硬约束、
> 用户能在「设置 → 它知道什么」里查看/删除/分享。探针阶段的 WAL/force-stop 数据留在 `docs/STATUS.md`
> 同一天的前一条记录里。
>
> 一句话：**本体存在手机 SQLite 里；硬约束每次会话自动注入；其余事实由 `ontology` 工具按需查询；
> 用户能看见模型记住了什么，并删掉它。**

## 1. 架构

```
ArkTS 设置面板 ──读──> <DSH_HOME>/ontology/snapshot.json
      │                         ▲
      └─写 command/*.json──> Node 插件（同进程）
                               │ node:sqlite
                               ▼
                        <DSH_HOME>/ontology/ontology.db
                               │
                agent/pre-step └─> 每个新会话的 pinned 事实块
                               │
                         ontology 工具 ──> 模型（remember/search/forget/export）
```

- **单一写者**：SQLite 只由 Node 插件打开；ArkTS 不直接开库，避免两个运行时抢锁。
- **单一命令通道**：面板每个删除动作写一个 `commands/<uuid>.json`，插件 fs.watch + 1.5s 轮询消费；
  每文件一个操作，避免“读一半再截断”丢命令。
- **快照**：每次变更后原子写 `snapshot.json`（面板读）与 `summary.md`（分享/人读）。
- **模型可见性**：pinned 事实走 `agent/pre-step` 注入；其余事实走工具查询。存储不等于可见。

## 2. 数据模型

```sql
entity(id, kind, name, aliases, created_at, merged_into)
fact(id, subject, predicate, object, object_kind, qualifier,
     confidence, source, observed_at,
     valid_from, valid_to, recorded_at,
     superseded_by, superseded_at, retired_at, pinned)
meta(key, value)
```

- `entity` 与 `fact` 分开：两个“小李”不会合成一行；`relation` 的 object 指向实体。
- **不覆盖事实**：单值谓词用 `superseded_by` 指向新事实；用户删除写 `retired_at`。
  历史还在，`search(history:true)` 能查“以前是什么”。
- **时间字段**：`observed_at`（何时得知）、`valid_from`/`valid_to`（现实世界生效区间）、
  `recorded_at`（系统写入时间）、`superseded_at`（旧值被取代的系统时间）、`retired_at`（删除）。
  当前值 = `superseded_by IS NULL AND retired_at IS NULL`；单值谓词同一时刻最多一条 live。
- `pinned` 由谓词决定，不由模型心情决定：过敏、饮食、语言、时区、称呼、沟通偏好永远注入。
- 受控词表在 `lib/vocab.js`（代码，不是表）。未知谓词直接报错并给出合法列表，防止 `favoriteColor`
  之类的垃圾谓词把图变成垃圾场。

### 2.1 时间与冲突

- **本机**：`remember` 带 `effective_at`（缺省 now）→ 新 `valid_from`。
  - 新 `valid_from` ≥ 当前 `valid_from`：新值成为 live，旧值 `valid_to = 新 valid_from`、`superseded_at = 写入时间`。
  - 新 `valid_from` < 当前 `valid_from`：作为**历史**写入，`valid_to = 当前 valid_from`、`superseded_by = 当前事实`；当前值不变。
- **同步**：先比 `valid_from`，再比 `recorded_at`；新者取代旧者，旧者写入历史；相等时本地保留。
- **删除**：`retired_at`；接收端本地 `valid_from > retired_at`（删除后重新添加）则保留，否则 retire。
- **`observed_at` 与 `valid_from` 分离**：用户说“我去年搬到上海”可以 `effective_at=去年`，而 `observed_at/recorded_at` 仍是今天。
- **schema v2 是硬断点**：`openStore` 发现旧 `fact` 没有 `valid_from` 时直接丢掉 `fact/entity/meta` 重建；不保留旧数据（本次用户明确同意）。`meta.version` 归零。

| 谓词 | 值类型 | 基数 | pinned | 说明 |
|---|---|---|---|---|
| `name` / `nickname` / `pronoun` | text | one/many | ✅ | 怎么称呼 |
| `language` / `timezone` | text | one | ✅ | 回答语言、时区 |
| `allergy` / `diet` / `avoids` | text | many | ✅ | 硬安全约束 |
| `communication_style` | text | one | ✅ | 简洁/详细/不要 emoji |
| `birthday` | date | one | | YYYY-MM-DD 或 MM-DD |
| `city` / `occupation` / `employer` | text | one | | 现居/职业/单位 |
| `likes` / `dislikes` | text | many | | 软偏好 |
| `relation` | entity | many | | subject=self, object=人, qualifier=角色 |
| `works_on` / `member_of` | entity | many | | self → 项目/组织 |
| `goal` / `note` | text | many | | 长期目标/兜底 |
| `deadline` | date | many | | subject=项目 |
| `met_on` / `promised` | date/text | many | | subject=人 |

关系约定：`remember({subject:'self', predicate:'relation', object:'妈妈', qualifier:'mother'})`；
关于妈妈本人的事实用 `subject:'妈妈'`（生日、见面、承诺）。

## 3. 工具

`ontology` 一个工具、八个动作：

| 动作 | 作用 | 关键行为 |
|---|---|---|
| `remember` | 记一条事实 | 重复 = no-op；单值谓词按 `effective_at` 决定取代还是写历史；未知谓词报错 |
| `correct` | 改一条事实 | 用 `fact_id` 指向旧值，`effective_at` 默认为 now；旧值 `valid_to/superseded_at` 被关闭，历史保留 |
| `forget` | 删一条/一批 | 默认软删；`fact_id`、`query`、`subject`、`predicate` 四选一；没有选择器时拒绝清库 |
| `search` | 查 | `history:true` 能查被取代/删除的旧值 |
| `list` | 概览 | pinned + 最近 10 条 + 计数 |
| `export` | 导出 | `markdown` / `json` / `turtle` 写到 `<dsh-home>/ontology/export.*`；`bundle` + `to_workspace:true` 写 `workspace/ontology/` 供项目同步 |
| `import` | 合并 bundle | `path` 指向 app files 目录内的 `ontology-bundle-*.json`；按 name/alias 对齐、只合并活事实、单值按 `valid_from` 新者胜；较早的 incoming 存为历史；面板「导入最新同步包」走同一逻辑 |
| `migrate_profile` | 迁移旧画像 | 默认 dry-run；`apply:true` 读 `<dsh-home>/AGENTS.md` 受管块，备份后逐条映射（姓名/过敏/饮食/语言/城市/关系→受控谓词，其余→带日期的 `note`），清空受管块；任一条失败则不清块；旧日期不会覆盖本体里更新的值 |

工具描述里明确：不用它记一次性对话、不记密码/密钥/身份证号；该用 `correct` 的时候不要新增一条
矛盾值。旧的 `user_profile` 已于 2026-11-24 停用；历史受管块用 `migrate_profile` 迁入本体，`AGENTS.md` 里用户自己写的 prose 保留。

## 4. 注入（硬约束怎么进模型）

`lib/store` 每次变更把 `meta.version` 加一。`agent/pre-step` 在请求组装后比较版本；版本没变就不动。
版本变了则读 pinned 事实，算一个 sha1 签名：

- 签名没变（只是写了非 pinned 事实）→ 不重复注入；
- 签名变了 → 追加一条 `source.kind='ontology'` 的 user message，正文是 pinned 块：
  “Known durable facts … this snapshot replaces earlier ones … do not re-ask”；
- pinned 全被删光 → 注入一句“Pinned ontology facts were all removed; do not apply any earlier snapshot”，
  避免模型继续用旧值。

注入只发生在新会话第一轮或 pinned 变化后的下一轮，不按分钟重复；重启/重连后的 resume 会再注入
一次（文本自述“replaces earlier”，所以旧快照不会赢）。块上限 2000 字符；pinned 谓词本身被限制在
身份/安全/沟通偏好，所以不会把整张图塞进 prompt。

另注册一条 `system-prompt` section（order 60）：告诉模型**什么时候**该主动 `remember`（姓名、语言、时区、
过敏、饮食、关系、项目、目标、承诺），否则它倾向于等用户说“记住”。工具描述负责“能做什么”，
system section 负责“什么时候做”。

## 5. 面板（「它知道什么」）

入口：设置 → 它知道什么 → 打开。面板是设置 sheet 内的全屏覆盖（不是嵌套 sheet，避免手机上两层拖拽面）。

- **列表**：每条显示谓词中文名、`硬约束` 徽章、主体、值、日期、来源（你告诉它的/它从对话里记的）。
- **搜索**：对主体/谓词/值/角色做本地过滤（快照最多 400 条）。
- **删除**：二次确认后写命令文件；插件下一 tick 软删并重写快照；面板 1.8s 后重读。
- **分享**：把 `summary.md` 交给系统分享面板（ShareKit）；实测 420B 的 Markdown 能打开分享。
- **状态**：空态、读取失败（Node 未就绪/插件未加载）、截断提示都明确写出来。
- **最近删除**：底部「最近删除 · N 条」可展开；列出最近 10 条软删事实（按 subject/predicate/object/qualifier 去重，取最新 `retired_at`），显示本地时间。已删除的事实不再注入；聊天里的「已记住」是当时的回执，不会随删除改写。

## 5.1 最近删除（面板底部）

`snapshot.json` 除了 `facts`/`pinned` 还写 `deleted`（最多 10 条）：`{id, subject, predicate, object, qualifier, retired_at}`。
来源是 `fact.retired_at IS NOT NULL AND superseded_by IS NULL`，按谓词/值/角色去重，取每个组合最近一次删除时间。
面板默认收起，只显示「最近删除 · N 条」；展开后是灰色卡片，带「已删除」徽章与本地时间，不提供恢复（恢复是显式重记）。

这条通道解决的是「聊天里说已记住、面板却是 0」的错觉：删除不会改写历史消息，但面板现在能证明这条事实曾经写入、
什么时候被删。真机（2026-11-24 06:27，手机 CMM-AL10）显示 0 条有效 / 5 条已删除（测试重复写入去重后），
平板 0 条有效 / 2 条已删除；两边展开都能看到「姓名 林舟」「过敏 花生」和本地删除时间。

## 5.2 跨设备同步（星闪 / 项目同步）

不传 `ontology.db`。DB 在本进程里开着（WAL + `-shm`），覆盖会坏库；而且整文件替换不能合并
接收端自己的事实。同步的单位是**可合并的 bundle**：

```
workspace/ontology/ontology-bundle-2026-11-23T19-38-04-314Z.json
  { format: "harmonygo-ontology-bundle", version: 1,
    entities: [{id, kind, name, aliases}],
    facts: [{subject, subject_name, predicate, object, object_id, object_name,
             object_kind, qualifier, confidence, source, observed_at,
             valid_from, valid_to, recorded_at}],
    tombstones: [{subject_name, predicate, object, object_name, object_kind,
                  qualifier, retired_at}] }
```

流程（两端都装本应用）：

1. 发送端面板「导出到工作区」→ 写 `workspace/ontology/ontology-bundle-<时间戳>.json`
   （时间戳是必须的：项目同步**同名不覆盖**，固定名第二次会被跳过）。
2. 设置 → 互联 → 项目同步 → 默认项目 → 取消「全部文件」→ 勾 `ontology` →
   传输选「星闪」→ 搜索附近设备 → 选对端 → 填对端 6 位配对码 → 开始发送。
3. 接收端：项目同步 → 接收 → 星闪 → 开始接收（显示配对码）→ 收下的文件落在
   `workspace/ontology/`。
4. 接收端面板「导入最新同步包」→ 合并；导入成功后 bundle 改名为 `.imported`，
   避免下次点击把已删除的事实又导入回来。

合并规则（v1）：

- 实体按 **name/alias** 对齐，incoming id 只作提示；alias 合并；未知谓词跳过。
- 只合并**活事实**；`(subject, predicate, object, qualifier)` 相同则跳过。
- 单值谓词比较 `valid_from`（缺失回落 `observed_at`），**新的赢**（旧值 `valid_to`/`superseded_at` 关闭并进历史）；多值谓词追加。
- **删除传播（tombstone）**：bundle 带软删事实的 `retired_at`；导入时先合并活事实，再处理 tombstone：
  本地同身份的事实若 `valid_from <= retired_at`，按 tombstone 的时间 retire；若 `valid_from > retired_at`
  （删除后重新添加），保留新的。被 `correct` 取代的旧值不是删除，不发 tombstone。
- 旧 bundle（没有 `tombstones` 字段）仍可导入；新 bundle 旧接收端会忽略该字段。
- 导入幂等：重复导入只增加 `skipped`；删除传播计入 `retracted`。

真机（2026-11-24 03:33–03:59，手机 CMM-AL10 ↔ 平板 MLR-AL00）：

- 手机导出 2 条事实（姓名林舟、花生过敏）→ 1 个文件 **1.3 KB**；星闪搜索到
  「niika的MatePad Mini 悦读版」，配对码 235902，接收端 **100% / 已接收 1 个文件 · 1.3 KB**。
- 平板「导入最新同步包」→ **2 条事实 · 1 个实体 · 2 条硬约束**；新会话问「我叫什么/对什么过敏」
  直接答「林舟 / 花生」，零工具调用。
- 两端随后把测试事实删回 0 条；手机上的测试 bundle 导入后已改名 `.imported`，再次点「导入最新
  同步包」仍为 0 条（真机复验，未复活事实）；平板的 bundle 已删除。
- 测试问答留在旧会话里，模型会从会话历史复述「你是林舟」——**删除本体不会改写历史消息**。
  验收后用消息菜单「回撤到这条消息之前」清掉旧会话里的测试问答，并删除测试会话；新会话复测
  回答「关于你，我什么都不知道」。用真实姓名/过敏做验收后必须做这一步，否则面板归零了，
  聊天里仍会复述。
- 同步过程中修了两个真机 bug：①导出时把 workspace 当成 `dsh-home/workspace`，实际是
  `<filesDir>/workspace`（`HOME` 的兄弟目录）；②导入路径校验只允许 `dsh-home`，把 workspace
  拒了；现在允许 app files 根下的两类路径。

安全边界：明文传输、配对码、只写项目工作区；bundle 是个人数据，和聊天一样只在两台设备之间走。
没有自动导入——接收端必须点一次「导入最新同步包」，这是有意的（同步进来的文件不自动进模型）。

## 6. 真机验收（2026-11-23 22:30–22:51，手机 CMM-AL10）

| 步骤 | 结果 |
|---|---|
| 启动插件 | `[ontology] ready version=0 facts=0 entities=1 pinned=0`；boot-report `tools(33)` 含 `ontology`（Python 开启） |
| 模型写入 | 一句“Remember: 我叫林舟、对花生过敏、不吃辣” → 模型调用 `ontology`，3 条事实，`version=3`，全部 pinned |
| 新会话注入 | 新建会话问“我叫什么？对什么过敏？不要调用工具” → 直接答“林舟 / 花生”，没有调用任何工具 |
| 面板 | 3 条事实、1 个实体、3 条硬约束；卡片显示中文谓词、硬约束徽章、日期、来源 |
| 删除 | 面板删“花生” → 二次确认 → 2 条；再删“辛辣”、再删“姓名” → 空态；每次 1.8s 内刷新 |
| 删除传播 | 删掉过敏后新建会话问“我对什么过敏？” → 回答“没有记录，不等于过敏”，不再说花生 |
| 分享 | 分享按钮打开系统面板，文件 `summary.md` 420B；面板内提示“已打开分享面板” |
| 冷启 | 多次 force-stop/重启，事实与面板计数保持；重启后仍能注入 |
| 失败路径 | 首次安装后启动曾出现 `libnode.so ... Operation not permitted`，重装 + 重启恢复；不是插件问题，但装机时先 force-stop 再 deploy 可避免 |

## 7. 边界（诚实清单）

- **本地存 ≠ 本地推理**：库在手机沙箱里，但被注入 prompt 的事实会发给模型服务商，和聊天内容一样。
  面板底部和文档都这么写，别对外说“零数据出域”。
- **没有静态加密**：`node:sqlite` 没有 SQLCipher；只有文件 mode 0600 + 应用沙箱。要加密只能走 ArkTS
  `relationalStore`，代价是 Node 侧要过桥。
- **OWL 只做导出**：OWL 2 DL 需要 Java 或 WASM reasoner（这台设备都没有）；`export turtle` 是给互换/备份
  用的，不是端侧推理。个人事实的封闭世界 + 时间 + 来源本来就更适合关系表。
- **旧 `user_profile` 已停用**（受管块仍在文件里时，用 `migrate_profile` 迁移；模型不再写第二份）。
  下一步要么把旧块导入本体，要么把 `user_profile` 降级为兼容层。
- **没有多设备合并**：当前只导出/分享；项目同步（TCP/星闪）没有接本体。
- **规模未压测**：面板/快照上限 400 条，`export` 最多 2000 条；10k+ 行未测。
- **平板已验（2026-11-24）**：面板导入/注入在 MLR-AL00 上验成；手机（单栏）与平板（双栏）的布局各自此前已验。
- **旧的 `spike.db` 还在** `<DSH_HOME>/ontology/spike.db`（探针留下的）；不影响本体，可手动删。
- **敏感事实没有审阅队列**：模型仍可能把不该记的写进去；面板的删除是事后纠错，不是事前同意。
- **主动记忆行为未单独验收**：`system-prompt` section 已注册（order 60），但真机验证都用显式
  「Remember / 记住」触发；下一轮用不带指令的一句「我对花生过敏」验一次，避免把“模型会主动记”
  当成已证。

## 8. 文件与命令

代码：

- `host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ontology/index.js` — 插件/工具/注入/命令通道
- `.../lib/vocab.js` — 受控词表
- `.../lib/store.js` — SQLite schema、实体消歧、supersede/retire、search
- `.../lib/render.js` — pinned 块、Markdown、Turtle、快照
- `.../test/*.test.mjs` — 26 个单测（含 bundle 合并/幂等/删除传播、最近删除去重、旧画像解析/映射、preserveNewer）
- `entry/src/main/ets/view/OntologyPanel.ets` — 原生面板
- `entry/src/main/ets/view/SettingsSheet.ets` — 入口
- bundle：`@ohos/dsh-bundle-ohos` 的 `cordis.patch.yml` + `package.json`

验证：

```bash
node scripts/assemble-payload.mjs --skip-install --skip-pack
cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ontology && node --test test/*.test.mjs
node scripts/assemble-payload.mjs --skip-install
devecocli check arkts entry/src/main/ets/view/OntologyPanel.ets entry/src/main/ets/view/SettingsSheet.ets
bash scripts/deploy.sh <serial>
# 设备侧
hdc shell tail -n 20 /data/app/el2/100/base/com.qtepp.harmonygo/haps/entry/files/dsh-home/bridge.log
```

拆掉：删 `cordis.patch.yml` 的 `ontology` 行与 bundle 依赖，重跑 assemble + deploy；再删
`<DSH_HOME>/ontology/`（DB、快照、摘要、命令）。不会动会话与工作区。

## 9. 下一步

- 平板双栏的面板/同步/导入/删除传播已验；剩余 ≥840vp 的字号复测。
- 旧 `user_profile` 的迁移器已做；后续可删掉旧插件代码/测试。
- 敏感谓词写入前确认（过敏/关系/财务）——把“事后删”变成“事前同意”。
- 10k 行压测与索引检查；`search` 的 FTS5 可选。
- tombstone 已随 bundle 传播；完整的双机 NearLink「手机删→平板跟着删」回环还没跑（传输层未变）。
- 若要跨工具/跨应用交换，再补 `export turtle` 的 SHACL 校验；仍不做 DL 推理。
