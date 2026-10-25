///|
/// One calendar object exposed by a collection response.
pub(all) struct DavResource {
  href : String
  etag : String
  calendar_data : String
} derive(Debug, Eq)

///|
pub extend DavResource with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend DavResource with Eq::{not_equal, equal}

///|
/// The result of evaluating HTTP entity-tag preconditions.
pub(all) enum Precondition {
  Pass
  Failed
} derive(Debug, Eq)

///|
pub extend Precondition with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Precondition with Eq::{not_equal, equal}

///|
/// Evaluate `If-Match` and `If-None-Match` against the current entity tag.
/// Header values may be `*`, a quoted tag, or a comma-separated tag list.
pub fn check_preconditions(
  current : String?,
  if_match : String?,
  if_none_match : String?,
) -> Precondition {
  match if_match {
    Some(value) =>
      if value == "*" {
        if current is None {
          return Failed
        }
      } else if !tag_list_contains(value, current) {
        return Failed
      }
    None => ()
  }
  match if_none_match {
    Some(value) =>
      if value == "*" {
        if current is Some(_) {
          Failed
        } else {
          Pass
        }
      } else if tag_list_contains(value, current) {
        Failed
      } else {
        Pass
      }
    None => Pass
  }
}

///|
fn tag_list_contains(value : String, current : String?) -> Bool {
  match current {
    None => false
    Some(tag) => {
      let quoted = "\"\{tag}\""
      let weak = "W/\{quoted}"
      for part in value.view().split(",".view()) {
        let item = part.trim(chars=" \t".view())
        if item.equal_to_string(quoted) ||
          item.equal_to_string(weak) ||
          item.equal_to_string(tag) {
          return true
        }
      }
      false
    }
  }
}

///|
/// A DAV multistatus body for the server root, exposing the current-user
/// principal used by Thunderbird, DAVx5, and Apple Calendar discovery.
pub fn root_propfind() -> String {
  multistatus([
    response(
      "/",
      "<D:resourcetype><D:collection/></D:resourcetype>" +
      "<D:current-user-principal><D:href>/principals/default/</D:href></D:current-user-principal>",
    ),
  ])
}

///|
/// A DAV multistatus body for the single built-in principal.
pub fn principal_propfind() -> String {
  multistatus([
    response(
      "/principals/default/",
      "<D:resourcetype><D:principal/></D:resourcetype>" +
      "<C:calendar-home-set><D:href>/cal/</D:href></C:calendar-home-set>" +
      "<D:displayname>moon-ical</D:displayname>",
    ),
  ])
}

///|
/// A DAV multistatus body for one calendar collection. Depth 0 returns only
/// the collection itself; depth 1 additionally returns every nested calendar
/// collection and every calendar object with its ETag.
///
/// `href` and `displayname` describe the collection being asked about, so the
/// same builder answers for the calendar home and for a collection created by
/// `MKCALENDAR` (RFC 4791 §5.3.1).
pub fn collection_propfind(
  resources : Array[DavResource],
  depth : Int32,
  href~ : String = "/cal/",
  displayname~ : String = "moon-ical",
  children~ : Array[(String, String)] = [],
) -> String {
  let entries : Array[String] = [collection_response(href, displayname)]
  if depth == 1 {
    for child in children {
      let (child_href, child_name) = child
      entries.push(collection_response(child_href, child_name))
    }
    for item in resources {
      entries.push(resource_response(item, false))
    }
  }
  multistatus(entries)
}

///|
/// The `DAV:response` for one calendar collection.
fn collection_response(href : String, displayname : String) -> String {
  let name = if displayname.length() > 0 {
    "<D:displayname>\{xml_escape(displayname)}</D:displayname>"
  } else {
    ""
  }
  response(
    href,
    "<D:resourcetype><D:collection/><C:calendar/></D:resourcetype>" +
    name +
    "<C:supported-calendar-component-set><C:comp name=\"VEVENT\"/></C:supported-calendar-component-set>" +
    "<D:current-user-principal><D:href>/principals/default/</D:href></D:current-user-principal>",
  )
}

///|
/// What a `REPORT` request body produced.
///
/// The cases stay separate rather than folding into an optional body because
/// the failures answer differently on the wire: an unknown report is `400`,
/// while the two filter preconditions of RFC 4791 §7.8 are `403` with a
/// `DAV:error` body naming the test that failed.
pub(all) enum ReportOutcome {
  /// A `DAV:multistatus` body listing the resources the report selected.
  Report(body~ : String)
  /// The body is a `REPORT` this server does not implement.
  UnsupportedReport
  /// A precondition failed; `body` is the `DAV:error` document to send.
  PreconditionFailed(body~ : String)
} derive(Debug, Eq)

///|
pub extend ReportOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ReportOutcome with Eq::{not_equal, equal}

///|
/// Build a `calendar-query` or `calendar-multiget` response.
///
/// A multiget body selects the requested `href` values. A calendar-query
/// body is evaluated against each resource's calendar data and only the
/// matching resources are returned — RFC 4791 §7.8 makes the filter the
/// whole point of the report, so a body without one, or one this server
/// cannot evaluate, is answered with the matching precondition failure
/// instead of an unfiltered listing.

