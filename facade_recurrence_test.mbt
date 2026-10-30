///|
// RFC 5545 §3.8.5.2: RDATE joins the recurrence set; EXDATE wins.
test "facade RDATE adds an instance and EXDATE removes it" {
  let head = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:rdate\r\n" +
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\n"
  let tail = "END:VEVENT\r\nEND:VCALENDAR\r\n"
  let original = @moon-ical.expand_series(@moon-ical.parse_events(head + tail))
  let added = @moon-ical.expand_series(
    @moon-ical.parse_events(head + "RDATE:20260904T090000Z\r\n" + tail),
  )
  let removed = @moon-ical.expand_series(
    @moon-ical.parse_events(
      head + "RDATE:20260904T090000Z\r\nEXDATE:20260904T090000Z\r\n" + tail,
    ),
  )
  assert_eq(original.length(), 2)
  assert_eq(added.length(), 3)
  assert_eq(added[2].start.to_string(), "2026-09-04T09:00:00Z")
  assert_eq(removed, original)
}

///|
test "facade preserves unsupported PERIOD without claiming typed support" {
  let input = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:period\r\n" +
    "DTSTART:20260901T090000Z\r\n" +
    "RDATE;VALUE=PERIOD:20260904T090000Z/PT1H\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n"
  let tree = @moon-ical.parse_calendar(input)
  let written = @moon-ical.serialize_components(tree)
  assert_eq(@moon-ical.parse_calendar(written), tree)
  try @moon-ical.parse_events(input) catch {
    @text.ParseError::BadLine(line_no=_, line=_, message~) =>
      assert_true(message.contains("PERIOD"))
    err => fail("unexpected error: \{err}")
  } noraise {
    _ => fail("PERIOD must not be silently dropped")
  }
}
