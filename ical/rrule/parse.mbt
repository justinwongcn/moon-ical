///|
/// Parse an `RRULE` property value (RFC 5545 §3.3.10) into a [`Rule`].
///
/// This is the syntax layer only. Every clause inside the project's support
/// boundary (docs/development.html §08) is parsed into a typed field; the
/// clauses outside it — the `HOURLY` / `MINUTELY` / `SECONDLY` frequencies
/// and the `BYWEEKNO` / `BYYEARDAY` / `BYHOUR` / `BYMINUTE` / `BYSECOND`
/// clauses — are rejected with an explicit [`@text.ParseError::BadRule`]
/// rather than silently dropped.
///
/// The `RRULE:` property-name prefix may be present or absent, so both a
/// bare property value and a whole content line parse. Clause names and
/// values match case-insensitively (real feeds mix cases). Each clause may
/// appear at most once, and `FREQ` must appear exactly once.
///
/// Two deliberate deviations from the RFC grammar, in the direction of
/// tolerating real feeds: `FREQ` is not required to be the first clause,
/// and no `DTSTART`-dependent semantic checks (COUNT + UNTIL exclusivity,
/// UNTIL value-type agreement) happen here — those belong to expansion
/// (S3), which is the only place that knows the `DTSTART`.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let rule = @rrule.parse_rule("FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10")
///   assert_true(rule.freq is @rrule.Freq::Weekly)
///   assert_eq(rule.count, Some(10))
///   assert_eq(rule.byday.length(), 2)
/// }
/// ```
pub fn parse_rule(rule : String) -> Rule raise {
  let body = without_rrule_prefix(rule)
  let mut freq : Freq? = None
  let mut interval : Int? = None
  let mut count : Int? = None
  let mut until : @model.IcalDateTime? = None
  let mut byday : Array[Byday] = []
  let mut bymonthday : Array[Int] = []
  let mut bymonth : Array[Int] = []
  let mut bysetpos : Array[Int] = []
  let mut wkst : @time.Weekday? = None
  let seen : Array[String] = []
  for part in split_on(body, ';') {
    if part == "" {
      raise @text.ParseError::BadRule(rule~, message="empty rule part")
    }
    let (name, value) = match split_at_equals(part) {
      Some(pair) => pair
      None =>
        raise @text.ParseError::BadRule(
          rule~,
          message="malformed rule part: \{part}",
        )
    }
    if name == "" {
      raise @text.ParseError::BadRule(
        rule~,
        message="malformed rule part: \{part}",
      )
    }
    let key = String::to_upper(name)
    if has_clause(seen, key) {
      raise @text.ParseError::BadRule(rule~, message="duplicate clause: \{key}")
    }
    seen.push(key)
    if key == "FREQ" {
      freq = Some(parse_freq(value, rule))
    } else if key == "INTERVAL" {
      interval = Some(positive_clause("INTERVAL", value, rule))
    } else if key == "COUNT" {
      count = Some(positive_clause("COUNT", value, rule))
    } else if key == "UNTIL" {
      until = Some(parse_until(value, rule))
    } else if key == "BYDAY" {
      byday = parse_byday_list(value, rule)
    } else if key == "BYMONTHDAY" {
      bymonthday = parse_int_list(value, "BYMONTHDAY", rule, 31, true)
    } else if key == "BYMONTH" {
      bymonth = parse_int_list(value, "BYMONTH", rule, 12, false)
    } else if key == "BYSETPOS" {
      bysetpos = parse_int_list(value, "BYSETPOS", rule, 366, true)
    } else if key == "WKST" {
      wkst = Some(parse_weekday_code(value, rule))
    } else if key == "BYWEEKNO" ||
      key == "BYYEARDAY" ||
      key == "BYHOUR" ||
      key == "BYMINUTE" ||
      key == "BYSECOND" {
      raise @text.ParseError::BadRule(
        rule~,
        message="unsupported RRULE clause: \{key}",
      )
    } else {
      raise @text.ParseError::BadRule(
        rule~,
        message="unknown RRULE clause: \{key}",
      )
    }
  }
  match freq {
    Some(f) =>
      {
        freq: f,
        interval: interval.unwrap_or(1),
        count,
        until,
        byday,
        bymonthday,
        bymonth,
        bysetpos,
        wkst: wkst.unwrap_or(@time.Weekday::Monday),
      }
    None =>
      raise @text.ParseError::BadRule(rule~, message="missing FREQ clause")
  }
}

