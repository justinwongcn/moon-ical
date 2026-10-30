///|
/// A `CALDAV:time-range` test (RFC 4791 §9.7.1) as a half-open interval of
/// UTC seconds. `None` on a side means that side is unbounded, which is how
/// a client asks for "everything after this" or "everything before that".
pub(all) struct TimeRange {
  start : Int64?
  end : Int64?
} derive(Debug, Eq)

///|
pub extend TimeRange with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend TimeRange with Eq::{not_equal, equal}

///|
/// A `CALDAV:text-match` test (RFC 4791 §9.7.4): a substring search over a
/// property value or a parameter value.
pub(all) struct TextMatch {
  text : String
  /// `negate-condition="yes"` inverts the test.
  negate : Bool
  /// `i;ascii-casemap` (the default) folds ASCII case; `i;octet` is exact.
  collation : String
} derive(Debug, Eq)

///|
pub extend TextMatch with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend TextMatch with Eq::{not_equal, equal}

///|
/// A `CALDAV:param-filter` (RFC 4791 §9.7.3): tests one parameter of the
/// enclosing property.
pub(all) struct ParamFilter {
  name : String
  is_not_defined : Bool
  text_match : TextMatch?
} derive(Debug, Eq)

///|
pub extend ParamFilter with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ParamFilter with Eq::{not_equal, equal}

///|
/// A `CALDAV:prop-filter` (RFC 4791 §9.7.2): tests one property of the
/// enclosing component.
pub(all) struct PropFilter {
  /// The property name, uppercased so it matches `ContentLine.name`.
  name : String
  is_not_defined : Bool
  time_range : TimeRange?
  text_match : TextMatch?
  params : Array[ParamFilter]
} derive(Debug, Eq)

///|
pub extend PropFilter with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PropFilter with Eq::{not_equal, equal}

///|
/// A `CALDAV:comp-filter` (RFC 4791 §9.7.1): tests one calendar component
/// type in the current scope, optionally recursing into nested components.
pub(all) struct CompFilter {
  /// The component name, uppercased (`VCALENDAR`, `VEVENT`, ...).
  name : String
  is_not_defined : Bool
  time_range : TimeRange?
  comps : Array[CompFilter]
  props : Array[PropFilter]
} derive(Debug, Eq)

///|
pub extend CompFilter with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend CompFilter with Eq::{not_equal, equal}

///|
/// A parsed `CALDAV:filter` element: the search a `calendar-query` asks for.
///
/// Before this existed the server answered every `calendar-query` with the
/// whole collection, so a client that asked for one week received the entire
/// calendar — RFC 4791 §7.8 makes the filter the defining part of the report,
/// and §7.4 requires a time range to be resolved against recurrence.
pub(all) struct Filter {
  root : CompFilter
  request_timezone : Bool
} derive(Debug, Eq)

///|
pub extend Filter with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Filter with Eq::{not_equal, equal}

///|
/// Why a `CALDAV:filter` could not be used.
///
/// The two variants are the two RFC 4791 §7.8 preconditions, and they are
/// deliberately distinct because the server must report them differently:
/// `valid-filter` for a body that is not a legal filter at all, and
/// `supported-filter` for a legal filter asking about something this server
/// cannot query. Both answer 403 with a `DAV:error` body naming the test.
pub(all) suberror FilterError {
  InvalidFilter(message~ : String)
  UnsupportedFilter(element~ : String)
  UnsupportedCollation
  InvalidCalendarData
} derive(Debug, Eq)

///|
pub extend FilterError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend FilterError with Eq::{not_equal, equal}

///|
pub impl Show for FilterError with fn output(self, logger) {
  match self {
    InvalidFilter(message=m) => logger.write_string("invalid filter: \{m}")
    UnsupportedFilter(element=e) =>
      logger.write_string("unsupported filter element: \{e}")
    UnsupportedCollation => logger.write_string("unsupported collation")
    InvalidCalendarData => logger.write_string("invalid request timezone")
  }
}

///|
pub extend FilterError with Show::{to_string, output}

