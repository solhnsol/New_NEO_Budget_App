import Foundation

/// 틀(`₩{금액} for {가맹점}`)을 정규식으로 바꾼다. 고정 글자는 그대로, 공백은 아무 공백 하나 이상,
/// `{칸 이름}`은 그 칸의 글자 모양, `{*}`는 아무 글자, `{re:…}`는 공식 항목이 쓰는 정규식 그대로.
struct ReadingFrame {
    let regex: NSRegularExpression
    /// 정규식 그룹 이름 → 칸.
    let slots: [String: ReadingSlot]

    init?(_ frame: String, anchored: Bool) {
        var pattern = anchored ? "^" : ""
        var slots: [String: ReadingSlot] = [:]
        var chars = Array(frame)
        var index = 0
        var literal = ""
        func flush() {
            guard !literal.isEmpty else { return }
            var out = ""
            var inSpace = false
            for ch in literal {
                if ch.isWhitespace {
                    if !inSpace { out += #"\s+"# }
                    inSpace = true
                } else {
                    out += NSRegularExpression.escapedPattern(for: String(ch))
                    inSpace = false
                }
            }
            pattern += out
            literal = ""
        }
        while index < chars.count {
            let ch = chars[index]
            guard ch == "{" else { literal.append(ch); index += 1; continue }
            // 닫는 괄호까지(정규식 안의 중괄호는 짝을 맞춘다).
            var depth = 0
            var end = index
            while end < chars.count {
                if chars[end] == "{" { depth += 1 } else if chars[end] == "}" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard end < chars.count else { return nil }
            let inner = String(chars[(index + 1)..<end])
            flush()
            if inner == "*" {
                pattern += #"[\s\S]*?"#
            } else if inner.hasPrefix("re:") {
                pattern += String(inner.dropFirst(3))
            } else if let slot = ReadingSlot(rawValue: inner) {
                let key = "s\(slots.count)"
                slots[key] = slot
                pattern += "(?<\(key)>\(slot.pattern))"
            } else {
                return nil
            }
            index = end + 1
        }
        flush()
        if anchored { pattern += "$" }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.regex = regex
        self.slots = slots
        chars.removeAll()
    }

    /// 틀이 글에 맞으면 칸별로 읽은 값(앞뒤 공백 제거).
    func match(in text: String) -> [ReadingSlot: String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        var values: [ReadingSlot: String] = [:]
        for (key, slot) in slots {
            let r = m.range(withName: key)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                values[slot] = String(text[swiftRange]).trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }

    /// 고정 글자 수(구체성 계산용). 칸·`{*}`는 세지 않는다.
    static func literalCount(_ frame: String) -> Int {
        var count = 0
        var depth = 0
        for ch in frame {
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) } else if depth == 0, !ch.isWhitespace { count += 1 }
        }
        return count
    }
}
