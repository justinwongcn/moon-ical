///|
// A VTIMEZONE whose offsets change must remain readable as raw data, but
// must not acquire a single guessed offset in the typed event API.
test "facade preserves dynamic zones and refuses typed time calculation" {
  let input = "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:Test/Changing\r\n" +
    "BEGIN:STANDARD\r\nDTSTART:20261101T020000\r\n" +
    "TZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nEND:STANDARD\r\n" +
    "BEGIN:DAYLIGHT\r\nDTSTART:20260308T020000\r\n" +
    "TZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nEND:DAYLIGHT\r\n" +
    "END:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:changing\r\n" +
    "DTSTART;TZID=Test/Changing:20260701T090000\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n"
  let tree = @moon-ical.parse_calendar(input)
  assert_eq(
    @moon-ical.parse_calendar(@moon-ical.serialize_components(tree)),
    tree,
  )
  try @moon-ical.parse_events(input) catch {
    @text.ParseError::BadLine(line_no=_, line=_, message~) =>
      assert_true(message.contains("unsupported TZID"))
    err => fail("unexpected error: \{err}")
  } noraise {
    _ => fail("dynamic time zones must not become a guessed fixed offset")
  }
}
