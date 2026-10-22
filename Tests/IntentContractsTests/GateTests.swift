import XCTest
import Foundation
@testable import IntentContracts

final class GateTests: XCTestCase {
    private let gate = ContractGate()

    private func evaluate(_ proposal: ContractProposal, plans: [AgentPlan] = Fixtures.plans) -> GateReport {
        gate.evaluate(baseline: Fixtures.baseline, proposed: proposal.surface, migration: proposal.migration, plans: plans)
    }

    private func status(_ report: GateReport, _ plan: AgentPlan) -> PlanComparison.Status? {
        report.plans.first { $0.name == plan.name }?.status
    }

    /// The verdict table in both READMEs, asserted.
    func testVerdictTable() {
        let expected: [(ContractProposal, Bool)] = [
            (Proposals.renameForgotAlias, false),
            (Proposals.renameWithAlias, true),
            (Proposals.namespacedWithShim, true),
            (Proposals.namespacedNoShim, false),
            (Proposals.requiredFolderMinor, false),
            (Proposals.requiredFolderBackfilled, true),
            (Proposals.removeArchiveOnSchedule, true),
            (Proposals.summaryBecomesEntity, false)
        ]
        XCTAssertEqual(expected.count, Proposals.all.count)
        for (proposal, passes) in expected {
            let report = evaluate(proposal)
            XCTAssertEqual(report.passed, passes, "\(proposal.title): \(report.findings)")
        }
    }

    func testForgottenAliasIsBlockedThreeWays() {
        let report = evaluate(Proposals.renameForgotAlias)
        // 1. Structure: the 0.9 alias ShowNote → OpenNote now dangles.
        XCTAssertTrue(report.findings.contains(.surfaceInvalid(.aliasDangling("ShowNote"))))
        // 2. Classification: a removal needs 2.0.0, the release says 1.1.0.
        XCTAssertTrue(report.findings.contains(.insufficientBump(required: .major, declared: .minor)))
        XCTAssertTrue(report.findings.contains { if case .uncoveredBreak = $0 { return true }; return false })
        // 3. Replay: both Shortcuts that open a note regress.
        XCTAssertEqual(status(report, Fixtures.openNote42), .regressed)
        XCTAssertEqual(status(report, Fixtures.legacyShowNote), .regressed)
        XCTAssertEqual(status(report, Fixtures.summariseAndShare), .unaffected)
    }

    func testAliasRescuesBothGenerationsOfShortcut() {
        let report = evaluate(Proposals.renameWithAlias)
        XCTAssertEqual(report.requiredBump, .minor)
        XCTAssertEqual(status(report, Fixtures.openNote42), .rescued)
        XCTAssertEqual(status(report, Fixtures.legacyShowNote), .rescued, "0.9 ShowNote → OpenNote → OpenDocument")
        guard case .resolved(let resolved)? = report.plans.first(where: { $0.name == Fixtures.legacyShowNote.name })?.after.outcomes.first else { return XCTFail() }
        XCTAssertEqual(resolved.aliasHops, ["ShowNote", "OpenNote"])
    }

    func testIDShimIsAuditedAndRescuesStoredIDs() {
        let report = evaluate(Proposals.namespacedWithShim)
        XCTAssertEqual(report.idAudits.count, 1)
        XCTAssertEqual(report.idAudits.first?.isStable, true)
        XCTAssertEqual(status(report, Fixtures.openNote42), .rescued)
        XCTAssertEqual(status(report, Fixtures.archiveOld), .rescued)
        XCTAssertEqual(report.plans.filter { $0.status == .rescued }.map(\.name).sorted(),
                       [Fixtures.archiveOld.name, Fixtures.openNote42.name, Fixtures.legacyShowNote.name].sorted(),
                       "README: 3 stored-ID plans rescued")
        XCTAssertEqual(report.idAudits.first?.sampled, 4)

        let missing = evaluate(Proposals.namespacedNoShim)
        XCTAssertTrue(missing.findings.contains { if case .uncoveredBreak = $0 { return true }; return false })
        XCTAssertEqual(status(missing, Fixtures.openNote42), .regressed)
    }

