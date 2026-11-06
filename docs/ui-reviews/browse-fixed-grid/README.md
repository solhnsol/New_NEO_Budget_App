# Browse on the fixed Temporal Grid (phase 1B)

Internal switch `-browse-temporal` (DEBUG builds only; the default and every release build are the existing Browse). The grid is read-only: the product's `DayRenderPlan.Prepared`, `ElapsedMinuteAxisMapping` and `TemporalAxisMapping` on 12 equal-height hour cells, the product's cards/lines/overflow cards, the existing week strip and one-day swipe. The timeline editor is never called; a line under the header says so (`고정 격자 보기 · 일정 만들기·이동·시간 조정은 아직 지원하지 않습니다`), and a long press only draws attention to it.

Launch: `tools/dev/check.sh ui -demo -demo-trans -browse-temporal` (classic: without the last argument). iPhone 18 Pro simulator, 3x.

## Screenshots (classic / fixed)

| case | classic | fixed |
|---|---|---|
| `-demo-trans` | `trans-classic.png` | `trans-fixed.png` |
| `-demo-dense` | `dense-classic.png` | `dense-fixed.png` |
| `-demo-overlap` | `overlap-classic.png` | `overlap-fixed.png` |
| `-demo-txn` (transactions) | `txn-classic.png` | `txn-fixed.png` |
| text size accessibility XXL (≈3x) | `text3x-classic.png` | `text3x-fixed.png` |

Behaviour: `tap-event-detail.png` (an event opens its detail sheet: time, calendar, Activity facts, linked spending), `tap-activity-sheet.png` ("활동 정보" opens the Activity sheet, the link to the Activity is kept), `swipe-next-day.png` (existing one-day swipe, week strip follows).

## What was checked (`FixedGridBrowseTests`, all 29 fixtures of `TemporalGridFixtures`, incl. dense, 32 events, text 3.0x, transaction clusters, midnight)

For both modes on the same days: same events (same `EventBlock`, i.e. same times, links, state), every transaction exactly once (line, overflow member or inside an event) and the same set in both modes, an event's top is the axis y of its own start and its bottom of its end (never moved for text), touch areas ≥ 44 pt for events/lines/overflow cards, every event reachable by some touch (itself or in a choice), VoiceOver text present for every line and overflow, every touch kind maps to the same sheet as in Browse. DST spring (23 h) and fall (25 h): all events/transactions present, drawn on the wall-clock axis without an engine layout, the fall-back axis refuses to give a saved time (`preservesInstantIdentity == false`). Midnight and multi-day events fill the edges of the axis.

## Measured

Per frame (window lookup + 2 day placements, 200 frames, Debug simulator): 32 events 0.558 ms, transaction cluster 0.034 ms, short dense events 0.110 ms, text 3.0x 0.129 ms. The first window of a day set (planner + layout engine, once): 3.3–7.8 ms. Over 300 redraws: 1 plan, 1 engine run, 2 day preparations; moving one day: +1 plan, +1 engine run, 2 preparations; a different room or text size: a new window.

Titles written on screen, classic → fixed (two days; the loss is the hour-cell model, not a fault of the hookup):

| fixture | classic | fixed | | fixture | classic | fixed |
|---|---|---|---|---|---|---|
| 3 busy/quiet | 14 | 13 | | 13 short events spread | 0 | 6 |
| 5 long + short | 8 | 2 | | 14 short events dense | 0 | 0 |
| 9 small viewport | 14 | 11 | | 15 long + short overlap | 8 | 4 |
| 10 large Dynamic Type 2.2x | 9 | 0 | | 17 transactions very dense | 1 | 2 |
| 18 32 events | 6 | 0 | | 19 Dynamic Type 3.0x | 9 | 2 |
| 20 `-demo-trans` | 4 | 7 | | 7 many overlapping | 5 | 6 |

Transaction lines + overflow cards drawn (fixed/classic): 17 → 2/15, 14 → 4/6, 16 → 4/6 (the fixed grid folds more into overflow cards; all ids stay reachable through them).

## Known limits

- The axis changes shape (snaps) when a swipe lands on the next day: the continuous date space is not integrated.
- With large text (2.2x and up) and with 30+ events the equal-height cells leave little room: few titles are written (see the table). Tap opens the details.
- A day with a daylight-saving change is drawn without the engine's decisions (every transaction a line).
- The repeated hour of a fall-back day overlaps on the axis (both passes share a position).
- No zoom, no pinch, no editing in this mode.
