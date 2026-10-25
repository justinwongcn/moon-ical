# CalDAV 服务器与运行操作

本页覆盖服务端从 socket 到磁盘的全部行为，以及怎么运行、怎么验收。协议语义层的细节（filter 求值、错误契约）在 [domain.md](domain.md)。

## 路由面（`cmd/serve/main.mbt` 的 `target_of`）

路由只看路径（query string 在 S14 起被剥离，不再 404）；**结尾斜杠区分集合与事件**：

| 目标 | 行为 |
|---|---|
| `/.well-known/caldav` | 301 → `/cal/`（发现链入口） |
| `/principals/default/` | 最小 principal：仅 `PROPFIND` / `OPTIONS` |
| `/cal/` | 日历家 = **默认集合**；`PROPFIND`（Depth 0/1）、`REPORT`、`OPTIONS`；`MKCALENDAR` 在此被拒（405） |
| `/cal/<cal>/` | MKCALENDAR 创建的嵌套集合：`PROPFIND` / `REPORT` / `GET` / `DELETE`（非空删除 409） |
| `/cal/<name>.ics`、`/cal/<cal>/<event>.ics` | 单个事件：`GET` / `PUT` / `DELETE` |
| `/cal/<cal>`、`/cal`（无斜杠） | 301 规范化到带斜杠形式（S13 集合 / S19 家目录；此前 Windows 上 500、POSIX 上静默清空集合） |

`/cal/` 兼作日历家与默认集合是 S10 的刻意兼容取舍：新建集合并排放在 `/cal/<cal>/`，已有客户端指到 `/cal/` 继续工作。

## 方法与条件写入

- `PROPFIND`：Depth 0 只回自身、Depth 1 加子项；**忽略请求的 `DAV:prop` 集**，固定返回 resourcetype / getcontenttype / getetag / calendar-data（声明过的边界）。
- `REPORT`：按**根元素**判定报告类型（S23 起——此前对整个 body 做大写子串嗅探，text-match 针或 href 里含另一报告名会误路由到 multiget）；`calendar-query`（filter 求值，见 [domain.md](domain.md)）与 `calendar-multiget`（只回被请求的 href；缺失的 href 回各自的 404 response 元素——RFC 4791 示例的逐 href 形状，S26 前是静默跳过）；未知报告类型 400。
- `MKCALENDAR`：在 `/cal/<cal>/` 创建集合，201；已存在 405；**请求体属性（displayname、calendar-color）不落盘**，集合名即 displayname。
- 条件写入：`If-Match` 陈旧 → 412（PUT 与 DELETE 双路径），`If-None-Match: *` 重复创建 → 412。
- `PUT /cal/` → 405 + `Allow`（S15 补上的方法缺失路径）。

## HTTP 请求层边界（`ical/httpd`）

手解析请求行/头/体（不走 `@async` 的 `read_request`，因其 `RequestMethod` 是封闭枚举），自带缓冲的有界读取（S14 的 `LineInput`）：

- chunked 请求体 → `411 Length Required`；
- 单头行 > 64KB 或头 > 100 行 → `400`；超限请求体 → `413`（拒绝前先排空连接，否则客户端未读上传的关闭 RST 会吞掉 413 响应——S17，有原始 socket 活体检查钉住；排空上限 10MB，仍在续传的更大上传会失去该拒绝响应——S28 文档化边界）；
- 非数字 `Content-Length` → `400`（不是 413）；
- 方法只是 token，PROPFIND/REPORT/MKCALENDAR 天然可读；
- 响应复用 `@async` 的 `send_response`，内容经 StringBuilder 缓冲（R11 修掉 O(n²) 拼接）。

## 存储（`ical/store`，vdir 约定）

- **每事件一个 `.ics` 文件，每个集合一个子目录**——vdir 是跨工具互认的存储约定，可以直接用文件管理器检查 `caldata` 目录。
- **ETag 是 FNV-1a 内容寻址**（`etag_of`）：同字节同 tag，改一字节即变；不是时间戳。
- **名字白名单**（`is_store_name`：字母数字 `._-` 且非点开头）拒绝非法名，防路径逃逸，错误是 `StoreError::BadName`。
- 集合 API：`collections` / `create_collection` / `collection` / `remove_collection`；`list` 只返回事件。

## 运行与操作

```bash
moon run cmd/serve --target native -- ./caldata 8437
```

- 日历家 `http://127.0.0.1:8437/cal/`；客户端发现从 `/.well-known/caldav` 进。
- 每个已响应请求记一行 `METHOD path -> status` 访问日志；请求层以下的失败在 500 前把错误打到 stderr（S24——此前 500 无任何痕迹）。刻意就这两路输出：无级别、无配置。
- **无 TLS、无认证、无 ACL**——这是明确范围：暴露到不可信网络前必须放在带 TLS 和认证的反代后面（README 边界一节）。
- 服务器只用 native 目标（`@async/fs` 在 js 目标是空壳）。

## 验收脚本（`tools/`）

活体验收是起真实服务器后用 curl 打真实 TCP 请求：

- `tools/s5_acceptance.py` — 23 项 HTTP 存储检查：PUT/GET/DELETE 往返、ETag 变化、411、边界头、413 中途上传可达等。
- `tools/s6_acceptance.py` — 36 项活体 CalDAV：发现链、Depth 差分、filter 区间内外选择（R1+R2）、403 前置条件、MKCALENDAR 生命周期、412 路径、裸 URL 301 差分等。

互操作现状以 [README.md](../README.md) 的矩阵为准：curl 59/59 活体通过；Thunderbird 155.0.1 完整 CRUD 已验；DAVx5 / Apple Calendar 未跑。**互操作通过不是协议完整的证据**（R6）——Thunderbird 恰好绕开了 S10 的两条缺陷。

## 服务端已知边界速查

- `PROPFIND`/`REPORT` 忽略 `DAV:prop` 选择，固定属性集；
- `MKCALENDAR` body 属性不落盘；
- `sync-collection` / CTag 不支持（400）；
- `DURATION` 不解析，组件结束只认 `DTEND`/`DUE`；
- `VALARM` 的 time-range 回 `403 supported-filter`；
- 请求体必须带 `Content-Length`。

改服务端行为时的最低验收：对应活体脚本全绿 + 新路径有 R1–R3 级判别用例（一对只差输入的请求、空结果、具体状态码 + 具体错误元素）。
