## SQL Server DBA Flight Recorder

**sp_SQLFlightRecorderr** is a lightweight, open-source, pure T-SQL stored procedure that captures safe SQL Server diagnostic snapshots and turns them into concise incident timelines, findings, and recommendations.

It is built for the question every DBA gets at 2 AM:

> “SQL Server was slow earlier — what happened?”

sp_SQLFlightRecorder gives you a local, low-friction flight recorder for SQL Server: collect small snapshots over time, then report on blocking, waits, I/O, memory pressure, restarts, configuration signals, and collection coverage.

Developed by **Ysaias Portes — Forward Thinkers Consulting, LLC.**

---

## Navigation

- [What it does](#what-it-does)
- [Why this tool exists](#why-this-tool-exists)
- [What it is not](#what-it-is-not)
- [When it is a big help](#when-it-is-a-big-help)
- [Quick start](#quick-start)
- [Parameters](#Parameters)
- [Common commands](#common-commands)
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

Open and execute:

```text
sp_SQLFlightRecorder.sql
```

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
| `@StartTime` | `NULL` | `Report` | Optional report start time. If omitted, the procedure chooses a default window. |
| `@EndTime` | `NULL` | `Report` | Optional report end time. If omitted, the procedure chooses a default window. |
| `@MinSeverity` | `Low` | `Report` | Minimum severity to show: `Informational`, `Low`, `Medium`, `High`, or `Critical`. |
| `@MaxFindings` | `200` | `Report` | Maximum number of findings to return. Valid range: `10` to `2000`. |
| `@TopN` | `50` | `Collect` | Per-collector row cap for top-N style collection. Valid range: `1` to `1000`. |
| `@OutputFormat` | `Default` | `Report` | Report format: `Default`, `FindingsOnly`, `TimelineOnly`, or `Markdown`. |
| `@IncludeQueryPlans` | `0` | `Report` | Optional plan output if supported. Plans are not shredded by default. |
| `@WhatIf` | `0` | `Purge`, `Uninstall` | Preview what would happen without making changes. |
| `@PreserveRunLog` | `0` | `Uninstall` | When `1`, preserves or archives run-log tables during uninstall if supported. |
| `@Debug` | `0` | `Collect`, internal/debug paths | Enables debug behavior. Useful for troubleshooting collector readiness. |
| `@ConfigKey` | `NULL` | `Configure` | Configuration key to update. If omitted, returns current configuration. |
| `@ConfigValue` | `NULL` | `Configure` | New value for `@ConfigKey`. |
| `@CreateAgentJob` | `0` | `Install` | Explicit opt-in to create a SQL Agent job for scheduled collection. |

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

### Install and create the SQL Agent job

Only use this if SQL Agent is available and you want scheduled collection.

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

### Include query plans if supported

Plans are optional and are not parsed/shredded by default.

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

## Common commands

### Help

```sql
EXEC dbo.sp_SQLFlightRecorder;
```

or:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
```

### About / version

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
```

### Install

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```

Install should be safe to run more than once.

### Status

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

### Collect

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

### Collect debug

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectDebug';
```

### Report

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
```

With a time window:

```sql
DECLARE @StartTime datetime2(3) = DATEADD(hour, -1, SYSUTCDATETIME());
DECLARE @EndTime   datetime2(3) = SYSUTCDATETIME();

EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @StartTime = @StartTime,
    @EndTime = @EndTime,
    @MinSeverity = N'Low',
    @MaxFindings = 200,
    @OutputFormat = N'Default';
```

### Markdown report

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'Markdown';
```

### Configure

Show current configuration:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';
```

Update retention:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Configure',
    @ConfigKey = N'SnapshotRetentionDays',
    @ConfigValue = N'7';
```

### Purge preview

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 1;
```

### Purge old data

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 0;
```

---

## Scheduling collection

For useful history, run `Collect` on a schedule.

Typical cadence:

```text
Every 1 minute
```

If your build supports SQL Agent job creation, create it explicitly:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Install',
    @CreateAgentJob = 1;
```

Verify the job:

```sql
SELECT 
    name,
    enabled,
    date_created,
    date_modified
FROM msdb.dbo.sysjobs
WHERE name LIKE N'%sp_SQLFlightRecorder%';
```

If SQL Agent is unavailable, schedule collection externally with `sqlcmd`, a DBA automation tool, Windows Task Scheduler, cron, or your preferred job runner.

Example:

```bash
sqlcmd -S MyServer -d MyDatabase -E -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';"
```

---

## Configuration and retention

Configuration is stored in:

```sql
dbo.FR_Config
```

Common keys may include:

| Key | Purpose |
|---|---|
| `SchemaVersion` | Installed repository schema version |
| `SnapshotIntervalSeconds` | Intended collection interval |
| `SnapshotRetentionDays` | Snapshot data retention |
| `RunLogRetentionDays` | Run-log retention |
| `MaxRowsPerCollector` | Per-collector row cap |
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

Always preview purge before deleting:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Purge',
    @WhatIf = 1;
```

---

## Uninstall

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

Preserve run-log tables if supported:

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

Recommended:

- SQL Server 2012 or newer
- A user database for the repository
- Permission to create/alter the stored procedure
- Permission to create repository tables
- `VIEW SERVER STATE` for collection
- SQL Agent permissions only if using optional job creation

Notes:

- SQL Agent is not available in SQL Server Express.
- Azure SQL Database does not support SQL Agent.
- Some collectors may degrade gracefully based on version, edition, permissions, or platform.

---

## Safety notes

sp_SQLFlightRecorder is designed to be DBA-safe:

- default mode is `Help`
- collection is bounded where practical
- report reads from repository tables
- destructive modes are explicit
- purge should support `@WhatIf`
- uninstall should support `@WhatIf`
- SQL Agent job creation should be opt-in
- no automatic remediation

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

Full documentation:

```text
docs/user-guide.md
```

Main implementation file:

```text
sp_SQLFlightRecorder.sql
```

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
