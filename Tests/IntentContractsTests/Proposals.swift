import IntentContracts

/// The same eight proposed releases the demo app ships, so the README's
/// verdict table is asserted here rather than just claimed.
enum Proposals {
    static let openDocument = IntentSchema("OpenDocument", title: "Open Note", parameters: [ParameterSchema("note", .entity("Note"))])

    static let renameForgotAlias = ContractProposal(
        title: "Rename, alias forgotten",
        summary: "OpenNote becomes OpenDocument; nobody adds an alias.",
        surface: Fixtures.surface(Fixtures.v110) { Fixtures.replaceIntent("OpenNote", in: &$0, with: openDocument) })

    static let renameWithAlias = ContractProposal(
        title: "Rename with alias",
        summary: "Same rename, plus an alias row OpenNote → OpenDocument.",
        surface: Fixtures.surface(Fixtures.v110) { s in
            Fixtures.replaceIntent("OpenNote", in: &s, with: openDocument)
            s.aliases.append(IntentAlias(from: "OpenNote", to: "OpenDocument", since: Fixtures.v110))
        })

    static func namespacedIDs(_ version: SemanticVersion) -> IntentSurface {
        Fixtures.surface(version) { $0.entities[0].idFormat = .prefixed("note-") }
    }

    static let namespacedWithShim = ContractProposal(
        title: "Namespaced IDs + shim",
        summary: "Note IDs move from 42 to note-42 in 2.0.0, with an audited ID shim.",
        surface: namespacedIDs(Fixtures.v200),
        migration: MigrationPlan(idShims: [PrefixingShim(entity: "Note", prefix: "note-")],
                                 legacyIDSamples: ["Note": Fixtures.legacyNoteIDs],
                                 liveIDSamples: ["Note": Fixtures.liveNoteIDs]))

    static let namespacedNoShim = ContractProposal(
        title: "Namespaced IDs, no shim",
        summary: "The same 2.0.0 ID change, shipped without a shim.",
        surface: namespacedIDs(Fixtures.v200))

    static func requireFolder(_ version: SemanticVersion) -> IntentSurface {
        Fixtures.surface(version) { s in
            var create = Fixtures.createNote
            create.parameters.append(ParameterSchema("folder", .entity("Folder")))
            Fixtures.replaceIntent("CreateNote", in: &s, with: create)
        }
    }

    static let requiredFolderMinor = ContractProposal(
        title: "Required folder as 1.1",
        summary: "CreateNote gains a required folder parameter in a minor release.",
        surface: requireFolder(Fixtures.v110))

    static let requiredFolderBackfilled = ContractProposal(
        title: "Required folder + backfill",
        summary: "Same parameter in 2.0.0; old callers get the Inbox folder.",
        surface: requireFolder(Fixtures.v200),
        migration: MigrationPlan(backfills: [ArgumentBackfill(intent: "CreateNote", parameter: "folder", value: .entity(type: "Folder", id: Fixtures.inboxFolder))]))

    static let removeArchiveOnSchedule = ContractProposal(
        title: "Remove ArchiveNote on schedule",
        summary: "ArchiveNote was deprecated in 0.9 with removal allowed from 2.0.0.",
        surface: Fixtures.surface(Fixtures.v200) { Fixtures.replaceIntent("ArchiveNote", in: &$0, with: nil) })

    static let summaryBecomesEntity = ContractProposal(
        title: "Summary becomes an entity",
        summary: "SummarizeNote returns a Note instead of text, in a minor release.",
        surface: Fixtures.surface(Fixtures.v110) { s in
            var summarize = Fixtures.summarize
            summarize.result = .entity("Note")
            Fixtures.replaceIntent("SummarizeNote", in: &s, with: summarize)
        })

    static let all = [renameForgotAlias, renameWithAlias, namespacedWithShim, namespacedNoShim,
                      requiredFolderMinor, requiredFolderBackfilled, removeArchiveOnSchedule, summaryBecomesEntity]
}
