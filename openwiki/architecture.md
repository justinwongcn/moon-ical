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
- `ical/model`：`parse_calendar` 返回组件树，`parse_events` 返回类型化事件；`build_zone_table` 记录可靠固定绑定和拒绝状态，实际引用未知或动态时区时失败。
- `ical/rrule`：`parse_rule` 和 `expand` 处理支持的规则；`expand_series` 合并 RDATE、EXDATE 与覆盖，`expand_series_query` 提供原始生成完整性信息。细节见 [domain.md](domain.md)。
- `ical/serialize`：组件树写为 CRLF 折行 `.ics`，测试检查树往返相等和幂等。服务端 GET/REPORT 的 calendar-data 回传存储原文，不在读路径重新序列化。

`ical/fetch` 是可选的网络取件切片（`fetch_ics`，S20 起自带 `timeout_seconds?` 默认 30 秒、到点抛 `FetchError::TimedOut`——上游 HTTP 客户端与 socket 层没有任何超时），demo 用它做 URL 模式；外部 URL 的网络测试不进 CI 仍是 S1.5 的既定决策，S20 加的唯一单测靠本地"接受但永不响应"监听器触发超时，纯本地、进 CI。

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

`moon-ical.mbt` 用 `pub using` 把解析、重复和写回 API 重导出为一个导入面：`parse_calendar` / `parse_events` / `parse_rule` / `expand` / `expand_series` / `serialize_component(s)` 及核心类型。**协议拼装原语（text 层、caldav 层）不进门面**——这是 R3 里程碑定下的收口原则：顶层只暴露完整工作流，需要原语的调用方导入对应子包。

## 设计立场（后续所有包必须继承的基线）

1. **保真优先**：未知组件/属性一律保留（竞品是固定字段清单）；序列化 roundtrip 后组件树相等。
2. **时间状态显式保存**：`IcalDateTime` 用结构体字段区分 UTC、floating、TZID 和全天日期。
3. **保留与计算分开**：树可保留未解释数据；相关时间计算不能可靠完成时返回错误，不改成主事件区间，也不将未证明完整的结果当成空集。查询失败经 `ReportOutcome::EvaluationFailed` 传到 HTTP 500，原始异常内容不进入响应或日志。

## 依赖与上游接缝

`moon.mod` 只依赖 `moonbitlang/async@0.22.5` 与 `moonbitlang/x@0.5.6`。围绕上游能力缺口定下的策略（完整登记在 [docs/upstream-seams.md](../docs/upstream-seams.md)）：

- **时区范围有限**：只计算可靠固定绑定；动态 VTIMEZONE 和未绑定地域 TZID 明确拒绝。IANA 数据库与内嵌转换规则是两个不同能力，本项目目前都不提供通用解析。
- **WebDAV 方法**：`httpd` 在裸 TCP 上手解析方法 token。若改用上游请求层，需要重新核对方法、帧化 reader 和完整 HTTP 行为，不是替换一行调用。
- **`@async/fs` 只有 native 实现**：CalDAV 服务器主目标 native，js 支持延后。

## XML 请求解析

`ical/caldav/xml.mbt` 是最小形状解析器，嵌套深度上限 64，按元素局部名匹配，不完整校验命名空间 URI。没有外部 XML 依赖；DOCTYPE、双顶层和字符引用的限制见 README。

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
