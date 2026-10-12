# Browse fixed grid: the edit interaction (phase 3A)

Design and results: `docs/development/phase3a-edit-interaction.md`.

Real touches injected on an iPhone 18 Pro simulator, launched with `-demo -browse-temporal -browse-temporal-edit-probe`.

- DEBUG only. The probe stands in for the draft, the time bubble and the save.
- A handle drag marks the draft "변경" (changed). A commit answers after 0.35 s with the event's own times.
- No time and no calendar data is changed.
- The purple line shows the session (`#id`, handle state, changed / saving), the counters, the anchor drift after an unfreeze, and the last command.

| file | what |
|---|---|
| `01-enter-session.png` | A long press on "영어 회화" opens session #1: the grid is frozen, the handles are drawn, no handle is chosen, and the probe gains 취소 (cancel) / 완료 (done). |
| `02-handle-tap-selects.png` | A tap on the start handle: "시작 선택" (start chosen), so its time bubble would show. |
| `03-handle-drag-dirty.png` | A drag from the end handle, diagonally: the end is chosen after the drag, the draft is "변경" (changed), and "날짜 이동 없음" (days did not move). |
| `04-outside-tap-releases-handle.png` | First tap on empty grid: only the chosen handle is released. The session stays, with its change. |
| `05-second-outside-tap-commits.png` | Second tap outside: the change is committed (default policy). The grid stays frozen until the answer, then unfreezes at the edited edge: "앵커 오차 0.00pt" (anchor drift 0.00 pt), `ended(committed)`. |
| `06-day-change-commits-and-moves.png` | Session #2 with a change, then a tap on "15" in the week strip: the grid lets go at once, the change is committed, and the days move to the 15th. |
| `07-other-event-retargets.png` | Session #3 on "영어 회화", then a tap on "팀 회의" with no change: the session moves to it (still #3, handles on 팀 회의) without unfreezing. |
| `08-cancel-ends.png` | 취소 (cancel): `ended(cancelled)`, no session. |

The anchor at 3× with a plan that moves under the session is checked by `afterASaveTheEditedEdgeStaysAtItsHeightWhileTheAxisEasesToTheNewPlan()`. In the probe nothing really changes, so the plan does not move.
