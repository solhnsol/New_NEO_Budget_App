# Core 설계 및 milestone 계획 — 합의 전 초안

Domain에는 iOS/HTTP/DB 타입을 넣지 않는다. 시각, 식별자, 설정, ID 생성은 입력 또는 interface로 받아 테스트에서 고정한다. 파일 경로·타임존·시스템 시각에 따라 계산 결과가 달라지지 않게 한다.

## 계층

```text
Core/
  Domain/          금액·계좌·금융 행위·근거·수정 모델
  Parsing/         provider별 parser와 정규화
  Deduplication/   원본 중복·원거래 일치·관련 근거 판정
  Ledger/          원장 반영·조정·수동 수정
  Budget/          순수 월별 집계와 이월
  Settlement/      관계 모델 경계; 첫 milestone 기능 확장은 보류
  Pipeline/        단계 조합과 처리 상태
  Storage/         Repository/atomic-write 계약
Infrastructure/
  Storage/        in-memory 및 추후 local adapter
  Import/         JSON fixture runner, 추후 CSV/Actual 가져오기
Platform/
  iOS/            경계 설명만; 현재 구현 없음
Tests/
  Fixtures/       익명화된 알림 + 합성 edge cases + 기대 원장
```

언어를 정하면 해당 언어의 package 관례로 디렉터리를 조정한다. Runtime Core에 fixture runner/파일 I/O를 끌어들이지 않는다.

현재 Swift Package에서 Core는 `Sources/NEOBudgetCore`, 테스트용 Infrastructure는 별도 `Sources/NEOBudgetInMemoryStorage` target으로 분리했다. 정규화는 Parsing으로 이동했고 중립 RawNotification/Repository 계약만 구현했다. 나머지 금융 계층은 이 문서의 설계 초안이다. Platform/iOS와 Platform/Android는 경계 문서만 둔다. 상세 결과는 platform-boundary-review.md 참조.

## 핵심 모델 제안

| 모델 | 주요 정보/책임 |
|---|---|
| Money | 정수 minor-unit amount, currency, overflow 검증; 최초 KRW 범위 논의 |
| Account | ID, provider/account binding, 은행/현금/선불 종류, 기초 잔액, 활성 상태 |
| CreditInstrument/Liability | 카드 등 결제 수단과 미납 의무/변동. 별도 카드 계좌를 요구하지 않음 |
| Merchant | 내부 ID, 원문 alias, 정규화 표시명. 소비 목적과 분리 |
| Category/CategoryGroup | 안정된 ID, 소속, 이름, 색/아이콘 메타데이터, 보관 상태 |
| Transaction | ID, 금융 행위 종류, 실제 발생 시각/정밀도, 상호/목적/카테고리, 근거 관계, 버전 |
| Posting | Transaction의 실제 계좌별 잔액 변동. 카드 미납 변동은 Liability 관계로 표현 |
| Transfer | 행위 ID, 출발/도착 계좌, 금액, 근거. 자체 계좌 이체와 카드 대금 납부를 소비 합계에서 제외 |
| Adjustment | 원거래 ID, 취소/부분 취소/환불, 금액, 상태, 환급 근거 ID. 원거래 제거로 처리하지 않음 |
| RawNotification | 내부 ID, sourceDeliveryID, app/provider hint, 원본 payload, 원래 알림 시각/수집 시각, 원본 hash |
| ParsedEvent | 파서 ID/버전, 명시된 provider reference/계좌/금액/방향/시각/잔액/상호; 미확정 필드와 정밀도 |
| TransactionCandidate | 금융 행위 제안, 모든 근거 ID, ready/needsReview/waiting/rejected 이유, 정책 버전 |
| ProcessingRecord | 원본→파서 결과→candidate→원장 연결과 성공/실패/재처리 상태 |
| ManualOverride | 수정 필드/이전 값/새 값, 사용자 수정 보호, 기준 버전. 자동값과 사용자값 분리 |
| Budget | 대상 월/그룹/카테고리, 배정액, 이월 정책/적용 버전 |
| Calendar/EventLink | 외부 일정 reference/회차, 거래 ID, 수동/자동 연결, 분석 기간. EventKit 객체 포함하지 않음 |

