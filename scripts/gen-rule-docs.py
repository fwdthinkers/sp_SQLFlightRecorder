#!/usr/bin/env python3
# =============================================================================
# scripts/gen-rule-docs.py
# -----------------------------------------------------------------------------
# Generates the per-rule documentation pages under docs/rules/ from the
# nine-section template (D-161). Build-pipeline tooling only (D-148); D-169
# sanctions generated docs. Metadata mirrors the FR_Rules seed in the artifact.
#
# FR_R0003.md is the hand-authored flagship example and is NOT overwritten.
#
# Usage:  python scripts/gen-rule-docs.py            # write pages + index
#         python scripts/gen-rule-docs.py --check    # fail if out of date
# =============================================================================
from __future__ import annotations
import sys
from pathlib import Path

RULES_DIR = Path(__file__).resolve().parents[1] / "docs" / "rules"
# Page filenames use the short number form (docs/rules/FR_R0003.md), matching the
# hand-authored flagship. That flagship is not overwritten.
KEEP_HANDWRITTEN = {"0003"}   # by 4-digit rule number

# (RuleId, Category, Severity, Confidence, EvidenceType, Lifecycle, IntroducedIn)
META = [
 ("FR_R0001_ActiveBlockingChain","Blocking","High","High","Observed","Active","0.1"),
 ("FR_R0002_LongRunningOpenTransaction","Blocking","Medium","High","Observed","Active","0.1"),
 ("FR_R0003_TopWaitTypeSpike","Waits","Medium","Medium","Inferred","Active","0.1"),
 ("FR_R0004_FileIoLatencySpike","IO","Medium","Medium","Inferred","Active","0.1"),
 ("FR_R0005_MemoryGrantsPending","Memory","High","High","Observed","Active","0.1"),
 ("FR_R0006_ServerRestartDuringWindow","Configuration","Critical","High","Observed","Active","0.1"),
 ("FR_R0007_BlockingStorm","Blocking","Critical","High","Observed","Active","0.2"),
 ("FR_R0008_TempdbVersionStoreGrowth","Tempdb","Medium","High","Observed","Active","0.2"),
 ("FR_R0009_TempdbFileImbalanceOrPressure","Tempdb","Medium","Medium","Inferred","Active","0.2"),
 ("FR_R0010_FailedSqlAgentJobNearIncident","Maintenance","High","High","Observed","Active","0.2"),
 ("FR_R0011_MaintenanceJobOverlap","Maintenance","Medium","Medium","Inferred","Active","0.2"),
 ("FR_R0012_BackupOverlapWithIncident","Maintenance","Medium","High","Observed","Active","0.2"),
 ("FR_R0013_DeadlocksObserved","Blocking","High","High","Observed","Active","0.2"),
 ("FR_R0014_AlwaysOnRoleOrStateChange","HA","Critical","High","Observed","Active","0.2"),
 ("FR_R0015_QueryPlanRegression","QueryStore","High","Medium","Inferred","Active","0.3"),
 ("FR_R0016_TopCpuConsumerInWindow","QueryStore","Medium","High","Observed","Active","0.3"),
 ("FR_R0017_QueryStoreDisabledOnUserDbs","Coverage","Informational","High","Observed","Active","0.3"),
 ("FR_R0018_FailedPlanForcing","QueryStore","Medium","High","Observed","Active","0.3"),
 ("FR_R0019_QueryStoreNearingCapacity","QueryStore","Medium","High","Observed","Active","0.3"),
 ("FR_R0020_HighCompilationRate","PlanCache","Medium","Medium","Inferred","Active","0.3"),
 ("FR_R0021_ConfigurationChangeInWindow","Configuration","Medium","High","Observed","Active","0.4"),
 ("FR_R0022_LogReuseWaitElevated","IO","High","High","Observed","Active","0.4"),
 ("FR_R0023_ThreadpoolWaitsObserved","Waits","Critical","High","Observed","Active","0.4"),
 ("FR_R0024_ResourceSemaphoreWaits","Memory","High","High","Observed","Active","0.4"),
 ("FR_R0025_RecentCheckDbOrBackupAge","Maintenance","Medium","High","Observed","Active","0.4"),
 ("FR_R0026_CoverageAndCapabilitySummary","Coverage","Informational","High","Observed","Active","0.4"),
 ("FR_R0030_PlanMissingIndex","QueryPlan","Medium","Medium","Inferred","Disabled","0.2"),
 ("FR_R0031_PlanImplicitConversion","QueryPlan","Low","Medium","Inferred","Disabled","0.2"),
 ("FR_R0032_PlanSpillToTempDb","QueryPlan","Medium","Medium","Inferred","Disabled","0.2"),
 ("FR_R0033_PlanWarnings","QueryPlan","Low","Medium","Inferred","Disabled","0.2"),
 ("FR_R0034_PlanParallelism","QueryPlan","Low","Low","Inferred","Disabled","0.2"),
]