    func testUnauditedOrLossyShimBlocks() {
        var proposal = Proposals.namespacedWithShim
        proposal.migration.legacyIDSamples = [:]
        let unaudited = evaluate(proposal)
        XCTAssertFalse(unaudited.passed)
        XCTAssertTrue(unaudited.findings.contains { if case .unstableIDShim(let r) = $0 { return r.sampled == 0 }; return false })

        proposal = Proposals.namespacedWithShim
        proposal.migration.idShims = [LookupTableShim(entity: "Note", from: .integer, to: .prefixed("note-"), table: ["3": "note-3", "7": "note-3", "42": "note-42", "108": "note-108"])]
        let lossy = evaluate(proposal)
        XCTAssertFalse(lossy.passed)
        XCTAssertTrue(lossy.findings.contains { if case .unstableIDShim(let r) = $0 { return !r.collisions.isEmpty }; return false })
    }

    func testBackfillCoversButStillDemandsMajor() {
        let minor = evaluate(Proposals.requiredFolderMinor)
        XCTAssertEqual(status(minor, Fixtures.quickCapture), .regressed)
        XCTAssertEqual(status(minor, Fixtures.summariseAndShare), .regressed)

        var backfilledButMinor = Proposals.requiredFolderBackfilled
        backfilledButMinor.surface.version = Fixtures.v110
        let report = evaluate(backfilledButMinor)
        XCTAssertEqual(report.findings, [.insufficientBump(required: .major, declared: .minor)],
                       "a shim makes a break safe for our resolver, not invisible to callers reading the schema")

        let major = evaluate(Proposals.requiredFolderBackfilled)
        XCTAssertEqual(status(major, Fixtures.quickCapture), .rescued)
    }

    func testScheduledRemovalOnMajorAcceptsTheBrokenShortcut() {
        let report = evaluate(Proposals.removeArchiveOnSchedule)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(status(report, Fixtures.archiveOld), .acceptedBreak)
        XCTAssertTrue(report.changes.contains { $0.change.kind == .intentRemoved("ArchiveNote", scheduled: true) && $0.coverage == .scheduledRemoval })
    }

    func testScheduledRemovalExcusesPlansThatReachItThroughAnAlias() {
        var baseline = Fixtures.baseline
        baseline.aliases.append(IntentAlias(from: "StashNote", to: "ArchiveNote", since: Fixtures.v090))
        let viaAlias = AgentPlan(name: "Stash note 3", origin: "Shortcut saved on 0.9", recordedAgainst: Fixtures.v090, steps: [
            .init(IntentInvocation("StashNote", arguments: ["note": .entity(type: "Note", id: "3")]))
        ])
        var proposed = baseline
        proposed.version = Fixtures.v200
        Fixtures.replaceIntent("ArchiveNote", in: &proposed, with: nil)
        proposed.aliases.removeAll { $0.from == "StashNote" }
        let report = gate.evaluate(baseline: baseline, proposed: proposed, plans: [viaAlias, Fixtures.archiveOld])
        XCTAssertTrue(report.passed, "\(report.findings)")
        XCTAssertEqual(status(report, viaAlias), .acceptedBreak)
        XCTAssertTrue(report.changes.contains { $0.change.kind == .aliasRemoved("StashNote", scheduled: true) && $0.coverage == .scheduledRemoval })
    }

    /// Reviewer-found hole: "worked before" must mean "worked through the
    /// published release's own shims", or dropping a shim looks harmless.
    func testDroppingThePublishedShimIsABreak() {
        let shipped = Proposals.namespacedWithShim
        var next = shipped.surface
        next.version = SemanticVersion(2, 0, 1)
        next.intents[0].title = "Open"
        let report = gate.evaluate(baseline: shipped.surface, proposed: next, baselineMigration: shipped.migration, migration: .none, plans: Fixtures.plans)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(status(report, Fixtures.openNote42), .regressed, "worked in 2.0.0 through its shim, so not 'already broken'")
        XCTAssertTrue(report.changes.contains { $0.change.kind == .migrationDropped("Note ID shim integer → prefixed(note-)") && $0.coverage == .uncovered })

        let kept = gate.evaluate(baseline: shipped.surface, proposed: next, baselineMigration: shipped.migration, migration: shipped.migration, plans: Fixtures.plans)
        XCTAssertTrue(kept.passed, "\(kept.findings)")
        XCTAssertEqual(status(kept, Fixtures.openNote42), .unaffected)
    }

