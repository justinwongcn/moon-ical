# 开发工作流与验证闸门

本页是改代码前要过的规矩：工具链硬规则、验证链、判别性验收、里程碑纪律。权威出处：[AGENTS.md](../AGENTS.md)、[docs/development.html](../docs/development.html) §05/§06/§11、`docs/PROGRESS.md`（本地）。

## 开工 / 收工的固定动作

- **开工先读 `docs/PROGRESS.md`**——它是跨会话状态源（本地文件、gitignored）：状态一览、里程碑表、会话日志。
- **收工必更它**，并同步 `docs/development.html` §02/§04（若里程碑落地）。pre-commit 钩子会机械校验"源码提交时 PROGRESS.md 的 mtime 晚于上次提交"。
- **提交命令是固定的**：`git -c core.hooksPath=.githooks commit ...`。EvoX 环境注入全局 `core.hooksPath`，配置压不过，必须显式 `-c` 才能让项目闸门（`moon check` + 文档同步检查）生效。**绝不 `--no-verify`，绝不裸 `git commit`**。
- 里程碑提交：一次提交一个最小目标，消息 `S<n>: <一句话>`，正文列改动点 + 验收证据；单步超过半天就拆。

## 工具链与 MoonBit 硬规则

`moon 0.1.20261023 / moonc v0.10.17`，特性开关 `rr_moon_mod + rr_moon_pkg`（元数据是 `moon.mod` / `moon.pkg`）。动手前先 `moon version --all`；写代码前按 AGENTS.md 的表加载对应 `.agents/skills/` 技能。最容易踩的：

- **导入只写 `moon.pkg`**；`.mbt` 文件里写 `import "..."` 是硬错误（3001/3002）。测试专用导入用 `import { … } for "test"`。
- **永远不要凭记忆写 stdlib API**：`moon ide doc "Type::method"` 核实后再用。
- **`Int` ≡ `Int32`**：formatter 归一为 `Int32`，新代码直接写 `Int32`。
- **可选参数实为带标签参数**（`name~ : T = d`）：只能 `f(x, name=1)` 按名传，**按位置传编译不过**。注意 `.mbti` 把 `?` 和 `~` 都渲染成 `name?`——"`.mbti` 无 diff = 接口没变"这条判据**有盲区**。
- **区间**写 `a..<b`（右开）/ `a..<=b`（闭）；`for` 头写坏会在下游报假错误，先修 for 头。
- **可抛错误**：`pub(all) suberror Name { Ctor(field~ : Type) }`；`Error` 是内建 opaque 类型，`impl Error for X` 必失败；展示用 `pub impl Show`。
- **带标签字段两头都带标签**：构造 `Ctor(a=1)`、匹配 `Ctor(a=x)`。
- **不要 `String::trim()` 接 `StringView::data()`**：`data()` 返回整个原串，trim 静默消失；照 `ical/text/content_line.mbt` 的 `trim_ascii` 写法来。
- 可执行包声明 `pkgtype(kind: "executable")`；`async fn main` 需要根包导入 `moonbitlang/async`。
- 块式组织：`///|` 分隔，每块一句"为什么"文档注释。

## 验证链（每次提交前）

```bash
moon fmt --check
moon check --target all --deny-warn
moon test  --target all --deny-warn
moon info               # 然后检查 *.mbti diff —— 接口变化必须是预期内的
```

CI（`.github/workflows/check.yml`）跑的就是这套。意外的 `.mbti` diff 说明改坏了边界；反过来说，**没有 diff 不等于接口没变**（见上面的 `?`/`~` 盲区）。

## 测试地图

| 层 | 载体 | 说明 |
|---|---|---|
| 单元测试 | `*_test.mbt`（黑盒）/ `*_wbtest.mbt`（白盒） | 各包目录内；`moon coverage analyze > uncovered.log` 找盲区 |
| RFC 语料对拍 | `ical/rrule/*corpus*` + `tools/gen_s3_corpus_test.py` | 期望值从 graham/rrule 套件**机械抽取**，不是实现的回声（R5 的库层范本） |
| 基准 | `*_bench_test.mbt` | native release；R 系列基线：parse ~15.6ms、multiget ~3.7ms、series ~1.68ms、monthly ~5.5ms |
| 活体验收 | `tools/s5_acceptance.py`（23 项）、`tools/s6_acceptance.py`（36 项） | 起服务器后 curl 打真实 TCP；S5/S6 全绿才算服务端验收 |
| fixture | `fixtures/recurrence-demo.ics`（`tools/make_recurring_fixture.py` 生成） | RRULE/EXDATE/RECURRENCE-ID/DST 全都有的演示源，驱动 demo/展开/合并/客户端演示 |

结果断言优先 `assert_eq` / `assert_true(pattern is ...)`；快照用 derive `Debug` + `debug_inspect`，别用 `Show`。

## 判别性验收规则 R1–R7（S10 复盘的产物）

0.2.0 有两条缺陷（`calendar-query` 忽略 filter、`MKCALENDAR` 不建集合）在全绿闸门下漏过，根因是**断言"预期的东西回来了"，而不是"输入改变了结果"**——全量返回的桩实现同样能通过。固化后的规则：

- **R1 判别对**：凡"接收输入并决定输出"的操作，必须有一对**只差该输入**的请求，断言结果**不同**。
- **R2 空结果**：选择/过滤类操作必须有"返回空集"的用例（区间外、无匹配）。
- **R3 拒绝落点**：可拒绝的操作断言**具体状态码 + 具体错误元素**（`403` + `<C:valid-filter/>`），不能只写"不是 200"。
- **R4 能力即证据**：README / 手册 §02 里每条对外能力，必须能在 §11 的"能力→证据矩阵"定位到判别性证据；定位不到就移进 §08 边界。
- **R5 规范机械对拍**：协议请求体从 RFC 例子机械抄录并注明章节，手写只作补充。
- **R6 互操作≠完整**：客户端会话只证明它走过的路，矩阵要记"未覆盖"列。
- **R7 可判否**：验收标准必须写成能判"否"的形式（"REPORT 全绿"不合格）。

**改能力声明前问三句**（§11 结尾）：①矩阵里定位得到判别性证据吗？②证据里有只差输入的一对请求吗？③新增 4xx 拒绝路径有拒绝用例吗？任何一句答不上来，先补证据再改声明。

## 里程碑节奏

历史节奏是 `S0–S15`（功能）与 `R1–R12`（复盘/优化），全部完成；0.3.0 开发中。新工作沿用同一循环：**写测试先行 → 实现 → 验证链 → 一次提交 → 更新 PROGRESS.md 与手册**。范围红线：单步新增超过计划规模 1.5 倍即视为蔓延，砍回去。明确不做的清单（§08）与已知未验证面（§11 诚实清单）在动手前先看一眼，别把边界内的省略当成 bug 修。
