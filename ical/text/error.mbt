///|
/// A line-level iCalendar parse failure.
///
/// `line_no` is 1-based over *logical* (unfolded) lines and `line` keeps the
/// offending text, so a caller can point a user at the exact place a feed
/// broke instead of just reporting "invalid iCalendar".
pub(all) suberror ParseError {
  BadLine(line_no~ : Int, line~ : String, message~ : String)
} derive(Debug, Eq)

///|
pub impl Show for ParseError with fn output(self, logger) {
  match self {
    BadLine(line_no=no, line~, message=msg) =>
      logger.write_string("line \{no}: \{msg} (in `\{line}`)")
  }
}
