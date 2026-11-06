# Phase 3A — Draft Core (`EditDraft`)

기준: `b470be0`(Phase 2B-3). 브랜치 `phase3a/draft-core`.

기존 일정 하나의 시간 편집을 저장 전까지 들고 있는 **순수 모델**과 테스트만 추가했다. UI, 제스처, EventKit 저장 코드는 바꾸지 않았다.

- 파일: `Sources/NEOBudgetCalendar/Editing/EditDraft.swift`(모듈 `NEOBudgetCalendar`, 플랫폼 타입 없음)
- 테스트: `Tests/NEOBudgetCalendarTests/EditDraftTests.swift`(22개)

## 1. 계약 (다른 세션이 기대해도 되는 것)

1. **범위는 절대 시각이다.** `range: TimedRange`(unix ms)는 이벤트의 실제 시작·끝이며, 열에 잘린 분(`startMinute`)이 아니다. `startDate`/`endDate`는 같은 시각의 `Date`다.
2. **원본은 불변이다.** `original: Snapshot`은 Draft를 만들 때 한 번 찍고 바뀌지 않는다. 이벤트 ID·캘린더 ID(`key`), 원본 revision token, 제목, 시간, 편집 가능 여부, 반복 회차 여부가 들어 있다.
3. **Draft에는 원본 아니면 유효한 범위만 있다.** 모든 변경은 `issue(start:end:)` 한 곳을 통과하고, 거부된 변경은 `EditDraftError`를 던지며 Draft를 **전혀 바꾸지 않는다**.
4. **취소는 Draft를 버리는 것이다.** 아무것도 쓰지 않으며 원본은 그대로다. 화면에서 원래대로 되돌리기만 하려면 `revert()`.
5. **충돌은 원본 기준으로 판정만 한다.** 해결(유지·폐기·병합)과 저장은 호출자 책임이다. 저장은 원본 revision을 기대값으로 보내므로, 그 사이 바뀐 이벤트는 provider가 `.conflict`로 거부한다(덮어쓰지 않음).
6. **이번 단계는 하루 안의 시간 일정만.** 종일·읽기 전용·유령(삭제된) 블록·이미 여러 날에 걸친 일정은 Draft를 만들 수 없다. 범위는 그 날의 `[00:00, 다음 날 00:00]`을 벗어날 수 없다(끝이 정확히 자정인 것은 허용). 자정 넘김 UI는 없다.

## 2. 공개 API

### 만들기

| API | 설명 |
|---|---|
| `EditDraft(event: CalendarEvent, timeZone:, generation: Int = 0) throws(EditDraftError)` | provider 스냅샷에서 |
| `EditDraft(block: EventBlock, timeZone:, generation: Int = 0) throws(EditDraftError)` | 타임라인 블록에서. 잘린 분이 아니라 `startUnixMilliseconds`/`endUnixMilliseconds`를 쓴다 |
| `EditDraft(original: Snapshot, timeZone:, generation: Int = 0) throws(EditDraftError)` | 이미 만든 스냅샷에서 |

- `timeZone`: 격자가 그려지는 표시 시간대. 날짜 판단과 15분 격자의 자정 기준이 된다.
- `generation`: 원본을 읽은 데이터 세대(예: `AppModel.dataGeneration`).
- 거부: `.allDay`, `.readOnly`, `.eventMissing`, `.spansDays`.

### 읽기

| API | 의미 |
|---|---|
| `original: Snapshot` | 시작 시점의 원본(불변) |
| `key`, `eventID`, `calendarID` | 원본의 식별자 |
| `originalRevisionToken: String?` | 원본 revision |
| `originalRange: TimedRange` | 원본 시간 |
| `range: TimedRange` | 편집 중인 시간(절대) |
| `startDate`, `endDate: Date` | `range`의 `Date` 표현 |
| `timeZone`, `extent: Extent` | 지금은 항상 `.singleDay(LocalDate)` |
| `days: [LocalDate]` | `range`가 닿는 로컬 날짜들(지금은 1개) |
| `segment(on: LocalDate) -> DaySegment?` | 한 열에의 투영. `EventBlock`과 같은 규칙(시작 분 내림, 끝 분 올림)이고 `continuesFromPreviousDay/ToNextDay` 포함 |
| `isChanged: Bool` | `range != originalRange` |
| `comparison: Comparison` | 변경 전후. `before`, `after`, `startDeltaMilliseconds`, `endDeltaMilliseconds`, `durationDeltaMilliseconds`, `startChanged`, `endChanged`, `isChanged` |
| `validationIssue: EditDraftError?`, `isValid` | 현재 범위가 편집 결과로 허용되는지. 15분보다 짧은 원본은 손대지 않아도 `.shorterThanMinimum`을 보고한다(저장할 것이 없으니 `update`는 어차피 `nil`) |
| `issue(start: Int64, end: Int64) -> EditDraftError?` | 임의 범위의 사전 검사(제스처 미리보기용). 순서: `.startNotBeforeEnd` → `.leavesDay(day)` → `.shorterThanMinimum` |
| `EditDraft.stepMinutes`, `EditDraft.minimumDurationMinutes` | 둘 다 15(`TimelineEditPolicy.standard`와 같은 값) |

