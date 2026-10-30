# 日历模型、重复集合与时间查询

本页说明当前 0.5.0 工作区的计算契约。0.4.0 已发布，但没有本轮的 RDATE 和严格时区变更。测试入口见 [development.md](development.md)。

## 解析保留与语义计算

`parse_calendar` 返回 `Component` 树；`parse_components` 接受逻辑行。未知组件和属性留在树里，序列化后再解析应得到相等的树。这不代表输入经过了完整 RFC 校验，也不代表所有属性都有类型化语义。

`parse_events` 将 VCALENDAR 下的 VEVENT 转成 `Event`。`Component::events(zones~)` 映射一个日历，`Component::event(zones~)` 只映射当前 VEVENT，其他组件返回 `None`。后一入口让查询不必解析无关事件。裸顶层 VEVENT 可保留为树，但 `parse_events` 不产出事件。

`Event` 包括 UID、文本字段、DTSTART/DTEND、RRULE 原文、EXDATE、RDATE、RECURRENCE-ID、RANGE 和 STATUS。`DURATION` 在没有 DTEND 时确定结束；两者并存报错。日期/周时长按固定偏移下的秒数计算，occurrence 可继承 master 时长。

## 时间与固定绑定

`IcalDateTime` 是结构体，保存墙上时间、可选 UTC 偏移、TZID 和全天标记，不是四个枚举构造子。

| 输入 | 当前处理 |
|---|---|
| `...Z` | UTC 绝对时刻 |
| 无 designator、无 TZID | floating 墙上时间；库排序按既有 epoch 约定，不替调用方选择当地时区 |
| `VALUE=DATE` | 全天日期 |
| `TZID=...` | 必须有可用的固定绑定，否则报 `BadLine` |

`ZoneTable::builtin_common()` 现在只提供 UTC/GMT/Z 固定别名，不再猜地域时区的标准偏移。调用方可用 `insert(name, seconds)` 明确声明固定绑定，并承担该绑定适用于输入日期的责任。

内嵌 VTIMEZONE 只有在可证明固定时才用于计算：STANDARD 必需字段唯一、DTSTART 为 floating DATE-TIME、FROM 与 TO 相同、所有段偏移一致，且没有 DAYLIGHT 或重复转换规则。动态、无效或冲突声明记录在拒绝表中，并遮蔽同名默认绑定；只有日期真正引用它时才失败。未引用的声明和原始树仍可保存、写回。`rejection_reason` 可查询拒绝原因。

不支持完整 IANA tzdb 或动态 VTIMEZONE 转换。即使事件没有跨 DST，夏季起点也不能用冬季偏移代算。

## RRULE 支持与预算

`parse_rule` 支持 DAILY/WEEKLY/MONTHLY/YEARLY，以及 INTERVAL、COUNT、UNTIL、序数 BYDAY、正负 BYMONTHDAY、BYMONTH、BYSETPOS、WKST。sub-daily 频率与 BYWEEKNO/BYYEARDAY/BYHOUR/BYMINUTE/BYSECOND 明确拒绝。

- 候选日期按周期排序、去重后再应用 BYSETPOS 和 COUNT。重复 BYMONTH 或归一到同一天的月日不重复计数。
- 不存在的日期跳过，不钳位成月末。
- COUNT 与 UNTIL 不能并存；UNTIL 的时间域必须符合起点。
- 步进使用 Int64；越出 year 9999 自然终止。
- `limit` 是原始 RRULE 实例预算。填满 limit 可以返回前缀；走完 10000 周期仍未耗尽且未填满预算时，`expand` 和 `expand_series` 报 `ExpandError::Invalid`，包括有 COUNT/UNTIL或零输出的情况。

