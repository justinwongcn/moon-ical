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
    Some(top) => { root: top, }
    None =>
      raise FilterError::InvalidFilter(
        message="CALDAV:filter without a comp-filter",
      )
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
    raise FilterError::UnsupportedFilter(
      element="<C:text-match collation=\"\{collation}\"/>",
    )
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
/// The ceiling the adaptive expansion stops doubling at. A rule that still
/// has not reached the range by here is far denser than any real calendar.
const SERIES_LIMIT_CAP : Int32 = 4096

///|
/// The component tree and typed events of one calendar object resource.
priv struct ResourceView {
  roots : Array[@model.Component]
  events : Array[@model.Event]
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
/// A resource that cannot be parsed does not match: the filter is a search,
/// and an unreadable resource cannot be shown to contain a match.
pub fn Filter::matches(self : Filter, calendar_data : String) -> Bool {
  let view = resource_view(calendar_data)
  comp_matches(self.root, view.roots, view)
}

///|
fn resource_view(calendar_data : String) -> ResourceView {
  let roots : Array[@model.Component] = @model.parse_calendar(calendar_data) catch {
    _ => []
  }
  let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  let events : Array[@model.Event] = []
  for root in roots {
    let parsed : Array[@model.Event]? = Some(root.events(zones~)) catch {
      _ => None
    }
    match parsed {
      Some(found) =>
        for event in found {
          events.push(event)
        }
      None => ()
    }
  }
  { roots, events, }
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
) -> Bool {
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
) -> Bool {
  match filter.time_range {
    Some(range) =>
      if !component_overlaps(component, range, view) {
        return false
      }
    None => ()
  }
  for child in filter.comps {
    if !comp_matches(child, component.children, view) {
      return false
    }
  }
  for prop in filter.props {
    if !prop_matches(prop, component) {
      return false
    }
  }
  true
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
) -> Bool {
  if component.kind == "VEVENT" {
    let series = view.events.filter(event => {
      event.uid.unwrap_or("") == component_uid(component)
    })
    return events_overlap(series, range)
  }
  match component_interval(component) {
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
fn events_overlap(events : Array[@model.Event], range : TimeRange) -> Bool {
  let visited : Map[String, Unit] = Map([])
  for event in events {
    let uid = event.uid.unwrap_or("")
    if visited.contains(uid) {
      continue
    }
    visited[uid] = ()
    let group = events.filter(item => item.uid.unwrap_or("") == uid)
    let occurrences = series_occurrences(group, range)
    if occurrences.length() == 0 {
      // No series to expand — a bare event with no RRULE, or a rule this
      // build cannot expand. Its own dates still say whether it overlaps.
      match master_interval(group) {
        Some(interval) =>
          if interval_overlaps(
              interval.start,
              interval.finish,
              interval.all_day,
              range,
            ) {
            return true
          }
        None => ()
      }
    } else {
      for occurrence in occurrences {
        let start = occurrence.start.instant_seconds()
        let finish = occurrence.end.map(end => end.instant_seconds())
        if interval_overlaps(start, finish, occurrence.start.all_day, range) {
          return true
        }
      }
    }
  }
  false
}

///|
/// Expand one UID's series far enough to answer a time range.
///
/// [`@rrule.expand_series`] takes a limit because a rule may be unbounded, so
/// the limit is doubled until the series either runs out or reaches the
/// bound the range cares about. Without this a long series would be judged
/// only on its first `limit` instances and a match past them would be lost.
fn series_occurrences(
  events : Array[@model.Event],
  range : TimeRange,
) -> Array[@rrule.Occurrence] {
  let bound = match range.end {
    Some(end) => Some(end)
    None => range.start
  }
  let mut limit = SERIES_INITIAL_LIMIT
  let mut out : Array[@rrule.Occurrence] = []
  for ;; {
    let parsed : Array[@rrule.Occurrence]? = Some(
      @rrule.expand_series(events, limit~),
    ) catch {
      _ => None
    }
    out = match parsed {
      Some(found) => found
      None => []
    }
    let exhausted = out.length() < limit
    let covered = match bound {
      None => true
      Some(target) =>
        out.length() > 0 &&
        out[out.length() - 1].start.instant_seconds() >= target
    }
    if exhausted || covered || limit >= SERIES_LIMIT_CAP {
      break
    }
    limit = limit * 4
  }
  out
}

///|
/// The interval of the master event of a group — the one without a
/// `RECURRENCE-ID`, which is the series definition rather than an override.
fn master_interval(events : Array[@model.Event]) -> Interval? {
  for event in events {
    if event.recurrence_id is None {
      match event.dtstart {
        Some(start) =>
          return Some({
            start: start.instant_seconds(),
            finish: event.dtend.map(end => end.instant_seconds()),
            all_day: start.all_day,
          })
        None => ()
      }
    }
  }
  None
}

///|
/// The `DTSTART` / `DTEND` / `DUE` interval of a component this build does
/// not expand. A `VTODO` with only a `DUE` is judged at its due instant.
fn component_interval(component : @model.Component) -> Interval? {
  let zones = @model.ZoneTable::builtin_common()
  let dtstart = component
    .property("DTSTART")
    .bind(line => try_date(line, zones))
  let dtend = component.property("DTEND").bind(line => try_date(line, zones))
  let due = component.property("DUE").bind(line => try_date(line, zones))
  match dtstart {
    Some(start) =>
      Some({
        start: start.instant_seconds(),
        finish: match dtend {
          Some(end) => Some(end.instant_seconds())
          None =>
            match due {
              Some(end) => Some(end.instant_seconds())
              None => None
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
fn prop_matches(filter : PropFilter, component : @model.Component) -> Bool {
  let lines = component.properties_named(filter.name)
  if filter.is_not_defined {
    return lines.length() == 0
  }
  if lines.length() == 0 {
    return false
  }
  for line in lines {
    if prop_line_matches(filter, line) {
      return true
    }
  }
  false
}

///|
fn prop_line_matches(filter : PropFilter, line : @text.ContentLine) -> Bool {
  match filter.time_range {
    Some(range) => {
      let zones = @model.ZoneTable::builtin_common()
      match try_date(line, zones) {
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
) -> @model.IcalDateTime? {
  Some(@model.parse_date_time(line, zones)) catch {
    _ => None
  }
}
