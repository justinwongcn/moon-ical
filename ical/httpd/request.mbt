///|
/// A request-body cap, so a rogue client cannot make the server buffer
/// an unbounded body in memory. vdir calendars are kilobytes; ten
/// megabytes is already generous by an order of magnitude.
const MAX_BODY : Int = 10 * 1024 * 1024

///|
/// One hand-parsed HTTP/1.1 request (RFC 7230 §3, the subset CalDAV
/// needs).
///
/// Why hand-parsed: upstream `ServerConnection::read_request` returns a
/// `RequestMethod` closed enum with the nine standard methods, and
/// WebDAV's `PROPFIND` / `REPORT` / `MKCALENDAR` do not fit (seam S6 in
/// docs/upstream-seams.md). A method is just a token in the request
/// line, so this layer keeps it as a `String` — every method a client
/// can spell can be read. When upstream opens the enum, the switch
/// recipe in the seam register swaps this back.
pub(all) struct HttpRequest {
  /// The method token exactly as sent (`GET`, `PUT`, `PROPFIND`, ...).
  /// Method tokens are case-sensitive by RFC 7230; nothing here folds
  /// their case.
  meth : String
  /// The request target exactly as sent, query string included.
  path : String
  /// The protocol token from the request line (`HTTP/1.1`).
  version : String
  /// Headers in arrival order. Names are lower-cased, values trimmed of
  /// the optional leading whitespace; repeats are kept — `Cookie`-style
  /// headers legitimately repeat.
  headers : Array[HttpHeader]
  /// The request body, decoded as UTF-8; empty when there is none.
  body : String
} derive(Debug, Eq)

///|
/// One header of an [`HttpRequest`], with the name lower-cased.
pub(all) struct HttpHeader {
  name : String
  value : String
} derive(Debug, Eq)

///|
/// Why a request could not be read. The server maps each shape to a
/// status: `Malformed` → 400, `ChunkedBody` → 411 (the project boundary
/// rejects chunked request bodies rather than half-implementing them),
/// `BodyTooLarge` → 413.
pub(all) suberror HttpParseError {
  Malformed(message~ : String)
  ChunkedBody
  BodyTooLarge(limit~ : Int)
} derive(Debug, Eq)

///|
pub impl Show for HttpParseError with fn output(self, logger) {
  match self {
    Malformed(message=m) => logger.write_string("malformed request: \{m}")
    ChunkedBody =>
      logger.write_string("chunked request bodies are not supported")
    BodyTooLarge(limit=k) =>
      logger.write_string("request body exceeds \{k} bytes")
  }
}

///|
/// The first header value with this name, if any. Names match
/// case-insensitively (they are stored lower-cased, and the lookup key
/// is folded the same way).
pub fn HttpRequest::header(self : HttpRequest, name : String) -> String? {
  let want = String::to_lower(name)
  let mut found : String? = None
  for h in self.headers {
    if h.name == want && found is None {
      found = Some(h.value)
    }
  }
  found
}

///|
/// Read one HTTP/1.1 request from `reader`: request line, headers, then
/// a `Content-Length`-sized body. Lines tolerate both CRLF and bare LF
/// endings. Returns `None` when the peer hangs up cleanly before any
/// request bytes arrive — a normal keep-alive disconnect, not an error.
/// Raises [`HttpParseError`] for anything this layer refuses: a
/// `Transfer-Encoding: chunked` body (`ChunkedBody`), a body over
/// [`MAX_BODY`] (`BodyTooLarge`), or a request line / header that does
/// not parse (`Malformed`).
///
/// This reads the *raw* byte stream (a `@socket.Tcp`, say): upstream's
/// `ServerConnection` reader is body-framed by an already-parsed
/// request, not a raw one, so raw parsing wants the socket itself —
/// which is also what keeps every WebDAV method token readable (seam
/// S6 in docs/upstream-seams.md).
///
/// # Example
/// ```mbt nocheck
/// async fn test_example() {
///   let r = @io.MemoryReader() <| w => { w.write("GET /a.ics HTTP/1.1\r\n\r\n") }
///   let req = @httpd.read_request(r).unwrap()
///   assert_eq(req.meth, "GET")
/// }
/// ```
pub async fn[R : @io.Reader] read_request(reader : R) -> HttpRequest? {
  // Leading blank lines before a request line are tolerated (RFC 7230
  // §3.5); a clean EOF anywhere in this loop is a disconnect.
  let mut first = read_line(reader)
  while first is Some("") {
    first = read_line(reader)
  }
  let request_line = match first {
    Some(line) => line
    None => return None
  }
  let parts = split_spaces(request_line)
  if parts.length() != 3 || parts[2].length() < 5 || parts[2][0:5] != "HTTP/" {
    raise HttpParseError::Malformed(message="bad request line: \{request_line}")
  }
  let headers : Array[HttpHeader] = []
  let mut blank = false
  while !blank {
    match read_line(reader) {
      None => raise HttpParseError::Malformed(message="EOF in headers")
      Some("") => blank = true
      Some(h) =>
        match parse_header(h) {
          Some(parsed) => headers.push(parsed)
          None => raise HttpParseError::Malformed(message="bad header: \{h}")
        }
    }
  }
  let request : HttpRequest = {
    meth: parts[0],
    path: parts[1],
    version: parts[2],
    headers,
    body: "",
  }
  if is_chunked(request) {
    raise HttpParseError::ChunkedBody
  }
  Some(read_body(reader, request))
}

