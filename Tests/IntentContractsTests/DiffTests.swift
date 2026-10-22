import XCTest
@testable import IntentContracts

final class DiffTests: XCTestCase {
    private let differ = SchemaDiffer()

    private func diff(_ edit: (inout IntentSurface) -> Void) -> [ContractChange] {
        differ.diff(from: Fixtures.baseline, to: Fixtures.surface(Fixtures.v110, edit))
    }

    func testIdenticalSurfacesProduceNoChanges() {
        XCTAssertEqual(differ.diff(from: Fixtures.baseline, to: Fixtures.baseline), [])
    }

    func testOptionalParameterIsAdditiveRequiredIsBreaking() {
        let optional = diff { s in
            var find = Fixtures.findNotes
            find.parameters.append(ParameterSchema("pinned", .boolean, optional: true))
            Fixtures.replaceIntent("FindNotes", in: &s, with: find)
        }
        XCTAssertEqual(optional, [ContractChange(kind: .parameterAdded(intent: "FindNotes", name: "pinned", required: false), impact: .additive)])

        let required = diff { s in
            var create = Fixtures.createNote
            create.parameters.append(ParameterSchema("folder", .entity("Folder")))
            Fixtures.replaceIntent("CreateNote", in: &s, with: create)
        }
        XCTAssertEqual(required, [ContractChange(kind: .parameterAdded(intent: "CreateNote", name: "folder", required: true), impact: .breaking, key: "param-required:CreateNote.folder")])

        let defaulted = diff { s in
            var create = Fixtures.createNote
            create.parameters.append(ParameterSchema("folder", .entity("Folder"), hasDefault: true))
            Fixtures.replaceIntent("CreateNote", in: &s, with: create)
        }
        XCTAssertEqual(defaulted.map(\.impact), [.additive])
    }

    func testRenameWithAliasIsNotARemovalOrAnAddition() {
        let changes = diff { s in
            Fixtures.replaceIntent("OpenNote", in: &s, with: IntentSchema("OpenDocument", title: "Open Note", parameters: [ParameterSchema("note", .entity("Note"))]))
            s.aliases.append(IntentAlias(from: "OpenNote", to: "OpenDocument", since: Fixtures.v110))
        }
        XCTAssertEqual(changes, [ContractChange(kind: .intentRenamed(from: "OpenNote", to: "OpenDocument"), impact: .additive)])
    }

    func testRenameWithoutAliasIsRemovalPlusAddition() {
        let changes = diff { s in
            Fixtures.replaceIntent("OpenNote", in: &s, with: IntentSchema("OpenDocument", title: "Open Note", parameters: [ParameterSchema("note", .entity("Note"))]))
        }
        XCTAssertTrue(changes.contains(ContractChange(kind: .intentRemoved("OpenNote", scheduled: false), impact: .breaking, key: "intent-removed:OpenNote")))
        XCTAssertTrue(changes.contains(ContractChange(kind: .intentAdded("OpenDocument"), impact: .additive)))
    }

    func testRemovalIsScheduledOnlyOnceTheWindowHasPassed() {
        let early = differ.diff(from: Fixtures.baseline, to: Fixtures.surface(Fixtures.v110) { Fixtures.replaceIntent("ArchiveNote", in: &$0, with: nil) })
        XCTAssertEqual(early.first?.kind, .intentRemoved("ArchiveNote", scheduled: false))
        let onTime = differ.diff(from: Fixtures.baseline, to: Fixtures.surface(Fixtures.v200) { Fixtures.replaceIntent("ArchiveNote", in: &$0, with: nil) })
        XCTAssertEqual(onTime.first?.kind, .intentRemoved("ArchiveNote", scheduled: true))
        XCTAssertEqual(onTime.first?.impact, .breaking, "scheduled removals are still breaking; they just have cover")
    }

    func testParameterTypeWideningVersusChange() {
        let widened = diff { s in
            var find = Fixtures.findNotes
            find.parameters[1].type = .decimal
            Fixtures.replaceIntent("FindNotes", in: &s, with: find)
        }
        XCTAssertEqual(widened.map(\.impact), [.additive])
        let narrowed = diff { s in
            var find = Fixtures.findNotes
            find.parameters[1].type = .string
            Fixtures.replaceIntent("FindNotes", in: &s, with: find)
        }
        XCTAssertEqual(narrowed, [ContractChange(kind: .parameterTypeChanged(intent: "FindNotes", name: "limit", from: .integer, to: .string), impact: .breaking, key: "param-type:FindNotes.limit")])
    }

