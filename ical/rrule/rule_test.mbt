///|
/// Run `parse_rule` and report its error message, or "no-error" on success.
fn rule_error_of(rule : String) -> String {
  try {
    let _ = @rrule.parse_rule(rule)
    "no-error"
  } catch {
    err => err.to_string()
  }
}

///|
test "a bare FREQ parses with interval and wkst defaulted" {
  let rule = @rrule.parse_rule("FREQ=DAILY")
  assert_true(rule.freq is @rrule.Freq::Daily)
  assert_eq(rule.interval, 1)
  assert_eq(rule.count, None)
  assert_eq(rule.until, None)
  assert_eq(rule.byday.length(), 0)
  assert_eq(rule.bymonthday.length(), 0)
  assert_eq(rule.bymonth.length(), 0)
  assert_eq(rule.bysetpos.length(), 0)
  assert_eq(rule.wkst, @time.Weekday::Monday)
}

///|
test "clause names and values are case-insensitive and the RRULE prefix is optional" {
  let rule = @rrule.parse_rule("rrule:freq=weekly;byday=tu,th;count=10;wkst=su")
  assert_true(rule.freq is @rrule.Freq::Weekly)
  assert_eq(rule.count, Some(10))
  assert_eq(rule.wkst, @time.Weekday::Sunday)
  assert_eq(rule.byday.length(), 2)
  assert_eq(rule.byday[0].ordinal, 0)
  assert_true(rule.byday[0].weekday is @time.Weekday::Tuesday)
  assert_true(rule.byday[1].weekday is @time.Weekday::Thursday)
}

///|
test "INTERVAL and COUNT must be positive integers" {
  assert_eq(@rrule.parse_rule("FREQ=DAILY;INTERVAL=2").interval, 2)
  assert_eq(
    rule_error_of("FREQ=DAILY;INTERVAL=0"),
    "invalid RRULE: INTERVAL must be a positive integer: 0 (in `FREQ=DAILY;INTERVAL=0`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;INTERVAL=x"),
    "invalid RRULE: malformed INTERVAL value: x (in `FREQ=DAILY;INTERVAL=x`)",
  )
  assert_eq(@rrule.parse_rule("FREQ=DAILY;COUNT=10").count, Some(10))
  assert_eq(
    rule_error_of("FREQ=DAILY;COUNT=0"),
    "invalid RRULE: COUNT must be a positive integer: 0 (in `FREQ=DAILY;COUNT=0`)",
  )
}

///|
test "UNTIL keeps the four-state date-time shape" {
  let utc = @rrule.parse_rule("FREQ=DAILY;UNTIL=19971224T000000Z")
  assert_eq(utc.until.unwrap().to_string(), "1997-12-24T00:00:00Z")
  let floating = @rrule.parse_rule("FREQ=DAILY;UNTIL=19971224T000000")
  assert_eq(floating.until.unwrap().to_string(), "1997-12-24T00:00:00")
  let day = @rrule.parse_rule("FREQ=DAILY;UNTIL=19971224")
  assert_eq(day.until.unwrap().to_string(), "1997-12-24")
  assert_eq(
    rule_error_of("FREQ=DAILY;UNTIL=garbage"),
    "invalid RRULE: malformed UNTIL value: garbage (in `FREQ=DAILY;UNTIL=garbage`)",
  )
}

///|
test "BYDAY accepts plain, ordinal, and negative-ordinal weekdays" {
  let rule = @rrule.parse_rule("FREQ=MONTHLY;BYDAY=TU,1FR,-2MO,20MO,-1SU")
  assert_eq(rule.byday.length(), 5)
  assert_eq(rule.byday[0].ordinal, 0)
  assert_true(rule.byday[0].weekday is @time.Weekday::Tuesday)
  assert_eq(rule.byday[1].ordinal, 1)
  assert_true(rule.byday[1].weekday is @time.Weekday::Friday)
  assert_eq(rule.byday[2].ordinal, -2)
  assert_true(rule.byday[2].weekday is @time.Weekday::Monday)
  assert_eq(rule.byday[3].ordinal, 20)
  assert_true(rule.byday[3].weekday is @time.Weekday::Monday)
  assert_eq(rule.byday[4].ordinal, -1)
  assert_true(rule.byday[4].weekday is @time.Weekday::Sunday)
}

///|
test "BYDAY rejects zero and out-of-range ordinals and bad codes" {
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYDAY=0TU"),
    "invalid RRULE: malformed BYDAY value: 0TU (in `FREQ=MONTHLY;BYDAY=0TU`)",
  )
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYDAY=54TU"),
    "invalid RRULE: malformed BYDAY value: 54TU (in `FREQ=MONTHLY;BYDAY=54TU`)",
  )
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYDAY=XX"),
    "invalid RRULE: malformed BYDAY value: XX (in `FREQ=MONTHLY;BYDAY=XX`)",
  )
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYDAY=-TU"),
    "invalid RRULE: malformed BYDAY value: -TU (in `FREQ=MONTHLY;BYDAY=-TU`)",
  )
}

