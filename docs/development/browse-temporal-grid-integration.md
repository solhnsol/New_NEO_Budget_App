# Browse ↔ Temporal Grid 통합 설계

기준 `24e7989` (`feat/fixed-temporal-grid-prototype`). 코드·제품 UI는 변경하지 않았고, 이 문서는 읽은 코드와 프로토타입 측정에서 나온 설계 제안이다. 근거가 코드에서 직접 확인된 것은 파일을 적었고, 추론인 것은 "추론"이라고 표시했다.

## 0. 결론

- 프로토타입이 검증한 것(고정 N칸 정각 분할, 연속 줌, 연속 날짜 위치, 앵커, 스와이프 입력)은 **Browse의 "축(axis)이 모양을 바꾼다"는 전제를 정반대로 뒤집는다.** Browse는 축을 접고(fold) 펴서(`expandedLocally`, `expanded(over:)`) 편집·펼침을 해결하는데, 새 모델은 축이 고정이고 확대 배율과 날짜 위치만 바뀐다. 따라서 통합의 핵심 위험은 렌더링이 아니라 **`TimelineEditor`가 축 변형에 의존하는 부분**(편집 확대 구간, 일정 펼침, 축 전환/스크롤 보정)이다.
- 재사용할 수 있는 것이 많다: `EventPresentation`, `DayRenderPlan`(축 추상화만 바꾸면), `AdaptiveLayoutEngine`(`fixedAxis`), 편집 계획기·정책·제스처 표, 거래/오버플로 뷰, 날짜 스트립 뷰.
- 권장 경로: **읽기 전용 Browse를 먼저 새 격자 위에 올리고(플래그 뒤), 그다음 편집을 옮기고, 마지막에 낡은 축 코드를 지운다.** 각 단계에서 기존 테스트가 통과해야 한다(8절).
- 통합 전에 결정해야 하는 가장 큰 것: **(1) 일정 "제자리 펼침"의 대체, (2) 정밀 편집(15분)의 방법, (3) DST 날의 시간 영역, (4) 하루 이동 거리 한도와 데이터 선읽기 범위.** 9절에 권장안이 있다.

## 1. 현재 구조 비교

### 1.1 Browse (제품)

| 영역 | 소유자 | 의존성 (코드 근거) |
|---|---|---|
| 선택된 날, 날 캐시 | `AppModel` (`selectedDay`, `cache`) | `reload()`는 `selectedDay`의 −1…+2일 4일만 읽고 `cache = loaded`로 **통째 교체**한다(`AppModel.swift:213~`). `strip`도 −1…+2일. `moveTo`는 캐시된 날로 즉시 이동하고 `editor.timelinesDidChange`를 부른다. |
| 시간축 | `TimelineEditor` | `TimelineAxis`(Int 분 구간의 조각선형): 한 번에 두 날을 `AdaptiveLayoutEngine`이 만든 `adaptive.axis`(`recomputeAdaptive`)를 쓰고, 편집 중에는 `frozenBrowse`로 고정, 핸들 주변은 `expandedLocally`로 확대, 펼친 일정은 `expanded(over:scale:)`로 확대. 변화는 `AxisTransition`(0.25초, 시계 기반)으로 그리고 끝에 `ScrollCommit`으로 스크롤을 한 번에 이동. |
| 렌더링 | `TimelineGridView` | SwiftUI `ScrollView` + `ScrollViewReader`. `TimelineView(.animation)` → `MorphingContent` → `grid(geometry:)`가 축 전환 중 **매 프레임** 두 날의 `DayRenderPlan`을 다시 만든다(`TimelineGridView.swift:274`, `plan(...)`). 날 열은 `DayColumns`(2열 고정, gutter 60)와 `swipeOffset`으로 배치. |
| 스크롤 | SwiftUI `ScrollView` (UIKit 스크롤 뷰) | `ScrollProbe`가 `UIScrollView`를 찾아 보이는 범위·이동 한도를 에디터에 알린다(`visibleRange`, `scrollLimits`). |
| 핀치 | 없음 | 수동 확대 구간은 있지만 두 손가락 제스처는 없다. |
| 날짜 스와이프 | `EditGestureHost.swipePan`(`UIPanGestureRecognizer`, 가로 우세 1.3) → `TimelineGridView.swipe` | `DaySwipe`: **한 번에 하루만**(`distanceShare` 40%, 플릭 450pt/s), 손가락을 `liveOffset`(±한 열)로 따라가고 놓으면 0.22초 ease-out 후 `onMoveDays`. `swipeEnabled = !isEditing && !isActive && !settling` → **정착 중 입력은 무시**된다. `pendingDays`는 결정이 바뀌는 순간 주 스트립을 바꾼다. |
| 날짜 스트립 | `WeekStripView`(주 스트립), `DayHeader`(제목·화살표), `DayHeaderStrip`(열 위 종일 일정) | 주 스트립은 `selected`·`pendingShift`(결정)로 움직이고, `DayHeaderStrip`은 `strip`과 `swipeOffset`으로 열과 같이 슬라이드. 먼 날로 가기(`goTo`)는 `jumpDays`를 읽어 슬라이드/크로스페이드. |
| 편집 제스처 | `EditGestureHost`(UIKit, 스크롤 뷰에 부착) | 길게 누르기 0.3초(`longPress`), 핸들에서 시작한 touch만 받는 `pan`, 가로 `swipePan`. 스크롤 뷰의 pan이 `pan`에 "required to fail"(핸들 외 touch는 즉시 스크롤). |
| 편집 상태/저장 | `TimelineEditor` | `Mode`(idle/dragging/choosingScope/namingEvent/committing), `TimelineEditPlanner`(미리보기·명령, 15분 스냅은 `TimelineEditPolicy.standard`, `AppModel.swift:153`), `environment.perform` → EventKit, 항상 `reload` 후 `clear()`, 실패 시 롤백·재시도. |

