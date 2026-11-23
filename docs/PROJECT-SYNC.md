# PROJECT-SYNC.md — 项目文件同步（WiFi 直连 → 星闪）

> 把某个项目的文件从一台装了 HarmonyGo 的设备发到另一台。**不是**聊天消息通道：
> 消息是「互联」里那一行 JSON，一个项目是带二进制文件的目录树，两者协议不同。
> 代码：`entry/src/main/ets/common/ProjectSync.ets`（协议 + 传输）、
> `entry/src/main/ets/view/SyncSheet.ets`（界面）、入口在设置 › 互联 ›「打开项目同步…」。

## 1. 现在能做什么

- 选择项目（默认项目 `workspace`，或 `workspaces/<projectId>`），发送**整个工作区**或**手动勾选顶层条目**。
- 可选把**手动勾选的会话**一起带过去：只带本机缓存的消息（最近 200 条），导入后标题带「（导入）」，
  图片不随会话走；接收端已存在同 id 的会话时**跳过不覆盖**（那边可能已经继续聊过）。
- 接收端打开「接收」后显示 **6 位配对码**与局域网地址；发送端填地址 + 码后开始传。
- 接收文件先写 `cacheDir/sync-incoming/`，全部到达且大小核对通过后才逐个 `rename` 进工作区——
  中断/取消不会在工作区留下半个项目。
- **同名文件不覆盖**：已存在的路径会出现在结果里（`skipped`），由用户自己决定怎么处理。
- 跳过 `.git` / `node_modules` / `.hvigor` / `.build`；单文件上限 64MB（超出的在结果里报出来）。

## 2. 线协议

同一帧格式，两个方向，大端：

```
[u32 headerLen][header JSON utf-8][u32 dataLen][dataLen 字节裸数据]
```

控制帧 `dataLen = 0`。帧类型：

| `t` | 方向 | 含义 |
|---|---|---|
| `hello` | 发送 → 接收 | `{version, code, name, files, bytes, entries:[{path,size}]}` |
| `sessions` | 发送 → 接收 | 可选：勾选会话的 JSON（`[{id,title,updatedAt,raw}]`，`raw` 是本地存储的原始转录） |
| `accept` / `deny` | 接收 → 发送 | 码对 → accept；错 → deny（附原因） |
| `file` | 发送 → 接收 | 开始一个文件 `{path, size}` |
| `chunk` | 发送 → 接收 | 一块数据，默认 **32KB**（塞得进星闪 65535 字节的包上限） |
| `fileEnd` | 发送 → 接收 | 该文件结束 `{path, size}` |
| `done` | 发送 → 接收 | 全部发完 `{files, bytes}` |
| `error` | 双向 | `{reason}`，取消时发送端也会发 |

背压：**一次只有一块在途**——`send()` 返回才发下一块。这是 socket API 暴露的唯一信号，
也保证内存平坦、不会把整个文件堆进系统缓冲。

## 3. 安全边界

- **不监听直到用户点「接收」**；一收到完整树（或失败）就关闭监听并清空 staging。
- **配对码**：接收端本地生成 6 位码，发送端在 `hello` 里重复；码不对直接 `deny`，一个字节都不写。
  （局域网端口若来者不拒，就是一个远程文件写入原语，这是本应用绝不能长的能力。）
- 只写**工作区内**：清单里的路径不允许 `..`（`resolveInside` 逐段拒绝），落盘路径全部锚在 staging 目标根下。
- 传输明文、不加密：同一局域网内的两台设备之间；跨网络/跨账号不在 v1 范围内。

## 4. 真机验证（2026-11-23，手机 CMM-AL10）

设备与 Mac 不在同一网段（`10.93.x` vs `192.168.43.x`），用 `hdc` 端口转发当桥梁，
Mac 上跑仓库里的 `scripts/sync-peer.mjs` 做对端：

- **设备接收**：`hdc fport tcp:4519 tcp:4519`，Mac 发送 `readme.md` + `sub/note.txt` + `sub/random.bin`
  （200000 字节随机数据）→ 设备 `workspace/` 里三个文件都在，`random.bin` 取回对 MD5
  **`ce4d0bf5060a6903b3ce744a5908e1a1` 与源文件一致**；界面显示「已接收 3 个文件」。
