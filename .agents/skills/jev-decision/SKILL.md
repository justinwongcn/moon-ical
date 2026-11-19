---
name: jev-decision
license: MIT
description: >
  Jev (TokenRhythm) integration craft for System One models (sometimes called Decision Models),
  which answer typed questions about text, images, and application state with probabilities. Use
  when building, reviewing, or debugging code that calls Jev (TokenRhythm); when writing
  its questions or state; when replacing an LLM prompt-and-parse step, keyword matching, or a
  brittle heuristic with a typed question; or when brainstorming where programmable common sense
  fits in an app.
---

# Build with Jev (TokenRhythm)

**Jev**，一个 **System One（决策）模型**，针对应用提供的 state 回答有类型的
问题。State 是请求随带的文本、图片和应用数据。Jev 支持三种题型：Choice（从选项中做选择）、
Noul（一个陈述成立的概率）、Score（在你描述的等级上打分）。每个答案都以带概率的类型化数据返回，
供代码使用；注意概率和 confidence 不能当作经校验的正确率，"是/否"等业务阈值由调用方决定。

Jev 是结构化决策模型，不是聊天模型：只能通过下文的供应商 API 调用，不提供
`/v1/chat/completions` 或网页聊天 Playground。

The rest of this skill is guidance: patterns that tend to produce reliable integrations. None of it
is absolute. Models change, applications differ, and edge cases exist. When a situation calls for
something else, test the alternative and use your judgment.

## Judgments from Jev, decisions in code

Integrations tend to work best when Jev makes the judgments and code decides what to do with
them. Think of each decision as a **truth table**. Jev supplies the inputs, such as "Does the
customer sound frustrated?" or "Which product is the message about?". Code holds the logic that
maps those inputs to an action.

A question that asks Jev to make the decision, such as "Should this ticket be escalated?" or "What
should the agent do next?", usually means the question is at the wrong layer. Instead, break the
decision into the judgments it depends on, and write the decision itself in code, where it's
visible and testable. Writing out the table often shows gaps in the business logic too. A
combination of judgments with no defined outcome is a design question about the system, and it is
best settled in code.

## 调用通道（本地 facade 与 TokenRhythm 云端）

Jev 引擎固定为 `NeoHorse-Jev-4B`，有两个等价调用通道，由 `.env`（或环境变量）里的三个键选择：

- **本地 facade（当前默认）**：`TOKENRHYTHM_API_BASE=http://127.0.0.1:11434`、
  `TOKENRHYTHM_API_KEY=magpie`、`TOKENRHYTHM_MODEL=jev/NeoHorse-Jev-4B`。Magpie 网关把
  `jev/` 前缀路由到同一 NeoHorse-Jev-4B 引擎，只暴露 System One 兼容路径
  `POST /v1/systemone`（`decide.mjs` 在自定义 BASE 下自动默认走它）。判定概率与云端一致。
- **TokenRhythm 云端**：`TOKENRHYTHM_API_BASE=https://tokenrhythm.studio`（或不设）+
  `sk_` 密钥、模型 `NeoHorse-Jev-4B`。端点 `POST /v1/decision` 与
  `POST /v1/systemone`（同一请求体，返回可另含 `usage`、`extensions`）；是否可用与价格以
  平台模型目录为准。2026-11-19 起云端密钥过期（401），`.env` 里留有注释行，续期后改回。

### 接口与鉴权

- 鉴权：`Authorization: Bearer <令牌>`（云端 `sk_` 密钥；本地 facade 固定 `magpie`），请求头
  `Content-Type: application/json`；两个通道均为**非流式 JSON**。
- `decide.mjs` 从环境变量或 `.env` 读 `TOKENRHYTHM_API_KEY`（Bearer 令牌）、
  `TOKENRHYTHM_API_BASE`（服务根址）、`TOKENRHYTHM_MODEL`（设置后覆盖请求体的 model 字段）。

### 请求体

```json
{
  "model": "NeoHorse-Jev-4B",
  "state": "路口信号灯为红色，前方有行人。",
  "questions": {
    "stop": {
      "type": "noul",
      "instructions": "现在是否应停车？"
    }
  }
}
```

- `state` 是背景或待判断内容，建议用字符串，也可传结构化 JSON。
- `questions` 的键由调用方自行定义，读取答案时按相同的问题 ID 查找。

### 题型

