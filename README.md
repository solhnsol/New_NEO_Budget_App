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

구현 언어는 순수 Swift Package로 합의했다. 실제 현금 흐름과 소비 예산 귀속을 분리하는 첫 원장 규약까지 합의·구현했다. Windows Swift 6.4 x64에서 빌드와 테스트를 통과했다.

현재 구현은 중립 `RawNotification`, 한국어 금융 알림의 엄격한 baseline parser, `Posting`/`LiabilityChange`/`BudgetImpact` 원장 모델과 in-memory 참조 adapter를 포함한다. Parser는 `RawNotification -> TransactionCandidate`만 수행하고, `CandidateProcessingRepository`가 candidate 저장과 ready candidate의 ledger 반영을 하나의 원자 작업으로 정의한다. `swift build`, `swift test`로 실행한다. 실제 provider별 익명화 fixture와 durable 저장소는 아직 구현하지 않았다.

현재 검증: Core/parser 테스트 46개가 Windows x86_64에서 통과했다. sanitized fixture 브랜치에서는 Swift 6.4/Linux의 정규화·입력·저장·가상 알림 커버리지 테스트 13개와 로컬 데이터 생성 도구 Python 테스트 7개가 통과했다. 통합 후 전체 수치는 이 브랜치에서 다시 검증한다. Android/iOS의 실제 실행은 별도 확인 필요.

`NEOBudgetCore`는 Platform/Infrastructure를 의존하지 않는다. `NEOBudgetInMemoryStorage` target이 Core protocol을 구현한다. `Platform/iOS`, `Platform/Android`는 향후 adapter 경계 문서만 있으며 빌드 target이나 실제 플랫폼 코드가 아니다.
