///|
/// Why an expansion can fail even though the rule parsed.
pub(all) suberror ExpandError {
  /// The rule uses a feature outside this package's supported boundary.
  Unsupported(feature~ : String)
  /// The rule is syntactically fine but semantically invalid with the
  /// `DTSTART` it was given; these checks were deferred from parsing
  /// because only expansion knows the `DTSTART`.
  Invalid(message~ : String)
} derive(Debug, Eq)

///|
pub impl Show for ExpandError with fn output(self, logger) {
  match self {
    Unsupported(feature=f) =>
      logger.write_string("unsupported RRULE feature in expansion: \{f}")
    Invalid(message=m) => logger.write_string("invalid recurrence rule: \{m}")
  }
}

///|
/// A safety bound on how many rule periods `expand` walks before giving
/// up, so a rule whose `BY*` clauses can never match (say
/// `BYMONTH=2;BYMONTHDAY=30`) terminates with an empty result instead of
/// spinning forever.
const MAX_PERIODS : Int = 10_000

///|
/// Expand a parsed [`Rule`] against its `DTSTART` into the occurrence
/// date-times of the series, in chronological order (RFC 5545 §3.3.10).
///
/// Supports the calendar-grade RFC 5545 rules in this project: `DAILY` /
/// `WEEKLY` / `MONTHLY` / `YEARLY`, ordinal `BYDAY`, positive and negative
/// `BYMONTHDAY`, `BYSETPOS`, `BYMONTH`, and `WKST`. The semantic
/// checks that need the `DTSTART` (`COUNT` + `UNTIL` exclusivity, `UNTIL`
/// value-type agreement) happen here.
///
/// Occurrences are wall-clock arithmetic: every occurrence carries the
/// `DTSTART`'s clock time, UTC offset, zone spelling, and all-day flag
/// unchanged (see [`@model.IcalDateTime::on_date`]), so a series crossing
/// a DST change keeps the `DTSTART` offset — the documented `ZoneTable`
/// boundary, not a silent guess. A `DTSTART` that does not match the rule
/// is not forced into the series: the first occurrence is the first
/// matching date, exactly as the reference corpus behaves.
///
/// `COUNT` counts occurrences from the first match (RFC 5545 counts the
/// `DTSTART` only when it matches); `UNTIL` bounds the series
/// inclusively, compared by instant. `limit` caps how many occurrences
/// are returned — the safety valve for unbounded rules — and never
/// truncates a `COUNT`/`UNTIL` rule that ends within it.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let rule = @rrule.parse_rule("FREQ=DAILY;COUNT=3")
///   let dtstart = @model.parse_single_date_time(
///     "20260901T090000Z",
///     @model.ZoneTable::empty(),
///   )
///   let occurrences = @rrule.expand(rule, dtstart)
///   assert_eq(occurrences.length(), 3)
///   assert_eq(occurrences[2].to_string(), "2026-09-03T09:00:00Z")
/// }
/// ```
pub fn expand(
  rule : Rule,
  dtstart : @model.IcalDateTime,
  limit? : Int = 200,
) -> Array[@model.IcalDateTime] raise {
  check_expandable(rule, dtstart)
  let start = plain_date_of(dtstart.wall)
  let until_instant : Int64? = match rule.until {
    Some(u) => Some(u.instant_seconds())
    None => None
  }
  let out : Array[@model.IcalDateTime] = []
  let mut done = false
  let mut period = 0
  while !done && period < MAX_PERIODS {
    for day in candidates_for(rule, start, period) {
      if day < start {
        continue
      }
      let occ = dtstart.on_date(day)
      let past_until = match until_instant {
        Some(u) => occ.instant_seconds() > u
        None => false
      }
      if past_until {
        // Candidates are chronological, so everything after this
        // occurrence is past UNTIL too — the series is finished.
        done = true
        break
      }
      out.push(occ)
      match rule.count {
        Some(cap) =>
          if out.length() >= cap {
            done = true
            break
          }
        None => ()
      }
      if out.length() >= limit {
        done = true
        break
      }
    }
    period = period + 1
  }
  out
}