### 바꾸기 (모두 `mutating`, 실패 시 throw하고 Draft 불변)

| API | 의미 |
|---|---|
| `stepStart(by steps: Int)` | 시작을 15분 × `steps` 이동, 끝은 고정. 음수는 앞당김 |
| `stepEnd(by steps: Int)` | 끝을 15분 × `steps` 이동, 시작은 고정 |
| `setRange(_ range: TimedRange)` | 정확한 범위로 설정(스냅 없음). 드래그는 `TimelineEditPolicy.snap`으로 먼저 스냅한다 |
| `revert()` | `range`를 원본으로. 충돌 상태는 유지 |

**격자 규칙:** 격자는 로컬 자정 기준 15분이다. 격자 위의 끝점은 정확히 15분씩 움직인다. 격자 밖의 끝점(예: 10:07)은 첫 걸음이 그 방향의 가장 가까운 격자선으로 간다(+1 → 10:15, −1 → 10:00, −2 → 09:45). 일광절약 전환일에도 벽시계 15분 격자를 따른다.

### 충돌

| API | 의미 |
|---|---|
| `conflict(with: Observation) -> Conflict` | 순수 판정. Draft를 바꾸지 않음 |
| `observe(_ observation: Observation, readGeneration: Int)` | 판정 결과를 `conflict`에 기록. `readGeneration`이 마지막 reload보다 오래된 읽기면 **무시**(늦게 도착한 옛 읽기). 더 새 세대면 그 reload도 함께 반영 |
| `noteReload(generation: Int)` | 캘린더가 바뀌었을 수 있음. 깨끗하던 Draft는 다시 볼 때까지 `.unverified`. 이미 알려진 `.changed`/`.deleted`는 유지. 같거나 옛 세대는 무시 |
| `conflict: Conflict`, `generation: Int` | 마지막 판정과 마지막으로 본 세대 |

`Observation`(지금 캘린더가 말하는 것):

| case | 만드는 법 |
|---|---|
| `.present(Snapshot)` | `Observation(providerEvent: event)`(non-nil), `Observation.lookup(key, in: timelines)`에서 찾음 |
| `.deleted` | `Observation(providerEvent: nil)`(즉 `CalendarProvider.event(_:)`가 nil), 저장 결과 `.rejected(.eventNotFound)`, 유령 블록 |
| `.unavailable` | 읽은 날짜들에 없음(다른 날로 옮겨졌을 수 있음), 아직 다시 읽지 않음, 접근 불가 |

`Conflict`:

| case | 의미 | `blocksSave` |
|---|---|---|
| `.none` | 지금 보이는 이벤트가 원본과 같다 | false |
| `.unverified` | reload 이후 아직 확인 못 함, 또는 읽을 수 없음 | true |
| `.changed(current:, fields:)` | 바뀜. `fields ⊆ {time, title, editability, revision}` | true |
| `.deleted` | 키가 더 이상 풀리지 않음 | true |

- 양쪽 다 revision token이 있으면 token이 다를 때 `.revision`이 들어간다. `.revision`만 있으면 도메인이 모델링하지 않는 필드(알림·참석자 등)가 바뀐 것이다.
- token이 한쪽이라도 없으면 필드(시간·제목·편집 가능)만으로 판정한다.
- 다른 캘린더로 옮겨진 이벤트는 키가 바뀌므로 `.deleted`로 보인다. 다른 키의 스냅샷을 넘기면 `.unverified`.
- 타임라인 조회는 못 찾아도 `.deleted`가 아니라 `.unavailable`이다. 삭제 확정은 provider 조회로만 한다.

### 저장 연결 (데이터만)

