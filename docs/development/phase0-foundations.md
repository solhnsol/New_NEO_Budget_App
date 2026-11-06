# Phase 0 결과: 공통 기반 (축 추상화, DST 정책, 날 캐시, 소유권)

기준 `f638620`. `browse-temporal-grid-integration.md`의 Phase 0 구현 결과. **Browse의 UI·제스처·편집·EventKit 저장/롤백·반복 일정 로직은 바뀌지 않았고**, DEBUG Temporal Grid(분할·핀치·스와이프)도 그대로다. 새 날짜 이동 상태 머신은 추가하지 않았다.

## 1. 축 추상화 `TimeAxisMapping`

- `Timeline/TimeAxisMapping.swift`: 하루의 세로 축이 하는 일만 모은 프로토콜 — `y(minute:)`, `minute(atY:)`, `y(exactMinute:)`, `exactMinute(atY:)`(소수 분), `totalMinutes`, `contentHeight`, 열 상수(`gutterWidth`, `trailingPadding`, `columnSpacing`, `minimumBlockHeight`). `contentWidth(totalWidth:)`와 `blockFrame(...)`은 프로토콜 확장으로 옮겨 두 축이 같은 구현을 쓴다(기존 `TimelineGeometry`의 본문을 그대로 이동, 값 불변).
- `TimelineGeometry`(기존, 접히는 조각선형 축·전환 블렌드 포함)는 프로토콜을 따른다. 동작 변경 없음.
- `TemporalGrid/TemporalAxisMapping.swift`: 새 격자(`TemporalGridPartition`의 현재 줌·보간 상태) 구현. 소수 분이 정확하다.
- 의존 방향을 바꾼 곳: `DayRenderPlan.init(geometry:)`와 `TimelineEditPlanner`(저장하는 `geometry`, `previewFrame(geometry:)`)가 `any TimeAxisMapping`을 받는다. 호출하는 쪽(`TimelineEditor`, `TimelineGridView`, 테스트)은 그대로 `TimelineGeometry`를 넘기므로 소스 변경 없이 컴파일된다.
- 결정:
  - 분 단위는 이 프로토콜에서 **호출자가 정한 축의 분**이다. 기존 축은 하루 시작 이후 **경과 분**, 격자는 **벽시계 분**(2절). 두 축을 한 화면에 섞지 않는다.
  - `TimelineGeometry`의 보간(같은 분의 y를 섞음)과 격자의 보간(칸 경계를 섞어 가로줄 y 고정)은 서로 다른 의미이므로 프로토콜은 보간 방식을 규정하지 않는다. 각 구현이 자기 방식의 `y`/`minute`만 제공한다.
  - `TimelineGeometry.contentHeight`는 축 전환 중 줄어들지 않는다(기존 의미 유지) — 프로토콜은 "콘텐츠 높이"로만 정의한다.
- 검증(`TimeAxisMappingTests`): 6개 축(선형, 접힌 축, 전환 중 축, 격자, 격자 3×, 격자 보간) 모두 `y(0)=0`, 끝 = 높이(전환 중 축만 `≥`), 단조 증가; 정수 분의 `y`↔`minute` 역변환(접힌 구간 제외, 격자는 정확); 격자의 소수 분 왕복 오차 < 1e-9(줌·보간 포함); 열 상수와 `blockFrame`이 두 축에서 같고, 같은 y를 주는 두 축에서 같은 값; `DayRenderPlan`이 어느 축이든 일정의 시작·끝 y를 축의 답 그대로 쓴다; 엔진의 `fixedAxis`(격자 `timelineAxis()`)로 만든 기존 타입 경로와 격자 매핑 경로가 같은 프레임·같은 프레젠테이션·같은 거래 줄을 만든다.

## 2. DST(23/25시간) 시간 좌표 정책 — `DayWallClock`

위치: `Sources/NEOBudgetCalendar/Timeline/DayWallClock.swift` (코어 패키지, `swift test`로 검증). `DayTimeline`의 분은 **경과 분**(하루 시작 기준, `DayTimeline.totalMinutes` = 1380/1500일 수 있음)이고 이 의미는 바뀌지 않는다. 격자는 **벽시계 24시간(0~1440)** 축에 그리므로 둘 사이의 매핑만 정의한다. 모든 규칙은 이미 있는 `DisplayTimeZone.instant(of:minuteOfDay:)`의 규칙과 일치한다(테스트로 모든 분에서 확인).

