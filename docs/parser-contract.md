# Parser 계약 (Parser Contract) — 설계 초안

상태: **초안. 코드 변경 없음.** Core ledger / candidate promotion 구현과 병렬로 준비한 문서이며, 아래 §9의 열린 질문은 구현 에이전트·사용자와 합의 후 확정한다.
짝 문서: [parser-fixtures.md](parser-fixtures.md) (케이스별 fixture matrix).

실제 은행/카드사의 문구·포맷은 이 문서에 없다. 모든 예시는 `테스트은행`, `테스트카드`, `테스트상호` 같은 합성 값이며, provider별 template은 익명화한 실제 샘플이 확보된 뒤 별도 rule로 추가한다(§5.3).

## 1. 파이프라인에서의 위치

```text
금융 앱 알림 → RawNotification → [Parser] → TransactionCandidate(Draft)
            → validation / dedup / review → ledger
```

| Parser가 하는 일 | Parser가 하지 않는 일 |
|---|---|
| 알림 텍스트 정규화(`NotificationText`) 후 사실(fact) 추출 | ledger/Repository 읽기·쓰기 (의존 금지) |
| 거래 종류(kind)·방향·금액·통화·시각·잔액·수단 힌트 추출 | 계좌/카드 바인딩 (`AccountID`, `CreditInstrumentID` 결정) |
| 원문 그대로의 상호/상대방 문자열 보존 | 상호 정규화, alias 병합, 상호 DB 조회 |
| 강/약 evidence 생성 | 중복 여부 판정, 원거래 연결, 이체 짝 맞추기 |
| issue 코드와 confidence 부여, 불확실 시 needsReview | category / activity / 정산 대상 추론 |
| 실패를 명시적 결과로 반환 | 환율 조회, 금액 보정, 시각 추정(§4.3의 명시 규칙 제외) |

## 2. 설계 원칙

1. **원본 보존.** Parser는 `RawNotification`을 변경하지 않으며, 모든 출력은 `rawNotificationID`로 원본을 가리킨다. 파싱 실패·`notTransaction` 판정도 원본은 그대로 남는다(삭제/덮어쓰기 금지). 재파싱은 항상 원본에서 다시 시작할 수 있어야 한다.
2. **Deterministic 우선.** 순수 함수: `parse(raw, context) -> outcome`. 같은 입력·같은 `parserVersion`이면 항상 같은 출력. 시스템 시각, 로케일, 타임존, 난수, 네트워크, ML을 쓰지 않는다. 기준 시각/타임존은 `ParsingContext`로 주입한다. 규칙은 명시적 키워드/정규식 + 우선순위표(§5)로 표현한다.
3. **불확실하면 추측 대신 needsReview.** 확신 못 하는 필드를 "가장 그럴듯한 값"으로 채우지 않는다. 필드를 비우고 issue를 남기거나(soft), 후보 전체를 needsReview로 보낸다(hard). 결정표는 §6.
4. **금액·통화·시각 파싱 실패는 안전하게 fail.** 파싱에 실패했거나 모호한 값은 기본값(0원, KRW, 현재 시각)으로 대체하지 않는다. "필드 없음(absent)"과 "필드가 있는데 해석 불가(malformed)"를 구분한다. 전자는 §4.3의 명시된 fallback만 허용, 후자는 항상 fail.
5. **Merchant normalization은 Parser와 분리.** Parser는 `merchantRaw`를 `NotificationText.normalize` 수준(NFC/공백/개행)으로만 정리해 보존한다. 법인 표기 제거, 지점명 분리, 대소문자 통일, alias 매칭은 별도 계층의 책임이다.
6. **Category/activity inference는 Parser 책임이 아니다.** 출력 타입에 category/activity/정산 필드가 없다. "스타벅스 → 카페" 같은 추론이 parser 코드에 나타나면 계약 위반.
7. **Strong ID가 없으면 fingerprint evidence만 생성한다.** 최종 dedup 판단(merge/별도 거래/review)은 Deduplication 계층이 한다(D003). Parser는 "이 알림이 어떤 증거를 갖는가"만 말하고 "다른 알림과 같은 거래인가"는 말하지 않는다.
8. **한 알림 → 독립 결과.** Parser는 과거 알림·ledger 상태를 보지 않는다. 같은 문구의 알림 두 개는 두 개의 독립 결과(각자 다른 candidate ID)다. 암묵적 중복 제거 금지(실제 연속 결제 2건이 합쳐지는 사고 방지).
9. **금액은 정수 minor unit.** 부동소수점 금지. 통화별 지수는 ISO 4217 표(KRW 0, JPY 0, USD 2, EUR 2 …)를 코드에 고정한다. 표에 없는 통화는 `currencyUnsupported`.
10. **개인정보 최소화.** 계좌/카드는 알림에 나온 마스킹 힌트(끝 4자리 등)만 보존한다. 전체 번호를 복원·저장하지 않는다. 수취인/송금인 이름은 `payeeRaw`로만 보존한다.
11. **Parser가 만든 값은 사실 주장이 아니라 "원문이 말한 것"이다.** 예: `balanceAfter`는 "알림에 적힌 잔액", 계좌의 검증된 잔액이 아니다.

