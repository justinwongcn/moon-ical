# moon-ical

An [iCalendar (RFC 5545)](https://www.rfc-editor.org/rfc/rfc5545) library and
a minimal [CalDAV (RFC 4791)](https://www.rfc-editor.org/rfc/rfc4791) server,
written in pure MoonBit. It parses `.ics` input into typed events, expands
recurring series, and serves the result over CalDAV so ordinary calendar
clients can discover and edit it.

## Features

- Parses the messy corners of iCalendar: line unfolding, quoted parameters,
  TEXT escaping, nested components. Unknown properties round-trip untouched.
- Handles UTC, floating, `TZID`, and all-day values. A `VTIMEZONE` embedded
  in the feed wins; otherwise zones fall back to a documented table of
  common fixed offsets.
- Expands `DAILY`, `WEEKLY`, `MONTHLY`, and `YEARLY` recurrence, with
  `INTERVAL`, `COUNT`, `UNTIL`, ordinal `BYDAY`, signed `BYMONTHDAY`,
  `BYMONTH`, `BYSETPOS`, and `WKST`.
- Merges series-level exceptions: `EXDATE`, `RECURRENCE-ID` overrides that
  move or cancel an instance, and `RANGE=THISANDFUTURE`.
- Writes .ics back out with CRLF line endings, folded at 75 octets without
  cutting a UTF-8 sequence in half.
- A native CalDAV server: vdir storage, content-addressed ETags, discovery,
  `PROPFIND`, `REPORT`, `MKCALENDAR`, and conditional PUT/DELETE.
- `calendar-query` really evaluates its `CALDAV:filter`, including nested
  component filters, `is-not-defined`, `text-match`, parameter filters, and
  `time-range` resolved against recurrence. Failed preconditions come back
  as `403` per RFC 4791 §7.8.
- `MKCALENDAR` creates a collection under `/cal/<name>/` that holds its own
  events, shows up in `PROPFIND`, and can be deleted.

## Install

```bash
moon add justinwongcn/moon-ical@0.3.0
```

0.3.0 is the version currently published on mooncakes. 0.4.0 is still in
development and will land once the new API and the end-to-end checks are
done.

## Library usage

```mbt nocheck
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

The library is also split into focused subpackages: `ical/text`, `ical/model`,
`ical/rrule`, `ical/serialize`, and `ical/caldav`. The root package re-exports
their stable public APIs.

## Run

```bash
moon run demo --target native
moon run demo --target native -- https://example.com/calendar.ics
moon run cmd/serve --target native -- ./caldata 8437
```

The calendar home is `http://127.0.0.1:8437/cal/`, and discovery starts at
`/.well-known/caldav`. The server speaks plain HTTP only, with no TLS or
authentication of its own. Put a reverse proxy that provides both in front
of it before exposing it beyond a trusted host.

## Verification

```bash
moon check --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
moon info
python tools/s5_acceptance.py
python tools/s6_acceptance.py
```

Right now that's 201 wasm, 184 wasm-gc, 201 JavaScript, and 210 native
tests, plus 23 HTTP storage checks and 39 live CalDAV checks driven by curl.

The suite is written to fail when a capability is missing: every
input-driven behavior has a pair of requests that differ in exactly that
input and must produce different answers. The rule and the
capability→evidence matrix are in
[docs/development.html](docs/development.html) §11.

## Client interoperability

| Client or driver | Discovery | Read/list | Create/update/delete | Result |
|---|---:|---:|---:|---|
| Real curl over TCP | Yes | Yes | Yes | 62/62 live checks pass |
| Thunderbird 155.0.1 (Windows) | Yes | Yes | Yes | Passed against localhost: seed read, create, in-place update, and delete verified in vdir |
| DAVx5 | Not run | Not run | Not run | Android device required |
| Apple Calendar | Not run | Not run | Not run | macOS/iOS device required |

A row only counts as passed after a real session with that client. The curl
numbers are protocol smoke tests and do not stand in for client
interoperability.

## 0.1.0 release scope (frozen)

The hackathon release (0.1.0) is feature-frozen at the reusable iCalendar
library, the minimal CalDAV server, the live curl acceptance suites, and the
verified Thunderbird CRUD interop. DAVx5 and Apple Calendar would be nice to
add but aren't release requirements. Cloud-account sync for Google Calendar,
iCloud, Yahoo, and Outlook/Microsoft Graph is post-hackathon work.

## Boundaries

- No full IANA tzdb. Named zones come from the feed's `VTIMEZONE` first, then
  a common fixed-offset table; recurring wall times keep their resolved
  offset across DST.
- No CalDAV scheduling (iTIP/iMIP), ACL system, built-in TLS, or CalDAV
  client.
- No provider adapters or cloud-account synchronization for Google Calendar,
  iCloud, Yahoo, or Outlook/Microsoft Graph.
- Request bodies need a `Content-Length`; chunked uploads get `411`.
- Sub-daily RRULE frequencies and `BYWEEKNO`, `BYYEARDAY`, `BYHOUR`,
  `BYMINUTE`, and `BYSECOND` are rejected as parse errors.
- `calendar-query` evaluates the filter, but `PROPFIND` and `REPORT` still
  ignore the requested `DAV:prop` set and answer with a fixed property set.
- `MKCALENDAR` creates the collection but ignores the properties in its
  request body (`displayname`, `calendar-color`); the collection's name is
  its display name.
- A bare top-level `VEVENT` with no `VCALENDAR` wrapper parses into a
  component tree, but `parse_events` yields no events from it. The tree is
  still inspectable via `parse_components`.
- An `EXDATE` at the same instant as a `RECURRENCE-ID` override removes that
  instance; the override doesn't resurrect it.
- The request XML parser is a shape parser: a DOCTYPE is skipped to its
  first `>`, and given two top-level elements only the first is read.
  Numeric character references decode up to the BMP (`&#38;` equals
  `&amp;`); astral-plane references stay verbatim.
- The server accepts an unbounded number of concurrent connections; it
  binds `127.0.0.1` unless you change the listen address.
- After refusing an oversized or chunked body the server drains up to
  10 MB before closing; an upload still running past that loses the
  refusal response to the close-time reset.
- `/cal/` is both the calendar home and the default collection. A collection
  created by `MKCALENDAR` sits beside the existing events instead of moving
  them, so a client already pointed at `/cal/` keeps working.
- A `time-range` on `VALARM` is refused with `supported-filter`; relative
  triggers are not resolved.
- `DURATION` is parsed as the alternative end (exact seconds; day and week components count nominally, which coincides under the fixed-offset zones). `RDATE` and `VALUE=PERIOD` are not parsed, so additional recurring instances are ignored.

Architecture notes and the milestone record are in
[docs/development.html](docs/development.html); third-party corpus sources
are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). This is an
independent MoonBit implementation, licensed under Apache-2.0.
