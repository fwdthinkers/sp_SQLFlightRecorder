# SQLFlightRecorder User Guide

SQLFlightRecorder is a single-file, pure T-SQL diagnostic stored procedure for SQL Server DBAs. It captures bounded diagnostic snapshots into local repository tables and produces practical findings about server health, blocking, waits, I/O, memory pressure, configuration, and collection coverage.

Developed by **Ysaias Portes — Forward Thinkers Consulting, LLC.**

Repository:

```text
https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder
```

---

## 1. What SQLFlightRecorder does

SQLFlightRecorder installs one stored procedure:

```sql
dbo.sp_SQLFlightRecorder
```

When installed, it can create a local repository using `FR_*` tables in the current user database. Those tables store diagnostic snapshots collected from SQL Server system views and DMVs.

The typical workflow is:

```text
1. Deploy the procedure file.
2. Run Install.
3. Run Collect one or more times.
4. Run Report.
5. Optionally Configure retention/settings.
6. Optionally schedule collection with SQL Agent.
7. Periodically Purge old data.
8. Uninstall when no longer needed.
```

---

## 2. What SQLFlightRecorder creates

The procedure itself is:

```sql
dbo.sp_SQLFlightRecorder
```

The repository tables are created only when you run:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```

Expected repository objects include:

```text
dbo.FR_Config
dbo.FR_RunLog
dbo.FR_RunLogStep
dbo.FR_Snapshot
dbo.FR_InstanceSnapshot
dbo.FR_Configuration
dbo.FR_Request
dbo.FR_Wait
dbo.FR_FileStat
dbo.FR_PerfCounter
dbo.FR_QueryText
dbo.FR_Rules
```

Some builds may also create two SQL Agent jobs if you explicitly request scheduled collection: a collector job (Collect, then Purge as cleanup) and a daily purge backstop job.

SQLFlightRecorder is intended to be installed in a **user database**, not directly in `master`, unless your version explicitly supports and documents a master-install option.

---

## 3. Safety model

SQLFlightRecorder is designed to be production-conscious:

- Default mode is `Help`, so accidental execution is non-destructive.
- Collection uses bounded reads where practical.
- Report mode reads from `FR_*` repository tables, not live workload DMVs.
- Destructive operations require explicit modes such as `Uninstall` or `Purge`.
- `Purge` should delete in batches and should support `@WhatIf = 1`.
- SQL Agent scheduling should be opt-in only.
- Uninstall should remove only SQLFlightRecorder-owned objects.

Recommended first use:

```text
Use a non-production database first.
Run Install, Collect, Report, Purge @WhatIf, and Uninstall before using it on an important server.
```

---

## 4. Required permissions

Exact permissions can vary by SQL Server version and by which modes you use.

### Basic deployment

To create or alter the procedure:

```text
CREATE PROCEDURE / ALTER PROCEDURE permission in the target database
```

or membership in a role such as:

```text
db_owner
```

### Install mode

Install creates repository tables, indexes, foreign keys, and seed data.

Usually required:

```text
CREATE TABLE
ALTER on schema dbo
INSERT/UPDATE permissions on created FR_* tables
```

The procedure may also check for:

```text
VIEW SERVER STATE
```

because collection modes depend on server-level diagnostic views.

### Collect mode

Collection usually requires:

```text
VIEW SERVER STATE
```

Depending on SQL Server version and enabled collectors, additional permissions may be needed.

### SQL Agent job creation

If you use optional SQL Agent scheduling, permissions are needed in `msdb`.

Common requirements:

```text
SQLAgentOperatorRole, SQLAgentUserRole, or sysadmin
```

Exact requirements depend on your SQL Server security model.

### Azure SQL / Express notes

SQL Agent is not available in SQL Server Express and is not available in Azure SQL Database. SQLFlightRecorder should report a clean unsupported message instead of failing unexpectedly.

---

## 5. Installation

### Step 1 — Get the procedure file

Use the file:

```text
sp_SQLFlightRecorder.sql
```

Open it in SSMS, Azure Data Studio, sqlcmd, or another SQL client connected to the target database.

### Step 2 — Run the file

Run the full file once in the database where you want the procedure installed.

This creates or alters:

```sql
dbo.sp_SQLFlightRecorder
```

Running the file should not immediately create repository tables. Repository tables are created by `Install` mode.

### Step 3 — Confirm the procedure exists

```sql
SELECT 
    OBJECT_SCHEMA_NAME(OBJECT_ID(N'dbo.sp_SQLFlightRecorder')) AS SchemaName,
    OBJECT_NAME(OBJECT_ID(N'dbo.sp_SQLFlightRecorder')) AS ProcedureName;
