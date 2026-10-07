# Calendar / Activity / Semantic 도메인

상태: **Windows에서 구현·검증된 플랫폼 독립 계층.** EventKit, SwiftUI, iOS 앱 target, 실기기 확인이 필요한 것은 구현하지 않았고 §9에 모았다.
관련: 초기 설계 초안 [calendar-integration-design.md](calendar-integration-design.md)(이 문서가 구현 결정의 기준이며 차이는 그 문서 상단에 적었다), 결정 기록 [decisions.md](decisions.md) D009.

## 1. 구조

```text
NEOBudgetCore                (기존: 원장·parser·promotion. 이번 변경 없음)
      ▲
NEOBudgetCalendar            순수 Swift. Calendar / Activity / Tag / Area / ActivityType / Link /
      ▲                      DayTimeline read model / drag·resize 정책 / command service / 포트
NEOBudgetInMemoryCalendar    테스트용 in-memory provider·저장소·거래 소스(고장 주입 포함)

(향후, 이 Package 밖)  iOS adapter: EventKit 기반 CalendarProvider, SwiftUI 화면 → NEOBudgetCalendar만 의존
```

- `NEOBudgetCalendar`는 `NEOBudgetCore`에서 `LedgerEntryID`, `Money`, `LedgerSnapshot`만 읽는다. **원장에 쓰지 않는다.**
- EventKit/SwiftUI/Apple framework를 import하지 않는다(`Foundation`만 사용: 시간대 계산).
- 기존 target과 기존 테스트는 변경하지 않았다. 새 target 3개를 `Package.swift`에 추가했다.

## 2. 의미 모델 (네 축 + Calendar)

| 개념 | 질문 | 소유 | 자동화 정책 | 타입 |
|---|---|---|---|---|
| **Category** | 무엇에 돈을 썼는가 | canonical taxonomy(정의는 별도) | 흔하고 공통적 → 자동화 가능, 모르면 **미분류** | `CanonicalCategoryID`, `CategoryClassification` |
| **Activity** | 어떤 실제 생활 활동에 속하는가 | **OnAll** | 개인 의미가 강함 → 사용자 결정 우선 | `Activity`, `ActivityTypeDefinition` |
| **Tag** | 개인적인 세부 분석 맥락 | **사용자** | 자동화는 기존 태그 **선택만**, 생성 불가 | `Tag`, `TagAssignment` |
| **Area** | 어느 생활권/상권인가 | 사용자·카탈로그 | 정확 일치만 해석, 추측 안 함 | `Area`, `AreaCatalog` |
| **Calendar** | 이벤트가 담긴 달력(일상·학교·연구실…) | 외부 캘린더 | 해당 없음 | `CalendarDescriptor` |

- **Calendar와 ActivityType은 별개 축**이다. 같은 enum이 아니고 ID 타입도 다르다(`CalendarID` vs `ActivityTypeID`). 연구실 캘린더의 이벤트가 `학업`/`업무`/`동아리` 어느 활동이든 될 수 있다.
- `ActivityType`: preset 10종(`데이트·친구·사교·운동·업무·학업·가족·여가·볼일·동아리·기타`, ID는 `preset.*`로 고정, 표시 이름은 변경 가능)과 사용자 정의 type. 보관(archive) 가능하며 보관된 type은 새로 배정할 수 없다.
- **`Activity 없음`은 정상 상태**다. 그 소비는 `DaySummary`에서 `unlinkedNetMinorUnits`(활동 외 소비)로 집계되며 오류·경고가 아니다.

## 3. 구현된 타입

**Calendar** (`Calendar/`): `CalendarID`, `CalendarEventID`(provider가 발급하는 **불투명 토큰**), `CalendarDescriptor`, `CalendarEventKey(calendarID, eventID)`, `CalendarEvent`, `CalendarEventDraft`, `CalendarEventUpdate`(patch: `FieldUpdate.keep/set/clear`), `EventTimeRange`(`.timed(TimedRange)` / `.allDay(DayRange)`, 잘못된 범위는 생성 불가), `LocalDate`, `DisplayTimeZone`(검증된 IANA zone), `RecurrenceScope`(의도만), 포트 `CalendarProvider`(+ `CalendarProviderResult/Failure`).

