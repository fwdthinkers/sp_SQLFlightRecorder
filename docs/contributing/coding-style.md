# Coding style (D-153)

There is **no auto-formatter in CI** — none handle dynamic SQL well — so style is
a code-review concern. The goal is readability at 2 AM (D-159: "boring code" is a
valid reason to request changes).

## T-SQL

- **Keywords UPPERCASE**, identifiers in their **original case**.
- **Four-space indent**; target ~**120-character** lines.
- **Schema-qualify** object names (`dbo.FR_Config`, `sys.dm_os_wait_stats`).
- **No `SELECT *`** — project columns explicitly.
- **No commented-out code.** Delete it; git remembers.
- No cursors, no `WITH RECOMPILE`; set-based throughout (D-138).
- Version-conditional code goes through `sys.sp_executesql` with parameter
  binding (D-112); no nested dynamic SQL, no dynamic SQL in rules (D-113).

## Naming (D-154)
- Tables `FR_*`; views `FR_v_*`; helper temp tables `#fr_*`; capability flags
  `@has<Feature>`.
- Rule IDs `FR_R####_ShortName` — never renamed or reused (D-089).

## Comments
- Explain constraints and *why*, not what the next line does.
- `TODO`/`FIXME` must reference a GitHub issue (D-155); untracked TODOs fail review.

## Build-pipeline code (Python/bash)
- Permitted in the build pipeline only (D-148); never required to install or use
  the tool. Keep line endings LF (`.gitattributes`).

## Wording in recommendations (§6.7)
Rule Recommendation text has its own rules — see
[safety-checklist.md](safety-checklist.md) (no "kill/force/NOLOCK/shrink/root
cause/always/never"; use "consider … only after validating …").
