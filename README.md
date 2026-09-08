# moon-ical

[iCalendar (RFC 5545)](https://www.rfc-editor.org/rfc/rfc5545) parsing and
recurrence expansion in pure [MoonBit](https://www.moonbitlang.com) — growing
towards a minimal [CalDAV (RFC 4791)](https://www.rfc-editor.org/rfc/rfc4791)
calendar server.

## What is here today

| Package | Contents |
|---|---|
| `ical/text` | Line unfolding (§3.1), content-line parsing with quoted parameters, RFC 5545 text unescaping, line-numbered `ParseError` |
| `ical/model` | Generic component tree (`BEGIN`/`END` nesting, unknown components preserved), `IcalDateTime` with explicit UTC / floating / TZID / all-day semantics, `ZoneTable` fixed-offset resolution incl. feed-embedded `VTIMEZONE` |

Both packages carry assertion tests (60 at S0), including RFC 5545
Appendix A recurrence cases ported for the expansion engine.

## Direction

The mooncakes.io registry currently has several offline iCalendar/RRULE
computation libraries and **no** CalDAV server or calendar subscription
package at all. moon-ical takes the end-to-end seat: parse real feeds, expand
recurrence, and serve them over CalDAV so stock calendar clients
(Thunderbird, DAVx5, Apple Calendar) can connect.

Roadmap (one verifiable step per commit):

1. **S1–S4** typed event layer → RRULE parsing → tier-1 expansion (DAILY /
   WEEKLY / MONTHLY, Appendix A cross-checked) → iCalendar serialization
2. **S5–S7** HTTP/1.1 request layer on `moonbitlang/async` sockets + vdir
   file store → WebDAV/CalDAV core (PROPFIND, REPORT, MKCALENDAR) → real
   client interop matrix
3. **S8–S9** RECURRENCE-ID override merge + tier-2 BY* clauses → CI,
   mooncakes.io publish

Seam register and spike evidence live in `docs/upstream-seams.md` and
`docs/spike-notes.md`. The living development handbook — positioning,
architecture, milestone ladder (S0–S9), engineering conventions, risk
register — is [`docs/development.html`](docs/development.html), updated at
every milestone commit.

## Boundaries (explicit non-goals)

- No full IANA tzdb — zone resolution is fixed-offset plus feed-embedded
  `VTIMEZONE` (see seam S2 in `docs/upstream-seams.md`).
- CalDAV server only, not a CalDAV client; no scheduling (iTIP/iMIP), no ACL
  system, no TLS in the first release.
- Unsupported RRULE clauses raise a typed error instead of being silently
  dropped.

## Development

```bash
moon check   # type-check all packages
moon test    # run the assertion suite
```

## License

Apache-2.0
