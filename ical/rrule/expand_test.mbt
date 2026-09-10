///|
/// Run `expand` and report its error message, or "no-error" on success.
fn expand_error_of(rule : String, dtstart : @model.IcalDateTime) -> String {
  try {
    let _ = @rrule.expand(@rrule.parse_rule(rule), dtstart)
    "no-error"
  } catch {
    err => err.to_string()
  }
}

///|
test "the second-tier corpus rules are refused by name, not expanded wrongly" {
  let dtstart = @model.parse_single_date_time(
    "19970902T090000",
    @model.ZoneTable::empty(),
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR", dtstart),
    "unsupported RRULE feature in expansion: ordinal BYDAY (S8)",
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;BYMONTHDAY=-3", dtstart),
    "unsupported RRULE feature in expansion: negative BYMONTHDAY (S8)",
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", dtstart),
    "unsupported RRULE feature in expansion: BYSETPOS (S8)",
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", dtstart),
    "unsupported RRULE feature in expansion: ordinal BYDAY (S8)",
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;COUNT=6;BYDAY=-2MO", dtstart),
    "unsupported RRULE feature in expansion: ordinal BYDAY (S8)",
  )
  assert_eq(
    expand_error_of("FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1", dtstart),
    "unsupported RRULE feature in expansion: negative BYMONTHDAY (S8)",
  )
}

///|
test "COUNT and UNTIL are mutually exclusive once DTSTART is known" {
  let dtstart = @model.parse_single_date_time(
    "19970902T090000Z",
    @model.ZoneTable::empty(),
  )
  assert_eq(
    expand_error_of("FREQ=DAILY;COUNT=5;UNTIL=19971224T000000Z", dtstart),
    "invalid recurrence rule: COUNT and UNTIL are mutually exclusive",
  )
}

///|
test "UNTIL must agree with the DTSTART value type" {
  let timed = @model.parse_single_date_time(
    "19970902T090000Z",
    @model.ZoneTable::empty(),
  )
  assert_eq(
    expand_error_of("FREQ=DAILY;UNTIL=19971224", timed),
    "invalid recurrence rule: UNTIL must have the same value type as DTSTART",
  )
  let all_day = @model.parse_single_date_time(
    "19970902",
    @model.ZoneTable::empty(),
  )
  assert_eq(
    expand_error_of("FREQ=DAILY;UNTIL=19971224T000000Z", all_day),
    "invalid recurrence rule: UNTIL must have the same value type as DTSTART",
  )
}

///|
test "a DTSTART that does not match the rule is not forced into the series" {
  // The Sep 2 1997 DTSTART is a Tuesday; the first Friday the 13th after
  // it is in February 1998 — exactly what the corpus expects for the
  // same rule.
  let dtstart = @model.parse_single_date_time(
    "19970902T090000",
    @model.ZoneTable::empty(),
  )
  let rule = @rrule.parse_rule("FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13")
  let got = @rrule.expand(rule, dtstart, limit=1)
  assert_eq(got.length(), 1)
  assert_eq(got[0].to_string(), "1998-02-13T09:00:00")
}

///|
test "an all-day DTSTART expands to DATE occurrences at the same clock" {
  let dtstart = @model.parse_single_date_time(
    "20260901",
    @model.ZoneTable::empty(),
  )
  let rule = @rrule.parse_rule("FREQ=WEEKLY;COUNT=3")
  let got = @rrule.expand(rule, dtstart)
  assert_eq(got.length(), 3)
  for occurrence in got {
    assert_true(occurrence.all_day)
  }
  assert_eq(got[0].to_string(), "2026-09-01")
  assert_eq(got[1].to_string(), "2026-09-08")
  assert_eq(got[2].to_string(), "2026-09-15")
}

///|
test "UNTIL bounds the series inclusively by instant" {
  // The occurrence at exactly the UNTIL instant is the last one kept:
  // 09:00 at -05:00 is 14:00Z, which is the UNTIL value itself.
  let dtstart = @model.parse_single_date_time(
    "20000131T090000",
    @model.ZoneTable::empty(),
  )
  // Give the floating DTSTART a New York offset via a TZID line, so the
  // 14:00Z arithmetic is exercised for real.
  let line = @text.parse_content_line(
    "DTSTART;TZID=America/New_York:20000131T090000", 1,
  )
  let ny = @model.parse_date_time(line, @model.ZoneTable::builtin_common())
  assert_eq(ny.utc_offset, Some(-5 * 3600))
  let rule = @rrule.parse_rule("FREQ=DAILY;UNTIL=20000201T140000Z")
  let got = @rrule.expand(rule, ny)
  // Feb 1 09:00 at -05:00 is exactly 14:00Z: included; Feb 2 is past.
  assert_eq(got.length(), 2)
  assert_eq(got[0].to_string(), "2000-01-31T09:00:00-05:00")
  assert_eq(got[1].to_string(), "2000-02-01T09:00:00-05:00")
  let _ = dtstart
}

///|
test "limit caps an unbounded rule without touching its first occurrences" {
  let dtstart = @model.parse_single_date_time(
    "20260901T090000Z",
    @model.ZoneTable::empty(),
  )
  let rule = @rrule.parse_rule("FREQ=DAILY;INTERVAL=2")
  let got = @rrule.expand(rule, dtstart, limit=3)
  assert_eq(got.length(), 3)
  assert_eq(got[2].to_string(), "2026-09-05T09:00:00Z")
}

///|
test "a rule whose dates never exist terminates with an empty series" {
  // February 30 does not exist in any year; the period walk must end.
  let dtstart = @model.parse_single_date_time(
    "20260101T090000Z",
    @model.ZoneTable::empty(),
  )
  let rule = @rrule.parse_rule("FREQ=MONTHLY;BYMONTH=2;BYMONTHDAY=30")
  let got = @rrule.expand(rule, dtstart)
  assert_eq(got.length(), 0)
}

///|
test "WKST defaults to Monday and only matters near a week boundary" {
  // With DTSTART on a Tuesday, BYDAY=TU,SU under the default (Monday)
  // week start matches the corpus's WKST=MO expectations.
  let line = @text.parse_content_line(
    "DTSTART;TZID=America/New_York:19970805T090000", 1,
  )
  let dtstart = @model.parse_date_time(line, @model.ZoneTable::builtin_common())
  let rule = @rrule.parse_rule("FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU")
  let got = @rrule.expand(rule, dtstart)
  assert_eq(got.map(o => o.to_string()), [
    "1997-08-05T09:00:00-05:00", "1997-08-10T09:00:00-05:00", "1997-08-19T09:00:00-05:00",
    "1997-08-24T09:00:00-05:00",
  ])
}
