# M0 Spike 结论（2026-09-08）

## 环境

| 项 | 值 |
|---|---|
| 开始时工具链 | moon 0.1.20260819 / moonc v0.10.9+6e6c44045 |
| **升级后工具链** | **moon 0.1.20260827 / moonc v0.10.11+6ff76a5f9（2026-08-28）** |
| 升级原因 | 旧版报 `Cannot inject the standard library moonbitlang/core: Cannot load the core file`：官方安装器的 core 预编译包（`~/.moon/lib/core`）缺失，且 mooncakes 索引（`mooncakes.io/git/index`）已重构为仅含 `user/` 命名空间，旧版解析器找不到 `moonbitlang/core` 条目。用官方 PowerShell 安装器重装（含 `cores/core-latest.zip` + `moon bundle`）后修复。 |
| 依赖 | `moonbitlang/async@0.21.2`（`moon add`，缓存在 `~/.moon/registry/cache`） |
| 新格式注意 | rr_moon_mod/rr_moon_pkg 下，包导入写在 `moon.pkg` 的 `import { "pkg" @alias }`，源文件里写 `import "..."` 会报 [3001]；`async fn main` 需要根包 `moonbitlang/async` 一并导入 |

## spike/http_get 实测（3 个 URL × 2 个目标）

| URL | js（Node 24 fetch） | native（Windows, IOCP） |
|---|---|---|
| https://www.moonbitlang.com（连通性对照） | code=200, 29718 bytes | code=200, 29718 bytes |
| calendar.google.com 中国节假日 basic.ics | FAILED: fetch failed | FAILED: OSError("@socket.Tcp::connect(): The semaphore timeout period has expired.") |
| www.calendarlabs.com/ical-calendar/ics/76/US_Holidays.ics（真实 .ics） | **code=200, 11675 bytes, is_ics=true** | **code=200, 11675 bytes, is_ics=true** |

## 结论

1. **js 目标可用**：`@http.get` 经 Node fetch 在 Windows 本机跑通，真实 .ics 拉取成功且被识别为 VCALENDAR。
2. **native 目标在 Windows 上完整可用**（HTTPS + 真实 .ics 端到端）。`moonbitlang/async` README 开头「only Linux/MacOS」的说法已过时，与其 Features 清单 `- [X] Windows support (IOCP)` 一致。**CLI 主目标定为 native**；js 保留为后备与浏览器场景。
3. **Google 日历 URL 在本网络不可达**（两个目标一致失败，属网络层问题而非客户端问题）。演示与 CI 一律使用本地 fixtures；在线演示选可直连的 .ics 源。
4. **持久化路线（S1）**：native 上 `moonbitlang/async/fs` 可用（见 probe）；js 上 `@async/fs` 仍是空壳（编译失败，见下）→ 维持 `PlatformStore` trait 方案：native→`@async/fs`，js→`ical/store/js_shim.mbt`（node:fs extern 兜底），web→localStorage。
5. 待 W1 处理：`async fn main` 的 `unused_async` 警告在 js 目标下出现（fs 存根使 async 无意义），属预期，js 分支主要走 js_shim/localStorage，不阻塞。

## probe/js_fs_probe（S1 探针基线）

- `moon run probe/js_fs_probe --target native` → **PROBE_OK content=moon-ical probe**（写/读/删均正常）
- `moon run probe/js_fs_probe --target js` → **编译失败**（`@fs.write_file` 在 js 下不可用），符合 `src/fs/unimplemented.mbt` 的 `#cfg(not(target="native"))` 声明。该失败即 S1 的基线状态；探针转绿之日即执行切换配方之时。
