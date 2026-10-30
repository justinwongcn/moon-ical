#!/usr/bin/env python3
"""Generate fixtures/recurrence-demo.ics — the recurring-event demo subscription.

Why Python (user-sanctioned 2026-09-10): the ecosystem is mature and the
generator is throwaway tooling, not library code; repo automation rules in
AGENTS.md (.mbtx) still apply to MoonBit build/test scripting.

The fixture intentionally carries the three shapes the expansion milestones
need, in one file:

- RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10  -> drives S3 (first-tier expansion)
- an override VEVENT with RECURRENCE-ID    -> drives S8 (instance merge)
- an explicitly fixed VTIMEZONE (-0500)    -> no DST correctness claim
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
    "X-WR-TIMEZONE:DEMO-FIXED-0500",
    "BEGIN:VTIMEZONE",
    "TZID:DEMO-FIXED-0500",
    "BEGIN:STANDARD",
    "DTSTART:19700101T000000",
    "TZOFFSETFROM:-0500",
    "TZOFFSETTO:-0500",
    "TZNAME:Fixed-0500",
    "END:STANDARD",
    "END:VTIMEZONE",
    "BEGIN:VEVENT",
    "UID:weekly-standup@moon-ical.demo",
    "DTSTAMP:20260901T000000Z",
    "DTSTART;TZID=DEMO-FIXED-0500:20260901T090000",
    "DTEND;TZID=DEMO-FIXED-0500:20260901T093000",
    "SUMMARY:每周例会（Tue/Thu 站会）",
    "DESCRIPTION:RRULE 驱动 S3 对拍；RECURRENCE-ID 改期驱动 S8；VTIMEZONE 驱动 ZoneTable。",
    "RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10",
    "EXDATE;TZID=DEMO-FIXED-0500:20260915T090000",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:weekly-standup@moon-ical.demo",
    "DTSTAMP:20260901T000000Z",
    "RECURRENCE-ID;TZID=DEMO-FIXED-0500:20260910T090000",
    "DTSTART;TZID=DEMO-FIXED-0500:20260910T103000",
    "DTEND;TZID=DEMO-FIXED-0500:20260910T110000",
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