### 1.2 DEBUG Temporal Grid (프로토타입, `Timeline/TemporalGrid/`)

| 영역 | 소유자 | 비고 |
|---|---|---|
| 시간 좌표 | `TemporalGridPartition`(경계 N+1개, 동일 칸 높이, 줌 `totalHeight`) | 분 단위는 `Double`. 칸 경계 보간으로 날짜 사이를 이동. |
| 분할 계획 | `TemporalGridPlanner`(DP)/`Store`(캐시)/`DemandProfile` | 정각 전용(`hourly`)이 기본, 창(D−1…D+2)별. 프레임당 계획 0회. |
| 시간축 표시 | `HourAxis` | 눈금 위치=`timeToY`, 표시 여부=그 순간의 간격. |
| 날짜 공간 | `DayAxisGeometry`, `ContinuousDayAxis`, `AnchorState`, `DayMoveModel` | 위치(Double 일), 스프링 정착, 비행 중 인계, 중앙 시각 앵커. |
| 입력 | `PinchZoomScrollView`(UIKit 스크롤 뷰 + `UIHostingController`), `DateSwipeRecognizer`, `TouchCounter`, `PinchZoomMath` | 두 손가락 중심 앵커, 고무줄, 제스처 중재. |
| 렌더링 | `RenderGridScreen`(DEBUG 전용) | `GridDayEntities`/`GridPlacement`/`GridTextLayout`로 직접 그린다 — **`DayRenderPlan`·`EventBlockView`·거래 뷰를 쓰지 않는다.** 일정 이동·편집·선택·EventKit 없음. |

### 1.3 핵심 차이

1. **좌표 모델**: Browse = Int 분 조각선형 축이 상태에 따라 변형. 새 모델 = 고정 칸 + 줌 + 위치. 날짜 사이 보간도 다르다: `TimelineGeometry(from:to:progress:)`는 **같은 분의 y를 섞고**(`y(minute)` 블렌드), 격자는 **칸 경계(분)를 섞어서 가로줄 y를 고정**한다. 둘은 호환되지 않으므로 보간을 쓰는 곳은 새 매핑을 써야 한다.
2. **소유권**: Browse = 축·스크롤·전환을 `TimelineEditor`가 한 곳에서 쥔다. 새 모델 = 줌·오프셋은 스크롤 호스트, 위치는 `DayMoveModel`, 앵커는 `AnchorState`로 흩어져 있다. 통합하면 에디터에서 이 책임을 빼야 한다.
3. **제스처 소유**: Browse는 `EditGestureHost`가 스크롤 뷰에 길게 누르기·핸들 pan·스와이프를 붙인다. 프로토타입은 컨테이너에 핀치·`DateSwipeRecognizer`를 붙이고 스크롤 뷰는 UIKit 그대로다. 두 곳 모두 "스크롤 뷰 조상 탐색"이라 한 스크롤 호스트 안에서 공존 가능하지만 **스와이프 인식기가 둘이 되면 안 된다.**
4. **입력 철학**: Browse = 하루씩, 정착 중 입력 무시, 결정 시점 햅틱. 프로토타입 = 위치 연속, 정착 중 즉시 인계, 최대 3일. 이는 UX 정책 차이다(9절).

## 2. 재사용 / 교체 / 제거

### 2.1 그대로 재사용

| 컴포넌트 | 이유 |
|---|---|
| `EventPresentation` (E0~E4) | 높이만으로 결정. 이미 `DayRenderPlan`이 쓰고 프로토타입도 같은 값. |
| `DayRenderPlan` (히트 테스트·touchFrame 44pt·충돌 후보·제목 배치·겹침 들여쓰기) | 터치·접근성 계약의 실체. 프로토타입은 이 계약이 없다(touchFrame, `choose`). 단 축 의존만 교체(2.2). |
| `AdaptiveLayoutEngine` + `fixedAxis` | 프로토타입 테스트에서 격자 축(`timelineAxis()`, 정수 정각 경계는 정확)으로 레이아웃이 그대로 만들어짐. 오버플로·링크·touchConflicts의 출처. |
| `EventBlockView`, `TransactionLineViews`(`TransactionLineView`, `OverflowCardView`), `TransactionCardView`, `EventTitleLayer` | 시각 부품은 프레임·프레젠테이션만 받는다(`geometry` 직접 참조 0회 확인). |
| `TimelineEditPlanner`, `TimelineEditPolicy`, `EditHit`, `TimelineGestureRouter`, `EditFeedback` | 계획기는 `geometry.y(minute:)`/`minute(atY:)`만 쓴다(추상화 가능). 제스처 표 테스트는 그대로 유효. |
| `AppModel`의 EventKit·원장 읽기, `CalendarCommandService`, 저장/롤백 | 변경 없음. 날 캐시 범위만 확장(2.2). |
| `WeekStripView`, `DayHeader`, `DayHeaderStrip`, `EventDetailView`, `EventActivitySheet` | 위치/목표 기반 입력으로 구동. 내부 로직 유지. |
| `Haptics`, `Formatting` | |

### 2.2 새 코드로 승격/교체