| 题型   | criteria                                     | 结果                                     |
| ------ | -------------------------------------------- | ---------------------------------------- |
| choice | 选项名到描述的对象，1～255 项；保持选项顺序  | `choice` 和 `probabilities`，可含 `confidence` |
| noul   | 可省略；也可提供 false/true 两个描述         | `noul` 成立概率（0～1）                  |
| score  | 从低到高的等级描述数组，2～10 档             | `score` 为从 0 编号的等级期望，可含 `confidence` |

### 限制

- 纯文本每次 1～16 题，JSON 请求体不超过 1 MiB。
- 图片放在顶层 `image` 字段，格式为一张 PNG 的 Base64 Data URL；带图时**只能有一道题**，完整
  JSON 不超过 8 MiB，移除 `image` 后仍不超过 1 MiB。
- 上游还有编码后的输入 token 上限，超出返回 422。不会静默截断输入。

### Token 口径

- `/v1/decision` 优先记录打包输入 `input_tokens`，未提供时使用
  `input_details.expanded_tokens`（多题展开输入）；两者不相加。
- `/v1/systemone` 记录 `usage.input_tokens` 和 `usage.output_tokens`，后者是答案序列化长度，
  不代表生成 Token。
- 上游未上报的 Token 会在调用明细中标为未知。

### 错误与重试

平台错误统一返回 `code`、`message`、`traceId`。常见状态：

| 状态码      | 含义                       |
| ----------- | -------------------------- |
| 401         | 平台密钥无效               |
| 403         | 未获灰度权限               |
| 413         | 请求体超限                 |
| 422         | 参数或上游输入限制不满足   |
| 429         | 容量限流                   |
| 502/503/504 | 上游或依赖故障             |

排障时保留 `traceId`；已发送的超时请求不要无条件重试。成功时直接返回含 `model`、`answers`
的结构化 JSON，不套聊天消息格式。

### 本地调用脚本与密钥

`scripts/decide.mjs` 是零依赖的 Node 脚本，封装了读取密钥、补全默认 `model`、调用接口、
把 `code`/`message`/`traceId` 透出到 stderr 的全过程，构建和测试问题时优先用它发起请求：

```bash
# 请求体从 stdin 读入（model 可省略，脚本默认补 NeoHorse-Jev-4B）
echo '{"state":"路口信号灯为红色，前方有行人。","questions":{"stop":{"type":"noul","instructions":"现在是否应停车？"}}}' \
  | node scripts/decide.mjs
# 或从文件读入；--endpoint systemone 切换 System One 兼容端点
node scripts/decide.mjs request.json --endpoint systemone
```

密钥约定：

- 来源：环境变量优先，其次本技能根目录的 `.env`
  （三个键与示例见 `.env.example`）。`.env` 已加入 `.gitignore`，禁止提交到仓库。
- 密钥保护：把真实 key 写入 `.env` 后，运行 `bash scripts/protect-env.sh` 收紧权限
  （移除继承，仅当前 Windows 用户可访问）；需要再编辑时先 `icacls .env /reset` 恢复。
- 注意：脚本调用模型时必须读到密钥，因此 `.env` 不能对当前用户"完全不可读"。如果要求连本机
  进程都读不到，就保持 `.env` 为空模板，调用时临时通过环境变量注入密钥。

## Workflow

1. **Start from the decision logic.** Begin with what the application will show, select, change,
   or hand off. Sketch the truth table or rules that decide it, and list the inputs they need.
   Inputs that need an understanding of language or images make good questions. Arithmetic, dates,
   exact lookups, and policy usually belong in code. Aim for every question to feed the table, and
   give every combination of answers an outcome, including the case where a Noul lands between your
   thresholds. If code alone can already make the decision reliably, tell the user.
