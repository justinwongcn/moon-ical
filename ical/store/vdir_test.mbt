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
async test "names that are not one plain token are refused" {
  assert_eq(name_error("../escape"), "refused store name: ../escape")
  assert_eq(name_error("/abs"), "refused store name: /abs")
  assert_eq(name_error("a/b"), "refused store name: a/b")
  assert_eq(name_error(""), "refused store name: ")
  assert_eq(name_error(".hidden"), "refused store name: .hidden")
  assert_eq(name_error("C:\\x"), "refused store name: C:\\x")
  assert_eq(name_error("a b"), "refused store name: a b")
}
