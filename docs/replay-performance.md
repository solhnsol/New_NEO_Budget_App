# Startup replay: cost and how it is kept linear

The ledger is derived. A launch reads every received notification and replays it, in arrival order, through
`NotificationIntake` into `InMemoryCandidateProcessingRepository` (`IntakeLedger.init`). So the replay is the launch time of
the real ledger, and it has to grow in proportion to the number of notifications. It used to grow with the square: 1,000
notifications took about 10 s, 3,000 about 80 s (`records/20261025-저장-확장성-벤치.md`).

Behavior did not change: the policy in `docs/ledger-behavior.md` and the matching rules in `docs/correlator-design.md` are
as they were. This is about how much of the history each step looks at.

## What was quadratic

Every step of one notification read all earlier ones:

| Step | Was | Now |
|---|---|---|
| `InMemoryLedgerRepository.commit` | rebuilt and revalidated the whole ledger for each new entry (and copied the entry array) | validates only the new entry against kept totals (balances, liabilities, monthly sums, adjusted amounts, evidence owners, reversed entries), then applies |
| candidate store `process` | copied the whole candidate map and the ledger to stay atomic, scanned all candidates for evidence owners and dedup collisions | writes in place; indexes by evidence ID and by time |
| correlation (`process(_:observation:...)`) | handed the correlator every stored record, sorted | hands it the records within the correlator's search radius of the incoming time (plus the records that corroborate them), and the same-name purchases for a refund |
| `NotificationIntake.ingest` | took a full snapshot for the revisions, the waiting records and the "same notification again" lookup | asks for revisions, nearby records and the notification's own candidate directly |
| `IntakeLedger` | `receive` rebuilt the set of known IDs; `status(of:)` scanned notifications and built a snapshot (so `inbox()` was N²) | keeps an ID → position table; `status(of:)` reads one candidate |

## Why the narrower reads give the same answer

- Every correlator rule that pairs two notifications compares their times within one of its tolerances, so a record further
  from the incoming one than `NotificationCorrelator.searchRadiusMilliseconds` can never be chosen. The one rule that looks
  further back is the refund suggestion; it is matched by name, so the store keeps purchases indexed by
  `NotificationCorrelator.purchaseNameKey` and passes them separately (`decide(_:nearby:sameNamePurchases:)`).
- `claimed(...)` asks whether a partner already has a corroborating record; the index of corroborators brings those along
  even when they lie outside the time window.
- The dedup validator only collides candidates of the same amount within five minutes, so it is given the candidates whose
  first reading is within that window.
- Choices among equal candidates were already made by time distance then candidate ID, so they do not depend on the order
  records are handed over.

The stored candidates are written in one place (`put`), which keeps the indexes in step with what is stored.

## Atomicity without copying

`process(_:observation:...)` applies a candidate, the candidates it closes and a reversal together or not at all. It used to
work on a copy of the whole repository. It now works in place with an undo trail: the candidate writes are journaled (old
value per key) and the ledger has `checkpoint()` / `rollback(to:)`. A thrown error rolls both back. The undo of the ledger
restores the small totals from the checkpoint and removes the per-entry index rows of the entries it pops.

## Numbers

Synthetic stream: card approvals, a third of them followed by the matching bank withdrawal (`tools/replay-bench`).
x86_64 Linux container, release build; a phone will differ but the shape does not.

| Notifications | Replay before | Replay after |
|---|---|---|
| 1,000 | 9.8 s | 1.2 s |
| 3,000 | about 80 s | 3.5 s |
| 10,000 | about 14 min (extrapolated) | 11 to 13 s |
| 30,000 | about 2 hours (extrapolated) | 40.6 s |
| `status(of:)` per call at 1,000 | 2.3 ms | 0.004 ms |

About 1.2 to 1.4 ms per notification at every size (1.2 s, 3.5 s, 13 s, 40.6 s for 1k, 3k, 10k, 30k). Most of that is parsing (regular expressions), so the next saving would be
persisting the derived ledger instead of replaying it (not done here; the notification file and its format are unchanged).

Run it yourself: `cd tools/replay-bench && swift run -c release ReplayBench 1000 3000 10000`.

## Opening on the recent weeks first

A launch does not wait for the full replay. `IntakeLedger(replayingSince:)` replays only the notifications of the last eight weeks
(`AppLedger.recentWindow`) in their arrival order, and remembers the older ones' IDs (`deferredIDs`) so they are not taken
twice. `AppModel.start()` then calls `AppLedger.completeHistory()`, which builds the full ledger off the actor, replays what
arrived meanwhile onto it, swaps it in and reloads the days on screen. Entry IDs come from the notification, so the recent
entries are the same ones in both. Until the swap, balances and account statements are not shown (they start from zero), a
refund of a purchase older than the window waits, and changes to the setup wait for the full replay. While partial,
`notifications.json` is written as the launch's full list plus the new ones, so nothing older is lost. Design and alternatives
(a persisted snapshot): `records/20261025-단계적-불러오기-설계.md`.
