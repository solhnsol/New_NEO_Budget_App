# Browse fixed grid: gesture ownership and edit sessions (phase 2B-3)

Design and results: `docs/development/phase2b3-gesture-ownership-and-edit-sessions.md`.

Real touches injected on the iPhone 18 Pro simulator, `-demo -browse-temporal -browse-temporal-edit-probe` (DEBUG: a long press on an event opens an edit session with nothing to edit; the purple line counts what it sees; no data is changed).

| file | what |
|---|---|
| `01-browse-tap-selects.png` | browse: a tap on an event opens its details (the tap is now a UIKit recognizer next to the pinch, the day swipe and the scroll) |
| `02-long-press-opens-session.png` | a long press on "영어 회화": the notice is emphasised, a session opens (partition and decisions frozen), the handles are drawn, the original reads "외부 변경 없음" |
| `03-handle-drags-no-day-move.png` | a sideways drag from the start handle and a vertical one from the end handle: "핸들 끌기 2(10)", "날짜 이동 없음"; a sideways swipe on empty grid during the session did not move the days either |
| `04-session-ended-swipe-moves.png` | a handle tap counted, a tap on empty grid ended the session ("세션 없음"), and a swipe moves the days again |
| `05-session-pinch-scroll.png` | in a new session: pinch out and scroll work; the handles follow the zoomed card |

`measurements/`: `i-base-*` / `i-new-*` swipes, `j-base-*` / `j-new-*` rubber — the 2B-2 build and this one, interleaved in one session, five each (`aggregate.py '<glob>'`).
