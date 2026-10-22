import XCTest
import Foundation
@testable import IntentContracts

final class SemanticVersionTests: XCTestCase {
    func testParsesOnlyStrictTriples() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("0.0.0"), SemanticVersion(0, 0, 0))
        for bad in ["", "1", "1.2", "1.2.3.4", "1..3", "-1.0.0", "a.b.c", "1.2.3-beta", " 1.2.3", "1.2.+3", "99999999999999999999.0.0", "١.٢.٣"] {
            XCTAssertNil(SemanticVersion(bad), "accepted \(bad)")
        }
    }

    func testNegativeLiteralsClampInsteadOfTrapping() {
        XCTAssertEqual(SemanticVersion(-4, -1, 2), SemanticVersion(0, 0, 2))
    }

    func testBumpSaturatesAtIntMax() {
        let top = SemanticVersion(Int.max, Int.max, Int.max)
        XCTAssertEqual(top.bumped(.major).major, Int.max)
        XCTAssertEqual(top.bumped(.minor).minor, Int.max)
        XCTAssertEqual(top.bumped(.patch).patch, Int.max)
        XCTAssertEqual(SemanticVersion(1, 4, 9).bumped(.major), SemanticVersion(2, 0, 0))
        XCTAssertEqual(SemanticVersion(1, 4, 9).bumped(.minor), SemanticVersion(1, 5, 0))
    }

    func testBumpLevelDetectsEachLevelAndRegression() {
        let base = SemanticVersion(1, 2, 3)
        XCTAssertEqual(SemanticVersion(2, 0, 0).bumpLevel(from: base), .major)
        XCTAssertEqual(SemanticVersion(1, 3, 0).bumpLevel(from: base), .minor)
        XCTAssertEqual(SemanticVersion(1, 2, 4).bumpLevel(from: base), .patch)
        XCTAssertEqual(base.bumpLevel(from: base), BumpLevel.none)
        XCTAssertNil(SemanticVersion(1, 2, 2).bumpLevel(from: base))
        XCTAssertNil(SemanticVersion(0, 99, 99).bumpLevel(from: base))
    }

    func testCodableUsesStringAndRejectsGarbage() throws {
        let data = try JSONEncoder().encode([SemanticVersion(3, 1, 4)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"3.1.4\"]")
        XCTAssertEqual(try JSONDecoder().decode([SemanticVersion].self, from: data), [SemanticVersion(3, 1, 4)])
        XCTAssertThrowsError(try JSONDecoder().decode([SemanticVersion].self, from: Data("[\"3.1\"]".utf8)))
    }
}

final class EntityIDFormatTests: XCTestCase {
    func testFormats() {
        XCTAssertTrue(EntityIDFormat.integer.matches("0042"))
        XCTAssertFalse(EntityIDFormat.integer.matches(""))
        XCTAssertFalse(EntityIDFormat.integer.matches("-1"))
        XCTAssertFalse(EntityIDFormat.integer.matches("4 2"))
        XCTAssertTrue(EntityIDFormat.prefixed("note-").matches("note-1"))
        XCTAssertFalse(EntityIDFormat.prefixed("note-").matches("note-"))
        XCTAssertFalse(EntityIDFormat.prefixed("").matches("anything"))
        XCTAssertTrue(EntityIDFormat.uuid.matches(Fixtures.inboxFolder))
        XCTAssertFalse(EntityIDFormat.uuid.matches("42"))
        XCTAssertFalse(EntityIDFormat.uuid.matches("{\(Fixtures.inboxFolder)}"), "braced UUIDs are a different string, so a different stored ID")
        XCTAssertTrue(EntityIDFormat.opaque.matches("x"))
        XCTAssertFalse(EntityIDFormat.opaque.matches(""))
    }
}

final class ValidatorTests: XCTestCase {
    func testBaselineIsClean() {
        XCTAssertEqual(SurfaceValidator.validate(Fixtures.baseline), [])
    }

    func testEmptySurfaceIsValidAndDuplicatesDoNotTrap() {
        XCTAssertEqual(SurfaceValidator.validate(IntentSurface(version: Fixtures.v100)), [])
        var surface = Fixtures.baseline
        surface.intents.append(Fixtures.openNote)
        surface.entities.append(Fixtures.note)
        surface.enums.append(Fixtures.color)
        // Lookups must not trap on duplicate keys (Dictionary(uniqueKeysWithValues:) would).
        XCTAssertEqual(surface.intentsByID.count, 6)
        let issues = SurfaceValidator.validate(surface)
        XCTAssertTrue(issues.contains(.duplicateIntent("OpenNote")))
        XCTAssertTrue(issues.contains(.duplicateEntity("Note")))
        XCTAssertTrue(issues.contains(.duplicateEnum("NoteColor")))
    }

