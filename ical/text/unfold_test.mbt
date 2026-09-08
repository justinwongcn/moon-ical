///|
test "unfold joins a continuation line and drops exactly one leading WSP" {
  let got = @text.unfold("DESCRIPTION:Line one\r\n more\r\nSUMMARY:Two")
  assert_eq(got, ["DESCRIPTION:Line onemore", "SUMMARY:Two"])
}

///|
test "unfold accepts a tab as a fold marker" {
  assert_eq(@text.unfold("A:1\n\t2\nB:3"), ["A:12", "B:3"])
}

///|
test "unfold chains multi-level folds onto one logical line" {
  // Each continuation consumes exactly one leading WSP, so the spaces here
  // are fold markers and disappear: RFC 5545 forbids inserting real spaces
  // at a fold point.
  assert_eq(@text.unfold("X:1\r\n 2\r\n 3\r\n 4"), ["X:1234"])
}

///|
test "bare LF and CRLF are both single terminators and agree" {
  let crlf = @text.unfold("A:1\r\nB:2\r\n")
  let lf = @text.unfold("A:1\nB:2\n")
  assert_eq(crlf, ["A:1", "B:2"])
  assert_eq(crlf, lf)
}

///|
test "a CR not followed by LF still ends a line" {
  assert_eq(@text.unfold("A:1\rB:2"), ["A:1", "B:2"])
}

///|
test "blank physical lines are dropped" {
  assert_eq(@text.unfold("A:1\r\n\r\n\r\nB:2"), ["A:1", "B:2"])
}

///|
test "empty input yields no logical lines" {
  assert_eq(@text.unfold(""), [])
}

///|
test "a fold marker with nothing to fold into keeps its data" {
  assert_eq(@text.unfold(" orphan"), ["orphan"])
}

///|
test "unfold keeps non-ascii payloads intact" {
  // The fold marker is one WSP, and unfolding removes it, so "会" joins
  // directly: multi-byte text must not be split by the byte-oriented scan.
  assert_eq(@text.unfold("SUMMARY:团队周\r\n 会"), ["SUMMARY:团队周会"])
}
