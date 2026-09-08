///|
/// One iCalendar component: its kind, its own properties in wire order, and
/// any nested components. Nesting is real (`VALARM` lives inside `VEVENT`,
/// `VEVENT` inside `VCALENDAR`), so the model keeps a tree instead of a flat
/// list, and properties stay in the order the feed sent them.
pub struct Component {
  kind : String
  properties : Array[@text.ContentLine]
  children : Array[Component]
} derive(Debug, Eq)

///|
/// The first property with this name, if the component carries one.
pub fn Component::property(
  self : Component,
  name : String,
) -> @text.ContentLine? {
  let want = String::to_upper(name)
  let mut found : @text.ContentLine? = None
  for p in self.properties {
    if p.name == want {
      found = Some(p)
      break
    }
  }
  found
}

///|
/// Every property with this name — `EXDATE` and `RDATE` may be repeated, and
/// a single one may hold a comma-separated list.
pub fn Component::properties_named(
  self : Component,
  name : String,
) -> Array[@text.ContentLine] {
  let want = String::to_upper(name)
  let out : Array[@text.ContentLine] = []
  for p in self.properties {
    if p.name == want {
      out.push(p)
    }
  }
  out
}

///|
/// Build a component tree from already-unfolded logical lines.
///
/// Unknown components are preserved rather than dropped, so an unusual feed
/// loses no data. Unbalanced `BEGIN`/`END`, a mismatched `END` name, and a
/// property outside any component all raise [`@text.ParseError`] carrying the
/// offending line number.
///
/// # Example
/// ```mbt nocheck
/// fn test_example() raise {
///   let roots = @model.parse_components([
///     "BEGIN:VCALENDAR", "BEGIN:VEVENT", "SUMMARY:Sync", "END:VEVENT", "END:VCALENDAR",
///   ])
///   assert_eq(roots.length(), 1)
///   assert_eq(roots[0].children[0].properties[0].value, "Sync")
/// }
/// ```
pub fn parse_components(lines : Array[String]) -> Array[Component] raise {
  let roots : Array[Component] = []
  let open : Array[Component] = []
  let total = lines.length()
  for i in 0..<total {
    let raw = lines[i]
    let line_no = i + 1
    let line = @text.parse_content_line(raw, line_no)
    if line.name == "BEGIN" {
      open.push({ kind: line.value.to_upper(), properties: [], children: [], })
    } else if line.name == "END" {
      match open.pop() {
        None =>
          raise @text.ParseError::BadLine(
            line_no~,
            line=raw,
            message="END without a matching BEGIN",
          )
        Some(done) =>
          if done.kind != line.value.to_upper() {
            raise @text.ParseError::BadLine(
              line_no~,
              line=raw,
              message="END \{line.value} closes \{done.kind}",
            )
          } else if open.length() == 0 {
            roots.push(done)
          } else {
            let last = open.length() - 1
            open[last].children.push(done)
          }
      }
    } else if open.length() == 0 {
      raise @text.ParseError::BadLine(
        line_no~,
        line=raw,
        message="property outside any component",
      )
    } else {
      let last = open.length() - 1
      open[last].properties.push(line)
    }
  }
  if open.length() > 0 {
    let last = open.length() - 1
    raise @text.ParseError::BadLine(
      line_no=lines.length(),
      line="",
      message="unclosed component: \{open[last].kind}",
    )
  }
  roots
}
