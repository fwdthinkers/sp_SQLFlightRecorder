# Configuration reference

All configuration lives in `dbo.FR_Config` (key/value). Read or change it with
[Configure mode](modes/configure.md):

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';                          -- read all
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure',
    @ConfigKey = N'SnapshotRetentionDays', @ConfigValue = N'7';              -- write
```

**Tunable** = editable via Configure (on the whitelist). **Internal** =
maintained by the tool (high-water markers, install metadata); do not edit by
hand. Multi-value keys are semicolon-delimited (D-026). Values marked
*(tentative, D-181)* are defensible defaults that may change in a minor release.

## Retention & cadence
| Key | Default | Tunable | Purpose |
|---|---|---|---|
| `SchemaVersion` | 0.5.0 | Internal | Forward-only migration marker (D-038). |
| `SnapshotIntervalSeconds` | 60 | Tunable | Intended collection cadence (D-042); also drives gap grading (D-066). |
| `SnapshotRetentionDays` | 7 | Tunable | Snapshot data retention. **Allowed range 1–31** (D-199); out-of-range values are refused. |
| `RunLogRetentionDays` | 28 | Tunable | Run-log retention (4× snapshot, D-035). **Allowed range 1–124** (D-199); out-of-range values are refused. |
| `MaxRowsPerCollector` | 50 | Tunable | Per-collector row cap (D-181). |
| `RepositoryTableWarnRows` | 5000000 | Tunable | Row count per `FR_*` table that raises a `Status` retention-health warning (D-199). |

> **Retention is a guardrail, not a warehouse setting (D-199).** SQLFR is an
> operational diagnostic recorder. Longer retention grows the `FR_*`
> repository and raises Report cost; if you must keep diagnostic history
> longer than the allowed ranges, export it elsewhere. **Purge is mandatory
> operational maintenance** — schedule it (Agent installs get a post-collect
> Purge step and a daily purge job automatically; see
> [operations/scheduling.md](operations/scheduling.md)).

## Rule thresholds
| Key | Default | Tunable | Drives |
|---|---|---|---|
| `DisabledRules` | (empty) | Tunable | Semicolon-delimited disabled RuleIds (D-099). |
| `WaitStatsIgnoreList` | (large list) | Tunable | Wait types excluded at collect time (D-033/D-057). |
| `CriticalWaitTypes` | PAGEIOLATCH_*;… | Tunable | **Defined but honored from v1.1** (D-105). FR_R0003 uses the hard-coded D-093 list until then. |
| `BlockingStormSessionThreshold` | 5 | Tunable | FR_R0007 *(tentative)*. |
| `TempdbVersionStoreWarnKb` | 5242880 | Tunable | FR_R0008 escalation *(tentative)*. |
| `LongOpenTxnSeconds` | 60 | Tunable | FR_R0002 span threshold *(tentative)*. |
| `FileIoLatencyWarnMs` | 20 | Tunable | FR_R0004 latency floor *(tentative)*. |
| `BackupWarnDays` | 7 | Tunable | FR_R0025 FULL-backup age (D-097). |
| `CheckDbWarnDays` | 14 | Tunable | FR_R0025 CHECKDB age (D-097). |
| `CompilationsPerSecWarn` | 100 | Tunable | FR_R0020 *(tentative)*. |
| `QueryStoreRegressionFactor` | 2 | Tunable | FR_R0015 *(tentative)*. |
| `QueryStoreCapacityWarnPercent` | 90 | Tunable | FR_R0019 *(tentative)*. |
| `BaselineLookbackHours` | 24 | Tunable | Baseline window for baseline-relative rules (D-092), 1–168. |

## Collector toggles
| Key | Default | Tunable | Purpose |
|---|---|---|---|
| `CollectQueryStore` | 1 | Tunable | Collect bounded Query Store top-N (D-044). |
| `QueryStoreMaxDatabases` | 50 | Tunable | Max user DBs scanned by the QS collector (D-052). |
| `CollectErrorLog` | 0 | Tunable | **Opt-in** error-log scrape (D-020/D-060). |
| `CollectSchemaActivity` | 1 | Tunable | Bounded schema/stats metadata (D-052). |
| `SchemaActivityMaxDatabases` | 50 | Tunable | Max DBs for the schema-activity collector (D-052). |
| `CollectPlanCacheSummary` | 1 | Tunable | Bounded plan-cache summary (D-055); never shreds plan XML. |
| `EnableAdvancedHaCollector` | 1 | Tunable | Advanced HA/AG context where HADR is enabled. |
| `EnableBufferPoolCollector` | 0 | Tunable | **Opt-in** buffer-pool summary (D-051). |
| `BufferPoolCollectionMaxRows` | 100 | Tunable | Row cap for the buffer-pool collector. |
| `BufferPoolMaxMemoryGB` | 256 | Tunable | Buffer-pool collector skipped above this memory (D-051). |

## Display (time zone)
| Key | Default | Tunable | Purpose |
|---|---|---|---|
| `TimeZoneMode` | UTC | Tunable | Report Markdown/Status display: `UTC` or `LOCAL` (D-180). Storage/sort stay UTC. |
| `TimeZoneName` | (empty) | Tunable | Windows time-zone id for `LOCAL` display (SQL 2016+); empty = server offset. |

## Internal (do not hand-edit)
`AgentJobName`, `AgentJobCreatedBySQLFlightRecorder`, `PurgeAgentJobName`,
`PurgeAgentJobCreatedBySQLFlightRecorder`, `AgentJobHighWaterInstanceId`,
`BackupHighWaterBackupSetId`, `ErrorLogHighWaterUtc`, `MaintenanceJobNamePatterns`
— install metadata and delta high-water markers maintained by the tool. The
`PurgeAgentJob*` keys record the daily purge backstop job that
`Install @CreateAgentJob = 1` creates (D-199), so Uninstall knows to remove it.

---
*Unknown keys and non-integer values for integer keys are refused by Configure.
See [modes/configure.md](modes/configure.md).*
