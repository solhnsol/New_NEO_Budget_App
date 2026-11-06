# 플랫폼 경계 점검과 최소 리팩터링

사용자 요청: Swift Core 유지, Android 확장을 어렵게 만드는 결합을 최소화. Android 앱/KMP/실제 iOS adapter는 현재 구현하지 않는다.

## 변경 전 판단

| 구분 | 실제 상태 | 조치 |
|---|---|---|
| 이미 중립적인 부분 | Package에 Apple platform 제한 없음, 외부 런타임 패키지 없음, 정규화는 입력만으로 계산, Core 테스트는 Swift Testing | 유지 |
| 불필요한 Apple 결합 | SwiftUI/UIKit/SwiftData/AppIntents/EventKit 의존성 없음 | 제거할 코드 없음 |
| 지금 분리할 부분 | 정규화가 Domain에 있고 중립 입력/저장 protocol이 아직 없음 | Parsing 이동, RawNotification 값, 원본 저장 protocol과 별도 in-memory target |
| 지금 건드리지 않을 부분 | Foundation의 NFC/문자열 정규화, 미구현 원장/예산/정산, UI/OS integration | Foundation 유지, 금융 정책 범위 확장 없이 기존 계획 유지 |

Foundation은 Apple 전용 UI/저장 framework와 구분한다. 현재 사용한 문자열 기능은 Linux에서 실제 테스트했다. 다른 플랫폼 전체 기능의 동일 동작은 각 도구 환경에서 검증할 필요가 있다.

## 적용한 경계

```text
Sources/
  NEOBudgetCore/
    Domain/RawNotification.swift
    Parsing/NotificationText.swift
    Storage/RawNotificationRepository.swift
  NEOBudgetInMemoryStorage/
    InMemoryRawNotificationRepository.swift
Platform/
  iOS/README.md
  Android/README.md
Tests/
  NEOBudgetCoreTests/
    Fixtures/raw-notifications.json
```

Swift Package 관례를 유지해 Sources 아래 Core/Infrastructure를 별도 target으로 나눴다. Core target은 Infrastructure나 Platform을 import하지 않는다. in-memory target이 Core를 의존하며, Platform 디렉터리는 현재 빌드하지 않는다. 미구현 Ledger/Budget/Settlement에 빈 target나 가짜 엔진을 만들지 않았다.

## RawNotification 계약

- 알림 원본 record ID, source app identifier, 선택적 provider hint/delivery ID, 명시적 epoch milliseconds, 선택적 제목/부제목/본문/원문 payload.
- OS enum/object, Date.now, 자동 UUID, DB entity를 포함하지 않는다. Codable/Equatable/Sendable 값이며 adapter가 입력을 제공한다.
- providerHint는 힌트이고 검증된 계좌/은행 판정이 아니다. 앱 identifier가 OS별로 다를 수 있으므로 미래 provider alias 설정에서 해소한다.
- 원본 notification time과 adapter capture time을 구분하며 이를 금융 거래의 실제 시각으로 자동 확정하지 않는다.
- 원본 payload는 정규화 없이 보관한다. 파싱용 텍스트는 새 값으로 생성한다.
- 전달 ID가 없는 경우 nil로 둔다. OS notification key가 항상 재전송 식별자 또는 은행 원거래 번호라는 가정을 두지 않는다.

## 저장 계약

insert는 원본 record ID 단위로 원자적이다. 같은 ID와 정확히 같은 기록의 재삽입은 alreadyStored이고, 내용이 바뀌면 원본을 덮어쓰지 않고 충돌을 반환한다. 다른 record ID의 유사 내용은 별도 보존한다.

이 계약은 금융 거래 dedup 엔진이 아니다. 동일 delivery ID를 가진 다른 record ID의 관계, capture time이 달라진 재전송, 은행/페이의 동일 결제 연결은 Deduplication 계층에서 처리할 후속 작업이다. 이런 사례를 텍스트 정규화나 저장소에서 몰래 합치지 않는다.

현재 in-memory 구현은 비영구 저장소이며 호출 직렬화가 필요하다. 앱 재실행 복원/프로세스 간 쓰기/DB durability를 검증했다고 주장하지 않는다. 전체 원장 atomic-write와 revision 계약은 원장 구현 시 추가한다.

## 검증

기존 정규화 6개와 새 boundary/fixture/Repository 계약 6개, 총 12개 Linux에서 통과. 새 검사는 서로 다른 adapter 입력의 동일 텍스트 처리, JSON 왕복과 원문 보존, 없는 식별자 유지, 재삽입, 충돌 시 원본 유지, 유사 원본 별도 보관을 검증한다.

fixtures는 합성 데이터다. 실제 단축어/Android listener 실행, provider parser, 금융 거래 dedup, Android/iOS/Windows 빌드 성공을 뜻하지 않는다.

## Android 재사용의 실제 범위

정책과 모델을 OS API로부터 분리해 같은 Swift 엔진을 재사용할 수 있는 경로를 열어 둔다. Swift 공식 Android SDK와 Java/Kotlin 연동 경로는 존재하지만, Android bridge/컴파일/런타임/패키징을 실제 검증해야 같은 코드를 재사용한다고 확정할 수 있다.

지금은 Kotlin/KMP 전환, JNI 공개 ABI, 만능 Platform interface, iOS 전용 코드의 조건부 import, Android SDK 설치를 하지 않는다. 외부 입력→값 모델, 저장 protocol, 단방향 target 의존성에만 경계를 둔다.

[공식 Swift Android SDK 안내](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