| 규칙 | 내용 |
|---|---|
| 1. 시각 → 벽시계 `wallMinute(forElapsed:)` | 그 순간의 시계 눈금. 모호하지 않다. 하루의 끝은 1440. |
| 2. 벽시계 → 시각 `elapsedMinute(forWall:)` | 존재하지 않는 시각(봄 갭)은 갭 뒤의 **첫 실제 시각**, 반복되는 시각(가을)은 **첫 번째 발생**. 두 번째 발생은 벽시계 축에서 지정할 수 없다. |
| 3. 구간 `wallRange(startElapsed:endElapsed:)` | 시작의 벽시계 분 ~ 마지막으로 덮는 분의 끝(구간이 도달하는 최대 벽시계 분). 갭을 가로지르면 갭을 덮고, 가을 반복 구간의 두 번째 발생에 있는 구간은 첫 번째와 같은 벽시계 분에 놓인다(겹침). 접힘을 가로지르면 첫 번째 발생의 끝까지로 그린다. |
| 4. 하루 경계 | 모든 값을 하루로 clamp(앞 날에서 이어지거나 다음 날로 이어지는 구간은 가장자리까지). `DayTimelineBuilder`가 다일 일정을 이미 하루 분으로 clamp한다. |

- `kind`(`regular/springForward/fallBack`), `skippedWall`(예: 120..<180), `repeatedWall`(예: 60..<120). 일반 날은 항등이고 표를 만들지 않는다(정상 경로 비용 0, 전환일만 최대 1500회 시계 조회).
- 테스트(`DayWallClockTests` 7개, America/New_York 2026-03-08 봄 / 2026-11-01 가을, Asia/Seoul): 일반 날 항등; 봄: 02:00~03:00 갭, 경과 120 = 벽시계 180, 갭 시각 → 120, 03:00~04:00 → 180~240, 갭 가로지르는 구간이 갭을 덮음; 가을: 1:30의 두 발생이 같은 벽시계 분, 반복 구간 → 첫 발생, 두 번째 발생의 구간은 첫 번째와 같은 y, 접힘 가로지르는 구간 → (90,120), 02:00 표준시 = 경과 180; **세 종류의 날 모든 벽시계 분에서 `instant(of:minuteOfDay:)`와 같은 순간**, 모든 경과 분에서 `zone.minuteOfDay(of:)`와 같은 벽시계; 갭·반복 외의 왕복 항등; 단조성(가을의 한 번 되돌아감 제외)과 하루 clamp; 다일 일정의 가장자리.
- **남은 제약**(문서화된 수용 사항):
  1. 가을 반복 시간대의 두 번째 발생에 있는 일정·거래는 첫 번째 발생과 **같은 y에 겹쳐 그려진다**(식별·선택은 유지). 반복 구간에서의 드래그/생성은 첫 번째 발생으로 간다.
  2. 접힘을 가로지르는 일정은 실제 길이보다 짧게 그려진다(구간이 드문 사례).
  3. 봄의 갭 시간대는 비어 있는 한 시간으로 보인다(라벨은 실제 벽시계 시각).
  4. 기존 Browse(경과 분 축)는 변경하지 않았다. 격자 통합(Phase 1)에서 `DayRenderPlan`에 줄 매핑이 경과 분 → 벽시계 분 변환(`DayWallClock`)을 거치는 어댑터를 둬야 한다(이번에는 만들지 않음, Phase 1 작업).
  5. 두 날의 DST 상태가 다르면(전환일과 그 다음 날) 벽시계 축에서는 같은 시각이 같은 높이에 오고, 경과 축(기존 Browse)은 한 시간 어긋난다 — 격자 통합이 이 어긋남을 해소한다.

## 3. 날 캐시 정책

`Model/DayCache.swift`(순수, 테스트됨), `AppModel`이 사용.

| 용어 | 값 | 의미 |
|---|---|---|
| required | `D-1 … D+2` (4일) | 항상 읽혀 있어야 하는 날(그리는 날 + 계획에 쓰는 날). 현 `strip`과 같다. |
| retained | required ± `margin`(2) = `D-3 … D+4` (8일) | 이미 읽혔으면 **유지**한다. 이동으로 required에서 빠져도, 되돌아와도 다시 읽지 않는다. |
| capacity | 12일 | eviction 후 최대 개수. retained(8) 위의 여유는 먼 이동 전 선읽기 용도. |

- **eviction**은 창이 움직일 때(`merge`/`evict`)만 일어나고 retained 밖을 지운 뒤 capacity를 넘으면 `D`에서 먼 날부터 지운다. 먼 이동의 선읽기(`adopt`→`insert`)는 착지 전까지 아무것도 지우지 않는다.
- **읽기 종류를 둘로 나눴다**:
  - `reload()` — 전과 같다. 달력 변경 알림, 앱 복귀, 저장된 편집 후에 쓰는 "무언가 바뀌었다" 읽기. required 4일 + 주 3개 + 달력 + 라이프 상태를 다시 읽고 캐시를 **읽은 날만으로 교체**(retained 날은 오래됐을 수 있어 버린다).
  - `loadMissing(extra:)` — 새로운 읽기. **날짜 이동 후**에 required 중 **없는 날만**(`extra`는 연속 이동용 선읽기, 최대 margin까지) 읽고, 필요한 주 셀만 읽고, 창 밖을 evict한다. 달력/라이프 상태는 읽지 않는다. 이미 `reload()`가 진행 중이면 그것이 더 신선하므로 `reload()`가 된다(데이터 갱신이 이동 때문에 버려지지 않게).