| 현재 | 대체 | 메모 |
|---|---|---|
| `TimelineGeometry`(축 기반) | **`TimeAxisMapping` 프로토콜**(`y(minute: Double)`, `minute(atY:) -> Double`, `totalHeight`, 거터/열 간격 상수) + `TemporalGeometry`(파티션+줌) | `DayRenderPlan`이 쓰는 표면은 `y` 4곳 + `blockFrame` + `contentWidth/gutterWidth/columnSpacing` 뿐(확인). 먼저 프로토콜을 만들고 기존 `TimelineGeometry`가 따르게 해서 동작 불변을 증명한다. |
| `DayColumns`(2열 고정, 정수 열 인덱스) | `DayAxisGeometry(visibleColumns:)` | 열 수를 한 곳 상수로. |
| `DaySwipe`(하루씩) + `EditGestureHost.swipePan` + `swipeOffset`/`pendingDays` 바인딩 | `DayMoveModel` + `DateSwipeRecognizer` | 스와이프 인식기는 하나만(`EditGestureHost`에서 제거). `swipeOffset`은 `position`에서 파생. |
| SwiftUI `ScrollView`+`ScrollViewReader`+`ScrollProbe` | `PinchZoomScrollView`(프로덕션 승격, 이름은 `TimelineScrollHost`) | `scrollToStart`의 `proxy.scrollTo`는 오프셋 계산(`anchoredOffset`)으로 대체. `EditGestureHost`는 조상 `UIScrollView`를 찾으므로 호스트 안에 그대로 붙는다. |
| `HourRow`/`FoldRow`/`QuarterMarks`/`TimelineGeometry.hourMarks,foldMarks` | `HourAxis` | 접힘 표식 없음. 15분 눈금(`QuarterMarks`)은 확대 상태의 정각 사이 눈금으로 재정의(9절). |
| `TimelineEditor`의 축 책임: `adaptive`/`recomputeAdaptive`, `frozenBrowse`, `zoomWindows`, `expandedLocally`, `AxisTransition`, `ScrollCommit`, `scrollLimits`, `visibleRange` | **`PartitionPlan`(창별 분할·`fixedAxis` 레이아웃 캐시) + 줌 전환(`ZoomTransition`)** | 가장 큰 교체. 에디터는 "현재 지오메트리/줌을 제공받는" 쪽으로 의존을 뒤집는다. |
| 편집 확대 구간(dwell zoom) | **줌 애니메이션**(핸들을 앵커로 확대) | `PinchZoomMath`의 앵커 비율 재사용. |
| 일정 펼침(`expandedKey`, `expanded(over:)`, `ExpandedBlockView`) | 정책 결정 필요(9.1). 기본안: 시트/하단 카드 | |
| `TimelineGridView`의 `MorphingContent`+`TimelineView(.animation)` | 위치·줌 기반 직접 렌더 | |

### 2.3 제거 (대체물이 동작 동등을 증명한 뒤)

- `TimelineAxis`의 `browse`, `expandedLocally`, `expanded(over:)`, `handleZones`, 접힘(fold) 모델과 `TimelineAxisTests`의 접힘·확대 테스트.
- `AxisStabilizer`, `AxisStability`(비교 도구), `StabilizedLayout`, `AxisDemandCache`, `AxisStabilityTests`, `AdaptiveCacheTests`의 해당 부분. 단 4일 스무딩의 아이디어는 격자 계획기(창 D−1…D+2 가중)가 이미 대체. **프로토타입 단계의 약속("유망함이 확인되기 전까지 기존 4일 스무딩을 제거하지 않는다")은 Phase 3 완료 기준에서 확인 후 해제.**
- `TimelineGridView.TransactionCards`(`TimelineGridView.swift:816`): 호출처가 없다(grep 확인, 죽은 코드). 지금 제거해도 되는 사전 정리 후보.
- `DayTimelineScreen`의 `goTo` 애니메이션 상태(`swipeOffset`/`pendingDays`/`jumpDays`/`isChangingDay`)는 `position`/`move` 기반으로 단순화.
- `EditGestureHost`의 `swipe` 경로와 `swipeEnabled`.
- `RenderGridScreen`은 DEBUG 벤치로 유지(성능 회귀 감시용), 통합 후에도 삭제하지 않는다.

## 3. 상태·제스처 소유권 설계

### 3.1 상태 소유권

| 상태 | 소유자 | 변경 가능한 자 | 파생/읽는 자 |
|---|---|---|---|
| 일정·거래 데이터, 날 캐시 | `AppModel` | `reload`, `moveTo`, 선읽기 | 모든 뷰 |
| **커밋된 날**(`selectedDay`) | `AppModel` | `BrowseViewState`가 이동이 **정지**할 때 `moveTo(target)` | 제목, `WeekStripView.selected`, 요약줄, 에디터 |
| **위치(position)**, 단계, 목표, 속도 | `BrowseViewState.move: DayMoveModel` | 스와이프 제스처, 스트립 탭(`retarget`), 버튼 | 열 x 위치, 공유 분할 보간, `DayHeaderStrip` 오프셋, `WeekStripView.pendingShift`(= 목표 − 커밋된 날), 햅틱(목표가 바뀔 때) |
| 줌 배율, 스크롤 오프셋 | 스크롤 호스트(`TimelineScrollHost`)의 `zoom`·`UIScrollView` | 핀치, 스크롤, 편집 줌 전환, 앵커 | 지오메트리(`TemporalGeometry`), 눈금 |
| 앵커 시각 | `BrowseViewState.anchor: AnchorState` | 날짜 이동 스텝, 사용자 스크롤/핀치(재설정) | 호스트의 오프셋 적용 |
| 창별 분할 | `TemporalGridStore`(한도 있는 캐시) + 화면의 창 메모 | 날/콘텐츠/설정/뷰포트 변화 때만 | 지오메트리, 엔진 레이아웃 |
| 창별 `AdaptiveLayout`(`fixedAxis`) | `PartitionPlan`(창+역할별 캐시) | 위와 같음 | `DayRenderPlan` |
| 선택/편집/펼침/미리보기 | `TimelineEditor` | 편집 제스처, 저장 흐름 | 핸들·미리보기·배지 |

