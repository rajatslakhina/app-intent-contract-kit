import Foundation

/// How a change affects callers that were written against the old surface.
public enum ChangeImpact: Int, Comparable, Sendable, CustomStringConvertible {
    /// Wording only (titles). Siri phrasing may shift; no caller breaks.
    case cosmetic = 0
    /// New capability. Every old caller still resolves.
    case additive = 1
    /// Still works today, scheduled to stop working.
    case deprecating = 2
    /// Some old Shortcut, Siri phrase or agent plan stops resolving.
    case breaking = 3

    public static func < (lhs: ChangeImpact, rhs: ChangeImpact) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The minimum semantic-version bump this impact demands.
    public var requiredBump: BumpLevel {
        switch self {
        case .cosmetic: return .patch
        case .additive, .deprecating: return .minor
        case .breaking: return .major
        }
    }

    public var description: String {
        switch self {
        case .cosmetic: return "cosmetic"
        case .additive: return "additive"
        case .deprecating: return "deprecating"
        case .breaking: return "breaking"
        }
    }
}

/// Stable keys tie three things together: a diff entry, the migration that
/// covers it, and a replay failure caused by it. One function per key so the
/// three can never spell it differently.
public enum ChangeKey {
    public static func intentRemoved(_ intent: String) -> String { "intent-removed:\(intent)" }
    public static func parameterRequired(_ intent: String, _ parameter: String) -> String { "param-required:\(intent).\(parameter)" }
    public static func parameterRemoved(_ intent: String, _ parameter: String) -> String { "param-removed:\(intent).\(parameter)" }
    public static func parametersMerged(_ intent: String, _ parameter: String) -> String { "param-merged:\(intent).\(parameter)" }
    public static func parameterType(_ intent: String, _ parameter: String) -> String { "param-type:\(intent).\(parameter)" }
    public static func resultType(_ intent: String) -> String { "result-type:\(intent)" }
    public static func entityIDFormat(_ entity: String) -> String { "entity-id:\(entity)" }
    public static func entityRemoved(_ entity: String) -> String { "entity-removed:\(entity)" }
    public static func entityProperty(_ entity: String, _ property: String) -> String { "entity-prop:\(entity).\(property)" }
    public static func enumRemoved(_ enumeration: String) -> String { "enum-removed:\(enumeration)" }
    public static func enumCaseRemoved(_ enumeration: String, _ value: String) -> String { "enum-case-removed:\(enumeration).\(value)" }
}

public enum ChangeKind: Hashable, Sendable {
    case intentAdded(String)
    case intentRemoved(String, scheduled: Bool)
    case intentRenamed(from: String, to: String)
    case intentDeprecated(String)
    case intentRetitled(String)
    /// An alias row (or a chain link) that used to resolve no longer does.
    case aliasRemoved(String, scheduled: Bool)
    /// A former parameter name that old callers still send was dropped.
    case parameterFormerNameDropped(intent: String, name: String)
    /// A former entity identifier that stored values still use was dropped.
    case entityFormerIdentifierDropped(entity: String, former: String)
    case parameterAdded(intent: String, name: String, required: Bool)
    case parameterRemoved(intent: String, name: String)
    case parameterRenamed(intent: String, from: String, to: String)
    /// Two old parameters now map onto one: a caller sending both is rejected.
    case parametersMerged(intent: String, into: String)
    /// The previous release's compatibility layer did something this one no longer does.
    case migrationDropped(String)
    case parameterTypeChanged(intent: String, name: String, from: ValueType, to: ValueType)
    case parameterTypeWidened(intent: String, name: String, from: ValueType, to: ValueType)
    case parameterBecameRequired(intent: String, name: String)
    case parameterRelaxed(intent: String, name: String)
    case resultTypeChanged(intent: String, from: ValueType?, to: ValueType?)
    case entityAdded(String)
    case entityRemoved(String)
    case entityRenamed(from: String, to: String)
    case entityIDFormatChanged(entity: String, from: EntityIDFormat, to: EntityIDFormat)
    case entityPropertyAdded(entity: String, name: String)
    case entityPropertyRemoved(entity: String, name: String)
    case entityPropertyTypeChanged(entity: String, name: String)
    case enumAdded(String)
    case enumRemoved(String)
    case enumCaseAdded(enumeration: String, value: String)
    case enumCaseRemoved(enumeration: String, value: String)
}

