# Windows 세션 인계

현재 작업 브랜치: `refactor/ingestion-pipeline`. 기존 parser 구현과 원자 승격 위에 Claude의 parser 계약 문서 및 sanitized test-data 브랜치를 통합하고 ingestion 경계를 재정의했다.

## 확정된 방향

- 자체 local-first/offline-first 가계부. Actual/FastAPI 실행 의존성 없음.
- 순수 Swift Package Core. Windows에서 개발하고 이후 iOS가 같은 모듈 사용.
- 금융 행위와 실제 계좌 잔액 변동 분리. 카드를 별도 가계부 계좌로 만들지 않고 결제 수단/미납 의무로 표현.
- 강한 ID 부재 자체는 review 사유가 아니다. 같은 금액/방향/근접 시각의 유사 후보가 충돌할 때 dedup이 `needsReview`로 남기며 자동 반영하지 않는다. 명확한 같은 strong evidence나 같은 candidate 재처리는 한 번만 반영.
- 환불 현금 흐름은 실제 발생 시점에 기록하되 소비 반환은 원구매 월에 귀속. 원거래를 보존하고 연결 조정으로 기록.
- iOS UI/플랫폼 연동/클라우드/구매/배포는 현재 구현하지 않음.
- 사용자와 의사결정을 함께 진행하고 결과 예시/비용/대안을 설명. 짧은 긍정으로 새 정책을 임의 확정하지 않음.

## 코드 상태

Swift Package, 중립 RawNotification, facts-only Draft parser, account resolver/assembler, dedup validator, 원본 저장 protocol/별도 in-memory adapter와 첫 원장 모델이 있다. Parser는 repository/ledger를 의존하지 않고 Draft만 만든다. `CandidateProcessingRepository`가 dedup safety gate, candidate 저장과 ready ledger 승격을 원자 처리하고 non-ready 상태의 자동 승격을 막는다. Swift Testing 총 423개(Core 60 + Calendar 363)가 Windows에서 통과한다. 별도 순수 Swift target `NEOBudgetCalendar`가 Calendar/Activity/Tag/Area/Person 도메인, 금액 지식·거래 분할·Obligation·Settlement(상계·유일 해 추론·residual), 경제적 정정, 사람별 정산 정책과 공유 지출 component, Spending Nature·Category 4상태, 참여자 친밀도, DayTimeline read model, drag/resize 정책, command 계약을 제공한다(`docs/calendar-domain.md`, D010, D011). 실제 iOS/Android 코드와 durable 저장소는 없다. `docs/core-plan.md`, `docs/notification-parser.md`, `docs/decisions.md`, `docs/parser-contract.md`, `docs/redteam-closure.md`, `docs/calendar-domain.md`를 먼저 읽는다.

## 다음 논의

1. 합성 26개 형식과 parser fixture matrix를 provider별 executable fixture/profile로 확장.
2. 서로 다른 provider raw가 같은 금융 거래일 때 promotion 전에 evidence를 결합하는 correlator/dedup 단계.
3. SQLite 등 durable 저장 adapter 선택과 migration/원자성 계약.
4. 취소 통지와 실제 환급 입금 통지가 같은 반환일 때 중복 상쇄하지 않는 상태 연결.
4. Windows 검증은 2026-10-06 완료했다. 다음 구현에서도 같은 환경에서 빌드/테스트를 유지한다.

## 환경 및 검증

기존 Linux JS 알림 테스트: 48개 중 46개 통과, SQLite 관련 2개 skipped. 새로운 Swift Core의 Windows 검증을 뜻하지 않는다.

기존 플랫폼 경계 테스트를 포함해 ingestion/원장/red-team/원자 처리 총 423개(Core 60 + Calendar 363)는 Swift 6.4/Windows x86_64에서 통과했다. test-data Python 테스트 7개도 통과한다. Developer Mode 활성화 뒤 SwiftPM 심볼릭 링크 경고도 사라졌다. Android 실행은 별도 검증 필요.

Linux 테스트 도구는 `.tooling/`에 격리돼 있으며 Git에서 제외된다. Windows로 가져갈 대상은 소스/테스트/문서이며 이 Linux 도구 폴더는 필요 없다.

Windows에서 공식 Swift Windows 설치 안내에 따라 Swift 6.4, Python 3.10, Visual Studio 2022 C++ Build Tools와 Windows 11 SDK를 구성했다. Visual Studio 개발자 환경과 `SDKROOT`를 사용해 `swift --version`, `swift build`, `swift test`를 검증했다. Mac/Xcode나 iOS SDK를 설치하는 단계는 없다.

운영 금융 알림 원문은 저장소에 복사하지 않는다. 읽기 전용 도구가 생성한 완전 가상 샘플 26개 형식만 Git에 포함하며 실제 거래 관계와 잔액은 보존하지 않는다.

## GitHub에서 Windows로 이어받기

```powershell
git clone --branch refactor/platform-neutral-boundaries https://github.com/solhnsol/New_NEO_Budget_App.git
Set-Location New_NEO_Budget_App
swift --version
swift build
swift test
```

공식 Swift Windows 설치를 먼저 완료한다. `feat/core-domain-storage`는 아직 로컬 작업이므로 push 전에는 위 기반 브랜치만 clone할 수 있다. clone은 현재 공개 저장소에서 인증 없이 가능하며, Windows에서 이후 push할 때는 해당 환경의 GitHub 인증이 필요하다. Linux의 `.tooling/`이나 인증 정보를 Windows로 복사하지 않는다.

기존 `New_NEO_Budget_App.bundle`은 초기 두 커밋을 보관한 오프라인 백업이며 이후 문서 커밋은 포함하지 않는다. 이어서 작업할 때는 GitHub의 최신 작업 브랜치를 사용한다.
