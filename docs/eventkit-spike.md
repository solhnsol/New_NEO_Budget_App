# EventKit spike 결과 (2026-10-08)

`docs/calendar-integration-design.md` §C.4의 검증 목록을 실제 EventKit에서 실행한 기록이다. 설계 문서의 🟡/🔴 가정을 이 결과로 대체한다.

## 실행 환경과 한계

- Xcode 27.0, iOS 27.0 시뮬레이터(iPhone 18 Pro), 시뮬레이터 로컬 캘린더(source `Default`).
- 코드: `Platform/iOS/EventKitSpike/Sources/SpikeApp/Spike.swift`, 실행: `Platform/iOS/EventKitSpike/run-spike.sh`.
- `xctest` 실행기에서는 캘린더 권한을 줄 수 없다(`calaccessd` XPC 오류, 상태 denied). 사용 설명 키(`NSCalendarsFullAccessUsageDescription`)가 있는 앱 번들이 필요하므로 최소 앱을 만들어 `simctl privacy grant`로 권한을 준다. 이는 이후 EventKit 통합 테스트의 실행 방식이기도 하다.
- **확인하지 못한 것**: iCloud/CalDAV 같은 동기화 계정에서의 동작(1번, 13번), 권한 철회 중 동작(9번), 같은 초 안의 연속 수정 충돌 감지, 캘린더 간 이동 시 식별자. 실기기에서 확인해야 한다.

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
| 10 | `lastModifiedDate`는 쓰기마다 갱신되지만 **초 단위**다. | 같은 초 안의 연속 수정은 구분할 수 없다. `revisionToken`은 lastModified만이 아니라 필드 fingerprint와 병행한다. |
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
