# Third-Party Notices

This project is licensed under the Apache License, Version 2.0 — see
[LICENSE](LICENSE). It contains no third-party implementation code; the only
third-party material incorporated is the RRULE test corpus listed below.

## graham/rrule — MIT License

- Upstream: <https://github.com/graham/rrule>
- Incorporated material: the RRULE strings of its `basic_test.go` test suite
  (the RFC 5545 Appendix A examples plus the RFC 2445-era sub-daily examples,
  as selected and arranged by that suite), used as behavioral-parity test data
  in `ical/rrule/corpus_test.mbt` and `ical/rrule/expand_corpus_test.mbt`.
  No implementation code is derived from the project.

```
MIT License

Copyright (c) 2023 Graham Abbott

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
