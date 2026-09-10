///|
/// RFC 5545 §3.1: lines of text SHOULD NOT be longer than 75 octets,
/// excluding the line break. Long content lines are folded — broken so
/// each continuation physical line starts with one WSP.
const FOLD_LIMIT : Int = 75

///|
/// Serialize a whole component forest back into iCalendar text:
/// `BEGIN:KIND`, every property line, every child component, `END:KIND`,
/// CRLF throughout (RFC 5545 §3.1), and every physical line within
/// [`FOLD_LIMIT`] octets.
///
/// Property values are written in their escaped wire form, exactly as
/// they were parsed — this layer folds, it does not re-escape — so a
/// feed that was parsed into a tree and written back out loses nothing.
/// Property and parameter names were normalised to upper case at parse
/// time and stay that way; parameter values whose content would read
/// back as structure (`,` `;` `:` `"`) are re-quoted.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let roots = @model.parse_components([
///     "BEGIN:VCALENDAR", "SUMMARY:Sync", "END:VCALENDAR",
///   ])
///   assert_eq(
///     @serialize.serialize_components(roots),
///     "BEGIN:VCALENDAR\r\nSUMMARY:Sync\r\nEND:VCALENDAR\r\n",
///   )
/// }
/// ```
pub fn serialize_components(roots : Array[@model.Component]) -> String {
  let pieces : Array[String] = []
  for root in roots {
    write_component(pieces, root)
  }
  join_pieces(pieces)
}

///|
/// Serialize a single root component; see [`serialize_components`].
pub fn serialize_component(root : @model.Component) -> String {
  let pieces : Array[String] = []
  write_component(pieces, root)
  join_pieces(pieces)
}

///|
/// Concatenate the already-terminated physical line pieces.
fn join_pieces(pieces : Array[String]) -> String {
  let out : Array[Char] = []
  for piece in pieces {
    for c in piece.to_array() {
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// One content line as `NAME;PARAM=VAL:value` text, folded so no
/// physical line exceeds [`FOLD_LIMIT`] octets and terminated with
/// CRLF. Parameter values containing `,` `;` `:` or `"` are quoted, so
/// parsing the output back yields the same `ContentLine` again.
pub fn serialize_content_line(line : @text.ContentLine) -> String {
  let chars : Array[Char] = []
  append_string(chars, line.name)
  for p in line.params {
    append_string(chars, ";")
    append_string(chars, p.name)
    append_string(chars, "=")
    if param_needs_quotes(p.value) {
      append_string(chars, "\"")
      append_string(chars, p.value)
      append_string(chars, "\"")
    } else {
      append_string(chars, p.value)
    }
  }
  append_string(chars, ":")
  append_string(chars, line.value)
  fold_line(chars)
}

///|
/// Append this component's lines to `pieces`, each piece one physical
/// line pair already CRLF-terminated.
fn write_component(
  pieces : Array[String],
  component : @model.Component,
) -> Unit {
  let begin : Array[Char] = []
  append_string(begin, "BEGIN:")
  append_string(begin, component.kind)
  pieces.push(fold_line(begin))
  for line in component.properties {
    pieces.push(serialize_content_line(line))
  }
  for child in component.children {
    write_component(pieces, child)
  }
  let end : Array[Char] = []
  append_string(end, "END:")
  append_string(end, component.kind)
  pieces.push(fold_line(end))
}

///|
/// Fold the characters of one logical line into physical lines and
/// terminate with CRLF. The first physical line takes up to
/// [`FOLD_LIMIT`] octets; each continuation starts with one space —
/// which counts toward its own budget, exactly as [`@text.unfold`]
/// expects when it strips that one space back off — and folds only
/// *between* characters, so a multi-byte character is never split.
fn fold_line(chars : Array[Char]) -> String {
  let out : Array[Char] = []
  let mut line_bytes = 0
  let mut first = true
  for c in chars {
    let width = utf8_len(c)
    let budget = if first { FOLD_LIMIT } else { FOLD_LIMIT - 1 }
    if line_bytes + width > budget {
      out.push('\r')
      out.push('\n')
      out.push(' ')
      line_bytes = 1
      first = false
    }
    out.push(c)
    line_bytes = line_bytes + width
  }
  out.push('\r')
  out.push('\n')
  String::from_array(out)
}

///|
/// Append every character of `text` to `out`.
fn append_string(out : Array[Char], text : String) -> Unit {
  for c in text.to_array() {
    out.push(c)
  }
}

///|
/// Bytes this character occupies in UTF-8.
fn utf8_len(c : Char) -> Int {
  let code = c.to_int()
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else if code < 0x10000 {
    3
  } else {
    4
  }
}

///|
/// Whether a parameter value needs surrounding double quotes when
/// written: any of the structural characters `,` `;` `:` or `"` would
/// otherwise be read back as structure rather than data.
fn param_needs_quotes(value : String) -> Bool {
  let mut needed = false
  for c in value.to_array() {
    if c == ',' || c == ';' || c == ':' || c == '"' {
      needed = true
    }
  }
  needed
}
