# Phase 2B-1 — 프레임 지연 계측과 연속 이동 중 데이터 로딩 안정화

대상: `-browse-temporal`(DEBUG) 고정 그리드 Browse. 기존 Browse·Release·편집·EventKit 경로의 동작은 바꾸지 않았다(아래 "범위" 참고). 레이아웃 결정의 표현 전환(0.5 지점 교체)과 제스처 리팩터링은 다음 작업이다. 성능 최적화는 하지 않았다 — 이번 작업은 계측과 로딩 정합성만 다룬다.

## 1. 계측 도구

`Timeline/FixedGrid/BrowseProbe.swift` (DEBUG에서만 기록, Release는 본문 그대로 호출만 하는 통과 함수)

- **스팬**: 앱 코드의 구간을 종류별로 기록(중첩 깊이 포함)하고 `OSSignposter`(subsystem `dev.onall.app`, category `browse`)로도 내보낸다. 종류: `screenBody`(FixedGridBrowseView.body), `gridBuild`(그리드 SwiftUI 트리 생성), `hostLayout`(그리드 호스팅 컨트롤러의 레이아웃 패스, `ProbedHostingController`), `applyMove`, `framePlan`(프레임 안 분할 계획), `engine`(AdaptiveLayoutEngine), `warmAhead`, `warmLand`, `cacheMerge`(읽은 날 merge/evict, reload 교체), `haptics`, `pinchStep`, `transitionTick`, `outerBody`/`weekStripBody`/`summaryBody`(그리드 바깥 화면).
- **런루프 턴**: 메인 런루프가 깨어날 때부터 다시 잠들 때까지. SwiftUI 그래프 갱신·UIKit 레이아웃·Core Animation 커밋이 모두 이 안에 들어간다.
- **디스플레이 프레임**: CADisplayLink 간격. 중앙값의 1.5배를 넘으면 지연 프레임.
- 지연 프레임마다 겹친 스팬(종류별), 가장 긴 턴, 그 턴에서 앱 스팬이 차지한 시간과 나머지(`unattributed`), 근처의 마크(`boundary`, `dragBegan`, `released`, `rested`, `dayLanded`, `selectedDayChanged`, `pinchBegan/Ended`, `axisTransition`)를 보고한다.
- 실행 방법: `-browse-temporal-script swipes|swipes-zoomed|days|zoom -browse-temporal-log <path>`(스크립트) 또는 `-browse-temporal-probe <path>`(손으로 조작; 정지·핀치 종료마다 누적 보고서를 쓴다). `swipes`는 인식기가 부르는 것과 같은 `handleDateDrag` 경로로 느린 드래그, 절반 넘김, 강한 플릭, 비행 중 잡기, 비행 중 반전, 경계 넘었다 되돌리기를 8 ms 간격 샘플로 두 번 재생한다.
- 읽기 지연·실패 주입(DEBUG, `-demo`): `-day-read-delay <ms>`, `-day-read-jitter <ms>`(도착 순서 역전), `-day-read-fail-every <n>` (`Model/DayReadFaults.swift`, `AppModel.dayReadInterceptor`).

## 2. 측정 결과 (iPhone 18 Pro 시뮬레이터, 60 Hz, `-demo -demo-dense`)

원자료: `docs/ui-reviews/browse-loading/measurements/` (실행별 보고서, `SUMMARY.txt`, 집계 스크립트, Time Profiler 분석).

### 2.1 지연 프레임

