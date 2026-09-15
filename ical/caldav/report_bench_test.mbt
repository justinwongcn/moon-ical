///|
fn report_benchmark_case() -> (String, Array[@caldav.DavResource]) {
  let body = StringBuilder()
  body.write_string("<C:calendar-multiget>")
  let resources : Array[@caldav.DavResource] = []
  for i in 0..<500 {
    let href = "/cal/event-\{i}.ics"
    body.write_string("<D:href>\{href}</D:href>")
    resources.push({
      href,
      etag: "etag-\{i}",
      calendar_data: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
    })
  }
  body.write_string("</C:calendar-multiget>")
  (body.to_string(), resources)
}

///|
test "bench calendar-multiget hrefs=500 resources=500" (it : @bench.T) {
  let (body, resources) = report_benchmark_case()
  it.bench(() => {
    let response = @caldav.report(body, resources)
    it.keep(response)
  })
}
