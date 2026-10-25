///|
/// The filesystem round trip lives here because this package is
/// native-only (`supported_targets = "+native"`): the wasm `@fs` is a
/// stub (seam S1), so the default-target test run never sees it, and
/// `moon test --target native` exercises it for real.
async test "store put/get/delete round-trip through the vdir" {
  let dir = @fs.tmpdir(prefix="moon-ical-serve-")
  let store = @store.VdirStore::new("\{dir}/cal")
  assert_eq(store.list(), [])
  let body = "BEGIN:VCALENDAR\r\nUID:one\r\nEND:VCALENDAR\r\n"
  let tag = store.put("one.ics", body)
  assert_eq(store.get("one.ics").unwrap().text, body)
  assert_eq(store.get("one.ics").unwrap().etag, tag)
  assert_eq(store.list(), ["one.ics"])
  let tag2 = store.put(
    "one.ics", "BEGIN:VCALENDAR\r\nUID:two\r\nEND:VCALENDAR\r\n",
  )
  assert_true(tag != tag2)
  assert_eq(store.put("one.ics", body), tag)
  assert_true(store.get("absent.ics") is None)
  assert_eq(store.delete("one.ics"), true)
  assert_eq(store.delete("one.ics"), false)
  assert_eq(store.list(), [])
  @fs.rmdir(dir, recursive=true)
}

///|
test "target_of classifies the calendar routes" {
  assert_true(target_of("/cal/a.ics") is Event(collection=None, name="a.ics"))
  assert_true(target_of("/cal/work/") is Collection(name="work"))
  assert_true(
    target_of("/cal/work/a.ics") is Event(collection=Some("work"), name="a.ics"),
  )
  // Without a trailing slash the path is still an event in the default
  // collection, which is what the first release served.
  assert_true(target_of("/cal/work") is Event(collection=None, name="work"))
  assert_true(target_of("/cal/") is Home)
  assert_true(target_of("/cal") is Home)
  assert_true(target_of("/") is Root)
  assert_true(target_of("/principals/default/") is Principal)
  assert_true(target_of("/.well-known/caldav") is WellKnown)
  assert_true(target_of("/other/a.ics") is Unknown)
}
