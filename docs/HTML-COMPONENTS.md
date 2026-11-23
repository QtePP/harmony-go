# HTML 组件库（A2UI）

> 这是 `@ohos/dsh-tool-html` 内置组件清单的快照；**权威来源是插件本身**（`html` 工具的 `action: components`）。
> 页面骨架已内联整套样式与明暗两套配色，模型只需要选组件、填内容：不要自己写 CSS，不要引外链，
> 不要加打印/分享按钮（预览页已经有「导出」）。图表是纯 CSS，可排序表格用页面内联脚本做渐进增强
> （脚本不可用时表格照样完整显示）。

# 组件清单（html 工具内置）

页面骨架已自带整套样式与明暗两套配色：**只复制下面的片段、填内容，不要自己写 CSS，不要引入外部资源。**

## hero · 开篇

什么时候用：页面第一段要说清「这是什么、给谁、解决什么」时，用一行标题 + 一句导语。

```html
<p class="lede">一句话说清这份页面解决什么问题。</p>
<div class="badges">
  <span class="badge">适用人群</span>
  <span class="badge">周期</span>
</div>
```

## card · 卡片

什么时候用：一块独立的内容（一个动作、一个方案、一个说明），标题 + 正文 + 可选脚注。

```html
<section class="card">
  <h3>卡片标题</h3>
  <p>卡片正文，两三句讲清一件事。</p>
  <p class="card-foot">可选脚注</p>
</section>
```

## grid · 并排卡片

什么时候用：2–3 个同级选项/要点需要并排对比阅读；手机宽度会自动变成单列。

```html
<div class="grid grid-2">
  <section class="card"><h3>左边</h3><p>说明。</p></section>
  <section class="card"><h3>右边</h3><p>说明。</p></section>
</div>
```

## stats · 关键数字

什么时候用：页面有 3–4 个要一眼看到的量化指标（时长、次数、预算、比例）。

```html
<div class="stats">
  <div class="stat"><div class="stat-value">5 + 2</div><div class="stat-label">训练 / 恢复</div></div>
  <div class="stat"><div class="stat-value">60′</div><div class="stat-label">单次时长</div></div>
  <div class="stat"><div class="stat-value">RPE 6–8</div><div class="stat-label">强度</div></div>
</div>
```

## steps · 步骤

什么时候用：有先后的操作/流程（做一件事的顺序），编号自带序号圆点。

```html
<ol class="steps">
  <li class="step"><span class="step-num">1</span><div class="step-body"><strong>第一步</strong>具体做什么。</div></li>
  <li class="step"><span class="step-num">2</span><div class="step-body"><strong>第二步</strong>具体做什么。</div></li>
</ol>
```

## checklist · 清单

什么时候用：用户要照着逐条打勾的事项（装备、检查项、待办）；复选框是纯 HTML，可在预览里直接点。

```html
<ul class="checklist">
  <li><input type="checkbox"><span>第一件事</span></li>
  <li><input type="checkbox"><span>第二件事</span></li>
</ul>
```

## table · 表格

什么时候用：多行多列的结构化数据（动作 × 组数 × 次数、对比项）。窄屏可横向滑动。

```html
<div class="table">
  <table>
    <thead><tr><th>列一</th><th>列二</th><th>列三</th></tr></thead>
    <tbody>
      <tr><td>值</td><td>值</td><td>值</td></tr>
      <tr><td>值</td><td>值</td><td>值</td></tr>
    </tbody>
  </table>
</div>
```

## table-sortable · 可排序表格

什么时候用：行数较多、需要按列排序或分页查看的数据（动作清单、支出明细）。内联脚本只做渐进增强：脚本被禁用时表格照样完整显示，导出长图/PDF 会带上当前排序与分页状态。

