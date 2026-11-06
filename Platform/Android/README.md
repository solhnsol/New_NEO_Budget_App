# Android adapter 경계 — 향후 검토

현재 Android 코드·SDK·Kotlin/KMP·JNI 구현은 없다. 이 디렉터리는 Swift Package target에 포함되지 않는다.

- NotificationListener/: 권한/서비스 생애주기와 OS 알림을 처리하고 중립 RawNotification 입력으로 변환한다. OS 객체나 Android notification key의 의미를 금융 거래 ID로 강제하지 않는다.
- Persistence/: 선택한 로컬 저장소를 Core Repository 계약 뒤에 둔다.
- UI/: 같은 원장/예산 정책의 결과를 표시하고 명령을 전달한다.

Swift Core의 같은 구현을 사용하는 후보 경로는 Swift Android SDK로 공유 라이브러리를 만들고 Java/Kotlin에서 호출하는 방식이다. 실제 cross-build, bridge 타입, 저장소 호출, 패키징/성능은 Android 확장 결정 시 검증한다.

[Swift 공식 Android 시작 안내](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)

OS에 중립적인 소스 구조만으로 Android 실행이 검증되지는 않는다. 같은 소스 재사용을 위한 경계를 마련한 상태이며 지원 완료를 뜻하지 않는다.
