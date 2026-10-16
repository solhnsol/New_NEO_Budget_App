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
| (Correlator 구현 후) | 10/9와 같은 7일 실제 데이터 재검증: 원장 반영 금액·건수, 잘못 묶인 짝 0건 | `data/`는 노트북 전용. 분석 도구는 저장소 밖에서 실행 |
