# 캘린더 통합 설계: EventKit contract + Calendar domain/read model — 설계 초안

> **상태 주의 (2026-10-07):** 이 문서는 구현 전 **초기 설계 초안**이다. Windows에서 구현·검증된 결정은 [calendar-domain.md](calendar-domain.md)와 `decisions.md` D009가 기준이며, 아래 차이가 있다.
> - `CalendarEventRef`·`EventSnapshot`·`ActivityMetadata` 대신 `CalendarEventKey`(불투명 `CalendarEventID` 포함)와 `CalendarEventAssociation`(last-known 요약 + 상태)을 사용한다. 이벤트 식별자 안정성·fingerprint 재바인딩은 구현하지 않았다(Mac spike 필요).
> - 새 개념 **Tag / Area / Category 훅 / provenance 기반 자동 배정 보호**가 추가되었다(이 초안에 없음). ActivityType은 단일 값이며 Calendar와 별개 축이다.
> - 구현하지 않은 것: `PendingOperation` 의도 로그, command ID 멱등성, undo, `RecurrenceScope`의 EventKit 매핑, EventKit adapter 전체. 구현된 쓰기 순서는 "캘린더 먼저, 로컬 나중, 실패는 typed 결과(`partiallyApplied` 포함)"이다.
> - `visibleCalendarIDs`는 인자만 있고 캘린더 표시 선택 UI는 없다.


상태: **설계 문서. 코드 구현 없음.** 확정된 정책이 아니라 제안이며, 사용자 결정이 필요한 항목은 §H에 모았다.
기준: 기존 Swift Package(`NEOBudgetCore` + `NEOBudgetInMemoryStorage`), `docs/core-plan.md`의 "Calendar/EventLink — EventKit 객체 포함하지 않음", `docs/platform-boundary-review.md`(Core에 Apple framework 금지), 레거시 `app/timeline.py`(소비–일정 시간 관계, 겹친 일정 배정).

## 0. 읽는 법

### 0.1 Apple API 확실성 표기

EventKit 세부 동작은 이 문서 작성 환경(Windows, EventKit 없음)에서 **실행해 확인하지 못했다.** 확인 정도를 구분해 표시한다.

| 표기 | 의미 |
|---|---|
| 🟢 | 널리 알려진 공개 API 사실로 판단(구현 전 문서 재확인 정도) |
| 🟡 | 기억에 의존하며 세부(경계 조건)가 불확실 — **기기 spike로 확인 후 사용** |
| 🔴 | 동작을 모름/추측 영역 — 설계는 이 동작에 **의존하지 않도록** 만들었고 spike가 필요 |

Apple 동작을 가정한 곳은 본문에서 해당 표기를 붙이고, §C.4에 "구현 전 검증 목록"으로 다시 모았다.

### 0.2 기존 Core 규약을 그대로 따른다

- ID는 `RawRepresentable` 문자열 래퍼, 시각은 `Int64` unix milliseconds, 금액은 `Money`(정수 minor unit).
- 시스템 시각/타임존/난수는 주입한다(결정론). 값 타입은 `Codable`, `Equatable`, `Sendable`.
- 저장은 protocol + revision CAS(`expectedRevision`) + in-memory 참조 구현. **영구 실패는 예외가 아니라 typed 결과**로 돌려준다(원장 red-team R7에서 얻은 교훈: poison 항목 방지). 일시 오류(stale revision)만 throw.
- Core는 Windows/Linux에서도 빌드·테스트된다. EventKit은 iOS/macOS 전용이므로 **Core와 새 캘린더 모듈은 EventKit을 import하지 않는다.**

---

## A. Recommended architecture

### A.1 한 줄 요약

> EventKit은 **캘린더 이벤트 필드의 원본(source of truth)**, OnAll은 **이벤트 위에 얹는 메타데이터와 거래 연결의 원본**. 둘 사이는 `CalendarProvider` 포트(값 타입만 오감)로만 통신하고, UI는 `CalendarService` 파사드의 **command와 read model**만 안다.

### A.2 계층과 모듈

```text
┌──────────────────────────── iOS app target (Platform/iOS, SwiftUI) ───────────────────────────┐
│ DayTimelineView / 제스처 / 드래그 미리보기(임시 UI 상태)                                         │
│   ↓ perform(command)          ↑ DayTimeline(read model), CommandOutcome                        │
├────────────────────────────── NEOBudgetCalendar (pure Swift, 새 target) ───────────────────────┤
│ CalendarService(actor) ── CalendarCommandHandler ── SyncReconciler ── DayTimelineBuilder(순수) │
│ Domain: EventSnapshot, CalendarEventRef, Activity, TransactionActivityLink, EventTime, ...     │
│ Ports:  CalendarProvider (EventKit 대리)   CalendarMetadataRepository (OnAll 저장)             │
│         TransactionTimelineSource (원장 읽기 전용 대리)                                          │
├──────────────┬──────────────────────────────┬───────────────────────────────────────────────────┤
│ NEOBudgetCore│ (기존) LedgerEntry, Money,    │ NEOBudgetInMemoryStorage / 새 in-memory 캘린더      │
│ (원장, 불변) │ LedgerEntryID …               │ (InMemoryCalendarProvider, fault injection)        │
└──────────────┴──────────────────────────────┴───────────────────────────────────────────────────┘
iOS 전용: NEOBudgetEventKit (EKEventStore를 소유하는 CalendarProvider 구현) — Package 밖(Platform/iOS), 단방향 의존 iOS → Calendar → Core
```

- **`NEOBudgetCalendar`(새 target)**: 캘린더 도메인·명령·read model·포트. 의존은 `NEOBudgetCore`의 ID/`Money`/시각 타입뿐이며 EventKit·SwiftUI·DB 구현을 알지 못한다. 원장(`LedgerRepository`)에 **쓰지 않는다.**
- **링크는 원장 안이 아니라 별도 저장소**: 원장은 append-only로 불변인데 거래–활동 연결은 사용자가 자주 바꾼다. 원장 전표(`LedgerEntry`)를 수정하지 않고 `TransactionActivityLink`가 `LedgerEntryID`를 참조한다.
- **`NEOBudgetEventKit`(iOS 전용 adapter)**: `EKEventStore`를 단일 actor가 소유하고 `EKEvent`/`EKCalendar`는 이 모듈 밖으로 나가지 않는다.
- **의존 방향**: iOS app → NEOBudgetCalendar → NEOBudgetCore, iOS app → NEOBudgetEventKit → NEOBudgetCalendar(포트 구현). Core → 캘린더, 캘린더 → EventKit 의존은 금지.

### A.3 책임 경계

| | 책임 | 하지 않는 일 |
|---|---|---|
| **EventKit adapter** (`NEOBudgetEventKit`) | 권한 요청/상태 변환, 캘린더·이벤트 조회(기간 predicate)와 `EventSnapshot`으로의 변환, 이벤트 생성/수정/삭제 저장(span 포함), `EKEventStoreChanged` 구독과 "변경됨" 신호 전달, EK 오류를 typed 오류로 변환, EK 객체의 스레드/actor 격리, **모델링하지 않은 EK 필드(참석자·알림·URL 등)를 보존**하는 patch 방식의 저장 | 활동/거래/연결 정책, 시간 snapping·최소 길이 같은 UX 정책, OnAll 메타데이터 저장 |
| **Core/Domain** (`NEOBudgetCalendar`) | 도메인 타입, command 검증과 의미(snapping, 최소 길이, 반복 scope), 동기화 reconcile(스냅샷 diff), 일관성 전략, `DayTimeline` read model 계산, 링크 규칙, 포트 정의 | EventKit 호출, 화면 좌표/픽셀, 제스처 인식 |
| **UI layer** (SwiftUI) | 제스처 인식과 **좌표 ↔ 분 단위 변환**, 드래그 중 임시 미리보기 상태, command 생성/제출, `CommandOutcome`에 따른 토스트/다이얼로그(반복 scope 선택 등), read model 렌더링 | `EKEvent`/원장 원본 객체 접근, 시간 정책 계산, 직접 저장 |

