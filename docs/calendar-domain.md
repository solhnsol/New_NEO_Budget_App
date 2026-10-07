# Calendar / Activity / Semantic / Settlement 도메인

상태: **Windows에서 구현·검증된 플랫폼 독립 계층.** EventKit, SwiftUI, iOS 앱 target, 실기기·서버·외부 API가 필요한 것은 구현하지 않았고 §13에 모았다.
관련: 초기 설계 초안 [calendar-integration-design.md](calendar-integration-design.md)(구현 결정의 기준은 이 문서), 결정 기록 [decisions.md](decisions.md) D009(캘린더/활동), **D010(거래 분할·금액 지식·정산)**.

## 0. 아키텍처 원칙

> **OnAll은 불완전한 정보를 버리거나 억지로 확정하지 않는다. 알고 있는 수준 그대로 저장하고, 후속 evidence로 점진적으로 정밀하게 만든다.**
>
> **실제 송금액이 obligation과 다르다는 것은 정산 실패의 증거가 아니라, 다른 obligation이 상계되었을 가능성을 의미할 수 있다.**
>
> **유일하게 설명 가능한 경우에만 unknown 값을 자동으로 inferred 값으로 승격한다.**

여기에 앞선 원칙이 그대로 이어진다: 반복적·공통적인 것은 자동화하고 개인적 의미가 강할수록 사용자 결정을 우선한다. 잘못된 자동 분류보다 미분류가 낫다. 외부 캘린더가 이벤트 필드의 원본이고, 원장은 불변이며(이 계층은 읽기만 한다), 영구 실패는 예외가 아니라 typed 결과다.

## 1. 구조

```text
NEOBudgetCore                (기존: 원장·parser·promotion. 변경 없음)
      ▲
NEOBudgetCalendar            순수 Swift. Calendar / Activity / Tag / Area / Person / ActivityType /
      ▲                      금액 지식 / 거래 분할 / Obligation / Settlement / 참여자 친밀도 /
      ▲                      DayTimeline read model / drag·resize 정책 / command service / 포트
NEOBudgetInMemoryCalendar    테스트용 in-memory provider·저장소·거래 소스(고장 주입 포함)
```

- `NEOBudgetCalendar`는 `NEOBudgetCore`에서 `LedgerEntryID`, `Money`, `LedgerSnapshot`만 읽는다. **원장에 쓰지 않는다.**
- EventKit/SwiftUI/Contacts/Messages/지도/LLM/은행 API를 import하지 않는다(`Foundation`만 사용: 시간대, `pow`).

## 2. 의미 축

| 개념 | 질문 | 소유 | 자동화 정책 | 타입 |
|---|---|---|---|---|
| **Category** | 무엇에 돈을 썼는가 | canonical taxonomy | 흔하고 공통적 → 자동화 가능, 모르면 **미분류** | `CanonicalCategoryID`, `CategoryClassification` |
| **Activity** | 무엇을 했나 | **OnAll** | 개인 의미가 강함 → 사용자 결정 우선 | `Activity`, `ActivityTypeDefinition` |
| **Tag** | 어떤 맥락인가 | **사용자** | 기존 태그 **선택만**, 생성 불가 | `Tag`, `TagAssignment` |
| **Area** | 어디였나 | 사용자·카탈로그 | 정확 일치만 해석 | `Area`, `AreaCatalog` |
| **Participant** | 누구와 했나 | **사용자** | 후보 제안(추천)만, 관계 추론 금지 | `Person`, `ParticipantAssignment` |
| **Calendar** | 이벤트가 담긴 달력 | 외부 캘린더 | 해당 없음 | `CalendarDescriptor` |

- **Calendar와 ActivityType은 별개 축**이다(ID 타입부터 다르다).
- **`Activity 없음`은 정상 상태**다. 그 소비는 `DaySummary`에서 `unlinkedNetMinorUnits`(활동 외 소비)로 집계된다.
- **"복합"은 Category가 아니다.** 여러 unknown 구성요소가 합계만 알려진 상태는 canonical category를 추가하지 않고 `AmountGroup`(미해결 배분 상태)으로 표현한다(§6).

