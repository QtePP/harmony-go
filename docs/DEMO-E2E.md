# 三条端到端验收（手工执行）

> 三条 **prompt 已固定**，不再由 agent 自拟。只在 App 里新建三个会话依次发送；
> 本文不替用户执行。Python 默认关闭，先按 §1 开。
>
> 设备快照（2026-11-24）：手机 CMM-AL10 上 Python 已开，`boot-report` 为
> `tools(33)`（含 `python_run` / `pybot_reply`）；不需要再重启。

## 1. 开 Python（项目一必需）

设置 →「Python 运行时（实验）」→ 打开 → **彻底退出并重启 App**。

- 关闭时：`tools(31)`，不挂隐藏 WebView；
- 开启后：`tools(33)`，出现 `python_run` / `pybot_reply`。

不开也能发项目一，但模型只能“普通推理”算数，**没有 pandas 的真算力**；
它应当明确说“没有用 Python 真算”，而不是假装跑过。

## 2. 项目一｜手机里算

**新建会话，发下面这条（整段复制）：**

```text
项目一｜手机里算

在当前工作区生成一份 12 行的销售数据 sales.csv，列是 region, month, amount（region 用华东/华南/华北/西南，month 1-3，amount 100-900 的整数）。
然后用 Python 真算：必须调用 python_run，用 pandas 读 sales.csv，按 region 汇总 amount 并按金额降序。
把汇总结果写成三个产物：
1) sales-summary.xlsx（office_write_xlsx）
2) sales-report.docx（office_write_docx，含汇总表和一句结论）
3) sales-report.html（用 html 工具的 components → create → fill → check 生成，移动端优先、零外链）

汇总数字必须来自 python_run 的 stdout，不要心算。若 Python 开关没开，直接说明没有 pandas 真算力，不要伪造结果。
```

**看什么：**

- 轨迹里应有 `python_run`，并且 Python 输出里能看到 pandas 的汇总；
- 工作区里出现 `sales-summary.xlsx`、`sales-report.docx`、`sales-report.html`；
- 不要用 `bash`（本 profile 没有这个工具）。

## 3. 项目二｜真实仓库排障

**新建会话，发下面这条：**

```text
项目二｜真实仓库排障

仓库：expressjs/express
报错原文：Cannot set headers after they are sent to the client

用 git 工具把仓库 clone 到当前项目（不要凭记忆），用 grep/read 找到这条报错在代码里的来源。
回答：
1) 哪个 API 调用顺序会触发它；
2) 最小修复是什么；
3) 如何写一个最小复现或验证。
必须引用你实际读到的文件路径和行号。
```

**看什么：**

- `git` 轨迹里有 clone，工作区 `repos/express/` 存在；
- 回答引用了仓库内真实文件/行号，而不是泛泛而谈；
- 不要求生成 .docx/.xlsx。

## 4. 项目三｜真实仓库排障

**新建会话，发下面这条：**

```text
项目三｜真实仓库排障

仓库：QtePP/harmony-go
报错原文：Error: cannot get property "workingDirectory" without inject

用 git 工具把仓库 clone 到当前项目（不要凭记忆），找到插件 inject 声明和读取 workingDirectory 的位置。
回答：
1) 缺 inject 时为什么报这个错；
2) 最小修复是什么；
3) 有没有同类字段会一起漏。
必须引用你实际读到的文件路径和行号。
```

**看什么：**

- clone 成功，`repos/harmony-go/` 存在；
- 回答定位到 `@ohos/dsh-tool-python`（或对应插件）的 `inject` 与 `workingDirectory` 读取处；
- 不要求生成 .docx/.xlsx。

## 5. 三处验收

### 5.1 App 内直接打开 .docx / .xlsx

在项目一的对话或「项目文件」里点：

- `sales-summary.xlsx` → 应进入 App 内原生预览：能看到工作表、列字母/行号、数字右对齐；
- `sales-report.docx` → 应看到标题、段落、汇总表，而不是下载或跳到外部应用。

失败信号：提示“不支持”、空白页、转去系统 Office/WPS。

### 5.2 HTML 预览的「导出」有三项

打开 `sales-report.html` → 预览页 → 长按或点「导出」，菜单应有：

1. **导出长图（亮 + 暗）** —— 生成两张整页长图（亮色 / 暗色各一张）；
2. **PNG** —— 当前页截图；
3. **PDF** —— 单页 PDF。

三项都要能触发；长图是两张，不是一张。若只有 PNG/PDF，说明缺少亮/暗双导出。

### 5.3 项目一 force-stop 后记录还在

项目一对话完成后：

```bash
hdc shell aa force-stop com.qtepp.harmonygo
```

重新打开 App，进入同一会话/项目：

- 对话记录还在（用户问题、模型回答、工具轨迹）；
- `sales-summary.xlsx` / `sales-report.docx` / `sales-report.html` 三个文件仍在工作区、点得开；
- 上下文小环/用量账本仍在（若之前有记录）。

失败信号：记录回到空白、文件列表丢失、只剩文件但对话没了。

## 6. 结果记录

每条验完在 `docs/STATUS.md` 追加一行：设备、时间、构建、三条 prompt 各自的结论
（通过/失败/失败原文），以及三处验收的结果。不要把“模型说生成了”当成产物存在；
以文件系统/App 预览为准。
