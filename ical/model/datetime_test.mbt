///|
/// Parse a full property line the way the sync layer will.
fn dt(line : String) -> @model.IcalDateTime raise {
  let cl = @text.parse_content_line(line, 1)
  @model.parse_date_time(cl, @model.ZoneTable::builtin_common())
}

///|
/// Report the message of a failing parse, or "no-error" when it succeeded.
fn error_of(line : String) -> String {
  try {
    let _ = dt(line)
    "no-error"
  } catch {
    err => err.to_string()
  }
}

///|
test "a trailing Z is UTC" {
  let v = dt("DTSTART:20260908T013000Z")
  assert_eq(v.utc_offset, Some(0))
  assert_true(v.is_utc())
  assert_eq(v.wall.hour(), 1)
  assert_eq(v.to_string(), "2026-09-08T01:30:00Z")
}

///|
test "a known TZID resolves through the table" {
  let v = dt("DTSTART;TZID=Asia/Shanghai:20260908T093000")
  assert_eq(v.utc_offset, Some(8 * 3600))
  assert_eq(v.zone_id, "Asia/Shanghai")
  assert_eq(v.to_string(), "2026-09-08T09:30:00+08:00")
}

///|
test "the same instant written two ways compares equal" {
  let utc = dt("DTSTART:20260908T013000Z")
  let zoned = dt("DTSTART;TZID=Asia/Shanghai:20260908T093000")
  assert_eq(utc.compare(zoned), 0)
  assert_eq(zoned.instant_seconds(), utc.instant_seconds())
}

///|
test "ordering follows the instant, not the wall clock" {
  let earlier = dt("DTSTART;TZID=Asia/Shanghai:20260908T093000")
  let later = dt("DTSTART:20260908T020000Z")
  assert_true(earlier.compare(later) < 0)
  assert_true(later.compare(earlier) > 0)
}

///|
test "no designator and no TZID means floating" {
  let v = dt("DTSTART:20260908T093000")
  assert_true(v.is_floating())
  assert_eq(v.utc_offset, None)
  assert_eq(v.to_string(), "2026-09-08T09:30:00")
}

///|
test "VALUE=DATE is an all-day value" {
  let v = dt("DTSTART;VALUE=DATE:20260908")
  assert_true(v.all_day)
  assert_eq(v.to_string(), "2026-09-08")
}

///|
test "a bare 8-digit value is all-day even without VALUE=DATE" {
  let v = dt("DTSTART:20260908")
  assert_true(v.all_day)
  assert_eq(v.wall.hour(), 0)
}

///|
test "an absolute offset designator is honoured" {
  let v = dt("DTSTART:20260908T093000-0500")
  assert_eq(v.utc_offset, Some(-(5 * 3600)))
  assert_eq(v.to_string(), "2026-09-08T09:30:00-05:00")
}

///|
test "half-hour zones keep their minutes" {
  let v = dt("DTSTART;TZID=Asia/Kolkata:20260908T093000")
  assert_eq(v.utc_offset, Some(5 * 3600 + 30 * 60))
  assert_eq(v.to_string(), "2026-09-08T09:30:00+05:30")
}

///|
test "TZID lookup ignores case, as feeds are inconsistent" {
  let v = dt("DTSTART;TZID=ASIA/shanghai:20260908T093000")
  assert_eq(v.utc_offset, Some(8 * 3600))
}

///|
test "an unknown TZID is an error, never a silent guess" {
  let msg = error_of("DTSTART;TZID=Mars/Olympus:20260908T093000")
  assert_true(msg.contains("unknown TZID"))
  assert_true(msg.contains("Mars/Olympus"))
}

///|
test "a dashed ISO date is rejected instead of half-parsed" {
  assert_true(error_of("DTSTART:2026-09-08T09:30").contains("malformed"))
}

///|
test "a value missing its T separator is rejected" {
  assert_true(error_of("DTSTART:20260908093000").contains("malformed"))
}

///|
test "a truncated time is rejected" {
  assert_true(error_of("DTSTART:20260908T093").contains("malformed"))
}

///|
test "parse_single_date_time reads a UTC UNTIL" {
  let v = @model.parse_single_date_time(
    "20261231T230000Z",
    @model.ZoneTable::builtin_common(),
  )
  assert_eq(v.utc_offset, Some(0))
  assert_eq(v.wall.minute(), 0)
}

///|
test "parse_single_date_time leaves a bare value floating" {
  let v = @model.parse_single_date_time(
    "20261231T230000",
    @model.ZoneTable::builtin_common(),
  )
  assert_true(v.is_floating())
}

///|
test "a negative one-hour offset prints its sign" {
  let v = dt("DTSTART;TZID=America/New_York:20260115T090000")
  assert_eq(v.utc_offset, Some(-5 * 3600))
  assert_eq(v.to_string(), "2026-01-15T09:00:00-05:00")
}

///|
test "a four-digit year below 1000 is padded when printed" {
  let cl = @text.parse_content_line("DTSTART;VALUE=DATE:09080101", 1)
  let v = @model.parse_date_time(cl, @model.ZoneTable::builtin_common())
  assert_eq(v.to_string(), "0908-01-01")
}
