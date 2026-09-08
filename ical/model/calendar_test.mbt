///|
test "nested components become a tree" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "SUMMARY:Sync", "BEGIN:VALARM",
    "ACTION:DISPLAY", "END:VALARM", "END:VEVENT", "END:VCALENDAR",
  ])
  assert_eq(roots.length(), 1)
  let cal = roots[0]
  assert_eq(cal.kind, "VCALENDAR")
  // VCALENDAR's own properties and its children are kept apart.
  assert_eq(cal.properties.length(), 1)
  assert_eq(cal.children.length(), 1)
  let event = cal.children[0]
  assert_eq(event.kind, "VEVENT")
  assert_eq(event.properties[0].value, "Sync")
  assert_eq(event.children[0].kind, "VALARM")
}

///|
test "component names are case-insensitive" {
  let roots = @model.parse_components(["begin:vcalendar", "end:VCALENDAR"])
  assert_eq(roots[0].kind, "VCALENDAR")
}

///|
test "unknown components are preserved, not dropped" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:X-WIDGET", "FROB:1", "END:X-WIDGET", "END:VCALENDAR",
  ])
  assert_eq(roots[0].children[0].kind, "X-WIDGET")
  assert_eq(roots[0].children[0].properties[0].value, "1")
}

///|
test "several sibling components are all returned" {
  let roots = @model.parse_components([
    "BEGIN:VCALENDAR", "BEGIN:VEVENT", "SUMMARY:A", "END:VEVENT", "BEGIN:VEVENT",
    "SUMMARY:B", "END:VEVENT", "END:VCALENDAR",
  ])
  assert_eq(roots[0].children.length(), 2)
  assert_eq(roots[0].children[1].properties[0].value, "B")
}

///|
test "END without a matching BEGIN is reported with its line number" {
  let outcome = try {
    let _ = @model.parse_components(["END:VEVENT"])
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("line 1"))
  assert_true(outcome.contains("END without a matching BEGIN"))
}

///|
test "a mismatched END name names both sides" {
  let outcome = try {
    let _ = @model.parse_components(["BEGIN:VCALENDAR", "END:VEVENT"])
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("line 2"))
  assert_true(outcome.contains("END VEVENT closes VCALENDAR"))
}

///|
test "a property outside any component is rejected" {
  let outcome = try {
    let _ = @model.parse_components(["SUMMARY:orphan"])
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("property outside any component"))
}

///|
test "an unclosed component is reported at the end of the stream" {
  let outcome = try {
    let _ = @model.parse_components(["BEGIN:VCALENDAR", "VERSION:2.0"])
    "no-error"
  } catch {
    err => err.to_string()
  }
  assert_true(outcome.contains("unclosed component: VCALENDAR"))
}

///|
test "an empty stream yields no components" {
  assert_eq(@model.parse_components([]), [])
}
