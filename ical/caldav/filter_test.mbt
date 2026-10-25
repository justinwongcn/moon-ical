///|
/// A one-event calendar whose `VEVENT` carries the given properties.
fn calendar(properties : String) -> String {
  "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n" +
  properties +
  "END:VEVENT\r\nEND:VCALENDAR\r\n"
}

///|
/// Whether this calendar matches this filter fragment, through the same
/// parse-then-evaluate path the server uses.
fn matches(filter : String, calendar_data : String) -> Bool raise {
  let parsed = @caldav.parse_filter(
    "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<C:filter>\{filter}</C:filter></C:calendar-query>",
  )
  parsed.matches(calendar_data)
}

///|
/// A filter selecting `VEVENT`s, optionally narrowed by a time range.
fn event_filter(inner : String) -> String {
  "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
  inner +
  "</C:comp-filter></C:comp-filter>"
}

///|
test "time-range matches a recurring series through expansion" {
  let data = calendar(
    "UID:r\r\nDTSTART:20260105T090000Z\r\nRRULE:FREQ=WEEKLY;COUNT=10\r\n",
  )
  // Ten weekly instances from 2026-01-05 end on 2026-03-09.
  assert_true(
    matches(
      event_filter(
        "<C:time-range start=\"20260201T000000Z\" end=\"20260301T000000Z\"/>",
      ),
      data,
    ),
  )
  assert_false(
    matches(
      event_filter(
        "<C:time-range start=\"20260401T000000Z\" end=\"20260501T000000Z\"/>",
      ),
      data,
    ),
  )
}

///|
test "time-range respects EXDATE" {
  let data = calendar(
    "UID:e\r\nDTSTART:20260105T090000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\n" +
    "EXDATE:20260106T090000Z\r\n",
  )
  // The excluded second day is the only instance in this window.
  assert_false(
    matches(
      event_filter(
        "<C:time-range start=\"20260106T000000Z\" end=\"20260107T000000Z\"/>",
      ),
      data,
    ),
  )
  assert_true(
    matches(
      event_filter(
        "<C:time-range start=\"20260107T000000Z\" end=\"20260108T000000Z\"/>",
      ),
      data,
    ),
  )
}

///|
test "time-range reaches past the first expansion window" {
  // A daily series long enough that a match only appears after several
  // doubling steps of the adaptive expansion.
  let data = calendar(
    "UID:long\r\nDTSTART:20260101T090000Z\r\nRRULE:FREQ=DAILY\r\n",
  )
  assert_true(
    matches(
      event_filter(
        "<C:time-range start=\"20261231T000000Z\" end=\"20270102T000000Z\"/>",
      ),
      data,
    ),
  )
}

///|
test "all-day events occupy their whole day" {
  let data = calendar("UID:d\r\nDTSTART;VALUE=DATE:20260110\r\n")
  assert_true(
    matches(
      event_filter(
        "<C:time-range start=\"20260110T120000Z\" end=\"20260110T130000Z\"/>",
      ),
      data,
    ),
  )
  assert_false(
    matches(
      event_filter(
        "<C:time-range start=\"20260111T000000Z\" end=\"20260112T000000Z\"/>",
      ),
      data,
    ),
  )
}

///|
test "time-range on an interval uses an exclusive end" {
  let data = calendar(
    "UID:i\r\nDTSTART:20260110T090000Z\r\nDTEND:20260110T100000Z\r\n",
  )
  // A range that begins exactly at DTEND does not overlap the event.
  assert_false(
    matches(
      event_filter(
        "<C:time-range start=\"20260110T100000Z\" end=\"20260110T110000Z\"/>",
      ),
      data,
    ),
  )
  // A range that ends exactly at DTSTART does not overlap either.
  assert_false(
    matches(
      event_filter(
        "<C:time-range start=\"20260110T080000Z\" end=\"20260110T090000Z\"/>",
      ),
      data,
    ),
  )
}

///|
test "text-match is case-insensitive by default and exact under i;octet" {
  let data = calendar("UID:t\r\nSUMMARY:Team Sync\r\n")
  let folded = "<C:prop-filter name=\"SUMMARY\"><C:text-match>team</C:text-match></C:prop-filter>"
  assert_true(matches(event_filter(folded), data))
  let exact = "<C:prop-filter name=\"SUMMARY\"><C:text-match collation=\"i;octet\">team</C:text-match></C:prop-filter>"
  assert_false(matches(event_filter(exact), data))
  let exact_hit = "<C:prop-filter name=\"SUMMARY\"><C:text-match collation=\"i;octet\">Team</C:text-match></C:prop-filter>"
  assert_true(matches(event_filter(exact_hit), data))
}

