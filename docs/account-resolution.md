# Account Discovery / Resolution

Pure domain logic in `Sources/NEOBudgetCore/Accounts`. No UI, no persistence, no correlator, no transfer pairing.
Designed from analyses of real notifications against final ledger records.

## Three things that are not the same

| Concept | Type | Example |
|---|---|---|
| Who delivered it | `SourceProviderID` (via `ProviderCatalog` aliases) | Toss, Wallet, Kakaopay |
| What kind of message | `NotificationType` | `tossPersonDeposit`, `cardApproval`, `transitFare` |
| What the money moved on | `FinancialInstrumentHint` (institution, `InstrumentKind`, `AccountIdentifier`) | a Woori account, a check card, a credit card |

A Toss message can be about a Woori account, a Hyundai credit card or a Toss Bank account; a Wallet message can be
about any card in it. The app is never the account. `AccountEvidenceExtractor` reads all three plus the other side
(`counterpart`) and text-only observations (balance, an amount in a field the parser does not read).

App display names depend on device language and on how the shortcut names the app, so providers are matched through
aliases (English, Korean, brand, manual). The internal ID is never typed by the user, and no bundle identifier is
assumed: the single shortcut that forwards notifications is unchanged.

## What each provider tells us

| Provider / type | Instrument | Identifier | Kind |
|---|---|---|---|
| Woori `bankTransaction` | Woori account | masked number (`NNNN-NNN-NNN***`), balance | bank account |
| Hyundai `cardApproval` | Hyundai card | card product (`MM`, `체크`) | `MM` credit card, `체크` debit card (settles on a bank account) |
| Toss `tossPayment` | named payment method | card product, or a bank name | per method |
| Toss `tossPersonDeposit` | the bank named in the message | none (bank only) | bank account |
| Toss `tossBankTransfer`/`Interest` | Toss Bank account | none | bank account |
| Kakao `kakaoCharge`/`kakaoSend` | the Kakao Pay wallet | none; the **other** bank + last four digits is the `counterpart` | prepaid wallet |
| Wallet `transitFare` | transit card | none; fare from subtitle, balance from body | transit card |
| Wallet `walletCardTap` | issuer only | none | supplementary, never binds |

A card product is a clue, not a global identifier: it is scoped to its issuer and one target may hold it. A second
card of the same product cannot be told apart and needs a last-four key.

## Decision (`AccountRegistry.resolve`)

1. Unrecognised or supplementary message → **ask**.
2. Institution or instrument kind unknown → **ask**.
3. Strong key (`InstrumentKey` = institution + identifier) present, authoritative, never falls to a rule:
   exactly one active match of the right class → **resolved**; none → **new `AccountCandidate`**;
   several → **ask**; inactive → **ask**; wrong class (a check card on a card liability) → **ask**.
4. No key: a user `SourceRule` scoped by **provider + message types + institution + instrument kind** applies only
   while its target is the only active account that could have produced the message. Otherwise → **ask**.

Ledger semantics are unchanged: a credit card binds to a `CreditInstrument` (liability); a check card, a bank account,
a wallet and a transit card bind to an `Account`.

## When the user must confirm

| Condition | Why | User action |
|---|---|---|
| New strong key | new account or renumbered account | link to existing / confirm as new / dismiss |
| Message names a bank but not the account (Toss deposit) and the bank has 2+ accounts | cannot tell | pick per message |
| No key, no rule (Kakao wallet, Toss Bank, transit card) | no clue in the message | create a rule once for that message type |
| Rule exists but a sibling account exists | same message could be either | pick; rule stays a suggestion |
| Unlisted card product | settlement unknown | register the product |
| Key matches 2+ accounts / inactive account / wrong class | unsafe | resolve the registry |
| Institution unknown / unrecognised message | cannot scope | add alias or pick |
| Counterpart not registered | the other side is often someone else's account | link the key once (never creates a candidate) |

Never auto-promoted: anything that is not `resolved`. `RegistryAccountResolver` maps every non-resolved decision to
`unresolved`.

## Out of scope

Correlator (transfer pairing, refund ↔ original, duplicate notifications across apps), UI, persistence. Counterparts
are resolved to an account when their key is registered, but are not fed to the assembler.
