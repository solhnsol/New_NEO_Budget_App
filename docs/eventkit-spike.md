# EventKit spike 결과 (2026-10-08)

`docs/calendar-integration-design.md` §C.4의 검증 목록을 실제 EventKit에서 실행한 기록이다. 설계 문서의 🟡/🔴 가정을 이 결과로 대체한다.

## 실행 환경과 한계

- Xcode 27.0, iOS 27.0 시뮬레이터(iPhone 18 Pro), 시뮬레이터 로컬 캘린더(source `Default`).
- 코드: `Platform/iOS/EventKitSpike/Sources/SpikeApp/Spike.swift`, 실행: `Platform/iOS/EventKitSpike/run-spike.sh`.
- `xctest` 실행기에서는 캘린더 권한을 줄 수 없다(`calaccessd` XPC 오류, 상태 denied). 사용 설명 키(`NSCalendarsFullAccessUsageDescription`)가 있는 앱 번들이 필요하므로 최소 앱을 만들어 `simctl privacy grant`로 권한을 준다. 이는 이후 EventKit 통합 테스트의 실행 방식이기도 하다.
- **확인하지 못한 것**: iCloud/CalDAV 같은 동기화 계정에서의 동작(1번, 13번), 동기화 계정에서 `lastModifiedDate` 해상도, 권한 철회 중 동작(9번), 캘린더 간 이동 시 식별자, detached 회차가 섞인 시리즈의 전체 수정. 실기기에서 확인해야 한다.

## 결과 (번호는 §C.4)

| # | 결과 | 설계에 주는 의미 |
|---|---|---|
| 2 | 반복 이벤트의 모든 회차가 **같은 `eventIdentifier`와 `calendarItemIdentifier`를 공유**한다. 회차는 `startDate`/`occurrenceDate`로만 구분된다. | 회차 키 = (eventIdentifier, 원래 시작 시각) 설계가 맞다. |
| 3 | 한 회차를 `.thisEvent`로 옮기면 **detached** 이벤트가 되고 `eventIdentifier`가 `<마스터>/RID=<원래 시작 초>`로 바뀐다(RID는 2001-01-01 기준 초, 확인값 815878800 = 원래 시작 11-09 10:00 KST). `occurrenceDate`는 **이동 후 시각**이고 원래 시작이 아니다. 나머지 회차는 마스터 ID 그대로다. | 원래 시작은 `occurrenceDate`가 아니라 **`eventIdentifier`의 RID 접미사**에서 복원해야 한다. 접미사가 없으면 비반복/비분리다. |
| 4 | 중간 회차에서 `.futureEvents`로 저장하면 시리즈가 분할된다. **앞 회차는 기존 ID를 유지하고, 편집 회차 이후는 새 `eventIdentifier`를 받는다.** 기존 ID는 계속 조회된다. | `thisAndFuture`는 편집한 회차 이후 Activity의 `CalendarEventRef` **재바인딩이 필수**다(MVP에서는 제외 유지). |
| 5 | EKSpan에는 "전체"가 없다. 아무 회차의 `eventIdentifier`로 `event(withIdentifier:)`를 부르면 **마스터(첫 회차)가 돌아오고**, 그것에 `.futureEvents`로 저장하면 전체 시리즈가 바뀌며 **ID는 변하지 않는다.** | `allInSeries` = 마스터 조회 + `.futureEvents`. 시리즈에 detached 회차가 섞인 경우의 동작은 미확인. |
| 6 | 종일 이벤트의 `endDate`는 입력과 무관하게 **마지막 날 23:59:59**로 정규화된다(끝을 13일 00:00 또는 14일 00:00으로 넣으면 각각 13일 23:59:59 또는 14일 23:59:59). 이 날짜들은 입력 날짜의 포함 마지막 날이다. `timeZone`은 nil(floating). | `DayRange.lastDay` = `endDate`가 속한 **날짜**(포함). 저장 시에는 마지막 날 23:59:59를 쓴다. 다음 날 00:00을 종료로 쓰면 하루가 늘어난다. |
| 7 | `timeZone = nil` 저장 후에도 nil 유지, 시각은 벽시계 값 그대로. | 도메인의 floating 해석이 맞다. |
| 8 | 캘린더 삭제 시 `EKEventStoreChanged` 1회, 이후 `event(withIdentifier:)`와 `calendar(withIdentifier:)`는 nil. | 변경 신호 뒤 캘린더 목록 diff와 `eventMissing` 처리가 맞다. |
| 10 | `lastModifiedDate`는 쓰기마다 갱신되고 시뮬레이터 로컬 저장소에서는 **마이크로초 해상도**다(연속 저장 4회가 3~4ms 간격으로 구분됨). 처음 기록한 "초 단위"는 시각을 초 단위로 출력한 탓에 생긴 오해였다. | 동기화 계정의 서버가 시각을 어떻게 저장하는지는 미확인이므로 adapter의 `revisionToken`은 시각만이 아니라 모델링한 필드 fingerprint를 함께 쓴다. |
| 11 | `allowsContentModifications`가 기본 Birthdays(immutable)와 구독 캘린더(`isSubscribed`)에서 false. | `CalendarDescriptor.isWritable`로 사전 판단하면 된다. |
| 12 | 자기 저장(`commit: true`)도 `EKEventStoreChanged`를 **1회** 낸다. | echo 억제 또는 멱등 diff가 필요하다. |
| 14 | `EKEvent`/`EKEventStore`를 `@MainActor`에서 쓰면 Swift 6 언어 모드에서 경고 없이 컴파일된다. Sendable이 아니므로 actor 밖으로 내보내지 않는다. | 설계대로 actor 하나가 store를 소유하고 값 타입 snapshot만 반환한다. |