## 3. 이전 모델에서 바뀐 것 (migration)

| 이전 (f218a2e) | 문제 | 지금 |
|---|---|---|
| `TransactionActivityLink`: 거래 ID가 키인 **1거래:1활동** | 80,000원 송금을 세 활동에 나눌 수 없다. 금액을 모르는 배분, 일부만 배분, 활동 외 명시 배분을 표현할 수 없다 | **`TransactionAllocation`**: 거래의 한 **부분**을 활동(또는 명시적으로 활동 없음)에 배정하는 N:M 관계. `LifeState.allocationSets`가 거래별 집합을 보관 |
| `setLink/removeLink`, `links(forActivity:)` | 위와 동일 | `upsertAllocation/removeAllocation/setAllocationAmount`, `allocations(forActivity:)` |
| `LinkedTransactionItem`/`linkedTotals`/`MarkerLinkState` | 거래 전체 금액 = 활동 금액으로 가정 | `AllocationItem`(배분 금액·부분 여부), `allocatedSpend/allocatedRefunds`(불확실성 보존 집계), `MarkerAllocation` |
| `linkTransaction`/`unlinkTransaction` command | — | **유지**: 각각 "거래 전체를 한 활동에 배정(기존 배분 교체)", "모든 배분 제거"로 동작하는 편의 command. 일반 형태는 `setAllocations` |

호환용 우회 abstraction은 두지 않았다. `TransactionActivityLink` 타입은 삭제했다. 의미(링크는 시간 포함 관계가 아님)는 그대로 승계된다.

## 4. 금액 지식 (`AmountKnowledge`)

금액을 숫자 하나로 쓰지 않는다. 얼마나 아는가를 값으로 가진다.

| 수준 | 의미 | hard bound | `rank` |
|---|---|---|---|
| `unknown` | 금액을 모름 | [0, ∞) | 0 |
| `range(min,max)` | 가능한 범위만 앎 | [min, max] | 1 |
| `estimated(v)` | 누군가의 대략적 추정(soft). **bound를 만들지 않는다** | [0, ∞) | 2 |
| `inferred(v, evidence)` | 다른 사실에서 논리적으로 역산. **exact와 다르다** | [v, v] | 3 |
| `exact(v)` | 직접 관측되었거나 사용자가 확정 | [v, v] | 4 |

`AmountEntry`는 통화·지식·출처(provenance)를 묶는다. 통화는 컨테이너가 가지며 서로 다른 통화는 합산하지 않는다.

### 갱신 규칙 (`AmountUpdatePolicy`) — 기존 provenance 보호와 통합

| 요청자 | 규칙 |
|---|---|
| **사용자** | 어떤 수준으로든 설정 가능(사용자 자신의 exact도 바꿀 수 있다) |
| **자동** | **사용자가 확정한 exact는 덮어쓰지 못한다**(같은 값을 inferred로 쓰는 것도 거부). 지식을 약화하지 못한다. 같은 수준이면 range를 **좁히는** 것만 허용하고 넓히기·서로 다른 estimate/inferred/관측 exact 간 교체는 거부(자동이 둘 중 하나를 고르지 않는다). 더 높은 수준으로의 승격은 이미 알려진 hard range 안에 있을 때만 허용 |

자동 거부 사유는 `rejectedProtectedUserAmount / rejectedWeakening / rejectedInconsistent / rejectedCurrencyMismatch`로 구분되어 상위 계층이 설명할 수 있다. 정산이 자동으로 만든 값은 항상 `inferred`이며 `exact`로 기록되지 않는다(`automatedPromotionMustBeInferred`).

### 불확실성을 잃지 않는 집계 (`AmountAggregate`)

exact 합계, inferred 합계, estimated 합계(soft)를 따로 보관하고, **하한**(hard 지식만: exact·inferred·range 최소)과 **상한**(unknown·estimated가 있으면 `nil`), 미해결 구성요소 수를 낸다. 예: 외식 120,000~130,000 + 카페 42,000~49,000 → 하한 162,000, 상한 179,000, 미해결 2개. 타임라인의 활동 블록 합계와 `DaySummary`가 이를 사용한다.

