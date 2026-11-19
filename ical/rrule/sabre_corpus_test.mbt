///|
/// Sabre/vobject corpus port (S55): the override-merge cases from
/// sabre-io/vobject's `EventIterator` tests, transcribed as differential
/// fixtures for `expand_series` — the third-party oracle for the
/// master-plus-overrides model that the RRULE corpus (graham) does not
/// cover.
///
/// Two upstream cases are excluded rather than ported, both model
/// differences with the RFC on moon's side:
///
/// - `SameDateForRecurringEventsTest`: overrides whose UID differs from
///   the master. RFC 5545 §3.8.4.4 requires overrides to carry the
///   master's UID; moon skips foreign-UID overrides (strict), sabre
///   leniently accepts. Pinned in the last test below.
/// - `NoInstancesTest`: expects `NoInstancesException` when EXDATE
///   excludes every instance. Moon's query model answers an empty result
///   (R2 discipline) — pinned in the last test below.
///
/// Adaptations: upstream's dynamic TZIDs (Europe/Berlin, Europe/Kiev) are
/// strict-rejected by the zone layer, so the ported bodies use UTC wall
/// times (mechanical offset shift; no DST transition inside any asserted
/// window), and `OverrideDuration`'s override carries the master's UID
/// (upstream sloppiness; the tested semantics is the override duration).

///|
test "sabre: MissingOverridden - an override replaces its slot and moves outside the window" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:foo\r\nDTSTART:20130727T120000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;COUNT=2\r\nSUMMARY:A\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:foo\r\nRECURRENCE-ID:20130728T120000Z\r\nDTSTART:20140101T120000Z\r\nDURATION:PT1H\r\nSUMMARY:B\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2013-07-27T12:00:00Z", "2014-01-01T12:00:00Z",
  ])
  assert_eq(merged.map(x => x.summary.unwrap_or("")), ["A", "B"])
  assert_eq(merged.map(x => x.end.map(e => e.to_string())), [
    Some("2013-07-27T13:00:00Z"),
    Some("2014-01-01T13:00:00Z"),
  ])
}

///|
test "sabre: OverrideDuration - an override carries its own duration" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20210517T070000Z\r\nDTEND:20210517T080000Z\r\nRRULE:FREQ=DAILY\r\nSUMMARY:short\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:1\r\nRECURRENCE-ID:20210519T070000Z\r\nDTSTART:20210519T070000Z\r\nDTEND:20210519T100000Z\r\nSUMMARY:long\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  let spans = []
  for i in 0..<4 {
    let o = merged[i]
    spans.push(
      "\{o.start.to_string()}..\{o.end.map(e => e.to_string()).unwrap_or("-")} \{o.summary.unwrap_or("")}",
    )
  }
  assert_eq(spans, [
    "2021-05-17T07:00:00Z..2021-05-17T08:00:00Z short", "2021-05-18T07:00:00Z..2021-05-18T08:00:00Z short",
    "2021-05-19T07:00:00Z..2021-05-19T10:00:00Z long", "2021-05-20T07:00:00Z..2021-05-20T08:00:00Z short",
  ])
}

///|
test "sabre: OverrideFirstEvent - the first instance is overridden in place" {
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:foobar\r\nDTSTART:20140803T120000Z\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:Original\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:foobar\r\nRECURRENCE-ID:20140803T120000Z\r\nDTSTART:20140803T120000Z\r\nSUMMARY:Overridden\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  let starts = []
  let summaries = []
  for i in 0..<5 {
    starts.push(merged[i].start.to_string())
    summaries.push(merged[i].summary.unwrap_or(""))
  }
  assert_eq(starts, [
    "2014-08-03T12:00:00Z", "2014-08-10T12:00:00Z", "2014-08-17T12:00:00Z", "2014-08-24T12:00:00Z",
    "2014-08-31T12:00:00Z",
  ])
  assert_eq(summaries, [
    "Overridden", "Original", "Original", "Original", "Original",
  ])
}

///|
test "sabre SameDate divergence: overrides with foreign UIDs are not series members" {
  // RFC 5545 §3.8.4.4 requires overrides to carry the master's UID. Moon
  // skips foreign-UID overrides (strict); sabre leniently accepts them.
  // Pinned here as the documented divergence.
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20160713T080000Z\r\nDTEND:20160713T083000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:2\r\nDTSTART:20160713T080000Z\r\nRECURRENCE-ID:20160714T080000Z\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:3\r\nDTSTART:20160713T080000Z\r\nRECURRENCE-ID:20160715T080000Z\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [
    "2016-07-13T08:00:00Z", "2016-07-14T08:00:00Z", "2016-07-15T08:00:00Z",
  ])
}

///|
test "sabre NoInstances divergence: a fully excluded series answers empty" {
  // Sabre's iterator model raises NoInstancesException; moon's query model
  // answers an empty result — selecting operations must be able to return
  // nothing rather than throw (R2 discipline).
  let text = "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:foo\r\nDTSTART:20130329T130000Z\r\nDTEND:20130329T140000Z\r\nRRULE:FREQ=WEEKLY;BYDAY=FR;UNTIL=20130412T115959Z\r\nEXDATE:20130405T130000Z\r\nEXDATE:20130329T130000Z\r\nSUMMARY:foo\r\nEND:VEVENT\r\n" +
    "END:VCALENDAR\r\n"
  let merged = @rrule.expand_series(@model.parse_events(text))
  assert_eq(merged.map(x => x.start.to_string()), [])
}