```

Expected result:

```text
SchemaName  ProcedureName
----------  --------------------
dbo         sp_SQLFlightRecorder
```

---

## 6. Help and version information

### Show help

```sql
EXEC dbo.sp_SQLFlightRecorder;
```

Equivalent:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
```

Use this first to confirm available modes and parameters.

### Show version/build information

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
```

Some builds may also support:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';
```

Expected information includes:

```text
ToolVersion
BuildDateUtc
SupportedSqlServerRange
ImplementationPart or feature scope
InvocationUtc
```

---

## 7. Install mode

Run:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```

Expected behavior:

- Creates required `FR_*` repository tables.
- Creates indexes and constraints.
- Seeds default configuration in `FR_Config`.
- Seeds rule metadata in `FR_Rules`.
- Is safe to run more than once.
- Refuses unsafe environments such as read-only databases.
- Refuses unsupported downgrade scenarios if schema version is newer than the procedure.

### Install idempotency test

Run install twice:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```

Expected result:

```text
Second install should not fail.
Second install should not duplicate config/rule seed rows.
```

### Verify repository tables

```sql
SELECT 
    s.name AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType
FROM sys.objects AS o
JOIN sys.schemas AS s
    ON s.schema_id = o.schema_id
WHERE o.name LIKE N'FR[_]%'
ORDER BY o.name;
```

Expected tables include:

```text
FR_Config
FR_RunLog
FR_RunLogStep
FR_Snapshot
FR_InstanceSnapshot
FR_Configuration
FR_Request
FR_Wait
FR_FileStat
FR_PerfCounter
FR_QueryText
FR_Rules
```

---

## 8. Status mode

Run:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

Status is intended to show the current repository state.

Expected information may include:

1. Configuration values from `FR_Config`
2. Rule catalog from `FR_Rules`
3. Recent run log rows
4. Repository table sizes
5. Run-log summary
6. Capability/version/permission information
7. Retention and purge health checks (`CheckName, CheckStatus, Detail`)

How to read the retention-health checks:

- `OK` — nothing to do.
- `Warning` — act on the `Detail` text: typically schedule or re-enable Purge,
  re-run `Install @CreateAgentJob = 1` to restore a missing job/step, or lower
  retention. Warnings fire when the oldest snapshot exceeds
  `SnapshotRetentionDays`, purge is not keeping up, the collector job lacks a
  Purge step, the daily purge job is missing, or an `FR_*` table exceeds
  `RepositoryTableWarnRows`.
- `NotApplicable` — the check does not apply here (for example, no SQL Agent
  on this platform; schedule Collect and Purge externally instead).
- `Unknown` — msdb job metadata could not be read (usually permissions); the
  jobs may be fine, but Status cannot confirm it.

Status should be safe to run at any time.

Recommended checks:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

SELECT COUNT(*) AS ConfigRows
FROM dbo.FR_Config;

SELECT COUNT(*) AS RuleRows
FROM dbo.FR_Rules;
```

---

## 9. Collect mode

Collect mode captures a diagnostic snapshot into the `FR_*` repository tables.

Run:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

Expected behavior:

- Acquires an application lock to avoid overlapping collections.
- Writes a row to `FR_RunLog`.
- Writes one or more rows to `FR_RunLogStep`.
- Writes a snapshot row to `FR_Snapshot`.
- Writes collector data to available child tables such as:
  - `FR_InstanceSnapshot`
  - `FR_Configuration`
  - `FR_Request`
  - `FR_Wait`
  - `FR_FileStat`
  - `FR_PerfCounter`
- Handles individual collector failures without corrupting the repository.

### Verify collection

```sql
SELECT COUNT(*) AS SnapshotCount
FROM dbo.FR_Snapshot;

