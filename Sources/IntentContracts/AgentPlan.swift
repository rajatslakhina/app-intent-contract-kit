import Foundation

/// A multi-step workflow recorded against some version of the surface: a
/// saved Shortcut, or a plan an agent produced and cached. Later steps can
/// consume earlier steps' results, which is where silent breakage hides: each
/// intent can be fine on its own while the chain no longer type-checks.
public struct AgentPlan: Hashable, Sendable, Identifiable {
    public struct Step: Hashable, Sendable {
        public var invocation: IntentInvocation
        /// Parameter name (as recorded) → index of the earlier step whose result feeds it.
        public var bindings: [String: Int]
        public init(_ invocation: IntentInvocation, bindings: [String: Int] = [:]) {
            self.invocation = invocation
            self.bindings = bindings
        }
    }

    public var id: String { name }
    public var name: String
    /// Who recorded it, for the report ("Siri Shortcut", "Agent plan").
    public var origin: String
    /// Metadata: the surface version the plan was captured on. Replay does
    /// not depend on it (an alias chain resolves regardless); the lab shows it.
    public var recordedAgainst: SemanticVersion
    public var steps: [Step]

    public init(name: String, origin: String, recordedAgainst: SemanticVersion, steps: [Step]) {
        self.name = name
        self.origin = origin
        self.recordedAgainst = recordedAgainst
        self.steps = steps
    }
}

public struct PlanReplay: Hashable, Sendable {
    public enum StepOutcome: Hashable, Sendable {
        case resolved(ResolvedInvocation)
        case failed(ResolutionFailure)
    }
    public var plan: String
    public var outcomes: [StepOutcome]

    public var firstFailure: (step: Int, failure: ResolutionFailure)? {
        for (index, outcome) in outcomes.enumerated() {
            if case .failed(let failure) = outcome { return (index, failure) }
        }
        return nil
    }

    public var succeeded: Bool { !outcomes.isEmpty && firstFailure == nil }
}

public enum PlanReplayer {
    /// Replays every step against `resolver`, stopping at the first failure
    /// (a later step cannot run once its input is gone). An empty plan is a
    /// failure, not a vacuous success.
    public static func replay(_ plan: AgentPlan, with resolver: IntentResolver) -> PlanReplay {
        var outcomes: [PlanReplay.StepOutcome] = []
        var resultTypes: [ValueType?] = []
        var resultIntents: [String] = []
        let aliases = resolver.surface.entityAliasMap

        for (index, step) in plan.steps.enumerated() {
            // Validate bindings before resolving: indices are untrusted input.
            for (parameter, source) in step.bindings.sorted(by: { $0.key < $1.key }) {
                guard source >= 0, source < index, resultTypes.indices.contains(source) else {
                    outcomes.append(.failed(.badBinding(step: index, parameter: parameter, reason: "source step \(source) is not an earlier step")))
                    return PlanReplay(plan: plan.name, outcomes: outcomes)
                }
            }
            let outcome = resolver.resolve(step.invocation, externallySupplied: Set(step.bindings.keys))
            switch outcome {
            case .failure(let failure):
                outcomes.append(.failed(failure))
                return PlanReplay(plan: plan.name, outcomes: outcomes)
            case .success(let resolved):
                guard let schema = resolver.intent(named: resolved.intent) else {
                    outcomes.append(.failed(.unknownIntent(resolved.intent)))
                    return PlanReplay(plan: plan.name, outcomes: outcomes)
                }
                for (parameter, source) in step.bindings.sorted(by: { $0.key < $1.key }) {
                    guard let target = schema.parameters.first(where: { $0.name == parameter || $0.formerNames.contains(parameter) }) else {
                        // The resolver already accepted and dropped a retired binding.
                        if resolver.migration.retires(intent: resolved.intent, parameter: parameter) { continue }
                        outcomes.append(.failed(.unknownArgument(intent: resolved.intent, name: parameter)))
                        return PlanReplay(plan: plan.name, outcomes: outcomes)
                    }
                    // Bounds were checked above; re-check rather than index blindly.
                    guard resultTypes.indices.contains(source), resultIntents.indices.contains(source) else {
                        outcomes.append(.failed(.badBinding(step: index, parameter: parameter, reason: "source step is out of range")))
                        return PlanReplay(plan: plan.name, outcomes: outcomes)
                    }
                    guard let produced = resultTypes[source] else {
                        outcomes.append(.failed(.bindingSourceHasNoResult(step: index, parameter: parameter, sourceIntent: resultIntents[source])))
                        return PlanReplay(plan: plan.name, outcomes: outcomes)
                    }
                    if !target.type.accepts(produced, entityAliases: aliases) {
                        let sourceIntent = resultIntents.indices.contains(source) ? resultIntents[source] : "step \(source + 1)"
                        outcomes.append(.failed(.bindingTypeMismatch(intent: resolved.intent, parameter: target.name, sourceIntent: sourceIntent, produced: produced, expected: target.type)))
                        return PlanReplay(plan: plan.name, outcomes: outcomes)
                    }
                }
                resultTypes.append(schema.result)
                resultIntents.append(resolved.intent)
                outcomes.append(.resolved(resolved))
            }
        }
        return PlanReplay(plan: plan.name, outcomes: outcomes)
    }
}
