# Browse on the fixed grid: continuous day swipe and pinch zoom (phase 2A)

Only with `-browse-temporal` (DEBUG builds read it; a release build is always the existing Browse — a Release build of the app compiles and shows the existing Browse). Editing, creating and the EventKit save path are not touched: the editor is never called from this view, and the screen says so.

## What is in the product now

`FixedGridBrowseView` hosts the product's `DayRenderPlan` cards, lines, overflow cards and touch plan inside the prototype's verified `PinchZoomScrollView` (now compiled in every build, unchanged), moved by the prototype's `DayMoveModel`, `DayAxisGeometry`, `ContinuousDayAxis` / `AnchorState` and `HorizontalDragClassifier`. No new state machine: `DayMoveModel` is the only one.

- **Days**: a finger drags the day line directly (a swipe starts after 4 points sideways). Letting go flicks to a day or back; a finger that comes down on a moving line stops it and takes over; the next flick may start before the last has landed. Every column and the hour axis use the one partition that is the blend of the two planned windows around the position. A release carries the days at most one day from the selected day (`FixedGridMove.held`), as Browse does; a drag is held to one day from it (`DayPrefetchPolicy.clampedPosition`).
- **Selected day**: `AppModel.selectedDay` follows when the line comes to rest, or at once when a new touch takes over a move that has already passed a day (so the next flick is measured from the day the person sees). The week strip's highlight follows `FixedGridMove.pending` (the nearest day, -1…+1) while moving; the header strip under it follows the same position. A change from outside (week strip, arrows, "오늘") runs the days to the new day (spring, up to 3 days; further is a jump).
- **Zoom**: pinch 1×…8× about the fingers' centre (time under the fingers stays under them), one-finger scroll and its inertia, rubber band back inside 1…8. At 1× the whole day is shown. Day moves on a zoomed view keep the time at the middle of the screen (`AnchorState`).
- **Data**: `AppModel.prefetch(forPosition:target:)` is called whenever the days a position needs change (not per frame); the cache keeps hop+1 days ahead (`DayPrefetchPolicy`); `AppModel.cachedTimeline(for:)` / `dataRevision` let the grid draw any day around its position.
- **Planning**: the partitions of the windows around the selected day are planned **off the main thread** when the day, the data or the room change (`FixedGridBrowseModel.warm`); a frame only finds them. The engine's decisions are made per window and rested zoom (a quarter unit is one decision); a pinch frame uses the last decision and never runs the engine. Nothing in a gesture frame plans or analyses a day.

## Recordings and screenshots (iPhone 18 Pro simulator, real touches injected; `-demo -demo-trans`)

| file | what |
|---|---|
| `session-gestures.mp4` | short slow drag (returns), slow drag past half (next day), hard flick (one day), drag and back before release (stays), pinch out (~4.7×), day swipe at 4.7× (12:00 / 1시 / 2시 stay at the same heights), one-finger scroll. The pinch back in at the end of the recording did not register; `06-after-pinch-in-1x.png` is the second attempt (back at exactly 1×, the whole day) |
| `zoom-script-1x-8x.mp4` | `-browse-temporal-script zoom`: 1 → 8 → 1 |
| `01…06-*.png` | rest at 1×, after a slow drag, after a flick and a reversal, zoomed, a day move while zoomed, back at 1× |
| `zoom3-dense.png`, `zoom3-overlap.png`, `zoom8-txn.png`, `zoom3-text3x.png` | dense, overlap, transaction clusters (8×) and accessibility XXL text at 3× |

Not injectable with the tools here: a second flick while the first is still settling (calls are ~1 s apart). It is covered by the model-level simulation in `FixedGridNavigationTests` (five flicks within a second; position never more than a day from the selected day; days committed one at a time) and by `-browse-temporal-script days` (rapid retargets, a reversal in flight), which drives the same `DayMoveModel` and ticker.

## Measured (Debug build, iOS simulator at 60 Hz, `-demo-dense`, the `-browse-temporal-script` runs; `-browse-temporal-log <path>` writes these)

| run | step cost | display frames late (>1.5× median) | view build | notes |
|---|---|---|---|---|
| days (rapid taps, reversal, 8 s) 1× | mean 0.09 ms, p99 0.26, max 0.30 | 3 of 485 (max 50 ms) | mean 0.09 ms, max 0.40 | planned off main 10, in a frame 1 (the first draw), engine runs 5 |
| days at 3× | mean 0.10, p99 0.45, max 0.62 | 6 of 488 | mean 0.08, max 0.35 | engine runs 9 |
| days at 8× | mean 0.12, p99 0.46, max 0.84 | 7 of 491 | mean 0.08, max 0.31 | engine runs 9 |
| zoom 1 → 8 → 1 (2.8 s) | mean 0.15, p99 0.40, max 1.4 | 0 of 164 | mean 0.21, max 5.8 | engine runs 32 (the script's zoom is not a pinch: a real pinch holds the last decision) |

Day reads while moving: 4 over the two-pass script, cache 8 days (capacity 12); one read per day, none repeated. Unit tests (`FixedGridNavigationTests`, 12) check: planned windows equal the phase-1B window and layout at rest, background planning with zero in-frame plans, blends at every position, replanning only the windows that read a changed day, a pinch running the engine 0 times, DST window without the engine, release/hop rules and chained flicks, drag clamped at the edges, time at the middle of the screen unchanged (< 1e-6 minute) while days move at 3× and 8×, every event and transaction drawn once at 1/3/8× on overlap, dense, 32 events, text 3.0×, transaction-dense and midnight fixtures with the same minute at the same height in every column, selected day / cache / strip agreement after chained moves.

## Remaining risks

- **Main-thread hitches of 50–120 ms** appear a few times per run in Debug (3–7 of ~490 frames; step interval max 86–123 ms). A sampling of the main thread shows SwiftUI's own view update and layout (the app is idle ~80% of the run); the cause is not isolated. Release and a real device were not measured.
- Chained flicks begin from the day the move has reached; if the next window's days have not been read yet (a flick storm faster than the reads), their columns are empty until the read lands (`prefetch` reads nearest first).
- The engine's decisions pop where the window nearest the position changes (halfway between two days): events whose overflow/inside rows differ between the two windows change at that moment. The partition itself is continuous.
- At zoom the engine's decisions are made at the rested zoom: a pinch shows the previous decision until it ends (one new decision at the end).
- Fixed-grid limits from phase 1B remain (large text and 30+ events leave few titles; overlapping events with an overflow card on the same hour overlap each other's text; DST days are drawn without the engine; no editing).
- Taps count only when the days are at rest; a long press only draws attention to the notice. VoiceOver was not run with the pinch scroll view (the cards keep their labels and default action in the hosted SwiftUI; not verified on a device).
