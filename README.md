# New NEO Budget App

iPhone 내부에서 원본 금융 알림과 거래 원장을 보관하고, 서버 없이 파싱·예산·정산·분석을 실행하는 가계부 프로젝트.

현재 단계는 플랫폼 독립 Core 설계다. Windows에서 개발·검증할 수 있는 구성부터 만든다. Actual/FastAPI는 앱 실행 의존성에 포함하지 않는다.

- [기존 코드 분석](docs/legacy-analysis.md)
- [Core 설계와 구현 계획](docs/core-plan.md)
- [공동 의사결정 기록](docs/decisions.md)
- [Windows 개발 및 검증 안내](docs/development.md)
- [플랫폼 경계 점검 결과](docs/platform-boundary-review.md)

구현 언어는 순수 Swift Package로 합의했다. 금융 정책은 사용자와 합의 중이다. Windows 테스트를 통과한 상태는 아니다.

현재 구현은 중립 `RawNotification`, 알림 텍스트 정규화, 원본 저장 protocol과 별도 in-memory adapter다. `swift build`, `swift test`로 실행한다. 거래 원장 milestone은 아직 완료되지 않았다.

현재 검증: Swift 6.4/Linux에서 정규화·입력·저장 계약 테스트 12개 통과. Windows/Android/iOS의 실제 실행은 별도 확인 필요.

`NEOBudgetCore`는 Platform/Infrastructure를 의존하지 않는다. `NEOBudgetInMemoryStorage` target이 Core protocol을 구현한다. `Platform/iOS`, `Platform/Android`는 향후 adapter 경계 문서만 있으며 빌드 target이나 실제 플랫폼 코드가 아니다.