///|
/// Parse the `CALDAV:filter` element of a `calendar-query` body.
///
/// A missing filter is an error rather than "match everything": RFC 4791
/// §9.5 makes the filter a required part of the request, and silently
/// answering with the whole collection is exactly the behaviour this module
/// replaces.
pub fn parse_filter(body : String) -> Filter raise FilterError {
  let document = match parse_xml_element(body) {
    Some(element) => element
    None =>
      raise FilterError::InvalidFilter(
        message="report body is not an XML element",
      )
  }
  match find_descendant(document, "timezone") {
    Some(timezone) => validate_request_timezone(timezone.text)
    None => ()
  }
  let element = match find_descendant(document, "filter") {
    Some(found) => found
    None =>
      raise FilterError::InvalidFilter(
        message="calendar-query without a CALDAV:filter element",
      )
  }
  let mut root : CompFilter? = None
  for child in element.children {
    match child.name {
      "comp-filter" => {
        if root is Some(_) {
          raise FilterError::InvalidFilter(
            message="CALDAV:filter carries more than one comp-filter",
          )
        }
        root = Some(parse_comp_filter(child))
      }
      _ =>
        raise FilterError::InvalidFilter(
          message="unexpected element in CALDAV:filter: \{child.name}",
        )
    }
  }
  match root {
    Some(top) =>
      {
        root: top,
        request_timezone: find_descendant(document, "timezone") is Some(_),
      }
    None =>
      raise FilterError::InvalidFilter(
        message="CALDAV:filter without a comp-filter",
      )
  }
}

///|
// RFC 4791 §7.8: request timezone must be one valid VTIMEZONE. Dynamic
// observances are legal even though temporal conversion is not implemented.
fn validate_request_timezone(text : String) -> Unit raise FilterError {
  let roots = @model.parse_calendar(decode_xml_entities(text)) catch {
    _ => raise FilterError::InvalidCalendarData
  }
  if roots.length() != 1 ||
    roots[0].kind != "VCALENDAR" ||
    roots[0].properties_named("VERSION").length() != 1 ||
    roots[0].property("VERSION").map(line => line.value) != Some("2.0") {
    raise FilterError::InvalidCalendarData
  }
  let zones = roots[0].children
  if zones.length() != 1 ||
    zones[0].kind != "VTIMEZONE" ||
    zones[0].properties_named("TZID").length() != 1 ||
    zones[0].property("TZID").map(line => line.value) == Some("") ||
    zones[0].children.length() == 0 {
    raise FilterError::InvalidCalendarData
  }
  for observance in zones[0].children {
    if observance.kind != "STANDARD" && observance.kind != "DAYLIGHT" {
      raise FilterError::InvalidCalendarData
    }
    for name in ["DTSTART", "TZOFFSETFROM", "TZOFFSETTO"] {
      if observance.properties_named(name).length() != 1 {
        raise FilterError::InvalidCalendarData
      }
      let line = match observance.property(name) {
        Some(line) => line
        None => raise FilterError::InvalidCalendarData
      }
      if name == "DTSTART" {
        if line.value.length() != 15 ||
          line.value.has_suffix("Z") ||
          line.param("TZID") is Some(_) ||
          (line.param("VALUE") is Some(value) && value != "DATE-TIME") {
          raise FilterError::InvalidCalendarData
        }
        let _ = @model.parse_date_time(line, @model.ZoneTable::empty()) catch {
          _ => raise FilterError::InvalidCalendarData
        }
      } else {
        let _ = @model.parse_utc_offset(line.value, line_no=0, raw=line.value) catch {
          _ => raise FilterError::InvalidCalendarData
        }
      }
    }
  }
}

