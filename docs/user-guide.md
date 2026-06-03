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

Some builds may also create a SQL Agent job if you explicitly request scheduled collection.

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
src/sp_SQLFlightRecorder.sql
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

Continue with **Chunk 2 of 3** when ready.
