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
- `REPORT`：按**根元素**判定报告类型（S23 起——此前对整个 body 做大写子串嗅探，text-match 针或 href 里含另一报告名会误路由到 multiget）；`calendar-query`（filter 求值，见 [domain.md](domain.md)）与 `calendar-multiget`（只回被请求的 href；缺失的 href 回各自的 404 response 元素——RFC 4791 示例的逐 href 形状，S26 前是静默跳过）；根的 `DAV:prop` 选择同样被尊重（DTD 里可选，缺失视为 allprop，含 calendar-data）；comp-filter 的 `name` 与组件 kind **大小写不敏感**比较（S70——RFC 5545 的 ABNF 字串大小写不敏感，`name="vevent"` 此前静默选出空集）；未知报告类型 400；`CALDAV:expand` 等未实现的扩展元素被忽略（不展开，能力边界）。REPORT 同样作用于单个事件（S44）：资源集就是该对象本身，失败契约与集合 REPORT 相同（filter 不匹配则 207 但资源被排除）。
- `HEAD`：与 GET 同 framing——Content-Length 与 GET 完全一致、零 body 字节（RFC 7231 §4.1，S45），文件、集合、家目录与 principal 都有答案；Allow 头补列。S71 起**错误应答同样无体**（RFC 9110 §9.3.2 的 MUST NOT 只豁免"没有内容"，不豁免 4xx）：`reply()` 对一切 HEAD 请求自动去体，413/400/403/404 都不再向 HEAD 客户端写正文——此前只有成功路径传了 `head~` 标志，HEAD+超限体曾在 413 里收到文本拒绝体。
- `MKCALENDAR`：在 `/cal/<cal>/` 创建集合，201；已存在 405；**请求体属性（displayname、calendar-color）不落盘**，集合名即 displayname。
- **PUT 前置校验**（S53/S54 + S60 收窄，RFC 4791 §5.3.2 + Radicale 式门前拒绝）：请求体先过 `calendar_object_precondition`，两层各半。**存储形状层（S60）**：集合在 PROPFIND 里宣传 VEVENT-only 的 `supported-calendar-component-set`，门与之等宽——iCalendar `METHOD` 属性与多实体类型混合（§4.1 两处 MUST NOT）回 `CALDAV:valid-calendar-object-resource`；单一非 VEVENT 实体（VTODO/VJOURNAL/VFREEBUSY，可读与否、重复与否一律）回 `CALDAV:supported-calendar-component`（§5.3.2.1，sabre/dav 同口径）；VTIMEZONE 与内嵌 VALARM 按 §4.1 的豁免放行。**可读性层（S53/S54）**：必须能解析为 iCalendar、VEVENT 时间属性能按体自带 zone 表解析、RRULE 必须可展开（跑 `limit=1`，把序数 WEEKLY、COUNT+UNTIL 等查询期拒绝前移到写入期）、同 UID 系列的类型一致性镜像求值拒绝。失败回 403 + 对应前置条件元素，被拒体不落盘。求值容忍的形状（TEXT 里的 NUL、无 DTSTART 的 VEVENT）继续放行；VTODO 时长状态镜像已随收窄移除——VTODO 到不了门内。
- **UID 唯一性与写入互斥**（S61/S65，RFC 4791 §5.3.2.1 `CALDAV:no-uid-conflict`）：PUT 的 UID 已被同集合其他资源持有 → 403 并在 `(DAV:href)` 里命名持有者；覆写把资源换成不同 UID → 403 命名自身；无 UID 体（R8 容忍）不参与冲突；**作用域是单集合**——同 UID 在嵌套集合里照常存储。服务器无状态，唯一性索引按次写入重建：每个兄弟文件的首 UID 经内容行扫描（折叠展开、名字归一、4096 上限防二次方拼接）进 `Map`，扫描与落盘在 `put_lock` 信号量内同段执行——并发同 UID 双 URL 曾双双 201（TOCTOU 实测），串行后恰一赢家。门与 S62 的重复属性守卫都依赖这条扫描，S68 的原子写让扫描读到的兄弟文件永远是完整旧体或完整新体。
- **重复属性行的门界**（S62+S72）：§3.6.1 ABNF 里 `dtstamp`/`uid` 组、`dtstart`（"in any case"）与 `recurid` 是 **MUST NOT occur more than once**——重复即 `valid-calendar-data` 拒绝；`rrule` 只是 **SHOULD NOT**、`dtend`/`duration` 无 once 注记（只有二者并存的互斥 MUST）——重复宽容，取首条，与 dateutil/icalendar 口径一致（S62 曾把三者全按 MUST 拒，S72 按 JEV 0.948/0.816 纠偏）。
- 条件写入：`If-Match` 陈旧 → 412（PUT 与 DELETE 双路径），`If-None-Match: *` 重复创建 → 412。S64 起 `If-Match` 用**强比较**（RFC 7232 §3.1：`W/"etag"` 与未加引号的 token 永不匹配），`If-None-Match` 用弱比较（§3.2，弱拼写匹配）；S67 起 **GET/HEAD 评估 `If-None-Match`**（§3.2 规定恰这两个方法必须评估）——匹配回 304 + ETag 无体，陈旧标签回 200，此前条件轮询全量重下。同一条件头的多行重复按首行求值（不合并，定义行为）。
- `PUT /cal/` → 405 + `Allow`（S15 补上的方法缺失路径）。