///|
fn parse_comp_filter(element : XmlElement) -> CompFilter raise FilterError {
  let spelling = match element.attrs.get("name") {
    Some(value) => value
    None =>
      raise FilterError::InvalidFilter(message="comp-filter without a name")
  }
  let name = spelling.to_upper()
  if !is_queryable_component(name) {
    raise FilterError::UnsupportedFilter(
      element="<C:comp-filter name=\"\{spelling}\"/>",
    )
  }
  let is_not_defined = has_child(element, "is-not-defined")
  let mut time_range : TimeRange? = None
  let comps : Array[CompFilter] = []
  let props : Array[PropFilter] = []
  for child in element.children {
    match child.name {
      "is-not-defined" => ()
      "time-range" => {
        // A VALARM's trigger is relative to its parent and RFC 4791 §9.9
        // defines its overlap rule in terms of that parent; this server does
        // not resolve triggers, so it declines the test rather than guessing.
        if name == "VALARM" {
          raise FilterError::UnsupportedFilter(
            element="<C:comp-filter name=\"VALARM\"><C:time-range/></C:comp-filter>",
          )
        }
        time_range = Some(parse_time_range(child))
      }
      "comp-filter" => comps.push(parse_comp_filter(child))
      "prop-filter" => props.push(parse_prop_filter(child))
      _ =>
        raise FilterError::InvalidFilter(
          message="unexpected element in comp-filter: \{child.name}",
        )
    }
  }
  if is_not_defined &&
    (time_range is Some(_) || comps.length() > 0 || props.length() > 0) {
    raise FilterError::InvalidFilter(
      message="comp-filter is-not-defined cannot carry other tests",
    )
  }
  { name, is_not_defined, time_range, comps, props, }
}

///|
fn parse_prop_filter(element : XmlElement) -> PropFilter raise FilterError {
  let name = match element.attrs.get("name") {
    Some(value) => value
    None =>
      raise FilterError::InvalidFilter(message="prop-filter without a name")
  }
  let is_not_defined = has_child(element, "is-not-defined")
  let mut time_range : TimeRange? = None
  let mut text_match : TextMatch? = None
  let params : Array[ParamFilter] = []
  for child in element.children {
    match child.name {
      "is-not-defined" => ()
      "time-range" => time_range = Some(parse_time_range(child))
      "text-match" => text_match = Some(parse_text_match(child))
      "param-filter" => params.push(parse_param_filter(child))
      _ =>
        raise FilterError::InvalidFilter(
          message="unexpected element in prop-filter: \{child.name}",
        )
    }
  }
  if is_not_defined &&
    (time_range is Some(_) || text_match is Some(_) || params.length() > 0) {
    raise FilterError::InvalidFilter(
      message="prop-filter is-not-defined cannot carry other tests",
    )
  }
  { name: name.to_upper(), is_not_defined, time_range, text_match, params, }
}

///|
fn parse_param_filter(element : XmlElement) -> ParamFilter raise FilterError {
  let name = match element.attrs.get("name") {
    Some(value) => value
    None =>
      raise FilterError::InvalidFilter(message="param-filter without a name")
  }
  let is_not_defined = has_child(element, "is-not-defined")
  let mut text_match : TextMatch? = None
  for child in element.children {
    match child.name {
      "is-not-defined" => ()
      "text-match" => text_match = Some(parse_text_match(child))
      _ =>
        raise FilterError::InvalidFilter(
          message="unexpected element in param-filter: \{child.name}",
        )
    }
  }
  if is_not_defined && text_match is Some(_) {
    raise FilterError::InvalidFilter(
      message="param-filter is-not-defined cannot carry a text-match",
    )
  }
  { name: name.to_upper(), is_not_defined, text_match, }
}

///|
fn parse_text_match(element : XmlElement) -> TextMatch raise FilterError {
  let collation = element.attrs.get("collation").unwrap_or("")
  if !is_supported_collation(collation) {
    raise FilterError::UnsupportedCollation
  }
  let negate = match element.attrs.get("negate-condition") {
    Some(value) => value.to_lower() == "yes"
    None => false
  }
  // Character data arrives entity-encoded; a needle for "R&D" sits on
  // the wire as "R&amp;D", so compare against the decoded text.
  { text: decode_xml_entities(element.text), negate, collation, }
}

///|
fn parse_time_range(element : XmlElement) -> TimeRange raise FilterError {
  let start = match element.attrs.get("start") {
    Some(value) => Some(parse_instant(value))
    None => None
  }
  let end = match element.attrs.get("end") {
    Some(value) => Some(parse_instant(value))
    None => None
  }
  if start is None && end is None {
    raise FilterError::InvalidFilter(
      message="time-range without a start or an end",
    )
  }
  // A range that starts at or after it ends can never overlap anything;
  // answering it as an invalid filter says so, where silently matching
  // nothing would read as "no events in range" for a request that never
  // made sense.
  if start is Some(s) && end is Some(e) && s >= e {
    raise FilterError::InvalidFilter(
      message="time-range start must be before end",
    )
  }
  { start, end, }
}

