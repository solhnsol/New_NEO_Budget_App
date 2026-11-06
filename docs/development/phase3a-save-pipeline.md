# Phase 3A — 저장 어댑터 (`EventSavePipeline`)

대상: 편집 세션(고정 그리드 Draft)의 시간 변경을 캘린더에 저장하는 경로. 이번 단계는 **저장 어댑터와 입력 계약**만 만든다. Browse UI·제스처·그리드 렌더링, `TimelineEditor`, EventKit provider는 바꾸지 않았다. Draft 모델(A)과는 `EventSaveRequest` 하나로 만난다.

## 1. 기존 경로 분석

| 단계 | 위치 | 의미 |
|---|---|---|
| 명령 생성 | `TimelineEditPlanner.command` | move → `moveEvent(.proposedStart)`, 시작 핸들 → `resizeEvent(.start)`, 끝 핸들 → `resizeEvent(.end, clampToDayEnd: 그날 끝)`. 기대 revision = 블록의 `revisionToken` |
| 반복 범위 선택 | `TimelineEditPlanner.scopeOptions`, `TimelineEditor.finish/chooseScope` | 반복 일정이면 쓰기 전에 묻는다. `thisOccurrence`(지원 시), `allInSeries`(지원 시 + 날짜가 바뀌지 않을 때). `thisAndFuture`는 키가 바뀌므로 절대 제시하지 않음. 제시하지 않은 범위를 고르면 롤백 |
| 저장 | `CalendarCommandService.perform` | `loadEditableEvent`(없음 → `eventNotFound`, 읽기 전용 → `eventNotEditable`, revision 불일치 → `conflict`) → 편집 정책(15분 스냅·최소 15분·끝 클램프) → `resolveScope`(반복이면 범위 필수, 미지원·날짜 변경+시리즈 거부) → provider `updateEvent`(기대 revision 재확인) → 로컬 Activity 요약 갱신(실패해도 이벤트는 정상) |
| EventKit | `EventKitCalendarProvider.updateEvent` | 접근 → 캘린더 → 이벤트 → 범위 → revision 순서로 검사, `thisOccurrence`는 `.thisEvent` 저장, `allInSeries`는 마스터를 같은 시각 이동·길이로 `.futureEvents` 저장. 저장 실패는 `saveFailed(retryable:)`로 값 반환 |
| 롤백 | `TimelineEditor.run/rollback` | 미리보기는 편집기 상태일 뿐이라 캘린더에 쓴 적이 없다. 결과와 무관하게 `reload` 후 미리보기를 지운다(= 캘린더의 진실 표시). `saveFailed(retryable: true)`만 재시도 가능(`EditFeedback.canRetry`), `lastCommand`를 그대로 다시 보냄 |

## 2. 어댑터 (`Sources/NEOBudgetCalendar/Commands/EventSavePipeline.swift`)

쓰기는 직접 하지 않는다. **위 경로를 그대로 호출**하고 앞뒤에 검사만 더한다.

1. **저장 전 재확인:** 대상 이벤트를 다시 읽어 원본과 비교한다. revision이 있으면 revision, 그리고 **실제 시작·끝**(자르지 않은 값, ms 단위)이 모두 같아야 한다.
   - 없음 → `refused(.targetGone)`
   - 다름 → `refused(.targetChanged(current:))` (revision이 같아도 시각이 다르면 거부)
   - 읽기 전용 → `refused(.notEditable)`
2. **명령 결정:** `TimelineEditPlanner.command`와 같은 명령을 만든다(앱 테스트로 동일성 확인).
   - 양 끝이 같은 만큼 이동하면 `move`, 시작만 바뀌면 `resizeStart`, 끝만 바뀌면 `resizeEnd`
   - 양 끝이 다르게 바뀌면 `editEvent(time:)`. 이 경우 검증은 하지만 스냅은 하지 않는다. 편집기에는 없던 경우다
   - 바뀐 것이 없으면 `unchanged`이고 쓰지 않는다
3. **반복 범위:** 현재 이벤트가 반복이면 `scopeOptions`(편집기와 같은 규칙)로 고른다.
   - `scope == nil`이면 `needsScope(options)`를 돌려주고 쓰지 않는다
   - 제시하지 않은 범위는 `refused(.scopeNotOffered)`를 돌려주고 쓰지 않는다
   - 단일 일정에서는 scope를 무시한다(`thisOccurrence`)
4. **쓰기:** `CalendarCommandService.perform` 한 번. 기대 revision은 **원본의** revision이다. 그래서 확인과 쓰기 사이의 변경도 서비스와 provider가 `conflict`로 막는다.
5. **실패 후 재확인:** provider 실패 시 이벤트를 다시 읽는다.
   - 없어졌으면 `targetGone`
   - 바뀌었으면 `targetChanged`
   - 원본 그대로면 `failed(originalVerified: true)`
   - `retry`는 `saveFailed(retryable: true)`이고 원본이 확인됐을 때만 같은 요청으로 채워진다. 다시 읽지 못하면(접근 상실 등) `originalVerified: false`, `retry: nil`
6. **성공:** `saved(EventSaveReceipt)`
   - 캘린더가 지금 가진 이벤트(시리즈 변경이면 편집한 회차), 실제 `start`·`end`(`Date`), 원본, 사용 범위, 보낸 명령을 담는다
   - 로컬 후속 작업이 실패했으면 그 사유(`localFailure`)를 담는다
   - 정책이 스냅·클램프했으면 `matchesProposal == false`

