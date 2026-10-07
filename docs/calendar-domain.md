# Calendar / Activity / Semantic / Settlement 도메인

상태: **Windows에서 구현·검증된 플랫폼 독립 계층.** EventKit, SwiftUI, iOS 앱 target, 실기기·서버·외부 API가 필요한 것은 구현하지 않았고 §17에 모았다.
관련: 초기 설계 초안 [calendar-integration-design.md](calendar-integration-design.md)(구현 결정의 기준은 이 문서), 결정 기록 [decisions.md](decisions.md) D009(캘린더/활동), **D010(거래 분할·금액 지식·정산)**, **D011(정정·잔여·정책·공유 지출·소비 성격·카테고리 상태)**.

## 0. 아키텍처 원칙

> **OnAll은 불완전한 정보를 버리거나 억지로 확정하지 않는다. 알고 있는 수준 그대로 저장하고, 후속 evidence로 점진적으로 정밀하게 만든다.**
>
> **실제 송금액이 obligation과 다르다는 것은 정산 실패의 증거가 아니라, 다른 obligation이 상계되었을 가능성을 의미할 수 있다.**
>
> **유일하게 설명 가능한 경우에만 unknown 값을 자동으로 inferred 값으로 승격한다.**
>
> **사용자가 실수를 바로잡으면 OnAll은 원본 거래를 지우지 않고 정정된 경제적 의미를 사용한다.**
>
> **정산 금액과 실제 송금액의 차이는 별도의 residual로 보존하며, 의미가 확인되기 전까지 임의로 소비/선물/면제로 해석하지 않는다.**
>
> **Category와 Budget Nature는 별도 축이다. 무엇을 샀는지와 예산상 어떤 성격의 소비인지는 다르다.**
>
> **기타는 taxonomy의 한계이고, 모름은 정보의 한계다.**
>
> **차액은 먼저 미확정 금액을 설명하는 evidence로 사용하고, 설명할 미확정 정보가 더 이상 없을 때만 residual로 승격한다.**
>
> **하나의 경제적 금액은 한 분석 경로에서 두 번 집계되어서는 안 된다.** (§20)

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
| **Category** | 무엇에 돈을 썼는가 | canonical taxonomy | 흔하고 공통적 → 자동화 가능. **classified / other / unresolved / confirmedUnknown / unclassified** 4상태(§12) | `CanonicalCategoryID`, `CategoryAssignment` |
| **Spending Nature** | 예산 관점에서 어떤 소비인가 | **사용자**(기본값은 시스템 신호) | Category와 **독립**. 사용자 결정은 자동이 못 덮음(§12) | `SpendingNature`, `NatureTarget` |
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
  **net 불변식**: 적용 금액의 부호 합(받을 돈 +, 줄 돈 −)에 **명시된 초과분(surplus residual, §10)**을 더한 것이 부호 있는 송금액과 정확히 같아야 한다. 상계(여러 obligation, 양방향)는 이 하나의 규칙으로 표현된다. 초과분은 숨겨지지 않고 항상 기록으로 남는다.
  settlement가 알게 해 준 금액은 `AppliedPromotion(previous, applied)`로 기록되어, settlement를 제거하면 근거를 잃은 inferred가 이전 지식으로 **되돌아간다**.

### 매처 (`SettlementMatcher`, 순수·결정적)

전제: 설명의 단위는 같은 상대·같은 통화의 **열린 obligation 부분집합**이다. 정산 대상(known)은 남은 금액 = 금액 − 이미 적용된 금액, unknown/range/estimated는 남은 범위의 구간으로 다룬다.

1. 모든 (known 부분집합 × unknown 부분집합)을 열거해 `Σ 부호·금액 = 송금액`을 만족하는 **설명**을 찾는다. unknown이 하나면 값이 강제되고(범위 안이어야 함), 둘 이상이면 합계만 정해지는 **미결정 설명**이다.
2. 설명이 **정확히 하나**일 때만 확정 결과를 낸다. 여럿이면 요청(request)이 포함하는 설명만 남겨 다시 본다(요청은 이미 맞는 설명들 중 **고르는 근거**일 뿐 숫자가 말하는 것을 뒤집지 않는다). 그래도 여럿이면 `ambiguous`.
3. 결과 타입: `exactMatch`(단일 obligation. 요청이 그 금액을 명시하면 **의도된 부분 정산**도 가능) / `netMatch`(여러·양방향) / `inferredUniqueSolution`(unknown 하나 확정) / **`matchWithResidual`**(obligation은 설명되지만 송금은 남는다: 초과/부족을 **unresolved residual**로 보존, §10) / `ambiguous`(대안 목록, 합계 제약) / `insufficientEvidence`(후보 과다, 어느 obligation이 부족한지 단정 불가) / `noMatch`(열린 obligation 없음, 설명 불가, 이미 정산된 송금, **정정 그룹에 묶인 raw 거래**).
   정확한 설명이 없을 때만 residual을 제안한다. 같은 상대의 **정산 대상**(요청이 지정한 obligation, 없으면 열린 obligation 전부, 단 unknown이 없어야 함)을 정해 그 net과 송금액의 차이를 본다.
4. 한계: 열린 obligation이 known 12개·unknown 6개를 넘으면 추측하지 않고 `insufficientEvidence`.

**실제 예제**(모두 테스트로 증명):

| 상황 | 결과 |
|---|---|
| 받을 돈 30,000 + 줄 돈 12,000, 입금 18,000 | `netMatch` — 두 obligation 함께 정리(**B**) |
| 받을 돈 30,000(확정) + 줄 돈 미상, 입금 18,000 | `inferredUniqueSolution` — 줄 돈 = `inferred(12,000)`, settled |
| 받을 돈 30,000 + 줄 돈 X·Y(미상), 입금 18,000 | `ambiguous` + 제약 "X+Y=12,000". **자동 exact 없음**(**C**). 제약은 `AmountGroup`으로 보존 가능 → 사용자가 X=5,000을 알게 되면 Y=7,000이 유일해짐 |
| 받을 돈 30,000만 있고 입금 18,000 | `matchWithResidual` — 18,000 부분 정산 + 12,000 **unresolved shortfall**. 면제로 단정하지 않으며 obligation은 `partiallySettled` |
| 받을 돈이 둘(30,000, 40,000)이고 입금 18,000 | `insufficientEvidence` — 어느 쪽이 부족한지 모르므로 제안하지 않는다 |
| 위 + 요청이 "10,000원" 명시 | `exactMatch(isPartial)`, 이후 20,000 입금은 같은 obligation의 나머지를 정산 |
| 점심(미상, 줄 돈) + 영화 7,000(받을 돈) + 카페 6,000(줄 돈), 내가 5,000 송금 (**A**) | 요청 없이는 설명 3개 → `ambiguous`. 세 obligation을 모두 포함한 요청이 있으면 `inferredUniqueSolution` — 점심 = `inferred(6,000)` |

