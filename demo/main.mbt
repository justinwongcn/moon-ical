///|
/// moon-ical demo entry.
///
///   moon run demo
///       parse the embedded fixture and print the typed events (works on
///       every target).
///
///   moon run demo --target native -- https://chinacalendar.app/ics/china-calendar-2026.ics
///       S1.5: fetch a live feed and parse it end-to-end (URL → events).
///       Needs a network-reachable URL; the fixture path needs no I/O.
async fn main {
  let url = requested_url()
  if url != "" {
    println("fetching \{url} …")
    let text = @fetch.fetch_ics(url)
    println("fetched \{text.length()} bytes\n")
    print_report("live: \{url}", @model.parse_events(text))
  } else {
    print_report("embedded fixture", @model.parse_events(fixture()))
  }
}

///|
/// The first `http(s)://` command-line argument, or "" when absent. Scanning
/// for the scheme instead of a fixed index keeps this target-agnostic:
/// `@env.args()` places the program name differently on js and native.
fn requested_url() -> String {
  for arg in @env.args() {
    if arg.has_prefix("http://") || arg.has_prefix("https://") {
      return arg
    }
  }
  ""
}

///|
/// Print one parsed event per block: summary line via `Show`, then the
/// optional bits that matter for a calendar (all-day flag, location,
/// recurrence rule, override origin, exclusions).
fn print_report(source : String, events : Array[@model.Event]) -> Unit {
  println("moon-ical demo [\{source}]: parsed \{events.length()} event(s)\n")
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

///|
/// A realistic embedded feed: a feed-declared VTIMEZONE, folded and escaped
/// text, a weekly RRULE with exclusions, an all-day event, and an override
/// instance that moves one occurrence to another day. No I/O — the fixture
/// path runs on every target.
fn fixture() -> String {
  "BEGIN:VCALENDAR\r\n" +
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
}
