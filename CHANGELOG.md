# Changelog

All notable changes to sp_SQLFlightRecorder are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Per design decision D-175, entries tag the affected `RuleId`s and `@Mode`s so
runbook owners can grep. Versioning follows the project-specific semver of
D-171 (major = contract break; minor = additive; patch = fixes).

## [Unreleased]

Retention and repository-performance hardening (**D-199**). Root cause
addressed: when purge was not scheduled or not enforced, `FR_*` repository
tables grew without bound in real deployments (35M+ rows observed in
`FR_SchemaActivity`, 12M+ in `FR_QueryStoreTopN`) and `Report` ran for hours.
SQLFR must not silently become its own performance problem, so retention is
now operationally safe by default. `ToolVersion` is `1.1.0`;
`SchemaVersion` advances to `0.5.0` (index-only DDL, forward-only per D-038);
`RulePackVersion` stays `0.4.3` (no rule logic or catalog change — the Report
changes below are access-path and evidence-cap work, not rule behavior).

### Added

- **Post-collect purge step in the collector job** (`@Mode = Install`,
  `@CreateAgentJob = 1`): the `SQLFlightRecorder Collect` Agent job now has two
  steps — `Collect`, then `Purge` (`@WhatIf = 0`) as normal cleanup. Existing
  single-step jobs from earlier releases are upgraded in place (the step is
  added and the Collect step is pointed at it). Job, step, and schedule
  creation are idempotent: re-running Install never duplicates any of them.
- **Daily purge backstop job** (`@Mode = Install`, `@CreateAgentJob = 1`): a
  second Agent job, `SQLFlightRecorder Purge`, runs
  `EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;` daily at
  02:30 server time, protecting retention when the collector job is disabled,
  changed, or failing before its cleanup step. Recorded in `FR_Config` as
  `PurgeAgentJobName` / `PurgeAgentJobCreatedBySQLFlightRecorder`.
- **Retention/purge-support indexes** (`@Mode = Install`; the `SchemaVersion`
  `0.5.0` DDL): a nonclustered `SnapshotId` index on every `FR_Snapshot` child
  table, `IX_FR_Snapshot_RunId`, `IX_FR_RunLogStep_RunId`, and
  `IX_FR_Request_QueryHash`. Purge deletes verify child foreign keys per
  deleted `FR_Snapshot` row; without these indexes each check was a full
  child-table scan, which is what made purge (and run-log cleanup, and
  `FR_QueryText` orphan cleanup) unusable on grown repositories. Created
  idempotently on fresh installs and upgrades — the first Install over a large
  old repository pays a one-time index build.
- **Retention guardrails** (`@Mode = Configure`): `SnapshotRetentionDays` now
  accepts 1–31 and `RunLogRetentionDays` 1–124; out-of-range values return a
  clean `InvalidConfigValue` error and `FR_Config` is not updated. New tunable
  `RepositoryTableWarnRows` (default 5,000,000) drives the Status size warning.
- **Status retention-health result set** (`@Mode = Status`; additive seventh
  result set `CheckName, CheckStatus, Detail` per D-023): warns when the
  oldest snapshot exceeds `SnapshotRetentionDays`, when purge appears not to
  be keeping up (oldest data > retention + 2 days, with last-purge evidence),
  when the collector job lacks a Purge step, when the daily purge job is
  missing on Agent-capable platforms, and when an `FR_*` table exceeds
  `RepositoryTableWarnRows`. msdb job checks are capability-gated and
  permission-safe (`Unknown`, never an error).
- **Schema-activity evidence cap warning** (`@Mode = Report`, RuleId
  `FR_R0026_CoverageAndCapabilitySummary`): when the window holds more
  distinct schema/stats events than `@MaxFindings`, the timeline is capped and
  one Informational Coverage finding says so and recommends narrowing the
  window or reducing retention.
- **Scheduling guidance by platform** — `docs/operations/scheduling.md`. Which
  scheduler to use is a capability question, not a preference: cron + `sqlcmd` on
  Linux; a SQL Agent job step on Azure SQL Managed Instance (`HasAgent = 1`);
  Azure Elastic Jobs or an external scheduler on Azure SQL Database, which has
  neither Agent nor msdb. Includes copy-paste snippets and the all-platform
  defaults (leave `CollectErrorLog` and `EnableBufferPoolCollector` off unless
  needed, periodic `Report`, scheduled `Purge`, UTC, and a documented uninstall
  path).

### Changed