모호한 경우 사용자는 `recordManualSettlement`로 직접 결정하며 `confirmedAmounts`는 **exact**로 기록된다.

## 8. 참여자와 친밀도

- `Activity.participants: [ParticipantAssignment(personID, provenance)]`. Calendar attendee와 `Person`은 동일하다고 가정하지 않는다(어댑터가 매핑).
- obligation/정산 상대 후보로 활동 참여자를 우선 쓸 수 있도록 core가 막지 않는다(UI 추천은 미구현).
- `ParticipantAffinityCalculator`(순수): 본인을 제외한 참여자가 2명 이상인 활동마다 각 쌍에 `1/(n−1) × 0.5^(경과일/반감기(기본 180일))`를 더한다. **인원이 많을수록 신호가 약해지므로** 3명 식사 8회가 30명 수업 8회보다 약 14배 크다. 출력은 쌍별 `coOccurrenceCount`(원 횟수), `weightedScore`, 마지막 함께한 시각, 함께한 활동 유형 분포. `recommend(given:)`는 이미 고른 사람과의 쌍 점수 합으로 후보를 순위화한다(동점은 ID 순, 선택된 사람·본인 제외, 함께한 적 없으면 추천 안 함).
- **관계 label(친구·연인·가족)은 추론하지 않는다.** `Person.relationshipLabel`은 사용자 provenance로만 설정되며 자동 provenance는 `relationshipLabelRequiresUser`로 거부된다. 저장되는 객관 사실은 "자주 함께 등장했다"뿐이다.

## 9. 경제적 정정 (`TransactionCorrectionGroup`)

> **원장은 그대로, 의미만 정정한다.** 사용자가 잘못 보낸 송금(+12,000)을 일부 돌려받았다면(-4,000) 실제 경제적 효과는 +8,000이다. 이를 "실수"로 **판단하고 묶는 것은 사용자**다. OnAll이 +12,000과 -4,000을 스스로 상계해 실수라고 결론내지 않는다.

- `TransactionCorrectionGroup(id, sources, effectiveDirection, effectiveAmount, provenance, createdAt)`. `sources`는 원 거래를 `ActualTransfer` 사실로 그대로 담고(원장은 읽기 전용), **effective 값은 그 순합에서 유도**되므로 둘이 어긋날 수 없다. 정정은 묶고 상계할 수는 있지만 원장이 뒷받침하지 않는 금액을 선언할 수는 없다.
- **사용자 provenance로만** 생성·삭제된다(`correctionRequiresUser`, 자동 삭제는 `userAssignmentProtected`).
- 한 거래는 **하나의 그룹**에만 속한다(`transactionAlreadyCorrected`). 같은 상대·같은 통화·2건 이상이어야 하며(`CorrectionError`), effective transfer를 다른 그룹의 source로 쓸 수 없다.
- 이미 단독으로 정산된 거래는 묶을 수 없고(`correctionSourceAlreadySettled`), 정정에 근거한 settlement가 있으면 정정을 지울 수 없다(`correctionHasSettlement`). settlement를 먼저 되돌려야 한다.
- **effective view**: `effectiveTransfer`는 `coveredTransactionIDs`로 원 거래 전부를 가리키는 하나의 `ActualTransfer`다(순합이 0이면 `nil`: 정산할 것이 없다). 매처는 그룹에 묶인 raw 거래를 `noMatch(.partOfCorrectionGroup)`으로 거부하고 effective transfer만 정산 대상으로 본다. 정산 후에는 원 거래들이 모두 소진되어 다시 정산될 수 없다. `EffectiveTransfers.resolve(raw:in:)`/`netMinorUnits`는 분석이 같은 관점을 쓰도록 하는 순수 재계산 경로다.
- **되돌리기**: 그룹을 제거하면 raw 거래 의미가 그대로 돌아온다(원장은 한 번도 바뀌지 않았다).
- 정정은 **residual이 아니다.** 18,000을 받아야 하는데 20,000을 받았다고 해서 자동으로 "정정"이나 "실수"로 처리하지 않는다. 그 2,000은 residual로 남는다(§10).

예(시나리오 G): 받을 돈 8,000이 있을 때 raw +12,000은 4,000이 초과된 송금으로만 보인다. 사용자가 +12,000/-4,000을 묶으면 effective +8,000이 되어 8,000과 `exactMatch`로 정산된다.

## 10. 정산 잔여 (`SettlementResidual`)

> **실제 금액 ≠ obligation 금액은 정산 실패가 아니다.** 차이는 별도 기록으로 남고, 의미가 확인되기 전까지 `unresolved`다.

- `SettlementResidual(id, settlementID, obligationID?, amount, direction, classification: Assigned<…>, createdAt)`. 방향: **`surplus`**(obligation이 설명하는 것보다 더 많이 움직임, 예: 18,000 받을 것에 20,000 입금 → 2,000)와 **`shortfall`**(obligation이 요구한 것보다 적게 움직임, 예: 17,000 입금 → 1,000이 부족).
- 분류: `unresolved`(기본이며 자동이 저장할 수 있는 **유일한** 값) / `gift`(surplus만) / `waived`(shortfall만) / `otherObligation` / `roundingAdjustment` / `other`. 자동 provenance의 분류는 `automatedResidualClassification`으로 거부되고, 사용자 분류는 자동이 바꾸지 못한다. 방향에 맞지 않는 분류는 `residualClassificationNotApplicable`.
- **surplus**: 정산 대상 obligation은 모두 정산되고 남은 금액이 surplus가 된다. net 불변식은 `Σ 적용 + surplus = 송금액`. 초과 지급에서 20,000 전체를 정산으로 처리하지도, 정산 실패로 보지도 않는다(시나리오 H).
- **shortfall**: 부족분을 가진 obligation이 **하나로 특정될 때만** 제안한다(정산 대상이 한 건). 17,000은 부분 정산으로 적용되고 obligation은 `partiallySettled`로 남으며 1,000은 unresolved shortfall이다(시나리오 I). 어느 obligation이 부족한지 알 수 없으면(여러 건) `insufficientEvidence`.
- **효과**: 사용자가 shortfall을 `waived`/`roundingAdjustment`로 분류하면 그 금액이 obligation에서 **닫힌 것**으로 취급되어(`closedMinorUnits = 적용 + 닫힌 shortfall`) obligation이 `settled`가 되고 요청이 `fulfilled`된다. 다시 `unresolved`로 열면 되돌아온다. 다른 분류(`other` 등)는 닫지 않는다. 나중에 남은 1,000이 별도로 입금되면 정확히 매치되고 shortfall 질문은 사라진다(`unresolvedResiduals`에서 빠지고 기록은 남음).
- **분석에서 residual은 소비 증감으로 반영하지 않는다.** `ResidualSummary`가 별도로 집계하며 지출 분석(`SpendingAnalytics`)에는 들어가지 않는다. 독립적인 미설명 금액은 **surplus뿐**이다(`unresolvedSurplusMinorUnits`). shortfall은 obligation의 남은 금액을 가리키는 **참조**(`openShortfallReferenceMinorUnits`)이며 더하면 안 된다(§20.4).
- **residual은 마지막 수단이다.** 미확정(unknown/range/estimated) obligation이 하나라도 열려 있으면 차액은 그쪽의 evidence가 되고 residual도 residual 질문도 만들지 않는다(§20.1).
- settlement를 제거하면 그 residual도 함께 제거된다. residual ID는 settlement ID에서 결정적으로 만든다.

