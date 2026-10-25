///|
test "the ETag is content-addressed: same bytes, same tag" {
  let a = @store.etag_of("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
  let b = @store.etag_of("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
  assert_eq(a, b)
  assert_true(a.length() > 0)
}

///|
test "any content change moves the ETag" {
  let base = @store.etag_of("UID:a")
  assert_true(base != @store.etag_of("UID:b"))
  assert_true(base != @store.etag_of("UID:a\r\n"))
  assert_true(base != @store.etag_of("uid:a"))
  assert_true(@store.etag_of("") != @store.etag_of("x"))
}

///|
/// Every refused name raises before any filesystem call, so this test
/// exercises pure validation and runs on every target.
async fn name_error(name : String) -> String {
  try {
    let store = @store.VdirStore::new("/unused")
    let _ = store.put(name, "x")
    "no-error"
  } catch {
    err => err.to_string()
  }
}

///|
/// A collection created over HTTP is a real directory holding real events, so
/// this walks the whole lifecycle the CalDAV layer drives.
async test "a created collection holds its own events" {
  let dir = @fs.tmpdir(prefix="moon-ical-vdir-")
  let store = @store.VdirStore::new("\{dir}/cal")
  assert_eq(store.collections(), [])
  assert_true(store.collection("work") is None)
  assert_eq(store.create_collection("work"), true)
  // Creating it twice is refused, which the CalDAV layer answers with 405.
  assert_eq(store.create_collection("work"), false)
  assert_eq(store.collections(), ["work"])
  let nested = store.collection("work").unwrap()
  let _ = nested.put("a.ics", "BEGIN:VCALENDAR\r\nUID:a\r\nEND:VCALENDAR\r\n")
  assert_eq(nested.list(), ["a.ics"])
  // A nested collection's events are not the parent's.
  assert_eq(store.list(), [])
  // A collection still holding events is not removed out from under them.
  assert_eq(store.remove_collection("work"), false)
  assert_eq(nested.delete("a.ics"), true)
  assert_eq(store.remove_collection("work"), true)
  assert_eq(store.collections(), [])
  assert_true(store.collection("work") is None)
  assert_true(store.collection("a b") is None)
  @fs.rmdir(dir, recursive=true)
}

///|
async test "names that are not one plain token are refused" {
  assert_eq(name_error("../escape"), "refused store name: ../escape")
  assert_eq(name_error("/abs"), "refused store name: /abs")
  assert_eq(name_error("a/b"), "refused store name: a/b")
  assert_eq(name_error(""), "refused store name: ")
  assert_eq(name_error(".hidden"), "refused store name: .hidden")
  assert_eq(name_error("C:\\x"), "refused store name: C:\\x")
  assert_eq(name_error("a b"), "refused store name: a b")
}

///|
test "Windows reserved device names are refused as store names" {
  // The base is reserved with or without an extension (CON.ics too);
  // longer spellings and COM10 are ordinary names. The refusal applies
  // on every platform: a vdir that Windows cannot read breaks the
  // portability the layout exists for.
  assert_eq(@store.is_store_name("CON"), false)
  assert_eq(@store.is_store_name("con.ics"), false)
  assert_eq(@store.is_store_name("Prn"), false)
  assert_eq(@store.is_store_name("NUL"), false)
  assert_eq(@store.is_store_name("AUX"), false)
  assert_eq(@store.is_store_name("COM1"), false)
  assert_eq(@store.is_store_name("lpt9"), false)
  assert_eq(@store.is_store_name("COM10"), true)
  assert_eq(@store.is_store_name("console"), true)
  assert_eq(@store.is_store_name("auxiliary"), true)
  assert_eq(@store.is_store_name("a.ics"), true)
}
