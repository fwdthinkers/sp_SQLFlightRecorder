# Documentation index — sp_SQLFlightRecorder

This is the map of the project's documentation and the coverage checklist for
the v1.0.0 documentation-completeness gate (§11.6). Each row names where a topic
is documented; **Status** is `present`, `sample` (a v1.0.0-rc structure sample
establishing the final template — the rest are produced from it), or `planned`
(authored in v1.0.0-rc Groups B/C — see `docs/implementation-plan-v1.0.0-rc.md`).

> **Structure samples (v1.0.0-rc):** the reusable templates are in place — a
> rule page ([rules/FR_R0003.md](rules/FR_R0003.md) from
> [rules/_template.md](rules/_template.md)), a mode page
> ([modes/report.md](modes/report.md)), the failure-mode catalog
> ([operations/troubleshooting.md](operations/troubleshooting.md)), the
> security/threat-model draft
> ([security-threat-model-draft.md](security-threat-model-draft.md)), the
> security/support/governance skeletons (SECURITY/SUPPORT/CONTRIBUTING/
> CODE_OF_CONDUCT/CODEOWNERS), and two issue templates (bug, false-positive).

## Start here
- [README.md](../README.md) — what the tool is, 30-second install, headline use.
- [docs/user-guide.md](user-guide.md) — full operational guide.
- [docs/design.md](design.md) — consolidated design (§1–§11; §12/§13 planned).
- [docs/decisions.md](decisions.md) — decision log D-001…D-190.
- [CHANGELOG.md](../CHANGELOG.md) — release history (Keep a Changelog, D-175).

## Modes (12) → `docs/modes/<mode>.md`
| Mode | Page | Status |
|---|---|---|
| Help | [modes/help.md](modes/help.md) | planned |
| About / Version | [modes/about.md](modes/about.md) | planned |
| Install | [modes/install.md](modes/install.md) | present (refresh) |
| Uninstall | [modes/uninstall.md](modes/uninstall.md) | present (refresh) |
| Status | [modes/status.md](modes/status.md) | present (refresh) |
| Collect | [modes/collect.md](modes/collect.md) | planned |
| CollectDebug | [modes/collectdebug.md](modes/collectdebug.md) | planned |
| Report | [modes/report.md](modes/report.md) | planned |
| Configure | [modes/configure.md](modes/configure.md) | planned |
| Purge | [modes/purge.md](modes/purge.md) | planned |
| CollectAndReport | [modes/collectandreport.md](modes/collectandreport.md) | planned |
| InstallDemoData | [modes/installdemodata.md](modes/installdemodata.md) | planned |

## Rules (31) → `docs/rules/<RuleId>.md` (template: `docs/rules/_template.md`, D-161)
**Active (26):** FR_R0001 ActiveBlockingChain, FR_R0002 LongRunningOpenTransaction,
FR_R0003 TopWaitTypeSpike, FR_R0004 FileIoLatencySpike, FR_R0005 MemoryGrantsPending,
FR_R0006 ServerRestartDuringWindow, FR_R0007 BlockingStorm,
FR_R0008 TempdbVersionStoreGrowth, FR_R0009 TempdbFileImbalanceOrPressure,
FR_R0010 FailedSqlAgentJobNearIncident, FR_R0011 MaintenanceJobOverlap,
FR_R0012 BackupOverlapWithIncident, FR_R0013 DeadlocksObserved,
FR_R0014 AlwaysOnRoleOrStateChange, FR_R0015 QueryPlanRegression,
FR_R0016 TopCpuConsumerInWindow, FR_R0017 QueryStoreDisabledOnUserDbs,
FR_R0018 FailedPlanForcing, FR_R0019 QueryStoreNearingCapacity,
FR_R0020 HighCompilationRate, FR_R0021 ConfigurationChangeInWindow,
FR_R0022 LogReuseWaitElevated, FR_R0023 ThreadpoolWaitsObserved,
FR_R0024 ResourceSemaphoreWaits, FR_R0025 RecentCheckDbOrBackupAge,
FR_R0026 CoverageAndCapabilitySummary.
**Disabled (5), IDs reserved forever (D-089/D-090):** FR_R0030 PlanMissingIndex,
FR_R0031 PlanImplicitConversion, FR_R0032 PlanSpillToTempDb, FR_R0033 PlanWarnings,
FR_R0034 PlanParallelism — no compliant implementation (plan-XML shredding is
forbidden by D-015/D-046/D-082/D-136).
Index page: `docs/rules/README.md` (planned, D-169). Status: **planned**.

## Collectors → documented in [modes/collect.md](modes/collect.md)
Instance, Configuration, Requests, QueryText, Waits, FileStats, PerfCounters,
Tempdb, Memory, AgentJobs, BackupHistory, AlwaysOnState, Deadlocks,
PlanCacheSummary, QueryStore, QueryStoreCapacity, SchemaActivity, ErrorLog
(opt-in), AdvancedHaState, BufferPool (opt-in). QueryPlans is a reserved
Skipped step (plan capture disabled by design). Status: **planned**.

## Configuration → `docs/configuration.md`
All `FR_Config` keys (37) incl. the v0.4.2 tunables `LongOpenTxnSeconds`,
`FileIoLatencyWarnMs`; each key's purpose and which rule it drives. Status:
**planned**.

## Capability snapshot → `docs/capability-snapshot.md`
Closed key set (D-127), incl. `PlanAnalysisSupport=0`. Status: **planned**.

## Compatibility → `docs/compatibility/matrix.md` (D-165)
Tier-1 (automated: 2017/2019/2022/2025 Linux) + Tier-2 (attested:
2012/2014/2016 Windows, Azure SQL MI, Azure SQL DB) posture; README badge links
here. Status: **planned**.

## Operations
- [operations/troubleshooting.md](operations/troubleshooting.md) — failure-mode
  catalog (D-147). Status: **planned**.
- [compatibility/support-policy.md](compatibility/support-policy.md) — "1.0 is
  forever" promises (§11.8). Status: **planned**.

## Security & governance
- [SECURITY.md](../SECURITY.md) + `docs/design.md` §12 threat model (Q-041).
  Status: **planned**.
- `docs/design.md` §13 appendices (Q-042). Status: **planned**.
- [CONTRIBUTING.md](../CONTRIBUTING.md), [SUPPORT.md](../SUPPORT.md),
  [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md); `docs/contributing/`
  (overview, coding-style D-153, safety-checklist D-176). Status: **planned**.

## Tests
- [tests/rules/](../tests/rules/) — rule fixtures + demo golden (D-160, D-122).
- [tests/static-analysis/](../tests/static-analysis/) — linter + fixtures (D-144).
- [tests/sp_SQLFlightRecorderManualScenarios.sql](../tests/sp_SQLFlightRecorderManualScenarios.sql)
  — manual scenarios.

---
*The `planned` rows are the v1.0.0 documentation-completeness worklist. A CI
doc-coverage gate (Group D) will assert a page exists for every mode, rule, and
config key before v1.0.0.*
