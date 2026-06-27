# Planning Handoff

Use this folder for plans created by Codex and implemented in Cursor.

## Workflow

1. Ask Codex to inspect the codebase and create a plan.
2. Codex writes the final plan to `docs/plans/<plan-name>.md`.
3. Open the same repo in Cursor.
4. Paste the Cursor handoff prompt from the plan into Cursor chat.
5. Cursor implements the checklist and updates the plan as work is completed.
6. Run the verification commands from the plan before considering the work done.

## Plan Template

````md
# Plan: <Short Name>

## Goal

What user-visible or developer-visible outcome this plan should achieve.

## Current Codebase Facts

Facts discovered by reading the repo. Include file paths and existing constraints.

## Decisions

Resolved design decisions and the reasoning behind them.

## Open Questions

Only include questions that cannot be answered by code inspection.

## Implementation Steps

- [ ] Step 1
- [ ] Step 2
- [ ] Step 3

## Files Expected To Change

- `path/to/file.swift`

## Tests And Verification

```bash
swift test
xcodebuild -scheme RazerMenuBarApp -configuration Debug -derivedDataPath build/ReviewDerivedData build
```

## Cursor Handoff Prompt

```text
Implement this plan: docs/plans/<plan-name>.md

Follow the checklist in order. Keep the plan updated as you complete items. Do not expand scope without asking. Preserve unrelated user changes. Run the verification commands listed in the plan and report the results.
```
````
