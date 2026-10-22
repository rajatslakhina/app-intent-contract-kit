#if canImport(SwiftUI)
import SwiftUI
import IntentContracts

/// Renders a `ContractLab`: pick a proposed release, see the gate's verdict,
/// every classified change, how each recorded Shortcut and agent plan fares,
/// and the ID-shim audits. All numbers come from the lab; the view computes nothing.
public struct ContractLabView: View {
    private let lab: ContractLab
    @State private var selection: Int

    public init(lab: ContractLab, initialSelection: Int = 0) {
        self.lab = lab
        _selection = State(initialValue: lab.proposals.indices.contains(initialSelection) ? initialSelection : 0)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if lab.proposals.isEmpty {
                    ContentUnavailableView("No proposed releases",
                                           systemImage: "doc.badge.ellipsis",
                                           description: Text("Add a ContractProposal to evaluate it against the published surface."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            picker
                            if let proposal = lab.proposal(at: selection), let report = lab.report(at: selection) {
                                ProposalDetail(proposal: proposal, report: report)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Intent Contract Gate")
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Published surface v\(lab.baseline.version.description) · \(lab.baseline.intents.count) intents · \(lab.plans.count) recorded plans")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(lab.proposals.enumerated()), id: \.offset) { index, proposal in
                        let passed = lab.report(at: index)?.passed ?? false
                        Button {
                            selection = index
                        } label: {
                            Label(proposal.title, systemImage: passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(index == selection ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                            in: Capsule())
                                .foregroundStyle(passed ? Color.green : Color.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(proposal.title), \(passed ? "passes" : "blocked")")
                    }
                }
            }
        }
    }
}

private struct ProposalDetail: View {
    let proposal: ContractProposal
    let report: GateReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title).font(.title3.bold())
                Text(proposal.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            verdict
            if !report.findings.isEmpty {
                Card(title: "Why it is blocked", systemImage: "exclamationmark.triangle") {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                        Text(verbatim: "• \(finding.description)").font(.footnote)
                    }
                }
            }
            Card(title: "Classified changes (\(report.changes.count))", systemImage: "list.bullet.rectangle") {
                if report.changes.isEmpty {
                    Text("No contract changes.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(report.changes.enumerated()), id: \.offset) { _, assessed in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        ImpactBadge(impact: assessed.change.impact)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assessed.change.description).font(.footnote)
                            if assessed.change.impact == .breaking {
                                Text(assessed.coverage.description)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(assessed.coverage == .uncovered ? Color.red : Color.secondary)
                            }
                        }
                    }
                }
            }
            Card(title: "Recorded Shortcuts & agent plans", systemImage: "point.3.connected.trianglepath.dotted") {
                if report.plans.isEmpty {
                    Text("No recorded plans to replay.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report.plans) { plan in
                    PlanRow(plan: plan)
                }
            }
            if !report.idAudits.isEmpty {
                Card(title: "Entity ID shim audits", systemImage: "number") {
                    ForEach(Array(report.idAudits.enumerated()), id: \.offset) { _, audit in
                        Text(verbatim: "\(audit.entity): \(audit.sampled) legacy IDs · \(audit.unmapped.count) unmapped · \(audit.orphaned.count) orphaned · \(audit.collisions.count) collisions — \(audit.isStable ? "stable" : "UNSAFE")")
                            .font(.footnote)
                            .foregroundStyle(audit.isStable ? Color.primary : Color.red)
                    }
                }
            }
        }
    }

    private var verdict: some View {
        HStack(spacing: 12) {
            Image(systemName: report.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.largeTitle)
                .foregroundStyle(report.passed ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.passed ? "PASS — safe to ship" : "BLOCKED")
                    .font(.headline)
                Text(verbatim: "v\(report.baselineVersion.description) → v\(report.proposedVersion.description) · declared \(report.declaredBump?.description ?? "regression") · required \(report.requiredBump.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background((report.passed ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.subheadline.bold())
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ImpactBadge: View {
    let impact: ChangeImpact

    var body: some View {
        Text(impact.description.uppercased())
            .font(.caption2.monospaced().weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch impact {
        case .cosmetic: return .gray
        case .additive: return .green
        case .deprecating: return .orange
        case .breaking: return .red
        }
    }
}

private struct PlanRow: View {
    let plan: PlanComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(plan.name).font(.footnote.weight(.semibold))
                Spacer(minLength: 4)
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
            }
            Text(verbatim: "\(plan.origin) · recorded on v\(plan.recordedAgainst.description)").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(detail.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: [String] {
        if let failure = plan.after.firstFailure {
            return ["Step \(failure.step + 1): \(failure.failure.description)"]
        }
        return plan.after.outcomes.flatMap { outcome -> [String] in
            if case .resolved(let resolved) = outcome { return resolved.notes }
            return []
        }
    }

    private var label: String {
        switch plan.status {
        case .unaffected: return "UNAFFECTED"
        case .rescued: return "RESCUED BY SHIM"
        case .acceptedBreak: return "ACCEPTED BREAK"
        case .regressed: return "REGRESSED"
        case .alreadyBroken: return "ALREADY BROKEN"
        }
    }

    private var icon: String {
        switch plan.status {
        case .unaffected: return "checkmark.circle"
        case .rescued: return "arrow.triangle.2.circlepath.circle"
        case .acceptedBreak: return "signature"
        case .regressed: return "xmark.circle"
        case .alreadyBroken: return "minus.circle"
        }
    }

    private var color: Color {
        switch plan.status {
        case .unaffected, .rescued: return .green
        case .acceptedBreak, .alreadyBroken: return .orange
        case .regressed: return .red
        }
    }
}
#endif
