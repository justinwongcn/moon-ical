///|
/// One effective occurrence after RRULE expansion, EXDATE removal, and
/// RECURRENCE-ID override merging.
pub(all) struct Occurrence {
  uid : String
  start : @model.IcalDateTime
  end : @model.IcalDateTime?
  summary : String?
  recurrence_id : @model.IcalDateTime
} derive(Debug, Eq)

///|
pub extend Occurrence with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend Occurrence with Eq::{not_equal, equal}

///|
/// Expand and merge one UID's VEVENT series. A cancelled override removes its
/// instance; a moved override replaces that instance; RANGE=THISANDFUTURE
/// shifts the selected instance and every later generated instance by the
/// same wall-clock delta.
pub fn expand_series(
  events : Array[@model.Event],
  limit~ : Int32 = 200,
) -> Array[Occurrence] raise {
  let result = expand_series_query(events, limit~)
  if result.budget_exceeded {
    raise ExpandError::Invalid(
      message="recurrence expansion exceeded 10000 periods without ending",
    )
  }
  result.occurrences
}

///|
/// A generated prefix with completeness independent of exclusions and overrides.
/// RDATE values are always included in full and never establish the RRULE frontier.
pub struct SeriesQueryResult {
  occurrences : Array[Occurrence]
  exhausted : Bool
  generated_through : @model.IcalDateTime?
  has_overrides : Bool
  /// The period safety budget ended before the requested raw instance budget.
  budget_exceeded : Bool
}

///|
/// Query one UID's series. `limit` budgets raw RRULE instances, not output size.
/// `exhausted` means the generator ended naturally; false requires a larger
/// budget or a range proof. With overrides, require exhaustion for that proof.
pub fn expand_series_query(
  events : Array[@model.Event],
  limit~ : Int32 = 200,
) -> SeriesQueryResult raise {
  let master = find_master(events)
  match master {
    None =>
      {
        occurrences: [],
        exhausted: true,
        generated_through: None,
        has_overrides: false,
        budget_exceeded: false,
      }
    Some(base) =>
      match base.dtstart {
        None => {
          if base.rdates.length() > 0 || base.rrule is Some(_) {
            raise ExpandError::Invalid(message="recurrence requires DTSTART")
          }
          {
            occurrences: [],
            exhausted: true,
            generated_through: None,
            has_overrides: false,
            budget_exceeded: false,
          }
        }
        Some(dtstart) => {
          let uid = base.uid.unwrap_or("")
          for event in events {
            if event.uid.unwrap_or("") != uid {
              continue
            }
            for value in [event.recurrence_id, event.dtstart] {
              match value {
                Some(value) =>
                  if value.all_day != dtstart.all_day ||
                    value.is_floating() != dtstart.is_floating() {
                    raise ExpandError::Invalid(
                      message="override value type must agree with DTSTART",
                    )
                  }
                None => ()
              }
            }
          }
          let (raw, exhausted) = match base.rrule {
            Some(text) => expand_generated(parse_rule(text), dtstart, limit~)
            None => ([dtstart], true)
          }
          let budget_exceeded = !exhausted && limit > 0 && raw.length() < limit
          let generated_through = if raw.length() > 0 {
            Some(raw[raw.length() - 1])
          } else {
            None
          }
          let generated = raw.copy()
          let keys : Map[Int64, Unit] = Map([])
          for slot in raw {
            keys[slot.instant_seconds()] = ()
          }
          for slot in base.rdates {
            if slot.all_day != dtstart.all_day ||
              slot.is_floating() != dtstart.is_floating() {
              raise ExpandError::Invalid(
                message="RDATE value type must agree with DTSTART",
              )
            }
            let key = slot.instant_seconds()
            if !keys.contains(key) {
              keys[key] = ()
              generated.push(slot)
            }
          }
          generated.sort_by((a, b) => a.compare(b))
          let has_overrides = events.any(event => {
            event.uid.unwrap_or("") == uid && event.recurrence_id is Some(_)
          })
          let index = SeriesIndex::build(events, base, uid)
          let duration = match base.dtend {
            Some(finish) =>
              Some(finish.instant_seconds() - dtstart.instant_seconds())
            None => None
          }
          let out : Array[Occurrence] = []
          let mut future_index = 0
          let mut active_future : @model.Event? = None
          for slot in generated {
            let key = slot.instant_seconds()
            while future_index < index.future.length() &&
                  index.future[future_index].0 <= key {
              active_future = Some(index.future[future_index].1)
              future_index = future_index + 1
            }
            if index.exdates.contains(key) {
              continue
            }
            match index.exact.get(key) {
              Some(event) =>
                if !cancelled(event) {
                  match event.dtstart {
                    Some(start) =>
                      out.push({
                        uid,
                        start,
                        end: override_end(event, duration),
                        summary: event.summary,
                        recurrence_id: slot,
                      })
                    None => ()
                  }
                }
              None =>
                match active_future {
                  Some(event) => {
                    if cancelled(event) {
                      continue
                    }
                    match (event.recurrence_id, event.dtstart) {
                      (Some(from), Some(to)) => {
                        let delta = to.instant_seconds() -
                          from.instant_seconds()
                        out.push({
                          uid,
                          start: slot.shift_seconds(delta),
                          end: shifted_end(slot, duration, delta),
                          summary: match event.summary {
                            Some(value) => Some(value)
                            None => base.summary
                          },
                          recurrence_id: slot,
                        })
                      }
                      _ => ()
                    }
                  }
                  None =>
                    out.push({
                      uid,
                      start: slot,
                      end: shifted_end(slot, duration, 0),
                      summary: base.summary,
                      recurrence_id: slot,
                    })
                }
            }
          }
          out.sort_by((a, b) => a.start.compare(b.start))
          {
            occurrences: out,
            exhausted,
            generated_through,
            has_overrides,
            budget_exceeded,
          }
        }
      }
  }
}

