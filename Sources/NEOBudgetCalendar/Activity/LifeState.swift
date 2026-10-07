import NEOBudgetCore

public enum LifeValidationError: Error, Hashable, Sendable {
    case emptyIdentifier(entity: String)
    case emptyName(entity: String)
    case duplicateIdentifier(entity: String, id: String)
    case duplicateTagName(String)
    case duplicateAreaAlias(String)
    case unknownBroaderArea(AreaID)
    case areaCycle(AreaID)
    case unknownActivity(ActivityID)
    case unknownActivityType(ActivityTypeID)
    case activityTypeArchived(ActivityTypeID)
    case unknownTag(TagID)
    case tagArchived(TagID)
    case unknownArea(AreaID)
    case eventAlreadyAssociated(CalendarEventKey)
    case notCalendarActivity(ActivityID)
    case activityHasLinks(ActivityID)
    case presetImmutable(ActivityTypeID)
    case invalidConfidence
    case userAssignmentProtected
}

/// A single validated mutation of life state. Removals and clears carry who is asking so that automation
/// cannot undo a user's decision.
public enum LifeChange: Hashable, Sendable {
    case upsertActivityType(ActivityTypeDefinition)
    case upsertTag(Tag)
    case upsertArea(Area)

    case createActivity(Activity)
    case updateAssociation(ActivityID, CalendarEventAssociation)
    case removeActivity(ActivityID)

    case setActivityType(ActivityID, Assigned<ActivityTypeID>)
    case clearActivityType(ActivityID, by: AssignmentProvenance)
    case setActivityArea(ActivityID, Assigned<AreaID>)
    case clearActivityArea(ActivityID, by: AssignmentProvenance)
    case setActivityTag(ActivityID, TagAssignment)
    case removeActivityTag(ActivityID, TagID, by: AssignmentProvenance)

    case setLink(TransactionActivityLink)
    case removeLink(LedgerEntryID, by: AssignmentProvenance)

    case setTransactionTag(LedgerEntryID, TagAssignment)
    case removeTransactionTag(LedgerEntryID, TagID, by: AssignmentProvenance)
}

/// All OnAll-owned meaning around calendar events and transactions, as one value with enforced invariants.
///
/// Pure and platform-independent: any repository (in-memory now, durable later) can wrap it. `applying`
/// is all-or-nothing and never mutates the receiver.
public struct LifeState: Codable, Equatable, Sendable {
    public private(set) var activityTypes: [ActivityTypeID: ActivityTypeDefinition]
    public private(set) var tags: [TagID: Tag]
    public private(set) var areaCatalog: AreaCatalog
    public private(set) var activities: [ActivityID: Activity]
    public private(set) var linksByTransaction: [LedgerEntryID: TransactionActivityLink]
    public private(set) var transactionTags: [LedgerEntryID: [TagAssignment]]

    /// Starts with the preset activity types and nothing else.
    public static var empty: LifeState {
        LifeState(
            activityTypes: Dictionary(uniqueKeysWithValues: ActivityTypeDefinition.presets.map { ($0.id, $0) }),
            tags: [:],
            areaCatalog: AreaCatalog(),
            activities: [:],
            linksByTransaction: [:],
            transactionTags: [:]
        )
    }

    private init(
        activityTypes: [ActivityTypeID: ActivityTypeDefinition],
        tags: [TagID: Tag],
        areaCatalog: AreaCatalog,
        activities: [ActivityID: Activity],
        linksByTransaction: [LedgerEntryID: TransactionActivityLink],
        transactionTags: [LedgerEntryID: [TagAssignment]]
    ) {
        self.activityTypes = activityTypes
        self.tags = tags
        self.areaCatalog = areaCatalog
        self.activities = activities
        self.linksByTransaction = linksByTransaction
        self.transactionTags = transactionTags
    }

    // MARK: Queries

    public func activity(forEvent key: CalendarEventKey) -> Activity? {
        activities.values.first { $0.association?.key == key }
    }

    /// One pass index for callers that look up many events.
    public func activitiesByEvent() -> [CalendarEventKey: Activity] {
        var index: [CalendarEventKey: Activity] = [:]
        for activity in activities.values {
            if let key = activity.association?.key { index[key] = activity }
        }
        return index
    }

