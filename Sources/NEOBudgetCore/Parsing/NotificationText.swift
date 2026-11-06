import Foundation

/// Text normalization only; it does not identify or merge financial transactions.
/// Original notification payloads must be retained separately.
public enum NotificationText {
    public static func joined(_ notification: RawNotification) -> String {
        joined(title: notification.title, subtitle: notification.subtitle, body: notification.body)
    }

    public static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func joined(title: String?, subtitle: String?, body: String?) -> String {
        [title, subtitle, body]
            .compactMap { $0 }
            .map(normalize)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
