import Foundation

/// Structural problems that make a surface unsafe to publish, independent of
/// what changed since the last release.
public enum SurfaceIssue: Hashable, Sendable, CustomStringConvertible {
    case invalidIdentifier(String)
    case duplicateIntent(String)
    case duplicateEntity(String)
    case duplicateEnum(String)
    case duplicateParameter(intent: String, name: String)
    case duplicateAlias(String)
    case aliasShadowsLiveIntent(String)
    case aliasDangling(String)
    case aliasCycle([String])
    case unknownEntityReference(context: String, entity: String)
    case unknownEnumReference(context: String, enumeration: String)
    case emptyEnum(String)
    case deprecationWindowInverted(String)
    case deprecationReplacementUnknown(intent: String, replacement: String)

    public var description: String {
        switch self {
        case .invalidIdentifier(let id): return "Invalid identifier '\(id)'"
        case .duplicateIntent(let id): return "Intent '\(id)' is declared twice"
        case .duplicateEntity(let id): return "Entity '\(id)' is declared twice"
        case .duplicateEnum(let id): return "Enum '\(id)' is declared twice"
        case let .duplicateParameter(intent, name): return "\(intent): parameter name '\(name)' is used twice (including former names)"
        case .duplicateAlias(let id): return "Alias '\(id)' is declared twice"
        case .aliasShadowsLiveIntent(let id): return "Alias '\(id)' has the same name as a live intent"
        case .aliasDangling(let id): return "Alias '\(id)' does not lead to a live intent"
        case .aliasCycle(let path): return "Alias cycle: \(path.joined(separator: " → "))"
        case let .unknownEntityReference(context, entity): return "\(context) references unknown entity '\(entity)'"
        case let .unknownEnumReference(context, enumeration): return "\(context) references unknown enum '\(enumeration)'"
        case .emptyEnum(let id): return "Enum '\(id)' has no cases"
        case .deprecationWindowInverted(let id): return "\(id): removal version must be after the deprecation version"
        case let .deprecationReplacementUnknown(intent, replacement): return "\(intent): replacement '\(replacement)' is not a live intent"
        }
    }
}

public enum SurfaceValidator {
    /// Identifiers are persisted by the system and by agents, so keep them to
    /// a conservative alphabet.
    static func isValidIdentifier(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == ".")
        }
    }

    public static func validate(_ surface: IntentSurface) -> [SurfaceIssue] {
        var issues: [SurfaceIssue] = []
        let entityIDs = Set(surface.entityAliasMap.keys)
        let enumIDs = Set(surface.enums.map(\.identifier))
        let liveIntents = Set(surface.intents.map(\.identifier))

        func checkType(_ type: ValueType, context: String) {
            switch type {
            case .entity(let name) where !entityIDs.contains(name):
                issues.append(.unknownEntityReference(context: context, entity: name))
            case .enumeration(let name) where !enumIDs.contains(name):
                issues.append(.unknownEnumReference(context: context, enumeration: name))
            case .list(let element):
                checkType(element, context: context)
            default:
                break
            }
        }

        var seenIntents: Set<String> = []
        for intent in surface.intents {
            if !isValidIdentifier(intent.identifier) { issues.append(.invalidIdentifier(intent.identifier)) }
            if !seenIntents.insert(intent.identifier).inserted { issues.append(.duplicateIntent(intent.identifier)) }
            var names: Set<String> = []
            for parameter in intent.parameters {
                for name in [parameter.name] + parameter.formerNames {
                    if !isValidIdentifier(name) { issues.append(.invalidIdentifier("\(intent.identifier).\(name)")) }
                    if !names.insert(name).inserted { issues.append(.duplicateParameter(intent: intent.identifier, name: name)) }
                }
                checkType(parameter.type, context: "\(intent.identifier).\(parameter.name)")
            }
            if let result = intent.result { checkType(result, context: "\(intent.identifier) result") }
            if let deprecation = intent.deprecation {
                if !(deprecation.since < deprecation.removalNotBefore) { issues.append(.deprecationWindowInverted(intent.identifier)) }
                if let replacement = deprecation.replacement, !liveIntents.contains(replacement) {
                    issues.append(.deprecationReplacementUnknown(intent: intent.identifier, replacement: replacement))
                }
            }
        }

        var seenEntities: Set<String> = []
        for entity in surface.entities {
            if !isValidIdentifier(entity.identifier) { issues.append(.invalidIdentifier(entity.identifier)) }
            if !seenEntities.insert(entity.identifier).inserted { issues.append(.duplicateEntity(entity.identifier)) }
            if case .prefixed(let prefix) = entity.idFormat,
               prefix.isEmpty || prefix.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) {
                issues.append(.invalidIdentifier("\(entity.identifier) id prefix '\(prefix)'"))
            }
            for former in entity.formerIdentifiers where !isValidIdentifier(former) {
                issues.append(.invalidIdentifier(former))
            }
            for property in entity.properties {
                if !isValidIdentifier(property.name) { issues.append(.invalidIdentifier("\(entity.identifier).\(property.name)")) }
                checkType(property.type, context: "\(entity.identifier).\(property.name)")
            }
        }

        var seenEnums: Set<String> = []
        for enumeration in surface.enums {
            if !isValidIdentifier(enumeration.identifier) { issues.append(.invalidIdentifier(enumeration.identifier)) }
            if !seenEnums.insert(enumeration.identifier).inserted { issues.append(.duplicateEnum(enumeration.identifier)) }
            if enumeration.cases.isEmpty { issues.append(.emptyEnum(enumeration.identifier)) }
            for value in enumeration.cases where !isValidIdentifier(value) {
                issues.append(.invalidIdentifier("\(enumeration.identifier).\(value)"))
            }
        }

        var seenAliases: Set<String> = []
        var reportedCycles: Set<Set<String>> = []
        for alias in surface.aliases {
            if !isValidIdentifier(alias.from) { issues.append(.invalidIdentifier(alias.from)) }
            if !seenAliases.insert(alias.from).inserted { issues.append(.duplicateAlias(alias.from)) }
            if liveIntents.contains(alias.from) { issues.append(.aliasShadowsLiveIntent(alias.from)); continue }
            switch surface.resolveIntent(alias.from) {
            case .live:
                break
            case .unknown, .dangling:
                issues.append(.aliasDangling(alias.from))
            case .cycle(let path):
                // Every member of a cycle reports the same loop; keep one.
                if reportedCycles.insert(Set(path)).inserted { issues.append(.aliasCycle(path)) }
            }
        }
        return issues
    }
}
