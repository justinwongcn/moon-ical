///|
/// How long an unfolded logical line the UID scan will keep assembling.
/// UID values are short (RFC 5545 recommends 75 octets), so an assembled
/// line past this cap stops accumulating — a megabyte-long fold must not
/// turn the scan quadratic through string concatenation, and a UID that
/// long is not one this check needs to catch anyway.
const UID_LINE_CAP : Int32 = 4096

///|
/// The first `UID` property value in a stored calendar text, or `None`.
///
/// A content-line scan, not a full calendar parse: the PUT path needs
/// the UID of every file already in the collection, and a full parse of
/// each one on every write would make a single `PUT` cost O(collection)
/// parses. The scan unfolds folded lines (RFC 5545 §3.1) and reads the
/// first property whose name — everything before the first `;` or `:`,
/// uppercased the same way the text layer normalizes — is `UID`. For a
/// resource stored through the door that is the master's UID (§4.1
/// keeps one entity type per resource and a series shares its UID); a
/// hand-seeded file carrying several UIDs contributes its first, which
/// errs toward refusing a write rather than letting a duplicate in.
pub fn first_uid(text : String) -> String? {
  let v = text.to_string_view()
  let n = v.length()
  let mut i = 0
  let mut line = ""
  while i < n {
    let mut j = i
    while j < n && v[j] != '\n' {
      j = j + 1
    }
    let raw = v[i:j]
    i = j + 1
    if raw.length() > 0 && (raw[0] == ' ' || raw[0] == '\t') {
      // A folded continuation: drop the single leading whitespace and
      // join onto the line being assembled.
      if line.length() < UID_LINE_CAP {
        line = line + trim_cr(raw[1:]).to_owned()
      }
      continue
    }
    match uid_of_line(line) {
      Some(uid) => return Some(uid)
      None => ()
    }
    line = trim_cr(raw).to_owned()
  }
  uid_of_line(line)
}

///|
/// The UID value of one assembled content line, or `None` when the line
/// is not a UID property.
fn uid_of_line(line : String) -> String? {
  let v = line.to_string_view()
  let n = v.length()
  // The property name ends at the first `;` (parameters follow) or `:`
  // (the value separator every property must carry).
  let mut k = 0
  while k < n && v[k] != ':' && v[k] != ';' {
    k = k + 1
  }
  if k == n || v[k] == ';' {
    // Either no separator at all, or parameters without a visible value
    // separator in the name scan — find the ':' behind the parameters.
    let mut colon = k
    while colon < n && v[colon] != ':' {
      colon = colon + 1
    }
    if colon == n {
      return None
    }
    if v[:k].to_owned().to_upper() != "UID" {
      return None
    }
    return value_after(v, colon)
  }
  if v[:k].to_owned().to_upper() != "UID" {
    return None
  }
  value_after(v, k)
}

///|
/// The property value: everything past the `:` at `sep`, verbatim, and
/// never empty — an empty UID cannot conflict with anything.
fn value_after(v : StringView, sep : Int32) -> String? {
  let value = v[sep + 1:v.length()].to_owned()
  if value is "" {
    return None
  }
  Some(value)
}

///|
/// Trim one trailing carriage return from a raw line view.
fn trim_cr(raw : StringView) -> StringView {
  if raw.length() > 0 && raw[raw.length() - 1] == '\r' {
    raw[:raw.length() - 1]
  } else {
    raw
  }
}

///|
/// Which conflicting href a `PUT` must be refused for under
/// `CALDAV:no-uid-conflict` (RFC 4791 §5.3.2.1), or `None`.
///
/// Two shapes violate the precondition: a body whose UID another
/// resource in the collection already holds — the payload names that
/// resource's href, as the precondition's DTD `(DAV:href)` prescribes —
/// and an overwrite of a resource whose UID differs from the body's,
/// where the conflicting resource is the one being written. A UID-less
/// body (the door's R8-shape tolerance) cannot conflict with anything.
pub fn uid_conflict(
  body_uid : String?,
  current_uid : String?,
  self_href : String,
  index : Map[String, String],
) -> String? {
  guard body_uid is Some(uid) else { return None }
  match current_uid {
    Some(existing) =>
      if existing != uid {
        return Some(
          "<C:no-uid-conflict><D:href>\{self_href}</D:href></C:no-uid-conflict>",
        )
      }
    None => ()
  }
  match index.get(uid) {
    Some(href) =>
      return Some(
        "<C:no-uid-conflict><D:href>\{href}</D:href></C:no-uid-conflict>",
      )
    None => None
  }
}