## 3. 타입 계약

Swift 구현 형태는 구현 에이전트가 정한다. 아래는 필드 의미와 불변식의 명세이며 이름은 제안이다.

### 3.1 입력

```text
parse(_ raw: RawNotification, context: ParsingContext) -> ParseOutcome

ParsingContext {
  timeZone: Asia/Seoul        // 원문에 시각대가 없을 때 해석 기준. 주입값, 시스템 값 금지
  referenceTime: Int64 ms     // 연도 보정 기준. 기본 = raw.notificationAt ?? raw.capturedAt
  parserVersion: String       // 예 "generic-ko.v1"
}
```

텍스트 입력은 `NotificationText.joined(raw)` 한 번만 사용한다. title/subtitle/body 어디에 있든 같은 결과여야 한다(§10 불변식 I7).

### 3.2 출력

```text
ParseOutcome =
  | candidate(TransactionCandidateDraft)   // 거래로 해석됨 (clean 또는 needsReview)
  | notTransaction(reason)                 // 금융 알림이지만 원장 이벤트가 아님 (광고, 인증번호, 한도 안내, 결제 예정 안내 …)
  | failed(ParseFailure)                   // 금융 거래로 보이나 안전하게 해석 불가
```

`failed`는 필드를 추측해 채우지 않는다. Assembler는 `failed`를 "내용 없는 needsReview + `parserUncertain`"으로 올려 사용자가 원문을 보고 처리하게 한다. 원본은 이미 보존돼 있다.

```text
TransactionCandidateDraft {
  rawNotificationID: String
  eventIndex: Int                        // 한 알림에서 복수 이벤트를 지원하게 될 때를 위한 자리. v1은 항상 0
  parserID, parserVersion, ruleID        // 어떤 rule이 매칭했는지 (테스트/디버깅/재파싱 비교용)

  kind: EventKind                        // §3.3
  direction: outflow | inflow | neutral  // 대상 수단 기준의 현금/부채 방향 (neutral = 매입 통지 등)
  cancellation: CancellationInfo?        // kind가 취소/환불일 때만

  amount: Money                          // 알림이 말한 "이 이벤트의 금액". 거래 통화 기준, 항상 > 0, 부호 없음
  settlementAmount: Money?               // 외화 결제에서 알림이 명시한 청구(원화) 금액
  originalAmount: Money?                 // 부분 취소: 원승인 금액 (명시된 경우만)
  remainingAmount: Money?                // 부분 취소: 취소 후 잔여 승인액 (명시된 경우만)
  feeAmount: Money?                      // ATM/이체 수수료 (라벨이 명시된 경우만)
  balanceAfter: Money?                   // 계좌성 수단의 거래 후 잔액 (명시된 경우만)

  occurredAt: Timestamp?                 // {unixMs, precision: second|minute|day, source: text|notificationTime|captureTime}
  instrument: InstrumentHint             // {type, maskedHint?, displayNameRaw?}
  flags: Set<ChannelFlag>                // easyPay(providerRaw?), overseas, foreignCurrency, recurring, transit, atm, autoDebit, installment(months)
  counterparty: { merchantRaw?, payeeRaw?, memoRaw? }

  evidence: [EvidenceItem]               // §8
  issues: [ParserIssue]                  // §6
  confidence: high | medium | low        // §7
  provenance: [FieldName: Range]         // 각 필드가 joined text의 어느 구간에서 왔는지 (review UI/테스트용, 권장)
}
```

