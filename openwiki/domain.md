# 领域概念：iCalendar 模型与重复事件

本页是库层的语义地图：数据模型怎么建、重复事件怎么展开、CalDAV 过滤怎么求值。改这些区域前先读它；每条语义都有对拍或差分测试钉住（证据地图见 [development.md](development.md)）。

## 数据模型（`ical/model`）

**组件树**。`parse_components` 把逻辑行建成 BEGIN/END 嵌套的 `Component` 树。未知组件和未知属性**原样保留**——这是设计立场，不是宽容：序列化 roundtrip 后组件树必须相等，未知内容仍出现在输出里。

**四态时间 `IcalDateTime`**（derive `Eq`）：

| 形态 | 例子 | 语义 |
|---|---|---|
| UTC | `DTSTART:20260901T090000Z` | 绝对时刻 |
| floating | `DTSTART:20260901T090000` | 无时区的墙上时间 |
| TZID | `DTSTART;TZID=America/New_York:...` | 经 `ZoneTable` 解析出偏移 |
| 日期（全天） | `DTSTART;VALUE=DATE:20260901` | `Event::all_day` 判定 |

解析入口：`parse_date_time`（内容行）、`parse_single_date_time`（RRULE 的 UNTIL 等裸值）、`parse_date_time_value`（EXDATE 多值）。关键规则：**未知 TZID 报错，不静默回落 UTC**。

**`ZoneTable`**：内置常用时区的固定偏移表（`builtin_common`）+ feed 内嵌 `VTIMEZONE`（优先级更高）。内部是 `Map[String,Int]` 索引（R11 优化，覆盖写 = 后插入胜）。仓库没有完整 IANA tzdb——重复的墙上时间跨 DST 保持解析出的偏移，这是声明过的边界。

**`Event` 类型化视图**：`parse_events` / `parse_calendar` 从组件树抽取 `Event { uid, summary, location, description, dtstart, dtend, recurrence_id, rrule, exdates }`。属性缺失是 `None` 不是错；畸形属性带行号报错。

## RRULE 分档语义（`ical/rrule`）

支持面按"档"划分，**档外子句显式 `BadRule` / `ExpandError::Unsupported` 报错，绝不静默吞**：

- **支持**：`DAILY` / `WEEKLY` / `MONTHLY` / `YEARLY` × `INTERVAL`、`COUNT`、`UNTIL`、序数 `BYDAY`（如 `-1SU`）、正负 `BYMONTHDAY`、`BYMONTH`、`BYSETPOS`、`WKST`。
- **显式拒绝**：sub-daily 频率（`HOURLY`/`MINUTELY`/`SECONDLY`）与 `BYWEEKNO`、`BYYEARDAY`、`BYHOUR`、`BYMINUTE`、`BYSECOND`。

展开语义的关键点：

- **候选组合**：MONTHLY/YEARLY 中多个 BY* 子句同时存在 = 交集，单个 = 生成器，全无 = DTSTART 回退特例。
- **不存在的日子跳过不钳位**：`MONTHLY;BYMONTHDAY=31` 在 2 月不产出 Feb 30。
- **错误契约**：`COUNT`+`UNTIL` 互斥、`UNTIL` 与 DTSTART 值类型不一致 → `ExpandError::Invalid`。
- **数值安全**（S12）：展开步进全 `Int64` 化；越出 year 9999 视为序列自然终结，不再回绕出"有效但错误"的日期。
- **负 `BYMONTHDAY`**（S11）：DAILY/WEEKLY 路径按候选日所在月长度归一化判定——曾静默零匹配，现已用差分测试钉死。

**对拍纪律**：期望值不是自造的。`expand_corpus_test.mbt` 由 `tools/gen_s3_corpus_test.py` 从 [graham/rrule](https://github.com/graham/rrule) 测试套件**机械抽取**生成（第一档 23 条 + 第二档 8 条；语料出处登记在 THIRD-PARTY-NOTICES.md）。改展开逻辑前先跑它。

## 系列覆盖合并（`expand_series`）

真实日历里重复事件不是一条 RRULE 就完事——`expand_series(events)` 在日历级做有效系列合并：

- `EXDATE`：从序列中移除指定实例；
- `RECURRENCE-ID` + 改期 DTSTART：移动单个实例；
- `RECURRENCE-ID` + `STATUS:CANCELLED`：取消单个实例；
- `RANGE=THISANDFUTURE`：从覆盖点起重定向整个后缀。

性能关键路径（R1）：同 UID 的 overrides/EXDATE **一次索引**，按序游标应用 THISANDFUTURE——2000 occurrences + 500 overrides 的基准从 20.27ms 降到 1.64ms。改 `series.mbt` 时保住这个结构，别退回逐条扫描。

## CalDAV filter 求值（`ical/caldav/filter.mbt`）

`calendar-query` 的 `CALDAV:filter` 是一棵 `CompFilter`/`PropFilter` 树（`parse_filter` 从 XML 请求体解析，非法结构回 `FilterError`）：

- 嵌套 `comp-filter` 与 `is-not-defined`；
- `time-range`：对含 RRULE 的组件走 `expand_series` 展开判重叠（RFC 4791 §7.4/§9.9）；
- `prop-filter` 的 `text-match`（两种 collation：默认 `i;ascii-casemap` 折叠大小写、`i;octet` 字节敏感）与 `param-filter`；
- 求值入口 `Filter::matches(calendar_data)`，对序列化后的 `.ics` 文本判定。

**前置条件**按 RFC 4791 §7.8 回 `403` + `DAV:error`：无 filter 或非法 filter → `valid-filter`；不可支持的过滤（如对 `VALARM` 的 time-range，不解析相对 trigger）→ `supported-filter`。XML 本身的嵌套深度上限 64，越界整文档拒绝（S13：曾可栈溢出杀死进程）。

## 错误契约总览

每个包一个 `suberror`，带标签字段，derive `Eq`：

| 包 | 错误 | 典型变体 |
|---|---|---|
| `ical/text` | `ParseError` | `BadLine(line_no~, line~, message~)` |
| `ical/rrule` | `ExpandError` | `Invalid`、`Unsupported` |
| `ical/caldav` | `FilterError` | `InvalidFilter(message~)`、`UnsupportedFilter(element~)` |
| `ical/store` | `StoreError` | `BadName(name~)` |
| `ical/httpd` | `HttpParseError` | `Malformed(message~)`、`ChunkedBody`、`BodyTooLarge(limit~)` |

历史教训（S12）：不要让外部依赖的未类型化 `Failure`（如 x/time 的日期越界）泄漏过包边界——越界日期分量必须收敛为带行号的 `BadLine`。给某条错误路径改契约时，连判别式测试一起改（S14 的 400/413 分流就是这么做的）。
