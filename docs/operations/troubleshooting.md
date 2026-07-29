# Troubleshooting / Failure-mode catalog

> At 2 AM you want one table that says "this happened → this is what you do."
> This is that table (D-147). It is **representative, not yet exhaustive** —
> more entries are added during v1.0.0-rc. Each entry is: **Symptom → Likely
> cause → What to do**. Nothing here changes data; the tool diagnoses, it does
> not remediate.

Reproduction convention for each entry's "check" is a read-only query against
the `FR_*` repository or a mode result set.

---

### Install fails or is refused

| Symptom | Likely cause | What to do |
|---|---|---|
| `Status=Error, ErrorCode=SystemDatabaseRefused` | You ran `Install` in `master`/`model`/`msdb`/`tempdb` (D-004). | Run it in a user database. |
| `ErrorCode=ReadOnlyDatabaseRefused` | The database is read-only (e.g., an AG secondary). | Install in a read-write database. |
| `ErrorCode=MissingViewServerState` | The caller lacks `VIEW SERVER STATE` (D-118). | Grant `VIEW SERVER STATE`, or install as a login that has it. |
| `ErrorCode=DowngradeBlocked` | The repository schema version is newer than this file (D-039). | Use the matching-or-newer `sp_SQLFlightRecorder.sql`; downgrade is unsupported. |

### Collect is Skipped or PartialSuccess

| Symptom | Likely cause | What to do |
|---|---|---|
| `Status=Skipped, "Another Collect is already running"` | The session applock is held by a concurrent Collect/Purge (D-011). | Expected under overlap; the next scheduled Collect is the retry. Check `FR_RunLog`. |
| `Status=PartialSuccess` | One collector failed but others succeeded (D-009); its `FR_RunLogStep` row is `Status=Error`. | `SELECT StepName, Status, ErrorMessage FROM dbo.FR_RunLogStep WHERE Status='Error'`. Common causes: a version-gated DMV, msdb permissions. Report surfaces this in FR_R0026. |
| A collector shows `Status=Skipped, Reason='Time budget exceeded'` | Cooperative timeout skipped late collectors (D-010). | Expected on a busy box; reduce `MaxRowsPerCollector` or investigate the slow collector. |

### QueryPlans step is always Skipped

| Symptom | Likely cause | What to do |
|---|---|---|
| `@IncludeQueryPlans=1` yields one `QueryPlans` step with `Status=Skipped` and `FR_QueryPlan` stays empty | **By design.** Plan capture and plan-XML analysis are disabled (D-015/046/082/136); the parameter is reserved. | Use Query Store for plan-level evidence. Report emits one Informational coverage finding explaining this. Not a defect. |

### Purge does not delete the rows you expected

| Symptom | Likely cause | What to do |
|---|---|---|
| `RowsDeleted=0` on data you think is old | Data is not past `SnapshotRetentionDays` / `RunLogRetentionDays` yet. | Check the cutoffs in the `Purge @WhatIf=1` output vs your rows' `SnapshotUtc`. |
| Purge returns `Status=PartialSuccess` with an `Errors` column | A table's batch loop hit an error (D-139); other tables still purged. | Read the `Errors` column; re-run Purge (it is resumable batch-by-batch). |
| Large repository, Purge seems to "not finish" | Batched 5,000/loop with a 250 ms pause (D-139); catches up over multiple runs. | Let scheduled Purge run repeatedly; it will converge. No `TRUNCATE`/shrink is used by design. |

### Report shows no findings (or only one Informational row)

| Symptom | Likely cause | What to do |
|---|---|---|
| A single Informational `FR_R0026` "No findings emitted" row | No rule fired for the window — this explicit row prevents silent output (D-077/083). | Widen the window, lower `@MinSeverity`, or collect more snapshots. |
| Critical Informational "Insufficient snapshot coverage" | Fewer than 2 snapshots in the window (D-065). | Run `Collect` at least twice, separated by the interval. |
| A Coverage "Collection gap" finding | A gap > 2× the interval (D-066). | Investigate missed snapshots (Agent job disabled, load, or a restart). |

---

*See also: [modes/report.md](../modes/report.md) for the Findings/Timeline
contracts, and [SECURITY.md](../../SECURITY.md) for reporting a vulnerability.*
