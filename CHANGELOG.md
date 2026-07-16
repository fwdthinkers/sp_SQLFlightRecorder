# Changelog

All notable changes to sp_SQLFlightRecorder are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Per design decision D-175, entries tag the affected `RuleId`s and `@Mode`s so
runbook owners can grep. Versioning follows the project-specific semver of
D-171 (major = contract break; minor = additive; patch = fixes).

## [0.4.2] - 2026-07-16

Promised-scope rule completion and report-contract stabilization. No new
collectors, tables, modes, or rule IDs. `SchemaVersion` stays `0.4.0` (no DDL;
new `FR_Config` keys and rule-lifecycle values are data).

### Added

- **FR_R0001 ActiveBlockingChain** (`@Mode = Report`): head-of-chain detection
  from `FR_Request.BlockingSessionId` (a blocker not itself blocked), session
  anchored (§7.9, D-074).
- **FR_R0002 LongRunningOpenTransaction**: open transaction persisting across
  snapshots spanning ≥ `LongOpenTxnSeconds` (new tunable, default 60) (§7.9,
  D-048).
- **FR_R0004 FileIoLatencySpike**: per-file window delta latency vs the recent
  baseline; escalates High above `max(4× baseline, 4× FileIoLatencyWarnMs)`
  (new tunable, default 20 ms) (§7.9, D-092).
- **FR_R0005 MemoryGrantsPending**: observed pending grant from `FR_Request`
  (§7.9, D-048).
- **FR_R0006 ServerRestartDuringWindow**: primary detection from the
  `FR_InstanceSnapshot` start-time change, with a **window split** (D-064) that
  re-anchors the delta rules (FR_R0002/FR_R0003/FR_R0004/FR_R0020) at the first
  post-restart snapshot so a counter reset can no longer register as a spike.
- **Graded collection-gap findings** (D-066): a gap > 2× the interval emits a
  Coverage finding scaled Medium/High/Critical (RuleId `FR_R0026`, dedup-exempt).
- **§7.13 folds**: `FR_R0007` folds `FR_R0001`/`FR_R0002`; `FR_R0024` folds
  `FR_R0005` (window-wide); `FR_R0015` folds `FR_R0016` on same query. Headline
  keeps its RuleId; contributors move to `MoreInfo` (D-106).
- `InstallDemoData` now also surfaces FR_R0001/2/4/5.
- `tests/rules/` fixtures runner + demo golden (D-160, D-122).
- New tunables `LongOpenTxnSeconds`, `FileIoLatencyWarnMs` (Configure + Status).

### Changed

- **Deterministic sort (D-068)** (`@Mode = Report`): Findings now order by
  Severity → Confidence → EvidenceType → StartTimeUtc → RuleId; `FindingOrdinal`
  is the 1..N display rank. The 16-column contract (D-067) is unchanged.
- **`@MaxFindings` enforcement + overflow finding (D-087)**: the final result
  set is capped (Critical/Coverage never truncated); one Informational Coverage
  row records the truncation.
- Query-scoped dedup now separates distinct queries (internal `AnchorKey`), so
  `FR_R0016` no longer collapses its top-N to a single row (D-074).

### Fixed

- **FR_R0004/FR_R0020**: divide-by-zero in `Report` on a quiet instance (no I/O
  or one plan-cache row between snapshots); the divisor is now `NULLIF`-guarded.
- **FR_R0021–FR_R0025** did not honor `FR_Config.DisabledRules` (D-099); they
  can now be disabled. `FR_R0026` remains non-disableable (D-098).

## [0.4.1] - 2026-07-15

Hardening/bugfix release. No new features. SchemaVersion stays `0.4.0`
(no DDL changes; rule lifecycle flips are seed data).

### Fixed

- **Purge** (`@Mode = Purge`): the first purge after retention age failed with
  a foreign-key violation because `FR_Snapshot` was deleted before its
  `FR_ErrorLog` / `FR_SchemaActivity` / `FR_PlanCacheSummary` children, and the
  failure path leaked the session applock (blocking later `Collect`/`Purge` on
  that connection). Children now purge strictly before the parent (D-141),
  every table loop is TRY/CATCH-isolated (D-139), the run closes as
  `PartialSuccess` with an `Errors` column when a table fails, and the applock
  release is always reached. `FR_QueryStoreTopN` — which had **no purge loop at
  all** — is now purged, and `FR_QueryText` orphans are cleaned up (D-141).
- **Uninstall** (`@Mode = Uninstall`): `@WhatIf = 1` on a database where
  Install never ran returned *Invalid object name 'dbo.FR_Config'* instead of a
  clean result; `@PreserveRunLog = 1` failed with *"input parameter 'NewName'
  is not allowed to be null"* whenever a run-log table was absent, because
  `sp_rename` executed unconditionally. Both paths are now guarded and safe;
  the in-progress-Collect gate had the same latent binding pattern and was
  restructured too.