## 5. 거래 분할 (`TransactionAllocation`)

```text
Transaction ── TransactionAllocation(id, transactionID, activityID?, amount: AmountEntry, provenance, createdAt) ── Activity
```

- 한 거래를 여러 활동에, 한 활동에 여러 거래의 부분을. `activityID == nil`은 **"이 부분은 활동 외 소비"라는 결정**이며, 아직 배분하지 않은 금액(**remainder**)과 구별된다.
- 거래의 총액·흐름(spend/refund)은 첫 배분 시 고정되고(원장은 불변) 이후 어긋나면 거부한다. 환불은 별도 거래이며 자기 배분을 가진다.
- 거래 시각이 활동 시간 범위 안일 필요가 없다. 영화표·KTX·참가비·사전 예매 모두 연결 가능(시간을 검증하는 코드가 없다).

**강제되는 불변식**: 배분 하한의 합 ≤ 거래 총액(range는 최소값으로 계산). 거래당 활동별 배분은 1개(명시적 "활동 없음"도 1개). 통화 일치. 배분은 활동/거래를 바꾸지 못한다(id 고정). 자동은 사용자 배분을 교체·삭제하지 못한다. 그룹 제약을 깨는 금액 변경은 거부. `remainder`는 `AmountBounds`(unknown/range 배분이 있으면 넓어짐), `knownRemainderMinorUnits`는 모든 배분이 확정일 때만 값을 가진다.

## 6. 합계만 아는 구성요소 (`AmountGroup`)

예: 데이트 정산 총액 31,000 = 점심 + 카페 + 택시, 각 금액은 모름. **개별 금액을 임의로 정하지 않고 "합이 31,000"이라는 제약 자체를 보존한다.**

- 구성: `AmountGroup(total: 확정 지식(exact/inferred), members: [obligation | allocation])`. 멤버는 한 그룹에만 속하고 통화가 같아야 한다. 정의 시점에 이미 불가능한 제약이면 거부.
- 분석(`AmountGroupSolver`, 순수): `satisfied` / `uniqueSolution`(미해결이 **정확히 하나**) / `underdetermined`(여러 개: 제약에서만 유도한 멤버별 범위 `narrowed`를 제공, **값은 고르지 않는다**) / `contradiction`.
- 새 evidence가 오면 점진적으로 좁혀진다: 점심 12,000 확정 → 아직 모호(남은 19,000) → 카페 7,000 확정 → 택시 12,000이 유일해(`resolveAmountGroup` command가 `inferred`로 승격).
- 사용자가 구성요소를 직접 입력하면 항상 우선하며, 제약을 깨는 입력은 `amountGroupContradiction`으로 거부된다.

## 7. Obligation / Settlement

> **Transaction = 실제 발생한 돈의 이동. Obligation = 아직 정리되어야 하는 경제적 관계.**

- `Obligation`(counterpartyID, activityID?, direction `payable/receivable`, `AmountEntry`, status `open/partiallySettled/settled/cancelled`, originTransactionID?, label?). 거래가 없어도 존재한다(상대가 점심을 결제 → 내가 줄 돈). 상태는 settlement에서 **유도**된다(직접 설정하지 못함; `cancelled`만 명시).
- `Person`: OnAll 계정과 무관한 안정 ID. `externalIdentity`는 저장만 하고 해석하지 않는다. 상대가 OnAll을 쓰지 않아도 모든 기능이 동작한다. 정산 상대가 본인(self)일 수 없다.
- `SettlementRequest`: OnAll이 사용자를 위해 만든 정산 요청 **기록**(전송·수신 없음). 포함한 obligation이 모두 settled/cancelled가 되면 어떤 settlement로 끝났든 `fulfilled`.
- `Settlement`: 실제 송금(`ActualTransfer`) 1건이 여러 obligation에 `SettlementAllocation(appliedMinorUnits)`로 적용된다. 하나의 obligation은 여러 settlement로 **부분 정산**될 수 있다.
  **net 불변식**: 적용 금액의 부호 합(받을 돈 +, 줄 돈 −)이 부호 있는 송금액과 정확히 같아야 한다. 상계(여러 obligation, 양방향)는 이 하나의 규칙으로 표현된다.
  settlement가 알게 해 준 금액은 `AppliedPromotion(previous, applied)`로 기록되어, settlement를 제거하면 근거를 잃은 inferred가 이전 지식으로 **되돌아간다**.

