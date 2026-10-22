import Foundation

/// A value a caller (a saved Shortcut, a Siri request, an agent's tool call)
/// supplies for a parameter.
public indirect enum ArgumentValue: Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case entity(type: String, id: String)
    case enumCase(String)
    case list([ArgumentValue])

    public var description: String {
        switch self {
        case .string(let value): return "\"\(value)\""
        case .integer(let value): return "\(value)"
        case .decimal(let value): return "\(value)"
        case .boolean(let value): return "\(value)"
        case let .entity(type, id): return "\(type)(\(id))"
        case .enumCase(let value): return ".\(value)"
        case .list(let values): return "[\(values.map(\.description).joined(separator: ", "))]"
        }
    }
}

/// One recorded call into the app.
public struct IntentInvocation: Hashable, Sendable {
    public var intent: String
    public var arguments: [String: ArgumentValue]
    public init(_ intent: String, arguments: [String: ArgumentValue] = [:]) {
        self.intent = intent
        self.arguments = arguments
    }
}

public struct ResolvedInvocation: Hashable, Sendable {
    public var intent: String
    public var aliasHops: [String]
    public var arguments: [String: ArgumentValue]
    /// What the compatibility layer did on the caller's behalf.
    public var notes: [String]
}

public enum ResolutionFailure: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownIntent(String)
    case danglingAlias([String])
    case aliasCycle([String])
    case unknownArgument(intent: String, name: String)
    case duplicateArgument(intent: String, name: String)
    case missingArgument(intent: String, name: String)
    case typeMismatch(intent: String, name: String, expected: ValueType, got: String)
    case unknownEntity(String)
    case entityIDUnresolvable(entity: String, id: String)
    case unknownEnumCase(enumeration: String, value: String)
    case badBinding(step: Int, parameter: String, reason: String)
    case bindingSourceHasNoResult(step: Int, parameter: String, sourceIntent: String)
    case bindingTypeMismatch(intent: String, parameter: String, sourceIntent: String, produced: ValueType, expected: ValueType)

    public var description: String {
        switch self {
        case .unknownIntent(let id): return "No intent or alias named \(id)"
        case .danglingAlias(let path): return "Alias chain \(path.joined(separator: " → ")) leads to an intent that no longer exists"
        case .aliasCycle(let path): return "Alias cycle \(path.joined(separator: " → "))"
        case let .unknownArgument(intent, name): return "\(intent) has no parameter \(name)"
        case let .duplicateArgument(intent, name): return "\(intent).\(name) supplied twice (old and new name)"
        case let .missingArgument(intent, name): return "\(intent).\(name) is required and was not supplied"
        case let .typeMismatch(intent, name, expected, got): return "\(intent).\(name) expects \(expected), got \(got)"
        case .unknownEntity(let name): return "No entity type \(name)"
        case let .entityIDUnresolvable(entity, id): return "\(entity) id '\(id)' is in a retired format and no shim maps it"
        case let .unknownEnumCase(enumeration, value): return "\(enumeration) has no case \(value)"
        case let .badBinding(step, parameter, reason): return "Step \(Saturating.add(step, 1)) binding for \(parameter): \(reason)"
        case let .bindingSourceHasNoResult(step, parameter, source): return "Step \(Saturating.add(step, 1)) binds \(parameter) to \(source), which no longer returns a value"
        case let .bindingTypeMismatch(intent, parameter, source, produced, expected): return "\(intent).\(parameter) expects \(expected) but \(source) now returns \(produced)"
        }
    }

    /// The `ChangeKey`s a migration could cover for this failure not to count
    /// as a regression. Empty means nothing can excuse it.
    public var relatedChangeKeys: [String] {
        switch self {
        case .unknownIntent(let id): return [ChangeKey.intentRemoved(id)]
        // Any link in the chain may be the one the release removed.
        case .danglingAlias(let path): return path.map(ChangeKey.intentRemoved)
        case let .unknownArgument(intent, name): return [ChangeKey.parameterRemoved(intent, name)]
        case let .duplicateArgument(intent, name): return [ChangeKey.parametersMerged(intent, name)]
        case let .missingArgument(intent, name): return [ChangeKey.parameterRequired(intent, name)]
        case let .typeMismatch(intent, name, _, _): return [ChangeKey.parameterType(intent, name)]
        case .unknownEntity(let entity): return [ChangeKey.entityRemoved(entity)]
        case let .entityIDUnresolvable(entity, _): return [ChangeKey.entityIDFormat(entity)]
        case let .unknownEnumCase(enumeration, value): return [ChangeKey.enumCaseRemoved(enumeration, value)]
        case let .bindingSourceHasNoResult(_, _, source): return [ChangeKey.resultType(source)]
        case let .bindingTypeMismatch(intent, parameter, source, _, _): return [ChangeKey.resultType(source), ChangeKey.parameterType(intent, parameter)]
        case .aliasCycle, .badBinding: return []
        }
    }
}

/// The runtime half of the contract: turns an invocation recorded against
/// *any* earlier surface into a call against the live one, applying exactly
/// the aliases, renames, backfills, retirements and ID shims the release
/// declared, and nothing else. Strict by default: an argument it cannot place
/// is an error, never silently dropped.
public struct IntentResolver: Sendable {
    public let surface: IntentSurface
    public let migration: MigrationPlan
    private let intents: [String: IntentSchema]
    private let entities: [String: EntitySchema]
    private let entityAliases: [String: String]
    private let enums: [String: EnumSchema]

