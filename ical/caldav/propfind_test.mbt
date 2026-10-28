///|
/// The property selection a `PROPFIND` or `REPORT` body names, against the
/// fixtures from `caldav_test.mbt` (`a.ics` etag `aaa`, `b.ics` etag `bbb`).
///
/// Request bodies below are transcribed from the RFC examples they cite
/// (R5), with only the href paths swapped for the fixture's.

///|
/// RFC 4791 §9.5/§9.10 leave the property selection optional in both
/// reports; §7.8 says the response then follows PROPFIND. A multiget with
/// no selection and one with an explicit `allprop` must answer the same.
test "a report without a prop element answers like allprop" {
  let plain = "<C:calendar-multiget xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:href>/cal/a.ics</D:href></C:calendar-multiget>"
  let allprop = plain.replace(old="\">", new="\"><D:allprop/>")
  assert_eq(report_body(plain, resources()), report_body(allprop, resources()))
  // Report context answers calendar-data: it is the report's payload
  // (RFC 4791 §9.6 exempts it only from PROPFIND).
  assert_true(report_body(plain, resources()).contains("calendar-data"))
}

///|
/// RFC 4791 §7.9.1 example request: a multiget naming `getetag` and
/// `calendar-data` answers both for the present href and a 404 for the
/// missing one.
test "a multiget answers exactly the properties it names" {
  let body = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>" +
    "<C:calendar-multiget xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:prop><D:getetag/><C:calendar-data/></D:prop>" +
    "<D:href>/cal/a.ics</D:href>" +
    "<D:href>/cal/mtg1.ics</D:href>" +
    "</C:calendar-multiget>"
  let result = report_body(body, resources())
  assert_true(result.contains("&quot;aaa&quot;"))
  assert_true(result.contains("calendar-data"))
  assert_true(result.contains("/cal/mtg1.ics"))
  assert_true(result.contains("404 Not Found"))
}

///|
/// R1: two requests differing only in the prop element must differ —
/// the one asking for `getetag` alone gets no calendar data.
test "a report naming getetag alone trims the answer" {
  let query = "<C:calendar-query xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:prop><D:getetag/></D:prop>" +
    "<C:filter><C:comp-filter name=\"VCALENDAR\"/></C:filter>" +
    "</C:calendar-query>"
  let etag_only = report_body(query, resources())
  let both = report_body(
    query.replace(old="<D:getetag/>", new="<D:getetag/><C:calendar-data/>"),
    resources(),
  )
  assert_true(etag_only.contains("&quot;aaa&quot;"))
  assert_false(etag_only.contains("calendar-data"))
  assert_true(both.contains("calendar-data"))
  // An unnamed property gets the 404 propstat RFC 4791 §7.8 defers to
  // RFC 4918 §9.1 for; the differential partner answers 200.
  let unknown = report_body(
    query.replace(old="<D:getetag/>", new="<D:no-such-prop/>"),
    resources(),
  )
  assert_true(unknown.contains("404 Not Found"))
  assert_true(unknown.contains("<D:no-such-prop/>"))
  assert_false(unknown.contains("getetag"))
}

///|
/// RFC 4791 §9.6: calendar-data is not a WebDAV property and is not
/// returned in PROPFIND responses — a PROPFIND naming it gets the 404
/// propstat, not the data (and a PROPFIND never ships event bodies).
test "propfind never returns calendar-data" {
  let allprop = @caldav.collection_propfind(resources(), 1)
  assert_true(allprop.contains("getcontenttype"))
  assert_false(allprop.contains("BEGIN:VCALENDAR"))
  let requested = @caldav.collection_propfind(
    resources(),
    1,
    selection=@caldav.Prop(["calendar-data"]),
  )
  assert_true(requested.contains("404 Not Found"))
  assert_true(requested.contains("<D:calendar-data/>"))
  assert_false(requested.contains("BEGIN:VCALENDAR"))
}

