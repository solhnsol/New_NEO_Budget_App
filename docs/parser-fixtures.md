# Parser Fixture Matrix — 후속 executable fixture 기준

상태: **계약 채택, 상세 fixture 구현 대기.** 계약은 [parser-contract.md](parser-contract.md). 현재 Core 경계와 합성 26개 형식 smoke는 구현됐으며, 이 문서의 각 `PF-*` fixture는 `Tests/NEOBudgetCoreTests/Fixtures/parser/*.json`(계약 §10.1 스키마)으로 옮겨 provider별 동작을 확장한다.

## 0. 읽는 법

**합성 문구 주의.** 아래 알림 문구는 실제 은행/카드사 포맷이 아니다. `테스트은행`/`테스트카드`/`테스트상호` 같은 일반화된 문구로 `GenericKoreanRules`(계약 §5.1)를 검증하기 위한 것이다. 실제 문구를 알게 되면 익명화한 샘플을 별도 `ProviderTemplate` fixture로 추가한다. 이 fixture를 근거로 특정 회사 포맷이 이렇다고 주장하지 않는다.

**공통 기준값**

| 항목 | 값 |
|---|---|
| `T0` | `2026-10-05T14:32:10+09:00` = `1791178330000` ms |
| `context.timeZone` | `Asia/Seoul` |
| `context.referenceTime` | 별도 표기 없으면 `raw.capturedAt` |
| `context.parserVersion` | `generic-ko.v1` |
| `capturedAt` | 별도 표기 없으면 `T0 + 2s` |
| `notificationAt` | 별도 표기 없으면 없음(nil) |
| 본문 시각 | `10/05 14:32` → `2026-10-05T14:32:00+09:00`, precision `minute`, source `text` |

**기본 source**

| 별칭 | applicationIdentifier / displayName / providerHint |
|---|---|
| `CARD` | `fixture.card.app` / 테스트카드 / `test-card` |
| `BANK` | `fixture.bank.app` / 테스트은행 / `test-bank` |
| `PAY` | `fixture.pay.app` / 테스트페이 / `test-pay` |
| `TRANSIT` | `fixture.transit.app` / 테스트교통 / `test-transit` |

**표기**

- `in.body`의 `\n`은 개행. title이 없으면 생략.
- `expect`에 안 적은 필드는 단언하지 않는다. 단, `absent:` 목록은 **반드시 nil**이어야 한다(추측 채움 방지).
- `evidence`는 kind 목록만 단언한다(해시값 아님). 별표 `(*)`: `sourceDeliveryID`가 있을 때만 `delivery-id` 추가.
- "기본 evidence 세트" `E0` = `fp.exact.v1`, `fp.loose.v1`, `text-digest` (+ `delivery-id`(*)).
- 상태 표기: `parsed`(자동 처리 가능, parser 관점) / `needsReview` / `failed` / `notTransaction`.
- 각 케이스 말미 항목: ① 자동 처리 가능 여부, ② needsReview 조건, ③ dedup evidence, ④ confidence, ⑤ edge case. (RawNotification 예시와 기대 필드는 fixture 블록.)

**공통 규칙(모든 케이스에 적용, 반복 생략)**: 계약 §10.2의 불변식 I1–I11, 원본 보존, category/activity/정규화 상호 필드 부재, "계좌 바인딩/중복 판정/원거래 연결은 parser가 하지 않음".

---

## 1. 체크카드 결제 (`PF-DEB`)

```yaml
# PF-DEB-001 체크카드 결제, 잔액 포함
in: {source: CARD, sourceDeliveryID: "d-001", title: "[테스트카드] 체크카드 승인",
     body: "체크 1234 승인\n5,000원 일시불\n10/05 14:32\n테스트상호\n잔액 100,000원"}
expect:
  outcome: candidate, status: parsed, confidence: high
  kind: purchase, direction: outflow
  amount: {minor: 5000, currency: KRW}
  occurredAt: {iso: "2026-10-05T14:32:00+09:00", precision: minute, source: text}
  instrument: {type: debitCard, maskedHint: "1234"}
  counterparty: {merchantRaw: "테스트상호"}
  balanceAfter: {minor: 100000, currency: KRW}
  flags: []        # 일시불은 flag 아님. installmentMonths = nil
  issues: []
  evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, delivery-id, balance-chain]
  absent: [settlementAmount, originalAmount, feeAmount]

# PF-DEB-002 잔액 없음
in: {source: CARD, title: "[테스트카드] 체크카드 승인",
     body: "체크 1234 승인\n5,000원 일시불\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, balanceAfter: nil, issues: [],
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest]}   # delivery-id 없음, balance-chain 없음

# PF-DEB-003 시각 없음 + notificationAt 존재
in: {source: CARD, notificationAt: "T0", body: "체크 1234 승인 5,000원\n테스트상호"}
expect: {status: parsed, confidence: medium,
         occurredAt: {iso: "2026-10-05T14:32:10+09:00", precision: second, source: notificationTime},
         issues: [timeAbsentFallback]}
```

① 자동 처리: 001·002 가능, 003 가능(soft만; 시각 fallback 표시). ledger 반영은 계좌 바인딩(체크카드 → 연결 계좌 Posting)과 dedup 통과 후.
② needsReview: 금액·방향 모호, 통화 단서 없음, 시각 malformed, 시각 fallback이 자정/월 경계 ±10분(계약 §4.3), 수단 힌트 2개 충돌.
③ evidence: `delivery-id`(있을 때), `fp.exact.v1`, `fp.loose.v1`, `text-digest`, `balance-chain`(잔액 있을 때).
④ confidence: 001/002 high, 003 medium(−0.15).
⑤ edge: 체크카드의 `잔액`은 **연결 계좌의** 잔액. `debitCard` 수단이어도 `balanceAfter`는 허용(계약 §4.4). 같은 문구에서 "체크 1234"가 `1234`카드 끝자리이며 계좌 번호가 아님을 `maskedHint`가 구분하지 않는다 — 계좌/카드 binding 계층 책임. 해외 체크카드 결제는 §12.

---

## 2. 신용카드 승인 (`PF-CRD`)

```yaml
# PF-CRD-001 일시불
in: {source: CARD, title: "[테스트카드] 승인", body: "신용 5678 승인\n12,300원 일시불\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, kind: purchase, direction: outflow,
         amount: {minor: 12300, currency: KRW}, instrument: {type: creditCard, maskedHint: "5678"},
         counterparty: {merchantRaw: "테스트상호"}, issues: [], absent: [balanceAfter]}

# PF-CRD-002 할부
in: {source: CARD, body: "신용 5678 승인\n300,000원 3개월\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, amount: {minor: 300000, currency: KRW},
         flags: [installment(3)], issues: []}
         # amount 는 총 승인액. 월 납입액 계산 금지(parser 책임 아님)

# PF-CRD-003 한도/누적 안내 포함 (잔액으로 오인 금지)
in: {source: CARD, body: "신용 5678 승인\n12,300원 일시불\n10/05 14:32\n테스트상호\n이번달 사용액 450,000원\n잔여한도 1,550,000원"}
expect: {status: parsed, confidence: high, amount: {minor: 12300, currency: KRW},
         absent: [balanceAfter], issues: []}
```

