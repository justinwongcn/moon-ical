///|
/// Root package of moon-ical.
///
/// The implementation remains in focused subpackages; this facade exposes the
/// complete parse, recurrence, and serialization workflows from one import.
/// Protocol-building primitives stay in their focused subpackages.

///|
pub using @text {type ParseError}

///|
pub using @model {
  type Component,
  type Event,
  type IcalDateTime,
  parse_calendar,
  parse_events,
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
pub using @serialize {serialize_component, serialize_components}
