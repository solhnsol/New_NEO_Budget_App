# 공동 의사결정 기록

설계 초안을 작성하는 것과 구현 정책을 확정하는 것을 구분한다. 아래 제안은 사용자의 이해와 선택을 확인하기 전에는 구현에 고정하지 않는다.

## 이미 사용자 지시로 확정된 범위

- offline-first/local-first, deterministic, idempotent, testable.
- iPhone 내부 자체 엔진, Actual/FastAPI 실행 의존성 없음. Android 확장을 고려하되 현재 Swift를 유지하고 OS adapter와 Core를 분리.
- 현재 Windows에서 개발 가능한 Core와 저장 인터페이스부터 진행.
- UI/App Intents/Shortcuts/SwiftData/Core Data/background/iCloud/StoreKit/배포는 현재 구현하지 않음.
- 첫 milestone은 샘플 알림 → 정확한 원장, 반복 처리 중복 없음, 이체/취소/환불의 정확한 소비 통계.
- 새 저장소에서 브랜치별 작업. 기존 운영 프로젝트는 참고/이관 대상.

## D001 — Core 언어: 사용자 선택 완료

권고: iOS 프레임워크 없는 순수 Swift Package. Windows용 Swift 도구로 Core를 개발하고 나중에 iOS가 같은 모듈을 사용한다. 공식 Windows 설치 문서: https://www.swift.org/install/windows/

사용자 선택: “순수 Swift Core — Windows 도구 설치를 감수하고 iPhone에서도 같은 코드를 사용”. 이 선택과 비용을 commentary에서 다시 설명했다. Swift Package/테스트 환경 준비를 진행하며 금융 정책 선택은 별도로 확인한다.

비용: Windows Swift/C++ 빌드 도구 설치와 플랫폼 간 빌드 검증. 현재 에이전트 Linux 환경에는 Swift가 설치돼 있지 않다. 도구 설치와 테스트 환경 확보도 별도로 보고한다.

대안: TypeScript Core. 기존 JS 파서 활용과 현 환경 실행이 쉽다. 네이티브 iOS에서 같은 Core를 어떻게 실행할지 별도 결정을 요구하며 Swift로 재구현하면 이중 유지보수가 생긴다.

확인 방식: 사용자가 선택한 방향과 이유/우려를 설명하고, 에이전트가 그 선택의 장단점을 다시 확인한다. 짧은 긍정만으로 서로 다른 대안을 임의 선택하지 않는다.

## D002 — 원장 표현: 사용자 선택 및 Core 규약 구현 완료

합의: 금융 행위 Transaction과 실제 계좌 변동 Posting을 분리. 사용자는 Actual식 카드용 계좌보다 이 구분을 선택했다. 카드 정보를 결제 수단 CreditInstrument와 미납 의무 Liability로 별도 표현하고 카드 계좌를 요구하지 않는다. 카드 사용 시 소비/미납 의무, 대금 납부 시 은행 계좌 변동/미납 의무 감소를 기록한다.

구현 규약: `Posting`은 실제 계좌 잔액 증감, `LiabilityChange`는 카드 미납 의무 증감, `BudgetImpact`는 소비/반환과 귀속 월을 표현한다. 금액은 통화와 함께 정수 최소 단위로 저장한다. 이체는 한 원장 항목 안의 합계 0인 두 Posting으로 원자적으로 저장한다. 카드 납부는 은행 Posting 감소와 Liability 감소이며 소비를 추가하지 않는다.

검토 예시: 카드 10,000원 결제 → 소비 10,000원. 카드 대금 10,000원 납부 → 소비 추가 0원, 은행 잔액 감소/카드 부채 해소.

## D003 — 중복과 애매함: 사용자 선택 완료

합의 방향: 원본 전송 ID/은행 원거래 ID 우선. 같은 금액·가게·분 단위 시각만으로 실제 결제를 합치지 않음. 사용자는 한 거래에서 동일 알림이 두 번 발생한 경험이 없으며, 모호한 경우 확인하거나 별도로 등록하는 방식을 고려한다고 설명했다.

선택: 강한 ID가 없는 모호한 유사 알림은 `needsReview` 후보로 보관하고 자동 원장 반영하지 않는다. 명확한 동일 원본/원장 ID의 재처리만 멱등 처리한다. 같은 금액·가게·분 단위 시각만으로 합치거나 별도 거래로 자동 확정하지 않는다.

원본 ID가 최초 앱 수신 시 생성되는 것과 단축어가 재시도 동안 동일 ID를 전달하는 것은 다르다. Core 테스트의 강한 delivery ID 계약을 정의하되 미래 단축어 adapter가 그 ID를 제공할 수 있는지 별도로 검증한다.

