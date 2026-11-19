///|
fn expand_strings(
  rule : String,
  start : String,
  limit : Int32,
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
    "BEGIN:VTIMEZONE\r\nTZID:PRIVATE-ZONE\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0930\r\nTZOFFSETTO:+0930\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
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

///|
test "an override without DTEND keeps the master's duration" {
  // The master runs 09:00-10:00; the override moves only the start to
  // 09:30. Before S26 the moved occurrence reported no end at all — a
  // one-hour meeting became open-ended.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:dur\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T100000Z\r\n" +
    "RRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:dur\r\nRECURRENCE-ID:20260902T090000Z\r\nDTSTART:20260902T093000Z\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.length(), 3)
  assert_eq(merged[1].start.to_string(), "2026-09-02T09:30:00Z")
  assert_eq(
    merged[1].end
    .unwrap_or(
      @model.parse_single_date_time(
        "20260101T000000Z",
        @model.ZoneTable::empty(),
      ),
    )
    .to_string(),
    "2026-09-02T10:30:00Z",
  )
}

///|
test "a group expands the series of its own UID, not any master" {
  // An override of uid=a arrives before an unrelated master of uid=b:
  // the group is about a, so there is no master to expand — before S26
  // the first master of ANY uid was picked and b's series came out.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:a\r\nRECURRENCE-ID:20260902T090000Z\r\nDTSTART:20260902T093000Z\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20260901T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let events = @model.parse_events(text)
  // The group of uid a (first event) has no master: no series.
  let merged = @rrule.expand_series(events)
  assert_eq(merged.length(), 0)
}

///|
test "a series defined by DURATION gives every occurrence an end" {
  // The master spells its length with DURATION instead of DTEND
  // (RFC 5545 3.8.5.3); expansion materializes the end per occurrence,
  // and a moved override without its own DTEND inherits the same length.
  let merged = @rrule.expand_series(
    @model.parse_events(
      "BEGIN:VCALENDAR\r\n" +
      "BEGIN:VEVENT\r\nUID:series\r\nDTSTART:20260901T090000Z\r\nDURATION:PT45M\r\n" +
      "RRULE:FREQ=DAILY;COUNT=2\r\nEND:VEVENT\r\n" +
      "BEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20260902T090000Z\r\n" +
      "DTSTART:20260902T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
  )
  assert_eq(merged.length(), 2)
  assert_eq(merged[0].end.unwrap().to_string(), "2026-09-01T09:45:00Z")
  assert_eq(merged[1].end.unwrap().to_string(), "2026-09-02T13:45:00Z")
}

///|
test "YEARLY ordinal BYDAY + BYMONTHDAY without BYMONTH is year-scoped" {
  // RFC 5545 §3.3.10 (the 20MO example): with no BYMONTH the ordinal counts
  // within the year, and BYMONTHDAY only limits — positive and negative
  // ordinals alike. The per-month reading used to emit every month that
  // starts (or ends) on the chosen weekday instead.
  assert_eq(
    expand_strings("FREQ=YEARLY;BYMONTHDAY=1;BYDAY=1MO", "20240101T090000", 4),
    [
      "2024-01-01T09:00:00", "2029-01-01T09:00:00", "2035-01-01T09:00:00", "2046-01-01T09:00:00",
    ],
  )
  assert_eq(
    expand_strings("FREQ=YEARLY;BYMONTHDAY=-1;BYDAY=-1MO", "20240101T090000", 4),
    [
      "2029-12-31T09:00:00", "2035-12-31T09:00:00", "2040-12-31T09:00:00", "2046-12-31T09:00:00",
    ],
  )
}

///|
test "THISANDFUTURE duration change becomes the duration of later instances" {
  // RFC 5545 §3.8.4.4: "if the duration of the given recurrence instance is
  // modified, then all subsequence instances are also modified to have this
  // same duration" — the override's DTEND, not the master's, governs the
  // instances after it.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nDTSTART:20260903T100000Z\r\nDTEND:20260903T120000Z\r\nSUMMARY:moved\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T09:00:00Z", "2026-09-03T10:00:00Z", "2026-09-04T10:00:00Z",
  ])
  assert_eq(merged.map(x => x.end.map(e => e.to_string())), [
    Some("2026-09-01T09:30:00Z"),
    Some("2026-09-02T09:30:00Z"),
    Some("2026-09-03T12:00:00Z"),
    Some("2026-09-04T12:00:00Z"),
  ])
}

///|
test "a duration-only THISANDFUTURE change moves every later end" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nDTSTART:20260903T090000Z\r\nDTEND:20260903T120000Z\r\nSUMMARY:longer\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2026-09-01T09:00:00Z", "2026-09-02T09:00:00Z", "2026-09-03T09:00:00Z", "2026-09-04T09:00:00Z",
  ])
  assert_eq(merged.map(x => x.end.map(e => e.to_string())), [
    Some("2026-09-01T09:30:00Z"),
    Some("2026-09-02T09:30:00Z"),
    Some("2026-09-03T12:00:00Z"),
    Some("2026-09-04T12:00:00Z"),
  ])
}

///|
test "a THISANDFUTURE override without DTEND keeps the master's shifted length" {
  // No explicit end on the override modifies no duration, so the master's
  // length survives the shift (RFC 5545 §3.8.4.4 covers only the modified
  // case; the unmodified fallback is the shift contract).
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nDTSTART:20260901T090000Z\r\nDTEND:20260901T093000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nSUMMARY:base\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:s\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20260903T090000Z\r\nDTSTART:20260903T100000Z\r\nSUMMARY:moved\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.end.map(e => e.to_string())), [
    Some("2026-09-01T09:30:00Z"),
    Some("2026-09-02T09:30:00Z"),
    Some("2026-09-03T10:30:00Z"),
    Some("2026-09-04T10:30:00Z"),
  ])
}

///|
test "an impossible ordinal BYDAY is provably empty, not a budget error" {
  // RFC 5545 §3.3.10: a month holds at most five of any weekday, a year at
  // most 53 (without BYMONTH). A rule every BYDAY entry of which is
  // impossible ends naturally empty instead of walking the period budget
  // to an error — which over CalDAV let one stored resource fail a whole
  // collection's REPORT.
  let dt = @model.parse_single_date_time(
    "20260101T090000Z",
    @model.ZoneTable::empty(),
  )
  assert_eq(
    @rrule.expand(@rrule.parse_rule("FREQ=MONTHLY;BYDAY=8MO"), dt, limit=5),
    [],
  )
  assert_eq(
    @rrule.expand(
      @rrule.parse_rule("FREQ=YEARLY;BYMONTH=2;BYDAY=8MO"),
      dt,
      limit=5,
    ),
    [],
  )
}