## 식별자 형태

- `eventIdentifier` = `<store/source UUID>:<이벤트 UUID>`(분리 회차는 뒤에 `/RID=<초>`). 첫 부분은 같은 source에서 동일했다.
- `calendarItemExternalIdentifier`는 `<이벤트 UUID>`와 같고 분리 회차에는 같은 `/RID=` 접미사가 붙는다. 서버 측 식별자로서의 재매칭 보조 가치는 동기화 계정에서 따로 확인해야 한다.
- `calendarItemIdentifier`는 분리 회차에서만 마스터와 다르다.

## 설계 문서에 반영할 사항

1. B.4: 회차 키의 원래 시작은 `RID` 접미사에서 복원. `occurrenceDate`에 의존하지 않는다.
2. B.4/C: `allInSeries`는 마스터 lookup 후 `.futureEvents`. `thisAndFuture`는 재바인딩 필요가 확인됐으므로 MVP 밖 유지.
3. B.1/C: 종일 `endDate` 정규화 규칙(포함 마지막 날, 23:59:59 저장).
4. F.1: echo가 실제로 발생하므로 멱등 diff 필수.
5. 테스트: EventKit 통합 테스트는 앱 번들 + `simctl privacy grant` 방식으로 실행한다.

## 계약과 adapter에 반영한 결과 (같은 날)

`CalendarProvider` 계약(문서 주석과 `changes()`), `InMemoryCalendarProvider`, `NEOBudgetEventKit`의 `EventKitCalendarProvider`, 공용 계약 테스트 `NEOBudgetCalendarContract`를 이 관찰에 맞춰 바꿨다.

| 주제 | 계약/구현 |
|---|---|
| occurrence identity | 키는 회차마다 유일해야 하고 `.thisOccurrence` 편집(이동 포함) 뒤에도 유지된다. EventKit 키는 비반복 = `eventIdentifier`, 반복 회차 = `<마스터 eventIdentifier>\|<원래 시작 날짜>`. 날짜는 분리 회차의 RID 접미사에서 복원한다. 시작 **시각**을 넣지 않은 이유는 `allInSeries`가 모든 회차의 시작 시각을 바꾸기 때문이다. 원래 날짜에서 1년 넘게 옮긴 회차는 조회되지 않는다. |
| recurring scope | `.thisOccurrence`, `.allInSeries`만 선언. `allInSeries`의 `time`은 지정한 회차의 새 구간이며 시리즈에는 같은 시각 이동과 길이를 적용한다. 다른 날로 옮기는 변경, 종일↔시간 전환, 시간대 변경, 분리된 회차는 `.unsupported`. `.thisAndFuture`는 키를 유지할 수 없어 선언하지 않는다(재바인딩 결과가 도메인에 생기기 전까지). |
| all-day | 종일은 provider의 day zone 기준 온전한 날들이다. EventKit은 마지막 날 23:59:59로 저장·반환하며 `DayRange.lastDay`는 `endDate`가 속한 날이다. in-memory의 "하루씩 넓혀서 겹침 판정" 임시 처리는 day zone 기반으로 교체했다. |
| change notification | `changes()` 추가. 데이터 없는 신호, 합쳐질 수 있고(`bufferingNewest(1)`), 자기 쓰기도 신호를 낼 수 있으며(EventKit은 실제로 1회 낸다), 순서 보장 없음. 소비자는 다시 읽고 diff한다. EventKit 구현은 어떤 store의 변경이든 받는다. |
| read-only | 쓰기 검사 순서를 계약에 고정: 접근 → 일회성 실패 큐 → 캘린더 존재(`calendarMissing`) → 쓰기 가능(`calendarNotWritable`) → 이벤트 존재(`eventMissing`) → 편집 가능·scope(`unsupported`) → revision. 읽기 전용 캘린더의 이벤트는 `isEditable == false`. |
| stale/conflict | 토큰은 모델링한 필드가 바뀌면 바뀌어야 하고(시각만 믿지 않음), 불일치 시 `.conflict`로 쓰지 않는다. 읽기-확인-쓰기는 플랫폼과 원자적일 수 없어 best effort다. |

### 계약 테스트
- `Sources/NEOBudgetCalendarContract`는 테스트 프레임워크 없이 18개 검사를 실행한다.
- in-memory: `swift test`의 `ProviderContractTests`(전체 실행, 건너뜀 0).
- EventKit: `Platform/iOS/EventKitContractHost/run-contract.sh`(시뮬레이터 앱 호스트). 17개 통과, 1개 건너뜀(권한 철회는 테스트에서 재현할 수 없음).
- 검증 방법: revision token을 초 단위 시각만으로 약화시키는 결함을 일부러 넣으면 계약이 2건 실패하는 것을 확인했다. 그 확인 중 다른 store가 방금 만든 캘린더를 adapter가 `calendarMissing`으로 오판하는 실제 결함이 드러나, 조회 실패 시 store를 새로 고치고 재시도하도록 고쳤다.
