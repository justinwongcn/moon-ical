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
test "normalized month days respect leap lengths and leave the parsed rule intact" {
  let rule = @rrule.parse_rule(
    "FREQ=MONTHLY;BYMONTHDAY=31,-1,28,29,30;BYSETPOS=-1;COUNT=5",
  )
  let wire_order = rule.bymonthday.copy()
  let start = @model.parse_single_date_time(
    "20240228T090000Z",
    @model.ZoneTable::empty(),
  )
  let got = @rrule.expand(rule, start).map(x => x.to_string())
  assert_eq(got, [
    "2024-02-29T09:00:00Z", "2024-03-31T09:00:00Z", "2024-04-30T09:00:00Z", "2024-05-31T09:00:00Z",
    "2024-06-30T09:00:00Z",
  ])
  assert_eq(rule.bymonthday, wire_order)
  assert_eq(rule.bysetpos, [-1])
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

///|
test "a series without a master, DTSTART, or RRULE degrades to the base case" {
  assert_eq(
    @rrule.expand_series(
      @model.parse_events("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"),
    ),
    [],
  )
  let no_dtstart = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:empty\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
  assert_eq(@rrule.expand_series(@model.parse_events(no_dtstart)), [])
  let no_rrule = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:once\r\nDTSTART:20260901T090000Z\r\nSUMMARY:once\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
  assert_eq(
    @rrule.expand_series(@model.parse_events(no_rrule)).map(x => {
      x.start.to_string()
    }),
    ["2026-09-01T09:00:00Z"],
  )
}

///|
test "a cancelled THISANDFUTURE removes every instance it would have shifted" {
  // File order puts the later RECURRENCE-ID first, so the merge index
  // genuinely has to sort its future overrides before applying them.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260904T090000Z\r\nDTSTART:20260904T120000Z\r\nDTEND:20260904T123000Z\r\nSUMMARY:moved\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260902T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-04T12:00:00Z",
  ])
  assert_eq(merged[1].summary, Some("moved"))
  assert_eq(merged[1].end.map(e => e.to_string()), Some("2026-09-04T12:30:00Z"))
}

///|
test "a THISANDFUTURE override without a DTSTART is skipped wherever it acts" {
  // At its own slot the override is an exact match with nothing to show;
  // at later slots it is the active future override, still with no
  // DTSTART to shift from — both shapes must be skipped, not crash.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T100000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T09:00:00Z",
  ])
}

///|
test "a moved instance without its own summary inherits the series summary" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260902T090000Z\r\nDTSTART:20260902T110000Z\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T11:00:00Z", "2026-09-03T11:00:00Z", "2026-09-04T11:00:00Z",
  ])
  // The exact override itself carries no summary; the shifted instances
  // fall back to the series summary, and the duration travels with them.
  assert_eq(merged[0].summary, Some("base"))
  assert_eq(merged[1].summary, None)
  assert_eq(merged[2].summary, Some("base"))
  assert_eq(merged[2].end.map(e => e.to_string()), Some("2026-09-03T11:30:00Z"))
}

///|
test "series merge ignores overrides from another UID" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:target\r\nDTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:other\r\nRECURRENCE-ID:20260902T090000Z\r\nDTSTART:20260902T120000Z\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T09:00:00Z", "2026-09-03T09:00:00Z",
  ])
}