///|
/// A `time-range` bound as a UTC instant. RFC 4791 §9.7.1 writes these in
/// UTC, so a bare `YYYYMMDD` (an all-day bound) reads as midnight UTC.
fn parse_instant(text : String) -> Int64 raise FilterError {
  let parsed = @model.parse_single_date_time(text, @model.ZoneTable::empty()) catch {
    _ =>
      raise FilterError::InvalidFilter(
        message="malformed time-range bound: \{text}",
      )
  }
  if !text.has_suffix("Z") || parsed.all_day {
    raise FilterError::InvalidFilter(
      message="time-range bound must be UTC DATE-TIME",
    )
  }
  parsed.instant_seconds()
}

///|
/// The component types this server answers queries about. RFC 4791 §7.7
/// requires a `supported-filter` failure for any other name rather than a
/// silently empty result.
fn is_queryable_component(name : String) -> Bool {
  name == "VCALENDAR" ||
  name == "VEVENT" ||
  name == "VTODO" ||
  name == "VJOURNAL" ||
  name == "VFREEBUSY" ||
  name == "VALARM"
}

///|
/// RFC 4791 §7.5 requires `i;ascii-casemap` and `i;octet`; `default` and an
/// absent attribute both mean `i;ascii-casemap`.
fn is_supported_collation(collation : String) -> Bool {
  match collation.to_lower() {
    "" | "default" | "i;ascii-casemap" | "i;octet" => true
    _ => false
  }
}

///|
/// How many occurrences the adaptive expansion starts with. A time range is
/// resolved by expanding until the series reaches the range or runs out, so
/// this is only a starting point rather than a cap on what can match.
const SERIES_INITIAL_LIMIT : Int32 = 32

///|
/// Maximum query work. Reaching it without coverage or exhaustion is a
/// checked server failure, never evidence of a successful empty result.
const SERIES_LIMIT_CAP : Int32 = 4096

///|
/// Lossless component trees only. Typed events and zones are interpreted
/// on demand so a SUMMARY search does not need recurrence or timezone support.
priv struct ResourceView {
  roots : Array[@model.Component]
  request_timezone : Bool
}

///|
priv suberror EvaluationError {
  CannotEvaluate(String)
}

///|
impl Show for EvaluationError with fn output(self, logger) {
  match self {
    CannotEvaluate(reason) => logger.write_string(reason)
  }
}

///|
// Never expose a parser's raw line, rule, or exception payload over HTTP
// or in logs: those may contain private calendar data.
fn evaluation_reason(err : Error) -> String {
  match err {
    EvaluationError::CannotEvaluate(_) =>
      "unsupported temporal evaluation or incomplete recurrence coverage"
    @text.ParseError::BadLine(..) =>
      "invalid or unsupported calendar date or structure"
    @text.ParseError::BadRule(..) => "invalid or unsupported recurrence rule"
    @rrule.ExpandError::Invalid(..) => "recurrence evaluation failed"
    @rrule.ExpandError::Unsupported(..) => "unsupported recurrence feature"
    _ => "calendar evaluation failed"
  }
}

///|
fn temporal_zones(view : ResourceView) -> @model.ZoneTable raise {
  if view.request_timezone {
    raise CannotEvaluate("request CALDAV:timezone is not implemented")
  }
  @model.ZoneTable::with_builtin(@model.build_zone_table(view.roots))
}

///|
/// The extent of one component: when it starts, when it ends (`None` when it
/// has no end), and whether it is an all-day value.
priv struct Interval {
  start : Int64
  finish : Int64?
  all_day : Bool
}

///|
/// Whether one calendar object resource matches this filter.
///
/// A failed evaluation is not evidence of an empty search. Dates and rules
/// are parsed only when a temporal test needs them; text searches remain
/// usable even when an unrelated recurrence cannot be interpreted.
pub fn Filter::matches(self : Filter, calendar_data : String) -> Bool raise {
  let view = {
    roots: @model.parse_calendar(calendar_data),
    request_timezone: self.request_timezone,
  }
  comp_matches(self.root, view.roots, view)
}