```html
<div class="table">
  <table class="sortable" data-page-size="8">
    <thead>
      <tr>
        <th class="sortable" data-type="text">动作</th>
        <th class="sortable" data-type="number">组数</th>
        <th class="sortable" data-type="number">次数</th>
      </tr>
    </thead>
    <tbody>
      <tr><td>深蹲</td><td>4</td><td>8</td></tr>
      <tr><td>卧推</td><td>4</td><td>10</td></tr>
      <tr><td>硬拉</td><td>3</td><td>5</td></tr>
      <tr><td>划船</td><td>3</td><td>12</td></tr>
      <tr><td>推举</td><td>3</td><td>8</td></tr>
    </tbody>
  </table>
</div>
<script>
(function () {
  function cellText(row, index) { var c = row.cells[index]; return c ? c.textContent.trim() : ""; }
  function toNumber(value) { var n = parseFloat(String(value).replace(/[^0-9.-]/g, "")); return isNaN(n) ? 0 : n; }
  function compareRows(a, b, index, type, dir) {
    var left = type === "number" ? toNumber(cellText(a, index)) : cellText(a, index);
    var right = type === "number" ? toNumber(cellText(b, index)) : cellText(b, index);
    if (left < right) { return -dir; }
    if (left > right) { return dir; }
    return 0;
  }
  function init(table) {
    if (table.getAttribute("data-ready")) { return; }
    table.setAttribute("data-ready", "1");
    var body = table.tBodies[0];
    if (!body) { return; }
    var rows = Array.prototype.slice.call(body.rows);
    var heads = table.tHead ? Array.prototype.slice.call(table.tHead.rows[0].cells) : [];
    var size = parseInt(table.getAttribute("data-page-size") || "0", 10);
    var page = 0;
    var column = -1;
    var dir = 1;
    var pager = null;
    var label = null;
    var prev = null;
    var next = null;
    var host = table.closest(".table") || table;
    if (size > 0) {
      pager = document.createElement("div");
      pager.className = "table-pager";
      prev = document.createElement("button");
      prev.type = "button";
      prev.textContent = "上一页";
      next = document.createElement("button");
      next.type = "button";
      next.textContent = "下一页";
      label = document.createElement("span");
      prev.onclick = function () { page = Math.max(0, page - 1); render(); };
      next.onclick = function () { page = Math.min(maxPage(), page + 1); render(); };
      pager.appendChild(prev);
      pager.appendChild(label);
      pager.appendChild(next);
      host.parentNode.insertBefore(pager, host.nextSibling);
    }
    function maxPage() { return Math.max(0, Math.ceil(rows.length / size) - 1); }
    function render() {
      var sorted = rows.slice();
      if (column >= 0) {
        var type = heads[column].getAttribute("data-type") || "text";
        sorted.sort(function (a, b) { return compareRows(a, b, column, type, dir); });
      }
      while (body.firstChild) { body.removeChild(body.firstChild); }
      var start = size > 0 ? page * size : 0;
      var end = size > 0 ? Math.min(sorted.length, start + size) : sorted.length;
      for (var i = start; i < end; i++) { body.appendChild(sorted[i]); }
      heads.forEach(function (head, index) {
        head.setAttribute("aria-sort", index === column ? (dir > 0 ? "ascending" : "descending") : "none");
      });
      if (pager) {
        prev.disabled = page <= 0;
        next.disabled = page >= maxPage();
        label.textContent = (page + 1) + " / " + (maxPage() + 1);
      }
    }
    heads.forEach(function (head, index) {
      if (!head.classList.contains("sortable")) { return; }
      head.onclick = function () { dir = column === index && dir === 1 ? -1 : 1; column = index; page = 0; render(); };
    });
    render();
  }
  Array.prototype.forEach.call(document.querySelectorAll("table.sortable"), init);
})();
</script>
```

## callout · 提示框

什么时候用：有一句「别踩这个坑 / 这条最重要」需要插在正文中间；加 callout-warn 变成注意事项。

```html
<div class="callout">需要被强调的一句话。</div>
<div class="callout callout-warn">需要警惕的一句话。</div>
```

## timeline · 时间线

什么时候用：按日期/阶段推进的计划（几周安排、里程碑）。

```html
<ul class="timeline">
  <li class="tl-item"><div class="tl-when">第 1–2 周</div><div class="tl-what">做什么。</div></li>
  <li class="tl-item"><div class="tl-when">第 3–4 周</div><div class="tl-what">做什么。</div></li>
</ul>
```

## compare · 两栏对比

什么时候用：两种做法/两个方案二选一，需要并排讲清各自适合谁。

```html
<div class="compare">
  <div class="compare-col"><p class="compare-head">方案 A</p><p>适合谁、代价是什么。</p></div>
  <div class="compare-col"><p class="compare-head">方案 B</p><p>适合谁、代价是什么。</p></div>
</div>
```

## bars · 进度条

什么时候用：表示占比/完成度（预算分配、训练强度、时间占比）。宽度写在 style 里，如 60%。

```html
<div class="bar-label"><span>力量</span><span>60%</span></div>
<div class="bar"><div class="bar-fill" style="width:60%"></div></div>
```

## chart-bars · 柱状图

什么时候用：几个同类量在时间/分类上高低对比（每周训练次数、各月支出）。纯 CSS，无脚本；柱高写百分比。

```html
<div class="chart-bars">
  <div class="chart-col"><span class="chart-val">5</span><div class="chart-bar" style="height:62%"></div><span class="chart-x">W1</span></div>
  <div class="chart-col"><span class="chart-val">6</span><div class="chart-bar" style="height:76%"></div><span class="chart-x">W2</span></div>
  <div class="chart-col"><span class="chart-val">4</span><div class="chart-bar alt" style="height:48%"></div><span class="chart-x">W3</span></div>
  <div class="chart-col"><span class="chart-val">7</span><div class="chart-bar" style="height:88%"></div><span class="chart-x">W4</span></div>
</div>
```

## chart-donut · 环形进度

什么时候用：单一比例（完成度、预算已用、占比）；百分比写在 style 的 --p 上（如 72%），中间洞里的数字要一致。

```html
<div class="chart-donut">
  <div class="donut" style="--p:72%"><div class="donut-hole">72%</div></div>
  <div class="chart-legend">本周训练完成度<b>18 / 25 次</b>还差 7 次，优先补两次力量</div>
</div>
```

## kv · 键值表

什么时候用：规格/参数/条件这类「名称 → 值」的短信息，比表格更省地方。

```html
<div class="kv">
  <div class="kv-row"><div class="kv-key">周期</div><div class="kv-val">8 周</div></div>
  <div class="kv-row"><div class="kv-key">频率</div><div class="kv-val">每周 5 练</div></div>
</div>
```

## fold · 折叠

什么时候用：次要的长内容（FAQ、细节说明）不必占据首屏；纯 HTML details，无脚本。

```html
<details class="fold">
  <summary>展开看细节</summary>
  <p>这一段默认收起。</p>
</details>
```

## quote · 引用

什么时候用：引用原文、原则、结论性的一句话。

```html
<blockquote>被引用的一句话。</blockquote>
```

## code · 代码

什么时候用：需要展示命令、配置片段时（注意转义 &lt; &gt; &amp;）。

```html
<pre><code>命令或配置片段</code></pre>
```

## divider · 分隔

什么时候用：两大段之间需要留白分界。

```html
<hr>
```

