# 开发工作流与验证闸门

本页是改代码前要过的规矩：工具链硬规则、验证链、判别性验收、里程碑纪律。权威出处：[AGENTS.md](../AGENTS.md)、[docs/development.html](../docs/development.html) §05/§06/§11、`docs/PROGRESS.md`（本地）。

## 开工 / 收工的固定动作

- **开工先读 `docs/PROGRESS.md`**——它是跨会话状态源（本地文件、gitignored）：状态一览、里程碑表、会话日志。
- **收工必更它**，并同步 `docs/development.html` §02/§04（若里程碑落地）。pre-commit 钩子会机械校验"源码提交时 PROGRESS.md 的 mtime 晚于上次提交"。
- **提交命令是固定的**：`git -c core.hooksPath=.githooks commit ...`。EvoX 环境注入全局 `core.hooksPath`，配置压不过，必须显式 `-c` 才能让项目闸门（`moon check` + 文档同步检查）生效。**绝不 `--no-verify`，绝不裸 `git commit`**。
- 里程碑提交：一次提交一个最小目标，消息 `S<n>: <一句话>`，正文列改动点 + 验收证据；单步超过半天就拆。

## 工具链与 MoonBit 硬规则

`moon 0.1.20261119 / moonc v0.10.22+124d61d05`（2026-11-22 升级,配对 async@0.22.10——旧 moonc v0.10.20/21 的 wasm-gc 代码生成对 0.22.10 会产出 V8 拒绝的模块,升级即解）（S36 已按 v0.10.20 迁移全仓：`#derive` 前置、`to_string_view()`/`clamped_view` 替代弃用的 `.view()`/切片糖），特性开关 `rr_moon_mod + rr_moon_pkg`（元数据是 `moon.mod` / `moon.pkg`）。动手前先 `moon version --all`；写代码前按 AGENTS.md 的表加载对应 `.agents/skills/` 技能。最容易踩的：

- **导入只写 `moon.pkg`**；`.mbt` 文件里写 `import "..."` 是硬错误（3001/3002）。测试专用导入用 `import { … } for "test"`。
- **模块根下的 `moon run x.mbtx` 从 mooncakes 注册表解析自模块 import，不是工作区**（实证：给本地包加语法错误，脚本照样运行——它测的是已发布的 0.5.0）。对工作区代码做行为验证，一律用模块内临时主包（`tmpfuzz/`，`pkgtype(kind: "executable")`，`moon run tmpfuzz --`，用后即删）。
- **永远不要凭记忆写 stdlib API**：`moon ide doc "Type::method"` 核实后再用。
- **`Int` ≡ `Int32`**：formatter 归一为 `Int32`，新代码直接写 `Int32`。
- **可选参数实为带标签参数**（`name~ : T = d`）：只能 `f(x, name=1)` 按名传，**按位置传编译不过**。注意 `.mbti` 把 `?` 和 `~` 都渲染成 `name?`——"`.mbti` 无 diff = 接口没变"这条判据**有盲区**。
- **区间**写 `a..<b`（右开）/ `a..<=b`（闭）；`for` 头写坏会在下游报假错误，先修 for 头。
- **可抛错误**：`pub(all) suberror Name { Ctor(field~ : Type) }`；`Error` 是内建 opaque 类型，`impl Error for X` 必失败；展示用 `pub impl Show`。
- **带标签字段两头都带标签**：构造 `Ctor(a=1)`、匹配 `Ctor(a=x)`。
- **不要 `String::trim()` 接 `StringView::data()`**：`data()` 返回整个原串，trim 静默消失；照 `ical/text/content_line.mbt` 的 `trim_ascii` 写法来。
- 当前可执行包使用 `pkgtype(kind: "executable")`；异步入口按依赖配置导入 `moonbitlang/async`。
- 代码块用 `///|` 分隔；注释说明契约或不明显的理由，避免逐句复述实现。

## 验证链（每次提交前）

```bash
moon fmt --check
moon check --target all --deny-warn
moon test  --target all --deny-warn
moon info               # 然后检查 *.mbti diff —— 接口变化必须是预期内的
```

CI 使用同类检查。`.mbti` 变化需要与预期契约逐项核对；没有 diff 也不能排除调用约定变化。本轮未提交、未触发远程 CI，验证结果来自本地。

## 测试地图