SELECT COUNT(*) AS RunLogCount
FROM dbo.FR_RunLog;

SELECT COUNT(*) AS RunLogStepCount
FROM dbo.FR_RunLogStep;
```

Collector row counts:

```sql
SELECT N'FR_InstanceSnapshot' AS TableName, COUNT(*) AS RowCount FROM dbo.FR_InstanceSnapshot
UNION ALL
SELECT N'FR_Configuration', COUNT(*) FROM dbo.FR_Configuration
UNION ALL
SELECT N'FR_Request', COUNT(*) FROM dbo.FR_Request
UNION ALL
SELECT N'FR_Wait', COUNT(*) FROM dbo.FR_Wait
UNION ALL
SELECT N'FR_FileStat', COUNT(*) FROM dbo.FR_FileStat
UNION ALL
SELECT N'FR_PerfCounter', COUNT(*) FROM dbo.FR_PerfCounter
ORDER BY TableName;
```

### Collect twice before reporting

Many reports are more useful with at least two snapshots.

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

WAITFOR DELAY '00:00:05';

EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

For normal scheduled use, collection is usually run every minute.

---

## 10. CollectDebug mode

CollectDebug mode is intended for diagnostics.

Run:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectDebug';
```

Expected behavior depends on your build, but generally:

- It should be safer than normal Collect for troubleshooting.
- It may write run-log/debug information.
- It should not corrupt repository tables.
- It should not silently change configuration.
- It should help identify missing permissions or collector failures.

Use CollectDebug when:

```text
Collect fails.
Collect returns PartialSuccess.
A collector is skipped.
A server/version capability is unclear.
```

After running CollectDebug, inspect recent runs:

```sql
SELECT TOP (20)
    RunId,
    StartUtc,
    EndUtc,
    Mode,
    Status,
    Reason,
    ErrorMessage
FROM dbo.FR_RunLog
ORDER BY RunId DESC;
```

---

## 11. Report mode

Report mode reads collected repository data and returns DBA-facing output.

Run after at least one or two Collect executions:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
```

Recommended:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'Default';
```

Expected behavior:

- Reads `FR_*` repository tables.
- Does not collect new live DMV data.
- Handles empty or low-data windows cleanly.
- Returns findings, timeline, markdown, or other supported output formats.
- Applies filters such as severity and maximum finding count.

### Common report parameters

Depending on your procedure version, supported parameters may include:

```sql
@StartTime
@EndTime
@MinSeverity
@MaxFindings
@OutputFormat
@IncludeQueryPlans
```

Example:

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

If supported:

```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode = N'Report',
    @OutputFormat = N'Markdown';
```

Expected result:

```text
A single report column containing Markdown text.
```
---

## 12. Output formats

SQLFlightRecorder may support the following report output formats:

    Default
    FindingsOnly
    TimelineOnly
    Markdown

### Default

Example:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @OutputFormat = N'Default';

Expected result:

    Findings result set
    Timeline result set

### FindingsOnly

Example:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @OutputFormat = N'FindingsOnly';

Expected result:

    Only findings.

### TimelineOnly

Example:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @OutputFormat = N'TimelineOnly';

Expected result:

    Only timeline events.

### Markdown

Example:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @OutputFormat = N'Markdown';

Expected result:

    One row / one column containing Markdown report text.

If your build does not yet support a specific output format, the procedure should return a clear validation or not-supported message.

---

## 13. Findings

A finding is a DBA-facing observation generated from collected data.

A finding should answer:

- What happened?
- How severe is it?
- How confident is the tool?
- What evidence supports it?
- What should the DBA do next?

Common finding fields may include:

    RuleId
    Severity
    Confidence
    EvidenceType
    Category
    Title
    Summary
    Evidence
    Recommendation
    FirstSeenUtc
    LastSeenUtc

Severity values:

    Informational
    Low
    Medium
    High
    Critical

Confidence values may include:

    Low
    Medium
    High

Evidence types may include:

    Observed
    Inferred
    Heuristic

### Interpreting severity