① 자동 처리: 가능. 신용카드는 은행 Posting이 아니라 소비 + 미납 의무(D002) — 매핑은 ledger 책임.
② needsReview: 라벨 없는 금액 복수(`amountAmbiguous`) 등 공통 조건. 할부 개월 수가 해석 불가(`개월` 앞 숫자가 아님)이면 flag를 만들지 않고 soft 처리하지 않고 hard(`parserUncertain`).
③ evidence: E0. `approval-no`가 본문에 라벨과 함께 있으면 추가(이 합성 문구에는 없음).
④ confidence: high.
⑤ edge: `이번달 사용액`, `잔여한도`의 금액을 amount로 고르는 오류 — 라벨 규칙이 막아야 한다(I11). 할부 `일시불` 문구 부재 시에도 `installment=nil`. 승인 시점에 청구 확정이 아님(§17).

---

## 3. 신용카드 승인 취소 (`PF-CXL`)

```yaml
# PF-CXL-001 원승인 정보 명시
in: {source: CARD, title: "[테스트카드] 승인취소",
     body: "신용 5678 승인취소\n12,300원\n10/05 14:32\n테스트상호\n원승인번호 99001122 (10/04)"}
expect: {status: parsed, confidence: high, kind: cancellation, direction: inflow,
         cancellation: {scope: unspecified},
         amount: {minor: 12300, currency: KRW}, instrument: {type: creditCard, maskedHint: "5678"},
         counterparty: {merchantRaw: "테스트상호"}, issues: [],
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, original-approval-ref]}
         # original-approval-ref.value = {approvalNo: "99001122", approvedOn: 2026-10-04}

# PF-CXL-002 원승인 정보 없음
in: {source: CARD, body: "신용 5678 승인취소\n12,300원\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, kind: cancellation, cancellation: {scope: unspecified},
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest]}
         # original-approval-ref 없음. 원거래 연결은 상위 계층, 없으면 거기서 missingOriginalEntry

# PF-CXL-003 "승인"을 포함한 취소 문구의 오분류 방지
in: {source: CARD, body: "신용 5678 취소승인\n12,300원\n10/05 14:32\n테스트상호"}
expect: {kind: cancellation, direction: inflow}      # purchase 가 아니어야 한다

# PF-CXL-004 취소인데 입금 문맥 모순
in: {source: CARD, body: "신용 5678 승인취소 12,300원 출금\n10/05 14:32\n테스트상호"}
expect: {status: needsReview, confidence: low, issues: [directionUnknown]}
```

① 자동 처리: 001–003 가능(parser 관점). 원거래가 ledger에 있는지/한도 내 반환인지는 후속 계층(D004).
② needsReview: 취소 문구 + 반대 방향 단서(`출금`) 모순, 취소 금액이 여러 개, kind 충돌.
③ evidence: E0 + `original-approval-ref`(명시 시). 취소 알림의 fingerprint는 원승인과 **같은 금액/상호여도 kind/direction이 달라** `fp.exact.v1`이 다르다(원승인과 혼동 방지).
④ confidence: high. 004는 low.
⑤ edge: `취소` 단어가 상호명에 포함(예: `취소국수`)된 경우 — 상호 슬롯에 있는 `취소`는 분류 키워드로 쓰지 않는다. 슬롯이 확정되지 않는 합성 문구라면 `kindAmbiguous`. 취소 금액이 원승인과 달라도 parser는 비교하지 않음. 취소 알림이 승인보다 먼저 도착할 수 있음(순서 비의존).

---

## 4. 부분 취소 (`PF-PCX`)

```yaml
# PF-PCX-001 원금액/취소액/잔여 명시, 일관됨
in: {source: CARD, body: "신용 5678 부분취소\n취소금액 10,000원\n승인금액 30,000원\n취소후금액 20,000원\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, kind: cancellation, direction: inflow,
         cancellation: {scope: partial},
         amount: {minor: 10000, currency: KRW},
         originalAmount: {minor: 30000, currency: KRW}, remainingAmount: {minor: 20000, currency: KRW},
         issues: []}

# PF-PCX-002 부분취소 문구만 있음
in: {source: CARD, body: "신용 5678 부분취소 10,000원\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: high, cancellation: {scope: partial},
         amount: {minor: 10000, currency: KRW}, absent: [originalAmount, remainingAmount]}

# PF-PCX-003 산술 불일치
in: {source: CARD, body: "신용 5678 부분취소\n취소금액 10,000원\n승인금액 30,000원\n취소후금액 15,000원\n10/05 14:32\n테스트상호"}
expect: {status: needsReview, confidence: low, issues: [partialCancelInconsistent]}

# PF-PCX-004 취소 금액이 원승인 금액보다 큼
in: {source: CARD, body: "신용 5678 부분취소\n취소금액 40,000원\n승인금액 30,000원\n10/05 14:32\n테스트상호"}
expect: {status: needsReview, issues: [partialCancelInconsistent]}

# PF-PCX-005 취소금액 = 승인금액 (전액인데 "부분취소"라 표기)
in: {source: CARD, body: "신용 5678 부분취소\n취소금액 30,000원\n승인금액 30,000원\n10/05 14:32\n테스트상호"}
expect: {status: needsReview, issues: [partialCancelInconsistent]}   # 문구 모순. scope 를 임의로 full 로 바꾸지 않는다
```

① 자동 처리: 001·002 가능. 같은 원거래에 대한 누적 반환이 원금액을 넘는지는 ledger(`adjustmentExceedsOriginal`) 몫.
② needsReview: 산술 불일치, 취소액 > 원금액, 문구/금액 모순.
③ evidence: E0 + `original-approval-ref`(명시 시). 같은 원거래에 부분취소가 여러 번 오면 `fp.exact.v1`이 금액·시각으로 달라진다. 연쇄 연결은 dedup/linking.
④ confidence: 001 high, 002 high(원금액 없음은 감점 없음), 003–005 low.
⑤ edge: 부분취소 2회가 같은 금액·분 단위에 연속(드묾)이면 I8로 서로 다른 후보 — 자동 병합 금지(D003). `scope`를 amount 비교로 추론해 `full`로 승격하지 않는다(문구 우선, 불명이면 `unspecified`).

---

## 5. 계좌 출금 (`PF-WDR`)

```yaml
# PF-WDR-001 일반 출금, 잔액 포함
in: {source: BANK, title: "[테스트은행] 출금", body: "123-***-456789\n출금 30,000원\n10/05 14:32\n테스트내용\n잔액 70,000원"}
expect: {status: parsed, confidence: high, kind: withdrawal, direction: outflow,
         amount: {minor: 30000, currency: KRW}, instrument: {type: bankAccount, maskedHint: "123-***-456789"},
         counterparty: {memoRaw: "테스트내용"}, balanceAfter: {minor: 70000, currency: KRW}, issues: [],
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, balance-chain]}

# PF-WDR-002 출금 대상 불명
in: {source: BANK, body: "123-***-456789 출금 30,000원 10/05 14:32"}
expect: {status: parsed, confidence: medium, counterparty: {merchantRaw: nil, payeeRaw: nil, memoRaw: nil},
         issues: [merchantMissing]}
```

① 자동 처리: 가능. 단, `kind=withdrawal`은 소비/이체/수수료 중 무엇인지 parser가 말하지 않는다 — 분류는 하위 계층(규칙·사용자).
② needsReview: 방향 단서 불명, 금액 라벨 부재.
③ evidence: E0, `balance-chain`.
④ confidence: 001 high, 002 medium.
⑤ edge: `출금`이 이체 문구를 포함(`이체 출금`)하면 §7 이체로 분류(우선순위 10 > 12). 출금과 카드대금이 같은 문구에 있으면 §8 규칙. 출금 후 잔액이 음수(마이너스 통장) 표기 `-1,000원`은 부호 보존 정책이 미정 → v1은 `parserUncertain`(hard)으로 보내고 PF-BAL-004로 고정(열린 질문).

