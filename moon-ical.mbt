///|
/// Root package of moon-ical.
///
/// The implementation remains in focused subpackages; this facade exposes the
/// stable parsing, model, recurrence, serialization, and CalDAV semantics from
/// one import for mooncakes.io users.

///|
pub using @text {
  type ContentLine,
  type ParseError,
  type PropertyParam,
  escape_value,
  parse_content_line,
  unescape_value,
  unfold,
}

///|
pub using @model {
  type Component,
  type Event,
  type IcalDateTime,
  type ZoneTable,
  build_zone_table,
  parse_components,
  parse_date_time,
  parse_date_time_value,
  parse_events,
  parse_single_date_time,
  parse_utc_offset,
}

///|
pub using @rrule {
  type Byday,
  type ExpandError,
  type Freq,
  type Occurrence,
  type Rule,
  expand,
  expand_series,
  parse_rule,
}

///|
pub using @serialize {
  serialize_component,
  serialize_components,
  serialize_content_line,
}

///|
pub using @caldav {
  type DavResource,
  type Precondition,
  check_preconditions,
  collection_propfind,
  principal_propfind,
  report,
  root_propfind,
  xml_escape,
}
