import Foundation

/// Arithmetic that cannot trap. Version components come from files that a
/// human (or an agent) edits, so "Int.max" is a reachable input, not a theory.
enum Saturating {
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs > 0 ? Int.max : Int.min
    }
}

/// How far a version moved between two releases of the intent surface.
public enum BumpLevel: Int, Comparable, Sendable, CustomStringConvertible {
    case none = 0
    case patch = 1
    case minor = 2
    case major = 3

    public static func < (lhs: BumpLevel, rhs: BumpLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .none: return "none"
        case .patch: return "patch"
        case .minor: return "minor"
        case .major: return "major"
        }
    }
}

/// A `MAJOR.MINOR.PATCH` version of the published intent surface.
///
/// Encoded as the string `"1.2.3"` so a committed snapshot stays human-diffable.
/// Pre-release and build metadata are deliberately unsupported: an intent
/// surface ships inside an app binary, so there is no "1.2.0-beta" of it that a
/// Shortcut could have been recorded against.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Negative components are clamped to zero rather than trapping or failing:
    /// this initializer exists for fixtures and literals.
    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    /// Strict parser: exactly three dot-separated, non-empty, ASCII-digit
    /// components that fit in `Int`. Anything else returns `nil`.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        guard values.count == 3 else { return nil }
        self.init(values[0], values[1], values[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The smallest version that satisfies `level` relative to `self`.
    /// Saturates at `Int.max` instead of overflowing.
    public func bumped(_ level: BumpLevel) -> SemanticVersion {
        switch level {
        case .none: return self
        case .patch: return SemanticVersion(major, minor, Saturating.add(patch, 1))
        case .minor: return SemanticVersion(major, Saturating.add(minor, 1), 0)
        case .major: return SemanticVersion(Saturating.add(major, 1), 0, 0)
        }
    }

    /// The bump that took `old` to `self`, or `nil` if `self` went backwards.
    public func bumpLevel(from old: SemanticVersion) -> BumpLevel? {
        if self < old { return nil }
        if major > old.major { return .major }
        if minor > old.minor { return .minor }
        if patch > old.patch { return .patch }
        return BumpLevel.none
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = SemanticVersion(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a MAJOR.MINOR.PATCH version: \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