///|
/// Whether any component of the filtered type in this scope satisfies every
/// test the comp-filter carries.
///
/// RFC 4791 §9.7.1 applies the nested tests to the same component instance,
/// so this looks for one component that passes all of them rather than
/// collecting components that pass individually.
fn comp_matches(
  filter : CompFilter,
  scope : Array[@model.Component],
  view : ResourceView,
) -> Bool raise {
  if filter.is_not_defined {
    return !scope.any(component => component.kind == filter.name)
  }
  for component in scope {
    if component.kind == filter.name && comp_tests_pass(filter, component, view) {
      return true
    }
  }
  false
}

///|
fn comp_tests_pass(
  filter : CompFilter,
  component : @model.Component,
  view : ResourceView,
) -> Bool raise {
  // Cheap/text predicates can prove a non-match without interpreting an
  // unrelated unsupported rule or date on this component.
  for prop in filter.props {
    if !prop_matches(prop, component, view) {
      return false
    }
  }
  for child in filter.comps {
    if !comp_matches(child, component.children, view) {
      return false
    }
  }
  match filter.time_range {
    Some(range) => component_overlaps(component, range, view)
    None => true
  }
}

///|
/// Whether a component overlaps a time range.
///
/// A `VEVENT` is judged through the expanded series of *its own* UID
/// (RFC 4791 §7.4: the server MUST expand recurring components and match
/// when any instance overlaps), which also folds in `EXDATE`, moved
/// `RECURRENCE-ID` instances, and `RANGE=THISANDFUTURE` shifts. Scoping
/// to the component's series is what §9.7.1 asks: every test of a
/// comp-filter applies to one component instance, so another event's
/// overlap must not satisfy this event's time-range. The other component
/// types are judged on their own `DTSTART` / `DTEND` / `DUE` interval,
/// which is the extent of what this build interprets for them.
fn component_overlaps(
  component : @model.Component,
  range : TimeRange,
  view : ResourceView,
) -> Bool raise {
  if component.kind == "VEVENT" {
    let zones = temporal_zones(view)
    let series : Array[@model.Event] = []
    for root in view.roots {
      for child in root.children {
        if child.kind == "VEVENT" &&
          component_uid(child) == component_uid(component) {
          match child.event(zones~) {
            Some(event) => series.push(event)
            None => ()
          }
        }
      }
    }
    return events_overlap(series, range)
  }
  if component.property("RRULE") is Some(_) ||
    component.property("RDATE") is Some(_) ||
    component.property("RECURRENCE-ID") is Some(_) {
    raise CannotEvaluate(
      "recurring \{component.kind} time-range is not implemented",
    )
  }
  if component.kind == "VTODO" {
    return todo_overlaps(component, range, temporal_zones(view))
  }
  match component_interval(component, temporal_zones(view)) {
    Some(interval) =>
      interval_overlaps(
        interval.start,
        interval.finish,
        interval.all_day,
        range,
      )
    None => false
  }
}

///|
// RFC 4791 §9.9 VTODO table, transcribed in row order. It deliberately
// differs from VEVENT: duration finish and due-only end are inclusive.
fn todo_overlaps(
  component : @model.Component,
  range : TimeRange,
  zones : @model.ZoneTable,
) -> Bool raise {
  let start = component
    .property("DTSTART")
    .map(line => @model.parse_date_time(line, zones).instant_seconds())
  let duration = component
    .property("DURATION")
    .map(line => @model.parse_duration(line.value, line_no=0, raw=line.value))
  let due = component
    .property("DUE")
    .map(line => @model.parse_date_time(line, zones).instant_seconds())
  if duration is Some(_) && (start is None || due is Some(_)) {
    raise CannotEvaluate("invalid VTODO duration state")
  }
  match (start, duration, due) {
    (Some(s), Some(d), None) =>
      at_or_before(range.start, s + d) &&
      (after(range.end, s) || at_or_after(range.end, s + d))
    (Some(s), None, Some(d)) => {
      if d < s {
        raise CannotEvaluate("invalid VTODO due before start")
      }
      (before(range.start, d) || at_or_before(range.start, s)) &&
      (after(range.end, s) || at_or_after(range.end, d))
    }
    (Some(s), None, None) => at_or_before(range.start, s) && after(range.end, s)
    (None, None, Some(d)) => before(range.start, d) && at_or_after(range.end, d)
    _ => {
      let completed = component
        .property("COMPLETED")
        .map(line => @model.parse_date_time(line, zones).instant_seconds())
      let created = component
        .property("CREATED")
        .map(line => @model.parse_date_time(line, zones).instant_seconds())
      match (completed, created) {
        (Some(done), Some(c)) =>
          (at_or_before(range.start, c) || at_or_before(range.start, done)) &&
          (at_or_after(range.end, c) || at_or_after(range.end, done))
        (Some(done), None) =>
          at_or_before(range.start, done) && at_or_after(range.end, done)
        (None, Some(c)) => after(range.end, c)
        (None, None) => true
      }
    }
  }
}

