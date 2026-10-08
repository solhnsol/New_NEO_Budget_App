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

## macOS / iOS (Xcode)

2026-10-08 Mac(Xcode 27.0, Swift 6.4)에서 `swift build`/`swift test` 452개와 iOS 27 시뮬레이터 `xcodebuild test`(스킴 `NEOBudgetCore-Package`) 452개가 통과했다. `xcode-select`가 CommandLineTools를 가리키면 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 지정한다.

EventKit 계약 테스트는 시뮬레이터에서만 돈다. `xctest` 실행기는 캘린더 권한을 받을 수 없어 사용 설명 키가 있는 앱 번들이 필요하다.

```bash
Platform/iOS/EventKitContractHost/run-contract.sh   # EventKit provider를 공용 계약에 통과시킴
Platform/iOS/EventKitSpike/run-spike.sh             # EventKit 동작 관찰(탐색용)
```

결과는 `docs/eventkit-spike.md`.

## OnAll iOS 앱

`Platform/iOS/OnAllApp/OnAllApp.xcodeproj`가 실제 앱 타깃이다(임시 spike 아님). 루트 Swift Package를 로컬 의존성으로 연결하며 `NEOBudgetCore`, `NEOBudgetCalendar`, `NEOBudgetEventKit`, `NEOBudgetInMemoryCalendar`, `NEOBudgetInMemoryStorage`를 쓴다. 소스는 파일 시스템 동기화 그룹이라 `OnAllApp/` 아래에 파일을 추가하면 프로젝트에 자동 포함된다. Xcode에서 열어 실행하거나 명령줄로 빌드/테스트한다.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -scheme OnAllApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

- 실행 인자 `-demo`(스킴의 Arguments에서 켠다)는 기기 캘린더를 건드리지 않고 합성 일정과 지출로 화면을 채운다.
- 실기기에서 실행하려면 Xcode에서 Signing Team을 지정한다. 프로젝트에는 팀을 넣지 않았다.
- 번들 ID는 `dev.onall.app`(임시). 정식 ID는 배포 전에 정한다.
- 단위 테스트는 레이아웃 계산(`TimelineGeometry`)을 다룬다. 도메인 규칙은 Swift Package 쪽 테스트가 소유한다.

현재 범위: 읽기 전용 Day Timeline(주간 스트립, 종일 행, 시간 격자, 겹침 열 배치, 지출 마커, 상세 시트, 권한 요청/거부 화면). 일정 편집(드래그/리사이즈/생성)은 다음 단계다.

원장 연결: 앱은 `AppLedger`(in-memory 처리 저장소를 가진 actor)의 스냅샷을 `LedgerTimelineProjection`으로 투영해 거래 마커를 만든다. 영속 저장소와 알림 수집은 아직 앱에 없으므로 일반 실행의 원장은 비어 있다. 실행 인자:
- `-demo`: 합성 캘린더 + 합성 원장(UI 회귀 확인용). 거래는 아래와 같은 실제 파이프라인을 거친다.
- `-ledger-sample`: 실제 기기 캘린더 + 합성 원장. 실제 캘린더 데이터 위에서 원장 파생 거래 표시를 확인한다.
합성 원장은 draft → assembler → 원자 승격을 통해 소비, 카드 사용, 환불, 그리고 소비가 아닌 월급·이체·카드 대금을 모두 담는다.

### Day Timeline: browse / edit 모드

타임라인은 두 가지 모양을 가진다. 둘 다 같은 `TimelineEditor.geometry`에서 나오며, 변하는 것은 시간축(`TimelineAxis`)뿐이다.

| | browse (기본) | edit (길게 눌러 진입) |
|---|---|---|
| 목적 | 하루를 한눈에 | 15분 단위로 정확하게 |
| 시간축 | 일정 경계와 지출 시각 주변은 원래 크기, 긴 빈 시간과 아주 긴 일정의 가운데는 접음(라벨에 길이 표시) | 선택한 일정 ±90분을 풀어서 크게(15분 ≥ 24pt). 멀리 있는 접힘은 그대로 |
| 리사이즈 핸들 | 없음 | 선택한 일정의 위·아래 핸들(●) |
| 전환 | 길게 누르면 부드럽게 확대(스크롤을 함께 보정해 손가락 아래 시각이 움직이지 않음), 손을 떼면 일정 전체가 보이게 맞춤 | "완료"나 빈 시간 탭으로 다시 접힘 |

