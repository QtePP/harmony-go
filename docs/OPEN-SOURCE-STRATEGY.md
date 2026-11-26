# HarmonyGo 开源策略（2026-11-25）

> 讨论稿，不是对外承诺。结论服务于一个目标：**让「端侧个人 Agent」这个品类被更多人采用，
> 同时不让项目因为开源而失去可持续性。**
>
> 现状基线：`QtePP/harmony-go`，MIT，GitHub + AtomGit 双远端，唯一 tag `v1.0.0`，
> dsh `0.2.2-rc.5`（MIT），HAP 内分发 676 个依赖包。对照对象：
> [`docs/OPENBITFUN-COMPARISON.md`](OPENBITFUN-COMPARISON.md)（OpenBitFun，MIT）。

---

## 0. 结论先行（五个决定）

1. **核心继续 MIT，不换 AGPL，不做「 cripple 版 open core」。**
   MIT 与 dsh 一致、与 AppGallery/企业 sideload 兼容、对插件生态最友好；
   闭源 fork 拿不走用户的端侧数据，也拿不走商标。
2. **开源边界按「代码 / 数据 / 服务」切，不按「功能」切。**
   外壳、宿主适配、ohos 插件、插件 SDK、设计令牌、测试工具全部开源；
   用户数据永不出设备；未来若有托管服务，只做可选、可自托管，不绑核心。
3. **治理用 BDFL + maintainers + DCO，不用 CLA。**
   贡献门槛低、法律链简单；协议/插件契约变更走公开 RFC。
4. **生态优先于市场。**
   先给 `@ohos/dsh-*` 插件契约、模板仓和 3 个参考插件；
   不在核心稳定前做插件市场或账号体系。
5. **商业化只卖「交付与支持」，不卖「数据与入口」。**
   赞助、企业部署/支持、垂域包、培训；不卖用户数据、不做订阅锁核心功能。

---

## 1. 现状审计（先承认欠账）

| 项 | 现状 | 判断 |
|---|---|---|
| 许可证 | 本仓 MIT；dsh MIT；载荷内 676 包混合 MIT/Apache/BSD/MPL/LGPL | 可分发，但声明要更新 |
| 社区文件 | LICENSE / CONTRIBUTING / SECURITY / CODE_OF_CONDUCT / Issue 模板 | 基本齐全 |
| 版本 | 只有 `v1.0.0`；`versionName` 1.0.0 | 缺发布节奏 |
| CI | `.github/workflows/payload.yml`：六个插件套件 + `--dump-config` | 只证明「我们写的部分」，不建 HAP |
| 合规 | `THIRD-PARTY-NOTICES.md` 仍写 dsh **0.2.1-rc.4 / 552 包** | **过时，必须修** |
| 贡献 | CONTRIBUTING 里「3. 真机验证」重复一行 | 小问题，顺手修 |
| 商标 | 无 `TRADEMARK.md`；MIT 不授予名称/Logo | 需要补 |
| DCO/CLA | 无 | 建议 DCO |
| SBOM | 无 | 建议 CycloneDX |
| 发布 | 无 Release workflow、无校验和、无签名 tag | 需要补 |
| Discussions | 未启用 | 建议启用 |
| 代码扫描 | 无 secret scanning / dependency review | 建议开 |

**一句话**：代码已经能开源，但「开源项目的运营件」还差一层。这一层不补，
外部贡献者会在第一个 PR 就撞到口径和合规问题。

---

## 2. 开源要买什么、不买什么

| 想买 | 为什么 | 代价 |
|---|---|---|
| **采用** | 鸿蒙开发者少，闭源 shell 没人敢把个人数据放进去 | 被 fork、被比较 |
| **信任** | 「无账号、无遥测、数据不出设备」必须可审计，开源是证据 | 安全面暴露 |
| **生态** | 插件、垂域包、教程只能靠外部贡献者 | 维护成本、质量参差 |
| **可持续** | 赞助/企业支持的前提是项目可见、可验证 | 需要持续运营 |