# Per-rule authored content. Fields: detects, source, anchor, computed, sev,
# conf, ev, fp, fn, drill, config, example.
C = {
 "FR_R0001_ActiveBlockingChain": dict(
  detects="A session at the head of a blocking chain — it blocks others but is not itself blocked.",
  source="`FR_Request`", anchor="lead-blocker `SessionId` (D-074)",
  computed="For each window snapshot, a lead blocker is a `SessionId` that appears as another row's `BlockingSessionId` and is not itself blocked. One finding per distinct lead blocker.",
  sev="High — an active blocking chain is a live, observed contention problem.",
  conf="High — directly observed from `BlockingSessionId`, not inferred.",
  ev="Observed.",
  fp="A brief, self-resolving block captured in one snapshot still reports.",
  fn="Sub-minute chains between snapshots are missed; only directly-blocking heads are named.",
  drill="Inspect the lead blocker's transaction and what it holds; correlate with FR_R0002/FR_R0007. Never kill blindly.",
  config="None.",
  example="Seed FR_Request with sessions blocked by a common head (see tests/rules/)."),
 "FR_R0002_LongRunningOpenTransaction": dict(
  detects="A session holding an open transaction across multiple snapshots for a long interval.",
  source="`FR_Request`", anchor="`SessionId` (D-074)",
  computed="No elapsed column is stored, so duration is inferred from persistence: `OpenTransactionCount > 0` in >= 2 snapshots (from `@DeltaStartUtc`) spanning >= `LongOpenTxnSeconds`.",
  sev="Medium — an open transaction is a risk (log growth, blocking) but not itself an incident.",
  conf="High — the open-transaction state is directly observed.",
  ev="Observed.",
  fp="A legitimately long batch (ETL) reports; the span is persistence-based, not true elapsed time.",
  fn="A long transaction seen in only one snapshot does not fire; anchored post-restart to avoid session-id reuse.",
  drill="Identify the session's transaction and why it stays open; check log reuse (FR_R0022).",
  config="`LongOpenTxnSeconds` (default 60).",
  example="Seed a session with open txn in two snapshots >60 s apart."),
 "FR_R0004_FileIoLatencySpike": dict(
  detects="A database file whose average read+write stall per I/O is elevated over its recent baseline.",
  source="`FR_FileStat`, `#fr_baseline`", anchor="db+file (D-074)",
  computed="Window delta latency per (db, file) = change in IO stall / change in ops from `@DeltaStartUtc` (D-007, restart-safe). Fires above max(2x baseline, `FileIoLatencyWarnMs`); escalates High above max(4x baseline, 4x floor).",
  sev="Medium, escalating High on large magnitude (by threshold, not row count; D-069 preserved).",
  conf="Medium, forced Low with <5 baseline samples (D-092).",
  ev="Inferred — latency is consistent with storage pressure but not attributed.",
  fp="A backup or bulk load can raise latency benignly; short windows amplify noise.",
  fn="A counter reset (restart) is excluded; sub-minute spikes are invisible.",
  drill="Correlate with PAGEIOLATCH waits (FR_R0003) and backup overlap (FR_R0012); check storage.",
  config="`FileIoLatencyWarnMs` (default 20).",
  example="Seed FR_FileStat with a rising IoStall/ops ratio across two snapshots."),
 "FR_R0005_MemoryGrantsPending": dict(
  detects="A request waiting for a query memory grant (requested but not yet granted).",
  source="`FR_Request` (grant columns), `FR_Memory` (corroboration)", anchor="`SessionId` (D-074)",
  computed="A row with `RequestedMemoryKb > 0` and `GrantedMemoryKb` NULL/0 is a pending grant. `FR_Memory.MemoryGrantsPending` is included as corroboration.",
  sev="High — pending grants mean queries are stalled on memory.",
  conf="High — the pending-grant state is directly observed.",
  ev="Observed.",
  fp="A momentary grant wait captured in one snapshot reports.",
  fn="Grants that resolve between snapshots are missed.",
  drill="Review large-grant queries and MAX_GRANT_PERCENT; correlate with RESOURCE_SEMAPHORE (FR_R0024). Folds into FR_R0024 (§7.13).",
  config="None.",
  example="Seed a request with RequestedMemoryKb>0 and GrantedMemoryKb NULL."),
 "FR_R0006_ServerRestartDuringWindow": dict(
  detects="A SQL Server restart inside the report window.",
  source="`FR_InstanceSnapshot.SqlStartTimeUtc`, `FR_ErrorLog` (corroboration)", anchor="window (D-074)",
  computed="The captured start time changing within the window means a restart; the window is split at the boundary and delta rules re-anchor at the first post-restart snapshot (D-064).",
  sev="Critical (informational) — cross-restart cumulative deltas are meaningless; the reader must know.",
  conf="High — the start-time change is directly observed.",
  ev="Observed.",
  fp="A planned restart still reports (correctly — it is context, not blame).",
  fn="If instance snapshots are missing, the error-log corroboration path is the fallback.",
  drill="Confirm whether the restart was expected; analyze pre/post segments separately.",
  config="None.",
  example="Seed two FR_InstanceSnapshot rows with different SqlStartTimeUtc."),
 "FR_R0007_BlockingStorm": dict(
  detects="Many sessions blocked within a single snapshot — a blocking storm.",
  source="`FR_Request`", anchor="window (D-074); folds FR_R0001/FR_R0002 (§7.13)",
  computed="Distinct blocked sessions per snapshot; fires when the peak reaches `BlockingStormSessionThreshold`.",
  sev="Critical — widespread blocking is a severe live incident.",
  conf="High — directly observed.", ev="Observed.",
  fp="A momentary fan-out on one snapshot can trip the threshold.",
  fn="A storm spread across snapshots (not concentrated) may not peak.",
  drill="Find the lead blocker; the folded FR_R0001/FR_R0002 contributors are listed in MoreInfo.",
  config="`BlockingStormSessionThreshold` (default 5).",
  example="Seed >=5 sessions blocked by one head in a single snapshot."),
 "FR_R0008_TempdbVersionStoreGrowth": dict(
  detects="The tempdb version store grew during the window.",
  source="`FR_Tempdb`", anchor="window (D-074)",
  computed="Compares min/max `VersionStoreKb` across the window; escalates when max >= `TempdbVersionStoreWarnKb`.",
  sev="Medium, escalating on size.", conf="High — observed from tempdb space usage.", ev="Observed.",
  fp="Normal snapshot-isolation workloads grow the version store benignly.",
  fn="Growth that fully drains between snapshots is missed.",
  drill="Find long-running / open transactions holding versions (FR_R0002); check snapshot isolation usage.",
  config="`TempdbVersionStoreWarnKb` (default ~5 GB).",
  example="Seed FR_Tempdb with rising VersionStoreKb."),
 "FR_R0009_TempdbFileImbalanceOrPressure": dict(
  detects="Tempdb data files differ substantially in size (allocation-contention risk).",
  source="`FR_Tempdb`", anchor="window (D-074)",
  computed="Flags when max data-file size exceeds 2x the min and there is more than one file.",
  sev="Medium.", conf="Medium — imbalance is a risk indicator, not a confirmed problem.", ev="Inferred.",
  fp="Auto-grow transients can momentarily unbalance files.",
  fn="Equal-sized but insufficient files are not flagged by this rule.",
  drill="Confirm tempdb files are equally sized and pre-grown; check allocation waits.",
  config="None.",
  example="Seed FR_Tempdb with min/max data-file sizes differing >2x."),
 "FR_R0010_FailedSqlAgentJobNearIncident": dict(
  detects="A SQL Agent job that failed near the incident window.",
  source="`FR_AgentJob`", anchor="db/job (D-074)",
  computed="Failed job outcomes from 15 minutes before `@StartTime` through `@EndTime` (D-095).",
  sev="High — a failed job near an incident often explains it.", conf="High — observed from msdb history.", ev="Observed.",
  fp="An unrelated failed job in the window is correlated by time, not causation.",
  fn="Jobs outside the 15-minute lead are not considered.",
  drill="Review the job's history and step output; correlate its timing with the symptoms.",
  config="None.",
  example="Seed FR_AgentJob with RunOutcome='Failed' near the window."),
 "FR_R0011_MaintenanceJobOverlap": dict(
  detects="A maintenance job that ran during or across the incident window.",
  source="`FR_AgentJob`", anchor="job (D-074)",
  computed="Jobs whose name matches `MaintenanceJobNamePatterns` and whose run overlapped the window.",
  sev="Medium.", conf="Medium — overlap is inferred correlation.", ev="Inferred.",
  fp="Maintenance overlapping an unrelated incident is coincidental.",
  fn="Custom job names not in the pattern list are missed.",
  drill="Confirm whether the maintenance activity coincided with the symptoms.",
  config="`MaintenanceJobNamePatterns`.",
  example="Seed FR_AgentJob with a matching maintenance job overlapping the window."),
 "FR_R0012_BackupOverlapWithIncident": dict(
  detects="A non-log backup that overlapped the incident window.",
  source="`FR_BackupHistory`", anchor="db (D-074)",
  computed="FULL/DIFF backups overlapping the window; log backups are excluded (D-096).",
  sev="Medium.", conf="High — observed from backupset history.", ev="Observed.",
  fp="Backup I/O overlapping an unrelated incident is coincidental.",
  fn="Log backups are excluded by design; very short backups may fall between snapshots.",
  drill="Correlate backup I/O with the symptoms; consider scheduling.",
  config="None.",
  example="Seed FR_BackupHistory with a FULL backup overlapping the window."),
 "FR_R0013_DeadlocksObserved": dict(
  detects="One or more unique deadlock graphs captured during the window.",
  source="`FR_Deadlock`", anchor="graph hash (D-074)",
  computed="Distinct deadlock graphs (deduped by hash, D-053) with a deadlock time in the window.",
  sev="High — deadlocks are real, actionable failures.", conf="High — observed graphs.", ev="Observed.",
  fp="A single benign deadlock still reports (correctly).",
  fn="Deadlocks not captured by system_health are not seen.",
  drill="Review the stored graph and participating queries; NOLOCK is not a remedy.",
  config="None.",
  example="Seed FR_Deadlock with a graph in the window."),
 "FR_R0014_AlwaysOnRoleOrStateChange": dict(
  detects="An Always On replica changed role or synchronization health during the window.",
  source="`FR_AlwaysOnState`", anchor="ag/replica (D-074)",
  computed="Flags when a replica shows more than one distinct role or health state across the window.",
  sev="Critical — a role/health change is a major HA event.", conf="High — observed.", ev="Observed.",
  fp="A brief, expected transition (planned failover) reports.",
  fn="Changes fully contained between snapshots are missed.",
  drill="Review the AG dashboard and cluster log for the timeframe.",
  config="None.",
  example="Seed FR_AlwaysOnState with a role/health change across snapshots."),
 "FR_R0015_QueryPlanRegression": dict(
  detects="A query whose recent plan is materially slower than a prior plan (Query Store).",
  source="`FR_QueryStoreTopN`", anchor="db+query (D-074, AnchorKey)",
  computed="Latest captured plan vs best prior plan for the same query; fires above `QueryStoreRegressionFactor`. On SQL 2016 Confidence is forced down (runtime stats only, D-107).",
  sev="High — a regression directly degrades a query.", conf="Medium (Low on 2016).", ev="Inferred.",
  fp="Parameter-sensitive plans can look like regressions; short samples mislead.",
  fn="Queries without a prior plan in the window are not compared. Folds FR_R0016 for the same query (§7.13).",
  drill="Review the query in Query Store; do not force a plan automatically.",
  config="`QueryStoreRegressionFactor`.",
  example="Seed FR_QueryStoreTopN with a regressed plan for a query (see tests/rules/)."),
 "FR_R0016_TopCpuConsumerInWindow": dict(
  detects="The queries that accumulated the most CPU in the window (Query Store).",
  source="`FR_QueryStoreTopN`", anchor="db+query (D-074, AnchorKey)",
  computed="Top-5 by total CPU across the window; duration/reads carried as supplementary evidence.",
  sev="Medium.", conf="High — aggregated from observed QS stats.", ev="Observed.",
  fp="A heavy but legitimate query is still 'top CPU'.",
  fn="Only the top 5 are reported; folded into FR_R0015 when the same query regressed.",
  drill="Review the query for tuning; confirm it is representative of the incident.",
  config="None.",
  example="Seed FR_QueryStoreTopN with several queries of differing total CPU."),
 "FR_R0017_QueryStoreDisabledOnUserDbs": dict(
  detects="Query Store found no QS-enabled user database (coverage gap).",
  source="`FR_RunLogStep` (QueryStore step Skipped)", anchor="window (Coverage, dedup-exempt)",
  computed="The most recent QueryStore collector step reported Skipped in the window.",
  sev="Informational (coverage).", conf="High — repository signal.", ev="Observed.",
  fp="Intentionally QS-disabled shops see this every report (by design).",
  fn="n/a — it reports absence.",
  drill="Consider enabling Query Store on key databases for future plan-level evidence.",
  config="`CollectQueryStore`.",
  example="Report with no QS-enabled DB; the QueryStore step is Skipped."),
 "FR_R0018_FailedPlanForcing": dict(
  detects="A forced plan reporting force failures (Query Store).",
  source="`FR_QueryStoreTopN`", anchor="db+query+plan (D-074, AnchorKey)",
  computed="Rows with `ForceFailureCount > 0`, deduped by (db, query, plan).",
  sev="Medium.", conf="High — observed from QS forced-plan columns.", ev="Observed.",
  fp="A transient force failure that later succeeds still reports.",
  fn="Only queries in the captured top-N are seen.",
  drill="Review why the forced plan fails and whether forcing is still intended; do not force/unforce automatically.",
  config="None.",
  example="Seed FR_QueryStoreTopN with IsForcedPlan=1 and ForceFailureCount>0."),
 "FR_R0019_QueryStoreNearingCapacity": dict(
  detects="A database's Query Store approached its configured maximum size.",
  source="`FR_RunLogStep` (QueryStoreCapacity step)", anchor="window (D-074)",
  computed="Reads the collect-time capacity percentage (stored in the step's RowsCollected); fires at `QueryStoreCapacityWarnPercent`.",
  sev="Medium.", conf="High — observed from the capacity probe.", ev="Observed.",
  fp="A DB near capacity but healthy still reports (a real warning).",
  fn="DBs whose capacity was not probed are not seen.",
  drill="Review Query Store retention and max-size settings.",
  config="`QueryStoreCapacityWarnPercent`.",
  example="Set the QueryStoreCapacity step RowsCollected above the threshold."),
 "FR_R0020_HighCompilationRate": dict(
  detects="Sustained high SQL compilation pressure.",
  source="`FR_PlanCacheSummary`", anchor="window (D-074)",
  computed="Rate derived from raw cumulative compilation counters via window delta from `@DeltaStartUtc` (D-007); fires above `CompilationsPerSecWarn`.",
  sev="Medium.", conf="Medium — a rate signal, not a confirmed cause.", ev="Inferred.",
  fp="A legitimate ad-hoc-heavy workload shows high compilation.",
  fn="Counter reset on restart is excluded; brief spikes are averaged out.",
  drill="Review ad-hoc workload and parameterization; do not clear the plan cache reflexively.",
  config="`CompilationsPerSecWarn`.",
  example="Seed FR_PlanCacheSummary with rising compilation counters."),
 "FR_R0021_ConfigurationChangeInWindow": dict(
  detects="A tracked server/database configuration value changed during the window.",
  source="`FR_Configuration`", anchor="config name (D-074)",
  computed="`LAG` over captured configuration values; a change in value across snapshots fires.",
  sev="Medium.", conf="High — observed diff.", ev="Observed.",
  fp="An intended change reports (correctly — it is context).",
  fn="Changes that revert between snapshots may be missed.",
  drill="Correlate the change time with the incident; confirm intent.",
  config="None.",
  example="Seed FR_Configuration with a value that changes across snapshots."),
 "FR_R0022_LogReuseWaitElevated": dict(
  detects="Transaction-log growth/reuse pressure elevated over baseline.",
  source="`FR_PerfCounter` (Log Growths), `#fr_baseline`", anchor="counter (D-074)",
  computed="Window max of 'Log Growths' vs the recent baseline (D-092); downgrades Confidence with <5 samples.",
  sev="High — log pressure can stall writes.", conf="High (Low with insufficient baseline).", ev="Observed.",
  fp="A one-off growth from a large transaction can trip it.",
  fn="Requires the perf counter to be captured; sub-minute events averaged.",
  drill="Review log backup cadence and long transactions (FR_R0002). Shrinking the log is not a fix.",
  config="None (baseline via `BaselineLookbackHours`).",
  example="Seed FR_PerfCounter 'Log Growths' rising above baseline."),
 "FR_R0023_ThreadpoolWaitsObserved": dict(
  detects="THREADPOOL waits recorded in the window (worker-thread starvation).",
  source="`FR_Wait`", anchor="window (D-074)",
  computed="Any THREADPOOL wait with positive wait time in the window fires.",
  sev="Critical — worker starvation can freeze the instance.", conf="High — observed.", ev="Observed.",
  fp="A brief THREADPOOL blip under momentary load reports.",
  fn="Sub-minute starvation between snapshots is missed.",
  drill="Investigate blocking chains and session counts; review max worker threads only after confirming sustained starvation.",
  config="None (wait ignore list does not exclude THREADPOOL).",
  example="Seed FR_Wait with a THREADPOOL wait."),
 "FR_R0024_ResourceSemaphoreWaits": dict(
  detects="RESOURCE_SEMAPHORE waits in the window (query memory-grant pressure).",
  source="`FR_Wait`", anchor="window (D-074); folds FR_R0005 (§7.13)",
  computed="Any RESOURCE_SEMAPHORE wait with positive wait time fires.",
  sev="High — queries are queuing for memory grants.", conf="High — observed.", ev="Observed.",
  fp="A momentary grant-wait under a big query reports.",
  fn="Sub-minute waits between snapshots are missed.",
  drill="Review large memory-grant queries and MAX_GRANT_PERCENT; the folded FR_R0005 sessions are in MoreInfo.",
  config="None.",
  example="Seed FR_Wait with a RESOURCE_SEMAPHORE wait."),
 "FR_R0025_RecentCheckDbOrBackupAge": dict(
  detects="A database whose last FULL backup (or CHECKDB) is older than the configured threshold.",
  source="`FR_BackupHistory`", anchor="db (D-074)",
  computed="Latest FULL backup age vs `BackupWarnDays`; CHECKDB age vs `CheckDbWarnDays` where a signal exists.",
  sev="Medium (High for CHECKDB age).", conf="High — observed from backup history.", ev="Observed.",
  fp="Age is limited by repository retention (a very old backup may show '>retention').",
  fn="Databases with no captured backup rows cannot be aged precisely.",
  drill="Confirm the backup schedule and chain; consider a FULL backup only after validating RPO.",
  config="`BackupWarnDays`, `CheckDbWarnDays`.",
  example="Seed FR_BackupHistory with a stale last-FULL date."),
 "FR_R0026_CoverageAndCapabilitySummary": dict(
  detects="Always-emitted coverage and capability summary: snapshot count, skipped collectors, suppressed rules, capability flags. Also carries graded gap findings (D-066).",
  source="`FR_Snapshot`, `FR_RunLogStep`, `FR_Config`", anchor="Coverage (dedup-exempt, D-075)",
  computed="Aggregates the window's snapshot count, skipped/partial collector steps, suppressed rules, and capability posture. Cannot be disabled (D-098).",
  sev="Informational.", conf="High — repository facts.", ev="Observed.",
  fp="n/a — it always emits by design.",
  fn="n/a.",
  drill="Address any skipped collectors before relying on absence of findings.",
  config="None (cannot be disabled, D-098).",
  example="Run Report on any installed repository; FR_R0026 always appears."),
}

