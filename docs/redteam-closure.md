# Red-team risk closure

기준: `docs/redteam-review.md`에서 재현한 R1–R9 및 Top 15 tests. 이 문서는 `refactor/ingestion-pipeline`에서 닫은 범위와 남은 범위를 한 장으로 요약한 것이며, **근거(실행 재현/코드 판독)와 잔여 위험의 전체 기록은 `docs/redteam-review.md` §I가 기준**이다. 두 문서의 상태 값은 같은 네 가지만 쓴다.

- **resolved**: 재현된 시나리오가 재현되지 않고 회귀 테스트가 있다(한정 조건은 §I.1 "잔여").
- **mitigated**: 재현된 시나리오는 막았지만 같은 위험의 다른 경로가 실행으로 확인되어 남아 있다.
- **deferred**: 큰 설계 확장이 필요해 의도적으로 제외했다. 위험은 그대로다.
- **unresolved**: 대응도 보류 결정도 없다(현재 없음).

## Critical risk 상태

| Risk | 상태 | 현재 보장 | 남은 범위 |
|---|---|---|---|
| R1 fail-open 분류 | mitigated | 거절·실패·예약·예정·**결제/승인 대기**·송금 요청·한도 변경·광고/혜택을 거래 분류보다 먼저 차단 | 블록리스트 방식이라 목록 밖 문구(`승인 보류` 등)는 거래가 된다. 허용목록 기반 분류는 후속 |
| R2 방향 부재 | mitigated | 입금/출금/이체 입금/이체 출금/ATM 출금의 kind와 direction을 명시하고 미분류 출금은 review | 양쪽 계좌 알림을 한 transfer로 짝짓는 correlator가 없어 이체가 수신 계좌에 이중 계상됨 |
| R3 dedup gate 부재 | mitigated | in-memory processing adapter가 ready candidate에 dedup safety gate를 강제하여 cross-provider 중복의 두 번째 승격을 차단 | 승인 며칠 뒤의 `매입` 통지는 새 지출로 승격됨. durable adapter도 같은 gate를 구현해야 함 |
| R4 첫 번째 원 금액 선택 | resolved | label 우선, 잔액/잔고/누적/한도/사용액 제외, 부분취소 금액 선택, 소수 KRW·외화 예상액·복수 모호 금액 fail-closed | 라벨 사전은 fixture로 확장. `원화결제` 같은 단어는 오금액이 아니라 fail-closed |
| R5 승인번호 기반 identity | resolved | candidate/entry ID는 raw ID + event index이며 parser version/승인번호와 무관. 승인번호 재사용 거래는 누락하지 않음 | 환불 원거래 조회 키가 범위 없는 문자열(후속) |
| R6 처리 월 사용 | mitigated | expense budget month는 occurredAt과 사용자 time zone으로 파생 | `occurredAt`은 알림 게시 시각이며 본문 거래 시각은 읽지 않음. 경계 불일치 review는 후속 |
| R7 poison 영구 오류 | resolved (in-memory) | 원장 영구 거부는 typed `rejectedByLedger`와 `needsReview/promotionRejected`로 저장되고 재시도도 typed 결과. parse는 0원/거대 숫자에서 던지지 않음 | durable fault injection은 adapter 구현 시 필요 |
| R8 source 단위 binding | deferred | Draft에서 binding 제거, Resolver/Assembler 계약으로 분리(구조만) | `maskedHint`를 추출하지 않고 체크/신용을 구분하지 않으며 Draft에 소스 식별이 없음. 힌트 불일치 review와 binding 유효기간은 후속 |
| R9 정정 불가 | deferred | 이번 변경은 잘못된 자동 승격의 입구를 fail-closed로 강화 | ledger reversal/void, evidence release, `openingBalanceAsOf`는 별도 정책·계약 필요 |

신규 결함 DEF-1(`승인번호` 라벨이 `원승인번호`에 매칭): **수정됨**, 회귀 테스트 `approvalNumberLabelDoesNotMatchOriginalApprovalNumber`.

## Top 15 대응

| # | 상태 | 근거 |
|---|---|---|
| 1 negative corpus | resolved | `negativeCorpusNeverBecomesCandidate` (거절·광고·송금 요청·예약이체·한도 변경·결제/승인 대기). 목록 밖 문구는 R1 잔여 |
| 2 explicit direction | mitigated | `directionIsExplicitForAccountNotifications`. 이체 양쪽 짝맞추기는 후속 |
| 3 own-transfer pairing | deferred | 양쪽 알림 correlator가 아직 없음 |
| 4 label-based amount | resolved | `amountSelectionIsLabelBasedAndAmbiguityFailsClosed` (누적·잔액·한도·사용액·소수·외화·모호 포함) |
| 5 cross-source purchase | mitigated | `crossProviderSamePurchaseCannotDoublePromote`. 승인→매입 연결은 후속 |
| 6 reused approval number | resolved | `reusedApprovalNumberForDifferentPurchasesIsNeverDropped` |
| 7 stable identity/retry | resolved | `rawIdentityAndRetryRemainStableAcrossParserVersions`, `evidenceOwnerTreatsEquivalentPromotedEntryAsRetry` |
| 8 occurredAt budget month | mitigated | `budgetMonthFollowsOccurredAtInUserTimeZone`. 본문 시각 대조 review는 후속 |
| 9 ledger rejection review | resolved | `permanentLedgerRejectionIsStoredForReviewAndRetryIsTyped`, `failedLedgerWriteAfterStoredReviewRestoresOriginalCandidate` |
| 10 durable fault injection | deferred | in-memory copy/validate/commit은 기존 테스트 유지, durable adapter 없음 |
| 11 refund lifecycle | mitigated | 기존 원금 상한·원월 테스트 유지. 환불 수단/통화/시각 일치 검증은 없음(원 결제수단과 다른 계좌로의 환불이 승격됨) |
| 12 binding hint mismatch | deferred | Resolver 경계만 정의, masked hint 정책 미구현 |
| 13 openingBalanceAsOf | deferred | Account 모델 확장은 별도 migration 결정 필요 |
| 14 parser fuzz/injection | mitigated | overflow·0원·금액 ambiguity는 non-throwing failure. 전체 fuzz corpus와 사용자 통제 필드 분리는 후속 |
| 15 reversal/evidence release | deferred | R9와 함께 별도 ledger 정정 설계 필요 |

## 익명 fixture

`synthetic-notification-coverage.json`의 26개 형식은 운영 원문이나 실제 금액/관계를 포함하지 않는다. 테스트는 22개 거래 형식의 kind/direction/금액과 4개 비거래 형식의 fail-closed 결과를 단언한다. 이 자료는 형식 커버리지이며 실제 금융 거래 ground truth로 사용하지 않는다. `redteam-parser-fixtures.json`은 위 회귀 입력(합성)만 담는다.