불변식:

- `amount.minor > 0`. 0원/음수는 §6의 `amountZero`/`amountUnparseable`.
- `evidence`는 최소 `fp.exact.v1`을 포함한다(필수 필드가 있을 때). 원본 raw ID 자체는 `TransactionCandidate.evidenceIDs`가 담는다.
- `confidence == low` ⇒ outcome은 항상 needsReview.
- `kind`/`direction`/`amount` 중 하나라도 확정 못 하면 draft를 만들지 않고 `failed`.
- Draft에는 `AccountID`, `CreditInstrumentID`, `LedgerEntryID`, category, activity, 정규화된 merchant가 **없다**.
- Parser는 `ready` 상태를 만들지 않는다. `ready`는 binding + dedup + validation 이후 Assembler/Promotion의 일이다(§9).

### 3.3 EventKind

| kind | 의미 | 방향 | 소비 영향(참고, ledger 책임) |
|---|---|---|---|
| `purchase` | 카드/체크/간편결제/교통 후불 등 결제 | outflow | 소비 |
| `cancellation` | 결제 취소(전액/부분/미상) | inflow | 원거래 반환 |
| `refund` | 환불 입금 (취소 문구 없이 돈이 돌아옴) | inflow | 반환(원거래 연결은 별도) |
| `withdrawal` | 이체/ATM/카드대금이 아닌 일반 출금 | outflow | 미정(수동/규칙) |
| `deposit` | 일반 입금 | inflow | 미정 |
| `transferOut` / `transferIn` | 계좌이체의 한 다리(leg) | outflow / inflow | 이체(소비 아님), 짝은 상위 계층 |
| `cardBillPayment` | 카드대금 납부 | outflow | 소비 아님, 부채 감소 |
| `cashWithdrawal` | ATM 현금 인출 | outflow | 현금 이동 |
| `walletTopUp` | 선불/간편결제 잔액 충전 | outflow | 이체 성격, 소비 아님 |
| `purchaseSettlementNotice` | 승인 후 매입(청구 확정) 통지 | neutral | 새 소비 아님, 승인 건과 연결 후보 |
| `feeCharge` | 별도 수수료 통지 | outflow | 수수료 |

분류가 둘 이상 매칭되고 우선순위로도 못 가르면 `kindAmbiguous`(hard).

## 4. 필드 파싱 규칙

### 4.1 금액

- 지원 표기(KRW): `5,000원`, `5000원`, `₩5,000`, `￦5,000`, `KRW 5,000`, `5,000 원`(공백). 천 단위 구분자 `,` 허용. 소수점은 KRW에서 거부.
- 미지원(→ fail): 한글 수사(`5천원`, `오만원`, `1만5천원`), 지수 표기, 범위(`5,000~6,000원`), 부호만 있는 값, 자릿수 오류(`5,00원`, `5,0000원`).
- **라벨 우선.** 한 알림에 금액이 여러 개면 라벨로 구분한다: `승인/결제/출금/입금/이체/취소/환불/사용 금액` ⇒ `amount`, `잔액/잔고` ⇒ `balanceAfter`, `수수료` ⇒ `feeAmount`, `한도/잔여한도/누적` ⇒ 어느 필드에도 넣지 않음(무시하되 `provenance`에 기록 가능). 라벨 없는 금액이 2개 이상이고 순서 규칙으로도 못 가르면 `amountAmbiguous`(hard). **금액 후보 중 "가장 큰 값"이나 "첫 값" 같은 휴리스틱을 쓰지 않는다.**
- 취소 알림의 `-5,000원` 같은 부호: 부호는 무시하고 방향은 `kind`로만 정한다(부호를 방향 근거로 쓰지 않음).
- 0원: `amountZero`(hard). (카드 등록 확인 0원 승인 등. 소비/이동이 아님을 사람이 확인.)
- `Int64` overflow → `amountUnparseable`.

### 4.2 통화