### A.4 `EKEvent`/`EKCalendar`를 어디까지 노출하는가

**어디에도 노출하지 않는다. 오직 adapter 내부.** 근거:
- 🟡 EventKit 객체는 `Sendable`이 아니고 `EKEventStore`에 묶여 있어(Swift 6 strict concurrency, 이 패키지는 swift-tools-version 6.0) actor 경계를 넘기면 안전하지 않다.
- 같은 이벤트도 store 갱신 후 객체 상태가 바뀐다 → 도메인은 **시점 고정된 값(`EventSnapshot`)** 으로만 다뤄야 diff·테스트·Windows 빌드가 가능하다.
- 테스트를 위해 `InMemoryCalendarProvider`로 대체 가능해야 한다.

adapter가 도메인으로 내보내는 것은 `EventSnapshot`, `CalendarInfo`, `CalendarAccessState`, typed 오류뿐이다.

### A.5 데이터 소유권 요약

| 데이터 | 원본 | OnAll 저장 |
|---|---|---|
| 제목·시간·장소·메모·반복·캘린더 소속 | **EventKit** | 마지막으로 본 값의 `EventSnapshot` **캐시**(오프라인/빠른 읽기/diff용). 쓰기 원본이 아님 |
| 활동 유형, 거래 연결, 사용자 메타데이터 | **OnAll** | `Activity`, `TransactionActivityLink` |
| 이벤트 identity(어느 이벤트/회차인가) | EventKit identifier + OnAll fingerprint | `CalendarEventRef` |
| 거래 금액·시각 | 원장(불변) | 저장 안 함, 읽기 전용 join |

### A.6 `CalendarService` 파사드

UI가 쓰는 유일한 진입점(actor, 내부에서 위 구성요소 조합):

```text
actor CalendarService {
  func accessState() async -> CalendarAccessState
  func requestAccess() async -> CalendarAccessState
  func dayTimeline(for day: LocalDate, displayTimeZone: String) async -> DayTimeline   // read model
  func timelineChanges() -> AsyncStream<TimelineInvalidation>                            // 갱신 신호만(데이터 없음)
  func perform(_ command: CalendarCommand) async -> CommandOutcome                       // typed 결과, 영구 실패는 throw 아님
  func resolve(_ pending: PendingDecisionID, choice: DecisionChoice) async -> CommandOutcome
}
```

드래그 미리보기용 순수 함수(`TimeSnapping`, `ResizeClamp` 등)는 `CalendarService`가 아니라 **무상태 순수 함수**로 UI에 공개한다 → 드래그 중에는 저장/EventKit 호출이 없고, 손을 뗀 순간에만 command가 제출된다.

---

## B. Domain types

### B.1 Activity와 Calendar Event를 분리할 것인가

**결론: 내부적으로 분리하되, 최소로.** 사용자 눈에는 "일정 = 활동" 하나이고, 내부에서는 소유자가 다른 두 레코드다.

| 후보 | 판단 |
|---|---|
| 거래를 `CalendarEventRef`에 **직접** 연결(Activity 없음) | 가장 단순하지만 아래 문제로 **채택 안 함** |
| `CalendarEventRef` + **`Activity`** + `TransactionActivityLink` | **채택(최소형)** |
| `ActivityMetadata`를 별도 타입으로 분리 | **MVP에서는 `Activity` 안에 인라인.** 필드가 늘어 분리 이득이 생길 때 분리 |

Activity가 필요한 이유(MVP에서도 필요):
1. **EventKit identifier를 믿을 수 없다.** 🟡 `eventIdentifier`는 동기화/계정 상황에서 바뀔 수 있다는 보고가 있고(정확한 조건 불확실), 반복 이벤트의 회차 식별 방식도 🟡이다. 거래 연결이 identifier 하나에 매달리면 identifier가 바뀔 때 연결이 고아가 된다. `Activity.id`는 OnAll이 소유한 **안정 ID**이고 `CalendarEventRef`는 **재바인딩 가능한 포인터**다.
2. **이벤트가 외부에서 삭제돼도 연결을 잃지 않는다**(§F). `Activity`가 `eventMissing` 상태로 남아 연결이 보존된다.
3. **미래 확장 지점**: 이벤트 없는 활동(관찰된 실제 활동, AI 추론, 위치 기반)을 `eventRef == nil`인 `Activity`로 표현할 수 있어 EventKit과 무관한 모델이 열려 있다.
4. **활동 유형(ActivityType)을 둘 곳**이 필요하다. EventKit 필드에 숨겨 저장하는 것은 사용자가 지우거나 다른 기기에서 편집할 수 있어 불안정하다(메모/URL 필드 오용 금지).

MVP를 과설계하지 않는 장치:
- **Activity는 지연 생성(lazy materialization)**. 가져온 모든 이벤트마다 행을 만들지 않는다. 사용자가 거래를 연결하거나 유형을 지정하는 **첫 순간**에 만든다. 이벤트만 있는 블록은 `EventSnapshot`만으로 그려진다(read model에서 `activityID == nil`).
- MVP의 `Activity`는 사실상 **"이벤트(회차) 1개 : Activity 0~1개"**. 미래 관찰 활동은 `eventRef == nil`로 열어 두기만 하고 구현하지 않는다.
- `ActivityMetadata`, 실제 시간(actual time), 추론 출처(inference provenance)는 **타입을 만들지 않는다.** 확장 지점만 명세한다(§G).

### B.2 타입 초안

(Swift 시그니처 형태의 **계약 스케치**이며 최종 이름·접근 수준은 구현 단계에서 확정.)

```text
// ── 식별자 ──────────────────────────────────────────────
struct ActivityID: RawRepresentable, Codable, Hashable, Sendable      // OnAll 안정 ID
struct CalendarSourceID                                                // 캘린더 식별(§B.3 불확실성 참조)
struct LocalDate: Codable, Hashable, Sendable { year, month, day }     // 시간대 없는 달력 날짜

// ── 시간 ───────────────────────────────────────────────
enum EventTime: Codable, Equatable, Sendable {
  case timed(startUnixMs: Int64, endUnixMs: Int64, timeZoneID: String?)   // nil = floating(기기 시간대로 해석) 🟢
  case allDay(firstDay: LocalDate, lastDay: LocalDate)                    // 포함 범위. EK의 종료일 관례는 adapter가 정규화 🟡
}

// ── 외부 이벤트 포인터 ──────────────────────────────────
struct CalendarEventRef: Codable, Equatable, Sendable {
  var calendarID: CalendarSourceID
  var eventIdentifier: String                  // EK 식별자(불안정할 수 있음) 🟡
  var externalIdentifier: String?              // 서버측 식별자가 있을 때 재매칭 보조 🟡
  var occurrenceStartUnixMs: Int64?            // 반복 회차의 "원래 시작"; 비반복은 nil (§B.4)
  var fingerprint: EventFingerprint            // 재매칭용 (제목 정규화 + 원래 시작 + 캘린더)
}

// ── EventKit 쪽 마지막 관측 값 ──────────────────────────
struct EventSnapshot: Codable, Equatable, Sendable {
  var ref: CalendarEventRef
  var title: String
  var time: EventTime
  var location: String?
  var notes: String?                           // 표시/편집용. OnAll 메타데이터를 여기에 숨기지 않는다
  var recurrence: RecurrenceSummary?           // 읽기 전용 요약(§B.4). 규칙 자체 편집은 MVP 밖
  var isDetachedOccurrence: Bool               // 반복 예외로 분리된 회차 🟡
  var isEditable: Bool                         // 캘린더가 쓰기 가능한가 + 이 이벤트 수정 가능한가 🟢(allowsContentModifications)
  var versionToken: String?                    // lastModifiedDate 등 변경 감지용. 없을 수 있음 🟡
  var observedAtUnixMs: Int64                  // 이 스냅샷을 만든 시각(주입 clock)
}

// ── OnAll 소유 활동 ────────────────────────────────────
struct Activity: Codable, Equatable, Sendable {
  var id: ActivityID
  var eventRef: CalendarEventRef?              // MVP: 사실상 항상 있음. 미래 관찰 활동은 nil
  var state: ActivityState                     // .linked / .eventMissing / .calendarUnavailable
  var activityType: ActivityTypeID?            // 사용자 정의 분류(§H 결정 필요)
  var createdAtUnixMs: Int64
  var revision: UInt64
}

struct TransactionActivityLink: Codable, Equatable, Sendable {
  var id: LinkID
  var transactionID: LedgerEntryID             // 기존 Core 타입 참조만. 원장 불변
  var activityID: ActivityID
  var source: LinkSource                       // MVP: .manual. 확장: .suggestedThenAccepted, .inferred
  var createdAtUnixMs: Int64
}
```

