
///|
// Run against an isolated live cmd/serve instance. Request skeletons follow
// RFC 4791 §7.8.1; all curl arguments are literal, no shell interpretation.
async fn request(
  base : String,
  meth : String,
  path : String,
  body : String,
) -> (String, String) {
  let out = @shell.Cmd("curl", [
    "-sS",
    "--max-time",
    "15",
    "-X",
    meth,
    base + path,
    "-H",
    if meth == "PUT" {
      "Content-Type: text/calendar"
    } else {
      "Content-Type: application/xml"
    },
    "--data-binary",
    body,
    "-w",
    "\n%{http_code}",
  ]).output()
  out.check()
  let raw = out.stdout()
  let at = raw.length() - 4
  (raw[at + 1:].to_owned(), raw[:at].to_owned())
}

///|
fn query(inner : String) -> String {
  "<C:calendar-query xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
  "<D:prop><D:getetag/><C:calendar-data/></D:prop><C:filter>" +
  "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VEVENT\">" +
  inner +
  "</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>"
}

///|
fn event(rule : String, extra : String) -> String {
  "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:evaluation-live\r\n" +
  "SUMMARY:Visible\r\nDTSTART:20260101T090000Z\r\nRRULE:" +
  rule +
  "\r\n" +
  extra +
  "END:VEVENT\r\nEND:VCALENDAR\r\n"
}

///|
fn assert_single_href(body : String, path : String) -> Unit raise {
  assert_true(body.has_prefix("<?xml"))
  assert_true(
    body.contains(
      "<D:multistatus xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">",
    ),
  )
  let mut count = 0
  for _ in body.split("<D:response>") {
    count += 1
  }
  assert_eq(count, 2)
  assert_true(body.contains("<D:href>" + path + "</D:href>"))
}

///|
fn assert_empty_report(body : String) -> Unit raise {
  assert_eq(
    body, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\"></D:multistatus>",
  )
}

