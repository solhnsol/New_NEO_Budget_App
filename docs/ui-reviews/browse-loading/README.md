# Browse fixed grid: loading while the days move, and frame measurements (phase 2B-1)

Design and results: `docs/development/phase2b-measurement-and-loading.md`.

## Screenshots (iPhone 18 Pro simulator, real flicks injected; `-demo -demo-trans -browse-temporal -day-read-delay 3000 -day-read-fail-every 3`)

| file | what |
|---|---|
| `01-two-days-loading.png` | two flicks ahead of the reads: both columns say "불러오는 중"; the shared axis is held (not planned on unread days); the rest of the screen stays (a failed or missing visible day no longer replaces the screen with the error page in the fixed grid) |
| `02-later.png`, `03-settled.png` | the reads landed (one of them after a failed attempt and a retry): 15 with its events, 16 read and empty — drawn as an empty day, with no loading mark |

## Measurements (`measurements/`)

- `agg-*`, `agg2-*`: Debug (`-Onone`) runs of `-browse-temporal-script swipes|days|zoom`, five each; `opt-*`: the same on a `-O` build; `slow-*`, `fail-*`: swipes with slow / jittered / failing reads; `touch.txt`: real touches (`-browse-temporal-probe`); `first-run-swipes.txt`: the first run (first `Haptics.snap()` 11 ms).
- `SUMMARY.txt`: each set aggregated by `aggregate.py` (late frames, app vs unattributed time in late turns, nearby marks).
- `time-profile-swipes.txt`: main-thread samples of one swipes run (Time Profiler attached), long busy stretches broken down by `time-profile.py`; `time-profile-run-probe.txt` is that run's probe report.
