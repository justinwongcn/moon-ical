///|
/// The moon-ical CalDAV server: WebDAV discovery plus one endpoint per vdir event.
///
/// Routes (all under `/cal/`):
///
/// - `OPTIONS /cal/<name>.ics` — what this server can do
/// - `GET /cal/<name>.ics` — the event bytes, with their `ETag`
/// - `PUT /cal/<name>.ics` — replace (or create) the event; answers
///   with the new `ETag`, 200 for a replace and 201 for a create
/// - `DELETE /cal/<name>.ics` — remove it
///
/// `GET /cal/` lists the collection. Anything else is 404, unknown
/// methods are 405, and a chunked request body gets 411 — the project
/// boundary (docs/development.html §08) rather than a half-implementation.
///
/// The server listens through `@socket.TcpServer`, not `@http.Server`:
/// upstream's `ServerConnection` reader is body-framed by an
/// already-parsed request, so raw request parsing wants the socket
/// stream itself (and it keeps WebDAV method tokens readable for S6 —
/// seam S6 in docs/upstream-seams.md).
///
/// The filesystem only runs natively (seam S1), so this binary is
/// native-only:
///
/// ```bash
/// moon run cmd/serve --target native -- ./caldata 8437
/// ```
async fn main {
  let args = @env.args()
  let root = if args.length() > 1 { args[1] } else { "./caldata" }
  let port = if args.length() > 2 { args[2] } else { "8437" }
  let store = @store.VdirStore::new(root)
  let server = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  let bound = server.addr.port()
  println("moon-ical serve: \{root} on http://127.0.0.1:\{bound}/cal/")
  server.run_forever((conn, _) => handle_connection(conn, store))
}

///|
/// Read and discard up to [`DRAIN_CAP`] bytes, stopping at EOF — used
/// after refusing a body so the close does not destroy the response
/// with an RST while the client is still sending.
async fn drain(conn : @socket.Tcp) -> Unit {
  let mut total = 0
  while total < DRAIN_CAP {
    match conn.read_some(max_len=4096) {
      None => break
      Some(bytes) => total = total + bytes.length()
    }
  }
}

///|
const DRAIN_CAP : Int = 10 * 1024 * 1024

///|
/// Keep-alive: answer every request on this connection until the peer
/// hangs up (a clean EOF between requests), sends something malformed,
/// or a request fails to parse.
async fn handle_connection(
  conn : @socket.Tcp,
  store : @store.VdirStore,
) -> Unit {
  for ;; {
    // Everything that can refuse a request — reading it and routing
    // it — sits inside one try, so every refusal gets its proper
    // response instead of escaping as a failed connection.
    let outcome = try {
      match @httpd.read_request(conn) {
        None => "closed" // clean disconnect between requests
        Some(request) => {
          route(conn, store, request)
          "ok"
        }
      }
    } catch {
      @httpd.HttpParseError::ChunkedBody => {
        @httpd.respond(conn, 411, "Length Required", headers=[
          ("Connection", "close"),
        ])
        // The client may still be mid-upload of the chunked body.
        // Draining it lets the response actually reach the client
        // before the close, instead of an RST discarding it.
        drain(conn)
        "close"
      }
      @httpd.HttpParseError::BodyTooLarge(limit=k) => {
        @httpd.respond(
          conn,
          413,
          "Payload Too Large",
          headers=[("Connection", "close")],
          body="body over \{k} bytes refused",
        )
        "close"
      }
      @httpd.HttpParseError::Malformed(message=m) => {
        // A malformed request stream cannot be trusted to
        // resynchronise; answer 400 and drop the connection.
        @httpd.respond(
          conn,
          400,
          "Bad Request",
          headers=[("Connection", "close")],
          body="malformed request: \{m}",
        )
        "close"
      }
      _ => {
        // Anything raised below the request layer (store, filesystem)
        // is the server's failure, not the client's malformed request.
        @httpd.respond(conn, 500, "Internal Server Error", headers=[
          ("Connection", "close"),
        ])
        "close"
      }
    }
    if outcome != "ok" {
      break
    }
  }
  conn.close()
}

