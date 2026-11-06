# Red-team 검토: Core + Parser + Promotion

상태: A–F와 부록 A는 **분석 기록**(`d3dec97` 기준, 당시 코드 변경 없음). **현재 R1–R9 상태와 남은 위험의 기준은 §I**(resolved / mitigated / deferred / unresolved).
검토 기준 코드: `origin/feat/notification-parser` @ `d3dec97` (그 아래 `feat/candidate-promotion` @ `0aec2f1`, `feat/core-domain-storage` @ `c81e730` 포함).
**§G·§H는 `refactor/ingestion-pipeline` @ `91143ee` 시점의 중간 재검증이며, 이후 수정을 반영한 최종 상태는 §I.**
관련 문서: [parser-contract.md](parser-contract.md), [parser-fixtures.md](parser-fixtures.md)(이 문서의 설계 초안. **구현은 이 초안과 다르게 갔다** — §0 참조).

## 0. 방법과 표기

현재 이 워크트리 브랜치(`claude/...-d3c724`)에는 parser/promotion 구현이 없고 별도 원격 브랜치에 있다. 구현을 읽은 뒤, 의심되는 동작은 **저장소 밖 임시 디렉터리에 브랜치를 내보내 탐침 테스트로 실제 실행**했다(저장소 변경 없음, 29개 시나리오). 근거 표기:

| 표기 | 의미 |
|---|---|
| ✅ | 탐침으로 **실행해서 재현**함 |
| 📖 | 코드를 읽고 판단함(미실행). 코드 경로가 명확한 경우만 사용 |
| 💭 | 추론. 구현 에이전트가 먼저 테스트로 확인해야 함 |

재현 입력과 관찰 결과는 부록 A. 실제 금융사 포맷은 사용하지 않았고 모든 입력은 합성이다.

**앞서 제안한 설계와 구현의 차이.** parser-contract.md는 (1) parser가 `ready`를 만들지 않고, (2) 계좌 바인딩은 별도 Resolver가 하며, (3) provider reference는 identity가 아니라 evidence이고, (4) 금액은 라벨 기반으로만 읽고, (5) 방향(direction)을 필수 필드로 보고, (6) 거래 시각은 본문에서 읽는 것을 전제했다. 구현은 이 중 거의 반대로 갔다: parser가 `ready`+`LedgerEntry`를 직접 만들고, 바인딩은 파싱 전에 `NotificationParsingContext`로 주입되고, reference가 candidate/entry ID가 되고, 금액은 "첫 번째 `원` 줄"이고, 방향 개념이 없고, 시각은 알림 게시 시각만 쓴다. 아래 critical 항목 대부분이 이 차이에서 나온다.

## 총평 (먼저)

- **Ledger 자체의 불변식(전표 형태, 합계 0, 원금 초과 환불 차단, 증거 단일 소비, 원자 커밋)은 탄탄하다.** 깨지는 곳은 그 위층이다.
- **현재 파이프라인(`parse → process`)을 그대로 연결하면 MVP로 안전하지 않다.** 재현된 바로는 승인 *거절* 알림이 지출로, `이체 입금`이 방향 반대로, 같은 결제의 카드앱+페이앱 알림이 이중 지출로, `총 30,000원 중 10,000원 취소`가 30,000원 환불로 원장에 들어간다. 모두 `ready` → 자동 승격된다.
- 원인은 한 가지로 요약된다: **parser가 `ready`를 직접 만들 수 있고, 그 사이에 dedup/상관(correlation) 게이트가 없고, 원장에는 잘못 들어간 항목을 되돌릴 방법이 없다.**
- 결론은 §F: 5가지를 먼저 고치면 MVP 기준으로 충분하다.

---

## A. Critical risks (출시 전 필수)

### R1. 분류가 fail-open이다 — 거절/예정/요청/안내가 거래가 된다 ✅
`classify`는 부분 문자열(`취소·환불 → 카드대금 → 이체·송금 → 입금 → 승인·사용·결제`)로 종류를 정하고, `ready`의 유일한 추가 관문은 `거래번호`/`승인번호` **라벨 줄의 존재**다.
- `신용 5678 승인거절 12,300원 한도초과 / 승인번호 777` → `ready` 지출 12,300 (✅ A). `승인`이 들어있다는 이유로.
- `송금 요청 20,000원 도착 / 거래번호 R1` → `ready` 이체 (✅ E10). `이체한도 5,000,000원으로 변경 / 거래번호 L1` → `ready` 이체 5,000,000 (✅ E11). `(광고) 결제 시 최대 10,000원 캐시백 / 거래번호 AD1` → `ready` 지출 (✅ E9).
- 부정 신호(거절/실패/예정/요청/한도/예약/안내/광고) 검사가 분류보다 먼저 없다. 사용자·상대방이 통제하는 텍스트(입금자명, 메모, 가맹점명)가 분류와 reference 추출에 그대로 들어간다(💭, R9 참조).
- 현재 구현이 안전해 보이는 것은 대부분 "라벨 줄이 없으면 needsReview"라는 우연한 관문 덕이다. 라벨이 있는 실제 알림(승인 알림 전반)에서는 관문이 열린다.

### R2. 방향(direction)이 모델에 없다 ✅
- `이체 입금 200,000원` → 입금 받는 계좌가 **출금 계좌로** 기록(`bank-main:-200000`, 상대 `+200000`) (✅ B).
- 계좌 간 이체의 양쪽 알림을 모두 처리하면 이체 200,000원이 **수신 계좌에 +400,000**으로 남는다. 출금 쪽은 `transfer`, 입금 쪽 `입금`은 `income` (✅ J: 시작 0 → 350,000, 입금 계좌는 이체 200,000 + 소득 200,000 − 역방향 50,000).
- `출금`/`ATM 출금`/`수수료 출금`은 지원 안 함 → `rejected(unsupportedEvent)` (✅ C). **`rejected`는 사용자에게 보이는 review 대상이 아니다.** 실제 돈이 움직였는데 원장에 없고 아무도 모른다 → 계좌 잔액이 조용히 틀어진다.

### R3. parser `ready`가 곧바로 승격되고, 그 사이에 dedup 게이트가 없다 ✅
- `process`는 `ready`면 즉시 원장에 쓴다. 상관(correlator)/검증 단계가 구조적으로 강제되지 않는다. 문서(`notification-parser.md`)는 "correlator/review"를 말하지만 코드에는 **없다**.
- 같은 결제를 카드앱(`app.card`)과 페이앱(`app.pay`)이 같은 승인번호로 알리면 둘 다 승격(✅ G1+G2: 7,000원 → 부채 14,000). candidate/entry ID에 `applicationIdentifier`가 들어가 서로 다른 앱은 서로 다른 거래가 된다.
- 같은 앱의 재전송(문자+푸시)은 이중 반영은 막히지만 **예외**로 막힌다(R7, ✅ G3).

### R4. 금액 선택이 "첫 번째 `원` 줄"이다 ✅
금액 라벨 문법이 없다(`잔액` 포함 줄만 제외).
- `승인취소 / 총 30,000원 중 10,000원 취소 / 원승인번호 O1 / 승인번호 C1` → `ready` 환불 **30,000** (✅ D). 부분취소가 전액취소로 기록되고 원금 상한 검사를 통과한다.
- `누적 사용액 450,000원 / 승인 12,300원` → 지출 **450,000** (✅ E2).
- `신용 5678 원화결제 25,000원` → `원`(원화결제의 첫 글자) 앞 숫자 `5678` → 지출 **5,678** (✅ E1).
- `승인 5,000.50원` → **50**원 (✅ E4). 소수점이 숫자 토큰을 끊는다.
- `해외승인 USD 12.34 (약 16,800원)` → KRW 16,800 지출로 `ready` (✅ E7). **예상** 환산액을 확정 금액으로 기록. 이후 매입 통지가 오면 둘째 지출(R3).
- `99999999999999999999원` → `ready`가 아니라 **예외 `amountOverflow`** (✅). 악의적/오류 입력 하나가 배치를 멈춘다(R7).
- (안전하게 실패하는 경우: `원조할머니 5,000원`, `원두 5,000원` → `missingAmount` review ✅ E5/E6. 한글 수사 `5천원`도 review 📖.)

### R5. 후보/전표 identity가 `(앱, 행위, 승인번호)`다 ✅
- 같은 앱, 같은 승인번호, **다른 두 번의 실제 결제**(다른 금액/가게): 두 번째가 `conflictingCandidate`로 **예외** (✅ F2). 실제 지출 하나가 누락되고 파이프라인은 같은 항목에서 계속 막힌다. 승인번호는 일 단위/카드사 범위에서만 유일하다(parser-contract §8 `approval-no`는 scoped로 본 이유).
- 같은 줄에 reference가 붙는지 여부로 ID가 달라진다: `승인 5,000원 일시불 승인번호 55667788 10/05` → reference `"55667788 10/05"`, 줄을 나누면 `"55667788"` (✅ 서로 다른 ID). 같은 거래가 레이아웃에 따라 다른 거래가 된다.
- 환불의 `adjustmentOriginalsByProviderReference`는 문자열 키만 사용(앱/카드/금액/일자 범위 없음) → 승인번호가 우연히 겹치는 다른 카드의 원거래에 환불이 연결될 수 있다 (📖).
- 매입 통지(`매입 12,300원 / 승인일 10/05 / 승인번호 ...`)는 `승인`을 포함해 지출로 분류된다 (📖). 같은 앱이면 R7, 다른 앱이면 이중 지출.

### R6. 예산 월이 거래 시각이 아니라 처리 시점의 `currentBudgetMonth`다 ✅
- `BudgetImpact.attributedMonth`는 지출에서 `context.currentBudgetMonth`로 정해진다. 10/31 23:58 승인 알림을 11/01에 처리하면 11월 소비가 된다 (✅ H: context 11월 → 11월).
- 거래 시각(`occurredAt`)은 알림 **게시** 시각뿐이다(본문 시각은 읽지 않음). 오프라인/절전 지연, Shortcut 지연, 시간대 이동에서 날짜가 틀린다.
- 환불은 원거래 월을 따르므로 지출이 잘못된 월이면 환불도 연쇄로 틀린다.
- 불변식 부재: `attributedMonth == month(occurredAt, userTimeZone)`을 어디서도 검사하지 않는다.

### R7. 영구적 오류가 "poison 항목"이 된다 ✅
`process`는 승격 시 검증 실패를 **예외로 던지고 candidate를 저장하지 않는다.**
- `이체 취소 / 원거래번호 TT1` + 원거래가 이체 전표 → parser는 `ready` 환불을 만들고 `process`는 `adjustmentTargetIsNotExpense`를 던짐, 후보 저장 0건 (✅ K, P2). 해당 알림은 review 목록에도 안 나타나고 재시도해도 같은 예외다.
- 동일 원인: 원금 초과 환불(승인취소+매입취소 두 통지, FX 환율 상승 시 환불액 > 원금), 비활성 계좌/카드(📖), 중복 증거, `amountOverflow`.
- 재파싱도 막힌다: 같은 raw ID가 처음엔 reference 없이 파싱돼 `candidate/raw/rp`로 저장된 뒤, parser가 reference를 인식하게 되면 새 ID로 만들어져 `evidenceAlreadyClaimed` (✅). `needsReview`가 증거를 붙잡고 있어서 병합/대체도 못 한다.
- parser 버전이 바뀌면 `policyVersion`이 달라져 이미 승격된 candidate와 `==`가 아니므로 `alreadyPromoted`가 아니라 `conflictingCandidate` (📖).

