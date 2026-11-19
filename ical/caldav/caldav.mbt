///|
/// One calendar object exposed by a collection response.
#derive(Debug, Eq)
pub(all) struct DavResource {
  href : String
  etag : String
  calendar_data : String
}

///|
pub extend DavResource with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend DavResource with Eq::{not_equal, equal}

///|
/// The result of evaluating HTTP entity-tag preconditions.
#derive(Debug, Eq)
pub(all) enum Precondition {
  Pass
  Failed
}

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
      for part in value.to_string_view().split(",".to_string_view()) {
        let item = part.trim(chars=" \t".to_string_view())
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
/// What a `REPORT` request body produced.
///
/// The cases stay separate rather than folding into an optional body because
/// the failures answer differently on the wire: an unknown report is `400`,
/// while the two filter preconditions of RFC 4791 §7.8 are `403` with a
/// `DAV:error` body naming the test that failed.
#derive(Debug, Eq)
pub(all) enum ReportOutcome {
  /// A `DAV:multistatus` body listing the resources the report selected.
  Report(body~ : String)
  /// The body is a `REPORT` this server does not implement.
  UnsupportedReport
  /// A precondition failed; `body` is the `DAV:error` document to send.
  PreconditionFailed(body~ : String)
  EvaluationFailed(reason~ : String)
}

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
///
/// Both reports carry a property selection as a direct child of their
/// root, which the DTD (RFC 4791 §9.5/§9.10) leaves optional; the
/// response answers that selection the way `PROPFIND` would (§7.8), so
/// an unrequested property is not returned and a requested one with no
/// answer gets its own 404 propstat.
pub fn report(body : String, resources : Array[DavResource]) -> ReportOutcome {
  // The report type is the root element's local name, read by the same
  // XML shape parser the filter uses — not a substring scan of the whole
  // body, which let a `text-match` needle or href that mentioned the
  // other report's name misroute the request.
  guard parse_xml_element(body) is Some(root) else {
    // A body that is not an XML element at all names no report this
    // server implements.
    return UnsupportedReport
  }
  match root.name {
    "calendar-multiget" => multiget_report(root, resources)
    "calendar-query" => query_report(root, body, resources)
    _ => UnsupportedReport
  }
}

///|
/// The character data of every `href` element at any depth, in document
/// order — read off the tree the report already parsed, so the body is
/// scanned once, not twice (the hrefs used to come from a second raw
/// pass over the whole body).
fn collect_hrefs(element : XmlElement, out : Array[String]) -> Unit {
  for child in element.children {
    if child.name == "href" {
      out.push(child.text)
    } else {
      collect_hrefs(child, out)
    }
  }
}

///|
/// The `calendar-multiget` branch: answer the requested `href` values
/// with the properties the report's selection names.
fn multiget_report(
  root : XmlElement,
  resources : Array[DavResource],
) -> ReportOutcome {
  let selection = selection_of(root).unwrap_or(AllProp)
  let hrefs : Array[String] = []
  collect_hrefs(root, hrefs)
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
      entries.push(
        propfind_response(
          resource.href,
          resource_props(resource, ReportContext),
          selection,
        ),
      )
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

///|
/// The `calendar-query` branch: evaluate the filter and answer each
/// matching resource with the properties the report's selection names.
fn query_report(
  root : XmlElement,
  body : String,
  resources : Array[DavResource],
) -> ReportOutcome {
  let filter = parse_filter(body) catch {
    FilterError::InvalidFilter(_) =>
      return PreconditionFailed(body=error_document("<C:valid-filter/>"))
    FilterError::InvalidCalendarData =>
      return PreconditionFailed(body=error_document("<C:valid-calendar-data/>"))
    FilterError::InvalidCalendarObjectResource =>
      return PreconditionFailed(
        body=error_document("<C:valid-calendar-object-resource/>"),
      )
    FilterError::UnsupportedCollation =>
      return PreconditionFailed(body=error_document("<C:supported-collation/>"))
    FilterError::UnsupportedFilter(element~) =>
      return PreconditionFailed(
        body=error_document(
          "<C:supported-filter>\{element}</C:supported-filter>",
        ),
      )
  }
  let selection = selection_of(root).unwrap_or(AllProp)
  let entries : Array[String] = []
  for resource in resources {
    // A failed evaluation is not an empty result: propagate it instead of
    // silently dropping the resource from the answer.
    let matched = filter.matches(resource.calendar_data) catch {
      err =>
        return EvaluationFailed(
          reason="\{resource.href}: \{evaluation_reason(err)}",
        )
    }
    if matched {
      entries.push(
        propfind_response(
          resource.href,
          resource_props(resource, ReportContext),
          selection,
        ),
      )
    }
  }
  Report(body=multistatus(entries))
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
fn multistatus(entries : Array[String]) -> String {
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
  "<D:multistatus xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">" +
  entries.join("") +
  "</D:multistatus>"
}

///|
/// Escape the five XML metacharacters and replace the control characters
/// XML 1.0 forbids, so a calendar value or an href can sit inside a DAV
/// response without being read as markup and without making the whole
/// document unparseable. The inverse of what a client does when it parses
/// the response back.
///
/// Stored bytes are served verbatim from the data layer — the store keeps
/// whatever a PUT delivered, and `PUT` does not validate body content. A
/// `SUMMARY` containing U+0000 therefore reaches this function and used to
/// reach the wire raw: XML 1.0 allows only TAB/LF/CR below U+0020, so one
/// poisoned resource made every `PROPFIND`/multiget/`calendar-query`
/// response over the collection unparseable for the clients syncing it.
/// Each forbidden control character becomes U+FFFD — the document stays
/// valid XML and the position stays visible — while TAB, LF, and CR (the
/// three legal ones) and every other character pass through untouched.
pub fn xml_escape(text : String) -> String {
  let v = text.to_string_view()
  let n = v.length()
  // The common inputs (etags, hrefs, ASCII calendar data) carry no
  // metacharacter or forbidden control: one scan returns the input without
  // building a copy.
  let mut i = 0
  while i < n &&
        !(v[i]
        is ('&'
        | '<'
        | '>'
        | '"'
        | '\''
        | '\u{0000}'..<='\u{0008}'
        | '\u{000B}'
        | '\u{000C}'
        | '\u{000E}'..<='\u{001F}')) {
    i = i + 1
  }
  if i == n {
    return text
  }
  let out = StringBuilder()
  for c in text {
    match c {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '\"' => out.write_string("&quot;")
      '\'' => out.write_string("&apos;")
      _ =>
        if c
          is ('\u{0000}'..<='\u{0008}'
          | '\u{000B}'
          | '\u{000C}'
          | '\u{000E}'..<='\u{001F}') {
          out.write_string("\u{FFFD}")
        } else {
          out.write_char(c)
        }
    }
  }
  out.to_string()
}

///|
fn local_part(name : StringView) -> StringView {
  match name.rev_find(":".to_string_view()) {
    Some(colon) => name[colon + 1:]
    None => name
  }
}