필드를 **뺀 것**과 이유:

| 제외 | 이유 |
|---|---|
| `recurrence` 편집 규칙 전체, `alarms`, `attendees`, `url`, `availability` | MVP에서 편집하지 않는다. **편집하지 않는 필드는 도메인에 가져오지 않고 adapter가 patch 저장으로 보존**(§C.3) |
| `linkedTransactionIDs`를 이벤트/Activity에 배열로 저장 | 링크는 **정규화된 별도 레코드**(`TransactionActivityLink`)가 원본. 배열은 read model에서 계산 |
| `ActivityMetadata` 별도 타입 | MVP는 `activityType` 하나뿐. 필드가 늘 때 분리 |
| `actualStart/actualEnd`, 위치, 추론 출처 | 후순위(§G). `Activity`에 optional 필드를 **미리 만들지 않는다**(저장 스키마 `schemaVersion`으로 추후 추가) |
| `syncState` 이벤트별 필드 | 별도 `PendingOperation`/`SyncStatus`로 관리(§F). 도메인 엔티티에 섞지 않음 |
| `calendarColor` | 표시용 → read model에서 `CalendarInfo`로 조인 |

### B.3 캘린더 식별과 identifier 보관

```text
struct CalendarInfo: Codable, Equatable, Sendable {
  var id: CalendarSourceID           // EK calendarIdentifier 🟡 안정성은 spike로 확인
  var title: String
  var colorHex: String?
  var isWritable: Bool               // allowsContentModifications 🟢
  var kind: CalendarKind             // local, iCloud/calDAV, exchange, subscription, birthday 🟢(EKCalendarType) — 도메인에선 단순화
  var sourceTitle: String?           // 계정 표시용
}
```

**identifier 보관 전략(불안정성 가정):**
1. **여러 식별자를 함께 저장**: `eventIdentifier`(+ 가능하면 `calendarItemExternalIdentifier`), `calendarID`, 반복이면 원래 시작 시각. 어느 하나에만 의존하지 않는다. 🟡 각 식별자의 안정성/반복 이벤트에서의 공유 여부는 **spike 확인 대상**.
2. **`EventFingerprint`**: 식별자 조회가 실패했을 때 재바인딩하는 보조 키. 구성: `(calendarID, 정규화한 제목, 원래 시작 시각(분 단위))`. 재바인딩은 "해당 기간·캘린더에서 fingerprint가 **정확히 하나**일 때만" 자동 수행, 둘 이상/없음이면 `eventMissing` 후보로 두고 사용자에게 알린다(추측 금지).
3. **Activity가 안정 ID를 소유**하므로 `CalendarEventRef`만 교체하면 연결은 유지된다.

### B.4 반복 이벤트 모델

- **회차 단위로 활동을 만든다**: 같은 "점심" 반복이라도 화요일 점심과 수요일 점심의 거래는 다르다. `Activity`는 **회차**(`CalendarEventRef.occurrenceStartUnixMs`)에 붙는다.
- **회차 키 = (시리즈 식별, 원래 시작 시각)**. 사용자가 회차를 다른 시간으로 옮겨 예외(detached)가 돼도 "원래 시작"은 변하지 않으므로 Activity가 따라간다. 🟡 EventKit이 회차 이동 후 원래 시작을 어떻게 노출하는지(`occurrenceDate` 계열)는 spike 확인.
- `RecurrenceSummary`는 **읽기 전용**: 사람이 읽을 수 있는 요약("매주 화·목", "종료일 …")과 `isRecurring` 정도. 반복 규칙을 편집하는 UI는 MVP에서 만들지 않는다(편집은 "이 회차 시간 변경/전체 시간 변경"까지).
- **편집 scope 표현**: `RecurrenceScope { thisOccurrence, thisAndFuture, allInSeries }` (도메인 3값). adapter가 EventKit span으로 매핑:
  - `thisOccurrence` → 🟢 `EKSpan.thisEvent`
  - `thisAndFuture` → 🟢 `EKSpan.futureEvents`
  - `allInSeries` → 🔴 EKSpan에는 "전체" 값이 없는 것으로 알고 있다(🟢 span 2종은 확실). 시리즈 마스터를 가져와 `futureEvents`로 저장하는 방식이 일반적이라고 기억하지만 **확신하지 않으며 spike 필요**.
  - 🔴 `thisAndFuture`는 시리즈를 분할하며 새 시리즈의 식별자/회차 연속성이 어떻게 되는지 **모른다.** 분할 후 기존 Activity들의 `CalendarEventRef` 재바인딩이 필요할 수 있다. 그래서 MVP 기본 제공은 `thisOccurrence`와 `allInSeries`로 시작하고 `thisAndFuture`는 spike 결과에 따라 결정한다(§H-6).

### B.5 `ActivityType`

- `ActivityTypeID`는 사용자가 편집 가능한 **작은 목록**의 키(이름, 색, 아이콘)로 시작. 이전 시스템에서 "카테고리 = 무엇에, 상황/성격 = #태그(#데이트 #모임 #정산 …)"로 나눴던 사용자의 사고를 이어, **ActivityType은 "상황/성격" 쪽**에 가깝다. 거래 카테고리(식비 등)는 원장/예산 쪽의 개념이며 여기서 다루지 않는다. 최종 형태(단일 선택 vs 복수 태그)는 §H-4.

---

## C. EventKit adapter contract

### C.1 포트 정의

```text
protocol CalendarProvider: Sendable {                      // 구현: EventKit adapter / InMemoryCalendarProvider
  func authorizationState() async -> CalendarAccessState
  func requestFullAccess() async -> CalendarAccessState

  func calendars() async throws -> [CalendarInfo]
  // 기간 조회. 반복은 회차로 펼쳐서 반환(🟢 predicateForEvents → 회차 단위 결과). 정렬은 보장하지 않음 → 호출 측에서 정렬
  func events(from: Int64, to: Int64, calendars: Set<CalendarSourceID>?) async throws -> [EventSnapshot]
  // 연결된 이벤트 개별 조회(보이는 기간 밖의 링크 보존 확인용)
  func event(for ref: CalendarEventRef) async throws -> EventLookup          // .found(EventSnapshot) / .notFound / .ambiguous([EventSnapshot])

  func create(_ draft: EventDraft, in calendar: CalendarSourceID) async -> ProviderResult<EventSnapshot>
  func update(_ ref: CalendarEventRef,
              patch: EventPatch,
              scope: RecurrenceScope,
              ifUnchangedSince expected: EventFingerprint/versionToken) async -> ProviderResult<EventSnapshot>
  func delete(_ ref: CalendarEventRef,
              scope: RecurrenceScope,
              ifUnchangedSince expected: ...) async -> ProviderResult<Void>

  /// 변경 신호. 🟡 EKEventStoreChanged는 "무엇이 바뀌었는지"를 주지 않는 것으로 알고 있음 → 데이터 없는 신호
  func storeChanges() -> AsyncStream<Void>
}

enum ProviderResult<T> {
  case success(T)
  case conflict(current: EventSnapshot?)       // 사전 확인에서 외부 변경 발견
  case failure(ProviderFailure)                // 영구/일시 구분된 typed 오류
}

enum ProviderFailure {
  case accessDenied(CalendarAccessState)
  case calendarNotWritable(CalendarSourceID)
  case calendarMissing(CalendarSourceID)
  case eventMissing
  case saveFailed(reason: String, retryable: Bool)   // EK 오류를 분류해 매핑 (구체 매핑은 spike 🟡)
  case unsupportedChange                              // 예: 읽기 전용 이벤트
}
```

