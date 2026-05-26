# Implementation Plan — SQL Server DBA Flight Recorder (v0.1)

**Source of truth:** `docs/design.md`, `docs/decisions.md` (D-001–D-190), `docs/design-lock-review.md`, `docs/open-questions.md`.
**Scope of this plan:** v0.1 only (the Design Prototype phase, §11.2). v0.2 and later are out of scope here and will get their own plans.
**No code in this document.**

---

## Plan principles

These are the rules this plan follows. They are derived from the design, not invented here.

1. **Each part is independently mergeable.** A part either ships clean or doesn't merge. No "this part needs the next part to be useful."
2. **Each part preserves what previous parts promised.** Forward-only schema (D-038). Output contracts semver-stable (D-023). No part may break a prior part's tests.
3. **Each part is small enough that one PR can carry it.** If a part feels like more than ~500 lines of code plus tests plus docs, it gets split.
4. **The first part ships nothing dangerous.** It is intentionally inert: no DMV reads, no tables created, no schedule. This is the trust-building first commit.
5. **Safety gates land before they are needed, not after.** The CI static-analysis suite (D-144) lands in Part 2, before any collector. The cost-regression test (D-143) lands in Part 4, before the second collector. Goldens (D-122) land in Part 6, before the first rule.
6. **Each part has explicit rollback.** Either the part is reversible by `git revert` with no residual state, or the part has a documented backout procedure.
7. **No scope creep.** v0.1 binding exclusions from §11.2.3 are restated in each part's "explicitly excluded" section. If you find yourself wanting to add something, it goes in a later part or a later release.

---

## Part overview

| Part | Goal | Touches user's SQL Server? | Touches user data? |
|---|---|---|---|
| 1 | Proc shell + Help + About modes | Yes (creates one proc) | No |
| 2 | CI scaffolding + static-analysis linter | No (CI only) | No |
| 3 | Repository schema + Install + Uninstall + Status | Yes (creates `FR_*` tables) | No |
| 4 | Capability probe + first collector + Collect mode + applock + run log | Yes (one snapshot per Collect) | No (sys.* and FR_* only) |
| 5 | Remaining 6 v0.1 collectors | Yes (one snapshot per Collect) | No |
| 6 | Report engine + Findings/Timeline contracts + Markdown + skeletal FR_R0026 | Yes (read-only on FR_* and bounded QS) | No |
| 7 | Six v0.1 rules (FR_R0001–FR_R0006) | Yes (read-only) | No |
| 8 | Configure mode + Purge mode + cost-regression test + soak | Yes (writes FR_Config; deletes from FR_*) | No |
| 9 | Documentation completeness + external DBA validation + v0.1 RC tag | Project repo only | No |

Total: 9 parts. Each part is intentionally smaller than "ship the whole release at once."

---

# Part 1 — Procedure shell, parameters, Help and About

**The first commit. Intentionally inert.**

### Goal

Land a single `.sql` file at `src/sp_SQLFlightRecorder.sql` that:
- Creates the procedure `dbo.sp_SQLFlightRecorder`.
- Accepts the full v0.1 parameter surface from §2.2 of the design.
- Implements two modes: `Help` (default) and `About` (returns version, build date, charter pillars).
- Does nothing else. No DMV reads, no table creation, no Agent job, no schedule.

This part exists to prove that the install/uninstall story works, the parameter contract is correct, and the file builds cleanly across the supported test matrix — *before* anything risky is added.

### Objects affected

- New file: `src/sp_SQLFlightRecorder.sql`
- New procedure: `dbo.sp_SQLFlightRecorder` (default install in user database per D-004)
- File header: tool version, build date comment line (D-171 supports `Tool-Version` lookup later)

No tables. No views. No functions. No Agent jobs.

### Features included

- Procedure exists with `@Mode = 'Help'` default (D-003).
- Full v0.1 parameter declarations per §2.2, with documented but unimplemented modes returning a clear "not yet implemented in v0.1.alpha" message rather than silently doing nothing.
- `Help` mode prints usage text, the eight v0.1 modes, the parameter list with defaults and ranges, the charter pillars (§1.7), and the failure-mode catalog stub (D-147). The catalog stub is a placeholder pointing at `docs/operations/troubleshooting.md`; the full catalog text lives in docs.
- `About` mode (or `Version` mode — name to be confirmed at PR review) returns one result set with: `ToolVersion`, `BuildDateUtc`, `SupportedSqlServerRange`, `LicenseUrl`, `RepositoryUrl`, `DesignDocUrl`. One row, fixed columns.
- Session-level safety primitives (D-132) set at the top of the proc: `SET NOCOUNT ON`, `SET XACT_ABORT ON`, `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED`, `SET LOCK_TIMEOUT 5000`, `SET DEADLOCK_PRIORITY LOW`, ANSI settings on. These are set in Part 1 even though they're not strictly needed yet — establishing the pattern early.
- Parameter validation: unknown `@Mode` returns a clear error result set, no exception. Invalid `@MinSeverity`, `@MaxFindings` out of range, etc., are caught and explained.
- `@Debug = 1` is accepted but has nothing to print yet; documented as such.

### Features explicitly excluded

- No table creation. `Install` mode returns "not yet implemented; arriving in Part 3."
- No DMV reads of any kind. Not even `@@VERSION` (capability probe arrives in Part 4).
- No `xp_*`, no `DBCC`, no dynamic SQL.
- No Agent job creation (Part 3 + opt-in per D-005).
- No `Report`, `Collect`, `Configure`, `Purge`, `Uninstall`, `Status`, `CollectAndReport`, `CollectDebug`, `InstallDemoData` logic — all return "not yet implemented" with a pointer to which part will deliver them.
- No `master` install path (Part 3, opt-in per D-004).
- No demo data (Q-041 deferred / D-182 deferred).

### Compatibility risks

- **Low.** The proc uses only universally-available T-SQL constructs: `CREATE PROCEDURE`, parameter declarations, `SET` options, `PRINT`, `SELECT` of literals. Nothing version-conditional.
- One concrete check: `datetime2(3)` literals in `About` output must compile on SQL Server 2012; this is fine since `datetime2` is available from 2008.
- Charset/collation: tool version strings are ASCII; no Unicode-specific concerns.

### Performance/safety risks

- **None.** The proc reads no user data, no DMVs, no system catalogs (beyond what `PRINT` and `SELECT` of literals require).
- Cannot deadlock (no shared resources accessed).
- Cannot block user workload.
- Cannot leak state (no writes anywhere).
- Cost-regression test (D-143) doesn't apply yet; the proc finishes in microseconds.

### Test approach

- **Manual smoke (Tier 1 matrix targets):** install the proc on SQL Server 2019 and 2022 Linux containers; execute with no parameters; verify Help output renders; execute `@Mode = 'About'`; verify one-row result with expected columns.
- **CI checks (added in Part 2; here, manual):**
  - File compiles on all four Tier 1 targets without errors or warnings.
  - Dropping the proc and re-running the file is idempotent.
  - Running with each defined `@Mode` value (other than `Help`/`About`) returns a clean "not yet implemented" result, not an exception.
- **Parameter contract test:** for every parameter listed in §2.2, verify the default value matches the design (e.g., `@MaxFindings = 200`, `@MinSeverity = 'Low'`).
- **Out-of-range tests:** `@MaxFindings = 5` and `@MaxFindings = 5000` both return clear errors. `@Mode = 'WrongMode'` returns a clear error.

### Rollback / removal considerations

- **Trivial rollback:** `DROP PROCEDURE dbo.sp_SQLFlightRecorder`. No tables exist, no jobs exist, no permissions changed. `git revert` of the PR is also clean.
- A user who installs Part 1 and decides not to proceed has nothing to clean up beyond the one procedure.