---

## 6. 계좌 입금 (`PF-DEP`)

```yaml
# PF-DEP-001 입금 + 송금인
in: {source: BANK, title: "[테스트은행] 입금", body: "123-***-456789\n입금 50,000원\n10/05 14:32\n테스트송금인\n잔액 120,000원"}
expect: {status: parsed, confidence: high, kind: deposit, direction: inflow,
         amount: {minor: 50000, currency: KRW}, counterparty: {payeeRaw: "테스트송금인"},
         balanceAfter: {minor: 120000, currency: KRW}, issues: []}

# PF-DEP-002 입금 + 메모(송금인 불명)
in: {source: BANK, body: "123-***-456789 입금 50,000원 10/05 14:32 메모:테스트메모"}
expect: {status: parsed, confidence: medium, counterparty: {payeeRaw: nil, memoRaw: "테스트메모"}, issues: [merchantMissing]}
```

① 자동 처리: 가능(parser 관점). 입금이 급여/정산/환불/이체 반대 다리 중 무엇인지는 parser가 추론하지 않는다.
② needsReview: 입금 문구에 출금 단서 동시 존재 등 방향 모순.
③ evidence: E0, `balance-chain`.
④ confidence: high / medium.
⑤ edge: 송금인 이름이 개인정보 — 로그 평문 금지. 입금이 자기 계좌 간 이체의 반대 다리일 수 있음 → §7(짝 맞추기는 상위).

---

## 7. 계좌이체 (`PF-TRF`)

```yaml
# PF-TRF-001 이체 출금 (수수료 없음)
in: {source: BANK, title: "[테스트은행] 이체 출금", body: "123-***-456789\n이체 출금 200,000원\n받는분 테스트수취인\n10/05 14:32\n잔액 300,000원"}
expect: {status: parsed, confidence: high, kind: transferOut, direction: outflow,
         amount: {minor: 200000, currency: KRW}, counterparty: {payeeRaw: "테스트수취인"},
         balanceAfter: {minor: 300000, currency: KRW}, issues: []}

# PF-TRF-002 이체 입금 (반대 다리 후보)
in: {source: BANK, title: "[테스트은행] 이체 입금", body: "789-***-000111\n이체 입금 200,000원\n보낸분 테스트송금인\n10/05 14:32\n잔액 500,000원"}
expect: {status: parsed, confidence: high, kind: transferIn, direction: inflow,
         amount: {minor: 200000, currency: KRW}, counterparty: {payeeRaw: "테스트송금인"}, issues: []}

# PF-TRF-003 수수료 명시
in: {source: BANK, body: "123-***-456789\n이체 출금 200,000원\n수수료 500원\n10/05 14:32"}
expect: {status: parsed, kind: transferOut, amount: {minor: 200000, currency: KRW},
         feeAmount: {minor: 500, currency: KRW}, issues: []}
         # amount 는 이체액만, 합계를 만들지 않는다

# PF-TRF-004 방향 불명
in: {source: BANK, body: "123-***-456789 이체 200,000원 10/05 14:32"}
expect: {outcome: candidate, status: needsReview, confidence: low, issues: [directionUnknown]}
```

① 자동 처리: 001–003 가능, 한 알림 = 한 다리(leg). `incompleteTransfer` 판정은 상위 계층(두 다리가 모두 있어야 이체로 확정).
② needsReview: 방향 불명, 수취인/송금인과 수단 힌트 역할 충돌.
③ evidence: E0, `balance-chain`. 두 다리는 서로 다른 계좌의 알림이므로 `fp.loose.v1`이 (kind·direction이 달라) 다르다 — 짝 탐지는 `kind` 쌍(transferOut/transferIn) + 금액 + 시각 근접 같은 별도 규칙이 해야 한다. **parser가 짝을 만들지 않는다.**
④ confidence: 001–003 high, 004 low.
⑤ edge: 자기 계좌 간 이체인지 타인 송금인지는 알림만으로 알 수 없음(`payeeRaw` 이름이 본인과 같을 수 있으나 parser는 모름). 이체가 소비가 아님은 ledger(D002/D004 규약). 이체 수수료가 별도 알림으로 오면 `feeCharge`(§9).

---

## 8. 카드대금 자동이체 (`PF-BIL`)

```yaml
# PF-BIL-001 명시적 카드대금 출금
in: {source: BANK, title: "[테스트은행] 출금", body: "123-***-456789\n테스트카드 카드대금 450,000원 자동이체 출금\n10/05 14:32\n잔액 1,000,000원"}
expect: {status: parsed, confidence: high, kind: cardBillPayment, direction: outflow,
         amount: {minor: 450000, currency: KRW}, flags: [autoDebit],
         counterparty: {payeeRaw: "테스트카드"}, balanceAfter: {minor: 1000000, currency: KRW}, issues: []}

# PF-BIL-002 카드사 이름만 있고 카드대금 라벨 없음
in: {source: BANK, body: "123-***-456789 출금 450,000원 테스트카드 10/05 14:32"}
expect: {status: needsReview, confidence: low, issues: [kindAmbiguous]}
         # 카드사에 지불한 것이 대금인지 보험/수수료인지 단정하지 않는다

# PF-BIL-003 카드사 쪽 알림 (결제 대금 출금 예정 안내)
in: {source: CARD, body: "결제 예정금액 450,000원\n10/07 출금 예정"}
expect: {outcome: notTransaction, reason: upcomingNotice}
```

① 자동 처리: 001 가능, 002/003은 각각 review/비거래.
② needsReview: 카드사명만 있고 대금 라벨 없음, 카드 대금과 일반 출금 신호 충돌.
③ evidence: E0, `balance-chain`. 대금 납부는 소비 추가 0(D002 예시)이므로 소비 집계에서 **과잉 계산을 막는 핵심 분류**다 — `kind=cardBillPayment`가 틀리면 소비가 두 번 잡힌다.
④ confidence: 001 high, 002 low.
⑤ edge: 일부 결제(부분 결제)/리볼빙/선결제는 별도 문구 — v1은 `unsupportedEvent`. 카드대금이 이번 청구액과 정확히 일치하는지는 검증하지 않음(상위). 결제 예정 안내(003)는 거래가 아님.

---

## 9. ATM 출금 (`PF-ATM`)

```yaml
# PF-ATM-001 수수료 포함 명시
in: {source: BANK, title: "[테스트은행] ATM 출금", body: "123-***-456789\nATM 출금 100,000원\n수수료 1,000원\n10/05 14:32\n잔액 400,000원"}
expect: {status: parsed, confidence: high, kind: cashWithdrawal, direction: outflow,
         amount: {minor: 100000, currency: KRW}, feeAmount: {minor: 1000, currency: KRW}, flags: [atm],
         balanceAfter: {minor: 400000, currency: KRW}, issues: []}
         # balanceAfter 는 알림이 말한 값. 100,000 + 1,000 이 잔액 감소와 일치하는지는 balance-chain 으로 상위가 검증

# PF-ATM-002 수수료 별도 알림
in: {source: BANK, body: "123-***-456789 수수료 출금 1,000원 10/05 14:32"}
expect: {status: parsed, kind: feeCharge, direction: outflow, amount: {minor: 1000, currency: KRW}, issues: []}

# PF-ATM-003 수수료 표기가 amount 에 합산됐는지 불명
in: {source: BANK, body: "123-***-456789\nATM 출금 101,000원 (수수료 포함)\n10/05 14:32"}
expect: {status: needsReview, issues: [parserUncertain]}   # 현금액/수수료 분리 불가. 임의로 100,000 + 1,000 분해 금지
```

