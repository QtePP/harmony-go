# 端侧 Python（Pyodide，实验）

> **状态：spike（2026-11-23，手机 CMM-AL10）**。核心链路真机跑通，但**不是产品能力**：
> 默认关闭开关已做；没有输出文件桥、没有后台保活、没有 CSP/禁网，包也只预置了 numpy/pandas。
> 产品化前按 §6 的清单继续。Office 不走这条路，仍用纯 JS 的 `office_*`。

## 1. 为什么是 Pyodide，而不是 CPython 二进制

HarmonyOS 禁止 fork/exec，所以**不能 `spawn python`**；但可以把解释器**嵌进进程**——Node 就是这么嵌的。
两条真路：

| 路线 | 做法 | 代价 |
|---|---|---|
| **A. Pyodide（当前）** | 隐藏 WebView 的 Web Worker 里跑 CPython/WASM；Node 工具经文件桥调用 | +~23MB（core+pandas），首次 3–8s，内存 +~150–250MB |
| B. CPython + NAPI | OHOS NDK 交叉编译 `libpython`，NAPI 在进程内调用 | 不占 WebView，但 C 扩展要逐个交叉编译，1–2 周 |

`--jitless` 只作用于内嵌 Node 的 V8，**不影响 ArkWeb 的 JS/WASM 运行时**；Pyodide 在 WebView 里可用。
`resource://rawfile` 不能承载 Pyodide 的动态 `import()` / wasm `fetch()`（真机报
`Failed to fetch dynamically imported module`），因此 ArkTS 起一个 **127.0.0.1 的只读 HTTP server**
提供 `pyodide/` 资产；这也是当前唯一能让 `loadPyodide` 离线工作的方式。

## 2. 架构

```
dsh Node 进程                            ArkTS / ArkWeb
┌─────────────────────┐   req/res JSON   ┌──────────────────────────────┐
│ @ohos/dsh-tool-python│ ───────────────▶ │ PythonRuntime（250ms 轮询）   │
│  python_run          │ ◀─────────────── │   │ runJavaScript            │
└─────────────────────┘  <dsh-home>/python │   ▼                          │
                              /req|res      │ runner.html（主线程）        │
                                            │   │ postMessage             │
                                            │   ▼                          │
                                            │ pyodide-worker.js            │
                                            │   CPython 3.13 + pandas      │
                                            └──────────────────────────────┘
```

- **为什么用文件而不是端口**：Node 不能直接调 ArkTS；文件协议没有握手、两边都能重启、不需要监听端口。
  代价是 250ms 轮询延迟，对工具调用可接受。
- **为什么 Python 在 Worker 里**：主线程跑 `while True` 会把整个 WebView 连同定时器/导航一起冻住；
  Worker 可以被主线程 `terminate()`，这是超时能恢复的前提。主线程只做计时与消息转发。
- **资产服务**：`PythonHttpServer` 只服务 allowlist（`runner.html` / `pyodide*.js` / `.wasm` / stdlib zip /
  lock / `.whl`），只绑 `127.0.0.1`，随机端口，不做目录列表。
- **文件桥 v1（输入）**：插件按 `ctx.fs` 栅栏读工作区文件 → base64 → 请求 JSON → ArkTS → Worker 写入
  Pyodide 的 `/workspace/<basename>`。上限 8 个文件、单文件 5MB、总计 15MB。**输出暂不回写**。

## 3. 工具

`python_run(code, timeout_ms?, files?)`

| 参数 | 说明 |
|---|---|
| `code` | Python 源码；`print()` 与最后一个表达式的值都会返回 |
| `timeout_ms` | 默认 90s，最大 300s；超时由 Worker 主线程 terminate，下一次调用重新加载解释器 |
| `files` | 工作区相对路径数组，复制到 `/workspace/<basename>`；只读输入 |

| `pybot_reply(text, thread?, reset?, timeout_ms?)` | 调用内置 pybot（Hugging Face/Apache-2.0），按 `thread` 缓存记忆；首调 120s 默认、最大 300s；返回 `{reply, module, seconds, durationMs}` |

输出：`{ok, stdout, stderr, value, durationMs}`；stdout 上限 30k、stderr 10k 字符。
失败时抛 `PYTHON_FAILED` / `PYTHON_TIMEOUT` / `PYTHON_SANDBOX_DENIED` 等。

预置包：**numpy 2.2.5、pandas 2.3.2**（含 python-dateutil/pytz/six），随 rawfile 分发；
`loadPackage(['pandas'])` 在首次运行时加载；`packages: []` 可跳过它们。另内置 **pybot 压测样本**
（见 §4.1）。没有 `pip install`。

## 4. 真机结果（2026-11-23，CMM-AL10）

| 项 | 结果 |
|---|---|
| `sys.version` | 3.13.2（Pyodide 0.29） |
| `print(1+1)` | 3225ms（含首次加载） |
| pandas groupby | **7735ms**，`a 3 / b 3`，pandas 2.3.2 |
| CSV 文件桥 | `files:["data.csv"]` → `/workspace/data.csv` → `read_csv` 成功 |
| 无限循环 + 3s 超时 | 3.1s 返回；Worker 被 terminate；下一次正常调用 2476ms 恢复 |
| 后台 20s sleep | 前台应 20s，实际 **40.2s**（切后台 25s 期间被冻结，回前台继续） |
| HAP | **387MB**（Pyodide core+pandas 时 375MB；pybot 样本 +12MB） |
| 整进程内存 | Pyodide+pandas 加载后 **RSS 601MB / 峰值 680MB**；pybot 加载后 **648MB / 684MB**（含 Node） |

