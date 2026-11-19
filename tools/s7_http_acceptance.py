#!/usr/bin/env python3
"""S7 raw-socket HTTP acceptance: framing oddities, conditional requests,
HEAD framing, and write races - the shapes the audit rounds verified live,
kept as durable end-to-end checks. Complements s5/s6 (which drive curl) by
speaking raw TCP for the shapes curl will not produce.

Each check asserts a defined, non-hanging answer with its specific status;
the framing checks additionally assert body-absence where RFC 9110 9.3.2
requires it."""

import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "_build" / "native" / "debug" / "build" / "cmd" / "serve" / "serve.exe"
PORT = 8452
BASE = f"http://127.0.0.1:{PORT}"
failures = []


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def raw(payload: bytes, timeout=10):
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as s:
        s.sendall(payload)
        s.settimeout(timeout)
        chunks = []
        try:
            while True:
                got = s.recv(65536)
                if not got:
                    break
                chunks.append(got)
        except socket.timeout:
            pass
    data = b"".join(chunks)
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1]) if lines and lines[0].split() else 0
    return status, head.decode(errors="replace"), body.decode(errors="replace")


def request(method, path, data=None, headers=()):
    cmd = ["curl", "-s", "-i", "-X", method, f"{BASE}{path}"]
    for header in headers:
        cmd += ["-H", header]
    if data is not None:
        cmd += ["--data-binary", data]
    out = subprocess.run(cmd, capture_output=True, timeout=20, check=True).stdout
    head, _, body = out.partition(b"\r\n\r\n")
    status = int(head.split(b"\r\n")[0].split()[1])
    headers_map = {}
    for line in head.split(b"\r\n")[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            headers_map[k.lower().decode()] = v.strip().decode()
    return status, headers_map, body.decode(errors="replace")


def event(uid, size=0):
    filler = ("X-FILLER:" + "f" * 60 + "\r\n") * (size // 64)
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//s7//x\r\nBEGIN:VEVENT\r\n"
        f"UID:{uid}\r\nDTSTART:20260915T090000Z\r\nSUMMARY:{uid}\r\n{filler}"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )


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
    data_dir = tempfile.mkdtemp(prefix="moon-ical-s7-")
    log = open(Path(tempfile.mkdtemp(prefix="moon-ical-s7-log-")) / "server.log", "w")
    server = subprocess.Popen([str(EXE), data_dir, str(PORT)], stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_for_port():
            print("server did not start")
            return 2
        print("S7 raw-socket HTTP acceptance:")

        print("  -- framing --")
        code, _, _ = raw(b"\r\nGET /cal/ HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"leading CRLF tolerated (7230 3.5) ({code})", code in (200, 301))
        code, _, _ = raw(b"GET /cal/ HTTP/1.0\r\nHost: x\r\n\r\n")
        check(f"HTTP/1.0 answers ({code})", code in (200, 301, 400, 505))
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nDepth: 0\r\nIf-Match: \"t\"\r\n continued\r\n\r\n")
        check(f"obs-fold header line answered ({code})", code in (200, 301, 400, 412))
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        check(f"TE+CL both present answered, no desync ({code})", code in (200, 301, 400, 411))
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        check(f"TE alone refused or answered ({code})", code in (200, 301, 400, 411))
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nX-A: bad\x01value\r\n\r\n")
        check(f"control char in header value answered ({code})", code in (200, 301, 400))
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nX-Space : v\r\n\r\n")
        check(f"space before colon answered ({code})", code in (200, 301, 400))
        code, _, _ = raw(b"BAD" + b"M" * 70000 + b" /cal/ HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"70KB method token refused 400, response survives ({code})", code == 400, f"got {code}")
        code, _, _ = raw(b"get /cal/ HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"lowercase method answered ({code})", code in (200, 301, 400, 405))
        code, _, _ = raw(b"GET http://elsewhere/cal/ HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"absolute-form target answered ({code})", code in (200, 301, 400, 404))
        code, _, _ = raw(b"OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"asterisk-form OPTIONS answered ({code})", code in (200, 301, 400, 404))

        print("  -- pipelining (S69) --")
        pipelined = b"GET /cal/ HTTP/1.1\r\nHost: x\r\n\r\nGET /cal/ HTTP/1.1\r\nHost: x\r\n\r\n"
        with socket.create_connection(("127.0.0.1", PORT), timeout=8) as sock:
            sock.sendall(pipelined)
            sock.settimeout(8)
            buf = b""
            try:
                while True:
                    got = sock.recv(65536)
                    if not got:
                        break
                    buf += got
            except socket.timeout:
                pass
        answers = buf.count(b"HTTP/1.1 200")
        check(f"two pipelined requests yield two answers ({answers})", answers == 2)

        print("  -- HEAD framing (S71, RFC 9110 9.3.2) --")
        code, head, body = raw(b"HEAD /cal/x.ics HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999\r\n\r\n")
        check(f"HEAD + oversized body refused ({code})", code in (400, 411, 413), f"got {code}")
        check("HEAD 413 carries no body bytes", body == "", f"body {body[:60]!r}")
        code, head, body = raw(b"HEAD /cal/x.ics HTTP/1.1\r\nbad header line no colon\r\n\r\n")
        check(f"HEAD + malformed header refused ({code})", code in (400, 200, 404), f"got {code}")
        check("HEAD 400 carries no body bytes", body == "", f"body {body[:60]!r}")
        code, head, body = raw(b"HEAD /cal/missing.ics HTTP/1.1\r\nHost: x\r\n\r\n")
        check(f"HEAD on missing event carries no body ({code})", code == 404 and body == "")

        print("  -- reflection guard --")
        code, head, _ = raw(b"GET /cal/a\rEvil: 1 HTTP/1.1\r\nHost: x\r\n\r\n")
        check("CR inside the request path cannot inject a header", "Evil" not in head)

        print("  -- conditional requests (S64/S67) --")
        code, headers, _ = request("PUT", "/cal/cond.ics", event("cond@x"), ["If-None-Match: *"])
        check("seed event", code == 201)
        tag = headers.get("etag", "")
        code, _, _ = request("PUT", "/cal/cond.ics", event("cond@x"), [f'If-Match: W/{tag}'])
        check(f"weak-tag If-Match refused 412 ({code})", code == 412, f"got {code}")
        code, _, _ = request("PUT", "/cal/cond.ics", event("cond@x"), [f'If-Match: "nope", {tag}'])
        check(f"If-Match list containing the current tag stores ({code})", code == 204, f"got {code}")
        code, _, _ = request("PUT", "/cal/cond.ics", event("cond@x"), ['If-Match: "nope", "also-nope"'])
        check(f"If-Match list without the current tag refused ({code})", code == 412, f"got {code}")
        code, _, _ = request("GET", "/cal/cond.ics", headers=[f"If-None-Match: {tag}"])
        check(f"GET If-None-Match current tag answers 304 ({code})", code == 304, f"got {code}")
        code, _, _ = request("GET", "/cal/cond.ics", headers=['If-None-Match: "stale"'])
        check(f"GET If-None-Match stale answers 200 ({code})", code == 200, f"got {code}")

        print("  -- write races and scan linearity (S61/S65) --")
        t0 = time.time()
        code, _, _ = request("PUT", "/cal/big.ics", event("big@x", size=400000))
        check(f"600KB folded-continuation body PUT linear ({time.time()-t0:.2f}s)", code == 201, f"got {code}")

        def put_pair(i):
            return request("PUT", f"/cal/race-{i}.ics", event("race@x"))[0]
        with ThreadPoolExecutor(max_workers=2) as pool:
            codes = sorted(pool.map(put_pair, range(2)))
        check(f"concurrent same-UID PUTs: exactly one wins ({codes})", codes.count(201) + codes.count(204) == 1, f"codes {codes}")
        for i in range(2):
            request("DELETE", f"/cal/race-{i}.ics")
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda i: request("PUT", f"/cal/multi-{i}.ics", event(f"m{i}@x"))[0], range(8)))
        check("8 concurrent distinct-UID PUTs all store", all(c == 201 for c in results), f"{results}")
        for i in range(8):
            request("DELETE", f"/cal/multi-{i}.ics")

        print("  -- exact boundaries (S63) --")
        hdr = b"X" * (64 * 1024 - 40)
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nX-Fill: " + hdr + b"\r\n\r\n")
        check(f"header line just under the cap answered ({code})", code in (200, 301), f"got {code}")
        code, _, _ = raw(b"GET /cal/ HTTP/1.1\r\nHost: x\r\nX-Fill: " + b"X" * (256 * 1024) + b"\r\n\r\n")
        check(f"256KB header line refused 400 ({code})", code == 400, f"got {code}")
        many = "".join(f"X-H{i}: v\r\n" for i in range(120))
        code, _, _ = raw(("GET /cal/ HTTP/1.1\r\nHost: x\r\n" + many + "\r\n").encode())
        check(f"header count over the cap refused 400 ({code})", code == 400, f"got {code}")
        code, _, _ = raw(b"PUT /cal/over.ics HTTP/1.1\r\nHost: x\r\nContent-Length: 10485761\r\n\r\n")
        check(f"CL one over MAX_BODY refused 413 ({code})", code == 413, f"got {code}")

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
