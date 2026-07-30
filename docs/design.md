# SQL Server DBA Flight Recorder — Design Document

> **Note on provenance.** This consolidated document is assembled from the chartering and design conversation that produced decisions D-001 through D-187. Sections 6 through 11 were written in full during the design session and are preserved here faithfully. Sections 1 through 5 were established earlier in the design work; the text below reconstructs them from the decision log (D-001 to D-061) and cross-references in later sections, organized for readability. Where a reconstruction summarizes rather than reproduces original prose, that is noted.
>
> **Design Lock Status:** A formal design lock / compliance review against the original Master Charter was completed (see `docs/design-lock-review.md`). All 18 charter requirements passed. All 40 design-time open questions (Q-001–Q-040) are resolved. 186 of 187 decisions are Locked; D-181 is Tentative (a runtime-tunable default). The design is approved for implementation planning at v0.1 scope.
>
> No decisions have been invented, dropped, or silently simplified. All D-### identifiers from the decision log appear in this document or in `docs/decisions.md`.

---

## Table of Contents

1. [Project Charter and Scope](#1-project-charter-and-scope)
2. [Procedure Surface — Modes and Parameters](#2-procedure-surface--modes-and-parameters)
3. [Architectural Principles](#3-architectural-principles)
4. [Repository Schema](#4-repository-schema)
5. [Collection Strategy](#5-collection-strategy)
6. [Reporting Strategy](#6-reporting-strategy)
7. [Recommendation Rules](#7-recommendation-rules)
8. [SQL Server Version Compatibility Plan](#8-sql-server-version-compatibility-plan)
9. [Performance and Safety Plan](#9-performance-and-safety-plan)
10. [Open Source Contribution Model](#10-open-source-contribution-model)
11. [MVP Scope and Phased Roadmap](#11-mvp-scope-and-phased-roadmap)
12. [Section 12 — Deferred (security/threat model)](#12-deferred-securitythreat-model)
13. [Section 13 — Deferred (appendices)](#13-deferred-appendices)

---

## 1. Project Charter and Scope

*Summary reconstructed from D-001–D-024 and charter references throughout later sections.*

### 1.1 What the tool is

`sp_SQLFlightRecorder` is a single pure-T-SQL stored procedure that captures SQL Server diagnostic data on a schedule and produces honest, prioritized findings about server health and recent incidents. It is a DBA's flight recorder: cheap to run continuously, useful after the fact.

### 1.2 What the tool is not

- Not a monitoring platform (no alerting, no dashboards — **D-019**).
- Not a notification system (no email, no webhooks — **D-019**).
- Not an "AI" tool (no ML, no anomaly detection — **D-012**).
- Not a multi-instance product (per-instance install only — **D-018**).
- Not a remediation tool (it diagnoses; it never takes corrective action).

### 1.3 Naming and entry surface

- Procedure name: `dbo.sp_SQLFlightRecorder`, with the `sp_` prefix to allow cross-database execution from `master` (**D-001**) despite Microsoft's discouragement of the prefix for user procedures.
- Single entry point with multiple `@Mode` values (**D-002**).
- Default `@Mode = 'Help'` so accidentally executing the procedure cannot harm a server (**D-003**).

### 1.4 Install location and footprint

- Default install in a user database; install in `master` is opt-in (**D-004**).
- SQL Agent job creation is opt-in (**D-005**); the charter forbids permanent server changes by default.
- No Extended Events session creation in v1 (**D-021**).
- Repository tables are prefixed `dbo.FR_*`; schema flexibility deferred (**D-022**).
- `CollectAndReport` mode exists but is documented as non-recommended; the real value is scheduled `Collect` plus on-demand `Report` (**D-024**).

### 1.5 Output discipline

- `Report` mode returns at most two result sets: Findings and Timeline (**D-006**).
- Output contract is semver-stable and additive in minor releases (**D-023**).
- Every finding carries Severity, Confidence, and EvidenceType (**D-013**).
- The rule pack is deterministic; no machine learning (**D-012**).
- Rules read only from the repository plus bounded Query Store catalog views (**D-014**).
- Query plans are never shredded by default (**D-015**).
- `READ UNCOMMITTED` session-wide; no `NOLOCK` hints in any recommendation (**D-017**).

### 1.6 Time handling

- All storage is UTC `datetime2(3)` (**D-016**); local-time conversion only for display.
- `@StartTime` / `@EndTime` interpreted as server local time in v1 (**D-180**); explicit `@TimeZone` deferred to v0.4+.

### 1.7 Charter pillars (operational summary)

- **Boring, transparent, easy to test.** Deterministic behavior; auditable evidence.
- **Honest.** Severity / Confidence / EvidenceType on every finding; no overclaiming; coverage gaps are findings, not silence.
- **Safe on production.** Bounded reads; no plan shredding; no user-table scans; cooperative timeout.
- **Compatible.** Primary range SQL Server 2014 through 2025, on-prem and cloud; capability-driven branching. 2017+ on Linux and Windows; 2014/2016 Windows-only; 2012 legacy best-effort with a known `SchemaActivity` limitation (**D-195**).
- **Open source first.** GitHub-native; DBA-friendly contribution model.

---

## 2. Procedure Surface — Modes and Parameters

*Summary reconstructed from D-002–D-006, D-024, D-128, D-149, D-182, D-183, and references throughout later sections.*

### 2.1 Modes (v1 surface)

| Mode | Purpose | Notes |
|---|---|---|
| `Help` | Default; prints usage, version, capability snapshot, failure-mode catalog | D-003 |
| `Install` | Idempotent install of schema, proc, optional Agent job | D-004 (default user DB); D-005 (Agent opt-in) |
| `Uninstall` | Clean removal of all `FR_*` objects | D-183 (drops everything; `@PreserveRunLog=1` opt-in) |
| `Collect` | Take one snapshot | D-009 (per-collector TRY/CATCH); D-011 (applock) |
| `CollectDebug` | Internal mode written when `@Debug=1`; no collector rows | D-128 |
| `Report` | Produce Findings + Timeline for a time window | D-006 (max two result sets) |
| `Status` | Current configuration, capability snapshot, run-log summary, repository size | |
| `Configure` | Read/write `FR_Config` entries | Validates writes |
| `Purge` | Batched retention cleanup | D-139, D-149 (`@WhatIf` exact-or-estimated) |
| `CollectAndReport` | Documented as non-recommended | D-024 |
| `InstallDemoData` | Deferred to v0.2/v0.3 | D-182 |

### 2.2 Key parameters

| Parameter | Default | Notes |
|---|---|---|
| `@Mode` | `'Help'` | D-003 |
| `@DatabaseName` | NULL | Filter findings to one DB (post-evaluation, D-070) |
| `@StartTime`, `@EndTime` | NULL | Server local time in v1 (D-180) |
| `@MinSeverity` | `'Low'` | Post-evaluation filter (D-070); cannot hide Critical |
| `@MaxFindings` | 200 (10–2000) | Safety cap (D-087) |
| `@TopN` | per-category default 50 | Collector-side only (D-070, D-181) |
| `@OutputFormat` | `'Default'` | `Default` / `FindingsOnly` / `TimelineOnly` / `Markdown` (D-079) |
| `@IncludeQueryPlans` | 0 | Surfaces XML by handle; never parses (D-082) |
| `@TimeZone` | (not in v1) | Deferred to v0.4+ (D-180) |
| `@WhatIf` | 0 | Used by `Uninstall` and `Purge` |
| `@PreserveRunLog` | 0 | `Uninstall` opt-in (D-183) |
| `@Debug` | 0 | PRINTs dynamic SQL without executing (D-114, D-128) |

---

## 3. Architectural Principles

*Summary reconstructed from D-007–D-024 and cross-references throughout later sections.*

### 3.1 Snapshot model

- Cumulative DMVs are stored raw; deltas are computed at report time (**D-007**). This lets the report engine recover from missed snapshots and supports the determinism guarantee.

### 3.2 Capability-driven branching

- Capability probe runs once per invocation (**D-008**). All version, edition, platform, and feature branching uses flags from this probe — never `@@VERSION` string parsing (**D-111**).
- Probe results are persisted to `FR_RunLog.CapabilitySnapshot` (**D-115**).
- Capability snapshot keys are a closed, documented set per release; additive in minors (**D-127**).

### 3.3 Error containment

- Every collector has its own `TRY/CATCH` (**D-009**).
- Cooperative timeout: collectors are ordered cheapest-and-most-volatile first (**D-010**). T-SQL has no preemptive cancellation; bounds are intrinsic to each collector.
- No in-run retry on collector failure; the next scheduled snapshot is the retry (**D-150**).

### 3.4 Concurrency control

- Session-scoped `sp_getapplock` gates `Collect` and `Purge`; `Report` is unlocked (**D-011**).
- No force-snapshot or applock-bypass mode in v1 (**D-061**).

### 3.5 Determinism

- The rule pack is deterministic; identical inputs produce identical outputs (**D-012**, **D-062**).
- Rules read only from the repository plus bounded Query Store catalog views (**D-014**, **D-081**).

### 3.6 Safety primitives

- Plans are never shredded by default (**D-015**, **D-046**).
- `READ UNCOMMITTED` session-wide; no `NOLOCK` hints (**D-017**).
- No transactions across collectors; each collector commits its own inserts.

### 3.7 Output stability

- Output contract is semver-stable; additive in minors (**D-023**).
- The `FR_Rules` catalog table is metadata; rule logic stays in code (**D-029**).

---

## 4. Repository Schema

*Summary reconstructed from D-025–D-041 and cross-references in later sections.*

### 4.1 Shape

- 15 tables in v1, organized around a snapshot-spine model (**D-025**).
- Every snapshot table has a `BIGINT IDENTITY` PK (**D-030**) and a clustered index leading with `SnapshotUtc` (**D-031**).
- Declared foreign keys, no cascading deletes (**D-032**); purge code knows the dependency order.

### 4.2 Schema versioning

- Forward-only migrations (**D-038**); snapshot data is never lost on upgrade.
- Downgrade is unsupported (**D-039**); prevents silent corruption.
- The parent `FR_Snapshot` row is inserted *after* all children for that snapshot (**D-135**) so reports never see orphaned children.

### 4.3 Table list (v1)

Core tables in v0.1: `FR_Config`, `FR_RunLog`, `FR_RunLogStep`, `FR_Snapshot`, `FR_InstanceSnapshot`, `FR_Configuration`, `FR_Request`, `FR_Wait`, `FR_FileStat`, `FR_PerfCounter`, `FR_QueryText`, `FR_Rules`.

Deferred to later phases (**D-037**): `FR_Tempdb`, `FR_Memory`, `FR_AgentJob`, `FR_BackupHistory`, `FR_AlwaysOnState`, `FR_Deadlock` (v0.2); `FR_QueryStoreTopN`, `FR_PlanCacheSummary`, `FR_ErrorLog`, `FR_SchemaActivity` (v0.3); `FR_HaState`, `FR_BufferPool` (v0.4).

### 4.4 Storage choices

- `PAGE` compression default, with cascade fallback by edition (**D-034**).
- No `NVARCHAR(MAX)` on hot per-snapshot rows (**D-040**); bounded fields may truncate.
- Sentinel values `DatabaseId = 0`, `SessionId = 0` for instance-scoped rows (**D-041**).

> **At-risk note (Charter §13, "Minimal storage"):** The storage envelope of 200 MB – 1.5 GB at default 7-day retention (§4.2 modeled estimate) is unverified at scale. The `Status` mode surfaces actual repository growth; retention is configurable. Empirical validation is expected through v0.1/v0.2 early adopters.

### 4.5 Configuration storage

- Multi-value config entries are semicolon-delimited (**D-026**, resolved Q-003).
- `FR_QueryText` is deduplicated on `(QueryHash, SHA2_256(SqlText))` to handle `query_hash` collisions and NULL/ad-hoc text (**D-027**, resolved Q-004).
- `InstanceFingerprint` is stored on `FR_RunLog` and `FR_InstanceSnapshot` but is never used in a PK or FK (**D-028**, resolved Q-008 storage portion) — repositories are restorable across instances.

### 4.6 Findings persistence

- No persisted Findings or Timeline tables in v1 (**D-036**). Report is the single source of truth; cannot diff yesterday's findings.

### 4.7 Run log retention

- `FR_RunLog` is retained for 4× the snapshot retention (**D-035**) so self-instrumentation outlives data.

### 4.8 Wait stats handling

- A wait-stats ignore list is applied at collect time (**D-033**) to bound the largest table.
- The ignore list is seeded into `FR_Config` at install with a hard-coded fallback (**D-057**, resolved Q-016).

---

## 5. Collection Strategy

*Summary reconstructed from D-042–D-061 and references throughout later sections.*

### 5.1 Cadence

- Default cadence: one snapshot per minute (**D-042**).
- Sub-minute spikes are intentionally invisible at default cadence.
- Cadence varies by collector class (**D-049**). Lower-frequency collectors gate on time-since-last-successful-capture read from `FR_RunLogStep` (**D-058**, resolved Q-017) — survives restarts and missed runs.
- Plan cache headlines every snapshot; top-N every 5th (**D-055**).

### 5.2 Budget

- Target median collect duration: ~2–8 seconds; hard cap 30 seconds (**D-043**).
- §9 enforces the budget mechanically.

> **At-risk note (Charter §5, "30-second collect cap"):** The 30-second cap is enforced cooperatively (D-010); pathological production cases cannot be reproduced in the synthetic CI workload (D-143). Mitigations: partial-success handling (D-059), FR_R0026 coverage findings, documented limits (D-146). Empirical validation depends on early-adopter feedback during v0.1.

### 5.3 Query Store collector

- Reads only the latest closed Query Store interval per database per snapshot (**D-044**).
- Capped at 50% of the total run budget (**D-045**).
- On budget hit mid-iteration, partial data is persisted and the step is marked `PartialSuccess`; the next report surfaces this as a Medium informational finding (**D-059**, resolved Q-018).

### 5.4 Forbidden DMVs at collector level

- No `CROSS APPLY sys.dm_exec_query_plan` in any v1 collector (**D-046**) — restates **D-015**.
- `dm_tran_locks` only queried for known blocker session IDs, capped at top-50 per blocker (**D-047**).
- Buffer-pool collector is opt-in and skipped on instances >256 GB RAM until empirically validated (**D-051**).
- Stats/schema activity collector caps at the first 50 user databases by `database_id`, configurable (**D-052**).

### 5.5 Tempdb and memory in v0.1

- Tempdb and memory data are captured *within* `FR_Request` and `FR_FileStat` in v0.1 (**D-048**). Dedicated tables wait for v0.2.

### 5.6 msdb-derived collectors

- Backup and Agent collectors use delta-only reads with a last-seen high-water mark (**D-050**).

### 5.7 Deadlocks

- Deadlock collector deduplicates by graph hash so each unique deadlock is shredded once (**D-053**).

### 5.8 Error log

- `xp_readerrorlog` collector is opt-in, off by default (**D-020**).
- Permissions verified at `Configure` time AND defensively at `Collect` time (**D-060**, resolved Q-019).

### 5.9 Self-instrumentation

- Skipped collectors emit `FR_RunLogStep` rows; these surface in Report as Coverage findings (**D-054**).

### 5.10 Collector phasing

- 19 collectors at v1.0, phased across releases (**D-056**): 7 in v0.1, +6 in v0.2, +4 in v0.3, +2 in v0.4.

### 5.11 Row bounds

- `MaxRowsPerCollector = 50` is the configurable v1 default (**D-181**, resolved Q-005), per-category overridable in `FR_Config`. **Status: Tentative** — revisable in any minor based on telemetry and community feedback.

---

## 6. Reporting Strategy

### 6.1 Pipeline

Deterministic pipeline: window → deltas → rules → dedup → filter → rank → emit (**D-062**). The window is internally expanded by one snapshot interval for `LAG()` anchoring; the user-visible window is unchanged (**D-063**).

### 6.2 Restart handling

Restart detection splits the window at the boundary; a Critical informational finding is emitted (**D-064**) because cross-restart deltas of cumulative DMVs are nonsense.

### 6.3 Coverage gates

- Windows with fewer than 2 snapshots emit a Critical informational finding and the report still proceeds (**D-065**, resolved Q-001) because Query Store and msdb history may still inform.
- Gaps >2× cadence emit informational findings; severity scales: Medium (2–5×), High (5–30×), Critical (>30× or ≥50% of window) (**D-066**, resolved Q-006).
- Per-gap findings and the FR_R0026 Coverage Summary both emit and are never deduped against each other (**D-104**, resolved Q-027) — different granularity, different purpose.

### 6.4 Findings result set

- 16-column public contract (**D-067**), semver-stable.
- Sort order: Severity → Confidence → EvidenceType → StartTimeUtc → RuleId (**D-068**), with Informational always last.
- Severity is per-rule constant, never auto-promoted by row count (**D-069**).
- `@MinSeverity` and `@DatabaseName` filter post-evaluation; `@TopN` is collector-side only and never truncates Findings (**D-070**).
- The empty-Findings case is replaced by a synthetic Informational row (**D-077**) that always appears regardless of `@MinSeverity` (**D-083**, resolved Q-021).
- Evidence is capped at approximately 1,900 characters with "(N more — see MoreInfo)" when truncated; full detail goes to MoreInfo (cap 1,000 chars) (**D-084**, resolved Q-022).

### 6.5 Timeline result set

- 12-column contract; strictly chronological, no ranking (**D-071**).
- Durations encoded as paired events (`*Started` / `*Ended`), not as `EndTime` columns (**D-072**).
- `EventType` and `Category` are closed sets, additive in minors, never removed or renamed (**D-073**).
- Empty Timeline is permitted (**D-078**); the asymmetry with Findings is intentional.

### 6.6 Deduplication

- Cross-category dedup forbidden; intra-category dedup by primary anchor (session / query+plan / db+object / 60s bucket) (**D-074**).
- Coverage findings are exempt from dedup (**D-075**).

### 6.7 Wording rules

- Recommendation wording rules are enforced at code review (**D-076**): no "kill session," "force the plan," "use NOLOCK," "shrink," "clear the plan cache," "the root cause is," "always," "never" without qualification.
- Required phrasing patterns: "consider … only after validating that …," "correlates with," "is consistent with."

> **At-risk note (Charter §14, "Clear findings"):** Wording compliance is human-enforced (code review + PR template checklist D-157 + two-reviewer rule D-158). No automated wording linter exists. Defense in depth is real but not perfect. Considered acceptable risk per the design lock review.

### 6.8 Output formats

- `Default` / `FindingsOnly` / `TimelineOnly` / `Markdown` (**D-079**).
- Markdown output is a single `nvarchar(max)` column named `Report` with stable header markers (`# SQL Server Flight Recorder Report`, `## Findings`, `## Timeline`).
- Markdown includes a stable machine-parseable key:value header block of 14 keys, part of the public contract (**D-085**, resolved Q-023): `Tool-Version`, `Schema-Version`, `Rule-Pack-Version`, `Report-Run-Id`, `Report-Generated-Utc`, `Window-Start-Utc`, `Window-End-Utc`, `Instance-Fingerprint`, `Database-Filter`, `Min-Severity`, `Snapshot-Count`, `Coverage-Warning-Count`, `Finding-Count`, `Timeline-Event-Count`.

### 6.9 Performance

- Report runtime target ≤3 s median, hard cap 60 s (**D-080**); over-cap returns partial results plus an Informational finding.
- Report reads no live DMVs except bounded Query Store catalog views (**D-081**).
- `@IncludeQueryPlans = 1` surfaces QS plan XML by handle and never parses it in T-SQL (**D-082**).
- `@MaxFindings` defaults to 200 (clamped 10–2000); overflow is truncated with one Informational row (**D-087**, resolved Q-025).
- Shared baselines are materialized once per report run into session-scoped temp tables; rules read from them (**D-103**, resolved Q-026) — bounds 26-rule baseline cost and ensures all rules agree on "normal."

### 6.10 Drill-down emission

- When a Finding has `QueryId IS NOT NULL`, `MoreInfo` may include a bounded, version-aware, read-only Query Store drilldown query (**D-086**, resolved Q-024): `SELECT`-only against `sys.query_store_*`, explicit `TOP` with small N, no plan-forcing or mutation procs, no `EXEC` or dynamic SQL, prefixed `-- Read-only QS drilldown; review before running:`.

---

## 7. Recommendation Rules

### 7.1 Rule pack scope

- 26 rules at v1.0 total (**D-088**), phased: 6 in v0.1 (FR_R0001–FR_R0006), +8 in v0.2 (FR_R0007–FR_R0014), +6 in v0.3 (FR_R0015–FR_R0020), +6 in v0.4 (FR_R0021–FR_R0026). v1.0 is hardening only.

### 7.2 Rule identity and lifecycle

- `RuleId` format: `FR_R####_ShortName`; never renamed, never reused after retirement (**D-089**).
- Lifecycle states: Active / Disabled / Deprecated / Retired (**D-090**).
- Retirement requires a major release; deprecated rules continue to fire for at least two minors before retirement.

### 7.3 Severity

- Severity is per-rule constant in `FR_Rules`, never auto-promoted (**D-091**) — prevents loudness inflation.

### 7.4 Baselines

- Baselines: 24h median excluding the incident window; require ≥5 prior samples or Confidence downgraded to Low (**D-092**).
- "Critical wait types" allow-list (`PAGEIOLATCH_*`, `WRITELOG`, `RESOURCE_SEMAPHORE`, `LCK_M_*`, `THREADPOOL`, `SOS_SCHEDULER_YIELD`) is hard-coded in v1 (**D-093**).
- The `CriticalWaitTypes` config key is defined in v1.0 but only honored from v1.1 (**D-105**, resolved Q-028) — forward compatibility.

> **At-risk note (Charter §16, "No AI magic"):** Baseline-relative rules use a transparent 24h median (D-092), not machine learning. This is statistical, not ML, and is documented as such in the rule docs (D-161). Skeptics could mischaracterize this; the transparency mechanism (every rule documents its baseline math) is the mitigation.

### 7.5 Maintenance pattern recognition

- Job name patterns hard-coded (**D-094**): Ola Hallengren conventions + common Maintenance Plan names.

### 7.6 Rule-specific windows and exclusions

- FR_R0010 (failed job near incident): window = 15 minutes before `@StartTime` through `@EndTime` (**D-095**).
- FR_R0012 (backup overlap): log backups excluded (**D-096**).
- FR_R0025 (recent CHECKDB/backup age): thresholds — FULL backup >7 days Medium, CHECKDB >14 days High (**D-097**).
- FR_R0026 (Coverage Summary): always emits, cannot be disabled (**D-098**).

### 7.7 Rule disabling

- Disabling rules via `FR_Config.DisabledRules` (semicolon-delimited) (**D-099**).
- Rule execution order is fixed by `RuleId` ascending; no inter-rule dependencies (**D-100**).
- Disabled rules appear in FR_R0026's "Suppressed rules" list (**D-101**).
- Headline (consolidated) rules keep their own `RuleId`; contributors are listed in `MoreInfo`; disabling a contributor does NOT silently disable the headline (**D-106**, resolved Q-029).
- Custom-rule plugin model is out of scope for v1 (**D-102**).

### 7.8 Version-aware rule behavior

- FR_R0015 (Plan regression) fires on SQL Server 2016 using runtime stats only; Confidence is forced down one level and Evidence states why (**D-107**, resolved Q-030).

### 7.9 v0.1 rules (FR_R0001–FR_R0006)

| Rule | Category | Severity | Confidence | Evidence |
|---|---|---|---|---|
| FR_R0001 ActiveBlockingChain | Blocking | High | High | Observed |
| FR_R0002 LongRunningOpenTransaction | Blocking | Medium | High | Observed |
| FR_R0003 TopWaitTypeSpike | Waits | Medium (escalates High) | Medium | Inferred |
| FR_R0004 FileIoLatencySpike | IO | Medium (escalates High) | Medium | Inferred |
| FR_R0005 MemoryGrantsPending | Memory | High | High | Observed |
| FR_R0006 ServerRestartDuringWindow | Configuration | Critical | High | Observed |

### 7.10 v0.2 rules (FR_R0007–FR_R0014)

| Rule | Category | Severity | Confidence | Evidence |
|---|---|---|---|---|
| FR_R0007 BlockingStorm | Blocking | Critical | High | Observed |
| FR_R0008 TempdbVersionStoreGrowth | Tempdb | Medium (escalates High) | High | Observed |
| FR_R0009 TempdbFileImbalanceOrPressure | Tempdb | Medium | Medium | Inferred |
| FR_R0010 FailedSqlAgentJobNearIncident | Maintenance | High | High | Observed |
| FR_R0011 MaintenanceJobOverlap | Maintenance | Medium | Medium | Inferred |
| FR_R0012 BackupOverlapWithIncident | Maintenance | Medium | High | Observed |
| FR_R0013 DeadlocksObserved | Blocking | High | High | Observed |
| FR_R0014 AlwaysOnRoleOrStateChange | HA | Critical | High | Observed |

### 7.11 v0.3 rules (FR_R0015–FR_R0020)

| Rule | Category | Severity | Confidence | Evidence |
|---|---|---|---|---|
| FR_R0015 QueryPlanRegression | QueryStore | High | Medium (Low on 2016) | Inferred |
| FR_R0016 TopCpuConsumerInWindow | QueryStore | Medium | High | Observed |
| FR_R0017 QueryStoreDisabledOnUserDbs | Coverage | Informational | High | Observed |
| FR_R0018 FailedPlanForcing | QueryStore | Medium | High | Observed |
| FR_R0019 QueryStoreNearingCapacity | QueryStore | Medium | High | Observed |
| FR_R0020 HighCompilationRate | PlanCache | Medium | Medium | Inferred |

### 7.12 v0.4 rules (FR_R0021–FR_R0026)

| Rule | Category | Severity | Confidence | Evidence |
|---|---|---|---|---|
| FR_R0021 ConfigurationChangeInWindow | Configuration | Medium | High | Observed |
| FR_R0022 LogReuseWaitElevated | IO | High | High | Observed |
| FR_R0023 ThreadpoolWaitsObserved | Waits | Critical | High | Observed |
| FR_R0024 ResourceSemaphoreWaits | Memory | High | High | Observed |
| FR_R0025 RecentCheckDbOrBackupAge | Maintenance | Medium/High | High | Observed |
| FR_R0026 CoverageAndCapabilitySummary | Coverage | Informational | High | Observed |

### 7.13 Dedup interactions

- FR_R0007 folds FR_R0001 / FR_R0002 (same anchor).
- FR_R0005 and FR_R0024 fold when same anchor.
- FR_R0015 and FR_R0016 fold only when same `query_id`.
- FR_R0026 is exempt from dedup (**D-075**).

---

## 8. SQL Server Version Compatibility Plan

### 8.1 Matrix

- Supported engine range: primary **SQL Server 2014 through 2025**; 2012 is legacy best-effort only (**D-108** as amended by **D-195**). Platform split: 2017+ Linux and Windows; 2014/2016 Windows-only; 2012 Windows-only, best-effort. The released `v1.0.0` artifact still reports `SupportedSqlServerRange = 'SQL Server 2012–2025'` — coarser than this policy, not false, and immutable.
- Synapse, Fabric, Big Data Clusters, Stretch Database — explicitly out of scope.
- Azure SQL Database supported with heavy degradation; per-database install, no Agent/msdb/error log (**D-109**).

### 8.2 Strategy

- No conditional compilation; one file identical for every target (**D-110**).
- Capability probe is the only branching mechanism; never `@@VERSION` parsing (**D-111**).
- Dynamic SQL discipline: anything not in every supported version goes via `sys.sp_executesql` with parameter binding (**D-112**).
- No nested dynamic SQL; no dynamic SQL inside rules (**D-113**).
- `@Debug = 1` PRINTs dynamic SQL without executing (**D-114**); still writes a RunLog entry as `Mode='CollectDebug'` with no collector rows (**D-128**, resolved Q-032).

### 8.3 Capability snapshot

- Persisted to `FR_RunLog.CapabilitySnapshot` per run (**D-115**).
- Keys are a closed, documented set per release; additive in minors (**D-127**, resolved Q-031); the key list is rendered in `Help` and `Status`.

### 8.4 Edition and platform

- Express: skip Agent install with status row; compression cascades per **D-034** (**D-116**).
- Linux: perf counter object name prefix normalized at collect time (strip `SQLServer:` / `MSSQL$INST:`) (**D-117**).

### 8.5 Permissions

- Tiers: `VIEW SERVER STATE` required (install refuses without); `VIEW ANY DEFINITION` strongly recommended; sysadmin discouraged (only for opt-in error log) (**D-118**).
- Missing permissions reported in three places: Install status, `Status` mode, Report FR_R0026 (**D-119**).

### 8.6 Test matrix

- **Tier 1** (automated CI, blocking): SQL Server 2017, 2019, 2022, 2025 Linux containers, latest CU (**D-120**).
- **Tier 2** (manual attestation, not merge-blocking): SQL Server 2014 and 2016 Windows — both **Verified** on manual `v1.0.0` evidence; Azure SQL MI and Azure SQL DB — **pending**; SQL Server 2012 Windows — **legacy best-effort**, lifecycle completes but `SchemaActivity` fails and collects return `PartialSuccess` (**D-121**, **D-195**).
- Golden output tests per version; any byte diff fails CI (**D-122**).
- Capability-flag unit tests with simulated `CapabilitySnapshot` values (**D-123**).
- New major engine releases evaluated within 90 days of GA; capability probes and rules added in a minor release (**D-124**).

> **At-risk note (Charter §10, "SQL Server 2012–2025 compatibility"):** The three oldest supported versions (2012, 2014, 2016) are not in automated CI; they depend on Tier 2 manual attestation (D-121) and the staleness policy (D-164). The matrix badge (D-165) makes verification status visible to users before install. The first 18 months post-launch are the real test of the attestation process. Carried as a release-process risk; not a v0.1 implementation blocker.

### 8.7 Portability and support commitments

- Repository portability across instances is supported by design (**D-125**); no v1 cross-instance UI.
- Major-version support is never dropped in a minor release (**D-126**).

---

## 9. Performance and Safety Plan

### 9.1 Operating envelope

| Metric | Target | Hard cap |
|---|---|---|
| `Collect` wall-clock, busy OLTP | 2–8 s | 30 s |
| `Report` wall-clock, typical | ≤ 3 s | 60 s |
| Query Store portion of `Collect` budget | ≤ 50% | 50% |
| Findings result set rows | typical < 20 | 200 (`@MaxFindings`) |
| CPU during `Collect` | < 5% sustained | (operational) |
| Locks taken on user objects | 0 | 0 |
| XML plans shredded by default | 0 | 0 |

Operating envelope codified as a testable contract (**D-131**).

### 9.2 Session-level safety primitives

Set at the top of every mode (**D-132**):

- `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` (**D-017**)
- `SET LOCK_TIMEOUT 5000` — defense in depth (**D-133**)
- `SET DEADLOCK_PRIORITY LOW` — diagnostic tool always loses (**D-134**)
- `SET XACT_ABORT ON`
- `SET NOCOUNT ON`
- ANSI settings on

### 9.3 Snapshot integrity

- Parent `FR_Snapshot` row inserted *after* all children (**D-135**) — reports inner-join `FR_Snapshot` first and cannot see orphaned children mid-write.

### 9.4 Bounded by construction

- Forbidden DMV list codified and enforced by CI static analysis (**D-136**): `sys.dm_exec_query_plan`, `sys.dm_exec_text_query_plan`, `xp_cmdshell`, `sys.fn_dblog`, `DBCC FREEPROCCACHE`, `DBCC DROPCLEANBUFFERS`, etc.
- Allow-list approach for bounded reads: every external SELECT in collector code has explicit `TOP(N)` with `ORDER BY`, or comes from a documented small-DMV allow-list (**D-137**).
- No cursors anywhere in v1; no `WITH RECOMPILE`; set-based throughout (**D-138**).

### 9.5 Purge

- Batched 5,000 rows per batch with 250 ms inter-batch pause; per-batch `TRY/CATCH`; abortable cleanly (**D-139**).
- No `TRUNCATE`, no shrink, no `ALTER INDEX REBUILD` on the repository (**D-140**) — we do not practice what we forbid.
- Purge order strictly enforced: snapshot children → `FR_Snapshot` → `FR_QueryText` orphans → run-log (**D-141**).
- `Purge @WhatIf` attempts exact counts within the same time cap as a real Purge; falls back to `sys.partitions` estimates with `IsEstimated` flag (**D-149**, resolved Q-036).

### 9.6 Opt-in expensive features

Three opt-ins and one report parameter; no "enable all" override (**D-142**):

- Error log scrape (`xp_readerrorlog`)
- Buffer pool composition (`dm_os_buffer_descriptors`) — skipped >256 GB RAM
- CHECKDB last-known-good capture
- `@IncludeQueryPlans = 1` (report)

### 9.7 Testing posture

- CI cost-regression test: synthetic OLTP workload + `Collect` every minute; PR fails if throughput drops >2% or any collect >10 s (**D-143**).
- CI static-analysis suite: bounded reads, no forbidden DMVs, no stray `BEGIN TRAN`, parameterized `sp_executesql`, bounded `WAITFOR` (**D-144**).
- 24-hour CI soak test (out-of-band, not per-PR) (**D-145**).
- CI static-analysis tooling may be external (Python, PowerShell) and runs at build time only; charter governs the shipped artifact, not the build pipeline (**D-148**, resolved Q-035).

### 9.8 What we will not promise

Documented limits (**D-146**): zero overhead, never-blocks, repository never grows, correctness on every bizarre workload, no future regressions.

### 9.9 User-facing failure-mode catalog

The failure-mode catalog is user documentation, printed in Help-extended and README (**D-147**) — at 2 AM users need one table that says "this happened, this is what you do."

### 9.10 Retry policy

- No in-run retry on collector failure; the next scheduled snapshot is the retry (**D-150**, resolved Q-037). In-run retry would break the cooperative timeout contract.

---

## 10. Open Source Contribution Model

### 10.1 Repository layout

Structured as `src/` (one shipped file), `docs/`, `examples/`, `tests/`, `.github/`, `scripts/` (**D-151**). Tests and contributing are first-class, not hidden.

The shipped artifact is always a single file; if source is ever split for maintainability, `scripts/build-single-file.sh` concatenates at build time (**D-152**).

### 10.2 Coding style

Style codified (**D-153**): keywords UPPERCASE, identifiers in original case, four-space indent, 120-character target line length, schema-qualified names, no `SELECT *`, no commented-out code, no auto-formatter in CI (none handle dynamic SQL well).

Naming conventions (**D-154**): `FR_*` tables, `FR_v_*` views, `sp_SQLFlightRecorder_<Phase>_<Area>` helpers, `#fr_*` temps, `@has<Feature>` flags.

TODO/FIXME comments must reference a GitHub issue; untracked TODOs fail review (**D-155**).

### 10.3 Issue templates

Eight templates with blank issues disabled (**D-156**): bug report, false positive, false negative, new rule proposal, new collector proposal, version compatibility, performance regression, config.

### 10.4 Pull requests

PR template includes a charter-compliance checkbox list (**D-157**) covering forbidden DMVs, XML shredding, user-table reads, wording rules, etc.

Two-reviewer rule for the shipped artifact; one for docs/examples; maintainer required for safety-checklist items (**D-158**).

The "boring code" criterion is grounds to request changes (**D-159**); appealable to a second maintainer, but safety/compatibility/performance objections remain non-appealable (**D-186**, resolved Q-039).

### 10.5 Rule contribution format

Every new rule PR must include (**D-160**): metadata row in `FR_Rules` seed data, T-SQL logic, docs page from the template, positive AND negative tests, golden file updates, wording self-review.

Rule docs use a fixed template with sections including Severity rationale, Confidence rationale, EvidenceType rationale, False-positive risks, drill-down, suppress instructions (**D-161**).

Rule retirement requires a maintainer proposal, ≥30-day discussion, deprecation for at least two minor releases, retirement only in a major release; `RuleId` is reserved forever (**D-162**).

### 10.6 CODEOWNERS

- `CODEOWNERS` routes by area: core, rule pack, compatibility, docs (**D-163**).
- At v1.0 launch, all paths route to a single default owner; topic-specific teams created when trusted maintainers with that focus exist (**D-185**, resolved Q-038).
- That single owner is the repository owner account `@forward-thinkers-lab`, not an `@org/team`: the repository is owned by a GitHub user account, where team syntax cannot resolve. D-185's team routing is reactivated if the project moves under an organization (**D-191**, supersedes D-185's routing target). Because GitHub does not request a review from a PR's own author, `CODEOWNERS` alone does not enforce the two-reviewer rule (**D-158**) on owner-authored PRs.

### 10.7 Compatibility test process

- Tier 2 attestation issues auto-open per release candidate; missing for 3 minors → Unverified; missing for 6 → deprecation discussion (**D-164**, resolved Q-034).
- Compatibility matrix is auto-generated from Tier 1 CI + Tier 2 attestations; README badge links to it; hand-edits to `matrix.md` rejected (**D-165**, resolved Q-033).
- Tier 3 community reports via Discussions category (non-binding) (**D-166**).

### 10.8 Documentation

- Every page answers a user question in the order asked; design doc published in `docs/design/` (no secret docs) (**D-167**).
- README structured for 2 AM phone reading: one paragraph, badge, 30-second install, headline use case, links to ops docs (**D-168**).
- Some docs auto-generated (rules index, compat matrix, modes parameter tables); hand-edits to generated files rejected (**D-169**).

### 10.9 Examples

Examples are runnable, comprehensive, and CI-tested every PR via Tier 1 (**D-170**) so they cannot bit-rot.

### 10.10 Release strategy

- Semver with project-specific meanings (**D-171**): major = output contract break / version drop / rule retirement; minor = additive; patch = fixes.
- Release cadence (**D-172**): patches as needed; minor target quarterly (floor six-monthly); major every 18–24 months with ≥1 minor of deprecation warnings.
- Release process (**D-173**): RC branch → Tier 2 attestation issues auto-open → Tier 1 must be green → CHANGELOG entry mandatory → tag → release.yml builds artifact and regenerates matrix.
- Hotfix process (**D-174**): branch from latest tag, minimal fix + regression test, Tier 1 green, ship within 72-hour target, forward-merge.

### 10.11 Changelog

CHANGELOG follows Keep a Changelog 1.1.0 format plus tags affected `RuleId`s and Mode names (**D-175**) so runbook owners can grep.

### 10.12 Safety checklist

Safety review checklist is its own doc, pasted verbatim into PR reviews when needed (**D-176**) — single source for "did we stay safe?"

### 10.13 Governance

- Small core maintainer team + topic-specific maintainer teams; lazy consensus (7-day silence = approval); major decisions require 14-day Discussion (**D-177**).
- The charter is the project BDFL-equivalent; disputes are resolved by quoting it (**D-178**).
- No CLA/DCO at v1; MIT license; no paid support tier; no vendor badges; no bounty program; no popularity-vote prioritization (**D-179**).

### 10.14 Contributor environment

- Minimum local environment is SSMS or Azure Data Studio plus access to a SQL Server instance (Developer Edition or container); Docker and full CI parity recommended but not required for first-time contributors (**D-187**, resolved Q-040).

---

## 11. MVP Scope and Phased Roadmap

### 11.1 Phasing principle

- Each phase delivers a user-visible improvement, end to end.
- Each phase preserves everything the previous phase promised.
- Each phase has a hard "out of scope" list, written before development starts, and that list is binding.

### 11.2 v0.1 — Design Prototype

**Goals:** prove the architecture works end to end; earn the right to be called a "flight recorder"; establish contracts that v0.2–v1.0 will extend without breaking; demonstrate safety claims on a real production-class workload.

**Included:**
- All eight modes (`Help`, `Install`, `Uninstall`, `Collect`, `Report`, `Status`, `Configure`, `Purge`) plus internal `CollectDebug`.
- 7 collectors (instance, configuration, requests/blocking, waits, file stats, perf counters, run log).
- 6 rules (FR_R0001–FR_R0006) plus a skeletal FR_R0026.
- Repository tables: `FR_Config`, `FR_RunLog`, `FR_RunLogStep`, `FR_Snapshot`, `FR_InstanceSnapshot`, `FR_Configuration`, `FR_Request`, `FR_Wait`, `FR_FileStat`, `FR_PerfCounter`, `FR_QueryText`, `FR_Rules`.
- Full v1 capability probe; full 16-column Findings + 12-column Timeline + 14-key Markdown header contracts.
- All §9 safety primitives.
- Tier 1 CI on SQL Server 2019 and 2022 Linux.

**Excluded (binding):** Query Store anything; SQL Agent / backup / deadlock / AG / error log / buffer pool / schema-stats collectors; dedicated `FR_Tempdb` / `FR_Memory` / etc. tables; `FR_v_*` views; demo data; `@TimeZone`; Azure SQL DB/MI claims; Tier 2 attestation; multi-instance.

### 11.3 v0.2 — Historical Correlation

**Goals:** make timeline reconstruction useful; prove rule pack growth without breaking v0.1 runbooks; activate Tier 2 attestation; ship `FR_v_*` views.

**Included:** 6 collectors (tempdb, memory, Agent jobs, backup history, AG state, deadlocks); 8 rules (FR_R0007–FR_R0014); 6 new tables; new timeline events; 5 initial views; Tier 1 expansion to SQL Server 2017 Linux; Tier 2 attestation goes live; compatibility matrix badge in README.

**Excluded:** Query Store anything; plan cache top-N; error log scrape; buffer pool; schema/stats; HA-other; custom rule plugin model; `@TimeZone`; central reporting.

### 11.4 v0.3 — Query Store Integration

**Goals:** add Query Store as evidence source; ship plan-regression detection; add opt-in error log; add schema/stats collector.

**Included:** 4 collectors (Query Store top-N, plan cache headlines, opt-in error log, schema/stats activity); 6 rules (FR_R0015–FR_R0020); 4 new tables; QS drilldown emission in `MoreInfo`; demo data mode at the latest; Tier 1 adds SQL Server 2025 when available; per-DB capability probe.

**Excluded:** buffer pool; HA-other; rules FR_R0021–FR_R0025; QS-hints-aware rules; `@TimeZone`; QS plan-shape analysis.

### 11.5 v0.4 — Recommendation Engine Maturation

**Goals:** finish the rule pack (all 26); add last two collectors; ship `@TimeZone`; begin wiring `CriticalWaitTypes` honoring (rolls into v1.1); rule wording polish pass.

**Included:** 2 collectors (HA-other, opt-in buffer pool); 6 rules (FR_R0021–FR_R0026 full); 2 new tables; new timeline events `ConfigurationChange`, `LogReuseWaitChanged`; `@TimeZone` parameter; 3 more views; two-maintainer wording review on all 26 rules; cost-regression threshold tightened to 1.5%; soak test extended to 7 days.

**Excluded:** any new collectors beyond the two; any new rules beyond the six; XE sessions; index/missing-index DMVs; login/connection auditing; resource governor; QS wait stats as a dedicated rule; cross-instance; live DMV reads from Report; HTML/charts; notifications; "what changed since yesterday"; automatic baseline profiles; custom rule plugin; predicted-next-incident; new modes.

### 11.6 v1.0 — Production-Ready Release

**Goals:** no new features; hardening; documentation completeness; version-matrix breadth; operational confidence.

**Included:** bug fixes from v0.4 RC; static analysis extensions; documentation completeness (every mode, rule, collector, config key, capability flag); design doc published; runbook examples; full Tier 1 matrix green; Tier 2 attestation **not** a release gate — v1.0 may ship with Tier-2 targets *Unverified*, provided every compatibility claim separates Tier-1 verified from Tier-2 pending/unverified and no unattested target is described as verified (**D-192**, superseding this clause's original "at least 4 of 5 targets" requirement); release process dry-run twice; hotfix process rehearsed; wording lock; "1.0 is forever" promises (rule IDs, output columns, forward-only schema, no breaking changes in v1.x).

**Excluded (binding):** absolutely no new collectors, rules, modes, parameters, capability flags, or view-layer expansion; no behavior-changing PRs.

### 11.7 Permanently out of v1

Custom-rule plugin model; XE session creation; index usage / missing-index DMVs; login/connection auditing; Resource Governor; QS wait stats as dedicated rule; cross-instance / central repository; live DMV reads from Report; HTML/charts/GUI/dashboards; notification/alerting/webhook; "what changed since yesterday"; automatic baseline profiles; predicted-next-incident features.

### 11.8 What "production-ready" means

A short, honest contract: will not corrupt the repository, will not block user workload, will not silently lose data, will not lie in findings, will install/uninstall cleanly, will produce deterministic output, will run on Verified matrix targets, will be supported ≥18 months from v1.0 GA, will not break v1.x contracts.

What it explicitly does *not* promise: catching every incident type; perfect recommendations; arbitrary scale; replacing senior DBA judgment; zero false positives; never regressing.

---

## 12. Security and Threat Model (Q-041)

What this tool does and does not defend against, why its default behavior is safe, and what an operator must do to keep it safe. Scope is the shipped artifact and the local `FR_*` repository — **not** the SQL Server instance's own security posture. [`SECURITY.md`](../SECURITY.md) at the repo root carries the disclosure process; this section carries the analysis. It consolidates D-118 (permission tiers), D-119 (missing-permission reporting in three places), D-060 (error-log permission re-verification), D-179 (MIT license, no CLA/DCO at v1), and the §10.13 governance section.

### 12.1 Assets
| Asset | Sensitivity | Notes |
|---|---|---|
| `FR_QueryText` | **High** | May contain literal parameter values embedded in ad-hoc SQL (PII, secrets). |
| `FR_Request` / `FR_QueryStoreTopN` | Medium | Query hashes, session IDs, database IDs; no plan XML (never captured). |
| `FR_ErrorLog` (opt-in) | Medium–High | Error-log text may contain object names, paths, principal names. |
| Shipped artifact (`sp_SQLFlightRecorder.sql`) | Integrity-critical | A tampered artifact runs with the installer's permissions. |
| Caller permissions | — | `VIEW SERVER STATE` required; sysadmin discouraged (D-118). |

### 12.2 Threat actors and trust boundaries
| Actor | Capability | In-scope concern | Posture |
|---|---|---|---|
| Installer / operating DBA | Can install and run all modes; holds `VIEW SERVER STATE` | That the tool over-reaches or makes permanent changes | Least privilege: sysadmin is discouraged (D-118); no permanent server/security changes by default (D-003/D-021); opt-in for anything sensitive. |
| Non-DBA with read access to the repository DB | Can `SELECT` from `FR_*` | Exposure of query text / error-log text | The repository can hold sensitive strings; restrict `SELECT` on `FR_*` to a scoped role, not `public` (12.4). |
| Contributor / supply chain | Submits changes to the artifact | A malicious or unsafe change reaching users | Single-file, human-reviewable artifact (D-110/D-152); CI static analysis rejects forbidden DMVs / plan shredding (D-136/D-144); two-reviewer rule for the artifact (D-158). |
| Scheduler / automation identity | Runs `Collect` on a schedule | Excess privilege on the job account | Collect needs only `VIEW SERVER STATE`; the optional Agent job is opt-in (D-005). |

**Trust boundaries.** The tool trusts the SQL Server instance it runs in and the account that installs it. It does **not** attempt to defend against a compromised instance, OS, or cloud control-plane — those are the platform's remit and are out of scope. The security-relevant boundary is between the `FR_*` repository (which may hold sensitive data) and whoever can read that database.

### 12.3 Controls (threat → control → decision)
| Risk | Control | Decision |
|---|---|---|
| Plan-cache OOM / stalls from plan shredding | No plan APPLY DMVs; no plan-XML parsing; `@IncludeQueryPlans` is a reserved no-op | D-015/046/082/136 |
| Unbounded / lock-heavy reads | Every external SELECT bounded by `TOP(n) ORDER BY` or a small-DMV allow-list; forbidden-DMV list CI-enforced | D-136/137/144 |
| Blocking user workload | `READ UNCOMMITTED`, `LOCK_TIMEOUT`, `DEADLOCK_PRIORITY LOW`; diagnostic always loses | D-017/133/134 |
| Permanent server changes | Nothing permanent by default; error-log scrape, buffer pool, Agent job, CHECKDB capture all opt-in | D-003/005/020/051/060 |
| Sensitive data at rest | Bounded fields, no `NVARCHAR(MAX)` on hot rows; retention configurable; full `Uninstall` | D-040/183 |
| Unsafe recommendations | Wording rules forbid `KILL`/force-plan/NOLOCK/shrink; drill-down queries are read-only | D-076/086 |

### 12.4 Data-sensitivity handling and recommendations
- Treat `FR_QueryText` and `FR_ErrorLog` as potentially sensitive.
- Recommended: a dedicated `FR_reader` role; do not grant repository `SELECT` to `public`; consider a shorter `SnapshotRetentionDays` where query text is sensitive; `Uninstall` removes everything (D-183).

### 12.5 Residual risks
Human-enforced wording discipline (D-076/D-189) and the modeled-not-measured storage/latency envelopes (D-188) are tracked risks, not guarantees.

### 12.6 Reporting a vulnerability
See [`SECURITY.md`](../SECURITY.md).

---

## 13. Appendices (Q-042)

### A. Glossary
| Term | Meaning |
|---|---|
| Finding | A prioritized observation with Severity/Confidence/EvidenceType (Findings result set). |
| Timeline | Chronological events for the window (Timeline result set). |
| Coverage finding | A finding about data completeness (gaps, skipped collectors), not an incident. |
| Observed vs Inferred | Evidence type: directly captured vs. reasoned from a signal. |
| Tier 1 / 2 / 3 | Automated CI / manual attestation / community reports (D-120/121/166). |
| Headline vs contributor rule | A rule that folds others' findings into its `MoreInfo` vs. the folded rule (§7.13). |
| Capability snapshot | The closed key set describing the engine, persisted per run (D-127). |

### B. References
- Microsoft Learn: the DMVs each collector reads (`sys.dm_os_wait_stats`, `sys.dm_io_virtual_file_stats`, `sys.dm_exec_requests`, Query Store views).
- Community: Paul Randal on wait statistics; Query Store guidance.
- Keep a Changelog 1.1.0 (CHANGELOG format, D-175).

### C. Master Charter
The project charter is the authoritative scope statement; it is stated in [§1 (Project Charter and Scope)](#1-project-charter-and-scope) and echoed in the `Help` mode output, so the design doc is self-contained without a duplicate reprint here.

### D. Failure-mode catalog
The canonical failure-mode catalog is user documentation and lives in [`docs/operations/troubleshooting.md`](operations/troubleshooting.md) (D-147); it is a living document, so it is referenced here rather than reprinted (which would create a sync burden).

---

## Appendix A — Resolved questions cross-reference

| Question | Resolved by | Section |
|---|---|---|
| Q-001 | D-065 | §6.3 |
| Q-002 | D-180 | §1.6 |
| Q-003 | D-026 | §4.5 |
| Q-004 | D-027 | §4.5 |
| Q-005 | D-181 | §5.11 |
| Q-006 | D-066 | §6.3 |
| Q-007 | D-182 | §11.4 (v0.3) |
| Q-008 (storage) | D-028 | §4.5 |
| Q-010 | D-079 | §6.8 |
| Q-011 | D-183 | §2.1 |
| Q-012 (storage) | D-029 | §3.7 |
| Q-013 | D-184 | §11.3 (v0.2) |
| Q-016 | D-057 | §4.8 |
| Q-017 | D-058 | §5.1 |
| Q-018 | D-059 | §5.3 |
| Q-019 | D-060 | §5.8 |
| Q-020 | D-061 | §3.4 |
| Q-021 | D-083 | §6.4 |
| Q-022 | D-084 | §6.4 |
| Q-023 | D-085 | §6.8 |
| Q-024 | D-086 | §6.10 |
| Q-025 | D-087 | §6.9 |
| Q-026 | D-103 | §6.9 |
| Q-027 | D-104 | §6.3 |
| Q-028 | D-105 | §7.4 |
| Q-029 | D-106 | §7.7 |
| Q-030 | D-107 | §7.8 |
| Q-031 | D-127 | §8.3 |
| Q-032 | D-128 | §8.2 |
| Q-033 | D-165 | §10.7 |
| Q-034 | D-164 | §10.7 |
| Q-035 | D-148 | §9.7 |
| Q-036 | D-149 | §9.5 |
| Q-037 | D-150 | §9.10 |
| Q-038 | D-185 | §10.6 |
| Q-039 | D-186 | §10.4 |
| Q-040 | D-187 | §10.14 |

(Question numbers Q-009, Q-014, Q-015 were used during design as placeholders that were absorbed into larger discussions before formal resolution; no orphan questions remain.)

---

## Unresolved Conflicts

None identified during the design lock review or earlier reconciliation. All conflicts encountered during the design conversation were resolved at the time.

If any conflict surfaces during implementation, it should be added here rather than resolved silently.

---

*End of consolidated design document. The design lock review (`docs/design-lock-review.md`) approved this document for v0.1 implementation planning. Sections 12 and 13 are deferred to v1.0 and are not blockers for v0.1.*