**Activity** (`Activity/`): `Activity`(안정 `ActivityID`, `origin`: `.calendarEvent(CalendarEventAssociation)` 또는 `.standalone`), `CalendarEventAssociation`(key + last-known 요약 + `present/missing(since)`), `TransactionActivityLink`, `LifeState`(모든 불변식을 가진 순수 값), `LifeChange`, `LifeRepository`(revision CAS), `CalendarReconciler`(순수).

**Semantic** (`Semantic/`): `AssignmentProvenance`(source/confidence/origin/시각), `Assigned<T>`, `AssignmentPolicy`, `ActivityTypeDefinition`, `Tag`, `Area`, `AreaCatalog`, `CategoryClassification`, `NameNormalizer`.

**Timeline** (`Timeline/`): `DayTimelineBuilder`(순수), `DayTimeline`/`EventBlock`/`AllDayItem`/`TransactionMarkerItem`/`DaySummary`, `WeekStripBuilder`, `TransactionMarker`, `TransactionSource`, `LedgerTransactionSource`.

**Editing / Commands**: `TimelineEditPolicy`(순수 drag/resize 의미), `CalendarCommand`(11종), `CalendarCommandService`(actor), `CalendarCommandOutcome`.

## 4. 핵심 불변식과 이를 증명하는 테스트

| 불변식 | 증명 |
|---|---|
| `TimedRange`/`DayRange`/`LocalDate`/`DisplayTimeZone`은 잘못된 값을 만들 수 없다(생성·디코딩 모두) | `FoundationTests` |
| 링크는 **시간 포함 관계가 아니다**: 이틀 전 구매한 영화표를 오늘의 데이트에 연결할 수 있고, 오늘 타임라인에서 그 블록 안에 `occursOnSelectedDay=false`로 보인다 | `aTransactionBoughtDaysBeforeTheEventCanStillBeLinkedToIt`, `aTransactionLinkIsMeaningNotTimeContainment` |
| 한 거래는 한 Activity에만 연결되고 재연결은 이동이다 | `relinkingMovesATransactionInsteadOfDuplicatingIt` |
| 이벤트가 사라져도 Activity와 링크는 남는다(`eventMissing`), 새 링크는 거부된다 | `anEventDisappearingKeepsTheActivityAndItsLinks`, `anActivityWhoseEventIsGoneCannotTakeNewLinks`, `anEventDeletedElsewhereStaysVisibleAsAGhostWithItsSpending` |
| Activity는 필요할 때만 만들어진다(지연 생성) | `linkingMaterializesTheActivityLazilyAndReusesItAfterwards`, `clearingATypeNeverCreatesAnActivityJustToClearIt` |
| Activity는 캘린더에 종속되지 않는다(`standalone`) | `anActivityNeedsNoCalendarAtAll` |
| **자동 배정은 사용자 결정을 덮어쓰거나 지울 수 없다**(type/area/tag/link/transaction tag, 변경과 삭제 모두) | `automationCannotOverwriteOrRemoveAUserDecision`, `aUserCanConfirmAnAutomatedLinkAndThatDecisionThenSticks` |
| 신뢰도 부족·없음 자동 배정은 **저장되지 않는다**(미분류가 오분류보다 낫다) | `lowConfidenceAutomationIsNotStored`, `lowConfidenceCategoryStaysUnclassifiedInsteadOfGuessing` |
| 태그는 사용자의 기존 비보관 태그에서만 고른다 — 자동화가 만들 수 없다 | `anAutomatedProposalCannotCreateAnUnknownOrArchivedTag`, `tagsAreChosenFromExistingOnesNeverInvented` |
| Area는 이름·alias 중복, 순환, 없는 상위 지역을 거부한다. 해석은 정확 일치만 | `areaCatalogRejectsDuplicatesCyclesAndMissingParents`, `areasResolveByNameOrAliasAndNeverByGuessing` |
| `LifeState.applying`/저장소 commit은 all-or-nothing | `applyingChangesIsAllOrNothing`, `anInvalidChangeLeavesTheRevisionAndStateUnchanged` |
| 이벤트 수정은 patch이며 모르는 필드를 지우지 않는다 | `editingIsAPatchThatKeepsEverythingItDoesNotMention`, `providerUpdatesArePatchesThatKeepUnmentionedFields` |
| 오래된 revision으로는 쓰지 않는다(외부 변경을 덮어쓰지 않음) | `aStaleRevisionIsAConflictAndNothingIsOverwritten`, `providerRefusesAStaleRevisionWithoutWriting` |
| 캘린더 쓰기 실패 시 로컬 변경 없음 / 로컬 실패 시 `partiallyApplied`로 정직하게 보고 | `theCalendarCanFailASaveWithoutAnyLocalSideEffects`, `ifTheLocalFollowUpFailsAfterTheCalendarWriteTheEventIsKeptAndTheOutcomeSaysSo` |
| 반복 이벤트는 명시적이고 provider가 지원하는 scope가 필요하고, 날짜가 바뀌는 변경은 `thisOccurrence`만 | `EventCommandTests`의 Recurrence 4건 |
| timeline 출력은 입력 순서와 무관(결정론) | `outputDoesNotDependOnInputOrder` |

