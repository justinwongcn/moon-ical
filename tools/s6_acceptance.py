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
        query = '<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav"><D:prop xmlns:D="DAV:"><D:getetag/><C:calendar-data/></D:prop></C:calendar-query>'
        code, _, body = request("REPORT", "/cal/", query, ["Content-Type: application/xml"])
        check("calendar-query returns calendar-data", code == 207 and "UID:s6@moon-ical" in body)
        multiget = '<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav"><D:href xmlns:D="DAV:">/cal/s6.ics</D:href></C:calendar-multiget>'
        code, _, body = request("REPORT", "/cal/", multiget, ["Content-Type: application/xml"])
        check("calendar-multiget returns selected event", code == 207 and "/cal/s6.ics" in body)
        code, _, _ = request("DELETE", "/cal/s6.ics", headers=[f"If-Match: {tag}"])
        check("matching conditional delete succeeds", code == 204)
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