| Severity | Meaning |
|---|---|
| Informational | Useful context, coverage warning, or no-action status |
| Low | Minor concern or early warning |
| Medium | Worth DBA review |
| High | Likely actionable issue |
| Critical | Urgent condition or report-quality blocker |

### Interpreting confidence

| Confidence | Meaning |
|---|---|
| High | Strong direct evidence |
| Medium | Evidence is meaningful but may need DBA interpretation |
| Low | Weak signal or incomplete context |

---

## 14. Timeline

Timeline output shows important events in chronological order.

Examples:

- Snapshot captured
- Collector skipped
- Blocking observed
- Restart detected
- Report coverage gap

Timeline is useful when investigating:

- when a problem began
- whether symptoms changed over time
- whether the server restarted during the window
- whether collectors were skipped
- whether data coverage is sufficient

---

## 15. Configure mode

Configure mode reads and updates SQLFlightRecorder settings stored in:

    dbo.FR_Config

Read current configuration:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';

You can also view configuration through Status:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

### Updating configuration

If your procedure supports `@ConfigKey` and `@ConfigValue`, update a known key like this:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'SnapshotRetentionDays',
        @ConfigValue = N'14';

Note: Some earlier examples may use `RetentionDays`. Use the actual key present in `FR_Config`. In the current schema, the expected snapshot retention key is usually `SnapshotRetentionDays`.

Verify:

    SELECT 
        ConfigKey,
        ConfigValue,
        Description,
        ModifiedUtc
    FROM dbo.FR_Config
    WHERE ConfigKey = N'SnapshotRetentionDays';

### Common configuration keys

Your build may include keys such as:

| Key | Purpose |
|---|---|
| `SchemaVersion` | Installed repository schema version |
| `SnapshotIntervalSeconds` | Intended collection interval |
| `SnapshotRetentionDays` | How long snapshot data is retained (allowed range 1–31) |
| `RunLogRetentionDays` | How long run-log data is retained (allowed range 1–124) |
| `MaxRowsPerCollector` | Per-collector row limit |
| `RepositoryTableWarnRows` | Row threshold for the Status repository-size warning |
| `DisabledRules` | Semicolon-delimited list of disabled rule IDs |

Retention values are validated: out-of-range values are refused with a clean
error and `FR_Config` is not updated. SQLFlightRecorder is an operational
diagnostic recorder, not a long-term warehouse — longer retention increases
repository size and report cost.

### Configure safety expectations

Configure should:

- allow only known config keys
- validate values where possible
- refuse unknown keys cleanly
- audit changes in `FR_RunLog`
- avoid changing schema objects

### Invalid key test

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'DoesNotExist',
        @ConfigValue = N'123';

Expected result:

    Clean error or refusal.
    No unknown row inserted into FR_Config.

---

## 16. Purge mode

Purge mode removes old repository data according to retention settings.

**Purge is mandatory operational maintenance.** Without it, `FR_*` tables grow
without bound (tens of millions of rows have been observed in the field) and
Report becomes slow or stops returning quickly. Agent-based installs created
with `@CreateAgentJob = 1` run purge automatically — a Purge step after every
Collect plus a daily backstop job. Every other install must schedule
`Purge @WhatIf = 0` externally, at least daily.

Preview what a purge would remove:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 1;

Expected behavior:

- Returns what would be deleted.
- Does not delete data.
- Shows exact counts or estimated counts depending on implementation.

### Run purge

The real run deletes expired rows (`@WhatIf = 0` is the default, shown
explicitly here for clarity):

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 0;

### Purge should be safe

Purge should:

- delete in batches
- delete child rows before parent rows
- avoid `TRUNCATE`
- avoid database shrink
- avoid index rebuilds
- respect retention config
- write run-log information
- be safe to interrupt between batches

### Typical purge dependency order

The exact order depends on table constraints, but conceptually child tables should be purged before parent tables:

    FR_InstanceSnapshot
    FR_Configuration
    FR_Request
    FR_Wait
    FR_FileStat
    FR_PerfCounter
    FR_Snapshot
    FR_QueryText orphan cleanup
    FR_RunLogStep
    FR_RunLog

### Configure retention

Example:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'SnapshotRetentionDays',
        @ConfigValue = N'7';

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'RunLogRetentionDays',
        @ConfigValue = N'28';