### R8. 계좌/카드 바인딩이 파싱 **전에** 소스 단위로 고정된다 📖
- `NotificationParsingContext.binding`은 단일 값이며 raw 텍스트를 보고 정할 수 없다(파싱 전 필요). 같은 은행 앱에 계좌가 여러 개이거나 같은 카드사에 카드가 여러 장이면 모든 알림이 같은 계좌/카드에 기록된다.
- parser는 알림 본문의 계좌/카드 끝자리(마스킹 힌트)를 읽지도, binding과 대조하지도 않는다. 불일치 시 `bindingMismatch` 같은 반응이 없다.
- 카드 재발급(번호 변경), 계좌/카드 비활성화 후 과거 알림 재처리도 처리 규칙이 없다(비활성 → 승격 시 예외, R7).

### R9. 잘못 승격된 항목을 되돌릴 방법이 없다 📖
- 원장은 append-only이고 정정 수단은 "expense에 대한 return adjustment(원금 이하)"뿐이다. income/transfer/cardPayment는 정정할 방법이 없고, 증거(raw ID)는 계속 점유된다(`evidenceAlreadyUsed`).
- R1–R5가 `ready`를 자동 승격하므로 오탐의 비용이 영구적이다. 사용자 수동 수정/삭제 흐름도 설계에 없다.

> 추가 critical(온보딩): **`Account.openingBalance`에 기준 시각이 없다** 📖. 현재 잔액으로 계좌를 만든 뒤 과거 알림을 재처리/백필하면 이미 잔액에 반영된 거래가 다시 더해진다. 계좌 생성 이전 알림은 거부하거나 review로 보내는 불변식이 필요하다(§D의 `openingBalanceAsOf`).

---

## B. Edge-case matrix

범례 — **현재**: ✅재현/📖판독/💭추론. **sev**: critical(조용히 틀린 금액·영구 손상) / high(예외·누락·과다 review로 운영 불가 또는 큰 오차) / medium / low. **MVP**: `필수`(출시 전 해결), `보강`(권장), `보류`(MVP 밖, 단 안전하게 review로 떨어져야 함).

### B1. 거래 생명주기

| ID | scenario | 현재 설계의 예상 동작 | 잘못될 수 있는 점 | 필요한 invariant | 필요한 test | sev / MVP |
|---|---|---|---|---|---|---|
| L1 | 승인 → 승인취소(전액), 취소 알림에 자체 번호 없고 원번호만 있음 | 📖 `currentProviderReference`가 `원승인` 줄 제외 → reference nil → `ambiguousWithoutStrongIdentity` review | 취소 알림 대부분이 영구 review(과다 review). 반대로 자체 번호가 있으면 `ready` | 취소의 강한 근거는 "원번호 + 금액"; 자체 ID 부재는 review 사유가 아님 | 원번호만 있는 취소 → 원거래 있으면 환불 후보, 없으면 `waitingForEvidence` | high / 필수 |
| L2 | 취소 후 재승인(같은 금액·가게, 새 승인번호) | 독립 처리, 각자 ref ID | 업체가 승인번호를 재사용하면 R5 충돌(예외) | identity가 ref에 의존하지 않을 것 | 같은 ref·다른 raw 두 건 → 둘 다 보존 또는 둘 다 review, 예외 없음 | high / 필수 |
| L3 | 승인 후 며칠 뒤 **매입** 통지 | 📖 `매입` 키워드 없음, 본문의 `승인일/승인번호`의 `승인`으로 지출 분류 | 같은 앱·ref면 `conflictingCandidate` 예외, 다른 앱이면 이중 지출 | 매입은 새 소비 아님(`settlement` 종류 또는 review) | 승인+매입 → 소비 1회, 매입은 연결 후보 | critical / 필수 |
| L4 | 승인취소 + 매입취소 두 통지 | 📖 둘 다 `adjustment`; 합이 원금 초과면 두 번째 `adjustmentExceedsOriginal` 예외 | 정상 중복 통지가 poison | 취소 중복은 typed 결과(`duplicateOf`)로 처리 | 전액취소 2회 → 두 번째는 review, 원장 불변, 예외 없음 | high / 필수 |
| L5 | 부분 취소(문구 `총 A 중 B 취소`) | ✅ A=원금액(30,000)으로 환불 | 취소액 과다 기록 → 순지출 과소 | 금액은 라벨로만 선택, 후보 2개 이상이면 review | D 시나리오 | critical / 필수 |
| L6 | 여러 번 부분 환불 | 📖 각 번호 있으면 `ready`, 누적 상한은 원장이 검사 | 번호 없으면 전부 review; 상한 초과 시 예외 | 환불 누적 ≤ 원금, 위반은 review 로 변환 | 3회 부분환불 합=원금 OK, 4번째는 typed 거부 | medium / 보강 |
| L7 | 원결제보다 환불이 먼저/원거래가 아직 미승격 | 📖 `missingOriginalEntry` review로 정체 | 원거래가 승격돼도 재평가 트리거 없음(`waitingForEvidence` 미사용) | 대기 후보는 원거래 승격 시 재평가 | 환불 → 원거래 도착 → 환불 후보 자동 재평가 | high / 보강 |
| L8 | 환불 후 재결제 | 독립 | L2와 동일(ref 재사용) | L2 | L2 | low / 보류 |
| L9 | pending → posted(체크카드 출금 pending, 승인, 확정) | 📖 서로 다른 문구/앱이면 각각 `ready` | 이중 지출 | 상관 계층의 stage 연결, 단계별 알림은 한 거래 | 승인+출금(다른 앱) → 지출 1회 | critical / 필수 |
| L10 | 같은 거래가 승인·매입·청구 알림 3개로 도착 | 📖 3개 모두 지출로 분류 가능 | 삼중 지출 | L3 | L3 | critical / 필수 |
| L11 | 환불이 `입금`으로만 표기(취소 문구 없음) | 📖 `income` ready(ref 있으면) | 예산 반환 없이 소득으로 계상 → 순지출 과다 | 환불 입금은 원거래 연결 전 review | 계좌 입금 후 사용자 연결 시 `adjustment`로 전환 가능 | medium / 보강 |
| L12 | 환불 일시가 원거래보다 이전 | ✅ 승격됨(`occurredAt` 비교 없음) | 시각 모순 데이터 | adjustment.occurredAt ≥ original.occurredAt (또는 review) | 역순 환불 → review | low / 보강 |
| L13 | 카드대금 납부 후 도착한 카드 취소 | ✅ 부채가 음수로 내려감(`-84,200` 사례) | 음수 부채(크레딧)가 의도인지 불명 | 정책 결정(C-11) 후 invariant | 납부 후 취소 → 정책대로 | medium / 보강 |

### B2. 카드

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| C1 | 승인 금액 ≠ 청구 금액(팁/수수료/분할 매입) | 📖 `expense`는 불변, 추가 금액은 정정 수단 없음 | 승인 10,000 → 청구 11,000을 반영 불가 또는 별도 지출로 이중 | 매입 통지는 정정 이벤트 또는 review | 승인 10,000 + 매입 11,000 → 정책 결과 | high / 보강 |
| C2 | 해외 결제 환율 전(예상)/후(확정) | ✅ 예상 환산액이 확정으로 기록(E7) | 이후 매입과 이중, 금액 오차 | 예상 금액(`약`/`예상`)은 review, 외화는 원금액 보존 필드 필요 | `USD 12.34 (약 16,800원)` → review | high / 필수 |
| C3 | 외화 환불 환율 변동 | 📖 환불액(KRW) > 원금이면 `adjustmentExceedsOriginal` 예외 | 정상 환불이 poison | 환율 차이 허용 정책/차액 항목 또는 review | 원금 16,800, 환불 16,900 → typed review | high / 보류(단 예외 금지) |
| C4 | 할부 승인 | 📖 총액 전체가 승인월 지출, 월 청구 알림은 `결제`로 지출 분류 가능 | 할부 회차 청구 알림이 새 지출로 | 회차/청구 알림은 소비 아님 | `할부 2/3회차 청구` → review | medium / 보류 |
| C5 | 부분 결제/카드대금 일부 납부 | ✅ 허용(부채 일부 감소) | 대금 명세 추적 불가 | (정책 C-2) | 일부 납부 후 부채 = 차액 | low / 보류 |
| C6 | 카드대금 과납/선결제 | ✅ 부채 음수 허용 | 의도 불명 | 정책 결정 | 과납 → 정책대로 | medium / 보강 |
| C7 | 카드대금 납부 알림 2개(은행 + 카드사) | 📖 서로 다른 앱 → 각각 `cardPayment` | 부채 이중 감소 | R3 상관 | 같은 대금, 앱 2개 → 1회 | critical / 필수 |
| C8 | `카드결제 출금` 문구의 은행 알림 | 📖 `카드대금/결제대금` 미포함 → `결제` → **expense** | 카드 소비(승인 시) + 같은 금액 지출 → 이중 소비 | `카드` + 출금은 cardPayment 후보 또는 review | `[은행] 카드결제 출금 450,000원 거래번호 …` | critical / 필수 |
| C9 | 소비월 ≠ 납부월 | 설계상 승인월 소비, 납부월은 소비 아님 | 정책 | C-2 | 10월 결제 → 11월 납부 → 월별 합계 | low / 보류 |
| C10 | 간편결제앱 + 카드사 중복 | ✅ 이중 지출(G1+G2) | 이중 | R3 | G | critical / 필수 |
| C11 | 교통 후불(건별 + 일/월 합산) | 📖 키워드에 의존, 합산 알림도 `결제`로 지출 | 이중 | 합산 알림은 review | 건별 3 + 합산 1 → 합 1회 | high / 보류(review로 안전) |
| C12 | 한도/누적 줄이 금액보다 앞 | ✅ 450,000 | 금액 오류 | R4 | E2 | critical / 필수 |
| C13 | 같은 카드앱에 카드 여러 장 | 📖 모두 같은 `creditInstrument` | 카드 오귀속 | R8 | 끝자리 힌트 불일치 → review | critical / 필수 |
| C14 | 해외 원화결제 문구 (`원화결제`) | ✅ 같은 줄 숫자 오파싱(E1) | 금액 오류 | R4 | E1 | high / 필수 |