- **Collect** (`@Mode = Collect`): with `@IncludeQueryPlans = 1` the
  QueryPlans collector block was duplicated, running twice per snapshot and
  double-inserting captured plans.
- **Report** (`@Mode = Report`): the plan-rule evaluation block was duplicated,
  emitting duplicate dedup-exempt coverage rows; the Markdown header emitted
  only 3 of the 14 locked keys (D-085). The full 14-key header is now emitted
  (`Rule-Pack-Version`, `Report-Run-Id`, `Report-Generated-Utc`,
  `Window-Start-Utc`, `Window-End-Utc`, `Instance-Fingerprint`,
  `Database-Filter`, `Min-Severity`, `Coverage-Warning-Count`,
  `Finding-Count`, `Timeline-Event-Count` added).
- **Help** (`@Mode = Help`): duplicate `@MinSeverity` and `@Debug` parameter
  entries removed; `@IncludeQueryPlans` description corrected (see Changed).
- Build/test infrastructure: the static-analysis linter, CI workflow, and
  local Tier 1 script pointed at the pre-rename `src/` artifact path — the
  linter had been passing while linting nothing. The linter now fails on zero
  targets, CI covers SQL Server 2017/2019/2022/2025 (D-120), handles
  `mssql-tools18` (`-C`) images, and parses the expected version from the file
  header. The missing `FR-LINT-004` fixture was restored and two accidental
  editor-named tracked files were removed.

### Changed

- **`@IncludeQueryPlans` is now an honest reserved/no-op parameter**
  (affects `@Mode = Collect` and `@Mode = Report`; RuleIds
  `FR_R0030_PlanMissingIndex`, `FR_R0031_PlanImplicitConversion`,
  `FR_R0032_PlanSpillToTempDb`, `FR_R0033_PlanWarnings`,
  `FR_R0034_PlanParallelism`). The prior opt-in implementation read
  `sys.dm_exec_query_plan` and shredded plan XML in T-SQL, violating locked
  decisions D-015, D-046, D-082 and D-136; per maintainer ruling the decision
  log is authoritative and the implementation was removed, not legalized.
  `@IncludeQueryPlans = 1` now records one `Skipped` QueryPlans step at
  Collect and one Informational coverage finding at Report. Rules
  FR_R0030–FR_R0034 keep their RuleIds forever (D-089) but are cataloged as
  `Disabled` (D-090) — seeded Disabled on fresh installs and migrated
  Disabled on existing repositories — until a decision-log-approved plan
  analysis design exists. `dbo.FR_QueryPlan` remains for forward schema
  compatibility (D-038) and is never written.
- `sys.dm_exec_sql_text` moved from the forbidden-DMV list to the small-DMV
  allow-list, exactly as the forbidden list's own v0.2+ note anticipated:
  permitted only as a text-by-handle lookup against TOP-capped active
  requests (QueryText collector), with an inline lint annotation stating the
  bound. The plan-XML DMVs remain forbidden without exception.
- Purge result set gains an `Errors` column and may report `PartialSuccess`
  (previously it could only report `Success` or fail entirely).
- Status capability key `PlanAnalysisSupport` now always reports `0`.

### Removed

- Dead duplicate `FR_QueryPlan` CREATE block (mislabeled "Create FR_Rules")
  and a duplicated `@Debug` normalization in the dispatcher.

## [0.4.0] - 2026-06-16

v0.4 milestone (pre-changelog; summarized from git history). Added the
advanced HA collector (`FR_HaState`), opt-in buffer pool collector
(`FR_BufferPool`, D-051 gate), v0.4 rules `FR_R0021_ConfigurationChangeInWindow`,
`FR_R0022_LogReuseWaitElevated`, `FR_R0023_ThreadpoolWaitsObserved`,
`FR_R0024_ResourceSemaphoreWaits`, `FR_R0025_RecentCheckDbOrBackupAge`, full
`FR_R0026_CoverageAndCapabilitySummary`, the baseline engine (D-092/D-103),
`@TimeZone` display support (D-180), and v0.4 timeline events.

## [0.3.0] - earlier

Query Store integration: `FR_QueryStoreTopN`, plan cache summary, opt-in
error log, schema activity collectors; rules FR_R0015–FR_R0020;
`InstallDemoData` mode.

## [0.2.0] - earlier

Historical correlation: tempdb, memory, Agent jobs, backup history,
Always On, deadlock collectors; rules FR_R0007–FR_R0014; `FR_v_*` views.

## [0.1.0] - earlier

Design prototype: procedure shell, Install/Uninstall/Status/Collect/Report/
Configure/Purge modes, seven core collectors, CI scaffolding and the
static-analysis linter.