① 자동 처리: 001, 002 가능. 003 불가.
② needsReview: 총액 vs 현금액 불명, 수수료 라벨 없는 추가 금액.
③ evidence: E0, `balance-chain`. 001과 002는 서로 다른 kind라 `fp.exact.v1`이 다르다.
④ confidence: 001 high, 002 high, 003 low.
⑤ edge: 해외 ATM 인출은 §12 + `atm`. 현금 인출은 소비가 아니라 현금 이동(상위 정책). 인출 후 현금 사용 추적 없음(범위 밖).

---

## 10. 간편결제 (`PF-EZP`)

```yaml
# PF-EZP-001 간편결제 앱 알림 (연결 카드 표기)
in: {source: PAY, title: "[테스트페이] 결제 완료", body: "테스트상호\n5,000원\n결제수단 테스트카드(1234)\n10/05 14:32"}
expect: {status: parsed, confidence: high, kind: purchase, direction: outflow,
         amount: {minor: 5000, currency: KRW}, flags: [easyPay(providerRaw: "테스트페이")],
         instrument: {type: unknown, maskedHint: "1234", displayNameRaw: "테스트카드"},
         counterparty: {merchantRaw: "테스트상호"}, issues: []}
         # instrument.type 은 수단이 체크/신용인지 알림이 말하지 않으면 unknown (카드 이름으로 추측 금지)
         # → instrumentHintMissing 은 아님(마스킹 힌트가 있음)

# PF-EZP-002 페이 잔액 충전 (소비 아님)
in: {source: PAY, body: "테스트페이 충전 50,000원\n출금계좌 123-***-456789\n10/05 14:32\n페이머니 잔액 80,000원"}
expect: {status: parsed, confidence: high, kind: walletTopUp, direction: outflow,
         amount: {minor: 50000, currency: KRW}, instrument: {type: prepaidWallet}, balanceAfter: {minor: 80000, currency: KRW},
         issues: []}
         # 출금계좌는 별도 힌트(sourceInstrumentHint). 어느 쪽이 대상 수단인지 라벨로 확정된 경우에만

# PF-EZP-003 같은 결제의 다른 소스 알림 (카드사 쪽)
in: {source: CARD, body: "신용 1234 승인\n5,000원 일시불\n10/05 14:32\n테스트페이_테스트상호"}
expect: {status: parsed, confidence: high, kind: purchase, amount: {minor: 5000, currency: KRW},
         counterparty: {merchantRaw: "테스트페이_테스트상호"}}
         # 001 과 003 은 같은 결제일 수 있다: fp.loose.v1 일치, fp.exact.v1 불일치(상호/수단이 다름)
```

① 자동 처리: 001, 002, 003 각각 가능. 단, **001과 003의 중복 여부는 parser가 모른다.**
② needsReview: 결제수단 표기 충돌, 충전의 대상/출처 라벨 불명, 앱 알림에 카드 정보 없음 + 금액 라벨 부재.
③ evidence: E0 + `fp.loose.v1`이 교차 소스 후보 탐지의 핵심. 001·003은 상호 문자열이 다르므로 exact는 달라도 loose는 같다 → 후속 계층에서 `ambiguousWithoutStrongIdentity`로 보내 **병합하지 않고 review**(D003). 같은 거래에 알림이 두 개 오는 경험이 없다는 사용자 설명이 있으므로 실제 데이터에서 확인 필요.
④ confidence: high.
⑤ edge: 간편결제 충전을 소비로 분류하면 충전 시와 사용 시 이중 계산 → `walletTopUp`을 반드시 분리. 페이 포인트/쿠폰 사용(할인 금액)은 `unsupportedEvent`. 간편결제 계좌이체 형 결제(계좌 직접 출금)는 수단 힌트가 계좌 → `kind=purchase`, `instrument.type=bankAccount`.

---

## 11. 해외 결제 (`PF-OVS`) — 원화 청구 해외 가맹점

```yaml
# PF-OVS-001 해외 가맹점, 원화 결제 (표기상 해외)
in: {source: CARD, title: "[테스트카드] 해외승인", body: "신용 5678 해외승인\n25,000원\n10/05 14:32\nTEST SHOP SEOUL KR\n원화결제"}
expect: {status: parsed, confidence: high, kind: purchase, amount: {minor: 25000, currency: KRW},
         flags: [overseas], counterparty: {merchantRaw: "TEST SHOP SEOUL KR"}, absent: [settlementAmount], issues: []}

# PF-OVS-002 해외 승인, 금액 통화 표기 없음
in: {source: CARD, body: "신용 5678 해외승인 25.00\n10/05 14:32\nTEST SHOP"}
expect: {status: needsReview, confidence: low, issues: [currencyAmbiguous]}
```

① 자동 처리: 001 가능.
② needsReview: 통화 표기 부재/모호, 원화결제 여부 불명(해외 알림 + 통화 라벨 없음).
③ evidence: E0. 해외 가맹점명은 대소문자·국가 접미사 변동이 큼 → exact 불일치는 상위 정규화 이후 merchant 비교에서 보완.
④ confidence: 001 high, 002 low.
⑤ edge: 원화결제(DCC)와 현지통화결제가 같은 `해외` 문구를 공유 → 통화 표기로만 구분(가정 금지). `overseas`는 문구 신호이지 가맹점 국가 검증이 아님.

---

## 12. 외화 결제 (`PF-FXC`)

```yaml
# PF-FXC-001 USD 거래 + 원화 청구 금액
in: {source: CARD, body: "신용 5678 해외승인\nUSD 12.34 (₩16,800)\n10/05 14:32\nTEST ONLINE SHOP"}
expect: {status: parsed, confidence: high, kind: purchase,
         amount: {minor: 1234, currency: USD}, settlementAmount: {minor: 16800, currency: KRW},
         flags: [overseas, foreignCurrency], issues: []}
         # 환율을 계산해 소수 처리하지 않는다. settlementAmount 는 알림이 말한 값만

# PF-FXC-002 USD, 원화 환산 없음
in: {source: CARD, body: "신용 5678 해외승인\nUSD 12.34\n10/05 14:32\nTEST ONLINE SHOP"}
expect: {status: parsed, confidence: high, amount: {minor: 1234, currency: USD}, absent: [settlementAmount], issues: []}

# PF-FXC-003 JPY (지수 0)
in: {source: CARD, body: "신용 5678 해외승인\nJPY 3,200\n10/05 14:32\nTEST SHOP TOKYO"}
expect: {status: parsed, amount: {minor: 3200, currency: JPY}}

# PF-FXC-004 "$" 기호만
in: {source: CARD, body: "신용 5678 해외승인\n$12.34\n10/05 14:32\nTEST SHOP"}
expect: {status: needsReview, confidence: low, issues: [currencyAmbiguous]}   # USD 로 가정하지 않는다

# PF-FXC-005 "예상 환산액" 표기
in: {source: CARD, body: "신용 5678 해외승인\nUSD 12.34\n예상 청구금액 약 16,800원\n10/05 14:32\nTEST SHOP"}
expect: {status: parsed, confidence: medium, amount: {minor: 1234, currency: USD},
         settlementAmount: nil, issues: []}
         # '약/예상'은 확정 금액이 아님 → settlementAmount 로 저장하지 않는다 (estimatedSettlement 를 별도 필드로 둘지는 열린 질문)

# PF-FXC-006 지원하지 않는 통화 코드
in: {source: CARD, body: "신용 5678 해외승인\nXYZ 12.34\n10/05 14:32\nTEST SHOP"}
expect: {status: needsReview, issues: [currencyUnsupported]}

# PF-FXC-007 소수 자릿수 오류
in: {source: CARD, body: "신용 5678 해외승인\nUSD 12.345\n10/05 14:32\nTEST SHOP"}
expect: {outcome: failed, failure: amountUnparseable}   # 통화 지수보다 자릿수가 많으면 반올림하지 않고 fail
```