    func testParameterRenameAndOptionalityTransitions() {
        let changes = diff { s in
            var find = Fixtures.findNotes
            find.parameters[0] = ParameterSchema("text", .string, optional: true, formerNames: ["query"])
            find.parameters[1].isOptional = false
            Fixtures.replaceIntent("FindNotes", in: &s, with: find)
        }
        XCTAssertTrue(changes.contains(ContractChange(kind: .parameterRenamed(intent: "FindNotes", from: "query", to: "text"), impact: .additive)))
        XCTAssertTrue(changes.contains(ContractChange(kind: .parameterRelaxed(intent: "FindNotes", name: "text"), impact: .additive)))
        XCTAssertTrue(changes.contains(ContractChange(kind: .parameterBecameRequired(intent: "FindNotes", name: "limit"), impact: .breaking, key: "param-required:FindNotes.limit")))
    }

    func testResultTypesAreCovariant() {
        func changeResult(_ type: ValueType?) -> [ContractChange] {
            diff { s in
                var summarize = Fixtures.summarize
                summarize.result = type
                Fixtures.replaceIntent("SummarizeNote", in: &s, with: summarize)
            }
        }
        XCTAssertEqual(changeResult(.integer).first?.impact, .breaking, "String → Int breaks consumers")
        XCTAssertEqual(changeResult(nil).first?.impact, .breaking, "dropping a result breaks consumers")
        var decimalResult = Fixtures.baseline
        decimalResult.intents[3].result = .decimal
        var integerResult = decimalResult
        integerResult.version = Fixtures.v110
        integerResult.intents[3].result = .integer
        XCTAssertEqual(differ.diff(from: decimalResult, to: integerResult).map(\.impact), [.additive], "Decimal → Int result is safe for consumers")
        XCTAssertEqual(differ.diff(from: integerResult, to: decimalResult).map(\.impact), [.breaking], "Int → Decimal result is not")
        XCTAssertEqual(diff { s in
            var share = Fixtures.shareText
            share.result = .string
            Fixtures.replaceIntent("ShareText", in: &s, with: share)
        }.first?.impact, .additive, "adding a result is additive")
    }

    func testEntityAndEnumChanges() {
        let changes = diff { s in
            s.entities[0].idFormat = .prefixed("note-")
            s.entities[0].properties.removeAll { $0.name == "tags" }
            s.enums[0].cases = ["yellow", "blue", "pink"]
        }
        XCTAssertTrue(changes.contains(ContractChange(kind: .entityIDFormatChanged(entity: "Note", from: .integer, to: .prefixed("note-")), impact: .breaking, key: "entity-id:Note")))
        XCTAssertTrue(changes.contains(ContractChange(kind: .entityPropertyRemoved(entity: "Note", name: "tags"), impact: .breaking, key: "entity-prop:Note.tags")))
        XCTAssertTrue(changes.contains(ContractChange(kind: .enumCaseRemoved(enumeration: "NoteColor", value: "green"), impact: .breaking, key: "enum-case-removed:NoteColor.green")))
        XCTAssertTrue(changes.contains(ContractChange(kind: .enumCaseAdded(enumeration: "NoteColor", value: "pink"), impact: .additive)))

        let removals = diff { s in
            s.entities.removeAll { $0.identifier == "Folder" }
            s.entities[0].properties[0].type = .integer
            s.enums = []
        }
        XCTAssertTrue(removals.contains(ContractChange(kind: .entityRemoved("Folder"), impact: .breaking, key: "entity-removed:Folder")))
        XCTAssertTrue(removals.contains(ContractChange(kind: .entityPropertyTypeChanged(entity: "Note", name: "title"), impact: .breaking, key: "entity-prop:Note.title")))
        XCTAssertTrue(removals.contains(ContractChange(kind: .enumRemoved("NoteColor"), impact: .breaking, key: "enum-removed:NoteColor")))
    }

    func testEntityRenameKeepsParameterReferencesCompatible() {
        let changes = diff { s in
            s.entities[0] = EntitySchema("Document", idFormat: .integer, properties: Fixtures.note.properties, formerIdentifiers: ["Note"])
            for index in s.intents.indices {
                for p in s.intents[index].parameters.indices where s.intents[index].parameters[p].type == .entity("Note") {
                    s.intents[index].parameters[p].type = .entity("Document")
                }
            }
            s.intents[1].result = .entity("Document")
            s.intents[2].result = .list(.entity("Document"))
        }
        XCTAssertTrue(changes.contains(ContractChange(kind: .entityRenamed(from: "Note", to: "Document"), impact: .additive)))
        XCTAssertFalse(changes.contains { $0.impact == .breaking }, "\(changes.filter { $0.impact == .breaking })")
    }

    func testDeprecationAndRetitle() {
        let changes = diff { s in
            var share = Fixtures.shareText
            share.title = "Share"
            share.deprecation = Deprecation(since: Fixtures.v110, removalNotBefore: Fixtures.v200)
            Fixtures.replaceIntent("ShareText", in: &s, with: share)
        }
        XCTAssertEqual(Set(changes.map(\.impact)), [.cosmetic, .deprecating])
        XCTAssertEqual(ChangeImpact.cosmetic.requiredBump, .patch)
        XCTAssertEqual(ChangeImpact.deprecating.requiredBump, .minor)
        XCTAssertEqual(ChangeImpact.breaking.requiredBump, .major)
    }