    /// Round-3 reviewer finding: a lossy shim swapped in a *later* release
    /// (no format change in that release) must still be audited.
    func testEveryShippedShimIsAuditedEvenWithoutAFormatChange() {
        let shipped = Proposals.namespacedWithShim
        var next = shipped.surface
        next.version = SemanticVersion(2, 0, 1)
        var lossy = shipped.migration
        lossy.idShims = [LookupTableShim(entity: "Note", from: .integer, to: .prefixed("note-"),
                                         table: ["3": "note-3", "7": "note-3", "42": "note-42", "108": "note-108"])]
        let report = gate.evaluate(baseline: shipped.surface, proposed: next, baselineMigration: shipped.migration, migration: lossy, plans: Fixtures.plans)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.idAudits.count, 1)
        XCTAssertTrue(report.findings.contains { if case .unstableIDShim(let r) = $0 { return r.collisions["note-3"] == ["3", "7"] }; return false })
    }

    func testDroppingAPublishedBackfillOrRetirementIsABreak() {
        let shipped = Proposals.requiredFolderBackfilled
        var next = shipped.surface
        next.version = SemanticVersion(2, 0, 1)
        let report = gate.evaluate(baseline: shipped.surface, proposed: next, baselineMigration: shipped.migration, migration: .none, plans: Fixtures.plans)
        XCTAssertTrue(report.changes.contains { $0.change.kind == .migrationDropped("backfill CreateNote.folder") && $0.change.key == "param-required:CreateNote.folder" })
        XCTAssertEqual(status(report, Fixtures.quickCapture), .regressed)

        let retire = MigrationPlan(retiredParameters: [ParameterRetirement(intent: "ShareText", parameter: "channel")])
        let dropped = gate.evaluate(baseline: Fixtures.baseline, proposed: Fixtures.surface(SemanticVersion(1, 0, 1)) { _ in }, baselineMigration: retire, migration: .none)
        XCTAssertTrue(dropped.changes.contains { $0.change.kind == .migrationDropped("retirement ShareText.channel") && $0.coverage == .uncovered })
    }

    /// The design rests on one invariant: for each kind of break, the replay
    /// failure carries the differ's key, so a signed break on a major release
    /// excuses exactly the plans it breaks. One row per kind.
    func testSignedBreakOnTheDiffKeyExcusesTheReplayFailure() {
        struct Row { let name: String; let edit: (inout IntentSurface) -> Void; let plan: AgentPlan; var baselineMigration = MigrationPlan.none }
        let call = { (intent: String, args: [String: ArgumentValue]) in
            AgentPlan(name: intent, origin: "test", recordedAgainst: Fixtures.v100, steps: [.init(IntentInvocation(intent, arguments: args))])
        }
        let rows: [Row] = [
            Row(name: "intent removed", edit: { Fixtures.replaceIntent("ShareText", in: &$0, with: nil) }, plan: call("ShareText", ["text": .string("x")])),
            Row(name: "parameter removed", edit: { $0.intents[5].parameters = [ParameterSchema("body", .string, optional: true)] }, plan: call("ShareText", ["text": .string("x")])),
            Row(name: "parameter required", edit: { $0.intents[1].parameters[1].isOptional = false }, plan: call("CreateNote", ["title": .string("x")])),
            Row(name: "parameter type", edit: { $0.intents[5].parameters[0].type = .integer }, plan: call("ShareText", ["text": .string("x")])),
            Row(name: "entity ID format", edit: { $0.entities[0].idFormat = .uuid }, plan: call("OpenNote", ["note": .entity(type: "Note", id: "42")])),
            Row(name: "entity removed", edit: { s in s.entities.removeAll { $0.identifier == "Folder" } }, plan: AgentPlan(name: "folder", origin: "test", recordedAgainst: Fixtures.v100, steps: [])),
            Row(name: "enum case removed", edit: { $0.enums[0].cases = ["yellow", "blue"] }, plan: call("CreateNote", ["title": .string("x"), "color": .enumCase("green")])),
            Row(name: "result type", edit: { $0.intents[3].result = .integer }, plan: Fixtures.summariseAndShare),
            Row(name: "result removed", edit: { $0.intents[3].result = nil }, plan: Fixtures.summariseAndShare),
            Row(name: "backfill dropped", edit: { s in s.intents[1].parameters.append(ParameterSchema("folder", .entity("Folder"))) },
                plan: call("CreateNote", ["title": .string("x")]), baselineMigration: Proposals.requiredFolderBackfilled.migration)
        ]
        for row in rows {
            var baseline = Fixtures.baseline
            if !row.baselineMigration.backfills.isEmpty { baseline = Proposals.requiredFolderBackfilled.surface; baseline.version = Fixtures.v100 }
            let proposed: IntentSurface = {
                var s = Fixtures.surface(Fixtures.v200, row.edit)
                if !row.baselineMigration.backfills.isEmpty { s = baseline; s.version = Fixtures.v200 }
                return s
            }()
            let unsigned = gate.evaluate(baseline: baseline, proposed: proposed, baselineMigration: row.baselineMigration, plans: [row.plan])
            let keys = unsigned.changes.filter { $0.coverage == .uncovered }.compactMap(\.change.key)
            XCTAssertFalse(keys.isEmpty, "\(row.name): the differ must report an uncovered break")
            if row.plan.steps.isEmpty { continue }   // entity removal: the key check above is the point
            XCTAssertEqual(status(unsigned, row.plan), .regressed, row.name)
            guard let failure = unsigned.plans.first?.after.firstFailure?.failure else { XCTFail(row.name); continue }
            XCTAssertFalse(Set(failure.relatedChangeKeys).isDisjoint(with: keys), "\(row.name): replay keys \(failure.relatedChangeKeys) vs diff keys \(keys)")

            var signedMigration = MigrationPlan()
            signedMigration.acceptedBreaks = keys.map { AcceptedBreak(key: $0, justification: "planned", approver: "lead") }
            let signed = gate.evaluate(baseline: baseline, proposed: proposed, baselineMigration: row.baselineMigration, migration: signedMigration, plans: [row.plan])
            XCTAssertEqual(status(signed, row.plan), .acceptedBreak, "\(row.name): \(signed.findings)")
        }
    }

    func testDeletingAnAliasWhoseTargetStillLivesIsNotExcused() {
        let proposed = Fixtures.surface(Fixtures.v200) { s in
            s.aliases.append(IntentAlias(from: "StashNote", to: "ArchiveNote", since: Fixtures.v100))
        }
        var baseline = Fixtures.baseline
        baseline.aliases.append(IntentAlias(from: "StashNote", to: "ArchiveNote", since: Fixtures.v090))
        var withoutAlias = proposed
        withoutAlias.aliases.removeAll { $0.from == "StashNote" }
        let report = gate.evaluate(baseline: baseline, proposed: withoutAlias)
        XCTAssertTrue(report.changes.contains { $0.change.kind == .aliasRemoved("StashNote", scheduled: false) && $0.coverage == .uncovered })
    }

    func testAcceptedBreakNeedsSignatureAndMajor() {
        let key = ChangeKey.resultType("SummarizeNote")
        var proposal = Proposals.summaryBecomesEntity
        proposal.migration.acceptedBreaks = [AcceptedBreak(key: key, justification: "   ", approver: "lead")]
        XCTAssertTrue(evaluate(proposal).findings.contains { if case .uncoveredBreak = $0 { return true }; return false }, "blank justification is not a signature")

        proposal.migration.acceptedBreaks = [AcceptedBreak(key: key, justification: "Summaries become first-class notes", approver: "lead")]
        let minor = evaluate(proposal)
        XCTAssertTrue(minor.findings.contains(.acceptedBreakNeedsMajor(key)))
        XCTAssertEqual(status(minor, Fixtures.summariseAndShare), .regressed)

        proposal.surface.version = Fixtures.v200
        let major = evaluate(proposal)
        XCTAssertTrue(major.passed, "\(major.findings)")
        XCTAssertEqual(status(major, Fixtures.summariseAndShare), .acceptedBreak)
    }

    func testVersionRegressionIsAFinding() {
        var proposal = Proposals.renameWithAlias
        proposal.surface.version = Fixtures.v090
        XCTAssertTrue(evaluate(proposal).findings.contains(.versionRegressed(from: Fixtures.v100, to: Fixtures.v090)))
    }

    func testPlanThatWasAlreadyBrokenIsNotBlamedOnThisRelease() {
        let broken = AgentPlan(name: "typo", origin: "test", recordedAgainst: Fixtures.v100, steps: [.init(IntentInvocation("OpenNoet"))])
        let report = evaluate(Proposals.renameWithAlias, plans: [broken, Fixtures.summariseAndShare])
        XCTAssertEqual(status(report, broken), .alreadyBroken)
        XCTAssertTrue(report.passed)
    }

    func testBaselineAliasIsNotCountedAsARescue() {
        // ShowNote → OpenNote already applied in 1.0.0; a release that does
        // not touch OpenNote must report that Shortcut as unaffected.
        let report = evaluate(Proposals.summaryBecomesEntity)
        XCTAssertEqual(status(report, Fixtures.legacyShowNote), .unaffected)
    }

    /// Defence in depth, tested against a broken implementation: a differ
    /// that reports nothing makes classification useless, and the replay check
    /// must still block the release on its own.
    func testLyingDifferIsCaughtByReplay() {
        struct BlindDiffer: SurfaceDiffing {
            func diff(from old: IntentSurface, to new: IntentSurface) -> [ContractChange] { [] }
        }
        let blind = ContractGate(differ: BlindDiffer())
        let proposal = Proposals.namespacedNoShim
        let report = blind.evaluate(baseline: Fixtures.baseline, proposed: proposal.surface, migration: proposal.migration, plans: Fixtures.plans)
        XCTAssertEqual(report.changes, [], "the differ really is blind")
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.findings.allSatisfy { if case .planRegressed = $0 { return true }; return false })

        // And without recorded plans the blind gate passes — which is exactly
        // why the plans are part of the gate, not an optional extra.
        XCTAssertTrue(blind.evaluate(baseline: Fixtures.baseline, proposed: proposal.surface, migration: proposal.migration, plans: []).passed)
    }

    func testLabIsBoundsSafe() {
        let lab = ContractLab(baseline: Fixtures.baseline, proposals: Proposals.all, plans: Fixtures.plans)
        XCTAssertEqual(lab.reports.count, Proposals.all.count)
        XCTAssertNil(lab.report(at: -1))
        XCTAssertNil(lab.report(at: Proposals.all.count))
        XCTAssertNil(ContractLab(baseline: Fixtures.baseline, proposals: [], plans: []).proposal(at: 0))
    }
}

