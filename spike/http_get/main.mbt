///|
/// M0 spike: verify `@http.get` against real URLs on this machine, on both
/// supported targets:
///
///   moon run spike/http_get --target js
///   moon run spike/http_get --target native
///
/// URL 1 is the connectivity control; URL 2/3 are real .ics feeds.
/// Per-URL failures are isolated so one unreachable host does not kill the run.
async fn probe_url(url : String) -> String {
  try {
    let (response, body) = @http.get(url)
    let text = body.text()
    "code=\{response.code} bytes=\{text.length()} is_ics=\{text.has_prefix("BEGIN:VCALENDAR")}"
  } catch {
    err => "FAILED: \{err}"
  }
}

///|
async fn main {
  let urls : Array[String] = [
    "https://www.moonbitlang.com", "https://calendar.google.com/calendar/ical/zh.china%23holiday%40group.v.calendar.google.com/public/basic.ics",
    "https://www.calendarlabs.com/ical-calendar/ics/76/US_Holidays.ics",
  ]
  for url in urls {
    let result = probe_url(url)
    println("[\{url}]\n  \{result}")
  }
}