///|
/// RFC 4918 §9.1.2: a requested property that does not exist is answered
/// in its own 404 propstat, the two-propstat shape the §9.1.3 example
/// shows; the properties that do exist stay in the 200 propstat.
test "a propfind propstat splits into 200 and 404" {
  let selection = @caldav.parse_propfind(
    "<D:propfind xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:prop><D:getetag/><C:calendar-data/></D:prop>" +
    "</D:propfind>",
  )
  // The collection itself has neither property: its response carries
  // only the 404 propstat — no 200 propstat for an all-missing answer.
  let collection_only = @caldav.collection_propfind([], 0, selection~)
  assert_true(collection_only.contains("HTTP/1.1 404 Not Found"))
  assert_true(collection_only.contains("HTTP/1.1 200 OK") is false)
  // At depth 1 the resources do have a getetag: their responses carry
  // the 200 propstat for it and the 404 one for calendar-data.
  let result = @caldav.collection_propfind(resources(), 1, selection~)
  assert_true(result.contains("HTTP/1.1 200 OK"))
  assert_true(result.contains("HTTP/1.1 404 Not Found"))
  assert_true(result.contains("&quot;aaa&quot;"))
  assert_true(result.contains("BEGIN:VCALENDAR") is false)
  // getetag is a resource property, not a collection one: on the
  // collection's own response it is the 404 half.
  let collection_part = result[:result.find("/cal/a.ics").unwrap_or(0)].to_owned()
  assert_true(collection_part.contains("<D:getetag/>"))
  assert_true(collection_part.contains("404 Not Found"))
}

///|
/// RFC 4918 §9.1.4: a `propname` request answers property names with no
/// values, both on a PROPFIND and inside a report.
test "propname answers names without values" {
  let body = "<D:propfind xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><C:propname/></D:propfind>"
  let result = @caldav.collection_propfind(
    resources(),
    1,
    selection=@caldav.parse_propfind(body),
  )
  assert_true(result.contains("<D:resourcetype/>"))
  assert_true(result.contains("<D:getetag/>"))
  assert_false(result.contains("&quot;aaa&quot;"))
  assert_false(result.contains("text/calendar"))
  let query = "<C:calendar-query xmlns:D=\"DAV:\" " +
    "xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:propname/>" +
    "<C:filter><C:comp-filter name=\"VCALENDAR\"/></C:filter>" +
    "</C:calendar-query>"
  let report_names = report_body(query, resources())
  assert_true(report_names.contains("<C:calendar-data/>"))
  assert_false(report_names.contains("BEGIN:VCALENDAR"))
}

///|
/// An empty `PROPFIND` body MUST be read as allprop (RFC 4918 §9.1); the
/// DTD's three selection forms are first-wins in document order when a
/// body names more than one.
test "the selection forms parse by the DTD" {
  assert_eq(@caldav.parse_propfind(""), @caldav.AllProp)
  assert_eq(@caldav.parse_propfind("  \r\n "), @caldav.AllProp)
  assert_eq(
    @caldav.parse_propfind(
      "<D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>",
    ),
    @caldav.AllProp,
  )
  // allprop + include is the §9.1.6 shape; the include is answered by
  // allprop already and read as no extra constraint.
  assert_eq(
    @caldav.parse_propfind(
      "<D:propfind xmlns:D=\"DAV:\"><D:allprop/>" +
      "<D:include><D:getetag/></D:include></D:propfind>",
    ),
    @caldav.AllProp,
  )
  assert_true(
    @caldav.parse_propfind(
      "<D:propfind xmlns:D=\"DAV:\"><D:allprop/><D:propname/></D:propfind>",
    )
    is @caldav.AllProp,
  )
  assert_true(
    @caldav.parse_propfind(
      "<D:propfind xmlns:D=\"DAV:\"><D:propname/><D:allprop/></D:propfind>",
    )
    is @caldav.PropName,
  )
  assert_eq(
    @caldav.parse_propfind(
      "<D:propfind xmlns:D=\"DAV:\"><D:prop>" +
      "<D:getetag/><D:getetag/><C:calendar-data/></D:prop></D:propfind>",
    ),
    @caldav.Prop(["getetag", "calendar-data"]),
  )
}