final class SnapshotTests: XCTestCase {
    /// Pins the canonical form + FNV-1a across platforms: the Linux job and the
    /// macOS job both assert this literal, so a platform-dependent fingerprint
    /// fails one of them.
    func testGoldenFingerprint() {
        XCTAssertEqual(CanonicalFingerprinter().fingerprint(Fixtures.baseline), "0c05df0fc7afb540")
    }

    func testFingerprintIgnoresDeclarationOrder() {
        var shuffled = Fixtures.baseline
        shuffled.intents.reverse()
        shuffled.entities.reverse()
        shuffled.intents[0].parameters.reverse()
        XCTAssertEqual(CanonicalFingerprinter().fingerprint(shuffled), CanonicalFingerprinter().fingerprint(Fixtures.baseline))
    }

    func testCodableRoundTripPreservesTheContract() throws {
        let data = try JSONEncoder().encode(Fixtures.baseline)
        let decoded = try JSONDecoder().decode(IntentSurface.self, from: data)
        XCTAssertEqual(decoded, Fixtures.baseline)
        XCTAssertEqual(CanonicalForm.text(of: decoded), CanonicalForm.text(of: Fixtures.baseline))
    }

    func testTitlesAreEscapedSoTheyCannotForgeLines() {
        var surface = Fixtures.baseline
        surface.intents[0].title = "Open\nintent Fake \"x\" -> Void"
        let text = CanonicalForm.text(of: surface)
        XCTAssertFalse(text.split(separator: "\n").contains { $0.hasPrefix("intent Fake") }, "a newline in a title must not start a new canonical line")
        XCTAssertTrue(text.contains(#"Open\nintent Fake \"x\""#), "newline and quotes are escaped, not dropped")

        // Backslash and carriage return must be escaped too, or "a\\nb" and
        // "a" + newline + "b" could render identically.
        var tricky = Fixtures.baseline
        tricky.intents[0].title = "a\\b\rc"
        XCTAssertTrue(CanonicalForm.text(of: tricky).contains(#""a\\b\rc""#))
        var lookalike = Fixtures.baseline
        lookalike.intents[0].title = "a\\nb"
        var real = Fixtures.baseline
        real.intents[0].title = "a\nb"
        XCTAssertNotEqual(CanonicalForm.text(of: lookalike), CanonicalForm.text(of: real))
    }

    func testEnumCasesAndIDPrefixesCannotCarryLineBreaks() {
        var surface = Fixtures.baseline
        surface.enums[0].cases.append("pink\nintent Fake")
        surface.entities[0].idFormat = .prefixed("n\nintent Fake")
        XCTAssertFalse(CanonicalForm.text(of: surface).split(separator: "\n").contains { $0.hasPrefix("intent Fake") })
        let issues = SurfaceValidator.validate(surface)
        XCTAssertTrue(issues.contains(.invalidIdentifier("NoteColor.pink\nintent Fake")))
        XCTAssertTrue(issues.contains { if case .invalidIdentifier(let s) = $0 { return s.hasPrefix("Note id prefix") }; return false })
    }

    /// The drift check must notice a change to a parameter's *type* alone.
    private func detectsTypeOnlyDrift(_ fingerprinter: any SurfaceFingerprinting) -> Bool {
        let committed = CommittedSnapshot(surface: Fixtures.baseline, fingerprinter: fingerprinter)
        var changed = Fixtures.baseline
        changed.intents[2].parameters[1].type = .string
        return !committed.drift(against: changed, fingerprinter: fingerprinter).isClean
    }

    func testDriftCheckCatchesTypeChangeAndABrokenFingerprinterWouldNot() {
        /// Broken on purpose: fingerprints names only, the way a hand-rolled
        /// "list the intents" check often does.
        struct NamesOnly: SurfaceFingerprinting {
            func fingerprint(_ surface: IntentSurface) -> String {
                surface.intents.map { $0.identifier + ":" + $0.parameters.map(\.name).joined(separator: ",") }.sorted().joined(separator: "|")
            }
        }
        XCTAssertTrue(detectsTypeOnlyDrift(CanonicalFingerprinter()))
        XCTAssertFalse(detectsTypeOnlyDrift(NamesOnly()), "the test above would fail against a names-only fingerprint")
    }

    func testDriftReportsTheExactLines() {
        let committed = CommittedSnapshot(surface: Fixtures.baseline)
        var changed = Fixtures.baseline
        changed.intents[2].parameters[1].type = .string
        guard case let .drifted(_, _, added, removed) = committed.drift(against: changed) else { return XCTFail() }
        XCTAssertEqual(added, ["  param limit: String? former=[]"])
        XCTAssertEqual(removed, ["  param limit: Int? former=[]"])
        XCTAssertTrue(committed.drift(against: Fixtures.baseline).isClean)
    }
}