### 매처 (`SettlementMatcher`, 순수·결정적)

전제: 설명의 단위는 같은 상대·같은 통화의 **열린 obligation 부분집합**이다. 정산 대상(known)은 남은 금액 = 금액 − 이미 적용된 금액, unknown/range/estimated는 남은 범위의 구간으로 다룬다.

1. 모든 (known 부분집합 × unknown 부분집합)을 열거해 `Σ 부호·금액 = 송금액`을 만족하는 **설명**을 찾는다. unknown이 하나면 값이 강제되고(범위 안이어야 함), 둘 이상이면 합계만 정해지는 **미결정 설명**이다.
2. 설명이 **정확히 하나**일 때만 확정 결과를 낸다. 여럿이면 요청(request)이 포함하는 설명만 남겨 다시 본다(요청은 이미 맞는 설명들 중 **고르는 근거**일 뿐 숫자가 말하는 것을 뒤집지 않는다). 그래도 여럿이면 `ambiguous`.
3. 결과 타입: `exactMatch`(단일 obligation. 요청이 그 금액을 명시하면 **부분 정산**도 가능) / `netMatch`(여러·양방향) / `inferredUniqueSolution`(unknown 하나 확정) / `ambiguous`(대안 목록, 합계 제약) / `insufficientEvidence`(부분 정산 가능성, 후보 과다) / `noMatch`(열린 obligation 없음, 설명 불가, 이미 정산된 송금).
4. 한계: 열린 obligation이 known 12개·unknown 6개를 넘으면 추측하지 않고 `insufficientEvidence`.

**실제 예제**(모두 테스트로 증명):

| 상황 | 결과 |
|---|---|
| 받을 돈 30,000 + 줄 돈 12,000, 입금 18,000 | `netMatch` — 두 obligation 함께 정리(**B**) |
| 받을 돈 30,000(확정) + 줄 돈 미상, 입금 18,000 | `inferredUniqueSolution` — 줄 돈 = `inferred(12,000)`, settled |
| 받을 돈 30,000 + 줄 돈 X·Y(미상), 입금 18,000 | `ambiguous` + 제약 "X+Y=12,000". **자동 exact 없음**(**C**). 제약은 `AmountGroup`으로 보존 가능 → 사용자가 X=5,000을 알게 되면 Y=7,000이 유일해짐 |
| 받을 돈 30,000만 있고 입금 18,000 | `insufficientEvidence(possiblePartialSettlement)` — 실패로 단정하지도, 부분 정산으로 단정하지도 않는다 |
| 위 + 요청이 "10,000원" 명시 | `exactMatch(isPartial)`, 이후 20,000 입금은 같은 obligation의 나머지를 정산 |
| 점심(미상, 줄 돈) + 영화 7,000(받을 돈) + 카페 6,000(줄 돈), 내가 5,000 송금 (**A**) | 요청 없이는 설명 3개 → `ambiguous`. 세 obligation을 모두 포함한 요청이 있으면 `inferredUniqueSolution` — 점심 = `inferred(6,000)` |

모호한 경우 사용자는 `recordManualSettlement`로 직접 결정하며 `confirmedAmounts`는 **exact**로 기록된다.

## 8. 참여자와 친밀도