///|
/// The gate every expansion passes first: DTSTART-dependent semantic checks
/// deferred from parsing happen here, along with RFC placement constraints.
fn check_expandable(rule : Rule, dtstart : @model.IcalDateTime) -> Unit raise {
  for entry in rule.byday {
    if entry.ordinal != 0 && (rule.freq is Daily || rule.freq is Weekly) {
      raise ExpandError::Invalid(
        message="ordinal BYDAY is only valid with MONTHLY or YEARLY",
      )
    }
  }
  if rule.bysetpos.length() > 0 &&
    rule.byday.length() == 0 &&
    rule.bymonthday.length() == 0 &&
    rule.bymonth.length() == 0 {
    raise ExpandError::Invalid(message="BYSETPOS requires another BY rule")
  }
  match (rule.count, rule.until) {
    (Some(_), Some(_)) =>
      raise ExpandError::Invalid(
        message="COUNT and UNTIL are mutually exclusive",
      )
    _ => ()
  }
  match rule.until {
    Some(u) =>
      if u.all_day != dtstart.all_day {
        raise ExpandError::Invalid(
          message="UNTIL must have the same value type as DTSTART",
        )
      }
    None => ()
  }
}

///|
/// The candidate dates of period `period`, in chronological order. How
/// much of the calendar one period covers is what the frequency means:
/// one interval-step of days, weeks, months, or years.
fn candidates_for(
  rule : Rule,
  start : @time.PlainDate,
  period : Int,
) -> Array[@time.PlainDate] raise {
  let all = match rule.freq {
    Daily => daily_candidates(rule, start, period)
    Weekly => weekly_candidates(rule, start, period)
    Monthly => monthly_candidates(rule, start, period)
    Yearly => yearly_candidates(rule, start, period)
  }
  apply_setpos(all, rule.bysetpos)
}

///|
/// Select positions from one frequency period after all other BY filters.
/// Positive positions count from one; negative positions count backwards.
fn apply_setpos(
  candidates : Array[@time.PlainDate],
  positions : Array[Int],
) -> Array[@time.PlainDate] {
  if positions.length() == 0 {
    return candidates
  }
  let out : Array[@time.PlainDate] = []
  for position in positions {
    let index = if position > 0 {
      position - 1
    } else {
      candidates.length() + position
    }
    if index >= 0 && index < candidates.length() {
      let candidate = candidates[index]
      if !date_selected(out, candidate) {
        out.push(candidate)
      }
    }
  }
  out.sort_by((a, b) => if a < b { -1 } else if a > b { 1 } else { 0 })
  out
}

///|
/// `DAILY`: one date per period, the interval step from `DTSTART`, kept
/// only if it survives every present `BY*` filter.
fn daily_candidates(
  rule : Rule,
  start : @time.PlainDate,
  period : Int,
) -> Array[@time.PlainDate] raise {
  let day = start.add_days((period * rule.interval).to_int64())
  if passes_filters(rule, day) {
    [day]
  } else {
    []
  }
}

///|
/// `WEEKLY`: the seven days of the `WKST`-aligned week that is
/// `period * interval` weeks from `DTSTART`'s week, filtered to the
/// `BYDAY` weekdays — or, with no `BYDAY`, to `DTSTART`'s own weekday.
/// `WKST` decides which week a date belongs to, which is why it changes
/// the result near a week boundary.
fn weekly_candidates(
  rule : Rule,
  start : @time.PlainDate,
  period : Int,
) -> Array[@time.PlainDate] raise {
  let into_week = (weekday_num(start.weekday()) - weekday_num(rule.wkst) + 7) %
    7
  let week0 = start.add_days(-into_week.to_int64())
  let base = week0.add_days((period * rule.interval * 7).to_int64())
  let out : Array[@time.PlainDate] = []
  for i in 0..<7 {
    let day = base.add_days(i.to_int64())
    let wanted = if rule.byday.length() > 0 {
      weekday_selected(rule.byday, day.weekday())
    } else {
      day.weekday() == start.weekday()
    }
    if wanted && passes_filters(rule, day) {
      out.push(day)
    }
  }
  out
}

