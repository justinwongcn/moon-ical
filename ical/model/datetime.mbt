///|
/// A parsed iCalendar date-time value (`DTSTART`, `DTEND`, `DUE`, `UNTIL`,
/// `EXDATE`, ...).
///
/// iCalendar writes *wall-clock* readings rather than instants, so the wall
/// time is kept next to the offset that says where it should be read:
///
/// - `DTSTART:20260908T013000Z` → `utc_offset = Some(0)`
/// - `DTSTART;TZID=Asia/Shanghai:20260908T093000` → `utc_offset = Some(28800)`
/// - `DTSTART:20260908T093000` → `utc_offset = None` (floating: the feed
///   declared no zone, so it means 09:30 wherever it is read)
/// - `DTSTART;VALUE=DATE:20260908` → `all_day = true`, wall time at midnight
///
/// `moonbitlang/x/time` supplies the calendar arithmetic; the offset stays a
/// plain `Int` instead of a `Zone` because named zones are resolved through a
/// fixed-offset table (see [`ZoneTable`] and seam S2 in
/// docs/upstream-seams.md).
pub struct IcalDateTime {
  wall : @time.PlainDateTime
  /// Seconds east of UTC; `None` means the value is floating.
  utc_offset : Int?
  /// The `TZID` / `Z` / absolute-offset spelling that produced `utc_offset`,
  /// kept for error messages and for writing a feed back out.
  zone_id : String
  all_day : Bool
} derive(Debug, Eq)

///|
/// Seconds since the Unix epoch for this value.
///
/// A floating value is treated as UTC so that floating and explicitly-zoned
/// times can still be sorted in one pass; the feed gave nothing better to go on.
pub fn IcalDateTime::instant_seconds(self : IcalDateTime) -> Int64 {
  self.wall.to_unix_second() - self.utc_offset.unwrap_or(0).to_int64()
}

///|
pub fn IcalDateTime::is_utc(self : IcalDateTime) -> Bool {
  self.utc_offset == Some(0)
}

///|
pub fn IcalDateTime::is_floating(self : IcalDateTime) -> Bool {
  match self.utc_offset {
    None => true
    Some(_) => false
  }
}

///|
/// The same clock reading as `self`, on another calendar day: the clock
/// time, UTC offset, zone spelling, and all-day flag all carry over
/// unchanged.
///
/// This is how a recurrence expansion moves a `DTSTART` through its
/// occurrences. The offset is deliberately frozen at `self`'s value: the
/// fixed-offset `ZoneTable` has no DST history (seam S2 in
/// docs/upstream-seams.md), so a series crossing a DST change keeps the
/// `DTSTART` offset rather than guessing — the boundary README documents
/// this. Raises if `date` is not a valid calendar day.
pub fn IcalDateTime::on_date(
  self : IcalDateTime,
  date : @time.PlainDate,
) -> IcalDateTime raise {
  {
    wall: @time.PlainDateTime::of(
      date.year(),
      date.month(),
      date.day(),
      hour=self.wall.hour(),
      minute=self.wall.minute(),
      second=self.wall.second(),
    ),
    utc_offset: self.utc_offset,
    zone_id: self.zone_id,
    all_day: self.all_day,
  }
}

///|
/// Shift this wall-clock value by an exact number of seconds while preserving
/// its zone spelling, fixed offset, and all-day marker.
pub fn IcalDateTime::shift_seconds(
  self : IcalDateTime,
  seconds : Int64,
) -> IcalDateTime raise {
  { ..self, wall: self.wall.add_seconds(seconds), }
}