///|
test "text-match negate-condition inverts the test" {
  let data = calendar("UID:n\r\nSUMMARY:Team Sync\r\n")
  let negated = "<C:prop-filter name=\"SUMMARY\"><C:text-match negate-condition=\"yes\">team</C:text-match></C:prop-filter>"
  assert_false(matches(event_filter(negated), data))
  let negated_hit = "<C:prop-filter name=\"SUMMARY\"><C:text-match negate-condition=\"yes\">lunch</C:text-match></C:prop-filter>"
  assert_true(matches(event_filter(negated_hit), data))
}

///|
test "text-match sees the unescaped property text" {
  let data = calendar("UID:u\r\nSUMMARY:Lunch\\, then sync\r\n")
  let filter = "<C:prop-filter name=\"SUMMARY\"><C:text-match>Lunch, then</C:text-match></C:prop-filter>"
  assert_true(matches(event_filter(filter), data))
}

///|
test "prop-filter is-not-defined requires the property to be absent" {
  let data = calendar("UID:p\r\nSUMMARY:Sync\r\n")
  let absent = "<C:prop-filter name=\"LOCATION\"><C:is-not-defined/></C:prop-filter>"
  assert_true(matches(event_filter(absent), data))
  let present = "<C:prop-filter name=\"SUMMARY\"><C:is-not-defined/></C:prop-filter>"
  assert_false(matches(event_filter(present), data))
}

///|
test "param-filter tests a parameter of the enclosing property" {
  let data = calendar("UID:z\r\nDTSTART;TZID=Asia/Shanghai:20260110T090000\r\n")
  let filter = "<C:prop-filter name=\"DTSTART\"><C:param-filter name=\"TZID\">" +
    "<C:text-match>shanghai</C:text-match></C:param-filter></C:prop-filter>"
  assert_true(matches(event_filter(filter), data))
  let missing = "<C:prop-filter name=\"DTSTART\"><C:param-filter name=\"VALUE\">" +
    "<C:is-not-defined/></C:param-filter></C:prop-filter>"
  assert_true(matches(event_filter(missing), data))
}

///|
test "comp-filter is-not-defined excludes a component type" {
  let data = calendar("UID:c\r\nSUMMARY:Sync\r\n")
  let no_todo = "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VTODO\">" +
    "<C:is-not-defined/></C:comp-filter></C:comp-filter>"
  assert_true(matches(no_todo, data))
  let no_event = "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:is-not-defined/></C:comp-filter></C:comp-filter>"
  assert_false(matches(no_event, data))
}

///|
test "a VTODO time-range is judged on its due date" {
  let data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:td\r\n" +
    "DUE:20260110T170000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
  let filter = "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VTODO\">" +
    "<C:time-range start=\"20260110T160000Z\" end=\"20260110T180000Z\"/>" +
    "</C:comp-filter></C:comp-filter>"
  assert_true(matches(filter, data))
}

///|
test "a VTODO is not selected by a VEVENT filter" {
  let data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:td\r\n" +
    "DUE:20260110T170000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
  assert_false(matches(event_filter(""), data))
}

///|
test "an unreadable resource never matches" {
  assert_false(matches(event_filter(""), "not an iCalendar document"))
}

///|
test "an unsupported collation is reported as supported-filter" {
  let body = "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<C:filter><C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:prop-filter name=\"SUMMARY\">" +
    "<C:text-match collation=\"i;unknown\">x</C:text-match>" +
    "</C:prop-filter></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>"
  try @caldav.parse_filter(body) catch {
    @caldav.FilterError::UnsupportedFilter(element~) =>
      assert_true(element.contains("i;unknown"))
    @caldav.FilterError::InvalidFilter(message~) =>
      fail("expected supported-filter, got invalid-filter: \{message}")
  } noraise {
    _ => fail("expected the filter to be refused")
  }
}

