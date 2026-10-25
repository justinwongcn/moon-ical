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
pub extend ExpandError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ExpandError with Eq::{not_equal, equal}

///|
pub impl Show for ExpandError with fn output(self, logger) {
  match self {
    Unsupported(feature=f) =>
      logger.write_string("unsupported RRULE feature in expansion: \{f}")
    Invalid(message=m) => logger.write_string("invalid recurrence rule: \{m}")
  }
}

///|
pub extend ExpandError with Show::{to_string, output}

///|
/// A safety bound on how many rule periods `expand` walks before giving
/// up, so a rule whose `BY*` clauses can never match (say
/// `BYMONTH=2;BYMONTHDAY=30`) terminates with an empty result instead of
/// spinning forever.
const MAX_PERIODS : Int32 = 10_000

///|
/// The last year moonbitlang/x's `PlainDate` can represent (its
/// `validate_year` bound). A candidate past it ends the expansion walk —
/// see [`expand`].
const MAX_PLAIN_YEAR : Int64 = 9999

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
/// truncates a `COUNT`/`UNTIL` rule that ends within it. A series whose
/// next candidate would fall past the representable calendar (year 9999
/// in moonbitlang/x) ends there rather than raising, whatever `INTERVAL`
/// says — the huge-interval products are computed in 64-bit for the same
/// reason: a wrapped 32-bit product can name a *valid but wrong* date.
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
  limit~ : Int32 = 200,
) -> Array[@model.IcalDateTime] raise {
  check_expandable(rule, dtstart)
  if limit <= 0 {
    // A cap of zero or less caps everything. The semantic checks above
    // still ran, so an invalid rule is reported rather than silently
    // empty — only the count is clamped. (Before S14 the first candidate
    // was pushed before the limit was consulted and limit=0 returned it.)
    return []
  }
  let normalized = NormalizedRule::new(rule)
  let rule = normalized.rule
  let start = plain_date_of(dtstart.wall)
  let until_instant : Int64? = match rule.until {
    Some(u) => Some(u.instant_seconds())
    None => None
  }
  let out : Array[@model.IcalDateTime] = []
  let mut done = false
  let mut period = 0
  while !done && period < MAX_PERIODS {
    let candidates : Array[@time.PlainDate] = match
      candidates_for(normalized, start, period) {
      // The next candidate would fall outside the representable calendar
      // (year -9999..9999 in moonbitlang/x), so the series has reached the
      // end of every date it could ever express — the walk is over, not
      // failed. Without this the walk raised x/time's untyped Failure
      // instead of ending (INTERVAL in the hundreds on MONTHLY, or an
      // Int32 product wrapping negative on WEEKLY/DAILY).
      None => {
        done = true
        []
      }
      Some(days) => days
    }
    for day in candidates {
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
/// Normalize BYMONTH and BYMONTHDAY once for all periods. Cache the realized
/// day numbers for every possible month length; negative days depend on that
/// length, but not on the particular year or month.
priv struct NormalizedRule {
  rule : Rule
  monthdays_by_length : Array[Array[Int32]]
}

///|
fn NormalizedRule::new(rule : Rule) -> NormalizedRule {
  let bymonth = rule.bymonth.copy()
  let bymonthday = rule.bymonthday.copy()
  bymonth.sort()
  bymonthday.sort()
  let sorted_rule = { ..rule, bymonth, bymonthday, }
  let monthdays_by_length : Array[Array[Int32]] = []
  for days_in_month in 28..<=31 {
    let days : Array[Int32] = []
    for raw_day in bymonthday {
      let day = if raw_day > 0 { raw_day } else { days_in_month + raw_day + 1 }
      if day >= 1 && day <= days_in_month {
        days.push(day)
      }
    }
    days.sort()
    monthdays_by_length.push(days)
  }
  { rule: sorted_rule, monthdays_by_length, }
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
  normalized : NormalizedRule,
  start : @time.PlainDate,
  period : Int32,
) -> Array[@time.PlainDate]? raise {
  let rule = normalized.rule
  let all : Array[@time.PlainDate]? = match rule.freq {
    Daily => daily_candidates(normalized, start, period)
    Weekly => weekly_candidates(normalized, start, period)
    Monthly => monthly_candidates(normalized, start, period)
    Yearly => yearly_candidates(normalized, start, period)
  }
  match all {
    None => None
    Some(days) => Some(apply_setpos(days, rule.bysetpos))
  }
}

///|
/// Select positions from one frequency period after all other BY filters.
/// Positive positions count from one; negative positions count backwards.
fn apply_setpos(
  candidates : Array[@time.PlainDate],
  positions : Array[Int32],
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
    if index >= 0 &&
      index < candidates.length() &&
      !out.contains(candidates[index]) {
      out.push(candidates[index])
    }
  }
  out.sort_by((a, b) => Compare::compare(a, b))
  out
}

///|
/// `DAILY`: one date per period, the interval step from `DTSTART`, kept
/// only if it survives every present `BY*` filter. `None` when the step
/// leaves the representable calendar.
fn daily_candidates(
  normalized : NormalizedRule,
  start : @time.PlainDate,
  period : Int32,
) -> Array[@time.PlainDate]? {
  // Int64 on purpose: period * interval can exceed Int32 for the huge
  // INTERVAL values parse_rule admits, and a wrapped product can land on
  // a *valid* date — the wrong occurrence, silently.
  let step = period.to_int64() * normalized.rule.interval.to_int64()
  let day : @time.PlainDate? = Some(start.add_days(step)) catch { _ => None }
  match day {
    None => None
    Some(day) =>
      if passes_filters(normalized, day) {
        Some([day])
      } else {
        Some([])
      }
  }
}

///|
/// `WEEKLY`: the seven days of the `WKST`-aligned week that is
/// `period * interval` weeks from `DTSTART`'s week, filtered to the
/// `BYDAY` weekdays — or, with no `BYDAY`, to `DTSTART`'s own weekday.
/// `WKST` decides which week a date belongs to, which is why it changes
/// the result near a week boundary. `None` past the representable
/// calendar.
fn weekly_candidates(
  normalized : NormalizedRule,
  start : @time.PlainDate,
  period : Int32,
) -> Array[@time.PlainDate]? raise {
  let rule = normalized.rule
  let into_week = (weekday_num(start.weekday()) - weekday_num(rule.wkst) + 7) %
    7
  let week0 = start.add_days(-into_week.to_int64())
  let step = period.to_int64() * rule.interval.to_int64() * 7
  let base : @time.PlainDate? = Some(week0.add_days(step)) catch { _ => None }
  match base {
    None => None
    Some(base) => {
      let out : Array[@time.PlainDate] = []
      for i in 0..<7 {
        let day = base.add_days(i.to_int64())
        let wanted = if rule.byday.length() > 0 {
          weekday_selected(rule.byday, day.weekday())
        } else {
          day.weekday() == start.weekday()
        }
        if wanted && passes_filters(normalized, day) {
          out.push(day)
        }
      }
      Some(out)
    }
  }
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
  normalized : NormalizedRule,
  start : @time.PlainDate,
  period : Int32,
) -> Array[@time.PlainDate]? raise {
  let rule = normalized.rule
  // Int64 arithmetic: period * interval overflows Int32 for the huge
  // INTERVAL values parse_rule admits, and a wrapped month count would
  // realize a wrong-but-valid year.
  let months = start.year().to_int64() * 12 +
    (start.month() - 1).to_int64() +
    period.to_int64() * rule.interval.to_int64()
  let year = months / 12
  if year > MAX_PLAIN_YEAR {
    return None
  }
  let year = Int64::to_int(year)
  let month = Int64::to_int(months % 12 + 1)
  if rule.bymonth.length() > 0 && !int_selected(rule.bymonth, month) {
    return Some([])
  }
  let days = month_days(normalized, start, year, month)
  let out : Array[@time.PlainDate] = []
  for day in days {
    out.push(@time.PlainDate::of(year, month, day))
  }
  Some(out)
}

///|
/// `YEARLY`: the year `period * interval` years on. Months come from
/// `BYMONTH`, or every month when `BYDAY`/`BYMONTHDAY` need a whole year
/// to range over, or just `DTSTART`'s month when nothing constrains it.
/// Inside each month the same day selection as `MONTHLY` applies, so the
/// `DTSTART` fallback yields the anniversary date.
fn yearly_candidates(
  normalized : NormalizedRule,
  start : @time.PlainDate,
  period : Int32,
) -> Array[@time.PlainDate]? raise {
  let rule = normalized.rule
  let year = start.year().to_int64() +
    period.to_int64() * rule.interval.to_int64()
  if year > MAX_PLAIN_YEAR {
    return None
  }
  let year = Int64::to_int(year)
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
    return Some(out)
  }
  let months : Array[Int32] = []
  if rule.bymonth.length() > 0 {
    for month in rule.bymonth {
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
    for day in month_days(normalized, start, year, month) {
      out.push(@time.PlainDate::of(year, month, day))
    }
  }
  Some(out)
}

///|
/// The day numbers of one month under this rule: `BYMONTHDAY` ∩ `BYDAY`
/// when both are present, either alone, or `DTSTART`'s day as the
/// fallback. Ascending, and never a day the calendar lacks.
fn month_days(
  normalized : NormalizedRule,
  start : @time.PlainDate,
  year : Int32,
  month : Int32,
) -> Array[Int32] raise {
  let rule = normalized.rule
  let dim = @time.PlainDate::of(year, month, 1).days_in_month()
  let out : Array[Int32] = []
  if rule.bymonthday.length() > 0 {
    for day in normalized.monthdays_by_length[dim - 28] {
      let weekday = @time.PlainDate::of(year, month, day).weekday()
      if rule.byday.length() == 0 ||
        weekday_selected_in_month(rule.byday, year, month, day, weekday) {
        out.push(day)
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
  out
}

///|
/// Whether a `DAILY`/`WEEKLY` candidate survives every present `BY*`
/// filter. Frequencies below monthly cannot generate from `BYMONTHDAY`,
/// so it limits here instead — and a negative `BYMONTHDAY` counts from the
/// end of the candidate's *own* month, so the test runs against the same
/// realized day numbers [`month_days`] generates from, never the raw
/// negative clause (which can never equal a 1..31 day number).
fn passes_filters(normalized : NormalizedRule, day : @time.PlainDate) -> Bool {
  let rule = normalized.rule
  if rule.bymonth.length() > 0 && !int_selected(rule.bymonth, day.month()) {
    return false
  }
  if rule.bymonthday.length() > 0 {
    let dim = day.days_in_month()
    if !int_selected(normalized.monthdays_by_length[dim - 28], day.day()) {
      return false
    }
  }
  if rule.byday.length() > 0 && !weekday_selected(rule.byday, day.weekday()) {
    return false
  }
  true
}

///|
/// Monday as 0 through Sunday as 6 — the arithmetic week-position of a
/// weekday, whatever spelling it came in as.
fn weekday_num(weekday : @time.Weekday) -> Int32 {
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
  for entry in entries {
    if entry.ordinal == 0 && entry.weekday == weekday {
      return true
    }
  }
  false
}

///|
fn weekday_selected_in_month(
  entries : Array[Byday],
  year : Int32,
  month : Int32,
  day : Int32,
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
/// Whether a normalized, ascending clause list contains the value.
fn int_selected(list : Array[Int32], value : Int32) -> Bool {
  list.binary_search(value) is Ok(_)
}

///|
/// The calendar date of a wall-clock value.
fn plain_date_of(wall : @time.PlainDateTime) -> @time.PlainDate raise {
  @time.PlainDate::of(wall.year(), wall.month(), wall.day())
}
