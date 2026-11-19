///|
test "first_uid reads the master's UID from raw text" {
  // The plain shape every client writes.
  assert_eq(
    @caldav.first_uid(
      "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a@x\r\nDTSTART:20260915T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
    Some("a@x"),
  )
  // A folded UID is unfolded before the name scan (RFC 5545 3.1) — the
  // index must not miss what the wire actually carried.
  assert_eq(
    @caldav.first_uid(
      "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:long-\r\n value@x\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
    Some("long-value@x"),
  )
  // Parameters before the colon do not hide the name.
  assert_eq(
    @caldav.first_uid("BEGIN:VEVENT\r\nUID;X-PARAM=1:param@x\r\nEND:VEVENT\r\n"),
    Some("param@x"),
  )
  // The first UID wins; a series in one resource shares its master's.
  assert_eq(
    @caldav.first_uid(
      "BEGIN:VEVENT\r\nUID:master\r\nRECURRENCE-ID:20260916T090000Z\r\nUID:ignored\r\nEND:VEVENT\r\n",
    ),
    Some("master"),
  )
}

///|
test "first_uid answers None for anything without a UID" {
  assert_eq(
    @caldav.first_uid(
      "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260915T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
    ),
    None,
  )
  assert_eq(@caldav.first_uid(""), None)
  assert_eq(@caldav.first_uid("not a calendar"), None)
  // An empty UID value cannot conflict with anything.
  assert_eq(@caldav.first_uid("BEGIN:VEVENT\r\nUID:\r\nEND:VEVENT\r\n"), None)
  // A name that merely contains UID as a prefix is not a UID.
  assert_eq(
    @caldav.first_uid("BEGIN:VEVENT\r\nUIDEXTRA:no\r\nEND:VEVENT\r\n"),
    None,
  )
}

///|
test "uid_conflict refuses a taken UID naming the holding href" {
  // RFC 4791 5.3.2.1: a new resource may not claim a UID another
  // resource already holds; the DTD's (DAV:href) points there.
  let index : Map[String, String] = Map([("taken@x", "/cal/first.ics")])
  assert_eq(
    @caldav.uid_conflict(Some("taken@x"), None, "/cal/second.ics", index),
    Some(
      "<C:no-uid-conflict><D:href>/cal/first.ics</D:href></C:no-uid-conflict>",
    ),
  )
  // A fresh UID on a fresh resource passes.
  assert_eq(
    @caldav.uid_conflict(Some("new@x"), None, "/cal/second.ics", index),
    None,
  )
}

///|
test "uid_conflict refuses an overwrite that changes the UID" {
  // Overwriting a resource with a different UID is the same
  // precondition; the conflicting resource is the one being written.
  let index : Map[String, String] = Map([])
  assert_eq(
    @caldav.uid_conflict(Some("b@x"), Some("a@x"), "/cal/over.ics", index),
    Some(
      "<C:no-uid-conflict><D:href>/cal/over.ics</D:href></C:no-uid-conflict>",
    ),
  )
  // Same UID over the same resource is the normal PUT replace.
  assert_eq(
    @caldav.uid_conflict(Some("a@x"), Some("a@x"), "/cal/over.ics", index),
    None,
  )
}

///|
test "uid_conflict lets UID-less bodies through" {
  // The door's R8-shape tolerance keeps UID-less resources legal; they
  // cannot conflict, so no-uid-conflict has nothing to say.
  let index : Map[String, String] = Map([("taken@x", "/cal/first.ics")])
  assert_eq(@caldav.uid_conflict(None, None, "/cal/new.ics", index), None)
  assert_eq(
    @caldav.uid_conflict(None, Some("a@x"), "/cal/over.ics", index),
    None,
  )
}
