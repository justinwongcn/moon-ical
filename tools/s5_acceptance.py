#!/usr/bin/env python3
"""S5 acceptance driver (foreground only).

Starts the calendar server binary as a subprocess, drives it with real
curl calls, and asserts the S5 acceptance criteria from
docs/development.html §04:

  - curl completes the event PUT / GET / DELETE round trip
  - the ETag changes with content and is content-addressed
  - a chunked request body is answered 411 Length Required

The server subprocess lives exactly as long as this script, so nothing
is left running afterwards. User-sanctioned Python for auxiliary
tooling (2026-09-10).
"""

import socket
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "_build" / "native" / "debug" / "build" / "cmd" / "serve" / "serve.exe"
PORT = 8437
BASE = f"http://127.0.0.1:{PORT}"

BODY_A = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nUID:test-1@moon-ical\r\nSUMMARY:alpha\r\nEND:VCALENDAR\r\n"
BODY_B = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nUID:test-1@moon-ical\r\nSUMMARY:bravo changed\r\nEND:VCALENDAR\r\n"

failures = []


def check(label: str, ok: bool, detail: str = "") -> None:
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {label}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def request(method: str, path: str, data=None, headers=None, raw=False):
    """One curl call; returns (status, headers-lowercased, body-bytes).

    Bytes mode on purpose: text=True would translate every CRLF to LF
    and the body-equality check would compare the wrong thing.
    """
    cmd = ["curl", "-s", "-i", "-X", method, f"{BASE}{path}"]
    if headers:
        for h in headers:
            cmd += ["-H", h]
    if data is not None:
        cmd += ["--data-binary", data]
    proc = subprocess.run(cmd, capture_output=True, timeout=15)
    out = proc.stdout
    head, sep, body = out.partition(b"\r\n\r\n")
    if not sep:
        head, sep, body = out.partition(b"\n\n")
    lines = head.replace(b"\r\n", b"\n").split(b"\n")
    status = int(lines[0].split(b" ")[1]) if lines and b" " in lines[0] else 0
    hdrs = {}
    for line in lines[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            hdrs[k.strip().lower().decode()] = v.strip().decode()
    return status, hdrs, body


def wait_for_port(seconds: float = 10.0) -> bool:
    deadline = seconds
    while deadline > 0:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=1):
                return True
        except OSError:
            time.sleep(0.3)
            deadline -= 0.3
    return False


import time  # noqa: E402  (used by wait_for_port)

def main() -> int:
    if not EXE.exists():
        print(f"server binary missing: {EXE}")
        return 2
    tmp = tempfile.mkdtemp(prefix="moon-ical-s5-")
    log = open(Path(tmp) / "server.log", "w", encoding="utf-8")
    server = subprocess.Popen(
        [str(EXE), tmp, str(PORT)],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        if not wait_for_port():
            print("server never came up; log tail:")
            log.flush()
            print(Path(tmp).joinpath("server.log").read_text(encoding="utf-8")[-500:])
            return 2
        print("S5 acceptance against a live server (curl round trip):")

        # 1. OPTIONS advertises the method set and DAV compliance.
        code, hdrs, _ = request("OPTIONS", "/cal/test.ics")
        check("OPTIONS -> 200", code == 200, f"got {code}")
        check("OPTIONS Allow lists PUT", "PUT" in hdrs.get("allow", ""))
        check("OPTIONS DAV includes class 1", "1" in hdrs.get("dav", ""))

        # 2. PUT creates and answers 201 with an ETag.
        code, hdrs, _ = request("PUT", "/cal/test.ics", data=BODY_A)
        check("PUT create -> 201", code == 201, f"got {code}")
        etag1 = hdrs.get("etag", "")
        check("PUT create carries ETag", etag1 != "")

        # 3. GET returns exactly the stored bytes with the same ETag.
        code, hdrs, body = request("GET", "/cal/test.ics")
        check("GET -> 200", code == 200, f"got {code}")
        check("GET body is byte-identical", body == BODY_A.encode())
        check("GET ETag equals PUT ETag", hdrs.get("etag", "") == etag1)

        # 4. Changed content moves the ETag; CalDAV PUT reports a replace (204).
        code, hdrs, _ = request("PUT", "/cal/test.ics", data=BODY_B)
        check("PUT replace -> 204", code == 204, f"got {code}")
        etag2 = hdrs.get("etag", "")
        check("content change moves ETag", etag2 != etag1 and etag2 != "")

        # 5. Content-addressed: restoring the bytes restores the ETag.
        code, hdrs, _ = request("PUT", "/cal/test.ics", data=BODY_A)
        check("PUT restore -> 204", code == 204, f"got {code}")
        check("restored bytes restore ETag", hdrs.get("etag", "") == etag1)

        # 6. A chunked request body is refused with 411.
        code, _, _ = request(
            "PUT",
            "/cal/test.ics",
            data=BODY_A,
            headers=["Transfer-Encoding: chunked"],
        )
        check("chunked body -> 411", code == 411, f"got {code}")

        # 7. Unknown methods get 405 with an Allow header.
        code, hdrs, _ = request("BREW", "/cal/test.ics")
        check("unknown method -> 405", code == 405, f"got {code}")
        check("405 carries Allow", "GET" in hdrs.get("allow", ""))

        # 8. The collection listing sees the event.
        code, _, body = request("GET", "/cal/")
        check("collection listing -> 200", code == 200, f"got {code}")
        check("listing contains test.ics", b"test.ics" in body)

        # 9. DELETE removes it (204), then reports nothing left (404).
        code, _, _ = request("DELETE", "/cal/test.ics")
        check("DELETE -> 204", code == 204, f"got {code}")
        code, _, _ = request("GET", "/cal/test.ics")
        check("GET after DELETE -> 404", code == 404, f"got {code}")
        code, _, _ = request("DELETE", "/cal/test.ics")
        check("second DELETE -> 404", code == 404, f"got {code}")

        # 10. Off-collection paths are 404.
        code, _, _ = request("GET", "/nope")
        check("off-collection path -> 404", code == 404, f"got {code}")

        print(f"\n{len(failures)} failure(s)" if failures else "\nall green")
        return 1 if failures else 0
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        log.close()
        print(f"server stopped; data dir {tmp}")


if __name__ == "__main__":
    sys.exit(main())