- **Uninstall removes both Agent jobs** (`@Mode = Uninstall`): the collector
  job and the daily purge job are dropped when this tool created them;
  `@WhatIf = 1` previews both; already-missing jobs never fail the uninstall;
  `@PreserveRunLog` semantics are unchanged.
- **Install on platforms without SQL Agent** (`@Mode = Install`,
  `@CreateAgentJob = 1` on Azure SQL Database / Express): no job is attempted;
  the Install result now states that BOTH
  `EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';` and
  `EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;` must be
  scheduled externally.
- **Report window-first reads** (`@Mode = Report`; performance only, output
  contract and rule behavior unchanged): the baseline builder, restart
  detection, FR_R0005's corroborating counter read, FR_R0021–FR_R0024's
  window scans, and the v0.4 timeline events now carry child-side
  `SnapshotUtc` range predicates (the child value always equals its parent's),
  so every read rides the clustered index instead of joining through the
  parent alone. The schema-activity timeline is rewritten window-first with
  bounded `SnapshotUtc` access, deduplicated per distinct event (the collector
  re-captures each event on every snapshot in its 7-day lookback; the timeline
  previously emitted those duplicates), and capped at `@MaxFindings` with the
  Coverage warning above.
- **Repository footprint row counts** (`@Mode = Status` result set 5 and
  `FR_v_RepositoryFootprint`): `RowCount` now counts heap/clustered rows only
  (`index_id IN (0, 1)`), so the new nonclustered indexes do not inflate it;
  `UsedKb` still includes index pages.
- Upgrade harness (`tests/upgrade/run-upgrade.sh`) now asserts that
  `SchemaVersion` advances to the current artifact's value (measured from a
  fresh reference install, not a hard-coded string) and that the new
  `SnapshotId` indexes exist after upgrade.
- **Purge is documented as mandatory operational maintenance** across README,
  the user guide, `docs/configuration.md` (retention ranges and the
  not-a-warehouse note), `docs/operations/scheduling.md` (per-platform purge
  scheduling, including Azure SQL Database external scheduling of both
  statements), `docs/operations/troubleshooting.md` (huge-repository /
  slow-Report recovery), and the regenerated mode pages for Install,
  Uninstall, Status, Configure, and Purge.
- **Azure SQL Managed Instance and Azure SQL Database are certified as
  supported** (**D-196**), both **Verified** by manual Tier-2 attestation against
  `v1.0.0`. MI ran the full collector set with only `AlwaysOnState` skipped;
  Azure SQL Database returned `Success` with four collectors skipped by design —
  `AgentJobs`, `BackupHistory`, `Deadlocks`, `AlwaysOnState` — each reason
  carried in the `FR_R0026` coverage finding. Both installed 25 core `FR_*`
  tables plus 5 `FR_v_*` views and uninstalled leaving `RemainingFrObjects = 0`.
  **No equivalence is claimed** between the two, or between either and on-prem.
- **The compatibility matrix now lists every version and platform explicitly** —
  no collapsed "2017+" row — including separate rows for **SQL Server on Azure VM
  (IaaS)**, which is the ordinary engine on a VM you administer and inherits its
  matching on-prem row, as distinct from the Azure PaaS products.
- The matrix states plainly that **Tier-2 "Verified" is not Tier-1 verified**: it
  is one manual run at one point in time, where Tier 1 is an automated per-push
  gate that blocks the build on failure.