///|
test "a malformed filter is reported as invalid-filter" {
  let cases = [
    // No filter element at all.
    "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\"/>",
    // A filter with no comp-filter.
    "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<C:filter/></C:calendar-query>",
    // A time range with neither bound.
    "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><C:filter>" +
    "<C:comp-filter name=\"VCALENDAR\"><C:time-range/></C:comp-filter>" +
    "</C:filter></C:calendar-query>",
    // is-not-defined combined with another test.
    "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><C:filter>" +
    "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:is-not-defined/><C:time-range start=\"20260101T000000Z\"/>" +
    "</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>",
  ]
  for body in cases {
    try @caldav.parse_filter(body) catch {
      @caldav.FilterError::InvalidFilter(_) => ()
      @caldav.FilterError::UnsupportedFilter(element~) =>
        fail("expected invalid-filter, got supported-filter: \{element}")
    } noraise {
      _ => fail("expected the filter to be refused: \{body}")
    }
  }
}

///|
test "a text-match needle decodes XML entities before comparing" {
  // S3 of the review round: a client searching for "R&D" must send
  // "R&amp;D" on the wire, so the needle has to be decoded to match.
  let data = calendar("UID:t\r\nSUMMARY:R&D meeting\r\n")
  let needle = "<C:prop-filter name=\"SUMMARY\">" +
    "<C:text-match>R&amp;D meeting</C:text-match></C:prop-filter>"
  assert_true(matches(event_filter(needle), data))
  // The same needle shape naming a different text selects nothing.
  let other = "<C:prop-filter name=\"SUMMARY\">" +
    "<C:text-match>Q&amp;D meeting</C:text-match></C:prop-filter>"
  assert_false(matches(event_filter(other), data))
}

///|
test "a body nested past the depth cap is refused, not walked" {
  // S2 of the review round: an unbounded tree overflowed the stack in
  // the recursive filter walks and killed the whole server process
  // (live-verified exit code 0xC00000FD at ~50k levels). Past the cap
  // the document is refused whole — the same 403 valid-filter
  // precondition any unreadable body gets.
  fn nested(depth : Int32) -> String {
    let out = StringBuilder()
    for _ in 0..<depth {
      out.write_string("<x>")
    }
    out.write_string("y")
    for _ in 0..<depth {
      out.write_string("</x>")
    }
    out.to_string()
  }
  fn error_of(body : String) -> String {
    try {
      let _ = @caldav.parse_filter(body)
      "no-error"
    } catch {
      err => err.to_string()
    }
  }
  // Below the cap the tree builds and the walk reports the missing
  // filter element; past it the document never becomes a tree at all.
  assert_eq(
    error_of(nested(60)),
    "invalid filter: calendar-query without a CALDAV:filter element",
  )
  assert_eq(
    error_of(nested(100)),
    "invalid filter: report body is not an XML element",
  )
}

///|
test "a time-range on VALARM is declined with supported-filter" {
  // The §11 capability-evidence matrix has claimed this refusal carries
  // a unit test since S10; review round T2 found the claim preceded the
  // test. This is the test: RFC 4791 §9.9 defines a VALARM's overlap in
  // terms of its parent's trigger, which this server does not resolve,
  // so the whole comp-filter is declined rather than guessed at.
  let body = "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<C:filter><C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:comp-filter name=\"VALARM\">" +
    "<C:time-range start=\"20260101T000000Z\"/>" +
    "</C:comp-filter></C:comp-filter></C:comp-filter></C:filter>" +
    "</C:calendar-query>"
  let error = try {
    let _ = @caldav.parse_filter(body)
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_eq(
    error, "unsupported filter element: <C:comp-filter name=\"VALARM\"><C:time-range/></C:comp-filter>",
  )
}

///|
test "a comp-filter's tests must pass on one event instance" {
  // RFC 4791 §9.7.1: every nested test of a comp-filter applies to the
  // same component instance. Alpha overlaps January but is not named
  // Beta; Beta is named Beta but sits in June. Judging the time-range
  // over the whole resource let Alpha's overlap satisfy Beta's filter
  // and the calendar falsely matched.
  let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
    "BEGIN:VEVENT\r\nUID:a\r\nSUMMARY:Alpha\r\nDTSTART:20260110T120000Z\r\nDTEND:20260110T130000Z\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:b\r\nSUMMARY:Beta\r\nDTSTART:20260610T120000Z\r\nDTEND:20260610T130000Z\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  assert_false(
    matches(
      "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
      "<C:time-range start=\"20260101T000000Z\" end=\"20260201T000000Z\"/>" +
      "<C:prop-filter name=\"SUMMARY\"><C:text-match>Beta</C:text-match></C:prop-filter>" +
      "</C:comp-filter></C:comp-filter>",
      ics,
    ),
  )
  // The differential the whole-resource judgement could not make: move
  // the range to June and Beta itself satisfies both tests, so the same
  // calendar matches.
  assert_true(
    matches(
      "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
      "<C:time-range start=\"20260601T000000Z\" end=\"20260701T000000Z\"/>" +
      "<C:prop-filter name=\"SUMMARY\"><C:text-match>Beta</C:text-match></C:prop-filter>" +
      "</C:comp-filter></C:comp-filter>",
      ics,
    ),
  )
}

