# 安全审计日志(worktree audit/2026-11-19,2026-11-19)

在独立 worktree 对 70f470a 基线做安全团队式审查:逐条合规检查、攻击波实机测试、
确认即修。修复以 S61-S66 入库于本分支。探针存档 `/tmp/security-audit/`
(`uid_probe.py` / `compliance_probe.py` / `waves.py`)。

## 实证修复(六笔)

| 提交 | 缺陷 | 实测形态 | 修复 |
|---|---|---|---|
| S61 `7a0a90e` | RFC 4791 §5.3.2.1 no-uid-conflict 未执行 | 同集合重复 UID PUT 201 → 同一逻辑系列存两份、报告双答 | first_uid 内容行扫描(折叠展开/名字归一/4096 上限)+ uid_conflict 纯决策 + PUT 接线;s6 +6 钉 |
| S62 `6791d37` | RFC 5545 六个 "MUST NOT occur more than once" 属性重复被静默收下,`property()` 取首条丢弃其余;DTEND 值类型与 DTSTART 混搭;DATE 起点配 PT 形 DURATION | 探针 PUT 全部 201,语义取决于读取者选了哪一行 | event_from_component 单次出现守卫 + 值类型一致;门自动镜像 403 valid-calendar-data;+2/+2 测试 + 5 s6 钉 |
| S63 `bc799da` | Malformed 分支不排空:70KB 方法 token 触发行上限时 RST 吞掉 400(与 S28 在 413 上修的是同族问题,请求行路径漏了) | 原始 socket 每次必现 ConnectionReset | respond 后 drain 再关闭,镜像 411/413 的实测理由 |
| S64 `91155c4` | If-Match 用弱比较:`W/"etag"` 通过强校验 | PUT 弱标签 204(应 412) | 强/弱比较分离(7232 §3.1/§3.2);旧测试把违规钉成 Pass,已反转 |
| S65 `f07380d` | no-uid-conflict 的 TOCTOU:索引按写重建,两并发 PUT 都在对方写入前扫描 | 并发同 UID 双 URL → 双 201 | scan+store 同段进 `put_lock`,`errdefer` 保错误路径释放;复测 [201, 403] 恰一赢家 |
| S66 `f1b53a0` | XML 形状解析器把 CDATA 节跳到首个 `>`,内部标记进结构 | CDATA 包裹的 getetag 从选择中消失(注入改变语义) | CDATA 内容按字符数据落入元素 text(与 xml.mbt 头注明的原则一致);R1 差分钉死 |

## 攻击波与否证(勿重复攻击)

**波 1 HTTP 层(原始 socket)**:obs-fold 续行、TE+CL 并存(按 CL)、TE-only、
头值控制字符、冒号前空格、70KB 方法(S63 修复后 400 可达)、小写方法、绝对形式
目标、`OPTIONS *` ——全部良定义应答,无挂起无死亡。

**波 1b 条件形状**:弱标签(S64 修)、If-Match 列表含现标签 204 / 不含 412、
未加引号 token 不再匹配(S64)。

**波 2 XML**:DOCTYPE 内部子集、重复属性键、注释内标记不成结构、CDATA(S66 修)、
方括号过滤器名(坏体 403 valid-filter 是正确答案)。

**波 3 资源与并发**:1.2MB 折叠续行体 PUT 线性 0.02s(UID 扫描 4096 上限防二次方);
覆写重扫线性;并发同 UID 恰一赢家(S65 修);8 并发异 UID 全 201。

**既有否证清单沿用**:路径穿越、CL 饱和、INTERVAL=0/-1、BYMONTH=13、BYSETPOS=0、
COUNT=0、year-9999、BOM/DOCTYPE 双根、i;octet、negate、世纪闰年、负 DURATION、
数字 XML 实体宽容、双根自闭合(S42)、文件级路由(S43-S52)——见 PROGRESS 11-13 轮。

## 方法教训

- 上一轮被暂停的目标在 worktree 留了未提交的半成品修复;吸收前逐行 diff 评审,
  其中一处(s6 的 S60 canary UID)它自己已经修对——半成品也有可取的判断。
- 我自己的合规探针把"no VERSION 被拒"误报为缺陷,实为探针编号 bug 撞上 S61 的
  UID 变更覆写拒绝——服务器是对的。R1 纪律(判别器自己也要被验证)同样适用于探针。
- 弱比较/强比较的旧测试把违规行为钉成 Pass:测试钉的是"当时的行为",
  不自动等于"对的行为"——对照 RFC 原文逐字核验才算数。

## 第二轮(合并后主线,S67-S70)

换面攻击:条件 GET、存储名碰撞、分帧形态、filter 边缘、读-写并发。探针 `waves2.py`。

| 提交 | 缺陷 | 实测形态 | 修复 |
|---|---|---|---|
| S67 `21e3325` | RFC 7232 §3.2:GET/HEAD 必须评估 If-None-Match,曾完全不读该头 | 现标签 GET 得 200/145 字节,应 304 | GET/HEAD 走 check_preconditions,304+ETag 无体;R1 对(陈旧 200)入 s6 |
| S68 `b62ccee` | write_file 默认 CreateOrTruncate——原地截断,并发读者可读到半写事件(vdir 注释承诺的「旧或新」在系统调用层不成立) | 读 .repos 源码确证;162+186 次并发读未见,但窗口按构造存在 | dotfile 临时 + rename(2);点前缀使其对 list() 与 HTTP 层双不可见,崩溃遗留零暴露 |
| S69 `b1ee8e7` | LineInput 每请求重建,流水线第二请求被读进缓冲后丢弃(socket 位置已前移) | 两连发 GET 只答一个,客户端永久挂起 | read_request 返回余量缓冲,连接循环回灌;单测钉两请求一块 |
| S70 `a7873ef` | comp-filter name 与组件 kind 大小写敏感 | name="vevent" → 207 空集,事件全被静默漏掉 | 两侧统一大写;R1 对在单测,s6 钉实机 |

**否证补录**:MKCALENDAR 撞事件名 405、文件作集合下 PUT 404、行首 CRLF 容忍、HTTP/1.0 200、CL "+5" 400 / "0005" 按 5、chunked 扩展+trailer 整体 411(既定口径)、CALDAV:expand 未知元素 207 忽略(不展开=声明的能力边界)、multiget 指集合 404 propstat、curl -X HEAD 挂起是探针误用(S45 无体正确)。

**探针自身 bug 三连**:嵌套 XML 没闭合、不存在的 timeout 参数(百万次 TypeError 假异常)、s6 钉子变量复用(body 残留空体)——三次都是判别器先错,判别器也要过 R1。
