# CalDAV 服务器与运行操作

本页覆盖服务端从 socket 到磁盘的全部行为，以及怎么运行、怎么验收。协议语义层的细节（filter 求值、错误契约）在 [domain.md](domain.md)。

## 路由面（`cmd/serve/main.mbt` 的 `target_of`）

路由只看路径（query string 在 S14 起被剥离，不再 404）；**结尾斜杠区分集合与事件**：

| 目标 | 行为 |
|---|---|
| `/.well-known/caldav` | 301 → `/cal/`（发现链入口） |
| `/principals/default/` | 最小 principal：仅 `PROPFIND` / `OPTIONS` / `HEAD`（S47），Allow 收窄到这三者 |
| `/cal/` | 日历家 = **默认集合**；`PROPFIND`（Depth 0/1）、`REPORT`、`GET`/`HEAD`、`OPTIONS`；`MKCALENDAR` 在此被拒（405） |
| `/cal/<cal>/` | MKCALENDAR 创建的嵌套集合：`PROPFIND` / `REPORT` / `GET` / `HEAD` / `DELETE`（非空删除 409） |
| `/cal/<name>.ics`、`/cal/<cal>/<event>.ics` | 单个事件：`GET` / `HEAD` / `PUT` / `DELETE` / `PROPFIND` / `REPORT`（S43-S45；OPTIONS 的 Allow 也随之收窄，不再宣传 MKCALENDAR——S52） |
| `/cal/<cal>`、`/cal`（无斜杠） | 301 规范化到带斜杠形式（S13 集合 / S19 家目录；此前 Windows 上 500、POSIX 上静默清空集合） |

`/cal/` 兼作日历家与默认集合是 S10 的刻意兼容取舍：新建集合并排放在 `/cal/<cal>/`，已有客户端指到 `/cal/` 继续工作。

## 方法与条件写入

- `PROPFIND`：Depth 0 只回自身、Depth 1 加子项；请求体里的 `DAV:prop` 选择**被尊重**（S34，`parse_propfind`）：按列出的属性裁剪，无答案的属性进 404 propstat（RFC 4918 §9.1.2），空体 ≡ allprop；畸形体（非 XML、根不是 `propfind`、缺选择子元素）回 400；`calendar-data` 不是 WebDAV 属性（RFC 4791 §9.6），PROPFIND 里显式请求它也是 404。PROPFIND 也作用于单个事件资源（S43，RFC 4918 §9.1 让它适用任意资源）：回一条 multistatus 条目，`calendar-data` 同样进 404 propstat——这是 etag 探测型客户端（Thunderbird、DAVx5）同步时会发的形状，此前一律 405。
- `REPORT`：按**根元素**判定报告类型（S23 起——此前对整个 body 做大写子串嗅探，text-match 针或 href 里含另一报告名会误路由到 multiget）；`calendar-query`（filter 求值，见 [domain.md](domain.md)）与 `calendar-multiget`（只回被请求的 href；缺失的 href 回各自的 404 response 元素——RFC 4791 示例的逐 href 形状，S26 前是静默跳过）；根的 `DAV:prop` 选择同样被尊重（DTD 里可选，缺失视为 allprop，含 calendar-data）；未知报告类型 400。REPORT 同样作用于单个事件（S44）：资源集就是该对象本身，失败契约与集合 REPORT 相同（filter 不匹配则 207 但资源被排除）。
- `HEAD`：与 GET 同 framing——Content-Length 与 GET 完全一致、零 body 字节（RFC 7231 §4.1，S45），文件、集合、家目录与 principal 都有答案；Allow 头补列。
- `MKCALENDAR`：在 `/cal/<cal>/` 创建集合，201；已存在 405；**请求体属性（displayname、calendar-color）不落盘**，集合名即 displayname。
- **PUT 前置校验**（S53/S54 + S60 收窄，RFC 4791 §5.3.2 + Radicale 式门前拒绝）：请求体先过 `calendar_object_precondition`，两层各半。**存储形状层（S60）**：集合在 PROPFIND 里宣传 VEVENT-only 的 `supported-calendar-component-set`，门与之等宽——iCalendar `METHOD` 属性与多实体类型混合（§4.1 两处 MUST NOT）回 `CALDAV:valid-calendar-object-resource`；单一非 VEVENT 实体（VTODO/VJOURNAL/VFREEBUSY，可读与否、重复与否一律）回 `CALDAV:supported-calendar-component`（§5.3.2.1，sabre/dav 同口径）；VTIMEZONE 与内嵌 VALARM 按 §4.1 的豁免放行。**可读性层（S53/S54）**：必须能解析为 iCalendar、VEVENT 时间属性能按体自带 zone 表解析、RRULE 必须可展开（跑 `limit=1`，把序数 WEEKLY、COUNT+UNTIL 等查询期拒绝前移到写入期）、同 UID 系列的类型一致性镜像求值拒绝。失败回 403 + 对应前置条件元素，被拒体不落盘。求值容忍的形状（TEXT 里的 NUL、无 DTSTART 的 VEVENT）继续放行；VTODO 时长状态镜像已随收窄移除——VTODO 到不了门内。
- 条件写入：`If-Match` 陈旧 → 412（PUT 与 DELETE 双路径），`If-None-Match: *` 重复创建 → 412。
- `PUT /cal/` → 405 + `Allow`（S15 补上的方法缺失路径）。

