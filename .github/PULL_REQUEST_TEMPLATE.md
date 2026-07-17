<!--
================================================================================
Pull Request — sp_SQLFlightRecorder
Per docs/decisions.md D-157 (charter-compliance checklist).

Keep this template short. The goal is a deliberate gate, not paperwork. If a
section does not apply, write "n/a — <one-line reason>". Do not delete sections.
================================================================================
-->

## What and why

<!-- One paragraph. What changes, and which design decision / part of the
implementation plan it advances. Link the relevant decision IDs (D-###) and
section numbers in docs/design.md where applicable. -->

## Implementation plan part

- [ ] This PR implements exactly one implementation-plan part.
- Part number: <!-- e.g., Part 2 -->
- Closes / advances: <!-- decision IDs, sections, issues -->

## Charter compliance checklist (D-157)

Tick every box or replace it with "n/a — <reason>". Reviewers must confirm.

- [ ] Pure T-SQL in the shipped artifact. External tooling (Python / bash / YAML) is CI-only or local-dev-only and is NOT required on a user's SQL Server (D-148).
- [ ] No required CLR, PowerShell, external services, agents, or libraries on the user path.
- [ ] No permanent server or database changes by default. Any optional change is reversible and gated behind explicit opt-in.
- [ ] No `BEGIN TRAN` / `BEGIN TRANSACTION` introduced (D-138). Allow-listed exceptions documented inline with `-- lint:allow FR-LINT-004 reason: ...`.
- [ ] No forbidden DMVs / procs introduced (D-136; see `tests/static-analysis/forbidden_dmvs.txt`).
- [ ] No plan XML shredding in T-SQL (D-015, D-046).
- [ ] No CROSS APPLY against unbounded fan-out (D-046).
- [ ] No new external SELECT without `TOP(n) ORDER BY` or small-DMV allow-list entry (D-137).
- [ ] No new `SELECT *` (D-153).
- [ ] All new procedure bodies set the D-132 session-level safety primitives at the top.
- [ ] Collection budget intact: no new collector step pushes the per-snapshot budget above 30 seconds (Charter §1, Part 4/5/8 gates).
- [ ] No new behavior added on a user's SQL Server beyond what this implementation-plan part scopes.

## Scope discipline

- [ ] No code from a later implementation-plan part is included.
- [ ] No code from an earlier part is silently modified except as documented in this PR description.
- [ ] No new public-contract additions to existing result sets (D-023, D-085) without an explicit `Added in vX.Y` note.

## Tests / verification

<!-- For Parts 1–2: smoke tests in CI. For Parts 3+: cost-regression results,
golden-output diffs, repro of any new rule against its fixture, etc. Paste or
link the relevant output. -->

- [ ] `ci-tier1` workflow is green (Tier 1 matrix per D-120).
- [ ] Static-analysis linter is green, including `--self-test`.
- [ ] Manually executed the install script on at least one Tier 1 target locally (`scripts/run-local-tier1.sh`). If not possible, explain.

## Decision log / docs

- [ ] If this PR changes a decision in `docs/decisions.md`, the decision entry is amended (not silently overwritten) with date and rationale.
- [ ] If this PR ships a new implementation-plan part, `docs/parts/part-NN.md` is added or updated.
- [ ] No design-doc fact is contradicted without an accompanying decision update.

## Risks and follow-ups

<!-- One short list. "None known" is a valid answer. Anything noted here should
either be tracked as an issue or scheduled into a later implementation-plan part. -->

---

<!-- Reviewers: two-reviewer rule (D-158) applies for changes to any of:
  - sp_SQLFlightRecorder.sql
  - tests/static-analysis/forbidden_dmvs.txt
  - tests/static-analysis/allow_list_small_dmvs.txt
  - docs/design.md, docs/decisions.md
  - .github/workflows/**
-->