검토 예시: 같은 가게에서 30초 사이 5,000원 결제를 두 번 하면 10,000원 소비여야 한다. 은행/페이 알림 두 개로 보인 한 결제는 5,000원이다. 원문에 둘을 구별할 정보가 없으면 자동 판단은 불가능하다.

## D004 — 취소/환불과 예산 월: 사용자 선택 및 Core 규약 구현 완료

선택: 원거래를 보존하고 연결된 취소/환불 `adjustment`를 별도 기록한다. 실제 현금/부채 변동은 환불이 발생한 시점에 기록하고, 소비 반환은 원구매의 `BudgetMonth`에 귀속한다. 누적 반환이 원소비 금액을 넘거나 원거래/귀속 월 연결이 맞지 않으면 전체 커밋을 거부한다.

Core 범위에서는 조정 연결과 초과 반환 방지를 구현했다. 같은 반환의 취소 통지와 실제 입금 통지를 하나로 연결하는 수집/검토 상태 머신은 파싱·오케스트레이션 단계에서 별도로 구현한다.

## D005 — 저장 구현/이월/브랜치 공개: 논의 전

- 첫 저장소는 in-memory 계약 테스트 후 파일/SQLite 어댑터 후보를 비교. 특정 iOS DB로 확정하지 않음.
- 이월은 없음/양수만/음수 포함, 그룹 정책과 소급 변경을 구체적인 수치로 논의.
- 사용자 승인으로 준비 커밋 `2b8aefe`와 main/plan/local-first-core 기준점을 생성했다. 작성자는 사용자가 제공한 solhnsol 정보로 이 저장소에만 설정했다. 최초 push는 HTTPS/SSH 인증 부재로 실패했으나, 2026-10-06 사용자 GitHub 기기 인증 후 세 브랜치 업로드와 원격 커밋 일치 확인을 완료했다.
- 사용자 요청 범위의 플랫폼 경계 리팩터링은 refactor/platform-neutral-boundaries 브랜치에서 진행한다.

사용자는 Linux 환경을 고집할 필요가 없으며 더 빠른 Windows 환경에서 clone 후 이어갈 수 있다고 설명했다. 현재 작업은 Windows 인계가 가능한 소스/문서로 준비하고 환경별 검증 결과를 구분한다.

모든 설명은 결정 내용 → 사용자에게 보이는 예시 → 대안/비용 → 검증 방법 → 선택의 순서로 진행한다. 알고리즘은 입력/설정/버전을 명시하고 근거를 기록한다.

## D006 — 플랫폼 경계: 사용자 요청 범위로 구현

Swift Core를 유지하고 Apple framework/OS 객체/구체 DB 호출을 분리한다. Android 앱/KMP/JNI 또는 iOS 기능을 지금 구현하지 않는다.

최소 변경: 정규화는 Parsing에 배치, RawNotification은 순수 값, 원본 저장은 protocol, in-memory adapter는 별도 target. Foundation의 NFC 기능은 Linux 검증을 유지하고 불필요하게 다시 만들지 않는다. raw ID 동일 기록 재삽입/충돌 계약만 정의하며 금융 dedup 정책은 D003의 선택을 그대로 남긴다.

같은 Swift 엔진의 Android 재사용 후보는 공식 Android SDK/Java 연동 경로다. OS 중립 구조가 Android 실행·패키징 검증을 대신하지 않으며 해당 결정/검증은 추후 진행한다.

## D007 — candidate 저장과 ledger 승격: 사용자 선택 및 Core 계약 구현 완료

선택: parser는 `RawNotification -> TransactionCandidateDraft`까지만 책임지고 ledger를 직접 수정하지 않는다. Resolver/Assembler와 dedup/validation을 통과해 만들어진 `TransactionCandidate`에 대해 `CandidateProcessingRepository.process`가 candidate 저장과 ready candidate의 ledger 반영, 승격 연결 기록을 하나의 원자 작업으로 수행한다.

동일 candidate의 재처리는 revision이 오래됐더라도 멱등 결과를 반환한다. `needsReview`, `waitingForEvidence`, `rejected`는 저장만 하며 자동 승격하지 않는다. 새 입력이나 candidate 갱신에는 candidate revision을, ready 승격에는 ledger revision도 함께 확인한다. candidate 충돌, 중복 증거, stale revision, ledger 불변식 실패 시 전체 상태를 보존한다.

in-memory 구현은 후보 상태와 ledger 값을 복사해 모두 검증한 뒤 한 commit point에서 교체한다. 미래 SwiftData/SQLite adapter는 `process` 전체를 단일 DB transaction/CAS로 구현해야 하며 중간 candidate row만 남기거나 ledger만 반영해서는 안 된다.