public struct ContractChange: Hashable, Sendable, CustomStringConvertible {
    public var kind: ChangeKind
    public var impact: ChangeImpact
    /// Present for breaking changes; what a migration has to cover.
    public var key: String?

    public init(kind: ChangeKind, impact: ChangeImpact, key: String? = nil) {
        self.kind = kind
        self.impact = impact
        self.key = key
    }

    public var description: String {
        switch kind {
        case .intentAdded(let id): return "Intent \(id) added"
        case let .intentRemoved(id, scheduled): return scheduled ? "Intent \(id) removed (deprecation window honoured)" : "Intent \(id) removed with no alias and no deprecation window"
        case let .intentRenamed(from, to): return "Intent \(from) renamed to \(to) (old identifier kept as alias)"
        case .intentDeprecated(let id): return "Intent \(id) deprecated"
        case .intentRetitled(let id): return "Intent \(id) retitled"
        case let .aliasRemoved(id, scheduled): return scheduled ? "Alias \(id) stops resolving (its target's deprecation window is honoured)" : "Alias \(id) no longer resolves to a live intent"
        case let .parameterFormerNameDropped(intent, name): return "\(intent): former parameter name \(name) dropped"
        case let .entityFormerIdentifierDropped(entity, former): return "\(entity): former identifier \(former) dropped"
        case let .parameterAdded(intent, name, required): return required ? "\(intent).\(name) added as a required parameter" : "\(intent).\(name) added (optional)"
        case let .parameterRemoved(intent, name): return "\(intent).\(name) removed"
        case let .parameterRenamed(intent, from, to): return "\(intent).\(from) renamed to \(to) (former name kept)"
        case let .parametersMerged(intent, into): return "\(intent): several old parameters now map onto \(into)"
        case .migrationDropped(let what): return "Compatibility shim dropped: \(what)"
        case let .parameterTypeChanged(intent, name, from, to): return "\(intent).\(name) type changed \(from) → \(to)"
        case let .parameterTypeWidened(intent, name, from, to): return "\(intent).\(name) widened \(from) → \(to)"
        case let .parameterBecameRequired(intent, name): return "\(intent).\(name) became required"
        case let .parameterRelaxed(intent, name): return "\(intent).\(name) became optional"
        case let .resultTypeChanged(intent, from, to): return "\(intent) result changed \(from.map(\.description) ?? "Void") → \(to.map(\.description) ?? "Void")"
        case .entityAdded(let id): return "Entity \(id) added"
        case .entityRemoved(let id): return "Entity \(id) removed"
        case let .entityRenamed(from, to): return "Entity \(from) renamed to \(to)"
        case let .entityIDFormatChanged(entity, from, to): return "\(entity) identifiers changed format \(from) → \(to)"
        case let .entityPropertyAdded(entity, name): return "\(entity).\(name) property added"
        case let .entityPropertyRemoved(entity, name): return "\(entity).\(name) property removed"
        case let .entityPropertyTypeChanged(entity, name): return "\(entity).\(name) property type changed"
        case .enumAdded(let id): return "Enum \(id) added"
        case .enumRemoved(let id): return "Enum \(id) removed"
        case let .enumCaseAdded(enumeration, value): return "\(enumeration).\(value) case added"
        case let .enumCaseRemoved(enumeration, value): return "\(enumeration).\(value) case removed"
        }
    }
}

/// Classifies every difference between two published surfaces.
/// A protocol so the gate's defence in depth can be tested against a lying differ.
public protocol SurfaceDiffing: Sendable {
    func diff(from old: IntentSurface, to new: IntentSurface) -> [ContractChange]
}

