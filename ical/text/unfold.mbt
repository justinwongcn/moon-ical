///|
/// Restore RFC 5545 §3.1 folded lines into logical lines.
///
/// A physical line that continues the previous logical line begins with a
/// single WSP (space or horizontal tab); that one WSP is removed and the rest
/// of the text is appended to the previous line. Blank physical lines are
/// dropped, and both CRLF and bare LF are accepted as terminators because
/// real-world feeds are inconsistent about which they emit.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() {
///   let lines = @text.unfold("DESCRIPTION:Line one\r\n more\r\nSUMMARY:Two")
///   // The single leading WSP is consumed by unfolding, so "more" joins
///   // directly onto "Line one".
///   assert_eq(lines, ["DESCRIPTION:Line onemore", "SUMMARY:Two"])
/// }
/// ```
pub fn unfold(input : String) -> Array[String] {
  let logical : Array[String] = []
  let view = input.view()
  let n = view.length()
  let mut start = 0
  let mut i = 0
  while i < n {
    if view[i] == '\r' || view[i] == '\n' {
      push_physical(logical, view[start:i])
      // A CRLF pair is one terminator, not two.
      if view[i] == '\r' && i + 1 < n && view[i + 1] == '\n' {
        i = i + 2
      } else {
        i = i + 1
      }
      start = i
    } else {
      i = i + 1
    }
  }
  if start < n {
    push_physical(logical, view[start:])
  }
  logical
}

///|
/// Append one physical line: a leading WSP means it folds into the previous
/// logical line, otherwise it starts a new one. A fold marker with nothing to
/// fold into is kept as its own line rather than dropped, so malformed data
/// survives the parse instead of vanishing.
fn push_physical(logical : Array[String], physical : StringView) -> Unit {
  let is_fold = physical.length() > 0 &&
    (physical[0] == ' ' || physical[0] == '\t')
  if !is_fold {
    if physical.length() > 0 {
      logical.push(physical.to_owned())
    }
  } else {
    // Unfold drops exactly one leading WSP, then joins.
    let rest = physical[1:].to_owned()
    if logical.length() > 0 {
      let last = logical.length() - 1
      logical[last] = logical[last] + rest
    } else {
      logical.push(rest)
    }
  }
}