2. **Keep all question wording in one place.** Questions, options, criteria, and thresholds are the
   parts of an integration people audit and edit most. Keeping them together in one module makes
   that easier. [Design the state](#design-the-state) and
   [Write the questions](#write-the-questions) describe what tends to work.
3. **Probe the live API**: send test requests as described in
   [Test with the live API](#test-with-the-live-api). Use representative cases, hard cases, and
   negative cases. Keep going until the application behaves as intended.
4. **Integrate.** A few habits help here. Expose or log the exact request payload. When a call to
   the API fails, surface it as an error, not as an answer; for example, don't treat a failed call
   as a "no". Keep API keys on the server.

If the user's request is open-ended, offer the few directions from [Cookbooks](#cookbooks) that
best serve their goal, and recommend one. If the request is concrete, build it.

## Design the state

A useful check for any question is the **human test**: could a smart person, shown only this state
and this question, answer quickly by intuition? When a question fails the test, the fix is usually
in the state, not in the wording.

- **Give what a person would look at.** That means who sent each message, the full thread rather
  than a truncated last line, names rather than raw IDs or @-mention markup, and the item the
  question is about rather than the whole catalogue. State facts your code already knows, such as
  "all messages in `replies` were sent after the refund was issued", rather than leaving the model
  to work them out again.
- **Supply facts the model may lack**, such as what an internal product name or codename refers
  to.
- **Ensure every field in the state is relevant.** Irrelevant detail clutters the context and
  reduces accuracy. A field added for one question can sway the answer to another, and the model
  can read an empty list as a signal.
- **Be mindful when truncating.** Truncate long strings only when you need to, and check that the
  cut doesn't remove context the questions need.
- **Structure with named fields.** JSON objects with descriptive keys work better than a string of
  serialized JSON. They also let a question refer to each part by its path. Stable names such as
  `candidates.refund_policy` are easier to refer to than array positions.
- **Consider leaving out what no person could judge**, such as an unreadable crop or a distinction
  experts dispute. The model's answer there tends to be noise, and code will treat that noise as
  signal.

## Write the questions

Break complex judgments or decisions into their parts, and combine the answers in code with
weighted sums, boolean logic, thresholds, or other heuristics to reach the final decision. For
example, rather than asking "Is this fraud?" or "Is this spam?", ask the set of atomic questions
about what might make something fraud or spam. Each question tends to work best when it asks for
**one judgment** that a person could make at a glance.

- **Ask the concrete, observable thing.** Aim for something a person could point to: "Is a SQL
  query built by string concatenation here?" rather than "Are there SQL injection risks?".
- **One judgment per question; beware the "or".** Two conditions joined by "or" or "and" usually
  work better as two questions. Likewise, a list of rules usually works better as one question per
  rule.
- **Anchor intent to the goal.** When the judgment is about what someone wants, it helps to name
  their goal: "Which of these files does the user want copied?" rather than "Which of these names
  the main input?".
- **Name the subject directly.** "Where is the coffee mug in `photo`?" reads better than "Where is
  `target` in `photo`?" with the target defined somewhere else. Context that only one question
  needs, including an image, usually fits best in that question's instructions (the question text)
  or its criteria (the descriptions of its options, its levels, or what yes and no mean). Context
  that many questions share can go in the state once, and each question can refer to it by its
  exact path in backticks. When you ask the same question about many items, it usually works better
  to put each item into its own question than to give an ID the model has to look up in a shared
  list.
- **Each question is answered on its own.** Questions in a request can't see each other or each
  other's answers. Any context a question relies on belongs in the state or in that question.
- **Write plainly.** A question isn't an LLM prompt. Preambles, "consider X, Y, and Z" lists, and
  output-format instructions add noise. Descriptions of the options belong in the criteria, not in
  the question. Phrase the question so that a true answer means yes. Watch for double negatives,
  and for presuppositions such as "the next step".
- **Name the case that causes confusion.** If answers keep mixing up two outcomes, say in the
  criteria what separates them, using the specific case. For example, for "Is this a refund
  request?", note that a question about the refund policy is not a request. A vague exclusion such
  as "not other kinds of message" helps less, and can draw attention to the wrong answer.

### Criteria

- **Ask about the null case separately.** A Choice always picks an option, even when nothing fits.
  Pair it with a Noul in the same request that asks whether anything fits ("Does `message` name
  any of our products?"), so code can tell when nothing does. This companion Noul usually works
  better than a "none of the above" option.
- **Option names are sent to the model; question IDs are not.** Names that describe the content
  (`refund_request`, `shipping_delay`) help the model. Positional names (`A`, `left`, `option_1`)
  give it nothing meaningful to go on and can bias the answer.
- **Keep options distinct and concrete.** Wording that options share with each other, or with the
  input, can pull probability toward those options. An option that covers several meanings is
  often worth splitting, because its probability can't tell code which meaning applied. Direction
  and magnitude usually work better as separate questions, so that the answer to one doesn't get
  mixed into the other.
- **Describe each Score level as a situation.** Each level should make sense when read on its own:
  "The customer mentions a minor inconvenience" rather than "More upset than the previous level".
- **Describe a Noul's `false` criterion as a concrete situation**, such as "the package arrived on
  time", rather than as "not late".
- **Use a Noul per statement when more than one can be true.** A Choice picks one option, so a
  message that is both a refund request and a complaint forces it to split probability between the
  two. Separate Nouls let each one be true on its own.

## Compose requests

**Bundle questions that share state.** A handy heuristic: if two calls would send the same state
with different questions, they can likely be one call. Questions are cheap and run in parallel, and
the state is read and paid for once. Exception: a request with a top-level `image` allows only one
question, so image judgments necessarily go one per request.

**Ask speculatively**, meaning ask a question before you know whether you'll need its answer. A
question that only matters in some cases can go in the same request as the question that
identifies the case. Ask "Is `order` a return request?" and "Which item in `order.items` is being
returned?" together, and have code read the second answer only when the first is yes. The second
question doesn't need an "if" clause, because code handles the condition.

A second request is usually worth it when:

- code needs an answer to build the next state, fetch evidence, or choose the next options;
- a state field needed for one question measurably misleads another;
- different sets of questions need to be cached or versioned separately.

## Read the answers

### Confidence is rarely the gate

Naive implementations often use an answer's `confidence` as the check that decides whether code
acts. Confidence measures how concentrated an answer's probability distribution is, which is not
the same as how likely the answer is to be correct. Think about what the probabilities should look
like in your use case; another calculation over them may suit it better.

### Probabilities and thresholds

- **A probability is the likelihood that an answer is correct.** Jev isn't a calculator for
  probability problems. Ask it for judgments, and do any math on odds or probabilities in code. A
  Noul near 0.5 usually means the state doesn't settle the question.
- **The top answer is a good default**: the Choice's top option, or the Score's position.
- **0.7 and 0.3 make good starting thresholds for a Noul**: above 0.7 reads as yes, below 0.3 as no,
  and the band between means the question isn't settled, which can get its own row in the truth
  table. Adjust them when the application calls for it, and be wary of over-fitting them to a
  handful of test cases.
- **Look at Score distributions.** The Score's position can get pulled toward the middle and hide
  two-peaked answers, so look at the level probabilities before deciding which value your code
  reads.

## Test with the live API

Sending test requests to the live API is a great way to test questions against your data. Ask the
user for permission first. Get a budget for experimentation, disclose what data will be sent
(point out any personal or private data), and say that their platform API key (`sk_...`) will be
used. Calls are metered: usage shows up in the platform's user center and call logs, and pricing
follows the model catalogue.

- Start with a few representative cases, plus hard ones and some whose answer is "no" or "nothing
  fits".
- Compare wordings by sending each variant as a separate question in one request, over the same
  state.
- Read individual answers, not only aggregates.
- Keep the exact request payload for each case so any result can be rerun.
- Check each change against cases you didn't use while tuning.

Make sure any agent that sends test requests has network access to the API endpoint.

### When an answer looks wrong

Check these, in this order:

1. the payload as actually sent;
2. the state, against the human test;
3. the options and candidates: is the right answer among them?
4. the scope of the questions: can each one be broken down into smaller judgments?
5. the wording.

If a clear question with complete state still gets an answer you're confident is wrong, keep the
exact request payload and the response's `traceId` for troubleshooting, and work out an
alternative approach with the user — usually better state, a separate question, or code.

### Yellow flags

Typically, a good change is one that makes the definition clearer or improves the state. Check each
change on cases you didn't tune on. Wording written to produce a particular value is **prompt
gymnastics**, and it tends to break on new inputs and on the next model version. Some yellow flags:

- criteria that name specific test items, or that gain a clause for each failing case;
- caveats that explain away a model quirk;
- thresholds fitted to particular cases;
- tests that assert an exact probability;
- code that quietly overrides answers.

The structural fix is usually better state, a separate question, or code.

## Cookbooks

Each of these starting points combines questions to serve one goal. Ideas outside this list are
welcome.

- **Route and fill arguments.** One request identifies what the user is asking for and which
  values go in each argument. Code then calls the handler (function calling, intent routing).
- **Select instead of generate.** Code finds candidate values or spans of text, the model picks
  the intended one, and code copies or normalizes it (value extraction, date extraction,
  structure recovery).
- **Find and judge evidence.** Retrieve candidates and ask how relevant each one is (line-by-line
  search, re-ranking, classifying RAG passages).
- **Turn answers into data.** Score each dimension once, then let code or users change the weights
  and views. If you have labeled outcomes, the answers can become features for a model (composite
  scoring, feature discovery).
- **Verify and escalate.** Check claims or fields against their evidence, and send the cases that
  fail to a person or a reasoning model (citation checks, extraction cascades).
