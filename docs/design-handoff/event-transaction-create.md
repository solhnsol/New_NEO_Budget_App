# 일정·거래 만들기 화면 — 시안에 없어서 정한 것 (2026-11-04)

시안: `design-v2/polish/CHANGES.md`(우선), `design-v2/ledger/openend-v1.html`(종료 미정 규칙), `design-v2/polish/create-v11.html`, `palette.html`.
코드: `Support/Design/SheetParts.swift`(부품), `Timeline/EventCreateSheet.swift`, `Timeline/EditingViews.swift`(`NewEventSheet`), `Ledger/ManualTransactionSheet.swift`, `Ledger/TransactionEditSheet.swift`.

## 시안과 다르게 한 것
- **알림·반복 행은 빼요.** 시안(③⑥)에 있지만 캘린더 도메인(`CalendarEventDraft`)에 알림·반복이 없어요. 도메인에 생기면 `EventCreateSheet.rows`에 `SheetRow` 두 줄만 더하면 돼요.
- **함께하는 사람** 행은 create-v11에만 있고 openend-v1에는 없어요. 둘 다 따르려고 장소 아래에 두었고, 눌러서 얼굴 선택(`PeoplePicker`)이 펼쳐져요. 저장하면 일정 생성 뒤에 참가자로 붙어요.
- **종료 지우기**: 종료를 넣은 뒤 되돌리는 방법이 시안에 없어서 값 옆에 작은 x 버튼을 뒀어요(종료 비면 종료 미정).
- 입력창은 시스템 시트가 아니라 화면 위에 직접 그린 패널이에요. 짧은 시스템 시트는 키보드가 올라오면 전체 높이로 커져서 시안(키보드 바로 위에 얹힘)을 낼 수 없어요. `AppModel.creatingEvent` + `RootTabs`의 overlay로 탭바 위에 그려요.
- 제안 "18:00 – 미정"을 누르면 요약 줄의 시작은 회색(openend-v1 ⑥)이고, create-v11처럼 파란색은 끌어서 만든 구간(`NewEventSheet`)에만 써요.

## 거래 추가(시안 없음)
일정 입력창과 같은 부품으로 구성: 제목줄(`내역 추가` + 저장 36) → 종류 세그먼트(지출 / 환불·돌려받음, 32, 흰 바탕 위 #F4F5F7 통 + 선택 #EAF0FD) → 금액 32/700(숫자 키패드, 천 단위 쉼표, 비면 옅은 `0원`) → 행 56: 이름·날짜·시각·분류(메뉴)·메모·태그(눌러서 펼침). 큰 시트, 행 값은 일정 시트와 같은 규칙(값 진함 500, 비었으면 #C6C6CB `추가`/`안 함`). `TransactionEditSheet`(거래 수정)도 같은 행으로 바꿨어요.

## 아직 안 한 것
- 일정 **수정** 화면(`EventActivitySheet`: 유형·장소·누구와·거래 연결)은 그대로예요. 시안이 없고, 일정 제목·시간 수정 진입점도 아직 없어요. 같은 `SheetRow`로 바꾸면 돼요.
- 모션(패널 닫힘, 열림 보간)은 다음 단계. 지금은 열 때 320ms spring, 닫을 때는 즉시.
- 제목 입력의 "18시" 파란 표시는 투명 입력창 아래에 글자를 겹쳐 그려요(한 줄 전용, 길면 말줄임이 입력창과 어긋날 수 있어요).
- 시뮬레이터에서 손으로 눌러 보는 검증은 못 했어요(접근 허용 대기). 화면은 실행 인자로 상태를 만들어 캡처했어요.
