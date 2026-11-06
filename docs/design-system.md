# OnAll 디자인 원칙

토스·당근·배민처럼 한국 사용자에게 익숙한 앱의 원칙을 OnAll에 맞게 정리한 것. 값은 `Platform/iOS/OnAllApp/OnAllApp/Support/Design/Theme.swift` 한 곳에만 있고, 화면은 `Components.swift`·`People.swift`의 부품으로 만든다. 화면 코드에서 색·글꼴·모서리를 직접 정하지 않는다.

## 원칙

1. **회색 바탕 위 흰 카드.** 한 카드는 한 주제만 담는다. 목록형 화면(소비 목록, 계좌 내역)은 흰 바탕에 구분선 없이 여백으로 나눈다.
2. **가장 중요한 숫자가 가장 크다.** 결제한 금액, 거래 금액은 `AmountHero`/`Theme.Typo.hero`로 크게, 그 위 설명은 작은 회색 글씨로.
3. **강조색은 파랑 하나.** 누를 수 있는 것, 고른 것, 쓴 돈(행 금액)은 파랑. 들어온 돈(실제 수입)만 빨강(`income`). 정산으로 돌려받은 돈은 수입이 아니라 원래 지출에 붙는다. 글자(행 제목 등)는 기본색, 텍스트 버튼만 강조색. 경고색(`danger`)은 되돌릴 수 없는 동작에만. 기다리는 상태는 캘린더 주황 배지.
4. **화면의 주된 동작은 아래쪽 큰 버튼 하나.** `primaryActionBar`로 엄지가 닿는 곳에 고정한다. 보조 동작은 회색 타일 버튼(`.onAllSecondary`).
5. **사람은 얼굴(동그라미)로.** 이름이 든 색 동그라미(`PersonAvatar`), 한국 이름은 이름 두 글자(`김민수` → `민수`). 같은 사람은 어디서나 같은 색. 사람 고르기는 어디서나 `PeoplePicker` 한 가지.
6. **해요체, 짧게, 무엇이 일어나는지.** "저장하지 못했습니다" 대신 "저장하지 못했어요", "정산 요청을 만들어요". 시스템 용어보다 사용자의 말.

## 토큰 (2026-11-03 design-v2 기준, 값은 `Theme.swift`)

팔레트 출처 `design-v2/ledger/palette.html`, 크기 표 `design-v2/polish/CHANGES.md`. 팔레트 밖 색은 쓰지 않는다(레일 #E5E8EB·키보드 #D2D5DB는 미결 → 우선 `divider`).

| 이름 | 라이트 | 쓰임 |
|---|---|---|
| `accent` / `accentStrong` / `accentSoft` / `accentLine` | #3D6FE0 / #2B54B8 / #EAF0FD / #C9D8F8 | 버튼·쓴 돈 / 옅은 바탕 위 글자 / 오늘·선택 바탕 / 선택 테두리 |
| `income` / `incomeSoft` | #C65B62 / #FBEEEF | 실제 수입 |
| `danger` / `dangerStrong` / `dangerSoft` | #E5484D / #C93A3F / #FDECEC | 삭제 |
| `actionBar` / `actionBarDelete` | #3E4C63 / #FFC9CB | 선택 모드 하단 바 |
| `background` / `surface` / `fill` / `divider` / `disabled` | #F4F5F7 / #FFFFFF / #F4F5F7 / #EEF0F2 / #C6C6CB | 바탕·카드·눌림·선·꺼진 토글 |
| `textPrimary/Secondary/Tertiary` | #191F28 / #4E5968 / #8B95A1 | 본문 / 보조 / 옅음 |
| `CalendarTint` | 6색, `soft` = 9% | 캘린더 색, 일정 카드·분류 타일 바탕 |

크기: 카드 반경 16·여백 16, 시트 반경 24, 버튼 52/반경 14(작은 36/12), 칩 32/반경 16, 세그먼트 32, 터치 44, 설정 행 52. 글자 h1 26, 화면 하위 제목 20, 섹션 18, 행 제목 16 medium, 보조 13, 금액 16 medium tabular, 캡션 최소 11, 큰 숫자 32. 다크 값은 시안에 없어 파생값이다. Pretendard는 아직 번들하지 않았고 시스템 글꼴을 쓴다(글꼴 번들은 별도 작업).

## 모션 (`Theme.Motion`)

눌림 120ms(행·카드 배경 `fill`, 버튼 불투명도 0.85) · 시트 열림 320ms spring(감쇠 0.85)+스크림 200ms · 선택 진입 길게 누름 0.35s+햅틱 medium, 선택 박스 150ms, 작업 바 240ms spring · 날짜 전환 220ms 슬라이드+페이드 · 월 격자 펼침 280ms spring · 새 일정 끌기 15분 스냅마다 가벼운 햅틱, 놓으면 100ms 정착 · 위젯 편집 들기 scale 1.02+그림자, 재배치 240ms spring, 삭제 배지 150ms. Reduce Motion이면 spring은 200ms ease, 슬라이드는 페이드(`Theme.Motion.resolved`).

## 접근성 메모

Dynamic Type: 시안 크기를 고정값으로 썼다(`Font.system(size:)`). 접근성 작업 때 `@ScaledMetric`/text style로 바꾼다.
