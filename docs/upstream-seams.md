# 上游接缝与切换预案（活文档）

> 原则：业务代码永不 import 兜底实现，只 import trait。
> 每个临时实现文件头标注 `// UPSTREAM-GAP: ...`；probe 转绿 = 上游已补齐 = 立即执行切换配方。
> 排期原则：上游有明确 issue/PR 在飞的才进候选清单；只挂在 README 未勾选项、无任何追踪条目的不进排期，纯靠 probe 发现。

## 接缝登记

| # | 能力 | 上游现状（核实日期 2026-09-08） | 临时实现 | probe | 切换配方 |
|---|---|---|---|---|---|
| S1 | 本地文件持久化 | `moonbitlang/async/fs` native 可用（Windows 实测 PROBE_OK）；js 下为 `#cfg(not(target="native"))` 空壳（已读 `src/fs/unimplemented.mbt` 原文）；js 侧 Node IO 原语仅 README 一条未勾选项，无 open issue/PR | `ical/store/js_shim.mbt`（node:fs extern，约 30 行）；web 走 localStorage | `moon run probe/js_fs_probe --target js`（当前预期失败） | 探针转绿后：删 `ical/store/js_shim.mbt`，`ical/store/native.mbt` 放开 js 分支，trait 与业务代码零改动 |
| S2 | IANA 时区（named zone + DST 历史规则） | `moonbitlang/x/time` 仅 fixed_zone（`ZoneOffset.dst` 是单点布尔）；mooncakes 未检索到 tzdb 包 | `ical/model/zone.mbt`：`ZoneResolver` trait = UTC / floating（委托 kawaz/timespec）/ 固定偏移表 / feed 内嵌 VTIMEZONE 固定段 | 无自动探针；里程碑探活时人工检索 mooncakes「timezone/tzdb」 | 出现可用 tzdb 包后：新增实现文件 + 改一处默认绑定 |
| S3 | HTTP 抓取 | `moonbitlang/async/http` native + js 已可用（M0 实测） | 无兜底；保留 `Fetcher` 抽象（web 用浏览器 fetch） | 无 | 在飞的 wasm-gc HTTP 支持落地后：增开 `--target wasm-gc`，CLI 变纯 wasm 单文件 |
| S4 | 异步运行时稳定性 | README 声明 experimental；有 issue 讨论 async 并入 moonbitlang/core 的 API 变更 | 无兜底 | `moon outdated` | API 触点收敛在 `ical/store/backend.mbt` 与 `ical/sync/fetch.mbt` |
| S5 | 系统本地时区 | `x/time` 要求自行 FFI；社区包 `kawaz/timespec@0.2.4` 的 `local_tz_offset()` 覆盖 native(C FFI)/JS(Date)/WASM(返回 Utc) | 用 kawaz/timespec | 无 | `x/time`/core 提供官方 local zone 后替换 `zone.mbt` 中唯一调用点 |

## 探活日志

| 日期 | 依赖版本 | probe 结果 | 动作 |
|---|---|---|---|
| 2026-09-08 | async@0.21.2；工具链 0.1.20260827 / moonc v0.10.11（M0 当日升级） | S1: js=编译失败（符合预期基线）、native=PROBE_OK | 无需切换；`js_shim.mbt` 维持 |
