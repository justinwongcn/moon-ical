# moon-ical

A pure MoonBit [iCalendar](https://www.rfc-editor.org/rfc/rfc5545) library
with a minimal [CalDAV](https://www.rfc-editor.org/rfc/rfc4791) server.
It reads and writes component trees, calculates a defined subset of recurring
events, and provides discovery and editing for stored calendar resources.
It does not calculate every valid iCalendar input.

## Version

```bash
moon add justinwongcn/moon-ical@0.5.0
```

0.5.0 is the published version (2026-10-31); it adds the RDATE sets,
strict fixed time zones, and checked-query evaluation described below.

## What it handles

- Line unfolding, quoted parameters, TEXT escaping, and nested components.
  Unknown properties remain in the component tree and survive tree round trips.
- UTC, floating times, all-day dates, and explicitly bound fixed-offset TZIDs.
  Unsupported time-zone definitions fail when a typed date references them.
- DAILY, WEEKLY, MONTHLY, and YEARLY recurrence, with INTERVAL, COUNT, UNTIL,
  ordinal BYDAY, signed BYMONTHDAY, BYMONTH, BYSETPOS, and WKST.
- DATE/DATE-TIME RDATE values, merged with recurrence slots and deduplicated.
  EXDATE removes instances; RECURRENCE-ID can move or cancel them;
  RANGE=THISANDFUTURE shifts later instances. DURATION supplies an end when
  DTEND is absent.
- CRLF serialization, folding within 75 octets without splitting UTF-8,
  and parameter quoting.
- A native server with vdir storage, content-addressed ETags, discovery,
  PROPFIND, calendar-query/multiget REPORT, MKCALENDAR, and conditional
  PUT/DELETE. The library also parses MKCALENDAR properties; the server does
  not persist them.

Preserving a component tree is separate from interpreting its dates. For
example, a tree containing PERIOD or dynamic VTIMEZONE data can be read and
written, while typed event parsing may reject it.

## Library usage

```mbt check
///|
test {
  let events = @moon-ical.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:demo\r\n" +
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let occurrences = @moon-ical.expand_series(events)
  assert_eq(occurrences.length(), 3)
  assert_eq(occurrences[2].start.to_string(), "2026-09-03T09:00:00Z")
}
```

The root package exports parse, recurrence, and serialization workflows.
Lower-level APIs live in `ical/text`, `ical/model`, `ical/rrule`,
`ical/serialize`, and `ical/caldav`. Since 0.2.0, the root facade no longer
exports the low-level text and protocol helpers that 0.1.0 exposed.

### 0.5.0 calculation contract

RDATE accepts DATE or DATE-TIME, including repeated lines and comma lists.
PERIOD and mismatched value types are errors. Recurrence needs DTSTART;
RDATE, RECURRENCE-ID, and override starts must use a compatible DATE/floating
domain. RDATE values are independent of RRULE COUNT/UNTIL.

`limit` budgets raw RRULE instances, not the size of the merged result:
RDATE is included in full, while exclusions may shorten the result.
`expand` and `expand_series` fail if the 10000-period safety budget ends
before natural exhaustion or the requested instance budget is filled.
For completeness information, import `ical/rrule` and use
`expand_series_query`; its raw frontier excludes RDATE and is not enough
to prove a moved override's query window complete.

`ZoneTable::builtin_common()` now contains UTC/GMT/Z aliases only. Regional
names no longer receive guessed standard offsets. Use UTC, a provably fixed
VTIMEZONE, or an explicit `ZoneTable::insert` binding. An explicit binding
means the caller is choosing a fixed offset, not enabling DST support.
Invalid or dynamic feed declarations block same-name fallback bindings.

`Filter::matches` now raises on evaluation failure. `ReportOutcome` adds
`EvaluationFailed`; servers must map it separately from filter preconditions.
Direct `Filter` record construction also needs `request_timezone`.

## Run

```bash
moon run demo --target native
moon run demo --target native -- https://example.com/calendar.ics
moon run cmd/serve --target native -- ./caldata 8437
```

The demo prints typed events; it does not expand occurrences. Discovery starts
at `/.well-known/caldav`, and the calendar home is
`http://127.0.0.1:8437/cal/`. The server has no authentication or TLS. Use a
reverse proxy providing both before exposing it beyond a trusted host.

Keep server logs outside the calendar data directory: the store treats files
there as resources.

## Query behavior

`calendar-query` applies component, property, parameter, and time-range filters.
Temporal tests parse only the dates they need. Unsupported recurrence or time
zones do not prevent a SUMMARY-only search, GET, or multiget.

A successful empty series stays empty. The server does not restore its master
or return a successful empty result when it cannot prove the queried window
has been covered. Evaluation failure returns **500**, with a resource href
and a fixed error category, not the raw calendar line or exception. It does
not return a partial multistatus.

Request preconditions return **403** with the applicable `valid-filter`,
`supported-filter`, or `supported-collation` element. Invalid checked request
timezone fields return `valid-calendar-data`. Resource calculation failures
are not mislabeled as unsupported filters.

## Verification

```bash
moon check --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
moon info
python -I tools/s5_acceptance.py
python -I tools/s6_acceptance.py
```

On 2026-10-31, the working tree passed 251 wasm, 234 wasm-gc, 251 JavaScript,
and 261 native tests, including the checked example above.
S5 passed 24 checks and S6 passed 47. Both scripts start and stop isolated
servers. A separate `tools/s6_evaluation_acceptance.mbtx` driver checks RDATE,
query completeness, fixed/dynamic zones, and private-data sentinels in HTTP
responses and logs. Run it against an empty isolated server as described in
[OpenWiki server notes](openwiki/server.md).

New input-driven behavior needs differential tests, empty-result checks,
and specific failure assertions. The capability-to-evidence matrix is in
[the development handbook](docs/development.html#s11).

## Client interoperability

| Client or driver | Discovery | Read/list | Create/update/delete | Evidence |
|---|---:|---:|---:|---|
| curl over TCP | Yes | Yes | Yes | S5 24/24 and S6 47/47; a separate evaluation driver also passes |
| Thunderbird 155.0.1 (Windows) | Yes | Yes | Yes | Earlier localhost session verified seed read, create, in-place update, and delete in vdir |
| DAVx5 | Not run | Not run | Not run | Android device required |
| Apple Calendar | Not run | Not run | Not run | macOS/iOS device required |

The Thunderbird session has not been repeated for the 0.5.0 changes. It did
not exercise MKCALENDAR or temporal filtering. Client CRUD does not prove
complete protocol or calendar semantics.

## Boundaries

- No IANA tzdb or dynamic VTIMEZONE conversion. Typed dates referencing an
  unbound regional TZID or unsupported declaration fail rather than use a
  guessed seasonal offset. Raw component trees remain available.
- No sub-daily FREQ or BYWEEKNO/BYYEARDAY/BYHOUR/BYMINUTE/BYSECOND. These
  rules are rejected; temporal REPORT evaluation fails explicitly.
- No RDATE VALUE=PERIOD expansion. DATE/DATE-TIME is supported.
- Request timezone conversion is not implemented. A request containing it
  fails when any temporal test is evaluated; text-only queries can succeed.
  Its validation checks structure and required fields, not all observance
  RRULE semantics.
- Repeated components other than VEVENT are not expanded for time-range.
  Nonrecurring VTODO uses its RFC 4791 task-state table. VALARM time-range
  is refused with `supported-filter`; relative triggers are not resolved.
- Time-range queries use up to 4096 raw RRULE instances per UID series;
  finite RDATE values are added separately. A proven match can
  succeed; an unproven negative result fails. Overrides require conservative
  completeness checks rather than an unshifted frontier.
- Floating times retain the library's existing comparison convention; it
  does not choose a user's local time zone.
- No CalDAV scheduling, ACL system, built-in TLS, provider adapters, cloud
  account synchronization, or CalDAV client.
- `PROPFIND` and `REPORT` honor the requested `DAV:prop` set: answers are
  trimmed to it, unanswerable names get their own 404 propstat, and
  `calendar-data` (not a WebDAV property) is report-only — in `PROPFIND`
  it answers 404. Matching is by local name, and the 404 echo carries the
  `DAV:` prefix regardless of the request's.
- MKCALENDAR creates a collection but does not persist request properties.
- Request bodies need Content-Length; chunked uploads get 411. After an
  oversized or chunked body, draining stops at 10 MB; a longer running upload
  can lose the refusal response to the close-time reset.
- The XML shape parser matches local element names without full namespace
  URI validation, skips DOCTYPE to its first `>`, and reads only the first
  top-level element. Numeric references decode within the BMP;
  astral-plane references stay verbatim.
- Concurrent connections are not capped. The default bind is 127.0.0.1.
- `/cal/` is both home and default collection. MKCALENDAR collections sit
  beside existing events. A bare top-level VEVENT yields no typed events.
- EXDATE at an override's original slot removes it; the override does not
  resurrect that instance.

See [OpenWiki](openwiki/quickstart.md) for the package map and calculation
contracts. This is an independent implementation under Apache-2.0;
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) records the test corpus source.
