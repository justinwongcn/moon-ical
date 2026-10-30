///|
// Request skeleton transcribed from RFC 4791 §7.8.1, varied only in tests.
fn temporal_query(kind : String, start : String, end : String) -> String {
  query(
    "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"\{kind}\">" +
    "<C:time-range start=\"\{start}\" end=\"\{end}\"/>" +
    "</C:comp-filter></C:comp-filter>",
  )
}

///|
fn one_resource(data : String) -> Array[@caldav.DavResource] {
  [{ href: "/cal/check.ics", etag: "t", calendar_data: data, }]
}

///|
fn assert_evaluation_failed(body : String, data : String) -> Unit raise {
  match @caldav.report(body, one_resource(data)) {
    @caldav.ReportOutcome::EvaluationFailed(reason~) => {
      assert_true(reason.contains("/cal/check.ics"))
      assert_true(reason.length() > "/cal/check.ics".length())
      assert_false(reason.contains("<C:supported-filter"))
      assert_false(reason.contains("<C:valid-filter"))
    }
    outcome => fail("expected checked evaluation failure, got \{Repr(outcome)}")
  }
}

///|
test "a genuinely empty recurrence never falls back to the master" {
  let data = calendar(
    "UID:e\r\nDTSTART:20260101T090000Z\r\nRRULE:FREQ=DAILY;COUNT=1\r\n",
  )
  let body = temporal_query("VEVENT", "20260101T000000Z", "20260102T000000Z")
  assert_true(report_body(body, one_resource(data)).contains("<D:response>"))
  let excluded = data.replace(
    old="END:VEVENT",
    new="EXDATE:20260101T090000Z\r\nEND:VEVENT",
  )
  assert_false(
    report_body(body, one_resource(excluded)).contains("<D:response>"),
  )
  let cancelled = data.replace(
    old="END:VCALENDAR",
    new="BEGIN:VEVENT\r\nUID:e\r\nRECURRENCE-ID:20260101T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  assert_false(
    report_body(body, one_resource(cancelled)).contains("<D:response>"),
  )
}

///|
test "unsupported RRULE fails temporal evaluation but not SUMMARY or multiget" {
  let good = calendar(
    "UID:e\r\nSUMMARY:Visible\r\nDTSTART:20260101T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\n",
  )
  let bad = good.replace(old="FREQ=DAILY", new="FREQ=HOURLY")
  let body = temporal_query("VEVENT", "20260102T000000Z", "20260103T000000Z")
  assert_true(report_body(body, one_resource(good)).contains("<D:response>"))
  assert_evaluation_failed(body, bad)
  let text = query(
    event_filter(
      "<C:prop-filter name=\"SUMMARY\"><C:text-match>Visible</C:text-match></C:prop-filter>",
    ),
  )
  assert_true(report_body(text, one_resource(bad)).contains("<D:response>"))
  assert_false(
    report_body(text.replace(old="Visible", new="Absent"), one_resource(bad)).contains(
      "<D:response>",
    ),
  )
  assert_true(
    report_body(
      "<C:calendar-multiget xmlns:C=\"urn:ietf:params:xml:ns:caldav\" xmlns:D=\"DAV:\"><D:href>/cal/check.ics</D:href></C:calendar-multiget>",
      one_resource(bad),
    ).contains("FREQ=HOURLY"),
  )
}

///|
test "a query beyond the safety cap cannot pretend its prefix is complete" {
  let data = calendar(
    "UID:e\r\nDTSTART:20060101T090000Z\r\nRRULE:FREQ=DAILY\r\n",
  )
  assert_true(
    report_body(
      temporal_query("VEVENT", "20060102T000000Z", "20060103T000000Z"),
      one_resource(data),
    ).contains("<D:response>"),
  )
  assert_evaluation_failed(
    temporal_query("VEVENT", "20200101T000000Z", "20200102T000000Z"),
    data,
  )
  let sparse = calendar(
    "UID:e\r\nDTSTART:20260228T000000Z\r\nRRULE:FREQ=WEEKLY;BYMONTHDAY=-1\r\n",
  )
  assert_evaluation_failed(
    temporal_query("VEVENT", "23000101T000000Z", "23000201T000000Z"),
    sparse,
  )
}

///|
test "non VEVENT temporal errors and recurrence are not empty results" {
  let good = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:t\r\nSUMMARY:Visible\r\nDTSTART:20260101T090000Z\r\nDURATION:PT1H\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
  let body = temporal_query("VTODO", "20260101T000000Z", "20260102T000000Z")
  assert_true(report_body(body, one_resource(good)).contains("<D:response>"))
  assert_evaluation_failed(body, good.replace(old="PT1H", new="broken"))
  assert_evaluation_failed(
    body,
    good.replace(old="20260101T090000Z", new="20261301T090000Z"),
  )
  assert_evaluation_failed(
    body,
    good.replace(old="END:VTODO", new="RRULE:FREQ=DAILY;COUNT=2\r\nEND:VTODO"),
  )
  let text = query(
    "<C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"VTODO\"><C:prop-filter name=\"SUMMARY\"><C:text-match>Visible</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter>",
  )
  assert_true(
    report_body(text, one_resource(good.replace(old="PT1H", new="broken"))).contains(
      "<D:response>",
    ),
  )
}

