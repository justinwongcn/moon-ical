///|
test "root facade parses and expands a series" {
  let events = parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:demo\r\n" +
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let occurrences = expand_series(events)
  assert_eq(occurrences.length(), 3)
  assert_eq(occurrences[2].start.to_string(), "2026-09-03T09:00:00Z")
}