## 11. 정산 정책과 공유 지출 (`SettlementPolicy`, `ExpenseComponent`)

### raw share와 requested share

`ShareBreakdown`은 두 값을 모두 보존한다: **raw share**(그 사람의 실제 부담, 총액의 정확한 분할, 총액과 같은 지식 수준)와 **requested share**(관계의 반올림 습관을 적용해 실제로 요청한 금액 = obligation 금액). 차이는 정책 조정(요청 − raw)이며 **residual이 아니다**(§20.5). raw를 잃으면 분석이 왜곡되므로 obligation이 `share.rawShare`(settled이면 `rawShareMinorUnits`)를 기억한다(시나리오 J: raw 23,700 → 요청 23,000, 조정 -700).

- 반올림: `RoundingRule(mode: exact/floor/ceil/nearest, unit ≥ 1)`. `nearest`는 절반을 올림. 요청이 반올림된 사람 몫의 차이는 **지불자가 흡수**한다(`roundingAbsorbedByPayerMinorUnits`). 지불자 본인 몫은 반올림하지 않는다(자기에게 청구하지 않는다).
- 요청 금액이 0이 되면 obligation을 만들지 않고 `roundedToZero`로 보고한다(raw 몫은 그대로 보임).
- 분할: `SplitRule` = `equal`(남는 minor unit은 ID 순서가 앞선 사람부터 1씩) / `weights`(가중치 비례, 최대 잔여 방식으로 합이 총액과 정확히 같음) / `fixedAmounts`(지정된 사람은 고정액, 나머지를 균등 분할; 모두 고정이면 합이 총액과 같아야 함). 잘못된 입력은 추측 없이 `SettlementPolicyError`.

### 정책 우선순위 (약 → 강)

| 단계 | 저장 위치 | 담는 것 |
|---|---|---|
| 1. global 기본값 | `policyOverrides[.global]` (없으면 균등·반올림 없음) | 분할·반올림 |
| 2. **person** | `policyOverrides[.person(id)]` | **반올림만** (한 지출에는 여러 사람이 있으므로 person 정책의 `splitRule`은 `personPolicyCannotSetSplitRule`) |
| 3. **activity** | `policyOverrides[.activity(id)]` | 분할·반올림(그 활동의 기본값) |
| 4. **component** | `ExpenseComponent.policy` | 가장 구체적인 override |

필드별로 상속한다(`SettlementPolicyOverride`의 빈 필드는 위 단계 값을 따른다). 반올림은 "청구하는 사람"의 습관이 기준이라 내가 지불자면 상대 person 정책, 상대가 지불자면 그 사람의 정책을 쓴다. 정책은 **사용자 것**이라 자동 provenance로 설정·삭제할 수 없다(`policyRequiresUser`).

### 이벤트 기본 정산 + 세부 override

`ExpenseComponent`(activityID, amount: `AmountEntry`, payerID, participants?, excludedParticipants, policy?, category, originTransactionID?)는 Activity의 한 번에 정산되는 지출 조각이다(1차, 2차, 술).
- 참여자: `participants == nil`이면 Activity 참여자 **+ 나**, 목록이 있으면 그 목록을 대체, 그 뒤 `excludedParticipants`를 뺀다. (늦참: 2차는 `participants`로 A B C만 → D에게는 obligation이 생기지 않는다. 술 미참여: 술 component는 A B만 → C 없음. 또는 `fixedAmounts`로 C는 20,000 고정.)
- **obligation 생성** (`deriveObligations`/`generateObligations`): **나와 관련된 것만** 만든다. 내가 지불자면 각 참여자에 대한 받을 돈, 다른 사람이 지불했고 내가 참여자면 그 사람에 대한 줄 돈 하나, 나와 무관한 지출(남들끼리)은 없다. 총액의 불확실성은 **거부하지 않고 몫에 그대로 전파**한다: exact→exact, inferred→inferred, range→range(25,000~30,000), estimated→estimated, unknown→unknown(§20.2). 자동 정산 강도만 다르다. obligation은 `componentID`와 `share`로 출처를 추적한다.
- 한 component당 상대별 live obligation은 하나다(`duplicateComponentObligation`). 같은 총액으로 다시 생성하면 아무것도 바꾸지 않고, 더 정밀한 총액이면 기존 obligation을 갱신한다. obligation이 있는 동안 지불자·참여자·정책과 **확정된** 금액은 바꿀 수 없다(`componentHasObligations`: label/category는 가능). 아직 불확실한 총액(unknown/range/estimated)을 더 정밀하게 만드는 것은 허용된다. obligation을 취소하면 다시 바꿀 수 있다. 활동을 지우려면 component와 obligation이 없어야 한다.

## 12. Spending Nature와 Category 상태

### Spending Nature (Category와 별개 축)

`SpendingNature`: `living`(생활비) / `discretionary`(선택 소비) / `irregular`(비정기). 목적: 폰 구매 같은 비정기 대형 지출이 생활비 예산을 왜곡하지 않게 한다. MVP에 맞게 세 값만 둔다.

신호는 `LifeState.natureSignals[NatureTarget]`에 하나의 맵으로 저장한다(`NatureTarget`: allocation / transaction / component / activity / tag / activityType / category). 해석(`SpendingNatureResolver`)은 가장 **구체적인** 진술이 이긴다:

`allocation(또는 component) → transaction → activity → tag → activityType → category 기본값 → 없음`

