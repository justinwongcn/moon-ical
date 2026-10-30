///|
// RFC 5545 §3.3.10 and §3.8.5.2: recurrence sets count unique instances.
// Duplicate BYMONTH entries replay a multi-day block, not adjacent duplicates.
test "review yearly duplicate month blocks preserve unique COUNT and metadata" {
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:review\r\n" +
    "DTSTART:20260101T090000Z\r\n" +
    "RRULE:FREQ=YEARLY;BYMONTH=1,1;BYMONTHDAY=1,2;COUNT=3\r\n" +
    "RDATE:20260102T090000Z\r\nEXDATE:20260101T090000Z\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let result = @rrule.expand_series_query(events, limit=3)
  assert_true(result.exhausted)
  assert_false(result.budget_exceeded)
  assert_eq(
    result.generated_through.unwrap().to_string(),
    "2027-01-01T09:00:00Z",
  )
  assert_eq(result.occurrences.map(o => o.start.to_string()), [
    "2026-01-02T09:00:00Z", "2027-01-01T09:00:00Z",
  ])
}

///|
// Valid DATE cancellation/move are controls for the cross-VALUE refusal tests.
test "review valid DATE overrides preserve domain and complete RDATE suffix" {
  let master = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:review\r\n" +
    "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902,20260903\r\n" +
    "END:VEVENT\r\n"
  let cancelled = @rrule.expand_series_query(
    @model.parse_events(
      master +
      "BEGIN:VEVENT\r\nUID:review\r\nRECURRENCE-ID;VALUE=DATE:20260902\r\n" +
      "STATUS:CANCELLED\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
  )
  assert_true(cancelled.exhausted)
  assert_true(cancelled.has_overrides)
  assert_eq(cancelled.occurrences.map(o => o.start.wall.day()), [1, 3])
  let moved = @rrule.expand_series_query(
    @model.parse_events(
      master +
      "BEGIN:VEVENT\r\nUID:review\r\nRECURRENCE-ID;VALUE=DATE;RANGE=THISANDFUTURE:20260902\r\n" +
      "DTSTART;VALUE=DATE:20260904\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
  )
  assert_true(moved.exhausted)
  assert_eq(moved.occurrences.map(o => o.start.wall.day()), [1, 4, 5])
  assert_true(
    moved.occurrences.all(o => o.start.all_day && o.start.wall.hour() == 0),
  )
}