///|
test "BYMONTHDAY, BYMONTH, and BYSETPOS take bounded integer lists" {
  let rule = @rrule.parse_rule(
    "FREQ=MONTHLY;BYMONTHDAY=1,-1,31;BYMONTH=1,12;BYSETPOS=3,-366",
  )
  assert_eq(rule.bymonthday, [1, -1, 31])
  assert_eq(rule.bymonth, [1, 12])
  assert_eq(rule.bysetpos, [3, -366])
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYMONTHDAY=0"),
    "invalid RRULE: BYMONTHDAY value out of range: 0 (in `FREQ=MONTHLY;BYMONTHDAY=0`)",
  )
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYMONTHDAY=32"),
    "invalid RRULE: BYMONTHDAY value out of range: 32 (in `FREQ=MONTHLY;BYMONTHDAY=32`)",
  )
  assert_eq(
    rule_error_of("FREQ=YEARLY;BYMONTH=0"),
    "invalid RRULE: BYMONTH value out of range: 0 (in `FREQ=YEARLY;BYMONTH=0`)",
  )
  assert_eq(
    rule_error_of("FREQ=YEARLY;BYMONTH=13"),
    "invalid RRULE: BYMONTH value out of range: 13 (in `FREQ=YEARLY;BYMONTH=13`)",
  )
  assert_eq(
    rule_error_of("FREQ=YEARLY;BYMONTH=-1"),
    "invalid RRULE: malformed BYMONTH value: -1 (in `FREQ=YEARLY;BYMONTH=-1`)",
  )
  assert_eq(
    rule_error_of("FREQ=MONTHLY;BYSETPOS=367"),
    "invalid RRULE: BYSETPOS value out of range: 367 (in `FREQ=MONTHLY;BYSETPOS=367`)",
  )
}

///|
test "the never-supported frequencies and clauses are rejected loudly" {
  assert_eq(
    rule_error_of("FREQ=HOURLY;INTERVAL=3"),
    "invalid RRULE: unsupported FREQ: HOURLY (in `FREQ=HOURLY;INTERVAL=3`)",
  )
  assert_eq(
    rule_error_of("FREQ=MINUTELY;INTERVAL=15;COUNT=6"),
    "invalid RRULE: unsupported FREQ: MINUTELY (in `FREQ=MINUTELY;INTERVAL=15;COUNT=6`)",
  )
  assert_eq(
    rule_error_of("FREQ=SECONDLY"),
    "invalid RRULE: unsupported FREQ: SECONDLY (in `FREQ=SECONDLY`)",
  )
  assert_eq(
    rule_error_of("FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO"),
    "invalid RRULE: unsupported RRULE clause: BYWEEKNO (in `FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO`)",
  )
  assert_eq(
    rule_error_of("FREQ=YEARLY;BYYEARDAY=1,100,200"),
    "invalid RRULE: unsupported RRULE clause: BYYEARDAY (in `FREQ=YEARLY;BYYEARDAY=1,100,200`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;BYHOUR=9,10"),
    "invalid RRULE: unsupported RRULE clause: BYHOUR (in `FREQ=DAILY;BYHOUR=9,10`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;BYMINUTE=0,20,40"),
    "invalid RRULE: unsupported RRULE clause: BYMINUTE (in `FREQ=DAILY;BYMINUTE=0,20,40`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;BYSECOND=10,20,30"),
    "invalid RRULE: unsupported RRULE clause: BYSECOND (in `FREQ=DAILY;BYSECOND=10,20,30`)",
  )
}

///|
test "FREQ is required exactly once and other clauses at most once" {
  assert_eq(
    rule_error_of("INTERVAL=2"),
    "invalid RRULE: missing FREQ clause (in `INTERVAL=2`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;FREQ=WEEKLY"),
    "invalid RRULE: duplicate clause: FREQ (in `FREQ=DAILY;FREQ=WEEKLY`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;COUNT=5;COUNT=6"),
    "invalid RRULE: duplicate clause: COUNT (in `FREQ=DAILY;COUNT=5;COUNT=6`)",
  )
}

///|
test "malformed rule shapes are rejected" {
  assert_eq(rule_error_of(""), "invalid RRULE: empty rule part (in ``)")
  assert_eq(
    rule_error_of("FREQ DAILY"),
    "invalid RRULE: malformed rule part: FREQ DAILY (in `FREQ DAILY`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;;COUNT=1"),
    "invalid RRULE: empty rule part (in `FREQ=DAILY;;COUNT=1`)",
  )
  assert_eq(
    rule_error_of("FREQ=DAILY;XMONTH=3"),
    "invalid RRULE: unknown RRULE clause: XMONTH (in `FREQ=DAILY;XMONTH=3`)",
  )
  assert_eq(
    rule_error_of("FREQ=WEELY"),
    "invalid RRULE: unknown FREQ: WEELY (in `FREQ=WEELY`)",
  )
  assert_eq(
    rule_error_of("FREQ="),
    "invalid RRULE: unknown FREQ:  (in `FREQ=`)",
  )
}