public struct SchemaDiffer: SurfaceDiffing {
    public init() {}

    public func diff(from old: IntentSurface, to new: IntentSurface) -> [ContractChange] {
        var changes: [ContractChange] = []
        let entityAliases = new.entityAliasMap
        changes += diffEntities(old: old, new: new)
        changes += diffEnums(old: old, new: new)
        changes += diffIntents(old: old, new: new, entityAliases: entityAliases)
        return changes
    }

    // MARK: Intents

    private func diffIntents(old: IntentSurface, new: IntentSurface, entityAliases: [String: String]) -> [ContractChange] {
        var changes: [ContractChange] = []
        let newByID = new.intentsByID
        let oldByID = old.intentsByID
        var renameTargets: Set<String> = []

        for oldIntent in old.intents.sorted(by: { $0.identifier < $1.identifier }) {
            if let newIntent = newByID[oldIntent.identifier] {
                changes += compare(oldIntent, newIntent, entityAliases: entityAliases)
                continue
            }
            switch new.resolveIntent(oldIntent.identifier) {
            case .live(let target, _):
                if let newIntent = newByID[target] {
                    // A rename only reads as additive if the target is new;
                    // aliasing onto an existing intent is a merge, still additive
                    // for resolution, so the parameter comparison decides.
                    if oldByID[target] == nil { renameTargets.insert(target) }
                    changes.append(ContractChange(kind: .intentRenamed(from: oldIntent.identifier, to: target), impact: .additive))
                    changes += compare(oldIntent, newIntent, entityAliases: entityAliases)
                }
            case .unknown, .dangling, .cycle:
                let scheduled = oldIntent.deprecation.map { new.version >= $0.removalNotBefore } ?? false
                changes.append(ContractChange(kind: .intentRemoved(oldIntent.identifier, scheduled: scheduled),
                                              impact: .breaking,
                                              key: ChangeKey.intentRemoved(oldIntent.identifier)))
            }
        }
        // Alias rows are callers' bookmarks too. If one resolved before and does
        // not now, every Shortcut that stored that name breaks.
        for alias in old.aliases.sorted(by: { $0.from < $1.from }) where oldByID[alias.from] == nil {
            guard case .live(let oldTarget, _) = old.resolveIntent(alias.from) else { continue }
            if newByID[alias.from] != nil { continue }
            if case .live = new.resolveIntent(alias.from) { continue }
            // Only excused when the target itself is gone on schedule; deleting a
            // row while its target still lives is an unforced break.
            let targetRemoved = newByID[oldTarget] == nil
            let scheduled = targetRemoved && (oldByID[oldTarget]?.deprecation.map { new.version >= $0.removalNotBefore } ?? false)
            changes.append(ContractChange(kind: .aliasRemoved(alias.from, scheduled: scheduled),
                                          impact: .breaking,
                                          key: ChangeKey.intentRemoved(alias.from)))
        }
        for newIntent in new.intents.sorted(by: { $0.identifier < $1.identifier })
        where oldByID[newIntent.identifier] == nil && !renameTargets.contains(newIntent.identifier) {
            changes.append(ContractChange(kind: .intentAdded(newIntent.identifier), impact: .additive))
        }
        return changes
    }

