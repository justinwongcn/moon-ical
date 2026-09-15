///|
/// A deliberately override-heavy feed. Most overrides belong to another UID:
/// series expansion should discard them once, not inspect them for every slot.
fn series_benchmark_events() -> Array[@model.Event] raise {
  let feed = StringBuilder()
  feed.write_string(
    "BEGIN:VCALENDAR\r\n" +
    "BEGIN:VEVENT\r\nUID:bench\r\nDTSTART:20260101T090000Z\r\n" +
    "RRULE:FREQ=DAILY;COUNT=2000\r\nSUMMARY:base\r\nEND:VEVENT\r\n",
  )
  for _ in 0..<500 {
    feed.write_string(
      "BEGIN:VEVENT\r\nUID:other\r\n" +
      "RECURRENCE-ID:20260102T090000Z\r\n" +
      "DTSTART:20260102T100000Z\r\nEND:VEVENT\r\n",
    )
  }
  feed.write_string("END:VCALENDAR\r\n")
  @model.parse_events(feed.to_string())
}

///|
test "bench expand_series occurrences=2000 unrelated_overrides=500" (
  it : @bench.T,
) {
  let events = series_benchmark_events()
  it.bench(() => {
    let occurrences = try! @rrule.expand_series(events, limit=2000)
    it.keep(occurrences)
  })
}