| 层 | 载体 | 说明 |
|---|---|---|
| 单元测试 | `*_test.mbt`（黑盒）/ `*_wbtest.mbt`（白盒） | 各包目录内；`moon coverage analyze > uncovered.log` 找盲区 |
| RFC 语料对拍 | `ical/rrule/*corpus*` + `tools/gen_s3_corpus_test.py` | 期望值从 graham/rrule 套件**机械抽取**，不是实现的回声（R5 的库层范本） |
| 第三方言差分 | `ical/rrule/sabre_corpus_test.mbt` | sabre-io/vobject（PHP 生态事实标准）EventIterator 的 override 合并语义移植 5 例（S55），首轮零分歧；其中两例按分歧钉死不移植——跨 UID override sabre 宽容而 RFC 5545 §3.8.4.4 要求同 UID，全排除序列 sabre 抛错而查询模型答空集（R2） |
| 基准 | `*_bench_test.mbt` | native release；R 系列基线：parse ~15.6ms、multiget ~3.7ms、series ~1.68ms、monthly ~5.5ms；unfold 基准钉住 S25 的线性化（770KB 折行行 1.68s → 6.6ms，修复前是二次方拼接） |
| 活体验收 | S5（24 项）、S6（91 项）、S7（34 项原始 socket，`tools/s7_http_acceptance.py`），另有 `tools/s6_evaluation_acceptance.mbtx` | 真实 TCP 检查；新驱动包括 RDATE、预算、错误分类和日志隐私，使用隔离目录。S7 用裸 TCP 盖 curl 不会发的形状：流水线、HEAD 错误无体（RFC 9110 §9.3.2）、obs-fold/TE 组合、行与头数上限、并发同 UID 恰一赢家、反射注入守卫 |
| fixture | `fixtures/recurrence-demo.ics` 与既有生成器 | 使用显式 DEMO-FIXED-0500，不作为动态纽约时区证据 |
| 本轮回归 | `recurrence_dates_test`、`fixed_zone_test`、`series_query_test`、`review_regression_test`、`evaluation_test` 与根门面测试 | 集合差分、完整性、明确拒绝、合法空集、HTTP 与隐私路径 |

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

**改能力声明前问三句**（§11 结尾）：①矩阵里定位得到判别性证据吗？②证据里有只差输入的一对请求吗？③新增失败路径（包括 500）有对应状态和安全错误内容的用例吗？任何一句答不上来，先补证据再改声明。

## 里程碑节奏

S0–S35 和 R1–R14 是已有历史；0.4.0 与 0.5.0（2026-10-31）均已发布到 mooncakes。驳回修复波以 S35 入库，与远端 S34/R14 合流后提交。提交使用固定命令 `git -c core.hooksPath=.githooks commit`。

S36–S60 是 2026-11-13/15/18 的三连波加一次收窄落地（工具链迁移 → JEV 审计修复 → 黑客轮实机攻击与成熟方案对齐 → 广告集执行），已入库**未推送**：S36 迁移 v0.10.20；S37 修递归/变更语义四处缺陷；S38-S53/S55 为实机攻击面修复（存储毒化 XML、走私头、超长名、可证空预算、双根 XML 杀进程、并发连接杀进程、PUT 前置校验、sabre 语料）与 S43-S52 的方法面补齐（文件级 PROPFIND/REPORT、HEAD、scoped Allow）；S56/S57 把可证空证明推广成形状不相交穷举并按 RFC 拒绝 WEEKLY;BYMONTHDAY；S60 把 PUT 门收窄到集合自己宣传的 VEVENT-only 组件集（METHOD/混合类型 → valid-calendar-object-resource，非 VEVENT 实体 → supported-calendar-component）。**破坏性变更：WEEKLY+BYMONTHDAY 从宽容过滤变为拒绝；VTODO/VJOURNAL/VFREEBUSY 从可存储变为 403**。S61-S73 为 11-19 审计波（UID 唯一性、重复行门界、条件 GET、原子写、流水线、分帧边界、Expect 100-continue）。详见 `docs/PROGRESS.md` 里程碑表。

2026-11-19 全目标严格测试为 310/310/290/321（wasm/wasm-gc/js/native），S5 24/24、S6 91/91、S7 34/34 活体全绿。S73 起 `Expect: 100-continue` 被尊重（读体前写 100）。S61-S72 是 11-19 的审计波（no-uid-conflict、重复属性行门界、条件 GET 304、原子写、流水线缓冲、comp-filter 大小写、HEAD 错误无体）；PUT 门收窄为 VEVENT-only 与广告集等宽。能力范围与证据对应表见手册 §11；明确拒绝的输入不能在申请材料里改称通用处理。
