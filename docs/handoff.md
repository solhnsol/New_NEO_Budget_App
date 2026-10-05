# Windows 세션 인계

현재 작업 브랜치: `refactor/platform-neutral-boundaries`. 2026-10-06 GitHub 업로드 및 원격 커밋 일치 확인 완료. `main`과 `plan/local-first-core`는 준비 커밋 `2b8aefe`, 작업 브랜치는 Core 경계 리팩터링 `607abf2`와 이후 인계 문서 수정 커밋을 포함한다.

## 확정된 방향

- 자체 local-first/offline-first 가계부. Actual/FastAPI 실행 의존성 없음.
- 순수 Swift Package Core. Windows에서 개발하고 이후 iOS가 같은 모듈 사용.
- 금융 행위와 실제 계좌 잔액 변동 분리. 카드를 별도 가계부 계좌로 만들지 않고 결제 수단/미납 의무로 표현.
- 같은 금액/가게/시간만으로 거래를 합치지 않음. 명확한 같은 원본 재처리는 한 번만 반영.
- iOS UI/플랫폼 연동/클라우드/구매/배포는 현재 구현하지 않음.
- 사용자와 의사결정을 함께 진행하고 결과 예시/비용/대안을 설명. 짧은 긍정으로 새 정책을 임의 확정하지 않음.

## 코드 상태

Swift Package, 중립 RawNotification, Parsing의 Foundation 기반 알림 텍스트 정규화, 원본 저장 protocol/별도 in-memory adapter, Swift Testing 테스트 12개. 실제 iOS/Android 코드는 없고 Platform에는 경계 문서만 있다. 금융 원장/실제 provider parser/중복/예산은 아직 설계 초안이다. `docs/core-plan.md`, `docs/legacy-analysis.md`, `docs/decisions.md`, `docs/platform-boundary-review.md`를 먼저 읽는다.

## 다음 논의

1. 강한 ID 없는 모호한 유사 알림: 확인 후보 보관 vs 별도 거래 반영+중복 의심 표시.
2. 지난달 구매의 이번 달 환불: 이번 달 소비 상쇄 vs 원구매 월 수정/이월 재계산. 앞서 사용자에게 제시한 질문은 아직 답을 받지 못했다.
3. 최소 원장 부호/금액 범위, 카드 미납/납부/환불 규약과 in-memory 저장 계약을 예시로 설명하고 구현.
4. Windows에서 작업 브랜치를 clone하고 Swift 빌드/테스트 검증. 실제 Windows 검증은 아직 수행하지 않았다.

## 환경 및 검증

기존 Linux JS 알림 테스트: 48개 중 46개 통과, SQLite 관련 2개 skipped. 새로운 Swift Core의 Windows 검증을 뜻하지 않는다.

새 Swift 테스트: Swift 6.4/Debian 13/aarch64 빌드 성공, 12개 통과. 격리된 도구 환경 때문에 native build system을 사용했으며 상세 명령은 development.md에 기록했다. Windows의 기본 빌드/테스트와 Android 실행은 별도 검증 필요.

Linux 테스트 도구는 `.tooling/`에 격리돼 있으며 Git에서 제외된다. Windows로 가져갈 대상은 소스/테스트/문서이며 이 Linux 도구 폴더는 필요 없다.

브랜치 공개 후 Windows에서 clone하고 공식 Swift Windows 설치 안내를 따라 `swift --version`, `swift build`, `swift test`를 실행한다. 실패하면 실제 출력과 도구 버전을 기록하고 수정한다. Mac/Xcode나 iOS SDK를 설치하는 단계는 없다.

실제 금융 알림 샘플은 현재 새 저장소에 복사하지 않았다. 기존 테스트/40개 fixture의 형식과 시나리오는 분석했으며, 원문을 가져오기 전에 익명화한다.

## GitHub에서 Windows로 이어받기

```powershell
git clone --branch refactor/platform-neutral-boundaries https://github.com/solhnsol/New_NEO_Budget_App.git
Set-Location New_NEO_Budget_App
swift --version
swift build
swift test
```

공식 Swift Windows 설치를 먼저 완료한다. clone은 현재 공개 저장소에서 인증 없이 가능하며, Windows에서 이후 push할 때는 해당 환경의 GitHub 인증이 필요하다. Linux의 `.tooling/`이나 인증 정보를 Windows로 복사하지 않는다.

기존 `New_NEO_Budget_App.bundle`은 초기 두 커밋을 보관한 오프라인 백업이며 이후 문서 커밋은 포함하지 않는다. 이어서 작업할 때는 GitHub의 최신 작업 브랜치를 사용한다.