### Acceptance criteria

1. `src/sp_SQLFlightRecorder.sql` installs cleanly via SSMS, ADS, or `sqlcmd` on SQL Server 2019 Linux and 2022 Linux containers.
2. Re-running the file in the same database is idempotent (no error, replaces the proc).
3. `EXEC dbo.sp_SQLFlightRecorder` (no parameters) returns Help output.
4. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'About'` returns one row with the documented columns.
5. Every documented `@Mode` value (per §2.1) returns either real output or a clear "not yet implemented in this part" message — never an exception, never silence.
6. Every documented parameter is declared with the documented default.
7. Parameter validation rejects out-of-range and unknown values with a clear error result.
8. The procedure body sets all session-level safety primitives from D-132 at its first line.
9. The file header comment block contains the tool version, build date, and a pointer to `docs/design.md`.
10. The PR includes a `docs/parts/part-01.md` page summarizing what shipped and what didn't.

---

# Part 2 — CI scaffolding and static-analysis linter

**Build pipeline, not shipped artifact. Lands before anything risky.**

### Goal

Stand up the CI matrix (Tier 1 minimum: 2019, 2022 Linux containers per §11.2.2) and the static-analysis linter (D-144) so that subsequent parts have automatic guardrails from their first PR. Per D-148, external tooling (Python/PowerShell) is permitted in the build pipeline.

### Objects affected

- New: `.github/workflows/ci-tier1.yml` (Tier 1 matrix: install/uninstall idempotency, smoke test, golden tests when they exist).
- New: `tests/static-analysis/lint.py` (or equivalent; language chosen by implementer per D-148).
- New: `tests/static-analysis/forbidden_dmvs.txt` (D-136 enforced list).
- New: `tests/static-analysis/allow_list_small_dmvs.txt` (D-137 allow-list).
- New: `scripts/run-local-tier1.sh` (per §10.3.1 first-hour walkthrough).
- New: `scripts/run-static-analysis.sh`.
- New: `.github/PULL_REQUEST_TEMPLATE.md` (D-157 checklist).
- New: `.github/ISSUE_TEMPLATE/` directory with 8 templates (D-156) + `config.yml` (blank issues disabled).
- New: `.github/CODEOWNERS` routing all paths to `@core-maintainers` (D-185).

### Features included

- **Tier 1 CI workflow:** matrix of SQL Server 2019 and 2022 Linux containers. Steps: install proc, run smoke test (Part 1 acceptance criteria), uninstall, verify idempotency. SQL Server 2017 and 2025 added in Part 5 and Part 8 respectively — keeping Part 2 small.
- **Static-analysis linter:** parses `src/sp_SQLFlightRecorder.sql` and enforces:
  - No occurrence of forbidden DMVs (D-136).
  - Every external `SELECT` has `TOP (N)` with `ORDER BY` or is in the small-DMV allow-list (D-137).
  - No `CROSS APPLY sys.dm_exec_query_plan` or `sys.dm_exec_text_query_plan` (D-046).
  - No `BEGIN TRAN` outside Install/Purge handlers (D-138).
  - No `xp_cmdshell`, `OPENROWSET`, `OPENDATASOURCE`, `BULK INSERT`.
  - Every `sys.sp_executesql` invocation is parameterized.
  - No `WAITFOR DELAY` longer than 1 second outside the Purge inter-batch pause.
  - No `OPTION (RECOMPILE)` outside an explicit allow-list comment.
- **PR template:** D-157 checklist.
- **Issue templates:** 8 templates per D-156, with blank issues disabled.
- **CODEOWNERS:** all paths → `@core-maintainers` (D-185).
- **`docs/contributing/` minimum set:** `overview.md`, `coding-style.md` (D-153), `safety-checklist.md` (D-176). The full set arrives in Part 9.

### Features explicitly excluded

- No cost-regression test (D-143) — arrives in Part 4 when there's something to regress.
- No 24h soak test (D-145) — arrives in Part 8.
- No golden output tests (D-122) — arrives in Part 6 when there's report output.
- No Tier 2 attestation workflow (D-164) — arrives in v0.2.
- No compatibility matrix badge generator (D-165) — v0.2.
- No SQL Server 2017 or 2025 in CI — added in Part 5 and Part 8 respectively.
- No release workflow (`release.yml`) — arrives in Part 9.
- No `build-single-file.sh` (D-152) — not needed until source splits, which it doesn't in v0.1.

### Compatibility risks

- **Low for the shipped artifact** — Part 2 changes only build-pipeline files, which never run on the user's SQL Server.
- **Medium for CI itself:** Docker container availability for `mcr.microsoft.com/mssql/server` images on the GitHub Actions runner; pinning specific CU tags to avoid drift; the linter must parse the `.sql` file without a full T-SQL parser (regex + AST best-effort per design).

### Performance/safety risks

- None for the user's SQL Server.
- CI runtime risk: the matrix should stay under 10 minutes per PR or contributors will route around it. Two targets × ~3 minutes each = ~6 minutes; acceptable.

### Test approach

- **Self-test of the linter:** craft synthetic `.sql` snippets that *should* fail each rule and verify the linter catches them. These live under `tests/static-analysis/fixtures/`.
- **Smoke test the workflow:** the PR for Part 2 must itself pass the workflow (`src/sp_SQLFlightRecorder.sql` from Part 1 must pass static analysis — it should, trivially, because Part 1 reads no DMVs).
- **Idempotency test:** the CI workflow installs, uninstalls, re-installs the Part 1 proc and verifies no errors.

### Rollback / removal considerations

- Reverting Part 2 disables CI but does not affect the shipped artifact. Contributors lose automatic enforcement; manual review remains.
- The PR template, issue templates, and CODEOWNERS can be left in place even after revert; they cause no harm.

### Acceptance criteria

1. CI workflow runs on every PR and passes on the Part 1 codebase.
2. Static-analysis linter rejects each documented forbidden pattern in self-test fixtures.
3. Static-analysis linter passes on `src/sp_SQLFlightRecorder.sql` (Part 1 has nothing risky).
4. PR template appears on new PRs.
5. Blank issues are disabled; only the 8 templates can open issues.
6. CODEOWNERS routes all paths to `@core-maintainers`.
7. `scripts/run-local-tier1.sh` and `scripts/run-static-analysis.sh` work on a clean clone with Docker + Python (per D-187, these are recommended-but-not-required for contributors).
8. `docs/contributing/safety-checklist.md` exists and matches §10.12 verbatim.

---

# Part 3 — Repository schema, Install, Uninstall, Status

**The tool now has somewhere to put data. Still doesn't collect any.**

### Goal

Implement the v0.1 schema (12 tables per §4.3 v0.1 core list), an idempotent `Install` mode, a clean `Uninstall` mode with `@PreserveRunLog` opt-in (D-183), and a `Status` mode that reports installation state, schema version, and (empty) repository contents.

### Objects affected

- New tables (all in default user database; `dbo` schema; D-022): `FR_Config`, `FR_RunLog`, `FR_RunLogStep`, `FR_Snapshot`, `FR_InstanceSnapshot`, `FR_Configuration`, `FR_Request`, `FR_Wait`, `FR_FileStat`, `FR_PerfCounter`, `FR_QueryText`, `FR_Rules`.
- All tables: `BIGINT IDENTITY` PK (D-030), `SnapshotUtc`-leading clustered index where applicable (D-031), declared FKs no cascade (D-032), `PAGE` compression with edition fallback (D-034), no `NVARCHAR(MAX)` on hot rows (D-040), sentinel values `DatabaseId=0`/`SessionId=0` where appropriate (D-041).
- `FR_Rules` seed data: 6 rule metadata rows for FR_R0001–FR_R0006 (the logic itself arrives in Part 7; the catalog rows ship now so `Status` can list them).
- `FR_Config` seed data: default snapshot interval, retention days, `MaxRowsPerCollector = 50` (D-181), wait-stats ignore list (D-033, D-057), `DisabledRules = ''` (D-099), `CriticalWaitTypes` key defined but not honored (D-105).
- Procedure body: `Install`, `Uninstall`, `Status` modes implemented.

### Features included

- **Install mode:**
  - Idempotent (re-running is safe; existing tables are not dropped).
  - Refuses on read-only databases (e.g., AG secondary).
  - Refuses if `VIEW SERVER STATE` is missing (D-118).
  - Default install in user database (D-004); `@InstallTarget = 'Master'` is opt-in.
  - Forward-only schema migration logic (D-038): reads current schema version from `FR_Config`, applies additions only.
  - Records install metadata in `FR_RunLog` as `Mode = 'Install'`.
  - No Agent job creation in Part 3 (Agent job is opt-in per D-005; it lands later as a separate mode parameter, possibly Part 8 or v0.2 — to be confirmed during this PR's review).
- **Uninstall mode:**
  - Default: drops all `FR_*` objects (D-183).
  - `@PreserveRunLog = 1` opt-in: renames `FR_RunLog` and `FR_RunLogStep` to `FR_RunLog_Archive_<timestamp>` and `FR_RunLogStep_Archive_<timestamp>`.
  - Refuses if a Collect or Purge is in flight (checks the applock — but the applock infrastructure arrives in Part 4; Part 3 Uninstall therefore performs a simpler "is there a recent `Mode = 'Collect'` row with no end timestamp in `FR_RunLog`?" check).
  - `@WhatIf = 1` prints what would be dropped without dropping.
- **Status mode:**
  - Returns multiple result sets (Status is the only mode that returns >2; this is documented and is not subject to the D-006 two-result-set rule which applies only to `Report`).
  - Result sets: installation summary; configuration (`FR_Config` contents); rule catalog (`FR_Rules` contents); repository size summary; run-log summary (empty in Part 3); capability snapshot (empty in Part 3 — arrives in Part 4); missing-permission report (per D-119).
- **Parent-after-children invariant (D-135):** documented in code comments at table-design level; enforced operationally starting in Part 4 when the first collector runs.

### Features explicitly excluded

- No capability probe (Part 4).
- No collectors (Part 4 and Part 5).
- No Report engine (Part 6).
- No rules (Part 7); only the `FR_Rules` *metadata rows* for FR_R0001–FR_R0006.
- No Purge (Part 8). Manual `DELETE` works on these tables in Part 3 if needed.
- No Configure mode (Part 8). `FR_Config` is populated at install with defaults; users cannot modify it via the proc yet.
- No Agent job creation (per the to-be-confirmed scheduling note above).
- No tables for v0.2+ collectors: `FR_Tempdb`, `FR_Memory`, `FR_AgentJob`, `FR_BackupHistory`, `FR_AlwaysOnState`, `FR_Deadlock`, etc.
- No `FR_v_*` views (D-184 deferred to v0.2).

### Compatibility risks

- **Low to Medium.** All table DDL uses constructs available in SQL Server 2012:
  - `BIGINT IDENTITY` — fine.
  - `datetime2(3)` — fine.
  - `PAGE` compression — Enterprise-only on 2012/2014; Standard-and-higher from 2016 SP1+. Edition-fallback logic (D-034) handles this.
  - `SHA2_256` (used in `FR_QueryText` dedup hash per D-027) — available 2008+, fine.
  - Filtered indexes — available 2008+, fine.
- One concrete check: the `FR_Config` value column type. `NVARCHAR(4000)` is safe; `NVARCHAR(MAX)` per D-040 is reserved for non-hot rows, and `FR_Config` is queried at every Collect, so the bounded type is correct.

### Performance/safety risks

- **Low.** `Install` writes only to the new `FR_*` tables it just created; no contention possible. `Uninstall` drops objects it owns. `Status` reads only `FR_*` and a small set of allow-listed system catalogs (`sys.objects`, `sys.indexes`, `sys.dm_db_partition_stats` for size, `sys.fn_my_permissions` for the permission report — all in the small-DMV allow-list to be added in Part 2's `allow_list_small_dmvs.txt`).
- **Risk:** if a user creates conflicting objects (an unrelated `FR_*` table outside the tool), `Install` could overwrite or fail. Mitigation: `Install` checks for our specific table shape, not just the name, before treating it as ours; otherwise refuses with a clear error.

### Test approach

- **Install idempotency:** install twice, verify no errors and no duplicate rows.
- **Install from clean state:** drop all `FR_*` objects, install, verify all 12 tables and seed data exist.
- **Install with insufficient permissions:** revoke `VIEW SERVER STATE`, attempt install, verify clean refusal with informative error.
- **Uninstall round-trip:** install, then uninstall, verify zero `FR_*` objects remain.
- **Uninstall with `@PreserveRunLog = 1`:** verify the archive-rename happened and no original `FR_RunLog*` tables remain.
- **Uninstall `@WhatIf`:** verify nothing is dropped.
- **Status output shape:** verify the documented columns and result-set count, even when most are empty.
- **Forward migration scenario:** install Part 3 schema, manually bump `SchemaVersion` in `FR_Config` to a fake future value, attempt install, verify clean refusal per D-039.
- **PAGE compression fallback:** install on a SQL Server Express edition (CI-tested in a 2019 Express container if available; otherwise Tier 2 attestation).

### Rollback / removal considerations

- `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Uninstall'` is the official rollback path.
- `git revert` of the Part 3 PR drops Install/Uninstall/Status logic from the proc but leaves any existing `FR_*` tables in place; the user must run the old Uninstall (or manually drop) before re-installing a Part 3-less version. This is acceptable because the Part 3 PR will be very early in the v0.1 lifecycle.
- Documented in the PR: "If you installed v0.1.alpha and want to revert to v0.1.dev (Part 1), run Uninstall first."

