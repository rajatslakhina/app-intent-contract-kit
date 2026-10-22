import Foundation

/// The type of an intent parameter, an intent result or an entity property,
/// as a *caller* sees it. Siri, Shortcuts and agents never see your Swift
/// types; they see this.
public indirect enum ValueType: Hashable, Sendable, Codable, CustomStringConvertible {
    case string
    case integer
    case decimal
    case boolean
    /// An `AppEntity`, by its stable type identifier.
    case entity(String)
    /// An `AppEnum`, by its stable type identifier.
    case enumeration(String)
    case list(ValueType)

    public var description: String {
        switch self {
        case .string: return "String"
        case .integer: return "Int"
        case .decimal: return "Decimal"
        case .boolean: return "Bool"
        case .entity(let name): return "Entity<\(name)>"
        case .enumeration(let name): return "Enum<\(name)>"
        case .list(let element): return "[\(element)]"
        }
    }

    /// Whether a value recorded as `older` is still a valid `self`.
    /// `entityAliases` maps a former entity identifier to its live identifier.
    public func accepts(_ older: ValueType, entityAliases: [String: String] = [:]) -> Bool {
        switch (older, self) {
        case let (a, b) where a == b:
            return true
        case (.integer, .decimal):
            return true
        case let (.entity(old), .entity(new)):
            // Either side may be spelled with a former identifier.
            guard let liveOld = entityAliases[old] else { return false }
            return liveOld == (entityAliases[new] ?? new)
        case let (.list(old), .list(new)):
            return new.accepts(old, entityAliases: entityAliases)
        default:
            return false
        }
    }

    /// Whether a value *produced* as `new` can still be consumed by code that
    /// was written for `old` (results and readable properties are covariant).
    public static func isCovariant(old: ValueType, new: ValueType, entityAliases: [String: String]) -> Bool {
        switch (old, new) {
        case let (a, b) where a == b:
            return true
        case (.decimal, .integer):
            return true
        case let (.entity(oldName), .entity(newName)):
            guard let liveOld = entityAliases[oldName] else { return false }
            return liveOld == (entityAliases[newName] ?? newName)
        case let (.list(oldElement), .list(newElement)):
            return isCovariant(old: oldElement, new: newElement, entityAliases: entityAliases)
        default:
            return false
        }
    }
}

/// How an `AppEntity` encodes its identifier. Shortcuts and agent plans store
/// these strings, so the format *is* the contract.
public enum EntityIDFormat: Hashable, Sendable, Codable, CustomStringConvertible {
    case uuid
    case integer
    case prefixed(String)
    case opaque

    public var description: String {
        switch self {
        case .uuid: return "uuid"
        case .integer: return "integer"
        case .prefixed(let prefix): return "prefixed(\(prefix))"
        case .opaque: return "opaque"
        }
    }

    /// Whether `id` is a well-formed identifier in this format.
    public func matches(_ id: String) -> Bool {
        switch self {
        case .opaque:
            return !id.isEmpty
        case .integer:
            return !id.isEmpty && id.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        case .prefixed(let prefix):
            guard !prefix.isEmpty, id.hasPrefix(prefix) else { return false }
            return id.count > prefix.count
        case .uuid:
            return UUID(uuidString: id) != nil && id.count == 36
        }
    }
}

public struct ParameterSchema: Hashable, Sendable, Codable {
    public var name: String
    public var type: ValueType
    public var isOptional: Bool
    public var hasDefault: Bool
    /// Names this parameter was published under before. Old Shortcuts and
    /// agent plans that still use them keep resolving.
    public var formerNames: [String]

    public init(_ name: String, _ type: ValueType, optional: Bool = false, hasDefault: Bool = false, formerNames: [String] = []) {
        self.name = name
        self.type = type
        self.isOptional = optional
        self.hasDefault = hasDefault
        self.formerNames = formerNames
    }

    /// A caller may omit this parameter.
    public var isRequired: Bool { !isOptional && !hasDefault }
}

public struct Deprecation: Hashable, Sendable, Codable {
    public var since: SemanticVersion
    /// The first surface version allowed to delete the intent.
    public var removalNotBefore: SemanticVersion
    public var replacement: String?

    public init(since: SemanticVersion, removalNotBefore: SemanticVersion, replacement: String? = nil) {
        self.since = since
        self.removalNotBefore = removalNotBefore
        self.replacement = replacement
    }
}

public struct IntentSchema: Hashable, Sendable, Codable {
    /// Stable identifier. In an app this is the `AppIntent` type's persistent
    /// identifier, which is what a saved Shortcut points at.
    public var identifier: String
    public var title: String
    public var parameters: [ParameterSchema]
    public var result: ValueType?
    public var deprecation: Deprecation?