///|
/// Which REPORT a request body names. The root element's local name,
/// read by the same XML shape parser the filter uses — not a substring
/// scan of the whole body, which let a `text-match` needle or href that
/// mentioned the other report's name misroute the request.
priv enum ReportKind {
  Multiget
  Query
  Other
}

///|
fn report_kind(body : String) -> ReportKind {
  match parse_xml_element(body) {
    Some(root) =>
      match root.name {
        "calendar-multiget" => Multiget
        "calendar-query" => Query
        _ => Other
      }
    // Element names are lowercased while scanning; a body that is not an
    // XML element at all names no report this server implements.
    None => Other
  }
}

///|
pub fn report(body : String, resources : Array[DavResource]) -> ReportOutcome {
  match report_kind(body) {
    Multiget => {
      let hrefs = xml_text_values(body, "href")
      let selected : Map[String, Unit] = Map([], capacity=hrefs.length())
      for href in hrefs {
        // hrefs arrive entity-encoded like any other character data; a
        // query-string ampersand sits on the wire as &amp;.
        selected[decode_xml_entities(href)] = ()
      }
      let entries : Array[String] = []
      let answered : Map[String, Unit] = Map([], capacity=resources.length())
      for resource in resources {
        if selected.contains(resource.href) {
          entries.push(resource_response(resource, true))
          answered[resource.href] = ()
        }
      }
      // A requested href with nothing behind it answers 404 for that
      // href, the per-href shape RFC 4791's multiget examples show:
      // silently dropping it left a client reconciling deletions unable
      // to tell "absent" from "deleted".
      for href in hrefs {
        let decoded = decode_xml_entities(href)
        if !answered.contains(decoded) {
          entries.push(missing_href_response(decoded))
          answered[decoded] = ()
        }
      }
      Report(body=multistatus(entries))
    }
    Query => {
      let filter = parse_filter(body) catch {
        FilterError::InvalidFilter(_) =>
          return PreconditionFailed(body=error_document("<C:valid-filter/>"))
        FilterError::UnsupportedFilter(element~) =>
          return PreconditionFailed(
            body=error_document(
              "<C:supported-filter>\{element}</C:supported-filter>",
            ),
          )
      }
      let entries : Array[String] = []
      for resource in resources {
        if filter.matches(resource.calendar_data) {
          entries.push(resource_response(resource, true))
        }
      }
      Report(body=multistatus(entries))
    }
    Other => UnsupportedReport
  }
}

///|
/// The `DAV:error` body that carries a failed precondition, the shape
/// RFC 4791 §7.8 specifies for the filter preconditions.
fn error_document(inner : String) -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:error xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
  inner +
  "</D:error>"
}

///|
/// The `DAV:response` for a requested href with nothing behind it: the
/// bare 404 status line, the per-href shape RFC 4791's multiget examples
/// show for missing resources.
fn missing_href_response(href : String) -> String {
  "<D:response><D:href>\{xml_escape(href)}</D:href>" +
  "<D:status>HTTP/1.1 404 Not Found</D:status></D:response>"
}

///|
fn resource_response(item : DavResource, include_data : Bool) -> String {
  let data = if include_data {
    "<C:calendar-data>\{xml_escape(item.calendar_data)}</C:calendar-data>"
  } else {
    ""
  }
  response(
    item.href,
    "<D:resourcetype/>" +
    "<D:getcontenttype>text/calendar; charset=utf-8</D:getcontenttype>" +
    "<D:getetag>\{xml_escape("\"\{item.etag}\"")}</D:getetag>" +
    data,
  )
}

///|
fn response(href : String, properties : String) -> String {
  "<D:response><D:href>\{xml_escape(href)}</D:href>" +
  "<D:propstat><D:prop>\{properties}</D:prop>" +
  "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
}

///|
fn multistatus(entries : Array[String]) -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:multistatus xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
  entries.join("") +
  "</D:multistatus>"
}

///|
/// Escape the five XML metacharacters so a calendar value or an href can sit
/// inside a DAV response without being read as markup. The inverse of what a
/// client does when it parses the response back.
pub fn xml_escape(text : String) -> String {
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '\"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Extract text from namespace-qualified or unqualified XML elements with a
/// given local name. This deliberately small parser is sufficient for DAV
/// request selection and never interprets entities as markup.
fn xml_text_values(xml : String, local_name : String) -> Array[String] {
  let values : Array[String] = []
  let view = xml.view()
  let wanted = local_name.view()
  let n = view.length()
  let mut i = 0
  while i < n {
    if view[i] == '<' && i + 1 < n && view[i + 1] != '/' {
      let mut close = i + 1
      while close < n && view[close] != '>' && view[close] != ' ' {
        close = close + 1
      }
      let qname = view[i + 1:close]
      if local_part(qname).equal_ignore_ascii_case(wanted) {
        let mut open_end = close
        while open_end < n && view[open_end] != '>' {
          open_end = open_end + 1
        }
        if open_end < n {
          let close_name = "</\{qname}>"
          let rest = view[open_end + 1:]
          match rest.find(close_name.view()) {
            Some(offset) => {
              values.push(rest[:offset].to_owned())
              i = open_end + 1 + offset + close_name.length()
              continue
            }
            None => ()
          }
        }
      }
    }
    i = i + 1
  }
  values
}

///|
fn local_part(name : StringView) -> StringView {
  match name.rev_find(":".view()) {
    Some(colon) => name[colon + 1:]
    None => name
  }
}