DISABLED_NOTE = (
 "Plan analysis is **disabled by design**. The original implementation shredded "
 "plan XML from `sys.dm_exec_query_plan`, which locked decisions **D-015, D-046, "
 "D-082, and D-136** forbid. There is no compliant implementation, so this rule "
 "has no logic and never fires. `@IncludeQueryPlans = 1` is a reserved no-op that "
 "emits a single Informational coverage finding explaining this. The RuleId is "
 "preserved and never reused (D-089/D-090); the rule may be revisited only under a "
 "future decision-log-approved plan-analysis design.")

def sev_field(sev, rid):
    if rid == "FR_R0003_TopWaitTypeSpike":
        return sev + " — escalates High on critical wait types"
    if rid == "FR_R0004_FileIoLatencySpike":
        return sev + " (escalates High)"
    return sev

def page(meta):
    rid, cat, sev, conf, ev, life, intro = meta
    short = rid.split("_", 2)[2]
    num = rid.split("_")[1]
    title = f"# FR_{num} {short}"
    if life == "Disabled":
        return "\n".join([
         title, "",
         "> **Status: Disabled / Reserved.** This plan-analysis rule is cataloged but"
         " has no logic.", "",
         "| Field | Value |", "|---|---|",
         f"| RuleId | `{rid}` |",
         f"| Category | {cat} |",
         f"| Severity (if it fired) | {sev} |",
         f"| Confidence | {conf} |",
         f"| Evidence type | {ev} |",
         f"| Introduced in | {intro} |",
         "| Lifecycle | **Disabled** |",
         "| Data source | none (would have required plan XML) |", "",
         "## Why it is disabled", "", DISABLED_NOTE, "",
         "## What it would have detected", "",
         {"FR_R0030_PlanMissingIndex":"Missing-index evidence in a captured plan.",
          "FR_R0031_PlanImplicitConversion":"A plan-affecting implicit conversion.",
          "FR_R0032_PlanSpillToTempDb":"A spill-to-tempdb warning in a plan.",
          "FR_R0033_PlanWarnings":"Optimizer warnings in a plan.",
          "FR_R0034_PlanParallelism":"Parallel operators in a plan."}[rid], "",
         "## Alternative", "",
         "For plan-level evidence without this tool parsing plan XML, use **Query "
         "Store** (see FR_R0015/FR_R0016/FR_R0018).", "",
         "## Guarantees", "",
         "- No `sys.dm_exec_query_plan`. No T-SQL plan-XML shredding.",
         "- RuleId preserved, never reused (D-089).",
         "- Enforced by the static-analysis linter (D-136/D-144).", "",
        ])
    c = C[rid]
    esc = ""
    return "\n".join([
     title, "",
     "| Field | Value |", "|---|---|",
     f"| RuleId | `{rid}` |",
     f"| Category | {cat} |",
     f"| Severity | {sev_field(sev, rid)} |",
     f"| Confidence | {conf} |",
     f"| Evidence type | {ev} |",
     f"| Introduced in | {intro} |",
     f"| Lifecycle | {life} |",
     f"| Data source | {c['source']} |",
     f"| Dedup anchor | {c['anchor']} |", "",
     "## What it detects", "", c["detects"], "",
     "## How it is computed", "", "Repository-only (D-014/D-081). " + c["computed"], "",
     "## Severity rationale", "", c["sev"], "",
     "## Confidence rationale", "", c["conf"], "",
     "## Evidence-type rationale", "", c["ev"], "",
     "## False-positive risks", "", c["fp"], "",
     "## False-negative risks", "", c["fn"], "",
     "## Drill-down guidance", "", c["drill"] + " Drill-down queries are read-only (D-086).", "",
     "## Suppress / disable", "",
     ("This rule cannot be disabled (D-098)." if rid in ("FR_R0026_CoverageAndCapabilitySummary",)
      else f"```sql\nEXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure',\n    @ConfigKey = N'DisabledRules', @ConfigValue = N'{rid}';\n```\nSuppressed rules are listed in FR_R0026 (D-101)."), "",
     "## Related config keys", "", c["config"] + " See [configuration.md](../configuration.md).", "",
     "## Example", "", c["example"], "",
    ])

