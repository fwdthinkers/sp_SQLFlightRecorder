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
src/sp_SQLFlightRecorder.sql
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
src/sp_SQLFlightRecorder.sql
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
