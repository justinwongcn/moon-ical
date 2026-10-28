///|
/// What a `PROPFIND` or `REPORT` body asks the server to return
/// (RFC 4918 §9.1, RFC 4791 §9.5/§9.10).
pub(all) enum PropFind {
  /// Every property the server knows on the resource. An empty `PROPFIND`
  /// request body MUST be read as this (RFC 4918 §9.1); a `REPORT` whose
  /// body names no selection form reads the same way, its DTD leaving the
  /// element optional.
  AllProp
  /// Only the names of the known properties, with no values.
  PropName
  /// Exactly the named properties, by lowercased local name. A name the
  /// resource has no answer for is answered 404 in its own propstat
  /// (RFC 4918 §9.1.2).
  Prop(Array[String])
} derive(Debug, Eq)

///|
pub extend PropFind with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PropFind with Eq::{not_equal, equal}

///|
/// A `PROPFIND` body this server cannot read as a property selection: it
/// is not an XML element, does not root at `propfind`, or names none of
/// the three selection forms the DTD requires (RFC 4918 §14.20). On the
/// wire this answers 400, the same refusal an unreadable `REPORT` body
/// already gets.
pub(all) suberror PropfindError {
  Malformed
} derive(Debug, Eq)

///|
pub extend PropfindError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PropfindError with Eq::{not_equal, equal}

///|
pub impl Show for PropfindError with fn output(self, logger) {
  let Malformed = self
  logger.write_string("malformed PROPFIND body")
}

///|
pub extend PropfindError with Show::{to_string, output}

///|
/// Read the property selection out of a `PROPFIND` request body
/// (RFC 4918 §9.1). An empty body is an `allprop` request; a body that
/// does not parse, does not root at `propfind`, or names none of the
/// three selection forms the DTD requires raises
/// [`PropfindError::Malformed`].
pub fn parse_propfind(body : String) -> PropFind raise PropfindError {
  if body.view().trim().length() == 0 {
    return AllProp
  }
  guard parse_xml_element(body) is Some(root) else {
    raise PropfindError::Malformed
  }
  if root.name != "propfind" {
    raise PropfindError::Malformed
  }
  match selection_of(root) {
    Some(selection) => selection
    None => raise PropfindError::Malformed
  }
}

///|
/// The selection form named by an element's direct children, in DTD
/// order (RFC 4791 §9.5/§9.10 make the choice optional, RFC 4918 §14.20
/// requires exactly one). `None` when no selection form appears; when
/// more than one does, the first in document order wins. Children other
/// than the three selection forms are ignored — the server does not
/// invent refusal policy for markup it was not asked to act on.
fn selection_of(root : XmlElement) -> PropFind? {
  for child in root.children {
    match child.name {
      "propname" => return Some(PropName)
      "allprop" => return Some(AllProp)
      "prop" => {
        // Requested names in document order, first occurrence wins: a
        // client naming a property twice gets one answer, not two.
        let requested : Array[String] = []
        for item in child.children {
          if !requested.contains(item.name) {
            requested.push(item.name)
          }
        }
        return Some(Prop(requested))
      }
      _ => ()
    }
  }
  None
}

///|
/// Which request the properties are being answered for. `calendar-data`
/// is a CalDAV report property, not a WebDAV property (RFC 4791 §9.6:
/// it "is not returned in PROPFIND responses"), so it exists for `REPORT`
/// answers and does not exist for `PROPFIND` — where a client naming it
/// gets the 404 propstat RFC 4918 §9.1 asks for a property that does not
/// exist.
priv enum PropContext {
  PropfindContext
  ReportContext
}

///|
/// One property the server can answer for a resource: its lowercased
/// local name (the key a request matches by), the qualified name it is
/// echoed under, and the value element as it goes on the wire.
priv struct DavProp {
  name : String
  qname : String
  value : String
}

///|
/// The properties of a calendar object resource. In report context the
/// answer includes `calendar-data`; in `PROPFIND` context it cannot.
fn resource_props(item : DavResource, context : PropContext) -> Array[DavProp] {
  let props : Array[DavProp] = [
    {
      name: "resourcetype",
      qname: "D:resourcetype",
      value: "<D:resourcetype/>",
    },
    {
      name: "getcontenttype",
      qname: "D:getcontenttype",
      value: "<D:getcontenttype>text/calendar; charset=utf-8</D:getcontenttype>",
    },
    {
      name: "getetag",
      qname: "D:getetag",
      value: "<D:getetag>\{xml_escape("\"\{item.etag}\"")}</D:getetag>",
    },
  ]
  if context is ReportContext {
    props.push({
      name: "calendar-data",
      qname: "C:calendar-data",
      value: "<C:calendar-data>\{xml_escape(item.calendar_data)}</C:calendar-data>",
    })
  }
  props
}