영구적인 ledger validation 거부는 더 이상 예외로 candidate를 유실하지 않는다. Ledger는 전혀 변경하지 않은 채 candidate/review 상태와 typed rejection reason을 한 candidate transaction으로 저장한다. Stale revision 같은 일시적 동시성 오류만 throw하며, 같은 실패의 재시도는 같은 typed 결과를 반환한다.

## D008 — 금융 알림 ingestion 경계: 사용자 선택 및 Core 계약 구현 완료

선택: parser는 `RawNotification -> TransactionCandidateDraft`까지만 담당하며 repository나 ledger port를 받지 않는다. Draft에는 계좌/카드/ledger ID가 없다. `TransactionAccountResolver`가 계좌/카드를 바인딩하고 `TransactionCandidateAssembler`가 예산 월·이체 상대·환불 원거래를 적용해 candidate를 만든다. 시스템 시각·locale·DB 조회로 누락 정보를 추정하지 않는다.

한국어 baseline parser는 승인/사용/결제, 입금, 이체/송금, 취소/환불, 카드대금/결제대금과 원 단위 금액, 거래번호/승인번호처럼 문구에 명시된 사실만 읽는다. 강한 ID 부재와 merchant/payee 부재는 그 자체로 review 사유가 아니다. 거래 시각이 없으면 notification/capture timestamp를 provenance와 함께 fallback할 수 있다. 승인번호는 scoped evidence이지 전역 strong ID가 아니다. 유사 후보가 충돌할 때만 dedup 계층이 `ambiguousWithoutStrongIdentity`를 올린다.

운영 DB는 도구가 읽기 전용으로 확인하고 Git에는 완전 가상 샘플만 둔다. 현재 26개 합성 형식은 결정론/경계 smoke에 사용하며 실제 거래 관계나 잔액을 보존하지 않는다. 특정 은행/카드/페이 provider profile은 같은 protocol 아래 후속 구현하고 baseline 키워드를 provider 전체 형식 검증으로 과장하지 않는다.

## D009 — Calendar / Activity / Semantic 도메인: 사용자 제품 방향에 따른 구현 (Windows 범위)

선택: 제품 첫 가치는 "좋은 캘린더 UX + 좋은 가계부 UX + 하나의 생활 타임라인"이며 자동화는 점진적으로 강화한다. 의미 모델을 **Category(무엇에, canonical) / Activity(어떤 생활 활동에, OnAll 소유) / Tag(사용자의 세부 맥락) / Area(생활권)**로 나누고, **Calendar는 ActivityType과 별개의 축**으로 둔다. 반복적·공통적인 것은 자동화하고 개인 의미가 강할수록 사용자 결정을 우선하며, 잘못된 자동 분류보다 미분류를 택한다.

결정 요약(상세·근거·테스트 대응은 [calendar-domain.md](calendar-domain.md)):
- 새 순수 Swift target `NEOBudgetCalendar`(+ `NEOBudgetInMemoryCalendar`). 원장에는 쓰지 않고 `LedgerEntryID`/`Money`만 읽는다. EventKit·SwiftUI 코드는 없다.
- 외부 캘린더가 이벤트 필드의 원본이고, `Activity`는 별도 OnAll entity다(안정 `ActivityID`, 이벤트와의 association은 선택적, 지연 생성, 이벤트 삭제 시 `eventMissing`으로 보존, 이벤트 없는 `standalone` 가능).
- 거래–활동 연결은 시간 포함 관계가 아니라 의미 관계다(영화표·KTX·참가비 사전 구매 허용). `Activity 없음`은 정상(활동 외 소비). relation 종류(during/forActivity)는 필요가 생길 때까지 만들지 않는다. **(1거래:1활동 `TransactionActivityLink`는 D010에서 `TransactionAllocation`으로 대체되었다.)**
- 모든 자동 배정은 provenance(출처·신뢰도)를 가지며 **자동은 사용자 결정을 덮어쓰거나 지울 수 없고**, 신뢰도 부족(기본 0.85 미만, 값 없음)은 저장하지 않는다. Tag는 사용자의 기존 태그만 선택 가능하고 자동 생성 경로가 없다. Category는 canonical ID만 허용하고 `unclassified`가 명시적 상태다.
- `CalendarEventID`는 provider가 발급한 **불투명 토큰**이며 반복·식별자 안정성 가정을 코드에 두지 않는다. 반복 scope는 의도(`RecurrenceScope`)만 표현하고 provider가 지원 범위를 선언한다.
- UI/adapter 경계는 `CalendarCommand`/`CalendarCommandService`/`DayTimeline` read model이다. 쓰기 순서는 캘린더 먼저, 로컬 나중, 실패는 typed 결과(`partiallyApplied` 포함).
- drag/resize는 순수 정책(15분 snap, 줌 5분, 최소 15분, 겹침·자정 넘김 허용, 선택일 clip)이며 gesture UI는 만들지 않았다.