① 자동 처리: 001–003 가능. 환율이 확정되는 청구 시점(매입)은 §17에서 다시 오며 금액이 달라질 수 있음.
② needsReview: 통화 모호(`$`/`¥`/단서 없음), 미지원 통화, 확정 금액과 예상 금액 혼재.
③ evidence: E0. `fp.loose.v1`는 거래 통화 금액 기준 → 같은 결제의 원화 청구 알림(KRW 금액)과는 **일치하지 않는다**(의도된 한계: 교차 통화 중복은 상위가 settlementAmount/시각으로 판단).
④ confidence: 001–003 high, 005 medium.
⑤ edge: 체크카드 해외결제는 amount=USD, balanceAfter=KRW(계약 §4.4, 통화 불일치 허용). 외화 취소/부분취소는 환율이 달라 반환 원화액이 다를 수 있음 → 취소의 `amount`는 알림이 말한 통화·금액 그대로. 통화 소수 자릿수 표(KRW/JPY 0, USD/EUR 2 …)를 한 곳에서 관리.

---

## 13. 교통 후불 결제 (`PF-TRN`)

```yaml
# PF-TRN-001 건별 승차
in: {source: TRANSIT, title: "[테스트교통] 후불 승차", body: "후불교통 승차 1,400원\n10/05 08:10\n테스트노선"}
expect: {status: parsed, kind: purchase, direction: outflow,
         amount: {minor: 1400, currency: KRW}, flags: [transit],
         instrument: {type: unknown}, counterparty: {merchantRaw: "테스트노선"},
         occurredAt: {iso: "2026-10-05T08:10:00+09:00", precision: minute, source: text},
         issues: [instrumentHintMissing], confidence: medium}   # soft → medium (high 아님)

# PF-TRN-002 기간 합산 정산 알림
in: {source: TRANSIT, body: "후불교통 10/01~10/05 이용 12회\n합계 16,800원"}
expect: {status: parsed, confidence: medium, kind: purchase, amount: {minor: 16800, currency: KRW},
         flags: [transit, aggregate],
         occurredAt: {iso: "2026-10-05", precision: day, source: text},    # 기간의 끝 날짜. period-key 가 기간 전체를 보존
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, period-key]}

# PF-TRN-003 합산 알림의 기간/건수 불명
in: {source: TRANSIT, body: "후불교통 이용 합계 16,800원"}
expect: {status: needsReview, issues: [parserUncertain]}
```

① 자동 처리: 001·002 가능하나 **건별(001)과 합산(002)이 함께 오면 이중 계산 위험** → 이중 계산 방지는 dedup/linking 책임(기간·건수·금액 합 evidence 제공). 003 불가.
② needsReview: 합산 알림에 기간/건수 불명, 승차/하차 요금 정산(차감) 문구 불명.
③ evidence: E0, `period-key`(기간·건수) — 상위가 건별 합과 비교.
④ confidence: 001 medium(수단 힌트 없음 −0.15), 002 medium, 003 low.
⑤ edge: 환승 할인은 마지막 하차에서 정산되어 승차 금액과 다를 수 있음 → 승차 금액을 확정 소비로 가정하지 않으나 parser 레벨에서는 알림이 말한 금액만. 선불 교통카드 충전은 `walletTopUp`(§10).

---

## 14. 정기결제 (`PF-SUB`)

```yaml
# PF-SUB-001 정기결제 승인
in: {source: CARD, title: "[테스트카드] 정기결제 승인", body: "신용 5678 정기결제 승인\n9,900원\n10/05 14:32\n테스트구독"}
expect: {status: parsed, confidence: high, kind: purchase, amount: {minor: 9900, currency: KRW},
         flags: [recurring], counterparty: {merchantRaw: "테스트구독"}, issues: []}
         # recurring 은 문구 신호만. 주기/다음 결제일/구독 객체 추론 금지

# PF-SUB-002 정기결제 실패 (거래 아님)
in: {source: CARD, body: "정기결제 실패\n9,900원\n10/05 14:32\n테스트구독\n카드 한도/잔액을 확인하세요"}
expect: {outcome: notTransaction, reason: declined}

# PF-SUB-003 정기결제 예정 안내
in: {source: CARD, body: "10/08 정기결제 예정\n9,900원\n테스트구독"}
expect: {outcome: notTransaction, reason: upcomingNotice}
```

① 자동 처리: 001 가능.
② needsReview: 정기 문구 + 금액 라벨 없음 등 공통 조건.
③ evidence: E0. 같은 구독이 매월 같은 금액·상호로 오므로 `fp.exact.v1`은 **날짜 부분 때문에** 월마다 다르다(시각이 fingerprint에 포함되는 이유). 시각이 없는 알림(§4.3 fallback)이라도 `occurredAt`은 알림 시각이라 월 단위로 달라진다.
④ confidence: 001 high.
⑤ edge: `정기` 문구가 있지만 일회성 결제(예: `정기점검` 안내)일 수 있음 — 금액+결제 문맥이 모두 있을 때만 거래. 가격 변동, 무료 체험 종료 안내는 notTransaction. 반복 패턴 탐지는 parser 밖(후속 분석).

---

## 15. 환불 (`PF-RFD`)

```yaml
# PF-RFD-001 환불 입금
in: {source: BANK, title: "[테스트은행] 입금", body: "123-***-456789\n환불 입금 15,000원\n10/05 14:32\n테스트상호\n잔액 85,000원"}
expect: {status: parsed, confidence: high, kind: refund, direction: inflow,
         amount: {minor: 15000, currency: KRW}, counterparty: {merchantRaw: "테스트상호"},
         balanceAfter: {minor: 85000, currency: KRW}, issues: []}
         # 원거래 연결은 상위 계층. parser 는 원거래를 모른다

# PF-RFD-002 환불 접수/예정 안내
in: {source: CARD, body: "환불이 접수되었습니다.\n영업일 3일 이내 처리됩니다.\n15,000원 테스트상호"}
expect: {outcome: candidate, status: waiting, kind: refund, issues: [pendingEvent], note: "금액이 있지만 확정 입금이 아님"}
         # Assembler 는 waitingForEvidence 로 변환. 원장 이벤트 아님. (pendingEvent 는 신규 issue 제안)

# PF-RFD-003 카드 취소가 아닌 환불 + 카드 문맥
in: {source: CARD, body: "신용 5678 환불 15,000원\n10/05 14:32\n테스트상호"}
expect: {status: parsed, kind: refund, direction: inflow, instrument: {type: creditCard, maskedHint: "5678"}}
         # 카드 문맥의 '환불'은 cancellation 과 동의어일 수 있으나 parser 는 문구대로 refund 로 분류. 병합은 상위
```