## HTTP 请求层边界（`ical/httpd`）

手解析请求行/头/体（不走 `@async` 的 `read_request`，因其 `RequestMethod` 是封闭枚举），自带缓冲的有界读取（S14 的 `LineInput`）：

- chunked 请求体 → `411 Length Required`；
- 单头行 > 64KB 或头 > 100 行 → `400`；超限请求体 → `413`（拒绝前先排空连接，否则客户端未读上传的关闭 RST 会吞掉 413 响应——S17，有原始 socket 活体检查钉住；排空上限 10MB，仍在续传的更大上传会失去该拒绝响应——S28 文档化边界）；
- 非数字 `Content-Length` → `400`（不是 413）；
- 重复且**值不一致**的 `Content-Length` 头 → `400`（RFC 7230 §3.3.2 的走私类形状，S39；值相同的重复折叠为该值）；
- 方法只是 token，PROPFIND/REPORT/MKCALENDAR 天然可读；
- 响应由 `ical/httpd` 写入裸连接，头部经 StringBuilder 组装；不调用上游的 `ServerConnection::send_response`。

## 存储（`ical/store`，vdir 约定）

- **每事件一个 `.ics` 文件，每个集合一个子目录**——vdir 是跨工具互认的存储约定，可以直接用文件管理器检查 `caldata` 目录。
- **ETag 是 FNV-1a 内容寻址**（`etag_of`）：同字节同 tag，改一字节即变；不是时间戳。
- **名字白名单**（`is_store_name`：字母数字 `._-` 且非点开头）拒绝非法名，防路径逃逸，错误是 `StoreError::BadName`；S31 起还全平台拒绝 Windows 保留设备名（`CON`/`PRN`/`AUX`/`NUL`/`COM1-9`/`LPT1-9`，带不带扩展名都算）——否则 vdir 拷到 Windows 机器就不可读，路由对这类名回普通 404。S40 起超过 255 字节（文件系统 NAME_MAX 下限）的名字也被白名单拒绝：路由层直接 404，不触文件系统——此前 8000 字符的合法字符集名会让 `@fs.exists` 的 OSError 以 500 逃逸。
- 集合 API：`collections` / `create_collection` / `collection` / `remove_collection`；`list` 只返回事件。

## 运行与操作

```bash
moon run cmd/serve --target native -- ./caldata 8437
```

- 日历家 `http://127.0.0.1:8437/cal/`；客户端发现从 `/.well-known/caldav` 进。
- 每个响应记一行 `METHOD path -> status`。REPORT 求值失败在 stderr 记录资源 href 与固定错误类别，不输出原始日历正文；其它 handler 错误沿用现有日志路径。日志放在日历数据目录外。
- **所有 `@stdio` 写经全局信号量串行化**（S51）：访问日志、错误日志、路由 500 记录、求值失败记录四处共用一把 `Semaphore(1)`。根因在上游——`moonbitlang/async@0.22.5` 的并发 `@stdio` 写会在第二个并发连接上杀死整个进程（20 行无项目代码的裸 TCP 服务器同样复现，已报上游 moonbitlang/async#732）；访问日志自 S24 起让每个请求都成了写者，Thunderbird 默认开多条连接，锁是必需的。
- **无 TLS、无认证、无 ACL**——这是明确范围：暴露到不可信网络前必须放在带 TLS 和认证的反代后面（README 边界一节）。
- 服务器只用 native 目标（`@async/fs` 在 js 目标是空壳）。