- `Activity.participants: [ParticipantAssignment(personID, provenance)]`. Calendar attendee와 `Person`은 동일하다고 가정하지 않는다(어댑터가 매핑).
- obligation/정산 상대 후보로 활동 참여자를 우선 쓸 수 있도록 core가 막지 않는다(UI 추천은 미구현).
- `ParticipantAffinityCalculator`(순수): 본인을 제외한 참여자가 2명 이상인 활동마다 각 쌍에 `1/(n−1) × 0.5^(경과일/반감기(기본 180일))`를 더한다. **인원이 많을수록 신호가 약해지므로** 3명 식사 8회가 30명 수업 8회보다 약 14배 크다. 출력은 쌍별 `coOccurrenceCount`(원 횟수), `weightedScore`, 마지막 함께한 시각, 함께한 활동 유형 분포. `recommend(given:)`는 이미 고른 사람과의 쌍 점수 합으로 후보를 순위화한다(동점은 ID 순, 선택된 사람·본인 제외, 함께한 적 없으면 추천 안 함).
- **관계 label(친구·연인·가족)은 추론하지 않는다.** `Person.relationshipLabel`은 사용자 provenance로만 설정되며 자동 provenance는 `relationshipLabelRequiresUser`로 거부된다. 저장되는 객관 사실은 "자주 함께 등장했다"뿐이다.

## 9. 타임라인 read model 변경

`EventBlock`/`AllDayItem`은 `allocations: [AllocationItem]`(거래 총액, **배분 금액 지식**, 부분 여부, 당일 여부, 출처)과 `allocatedSpend/allocatedRefunds: [AmountAggregate]`를 가진다. 이틀 전에 산 영화표의 배분은 오늘 데이트 블록 안에 보인다. `ActivityBadge`는 참여자와 미정산 obligation 수를 포함한다.
`TransactionMarkerItem`은 오늘 거래 중 보이는 활동 블록 안에서 **완전히 설명되지 않은** 것만 표시하며 `allocations`(어디로 얼마), `remainder`(남은 금액 구간), `isFullyAllocated`를 가진다. 빈 `allocations`는 오류가 아니라 정상 상태(활동 외 소비)다.
`DaySummary.totals`는 통화별로 **linked(활동에 확정 배분) / unlinked(확정 활동 외: 명시적 활동 없음 + 배분 안 된 나머지) / uncertain(금액 미확정 배분 때문에 위치를 모르는 부분)**을 나눠 순지출(환불 차감)로 낸다.

## 10. 핵심 불변식과 증명 테스트