① 자동 처리: 001, 003 가능. 002는 원장 이벤트가 아니다.
② needsReview: 환불 문구와 입금/출금 방향 모순, 금액 복수.
③ evidence: E0, `balance-chain`. 환불은 원구매 알림과 금액이 같을 수 있음 → fingerprint의 kind/direction이 달라 일치하지 않는다(원거래 연결은 `original-approval-ref`가 있을 때만 후보).
④ confidence: 001 high, 003 high.
⑤ edge: 같은 반환의 취소 통지와 실제 입금 통지가 둘 다 올 수 있음(D004에서 "수집/검토 상태 머신은 별도"로 남긴 부분). parser는 두 알림을 `cancellation`과 `refund`(또는 `deposit`)로 독립 보고하고 연결은 상위. 환불 입금이 원구매 며칠 뒤여도 parser는 시점을 비교하지 않음.

---

## 16. 동일 거래 중복 알림 (`PF-DUP`)

```yaml
# PF-DUP-001 같은 sourceDeliveryID 재전달 (재시도)
in_a: {id: "raw-a", source: CARD, sourceDeliveryID: "d-77", body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
in_b: {id: "raw-b", source: CARD, sourceDeliveryID: "d-77", body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
expect_each: {status: parsed, evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, delivery-id]}
expect_pair: {delivery-id 값 동일, fp.exact.v1 동일, candidateID 상이}
             # 멱등 처리는 raw 계층(RawNotificationRepository 의 sourceDeliveryID 계약)/dedup 이 한다

# PF-DUP-002 같은 문구, 다른 ID/다른 delivery ID (전달 경로 상이 or 진짜 연속 결제)
in_a: {id: "raw-a", source: CARD, sourceDeliveryID: "d-1", body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
in_b: {id: "raw-b", source: CARD, sourceDeliveryID: "d-2", body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
expect_pair: {fp.exact.v1 동일, text-digest 동일, delivery-id 상이, 두 candidate 독립 존재}
             # parser 는 둘 다 정상 결과로 반환. 같은 거래인지는 dedup → 강한 ID 없음 → review (D003)

# PF-DUP-003 30초 간격 연속 결제 (D003 예시: 10,000원 소비여야 함)
in_a: {id: "raw-a", source: CARD, body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호", capturedAt: "T0"}
in_b: {id: "raw-b", source: CARD, body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호", capturedAt: "T0+30s"}
expect_pair: {fp.exact.v1 동일(분 단위 구별 불가), 두 candidate 독립}

# PF-DUP-004 delivery ID 없이 두 소스에서 같은 거래 (카드 앱 + 은행 앱)
in_a: {source: CARD, body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
in_b: {source: BANK, body: "체크카드 5,000원 출금\n10/05 14:32\n테스트상호\n잔액 100,000원"}
expect_pair: {fp.loose.v1 동일, fp.exact.v1 상이(수단/상호 표기가 다름), 각자 독립 결과}
```

① 자동 처리: 각 알림은 독립적으로 parsed 가능. 쌍 단위 결정은 parser 책임 아님.
② needsReview: parser 레벨에서는 중복 때문에 review를 올리지 않는다. 그 판단은 Deduplication 계층이 `ambiguousWithoutStrongIdentity`/`conflictingStrongIdentity`로.
③ evidence: 핵심 fixture. 강/약 evidence 구분: `delivery-id`(strong, scope=app), `fp.exact.v1`/`fp.loose.v1`/`text-digest`(weak). **text-digest 일치 ≠ 같은 거래**를 계약 문서에서 명시한다.
④ confidence: high.
⑤ edge: 004의 `fp.loose.v1` 일치는 "병합 후보" 신호지 병합 근거가 아님. 분 단위 시각이 같은 연속 결제(003)는 parser 출력만으로 구별 불가능 → `occurredAt.precision=minute`를 정확히 보고하는 것이 중요(초 단위인 것처럼 속이지 않기).

---

## 17. 승인/매입 시점 차이 (`PF-SET`)

```yaml
# PF-SET-001 승인 알림 (구매 시점)
in: {source: CARD, body: "신용 5678 승인\n12,300원 일시불\n10/05 14:32\n테스트상호\n승인번호 55667788"}
expect: {status: parsed, kind: purchase, amount: {minor: 12300, currency: KRW},
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, approval-no]}   # approval-no: 55667788, scope=(test-card, 5678, 12300, 2026-10-05)

# PF-SET-002 매입(청구 확정) 통지, 며칠 뒤
in: {source: CARD, notificationAt: "2026-10-08T09:00:00+09:00",
     body: "신용 5678 매입\n12,300원\n승인일 10/05\n테스트상호\n승인번호 55667788"}
expect: {status: parsed, confidence: high, kind: purchaseSettlementNotice, direction: neutral,
         amount: {minor: 12300, currency: KRW},
         occurredAt: {iso: "2026-10-05", precision: day, source: text},     # '승인일'. 매입일(10/08)은 별도 필드(settledOn)로 보존 제안
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, approval-no, settlement-link]}
         # 새로운 소비를 만드는 이벤트가 아니다. 001 과 같은 승인번호 → 연결 후보

# PF-SET-003 매입 금액이 승인과 다른 알림 내부 모순
in: {source: CARD, body: "신용 5678 매입 12,800원\n승인금액 12,300원\n승인일 10/05\n테스트상호"}
expect: {status: needsReview, issues: [settlementAmountMismatch]}

# PF-SET-004 외화 매입 (환율 확정)
in: {source: CARD, body: "신용 5678 해외매입\nUSD 12.34\n청구금액 16,900원\n승인일 10/05\nTEST ONLINE SHOP"}
expect: {status: parsed, kind: purchaseSettlementNotice, amount: {minor: 1234, currency: USD}, settlementAmount: {minor: 16900, currency: KRW}}
```

① 자동 처리: 001, 002, 004 가능(parser 관점). **002가 새 지출로 두 번 반영되면 소비가 이중이 된다 → `kind`가 `purchaseSettlementNotice`/`direction=neutral`로 명시되어야 한다.** 연결/중복 방지는 상위 계층.
② needsReview: 알림 내 모순(003), 매입 문구 + 취소 신호 동시 존재, 승인일 불명.
③ evidence: `approval-no`(scoped), `settlement-link`, 기본 세트. 같은 승인번호/수단/금액이면 승인 알림과 매입 통지를 이을 후보 → 판단은 dedup/linking.
④ confidence: high.
⑤ edge: 승인번호가 없는 매입은 금액·가맹점·승인일로만 이을 수 있음(weak) → 상위 review. 매입 통지가 원승인의 금액과 다르면(팁, 환율, 부분 매입) 승인금액을 덮어쓰지 않고 별도 사실로 둔다. 매입이 승인 알림보다 **먼저** 처리되는 순서 역전도 가능.

---

## 18. 잔액 포함 / 미포함 (`PF-BAL`)

`PF-DEB-001/002`, `PF-WDR-001`, `PF-DEP-001`, `PF-TRF-001`, `PF-ATM-001`이 이미 포함·미포함을 커버한다. 추가 경계 fixture:

```yaml
# PF-BAL-001 잔액 라벨 없는 숫자
in: {source: BANK, body: "123-***-456789 출금 30,000원 10/05 14:32 70,000원"}
expect: {status: needsReview, confidence: low, issues: [amountAmbiguous]}   # 라벨 없는 두 번째 금액을 잔액으로 단정하지 않는다

# PF-BAL-002 잔액이 amount 보다 앞에 등장
in: {source: BANK, body: "잔액 70,000원\n123-***-456789 출금 30,000원 10/05 14:32"}
expect: {status: parsed, amount: {minor: 30000, currency: KRW}, balanceAfter: {minor: 70000, currency: KRW}}   # 순서가 아니라 라벨로 결정

# PF-BAL-003 잔액 통화 표기 불명
in: {source: BANK, body: "123-***-456789 출금 30,000원 10/05 14:32 잔액 70,000"}
expect: {status: parsed, confidence: medium, balanceAfter: nil, issues: []}
         # 통화 단서 없는 잔액은 보존하지 않는다(금액은 확정이므로 거래 자체는 영향 없음). 폐기 사실은 provenance 에만 남김

# PF-BAL-004 잔액이 amount 와 모순 (잔액 < 0, 부호 포함)
in: {source: BANK, body: "123-***-456789 출금 30,000원 10/05 14:32 잔액 -5,000원"}
expect: {status: needsReview, issues: [parserUncertain]}   # 음수 잔액 정책은 열린 질문
```

