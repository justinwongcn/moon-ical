# 申报范围修复：交付核对

日期：2026-10-31。范围：修复静默日程错误、补测试、限定审核、先更新 OpenWiki 再同步其它文档；不提交 Git。本记录是本地工程审核，不是赛事复审结果。

## 需求与证据

| 要求 | 文件/执行证据 | 结果 |
|---|---|---|
| 借助 JEV | 本轮经用户授权最多6次，实际4次；请求响应保存在系统临时目录 jev-moonical/goal-*.json | 范围核对、修复证据与文档核对完成；不以概率代替规范或执行测试 |
| 修 RDATE 静默遗漏 | model/event.mbt、rrule/series.mbt；recurrence_dates_test、series_query_test、根 facade_recurrence_test | DATE/DATE-TIME合并、去重、EXDATE/改期/取消/后缀覆盖；PERIOD拒绝，原始树可往返 |
| 修动态时区误算 | model/zone.mbt、datetime.mbt；fixed_zone_test、facade_timezone_test | 动态/无效/未绑定地域TZID在引用时拒绝，可靠固定绑定可计算；不是完整DST实现 |
| 修查询假成功 | caldav/filter.mbt、caldav.mbt、cmd/serve/main.mbt；evaluation_test | 空系列不恢复master；未证明窗口阴性失败，不返回部分207 |
| 补测试 | 上述新增测试、rrule/review_regression_test与serialize_test | 支持/拒绝/空结果/单变量差分；YEARLY重复候选守卫曾红后绿 |
| 审核后修缺口 | 两组独立源码审核和当前树测试；六条库层、三条协议缺口闭环 | 包括COUNT前去重、预算、TZID遮蔽、时间域、timezone合法性、VTODO状态表、隐私失败类别 |
| HTTP验证 | S5 24/24、S6 39/39；tools/s6_evaluation_acceptance.mbtx真实curl驱动 | 新驱动含RDATE、预算、动态/固定、负移位、具体状态、完整href/空XML、响应和日志sentinel；隔离服务已回收 |
| 全目标验证 | moon check/test --target all --deny-warn | wasm251、wasm-gc234、js251、native261，全通过 |
| 格式/接口/构建 | moon fmt --check；moon info；native release build；git diff --check（cr-at-eol） | 通过；三包公开接口变化符合契约，MSVC上游EINVAL宏重定义警告仍存在 |
| 示例可运行 | README.mbt.md的mbt check四目标各1通过；moon run demo --target native | 通过；demo打印事件，不冒充展开验证 |
| 先OpenWiki后其它文档 | OpenWiki五篇和metadata先更新；随后双README、手册、接缝、CHANGELOG与本地申请素材 | 独立文档复核后修正范围/版本/旧数字/XML声明 |
| 消除文档AI套话 | README、OpenWiki和手册去“完整路径/任意来源/一行切换”等宽泛承诺，改成具体行为与限制 | 已复核；不声称可以由文风判断作者身份 |
| 申请一致性 | OSC2026-PROPOSAL.md | 旧不实稿改为范围核对素材，标明不得直接提交；最终稿须本人撰写 |
| 不提交Git | HEAD仍4fe115d39958d21fef5fc1ebd57d6b945ba67745；git diff --cached为空 | 未commit、push、publish，全部留工作区；原有用户未跟踪路径未处理 |

## 剩余边界

不实现PERIOD、完整IANA/DST、第三档RRULE、请求timezone转换和非VEVENT重复展开；相关时间计算明确失败。DAV:prop选择、TLS/认证/ACL等仍未实现。未重跑Thunderbird，未跑本轮性能基准，未提交官方复审。已有客户端CRUD只证明旧会话路径。

JEV有一次摘要RDATE判断未定，补具体执行断言后接受；复合范围问题给出与事实不符的判断，没有据此改变代码或扩大承诺。最终审核依据是规范、源码、具体测试和公开范围一致性。
