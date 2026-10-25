///|
test "built-in table resolves common zone names" {
  let t = @model.ZoneTable::builtin_common()
  assert_eq(t.lookup("UTC"), Some(0))
  assert_eq(t.lookup("Asia/Shanghai"), Some(8 * 3600))
  assert_eq(t.lookup("america/new_york"), Some(-5 * 3600))
  assert_eq(t.lookup("Europe/Berlin"), Some(1 * 3600))
}

///|
test "an unknown zone stays unknown rather than defaulting to UTC" {
  let t = @model.ZoneTable::builtin_common()
  assert_eq(t.lookup("Antarctica/Troll"), None)
  assert_eq(@model.ZoneTable::empty().lookup("UTC"), None)
}

///|
test "half-hour and negative offsets are composed correctly" {
  // -0530 must be minus five-and-a-half, not minus four-and-a-half.
  let t = @model.ZoneTable::empty()
  t.insert("X/NEG", -(5 * 3600 + 30 * 60))
  assert_eq(t.lookup("x/neg"), Some(-(5 * 3600 + 30 * 60)))
  assert_eq(
    @model.parse_utc_offset("+0530", line_no=1, raw="+0530"),
    5 * 3600 + 30 * 60,
  )
  assert_eq(
    @model.parse_utc_offset("-0800", line_no=1, raw="-0800"),
    -(8 * 3600),
  )
}

///|
test "a bare-hour offset is accepted" {
  assert_eq(@model.parse_utc_offset("+08", line_no=1, raw="+08"), 8 * 3600)
}

///|
test "offsets without a sign or digits are rejected" {
  // Since S12 the exact-shape gate runs first, so a wrong-length value is
  // reported by its shape; the sign message is reachable for a value that
  // has a legal length but no sign.
  let msg = try {
    let _ = @model.parse_utc_offset("080", line_no=1, raw="080")
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(msg.contains("needs a sign"))
  let short = try {
    let _ = @model.parse_utc_offset("+8", line_no=1, raw="+8")
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(short.contains("must be +hh"))
}

///|
test "a feed's own VTIMEZONE is picked up" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:/google.com/ntp/Made-Up", "BEGIN:STANDARD",
    "TZOFFSETTO:+0930", "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
  ])
  let table = @model.build_zone_table(roots)
  assert_eq(table.lookup("/google.com/ntp/made-up"), Some(9 * 3600 + 30 * 60))
}

///|
test "only the STANDARD segment is read, and a bad offset is skipped" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:ONE-ZONE", "BEGIN:STANDARD", "TZOFFSETTO:nonsense",
    "END:STANDARD", "END:VTIMEZONE", "BEGIN:VTIMEZONE", "TZID:GOOD-ZONE", "BEGIN:STANDARD",
    "TZOFFSETTO:-0300", "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
  ])
  let table = @model.build_zone_table(roots)
  // The broken VTIMEZONE must not hide the healthy one.
  assert_eq(table.lookup("GOOD-ZONE"), Some(-3 * 3600))
  assert_eq(table.lookup("ONE-ZONE"), None)
}

///|
test "a feed zone overrides the built-in guess for the same name" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:Asia/Shanghai", "BEGIN:STANDARD",
    "TZOFFSETTO:+0700", "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
  ])
  let merged = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  assert_eq(merged.lookup("Asia/Shanghai"), Some(7 * 3600))
}

///|
test "a private TZID parses a date-time once the feed declared it" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:China Standard Time", "BEGIN:STANDARD",
    "TZOFFSETTO:+0800", "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
  ])
  let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  let cl = @text.parse_content_line(
    "DTSTART;TZID=China Standard Time:20260908T093000", 3,
  )
  let v = @model.parse_date_time(cl, zones)
  assert_eq(v.utc_offset, Some(8 * 3600))
}

///|
test "inserting the same zone twice keeps the later value" {
  let t = @model.ZoneTable::empty()
  t.insert("A/B", 3600)
  t.insert("a/b", 7200)
  assert_eq(t.lookup("A/B"), Some(7200))
}

///|
test "malformed UTC offsets are refused whole, not half-read" {
  // Review round M1: +05:30 parsed as +05:00 (half an hour silently
  // lost), +0899 composed to +09:39, and tails beyond five characters
  // were ignored. Every shape but +hh/+hhmm/+hhmmss is now a line error.
  fn offset_error(text : String) -> String {
    try {
      let _ = @model.parse_utc_offset(text, line_no=1, raw=text)
      "no-error"
    } catch {
      err => err.to_string()
    }
  }
  assert_eq(
    offset_error("+05:30"),
    "line 1: UTC offset must be +hh, +hhmm, or +hhmmss: +05:30 (in `+05:30`)",
  )
  assert_eq(
    offset_error("+080"),
    "line 1: UTC offset must be +hh, +hhmm, or +hhmmss: +080 (in `+080`)",
  )
  assert_eq(
    offset_error("+0530x"),
    "line 1: UTC offset must be +hh, +hhmm, or +hhmmss: +0530x (in `+0530x`)",
  )
  assert_eq(
    offset_error("+0899"),
    "line 1: UTC offset minute or second out of range: +0899 (in `+0899`)",
  )
}

///|
test "the RFC seconds form of a UTC offset composes into the value" {
  assert_eq(
    @model.parse_utc_offset("+053030", line_no=1, raw="+053030"),
    5 * 3600 + 30 * 60 + 30,
  )
  assert_eq(
    @model.parse_utc_offset("-053000", line_no=1, raw="-053000"),
    -(5 * 3600 + 30 * 60),
  )
}