| 실행 | 프레임 | 지연 | 최악 | 지연 턴에서 앱 스팬 밖 비율 | 근처 마크 |
|---|---|---|---|---|---|
| swipes ×5, Debug `-Onone` | 3503 | 13 (0.37%) | 41.8 ms | 92% | dragBegan 9, boundary 4 |
| days ×5, Debug | 1193 | 9 (0.75%) | 49.4 ms | 89% | boundary 5, 없음 4 |
| zoom 1→8→1 ×5, Debug | 819 | 3 (0.37%) | 46.0 ms | 79% | 없음 3 |
| swipes ×5 (2차, 마크 추가 후), Debug | 3483 | 23 (0.66%) | 419.8 ms* | 85% | boundary 13, dragBegan 6, 없음 4, dayLanded 3, selectedDayChanged 3 |
| swipes ×5, `-O` | 3509 | 8 (0.23%) | 38.7 ms | 93% | boundary 6, dragBegan 2 |
| days ×5, `-O` | 1190 | 5 (0.42%) | 46.4 ms | 92% | boundary 3 |
| zoom ×5, `-O` | 820 | 1 (0.12%) | 33.3 ms | 86% | — |
| swipes ×3, 읽기 150 ms + 0–250 ms | 2105 | 7 (0.33%) | 40.7 ms | 90% | dragBegan 4, boundary 4 |
| swipes ×3, 읽기 60 ms + 0–120 ms, 4번째마다 실패 | 2098 | 8 (0.38%) | 44.5 ms | 84% | boundary 4, dragBegan 3, dayLanded 1 |
| 실제 터치(시뮬레이터 주입: 플릭 7, 핀치 1), 읽기 120 + 0–200 ms | 1870 | 6 | 159.6 ms (첫 스와이프) | 95% | dragBegan/boundary, rested/selectedDayChanged |

\* 한 실행에서 프로세스 전체가 멈춘 구간: 평소 0.03 ms인 `screenBody`가 10.5 ms, 0.01 ms인 `weekStripBody`가 4.2 ms로 모든 종류가 100–200배 느려졌다. 앱 작업이 아니라 시뮬레이터/호스트 정지로 보고 결론에서 제외한다(자료는 남겨 둠).

### 2.2 앱 스팬의 비용 (swipes, Debug; `-O`는 대략 절반)

| 스팬 | 평균 | p99 | 최대 |
|---|---|---|---|
| applyMove | 0.12 ms | 0.40 | 1.9 (첫 haptics 포함 시 11.3) |
| gridBuild | 0.13 | 0.49 | 0.6 |
| hostLayout | 0.46 | 1.35 | 5.4 |
| screenBody | 0.05 | 0.16 | 0.3 |
| engine | 0.04 (Debug 손조작 0.16) | — | 0.9 |
| cacheMerge | 0.03 | 0.12 | 0.2 |
| haptics (`Haptics.snap`) | 0.2 | — | **첫 호출 9–11 ms**, 이후 ≤ 2–5 ms |
| framePlan (프레임 안 분할 계획) | 3.5 (손조작 2회) | — | 3.9 |

### 2.3 Time Profiler (swipes 한 실행, 메인 스레드 1 ms 샘플, ≥12 ms 연속 구간 9개; `time-profile-swipes.txt`)

- 구간 샘플의 약 85–90%가 `_UIHostingView` 아래 SwiftUI 트랜잭션 flush·그래프 갱신(`GraphHost.flushTransactions`, `updateGraph`) 안에 있고, 스택에 앱 프레임이 `$main`밖에 없다. 최상위 라이브러리는 libswiftCore 76, AttributeGraph 39, SwiftUICore 24.
- 그 구간에서 보인 앱 body: `WeekStripView.dayCell`, `SummaryBar.body`, `DayHeaderCell.body`(그리드 **바깥** 화면), `DayPlanPreparations.prepared`, `HourAxis.layout`, `FixedGridBrowseView.plan`. 프레임워크 리프: `Button.body.getter` 10, `NSAttributedString.MetricsCache` 5, `ViewGraph.setRootView` 4, `ForEachChild.updateValue` 4.

### 2.4 측정된 사실과 원인 가설의 구분

