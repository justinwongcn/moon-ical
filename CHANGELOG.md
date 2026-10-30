# Changelog

## 0.5.0 (2026-10-31)

- Honor the `DAV:prop` selection in `PROPFIND` and `REPORT` bodies: answers
  carry exactly the properties the request named, a property the resource
  has no answer for gets its own 404 propstat (RFC 4918 §9.1.2), and
  `propname` answers names without values. `calendar-data` is a report
  property, not a WebDAV property (RFC 4791 §9.6): reports return it, and
  in `PROPFIND` an explicit request for it answers 404. The report DTDs
  leave the selection optional, so a body without one reads as `allprop`.
  Matching is by lowercased local name; the 404 echo carries the `DAV:`
  prefix regardless of the request's.
- Add `parse_propfind` and the `PropFind` / `PropfindError` types to the
  CalDAV semantics package; `root_propfind`, `principal_propfind`, and
  `collection_propfind` take a `selection` parameter. An empty `PROPFIND`
  body reads as `allprop` (RFC 4918 §9.1); a body that does not parse,
  roots elsewhere, or names none of the three selection forms is a bad
  request (400) rather than a silent `allprop`.

- Speed up the calendar-multiget path by a measured 35% (920.67µs →
  597.77µs at 500 hrefs × 500 resources, native release): requested hrefs
  are read off the report's parsed XML tree instead of a second full-body
  scan, `xml_escape` returns inputs that carry no metacharacter without
  building a copy, and the allprop/propname responses stream straight
  into one builder. Internal only — no public interface changes.

- Compute the recurrence set from RRULE/DTSTART plus all master RDATE
  DATE/DATE-TIME values, deduplicate slots, then apply EXDATE and overrides.
  RDATE does not consume RRULE COUNT and may precede DTSTART or follow UNTIL.
  PERIOD, malformed recurrence values, missing recurrence DTSTART, and mixed
  DATE/floating/absolute recurrence domains are refused rather than guessed.
- Require explicit fixed TZID bindings. Built-in aliases are now UTC/GMT/Z
  only; regional names no longer inherit a guessed standard offset. Embedded
  VTIMEZONE declarations must prove a fixed offset. Dynamic, invalid, or
  conflicting declarations shadow same-name defaults and fail when referenced;
  unreferenced declarations remain available in the component tree.
- Sort and deduplicate raw candidates before BYSETPOS and COUNT. Period-budget
  exhaustion now fails even for COUNT/UNTIL-bounded or zero-output walks when
  they have not ended or filled the requested generation limit. This corrects
  the narrower budget check described under 0.4.0 below.
- Add `expand_series_query` and `SeriesQueryResult` in `ical/rrule`: raw
  exhaustion, generated frontier, override presence, and budget shortfall are
  recorded independently of RDATE, exclusions, and moved output instances.
  `limit` bounds RRULE generation, not the final union's length.
- Propagate calendar-query resource evaluation failure through
  `ReportOutcome::EvaluationFailed` to HTTP 500. No master-interval fallback or
  partial multistatus is returned; a proven empty recurrence remains empty.
  SUMMARY-only filtering, GET, and multiget do not require temporal evaluation.
  The 500 reason and its REPORT log contain a resource href and fixed error
  category, not raw exceptions, rules, or calendar content.
- Use the RFC 4791 §9.9 state table for non-recurring VTODO overlap, including
  DUE, CREATED, and COMPLETED states. Unimplemented non-VEVENT recurrence fails
  temporal evaluation. Request timezone conversion is still unsupported:
  its presence makes temporal evaluation fail, while text filtering can work.
  Invalid checked timezone structure/fields return 403 `valid-calendar-data`;
  this validation does not claim full observance-RRULE conformance. Unsupported
  collations return 403 `supported-collation` rather than `supported-filter`.
- **API changes:** `Event.rdates`, `Component::event`,
  `ZoneTable::rejection_reason`, `Filter.request_timezone`, new FilterError
  variants, and `Filter::matches`'s raising contract accompany the query APIs
  and outcome above. Check source as well as generated interfaces for labeled
  parameter calling conventions.
