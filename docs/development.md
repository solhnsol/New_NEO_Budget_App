# 개발 및 검증 환경

Core는 Swift Package이며 iOS SDK, Xcode, SwiftUI를 요구하지 않는다. 테스트 라이브러리는 Swift 도구에 포함된 Swift Testing을 사용한다. 런타임 외부 패키지는 없다.

## Windows

[공식 Swift Windows 설치 안내](https://www.swift.org/install/windows/)를 따른다. Swift뿐 아니라 Windows SDK와 C++ 빌드 도구가 필요하다. 기존 Visual Studio 설치가 있으면 필요한 구성 요소를 추가할 수 있으므로 먼저 설치 상태를 확인한다. 이 저장소는 도구를 자동 설치하지 않는다.

Swift 설치 후 새 PowerShell에서 확인:

```powershell
swift --version
git clone https://github.com/solhnsol/New_NEO_Budget_App.git
Set-Location New_NEO_Budget_App
# 작업 브랜치가 원격에 공개된 뒤 해당 브랜치를 선택한다.
swift build
swift test
```


2026-10-06 GitHub 인증 후 `main`, `plan/local-first-core`, `refactor/platform-neutral-boundaries` 업로드와 원격 커밋 일치 확인을 완료했다. Windows에서는 `refactor/platform-neutral-boundaries`를 clone해 이어서 작업한다. 명령은 `docs/handoff.md`를 참고한다.

2026-10-07 실제 Windows x86_64에서 Swift 6.4, Visual Studio Build Tools 2022 17.14, Windows 11 SDK 환경으로 `swift build`와 `swift test` 성공을 확인했다. ingestion 경계, red-team corpus, 합성 fixture, atomic promotion을 포함한 총 423개(Core 60 + Calendar 363)가 통과했다. Developer Mode 활성화 후 `.build/debug` 심볼릭 링크 경고도 더 이상 발생하지 않았다. 새 PowerShell이 설치 환경을 아직 반영하지 않은 경우 Visual Studio Developer Command Prompt를 로드하고 `SDKROOT`를 Swift의 `Windows.sdk` 경로로 지정해야 한다.

통과 기준: build 성공, 테스트 발견/실행, 실패 0개. Windows CI 도구/버전/공개는 별도 결정한다.

## 현재 에이전트 Linux 환경

Debian 13/aarch64. 시스템 Swift가 없어 공식 Swift 도구를 저장소의 `.tooling/`에 격리해 준비한다. `.tooling/`은 Git에서 제외되며 앱이나 Core의 배포 의존성이 아니다.

Package의 최소 manifest 버전은 Swift 6.0이다. 모든 지원 Swift 버전을 검증했다는 의미는 아니다. 실제 사용한 도구 버전과 테스트 결과를 기록한다.

검증 결과: Swift 6.4, Debian 13/aarch64에서 빌드 및 Swift Testing 12개 통과. Windows x86_64에서도 동일한 12개 테스트를 통과했다. Linux의 새 기본 Swift Build 실행은 격리된 libncurses 경로가 하위 링크 명령에 전달되지 않아 실패했고, 이 환경에서는 SwiftPM의 native build system으로 실제 실행을 완료했다. 이것은 Linux 도구 환경에 대한 우회이며 앱 소스 변경은 아니다.

이 Linux 환경에서 실행한 명령:

```bash
LD_LIBRARY_PATH="$PWD/.tooling/system-libs/usr/lib/aarch64-linux-gnu" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.tooling/module-cache" \
CLANG_MODULE_CACHE_PATH="$PWD/.tooling/clang-cache" \
.tooling/swift-6.4.0-RELEASE-debian13-aarch64/usr/bin/swift test \
  --build-system native --scratch-path .build/native \
  --cache-path .tooling/cache --config-path .tooling/config \
  --security-path .tooling/security
```

native 옵션은 사용한 도구에서 deprecated 안내가 있으므로 Windows에 이 우회를 그대로 강제하지 않는다. Windows의 정상 설치에서 기본 `swift test`를 먼저 확인한다.

## 현재 구현 범위

- Swift Package와 테스트 target.
- 원문 NFC/공백/줄바꿈 정규화 및 알림 필드 연결. 원문을 수정하거나 거래를 합치지 않는다.
- 중립 RawNotification과 원본 저장 protocol, 별도 in-memory adapter.
- 실제 계좌 `Posting`, 카드 `LiabilityChange`, 소비 귀속 `BudgetImpact`를 분리한 원장 값 모델.
- revision 조건부 원자 커밋, 강한 원장 ID 멱등성, 이체/카드 납부/환불/금액 보존 불변식과 projection을 제공하는 저장 protocol 및 in-memory adapter.
- candidate 저장과 ready candidate ledger 승격을 한 commit point로 묶는 Core protocol 및 in-memory adapter.
- repository/ledger 의존성 없이 `TransactionCandidateDraft`만 만드는 parser와 account resolver/assembler, dedup 계약.
- 합성 알림 26개 형식의 결정론/provenance 및 의미 검증을 포함한 Swift 테스트 452개(Core 60 + Calendar 392)와 test-data Python 테스트 7개. D012의 머니 플로우 일관성 테스트(시나리오 O~W, 보존 불변식 sweep)는 `MoneyFlowConsistencyTests.swift`.

provider별 상세 fixture/profile, provider 간 같은 거래 evidence 결합, 같은 반환 알림의 상태 연결, durable 저장소는 다음 단계다. parser는 ledger를 직접 변경하지 않고 `RawNotification -> TransactionCandidateDraft`까지만 담당한다. 현재 테스트가 milestone 전체의 correctness를 검증하는 것은 아니다.

## 머니 플로우 red-team 검증 (D012)

Linux x86_64 에이전트 환경에서는 `download.swift.org`가 막혀 Docker Hub의 공식 `swift:6.0-noble` 이미지 레이어에서 Swift 6.0.3 툴체인을 풀어 사용했다(저장소 밖). 이 환경의 결과: `swift build --build-tests`, `swift test` 452개 통과, test-data Python 테스트 7개 통과, `git diff --check` 깨끗함, Sources/Package에서 Apple 전용 API(`UIKit`/`SwiftUI`/`EventKit`/`CoreData` 등 import, `UserDefaults`, `EKEventStore`) 검색 결과 없음. Swift 6.0.3은 6.4보다 지역 변수 이름 가림(shadowing)에 엄격해 `SettlementMatcher`의 지역 변수 한 개를 개명했다(동작 변화 없음). Windows 재검증은 별도로 필요하다.