///|
/// `MONTHLY`: the month `period * interval` months on. Within it, the
/// `BYMONTHDAY` days and the `BYDAY` weekdays combine — both present
/// means dates matching both, either alone means its own dates, and
/// neither falls back to `DTSTART`'s day-of-month (skipped in months too
/// short for it). `BYMONTH` drops the whole month when it does not
/// match. Days missing from the calendar (February 30) are skipped, not
/// clamped: RFC 5545 has no such date to emit.
fn monthly_candidates(
  rule : Rule,
  start : @time.PlainDate,
  period : Int,
) -> Array[@time.PlainDate] raise {
  let months = start.year() * 12 + (start.month() - 1) + period * rule.interval
  let year = months / 12
  let month = months % 12 + 1
  if rule.bymonth.length() > 0 && !int_selected(rule.bymonth, month) {
    return []
  }
  let days = month_days(rule, start, year, month)
  let out : Array[@time.PlainDate] = []
  for day in days {
    out.push(@time.PlainDate::of(year, month, day))
  }
  out
}

///|
/// `YEARLY`: the year `period * interval` years on. Months come from
/// `BYMONTH`, or every month when `BYDAY`/`BYMONTHDAY` need a whole year
/// to range over, or just `DTSTART`'s month when nothing constrains it.
/// Inside each month the same day selection as `MONTHLY` applies, so the
/// `DTSTART` fallback yields the anniversary date.
fn yearly_candidates(
  rule : Rule,
  start : @time.PlainDate,
  period : Int,
) -> Array[@time.PlainDate] raise {
  let year = start.year() + period * rule.interval
  if rule.bymonth.length() == 0 &&
    rule.bymonthday.length() == 0 &&
    has_ordinal_byday(rule.byday) {
    let out : Array[@time.PlainDate] = []
    for month in 1..<=12 {
      let dim = @time.PlainDate::of(year, month, 1).days_in_month()
      for day in 1..<=dim {
        let date = @time.PlainDate::of(year, month, day)
        if weekday_selected_in_year(rule.byday, date) {
          out.push(date)
        }
      }
    }
    return out
  }
  let months : Array[Int] = []
  if rule.bymonth.length() > 0 {
    for month in sorted_ints(rule.bymonth) {
      months.push(month)
    }
  } else if rule.byday.length() > 0 || rule.bymonthday.length() > 0 {
    for month in 1..<=12 {
      months.push(month)
    }
  } else {
    months.push(start.month())
  }
  let out : Array[@time.PlainDate] = []
  for month in months {
    for day in month_days(rule, start, year, month) {
      out.push(@time.PlainDate::of(year, month, day))
    }
  }
  out
}

///|
/// The day numbers of one month under this rule: `BYMONTHDAY` ∩ `BYDAY`
/// when both are present, either alone, or `DTSTART`'s day as the
/// fallback. Ascending, and never a day the calendar lacks.
fn month_days(
  rule : Rule,
  start : @time.PlainDate,
  year : Int,
  month : Int,
) -> Array[Int] raise {
  let dim = @time.PlainDate::of(year, month, 1).days_in_month()
  let out : Array[Int] = []
  if rule.bymonthday.length() > 0 {
    for raw_day in sorted_ints(rule.bymonthday) {
      let day = if raw_day > 0 { raw_day } else { dim + raw_day + 1 }
      if day >= 1 && day <= dim {
        let weekday = @time.PlainDate::of(year, month, day).weekday()
        if rule.byday.length() == 0 ||
          weekday_selected_in_month(rule.byday, year, month, day, weekday) {
          out.push(day)
        }
      }
    }
  } else if rule.byday.length() > 0 {
    for day in 1..<=dim {
      let weekday = @time.PlainDate::of(year, month, day).weekday()
      if weekday_selected_in_month(rule.byday, year, month, day, weekday) {
        out.push(day)
      }
    }
  } else if start.day() <= dim {
    out.push(start.day())
  }
  out.sort()
  out
}

