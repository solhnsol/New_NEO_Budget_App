# 지출 없는 일정은 얇은 카드로 (리스트 보기)

- 범위: `DayListView.swift`의 `EventCard`만. 묶인 거래(`allocations`)와 합계(`allocatedSpend`)가 둘 다 없으면 제목과 시간을 한 줄에 놓고 세로 여백을 `Space.l`에서 `Space.m`으로 줄였어요.
- 지출이 있는 카드는 그대로예요.
- 기준: PR #5 브랜치(claude/project-thread-5ujh6f). 별도 worktree와 별도 시뮬레이터 기기(iPhone 17)로 확인했고, 확인 뒤 기기와 빌드 폴더를 지웠어요.
- 확인: 샘플 데이터(지출 묶인 일정이 없는 날)에서 모든 일정이 얇은 한 줄 카드로 보여요. 지출이 묶인 일정과의 나란한 비교는 샘플에 없어 못 했어요.