- 아무도 진술하지 않으면 `unspecified`이며 **living으로 가정하지 않는다**.
- 같은 활동의 태그가 서로 다른 성격을 진술하면 태그 단계는 진술 없음으로 보고 다음 단계로 간다.
- 사용자 진술은 자동이 덮어쓰거나 지우지 못한다(`userAssignmentProtected`). 자동은 자기 이전 값만 바꿀 수 있다.
- 시나리오 M: Category = 식비 > 외식(기본 living), Activity = 제주 여행(irregular) → 그 식사는 **카테고리는 그대로** irregular로 집계되고, 평소 점심은 living으로 집계된다.
- 집계(`SpendingAnalytics`): `byNature`(생활/선택/비정기/미지정 각각 `AmountAggregate`, 불확실성 보존), 환불은 별도 flow로 섞지 않는다. 예: 총 1,500,000 = 생활 700,000 + 비정기 700,000 + 선택 100,000. component 기반 항목(`items(fromComponentsIn:)`)과 allocation 기반 항목을 한 분석에서 함께 쓸 때는 같은 비용을 두 번 세지 않도록 `items(unifiedIn:)`을 쓴다(§20.6).

### Category 상태 (`CategoryAssignment`)

| 상태 | 뜻 | 한계의 원인 | 예 |
|---|---|---|---|
| `classified(id, provenance)` | 무엇인지 알고 taxonomy에 맞는 category가 있음 | — | 식비 > 외식 |
| `other(provenance)` | 무엇인지 알지만 taxonomy에 맞는 category가 없음 | **taxonomy의 한계** | 매우 특이한 서비스 |
| `unresolved` | 정보가 부족해 아직 모름. **사용자에게 아직 묻지 않음** | **정보의 한계(아직)** | "김철수 18,000" 이유 모름 |
| `confirmedUnknown(provenance)` | 사용자에게 물었고 사용자가 "나도 모름"이라고 **확인함** | **사용자의 결정** | 가계부 차액 13,000, 영수증 없음 |
| `unclassified(reason)` | 정보는 충분하지만 시스템이 아직 정하지 못함 | **처리 대기** | merchant는 확실한데 분류 전 (`notYetEvaluated`/`ambiguous`) |

- 기타와 모름을 합치지 않는다. 동등성·직렬화·집계(`CategoryStateBreakdown`)에서 서로 섞이지 않는다(시나리오 N). 분석은 다섯 상태를 따로 본다.
- **누가 무엇을 하는가**: `unresolved`는 **사용자에게 질문할 가치**가 있다(`needsUserQuestion`). `unclassified`는 질문이 아니라 classifier/merchant resolution이 다시 처리할 일이다(`needsAutomatedRetry`, `classifierBacklog`). `confirmedUnknown`은 기본 review에서 **제외**되고 같은 evidence로 다시 묻지 않는다. `other`/`classified`는 완료다.
- `reviewQueue`는 `unresolved`를 먼저, 그다음 분류기가 충돌한 `unclassified(.ambiguous)`, 단순 대기 순으로 정렬한다. `confirmedUnknown`은 `evidenceVersions[item.id]`가 사용자가 확인한 evidence보다 **새로울 때만** 다시 나타난다. `userQuestions`는 큐 중 사용자에게 묻는 부분만 보여 준다.
- **confirmedUnknown의 provenance**: 사용자만 만들 수 있다(`confirmedUnknownRequiresUser`). 사용자가 본 evidence의 버전(`AssignmentProvenance.evidenceVersion`, 없으면 응답 시각)을 보존한다. 자동 classifier가 **같은 evidence로** 이를 `classified`로 덮어쓸 수 없고(`userAssignmentProtected`), 더 새로운 `evidenceVersion`을 명시한 제안만 재평가된다(영수증 발견 등). 사용자는 언제나 바꿀 수 있다. `confirmedUnknown`은 영구 불변이 아니라 "같은 질문을 다시 하지 않는 상태"다.
- 사용자 결정(어떤 상태든)은 자동이 덮어쓰지 못한다(위 `confirmedUnknown`의 새 evidence 경로 제외). 자동의 `unclassified`/`unresolved`는 시스템 상태라 사용자 결정을 대체할 수 없다(`CategoryAssignment.canReplace`).
- 분류기는 충분한 evidence 없이 `confirmedUnknown`을 `classified`로 강제하지 않는다: `AssignmentPolicy.classification(proposing:provenance:replacing:)`는 제안 provenance의 `evidenceVersion`이 확인 시점보다 새롭지 않으면 신뢰도가 높아도 그대로 둔다. 신뢰도가 임계값 미만이면 evidence가 새로워도 category가 되지 않는다.
- **금액 불확실성과 category 불확실성은 별도 축**이다. `amount = exact, category = confirmedUnknown`도, `amount = unknown, category = classified(식비 > 카페)`도 표현된다. 카테고리는 `TransactionAllocation.category`와 `ExpenseComponent.category`에 있다.

## 13. 타임라인 read model 변경

`EventBlock`/`AllDayItem`은 `allocations: [AllocationItem]`(거래 총액, **배분 금액 지식**, 부분 여부, 당일 여부, 출처)과 `allocatedSpend/allocatedRefunds: [AmountAggregate]`를 가진다. 이틀 전에 산 영화표의 배분은 오늘 데이트 블록 안에 보인다. `ActivityBadge`는 참여자와 미정산 obligation 수를 포함한다.
`TransactionMarkerItem`은 오늘 거래 중 보이는 활동 블록 안에서 **완전히 설명되지 않은** 것만 표시하며 `allocations`(어디로 얼마), `remainder`(남은 금액 구간), `isFullyAllocated`를 가진다. 빈 `allocations`는 오류가 아니라 정상 상태(활동 외 소비)다.
`DaySummary.totals`는 통화별로 **linked(활동에 확정 배분) / unlinked(확정 활동 외: 명시적 활동 없음 + 배분 안 된 나머지) / uncertain(금액 미확정 배분 때문에 위치를 모르는 부분)**을 나눠 순지출(환불 차감)로 낸다.

