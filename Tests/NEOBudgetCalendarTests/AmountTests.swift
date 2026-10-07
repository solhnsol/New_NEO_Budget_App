import Foundation
import Testing
import NEOBudgetCalendar
import NEOBudgetCore

// MARK: Knowledge levels

@Test func everyKnowledgeLevelValidatesItsOwnShape() throws {
    #expect(throws: AmountValidationError.nonPositiveAmount) { try AmountKnowledge.exact(0).validate() }
    #expect(throws: AmountValidationError.nonPositiveAmount) { try AmountKnowledge.estimated(-5).validate() }
    #expect(throws: AmountValidationError.nonPositiveAmount) { try inferred(0).validate() }
    #expect(throws: AmountValidationError.invalidRange) { try AmountRange(minMinorUnits: 10, maxMinorUnits: 5) }
    #expect(throws: AmountValidationError.invalidRange) { try AmountRange(minMinorUnits: -1, maxMinorUnits: 5) }
    #expect(throws: (any Error).self) { try AmountEntry(currency: "krw", knowledge: .unknown, provenance: userProvenance()) }
    #expect(throws: AmountValidationError.nonPositiveAmount) { try AmountEntry(currency: "KRW", knowledge: .exact(0), provenance: userProvenance()) }
    try AmountKnowledge.unknown.validate()
    try amountRange(0, 0).validate()
}

@Test func onlyExactAndInferredAreSettledAndTheyAreNeverTheSame() {
    #expect(AmountKnowledge.exact(7_000).knownValue == 7_000)
    #expect(inferred(7_000).knownValue == 7_000)
    #expect(AmountKnowledge.estimated(7_000).knownValue == nil)
    #expect(AmountKnowledge.unknown.knownValue == nil)
    #expect(amountRange(1, 2).knownValue == nil)
    #expect(AmountKnowledge.exact(7_000) != inferred(7_000))                  // an inference is not a confirmation
    #expect(AmountKnowledge.exact(7_000).rank > inferred(7_000).rank)
    let ranks = [AmountKnowledge.unknown, amountRange(1, 9), .estimated(5), inferred(5), .exact(5)].map(\.rank)
    #expect(ranks == ranks.sorted() && Set(ranks).count == 5)
}

@Test func boundsContainOnlyHardKnowledge() {
    #expect(AmountKnowledge.unknown.bounds == AmountBounds(lower: 0, upper: nil))
    #expect(AmountKnowledge.estimated(9_000).bounds == AmountBounds(lower: 0, upper: nil))   // an estimate bounds nothing
    #expect(amountRange(100, 200).bounds == AmountBounds(lower: 100, upper: 200))
    #expect(AmountKnowledge.exact(50).bounds == AmountBounds(lower: 50, upper: 50))
    #expect(inferred(50).bounds == AmountBounds(lower: 50, upper: 50))
    #expect(AmountBounds(lower: 5, upper: nil).contains(1_000_000) && !AmountBounds(lower: 5, upper: nil).contains(4))
}

@Test func knowledgeRoundTripsThroughCodable() throws {
    let samples: [AmountKnowledge] = [.unknown, amountRange(10, 20), .estimated(15), inferred(15, summary: "why"), .exact(15)]
    for sample in samples {
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(AmountKnowledge.self, from: data) == sample)
    }
    let value = entry(inferred(12_000), provenance: autoProvenance(1.0))
    #expect(try JSONDecoder().decode(AmountEntry.self, from: JSONEncoder().encode(value)) == value)
    let bad = Data(#"{"currency":"KRW","knowledge":{"exact":{"_0":-5}},"provenance":{"source":"user","assignedAtUnixMilliseconds":1}}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(AmountEntry.self, from: bad) }
}

// MARK: Update policy — user decisions are protected, automation only refines

@Test func aUserMayAlwaysSetAnyLevelOfKnowledge() {
    let old = entry(.exact(10_000))
    for knowledge in [AmountKnowledge.unknown, amountRange(1, 5), .estimated(3), inferred(4), .exact(20_000)] {
        #expect(AmountUpdatePolicy.evaluate(old: old, new: entry(knowledge)) == .accept)
    }
}

