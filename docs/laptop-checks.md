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

## 확인 완료 (2026-10-16, 노트북)

- `claude/project-thread-hstee5` `tools/dev/check.sh full`: 패키지 582개, 앱 499개 통과.
- `claude/project-thread-hstee5` 고정 그리드 "무엇을 선택할까요?": 데모 16일 "배달"(저녁 운동과 겹침)에서 거래를 고르면 상세 시트가, 일정을 고르면 편집 세션(핸들, 취소/완료 막대)이 열린다.
- 7일 실제 데이터 재검증: 결과는 `docs/correlator-design.md` 6절 5번.
