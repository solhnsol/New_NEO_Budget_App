import Foundation

/// Reads what the notification Shortcut sends (a JSON object, or an array of them) into `RawNotification`s.
///
/// Shapes seen from the Shortcut so far:
/// - `{app, title, subtitle, body, timestamp, assosicated}` (the current one; `assosicated` is the Shortcut's own spelling)
/// - `{app, message, timestamp}` and `{message, timestamp}` (older ones; `message` is read as the body)
///
/// Values are kept as sent, apart from empty strings becoming absent. The Shortcut cannot name a delivery ID, so
/// `sourceDeliveryID` stays nil; the record ID is a digest of what was sent, so the same notification sent twice is one
/// record (`RawNotificationRepository` keeps the first), while two notifications that differ in any field are two.
public struct ShortcutNotificationDecoder: Sendable {
    public enum DecodingError: Error, Equatable, Sendable {
        case notJSON
        case notAnObject
        /// Neither title, subtitle, body nor message has any text.
        case empty
    }

    public static let applicationIdentifierPrefix = "shortcut:"

    /// The zone the Shortcut's local timestamps are read in (the device's).
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// `receivedAtUnixMilliseconds` is when the app got the payload: the capture time.
    public func decode(_ text: String, receivedAtUnixMilliseconds: Int64) throws -> [RawNotification] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw DecodingError.notJSON
        }
        if let objects = value as? [Any] {
            return try objects.map { object in
                guard let fields = object as? [String: Any] else { throw DecodingError.notAnObject }
                return try notification(fields, raw: serialized(fields) ?? text, receivedAt: receivedAtUnixMilliseconds)
            }
        }
        guard let fields = value as? [String: Any] else { throw DecodingError.notAnObject }
        return [try notification(fields, raw: text, receivedAt: receivedAtUnixMilliseconds)]
    }

    private func notification(_ fields: [String: Any], raw: String, receivedAt: Int64) throws -> RawNotification {
        func field(_ key: String) -> String? {
            let found = fields.first { $0.key.lowercased() == key }?.value
            let text: String? = switch found {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let app = field("app")
        let title = field("title")
        let subtitle = field("subtitle")
        let body = field("body") ?? field("message")
        guard title != nil || subtitle != nil || body != nil else { throw DecodingError.empty }
        let stamp = field("timestamp")

        // Without a timestamp nothing tells a resend from a second identical notification, so the receive time is
        // part of the identity and a resend is a new record.
        let identity = [app, title, subtitle, body, stamp ?? "received:\(receivedAt)"]
            .map { value in value.map { "\($0.utf8.count):\($0)" } ?? "-" }
            .joined(separator: "|")
        return RawNotification(
            id: "shortcut-" + SHA256.hex(identity),
            source: NotificationSource(applicationIdentifier: Self.applicationIdentifierPrefix + (app ?? "unknown"), displayName: app),
            capturedAtUnixMilliseconds: receivedAt,
            notificationAtUnixMilliseconds: stamp.flatMap(timestamp),
            title: title,
            subtitle: subtitle,
            body: body,
            rawPayload: raw
        )
    }

    /// The Shortcut's "Current Date" as text. Device-format dates are read in `timeZone`; unreadable text gives nil
    /// (the capture time is used instead), never a guess.
    public func timestamp(_ text: String) -> Int64? {
        let cleaned = text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(cleaned), seconds > 1_000_000_000 {
            // Epoch seconds, or milliseconds when it is too large to be seconds.
            return seconds > 100_000_000_000 ? Int64(seconds) : Int64(seconds * 1_000)
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: cleaned) { return Self.milliseconds(date) }
        }
        let local: [(String, String)] = [
            ("en_US_POSIX", "MMM d, yyyy 'at' h:mm:ss a"),
            ("en_US_POSIX", "MMM d, yyyy 'at' h:mm a"),
            ("en_US_POSIX", "yyyy-MM-dd HH:mm:ss"),
            ("ko_KR", "yyyy. M. d. a h:mm:ss"),
            ("ko_KR", "yyyy년 M월 d일 a h:mm:ss"),
        ]
        for (locale, format) in local {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return Self.milliseconds(date) }
        }
        return nil
    }

    private func serialized(_ fields: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}