`EventPatch`는 **변경할 필드만** 담는다(`title?`, `time?`, `location?`, `notes?`, `allDayChange?`…). 값이 없는 필드는 "건드리지 않음"이다.

### C.2 `CalendarAccessState`

```text
enum CalendarAccessState { notDetermined, fullAccess, writeOnly, denied, restricted }
```
🟢 iOS 17+의 `EKAuthorizationStatus`에 `fullAccess`/`writeOnly`가 있고, 전체 접근은 `requestFullAccessToEvents`로 요청하며 Info.plist에 전체 접근 사용 설명 키가 필요하다(🟡 정확한 키 이름은 구현 시 문서로 재확인). `writeOnly`에서는 이벤트를 **읽지 못하므로** OnAll은 `fullAccess`가 아니면 읽기 기능을 제공하지 않는다(§F.5). 지원 OS 최소 버전은 iOS 17(§H-10).

### C.3 adapter 구현 규칙

1. **단일 `EKEventStore`를 actor가 소유**. EK 객체를 actor 밖으로 반환하지 않는다.
2. **조회는 actor 밖의 메인 스레드를 막지 않게** 수행(🟡 predicate 조회는 동기 API이며 큰 기간에서 느릴 수 있다고 알고 있음 → 기간을 하루~몇 주 단위로 제한하고 백그라운드 실행).
3. **저장은 patch 방식**: 기존 이벤트를 다시 가져와 필요한 필드만 바꿔 저장해 **OnAll이 모르는 필드(참석자, 알림, URL, 가용성 등)를 잃지 않는다.** 새 `EKEvent`를 만들어 덮어쓰지 않는다.
4. **쓰기 전 사전 확인(optimistic check)**: 저장 직전에 이벤트를 다시 읽어 `expected`(fingerprint/versionToken)와 비교, 다르면 `conflict`를 돌려주고 저장하지 않는다(§F.2).
5. 배치 저장 시 `commit` 시점은 adapter 내부 결정(🟢 `save(_:span:commit:)`가 있다). 도메인은 알지 못한다.
6. **오류는 분류해서** `ProviderFailure`로 변환(retryable 여부 포함). 매핑 표는 spike에서 EK 오류 코드를 실제로 보고 확정(🟡).
7. `storeChanges()`는 `EKEventStoreChanged` 구독을 **디바운스**(예: 수백 ms)해 `Void` 신호만 내보낸다. 자기 저장도 신호를 일으킬 수 있으므로(🟡) 수신 측이 멱등 diff로 처리한다(§F.1).

### C.4 구현 전 검증 목록 (EventKit spike)

기기(또는 macOS+시뮬레이터)에서 확인해야 하며, **결과에 따라 B.3/B.4가 바뀔 수 있다.** Windows 개발 환경에서는 실행할 수 없다.

| # | 확인할 것 | 현재 가정 | 확신 | 틀리면 |
|---|---|---|---|---|
| 1 | `eventIdentifier`가 동기화·시간 수정·계정 변경에서 바뀌는 조건 | 바뀔 수 있다 | 🟡 | fingerprint 재매칭의 중요도 상향 |
| 2 | 반복 이벤트 회차들이 같은 `eventIdentifier`를 공유하는가, 회차는 시작 시각으로 구분하는가 | 공유 + 시작 시각으로 구분 | 🟡 | `CalendarEventRef.occurrenceStart` 설계 변경 |
| 3 | 회차를 이동(예외)한 뒤 "원래 시작"을 읽을 수 있는가(occurrenceDate 계열) | 가능 | 🟡 | Activity가 이동 후 회차에서 떨어질 수 있음 |
| 4 | `futureEvents` 저장 시 새 시리즈의 식별자와 기존 회차의 식별자 변화 | 모름 | 🔴 | thisAndFuture를 MVP에서 제외 |
| 5 | "전체 반복 수정"의 정확한 구현 방식(마스터 + futureEvents?) | 마스터 가져와 futureEvents | 🔴 | allInSeries 구현 방식 변경 |
| 6 | 종일 이벤트의 `endDate` 관례(마지막 날 시작/끝 시각) | 정규화 필요 | 🟡 | `EventTime.allDay` 변환 규칙 |
| 7 | 타임존 nil(floating) 이벤트의 해석과 저장 | nil = floating | 🟢 | |
| 8 | 캘린더 삭제 시 이벤트 조회 결과와 알림 시점 | `EKEventStoreChanged` 후 캘린더 목록 diff로 감지 | 🟡 | 삭제 감지 로직 |
| 9 | 권한 철회 시 앱 실행 중 동작(알림? 오류?) | 다음 접근에서 실패 | 🔴 | 권한 재확인 시점을 foreground마다 + 오류 시 |
| 10 | `lastModifiedDate`로 충돌 감지가 되는가(일부 이벤트는 nil?) | 항상 신뢰 불가 → fingerprint 병행 | 🟡 | |
| 11 | 읽기 전용/구독/공유 캘린더에서 수정 시도의 오류 형태 | `allowsContentModifications`로 사전 판단 | 🟢 | |
| 12 | 자기 저장 직후 `EKEventStoreChanged`가 오는가 | 온다 | 🟡 | echo 억제 필요성 |
| 13 | 이벤트 변경 감지 범위(어떤 계정 동기화 이후 시점) | 시점 보장 없음 | 🟡 | "다시 불러오기" UX |
| 14 | Swift 6 동시성에서 EK 객체의 Sendable 상태 | 비Sendable | 🟡 | actor 격리 설계 확정 |

---

## D. UI mutation commands

UI는 도메인을 직접 수정하지 않고 아래 command만 제출한다. 모든 시간 입력은 **분 단위가 이미 snapping된 값**(UI가 `TimeSnapping`을 호출)이지만 **검증은 항상 Core가 다시 수행**한다(UI를 신뢰하지 않음).

### D.1 공통 규칙

```text
enum CalendarCommand {
  case createEvent(CreateEventInput)
  case moveEvent(MoveEventInput)
  case resizeEventStart(ResizeInput)
  case resizeEventEnd(ResizeInput)
  case changeAllDay(ChangeAllDayInput)
  case deleteEvent(DeleteEventInput)
  case linkTransaction(LinkInput)
  case unlinkTransaction(UnlinkInput)
  case changeActivityType(ChangeTypeInput)
  // 편집 필드(제목/장소/메모): updateEventDetails(...)
}

enum CommandOutcome {
  case applied(TimelineInvalidation, undo: UndoToken?)
  case needsDecision(PendingDecision)             // 예: 반복 scope 선택, 삭제 시 연결 처리 확인
  case rejected(CommandRejection)                 // 검증 실패 — 상태 변경 없음 (영구)
  case conflict(current: EventSnapshot?)          // 외부에서 먼저 변경됨 — 상태 변경 없음, 최신 상태로 재시도 유도
  case failed(CommandFailure)                     // EK/저장 실패 — 상태 정의된 대로 롤백/보존됨
}
```

- **영구 실패는 throw하지 않는다**(기존 Core 규약). 일시 오류는 `failed(.retryable)`.
- 모든 EK 쓰기 command는 **사전 확인(optimistic check)**을 거친다(§F.2).
- 반복 이벤트에 대한 시간 변경은 `scope`가 필요하다. UI가 scope를 주지 않으면 `needsDecision(.recurrenceScope)`가 돌아온다.
- **undo**: MVP는 직전 command 1개의 undo 토스트 정도(EK에 이전 값으로 patch). 다단계 undo는 deferred.