### B3. 계좌

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| A1 | 타인 송금(`이체`/`송금`, 목적지 계좌 모름) | 📖 context에 목적지 없으면 `incompleteTransfer` review | 내 돈이 사라지는 항목이 전부 review(과다); 목적지를 caller가 임의 지정하면 오귀속 | 외부 지급은 "외부 상대" 모델 필요(C-5) | 이체 → 외부 상대 항목 | high / 필수 |
| A2 | 입금(급여/정산/환불/이체 반대편 구분 불가) | 📖 `income` ready | 정산·환불이 소득으로 | 입금은 기본 review 또는 낮은 신뢰 | 입금 → 사용자 분류 전 승격 안 됨 | medium / 보강 |
| A3 | 계좌 간 이체 양쪽 알림 | ✅ 수신 계좌 +400,000 (J) | 이체액 이중 | R2: 양쪽을 한 transfer로 짝짓기 | J | critical / 필수 |
| A4 | 같은 수취인에게 같은 금액 짧은 시간 2회 송금 | 📖 각 `거래번호` 다르면 독립 `ready` | ref 없으면 둘 다 review(정상), 같은 ref면 예외 | 서로 다른 raw 둘 → 둘 다 보존, 절대 자동 병합 금지(D003) | 30초 간격 2회 → 2건 | high / 필수 |
| A5 | ATM 출금 | ✅ `rejected(unsupportedEvent)` | 은행 잔액 감소가 원장에 없음, 현금 계좌 없음 | 출금은 자금 이동 후보: 현금 계좌로 이체 또는 review | ATM → 이체 후보/`needsReview` | high / 필수 |
| A6 | 수수료가 별도 알림(`수수료 500원 출금`) | ✅ `출금` 미지원 → rejected; `이체수수료`는 `이체` → **이체로 오분류** (📖) | 수수료 누락 또는 목적지로 +500 이체 | 수수료는 별도 종류 | `이체수수료 500원` → fee/review | high / 보강 |
| A7 | 자동이체 | 📖 `이체` → transfer, 목적지 없으면 review | 과다 review, 목적지 임의 지정 위험 | A1 | A1 | medium / 보강 |
| A8 | 예약이체 등록/실행 예정 알림 | 📖 `이체` + 금액 + (ref 있으면) `ready` | 실제 이동 전에 반영 | 예정/등록은 거래 아님 | `예약이체 등록 완료 100,000원 거래번호…` → not ready | high / 필수 |
| A9 | 이체 취소/반환 | ✅ `ready` 환불 → 승격 시 예외(K) | poison | R7 | K | high / 필수 |
| A10 | 입금자명/출금자명이 알림마다 달라짐 | 현재 이름은 모델에 없음 | fingerprint(상대 이름 포함) 불일치로 중복 놓침, 이름에 키워드가 있으면 분류 오염(R1) | 상대 이름은 분류에 쓰지 않음, 중복 판단은 loose 키 | 입금자명 `취소` → 분류 불변 | medium / 보강 |
| A11 | `출금`/`입금 예정`/`송금 요청` | ✅ 출금 rejected, `송금 요청` ready(E10) | R1/R2 | R1 | E10 | high / 필수 |

### B4. Dedup

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| D1 | strong ID 있음, 같은 앱 재전송(다른 raw ID) | ✅ `conflictingCandidate` 예외(G3) | 중복 판정이 오류로 표현, 두 번째 raw 증거 미연결 | typed `duplicateEvidence(of:)` + raw 연결 | G3 | high / 필수 |
| D2 | strong ID 없음, 유사 알림 2개 | 📖 둘 다 `ambiguousWithoutStrongIdentity` review | 사용자가 "중복"이라 판정할 연산이 없음(`rejected`로 저장은 가능) | `duplicateOf` 결정 연산, 증거 점유 해제 | review 결정 후 원장 1건 | high / 필수 |
| D3 | 같은 금액·가게·시각의 실제 연속 결제 | 📖 raw ID 기반이라 각자 독립 | (OK) 단 ref 없으면 둘 다 review | D003 유지 | 2건 모두 보존 | low / 보강 |
| D4 | `sourceDeliveryID`가 같은데 raw ID가 다름 | 📖 raw 저장소는 `id`로만 멱등 | 재시도가 별개 raw로 저장 | (source app, sourceDeliveryID) 유일 | 같은 delivery ID 두 번 → alreadyStored | medium / 필수 |
| D5 | 문자 + 앱 푸시 중복 | ✅ 다른 앱이면 이중 (G1/G2), 같은 앱이면 예외 | R3 | R3 | G | critical / 필수 |
| D6 | 승인번호 재사용 | ✅ F2 | 누락+예외 | R5 | F2 | critical / 필수 |
| D7 | 승인번호는 같고 카드/계좌 다름 | ✅ F2와 동일 경로 | 한쪽 누락 | identity에 바인딩/금액/시각 포함 또는 ref를 evidence로만 사용 | F2 변형 | critical / 필수 |
| D8 | 초 단위 누락, 시간대 차이, 알림 시각 ≠ 거래 시각 | 📖 본문 시각 미사용 | 상관 window가 알림 게시 시각 기준이라 지연 알림에서 빗나감 | 본문 시각 우선, 둘이 크게 다르면 표시 | 3시간 지연 알림 | medium / 보강 |
| D9 | 재파싱/parser 버전 업 | ✅ `evidenceAlreadyClaimed`(raw 동일, ID 변경), 📖 `policyVersion` 달라 conflicting | 재처리 불가 | 대체(supersede) 연산 | R7 | high / 필수 |

### B5. Parser / Draft

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| P1 | 한 알림에 금액 여러 개 | ✅ 첫 `원` 줄 | R4 | 라벨 기반, 모호하면 review | E2, D | critical / 필수 |
| P2 | 통화 기호/외화 | ✅ `USD … (약 …원)`을 KRW로 확정; 외화만 있으면 `missingAmount` | 통화 context 고정(`context.currency`), 외화 원금액 보존 없음 | 외화/예상 금액은 review | E7 | high / 필수 |
| P3 | 음수/양수 표현(`-5,000원`, `(5,000)`) | 📖 부호 무시, 방향은 키워드 | 방향 키워드 부재 시 오방향 | 방향 필수(R2) | 부호 변형 | medium / 보강 |
| P4 | 천 단위 구분자(`5.000원`, 전각 숫자) | 📖 `5.000원`→ `000`→ 0 → `invalidAmount` review(안전). 💭 전각 숫자는 `Int64` 변환 실패로 `amountOverflow` 오분류 가능 | 오류 유형 혼동/예외 | 숫자 정규화 후 파싱, 실패는 review | 전각 `５,０００원` | medium / 보강 |
| P5 | 소수점 `5,000.50원` | ✅ 50원 | 금액 오류 | KRW는 소수 거부 | E4 | critical / 필수 |
| P6 | 가맹점/상대 없음 | 모델에 가맹점 자체가 없음 | review UI/중복 판단 재료 없음, 원문은 raw로 조회 필요 | candidate가 원문 사실을 참조 가능 | UI 요구 | medium / 보강 |
| P7 | 계좌 식별 불가 | ✅ 소스 binding으로 대체(R8) | 오귀속 | R8 | R8 | critical / 필수 |
| P8 | 시각 없음 | ✅ `missingTransactionTime` review(안전) | Shortcuts/리스너에 시각이 없는 소스는 전부 review | 정책: `capturedAt` 대체 허용 여부(C-12) | 시각 없음 처리 | medium / 보강 |
| P9 | 시각 파싱 실패 | 본문 시각을 읽지 않음 | 본문 시각과 알림 시각이 어긋나도 모름 | 본문 시각 검증 | 12/31 23:58 vs 1/1 | high / 필수 |
| P10 | 잔액 + 거래 금액 한 줄 | 📖 `잔액` 포함 줄 전체 제외 → 금액 줄이 없으면 `missingAmount` | 안전하지만 과다 review, 잔액은 버려짐(대사 불가) | 줄이 아니라 라벨 단위 파싱 | `출금 30,000원 잔액 70,000원` | low / 보강 |
| P11 | 광고/OTP/거절 오탐 | ✅ R1 | 지출/이체 승격 | R1 | A, E9-E11 | critical / 필수 |
| P12 | 한 알림 두 거래 | 📖 첫 금액만 사용, 나머지 침묵 누락 | 누락 | 금액 후보 2개 이상이면 review | 이용내역 2건 | high / 필수 |
| P13 | 입력 일부를 상대방이 통제 | 💭 `취소`/`승인번호 …`가 입금자명/메모에 있으면 분류·ref 오염 | 분류 조작, 환불로 위장 | 분류는 구조 슬롯 기준 | 입금자명 `승인번호 1` | high / 보강 |
| P14 | 매우 큰 숫자/비정상 입력 | ✅ `amountOverflow` 예외 | 배치 중단 | parse는 던지지 않음 | big | medium / 필수 |

### B6. AccountResolver / Assembler

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| V1 | 같은 은행 계좌 여러 개 | 📖 소스당 binding 1개 | 오귀속 | R8 | R8 | critical / 필수 |
| V2 | 같은 카드사 카드 여러 장 | 📖 | 오귀속 | R8 | R8 | critical / 필수 |
| V3 | 끝자리만 마스킹 | 📖 읽지 않음 | 대조 불가 | 힌트 불일치 → review | R8 | high / 필수 |
| V4 | 계좌 정보 전무 | 📖 소스 binding에 의존 | 다계좌 사용자는 오귀속 | binding 후보 2개 이상 + 힌트 없음 → review | R8 | high / 필수 |
| V5 | 카드 재발급 vs 과거 규칙 | 💭 | 신/구 번호 매핑 충돌 | binding에 유효기간, 새 힌트는 review | 재발급 | medium / 보강 |
| V6 | 계좌/카드 삭제(비활성) 후 과거 알림 재처리 | 📖 `inactiveAccount` 예외 | poison | 거래 시각이 비활성화 이전이면 허용 또는 review | 비활성 계좌 재처리 | high / 필수 |
| V7 | 계좌 생성 후 과거 알림 백필 | 📖 openingBalance에 기준 시각 없음 | 잔액 이중 계상 | `openingBalanceAsOf` 이전 알림은 반영 금지 | 시작일 이전 알림 | critical / 필수(백필 시) |

### B7. Atomic promotion

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| T1 | 저장 성공 후 ledger 실패 | ✅(in-memory) 상태 불변. **후보 미저장**(K) | 실패한 후보가 review 큐에 없음 | 영구 실패는 candidate를 `needsReview`로 저장 | K | high / 필수 |
| T2 | ledger 일부 기록 후 crash | in-memory는 검증 불가(복사 후 교체) | durable adapter가 부분 기록 가능 | `ledger entry 존재 ⇔ candidate 승격 링크 존재` | fault-injection | high / 필수(영속화 전) |
| T3 | 재시도(응답 유실) | ✅ 동일 candidate면 `alreadyPromoted` | `policyVersion`만 달라지면 예외(📖) | 승격 여부 판정은 proposedEntry 동일성 기준 | parser 버전 업 후 재처리 | high / 필수 |
| T4 | 동시 처리 | 📖 전역 revision CAS, 직렬화는 caller 책임 | 모든 저장이 candidateRevision을 올려 병렬 시 stale 연발 | 단일 writer 또는 재시도 규약 | 병렬 2건 | medium / 보강 |
| T5 | 동일 candidate 동시 승격 | 📖 먼저 온 쪽이 승격, 뒤는 동일성 검사로 `alreadyPromoted` | (OK) | 멱등 우선 확인 유지 | 동시 2회 | low / 보강 |
| T6 | 승격 직전 candidate 변경(사용자 reject) | 📖 stale candidate revision으로 거부 | OK, 단 idempotent 경로가 revision을 건너뜀 | stale 입력의 `alreadyStored`가 상태 변경을 가리지 않을 것 | reject 후 옛 ready 재처리 | medium / 보강 |
| T7 | rollback 실패 | n/a(in-memory) | durable: 이중 트랜잭션 | 단일 DB transaction | fault-injection | high / 필수(영속화 전) |
| T8 | 대량 재처리 성능 | 📖 commit/스냅샷마다 전체 재계산 O(n), 증거 검사 O(n) | 백필 시 O(n²) | 증분 갱신 | 5,000건 | low / 보류 |

