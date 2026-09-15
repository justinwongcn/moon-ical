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
          let out : Array[Occurrence] = []
          for slot in generated {
            if excluded(base.exdates, slot) {
              continue
            }
            match exact_override(events, uid, slot) {
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
                match latest_future_override(events, uid, slot) {
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
                          end: shift_master_end(base, slot, delta),
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
                      end: shift_master_end(base, slot, 0),
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
fn exact_override(
  events : Array[@model.Event],
  uid : String,
  slot : @model.IcalDateTime,
) -> @model.Event? {
  for event in events {
    if event.uid.unwrap_or("") == uid {
      match event.recurrence_id {
        Some(id) => if id.compare(slot) == 0 { return Some(event) }
        None => ()
      }
    }
  }
  None
}

///|
fn latest_future_override(
  events : Array[@model.Event],
  uid : String,
  slot : @model.IcalDateTime,
) -> @model.Event? {
  let mut selected : @model.Event? = None
  let mut selected_id : @model.IcalDateTime? = None
  for event in events {
    if event.uid.unwrap_or("") == uid &&
      event.recurrence_range.map(r => r.to_upper()) == Some("THISANDFUTURE") {
      match event.recurrence_id {
        Some(id) =>
          if id.compare(slot) <= 0 &&
            (selected_id is None || id.compare(selected_id.unwrap()) > 0) {
            selected = Some(event)
            selected_id = Some(id)
          }
        None => ()
      }
    }
  }
  selected
}

///|
fn cancelled(event : @model.Event) -> Bool {
  event.status.map(s => s.to_upper()) == Some("CANCELLED")
}

///|
fn excluded(
  exdates : Array[@model.IcalDateTime],
  slot : @model.IcalDateTime,
) -> Bool {
  for date in exdates {
    if date.compare(slot) == 0 {
      return true
    }
  }
  false
}

///|
fn shift_master_end(
  base : @model.Event,
  slot : @model.IcalDateTime,
  delta : Int64,
) -> @model.IcalDateTime? raise {
  match (base.dtstart, base.dtend) {
    (Some(start), Some(finish)) => {
      let duration = finish.instant_seconds() - start.instant_seconds()
      Some(slot.shift_seconds(duration + delta))
    }
    _ => None
  }
}
