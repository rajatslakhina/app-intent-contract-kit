import Foundation

/// A deterministic, line-oriented rendering of an `IntentSurface`.
///
/// Why not `JSONEncoder(.sortedKeys)`: the JSON output depends on the
/// Foundation implementation (slash escaping, number formatting, and the
/// shape synthesized `Codable` picks for enums with payloads), so the same
/// surface could fingerprint differently on a developer's Mac and a Linux CI
/// runner. A hand-written canonical form is boring and identical everywhere,
/// and it doubles as a readable diff in code review.
public enum CanonicalForm {
    public static func lines(of surface: IntentSurface) -> [String] {
        var out: [String] = ["surface \(surface.version)"]

        for entity in surface.entities.sorted(by: { $0.identifier < $1.identifier }) {
            out.append("entity \(entity.identifier) id=\(escape(entity.idFormat.description)) former=[\(entity.formerIdentifiers.sorted().joined(separator: ","))]")
            for property in entity.properties.sorted(by: { $0.name < $1.name }) {
                out.append("  prop \(property.name): \(property.type)")
            }
        }
        for enumeration in surface.enums.sorted(by: { $0.identifier < $1.identifier }) {
            out.append("enum \(enumeration.identifier)")
            for value in enumeration.cases.sorted() {
                out.append("  case \(escape(value))")
            }
        }
        for intent in surface.intents.sorted(by: { $0.identifier < $1.identifier }) {
            out.append("intent \(intent.identifier) \"\(escape(intent.title))\" -> \(intent.result.map(\.description) ?? "Void")")
            for parameter in intent.parameters.sorted(by: { $0.name < $1.name }) {
                let optional = parameter.isOptional ? "?" : ""
                let fallback = parameter.hasDefault ? "=default" : ""
                out.append("  param \(parameter.name): \(parameter.type)\(optional)\(fallback) former=[\(parameter.formerNames.sorted().joined(separator: ","))]")
            }
            if let deprecation = intent.deprecation {
                out.append("  deprecated since=\(deprecation.since) removal>=\(deprecation.removalNotBefore) replacement=\(deprecation.replacement ?? "-")")
            }
        }
        for alias in surface.aliases.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            out.append("alias \(alias.from) -> \(alias.to) since=\(alias.since)")
        }
        return out
    }

    public static func text(of surface: IntentSurface) -> String {
        lines(of: surface).joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            default: result.append(character)
            }
        }
        return result
    }
}

/// Produces a stable fingerprint for a surface. Injected so the drift check
/// can be tested against a deliberately broken implementation.
public protocol SurfaceFingerprinting: Sendable {
    func fingerprint(_ surface: IntentSurface) -> String
}

/// 64-bit FNV-1a over the UTF-8 of `CanonicalForm.text`.
///
/// Not `Hasher`: `Hasher` is randomly seeded per process, so a fingerprint
/// committed from one run would never match the next. Not cryptographic either,
/// and it does not need to be: the threat is "someone changed an intent and
/// forgot to regenerate the snapshot", not an adversary forging collisions.
public struct CanonicalFingerprinter: SurfaceFingerprinting {
    public init() {}

    public func fingerprint(_ surface: IntentSurface) -> String {
        Self.fnv1a64(CanonicalForm.text(of: surface))
    }

    static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3   // wrapping multiply is the algorithm, not an accident
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

/// The file a team commits next to its intents (e.g. `IntentSurface.snapshot.json`).
public struct CommittedSnapshot: Hashable, Sendable, Codable {
    public var version: SemanticVersion
    public var fingerprint: String
    public var canonicalLines: [String]

    public init(surface: IntentSurface, fingerprinter: any SurfaceFingerprinting = CanonicalFingerprinter()) {
        self.version = surface.version
        self.fingerprint = fingerprinter.fingerprint(surface)
        self.canonicalLines = CanonicalForm.lines(of: surface)
    }

    /// Compares the committed snapshot with the surface the code declares now.
    public func drift(against surface: IntentSurface, fingerprinter: any SurfaceFingerprinting = CanonicalFingerprinter()) -> SnapshotDrift {
        let current = fingerprinter.fingerprint(surface)
        guard current != fingerprint else { return .clean }
        let now = CanonicalForm.lines(of: surface)
        let before = Set(canonicalLines)
        let after = Set(now)
        return .drifted(
            committed: fingerprint,
            current: current,
            added: now.filter { !before.contains($0) },
            removed: canonicalLines.filter { !after.contains($0) }
        )
    }
}

public enum SnapshotDrift: Hashable, Sendable {
    case clean
    case drifted(committed: String, current: String, added: [String], removed: [String])

    public var isClean: Bool { self == .clean }
}
