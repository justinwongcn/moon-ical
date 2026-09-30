# Changelog

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
