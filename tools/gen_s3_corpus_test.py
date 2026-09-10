#!/usr/bin/env python3
"""Emit the MoonBit S3 corpus cross-check table from graham's corpus.

Reads the case table below (lifted mechanically from
`.survey/src/graham_rrule/basic_test.go`, the rrule.js-derived suite
graham vendored) and prints `ical/rrule/expand_corpus_test.mbt`: one row
per FIRST-TIER rule string — no ordinal BYDAY, no negative BYMONTHDAY,
no BYSETPOS — paired with the occurrence list graham's own tests assert.
The expectations are graham's, mechanically lifted; this script only
formats them. Re-run it only when the survey corpus changes:

    python tools/gen_s3_corpus_test.py > ical/rrule/expand_corpus_test.mbt
"""

import sys
from datetime import date, timedelta

D = lambda y, m, d: date(y, m, d)  # noqa: E731

WEEKS = lambda start, n: [start + timedelta(weeks=i) for i in range(n)]  # noqa: E731


def run(start: date, count: int):
    return [start + timedelta(days=i) for i in range(count)]


def three_jans() -> list:
    out = []
    for year in (1998, 1999, 2000):
        for day in range(1, 32):
            out.append(D(year, 1, day))
    return out


def jun_aug_thursdays() -> list:
    out = []
    for year in (1997, 1998, 1999):
        day = date(year, 6, 1)
        while day <= date(year, 8, 31):
            if day.weekday() == 3:  # Thursday
                out.append(day)
            day += timedelta(days=1)
    return out


