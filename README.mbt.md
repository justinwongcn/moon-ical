# moon-ical

A pure MoonBit [iCalendar (RFC 5545)](https://www.rfc-editor.org/rfc/rfc5545)
library and minimal [CalDAV (RFC 4791)](https://www.rfc-editor.org/rfc/rfc4791)
server. It covers the full path from `.ics` input through typed events and
recurrence expansion to a DAV calendar that stock clients can discover.

## Features

- iCalendar unfolding, quoted parameters, TEXT escaping, nested components,
  and preservation of unknown properties.
- UTC, floating, `TZID`, and all-day values; feed-embedded `VTIMEZONE` takes
  precedence over the documented common fixed-offset table.
- `DAILY`, `WEEKLY`, `MONTHLY`, and `YEARLY` recurrence with `INTERVAL`,
  `COUNT`, `UNTIL`, ordinal `BYDAY`, positive/negative `BYMONTHDAY`,
  `BYMONTH`, `BYSETPOS`, and `WKST`.
- Effective-series merging for `EXDATE`, moved/cancelled `RECURRENCE-ID`, and
  `RANGE=THISANDFUTURE`.
- RFC-style CRLF serialization with UTF-8-safe 75-octet folding.
- Native CalDAV server: vdir storage, content-addressed ETags, discovery,
  `PROPFIND`, calendar-query/multiget `REPORT`, `MKCALENDAR`, and conditional
  PUT/DELETE.

## Library usage

```mbt nocheck
///|
test {
  let events = @moon_ical.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:demo\r\n" +
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let occurrences = @moon_ical.expand_series(events)
  assert_eq(occurrences.length(), 3)
  assert_eq(occurrences[2].start.to_string(), "2026-09-03T09:00:00Z")
}
```

Focused subpackages remain available under `ical/text`, `ical/model`,
`ical/rrule`, `ical/serialize`, and `ical/caldav`. The root package re-exports
their stable public APIs.

## Run

```bash
moon run demo --target native
moon run demo --target native -- https://example.com/calendar.ics
moon run cmd/serve --target native -- ./caldata 8437
```

The calendar home is `http://127.0.0.1:8437/cal/`; discovery starts at
`/.well-known/caldav`. The first release is local/plain HTTP. Put TLS and
authentication in a reverse proxy before exposing it outside a trusted host.

## Verification

```bash
moon check --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
moon info
python tools/s5_acceptance.py
python tools/s6_acceptance.py
```

Current results: 131 wasm, 121 wasm-gc, 131 JavaScript, and 136 native tests;
21 HTTP storage and 11 live CalDAV curl checks also pass.

## Client interoperability

| Client or driver | Discovery | Read/list | Create/update/delete | Result |
|---|---:|---:|---:|---|
| Real curl over TCP | Yes | Yes | Yes | 32/32 live checks pass |
| Thunderbird 155.0.1 (Windows) | Yes | Yes | Yes | Passed against localhost: seed read, create, in-place update, and delete verified in vdir |
| DAVx5 | Not run | Not run | Not run | Android device required |
| Apple Calendar | Not run | Not run | Not run | macOS/iOS device required |

Rows are marked passed only after an actual client session; curl coverage is
not presented as client-interoperability evidence.

## Boundaries

- No complete IANA tzdb. Named zones use feed `VTIMEZONE` then a common
  fixed-offset table; recurring wall time keeps the resolved offset across DST.
- No CalDAV scheduling (iTIP/iMIP), ACL system, built-in TLS, or CalDAV client.
- Request bodies require `Content-Length`; chunked uploads receive `411`.
- Sub-daily RRULE frequencies and `BYWEEKNO`, `BYYEARDAY`, `BYHOUR`,
  `BYMINUTE`, and `BYSECOND` are explicit parse errors.

The architecture and milestone record are in
[docs/development.html](docs/development.html); corpus provenance and ecosystem
research are under `docs/research/`. This is an independent MoonBit
implementation, licensed under Apache-2.0.