규칙:
1. **위치는 `DayMoveModel` 하나**가 쥔다. 열 x, 분할 보간, 종일 헤더, 눈금은 모두 `position`의 함수(프로토타입에서 검증).
2. **커밋은 정지 시점**에만: `phase == .resting`이 되는 프레임에 `AppModel.moveTo(round(position))`. 이동 중 헤더/주 스트립은 `target`을 따른다(현재 `pendingDays`와 동일한 의미).
3. `AppModel.reload`가 캐시를 `−1…+2`로 교체하는 것은 이동 중 보이는 날을 지울 수 있다. **`[position−r, position+r+2]`를 유지하는 병합형으로 바꾼다**(r은 선읽기 반경, 9.7).
4. `TimelineEditor.timelinesDidChange`는 "날이 바뀌었을 때 축 전환"을 하지 않는다(축이 고정이므로). 대신 새 창이 확정되면 `PartitionPlan`이 준비되었음을 알린다.
5. 정지가 아닌 동안(드래그/정착) 편집은 시작되지 않는다(Browse의 `swipeEnabled` 부정과 같은 방향: 편집 ⇒ 날 이동 불가, 날 이동 중 ⇒ 편집 진입 불가). 단 **손가락이 닿는 순간 정착이 멈추는**(인계) 동작은 유지한다.

### 3.2 제스처 소유권

| 제스처 | 인식기 / 위치 | 소유자 | 활성 조건 | 충돌 해결 |
|---|---|---|---|---|
| 세로 스크롤 | `UIScrollView.panGestureRecognizer` | `TimelineScrollHost` | 핀치·날짜 스와이프·편집 드래그 중에는 끔 | 날짜 스와이프(4pt)가 UIKit pan(약 10pt)보다 먼저 가로를 가져가고, 세로는 실패해서 스크롤로 넘어감(`HorizontalDragClassifier`). |
| 핀치 | `UIPinchGestureRecognizer`(호스트) | 호스트 → 줌 모델 | 편집 **드래그 중 아님**. 편집 모드 idle에서는 허용(권장, 9.2) | 시작 시 스크롤·날짜 스와이프·길게 누르기 취소. 종료 후 모든 손가락이 떨어질 때까지 스크롤/스와이프 비활성(`TouchCounter`). |
| 날짜 스와이프 | `DateSwipeRecognizer`(호스트) — **유일** | `BrowseViewState.move` | `!editor.isEditing && !editor.isActive`, 핀치 아님 | 두 번째 손가락이 닿으면 취소→핀치. 정착 중 손가락이 닿으면 멈춤(`touchDown`), 스와이프가 아니면 `touchUp`에서 원래 목표로 계속. |
| 길게 누르기(0.3초) | `EditGestureHost.longPress`(스크롤 뷰) | `TimelineEditor` | 이동 정지 상태(`!move.isMoving`)에서만 의미 | 0.3초 안에 10pt 이상 움직이면 실패 → 스크롤/스와이프. 길게 누르기가 인식되면 `swipe`는 이미 불가(편집). |
| 핸들 pan | `EditGestureHost.pan` | `TimelineEditor` | 편집 모드, 핸들에서 시작한 touch만 | 스크롤 pan이 이 pan에 대해 "required to fail"(기존 유지). |
| 탭 | SwiftUI 단일 탭 핸들러(`handleTap`) | 화면 | 이동·정착 중에는 무시(손가락이 닿으면 먼저 인계됨) | 히트 테스트는 **정지 위치의 계획**으로(아래). |

히트 테스트: 지금은 `editor.geometry`와 고정 2열 `DayColumns`로 `DayRenderPlan.hit(at:)`을 부른다. 새 구조에서는 `position`이 정수일 때만(정지) 같은 방식으로 동작하고, 이동 중에는 입력을 받지 않는다(탭/길게 누르기 무시). 이렇게 하면 "움직이는 일정"을 누르는 모호성을 만들지 않는다.

## 4. 편집·EventKit과의 충돌