## 14. 핵심 불변식과 증명 테스트

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
| 부분 정산, 한 obligation의 여러 settlement | `aSmallerTransferIsAPartialSettlementWithAnUnresolvedShortfallNeverAWaiver`, `withSeveralOpenObligationsAShortTransferCannotSayWhichOneIsShort`, `aRequestForThatAmountMakesAPartialSettlementTheEvidencedExplanation` |
| 자동 승격은 inferred만, settlement 제거 시 되돌림 | `anAutomatedPromotionMustBeInferredNeverExact`, `removingASettlementUndoesItsStatusesInferencesAndRequest` |
| 시나리오 A(데이트 정산)와 참여자 | `scenarioA_aDateSettlementInfersTheLunchShareWhenARequestCoversEverything`, `scenarioA_aDateIsSettledAndTheLunchShareIsInferredFromTheRequest` |
| 참여자 추천: 소규모 반복 > 대규모, 관계 추론 금지 | `scenarioF_smallRepeatedGroupsOutrankLargeGroupOnlyPeople`, `threePeopleDiningEightTimesBeatThirtyPeopleInEightLectures`, `relationshipLabelsExistOnlyWhenTheUserStatesThem`, `affinityNeverInventsARelationshipLabel` |
| 타임라인에서 분할·불확실 표시 | `aSplitTransactionShowsItsPortionInsideTheBlockAndKeepsAMarkerForTheRest` |
| **G** 잘못 송금 후 반환 → 사용자 정정 → effective +8,000으로 정산, raw는 그대로 | `scenarioGWrongTransferThenPartialReturnBecomesEffectivePlus8000`, `scenarioGEndToEndThroughTheService`, `theEffectiveViewReplacesRawTransfersAndRemovingTheCorrectionRestoresThem` |
| 정정은 사용자만, 한 거래는 한 그룹, 정산 중인 정정은 삭제 불가, 위조된 effective 거부 | `aCorrectionCanOnlyBeMadeByTheUser`, `aTransactionCannotBelongToTwoCorrectionGroups`, `aCorrectionThatAlreadySettledSomethingCannotBeRemovedSilently`, `theStateEnforcesTheCorrectionRulesEvenForHandBuiltSettlements`, `aCorrectionThatNetsToZeroLeavesNothingToSettle` |
| residual은 정정이 아님 | `residualsAreNotCorrections` |
| **H** 초과 지급 → 정산 + unresolved surplus, 자동 gift 금지 | `scenarioHOverpaymentSettlesTheObligationAndKeepsAnUnresolvedSurplus`, `automationCanNeverClassifyAResidualButTheUserCan`, `scenarioHEndToEndOverpaymentStaysUnresolvedUntilTheUserSaysWhat` |
| **I** 부족 지급 → 부분 정산 + unresolved shortfall, 자동 waive 금지 | `scenarioIShortPaymentIsAPartialSettlementWithAnUnresolvedRemainder`, `onlyTheUserCanWaiveOrRoundAwayAShortfall`, `scenarioIEndToEndAShortfallKeepsTheRequestOpenUntilTheUserWaivesIt` |
| residual 정합성(net, shortfall 금액), 요청 기반 정산 대상 | `theSettlementRecordRefusesResidualsThatDoNotAddUp`, `aRequestNamesWhatTheTransferIsAboutSoTheSurplusIsUnambiguous`, `aShortTransferForSeveralNamedObligationsDoesNotGuessWhichIsShort` |
| **J** 사람별 내림: raw와 requested 모두 보존 | `scenarioJRawShareAndRequestedShareAreBothKept`, `theObligationRemembersTheRawShareSoAnalysisIsNotDistorted` |
| 반올림·분할 산술(합이 총액과 같음) | `roundingModesBehaveAsHabitsDo`, `anEqualSplitNeverLosesAMinorUnit`, `weightedSplitsUseTheLargestRemainder`, `fixedAmountsTakeTheirShareAndTheRestIsSplitEqually` |
| 정책 우선순위(global→person→activity→component), 사용자만 설정 | `policiesResolveFromGlobalThroughPersonAndActivityToTheComponent`, `aPersonPolicyCarriesRoundingOnlyAndEverythingElseIsTheUsersDecision` |
| **K** 늦참 → 2차 obligation 없음 | `scenarioKTheLateComerOwesNothingForTheSecondRound`, `theParticipantListIsInheritedUntilTheComponentStatesItsOwn` |
| **L** 술 미참여 → alcohol obligation 없음 / 고정 20,000 | `scenarioLTheNonDrinkerHasNoAlcoholObligation`, `scenarioLAlternativeAFixedAmountForTheOneWhoDidNotDrink` |
| component → obligation 규칙(나와 관련된 것만, 총액의 불확실성은 몫에 전파, 중복 금지) | `whenSomeoneElsePaidIOweThemMyShareOnly`, `expensesBetweenOtherPeopleCreateNothingForMe`, `anUnsettledTotalIsCarriedIntoObligationsNeverGuessedAsExact`, `sharesOfAnInferredTotalAreInferredNotExact`, `obligationsAreCreatedOncePerComponentAndCounterparty` |
| **M** 여행 식사는 irregular, 카테고리는 그대로 | `scenarioMATripMealKeepsItsCategoryButCountsAsIrregular`, `theLivingBudgetIsNotDistortedByOneBigPurchase`, `natureIsResolvedFromTheMostSpecificStatement` |
| 성격 미진술은 unspecified, 사용자 성격은 자동이 못 덮음 | `nothingStatedMeansUnspecifiedNeverLiving`, `aUserNatureIsNeverOverwrittenByAutomation`, `tagsThatDisagreeCountAsNoStatement` |
| **N** category 5상태가 섞이지 않음(동등성·직렬화·집계) | `scenarioNTheFiveCategoryStatesAreDistinct`, `scenarioNAnalyticsReportTheFiveStatesSeparately`, `complexIsNotACategory` |
| 금액 불확실성과 category 불확실성은 독립 | `amountUncertaintyAndCategoryUncertaintyAreIndependentAxes`, `uncertainAmountsStayUncertainInTheNatureBreakdown` |
| category 덮어쓰기 보호, unknown을 근거 없이 classified로 강제하지 않음 | `aUserCategoryDecisionOfAnyKindIsNeverOverwrittenByAutomation`, `aClassifierCannotTurnLackOfInformationIntoACategoryByBeingConfident`, `allocationUpsertsCannotSneakPastACategoryProtection` |
| **O** unknown이 차액을 소비하면 residual 없음 | `scenarioOUnknownObligationConsumesTheDifferenceAndLeavesNoResidual` |
| **P** unknown 여럿은 constraint만 남기고 residual·질문 없음 | `scenarioPSeveralUnknownsKeepAConstraintAndNeverCreateAResidualQuestion`, `anOpenUnknownNeverLetsADifferenceBecomeAResidualEvenWithARequest`, `theStateRefusesAnAutomatedResidualWhileAnUncertainObligationIsOpen` |
| **Q** range 총액 → range 몫, 불확실성 전파, 자동 강도 | `scenarioQARangeTotalGivesARangeObligation`, `uncertaintyIsPropagatedFromTheTotalToTheShareAtTheSameLevel`, `aRangeShareBoundsHoldForWeightedAndFixedSplitsAndRounding`, `aRangeObligationIsOnlyEverInferredNeverExactBySettlement`, `anEstimateIsASoftHintNeverAHardBoundOrAnExactMatch`, `aSharperTotalRefinesRangeObligationsInsteadOfDuplicatingThem` |
| **R** shortfall은 이중 집계되지 않음(남은 금액의 참조) | `scenarioRExactShortfallIsSettledPlusRemainingAndNotCountedTwice`, `aLaterPaymentRetiresTheShortfallReferenceInsteadOfLeavingStaleMoney`, `originalEqualsSettledPlusWaivedPlusRemainingAndSurplusIsNotSymmetricWithShortfall`, `aCancelledObligationKeepsItsAmountAccountedFor` |
| **S/T** raw → 조정 → 요청 → 실제 → residual 단계 분리 | `scenarioSRoundingPolicyNeverBecomesAResidual`, `scenarioTRoundingPlusAnActualShortfallLeavesOnlyTheUnexplainedThousand`, `anActualAboveTheRequestedAmountIsASurplusOfOnlyTheExcess`, `nettingWithPerPersonRoundingLeavesNoResidualEvenThoughRawSharesDiffer`, `componentRoundingAndDifferentPersonPoliciesEachKeepTheirOwnAdjustment` |
| **U** 요청 30,000에 50,000 입금: 정산 30,000 + surplus 20,000 | `scenarioUParentOverpaymentSplitsIntoSettlementAndUnresolvedSurplus` |
| 한 거래는 한 경제적 역할(정산 송금 ↔ 소비) | `aSettlementTransferCannotAlsoBeAllocatedAsSpendingOrARefund`, `aCorrectedRawTransferCannotBeAllocatedAsSpendingEither`, `aComponentThatMirrorsAnAllocatedTransactionIsCountedOnlyOnce`, `reimbursementObligationsNeverReduceTheOriginalSpending` |
| 돈 보존: 정정 effective = raw 부호 합, settlement·obligation 장부 균형 | `aCorrectionsEffectiveAmountIsTheSignedSumOfItsRawMembersAndConservesMoney`, `everySettlementKeepsTheTransferAndTheObligationBooksBalancedAcrossManyShapes` |
| **V** unresolved → confirmedUnknown, 기본 review 제외 | `scenarioVUnresolvedBecomesConfirmedUnknownAndLeavesTheDefaultReview`, `unresolvedAndConfirmedUnknownAreDistinctFromUnclassifiedAndOther` |
| **W** confirmedUnknown은 새 evidence로만 재평가 | `scenarioWConfirmedUnknownIsReopenedOnlyByNewEvidence`, `aClassifierCannotTurnLackOfInformationIntoACategoryByBeingConfident` |
| 이전 불변식(캘린더·활동·provenance·일관성)은 유지 | 기존 테스트(새 모델로 이전·통과) |