**측정됨**
1. 지연 프레임은 전체의 0.12–0.75%이고, 지연 턴 시간의 79–95%는 앱 스팬 밖이다. `-O`로 앱 코드가 절반으로 줄어도 지연 수와 비율은 거의 같다.
2. 앱 자체 작업(이동 한 단계, 그리드 트리, 엔진, 캐시 merge)은 지연 턴에서 합쳐 0–12 ms이고, 그중 가장 큰 단일 항목은 **첫 `Haptics.snap()`의 9–11 ms**다.
3. 지연 프레임은 `boundary`(주간 스트립의 pending 날짜가 바뀌는 0.5 지점)와 `dragBegan`(특히 비행을 잡아 선택 날짜가 바뀌는 경우), `rested`/`selectedDayChanged` 근처에 몰린다. `dayLanded`/`axisTransition` 근처의 지연은 드물다(지연 주입 실행에서 15건 중 1건).
4. 첫 실행 패스에 지연이 많다. 같은 스크립트의 두 번째 패스는 지연 0인 실행이 여러 번 있었다. 실제 터치의 최악(160 ms)도 첫 스와이프다.
5. 그 턴들의 대부분은 SwiftUI 그래프 갱신이고, 그 안에서 그리드 바깥 화면(주간 스트립·요약·헤더)의 body가 평가된다. 그리드 호스트의 레이아웃 패스(`hostLayout`)는 지연 턴에서 대개 1–5 ms다.

**가설 (검증 안 됨)**
- H1. 0.5 지점에서 `pendingDays` 바인딩 변경 → `DayTimelineScreen`·`WeekStripView`(Button 21개) 재평가와, 같은 순간의 그리드 `layoutWindow` 교체·Prepared 캐시 미스가 겹쳐 SwiftUI 갱신이 커진다.
- H2. 첫 패스 집중은 최초 사용 비용(햅틱 엔진 준비, 처음 그리는 텍스트·폰트 메트릭, SwiftUI 뷰 최초 생성) 때문이다.
- H3. `updateUIView`에서 매번 하는 `hosting.rootView = AnyView(...)` 교체(`setRootView` 샘플)가 기본 비용을 더한다.
- 이 셋을 분리하려면: 주간 스트립 갱신만 끈 실행, 햅틱 `prepare()`만 한 실행, rootView 교체를 관찰 모델로 바꾼 실행을 각각 같은 스크립트 ×5로 비교한다. 실기기·Release·120 Hz는 측정하지 못했다(시뮬레이터 햅틱은 실제 Taptic Engine이 아니다).

## 3. 데이터 로딩 (`AppModel`)

| 요구 | 이전 | 지금 |
|---|---|---|
| 읽은 날짜 즉시 반영 | prefetch·loadMissing 모두 전부 읽은 뒤 한 번 merge(가까운 날부터 읽어도 표시는 같은 시점) | 하루씩 읽는 즉시 `keep` → merge (가까운 날부터) |
| 일부 실패 | prefetch: 한 날 실패면 `return`으로 앞서 읽은 날까지 버림. loadMissing: 실패면 전부 버리고 `.failed` | 실패한 날만 `failedDays`; 나머지는 유지. 다음 요청(이동, 정지, 화면 위 실패일 1초 뒤 최대 3회)에서 다시 읽음 |
| 이동 vs 데이터 revision | `generation` 하나를 reload·loadMissing이 모두 올림 → 이동(테이크오버, 정지)마다 진행 중 prefetch 결과가 버려짐 | `dataGeneration`(reload만 올림: 캘린더 변경 = 이전 읽기 무효) / `navigationRevision`+`navigationNeeded`(prefetch: 지금 이동이 필요한 날, eviction 보호) / `cache.revision`(내용 변경, 그리드가 다시 볼지 판단) |
| 오래된 결과 | 위와 같이 세대 비교만 | 읽기는 시작한 세대를 들고 있고, 착지 시 세대가 바뀌었으면 버림(`staleReadsDropped`). 같은 날 읽기는 하나만(두 번째 요청자는 합류) |
| 로딩 중 vs 빈 날짜 | 구분 없음(캐시에 없으면 열을 안 그림) | `loadState(for:)`: `.loaded`(빈 날 포함) / `.loading` / `.failed` / `.notRead`. 그리드는 로딩·실패 열에 "불러오는 중"/"불러오지 못했습니다" 표시 |
| eviction 기준 | prefetch는 그 시점 위치, loadMissing은 시작 시 선택일 | 착지 시점의 선택일 기준 + 화면 두 날과 최신 이동이 필요한 날 보호. 창이 떠난 날은 넣지 않음 |