语料来自 [graham/rrule](https://github.com/graham/rrule)，出处见 [第三方声明](../THIRD-PARTY-NOTICES.md)。旧纽约示例现在使用调用方显式固定绑定，只验证重复规则，不验证纽约历史偏移。

## RDATE 与系列合并

`expand_series` 接受一个 UID 的系列。候选由 RRULE 前缀（没有 RRULE 时为 DTSTART）与 master 的全部 RDATE 合并，按原始 recurrence slot 去重，再应用 EXDATE、改期、取消和 THISANDFUTURE，最后按实际开始排序。

RDATE 支持 DATE/DATE-TIME、多值和重复属性行。它可以早于 DTSTART 或晚于 UNTIL，不占 RRULE COUNT，也不会因生成预算而静默截断。相同 slot 优先保留已有 RRULE/DTSTART 表示。EXDATE 优先于同槽 override；RDATE slot 同样可改期、取消并继承时长。

PERIOD、空值、VALUE 与值形状不一致明确拒绝。重复集合需要 DTSTART；DATE、floating 与有偏移的 DATE-TIME 不混算。RID 和 override DTSTART 也必须与 master 的 DATE/floating 域一致。这是本库支持范围，不应表述成所有 RFC 合法组合都被支持。

`limit` 不限制合并后的总输出：有限 RDATE 全部加入，EXDATE/取消又可能缩短结果。不能从输出长度推断生成器是否结束。

## 查询完整性接口

`expand_series_query` 返回 `SeriesQueryResult`：

| 字段 | 用途 |
|---|---|
| `occurrences` | 当前生成预算内计算出的实例，加上全部 RDATE |
| `exhausted` | 原始生成因 COUNT、UNTIL、日期地平线结束，或无 RRULE 的有限起点已生成 |
| `generated_through` | 原始生成最后的实例；无 RRULE 时为 DTSTART。不含 RDATE，不受 EXDATE 影响 |
| `has_overrides` | 同 UID 存在覆盖；未移动的前沿不能证明移动后的窗口完整 |
| `budget_exceeded` | 周期预算耗尽，原始实例数仍未达到请求预算 |

这些字段用于证明查询，不是“已经完整计算”的统一标记。找到实际重叠实例足以返回匹配；返回不匹配则需要自然耗尽，或无覆盖且原始前沿已覆盖有限查询终点。有覆盖或开放终点时采取保守证明，预算内不能证明就失败。

## CalDAV 求值与错误

`Filter::matches(calendar_data)` 可以抛错。资源树先读取，时间只在相关测试需要时解析。SUMMARY 筛选、GET 和 multiget 不依赖重复规则或时区计算能力。

VEVENT time-range 按当前组件自身 UID 取系列，避免另一组件代为通过；成功的空系列不回退 master。非重复 VTODO 使用 RFC 4791 §9.9 的任务状态表；重复 VTODO 等未实现的组件重复计算明确失败。

`report` 区分四种结果：报告成功、未知报告、请求前置条件失败、资源求值失败。

| 情况 | HTTP |
|---|---|
| 成功，包括已证明为空 | 207 multistatus |
| 非法 filter/time-range | 403 `valid-filter` |
| 不支持的 filter 组件/属性/参数 | 403 `supported-filter` |
| 不支持的 collation | 403 `supported-collation` |
| 非法请求 timezone 的已检查结构/字段 | 403 `valid-calendar-data` |
| 资源解析/时间求值失败，或预算内不能证明查询结论 | 500，安全错误类别；不返回部分 multistatus |

请求 timezone 的转换尚未实现：其存在时，任何 temporal 判断保守失败，纯文本筛选仍可运行。合法性检查不宣称覆盖 observance RRULE 的全部规范语义。VALARM time-range 仍按现有能力契约拒绝为 `supported-filter`。

REPORT 资源求值失败的 500 响应和对应日志只带资源 href 与固定分类，不拼接原始异常、规则或日历正文。相关源文件是 `ical/model/{event,datetime,zone}.mbt`、`ical/rrule/{expand,series}.mbt` 和 `ical/caldav/filter.mbt`。
