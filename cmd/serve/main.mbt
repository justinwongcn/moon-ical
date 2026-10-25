///|
/// The moon-ical CalDAV server: WebDAV discovery, calendar collections, and
/// one endpoint per vdir event.
///
/// Routes:
///
/// - `GET /cal/` — list the default collection's events
/// - `GET /cal/<name>.ics` — the event bytes, with their `ETag`
/// - `PUT /cal/<name>.ics` — replace (or create) the event; answers with the
///   new `ETag`, 204 for a replace and 201 for a create
/// - `DELETE /cal/<name>.ics` — remove it
/// - `PROPFIND /cal/` — the calendar home; `Depth: 1` adds its events and its
///   nested calendar collections
/// - `REPORT /cal/` — calendar-query / calendar-multiget over the collection
/// - `MKCALENDAR /cal/<cal>/` — create a calendar collection (201), 405 when
///   one is already there
/// - `PROPFIND|REPORT|GET|DELETE /cal/<cal>/` — the same operations on a
///   created collection; its events live at `/cal/<cal>/<name>.ics`
///
/// `/cal/` is both the calendar home and the default collection: the first
/// release already served events straight from it and a stock client is
/// configured against that path, so a created collection nests beside them
/// rather than moving them. Anything else is 404, unknown methods are 405,
/// and a chunked request body gets 411 — the project boundary
/// (docs/development.html §08) rather than a half-implementation.
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
const DRAIN_CAP : Int32 = 10 * 1024 * 1024

///|
/// Whether the connection loop goes on to read the next request.
priv enum Outcome {
  Next
  Stop
}

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
        None => Stop // clean disconnect between requests
        Some(request) => {
          route(conn, store, request)
          Next
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
        Stop
      }
      @httpd.HttpParseError::BodyTooLarge(limit=k) => {
        @httpd.respond(
          conn,
          413,
          "Payload Too Large",
          headers=[("Connection", "close")],
          body="body over \{k} bytes refused",
        )
        Stop
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
        Stop
      }
      _ => {
        // Anything raised below the request layer (store, filesystem)
        // is the server's failure, not the client's malformed request.
        @httpd.respond(conn, 500, "Internal Server Error", headers=[
          ("Connection", "close"),
        ])
        Stop
      }
    }
    if outcome is Stop {
      break
    }
  }
  conn.close()
}

///|
/// Where a request path points. The calendar home and the nested calendar
/// collections share the `/cal/` prefix, so one parse decides which of them a
/// path names and everything below switches on the result.
priv enum Target {
  WellKnown
  Root
  Principal
  /// `/cal/` — the calendar home, which is also the default collection.
  Home
  /// `/cal/<name>/` — a nested calendar collection.
  Collection(name~ : String)
  /// `/cal/<name>.ics`, or `/cal/<cal>/<name>.ics` inside a nested collection.
  Event(collection~ : String?, name~ : String)
  Unknown
}

///|
/// Classify a request path. A trailing slash marks a collection, so
/// `/cal/work/` names a calendar while `/cal/work` names an event in the
/// default collection — the shape the event routes already had.
fn target_of(path : String) -> Target {
  if path == "/.well-known/caldav" {
    return WellKnown
  }
  if path == "/" {
    return Root
  }
  if path == "/principals/default/" {
    return Principal
  }
  if path == "/cal/" || path == "/cal" {
    return Home
  }
  if !path.has_prefix("/cal/") {
    return Unknown
  }
  let rest = path.view()[5:]
  match rest.find("/".view()) {
    None => Event(collection=None, name=rest.to_owned())
    Some(slash) => {
      let name = rest[:slash].to_owned()
      let tail = rest[slash + 1:].to_owned()
      if tail.length() == 0 {
        Collection(name~)
      } else {
        Event(collection=Some(name), name=tail)
      }
    }
  }
}

