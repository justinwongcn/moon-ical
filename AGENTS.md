# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Read the MoonBit skills before writing code

MoonBit's language surface is small and moves fast. Model priors are routinely
wrong here: an API that looks plausible may not exist, the metadata format
depends on feature flags, and imports do not live where most languages put
them. Load the matching skill from `.agents/skills/` **before** the first edit,
not after a build failure.

| Task | Skill to read first |
| --- | --- |
| Any MoonBit question ("does it have X?", a diagnostic, a target rule) | `moonbit-orientation` |
| Writing / organizing / testing MoonBit, `moon` tooling, `.mbtx` | `moonbit-agent-guide` |
| Refactoring a package, shrinking a public API | `moonbit-refactoring` |
| Spec-first API and test suite (`spec.mbt`, `declare`) | `moonbit-spec-test-development` |
| Extracting spec/tests from an existing implementation | `moonbit-extract-spec-test` |
| Proof-carrying code, Why3, abstraction functions, invariants | `moonbit-proof` |
| `extern "c"` bindings, vendoring C sources | `moonbit-c-binding`, then `make-moonbit-c-bindings` |
| Porting OCaml code to MoonBit | `ocaml2moonbit-migration` |
| OSC 2026 contest, packaging, submission checks | `osc2026-guide` |

Two non-negotiables:

- Never name a stdlib or package API you have not verified. Check with
  `moon ide doc "Type::method"` (or `moon ide peek-def`) before using it, and
  say so in the answer when you did.
- Check the toolchain first: `moon version --all`. Feature flags such as
  `rr_moon_mod` / `rr_moon_pkg` decide whether metadata is `moon.mod` /
  `moon.pkg` or the legacy `.json` form, and where imports are declared.

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

## Cross-session progress tracking

- **Before doing any work in this repository, read `docs/PROGRESS.md`.** It is
  the single cross-session source of truth for where the project is, what the
  next milestone is, and why key decisions were made.
- **Before ending a session, update `docs/PROGRESS.md`** (status snapshot,
  milestone table, append to the session log, run through its closing
  checklist). If a milestone landed, also sync `docs/development.html` §02/§04.
- Milestone work follows the handbook in `docs/development.html`: one minimal
  goal per commit, `S<n>:` commit prefix, per-step acceptance criteria, and a
  hard cap — split the step if it outgrows half a day.
- **Commit command is fixed**: `git -c core.hooksPath=.githooks commit ...`.
  EvoX's environment injects a global `core.hooksPath`, so the project gate in
  `.githooks/pre-commit` (moon check + "source changes must include a
  docs/PROGRESS.md update") only fires with this explicit `-c`. Never pass
  `--no-verify` and never use a bare `git commit` for milestone work.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
