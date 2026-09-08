# moon-ical 任务跟进（跨会话交接文档）

> **用途**：跨会话任务跟进的唯一状态源。任何会话**开工前先读本文件**，**收工前更新它**。
> 分工：`docs/development.html` 是手册（定位/架构/规矩），本文件只回答「**做到哪了、下一步干什么、为什么这么定**」。
> 最后更新：2026-09-08 · S1 完成后

---

## 1. 状态一览（新会话从这里开始）

| 项 | 值 |
|---|---|
| 当前里程碑 | **S2 待做**：RRULE 解析，不展开（~200 行；验收 = graham 32 条 rule 串按档位解析或报错） |
| HEAD | S1.5（fetch 切片，本提交；之前 `79752d9` S1、`0ab8978` S0）（分支 master，无远程） |
| 测试 | 73/73 绿（`moon check` ✓ · `moon test` ✓）；端到端实测：用户提供的 chinacalendar.app URL → 13 个事件 |
| 规模 | 实现 1155 行 + 测试 665 行 + demo 71 行 |
| 阻塞 | 无 |
| 待用户确认 | `moon.mod` 的 `repository = ""` 需真实 GitHub 仓库地址 |

## 2. 里程碑进度

| 步骤 | 状态 | commit | 一句话 |
|---|---|---|---|
| S0 清场 | ✅ | `0ab8978` | 删模板/探针，README/moon.mod 就位，登记 S6 接缝 |
| S1 事件层 | ✅ | `79752d9` | `Event` 类型化视图 + `parse_events` + demo 可运行 |
| S1.5 取件切片 | ✅ | 本提交 | `ical/fetch` + demo URL 模式；实测 chinacalendar.app 2026 中国节假日 → 13 事件 |
| S2 RRULE 解析 | ⏳ | — | 第一档子句 → `Rule` 结构；不支持子句显式报错 |
| S3 第一档展开 | ⏳ | — | DAILY/WEEKLY/MONTHLY…附录 A ~20 用例对拍（语料在 `.survey/src/graham_rrule/basic_test.go`） |
| S4 序列化写回 | ⏳ | — | fold/escape，roundtrip 测试 |
| S5 HTTP+存储 | ⏳ | — | 手解析 HTTP/1.1（接缝 S6）+ vdir 文件存储 |
| S6 WebDAV/CalDAV | ⏳ | — | PROPFIND/REPORT/MKCALENDAR + 发现链 |
| S7 客户端联调 | ⏳ | — | Thunderbird → DAVx5 → Apple 日历，互操作矩阵 |
| S8 库层深度 | ⏳ | — | RECURRENCE-ID 合并 + 第二档 BY* + ZoneTable 接入展开链 |
| S9 发布打磨 | ⏳ | — | CI、mooncakes 发布、申报书、根包门面 |

每个里程碑的目标/规模/验收细则见 `docs/development.html` §04。

## 3. 会话日志（append-only，新会话往后追加）

### 2026-09-08 · Session A（定向 → S0 → S1）
- 竞品调研完成（5 包，全离线库），评委确认 CalDAV 选题；产出计划 v2（`docs/development.html`）。
- S0：删 `cmd/`、`spike/`、`probe/` 与根包测试桩；README/moon.mod 就位；登记接缝 S6。
- 开发手册 `docs/development.html` 上线，并确立本文件为跨会话状态源。
- S1：`ical/model/event.mbt`（Event 视图 + `parse_events`）+ `parse_date_time_value`（EXDATE 多值）+ `demo/`；`IcalDateTime` 补 derive `Eq`。
- S1.5：`ical/fetch`（`fetch_ics` 薄层 + `FetchError`）+ demo URL 模式（`@env.args()` 扫描 http(s):// 参数，async main）；用户提供的 `chinacalendar.app/ics/china-calendar-2026.ics` 端到端跑通 → 13 事件（命令：`moon run demo --target native -- <url>`）。
- 计划调整（用户提议）：S1 与 S2 之间插入 **S1.5 取件切片**——解析既已落地，fetch→parse→打印 的端到端立刻可用，用户可直接提供 URL 参与测试；网络测试不进 CI（Google 源本网络不可达，演示用 calendarlabs）。完整订阅同步（缓存/刷新）仍留在 S9 支线，避免提前倒逼半成品存储层。

### 遗留事项
- `repository = ""` 待填（等用户提供真实仓库 URL）。
- S3 动工前**不要删 `.survey/`**（对拍语料）；`.repos/` 是依赖缓存，同理保留。
- 手册 §06 踩坑清单可补两条 S1 实测坑：可选参数展开 `tzid?` 要求 `String??`（应传 `tzid=tzid`）；MoonBit 无 `?.` 可选链（用 match/`unwrap()`）。

## 4. 关键决策记录（为什么这么做）

| 决策 | 理由 | 出处 |
|---|---|---|
| 选题 = iCal 库 + **CalDAV 服务器** | 评委 2026-09-08 确认；mooncakes 检索 `caldav/webdav/webcal` 均 0 结果；五竞品全是离线计算库 | `docs/research/mooncakes-competitors-survey.html` |
| RRULE 深度止于 RFC 附录 A 对拍 | rrule_lab 已把 BYSETPOS/负序号/可解释做到头；我们的差异在端到端 + 服务 | 计划 v2 §0 |
| S5 手解析 HTTP/1.1 请求行 | `RequestMethod` 是封闭枚举（`types.mbt:16`），装不下 PROPFIND/REPORT；`ServerConnection` 实现 `@io.Reader` 可自解析 | 接缝 S6（upstream-seams.md） |
| vdir 一文件一项存储 | Radicale 同款路线，跨工具互认 | 计划 v2 §1 |
| 保留 `.survey/`、`.repos/`（虽 gitignore） | 前者是 S3 对拍语料，后者是依赖缓存；均不进仓库 | S0 报告 |

## 5. 跨会话环境事实

- 工具链 `moon 0.1.20260827 / moonc v0.10.11`，新格式 `rr_moon_mod + rr_moon_pkg`（坑清单见手册 §06）。
- 依赖 `moonbitlang/async@0.21.2` + `moonbitlang/x@0.5.1`，已缓存在 `.mooncakes/` 与 `.repos/`。
- 无 git remote；`core.hooksPath` 指向 EvoX git-hooks（项目 `.githooks/` 未启用）。
- 用户语言偏好：**回复始终简体中文**（已存档）。
- 黑盒测试惯用法：`try { } catch { err => err.to_string() }`；别名 `@model`/`@text` 经 moon.pkg 的 `for "test"` 导入。

## 6. 收工清单（每次会话结束前过一遍）

1. `moon fmt && moon check && moon test && moon info` 全绿？`.mbti` diff 在预期内？
2. 本文件 §1/§2/§3 更新了吗？
3. 若完成了里程碑：`docs/development.html` §02 快照与 §04 状态同步了吗？
4. commit 完成、`git status` 干净？