## 验收脚本（`tools/`）

活体验收是起真实服务器后用 curl 打真实 TCP 请求：

- `python3 -I tools/s5_acceptance.py` — 24 项 HTTP 存储检查：PUT/GET/DELETE 往返、ETag 变化、411、边界头、413 中途上传可达等。
- `python3 -I tools/s6_acceptance.py` — 49 项活体 CalDAV：发现链、Depth 差分、`DAV:prop` 选择差分（R1+R2+R3）、filter 区间内外选择、403 前置条件、MKCALENDAR 生命周期、412 路径、裸 URL 301 差分、文件级 PROPFIND/REPORT 路由（S49 钉住，防 S48 型回归）等。两脚本自行启动、回收隔离服务；日志不可放进日历数据目录。
- `moon run tools/s6_evaluation_acceptance.mbtx http://127.0.0.1:8459 <server-log-path>` — 在单独启动的空数据目录服务上检查 RDATE、成功空集、预算失败、动态时区拒绝、错误分类及响应/日志隐私。日志须在数据目录外；执行后停止该服务。此驱动单独记录，不并入原有 73 项计数。

2026-11-15 复跑三套活体验收全绿（S5 24/24、S6 49/49、求值驱动通过）。互操作现状以 [README.md](../README.md) 的矩阵为准：curl 73/73 活体通过；Thunderbird 155.0.1 的发现/CRUD 是此前的会话证据，没有在并发连接（S51 之后）与 PUT 前置校验（S53 之后）下重新联调；DAVx5 / Apple Calendar 未跑。**互操作通过不是协议完整的证据**（R6）——客户端会话只证明它使用的路径，Thunderbird 恰好绕开了 S10 的两条缺陷。

## 服务端已知边界速查

- DAV 响应正文（PROPFIND/REPORT 的 multistatus）对存储的控制字符保持 XML 1.0 合法：除 TAB/LF/CR 外 <0x20 的控制字符替换为 U+FFFD（S38，`xml_escape`）——文档对同步客户端可解析、毒点可见；GET 仍回存储原字节，ETag 一致性不变；
- `PROPFIND`/`REPORT` 的 `DAV:prop` 选择已实现（S34，`parse_propfind`）；剩余的边角：按 local name 匹配（命名空间不敏感）、404 回显带 `DAV:` 前缀、`calendar-data` 的子元素（`expand` 等）不支持而回全量、`allprop` 的 `include` 读为无额外约束；
- PUT 门与数据层边界并存：绕过 PUT 直接写进 vdir 的文件不做前置校验，一条不可读资源仍会让集合的 calendar-query 以 500 失败（fail-closed 契约，错误类别带毒 href 便于清除）；
- `MKCALENDAR` body 属性已类型化解析（caldav 的 `parse_mkcalendar`，S30），但服务端仍不落盘——是否持久化是嵌入方的部署决策；
- `sync-collection` / CTag 不支持（400）；
- 当前 0.5.0 支持 RDATE DATE/DATE-TIME；PERIOD、动态时区、未绑定地域 TZID 和未支持的重复规则在相关时间求值时失败；
- `calendar-query` 无法证明匹配窗口完整时返回 500，不返回主事件近似或部分 207；成功空集保持为空，错误正文只含安全类别和资源 href；
- 请求 timezone 的转换、重复 VTODO 等非 VEVENT 重复计算尚未支持，相关时间查询失败。非法请求 timezone 已检查的字段/结构返回 403 `valid-calendar-data`；
- `VALARM` 的 time-range 回 `403 supported-filter`；
- 请求体必须带 `Content-Length`。

改服务端行为时的最低验收：对应活体脚本全绿 + 新路径有 R1–R3 级判别用例（一对只差输入的请求、空结果、具体状态码 + 具体错误元素）。