def index():
    rows = ["# Rule index", "",
            "One page per rule (D-161). Template: [_template.md](_template.md).", "",
            "| RuleId | Category | Severity | Confidence | Evidence | Lifecycle |",
            "|---|---|---|---|---|---|"]
    for rid, cat, sev, conf, ev, life, _ in META:
        num = rid.split("_")[1][1:]   # 'R0001' -> '0001'
        rows.append(f"| [{num}](FR_R{num}.md) {rid.split('_',2)[2]} | {cat} | {sev} | {conf} | {ev} | {life} |")
    return "\n".join(rows) + "\n"

def main():
    check = "--check" in sys.argv
    RULES_DIR.mkdir(parents=True, exist_ok=True)
    stale = []
    for meta in META:
        rid = meta[0]
        num = rid.split("_")[1][1:]   # 'R0001' -> '0001'
        if num in KEEP_HANDWRITTEN:
            continue
        p = RULES_DIR / f"FR_R{num}.md"
        new = page(meta) + "\n"
        if check:
            if not p.exists() or p.read_text(encoding="utf-8") != new:
                stale.append(p.name)
        else:
            p.write_text(new, encoding="utf-8", newline="\n")
    idx = RULES_DIR / "README.md"
    if check:
        if not idx.exists() or idx.read_text(encoding="utf-8") != index():
            stale.append("README.md")
        if stale:
            print("STALE rule docs (run scripts/gen-rule-docs.py):", ", ".join(stale)); return 1
        print("rule docs up to date."); return 0
    idx.write_text(index(), encoding="utf-8", newline="\n")
    print(f"generated {len(META)-len(KEEP_HANDWRITTEN)} rule pages + index (kept FR_R{sorted(KEEP_HANDWRITTEN)[0]}.md).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