| 不买 | 原因 |
|---|---|
| 用 AGPL 逼退闭源 fork | 会同时逼退企业、AppGallery 集成和插件作者；而闭源 fork 拿不走端侧数据 |
| 用「开源版缺功能」逼付费 | 与「端侧完整 Agent」的定位冲突，用户会直接换 OpenBitFun 式遥控器 |
| 用账号/云服务做护城河 | 与 `docs/POSITIONING.md` 的「无账号、无后端」正面冲突 |
| 追 star 数 | 鸿蒙垂直品类，star 不等于采用；下载/留存/插件数更有意义 |

---

## 3. 许可证：为什么继续 MIT

| 方案 | 采用 | 生态 | 企业/商店 | 保护 | 结论 |
|---|---|---|---|---|---|
| **MIT（现状）** | 最高 | 最好 | 最好 | 弱（允许闭源 fork） | **保留** |
| Apache-2.0 | 高 | 好 | 好 | 中（专利授权） | 若专利风险出现再评估；现在切换会打断贡献者 |
| AGPL-3.0 | 低 | 差 | 差 | 强（网络分发） | 不用 |
| BSL / 延迟开源 | 低 | 差 | 中 | 强 | 不用，伤害信任 |
| Open core（核心 cripple） | 中 | 中 | 中 | 中 | 不用，定位冲突 |

**MIT 的「弱保护」不是问题**：我们的护城河是端侧数据、跨设备连续性和原生入口，
不是代码保密。OpenBitFun 即使把外壳代码抄走，也拿不到用户手机上的本体、会话和星闪配对。

**要补的是商标，不是许可证**：MIT 允许代码复用，但不允许用 `HarmonyGo` 名字和 Logo
冒充官方。新增 `TRADEMARK.md`：

- 代码可以 fork、可以商用；
- 分发修改版必须换名、换图标，不得暗示官方支持；
- 官方 Release 只从 `QtePP/harmony-go` 与 `atomgit.com/qtepp/harmony-go` 发出。

**贡献授权用 DCO**：每个 commit `Signed-off-by`，不引入 CLA。理由：个人项目，
CLA 会让企业贡献者走法务，DCO 已足够证明 MIT 授权。

---

## 4. 开源边界：代码 / 数据 / 服务

### 4.1 全部开源（MIT）

- ArkUI 外壳、`host/` 适配层、`profile-ohos` 模板；
- 11 个 `@ohos/dsh-*` 插件（ontology / office / python / git / html / search / context-ledger…）；
- 插件 SDK、模板、测试夹具、设计令牌、文档与落地页；
- 装配/部署/测试脚本（不含密钥与签名材料）。

### 4.2 永不进入仓库

- API Key、GitHub token、签名材料、设备序列号；
- 用户会话、本体数据库、工作区文件、同步内容；
- 任何默认遥测/埋点。

### 4.3 可闭源的可选层（现在不做）

- 企业设备群管理（MDM/sideload 工具链）；
- 垂域包（游戏、财务、医疗模板）——可单独授权；
- 付费支持/培训/定制交付；
- 若未来做同步中继：协议开源、官方托管可选、必须可自托管，且不绑核心功能。

> 红线：**核心能力不因付费而被拿走。** 免费版必须是完整的端侧 Agent。

---

## 5. 治理与贡献

### 5.1 角色

| 角色 | 权力 | 义务 |
|---|---|---|
| BDFL（仓库所有者） | 最终否决、发布、商标 | 公开路线图、回应安全报告 |
| Maintainer（1–3 人） | 合并 PR、triage、发布候选 | 按 `AGENTS.md` 口径审稿 |
| Contributor | 提 PR/Issue/插件 | DCO、测试、真机证据 |

### 5.2 决策

- 日常改动：lazy consensus（48h 无反对即合并）；
- 协议/插件契约/平台约束变更：**RFC**（`docs/rfcs/NNNN-*.md`），至少 7 天讨论；
- 安全：私密 advisory，修复后公开致谢；
- 版本：SemVer；`v1.x` 内不破坏插件契约。

### 5.3 贡献漏斗

1. 文档/示例（`good first issue`）；
2. 插件模板 + 参考插件；
3. 平台适配（新设备/新 API）；
4. 上游 dsh 补丁（ACP、搜索、时间上下文）；
5. 垂域包。

### 5.4 渠道

