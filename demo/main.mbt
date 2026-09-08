///|
/// S1 demo: parse an embedded calendar feed and print its typed events.
///
///   moon run demo
///
/// The fixture is a realistic feed: a feed-declared VTIMEZONE, folded and
/// escaped text, a weekly RRULE with exclusions, an all-day event, and an
/// override instance that moves one occurrence to another day. No I/O —
/// everything happens in-process, so the demo runs on every target.
fn main raise {
  let feed = "BEGIN:VCALENDAR\r\n" +
    "VERSION:2.0\r\n" +
    "PRODID:-//moon-ical//demo//EN\r\n" +
    "CALSCALE:GREGORIAN\r\n" +
    "BEGIN:VTIMEZONE\r\n" +
    "TZID:Asia/Shanghai\r\n" +
    "BEGIN:STANDARD\r\n" +
    "DTSTART:19700101T000000\r\n" +
    "TZOFFSETFROM:+0800\r\n" +
    "TZOFFSETTO:+0800\r\n" +
    "TZNAME:CST\r\n" +
    "END:STANDARD\r\n" +
    "END:VTIMEZONE\r\n" +
    "BEGIN:VEVENT\r\n" +
    "UID:weekly-sync@demo\r\n" +
    "DTSTART;TZID=Asia/Shanghai:20260910T093000\r\n" +
    "DTEND;TZID=Asia/Shanghai:20260910T100000\r\n" +
    "SUMMARY:每周同步会\\, 2026 秋\r\n 季版\r\n" +
    "LOCATION:会议室 B\r\n" +
    "RRULE:FREQ=WEEKLY;BYDAY=TH;COUNT=8\r\n" +
    "EXDATE;TZID=Asia/Shanghai:20260924T093000,20261008T093000\r\n" +
    "END:VEVENT\r\n" +
    "BEGIN:VEVENT\r\n" +
    "UID:mid-autumn@demo\r\n" +
    "DTSTART;VALUE=DATE:20260925\r\n" +
    "DTEND;VALUE=DATE:20260926\r\n" +
    "SUMMARY:中秋节\r\n" +
    "TRANSP:TRANSPARENT\r\n" +
    "END:VEVENT\r\n" +
    "BEGIN:VEVENT\r\n" +
    "UID:weekly-sync@demo\r\n" +
    "RECURRENCE-ID;TZID=Asia/Shanghai:20260917T093000\r\n" +
    "DTSTART;TZID=Asia/Shanghai:20260918T140000\r\n" +
    "DTEND;TZID=Asia/Shanghai:20260918T150000\r\n" +
    "SUMMARY:每周同步会（改期到周五 14:00）\r\n" +
    "END:VEVENT\r\n" +
    "END:VCALENDAR"
  let events = @model.parse_events(feed)
  println("moon-ical demo: parsed \{events.length()} event(s)\n")
  for i, event in events {
    println("[\{i + 1}] \{event}")
    if event.all_day() {
      println("    all-day")
    }
    if event.location is Some(loc) {
      println("    location: \{loc}")
    }
    if event.rrule is Some(rule) {
      println("    repeats: \{rule}")
    }
    if event.recurrence_id is Some(orig) {
      println("    overrides the instance at \{orig}")
    }
    if event.exdates.length() > 0 {
      println(
        "    except \{event.exdates.length()} occurrence(s): \{event.exdates[0]} …",
      )
    }
    println("")
  }
}
