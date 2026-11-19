# RFC 5545 / RFC 4791 合规矩阵

2026-11-19 审计轮产出。每一行是条款、原文关键句、实测定性、证据位置。
"容忍"指服务器接受超出 RFC 最低要求的形状——门与求值器等宽(S53 原则),不是缺陷;
"缺口"指违反 MUST 的行为,本轮已修复的标出提交号。探针存档 `/tmp/security-audit/compliance_probe.py`。

## RFC 5545(iCalendar)

| 条款 | 要求(摘句) | 判定 | 证据 |
|---|---|---|---|
| §3.1 | 行 ≤75 八位组折叠,不拆 UTF-8 | 合规 | `ical/serialize/serialize_test.mbt` 往返;GET 逐字节回存是 ETag 契约,存储层不重折叠(设计) |
| §3.1 | TEXT 转义 `\,` `\;` `\n` `\\` | 合规 | `escape_value` + 探针往返逐字;CR 统一转 `\n` |
| §3.3.5 | DATE-TIME 四形态(floating/UTC/TZID/DATE) | 合规 | `parse_date_time` + datetime 测试 |
| §3.3.9 | DURATION 严格文法(阶段机) | 合规 | S29 的 10 合法/12 拒绝差分 |
| §3.3.10 | RECUR 语义 + UNTIL UTC | 合规 | graham 语料机械抽取 + dateutil 对拍 + fuzz 100 条 0 不一致;WEEKLY+BYMONTHDAY 按 MUST NOT 拒绝(S57) |
| §3.3.14 | UTC-OFFSET 允许 `±hhmmss` 秒形 | 合规 | 探针实测存储;S20 的 ≤23h 上界 |
| §3.8.2.2 | DTEND 值必须晚于 DTSTART("MUST be later in time") | 容忍(门不拒,JEV 0.025) | 空区间求值:任何 time-range 窗口都不选中(钉住);负 DURATION 语法合法值同口径 |
| §3.6 | iCalendar 对象 MUST 含 PRODID 与 VERSION | 容忍(缺失放行) | 探针:仅 VERSION / 仅 PRODID / 均无 → 201。文档化容忍,门=求值宽 |
| §3.6.1 | VEVENT 必含 DTSTAMP 与 UID | 容忍(缺失放行) | 探针:无 DTSTAMP → 201;无 UID 是 R8 既定宽容。求值不读 DTSTAMP |
| §3.8.2.2 | DTEND 值类型必须同 DTSTART;DATE 起点配 DURATION 只能 dur-day/week | **缺口→已修 S62** | 探针:DATE 起点 + DATE-TIME DTEND 曾存储,现 403 valid-calendar-data |
| §3.8.2.2/3 | DTEND 与 DURATION 不得并存 | 合规(原有) | S29 测试;探针 403 |
| §3.6.1 | DTSTART/UID/RECURRENCE-ID "MUST NOT occur more than once"(ABNF 逐字) | **缺口→已修 S62** | 探针:三类重复曾静默收下(`property()` 取首条),现 403 |
| §3.6.1 | RRULE "SHOULD NOT occur more than once";dtend/duration 无 once 注记(仅互斥 MUST) | **S72 纠偏** | 逐字核验发现 S62 曾把这三类按 MUST 拒——按 JEV 判定(0.948/0.816)恢复宽容取首条,与 dateutil/icalendar 口径一致;互斥 MUST 与值类型 MUST 仍拒绝 |
| §3.8.4.7 | UID 唯一标识 | 合规(S61 补齐) | 同集合重复 UID → 403 no-uid-conflict(S61);无 UID 单独判定(S37) |
| §3.8.5.3 | RRULE 至多一条 | **缺口→已修 S62** | 同上 |

## RFC 4791(CalDAV)

| 条款 | 要求(摘句) | 判定 | 证据 |
|---|---|---|---|
| §4.1 | 不多于一种实体类型;MUST NOT 带 METHOD;VTIMEZONE 豁免 | 合规(S60) | 探针:混合 403 valid-calendar-object-resource、METHOD 403、顶层 VALARM/VTIMEZONE 放行 |
| §5.2.3 | supported-calendar-component-set 广告与门等宽 | 合规(S60) | propfind 广告 VEVENT-only;非 VEVENT PUT → 403 supported-calendar-component |
| §5.3.2 | valid-calendar-data / valid-calendar-object-resource | 合规(S53/S54/S62) | 垃圾/PERIOD/序数 WEEKLY/重复属性/类型混搭全 403,被拒体不落盘 |
| §5.3.2.1 | no-uid-conflict:同集合 UID 唯一;覆写不得换 UID | **缺口→已修 S61** | 探针:重复 UID 曾 201,现 403 命名持有者 href;覆写换 UID 403 命名自身 |
| §5.3.2.1 | UID 作用域是集合 | 合规 | R1 探针:跨集合同 UID 双双 201 |
| §9.6/9.1 | calendar-data 非 WebDAV 属性;PROPFIND Depth/选择 | 合规(S34/S43) | s6 钉子 |

## RFC 7232(条件请求)

| 条款 | 要求(摘句) | 判定 | 证据 |
|---|---|---|---|
| §3.1 | If-Match 用强比较:弱标签永不匹配 | **缺口→已修 S64** | 探针:`W/"etag"` 曾 204,现 412 |
| §3.2 | If-None-Match 用弱比较 | 合规 | 同一比较器的 weak 分支;钉死测试 |
| §3.1 | 列表任一匹配即通过 | 合规 | s6 + 探针:列表含现标签 204,不含 412 |
| §3.2 | If-None-Match 弱比较;GET/HEAD MUST 评估 | **缺口→已修 S67** | 探针:现标签曾 200,现 304+ETag;陈旧 200;弱拼写 304 |

## 显式边界(声明而非缺陷)

- GET 返回存储字节原文——ETag 是内容寻址,折叠/序列化是客户端与库层的职责(`ical/serialize`)。
- 求值容忍的形状(TEXT 含 NUL、无 DTSTART 的 VEVENT)继续存储——门与求值器等宽,毒化零路径。
- 顶层未知组件(含 VALARM)原样保留,不参与实体普查(§4.1 的豁免面)。
- 实体普查计数 VEVENT/VTODO/VJOURNAL/VFREEBUSY;未知组件不拒绝(容忍)。
- 存储原子性:PUT 经 dotfile 临时 + rename(2)(S68)——write_file 的默认原地截断不满足「读者只见旧或新」。
- 组件名 wire 上大小写不敏感(§3.6),comp-filter 匹配已同步(S70);CALDAV:expand 等未支持的扩展元素被忽略(不展开为声明的能力边界,非缺陷)。