- GitHub Discussions（英文/中文都可）；
- 微信社区群（中国用户，二维码放 README，不进仓库图片以外的隐私）；
- AtomGit 镜像用于国内访问；
- 不在早期铺 Discord/Slack，避免多 channel 失血。

---

## 6. 生态：先契约，后市场

### 6.1 插件 SDK（P0）

- `docs/PLUGIN-SDK.md`：插件入口、`ctx` 能力、工具 schema、权限、测试夹具；
- `examples/plugin-template/`：一个最小 `@ohos/dsh-hello`（一个工具 + 一个测试）；
- 3 个参考插件（已有）：`tool-html`、`tool-office`、`ontology`；
- 兼容矩阵：dsh 版本 × 插件版本 × API 级别；
- 插件不动态加载原生库（平台约束），只允许纯 JS + 现有 NAPI。

### 6.2 上游策略

- **不 fork dsh**，只 pin 版本 + 补丁；
- 把通用能力推回上游：`session/load`、`mode`、纯 JS 搜索契约、时间上下文挂载点；
- 上游升级流程写进 `docs/BUILD.md`：`PINNED_DSH_VERSION` + 三段验证 + 真机回归。

### 6.3 市场（P2，暂缓）

- 先做「精选配方仓」（curated recipes），不做交易/分成/账号；
- 等核心稳定、插件数 ≥10、有外部作者再评估市场；
- 市场若做，必须不依赖账号（可用签名/哈希校验），否则与定位冲突。

---

## 7. 商业化：卖交付，不卖数据

| 模式 | 做不做 | 说明 |
|---|---|---|
| GitHub Sponsors / OpenCollective | ✅ | 最轻，先做 |
| 企业部署与支持 | ✅ | 设备群刷机、签名、内网模型、培训 |
| 垂域包授权 | ✅ | 游戏/财务/医疗等垂直能力，单独仓库/单独许可 |
| 付费模板（周报/简历/发票） | ✅ | 可选，核心模板仍免费 |
| 订阅锁核心功能 | ❌ | 与定位冲突 |
| 卖用户数据/画像 | ❌ | 永远不做 |
| 官方托管中继（若未来） | ⚠️ | 协议开源、可自托管、不绑核心 |

**定价原则**：按「交付/支持」计价，不按「用户数据量/消息数」计价。
**AppGallery**：免费上架，开源披露 + 隐私政策；付费走企业合同，不在商店内做订阅。

---

## 8. 合规、供应链与安全

### 8.1 必须马上修的合规欠账

1. `THIRD-PARTY-NOTICES.md`：dsh 版本改 **0.2.2-rc.5**，包数改 **676**，重跑许可证统计；
2. 对 MPL/LGPL 组件保留「未加载」证据（平台专属二进制），或装配期删除；
3. 生成 **CycloneDX SBOM**，随 Release 发布；
4. Release 附 **SHA256** + 签名 tag；
5. 开启 GitHub secret scanning、dependency review、private vulnerability reporting；
6. `CONTRIBUTING.md` 去重 + 加 DCO 说明；
7. 新增 `TRADEMARK.md`、`GOVERNANCE.md`、`docs/PLUGIN-SDK.md`；
8. Issue 模板加「设备型号/API/是否 ACP/诊断日志」字段（已有部分）。

**已完成（2026-11-25）**：① NOTICES 更新（0.2.2-rc.5 / 676 安装包 / 642 唯一包，许可证表重算）；
③ `scripts/generate-sbom.mjs` + `.github/workflows/release.yml`（SBOM/SHA256 上传，HAP 仍手工）；
④ workflow 生成 SHA256（tag 签名仍手工）；⑥ CONTRIBUTING 去重 + DCO；⑦ `TRADEMARK.md`、
`GOVERNANCE.md`、`CODEOWNERS`、PR/RFC 模板、`docs/PLUGIN-SDK.md`。

**还差**：⑤ 仓库设置里开 secret scanning / private vulnerability reporting（不是代码能开的）；
③④ 首次 `v1.1.0` 实跑 workflow；插件模板仓（本文已有最小示例，独立模板仓待做）。

### 8.2 安全边界（写清楚，避免「伪漏洞」）

