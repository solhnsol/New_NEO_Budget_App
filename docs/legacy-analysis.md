# 기존 코드 분석

분석일: 2026-10-05. 새 원격 저장소는 빈 상태였다. 기존 action-inbox, actual-budget/proxy, budget-mcp, calendar-mcp 소스와 테스트를 참고했다. 기존 서비스를 삭제/변경하지 않았다.

## 재사용 범위

여기서 재사용은 제품 규칙·입력 형식·테스트 시나리오의 재사용을 포함한다. 구현 언어를 바꾸면 해당 로직을 새 언어로 옮기고 동등한 결과를 검증해야 한다.

| 기존 파일/기능 | 판정 | 가져올 내용과 바꿀 점 |
|---|---|---|
| actual-budget/proxy/notify_parse.js | 파싱 로직 참고/이식 | NFC, 전각 공백, title/subtitle/body, 우리은행/토스/카카오페이/현대카드/Wallet 형식. provider 확인과 parser 선택을 추가하고 개인 계좌 이름/본인 이름을 외부 설정으로 분리 |
| actual-budget/proxy/notify_match.js | 일부 규칙 이식, 매칭 구조 재설계 | 카드 승인+은행 출금의 동일 거래 연결, 계좌 간 이체, 카드 대금 분리. 금액+수신 시각의 가장 가까운 후보 선택만으로 확정하지 않기 |
| actual-budget/proxy/notify_balance.js | 순수 계산 재사용 후보 | 계좌별 거래 후 잔액 연속성 검사. 누락을 진단하되 확인되지 않은 소비를 자동 생성하지 않기 |
| actual-budget/proxy/pusher.js의 plan | 원장 규칙 참고 | 이체의 출발/도착 두 다리와 합계 불변식. Actual payee/transfer_id/imported_id 형식과 무작위 ID 생성은 새 모델로 대체 |
| actual-budget/proxy/test/notify.test.js | fixture/회귀 시나리오 재사용 | 도착 순서, 체크/신용카드, 이체 양쪽, 미등록 계좌, NFC, 잔액 불연속. 기존 기대 결과가 새 정책에 맞는지 개별 검토 |
| actual-budget/proxy/test/real_sample.json | 검토 후 익명화해서 재사용 | 40개 알림, app/body/id/received_at/subtitle/title 필드. 실거래 금액·잔액·시각·상호·계좌 식별자까지 검토하고 공개 저장소에 원문을 그대로 복사하지 않기 |
| budget-mcp/budget_logic.py의 집계 | 순수 계산 참고 | 수입/지출, 분할, 이체 제외, 예산 잔액. off-budget 이체를 소비로 취급하는 기존 예외는 새 원칙과 다르므로 채택 보류 |
| budget-mcp/budget_logic.py의 예산 | 정책 참고 | 월 배정/예산 이동/이월 계산. 생활비·예비비 이름과 Actual 월별 객체 구조 의존을 제거 |
| budget-mcp/budget_logic.py의 merchant/tag | 정규화 참고 | 원문 상호와 정규화 상호 분리, 알려진 태그. 목적을 상호로 합치지 않기 |
| budget-mcp/budget_logic.py의 정산 | 후속 단계 참고 | 후보 근거와 입금 대조. 이름·합계만으로 수령 확정을 일반화하지 않기 |
| app/timeline.py | 순수 계산 참고 | 소비와 일정 시간 관계, 겹친 일정 배정, 정산을 반영한 소비. 캘린더 이름·교통요금·일 경계 하드코딩 제거 |
| app/settlements.py | 계산 의미 참고 | 1/n과 개인별 부담액 검증. HTTP 호출과 Social 의존 제거 |
| 기존 테스트 전반 | 불변식/사례 참고 | 정확한 잔액, 예산, 수정/되돌리기 검증. 외부 서버 mock 위주의 검사는 Core 계약 테스트로 대체 |

## 실행 의존성에서 제거할 코드

- app/main.py, clients.py, upstream.py, security.py, dashboard.py의 HTTP 서버·공용 토큰·원격 조회·서버 캐시.
- FastAPI/SQLAlchemy Session에 직접 연결된 crud/entries/requests_flow: 입력 상태와 수정 이력 아이디어는 참고하되 새 Repository 계약으로 작성.
- actual-budget/proxy/index.js의 Express와 Actual 전역 초기화, pusher.js의 Actual 쓰기 및 payee 정리.
- shadow.js의 better-sqlite3 구체 구현과 Actual 동기화 상태: 상태 전이와 원본 보관 개념은 유지, 저장소 호출은 추상화.
- LLM HTTP 호출·API 키·개인 서비스 환경 변수. 기본 파싱/원장/예산 처리에서 온라인 호출 제거.
- Docker/Tailscale/cron/상시 서버 worker, Scriptable와 현재 웹 UI는 새 Core 실행 경로에 포함하지 않음.

## 그대로 옮기지 않을 정책

1. 카카오페이 충전 뒤 송금 알림이 없으면 잔액 전부를 소비로 추정: 진단/확인 후보로만 다룰 것을 제안.
2. 수락 요청 알림을 이미 받은 돈으로 처리: pending 상태를 표현하고 실제 수락/입금 근거와 구분할 것을 제안.
3. 같은 금액·가까운 수신 시각만으로 알림 연결: 반복 결제/반복 이체를 구분하는 원거래 ID·실제 시각·잔액·계좌·provider 증거가 필요.
4. 미확인 취소를 일반 수입으로 반영: 원승인 연결과 누적 취소 금액 검증이 필요. 현재 취소 후보는 unresolved다.
5. 거래 후보를 전부 다시 계산한 뒤 반영된 후보를 동결: 늦게 온 근거를 기존 거래에 붙일 수 있도록 evidence와 ledger identity를 분리.
6. 입력 hash가 같으면 같은 거래라고 가정: 전송 중복과 금융 거래 중복/관련 알림을 각각 판정해야 함.

이 정책 변경은 제안이다. 사용자와 구체적 예시를 검토해 decisions.md에서 합의 후 구현한다.

## 확인한 검증 범위

현재 실행 환경은 Linux/Node 20이다. 기존 notify.test.js를 직접 실행한 결과 48개 중 46개 통과, 2개 skipped, 실패 0개였다. skipped는 SQLite 모듈이 필요한 수동 해결/불연속 확인 테스트다. 새 Core나 Windows의 검증 결과로 간주하지 않는다.