## 5. 정책 (순수 함수, 모두 테스트됨)

**Drag/resize** (`TimelineEditPolicy`): snap 기본 15분 / zoom 5분 — 로컬 자정 기준 가장 가까운 격자로, 정확히 중간이면 올림. 최소 길이 15분(생성·리사이즈 공통). 전체 drag = 길이 보존 + 시작 snap. top edge는 `시작 ≤ 종료 − 최소`로, bottom edge는 `종료 ≥ 시작 + 최소`로 clamp하며 뒤집히지 않는다(`wasClamped` 반환). bottom resize는 선택한 날의 끝으로 clamp 가능. 빈 영역 drag 생성은 두 끝을 정렬·snap하고 최소 길이로 확장(탭과 drag의 구분은 UI 몫). 다른 날로 이동하면 로컬 시각·길이 보존(DST 날에도 벽시계 유지). 종일→timed는 기본 60분, timed→종일은 시간 정보 소실. 겹침 허용, 자정 넘김 허용.

**DayTimeline**: 선택일로 clip(`continuesFromPreviousDay/ToNextDay`), 종일은 별도 목록, 겹침 열 배정(cluster별 `column/columnCount`; 정렬은 시작↑·길이↓·ID로 결정), **최소 시각 높이**(표시 범위만 늘림; 하루 끝을 넘지 않음; 늘어난 표시 범위 기준으로 열을 배정), DST 날의 실제 길이(23/25시간), 블록 크기는 **시간 기준이며 금액과 무관**. 선택일 거래는 연결 안 됨(`unlinked`) / 다른 날 활동에 연결(`linkedElsewhere`)로 표시하고, 보이는 활동에 연결된 거래는 날짜와 상관없이 그 블록의 `linked`에 나온다.

**AssignmentPolicy**: 사용자는 항상 허용, 자동은 신뢰도 ≥ 0.85(기본)이고 값이 있어야 한다.

## 6. 일관성 (구현된 것)

- 쓰기 순서: **캘린더 provider 먼저, 로컬 나중.** provider가 실패하면 로컬은 바뀌지 않는다. provider 성공 후 로컬이 실패하면 `partiallyApplied`(이벤트는 올바르고 로컬 부분만 재시도 가능, 데이터 손실 없음).
- 메타데이터만 바꾸는 command(연결/해제/유형/태그)는 provider를 건드리지 않는다.
- 영구 실패는 throw가 아니라 `CalendarCommandOutcome`의 값이다(원장 red-team R7의 교훈).
- **구현하지 않은 것**: 의도 로그(`PendingOperation`)와 앱 재시작 후 복구, command ID 기반 멱등성, undo(§10).

## 7. Category / Merchant 훅

이번에 구현한 것은 끝단의 계약뿐이다: `CanonicalCategoryID`(자유 텍스트 category 없음), `CategoryClassification`(`unclassified(reason)`이 **명시적 상태**이고 초기값), `AssignmentPolicy.classification(proposing:...)`(낮은 신뢰도 제안은 `unclassified(.ambiguous)`로 남고 사용자의 선택은 덮어쓰지 않음). `raw description → canonical payee/merchant → merchant type → canonical category → Activity/Tag/Area` 체인의 앞 단계와 category 저장 위치, canonical taxonomy 정의는 후속이며 이 타입들과 충돌하지 않는다.

## 8. 원장과의 경계

- `TransactionSource`(읽기 전용)가 원장에서 소비만 보여준다: `expense`와 `adjustment(return)`. 수입·이체·카드대금은 제외. 금액은 양의 크기 + `flow`(spend/refund), 합계는 환불을 뺀 순지출.
- 원장 `LedgerEntry`에는 상호/설명이 없으므로 `title`은 선택 입력(후보의 원문 상호를 조인해 넣는 책임은 호출 측).
- 원장 시각은 현재 알림 게시 시각이라 `TimePrecision.approximate`가 기본이다(UI가 근사임을 표시할 수 있도록).
- 연결은 원장 밖의 별도 저장소(`LifeState`)에 있다. 원장은 변경하지 않는다.