- `원`, `₩`, `￦`, `KRW` ⇒ KRW(확정). ISO 코드(`USD`, `JPY`, `EUR`, …)가 붙으면 그 통화(확정, 표에 있을 때).
- 기호만 있는 경우: `€` ⇒ EUR(확정). `$`, `¥`, `£`는 통화가 여러 나라에 걸치거나(`$`: USD/CAD/AUD, `¥`: JPY/CNY) 오해 소지가 있어 **통화 후보를 찍지 않고** `currencyAmbiguous`(hard). 구현은 `$ ⇒ USD` 기본값을 두지 않는다.
- 통화 단서가 전혀 없는 숫자(`5,000`)는 `원`/`KRW`가 없으면 KRW로 간주하지 않는다 ⇒ `currencyAmbiguous`. 단, 해당 rule이 템플릿상 "금액 슬롯은 항상 KRW"임이 provider 샘플로 확인된 경우에만 rule 단위로 예외를 둔다(현재 generic rule에는 예외 없음).
- 환율/원화 환산액은 명시된 경우에만 `settlementAmount`로 보존. 계산하지 않는다.

### 4.3 시각

- 지원 표기 예: `10/05 14:32`, `10월 05일 14:32`, `2026-10-05 14:32[:11]`, `26.10.05 14:32`, `10/05` (날짜만), `14:32` (시각만).
- 타임존은 `context.timeZone`으로 해석(원문에 오프셋이 명시되면 그 값, 단 알림 문구에서는 드묾).
- 연도가 없는 경우: `referenceTime` 기준으로 "해당 월/일이 reference 날짜 + 1일 이하인 가장 가까운 연도"를 고른다(연말·연초 알림: 12/31 거래를 1/1에 받으면 전년도). 규칙은 결정적이며 fixture로 고정한다.
- 시각 없이 날짜만 있으면 `precision=day`. `occurredAt.source=text`.
- **absent(시각 정보 자체가 없음)**: `notificationAtUnixMilliseconds` → 없으면 `capturedAtUnixMilliseconds`를 `occurredAt`으로 쓰되 `source`를 `notificationTime`/`captureTime`으로 표시하고 `timeAbsentFallback`(soft) 부여. 단, 값이 자정 ±N분(N=10, 설정 상수) 또는 월 경계에 걸리면 예산 월이 틀릴 수 있어 `timeBoundaryRisk`(hard).
- **malformed(시각 문자열이 있는데 해석 불가: `25:61`, `13/45`, `02/30`)**: fallback 금지. `timeMalformed`(hard) — 거래 시각은 비워두고 draft 자체는 만들 수 있으나 needsReview.
- 알림의 `capturedAt`은 거래 시각이 아니다. 원문에 시각이 있으면 항상 원문이 우선(원문 시각과 `notificationAt` 차이가 크면(≥ 24h) `timeSkewSuspicious`(soft)).

### 4.4 잔액

- `잔액/잔고` 라벨 뒤 금액만 `balanceAfter`. 계좌성 수단(`bankAccount`, `debitCard`(연결 계좌), `prepaidWallet`)에서만 의미가 있다.
- 신용카드의 `한도/잔여한도/이번달 사용액`은 `balanceAfter`가 아니다(무시).
- `balanceAfter`의 통화는 **잔액 자신의 통화 표기**를 따르며 `amount`의 통화와 같을 필요가 없다(체크카드 해외결제: amount=USD, balanceAfter=KRW). 잔액 쪽 통화 단서가 없으면 §4.2를 적용해 잔액만 버린다(거래 자체는 영향 없음, PF-BAL-003).
- 음수 잔액 표기(`-5,000원`)는 정책 미정이므로 v1은 hard issue(`parserUncertain`)로 처리한다(열린 질문).
- 잔액이 없으면 `balanceAfter=nil`, issue 없음(soft deficiency로 취급하지 않음, confidence 감점 없음).

### 4.5 수단 / 상대방

- `instrument.type`: 키워드(`체크`, `신용`, `카드`, `계좌`, `입출금`, `충전`, `교통카드` 등)로 결정. 판단 근거가 없으면 `unknown`(soft, 후속 binding 계층이 `unknownAccount` 처리).
- `maskedHint`: 알림에 나온 끝자리 마스킹만(`1234`, `*1234`, `123-***-456789` → `*456789` 처럼 알림이 노출한 형태 그대로). 가공해서 완전한 번호로 만들지 않는다.
- 같은 알림에 서로 다른 수단 힌트가 둘 이상(예: 카드 `1234`와 계좌 `5678`)이면 라벨 규칙으로 역할을 정할 수 있을 때만 사용하고, 아니면 `instrumentConflict`(hard).
- `merchantRaw`: 라벨(`가맹점`, `이용처`, `사용처`) 또는 template 위치로 확정된 문자열. 못 찾으면 `nil` + `merchantMissing`(soft).
- `payeeRaw`: 이체/입금의 상대방 이름. 개인 이름일 수 있으므로 evidence/fingerprint 해시에는 쓰되 로그에 평문을 남기지 않는 것을 권장.

