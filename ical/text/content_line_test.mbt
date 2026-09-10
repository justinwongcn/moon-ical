///|
test "property line with one parameter" {
  let c = @text.parse_content_line(
    "DTSTART;TZID=Asia/Shanghai:20260908T093000", 1,
  )
  assert_eq(c.name, "DTSTART")
  assert_eq(c.params.length(), 1)
  assert_eq(c.params[0].name, "TZID")
  assert_eq(c.params[0].value, "Asia/Shanghai")
  assert_eq(c.value, "20260908T093000")
}

///|
test "parameter names are normalised to upper case" {
  let c = @text.parse_content_line("dtstart;tzid=UTC:20260908T093000Z", 2)
  assert_eq(c.name, "DTSTART")
  assert_eq(c.params[0].name, "TZID")
}

///|
test "a colon inside a quoted param value does not start the value" {
  let c = @text.parse_content_line("X-COMMENT;P=\"a:b\":real", 3)
  assert_eq(c.params[0].value, "a:b")
  assert_eq(c.value, "real")
}

///|
test "a comma inside a quoted param value is not a param separator" {
  let c = @text.parse_content_line("X;P=\"a,b\";Q=1:value", 4)
  assert_eq(c.params.length(), 2)
  assert_eq(c.params[0].value, "a,b")
  assert_eq(c.params[1].name, "Q")
  assert_eq(c.params[1].value, "1")
  assert_eq(c.value, "value")
}

///|
test "a value may contain colons after the first separator" {
  let c = @text.parse_content_line("DESCRIPTION:note: 12:30 UTC", 5)
  assert_eq(c.name, "DESCRIPTION")
  assert_eq(c.value, "note: 12:30 UTC")
}

///|
test "a property without parameters parses" {
  let c = @text.parse_content_line("BEGIN:VEVENT", 6)
  assert_eq(c.name, "BEGIN")
  assert_eq(c.params.length(), 0)
  assert_eq(c.value, "VEVENT")
}

///|
test "an empty value is still a value" {
  let c = @text.parse_content_line("CATEGORIES:", 7)
  assert_eq(c.name, "CATEGORIES")
  assert_eq(c.value, "")
}

///|
test "missing value separator reports the offending line" {
  let outcome = try {
    let _ = @text.parse_content_line("NOT A PROPERTY LINE", 42)
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("line 42"))
  assert_true(outcome.contains("NOT A PROPERTY LINE"))
}

///|
test "a parameter without '=' is rejected with context" {
  let outcome = try {
    let _ = @text.parse_content_line("X;BOGUS:value", 9)
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("line 9"))
  assert_true(outcome.contains("BOGUS"))
}

///|
test "unescape_value restores escaped delimiters and newlines" {
  assert_eq(@text.unescape_value("a\\,b\\nc\\;d\\\\e"), "a,b\nc;d\\e")
}

///|
test "unescape_value accepts the Apple \\N newline spelling" {
  assert_eq(@text.unescape_value("one\\Ntwo"), "one\ntwo")
}

///|
test "unescape_value passes unknown escapes through unchanged" {
  assert_eq(@text.unescape_value("keep\\Xthis"), "keep\\Xthis")
}

///|
test "unescape_value on a string with no escapes is identity" {
  assert_eq(@text.unescape_value("plain text"), "plain text")
}

///|
test "a trailing lone backslash does not run off the end" {
  assert_eq(@text.unescape_value("ends\\"), "ends\\")
}

///|
test "escape_value is the inverse of unescape_value" {
  assert_eq(
    @text.escape_value("Team sync, 2026\nRoom B; weekly"),
    "Team sync\\, 2026\\nRoom B\\; weekly",
  )
  assert_eq(
    @text.unescape_value(@text.escape_value("a,b\nc;d\\e")),
    "a,b\nc;d\\e",
  )
  assert_eq(@text.escape_value("plain"), "plain")
}