///|
/// RFC 4918 §14.20 requires a `propfind` to name exactly one selection
/// form; a body that parses but names none of them is malformed, as is
/// one rooted elsewhere or not XML at all.
test "unreadable propfind bodies are refused, not guessed" {
  try @caldav.parse_propfind("this is not xml") catch {
    @caldav.PropfindError::Malformed => ()
  } noraise {
    _ => fail("expected Malformed for a non-XML body")
  }
  try @caldav.parse_propfind("<D:calendar-query xmlns:D=\"DAV:\"/>") catch {
    @caldav.PropfindError::Malformed => ()
  } noraise {
    _ => fail("expected Malformed for a non-propfind root")
  }
  try @caldav.parse_propfind("<D:propfind xmlns:D=\"DAV:\"/>") catch {
    @caldav.PropfindError::Malformed => ()
  } noraise {
    _ => fail("expected Malformed for a selection-less propfind")
  }
}

///|
/// An empty prop request names nothing: the response element still
/// answers, with one empty 200 propstat (R2: the emptiest selection).
test "an empty prop element answers an empty propstat" {
  let result = @caldav.collection_propfind(
    resources(),
    0,
    selection=@caldav.Prop([]),
  )
  assert_true(result.contains("<D:prop></D:prop>"))
  assert_true(result.contains("HTTP/1.1 200 OK"))
  assert_false(result.contains("resourcetype"))
}

///|
/// A property only exists where the resource kind has it: the collection
/// has no `getetag`, an unnamed collection has no `displayname`, and the
/// discovery resources trim to the properties they were asked for.
test "per-kind property tables answer 404 for absent names" {
  let collection = @caldav.collection_propfind(
    [],
    0,
    selection=@caldav.Prop(["getetag"]),
  )
  assert_true(collection.contains("<D:getetag/>"))
  assert_true(collection.contains("404 Not Found"))
  let unnamed = @caldav.collection_propfind(
    [],
    0,
    displayname="",
    selection=@caldav.Prop(["displayname"]),
  )
  assert_true(unnamed.contains("404 Not Found"))
  let root = @caldav.root_propfind(
    selection=@caldav.Prop(["current-user-principal"]),
  )
  assert_true(root.contains("current-user-principal"))
  assert_false(root.contains("resourcetype"))
  let principal = @caldav.principal_propfind(
    selection=@caldav.Prop(["calendar-home-set"]),
  )
  assert_true(principal.contains("calendar-home-set"))
  assert_false(principal.contains("displayname"))
}

///|
/// A name requested twice is answered once (R2 on repetition): the
/// response carries exactly one etag element per resource.
test "a repeated property name collapses to one answer" {
  let result = @caldav.collection_propfind(
    [],
    0,
    selection=@caldav.Prop(["resourcetype", "resourcetype"]),
  )
  assert_eq(result.split("<D:resourcetype>").count(), 2)
}

///|
/// The 404-propstat echo is escaped: the shape parser's name scan admits
/// XML metacharacters, and an unescaped echo would let a request body
/// corrupt the response's markup.
test "an echoed property name is XML-escaped" {
  let selection = @caldav.parse_propfind(
    "<D:propfind xmlns:D=\"DAV:\"><D:prop><D:x<y/></D:prop></D:propfind>",
  )
  let result = @caldav.collection_propfind([], 0, selection~)
  assert_true(result.contains("<D:x&lt;y/>"))
  assert_true(result.contains("x<y") is false)
}

///|
/// Requested names match by lowercased local name: another namespace
/// prefix and mixed case still hit the property — the shape parser
/// keeps local names, and the 200 answer (not a 404 propstat) is the
/// discriminating half.
test "requested names match by local name regardless of prefix" {
  let selection = @caldav.parse_propfind(
    "<D:propfind xmlns:D=\"DAV:\" xmlns:X=\"urn:example\">" +
    "<D:prop><X:Calendar-Home-Set/></D:prop></D:propfind>",
  )
  let result = @caldav.principal_propfind(selection~)
  assert_true(result.contains("<C:calendar-home-set>"))
  assert_true(result.contains("404") is false)
}
