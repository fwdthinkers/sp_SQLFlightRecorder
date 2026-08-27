## SQL Server DBA Flight Recorder

**sp_SQLFlightRecorder** is a lightweight, open-source, pure T-SQL stored procedure that captures safe SQL Server diagnostic snapshots and turns them into concise incident timelines, findings, and recommendations.

It is built for the question every DBA gets at 2 AM:

> “SQL Server was slow earlier — what happened?”

sp_SQLFlightRecorder gives you a local, low-friction flight recorder for SQL Server: collect small snapshots over time, then report on blocking, waits, I/O, memory pressure, restarts, configuration signals, and collection coverage.

Developed by **Ysaias Portes — Forward Thinkers Consulting, LLC.**

**Current release: v1.1.2** (2026-08-27) — see the [CHANGELOG](CHANGELOG.md) and [releases](https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder/releases). v1.1.0 made retention operationally safe by default: Agent-capable installs create both a collector job (Collect, then Purge) and a daily purge backstop job, retention values are validated, and the repository is indexed for purge/report at scale. From v1.0.0 the output contract is frozen for v1.x: rule IDs, output columns, and the forward-only schema are ["1.0 is forever" promises](docs/compatibility/support-policy.md).

---

## Navigation

- [What it does](#what-it-does)
- [Why this tool exists](#why-this-tool-exists)
- [What it is not](#what-it-is-not)
- [How it fits with other SQL Server tools](#how-it-fits-with-other-sql-server-tools)
- [When it is a big help](#when-it-is-a-big-help)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [Examples](#examples)
- [Scheduling collection](#scheduling-collection)
- [Configuration and retention](#configuration-and-retention)
- [Uninstall](#uninstall)
- [Requirements](#requirements)
- [Safety notes](#safety-notes)
- [Documentation](#documentation)
- [License](#license)

---

## What it does

sp_SQLFlightRecorder installs one stored procedure:

```sql
dbo.sp_SQLFlightRecorder
```

When you run `Install`, it creates local `FR_*` repository tables in your database. When you run `Collect`, it captures bounded diagnostic data. When you run `Report`, it reads the repository and produces findings and timeline output.

Typical workflow:

```text
Install once.
Collect every minute.
Report when something goes wrong.
Purge old data.
Uninstall cleanly when done.
```

The goal is not to replace your monitoring stack. The goal is to give DBAs a simple, portable, evidence-based incident recorder that is already inside SQL Server.

---

## Why this tool exists

Many SQL Server troubleshooting tools are excellent at one thing:

- current requests
- waits
- blocking
- file latency
- configuration
- SQL Agent history
- Query Store
- performance counters
- server metadata

But during an incident, DBAs often have to jump between multiple scripts, tools, tabs, dashboards, and historical sources.

sp_SQLFlightRecorder helps consolidate the basics into one repeatable flow:

```text
Collect useful diagnostic snapshots.
Store them locally.
Report on what changed.
Show findings with evidence.
Keep everything DBA-readable.
```

It is designed to help answer:

- Was there blocking?
- Were waits abnormal?
- Did SQL Server restart?
- Were memory grants pending?
- Was I/O latency high?
- Were collectors skipped?
- Do we have enough data to trust the report?

---

## What it is not

sp_SQLFlightRecorder is **not**:

- a monitoring platform
- an alerting system
- a dashboard
- an AI/ML anomaly detector
- a remediation tool
- a replacement for Query Store
- a replacement for Extended Events
- a replacement for a senior DBA
- a tool that automatically fixes anything

It diagnoses. It does not take corrective action.

It will not kill sessions, force plans, shrink files, clear cache, change indexes, or “fix” your server for you.

---

## How it fits with other SQL Server tools

I use and recommend the tools below. sp_SQLFlightRecorder is not a replacement for any of them and does not try to be.

- [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) — what is running right now
- [First Responder Kit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) — health checks, plan cache analysis, index analysis, first-response triage
- [Ola Hallengren's Maintenance Solution](https://github.com/olahallengren/sql-server-maintenance-solution) — backups, integrity checks, index and statistics maintenance
- [dbatools](https://dbatools.io/) — estate-wide automation and administration
- [Glenn Berry's Diagnostic Queries](https://glennsqlperformance.com/resources/) — manual DMV inspection and configuration review
- Query Store — per-database query runtime and plan history
- Extended Events — precise, customizable event capture

sp_SQLFlightRecorder fills a narrower gap: a small amount of retained, server-wide evidence, already inside SQL Server, for the case where the incident is over and nobody was watching. It collects bounded snapshots on a schedule, keeps them for a short configurable window, and reports on what changed.

Several of these tools can be scheduled to persist their output, and if you already do that, you may not need this one. What sp_SQLFlightRecorder offers is a single procedure with no dependencies, a curated evidence set spanning waits, blocking, I/O, memory, restarts, configuration, and Agent history in one repository, and a report that reads as a timeline rather than a set of separate result sets.

---

## When it is a big help

sp_SQLFlightRecorder is especially useful when:

- users report slowness after the fact
- you need recent diagnostic history but do not have a full monitoring platform
- you want a lightweight collector in a client environment
- you need repeatable DBA triage output
- you want to compare snapshots before, during, and after an incident
- you want to document what happened with evidence
- you need something easier to deploy than a full monitoring stack
- you are helping a team that has “some SQL problem” but no historical data

It is also useful for consultants because it is self-contained:

```text
One SQL file.
One stored procedure.
Local repository tables.
No service.
No installer.
No external runtime.
```

---

## Quick start

> Test first in a non-production database.

### 1. Run the procedure file

Open and execute [`sp_SQLFlightRecorder.sql`](sp_SQLFlightRecorder.sql).

This creates or updates:

```sql
dbo.sp_SQLFlightRecorder
```

### 2. Check version and help

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
```

### 3. Install the repository

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```

### 4. Check status

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

### 5. Collect two snapshots

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

WAITFOR DELAY '00:00:05';

EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

### 6. Run a report

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @MinSeverity = N'Informational',
    @OutputFormat = N'Default';
```

---

## Parameters

`sp_SQLFlightRecorder` is controlled by parameters. The most important one is `@Mode`.

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Help';
```

### Main parameters

| Parameter | Default | Used by | Meaning |
|---|---:|---|---|
| `@Mode` | `Help` | All | Chooses what the procedure does. Examples: `Install`, `Collect`, `Report`, `Configure`, `Purge`, `Uninstall`. |
| `@DatabaseName` | `NULL` | `Report` | Optional database filter for report output. |
| `@StartTime` | `NULL` | `Report` | Optional report start time. If omitted, the procedure chooses a default window. Default 1 hour back. |
| `@EndTime` | `NULL` | `Report` | Optional report end time. If omitted, the procedure chooses a default window. Current datetime. |
| `@MinSeverity` | `Low` | `Report` | Minimum severity to show: `Informational`, `Low`, `Medium`, `High`, or `Critical`. |
| `@MaxFindings` | `200` | `Report` | Maximum number of findings to return. Valid range: `10` to `2000`. |
| `@TopN` | `50` | `Collect` | Per-collector row cap for top-N style collection. Valid range: `1` to `1000`. |
| `@OutputFormat` | `Default` | `Report` | Report format: `Default`, `FindingsOnly`, `TimelineOnly`, or `Markdown`. |
| `@IncludeQueryPlans` | `0` | `Report` | **Reserved / no-op in this build.** Plan capture and plan-XML analysis are disabled by design; no plan output is returned. `1` records a Skipped step at Collect and one Informational coverage finding at Report. |
| `@WhatIf` | `0` | `Purge`, `Uninstall` | Preview what would happen without making changes. |
| `@PreserveRunLog` | `0` | `Uninstall` | When `1`, Uninstall renames `FR_RunLog`/`FR_RunLogStep` to timestamped `FR_RunLog_Archive_<yyyymmdd_hhmmss>` tables instead of dropping them. |
| `@Debug` | `0` | `Collect` | `1` routes `Collect` to `CollectDebug`: validates collector readiness and writes no collector rows. |
| `@ConfigKey` | `NULL` | `Configure` | Configuration key to update. If omitted, returns current configuration. |
| `@ConfigValue` | `NULL` | `Configure` | New value for `@ConfigKey`. |
| `@CreateAgentJob` | `0` | `Install` | Explicit opt-in to create/update the SQL Agent jobs: the per-minute collector job (Collect step, then a Purge cleanup step) and a daily purge backstop job. |
| `@TimeZone` | `NULL` | `Report` | Display-only IANA/Windows time zone for Markdown output (SQL 2016+/Azure; falls back to UTC elsewhere). Storage and sorting stay UTC. |

### Common `@Mode` values

| Mode | What it does |
|---|---|
| `Help` | Shows usage information. This is the default mode. |
| `About` | Shows version and build information. |
| `Install` | Creates the local `FR_*` repository tables and seed data. |
| `Status` | Shows current configuration, rules, recent runs, and repository footprint. |
| `Collect` | Captures one diagnostic snapshot. |
| `CollectDebug` | Runs diagnostic/debug collection behavior. |
| `Report` | Reads collected snapshots and returns findings/timeline output. |
| `Configure` | Shows or updates configuration values. |
| `Purge` | Deletes old repository data based on retention settings. |
| `Uninstall` | Removes SQLFlightRecorder repository objects. |

---

## Examples

These examples are copy/paste friendly.

### Install SQLFlightRecorder

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Install';
```

### Install and create the SQL Agent jobs

Only use this if SQL Agent is available and you want scheduled collection.
This creates or updates **two** jobs, idempotently: `SQLFlightRecorder Collect`
(every minute: a Collect step, then a Purge cleanup step) and
`SQLFlightRecorder Purge` (a daily retention backstop at 02:30 server time).

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Install',
    @CreateAgentJob = 1;
```

### Check status

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Status';
```

### Collect one snapshot

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Collect';
```

### Collect with a smaller top-N cap

Use this if you want collection to be more conservative.

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Collect',
    @TopN = 25;
```

### Run a basic report

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report';
```

### Run a report for the last hour

```sql
DECLARE @StartTime datetime2(3) = DATEADD(hour, -1, SYSUTCDATETIME());
DECLARE @EndTime   datetime2(3) = SYSUTCDATETIME();

EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @StartTime = @StartTime,
    @EndTime = @EndTime;
```

### Run a report for one database

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @DatabaseName = N'YourDatabaseName';
```

### Show only high-severity findings

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @MinSeverity = N'High';
```

### Return more findings

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @MaxFindings = 500;
```

### Return findings only

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'FindingsOnly';
```

### Return timeline only

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'TimelineOnly';
```

### Return Markdown output

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'Markdown';
```

### Reserved query-plan parameter

`@IncludeQueryPlans` is reserved and is a no-op in this build: plan capture
and plan-XML analysis are disabled by design, so no plan output is returned.
Setting it to `1` records a Skipped QueryPlans step at Collect and one
Informational coverage finding at Report explaining this. Use Query Store for
plan-level evidence.

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @IncludeQueryPlans = 1;
```

### Show current configuration

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure';
```

### Change snapshot retention

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure',
    @ConfigKey = N'SnapshotRetentionDays',
    @ConfigValue = N'7';
```

### Change run-log retention

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure',
    @ConfigKey = N'RunLogRetentionDays',
    @ConfigValue = N'28';
```

### Change the default row cap

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure',
    @ConfigKey = N'MaxRowsPerCollector',
    @ConfigValue = N'50';
```

### Disable one or more rules

Use a semicolon-delimited list.

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure',
    @ConfigKey = N'DisabledRules',
    @ConfigValue = N'FR_R0003_TopWaitTypeSpike;FR_R0004_FileIoLatencySpike';
```

### Preview purge

Always preview purge first.

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 1;
```

### Run purge

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 0;
```

### Preview uninstall

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall',
    @WhatIf = 1;
```

### Uninstall but preserve run log

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall',
    @PreserveRunLog = 1;
```

### Clean uninstall

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall',
    @PreserveRunLog = 0;
```

### Remove the procedure itself

`Uninstall` removes the repository objects. If you also want to remove the stored procedure:

```sql
DROP PROCEDURE dbo.sp_SQLFlightRecorder;
```

---

## Scheduling collection

For useful history, run `Collect` on a schedule — and **always schedule `Purge`
too**. Purge is mandatory operational maintenance: without it the `FR_*`
repository grows without bound and `Report` slows down or stops returning
quickly.

Typical cadence:

```text
Collect: every 1 minute
Purge:   after each collect (cleanup step) plus a daily backstop
```

If your build supports SQL Agent job creation, create both jobs explicitly:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Install',
    @CreateAgentJob = 1;
```

This ensures (idempotently — re-running never duplicates jobs, steps, or
schedules):

- **`SQLFlightRecorder Collect`** — every minute; step 1 runs `Collect`,
  step 2 runs `Purge` (`@WhatIf = 0`) as normal cleanup.
- **`SQLFlightRecorder Purge`** — daily at 02:30 server time; a retention
  backstop in case the collector job is disabled, changed, or failing.

Verify the jobs:

```sql
SELECT 
    name,
    enabled,
    date_created,
    date_modified
FROM msdb.dbo.sysjobs
WHERE name LIKE N'%SQLFlightRecorder%';
```

If SQL Agent is unavailable, schedule externally with `sqlcmd`, a DBA
automation tool, Windows Task Scheduler, cron, or your preferred job runner —
and schedule **both** statements:

```bash
sqlcmd -S MyServer -d MyDatabase -E -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';"
sqlcmd -S MyServer -d MyDatabase -E -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;"
```

> **Platform-specific recipes** — cron + `sqlcmd` on Linux, SQL Agent jobs on
> Azure SQL Managed Instance, and Elastic Jobs or an external scheduler on
> Azure SQL Database (which has no SQL Agent and no msdb — it must schedule both
> `Collect` and `Purge` externally): see
> **[docs/operations/scheduling.md](docs/operations/scheduling.md)**.

---

## Configuration and retention

Configuration is stored in:

```sql
dbo.FR_Config
```

The most commonly tuned keys (full reference: [docs/configuration.md](docs/configuration.md)):

| Key | Purpose |
|---|---|
| `SchemaVersion` | Installed repository schema version |
| `SnapshotIntervalSeconds` | Intended collection interval |
| `SnapshotRetentionDays` | Snapshot data retention (allowed 1–31) |
| `RunLogRetentionDays` | Run-log retention (allowed 1–124) |
| `MaxRowsPerCollector` | Per-collector row cap |
| `RepositoryTableWarnRows` | Row threshold for the Status size warning |
| `DisabledRules` | Semicolon-delimited disabled rule list |

View configuration:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';
```

or:

```sql
SELECT *
FROM dbo.FR_Config
ORDER BY ConfigKey;
```

Recommended starting retention:

```text
SnapshotRetentionDays = 7
RunLogRetentionDays   = 28
```

Retention is validated: `SnapshotRetentionDays` accepts 1–31 and
`RunLogRetentionDays` accepts 1–124; out-of-range values are refused.
SQLFlightRecorder is an operational diagnostic recorder, not a long-term
warehouse — longer retention grows the repository and raises report cost.
Export data you need to keep longer.

Always preview purge before deleting:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 1;
```

Then run the real purge (this is what the Agent jobs run for you):

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 0;
```

`Status` includes a retention-health result set that warns when the oldest
snapshot exceeds retention, purge is not keeping up, a purge job/step is
missing on Agent-capable platforms, or an `FR_*` table crosses
`RepositoryTableWarnRows`.

---

## Uninstall

Uninstall removes the `FR_*` repository objects and both SQL Agent jobs
(`SQLFlightRecorder Collect` and `SQLFlightRecorder Purge`) if this tool
created them. It is idempotent and does not fail if a job is already gone.

Preview uninstall first:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall',
    @WhatIf = 1;
```

Remove repository objects:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall';
```

Preserve the run log (renames `FR_RunLog`/`FR_RunLogStep` to timestamped `FR_*_Archive_*` tables):

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Uninstall',
    @PreserveRunLog = 1;
```

Remove the procedure itself:

```sql
DROP PROCEDURE dbo.sp_SQLFlightRecorder;
```

Verify remaining objects:

```sql
SELECT 
    s.name AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType
FROM sys.objects AS o
JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
WHERE o.name LIKE N'FR[_]%'
   OR o.name = N'sp_SQLFlightRecorder'
ORDER BY o.name;
```

---

## Requirements

**Primary supported range: SQL Server 2014 through 2025.** SQL Server 2012 is legacy best-effort with a known `SchemaActivity` collector degradation, listed in the table for completeness.

| Version | Platform | Support status |
|---|---|---|
| **2017, 2019, 2022, 2025** | Linux | Supported core — **verified** per-push in automated Tier-1 CI. |
| **2017, 2019, 2022, 2025** | Windows | Supported. Same capability-based code path as Linux (the tool branches on capability flags and `EngineEdition`, never on OS); no manual attestation on file yet. |
| **2017, 2019, 2022, 2025** | SQL Server on Azure VM (IaaS) | Supported as the matching Linux or Windows row — it is the ordinary engine on a VM you administer, not a separate product. |
| **2016** | **Windows only** | Manual Tier-2 target — **verified against v1.0.0**. |
| **2014** | **Windows only** | Manual Tier-2 target — **verified against v1.0.0**. |
| **2012** | **Windows only** | **Legacy best-effort.** The v1.0.0 lifecycle was manually tested and completed, but with a known `SchemaActivity` collector degradation — collect runs return `PartialSuccess` and schema-activity data is incomplete. |
| **Azure SQL Managed Instance** | Azure PaaS | **Verified** by manual Tier-2 attestation against v1.0.0. Full collector set; only `AlwaysOnState` skipped, capability-gated. SQL Agent available. |
| **Azure SQL Database** | Azure PaaS | **Verified** by manual Tier-2 attestation against v1.0.0, **with four expected capability-gated skips** (`AgentJobs`, `BackupHistory`, `Deadlocks`, `AlwaysOnState`). No SQL Agent, no msdb. |

Tier-2 "verified" means one manual lifecycle run, not the per-push automated
gate that covers the Tier-1 Linux rows. **No equivalence is claimed** between
Azure SQL Database and Managed Instance, or between either and on-prem.

Full detail, including per-target evidence and caveats:
[docs/compatibility/matrix.md](docs/compatibility/matrix.md) and
[docs/compatibility/support-policy.md](docs/compatibility/support-policy.md).

Also required:

- A user database for the repository
- Permission to create/alter the stored procedure
- Permission to create repository tables
- `VIEW SERVER STATE` for collection
- SQL Agent permissions only if using optional job creation

Notes:

- SQL Agent is not available in SQL Server Express.
- Azure SQL Database does not support SQL Agent.
- Capability-gated collectors skip cleanly where a source is absent: `AgentJobs` and `BackupHistory` without msdb (Azure SQL Database), `Deadlocks` on Azure SQL Database, `AlwaysOnState` and the advanced HA collector without Always On, Query Store before SQL 2016 or with no Query Store-enabled database, the opt-in error log on Azure SQL Database, and the opt-in buffer pool above 256 GB target memory. `SchemaActivity` degrades on SQL Server 2012 (collect runs return `PartialSuccess`). Per-platform detail: [docs/compatibility/matrix.md](docs/compatibility/matrix.md).

---

## Safety notes

sp_SQLFlightRecorder is DBA-safe by construction:

- The default mode is `Help`. Running the procedure with no parameters prints usage and does nothing else.
- Collection is bounded. Most collectors cap at `MaxRowsPerCollector` (default 50); file stats cap at `TOP (5000)` rows, perf counters at `TOP (100)` over an 8-counter allow-list, `FR_Configuration` stores all of `sys.configurations` (roughly 80–110 rows), and several collectors write a single row per snapshot. Query Store and schema activity apply the cap per database across up to 50 databases. The `@TopN` parameter is validated 1–1000; the `MaxRowsPerCollector` config key is not range-checked.
- `Report` evaluates findings and the timeline only from the `FR_*` repository tables. The only live reads on any invocation are the fixed two-value capability probe (target server memory and host platform).
- Destructive modes are explicit, and `Purge` and `Uninstall` both accept `@WhatIf = 1` to preview without changing anything.
- SQL Agent job creation requires an explicit `@CreateAgentJob = 1`. It never happens by default.
- The procedure never issues `KILL`, never changes server or database configuration, and never modifies user objects — a CI linter enforces the forbidden list. It creates and drops only its own `FR_*` objects and, opt-in only, the two named Agent jobs.
- No automatic remediation.

Still, treat it like any DBA tool:

```text
Read the help.
Test in non-production.
Preview destructive actions.
Review permissions.
Schedule conservatively.
Watch repository growth.
```

---

## Documentation

Full documentation: [docs/user-guide.md](docs/user-guide.md)

Configuration reference: [docs/configuration.md](docs/configuration.md)

Main implementation file: [`sp_SQLFlightRecorder.sql`](sp_SQLFlightRecorder.sql)

Useful commands:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

---

## License

MIT License.

Copyright © Forward Thinkers Consulting, LLC.

---

## Final thought

sp_SQLFlightRecorder is for DBAs who want evidence, not guesses.

It does not try to be magic.  
It tries to be useful when the phone rings.
