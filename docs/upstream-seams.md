# 上游接缝与切换预案（活文档）

当前依赖：`moonbitlang/async@0.22.5`、`moonbitlang/x@0.5.6`（`moon.mod`）。下表区分实际实现、早期调研和待验证条件；不把规划中的适配器当成现有 API。上游能力变化后先验证契约，再决定迁移，不承诺“一行切换”。

## 接缝登记

| # | 能力 | 已核实的边界 | 当前实现 | 后续核对与切换条件 |
|---|---|---|---|---|
| S1 | 本地文件持久化 | 2026-09-08 调研：async/fs native 可用，js 未实现；当前 store/serve 仍限定 native | `ical/store/vdir.mbt` 直接使用 async/fs；没有 `js_shim.mbt` 或 localStorage 后端 | 上游有可用 js 文件接口后，重新验证文件/目录区分、ETag、条件写入和集合隔离，再调整目标配置。旧 `probe/js_fs_probe` 已不在树中，不列作可运行命令 |
| S2 | IANA tzdb / 动态时区 | x/time 提供固定偏移基础，不是完整 IANA 数据库。2026-09-08 检索未找到 tzdb 包；这不是今日全生态不存在的证明。IANA 数据与内嵌 VTIMEZONE 转换是两项不同能力 | `ical/model/zone.mbt` 的 `ZoneTable`。未发布 0.5.0 仅内置 UTC/GMT/Z；调用方可显式 `insert` 固定绑定。内嵌声明只有能证明固定时才可计算；动态、无效、同名冲突声明遮蔽默认绑定，引用时拒绝；未引用仍可保留/写回。没有 `ZoneResolver` trait 或 kawaz/timespec 依赖 | 人工检索 timezone/tzdb 并读候选实现。引入转换前验证夏季起点、转换边界、重复/缺失墙上时间、历史偏移与查询完整性；不以固定冬季偏移代算动态时区。证据：`ical/model/fixed_zone_test.mbt`、`ical/caldav/evaluation_test.mbt` |
| S3 | HTTP 取件与超时 | async/http 提供取件。S20/S21 对 async 0.21.2、0.22.4 的源码核查未找到客户端/socket 自带超时；后续升级不能自动证明它已补齐 | `ical/fetch/fetch.mbt` 的 `fetch_ics` 包装状态检查和 `with_timeout`，默认 30 秒，超时抛 `FetchError::TimedOut`；当前包限定 native。无 `Fetcher` 抽象或浏览器 fetch 适配器 | 升级时核对超时/取消与响应资源释放；若上游提供等价界限，再用本地永不响应监听器测试迁移。证据：`ical/fetch/fetch_test.mbt`；不承诺 wasm-gc HTTP 或单文件 CLI |
| S4 | async API 演进 | 早期 README 的 experimental 声明属调研记录，不能据此推断当前稳定性或正在进行的 PR | 触点位于 `ical/httpd/request.mbt`、`ical/store/vdir.mbt`、`ical/fetch/fetch.mbt`、`cmd/serve/main.mbt`；不存在 `ical/store/backend.mbt` 或 `ical/sync/fetch.mbt` | 依赖升级核对实际 API 与变更记录，跑严格四目标测试及三套活体驱动；没有证据时不承诺 core 合并时间表 |
| S5 | 系统本地时区 | 当前没有系统当地时区转换能力，也未依赖 kawaz/timespec | UTC、floating、DATE 和显式固定绑定；floating 不自动选择宿主当地时区 | 如需求出现，先定义宿主时区/日期边界契约再核对官方或社区接口；无现有“唯一调用点”可替换 |
| S6 | WebDAV 方法与 HTTP 帧 | 2026-09-08 核查 async `RequestMethod` 是封闭枚举，缺 PROPFIND/REPORT/MKCALENDAR；S5 实测 `ServerConnection` 的 Reader 是帧化 body，不是原始请求流 | `cmd/serve` 接受裸 TCP；`ical/httpd` 自行读取方法 token、头与 Content-Length 体并写响应。没有使用 `ServerConnection::send_response/end_response` | 上游支持方法只是必要条件。还要验证原始请求读取/帧化、keep-alive、UTF-8 字节长度、400/411/413 与 drain 行为；全部有等价证据后才迁移。S5/S6 活体是守卫，不把 grep 命中当成可直接切换 |

## 本轮计算边界（2026-10-31，0.5.0 未发布）

- `request timezone` 是 CalDAV 请求自带的时区，不等于 feed 的固定 VTIMEZONE 绑定。当前仅检查单一 VCALENDAR、VERSION、单一 VTIMEZONE/TZID、observance 必需字段唯一且 DTSTART 为 floating DATE-TIME 等结构/字段；不声称完整验证转换 RRULE。
- 该请求时区的转换尚未实现：任何相关 temporal 判断保守失败，REPORT 为 500；纯文本筛选仍可执行。非法已检查结构/字段为 403 `valid-calendar-data`。不能写成“时区已支持”或伪装成 `supported-filter`。
- 资源解析、时区、规则或预算导致无法可靠求值时，`ReportOutcome::EvaluationFailed` 经服务端返回 500；无 master 近似、无 partial multistatus。错误原因只用资源 href 和固定分类。
- 证据：`ical/caldav/evaluation_test.mbt` 和独立 `tools/s6_evaluation_acceptance.mbtx`。严格测试最终为 251/234/251/261，S5 24、S6 39；新 HTTP 求值驱动另计。

## 探活日志（历史与更正）

| 日期 | 依赖版本 | 证据与动作 |
|---|---|---|
| 2026-09-08 | async 0.21.2；moon 0.1.20260827 / moonc v0.10.11 | 早期 js 文件探针编译失败、native 为 PROBE_OK；方法枚举缺 WebDAV。原文把 `js_shim.mbt` 写成已存在，并计划在 ServerConnection Reader 上手解析，两者均不符合最终实现；保留调研结果，不保留错误切换配方 |
| S5 实现时 | async 0.21.2 | ServerConnection 帧化 reader 导致自解析失败，改用 TcpServer 裸连接；请求与响应均由 httpd 处理 |
| S20/S21 | async 0.21.2 / 0.22.4 | 核查客户端/socket 超时缺口；fetch 增加独立超时与本地守卫 |
| S33（2026-10-26） | async 0.22.5 / x 0.5.6 | 依赖升级全门闸与 S5/S6 通过；S29–S33 实际随 0.4.0 发布，早期“0.5.0 批次”是计划标签 |
| 2026-10-31 | 同上 | 未发布 0.5.0 收紧固定绑定、查询求值和 request timezone 边界；本次接缝更新不迁移上游接口。行为验证见上述守卫测试与独立 HTTP 驱动 |