@Test func automationNeverOverwritesAUserConfirmedExactAmount() {
    let userExact = entry(.exact(12_000))
    let auto = { (knowledge: AmountKnowledge) in entry(knowledge, provenance: autoProvenance(1.0)) }
    #expect(AmountUpdatePolicy.evaluate(old: userExact, new: auto(inferred(12_000))) == .rejectedProtectedUserAmount)   // even the same value, as inferred
    #expect(AmountUpdatePolicy.evaluate(old: userExact, new: auto(.exact(13_000))) == .rejectedProtectedUserAmount)
    #expect(AmountUpdatePolicy.evaluate(old: userExact, new: auto(.unknown)) == .rejectedProtectedUserAmount)
    #expect(AmountUpdatePolicy.evaluate(old: userExact, new: userExact) == .accept)                                      // identical is fine
}

@Test func automationCannotWeakenWhatIsKnown() {
    let auto = { (knowledge: AmountKnowledge) in entry(knowledge, provenance: autoProvenance(1.0)) }
    #expect(AmountUpdatePolicy.evaluate(old: entry(inferred(5_000), provenance: autoProvenance(1.0)), new: auto(.unknown)) == .rejectedWeakening)
    #expect(AmountUpdatePolicy.evaluate(old: entry(inferred(5_000), provenance: autoProvenance(1.0)), new: auto(.estimated(5_000))) == .rejectedWeakening)
    #expect(AmountUpdatePolicy.evaluate(old: entry(.estimated(5_000)), new: auto(amountRange(1, 9_000))) == .rejectedWeakening)
    #expect(AmountUpdatePolicy.evaluate(old: entry(amountRange(1, 9_000)), new: auto(.unknown)) == .rejectedWeakening)
}

@Test func automationMayNarrowARangeButNeverWidenIt() {
    let old = entry(amountRange(10_000, 20_000))
    let auto = { (min: Int64, max: Int64) in entry(amountRange(min, max), provenance: autoProvenance(1.0)) }
    #expect(AmountUpdatePolicy.evaluate(old: old, new: auto(12_000, 15_000)) == .accept)
    #expect(AmountUpdatePolicy.evaluate(old: old, new: auto(10_000, 20_000)) == .accept)
    #expect(AmountUpdatePolicy.evaluate(old: old, new: auto(5_000, 20_000)) == .rejectedInconsistent)
    #expect(AmountUpdatePolicy.evaluate(old: old, new: auto(10_000, 25_000)) == .rejectedInconsistent)
}

@Test func automationMayPromoteUnknownKnowledgeButOnlyConsistently() {
    let auto = { (knowledge: AmountKnowledge) in entry(knowledge, provenance: autoProvenance(1.0)) }
    #expect(AmountUpdatePolicy.evaluate(old: entry(.unknown), new: auto(inferred(12_000))) == .accept)
    #expect(AmountUpdatePolicy.evaluate(old: entry(.estimated(9_000)), new: auto(inferred(12_000))) == .accept)   // an estimate is soft
    #expect(AmountUpdatePolicy.evaluate(old: entry(amountRange(10_000, 15_000)), new: auto(inferred(12_000))) == .accept)
    #expect(AmountUpdatePolicy.evaluate(old: entry(amountRange(10_000, 15_000)), new: auto(inferred(20_000))) == .rejectedInconsistent)
    #expect(AmountUpdatePolicy.evaluate(old: entry(.unknown), new: auto(.exact(12_000))) == .accept)             // observed directly
}

@Test func twoDifferentAutomatedConclusionsAreNeverSilentlyResolved() {
    let first = entry(inferred(12_000), provenance: autoProvenance(1.0))
    #expect(AmountUpdatePolicy.evaluate(old: first, new: entry(inferred(13_000), provenance: autoProvenance(1.0))) == .rejectedInconsistent)
    #expect(AmountUpdatePolicy.evaluate(old: entry(.estimated(5), provenance: autoProvenance(0.9)), new: entry(.estimated(6), provenance: autoProvenance(0.9))) == .rejectedInconsistent)
    let observed = entry(.exact(5_000), provenance: autoProvenance(1.0))
    #expect(AmountUpdatePolicy.evaluate(old: observed, new: entry(.exact(6_000), provenance: autoProvenance(1.0))) == .rejectedInconsistent)
}

