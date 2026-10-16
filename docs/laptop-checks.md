# 노트북 확인 목록

클라우드에서는 Swift 패키지 테스트(`swift test`)만 돌린다. Xcode·시뮬레이터·실기기가 필요한 확인은 여기에 쌓아 두고, 노트북이 연결될 때 한 번에 실행한다. 확인한 항목은 결과와 함께 지운다.

## 공통

```zsh
git fetch origin && git checkout claude/project-thread-hstee5
tools/dev/check.sh full
```

## 대기 중

| 브랜치/커밋 | 확인할 것 | 방법 |
|---|---|---|
| `claude/project-thread-3pg436` | 앱 빌드와 앱 테스트 통과 (새 `DayRenderPlanTests` 항목 포함). 화면 코드는 클라우드에서 컴파일하지 못했다. 첫 확인(10/16)에서 만들기·이동·칩·핸들·완료·취소는 통과. | `tools/dev/check.sh full` |
| `claude/project-thread-3pg436` | 접힌 시간대(오전 6–9시)에 길게 눌러 만들어도 카드가 제목과 시간이 보이는 높이로 그려진다. 끝 핸들을 끌면 첫 움직임에 끝 시각이 튀지 않는다. | `tools/dev/check.sh ui -demo -browse-temporal` → 6–9시 빈 곳 길게 누르기 → 끝 핸들 끌기 |
| `claude/project-thread-3pg436` | 스터디를 품는 새 일정(예: 12:30–15:45)을 저장해도 "스터디" 제목이 바깥 카드의 "거래 N건" 줄과 겹치지 않는다. | 위 실행에서 만들고 완료 |
| `claude/project-thread-3pg436` | **직접 확인:** 손을 떼면 키보드가 바로 올라오고 이름을 쳐서 저장된다. 끄는 도중 점선 미리보기와 시간축 시작 시각이 손가락을 따라 움직인다. | Hans가 시뮬레이터나 실기기에서 직접 |
| `claude/project-thread-5mrles` | 고정 그리드에서 거래 줄을 길게 누르면 거래가 손가락을 따라오고, 일정 카드 위에서는 카드 테두리가 굵어지며 "→ 일정 이름"이 보인다. 놓으면 그 일정 카드 안으로 들어간다. 빈 곳에 놓으면 아무것도 바뀌지 않는다. (길게 눌러 일정 만들기 브랜치를 합친 위에서) `FixedGridTransactionCarryTests` 통과. | `tools/dev/check.sh ui -demo -browse-temporal` → 카드 밖 거래 줄 길게 누르기 → 다른 일정 위에 놓기 |
| `claude/project-thread-hstee5` | 단축어 연결 코드가 Xcode에서 빌드되고 앱 테스트가 통과한다 (`RecordNotificationIntent`, 받은 알림 화면은 클라우드에서 컴파일하지 못했다). | `tools/dev/check.sh full` |
| `claude/project-thread-hstee5` | **실기기:** 단축어 앱 동작 목록에 "OnAll · 알림 기록하기"가 보인다. 기존 자동화의 서버 전송 단계를 이 동작으로 바꾸고 결제 알림을 받으면, 가계부 탭 오른쪽 위 "받은 알림"에 제목·본문이 나뉘어 보인다(한 덩어리로 보이면 사전이 JSON으로 넘어오지 않은 것). | Hans가 폰에서 직접 |
| `claude/project-thread-hstee5` | **실기기:** "이 계좌가 맞나요?"에서 계좌를 등록·연결하면 앞서 받은 알림까지 "가계부에 반영됨"으로 바뀌고, 소비 목록과 캘린더 거래 줄에 앱을 다시 켜지 않아도 나타난다. 앱을 껐다 켜도 남아 있다. 잠긴 화면에서 온 알림도 기록된다. | Hans가 폰에서 직접 |
| `claude/project-thread-hstee5` | 실행 인자 없이 켜도(폰 설치본 포함) 캘린더가 고정 그리드로 열린다. `-browse-classic`을 주면 예전 화면이 나온다. `FixedGridBrowseTests`의 기본값 테스트가 통과한다. | `tools/dev/check.sh ui` (인자 없이) |

## 확인 완료 (2026-10-16, 노트북)

- `claude/project-thread-hstee5` `tools/dev/check.sh full`: 패키지 582개, 앱 499개 통과.
- `claude/project-thread-hstee5` 고정 그리드 "무엇을 선택할까요?": 데모 16일 "배달"(저녁 운동과 겹침)에서 거래를 고르면 상세 시트가, 일정을 고르면 편집 세션(핸들, 취소/완료 막대)이 열린다.
- 7일 실제 데이터 재검증: 결과는 `docs/correlator-design.md` 6절 5번.