| 영역 | Browse 현재 | 격자와의 충돌 | 설계 |
|---|---|---|---|
| 일정 선택/펼침 | 탭 → 제자리 펼침(`expandedKey`, 축 확대 `expanded(over:)`) | **높이 고정이라 펼칠 수 없다.** 펼침 테스트 ≈10개(`tappingAnEventOpensItInPlace…` 등)와 `QuarterMarks`가 이 전제. | 9.1 정책 결정. 기본안 = 상세 시트(`EventDetailView`/`ExpandedBlockView` 내용). `expandedKey` 개념은 에디터에서 제거. |
| 길게 누르기 → 편집 모드 | 선택만, **화면이 움직이지 않는다**(테스트로 보장) | 축이 고정이므로 "움직이지 않음"은 자동으로 성립. 단 편집 진입 때 축 전환이 없으니 `setAnchors`/`AxisTransition` 불필요. | 편집 진입은 선택 상태 + 핸들 표시 + **분할 동결**(편집 중 `PartitionPlan` 재계획 금지, 현 `frozenBrowse`와 동일 의미). |
| 핸들 드래그·이동 | `geometry.minute(atY:)`로 Int 분, 이후 `policy`가 15분 스냅 | 1×에서 1pt가 최대 약 9분(8시간 칸, N=12 기준 53pt/480분)까지 거칠다 → 15분 스냅이 점프. 현재는 **휴지 후 구간 확대(dwell zoom)**로 해결. | dwell zoom을 **줌 애니메이션**으로 대체: 핸들 휴지 400ms → 해당 분이 `editScale`(0.8pt/분)에 도달하는 줌(상한 8×)으로 핸들을 앵커로 확대. 8×로도 모자라는 극단(N=16, 8시간 칸: 0.67pt/분)은 15분 = 10pt로 허용(9.2). |
| 15분 스냅 | `TimelineEditPolicy.standard` | 변경 없음. 계획기는 `Double` 분을 받아 반올림. | 프로토콜 지오메트리 `minute(atY:)`를 `Double`로 받고 `Int`로 반올림해 `policy`에 전달. |
| 새 일정 만들기(빈 시간 길게 누르기) | `focusForCreate`가 해당 분 주변을 확대 | 같은 문제 | 줌 애니메이션으로 대체. |
| 미리보기 프레임 | `previewFrame(totalWidth:geometry:)` | 지오메트리 프로토콜로 | 줌·위치가 편집 중 바뀌면(휴지 줌) 미리보기 y도 같은 매핑으로. |
| EventKit 저장 | `perform` → `reload` → `clear()`; 실패/오래된 revision/읽기 전용/반복 범위 질문은 모두 에디터 `Mode`가 처리 | **영향 없음.** 편집 모델과 명령은 지오메트리와 무관. | 변경 금지: `startCommit`/`run`/`rollback`/`chooseScope`/`confirmCreate`/`nudge`. |
| 저장 후 재계획 | `run`이 `before = currentAxis`를 잡아 새 축에서도 편집한 가장자리를 화면에 고정 | 일정 시간이 바뀌면 그 날의 수요가 바뀌어 **분할이 다시 계획**된다 → 저장 직후 격자가 튈 수 있다. | 새 분할로 **`interpolated(old,new)` 전환**(시계 기반 progress, 현 `AxisTransition`과 같은 역할)하며 `AnchorState`로 편집한 가장자리 시각을 고정. 이 경로는 프로토타입에 없다(확인되지 않음, Phase 2의 핵심 검증). |
| 롤백 | 미리보기 제거 + 선택 유지/해제 | 영향 없음. 단 롤백 중에도 분할은 동결이므로 튀지 않는다. | |
| VoiceOver 핸들 조정 | `EditHandle.accessibilityAdjustableAction` → `editor.nudge` | 유지. 핸들의 접근성 프레임은 `DayRenderPlan` 프레임이라 지오메트리 교체만 하면 됨. | |

## 5. 거래 표시 · Activity 연결 · 터치 영역

- 프로토타입 렌더러(`GridTextLayout`의 클러스터 배지 "N", 단순 금액 텍스트)는 **Browse 계약보다 적다**: `touchFrame ≥ 44pt`, `TouchConflict`/`choose` 후보 선택, Activity 링크 라벨(`linkedEventTitle`), 카테고리 아이콘, `OverflowSelection` 목록 시트, 접근성 레이블이 없다. **그래서 렌더링은 프로토타입이 아니라 `DayRenderPlan`을 쓴다.**
- 거래 처리 대응:
  - 독립 거래의 글자 표시는 현재 규칙(방 있으면 reveal) 그대로 — 프로토타입의 `reveal`과 같은 아이디어이고 `DayRenderPlan`이 `reveal`을 이미 계산.
  - 밀집으로 겹치는 점은 현재 `TransactionOverflow`(오버플로 카드)가 흡수. **시각만 건수 배지 스타일로 바꾸고**(`OverflowCardView`), 탭 → `OverflowSelection` 시트(ID·시각·금액·링크, 아무것도 합치지 않음)는 유지. 같은 분 거래도 엔진이 오버플로로 보낸다.
  - 일정 내부 거래 행(`insideRows`), 링크 거래의 일정 라벨은 `EventBlockView`가 이미 처리.
- Activity 연결·금액·ID: 모두 `DayTimeline`/`AllocationItem`에서 오고 렌더링 방식과 무관. 격자 통합이 이 데이터 경로를 건드리지 않는다.
- 터치 영역: `DayRenderPlan`이 `touchFrame`(≥44pt)과 충돌 집합을 계산하고 프레임은 지오메트리에서 나온다. **줌이 바뀌면 프레임이 바뀌므로** 정지 상태(줌 고정)에서만 히트 테스트한다. 1×에서 1시간 미만 일정은 높이 ≈ 13~20pt지만 `touchFrame`이 44pt로 확장되고, 겹치면 `choose`로 사용자가 고르게 되는 현행 계약이 유지된다.
- 짧은 일정의 제목은 정각 정책에서 줄어든다(프로토타입 측정: 주날짜 제목 수 60.0 → N=12 정각 40.0). **존재·선택 가능성(P0)은 유지되지만 읽기는 손해**이므로 9.9에서 보완책을 결정한다.

## 6. 테스트·회귀 위험

