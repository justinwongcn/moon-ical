///|
fn resources() -> Array[@caldav.DavResource] {
  [
    {
      href: "/cal/a.ics",
      etag: "aaa",
      calendar_data: "BEGIN:VCALENDAR\r\nSUMMARY:A & B\r\nEND:VCALENDAR\r\n",
    },
    {
      href: "/cal/b.ics",
      etag: "bbb",
      calendar_data: "BEGIN:VCALENDAR\r\nSUMMARY:B\r\nEND:VCALENDAR\r\n",
    },
  ]
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
  let body = "<C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\"/>"
  let result = @caldav.report(body, resources()).unwrap()
  assert_true(result.contains("/cal/a.ics"))
  assert_true(result.contains("A &amp; B"))
}

///|
test "calendar-multiget selects requested hrefs" {
  let body = "<C:calendar-multiget xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:href xmlns:D=\"DAV:\">/cal/b.ics</D:href></C:calendar-multiget>"
  let result = @caldav.report(body, resources()).unwrap()
  assert_true(!result.contains("/cal/a.ics"))
  assert_true(result.contains("/cal/b.ics"))
  assert_true(@caldav.report("<D:sync-collection/>", resources()) is None)
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