## 5. 분류 규칙

### 5.1 키워드 우선순위 (generic-ko v1)

단순 `contains("승인")` 매칭은 `승인취소`를 승인으로 오분류한다. 분류는 아래 순서로 **첫 매칭에서 멈추지 않고 전부 수집한 뒤** 우선순위로 해소한다.

| 순위 | 신호 | 결과 |
|---|---|---|
| 1 | `승인거절`, `결제실패`, `한도초과`, `잔액부족` 등 거절/실패 | `notTransaction(declined)` |
| 2 | `부분취소`, `일부취소` | `cancellation(partial)` |
| 3 | `승인취소`, `결제취소`, `취소승인`, `매입취소`, `취소` + 금액 | `cancellation(unspecified)` |
| 4 | `환불예정`, `환불 접수`, `취소 예정`, `영업일 이내` | `notTransaction(pending)` 또는 pending draft(§fixtures PF-RFD) |
| 5 | `환불` + 입금 문맥 | `refund` |
| 6 | `카드대금`, `결제대금`, `카드 자동이체` | `cardBillPayment` |
| 7 | `ATM`, `CD기`, `현금인출` | `cashWithdrawal` |
| 8 | `충전` | `walletTopUp` |
| 9 | `매입` (취소 아님) | `purchaseSettlementNotice` |
| 10 | `이체` + `출금`/`입금` | `transferOut`/`transferIn` |
| 11 | `승인`, `결제`, `사용` + 카드/페이 문맥 | `purchase` |
| 12 | `출금` / `입금` 단독 | `withdrawal` / `deposit` |

규칙:
- 서로 다른 kind가 같은 순위대에서 충돌하면 `kindAmbiguous`.
- 방향 단서(출금/입금)와 kind가 모순(예: `purchase`인데 `입금`)이면 `directionUnknown`(hard).
- 인증번호/광고/이벤트/한도·잔액 조회/결제 예정 안내: `notTransaction`. **금액이 있다고 거래가 아니다.**

### 5.2 복수 이벤트

한 알림에 거래가 둘 이상(예: 이용 내역 요약 2건)이면 v1은 `multipleTransactionsInOne`(hard) + 첫 이벤트만 추측하지 않고 `failed` 처리. 분리 파싱(`eventIndex` 사용)은 실제 샘플로 필요성이 확인되면 추가.

### 5.3 Rule 구조와 provider template

- `GenericKoreanRules`: 위 키워드 기반. 모든 fixture가 이것을 기준으로 한다.
- `ProviderTemplate`(추후): 익명화한 실제 샘플로 확인된 정확한 슬롯 위치. `providerHint`가 일치할 때만 활성화하되, template이 매칭 실패하면 generic으로 **조용히 fallback하지 않고** `templateConflict` 또는 confidence 감점으로 드러낸다(추측 확장 방지).
- 모든 rule은 `ruleID`와 `parserVersion`으로 식별한다. 규칙을 바꾸면 버전을 올리고, fixture의 `expect`는 버전과 함께 갱신한다.

## 6. Issue 카탈로그와 needsReview 결정표

Parser issue는 Core의 `CandidateIssue`(8절 매핑)로 올라간다. **hard**가 하나라도 있으면 draft는 `needsReview`다. **soft**만 있으면 confidence만 영향받고 자동 처리 가능 상태(`parsed`)를 유지한다.

