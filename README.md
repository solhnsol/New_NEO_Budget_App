# New NEO Budget App

iPhone 내부에서 원본 금융 알림과 거래 원장을 보관하고, 서버 없이 파싱·예산·정산·분석을 실행하는 가계부 프로젝트.

현재 단계는 플랫폼 독립 Core 설계다. Windows에서 개발·검증할 수 있는 구성부터 만든다. Actual/FastAPI는 앱 실행 의존성에 포함하지 않는다.

- [기존 코드 분석](docs/legacy-analysis.md)
- [Core 설계와 구현 계획](docs/core-plan.md)
- [금융 알림 parser 계약](docs/notification-parser.md)
- [공동 의사결정 기록](docs/decisions.md)
- [Windows 개발 및 검증 안내](docs/development.md)
- [플랫폼 경계 점검 결과](docs/platform-boundary-review.md)
- [RPi 테스트 자료 생성 및 자동화](docs/test-data-pipeline.md)
- [Red-team 위험 대응 현황](docs/redteam-closure.md)
- [Calendar / Activity / Semantic 도메인](docs/calendar-domain.md)

구현 언어는 순수 Swift Package로 합의했다. 실제 현금 흐름과 소비 예산 귀속을 분리하는 첫 원장 규약까지 합의·구현했다. Windows Swift 6.4 x64에서 빌드와 테스트를 통과했다.

현재 구현은 중립 `RawNotification`, facts-only `TransactionCandidateDraft`, account resolver/assembler, dedup validation, `Posting`/`LiabilityChange`/`BudgetImpact` 원장 모델과 in-memory 참조 adapter를 포함한다. Parser는 `RawNotification -> TransactionCandidateDraft`만 수행하고, `CandidateProcessingRepository`가 candidate 저장과 ready candidate의 ledger 반영을 하나의 원자 작업으로 정의한다. `swift build`, `swift test`로 실행한다. provider별 상세 fixture parser와 durable 저장소는 아직 구현하지 않았다.

현재 검증: Core/ingestion/atomic promotion/calendar·activity·정산·정정·정책·소비 성격 테스트 423개가 Windows x86_64에서 통과했다. 합성 알림 26개 형식의 결정론/provenance 및 kind/direction/amount 검증을 포함한다. 로컬 데이터 생성 도구 Python 테스트 7개도 통과한다. Android/iOS의 실제 실행은 별도 확인 필요.

`NEOBudgetCore`는 Platform/Infrastructure를 의존하지 않는다. `NEOBudgetInMemoryStorage` target이 Core protocol을 구현한다. `NEOBudgetCalendar`는 EventKit/SwiftUI 없이 Calendar·Activity·Tag·Area·Person 도메인, 금액 지식·거래 분할·Obligation·Settlement(상계/유일 해 추론/residual), 경제적 정정, 정산 정책·공유 지출, Spending Nature·Category 4상태, day timeline read model, drag/resize 정책, command 계약을 제공하고 `NEOBudgetInMemoryCalendar`가 테스트용 fake를 제공한다. `Platform/iOS`, `Platform/Android`는 향후 adapter 경계 문서만 있으며 빌드 target이나 실제 플랫폼 코드가 아니다.
