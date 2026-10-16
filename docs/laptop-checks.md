# 노트북 확인 목록

클라우드에서는 Swift 패키지 테스트(`swift test`)만 돌린다. Xcode·시뮬레이터·실기기가 필요한 확인은 여기에 쌓아 두고, 노트북이 연결될 때 한 번에 실행한다. 확인한 항목은 결과와 함께 지운다.

## 공통

```zsh
git fetch origin && git checkout claude/project-thread-hstee5
tools/dev/check.sh full
```

## 대기 중

10/16 오후 노트북 실행(hstee5 `36c0417` 빌드·설치)은 세션이 응답을 멈춰 중단됐고 앱 테스트 결과가 남지 않았다. 아래 `check.sh full` 항목은 모두 다시 돌린다.

| 브랜치/커밋 | 확인할 것 | 방법 |
|---|---|---|
| `claude/project-thread-3pg436` | 앱 빌드와 앱 테스트 통과 (새 `DayRenderPlanTests` 항목 포함). 화면 코드는 클라우드에서 컴파일하지 못했다. 첫 확인(10/16)에서 만들기·이동·칩·핸들·완료·취소는 통과. | `tools/dev/check.sh full` |
| `claude/project-thread-3pg436` | 접힌 시간대(오전 6–9시)에 길게 눌러 만들어도 카드가 제목과 시간이 보이는 높이로 그려진다. 끝 핸들을 끌면 첫 움직임에 끝 시각이 튀지 않는다. | `tools/dev/check.sh ui -demo -browse-temporal` → 6–9시 빈 곳 길게 누르기 → 끝 핸들 끌기 |
| `claude/project-thread-3pg436` | 스터디를 품는 새 일정(예: 12:30–15:45)을 저장해도 "스터디" 제목이 바깥 카드의 "거래 N건" 줄과 겹치지 않는다. | 위 실행에서 만들고 완료 |
| `claude/project-thread-3pg436` | **직접 확인:** 손을 떼면 키보드가 바로 올라오고 이름을 쳐서 저장된다. 끄는 도중 점선 미리보기와 시간축 시작 시각이 손가락을 따라 움직인다. | Hans가 시뮬레이터나 실기기에서 직접 |
| `claude/project-thread-5mrles` | 고정 그리드에서 거래 줄을 길게 누르면 거래가 손가락을 따라오고, 일정 카드 위에서는 카드 테두리가 굵어지며 "→ 일정 이름"이 보인다. 놓으면 그 일정 카드 안으로 들어간다. 빈 곳에 놓으면 아무것도 바뀌지 않는다. (길게 눌러 일정 만들기 브랜치를 합친 위에서) `FixedGridTransactionCarryTests` 통과. | `tools/dev/check.sh ui -demo -browse-temporal` → 카드 밖 거래 줄 길게 누르기 → 다른 일정 위에 놓기 |
| `claude/project-thread-hstee5` | 단축어 연결 코드가 Xcode에서 빌드되고 앱 테스트가 통과한다 (`RecordNotificationIntent`, 받은 알림 화면은 클라우드에서 컴파일하지 못했다). | `tools/dev/check.sh full` |
| `claude/project-thread-hstee5` | **실기기, `-live`로 실행** (인자 없이 켜면 더미 데이터라 받은 알림 버튼이 없다. 단축어 동작은 그래도 알림을 저장한다): 단축어 앱 동작 목록에 "OnAll · 알림 기록하기"가 보인다. 기존 자동화의 서버 전송 단계를 이 동작으로 바꾸고 결제 알림을 받으면, 가계부 탭 오른쪽 위 "받은 알림"에 제목·본문이 나뉘어 보인다(한 덩어리로 보이면 사전이 JSON으로 넘어오지 않은 것). | Hans가 폰에서 직접 |
| `claude/project-thread-hstee5` | **실기기:** "이 계좌가 맞나요?"에서 계좌를 등록·연결하면 앞서 받은 알림까지 "가계부에 반영됨"으로 바뀌고, 소비 목록과 캘린더 거래 줄에 앱을 다시 켜지 않아도 나타난다. 앱을 껐다 켜도 남아 있다. 잠긴 화면에서 온 알림도 기록된다. | Hans가 폰에서 직접 |
| `claude/project-thread-hstee5` | 실행 인자 없이 켜도(폰 설치본 포함) 캘린더가 고정 그리드로 열리고, 맨 아래 안내 줄이 없다. `-browse-classic`을 주면 예전 화면이 나온다. `FixedGridBrowseTests`의 기본값 테스트가 통과한다. | `tools/dev/check.sh ui` (인자 없이) |
| `claude/project-thread-01q0du` (UI 통일) | 앱이 빌드된다(`Support/Design/` 새 파일, 정산·활동 정보 시트, 가계부 탭, 받은 알림은 클라우드에서 컴파일하지 못했다). 앱 테스트 통과. | `tools/dev/check.sh full` |
| `claude/project-thread-01q0du` (UI 통일) | 가계부 탭: 회색 없는 흰 목록에 날짜 줄(회색 작은 글씨, 오늘은 파란 "오늘" 배지), 각 거래 앞에 둥근 회색 아이콘 타일, 환불은 파란 "+금액". 거래를 누르면 금액이 맨 위에 크게. 계좌·카드 보기는 회색 바탕에 흰 카드, 계좌/카드 아이콘 타일. 다크 모드에서도 글씨가 읽힌다. | `tools/dev/check.sh ui -demo` → 가계부 탭, 다크 모드도 |
| `claude/project-thread-01q0du` (UI 통일) | 정산 시트: 맨 위 "결제한 금액"이 크게, "함께한 사람"은 얼굴 동그라미 줄("나"가 맨 앞, 고른 사람은 진하고 체크, 안 고른 사람은 흐림, 끝에 "+ 추가" → 이름 입력 창), 그 아래 "총 인원 − N명 +"(나 포함 설명). 나눠 낼 금액은 얼굴과 함께, 맨 아래 파란 큰 버튼 "N명에게 정산 요청 만들기". 요청 뒤에는 사람 고르기가 잠기고 상태가 주황/파랑 배지로. | 데모 일정 상세 → 정산하기 |
| `claude/project-thread-01q0du` (UI 통일) | 일정 상세의 "무엇을, 어디서, 누구와" 시트: "누구와"가 정산과 같은 얼굴 줄이고, 누르면 바로 저장된다. | 데모 일정 상세 → 무엇을, 어디서, 누구와 |
| `claude/project-thread-01q0du` (UI 통일) | 새 일정 만들 때 키보드 위 줄: "누구와" + 작은 얼굴 칩, 오른쪽 끝에 고정된 "− N명 +"(사람 칩만 가로로 스크롤). 사람을 고르면 최소 인원이 따라 올라간다. 아는 사람이 없으면 안내 문구가 보인다. | 빈 곳 길게 눌러 새 일정 → 키보드 위 줄 |
| `claude/project-thread-yu6o5o` | 앱 빌드와 새 `whileTheDaysMoveALineIsWritten…` 테스트 통과 (`DayRenderPlan.holdingVisibility`, 화면 코드는 클라우드에서 컴파일하지 못했다). | `tools/dev/check.sh full` |
| `claude/project-thread-yu6o5o` | 좌우로 천천히 끌어 날짜를 옮기는 동안 거래 줄 글자·카드 위 제목 탭(헤더)·짧아진 제목이 나타났다 사라지지 않는다. 정지했을 때 보이던 것이 그대로 따라 움직이고, 가운데 날(0.3–0.7 구간)만 서서히 바뀐다. | `tools/dev/check.sh ui -demo -browse-temporal` → 거래 많은 날에서 천천히 끌기, 중간에 멈췄다 되돌리기 |
| `claude/project-thread-yu6o5o` | **직접 확인:** 상단 주간 달력을 옆으로 밀어 다음/이전 주로 넘기면, 떠나는 검은 공이 그 주와 함께 밀려 나가며 사라지고 새 주가 미끄러져 들어온다(제자리에서 사라지거나 반대로 튀지 않는다). 날 탭, 그리드 스와이프 때 공·캡슐 움직임은 예전과 같다. | Hans가 시뮬레이터나 실기기에서 직접 |
| `claude/project-thread-5trncm` | 인자 없이 켜면 6주치 더미 일정과 소비가 열리고(오늘 기준 4주 전–2주 후), `-live`로 켜면 기기 캘린더와 실제 장부가 열린다. 앱 테스트는 예전 샘플 하루를 그대로 본다. | `tools/dev/check.sh ui` (인자 없이), `tools/dev/check.sh ui -live` |

## 확인 완료 (2026-10-16, 노트북)

- `claude/project-thread-hstee5` `tools/dev/check.sh full`: 패키지 582개, 앱 499개 통과.
- `claude/project-thread-hstee5` 고정 그리드 "무엇을 선택할까요?": 데모 16일 "배달"(저녁 운동과 겹침)에서 거래를 고르면 상세 시트가, 일정을 고르면 편집 세션(핸들, 취소/완료 막대)이 열린다.
- 7일 실제 데이터 재검증: 결과는 `docs/correlator-design.md` 6절 5번.