///|
/// The series definition: the first event without a `RECURRENCE-ID` that
/// carries the group's UID — the UID of the group's first event. A
/// master of some other UID used to be picked up when it came first,
/// silently expanding the wrong series for the group; a group whose UID
/// has no master has no series to expand.
fn find_master(events : Array[@model.Event]) -> @model.Event? {
  if events.length() == 0 {
    return None
  }
  let uid = events[0].uid.unwrap_or("")
  for event in events {
    if event.recurrence_id is None && event.uid.unwrap_or("") == uid {
      return Some(event)
    }
  }
  None
}

///|
priv struct SeriesIndex {
  exact : Map[Int64, @model.Event]
  exdates : Map[Int64, Unit]
  future : Array[(Int64, @model.Event)]
}

///|
fn SeriesIndex::build(
  events : Array[@model.Event],
  base : @model.Event,
  uid : String,
) -> SeriesIndex {
  let exact : Map[Int64, @model.Event] = Map([], capacity=events.length())
  let future_by_slot : Map[Int64, @model.Event] = Map([])
  for event in events {
    if event.uid.unwrap_or("") == uid {
      match event.recurrence_id {
        Some(id) => {
          let key = id.instant_seconds()
          // The old linear lookup selected the first override at a duplicate
          // RECURRENCE-ID, so preserve that deterministic wire-order rule.
          if !exact.contains(key) {
            exact[key] = event
          }
          if event.recurrence_range.map(r => r.to_upper()) ==
            Some("THISANDFUTURE") &&
            !future_by_slot.contains(key) {
            future_by_slot[key] = event
          }
        }
        None => ()
      }
    }
  }
  let future = future_by_slot.to_array()
  future.sort_by((a, b) => a.0.compare(b.0))
  let exdates : Map[Int64, Unit] = Map([], capacity=base.exdates.length())
  for date in base.exdates {
    exdates[date.instant_seconds()] = ()
  }
  { exact, exdates, future, }
}

///|
fn cancelled(event : @model.Event) -> Bool {
  event.status.map(s => s.to_upper()) == Some("CANCELLED")
}

///|
/// An override's end: its own `DTEND`, or the master's duration when the
/// override moved only the start. An override that says nothing about the
/// end keeps the meeting's length — dropping it made a moved one-hour
/// meeting report no end at all.
fn override_end(
  event : @model.Event,
  duration : Int64?,
) -> @model.IcalDateTime? raise {
  match event.dtend {
    Some(end) => Some(end)
    None =>
      match (event.dtstart, duration) {
        (Some(start), Some(seconds)) => Some(start.shift_seconds(seconds))
        _ => None
      }
  }
}

///|
fn shifted_end(
  slot : @model.IcalDateTime,
  duration : Int64?,
  delta : Int64,
) -> @model.IcalDateTime? raise {
  match duration {
    Some(seconds) => Some(slot.shift_seconds(seconds + delta))
    None => None
  }
}
