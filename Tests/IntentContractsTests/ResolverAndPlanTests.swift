import XCTest
@testable import IntentContracts

final class ResolverTests: XCTestCase {
    private var renamedFind: IntentSurface {
        Fixtures.surface(Fixtures.v110) { s in
            var find = Fixtures.findNotes
            find.parameters[0] = ParameterSchema("text", .string, formerNames: ["query"])
            find.parameters[1].type = .decimal
            Fixtures.replaceIntent("FindNotes", in: &s, with: find)
        }
    }

    func testOldParameterNameAndWideningAreApplied() throws {
        let resolver = IntentResolver(surface: renamedFind)
        let resolved = try resolver.resolve(IntentInvocation("FindNotes", arguments: ["query": .string("x"), "limit": .integer(3)])).get()
        XCTAssertEqual(resolved.arguments, ["text": .string("x"), "limit": .decimal(3)])
        XCTAssertTrue(resolved.notes.contains("Mapped query → text"))
    }

    func testOldAndNewNameTogetherIsRejected() {
        let resolver = IntentResolver(surface: renamedFind)
        XCTAssertEqual(resolver.resolve(IntentInvocation("FindNotes", arguments: ["query": .string("a"), "text": .string("b")])),
                       .failure(.duplicateArgument(intent: "FindNotes", name: "text")))
    }

    func testStrictUnknownArgumentUnlessRetired() {
        let invocation = IntentInvocation("ShareText", arguments: ["text": .string("hi"), "channel": .string("mail")])
        XCTAssertEqual(IntentResolver(surface: Fixtures.baseline).resolve(invocation), .failure(.unknownArgument(intent: "ShareText", name: "channel")))
        let lenient = IntentResolver(surface: Fixtures.baseline, migration: MigrationPlan(retiredParameters: [ParameterRetirement(intent: "ShareText", parameter: "channel")]))
        XCTAssertEqual(try lenient.resolve(invocation).get().arguments, ["text": .string("hi")])
    }

    func testMissingRequiredArgumentAndBackfill() throws {
        let surface = Proposals.requireFolder(Fixtures.v200)
        let call = IntentInvocation("CreateNote", arguments: ["title": .string("t")])
        XCTAssertEqual(IntentResolver(surface: surface).resolve(call), .failure(.missingArgument(intent: "CreateNote", name: "folder")))
        let backfilled = try IntentResolver(surface: surface, migration: Proposals.requiredFolderBackfilled.migration).resolve(call).get()
        XCTAssertEqual(backfilled.arguments["folder"], .entity(type: "Folder", id: Fixtures.inboxFolder))
    }

    func testBackfillOfTheWrongTypeIsRejectedNotInjected() {
        let bad = MigrationPlan(backfills: [ArgumentBackfill(intent: "CreateNote", parameter: "folder", value: .string("Inbox"))])
        let result = IntentResolver(surface: Proposals.requireFolder(Fixtures.v200), migration: bad).resolve(IntentInvocation("CreateNote", arguments: ["title": .string("t")]))
        guard case .failure(.typeMismatch(intent: "CreateNote", name: "folder", _, _)) = result else { return XCTFail("\(result)") }
    }