- 기존 Browse 동작 유지: reload는 그대로 원자적 교체, loadMissing의 "화면 두 날 중 하나라도 실패하면 화면 실패"는 기본값(`failsScreen: true`)으로 유지. 고정 그리드만 `failsScreen: false`(실패는 그 열의 표시와 재시도). `DayTimelineScreen`은 고정 그리드 모드에서만 두 날이 다 없어도 그리드를 보인다.
- `editor?.timelinesDidChange` 호출 위치는 그대로(loadMissing 끝, reload). EventKit 공급자·명령 경로는 손대지 않았다.

## 4. 데이터 미도착 시 공유 시간축 (`FixedGridBrowseModel`)

- 창(D-1…D+2)에 읽히지 않은 날이 있으면 **분할을 계획하지 않는다**(프레임 안에서도, `warm`에서도). 대신 그 창이 보여 주던 분할 → 이웃 창의 분할 → 균등 분할 순으로 **유지**한다(`heldPartitions`).
- 날이 도착해 계획이 생기면(백그라운드 착지 또는 데이터가 다 있는 창의 프레임 안 계획), 화면에 있던 분할에서 새 계획으로 0.3초 ease-out으로 **보간**한다(`transitionsBegun`, `isEasing`). 화면을 떠난 창은 보간할 "보이던 것"을 버린다.
- 보간 중 정지 상태면 화면 가운데 시각을 `AnchorState`로 고정한다(`holdAnchor`, 확대 시).
- 엔진 결정은 창의 **계획된** 분할에서만 만든다(보간 중·유지 중인 축에서는 엔진을 돌리지 않음). 날이 없는 동안은 그 창의 마지막 결정을 유지하고, 없으면 엔진 없이 그린다.

## 5. 검증

- 새 테스트 `OnAllAppTests/DayLoadingTests.swift` (11개): 느린 날을 기다리지 않고 나머지가 먼저 반영; 실패한 날이 다른 날을 버리지 않고 로딩/실패/빈 날 구분 후 재시도로 회복; 화면 날 실패 시 기존 Browse는 화면 실패, 고정 그리드는 열 실패; 이동이 앞지른 읽기 유지 + 두 요청자 1회 읽기(도착 순서 역전 포함); reload가 앞지른 읽기는 버려지고 새 데이터를 덮어쓰지 않음(엉뚱한 날 데이터로 응답시켜 확인); 무작위 지연·실패·reload가 섞인 이동 폭주 후 캐시 일관성(날짜 키 = 내용, 이벤트·거래 identity 중복 없음, 용량, 필요한 날 모두 loaded, 실패 잔여 없음); 날 미도착 창은 계획 안 하고 축 유지; 아무것도 없으면 균등 분할; 도착 시 보간(첫 프레임은 이전 축, 18프레임 안에 정확히 새 계획, 한 프레임 최대 이동 ≤ 전체 변화의 1/5); 보간 중 엔진 재실행 없음; 떠난 창은 보간하지 않음.
- 전체 검사 `tools/dev/check.sh full`: 패키지 415 + 90, 앱 422(기존 411 + 신규 11) 통과. Release 구성 빌드 성공.
- 시뮬레이터: 지연·실패 주입 상태에서 실제 플릭 — 로딩 열 표시, 실패 후 재시도로 회복, 빈 날은 표시 없이 빈 날로 그려짐(`docs/ui-reviews/browse-loading/*.png`).

## 6. 남은 것 (다음 작업)

- 0.5 지점의 레이아웃 결정 교체와 세 번째 열의 `role == nil`(엔진 배치 없음): 표현 전환 작업.
- 지연 원인 가설 H1–H3 분리 실험과 그 결과에 따른 수정, 실기기·Release·120 Hz 측정.
- 스프링 타이머(`Task.sleep(8ms)`)의 비동기화: 이번 계측에서 step 간격 p99 ≈ 20 ms, 최대 46 ms. 수정은 측정 비교와 함께.
- 읽기는 순차(가까운 날부터)다. 맨 앞의 느린 날이 뒤의 날을 늦춘다. 서비스가 actor라 병렬화 이득은 측정 후 판단.
- 실패 재시도는 화면 위 날만 1초 간격 최대 3회, 나머지는 다음 이동 때. 실제 EventKit 오류 유형별 정책은 미정.
