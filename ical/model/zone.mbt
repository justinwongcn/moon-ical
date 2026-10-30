///|
/// A zone-name to UTC-offset table used to resolve `TZID=` parameters.
///
/// Offsets are seconds east of UTC. iCalendar defines `TZID` case-sensitively,
/// but real feeds are sloppy (Google emits `Asia/Shanghai`, some Outlook
/// exports `ASIA/SHANGHAI`), so keys are normalised before comparison.
///
/// Only explicit fixed bindings are usable: UTC aliases, caller inserts, or
/// a provably fixed VTIMEZONE. Regional names are not guessed. Unsupported
/// feed declarations are retained as rejections and shadow default bindings.
pub struct ZoneTable {
  entries : Map[String, Int32]
  rejected : Map[String, String]
} derive(Debug)

///|
pub extend ZoneTable with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// An empty table: every `TZID` fails to resolve until zones are added.
pub fn ZoneTable::empty() -> ZoneTable {
  { entries: Map([]), rejected: Map([]), }
}

///|
/// Intrinsically fixed UTC aliases only. Regional names need an explicit
/// caller binding or a provably fixed feed declaration.
pub fn ZoneTable::builtin_common() -> ZoneTable {
  let zones : Map[String, Int32] = { "UTC": 0, "GMT": 0, "Z": 0 }
  { entries: zones, rejected: Map([]), }
}

///|
/// Normalise a zone name for table keys and lookups.
fn normalize_zone_id(tzid : String) -> String {
  tzid.view().trim(chars=" \t".view()).to_upper().to_owned()
}

///|
/// Explicitly bind a fixed offset. Later caller inserts win and remove a
/// prior rejection. This is an assertion by the caller, not IANA resolution.
pub fn ZoneTable::insert(
  self : ZoneTable,
  tzid : String,
  seconds : Int32,
) -> Unit {
  let key = normalize_zone_id(tzid)
  self.entries[key] = seconds
  self.rejected.remove(key)
}

///|
/// UTC defaults overridden by feed declarations, including rejections.
/// A malformed same-name declaration must not fall back to a default.
pub fn ZoneTable::with_builtin(feed : ZoneTable) -> ZoneTable {
  let table = ZoneTable::builtin_common()
  for name, seconds in feed.entries {
    table.entries[name] = seconds
  }
  for name, reason in feed.rejected {
    table.entries.remove(name)
    table.rejected[name] = reason
  }
  table
}

///|
/// Look a zone up, case-insensitively; the most recently inserted match wins.
pub fn ZoneTable::lookup(self : ZoneTable, tzid : String) -> Int32? {
  self.entries.get(normalize_zone_id(tzid))
}

///|
/// Parse an iCalendar UTC-offset value (RFC 5545 §3.3.14): `+0800`,
/// `-0500`, `+0530`, `+053030`, or a bare `+08` (a deliberate lenience —
/// the RFC grammar requires the minutes). Raises [`ParseError`] on
/// anything else: an offset whose shape or components are not read whole
/// would silently shift every event in a calendar, which is how the
/// pre-S12 half-read of `+05:30` lost half an hour.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   assert_eq(
///     @model.parse_utc_offset("+0530", line_no=1, raw="+0530"),
///     5 * 3600 + 30 * 60,
///   )
///   assert_eq(
///     @model.parse_utc_offset("-0800", line_no=1, raw="-0800"),
///     -(8 * 3600),
///   )
/// }
/// ```
pub fn parse_utc_offset(
  text : String,
  line_no~ : Int32,
  raw~ : String,
) -> Int32 raise {
  let v = text.view()
  let n = v.length()
  // Sign, two-digit hour, optional two-digit minute, optional two-digit
  // second — and nothing else. The exact length is the whole check: a
  // colon form or a stray tail used to be read by its first five
  // characters with the rest silently dropped.
  if n != 3 && n != 5 && n != 7 {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="UTC offset must be +hh, +hhmm, or +hhmmss: \{text}",
    )
  }
  let sign = if v[0] == '-' {
    -1
  } else if v[0] == '+' {
    1
  } else {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="UTC offset needs a sign: \{text}",
    )
  }
  let hours = digits(v, 1, 2)
  let minutes = if n >= 5 { digits(v, 3, 2) } else { Some(0) }
  let seconds = if n == 7 { digits(v, 5, 2) } else { Some(0) }
  match (hours, minutes, seconds) {
    (Some(h), Some(m), Some(s)) =>
      // RFC 5545 §3.3.14 bounds every component: hour at 23, minute and
      // second at 59. An hour past 23 is not an offset any zone declares;
      // accepting it would shift a whole calendar by imaginary hours.
      if h > 23 || m > 59 || s > 59 {
        raise @text.ParseError::BadLine(
          line_no~,
          line=raw,
          message="UTC offset component out of range: \{text}",
        )
      } else {
        sign * (h * 3600 + m * 60 + s)
      }
    _ =>
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed UTC offset: \{text}",
      )
  }
}