CASES = [
    ("Test_DailyFor10", "FREQ=DAILY;COUNT=10", D(1997, 9, 2),
     run(D(1997, 9, 2), 10)),
    # the corpus builds Sep 2 .. Dec 23 (113 consecutive days)
    ("Test_DailyUntil", "FREQ=DAILY;UNTIL=19971224T000000Z", D(1997, 9, 2),
     run(D(1997, 9, 2), 113)),
    # unbounded; the corpus compares the first 6
    ("Test_Daily_EveryOtherDayForever", "FREQ=DAILY;INTERVAL=2", D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 4), D(1997, 9, 6), D(1997, 9, 8),
      D(1997, 9, 10), D(1997, 9, 12)]),
    ("Test_Interval_And_Count", "FREQ=DAILY;INTERVAL=10;COUNT=5", D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 12), D(1997, 9, 22), D(1997, 10, 2),
      D(1997, 10, 12)]),
    # both spellings of "every day in January" assert the same 93 dates
    ("Test_EveryDayInJanuary_ForThreeYears",
     "FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA",
     D(1998, 1, 1), three_jans()),
    ("Test_EveryDayInJanuary_ForThreeYears",
     "FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1", D(1998, 1, 1),
     three_jans()),
    ("Test_Weekly_for_10_Count", "FREQ=WEEKLY;COUNT=10", D(1997, 9, 2),
     WEEKS(D(1997, 9, 2), 10)),
    # UNTIL and COUNT spellings of the same series yield these 10 dates
    ("Test_TU_TH_for_Five_Weeks",
     "FREQ=WEEKLY;UNTIL=19971007T000000Z;WKST=SU;BYDAY=TU,TH", D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 4), D(1997, 9, 9), D(1997, 9, 11),
      D(1997, 9, 16), D(1997, 9, 18), D(1997, 9, 23), D(1997, 9, 25),
      D(1997, 9, 30), D(1997, 10, 2)]),
    ("Test_TU_TH_for_Five_Weeks", "FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH",
     D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 4), D(1997, 9, 9), D(1997, 9, 11),
      D(1997, 9, 16), D(1997, 9, 18), D(1997, 9, 23), D(1997, 9, 25),
      D(1997, 9, 30), D(1997, 10, 2)]),
    ("Test_every_other_complex",
     "FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR",
     D(1997, 9, 1),
     [D(1997, 9, 1), D(1997, 9, 3), D(1997, 9, 5), D(1997, 9, 15),
      D(1997, 9, 17), D(1997, 9, 19), D(1997, 9, 29), D(1997, 10, 1),
      D(1997, 10, 3), D(1997, 10, 13), D(1997, 10, 15), D(1997, 10, 17),
      D(1997, 10, 27), D(1997, 10, 29), D(1997, 10, 31), D(1997, 11, 10),
      D(1997, 11, 12), D(1997, 11, 14), D(1997, 11, 24), D(1997, 11, 26),
      D(1997, 11, 28), D(1997, 12, 8), D(1997, 12, 10), D(1997, 12, 12),
      D(1997, 12, 22)]),
    ("Test_Monthly_2nd_15th_for_10Count",
     "FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15", D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 15), D(1997, 10, 2), D(1997, 10, 15),
      D(1997, 11, 2), D(1997, 11, 15), D(1997, 12, 2), D(1997, 12, 15),
      D(1998, 1, 2), D(1998, 1, 15)]),
    # INTERVAL=18: Sep 1997 then Mar 1999 — the long-step case
    ("Test_LongInterval",
     "FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15",
     D(1997, 9, 10),
     [D(1997, 9, 10), D(1997, 9, 11), D(1997, 9, 12), D(1997, 9, 13),
      D(1997, 9, 14), D(1997, 9, 15), D(1999, 3, 10), D(1999, 3, 11),
      D(1999, 3, 12), D(1999, 3, 13)]),
    # unbounded; the corpus compares the first 5 (DTSTART does not match)
    ("Test_FridayThe13th", "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13",
     D(1997, 9, 2),
     [D(1998, 2, 13), D(1998, 3, 13), D(1998, 11, 13), D(1999, 8, 13),
      D(2000, 10, 13)]),
    # BYDAY=SA ∩ BYMONTHDAY=7..13 — the first Saturday after day 6
    ("Test_FirstSaturdayAfterFirstSunday",
     "FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13", D(1997, 9, 13),
     [D(1997, 9, 13), D(1997, 10, 11), D(1997, 11, 8), D(1997, 12, 13),
      D(1998, 1, 10), D(1998, 2, 7), D(1998, 3, 7), D(1998, 4, 11),
      D(1998, 5, 9), D(1998, 6, 13)]),
    # unbounded; the corpus compares the first 18
    ("Test_EveryTuesday_EveryOtherMonth", "FREQ=MONTHLY;INTERVAL=2;BYDAY=TU",
     D(1997, 9, 2),
     [D(1997, 9, 2), D(1997, 9, 9), D(1997, 9, 16), D(1997, 9, 23),
      D(1997, 9, 30), D(1997, 11, 4), D(1997, 11, 11), D(1997, 11, 18),
      D(1997, 11, 25), D(1998, 1, 6), D(1998, 1, 13), D(1998, 1, 20),
      D(1998, 1, 27), D(1998, 3, 3), D(1998, 3, 10), D(1998, 3, 17),
      D(1998, 3, 24), D(1998, 3, 31)]),
    ("Test_EveryOtherYear_onJFM", "FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3",
     D(1997, 3, 10),
     [D(1997, 3, 10), D(1999, 1, 10), D(1999, 2, 10), D(1999, 3, 10),
      D(2001, 1, 10), D(2001, 2, 10), D(2001, 3, 10), D(2003, 1, 10),
      D(2003, 2, 10), D(2003, 3, 10)]),
    ("Test_YearlyWithoutSpecifics", "FREQ=YEARLY;COUNT=10;BYMONTH=6,7",
     D(1997, 6, 10),
     [D(1997, 6, 10), D(1997, 7, 10), D(1998, 6, 10), D(1998, 7, 10),
      D(1999, 6, 10), D(1999, 7, 10), D(2000, 6, 10), D(2000, 7, 10),
      D(2001, 6, 10), D(2001, 7, 10)]),
    # unbounded; the corpus compares the first 11
    ("Test_EveryThursdayInMarch", "FREQ=YEARLY;BYMONTH=3;BYDAY=TH",
     D(1997, 3, 13),
     [D(1997, 3, 13), D(1997, 3, 20), D(1997, 3, 27), D(1998, 3, 5),
      D(1998, 3, 12), D(1998, 3, 19), D(1998, 3, 26), D(1999, 3, 4),
      D(1999, 3, 11), D(1999, 3, 18), D(1999, 3, 25)]),
    # unbounded; the corpus compares the first 39 (13 per year)
    # unbounded; the corpus compares 39 dates: every Thursday of
    # June-August in 1997, 1998, and 1999 (13 per year)
    ("Test_EveryT_but_OnlyJuneJulyAugust", "FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8",
     D(1997, 6, 5), jun_aug_thursdays()),
    ("Test_Election_Day_US",
     "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8",
     D(1996, 11, 5), [D(1996, 11, 5), D(2000, 11, 7), D(2004, 11, 2)]),
    # February 30 is skipped, not clamped
    ("Test_Dont_Return_Invalid_Date",
     "FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5", D(2007, 1, 15),
     [D(2007, 1, 15), D(2007, 1, 30), D(2007, 2, 15), D(2007, 3, 15),
      D(2007, 3, 30)]),
    # the WKST pair: same rule, different week starts, different dates
    ("Test_WKST_Change", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO",
     D(1997, 8, 5),
     [D(1997, 8, 5), D(1997, 8, 10), D(1997, 8, 19), D(1997, 8, 24)]),
    ("Test_WKST_Change", "FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU",
     D(1997, 8, 5),
     [D(1997, 8, 5), D(1997, 8, 17), D(1997, 8, 19), D(1997, 8, 31)]),
]