### Acceptance criteria

1. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Install'` creates all 12 tables on Tier 1 targets.
2. Re-running Install is idempotent.
3. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Uninstall'` removes all `FR_*` objects.
4. `@PreserveRunLog = 1` archives the run-log tables with timestamped rename.
5. `@WhatIf = 1` on Uninstall lists target objects without dropping.
6. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Status'` returns the documented result sets, even when empty.
7. `FR_Rules` contains seed rows for FR_R0001–FR_R0006 with status `Active` per D-090.
8. `FR_Config` contains all v0.1 default keys including `MaxRowsPerCollector = 50` (D-181) and the wait-stats ignore list (D-057).
9. Static-analysis linter (Part 2) passes on the Part 3 codebase.
10. CI Tier 1 matrix passes for Part 3.
11. `docs/modes/install.md`, `docs/modes/uninstall.md`, and `docs/modes/status.md` exist and match the implemented behavior.

---

# Part 4 — Capability probe, applock, run log, first collector, Collect mode

**The tool starts touching DMVs. This is the highest-risk part of v0.1.**

### Goal

Implement the capability probe (D-008, D-111, D-127), the applock concurrency gate (D-011, D-061), full run-log instrumentation (D-009, D-054), and exactly one collector: instance/server state (§5.4.1, the simplest and safest of the seven v0.1 collectors). The cost-regression test (D-143) lands in this part so the second collector in Part 5 inherits a working benchmark.

### Objects affected

