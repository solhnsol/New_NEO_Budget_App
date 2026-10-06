# 금융 알림 parser 계약

`TransactionCandidateParser`의 출력은 금융 사실의 제안이지 저장 완료된 원장이 아니다.

```text
RawNotification
  -> TransactionCandidateParser
  -> TransactionCandidate
  -> correlator/review
  -> CandidateProcessingRepository
  -> Ledger
```

Parser에는 repository, ledger, 시스템 clock, locale, OS 계좌 객체가 전달되지 않는다. application은 확인된 계좌/카드 binding, 통화, 예산 월, 환불 원거래 연결을 `NotificationParsingContext`로 제공한다.

## ready 조건

- 지원하는 행위가 명시돼 있음: 승인/사용/결제, 입금, 이체/송금, 취소/환불, 카드대금/결제대금.
- 잔액 줄이 아닌 원 단위 거래 금액이 있음.
- `notificationAtUnixMilliseconds`가 있음. 수집 시각을 실제 거래 시각으로 바꾸지 않음.
- source binding과 행위별 필수 상대가 있음.
- 거래번호/승인번호 등 강한 금융 거래 reference가 있음.
- 환불은 원거래 ledger ID와 원구매 예산 월을 찾을 수 있음.

하나라도 부족하면 `needsReview`다. 지원하지 않는 광고/안내는 `rejected`다. `sourceDeliveryID`는 raw 재전송 식별자일 뿐 금융 거래 reference로 승격하지 않는다.

## 생성 결과

- 은행/현금 지출: 음수 `Posting`과 expense `BudgetImpact`.
- 카드 사용: 양수 `LiabilityChange`와 expense `BudgetImpact`; 현금 Posting 없음.
- 입금: 양수 `Posting`; 소비 예산 영향 없음.
- 이체: 합계 0인 두 `Posting`; 소비 예산 영향 없음.
- 카드대금: 음수 은행 `Posting`과 음수 `LiabilityChange`; 소비 예산 영향 없음.
- 환불: 실제 발생 시각의 양수 Posting 또는 음수 Liability, 원구매 월의 return `BudgetImpact`.

Candidate/entry ID는 application identifier, 행위, provider reference를 길이 구분해 결정적으로 만든다. 같은 provider 거래가 서로 다른 title/body 배치로 들어와도 identity는 같지만, 서로 다른 provider의 알림을 하나의 거래로 결합하는 책임은 parser가 아니라 후속 correlator에 있다.

## 현재 한계

현재 구현은 익명 합성 입력으로 검증한 엄격한 한국어 baseline이다. 특정 provider의 모든 문구를 지원한다고 간주하지 않는다. provider profile을 추가할 때는 개인정보를 제거한 실제 title/subtitle/body, 기대 candidate 상태, parser policy version을 fixture로 함께 보관한다.
