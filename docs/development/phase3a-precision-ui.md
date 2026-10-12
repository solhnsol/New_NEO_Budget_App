# Phase 3A — 정밀 편집 말풍선 (UI만)

대상: 고정 그리드 편집 세션에서 시작·종료 핸들을 눌렀을 때 뜨는 ±15분 말풍선(`FixedGridGestures.TapMeaning.handle`이 "Future: the 15-minute time bubble"로 남겨 둔 자리). 이번 단계는 **독립 컴포넌트와 DEBUG 대역**만 만든다. `FixedGridBrowseView`·`PinchZoomScrollView`(Coordinator 포함)·편집 모델 파일(`TimelineEditor`, `TimelineEditPlanner`, `FixedGridGestures`, `FixedGridBrowseModel`, `FixedGridEditBaseline`)은 수정하지 않았다. 앱 진입점(`OnAllApp.swift`)에는 DEBUG 경로 한 줄만 추가했다.

## 1. 구성 (`OnAllApp/Timeline/Precision/`)

| 파일 | 역할 |
|---|---|
| `PrecisionEditBubble.swift` | 제어형 말풍선 본체. 입력 `PrecisionBubbleInput`, 출력 `PrecisionBubbleAction`. 문구 `PrecisionBubbleText`, 크기 `PrecisionBubbleMetrics`. |
| `PrecisionBubbleLayout.swift` | 순수 배치 함수 `place(anchor:edge:size:bounds:clearance:previous:)`. |
| `PrecisionBubbleOverlay.swift` | 핸들 옆에 놓는 오버레이, 화살표, 스크롤·확대 추적기 `PrecisionAnchorTracker`. |
| `PrecisionBubbleFixture.swift` | DEBUG 대역 화면(`-precision-bubble-fixture [scenario]`)과 `#Preview` 5개. |

말풍선은 **계산하지 않는다**: Date 연산, 15분 스냅, Draft 수정, EventKit 쓰기 없음. 눌린 것만 알린다. 막힌 단계(`canDecrement`/`canIncrement == false`)는 버튼이 꺼지고 VoiceOver 조절도 아무것도 보내지 않는다. 닫기는 항상 가능하다.

## 2. 배치 규칙 (`PrecisionBubbleLayout`)

- 시작 핸들(카드 위 가장자리) → **위**, 종료 핸들(아래 가장자리) → **아래**. 일정 본문 대신 경계 바깥 시간을 가린다.
- 위·아래 끝에 닿으면 반대쪽으로 뒤집는다. 둘 다 안 되면(작은 화면 + 큰 글자) 핸들 **옆**, 그것도 안 되면 영역 안에 화살표 없이(`clamped`).
- 가로는 핸들 중심에 맞추고 영역 안으로 민다. 화살표는 둥근 모서리가 허락하는 범위에서 핸들을 가리킨다.
- 핸들 터치 원(반지름 22pt)을 덮지 않는다. 말풍선이 열린 채로 핸들을 끌 수 있다.
- 핸들이 스크롤로 화면 밖에 나가면 그쪽 끝에 고정(`pinnedTop`/`pinnedBottom`)하고, 머리줄의 ⌃/⌄로 방향을 알린다.
- 히스테리시스: 선호 쪽에서 밀려난 뒤에는 선호 쪽에 24pt 여유가 생겨야 돌아간다. 느린 스크롤로 경계를 지날 때 깜빡이지 않고, 큰 이동(시나리오 진입·확대)은 선호 쪽으로 간다.

## 3. 위치 동기화

- 오버레이는 그리드의 스크롤 뷰 위에 **같은 크기로** 얹는다(`.overlay` on `PinchZoomScrollView`). 좌표는 뷰포트 좌표 = 콘텐츠 좌표 − `contentOffset.y`(가로 스크롤 없음).
- `PrecisionAnchorTracker`: 표시 프레임마다 `source()`를 읽어 0.1pt 이상 움직였을 때만 발행한다. 다시 그리는 것은 오버레이뿐이고 그리드는 아니다. `PinchZoomScrollView`를 고치지 않고도 스크롤 감속·핀치·러버밴드를 따라간다.
- 위치는 애니메이션하지 않는다(핸들을 뒤따라오지 않게). 나타남·사라짐만 0.15초 페이드다.
- 단계 이동(±15)은 입력이 바뀌는 같은 업데이트에서 `refresh()`한다. 다음 프레임까지 기다리지 않아 카드와 말풍선이 한 프레임 어긋나지 않는다(시뮬레이터에서 확인: 수정 전 탭 직후 화면은 말풍선이 이전 위치, 수정 후 같은 프레임).
- 확대: 콘텐츠 높이 = 뷰포트 × 줌이고 모든 y가 줌에 비례한다(`TemporalGridPartition.zoomed`). 편집 세션 중에는 분할이 고정되므로 1× 핸들 좌표를 한 번 구해 `contentPoint(atUnitZoom:zoom:)`로 따라가면 계획을 다시 돌리지 않는다.

