# Windows 세션 인계

현재 작업 브랜치: `refactor/platform-neutral-boundaries`. 준비 커밋 `2b8aefe`를 main/plan/local-first-core에 만들었다. 사용자가 commit/push를 승인했지만 GitHub 인증이 없어 push에 실패했다. 원격 공개 완료로 오해하지 않는다.

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
4. GitHub 인증 복구와 원격 push 또는 bundle Windows 인계. 실제 Windows 검증 방식은 선택 필요.

## 환경 및 검증

기존 Linux JS 알림 테스트: 48개 중 46개 통과, SQLite 관련 2개 skipped. 새로운 Swift Core의 Windows 검증을 뜻하지 않는다.

새 Swift 테스트: Swift 6.4/Debian 13/aarch64 빌드 성공, 12개 통과. 격리된 도구 환경 때문에 native build system을 사용했으며 상세 명령은 development.md에 기록했다. Windows의 기본 빌드/테스트와 Android 실행은 별도 검증 필요.

Linux 테스트 도구는 `.tooling/`에 격리돼 있으며 Git에서 제외된다. Windows로 가져갈 대상은 소스/테스트/문서이며 이 Linux 도구 폴더는 필요 없다.

브랜치 공개 후 Windows에서 clone하고 공식 Swift Windows 설치 안내를 따라 `swift --version`, `swift build`, `swift test`를 실행한다. 실패하면 실제 출력과 도구 버전을 기록하고 수정한다. Mac/Xcode나 iOS SDK를 설치하는 단계는 없다.

실제 금융 알림 샘플은 현재 새 저장소에 복사하지 않았다. 기존 테스트/40개 fixture의 형식과 시나리오는 분석했으며, 원문을 가져오기 전에 익명화한다.

## 원격 인증 없이 Windows로 먼저 옮기기

이력과 세 브랜치를 담은 `New_NEO_Budget_App.bundle`을 생성해 검증했다. 이 파일에는 `.tooling/`, 빌드 캐시, GitHub 인증 정보가 들어가지 않는다. 현재 checkpoint의 bundle을 다운로드한 폴더에서:

```powershell
git clone --branch refactor/platform-neutral-boundaries .\New_NEO_Budget_App.bundle New_NEO_Budget_App
Set-Location New_NEO_Budget_App
git remote rename origin offline-bundle
git branch main offline-bundle/main
git branch plan/local-first-core offline-bundle/plan/local-first-core
git remote add origin https://github.com/solhnsol/New_NEO_Budget_App.git
```

Windows Git의 GitHub 인증을 완료한 뒤 원격에 공개한다:

```powershell
git push origin main plan/local-first-core refactor/platform-neutral-boundaries
swift test
```

이는 Windows 인계를 선택했을 때 사용할 경로이며 현재 원격 push가 성공했다는 의미가 아니다. bundle 이후 새 커밋이 생기면 최신 bundle 또는 원격 브랜치를 사용한다. 소스만 ZIP으로 복사하는 것과 달리 bundle은 커밋 작성자와 브랜치 이력을 유지한다.