| ParserIssue | 등급 | 조건 | 올라가는 CandidateIssue |
|---|---|---|---|
| `amountMissing` | fail | 금액 라벨/값 없음 | (failed) `parserUncertain` |
| `amountUnparseable` | fail | 형식 오류, overflow | (failed) `parserUncertain` |
| `amountAmbiguous` | hard | 라벨 없는 복수 금액 | `parserUncertain` |
| `amountZero` | hard | 0원 | `parserUncertain` |
| `currencyAmbiguous` | hard | `$`/`¥`/단서 없음 | `parserUncertain` |
| `currencyUnsupported` | hard | ISO 표에 없음 | `unsupportedEvent` |
| `timeMalformed` | hard | 시각 문자열 해석 불가 | `parserUncertain` |
| `timeBoundaryRisk` | hard | fallback 시각이 자정/월 경계 근처 | `parserUncertain` |
| `kindAmbiguous` | hard | 분류 충돌 | `parserUncertain` |
| `directionUnknown` | hard | 방향 단서 없음/모순 | `parserUncertain` |
| `instrumentConflict` | hard | 수단 힌트 충돌 | `parserUncertain` |
| `partialCancelInconsistent` | hard | `original − cancel ≠ remaining` 등 | `parserUncertain` |
| `settlementAmountMismatch` | hard | 매입액 ≠ 승인액 등 알림 내부 모순 | `parserUncertain` |
| `multipleTransactionsInOne` | hard | 복수 이벤트 | `unsupportedEvent` |
| `unsupportedEvent` | hard | 금융이지만 지원 밖(대출 이자, 증권 매매 등) | `unsupportedEvent` |
| `templateConflict` | hard | provider template과 generic 불일치 | `parserUncertain` |
| `merchantMissing` | soft | 상호 슬롯 없음 | — |
| `timeAbsentFallback` | soft | 시각 없음 → 알림/수신 시각 사용 | — |
| `instrumentHintMissing` | soft | 수단 마스킹 힌트 없음 | — (후속 `unknownAccount`) |
| `timeSkewSuspicious` | soft | 원문 시각과 notificationAt 차이 ≥ 24h | — |
| `recurringHintOnly` | soft | `정기` 키워드는 있으나 주기 정보 없음 | — |

Parser가 **발행하지 않는** CandidateIssue: `ambiguousWithoutStrongIdentity`, `conflictingStrongIdentity`, `missingOriginalEntry`, `incompleteTransfer`, `unknownAccount`. 이들은 dedup/linking/binding 계층이 ledger·다른 candidate를 알아야 판정 가능하다.

**"strong ID 없음"은 parser needsReview 사유가 아니다.** 단독 알림에 강한 ID가 없는 것은 정상이다. 유사 알림과 충돌할 때 `ambiguousWithoutStrongIdentity`를 올리는 것은 dedup 계층이다(D003).

## 7. Confidence 루브릭 (결정적)

ML 확률이 아니라 규칙 기반 등급이다. 시작 1.0에서 감점하고 구간으로 등급을 낸다. **테스트는 등급(tier)만 단언**하며, 점수는 디버그용이다.

| 감점 | 값 |
|---|---|
| 기본: rule 정확 매칭, kind/amount/currency/direction 라벨 확정 | 1.00 |
| `merchantMissing` (결제류) | −0.15 |
| `timeAbsentFallback` | −0.15 |
| `instrumentHintMissing` | −0.15 |
| `recurringHintOnly`, `timeSkewSuspicious` | −0.10 |
| 매칭된 rule이 provider template이 아닌 generic fallback | −0.05 |
| 잔여 미해석 텍스트(템플릿 슬롯 밖 숫자/금액 토큰) 존재 | −0.20 |
| hard issue 1개 | 즉시 `low` |

등급: `high` ≥ 0.85, `medium` 0.60–0.85, `low` < 0.60 또는 hard issue 존재.

자동 처리 가능성(parser 관점): `high`, `medium`(soft만) ⇒ `parsed`. `low` ⇒ needsReview. 자동 처리 가능은 "parser가 사람 확인을 요구하지 않는다"는 뜻이며 **ledger 반영을 의미하지 않는다.** 이후 binding / dedup / validation이 각자 review를 요구할 수 있다.

## 8. Evidence 계약

`EvidenceItem { kind, value, strength, scope }`. Parser는 생성만 하고 판정하지 않는다.

