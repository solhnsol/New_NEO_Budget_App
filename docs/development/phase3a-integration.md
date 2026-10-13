# Phase 3A — 네 부품 연결 (Draft · 저장 · 인터랙션 · 정밀 말풍선)

기준: `350c6fc`(3A 네 브랜치 병합). 대상은 `-browse-temporal`(DEBUG) 고정 그리드 Browse다. 기존 일정 하나의 **시작·끝 시간 조정**을 처음부터 끝까지 연결했다.

흐름은 다음과 같다. 길게 누르기 → 세션 → 핸들 끌기 또는 ±15분 → 완료(또는 바깥 탭) → 저장 → 편집한 가장자리 기준으로 unfreeze.

## 1. 구조

```
FixedGridBrowseView ──(그리드 이벤트)──▶ FixedGridEditRouter ──(편집 명령)──▶ FixedGridEditor
        ▲  freeze/retarget/unfreeze ◀──┘        ▲                                │ EditDraft
        │                                       └──── draftChanged / commit… ────┤ EventSaveRequest → AppModel.save → EventSavePipeline
        └─ 미리보기 카드 · 핸들 · 말풍선(TrackedPrecisionBubbleOverlay) · 편집 바 ◀──────┘ bubbleInput / message / scopeQuestion
```

- **`FixedGrid/FixedGridEditor.swift`(신규):** `router.editor`의 구현이다. Draft·말풍선 상태·저장을 한곳에 둔다. 세션 상태는 정하지 않고 이벤트로만 응답한다.
  - `Environment`(zone, generation, block 조회, save, haptic)로 앱에서 분리되어 있다. 그래서 테스트는 실제 `CalendarCommandService`와 `InMemoryCalendarProvider`로 돌린다.
- **DEBUG 프로브 편집 부품(`probeEditor`)과 `-browse-temporal-edit-probe-fail`은 없앴다.** `-browse-temporal-edit-probe`는 이제 진단 줄만 보여 준다. 완료·취소는 편집 바에 있다.
- 세션 진입은 프로브 없이 열린다. 기본 Browse(`classic`)와 Release는 그대로다. `-browse-temporal` 자체가 DEBUG 전용이다.

## 2. 결정한 것

