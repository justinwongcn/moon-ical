# 架构与数据流

moon-ical 是两条栈：一条**库管线**把 `.ics` 文本变成类型化事件并展开重复，一条**服务栈**在这之上接出 CalDAV 协议面。每个包一个层，单向依赖，层间只经公开接口（`*.mbti`）通信。

## 库管线（纯函数，四个目标全可用）

```
.ics 文本 ──▶ ical/text ──▶ ical/model ──▶ ical/rrule ──▶ occurrences
  物理行        unfold        组件树          解析+展开
                内容行        IcalDateTime
                              ZoneTable / Event
                     model ──▶ ical/serialize ──▶ 折行 .ics 文本
```

- `ical/text`：`unfold` 把折叠的物理行还原成逻辑行，`parse_content_line` 解析名字/参数/值（引号参数、TEXT 转义）。所有解析错误是带行号的 `ParseError`。
- `ical/model`：`parse_components` 建 BEGIN/END 嵌套的组件树；`build_zone_table` 从 `VTIMEZONE` + 内置常用固定偏移表建时区表；`parse_events` / `parse_calendar` 给出 `Event` 类型化视图。
- `ical/rrule`：`parse_rule` 把 RRULE 值解析成类型化 `Rule`（不支持子句**显式报错**），`expand` 单规则展开，`expand_series` 在日历级合并 `EXDATE` 与 `RECURRENCE-ID` 覆盖。语义细节见 [domain.md](domain.md)。
- `ical/serialize`：组件树 → CRLF 折行 `.ics`，与解析对称（roundtrip 组件树相等且幂等）。CalDAV 响应体里的 `calendar-data` 就是它的输出。

`ical/fetch` 是可选的网络取件切片（`fetch_ics`），demo 用它做 URL 模式；网络测试不进 CI 是 S1.5 的既定决策。

## 服务栈（native 目标）

```
日历客户端 ──▶ cmd/serve ──▶ ical/httpd ──▶ ical/caldav（纯语义）
 (curl 等)      TCP accept      请求行/头/体      PROPFIND / REPORT / filter
                     │                            │
                     └────▶ ical/store ◀──────────┘
                            vdir：每事件一个 .ics
```

关键设计：`ical/caldav` 是**纯函数包**（`moon.pkg` 注释明言 "Filesystem and sockets remain in cmd/serve"），所以整套协议语义可以在任意后端上单测；socket 与文件系统只出现在 `cmd/serve`。`caldav` 为求值 `CALDAV:time-range` 直接依赖 `model` 与 `rrule`——重复事件的区间判定走 `expand_series`（RFC 4791 §7.4）。

`cmd/serve` 的路由按路径分类（`target_of`）：`/`、`/.well-known/caldav`、`/principals/default/`、`/cal/`（日历家 = 默认集合）、`/cal/<cal>/`（集合）、`/cal/<name>.ics` 与 `/cal/<cal>/<event>.ics`（事件）。协议面详情见 [server.md](server.md)。

## 根包门面

`moon-ical.mbt` 用 `pub using` 把子包的稳定公开 API 重导出为一个导入面：`parse_calendar` / `parse_events` / `parse_rule` / `expand` / `expand_series` / `serialize_component(s)` 及核心类型。**协议拼装原语（text 层、caldav 层）不进门面**——这是 R3 里程碑定下的收口原则：顶层只暴露完整工作流，需要原语的调用方导入对应子包。

## 设计立场（后续所有包必须继承的基线）

1. **保真优先**：未知组件/属性一律保留（竞品是固定字段清单）；序列化 roundtrip 后组件树相等。
2. **时间四态显式建模**：UTC / floating / TZID / 全天日期是 `IcalDateTime` 的构造子，不共用一个"字符串时间"。
3. **解析不了就报错**：带行号报错而不是静默吞掉；不支持的 RRULE 子句、不支持的时间范围（如 VALARM 的 time-range）都是具名错误或具名拒绝，不静默降级。

## 依赖与上游接缝

`moon.mod` 只依赖 `moonbitlang/async@0.21.2` 与 `moonbitlang/x@0.5.1`。围绕上游能力缺口定下的策略（完整登记在 [docs/upstream-seams.md](../docs/upstream-seams.md)）：

- **无 IANA tzdb**：`ZoneTable` = 固定偏移表 + feed 内嵌 `VTIMEZONE`；重复的墙上时间跨 DST 保持解析出的偏移。边界写进了 README。
- **`@async` 的 `RequestMethod` 是封闭枚举**，没有 PROPFIND/REPORT/MKCALENDAR：所以 `httpd` 手解析请求行（方法只是 token）。上游扩展后可一行切回 `read_request`。
- **`@async/fs` 只有 native 实现**：CalDAV 服务器主目标 native，js 支持延后。

## 文档与源码的一处已知不一致

[docs/development.html](../docs/development.html) §03 的流程图写着 "XML 用 `Milky2018/xml`"，这是早期计划；S10 起实际落地的是**自研最小 XML 形状解析器** `ical/caldav/xml.mbt`（嵌套深度上限 64，按 `(namespace-uri, local-name)` 匹配，前缀无关），`ical/caldav/moon.pkg` 里没有任何外部 XML 依赖。以源码为准。

## 改动落点速查

| 想改什么 | 从哪开始 |
|---|---|
| 解析行为（折叠/转义/参数） | `ical/text/content_line.mbt`、`ical/text/unfold.mbt` |
| 事件视图 / 时间语义 | `ical/model/event.mbt`、`ical/model/datetime.mbt`、`ical/model/zone.mbt` |
| RRULE 语义 | `ical/rrule/parse.mbt`、`ical/rrule/expand.mbt`、`ical/rrule/series.mbt` |
| 序列化 | `ical/serialize/serialize.mbt` |
| 协议语义 / filter | `ical/caldav/caldav.mbt`、`ical/caldav/filter.mbt`、`ical/caldav/xml.mbt` |
| HTTP 边界 | `ical/httpd/request.mbt` |
| 存储布局 / ETag | `ical/store/vdir.mbt` |
| 路由 / 连接处理 | `cmd/serve/main.mbt` |