| kind | strength | value 구성 | 생성 조건 |
|---|---|---|---|
| `delivery-id` | strong (adapter가 보장할 때) | `raw.sourceDeliveryID` | 값이 있을 때. scope = `source.applicationIdentifier`. 이것은 raw 계층의 멱등 키이며 같은 거래의 *다른 알림*을 묶는 근거가 아니다 |
| `provider-txn-id` | strong | 알림 본문의 라벨된 거래/원거래 번호(`거래번호`, `승인번호`가 아니라 거래 식별 라벨) | 라벨이 명시된 값만. 숫자열을 추측해 ID로 취급 금지 |
| `approval-no` | scoped | 승인번호 | 라벨 `승인번호`가 있을 때. 승인번호는 카드사 내 날짜·가맹점 범위에서만 유일 → scope = (provider, instrument hint, amount, 승인일). **단독으로 strong 취급 금지**, dedup 계층 정책 |
| `original-approval-ref` | relation | 취소/환불 알림이 가리키는 원승인번호·원승인일·원금액 | 취소류에 명시된 경우. 관계 힌트이며 원거래 존재를 보증하지 않음 |
| `fp.exact.v1` | weak | `kind\|direction\|amount.minor\|ccy\|instrument.type+hint\|occurredAt(분 단위, 정밀도 미달 시 일 단위)\|merchantRaw\|payeeRaw` (normalize된 원문, 정규화 DB 미사용) | 필수 필드 확보 시 항상 |
| `fp.loose.v1` | weak | `kind\|direction\|amount.minor\|ccy\|occurredAt(분 단위)` | 항상. 서로 다른 앱(간편결제앱 + 카드사)의 같은 결제 후보 탐지용 |
| `balance-chain` | contextual | `{balanceAfter, signedDelta}` | `balanceAfter` 있을 때. 후속 계층이 `before = after ∓ amount`로 연속성/순서를 검증 |
| `text-digest` | weak | 정규화된 joined text 해시 | 항상. "완전히 같은 문구"만 의미하며 같은 거래 증명이 아님 |
| `period-key` | contextual | 집계 알림의 기간·건수 | 교통 후불 합산 등 |
| `settlement-link` | relation | 매입 통지의 승인번호/금액/가맹점 | `purchaseSettlementNotice`일 때 |

해시 알고리즘·직렬화 형식은 구현 에이전트가 고정하되, **fixture는 해시값이 아니라 "evidence kind와 구성 필드"를 단언**한다(구현 종속 방지). 구성 문자열 자체를 노출하는 테스트 헬퍼(`fingerprintInput`)를 두면 fixture에서 정확한 구성을 검증할 수 있다.

## 9. 기존 Core 타입과의 매핑 및 열린 질문

현재 `TransactionCandidate`(`Sources/NEOBudgetCore/Domain/TransactionCandidate.swift`)는 `evidenceIDs`, `status`, `issues`, `proposedEntry: LedgerEntry?`, `policyVersion`만 갖고, `ready`는 `proposedEntry != nil && issues.isEmpty`를 요구한다. `LedgerEntry`는 `AccountID` 기반 Posting을 요구하므로 **parser 단계에서는 `ready`를 만들 수 없다.**

제안 매핑:

| Parser outcome | Assembler가 만드는 TransactionCandidate |
|---|---|
| `candidate`, hard issue 없음 | `parsed`(내부 상태). binding+dedup+validation 통과 시 비로소 `ready` + `proposedEntry` |
| `candidate`, hard issue 있음 | `needsReview`, issues = 매핑표, `proposedEntry = nil` |
| `candidate`, pending 종류(환불 예정 등) | `waitingForEvidence` |
| `failed` | `needsReview` + `parserUncertain`, 파싱된 필드 없음 |
| `notTransaction` | candidate 없음 (raw에 분류 결과만 기록) |

열린 질문 (구현 에이전트/사용자 확인 필요):

- **Q1 Draft 위치.** parsed facts(`TransactionCandidateDraft`)를 `TransactionCandidate`에 필드로 추가할지, parser 전용 타입으로 두고 Assembler가 변환할지. 현재 `TransactionCandidate`에는 파싱 사실을 담을 곳이 없다. 이 문서는 후자(parser 전용 타입)를 가정한다.
- **Q2 `parsed` 상태.** `CandidateStatus`에 pre-binding 상태가 필요한가, 아니면 Assembler 내부 타입으로만 둘 것인가.
- **Q3 `merchantMissing`을 soft로 둔 결정.** 상호가 없어도 금액/수단/시각이 확실하면 자동 처리 가능으로 본다(상호는 메타데이터). 더 보수적으로 가려면 hard로 올린다.
- **Q4 `approval-no` 강도.** scoped로 두었다. 이 조합을 dedup에서 strong으로 인정할지는 D003의 연장 결정.
- **Q5 시각 fallback 허용.** 시각 absent 시 알림/수신 시각으로 대체(soft)하는 정책이 사용자 의도와 맞는지(§4.3). 대안: 항상 review.
- **Q6 통화 `$` 기본값 금지.** 구현상 편의와 정확성의 절충(§4.2). 사용자의 실제 해외 결제 알림 샘플로 재검토.
- **Q7 candidate ID 생성.** `TransactionCandidateID`를 `hash(rawNotificationID + parserVersion + eventIndex)`처럼 결정적으로 만들지(재파싱 시 같은 ID) vs 외부 주입. 재파싱 정책과 연결.