| API | 의미 |
|---|---|
| `target: EventTarget` | 원본 키 + **원본** revision을 기대값으로 |
| `update: CalendarEventUpdate?` | 시간만 담은 패치(`time: .timed(range)`). 바뀌지 않았거나 유효하지 않으면 `nil`. 제목·장소·메모·시간대는 `.keep` |
| `editEventInput(scope: RecurrenceScope? = nil) -> EditEventInput?` | `CalendarCommand.editEvent`에 넣을 입력. 충돌은 검사하지 않음(`conflict.blocksSave`를 따로 본다) |

## 3. 세션별 사용 예

```swift
// 편집 시작 (interaction): 길게 누른 블록에서
var draft = try EditDraft(block: block, timeZone: zone, generation: appModel.dataGeneration)

// 정밀 조정 (precision-ui): ±15분 버튼
do { try draft.stepEnd(by: +1) } catch { /* error: EditDraftError → 흔들기/안내, draft는 그대로 */ }
let label = draft.comparison                     // "+15분" 등 표시
let column = draft.segment(on: draft.days[0])    // 카드 위치

// 외부 변경 (interaction / save): reload와 다시 읽기
draft.noteReload(generation: appModel.dataGeneration)
draft.observe(.lookup(draft.key, in: visibleTimelines), readGeneration: appModel.dataGeneration)

// 저장 (save-pipeline)
if !draft.conflict.blocksSave, let input = draft.editEventInput(scope: .thisOccurrence) {
    let outcome = await service.perform(.editEvent(input))
    // .conflict(current: event?) → draft.observe(event.map { .present(EditDraft.Snapshot($0)) } ?? .unavailable, readGeneration: …)
    //   (current == nil는 "최신 상태 모름"이지 삭제가 아니다)
    // .rejected(.eventNotFound) → draft.observe(.deleted, readGeneration: …)
}

// 취소: draft를 버린다. 아무것도 쓰지 않는다.
```

## 4. 다일 일정으로의 확장

막지 않도록 둔 것:

- 범위·원본·비교·저장 패치는 절대 시각이라 날짜 수와 무관하다.
- `days`와 `segment(on:)`은 이미 여러 날을 처리한다(`continuesFromPreviousDay/ToNextDay`).
- 하루 제한은 `Extent.singleDay` 한 곳과 `issue`의 해당 분기, 생성 시 `.spansDays` 검사에만 있다.

확장할 때 할 일:

- `Extent`에 여러 날 case를 추가한다.
- `issue`에 그 분기를 넣는다.
- 생성 검사를 완화한다.

`Extent`는 공개 enum이라 case 추가는 `switch`하는 호출자에게 소스 호환성이 깨지는 변경이다. 지금 호출자는 `extent`를 `switch`하지 말고 `days`/`segment(on:)`를 쓰는 편이 안전하다.

## 5. 범위 밖

- 핸들 드래그의 좌표 ↔ 시각 변환, 자동 스크롤, 생성 Draft(새 일정)
- 충돌 해결 UI와 rebase(바뀐 원본 위에 다시 적용)
- 반복 일정 범위 선택(`scope`는 호출자가 넘김)
- EventKit 쓰기

## 6. 검증

- `swift test`: 패키지 437 + 90 통과(이전 415 + 90, 신규 22).
- `tools/dev/check.sh build`(별도 derived data): 앱 빌드 성공. 앱 코드는 바뀌지 않았다.

신규 테스트가 다루는 것:

- 절대 범위·ID·캘린더·revision 보존(초 단위가 섞인 격자 밖 시작 포함)
- 블록에서 만들 때 잘린 분이 아닌 실제 범위 사용
- 생성 거부 4종(유령 블록 포함), 자정에 끝나는 일정 허용
- 15분 증감
- 격자 밖 첫 걸음 규칙
- 거부된 변경 뒤 Draft 불변(시작 ≥ 끝, 최소 길이, 날짜 이탈)
- 검증 순서
- 일광절약 전환일(뉴욕 봄·가을)
- `revert` 후 원본·키·revision 불변
- 변경 전후 비교 값
- 저장 입력: 원본 키·revision, 시간만 담긴 패치
- 충돌 판정: 같음, 필드별 변경, token만 변경, token 없음, 삭제, 확인 불가, 다른 키
- 타임라인 조회는 유령 블록일 때만 `.deleted`, 못 찾으면 `.unavailable`
- reload: `unverified` 전환, 늦게 도착한 옛 읽기 무시, 재확인 후 정상, 변경·삭제 유지
- 열 투영이 `EventBlock`의 분과 일치
