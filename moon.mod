// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "justinwongcn/moon-ical"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/justinwongcn/moon-ical"

license = "Apache-2.0"

keywords = [ "icalendar", "calendar", "caldav", "rrule", "rfc5545" ]

preferred_target = "wasm"

description = "iCalendar (RFC 5545) parsing, recurrence expansion, and a minimal CalDAV server in pure MoonBit"

import {
  "moonbitlang/async@0.21.2",
  "moonbitlang/x@0.5.1",
}
