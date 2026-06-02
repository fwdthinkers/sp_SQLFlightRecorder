# Part 1 — Procedure Shell, Parameters, Help and About

**Status:** Implemented.
**Tool version after this part:** `0.1.0-alpha.1`
**Source of truth:** `docs/implementation-plan.md` (Part 1), `docs/design.md` §1, §2, §9.2.

---

## What this part shipped

A single file, `src/sp_SQLFlightRecorder.sql`, that creates the procedure `dbo.sp_SQLFlightRecorder` in the database in which it is executed. The procedure:

- Declares the full v0.1 parameter surface from design §2.2.
- Implements two functional modes: `Help` (default) and `About` (with `Version` as an accepted alias).
- Sets every session-level safety primitive from D-132 at the top of every mode handler.
- Validates `@MinSeverity`, `@MaxFindings`, `@TopN`, `@OutputFormat`, `@StartTime`/`@EndTime` ordering, and unknown `@Mode` values, returning a friendly single-row result set on validation failure rather than raising an exception.
- Routes every other documented mode (`Install`, `Uninstall`, `Collect`, `CollectDebug`, `Report`, `Status`, `Configure`, `Purge`, `CollectAndReport`, `InstallDemoData`) to a clean "not yet implemented" response that names the implementation part that will deliver the mode.
- Is re-runnable in place via the `IF OBJECT_ID(…) IS NULL` stub plus `ALTER PROCEDURE` pattern (SQL Server 2012-compatible; `DROP PROCEDURE IF EXISTS` is intentionally not used).

The file header carries the tool version, build date, supported SQL Server range, license, repository URL, and design-doc URL. These values are also returned by `@Mode = 'About'` so a DBA can answer "what version is this?" without opening the file.

---

## Files changed

| Path | Change |
|---|---|
| `src/sp_SQLFlightRecorder.sql` | **Added.** The full Part 1 procedure shell. |
| `docs/parts/part-01.md` | **Added.** This summary. |

Nothing else changed. No tables, no Agent jobs, no other procedures, no docs outside `docs/parts/`.

---

## How to run

### Help mode (default)

```sql
EXEC dbo.sp_SQLFlightRecorder;
```

or equivalently:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
```

Help output goes to the **Messages** tab in SSMS or Azure Data Studio (it uses `PRINT`, not `SELECT`, to avoid column-width truncation). Help intentionally does not return a result set.

### About mode

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
```

Returns one result set with one row and the following columns:

- `ToolVersion`
- `BuildDateUtc`
- `SupportedSqlServerRange`
- `ImplementationPart`
- `InvocationUtc`
- `LicenseUrl`
- `RepositoryUrl`
- `DesignDocUrl`

