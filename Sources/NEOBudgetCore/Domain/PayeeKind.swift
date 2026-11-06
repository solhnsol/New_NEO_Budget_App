/// Whether a transaction's other side is a private person or a business. Automatic categories and tags must never be put on a person's
/// transfer: the same name can be a split meal, a gift, or rent from one month to the next.
public enum PayeeKind: String, Sendable {
    case person, merchant

    /// Conservative on purpose: a transfer-like event whose name is 2–4 Hangul letters (a `*` may mask one) is a person.
    /// shortcut: no check of the sending channel (Toss, Kakao, bank name); the event kind is the stronger signal. Add it if businesses with
    /// 2–4 letter names turn up in transfers.
    public static func classify(_ draft: TransactionCandidateDraft) -> PayeeKind {
        switch draft.kind {
        case .transferOut, .transferIn, .withdrawal, .deposit: break
        default: return .merchant
        }
        let names = [draft.counterparty.payeeRaw, draft.counterparty.merchantRaw, draft.counterparty.memoRaw]
        return names.contains { $0.map(isPersonName) ?? false } ? .person : .merchant
    }

    static func isPersonName(_ raw: String) -> Bool {
        let name = raw.filter { !$0.isWhitespace }
        guard (2...4).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "*" || (0xAC00...0xD7A3).contains($0.value) }
    }
}

/// Where an automatic category may be put. User-made rules are not held to this (they only get a warning); suggestions and any future
/// classifier are.
public enum CategoryEvidencePolicy {
    /// Money coming in is never auto-categorized, and neither is a person's transfer.
    public static func canAutoCategorize(_ draft: TransactionCandidateDraft) -> Bool {
        draft.direction != .inflow && PayeeKind.classify(draft) == .merchant
    }

    /// Transit only for a transit card or a known transit operator. A place name alone (`안국역점`) proves nothing.
    public static func canSuggestTransit(_ draft: TransactionCandidateDraft) -> Bool {
        guard canAutoCategorize(draft) else { return false }
        if draft.instrument.kind == .transitCard { return true }
        let names = [draft.counterparty.merchantRaw, draft.counterparty.payeeRaw].compactMap { $0 }
        return names.contains { name in transitBrands.contains { name.contains($0) } }
    }

    /// shortcut: starting list; Hans may extend it in settings later.
    static let transitBrands = ["티머니", "T-money", "Tmoney", "캐시비", "코레일", "KORAIL", "SRT", "카카오T", "타다", "우티", "UT택시", "서울교통공사"]
}
