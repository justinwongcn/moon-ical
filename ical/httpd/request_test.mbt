///|
async fn request_of(raw : String) -> @httpd.HttpRequest? {
  let reader = @io.MemoryReader() <| w => { w.write(raw) }
  defer reader.close()
  @httpd.read_request(reader)
}

///|
async fn request_error_of(raw : String) -> String {
  try {
    match request_of(raw) {
      Some(_) => "no-error"
      None => "clean-disconnect"
    }
  } catch {
    err => err.to_string()
  }
}

///|
async test "a GET request with no body parses" {
  let req = request_of("GET /cal/a.ics HTTP/1.1\r\nHost: x\r\n\r\n").unwrap()
  assert_eq(req.meth, "GET")
  assert_eq(req.path, "/cal/a.ics")
  assert_eq(req.version, "HTTP/1.1")
  assert_eq(req.body, "")
  assert_eq(req.header("HOST"), Some("x"))
}

///|
async test "a clean EOF before any request bytes is a disconnect, not an error" {
  assert_true(request_of("") is None)
  // Blank lines before a request line are tolerated (RFC 7230 §3.5),
  // and an EOF after them is still just a disconnect.
  assert_true(request_of("\r\n\r\n") is None)
}

///|
async test "method tokens are kept verbatim, including WebDAV ones" {
  let req = request_of("PROPFIND /cal/ HTTP/1.1\r\nDepth: 1\r\n\r\n").unwrap()
  assert_eq(req.meth, "PROPFIND")
  assert_eq(req.header("depth"), Some("1"))
  let req2 = request_of("REPORT /cal/ HTTP/1.1\r\n\r\n").unwrap()
  assert_eq(req2.meth, "REPORT")
}

///|
async test "bare LF line endings are tolerated" {
  let req = request_of("PUT /cal/a.ics HTTP/1.1\nContent-Length: 2\n\nhi").unwrap()
  assert_eq(req.meth, "PUT")
  assert_eq(req.body, "hi")
}

///|
async test "a Content-Length body is read and header lookups fold case" {
  let body = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
  let req = request_of(
    "PUT /cal/a.ics HTTP/1.1\r\nContent-Type: text/calendar\r\nContent-Length: \{body.length()}\r\n\r\n\{body}",
  ).unwrap()
  assert_eq(req.body, body)
  assert_eq(req.header("content-type"), Some("text/calendar"))
  assert_eq(req.header("CONTENT-LENGTH"), Some(body.length().to_string()))
  assert_eq(req.header("absent"), None)
}

///|
async test "repeated headers are kept in arrival order" {
  let req = request_of("GET / HTTP/1.1\r\nX-A: 1\r\nX-B: 2\r\nX-A: 3\r\n\r\n").unwrap()
  assert_eq(req.headers.length(), 3)
  assert_eq(req.headers[0], { name: "x-a", value: "1", })
  assert_eq(req.headers[2], { name: "x-a", value: "3", })
  // The first value wins the lookup.
  assert_eq(req.header("X-A"), Some("1"))
}

///|
async test "a chunked request body is refused" {
  assert_eq(
    request_error_of(
      "PUT /cal/a.ics HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n",
    ),
    "chunked request bodies are not supported",
  )
}

///|
async test "malformed request lines and headers are refused" {
  assert_eq(
    request_error_of("garbage\r\n\r\n"),
    "malformed request: bad request line: garbage",
  )
  assert_eq(
    request_error_of("GET / HTTP/1.1\r\nbad header line\r\n\r\n"),
    "malformed request: bad header: bad header line",
  )
  assert_eq(
    request_error_of("GET / HTTP/1.1\r\nContent-Length: 3\r\n\r\nhi"),
    "malformed request: truncated body: expected 3 bytes",
  )
}

///|
async test "a Content-Length that is not a plain integer is refused" {
  // The unparseable length becomes -1, which reads as too large: a body
  // size the server will not guess at.
  assert_eq(
    request_error_of(
      "PUT /cal/a.ics HTTP/1.1\r\nContent-Length: 4x\r\n\r\nabcd",
    ),
    "request body exceeds 10485760 bytes",
  )
}

///|
async test "a multibyte body round-trips through the UTF-8 decode" {
  let body = "SUMMARY:中秋节的月亮\r\n"
  let req = request_of(
    "PUT /a.ics HTTP/1.1\r\nContent-Length: 28\r\n\r\n\{body}",
  ).unwrap()
  assert_eq(req.body, body)
}