저장 ID와 계산의 determinism을 구분한다. ID 생성기는 주입하고 동일 원본의 기존 연결을 조회해 재사용한다. parser 버전 변경만으로 새 금융 거래를 만들지 않는다.

## 독립 테스트 가능한 pipeline

1. 수신: raw 입력 스키마 검증, 전송 ID와 보관 계약.
2. Parser: 원본에서 명시된 사실 추출. 개인 계좌를 추정/원장 생성하지 않음.
3. Identification: provider 후보/계좌 마스크/사용자 binding으로 계좌 결정. parser 선택을 위한 provider hint는 앞 단계에서 사용 가능하되 미일치를 검증.
4. Normalization: NFC/공백, Money/UTC+원래 timezone, 시간 정밀도, 상호 alias. 원문 보존.
5. Deduplication: identical delivery / same financial event / complementary evidence / distinct / ambiguous 반환.
6. Candidate: 승인·입출금·이체·반환 관련 이벤트를 묶고 필요한 근거/검증 상태 생성.
7. Ledger: revision/수동 수정 보호/금액 불변식 검증 후 원장+근거 소비 기록을 atomic-write.

원본 수신과 금융 반영은 각각 멱등성을 가진다. 한 pipeline 단계 실패 시 원본과 이전 성공 결과를 보존한다. 도착 순서가 바뀌어도 동일한 최종 금융 결과를 얻고, 모호한 매칭은 순서에 따라 임의 선택하지 않는다.

## 중복 판정 제안

- 같은 sourceDeliveryID: 재전송. payload가 다르면 조용히 덮어쓰지 않고 충돌.
- provider가 준 원거래/승인 번호: provider·계좌·행위 종류 범위로 비교. 승인과 취소는 번호가 같아도 서로 다른 행위.
- 동일 payload digest는 증거 중 하나. 새 수집 시각은 같은 거래를 새 거래로 만드는 근거도, 새로운 실제 결제를 합치는 근거도 아님.
- provider/account/currency/amount/direction/실제 시각 및 정밀도/상호/거래 후 잔액/원문을 조합. 강한 근거와 시간상 근접 후보를 구분.
- 은행 알림+페이 상세, 이체 출금+입금은 raw 중복이 아니라 하나의 행위에 속하는 여러 근거다.
- 승인 번호/전송 ID 없이 원문과 분 단위 시각이 같은 실제 반복 결제는 완전 자동 구별이 불가능할 수 있다. 보류/확인 정책을 명시하고 누락을 감추지 않음.
- 합성 fingerprint는 index/후보 검색용으로 사용할 수 있지만 유일한 금융 진실로 강제하지 않음.

## Repository 계약 제안

원본 저장/조회, provider reference 및 근거 조회, 계좌 binding, 원장 snapshot, 버전 조건부 수정, candidate 상태 변경, atomic-write를 제공한다. 메서드 인자/결과는 Domain 값이며 SQL/SwiftData 객체를 노출하지 않는다.

원장 반영과 이미 반영한 근거의 기록은 하나의 commit 단위. 한쪽 이체만 저장하거나 원장만 쓰고 처리 상태가 빠지는 것을 금지한다. in-memory 구현도 rollback/중복 제약/revision 검사를 수행해 실제 DB와 같은 계약으로 테스트한다.

앱 UI와 미래 단축어 adapter는 같은 application use case를 호출한다. 플랫폼은 시각/저장/알림/캘린더 입력을 제공하고, 분류/집계/매칭 정책을 갖지 않는다.

## 예산 계산 제안

