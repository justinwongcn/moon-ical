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
test "event_name only recognises /cal/<name> paths" {
  assert_eq(event_name("/cal/a.ics"), Some("a.ics"))
  assert_eq(event_name("/cal/a"), Some("a"))
  assert_eq(event_name("/cal/"), None)
  assert_eq(event_name("/other/a.ics"), None)
  assert_eq(event_name("/"), None)
}
