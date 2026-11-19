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
    log_dir = tempfile.mkdtemp(prefix="moon-ical-s6-log-")
    log = open(Path(log_dir) / "server.log", "w", encoding="utf-8")
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
        # The property selection is an input the response builder reads
        # (RFC 4918 9.1): requests differing only in the DAV:prop list must
        # answer different property sets, an unknown name gets its own 404
        # propstat, and calendar-data — not a WebDAV property (RFC 4791 9.6)
        # — does not exist for PROPFIND at all. A stub returning a fixed
        # property set cannot pass this block.
        selection = (
            '<?xml version="1.0" encoding="utf-8" ?>'
            '<D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop>%s</D:prop></D:propfind>'
        )
        cup_only = selection % "<D:current-user-principal/>"
        code, _, body = request("PROPFIND", "/cal/", cup_only, ["Content-Type: application/xml", "Depth: 0"])
        check("propfind answers exactly the property it names", code == 207 and "current-user-principal" in body and "resourcetype" not in body and "getetag" not in body and "getcontenttype" not in body)
        etag_ask = selection % "<D:getetag/>"
        code, _, body = request("PROPFIND", "/cal/", etag_ask, ["Content-Type: application/xml", "Depth: 0"])
        check("a different property name answers differently", code == 207 and "getetag" in body and "current-user-principal" not in body and "404 Not Found" in body)
        unknown_ask = selection % "<D:no-such-prop/>"
        code, _, body = request("PROPFIND", "/cal/", unknown_ask, ["Content-Type: application/xml", "Depth: 0"])
        check("an unknown property is a 404 propstat", code == 207 and "404 Not Found" in body and "<D:no-such-prop/>" in body)
        data_ask = selection % '<C:calendar-data/>'
        code, _, body = request("PROPFIND", "/cal/", data_ask, ["Content-Type: application/xml", "Depth: 1"])
        check("propfind answers calendar-data with a 404 propstat", code == 207 and "404 Not Found" in body and "BEGIN:VCALENDAR" not in body)
        code, _, body = request("PROPFIND", "/cal/", '<D:propfind xmlns:D="DAV:"/>', ["Content-Type: application/xml", "Depth: 0"])
        check("a selection-less propfind is a bad request", code == 400)
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
        # The report's prop element is honored like PROPFIND's (RFC 4791
        # 7.8): a getetag-only query ships no calendar data, and naming
        # calendar-data brings it back — the R1 pair.
        trim = (
            '<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
            '<D:prop><D:getetag/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"/></C:filter>'
            '</C:calendar-query>'
        )
        code, _, body = request("REPORT", "/cal/", trim, ["Content-Type: application/xml"])
        check("a report naming getetag alone omits calendar data", code == 207 and "getetag" in body and "calendar-data" not in body and "BEGIN:VCALENDAR" not in body)
        code, _, body = request("REPORT", "/cal/", trim.replace("<D:getetag/>", "<D:getetag/><C:calendar-data/>"), ["Content-Type: application/xml"])
        check("naming calendar-data in a report brings it back", code == 207 and "calendar-data" in body and "BEGIN:VCALENDAR" in body)
        empty_prop = '<C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop/><D:href>/cal/s6.ics</D:href></C:calendar-multiget>'
        code, _, body = request("REPORT", "/cal/", empty_prop, ["Content-Type: application/xml"])
        check("an empty prop list answers an empty propstat", code == 207 and "<D:prop></D:prop>" in body and "/cal/s6.ics" in body)
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
        # S44: the same reports apply to a single calendar object (RFC 4918
        # 9.1), and S48 guards against the misplaced-branch regression that
        # let a file report leak other collections' events.
        code, _, body = request("PROPFIND", "/cal/work/w.ics", headers=["Depth: 0"])
        check("file-level PROPFIND answers 207", code == 207 and "/cal/work/w.ics" in body)
        code, _, body = request("REPORT", "/cal/work/w.ics", query, ["Content-Type: application/xml"])
        check("file-level calendar-query is scoped to the object", code == 207 and "UID:s6-work@moon-ical" in body and "UID:s6@moon-ical" not in body)
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

        # S60 PUT door: the collection advertises a VEVENT-only supported-
        # calendar-component-set, and RFC 4791 4.1 forbids more than one
        # entity type per resource and the METHOD property outright. Each
        # refusal must name its specific precondition element (a bare "not
        # 200" proves nothing) and the refused body must not have been
        # stored. The R1 pair: the same body with the poison removed stores
        # fine, so the refusals below really are reading the input.
        code, _, body = request(
            "PUT",
            "/cal/poison-mixed.ics",
            EVENT.replace(
                "END:VCALENDAR",
                "BEGIN:VTODO\r\nUID:poison-t\r\nDUE:20260916T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR",
            ),
        )
        check(
            "mixed entity types refused as valid-calendar-object-resource",
            code == 403 and "valid-calendar-object-resource" in body,
        )
        code, _, _ = request("GET", "/cal/poison-mixed.ics")
        check("refused mixed body was not stored", code == 404)
        code, _, body = request(
            "PUT",
            "/cal/poison-method.ics",
            EVENT.replace("VERSION:2.0", "VERSION:2.0\r\nMETHOD:REQUEST"),
        )
        check(
            "METHOD property refused as valid-calendar-object-resource",
            code == 403 and "valid-calendar-object-resource" in body,
        )
        code, _, _ = request("GET", "/cal/poison-method.ics")
        check("refused METHOD body was not stored", code == 404)
        code, _, body = request(
            "PUT",
            "/cal/poison-todo.ics",
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:poison-only\r\nDUE:20260916T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n",
        )
        check(
            "VTODO refused as supported-calendar-component",
            code == 403 and "supported-calendar-component" in body and "valid-calendar-data" not in body,
        )
        code, _, _ = request("GET", "/cal/poison-todo.ics")
        check("refused VTODO body was not stored", code == 404)
        code, _, _ = request(
            "PUT",
            "/cal/s6-clean.ics",
            EVENT.replace("UID:s6@moon-ical", "UID:s6-clean@moon-ical"),
            ["If-None-Match: *"],
        )
        check("the R1 canary VEVENT still stores", code == 201)
        code, _, body = request("PROPFIND", "/cal/", headers=["Depth: 1"])
        check(
            "collection stays clean: canary listed, no poison hrefs",
            code == 207 and "/cal/s6-clean.ics" in body and "poison" not in body,
        )
        code, _, _ = request("DELETE", "/cal/s6-clean.ics")
        check("cleanup of the S60 canary", code == 204)

        # S61 no-uid-conflict (RFC 4791 5.3.2.1): a UID another resource
        # already holds must be refused naming that resource's href, an
        # overwrite that changes the UID must be refused naming itself,
        # and the same UID over the same resource stays the normal
        # replace. Each refusal leaves nothing behind (R2).
        uid_a = EVENT.replace("UID:s6@moon-ical", "UID:uid-a@moon-ical")
        code, _, _ = request("PUT", "/cal/uid-a.ics", uid_a, ["If-None-Match: *"])
        check("S61 fresh UID on a fresh resource stores", code == 201)
        code, _, body = request("PUT", "/cal/uid-b.ics", uid_a)
        check(
            "S61 duplicate UID on another URL refused naming the holder",
            code == 403 and "no-uid-conflict" in body and "/cal/uid-a.ics" in body,
        )
        code, _, _ = request("GET", "/cal/uid-b.ics")
        check("S61 refused duplicate body was not stored", code == 404)
        code, _, body = request("PUT", "/cal/uid-a.ics", EVENT)
        check(
            "S61 overwrite changing the UID refused naming itself",
            code == 403 and "no-uid-conflict" in body and "/cal/uid-a.ics" in body,
        )
        code, _, _ = request("PUT", "/cal/uid-a.ics", uid_a)
        check("S61 same UID over the same resource stays a replace", code == 204)
        code, _, _ = request("DELETE", "/cal/uid-a.ics")
        check("S61 cleanup of the UID pin", code == 204)

        # S62 single-occurrence properties (RFC 5545 3.8): a body whose
        # meaning would depend on which line a reader picks is refused as
        # invalid-calendar-data and leaves nothing behind (R2/R3). The
        # matching-type pair stays legal (R1 control).
        code, _, body = request(
            "PUT",
            "/cal/poison-dup.ics",
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s6//x\r\nBEGIN:VEVENT\r\nUID:dup@moon-ical\r\nDTSTART:20260915T090000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nRRULE:FREQ=WEEKLY;COUNT=2\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        )
        check(
            "S72 duplicate RRULE tolerated as SHOULD-level (stores 201)",
            code == 201,
        )
        code, _, _ = request("GET", "/cal/poison-dup.ics")
        check("S72 tolerated duplicate body stored", code == 200)
        code, _, body = request(
            "PUT",
            "/cal/poison-mix.ics",
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s6//x\r\nBEGIN:VEVENT\r\nUID:mix@moon-ical\r\nDTSTART;VALUE=DATE:20260915\r\nDTEND:20260916T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        )
        check(
            "S62 DATE DTSTART with DATE-TIME DTEND refused",
            code == 403 and "valid-calendar-data" in body,
        )
        # S72 correction: the value-type agreement and the dtend+duration
        # mutual exclusion stay MUST-level refusals; only the once-ness
        # of rrule (SHOULD) and of dtend/duration (unannotated) softened.
        code, _, body = request(
            "PUT",
            "/cal/poison-both.ics",
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s6//x\r\nBEGIN:VEVENT\r\nUID:both@moon-ical\r\nDTSTART:20260915T090000Z\r\nDTEND:20260915T100000Z\r\nDURATION:PT30M\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        )
        check(
            "S72 dtend+duration co-occurrence still refused",
            code == 403 and "valid-calendar-data" in body,
        )
        code, _, _ = request("PUT", "/cal/s62-ok.ics",
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s6//x\r\nBEGIN:VEVENT\r\nUID:s62ok@moon-ical\r\nDTSTART;VALUE=DATE:20260915\r\nDTEND;VALUE=DATE:20260916\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
            ["If-None-Match: *"],
        )
        check("S62 matching DATE pair still stores", code == 201)
        code, _, _ = request("DELETE", "/cal/s62-ok.ics")
        check("S62 cleanup of the control", code == 204)

        # S67 conditional GET (RFC 7232 3.2): GET and HEAD are exactly the
        # methods that must honor If-None-Match - a match answers 304 with
        # the entity tag and no body, a stale tag answers 200 (R1 pair),
        # and the weak spelling matches because 3.2 prescribes the weak
        # comparison here.
        code, headers, body = request("GET", "/cal/s6.ics", headers=[f"If-None-Match: {tag}"])
        check("GET with If-None-Match current tag answers 304", code == 304 and body == "" and bool(headers.get("etag")))
        code, _, _ = request("GET", "/cal/s6.ics", headers=['If-None-Match: "stale"'])
        check("GET with a stale If-None-Match answers 200", code == 200)
        code, _, _ = request("GET", "/cal/s6.ics", headers=[f"If-None-Match: W/{tag}"])
        check("GET weak-spelling If-None-Match also matches", code == 304)
        # S61 follow-up: duplicate conditional header lines are evaluated
        # first-only (no comma-combining) - the stale first line wins and
        # the matching second is ignored (defined boundary, recorded).
        code, _, _ = request(
            "PUT", "/cal/s6.ics", EVENT,
            ['If-Match: "stale"', f"If-Match: {tag}"],
        )
        check("duplicate If-Match lines: first line evaluated, 412", code == 412)
        # EXDATE exclusion matches by instant, not by TZID spelling - a
        # fixed-zone spelling of the same instant removes the same slot
        # as the UTC spelling (R1 pair).
        fixed_zone = (
            "BEGIN:VTIMEZONE\r\nTZID:W3-Z\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\n"
            "TZOFFSETFROM:+0900\r\nTZOFFSETTO:+0900\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n"
        )
        ex_base = (
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s6//x\r\n" + fixed_zone +
            "BEGIN:VEVENT\r\nUID:{uid}\r\nDTSTART:20260915T090000Z\r\n"
            "RRULE:FREQ=DAILY;COUNT=3\r\n{ex}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        )
        code, _, _ = request(
            "PUT", "/cal/ex-utc.ics",
            ex_base.format(uid="exutc@moon-ical", ex="EXDATE:20260916T090000Z"),
            ["If-None-Match: *"],
        )
        check("UTC-spelled EXDATE stores", code == 201)
        code, _, _ = request(
            "PUT", "/cal/ex-tz.ics",
            ex_base.format(uid="extz@moon-ical", ex="EXDATE;TZID=W3-Z:20260916T180000"),
            ["If-None-Match: *"],
        )
        check("cross-TZ EXDATE (same instant) stores", code == 201)
        code, _, body = request(
            "REPORT", "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260916T000000Z" end="20260917T000000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check(
            "exclusion by instant: both EXDATE spellings exclude the slot",
            code == 207 and "/cal/ex-utc.ics" not in body and "/cal/ex-tz.ics" not in body,
        )
        code, _, _ = request("DELETE", "/cal/ex-utc.ics")
        code, _, _ = request("DELETE", "/cal/ex-tz.ics")

        # Hacker-view wire receipts (S73 review round): series semantics,
        # multiget pathologies, and the XML depth boundary, measured live
        # and pinned so the router/door/evaluator integration cannot drift.
        series = (
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:nouid2a\r\nDTSTART:20260101T090000Z\r\n"
            "DTEND:20260101T100000Z\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:nouid2b\r\n"
            "DTSTART:20260915T090000Z\r\nDTEND:20260915T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        )
        code, _, _ = request("PUT", "/cal/series-nouid.ics", series, ["If-None-Match: *"])
        check("two UID-less events in one resource store", code == 201)
        code, _, body = request(
            "REPORT", "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260915T090000Z" end="20260915T100000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check(
            "a window matching only the second UID-less event selects the resource (R1)",
            code == 207 and "/cal/series-nouid.ics" in body,
        )
        code, _, _ = request("DELETE", "/cal/series-nouid.ics")
        taf = (
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:taf-s6\r\nDTSTART:20260915T090000Z\r\n"
            "DTEND:20260915T093000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:taf-s6\r\n"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260916T090000Z\r\nDTSTART:20260916T090000Z\r\n"
            "DTEND:20260916T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        )
        code, _, _ = request("PUT", "/cal/taf.ics", taf, ["If-None-Match: *"])
        check("THISANDFUTURE duration change stores", code == 201)
        code, _, body = request(
            "REPORT", "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260917T100000Z" end="20260917T110000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check(
            "the inherited longer duration covers the old short slot's window",
            code == 207 and "/cal/taf.ics" in body,
        )
        code, _, body = request(
            "REPORT", "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260917T093000Z" end="20260917T093500Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check(
            "a window inside the inherited span selects (09:30-09:35 is past the old 09:30 end)",
            code == 207 and "/cal/taf.ics" in body,
        )
        code, _, body = request(
            "REPORT", "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260917T120000Z" end="20260917T123000Z"/></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check(
            "a window beyond the inherited end excludes the instance",
            code == 207 and "/cal/taf.ics" not in body,
        )
        code, _, _ = request("DELETE", "/cal/taf.ics")
        mg_base = '<C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop>{hrefs}</C:calendar-multiget>'
        mg_event = EVENT.replace("UID:s6@moon-ical", "UID:mg@moon-ical")
        code, _, _ = request("PUT", "/cal/mg.ics", mg_event, ["If-None-Match: *"])
        check("multiget seed", code == 201)
        code, _, body = request(
            "REPORT", "/cal/",
            mg_base.format(hrefs="<D:href>/cal/mg.ics</D:href><D:href>/cal/mg.ics</D:href>"),
            ["Depth: 1"],
        )
        check(f"duplicated multiget href answers one response ({body.count('<D:response')})", code == 207 and body.count("<D:response") == 1)
        code, _, body = request(
            "REPORT", "/cal/",
            mg_base.format(hrefs="<D:href>/cal/%6d.ics</D:href>"),
            ["Depth: 1"],
        )
        check(
            "percent-encoded href matches byte-exact, 404 propstat, nothing leaks",
            code == 207 and "404" in body and "/cal/mg.ics" not in body,
        )
        code, _, body = request(
            "REPORT", "/cal/",
            mg_base.format(hrefs="<D:href>/cal/..%2Foutside.ics</D:href>"),
            ["Depth: 1"],
        )
        check("traversal href stays inside the collection 404", code == 207 and "404" in body and "outside" not in body.replace("/cal/..%2Foutside.ics", ""))
        code, _, body = request(
            "REPORT", "/cal/",
            mg_base.format(hrefs=f"<D:href>http://127.0.0.1:{PORT}/cal/mg.ics</D:href>"),
            ["Depth: 1"],
        )
        check(
            "absolute-URI href form matches the resource (defined lenient)",
            code == 207 and "/cal/mg.ics" in body,
        )
        code, _, _ = request("DELETE", "/cal/mg.ics")
        deep63 = '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter>' + '<C:comp-filter name="VCALENDAR">' * 63 + "</C:comp-filter>" * 63 + "</C:calendar-query>"
        deep65 = deep63.replace("* 63", "* 65").replace("</C:comp-filter>" * 63, "</C:comp-filter>" * 65)
        code, _, _ = request("REPORT", "/cal/", deep63, ["Depth: 1"])
        check(f"63-deep comp-filter answered ({code})", code in (207, 400))
        code, _, _ = request("REPORT", "/cal/", deep65, ["Depth: 1"])
        check(f"65-deep comp-filter refused ({code})", code == 400, f"got {code}")
        code, _, rep_body = request(
            "REPORT",
            "/cal/",
            '<?xml version="1.0"?><C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="vevent"/></C:comp-filter></C:filter></C:calendar-query>',
            ["Depth: 1"],
        )
        check("S70 lowercase comp-filter selects the same events", code == 207 and "/cal/s6.ics" in rep_body)

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