## 4. 접근성

- **Dynamic Type:** 모든 글자가 텍스트 스타일이다. 너비는 크기별로 232→340pt(영역보다 넓어지지 않음)이고, 접근성 크기에서는 두 버튼을 세로로 쌓는다. 상한은 AX3이다(그 이상은 화면 대부분을 덮어 핸들을 움직일 자리가 없음). 버튼과 닫기는 높이 44pt 이상이다.
- **VoiceOver:**
  - 시각이 하나의 조절 요소다. 라벨 "시작 시각", 값 "10월 13일 화요일 오후 2:15"이고, 위로 쓸면 +15분, 아래로 쓸면 −15분이다(허용된 쪽만).
  - 힌트는 가능한 것만 말한다.
  - 버튼 라벨은 "15분 앞당기기" / "15분 늦추기" / "닫기"이다. 문지르기(escape) 제스처로 닫힌다.
  - 버튼으로 단계를 바꾸면 새 시각이 도착할 때 안내한다. 조절 요소는 자기 값을 스스로 읽으므로 이중 안내는 하지 않는다.
  - 참고: 기존 `TimelineGridView`의 핸들 힌트("위로 쓸면 15분 일찍")는 실제 동작(increment = +15)과 반대다. 이번에 고치지 않았다.
- 버튼을 누르고 있으면 반복된다(`buttonRepeatBehavior`). 반복마다 액션이 하나씩 나간다.

## 5. 검증

- **`OnAllAppTests/PrecisionBubbleTests.swift` (14개):**
  - 선호 쪽, 위·아래 뒤집기(정확한 경계 1pt), 좌우 끝 클램프와 화살표 추적
  - 옆·클램프 대체, 화면 밖 고정, 히스테리시스(왕복 스크롤 시 뒤집힘 2회·떨림 무시·큰 이동 복귀)
  - 화면 전 영역 격자 × 두 크기 × 두 경계에서 영역 안 + 핸들 비침범
  - 문구(시간대, 자정 = 다음 날), 힌트, 제어형(꺼진 단계 무출력), 핸들→경계, Dynamic Type 너비·쌓기
  - 스크롤·핀치 좌표 변환(`PinchZoomMath.offsetAfterZoom`과 맞물림), 추적기 발행 조건
- **시뮬레이터** (전용 기기, `docs/ui-reviews/precision-bubble/`):
  - 시나리오 9개: 가운데·위 끝·아래 끝·왼쪽·오른쪽·화면 밖·AX3·한계·다크
  - 실터치 3개: 플릭 스크롤 직후, ±15 탭 직후 같은 프레임, 핀치 중 8.4× 러버밴드
- **`tools/dev/check.sh full`:** 패키지 415 + 90, 앱 452 통과. Release 빌드 성공.
- **확인하지 못한 것:**
  - VoiceOver 실제 읽기 순서와 안내(실기기 필요)
  - 실기기에서 스크롤 감속 중 말풍선이 한 프레임 늦는지. 표시 링크 순서가 `UIScrollView`의 감속 애니메이션과 정해져 있지 않아, 통합 시 `scrollViewDidScroll`에서 `refresh()`를 부르면 확실해진다.
  - 시뮬레이터의 지속시간 0 합성 탭은 앱 전체의 SwiftUI 컨트롤에서 다음 터치 때 처리된다. 컴포넌트 문제는 아니며, 0.12초 탭은 정상이다.

## 6. 통합 메모 (다음 단계)

- 핸들 탭(`TapMeaning.handle(hit)`) → `PrecisionEdge(hit)`로 말풍선을 연다. 빈 곳 탭·다른 일정 탭·세션 종료 시 닫는다.
- 핸들 드래그 중에는 숨기거나 그대로 두는 것을 소유자가 정한다(`input = nil`이면 숨김). 말풍선은 핸들 터치 원을 덮지 않는다.
- 오버레이는 스크롤 뷰 **밖**(위)에 둔다. 콘텐츠 안에 두면 컨테이너 인식기가 버튼 터치를 받는다.
- `canDecrement`/`canIncrement`는 소유자가 계산한다(반대 경계와 15분 이상 간격, 하루/세션 한도, 저장 중).
