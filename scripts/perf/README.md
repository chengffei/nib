# Performance baseline

`sh scripts/perf/run.sh` generates a deterministic ~1,000,000-character document (18,196 lines: headings, CJK and English prose,
lists, tables, code blocks), opens it in the offscreen editor, switches to edit mode and times 100 of each operation in 3 fresh
processes. A sample is the editor's synchronous update plus a forced layout: main-thread work, not frame pacing.
WebKit rounds `performance.now()` to 1 ms, so differences under 1 ms do not show.

Re-run before and after changes to the editor core (`Web/src`) and update the table when a change is intended to move it.

| Date | Commit | Machine | Typing P50 / P95 | Backspace P50 / P95 | Scroll P50 / P95 |
|---|---|---|---|---|---|
| 2026-11-27 | after 0.5.1 | Apple silicon | 7 / 10 ms | 7 / 10 ms | 4–5 / 7 ms |