- Verification on 2026-10-31: 251 wasm / 234 wasm-gc / 251 js / 261 native
  strict tests, S5 24/24 and S6 39/39. The review snapshot was
  250/233/250/260; the checked README example adds one per target. The separate
  `tools/s6_evaluation_acceptance.mbtx` live driver covers evaluation errors,
  RDATE, empty results, budgets, timezone refusal, and response/log privacy;
  it is not included in the original 63 live checks. These fixes remain
  uncommitted and unpublished; the earlier Thunderbird session was not rerun.

## 0.4.0

> Release-history correction: S29–S33 (DURATION, MKCALENDAR parsing, reserved
> names, first-root handling, and dependency updates) shipped in 0.4.0 on
> 2026-10-26 despite their planning labels saying “0.5.0”. The budget and
> master-fallback behavior recorded below describes that release, not the
> stricter 0.5.0 behavior above.

- Upgrade to moonbitlang/async 0.22.5 and moonbitlang/x 0.5.6 (the
  routine pre-release pass; every strict gate and both live suites
  pass, interfaces unchanged).
- Keep the first root of a request body with two top-level elements:
  the coverage audit caught the documented "first root wins" shape
  actually being last-root-wins, which let a trailing root override
  what the request already said.
- Refuse Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1`-`COM9`, `LPT1`-`LPT9`, with or without an extension) as store
  names on every platform: a vdir Windows cannot read breaks the
  portability the layout exists for.
- Add `parse_mkcalendar` to the CalDAV semantics package: the typed
  properties (`displayname`, `calendar-description`, `calendar-color`)
  a `MKCALENDAR` request body asks for, entity-decoded. Parsing only —
  what to persist is the embedding server's deployment decision.
- Parse the `DURATION` property (RFC 5545 §3.3.6): an event stating no
  `DTEND` ends where its `DURATION` says (both present is the loud
  spec violation), occurrences inherit the length, and the VTODO /
  VFREEBUSY time-range path honors it too. Day and week components
  count as exact seconds, which coincides with the nominal reading
  under the fixed-offset zones.
- Decode numeric character references (`&#38;`, `&#x26;`) in comparison
  text alongside the five named entities: the numeric spelling of the
  S13 fix's own example searched for a literal `&#38;` and silently
  missed. References naming no single UTF-16 code unit (astral planes,
  surrogates, zero) stay verbatim and simply do not match.
- Fix an Int64 overflow in the Content-Length parser found by the third
  review round: a length of `Int64::MAX/10` times ten plus a digit above
  seven wrapped negative and read as "no size problem", swallowing the
  connection's buffered bytes as the body. The accumulator now saturates
  on the wrap itself.
- Raise the existing typed `ExpandError::Invalid` when a rule has
  produced instances but the expansion's period budget cuts it off short
  of the caller's limit: a sparse unbounded series (a month-end weekly,
  say) used to answer with a silently truncated prefix that read as
  complete. An empty answer stays empty (a rule whose clauses never
  match), and COUNT/UNTIL-bounded rules and limit-filling walks end
  honestly as before; CalDAV time-range evaluation catches the error and
  falls back to the master interval as it already did for other
  failures.
