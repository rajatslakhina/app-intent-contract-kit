import Foundation

/// How a breaking change is (or is not) made safe for existing callers.
public enum Coverage: Hashable, Sendable, CustomStringConvertible {
    case notRequired
    case scheduledRemoval
    case idShim(stable: Bool)
    case backfill
    case retirement
    case acceptedBreak(approver: String)
    case uncovered

    public var description: String {
        switch self {
        case .notRequired: return "no migration needed"
        case .scheduledRemoval: return "deprecation window honoured"
        case .idShim(let stable): return stable ? "ID shim, audit passed" : "ID shim, audit FAILED"
        case .backfill: return "backfilled for old callers"
        case .retirement: return "old argument accepted and dropped"
        case .acceptedBreak(let approver): return "accepted break, signed by \(approver)"
        case .uncovered: return "NOT covered"
        }
    }
}

public struct AssessedChange: Hashable, Sendable {
    public var change: ContractChange
    public var coverage: Coverage
}

public struct PlanComparison: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Replays identically.
        case unaffected
        /// Replays only because the compatibility layer stepped in.
        case rescued
        /// Breaks, but on a change the release explicitly owns on a major bump.
        case acceptedBreak
        /// Worked before, fails now, and nothing excuses it.
        case regressed
        /// Already failed against the baseline; not this release's doing.
        case alreadyBroken
    }
    public var id: String { name }
    public var name: String
    public var origin: String
    public var recordedAgainst: SemanticVersion
    public var before: PlanReplay
    public var after: PlanReplay
    public var status: Status
}

public enum GateFinding: Hashable, Sendable, CustomStringConvertible {
    case surfaceInvalid(SurfaceIssue)
    case versionRegressed(from: SemanticVersion, to: SemanticVersion)
    case insufficientBump(required: BumpLevel, declared: BumpLevel)
    case uncoveredBreak(ContractChange)
    case acceptedBreakNeedsMajor(String)
    case unstableIDShim(IDStabilityReport)
    case planRegressed(plan: String, step: Int, failure: ResolutionFailure)

    public var description: String {
        switch self {
        case .surfaceInvalid(let issue): return "Invalid surface: \(issue)"
        case let .versionRegressed(from, to): return "Version went backwards: \(from) → \(to)"
        case let .insufficientBump(required, declared): return "Changes need a \(required) bump; the release declares \(declared)"
        case .uncoveredBreak(let change): return "Breaking change with no migration: \(change)"
        case .acceptedBreakNeedsMajor(let key): return "Accepted break \(key) is only honoured on a major release"
        case .unstableIDShim(let report):
            if report.sampled == 0 { return "\(report.entity) ID shim was never audited against real IDs" }
            return "\(report.entity) ID shim is unsafe: \(report.unmapped.count) unmapped, \(report.orphaned.count) orphaned, \(report.malformed.count) malformed, \(report.collisions.count) collisions"
        case let .planRegressed(plan, step, failure): return "\"\(plan)\" breaks at step \(Saturating.add(step, 1)): \(failure)"
        }
    }
}

public struct GateReport: Sendable {
    public var baselineVersion: SemanticVersion
    public var proposedVersion: SemanticVersion
    public var changes: [AssessedChange]
    public var requiredBump: BumpLevel
    public var declaredBump: BumpLevel?
    public var idAudits: [IDStabilityReport]
    public var plans: [PlanComparison]
    public var findings: [GateFinding]

    public var passed: Bool { findings.isEmpty }
    public var highestImpact: ChangeImpact? { changes.map(\.change.impact).max() }
}

/// The CI gate. Three independent checks, any of which blocks a release:
///
/// 1. **Classification** – every change is diffed and the declared semantic
///    version must be at least what the worst change demands.
/// 2. **Coverage** – every breaking change is either a scheduled removal, or
///    carries an executable shim (ID shim, backfill, retirement), or a signed
///    break-glass on a major release. ID shims are audited against real IDs.
/// 3. **Replay** – every recorded Shortcut and agent plan that worked against
///    the baseline must still work against the proposal *through the same
///    migration plan the app ships*.
///
/// Check 3 does not trust check 1. If the differ misses a break, the replay
/// still catches it; that is tested with a deliberately lying differ.
public struct ContractGate: Sendable {
    public let differ: any SurfaceDiffing