- **Primary supported range is now SQL Server 2014–2025** (**D-195**, amending
  D-108's range framing). SQL Server **2012 is demoted to legacy best-effort**:
  the `v1.0.0` lifecycle was manually tested on 2012 Windows and completed, but
  with a known `SchemaActivity` collector degradation — both `Collect` runs
  returned `PartialSuccess` (`dbsDone=0; dbErrors=1; budgetHit=0`). Platform
  split now stated wherever compatibility is claimed: **2017+ on Linux and
  Windows**, **2014/2016 Windows-only**, **2012 Windows-only best-effort**.
- **SQL Server 2014 and 2016 (Windows) are now Tier-2 Verified** on manual
  `v1.0.0` attestations — full lifecycle Success, evidence and caveats recorded
  in the compatibility matrix. This is the first upgrade of a Tier-2 status on
  real evidence, which is the only path D-192 permits.
- Note for anyone comparing docs with the tool: the released `1.0.0` artifact
  reports `SupportedSqlServerRange = 'SQL Server 2012–2025'`. That is not false
  — 2012 remains supported best-effort — but it is coarser than this policy, and
  the artifact is immutable.

## [1.0.0] - 2026-07-29

**First stable release.** The v1.x contract starts here: rule IDs, output
columns, and the forward-only schema are now "1.0 is forever" promises — see
[docs/compatibility/support-policy.md](docs/compatibility/support-policy.md).

Relative to `1.0.0-rc.1` the **only artifact change is version metadata**:
`ToolVersion` `1.0.0-rc.1` → `1.0.0` and the build date. Everything else in this
entry is documentation and process. `SchemaVersion` stays `0.4.0` (no DDL,
forward-only, D-038) and `RulePackVersion` stays `0.4.3` — it names the release
that last changed rule logic or the rule catalog, not the tool release (D-085),
and no rule has changed since 0.4.3.

**Compatibility, stated by tier.** Tier-1 **verified** in automated CI: SQL
Server 2017 / 2019 / 2022 / 2025 Developer, plus 2022 Express and Standard.
Tier-2 **Unverified** — no attestation received, meaning untested, not "works"
and not "broken": SQL Server 2012 / 2014 / 2016 (Windows), Azure SQL Managed
Instance, Azure SQL Database. The two tiers are separate claims; see
[docs/compatibility/matrix.md](docs/compatibility/matrix.md) before relying on a
Tier-2 target.

**Upgrades** from 0.4.1 / 0.4.2 / 0.4.3 / 1.0.0-rc.1 are validated and
migration-free (`tests/upgrade/run-upgrade.sh`). `v0.4.0` has no public tag and
is untested — not faked, not claimed.

### Changed

- `ToolVersion` is now `1.0.0` (surfaced by `About`, `Help`, `Status`, and the
  Markdown report header; build date 2026-07-29). **No behavior change.**
- **Security reporting now has a dedicated private contact.** `SECURITY.md`
  directs vulnerability reports to
  `sqlflightrecorder-security@forwardthinkersconsulting.com`. GitHub private
  vulnerability reporting is **not** enabled on this repository, and the policy
  says so rather than pointing reporters at a *Report a vulnerability* button
  that is not available to them.
- **Conduct reporting has a designated v1.0.0 path.** `CODE_OF_CONDUCT.md`
  routes reports to the repository owner through GitHub maintainer channels,
  with a fallback for reporters who have no private channel, marked explicitly
  as the v1.0.0 path rather than a placeholder. No address invented. It also
  states that a single-maintainer project cannot independently review a report
  about that maintainer, and points to GitHub's own abuse reporting as an
  independent route.
- **Owner sign-off is sufficient for the v1.0.0 wording lock** (**D-193**),
  superseding D-158's two-reviewer rule and D-189's second-reviewer eligibility
  for that sign-off only. Two-maintainer review resumes automatically once a
  second maintainer exists or the project moves to an organization/team model.
  This narrows who signs off, not what §6.7 requires of the wording.
- **Cost-regression (D-143) and soak (D-145) are not a v1.0.0 gate**
  (**D-194**). No green evidence exists for either and none is claimed: both
  workflows are schedule/dispatch-only by design, and scheduled workflows run
  only from the default branch, where neither file exists yet.
- **Tier-2 attestation is no longer a v1.0.0 release gate** (**D-192**). The
  earlier §11.6 rule required at least 4 of 5 Tier-2 targets attested before
  final v1.0.0; final v1.0.0 may now ship with those targets **Unverified**.
  What replaces the count is a wording obligation: compatibility claims must
  keep **Tier-1 verified** (automated CI evidence) and **Tier-2 pending /
  unverified** (no attestation received) visibly separate, and no unattested
  target may be described as verified or tested. SQL Server 2012, 2014 and 2016
  and the Azure targets stay *Unverified* — untested, not "works", not "broken"
  — until a real attestation is recorded. Attestation collection continues as
  post-1.0 work under D-164 and the D-190 18-month review.
- The Tier-2 attestation issue template now **requires** the capability snapshot
  and takes it as a multi-line field. The process always listed it as required
  evidence — it is what pins which target the evidence describes — but the
  template marked it optional, so an attestation could arrive unrecordable.
- The upgrade harness now includes `1.0.0-rc.1` as a source version, so the
  RC-to-final upgrade path is covered. Fixed a latent bug it exposed: database
  names were built by stripping dots only, so a prerelease version's hyphen
  produced an illegal identifier.
- The **hotfix process (D-174) was rehearsed** before this release: branch from
  the latest tag, minimal fix, validation, forward-merge. Recorded with its
  limits in `docs/release-readiness-v1.0.0-rc.1.md` — the rehearsal used a
  docs-only fix, so it did not exercise the regression-test leg.

## [1.0.0-rc.1] - 2026-07-21

First release candidate for v1.0.0. This is a **documentation, CI/release-process,
and version-metadata** stabilization on top of `0.4.3`. It changes **no schema,
output contract, rule ID, rule logic, collector, or mode**: `SchemaVersion` stays
`0.4.0`, and `RulePackVersion` stays `0.4.3` because no rule logic or catalog
entry changed since 0.4.3 (the rule-pack version names the last rule change, not
the tool release — D-085). Upgrades from 0.4.1 / 0.4.2 / 0.4.3 are validated and
migration-free.

### Changed

- `ToolVersion` is now `1.0.0-rc.1` (surfaced by `About`, `Help`, `Status`, and
  the Markdown report header; build date 2026-07-21). No behavior change.

### Added

- **Documentation completeness** (§11.6): a page for every mode, rule, and
  config key, enforced by a CI doc-coverage gate (`scripts/check-doc-coverage.sh`)
  plus rule/mode/compat-matrix generators.
- **CI / release wiring**: rule fixtures + demo golden in CI; a dry-runnable
  release workflow (`release.yml`) that builds a byte-identical artifact with a
  checksum and attaches the compatibility matrix; out-of-band cost/soak harnesses
  (non-blocking).
- **Compatibility**: six Tier-1 verified targets (2017/2019/2022/2025 Developer +
  2022 Express/Standard) and a documented Tier-2 attestation process for
  2012/2014/2016 Windows + Azure MI/DB (pending attestation).
- **Upgrade-path validation** harness (`tests/upgrade/run-upgrade.sh`).
- **Security / support / governance** docs: threat-model, support policy,
  contributing guides, CODEOWNERS, and eight issue templates.

### Notes

- The **D-076 / D-189 wording lock** was reviewed with no changes required: every
  rule recommendation is advisory and evidence-gated ("consider … only after
  validating"), with explicit guards against reflexive action; no unsafe advice
  is present (no kill / force / `NOLOCK` / shrink; no unqualified root-cause
  claims). See `docs/wording-lock-review.md`.
- **Must resolve before final v1.0.0:** a dedicated private security contact or
  GitHub private vulnerability reporting; a dedicated conduct contact; the
  two-maintainer wording sign-off; ≥ 4 of 5 Tier-2 attestations; and,
  optionally, the historical `v0.4.0` upgrade artifact (no public `v0.4.0` tag
  exists). `SECURITY.md` and `CODE_OF_CONDUCT.md` describe the channels that
  exist today rather than promising contacts that do not — no placeholder
  addresses are published.
- **CODEOWNERS** routes to the repository owner account `@forward-thinkers-lab`.
  The repository is owned by a user account, not an organization, so GitHub team
  syntax cannot resolve here; D-185's `@core-maintainers` team routing is
  superseded by **D-191** and reactivated only if the project moves under an
  organization.

## [0.4.3] - 2026-07-17

Pre-v1.0 rule-maturation patch. Resolves the last documented rule-behavior gap
before the v1.0 contract/wording lock. `SchemaVersion` stays `0.4.0` (no DDL).

### Changed

- **FR_R0003 TopWaitTypeSpike** (`@Mode = Report`): severity now escalates to
  **High** when the top spiking wait is a hard-coded critical wait type (D-093:
  `PAGEIOLATCH_*`, `WRITELOG`, `RESOURCE_SEMAPHORE`, `LCK_M_*`, `THREADPOOL`,
  `SOS_SCHEDULER_YIELD`); **Medium** otherwise. This completes the §7.9 "Medium
  (escalates High)" definition. Escalation is by wait class, not row count, so
  D-069 holds; it uses the hard-coded list, not the `CriticalWaitTypes` config
  key (honoring stays v1.1, D-105). The `FR_Rules` catalog severity remains the
  Medium base (D-091). `InstallDemoData` does not seed `FR_Wait`, so the demo
  golden is unchanged — the output contract is stable.

### Added

- FR_R0003 fixtures (critical→High, non-critical→Medium, no-delta→silent) and a
  `.gitattributes` keeping `.sh`/`.tsv`/`.sql`/`.md` LF so a CRLF checkout cannot
  break the byte-exact golden or bash scripts on Linux CI.

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
