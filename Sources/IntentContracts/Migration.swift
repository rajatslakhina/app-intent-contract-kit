import Foundation

/// Rewrites a stored entity identifier from a retired format to the live one.
///
/// This runs inside the app when Siri replays a Shortcut saved two releases
/// ago, so it must be total over the legacy IDs that exist, injective (two old
/// notes must never become one new note), and land on IDs that actually exist.
/// `IDStabilityAudit` checks all three before the gate accepts a shim.
public protocol EntityIDShim: Sendable {
    var entity: String { get }
    var from: EntityIDFormat { get }
    var to: EntityIDFormat { get }
    func migrate(_ legacyID: String) -> String?
}

/// `42` → `note-42`. The common case when an app moves from database row IDs
/// to namespaced IDs.
public struct PrefixingShim: EntityIDShim {
    public let entity: String
    public let prefix: String
    public var from: EntityIDFormat { .integer }
    public var to: EntityIDFormat { .prefixed(prefix) }

    public init(entity: String, prefix: String) {
        self.entity = entity
        self.prefix = prefix
    }

    public func migrate(_ legacyID: String) -> String? {
        guard from.matches(legacyID) else { return nil }
        return prefix + legacyID
    }
}

/// An explicit old → new table, for when the new IDs were minted (e.g. UUIDs
/// assigned during a storage migration) and only the migration knows the pairing.
public struct LookupTableShim: EntityIDShim {
    public let entity: String
    public let from: EntityIDFormat
    public let to: EntityIDFormat
    public let table: [String: String]

    public init(entity: String, from: EntityIDFormat, to: EntityIDFormat, table: [String: String]) {
        self.entity = entity
        self.from = from
        self.to = to
        self.table = table
    }

    public func migrate(_ legacyID: String) -> String? { table[legacyID] }
}

/// Supplies a value for a parameter that became required, so an old caller
/// that never sent it still resolves.
public struct ArgumentBackfill: Hashable, Sendable {
    public var intent: String
    public var parameter: String
    public var value: ArgumentValue
    public init(intent: String, parameter: String, value: ArgumentValue) {
        self.intent = intent
        self.parameter = parameter
        self.value = value
    }
}

/// Accepts and drops a parameter that no longer exists, instead of failing
/// the invocation.
public struct ParameterRetirement: Hashable, Sendable {
    public var intent: String
    public var parameter: String
    public init(intent: String, parameter: String) {
        self.intent = intent
        self.parameter = parameter
    }
}

/// A break the team chose to ship anyway, with a named owner. Only honoured
/// on a major version bump, and never with a blank justification.
public struct AcceptedBreak: Hashable, Sendable {
    public var key: String
    public var justification: String
    public var approver: String
    public init(key: String, justification: String, approver: String) {
        self.key = key
        self.justification = justification
        self.approver = approver
    }

    var isSigned: Bool {
        !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !approver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Everything a release declares to keep old callers working.
///
/// The same value is read by the CI gate *and* by the runtime resolver. That is
/// the point: the shim that passes review is, by construction, the shim that
/// runs when Siri replays a two-year-old Shortcut.
public struct MigrationPlan: Sendable {
    public var idShims: [any EntityIDShim]
    public var backfills: [ArgumentBackfill]
    public var retiredParameters: [ParameterRetirement]
    public var acceptedBreaks: [AcceptedBreak]
    /// Real legacy IDs to audit each shim against (sampled from storage in a
    /// real pipeline), keyed by entity.
    public var legacyIDSamples: [String: [String]]
    /// The IDs that exist after the data migration, keyed by entity.
    public var liveIDSamples: [String: Set<String>]

    public init(idShims: [any EntityIDShim] = [],
                backfills: [ArgumentBackfill] = [],
                retiredParameters: [ParameterRetirement] = [],
                acceptedBreaks: [AcceptedBreak] = [],
                legacyIDSamples: [String: [String]] = [:],
                liveIDSamples: [String: Set<String>] = [:]) {
        self.idShims = idShims
        self.backfills = backfills
        self.retiredParameters = retiredParameters
        self.acceptedBreaks = acceptedBreaks
        self.legacyIDSamples = legacyIDSamples
        self.liveIDSamples = liveIDSamples
    }

    public static let none = MigrationPlan()

    func shim(for entity: String, accepting id: String) -> (any EntityIDShim)? {
        idShims.first { $0.entity == entity && $0.from.matches(id) }
    }

    func backfill(intent: String, parameter: String) -> ArgumentBackfill? {
        backfills.first { $0.intent == intent && $0.parameter == parameter }
    }

    func retires(intent: String, parameter: String) -> Bool {
        retiredParameters.contains { $0.intent == intent && $0.parameter == parameter }
    }

    func signedBreak(_ key: String) -> AcceptedBreak? {
        acceptedBreaks.first { $0.key == key && $0.isSigned }
    }
}

// MARK: - ID stability

public struct IDStabilityReport: Hashable, Sendable {
    public var entity: String
    public var sampled: Int
    /// Legacy IDs the shim returned `nil` for: Shortcuts that silently die.
    public var unmapped: [String]
    /// Mapped to a well-formed ID that does not exist after migration.
    public var orphaned: [String]
    /// Output not in the live format.
    public var malformed: [String]
    /// Several legacy IDs mapped to one new ID: "open my note" opens someone else's.
    public var collisions: [String: [String]]

    public var isStable: Bool {
        sampled > 0 && unmapped.isEmpty && orphaned.isEmpty && malformed.isEmpty && collisions.isEmpty
    }
}

public enum IDStabilityAudit {
    /// Audits a shim against real legacy IDs. An empty sample is reported as
    /// unstable on purpose: an unverified shim must not pass the gate.
    public static func run(_ shim: any EntityIDShim, legacyIDs: [String], liveIDs: Set<String>) -> IDStabilityReport {
        var unmapped: [String] = []
        var orphaned: [String] = []
        var malformed: [String] = []
        var owners: [String: [String]] = [:]
        let unique = Array(Set(legacyIDs)).sorted()
        for legacy in unique {
            guard let migrated = shim.migrate(legacy) else { unmapped.append(legacy); continue }
            if !shim.to.matches(migrated) { malformed.append(legacy); continue }
            if !liveIDs.contains(migrated) { orphaned.append(legacy) }
            owners[migrated, default: []].append(legacy)
        }
        let collisions = owners.filter { $0.value.count > 1 }
        return IDStabilityReport(entity: shim.entity, sampled: unique.count, unmapped: unmapped, orphaned: orphaned, malformed: malformed, collisions: collisions)
    }
}
