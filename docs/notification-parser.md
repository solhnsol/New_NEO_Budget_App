# 금융 알림 ingestion 계약

Parser의 출력은 ledger 후보가 아니라 알림에서 직접 관측한 사실이다.

```text
RawNotification
  -> TransactionCandidateParser
  -> TransactionCandidateDraft
  -> TransactionAccountResolver / TransactionCandidateAssembler
  -> TransactionCandidate
  -> CandidateDeduplicationValidator
  -> CandidateProcessingRepository (atomic)
  -> Ledger
```

## 경계

- Parser는 금액, 방향, 행위 종류, 원문 상대방, 수단 힌트, 시각과 evidence만 추출한다.
- Draft에는 `AccountID`, `CreditInstrumentID`, `LedgerEntryID`가 없다.
- `NotificationParsingContext`에는 결정론에 필요한 타임존, 기준 시각, parser ID/version만 있다.
- Resolver가 계좌 또는 카드 수단을 바인딩하고 Assembler가 실제 `TransactionCandidate`와 proposed entry를 만든다.
- Parser와 Assembler는 repository나 ledger를 수정하지 않는다.
- `CandidateProcessingRepository.process`만 candidate 저장과 ready ledger 승격을 하나의 원자 작업으로 수행한다.

## review 및 identity 규칙

강한 ID가 없다는 사실만으로 review가 되지 않는다. 금액·방향·계좌 등이 충분하고 parser issue가 soft뿐이면 merchant/payee가 없어도 ready로 조립할 수 있다. 강한 identity가 없는 유사 후보가 이미 있을 때만 dedup 계층이 `ambiguousWithoutStrongIdentity`를 올린다.

승인번호는 application scope 안의 유용한 evidence지만 단독 전역 strong ID가 아니다. Source delivery ID나 provider transaction ID는 scope를 포함해 비교한다. 같은 strong evidence가 확인되면 dedup 결과는 기존 candidate의 duplicate이며 두 번째 candidate를 atomic promotion에 넘기지 않는다.

Candidate/entry ID는 raw notification ID, parser version, event index를 길이 구분해 결정적으로 만든다. 승인번호를 ID로 사용하지 않는다.

## 시각 provenance

원문 거래 시각이 없을 때 notification timestamp, 그마저 없으면 capture timestamp를 fallback으로 쓸 수 있다. `ObservedTimestamp.source`는 각각 `text`, `notificationTime`, `captureTime`을 보존한다. Capture fallback은 `timeAbsentFallback` soft issue이며 그 자체로 자동 처리를 막지 않는다.

## ledger 결과

- 은행/현금 지출: 음수 `Posting`과 expense `BudgetImpact`.
- 카드 사용: 양수 `LiabilityChange`와 expense `BudgetImpact`; 현금 Posting 없음.
- 입금: 양수 `Posting`; 소비 예산 영향 없음.
- 이체: 합계 0인 두 `Posting`; 소비 예산 영향 없음.
- 카드대금: 음수 은행 `Posting`과 음수 `LiabilityChange`; 소비 예산 영향 없음.
- 환불: 실제 발생 시각의 양수 Posting 또는 음수 Liability, 원구매 월의 return `BudgetImpact`.

현재 한국어 parser는 경계 검증용 보수적 baseline이다. `synthetic-notification-coverage.json` 26개 형식은 결정론과 provenance를 검증하지만 provider별 완전 지원을 뜻하지 않는다. 상세 fixture 구현은 atomic promotion 계약 이후 단계에서 확장한다.