    /// Compares an old intent with the live intent its callers now reach.
    /// Keys use the *new* identifier because that is what migrations attach to.
    private func compare(_ old: IntentSchema, _ new: IntentSchema, entityAliases: [String: String]) -> [ContractChange] {
        var changes: [ContractChange] = []
        let id = new.identifier
        if old.title != new.title {
            changes.append(ContractChange(kind: .intentRetitled(id), impact: .cosmetic))
        }
        if old.deprecation == nil, new.deprecation != nil {
            changes.append(ContractChange(kind: .intentDeprecated(id), impact: .deprecating))
        }

        var matchedNew: Set<String> = []
        for oldParameter in old.parameters.sorted(by: { $0.name < $1.name }) {
            guard let newParameter = new.parameters.first(where: { $0.name == oldParameter.name || $0.formerNames.contains(oldParameter.name) }) else {
                // Old callers may send the current name or any former name, and
                // each needs its own cover (a retirement is per name).
                for name in [oldParameter.name] + oldParameter.formerNames.sorted() {
                    changes.append(ContractChange(kind: .parameterRemoved(intent: id, name: name),
                                                  impact: .breaking,
                                                  key: ChangeKey.parameterRemoved(id, name)))
                }
                continue
            }
            for former in oldParameter.formerNames.sorted() where former != newParameter.name && !newParameter.formerNames.contains(former) {
                changes.append(ContractChange(kind: .parameterFormerNameDropped(intent: id, name: former),
                                              impact: .breaking,
                                              key: ChangeKey.parameterRemoved(id, former)))
            }
            if !matchedNew.insert(newParameter.name).inserted {
                changes.append(ContractChange(kind: .parametersMerged(intent: id, into: newParameter.name),
                                              impact: .breaking,
                                              key: ChangeKey.parametersMerged(id, newParameter.name)))
            }
            if newParameter.name != oldParameter.name {
                changes.append(ContractChange(kind: .parameterRenamed(intent: id, from: oldParameter.name, to: newParameter.name), impact: .additive))
            }
            if oldParameter.type != newParameter.type {
                if newParameter.type.accepts(oldParameter.type, entityAliases: entityAliases) {
                    changes.append(ContractChange(kind: .parameterTypeWidened(intent: id, name: newParameter.name, from: oldParameter.type, to: newParameter.type), impact: .additive))
                } else {
                    changes.append(ContractChange(kind: .parameterTypeChanged(intent: id, name: newParameter.name, from: oldParameter.type, to: newParameter.type),
                                                  impact: .breaking,
                                                  key: ChangeKey.parameterType(id, newParameter.name)))
                }
            }
            if !oldParameter.isRequired, newParameter.isRequired {
                changes.append(ContractChange(kind: .parameterBecameRequired(intent: id, name: newParameter.name),
                                              impact: .breaking,
                                              key: ChangeKey.parameterRequired(id, newParameter.name)))
            } else if oldParameter.isRequired, !newParameter.isRequired {
                changes.append(ContractChange(kind: .parameterRelaxed(intent: id, name: newParameter.name), impact: .additive))
            }
        }
        for newParameter in new.parameters.sorted(by: { $0.name < $1.name }) where !matchedNew.contains(newParameter.name) {
            if newParameter.isRequired {
                changes.append(ContractChange(kind: .parameterAdded(intent: id, name: newParameter.name, required: true),
                                              impact: .breaking,
                                              key: ChangeKey.parameterRequired(id, newParameter.name)))
            } else {
                changes.append(ContractChange(kind: .parameterAdded(intent: id, name: newParameter.name, required: false), impact: .additive))
            }
        }

        if old.result != new.result {
            // Downstream plan steps consume the result, so the *old* type must
            // accept the new one (covariance): Int where Decimal was promised is fine.
            let compatible: Bool
            switch (old.result, new.result) {
            case (nil, _): compatible = true
            case (_, nil): compatible = false
            case let (oldType?, newType?):
                compatible = ValueType.isCovariant(old: oldType, new: newType, entityAliases: entityAliases)
            }
            changes.append(ContractChange(kind: .resultTypeChanged(intent: id, from: old.result, to: new.result),
                                          impact: compatible ? .additive : .breaking,
                                          key: compatible ? nil : ChangeKey.resultType(id)))
        }
        return changes
    }

    // MARK: Entities

