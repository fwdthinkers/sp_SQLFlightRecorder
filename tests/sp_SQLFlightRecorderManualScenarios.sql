
/*==============================================================================
sp_SQLFlightRecorder Manual Scenario Test Script

Purpose:
  Test dbo.sp_SQLFlightRecorder modes and parameters in one disposable database.

Important:
  Run this in a NON-PRODUCTION test database first.
  By default, destructive tests are OFF.
  Set @RunDestructiveTests = 1 only when you are ready to test Purge/Uninstall.
  Set @TestAgentJob = 1 only on a SQL Server instance where SQL Agent is available.

Expected:
  Most scenarios should return Success, Status output, validation errors, or clean
  NotSupported/Skipped messages. No scenario should produce an unhandled crash.

==============================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @RunDestructiveTests bit = 1; -- 0=safe default, 1=run real Purge/Uninstall tests
DECLARE @TestAgentJob        bit = 1; -- 0=skip Agent job test, 1=test @CreateAgentJob if supported

DECLARE @ProcName sysname = N'dbo.sp_SQLFlightRecorder';

IF OBJECT_ID(@ProcName, N'P') IS NULL
BEGIN
    RAISERROR('dbo.sp_SQLFlightRecorder does not exist in this database. Run sp_SQLFlightRecorder.sql first.', 16, 1);
    RETURN;
END;

IF OBJECT_ID('tempdb..#TestLog') IS NOT NULL DROP TABLE #TestLog;
CREATE TABLE #TestLog
(
    TestId       int IDENTITY(1,1) PRIMARY KEY,
    Scenario     nvarchar(200) NOT NULL,
    Expected     nvarchar(1000) NULL,
    Status       nvarchar(20) NOT NULL,
    ErrorNumber  int NULL,
    ErrorMessage nvarchar(max) NULL,
    StartedAt    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    EndedAt      datetime2(3) NULL
);

IF OBJECT_ID('tempdb..#Cases') IS NOT NULL DROP TABLE #Cases;
CREATE TABLE #Cases
(
    CaseId        int IDENTITY(1,1) PRIMARY KEY,
    Scenario      nvarchar(200) NOT NULL,
    Expected      nvarchar(1000) NULL,
    SqlText       nvarchar(max) NOT NULL,
    IsDestructive bit NOT NULL DEFAULT 0,
    IsAgent       bit NOT NULL DEFAULT 0
);

DECLARE
    @HasConfigKey     bit = CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(@ProcName) AND name = N'@ConfigKey') THEN 1 ELSE 0 END,
    @HasConfigValue   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(@ProcName) AND name = N'@ConfigValue') THEN 1 ELSE 0 END,
    @HasCreateAgentJob bit = CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(@ProcName) AND name = N'@CreateAgentJob') THEN 1 ELSE 0 END;

/*------------------------------------------------------------------------------
Scenario: About.
Expected: Version/build metadata result set.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'About mode', N'Returns version/build metadata.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''About'';');

/*------------------------------------------------------------------------------
Scenario: Version alias.
Expected: Same or similar output as About, if alias is supported.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Version alias', N'Returns About/version metadata or clean validation response.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Version'';');

/*------------------------------------------------------------------------------
Scenario: Help default.
Expected: Help output. No repository changes required.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Help default mode', N'Returns/prints help text.',
 N'EXEC dbo.sp_SQLFlightRecorder;');

/*------------------------------------------------------------------------------
Scenario: Help explicit.
Expected: Help output.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Help explicit mode', N'Returns/prints help text.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Help'';');

/*------------------------------------------------------------------------------
Scenario: Unknown mode.
Expected: Clean validation error, not an unhandled exception.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Invalid @Mode', N'Clean UnknownMode/validation response.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''BadMode'';');

/*------------------------------------------------------------------------------
Scenario: Invalid @MinSeverity.
Expected: Clean validation error.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Invalid @MinSeverity', N'Clean InvalidMinSeverity response.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''Severe'';');

/*------------------------------------------------------------------------------
Scenario: Valid @MinSeverity values.
Expected: Each accepted; Report may return findings or insufficient-data output.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@MinSeverity Informational', N'Accepted or clean Report response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''Informational'';'),
(N'@MinSeverity Low',           N'Accepted or clean Report response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''Low'';'),
(N'@MinSeverity Medium',        N'Accepted or clean Report response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''Medium'';'),
(N'@MinSeverity High',          N'Accepted or clean Report response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''High'';'),
(N'@MinSeverity Critical',      N'Accepted or clean Report response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MinSeverity = N''Critical'';');

/*------------------------------------------------------------------------------
Scenario: @MaxFindings bounds.
Expected: 10 and 2000 accepted; 9 and 2001 rejected cleanly.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@MaxFindings lower valid',   N'Accepted.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MaxFindings = 10;'),
(N'@MaxFindings upper valid',   N'Accepted.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MaxFindings = 2000;'),
(N'@MaxFindings too low',       N'Clean validation response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MaxFindings = 9;'),
(N'@MaxFindings too high',      N'Clean validation response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @MaxFindings = 2001;');

/*------------------------------------------------------------------------------
Scenario: @TopN bounds.
Expected: 1 and 1000 accepted; 0 and 1001 rejected cleanly.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@TopN lower valid', N'Accepted.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'', @TopN = 1;'),
(N'@TopN upper valid', N'Accepted.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'', @TopN = 1000;'),
(N'@TopN too low',     N'Clean validation response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'', @TopN = 0;'),
(N'@TopN too high',    N'Clean validation response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'', @TopN = 1001;');

/*------------------------------------------------------------------------------
Scenario: @OutputFormat values.
Expected: Valid formats accepted; invalid rejected cleanly.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@OutputFormat Default',      N'Returns default Report output.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''Default'';'),
(N'@OutputFormat FindingsOnly', N'Returns findings only or clean no-data response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''FindingsOnly'';'),
(N'@OutputFormat TimelineOnly', N'Returns timeline only or clean no-data response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''TimelineOnly'';'),
(N'@OutputFormat Markdown',     N'Returns Markdown report or clean no-data response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''Markdown'';'),
(N'Invalid @OutputFormat',      N'Clean InvalidOutputFormat response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''Json'';');

/*------------------------------------------------------------------------------
Scenario: @StartTime and @EndTime validation.
Expected: Valid window accepted; invalid window rejected cleanly.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Valid @StartTime/@EndTime', N'Accepted; report for window or clean no-data response.',
 N'DECLARE @s datetime2(3)=DATEADD(hour,-1,SYSUTCDATETIME()), @e datetime2(3)=SYSUTCDATETIME();
   EXEC dbo.sp_SQLFlightRecorder @Mode=N''Report'', @StartTime=@s, @EndTime=@e;'),
(N'Invalid @StartTime >= @EndTime', N'Clean InvalidTimeWindow response.',
 N'DECLARE @s datetime2(3)=SYSUTCDATETIME(), @e datetime2(3)=DATEADD(hour,-1,SYSUTCDATETIME());
   EXEC dbo.sp_SQLFlightRecorder @Mode=N''Report'', @StartTime=@s, @EndTime=@e;');

/*------------------------------------------------------------------------------
Scenario: @DatabaseName filter.
Expected: Accepted; filters report or returns clean no-data response.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@DatabaseName current database', N'Accepted; report scoped/filtered if implemented.',
 N'DECLARE @db sysname = DB_NAME();
   EXEC dbo.sp_SQLFlightRecorder @Mode=N''Report'', @DatabaseName=@db;');

/*------------------------------------------------------------------------------
Scenario: @IncludeQueryPlans.
Expected: 0 and 1 accepted; 1 may be no-op if no plan source exists.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'@IncludeQueryPlans 0', N'Accepted.', N'EXEC dbo.sp_SQLFlightRecorder @Mode=N''Report'', @IncludeQueryPlans=0;'),
(N'@IncludeQueryPlans 1', N'Accepted or clean no-op/not-supported response.', N'EXEC dbo.sp_SQLFlightRecorder @Mode=N''Report'', @IncludeQueryPlans=1;');

/*------------------------------------------------------------------------------
Scenario: Install.
Expected: Creates/updates FR_* repository objects.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Install mode', N'Creates FR_* repository tables and seed rows.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install'';');

/*------------------------------------------------------------------------------
Scenario: Install idempotency.
Expected: Second install succeeds without duplicate seed rows.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Install idempotency', N'Second install succeeds without duplicate config/rule seed data.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install'';');

/*------------------------------------------------------------------------------
Scenario: Verify FR_* objects.
Expected: Repository tables are present after Install.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Verify installed FR objects', N'Shows installed FR_* objects.',
 N'SELECT s.name AS SchemaName, o.name AS ObjectName, o.type_desc
   FROM sys.objects AS o
   JOIN sys.schemas AS s ON s.schema_id = o.schema_id
   WHERE o.name LIKE N''FR[_]%''
   ORDER BY o.name;');

/*------------------------------------------------------------------------------
Scenario: Status.
Expected: Returns repository/config/rules/run/footprint/capability status.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Status mode', N'Returns status result sets.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Status'';');

/*------------------------------------------------------------------------------
Scenario: Collect.
Expected: Writes run log, run steps, snapshot, and collector rows if supported.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Collect mode', N'Writes one collection run and snapshot data.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'';');

/*------------------------------------------------------------------------------
Scenario: Second Collect.
Expected: Creates another snapshot so Report has at least two points.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Second Collect after short delay', N'Creates second snapshot.',
 N'WAITFOR DELAY ''00:00:05'';
   EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'';');

/*------------------------------------------------------------------------------
Scenario: @Debug with Collect.
Expected: Debug behavior or CollectDebug path; no repository corruption.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Collect with @Debug = 1', N'Accepted; emits debug/run-log behavior without corruption.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect'', @Debug = 1;');

/*------------------------------------------------------------------------------
Scenario: CollectDebug.
Expected: Safe diagnostic run; no unhandled exception.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'CollectDebug mode', N'Runs diagnostic collect/debug behavior safely.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''CollectDebug'';');

/*------------------------------------------------------------------------------
Scenario: Verify collection rows.
Expected: Row counts show snapshots, run logs, and collector rows.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Verify collection row counts', N'Shows row counts in repository tables.',
 N'
 SELECT N''FR_RunLog'' AS TableName, COUNT(*) AS [RowCount] FROM dbo.FR_RunLog
 UNION ALL SELECT N''FR_RunLogStep'', COUNT(*) FROM dbo.FR_RunLogStep
 UNION ALL SELECT N''FR_Snapshot'', COUNT(*) FROM dbo.FR_Snapshot
 UNION ALL SELECT N''FR_InstanceSnapshot'', COUNT(*) FROM dbo.FR_InstanceSnapshot
 UNION ALL SELECT N''FR_Configuration'', COUNT(*) FROM dbo.FR_Configuration
 UNION ALL SELECT N''FR_Request'', COUNT(*) FROM dbo.FR_Request
 UNION ALL SELECT N''FR_Wait'', COUNT(*) FROM dbo.FR_Wait
 UNION ALL SELECT N''FR_FileStat'', COUNT(*) FROM dbo.FR_FileStat
 UNION ALL SELECT N''FR_PerfCounter'', COUNT(*) FROM dbo.FR_PerfCounter;
 ');

/*------------------------------------------------------------------------------
Scenario: Report default after snapshots.
Expected: Findings/timeline or clean no-findings/insufficient-data response.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Report default after collect', N'Returns report output.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Report'', @OutputFormat = N''Default'', @MinSeverity = N''Informational'';');

/*------------------------------------------------------------------------------
Scenario: Configure read.
Expected: Returns current FR_Config.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Configure read', N'Returns current configuration.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Configure'';');

/*------------------------------------------------------------------------------
Scenario: Configure known key.
Expected: Updates SnapshotRetentionDays if @ConfigKey/@ConfigValue are supported.
------------------------------------------------------------------------------*/
IF @HasConfigKey = 1 AND @HasConfigValue = 1
BEGIN
    INSERT #Cases (Scenario, Expected, SqlText)
    VALUES
    (N'Configure update SnapshotRetentionDays', N'Updates known config key and audits change.',
     N'EXEC dbo.sp_SQLFlightRecorder
           @Mode = N''Configure'',
           @ConfigKey = N''SnapshotRetentionDays'',
           @ConfigValue = N''7'';

       SELECT ConfigKey, ConfigValue, ModifiedUtc
       FROM dbo.FR_Config
       WHERE ConfigKey = N''SnapshotRetentionDays'';');

    INSERT #Cases (Scenario, Expected, SqlText)
    VALUES
    (N'Configure invalid key', N'Clean refusal; no unknown config row inserted.',
     N'EXEC dbo.sp_SQLFlightRecorder
           @Mode = N''Configure'',
           @ConfigKey = N''DoesNotExist'',
           @ConfigValue = N''123'';

       SELECT *
       FROM dbo.FR_Config
       WHERE ConfigKey = N''DoesNotExist'';');

    INSERT #Cases (Scenario, Expected, SqlText)
    VALUES
    (N'Configure retention out of range', N'Clean refusal (SnapshotRetentionDays allows 1-31, RunLogRetentionDays 1-124); FR_Config is not updated.',
     N'EXEC dbo.sp_SQLFlightRecorder
           @Mode = N''Configure'',
           @ConfigKey = N''SnapshotRetentionDays'',
           @ConfigValue = N''365'';

       EXEC dbo.sp_SQLFlightRecorder
           @Mode = N''Configure'',
           @ConfigKey = N''RunLogRetentionDays'',
           @ConfigValue = N''0'';

       SELECT ConfigKey, ConfigValue, ModifiedUtc
       FROM dbo.FR_Config
       WHERE ConfigKey IN (N''SnapshotRetentionDays'', N''RunLogRetentionDays'');');
END
ELSE
BEGIN
    INSERT #Cases (Scenario, Expected, SqlText)
    VALUES
    (N'Configure write skipped', N'Procedure does not declare @ConfigKey/@ConfigValue.',
     N'SELECT N''Skipped'' AS Status, N''@ConfigKey/@ConfigValue not declared.'' AS Message;');
END;

/*------------------------------------------------------------------------------
Scenario: Purge @WhatIf.
Expected: Preview only; no deletes.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Purge @WhatIf = 1', N'Preview purge counts/actions; no data deleted.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Purge'', @WhatIf = 1;');

/*------------------------------------------------------------------------------
Scenario: Purge real.
Expected: Deletes only expired data in batches. Destructive; off by default.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText, IsDestructive)
VALUES
(N'Purge @WhatIf = 0', N'Destructive: deletes expired repository rows only.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Purge'', @WhatIf = 0;', 1);

/*------------------------------------------------------------------------------
Scenario: Agent job opt-in.
Expected: Creates or updates BOTH jobs (collector with Collect + Purge steps,
plus the daily purge backstop), or a clean unsupported response. Re-running
must not duplicate jobs, steps, or schedules. Agent test is off by default.
------------------------------------------------------------------------------*/
IF @HasCreateAgentJob = 1
BEGIN
    INSERT #Cases (Scenario, Expected, SqlText, IsAgent)
    VALUES
    (N'Install with @CreateAgentJob = 1', N'Creates/updates the SQLFlightRecorder Collect job (Collect + Purge steps) and the SQLFlightRecorder Purge daily job, or a clean unsupported/permission response. Idempotent on re-run.',
     N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install'', @CreateAgentJob = 1;
       EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install'', @CreateAgentJob = 1;

       IF DB_ID(N''msdb'') IS NOT NULL
       BEGIN
           SELECT name, enabled, date_created, date_modified
           FROM msdb.dbo.sysjobs
           WHERE name LIKE N''%SQLFlightRecorder%'';

           SELECT j.name AS JobName, st.step_id, st.step_name, st.on_success_action
           FROM msdb.dbo.sysjobsteps AS st
           JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
           WHERE j.name LIKE N''%SQLFlightRecorder%''
           ORDER BY j.name, st.step_id;
       END;', 1);
END
ELSE
BEGIN
    INSERT #Cases (Scenario, Expected, SqlText)
    VALUES
    (N'Agent job parameter skipped', N'Procedure does not declare @CreateAgentJob.',
     N'SELECT N''Skipped'' AS Status, N''@CreateAgentJob not declared.'' AS Message;');
END;

/*------------------------------------------------------------------------------
Scenario: Uninstall @WhatIf.
Expected: Preview objects/actions only; no objects dropped.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText)
VALUES
(N'Uninstall @WhatIf = 1', N'Preview uninstall actions; no objects dropped.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Uninstall'', @WhatIf = 1;');

/*------------------------------------------------------------------------------
Scenario: Uninstall preserve run log.
Expected: Destructive; archives run-log tables if supported. Off by default.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText, IsDestructive)
VALUES
(N'Uninstall @PreserveRunLog = 1', N'Destructive: removes repository and preserves/archives run log if supported.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Uninstall'', @PreserveRunLog = 1;

   SELECT s.name AS SchemaName, o.name AS ObjectName, o.type_desc
   FROM sys.objects AS o
   JOIN sys.schemas AS s ON s.schema_id = o.schema_id
   WHERE o.name LIKE N''FR[_]%''
   ORDER BY o.name;', 1);

/*------------------------------------------------------------------------------
Scenario: Reinstall after preserve test.
Expected: Recreates repository after uninstall. Destructive group only.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText, IsDestructive)
VALUES
(N'Reinstall after preserve uninstall', N'Repository installs cleanly again.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install'';', 1);

/*------------------------------------------------------------------------------
Scenario: Clean uninstall.
Expected: Destructive; removes all active FR_* repository objects. Off by default.
------------------------------------------------------------------------------*/
INSERT #Cases (Scenario, Expected, SqlText, IsDestructive)
VALUES
(N'Clean Uninstall', N'Destructive: removes active FR_* repository objects.',
 N'EXEC dbo.sp_SQLFlightRecorder @Mode = N''Uninstall'', @PreserveRunLog = 0;

   SELECT s.name AS SchemaName, o.name AS ObjectName, o.type_desc
   FROM sys.objects AS o
   JOIN sys.schemas AS s ON s.schema_id = o.schema_id
   WHERE o.name LIKE N''FR[_]%''
   ORDER BY o.name;', 1);

/*------------------------------------------------------------------------------
Run all selected cases.
Expected: Each case logs PASS if no unhandled exception reached the test harness.
------------------------------------------------------------------------------*/
DECLARE
    @CaseId int,
    @Scenario nvarchar(200),
    @Expected nvarchar(1000),
    @SqlText nvarchar(max),
    @IsDestructive bit,
    @IsAgent bit,
    @LogId int;

DECLARE case_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT CaseId, Scenario, Expected, SqlText, IsDestructive, IsAgent
FROM #Cases
WHERE (@RunDestructiveTests = 1 OR IsDestructive = 0)
  AND (@TestAgentJob = 1 OR IsAgent = 0)
ORDER BY CaseId;

OPEN case_cursor;

FETCH NEXT FROM case_cursor
INTO @CaseId, @Scenario, @Expected, @SqlText, @IsDestructive, @IsAgent;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT REPLICATE(N'=', 90);
    PRINT CONCAT(N'TEST ', @CaseId, N': ', @Scenario);
    PRINT CONCAT(N'EXPECTED: ', @Expected);

    INSERT #TestLog (Scenario, Expected, Status)
    VALUES (@Scenario, @Expected, N'Running');

    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC sys.sp_executesql @SqlText;

        UPDATE #TestLog
        SET Status = N'PASS',
            EndedAt = SYSUTCDATETIME()
        WHERE TestId = @LogId;
    END TRY
    BEGIN CATCH
        UPDATE #TestLog
        SET Status = N'FAIL',
            ErrorNumber = ERROR_NUMBER(),
            ErrorMessage = ERROR_MESSAGE(),
            EndedAt = SYSUTCDATETIME()
        WHERE TestId = @LogId;

        PRINT CONCAT(N'FAILED: ', ERROR_MESSAGE());
    END CATCH;

    FETCH NEXT FROM case_cursor
    INTO @CaseId, @Scenario, @Expected, @SqlText, @IsDestructive, @IsAgent;
END;

CLOSE case_cursor;
DEALLOCATE case_cursor;

/*------------------------------------------------------------------------------
Final summary.
Expected: Review FAIL rows. Validation responses from the procedure can still be PASS.
------------------------------------------------------------------------------*/
SELECT
    TestId,
    Scenario,
    Status,
    ErrorNumber,
    ErrorMessage,
    StartedAt,
    EndedAt
FROM #TestLog
ORDER BY TestId;

/*------------------------------------------------------------------------------
Skipped destructive/Agent reminder.
Expected: Shows whether real Purge/Uninstall/Agent tests were skipped.
------------------------------------------------------------------------------*/
SELECT
    @RunDestructiveTests AS RunDestructiveTests,
    @TestAgentJob AS TestAgentJob,
    @HasConfigKey AS HasConfigKeyParameter,
    @HasConfigValue AS HasConfigValueParameter,
    @HasCreateAgentJob AS HasCreateAgentJobParameter,
    CASE WHEN @RunDestructiveTests = 0 THEN N'Real Purge and Uninstall tests were skipped.' ELSE N'Real destructive tests were enabled.' END AS DestructiveTestStatus,
    CASE WHEN @TestAgentJob = 0 THEN N'Agent job creation test was skipped.' ELSE N'Agent job creation test was enabled.' END AS AgentTestStatus;
