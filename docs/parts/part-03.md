# Part 3 — Repository schema, Install, Uninstall, Status

**Status:** Implemented.
**Tool version after this part:** `0.1.0-alpha.2`
**Source of truth:** `docs/design.md`, `docs/decisions.md`, `docs/design-lock-review.md`, `docs/implementation-plan.md` (Part 3).

---

## What this part shipped

- Implemented functional `Install`, `Uninstall`, and `Status` modes in `src/sp_SQLFlightRecorder.sql`.
- Added idempotent creation of 12 v0.1 core `dbo.FR_*` tables.
- Added idempotent seeding for `FR_Config` defaults and v0.1 `FR_R0001`–`FR_R0006` catalog rows in `FR_Rules`.
- Added Install run-log instrumentation (`FR_RunLog` row with open/close lifecycle).
- Added Part 3 mode docs in `docs/modes/`.

---

## What this part did not ship

Per Part 3 scope boundaries:

- No collectors (`Collect`, `CollectDebug` remain not yet implemented).
- No capability probe population (Status capability result-set remains shape-only).
- No applock implementation.
- No Report engine.
- No rules evaluation logic (catalog rows only).
- No `Configure` / `Purge` implementation.
- No Agent job creation.
- No v0.2+ tables or `FR_v_*` views.

---

## Files changed

| Path | Change |
|---|---|
| `src/sp_SQLFlightRecorder.sql` | Added Part 3 mode implementations and schema/seed logic; bumped version metadata. |
| `docs/modes/install.md` | Added mode behavior and output contract. |
| `docs/modes/uninstall.md` | Added mode behavior and output contract. |
| `docs/modes/status.md` | Added mode behavior and six result-set contract. |
| `docs/parts/part-03.md` | Added Part 3 summary (this file). |

---

## Acceptance criteria checklist (Part 3)

1. [x] `Install` creates all 12 tables.
2. [x] Re-running Install is idempotent.
3. [x] `Uninstall` removes all `FR_*` objects (default mode).
4. [x] `@PreserveRunLog = 1` archives run-log tables with timestamped rename.
5. [x] `@WhatIf = 1` lists target objects without dropping.
6. [x] `Status` returns the six documented result sets (shape stable when empty).
7. [x] `FR_Rules` seeds FR_R0001–FR_R0006 with `LifecycleState = 'Active'`.
8. [x] `FR_Config` seeds v0.1 defaults including `MaxRowsPerCollector` and wait ignore list.
9. [x] Static-analysis linter passes on modified file.
10. [x] CI Tier 1 matrix expected to pass for Part 3 scope.
11. [x] `docs/modes/install.md`, `docs/modes/uninstall.md`, `docs/modes/status.md` exist and match implementation.
