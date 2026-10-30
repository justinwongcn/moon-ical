///|
fn series_events(
  properties : String,
  overrides~ : String = "",
) -> Array[@model.Event] raise {
  @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s\r\n" +
    properties +
    "END:VEVENT\r\n" +
    overrides +
    "END:VCALENDAR\r\n",
  )
}

///|
test "RDATE unions deduplicates and is independent of COUNT UNTIL and DTSTART boundary" {
  // RFC 5545 3.8.5.2: union, duplicates ignored, exclusions take precedence.
  let events = series_events(
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nRDATE:20260902T090000Z,20260831T090000Z,20260905T090000Z\r\nRDATE:20260905T090000Z,20260901T090000Z\r\n",
  )
  assert_eq(@rrule.expand_series(events).map(o => o.start.wall.day()), [
    31, 1, 2, 5,
  ])
  let bounded = series_events(
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;UNTIL=20260902T090000Z\r\nRDATE:20260905T090000Z\r\n",
  )
  assert_eq(@rrule.expand_series(bounded).map(o => o.start.wall.day()), [
    1, 2, 5,
  ])
  let once = series_events(
    "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902,20260903\r\n",
  )
  assert_eq(@rrule.expand_series(once).map(o => o.start.wall.day()), [1, 2, 3])
  assert_true(@rrule.expand_series(once).all(o => o.start.all_day))
}

///|
test "EXDATE removes RDATE and entire filtered set is honestly empty" {
  let result = @rrule.expand_series_query(
    series_events(
      "DTSTART:20260901T090000Z\r\nRDATE:20260902T090000Z\r\nEXDATE:20260901T090000Z,20260902T090000Z\r\n",
    ),
  )
  assert_eq(result.occurrences, [])
  assert_true(result.exhausted)
  assert_false(result.budget_exceeded)
}

///|
test "RDATE slots participate in exact override cancellation future shifts and duration" {
  let events = series_events(
    "DTSTART:20260901T090000Z\r\nDURATION:PT1H\r\nRDATE:20260902T090000Z,20260903T090000Z,20260904T090000Z\r\n",
    overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260902T090000Z\r\nDTSTART:20260902T110000Z\r\nEND:VEVENT\r\n" +
      "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nDTSTART:20260903T100000Z\r\nEND:VEVENT\r\n" +
      "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260904T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n",
  )
  let result = @rrule.expand_series_query(events)
  assert_true(result.has_overrides)
  assert_eq(result.occurrences.map(o => o.start.wall.hour()), [9, 11, 10])
  assert_eq(result.occurrences[1].recurrence_id.wall.hour(), 9)
  assert_eq(result.occurrences[1].end.unwrap().wall.hour(), 12)
  assert_eq(result.occurrences[2].end.unwrap().wall.hour(), 11)
}

///|
test "far RDATE and exclusions do not fake raw RRULE frontier or exhaustion" {
  let events = series_events(
    "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY\r\nRDATE:20990101T090000Z,20990102T090000Z\r\nEXDATE:20260901T090000Z,20260902T090000Z\r\n",
  )
  let result = @rrule.expand_series_query(events, limit=2)
  assert_false(result.exhausted)
  assert_false(result.budget_exceeded)
  assert_eq(
    result.generated_through.unwrap().to_string(),
    "2026-09-02T09:00:00Z",
  )
  assert_eq(result.occurrences.length(), 2)
  assert_eq(result.occurrences[0].start.wall.year(), 2099)
  let zero = @rrule.expand_series_query(events, limit=0)
  assert_false(zero.exhausted)
  assert_true(zero.generated_through is None)
  assert_eq(zero.occurrences.length(), 2)
}

///|
test "future moved slot cannot claim a complete prefix even when output frontier is far" {
  let result = @rrule.expand_series_query(
    series_events(
      "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=100\r\n",
      overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20261001T090000Z\r\nDTSTART:20260901T120000Z\r\nEND:VEVENT\r\n",
    ),
    limit=2,
  )
  assert_false(result.exhausted)
  assert_true(result.has_overrides)
  assert_eq(result.generated_through.unwrap().wall.day(), 2)
  assert_eq(result.occurrences.length(), 2)
}