### D.2 command별 정의

| Command | 입력 | 검증(Core) | EventKit write | 로컬 metadata write | 실패 시 UX |
|---|---|---|---|---|---|
| **CreateEvent** | calendarID, 제목, `EventTime`, (선택) 장소·메모·activityType·초기 연결 거래 | 쓰기 가능한 캘린더, 제목 허용(빈 제목 정책 §H), 시간 정책(최소 길이/종료>시작), 자정 넘김 허용, 하루~다일 범위 | **필요**(create) | activityType 또는 거래 연결이 있으면 Activity 생성 + 링크. **EK 성공 후** 기록(§F.4) | 검증 실패: 입력 위치에 인라인 오류. EK 실패: 드래프트 유지 + "저장 실패, 다시 시도". 로컬 실패(EK 성공): 이벤트는 생성됨, 메타 재시도 안내(데이터 손실 없음) |
| **MoveEvent** | 대상(Activity 또는 ref), 새 시작(또는 Δ분), (날짜 이동 포함), scope(반복 시) | 편집 가능, 길이 보존, snapping 규칙, 종일 이동은 일 단위, 반복+날짜 이동은 `thisOccurrence`만 허용(§D.4) | **필요**(update time) | 없음. 단 반복 `thisAndFuture/all` 후 ref 재바인딩 시 Activity ref 갱신 | 충돌: "다른 곳에서 변경됨" + 최신 위치로 블록 복귀. 읽기 전용: 블록 흔들림 + "읽기 전용 캘린더". EK 실패: 원위치 복귀 + 재시도 토스트 |
| **ResizeEventStart** | 대상, 새 시작, scope | 새 시작 < 종료 − 최소 길이(clamp, 뒤집기 없음), snapping, 종일 이벤트는 불가 | **필요** | 없음 | MoveEvent와 동일 |
| **ResizeEventEnd** | 대상, 새 종료, scope | 새 종료 > 시작 + 최소 길이, 표시 일 24:00 clamp(§D.4), snapping | **필요** | 없음 | MoveEvent와 동일 |
| **ChangeAllDay** | 대상, 종일 여부, (timed→종일: 일 범위 / 종일→timed: 시작+길이) | 반복 포함 시 scope, 시간 정보 손실 확인 | **필요** | 없음 | 손실 확인 다이얼로그(정보 손실 있을 때) |
| **DeleteEvent** | 대상, scope, **연결 처리 선택**(연결 유지(orphan) / 연결 해제) | 편집 가능, 연결된 거래가 있으면 `needsDecision`(§F.3) | **필요**(remove) | 연결 해제 선택 시 링크 삭제 + Activity 정리. 유지 시 Activity `eventMissing` | EK 실패: 이벤트 유지, 링크 변경 없음. 로컬 실패(EK 성공): Activity를 `eventMissing`로 다음 reconcile이 정리 |
| **LinkTransactionToEvent** | transactionID, 대상(ActivityID 또는 이벤트 ref+회차) | 거래 존재(원장 읽기), 링크 가능한 거래 종류(§H-1), 이미 다른 활동에 연결돼 있으면 **이동**(중복 링크 금지, 1거래:1활동), 대상 이벤트가 `eventMissing`이면 거부 | **불필요** | **필요**: 대상 Activity가 없으면 지연 생성 + 링크 upsert (한 로컬 트랜잭션) | 거래/이벤트 소실: 상태 새로고침 + "대상이 사라짐". 로컬 저장 실패: 드래그 취소(원래 위치) + 재시도 |
| **UnlinkTransaction** | linkID 또는 transactionID | 링크 존재(없으면 멱등 성공) | 불필요 | 링크 삭제, 연결이 0개고 메타 없는 Activity는 정리 가능 | 로컬 실패: 링크 유지 + 재시도 |
| **ChangeActivityType** | 대상, activityTypeID? | 존재하는 유형 | 불필요 | Activity 지연 생성/갱신 | 로컬 실패: 이전 값 유지 |

### D.3 멱등성과 재시도

- 모든 command는 클라이언트 생성 `commandID`를 가진다. 같은 `commandID` 재제출은 **같은 결과**를 돌려준다(응답 유실·중복 탭 방지). 최근 N개의 결과만 보관하면 충분(iOS 로컬 앱 수준).
- 링크 upsert는 `(transactionID)`가 유일 키 → 재시도해도 중복되지 않는다.

---

### D.4 상호작용 의미 (Drag/resize semantics) 정책 초안

모든 시간 계산은 `TimeSnapping` 등 **순수 함수**로 Core에 두고 UI가 호출한다. 수치는 **초안**이며 §H에서 확정.

| 항목 | 정책 초안 |
|---|---|
| **Snapping** | 기본 **15분**. 확대(zoom) 시 **5분**. 10분은 정시/반시와 어긋나므로 기본 목록에서 제외(설정 노출은 §H-5). 스냅은 **표시 시간대 벽시계 기준** |
| **최소 duration** | 15분(생성·리사이즈 공통). 더 짧게 만들 수 없음(clamp) |
| **이벤트 전체 drag** | 길이 보존, 시작을 snapping. 같은 날 안/다른 날로 이동 모두 같은 command(`MoveEvent`) |
| **top edge drag(시작 변경)** | 종료 고정, 시작 이동. `시작 ≤ 종료 − 최소 길이`로 clamp(**뒤집기 없음**) |
| **bottom edge drag(종료 변경)** | 시작 고정, 종료 이동. `종료 ≥ 시작 + 최소 길이`로 clamp. 일 뷰에서는 표시 일의 **24:00에서 clamp**(MVP는 리사이즈로 자정 넘김 안 함) |
| **빈 영역 drag로 생성** | 드래그 구간을 snapping해 [시작, 종료]. 구간이 최소 길이 미만이면 최소 길이로 확장. **탭만으로는 생성하지 않음**(오조작 방지). 롱프레스+드래그가 생성 제스처(제스처 충돌은 UI 세부). 생성 직후 제목 입력 시트, 취소 시 아무것도 저장 안 함(EK 호출은 확정 시점) |
| **자정 넘김** | 이벤트는 단일 구간 [start, end]로 저장(여러 날 걸침 가능). 일 뷰는 해당 일로 clip하고 `continuesFromPreviousDay/ToNextDay`를 표시. clip된 가짜 끝(24:00/00:00)은 **리사이즈 핸들을 제공하지 않음**. 이동은 길이를 보존하므로 자정을 넘길 수 있음 |
| **날짜 이동** | 일 뷰에서 주 스트립/가장자리 hover로 다른 날 선택 후 드롭. 시각(벽시계)·길이 보존. 이벤트 시간대 유지 |
| **종일 ↔ timed 전환** | 종일 → 시간 그리드로 드래그: 드롭 위치에서 **60분** timed로 변환. timed → 종일 영역으로 드래그: 시작일 종일로 변환(**시각 정보 손실, undo 토스트 제공**). 반복 이벤트는 scope 선택 |
| **겹치는 이벤트** | **허용**(캘린더의 일반 동작). 충돌 경고 없음(MVP). 레이아웃 열 배정만 계산. 거래는 시간 겹침과 무관하게 사용자가 연결 |
| **시간대** | 이벤트는 자기 시간대를 유지(floating은 floating 유지). 표시와 snapping은 **표시 시간대(기본: 기기 현재)** 의 벽시계 기준. 이벤트 시간대 ≠ 표시 시간대면 블록에 작은 배지(MVP는 표시만). 존재하지 않는 로컬 시각(DST 건너뜀)이 나오면 다음 유효 시각으로 보정 |
| **반복 일정** | 반복 회차에 시간 변경/삭제 시 **scope 선택 필수**(기본 선택은 `thisOccurrence`). **날짜가 바뀌는 이동은 `thisOccurrence`만 허용**(시리즈 요일 전체 이동 같은 모호한 의미는 MVP에서 제공하지 않음). 시각만 바뀌는 변경은 `allInSeries` 가능. `thisAndFuture`는 §C.4 spike 후 결정 |
| **transaction → event drag** | `LinkTransactionToEvent`. 드롭 대상 이벤트 하이라이트(블록 전체가 드롭 영역). 이미 다른 활동에 연결돼 있으면 **이동**(undo 토스트). 거래 시각과 이벤트 시간이 멀어도 허용(검증 안 함) |
| **transaction을 event 밖으로 drag** | 연결 해제 존(또는 블록 밖 드롭)에서만 `UnlinkTransaction`. **빈 타임라인 영역에 드롭해도 거래 시각은 바뀌지 않고** 단순히 연결이 해제된다 |
| **읽기 전용 이벤트** | 이동/리사이즈 불가(제스처 시작 시 shake). 거래 **연결은 허용**(OnAll 메타) |