## 15. 일관성 (구현된 것)

쓰기 순서: 캘린더 provider 먼저, 로컬 나중. provider 실패 시 로컬 변경 없음, 로컬 실패 시 `partiallyApplied`. 금액·배분·정산·참여자 command는 provider를 쓰지 않으며 `LifeState.applying`이 all-or-nothing이다(예: 한 command 안의 일부 변경이 실패하면 지연 생성된 활동도 남지 않는다). 영구 실패는 `CommandRejection` 값이다.

## 16. 정책 요약

drag/resize(15분 snap, 줌 5분, 최소 15분, 겹침·자정 넘김 허용), `AssignmentPolicy`(자동은 신뢰도 ≥ 0.85, 사용자는 항상 허용), 매처 한계(known 12·unknown 6), 친밀도 반감기 180일은 모두 **초기 제안 값**이다.

## 17. Mac/Xcode·서버·외부 API가 있어야 하는 작업 (구현하지 않음)

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

## 18. 의도적으로 구현하지 않은 것 (Mac과 무관)

command ID 멱등성, 앱 재시작 후 복구용 의도 로그, 일괄 undo(정정·정산을 한 번에 되돌리기), 이벤트 ID 변경 시 재바인딩, 비선형 시간 축, category 저장소와 merchant 체인의 앞 단계, **다중 통화 정산·환산**(통화가 다르면 서로 후보가 아님), 한 transfer를 여러 상대에게 나누는 정산, 정산 송금·residual이 원장에서 지출/이체/수입/선물 중 무엇으로 분류되는지(예산 처리), 예산 엔진 자체(성격별 한도·상각·이월), 카테고리별·활동 유형별 기본 성격 데이터, 한 component를 여러 통화로 나누는 지출, durable 저장소, 친밀도 데이터의 캐시/증분 계산, 추천 UI.

## 19. 위험과 열린 질문