    // MARK: Removing a name callers still store is breaking, even with no intent removed

    func testDeletingAnAliasRowIsBreaking() {
        let changes = differ.diff(from: Fixtures.baseline, to: Fixtures.surface(SemanticVersion(1, 0, 1)) { $0.aliases = [] })
        XCTAssertEqual(changes, [ContractChange(kind: .aliasRemoved("ShowNote", scheduled: false), impact: .breaking, key: "intent-removed:ShowNote")])
        let report = ContractGate().evaluate(baseline: Fixtures.baseline, proposed: Fixtures.surface(SemanticVersion(1, 0, 1)) { $0.aliases = [] }, plans: [])
        XCTAssertFalse(report.passed, "must block even when no recorded plan uses the alias")
    }

    func testDroppingAParameterFormerNameIsBreaking() {
        var old = Fixtures.baseline
        old.intents[2].parameters[0].formerNames = ["text"]
        var new = old
        new.version = Fixtures.v110
        new.intents[2].parameters[0].formerNames = []
        XCTAssertEqual(differ.diff(from: old, to: new), [ContractChange(kind: .parameterFormerNameDropped(intent: "FindNotes", name: "text"), impact: .breaking, key: "param-removed:FindNotes.text")])
    }

    func testDroppingAnEntityFormerIdentifierIsBreaking() {
        var old = Fixtures.baseline
        old.entities[0].formerIdentifiers = ["Memo"]
        var new = old
        new.version = Fixtures.v110
        new.entities[0].formerIdentifiers = []
        XCTAssertEqual(differ.diff(from: old, to: new), [ContractChange(kind: .entityFormerIdentifierDropped(entity: "Note", former: "Memo"), impact: .breaking, key: "entity-removed:Memo")])
    }

    func testMergingTwoParametersIntoOneIsBreaking() {
        let old = IntentSurface(version: Fixtures.v100, intents: [IntentSchema("Send", title: "Send", parameters: [
            ParameterSchema("a", .string, optional: true), ParameterSchema("b", .string, optional: true)])])
        let new = IntentSurface(version: Fixtures.v110, intents: [IntentSchema("Send", title: "Send", parameters: [
            ParameterSchema("a", .string, optional: true, formerNames: ["b"])])])
        let changes = differ.diff(from: old, to: new)
        XCTAssertTrue(changes.contains(ContractChange(kind: .parametersMerged(intent: "Send", into: "a"), impact: .breaking, key: "param-merged:Send.a")))
        let plan = AgentPlan(name: "both", origin: "test", recordedAgainst: Fixtures.v100, steps: [
            .init(IntentInvocation("Send", arguments: ["a": .string("1"), "b": .string("2")]))])
        let report = ContractGate().evaluate(baseline: old, proposed: new, plans: [plan])
        XCTAssertFalse(report.passed)
        guard case .planRegressed(_, _, let failure)? = report.findings.last else { return XCTFail("\(report.findings)") }
        XCTAssertEqual(failure.relatedChangeKeys, ["param-merged:Send.a"], "replay failure and diff agree on the key")
    }

    func testRemovedParameterNeedsCoverForEveryNameCallersSend() {
        var old = Fixtures.baseline
        old.intents[2].parameters[1] = ParameterSchema("max", .integer, optional: true, formerNames: ["limit"])
        let new = Fixtures.surface(Fixtures.v200) { s in
            s.intents[2].parameters.removeLast()
        }
        let keys = differ.diff(from: old, to: new).compactMap(\.key)
        XCTAssertEqual(keys, ["param-removed:FindNotes.max", "param-removed:FindNotes.limit"])

        let plan = AgentPlan(name: "old limit", origin: "test", recordedAgainst: Fixtures.v090, steps: [
            .init(IntentInvocation("FindNotes", arguments: ["query": .string("q"), "limit": .integer(2)]))
        ])
        let onlyMax = MigrationPlan(retiredParameters: [ParameterRetirement(intent: "FindNotes", parameter: "max")])
        let partial = ContractGate().evaluate(baseline: old, proposed: new, migration: onlyMax, plans: [plan])
        XCTAssertFalse(partial.passed)
        XCTAssertTrue(partial.changes.contains { $0.change.key == "param-removed:FindNotes.limit" && $0.coverage == .uncovered },
                      "the display must agree with the replay: 'limit' is not covered")

        let both = MigrationPlan(retiredParameters: [ParameterRetirement(intent: "FindNotes", parameter: "max"), ParameterRetirement(intent: "FindNotes", parameter: "limit")])
        XCTAssertTrue(ContractGate().evaluate(baseline: old, proposed: new, migration: both, plans: [plan]).passed)
    }
}