def wall(d: date) -> str:
    # IcalDateTime::to_string of a 09:00 America/New_York occurrence: the
    # builtin zone table resolves the zone to its standard-time offset.
    return f"{d.isoformat()}T09:00:00-05:00"


HEADER = """///|
/// The S3 expansion cross-check: every first-tier rule string of
/// graham's corpus (`.survey/src/graham_rrule/basic_test.go`),
/// paired with the occurrence list graham's own tests assert. The
/// expectations were lifted mechanically from that file by
/// `tools/gen_s3_corpus_test.py` — they are graham's numbers, not ours.
/// All `DTSTART`s are 09:00 `America/New_York`, which the builtin zone
/// table resolves to its standard-time offset (-05:00); the DST
/// boundary is documented in the README.
///
/// 23 cases cover the first tier: no ordinal `BYDAY`, no negative
/// `BYMONTHDAY`, no `BYSETPOS` — those raise `ExpandError::Unsupported`
/// until S8 and are exercised in `expand_test.mbt`. Unbounded rules are
/// cut off with a `limit` equal to the number of occurrences graham's
/// test compares against; `COUNT`/`UNTIL` rules always end naturally.
///|
struct ExpansionCase {
  /// The graham test function this case came from.
  origin : String
  rule : String
  dtstart : String
  /// The `limit` passed to `expand`.
  limit : Int
  expected : Array[String]
}

///|
fn expansion_cases() -> Array[ExpansionCase] {
  [
"""

DRIVER = """  ]
}

///|
/// A `DTSTART;TZID=America/New_York:...` value, resolved through the
/// builtin zone table the way `parse_events` resolves one.
fn ny_dtstart(text : String) -> @model.IcalDateTime raise {
  let line = @text.parse_content_line(
    "DTSTART;TZID=America/New_York:\\{text}",
    1,
  )
  @model.parse_date_time(line, @model.ZoneTable::builtin_common())
}

///|
test "corpus: first-tier rules expand to graham's expected occurrences" {
  for case in expansion_cases() {
    // Every case names the graham test function it was lifted from.
    assert_true(case.origin.length() > 0)
    let rule = @rrule.parse_rule(case.rule)
    let got = @rrule
      .expand(rule, ny_dtstart(case.dtstart), limit=case.limit)
      .map(o => o.to_string())
    assert_eq(got, case.expected)
  }
}
"""


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    out = [HEADER]
    for origin, rule, dtstart, dates in CASES:
        out.append(
            "    {\n"
            f"      origin: \"{origin}\",\n"
            f"      rule: \"{rule}\",\n"
            f"      dtstart: \"{dtstart.strftime('%Y%m%dT090000')}\",\n"
            f"      limit: {len(dates)},\n"
            "      expected: [\n"
        )
        for i in range(0, len(dates), 3):
            chunk = ", ".join(f'"{wall(d)}"' for d in dates[i:i + 3])
            out.append(f"        {chunk},\n")
        out.append("      ],\n    },\n")
    out.append(DRIVER)
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main()