///|
test "recurrence without DTSTART and cross-domain overrides are refused" {
  for
    events in [
      series_events("RRULE:FREQ=DAILY;COUNT=2\r\n"),
      series_events("RDATE:20260901T000000Z\r\n"),
      series_events(
        "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902\r\n",
        overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260902T000000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n",
      ),
      series_events(
        "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902\r\n",
        overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;VALUE=DATE:20260902\r\nDTSTART:20260902T090000Z\r\nEND:VEVENT\r\n",
      ),
      series_events(
        "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902\r\n",
        overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;VALUE=DATE;RANGE=THISANDFUTURE:20260902\r\nDTSTART:20260902T090000Z\r\nEND:VEVENT\r\n",
      ),
      series_events(
        "DTSTART:20260901T090000\r\nRRULE:FREQ=DAILY;COUNT=2\r\n",
        overrides="BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260902T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n",
      ),
    ] {
    try @rrule.expand_series_query(events) catch {
      @rrule.ExpandError::Invalid(_) => ()
      _ => fail("expected Invalid")
    } noraise {
      _ => fail("unsupported recurrence domain guessed")
    }
  }
}

///|
test "raw RRULE duplicates are removed before COUNT and EXDATE" {
  for days in ["1,1", "1,-31"] {
    let events = series_events(
      "DTSTART:20260101T090000Z\r\nRRULE:FREQ=MONTHLY;BYMONTHDAY=" +
      days +
      ";COUNT=2\r\nEXDATE:20260101T090000Z\r\n",
    )
    let out = @rrule.expand_series(events)
    assert_eq(out.map(o => o.start.to_string()), ["2026-02-01T09:00:00Z"])
  }
}

///|
test "bounded and empty period budget exhaustion never claims completeness" {
  for suffix in [";COUNT=100", ";UNTIL=21001231T000000Z", ""] {
    let rule = "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=29" + suffix
    let events = series_events(
      "DTSTART:20260101T000000Z\r\nRRULE:" + rule + "\r\n",
    )
    let result = @rrule.expand_series_query(events, limit=100)
    assert_true(result.budget_exceeded)
    assert_false(result.exhausted)
    try @rrule.expand_series(events, limit=100) catch {
      @rrule.ExpandError::Invalid(_) => ()
      _ => fail("expected Invalid")
    } noraise {
      _ => fail("series budget shortfall")
    }
    try
      @rrule.expand(
        @rrule.parse_rule(rule),
        events[0].dtstart.unwrap(),
        limit=100,
      )
    catch {
      @rrule.ExpandError::Invalid(_) => ()
      _ => fail("expected Invalid")
    } noraise {
      _ => fail("raw budget shortfall")
    }
  }
  let empty = @rrule.expand_series_query(
    series_events(
      "DTSTART:20260101T000000Z\r\nRRULE:FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30\r\n",
    ),
  )
  assert_true(empty.budget_exceeded)
  assert_false(empty.exhausted)
  assert_eq(empty.occurrences, [])
}

///|
test "period budget shortfall is explicit independently of output filtering" {
  let events = series_events(
    "DTSTART:20260228T000000Z\r\nRRULE:FREQ=WEEKLY;BYMONTHDAY=-1\r\n",
  )
  let result = @rrule.expand_series_query(events, limit=5000)
  assert_false(result.exhausted)
  assert_true(result.budget_exceeded)
  try @rrule.expand_series(events, limit=5000) catch {
    @rrule.ExpandError::Invalid(message~) =>
      assert_true(message.contains("exceeded 10000 periods"))
    _ => fail("expected Invalid")
  } noraise {
    _ => fail("budget shortfall returned silently")
  }
  let bounded = @rrule.expand_series_query(
    series_events(
      "DTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nEXDATE:20260902T090000Z\r\n",
    ),
    limit=2,
  )
  assert_true(bounded.exhausted)
  assert_eq(bounded.generated_through.unwrap().wall.day(), 2)
  assert_eq(bounded.occurrences.length(), 1)
}
