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
| 시간축 | 일정 경계와 지출 시각 주변은 원래 크기, 긴 빈 시간과 아주 긴 일정의 가운데는 접음(접힘은 길이 라벨 없이 `⋮` 표시만) | **browse와 같다.** 편집 모드에 들어가도 시간축은 바뀌지 않는다. 핸들을 잡고 끌다가 멈추면 그 시각 주변(±45분)만 확대한다 |
| 리사이즈 핸들 | 없음 | 선택한 일정의 위·아래 핸들(●) |
| 전환 | — | 진입·종료 모두 **화면에서 아무것도 움직이지 않는다**(핸들만 나타나고 사라진다). "완료"나 빈 시간 탭으로 종료 |

연결된 거래는 별도 레일이 아니라 **해당 일정 블록 안**에 표시한다. 접힌(기본) 블록은 **금액이 큰 순으로 최대 2건**을 보이고, 나머지는 `+N건 · 합계 …`로 접는다(`InlineAllocationPlan`, `AllocationOrdering`). 높이가 모자라면 한 줄 요약 행("N건 · 합계"), 한 줄도 안 들어가면 제목 줄의 요약 칩으로 대체한다. 블록 높이는 시간만 반영하므로 거래가 많아도 커지지 않는다. 금액 순위에서 추정 금액은 그 값으로, 범위는 하한으로 세고 금액이 아예 없는 거래만 맨 뒤로 간다. 합계는 환불을 빼고 통화를 섞지 않으며 미확정이 있으면 그렇게 말한다(`LinkedTotal`). 일정에 속하지 않은 지출만 시간축의 독립 마커로 남는다(오른쪽 레일).

#### 핸들 드래그 중 확대 영역 이동 (`TimelineEditor.zoomAtFinger`)

- 편집 모드에서 시간축은 바뀌지 않으므로, 확대는 **핸들을 잡은 뒤** 손가락이 400ms 멈췄을 때(또는 잡은 채 움직이지 않았을 때) 한 번에 한 곳만 생긴다. 움직이는 손가락 아래에서는 시간축을 바꾸지 않는다.
- 확대 전후로 **선택된 시각은 바뀌지 않는다**. 그 시각의 화면 위치가 변하지 않도록 내용을 같은 양만큼 옮기고, 드래그 기준점(`fingerAnchorY`)도 새 시간축에 맞춰 다시 잡는다(좌표 연속성). 손가락과 핸들 사이의 간격도 유지된다.
- 시간축이 바뀌는 0.35초 동안의 손가락 값은 실제 드래그가 아니므로 무시한다.
- 확대는 **시작·종료 핸들만** 한다. 일정 이동이나 새 일정 만들기는 움직이는 동안 시간축이 바뀌면 안 되므로 멈춰도 확대하지 않는다. 이미 충분히 큰(편집 배율 이상) 곳에서는 아무 것도 하지 않는다.
- 4pt 이하의 떨림은 "멈춤"으로 본다. 손을 떼거나 취소하면 대기를 취소하고 확대 영역을 거두며, 확정 후에는 방금 움직인 가장자리가 제자리에 남는다.
- 확대 영역이 열릴 때 가벼운 햅틱(선택 틱)이 나온다.

#### 시간축이 바뀔 때: 하나의 값으로 모든 것을 그린다 (`AxisTransition`)

시간축의 모양이 바뀌는 모든 경우(확대 영역 이동, 확대를 거둘 때, 열린 일정이 닫힐 때 등)는 하나의 `AxisTransition`(이전 모양, 새 모양, 기준 시각이 움직인 거리 `delta`)이 된다. 원인과 해법:

