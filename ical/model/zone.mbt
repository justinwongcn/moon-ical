///|
/// A zone-name to UTC-offset table used to resolve `TZID=` parameters.
///
/// Offsets are seconds east of UTC. iCalendar defines `TZID` case-sensitively,
/// but real feeds are sloppy (Google emits `Asia/Shanghai`, some Outlook
/// exports `ASIA/SHANGHAI`), so keys are normalised before comparison.
///
/// The table holds *fixed* offsets only. Honouring a named zone's
/// daylight-saving history per date needs an IANA time-zone database, which
/// `moonbitlang/x/time` does not ship and no mooncakes package provides — see
/// seam S2 in docs/upstream-seams.md. The practical consequence is stated in
/// README: a February and a July event in `Europe/Berlin` resolve to the same
/// offset here (+01:00), while a feed that embeds its own `VTIMEZONE` gets the
/// offset its author actually declared.
pub struct ZoneTable {
  entries : Array[(String, Int)]
} derive(Debug)

///|
/// An empty table: every `TZID` fails to resolve until zones are added.
pub fn ZoneTable::empty() -> ZoneTable {
  { entries: [], }
}

///|
/// Offsets for the named zones that actually show up in the feeds we test
/// against. Standard-time values only, on purpose (see the `ZoneTable` doc).
pub fn ZoneTable::builtin_common() -> ZoneTable {
  let zones : Array[(String, Int)] = [
    ("UTC", 0),
    ("GMT", 0),
    ("Z", 0),
    ("ASIA/SHANGHAI", offset(8, 0)),
    ("ASIA/CHONGQING", offset(8, 0)),
    ("ASIA/HONG_KONG", offset(8, 0)),
    ("ASIA/TAIPEI", offset(8, 0)),
    ("ASIA/SINGAPORE", offset(8, 0)),
    ("ASIA/URUMQI", offset(6, 0)),
    ("ASIA/TOKYO", offset(9, 0)),
    ("ASIA/SEOUL", offset(9, 0)),
    ("ASIA/KOLKATA", offset(5, 30)),
    ("ASIA/DUBAI", offset(4, 0)),
    ("AUSTRALIA/SYDNEY", offset(10, 0)),
    ("EUROPE/LONDON", offset(0, 0)),
    ("EUROPE/BERLIN", offset(1, 0)),
    ("EUROPE/PARIS", offset(1, 0)),
    ("EUROPE/BELGRADE", offset(1, 0)),
    ("EUROPE/MOSCOW", offset(3, 0)),
    ("AMERICA/NEW_YORK", offset(-5, 0)),
    ("AMERICA/CHICAGO", offset(-6, 0)),
    ("AMERICA/DENVER", offset(-7, 0)),
    ("AMERICA/LOS_ANGELES", offset(-8, 0)),
    ("AMERICA/SAO_PAULO", offset(-3, 0)),
    ("AFRICA/JOHANNESBURG", offset(2, 0)),
  ]
  { entries: zones, }
}

///|
/// Seconds east of UTC from an hour/minute pair, where a negative hour makes
/// the whole offset negative (`offset(-5, 30)` is `-0530`, not `-0430`).
fn offset(hours : Int, minutes : Int) -> Int {
  let sign = if hours < 0 { -1 } else { 1 }
  sign * (hours.abs() * 3600 + minutes.abs() * 60)
}

///|
/// Normalise a zone name for table keys and lookups.
fn normalize_zone_id(tzid : String) -> String {
  let mut trimmed = tzid
  while trimmed.length() > 0 && (trimmed[0] == ' ' || trimmed[0] == '\t') {
    trimmed = String::from_array(trimmed.to_array()[1:])
  }
  let cs = trimmed.to_array()
  let mut last = cs.length()
  while last > 0 && (cs[last - 1] == ' ' || cs[last - 1] == '\t') {
    last = last - 1
  }
  String::to_upper(String::from_array(cs[0:last]))
}

///|
/// Record a zone. Later inserts win, which is what lets a feed's own
/// `VTIMEZONE` override a built-in guess for the same name.
pub fn ZoneTable::insert(
  self : ZoneTable,
  tzid : String,
  seconds : Int,
) -> Unit {
  self.entries.push((normalize_zone_id(tzid), seconds))
}

///|
/// The built-in zones, overridden by anything the feed declared itself. This is
/// the table `parse_date_time` wants: a feed that ships a `VTIMEZONE` knows
/// better than our guess, and everything else still resolves.
pub fn ZoneTable::with_builtin(feed : ZoneTable) -> ZoneTable {
  let table = ZoneTable::builtin_common()
  for pair in feed.entries {
    table.entries.push(pair)
  }
  table
}

///|
/// Look a zone up, case-insensitively; the most recently inserted match wins.
pub fn ZoneTable::lookup(self : ZoneTable, tzid : String) -> Int? {
  let key = normalize_zone_id(tzid)
  let mut found : Int? = None
  for pair in self.entries {
    let (name, seconds) = pair
    if name == key {
      found = Some(seconds)
    }
  }
  found
}

///|
/// Parse an iCalendar UTC-offset value: `+0800`, `-0500`, `+0530`, or a bare
/// `+08`. Raises [`ParseError`] on anything else, because a half-read offset
/// silently shifts every event in a calendar.
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
  line_no~ : Int,
  raw~ : String,
) -> Int raise {
  let cs = text.to_array()
  let n = cs.length()
  if n < 3 {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="UTC offset too short: \{text}",
    )
  }
  let sign = if cs[0] == '-' {
    -1
  } else if cs[0] == '+' {
    1
  } else {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="UTC offset needs a sign: \{text}",
    )
  }
  let hours = digits(cs, 1, 2)
  let minutes = if n == 5 { digits(cs, 3, 2) } else { Some(0) }
  match (hours, minutes) {
    (Some(h), Some(m)) => sign * (h * 3600 + m * 60)
    _ =>
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed UTC offset: \{text}",
      )
  }
}

///|
/// Collect `TZID -> TZOFFSETTO` from a feed's own `VTIMEZONE` components, so a
/// private zone name (`/google.com/ntp/Asia/Shanghai`, `China Standard Time`)
/// resolves without an IANA database.
///
/// Only the `STANDARD` sub-component is read, and an offset that will not
/// parse is skipped rather than aborting the whole feed: one broken VTIMEZONE
/// should not hide the events that reference it.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let roots = @model.parse_components([
///     "BEGIN:VCALENDAR", "BEGIN:VTIMEZONE", "TZID:MY-ZONE", "BEGIN:STANDARD", "TZOFFSETTO:+0930",
///     "END:STANDARD", "END:VTIMEZONE", "END:VCALENDAR",
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
  match vtz.property("TZID") {
    None => ()
    Some(tzid) =>
      for child in vtz.children {
        if child.kind == "STANDARD" {
          match child.property("TZOFFSETTO") {
            None => ()
            Some(offset_line) => {
              let value = offset_line.value
              let parsed = Some(parse_utc_offset(value, line_no=0, raw=value)) catch {
                _ => None
              }
              match parsed {
                Some(seconds) => table.insert(tzid.value, seconds)
                None => ()
              }
            }
          }
        }
      }
  }
}