///|
/// One request to its answer.
async fn route(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
) -> Unit {
  let path = request.path
  if path == "/.well-known/caldav" {
    @httpd.respond(conn, 301, "Moved Permanently", headers=[
      ("Location", "/cal/"),
    ])
    return
  }
  if path == "/" || path == "/principals/default/" {
    if request.meth == "PROPFIND" {
      let body = if path == "/" {
        @caldav.root_propfind()
      } else {
        @caldav.principal_propfind()
      }
      dav_response(conn, body)
    } else if request.meth == "OPTIONS" {
      options_response(conn)
    } else {
      method_not_allowed(conn)
    }
    return
  }
  if path == "/cal/" || path == "/cal" {
    if request.meth == "GET" {
      let names = store.list()
      @httpd.respond(
        conn,
        200,
        "OK",
        headers=[("Content-Type", "text/plain; charset=utf-8")],
        body=names.join("\n") + "\n",
      )
    } else if request.meth == "OPTIONS" {
      options_response(conn)
    } else if request.meth == "PROPFIND" {
      let depth = if request.header("Depth") == Some("1") { 1 } else { 0 }
      dav_response(
        conn,
        @caldav.collection_propfind(load_resources(store), depth),
      )
    } else if request.meth == "REPORT" {
      match @caldav.report(request.body, load_resources(store)) {
        Some(body) => dav_response(conn, body)
        None =>
          @httpd.respond(conn, 400, "Bad Request", body="unsupported REPORT")
      }
    } else if request.meth == "MKCALENDAR" {
      @httpd.respond(conn, 201, "Created")
    } else {
      method_not_allowed(conn)
    }
    return
  }
  let name = event_name(path)
  match (request.meth, name) {
    ("OPTIONS", Some(_)) => options_response(conn)
    ("GET", Some(n)) =>
      match store.get(n) {
        Some(file) =>
          @httpd.respond(
            conn,
            200,
            "OK",
            headers=[
              ("Content-Type", "text/calendar; charset=utf-8"),
              ("ETag", "\"\{file.etag}\""),
            ],
            body=file.text,
          )
        None => @httpd.respond(conn, 404, "Not Found")
      }
    ("PUT", Some(n)) => {
      let current = store.get(n)
      let current_tag = match current {
        Some(file) => Some(file.etag)
        None => None
      }
      if @caldav.check_preconditions(
          current_tag,
          request.header("If-Match"),
          request.header("If-None-Match"),
        )
        is @caldav.Precondition::Failed {
        @httpd.respond(conn, 412, "Precondition Failed")
      } else {
        let etag = store.put(n, request.body)
        let code = if current is Some(_) { 204 } else { 201 }
        let reason = if code == 204 { "No Content" } else { "Created" }
        @httpd.respond(conn, code, reason, headers=[("ETag", "\"\{etag}\"")])
      }
    }
    ("DELETE", Some(n)) => {
      let current = store.get(n)
      let current_tag = match current {
        Some(file) => Some(file.etag)
        None => None
      }
      if @caldav.check_preconditions(
          current_tag,
          request.header("If-Match"),
          None,
        )
        is @caldav.Precondition::Failed {
        @httpd.respond(conn, 412, "Precondition Failed")
      } else if store.delete(n) {
        @httpd.respond(conn, 204, "No Content")
      } else {
        @httpd.respond(conn, 404, "Not Found")
      }
    }
    (_, Some(_)) => method_not_allowed(conn)
    (_, None) => @httpd.respond(conn, 404, "Not Found")
  }
}

///|
/// `/cal/<name>` → `Some(name)`; any other shape is `None`. The name is
/// store-validated before it ever reaches the filesystem, so this only
/// decides whether the path *looks* like an event route.
fn event_name(path : String) -> String? {
  let prefix = "/cal/"
  let chars = path.to_array()
  let plen = prefix.length()
  if chars.length() > plen && String::from_array(chars[0:plen]) == prefix {
    Some(String::from_array(chars[plen:]))
  } else {
    None
  }
}

///|
async fn method_not_allowed(conn : @socket.Tcp) -> Unit {
  @httpd.respond(conn, 405, "Method Not Allowed", headers=[
    ("Allow", "OPTIONS, GET, PUT, DELETE, PROPFIND, REPORT, MKCALENDAR"),
  ])
}

///|
async fn options_response(conn : @socket.Tcp) -> Unit {
  @httpd.respond(conn, 200, "OK", headers=[
    ("Allow", "OPTIONS, GET, PUT, DELETE, PROPFIND, REPORT, MKCALENDAR"),
    ("DAV", "1, 3, calendar-access"),
  ])
}

///|
async fn dav_response(conn : @socket.Tcp, body : String) -> Unit {
  @httpd.respond(
    conn,
    207,
    "Multi-Status",
    headers=[("Content-Type", "application/xml; charset=utf-8")],
    body~,
  )
}

///|
async fn load_resources(store : @store.VdirStore) -> Array[@caldav.DavResource] {
  let resources : Array[@caldav.DavResource] = []
  for name in store.list() {
    match store.get(name) {
      Some(file) =>
        resources.push({
          href: "/cal/\{name}",
          etag: file.etag,
          calendar_data: file.text,
        })
      None => ()
    }
  }
  resources
}
