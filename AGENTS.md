# AGENTS.md

## Working Agreement

Use this repository as the shared handoff point between Codex and Cursor.

When planning, interview the user until the design is clear. Ask one question at a time, and include a recommended answer with each question. If a question can be answered by reading the codebase, inspect the codebase instead of asking.

Do not jump from a broad idea directly to implementation. Resolve decisions in dependency order: product behavior, data model, runtime architecture, UI, safety/recovery, tests, and release/verification.

## Planning Handoff

Write implementation plans in `docs/plans/` as Markdown files. Use descriptive kebab-case names, for example `docs/plans/fix-scroll-remapper-edge-cases.md`.

Each plan should include:

- Goal
- Current codebase facts
- Decisions made
- Open questions, if any
- Implementation steps with checkboxes
- Files expected to change
- Tests and verification commands
- Cursor handoff prompt

Plans are allowed to be detailed, but they should be directly executable by another coding agent without requiring hidden conversation context.

## Implementation Rules

Prefer small, codebase-shaped changes. Preserve existing user work and unrelated diffs.

For this project:

- Core logic lives in `Sources/RazerCore/`.
- The menu-bar app lives in `RazerMenuBarApp/`.
- CLI diagnostics live in `Sources/RazerProbeCLI/`.
- Unit tests live in `Tests/RazerCoreTests/`.
- Xcode project generation is driven by `project.yml` and `scripts/xcode-build.sh`.

Avoid production instrumentation that writes to absolute local paths. Avoid synchronous file I/O in input event-tap paths.

## Verification

Run targeted tests for changed logic, then broader verification when practical:

```bash
swift test
xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build
```

In restricted Codex sandboxes, `swift test --disable-sandbox` may be needed when Swift writes module caches outside the workspace.

If `project.yml` changes, regenerate and build the Xcode project with:

```bash
make xcode
```