## 4.1 pybot 压测样本（Hugging Face / Apache-2.0）

> **归属**：pybot 是 Hugging Face 的 [`huggingface/pybot`](https://github.com/huggingface/pybot)（Apache-2.0），
> 由 1000+ 个 DeepSeek-V4.1-Flash agent 集群写成；**DeepSeek 是写它的模型，不是发布它的仓库**。
> 无权重、无训练、纯规则；约 64 万行 Python、528 个模块、零第三方依赖。它不是产品功能，
> 只是路线 A 的**大纯 Python 代码库压测样本**（26% SmolTalkBench 胜率，约 SmolLM-360M 级）。

- 资产：`host/pybot/pybot.zip`（12MB，含 `LICENSE`），`stage-pyodide.mjs` 拷到 `rawfile/pyodide/`；
  `PythonHttpServer` allowlist 放行；worker 在代码引用 `/pybot.zip` 时 fetch 并写入 Pyodide FS
  （HTTP 资产不会自动出现在 Python 的内存 FS 里）。
- 工具：`pybot_reply(text, thread='demo', timeout_ms=300000)`；同一 `thread` 的多轮共享记忆，
  `reset: true` 清空。它内部用 `packages: []` 跳过 numpy/pandas，并把 `/pybot.zip` 挂进 Pyodide FS。
- 用法：
  ```
  pybot_reply(text="hello, my name is Sam", thread="demo", timeout_ms=300000)
  pybot_reply(text="what is my name?", thread="demo", timeout_ms=30000)
  ```
- 真机（CMM-AL10）：冷启 **25.7s**（含 Pyodide+zip 导入），热回答 **777ms**（answers 路径）/
  **4002ms**（memory_store 路径）；多轮记忆 `You're Sam.` 成功；RSS **648MB / 峰值 684MB**；
  HAP 387MB。冷启 ≤60s、RSS ≤900MB 两个门槛过；热回答 0.8–4.0s，仍在 2–8s 估算内。
- **不证明**：不增加 dsh 工具能力（pybot 不读工作区、不调工具）、26% 胜率不适合当离线兜底、
  不解决 Office 渲染/pandas 分析。默认关闭，随 Python 实验开关一起启停。

## 5. 已知边界

- **后台会暂停**：WebView/Worker 在后台被冻结；长任务必须保持前台，或产品化时做前台服务/通知与超时策略。
- **文件只进不出**：Python 不能写回工作区；需要输出就打印文本，或用 `write`/`office_*`。
- **包固定**：没有 pip；除 numpy/pandas 与 pybot 样本外，`python-docx`/`lxml`/`Pillow`/matplotlib 未打包、未验。
- **安全未收**：WebView 仍有网络权限，Python 可经 `pyodide` 的 JS 桥/`fetch` 外传；`dshHost` proxy 已最小化，
  但没有 CSP/禁网；桥只允许工作区内文件，仍应把 Python 视为执行模型生成的代码。
- **5MB base64 未压测**：文件桥上限按 15MB 设计，实际只验了小 CSV；大文件要测 `runJavaScript` 字符串上限与内存。
- **默认关闭，已做成实验开关**：平台 patch 不 insert `tool-python-ohos`；Settings「Python 运行时（实验）」
  写入 `user.patch.yml` 的 `- insert:`，重启后 `tools(33)` 并挂载 `PythonHost`；关闭时 `tools(31)`，
  不创建隐藏 WebView、不起 loopback server。真机已验证开/关两态。

## 6. 产品化前的 go/no-go 清单

- [x] WASM + `sys.version`
- [x] 离线资产（loopback HTTP，不依赖 CDN）
- [x] numpy/pandas + 真实 groupby
- [x] 文件输入桥（1 个小 CSV）
- [ ] 5MB base64 进出、内存峰值、桥延迟
- [ ] 后台策略（保持前台/通知/冻结提示），长任务恢复
- [x] 死循环/超时/Worker 重启
- [x] pybot 大纯 Python 库压测 + `pybot_reply` 工具：冷启 25.7s / 热 0.8–4.0s / RSS 648MB（样本，非产品）
- [ ] micropip 离线装纯 Python 包；逐项验 lxml/Pillow/python-docx
- [x] HAP/内存粗测
- [x] 默认关闭的 Settings 实验开关 + `PythonHost` 门控（真机开/关两态验成）
- [ ] CSP/禁网/桥最小权限；明确“模型代码”风险

## 7. 构建

Pyodide 资产是构建产物，不进 git：

```bash
node scripts/stage-pyodide.mjs        # 从 host/pyodide/pyodide-0.29.0.tgz 展开 core + wheels 到 rawfile
# rawfile/pyodide 已在 .gitignore；deploy.sh / build-release.sh 会自动调用
```

`host/pyodide/packages/*.whl` 是 vendored 的 numpy/pandas 依赖闭包（9MB），随仓库提交；
核心 tarball 5.3MB。HAP 因此增加约 23MB。
