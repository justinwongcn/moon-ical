///|
/// A feed with one ordinary event: TZID times, an escaped and folded summary.
fn one_event_feed() -> String {
  "BEGIN:VCALENDAR\r\n" +
  "VERSION:2.0\r\n" +
  "PRODID:-//moon-ical//test//EN\r\n" +
  "BEGIN:VEVENT\r\n" +
  "UID:demo-1@moon-ical\r\n" +
  "DTSTART;TZID=Asia/Shanghai:20260910T093000\r\n" +
  "DTEND;TZID=Asia/Shanghai:20260910T103000\r\n" +
  "SUMMARY:每周同步会\\, 2026 秋\r\n 季版\r\n" +
  "LOCATION:会议室 B\r\n" +
  "END:VEVENT\r\n" +
  "END:VCALENDAR"
}

///|
/// Report the message of a failing parse, or "no-error" when it succeeded.
fn feed_error_of(feed : String) -> String {
  try {
    let _ = @model.parse_events(feed)
    "no-error"
  } catch {
    err => err.to_string()
  }
}

///|
test "parse_events maps typed fields, unescaping and unfolding on the way" {
  let events = @model.parse_events(one_event_feed())
  assert_eq(events.length(), 1)
  let e = events[0]
  assert_eq(e.uid, Some("demo-1@moon-ical"))
  assert_eq(e.summary, Some("每周同步会, 2026 秋季版"))
  assert_eq(e.location, Some("会议室 B"))
  let dt = e.dtstart.unwrap()
  assert_eq(dt.utc_offset, Some(8 * 3600))
  assert_eq(dt.wall.hour(), 9)
  assert_eq(e.dtend.unwrap().wall.hour(), 10)
}

///|
test "an all-day event is recognised through its DATE dtstart" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:holiday\r\nDTSTART;VALUE=DATE:20260925\r\nDTEND;VALUE=DATE:20260926\r\nSUMMARY:中秋节\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  let e = events[0]
  assert_true(e.all_day())
  assert_true(e.dtstart.unwrap().all_day)
  assert_true(e.dtend.unwrap().all_day)
}

///|
test "the raw RRULE value is kept verbatim for the expansion milestones" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r\r\nDTSTART:20260910T090000Z\r\nRRULE:FREQ=WEEKLY;BYDAY=TH;COUNT=8\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_eq(events[0].rrule, Some("FREQ=WEEKLY;BYDAY=TH;COUNT=8"))
}

///|
test "EXDATE collects comma-packed and repeated lines in wire order" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:20260910T090000Z\r\n" +
    "EXDATE:20260917T090000Z,20260924T090000Z\r\n" +
    "EXDATE:20261001T090000Z\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR",
  )
  let e = events[0]
  assert_eq(e.exdates.length(), 3)
  assert_eq(e.exdates[0].wall.day(), 17)
  assert_eq(e.exdates[2].wall.day(), 1)
}

///|
test "an EXDATE with a TZID parameter resolves through it" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Asia/Shanghai:20260910T093000\r\nEXDATE;TZID=Asia/Shanghai:20260924T093000\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_eq(events[0].exdates[0].utc_offset, Some(8 * 3600))
}

///|
test "a feed's own VTIMEZONE wins over the built-in guesses" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:/demo/Custom-Zone\r\nBEGIN:STANDARD\r\nTZOFFSETTO:+0930\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
    "BEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=/demo/Custom-Zone:20260910T093000\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_eq(events[0].dtstart.unwrap().utc_offset, Some(9 * 3600 + 30 * 60))
}

///|
test "a RECURRENCE-ID override event keeps both its own and its series time" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID;TZID=Asia/Shanghai:20260917T093000\r\nDTSTART;TZID=Asia/Shanghai:20260918T140000\r\nSUMMARY:改期\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  let e = events[0]
  assert_eq(e.recurrence_id.unwrap().wall.day(), 17)
  assert_eq(e.dtstart.unwrap().wall.day(), 18)
  assert_eq(e.dtstart.unwrap().wall.hour(), 14)
}

///|
test "optional properties that are absent stay None, not errors" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260910T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  let e = events[0]
  assert_eq(e.uid, None)
  assert_eq(e.summary, None)
  assert_eq(e.dtend, None)
  assert_eq(e.rrule, None)
  assert_eq(e.recurrence_id, None)
  assert_eq(e.exdates.length(), 0)
  assert_false(e.all_day())
}

///|
test "unknown properties on a VEVENT are ignored, not errors" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:20260910T090000Z\r\nX-CUSTOM-PROP:whatever\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_eq(events[0].uid, Some("x"))
}

///|
test "a calendar without VEVENT yields an empty event list" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR",
  )
  assert_eq(events.length(), 0)
}

///|
test "only direct VEVENT children are mapped" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:X-CONTAINER\r\nBEGIN:VEVENT\r\nUID:buried\r\nEND:VEVENT\r\nEND:X-CONTAINER\r\nEND:VCALENDAR",
  )
  assert_eq(events.length(), 0)
}

///|
test "a malformed DTSTART is loud, not silently dropped" {
  let msg = feed_error_of(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:2026-09-10T09:00\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_true(msg.contains("malformed"))
}

///|
test "an unknown TZID on an event is an error, never a silent guess" {
  let msg = feed_error_of(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=Mars/Olympus:20260910T093000\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_true(msg.contains("unknown TZID"))
  assert_true(msg.contains("Mars/Olympus"))
}
