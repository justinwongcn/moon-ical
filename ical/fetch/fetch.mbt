///|
/// A fetch failure: the server answered, but not with a usable calendar.
///
/// Network-level failures (DNS, TLS, timeout) surface as `@http`'s own
/// errors; this covers the "got a response we cannot use" case, so callers
/// see the status code and the URL instead of a misleading parse error that
/// would come from feeding an HTML error page into the parser.
pub(all) suberror FetchError {
  BadStatus(status~ : Int, url~ : String)
} derive(Debug, Eq)

///|
pub impl Show for FetchError with fn output(self, logger) {
  match self {
    BadStatus(status~, url~) =>
      logger.write_string("fetch \{url}: unexpected status \{status}")
  }
}

///|
/// Fetch an iCalendar feed over HTTP(S) — pipeline stage ① 取件.
///
/// Thin on purpose: `@http.get` plus a status check, returning the body
/// verbatim. Every parsing concern belongs to `ical/text` / `ical/model`,
/// and this layer never guesses. Redirects, auth and retries are upstream
/// `@async/http` concerns (seam S3 in docs/upstream-seams.md). Network tests
/// stay out of CI by policy — feeds are flaky, fixtures are not; the live
/// acceptance for this layer is the demo's URL mode.
pub async fn fetch_ics(url : String) -> String {
  let (response, body) = @http.get(url)
  if response.code != 200 {
    raise FetchError::BadStatus(status=response.code, url~)
  }
  body.text()
}