### B8. BudgetImpact / 원장 의미

| ID | scenario | 현재 | 잘못될 수 있는 점 | invariant | test | sev / MVP |
|---|---|---|---|---|---|---|
| B1 | 이체가 소비로 | 형태 불변식으로 transfer는 impact 없음 ✅ | 분류 오류(`송금`/`이체`)로 expense가 되는 경로는 `카드결제 출금`(C8) 등 | 분류 개선 | C8 | critical / 필수 |
| B2 | 카드대금이 소비로 중복 | C7/C8 | 이중 소비 | cardPayment 후보 인식 | C8 | critical / 필수 |
| B3 | 환불이 잘못된 월 상쇄 | 환불은 원거래 월 ✅ | 원거래 월이 R6로 틀리면 연쇄 | R6 | H | critical / 필수 |
| B4 | 복합 정산 송금(여러 가게 몫) | 📖 단일 impact, 분할 불가 | 정산 분배 불가 | (보류) 검토 큐 | - | low / 보류 |
| B5 | 소비/자금이동 불명 거래 | 📖 `입금`→소득, `출금`→rejected | 기본값이 조용함 | 불명은 review | A2 | high / 필수 |
| B6 | 수수료/이자/캐시백/포인트 | 📖 전용 종류 없음, 키워드 우연에 의존 | 오분류 | 전용 종류 또는 review | `캐시백 입금`, `이자 입금` | medium / 보류(review로 안전) |
| B7 | 한 달에 외화+원화 지출 | ✅ 월 요약이 단일 통화(교차 통화 환불이 예외로 막히는 것은 *요약 계산의 부수 효과*; 명시적 불변식 아님) | 외화 항목이 들어오면 같은 월 전체 커밋이 막힘 | 통화는 명시 검사, MVP는 KRW만, 외화는 review | USD 지출 같은 달 | medium / 필수(KRW 고정 강제) |
| B8 | 환불 계좌가 원 결제수단과 다름 | ✅ 카드 지출 16,800에 은행 환불 +4,000 승격됨(부채 그대로) | 부채/현금 둘 다 틀림 | 환불 수단 ≡ 원 수단(또는 사용자 확인) | refund-to-bank | high / 필수 |

---

## C. Ambiguous semantics — 코드가 아니라 **제품 정책 결정**이 먼저

각 항목은 "결정 → 영향받는 코드" 형태. 결정 전에는 구현하지 말고 기본값은 review.

1. **지출 시점: 승인 vs 매입.** 현재 구현은 승인 알림 시각(= 승인월)이 소비. 매입 통지를 (a) 무시/연결만 하는가, (b) 금액 정정 이벤트로 쓰는가. 해외·팁·분할 때문에 승인액 ≠ 청구액이 흔하다(C1/C2).
2. **카드 소비월 vs 청구/납부월.** 현재: 소비는 승인월, 카드대금 납부는 소비 아님(D002). 월 결산 화면이 "이번 달 카드 청구 예정액"을 보여줘야 하는지에 따라 부채 명세(statement) 추적이 필요해진다.
3. **환불 반영 시점.** `환불 접수/예정`은 소비 반환으로 세지 않음(대기). 카드 취소 통지 시점 vs 실제 입금 시점 중 어느 쪽이 `BudgetImpact` 반환 시점인가(D004는 현금은 입금 시점, 소비 반환은 원월로 정함. 취소 통지와 입금 통지가 같은 반환임을 연결하는 규칙은 미정).
4. **환불이 원 결제수단과 다른 곳으로 올 때**(카드 → 은행 계좌) 허용/확인/거부(B8).
5. **타인 송금/정산 입금의 의미.** 외부로 나간 이체는 소비인가, 자금 이동인가, 정산인가. 정산 입금은 소득인가, 원지출의 반환인가(`income` vs `return`). 이체의 목적지 모델(외부 상대 계정) 필요 여부. 사용자의 가계부 사용 흐름(정산 후 순지출 보정)을 고려하면 중요한 결정.
6. **중복 정책의 운영 비용.** D003대로 강한 ID 없는 유사 알림은 모두 review. 은행 알림 대부분이 ID가 없다면 거의 모든 은행 입출금이 review → 사용 불가. 허용할 자동 승격 범위(예: 카드 승인만, 금액 한도 이하)를 정해야 한다.
7. **자동 승격 허용 종류.** 지출(승인)만 자동, 이체/입금/환불/카드대금은 항상 사용자 확인으로 시작할지(권장: MVP 첫 단계).
8. **외화.** KRW만 지원하고 외화는 review로 보낼지, 외화 원금액과 청구 원화를 모두 보존할지, 환율 차이를 어떻게 처리할지.
9. **할부.** 승인월에 총액을 소비로 볼지, 월별 분할로 볼지(현재: 총액 승인월).
10. **포인트/쿠폰/캐시백/리워드.** 소비액은 총액인지 실결제액인지. 캐시백은 소득인지 지출 반환인지. 이자/수수료는 소비인지.
11. **음수 부채(카드 크레딧) 허용 여부.** 납부 후 취소, 과납이 부채를 0 미만으로 만든다.
12. **시각 정책.** 본문 시각이 없을 때 `capturedAt` 대체를 허용할지(Shortcuts/리스너는 `notificationAt`이 없음). 예산 월 경계 ±N분은 review로 할지. 사용자 시간대 변경(해외 체류)의 예산 월 판정.
13. **알림 잔액의 지위.** `balanceAfter`를 원장 대사(drift 감지) 용도로만 쓸지, 아예 무시할지. (정답 잔액으로 삼으면 안 됨.)
14. **재발급 카드/폐기 계좌**의 binding 수명.
15. **정정/삭제 모델.** 사용자가 잘못 승격된 항목을 삭제(void)하면 증거를 해제해 재처리 가능하게 할지.

## D. Missing states / types — 실제로 필요한 것만

과설계를 피하기 위해 **최소 집합**과 **보류 가능**을 구분했다.

**최소(MVP 필수)**

1. **`ready` 생성 권한 분리.** parser는 `ready`를 못 만든다. 방법: `CandidateStatus`에 pre-state(예: `pendingCorrelation`)를 추가하고 `ready`는 상관/검증을 통과한 Assembler만 생성(타입으로 강제). 근거 R3.
2. **`CandidateFacts`(후보가 보유하는 파싱 사실).** 방향, 금액+통화, 본문 시각과 출처(`text`/`notificationTime`), provider reference와 scope, 수단 힌트(끝자리), 원문 상호/상대, `balanceAfter`. 상관 계층과 review UI의 입력. 지금은 후보가 `evidenceIDs`와 `proposedEntry`만 가져 사실이 ID 문자열에 인코딩돼 있다.
3. **방향 enum**(출금/입금/중립)과 **종류 확장**: `withdrawal`(미분류 출금), `settlementNotice`(매입), `feeCharge`. 현재 `Event`는 5종 + unsupported.
4. **CandidateIssue 추가**: `directionUnknown`, `duplicateOfExisting`, `pendingEvent`(예정/접수), `bindingMismatch`, `promotionRejected(LedgerValidationError)`(승격 시 검증 실패를 review로 보관), `periodBoundary`.
5. **typed non-throwing 처리 결과.** 영구 오류를 던지지 말고 `process`가 `.rejectedByLedger(reason)` 등 값으로 반환하고 후보를 `needsReview`로 저장. 일시 오류(stale revision)만 throw.
6. **대체/병합 연산**(`supersede`/`resolveDuplicate`): 같은 raw 재파싱과 중복 병합 시 기존 후보의 증거 점유를 이전. 현재 protocol에는 `process` 하나뿐.
7. **Ledger 정정 수단**(`reversal`/`void`) + 증거 해제. (R9)
8. **`Account.openingBalanceAsOf`.** (V7)
9. **환불 연결 검증 필드**: 원 전표와 환불 전표의 통화·수단 일치(B8), 환불 시각 ≥ 원 시각.
10. **`waitingForEvidence`의 실제 사용**(`awaiting: 원거래` 등)과 재평가 트리거.

**보류 가능(MVP 밖)**: 외화 원금액/환율 필드(`OriginalAmount`), 카드 명세(statement) 모델, 외부 상대 계정(결정 C-5 후), 할부 회차, 분할 정산 전표, binding 유효기간(재발급은 우선 review로).

---

## E. Top 15 tests (우선순위순)

테스트는 먼저 **실패하는(red) 상태**로 추가한다. 이름은 제안.