| 주제 | 결정 |
|---|---|
| 저장 경로 | **하나로 정했다.** Draft에서 `EventSaveRequest(original: EventSaveOriginal(block:), proposedStart/End: draft)`를 만들고 `AppModel.save` → `EventSavePipeline`으로 보낸다. `EditDraft.editEventInput`는 쓰지 않는다. 저장 직전 원본 재확인은 pipeline이 맡는다. |
| 핸들 끌기 | `EditDraft.drag(_:to:)`를 추가했다. 손가락 시각을 15분 격자의 가장 가까운 선에 맞추고, 하루와 최소 15분 안으로 붙잡는다. 거부하지 않는다. 손가락이 핸들 중심에서 떨어진 거리(grab offset)는 끄는 동안 유지한다. 끌기가 취소되면 시작 전 범위로 되돌린다. |
| 자정 넘김 | Draft의 하루 제한이 상한이다. 여러 날 일정은 길게 누르면 세션을 열지 않고 이유를 말한다(`FixedGridEditor.refusal`). pipeline의 `endLimit`은 `nil`로 둔다. |
| 양 끝 동시 변경(`retime`) | Draft가 항상 격자에 맞춘 값만 넘기므로 정책 스냅 없이 저장해도 된다. 원본이 격자 밖이면 손대지 않은 끝은 그대로 간다. |
| 반복 일정 | `needsScope`가 오면 범위 대화상자("이 일정만" / "모든 반복 일정")를 띄운다. 닫거나 취소하면 `commitFailed` → 편집으로 돌아가고 변경은 유지된다. |
| 거부(`refused`) | 다시 저장해도 소용없으므로 메시지를 보이고 `commitFailed` 후 `cancel`한다. Draft는 버린다. 화면에는 reload된 캘린더 상태가 보인다. 충돌 해결 UI(유지·병합)는 만들지 않았다. |
| 실패(`failed`) | 편집으로 돌아가고 변경은 유지된다. "완료"를 다시 누르는 것이 재시도다. pipeline이 원본부터 다시 확인한다. |
| 바깥 탭 기본값 | `commit`을 유지했다(캘린더 앱의 드래그 유지와 같다). `askExit`는 기본 정책에서 나오지 않는다. 나오면 confirm으로 답한다. |
| 말풍선 | 선택된 핸들에, 끄는 동안에도 띄운다. 끄는 동안 ±버튼은 끈다. 닫기는 같은 핸들 탭과 같다(선택 해제). 저장 중에는 숨긴다. 버튼 켜짐은 `EditDraft.canStep`으로 정한다. |
| 말풍선 위치 | 핸들 중심을 1× 좌표로 한 번 구하고, `PrecisionAnchorTracker`가 매 프레임 `y × zoom − offset`으로 따라간다. 세션 중에는 분할이 고정되어 있어 이 계산이 성립한다. 아래 여백은 편집 바의 실제 높이 + 8pt다. |
| 미리보기 | 원래 카드는 그대로 두고, Draft 위치에 카드를 덧그린다. 바뀌지 않았으면 윤곽선만, 바뀌었으면 캘린더 색으로 채우고 제목·새 시간을 쓴다. 바뀐 동안 원래 카드는 30%로 흐리게 한다. 계획(엔진 결정)은 다시 돌리지 않는다. 핸들 좌표(`place`)도 Draft 위치를 쓴다. |
| 외부 변경 | `dataRevision`이 바뀌면 `EditDraft.noteReload`와 `observe(.lookup)`를 실행한다. `.changed`/`.deleted`이면 편집 바에 경고를 보인다. 저장의 최종 판정은 pipeline이 한다. |

## 3. 검증

- **패키지 `EditDraftTests` +4:** 끌기 스냅·반올림, 한계에서 붙잡기, 짧은 원본, `canStep`. 패키지 전체 467 + 90 통과.
- **앱 `FixedGridEditorTests` 11개:** 실제 서비스와 in-memory 캘린더를 router에 연결해 다음을 확인했다.
  - Draft·끌기·말풍선 단계·닫기, 끌기 취소, 취소 시 쓰지 않음
  - 완료 저장과 편집한 끝 기준 앵커
  - 반복 범위 질문(무응답은 편집 복귀, `thisOccurrence` 저장)
  - 외부 변경 거부, 실패 후 재시도, 캘린더 없음, 자정 넘김 거부, 다른 일정으로 옮기기, reload 충돌 표시, 편집 바 문구
  - 앱 전체 479개 통과. Release 빌드 성공.
- **시뮬레이터 실터치:** `docs/ui-reviews/edit-integration/` README 참고.

## 4. 남은 것

- **1×에서는 저장 후 앵커가 가장자리를 붙잡지 못한다.** 스크롤할 여유가 없어서다. 축이 새 계획으로 이징하면 카드가 움직인다. 줌 상태에서는 지금처럼 0pt로 유지된다.
- **충돌 해결 UI가 없다.** 지금은 거부 시 버리고 캘린더 상태를 보여 준다.
- 몸통 끌기(이동)와 빈 곳에서 만들기는 없다. 핸들 근처 자동 스크롤도 없다.
- VoiceOver 실기기 확인, EventKit 실기기 저장 실패 확인은 하지 않았다.
- **렌더 문제를 하나 발견했다(편집과 무관).** 데모에서 14일 "팀 회의"를 13:30 시작으로 바꾸면, 13일 "스터디" 카드 안 거래 줄 "카페/분식"의 글자가 겹친다. 날짜를 옮겼다 돌아와도 남는다. 세션이 끝난 뒤의 일반 계획에서 생기므로 별도 작업으로 남겼다.
