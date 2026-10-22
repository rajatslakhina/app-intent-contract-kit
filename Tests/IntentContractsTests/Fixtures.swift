import IntentContracts

/// A small notes app's published intent surface, the plans recorded against
/// it, and the proposed releases the gate is asked to judge.
enum Fixtures {
    static let v090 = SemanticVersion(0, 9, 0)
    static let v100 = SemanticVersion(1, 0, 0)
    static let v110 = SemanticVersion(1, 1, 0)
    static let v200 = SemanticVersion(2, 0, 0)

    static let note = EntitySchema("Note", idFormat: .integer, properties: [
        PropertySchema("title", .string),
        PropertySchema("tags", .list(.string))
    ])
    static let folder = EntitySchema("Folder", idFormat: .uuid, properties: [PropertySchema("name", .string)])
    static let color = EnumSchema("NoteColor", cases: ["yellow", "blue", "green"])

    static let openNote = IntentSchema("OpenNote", title: "Open Note", parameters: [ParameterSchema("note", .entity("Note"))])
    static let createNote = IntentSchema("CreateNote", title: "Create Note", parameters: [
        ParameterSchema("title", .string),
        ParameterSchema("body", .string, optional: true),
        ParameterSchema("color", .enumeration("NoteColor"), hasDefault: true)
    ], result: .entity("Note"))
    static let findNotes = IntentSchema("FindNotes", title: "Find Notes", parameters: [
        ParameterSchema("query", .string),
        ParameterSchema("limit", .integer, optional: true)
    ], result: .list(.entity("Note")))
    static let summarize = IntentSchema("SummarizeNote", title: "Summarize Note", parameters: [ParameterSchema("note", .entity("Note"))], result: .string)
    static let archive = IntentSchema("ArchiveNote", title: "Archive Note", parameters: [ParameterSchema("note", .entity("Note"))],
                                      deprecation: Deprecation(since: v090, removalNotBefore: v200))
    static let shareText = IntentSchema("ShareText", title: "Share Text", parameters: [ParameterSchema("text", .string)])

    static let baseline = IntentSurface(
        version: v100,
        intents: [openNote, createNote, findNotes, summarize, archive, shareText],
        entities: [note, folder],
        enums: [color],
        aliases: [IntentAlias(from: "ShowNote", to: "OpenNote", since: v100)]
    )

    // MARK: Recorded plans

    static let openNote42 = AgentPlan(name: "Open note 42", origin: "Siri Shortcut", recordedAgainst: v100, steps: [
        .init(IntentInvocation("OpenNote", arguments: ["note": .entity(type: "Note", id: "42")]))
    ])
    static let legacyShowNote = AgentPlan(name: "Show note 7", origin: "Shortcut saved on 0.9", recordedAgainst: v090, steps: [
        .init(IntentInvocation("ShowNote", arguments: ["note": .entity(type: "Note", id: "7")]))
    ])
    static let summariseAndShare = AgentPlan(name: "Capture, summarise, share", origin: "Agent plan", recordedAgainst: v100, steps: [
        .init(IntentInvocation("CreateNote", arguments: ["title": .string("Standup")])),
        .init(IntentInvocation("SummarizeNote"), bindings: ["note": 0]),
        .init(IntentInvocation("ShareText"), bindings: ["text": 1])
    ])
    static let archiveOld = AgentPlan(name: "Archive note 3", origin: "Shortcut saved on 0.9", recordedAgainst: v090, steps: [
        .init(IntentInvocation("ArchiveNote", arguments: ["note": .entity(type: "Note", id: "3")]))
    ])
    static let quickCapture = AgentPlan(name: "Quick capture", origin: "Agent plan", recordedAgainst: v100, steps: [
        .init(IntentInvocation("CreateNote", arguments: ["title": .string("Idea"), "color": .enumCase("yellow")]))
    ])

    static let plans = [openNote42, legacyShowNote, summariseAndShare, archiveOld, quickCapture]

    // MARK: Helpers for building proposals

    static func surface(_ version: SemanticVersion, _ edit: (inout IntentSurface) -> Void) -> IntentSurface {
        var copy = baseline
        copy.version = version
        edit(&copy)
        return copy
    }

    static func replaceIntent(_ id: String, in surface: inout IntentSurface, with replacement: IntentSchema?) {
        guard let index = surface.intents.firstIndex(where: { $0.identifier == id }) else { return }
        if let replacement {
            surface.intents[index] = replacement
        } else {
            surface.intents.remove(at: index)
        }
    }

    static let legacyNoteIDs = ["3", "7", "42", "108"]
    static let liveNoteIDs: Set<String> = ["note-3", "note-7", "note-42", "note-108"]
    static let inboxFolder = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
}