① 자동 처리: 001 불가, 002 가능, 003 가능, 004 불가.
② needsReview: 라벨 없는 복수 금액, 음수 잔액.
③ evidence: `balance-chain`은 `balanceAfter`가 확정된 경우에만 생성.
④ confidence: 001 low, 002 high, 003 medium.
⑤ edge: 잔액 수치가 알림 도착 순서와 거래 순서가 다를 때 오래된 알림의 잔액이 최신 잔액을 덮어쓰면 안 됨 — parser는 `balanceAfter`와 `occurredAt`을 함께 보고하고 갱신 정책은 상위. 신용카드의 잔여한도는 `PF-CRD-003`처럼 `balanceAfter`가 아니다.

---

## 19. 상호/상대방 불명확 (`PF-MER`)

```yaml
# PF-MER-001 상호 슬롯 없음
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32"}
expect: {status: parsed, confidence: medium, kind: purchase, counterparty: {merchantRaw: nil}, issues: [merchantMissing]}

# PF-MER-002 결제대행사/약어 형태의 상호 — 원문 그대로 보존, 해석하지 않음
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\nTESTPG*TESTSHOP 1234"}
expect: {status: parsed, confidence: high, counterparty: {merchantRaw: "TESTPG*TESTSHOP 1234"}, issues: []}
         # 'TESTPG*'를 떼거나 소문자화하는 처리는 normalization 계층. parser 의 raw 보존이 계약

# PF-MER-003 상호에 키워드 포함 (분류 오염 방지)
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\n테스트취소식당"}
expect: {kind: purchase, counterparty: {merchantRaw: "테스트취소식당"}}

# PF-MER-004 상호가 여러 줄/공백 변형
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\n　테스트　상호　"}   # 전각 공백
expect: {counterparty: {merchantRaw: "테스트 상호"}}   # NotificationText.normalize 수준까지만 (전각→반각 공백, trim)
```

① 자동 처리: 001 가능(medium) — Q3의 결정에 따름(계약 §9). 002–004 가능.
② needsReview: 상호 슬롯이 둘 이상이고 확정 불가, 상호 문자열이 금액/날짜 토큰과 구분 불가.
③ evidence: `fp.exact.v1`에 `merchantRaw`가 들어가므로 상호 부재(001)는 `merchantRaw=""`로 직렬화(널 구분자 일관성).
④ confidence: 001 medium, 나머지 high.
⑤ edge: "상호를 못 알아본 이유가 알림에 상호가 없는 것인지, template이 없어서인지"를 구분 — 잔여 텍스트에 금액/날짜가 아닌 문자열이 남아 있으면 `merchantMissing` 대신 `parserUncertain`(템플릿 불일치 의심)을 고려(열린 질문). 결제 대행사(PG) 이름이 실제 판매처가 아닐 수 있음을 아는 것은 상위 normalization.

---

## 20. Strong transaction ID 없음 (`PF-NID`)

```yaml
# PF-NID-001 sourceDeliveryID 없음, provider 거래번호 없음, 승인번호 없음
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\n테스트상호"}   # sourceDeliveryID 없음
expect: {status: parsed, confidence: high,
         evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest],   # strong evidence 없음
         absentEvidence: [delivery-id, provider-txn-id, approval-no]}

# PF-NID-002 숫자열이 있지만 라벨이 없음 (ID로 오인 금지)
in: {source: CARD, body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\n테스트상호\n99887766"}
expect: {status: parsed, confidence: medium,
         absentEvidence: [provider-txn-id, approval-no],
         note: "라벨 없는 숫자열은 evidence 로 만들지 않고 잔여 텍스트로 취급"}
         # residual 숫자 토큰 → 계약 §7 −0.20 → medium

# PF-NID-003 sourceDeliveryID 만 있음
in: {source: CARD, sourceDeliveryID: "d-9", body: "신용 5678 승인 12,300원 일시불\n10/05 14:32\n테스트상호"}
expect: {evidenceKinds: [fp.exact.v1, fp.loose.v1, text-digest, delivery-id]}   # 같은 delivery id 재처리는 raw 계층 멱등; 다른 알림과의 거래 동일성 근거는 아님
```

① 자동 처리: 가능 — **strong ID가 없다는 것은 parser가 review를 올릴 이유가 아니다.** 유사 후보가 이미 있을 때만 상위가 `ambiguousWithoutStrongIdentity`(D003).
② needsReview: 해당 없음(ID 부재만으로는 parser 단에서 review 안 함).
③ evidence: fingerprint 세트만. 어떤 fingerprint도 "강함"으로 표기하지 않는다(weak).
④ confidence: 001 high, 002 medium.
⑤ edge: 라벨 없는 숫자열을 승인번호로 승격하는 "똑똑한" 추측은 금지(고유성이 보장되지 않아 서로 다른 거래가 병합될 수 있음).

---

## 21. 비거래/실패/파싱 안전성 (`PF-NEG`, `PF-MUT`)

