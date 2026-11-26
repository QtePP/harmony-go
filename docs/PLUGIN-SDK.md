# 插件 SDK / Plugin SDK

> 适用对象：想给 `ohos` profile 增加一个 `@ohos/dsh-*` 插件的贡献者。
> 本文只讲**本仓库的插件契约**；dsh 本身的 Cordis 生命周期以
> [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) 的文档为准。
>
> 先读三个真实插件，比读抽象文档快：
> [`@ohos/dsh-boot-report`](../host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-boot-report/index.js)（最小）、
> [`@ohos/dsh-ontology`](../host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-ontology/index.js)（工具 + pre-step）、
> [`@ohos/dsh-tool-html`](../host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-tool-html/index.js)（多动作工具 + 输出 schema）。

## 1. 一个插件由三部分组成

| 部分 | 位置 | 作用 |
|---|---|---|
| 包 | `host/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-<name>/` | ESM 包；`index.js` 导出 `name` / `inject` / `apply` |
| 路由声明 | `@ohos/dsh-bundle-ohos/package.json` 的 `dependencies` | **不声明 = 永不 mount**；profile 路由表按 bundle 依赖闭包构建 |
| 挂载行 | `@ohos/dsh-bundle-ohos/cordis.patch.yml` 的 `- insert:` | 给 row 一个 `id`，把包名挂到 profile 上；可 `disabled: true` |

载荷装配时 `assemble-payload.mjs` 会把这棵树打进 `dsh-payload.zip`；App 首启解包到
`$DSH_HOME/profiles/ohos`。**改模板后必须重新装配 + 重装**，否则设备上跑的是旧模板
（bootstrap 按内容哈希戳做幂等安装）。

## 2. 最小插件

```js
// @ohos/dsh-hello/index.js
import z from "@deepseek-ai/schemastery";
import { defineTool } from "@deepseek-ai/dsh-tools";

const name = "tool-hello";
const inject = ["tools"];

const Config = z.object({
  greeting: z.string().default("hello")
});

function apply(ctx, config) {
  const resolved = config === undefined ? Config() : config;
  ctx.tools.register(defineTool({
    name: "hello",
    description: "Say hello to someone. Use this only when the user asks for a greeting.",
    parameters: {
      who: { type: "string", required: true, description: "Name to greet" }
    },
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          ok: { type: "boolean", required: true },
          summary: { type: "string", required: true }
        }
      }
    },
    async execute(args, exec) {
      const who = String(args.who ?? "").trim();
      if (who.length === 0) {
        return { ok: false, summary: "who is required" };
      }
      return { ok: true, summary: `${resolved.greeting}, ${who}` };
    }
  }));
}

export { Config, apply, inject, name };
```

`package.json`：

```json
{
  "name": "@ohos/dsh-hello",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "index.js",
  "exports": { ".": "./index.js", "./package.json": "./package.json" }
}
```

挂载：

```yaml
# @ohos/dsh-bundle-ohos/cordis.patch.yml
- insert:
    - id: tool-hello
      name: "@ohos/dsh-hello"
```

并在 `@ohos/dsh-bundle-ohos/package.json` 的 `dependencies` 加
`"@ohos/dsh-hello": "0.1.0"`。**少任何一步，启动后 `tools(N)` 里都不会出现它。**

## 3. 工具契约

- `defineTool({ name, description, parameters, output?, execute })`：
  - `name` 是模型看到的工具名，全局唯一；不要用 `bash`/`git` 这类会与平台补丁冲突的名字。
  - `description` 是**给模型看的提示**，写清楚「什么时候用、什么时候不用、返回什么」；它比实现更容易决定工具是否被正确调用。
  - `parameters` 是 JSON Schema 子集（`type` / `required` / `description` / `items` / `additionalProperties`）。
  - `output.schema` 可选；如果返回结构化对象，建议给，客户端/日志更容易诊断。
  - `execute(args, exec)` 返回 `{ ok, summary, ... }` 或 `[{type:"text", text}]`。`summary` 是人类可读的一行，不要塞大段内容。