    public func link(for transactionID: LedgerEntryID) -> TransactionActivityLink? { linksByTransaction[transactionID] }

    public func links(forActivity id: ActivityID) -> [TransactionActivityLink] {
        linksByTransaction.values
            .filter { $0.activityID == id }
            .sorted { ($0.createdAtUnixMilliseconds, $0.transactionID.rawValue) < ($1.createdAtUnixMilliseconds, $1.transactionID.rawValue) }
    }

    public func tags(forTransaction id: LedgerEntryID) -> [TagAssignment] { transactionTags[id] ?? [] }

    // MARK: Mutation

    /// Applies every change in order or none of them.
    public func applying(_ changes: [LifeChange]) throws -> LifeState {
        var next = self
        for change in changes { try next.apply(change) }
        return next
    }

    private mutating func apply(_ change: LifeChange) throws {
        switch change {
        case let .upsertActivityType(definition):
            guard !definition.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "activityType") }
            guard !NameNormalizer.normalize(definition.displayName).isEmpty else { throw LifeValidationError.emptyName(entity: "activityType") }
            if let existing = activityTypes[definition.id], existing.isPreset != definition.isPreset {
                throw LifeValidationError.presetImmutable(definition.id)
            }
            activityTypes[definition.id] = definition

        case let .upsertTag(tag):
            guard !tag.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "tag") }
            let normalized = NameNormalizer.normalize(tag.name)
            guard !normalized.isEmpty else { throw LifeValidationError.emptyName(entity: "tag") }
            if !tag.isArchived,
               tags.values.contains(where: { $0.id != tag.id && !$0.isArchived && NameNormalizer.normalize($0.name) == normalized }) {
                throw LifeValidationError.duplicateTagName(normalized)
            }
            tags[tag.id] = tag

        case let .upsertArea(area):
            areaCatalog = try areaCatalog.inserting(area)

        case let .createActivity(activity):
            guard !activity.id.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "activity") }
            guard activities[activity.id] == nil else {
                throw LifeValidationError.duplicateIdentifier(entity: "activity", id: activity.id.rawValue)
            }
            switch activity.origin {
            case let .calendarEvent(association):
                guard activitiesByEvent()[association.key] == nil else {
                    throw LifeValidationError.eventAlreadyAssociated(association.key)
                }
            case let .standalone(info):
                guard !NameNormalizer.normalize(info.title).isEmpty else { throw LifeValidationError.emptyName(entity: "activity") }
            }
            if let type = activity.activityType { try validateType(type) }
            if let area = activity.area { try validateArea(area) }
            var seen = Set<TagID>()
            for tag in activity.tags {
                try validateTag(tag)
                guard seen.insert(tag.tagID).inserted else {
                    throw LifeValidationError.duplicateIdentifier(entity: "activityTag", id: tag.tagID.rawValue)
                }
            }
            activities[activity.id] = activity

        case let .updateAssociation(id, association):
            var activity = try existingActivity(id)
            guard activity.association != nil else { throw LifeValidationError.notCalendarActivity(id) }
            if let holder = activitiesByEvent()[association.key], holder.id != id {
                throw LifeValidationError.eventAlreadyAssociated(association.key)
            }
            activity.origin = .calendarEvent(association)
            activities[id] = activity

        case let .removeActivity(id):
            _ = try existingActivity(id)
            guard !linksByTransaction.values.contains(where: { $0.activityID == id }) else {
                throw LifeValidationError.activityHasLinks(id)
            }
            activities[id] = nil

        case let .setActivityType(id, assigned):
            var activity = try existingActivity(id)
            try validateType(assigned)
            if let existing = activity.activityType, !assigned.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            activity.activityType = assigned
            activities[id] = activity

        case let .clearActivityType(id, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let existing = activity.activityType {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.activityType = nil
                activities[id] = activity
            }

        case let .setActivityArea(id, assigned):
            var activity = try existingActivity(id)
            try validateArea(assigned)
            if let existing = activity.area, !assigned.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            activity.area = assigned
            activities[id] = activity

        case let .clearActivityArea(id, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let existing = activity.area {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.area = nil
                activities[id] = activity
            }

        case let .setActivityTag(id, assignment):
            var activity = try existingActivity(id)
            try validateTag(assignment)
            if let index = activity.tags.firstIndex(where: { $0.tagID == assignment.tagID }) {
                guard assignment.provenance.mayReplace(activity.tags[index].provenance) else {
                    throw LifeValidationError.userAssignmentProtected
                }
                activity.tags[index] = assignment
            } else {
                activity.tags.append(assignment)
                activity.tags.sort { $0.tagID < $1.tagID }
            }
            activities[id] = activity

        case let .removeActivityTag(id, tagID, by):
            var activity = try existingActivity(id)
            try requireValid(by)
            if let index = activity.tags.firstIndex(where: { $0.tagID == tagID }) {
                guard by.mayReplace(activity.tags[index].provenance) else { throw LifeValidationError.userAssignmentProtected }
                activity.tags.remove(at: index)
                activities[id] = activity
            }

        case let .setLink(link):
            guard !link.transactionID.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "transaction") }
            _ = try existingActivity(link.activityID)
            try requireValid(link.provenance)
            if let existing = linksByTransaction[link.transactionID], !link.provenance.mayReplace(existing.provenance) {
                throw LifeValidationError.userAssignmentProtected
            }
            // Deliberately no time-containment check: a link is meaning, not a time window.
            linksByTransaction[link.transactionID] = link

        case let .removeLink(transactionID, by):
            try requireValid(by)
            if let existing = linksByTransaction[transactionID] {
                guard by.mayReplace(existing.provenance) else { throw LifeValidationError.userAssignmentProtected }
                linksByTransaction[transactionID] = nil
            }

        case let .setTransactionTag(transactionID, assignment):
            guard !transactionID.rawValue.isEmpty else { throw LifeValidationError.emptyIdentifier(entity: "transaction") }
            try validateTag(assignment)
            var list = transactionTags[transactionID] ?? []
            if let index = list.firstIndex(where: { $0.tagID == assignment.tagID }) {
                guard assignment.provenance.mayReplace(list[index].provenance) else {
                    throw LifeValidationError.userAssignmentProtected
                }
                list[index] = assignment
            } else {
                list.append(assignment)
                list.sort { $0.tagID < $1.tagID }
            }
            transactionTags[transactionID] = list

        case let .removeTransactionTag(transactionID, tagID, by):
            try requireValid(by)
            var list = transactionTags[transactionID] ?? []
            if let index = list.firstIndex(where: { $0.tagID == tagID }) {
                guard by.mayReplace(list[index].provenance) else { throw LifeValidationError.userAssignmentProtected }
                list.remove(at: index)
                transactionTags[transactionID] = list.isEmpty ? nil : list
            }
        }
    }

    // MARK: Validation helpers

    private func existingActivity(_ id: ActivityID) throws -> Activity {
        guard let activity = activities[id] else { throw LifeValidationError.unknownActivity(id) }
        return activity
    }

    private func requireValid(_ provenance: AssignmentProvenance) throws {
        guard provenance.hasValidConfidence else { throw LifeValidationError.invalidConfidence }
    }

    private func validateType(_ assigned: Assigned<ActivityTypeID>) throws {
        try requireValid(assigned.provenance)
        guard let definition = activityTypes[assigned.value] else { throw LifeValidationError.unknownActivityType(assigned.value) }
        guard !definition.isArchived else { throw LifeValidationError.activityTypeArchived(assigned.value) }
    }

    private func validateArea(_ assigned: Assigned<AreaID>) throws {
        try requireValid(assigned.provenance)
        guard areaCatalog.area(assigned.value) != nil else { throw LifeValidationError.unknownArea(assigned.value) }
    }

    private func validateTag(_ assignment: TagAssignment) throws {
        try requireValid(assignment.provenance)
        guard let tag = tags[assignment.tagID] else { throw LifeValidationError.unknownTag(assignment.tagID) }
        guard !tag.isArchived else { throw LifeValidationError.tagArchived(assignment.tagID) }
    }
}