- **设备发送**：`hdc rport tcp:4519 tcp:4520`，Mac 监听 4520、码 `123456` → 设备界面上
  「已发送 3 个文件 · 195.4 KB」，Mac 端日志 `file … OK` ×3、`DONE files=3 bytes=200041`，
  收到的 `random.bin` MD5 同样一致。

- **会话同步**（同一轮）：设备勾选 1 个会话 → Mac 端收到 `sessions frame 778 bytes`
  （落成 `.sessions.json`，含 3 条消息、标题「你好」）；反向 Mac → 设备发一个改过 id 的会话 →
  应用里出现「来自 Mac 的会话（导入）」，点开能看到完整对话（`dsh_sessions` 里也有
  `session.<id>` 与索引行）。**只带本地缓存消息**：dsh 的服务端日志（`session.v4.jsonl.zstd`）
  不随行，所以接收端 `resume` 会新建服务端会话，这是 v1 的边界。

### 4.1 失败路径与边界（同一轮补测）

| 场景 | 结果 |
|---|---|
| **配对码错** | 接收端回 `deny`、界面「配对码不对，已拒绝」，**工作区零字节变化**；接收端随即关闭监听（再传要重新点「开始接收」拿新码——这是单次配对的设计） |
| **重复发送同一棵树** | 三个文件全部跳过，设备侧文件 mtime 保持第一次的时间（**不覆盖**） |
| **中文路径 / 嵌套目录** | `中文说明.md`、`子目录/嵌套.txt` 原样落盘；Mac 端 `diff -r` 子树一致 |
| **5MB 二进制** | 设备收下 5000000 字节，取回 MD5 与源一致（`249a76a3…`） |
| **整棵真实工作区 156 文件 / 7.9MB（含一个 clone 下来的 git 仓库）** | 设备→Mac 全部 `OK`，`DONE files=156 bytes=8286575`；Mac 端 156 个文件、5MB 大文件 MD5 仍一致 |

分帧的 UTF-8 编解码改成了自己实现（不再用 `util.TextEncoder/Decoder`）：`util` 在 host 单测里是桩，
帧会被当成损坏——三条 framing 单测一开始全红就是这个原因。现在 `FrameReader` 有 3 条单测
（跨读拼帧 / 一次读多帧 / 长度字段异常），协议在设备外也可测。

**设备内 loopback 回归**（`entry/src/ohosTest/ets/test/ProjectSync.test.ets`，进
`bash scripts/test.sh device`）：同一台设备上让接收端监听 127.0.0.1、发送端连过去跑完整流程，
断言文件数与**字节数**（staging 里写成空文件也能通过文件数断言，所以这里查 4096 与 22 字节）；
第二条用例用错配对码，断言发送端抛错、接收端报「配对码不对」、目标目录**一个文件都没有**。
这条测试是「协议两半真的能对上」的自动化证据，也是改传输层的回归网。

## 5. 电脑端（`scripts/sync-peer.mjs`）

电脑不是客户端，但它是**接收方**——手机 → Mac 传文件靠这个脚本，零依赖，只要 Node。

```bash
# Mac 接收（先跑这个，把打印出的局域网地址填进设备）
node scripts/sync-peer.mjs receive 4519 123456 ~/Downloads/from-phone

# Mac 发送（设备端先点「接收」，把配对码给它）
node scripts/sync-peer.mjs send 192.168.1.20:4519 123456 ./project Mac
node scripts/sync-peer.mjs send <addr> <code> <dir> Mac sessions.json   # 连带会话
node scripts/sync-peer.mjs watch ./project                              # 只预览清单，不发
```

它**不信任发送方**，与设备端执行同一套规则：路径含 `..` / `.` / 空段 / 绝对路径一律拒绝；
整棵树先落 staging、全部到齐并核对大小后才 `rename` 进目标；**同名文件跳过不覆盖**。
安全性质靠 `scripts/sync-peer.test.mjs` 8 条钉住（含在**真实接收器**上重放穿越清单，确认目标
内外都没有文件落地）。

