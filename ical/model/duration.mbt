///|
/// Parse an iCalendar DURATION value (RFC 5545 §3.3.6) into its total
/// seconds. The grammar: an optional sign, `P`, then either `nW` alone,
/// or `nD` optionally followed by `T` and a run of `nH`/`nM`/`nS` in
/// that exact order — each component at most once, each with at least
/// one digit. Raises [`@text.ParseError`] with the offending text on
/// anything else.
///
/// Day and week components count as their exact 86400 / 604800 seconds.
/// Nominal durations would drift across DST changes, but this project's
/// fixed-offset `ZoneTable` has no DST history (see [`ZoneTable`] and
/// seam S2 in docs/upstream-seams.md), so nominal and exact coincide by
/// the same boundary that freezes every other wall-clock computation.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   assert_eq(@model.parse_duration("PT1H30M", line_no=1, raw="PT1H30M"), 5400)
///   assert_eq(@model.parse_duration("-P1D", line_no=1, raw="-P1D"), -86400)
/// }
/// ```
pub fn parse_duration(
  text : String,
  line_no~ : Int32,
  raw~ : String,
) -> Int64 raise {
  let v = text.view()
  let n = v.length()
  let mut i = 0
  let mut sign : Int64 = 1
  if i < n && (v[i] == '+' || v[i] == '-') {
    if v[i] == '-' {
      sign = -1
    }
    i = i + 1
  }
  // The designator and at least one duration component must follow.
  if i >= n || v[i] != 'P' {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="malformed duration, expected P: \{text}",
    )
  }
  i = i + 1
  // A strict walk of the RFC's component order. Stages name the last
  // part seen: 0 the `P`, 1 a day, 2 the `T`, 3 an hour, 4 a minute,
  // 5 a second, 6 a week (which may not be followed by anything).
  let mut stage = 0
  let mut total : Int64 = 0
  let mut seen = 0
  // Set when the T designator is consumed, cleared by the first H/M/S
  // after it — a T that names no component ("P1DT") is not a grammar
  // walk the RFC allows.
  let mut bare_t = false
  while i < n {
    // The time designator carries no number of its own: it may stand
    // directly after P or a day component, and only opens the H/M/S run.
    if v[i] == 'T' && (stage == 0 || stage == 1) {
      stage = 2
      bare_t = true
      i = i + 1
      continue
    }
    let (count, next) : (Int64, Int32) = match digits_of(v, i) {
      Some(pair) => pair
      None =>
        raise @text.ParseError::BadLine(
          line_no~,
          line=raw,
          message="malformed duration, expected a number: \{text}",
        )
    }
    guard next < n else {
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="malformed duration, number without a designator: \{text}",
      )
    }
    let unit = v[next]
    let seconds : Int64 = match (stage, unit) {
      (0, 'D') => {
        stage = 1
        86_400
      }
      (0, 'W') => {
        stage = 6
        604_800
      }
      (2 | 3, 'H') => {
        stage = 3
        bare_t = false
        3_600
      }
      (2 | 3 | 4, 'M') => {
        stage = 4
        bare_t = false
        60
      }
      (2 | 4 | 5, 'S') => {
        stage = 5
        bare_t = false
        1
      }
      _ =>
        raise @text.ParseError::BadLine(
          line_no~,
          line=raw,
          message="malformed duration designator or order: \{text}",
        )
    }
    i = next + 1
    if seconds > 0 {
      seen = seen + 1
      total = total + count * seconds
    }
  }
  if bare_t {
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="malformed duration, no components after T: \{text}",
    )
  }
  if seen == 0 {
    // "P" and "PT" — the designators named no component at all.
    raise @text.ParseError::BadLine(
      line_no~,
      line=raw,
      message="malformed duration, no components: \{text}",
    )
  }
  sign * total
}

///|
/// The run of decimal digits starting at `from`, as its value and the
/// offset just past the run. `None` when the first character is not a
/// digit (a leading zero run is fine; RFC 5545 says 1*DIGIT).
fn digits_of(v : StringView, from : Int32) -> (Int64, Int32)? {
  let n = v.length()
  let c = v[from]
  if !(c is ('0'..<='9')) {
    return None
  }
  let mut acc : Int64 = 0
  let mut i = from
  while i < n {
    let d = v[i]
    if !(d is ('0'..<='9')) {
      break
    }
    acc = acc * 10 + (d.to_int() - '0'.to_int()).to_int64()
    i = i + 1
  }
  Some((acc, i))
}
