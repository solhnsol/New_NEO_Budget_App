# Phase 1A — rendering foundations for the fixed Temporal Grid in Browse

Base: `88d43a5`. Browse UI, gestures, editing, EventKit save/rollback and the DEBUG Temporal Grid are unchanged. Nothing here replaces Browse's swipe.

## 1. Wall-clock adapter (`Timeline/WallClockProjection.swift`)

`DayWallClock` (Phase 0) maps a day's elapsed minutes (1380 / 1440 / 1500) to wall-clock minutes. `WallClockProjection` + `ElapsedMinuteAxisMapping` put the **elapsed-minute model, the engine and every EventKit `Date` untouched** and only change *where* an elapsed minute is drawn on a wall-clock axis.

- Elapsed → wall is exact for an instant. A span's bottom is the furthest wall minute it reaches (`DayWallClock.wallRange`), so a span across a repeated hour is drawn to the end of the first pass, a span ending where a gap begins ends before the gap.
- `TimeAxisMapping.y(bottomOfSpanFrom:to:)` carries that rule (default: `y(endMinute:)`); `blockFrame` and `DayRenderPlan` use it.
- **Contract — the inverse is display-only.** `minute(atY:)` / `displayElapsed(forWall:)` of a DST-ambiguous position (skipped or repeated wall minute) names the first real minute and reports `isUnambiguous == false`. It must never feed an edit or save. Enforced by `TimeAxisMapping.preservesInstantIdentity` (false on a fall-back day): `TimelineEditPlanner.preview` returns nil, `TimelineEditor.beginCreate` refuses, `createPreview` has a precondition. Spring-forward days keep identity (the gap is never a source of a saved time).
- Engine input in wall minutes: `WallClockProjection.projected(_:)` keeps every id, title and amount. On DST days the plan is drawn with `layout: nil` (the engine lays out an elapsed day, not a wall axis); every transaction is still a line at its wall time.

## 2. Static / dynamic split of `DayRenderPlan`

`DayRenderPlan.Prepared` holds everything that depends only on the day's data, role and engine layout (event/transaction semantics, overlap analysis, inside rows, link/line identities). `init(prepared:geometry:…)` only places (axis y, widths, presentation by height). The old initializer delegates to it, so there is one code path. `DayPlanPreparations` (LRU, 8 days) keys by `timeline ==`, role and `layout ==`; `TimelineGridView` holds one, so zoom, date interpolation, text size and focus never re-prepare.

Equivalence: `DayRenderPlanEquivalenceTests` records golden FNV-1a digests of the full plan description on the **old** code (regular, many-overlap, midnight/multi-day, transaction-heavy days, several widths/zooms); they pass unchanged on the new path. `WallClockProjectionTests` also checks prepared-then-placed == whole plan at three zooms.

## 3. Prefetch policy (`Model/DayPrefetchPolicy.swift`, `AppModel.prefetch`)

- `maximumHop` is **1** for Browse (a swipe never skips a day); `DayMoveModel` takes `maximumHop:` (default 3 stays for the DEBUG grid).
- Window `D` shows `D…D+1` and plans `D−1…D+2`. At position `p` between two days both windows are used: needed = `floor(p)−1 … ceil(p)+2`, widened to the move's target.
- Cache margin = hop + 1 (2), capacity 12 (was 8 at margin 1); at rest, `loadMissing(extra: hop+1, policy:)` fills it. `prefetch(forPosition:target:)` reads only missing needed days (nearest first), never changes `selectedDay`, is dropped if a `reload` overtakes it, and protects the on-screen pair and the needed range from eviction.
- A drag is clamped to ±hop from the selected day (`clampedPosition`), which keeps every position inside what is kept.

## Measured (simulator, iPhone 18 Pro, 14 events + 24 transactions)

| | value |
|---|---|
| Plan per frame, whole plan rebuilt (old path) | 0.332 ms |
| Plan per frame, placed from prepared | 0.129 ms (2.6× less) |
| Date-blend frame (partition interpolation + placing) | 0.136 ms |
| Static preparations over 240 zoom frames + 241 blend frames | **1** (hits 480) |
| Fast 30 consecutive hops (4 positions per hop) | 1.00 day read / hop, cache 8 days (capacity 12), both shown days present at every selection |

## Remaining constraints

- Browse still draws on `TimelineGeometry`; the adapter is used by tests and ready for the fixed grid, not wired into Browse screens.
- Fall-back day: the repeated hour overlaps (both passes at the same y); no create/move/resize on that day's grid axis until Phase 1B chooses the UX (see integration doc).
- DST days use `layout: nil` (no engine packing of inside-transactions) on the wall axis.
- `prefetch` is not yet called by Browse's pager; hop 1 matches today's swipe, so no behaviour change.

## Phase 1B readiness

Ready: rendering base (adapter, split, cached preparation), data availability by position, hop policy. Phase 1B can wire the fixed grid axis into Browse behind the existing swipe, calling `prefetch(forPosition:)` from the move, and decide the fall-back-day editing UX.
