# moon-ical 项目申报书

**项目名称**：moon-ical：纯 MoonBit iCalendar 库与 CalDAV 服务器  
**参赛者**：Justin Wong  
**GitHub 仓库**：https://github.com/justinwongcn/moon-ical  
**项目方向**：MoonBit 日历协议基础设施 / 应用生态

moon-ical 面向需要读取日历订阅、计算重复事件或接入桌面与移动日历客户端的 MoonBit 开发者。项目实现 RFC 5545 iCalendar 的内容行、组件树、日期时间、序列化与 RRULE 展开，并在此之上提供基于 `moonbitlang/async` 原生 socket 的最小 CalDAV 服务端。mooncakes.io 已有的同类包主要停留在离线计算层；本项目补齐“网络取件—解析—展开—写回—服务—客户端发现”的端到端链路。

核心功能包括：保留未知属性的 iCalendar 组件树；UTC、浮动、TZID、全天四态日期时间；固定偏移及 feed 内嵌 VTIMEZONE；DAILY/WEEKLY/MONTHLY/YEARLY、序数 BYDAY、正负 BYMONTHDAY、BYSETPOS、WKST；EXDATE 与 RECURRENCE-ID 改期、取消、THISANDFUTURE 合并；75-octet 安全折行序列化；vdir 一事件一文件存储和内容寻址 ETag；PROPFIND、calendar-query、calendar-multiget、MKCALENDAR、well-known 发现链及条件写入。

工程验证以 RFC 5545 附录 A 和 graham/rrule 测试语料为参照，核心结果使用断言测试；HTTP/CalDAV 另有真实 socket + curl 集成序列。CI 覆盖所有受支持目标、严格警告、格式、接口文件和 native 服务端构建。项目提供命令行 demo、服务器启动说明、协议边界与客户端互操作矩阵。

项目为独立 MoonBit 实现，不移植其他项目代码。设计上参考 RFC 5545、RFC 4791、vdir 约定与 Radicale 的最小互操作思路；graham/rrule 仅作为公开行为对拍语料来源，相关来源和范围在仓库调研文档中说明。项目采用 Apache-2.0 许可证。

首版明确不包含完整 IANA tzdb、CalDAV 调度/ACL/TLS 和 CalDAV 客户端；命名时区采用内嵌 VTIMEZONE 优先、常见固定偏移兜底。目标是提供边界清晰、可测试、可发布到 mooncakes.io、可由真实日历客户端直连的 MoonBit 日历基础设施。