1. **`negativeCorpusNeverReady`** — 승인거절/결제실패/한도초과/결제예정/송금요청/이체한도 변경/예약이체 등록/광고 문구에 `거래번호`/`승인번호` 줄을 붙여도 `ready`가 아니다(`rejected` 또는 `notTransaction` 또는 review). *(R1; 부록 A의 A·E9–E11)*
2. **`directionIsExplicit`** — `이체 출금`/`이체 입금`/`입금`/`출금`/`ATM 출금`의 posting 부호가 문구와 일치하거나 review. `이체 입금`이 수신 계좌를 감소시키면 실패. 출금 계열은 `rejected`가 아니라 review 대상. *(R2)*
3. **`ownTransferTwoLegsPostOnce`** — 출금 알림 + 입금 알림 → transfer 1건, 수신 계좌 +X **1회**. 한쪽만 도착하면 `ready` 아님. *(R2/A3)*
4. **`amountSelectionIsLabelBased`** — `총 30,000원 중 10,000원 취소`→10,000 또는 review, `누적 사용액…`·`원화결제`·`5,000.50원`·`USD 12.34 (약 16,800원)`·`1,234원 / 5,678원`(라벨 없는 복수 금액)→ 정답 금액 또는 review, 임의 값으로 `ready` 불가. *(R4; 속성 기반: 금액 토큰 순서를 섞어도 오답 불가)*
5. **`crossSourceSamePurchaseNotDoubleCounted`** — 같은 승인번호/금액/시각을 `app.card`, `app.pay`, 문자 소스가 각각 알려도 소비 1회(또는 나머지는 review). *(R3)*
6. **`reusedApprovalNumberIsNeverDropped`** — 같은 앱/승인번호, 다른 금액/가게/카드 두 알림 → 둘 다 보존 또는 둘 다 review. 예외 없음, 누락 없음. *(R5)*
7. **`candidateIdentityIsStable`** — 같은 raw를 두 번(parser 버전/`policyVersion` 변경 포함)·reference 줄 위치 변경으로 파싱해도 `alreadyPromoted`/typed 결과, 예외 없음. `needsReview`가 점유한 증거를 재파싱 후보가 대체 가능. *(R5/R7)*
8. **`budgetMonthFollowsTransactionTime`** — 10/31 23:58(KST) 알림을 11/01에 처리 → 10월. 속성: `attributedMonth == month(occurredAt, tz)`. 본문 시각과 알림 시각 차이가 크면 review. *(R6)*
9. **`ledgerRejectionBecomesReviewNotException`** — 이체 원거래 환불, 원금 초과 환불, 비활성 계좌, 통화 불일치, 승인취소+매입취소 중복 → `process`가 throw하지 않고 후보를 `needsReview`로 저장, ledger/revision 불변, 재시도 결과 동일. *(R7)*
10. **`promotionIsAtomicUnderFaultInjection`** — `process`의 각 단계(후보 기록 후/ledger 기록 후 링크 전/커밋 직전)에 장애 주입 하니스. 불변식 `ledger entry 존재 ⇔ promotedEntryID 링크 존재`, 복구 후 재시도 멱등. durable adapter용 계약 테스트. *(T2/T7)*
11. **`refundLifecycleConsistency`** — 환불 수단이 원 수단과 다름, 환불 통화 불일치, 환불 시각 < 원 시각, 3회 부분 환불 후 4번째, 매입 통지 후 승인 통지, 납부 후 취소 → 각각 정의된 결과(허용 또는 typed review). 부록 A의 ledger 3건이 현재 모두 "승격됨"이므로 정책 결정 후 단언을 확정. *(B8/L3/L4/L12/L13)*
12. **`bindingHintMismatchNeedsReview`** — 카드 2장/계좌 2개, 본문 끝자리가 binding과 다르거나 없으면 review, 일치하면 해당 수단에 기록. *(R8)*
13. **`openingBalanceAsOfGuard`** — 계좌 시작일 이전 알림 재처리 시 잔액 불변(거부/review). *(V7)*
14. **`parserNeverThrowsAndRejectsInjection`** — 임의 문자열/전각 숫자/제로폭 문자/매우 큰 숫자 퍼징에서 parse가 던지지 않음. 입금자명/메모에 `취소`, `승인번호 1`, `원거래번호 …`가 있어도 분류·reference가 변하지 않음. *(P13/P14)*
15. **`reversalRestoresStateAndReleasesEvidence`** — (R9 도입 후) 승격된 항목을 정정하면 잔액·부채·월 예산이 복원되고 증거가 해제되어 재처리 가능. 환불이 연결된 원 전표의 정정은 거부.

## F. MVP 평가와 결론

**평가: 현재 구현을 `parse → process`로 그대로 연결하는 것은 MVP 기준으로 충분히 안전하지 않다.** Ledger의 형태·원자성 불변식은 충분히 견고하지만, 그 위의 parser/identity/binding/dedup 층이 조용히 틀린 금액을 `ready`로 만들어 영구 반영하고, 한 번 틀리면 되돌릴 수단이 없다.

아래 5가지만 먼저 고치면 MVP 안전 수준에 도달한다(나머지는 review로 안전하게 떨어지면 보류 가능).

1. **Parser 문법 강화** — (R1·R2·R4, 테스트 1·2·4·14)
   라벨 기반 금액, 소수/예상 금액/외화 거부, **방향 필수**(모르면 review), 거절·예정·요청·한도·광고 부정 신호를 분류보다 먼저 검사, 출금/ATM은 `rejected`가 아니라 review, 사용자 통제 문자열을 분류에 사용하지 않기, parse는 던지지 않음. `카드결제 출금`은 cardPayment 후보 또는 review.
2. **Identity와 dedup 게이트** — (R3·R5, 테스트 3·5·6·7)
   candidate/entry ID는 raw 기반, provider reference는 **evidence**(scope: 앱·수단·금액·일자)로만 사용. parser는 `ready`를 만들 수 없게(pre-state 도입) 하고 상관/중복/이체 짝 맞추기 단계를 거쳐야만 승격. `duplicateOf`와 대체(supersede) 연산 추가. MVP 초기에는 지출(승인)만 자동 승격, 나머지는 항상 확인 (정책 C-6/C-7).
3. **예산 월/거래 시각 파생** — (R6, 테스트 8)
   `attributedMonth`는 Assembler가 `occurredAt`과 사용자 시간대로 계산, 본문 시각 우선, 경계 근처/시각 불일치는 review. 소스에 시각이 없을 때의 정책(C-12) 결정.
4. **승격 전 검증과 typed 결과** — (R7, 테스트 9·10)
   `process`는 영구 오류를 던지지 않고 후보를 `needsReview(promotionRejected)`로 저장. 승격 전 dry-run 검증, 승격 여부 판정을 `policyVersion`이 아니라 `proposedEntry` 동일성으로. durable adapter용 장애 주입 하니스.
5. **바인딩 힌트 검증 + 정정 수단** — (R8·R9, 테스트 12·13·15)
   본문의 계좌/카드 끝자리를 읽어 binding과 대조(불일치/다중 후보 → review), `openingBalanceAsOf`로 백필 보호, 환불은 원 수단/통화/시각 일치 검사, **ledger reversal/void**로 잘못된 승격을 되돌리고 증거를 해제.

**MVP에서 명시적으로 보류해도 되는 것(단 review로 안전하게 떨어질 것)**: 외화 원금액/환율 필드와 FX 환불 차액, 할부 회차, 교통 후불 합산, 복합 정산 분할, 카드 명세(statement) 추적, binding 유효기간, 성능(O(n²)), 입금자명 정규화.

---

## 부록 A. 재현 입력과 관찰 결과 (구현 에이전트가 테스트로 옮길 시드)

모두 합성 입력. 공통: `source.applicationIdentifier = "app.a"`(별도 표기 제외), `notificationAt = 1_780_000_000_000`, 카드 문맥 = `.creditInstrument(card-main)`, 은행 문맥 = `.account(bank-main)`(+필요 시 `transferDestinationAccountID`), `currency = KRW`, `currentBudgetMonth = 2026-10`(별도 표기 제외).

| # | 입력(body) | 문맥 | 관찰 |
|---|---|---|---|
| A | `신용 5678 승인거절 12,300원 한도초과\n승인번호 777` | 카드 | `ready` expense 12,300 |
| B | `이체 입금 200,000원\n보낸분 테스트\n거래번호 T1` | 은행→dest `bank-2` | `ready` transfer, `bank-main:-200000`, `bank-2:+200000` |
| C | `ATM 출금 100,000원\n거래번호 T2` / `출금 30,000원\n거래번호 T3` | 은행 | `rejected(unsupportedEvent)` |
| D | `승인취소\n총 30,000원 중 10,000원 취소\n원승인번호 O1\n승인번호 C1` | 카드, originals[O1]=(e1, 2026-09) | `ready` adjustment **30,000**, 월 9 |
| E1 | `신용 5678 원화결제 25,000원\n승인번호 N1` | 카드 | `ready` expense **5,678** |
| E2 | `누적 사용액 450,000원\n승인 12,300원\n승인번호 N2` | 카드 | `ready` expense **450,000** |
| E4 | `승인 5,000.50원\n승인번호 N4` | 카드 | `ready` expense **50** |
| E5/E6 | `승인 원조할머니 5,000원…` / `신용 1234 승인 스타벅스 원두 5,000원…` | 카드 | `needsReview(missingAmount)` (안전) |
| E7 | `해외승인 USD 12.34 (약 16,800원)\n승인번호 N7` | 카드 | `ready` expense 16,800 |
| E8 | `승인 5,000원 취소국수\n승인번호 N8\n신용 5678` | 카드 | `needsReview(missingOriginalEntry)` (취소로 오분류, ref 관문 덕에 안전) |
| E9 | `(광고) 결제 시 최대 10,000원 캐시백 이벤트\n거래번호 AD1` | 은행 | `ready` expense 10,000 |
| E10 | `송금 요청 20,000원 도착\n거래번호 R1` | 은행→dest | `ready` transfer |
| E11 | `이체한도 5,000,000원으로 변경되었습니다\n거래번호 L1` | 은행→dest | `ready` transfer 5,000,000 |
| E12/E13 | `승인 5,000원 일시불 승인번호 55667788 10/05` vs `승인 5,000원\n승인번호 55667788` | 은행 | ID `candidate/5:app.x/expense/14:55667788 10/05` ≠ `…/8:55667788` |
| H | `승인 5,000원\n승인번호 H1` | 카드, `currentBudgetMonth=11` | 월 **11** |
| I | `환불이 접수되었습니다 15,000원\n영업일 3일 이내\n거래번호 P1` | 카드 | `needsReview(missingOriginalEntry)` |
| big | `승인 99999999999999999999원\n승인번호 B` | 카드 | **throws `amountOverflow`** |
| F | f1: `승인 5,000원 가게A\n승인번호 12345678`, f2: `승인 9,000원 가게B\n승인번호 12345678`(같은 앱) | 카드, `process` 순차 | f1 promoted, f2 **throws `conflictingCandidate`** |
| G | g1(`app.card`) `승인 7,000원 가게C\n승인번호 87654321`, g2(`app.pay`) `결제 7,000원 …` 같은 번호, g3(`app.card`) g1 재전송(다른 raw id) | 카드 | g1, g2 모두 promoted(부채 +14,000), g3 **throws `conflictingCandidate`** |
| J | j1 `이체 출금 200,000원\n거래번호 J1`(bank→bank2), j2 `입금 200,000원\n거래번호 J2`(bank2), j3 `이체 입금 50,000원\n거래번호 J3`(binding bank2, dest bank) | 시작: bank 1,000,000 / bank2 0 | 모두 promoted → bank 850,000, bank2 **350,000** |
| K | 이체 `TT1` 승격 후 `이체 취소 100,000원\n원거래번호 TT1\n거래번호 TC1`(originals[TT1]=이체 전표) | 은행 | parser `ready`, `process` **throws `adjustmentTargetIsNotExpense`**, 후보 저장 0건 |
| reparse | raw `rp`: `승인 5,000원`(저장: `candidate/raw/2:rp`) 후 같은 raw를 `…\n승인번호 ZZ9`로 재파싱 | 은행 | **throws `evidenceAlreadyClaimed`** |
| L-a | ledger: 카드 지출 16,800 → USD 계좌에 USD 12,000 환불 | | `currencyMismatch` 예외(요약 계산의 부수 효과) |
| L-b | ledger: 카드 지출 16,800 → **은행 계좌**로 +4,000 환불 | | **승격됨**, 부채 16,800 유지 |
| L-c | ledger: 카드대금 100,000 > 부채 | | **승격됨**, 부채 음수 |
| L-d | ledger: 환불 `occurredAt`(−999) < 원거래(1000) | | **승격됨** |

탐침 코드는 저장소에 넣지 않았다(임시 디렉터리). 필요하면 위 표를 기준으로 구현 에이전트가 `Tests/`에 정식 테스트로 작성한다.

---