보류(Mac/Xcode 필요): EventKit adapter, SwiftUI, 권한, EKEvent identifier 안정성, 반복 이벤트 의미, 종일 종료일 관례, 변경 통지. 보류(Mac 무관): command 멱등성, 의도 로그 복구, undo, 이벤트 ID 변경 시 재바인딩, 비선형 시간 축, merchant DB/LLM, durable 저장소.

## D010 — 거래 분할·금액 지식·정산: 사용자 제품 요구에 따른 도메인 수정 (Windows 범위)

배경: D009의 1거래:1활동 링크는 현실적인 정산(80,000원 송금을 세 활동에 나눔)과 아직 거래가 없는 경제적 관계(상대가 점심을 결제해 내가 줄 돈이 생김)를 표현하지 못했다. 잘못된 abstraction을 호환성 때문에 유지하지 않고 모델을 바꿨다.

원칙(아키텍처 원칙으로 명시): OnAll은 불완전한 정보를 버리거나 억지로 확정하지 않고 알고 있는 수준 그대로 저장해 후속 evidence로 정밀하게 만든다. 실제 송금액이 obligation과 다르다는 것은 정산 실패의 증거가 아니라 다른 obligation이 상계되었을 가능성을 뜻한다. 유일하게 설명 가능한 경우에만 unknown을 자동으로 inferred로 승격한다.

결정 요약(상세·근거·테스트 대응은 [calendar-domain.md](calendar-domain.md)):
- **금액 지식** `AmountKnowledge`(unknown / range / estimated / inferred(evidence) / exact). inferred는 exact가 아니다. 사용자가 확정한 exact는 자동이 덮어쓰지 못하고, 자동은 지식을 약화하거나 알려진 범위와 모순되게 바꿀 수 없다(`AmountUpdatePolicy`). 집계(`AmountAggregate`)는 exact·inferred·estimated를 분리하고 하한/상한/미해결 수를 보존한다.
- **거래 분할** `TransactionAllocation`이 1:1 링크를 대체한다(N:M, 부분 금액, 알 수 없는 금액, 명시적 "활동 외"). 배분 합은 거래 총액을 넘지 못하고 남은 금액(remainder)을 표현한다. 거래 시각은 활동 시간과 무관하다. 원장은 변경하지 않는다.
- **"복합"은 category가 아니다.** 합계만 아는 구성요소는 `AmountGroup` 제약으로 보존하고(해석기는 유일 해일 때만 승격, 여럿이면 범위만 좁히고 선택하지 않음) canonical category에 복합을 추가하지 않는다.
- **Obligation**(payable/receivable, 거래 없이 존재, 상태는 settlement에서 유도), **Person**(OnAll 계정 무관), **SettlementRequest**(OnAll이 만든 요청 기록, 실제 전송 없음), **Settlement/SettlementAllocation**(N:M, 부분 정산, 부호 있는 net이 송금액과 같아야 함).
- **매처**는 단일 금액 비교가 아니라 열린 obligation 부분집합의 net을 송금액과 비교한다. 설명이 정확히 하나일 때만 `exactMatch/netMatch/inferredUniqueSolution`을 내고, 아니면 `ambiguous`(대안·합계 제약 보존)/`insufficientEvidence`/`noMatch`로 구분한다. 요청은 이미 맞는 설명들 사이에서 고르는 근거로만 쓴다.
- **Participant**를 Activity의 축으로 추가(`누구와`). 친밀도는 co-occurrence의 순수 함수(소규모·최근 가중, 대규모 억제)이며 관계 label(친구·연인·가족)은 추론하지 않고 사용자 입력에서만 설정된다.
- 기존 provenance 보호와 통합: 자동은 사용자 결정(링크·분할·참여자·금액·정산·group)을 덮어쓰거나 지우지 못하고, 낮은 신뢰도는 저장하지 않으며, 영구 실패는 typed 결과다.

보류(Mac/서버/외부 API 필요): Contacts 연동과 attendee→Person 해석, 메시지 전송·수신, 실제 송금/은행 API, OnAll 계정·친구 서버와 공유 identity, 지오코딩, LLM 분류. 보류(무관): 다중 통화 정산, 정산 송금의 예산 처리(소비/이체/수입 분류), command 멱등성, 의도 로그 복구, durable 저장소.