///|
fn at_or_after(limit : Int64?, value : Int64) -> Bool {
  match limit {
    Some(bound) => bound >= value
    None => true
  }
}

///|
/// The UID of a component, read the way `event_from_component` reads it:
/// the unescaped text of the first `UID` property, "" when absent. A
/// component and the event parsed from it then compare equal on the same
/// string, which is how the series scope above finds its group.
fn component_uid(component : @model.Component) -> String {
  match component.property("UID") {
    Some(line) => @text.unescape_value(line.value)
    None => ""
  }
}

///|
/// Whether any occurrence of any series in this resource overlaps the range.
fn events_overlap(
  events : Array[@model.Event],
  range : TimeRange,
) -> Bool raise {
  let visited : Map[String, Unit] = Map([])
  for event in events {
    let uid = event.uid.unwrap_or("")
    if visited.contains(uid) {
      continue
    }
    visited[uid] = ()
    let group = events.filter(item => item.uid.unwrap_or("") == uid)
    if series_overlaps(group, range) {
      return true
    }
  }
  false
}

///|
/// Expand one UID's series far enough to answer a time range.
///
/// A witnessed overlap proves true. A negative result requires exhaustion
/// or an unshifted RRULE generation frontier covering the query end; far
/// RDATE values and output lengths cannot prove that intermediate slots were
/// visited. Overrides conservatively require exhaustion for a negative.
fn series_overlaps(
  events : Array[@model.Event],
  range : TimeRange,
) -> Bool raise {
  let mut limit = SERIES_INITIAL_LIMIT
  for ;; {
    let result = @rrule.expand_series_query(events, limit~)
    for occurrence in result.occurrences {
      if interval_overlaps(
          occurrence.start.instant_seconds(),
          occurrence.end.map(end => end.instant_seconds()),
          occurrence.start.all_day,
          range,
        ) {
        return true
      }
    }
    let covered = if result.has_overrides {
      false
    } else {
      match (range.end, result.generated_through) {
        (Some(bound), Some(frontier)) => frontier.instant_seconds() >= bound
        _ => false
      }
    }
    if result.exhausted || covered {
      return false
    }
    if result.budget_exceeded {
      raise CannotEvaluate(
        "recurrence period budget exhausted without proving coverage",
      )
    }
    if limit >= SERIES_LIMIT_CAP {
      raise CannotEvaluate(
        "recurrence query exceeded \{SERIES_LIMIT_CAP} instances without proving coverage",
      )
    }
    limit = if limit * 4 > SERIES_LIMIT_CAP {
      SERIES_LIMIT_CAP
    } else {
      limit * 4
    }
  }
}

///|
/// The `DTSTART` / `DTEND` / `DUE` interval of a component this build does
/// not expand. A `VTODO` with only a `DUE` is judged at its due instant.
/// `zones` is the resource's own resolved table, so a feed-declared
/// `TZID` resolves here exactly as it does on the VEVENT path.
fn component_interval(
  component : @model.Component,
  zones : @model.ZoneTable,
) -> Interval? raise {
  let dtstart = component
    .property("DTSTART")
    .bind(line => try_date(line, zones))
  let dtend = component.property("DTEND").bind(line => try_date(line, zones))
  let due = component.property("DUE").bind(line => try_date(line, zones))
  // Malformed duration is a checked failure, not a missing end.
  let duration : Int64? = component
    .property("DURATION")
    .bind(line => {
      Some(@model.parse_duration(line.value, line_no=0, raw=line.value))
    })
  match dtstart {
    Some(start) =>
      Some({
        start: start.instant_seconds(),
        finish: match dtend {
          Some(end) => Some(end.instant_seconds())
          None =>
            match due {
              Some(end) => Some(end.instant_seconds())
              None =>
                match duration {
                  Some(seconds) => Some(start.instant_seconds() + seconds)
                  None => None
                }
            }
        },
        all_day: start.all_day,
      })
    None =>
      match due {
        Some(end) =>
          Some({
            start: end.instant_seconds(),
            finish: None,
            all_day: end.all_day,
          })
        None => None
      }
  }
}