### D.5 UI 임시 상태 vs 도메인

드래그 중 상태(`DragSession`: 대상, 현재 snapped 시간, 유효 여부)는 **UI/Core 순수 함수 결과의 임시 값**이며 어디에도 저장되지 않는다. 손을 뗄 때 하나의 command로 제출된다. 제스처가 취소되면 아무 일도 일어나지 않는다.

---

---

## E. Day timeline read model

### E.1 원칙

- UI는 EventKit 객체도 원장 전표도 만지지 않는다. `DayTimelineBuilder`(**순수 함수**)가 아래를 입력받아 `DayTimeline`을 계산한다.
  - 입력: `[EventSnapshot]`(캐시), `[Activity]`, `[TransactionActivityLink]`, `[TimelineTransaction]`(원장 읽기 포트의 결과), `CalendarAccessState`, `displayTimeZone`, `now`(주입).
  - 출력: 화면을 그릴 수 있는 값 타입. **레이아웃 용 겹침 열 배정까지 계산**(좌표/픽셀은 UI가 계산).
- 같은 입력 → 같은 출력(결정론). EventKit/원장 없이 단위 테스트 가능. 레거시 `app/timeline.py`의 "겹친 일정 배정" 계산을 이 빌더로 재작성하되 캘린더 이름·교통요금·일 경계 하드코딩은 제거한다.

### E.2 타입

```text
struct DayTimeline: Equatable, Sendable {
  var day: LocalDate
  var displayTimeZoneID: String
  var access: CalendarAccessState                // 접근 불가면 캐시 표시 + 배너용
  var freshness: Freshness                       // .live / .cached(asOf) / .stale — UI 배지용
  var allDay: [AllDayBlock]
  var blocks: [EventBlock]                       // 시간 있는 일정(해당 일로 clip)
  var unlinkedTransactions: [UnlinkedTransactionMarker]
  var summary: DaySummary
}

struct EventBlock: Equatable, Sendable {
  var id: BlockID                                // ActivityID 또는 (ref+회차)에서 만든 안정 ID — 드래그 중 identity 유지
  var activityID: ActivityID?                    // 지연 생성이라 nil 가능
  var title: String
  var start: Int64, end: Int64                   // 표시 일로 clip된 값 (unix ms)
  var continuesFromPreviousDay: Bool
  var continuesToNextDay: Bool
  var calendar: CalendarDisplay                  // 제목/색
  var activityType: ActivityTypeDisplay?
  var recurrence: RecurrenceBadge?               // 반복 아이콘 정도
  var layout: OverlapLayout                      // column, columnCount (겹침 그룹 내 위치)
  var linked: [LinkedTransactionSummary]         // 이 블록에 연결된 거래(시간순)
  var linkedTotal: Money?                        // 같은 통화일 때 합계, 혼합 통화면 nil
  var state: BlockState                           // .normal / .eventMissing / .syncPending / .conflict
  var capabilities: BlockCapabilities            // canMove, canResizeStart, canResizeEnd, canDelete, recurrenceScopes 허용 목록 — UI가 정책을 재구현하지 않도록
}

struct LinkedTransactionSummary: Equatable, Sendable {
  var linkID: LinkID
  var transactionID: LedgerEntryID
  var displayTitle: String                       // 상호/설명 (아래 주의)
  var amount: Money
  var direction: ExpenseDirection                // .spend / .refund / .income 표시용
  var occurredAt: Int64
  var timePrecision: TimePrecision               // .exact / .approximate(알림 시각 기반) — 표시 힌트
}

struct UnlinkedTransactionMarker: Equatable, Sendable {
  var transactionID: LedgerEntryID
  var displayTitle: String
  var amount: Money
  var direction: ExpenseDirection
  var positionedAt: Int64                        // 타임라인 위 위치
  var timePrecision: TimePrecision
  var hint: UnlinkedHint?                        // .linkedToMissingEvent(이전 일정이 삭제됨) 등
  var suggestedBlockID: BlockID?                 // 겹치는 블록(UI 하이라이트 힌트 전용, 저장 안 함 — 자동 연결 아님)
}

struct DaySummary: Equatable, Sendable {
  var eventCount: Int
  var linkedSpend: Money?, unlinkedSpend: Money?, totalSpend: Money?   // 순지출(환불 반영) 기준 §H-1
  var unlinkedCount: Int
}
```

### E.3 사용자 예시가 read model로 어떻게 나오는가

```text
09:00  (빈 시간)
10:00  EventBlock "수업"                       linked: []
12:00  EventBlock "점심"   linkedTotal 9,500원  linked: [식당 9,500]
14:00  EventBlock "연구실" linkedTotal 5,800원  linked: [카페 5,800]
19:00  EventBlock "데이트"                      linked: []
22:00  UnlinkedTransactionMarker "택시" 13,200원
Summary: events 4 · linked 15,300 · unlinked 13,200 · total 28,500
```

### E.4 주의점 (원장 연동 시 알려진 한계)

- **거래 표시 이름이 원장에 없다.** `LedgerEntry`는 상호/설명을 담지 않는다(red-team 확인). `TimelineTransaction`을 돌려주는 `TransactionTimelineSource` 포트가 `displayTitle`을 책임진다: 후보의 `sourceDraft.counterparty`(원문 상호) → 없으면 "지출 5,800원" 같은 기본 문구. 사용자 편집 이름 덮어쓰기는 후속(§H-8).
- **거래 시각의 정밀도.** `occurredAtUnixMilliseconds`는 현재 알림 게시 시각이며(red-team R6) 실제 결제 시각이 아닐 수 있다. 그래서 read model이 `timePrecision`을 전달하고 UI는 근사 시각을 표시한다. 원장 후보의 `ObservedTimestamp.source/precision`을 `TransactionTimelineSource`가 함께 조인한다. 거래가 **블록 밖에 놓여도 연결은 시간과 무관**하다(연결은 사용자 의사).
- **자동 연결은 없다.** `suggestedBlockID`는 UI가 드래그 중 타깃 하이라이트나 "여기에 연결?" 힌트로만 쓰는 **휘발성 값**이며 저장되지 않는다.
- **원장 쓰기 금지**: `TransactionTimelineSource`는 읽기 전용이다. 거래 시각 수정/이동은 이 모듈이 하지 않는다 — 거래를 타임라인 빈 곳에 드롭해도 **거래의 시각은 바뀌지 않는다**(§D.4).

### E.5 구성 방식 (UI가 원본을 조합하지 않도록)

```text
CalendarProvider ──► SyncReconciler ──► CalendarMetadataRepository (EventSnapshot 캐시, Activity, Link)
Ledger ──► TransactionTimelineSource ─┐
                                      ├─► DayTimelineBuilder (순수) ─► DayTimeline ─► UI
CalendarMetadataRepository ───────────┘
```