| 불변식 | 증명 |
|---|---|
| 한 거래를 여러 활동에 분할, 한 활동에 여러 거래의 부분 | `oneTransferCanBeSplitAcrossSeveralActivities`, `oneActivityCanHoldPortionsOfManyTransactions`, `scenarioD_oneTransferIsSplitAcrossThreeActivitiesThroughTheService` |
| 부분 배분과 remainder 표현 | `aTransactionCanBeOnlyPartlyAllocatedAndTheRestIsRepresentable`, `scenarioE_aPartialAllocationLeavesTheRestUnallocated` |
| 배분 합은 거래 총액을 넘지 못함, 총액 고정 | `theAllocatedAmountsCanNeverExceedTheTransaction`, `theTransactionTotalCannotChangeBetweenAllocations`, `exceedingTheTransactionIsRejectedAndNothingChanges` |
| 거래 시각과 활동 시간은 무관 | `anAllocationNeedsNoTimeContainmentAndTheTotalCannotBeExceeded`, `theTransactionTimeNeedNotLieInsideTheActivity`, `aTransactionBoughtDaysBeforeTheEventCanStillBeLinkedToIt` |
| unknown/range 배분이 remainder를 넓힌다 | `aPortionMayBeUnknownAndTheRemainderWidensAccordingly`, `rangesNarrowTheRemainderFromBothSides` |
| inferred는 exact가 아니다 | `onlyExactAndInferredAreSettledAndTheyAreNeverTheSame`, `aggregatesKeepExactInferredAndEstimatedApart`, `anInferredAllocationKeepsItsEvidenceLevelInTheReadModel` |
| 자동은 사용자 exact를 덮어쓰지 못하고 지식을 약화하지 못함 | `automationNeverOverwritesAUserConfirmedExactAmount`, `automationCannotWeakenWhatIsKnown`, `automationMayNarrowARangeButNeverWidenIt`, `anAutomaticInferenceCanPromoteButNeverOverwriteAUserConfirmedAmount` |
| 불확실성이 집계에서 사라지지 않음 | `rangesProduceALowerAndUpperBoundInsteadOfAFalseTotal`, `anUnknownPortionIsReportedAsUncertainNotAsAGuess` |
| 합계 제약 보존, 해가 여럿이면 선택하지 않음, 하나면 승격 | `theSumIsPreservedInsteadOfSplittingUnknownMembersArbitrarily`, `twoUnresolvedMembersAreStillAmbiguousEvenWhenTheTotalIsFixed`, `exactlyOneUnresolvedMemberIsForced`, `aDateSettlementKeepsItsTotalWhileTheSharesAreStillUnknown` |
| "복합"은 category가 아님 | `theCompositeIsAnUnresolvedStateNeverACategory` |
| obligation은 거래·계정 없이 존재 | `anObligationExistsWithNoTransactionAndNoOnAllAccount` |
| 상계 정산(양방향 net) | `scenarioB_aNetTransferSettlesBothDirectionsAtOnce`, `aSettlementMustNetExactlyToTheTransfer`, `oneTransferCanResolveSeveralObligations` |
| 유일하면 inferred, 여럿이면 모호 | `scenarioB2_oneUnknownPayableIsInferredFromTheNet`, `scenarioC_severalUnknownsOnlyYieldAConstraintNeverAnAutomaticSplit`, `twoObligationsOfTheSameAmountAreAmbiguousNotArbitrarilyPicked`, `anAmbiguousMatchIsNeverAppliedAutomaticallyButTheUserCanDecide` |
| 요청은 근거이지 override가 아님 | `aSettlementRequestIsEvidenceThatBreaksAnOtherwiseTiedMatch`, `aRequestNeverOverridesWhatTheNumbersSayWhenTheyAreUnambiguous`, `theRequestedAmountMinusARelatedPayableExplainsTheDeposit` |
| 부분 정산, 한 obligation의 여러 settlement | `aSmallerTransferIsPossiblyPartialButNotAssumedWithoutEvidence`, `aRequestForThatAmountMakesAPartialSettlementTheEvidencedExplanation` |
| 자동 승격은 inferred만, settlement 제거 시 되돌림 | `anAutomatedPromotionMustBeInferredNeverExact`, `removingASettlementUndoesItsStatusesInferencesAndRequest` |
| 시나리오 A(데이트 정산)와 참여자 | `scenarioA_aDateSettlementInfersTheLunchShareWhenARequestCoversEverything`, `scenarioA_aDateIsSettledAndTheLunchShareIsInferredFromTheRequest` |
| 참여자 추천: 소규모 반복 > 대규모, 관계 추론 금지 | `scenarioF_smallRepeatedGroupsOutrankLargeGroupOnlyPeople`, `threePeopleDiningEightTimesBeatThirtyPeopleInEightLectures`, `relationshipLabelsExistOnlyWhenTheUserStatesThem`, `affinityNeverInventsARelationshipLabel` |
| 타임라인에서 분할·불확실 표시 | `aSplitTransactionShowsItsPortionInsideTheBlockAndKeepsAMarkerForTheRest` |
| 이전 불변식(캘린더·활동·provenance·일관성)은 유지 | 기존 153개 테스트(새 모델로 이전·통과) |

## 11. 일관성 (구현된 것)

쓰기 순서: 캘린더 provider 먼저, 로컬 나중. provider 실패 시 로컬 변경 없음, 로컬 실패 시 `partiallyApplied`. 금액·배분·정산·참여자 command는 provider를 쓰지 않으며 `LifeState.applying`이 all-or-nothing이다(예: 한 command 안의 일부 변경이 실패하면 지연 생성된 활동도 남지 않는다). 영구 실패는 `CommandRejection` 값이다.

## 12. 정책 요약

drag/resize(15분 snap, 줌 5분, 최소 15분, 겹침·자정 넘김 허용), `AssignmentPolicy`(자동은 신뢰도 ≥ 0.85, 사용자는 항상 허용), 매처 한계(known 12·unknown 6), 친밀도 반감기 180일은 모두 **초기 제안 값**이다.