- Tighten four series and response semantics: `expand_series` picks the
  series master by the group's own UID (a foreign master no longer gets
  expanded for a group it does not belong to) and an override without
  its own `DTEND` keeps the master's duration; `calendar-multiget`
  answers a requested but absent href with its own 404 response
  (RFC 4791's per-href shape) instead of dropping it; `VALUE=DATE` with
  a date-time value is a line error instead of a half-read all-day
  value. The bare top-level `VEVENT` and the `EXDATE`-over-override
  behavior are now documented boundaries rather than surprises.
- Make `unfold` linear: each logical line accumulates in its own
  buffer instead of re-copying the whole line on every fold. A 770KB
  folded line measured 1.68s before and 6.6ms after (255x, native
  release, now a kept benchmark); within the server's own 10MB body cap
  the old quadratic extrapolated to minutes per unfold.
- Give the server a one-line access log (`METHOD path -> status`) and a
  stderr line for handler failures: both go through the async runtime's
  direct stdio writes, because core `println` is block-buffered when
  redirected on the native backend and a server that never exits would
  never flush it — before this, a 500 left no trace anywhere.
- Type a REPORT by its root element's local name instead of a substring
  scan of the whole body, so a `calendar-query` whose text-match needle
  or href mentions `CALENDAR-MULTIGET` is no longer misrouted to the
  multiget handler; and refuse a `time-range` whose start is at or after
  its end with the `valid-filter` precondition (403) instead of silently
  matching nothing.
- Close the four confirmed P3 findings from the second review round: a
  well-formed ten-digit `Content-Length` is a size refusal (413) instead
  of "not a plain integer" (400) — the parser saturates an `Int64`
  accumulator instead of rejecting long digit strings; `escape_value`
  normalizes a carriage return to the `\n` escape (RFC 5545 TEXT values
  carry no CR, and a raw one would split the property when unfolded);
  `VdirStore::delete` refuses a directory instead of letting POSIX
  `rmdir(2)` silently remove an empty collection and answer 204; and
  `parse_components` bounds nesting at 64 levels — the cap the XML
  request parser already enforces — so a hostile feed cannot reach the
  recursive serializer and filter walks as a stack overflow.

## 0.3.0

- Evaluate the `CALDAV:filter` of a `calendar-query` instead of answering with
  the whole collection. Nested `comp-filter`, `is-not-defined`, `time-range`,
  `prop-filter` with `text-match`/`param-filter`, and the two `i;ascii-casemap`
  / `i;octet` collations are supported; the RFC 4791 §7.8 preconditions are
  reported as `403` with a `DAV:error` body. A time range is resolved against
  recurrence, `EXDATE`, moved or cancelled instances, and
  `RANGE=THISANDFUTURE` through `expand_series`.
- Make `MKCALENDAR` create a real calendar collection at `/cal/<name>/`,
  answering `405` when one already exists. A created collection is discoverable
  by `PROPFIND`, holds its own events at `/cal/<name>/<event>.ics`, and can be
  reported on and deleted; events at `/cal/<name>.ics` keep working.
- **Breaking:** `ical/caldav`'s `report` returns `ReportOutcome` rather than
  `String?`, so an unknown report (`400`) and the two filter preconditions
  (`403`) can answer differently. `collection_propfind` gains optional `href`,
  `displayname`, and `children` arguments.
- **Breaking:** `ical/store` gains collection APIs — `is_store_name`,
  `VdirStore::collections`, `create_collection`, `collection`, and
  `remove_collection` — and `list` now returns events only.
- Extend the live curl acceptance to cover filter selection, filter
  preconditions, and the collection lifecycle: 170 wasm / 157 wasm-gc / 170 js
  / 176 native tests, S5 21/21 and S6 23/23.
- Align the source tree with moonc v0.10.15's formatter: `Int` is written as
  `Int32`, optional parameters become labeled parameters, and inclusive ranges
  use `..<=`. Semantics and the published `.mbti` interface are unchanged; the
  one observable difference is that those parameters can no longer be passed
  positionally, and every call site already passed them by name. `moon fmt
  --check` passes again, so the CI formatting gate is green.
- Post-review verification round (S11-S15): realize negative `BYMONTHDAY`
  on the DAILY/WEEKLY expansion paths (it silently matched nothing); keep
  expansion past year 9999 and huge-interval arithmetic inside the typed
  error contract (64-bit stepping, the horizon ends the series); report
  out-of-range date-time components and malformed UTC offsets as line
  errors instead of leaking x/time's untyped Failure or half-reading the
  offset; redirect bare collection URLs to their canonical slashed form;
  cap XML nesting depth (a deeply nested REPORT body used to kill the
  process with a stack overflow); decode the predefined XML entities in
  text-match needles and multiget hrefs; bound the request head (64 KB
  per line, 100 header lines) and answer a non-numeric Content-Length
  with 400 instead of 413; make `expand(limit<=0)` return an empty
  series; quote edge-whitespace parameter values on serialization; strip
  the query string before routing. Live acceptance grows to S5 22/22 and
  S6 31/31, including Depth-0 and stale-If-Match-DELETE differentials.
- Re-render the six generated `.mbti` interfaces with moonc v0.10.17, which
  now renders the type as `Int32` directly instead of folding it back to
  `Int` (24 lines, render-only; the types are identical, so no API change).
  Keeps `moon info` diff-clean on current toolchains, where CI runs it.
- Document the three public definitions that carried no doc comment
  (`IcalDateTime::is_utc`, `IcalDateTime::is_floating`, `xml_escape`), found by
  enabling the new `missing_doc` lint.
- Post-review verification round, second wave (S16-S20): end a `WEEKLY`
  series at the calendar horizon when its final week runs past year 9999
  (S12 guarded the step to the week's first day, but the days within the
  week still escaped as x/time's untyped Failure); drain the connection
  after refusing an oversized body, so the 413 actually reaches a client
  that is still uploading instead of dying to the close-time RST (the
  411 branch already drained; measured 6/6 losses before, reliable
  delivery after — now pinned by a raw-socket live check); apply every
  test of a `comp-filter` to one component instance (RFC 4791 §9.7.1) —
  a `VEVENT` time-range is judged against that event's own UID series
  instead of every event in the resource, so another event's overlap can
  no longer satisfy this event's filter (two-event false positive);
  redirect the home collection's bare URL `/cal` to its canonical slashed
  form, the rule the nested collections already followed (the discovery
  chain only ever emits slashed hrefs, so configured clients are
  unaffected); resolve a feed's own `VTIMEZONE` on the VTODO/VJOURNAL and
  prop-filter time-range paths too, so a feed-private `TZID` no longer
  silently matches nothing; bound `parse_utc_offset`'s hour at 23 per RFC
  5545 §3.3.14 (`+9900` used to be silently accepted as 99 hours); give
  `fetch_ics` a timeout of its own (`timeout_seconds? = 30`), because
  upstream's HTTP client and socket layer have none — a server that
  accepts and never answers used to hang the caller forever, and the
  bound now raises the new `FetchError::TimedOut`.
- Upgrade to moonbitlang/async 0.22.4 and moonbitlang/x 0.5.5 ahead of
  the 0.3.0 release. The premise behind `fetch_ics`'s timeout was
  re-verified on the new async (still no timeout of its own in the HTTP
  client or the socket layer); every strict gate and both live
  acceptance suites pass on the upgraded dependencies, and the generated
  interfaces are unchanged.

## 0.2.0

- Add `parse_calendar(String)` as the lossless whole-document entry point.
- Keep the root package focused on complete parsing, recurrence, and
  serialization workflows. Import low-level APIs directly from `ical/text`,
  `ical/model`, `ical/serialize`, or `ical/caldav`.
- Index recurrence overrides and exclusions once during `expand_series`.
- Use zero-copy XML views and indexed href selection for CalDAV multiget.
- Use `StringView` through the shared iCalendar unfolding and content-line
  parser, materializing strings only at model ownership boundaries.
- Normalize RRULE month filters once per expansion and cache month-day
  candidates for 28–31-day months without mutating parsed rules.
- Extend zero-copy `StringView` parsing to the date-time value, RRULE
  clause, HTTP request, and vdir ETag paths past the model ownership
  boundary.
- Build HTTP responses in a `StringBuilder` and resolve `TZID` lookups
  through a `Map`; `ZoneTable.entries` changes type accordingly.
- Render ETags as hex (`to_string(radix=16)`), matching their documented
  form; ETags remain opaque tokens.
- Close the audit's functional test-coverage gaps (BYSETPOS ordering and
  dedup, YEARLY ordinal BYDAY, series merge edge cases, HTTP error paths);
  150 wasm / 137 wasm-gc / 150 js / 155 native tests at 96.0% line
  coverage.

## 0.1.0

- Initial iCalendar library and minimal CalDAV server release.
