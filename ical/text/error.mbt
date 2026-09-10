///|
/// A line-level iCalendar parse failure.
///
/// `BadLine` is raised by the content-line and component layers: `line_no` is
/// 1-based over *logical* (unfolded) lines and `line` keeps the offending
/// text, so a caller can point a user at the exact place a feed broke instead
/// of just reporting "invalid iCalendar". `BadRule` is raised by value-level
/// parsers such as `@rrule.parse_rule`, where a whole `RRULE` value is the
/// unit of failure and no line context applies.
pub(all) suberror ParseError {
  BadLine(line_no~ : Int, line~ : String, message~ : String)
  BadRule(rule~ : String, message~ : String)
} derive(Debug, Eq)

///|
pub impl Show for ParseError with fn output(self, logger) {
  match self {
    BadLine(line_no=no, line~, message=msg) =>
      logger.write_string("line \{no}: \{msg} (in `\{line}`)")
    BadRule(rule~, message=msg) =>
      logger.write_string("invalid RRULE: \{msg} (in `\{rule}`)")
  }
}
