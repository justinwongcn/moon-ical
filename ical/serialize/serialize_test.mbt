///|
/// UTF-8 byte length of a string, the unit of RFC 5545's 75-octet fold
/// limit.
fn byte_len(s : String) -> Int {
  let mut total = 0
  for c in s.to_array() {
    let code = c.to_int()
    if code < 0x80 {
      total = total + 1
    } else if code < 0x800 {
      total = total + 2
    } else if code < 0x10000 {
      total = total + 3
    } else {
      total = total + 4
    }
  }
  total
}

///|
/// The physical lines of serialized text (without terminators): split on
/// CRLF, as the serializer itself emits them.
fn physical_lines(text : String) -> Array[String] {
  let parts : Array[String] = []
  let chars = text.to_array()
  let n = chars.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if chars[i] == '\r' && i + 1 < n && chars[i + 1] == '\n' {
      parts.push(String::from_array(chars[start:i]))
      i = i + 2
      start = i
    } else if chars[i] == '\n' {
      parts.push(String::from_array(chars[start:i]))
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  if start < n {
    parts.push(String::from_array(chars[start:n]))
  }
  // A trailing CRLF leaves one empty tail piece; drop it.
  let non_empty : Array[String] = []
  for p in parts {
    if p.length() > 0 {
      non_empty.push(p)
    }
  }
  non_empty
}

///|
/// A feed exercising everything a round trip must preserve: folding,
/// escaped text, TZID parameters, an RRULE, EXDATE, all-day values, a
/// nested VALARM, an unknown property, and an unknown nested component.
fn roundtrip_feed() -> String {
  "BEGIN:VCALENDAR\r\n" +
  "VERSION:2.0\r\n" +
  "PRODID:-//moon-ical//test//EN\r\n" +
  "BEGIN:VEVENT\r\n" +
  "UID:roundtrip-1@moon-ical\r\n" +
  "DTSTART;TZID=Asia/Shanghai:20260910T093000\r\n" +
  "DTEND;TZID=Asia/Shanghai:20260910T103000\r\n" +
  "DTSTAMP:20260901T000000Z\r\n" +
  "SUMMARY:每周同步会\\, 2026 秋\r\n 季版\r\n" +
  "DESCRIPTION:第一行\\n第二行\\;分号\r\n" +
  "RRULE:FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10\r\n" +
  "EXDATE;TZID=Asia/Shanghai:20260915T093000\r\n" +
  "X-UNKNOWN-PROP:keep me\r\n" +
  "BEGIN:VALARM\r\n" +
  "ACTION:DISPLAY\r\n" +
  "TRIGGER:-PT15M\r\n" +
  "END:VALARM\r\n" +
  "BEGIN:X-WEIRD\r\n" +
  "X-INNER:kept\r\n" +
  "END:X-WEIRD\r\n" +
  "END:VEVENT\r\n" +
  "BEGIN:VEVENT\r\n" +
  "UID:holiday\r\n" +
  "DTSTART;VALUE=DATE:20260925\r\n" +
  "DTEND;VALUE=DATE:20260926\r\n" +
  "SUMMARY:中秋节\r\n" +
  "END:VEVENT\r\n" +
  "END:VCALENDAR"
}

///|
test "parse to serialize to parse keeps the component tree identical" {
  let roots1 = @model.parse_components(@text.unfold(roundtrip_feed()))
  let wire2 = @serialize.serialize_components(roots1)
  let roots2 = @model.parse_components(@text.unfold(wire2))
  assert_eq(roots2, roots1)
}

///|
test "serializing twice is a fixed point" {
  let roots = @model.parse_components(@text.unfold(roundtrip_feed()))
  let once = @serialize.serialize_components(roots)
  let twice = @serialize.serialize_components(
    @model.parse_components(@text.unfold(once)),
  )
  assert_eq(twice, once)
}

///|
test "round trip keeps the typed events identical" {
  let events1 = @model.parse_events(roundtrip_feed())
  let wire2 = @serialize.serialize_components(
    @model.parse_components(@text.unfold(roundtrip_feed())),
  )
  let events2 = @model.parse_events(wire2)
  assert_eq(events2.length(), events1.length())
  assert_eq(events2.length(), 2)
  // The series event keeps every typed field, escapes unfolded.
  assert_eq(events2[0].summary, events1[0].summary)
  assert_eq(events2[0].summary, Some("每周同步会, 2026 秋季版"))
  assert_eq(events2[0].rrule, events1[0].rrule)
  assert_eq(events2[0].exdates.length(), 1)
  assert_eq(events2[1].all_day(), true)
}

///|
test "already-canonical input serializes back byte for byte" {
  let canonical = "BEGIN:VCALENDAR\r\nPRODID:-//moon-ical//test//EN\r\nEND:VCALENDAR\r\n"
  let roots = @model.parse_components(@text.unfold(canonical))
  assert_eq(@serialize.serialize_components(roots), canonical)
}

///|
test "no physical line of the output exceeds 75 octets" {
  let long = "BEGIN:VCALENDAR\r\nSUMMARY:中秋节的月亮圆又圆" +
    "中秋节的月亮圆又圆中秋节的月亮圆又圆中秋节的月亮圆又圆" +
    "中秋节的月亮圆又圆中秋节的月亮圆又圆\r\nEND:VCALENDAR\r\n"
  let wire = @serialize.serialize_components(
    @model.parse_components(@text.unfold(long)),
  )
  let lines = physical_lines(wire)
  // Folding must have happened at all: one long Chinese summary cannot
  // fit one line.
  assert_true(lines.length() > 3)
  for line in lines {
    assert_true(byte_len(line) <= 75)
  }
  // And unfolding the folded text restores the original logical line,
  // character for character — no multi-byte character was split.
  assert_eq(@text.unfold(wire), @text.unfold(long))
}

///|
test "folding an ASCII value breaks between characters only" {
  let mut long_value = ""
  while long_value.length() < 120 {
    long_value = long_value + "x"
  }
  let feed = "BEGIN:VCALENDAR\r\nDESCRIPTION:\{long_value}\r\nEND:VCALENDAR\r\n"
  let wire = @serialize.serialize_components(
    @model.parse_components(@text.unfold(feed)),
  )
  for line in physical_lines(wire) {
    assert_true(byte_len(line) <= 75)
  }
  assert_eq(@text.unfold(wire), @text.unfold(feed))
}

///|
test "a structural parameter value is re-quoted on output" {
  let feed = "BEGIN:VCALENDAR\r\nX-MEMBER;MEMBER=\"mailto:a,b\":v\r\nEND:VCALENDAR\r\n"
  let roots1 = @model.parse_components(@text.unfold(feed))
  assert_eq(roots1[0].properties[0].params[0].value, "mailto:a,b")
  let wire = @serialize.serialize_components(roots1)
  // The value went back out quoted, so parsing reads it as one value.
  let roots2 = @model.parse_components(@text.unfold(wire))
  assert_eq(roots2, roots1)
}

///|
test "a parameter value with a colon is quoted, a plain one is not" {
  let feed = "BEGIN:VCALENDAR\r\nX-A;TZID=\"Odd:Zone\":1\r\nX-B;TZID=Asia/Shanghai:2\r\nEND:VCALENDAR\r\n"
  let roots = @model.parse_components(@text.unfold(feed))
  let wire = @serialize.serialize_components(roots)
  assert_true(wire.contains("\"Odd:Zone\""))
  assert_true(wire.contains("TZID=Asia/Shanghai:"))
  assert_eq(@model.parse_components(@text.unfold(wire)), roots)
}

///|
test "an empty value and a leading-space value survive verbatim" {
  let feed = "BEGIN:VCALENDAR\r\nX-EMPTY:\r\nX-SPACE: padded\r\nEND:VCALENDAR\r\n"
  let roots1 = @model.parse_components(@text.unfold(feed))
  assert_eq(roots1[0].properties[0].value, "")
  assert_eq(roots1[0].properties[1].value, " padded")
  let wire = @serialize.serialize_components(roots1)
  assert_eq(@model.parse_components(@text.unfold(wire)), roots1)
}

///|
test "serialize_content_line folds and terminates a single line" {
  let line = @text.parse_content_line(
    "SUMMARY:本周要点的中文名称特别长长长长长长长长长长长长长长长长长长长长",
    1,
  )
  let text = @serialize.serialize_content_line(line)
  assert_true(text.length() > 0)
  for line2 in physical_lines(text) {
    assert_true(byte_len(line2) <= 75)
  }
}