///|
test "a VTODO time-range resolves the feed's own VTIMEZONE" {
  // The non-VEVENT time-range paths used to parse dates with the built-in
  // zone table alone, so a feed-private TZID never resolved and the todo
  // silently matched nothing. The feed's own declaration (+0900) puts
  // this DTSTART at 2026-01-15 01:00 UTC, inside the range.
  let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
    "BEGIN:VTIMEZONE\r\nTZID:My-Zone\r\nBEGIN:STANDARD\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n" +
    "BEGIN:VTODO\r\nUID:t\r\nDTSTART;TZID=My-Zone:20260115T100000\r\nDUE;TZID=My-Zone:20260115T110000\r\nEND:VTODO\r\n" +
    "END:VCALENDAR\r\n"
  let vtodo_range = "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VTODO\">" +
    "<C:time-range start=\"20260115T000000Z\" end=\"20260116T000000Z\"/>" +
    "</C:comp-filter></C:comp-filter>"
  assert_true(matches(vtodo_range, ics))
  // The differential: with the zone no longer declared by the feed, the
  // same todo cannot be judged and matches nothing.
  assert_false(
    matches(vtodo_range, ics.replace(old="TZID:My-Zone", new="TZID:Gone")),
  )
}

///|
test "an inverted time-range is an invalid filter, with equal bounds too" {
  // The report-level 403 shape is pinned in caldav_test; this pins the
  // parse-level contract: a half-open range needs start < end.
  let inverted = "<C:time-range start=\"20260201T000000Z\" end=\"20260101T000000Z\"/>"
  let error = try {
    let _ = @caldav.parse_filter(
      "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
      "<C:filter><C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">\{inverted}</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>",
    )
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_eq(error, "invalid filter: time-range start must be before end")
  let equal = inverted.replace(old="20260101T000000Z", new="20260201T000000Z")
  let error2 = try {
    let _ = @caldav.parse_filter(
      "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
      "<C:filter><C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">\{equal}</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>",
    )
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_eq(error2, "invalid filter: time-range start must be before end")
}

///|
test "a numeric character reference in a needle decodes like a named one" {
  // &#38; and &amp; spell the same character on the wire; the S13
  // decode covered only the named form, so a client using the numeric
  // spelling searched for a literal "&#38;" and silently missed — the
  // same defect shape, one escape form later.
  let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:r\r\nSUMMARY:R&D\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
  let base = "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:prop-filter name=\"SUMMARY\"><C:text-match>R&amp;D</C:text-match></C:prop-filter>" +
    "</C:comp-filter></C:comp-filter>"
  assert_true(matches(base, ics))
  assert_true(matches(base.replace(old="R&amp;D", new="R&#38;D"), ics))
  assert_true(matches(base.replace(old="R&amp;D", new="R&#x26;D"), ics))
  // A reference that names no character stays verbatim and simply does
  // not match: past the Unicode ceiling, a surrogate half, zero, and a
  // non-number are all left as written.
  assert_false(matches(base.replace(old="R&amp;D", new="R&#x110000;D"), ics))
  assert_false(matches(base.replace(old="R&amp;D", new="R&#xD800;D"), ics))
  assert_false(matches(base.replace(old="R&amp;D", new="R&#0;D"), ics))
  assert_false(matches(base.replace(old="R&amp;D", new="R&#zz;D"), ics))
  // The reference window reaches ten characters, but an astral-plane
  // reference (U+10000 and up, the ceiling included) stays verbatim: a
  // Char is one UTF-16 code unit, so BMP is the decode range and an
  // out-of-range reference simply does not match rather than matching
  // something else.
  assert_false(matches(base.replace(old="R&amp;D", new="R&#1114111;D"), ics))
}