연결된 거래는 별도 레일이 아니라 **해당 일정 블록 안**에 표시한다. 한 블록에 최대 3줄, 넘치면 `+N건`으로 접고, 한 줄만 들어갈 때는 "N건 · 합계" 요약 행, 줄이 하나도 안 들어가면 제목 줄의 요약 칩으로 대체한다. 블록 높이는 시간만 반영하므로 거래가 많아도 커지지 않는다(`InlineAllocationPlan`). 일정에 속하지 않은 지출만 시간축의 독립 마커로 남는다(오른쪽 레일).

편집은 제스처 중에는 캘린더에 쓰지 않고 로컬 미리보기만 갱신하며, 손을 뗄 때 `TimelineEditPolicy`로 확정한 범위를 `CalendarCommandService`에 **한 번** 보낸다.

| 동작 | 제스처 |
|---|---|
| 편집 모드 진입 | 일정을 길게 누르기. 누른 채 그대로 드래그하면 바로 이동 |
| 이동 | 편집 모드에서 일정 본체를 바로 드래그 (15분 단위, 길이 유지) |
| 시작/끝 조절 | 편집 모드의 핸들(●) 드래그 (최소 15분, 하단은 그날 끝까지) |
| 생성 | 빈 곳을 길게 누른 뒤 드래그 → 그 주변이 펼쳐져 15분 단위로 범위를 잡고, 제목·캘린더를 정해 저장 |
| 반복 일정 | 손을 뗀 시점에만 "이 일정만 / 전체 일정"을 묻는다. 날짜가 바뀌는 변경은 "이 일정만"만 가능. `thisAndFuture`는 노출하지 않는다 |

터치는 SwiftUI 제스처가 아니라 스크롤뷰에 붙인 UIKit 인식기(`EditGestureHost`)로 처리한다. 길게 누르기(0.3초)는 스크롤과 구분하고, 편집 모드의 pan은 **선택한 일정 영역에서 시작할 때만** 인식해서 나머지는 그대로 스크롤된다. SwiftUI의 `LongPressGesture.sequenced(before: DragGesture)`나 자식 뷰의 `DragGesture`는 스크롤을 막아서 쓰지 않는다.

실패하면 미리보기를 되돌리고 이유를 알린다: 다른 곳에서 바뀐 일정(`conflict`, 최신 내용으로 새로 고침), 읽기 전용 일정/캘린더, 저장 실패(재시도 가능하면 "다시 시도"가 사용자가 닫을 때까지 남는다), 삭제된 일정, 접근 꺼짐. 충돌 감지는 타임라인을 그릴 때의 `revisionToken`(`EventBlock.revisionToken`)을 기대 revision으로 보낸다. 편집 중인 일정이 다른 곳에서 바뀌면 확대 영역이 따라가고, 사라지면 편집 모드가 조용히 끝난다.

겹치는 일정의 열 배치(`OverlapLayout`)는 읽기 모델의 값을 그대로 쓰며, 좌표로 바뀌는 곳은 `TimelineGeometry.blockFrame` 한 곳이다. 다른 배치로 바꿀 때는 그 함수만 교체한다.

데모 모드 전용 디버그 인자: `-demo-preview edit|move|resize|create`(해당 상태로 멈춤), `-demo-fail-next-write`(첫 번째 쓰기를 실패시킴). 데모에는 읽기 전용 캘린더의 일정, 반복 일정, 한 일정에 연결된 거래 4건(`+N` 확인용)이 들어 있다.

테스트:
- `TimelineAxisTests`: 접기 규칙, 매핑의 단조성과 역변환, 확대 구간의 15분 높이, 접힘 라벨과 시각 라벨의 충돌, 화면용 설정값으로 하루가 한 화면에 가까운지.
- `InlineAllocationPlanTests`: 인라인 3줄 한도, `+N`, 요약 행/칩.
- `TimelineEditorTests`: 편집 모드 수명주기(진입·종료·스크롤 보정 요청·선택 유지·따라가기·생성 포커스), 확대 구간 안의 15분 단위 이동, 핸들 hit-test, 그리고 기존 이동/리사이즈/생성/반복 범위/충돌/읽기 전용/저장 실패(실제 `CalendarCommandService` + in-memory provider).
- `CommandFlowContract`: 같은 편집 흐름을 provider에 독립적으로 검사. in-memory는 `swift test`, EventKit은 `Platform/iOS/EventKitContractHost/run-contract.sh`.

아직 없는 것: 드래그 중 화면 가장자리 자동 스크롤, 종일 일정의 제스처 편집, VoiceOver용 편집 동작(현재 제스처만 있다), 일정 삭제. 편집 모드의 멀리 이동은 접힌 구간에서 거칠다(그 구간은 1pt가 여러 분이다). 놓은 뒤 확대 영역이 새 위치로 따라오므로 거기서 다듬는다.