Then preview:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 1;

---

## 17. SQL Agent scheduling

SQLFlightRecorder can be run manually, but scheduled collection is usually more useful.

A typical schedule is:

- Run Collect every 1 minute.
- Run Purge after each collect and daily as a backstop.
- Run Report manually during investigation.

### Important

SQL Agent job creation should be explicit opt-in only.

Do not assume the Agent jobs exist unless you created them.

### Create the Agent jobs

If your procedure supports `@CreateAgentJob`, use:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Install',
        @CreateAgentJob = 1;

This creates or updates **two** jobs, idempotently (re-running never
duplicates a job, step, or schedule):

| Job | Schedule | Steps |
|---|---|---|
| `SQLFlightRecorder Collect` | Every minute | 1. Collect, 2. Purge (`@WhatIf = 0`) as cleanup |
| `SQLFlightRecorder Purge` | Daily at 02:30 server time | Purge (`@WhatIf = 0`) — retention backstop |

The daily job protects you if the collector job is disabled, changed, or fails
before its cleanup step. Re-running Install on an older repository upgrades an
existing single-step collector job in place by adding the Purge step.

If your build uses a different parameter or mode for scheduling, use Help to confirm:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';

### Verify jobs exist

    SELECT 
        j.name,
        j.enabled,
        j.date_created,
        j.date_modified
    FROM msdb.dbo.sysjobs AS j
    WHERE j.name LIKE N'%SQLFlightRecorder%';

Verify the collector job's steps:

    SELECT 
        j.name AS JobName,
        s.step_id,
        s.step_name,
        s.database_name,
        s.command
    FROM msdb.dbo.sysjobsteps AS s
    JOIN msdb.dbo.sysjobs AS j
        ON j.job_id = s.job_id
    WHERE j.name LIKE N'%SQLFlightRecorder%'
    ORDER BY j.name, s.step_id;

View schedules:

    SELECT 
        j.name AS JobName,
        s.name AS ScheduleName,
        s.freq_type,
        s.freq_subday_type,
        s.freq_subday_interval,
        s.enabled
    FROM msdb.dbo.sysjobs AS j
    JOIN msdb.dbo.sysjobschedules AS js
        ON js.job_id = j.job_id
    JOIN msdb.dbo.sysschedules AS s
        ON s.schedule_id = js.schedule_id
    WHERE j.name LIKE N'%SQLFlightRecorder%';

### Run jobs manually

    EXEC msdb.dbo.sp_start_job
        @job_name = N'SQLFlightRecorder Collect';

    EXEC msdb.dbo.sp_start_job
        @job_name = N'SQLFlightRecorder Purge';

If your implementation uses different job names, adjust the commands.

### Disable a job

    EXEC msdb.dbo.sp_update_job
        @job_name = N'SQLFlightRecorder Collect',
        @enabled = 0;

If you disable the collector job, keep the daily purge job enabled (or purge
externally) so the repository stays bounded.

### Delete jobs manually

Normally, `Uninstall` removes both jobs created by SQLFlightRecorder.

If manual cleanup is required:

    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLFlightRecorder Collect';

    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLFlightRecorder Purge';

Use this only if you verified the jobs belong to SQLFlightRecorder.

### Environments without SQL Agent

SQL Agent may be unavailable in:

- SQL Server Express
- Azure SQL Database
- Some container environments
- Some locked-down servers

In those environments, schedule **both Collect and Purge** externally, for example:

- Windows Task Scheduler plus sqlcmd
- Linux cron plus sqlcmd
- DBA automation tool
- Azure Automation or Elastic Jobs where appropriate

Example sqlcmd commands:

    sqlcmd -S MyServer -d MyDatabase -E -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';"
    sqlcmd -S MyServer -d MyDatabase -E -Q "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;"

See docs/operations/scheduling.md for per-platform recipes.

---

## 18. Uninstall mode

Uninstall removes SQLFlightRecorder repository objects.

Always preview first:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall',
        @WhatIf = 1;

Expected output:

    Objects that would be dropped or archived.

### Normal uninstall

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall';

Expected behavior:

- Removes `FR_*` repository tables.
- Removes both SQLFlightRecorder-created Agent jobs (collector and daily
  purge) if this tool created them; missing jobs never fail the uninstall.
- Leaves the stored procedure itself unless your version explicitly drops it.

If you also want to remove the procedure:

    DROP PROCEDURE dbo.sp_SQLFlightRecorder;

### Preserve run log

If supported:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall',
        @PreserveRunLog = 1;

Expected behavior:

- Drops snapshot and collector tables.
- Archives or renames `FR_RunLog` and `FR_RunLogStep`.
- Removes active repository tables.
- Leaves archived run-log tables for audit/reference.

### Verify uninstall

    SELECT 
        s.name AS SchemaName,
        o.name AS ObjectName,
        o.type_desc AS ObjectType
    FROM sys.objects AS o
    JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.name LIKE N'FR[_]%'
    ORDER BY o.name;

After normal uninstall, expected result:

    0 rows

After preserve-run-log uninstall, expected result may include archived run-log tables.

---

## 19. Manual smoke test

Use this sequence in a disposable test database.

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
    WAITFOR DELAY '00:00:05';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 1;

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall',
        @WhatIf = 1;

Only after reviewing the output:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';
---

## 20. Troubleshooting

### Procedure does not exist

Symptom:

    Could not find stored procedure 'dbo.sp_SQLFlightRecorder'.

Fix:

Run the full procedure file first:

    sp_SQLFlightRecorder.sql

Then confirm:

    SELECT OBJECT_ID(N'dbo.sp_SQLFlightRecorder', N'P') AS ProcedureObjectId;

---

### Install refuses to run in system database

Symptom:

    Install is allowed only in a user database.

Fix:

Connect to a user database and run the procedure file there.

Recommended:

    USE YourUserDatabase;
    GO

Then run:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';

Avoid installing repository tables in:

- master
- model
- msdb
- tempdb
- distribution

unless your version explicitly documents and supports that install target.

---

### Missing VIEW SERVER STATE

Symptom:

    Requires VIEW SERVER STATE permission.

Fix:

Ask a sysadmin to grant:

    GRANT VIEW SERVER STATE TO [YourLoginOrUser];

In some environments, this permission may be restricted by policy.

Without this permission, collection may not be able to read required SQL Server diagnostic views.

---

### Database is read-only

Symptom:

    Database must be READ_WRITE.

Fix:

Install SQLFlightRecorder in a writable user database.

For Always On Availability Groups, make sure you are connected to a writable primary replica if the repository is installed in that database.

---

### Status fails before Install

Some versions may expect repository tables to exist before `Status` returns full output.

Fix:

Run:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';

Then:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

If Status is intended to work before Install in your version, this should be reported as a bug.

---

### Collect returns Skipped

Possible cause:

    Another collection is already running.

This is usually expected if the applock concurrency guard is working.

Check recent runs:

    SELECT TOP (20)
        RunId,
        StartUtc,
        EndUtc,
        Mode,
        Status,
        Reason,
        ErrorMessage
    FROM dbo.FR_RunLog
    ORDER BY RunId DESC;

If many runs are skipped, check whether:

- SQL Agent schedule is too frequent
- Collect is taking too long
- a previous session is stuck
- blocking exists in the database

---

### Collect returns PartialSuccess

PartialSuccess means at least one collector failed or was skipped, but the procedure continued.

Inspect step details:

    SELECT TOP (100)
        s.RunStepId,
        s.RunId,
        s.StepName,
        s.StartUtc,
        s.EndUtc,
        s.Status,
        s.RowsCollected,
        s.Reason,
        s.ErrorMessage
    FROM dbo.FR_RunLogStep AS s
    ORDER BY s.RunStepId DESC;

Common causes:

- missing permissions
- DMV unavailable on this SQL Server version
- unsupported platform feature
- transient metadata access issue
- timeout

---

### Report says insufficient data

Reports are more useful with at least two snapshots.

Fix:

Run:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

    WAITFOR DELAY '00:00:05';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

Then:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';

For normal usage, collect every minute for a useful incident window.

---

### Report returns no findings

This can be normal.

Possible explanations:

- the selected time window has no significant issues
- insufficient snapshots
- relevant rules are disabled
- the needed collector did not capture rows
- severity filter is too high
- report window is wrong