| 테스트 파일 (줄) | 성격 | 통합 영향 | 처리 |
|---|---|---|---|
| `TimelineEditorTests` (1250) | 에디터 상태기계, 저장·롤백, **축 전환/dwell zoom/anchors** 혼재 | 저장·롤백·스코프·nudge·제스처 표 ≈ 절반은 지오메트리 무관(유지). 축 확대/전환/펼침 ≈ 절반(위 목록의 `…EnlargedRegion…`, `…ZoomsTheSameWay`, `…Transition…`, `…Settling…`, `…OpenInPlace…`)은 모델이 바뀐다. | **파일을 둘로 분리**(지오메트리 무관 / 축 모델 의존)한 뒤 후자를 줌 전환 모델로 다시 쓴다. 분리 자체가 Phase 0의 작업이고 이때는 전부 통과해야 한다. |
| `DayRenderPlanTests` (428) | 계획 = 지오메트리 위의 위치·프레젠테이션·히트 | 프로토콜 도입으로 불변이어야 한다 | Phase 0에서 그대로 통과. 이후 격자 지오메트리로 같은 테스트를 파라미터화. |
| `EventPresentationTests` (245), `InlineAllocationPlanTests`, `DayContentLayoutTests` | 순수 | 영향 없음 | 유지 |
| `AdaptiveLayoutEngineTests` (548), `AxisStabilityTests`(`fixedAxis` 불변식 포함) | 엔진·`fixedAxis` | `fixedAxis` 경로는 계속 사용. 안정화 비교 부분만 제거 후보. | `fixedAxis` 테스트 유지, 안정화 비교 삭제(Phase 4) |
| `TimelineAxisTests` (352) | 접힘/확대 축 모델 | 모델 제거 시 삭제. 매핑(y↔minute) 불변식은 `TimeAxisMapping` 테스트로 이전 | Phase 4 |
| `TwoDayTimelineTests` (257) | 두 날 열·스와이프 | `DayColumns`/`DaySwipe` 의존 부분 교체 | Phase 1에서 `DayAxisGeometry`/`DayMoveModel` 테스트(이미 있음)로 이전 |
| `TimelineGeometryTests` (61), `AdaptiveCacheTests` | | 지오메트리 테스트는 프로토콜 도입 시 확장 | |
| 프로토타입 테스트(`TemporalGrid*`, `HourAxis`, `PinchZoomMath`, `ContinuousGrid`, `DateSwipe`) | 새 모델 | 통합 후에도 순수 로직 테스트로 유지 | 유지 |

회귀 위험 요약(우선순위 순):
1. **R1 편집 모델 재작성** — 가장 큰 변경, 테스트로 둘러싸인 부분. 분리 후 재작성, 저장·롤백 테스트는 **수정 없이** 통과해야 한다.
2. **R2 DST/타임존** — `DayTimeline.totalMinutes`는 1380/1500일 수 있다(`DayTimeline.swift:217`). 프로토타입은 1440 고정. 9.3.
3. **R3 접근성(VoiceOver/Dynamic Type)** — 호스팅 컨트롤러가 `UIScrollView` 안에 들어가면 접근성 요소 트리와 스크롤 동작이 달라질 수 있다(추론). `EditHandle`의 조정 가능 요소와 일정 `accessibilityAction`을 실기기 VoiceOver로 확인해야 한다.
4. **R4 `UIHostingController` 수명** — `rootView`를 갱신마다 교체한다(프로토타입 방식). SwiftUI `@State`를 포함한 뷰 트리가 리셋되지 않는지 확인 필요(추론; 프로토타입 화면에서는 문제 미관찰).
5. **R5 `AppModel` 캐시 변경** — `reload`의 병합형 변경이 편집 중 `timelinesDidChange` 흐름과 맞물린다.
6. **R6 먼 날 이동** — `goTo`의 `jumpDays`/크로스페이드를 `DayMoveModel`과 병행해야 한다(9.7).

## 7. 프레임별 재계산 · SwiftUI 병목

측정/관찰 근거:

- **`DayRenderPlan.init`은 축 전환 중 프레임마다, 날마다 호출된다**(`TimelineGridView.dayContent` → `plan(...)`). 24일정·30거래의 한 날, Debug 빌드 **0.88ms/프레임**(프로토타입 `printWhatTheExistingRendererRecomputesOnEveryFrameOfADateMove`). 3열이 보이면 약 2.6ms로, 120Hz 프레임 예산(8.3ms)의 약 3분의 1이다(Debug 값이고 실기기·Release는 다를 수 있음). 같은 날의 프로토타입 정적/동적 분리(`GridDayEntities` 1회 + `GridPlacement` 프레임당)는 **0.05ms/프레임**.
- 그 원인: `DayRenderPlan.init`이 `EventOverlapAnalysis`(2회), `DayContentLayout`, 제목 배치, 히트·충돌 구성을 **프레임마다 반복**한다(코드: `DayRenderPlan.swift:107~340`의 `init`).
- 프로토타입의 프레임 비용(Debug): 모델 계산(열 3개 + 눈금 + 분할 보간) 0.2~0.5ms, 스와이프/정착 한 프레임(모델+앵커) 0.06ms. 시뮬레이터 60Hz에서 핀치·스와이프 프레임 간격 중앙값 16.7ms, 지연 프레임 0~3/24~82. **실기기 120Hz는 측정하지 않았다.**
- 분할 계획: 최적화 빌드 기준 탐색 1.7ms + 프로필 0.2ms(창 하나), Debug는 약 50ms. 날/설정/뷰포트가 바뀔 때만 실행.
- SwiftUI 병목 후보:
  1. 8×에서 콘텐츠 높이가 뷰포트의 8배(예: 5000pt). 프로토타입은 ±1 뷰포트 밖 일정·거래를 뷰로 만들지 않고 반 뷰포트 밴드가 바뀔 때만 재구성했다. Browse의 `grid`는 지금 모든 일정을 한 `ZStack`에 만든다 → 같은 컬링이 필요.
  2. 핀치 프레임마다 SwiftUI 트리를 다시 만드는 구조(프로토타입). 시뮬레이터에서는 충분했지만 실기기에서 부족하면 핀치 중에는 컨텐츠에 변환(scale)만 적용하고 종료 시 재구성하는 방식이 대안이다(추론, 미검증).
  3. `TimelineView(.animation)` 기반 `MorphingContent`는 제거 대상(축 전환이 없다). 대신 날짜 정착은 모델 스텝(디스플레이 링크 근사: 프로토타입은 8ms 슬립 루프 → 통합 시 `CADisplayLink`로 교체 권장).
  4. 에디터의 `adaptiveRuns` 카운터는 스크롤이 엔진을 부르지 않는다는 테스트의 근거. **격자 통합에서도 "핀치/스크롤/스와이프 프레임에서 엔진·분할 계획 0회"를 같은 방식의 카운터 테스트로 지킨다.**

## 8. 단계별 통합 계획

