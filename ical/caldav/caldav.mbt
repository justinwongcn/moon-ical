///|
/// One calendar object exposed by a collection response.
pub(all) struct DavResource {
  href : String
  etag : String
  calendar_data : String
} derive(Debug, Eq)

///|
/// The result of evaluating HTTP entity-tag preconditions.
pub(all) enum Precondition {
  Pass
  Failed
} derive(Debug, Eq)

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
/// A DAV multistatus body for `/cal/`. Depth 0 returns only the collection;
/// depth 1 additionally returns every calendar object and its ETag.
pub fn collection_propfind(
  resources : Array[DavResource],
  depth : Int,
) -> String {
  let entries : Array[String] = [
    response(
      "/cal/",
      "<D:resourcetype><D:collection/><C:calendar/></D:resourcetype>" +
      "<D:displayname>moon-ical</D:displayname>" +
      "<C:supported-calendar-component-set><C:comp name=\"VEVENT\"/></C:supported-calendar-component-set>" +
      "<D:current-user-principal><D:href>/principals/default/</D:href></D:current-user-principal>",
    ),
  ]
  if depth == 1 {
    for item in resources {
      entries.push(resource_response(item, false))
    }
  }
  multistatus(entries)
}

///|
/// Build a `calendar-query` or `calendar-multiget` response. A multiget body
/// selects the requested `<href>` values; a calendar-query returns all event
/// resources. Unknown REPORT bodies produce no selected resources.
pub fn report(body : String, resources : Array[DavResource]) -> String? {
  let upper = String::to_upper(body)
  if upper.contains("CALENDAR-MULTIGET") {
    let hrefs = xml_text_values(body, "href")
    let selected : Map[String, Unit] = Map([], capacity=hrefs.length())
    for href in hrefs {
      selected[href] = ()
    }
    let entries : Array[String] = []
    for resource in resources {
      if selected.contains(resource.href) {
        entries.push(resource_response(resource, true))
      }
    }
    Some(multistatus(entries))
  } else if upper.contains("CALENDAR-QUERY") {
    Some(multistatus(resources.map(item => resource_response(item, true))))
  } else {
    None
  }
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