Try:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @MinSeverity = N'Informational',
        @MaxFindings = 200;

Check available snapshots:

    SELECT 
        MIN(SnapshotUtc) AS FirstSnapshotUtc,
        MAX(SnapshotUtc) AS LastSnapshotUtc,
        COUNT(*) AS SnapshotCount
    FROM dbo.FR_Snapshot;

---

### Configure refuses an unknown key

This is expected.

SQLFlightRecorder should allow only known configuration keys.

List current keys:

    SELECT 
        ConfigKey,
        ConfigValue,
        Description
    FROM dbo.FR_Config
    ORDER BY ConfigKey;

Use one of the listed keys.

---

### Purge preview shows too many rows

Check retention settings:

    SELECT 
        ConfigKey,
        ConfigValue
    FROM dbo.FR_Config
    WHERE ConfigKey IN
    (
        N'SnapshotRetentionDays',
        N'RunLogRetentionDays'
    );

If needed, update retention before purge:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'SnapshotRetentionDays',
        @ConfigValue = N'14';

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Configure',
        @ConfigKey = N'RunLogRetentionDays',
        @ConfigValue = N'56';

Then preview again:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 1;

---

### Uninstall fails because of foreign keys

Uninstall must drop objects in dependency order.

Correct conceptual order:

    FR_InstanceSnapshot
    FR_Configuration
    FR_Request
    FR_Wait
    FR_FileStat
    FR_PerfCounter
    FR_QueryText
    FR_Snapshot
    FR_RunLogStep
    FR_RunLog
    FR_Rules
    FR_Config

If `@PreserveRunLog = 1`, snapshot children and `FR_Snapshot` must be removed before archiving or renaming `FR_RunLogStep` and `FR_RunLog`.

If uninstall fails, capture the error and check for remaining objects:

    SELECT 
        s.name AS SchemaName,
        o.name AS ObjectName,
        o.type_desc AS ObjectType
    FROM sys.objects AS o
    JOIN sys.schemas AS s
        ON s.schema_id = o.schema_id
    WHERE o.name LIKE N'FR[_]%'
    ORDER BY o.name;

---

### SQL Agent job was not created

Possible causes:

- `@CreateAgentJob` was not provided or is not supported by your build
- SQL Agent is not installed or running
- SQL Server Express
- Azure SQL Database
- insufficient permissions in `msdb`
- job name already exists

Check whether SQL Agent jobs are available:

    SELECT 
        SERVERPROPERTY(N'Edition') AS Edition,
        SERVERPROPERTY(N'EngineEdition') AS EngineEdition;

Check for an existing job:

    SELECT 
        name,
        enabled,
        date_created,
        date_modified
    FROM msdb.dbo.sysjobs
    WHERE name LIKE N'%SQLFlightRecorder%';

---

### SQL Agent job exists but does not collect

Check job history:

    SELECT TOP (50)
        j.name AS JobName,
        h.step_id,
        h.step_name,
        h.run_date,
        h.run_time,
        h.run_duration,
        h.run_status,
        h.message
    FROM msdb.dbo.sysjobhistory AS h
    JOIN msdb.dbo.sysjobs AS j
        ON j.job_id = h.job_id
    WHERE j.name LIKE N'%SQLFlightRecorder%'
    ORDER BY h.instance_id DESC;

Check whether the job points to the correct database:

    SELECT 
        j.name AS JobName,
        s.step_id,
        s.step_name,
        s.database_name,
        s.command
    FROM msdb.dbo.sysjobsteps AS s
    JOIN msdb.dbo.sysjobs AS j
        ON j.job_id = s.job_id
    WHERE j.name LIKE N'%SQLFlightRecorder%';

The command should call:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

in the database where the procedure and repository are installed.

---

## 21. Operational recommendations

### Start small

First test in a disposable database:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';

Then test on a non-production server with a real workload.

### Keep collection interval reasonable

A typical interval is:

    60 seconds

Avoid very aggressive schedules unless you have measured overhead.

### Use UTC

SQLFlightRecorder uses UTC timestamps. This makes reports consistent across time zones and daylight-saving changes.