## HTTP 请求层边界（`ical/httpd`）

手解析请求行/头/体（不走 `@async` 的 `read_request`，因其 `RequestMethod` 是封闭枚举），自带缓冲的有界读取（S14 的 `LineInput`）：

- chunked 请求体 → `411 Length Required`（chunked 扩展与 trailer 一并拒，不解析）；
- 单头行超 `MAX_LINE_BYTES`(64KB) → `400`；**真实上限是 64KB + 至多一个 4KB 读块**——检查发生在块边界，恰超 64KB 几个字节的行会滑过一个块间隙（S63 轮实测 65552 字节行通过、256KB 行正确拒绝）；头 > 100 行 → `400`；超限请求体 → `413`（拒绝前先排空连接，否则客户端未读上传的关闭 RST 会吞掉 413 响应——S17，有原始 socket 活体检查钉住；排空上限 10MB，仍在续传的更大上传会失去该拒绝响应——S28 文档化边界）；S63 起**畸形请求的 400 分支同样先排空**——超长请求行在上限触发时客户端仍在传，不排空则 RST 吞掉 400（70KB 方法 token 实测每次必现）；S71 起 411/413/400 对 HEAD 请求无体（错误变体携带请求行方法）；
- **`Expect: 100-continue` 被尊重**（S73，RFC 9110 §10.1.1）：头里带 `Expect: 100-continue` 且声明了非零体长时，读体前先写 `HTTP/1.1 100 Continue`——此前从不发 100、阻塞读体，等待 interim 响应的严格客户端无限挂起（原始 socket 实测 3 秒超时）；curl 的 1 秒兜底掩盖了它。`notify_continue` 回调由 `read_request` 在头解析后触发。
- **流水线请求缓冲**（S69）：`read_request` 返回"请求 + 上一次读块多出的字节"，连接循环把余量带回下一次调用——此前每次调用新建 `LineInput`，与头同块到达的第二个请求被读进缓冲后随缓冲丢弃（socket 位置已前移），两连发只答一个、客户端永久挂起（实测）。
- 非数字 `Content-Length` → `400`（不是 413）；
- 重复且**值不一致**的 `Content-Length` 头 → `400`（RFC 7230 §3.3.2 的走私类形状，S39；值相同的重复折叠为该值）；
- 方法只是 token，PROPFIND/REPORT/MKCALENDAR 天然可读；
- 响应由 `ical/httpd` 写入裸连接，头部经 StringBuilder 组装；不调用上游的 `ServerConnection::send_response`。

## 存储（`ical/store`，vdir 约定）

