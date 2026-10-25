///|
/// A request-body cap, so a rogue client cannot make the server buffer
/// an unbounded body in memory. vdir calendars are kilobytes; ten
/// megabytes is already generous by an order of magnitude.
const MAX_BODY : Int32 = 10 * 1024 * 1024

///|
/// Caps on one physical line of the request head (request line or header
/// line) and on how many header lines one request may carry — the
/// read-side twin of [`MAX_BODY`]. Without them a client that never
/// sends its newline buffers memory without bound, line by line.
const MAX_LINE_BYTES : Int32 = 64 * 1024

///|
const MAX_HEADERS : Int32 = 100

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
pub extend HttpRequest with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend HttpRequest with Eq::{not_equal, equal}

///|
/// One header of an [`HttpRequest`], with the name lower-cased.
pub(all) struct HttpHeader {
  name : String
  value : String
} derive(Debug, Eq)

///|
pub extend HttpHeader with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend HttpHeader with Eq::{not_equal, equal}

///|
/// Why a request could not be read. The server maps each shape to a
/// status: `Malformed` → 400, `ChunkedBody` → 411 (the project boundary
/// rejects chunked request bodies rather than half-implementing them),
/// `BodyTooLarge` → 413.
pub(all) suberror HttpParseError {
  Malformed(message~ : String)
  ChunkedBody
  BodyTooLarge(limit~ : Int32)
} derive(Debug, Eq)

///|
pub extend HttpParseError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend HttpParseError with Eq::{not_equal, equal}

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
pub extend HttpParseError with Show::{to_string, output}

