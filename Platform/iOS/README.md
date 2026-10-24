# iOS adapter 경계 — 향후 구현

이 디렉터리는 현재 Swift Package target에 포함되지 않는다. iOS 코드는 아직 없다.

- AppIntents/: 단축어 입력을 Core의 RawNotification으로 변환한다. 명시된 ID와 시각을 전달하고 실제로 없는 금융 거래 시각/provider reference를 만들지 않는다.
- Persistence/: Core의 Repository protocol을 구현한다. SwiftData/Core Data 객체가 Core로 넘어가지 않게 한다.
- UI/: Core의 use case/값을 표시하고 사용자 명령을 전달한다. 원장 계산/중복 정책을 UI에 구현하지 않는다.

의존 방향은 iOS → Core이며 Core → iOS는 금지한다. 현재 파일은 경계 설명이며 iOS 기능 구현이 아니다.
