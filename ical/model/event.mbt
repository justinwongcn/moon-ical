///|
/// One calendar event, mapped from a `VEVENT` component (RFC 5545 §3.6.1).
///
/// This is a typed *view* over the component tree, not a replacement for it:
/// unknown properties stay in the `Component` and nothing is dropped. Every
/// field is optional because RFC 5545 makes every `VEVENT` property optional;
/// a property that is *present but malformed* raises [`@text.ParseError`]
/// instead of being silently skipped, so a broken feed is loud rather than
/// subtly wrong. A property that is simply absent is `None` — absence is not
/// breakage.
///
/// Not interpreted yet: `DURATION` as the alternative end to `DTEND` (needs
/// ISO 8601 duration parsing, planned with the recurrence work), and merging
/// override events into an expanded series (S8). `RECURRENCE-ID` is parsed
/// and kept so a moved or cancelled single instance is already visible.
pub struct Event {
  uid : String?
  summary : String?
  location : String?
  description : String?
  dtstart : IcalDateTime?
  dtend : IcalDateTime?
  /// The raw `RRULE` value exactly as it appeared on the wire; the rule is
  /// parsed and expanded by later milestones (S2/S3/S8).
  rrule : String?
  /// The series instance this event overrides, when this is an override
  /// event rather than a series definition.
  recurrence_id : IcalDateTime?
  /// `RANGE=THISANDFUTURE` on RECURRENCE-ID, when present.
  recurrence_range : String?
  /// Event status, notably `CANCELLED` on an overridden instance.
  status : String?
  /// Every `EXDATE` value across repeated property lines, in wire order.
  exdates : Array[IcalDateTime]
} derive(Debug)

///|
/// An all-day event is one whose `DTSTART` is a DATE value.
pub fn Event::all_day(self : Event) -> Bool {
  match self.dtstart {
    Some(dt) => dt.all_day
    None => false
  }
}

///|
pub impl Show for Event with fn output(self, logger) {
  let uid = self.uid.unwrap_or("-")
  let summary = self.summary.unwrap_or("")
  match self.dtstart {
    Some(dt) => logger.write_string("VEVENT \{uid}: \{summary} @ \{dt}")
    None => logger.write_string("VEVENT \{uid}: \{summary}")
  }
}

///|
/// The `VEVENT` children of this component as typed events, in wire order.
///
/// `zones` resolves `TZID=` parameters. Pass the table the way [`parse_events`]
/// builds it — [`ZoneTable::with_builtin`] over [`build_zone_table`] applied to
/// the same feed — so a feed's own `VTIMEZONE` wins over the built-in guesses.
///
/// Only direct children are considered: a `VEVENT` nests directly inside a
/// `VCALENDAR`, never deeper.
pub fn Component::events(
  self : Component,
  zones~ : ZoneTable,
) -> Array[Event] raise {
  let out : Array[Event] = []
  for child in self.children {
    if child.kind == "VEVENT" {
      out.push(event_from_component(child, zones))
    }
  }
  out
}

///|
/// Parse a complete iCalendar document into its lossless component trees.
/// Unknown components and properties remain available for inspection and
/// serialization.
pub fn parse_calendar(input : String) -> Array[Component] raise {
  parse_components(@text.unfold(input))
}

///|
/// Parse a whole iCalendar feed into typed events: unfold the text, build
/// the component tree, resolve zones (the feed's own `VTIMEZONE` first,
/// built-in guesses second), then map every `VEVENT`.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let events = @model.parse_events(
///     "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Sync\r\nEND:VEVENT\r\nEND:VCALENDAR",
///   )
///   assert_eq(events.length(), 1)
///   assert_eq(events[0].summary, Some("Sync"))
/// }
/// ```
pub fn parse_events(input : String) -> Array[Event] raise {
  let roots = parse_calendar(input)
  let zones = ZoneTable::with_builtin(build_zone_table(roots))
  let out : Array[Event] = []
  for root in roots {
    for event in root.events(zones~) {
      out.push(event)
    }
  }
  out
}

///|
/// Map one `VEVENT` component onto an [`Event`]. A malformed date property
/// raises; a missing one stays `None`.
fn event_from_component(
  component : Component,
  zones : ZoneTable,
) -> Event raise {
  let dtstart = match component.property("DTSTART") {
    Some(line) => Some(parse_date_time(line, zones))
    None => None
  }
  let dtend = match component.property("DTEND") {
    Some(line) => Some(parse_date_time(line, zones))
    None => None
  }
  let recurrence_id = match component.property("RECURRENCE-ID") {
    Some(line) => Some(parse_date_time(line, zones))
    None => None
  }
  let recurrence_range = match component.property("RECURRENCE-ID") {
    Some(line) => line.param("RANGE")
    None => None
  }
  let exdates : Array[IcalDateTime] = []
  for line in component.properties_named("EXDATE") {
    let tzid = line.param("TZID")
    let value_is_date = match line.param("VALUE") {
      Some(v) => String::to_upper(v) == "DATE"
      None => false
    }
    for value in split_values(line.value) {
      exdates.push(
        parse_date_time_value(value, zones, tzid~, value_is_date~, line_no=0),
      )
    }
  }
  {
    uid: text_of(component, "UID"),
    summary: text_of(component, "SUMMARY"),
    location: text_of(component, "LOCATION"),
    description: text_of(component, "DESCRIPTION"),
    dtstart,
    dtend,
    rrule: match component.property("RRULE") {
      Some(line) => Some(line.value)
      None => None
    },
    recurrence_id,
    recurrence_range,
    status: text_of(component, "STATUS"),
    exdates,
  }
}

///|
/// Unescaped display text of the first property with this name, if any.
fn text_of(component : Component, name : String) -> String? {
  match component.property(name) {
    Some(line) => Some(@text.unescape_value(line.value))
    None => None
  }
}

///|
/// Split a comma-separated property value into its parts, as `EXDATE` and
/// `RDATE` lists are written. Hand-rolled for the same reason as the other
/// string helpers in this module: explicit slices, no view pitfalls.
fn split_values(value : String) -> Array[String] {
  let parts : Array[String] = []
  let chars = value.to_array()
  let n = chars.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if chars[i] == ',' {
      parts.push(String::from_array(chars[start:i]))
      start = i + 1
    }
    i = i + 1
  }
  parts.push(String::from_array(chars[start:n]))
  parts
}