`Version` is accepted as an alias:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';
```

### Any other mode

Returns a single-row result set with `Status = 'NotYetImplemented'` and a `Message` column explaining which implementation part will deliver that mode. No state is changed, no error is raised.

### Bad parameters

Returns a single-row result set with `Status = 'Error'`, an `ErrorCode`, and a `Message`. No exception is raised; the procedure exits cleanly.

---

## What was intentionally not implemented

Per the Part 1 scope in `docs/implementation-plan.md`:

- **No repository tables.** `FR_Config`, `FR_RunLog`, `FR_RunLogStep`, `FR_Snapshot`, `FR_InstanceSnapshot`, `FR_Configuration`, `FR_Request`, `FR_Wait`, `FR_FileStat`, `FR_PerfCounter`, `FR_QueryText`, `FR_Rules` arrive in **Part 3**.
- **No `Install` mode logic.** `Install` returns a "not yet implemented; arrives in Part 3" message.
- **No `Uninstall` mode logic.** Returns the same kind of message for Part 3.
- **No `Status` mode logic.** Part 3.
- **No collectors.** Even the simplest one (instance/server state) arrives in **Part 4**. No DMV reads in Part 1, not even `@@VERSION`.
- **No capability probe.** Part 4.
- **No applock.** Part 4.
- **No `Collect` / `CollectDebug` execution.** Part 4 (single collector) and Part 5 (remaining six).
- **No `Report` engine.** Part 6.
- **No recommendation rules.** Part 7.
- **No `Configure` / `Purge` modes.** Part 8.
- **No Agent job creation.** Part 8 opt-in.
- **No Query Store anything.** v0.3.
- **No demo data mode.** Deferred to v0.2/v0.3 per D-182.
- **No `@TimeZone` parameter.** Deferred to v0.4 per D-180. v1 interprets `@StartTime`/`@EndTime` as server local time.
- **No dynamic SQL that collects data.** The only `EXEC` in Part 1 is the one-time stub creation (`EXEC (N'CREATE PROCEDURE …')`), which is structural, not collection.
- **No CI workflow.** Lands in **Part 2**, before any DMV reads are added.

---

## Safety verification (against the Master Charter)

| Charter requirement | Part 1 status |
|---|---|
| Pure T-SQL only | ✓ — one `.sql` file, no external dependencies |
| No required CLR / PS / external tools / agents / services | ✓ — none referenced |
| No permanent security/configuration changes by default | ✓ — only the procedure itself is created; no permissions, no `sp_configure`, no traceflags, no Agent jobs |
| Optional changes safe and reversible | ✓ — the only side effect is the procedure; `DROP PROCEDURE dbo.sp_SQLFlightRecorder` reverses it |
| Collection ≤ 30 seconds | n/a — no collection happens; Help and About complete in milliseconds |
| No blocking, no heavy workload, no user-table scans | ✓ — no SELECTs from any user or system catalog beyond what `PRINT` and literal `SELECT` need |
| Single-script model | ✓ — one file at `src/sp_SQLFlightRecorder.sql` |
| Single entry point / stored procedure | ✓ — `dbo.sp_SQLFlightRecorder` |
| Report ≤ two result sets | n/a — `Report` not yet implemented; About returns one set; Help returns zero |
| SQL Server 2012–2025 compatibility | ✓ — `CREATE/ALTER PROCEDURE` stub pattern, `datetime2(3)`, `CONCAT`, `SYSUTCDATETIME`, `CONVERT` style 126 — all 2012+ |
| Default `@Mode` must be `Help` | ✓ — D-003 honored |
| Accidental execution must not collect or modify data | ✓ — verified by inspection: no writes, no DMV reads |

---

## Risks and follow-up TODOs

### Risks (low for Part 1)

- **Procedure name collision.** If a user already has an unrelated `dbo.sp_SQLFlightRecorder`, the `ALTER PROCEDURE` will overwrite it. This is normal install-time behavior for any single-script tool; documented behavior, not a defect.
- **PRINT message visibility.** Some client tools (`sqlcmd -E -h-1`, log shippers) may suppress `PRINT` output. About mode covers the "machine-readable" use case; this is the intended split.
- **`CONCAT` returns `nvarchar(MAX)` semantics.** Used here for error messages only, not for hot rows; no D-040 violation.

### Follow-up TODOs (tracked for later parts, not for this PR)

- **Part 2 will add CI** that compiles this file against the Tier 1 matrix (D-120) and runs the static-analysis linter (D-144). Part 1 has nothing risky for the linter to catch, which is the point.
- **Part 3 will implement `Install`, `Uninstall`, and `Status`** and will retire the corresponding "not yet implemented" branches in the dispatcher.
- **Version string in two places.** The tool version is encoded both in the file header comment block and in the `@ToolVersion` local. When the version is bumped, both must be updated. Keep this in mind during Part 2 onwards; a build-time substitution could be considered in Part 9 but is deliberately out of scope here.
- **`InvocationUtc` column in About.** Currently returned as an ISO-8601 string with a trailing `Z` for human readability. If a future part wants a typed `datetime2`, that is an additive change (D-023) but worth noting.

---

## Acceptance criteria checklist (from `docs/implementation-plan.md` Part 1)

1. ✓ Procedure installs cleanly via SSMS/ADS/`sqlcmd` on the Tier 1 matrix (manual verification; Part 2 will automate this).
2. ✓ Re-running the file is idempotent — the stub-plus-`ALTER` pattern guarantees it.
3. ✓ `EXEC dbo.sp_SQLFlightRecorder` (no parameters) returns Help output.
4. ✓ `EXEC dbo.sp_SQLFlightRecorder @Mode = 'About'` returns one row with the documented columns.
5. ✓ Every documented `@Mode` value returns either real output or a clear "not yet implemented" message; no exceptions, no silence.
6. ✓ Every documented parameter is declared with the documented default.
7. ✓ Parameter validation rejects out-of-range and unknown values with a clear error result.
8. ✓ The procedure body sets every D-132 session-level safety primitive on its first executable line.
9. ✓ File header contains tool version, build date, supported range, license, repo URL, and design-doc URL.
10. ✓ This `docs/parts/part-01.md` page exists and summarizes the shipped and unshipped scope.
