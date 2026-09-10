///|
/// How often a recurrence repeats: the `FREQ` clause of RFC 5545 §3.3.10.
///
/// Only the four calendar grades are representable, on purpose. The finer
/// `HOURLY`, `MINUTELY`, and `SECONDLY` grades fall outside this project's
/// boundary (docs/development.html §08), so [`@rrule.parse_rule`] rejects
/// them with an explicit error instead of silently narrowing or dropping
/// them.
pub(all) enum Freq {
  Yearly
  Monthly
  Weekly
  Daily
} derive(Debug, Eq)

///|
/// One `BYDAY` entry: a weekday, optionally qualified by an ordinal.
///
/// `TU` is any Tuesday (`ordinal = 0`), `1FR` the first Friday of the
/// interval, `-2MO` the second-to-last Monday. RFC 5545 bounds the ordinal
/// to ±53; expansion of qualified weekdays arrives with S8.
pub struct Byday {
  /// Zero when the weekday stands alone.
  ordinal : Int
  weekday : @time.Weekday
} derive(Debug, Eq)

///|
/// A parsed `RRULE` value (RFC 5545 §3.3.10): the *syntax* of a recurrence
/// rule, not its expansion.
///
/// Every clause within the project's support boundary is kept in a typed
/// field, whichever milestone will expand it — the first-tier clauses
/// (INTERVAL / COUNT / UNTIL / plain BYDAY / positive BYMONTHDAY / BYMONTH)
/// with S3, the second-tier ones (ordinal BYDAY, negative BYMONTHDAY,
/// BYSETPOS, WKST) with S8. Clauses outside the boundary never reach a
/// `Rule`: [`@rrule.parse_rule`] rejects them loudly.
///
/// Defaults follow the RFC: `interval = 1` and `wkst = Monday` when their
/// clauses are absent, and every BY* list is empty when absent.
pub struct Rule {
  freq : Freq
  interval : Int
  count : Int?
  until : @model.IcalDateTime?
  byday : Array[Byday]
  bymonthday : Array[Int]
  bymonth : Array[Int]
  bysetpos : Array[Int]
  wkst : @time.Weekday
} derive(Debug, Eq)