- Browse의 이동 경로(`goTo` 3곳, 스와이프 정착 `onMoveDays`)가 `reload()` 대신 `loadMissing()`을 부른다. 화면에 보이는 결과는 같고(이동 즉시 캐시된 날 표시, 부족한 날은 읽는 대로), 읽는 날이 4일 → 0~1일로 준다. `moveTo`와 에디터 통지(`timelinesDidChange`)는 그대로.
- 계측: `AppModel.dayReads`(읽은 날 수), `cachedDays`.
- 검증(`DayCacheTests` 6개 + `AppModelDayCacheTests` 6개, 합성 달력 `-demo`): 첫 읽기 = required 4일뿐(`dayReads == 4`); 하루 이동 → 읽기 +1(D+3만), D-1은 지워지지 않음, 되돌아가면 읽기 0; 8일 앞으로, 8일 뒤로 이동에서 이동당 새 읽기 ≤ 1, 캐시 ≤ capacity, 항상 retained ⊂, 이동 즉시 두 날이 보임; 선읽기 `extra: 2` → +4, 다음 이동에서 +1, 그다음 0; 달력 변경(`reload`) → required 4일만 남고 4회 읽음; 먼 점프의 선읽기 4일은 착지 후 `loadMissing`이 0회로 끝나고 창 밖은 evict; 순수 캐시의 읽기 최소성·용량·교체 의미.

## 4. 상태·소유권 경계 (구현은 하지 않고 경계를 고정)

| 상태 | 소유자 (현재 → Phase 1 이후) | 이번 Phase에서 한 일 |
|---|---|---|
| 일정·거래 데이터, 날 캐시 정책 | `AppModel` + `DayCache`/`DayCachePolicy` | 정책을 한 곳으로 모으고 읽기 경로를 둘로 나눔(`reload`/`loadMissing`) |
| 커밋된 날 `selectedDay` | `AppModel` (이동이 정지할 때만 갱신 — Phase 1) | 변경 없음 |
| 시간 좌표 | 호출자가 정한 `TimeAxisMapping` (Browse: `TimelineGeometry`, 격자: `TemporalAxisMapping`) | 프로토콜 도입, 소비자(`DayRenderPlan`, `TimelineEditPlanner`)는 구체 축을 모름 |
| 벽시계↔경과 변환 | `DayWallClock` (코어, 순수) | 규칙 정의·검증. 소비는 Phase 1 |
| 위치/줌/앵커 | 아직 Browse에는 없음 (프로토타입의 `DayMoveModel`/`PinchZoomModel`/`AnchorState`) | 건드리지 않음. Browse에 연결하지 않음 |
| 선택·편집·저장·롤백 | `TimelineEditor` + `CalendarCommandService` | 변경 없음(편집기는 `TimelineGeometry`를 그대로 사용, 계획기만 프로토콜을 받음) |

경계 규칙: (1) 데이터는 `AppModel`만 읽는다. (2) 축은 값으로 주입되고 소비자는 모른다. (3) 날짜 이동 상태는 `DayMoveModel` 하나로 정해져 있다(새로 만들지 않음). (4) 편집·EventKit 경로는 지오메트리 구현과 무관하다.

## 5. 검증 요약

- 새 테스트: 코어 `DayWallClockTests` 7, 앱 `TimeAxisMappingTests` 6, `DayCacheTests` 6, `AppModelDayCacheTests` 6 (총 25).
- `tools/dev/check.sh full` 통과: 코어 패키지 415개(+7), 앱 370개(+18). 기존 Browse·DEBUG 테스트는 수정·삭제 없이 통과.

## 6. Phase 1 진입 가능 여부

가능하다. 남은 선행 조건과 Phase 1의 첫 작업:
1. 경과 분 → 벽시계 분 어댑터(`DayWallClock`을 쓰는 `TimeAxisMapping`)를 Phase 1 첫 작업으로 만든다(DST 제약 4 참조).
2. 먼 날 이동 정책(`maximumHop`)과 `loadMissing(extra:)`의 반경을 같이 정한다(통합 문서 9.7).
3. `DayRenderPlan`의 정적/동적 분리와 `TimelineEditorTests`의 지오메트리 무관/축 의존 분리는 Phase 0의 나머지 항목으로 남았다(이번 요청 범위 밖: 요청된 4개 작업만 수행). Phase 1에서 `DayRenderPlan`을 프레임마다 다시 만드는 비용(0.88ms/날)이 문제가 되기 전에 분리해야 한다.