///|
test "unsupported request timezone only fails when temporal evaluation needs it" {
  let data = calendar("UID:e\r\nSUMMARY:Visible\r\nDTSTART:20260101T090000\r\n")
  let zone = "<C:timezone>BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:Fixed\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n</C:timezone>"
  let body = temporal_query("VEVENT", "20260101T000000Z", "20260102T000000Z")
  assert_evaluation_failed(
    body.replace(old="</C:calendar-query>", new=zone + "</C:calendar-query>"),
    data,
  )
  let text = query(
    event_filter(
      "<C:prop-filter name=\"SUMMARY\"><C:text-match>Visible</C:text-match></C:prop-filter>",
    ),
  )
  assert_true(
    report_body(
      text.replace(old="</C:calendar-query>", new=zone + "</C:calendar-query>"),
      one_resource(data),
    ).contains("<D:response>"),
  )
}

///|
test "dynamic feed timezone fails only when referenced by a temporal test" {
  let zone = "BEGIN:VTIMEZONE\r\nTZID:Dynamic\r\nBEGIN:STANDARD\r\nDTSTART:19701101T020000\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\nEND:STANDARD\r\nBEGIN:DAYLIGHT\r\nDTSTART:19700308T020000\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n"
  let data = calendar(
    "UID:e\r\nSUMMARY:Visible\r\nDTSTART;TZID=Dynamic:20260701T090000\r\n",
  ).replace(old="BEGIN:VEVENT", new=zone + "BEGIN:VEVENT")
  assert_evaluation_failed(
    temporal_query("VEVENT", "20260701T125900Z", "20260701T130100Z"),
    data,
  )
  let text = query(
    event_filter(
      "<C:prop-filter name=\"SUMMARY\"><C:text-match>Visible</C:text-match></C:prop-filter>",
    ),
  )
  assert_true(report_body(text, one_resource(data)).contains("<D:response>"))
}

///|
test "RDATE selection and exclusion do not confuse recurrence completeness" {
  let data = calendar(
    "UID:e\r\nDTSTART:20260101T090000Z\r\nRDATE:20260201T090000Z\r\n",
  )
  let feb = temporal_query("VEVENT", "20260201T000000Z", "20260202T000000Z")
  assert_true(report_body(feb, one_resource(data)).contains("<D:response>"))
  assert_false(
    report_body(
      feb,
      one_resource(
        data.replace(
          old="END:VEVENT",
          new="EXDATE:20260201T090000Z\r\nEND:VEVENT",
        ),
      ),
    ).contains("<D:response>"),
  )
  let far = calendar(
    "UID:e\r\nDTSTART:20060101T090000Z\r\nRRULE:FREQ=DAILY\r\nRDATE:20500101T090000Z\r\n",
  )
  assert_evaluation_failed(
    temporal_query("VEVENT", "20200101T000000Z", "20200102T000000Z"),
    far,
  )
}

///|
test "future negative shift overrides require exhaustion for an empty answer" {
  let data = calendar(
    "UID:e\r\nDTSTART:20060101T090000Z\r\nRRULE:FREQ=DAILY\r\n",
  ).replace(
    old="END:VCALENDAR",
    new="BEGIN:VEVENT\r\nUID:e\r\nRECURRENCE-ID;RANGE=THISANDFUTURE:20250101T090000Z\r\nDTSTART:20200101T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR",
  )
  // A far future generated slot shifts back into the queried window. A
  // frontier from unshifted slots cannot establish a negative result.
  assert_evaluation_failed(
    temporal_query("VEVENT", "20200101T000000Z", "20200102T000000Z"),
    data,
  )
  assert_true(
    report_body(
      temporal_query("VEVENT", "20060101T000000Z", "20060102T000000Z"),
      one_resource(data),
    ).contains("<D:response>"),
  )
  let bounded = data.replace(old="FREQ=DAILY", new="FREQ=DAILY;COUNT=7000")
  // The shifted target is genuinely present, but above the protocol cap;
  // explicit failure is safer than a fabricated successful empty answer.
  assert_evaluation_failed(
    temporal_query("VEVENT", "20200101T000000Z", "20200102T000000Z"),
    bounded,
  )
}