어댑터는 상태가 없다. 재시도는 `failure.retry`를 다시 `save`하는 것이고, 매번 1번 재확인부터 다시 한다.

**바뀐 기존 코드:**
- `CalendarCommandService.event(_:)`: 읽기 전용 메서드 추가(provider `event` 위임)
- `AppModel.savePipeline` / `AppModel.save(_:)`: 저장 후 날짜를 다시 읽는다. 편집기와 같은 규칙이고, `needsScope`·`unchanged`는 읽지 않는다

명령·정책·provider·EventKit의 저장과 롤백 의미는 그대로다.

## 3. Draft 결합 계약

```swift
EventSaveOriginal(key:revisionToken:start:end:)        // 세션 시작 시 고정. EventSaveOriginal(block:)은 블록의 실제(unclipped) 범위를 쓴다
EventSaveRequest(original:proposedStart:proposedEnd:scope:endLimit:)
pipeline.save(request) -> EventSaveResult              // 또는 AppModel.save(request)
```

| Draft 쪽 값 | 요청 필드 |
|---|---|
| 이벤트 id (`CalendarEventKey`) | `original.key` |
| 세션 시작 시 revision | `original.revisionToken`. `FixedGridEditBaseline.Target.revisionToken`과 같은 값 |
| 세션 시작 시 실제 시작·끝 | `original.start/end`. 그날 분(minute)이 아니라 실제 `Date`. 자정을 넘는 일정도 하나의 범위 |
| Draft의 실제 시작·끝 | `proposedStart/End` (어댑터가 ms로 반올림) |
| 사용자가 고른 반복 범위 | `scope`. 처음엔 `nil`, `needsScope`를 받으면 `request.scoped(_:)`로 다시 |
| 끝 핸들 상한 (선택) | `endLimit`. 편집기는 그날 끝을 넘긴다. 고정 그리드가 자정 넘김을 허용하면 `nil` |

결과별 Draft 처리:

| 결과 | Draft 처리 |
|---|---|
| `saved` | Draft 종료, 영수증 시각으로 표시 |
| `needsScope` | 범위 선택 UI 표시 |
| `refused(.targetChanged/.targetGone)` | Draft 유지·폐기를 결정(UI는 이번 범위 밖) |
| `failed` + `retry` | 재시도 버튼 |
| `failed`, `retry == nil` | 원본이 다시 읽힐 때까지 대기 |

## 4. 검증

- **`Tests/NEOBudgetCalendarTests/EventSavePipelineTests.swift` (26개):** 실제 `CalendarCommandService` + `InMemoryCalendarProvider`
  - 명령 매핑(move·두 핸들·양끝·무변경), 블록의 실제 범위(자정 넘김), revision 같고 시각 다른 경우 불일치
  - 이동·각 핸들·양끝 저장과 반환값, 스냅 결과 반환, 최소 길이 클램프(기존 정책 그대로), 무변경·역전 범위는 쓰지 않음
  - 외부 수정·외부 이동·삭제·읽기 전용 거부, 확인 후 쓰기 전 끼어든 변경 → 서비스 `conflict`
  - 저장 실패 시 원본(revision 포함) 보존 → `retry`로 성공, 재시도 불가 실패, 실패 중 외부 수정·삭제, 접근 상실(확인 단계·쓰기 단계), 일시적 읽기 오류
  - **반복:**
    - 범위 질문(날짜 변경 시 `thisOccurrence`만), 질문 → 선택 → 저장
    - `thisOccurrence`는 그 회차만 바꾸고 키를 유지한다. 다른 날로 옮기는 것도 저장된다
    - `allInSeries`는 네 회차를 모두 같은 시각·길이로 바꾸고, 편집한 회차를 반환한다
    - 시리즈가 바뀐 뒤 옛 원본으로 저장하면 거부된다
    - 날짜 변경 + 시리즈, `thisAndFuture`는 거부된다. 시리즈 미지원 provider에서도 확인했다
    - 시리즈 저장이 실패하면 어떤 회차도 바뀌지 않고 재시도된다. 삭제된 회차는 거부된다
- **`OnAllAppTests/EventSavePipelineAppTests.swift` (2개):**
  - 단일·자정 넘김·반복 블록 × 4가지 변경 × 3가지 범위 × 2가지 provider에서 `TimelineEditPlanner.command`/`scopeOptions`와 동일
  - 데모 `AppModel`에서 반복 일정 질문(읽기 없음) → `thisOccurrence` 저장 → reload 후 화면 블록 = 영수증 → 같은 원본 재저장은 `targetChanged`
- **`tools/dev/check.sh full`:** 패키지 441 + 90, 앱 440 통과(이전 415 + 90, 438).

## 5. 남은 것

- 충돌(`targetChanged`/`targetGone`) 시 Draft UI: 유지·폐기·최신으로 다시 맞춤.
- 양 끝이 함께 바뀌는 `retime`은 편집 정책 스냅을 거치지 않는다. Draft가 스냅된 값을 넘긴다고 가정했다. 정책이 필요하면 `TimelineEditPolicy`에 두 끝 편집을 추가해야 한다.
- EventKit 실기기에서 저장 실패 후 원본 보존 확인(`Platform/iOS/EventKitContractHost`)은 이번에 돌리지 않았다. provider 계약과 기존 EventKit 경로는 바꾸지 않았다.
- 생성(`createEvent`)과 삭제는 이번 어댑터 범위 밖이다.
