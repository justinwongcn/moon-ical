///|
/// Two one-event calendars, far enough apart that a time range can tell them
/// apart. `a.ics` deliberately carries text needing XML escaping so the
/// response builder is exercised by the same fixture the filter uses.
fn resources() -> Array[@caldav.DavResource] {
  [
    {
      href: "/cal/a.ics",
      etag: "aaa",
      calendar_data: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n" +
      "UID:a\r\nDTSTART:20260110T090000Z\r\nDTEND:20260110T100000Z\r\n" +
      "SUMMARY:A & B\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    },
    {
      href: "/cal/b.ics",
      etag: "bbb",
      calendar_data: "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n" +
      "UID:b\r\nDTSTART:20260610T090000Z\r\nDTEND:20260610T100000Z\r\n" +
      "SUMMARY:B\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    },
  ]
}

///|
/// A `calendar-query` body wrapping a filter fragment.
fn query(filter : String) -> String {
  "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
  "<C:filter>\{filter}</C:filter></C:calendar-query>"
}

///|
/// The multistatus body of a report that must succeed.
fn report_body(
  body : String,
  resources : Array[@caldav.DavResource],
) -> String raise {
  match @caldav.report(body, resources) {
    @caldav.ReportOutcome::Report(body~) => body
    outcome => fail("expected a multistatus report, got \{Repr(outcome)}")
  }
}

///|
test "discovery responses expose principal and calendar home" {
  assert_true(@caldav.root_propfind().contains("/principals/default/"))
  assert_true(@caldav.principal_propfind().contains("calendar-home-set"))
  assert_true(@caldav.principal_propfind().contains("/cal/"))
}

///|
test "Depth 0 and 1 collection responses differ by resources" {
  let depth0 = @caldav.collection_propfind(resources(), 0)
  let depth1 = @caldav.collection_propfind(resources(), 1)
  assert_true(!depth0.contains("/cal/a.ics"))
  assert_true(depth1.contains("/cal/a.ics"))
  assert_true(depth1.contains("&quot;aaa&quot;"))
}

///|
test "calendar-query returns data and escapes XML" {
  let body = query("<C:comp-filter name=\"VCALENDAR\"/>")
  let result = report_body(body, resources())
  assert_true(result.contains("/cal/a.ics"))
  assert_true(result.contains("A &amp; B"))
}

///|
test "calendar-query selects by time range" {
  let body = query(
    "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:time-range start=\"20260101T000000Z\" end=\"20260201T000000Z\"/>" +
    "</C:comp-filter></C:comp-filter>",
  )
  let result = report_body(body, resources())
  assert_true(result.contains("/cal/a.ics"))
  assert_true(!result.contains("/cal/b.ics"))
}

///|
test "calendar-query with no match returns an empty multistatus" {
  let body = query(
    "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
    "<C:time-range start=\"20300101T000000Z\" end=\"20310101T000000Z\"/>" +
    "</C:comp-filter></C:comp-filter>",
  )
  let result = report_body(body, resources())
  assert_true(!result.contains("/cal/a.ics"))
  assert_true(!result.contains("/cal/b.ics"))
  assert_true(result.contains("multistatus"))
}

///|
test "calendar-query without a filter fails the valid-filter precondition" {
  match
    @caldav.report(
      "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\"/>",
      resources(),
    ) {
    @caldav.ReportOutcome::PreconditionFailed(body~) =>
      assert_true(body.contains("valid-filter"))
    outcome => fail("expected a precondition failure, got \{Repr(outcome)}")
  }
}

///|
test "calendar-query on an unknown component fails supported-filter" {
  let body = query("<C:comp-filter name=\"X-NOT-A-COMPONENT\"/>")
  match @caldav.report(body, resources()) {
    @caldav.ReportOutcome::PreconditionFailed(body~) => {
      assert_true(body.contains("supported-filter"))
      assert_true(body.contains("X-NOT-A-COMPONENT"))
    }
    outcome => fail("expected a precondition failure, got \{Repr(outcome)}")
  }
}

///|
test "calendar-multiget selects requested hrefs" {
  let body = "<C:calendar-multiget xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:href xmlns:D=\"DAV:\">/cal/b.ics</D:href></C:calendar-multiget>"
  let result = report_body(body, resources())
  assert_true(!result.contains("/cal/a.ics"))
  assert_true(result.contains("/cal/b.ics"))
  assert_eq(
    @caldav.report("<D:sync-collection/>", resources()),
    @caldav.ReportOutcome::UnsupportedReport,
  )
}

///|
test "calendar-multiget matches local names independent of prefix case" {
  let body = "<calendar-multiget><x:HrEf>/cal/a.ics</x:HrEf></calendar-multiget>"
  let result = report_body(body, resources())
  assert_true(result.contains("/cal/a.ics"))
  assert_true(!result.contains("/cal/b.ics"))
}

///|
test "entity-tag preconditions cover create update and lists" {
  assert_eq(
    @caldav.check_preconditions(None, None, Some("*")),
    @caldav.Precondition::Pass,
  )
  assert_eq(
    @caldav.check_preconditions(Some("aaa"), None, Some("*")),
    @caldav.Precondition::Failed,
  )
  assert_eq(
    @caldav.check_preconditions(Some("aaa"), Some("\"aaa\""), None),
    @caldav.Precondition::Pass,
  )
  assert_eq(
    @caldav.check_preconditions(Some("aaa"), Some("\"bbb\", W/\"aaa\""), None),
    @caldav.Precondition::Pass,
  )
  assert_eq(
    @caldav.check_preconditions(Some("aaa"), Some("\"bbb\""), None),
    @caldav.Precondition::Failed,
  )
  assert_eq(
    @caldav.check_preconditions(None, Some("*"), None),
    @caldav.Precondition::Failed,
  )
}