각 단계는 플래그 뒤에서 진행하고, 이전 단계 완료 기준을 만족해야 시작한다. 모든 단계의 공통 기준: `tools/dev/check.sh full` 통과, 기존 테스트 삭제·약화 없이(제거 대상은 해당 단계에서 명시), 스크린샷/녹화로 DEBUG 격자와 시각 비교.

### Phase 0 — 준비 (동작 불변)

> **진행 상태**: 항목 1(축 추상화), DST 정책(5), 날 캐시 개선, 소유권 경계 정리는 구현됨 — `phase0-foundations.md`. 항목 2(`DayRenderPlan` 정적/동적 분리), 3(`TimelineEditorTests` 분리), 4(죽은 코드 제거)는 아직 남아 있다.

작업:
1. `TimeAxisMapping` 프로토콜 도입, `TimelineGeometry`가 따르게 하고 `DayRenderPlan`/`TimelineEditPlanner`/`EditHit` 사용처를 프로토콜로 바꾼다. (`minute(atY:)`는 `Double`을 돌려주되 기존 구현은 Int→Double.)
2. `DayRenderPlan`을 정적(겹침 분석, 표시 데이터, 제목 폭, 링크 라벨)과 동적(프레임, 프레젠테이션, 히트) 부분으로 분리하고 정적 부분을 날·텍스트 크기·콘텐츠 키로 캐시.
3. `TimelineEditorTests`를 지오메트리 무관/축 모델 의존으로 나눈다(파일 분리만).
4. 죽은 코드(`TransactionCards`) 제거.
5. DST 스파이크: 23/25시간 날에서 시간 영역 결정(9.3) 프로토타입.

완료 기준: 앱 동작·스크린샷 불변(`-demo`, `-demo-trans`), 모든 기존 테스트 통과, 프레임당 `DayRenderPlan` 비용 ≤ 현재의 50%(정적 캐시 적중 시) 측정 기록, 새 정적 캐시 테스트(내용 변경 시 무효화).

### Phase 1 — 읽기 전용 격자 Browse (플래그 `-browse-temporal`)

> **진행 상태**: 1A(`phase1a-rendering-foundations.md`)와 1B(기존 Browse 렌더러를 고정 격자에 연결한 읽기 전용 내부 경로, `docs/ui-reviews/browse-fixed-grid/README.md`)가 구현됨. 핀치·연속 날짜 스와이프·편집은 아직 없다.

작업: `TemporalBrowseGrid`(`TimelineScrollHost` + `HourAxis` + `DayRenderPlan` on `TemporalGeometry`)로 `TimelineGridView`의 읽기 경로를 대체. `BrowseViewState`(`DayMoveModel`, `AnchorState`, 줌 모델). `AppModel` 캐시 병합형, 선읽기 반경. 주 스트립/헤더/종일 헤더를 `position`/`target`으로 구동. 창별 분할·`fixedAxis` 레이아웃 캐시. 편집 UI는 비활성(플래그 모드에서 길게 누르기 무시). 탭은 상세 시트(일정), 거래 선택·오버플로 시트 유지.

완료 기준:
- 일정·종일·거래·오버플로·링크 거래의 모든 탭 경로가 기존과 같은 시트를 연다(UI 스모크 + 단위 테스트).
- 핀치/스크롤/스와이프 프레임에서 분할 계획·엔진 실행 0회(카운터 테스트).
- 일정·거래 ID 보존, 위치 연속성, 날짜·시간축·콘텐츠가 같은 `position`(프로토타입 테스트 이식).
- 10개 이상 fixture + `-demo-trans`에서 기존 Browse 대비 스크린샷 비교(제목 수·E0 수 표 포함), 열화 사례를 문서화.
- 실기기에서 핀치·스와이프 프레임 시간 측정(목표: 99% 프레임이 8.3ms 이하 또는 합의한 예산) — 못 맞추면 핀치 변환 방식(7절 2번)을 먼저 도입.
- VoiceOver로 일정·거래·핸들 읽기 확인(편집은 아직 없음).

### Phase 2 — 편집

작업: `TimelineEditor`에서 축 책임 제거(`TimeAxisMapping`/줌 전환 주입), 분할 동결(`frozenBrowse` 대응), dwell zoom → 줌 애니메이션, 저장 후 재계획 전환(`interpolated(old,new)` + 앵커), 미리보기/배지/핸들을 지오메트리 프로토콜로, `EditGestureHost`에서 스와이프 제거, 편집 중 핀치 정책.

완료 기준:
- 지오메트리 무관 에디터 테스트는 **수정 없이** 통과(저장·롤백·스코프·nudge·정책·제스처 표).
- 축 모델 의존 테스트는 줌 전환 모델로 재작성되어, 같은 사용자 시나리오(핸들 휴지 → 15분 단위로 정밀 이동 → 놓기 → 선택 유지 → 롤백/재시도)를 검증한다.
- "길게 눌러 편집에 들어가도 화면이 움직이지 않는다" 불변식 유지.
- 편집한 가장자리가 저장 후 재계획 전환 동안 화면에서 움직이지 않음(앵커 오차 < 1pt 테스트).
- 1×에서 15분 일정의 핸들 터치 영역 ≥ 44pt, 줌 8×에서 15분 스냅 간격 ≥ 10pt(측정/테스트).
- EventKit 실패·오래된 revision·읽기 전용·반복 일정 범위 시나리오 수동 확인(기기).

### Phase 3 — 펼침·정리·기본값 전환

작업: 일정 펼침 대체(9.1) 마무리, `QuarterMarks` 재정의, 플래그를 기본값으로(롤백 스위치 1릴리스 유지), 접근성·Dynamic Type 점검, DST 날 검증.