///|
/// Whether one property matches a prop-filter: every test it carries must
/// hold, and the filter matches when at least one occurrence of the property
/// satisfies them (RFC 4791 §9.7.2 allows a repeated property).
fn prop_matches(
  filter : PropFilter,
  component : @model.Component,
  view : ResourceView,
) -> Bool raise {
  let lines = component.properties_named(filter.name)
  if filter.is_not_defined {
    return lines.length() == 0
  }
  if lines.length() == 0 {
    return false
  }
  for line in lines {
    if prop_line_matches(filter, line, view) {
      return true
    }
  }
  false
}

///|
fn prop_line_matches(
  filter : PropFilter,
  line : @text.ContentLine,
  view : ResourceView,
) -> Bool raise {
  match filter.time_range {
    Some(range) =>
      match try_date(line, temporal_zones(view)) {
        Some(value) =>
          if !interval_overlaps(
              value.instant_seconds(),
              None,
              value.all_day,
              range,
            ) {
            return false
          }
        None => return false
      }
    None => ()
  }
  match filter.text_match {
    Some(matcher) =>
      // The wire value is escaped (`\,`, `\;`, `\n`); a client searches for
      // the text a human sees, so compare against the unescaped form.
      if !text_matches(matcher, @text.unescape_value(line.value)) {
        return false
      }
    None => ()
  }
  for param in filter.params {
    if !param_matches(param, line) {
      return false
    }
  }
  true
}

///|
fn param_matches(filter : ParamFilter, line : @text.ContentLine) -> Bool {
  let value = line.param(filter.name)
  if filter.is_not_defined {
    return value is None
  }
  match value {
    None => false
    Some(text) =>
      match filter.text_match {
        Some(matcher) => text_matches(matcher, text)
        None => true
      }
  }
}

///|
/// RFC 4791 §9.7.4 substring matching, honouring the collation and
/// `negate-condition`.
fn text_matches(matcher : TextMatch, value : String) -> Bool {
  let found = if matcher.collation.to_lower() == "i;octet" {
    value.view().find(matcher.text.view()) is Some(_)
  } else {
    value.view().to_lower().find(matcher.text.view().to_lower()) is Some(_)
  }
  if matcher.negate {
    !found
  } else {
    found
  }
}

///|
/// The RFC 4791 §9.9 overlap rule for one component interval.
///
/// The three branches are the three states the RFC enumerates: an interval
/// with an end is open at both comparisons, a `DATE-TIME` with no end is an
/// instant whose range start is inclusive, and a `DATE` with no end occupies
/// its whole day.
fn interval_overlaps(
  start : Int64,
  finish : Int64?,
  all_day : Bool,
  range : TimeRange,
) -> Bool {
  match finish {
    Some(end) => before(range.start, end) && after(range.end, start)
    None =>
      if all_day {
        before(range.start, start + DAY_SECONDS) && after(range.end, start)
      } else {
        at_or_before(range.start, start) && after(range.end, start)
      }
  }
}

///|
const DAY_SECONDS : Int64 = 86400

///|
fn before(limit : Int64?, value : Int64) -> Bool {
  match limit {
    Some(bound) => bound < value
    None => true
  }
}

///|
fn after(limit : Int64?, value : Int64) -> Bool {
  match limit {
    Some(bound) => bound > value
    None => true
  }
}

///|
fn at_or_before(limit : Int64?, value : Int64) -> Bool {
  match limit {
    Some(bound) => bound <= value
    None => true
  }
}

///|
/// Parse a property line as a date-time, treating a malformed value as "not
/// a date" rather than failing the whole report.
fn try_date(
  line : @text.ContentLine,
  zones : @model.ZoneTable,
) -> @model.IcalDateTime? raise {
  Some(@model.parse_date_time(line, zones))
}
