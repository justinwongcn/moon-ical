///|
/// One parsed property line: `NAME;PARAM=VAL;PARAM2="A,B":value`.
///
/// `value` is still the escaped form as it appears on the wire; call
/// [`unescape_value`] to get the text a human should see.
pub struct ContentLine {
  name : String
  params : Array[PropertyParam]
  value : String
} derive(Debug, Eq)

///|
/// A single parameter of a content line, with surrounding quotes already
/// stripped from its value.
pub struct PropertyParam {
  name : String
  value : String
} derive(Debug, Eq)

///|
/// Parse one logical (already unfolded) content line.
///
/// Raises [`ParseError`] when there is no value separator or the property name
/// is missing — either way the text is not a usable iCalendar property.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let line = @text.parse_content_line(
///     "DTSTART;TZID=Asia/Shanghai:20260908T093000", 1,
///   )
///   assert_eq(line.name, "DTSTART")
///   assert_eq(line.params[0].value, "Asia/Shanghai")
///   assert_eq(line.value, "20260908T093000")
/// }
/// ```
pub fn parse_content_line(line : String, line_no : Int) -> ContentLine raise {
  let chars = line.to_array()
  let n = chars.length()
  // The first ':' outside a quoted param value starts the value. A ':' inside
  // quotes belongs to that parameter, so splitting on ':' blindly is wrong.
  let mut colon = -1
  let mut quoted = false
  let mut i = 0
  while i < n && colon < 0 {
    let c = chars[i]
    if c == '"' {
      quoted = !quoted
    } else if c == ':' && !quoted {
      colon = i
    }
    i = i + 1
  }
  if colon < 0 {
    raise ParseError::BadLine(line_no~, line~, message="no ':' value separator")
  }
  let head = String::from_array(chars[0:colon])
  let value = String::from_array(chars[colon + 1:n])
  let parts = split_unquoted(head, ';')
  let name = String::to_upper(trim_ascii(parts[0]))
  if name.length() == 0 {
    raise ParseError::BadLine(line_no~, line~, message="empty property name")
  }
  let params : Array[PropertyParam] = []
  for raw in parts[1:] {
    let eq = find_unquoted(raw, '=')
    if eq < 0 {
      raise ParseError::BadLine(
        line_no~,
        line~,
        message="parameter without '=': \{raw}",
      )
    }
    let raw_chars = raw.to_array()
    let rn = raw_chars.length()
    let pname = String::to_upper(
      trim_ascii(String::from_array(raw_chars[0:eq])),
    )
    let pvalue = unquote(trim_ascii(String::from_array(raw_chars[eq + 1:rn])))
    params.push({ name: pname, value: pvalue, })
  }
  { name, params, value, }
}

///|
/// Trim surrounding spaces and horizontal tabs, returning a `String`.
///
/// Deliberately not built on `String::trim`: that yields a `StringView`, and
/// `StringView::data` hands back the *whole* string being viewed rather than
/// the viewed slice, which would silently un-trim the value.
fn trim_ascii(s : String) -> String {
  let chars = s.to_array()
  let n = chars.length()
  let mut first = 0
  let mut last = n
  while first < last && (chars[first] == ' ' || chars[first] == '\t') {
    first = first + 1
  }
  while last > first && (chars[last - 1] == ' ' || chars[last - 1] == '\t') {
    last = last - 1
  }
  if first == 0 && last == n {
    s
  } else {
    String::from_array(chars[first:last])
  }
}

///|
/// The value of the first parameter with this name (`TZID`, `VALUE`, ...).
/// Parameter names were normalised to upper case while parsing, and the lookup
/// key is normalised the same way, so callers can pass either spelling.
pub fn ContentLine::param(self : ContentLine, name : String) -> String? {
  let want = String::to_upper(name)
  let mut found : String? = None
  for p in self.params {
    if p.name == want {
      found = Some(p.value)
      break
    }
  }
  found
}

///|
/// Turn the RFC 5545 escaped text of a property value into display text.
///
/// `\\n` and `\\N` both mean a newline (the latter is common in Apple feeds),
/// `\\,` and `\\;` are literal delimiters, `\\\\` is a literal backslash. An
/// unknown escape is passed through rather than dropped, so odd feed data
/// still survives a parse.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() {
///   assert_eq(
///     @text.unescape_value("Team sync\\, 2026\\nRoom B"),
///     "Team sync, 2026\nRoom B",
///   )
/// }
/// ```
pub fn unescape_value(value : String) -> String {
  let out : Array[Char] = []
  let chars = value.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '\\' && i + 1 < n {
      let esc = chars[i + 1]
      if esc == 'n' || esc == 'N' {
        out.push('\n')
        i = i + 2
      } else if esc == ',' || esc == ';' {
        out.push(esc)
        i = i + 2
      } else if esc == '\\' {
        out.push('\\')
        i = i + 2
      } else {
        // Unknown escape: keep the backslash and continue after it.
        out.push(c)
        i = i + 1
      }
    } else {
      out.push(c)
      i = i + 1
    }
  }
  String::from_array(out)
}

///|
/// Escape text for use as a property value, the inverse of
/// [`unescape_value`]: a newline becomes `\n`, and a literal comma,
/// semicolon, or backslash gains its backslash. Characters that need no
/// escape pass through untouched.
///
/// Parsed values keep their escaped wire form, so a round trip through
/// parse and serialize never calls this — it is for *building* content
/// from plain text.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() {
///   assert_eq(
///     @text.escape_value("Team sync, 2026\nRoom B"),
///     "Team sync\\, 2026\\nRoom B",
///   )
/// }
/// ```
pub fn escape_value(text : String) -> String {
  let out : Array[Char] = []
  for c in text.to_array() {
    if c == '\n' {
      out.push('\\')
      out.push('n')
    } else if c == ',' || c == ';' || c == '\\' {
      out.push('\\')
      out.push(c)
    } else {
      out.push(c)
    }
  }
  String::from_array(out)
}

///|
/// Split on `sep`, ignoring separators that sit inside double quotes.
fn split_unquoted(s : String, sep : Char) -> Array[String] {
  let chars = s.to_array()
  let parts : Array[String] = []
  let n = chars.length()
  let mut quoted = false
  let mut start = 0
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '"' {
      quoted = !quoted
    } else if c == sep && !quoted {
      parts.push(String::from_array(chars[start:i]))
      start = i + 1
    }
    i = i + 1
  }
  parts.push(String::from_array(chars[start:n]))
  parts
}

///|
/// Index of `target` outside double quotes, or -1 when it is absent.
fn find_unquoted(s : String, target : Char) -> Int {
  let chars = s.to_array()
  let mut quoted = false
  let mut found = -1
  let mut i = 0
  while i < chars.length() && found < 0 {
    let c = chars[i]
    if c == '"' {
      quoted = !quoted
    } else if c == target && !quoted {
      found = i
    }
    i = i + 1
  }
  found
}

///|
/// Strip one layer of surrounding double quotes.
fn unquote(s : String) -> String {
  let chars = s.to_array()
  let n = chars.length()
  if n >= 2 && chars[0] == '"' && chars[n - 1] == '"' {
    String::from_array(chars[1:n - 1])
  } else {
    s
  }
}
