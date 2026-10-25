///|
test "the RFC 4791 5.3.1 MKCALENDAR example parses its displayname" {
  // Transcribed mechanically from RFC 4791 section 5.3.1's request body
  // example (R5): the displayname sits in the outer DAV:prop.
  let body = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>" +
    "<C:mkcalendar xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:set><D:prop>" +
    "<D:resourcetype><D:collection/><C:calendar/></D:resourcetype>" +
    "<C:supported-calendar-component-set><C:comp name=\"VEVENT\"/></C:supported-calendar-component-set>" +
    "</D:prop></D:set>" +
    "<D:prop><D:displayname>Lisa's Events</D:displayname></D:prop>" +
    "</C:mkcalendar>"
  let props = @caldav.parse_mkcalendar(body)
  assert_eq(props.displayname, Some("Lisa's Events"))
  assert_eq(props.description, None)
  assert_eq(props.color, None)
}

///|
test "MKCALENDAR properties decode entities and read set-prop spellings" {
  // The same property may ride in DAV:set/DAV:prop instead of the outer
  // DAV:prop; entities decode like any other character data (S13/S28).
  let body = "<C:mkcalendar xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
    "<D:set><D:prop>" +
    "<D:displayname>R&amp;D</D:displayname>" +
    "<C:calendar-color>#3A57E8</C:calendar-color>" +
    "</D:prop></D:set>" +
    "<C:calendar-description>Year &#38; quarter planning</C:calendar-description>" +
    "</C:mkcalendar>"
  let props = @caldav.parse_mkcalendar(body)
  assert_eq(props.displayname, Some("R&D"))
  assert_eq(props.description, Some("Year & quarter planning"))
  assert_eq(props.color, Some("#3A57E8"))
}

///|
test "an absent or non-XML MKCALENDAR body asks for no properties" {
  // RFC 4791 5.3.1 makes the body optional; the collection's name is
  // its display name, so an unreadable body parses as "nothing asked"
  // rather than failing the request.
  assert_eq(@caldav.parse_mkcalendar(""), {
    displayname: None,
    description: None,
    color: None,
  })
  assert_eq(@caldav.parse_mkcalendar("not xml at all"), {
    displayname: None,
    description: None,
    color: None,
  })
}