    private func diffEntities(old: IntentSurface, new: IntentSurface) -> [ContractChange] {
        var changes: [ContractChange] = []
        let newByID = new.entitiesByID
        let aliases = new.entityAliasMap
        var matched: Set<String> = []

        for oldEntity in old.entities.sorted(by: { $0.identifier < $1.identifier }) {
            guard let liveID = aliases[oldEntity.identifier], let newEntity = newByID[liveID] else {
                changes.append(ContractChange(kind: .entityRemoved(oldEntity.identifier), impact: .breaking, key: ChangeKey.entityRemoved(oldEntity.identifier)))
                continue
            }
            matched.insert(liveID)
            for former in oldEntity.formerIdentifiers.sorted() where aliases[former] == nil {
                changes.append(ContractChange(kind: .entityFormerIdentifierDropped(entity: liveID, former: former),
                                              impact: .breaking,
                                              key: ChangeKey.entityRemoved(former)))
            }
            if liveID != oldEntity.identifier {
                changes.append(ContractChange(kind: .entityRenamed(from: oldEntity.identifier, to: liveID), impact: .additive))
            }
            if oldEntity.idFormat != newEntity.idFormat {
                changes.append(ContractChange(kind: .entityIDFormatChanged(entity: liveID, from: oldEntity.idFormat, to: newEntity.idFormat),
                                              impact: .breaking,
                                              key: ChangeKey.entityIDFormat(liveID)))
            }
            let newProperties = Dictionary(newEntity.properties.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
            let oldNames = Set(oldEntity.properties.map(\.name))
            for property in oldEntity.properties.sorted(by: { $0.name < $1.name }) {
                guard let newType = newProperties[property.name] else {
                    changes.append(ContractChange(kind: .entityPropertyRemoved(entity: liveID, name: property.name), impact: .breaking, key: ChangeKey.entityProperty(liveID, property.name)))
                    continue
                }
                if !ValueType.isCovariant(old: property.type, new: newType, entityAliases: aliases) {
                    changes.append(ContractChange(kind: .entityPropertyTypeChanged(entity: liveID, name: property.name), impact: .breaking, key: ChangeKey.entityProperty(liveID, property.name)))
                }
            }
            for property in newEntity.properties.sorted(by: { $0.name < $1.name }) where !oldNames.contains(property.name) {
                changes.append(ContractChange(kind: .entityPropertyAdded(entity: liveID, name: property.name), impact: .additive))
            }
        }
        for entity in new.entities.sorted(by: { $0.identifier < $1.identifier }) where !matched.contains(entity.identifier) {
            changes.append(ContractChange(kind: .entityAdded(entity.identifier), impact: .additive))
        }
        return changes
    }

    // MARK: Enums

    private func diffEnums(old: IntentSurface, new: IntentSurface) -> [ContractChange] {
        var changes: [ContractChange] = []
        let newByID = new.enumsByID
        let oldIDs = Set(old.enums.map(\.identifier))
        for oldEnum in old.enums.sorted(by: { $0.identifier < $1.identifier }) {
            guard let newEnum = newByID[oldEnum.identifier] else {
                changes.append(ContractChange(kind: .enumRemoved(oldEnum.identifier), impact: .breaking, key: ChangeKey.enumRemoved(oldEnum.identifier)))
                continue
            }
            let newCases = Set(newEnum.cases)
            let oldCases = Set(oldEnum.cases)
            for value in oldEnum.cases.sorted() where !newCases.contains(value) {
                changes.append(ContractChange(kind: .enumCaseRemoved(enumeration: oldEnum.identifier, value: value), impact: .breaking, key: ChangeKey.enumCaseRemoved(oldEnum.identifier, value)))
            }
            for value in newEnum.cases.sorted() where !oldCases.contains(value) {
                changes.append(ContractChange(kind: .enumCaseAdded(enumeration: oldEnum.identifier, value: value), impact: .additive))
            }
        }
        for newEnum in new.enums.sorted(by: { $0.identifier < $1.identifier }) where !oldIDs.contains(newEnum.identifier) {
            changes.append(ContractChange(kind: .enumAdded(newEnum.identifier), impact: .additive))
        }
        return changes
    }
}
