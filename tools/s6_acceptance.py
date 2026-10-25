#!/usr/bin/env python3
"""S6 live CalDAV acceptance: discovery, REPORT, and ETag conditions."""

import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "_build" / "native" / "debug" / "build" / "cmd" / "serve" / "serve.exe"
PORT = 8438
BASE = f"http://127.0.0.1:{PORT}"
EVENT = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:s6@moon-ical\r\nDTSTART:20260915T090000Z\r\nSUMMARY:S6\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
WORK_EVENT = EVENT.replace("UID:s6@moon-ical", "UID:s6-work@moon-ical")
failures = []


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def request(method, path, data=None, headers=()):
    cmd = ["curl", "-s", "-i", "-X", method, f"{BASE}{path}"]
    for header in headers:
        cmd += ["-H", header]
    if data is not None:
        cmd += ["--data-binary", data]
    raw = subprocess.run(cmd, capture_output=True, timeout=15, check=True).stdout
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    parsed = {}
    for line in lines[1:]:
        if b":" in line:
            key, value = line.split(b":", 1)
            parsed[key.lower().decode()] = value.strip().decode()
    return status, parsed, body.decode(errors="replace")


def wait_for_port():
    for _ in range(40):
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=1):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def main():
    subprocess.run(["moon", "build", "cmd/serve", "--target", "native"], cwd=ROOT, check=True)
    data_dir = tempfile.mkdtemp(prefix="moon-ical-s6-")
    log = open(Path(data_dir) / "server.log", "w", encoding="utf-8")
    server = subprocess.Popen([str(EXE), data_dir, str(PORT)], stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_for_port():
            print("server did not start")
            return 2
        print("S6 acceptance against a live CalDAV server:")
        code, headers, _ = request("OPTIONS", "/cal/")
        check("OPTIONS advertises calendar-access", code == 200 and "calendar-access" in headers.get("dav", ""))
        code, headers, _ = request("GET", "/.well-known/caldav")
        check("well-known redirects to /cal/", code == 301 and headers.get("location") == "/cal/")
        # The home collection follows the same canonical-URL rule as the
        # nested collections (RFC 4918 5.2): its bare form redirects, the
        # slashed form serves. Before S19 the home alone answered both.
        code, headers, _ = request("GET", "/cal")
        check("home URL without the slash redirects", code == 301 and headers.get("location") == "/cal/")
        code, _, _ = request("GET", "/cal/")
        check("home URL with the slash serves", code == 200)
        code, _, body = request("PROPFIND", "/", headers=["Depth: 0"])
        check("root discovers current principal", code == 207 and "/principals/default/" in body)
        code, _, body = request("PROPFIND", "/principals/default/", headers=["Depth: 0"])
        check("principal discovers calendar home", code == 207 and "calendar-home-set" in body and "/cal/" in body)

        code, headers, _ = request("PUT", "/cal/s6.ics", EVENT, ["If-None-Match: *"])
        tag = headers.get("etag", "")
        check("conditional create succeeds", code == 201 and bool(tag))
        code, _, _ = request("PUT", "/cal/s6.ics", EVENT, ["If-None-Match: *"])
        check("duplicate create is rejected", code == 412)
        code, _, _ = request("PUT", "/cal/s6.ics", EVENT, ["If-Match: \"wrong\""])
        check("stale update is rejected", code == 412)

        code, _, body = request("PROPFIND", "/cal/", headers=["Depth: 1"])
        check("Depth 1 lists event and ETag", code == 207 and "/cal/s6.ics" in body and tag.strip('"') in body)
        # Depth is an input the routing reads from the header, so a stub
        # hardcoding depth 1 must fail here: depth 0 and an unparseable
        # depth both answer the collection alone.
        code, _, body = request("PROPFIND", "/cal/", headers=["Depth: 0"])
        check("Depth 0 omits the events", code == 207 and "/cal/s6.ics" not in body)
        code, _, body = request("PROPFIND", "/cal/", headers=["Depth: infinity"])
        check("an unparseable Depth reads as 0", code == 207 and "/cal/s6.ics" not in body)
        # The filter is the defining part of a calendar-query (RFC 4791 §7.8),
        # so the request carries a real one and the checks assert the selection
        # it implies rather than merely that the event came back. The unfiltered
        # server could not tell these two requests apart.
        query = (
            '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop><D:getetag/><C:calendar-data/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
            '<C:time-range start="20260901T000000Z" end="20261001T000000Z"/>'
            '</C:comp-filter></C:comp-filter></C:filter>'
            '</C:calendar-query>'
        )
        code, _, body = request("REPORT", "/cal/", query, ["Content-Type: application/xml"])
        check("calendar-query inside the range selects the event", code == 207 and "UID:s6@moon-ical" in body)
        outside = query.replace("20260901T000000Z", "20300101T000000Z").replace("20261001T000000Z", "20300201T000000Z")
        code, _, body = request("REPORT", "/cal/", outside, ["Content-Type: application/xml"])
        check("calendar-query outside the range selects nothing", code == 207 and "UID:s6@moon-ical" not in body and "multistatus" in body)
        # A range that starts at or after it ends can never overlap; it is
        # an invalid filter (403 valid-filter), not an empty answer.
        inverted = (
            '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop><D:getetag/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
            '<C:time-range start="20261001T000000Z" end="20260901T000000Z"/>'
            '</C:comp-filter></C:comp-filter></C:filter>'
            '</C:calendar-query>'
        )
        code, _, body = request("REPORT", "/cal/", inverted, ["Content-Type: application/xml"])
        check("an inverted time-range is refused as valid-filter", code == 403 and "valid-filter" in body)
        # The report type is the root element, not a substring sniff: a
        # query whose text-match needle names the other report still runs
        # as a query and selects the matching event.
        named = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:s6-named@moon-ical\r\nDTSTART:20260915T090000Z\r\nSUMMARY:CALENDAR-MULTIGET\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        request("PUT", "/cal/named.ics", named, ["If-None-Match: *"])
        needle_query = (
            '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop><D:getetag/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
            '<C:prop-filter name="SUMMARY"><C:text-match>CALENDAR-MULTIGET</C:text-match></C:prop-filter>'
            '</C:comp-filter></C:comp-filter></C:filter>'
            '</C:calendar-query>'
        )
        code, _, body = request("REPORT", "/cal/", needle_query, ["Content-Type: application/xml"])
        check("a query naming the other report in its needle still queries", code == 207 and "/cal/named.ics" in body)
        request("DELETE", "/cal/named.ics")
        no_filter = '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop></C:calendar-query>'
        code, _, body = request("REPORT", "/cal/", no_filter, ["Content-Type: application/xml"])
        check("calendar-query without a filter is refused", code == 403 and "valid-filter" in body)
        unsupported = query.replace('name="VEVENT"', 'name="X-NOT-A-COMPONENT"')
        code, _, body = request("REPORT", "/cal/", unsupported, ["Content-Type: application/xml"])
        check("calendar-query on an unknown component is refused", code == 403 and "supported-filter" in body)
        multiget = '<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav"><D:href xmlns:D="DAV:">/cal/s6.ics</D:href></C:calendar-multiget>'
        code, _, body = request("REPORT", "/cal/", multiget, ["Content-Type: application/xml"])
        check("calendar-multiget returns selected event", code == 207 and "/cal/s6.ics" in body)
        miss = multiget.replace("/cal/s6.ics", "/cal/nothere.ics")
        code, _, body = request("REPORT", "/cal/", miss, ["Content-Type: application/xml"])
        check("multiget for a missing href selects nothing", code == 207 and "/cal/s6.ics" not in body and "multistatus" in body)
        # A missing href is answered per-href with 404 (RFC 4791 multiget
        # shape), so a client can tell "absent" from "deleted"; before S26
        # it was silently dropped. Both hrefs of a mixed request get their
        # own response element: 200 with data, 404 without.
        mixed = multiget.replace("</C:calendar-multiget>", "<D:href xmlns:D=\"DAV:\">/cal/nothere.ics</D:href></C:calendar-multiget>")
        code, _, body = request("REPORT", "/cal/", mixed, ["Content-Type: application/xml"])
        check("a mixed multiget answers 200 and per-href 404", code == 207 and "404 Not Found" in body and "/cal/nothere.ics" in body and "calendar-data" in body)
        # Every test of a comp-filter applies to ONE component instance
        # (RFC 4791 9.7.1). k2a overlaps January but is not named k2beta;
        # k2beta is named k2beta but sits in June. Judging the time-range
        # over the whole resource let k2a's overlap satisfy k2beta's
        # filter, so the January+name query must select nothing.
        k2a = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:k2a@moon-ical\r\nSUMMARY:k2alpha\r\nDTSTART:20260110T120000Z\r\nDTEND:20260110T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        k2beta = k2a.replace("UID:k2a@moon-ical", "UID:k2b@moon-ical").replace("SUMMARY:k2alpha", "SUMMARY:k2beta").replace("20260110", "20260610")
        request("PUT", "/cal/k2a.ics", k2a, ["If-None-Match: *"])
        request("PUT", "/cal/k2beta.ics", k2beta, ["If-None-Match: *"])
        both = (
            '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop><D:getetag/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
            '<C:time-range start="20260101T000000Z" end="20260201T000000Z"/>'
            '<C:prop-filter name="SUMMARY"><C:text-match>k2beta</C:text-match></C:prop-filter>'
            '</C:comp-filter></C:comp-filter></C:filter>'
            '</C:calendar-query>'
        )
        code, _, body = request("REPORT", "/cal/", both, ["Content-Type: application/xml"])
        check("no single instance satisfies both tests", code == 207 and "k2a" not in body and "k2beta" not in body and "multistatus" in body)
        june = both.replace("20260101T000000Z", "20260601T000000Z").replace("20260201T000000Z", "20260701T000000Z")
        code, _, body = request("REPORT", "/cal/", june, ["Content-Type: application/xml"])
        check("the June instance satisfies both tests", code == 207 and "/cal/k2beta.ics" in body and "k2a" not in body)
        request("DELETE", "/cal/k2a.ics")
        request("DELETE", "/cal/k2beta.ics")
        # A write on the collection itself is a method miss, not a write.
        code, hdrs, _ = request("PUT", "/cal/", "x")
        check("PUT on the home collection is 405 with Allow", code == 405 and "PROPFIND" in hdrs.get("allow", ""))

        # MKCALENDAR has to produce a collection that is then usable, so this
        # walks create, discover, write, query-scoped-to-it, and remove.
        code, _, _ = request("MKCALENDAR", "/cal/work/")
        check("MKCALENDAR creates a collection", code == 201)
        code, _, _ = request("MKCALENDAR", "/cal/work/")
        check("MKCALENDAR on an existing collection is 405", code == 405)
        code, _, body = request("PROPFIND", "/cal/", headers=["Depth: 1"])
        check("Depth 1 discovers the created collection", code == 207 and "/cal/work/" in body)
        code, _, _ = request("PUT", "/cal/work/w.ics", WORK_EVENT, ["If-None-Match: *"])
        check("PUT into the created collection succeeds", code == 201)
        code, _, body = request("PROPFIND", "/cal/work/", headers=["Depth: 1"])
        check("the created collection lists its own event", code == 207 and "/cal/work/w.ics" in body)
        code, _, body = request("REPORT", "/cal/work/", query, ["Content-Type: application/xml"])
        check("calendar-query is scoped to the collection", code == 207 and "UID:s6-work@moon-ical" in body and "UID:s6@moon-ical" not in body)
        # A collection URL without its trailing slash redirects to the
        # canonical form instead of routing the collection into the event
        # methods (which PUT/DELETE a directory: 500 on Windows, a silent
        # rmdir of an empty collection on POSIX).
        code, hdrs, _ = request("GET", "/cal/work")
        check("collection URL without the slash redirects", code == 301 and hdrs.get("location") == "/cal/work/")
        code, _, _ = request("GET", "/cal/missing.ics")
        check("a missing event without a slash is a plain 404", code == 404)
        code, _, _ = request("DELETE", "/cal/work/")
        check("deleting a non-empty collection is refused", code == 409)
        code, _, _ = request("DELETE", "/cal/work/w.ics")
        check("deleting the collection's event succeeds", code == 204)
        code, _, _ = request("DELETE", "/cal/work/")
        check("deleting the now-empty collection succeeds", code == 204)

        code, _, _ = request("DELETE", "/cal/s6.ics", headers=[f"If-Match: {tag}"])
        check("matching conditional delete succeeds", code == 204)
        # The DELETE precondition must be evaluated, not assumed: a stale
        # tag refuses where the matching tag above removed the event.
        code, _, _ = request("PUT", "/cal/s6.ics", EVENT, ["If-None-Match: *"])
        check("re-create for the stale-tag delete", code == 201)
        code, _, _ = request("DELETE", "/cal/s6.ics", headers=['If-Match: "stale"'])
        check("DELETE with a stale If-Match is refused", code == 412)
        code, _, _ = request("DELETE", "/cal/s6.ics")
        check("cleanup of the re-created event", code == 204)
        print(f"\n{len(failures)} failure(s)" if failures else "\nall green")
        return 1 if failures else 0
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
