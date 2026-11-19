///|
/// The `DAV:error` payload for a refused calendar-object body.
pub fn precondition_document(inner : String) -> String {
  error_document(inner)
}

///|
/// Which RFC 4791 §5.3.2 precondition a `PUT` body fails, if any — the
/// payload is the error element to put on the wire (`None` = acceptable).
///
/// The bar is "the query evaluation can read every component": the body
/// parses as iCalendar, every calendar component's temporal properties
/// parse against the body's own zone table, and every `RRULE` is
/// expandable. Anything the evaluation would fail closed on (500 with
/// the poison href named) is refused here with the precondition RFC 4791
/// §5.3.2 sanctions, so one bad `PUT` can no longer turn the
/// collection's reports into 500s.
pub fn calendar_object_precondition(body : String) -> String? {
  let roots = @model.parse_calendar(body) catch {
    _ => return Some("<C:valid-calendar-data/>")
  }
  let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  for root in roots {
    for child in root.children {
      let verdict = match child.kind {
        "VEVENT" => check_vevent(child, zones~)
        "VTODO" | "VJOURNAL" | "VFREEBUSY" => check_non_event(child, zones~)
        _ => "" // VTIMEZONE and unknown components are preserved, never evaluated
      }
      if verdict != "" {
        return Some(verdict)
      }
    }
  }
  // Cross-component consistency (S44's series raise, mirrored): within a
  // UID group the master DTSTART fixes the type shape and every override
  // must share it. Grouped per UID, checked after the per-component pass.
  let groups : Map[String, Array[@model.Component]] = Map([])
  for root in roots {
    for child in root.children {
      if child.kind == "VEVENT" {
        let uid = match child.property("UID") {
          Some(line) => line.value
          None => ""
        }
        match groups.get(uid) {
          Some(group) => group.push(child)
          None => groups[uid] = [child]
        }
      }
    }
  }
  for _uid, group in groups {
    let verdict = check_series_types(group, zones~)
    if verdict != "" {
      return Some(verdict)
    }
  }
  None
}

///|
/// Precondition element, or `""` when the component is readable.
fn check_vevent(child : @model.Component, zones~ : @model.ZoneTable) -> String {
  let reject_data = "<C:valid-calendar-data/>"
  let parsed = child.event(zones~) catch { _ => return reject_data }
  // A degenerate `VEVENT` without `DTSTART` is tolerated by evaluation
  // (R8) and poisons nothing — keep accepting it.
  match child.property("RRULE") {
    Some(line) => {
      let rule = @rrule.parse_rule(line.value) catch { _ => return reject_data }
      // The expansion is what evaluation runs at query time; running one
      // step here turns its refusals (ordinal WEEKLY, COUNT+UNTIL,
      // UNTIL type mismatch, the period budget of a never-matching rule)
      // into a 403 instead of a 500 on every later report.
      let dtstart = try {
        match child.property("DTSTART") {
          Some(dtline) => @model.parse_date_time(dtline, zones)
          None => raise FilterError::InvalidCalendarData
        }
      } catch {
        _ => return reject_data
      }
      ignore(@rrule.expand(rule, dtstart, limit=1)) catch {
        _ => return reject_data
      }
      ignore(parsed)
    }
    None => ()
  }
  ""
}

///|
/// `VTODO` / `VJOURNAL` / `VFREEBUSY`: the temporal properties are parsed
/// exactly like the evaluation parses them, and a recurring non-`VEVENT`
/// component is refused with the component-set precondition — evaluation
/// answers "recurring VTODO time-range is not implemented" for those, so
/// storing one poisons time-range reports.
fn check_non_event(
  child : @model.Component,
  zones~ : @model.ZoneTable,
) -> String {
  let reject_set = "<C:valid-calendar-object-resource/>"
  let reject_data = "<C:valid-calendar-data/>"
  if child.property("RRULE") is Some(_) ||
    child.property("RDATE") is Some(_) ||
    child.property("RECURRENCE-ID") is Some(_) {
    return reject_set
  }
  for name in ["DTSTART", "DTEND", "DUE", "COMPLETED", "CREATED"] {
    match child.property(name) {
      Some(line) => {
        let parsed = @model.parse_date_time(line, zones) catch {
          _ => return reject_data
        }
        ignore(parsed)
      }
      None => ()
    }
  }
  if child.kind == "VTODO" {
    let state = check_vtodo_states(child, zones~)
    if state != "" {
      return state
    }
  } else {
    match child.property("DURATION") {
      Some(line) => {
        let parsed = @model.parse_duration(
          line.value,
          line_no=0,
          raw=line.value,
        ) catch {
          _ => return reject_data
        }
        ignore(parsed)
      }
      None => ()
    }
  }
  ""
}

///|
/// Mirror of the two `VTODO` state raises in `todo_overlaps`: `DURATION`
/// needs exactly `DTSTART` (no `DUE`), and `DUE` must not precede
/// `DTSTART` (RFC 5545). Violations fail every time-range report with a
/// 500 today — the door turns them into the data precondition.
fn check_vtodo_states(
  child : @model.Component,
  zones~ : @model.ZoneTable,
) -> String {
  let reject = "<C:valid-calendar-data/>"
  let mut start : Int64? = None
  let mut due : Int64? = None
  let mut duration : Int64? = None
  match child.property("DTSTART") {
    Some(line) => {
      let dt = @model.parse_date_time(line, zones) catch { _ => return reject }
      start = Some(dt.instant_seconds())
    }
    None => ()
  }
  match child.property("DUE") {
    Some(line) => {
      let d = @model.parse_date_time(line, zones) catch { _ => return reject }
      due = Some(d.instant_seconds())
    }
    None => ()
  }
  match child.property("DURATION") {
    Some(line) => {
      let d = @model.parse_duration(line.value, line_no=0, raw=line.value) catch {
        _ => return reject
      }
      duration = Some(d)
    }
    None => ()
  }
  // (start <= DTSTART+DURATION ...) row requires the DTSTART+DURATION
  // pairing; the due row requires no DURATION beside it.
  if duration is Some(_) && (start is None || due is Some(_)) {
    return reject
  }
  match (start, due) {
    (Some(s), Some(u)) => if u < s { return reject }
    _ => ()
  }
  ""
}

///|
/// Mirror of `expand_series_query`'s type-agreement raise: within one UID
/// group, the master `DTSTART` fixes the (all-day, floating) shape, and
/// every override's `RECURRENCE-ID` and `DTSTART` must share it. A
/// disagreement fails every time-range report over the collection with a
/// 500 today — the door refuses it as invalid data instead.
fn check_series_types(
  group : Array[@model.Component],
  zones~ : @model.ZoneTable,
) -> String {
  let reject = "<C:valid-calendar-data/>"
  let mut master_type : (Bool, Bool)? = None
  for child in group {
    if child.property("RECURRENCE-ID") is None {
      match child.property("DTSTART") {
        Some(line) => {
          let dt = @model.parse_date_time(line, zones) catch {
            _ => return reject
          }
          if master_type is None {
            master_type = Some((dt.all_day, dt.is_floating()))
          }
        }
        None => ()
      }
    }
  }
  match master_type {
    None => ""
    Some((all_day, floating)) => {
      for child in group {
        for name in ["RECURRENCE-ID", "DTSTART"] {
          match child.property(name) {
            Some(line) => {
              let dt = @model.parse_date_time(line, zones) catch {
                _ => return reject
              }
              if dt.all_day != all_day || dt.is_floating() != floating {
                return reject
              }
            }
            None => ()
          }
        }
      }
      ""
    }
  }
}
