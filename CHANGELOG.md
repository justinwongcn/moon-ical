# Changelog

## 0.4.0

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
