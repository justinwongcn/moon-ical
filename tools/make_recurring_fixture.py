#!/usr/bin/env python3
"""Generate fixtures/recurrence-demo.ics — the recurring-event demo subscription.

Why Python (user-sanctioned 2026-09-10): the ecosystem is mature and the
generator is throwaway tooling, not library code; repo automation rules in
AGENTS.md (.mbtx) still apply to MoonBit build/test scripting.

The fixture intentionally carries the three shapes the expansion milestones
need, in one file:

- RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10  -> drives S3 (first-tier expansion)
- an override VEVENT with RECURRENCE-ID    -> drives S8 (instance merge)
- an embedded VTIMEZONE with DST RRULEs    -> exercises ZoneTable resolution
- one EXDATE                               -> exercises the exdate path

DTSTART 2026-09-01 is a Tuesday; ten TU/TH occurrences run through Oct 1.
The override moves the Sep 10 occurrence to 10:30; the EXDATE cancels Sep 15.

Run:  python tools/make_recurring_fixture.py
Output is deterministic (fixed DTSTAMP), CRLF-terminated per RFC 5545 §3.1.
"""

from pathlib import Path

LINES = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//moon-ical//recurrence-demo//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:moon-ical 重复事件演示",
    "X-WR-TIMEZONE:America/New_York",
    "BEGIN:VTIMEZONE",
    "TZID:America/New_York",
    "BEGIN:STANDARD",
    "DTSTART:20071104T020000",
    "TZOFFSETFROM:-0400",
    "TZOFFSETTO:-0500",
    "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
    "TZNAME:EST",
    "END:STANDARD",
    "BEGIN:DAYLIGHT",
    "DTSTART:20070311T020000",
    "TZOFFSETFROM:-0500",
    "TZOFFSETTO:-0400",
    "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
    "TZNAME:EDT",
    "END:DAYLIGHT",
    "END:VTIMEZONE",
    "BEGIN:VEVENT",
    "UID:weekly-standup@moon-ical.demo",
    "DTSTAMP:20260901T000000Z",
    "DTSTART;TZID=America/New_York:20260901T090000",
    "DTEND;TZID=America/New_York:20260901T093000",
    "SUMMARY:每周例会（Tue/Thu 站会）",
    "DESCRIPTION:RRULE 驱动 S3 对拍；RECURRENCE-ID 改期驱动 S8；VTIMEZONE 驱动 ZoneTable。",
    "RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10",
    "EXDATE;TZID=America/New_York:20260915T090000",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:weekly-standup@moon-ical.demo",
    "DTSTAMP:20260901T000000Z",
    "RECURRENCE-ID;TZID=America/New_York:20260910T090000",
    "DTSTART;TZID=America/New_York:20260910T103000",
    "DTEND;TZID=America/New_York:20260910T110000",
    "SUMMARY:每周例会（9/10 改期 10:30）",
    "END:VEVENT",
    "END:VCALENDAR",
]


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    out = root / "fixtures" / "recurrence-demo.ics"
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(("\r\n".join(LINES) + "\r\n").encode("utf-8"))
    print(f"wrote {out.relative_to(root)} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
