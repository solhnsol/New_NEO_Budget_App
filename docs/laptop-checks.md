# 노트북 확인 목록

클라우드에서는 Swift 패키지 테스트(`swift test`)만 돌린다. Xcode·시뮬레이터·실기기가 필요한 확인은 여기에 쌓아 두고, 노트북이 연결될 때 한 번에 실행한다. 확인한 항목은 결과와 함께 지운다.

## 공통

```zsh
git fetch origin && git checkout claude/project-thread-hstee5
tools/dev/check.sh full
```

## 대기 중

(없음)

## 확인 완료 (2026-10-16, 노트북)

- `claude/project-thread-hstee5` `tools/dev/check.sh full`: 패키지 582개, 앱 499개 통과.
- `claude/project-thread-hstee5` 고정 그리드 "무엇을 선택할까요?": 데모 16일 "배달"(저녁 운동과 겹침)에서 거래를 고르면 상세 시트가, 일정을 고르면 편집 세션(핸들, 취소/완료 막대)이 열린다.
- 7일 실제 데이터 재검증: 결과는 `docs/correlator-design.md` 6절 5번.
