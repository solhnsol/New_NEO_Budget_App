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

2026-10-06 실제 Windows x86_64에서 Swift 6.4, Visual Studio Build Tools 2022 17.14, Windows 11 SDK 환경으로 `swift build` 성공을 확인했다. 플랫폼 경계 단계의 12개 테스트와 원장·후보 상태 단계에서 추가한 14개 테스트, 총 26개가 통과했다. 새 PowerShell이 설치 환경을 아직 반영하지 않은 경우 Visual Studio Developer Command Prompt를 로드하고 `SDKROOT`를 Swift의 `Windows.sdk` 경로로 지정해야 한다. Developer Mode가 꺼진 환경에서는 `.build/debug` 심볼릭 링크 생성 경고가 나왔지만 빌드와 테스트 결과에는 영향을 주지 않았다.

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
- 정규화·입력·원본 저장 12개와 원장·후보 상태 계약 14개, 총 테스트 26개.

실제 provider parser, candidate 저장과 원장 승격의 원자적 orchestration, 같은 반환 알림의 상태 연결, durable 저장소는 다음 단계다. 현재 테스트가 milestone 전체의 correctness를 검증하는 것은 아니다.
