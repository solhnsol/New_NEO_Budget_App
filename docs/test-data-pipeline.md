# RPi 데이터로 만드는 테스트 자료

운영 action-inbox를 계속 사용하면서 기존/신규 입력의 **형식 커버리지**를 새 Core 테스트에 활용한다. Python 표준 라이브러리만 쓰는 오프라인 개발 도구이며 Swift Core의 실행 의존성이 아니다. 원문이나 가명 처리한 거래 이력을 공개하지 않는다.

## 개인정보 처리 방식과 한계

이름만 지우는 방식으로는 상호, 금액, 잔액, 정확한 시각, 계좌번호, 원본 ID, URL, 메모에서 사용자가 식별될 수 있다. 따라서 원문을 정규식으로 일부 지우는 대신, 허용된 알림 종류와 제한된 형식 변형만 추출한 뒤 **코드에 있는 가상 문자열과 고정 값으로 새 입력을 생성**한다.

- 금융 자료: `actual-budget/ingest/ingest.sqlite`의 `events.json`에서 알려진 type와 boolean/형식 변형만 선택. 알림 원문 `notifications.raw`, 거래 후보, 계좌/상호/이름/금액/잔액/시각/원본 ID/해시를 출력하지 않는다. 같은 형식이 여러 번 관측돼도 샘플은 하나다. 알림 순서와 간격도 보존하지 않는다.
- action-inbox: `entries.kind`, `inbox_items.type`만 허용 목록과 비교하고 가상 입력을 생성. 자유 텍스트, 일정, 장소, LLM 결과, 요청 snapshot/정산/토큰/오류는 가져오지 않는다.
- 출력 ID는 `synthetic-<형식>`이며 실제 전송 ID가 아니다. `sourceDeliveryID`, `notificationAtUnixMilliseconds`, `rawPayload`는 null이다. app/providerHint는 고정된 테스트용 별칭이다.
- 모르는 type, 손상된 JSON은 제외하고 **로컬 보고서에 건수만** 남긴다. unparsed/new 알림 건수도 로컬 보고서에 포함한다. 미래 형식을 자동 학습하거나 외부 LLM에 보내지 않는다.

원본에서 유도한 형식의 존재 여부와 `localReport`의 건수 자체는 운영 정보다. 그러므로 실제 DB에서 만든 결과는 로컬 비공개 자료로 취급한다. 재식별 불가능성을 보장하는 통계적 익명화나 법률 인증을 뜻하지 않는다. Git에 포함되는 공개 fixture는 **DB 접근 없이 전체 가상 카탈로그에서 생성**한다.

이 버전은 실거래 재현, 실제 잔액 연속성, 결제/취소 연결, 거래 중복 판단, 분류 정답, 개인 소비 통계, 모델 학습 corpus를 제공하지 않는다. 기존 파서의 type/본인 여부는 검증된 정답이 아니며 형식 선택 힌트다. `inboxShapes`도 action-inbox API payload가 아니라 입력 종류 목록이다. 이후 수집/파싱 알고리즘에 새 형식을 추가하려면 로컬에서 관측한 실패를 바탕으로 가상 fixture와 기대 결과를 별도로 작성한다. 결정 대기 중인 원장 정책은 이 도구에서 정하지 않는다.

## 수동 실행 (RPi)

저장소 루트에서 실행:

```bash
python3 tools/test_data/export.py \
  --ingest-db /home/jayhanss/actual-budget/ingest/ingest.sqlite \
  --inbox-db /home/jayhanss/action-inbox/data/action_inbox.db \
  --output data/sanitized/dataset.json
```

두 입력 중 하나만 지정할 수도 있다. 기본 생성 폴더 `data/`는 Git에서 제외된다. `.env`, 금융 DB, 개인별 mapping/key는 필요하지 않으며 네트워크 호출도 없다.

`mode=ro`, `query_only`와 짧은 읽기 transaction으로 SQLite WAL까지 읽는다. DB 파일만 복사해서 WAL의 최근 입력을 잃는 방식을 쓰지 않는다. 기존 앱의 ORM을 import하거나 스키마를 바꾸거나 데이터를 삭제/수정하지 않는다. SQLite 읽기 자체는 WAL shared-memory 관리에 참여할 수 있다. 서로 다른 두 DB를 읽는 시점은 독립적이며 하나의 전역 스냅샷을 보장하지 않는다. 오래 걸리면 이전 출력이 유지되도록 service timeout을 둔다.