    public init(surface: IntentSurface, migration: MigrationPlan = .none) {
        self.surface = surface
        self.migration = migration
        self.intents = surface.intentsByID
        self.entities = surface.entitiesByID
        self.entityAliases = surface.entityAliasMap
        self.enums = surface.enumsByID
    }

    public func intent(named identifier: String) -> IntentSchema? { intents[identifier] }

    /// - Parameter externallySupplied: parameter names (old or new spelling)
    ///   that a plan binds from an earlier step's result.
    public func resolve(_ invocation: IntentInvocation, externallySupplied: Set<String> = []) -> Result<ResolvedInvocation, ResolutionFailure> {
        let target: String
        let hops: [String]
        switch surface.resolveIntent(invocation.intent) {
        case let .live(id, path): target = id; hops = path
        case .unknown(let id): return .failure(.unknownIntent(id))
        case .dangling(let path): return .failure(.danglingAlias(path))
        case .cycle(let path): return .failure(.aliasCycle(path))
        }
        guard let schema = intents[target] else { return .failure(.unknownIntent(invocation.intent)) }

        var notes: [String] = []
        if !hops.isEmpty { notes.append("Resolved \(invocation.intent) → \(target) via alias") }
        var resolved: [String: ArgumentValue] = [:]
        var supplied: Set<String> = []

        func parameter(for name: String) -> ParameterSchema? {
            schema.parameters.first { $0.name == name || $0.formerNames.contains(name) }
        }

        for name in externallySupplied.sorted() {
            guard let param = parameter(for: name) else {
                // Same rule as literal arguments: a retired name is accepted and dropped.
                if migration.retires(intent: target, parameter: name) {
                    notes.append("Dropped retired bound argument \(name)")
                    continue
                }
                return .failure(.unknownArgument(intent: target, name: name))
            }
            guard supplied.insert(param.name).inserted else { return .failure(.duplicateArgument(intent: target, name: param.name)) }
        }

        for (name, value) in invocation.arguments.sorted(by: { $0.key < $1.key }) {
            guard let param = parameter(for: name) else {
                if migration.retires(intent: target, parameter: name) {
                    notes.append("Dropped retired argument \(name)")
                    continue
                }
                return .failure(.unknownArgument(intent: target, name: name))
            }
            guard supplied.insert(param.name).inserted else { return .failure(.duplicateArgument(intent: target, name: param.name)) }
            if param.name != name { notes.append("Mapped \(name) → \(param.name)") }
            switch conform(value, to: param.type, intent: target, parameter: param.name) {
            case .success(let (converted, conversionNotes)):
                resolved[param.name] = converted
                notes += conversionNotes
            case .failure(let failure):
                return .failure(failure)
            }
        }

        for param in schema.parameters where param.isRequired && !supplied.contains(param.name) {
            guard let backfill = migration.backfill(intent: target, parameter: param.name) else {
                return .failure(.missingArgument(intent: target, name: param.name))
            }
            switch conform(backfill.value, to: param.type, intent: target, parameter: param.name) {
            case .success(let (converted, _)):
                resolved[param.name] = converted
                notes.append("Backfilled \(param.name) = \(converted)")
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .success(ResolvedInvocation(intent: target, aliasHops: hops, arguments: resolved, notes: notes))
    }

    private func conform(_ value: ArgumentValue, to type: ValueType, intent: String, parameter: String) -> Result<(ArgumentValue, [String]), ResolutionFailure> {
        let mismatch = ResolutionFailure.typeMismatch(intent: intent, name: parameter, expected: type, got: value.description)
        switch (value, type) {
        case (.string, .string), (.integer, .integer), (.decimal, .decimal), (.boolean, .boolean):
            return .success((value, []))
        case (.integer(let number), .decimal):
            return .success((.decimal(Double(number)), []))
        case let (.enumCase(name), .enumeration(enumID)):
            guard let schema = enums[enumID] else { return .failure(mismatch) }
            guard schema.cases.contains(name) else { return .failure(.unknownEnumCase(enumeration: enumID, value: name)) }
            return .success((value, []))
        case let (.entity(recordedType, id), .entity(expected)):
            guard let live = entityAliases[recordedType] else { return .failure(.unknownEntity(recordedType)) }
            guard live == (entityAliases[expected] ?? expected), let schema = entities[live] else { return .failure(mismatch) }
            if schema.idFormat.matches(id) { return .success((.entity(type: live, id: id), [])) }
            guard let shim = migration.shim(for: live, accepting: id),
                  let migrated = shim.migrate(id), schema.idFormat.matches(migrated) else {
                return .failure(.entityIDUnresolvable(entity: live, id: id))
            }
            return .success((.entity(type: live, id: migrated), ["Migrated \(live) id \(id) → \(migrated)"]))
        case let (.list(values), .list(element)):
            var converted: [ArgumentValue] = []
            var notes: [String] = []
            for item in values {
                switch conform(item, to: element, intent: intent, parameter: parameter) {
                case .success(let (value, more)): converted.append(value); notes += more
                case .failure(let failure): return .failure(failure)
                }
            }
            return .success((.list(converted), notes))
        default:
            return .failure(mismatch)
        }
    }
}