- Procedure body: `Collect` mode implemented (single collector); `CollectDebug` (D-128) implemented.
- `FR_Snapshot`, `FR_InstanceSnapshot`, `FR_RunLog`, `FR_RunLogStep` rows written per snapshot.
- `FR_RunLog.CapabilitySnapshot` populated with the closed key set (D-127).
- New: `tests/integration/cost-regression/` workload fixture and harness.
- New: `tests/unit/capability-flag-tests/` simulating each capability flag combination (D-123).

### Features included

- **Capability probe (D-008):** runs once per invocation; populates a session temp table `#fr_capabilities`. Probes for: engine major version, edition, platform (Windows/Linux), Azure SQL DB vs MI vs on-prem, Query Store availability (DB-scoped check deferred to v0.3 per §11.4), Always On availability, in-memory OLTP availability, and the documented v1.0 key set per D-127. Keys are a closed, documented set; the list is rendered in `Status` (this exposure shipped in Part 3 as an empty placeholder; Part 4 fills it).
- **Applock (D-011):** session-scoped `sp_getapplock` on resource `'SQLFlightRecorder/Collect'` with 1-second timeout. Acquisition failure: clean exit with `Status = 'Skipped'`, `Reason = 'Another collection is already running'` (D-061).
- **Run log (D-009, D-054):** every Collect opens an `FR_RunLog` row, writes `FR_RunLogStep` rows for each collector, and closes the run row at the end (success / partial success / error). Skipped collectors emit log rows.
- **Cooperative timeout (D-010):** dispatcher checks remaining budget between collectors; in Part 4 there's only one collector, so this is structural prep.
- **Parent-after-children invariant (D-135):** the `FR_Snapshot` row is inserted *after* the `FR_InstanceSnapshot` child row.
- **`@Debug = 1` behavior (D-114, D-128):** `Mode = 'CollectDebug'` row written to `FR_RunLog`; no collector rows persisted; dynamic SQL (if any) printed.
- **No-retry policy (D-150):** if the collector fails, the next scheduled Collect is the retry.
- **First collector — instance/server state (§5.4.1):** reads `sys.dm_os_sys_info`, `sys.dm_os_host_info`, `SERVERPROPERTY` outputs, uptime, edition, version. Bounded by construction (small-DMV allow-list).
- **Cost-regression test (D-143):** synthetic OLTP workload (e.g., `ostress` or equivalent) runs in CI; harness measures throughput baseline, runs `Collect` every minute for 5 minutes, asserts throughput drop ≤2% and no Collect >10 s.

### Features explicitly excluded

- All other collectors (Part 5: configuration, requests/blocking, waits, file stats, perf counters, run log self-instrumentation).
- Report engine (Part 6).
- Rules (Part 7).
- Configure mode and Purge mode (Part 8).
- Query Store probe details beyond instance-level capability (v0.3 per §11.4).
- Per-DB capability probe (v0.3).
- Buffer pool, error log, schema/stats, HA-other collectors (v0.3, v0.4).

### Compatibility risks

- **Medium.** This is the first part where dynamic SQL discipline (D-112) matters. The capability probe must execute on SQL Server 2012, where some columns and views differ. Specific care:
  - `sys.dm_os_host_info` doesn't exist on 2012/2014; capability probe must detect via `OBJECT_ID('sys.dm_os_host_info')` and fall back to `xp_msver` (cautiously) or simply leave the `Platform` flag as `Unknown`.
  - `SERVERPROPERTY('IsXTPSupported')` differs across versions.
  - `sys.dm_os_sys_info` columns vary (e.g., `socket_count` added in 2012 SP3+).
- **Mitigation:** every probe block is wrapped in `TRY/CATCH`; failed probes default to a safe-off value. The simulated-capability unit tests (D-123) exercise the matrix.

### Performance/safety risks

