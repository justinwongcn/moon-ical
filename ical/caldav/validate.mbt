///|
/// The `DAV:error` payload for a refused calendar-object body.
pub fn precondition_document(inner : String) -> String {
  error_document(inner)
}

///|
/// Which RFC 4791 §5.3.2 precondition a `PUT` body fails, if any — the
/// payload is the error element to put on the wire (`None` = acceptable).
///
/// The bar has two halves. The stored shape comes first: the collection
/// advertises a VEVENT-only `supported-calendar-component-set` (the
/// PROPFIND answer), so a body may carry exactly one entity type — RFC
/// 4791 §4.1 forbids more than one type per calendar object resource —
/// that entity must be the advertised `VEVENT`, and the body must not
/// carry the iCalendar `METHOD` property (§4.1's own MUST NOT; METHOD
/// marks an iTIP scheduling message, not a stored event). Mixing types
/// and `METHOD` answer `valid-calendar-object-resource`; a component the
/// collection does not list answers `supported-calendar-component`.
/// Second, evaluation readability: every `VEVENT`'s temporal properties
/// must parse against the body's own zone table and every `RRULE` must
/// be expandable. Anything the evaluation would fail closed on (500 with
/// the poison href named) is refused here with the precondition RFC 4791
/// §5.3.2 sanctions, so one bad `PUT` can no longer turn the
/// collection's reports into 500s.
pub fn calendar_object_precondition(body : String) -> String? {
  let roots = @model.parse_calendar(body) catch {
    _ => return Some("<C:valid-calendar-data/>")
  }
  // §4.1: a stored calendar object never carries METHOD.
  for root in roots {
    if root.property("METHOD") is Some(_) {
      return Some("<C:valid-calendar-object-resource/>")
    }
  }
  // The entity census, with §4.1's own VTIMEZONE exemption: VTIMEZONE
  // sits beside the VEVENT it backs and is never an entity type of its
  // own. An embedded VALARM is likewise a subcomponent of its VEVENT.
  let mut seen_event = false
  let mut seen_other = false
  for root in roots {
    for child in root.children {
      match child.kind {
        "VEVENT" => seen_event = true
        "VTODO" | "VJOURNAL" | "VFREEBUSY" => seen_other = true
        _ => ()
      }
    }
  }
  if seen_event && seen_other {
    // §4.1: "MUST NOT contain more than one type of calendar component".
    // The mixing violation is the resource-shape precondition; the
    // component-set precondition below covers the single-type case.
    return Some("<C:valid-calendar-object-resource/>")
  }
  if seen_other {
    // One non-VEVENT entity type: not in the advertised
    // supported-calendar-component-set, so the §5.3.2 precondition for
    // an unsupported component refuses it before it can be stored —
    // storing one would make the advertisement a lie for everything a
    // client reads back through the collection.
    return Some("<C:supported-calendar-component/>")
  }
  let zones = @model.ZoneTable::with_builtin(@model.build_zone_table(roots))
  for root in roots {
    for child in root.children {
      if child.kind == "VEVENT" {
        let verdict = check_vevent(child, zones~)
        if verdict != "" {
          return Some(verdict)
        }
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