- **每事件一个 `.ics` 文件，每个集合一个子目录**——vdir 是跨工具互认的存储约定，可以直接用文件管理器检查 `caldata` 目录。
- **写入是原子替换**（S68）：PUT 先写点前缀临时文件（`.名字.tmp`）再 `rename(2)` 覆盖目标——`@fs.write_file` 默认 `CreateOrTruncate` 是原地截断，并发读者可能读到半写事件；点前缀让临时文件对 `list()`/`collections()`（`is_store_name` 拒点文件）与 HTTP 层（`check_name` 拒点开头名）都不可见，崩溃遗留零暴露。
- **ETag 是 FNV-1a 内容寻址**（`etag_of`）：同字节同 tag，改一字节即变；不是时间戳。
- **名字白名单**（`is_store_name`：字母数字 `._-` 且非点开头）拒绝非法名，防路径逃逸，错误是 `StoreError::BadName`；S31 起还全平台拒绝 Windows 保留设备名（`CON`/`PRN`/`AUX`/`NUL`/`COM1-9`/`LPT1-9`，带不带扩展名都算）——否则 vdir 拷到 Windows 机器就不可读，路由对这类名回普通 404。S40 起超过 255 字节（文件系统 NAME_MAX 下限）的名字也被白名单拒绝：路由层直接 404，不触文件系统——此前 8000 字符的合法字符集名会让 `@fs.exists` 的 OSError 以 500 逃逸。
- 集合 API：`collections` / `create_collection` / `collection` / `remove_collection`；`list` 只返回事件。

## 运行与操作

```bash
moon run cmd/serve --target native -- ./caldata 8437
```

- 日历家 `http://127.0.0.1:8437/cal/`；客户端发现从 `/.well-known/caldav` 进。
- 每个响应记一行 `METHOD path -> status`。REPORT 求值失败在 stderr 记录资源 href 与固定错误类别，不输出原始日历正文；其它 handler 错误沿用现有日志路径。日志放在日历数据目录外。
- **`@stdio` 写历史上经全局信号量串行化**（S51 引入，S76 移除）：访问日志、错误日志、路由 500 记录、求值失败记录四处曾共用一把 `Semaphore(1)`，规避上游并发 `@stdio` 写杀死进程的缺陷（20 行无项目代码的裸 TCP 服务器同样复现，已报上游 moonbitlang/async#732）。上游以 PR #735 "allow concurrent write over stdio channels" 修复后，规避锁于 2026-11-22 移除——移除后并发竞态套件（s7 的同 UID 恰一赢家与 8 并发异 UID）实测无回归。
- **无 TLS、无认证、无 ACL**——这是明确范围：暴露到不可信网络前必须放在带 TLS 和认证的反代后面（README 边界一节）。
- 服务器只用 native 目标（`@async/fs` 在 js 目标是空壳）。

## 验收脚本（`tools/`）

活体验收是起真实服务器后用 curl 打真实 TCP 请求：

- `python3 -I tools/s5_acceptance.py` — 24 项 HTTP 存储检查：PUT/GET/DELETE 往返、ETag 变化、411、边界头、413 中途上传可达等。
- `python3 -I tools/s6_acceptance.py` — 49 项活体 CalDAV：发现链、Depth 差分、`DAV:prop` 选择差分（R1+R2+R3）、filter 区间内外选择、403 前置条件、MKCALENDAR 生命周期、412 路径、裸 URL 301 差分、文件级 PROPFIND/REPORT 路由（S49 钉住，防 S48 型回归）等。两脚本自行启动、回收隔离服务；日志不可放进日历数据目录。
- `moon run tools/evalacceptance --target native -- http://127.0.0.1:8459 <server-log-path> <data-dir>` — 在单独启动的空数据目录服务上检查 RDATE、成功空集、预算失败、动态时区拒绝、错误分类及响应/日志隐私。**三个参数缺一不可**（第三个是服务器的数据目录，驱动要向它手工播种门不会存储的毒文件）。日志须在数据目录外；执行后停止该服务。此驱动单独记录，不并入计数。原 .mbtx 脚本形态因脚本模式的依赖缓存拉到与当前工具链 core 不兼容的 async 版本而无法编译（S75 起改为模块内主包，走 .mooncakes 的模块钉定版本）。

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
