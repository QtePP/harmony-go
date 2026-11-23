# Office（docx / xlsx）端侧方案

> 状态：**真机闭环**（2026-11-23，手机 CMM-AL10）：模型用 `office_write_docx` / `office_write_xlsx` 生成文件，`FileViewer` 原生预览，插件单测 40/40、`--jitless` 40/40，LocalUnit 覆盖解析器。
> 范围：`.docx` / `.xlsx` 的**生成与读取**、App 内**只读预览**；不含 `.pptx`、旧二进制格式（`.doc/.xls/.ppt`）、图片/图表、公式重算。

## 1. 为什么不用 dsh 自带的 Office 栈

| 自带件 | 依赖 | 鸿蒙手机 |
|---|---|---|
| `dsh-skill-office` | python-docx / openpyxl / python-pptx + shell `cp` | 无 Python、无 shell |
| `dsh-office-kit` | `libreoffice-kit`（按平台的原生 LibreOffice，缺原生退 WASM） | 禁原生 ELF；`--jitless` 无 WASM |
| `dsh-tool-office` | 上述两项 | 无法挂载（`office-kit` 只随 sdk-app） |

结论：**不是把 dsh 的 Office 修好，而是用纯 JS 重写 OOXML 的读写**。`.docx/.xlsx` 本质是 ZIP + XML；Node 内置 `zlib` 是编译好的 C（不是 WASM），所以 `--jitless` 下仍可用。

## 2. 插件：`@ohos/dsh-tool-office`

位置：`host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-office/`。

| 工具 | 输入 | 输出 |
|---|---|---|
| `office_read` | `path`（工作区内 `.docx/.xlsx`）、可选 `sheet`、`max_chars` | docx → Markdown；xlsx → 每表 `## Sheet: name` + TSV；公式显示 `=…`；日期按 ISO |
| `office_write_docx` | `path`、`markdown` | 标题/段落/列表/表格/引用/代码/粗斜体/行内码 |
| `office_write_xlsx` | `path`、`csv`（逗号/制表/分号由首行嗅探）、可选 `sheet_name` | 单表工作簿；数字/公式/首行表头加粗冻结 |

硬约束：

- **路径栅栏**：`ctx.fs.resolve` + `ctx.fs.contains`，只允许会话工作区；写入在 `read-only` 模式直接拒绝。
- **原子写**：临时文件 + `rename`，失败不留半截文档。
- **纯 JS**：自写 ZIP（`lib/zip.js`，Node `zlib` + CRC32），`lib/docx.js` / `lib/xlsx.js` 只做 OOXML；`--jitless` 下 40/40 通过。
- **明确的不可用**：旧格式提示另存为 OOXML；`.pptx` 提示分享 PDF；不是静默失败。

## 3. 预览：`FileViewer` 原生渲染

链路：`@ohos.zlib.decompressFile` 解包到 `cacheDir/office-preview` → 读 `word/document.xml` / `xl/*.xml` → 纯 ArkTS 解析（`entry/src/main/ets/common/OfficePreview.ets`）→ ArkUI 渲染。

- **docx**：标题 1–3、段落、项目符号/编号、表格、引用、代码块、粗体/斜体/行内码；只读、版式简化。
- **xlsx**：工作表 tab、列字母 + 行号、单元格网格、数字右对齐、首行表头加粗；日期按样式转 ISO。
- **上限**：300 行 × 40 列 × 300 字符/单元格；docx 400 块；文件 > 20MB 拒绝预览；超限在底部标注。
- **不支持**：pptx、旧格式、图片/图表、批注/修订；错误页给出「分享到系统 Office/WPS 打开」。

## 4. 验收与测试

- 插件：`dsh-tool-office` 40/40（含 `--jitless`）；`test/zip`、`docx`、`xlsx`、`tools` 四套；宿主侧用 python-docx / openpyxl / xmllint 交叉验证生成物。
- 解析器：`entry/src/test/OfficePreview.test.ets` 纳入 `LocalUnit`。
- 装配：`ohos` profile `--dump-config` 可见 `tool-office-ohos`；boot-report `tools(31)` 含三个 `office_*`。
- 真机：模型生成 `reports/office-test.docx`（3097B）与 `.xlsx`（2348B）；预览截图通过；把设备生成的文件拉回宿主，插件读取结果与写入内容一致。

## 5. 已知边界

- **公式**：读取显示 `=SUM(...)`，不在本机重算；生成时写 `fullCalcOnLoad`，由 Excel/WPS 打开时计算。
- **日期**：预览/读取依赖 `styles.xml` 的 numFmt；极端自定义格式可能按原始值显示。
- **版式**：不复制分页、页眉页脚、浮动图片、合并单元格（表格按格子铺开）；复杂文档请分享到 WPS 查看。
- **PPTX**：下一步；生成可用纯 JS 方案，预览成本高，先走外部打开。
