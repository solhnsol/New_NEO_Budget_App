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
| `claude/project-thread-hstee5` | 고정 그리드에서 "무엇을 선택할까요?"로 **거래**를 고르면 상세 시트가 열린다. 일정을 고르면 지금처럼 편집 세션이 열린다. | `tools/dev/check.sh ui -demo -browse-temporal` → 데모의 "배달"처럼 겹친 곳을 탭 → 거래 선택 |
| `claude/project-thread-hstee5` | 앱 빌드와 앱 테스트 전체가 통과한다. Core 변경(교통카드 파서, `LedgerEntry.Kind.reversal`, `CandidateProcessingResult.corroborated`, 저장 후보의 새 필드)이 앱 코드와 충돌하지 않는다. | `tools/dev/check.sh full` |
| `claude/project-thread-3pg436` | 앱이 빌드되고 앱 테스트 전체가 통과한다 (새 `FixedGridCreateTests` 포함). 고정 그리드 화면 코드(`FixedGridBrowseView`)는 클라우드에서 컴파일하지 못했다. | `tools/dev/check.sh full` |
| `claude/project-thread-3pg436` | 고정 그리드 빈 곳을 길게 누르면 1시간짜리 새 일정이 손가락 밑에 생기고 손가락을 따라 15분 단위로 움직인다. 점선 테두리 미리보기와 시간축의 시작 시각 표시가 같이 움직이고, 옆 날짜 칸으로도 옮겨진다. | `tools/dev/check.sh ui -demo -browse-temporal` → 빈 곳 길게 누르고 위아래·옆으로 끌기 |
| `claude/project-thread-3pg436` | 손을 떼면 그 자리에 카드가 남고 키보드와 캘린더 칩이 올라온다. 이름 입력, 칩으로 캘린더 선택, 핸들로 길이 변경 후 완료하면 캘린더에 생긴다. 취소하면 아무것도 생기지 않는다. 핸들을 끄는 동안 시간축에 그 끝의 시각이 보인다. | 위와 같은 실행에서 확인. 실기기에서 손가락이 가리는 정도도 볼 것 |
| (Correlator 구현 후) | 10/9와 같은 7일 실제 데이터 재검증: 원장 반영 금액·건수, 잘못 묶인 짝 0건 | `data/`는 노트북 전용. 분석 도구는 저장소 밖에서 실행 |