///|
/// Collect provably fixed feed declarations without interpreting dynamic
/// transitions. Invalid or unsupported declarations shadow defaults and
/// fail only when a date property references their TZID. A fixed STANDARD
/// has a local DTSTART and equal FROM/TO offsets, with no transition rules.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let roots = @model.parse_components([
///     "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:MY-ZONE", "BEGIN:STANDARD", "DTSTART:19700101T000000",
///     "TZOFFSETFROM:+0930", "TZOFFSETTO:+0930", "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
///   ])
///   let table = @model.build_zone_table(roots)
///   assert_eq(table.lookup("my-zone"), Some(9 * 3600 + 30 * 60))
/// }
/// ```
pub fn build_zone_table(roots : Array[Component]) -> ZoneTable {
  let table = ZoneTable::empty()
  for root in roots {
    for child in root.children {
      if child.kind == "VTIMEZONE" {
        register_vtimezone(table, child)
      }
    }
  }
  table
}

///|
fn register_vtimezone(table : ZoneTable, vtz : Component) -> Unit {
  let ids = vtz.properties_named("TZID")
  if ids.length() != 1 {
    for id in ids {
      let key = normalize_zone_id(id.value)
      table.entries.remove(key)
      table.rejected[key] = "VTIMEZONE has duplicate TZID properties"
    }
    return
  }
  let tzid = ids[0]
  let key = normalize_zone_id(tzid.value)
  let fixed = fixed_vtimezone(vtz) catch { _ => None }
  // Duplicate definitions cannot establish an unambiguous fixed binding.
  if table.entries.contains(key) || table.rejected.contains(key) {
    table.entries.remove(key)
    table.rejected[key] = "conflicting VTIMEZONE declarations"
  } else {
    match fixed {
      Some(seconds) => table.insert(key, seconds)
      None => table.rejected[key] = "VTIMEZONE is dynamic or not provably fixed"
    }
  }
}

///|
/// Why a feed declaration cannot be used as a fixed binding, if present.
pub fn ZoneTable::rejection_reason(self : ZoneTable, tzid : String) -> String? {
  self.rejected.get(normalize_zone_id(tzid))
}

///|
fn fixed_vtimezone(vtz : Component) -> Int32? raise {
  if vtz.properties_named("TZID").length() != 1 {
    return None
  }
  let mut fixed : Int32? = None
  let mut seen = false
  for child in vtz.children {
    if child.kind == "DAYLIGHT" {
      return None
    }
    if child.kind != "STANDARD" {
      return None
    }
    seen = true
    for name in ["DTSTART", "TZOFFSETFROM", "TZOFFSETTO"] {
      if child.properties_named(name).length() != 1 {
        return None
      }
    }
    // Transition recurrence machinery is outside the fixed subset.
    if child.properties_named("RRULE").length() > 0 ||
      child.properties_named("RDATE").length() > 0 {
      return None
    }
    let start = parse_date_time(
      child.property("DTSTART").unwrap(),
      ZoneTable::empty(),
    )
    if start.all_day || !start.is_floating() {
      return None
    }
    let from = child.property("TZOFFSETFROM").unwrap().value
    let to = child.property("TZOFFSETTO").unwrap().value
    let from_seconds = parse_utc_offset(from, line_no=0, raw=from)
    let seconds = parse_utc_offset(to, line_no=0, raw=to)
    if from_seconds != seconds {
      return None
    }
    match fixed {
      Some(previous) => if previous != seconds { return None }
      None => fixed = Some(seconds)
    }
  }
  if seen {
    fixed
  } else {
    None
  }
}