    public init(differ: any SurfaceDiffing = SchemaDiffer()) {
        self.differ = differ
    }

    /// - Parameters:
    ///   - baselineMigration: the compatibility layer the *published* release
    ///     ships. "Worked before" means worked through it, and anything it did
    ///     that `migration` no longer does is a breaking change.
    public func evaluate(baseline: IntentSurface, proposed: IntentSurface, baselineMigration: MigrationPlan = .none, migration: MigrationPlan = .none, plans: [AgentPlan] = []) -> GateReport {
        var findings: [GateFinding] = SurfaceValidator.validate(proposed).map(GateFinding.surfaceInvalid)

        let declared = proposed.version.bumpLevel(from: baseline.version)
        if declared == nil { findings.append(.versionRegressed(from: baseline.version, to: proposed.version)) }
        let isMajor = declared == .major

        var assessed: [AssessedChange] = []
        var audits: [IDStabilityReport] = []
        var excusedKeys: Set<String> = []

        for change in differ.diff(from: baseline, to: proposed) + Self.droppedMigrations(from: baselineMigration, to: migration) {
            guard change.impact == .breaking else {
                assessed.append(AssessedChange(change: change, coverage: .notRequired))
                continue
            }
            let coverage = cover(change, migration: migration, audits: &audits)
            switch coverage {
            case .uncovered:
                findings.append(.uncoveredBreak(change))
            case .idShim(stable: false):
                if let report = audits.last { findings.append(.unstableIDShim(report)) }
            case .acceptedBreak:
                if !isMajor, let key = change.key { findings.append(.acceptedBreakNeedsMajor(key)) }
                if let key = change.key { excusedKeys.insert(key) }
            case .scheduledRemoval:
                if let key = change.key { excusedKeys.insert(key) }
            default:
                break
            }
            assessed.append(AssessedChange(change: change, coverage: coverage))
        }

        // Every shim the release ships is audited, not only one introduced
        // alongside a format change: a lossy shim swapped in later is the
        // "open my note opens someone else's" failure.
        let audited = Set(audits.map(\.entity))
        for shim in migration.idShims where !audited.contains(shim.entity) {
            let report = IDStabilityAudit.run(shim,
                                              legacyIDs: migration.legacyIDSamples[shim.entity] ?? [],
                                              liveIDs: migration.liveIDSamples[shim.entity] ?? [])
            audits.append(report)
            if !report.isStable { findings.append(.unstableIDShim(report)) }
        }

        let required = assessed.map(\.change.impact.requiredBump).max() ?? BumpLevel.none
        if let declared, declared < required {
            findings.append(.insufficientBump(required: required, declared: declared))
        }

        let oldResolver = IntentResolver(surface: baseline, migration: baselineMigration)
        let newResolver = IntentResolver(surface: proposed, migration: migration)
        var comparisons: [PlanComparison] = []
        for plan in plans {
            let before = PlanReplayer.replay(plan, with: oldResolver)
            let after = PlanReplayer.replay(plan, with: newResolver)
            let status: PlanComparison.Status
            if !before.succeeded {
                status = .alreadyBroken
            } else if let first = after.firstFailure {
                // `before` succeeded, so the plan has steps; an empty `after` is impossible.
                let excused = isMajor && first.failure.relatedChangeKeys.contains(where: excusedKeys.contains)
                status = excused ? .acceptedBreak : .regressed
                if !excused { findings.append(.planRegressed(plan: plan.name, step: first.step, failure: first.failure)) }
            } else {
                // "Rescued" means the compatibility layer did something *new* in
                // this release; an alias that already applied to the baseline
                // does not count.
                let touched = Self.compatibilityNotes(after) != Self.compatibilityNotes(before)
                status = touched ? .rescued : .unaffected
            }
            comparisons.append(PlanComparison(name: plan.name, origin: plan.origin, recordedAgainst: plan.recordedAgainst, before: before, after: after, status: status))
        }

        return GateReport(baselineVersion: baseline.version,
                          proposedVersion: proposed.version,
                          changes: assessed,
                          requiredBump: required,
                          declaredBump: declared,
                          idAudits: audits,
                          plans: comparisons,
                          findings: findings)
    }