## 9. Mac/Xcode가 있어야 하는 작업 (구현하지 않음)

| 항목 | 필요한 이유 / 확인 대상 |
|---|---|
| `EventKit` 기반 `CalendarProvider` 구현 | 플랫폼 API. 포트 계약(`CalendarProvider`)은 이미 정의됨. 계약 테스트는 in-memory provider 테스트를 같은 케이스로 재사용 |
| SwiftUI 타임라인, 제스처 인식, 좌표↔분 변환, 드래그 미리보기 | UI. 정책 함수와 read model은 준비됨 |
| iOS 캘린더 권한 흐름 | 시스템 권한 다이얼로그. `ProviderFailure.accessUnavailable`로 이미 표현됨 |
| **EKEvent identifier 안정성** (동기화·계정·수정 시 변하는가, 반복 회차 식별) | 실기기 확인 전에는 가정 금지. 그래서 `CalendarEventID`를 불투명 토큰으로 두고 재바인딩은 구현하지 않음(`CalendarReconciler` 주석) |
| **반복 이벤트 scope의 provider 매핑** (`thisAndFuture`/`allInSeries`의 실제 동작, 시리즈 분할 시 식별자) | 추측해서 코드에 박지 않음. `RecurrenceScope`는 의도만 표현하고 provider가 지원 범위를 선언 |
| 종일 이벤트의 종료일 관례, floating(시간대 없는) 이벤트 해석 | adapter가 `DayRange`/`timeZoneIdentifier`로 정규화해야 함 |
| 변경 통지(`EKEventStoreChanged`)의 시점·빈도, 자기 저장 echo | `CalendarService.reconcile` 호출 시점 결정에 필요 |
| 권한 철회가 앱 실행 중에 어떻게 드러나는가 | foreground 재확인 정책 |
| iPhone 실기기 성능(대량 이벤트 조회), 접근성, 제스처 충돌 | 실기기 |
| 최소 iOS 버전과 Info.plist 설명 문구 | 앱 target 설정 |

## 10. 의도적으로 구현하지 않은 것 (Mac과 무관)

command ID 멱등성, `PendingOperation` 의도 로그와 앱 시작 시 복구, 다단계 undo, 이벤트 ID 변경 시 Activity 재바인딩, 본문(캘린더 제목) 기반 Area 후보 추출(정확 일치 `resolve`만 있음), 비선형 시간 축(semi-proportional scale; 현재는 선형만), merchant DB/LLM 분류, category 저장소, 거래를 여러 Activity에 분할 연결, 외부 인물 송금 모델, durable 저장소(SwiftData/SQLite), 캘린더 표시 선택 UI(`visibleCalendarIDs` 인자만 있음).

## 11. 위험과 열린 질문

- `InMemoryCalendarProvider`는 **계약 정의용**이며 실제 캘린더와 동일하다고 주장하지 않는다. 종일 이벤트 조회는 시간대가 없어 ±1일로 넓게 반환하고 호출 측이 다시 거른다. 실제 adapter가 같은 계약 테스트를 통과하는지는 Mac에서 확인해야 한다.
- 이벤트 ID 변경(§9)이 실제로 일어나면 Activity가 `eventMissing`으로 잘못 표시될 수 있다. 데이터는 보존되며 사용자가 재연결해야 한다(재연결 command는 아직 없음 — 필요하면 `updateAssociation` 기반 command 추가).
- 거래의 `TimePrecision`을 원장에서 가져오는 방법이 아직 없다(원장 시각이 알림 게시 시각이기 때문). 정확도가 필요하면 후보의 `ObservedTimestamp`와 조인하는 어댑터가 필요하다.
- Activity 삭제 시 연결 처리 기본값(`keepLinks`), 자동 배정 신뢰도 기준(0.85), snap/최소 길이 값은 **초기 제안 값**이며 사용 중 조정한다.
- `DayTimeline`의 `eventCount`에는 삭제된 이벤트의 ghost 블록도 포함된다(ghost는 정책으로 숨길 수 있다).
- 한 거래가 여러 활동에 걸치는 정산성 송금은 1거래:1활동 모델이라 표현하지 못한다(후속).
