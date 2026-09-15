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
/// Expand and merge one UID's VEVENT series. A cancelled override removes its
/// instance; a moved override replaces that instance; RANGE=THISANDFUTURE
/// shifts the selected instance and every later generated instance by the
/// same wall-clock delta.
pub fn expand_series(
  events : Array[@model.Event],
  limit? : Int = 200,
) -> Array[Occurrence] raise {
  let master = find_master(events)
  match master {
    None => []
    Some(base) =>
      match base.dtstart {
        None => []
        Some(dtstart) => {
          let generated = match base.rrule {
            Some(text) => expand(parse_rule(text), dtstart, limit~)
            None => [dtstart]
          }
          let uid = base.uid.unwrap_or("")
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
                        end: event.dtend,
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
          out
        }
      }
  }
}

///|
fn find_master(events : Array[@model.Event]) -> @model.Event? {
  for event in events {
    if event.recurrence_id is None {
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
  future.sort_by((a, b) => {
    if a.0 < b.0 {
      -1
    } else if a.0 > b.0 {
      1
    } else {
      0
    }
  })
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