@Test func currencyMustMatch() {
    #expect(AmountUpdatePolicy.evaluate(old: entry(.unknown), new: entry(.exact(5), currency: "USD")) == .rejectedCurrencyMismatch)
}

// MARK: Aggregation keeps uncertainty

@Test func aggregatesKeepExactInferredAndEstimatedApart() {
    let totals = AmountAggregate.summarize([
        ("KRW", .exact(10_000)), ("KRW", inferred(6_000)), ("KRW", .estimated(4_000)), ("KRW", .unknown)
    ])
    #expect(totals.count == 1)
    let total = totals[0]
    #expect(total.exactMinorUnits == 10_000 && total.inferredMinorUnits == 6_000 && total.estimatedMinorUnits == 4_000)
    #expect(total.knownMinorUnits == 16_000)
    #expect(total.lowerBoundMinorUnits == 16_000)              // only hard knowledge counts toward the floor
    #expect(total.upperBoundMinorUnits == nil)                 // an unknown or estimated part has no ceiling
    #expect(total.unresolvedCount == 2 && total.componentCount == 4 && !total.isFullyKnown)
}

@Test func rangesProduceALowerAndUpperBoundInsteadOfAFalseTotal() {
    // 외식 120,000 ~ 130,000 and 카페 42,000 ~ 49,000
    let total = AmountAggregate.summarize([("KRW", amountRange(120_000, 130_000)), ("KRW", amountRange(42_000, 49_000))])[0]
    #expect(total.lowerBoundMinorUnits == 162_000)
    #expect(total.upperBoundMinorUnits == 179_000)
    #expect(total.unresolvedCount == 2 && total.exactMinorUnits == 0)
    let mixed = AmountAggregate.summarize([("KRW", .exact(5_000)), ("KRW", amountRange(1_000, 3_000))])[0]
    #expect(mixed.lowerBoundMinorUnits == 6_000 && mixed.upperBoundMinorUnits == 8_000)
}

@Test func fullyKnownComponentsGiveAnExactBoundedTotal() {
    let total = AmountAggregate.summarize([("KRW", .exact(1_000)), ("KRW", inferred(2_000))])[0]
    #expect(total.isFullyKnown && total.lowerBoundMinorUnits == 3_000 && total.upperBoundMinorUnits == 3_000)
}

@Test func aggregatesNeverMixCurrenciesAndAreOrdered() {
    let totals = AmountAggregate.summarize([("USD", .exact(100)), ("KRW", .exact(5_000)), ("USD", .exact(50))])
    #expect(totals.map(\.currency) == ["KRW", "USD"])
    #expect(totals[1].exactMinorUnits == 150)
    #expect(AmountAggregate.summarize([]).isEmpty)
}

// MARK: Group constraints

private let members3 = [AmountMemberRef.obligation(oid("lunch")), .obligation(oid("cafe")), .obligation(oid("taxi"))]

@Test func aGroupNeedsSeveralMembersAndASettledTotal() throws {
    let total = entry(.exact(31_000))
    #expect(throws: AmountGroupError.tooFewMembers) { try AmountGroup(id: AmountGroupID(rawValue: "g"), total: total, members: [members3[0]], createdAtUnixMilliseconds: 1) }
    #expect(throws: AmountGroupError.duplicateMember(members3[0])) {
        try AmountGroup(id: AmountGroupID(rawValue: "g"), total: total, members: [members3[0], members3[0]], createdAtUnixMilliseconds: 1)
    }
    for unsettled in [AmountKnowledge.unknown, .estimated(31_000), amountRange(30_000, 32_000)] {
        #expect(throws: AmountGroupError.totalNotKnown) {
            try AmountGroup(id: AmountGroupID(rawValue: "g"), total: entry(unsettled), members: members3, createdAtUnixMilliseconds: 1)
        }
    }
    let group = try AmountGroup(id: AmountGroupID(rawValue: "g"), total: entry(inferred(31_000)), members: members3.reversed(), createdAtUnixMilliseconds: 1)
    #expect(group.totalMinorUnits == 31_000 && group.members == members3.sorted())
    #expect(try JSONDecoder().decode(AmountGroup.self, from: JSONEncoder().encode(group)) == group)
}

