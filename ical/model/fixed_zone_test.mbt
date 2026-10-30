///|
fn zone_calendar(body : String) -> Array[@model.Component] raise {
  @model.parse_calendar(
    "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:UTC\r\n" +
    body +
    "END:VTIMEZONE\r\nEND:VCALENDAR\r\n",
  )
}

///|
fn fixed_standard(from : String, to : String) -> String {
  "BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:" +
  from +
  "\r\nTZOFFSETTO:" +
  to +
  "\r\nEND:STANDARD\r\n"
}

///|
fn assert_zone_refused(body : String) -> Unit raise {
  let roots = zone_calendar(body)
  let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  assert_eq(zones.lookup("UTC"), None)
  assert_true(zones.rejection_reason("utc") is Some(_))
  let line = @text.parse_content_line("DTSTART;TZID=UTC:20260901T090000", 9)
  try @model.parse_date_time(line, zones, line_no=9) catch {
    @text.ParseError::BadLine(line_no=9, message~, ..) =>
      assert_true(message.contains("unsupported TZID"))
    _ => fail("expected typed zone refusal")
  } noraise {
    _ => fail("unsupported zone calculated")
  }
  // Z is independent of a rejected TZID binding.
  assert_eq(
    @model.parse_single_date_time("20260901T090000Z", zones).utc_offset,
    Some(0),
  )
}

///|
test "provably fixed VTIMEZONE versus changed FROM offset differ" {
  let fixed = @model.ZoneTable::with_builtin(
    @model.build_zone_table(zone_calendar(fixed_standard("+0930", "+0930"))),
  )
  assert_eq(fixed.lookup("UTC"), Some(34200))
  assert_zone_refused(fixed_standard("+0830", "+0930"))
}

///|
test "dynamic historic malformed and incomplete feed declarations shadow builtin" {
  for
    body in [
      fixed_standard("+0100", "+0100") + fixed_standard("+0200", "+0200"),
      fixed_standard("+0100", "+0100") +
      "BEGIN:DAYLIGHT\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nEND:DAYLIGHT\r\n",
      "BEGIN:DAYLIGHT\r\nTZOFFSETTO:+0200\r\nEND:DAYLIGHT\r\n",
      "BEGIN:STANDARD\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\n",
      fixed_standard("nonsense", "+0100"),
      "BEGIN:STANDARD\r\nDTSTART:20260230T000000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\n",
      "BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0100\r\nRRULE:FREQ=YEARLY\r\nEND:STANDARD\r\n",
    ] {
    assert_zone_refused(body)
  }
}

///|
test "unbound regional names fail while explicit fixed binding calculates" {
  let line = @text.parse_content_line(
    "RDATE;TZID=America/New_York:20260701T090000", 1,
  )
  try @model.parse_date_time(line, @model.ZoneTable::builtin_common()) catch {
    @text.ParseError::BadLine(message~, ..) =>
      assert_true(message.contains("no explicit fixed binding"))
    _ => fail("expected BadLine")
  } noraise {
    _ => fail("regional zone guessed")
  }
  let zones = @model.ZoneTable::empty()
  zones.insert("America/New_York", -18000)
  assert_eq(@model.parse_date_time(line, zones).utc_offset, Some(-18000))
}

///|
test "duplicate TZID properties reject every declared name in either order" {
  for ids in ["TZID:Private\r\nTZID:UTC\r\n", "TZID:UTC\r\nTZID:Private\r\n"] {
    let roots = @model.parse_calendar(
      "BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\n" +
      ids +
      fixed_standard("+0000", "+0000") +
      "END:VTIMEZONE\r\nEND:VCALENDAR\r\n",
    )
    let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
    assert_eq(zones.lookup("UTC"), None)
    assert_eq(zones.lookup("Private"), None)
    assert_true(zones.rejection_reason("UTC") is Some(_))
    let line = @text.parse_content_line("DTSTART;TZID=UTC:20260901T090000", 1)
    try @model.parse_date_time(line, zones) catch {
      @text.ParseError::BadLine(message~, ..) =>
        assert_true(message.contains("unsupported TZID"))
      _ => fail("expected BadLine")
    } noraise {
      _ => fail("duplicate declaration fell back to builtin")
    }
  }
}

///|
test "all event date references reject a dynamic zone only when referenced" {
  let declaration = "BEGIN:VTIMEZONE\r\nTZID:UTC\r\n" +
    fixed_standard("+0100", "+0200") +
    "END:VTIMEZONE\r\n"
  let prefix = "BEGIN:VCALENDAR\r\n" + declaration + "BEGIN:VEVENT\r\nUID:z\r\n"
  assert_eq(
    @model.parse_events(
      prefix + "SUMMARY:unreferenced\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ).length(),
    1,
  )
  for name in ["DTSTART", "DTEND", "RECURRENCE-ID", "EXDATE", "RDATE"] {
    let feed = prefix +
      name +
      ";TZID=UTC:20260901T090000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    try @model.parse_events(feed) catch {
      @text.ParseError::BadLine(message~, ..) =>
        assert_true(message.contains("unsupported TZID"))
      _ => fail("expected BadLine")
    } noraise {
      _ => fail("dynamic reference guessed")
    }
    assert_eq(@model.parse_calendar(feed)[0].children[0].kind, "VTIMEZONE")
  }
}
