extension IntakeSetup {
    /// Registers the accounts and cards of an import that this setup does not have yet. Their IDs come from the account
    /// names, so importing again adds nothing and never moves a starting balance.
    public mutating func importAccounts(_ plan: ImportPlan) throws {
        for account in plan.accounts where registry.profile(account.binding) == nil {
            let target: NewTargetKind
            let id: String
            switch account.binding {
            case let .account(accountID):
                id = accountID.rawValue
                let opening = try Money(minorUnits: account.openingBalance, currency: ImportPlan.currency)
                target = .account(account.kind == .prepaid ? .prepaid : .bank, openingBalance: opening)
            case let .creditInstrument(instrumentID):
                id = instrumentID.rawValue
                target = .creditInstrument(currency: ImportPlan.currency)
            }
            try addAccount(displayName: account.name, institution: nil, kind: target, makeID: { id })
        }
    }
}