///|
/// The first header value with this name, if any. Names match
/// case-insensitively (they are stored lower-cased, and the lookup key
/// is folded the same way).
pub fn HttpRequest::header(self : HttpRequest, name : String) -> String? {
  let want = String::to_lower(name)
  for h in self.headers {
    if h.name == want {
      return Some(h.value)
    }
  }
  None
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
  let input : LineInput[R] = { reader, buf: [], }
  // Leading blank lines before a request line are tolerated (RFC 7230
  // §3.5); a clean EOF anywhere in this loop is a disconnect.
  let mut first = input.read_line()
  while first is Some("") {
    first = input.read_line()
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
    match input.read_line() {
      None => raise HttpParseError::Malformed(message="EOF in headers")
      Some("") => blank = true
      Some(h) =>
        match parse_header(h) {
          Some(parsed) => {
            if headers.length() >= MAX_HEADERS {
              raise HttpParseError::Malformed(
                message="too many header lines (over \{MAX_HEADERS})",
              )
            }
            headers.push(parsed)
          }
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
  Some(read_body(input, request))
}

///|
/// A byte-level line reader over any reader, holding the bytes that
/// arrived past the last newline. `@io.Reader::read_until` buffers a
/// never-ending line without bound, which is exactly the memory hole
/// [`MAX_LINE_BYTES`] exists to close, so the request head is read
/// through this owned buffer instead.
priv struct LineInput[R] {
  reader : R
  mut buf : Array[Byte]
}

///|
/// Read one line: up to the next LF, with a trailing CR stripped, so
/// both CRLF and bare LF terminators parse. `None` on a clean EOF before
/// any byte — a keep-alive disconnect; a partial line at EOF is handed
/// up for the caller's parse to judge. Raises [`HttpParseError`] when
/// the line would pass [`MAX_LINE_BYTES`] or is not UTF-8.
async fn[R : @io.Reader] LineInput::read_line(self : LineInput[R]) -> String? {
  for ;; {
    let mut newline : Int32? = None
    let buf = self.buf
    for i in 0..<buf.length() {
      if buf[i].to_int() == '\n'.to_int() {
        newline = Some(i)
        break
      }
    }
    match newline {
      Some(lf) => {
        let line_bytes : Array[Byte] = []
        for i in 0..<lf {
          line_bytes.push(buf[i])
        }
        let rest : Array[Byte] = []
        for i in (lf + 1)..<buf.length() {
          rest.push(buf[i])
        }
        self.buf = rest
        return Some(finish_line(line_bytes))
      }
      None =>
        if self.buf.length() > MAX_LINE_BYTES {
          raise HttpParseError::Malformed(
            message="line too long (over \{MAX_LINE_BYTES} bytes)",
          )
        } else {
          match self.reader.read_some(max_len=4096) {
            None =>
              if self.buf.length() == 0 {
                return None
              } else {
                let line_bytes = self.buf
                self.buf = []
                return Some(finish_line(line_bytes))
              }
            Some(chunk) =>
              for i in 0..<chunk.length() {
                self.buf.push(chunk[i])
              }
          }
        }
    }
  }
}

///|
/// Decode one line's bytes as UTF-8 and strip a trailing CR.
fn finish_line(bytes : Array[Byte]) -> String raise {
  let text = @utf8.decode(Bytes::from_array(bytes.exact_view())) catch {
    _ => raise HttpParseError::Malformed(message="line is not valid UTF-8")
  }
  let v = text.view()
  let n = v.length()
  if n > 0 && v[n - 1] == '\r' {
    v[:n - 1].to_owned()
  } else {
    text
  }
}

///|
/// Split on runs of spaces, dropping empties — tolerant of the sloppy
/// spacing real clients occasionally send.
fn split_spaces(line : String) -> Array[String] {
  let parts : Array[String] = []
  let v = line.view()
  let n = v.length()
  let mut start = -1
  for i in 0..<n {
    if v[i] == ' ' {
      if start >= 0 {
        parts.push(v[start:i].to_owned())
        start = -1
      }
    } else if start < 0 {
      start = i
    }
  }
  if start >= 0 {
    parts.push(v[start:].to_owned())
  }
  parts
}

///|
/// `Name: value` → [`HttpHeader`] with a lower-cased name; `None` when
/// there is no colon or the name is empty.
fn parse_header(line : String) -> HttpHeader? {
  let v = line.view()
  let n = v.length()
  let mut colon = -1
  for i in 0..<n {
    if v[i] == ':' {
      colon = i
      break
    }
  }
  if colon <= 0 {
    return None
  }
  let name = v[:colon].to_lower().to_owned()
  // Skip the optional whitespace RFC 7230 allows after the colon.
  let mut first = colon + 1
  while first < n && (v[first] == ' ' || v[first] == '\t') {
    first = first + 1
  }
  Some({ name, value: v[first:].to_owned(), })
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
  input : LineInput[R],
  request : HttpRequest,
) -> HttpRequest {
  match request.header("Content-Length") {
    None => request
    Some(text) => {
      // A length that is not a plain integer is a malformed header
      // (RFC 7230 §3.3.2, 400); a well-formed but huge one is a size
      // refusal (413). Before S22 the parser capped digits at nine to
      // fit Int32, so a ten-digit length fell into the 400 bucket.
      let length = match parse_int(text) {
        None =>
          raise HttpParseError::Malformed(
            message="Content-Length is not a plain integer: \{text}",
          )
        Some(len) => len
      }
      if length > MAX_BODY.to_int64() {
        raise HttpParseError::BodyTooLarge(limit=MAX_BODY)
      }
      let length = Int64::to_int(length)
      // The body's first bytes may already sit in the line reader's
      // buffer, having arrived in the same chunk as the head; drain
      // those before asking the reader for the rest.
      let (head, taken) = input.take_bytes(length)
      let bytes = if taken < length {
        let tail = input.reader.read_exactly(length - taken) catch {
          _ =>
            raise HttpParseError::Malformed(
              message="truncated body: expected \{length} bytes",
            )
        }
        head.add(tail)
      } else {
        head
      }
      let body = @utf8.decode(bytes) catch {
        _ => raise HttpParseError::Malformed(message="body is not valid UTF-8")
      }
      { ..request, body, }
    }
  }
}

///|
/// Take up to `want` bytes the line reader has already buffered — the
/// front of its buffer is exactly the next byte the connection owes —
/// returning them with how many were taken. A pipelined request's first
/// bytes stay behind in the buffer.
fn[R] LineInput::take_bytes(
  self : LineInput[R],
  want : Int32,
) -> (Bytes, Int32) {
  let take = if self.buf.length() > want { want } else { self.buf.length() }
  let head : Array[Byte] = []
  let rest : Array[Byte] = []
  for i in 0..<self.buf.length() {
    if i < take {
      head.push(self.buf[i])
    } else {
      rest.push(self.buf[i])
    }
  }
  self.buf = rest
  (Bytes::from_array(head.exact_view()), take)
}

///|
/// Decimal digits only; anything else is refused rather than guessed.
/// The accumulator saturates near the Int64 ceiling so a well-formed but
/// absurd length stays "a number, a huge one" (the 413 bucket) instead
/// of wrapping or being rejected as malformed.
fn parse_int(text : String) -> Int64? {
  let v = text.view()
  let n = v.length()
  if n == 0 {
    return None
  }
  let mut acc : Int64 = 0
  for i in 0..<n {
    let c = v[i]
    if !(c is ('0'..<='9')) {
      return None
    }
    if acc > 922_337_203_685_477_580 {
      return Some(9_223_372_036_854_775_807)
    }
    acc = acc * 10 + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(acc)
}

///|
/// Send a full HTTP/1.1 response over `writer`: status line, the given
/// headers, `Content-Length` (in UTF-8 *bytes* — a body's character
/// count would under-report multibyte text and hang the client), the
/// blank line, then the body. One write, so a response is never
/// interleaved with another's.
pub async fn[W : @io.Writer] respond(
  writer : W,
  code : Int32,
  reason : String,
  headers~ : Array[(String, String)] = [],
  body~ : String = "",
) -> Unit {
  let out = StringBuilder()
  out.write_string("HTTP/1.1 \{code} \{reason}\r\n")
  for pair in headers {
    let (name, value) = pair
    out.write_string("\{name}: \{value}\r\n")
  }
  out.write_string("Content-Length: \{utf8_byte_len(body)}")
  out.write_string("\r\n\r\n")
  out.write_string(body)
  writer.write(out.to_string())
}

///|
/// The UTF-8 byte length of a string — the unit HTTP lengths count in.
fn utf8_byte_len(text : String) -> Int32 {
  let mut total = 0
  for c in text {
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