///|
test "VTODO overlap follows RFC4791 section 9.9 state table" {
  fn todo(props : String) -> String {
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:t\r\n" +
    props +
    "END:VTODO\r\nEND:VCALENDAR\r\n"
  }
  let after = temporal_query("VTODO", "20260101T100000Z", "20260101T110000Z")
  assert_true(
    report_body(after, one_resource(todo(""))).contains("<D:response>"),
  )
  assert_true(
    report_body(
      after,
      one_resource(todo("DTSTART:20260101T090000Z\r\nDURATION:PT1H\r\n")),
    ).contains("<D:response>"),
  )
  assert_false(
    report_body(
      after.replace(old="T100000Z", new="T100001Z"),
      one_resource(todo("DTSTART:20260101T090000Z\r\nDURATION:PT1H\r\n")),
    ).contains("<D:response>"),
  )
  let created = todo("CREATED:20260101T090000Z\r\n")
  assert_true(
    report_body(after, one_resource(created)).contains("<D:response>"),
  )
  assert_false(
    report_body(
      temporal_query("VTODO", "20260101T080000Z", "20260101T090000Z"),
      one_resource(created),
    ).contains("<D:response>"),
  )
  let due = todo("DUE:20260101T100000Z\r\n")
  assert_true(
    report_body(
      temporal_query("VTODO", "20260101T090000Z", "20260101T100000Z"),
      one_resource(due),
    ).contains("<D:response>"),
  )
  assert_false(report_body(after, one_resource(due)).contains("<D:response>"))
}

///|
test "request timezone required fields are unique and floating DATE-TIME" {
  let zone = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:Fixed\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n"
  let body = temporal_query("VEVENT", "20260101T000000Z", "20260102T000000Z")
  for
    invalid in [
      zone.replace(old="VERSION:2.0", new="VERSION:1.0"),
      zone.replace(old="VERSION:2.0", new="VERSION:2.0\r\nVERSION:2.0"),
      zone.replace(old="TZID:Fixed", new="TZID:Fixed\r\nTZID:Fixed"),
      zone.replace(
        old="DTSTART:19700101T000000",
        new="DTSTART;VALUE=DATE:19700101",
      ),
      zone.replace(
        old="DTSTART:19700101T000000",
        new="DTSTART:19700101T000000Z",
      ),
      zone.replace(
        old="DTSTART:19700101T000000",
        new="DTSTART:19700101T000000\r\nDTSTART:19700101T000000",
      ),
      zone.replace(
        old="TZOFFSETTO:+0900",
        new="TZOFFSETTO:+0900\r\nTZOFFSETTO:+0900",
      ),
    ] {
    let request = body.replace(
      old="</C:calendar-query>",
      new="<C:timezone>" + invalid + "</C:timezone></C:calendar-query>",
    )
    match @caldav.report(request, resources()) {
      @caldav.ReportOutcome::PreconditionFailed(body~) =>
        assert_true(body.contains("<C:valid-calendar-data/>"))
      other => fail("expected valid-calendar-data: \{Repr(other)}")
    }
  }
}

///|
test "evaluation reasons never disclose private calendar content" {
  for
    data in [
      calendar(
        "UID:e\r\nDTSTART:20260101T090000Z\r\nDURATION:PRIVATE-SENTINEL\r\n",
      ),
      "PRIVATE-SENTINEL",
    ] {
    match
      @caldav.report(
        temporal_query("VEVENT", "20260101T000000Z", "20260102T000000Z"),
        one_resource(data),
      ) {
      @caldav.ReportOutcome::EvaluationFailed(reason~) => {
        assert_false(reason.contains("PRIVATE-SENTINEL"))
        assert_true(reason.contains("/cal/check.ics"))
      }
      other => fail("expected safe failure: \{Repr(other)}")
    }
  }
}

///|
test "collation and UTC range preconditions retain the precise error element" {
  let text = query(
    event_filter(
      "<C:prop-filter name=\"SUMMARY\"><C:text-match collation=\"i;unknown\">A</C:text-match></C:prop-filter>",
    ),
  )
  match @caldav.report(text, resources()) {
    @caldav.ReportOutcome::PreconditionFailed(body~) => {
      assert_true(body.contains("<C:supported-collation/>"))
      assert_false(body.contains("supported-filter"))
    }
    other => fail("expected collation precondition: \{Repr(other)}")
  }
  match
    @caldav.report(
      text.replace(
        old="</C:calendar-query>",
        new="<C:timezone>broken</C:timezone></C:calendar-query>",
      ),
      resources(),
    ) {
    @caldav.ReportOutcome::PreconditionFailed(body~) =>
      assert_true(body.contains("<C:valid-calendar-data/>"))
    other => fail("expected timezone precondition: \{Repr(other)}")
  }
  assert_true(
    report_body(text.replace(old="i;unknown", new="i;octet"), resources()).contains(
      "<D:response>",
    ),
  )
  match
    @caldav.report(
      temporal_query("VEVENT", "20260101", "20260201T000000Z"),
      resources(),
    ) {
    @caldav.ReportOutcome::PreconditionFailed(body~) =>
      assert_true(body.contains("<C:valid-filter/>"))
    other => fail("expected valid-filter: \{Repr(other)}")
  }
}