## G. 재검증 결과 (2026-10-07, `origin/refactor/ingestion-pipeline` @ `91143ee`)

위 A–F와 부록 A는 `feat/notification-parser` @ `d3dec97` 기준이며 그대로 둔다. 이 절은 이후 올라온 `refactor/ingestion-pipeline`(parse → `TransactionCandidateDraft` → Resolver/Assembler → Dedup → `process`)을 같은 시나리오로 다시 돌린 결과다. 기존 테스트 49개는 모두 통과했다. 검증 방법은 앞과 같다(저장소 밖 임시 디렉터리에 브랜치를 내보내 탐침 테스트 실행, 저장소 변경 없음). 근거 표기도 같다: ✅ 실행 재현 / 📖 코드 판독 / 💭 추론.

**상태 기준**
- **resolved**: 원래 재현된 실패 시나리오가 더 이상 재현되지 않고, 그 방지가 구조 또는 코드로 보장됨.
- **partially resolved**: 일부 시나리오·계층은 개선됐으나 같은 위험의 다른 경로가 남았거나, 구현은 있어도 강제되지 않음.
- **unresolved**: 원래 시나리오가 그대로 재현됨.

**변경된 구조(이 판정의 전제)**: parser는 `TransactionCandidateDraft`만 반환하고 `ready`를 만들 수 없다(타입으로 강제, 📖). Draft에는 `AccountID`/`CreditInstrumentID`/`LedgerEntryID`가 없다. 바인딩은 `TransactionAccountResolver`, 조립은 `DefaultTransactionCandidateAssembler`, 중복 판정은 `DefaultCandidateDeduplicationValidator`가 맡는다. 후보 ID는 `raw ID + parserVersion + eventIndex`다. `Ledger.swift`, `CandidateProcessingRepository`, in-memory 저장소는 변경이 없다(📖 diff 없음).

### G.1 R1–R9 상태

| 위험 | 상태 | 근거 | 확인 내용 |
|---|---|---|---|
| **R1** 분류가 fail-open | **unresolved** | ✅ 실행 재현 | 승인거절 + `승인번호` → `ready` 지출 12,300 (이전과 동일). `(광고) 결제 시 … 캐시백` + `거래번호` → `ready` 지출 10,000. `송금 요청 20,000원` → `ready` 이체. `결제 대기 5,000원` → `ready` 지출. `이체한도 변경`, `예약이체 등록 완료`는 `notTransaction`이 됐지만 **키워드가 하나도 없어서 우연히** 그렇게 된 것이다. |
| | | 📖 코드 판독 | `classifyNonTransaction`(광고/인증/거절/대기/잔액)은 `classify`가 `nil`일 때만 호출된다. 본문에 `승인`·`사용`·`결제`·`입금`·`출금` 등이 있으면 부정 신호 검사 없이 거래로 분류되므로 `declined`/`pending`/`promotion`/`authentication` 사유는 일반 알림에서 사실상 도달 불가다. |
| **R2** 방향 | **partially resolved** | ✅ 실행 재현 | 개선: `이체 입금`은 `deposit`/`inflow`로 올바르게 기록(이전의 수신 계좌 감소 없음). `이체 출금`(띄어쓰기)과 `ATM 출금`은 `withdrawal`로 분류돼 `needsReview(unsupportedEvent)`로 저장(이전의 `rejected` 아님). 잔존: 출금 알림(`출금이체`) → transfer, 입금 알림(`입금`) → income을 둘 다 처리하면 이체 300,000원이 수신 계좌에 **+600,000**으로 남는다(이중 계상). `송금 요청`은 여전히 transfer. |
| | | 📖 코드 판독 | 이체 양쪽을 짝짓는 로직이 없다. 검증기는 `kind`가 같아야 유사로 보므로 `transferOut`과 `deposit`은 비교조차 되지 않는다. 키워드가 띄어쓰기에 민감하다(`출금이체`/`이체출금` vs `이체 출금`). |
| **R3** dedup 게이트 부재 | **partially resolved** | ✅ 실행 재현 | 개선(검증기를 거친 경우): 같은 앱·같은 `거래번호` 재전송 → `duplicate`; 다른 앱·같은 `거래번호` → `conflictingStrongIdentity` review; 같은 승인번호(scoped)·다른 앱 → `ambiguousWithoutStrongIdentity` review; 30초 뒤 새 승인번호의 동일 금액 결제 → review(D003 유지). 잔존: 검증기를 거치지 않으면 같은 결제가 그대로 이중 승격(`useDedup:false` 재현). 승인 3일 뒤의 `매입` 통지는 새 지출로 승격(이중 지출). |
| | | 📖 코드 판독 | 게이트가 **구조적으로 강제되지 않는다**: `process`는 검증기 통과 여부를 모르고, 새 `IngestionPipelineTests`도 검증기를 거치지 않는다. 오케스트레이터 타입이 없다. 비교 창이 5분(기본)이라 며칠 뒤 통지는 비교 대상이 아니고, `purchaseSettlementNotice` 종류는 정의만 있고 parser가 생성하지 않는다. `duplicate` 결과가 저장되거나 raw에 연결되는 곳이 없다. 이체 양쪽 짝맞추기 없음. |
| **R4** 금액 선택 | **unresolved** | ✅ 실행 재현 | `원화결제` 같은 줄의 카드 끝자리 → 5,678; `누적 사용액` 줄 → 450,000; `5,000.50원` → 50; `USD 12.34 (약 16,800원)` → 확정 16,800 `ready`; 99999999999999999999원 → 예외 `amountOverflow`; 취소 Draft 금액 `총 30,000원 중 10,000원 취소` → **30,000**. 모두 이전과 동일. |
| | | 📖 코드 판독 | `parseAmount`가 `d3dec97`과 동일 로직. `confidence`는 항상 `.high`이고 `amountAmbiguous`/`kindAmbiguous`/`directionUnknown`/`timeBoundaryRisk`/`timeMalformed`는 정의만 있고 어디서도 발행되지 않는다(hard issue 경로가 사실상 죽은 코드). |
| **R5** identity/ref 의존 | **resolved** (identity 한정) | ✅ 실행 재현 | 같은 앱·같은 승인번호의 서로 다른 두 결제(다른 금액/가게)가 이제 둘 다 승격된다(이전: 두 번째 `conflictingCandidate` 예외). |
| | | 📖 코드 판독 | ID가 `raw ID + parserVersion + eventIndex`이고 승인번호는 scoped evidence로만 쓰인다. 남은 약점: 환불 원거래 조회(`adjustmentOriginalsByEvidenceValue`)가 여전히 범위 없는 문자열 키 `[String: AdjustmentOriginal]`이라 우연히 겹친 번호의 다른 원거래에 연결될 수 있다. 버전이 ID에 들어가므로 버전 변경 후 재파싱 충돌은 R7에서 다룬다. |
| **R6** 예산 월/거래 시각 | **unresolved** | ✅ 실행 재현 | 예산 월은 `context.currentBudgetMonth`(11월을 주면 11월). 본문 시각 `10/05 14:32`가 있어도 `occurredAt.source = notificationTime`, 본문 시각은 읽지 않음. |
| | | 📖 코드 판독 | Assembler의 `expense`가 `context.currentBudgetMonth`를 그대로 사용. `timeBoundaryRisk`는 발행되지 않는다. |
| **R7** poison/영구 오류 | **unresolved** (일부 악화) | ✅ 실행 재현 | `process`가 영구 오류를 던지고 후보를 저장하지 않는다: 이체 원거래 환불 → `adjustmentTargetIsNotExpense`(저장 후보 수·원장 revision 불변), 존재하지 않는 원거래 → `originalEntryNotFound`, 원금 초과 → `adjustmentExceedsOriginal`. 같은 raw를 parser 버전만 올려 재파싱(강한 ID 없음) → `evidenceAlreadyClaimed`(강한 ID가 있으면 검증기가 `duplicate`로 먼저 걸러 예외 없음). `amountOverflow` 예외 유지. **신규 회귀**: `0원` 입력에서 parse가 `nonPositiveAmount`를 던진다(이전에는 review로 갔음). |
| | | 📖 코드 판독 | Storage/`process`/Ledger 변경 없음. typed non-throwing 결과, 승격 전 dry-run, supersede/재파싱 연산 없음. |
| **R8** 계좌/카드 바인딩 | **partially resolved** | ✅ 실행 재현 | 구조는 분리됨(Resolver 프로토콜, Draft에 ID 없음). 기능은 미완: `체크카드 1234`가 `creditCard`/`maskedHint = nil`, `신용 5678`은 `unknown`/`nil` — **끝자리를 전혀 추출하지 않는다**. |
| | | 📖 코드 판독 | `parseInstrumentHint`가 `카드` 포함 여부만 본다(체크/신용 구분 없음). `resolve(draft)`는 Draft만 받는데 Draft에 소스 앱 식별자가 없다(증거의 `scope`에만 간접 존재, 증거가 없으면 없음). 따라서 다계좌·다카드 사용자에게 Resolver가 쓸 재료가 부족하다. 힌트 불일치 → review 규칙 없음. |
| **R9** 정정 수단/기준 시각 | **unresolved** | 📖 코드 판독 | `Ledger.swift` 변경 없음. `void`/`reversal`/`openingBalanceAsOf` 검색 결과 0건(✅ 문자열 검색). |

**집계**: resolved 1(R5, identity 한정), partially resolved 3(R2·R3·R8), unresolved 5(R1·R4·R6·R7·R9).

**개선으로 인정하는 것**: parser의 `ready` 생성 불가, 방향 필드, 출금/ATM의 review 처리, 승인번호 scoped 취급, raw 기반 identity, 검증기의 `duplicate`/`conflictingStrongIdentity` 구분, Draft 경계의 결정론 테스트(합성 26종).

> **탐침 해석 주의**: 이번 재검증 탐침에는 내 입력 실수가 두 곳 있었다. (1) 환불 시나리오에서 원거래 전표를 잘못 골라 처음에는 다른 예외 종류가 나왔고, 올바른 원거래로 재실행해 `adjustmentTargetIsNotExpense`를 확인했다. (2) 기본 타임스탬프를 재사용해 일부 첫 결제가 dedup으로 review가 됐으나 이는 의도된 D003 동작이다. 두 경우 모두 판정에는 영향이 없다.

### G.2 신규 결함

#### DEF-1. `승인번호` 라벨 검색이 `원승인번호` 줄에도 매칭된다 — ✅ 실행 재현 / 📖 코드 판독

