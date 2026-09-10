///|
/// The RRULE strings of graham's rrule test suite
/// (`.survey/src/graham_rrule/basic_test.go`): every rule string its
/// `basic_test.go` feeds to `Parse`, which is the RFC 5545 Appendix A set
/// in full, plus the RFC 2445-era sub-daily examples graham kept and the
/// WKST variants of the "every other week on Tuesday and Sunday" example.
/// Counted as strings rather than examples, the corpus is 40: the 32
/// below, whose clauses all sit inside the project's support boundary
/// (docs/development.html §08), and the 8 in `corpus_unsupported`, which
/// must be rejected with an explicit error.
fn corpus_supported() -> Array[String] {
  [
    "RRULE:FREQ=DAILY;COUNT=10", "RRULE:FREQ=DAILY;UNTIL=19971224T000000Z", "RRULE:FREQ=DAILY;INTERVAL=2",
    "RRULE:FREQ=DAILY;INTERVAL=10;COUNT=5", "RRULE:FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA",
    "RRULE:FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1", "RRULE:FREQ=WEEKLY;COUNT=10",
    "RRULE:FREQ=WEEKLY;UNTIL=19971007T000000Z;WKST=SU;BYDAY=TU,TH", "RRULE:FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH",
    "RRULE:FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR",
    "RRULE:FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR", "RRULE:FREQ=MONTHLY;BYMONTHDAY=-3",
    "RRULE:FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3", "RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2",
    "RRULE:FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU", "RRULE:FREQ=MONTHLY;COUNT=6;BYDAY=-2MO",
    "RRULE:FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1", "RRULE:FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15",
    "RRULE:FREQ=YEARLY;COUNT=10;BYMONTH=6,7", "RRULE:FREQ=YEARLY;BYDAY=20MO", "RRULE:FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15",
    "RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=TU", "RRULE:FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3",
    "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=TH", "RRULE:FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8",
    "RRULE:FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13", "RRULE:FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13",
    "RRULE:FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8",
    "RRULE:FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU",
    "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU",
  ]
}

///|
/// The corpus strings exercising the clauses outside the support boundary:
/// each must fail with the exact unsupported error, paired here with the
/// reason string its error message must carry.
fn corpus_unsupported() -> Array[(String, String)] {
  [
    (
      "RRULE:FREQ=HOURLY;INTERVAL=3;UNTIL=19970902T210000Z", "unsupported FREQ: HOURLY",
    ),
    ("RRULE:FREQ=MINUTELY;INTERVAL=15;COUNT=6", "unsupported FREQ: MINUTELY"),
    ("RRULE:FREQ=MINUTELY;INTERVAL=90;COUNT=4", "unsupported FREQ: MINUTELY"),
    (
      "RRULE:FREQ=MINUTELY;INTERVAL=20;BYHOUR=9,10,11,12,13,14,15,16", "unsupported FREQ: MINUTELY",
    ),
    (
      "RRULE:FREQ=HOURLY;BYMINUTE=0,20,40;BYSECOND=10,20,30", "unsupported FREQ: HOURLY",
    ),
    (
      "RRULE:FREQ=DAILY;BYHOUR=9,10,11,12,13,14,15,16;BYMINUTE=0,20,40", "unsupported RRULE clause: BYHOUR",
    ),
    (
      "RRULE:FREQ=YEARLY;BYYEARDAY=1,100,200", "unsupported RRULE clause: BYYEARDAY",
    ),
    (
      "RRULE:FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO", "unsupported RRULE clause: BYWEEKNO",
    ),
  ]
}

///|
test "corpus: the 32 in-boundary rule strings all parse" {
  for rule_str in corpus_supported() {
    let problem = try {
      let _ = @rrule.parse_rule(rule_str)
      "ok"
    } catch {
      err => "`\{rule_str}`: \{err.to_string()}"
    }
    assert_eq(problem, "ok")
  }
}

///|
test "corpus: the 8 out-of-boundary rule strings are rejected" {
  for entry in corpus_unsupported() {
    let (rule_str, reason) = entry
    let outcome = try {
      let _ = @rrule.parse_rule(rule_str)
      "parsed"
    } catch {
      err => err.to_string()
    }
    assert_eq(outcome, "invalid RRULE: \{reason} (in `\{rule_str}`)")
  }
}

///|
test "corpus spot check: the five-clause election-day rule" {
  let rule = @rrule.parse_rule(
    "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8",
  )
  assert_true(rule.freq is @rrule.Freq::Yearly)
  assert_eq(rule.interval, 4)
  assert_eq(rule.count, None)
  assert_eq(rule.until, None)
  assert_eq(rule.bymonth, [11])
  assert_eq(rule.byday.length(), 1)
  assert_eq(rule.byday[0].ordinal, 0)
  assert_true(rule.byday[0].weekday is @time.Weekday::Tuesday)
  assert_eq(rule.bymonthday, [2, 3, 4, 5, 6, 7, 8])
  assert_eq(rule.wkst, @time.Weekday::Monday)
}

///|
test "corpus spot check: every-other-week with UNTIL, WKST, and BYDAY" {
  let rule = @rrule.parse_rule(
    "FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR",
  )
  assert_true(rule.freq is @rrule.Freq::Weekly)
  assert_eq(rule.interval, 2)
  assert_eq(rule.until.unwrap().to_string(), "1997-12-24T00:00:00Z")
  assert_eq(rule.wkst, @time.Weekday::Sunday)
  assert_eq(rule.byday.length(), 3)
  assert_true(rule.byday[0].weekday is @time.Weekday::Monday)
  assert_true(rule.byday[1].weekday is @time.Weekday::Wednesday)
  assert_true(rule.byday[2].weekday is @time.Weekday::Friday)
}

///|
test "corpus spot check: ordinal and negative-ordinal BYDAY in one rule" {
  let rule = @rrule.parse_rule(
    "FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU",
  )
  assert_eq(rule.interval, 2)
  assert_eq(rule.count, Some(10))
  assert_eq(rule.byday.length(), 2)
  assert_eq(rule.byday[0].ordinal, 1)
  assert_true(rule.byday[0].weekday is @time.Weekday::Sunday)
  assert_eq(rule.byday[1].ordinal, -1)
  assert_true(rule.byday[1].weekday is @time.Weekday::Sunday)
}

///|
test "corpus spot check: BYSETPOS and negative BYMONTHDAY survive parsing" {
  let rule = @rrule.parse_rule("FREQ=MONTHLY;COUNT=3;BYDAY=TU,WE,TH;BYSETPOS=3")
  assert_eq(rule.count, Some(3))
  assert_eq(rule.bysetpos, [3])
  assert_eq(rule.byday.length(), 3)
  let neg = @rrule.parse_rule("FREQ=MONTHLY;BYMONTHDAY=-3")
  assert_eq(neg.bymonthday, [-3])
}