///|
/// Whether a `DAILY`/`WEEKLY` candidate survives every present `BY*`
/// filter. Frequencies below monthly cannot generate from `BYMONTHDAY`,
/// so it limits here instead.
fn passes_filters(rule : Rule, day : @time.PlainDate) -> Bool {
  if rule.bymonth.length() > 0 && !int_selected(rule.bymonth, day.month()) {
    false
  } else if rule.bymonthday.length() > 0 &&
    !int_selected(rule.bymonthday, day.day()) {
    false
  } else if rule.byday.length() > 0 &&
    !weekday_selected(rule.byday, day.weekday()) {
    false
  } else {
    true
  }
}

///|
/// Monday as 0 through Sunday as 6 — the arithmetic week-position of a
/// weekday, whatever spelling it came in as.
fn weekday_num(weekday : @time.Weekday) -> Int {
  match weekday {
    @time.Weekday::Monday => 0
    @time.Weekday::Tuesday => 1
    @time.Weekday::Wednesday => 2
    @time.Weekday::Thursday => 3
    @time.Weekday::Friday => 4
    @time.Weekday::Saturday => 5
    @time.Weekday::Sunday => 6
  }
}

///|
/// Whether one of the plain `BYDAY` entries names this weekday.
fn weekday_selected(entries : Array[Byday], weekday : @time.Weekday) -> Bool {
  let mut found = false
  for entry in entries {
    if entry.ordinal == 0 && entry.weekday == weekday {
      found = true
    }
  }
  found
}

///|
fn weekday_selected_in_month(
  entries : Array[Byday],
  year : Int,
  month : Int,
  day : Int,
  weekday : @time.Weekday,
) -> Bool raise {
  let dim = @time.PlainDate::of(year, month, 1).days_in_month()
  for entry in entries {
    if entry.weekday == weekday {
      if entry.ordinal == 0 {
        return true
      }
      let ordinal = if entry.ordinal > 0 {
        (day - 1) / 7 + 1
      } else {
        -((dim - day) / 7 + 1)
      }
      if ordinal == entry.ordinal {
        return true
      }
    }
  }
  false
}

///|
fn weekday_selected_in_year(
  entries : Array[Byday],
  date : @time.PlainDate,
) -> Bool raise {
  for entry in entries {
    if entry.weekday == date.weekday() {
      if entry.ordinal == 0 {
        return true
      }
      let jan1 = @time.PlainDate::of(date.year(), 1, 1)
      let dec31 = @time.PlainDate::of(date.year(), 12, 31)
      let ordinal = if entry.ordinal > 0 {
        (date.to_unix_day() - jan1.to_unix_day()).to_int() / 7 + 1
      } else {
        -((dec31.to_unix_day() - date.to_unix_day()).to_int() / 7 + 1)
      }
      if ordinal == entry.ordinal {
        return true
      }
    }
  }
  false
}

///|
fn has_ordinal_byday(entries : Array[Byday]) -> Bool {
  for entry in entries {
    if entry.ordinal != 0 {
      return true
    }
  }
  false
}

///|
fn date_selected(
  values : Array[@time.PlainDate],
  value : @time.PlainDate,
) -> Bool {
  for item in values {
    if item == value {
      return true
    }
  }
  false
}

///|
/// Whether the list contains the value.
fn int_selected(list : Array[Int], value : Int) -> Bool {
  let mut found = false
  for entry in list {
    if entry == value {
      found = true
    }
  }
  found
}

///|
/// An ascending copy of the list — clause values arrive in wire order
/// (`BYMONTHDAY=30,15` is legal) but candidates must be chronological.
fn sorted_ints(list : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  for value in list {
    out.push(value)
  }
  let n = out.length()
  for i in 1..<n {
    let key = out[i]
    let mut j = i - 1
    let mut placed = false
    while !placed {
      if j >= 0 && out[j] > key {
        out[j + 1] = out[j]
        j = j - 1
      } else {
        out[j + 1] = key
        placed = true
      }
    }
  }
  out
}

///|
/// The calendar date of a wall-clock value.
fn plain_date_of(wall : @time.PlainDateTime) -> @time.PlainDate raise {
  @time.PlainDate::of(wall.year(), wall.month(), wall.day())
}