///|
/// The properties of a calendar collection. `displayname` only exists
/// when the collection has a name to show — an unnamed collection has no
/// answer for it, the same 404 an unknown name gets.
fn collection_props(displayname : String) -> Array[DavProp] {
  let props : Array[DavProp] = [
    {
      name: "resourcetype",
      qname: "D:resourcetype",
      value: "<D:resourcetype><D:collection/><C:calendar/></D:resourcetype>",
    },
  ]
  if displayname.length() > 0 {
    props.push({
      name: "displayname",
      qname: "D:displayname",
      value: "<D:displayname>\{xml_escape(displayname)}</D:displayname>",
    })
  }
  props.push({
    name: "supported-calendar-component-set",
    qname: "C:supported-calendar-component-set",
    value: "<C:supported-calendar-component-set><C:comp name=\"VEVENT\"/></C:supported-calendar-component-set>",
  })
  props.push({
    name: "current-user-principal",
    qname: "D:current-user-principal",
    value: "<D:current-user-principal><D:href>/principals/default/</D:href></D:current-user-principal>",
  })
  props
}

///|
/// The properties of the single built-in principal.
fn principal_props() -> Array[DavProp] {
  [
    {
      name: "resourcetype",
      qname: "D:resourcetype",
      value: "<D:resourcetype><D:principal/></D:resourcetype>",
    },
    {
      name: "calendar-home-set",
      qname: "C:calendar-home-set",
      value: "<C:calendar-home-set><D:href>/cal/</D:href></C:calendar-home-set>",
    },
    {
      name: "displayname",
      qname: "D:displayname",
      value: "<D:displayname>moon-ical</D:displayname>",
    },
  ]
}

///|
/// The properties of the server root.
fn root_props() -> Array[DavProp] {
  [
    {
      name: "resourcetype",
      qname: "D:resourcetype",
      value: "<D:resourcetype><D:collection/></D:resourcetype>",
    },
    {
      name: "current-user-principal",
      qname: "D:current-user-principal",
      value: "<D:current-user-principal><D:href>/principals/default/</D:href></D:current-user-principal>",
    },
  ]
}

///|
/// One `DAV:response` answering `selection` from `props`: the matched
/// properties in a 200 propstat, the names with no answer in a 404
/// propstat (RFC 4918 §9.1.2, the two-propstat shape the §9.1.3 example
/// shows). A `prop` request naming nothing answers one empty 200
/// propstat. A name asked twice is answered once. Names echoed into a
/// 404 propstat carry the `DAV:` prefix regardless of the prefix the
/// request used — the shape parser keeps local names only.
fn propfind_response(
  href : String,
  props : Array[DavProp],
  selection : PropFind,
) -> String {
  let found : Array[String] = []
  let missing : Array[String] = []
  let answered : Array[String] = []
  match selection {
    AllProp =>
      for prop in props {
        found.push(prop.value)
      }
    PropName =>
      for prop in props {
        found.push("<\{prop.qname}/>")
      }
    Prop(requested) =>
      for name in requested {
        if answered.contains(name) {
          continue
        }
        answered.push(name)
        let mut answer : DavProp? = None
        for prop in props {
          if prop.name == name {
            answer = Some(prop)
            break
          }
        }
        match answer {
          Some(prop) => found.push(prop.value)
          // The echo is escaped: the shape parser's name scan admits
          // characters (&, <) an XML NCName forbids, and an unescaped
          // echo would let a request body corrupt the response's markup.
          None => missing.push("<D:\{xml_escape(name)}/>")
        }
      }
  }
  let mut body = "<D:response><D:href>\{xml_escape(href)}</D:href>"
  if found.length() > 0 || missing.length() == 0 {
    body = body +
      "<D:propstat><D:prop>\{found.join("")}</D:prop>" +
      "<D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
  }
  if missing.length() > 0 {
    body = body +
      "<D:propstat><D:prop>\{missing.join("")}</D:prop>" +
      "<D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>"
  }
  body + "</D:response>"
}

///|
/// A DAV multistatus body for the server root, exposing the current-user
/// principal used by Thunderbird, DAVx5, and Apple Calendar discovery.
pub fn root_propfind(selection~ : PropFind = AllProp) -> String {
  multistatus([propfind_response("/", root_props(), selection)])
}

///|
/// A DAV multistatus body for the single built-in principal.
pub fn principal_propfind(selection~ : PropFind = AllProp) -> String {
  multistatus([
    propfind_response("/principals/default/", principal_props(), selection),
  ])
}

///|
/// A DAV multistatus body for one calendar collection. Depth 0 returns only
/// the collection itself; depth 1 additionally returns every nested calendar
/// collection and every calendar object with its ETag.
///
/// `href` and `displayname` describe the collection being asked about, so the
/// same builder answers for the calendar home and for a collection created by
/// `MKCALENDAR` (RFC 4791 §5.3.1). The selection is what the request body
/// asked for (RFC 4918 §9.1); an absent selection answers every property.
pub fn collection_propfind(
  resources : Array[DavResource],
  depth : Int32,
  href~ : String = "/cal/",
  displayname~ : String = "moon-ical",
  children~ : Array[(String, String)] = [],
  selection~ : PropFind = AllProp,
) -> String {
  let entries : Array[String] = [
    propfind_response(href, collection_props(displayname), selection),
  ]
  if depth == 1 {
    for child in children {
      let (child_href, child_name) = child
      entries.push(
        propfind_response(child_href, collection_props(child_name), selection),
      )
    }
    for item in resources {
      entries.push(
        propfind_response(
          item.href,
          resource_props(item, PropfindContext),
          selection,
        ),
      )
    }
  }
  multistatus(entries)
}