    func testEntityIDsMigrateThroughTheShimOrFail() throws {
        let surface = Proposals.namespacedIDs(Fixtures.v200)
        let call = IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Note", id: "42")])
        XCTAssertEqual(IntentResolver(surface: surface).resolve(call), .failure(.entityIDUnresolvable(entity: "Note", id: "42")))
        let migrated = try IntentResolver(surface: surface, migration: Proposals.namespacedWithShim.migration).resolve(call).get()
        XCTAssertEqual(migrated.arguments["note"], .entity(type: "Note", id: "note-42"))
        // Already-new IDs pass straight through, untouched by the shim.
        let fresh = try IntentResolver(surface: surface, migration: Proposals.namespacedWithShim.migration)
            .resolve(IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Note", id: "note-9")])).get()
        XCTAssertEqual(fresh.arguments["note"], .entity(type: "Note", id: "note-9"))
    }

    func testEnumsListsAndEntityTypeChecks() {
        let resolver = IntentResolver(surface: Fixtures.baseline)
        XCTAssertEqual(resolver.resolve(IntentInvocation("CreateNote", arguments: ["title": .string("t"), "color": .enumCase("purple")])),
                       .failure(.unknownEnumCase(enumeration: "NoteColor", value: "purple")))
        XCTAssertEqual(resolver.resolve(IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Ghost", id: "1")])),
                       .failure(.unknownEntity("Ghost")))
        guard case .failure(.typeMismatch) = resolver.resolve(IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Folder", id: Fixtures.inboxFolder)])) else {
            return XCTFail("a Folder must not be accepted where a Note is expected")
        }
        let listSurface = Fixtures.surface(Fixtures.v110) { s in
            s.intents.append(IntentSchema("TagNotes", title: "Tag", parameters: [ParameterSchema("notes", .list(.entity("Note")))]))
        }
        let ok = IntentResolver(surface: listSurface).resolve(IntentInvocation("TagNotes", arguments: ["notes": .list([.entity(type: "Note", id: "1"), .entity(type: "Note", id: "2")])]))
        XCTAssertNoThrow(try ok.get())
        let empty = IntentResolver(surface: listSurface).resolve(IntentInvocation("TagNotes", arguments: ["notes": .list([])]))
        XCTAssertNoThrow(try empty.get(), "an empty list is a valid list")
        let mixed = IntentResolver(surface: listSurface).resolve(IntentInvocation("TagNotes", arguments: ["notes": .list([.entity(type: "Note", id: "1"), .string("2")])]))
        guard case .failure(.typeMismatch) = mixed else { return XCTFail("\(mixed)") }
    }

    func testDanglingAliasIsNamedAsSuch() {
        let surface = Fixtures.surface(Fixtures.v110) { Fixtures.replaceIntent("OpenNote", in: &$0, with: nil) }
        let result = IntentResolver(surface: surface).resolve(IntentInvocation("ShowNote"))
        XCTAssertEqual(result, .failure(.danglingAlias(["ShowNote", "OpenNote"])))
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertEqual(failure.relatedChangeKeys, ["intent-removed:ShowNote", "intent-removed:OpenNote"])
    }

    func testRetirementAppliesToBoundArgumentsToo() {
        let proposed = Fixtures.surface(Fixtures.v200) { s in s.intents[5].parameters = [] }
        let retire = MigrationPlan(retiredParameters: [ParameterRetirement(intent: "ShareText", parameter: "text")])
        let report = ContractGate().evaluate(baseline: Fixtures.baseline, proposed: proposed, migration: retire, plans: [Fixtures.summariseAndShare])
        XCTAssertTrue(report.changes.contains { $0.coverage == .retirement })
        XCTAssertEqual(report.plans.first?.status, .rescued, "the change list says covered, so replay must agree")
    }

    func testParameterTypedWithAFormerEntityIdentifierStillResolves() throws {
        let renamed = Fixtures.surface(Fixtures.v110) { s in
            s.entities[0] = EntitySchema("Document", idFormat: .integer, properties: Fixtures.note.properties, formerIdentifiers: ["Note"])
        }
        XCTAssertEqual(SurfaceValidator.validate(renamed), [])
        let resolved = try IntentResolver(surface: renamed).resolve(IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Note", id: "42")])).get()
        XCTAssertEqual(resolved.arguments["note"], .entity(type: "Document", id: "42"))
        XCTAssertTrue(ContractGate().evaluate(baseline: Fixtures.baseline, proposed: renamed, plans: Fixtures.plans).passed)
    }

    func testDescriptionsSaturateInsteadOfTrapping() {
        XCTAssertTrue(ResolutionFailure.badBinding(step: Int.max, parameter: "p", reason: "r").description.contains("\(Int.max)"))
        XCTAssertFalse(GateFinding.planRegressed(plan: "p", step: Int.max, failure: .unknownIntent("x")).description.isEmpty)
    }

    func testAliasCycleIsAFailureNotAHang() {
        let surface = IntentSurface(version: Fixtures.v100, aliases: [IntentAlias(from: "A", to: "B", since: Fixtures.v100), IntentAlias(from: "B", to: "A", since: Fixtures.v100)])
        XCTAssertEqual(IntentResolver(surface: surface).resolve(IntentInvocation("A")), .failure(.aliasCycle(["A", "B", "A"])))
    }
}

final class IDStabilityTests: XCTestCase {
    func testPrefixingShimIsStableOnRealIDs() {
        let report = IDStabilityAudit.run(PrefixingShim(entity: "Note", prefix: "note-"), legacyIDs: Fixtures.legacyNoteIDs + ["42"], liveIDs: Fixtures.liveNoteIDs)
        XCTAssertTrue(report.isStable)
        XCTAssertEqual(report.sampled, 4, "duplicates in the sample are counted once")
    }

    func testUnauditedShimIsNotStable() {
        XCTAssertFalse(IDStabilityAudit.run(PrefixingShim(entity: "Note", prefix: "note-"), legacyIDs: [], liveIDs: []).isStable)
    }

    /// A deliberately broken shim: maps by `id % 2`, so distinct notes collide.
    /// The audit must catch it, or "injective" in the README is a claim, not a check.
    func testCollidingShimIsCaught() {
        let lossy = LookupTableShim(entity: "Note", from: .integer, to: .prefixed("note-"),
                                    table: ["3": "note-1", "7": "note-1", "42": "note-0", "108": "note-0"])
        let report = IDStabilityAudit.run(lossy, legacyIDs: Fixtures.legacyNoteIDs, liveIDs: ["note-0", "note-1"])
        XCTAssertFalse(report.isStable)
        XCTAssertEqual(report.collisions, ["note-1": ["3", "7"], "note-0": ["108", "42"]])
    }

    func testUnmappedOrphanedAndMalformedAreSeparated() {
        let shim = LookupTableShim(entity: "Note", from: .integer, to: .prefixed("note-"),
                                   table: ["3": "note-3", "7": "note-999", "42": "42"])
        let report = IDStabilityAudit.run(shim, legacyIDs: Fixtures.legacyNoteIDs, liveIDs: Fixtures.liveNoteIDs)
        XCTAssertEqual(report.unmapped, ["108"])
        XCTAssertEqual(report.orphaned, ["7"])
        XCTAssertEqual(report.malformed, ["42"])
        XCTAssertFalse(report.isStable)
    }
}

final class PlanReplayTests: XCTestCase {
    private let resolver = IntentResolver(surface: Fixtures.baseline)

    func testAllBaselinePlansReplay() {
        for plan in Fixtures.plans {
            XCTAssertTrue(PlanReplayer.replay(plan, with: resolver).succeeded, plan.name)
        }
    }

    func testEmptyPlanIsNotASuccess() {
        XCTAssertFalse(PlanReplayer.replay(AgentPlan(name: "empty", origin: "test", recordedAgainst: Fixtures.v100, steps: []), with: resolver).succeeded)
    }

    func testBindingsMustPointBackwards() {
        // Step 1 may only bind to step 0. Self (1), forward (5) and out-of-range values all fail.
        for source in [1, 5, -1, Int.max, Int.min] {
            let plan = AgentPlan(name: "bad", origin: "test", recordedAgainst: Fixtures.v100, steps: [
                .init(IntentInvocation("CreateNote", arguments: ["title": .string("t")])),
                .init(IntentInvocation("SummarizeNote"), bindings: ["note": source])
            ])
            let replay = PlanReplayer.replay(plan, with: resolver)
            guard case .badBinding? = replay.firstFailure?.failure else { return XCTFail("source \(source): \(replay)") }
        }
    }

    func testBindingToAStepWithoutAResultFails() {
        let plan = AgentPlan(name: "void", origin: "test", recordedAgainst: Fixtures.v100, steps: [
            .init(IntentInvocation("ShareText", arguments: ["text": .string("x")])),
            .init(IntentInvocation("ShareText"), bindings: ["text": 0])
        ])
        XCTAssertEqual(PlanReplayer.replay(plan, with: resolver).firstFailure?.failure,
                       .bindingSourceHasNoResult(step: 1, parameter: "text", sourceIntent: "ShareText"))
    }

    func testChainBreaksWhenAnUpstreamResultChangesType() {
        let replay = PlanReplayer.replay(Fixtures.summariseAndShare, with: IntentResolver(surface: Proposals.summaryBecomesEntity.surface))
        XCTAssertEqual(replay.firstFailure?.step, 2)
        XCTAssertEqual(replay.firstFailure?.failure.relatedChangeKeys.first, "result-type:SummarizeNote")
    }
}