월별 gross expense, returned amount, net expense, income, transfer amount를 구분한다. 소비 예산에서 이체/카드 대금을 제외한다. 기초 잔액과 계좌 조정은 생활 수입으로 세지 않는다. 수수료가 있으면 이체 원금과 별도 소비로 표현한다.

remaining = allocated + carry-in - eligible net expense. category별 계산을 group/전체로 합산하되 미분류 소비를 숨기지 않는다. 부분 취소/환불과 정산 수령은 일반 수입과 구분한다. 이월과 지난달 환불의 귀속은 D004/D005 선택 후 고정한다.

## 첫 milestone의 기능 브랜치 제안

| 단계/브랜치 후보 | 결과 | 검증 |
|---|---|---|
| plan/local-first-core | 분석, 모델/정책 초안, 결정 기록 | 사용자 설명과 선택 |
| feat/core-domain-storage | 패키지, Domain, in-memory 저장 계약 | Money/계좌/관계/revision/rollback |
| feat/notification-pipeline | parser/계좌 판별/정규화 | 익명화 provider fixtures, NFC, 미등록 계좌 |
| feat/ledger-dedup | 원장·근거·이체·카드·취소/환불·사용자 수정 | replay/order/원금 초과/부분 실패/모호함 |
| feat/budget-engine | 순수 월별 합계·예산·선택한 이월 | 이체 제외/반환/월 경계/음수 잔액 |
| test/milestone-one | fixture runner, Windows/Linux 검증 | 전체 기대 원장·잔액·소비·미확정 상태 |

브랜치 이름/분할은 초안이다. 최초 빈 저장소의 기준 브랜치 생성, commit/push/PR은 별도로 합의한다. Settlement 세부 엔진과 이벤트 편집 기능은 첫 milestone에 무리하게 확장하지 않는다.

## 필수 fixture 및 실패 시나리오

- 단일 지출/수입; 동일 source ID 재전송; source ID 충돌.
- 30초 간격 동일 금액·동일 상호 실제 결제 2건; 분 단위 시각만 있어 구분 불가한 사례.
- 카드 승인+은행 출금+페이 상세의 동일 결제; 모든 도착 순서와 지연된 상세.
- 자체 계좌 이체 양쪽 알림, 한쪽 누락, 여러 동일 금액 이체의 모호한 대응.
- 신용카드 사용과 카드 대금 출금; 대금 합계가 개별 승인 합계와 다른 경우.
- 승인 후 전액 취소, 부분 취소 반복, 중복 취소, 취소가 먼저 도착, 원승인 미확인, 원금 초과.
- 취소 통지+환급 입금, 다른 달 환불, 별도 실제 수입과의 혼동.
- 수동 category/merchant/amount 변경 후 재파싱, revision 충돌, 사용자가 연결/제외한 근거.
- unknown provider/account, 광고/수락 요청, 잘못된 시각/금액, NFC/NFD, 연말/자정.
- atomic commit 실패/rollback/재시도, 여러 호출의 동시 반영, 앱 재실행을 흉내 낸 저장소 복원.
- 모든 순열/반복 처리 후 동일 금융 결과, 원장 합계와 계좌 변동 검증. 원본 증거 개수 차이는 별도 표현.

fixture는 input/settings/fixed clock/expected ledger/expected unresolved를 함께 기록한다. 기존 사례와 합성 사례를 구분하며 원문의 개인정보는 새 저장소에 공개하지 않는다.

## 환경 검증의 구분

- Windows 도구 설치/빌드/test 명령을 문서화하고 실제 Windows 실행 또는 CI 로그로 검증해야 Windows 검증 완료라고 보고한다.
- 에이전트 현재 환경은 Linux이며 Swift 미설치. 언어 합의 후 필요한 환경과 자동 검증 구성을 제안한다.
- iOS SDK/framework에 의존하는 import를 Core에 넣지 않는다. Windows 빌드 성공은 iPhone adapter 검증을 대신하지 않는다.