- **부분 정산**: 요청이 금액을 명시하면 의도된 부분 정산으로, 요청 없이 열린 obligation이 **하나뿐**인데 더 적게 들어오면 부분 정산 + unresolved shortfall로 제안한다. 열린 obligation이 여럿이면 어느 것이 부족한지 몰라 제안하지 않는다. 이 경계가 실제 사용에서 적절한지 확인이 필요하다.
- **Residual UX**: unresolved residual이 쌓이면 사용자에게 부담이다. 언제·어떻게 묻고 어떻게 한 번에 정리할지(일괄 분류, 알림 빈도, 오래된 surplus 처리)는 UI 설계 과제이며, 도메인은 `unresolvedResiduals`/`ResidualSummary`만 제공한다.
- **정정 되돌리기**: 정정 그룹은 지울 수 있지만, 그 정정에 근거한 settlement가 있으면 settlement를 먼저 되돌려야 한다. 한 번에 되돌리는 undo는 없다. 또한 정정은 원장이 뒷받침하는 net만 표현하므로 "이 거래는 정산과 무관하다"처럼 금액을 바꾸는 정정은 모델링하지 않는다.
- **waive/gift 의미**: `waived`는 shortfall을 닫고(obligation settled), `gift`는 surplus의 이름표일 뿐이다. 선물이 세금·증여·가계부 수입/지출에서 어떻게 보여야 하는지는 정하지 않았다. `otherObligation`은 어떤 obligation을 가리키는지까지는 연결하지 않는다.
- **반올림과 상계의 상호작용**: 반올림은 obligation 단위로 적용되므로 여러 obligation의 합을 한 번에 반올림한 값과 다를 수 있다. 상계 정산(양방향 net)은 반올림된 요청 금액을 기준으로 맞춘다. 사람이 net을 따로 반올림해 보내면 shortfall/surplus residual이 된다.
- **component override 복잡도**: 정책 4단계(global/person/activity/component)와 참여자 상속·제외·고정액이 겹치면 사용자가 결과를 예측하기 어렵다. 도메인은 계산 결과(`ComponentShares`, `previewObligations`)를 먼저 보여 줄 수 있게 했지만, 편집 UI에서의 이해 가능성은 검증이 필요하다. obligation이 생성된 뒤 component를 바꾸려면 obligation을 먼저 취소해야 한다.
- **예산 성격(SpendingNature) 기본값**: 카테고리별·활동 유형별 기본 성격은 아직 데이터가 없다(맵과 우선순위만 있음). `living/discretionary/irregular` 세 값이 충분한지, 월 단위 `irregular` 상각 같은 예산 엔진 요구가 모델을 바꾸는지는 예산 기능을 만들며 확인해야 한다.
- **레거시 거래 마이그레이션**: 이미 저장된 거래/링크/카테고리에는 성격·카테고리 5상태·정정이 없다. 모든 기존 분류는 `unclassified(.notYetEvaluated)`로 시작하고 성격은 `unspecified`다. 기존 `CategoryClassification.unclassified(.insufficientInformation)`이 있었다면 의미가 이제 `unknown`에 해당하므로 데이터가 생기기 전에 매핑 규칙(사용자 확인 후 `unknown`)이 필요하다. 영속 저장소가 없어 실제 마이그레이션 코드는 없다.
- **다중 통화**: 매처는 같은 통화의 obligation만 후보로 삼는다. 환율 개입 정산은 모델링하지 않았다.
- **공유 OnAll 사용자 identity**: `Person`은 OnAll 계정과 독립이고 `ExternalIdentity`는 불투명하다. 양쪽이 OnAll을 쓸 때 obligation을 서로 대조하는 모델(상호 확인·충돌)은 없다.
- **여러 unknown 배분**: 합계 제약과 narrowing, 사용자의 수동 결정까지만 있다. 여러 unknown 사이의 자동 분배(예: 비율 가정)는 의도적으로 없다.
- **참여자 identity 해석**: 캘린더 attendee → `Person` 매핑이 틀리면 친밀도와 추천이 왜곡된다. 어댑터 설계 때 사용자 확인이 필요하다.
- **exact vs inferred 승격**: inferred를 사용자가 "맞다"고 확인하면 exact로 올리는 명시 경로는 `setObligationAmount`(사용자 provenance)뿐이다. 자동 경로에서는 절대 exact가 되지 않는다. 확인 UX(한 번 탭으로 승격)는 UI 설계 과제다.
- 매처는 **엄격한 유일성**을 쓴다(모든 부분집합이 후보). 실제 데이터에서는 모호 판정이 자주 나올 수 있고, 활동 단위 범위 지정이나 요청 같은 추가 evidence가 필요하다. 임계값(known 12·unknown 6)은 성능과 신뢰성을 위한 초기 값이다.
- 정산용 송금/입금이 가계부에서 소비·이체·수입 중 무엇으로 계산되어야 하는지(정산 입금은 지출의 반환인가)는 제품 결정이 필요하며 이 계층은 중립이다.
- `InMemoryCalendarProvider`는 계약 정의용이며 실제 캘린더와 같다고 주장하지 않는다.

## 20. 머니 플로우 일관성 (uncertainty semantics와 보존 법칙)

이 절은 구현된 모델 사이의 돈 흐름(거래 → 정정 → 정산 → obligation → residual → 지출 분석)에서 같은 1원이 두 곳에 잡히거나, 불확실한 금액이 residual로 잘못 굳는 일을 막는 규칙이다.

### 20.1 차액은 evidence가 먼저, residual은 마지막

> **차액은 먼저 미확정 금액을 설명하는 evidence로 사용하고, 설명할 미확정 정보가 더 이상 없을 때만 residual로 승격한다.**

매처의 처리 순서(`SettlementMatcher`):

1. exact / inferred obligation을 적용한다(확정 금액).
2. unknown / range / estimated obligation에 transfer 차액을 evidence로 적용한다(모든 부분집합을 열거).
3. 해가 **유일**하면 그 금액을 `inferred`로 승격한다(`inferredUniqueSolution`, 시나리오 O: payable 12,000).
4. 해가 **여럿**이면 constraint(`X + Y = 12,000`)·범위만 남기고 모호함을 그대로 보고한다(`ambiguous`, 시나리오 P). 아무것도 확정하지 않는다.
5. 열린 미확정 obligation이 하나라도 있는데 정확한 설명이 없으면 `insufficientEvidence(.unknownAmountsMayExplainDifference)`를 돌려준다. **residual도, "이 차액이 무엇인가요?"라는 질문도 만들지 않는다.** 요청(request)이 확정 obligation만 지목해도 같다.
6. 관련된 금액이 모두 확정되었는데도 설명되지 않는 금액이 남을 때만 `matchWithResidual`(surplus, 또는 대상이 하나로 특정될 때 shortfall)을 제안한다.

상태 수준의 가드: 자동 provenance의 settlement가 residual을 기록하려는데 같은 상대·통화에 미확정 obligation이 열려 있으면 `residualWhileUncertainObligationsOpen`으로 거부한다. 사용자는 알고 기록할 수 있다.

### 20.2 불확실성 전파와 자동화 강도

`ExpenseComponent` 총액의 지식 수준은 obligation 몫(그리고 `ShareBreakdown`의 raw share/total)에 그대로 전파된다.

| 총액 | 몫 | 자동 정산 강도 |
|---|---|---|
| exact | exact | 강함: `exactMatch`/`netMatch` |
| inferred | inferred | 강함 |
| range 50,000~60,000 (2인 균등) | range 25,000~30,000 | 후보/호환성만: 범위 안의 송금은 `inferred` 후보. **exact로 정산되지 않는다** |
| estimated 50,000 | estimated 25,000 | 후보만: 추정값은 hard bound도 매칭 근거도 아니다 |
| unknown | unknown | 금액 일치의 근거가 될 수 없다. 다른 금액이 확정될 때 유일해일 때만 forced inference |

range 몫의 경계는 equal/fixed는 구간 양 끝의 분할, weights(최대 잔여 방식은 총액에 단조가 아니다)는 비례 몫의 내림/올림으로 잡아 항상 가능한 모든 총액을 포함한다. 반올림은 양 끝에 같은 습관을 적용한다. 요청 상한이 0이면 obligation을 만들지 않는다. 총액이 나중에 정밀해지면(영수증) component 금액을 갱신한 뒤 `generateObligations`를 다시 호출해 기존 obligation을 갱신한다(중복 생성하지 않음). `shares(ofComponent:)`는 단일 분할이 있을 때만(exact/inferred/estimated) 값을 주고 range/unknown은 `totalNotKnown`이다.

