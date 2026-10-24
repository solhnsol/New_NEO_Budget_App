# Phase 3A — 고정 그리드 편집 인터랙션 연결 기반

대상: `-browse-temporal`(DEBUG) 고정 그리드 Browse. 이번 단계는 2B-3의 제스처 소유권·freeze 위에 **편집 세션의 상태 머신과 라우팅**을 얹는다.

- 실제 시간 변경, Draft, 말풍선, 저장(EventKit 쓰기)은 연결하지 않는다.
- 다른 세션(정밀 UI, 저장 파이프라인)의 타입에 의존하지 않는다. 작은 **이벤트 → 명령** 인터페이스로만 만난다.
- 세션 진입은 여전히 DEBUG 편집 프로브(`-browse-temporal-edit-probe`)에서만 열린다. 기본 Browse·Release 동작은 그대로다.

## 1. 상태 머신 (`FixedGrid/FixedGridEditInteraction.swift`)

순수 값 타입이라 테스트로 검증한다. `handle(_ event) -> [Command]`.

**입력 이벤트**

| 이벤트 | 보내는 곳 |
|---|---|
| `enter(Target)` | 편집 가능한 일정(`isEditable`) 길게 누르기 (프로브) |
| `handleTap(start/end)` | UIKit 탭 인식기 → `TapMeaning.handle` |
| `handleDrag(phase, handle, point, minute)` | 핸들 pan. `minute`은 고정 축에서 손가락 높이의 경과 분 |
| `tapOutside` | 빈 격자, 거래선·묶음 카드, 편집 불가 일정, 날짜 헤더 |
| `tapEvent(Target)` | 편집 중 다른 일정 탭 |
| `selectedDayChanged` | 주간 스트립·"오늘" 등으로 선택일이 바뀜 |
| `cancel` / `confirm` | 편집 UI의 취소·완료 (이번에는 프로브 버튼) |
| `draftChanged` / `commitFinished` / `commitFailed` | 편집 부품(Draft·저장)의 응답 |

**출력 명령**

| 명령 | 받는 곳 |
|---|---|
| `freeze` / `retarget` / `unfreeze(anchor)` | 화면이 직접 수행(그리드 명령, `isGrid`) |
| `began` / `handle(state)` / `dragHandle` | 편집 부품: Draft 시작, 말풍선 표시·숨김, 끌기 단계 |
| `commit` / `discard` / `askExit` / `ended(reason)` | 편집 부품: 저장, 폐기, 나가기 확인, 세션 종료 |

**`FixedGridEditRouter`** (`@Observable`)가 화면과 편집 부품 사이의 유일한 접점이다.

- 화면은 `grid` 클로저로 그리드 명령을 받는다.
- 편집 부품은 `editor` 클로저로 나머지 명령을 받고, `send`로 응답한다.
- 이번에는 `editor`를 DEBUG 프로브만 구현한다. 핸들을 끌면 "변경됨"이 되고, 저장은 0.35초 뒤 원래 시각으로 성공한다(`-browse-temporal-edit-probe-fail`이면 실패).

## 2. 정책

**핸들 상태:** `none` / `selected(h)` / `dragging(h)`

- 탭: 그 핸들을 선택한다(말풍선). 같은 핸들을 다시 탭하면 해제하고, 다른 핸들을 탭하면 그쪽으로 바꾼다.
- 끌기: 끄는 동안 `dragging`이고, 끝나면 `selected`가 된다. 끈 직후 말풍선으로 미세 조정을 잇는다.
- 마지막으로 만진 핸들(`lastEdited`)은 종료 시 앵커로 쓴다.

**종료 정책** (`ExitPolicy`, 기본값 굵게)

| 상황 | 변경 없음 | 변경 있음 |
|---|---|---|
| 완료 | 그냥 종료(가운데 앵커) | `commit` → 응답까지 **freeze 유지** → 성공 시 편집한 가장자리 앵커로 unfreeze, 실패 시 편집으로 복귀(변경 유지) |
| 취소 | 종료 | `discard` 후 종료 |
| 바깥 탭 | 선택된 핸들이 있으면 **먼저 해제만** 한다. 다음 탭에 종료 | 먼저 핸들 해제. 다음 탭은 `outsideTap` 정책: **commit** / discard / ask |
| 다른 일정 탭 | 세션이 그 일정으로 옮겨 감(`retarget`), **unfreeze 없음** | 바깥 탭과 같음 |
| 선택일 변경 | 즉시 unfreeze 후 종료 | 즉시 unfreeze. `dayChange` 정책: **commit** / discard. `ask`는 commit으로 처리한다(날짜가 이미 움직여 답을 기다릴 수 없음) |

- `ask`: 세션을 freeze한 채로 둔 채 `askExit`를 보낸다. 답은 `confirm` 또는 `cancel`이다. 기다리는 동안 다른 터치는 무시한다.
- 저장 중에는 `commitFinished`/`commitFailed`와 선택일 변경만 받는다. 선택일 변경이 오면 그리드를 즉시 놓고(`released`), 저장 응답은 세션을 닫기만 한다. 놓은 뒤 실패하면 `ended(.commitFailedAfterRelease)`로 알린다.
- 다음 세션은 이전 저장이 끝난 뒤에만 연다.

## 3. freeze 유지

