///|
fn expand_strings(
  rule : String,
  start : String,
  limit : Int,
) -> Array[String] raise {
  let dtstart = @model.parse_single_date_time(start, @model.ZoneTable::empty())
  @rrule.expand(@rrule.parse_rule(rule), dtstart, limit~).map(x => x.to_string())
}

///|
test "ordinal BYDAY expands within months and years" {
  assert_eq(
    expand_strings("FREQ=MONTHLY;COUNT=4;BYDAY=1FR", "19970905T090000", 4),
    [
      "1997-09-05T09:00:00", "1997-10-03T09:00:00", "1997-11-07T09:00:00", "1997-12-05T09:00:00",
    ],
  )
  assert_eq(
    expand_strings("FREQ=MONTHLY;COUNT=4;BYDAY=-2MO", "19970922T090000", 4),
    [
      "1997-09-22T09:00:00", "1997-10-20T09:00:00", "1997-11-17T09:00:00", "1997-12-22T09:00:00",
    ],
  )
  assert_eq(expand_strings("FREQ=YEARLY;BYDAY=20MO", "19970519T090000", 3), [
    "1997-05-19T09:00:00", "1998-05-18T09:00:00", "1999-05-17T09:00:00",
  ])
}

///|
test "negative BYMONTHDAY and BYSETPOS expand" {
  assert_eq(
    expand_strings("FREQ=MONTHLY;BYMONTHDAY=-3", "19970928T090000", 6),
    [
      "1997-09-28T09:00:00", "1997-10-29T09:00:00", "1997-11-28T09:00:00", "1997-12-29T09:00:00",
      "1998-01-29T09:00:00", "1998-02-26T09:00:00",
    ],
  )
  assert_eq(
    expand_strings(
      "FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", "19970904T090000", 3,
    ),
    ["1997-09-04T09:00:00", "1997-10-07T09:00:00", "1997-11-06T09:00:00"],
  )
  assert_eq(
    expand_strings(
      "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2", "19970929T090000", 4,
    ),
    [
      "1997-09-29T09:00:00", "1997-10-30T09:00:00", "1997-11-27T09:00:00", "1997-12-30T09:00:00",
    ],
  )
  assert_eq(
    expand_strings("FREQ=MONTHLY;COUNT=6;BYMONTHDAY=1,-1", "19970930T090000", 6),
    [
      "1997-09-30T09:00:00", "1997-10-01T09:00:00", "1997-10-31T09:00:00", "1997-11-01T09:00:00",
      "1997-11-30T09:00:00", "1997-12-01T09:00:00",
    ],
  )
  assert_eq(
    expand_strings(
      "FREQ=MONTHLY;INTERVAL=2;COUNT=6;BYDAY=1SU,-1SU", "19970907T090000", 6,
    ),
    [
      "1997-09-07T09:00:00", "1997-09-28T09:00:00", "1997-11-02T09:00:00", "1997-11-30T09:00:00",
      "1998-01-04T09:00:00", "1998-01-25T09:00:00",
    ],
  )
}

///|
test "RECURRENCE-ID moves excludes and cancels instances" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXDATE:20260902T090000Z\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260903T090000Z\r\nDTSTART:20260903T110000Z\r\nDTEND:20260903T113000Z\r\nSUMMARY:moved\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID:20260904T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-03T11:00:00Z", "2026-09-05T09:00:00Z",
  ])
  assert_eq(merged[1].summary, Some("moved"))
}

///|
test "THISANDFUTURE shifts the selected and later instances" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nDTSTART:20260903T100000Z\r\nSUMMARY:shifted\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T09:00:00Z", "2026-09-03T10:00:00Z", "2026-09-04T10:00:00Z",
  ])
  assert_eq(merged[3].summary, Some("shifted"))
}

///|
test "feed ZoneTable flows through parse_events into series expansion" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VTIMEZONE\r\nTZID:PRIVATE-ZONE\r\nBEGIN:STANDARD\r\nTZOFFSETTO:+0930\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
    "BEGIN:VEVENT\r\nUID:z\r\nDTSTART;TZID=PRIVATE-ZONE:20260901T090000\r\nRRULE:FREQ=DAILY;COUNT=2\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00+09:30", "2026-09-02T09:00:00+09:30",
  ])
}