///|
/// Negative when `self` happens before `other`, zero for the same instant,
/// positive afterwards. All-day values compare by their calendar day.
pub fn IcalDateTime::compare(self : IcalDateTime, other : IcalDateTime) -> Int {
  let a = self.instant_seconds()
  let b = other.instant_seconds()
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
pub impl Show for IcalDateTime with fn output(self, logger) {
  let day = "\{pad4(self.wall.year())}-\{pad2(self.wall.month())}-\{pad2(self.wall.day())}"
  if self.all_day {
    logger.write_string(day)
  } else {
    let clock = "\{pad2(self.wall.hour())}:\{pad2(self.wall.minute())}:\{pad2(self.wall.second())}"
    let suffix = match self.utc_offset {
      None => ""
      Some(0) => "Z"
      Some(seconds) => {
        let sign = if seconds < 0 { "-" } else { "+" }
        let abs = seconds.abs()
        "\{sign}\{pad2(abs / 3600)}:\{pad2((abs / 60) % 60)}"
      }
    }
    logger.write_string("\{day}T\{clock}\{suffix}")
  }
}

///|
/// Parse a `DTSTART` / `DTEND` / `DUE` property into an [`IcalDateTime`].
///
/// `zones` resolves a `TZID=` parameter; pass [`ZoneTable::with_builtin`] over
/// [`build_zone_table`] when reading a feed that ships its own `VTIMEZONE`. An
/// unresolvable `TZID` is an error rather than a silent fallback to UTC,
/// because guessing would move every event in that calendar by hours.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let line = @text.parse_content_line(
///     "DTSTART;TZID=Asia/Shanghai:20260908T093000", 1,
///   )
///   let dt = @model.parse_date_time(line, @model.ZoneTable::builtin_common())
///   assert_eq(dt.utc_offset, Some(8 * 3600))
///   assert_eq(dt.to_string(), "2026-09-08T09:30:00+08:00")
/// }
/// ```
pub fn parse_date_time(
  line : @text.ContentLine,
  zones : ZoneTable,
  line_no? : Int = 0,
) -> IcalDateTime raise {
  let value_is_date = match line.param("VALUE") {
    Some(v) => String::to_upper(v) == "DATE"
    None => false
  }
  parse_value(
    line.value,
    tzid=line.param("TZID"),
    value_is_date,
    zones,
    line_no,
  )
}

///|
/// Parse a bare date-time text, as found in `RRULE`'s `UNTIL=` and in an
/// `EXDATE` list, where no property carries a `TZID`.
///
/// RFC 5545 requires `UNTIL` to be UTC when `DTSTART` is UTC, so a trailing
/// `Z` is read here; anything else is floating, exactly like a `DTSTART`
/// written without a designator.
pub fn parse_single_date_time(
  text : String,
  zones : ZoneTable,
  line_no? : Int = 0,
) -> IcalDateTime raise {
  parse_value(text, tzid=None, false, zones, line_no)
}

///|
/// Parse one date-time value together with the context its property line
/// carried. `EXDATE` and `RDATE` pack several comma-separated values into one
/// line, and the line's `TZID=` / `VALUE=DATE` parameters apply to every one
/// of them — split the values, pass each through here with the same context.
pub fn parse_date_time_value(
  raw : String,
  zones : ZoneTable,
  tzid? : String? = None,
  value_is_date? : Bool = false,
  line_no? : Int = 0,
) -> IcalDateTime raise {
  parse_value(raw, tzid~, value_is_date, zones, line_no)
}

///|
/// The shared body of both entry points: read one iCalendar date-time value.
fn parse_value(
  raw : String,
  tzid~ : String?,
  value_is_date : Bool,
  zones : ZoneTable,
  line_no : Int,
) -> IcalDateTime raise {
  let cs = raw.to_array()
  let n = cs.length()
  // An 8-digit value is a DATE. Anything longer needs the T separator.
  if n == 8 {
    let (y, m, d) = read_date(cs, line_no, raw)
    IcalDateTime::{
      wall: @time.PlainDateTime::of(y, m, d),
      utc_offset: None,
      zone_id: "",
      all_day: true,
    }
  } else if n < 15 || cs[8] != 'T' {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="malformed date-time: \{raw}",
    )
  } else {
    let (y, m, d) = read_date(cs, line_no, raw)
    let (hh, mm, ss) = read_time(cs, line_no, raw)
    let wall = @time.PlainDateTime::of(y, m, d, hour=hh, minute=mm, second=ss)
    // `YYYYMMDDThhmmss` is 15 chars; anything past that is
    // the designator: nothing, `Z`, or `+hhmm`/`-hhmm`.
    let tail = n - 15
    if tail == 0 {
      // No designator: a TZID parameter gave the zone, or the value floats.
      match tzid {
        Some(id) =>
          match zones.lookup(id) {
            Some(seconds) =>
              IcalDateTime::{
                wall,
                utc_offset: Some(seconds),
                zone_id: id,
                all_day: value_is_date,
              }
            None =>
              raise @text.ParseError::BadLine(
                line_no~,
                line=raw,
                message="unknown TZID: \{id}",
              )
          }
        None =>
          IcalDateTime::{
            wall,
            utc_offset: None,
            zone_id: "",
            all_day: value_is_date,
          }
      }
    } else if tail == 1 && cs[15] == 'Z' {
      IcalDateTime::{
        wall,
        utc_offset: Some(0),
        zone_id: "Z",
        all_day: value_is_date,
      }
    } else if tail == 5 && (cs[15] == '+' || cs[15] == '-') {
      let text = String::from_array(cs[15:n])
      IcalDateTime::{
        wall,
        utc_offset: Some(parse_utc_offset(text, line_no~, raw~)),
        zone_id: text,
        all_day: value_is_date,
      }
    } else {
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed date-time designator in: \{raw}",
      )
    }
  }
}

///|
/// YYYYMMDD from positions 0..8 of a value's chars.
fn read_date(
  cs : Array[Char],
  line_no : Int,
  raw : String,
) -> (Int, Int, Int) raise {
  match (digits(cs, 0, 4), digits(cs, 4, 2), digits(cs, 6, 2)) {
    (Some(y), Some(m), Some(d)) => (y, m, d)
    _ =>
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed date part in: \{raw}",
      )
  }
}

///|
/// THHMMSS from positions 9..14 of a value's chars.
fn read_time(
  cs : Array[Char],
  line_no : Int,
  raw : String,
) -> (Int, Int, Int) raise {
  match (digits(cs, 9, 2), digits(cs, 11, 2), digits(cs, 13, 2)) {
    (Some(h), Some(mi), Some(s)) => (h, mi, s)
    _ =>
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed time part in: \{raw}",
      )
  }
}

///|
/// Read `width` decimal digits starting at `from`, or `None` when the range is
/// out of bounds or holds a non-digit.
fn digits(cs : Array[Char], from : Int, width : Int) -> Int? {
  let end = from + width
  if from < 0 || end > cs.length() {
    None
  } else {
    let mut acc = 0
    let mut i = from
    let mut done = true
    while i < end {
      let d = cs[i].to_int() - '0'.to_int()
      if d < 0 || d > 9 {
        done = false
        i = end
      } else {
        acc = acc * 10 + d
        i = i + 1
      }
    }
    if done {
      Some(acc)
    } else {
      None
    }
  }
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : Int) -> String {
  let s = n.to_string()
  if s.length() >= 4 {
    s
  } else {
    // Keep the last four digits of the zero-padded text.
    let chars = ("0000" + s).to_array()
    let k = chars.length()
    String::from_array(chars[k - 4:k])
  }
}