    public init(_ identifier: String, title: String, parameters: [ParameterSchema] = [], result: ValueType? = nil, deprecation: Deprecation? = nil) {
        self.identifier = identifier
        self.title = title
        self.parameters = parameters
        self.result = result
        self.deprecation = deprecation
    }
}

public struct PropertySchema: Hashable, Sendable, Codable {
    public var name: String
    public var type: ValueType
    public init(_ name: String, _ type: ValueType) {
        self.name = name
        self.type = type
    }
}

public struct EntitySchema: Hashable, Sendable, Codable {
    public var identifier: String
    public var idFormat: EntityIDFormat
    public var properties: [PropertySchema]
    public var formerIdentifiers: [String]

    public init(_ identifier: String, idFormat: EntityIDFormat, properties: [PropertySchema] = [], formerIdentifiers: [String] = []) {
        self.identifier = identifier
        self.idFormat = idFormat
        self.properties = properties
        self.formerIdentifiers = formerIdentifiers
    }
}

public struct EnumSchema: Hashable, Sendable, Codable {
    public var identifier: String
    public var cases: [String]
    public init(_ identifier: String, cases: [String]) {
        self.identifier = identifier
        self.cases = cases
    }
}

/// A record that an intent identifier used to exist. Meant to be append-only:
/// `SchemaDiffer` reports deleting a row as a breaking change. `to` may
/// itself be a former identifier, so renames chain: v1 `OpenNote` → v2
/// `ShowNote` → v3 `OpenDocument` needs no edit to the v1 row.
public struct IntentAlias: Hashable, Sendable, Codable {
    public var from: String
    public var to: String
    public var since: SemanticVersion
    public init(from: String, to: String, since: SemanticVersion) {
        self.from = from
        self.to = to
        self.since = since
    }
}

/// The complete, versioned surface an app publishes to Siri, Shortcuts,
/// Spotlight and agents. This is the thing under contract.
public struct IntentSurface: Hashable, Sendable, Codable {
    public var version: SemanticVersion
    public var intents: [IntentSchema]
    public var entities: [EntitySchema]
    public var enums: [EnumSchema]
    public var aliases: [IntentAlias]

    public init(version: SemanticVersion, intents: [IntentSchema] = [], entities: [EntitySchema] = [], enums: [EnumSchema] = [], aliases: [IntentAlias] = []) {
        self.version = version
        self.intents = intents
        self.entities = entities
        self.enums = enums
        self.aliases = aliases
    }

    // MARK: Lookups (never trap on duplicates: first declaration wins, and the
    // validator reports the duplicate separately)

    public var intentsByID: [String: IntentSchema] {
        Dictionary(intents.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var entitiesByID: [String: EntitySchema] {
        Dictionary(entities.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var enumsByID: [String: EnumSchema] {
        Dictionary(enums.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Former entity identifier → live entity identifier. Live identifiers
    /// map to themselves so callers can look up either form.
    public var entityAliasMap: [String: String] {
        var map: [String: String] = [:]
        for entity in entities {
            if map[entity.identifier] == nil { map[entity.identifier] = entity.identifier }
        }
        for entity in entities {
            for former in entity.formerIdentifiers where map[former] == nil {
                map[former] = entity.identifier
            }
        }
        return map
    }

    /// Follows the alias table from `identifier` to a live intent.
    ///
    /// Bounded: at most `aliases.count + 1` hops, with an explicit visited set,
    /// so a corrupted table (a cycle) is reported instead of hanging the app
    /// at the moment Siri invokes it.
    public func resolveIntent(_ identifier: String) -> IntentLookup {
        let live = intentsByID
        if live[identifier] != nil { return .live(identifier, hops: []) }
        let table = Dictionary(aliases.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
        var current = identifier
        var visited: [String] = [identifier]
        var seen: Set<String> = [identifier]
        for _ in 0...aliases.count {
            guard let next = table[current] else {
                // `identifier` is an alias, but the chain stops at a name that
                // is neither live nor aliased onward.
                return current == identifier ? .unknown(identifier) : .dangling(visited)
            }
            if live[next] != nil { return .live(next, hops: visited) }
            if seen.contains(next) { return .cycle(visited + [next]) }
            seen.insert(next)
            visited.append(next)
            current = next
        }
        return .cycle(visited)
    }
}

public enum IntentLookup: Hashable, Sendable {
    /// Resolved to a live intent; `hops` are the former identifiers walked.
    case live(String, hops: [String])
    case unknown(String)
    /// An alias chain that ends at a name which no longer exists.
    case dangling([String])
    case cycle([String])
}
