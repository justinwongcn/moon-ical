///|
fn calendar_benchmark_text() -> String {
  let input = StringBuilder()
  input.write_string("BEGIN:VCALENDAR\r\n")
  for i in 0..<1000 {
    input.write_string(
      "BEGIN:VEVENT\r\n" +
      "UID:event-\{i}\r\n" +
      "SUMMARY;LANGUAGE=en;X-LABEL=\"team,a\":Planning \\, review\r\n" +
      "DTSTART;TZID=Asia/Shanghai:20260908T093000\r\n" +
      "END:VEVENT\r\n",
    )
  }
  input.write_string("END:VCALENDAR\r\n")
  input.to_string()
}

///|
test "bench parse_calendar events=1000" (it : @bench.T) {
  let input = calendar_benchmark_text()
  it.bench(() => {
    let calendar = try! @model.parse_calendar(input)
    it.keep(calendar)
  })
}