- **SwiftUI 애니메이션과 UIKit 스크롤 보정은 서로 다른 시계라 어긋난다.** 그래서 애니메이션을 쓰지 않는다. 진행도는 **시계로 계산한 하나의 숫자**(`AxisTransition.progress(at:)`, easeInOut 0.25초)이고, 매 프레임 `TimelineView`가 그 값으로 그린다. 이전 변화를 이어받아 겹치는(additive) 보간이 없어서 변화가 변화를 대체해도 값이 튀지 않는다.
- 일정 본체, 핸들, 시간 눈금, 접힘, 지출 마커, 미리보기가 모두 같은 `TimelineGeometry`(두 모양의 블렌드)에게 위치를 묻는다. 따로 움직일 수 없다. 눈금·접힘 표시는 한쪽 모양에만 있으면 페이드한다.
- **스크롤뷰는 변화가 끝날 때까지 제자리에 둔다.** 대신 내용을 `delta × 진행도`만큼 옮겨 기준 시각을 같은 자리에 붙잡고, 끝나는 순간 스크롤뷰를 `delta`만큼 한 번에 옮기면서 같은 갱신에서 내용 이동을 지운다. 두 값이 정확히 상쇄되어 화면은 변하지 않는다.
- 변화 중 내용 높이는 줄어들지 않는다(`TimelineGeometry.contentHeight`). 줄어들면 UIKit이 스크롤 위치를 강제로 줄여서(오프셋 clamp) 화면이 엉뚱한 양만큼 움직인다.
- 스크롤뷰가 따라갈 수 있는 범위(`ScrollProbe.shiftRange`)를 넘는 이동은 미리 그 범위로 줄인다. 그렇지 않으면 끝에서 한 번에 튄다. 짧은 하루에서는 편집 중 아래쪽 여유(320pt)가 필요하며, 확대 영역이 있거나 드래그 중일 때만 둔다.
- **확대를 반복해도 일정의 다른 쪽 가장자리는 화면에 남는다.** 확대 영역은 손가락을 붙잡으려고 내용을 밀기 때문에, 위아래로 반복하면 밀림이 쌓여 원래 일정이 화면 밖으로 나갔다. 이제 새 확대 영역을 열 때 일정의 다른 가장자리(끝 핸들을 끌면 시작)가 화면에 있으면 그대로 있도록, 그 가장자리를 향한 쪽 반경을 45분에서 30·15·0분으로 줄인다(`TimelineEditor.radii`). 이미 화면 밖이면 건드리지 않는다.
- **놓을 때 드래그가 필요로 했던 스크롤을 전부 돌려준다**(`dragShift`). 확대가 열릴 때마다 손가락을 붙잡으려고 내용을 밀었는데, 놓고 나서 그만큼을 돌려주지 않으면 화면이 처음보다 위로 밀린 채 남는다(맨 위 일정을 늘렸다가 제자리로 놓으면 위쪽 영역이 잘려 있다가 한꺼번에 들어오던 문제). 이제 놓으면 핸들을 잡았을 때의 스크롤 위치로 부드럽게 돌아간다. 스크롤뷰가 그 위치를 가질 수 없으면(확대가 사라지며 여유 공간도 사라질 때) 끝에서 UIKit이 한 번에 clamp하지 않도록 변화를 계획할 때 이미 그 한계로 줄인다.
- 구조가 다른 `if/else`로 내용을 바꾸면 SwiftUI가 다른 뷰로 보고 격자·제스처 인식기·스크롤 위치를 통째로 다시 만든다. 그래서 변화 중에도 같은 뷰 구조를 유지한다. 새로 만들어진 제스처 호스트는 이전 스크롤 명령을 다시 실행하지 않는다.
- 측정: 데모 `-demo-preview script-zoom`이 24시간 일정에서 핸들 드래그(빠른 이동 → 멈춤 → 15분 조정 → 놓기 → 종료)를 실제 시간으로 재생한다. 화면을 녹화해 프레임마다 블록·핸들·눈금의 Y를 읽었다(편집 진입: 변화 없음, 확대: 손가락 아래 핸들이 모든 프레임에서 같은 Y, 놓기: 블록 가장자리가 단조롭게 이동하고 마지막 프레임에서 튀지 않음).

### 일정 탭: 제자리 확장

일정을 **탭하면 화면 전환 없이 그 블록이 펼쳐진다**(`ExpandedBlockView`). 한 번에 하나만 열리고, 다른 일정을 탭하면 기존 것은 접히고 새 것이 열린다. 같은 일정을 다시 탭하거나 빈 시간을 탭하면 접힌다.

