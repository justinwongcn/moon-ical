///|
fn duration_result(text : String) -> String {
  try {
    let seconds = @model.parse_duration(text, line_no=1, raw=text)
    "ok:\{seconds}"
  } catch {
    err => "err:\{err.to_string()}"
  }
}

///|
test "the RFC 5545 duration grammar parses in full" {
  // RFC 5545 3.3.6: sign P (nW | nD [T nH [nM [nS]]]).
  assert_eq(duration_result("P1W"), "ok:604800")
  assert_eq(duration_result("P1D"), "ok:86400")
  assert_eq(duration_result("PT1H"), "ok:3600")
  assert_eq(duration_result("PT1H30M"), "ok:5400")
  assert_eq(duration_result("PT30M"), "ok:1800")
  assert_eq(duration_result("PT45S"), "ok:45")
  assert_eq(duration_result("P1DT2H"), "ok:93600")
  assert_eq(duration_result("PT0S"), "ok:0")
  assert_eq(duration_result("+P1D"), "ok:86400")
  assert_eq(duration_result("-PT1H"), "ok:-3600")
  assert_eq(
    duration_result("P1DT"),
    "err:line 1: malformed duration, no components after T: P1DT (in `P1DT`)",
  )
  // Leading zeros are 1*DIGIT like any other run.
  assert_eq(duration_result("PT01H"), "ok:3600")
}

///|
test "the duration grammar is strict about order and combination" {
  // RFC 5545 3.3.6: W stands alone; H/M/S come only after T and in
  // order (S never directly after H); components never repeat.
  let cases = [
    // H without the T designator.
    (
      "P1H", "err:line 1: malformed duration designator or order: P1H (in `P1H`)",
    ),
    // Weeks combine with nothing.
    (
      "P1W1D", "err:line 1: malformed duration designator or order: P1W1D (in `P1W1D`)",
    ),
    // Days after hours.
    (
      "PT1H1D", "err:line 1: malformed duration designator or order: PT1H1D (in `PT1H1D`)",
    ),
    // Seconds straight after hours: the grammar routes S through M.
    (
      "PT1H1S", "err:line 1: malformed duration designator or order: PT1H1S (in `PT1H1S`)",
    ),
    // Repeated days.
    (
      "P1D1D", "err:line 1: malformed duration designator or order: P1D1D (in `P1D1D`)",
    ),
    // No designator where P belongs.
    ("1D", "err:line 1: malformed duration, expected P: 1D (in `1D`)"),
    ("P", "err:line 1: malformed duration, no components: P (in `P`)"),
    ("PT", "err:line 1: malformed duration, no components after T: PT (in `PT`)"),
    ("PW", "err:line 1: malformed duration, expected a number: PW (in `PW`)"),
    ("PD", "err:line 1: malformed duration, expected a number: PD (in `PD`)"),
    ("PX", "err:line 1: malformed duration, expected a number: PX (in `PX`)"),
    // A number that names no unit.
    (
      "P1", "err:line 1: malformed duration, number without a designator: P1 (in `P1`)",
    ),
  ]
  for pair in cases {
    let (text, expected) = pair
    assert_eq(duration_result(text), expected)
  }
}

///|
test "a VEVENT's DURATION becomes its end when DTEND is absent" {
  // RFC 5545 3.8.5.3 offers DURATION as the alternative end; before S29
  // the property was ignored and the event had no end at all.
  let events = @model.parse_events(
    "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:dur\r\n" +
    "DTSTART:20260901T090000Z\r\nDURATION:PT1H30M\r\nSUMMARY:sync\r\n" +
    "END:VEVENT\r\nEND:VCALENDAR\r\n",
  )
  assert_eq(events.length(), 1)
  assert_eq(events[0].dtend.unwrap().to_string(), "2026-09-01T10:30:00Z")
}

///|
test "DTEND and DURATION on one VEVENT is the loud spec violation" {
  // RFC 5545 3.8.5.3: DTEND and DURATION MUST NOT both be present —
  // which end applies would be a guess.
  let error = try {
    let _ = @model.parse_events(
      "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:both\r\n" +
      "DTSTART:20260901T090000Z\r\nDTEND:20260901T100000Z\r\nDURATION:PT1H\r\n" +
      "END:VEVENT\r\nEND:VCALENDAR\r\n",
    )
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_eq(error, "line 0: VEVENT carries both DTEND and DURATION (in `PT1H`)")
}