- **Low to Medium.** Instance/server-state collector reads only small system catalogs; cost should be sub-100 ms.
- **Applock risk:** session-scoped applock must be released on exit, including error paths. `XACT_ABORT ON` plus explicit release in a `TRY ... CATCH ... FINALLY`-equivalent pattern. Tested by simulating exceptions mid-run.
- **Parent-after-children risk:** must be tested explicitly. A test should start a Collect, kill it between `FR_InstanceSnapshot` insert and `FR_Snapshot` insert, then verify no orphaned `FR_InstanceSnapshot` rows show up in a future Report (Report doesn't exist yet, so this test queries the raw tables and asserts the invariant).
- **Cost-regression baseline:** first time this test runs, it establishes the baseline. Subsequent parts inherit the 2% drift budget.

### Test approach

- **Capability-flag unit tests (D-123):** simulate each flag combination by overriding `#fr_capabilities` and verifying dispatcher behavior.
- **Applock contention test:** start two concurrent Collects; verify exactly one succeeds and the other is `Skipped` with the documented reason.
- **Run-log completeness:** every Collect produces exactly one `FR_RunLog` row with a matching `FR_RunLogStep` row per collector (in Part 4, just one).
- **Parent-after-children:** verify ordering of inserts.
- **Cost-regression test:** PR fails if throughput drops >2% or any Collect >10 s (D-143).
- **`@Debug = 1` test:** verify `FR_RunLog` has the `CollectDebug` row and no `FR_RunLogStep` or `FR_InstanceSnapshot` rows for that run.
- **No-retry verification:** force a collector failure; verify no in-run retry and the next Collect captures normally.
- **Cross-version capability probe:** unit tests with simulated 2012/2014/2016/2017/2019/2022/2025 capability snapshots; verify the key set matches D-127.

### Rollback / removal considerations

- Reverting Part 4 means Collect goes back to "not yet implemented." Any `FR_Snapshot`/`FR_InstanceSnapshot`/`FR_RunLog`/`FR_RunLogStep` rows already written remain in the repository — they are not deleted by revert. Users can run Uninstall + Install for a clean state, or leave them; they are harmless.
- The applock infrastructure is in the proc body; reverting it removes concurrency protection from Uninstall (which started checking it in Part 3 via the simpler "is there an open Mode=Collect row" mechanism). Part 4's revert restores the simpler check.

### Acceptance criteria

1. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Collect'` writes exactly one `FR_Snapshot` row, one `FR_InstanceSnapshot` row, one `FR_RunLog` row, and one `FR_RunLogStep` row.
2. The applock prevents concurrent Collects; the second concurrent call exits cleanly with `Status = 'Skipped'`.
3. The capability snapshot persisted in `FR_RunLog.CapabilitySnapshot` contains every documented v1.0 key (D-127) with appropriate values.
4. `@Debug = 1` writes a `CollectDebug` run-log row, no collector rows, no instance snapshot row.
5. A simulated collector failure (test-only hook) results in one `FR_RunLogStep` row with `Status = 'Error'` and the run is marked `PartialSuccess`; no in-run retry.
6. Parent-after-children invariant verified: every `FR_InstanceSnapshot` row's `SnapshotId` exists in `FR_Snapshot`.
7. Cost-regression test passes: <2% throughput drop, no Collect >10 s on the Tier 1 OLTP fixture.
8. Cross-version capability-flag unit tests pass for simulated 2012/2014/2016/2017/2019/2022/2025.
9. CI Tier 1 matrix passes.
10. `docs/modes/collect.md` updated to reflect the v0.1 Part 4 state.

---

# Part 5 — Remaining six v0.1 collectors

**Fills out the §11.2.2 v0.1 collector list.**

### Goal

Implement the remaining six v0.1 collectors per §11.2.2 v0.1 included list: configuration, requests/blocking, waits, file stats, performance counters, and run-log self-instrumentation. Add SQL Server 2017 Linux to the Tier 1 CI matrix.

### Objects affected

- Procedure body: dispatcher loop calls all seven v0.1 collectors with cooperative-timeout checks (D-010) between each.
- Rows written to `FR_Configuration`, `FR_Request`, `FR_Wait`, `FR_FileStat`, `FR_PerfCounter` per snapshot.
- `FR_RunLogStep` carries one row per collector per Collect.
- `.github/workflows/ci-tier1.yml`: add SQL Server 2017 Linux container.

### Features included

- **Configuration collector (§5.4.2):** `sys.configurations`, trace flags via `DBCC TRACESTATUS(-1)` (read-only allow-listed DBCC), DB-scoped configurations where available (capability-gated).
- **Requests/blocking collector (§5.4.3):** active requests from `sys.dm_exec_requests` joined to `sys.dm_exec_sessions`, top 50 by ordering (CPU, wait time, blocked count) per D-181, blocking chain reconstruction. Includes tempdb/memory data per D-048 (in v0.1 these live in `FR_Request`, not a dedicated table).
- **Waits collector (§5.4.4):** `sys.dm_os_wait_stats` with ignore-list filter applied at collect time (D-033, D-057). Cumulative values stored raw per D-007.
- **File stats collector (§5.4.5):** `sys.dm_io_virtual_file_stats(NULL, NULL)` for all files up to 5,000. Cumulative.
- **Perf counters collector (§5.4.6):** allow-listed counters (~60) from `sys.dm_os_performance_counters` with Linux prefix normalization (D-117).
- **Run-log self-instrumentation collector (§5.4.9):** writes summary of the current run; this is the collector that *records* the other collectors' completion. Always runs last.
- **Cooperative timeout enforcement:** between each collector, dispatcher checks remaining wall-clock budget; collectors not yet started are skipped with `Status = 'Skipped', Reason = 'Time budget exceeded'` (D-010, D-054).
- **Tier 1 matrix expansion:** SQL Server 2017 Linux container added.

### Features explicitly excluded

- All v0.2+ collectors (Query Store, plan cache, Agent jobs, backups, deadlocks, AG state, tempdb dedicated, memory dedicated, error log, schema/stats, buffer pool, HA-other).
- Report engine (Part 6).
- Rules (Part 7).
- The dedicated `FR_Tempdb` and `FR_Memory` tables (v0.2).

### Compatibility risks

- **Medium.** Each collector has version-specific concerns:
  - `sys.dm_exec_session_wait_stats` exists from 2016+; the requests collector must not depend on it in v0.1.
  - `sys.dm_db_session_space_usage` is universal but tempdb-only meaningful.
  - Trace flag column names differ slightly across versions.
  - Linux perf-counter prefix normalization (D-117) must be unit-tested.
- **Mitigation:** every cross-version difference is gated on a capability flag from Part 4's probe.

### Performance/safety risks

- **Medium.** Seven collectors per Collect; the 30-second hard cap (D-043) is now meaningfully exercised. The cost-regression test (D-143) from Part 4 enforces ≤10 s on synthetic workload and ≤2% throughput drop.
- **Locking risk:** `dm_os_wait_stats` and `dm_io_virtual_file_stats` are wide DMVs; on busy boxes they can take longer than expected. `LOCK_TIMEOUT 5000` (D-133) catches pathological cases.
- **Storage risk:** `FR_Wait` is the largest table; the ignore list (D-033) is the primary bound. Verify against the wait list seeded in Part 3.

### Test approach

- **Collector smoke tests:** for each collector, verify it writes the expected row count on a clean instance with no workload.
- **Collector failure isolation:** simulate failure of one collector (e.g., requests/blocking); verify other collectors still run, the run is `PartialSuccess`, and `FR_RunLogStep` records the failure.
- **Cooperative timeout test:** artificially constrain wall-clock budget; verify late collectors are `Skipped`.
- **Cost regression on full collector set:** Part 4's harness re-runs against all seven collectors; the 2% drop and 10 s caps must still hold.
- **Linux perf-counter normalization:** unit test with simulated Windows and Linux perf-counter rows.
- **Wait-stats ignore list:** verify the filter is applied (count of rows in `FR_Wait` matches expected after filter).
- **Cross-version capability gates:** simulated 2012/2014/2016 capability snapshots must produce sensible collector behavior (e.g., DB-scoped configs absent on 2012).

### Rollback / removal considerations

- Reverting Part 5 leaves only the instance/server-state collector from Part 4. Any rows already written to `FR_Configuration`/`FR_Request`/`FR_Wait`/`FR_FileStat`/`FR_PerfCounter` remain in the repository; they are harmless without Report. Uninstall + Install gives a clean state if desired.

### Acceptance criteria

1. All seven v0.1 collectors run successfully against a Tier 1 OLTP fixture and write expected rows.
2. Each collector has its own `FR_RunLogStep` row.
3. A simulated collector failure leaves other collectors running; run finishes as `PartialSuccess`.
4. Cooperative timeout correctly skips late collectors when budget is exhausted.
5. Cost-regression test still passes with all seven collectors active (<2% throughput drop, no Collect >10 s).
6. Wait-stats ignore list is honored.
7. Linux perf-counter prefix normalization works on the SQL Server 2017 Linux Tier 1 target.
8. Tier 1 CI matrix passes including the newly-added 2017 Linux target.
9. Static-analysis linter passes.
10. `docs/modes/collect.md` updated to list all seven collectors.

---

# Part 6 — Report engine, output contracts, Markdown, skeletal FR_R0026

**The user finally sees something useful. The output contract gets locked.**

### Goal

Implement the `Report` mode with the full v1.0 output contracts shipped in v0.1: 16-column Findings, 12-column Timeline, 14-key Markdown header. Ship the report pipeline (windowing, delta computation, dedup, filter, rank, emit per D-062) and the skeletal version of FR_R0026 (Coverage Summary). No other rules yet — that's Part 7. The point of shipping the full output contracts before any rule logic exists is precisely to lock those contracts before runbooks form (per §11.2.2 / §11.6.4 risk).

### Objects affected

- Procedure body: `Report` mode implemented end-to-end.
- New session-scoped temp tables used at report time: `#fr_window_snapshots`, `#fr_baseline_*`, `#fr_findings`, `#fr_timeline`.
- New: golden output test fixtures in `tests/golden/<version>/`.
- New: `tests/fixtures/empty.bak`, `tests/fixtures/blocking-storm.bak` (the second is built from Part 5 collector data captured during a synthetic blocking scenario).

### Features included

- **Report pipeline (D-062):** deterministic; window → delta → rules → dedup → filter → rank → emit.
- **Window handling (D-063):** internally expanded by one snapshot for `LAG()`; user-visible window unchanged.
- **Restart detection (D-064):** splits window at restart boundary; emits a Critical informational finding via the Coverage rule.
- **Findings result set (D-067, D-068):** full 16-column contract; documented sort order; Severity-per-rule constant (D-069); post-evaluation filters (D-070); empty-Findings synthetic Informational (D-077, D-083); Evidence cap with attribution (D-084).
- **Timeline result set (D-071, D-072, D-073):** full 12-column contract; chronological; closed `EventType`/`Category` sets; paired-event durations.
- **Output formats (D-079):** `Default` / `FindingsOnly` / `TimelineOnly` / `Markdown`.
- **Markdown output (D-085):** single `nvarchar(max)` column named `Report`; 14-key header block; stable markers (`# SQL Server Flight Recorder Report`, `## Findings`, `## Timeline`).
- **Performance contract (D-080):** ≤3 s median, hard cap 60 s; over-cap returns partial results with one Informational finding.
- **Baseline materialization (D-103):** shared baselines computed once into session temp tables per Report run.
- **Drill-down emission (D-086):** infrastructure present, but only fires when `QueryId IS NOT NULL`, which v0.1 rules never set (no Query Store rule until v0.3). The code path exists; v0.1 just never executes the QS-specific branch.
- **Skeletal FR_R0026 (Coverage Summary):** always emits; cannot be disabled (D-098); reports snapshot count, gap detection (D-066, D-104), suppressed collectors. The *full* FR_R0026 lands in v0.4 per §11.5; v0.1 ships the simpler form covering only what v0.1 collectors produce.
- **`@MaxFindings` enforcement (D-087):** default 200, clamped 10–2000; overflow truncated with one Informational row.
- **No live DMV reads from Report (D-081):** Report reads only `FR_*` tables.
- **`@IncludeQueryPlans = 1` infrastructure (D-082):** parameter accepted, no-op in v0.1 (no QS data exists yet).
- **Coverage gates (D-065, D-066):** <2 snapshots → Critical informational, report proceeds.

### Features explicitly excluded

- All six v0.1 *recommendation* rules (FR_R0001–FR_R0006) — Part 7.
- Any v0.2+ rules.
- Cross-category dedup (D-074): forbidden by design; v0.1 rules don't need intra-category dedup either because there's only one rule (FR_R0026) and it's exempt from dedup (D-075).
- Query Store integration of any kind (v0.3).
- Plan XML surfacing (parameter exists per D-082 but is a no-op in v0.1).

### Compatibility risks

- **Medium.** `LAG()` requires SQL Server 2012+; we're at the floor. `STRING_AGG()` would be convenient but isn't available before 2017; Markdown assembly must use FOR XML PATH or similar legacy patterns.
- **Mitigation:** all version-conditional T-SQL goes through `sp_executesql` per D-112; no nested dynamic SQL (D-113); no dynamic SQL in rules (D-113), which means FR_R0026 must be expressible without dynamic SQL — true since it just counts rows in `FR_RunLogStep` and `FR_Snapshot`.

### Performance/safety risks

- **Low to Medium.** Report reads only `FR_*` tables; no DMVs except bounded QS which v0.1 doesn't use.
- **Storage temp pressure:** baseline materialization (D-103) writes to session-scoped temp tables. Bounded by the row counts of `FR_Wait`, `FR_FileStat`, `FR_PerfCounter` over the report window; sized for typical 1-hour windows at 1-minute cadence (= 60 snapshots × ~500 wait types after filter = ~30k rows). Acceptable.
- **Determinism risk:** the sort order (D-068) must be exact. Verified by golden tests.

### Test approach

- **Golden output tests (D-122):** for the empty and blocking-storm fixtures, capture the byte-exact Markdown output on each Tier 1 target; any future change that alters output must update goldens explicitly. This is the strongest guarantee of determinism.
- **Empty window test:** Report against a window with zero snapshots → synthetic Critical informational finding (D-065).
- **Two-snapshot edge:** Report against a window with exactly 2 snapshots; verify deltas compute.
- **Restart boundary test:** synthesize a server restart between two snapshots; verify window split and informational finding.
- **`@MaxFindings` overflow:** force FR_R0026 to produce many rows (synthetic skipped-collector storm); verify truncation Informational appears.
- **Sort-order test:** synthesize findings of various severities/confidences; verify documented sort order.
- **Markdown header test:** verify all 14 header keys are present and in stable order.
- **Output format variants:** `Default`/`FindingsOnly`/`TimelineOnly`/`Markdown` each return correct shape.
- **Performance contract test:** Report against a 24-hour window of synthetic data; verify ≤3 s median, ≤60 s hard cap.

### Rollback / removal considerations

- Reverting Part 6 returns the proc to a state where `Collect` works but `Report` doesn't. Repository contents are unaffected.
- Goldens become orphans if Part 6 is reverted; they can be left in place or removed.

### Acceptance criteria

1. `EXEC dbo.sp_SQLFlightRecorder @Mode = 'Report', @StartTime = ..., @EndTime = ...` returns exactly two result sets in `Default` format.
2. Findings is 16 columns in documented sort order; Timeline is 12 columns chronological.
3. Markdown format returns one `nvarchar(max)` column named `Report` with the 14-key header block.
4. Skeletal FR_R0026 always emits at least one row.
5. <2-snapshot window produces a Critical informational finding and the report proceeds.
6. Server-restart boundary splits the window.
7. `@MaxFindings = 10` truncates with an Informational overflow row.
8. Golden tests pass byte-exact on all Tier 1 targets for the empty and blocking-storm fixtures.
9. Report runtime ≤3 s median, ≤60 s hard cap on the 24-hour synthetic fixture.
10. Static analysis passes; CI Tier 1 matrix passes.
11. `docs/modes/report.md` updated; per-rule doc for FR_R0026 added at `docs/rules/FR_R0026_CoverageAndCapabilitySummary.md`.

---

# Part 7 — Six v0.1 recommendation rules (FR_R0001–FR_R0006)

**The tool starts saying useful things.**

### Goal

Implement the six v0.1 rules per §7.9: FR_R0001 (ActiveBlockingChain), FR_R0002 (LongRunningOpenTransaction), FR_R0003 (TopWaitTypeSpike), FR_R0004 (FileIoLatencySpike), FR_R0005 (MemoryGrantsPending), FR_R0006 (ServerRestartDuringWindow). Each ships with full documentation per §10.6 (D-160, D-161): positive test, negative test, golden update, wording self-review.

### Objects affected

- Procedure body: rule pack (six rules added to the Report engine's rule loop).
- `FR_Rules` seed data already exists from Part 3; Part 7 verifies severity/confidence/evidence-type values match §7.9 exactly.
- New: six pages under `docs/rules/`, one per rule, following the template (D-161).
- New: positive and negative test fixtures per rule under `tests/fixtures/`.
- Updates: golden output files for affected fixtures.

### Features included

- **Six rules** with severity / confidence / evidence type per §7.9 table.
- **Each rule** wrapped in its own `TRY/CATCH` (D-009 pattern extended to rules).
- **Each rule** reads only from `FR_*` tables (D-014, D-081).
- **Each rule** uses the shared baselines from D-103, not its own.
- **Each rule** is capability-gated where applicable (e.g., FR_R0005 MemoryGrantsPending requires the requests collector to have data).
- **Rule execution order:** fixed by `RuleId` ascending (D-100); no inter-rule deps.
- **Wording rules (D-076, D-189):** every Recommendation template reviewed against §6.7 wording rules by two maintainers before merge.
- **Dedup:** FR_R0001 and FR_R0002 share the "Blocking" category, but their anchors differ enough that intra-category dedup (D-074) doesn't fold them; verify by test. FR_R0007 (which folds them) doesn't exist until v0.2.
- **FR_R0026 enhancement:** Coverage Summary now lists which of the six rules fired and which were suppressed (D-101).

### Features explicitly excluded

- All v0.2+ rules (FR_R0007–FR_R0026 except the skeletal FR_R0026 from Part 6).
- Custom-rule plugin model (D-102, out of v1).
- Rule disabling via `FR_Config.DisabledRules` — wait, this is *included*: D-099 says disabling is via config, and Part 8 ships Configure mode. In Part 7, disabling must work via direct UPDATE of `FR_Config` (manual until Part 8). The rule code reads `FR_Config.DisabledRules` regardless of how it got there.

### Compatibility risks

- **Low to Medium.** All six rules read from v0.1 tables that exist on all Tier 1 targets. Specific concerns:
  - FR_R0006 (ServerRestartDuringWindow) depends on the restart detection from Part 6, which uses `sys.dm_os_sys_info.sqlserver_start_time` captured by the instance/server-state collector. Verify on 2012.
  - FR_R0005 (MemoryGrantsPending) depends on memory data captured *within* `FR_Request` per D-048; verify the requests collector captures enough for the rule.

### Performance/safety risks

- **Low.** All rules are set-based, read-only, on already-collected data. Shared baselines (D-103) bound rule cost.
- **Risk:** if all six rules together exceed the Report 3 s median (D-080), the budget cap kicks in. Verified by Part 6's perf test extended to include rule execution.

### Test approach

- **Positive test per rule:** fixture that should make the rule fire; verify Finding row with expected severity/confidence/evidence type.
- **Negative test per rule:** fixture that looks similar but should NOT fire; verify no Finding.
- **Sort-order test:** with all six rules potentially firing, verify D-068 sort order.
- **Disabling test:** set `FR_Config.DisabledRules = 'FR_R0001'`; verify FR_R0001 doesn't fire AND appears in FR_R0026's Suppressed list (D-101).
- **Wording review:** each Recommendation template reviewed against §6.7 by two maintainers (D-189 commitment).
- **Golden regeneration:** every fixture's golden output updated to reflect the new rules.
- **Perf contract still holds:** Report ≤3 s median, ≤60 s hard cap, even with all six rules.

### Rollback / removal considerations

- Reverting Part 7 removes rule logic; FR_R0026 still emits.
- `FR_Rules` seed data from Part 3 remains; orphan rule metadata is harmless and Report's enumeration of `FR_Rules` continues to list them as "Active" (the rule loop just won't execute logic that no longer exists). This is a minor inconsistency for the revert window; documented in the Part 7 PR description.

### Acceptance criteria

1. Each of the six rules fires correctly on its positive fixture with the documented severity/confidence/evidence type.
2. Each rule does not fire on its negative fixture.
3. Sort order on multi-rule scenarios matches D-068.
4. Disabling FR_R0001 via `FR_Config.DisabledRules` works AND surfaces in FR_R0026.
5. Six rule docs exist under `docs/rules/` following the D-161 template, including Severity rationale, Confidence rationale, EvidenceType rationale, False-positive risks.
6. Wording review (D-189) attested by two maintainers in the PR description.
7. All goldens regenerated and pass byte-exact on Tier 1 matrix.
8. Report perf contract holds.
9. CI Tier 1 matrix passes.
10. Static analysis passes (rules contain no dynamic SQL per D-113).

---

# Part 8 — Configure mode, Purge mode, cost-regression at full collector set, soak test

**The operational modes the user needs for day-to-day life.**

### Goal

Implement `Configure` mode (read/write `FR_Config`) and `Purge` mode (batched retention cleanup per D-139, D-140, D-141). Optional Agent job creation lands here if not earlier (this PR confirms it). Add the 24-hour soak test (D-145) to out-of-band CI. Add SQL Server 2025 Linux to Tier 1 CI matrix.

### Objects affected

- Procedure body: `Configure`, `Purge` modes implemented.
- Optional: Agent job creation logic guarded by an `@CreateAgentJob` parameter on `Install` (D-005).
- `FR_RunLog` rows written for Configure invocations that modify state.
- New: `.github/workflows/ci-soak.yml` (nightly out-of-band).
- `.github/workflows/ci-tier1.yml`: SQL Server 2025 added (if 2025 has GA'd; otherwise queued for the GA point per D-124).

### Features included

- **Configure mode:**
  - Read mode: returns current `FR_Config` contents (subset of `Status`).
  - Write mode: `@ConfigKey`, `@ConfigValue` parameters; validates against known key set; refuses unknown keys.
  - Multi-value config follows the semicolon-delimited convention (D-026).
  - `xp_readerrorlog` permission verification (D-060) — but v0.1 doesn't ship the error-log collector; the config key for enabling it can be set, but the collector isn't there to honor it (deferred to v0.3). Documented behavior: the config can be set; the collector that consumes it ships later.
  - `CriticalWaitTypes` key can be set but is not honored until v1.1 per D-105.
  - Writes audited in `FR_RunLog` with `Mode = 'Configure'`.
- **Purge mode (D-139, D-140, D-141, D-149):**
  - Batched 5,000 rows per batch with 250 ms inter-batch pause.
  - Per-batch `TRY/CATCH`; abortable cleanly between batches.
  - Strict deletion order: snapshot children → `FR_Snapshot` → `FR_QueryText` orphans (the `FR_QueryText` table exists; orphan detection runs even though v0.1 doesn't populate it much) → run-log tables.
  - No `TRUNCATE`, no shrink, no index rebuild (D-140).
  - `@WhatIf = 1` attempts exact counts under the same time cap; falls back to `sys.partitions` estimates with `IsEstimated` flag (D-149).
  - Honors snapshot retention (`FR_Config.RetentionDays`) and the 4× rule for run log (D-035).
- **Optional Agent job creation:** `Install @CreateAgentJob = 1` creates a SQL Agent job that runs `Collect` every minute (D-042). Default is 0 (D-005). Skipped on Express edition (D-116) with a clear `FR_RunLog` row.
- **Cost-regression at full collector + rule set (D-143):** Part 4's harness now runs with all seven collectors and all six rules; the 2% / 10 s thresholds still hold.
- **24-hour soak test (D-145):** nightly job installs the proc, runs `Collect` every minute for 24 hours, runs `Report` at random points, asserts repo growth matches §4.2 model, Purge keeps up, no Report >5 s.
- **Tier 1 matrix:** SQL Server 2025 Linux added when GA available.

### Features explicitly excluded

- Demo data mode (D-182 deferred to v0.2/v0.3).
- v0.2+ collectors, rules, schema additions.
- Tier 2 attestation workflow activation (v0.2 per §11.3.2 / D-164).
- Compatibility matrix badge generation (v0.2).
- Empirical-validation issue template per Q-043 (v0.2 release planning).
- `@TimeZone` parameter (v0.4 per D-180).

### Compatibility risks

- **Low to Medium.** Agent job creation uses `msdb.dbo.sp_add_job` etc.; this is well-established across all supported versions but is unavailable on Azure SQL DB (D-109) and Express (D-116). Capability flag gates both.
- Purge `@WhatIf` estimate fallback (D-149) reads `sys.partitions` which is universal.

### Performance/safety risks

- **Medium.** Purge is the second-largest source of risk in DBA tools (per §9.8). The batched-with-pause design (D-139) is the mitigation. Tested explicitly: artificial 5M-row `FR_Wait` fixture; Purge must complete batch-by-batch without filling the log.
- **Configure write race:** if two Configure writes happen concurrently, the last-writer-wins on a per-key basis. No applock is needed because writes are atomic single-row updates. Documented.
- **Soak test resource cost:** 24 hours of CI is expensive; run nightly out-of-band only.

### Test approach

- **Configure read/write round-trip:** set a key, read it back, verify FR_RunLog has the audit row.
- **Configure unknown key:** verify clean refusal.
- **Purge batch behavior:** load 50,000 rows older than retention; run Purge; verify exactly the expected count remains and batches were honored.
- **Purge `@WhatIf` exact path:** small repo; verify exact counts returned with `IsEstimated = 0`.
- **Purge `@WhatIf` estimate path:** simulate cap exhaustion; verify estimates returned with `IsEstimated = 1`.
- **Agent job test:** Install with `@CreateAgentJob = 1`; verify job exists and is enabled; Uninstall removes it.
- **Express edition:** Install with `@CreateAgentJob = 1` on Express; verify skip with clear FR_RunLog row.
- **Cost regression at full collector + rule set:** ≤2% drop, no Collect >10 s.
- **Soak test 24h:** repo growth within ±20% of §4.2 model; Purge keeps up; no Report >5 s.

### Rollback / removal considerations

- Reverting Part 8 removes Configure/Purge; manual `UPDATE` and `DELETE` against `FR_Config` and `FR_*` tables still work for power users.
- Agent jobs created via the opt-in must be removed by an Uninstall *before* revert; otherwise the job will keep calling a Collect mode that may have changed signature. Documented.

### Acceptance criteria

1. `Configure` mode reads and writes `FR_Config` with audit rows in `FR_RunLog`.
2. Unknown keys are refused with a clear error.
3. `Purge` mode batches correctly, honors retention, never uses `TRUNCATE`.
4. `Purge @WhatIf` returns exact counts when affordable, estimates with `IsEstimated` flag when not.
5. Agent job opt-in creates the job; Uninstall removes it.
6. Cost regression at full collector + rule set: ≤2% drop, no Collect >10 s.
7. 24-hour soak test passes on the nightly CI workflow.
8. Tier 1 matrix expanded to include 2025 Linux (when 2025 GA available).
9. `docs/modes/configure.md` and `docs/modes/purge.md` exist and match implemented behavior.
10. Static analysis passes; CI Tier 1 passes.

---

# Part 9 — Documentation completeness, external DBA validation, v0.1 RC tag

**The release-readiness part. No new code.**

### Goal

Complete the v0.1 documentation set per the v0.1 acceptance criteria in §11.2.5. Obtain external DBA validation (acceptance criterion #12 from §11.2.5, mandatory). Tag v0.1.

### Objects affected

- `README.md` — final 2-AM-friendly version per D-168.
- `docs/getting-started.md`.
- `docs/modes/` — pages for all 8 modes.
- `docs/rules/` — pages for FR_R0001–FR_R0006 and FR_R0026.
- `docs/compatibility/matrix.md` — auto-generated stub (full automation lands in v0.2 per D-165).
- `docs/operations/troubleshooting.md` — the failure-mode catalog from §9.9 (D-147).
- `docs/contributing/` — all pages from D-151 layout.
- `CHANGELOG.md` — initial v0.1 entry per D-175.
- `examples/01-first-run.sql`, `examples/02-headline-incident.sql` — runnable, CI-tested in Part 2's workflow (per D-170; the workflow needs a one-line addition to execute examples against fixtures).
- `LICENSE` (MIT per D-179), `SECURITY.md` (minimal in v0.1; full security model is Q-041 deferred to v1.0), `SUPPORT.md`, `CODE_OF_CONDUCT.md`.
- New: `.github/workflows/release.yml` (minimal v0.1 release workflow; full release process per D-173 hardens at v1.0).

### Features included

- **README** per D-168 structure.
- **Per-mode docs** for all 8 v0.1 modes.
- **Per-rule docs** for FR_R0001–FR_R0006 and FR_R0026 (all using D-161 template).
- **Failure-mode catalog** as user-facing doc per D-147.
- **Examples** runnable and CI-tested.
- **CHANGELOG** initial entry in Keep a Changelog 1.1.0 format per D-175.
- **Release workflow** that produces a versioned `.sql` artifact and a GitHub Release.
- **External DBA validation** — at least one external DBA installs v0.1 RC on a real instance and reports back; feedback addressed before tagging.

### Features explicitly excluded

- Tier 2 attestation workflow (v0.2).
- Compatibility matrix auto-generation (v0.2).
- Demo data mode (v0.2/v0.3 per D-182).
- Empirical-validation issue template (v0.2 release planning per Q-043).
- Full SECURITY.md content (Q-041 deferred to v1.0).
- Full appendices (Q-042 deferred to v1.0).
- Two-maintainer wording review pass on all 26 rules (v0.4).

### Compatibility risks

- None — docs and process only.

### Performance/safety risks

- None — docs and process only.

### Test approach

- **Doc completeness audit:** every shipped mode, rule, collector, config key has a doc page.
- **README example works:** copy-paste the headline example from README and run on a clean install; must produce the documented output.
- **Examples CI:** the CI workflow runs each example file against a fixture and verifies clean execution.
- **External DBA report:** at least one external DBA's feedback is documented in the v0.1 RC PR thread, with maintainer responses to each item (resolved, deferred to v0.2 with issue number, or rejected with reason).

### Rollback / removal considerations

- A tagged release cannot be untagged in practice. If v0.1 RC is found broken between RC and GA, the response is v0.1.0.1 patch per D-174, not retraction.

### Acceptance criteria (v0.1 GA — these are §11.2.5 verbatim plus a Part-9-specific check)

1. The shipped artifact installs cleanly on SQL Server 2019 and 2022 Linux from a fresh database. ✓ (Part 3+)
2. `Collect` completes in under 10 seconds on the synthetic OLTP fixture and under 30 seconds on at least one manually-tested busy production-class system. ✓ (Part 4+ for synthetic; Part 9 for production-class)
3. Six rules produce expected output on their respective fixture incidents. ✓ (Part 7)
4. `Report` produces deterministic byte-identical Markdown across two runs of the same window. ✓ (Part 6)
5. `Uninstall` removes every `FR_*` object cleanly and leaves no orphans. ✓ (Part 3 + Part 8 Agent-job extension)
6. All eight modes have complete documentation pages. ✓ (Part 9)
7. Six rules have complete documentation pages. ✓ (Part 7 + Part 9 finalization)
8. The README's headline example actually works. ✓ (Part 9 audit)
9. Tier 1 CI is green. ✓ (every part)
10. The static-analysis suite passes. ✓ (every part since Part 2)
11. The cost-regression test passes. ✓ (Part 4+)
12. **At least one external DBA (not a project maintainer) has installed v0.1 RC on a real instance and provided feedback. The feedback is addressed before tagging.** ✓ (Part 9)
13. CHANGELOG entry exists for v0.1 in Keep a Changelog format with tagged RuleIds and Modes. ✓ (Part 9 per D-175)

---

## Cross-part risk summary

| Risk | Part introducing it | Mitigation |
|---|---|---|
| Capability probe gaps on 2012/2014/2016 | Part 4 | Tier 2 attestation in v0.2; capability-flag unit tests with simulated snapshots |
| Cost regression under real production workloads | Part 4 / Part 5 | CI cost-regression test + Part 9 external DBA validation; D-188 commitment makes empirical validation a v0.2 release gate |
| Output contract premature lock | Part 6 | Deliberate per §11.2.2 — lock the contract before runbooks form; semver-stable per D-023 |
| Wording slip in rules | Part 7 | Two-maintainer review per D-158 + D-189 ongoing commitment |
| Purge log pressure | Part 8 | Batched + paused + abortable per D-139; tested with 50,000-row fixture |
| Agent job orphans on revert | Part 8 | Documented in PR; Uninstall removes the job |

## Cross-part deferred items reference

These appear in the design but are out of v0.1 scope and therefore out of this plan:

- v0.2 collectors and rules (FR_R0007–FR_R0014; tempdb/memory/Agent/backup/AG/deadlock collectors; `FR_v_*` views; Tier 2 attestation workflow; compatibility matrix badge generation).
- v0.3 (Query Store integration; plan cache headlines; error log opt-in collector; schema/stats activity; FR_R0015–FR_R0020; QS drilldown; demo data mode).
- v0.4 (HA-other collector; buffer pool opt-in; FR_R0021–FR_R0026 full; `@TimeZone` parameter; wording polish pass; soak extended to 7 days).
- v1.0 (hardening; doc completeness; full Tier 1 matrix attestations; Section 12 security/threat model per Q-041; Section 13 appendices per Q-042; release/hotfix dry-runs; wording lock).

---

## Plan summary

**9 parts. Each independently mergeable. v0.1 ships when Part 9's acceptance criteria are all green.**

The plan respects the design lock review approvals (D-188, D-189, D-190 commitments are operationalized at the part where they first apply: D-188 → Part 4 cost-regression, Part 9 external DBA; D-189 → Part 7 wording review; D-190 → v0.2 release planning, not v0.1).

No code in this document. No implementation has started.
