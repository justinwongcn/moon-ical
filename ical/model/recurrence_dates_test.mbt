///|
fn recurrence_feed(properties : String) -> String {
  "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:r\r\n" +
  properties +
  "END:VEVENT\r\nEND:VCALENDAR\r\n"
}

///|
fn recurrence_rejection(properties : String, reason : String) -> Unit raise {
  try @model.parse_events(recurrence_feed(properties)) catch {
    @text.ParseError::BadLine(message~, ..) =>
      assert_true(message.contains(reason))
    _ => fail("expected BadLine")
  } noraise {
    _ => fail("expected rejection")
  }
}

///|
test "RDATE default UTC explicit DATE-TIME and repeated lines retain wire order" {
  // RFC 5545 3.8.5.2, default DATE-TIME and repeated property syntax.
  let event = @model.parse_events(
      recurrence_feed(
        "DTSTART:20260901T090000Z\r\nRDATE:20260903T090000Z,20260902T090000Z\r\nRDATE;VALUE=DATE-TIME:20260904T090000Z\r\n",
      ),
    )[0]
  assert_eq(event.rdates.map(dt => dt.wall.day()), [3, 2, 4])
  assert_true(event.rdates.all(dt => dt.utc_offset == Some(0)))
  assert_eq(
    @model.parse_events(recurrence_feed("DTSTART:20260901T090000Z\r\n"))[0].rdates,
    [],
  )
}

///|
test "RDATE DATE and floating DATE-TIME preserve their value types" {
  let dates = @model.parse_events(
      recurrence_feed(
        "DTSTART;VALUE=DATE:20260901\r\nRDATE;VALUE=DATE:20260902,20260903\r\n",
      ),
    )[0]
  assert_true(dates.rdates.all(dt => dt.all_day))
  let floating = @model.parse_events(
      recurrence_feed("DTSTART:20260901T090000\r\nRDATE:20260902T103000\r\n"),
    )[0]
  assert_true(floating.rdates[0].is_floating())
  assert_eq(floating.rdates[0].wall.hour(), 10)
}

///|
test "RDATE PERIOD both RFC forms fail explicitly before date parsing" {
  // RFC 5545 3.8.5.2 PERIOD example, both start/end and start/duration.
  for value in ["19960403T020000Z/19960403T040000Z", "19960404T010000Z/PT3H"] {
    recurrence_rejection(
      "RDATE;VALUE=PERIOD:" + value + "\r\n",
      "unsupported RDATE VALUE=PERIOD",
    )
  }
}

///|
test "RDATE malformed value types empty items and incompatible DTSTART are refused" {
  for
    line in [
      "RDATE:20260902", "RDATE;VALUE=DATE-TIME:20260902", "RDATE;VALUE=DATE:20260902T090000Z",
      "RDATE;VALUE=TEXT:hello", "RDATE:", "RDATE:20260902T090000Z,", "RDATE:20260902T090000Z,,20260903T090000Z",
      "RDATE;TZID=UTC;VALUE=DATE:20260902", "RDATE;TZID=UTC:20260902T090000Z", "RDATE:20260230T090000Z",
      "RDATE;TZID=Mars/Olympus:20260902T090000",
    ] {
    recurrence_rejection(line + "\r\n", "")
  }
  recurrence_rejection(
    "DTSTART;VALUE=DATE:20260901\r\nRDATE:20260902T090000Z\r\n", "value type",
  )
  recurrence_rejection(
    "DTSTART:20260901T090000\r\nRDATE:20260902T090000Z\r\n", "value type",
  )
}

///|
test "fixed TZID RDATE preserves binding and equals UTC instants" {
  let roots = @model.parse_calendar(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260901T010000Z\r\nRDATE;TZID=Fixed:20260902T093000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let zones = @model.ZoneTable::empty()
  zones.insert("Fixed", 30600)
  let event = roots[0].children[0].event(zones~).unwrap()
  assert_eq(event.rdates[0].utc_offset, Some(30600))
  assert_eq(
    event.rdates[0].compare(
      @model.parse_single_date_time("20260902T010000Z", zones),
    ),
    0,
  )
}

///|
test "Component event maps only the selected VEVENT and leaves raw PERIOD intact" {
  let roots = @model.parse_calendar(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:good\r\nDTSTART:20260901T090000Z\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:bad\r\nRDATE;VALUE=PERIOD:19960404T010000Z/PT3H\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  let zones = @model.ZoneTable::builtin_common()
  assert_true(roots[0].event(zones~) is None)
  assert_eq(roots[0].children[0].event(zones~).unwrap().uid, Some("good"))
  assert_eq(
    roots[0].children[1].property("RDATE").unwrap().value,
    "19960404T010000Z/PT3H",
  )
}