///|
/// Drop a leading `RRULE:` property-name prefix, if present, so a whole
/// content line and a bare property value both parse.
fn without_rrule_prefix(rule : String) -> String {
  let cs = rule.to_array()
  let n = cs.length()
  if n >= 6 {
    let head = String::to_upper(String::from_array(cs[0:6]))
    if head == "RRULE:" {
      String::from_array(cs[6:n])
    } else {
      rule
    }
  } else {
    rule
  }
}

///|
/// Split on a one-character separator, keeping every part — including a
/// trailing empty one — so `a;;b` and `a;` stay visible to the caller as
/// breakage instead of being quietly folded away.
fn split_on(text : String, sep : Char) -> Array[String] {
  let parts : Array[String] = []
  let cs = text.to_array()
  let n = cs.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if cs[i] == sep {
      parts.push(String::from_array(cs[start:i]))
      start = i + 1
    }
    i = i + 1
  }
  parts.push(String::from_array(cs[start:n]))
  parts
}

///|
/// Split a clause into its name and value at the first `=`; `None` when
/// there is no separator at all.
fn split_at_equals(part : String) -> (String, String)? {
  let cs = part.to_array()
  let n = cs.length()
  let mut found = -1
  let mut i = 0
  while i < n {
    if cs[i] == '=' {
      found = i
      i = n
    } else {
      i = i + 1
    }
  }
  if found < 0 {
    None
  } else {
    Some((String::from_array(cs[0:found]), String::from_array(cs[found + 1:n])))
  }
}

///|
/// Whether this clause name has already appeared in the rule.
fn has_clause(seen : Array[String], key : String) -> Bool {
  let mut found = false
  for entry in seen {
    if entry == key {
      found = true
    }
  }
  found
}

///|
/// The `FREQ` value: one of the four supported calendar grades, or an
/// explicit error. The sub-daily grades are named in their own rejection
/// message so a feed author learns the boundary, not just the failure.
fn parse_freq(value : String, rule : String) -> Freq raise {
  match String::to_upper(value) {
    "YEARLY" => Yearly
    "MONTHLY" => Monthly
    "WEEKLY" => Weekly
    "DAILY" => Daily
    "HOURLY" | "MINUTELY" | "SECONDLY" =>
      raise @text.ParseError::BadRule(
        rule~,
        message="unsupported FREQ: \{value}",
      )
    _ =>
      raise @text.ParseError::BadRule(rule~, message="unknown FREQ: \{value}")
  }
}

///|
/// `INTERVAL` and `COUNT`: a positive integer, nothing else.
fn positive_clause(key : String, value : String, rule : String) -> Int raise {
  match parse_signed_int(value) {
    Some(n) =>
      if n >= 1 {
        n
      } else {
        raise @text.ParseError::BadRule(
          rule~,
          message="\{key} must be a positive integer: \{value}",
        )
      }
    None =>
      raise @text.ParseError::BadRule(
        rule~,
        message="malformed \{key} value: \{value}",
      )
  }
}

///|
/// The `UNTIL` value: a DATE or date-time, read by the same four-state
/// parser the model layer uses. Its own error is re-wrapped as a rule
/// failure so every `parse_rule` caller sees one error shape.
fn parse_until(value : String, rule : String) -> @model.IcalDateTime raise {
  @model.parse_single_date_time(value, @model.ZoneTable::empty()) catch {
    _ =>
      raise @text.ParseError::BadRule(
        rule~,
        message="malformed UNTIL value: \{value}",
      )
  }
}