**这里曾经有两个「报告成功但数据是错的」bug**（2026-11-23，都已修）：
①`stream.end()` 异步，紧跟的 `commit()` 在 flush 前就 `rename` ⇒ **每个收到的文件都是 0 字节**；
②`currentRel` 是共享状态，在异步回调里读到的是下一个文件 ⇒ **三个文件全记成最后一个的名字**。
两者都不会报错，只有比对 MD5 才发现——所以电脑端现在也有测试，且并进了 `bash scripts/test.sh unit`。

## 6. 星闪（第二条传输，同一套协议）

WiFi 直连要求两台设备在同一网段；星闪（NearLink）是近场链路，不需要路由器。协议**一行没改**：
`ProjectSync.ets` 现在把传输抽成 `SyncLink`（`send/close/onBytes/onClosed`）+ `SyncSession`
（收帧/落盘/配对码校验，与传输无关），TCP 与星闪只是两个实现。

- `common/NearLinkSync.ets`：`nearLinkSyncSupported()`（`canIUse(SystemCapability.Communication.NearLink.Core)`）、
  `scanNearLinkPeers(ms)`（`scan.startScan(null, …)` + `deviceFound` 去重）、`NearLinkSyncLink`
  （`connect({address,uuid,mtu:65535})` → `writeData` 每帧 → `readData` 喂给 FrameReader）、
  `NearLinkSyncReceiver`（`createPort(uuid)` + `startAdvertising`，第一包决定对端地址，回帧走 `writeData`）。
- 服务 uuid 固定 `7D5F6A2C-1B8E-4C3A-9F10-2A6B7C8D9E01`；分片仍 32KB（≤65535 的端口 MTU）。
- UI：项目同步面板里多一行「传输：WiFi 直连 / 星闪」，只在 `nearLinkSyncSupported()` 为真时出现；
  星闪发送要「搜索附近设备」选一台，星闪接收打开广告后等对方连；配对码仍然是协议层那道门。
- **状态：星闪真机双向验成（2026-11-23 15:38，手机 CMM-AL10 ↔ 平板 MLR-AL00）**。
  两个设备端用例各跑一半（`-s role receiver|sender`，见 `entry/src/ohosTest/ets/test/NearLink.test.ets`），
  两端都 `Tests run: 4, Pass: 4`：**17 字节文本 + 40000 字节二进制**从手机经星闪落到平板，
  接收端 `receiver finished files=2 error=[]`，`big.bin` 大小 40000 校验通过。
  打通前有四道坎，都是真机实测出来的，全部写进了代码注释：
  ① **发送端也必须 `createPort`**（官方文档：「发送端和接收端均需注册」）——不建端口时
     `connect()` 报 `1009700099`；
  ② **`connect()` resolve ≠ 通道可用**：接收端 `connectionStateChanged` 在 connect 返回约 10 秒后
     才变 `STATE_CONNECTED`，此前写出的帧全丢。发送端现在等这个事件（30s 超时）再发 hello；
  ③ **分片要按星闪的包大小**：协商出来的 `mtu` 事件里是 0，写 32KB 会被截成 ~7.2KB 并断链；
     星闪链路固定用 **4KB** 分片（`SyncLink.maxPayload()`，TCP 仍 32KB）；
  ④ **发送端不能在最后一帧后立刻断开**：`writeData` resolve 只是本地栈收下，接收端还没读完就
     `disconnect` 会丢尾巴。协议加了 `ack` 帧：接收端落盘后回 `{t:'ack'}`，星闪发送端等到 ack
     再关链路（TCP 不需要，`SyncLink.needsAck()` 区分）。
  诊断方法也沉淀了一条：测试进程的日志不可靠（hilog 取不到、`filesDir` 指向不存在的模块目录），
  改成 `setNearLinkLog()` 注入一个写 `context.cacheDir` 的 sink，用 `hdc shell cat` 取——就是靠它
  看到「连接 10 秒后才 CONNECTED」「32KB 被截成 7253」这两个关键事实。

## 7. 还没做

- **断点续传 / 冲突合并**：v1 用「整棵树 staging + 不覆盖」换确定性；重传从头开始。
- **加密与身份**：v1 靠配对码 + 局域网范围。
