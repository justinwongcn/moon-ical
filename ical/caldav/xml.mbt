///|
/// A parsed XML element: local name (lowercased), attributes keyed by
/// lowercased local name, child elements, and the direct character data
/// between the element's own tags.
///
/// This is deliberately a *shape* parser, not a conforming XML processor. It
/// understands elements, attributes, self-closing tags, comments, the XML
/// declaration, and character data — exactly what a CalDAV `REPORT` body is
/// made of. Entities are not decoded and mixed content is flattened, because
/// no element this server reads carries either. Like the text extractor in
/// `caldav.mbt`, it never treats markup found inside a value as structure.
priv struct XmlElement {
  name : String
  attrs : Map[String, String]
  children : Array[XmlElement]
  /// Mutable because character data arrives after the element is already
  /// reachable from its parent: rebuilding the struct instead would leave the
  /// parent's copy stale and silently drop the text.
  mut text : String
}

///|
/// One start tag as scanned from the input: its local name, its attributes,
/// whether it closed itself, and the offset just past its `>`.
priv struct TagInfo {
  name : String
  attrs : Map[String, String]
  self_closing : Bool
  end : Int
}

///|
/// Parse the outermost element of an XML document, or `None` when no complete
/// element is present.
fn parse_xml_element(input : String) -> XmlElement? {
  let v = input.view()
  let n = v.length()
  let stack : Array[XmlElement] = []
  let mut root : XmlElement? = None
  let mut i = 0
  // Start of the character-data run being accumulated. Slicing at the next
  // tag avoids materialising text one code unit at a time.
  let mut run = 0
  while i < n {
    if v[i] != '<' {
      i = i + 1
      continue
    }
    flush_text(stack, v[run:i].to_owned())
    if i + 1 < n && v[i + 1] == '?' {
      // XML declaration or processing instruction: skip to its end.
      match find_after(v, i + 2, "?>") {
        Some(after) => i = after
        None => break
      }
    } else if i + 3 < n && v[i + 1] == '!' && v[i + 2] == '-' && v[i + 3] == '-' {
      match find_after(v, i + 4, "-->") {
        Some(after) => i = after
        None => break
      }
    } else if i + 1 < n && v[i + 1] == '!' {
      // DOCTYPE and friends: skip to the first `>`.
      match find_char(v, i, '>') {
        Some(gt) => i = gt + 1
        None => break
      }
    } else if i + 1 < n && v[i + 1] == '/' {
      match find_char(v, i, '>') {
        Some(gt) => {
          // The closing tag's own name is not re-checked: nesting is already
          // established by the open tags, and a CalDAV body is machine-written.
          match stack.pop() {
            Some(done) => if stack.length() == 0 { root = Some(done) }
            None => ()
          }
          i = gt + 1
        }
        None => break
      }
    } else {
      match scan_tag(v, i) {
        Some(tag) => {
          let element : XmlElement = {
            name: tag.name,
            attrs: tag.attrs,
            children: [],
            text: "",
          }
          if tag.self_closing {
            if stack.length() == 0 {
              root = Some(element)
            } else {
              let last = stack.length() - 1
              stack[last].children.push(element)
            }
          } else {
            if stack.length() > 0 {
              let last = stack.length() - 1
              stack[last].children.push(element)
            }
            stack.push(element)
          }
          i = tag.end
        }
        None => break
      }
    }
    run = i
  }
  root
}

///|
/// Append a character-data run to the element currently open, ignoring
/// whitespace-only runs so indentation between tags never becomes content.
fn flush_text(stack : Array[XmlElement], chunk : String) -> Unit {
  if stack.length() == 0 || chunk.trim().length() == 0 {
    return
  }
  let last = stack.length() - 1
  stack[last].text = stack[last].text + chunk
}

///|
/// The offset just past the first occurrence of `needle` at or after `from`,
/// or `None`.
fn find_after(v : StringView, from : Int, needle : String) -> Int? {
  let rest = v[from:]
  match rest.find(needle.view()) {
    Some(offset) => Some(from + offset + needle.length())
    None => None
  }
}

///|
/// The offset of the first `target` code unit at or after `from`, or `None`.
fn find_char(v : StringView, from : Int, target : UInt16) -> Int? {
  let n = v.length()
  for i in from..<n {
    if v[i] == target {
      return Some(i)
    }
  }
  None
}

///|
/// Scan one start tag beginning at `<`. Attribute values may contain `>` and
/// `/`, so the scan tracks quoting rather than stopping at the first one.
fn scan_tag(v : StringView, start : Int) -> TagInfo? {
  let n = v.length()
  let mut i = start + 1
  let name_start = i
  while i < n && !is_markup_space(v[i]) && v[i] != '>' && v[i] != '/' {
    i = i + 1
  }
  if i == name_start {
    return None
  }
  let name = local_part(v[name_start:i]).to_lower().to_owned()
  let attrs : Map[String, String] = Map([])
  let mut self_closing = false
  for ;; {
    while i < n && is_markup_space(v[i]) {
      i = i + 1
    }
    if i >= n {
      return None
    }
    if v[i] == '>' {
      i = i + 1
      break
    }
    if v[i] == '/' {
      self_closing = true
      i = i + 1
      while i < n && is_markup_space(v[i]) {
        i = i + 1
      }
      if i < n && v[i] == '>' {
        i = i + 1
      }
      break
    }
    let (attr, next) = scan_attribute(v, i)
    match attr {
      Some((key, value)) => attrs[key] = value
      None => ()
    }
    i = next
  }
  Some({ name, attrs, self_closing, end: i, })
}

///|
/// Scan one `name="value"` attribute pair and return the pair with the offset
/// where scanning resumes. A bare name (HTML-style) is read as an empty value.
fn scan_attribute(v : StringView, start : Int) -> ((String, String)?, Int) {
  let n = v.length()
  let mut i = start
  let name_start = i
  while i < n && v[i] != '=' && !is_markup_space(v[i]) && v[i] != '>' {
    i = i + 1
  }
  let name = local_part(v[name_start:i]).to_lower().to_owned()
  let mut j = i
  while j < n && is_markup_space(v[j]) {
    j = j + 1
  }
  if j >= n || v[j] != '=' {
    return (Some((name, "")), i)
  }
  j = j + 1
  while j < n && is_markup_space(v[j]) {
    j = j + 1
  }
  if j >= n || (v[j] != '"' && v[j] != '\'') {
    return (Some((name, "")), j)
  }
  let quote = v[j]
  j = j + 1
  let value_start = j
  while j < n && v[j] != quote {
    j = j + 1
  }
  let value = v[value_start:j].to_owned()
  if j < n {
    j = j + 1
  }
  (Some((name, value)), j)
}

///|
/// Whitespace between markup tokens — never inside a quoted value.
fn is_markup_space(c : UInt16) -> Bool {
  c is (' ' | '\t' | '\r' | '\n')
}

///|
/// The first descendant with this local name, searched breadth-first so the
/// shallowest match wins.
fn find_descendant(element : XmlElement, local_name : String) -> XmlElement? {
  if element.name == local_name {
    return Some(element)
  }
  for child in element.children {
    if child.name == local_name {
      return Some(child)
    }
  }
  for child in element.children {
    match find_descendant(child, local_name) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

///|
/// Whether this element has a direct child with this local name.
fn has_child(element : XmlElement, local_name : String) -> Bool {
  element.children.any(child => child.name == local_name)
}