///|
/// A comma-separated `BYDAY` list; every entry must be a weekday code with
/// an optional ordinal.
fn parse_byday_list(value : String, rule : String) -> Array[Byday] raise {
  let out : Array[Byday] = []
  for item in split_on(value, ',') {
    match parse_byday_item(item) {
      Some(entry) => out.push(entry)
      None =>
        raise @text.ParseError::BadRule(
          rule~,
          message="malformed BYDAY value: \{item}",
        )
    }
  }
  out
}

///|
/// One `BYDAY` entry: an optional signed ordinal (±53, never 0) followed
/// by a two-letter weekday code.
fn parse_byday_item(item : String) -> Byday? {
  let text = String::to_upper(item)
  let cs = text.to_array()
  let n = cs.length()
  if n < 2 {
    None
  } else {
    match weekday_of(String::from_array(cs[n - 2:n])) {
      None => None
      Some(weekday) => {
        let head = String::from_array(cs[0:n - 2])
        if head == "" {
          Some({ ordinal: 0, weekday, })
        } else {
          match parse_signed_int(head) {
            Some(ordinal) =>
              if ordinal == 0 || ordinal.abs() > 53 {
                None
              } else {
                Some({ ordinal, weekday, })
              }
            None => None
          }
        }
      }
    }
  }
}

///|
/// The `WKST` value: one weekday code.
fn parse_weekday_code(value : String, rule : String) -> @time.Weekday raise {
  match weekday_of(String::to_upper(value)) {
    Some(weekday) => weekday
    None =>
      raise @text.ParseError::BadRule(
        rule~,
        message="malformed WKST value: \{value}",
      )
  }
}

///|
/// A two-letter weekday code, as `BYDAY` and `WKST` spell them.
fn weekday_of(code : String) -> @time.Weekday? {
  match code {
    "MO" => Some(@time.Weekday::Monday)
    "TU" => Some(@time.Weekday::Tuesday)
    "WE" => Some(@time.Weekday::Wednesday)
    "TH" => Some(@time.Weekday::Thursday)
    "FR" => Some(@time.Weekday::Friday)
    "SA" => Some(@time.Weekday::Saturday)
    "SU" => Some(@time.Weekday::Sunday)
    _ => None
  }
}

///|
/// A comma-separated integer list for `BYMONTHDAY`, `BYMONTH`, and
/// `BYSETPOS`. Every entry must be non-zero and within `bound` of zero;
/// `signed` selects whether a leading sign is part of the grammar (`false`
/// for `BYMONTH`, whose RFC grammar is bare digits).
fn parse_int_list(
  value : String,
  key : String,
  rule : String,
  bound : Int,
  signed : Bool,
) -> Array[Int] raise {
  let out : Array[Int] = []
  for item in split_on(value, ',') {
    let cs = item.to_array()
    if !signed && cs.length() > 0 && (cs[0] == '-' || cs[0] == '+') {
      raise @text.ParseError::BadRule(
        rule~,
        message="malformed \{key} value: \{item}",
      )
    }
    match parse_signed_int(item) {
      Some(n) =>
        if n == 0 || n.abs() > bound {
          raise @text.ParseError::BadRule(
            rule~,
            message="\{key} value out of range: \{item}",
          )
        } else {
          out.push(n)
        }
      None =>
        raise @text.ParseError::BadRule(
          rule~,
          message="malformed \{key} value: \{item}",
        )
    }
  }
  out
}

///|
/// A decimal integer with an optional sign. Values longer than nine digits
/// are refused rather than risked through silent wrap-around.
fn parse_signed_int(text : String) -> Int? {
  let cs = text.to_array()
  let n = cs.length()
  if n == 0 {
    None
  } else {
    let mut i = 0
    let mut sign = 1
    if cs[0] == '-' {
      sign = -1
      i = 1
    } else if cs[0] == '+' {
      i = 1
    }
    if i >= n {
      None
    } else {
      let mut acc = 0
      let mut digits = 0
      let mut ok = true
      while i < n {
        let d = cs[i].to_int() - '0'.to_int()
        if d < 0 || d > 9 {
          ok = false
          i = n
        } else {
          acc = acc * 10 + d
          digits = digits + 1
          i = i + 1
        }
      }
      if ok && digits <= 9 {
        Some(sign * acc)
      } else {
        None
      }
    }
  }
}