- 同进程 Node、无进程隔离、桥无鉴权、`danger-full-access` 零审批——都是设计选择，
  已在 `SECURITY.md` 的「已知边界」写明；
- 新增插件必须声明网络/文件能力；默认最小权限；
- 供应链：`npm install --ignore-scripts`、原生模块不进载荷、锁版本。

### 8.3 法务

- dsh 是 MIT，可随 HAP 分发；保留其 LICENSE/NOTICE；
- HarmonyOS SDK / DevEco 的许可不覆盖本仓代码，文档里不暗示华为背书；
- `HarmonyGo` 名称/Logo 商标声明（哪怕未注册，也先有 common-law 立场）；
- 不把用户数据用于训练/分析；隐私政策与 `SECURITY.md` 一致。

---

## 9. 90 天路线

| 周 | 交付 | 验收 |
|---|---|---|
| 1–2 | 合规修复（NOTICES/SBOM/DCO/TRADEMARK/CONTRIBUTING） | 第三方清单与载荷一致；CI 绿 |
| 2–3 | D1/D2/D3 收尾 + Release `v1.1.0` | tag 签名、SHA256、Release notes |
| 3–4 | `docs/PLUGIN-SDK.md` + 插件模板 + 1 个 hello 插件 | 外部人按文档 30 分钟内跑通 |
| 5–6 | 3 个参考插件文档化（html/office/ontology） | 每篇有最小示例与测试 |
| 6–8 | 上游 PR：ACP `session/load`/`mode`（参考 OpenBitFun 桥） | 上游接受或明确拒绝 |
| 8–10 | Discussions + 路线图 RFC + `good first issue` ×5 | 至少 3 个外部 issue/PR |
| 10–12 | 社区发布（鸿蒙论坛/V2EX/掘金/HN） | 100 下载/20 star/3 贡献者为及格 |
| 12 | 复盘：采用、贡献、赞助、投诉 | 决定是否做市场/中继 |

---

## 10. 指标（无遥测）

| 层 | 指标 | 目标（首季度） | 来源 |
|---|---|---|---|
| 采用 | Release 下载 / HAP 安装 | 100+ | GitHub Releases |
| 信任 | 安全报告响应中位数 | <48h | advisory |
| 社区 | 外部 contributor / PR | ≥3 人 / ≥5 PR | GitHub |
| 生态 | 外部插件 | ≥3 | 仓库/文档 |
| 质量 | `scripts/test.sh` 全绿 | 100% | CI |
| 可持续 | 赞助/企业线索 | ≥1 | OpenCollective |

> 不用默认遥测。采用数据只能靠 Release 下载、issue、社区反馈和用户自愿分享；
> 这是「无账号、无后端」的代价，也是卖点。

---

## 11. 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 闭源 fork 拿走代码 | 高 | 中 | 商标、发布节奏、数据护城河、社区 |
| dsh 上游破坏兼容 | 中 | 高 | pin 版本、CI、上游 PR、兼容矩阵 |
| 插件生态出安全问题 | 中 | 高 | 最小权限、审查、签名/哈希、默认禁用 |
| 维护者倦怠 | 高 | 高 | 明确「不做什么」、DCO、赞助、maintainer 梯队 |
| AppGallery 审核/合规 | 中 | 中 | 免费、隐私政策、开源披露、提前沟通 |
| 商标被抢注/滥用 | 低 | 中 | `TRADEMARK.md` + 尽早注册（预算允许） |
| 弱著佐权组件被质疑 | 中 | 中 | SBOM + 未加载证据 + 可选裁剪 |

---

## 12. 不做什么（反范围）

- 不做账号体系、云同步、遥测；
- 不做「开源版缺功能」；
- 不做插件市场（至少 12 个月内）；
- 不 fork dsh；
- 不为 star 做通用 Agent 功能堆砌；
- 不承诺长期支持旧 API（`SECURITY.md` 已写「仅最新 commit」）。

---

## 13. 一句话

**开源不是把代码放出去，是把「可验证的信任」做成产品的一部分。**
HarmonyGo 卖的不是代码，是「你的数据在你自己设备上」——这句话只有能被审计时才成立。