- **위치**: `KoreanFinancialNotificationParser.evidence(notification:lines:)`.
- **재현**: 입력 `승인취소\n총 30,000원 중 10,000원 취소\n원승인번호 O1\n승인번호 C1` → Draft evidence가 `approvalNumber=O1`, `originalApprovalReference=O1`(취소 건 자신의 번호 `C1`은 어디에도 없음). 출력: `evidence=["approvalNumber=O1", "originalApprovalReference=O1"]`.
- **원인**: `providerTransactionID`는 `원거래`/`원승인` 줄을 제외한 `currentLines`에서 찾지만, `approvalNumber`는 전체 `lines`에서 `승인번호`를 찾는다. `승인번호`는 `원승인번호`의 부분 문자열이어서 `원승인번호 O1` 줄이 먼저 매칭된다. 이전 버전 `currentProviderReference`는 필터를 적용했지만 새 `evidence`에서 `approvalNumber`에만 빠졌다.
- **영향**: 취소 알림의 `approvalNumber`(scoped)가 원거래 번호로 채워져 취소와 원승인이 같은 승인번호 evidence를 갖는다. 현재 검증기는 `strong`만 비교하므로 즉시 오판정은 없지만, 승인번호를 scoped로 비교하는 후속 correlator/매입 연결 구현이 생기면 취소 알림이 원승인과 동일 거래로 오인된다. 또한 취소 알림 자체의 번호가 사라진다.
- **같은 유형의 위험**: `거래번호` ↔ `원거래번호`는 `currentLines` 필터가 있어 안전하지만, 필터가 줄 단위라 같은 줄에 `원거래번호 X 거래번호 Y`가 함께 있으면 `Y`도 버려진다(💭 미확인).
- **필요한 invariant**: 라벨은 토큰 경계로 매칭하고(`원` 접두 구분), 하나의 줄은 하나의 라벨에만 귀속된다. 취소 알림에서 `approvalNumber`는 자기 번호이거나 없어야 하며 원번호와 같을 수 없다.
- **필요한 test**: 위 입력에서 `approvalNumber`가 `C1`이고 `originalApprovalReference`가 `O1`임을 단언; 자체 번호가 없는 취소 알림에서는 `approvalNumber`가 없음을 단언; 순서를 뒤바꾼 입력에서도 동일 결과.
- **severity**: medium(현재 직접 오기록 없음, evidence 오염). 상관 계층 구현 시 high로 상향.

### G.3 이번 재검증에서 새로 확인한 부수 사항(위험 번호에 편입)

- 0원 입력의 parse 예외(R7에 편입, ✅).
- 이체 방향 키워드의 띄어쓰기 민감성(R2, 📖).
- 서로 다른 승인번호를 둘 다 가진 동일 금액 연속 결제가 `ambiguousWithoutStrongIdentity`가 된다(✅). D003에 부합하는 보수적 동작이지만, "승인번호가 서로 다르다"는 사실은 같은 거래가 아니라는 증거이므로 과다 review를 줄이려면 상관 정책 결정이 필요하다(정책 C-6).

---

## H. 현재 우선 수정 순서

재검증 결과와 Draft 분리 이후의 구조를 반영한 순서다. 1–2는 parser 내부 수정으로 끝나고, 3 이후는 Assembler/Core를 건드린다. 각 항목은 앞 항목에 의존하지 않고 독립적으로 병합할 수 있으나, 위험 순서대로 처리할 것을 권한다.

| 순서 | 항목 | 현재 상태 | 범위 | 완료 기준(테스트) |
|---|---|---|---|---|
| **1** | **R1 비거래/부정 신호 선차단** | unresolved | parser: 분류보다 먼저 거절·실패·예정·대기·요청·예약·한도·광고·인증 신호를 검사해 `notTransaction`으로 보낸다. 사용자 통제 필드(입금자명·메모·가맹점명)는 분류 입력에서 제외. 이체/출금/입금 키워드의 띄어쓰기 허용. | E의 test 1 `negativeCorpusNeverReady`: 승인거절/결제 대기/송금 요청/광고/예약이체/한도 변경 문구에 `거래번호`·`승인번호`를 붙여도 `ready`가 아니다. 입금자명 `취소` 등으로 분류가 변하지 않는다. |
| **2** | **R4 금액 문법** | unresolved | parser: 라벨 기반 금액 선택(`승인/결제/취소/출금/입금 금액`), 후보가 둘 이상이거나 `총/중/누적/한도/약/예상`이 붙으면 `amountAmbiguous`(hard), 소수점 거부, `원화결제` 등 단어 속 `원` 무시, 외화·예상 금액은 review, 0원·거대 숫자는 던지지 않고 review/`failed`. 사용하지 않는 hard issue를 실제로 발행하고 confidence를 낮춘다. | test 4 `amountSelectionIsLabelBased`, test 14 `parserNeverThrowsAndRejectsInjection`. 부록 A의 D·E1·E2·E4·E7·big 시드가 정답 또는 review가 된다. DEF-1(승인번호 매칭)도 이 단계에서 함께 고친다(같은 줄/라벨 파싱 코드). |
| **3** | **R6 시각/예산 월** | unresolved | Assembler: `attributedMonth`를 `occurredAt`과 사용자 시간대로 계산(`context.currentBudgetMonth` 제거 또는 검증용으로만 사용). parser: 본문 시각을 읽어 `source=text`, 알림 시각과 크게 다르면 표시, 월 경계·자정 근처·시각 부재 시 `timeBoundaryRisk`. 소스에 시각이 없을 때의 정책(C-12) 결정. | test 8 `budgetMonthFollowsTransactionTime`: 10/31 23:58 알림을 11/01에 처리해도 10월. 속성: `attributedMonth == month(occurredAt, tz)`. |
| **4** | **R7 permanent failure / poison candidate** | unresolved | Core/Storage: `process`가 영구 오류(`adjustmentTargetIsNotExpense`, `originalEntryNotFound`, `adjustmentExceedsOriginal`, 비활성 계좌, 통화 불일치)를 던지지 않고 후보를 `needsReview`(예: `promotionRejected`)로 저장해 반환. 승격 전 dry-run 검증. 재파싱·parser 버전 변경을 위한 supersede/대체 연산. parse가 던지는 경로(`amountOverflow`, `nonPositiveAmount`)는 2에서 제거. | test 9 `ledgerRejectionBecomesReviewNotException`, test 7 `candidateIdentityIsStable`. 부록 A의 K·reparse 시드. 영구 오류는 반환 값으로, 일시 오류(stale revision)만 예외로 남는다. |
| **5** | **R3 dedup gate 구조적 강제** | partially resolved | 파이프라인 오케스트레이터(또는 `process` 입력 타입)로 검증기 통과를 강제: 검증기를 거치지 않은 `ready`는 승격 불가. `duplicate` 결과의 저장/raw 연결. 매입 통지 분류(`purchaseSettlementNotice` 생성)와 승인–매입 연결(비교 창이 아니라 승인번호·금액·수단 기준). 이체 양쪽 짝맞추기(또는 한쪽만 도착한 입금은 review). | test 3 `ownTransferTwoLegsPostOnce`, test 5 `crossSourceSamePurchaseNotDoubleCounted`, test 11 중 매입 항목. `useDedup:false` 시나리오가 구성 불가(컴파일 또는 승격 거부)여야 한다. |
| **6** | **R8 resolver에 필요한 binding hint 보강** | partially resolved | parser: 카드/계좌 끝자리 추출(`maskedHint`), 체크/신용/계좌 구분. Draft에 소스 식별(앱 식별자)을 보존해 Resolver 입력으로 사용. Assembler/Resolver: 힌트 불일치·다중 후보·힌트 없음 → review(`bindingMismatch`). | test 12 `bindingHintMismatchNeedsReview`: 카드 2장·계좌 2개 시나리오에서 끝자리 일치 시 해당 수단, 불일치/없음은 review. |
| **7** | **R9 void/reversal/opening balance** | unresolved | Core/Ledger: 정정 전표(`reversal`/`void`)와 증거 해제, `Account.openingBalanceAsOf`(기준 시각 이전 알림 반영 금지), 환불 연결 검증(원 수단·통화·시각 일치). 정책 C-15 결정 후 진행. | test 13 `openingBalanceAsOfGuard`, test 15 `reversalRestoresStateAndReleasesEvidence`, test 11 중 환불 일관성 항목. |

**순서의 근거**: 1–2는 현재 재현된 "조용히 틀린 금액·거래가 `ready`로 승격"을 parser 안에서 막으므로 가장 값싸고 효과가 크다. 3은 월별 예산의 정확성을 결정한다. 4는 한 번 틀린 입력이 파이프라인을 막는 것을 없앤다. 5는 1–2가 막지 못하는 교차 소스 중복을 구조로 막는다. 6은 다계좌 사용자가 생길 때 필요하다. 7은 정책 결정과 원장 모델 변경이 필요해 가장 크고, 1–5가 `ready` 오탐을 줄인 뒤에 안전망으로 추가한다.

**MVP 게이트 제안**: 1–4가 끝나기 전에는 `process`로 자동 승격하지 않는다(모든 후보를 사용자 확인 후 승격). 1–5가 끝나면 승인 지출에 한해 자동 승격을 허용할 수 있다(정책 C-7). 7이 끝나기 전에는 이체/입금/환불/카드대금의 자동 승격을 허용하지 않는다.

> §G·§H는 `91143ee` 시점의 **중간 기록**이다. 이후 `refactor/ingestion-pipeline`에서 R1·R2·R4·R6·R7과 R3의 일부를 수정했고, 최종 상태와 남은 위험은 아래 §I가 기준이다.

---

## I. 최종 상태 (2026-10-07, `refactor/ingestion-pipeline`, 이번 커밋 기준)

이 절은 위험 상태의 **현재 기준 문서**다. 상태 값은 네 가지만 쓴다.

| 값 | 의미 |
|---|---|
| **resolved** | 원래 재현된 실패 시나리오가 재현되지 않고, 회귀 테스트가 있다. 남은 한계는 아래 "잔여"에 명시. |
| **mitigated** | 재현된 시나리오는 막았지만 같은 위험의 다른 경로가 **실행으로 확인되어** 남아 있다. |
| **deferred** | 의도적으로 이번 범위에서 제외했다(큰 설계 확장이 필요). 위험은 그대로다. |
| **unresolved** | 대응이 없고 보류 결정도 없다. (현재 해당 없음) |

근거 표기: ✅ 이 세션에서 **실행으로 재현/검증** / 📖 코드 판독만 / 💭 추론. 검증은 Codex 워크트리의 수정본에서 수행했고, 시나리오별 탐침은 저장소 밖 임시 디렉터리에서 실행했다(저장소에 포함하지 않음).

### I.1 R1–R9 최종 상태