```yaml
# PF-NEG-001 인증번호
in: {source: BANK, body: "[테스트은행] 인증번호 123456 (유효 3분)"}
expect: {outcome: notTransaction, reason: authCode}

# PF-NEG-002 광고/이벤트
in: {source: CARD, body: "(광고) 이번 달 결제 시 최대 10,000원 캐시백 이벤트"}
expect: {outcome: notTransaction, reason: promotion}   # 금액이 있어도 거래가 아니다

# PF-NEG-003 승인 거절
in: {source: CARD, body: "신용 5678 승인거절 12,300원 한도초과\n10/05 14:32\n테스트상호"}
expect: {outcome: notTransaction, reason: declined}    # '승인' 포함 문구지만 거래 아님. 순위 1 규칙

# PF-NEG-004 잔액/한도 조회성 안내
in: {source: BANK, body: "123-***-456789 현재 잔액 100,000원"}
expect: {outcome: notTransaction, reason: balanceInquiry}

# PF-NEG-005 금융처럼 보이지만 템플릿 불명
in: {source: BANK, body: "테스트 금융 알림: 계좌 상태가 변경되었습니다"}
expect: {outcome: notTransaction, reason: unrecognized}   # 금액·방향이 없고 거래 키워드 부재

# PF-NEG-006 거래 키워드는 있으나 금액 없음
in: {source: CARD, body: "신용 5678 승인\n10/05 14:32\n테스트상호"}
expect: {outcome: failed, failure: amountMissing}          # 금액을 0원/추정값으로 채우지 않는다

# PF-NEG-007 복수 거래 요약
in: {source: CARD, body: "오늘 이용내역\n10/05 14:32 테스트상호 5,000원\n10/05 15:10 테스트상호2 3,000원"}
expect: {outcome: failed, failure: multipleTransactionsInOne}   # v1: 첫 건만 취하지 않는다

# PF-MUT-001 시각 malformed
in: {source: CARD, body: "신용 5678 승인 5,000원 일시불\n13/45 25:61\n테스트상호"}
expect: {outcome: candidate, status: needsReview, issues: [timeMalformed], occurredAt: nil}   # 알림 시각으로 대체하지 않는다

# PF-MUT-002 금액 형식 오류
in: {source: CARD, body: "신용 5678 승인 5,00원 일시불\n10/05 14:32\n테스트상호"}
expect: {outcome: failed, failure: amountUnparseable}

# PF-MUT-003 한글 수사 금액 (미지원)
in: {source: CARD, body: "신용 5678 승인 5천원 일시불\n10/05 14:32\n테스트상호"}
expect: {outcome: failed, failure: amountUnparseable}   # 미지원 표기는 추측 파싱하지 않고 fail

# PF-MUT-004 0원 승인
in: {source: CARD, body: "신용 5678 승인 0원\n10/05 14:32\n테스트상호"}
expect: {status: needsReview, issues: [amountZero]}

# PF-MUT-005 연도 경계 (연말 거래를 연초에 수신)
context: {referenceTime: "2027-01-01T00:05:00+09:00"}
in: {source: CARD, body: "신용 5678 승인 5,000원 일시불\n12/31 23:58\n테스트상호"}
expect: {status: parsed, occurredAt: {iso: "2026-12-31T23:58:00+09:00", precision: minute, source: text}}   # 2027 로 추정하지 않는다

# PF-MUT-006 시각 absent + 월 경계
in: {source: CARD, notificationAt: "2026-10-31T23:58:00+09:00", body: "체크 1234 승인 5,000원\n테스트상호"}
expect: {status: needsReview, issues: [timeAbsentFallback, timeBoundaryRisk]}   # 예산 월(10/11)이 바뀔 수 있음

# PF-MUT-007 원문 시각과 알림 시각이 크게 어긋남
in: {source: CARD, notificationAt: "2026-10-09T10:00:00+09:00", body: "체크 1234 승인 5,000원\n10/05 14:32\n테스트상호"}
expect: {status: parsed, confidence: medium, occurredAt: {iso: "2026-10-05T14:32:00+09:00", source: text}, issues: [timeSkewSuspicious]}

# PF-MUT-008 같은 텍스트가 title/subtitle/body 에 분산 (I7)
in_a: {source: CARD, title: "체크 1234 승인", subtitle: "5,000원 일시불", body: "10/05 14:32\n테스트상호"}
in_b: {source: CARD, body: "체크 1234 승인\n5,000원 일시불\n10/05 14:32\n테스트상호"}
expect_pair: {결과의 거래 필드 동일 (rawNotificationID/candidateID 제외)}

# PF-MUT-009 CRLF / NBSP / 전각 공백 변형 (I7)
in: {source: CARD, body: "체크 1234 승인\r\n5,000원 일시불\r\n10/05 14:32\r\n테스트상호"}
expect_equals: PF-DEB-002 결과 (거래 필드 동일)
```

① 자동 처리: 해당 없음. `notTransaction`은 candidate를 만들지 않고 분류 결과만 raw에 기록한다(원본은 보존). `failed`는 내용 없는 `needsReview + parserUncertain`으로 상위에서 사용자 확인. `PF-MUT-005`/`007`은 가능.
② needsReview: 위 각 fixture.
③ evidence: `failed`/`notTransaction`은 evidence를 만들지 않는다(필수 필드 없음). `text-digest`만 raw 계층에 기록 가능.
④ confidence: 비거래/failed는 없음(해당 없음). `PF-MUT-001/004/006`는 low.
⑤ edge: `PF-NEG-003`의 `승인` 포함 문구, `PF-MUT-003`의 `5천원`처럼 "아는 척하면 틀리는" 경계가 이 절의 목적. 새 provider 문구 변형이 제보되면 **fixture를 먼저 추가하고(red) rule을 확장**한다.

---

## 22. 요약 매트릭스

| 케이스 | 대표 fixture | kind | 자동 처리(parser) | 대표 review 조건 | 핵심 evidence | confidence |
|---|---|---|---|---|---|---|
| 체크카드 결제 | PF-DEB-001 | purchase | O | 방향/금액 모호, 시각 경계 | fp, balance-chain | high |
| 신용카드 승인 | PF-CRD-001 | purchase | O | 라벨 없는 복수 금액 | fp, approval-no | high |
| 승인 취소 | PF-CXL-001 | cancellation | O | 방향 모순 | fp, original-approval-ref | high |
| 부분 취소 | PF-PCX-001 | cancellation(partial) | O | 산술 불일치 | original-approval-ref | high |
| 계좌 출금 | PF-WDR-001 | withdrawal | O | 방향 불명 | fp, balance-chain | high |
| 계좌 입금 | PF-DEP-001 | deposit | O | 방향 모순 | fp, balance-chain | high |
| 계좌이체 | PF-TRF-001/002 | transferOut/In | O(한 다리) | 방향 불명 | fp, balance-chain | high |
| 카드대금 | PF-BIL-001 | cardBillPayment | O | 대금 라벨 없음 | fp, balance-chain | high / low |
| ATM 출금 | PF-ATM-001 | cashWithdrawal | O | 총액/수수료 분리 불가 | fp, balance-chain | high |
| 간편결제 | PF-EZP-001 | purchase / walletTopUp | O | 결제수단 충돌 | fp.loose(교차 소스) | high |
| 해외 결제 | PF-OVS-001 | purchase | O | 통화 불명 | fp | high |
| 외화 결제 | PF-FXC-001 | purchase(USD) | O | `$` 모호, 미지원 통화 | fp | high |
| 교통 후불 | PF-TRN-001/002 | purchase | O(medium) | 합산 기간 불명 | period-key | medium |
| 정기결제 | PF-SUB-001 | purchase(recurring) | O | 금액 라벨 없음 | fp | high |
| 환불 | PF-RFD-001 | refund | O | 방향 모순 | fp, balance-chain | high |
| 중복 알림 | PF-DUP-001..004 | — | 각 알림 독립 | (parser는 review 안 올림) | delivery-id, fp, text-digest | high |
| 승인/매입 | PF-SET-001/002 | purchase / settlementNotice | O | 내부 모순 | approval-no, settlement-link | high |
| 잔액 포함/없음 | PF-BAL-* | — | O/X | 라벨 없는 금액 | balance-chain | high–low |
| 상호 불명확 | PF-MER-001 | purchase | O(medium) | 상호 슬롯 모호 | fp | medium |
| Strong ID 없음 | PF-NID-001 | purchase | O | **해당 없음** | fp 세트(weak) | high |
| 비거래/실패 | PF-NEG/MUT-* | — | candidate 없음/failed | 모든 fail-safe | — | — |

## 23. 새로 제안하는 항목 (구현 에이전트 합의 필요)

- `ParserIssue.pendingEvent`(환불 예정 등 거래 확정 전 통지) → Assembler가 `waitingForEvidence`로 변환(PF-RFD-002).
- `occurredAt`과 별개로 `settledOn`(매입일)을 둘지(PF-SET-002).
- `estimatedSettlementAmount`(약/예상 환산액) 별도 필드 여부(PF-FXC-005).
- 음수 잔액 표기 정책(PF-BAL-004, PF-WDR 5절 edge).
- `merchantMissing` vs 템플릿 불일치 의심의 구분 기준(PF-MER).
- 이 matrix의 hard/soft 등급과 confidence 감점값은 **초기 제안**이며, 실제 알림 샘플을 가져오면 fixture와 함께 조정한다.