///|
async fn main {
  let args = @env.args()
  let base = args[1]
  let path = "/cal/evaluation-live.ics"
  let temporal = query(
    "<C:time-range start=\"20260102T000000Z\" end=\"20260103T000000Z\"/>",
  )
  let text = query(
    "<C:prop-filter name=\"SUMMARY\"><C:text-match>Visible</C:text-match></C:prop-filter>",
  )
  let good = event("FREQ=DAILY;COUNT=2", "")
  let bad = event("FREQ=HOURLY;COUNT=2", "")
  let (put, _) = request(base, "PUT", path, good)
  assert_true(put == "201" || put == "204")
  let (code, body) = request(base, "REPORT", "/cal/", temporal)
  assert_eq(code, "207")
  assert_single_href(body, path)
  // The S53 door moved the "unimplemented recurrence" contract to the
  // write path: a sub-daily rule is a 403 with valid-calendar-data at
  // PUT, and the stored resource — still the good event — keeps
  // answering clean reports. The fail-closed 500 remains the contract
  // for content that bypassed the door (hand-seeded files below), not
  // for anything HTTP stored.
  let (put, put_body) = request(base, "PUT", path, bad)
  assert_eq(put, "403")
  assert_true(put_body.contains("<C:valid-calendar-data/>"))
  let (code, body) = request(base, "REPORT", "/cal/", temporal)
  assert_eq(code, "207")
  assert_single_href(body, path)
  assert_false(body.contains("recurrence rule"))
  let (code, body) = request(base, "REPORT", "/cal/", text)
  assert_eq(code, "207")
  assert_single_href(body, path)
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    text.replace(old="Visible", new="Absent"),
  )
  assert_eq(code, "207")
  assert_empty_report(body)
  let (code, body) = request(base, "GET", path, "")
  assert_eq(code, "200")
  assert_eq(body, good)
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    text.replace(
      old="<C:text-match>",
      new="<C:text-match collation=\"i;unknown\">",
    ),
  )
  assert_eq(code, "403")
  assert_true(body.contains("<C:supported-collation/>"))
  assert_true(body.contains("xmlns:C=\"urn:ietf:params:xml:ns:caldav\""))
  assert_false(body.contains("supported-filter"))
  let first = query(
    "<C:time-range start=\"20260101T000000Z\" end=\"20260102T000000Z\"/>",
  )
  ignore(request(base, "PUT", path, event("FREQ=DAILY;COUNT=1", "")))
  let (code, body) = request(base, "REPORT", "/cal/", first)
  assert_eq(code, "207")
  assert_single_href(body, path)
  ignore(
    request(
      base,
      "PUT",
      path,
      event("FREQ=DAILY;COUNT=1", "EXDATE:20260101T090000Z\r\n"),
    ),
  )
  let (code, body) = request(base, "REPORT", "/cal/", first)
  assert_eq(code, "207")
  assert_empty_report(body)
  let far = event("FREQ=DAILY", "").replace(old="20260101", new="20060101")
  ignore(request(base, "PUT", path, far))
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    query("<C:time-range start=\"20200101T000000Z\" end=\"20200102T000000Z\"/>"),
  )
  assert_eq(code, "500")
  assert_true(body.contains("coverage"))
  assert_false(body.contains("number-of-matches-within-limits"))
  let rdate = event("FREQ=DAILY;COUNT=1", "RDATE:20260201T090000Z\r\n")
  let feb = query(
    "<C:time-range start=\"20260201T000000Z\" end=\"20260202T000000Z\"/>",
  )
  ignore(request(base, "PUT", path, rdate))
  let (code, body) = request(base, "REPORT", "/cal/", feb)
  assert_eq(code, "207")
  assert_single_href(body, path)
  ignore(
    request(
      base,
      "PUT",
      path,
      rdate.replace(
        old="END:VEVENT",
        new="EXDATE:20260201T090000Z\r\nEND:VEVENT",
      ),
    ),
  )
  let (code, body) = request(base, "REPORT", "/cal/", feb)
  assert_eq(code, "207")
  assert_empty_report(body)
  ignore(
    request(
      base,
      "PUT",
      path,
      far.replace(old="END:VEVENT", new="RDATE:20500101T090000Z\r\nEND:VEVENT"),
    ),
  )
  let (code, _) = request(
    base,
    "REPORT",
    "/cal/",
    query("<C:time-range start=\"20200101T000000Z\" end=\"20200102T000000Z\"/>"),
  )
  assert_eq(code, "500")
  let shifted = far.replace(
    old="END:VCALENDAR",
    new="BEGIN:VEVENT\r\nUID:evaluation-live\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20250101T090000Z\r\nDTSTART:20200101T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  ignore(request(base, "PUT", path, shifted))
  let (code, _) = request(
    base,
    "REPORT",
    "/cal/",
    query("<C:time-range start=\"20200101T000000Z\" end=\"20200102T000000Z\"/>"),
  )
  assert_eq(code, "500")
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    query("<C:time-range start=\"20060101T000000Z\" end=\"20060102T000000Z\"/>"),
  )
  assert_eq(code, "207")
  assert_single_href(body, path)
  let fixed = "BEGIN:VTIMEZONE\r\nTZID:Private\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
  let zoned = good
    .replace(old="BEGIN:VEVENT", new=fixed + "BEGIN:VEVENT")
    .replace(
      old="DTSTART:20260101T090000Z",
      new="DTSTART;TZID=Private:20260101T090000",
    )
  let narrow = query(
    "<C:time-range start=\"20260101T000000Z\" end=\"20260101T000100Z\"/>",
  )
  ignore(request(base, "PUT", path, zoned))
  let (code, body) = request(base, "REPORT", "/cal/", narrow)
  assert_eq(code, "207")
  assert_single_href(body, path)
  let dynamic = zoned.replace(
    old="END:VTIMEZONE",
    new="BEGIN:DAYLIGHT\r\nDTSTART:19700308T020000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+1000\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE",
  )
  // Same contract move: a zone binding the typed parse refuses is a
  // 403 at PUT, and the last door-accepted resource keeps serving.
  let (put, put_body) = request(base, "PUT", path, dynamic)
  assert_eq(put, "403")
  assert_true(put_body.contains("<C:valid-calendar-data/>"))
  let (code, body) = request(base, "REPORT", "/cal/", narrow)
  assert_eq(code, "207")
  assert_single_href(body, path)
  let (code, body) = request(base, "REPORT", "/cal/", text)
  assert_eq(code, "207")
  assert_single_href(body, path)
  let (code, body) = request(base, "GET", path, "")
  assert_eq(code, "200")
  assert_eq(body, zoned)
  // S60 narrowed the door to the advertised VEVENT-only set: a VTODO
  // is a 403 with supported-calendar-component before it can be stored,
  // and the VTODO-filtered query answers an empty report — nothing is
  // there to fail closed on.
  let todo = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:evaluation-live\r\nDTSTART:20260101T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
  let (put, put_body) = request(base, "PUT", path, todo)
  assert_eq(put, "403")
  assert_true(put_body.contains("<C:supported-calendar-component/>"))
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    first.replace(old="VEVENT", new="VTODO"),
  )
  assert_eq(code, "207")
  assert_empty_report(body)
  ignore(request(base, "PUT", path, good))
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    first.replace(
      old="</C:calendar-query>",
      new="<C:timezone>BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:Fixed\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n</C:timezone></C:calendar-query>",
    ),
  )
  assert_eq(code, "500")
  assert_true(body.contains("unsupported temporal evaluation"))
  let (code, body) = request(
    base,
    "REPORT",
    "/cal/",
    first.replace(
      old="</C:calendar-query>",
      new="<C:timezone>broken</C:timezone></C:calendar-query>",
    ),
  )
  assert_eq(code, "403")
  assert_true(body.contains("<C:valid-calendar-data/>"))
  // The door refuses both poison shapes at PUT — a sentinel can never
  // reach the store through HTTP. The privacy receipt therefore moves
  // to a hand-seeded file: the one shape that bypasses the door, and
  // the reason the fail-closed path still exists at all.
  for
    private_data in [
      event("FREQ=DAILY;COUNT=1", "DURATION:PRIVATE-SENTINEL\r\n"),
      "PRIVATE-SENTINEL",
    ] {
    let (put, _) = request(base, "PUT", path, private_data)
    assert_eq(put, "403")
    let (code, body) = request(base, "REPORT", "/cal/", first)
    assert_eq(code, "207")
    assert_single_href(body, path)
    assert_false(body.contains("PRIVATE-SENTINEL"))
  }
  // args[3] is the server's data directory. Hand-seed what the door
  // would never store, then watch the report fail closed naming the
  // href while the log carries the reason but never the sentinel.
  let seed = event("FREQ=DAILY;COUNT=1", "DURATION:PRIVATE-SENTINEL\r\n")
  @afs.write_file(args[3] + "/seed-private.ics", seed)
  let (code, body) = request(base, "REPORT", "/cal/", first)
  assert_eq(code, "500")
  assert_false(body.contains("PRIVATE-SENTINEL"))
  assert_true(body.has_prefix("/cal/seed-private.ics:"))
  let log = @fs.read_file_to_string(args[2])
  assert_false(log.contains("PRIVATE-SENTINEL"))
  assert_true(log.contains("REPORT evaluation failed:"))
  let (code, _) = request(base, "DELETE", path, "")
  assert_eq(code, "204")
  println(
    "HTTP evaluation acceptance passed: door/empty/cap/collation/VTODO/timezone/text/GET/log",
  )
}