매 실행은 전체 형식 집합을 다시 계산하므로 새 형식/수정/제외가 다음 성공 실행에 반영된다. 동일 입력은 byte 단위로 동일한 결과다. cursor나 원본 ID 저장이 없고, 건수만 바뀌면 `contentDigest`는 유지된다. 고유 형식 수만큼 출력하므로 이력 전체가 파일에 누적되지 않는다. 이것은 운영 archive의 백업이 아니다.

출력은 임시 파일을 flush/fsync한 후 atomic replace하며 권한은 0600이다. 새 출력 폴더는 0700으로 생성한다. 실패 시 마지막 성공 파일을 유지하고 민감한 예외 내용은 로그에 출력하지 않는다. 원본 DB가 없으면 새 DB를 생성하지 않고 실패한다. 출력은 `.json` 파일이어야 한다.

## 매시간 자동 갱신

RPi 사용자 unit 두 개와 도구 사본을 설치한다. 사본을 사용자 데이터 폴더에 두므로 개발 워크트리를 옮겨도 실행된다. 서비스에 맞는 기존 DB 경로를 먼저 확인한다. 스케줄러 자체는 sudo, 기존 앱 재시작, Docker 변경, 네트워크 권한을 요구하지 않는다.

```bash
sh deploy/test-data/install.sh
systemctl --user status neo-test-data.timer --no-pager
journalctl --user -u neo-test-data.service -n 10 --no-pager
```

설치 시 한 번 실행하고 이후 매시간 + 최대 5분 지연으로 실행한다. `Persistent=true`는 사용자 manager가 돌아올 때 놓친 실행을 보충한다. 저장 위치는 `~/.local/share/neo-test-data/dataset.json`. 초기 실행이 실패하면 timer enable 전에 설치가 중단된다. 서비스 로그와 로컬 건수를 확인해 실패/미지원 형식을 점검한다. 자동 커밋, 자동 푸시, 기존 입력을 삭제하는 기능은 없다.

사용자 manager가 로그아웃 후에도 유지되는지는 호스트 설정에 달려 있다. `loginctl show-user "$USER" -p Linger`로 확인한다. 이 설치 도구는 linger나 시스템 전역 설정을 바꾸지 않는다. 도구 변경을 자동화에 반영하려면 설치 명령을 다시 실행한다.

이번 RPi 설치에서는 별도로 사용자 linger를 활성화하고 `Linger=yes`, timer enabled/active, 첫 service 실행 `Result=success`를 확인했다. 따라서 로그아웃 후에도 사용자 manager가 유지된다. 이 호스트 설정을 되돌릴 때는 다른 사용자 서비스의 필요 여부를 확인한 후 `loginctl disable-linger "$USER"`를 사용한다.

중단/제거:

```bash
systemctl --user disable --now neo-test-data.timer
systemctl --user stop neo-test-data.service
rm ~/.config/systemd/user/neo-test-data.service ~/.config/systemd/user/neo-test-data.timer
systemctl --user daemon-reload
```

로컬 결과와 도구 사본은 제거 후에도 남아 있으며 필요하면 따로 지운다. 운영 DB는 삭제하지 않는다.

## 공개 fixture와 검증

DB를 지정하지 않고 전체 카탈로그를 생성한다. 16종 금융 알림의 본인/상대, 체크/신용, 요금/잔액, 일시불/할부 변형을 포함해 26개다. 합성 값은 balance/amount 관계를 가진 실제 원장 시나리오를 뜻하지 않는다.

```bash
python3 tools/test_data/export.py --synthetic-catalog \
  --output Tests/NEOBudgetCoreTests/Fixtures/synthetic-notification-coverage.json
python3 -m unittest discover -s tests/test_data -v
swift test
```

Windows에서는 같은 Python 3 명령과 기본 `swift test`를 사용한다. Linux 격리 Swift 도구의 우회 옵션은 [개발 환경](development.md)을 따른다.

검증: Python 7개(민감 값 배제, 새 WAL 입력 반영, 반복 실행, 실패 시 보존, 원본 보호, action-inbox 자유 텍스트 배제, 공개 fixture 재생성) 통과. Swift 6.4/Linux 전체 13개 통과. 기존 RPi `notify_parse.js`에서 가상 알림 26개가 모두 해당 type으로 파싱됨을 별도로 확인했다. 기존 파서는 새 저장소 테스트의 실행 의존성이 아니다. Windows 실행은 아직 검증하지 않았다.
