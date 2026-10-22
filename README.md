# IntentContracts

**Your App Intents are now an API that AI calls. This package versions and contract-tests them like one.**

In iOS 27, App Intents are how Siri, Apple Intelligence, Spotlight and in-app agents reach your app. Every saved Shortcut and every agent plan stores your intent identifiers, parameter names and entity IDs. Rename `OpenNote` to `OpenDocument`, switch note IDs from `42` to `note-42`, or add a required parameter, and those callers break silently. Users only find out when Siri says "something went wrong."

`IntentContracts` treats the intent surface as a published, semantically versioned API. It provides:

- a **schema snapshot** you commit next to your intents, with a fingerprint that is the same on every platform;
- a **diff gate** that classifies each change as cosmetic, additive, deprecating or breaking, and works out the version bump the release needs;
- **executable migrations** (alias chains, parameter renames, backfills, retirements, entity-ID shims). The CI gate checks these, and the **same values** run in the app's resolver;
- **replay of recorded Shortcuts and agent plans**, including multi-step plans where one step's result feeds the next, against the proposed release.

Demo app: **[app-intent-contract-demo-app](https://github.com/rajatslakhina/app-intent-contract-demo-app)** (a separate Xcode project that consumes this package as a version-pinned remote dependency)

---

## Why this matters

App Intents look like UI code, but they behave like a public API with clients you can't see or update:

| Client | What it stores | What breaks it |
|---|---|---|
| A user's saved Shortcut | intent identifier, parameter names, entity IDs | renames, ID format changes, new required parameters |
| Siri / Apple Intelligence | your published schema | removed intents, changed parameter types |
| An agent's cached plan | a *chain* of intents, where step 2 consumes step 1's result | a changed **result** type, even when every intent still exists |

None of these clients fail at compile time. On a team, the person who renames an intent is rarely the person who gets the bug report. So this is a governance question for the lead: what counts as a breaking change, who may ship one, and what proves an old caller still works?

## What's in the package

```
IntentContracts            (Foundation only; builds and tests on Linux)
├── IntentSurface          schema: intents, parameters, entities (+ ID format), enums, alias table
├── SurfaceValidator       structural checks: duplicates, dangling/cyclic aliases, unknown references
├── CanonicalForm          platform-independent line format + FNV-1a fingerprint
├── CommittedSnapshot      "did someone change an intent without regenerating the snapshot?"
├── SchemaDiffer           classifies every change → ChangeImpact + a stable ChangeKey
├── MigrationPlan          ID shims, backfills, retirements, signed break-glass
├── IDStabilityAudit       a shim must be total, injective, well-formed and land on real IDs
├── IntentResolver         runtime: old invocation → live intent, through the migration plan
├── PlanReplayer           multi-step plans, with result→parameter bindings type-checked
└── ContractGate / Lab     the three checks combined into one verdict

IntentContractsUI          ContractLabView: SwiftUI view over a ContractLab (renders, computes nothing)
```

### The gate runs three independent checks

1. **Classification.** `SchemaDiffer` compares the published baseline with the proposal. The declared version must be at least the worst change's required bump: patch for cosmetic, minor for additive or deprecating, major for breaking.
2. **Coverage.** Every breaking change needs a cover. It is either a removal whose deprecation window has passed, or it has an executable shim (an ID shim audited against real IDs, a backfill, or a retirement), or it carries a **signed** `AcceptedBreak` on a major release. A blank justification doesn't count as a signature.
3. **Replay.** Every recorded Shortcut and agent plan that worked against the baseline must still work against the proposal, through the same `MigrationPlan` the app ships.

Check 3 does not trust check 1. `testLyingDifferIsCaughtByReplay` swaps in a differ that reports nothing, and the release is still blocked by replay alone.

### The eight proposals in the demo (asserted in `GateTests.testVerdictTable`)

| Proposed release | Verdict | Why |
|---|---|---|
| Rename `OpenNote` → `OpenDocument`, alias forgotten (1.1.0) | **Blocked** | dangling 0.9 alias, needs major, 2 Shortcuts regress |
| Same rename + alias row (1.1.0) | Pass | 0.9 `ShowNote` resolves in 2 hops: `ShowNote → OpenNote → OpenDocument` |
| Note IDs `42` → `note-42` + audited shim (2.0.0) | Pass | 3 stored-ID plans rescued; audit: 4/4 IDs mapped, 0 collisions |
| Same ID change, no shim (2.0.0) | **Blocked** | uncovered break; stored IDs unresolvable |
| Required `folder` on `CreateNote` (1.1.0) | **Blocked** | needs major; both CreateNote plans regress |
| Required `folder` + Inbox backfill (2.0.0) | Pass | old callers get the Inbox folder |
| Remove deprecated `ArchiveNote` on schedule (2.0.0) | Pass | window honoured; the 0.9 Shortcut is an *accepted* break |
| `SummarizeNote` returns a Note, not text (1.1.0) | **Blocked** | no intent removed, but the 3-step agent plan breaks at step 3 |

The last row is the one a reviewer misses. Every intent still exists and every single-step Shortcut still works, but the agent plan chains `SummarizeNote → ShareText`, and that chain no longer type-checks.

## Design decisions and trade-offs

**The migration plan is shared between CI and runtime.** The gate checks the same `MigrationPlan` value that `IntentResolver` applies when Siri replays a two-year-old Shortcut. *Rejected:* a separate "compatibility checklist" in CI. It drifts from the code that actually runs.

**"Worked before" means "worked through the published release's own shims".** The baseline is replayed with the migration plan that release shipped (`baselineMigration`). Any ID shim, backfill or retirement it had and the proposal drops is itself a breaking change (`testDroppingThePublishedShimIsABreak`). *Rejected:* replaying the baseline raw. Then a Shortcut kept alive by last release's shim looks "already broken", and deleting the shim sails through.

**A shim makes a break safe, but it doesn't make it non-breaking.** A backfilled required parameter still demands 2.0.0 (`testBackfillCoversButStillDemandsMajor`). Our resolver handles old callers, but anything reading the schema directly, such as Siri's parameter prompting or a third-party agent, still sees a new required field. *Rejected:* letting a shim downgrade the bump. It would hide the break from exactly the clients you can't patch.

**Aliases are an append-only table, not a field on each intent.** Renames chain (`ShowNote → OpenNote → OpenDocument`) without editing history. "Append-only" is enforced rather than hoped for: deleting an alias row that used to resolve is a breaking change, and so is dropping a parameter's former name or an entity's former identifier. These are names callers have stored, even when no intent disappears. A deleted alias is only excused as a scheduled removal when its target intent is itself removed on schedule. Deleting the row while the target still lives is an unforced break. The cost of chaining is that cycles become possible, so resolution is bounded (`aliases.count + 1` hops plus a visited set), the validator reports each cycle once, and a chain that ends nowhere is reported as a dangling alias rather than an unknown name. *Rejected:* `aliases: [String]` on the intent, which silently breaks the v0.9 Shortcut on the second rename.

**Hand-written canonical form instead of `JSONEncoder(.sortedKeys)`.** Foundation's JSON output (slash escaping, number formatting, how synthesized `Codable` encodes enums with payloads) is not a cross-platform contract. A golden fingerprint (`0c05df0fc7afb540`) is asserted by the test suite, which both CI jobs (Linux and macOS) run, so a platform-dependent fingerprint fails one of them. It was also cross-checked against an independent Python FNV-1a over the same text. *Rejected:* `Hasher`, which is randomly seeded per process, and SHA-256 via CryptoKit, which isn't available on Linux and protects against a threat (forged collisions) that isn't the risk here.

**Every name a caller might send needs its own cover.** A removed parameter is reported once for its current name and once for each former name, and a `ParameterRetirement` covers exactly one name. A retirement applies to literal and plan-bound arguments alike. Merging two old parameters into one is breaking, because a caller that sends both is rejected (`param-merged` key). The gate's change list and the replay are meant to agree on what is covered, for executable covers and for signed breaks alike. `testSignedBreakOnTheDiffKeyExcusesTheReplayFailure` checks this table-style, one row per kind of break: removed intent, removed, required or retyped parameter, ID format, removed entity, removed enum case, result retyped or removed, and dropped backfill. Each row asserts that the replay failure carries the differ's key, and that a signed break on that key turns the regression into an accepted break.

**The resolver is strict by default.** An argument it can't place is an error unless the release explicitly retires it. Passing an old and a new parameter name together is rejected, not merged. *Rejected:* silently dropping unknown arguments, which turns "the Shortcut broke" into "the Shortcut did something else."

**Results are covariant, parameters are contravariant.** `Int → Decimal` on a parameter is widening (additive). On a result, `Decimal → Int` is safe and `String → Note` breaks downstream steps. The differ and the plan replayer use the same rules.

**ID shims are audited, not trusted.** Every shim a release ships is audited on every release, not only in the release that changed the ID format, so a lossy shim swapped in later is still caught (`testEveryShippedShimIsAuditedEvenWithoutAFormatChange`). `IDStabilityAudit` rejects a shim that is unaudited (empty sample), lossy (`nil`), orphaning (maps to an ID that doesn't exist after migration), malformed, or non-injective (two old notes become one). A non-injective shim is the worst failure: "open my note" opens someone else's note.

**Break-glass exists, but it's expensive.** `AcceptedBreak` needs a key, a non-blank justification, a named approver and a major version. A governance tool with no escape hatch gets bypassed; one with a cheap escape hatch gets abused.

### Failure modes handled

- Duplicate declarations: lookups use `uniquingKeysWith`, so the app never traps on load, and the validator reports the duplicate.
- Alias cycles and dangling aliases: reported, never followed forever.
- Plan bindings with negative, forward, self-referencing, `Int.max` or `Int.min` indices: rejected before any array access.
- A binding to a step with no result: rejected.
- Version components at `Int.max`: bumps saturate, they don't trap. Non-ASCII digits and overflowing components are rejected by the parser.
- An empty plan is a failure, not a vacuous success. An empty ID sample makes a shim unaudited, not stable.

There is no shared mutable state in the core module, so there are no actors and no reentrancy windows. Every type is a `Sendable` value, and the gate is a pure function of its inputs.

### What this does not do (yet)

- **It does not extract the schema from your compiled intents.** The surface is declared alongside them. The natural next step is to generate `IntentSurface` from the app's App Intents metadata, or to assert it from iOS 27's `AppIntentsTesting` out-of-process tests. That needs Xcode 27, and none of this repo's CI runs it.
- **It does not run `AppIntentsTesting`.** Replay here is a model of invocation (identifier, arguments, entity IDs, bindings), not a live app process.
- **Adding an enum case is classified as additive everywhere.** That is right for parameters, but a consumer that switches exhaustively over an enum *result* or entity property can break. Classifying it by usage is a known gap.
- Recorded plans are fixtures. In production you would sample them, with consent, from intent donations or agent logs.

## Use it

```swift
.package(url: "https://github.com/rajatslakhina/app-intent-contract-kit.git", from: "1.0.0")
```

```swift
import Foundation
import IntentContracts

let report = ContractGate().evaluate(
    baseline: publishedSurface,          // decoded from the committed snapshot
    proposed: surfaceInThisBranch,
    baselineMigration: shippedMigration, // what the published release's resolver does today
    migration: migrationPlan,            // the same value this release's resolver will use
    plans: recordedShortcutsAndAgentPlans)

guard report.passed else {
    report.findings.forEach { print("✗", $0) }
    exit(1)
}
```

At runtime:

```swift
let resolver = IntentResolver(surface: liveSurface, migration: migrationPlan)
switch resolver.resolve(IntentInvocation("ShowNote", arguments: ["note": .entity(type: "Note", id: "42")])) {
case .success(let call):
    print(call.intent, call.notes)   // "OpenDocument", ["Resolved ShowNote → OpenDocument via alias", "Migrated Note id 42 → note-42"]
case .failure(let failure):
    print(failure, failure.relatedChangeKeys)   // typed, plus the ChangeKeys a migration could have covered
}
```

## Verification

- **Local (Linux, Swift 6.0.3):** a clean `swift build -Xswiftc -warnings-as-errors` succeeds, and `swift test` runs **75 tests, 0 failures**.
- **Mutation spot-checks (run by hand, not in CI):** fifteen deliberate bugs, each caught by at least one test:
  - disabling plan-regression findings;
  - ignoring ID collisions;
  - treating alias cycles as unknown;
  - missing optional→required transitions;
  - accepting duplicate old/new argument names;
  - removing title escaping;
  - ignoring deleted alias rows;
  - removing Decimal→Int result covariance;
  - removing the backslash escape;
  - removing the carriage-return escape;
  - replaying the baseline without its shims;
  - missing parameter merges;
  - dropping the `missingArgument` replay key;
  - dropping the `unknownEnumCase` replay key;
  - auditing only shims that arrive with a format change.
- **The SwiftUI target is compiled only in CI.** `IntentContractsUI` is wrapped in `#if canImport(SwiftUI)`, so the Linux build compiles it as an empty module. The only place it has been compiled is the macOS CI job above. It has not been run.
- **CI ([Actions](https://github.com/rajatslakhina/app-intent-contract-kit/actions)):** both jobs passed on the first push of the code (commit `926b9a5`):
  - **Linux** (`swift:6.0` container): `swift build` and `swift test` with warnings as errors.
  - **macOS 15:** `swift test` with warnings as errors, then `xcodebuild build` of both products (including `IntentContractsUI`) for `generic/platform=iOS Simulator`.

  Both jobs run the golden-fingerprint test, so the fingerprint held on both platforms.
- **Simulator:** see the demo repo for exactly what was and wasn't run.

## License

MIT