    func testAliasProblems() {
        var surface = Fixtures.baseline
        surface.aliases += [
            IntentAlias(from: "A", to: "B", since: Fixtures.v100),
            IntentAlias(from: "B", to: "A", since: Fixtures.v100),
            IntentAlias(from: "Gone", to: "Nowhere", since: Fixtures.v100),
            IntentAlias(from: "OpenNote", to: "CreateNote", since: Fixtures.v100),
            IntentAlias(from: "ShowNote", to: "CreateNote", since: Fixtures.v100)
        ]
        let issues = SurfaceValidator.validate(surface)
        XCTAssertEqual(issues.filter { if case .aliasCycle = $0 { return true }; return false }.count, 1, "one cycle, reported once")
        XCTAssertTrue(issues.contains(.aliasDangling("Gone")))
        XCTAssertTrue(issues.contains(.aliasShadowsLiveIntent("OpenNote")))
        XCTAssertTrue(issues.contains(.duplicateAlias("ShowNote")))
    }

    func testReferencesDeprecationAndIdentifiers() {
        var surface = Fixtures.baseline
        surface.intents.append(IntentSchema("Bad Name", title: "x", parameters: [
            ParameterSchema("items", .list(.entity("Ghost"))),
            ParameterSchema("mood", .enumeration("Mood")),
            ParameterSchema("dup", .string),
            ParameterSchema("other", .string, formerNames: ["dup"])
        ], deprecation: Deprecation(since: Fixtures.v200, removalNotBefore: Fixtures.v100, replacement: "Nope")))
        surface.enums.append(EnumSchema("Empty", cases: []))
        surface.entities[0].properties.append(PropertySchema("x\nintent Fake", .string))
        let issues = SurfaceValidator.validate(surface)
        XCTAssertTrue(issues.contains(.invalidIdentifier("Bad Name")))
        XCTAssertTrue(issues.contains(.unknownEntityReference(context: "Bad Name.items", entity: "Ghost")))
        XCTAssertTrue(issues.contains(.unknownEnumReference(context: "Bad Name.mood", enumeration: "Mood")))
        XCTAssertTrue(issues.contains(.duplicateParameter(intent: "Bad Name", name: "dup")))
        XCTAssertTrue(issues.contains(.deprecationWindowInverted("Bad Name")))
        XCTAssertTrue(issues.contains(.deprecationReplacementUnknown(intent: "Bad Name", replacement: "Nope")))
        XCTAssertTrue(issues.contains(.emptyEnum("Empty")))
        XCTAssertTrue(issues.contains(.invalidIdentifier("Note.x\nintent Fake")))
    }
}

final class AliasResolutionTests: XCTestCase {
    func testChainedRenamesResolveWithoutRewritingHistory() {
        let surface = Fixtures.surface(Fixtures.v110) { surface in
            Fixtures.replaceIntent("OpenNote", in: &surface, with: IntentSchema("OpenDocument", title: "Open", parameters: [ParameterSchema("note", .entity("Note"))]))
            surface.aliases.append(IntentAlias(from: "OpenNote", to: "OpenDocument", since: Fixtures.v110))
        }
        XCTAssertEqual(surface.resolveIntent("ShowNote"), .live("OpenDocument", hops: ["ShowNote", "OpenNote"]))
        XCTAssertEqual(surface.resolveIntent("OpenDocument"), .live("OpenDocument", hops: []))
        XCTAssertEqual(surface.resolveIntent("Nope"), .unknown("Nope"))
    }

    func testCycleTerminates() {
        let surface = IntentSurface(version: Fixtures.v100, aliases: [
            IntentAlias(from: "A", to: "B", since: Fixtures.v100),
            IntentAlias(from: "B", to: "C", since: Fixtures.v100),
            IntentAlias(from: "C", to: "A", since: Fixtures.v100)
        ])
        XCTAssertEqual(surface.resolveIntent("A"), .cycle(["A", "B", "C", "A"]))
    }
}
