# moon-ical 快速上手

moon-ical（`justinwongcn/moon-ical`）是一个纯 MoonBit 的 [iCalendar (RFC 5545)](https://www.rfc-editor.org/rfc/rfc5545) 解析 / 重复事件展开库，外加一个最小化的 [CalDAV (RFC 4791)](https://www.rfc-editor.org/rfc/rfc4791) 服务器。它覆盖从 `.ics` 输入到类型化事件、重复展开、再到真实日历客户端可直连的 DAV 日历的完整路径。

- **当前状态**：0.3.0 已发布到 mooncakes；0.4.0 开发中（本仓库 HEAD 所在分支）。0.3.0 的主题是 `calendar-query` 真正求值 `CALDAV:filter` 与 `MKCALENDAR` 真正创建集合，以及 S11–S21 两轮复审修复波与依赖升级；0.4.0 自 S22（P3 收口批）起步；S23–S28/R13 复审波与 S29–S33 功能批（DURATION、MKCALENDAR body 解析、存储名加固、依赖例行升级）已落地。
- **测试规模**：全目标严格闸门全绿 —— wasm 212、wasm-gc 195、JavaScript 212、native 222；另有 24 项 S5 HTTP 存储与 39 项 S6 活体 CalDAV curl 验收。
- **互操作**：Thunderbird 155.0.1（Windows）已完成发现、读取、创建、修改、删除的真实联调；DAVx5 / Apple Calendar 是候选，未跑。

## 为什么有这个项目

mooncakes.io 生态检索 `caldav` / `webdav` / `webcal` 均无结果，五家竞品（mooncal、mooncalguard、rrule_lab、moon-schedule、moonrrule）全是离线计算库，输入都是调用方喂好的字符串。moon-ical 的差异化在端到端：网络取件 → 解析 → 重复展开 → 客户端可直连的服务端。完整立项证据链见 [docs/development.html](../docs/development.html) §01。

## 三分钟上手

```bash
moon version --all          # 先确认工具链（见 development 笔记的工具链一节）

# 1) 跑演示：读内嵌 fixture 打印事件清单，或给一个真实 .ics URL
moon run demo --target native
moon run demo --target native -- https://example.com/calendar.ics

# 2) 起 CalDAV 服务器（native 目标；数据目录 + 端口）
moon run cmd/serve --target native -- ./caldata 8437
#    日历家 = http://127.0.0.1:8437/cal/，发现链从 /.well-known/caldav 开始

# 3) 完整验证链（CI 同款）
moon check --target all --deny-warn
moon test  --target all --deny-warn
moon fmt --check
moon info                    # 然后检查 *.mbti 是否有非预期 diff

# 4) 活体验收（需要先起服务器）
python tools/s5_acceptance.py
python tools/s6_acceptance.py
```

库用法（根包门面，一次导入拿到完整工作流）：

```mbt nocheck
test {
  let events = @moon_ical.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:demo\r\n" +
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let occurrences = @moon_ical.expand_series(events)
  assert_eq(occurrences.length(), 3)
}
```

安装已发布版：`moon add justinwongcn/moon-ical@0.3.0`。

## 包地图

| 包 | 职责 | 关键入口 |
|---|---|---|
| `ical/text` | 物理行 → 逻辑行 → 内容行：折行展开（RFC 5545 §3.1）、引号参数、TEXT 转义/反转义 | `unfold`、`parse_content_line`、`unescape_value` |
| `ical/model` | 组件树（未知组件保留）、四态时间 `IcalDateTime`、时区表 `ZoneTable`、`Event` 类型化视图 | `parse_calendar`、`parse_events`、`build_zone_table` |
| `ical/rrule` | RRULE 解析（三档分界）与展开；系列级覆盖合并 | `parse_rule`、`expand`、`expand_series` |
| `ical/serialize` | 组件树 → 折行 `.ics` 文本（CRLF、75 octet、UTF-8 不劈开） | `serialize_components` |
| `ical/fetch` | URL 取件薄层（`@http.get` + 状态检查 + 超时兜底，上游客户端自身无超时） | `fetch_ics` |
| `ical/httpd` | HTTP/1.1 请求层：手解析请求行/头/体，方法只是 token（WebDAV 方法天然可用） | `read_request`、`respond` |
| `ical/caldav` | WebDAV/CalDAV 语义（纯函数包，无 IO）：发现、PROPFIND、REPORT、`DAV:prop` 选择、filter 求值、XML | `report`、`parse_filter`、`parse_propfind`、`collection_propfind` |
| `ical/store` | vdir 存储：每事件一个 `.ics`、目录即集合、内容寻址 ETag | `VdirStore`、`etag_of` |
| `cmd/serve` | 可执行入口：TCP accept、路由、把 httpd/caldav/store 组装起来 | `moon run cmd/serve` |
| `demo` | 演示入口：本地 fixture 或 URL → 事件清单 | `moon run demo` |
| 根包 `moon-ical.mbt` | 门面：`using` 重导出 parse / recurrence / serialize 工作流 | `parse_calendar`、`expand_series`、`serialize_component` |

依赖只有两个：`moonbitlang/async@0.22.5`（socket/fs/http/io）与 `moonbitlang/x@0.5.6`。XML 解析是自研的最小形状解析器（`ical/caldav/xml.mbt`），没有外部 XML 依赖。

## 文档索引

本文档（`openwiki/`）是导航与综合层，不重复已有文档：

- [architecture.md](architecture.md) — 两条栈（库管线 / 服务栈）与数据流、设计立场、上游接缝
- [domain.md](domain.md) — iCalendar 数据模型、四态时间、RRULE 分档语义、覆盖合并、filter 求值
- [server.md](server.md) — CalDAV 协议面、路由表、vdir 布局、运行操作与验收脚本
- [development.md](development.md) — 工具链硬规则、验证链、判别性验收规则 R1–R7、里程碑工作流

仓库自带的原始文档（权威细节以它们为准）：

- [README.md](../README.md) — 特性、边界清单、互操作矩阵
- [docs/development.html](../docs/development.html) — 内部开发手册：架构（§03）、里程碑（§04）、MoonBit 踩坑（§06）、验收有效性复盘与能力→证据矩阵（§11）
- `docs/PROGRESS.md` — **本地文件（gitignored），跨会话状态源**：开工先读，收工必更
- [CHANGELOG.md](../CHANGELOG.md)、[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)（RRULE 语料出处）、[docs/upstream-seams.md](../docs/upstream-seams.md)（上游接缝登记）

## 新会话从哪开始改代码

1. 先读 `docs/PROGRESS.md`（状态一览 + 下一步），再读本页与 [development.md](development.md)。
2. 改库层语义 → [domain.md](domain.md)；改服务器行为 → [server.md](server.md)。
3. 任何新能力的测试必须满足判别性规则 R1–R7（见 [development.md](development.md)），否则验收等于没验。