- **보여 주는 것**: 제목, 시간, 캘린더, 그리고 Activity가 가진 유형·장소·참여자("나, 가영 외 2명")·태그. 이름은 읽기 모델의 `ActivityBadge.display`(`ActivityDisplay`)가 `LifeState`에서 풀어 주므로 UI는 조회하지 않는다. Activity에 아직 정보가 없으면 그렇게 말한다. 연결된 **거래 전체를 시간순**으로(다른 날 결제는 날짜로) 보이고 합계를 함께 보인다.
- **일정 내부 시간축**: 열린 일정의 시간 구간만 블록이 내용만큼 높아지도록 확대한다(`TimelineEditor.expansion`). 안쪽에 15분 눈금이 열린다. 일정의 위쪽은 그대로라 화면에서 블록의 윗변이 움직이지 않고, 열린 일정은 이웃 위로 전체 폭을 쓴다.
- **시간 조정과 분리**: 길게 누르기는 그대로 시간 이동/리사이즈(편집 모드)다. 두 모드는 서로 배타적이라 길게 누르면 확장이 닫히고 편집 모드로 들어가며, 편집 중에 탭하면 편집이 끝나고 그 일정이 열린다. 제스처나 결정이 진행 중일 때의 탭은 무시한다.
- 읽기만 한다. 제목·참여자 인라인 수정은 다음 단계, 복잡한 속성은 이후의 Inspector로 둔다. 새 화면과 큰 폼은 없다. 종일 일정과 지출 마커는 기존처럼 상세 시트를 쓴다.

편집은 제스처 중에는 캘린더에 쓰지 않고 로컬 미리보기만 갱신하며, 손을 뗄 때 `TimelineEditPolicy`로 확정한 범위를 `CalendarCommandService`에 **한 번** 보낸다.

| 동작 | 제스처 |
|---|---|
| 일정 열기 | 일정 탭(인라인 확장) |
| 편집 모드 진입 | **첫 번째** 길게 누르기. 핸들만 나타나고 시간·블록·스크롤은 그대로다(열려 있으면 닫힘) |
| 스크롤 | 편집 모드의 **일반 드래그**는 언제나 스크롤이다 |
| 이동 | 편집 모드에서 선택한 일정을 **다시** 길게 눌러 집어 올린 뒤 드래그(햅틱). 15분 단위, 길이 유지 |
| 시작/끝 조절 | 핸들(●)에서 시작하는 드래그 (최소 15분, 하단은 그날 끝까지). 핸들의 터치 영역은 44pt. 드래그는 터치가 **닿은 지점**에서 시작한다(pan은 손가락이 이미 움직인 뒤에 인식되므로 그 시점의 위치로 hit-test하면 빠른 드래그에서 핸들을 놓친다) |
| 빠른 이동 → 정밀 조정 | 핸들을 압축 구간(일정 가운데)으로 끌고 가면 몇 시간씩 빠르게 움직인다. 거기서 손가락을 **400ms** 멈추면 그 시각 중심으로 확대 영역(±45분, 24pt = 15분)이 옮겨 오고, 작은 움직임으로 15분 단위 조정을 한다. 다시 빠르게 끌면 다시 압축을 쓴다. 확대 영역은 하나만 있어 멈출 때마다 따라온다 |
| 편집 종료 | 일정 밖 탭(탭한 시각이 제자리에 남음) 또는 "완료" |
| 생성 | 빈 곳을 길게 누른 뒤 드래그 → 그 주변이 펼쳐져 15분 단위로 범위를 잡고, 제목·캘린더를 정해 저장 |
| 반복 일정 | 손을 뗀 시점에만 "이 일정만 / 전체 일정"을 묻는다. 날짜가 바뀌는 변경은 "이 일정만"만 가능. `thisAndFuture`는 노출하지 않는다 |

터치는 SwiftUI 제스처가 아니라 스크롤뷰에 붙인 UIKit 인식기(`EditGestureHost`)로 처리한다. 길게 누르기(0.3초)는 스크롤과 구분한다. 편집 모드의 pan은 **핸들에서 시작한 터치만 받고**(그 밖의 터치는 인식기가 아예 받지 않아 스크롤뷰가 기다리지 않는다) 나머지는 첫 이동부터 스크롤된다. 어떤 터치가 무엇을 뜻하는지는 순수 함수 `TimelineGestureRouter`가 정하고(표로 테스트), 좌표 변환(`TimelineAxis`)과 hit testing(`EditHit`)은 서로 독립이다. SwiftUI의 `LongPressGesture.sequenced(before: DragGesture)`나 자식 뷰의 `DragGesture`는 스크롤을 막아서 쓰지 않는다.

실패하면 미리보기를 되돌리고 이유를 알린다: 다른 곳에서 바뀐 일정(`conflict`, 최신 내용으로 새로 고침), 읽기 전용 일정/캘린더, 저장 실패(재시도 가능하면 "다시 시도"가 사용자가 닫을 때까지 남는다), 삭제된 일정, 접근 꺼짐. 충돌 감지는 타임라인을 그릴 때의 `revisionToken`(`EventBlock.revisionToken`)을 기대 revision으로 보낸다. 편집 중인 일정이 다른 곳에서 바뀌면 확대 영역이 따라가고, 사라지면 편집 모드가 조용히 끝난다.

