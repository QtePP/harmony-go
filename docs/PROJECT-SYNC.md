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

## 5. 还没做

- **星闪传输**：协议与传输已解耦，接星闪只需实现 `scan → connect → writeData/on('readData') → disconnect`
  这套适配；但要在两台支持星闪且都装了本应用的设备上验，当前只有一台。
- **断点续传 / 冲突合并**：v1 用「整棵树 staging + 不覆盖」换确定性；重传从头开始。
- **加密与身份**：v1 靠配对码 + 局域网范围。
