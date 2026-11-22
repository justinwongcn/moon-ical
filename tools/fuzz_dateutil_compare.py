#!/usr/bin/env python3
"""S76-era regression fuzz: 150 random RRULEs, moon vs python-dateutil.
Excludes the three known dateutil defect families documented in PROGRESS."""
from pathlib import Path

import random
import subprocess
import sys
from datetime import datetime, timezone
from dateutil.rrule import rrulestr

random.seed(20261123)
N = 150
DAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

def gen_rule():
    freq = random.choice(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])
    parts = [f"FREQ={freq}"]
    interval = random.choice([1, 1, 2, 3])
    if interval > 1:
        parts.append(f"INTERVAL={interval}")
    # COUNT 与 UNTIL 二选一
    if random.random() < 0.6:
        parts.append(f"COUNT={random.randint(3, 30)}")
    else:
        y, m, d = random.randint(2026, 2028), random.randint(1, 12), random.randint(1, 28)
        parts.append(f"UNTIL={y}{m:02d}{d:02d}T235959Z")
    if freq == "WEEKLY":
        # 已知 dateutil 缺陷:INTERVAL>1 + 日修饰走月网格 → 仅 INTERVAL=1 时生成 BYDAY
        if interval == 1 or random.random() < 0.3:
            parts.append("BYDAY=" + ",".join(random.sample(DAYS, random.randint(1, 3))))
    elif freq == "MONTHLY":
        if random.random() < 0.5:
            # 已知 dateutil 缺陷:序数 BYDAY + INTERVAL=2 → IndexError;序数只配 INTERVAL=1 或无 INTERVAL
            ord_part = f"{random.randint(1, 2)}{random.choice(DAYS[:2])}" if interval == 1 or random.random() < 0.5 else ""
            if ord_part and interval != 2:
                parts.append(f"BYDAY={ord_part}")
        if random.random() < 0.5:
            parts.append("BYMONTHDAY=" + ",".join(str(random.choice([1, 5, 15, -1, -5, 28])) for _ in range(random.randint(1, 2))))
    elif freq == "YEARLY":
        if random.random() < 0.5:
            parts.append("BYMONTH=" + ",".join(str(random.randint(1, 12)) for _ in range(random.randint(1, 2))))
        if random.random() < 0.5:
            parts.append("BYMONTHDAY=" + ",".join(str(random.choice([1, 10, 15, 29, -1])) for _ in range(random.randint(1, 2))))
        if random.random() < 0.4:
            # 序数 BYDAY + BYMONTH = 正确的年序号形状
            parts.append(f"BYDAY={random.randint(1, 3)}{random.choice(DAYS)}")
    if freq in ("MONTHLY", "YEARLY") and random.random() < 0.25:
        parts.append("BYSETPOS=" + str(random.choice([1, -1, 2])))
    if random.random() < 0.15:
        parts.append("WKST=" + random.choice(DAYS))
    # 去重相邻同名子句(fuzz 已在解析层拒绝重复;这里避免生成)
    seen, dedup = set(), []
    for p in parts:
        key = p.split("=")[0]
        if key in seen:
            continue
        seen.add(key)
        dedup.append(p)
    return ";".join(dedup)

rules = []
while len(rules) < N:
    r = gen_rule()
    # 已知 dateutil 缺陷族:混用序数+平条目 BYDAY 单条规则 → dateutil 全空
    if "BYDAY" in r:
        dayvals = r.split("BYDAY=")[1].split(";")[0].split(",")
        ords = [v for v in dayvals if v and v[0].isdigit() and not v.isdigit() or (v and v[0] in "12345" and len(v) > 2)]
        plains = [v for v in dayvals if v in DAYS]
        if ords and plains:
            continue
    rules.append(r)

dts = []
for _ in range(N):
    y, m, d = 2026, random.randint(1, 12), random.randint(1, 28)
    hh, mm = random.randint(0, 22), random.choice([0, 15, 30, 45])
    dts.append(f"{y}{m:02d}{d:02d}T{hh:02d}{mm:02d}00Z")

pairs = [f"{dts[i]}\t{rules[i]}" for i in range(N)]
rules_text = "\n".join(pairs)
open("/tmp/fuzz-rules.txt", "w").write(rules_text)

out = subprocess.run(
    ["moon", "run", "tmpfuzz", "--target", "native", "--", rules_text],
    cwd=str(Path(__file__).resolve().parent.parent), capture_output=True, timeout=600, text=True,
).stdout

moon_map = {}
for line in out.splitlines():
    if ":" in line and line.split(":")[0].isdigit():
        idx, rest = line.split(":", 1)
        if rest.startswith("REFUSED"):
            continue
        moon_map[int(idx)] = [o for o in rest[3:].split(",") if o]

mismatches = []
skipped = 0
for i in range(N):
    dt = datetime.strptime(dts[i], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    rr = rrulestr("RRULE:" + rules[i], dtstart=dt)
    expected = [d.strftime("%Y-%m-%dT%H:%M:%SZ") for d in list(rr)[:60]]
    if i not in moon_map:
        skipped += 1
        continue
    got = moon_map[i]
    if expected != got:
        mismatches.append((i, rules[i], dts[i], expected[:6], got[:6]))

print(f"rules: {N}, comparable: {len(moon_map)}, refused/skipped: {skipped}, mismatches: {len(mismatches)}")
for i, rule, dts0, exp, got in mismatches[:8]:
    print(f"  MISMATCH #{i}: {rule}\n    dtstart={dts0}\n    dateutil={exp}\n    moon    ={got}")
sys.exit(1 if mismatches else 0)