///|
/// One request to its answer.
async fn route(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
) -> Unit {
  match target_of(request.path) {
    WellKnown =>
      @httpd.respond(conn, 301, "Moved Permanently", headers=[
        ("Location", "/cal/"),
      ])
    Root => discovery_request(conn, request, @caldav.root_propfind())
    Principal => discovery_request(conn, request, @caldav.principal_propfind())
    Home => home_request(conn, store, request)
    Collection(name~) => collection_request(conn, store, request, name)
    Event(collection~, name~) =>
      event_request(conn, store, request, collection, name)
    Unknown => @httpd.respond(conn, 404, "Not Found")
  }
}

///|
/// The two discovery resources answer `PROPFIND` and `OPTIONS` only.
async fn discovery_request(
  conn : @socket.Tcp,
  request : @httpd.HttpRequest,
  body : String,
) -> Unit {
  if request.meth == "PROPFIND" {
    dav_response(conn, body)
  } else if request.meth == "OPTIONS" {
    options_response(conn)
  } else {
    method_not_allowed(conn)
  }
}

///|
/// The calendar home: the default collection. `MKCALENDAR` is refused here
/// because this collection already exists, and RFC 4791 §5.3.1 gives 405 for
/// creating a collection that is already there.
async fn home_request(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
) -> Unit {
  if request.meth == "GET" {
    list_events(conn, store)
  } else if request.meth == "OPTIONS" {
    options_response(conn)
  } else if request.meth == "PROPFIND" {
    propfind_collection(conn, store, request, "/cal/", "moon-ical", true)
  } else if request.meth == "REPORT" {
    report_request(conn, store, request, "/cal/")
  } else if request.meth == "MKCALENDAR" {
    already_exists(conn)
  } else {
    method_not_allowed(conn)
  }
}

///|
/// A nested calendar collection: created on demand by `MKCALENDAR`, then
/// served like the home collection but scoped to its own events.
async fn collection_request(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
  name : String,
) -> Unit {
  let href = "/cal/\{name}/"
  match store.collection(name) {
    None =>
      if request.meth == "MKCALENDAR" {
        if !@store.is_store_name(name) {
          @httpd.respond(conn, 404, "Not Found")
        } else if store.create_collection(name) {
          @httpd.respond(conn, 201, "Created")
        } else {
          already_exists(conn)
        }
      } else {
        @httpd.respond(conn, 404, "Not Found")
      }
    Some(nested) =>
      if request.meth == "GET" {
        list_events(conn, nested)
      } else if request.meth == "OPTIONS" {
        options_response(conn)
      } else if request.meth == "PROPFIND" {
        propfind_collection(conn, nested, request, href, name, false)
      } else if request.meth == "REPORT" {
        report_request(conn, nested, request, href)
      } else if request.meth == "DELETE" {
        if store.remove_collection(name) {
          @httpd.respond(conn, 204, "No Content")
        } else {
          // The collection is there, so a refusal here means it still holds
          // events: a collection is not deleted out from under its contents.
          @httpd.respond(conn, 409, "Conflict", body="collection is not empty")
        }
      } else if request.meth == "MKCALENDAR" {
        already_exists(conn)
      } else {
        method_not_allowed(conn)
      }
  }
}

///|
/// A calendar object resource, in the default collection or in a named one.
async fn event_request(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
  collection : String?,
  name : String,
) -> Unit {
  match store_for(store, collection) {
    None => @httpd.respond(conn, 404, "Not Found")
    Some(target) => event_method(conn, target, request, name)
  }
}

///|
/// The store a collection name refers to, or `None` when that collection does
/// not exist. `None` means the default collection, which always exists.
async fn store_for(
  store : @store.VdirStore,
  collection : String?,
) -> @store.VdirStore? {
  match collection {
    None => Some(store)
    Some(name) => store.collection(name)
  }
}