When investigating an incident, convert local times to UTC before passing `@StartTime` and `@EndTime`.

### Keep retention bounded

Recommended starting point:

    SnapshotRetentionDays = 7
    RunLogRetentionDays = 28

Allowed ranges (enforced by Configure): `SnapshotRetentionDays` 1–31,
`RunLogRetentionDays` 1–124. SQLFlightRecorder is an operational diagnostic
recorder, not a long-term warehouse — longer retention increases repository
size and report cost. Export data you need to keep longer.

Adjust based on:

- server size
- incident response needs
- available storage
- collection frequency

### Purge regularly

Purge is mandatory maintenance, not optional cleanup. Agent-based installs
(`@CreateAgentJob = 1`) purge automatically after each collect plus daily;
all other installs must schedule it themselves, usually daily:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;

Preview what a run would remove at any time:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;

`Status` includes a retention-health result set that warns when purge is not
keeping up or when an `FR_*` table grows past `RepositoryTableWarnRows`. If the
repository has already grown huge, run purge repeatedly (or let the daily job
catch up) — it deletes in bounded batches and converges.

### Do not edit repository tables casually

Avoid manual updates/deletes to `FR_*` tables unless troubleshooting.

Use:

- Configure for settings
- Purge for cleanup
- Uninstall for removal

---

## 22. Manual validation checklist

Before using SQLFlightRecorder on an important system, verify:

- [ ] Procedure file runs successfully.
- [ ] `Help` returns usage.
- [ ] `About` returns version/build metadata.
- [ ] `Install` succeeds.
- [ ] Running `Install` twice is safe.
- [ ] `Status` returns useful output.
- [ ] `Collect` succeeds.
- [ ] Running `Collect` twice creates at least two snapshots.
- [ ] `Report` works after two snapshots.
- [ ] `Configure` can read config.
- [ ] Known config key update works.
- [ ] Unknown config key is refused.
- [ ] `Purge @WhatIf = 1` previews without deleting.
- [ ] SQL Agent job creation works, if used (collector job with Collect + Purge steps, plus the daily purge job).
- [ ] Re-running Install with `@CreateAgentJob = 1` does not duplicate jobs, steps, or schedules.
- [ ] SQL Agent jobs run against the correct database, if used.
- [ ] `Uninstall @WhatIf = 1` previews objects.
- [ ] `Uninstall` removes repository objects.
- [ ] `Uninstall @PreserveRunLog = 1` works, if used.

---

## 23. Minimal first-run script

Use this on a disposable database:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
    WAITFOR DELAY '00:00:05';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Report',
        @MinSeverity = N'Informational',
        @OutputFormat = N'Default';

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Purge',
        @WhatIf = 1;

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall',
        @WhatIf = 1;

Do not run the final uninstall until you are ready:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';

---

## 24. Support and issue reporting

When reporting a problem, include:

- SQL Server version and edition
- operating system
- database compatibility level
- SQLFlightRecorder version from `About`
- exact command run
- exact error message
- relevant `FR_RunLog` rows
- relevant `FR_RunLogStep` rows
- whether SQL Agent is involved
- whether the server is Azure SQL, Managed Instance, Express, Linux, or Windows

Useful diagnostic queries:

    EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
    EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';

    SELECT TOP (20)
        *
    FROM dbo.FR_RunLog
    ORDER BY RunId DESC;

    SELECT TOP (100)
        *
    FROM dbo.FR_RunLogStep
    ORDER BY RunStepId DESC;

---

## 25. Removal summary

To remove repository data:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall';

To preserve run-log tables if supported:

    EXEC dbo.sp_SQLFlightRecorder
        @Mode = N'Uninstall',
        @PreserveRunLog = 1;

To remove the procedure itself:

    DROP PROCEDURE dbo.sp_SQLFlightRecorder;

Verify:

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

---

## 26. Final notes

SQLFlightRecorder is intended to help DBAs capture short, useful diagnostic history without installing a large monitoring platform.

It is not a replacement for:

- full observability platforms
- Query Store analysis
- Extended Events incident traces
- vendor monitoring tools
- DBA judgment

Use it as a lightweight incident recorder and triage assistant.

Always test first.