UI는 `DayTimeline`과 `timelineChanges()` 신호만 소비한다. 변경 신호 수신 시 해당 일의 `dayTimeline`을 다시 요청한다(증분 diff는 MVP 불필요).

---

## F. Sync / conflict rules

### F.1 동기화 모델 (EventKit에는 변경 토큰이 없다고 가정 🟡)

- **EventKit이 이벤트 필드의 원본.** 외부 변경은 "스냅샷 reconcile"로 반영한다.
- **트리거**: ① `storeChanges()` 신호(디바운스) ② 앱 foreground 진입 ③ 사용자가 보는 기간 변경 ④ command 후 echo 확인.
- **reconcile 범위**: (a) **보이는 기간 ± 여유**(예: 앞뒤 2주)의 이벤트 전체, (b) **연결(Activity)이 있는 이벤트는 기간과 무관하게 `event(for:)`로 개별 확인**(너무 많으면 최근/미래 N개로 제한 — 규모 가정은 §H-12).
- **diff**: 새 `EventSnapshot` 목록 vs 저장된 스냅샷을 `CalendarEventRef` 기준으로 비교 → `added / changed / removed`. 변경분만 저장소에 반영하고 `TimelineInvalidation` 발행. 같은 입력이면 같은 결과(멱등) → 자기 저장의 echo도 변경 없음으로 흡수된다.
- **원본 우선**: 동기화에서 EventKit 값과 로컬 스냅샷이 다르면 **EventKit이 이긴다**(스냅샷은 캐시일 뿐).

### F.2 쓰기 충돌 (OnAll 수정 직후 Apple Calendar에서도 수정)

**낙관적 확인 + 외부 우선.**
1. command 시점의 스냅샷 `fingerprint/versionToken`을 `expected`로 들고 간다.
2. adapter가 저장 직전에 이벤트를 다시 읽어 `expected`와 비교한다.
3. 다르면 **저장하지 않고** `conflict(current:)`를 반환 → UI: 블록을 최신 상태로 갱신하고 "다른 곳에서 일정이 바뀌었어요. 다시 수정하시겠어요?" (자동 재적용 없음).
4. 저장 중 경쟁(확인 이후 외부 저장)은 EK가 마지막 저장을 반영하는 것으로 가정(🟡 EK의 동시성 보장 정도 불확실). 이후 reconcile이 실제 값을 가져와 화면을 바로잡는다. **MVP에서는 이 짧은 경쟁 창을 허용**(로컬 앱 수준).

### F.3 삭제·캘린더 소실

| 상황 | 감지 | 처리 |
|---|---|---|
| **이벤트가 외부에서 삭제** | reconcile에서 `event(for:)` → `.notFound`(fingerprint 재매칭도 실패) | Activity `eventMissing`. **링크는 유지.** 거래는 타임라인에 `UnlinkedTransactionMarker`(hint: 연결된 일정이 삭제됨)로 보인다. 자동 삭제 없음. 사용자가 다른 일정에 재연결하거나 연결을 해제. 일정 "복원"(재생성) 제안은 deferred |
| **식별자가 바뀜** | `.notFound`지만 fingerprint가 정확히 1개 일치 | `CalendarEventRef` 자동 재바인딩(Activity 유지, 사용자 알림 없음) |
| 재매칭 후보가 2개 이상 | `.ambiguous` | `eventMissing` + 사용자 선택 필요(MVP는 기본 `eventMissing`로 두고 수동 재연결) |
| **OnAll에서 이벤트 삭제** | command | 연결된 거래가 있으면 `needsDecision`: "연결된 거래 N건: 연결 해제 / 유지" (기본: 해제 후 거래는 미연결로). 반복은 scope 선택 |
| **캘린더 전체 삭제** | `calendars()` diff에서 id 소실 | 해당 캘린더 이벤트의 Activity 일괄 `eventMissing`(+ 배너: "캘린더 'X'가 삭제됨"), 표시 캘린더 설정에서 제거 |
| **캘린더 쓰기 불가로 변경**(구독/공유 권한 변경 등) | `isWritable` 변화 | 해당 블록 `capabilities`에서 편집 비활성 |

### F.4 두 저장소 간 일관성 (EventKit ↔ 로컬 메타데이터)

두 곳을 원자적으로 쓸 수 없다. **분산 시스템 설계는 하지 않고 순서와 복구 규칙만 정한다.**

**핵심 단순화: 지연 생성(lazy) 덕분에 "이벤트는 있는데 Activity가 없는 상태"는 정상이다.** 따라서:

| 케이스 | 순서 | 실패 처리 |
|---|---|---|
| **메타데이터만 변경**(링크/유형) | 로컬 트랜잭션 한 번 | 실패 시 변경 없음 + 재시도. EK 무관 |
| **EK 필드만 변경**(이동/리사이즈) | EK 저장 → 성공 후 스냅샷 캐시 갱신(로컬) | EK 실패: 로컬 변경 없음, 블록 원위치. EK 성공+캐시 갱신 실패: **무해**(다음 reconcile이 EK 값을 가져옴) |
| **EK + 메타 동시**(Create with type/link, Delete with unlink) | ① 로컬에 `PendingOperation(commandID, 의도, 예상 결과)` 기록 ② EK 저장 ③ 성공이면 메타 적용+pending 완료(한 로컬 트랜잭션) | ② 실패: pending 삭제, 변경 없음. ③ 실패(EK는 성공): pending이 남아 **앱 시작/reconcile 시 완료 재시도**(EK에서 결과 이벤트를 찾아 메타 적용). 이벤트 자체는 이미 존재하므로 데이터 손실 없음 |
| **로컬에만 저장되고 EK 실패**(반대) | EK가 먼저이므로 발생하지 않음. 로컬 선기록은 `PendingOperation`뿐이고 EK 실패 시 즉시 삭제 | pending 잔재가 남으면(앱 종료) 시작 시 EK 상태를 보고 "적용됨/미적용" 판정 후 정리 |

`PendingOperation`은 **create/delete + 메타 동반**일 때만 사용하는 아주 작은 의도 로그(수십 건 이하, 완료 시 삭제)다. 이를 넘는 outbox/큐 일반화는 하지 않는다.

### F.5 권한 변화

| 변화 | 처리 |
|---|---|
| fullAccess → **denied / restricted / writeOnly** | `access` 상태 갱신. **캐시된 스냅샷으로 읽기 전용 타임라인** 표시 + 상단 배너("설정에서 캘린더 접근을 허용해주세요"). EventKit 쓰기 command는 `rejected(.accessUnavailable)`. 메타 전용 command(연결/해제/유형)는 **허용**(OnAll 소유 데이터). 권한 복구 시 reconcile |
| 권한 변화 감지 시점 | foreground 진입 + `storeChanges` + 오류 시 재확인. 🔴 앱 실행 중 철회 시 동작은 spike |
| writeOnly | 이벤트를 읽을 수 없으므로 fullAccess가 아니면 일정 기능 불가(쓰기만 되는 것은 OnAll에 쓸모 없음) |

### F.6 EventKit 저장 실패

- 분류: 접근 거부 / 쓰기 불가 캘린더 / 캘린더 소실 / 이벤트 소실 / 일시적 저장 실패. 일시적은 `failed(retryable)`로 "다시 시도" 제공. 낙관적 UI(블록을 새 위치에 먼저 그리기)를 쓰되 **실패 시 원위치 복귀 애니메이션 + 토스트**로 되돌린다.

---

## G. MVP vs deferred

### G.1 MVP에 꼭 필요한 것

