///|
/// The properties a `MKCALENDAR` request body asks the new collection to
/// carry (RFC 4791 §5.3.1): the parsed, typed form of what the client
/// sent. Parsing only — what to persist, where, and in what format is
/// the embedding server's deployment decision, not this package's
/// (adjudicated: the library parses and exposes, the embedder stores).
pub(all) struct MkCalendarProps {
  /// `DAV:displayname` — the human name for the new collection.
  displayname : String?
  /// `CALDAV:calendar-description` — the human description.
  description : String?
  /// `ICAL:calendar-color` (Apple's extension, `#RRGGBB` or `#RRGGBBAA`)
  /// — read verbatim as opaque text since the extension defines no
  /// single canonical form.
  color : String?
} derive(Debug, Eq)

///|
pub extend MkCalendarProps with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend MkCalendarProps with Eq::{not_equal, equal}

///|
/// Parse a `MKCALENDAR` request body into its properties. A body that is
/// not an XML element at all parses as "no properties asked" — the
/// request stays legal (RFC 4791 §5.3.1 makes the body optional) and the
/// collection's name is its display name, exactly as the server already
/// answers. Where an element appears in both the outer `DAV:prop` and
/// the `DAV:set/DAV:prop`, the shallowest occurrence wins (the search is
/// breadth-first), and each property reads its first occurrence.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() {
///   let props = @caldav.parse_mkcalendar(
///     "<C:mkcalendar xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
///     + "<D:prop><D:displayname>Lisa's Events</D:displayname></D:prop>"
///     + "</C:mkcalendar>",
///   )
///   assert_eq(props.displayname, Some("Lisa's Events"))
/// }
/// ```
pub fn parse_mkcalendar(body : String) -> MkCalendarProps {
  let document = match parse_xml_element(body) {
    Some(element) => element
    None => return { displayname: None, description: None, color: None, }
  }
  fn text_of(local_name : String) -> String? {
    match find_descendant(document, local_name) {
      Some(element) => Some(decode_xml_entities(element.text))
      None => None
    }
  }
  {
    displayname: text_of("displayname"),
    description: text_of("calendar-description"),
    color: text_of("calendar-color"),
  }
}
