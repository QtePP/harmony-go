# 上下文账本（Context Ledger）与原生上下文面板

> 状态：**代码、单测与真机验收均完成**（2026-11-23，手机 CMM-AL10）。
> 相关代码：`host/profile-ohos/.../@ohos/dsh-context-ledger/`、`entry/.../model/ContextLedger.ets`、
> `entry/.../view/ContextPanel.ets`、`entry/.../pages/Index.ets`（入口与覆盖层）。

## 它回答什么

输入框旁的上下文小环只回答「窗口有多满」。这个面板回答另外三个问题：

1. **窗口里是什么**——系统提示 / 工具 schema / 消息与工具结果各占多少；
2. **前缀缓存有没有生效**——缓存读、未缓存输入、缓存写，以及命中率；
3. **最近几轮各花了多少**——每轮输入/输出、步数、缓存命中、窗口占用。

## 为什么需要宿主插件

dsh 已经把这些数算好了：`@deepseek-ai/dsh-token-meter` 维护 `contextBreakdown`
（system/tools/messages）、`contextPressure`（used/window）两个会话投影，`assistant/message`
事件自带 provider 的 `usage`（input/output/cacheRead/cacheWrite/reasoning）。

但 ACP 只转发 `usage_update`（used/size），**拿不到投影和缓存字段**。所以由
`@ohos/dsh-context-ledger` 在宿主侧订阅 `session/event`，把一份**只有计数、没有内容**的记录
追加到 `<dsh-home>/context-ledger.jsonl`，原生客户端读文件渲染。

没有 web 依赖、没有 UI 插件、没有模型工具 schema——对模型完全不可见。

## 记录格式（v1）

一行一个 JSON 对象，短键是为了控制手机上文件体积：

| 键 | 含义 |
|---|---|
| `v` | schema 版本，当前 `1` |
| `t` / `s` | 事件时间（ms）/ 会话 id |
| `turn` / `step` / `seq` | 轮次 / 步 / 会话事件序号 |
| `p` / `m` | provider / model |
| `ctx` / `win` | 上下文占用 / 窗口（`contextPressure`，缺失时回落到组成之和） |
| `sys` / `tools` / `msg` | 系统提示 / 工具 schema / 消息与工具结果的估算 token |
| `inp` / `out` | 未缓存输入 / 输出 token |
| `cr` / `cw` | 缓存读 / 缓存写 token |
| `rs` | reasoning token |

缓存命中率 = `cr / (inp + cr + cw)`。不联网、不取价格、不算钱。

## 写入约束

- 监听器在回合事件派发里同步执行：**不 await、不抛错**；写盘走串行 promise 链。
- 队列上限 64 行，磁盘卡住时丢账本行而不是卡住回合；失败只告警一次。
- 文件超过 **4 MiB** 轮转到 `.1`（只保留一代）；客户端两代都读。
- **跳过 subagent 会话**：面板展示的是用户正在看的这条对话。
- 读侧容忍撕裂的最后一行、空行、未知 `v`、`null`/数组等非对象 JSON。

## 入口与界面

上下文小环（`ChatView.contextRing`）点击 → `Index.openContext()` 读取账本（当前会话过滤 +
按时间排序）→ 在页面内渲染全屏覆盖层 `ContextPanel`。

> 覆盖层没有用 `bindContentCover`：该 Stack 已经承载文件预览 cover，父节点承载设置 sheet，
> 而同一节点只能挂一个这类模态（`Index.ets` 里已有同节点绑定破坏模态的注释）。

面板内容：占用条（70%/90% 变色）→ 缓存卡（命中率、缓存读/写）→ 组成条 + 图例 →
最近 12 轮列表 → 说明行。空状态明确写出「只在使用 ACP 连接方式时记录」。

## 已知边界

- **只有 ACP profile 有账本**：SDK 兼容 profile 不挂 `ohos` bundle。
- **不回溯历史**：插件只记录安装之后的新回合；老会话的旧回合不在面板里。
- 组成数字来自 token-meter 的**启发式估算**（不是 tokenizer 精确值）；`ctx` 优先用 provider
  回报的占用。
- 每次 `assistant/message` 读一次投影快照；长会话由 token-meter 的增量折叠兜底，不在插件里
  重复计算。
- 原生面板不显示价格：价格需要联网取价目表（`models.dev`），与「本地、无额外出站」冲突。

## 验收

本地已通过：

```sh
cd host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-context-ledger && node --test test/*.test.mjs   # 6/6
bash scripts/test.sh unit local                                                                          # 插件 9 套 + LocalUnit 全绿
devecocli build                                                                                          # BUILD SUCCESSFUL
```

真机已验（2026-11-23 19:25，手机 CMM-AL10，ACP）：

1. 跑一轮（`只回复：账本测试`）后，设备上 `context-ledger.jsonl` 立刻出现
   `turn:5 step:1` 的记录（`inp:159 / cr:76544 / ctx:76703`）；
2. 点输入框右侧小环 → 面板显示 `83.6k / 1.0M（8%）`、缓存 `95%`（1.5M 走缓存）、
   组成 `622 / 6.2k / 55.9k`、最近 3 轮（第 4/5/6 轮）；
3. **force-stop 冷启**后重开同一会话 → 面板数字与轮次不变（文件 20 行，`tail` 可见
   `turn:6 step:11`）；冷启后列表/输入行布局正常；
4. 返回键先关面板、不退应用（`onBackPress`）；
5. 未验：SDK 模式的空状态（切 profile 需要重启，会打断当前验收）。
   **空状态文案**已按「只在 ACP 记录」写好，下次切换时补一眼即可。
