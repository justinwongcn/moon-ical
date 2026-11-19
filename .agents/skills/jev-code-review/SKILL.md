---
name: jev-code-review
description: Use for targeted review of a supplied code change and associated test receipts against custom review criteria. Returns evidence-backed review leads, not merge approval or a replacement for tests.
---

# Review a diff and its completion evidence

## Setup: choose the service or simulation

Check only the presence of `OPENROUTER_API_KEY` and `TYPESAFE_API_KEY`; never
print credentials. Respect the user's already chosen mode. For a new setup,
prefer the user's existing OpenRouter account; otherwise offer official TypeSafe.
If OpenRouter is missing, explain that direct TypeSafe is also real Jev. Do not
silently change destination, send data, create an account or switch the host model.

If no route has been chosen, explain the available routes and ask:

> **A — Real Jev:** use/get an OpenRouter key at https://openrouter.ai/settings/keys
> if you use OpenRouter; otherwise use/get a TypeSafe key at
> https://console.typesafe.ai. Configure it locally, not in chat.
> **B — Simulate:** use the current agent, or an explicitly selected available
> model such as DeepSeek, with the same context, questions and criteria.

**Wait for an explicit choice.** Do not ask again for every record in the same
approved task. API errors do not authorize switching providers or simulation.
Missing both keys is not a dead end: offer B. It requires no Jev key but the
chosen agent/model's ordinary access, usage costs and privacy terms still apply.
Do not assume DeepSeek is installed, free or locally hosted.

In B, return `mode: agent_simulation` for the current host or
`mode: model_simulation` for another explicitly approved model, plus its actual
model identity when available and `jev_called: false`. Each question has `value`,
`needs_review`, a brief evidence-based `reason`, `probability: null` and
`confidence: null`. Choice values must be supplied labels, Noul values booleans,
and Score values integer rubric indices. Use null/review for missing evidence.
Never present this as Jev, calibrated probability or equivalent speed/accuracy.
Skip Jev CLI/API steps in B; use the approved model's existing interface and do
not install a substitute or send data elsewhere without consent.

In A (this project's configured route), Jev calls go through the TokenRhythm
channel that the sibling `jev-decision` skill already provides — no
OpenRouter/TypeSafe account and no `jev-decide` CLI are involved. The key
comes from `TOKENRHYTHM_API_KEY` in the environment or from
`.agents/skills/jev-decision/.env`; requests run as
`node .agents/skills/jev-decision/scripts/decide.mjs <request.json>` from the
repository root. `--dry-run` validates the request locally; it neither
classifies nor makes a network call, and it does not read the key.

## Jev API prerequisite and first example

In Jev API mode, use the TokenRhythm channel script
`.agents/skills/jev-decision/scripts/decide.mjs` (Node, zero dependencies) —
this project's already-configured route. Do not install the upstream
`jev-decide` CLI and do not ask for OpenRouter/TypeSafe keys. The script reads
`TOKENRHYTHM_API_KEY` from the environment or from
`.agents/skills/jev-decision/.env` and never prints credentials; the key never
goes into a prompt or request file. Requests without an explicit `model` field
get the TokenRhythm model (`NeoHorse-Jev-4B`) filled in automatically; the
bundled examples' `typesafe/jev-1.13` id is not valid here and has been
replaced in this installation.
Actual UI, file, mailbox or simulation actions require the host's own tools.

Resolve `<skill-dir>` to this installed folder. Copy and edit
[assets/example.json](assets/example.json) for the user's task; it is synthetic
input, not a captured successful result. Validate it without a key or API call:

```bash
node .agents/skills/jev-decision/scripts/decide.mjs <skill-dir>/assets/example.json --dry-run
# After reviewing the input and authorization to send it to TokenRhythm:
node .agents/skills/jev-decision/scripts/decide.mjs /path/to/edited-request.json
```

Normal calls send the supplied evidence to TokenRhythm and incur usage.
Success exits 0 and prints the structured answers to stdout; any failure
(network, HTTP status, missing key) exits non-zero and puts
`code`/`message`/`traceId` on stderr — a failed call is an error, not an
answer. Read the answers, not only the exit code: each answer carries its
`noul`/`choice`/`score` value and probabilities; caller-set thresholds (this
project uses 0.7/0.3) decide yes/no, and the band between them is "not
settled". A confidently false Noul is still false. Unknown, missing or
conflicting evidence needs a fallback.

## Workflow

1. Collect the actual diff, relevant source and tests, acceptance criteria and real command receipts. Mark unavailable evidence as missing.
2. Separate concerns such as correctness, compatibility and test coverage. Select concrete hunks before attaching severity to a finding.
3. Use test receipts to check completion claims; a passing altered test is not evidence for the original behavior.
4. Return each lead with its hunk/source ID, concern, uncertainty and a concrete verification step. A Jev label alone is not proof of a defect.
5. Keep compilers, static analysis and original tests. Do not merge, publish, change review protections or edit tests merely because the judgment suggests approval.

## Context and parallelism

Jev does not inherit the agent's history. Give every request sufficient context:
requirements, the actual diff, surrounding source and relevant callers, invariants,
tests and their receipts. A hunk alone may hide the reason for a change; preserve
cross-file dependencies. Mark missing evidence and omit unrelated files and secrets.

Batch independent review criteria over the same diff instead of serial LLM calls.
Use bounded concurrency for independent change groups, with hunk/question IDs,
rate limits and a cost/time budget; include shared dependencies in each request.
The host schedules calls; the CLI has no parallel scheduler. Questions cannot read
other answers in the same request: a finding-dependent verification needs a later
call with its receipt. Jev's low latency helps broad screening, not patch generation
or replacing tests and deeper review.

## Make it yours

Replace the example's evidence, candidate IDs and criteria together. Preserve a
no-match route when the real task can fall outside the labels. Agree on how the
host or person consumes each answer before enabling any automatic effect.

## Precedent

[Related project or author example](https://github.com/devagrawal09/jev-review). Our workflow is an adaptation,
not that project's code, an automatic installer, or a reproduced benchmark.
[OpenRouter request contract](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request).
