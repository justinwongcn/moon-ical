///|
/// One RFC-folded logical line: 75 octets of payload, then CRLF + one
/// space, `folds` times. The size the server's own 10MB body cap admits
/// makes the difference between a linear and a quadratic unfold the
/// difference between milliseconds and minutes.
fn folded_benchmark_text(folds : Int32) -> String {
  let input = StringBuilder()
  for _ in 0..<folds {
    input.write_string(
      "01234567890123456789012345678901234567890123456789012345678901234567890123\r\n ",
    )
  }
  input.to_string()
}

///|
test "bench unfold one folded line folds=10000" (it : @bench.T) {
  let input = folded_benchmark_text(10000)
  it.bench(() => {
    let lines = @text.unfold(input)
    it.keep(lines)
  })
}