- `exec` 里有 `agent` / `signal`；需要会话工作目录时用
  `await ctx.workingDirectory.ensure(exec.agent, exec.signal)`，不要用 `process.cwd()`。
- 失败时返回 `{ok:false,summary}` 或抛 `HarnessError`；**不要**把内部堆栈直接回给模型。

## 4. 平台红线（违反会直接崩或永不工作）

| 红线 | 正确做法 |
|---|---|
| 禁 fork/exec | 不调 `child_process`；没有 `git`/`rg`/`bash` 二进制 |
| jitless ⇒ 无 WebAssembly | 不加载 `.wasm`；需要 HTTP 用全局 `fetch`（shim 已接管） |
| 原生 `.node` 模块不可用 | 只用纯 JS；需要能力就写 JS 或走已有 NAPI |
| 工作区栅栏 | 写文件走 `ctx.fs` 或 `workingDirectory`；不要绕过 `workspace-write` |
| 路径穿越 | 用户给的相对路径必须 `resolve` 后校验仍在工作区内 |
| 密钥 | 不读 env 里的 key；用 `ctx.credentials`/`<dsh-home>/.api-key`；不写日志 |
| 定时器 | `apply` 里创建的 timer/watch 必须在 dispose 时清掉，否则热重载/重启会泄漏 |

## 5. 测试

插件测试必须在**载荷树内**跑：`index.js` 依赖 `@deepseek-ai/schemastery` 等包，只有
`.build/payload` 的 `node_modules` 能解析。

```bash
cd .build/payload/profile-ohos/profiles/ohos/node_modules/@ohos/dsh-hello
node --test test/*.test.mjs
```

测试建议：

1. **纯函数优先**：把路径解析、参数校验、格式化抽成可单测函数；`apply` 只做注册。
2. **假 ctx**：`{ tools: { register(tool) { registered = tool } } }`，断言 `tool.name`/`parameters`/`execute`。
3. **失败路径**：空参数、路径穿越、超限、只读沙箱——每个破坏性操作都要有一条失败用例。
4. **配置层**：`node scripts/assemble-payload.mjs` 后跑
   `DSH_HOME=.build/ohos-e2e node .build/payload/node_modules/@deepseek-ai/dsh/lib/bin.js --profile ohos --patch .build/payload/patches/ohos.patch.yml --dump-config`
   确认 `- id: tool-hello` 在输出里。
5. **合并门禁**：`bash scripts/test.sh unit` 必须全绿；CI 的
   `.github/workflows/payload.yml` 会在 `host/**` 变更时跑同一批套件。

## 6. 版本与命名

- 包名 `@ohos/dsh-<name>`；`version` 从 `0.1.0` 起；`private: true`（不发布 npm）。
- 一个插件只做一件事；工具名不要抢 dsh 内置名（`read`/`write`/`glob`/`grep`/`bash`/`run_code`）。
- 破坏性动作（删除/覆盖/推送）必须在 `description` 里写清楚，并提供 `force`/`dryRun` 一类显式开关。
- 新增插件要同步：`AGENTS.md` §2 的插件表（一句话 + 锚点）、`docs/STATUS.md` 的真机验收、
  本文的「参考插件」列表。

## 7. 参考插件

| 插件 | 看什么 |
|---|---|
| `@ohos/dsh-boot-report` | 最小 `apply`；只读；`ctx.get('web')` 诊断 |
| `@ohos/dsh-tool-git` | 多动作工具、纯 JS HTTP、路径栅栏、破坏性操作 |
| `@ohos/dsh-tool-html` | 多动作工具、组件库、输出 schema、工作区写入 |
| `@ohos/dsh-ontology` | SQLite、`agent/pre-step`、bundle 导入导出、设置面板通道 |
| `@ohos/dsh-context-ledger` | 只记计数、追加 JSONL、面板读取 |