| 영역 | 포함 |
|---|---|
| 권한 | Full Access 요청/상태 표시/거부 시 읽기 전용 캐시 |
| 읽기 | 캘린더 목록·표시 선택, 하루/주 단위 이벤트 조회, 반복 회차 표시, 종일 이벤트 |
| 편집 | 생성(빈 영역 drag), 이동, top/bottom 리사이즈, 삭제, 제목/장소/메모 편집, 반복은 `this/all` |
| 거래 | 거래 목록을 같은 일 타임라인에 표시(연결/미연결), 연결/해제/이동(drag), 블록별 합계, DaySummary |
| 메타 | Activity 지연 생성, ActivityType 최소 지원 |
| 동기화 | reconcile(foreground/변경 신호), 외부 삭제 → `eventMissing`, 낙관적 충돌 확인, 캘린더 삭제 처리 |
| 일관성 | 위 §F.4의 `PendingOperation`(생성/삭제+메타 동반) |
| 테스트 기반 | `InMemoryCalendarProvider`(외부 편집/오류 주입), 순수 빌더 golden test |

### G.2 MVP 이후로 미룰 것

AI activity inference, 실제 시간(observed actual time), 위치 추론, 반복 활동 학습, 자동 캘린더 이벤트 생성, 자동 이벤트 시간 보정, 공유 캘린더의 고급 충돌 해결(참석자 응답/초대 수정), 다단계 undo, 반복 규칙 편집 UI, `thisAndFuture`(spike 결과에 따라 MVP 이후 가능), 거래 → 일정 생성 제안, 거래 분할 연결(한 거래를 여러 활동에), 알람/참석자 편집, 위젯/알림, 다중 통화 합계, 시간대 여행 지원(표시만 구현).

### G.3 확장 지점 (**구현하지 않고 막지도 않는** 장치)

| 미래 기능 | 열어 둔 지점 |
|---|---|
| 관찰된 실제 활동 / AI 추론 | `Activity.eventRef == nil` 허용, `LinkSource` 확장(`.inferred`), 저장 `schemaVersion`으로 필드 추가 |
| 실제 시간(actual) | `Activity`에 optional `actualTime` 추가(계획 시간은 EventKit, 실제는 OnAll 소유 — 소유권이 이미 분리돼 있음) |
| 자동 연결/제안 | `suggestedBlockID` 힌트 계산 위치가 이미 존재(저장 없음). 수락 시 `.suggestedThenAccepted` 링크 |
| 위치 추론 | `EventSnapshot.location`과 독립된 `Activity` 필드로 추가 |
| 반복 활동 학습 | 회차 단위 Activity가 학습 데이터 단위로 적합 |

---

## H. Open product decisions (결정 전에는 기본값 사용)

| # | 결정 | 제안(기본값) |
|---|---|---|
| 1 | 타임라인에 보여줄 거래 종류: 지출만 / 환불 포함 / 수입·이체 포함 | 지출 + 환불(순지출). 이체·카드대금은 제외(소비 아님). 수입은 표시만 |
| 2 | 1거래 : 1활동(이동식) 고정? 거래 분할 연결? | 1:1(이동). 분할은 후속 |
| 3 | 이벤트 삭제 시 연결 처리 기본값 | "연결 해제"를 기본, 선택지 제공 |
| 4 | ActivityType: 단일 유형 vs 복수 태그, 기본 목록, 거래 카테고리와의 관계 | 단일 유형(편집 가능한 소수 목록), 카테고리와 분리 |
| 5 | snapping 기본/설정 노출, 최소 길이 | 15분 기본, 줌 시 5분, 최소 15분. 설정 UI는 후속 |
| 6 | 반복 `thisAndFuture` MVP 포함 여부 | spike 후 결정. 기본: 제외 |
| 7 | 빈 제목 허용/기본 제목, 새 이벤트 기본 캘린더, OnAll 전용 캘린더 생성 여부 | 사용자의 기본 캘린더 + 변경 가능. 전용 캘린더는 만들지 않음 |
| 8 | 거래 표시 이름 사용자 편집 | MVP 제외(원문 상호 표시) |
| 9 | 다일(multi-day) 일정의 일 뷰 표현 | clip + 연속 표시(위 정책). 별도 헤더 영역은 후속 |
| 10 | 최소 iOS 버전 | iOS 17(Full Access API 기준). 확정 필요 |
| 11 | 읽기 전용/구독/공유 캘린더 표시 정책 | 표시하되 편집 비활성, 거래 연결은 허용 |
| 12 | 연결된 이벤트 개별 확인의 규모 상한(최근/미래 N개) | 수백 건 가정. 실제 데이터로 조정 |
| 13 | 거래 시각이 근사일 때 타임라인 위치 표시 방식 | 근사 배지 + 위치 고정(휴리스틱 보정 금지) |
| 14 | 외부 삭제된 일정에 연결된 거래의 보관 기간/정리 | 사용자가 정리할 때까지 보존 |

---

## I. 구현 순서 제안

앞 단계가 뒤 단계의 위험을 줄이도록 **EventKit 불확실성은 일찍 조사하고, 순수 로직은 Windows에서 먼저 굳힌다.**

1. **EventKit spike(병렬 시작, 코드 최소·버릴 수 있음)** — §C.4의 🔴/🟡 항목(식별자 안정성, 반복 회차/예외, `thisAndFuture` 동작, 종일 종료 관례, 권한 철회, 변경 알림 동작)을 기기에서 확인하고 결과를 이 문서에 반영. 이 결과가 B.3/B.4와 MVP 범위(반복 scope)를 확정한다. (macOS/iOS 환경 필요)
2. **도메인 타입과 순수 정책** — `NEOBudgetCalendar` target 신설: `EventTime`/`LocalDate`/`CalendarEventRef`/`Activity`/`TransactionActivityLink`, `TimeSnapping`·리사이즈 clamp·반복 scope 규칙·command 검증. 단위 테스트(경계: 최소 길이, 자정, DST, 종일 전환). Windows에서 실행 가능.
3. **포트 + in-memory 구현 + reconcile** — `CalendarProvider`, `CalendarMetadataRepository`, `TransactionTimelineSource` 정의. `InMemoryCalendarProvider`(외부 편집/삭제/캘린더 삭제/권한 변경/저장 실패/식별자 변경 주입), 스냅샷 diff `SyncReconciler`와 재바인딩 로직. §F의 모든 시나리오를 이 단계 테스트로 먼저 고정.
4. **`DayTimelineBuilder` + golden test** — E.3 예시 하루, 겹침 열 배정, 자정 걸침, 미연결 거래, `eventMissing`, 접근 불가 캐시 상태, 근사 시각 거래. 순수 함수라 빠르게 반복 가능.
5. **Command handler** — 메타 전용(link/unlink/type) → EK 쓰기(move/resize/create/delete) 순으로. 충돌·`PendingOperation` 복구·멱등성(commandID) 테스트. 원장 연동은 읽기 전용 `TransactionTimelineSource` 구현(표시 이름·시각 정밀도 조인 포함).
6. **EventKit adapter (iOS 전용)** — spike 결과를 반영해 `CalendarProvider` 구현. 계약 테스트 스위트를 in-memory와 EK 양쪽에 같은 케이스로 실행(가능한 범위). patch 저장으로 미모델 필드 보존 검증.
7. **SwiftUI 타임라인 + 제스처** — `DayTimeline`만 렌더링하고 command만 제출. 드래그 미리보기는 순수 함수 호출. 먼저 이동/리사이즈/생성, 이후 거래 drag 연결. 수동 QA 시나리오(반복 일정, 읽기 전용 캘린더, 권한 변경, 외부 편집 경합).
8. **하드닝** — foreground/백그라운드 reconcile 시점, 대량 데이터 성능(기간 조회·링크 확인), 접근성(드래그 대체 조작), 오류 문구, 베타 운영 체크리스트. 이후에 deferred 목록을 우선순위로 재평가.

> **다음 확인이 필요한 것**: (1) EventKit spike를 누가/언제 수행할지(Apple 기기와 Xcode 필요), (2) §H의 결정 중 1·2·3·4·6·10, (3) 새 `NEOBudgetCalendar` target을 현재 진행 중인 `refactor/ingestion-pipeline`에서 분기할지 별도 브랜치로 둘지.