///|
/// The event methods, unchanged from the single-collection server — the
/// nested store has the same shape, so they work on either.
async fn event_method(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
  name : String,
) -> Unit {
  if !@store.is_store_name(name) {
    // The name is validated before it goes near the filesystem; a name that
    // could never be an event is simply not found.
    @httpd.respond(conn, 404, "Not Found")
  } else if request.meth == "OPTIONS" {
    options_response(conn)
  } else if request.meth == "GET" {
    match store.get(name) {
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
  } else if request.meth == "PUT" {
    let current = store.get(name)
    let current_tag = current.map(file => file.etag)
    if @caldav.check_preconditions(
        current_tag,
        request.header("If-Match"),
        request.header("If-None-Match"),
      )
      is @caldav.Precondition::Failed {
      @httpd.respond(conn, 412, "Precondition Failed")
    } else {
      let etag = store.put(name, request.body)
      let code = if current is Some(_) { 204 } else { 201 }
      let reason = if code == 204 { "No Content" } else { "Created" }
      @httpd.respond(conn, code, reason, headers=[("ETag", "\"\{etag}\"")])
    }
  } else if request.meth == "DELETE" {
    let current = store.get(name)
    let current_tag = current.map(file => file.etag)
    if @caldav.check_preconditions(
        current_tag,
        request.header("If-Match"),
        None,
      )
      is @caldav.Precondition::Failed {
      @httpd.respond(conn, 412, "Precondition Failed")
    } else if store.delete(name) {
      @httpd.respond(conn, 204, "No Content")
    } else {
      @httpd.respond(conn, 404, "Not Found")
    }
  } else {
    method_not_allowed(conn)
  }
}

///|
/// A collection's events, one per line. Kept from the single-collection
/// server as a plain-text convenience listing.
async fn list_events(conn : @socket.Tcp, store : @store.VdirStore) -> Unit {
  @httpd.respond(
    conn,
    200,
    "OK",
    headers=[("Content-Type", "text/plain; charset=utf-8")],
    body=store.list().join("\n") + "\n",
  )
}

///|
/// `PROPFIND` on a collection. `Depth: 1` adds its nested calendar
/// collections and its events; anything else is treated as depth 0.
async fn propfind_collection(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
  href : String,
  displayname : String,
  include_children : Bool,
) -> Unit {
  let depth = if request.header("Depth") == Some("1") { 1 } else { 0 }
  let children : Array[(String, String)] = []
  if include_children && depth == 1 {
    for name in store.collections() {
      children.push(("/cal/\{name}/", name))
    }
  }
  dav_response(
    conn,
    @caldav.collection_propfind(
      load_resources(store, href),
      depth,
      href~,
      displayname~,
      children~,
    ),
  )
}

///|
/// `REPORT` on a collection, with the `DAV:error` body a failed filter
/// precondition calls for.
async fn report_request(
  conn : @socket.Tcp,
  store : @store.VdirStore,
  request : @httpd.HttpRequest,
  href : String,
) -> Unit {
  match @caldav.report(request.body, load_resources(store, href)) {
    @caldav.ReportOutcome::Report(body~) => dav_response(conn, body)
    @caldav.ReportOutcome::UnsupportedReport =>
      @httpd.respond(conn, 400, "Bad Request", body="unsupported REPORT")
    @caldav.ReportOutcome::PreconditionFailed(body~) =>
      @httpd.respond(
        conn,
        403,
        "Forbidden",
        headers=[("Content-Type", "application/xml; charset=utf-8")],
        body~,
      )
  }
}

///|
async fn method_not_allowed(conn : @socket.Tcp) -> Unit {
  @httpd.respond(conn, 405, "Method Not Allowed", headers=[
    ("Allow", "OPTIONS, GET, PUT, DELETE, PROPFIND, REPORT, MKCALENDAR"),
  ])
}

///|
/// `MKCALENDAR` on a collection that already exists.
async fn already_exists(conn : @socket.Tcp) -> Unit {
  @httpd.respond(conn, 405, "Method Not Allowed", headers=[
    ("Allow", "OPTIONS, GET, PROPFIND, REPORT, DELETE"),
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
/// Every event in a collection, with the hrefs built from the collection's
/// own path so a report answers with URLs the client can follow.
async fn load_resources(
  store : @store.VdirStore,
  href : String,
) -> Array[@caldav.DavResource] {
  let resources : Array[@caldav.DavResource] = []
  for name in store.list() {
    match store.get(name) {
      Some(file) =>
        resources.push({
          href: "\{href}\{name}",
          etag: file.etag,
          calendar_data: file.text,
        })
      None => ()
    }
  }
  resources
}