- 세션이 열려 있는 동안 `gestureMode`는 항상 `editing`이다.
  - 2B-3에서는 대상 카드를 찾지 못하면(reload로 block id가 다시 만들어지거나 일정이 사라지면) `browse`로 돌아갔다. 그러면 freeze 중에 날짜 스와이프가 열렸다.
  - 이제는 그런 경우에도 핸들 없는 `editing`을 유지한다. 날짜는 움직이지 않고, 스크롤·핀치는 그대로 된다.
- 카드는 block id로 찾고, 없으면 캘린더 키(`eventKey`)로 찾는다.
- 다른 일정으로 옮겨 갈 때 `FixedGridBrowseModel.retarget`을 쓴다.
  - 분할·결정은 그대로 둔다. 2B-3 프로브는 unfreeze 후 다시 freeze해서 줌이 바뀐 뒤면 결정이 튈 수 있었다.
  - 원본의 시작점(generation, revision, 날짜들)은 유지하고 대상만 바꾼다.
- 저장 중에도 freeze는 유지된다. 응답을 받은 뒤에만 unfreeze한다.

## 4. 저장 후 unfreeze 앵커 (`FixedGrid/FixedGridUnfreezeAnchor.swift`)

**앵커 요청** (`AnchorRequest`): `.middle` 또는 `.edge(handle, day, minute)`

- 저장 성공 시 마지막으로 만진 핸들을 앵커로 쓴다.
- 만진 핸들이 없으면, 저장 결과에서 끝만 움직였으면 끝을, 아니면 시작을 쓴다.
- minute은 **저장된 시각**(경과 분)이다.

**해석** (`resolve`)

- 고정 분할·줌·뷰포트·스크롤 위치로 그 가장자리가 지금 그려진 높이(`focal`)를 구한다.
  - 시작은 그 벽시계 분이고, 끝은 끝나기 직전 분(`exclusiveEndWall`)이다. 카드를 그리는 규칙과 같다.
- 가장자리가 화면 밖이면 가운데 시각으로 대체한다.

**적용**

- 해제 이징 동안 매 프레임 `anchoredOffset(time, focal)`로 스크롤을 맞춰 가장자리 높이를 고정한다.
- 사람이 스크롤하거나 날짜가 움직이면 앵커를 놓는다.
- 이징이 끝나면 남은 오차를 프로브에 표시한다.
- 앵커가 없으면(취소·변경 없음·선택일 변경) 2B-3처럼 가운데 시각을 고정한다.

## 5. 검증

**`OnAllAppTests/FixedGridEditInteractionTests.swift` (14개)**

- 진입 → `freeze`+`began`
- 핸들 탭 선택·해제·전환, 끌기 단계와 분 전달
- 세션 없을 때 모든 이벤트 무시
- 완료: 저장 중 입력 무시, 다른 세션의 응답 무시, 성공 시 끝 가장자리 앵커, 실패 시 편집 복귀
- 변경 없는 완료·취소·폐기
- 바깥 탭 정책 3종: 핸들 먼저 해제, ask는 답만 받음
- 다른 일정: `retarget`이고 unfreeze 없음, 변경 있으면 나가기
- 선택일 변경: 즉시 unfreeze, commit·discard·ask→commit, 저장 중 변경, 놓은 뒤 실패, 다음 세션 대기
- 대상 카드를 못 찾아도 `editing` 유지(날짜 스와이프 불가, 핸들 없음), 저장 중 freeze 유지
- `retarget`: 실제 `FixedGridBrowseModel`에서 분할·결정 그대로, 원본 시작점 유지(옮기기 전 변경일 감지), 다른 id 무시
- 앵커 가장자리 선택 규칙
- **3× 줌, 데이터 변경 후 해제:** 매 프레임 편집한 끝 가장자리의 높이 오차 < 1e-6pt. 앵커가 없으면 1pt 넘게 움직였을 것을 함께 확인
- 화면 밖 가장자리는 가운데로 대체, 끝 분 규칙
- 라우터: 그리드/편집 부품 분배, 편집 부품의 재진입 응답

**시뮬레이터 실터치** (`-browse-temporal-edit-probe`, `docs/ui-reviews/edit-interaction/`): README 참고

- 진입·핸들 탭·핸들 끌기(날짜 이동 없음)·바깥 탭 2단계(핸들 해제 → commit, 앵커 오차 0.00pt)
- 변경 있는 상태에서 주간 스트립 날짜 변경(commit 후 날짜 이동)
- 변경 없는 다른 일정 탭(세션 번호 유지, 핸들만 이동)
- 취소

**`tools/dev/check.sh full`:** 패키지 415 + 90, 앱 452(기존 438 + 14) 통과. Release 빌드 성공.

## 6. 다음 세션과의 접점

**편집 부품** (Draft·말풍선·저장)은 `router.editor`에 붙는다.

- `began(target)`: Draft를 만든다.
- `handle(state)`: 말풍선을 표시하거나 숨긴다.
- `dragHandle(phase, handle, point, minute)`: 끄는 대로 Draft를 갱신한다.
- `commit`: 저장한다.
- `discard`: Draft를 버린다.
- `askExit`: 확인을 받는다.
- `ended`: 정리한다.

**응답:** `draftChanged`, `commitFinished(Committed)`, `commitFailed`. 확인 UI의 답은 `confirm` / `cancel`.

**남은 결정**

- 바깥 탭 기본값(commit)이 맞는지.
- 선택일 변경 시 확인을 받으려면 날짜 이동을 미루는 경로가 따로 필요하다.
- 핸들 외 영역 길게 누르기(이동)·빈 곳 생성 진입은 이번 범위가 아니다.