| 위험 | 최종 상태 | 검증된 사실 (✅/📖) | 잔여 (숨기지 않음) |
|---|---|---|---|
| **R1** 분류 fail-open | **mitigated** | ✅ 거절(`승인 거절`/`승인거절`), 광고·혜택, `송금 요청`, `예약이체`, `이체한도 변경`, **`결제 대기`/`결제대기`/`승인 대기`(이번 커밋에서 추가)**가 `승인번호`/`거래번호` 줄이 있어도 `notTransaction`. 📖 부정 신호 검사가 분류보다 먼저 실행. | ✅ **블록리스트 방식이라 목록 밖 문구는 여전히 거래가 된다**: `승인 보류 5,000원 / 승인번호 U2` → 승격됨. 📖 `classifyNonTransaction`의 키워드 폴백은 분류가 `nil`일 때만 동작. 근본 해결은 허용목록(positive structure) 기반 분류. |
| **R2** 방향 | **mitigated** | ✅ `입금`/`출금`/`이체 입금`/`이체 출금`/`ATM 출금`에 kind·direction 명시, 미분류 출금은 `needsReview(unsupportedEvent)`로 저장(`rejected` 아님). 이전의 `이체 입금` 방향 반전 없음. | ✅ **이체 양쪽 알림 짝맞추기 없음**: 출금이체 300,000 + 입금 300,000 → 출금 계좌 −300,000, 수신 계좌 **+600,000**(이중 계상). 짝맞추기(correlator)는 deferred. |
| **R3** dedup 게이트 | **mitigated** | ✅ `process`가 `ready` 후보에 dedup 게이트를 **직접 강제**한다(호출자가 검증을 빠뜨릴 수 없음): 다른 앱의 같은 결제(승인번호 동일)의 두 번째는 `stored`(review)이며 원장은 1건. 같은 범위의 강한 ID 재전송은 `duplicate`. | ✅ **승인 3일 뒤의 `매입` 통지는 새 지출로 승격된다**(비교 창 5분, 매입 종류 미생성) → 부채 이중 계상. 이체 양쪽 짝맞추기 없음. 📖 durable adapter도 같은 게이트를 구현해야 한다(in-memory만 강제). |
| **R4** 금액 문법 | **resolved** (열거된 시나리오 한정) | ✅ 라벨 기반 선택: `총 30,000원 중 10,000원 취소` → 10,000, `누적 사용액` 무시, `잔액` 무시, 소수 `5,000.50원`/외화·예상 환산/복수 모호 금액/0원/초과 숫자는 **non-throwing failure**. **이번 커밋에서 추가 수정**: 거래 금액 줄이 없을 때 `잔여한도`·`이번달 사용액`·`잔고` 줄이 금액으로 채택되던 결함(`잔여한도 1,550,000원` → 승인 1,550,000)을 막음(`한도`/`누적`/`사용액` 줄 제외, `잔액`/`잔고`/`잔여` 앞까지만 사용). | ✅ `신용 5678 원화결제 25,000원`은 올바른 금액이 아니라 `amountAmbiguous`로 **fail-closed**(잘못된 값은 아니지만 정상 알림이 거절됨). 📖 라벨 사전이 한정적이라 새 문구는 fixture로 확장 필요. |
| **R5** identity | **resolved** | ✅ candidate/entry ID = raw ID + event index. 같은 승인번호의 서로 다른 두 결제가 모두 기록됨(`reusedApprovalNumberForDifferentPurchasesIsNeverDropped`), parser 버전 변경 후에도 ID·proposedEntry 동일, 재시도는 `alreadyPromoted`(`rawIdentityAndRetryRemainStableAcrossParserVersions`). | 📖 환불 원거래 조회 `adjustmentOriginalsByEvidenceValue`는 여전히 범위 없는 문자열 키(우연히 겹친 번호의 다른 원거래에 연결 가능) — deferred. |
| **R6** 예산 월/시각 | **mitigated** | ✅ expense `attributedMonth`가 `occurredAt`과 사용자 시간대에서 파생(`budgetMonthFollowsOccurredAtInUserTimeZone`: 10/31 23:58 KST를 11월에 처리해도 10월). | ✅ `occurredAt`은 여전히 알림 **게시** 시각이며 본문 시각(`10/05 14:32`)은 읽지 않는다(`source=notificationTime`로 승격됨). 📖 `timeBoundaryRisk`는 발행되지 않는다. 지연 알림·시각 부재 소스는 월이 틀릴 수 있다. |
| **R7** poison/영구 오류 | **resolved** (in-memory 계약 한정) | ✅ 원장의 영구 거부는 예외로 후보를 잃지 않고 `needsReview(promotionRejected)` + typed `rejectedByLedger`로 저장, 재시도도 같은 typed 결과(`permanentLedgerRejectionIsStoredForReviewAndRetryIsTyped`, `failedLedgerWriteAfterStoredReviewRestoresOriginalCandidate`). ✅ parse가 `0원`/거대 숫자에서 던지지 않음(`failed(.amountUnparseable)`). 같은 raw를 다른 parser 버전으로 재파싱해도 `alreadyPromoted`. | 📖 durable adapter의 fault injection(저장 후 crash 등)은 deferred(어댑터가 없음). 일시 오류(stale revision)는 의도적으로 throw. |
| **R8** 바인딩 | **deferred** | 📖 Draft에 계좌/카드/원장 ID가 없고 Resolver/Assembler로 분리된 **구조**만 있음(이전 커밋). | ✅ `maskedHint`는 항상 nil이고 `체크카드 1234`가 `creditCard`로 분류됨. 📖 Draft에 소스 앱 식별이 없어 Resolver가 다계좌를 구분할 재료가 없다. 힌트 불일치 → review 규칙 없음. |
| **R9** 정정 수단 | **deferred** | ✅ `Ledger.swift`에 void/reversal/`openingBalanceAsOf` 없음(이번 변경에서도 원장 모델은 변경하지 않음). | 잘못 승격된 항목을 되돌리거나 증거를 해제할 수 없다. 계좌 시작일 이전 알림 백필 시 잔액 이중 계상 가능. |

**집계**: resolved 3(R4·R5·R7 — 모두 한정 조건 있음), mitigated 4(R1·R2·R3·R6), deferred 2(R8·R9), unresolved 0.

### I.2 신규 결함 DEF-1 (§G.2) — 이번 커밋에서 수정

- **상태**: ✅ **fixed**. 수정 전 코드에서 새 회귀 테스트가 6건 실패(red)함을 확인한 뒤, `reference(in:labels:)`가 `승인번호` 라벨 앞에 `원`이 붙은 경우(= `원승인번호`)를 건너뛰고 같은 줄의 다음 라벨을 계속 찾도록 수정.
- **회귀 테스트**: `approvalNumberLabelDoesNotMatchOriginalApprovalNumber` — 원번호 줄이 먼저/나중, 원번호만 있는 취소(자체 `approvalNumber` 없음), 같은 줄에 두 라벨.
- **잔여(📖, 테스트 미단언)**: `원승인번호 O1 승인번호 C1`처럼 같은 줄에 둘이 있을 때 `originalApprovalReference` 값은 줄 끝까지(`O1 승인번호 C1`)가 된다. 레퍼런스 값이 항상 줄의 나머지라는 기존 동작(예: `승인번호 55667788 10/05` → `55667788 10/05`)은 바뀌지 않았다. 토큰 단위 값 추출은 후속.

### I.3 요청된 회귀가 실제 테스트로 존재하는지

| # | 회귀 | 테스트 (Swift Testing) | 비고 |
|---|---|---|---|
| 1 | 승인 거절 + 승인번호가 거래가 되지 않음 | `negativeCorpusNeverBecomesCandidate` (`neg-declined`, `neg-declined-compact`★) | ★이번 커밋 추가 |
| 2 | 광고 / 송금 요청 / 결제 대기 오탐 차단 | 같은 테스트: `neg-ad`, `neg-request`, `neg-scheduled`, `neg-limit`, **`neg-payment-pending`★, `neg-payment-pending-compact`★, `neg-approval-pending`★** | **`결제 대기`는 이번 커밋 전까지 테스트도 구현도 없었고 실제로 승격됐다**(✅ 재현 후 수정) |
| 3 | 취소금액과 원거래금액 구분 | `amountSelectionIsLabelBasedAndAmbiguityFailsClosed` (`amt-partial-cancel` = 10,000) | |
| 4 | `승인번호`/`원승인번호` 라벨 충돌 방지 | `approvalNumberLabelDoesNotMatchOriginalApprovalNumber`★ | **이번 커밋 전에는 테스트도 수정도 없었다** |
| 5 | 누적 사용액/잔액/한도가 금액으로 선택되지 않음 | 같은 amount 테스트: `amt-cumulative`, `amt-balance`, `amt-remaining-limit`★, `amt-limit-only`★, `amt-usage-only`★, `amt-balance-only`★, `amt-oneline-jango`★ | ★ 중 `*-only` 3건은 수정 전 승격되던 실제 결함 |
| 6 | 모호한 금액이 자동 승격되지 않음 | 같은 amount 테스트: `amt-ambiguous` → `.failed(.amountAmbiguous)` (후보 자체가 생성되지 않음) | |
| 7 | `occurredAt` 기준 budget month | `budgetMonthFollowsOccurredAtInUserTimeZone` | |
| 8 | 영구 ledger rejection이 유실 없이 review로 남음 | `permanentLedgerRejectionIsStoredForReviewAndRetryIsTyped`, `failedLedgerWriteAfterStoredReviewRestoresOriginalCandidate` | |
| 9 | 동일 raw retry 안전 | `rawIdentityAndRetryRemainStableAcrossParserVersions`, `evidenceOwnerTreatsEquivalentPromotedEntryAsRetry` | |

### I.4 이번 커밋의 검증 결과

| 항목 | 결과 |
|---|---|
| Swift 전체(`swift test`, Windows x86_64, Swift 6.4) | **60/60 통과** (이전 세션 59개 + 이번 라벨 테스트 1개; fixture 케이스 추가는 기존 테스트 안) |
| 수정 전 코드에서의 새 회귀 | 실패 확인(`approvalNumber` 3건, `결제 대기` 계열 3건) → 수정 후 통과 |
| Python test-data(`python -m unittest discover -s tests/test_data`) | **7/7 통과** |
| 합성 provider fixture | 카탈로그 재생성 결과 26종, 커밋된 `synthetic-notification-coverage.json`과 **해시 동일**; Swift `SyntheticCoverageTests`로 22개 거래(명시적 kind/direction/12,000원) + 4개 비거래(송금 요청·이자 안내·Tmoney 잔액/승차) 단언 |
| `git diff --check` | 통과(추적 파일 오류 없음, 새 파일 4개도 trailing whitespace 없음). LF→CRLF 변환 경고는 저장소 설정에 따른 것으로 오류가 아님 |

### I.5 남은 우선 순서 (이번 커밋 이후)

§H의 순서 중 1(R1), 2(R4), 4(R7)의 열거된 시나리오, 5(R3)의 게이트는 처리됐다. 남은 것을 위험 순서로:

1. **이체 양쪽 알림 짝맞추기 + 매입 연결** (R2·R3, 실행 재현된 이중 계상 두 건). 승인–매입은 비교 창이 아니라 승인번호·금액·수단으로 연결.
2. **본문 거래 시각 파싱과 경계 review** (R6): `occurredAt`을 `source=text`로, 월 경계·시각 부재 시 `timeBoundaryRisk`.
3. **분류를 블록리스트에서 허용목록 기반으로** (R1): `승인 보류` 같은 목록 밖 문구가 거래가 되는 구조 해소.
4. **binding hint**(R8): 끝자리 추출, 체크/신용 구분, Draft의 소스 식별, 힌트 불일치 review.
5. **void/reversal/`openingBalanceAsOf`/환불 수단·통화 일치 검증** (R9) — 정책 C-15 결정 후.
6. **durable adapter용 fault-injection 계약 테스트**와 gate 구현 의무 (R7·R3).
7. 환불 원거래 조회 키 범위화, reference 값의 토큰 단위 추출.