    /// Shims, backfills and retirements the published release had and the
    /// proposal no longer has. Not part of `SurfaceDiffing`: it compares
    /// migration plans, not schemas, so a custom differ cannot skip it.
    static func droppedMigrations(from old: MigrationPlan, to new: MigrationPlan) -> [ContractChange] {
        // Keyed with the same ChangeKey the replay failure will carry, so a
        // signed break on it excuses exactly the plans it breaks.
        var dropped: [(String, String)] = []
        for shim in old.idShims where !new.idShims.contains(where: { $0.entity == shim.entity && $0.from == shim.from && $0.to == shim.to }) {
            dropped.append(("\(shim.entity) ID shim \(shim.from) → \(shim.to)", ChangeKey.entityIDFormat(shim.entity)))
        }
        for backfill in old.backfills where new.backfill(intent: backfill.intent, parameter: backfill.parameter) == nil {
            dropped.append(("backfill \(backfill.intent).\(backfill.parameter)", ChangeKey.parameterRequired(backfill.intent, backfill.parameter)))
        }
        for retirement in old.retiredParameters where !new.retires(intent: retirement.intent, parameter: retirement.parameter) {
            dropped.append(("retirement \(retirement.intent).\(retirement.parameter)", ChangeKey.parameterRemoved(retirement.intent, retirement.parameter)))
        }
        return dropped.sorted { $0.0 < $1.0 }.map {
            ContractChange(kind: .migrationDropped($0.0), impact: .breaking, key: $0.1)
        }
    }

    private static func compatibilityNotes(_ replay: PlanReplay) -> [[String]] {
        replay.outcomes.map { outcome in
            if case .resolved(let resolved) = outcome { return resolved.notes }
            return []
        }
    }

    private func cover(_ change: ContractChange, migration: MigrationPlan, audits: inout [IDStabilityReport]) -> Coverage {
        switch change.kind {
        case .intentRemoved(_, scheduled: true), .aliasRemoved(_, scheduled: true):
            return .scheduledRemoval
        case let .entityIDFormatChanged(entity, from, to):
            if let shim = migration.idShims.first(where: { $0.entity == entity && $0.from == from && $0.to == to }) {
                let report = IDStabilityAudit.run(shim,
                                                  legacyIDs: migration.legacyIDSamples[entity] ?? [],
                                                  liveIDs: migration.liveIDSamples[entity] ?? [])
                audits.append(report)
                return .idShim(stable: report.isStable)
            }
        case let .parameterAdded(intent, name, true), let .parameterBecameRequired(intent, name):
            if migration.backfill(intent: intent, parameter: name) != nil { return .backfill }
        case let .parameterRemoved(intent, name), let .parameterFormerNameDropped(intent, name):
            if migration.retires(intent: intent, parameter: name) { return .retirement }
        default:
            break
        }
        if let key = change.key, let signed = migration.signedBreak(key) {
            return .acceptedBreak(approver: signed.approver)
        }
        return .uncovered
    }
}

// MARK: - Lab: the gate applied to a catalogue of proposed releases

public struct ContractProposal: Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var summary: String
    public var surface: IntentSurface
    public var migration: MigrationPlan

    public init(title: String, summary: String, surface: IntentSurface, migration: MigrationPlan = .none) {
        self.title = title
        self.summary = summary
        self.surface = surface
        self.migration = migration
    }
}

/// Evaluates every proposal against one baseline and one set of recorded
/// plans. Pure and eager: the UI renders results, it never computes them.
public struct ContractLab: Sendable {
    public let baseline: IntentSurface
    public let baselineMigration: MigrationPlan
    public let proposals: [ContractProposal]
    public let plans: [AgentPlan]
    public let reports: [GateReport]

    public init(baseline: IntentSurface, baselineMigration: MigrationPlan = .none, proposals: [ContractProposal], plans: [AgentPlan], gate: ContractGate = ContractGate()) {
        self.baseline = baseline
        self.baselineMigration = baselineMigration
        self.proposals = proposals
        self.plans = plans
        self.reports = proposals.map { gate.evaluate(baseline: baseline, proposed: $0.surface, baselineMigration: baselineMigration, migration: $0.migration, plans: plans) }
    }

    public func report(at index: Int) -> GateReport? {
        reports.indices.contains(index) ? reports[index] : nil
    }

    public func proposal(at index: Int) -> ContractProposal? {
        proposals.indices.contains(index) ? proposals[index] : nil
    }
}