## 13. Mac/Xcode·서버·외부 API가 있어야 하는 작업 (구현하지 않음)

| 항목 | 이유 |
|---|---|
| `EventKit` 기반 `CalendarProvider`, SwiftUI 타임라인·제스처, 캘린더 권한 | 플랫폼 API/UI |
| **EKEvent identifier 안정성, 반복 이벤트 scope 매핑**, 종일 종료일 관례, 변경 통지 | 실기기에서 확인 전에는 가정하지 않음(`CalendarEventID`는 불투명 토큰) |
| Contacts framework와 `Person` 연결(캘린더 attendee → `Person` 해석) | 플랫폼 API. `ExternalIdentity`는 저장만 한다 |
| SMS/메시지로 정산 요청 전송·수신 | 시스템 API. `SettlementRequest`는 기록만 |
| 송금/은행 API로 실제 송금 확인 | 외부 서비스. 송금은 이미 원장에 기록된 거래를 `ActualTransfer`로 넘겨받는다 |
| OnAll 계정/친구 서버, 공유 identity(`Person` ↔ OnAllUserID) | 서버. 이 단계에서 계정 시스템을 만들지 않음 |
| 위치/지오코딩(Area 자동 부여), LLM 분류, merchant 클라우드 DB | 외부 API |
| iPhone 실기기 성능·접근성 | 실기기 |

## 14. 의도적으로 구현하지 않은 것 (Mac과 무관)

command ID 멱등성, 앱 재시작 후 복구용 의도 로그, undo, 이벤트 ID 변경 시 재바인딩, 비선형 시간 축, category 저장소와 merchant 체인의 앞 단계, **다중 통화 정산·환산**(통화가 다르면 서로 후보가 아님), 한 transfer를 여러 상대에게 나누는 정산, 정산 송금이 원장에서 지출/이체/수입 중 무엇으로 분류되는지(예산 처리), durable 저장소, 친밀도 데이터의 캐시/증분 계산, 추천 UI.

## 15. 위험과 열린 질문

- **부분 정산**: 요청이 금액을 명시할 때만 자동 제안한다. 요청 없이 작은 입금이 오면 `insufficientEvidence`로 사람에게 넘긴다. 실제 사용에서 이 마찰이 큰지 확인이 필요하다.
- **다중 통화**: 매처는 같은 통화의 obligation만 후보로 삼는다. 환율 개입 정산은 모델링하지 않았다.
- **공유 OnAll 사용자 identity**: `Person`은 OnAll 계정과 독립이고 `ExternalIdentity`는 불투명하다. 양쪽이 OnAll을 쓸 때 obligation을 서로 대조하는 모델(상호 확인·충돌)은 없다.
- **여러 unknown 배분**: 합계 제약과 narrowing, 사용자의 수동 결정까지만 있다. 여러 unknown 사이의 자동 분배(예: 비율 가정)는 의도적으로 없다.
- **참여자 identity 해석**: 캘린더 attendee → `Person` 매핑이 틀리면 친밀도와 추천이 왜곡된다. 어댑터 설계 때 사용자 확인이 필요하다.
- **exact vs inferred 승격**: inferred를 사용자가 "맞다"고 확인하면 exact로 올리는 명시 경로는 `setObligationAmount`(사용자 provenance)뿐이다. 자동 경로에서는 절대 exact가 되지 않는다. 확인 UX(한 번 탭으로 승격)는 UI 설계 과제다.
- 매처는 **엄격한 유일성**을 쓴다(모든 부분집합이 후보). 실제 데이터에서는 모호 판정이 자주 나올 수 있고, 활동 단위 범위 지정이나 요청 같은 추가 evidence가 필요하다. 임계값(known 12·unknown 6)은 성능과 신뢰성을 위한 초기 값이다.
- 정산용 송금/입금이 가계부에서 소비·이체·수입 중 무엇으로 계산되어야 하는지(정산 입금은 지출의 반환인가)는 제품 결정이 필요하며 이 계층은 중립이다.
- `InMemoryCalendarProvider`는 계약 정의용이며 실제 캘린더와 같다고 주장하지 않는다.
