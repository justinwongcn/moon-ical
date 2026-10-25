# Changelog

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