## 10. 테스트 규약

### 10.1 Fixture 스키마

위치 제안: `Tests/NEOBudgetCoreTests/Fixtures/parser/*.json` (현재 `Fixtures/raw-notifications.json`과 같은 형태의 `RawNotification` 입력을 재사용).

```json
{
  "id": "PF-DEB-001",
  "description": "체크카드 결제, 잔액 포함",
  "context": { "timeZone": "Asia/Seoul", "referenceTimeUnixMilliseconds": 1791178330000, "parserVersion": "generic-ko.v1" },
  "input": { "...RawNotification 필드...": "" },
  "expect": {
    "outcome": "candidate | notTransaction | failed",
    "status": "parsed | needsReview",
    "confidence": "high | medium | low",
    "kind": "purchase",
    "direction": "outflow",
    "amount": { "minor": 5000, "currency": "KRW" },
    "occurredAt": { "iso": "2026-10-05T14:32:00+09:00", "precision": "minute", "source": "text" },
    "instrument": { "type": "debitCard", "maskedHint": "1234" },
    "counterparty": { "merchantRaw": "테스트상호" },
    "balanceAfter": { "minor": 100000, "currency": "KRW" },
    "flags": [],
    "issues": [],
    "evidenceKinds": ["fp.exact.v1", "fp.loose.v1", "balance-chain", "text-digest"],
    "absentFields": ["settlementAmount"]
  }
}
```

- 단언 대상은 `expect`에 쓴 필드만이 아니라 **`absentFields`로 명시한 필드가 정말 nil인지**를 포함한다(추측 채움 방지가 계약의 핵심이므로).
- 기준 시각 `T0 = 2026-10-05T14:32:10+09:00 = 1791178330000 ms`. fixture 문서의 `T0+Ns`는 이 값 기준 상대 표기다.

### 10.2 공통 불변식 (모든 fixture에 자동 적용하는 property 테스트)

| ID | 불변식 |
|---|---|
| I1 | 같은 입력·context ⇒ 같은 출력 (두 번 실행 비교) |
| I2 | `RawNotification`이 변경되지 않는다 (입력 deep-equal) |
| I3 | draft의 `rawNotificationID == raw.id` |
| I4 | `amount.minor > 0` 이고 정수. hard issue가 있으면 `status=needsReview` |
| I5 | `confidence == low` ⇒ `status != parsed` |
| I6 | draft는 category/activity/AccountID/정규화 상호 필드를 갖지 않는다 (타입 수준) |
| I7 | title/subtitle/body 분할 위치, CRLF/LF, NBSP, 전각 공백이 달라도 같은 결과 (`NotificationText.joined` 이후 동일) |
| I8 | 같은 문구의 두 raw(ID만 다름) ⇒ 두 개의 서로 다른 독립 결과, `fp.exact.v1` 값은 같고 candidate ID는 다름 |
| I9 | `failed`/`notTransaction`에서 부분적으로 추측된 금액/시각 필드가 없다 |
| I10 | `sourceDeliveryID`가 있으면 `delivery-id` evidence가 있고, 없으면 만들지 않는다 |
| I11 | 금액 문자열 뒤에 임의 숫자가 붙거나 순서가 바뀐 변형(mutation)에서 라벨 규칙이 잘못된 값을 `amount`로 선택하지 않는다 (fail 또는 라벨 값 유지) |

### 10.3 Parser 단위 테스트가 건드리면 안 되는 것

Parser 테스트는 `LedgerRepository`/`RawNotificationRepository`/in-memory target을 import하지 않는다. 의존 방향 위반은 테스트 컴파일 오류로 드러나야 한다.