///|
/// Read one line: up to the next LF, with a trailing CR stripped, so
/// both CRLF and bare LF terminators parse. `None` is a clean EOF.
async fn[R : @io.Reader] read_line(reader : R) -> String? {
  match reader.read_until("\n") {
    Some(line) => {
      let chars = line.to_array()
      let n = chars.length()
      if n > 0 && chars[n - 1] == '\r' {
        Some(String::from_array(chars[0:n - 1]))
      } else {
        Some(line)
      }
    }
    None => None
  }
}

///|
/// Split on runs of spaces, dropping empties — tolerant of the sloppy
/// spacing real clients occasionally send.
fn split_spaces(line : String) -> Array[String] {
  let parts : Array[String] = []
  let chars = line.to_array()
  let n = chars.length()
  let mut start = -1
  let mut i = 0
  while i <= n {
    let at_end = i == n
    let is_space = !at_end && chars[i] == ' '
    if is_space {
      if start >= 0 {
        parts.push(String::from_array(chars[start:i]))
        start = -1
      }
    } else if start < 0 && !at_end {
      start = i
    }
    i = i + 1
  }
  if start >= 0 {
    parts.push(String::from_array(chars[start:n]))
  }
  parts
}

///|
/// `Name: value` → [`HttpHeader`] with a lower-cased name; `None` when
/// there is no colon or the name is empty.
fn parse_header(line : String) -> HttpHeader? {
  let chars = line.to_array()
  let n = chars.length()
  let mut colon = -1
  let mut i = 0
  while i < n && colon < 0 {
    if chars[i] == ':' {
      colon = i
    }
    i = i + 1
  }
  if colon <= 0 {
    None
  } else {
    let name = String::to_lower(String::from_array(chars[0:colon]))
    // Skip the optional whitespace RFC 7230 allows after the colon.
    let mut first = colon + 1
    while first < n && (chars[first] == ' ' || chars[first] == '\t') {
      first = first + 1
    }
    Some({ name, value: String::from_array(chars[first:n]), })
  }
}

///|
/// Whether the request declares a chunked body. Any
/// `Transfer-Encoding` header at all is treated as chunked: the only
/// encoding HTTP/1.1 defines there is chunked, and CalDAV clients
/// chunking a PUT is the exact case the project boundary rejects.
fn is_chunked(request : HttpRequest) -> Bool {
  match request.header("Transfer-Encoding") {
    Some(_) => true
    None => false
  }
}

///|
/// Read the body the headers describe: `Content-Length` bytes, decoded
/// as UTF-8. Without a length there is no body — an HTTP/1.1 request
/// body must be delimited by one of the two mechanisms this layer
/// handles, and chunked was already refused.
async fn[R : @io.Reader] read_body(
  reader : R,
  request : HttpRequest,
) -> HttpRequest {
  match request.header("Content-Length") {
    None => request
    Some(text) => {
      let length = parse_int(text)
      if length < 0 || length > MAX_BODY {
        raise HttpParseError::BodyTooLarge(limit=MAX_BODY)
      }
      let bytes = reader.read_exactly(length) catch {
        _ =>
          raise HttpParseError::Malformed(
            message="truncated body: expected \{length} bytes",
          )
      }
      let body = @utf8.decode(bytes) catch {
        _ => raise HttpParseError::Malformed(message="body is not valid UTF-8")
      }
      { ..request, body, }
    }
  }
}

///|
/// Decimal digits only; anything else is refused rather than guessed.
fn parse_int(text : String) -> Int {
  let chars = text.to_array()
  let n = chars.length()
  if n == 0 || n > 9 {
    -1
  } else {
    let mut acc = 0
    let mut ok = true
    let mut i = 0
    while i < n && ok {
      let d = chars[i].to_int() - '0'.to_int()
      if d < 0 || d > 9 {
        ok = false
      } else {
        acc = acc * 10 + d
        i = i + 1
      }
    }
    if ok {
      acc
    } else {
      -1
    }
  }
}

///|
/// Send a full HTTP/1.1 response over `writer`: status line, the given
/// headers, `Content-Length` (in UTF-8 *bytes* — a body's character
/// count would under-report multibyte text and hang the client), the
/// blank line, then the body. One write, so a response is never
/// interleaved with another's.
pub async fn[W : @io.Writer] respond(
  writer : W,
  code : Int,
  reason : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> Unit {
  let mut text = "HTTP/1.1 \{code} \{reason}\r\n"
  for pair in headers {
    let (name, value) = pair
    text = text + "\{name}: \{value}\r\n"
  }
  text = text + "Content-Length: \{utf8_byte_len(body)}"
  text = text + "\r\n\r\n"
  text = text + body
  writer.write(text)
}

///|
/// The UTF-8 byte length of a string — the unit HTTP lengths count in.
fn utf8_byte_len(text : String) -> Int {
  let mut total = 0
  for c in text.to_array() {
    let code = c.to_int()
    if code < 0x80 {
      total = total + 1
    } else if code < 0x800 {
      total = total + 2
    } else if code < 0x10000 {
      total = total + 3
    } else {
      total = total + 4
    }
  }
  total
}