### 20.3 raw → 조정 → 요청 → 실제 → residual

다섯 단계를 섞지 않는다. `ObligationBalance`가 obligation 하나의 모든 단계를 한 곳에 보여 준다.

| 단계 | 예 | 어디에 |
|---|---|---|
| raw economic share | 23,700 | `ShareBreakdown.rawShare` / `ObligationBalance.rawShareMinorUnits` |
| policy adjustment | −700 (floor 1,000) | `policyAdjustmentMinorUnits`. 사용자가 고른 정책의 결과이며 **residual이 아니다** |
| requested(original) | 23,000 | obligation 금액 |
| actual | 23,000 / 22,000 / 25,000 | `settledMinorUnits`(적용), surplus는 settlement |
| unexplained | 0 / 1,000 shortfall / 2,000 surplus | residual (요청 ≠ 실제일 때만, 20.1 이후) |

시나리오 S: raw 23,700 → 요청 23,000 → 실제 23,000 → residual 0. 시나리오 T: 실제 22,000 → 정책 조정 −700, 설명되지 않는 차이는 **1,000뿐**(1,700이 아니다). 실제 25,000이면 surplus 2,000(1,300이 아니다). 상계(양방향 net)는 반올림된 요청 금액을 기준으로 맞춘다. 사용자가 shortfall에 `roundingAdjustment`를 분류하는 것은 "그 차이를 사용자가 닫는다"는 사용자 결정(`waived`와 같은 효과)일 뿐 정책 조정이 아니다.

### 20.4 shortfall은 독립 금액이 아니라 obligation 잔액의 참조

```
Obligation   original 18,000   settled 17,000   remaining 1,000
Settlement   actual 17,000     shortfall reference = 1,000   (메타데이터)
```

- 항등식(금액이 확정된 obligation): `original = settled + waived + cancelled + remaining` (`ObligationBalance.isConserved`). `waived`는 사용자가 닫은 shortfall이다.
- shortfall 레코드는 위 식의 어느 항도 아니다. `ObligationBalance.openShortfallReferenceMinorUnits`와 `ResidualSummary.openShortfallReferenceMinorUnits`는 **remaining의 일부를 가리키는 참조**이며 remaining/outstanding에 더하지 않는다. 나머지가 나중에 입금되거나 닫히면 참조는 0이 된다(남은 금액을 넘지 않도록 잘린다). 이전 구현은 이미 갚은 shortfall을 요약에 계속 세었다(발견한 이중 집계).
- surplus는 대칭이 아니다. surplus는 어떤 obligation의 일부도 아닌 **실제로 더 움직인 돈**이라 독립 residual이며(`unresolvedSurplusMinorUnits`) transfer 보존식에 들어간다. shortfall은 움직이지 않은 돈이라 transfer 보존식에 들어가지 않는다.
- `LifeState.outstanding()`이 "얼마가 남았나"의 유일한 답이다: 통화별 받을/줄 remaining 합(금액을 모르는 obligation은 숫자 없이 개수로만 보고).

### 20.5 시나리오 U — 요청 30,000에 50,000 입금

구매액 30,000(요청도 exact)에 엄마가 50,000을 보내면 정산 30,000 + unresolved surplus 20,000이다. 사용자에게 의미를 물을 수 있다(후속 분류는 이번에 확장하지 않는다: `gift`/`otherObligation`/`other` 등). **50,000 전체를 그 구매의 환급으로 처리해 구매 지출을 −20,000으로 만들지 않는다.** 경제적 사실(돈이 움직임)과 분석 귀속(무엇의 환급인가)을 분리하며, residual은 지출 분석에 들어가지 않는다.

### 20.6 한 원은 한 경제적 역할 (회계 포함 규칙)

| 대상 | 역할 | 소비 분석 | 정산 |
|---|---|---|---|
| 원장 거래 + `TransactionAllocation` | 소비(또는 환불 flow) | 포함 | 제외 |
| 정산 송금(`Settlement.transfer`, 정정 effective의 source) | obligation 적용 + surplus | **제외** | 포함 |
| `Obligation` (component에서 유도 포함) | 받을/줄 돈 | 제외 (원래 지출을 줄이지 않는다) | 대상 |
| `SettlementResidual` surplus | 설명되지 않은 실제 금액 | 제외 | 별도 집계 |
| `SettlementResidual` shortfall | obligation 잔액의 참조 | 제외 | 잔액에 이미 포함 |
| 정책 조정(반올림) | raw와 요청의 차 | 제외(`RoundingSummary`로 별도) | obligation 금액에 이미 반영 |
| `ExpenseComponent` | 비용 조각 | 같은 거래의 allocation이 있으면 한 번만 | — |

강제하는 곳:
- 정산에 쓰인 거래(또는 정정 그룹에 묶인 raw 거래)를 소비로 allocation하면 `allocationOnSettlementTransfer`, 이미 allocation된 거래를 정산 송금으로 쓰면 `settlementTransferIsAllocated`.
- `SpendingAnalytics.items(unifiedIn:)`은 allocation 항목과 component 항목을 합치되, 같은 `originTransactionID`·같은 Activity의 allocation이 있는 component를 뺀다.
- 정정은 돈을 만들거나 없애지 않는다: effective = 원 거래 부호 있는 합(`effectiveSignedMinorUnits`).

### 20.7 보존 불변식과 점검 도구

```
raw transfer 합(부호) = effective transfer 합
effective transfer    = settlement에 적용된 합(받을 +, 줄 −) + surplus + 아직 정산되지 않은 합
transfer(settlement)  = Σ(부호 적용액) + surplus            (shortfall은 불포함)
obligation original   = settled + waived + cancelled + remaining
requested             = raw share + policy adjustment
```

`MoneyFlowAudit.audit(rawTransfers:in:)`는 첫 세 줄을, `ObligationBalance.isConserved`는 넷째 줄을 계산하며, `LifeState.conservationViolations()`는 모든 settlement·obligation·정정 그룹·거래 역할을 한 번에 점검해 위반을 문자열로 돌려준다(빈 배열이면 일관). 테스트는 결정론적 property-style sweep으로 300개의 무작위 obligation 조합에서 이 식들과 "미확정 obligation이 열려 있으면 residual 없음"을 검증한다.