겹치는 일정의 열 배치(`OverlapLayout`)는 읽기 모델의 값을 그대로 쓰며, 좌표로 바뀌는 곳은 `TimelineGeometry.blockFrame` 한 곳이다. 다른 배치로 바꿀 때는 그 함수만 교체한다.

데모 모드 전용 디버그 인자: `-demo-preview expand|edit|move|resize|create`(해당 상태로 멈춤), `-demo-preview script-zoom`(`-demo-long`과 함께: 핸들 드래그를 스스로 재생), `script-return`(첫 일정의 끝 핸들을 늘렸다가 제자리로 놓기), `script-oscillate`(위아래로 반복해 확대하며 유지), `-demo-fail-next-write`(첫 번째 쓰기를 실패시킴), `-demo-long`(오늘 30분·2시간·8시간 일정, 내일 24시간 일정으로 바꿈). 데모에는 읽기 전용 캘린더의 일정, 반복 일정, 한 일정에 연결된 거래 4건(`+N` 확인용)이 들어 있다.

테스트:
- `TimelineAxisTests`: 접기 규칙, 매핑의 단조성과 역변환, 핸들 주변 확대(15분 ≥ 24pt, 병합·분리, 중간 크기 연결, 접힌 가운데 유지), 30분·2시간·8시간·24시간 일정 각각의 확대 폭·한 화면 안 배치·단조성, 접힘 라벨과 시각 라벨의 충돌, 화면용 설정값으로 하루가 한 화면에 가까운지.
- `InlineAllocationPlanTests`: 접힌 블록의 2건 한도와 `+N`, 요약 행/칩, 금액순·시간순 정렬(추정 금액 포함), 합계 문구, 확장 블록의 행 구성·높이·참여자 줄임.
- `TimelineEditorTests`(핸들 드래그 확대 포함): 09:00~17:00 → 09:00~13:00 축소(압축으로 빠르게 → 멈춤 → 정밀), 확대 영역 안 15분 단위, 확대 시 선택 시각·핸들 위치 불변(손가락이 핸들에서 떨어져 있어도), 드래그 재개 시 연속성, 정착 중 값 무시, 영역이 따라 움직임, 취소 시 되돌림, 시작/종료 핸들 모두, 30분·2시간·8시간·24시간, 이동은 확대하지 않음, 멈춤 대기(떨림·재시작·손 뗌 취소). 제자리 확장(열기·닫기·하나만·편집 모드와의 배타·제스처 중 무시·사라진 일정), 편집 모드 수명주기(진입·종료·스크롤 보정 요청·선택 유지·따라가기·생성 포커스), 긴 일정(8시간·24시간·핸들이 없는 다일 일정)에서 가운데가 접힌 채 유지되고 누른 시각이 제자리에 남는지, 확대 구간 안의 15분 단위 이동, 핸들 touch target(44pt·한 화면·가까운 핸들 우선)과 제스처 표(`TimelineGestureRouter`), VoiceOver용 가장자리 조정(`nudge`), 그리고 기존 이동/리사이즈/생성/반복 범위/충돌/읽기 전용/저장 실패(실제 `CalendarCommandService` + in-memory provider).
- `CommandFlowContract`: 같은 편집 흐름을 provider에 독립적으로 검사. in-memory는 `swift test`, EventKit은 `Platform/iOS/EventKitContractHost/run-contract.sh`.

VoiceOver: 일정에 "시간 조정" 동작이 있어 편집 모드로 들어가고, 시작/종료 핸들은 조절 가능한 요소(위/아래로 쓸면 15분)라서 제스처 없이도 같은 명령으로 가장자리를 옮긴다. 일정 이동(본체)의 VoiceOver 동작은 아직 없다.

아직 없는 것: 드래그 중 화면 가장자리 자동 스크롤, 종일 일정의 제스처 편집, 일정 이동의 VoiceOver 동작, 일정 삭제. 편집 모드의 멀리 이동은 접힌 구간에서 거칠다(그 구간은 1pt가 여러 분이다). 놓은 뒤 확대 영역이 새 위치로 따라오므로 거기서 다듬는다.