private func analyze(_ total: Int64, _ knowledge: [AmountKnowledge]) -> AmountGroupAnalysis {
    let refs = members3.prefix(knowledge.count)
    return AmountGroupSolver.analyze(totalMinorUnits: total, members: Dictionary(uniqueKeysWithValues: zip(refs, knowledge).map { ($0, $1) }))
}

@Test func theSumIsPreservedInsteadOfSplittingUnknownMembersArbitrarily() {
    // 정산 총액 31,000 = 점심 + 카페 + 택시, none known.
    guard case let .underdetermined(group) = analyze(31_000, [.unknown, .unknown, .unknown]) else {
        Issue.record("expected underdetermined")
        return
    }
    #expect(group.remainingMinorUnits == 31_000)
    #expect(group.unresolved == members3.sorted())
    for member in members3 {
        #expect(group.narrowed[member] == AmountBounds(lower: 1, upper: 30_998))   // each is positive; nothing else is forced
    }
}

@Test func knownRangesNarrowTheOthersThroughTheConstraint() {
    guard case let .underdetermined(group) = analyze(31_000, [amountRange(10_000, 20_000), .unknown, .unknown]) else {
        Issue.record("expected underdetermined")
        return
    }
    #expect(group.narrowed[members3[0]] == AmountBounds(lower: 10_000, upper: 20_000))
    #expect(group.narrowed[members3[1]] == AmountBounds(lower: 1, upper: 20_999))     // 31,000 - 10,000 - 1
    #expect(group.narrowed[members3[2]] == AmountBounds(lower: 1, upper: 20_999))
}

@Test func boundedMembersCanForceEachOthersLowerLimits() {
    guard case let .underdetermined(group) = analyze(31_000, [amountRange(1, 10_000), amountRange(1, 10_000), amountRange(1, 20_000)]) else {
        Issue.record("expected underdetermined")
        return
    }
    #expect(group.narrowed[members3[2]]?.lower == 11_000)       // the other two can supply at most 20,000
    #expect(group.narrowed[members3[0]]?.lower == 1_000)        // 31,000 - 10,000 - 20,000
}

@Test func exactlyOneUnresolvedMemberIsForced() {
    #expect(analyze(31_000, [.exact(12_000), .exact(7_000), .unknown]) == .uniqueSolution(member: members3[2], minorUnits: 12_000))
    #expect(analyze(31_000, [.exact(12_000), inferred(7_000), .estimated(1)]) == .uniqueSolution(member: members3[2], minorUnits: 12_000))
    #expect(analyze(31_000, [.exact(12_000), .exact(7_000), amountRange(10_000, 15_000)]) == .uniqueSolution(member: members3[2], minorUnits: 12_000))
}

@Test func twoUnresolvedMembersAreStillAmbiguousEvenWhenTheTotalIsFixed() {
    guard case let .underdetermined(group) = analyze(31_000, [.exact(12_000), .unknown, .unknown]) else {
        Issue.record("expected underdetermined, not a guess")
        return
    }
    #expect(group.remainingMinorUnits == 19_000 && group.unresolved.count == 2)
}

@Test func impossibleConstraintsAreContradictionsNotSolutions() {
    #expect(analyze(31_000, [.exact(12_000), .exact(7_000), .exact(11_000)]) == .contradiction(.knownSumMismatch))
    #expect(analyze(31_000, [.exact(12_000), .exact(7_000), .exact(12_000)]) == .satisfied)
    #expect(analyze(10_000, [.exact(12_000), .unknown, .unknown]) == .contradiction(.knownSumExceedsTotal))
    #expect(analyze(31_000, [.exact(12_000), .exact(7_000), amountRange(1_000, 5_000)]) == .contradiction(.solutionOutsideMemberBounds(members3[2])))
    #expect(analyze(5_000, [amountRange(4_000, 6_000), amountRange(4_000, 6_000), .unknown]) == .contradiction(.boundsCannotReachTotal))
    #expect(analyze(31_000, [amountRange(1, 5_000), amountRange(1, 5_000), amountRange(1, 5_000)]) == .contradiction(.boundsCannotReachTotal))
    #expect(analyze(2, [.unknown, .unknown, .unknown]) == .contradiction(.boundsCannotReachTotal))      // each member is at least 1
}