완료 기준: 신 경로가 기본이고 구 경로는 플래그 뒤에 남음, Dynamic Type 최대·VoiceOver·DST 시나리오 통과, 사용자 합의된 UX 정책(9절) 문서 반영, 성능 기준 만족.

### Phase 4 — 제거

작업: 2.3의 제거 목록 실행, 죽은 테스트 삭제, 4일 스무딩(구) 제거 확인.

완료 기준: 구 경로 참조 0, `check.sh full` 통과, 제거된 코드 대응 기능이 새 테스트로 커버됨.

## 9. 미결정 UX 정책과 권장안

| # | 정책 | 선택지 | 권장 |
|---|---|---|---|
| 9.1 | **일정 제자리 펼침**을 어떻게 대체하나 | (a) 상세 시트 (b) 일정에 맞춰 줌(탭 → 그 일정이 보이는 줌으로 애니메이션) (c) 펼침 유지(축 변형) | **(a)로 출시, (b)는 이후 실험.** (c)는 고정 높이 모델을 깬다. |
| 9.2 | **15분 정밀 편집** 방법 | (a) 핸들 휴지 → 앵커 줌(상한 8×) (b) 편집 진입 시 자동 확대 (c) 별도 정밀 모드 | **(a)**. 현행 "첫 길게 누르기는 아무것도 움직이지 않는다"를 유지. 8×에서도 0.8pt/분에 못 미치는 극단(N=16·8시간 칸)은 15분 = 10pt로 허용하고 필요 시 N=12 고정. |
| 9.3 | **DST 날**(1380/1500분)의 시간 영역 | (a) 벽시계 분(0~1440) 기준 축 (b) 경과 분 기준에서 칸 수를 유지한 채 영역 길이만 변화 | **(a)**: 시간 라벨은 이미 `wallHour`를 쓴다(`HourRow`). 25시간 날의 반복되는 1시간에 걸친 일정은 같은 y에 겹치므로 소수 사례로 수용, 스파이크(Phase 0)에서 확정. |
| 9.4 | 기본 칸 수 N | 10 / 12 / 16 | **12**(프로토타입 기본). 실제 데이터 일주일로 재검증 후 확정. |
| 9.5 | 시작 줌·스크롤 | 1× 전체 / 오늘이면 지금 근처 확대 | **1×로 시작**(전체가 보임). 현재 Browse의 "오늘이면 지금 근처로 스크롤"(`scrollToStart`, 컨텐츠 > 760pt일 때)은 2× 이상 자동 확대가 될 수 있으니 초기 릴리스에서 제외. |
| 9.6 | 거래 밀집 표시 | 오버플로 카드 유지 / 건수 배지 | **오버플로 카드의 시각만 건수 배지로**, 시트·ID 보존 유지. |
| 9.7 | 한 번의 스와이프 이동 거리와 선읽기 | 하루(현행) / 최대 3일 | **초기 `maximumHop = 1`**(현행 "하루씩" 유지), 정착 스프링·즉시 인계는 적용. 선읽기 반경 r = 1일(= 현행 −1…+2에 맞춤), hop 확대 시 r을 같이 늘린다. 먼 날 이동(주 스트립 탭)은 기존 크로스페이드 유지. |
| 9.8 | 편집 모드에서의 핀치 | 허용 / 금지 | **idle에서 허용, 드래그 중 금지.** 날 이동은 편집 중 금지(현행). |
| 9.9 | 1시간 미만 일정의 제목(정각 정책의 손실) | 감수 / 30분 칸 예외 / 탭·확대 | **감수 + 확대/탭으로 접근**(P0 보존). 30분 칸은 실제 데이터에서 손실이 문제로 확인될 때만 재검토(프로토타입 실험: 30분 칸 허용은 정각 전용 대비 제목 40 → 58). |
| 9.10 | 앵커 정책(날 이동 중 확대 상태) | 중앙 시각 / 상단 / 오프셋 pt 유지 | **중앙 시각**(프로토타입 검증). 스크롤·핀치가 이동을 끊으면 사용자가 본 곳에서 재설정. |
| 9.11 | 날 열 수 | 2 / 1 / 3 | **2 유지.** 구조는 `visibleColumns`로 일반화(분할 계획의 창 읽기 정책은 3열 이상에서 따로 결정). |
| 9.12 | 이동 중 탭/길게 누르기 | 무시 / 인계 후 처리 | **손가락이 닿으면 정착을 멈추고(인계), 스와이프가 아니면 계속.** 탭 동작은 정지 후만. |
| 9.13 | 햅틱 | 결정 시점(`pendingDays`)에 `snap` | 목표가 바뀔 때 `snap`(현행과 동일 의미). |
| 9.14 | 눈금 라벨 폰트(Dynamic Type) | ×1.4 상한 / 열 폭 확장 | **×1.4 상한**, 접근성 큰 글자용 정책은 별도 결정. |

## 10. 확인되지 않은 것과 가정

- 실기기 120Hz 성능, 실기기 VoiceOver, DST 날의 실제 동작은 확인하지 않았다.
- 저장 후 재계획 전환(4절)은 설계만 있고 프로토타입에 구현·측정이 없다.
- `UIHostingController`를 `UIScrollView` 안에 두는 구조에서 접근성과 `@State` 수명은 추론이다(프로토타입 DEBUG 화면에서는 문제를 관찰하지 못했음).
- 측정치는 합성 fixture와 Debug 빌드/시뮬레이터(60Hz) 기준이며 위 수치를 출시 기준으로 쓰지 않는다. Phase 1에서 실기기 기준을 세운다.
- 프로토타입 결과와 근거 문서: `docs/temporal-grid-prototype.md`, `docs/ui-reviews/{hourly-grid,pinch-zoom,time-axis,continuous-grid,continuous-swipe}/`.
