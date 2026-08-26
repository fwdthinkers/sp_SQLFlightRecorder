-- =============================================================================
-- sp_SQLFlightRecorder
-- SQL Server DBA Flight Recorder
-- =============================================================================
-- Developed by: Ysaias Portes
-- Company:      Forward Thinkers Consulting, LLC.
-- Web:          https://www.forwardthinkersconsulting.com/
-- Contact:      contact@forwardthinkersconsulting.com
-- Repository:   https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder
-- License:      MIT
--
-- A single pure-T-SQL stored procedure for capturing bounded SQL Server
-- diagnostic snapshots and producing prioritized DBA findings.
--
-- Current implementation scope:
--   * Help mode: usage and parameter documentation
--   * About mode: version and build metadata
--   * Install mode: idempotent FR_* repository schema creation
--   * Uninstall mode: clean removal with optional run-log archive
--   * Status mode: installation, configuration, rules, run, and footprint status
--   * Collect / CollectDebug / Report / Configure / Purge:
--       implemented as the procedure evolves through the v0.1 roadmap
--
-- Tool-Version:   1.1.0
-- Build-Date-Utc: 2026-08-25
-- Design:         docs/design.md
-- Decisions:      docs/decisions.md
--
-- Compatibility:
--   SQL Server 2012–2025 compatible where practical.
--   Single-file deployment. No preprocessor. No external runtime dependency.
--
-- Safety posture:
--   Default @Mode = 'Help' so accidental execution is non-destructive.
--   Production-oriented defaults: bounded reads, low deadlock priority,
--   lock timeout, READ UNCOMMITTED, and explicit opt-in for destructive modes.
--
-- Notes:
--   This procedure is intended to be installed in a user database by default.
--   Review documentation and test in a non-production environment before use.
-- =============================================================================


SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.sp_SQLFlightRecorder', N'P') IS NULL
    EXEC sys.sp_executesql N'CREATE PROCEDURE dbo.sp_SQLFlightRecorder AS RETURN 0;';
GO

ALTER PROCEDURE dbo.sp_SQLFlightRecorder
    @Mode                 nvarchar(30)   = N'Help'
  , @DatabaseName         sysname        = NULL
  , @StartTime            datetime2(3)   = NULL
  , @EndTime              datetime2(3)   = NULL
  , @MinSeverity          nvarchar(20)   = N'Low'
  , @MaxFindings          int            = 200
  , @TopN                 int            = 50
  , @OutputFormat         nvarchar(20)   = N'Default'
  , @IncludeQueryPlans    bit            = 0
  , @WhatIf               bit            = 0
  , @PreserveRunLog       bit            = 0
  , @Debug                bit            = 0
  , @ConfigKey            sysname        = NULL
  , @ConfigValue          nvarchar(4000) = NULL
  , @CreateAgentJob       bit            = 0
  , @TimeZone             sysname        = NULL
AS
BEGIN
    -- =========================================================================
    -- Session safety primitives (D-132, D-133, D-134)
    -- =========================================================================
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_NULLS ON;
    SET ANSI_WARNINGS ON;
    SET QUOTED_IDENTIFIER ON;
    SET ARITHABORT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    -- =========================================================================
    -- Constants and version info
    -- =========================================================================
    DECLARE @ToolVersion             nvarchar(30)  = N'1.1.0';
    DECLARE @BuildDateUtc            datetime2(3)  = CONVERT(datetime2(3), '2026-08-25T00:00:00');
    -- SchemaVersion 0.5.0: v1.1.0 adds retention/purge-support indexes on the
    -- existing FR_* tables (D-199). Index-only DDL; no table shape changes.
    -- Forward-only (D-038): Install creates the indexes on upgraded
    -- repositories the first time it runs over them.
    DECLARE @SchemaVersion            nvarchar(20) = N'0.5.0';
    -- Rule-pack version is part of the Markdown header contract (D-085).
    -- It names the release that last changed rule logic or the rule catalog
    -- (0.4.3 completed the FR_R0003 escalation before the v1.0 lock). 1.0.0-rc.1
    -- and 1.0.0 are docs/process/version-metadata releases that change no rule
    -- logic or catalog, so the rule-pack version intentionally stays 0.4.3 (not
    -- tracked to ToolVersion — it names the last rule change, D-085).
    DECLARE @RulePackVersion         nvarchar(20)  = N'0.4.3';
    DECLARE @SupportedSqlServerRange nvarchar(50)  = N'SQL Server 2012–2025';
    DECLARE @PartNumber              int           = 1;
    DECLARE @PartTotal               int           = 1;

    -- =========================================================================
    -- Capability probe (D-008, D-111, D-115, D-127) — closed key set
    -- =========================================================================
    DECLARE @EngineEditionProbe   int          = TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition'));
    DECLARE @ProductMajorProbe    int          = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
    DECLARE @ProductLevelProbe    nvarchar(20) = CONVERT(nvarchar(20), SERVERPROPERTY(N'ProductLevel'));
    DECLARE @IsAzureSqlDb         bit          = CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) = 5 THEN 1 ELSE 0 END;
    DECLARE @IsAzureManagedInst   bit          = CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) = 8 THEN 1 ELSE 0 END;
    DECLARE @HasMsdb              bit          = CASE WHEN DB_ID(N'msdb') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasAgent             bit          = CASE WHEN DB_ID(N'msdb') IS NOT NULL AND OBJECT_ID(N'msdb.dbo.sysjobhistory', N'U') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @IsHadrEnabledProbe   bit          = TRY_CONVERT(bit, SERVERPROPERTY(N'IsHadrEnabled'));
    DECLARE @PlatformProbe        nvarchar(20) = N'Windows';
    DECLARE @HasQueryStoreSupport bit          = CASE WHEN ISNULL(@ProductMajorProbe, 0) >= 13
                                                        OR @EngineEditionProbe IN (5, 8)
                                                       THEN 1 ELSE 0 END;
    -- v0.4 capability flags.
    -- AT TIME ZONE is SQL 2016+ (ProductMajorVersion >= 13) and Azure (5/8). Display-only (D-180).
    DECLARE @HasTimeZoneSupport   bit          = CASE WHEN ISNULL(@ProductMajorProbe, 0) >= 13
                                                        OR @EngineEditionProbe IN (5, 8)
                                                       THEN 1 ELSE 0 END;
    -- Advanced HA DMVs exist on Box/MI; Azure SQL DB (edition 5) has no AG DMVs.
    DECLARE @HasAdvancedHaSupport bit          = CASE WHEN @EngineEditionProbe = 5 THEN 0
                                                       WHEN ISNULL(@IsHadrEnabledProbe, 0) = 1 THEN 1
                                                       ELSE 0 END;
    -- Target server memory in MB (used by the buffer pool D-051 gate). Best-effort; safe on all editions.
    DECLARE @TargetServerMemoryMb bigint       = NULL;
    -- Buffer pool descriptors DMV is unavailable on Azure SQL DB (edition 5).
    DECLARE @HasBufferPoolSupport bit          = CASE WHEN @EngineEditionProbe = 5 THEN 0 ELSE 1 END;
    DECLARE @CapabilitySnapshot   nvarchar(max);

    BEGIN TRY
        SELECT @TargetServerMemoryMb = CONVERT(bigint, cntr_value) / 1024
        FROM sys.dm_os_performance_counters
        WHERE RTRIM(counter_name) = N'Target Server Memory (KB)';
    END TRY
    BEGIN CATCH
        SET @TargetServerMemoryMb = NULL;   -- never fail the probe (D-008)
    END CATCH;

    -- Platform detection without @@VERSION parsing: host_platform is available
    -- on SQL 2017+ (sys.dm_os_host_info). Older engines are Windows-only.
    IF OBJECT_ID(N'sys.dm_os_host_info', N'V') IS NOT NULL
       OR EXISTS (SELECT 1 FROM sys.all_objects WHERE name = N'dm_os_host_info')
    BEGIN
        BEGIN TRY
            DECLARE @hostPlat nvarchar(256);
            EXEC sys.sp_executesql
                 N'SELECT @p = host_platform FROM sys.dm_os_host_info;',
                 N'@p nvarchar(256) OUTPUT', @p = @hostPlat OUTPUT;
            IF @hostPlat IS NOT NULL SET @PlatformProbe = CONVERT(nvarchar(20), @hostPlat);
        END TRY
        BEGIN CATCH
            SET @PlatformProbe = N'Windows';
        END CATCH;
    END;

    SET @CapabilitySnapshot = CONCAT(
          N'EngineEdition=', ISNULL(CONVERT(nvarchar(10), @EngineEditionProbe), N''), N';',
          N'ProductMajorVersion=', ISNULL(CONVERT(nvarchar(10), @ProductMajorProbe), N''), N';',
          N'ProductLevel=', ISNULL(@ProductLevelProbe, N''), N';',
          N'Platform=', @PlatformProbe, N';',
          N'IsAzureSqlDb=', CONVERT(nvarchar(1), @IsAzureSqlDb), N';',
          N'IsAzureManagedInstance=', CONVERT(nvarchar(1), @IsAzureManagedInst), N';',
          N'HasMsdb=', CONVERT(nvarchar(1), @HasMsdb), N';',
          N'HasAgent=', CONVERT(nvarchar(1), @HasAgent), N';',
          N'IsHadrEnabled=', ISNULL(CONVERT(nvarchar(1), @IsHadrEnabledProbe), N'0'), N';',
          N'HasQueryStoreSupport=', CONVERT(nvarchar(1), @HasQueryStoreSupport), N';',
          N'HasAdvancedHaSupport=', CONVERT(nvarchar(1), @HasAdvancedHaSupport), N';',
          N'HasBufferPoolSupport=', CONVERT(nvarchar(1), @HasBufferPoolSupport), N';',
          N'HasTimeZoneSupport=', CONVERT(nvarchar(1), @HasTimeZoneSupport), N';',
          N'TargetServerMemoryMb=', ISNULL(CONVERT(nvarchar(20), @TargetServerMemoryMb), N''), N';',
          N'SchemaVersion=', @SchemaVersion);

    -- =========================================================================
    -- Input normalization and validation
    -- =========================================================================
    DECLARE @ModeNormalized nvarchar(30) = LTRIM(RTRIM(ISNULL(@Mode, N'Help')));

    -- Alias 'Version' → 'About'
    IF UPPER(@ModeNormalized) = N'VERSION'
        SET @ModeNormalized = N'About';

    -- @Debug routes Collect to safe CollectDebug (D-128): no collector rows,
    -- a single FR_RunLog row written as Mode = 'CollectDebug'.
    IF UPPER(@ModeNormalized) = N'COLLECT' AND @Debug = 1
        SET @ModeNormalized = N'CollectDebug';

    -- Validate closed set of modes
    IF UPPER(@ModeNormalized) NOT IN (
        N'HELP', N'ABOUT', N'INSTALL', N'UNINSTALL',
        N'STATUS', N'COLLECT', N'REPORT', N'CONFIGURE', N'PURGE',
        N'COLLECTDEBUG', N'COLLECTANDREPORT', N'INSTALLDEMODATA'
    )
    BEGIN
        SELECT
            N'Error' AS Status,
            N'UnknownMode' AS ErrorCode,
            CONCAT(N'@Mode must be Help, About, Install, Uninstall, Status, or other documented mode. You passed: ''', @Mode, N'''.') AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    -- Validate parameters
    IF UPPER(ISNULL(@MinSeverity, N'')) NOT IN (N'INFORMATIONAL', N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')
    BEGIN
        SELECT N'Error' AS Status, N'InvalidMinSeverity' AS ErrorCode,
            N'@MinSeverity must be Informational, Low, Medium, High, or Critical.' AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    IF @MaxFindings IS NULL OR @MaxFindings < 10 OR @MaxFindings > 2000
    BEGIN
        SELECT N'Error' AS Status, N'InvalidMaxFindings' AS ErrorCode,
            N'@MaxFindings must be between 10 and 2000.' AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    IF @TopN IS NULL OR @TopN < 1 OR @TopN > 1000
    BEGIN
        SELECT N'Error' AS Status, N'InvalidTopN' AS ErrorCode,
            N'@TopN must be between 1 and 1000.' AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    IF UPPER(ISNULL(@OutputFormat, N'')) NOT IN (N'DEFAULT', N'FINDINGSONLY', N'TIMELINEONLY', N'MARKDOWN')
    BEGIN
        SELECT N'Error' AS Status, N'InvalidOutputFormat' AS ErrorCode,
            N'@OutputFormat must be Default, FindingsOnly, TimelineOnly, or Markdown.' AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    IF @StartTime IS NOT NULL AND @EndTime IS NOT NULL AND @StartTime >= @EndTime
    BEGIN
        SELECT N'Error' AS Status, N'InvalidTimeWindow' AS ErrorCode,
            N'@StartTime must be strictly less than @EndTime.' AS Message,
            @ToolVersion AS ToolVersion;
        RETURN;
    END;

    -- =========================================================================
    -- Mode: ABOUT
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'ABOUT'
    BEGIN
        SELECT
            @ToolVersion AS ToolVersion,
            @BuildDateUtc AS BuildDateUtc,
            @SupportedSqlServerRange AS SupportedSqlServerRange,
            CONCAT(@PartNumber, N' of ', @PartTotal) AS ImplementationPart,
            CONVERT(nvarchar(50), SYSUTCDATETIME(), 126) + N'Z' AS InvocationUtc;
        RETURN;
    END;

    -- =========================================================================
    -- Mode: HELP
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'HELP'
    BEGIN
        PRINT N'================================================================================';
        PRINT N'sp_SQLFlightRecorder — SQL Server DBA Flight Recorder';
        PRINT CONCAT(N'Version: ', @ToolVersion, N'  |  Part ', @PartNumber, N' of ', @PartTotal);
        PRINT N'================================================================================';
        PRINT N'';
        PRINT N'MODES';
        PRINT N'-----';
        PRINT N'  Help              Default. Print this message.';
        PRINT N'  About             Return version metadata (one-row result set).';
        PRINT N'  Install           Create FR_* schema (idempotent). Part 3.';
        PRINT N'  Uninstall         Drop FR_* schema. Part 3. @WhatIf previews; @PreserveRunLog archives.';
        PRINT N'  Status            Six result sets: config, rules, runs, footprint, etc. Part 3.';
        PRINT N'  Collect           Capture one diagnostic snapshot into FR_* tables.';
        PRINT N'  CollectDebug      Validate collector readiness without writing collector rows.';
        PRINT N'  Report            Read FR_* tables and return Findings + Timeline.';
        PRINT N'  Configure         Read or update known FR_Config keys.';
        PRINT N'  Purge             Batched retention cleanup. Applock-gated; logged. Supports @WhatIf.';
        PRINT N'  CollectAndReport  Bounded Collect then Report in one call (D-024; non-recommended).';
        PRINT N'  InstallDemoData   Insert synthetic demo rows so Report shows sample findings.';
        PRINT N'';
        PRINT N'v0.2 COLLECTORS (run automatically by Collect; capability-gated)';
        PRINT N'-----------------------------------------------------------------';
        PRINT N'  Tempdb, Memory, AgentJobs, BackupHistory, AlwaysOnState, Deadlocks.';
        PRINT N'  Plan collection runs only when @IncludeQueryPlans = 1.';
        PRINT N'';
        PRINT N'v0.2 RULES';
        PRINT N'----------';
        PRINT N'  FR_R0007 BlockingStorm, FR_R0008 TempdbVersionStoreGrowth,';
        PRINT N'  FR_R0009 TempdbFileImbalanceOrPressure, FR_R0010 FailedSqlAgentJobNearIncident,';
        PRINT N'  FR_R0011 MaintenanceJobOverlap, FR_R0012 BackupOverlapWithIncident,';
        PRINT N'  FR_R0013 DeadlocksObserved, FR_R0014 AlwaysOnRoleOrStateChange.';
        PRINT N'';
        PRINT N'v0.3 COLLECTORS (capability-gated; bounded)';
        PRINT N'-------------------------------------------';
        PRINT N'  QueryStore (latest closed interval/DB), PlanCacheSummary, SchemaActivity.';
        PRINT N'  ErrorLog is OPT-IN (FR_Config.CollectErrorLog = 1); OFF by default.';
        PRINT N'';
        PRINT N'v0.3 RULES';
        PRINT N'----------';
        PRINT N'  FR_R0015 QueryPlanRegression, FR_R0016 TopCpuConsumerInWindow,';
        PRINT N'  FR_R0017 QueryStoreDisabledOnUserDbs, FR_R0018 FailedPlanForcing,';
        PRINT N'  FR_R0019 QueryStoreNearingCapacity, FR_R0020 HighCompilationRate.';
        PRINT N'';
        PRINT N'PARAMETERS';
        PRINT N'----------';
        PRINT N'  @Mode             Which mode to run (default: Help).';
        PRINT N'  @MaxFindings      Cap findings at 10–2000 rows (default: 200).';
        PRINT N'  @TopN             Collector-side row cap per category (default: 50).';
        PRINT N'  @OutputFormat     Default, FindingsOnly, TimelineOnly, or Markdown (default: Default).';
        PRINT N'  @IncludeQueryPlans RESERVED; no-op in this build. Plan capture and plan-XML';
        PRINT N'                    analysis are disabled by design (D-015/D-046/D-082/D-136):';
        PRINT N'                    this tool never reads sys.dm_exec_query_plan and never';
        PRINT N'                    shreds plan XML in T-SQL. 1 = emit an honest coverage note.';
        PRINT N'  @DatabaseName     Report: scope DB-bound findings/timeline to one database.';
        PRINT N'                    Instance-level and Coverage findings are always retained.';
        PRINT N'  @MinSeverity      Report filter applied after rules: Informational, Low, Medium,';
        PRINT N'                    High, Critical (default: Low). Critical and Coverage are never hidden.';
        PRINT N'  @Debug            1 with @Mode=Collect routes to safe CollectDebug: no collector';
        PRINT N'                    rows; dynamic SQL is printed, not executed (default: 0).';
        PRINT N'  @WhatIf           Preview without executing (Uninstall, Purge modes).';
        PRINT N'  @PreserveRunLog   Uninstall: 1=archive FR_RunLog with timestamped name (default: 0).';
        PRINT N'  @ConfigKey        Configure mode: key to update. NULL returns all config.';
        PRINT N'  @ConfigValue      Configure mode: value to write for @ConfigKey.';
        PRINT N'  @CreateAgentJob   Install mode: explicit opt-in SQL Agent job creation.';
        PRINT N'';
        PRINT N'CHARTER PILLARS';
        PRINT N'---------------';
        PRINT N'  * Boring, transparent, deterministic behavior.';
        PRINT N'  * Honest: every finding has Severity, Confidence, EvidenceType.';
        PRINT N'  * Safe on production: bounded reads, no plan shredding, READ UNCOMMITTED.';
        PRINT N'  * Compatible: SQL Server 2012–2025 (capability-driven branching, no string parsing).';
        PRINT N'  * Open source first: GitHub-native, DBA-friendly contribution model.';
        PRINT N'';
        PRINT N'v0.4 COLLECTORS (capability-gated; bounded)';
        PRINT N'-------------------------------------------';
        PRINT N'  AdvancedHaState (AG queues/health; non-Azure-DB), BufferPool (opt-in; >256 GB skipped).';
        PRINT N'';
        PRINT N'v0.4 RULES';
        PRINT N'----------';
        PRINT N'  FR_R0021 ConfigurationChangeInWindow, FR_R0022 LogReuseWaitElevated,';
        PRINT N'  FR_R0023 ThreadpoolWaitsObserved, FR_R0024 ResourceSemaphoreWaits,';
        PRINT N'  FR_R0025 RecentCheckDbOrBackupAge, FR_R0026 CoverageAndCapabilitySummary.';
        PRINT N'';
        PRINT N'  @TimeZone         Report: display-only IANA/Windows time zone for Markdown/Status output.';
        PRINT N'                    UTC remains the storage and sort key. Falls back to UTC pre-SQL 2016.';
        PRINT N'================================================================================';
        
        RETURN;
    END;

    -- =========================================================================
    -- Mode: INSTALL
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'INSTALL'
    BEGIN
        -- Validation
        IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb', N'distribution')
        BEGIN
            SELECT N'Error' AS Status, N'SystemDatabaseRefused' AS ErrorCode,
                N'Install is allowed only in a user database (D-004).' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF ISNULL(CONVERT(nvarchar(20), DATABASEPROPERTYEX(DB_NAME(), N'Updateability')), N'') <> N'READ_WRITE'
        BEGIN
            SELECT N'Error' AS Status, N'ReadOnlyDatabaseRefused' AS ErrorCode,
                N'Database must be READ_WRITE.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF NOT EXISTS (
            SELECT 1 FROM sys.fn_my_permissions(NULL, N'SERVER') p
            WHERE p.permission_name = N'VIEW SERVER STATE'
        )
        BEGIN
            SELECT N'Error' AS Status, N'MissingViewServerState' AS ErrorCode,
                N'Requires VIEW SERVER STATE permission (D-118).' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        -- Check existing schema version (D-038, D-039: forward-only, no downgrade)
        DECLARE @ExistingSchemaVersion nvarchar(20) = NULL;
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
        BEGIN
            SELECT @ExistingSchemaVersion = ConfigValue
            FROM dbo.FR_Config
            WHERE ConfigKey = N'SchemaVersion';
        END;

        IF @ExistingSchemaVersion IS NOT NULL AND @ExistingSchemaVersion > @SchemaVersion
        BEGIN
            SELECT N'Error' AS Status, N'DowngradeBlocked' AS ErrorCode,
                CONCAT(N'Existing schema version ', @ExistingSchemaVersion, N' > ', @SchemaVersion, N'. Downgrade not supported (D-039).') AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        -- Compression settings (D-034)
        DECLARE @EngineEdition int = TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition'));
        DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
        DECLARE @UsePageCompression bit = 0;
        DECLARE @CreateSql nvarchar(max);
        DECLARE @TableCompressionClause nvarchar(64) = N'';
        DECLARE @IndexCompressionClause nvarchar(64) = N'';
        DECLARE @InstallAgentSummary nvarchar(600) = N'';

        IF @EngineEdition IN (3, 5, 8) OR (@EngineEdition = 2 AND ISNULL(@ProductMajorVersion, 0) >= 13)
        BEGIN
            SET @TableCompressionClause = N' WITH (DATA_COMPRESSION = PAGE)';
            SET @IndexCompressionClause = @TableCompressionClause;
        END;

        BEGIN TRY
            -- Create FR_Config (D-025, D-026, D-030, D-031)
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Config (
    ConfigKey    sysname         NOT NULL PRIMARY KEY CLUSTERED,
    ConfigValue  nvarchar(4000)  NULL,
    Description  nvarchar(400)   NULL,
    ModifiedUtc  datetime2(3)    NOT NULL DEFAULT (SYSUTCDATETIME())
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_RunLog (D-030, D-031)
            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_RunLog (
    RunId               bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    StartUtc            datetime2(3)   NOT NULL,
    EndUtc              datetime2(3)   NULL,
    Mode                nvarchar(30)   NOT NULL,
    Status              nvarchar(20)   NULL,
    Reason              nvarchar(400)  NULL,
    InstanceFingerprint nvarchar(200)  NULL,
    CapabilitySnapshot  nvarchar(max)  NULL,
    ErrorMessage        nvarchar(max)  NULL,
    LoginName           sysname        NULL,
    HostName            sysname        NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_RunLog_StartUtc_RunId ON dbo.FR_RunLog (StartUtc, RunId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_RunLogStep
            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_RunLogStep (
    RunStepId     bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    RunId         bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_RunLog (RunId),
    StepName      nvarchar(60)   NOT NULL,
    StartUtc      datetime2(3)   NOT NULL,
    EndUtc        datetime2(3)   NULL,
    Status        nvarchar(20)   NULL,
    RowsCollected int            NULL,
    Reason        nvarchar(400)  NULL,
    ErrorMessage  nvarchar(max)  NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_RunLogStep_StartUtc_RunStepId ON dbo.FR_RunLogStep (StartUtc, RunStepId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_Snapshot (D-135: inserted after children)
            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Snapshot (
    SnapshotId            bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotUtc           datetime2(3)   NOT NULL,
    InstanceFingerprint   nvarchar(200)  NULL,
    RunId                 bigint         NULL FOREIGN KEY REFERENCES dbo.FR_RunLog (RunId)
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Snapshot_SnapshotUtc_SnapshotId ON dbo.FR_Snapshot (SnapshotUtc, SnapshotId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_InstanceSnapshot
            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_InstanceSnapshot (
    InstanceSnapshotId  bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId          bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc         datetime2(3)   NOT NULL,
    ServerName          sysname        NULL,
    EngineEdition       int            NULL,
    ProductVersion      nvarchar(50)   NULL,
    ProductLevel        nvarchar(20)   NULL,
    IsHadrEnabled       bit            NULL,
    Platform            nvarchar(20)   NULL,
    CpuCount            int            NULL,
    PhysicalMemoryKb    bigint         NULL,
    SqlStartTimeUtc     datetime2(3)   NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_InstanceSnapshot_SnapshotUtc_InstanceSnapshotId ON dbo.FR_InstanceSnapshot (SnapshotUtc, InstanceSnapshotId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_Configuration
            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Configuration (
    ConfigurationId    bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId         bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc        datetime2(3)   NOT NULL,
    ConfigurationKind  nvarchar(30)   NOT NULL,
    Name               nvarchar(200)  NOT NULL,
    ValueText          nvarchar(400)  NULL,
    IsDefault          bit            NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Configuration_SnapshotUtc_ConfigurationId ON dbo.FR_Configuration (SnapshotUtc, ConfigurationId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_Request
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Request (
    RequestId            bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId           bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc          datetime2(3)   NOT NULL,
    SessionId            int            NOT NULL,
    DatabaseId           int            NOT NULL,
    BlockingSessionId    int            NULL,
    WaitTypeAtCapture    nvarchar(60)   NULL,
    WaitTimeMs           int            NULL,
    CpuTimeMs            int            NULL,
    LogicalReads         bigint         NULL,
    Status               nvarchar(30)   NULL,
    Command              nvarchar(60)   NULL,
    OpenTransactionCount int            NULL,
    QueryHash            binary(8)      NULL,
    QueryPlanHash        binary(8)      NULL,
    RequestedMemoryKb    bigint         NULL,
    GrantedMemoryKb      bigint         NULL,
    MemoryGrantTimeUtc   datetime2(3)   NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Request_SnapshotUtc_RequestId ON dbo.FR_Request (SnapshotUtc, RequestId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_Wait (D-031: clustered on SnapshotUtc, SnapshotId, WaitType)
            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Wait (
    WaitId              bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId          bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc         datetime2(3)   NOT NULL,
    WaitType            nvarchar(60)   NOT NULL,
    WaitingTasksCount   bigint         NOT NULL,
    WaitTimeMs          bigint         NOT NULL,
    MaxWaitTimeMs       bigint         NOT NULL,
    SignalWaitTimeMs    bigint         NOT NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Wait_SnapshotUtc_SnapshotId_WaitType ON dbo.FR_Wait (SnapshotUtc, SnapshotId, WaitType)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_FileStat
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_FileStat (
    FileStatId          bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId          bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc         datetime2(3)   NOT NULL,
    DatabaseId          int            NOT NULL,
    FileId              int            NOT NULL,
    NumOfReads          bigint         NOT NULL,
    NumOfBytesRead      bigint         NOT NULL,
    IoStallReadMs       bigint         NOT NULL,
    NumOfWrites         bigint         NOT NULL,
    NumOfBytesWritten   bigint         NOT NULL,
    IoStallWriteMs      bigint         NOT NULL,
    SizeOnDiskBytes     bigint         NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_FileStat_SnapshotUtc_DatabaseId_FileId ON dbo.FR_FileStat (SnapshotUtc, DatabaseId, FileId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_PerfCounter
            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_PerfCounter (
    PerfCounterId   bigint          IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId      bigint          NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc     datetime2(3)    NOT NULL,
    ObjectName      nvarchar(128)   NOT NULL,
    CounterName     nvarchar(128)   NOT NULL,
    InstanceName    nvarchar(128)   NULL,
    CounterValue    bigint          NOT NULL,
    CounterType     int             NOT NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_PerfCounter_SnapshotUtc_ObjectName_CounterName_InstanceName ON dbo.FR_PerfCounter (SnapshotUtc, ObjectName, CounterName, InstanceName)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_QueryText (D-027)
            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_QueryText (
    QueryTextId    bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    QueryHash      binary(8)      NOT NULL,
    TextHash       binary(32)     NOT NULL,
    SqlText        nvarchar(max)  NULL,
    FirstSeenUtc   datetime2(3)   NOT NULL DEFAULT (SYSUTCDATETIME()),
    LastSeenUtc    datetime2(3)   NOT NULL DEFAULT (SYSUTCDATETIME())
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE UNIQUE NONCLUSTERED INDEX UX_FR_QueryText_QueryHash_TextHash ON dbo.FR_QueryText (QueryHash, TextHash)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- ===== v0.2 tables (Historical Correlation) =====================

            -- FR_Tempdb (one row per snapshot; tempdb space + file shape)
            IF OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Tempdb (
    TempdbId             bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId           bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc          datetime2(3)  NOT NULL,
    VersionStoreKb       bigint        NULL,
    UserObjectKb         bigint        NULL,
    InternalObjectKb     bigint        NULL,
    UnallocatedExtentKb  bigint        NULL,
    MixedExtentKb        bigint        NULL,
    DataFileCount        int           NULL,
    MinDataFileSizeKb    bigint        NULL,
    MaxDataFileSizeKb    bigint        NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Tempdb_SnapshotUtc_TempdbId ON dbo.FR_Tempdb (SnapshotUtc, TempdbId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_Memory (one row per snapshot; memory pressure summary)
            IF OBJECT_ID(N'dbo.FR_Memory', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Memory (
    MemoryId                 bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId               bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc              datetime2(3)  NOT NULL,
    TotalServerMemoryKb      bigint        NULL,
    TargetServerMemoryKb     bigint        NULL,
    StolenServerMemoryKb     bigint        NULL,
    MemoryGrantsPending      bigint        NULL,
    MemoryGrantsOutstanding  bigint        NULL,
    PageLifeExpectancy       bigint        NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Memory_SnapshotUtc_MemoryId ON dbo.FR_Memory (SnapshotUtc, MemoryId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_AgentJob (delta-read msdb job history; high-water in FR_Config)
            IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_AgentJob (
    AgentJobRowId    bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId       bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc      datetime2(3)  NOT NULL,
    MsdbInstanceId   int           NOT NULL,
    JobName          sysname       NULL,
    StepId           int           NULL,
    StepName         nvarchar(200) NULL,
    RunStatus        int           NULL,
    RunOutcome       nvarchar(20)  NULL,
    RunStartUtc      datetime2(3)  NULL,
    RunDurationSec   int           NULL,
    MessageText      nvarchar(400) NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_AgentJob_SnapshotUtc_AgentJobRowId ON dbo.FR_AgentJob (SnapshotUtc, AgentJobRowId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_BackupHistory (delta-read msdb backupset; high-water in FR_Config)
            IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_BackupHistory (
    BackupHistoryId  bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId       bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc      datetime2(3)  NOT NULL,
    MsdbBackupSetId  int           NOT NULL,
    DatabaseName     sysname       NULL,
    BackupType       nvarchar(20)  NULL,
    BackupStartUtc   datetime2(3)  NULL,
    BackupFinishUtc  datetime2(3)  NULL,
    BackupSizeBytes  bigint        NULL,
    IsCopyOnly       bit           NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_BackupHistory_SnapshotUtc_BackupHistoryId ON dbo.FR_BackupHistory (SnapshotUtc, BackupHistoryId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_AlwaysOnState (one row per replica/db per snapshot)
            IF OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_AlwaysOnState (
    AlwaysOnStateId       bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId            bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc           datetime2(3)  NOT NULL,
    AgName                sysname       NULL,
    ReplicaServer         sysname       NULL,
    Role                  nvarchar(30)  NULL,
    OperationalState      nvarchar(30)  NULL,
    ConnectedState        nvarchar(30)  NULL,
    SynchronizationHealth nvarchar(30)  NULL,
    DatabaseName          sysname       NULL,
    SynchronizationState  nvarchar(30)  NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_AlwaysOnState_SnapshotUtc_AlwaysOnStateId ON dbo.FR_AlwaysOnState (SnapshotUtc, AlwaysOnStateId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_Deadlock (dedup by graph hash; bounded read of system_health)
            IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Deadlock (
    DeadlockId      bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId      bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc     datetime2(3)  NOT NULL,
    GraphHash       varbinary(32) NOT NULL,
    DeadlockTimeUtc datetime2(3)  NULL,
    ProcessCount    int           NULL,
    DeadlockGraph   nvarchar(max) NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Deadlock_SnapshotUtc_DeadlockId ON dbo.FR_Deadlock (SnapshotUtc, DeadlockId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE NONCLUSTERED INDEX IX_FR_Deadlock_GraphHash ON dbo.FR_Deadlock (GraphHash)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_QueryPlan (opt-in @IncludeQueryPlans storage; child of FR_Snapshot)
            IF OBJECT_ID(N'dbo.FR_QueryPlan', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_QueryPlan (
    QueryPlanId    bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId     bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc    datetime2(3)  NOT NULL,
    DatabaseId     int           NOT NULL,
    SessionId      int           NULL,
    QueryHash      binary(8)     NULL,
    QueryPlanHash  binary(8)     NULL,
    PlanXml        xml           NULL,
    PlanXmlHash    varbinary(32) NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_QueryPlan_SnapshotUtc_QueryPlanId ON dbo.FR_QueryPlan (SnapshotUtc, QueryPlanId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- ===== v0.3 tables (Query Store Integration + correlation) =======

            -- FR_QueryStoreTopN (latest closed QS interval per DB; D-044/D-045/D-059)
            IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_QueryStoreTopN (
    QueryStoreTopNId   bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId         bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc        datetime2(3)  NOT NULL,
    DatabaseId         int           NOT NULL,
    DatabaseName       sysname       NULL,
    QsQueryId          bigint        NOT NULL,
    QsPlanId           bigint        NULL,
    IsForcedPlan       bit           NULL,
    ForceFailureCount  bigint        NULL,
    LastForceFailureReason nvarchar(128) NULL,
    ExecutionCount     bigint        NULL,
    TotalDurationUs    bigint        NULL,
    AvgDurationUs      bigint        NULL,
    TotalCpuUs         bigint        NULL,
    AvgCpuUs           bigint        NULL,
    AvgLogicalReads    bigint        NULL,
    AvgPhysicalReads   bigint        NULL,
    AvgWrites          bigint        NULL,
    IntervalStartUtc   datetime2(3)  NULL,
    IntervalEndUtc     datetime2(3)  NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_QueryStoreTopN_SnapshotUtc_Id ON dbo.FR_QueryStoreTopN (SnapshotUtc, QueryStoreTopNId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_ErrorLog (opt-in, OFF by default; D-020/D-060; high-water bounded)
            IF OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_ErrorLog (
    ErrorLogId   bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId   bigint         NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc  datetime2(3)   NOT NULL,
    LogDateUtc   datetime2(3)   NULL,
    ProcessInfo  nvarchar(64)   NULL,
    Category     nvarchar(30)   NULL,
    LogText      nvarchar(2000) NULL,
    TextHash     varbinary(32)  NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_ErrorLog_SnapshotUtc_Id ON dbo.FR_ErrorLog (SnapshotUtc, ErrorLogId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_SchemaActivity (metadata-only; capped 50 DBs; D-052)
            IF OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_SchemaActivity (
    SchemaActivityId bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId       bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc      datetime2(3)  NOT NULL,
    DatabaseId       int           NOT NULL,
    DatabaseName     sysname       NULL,
    ActivityKind     nvarchar(30)  NOT NULL,
    SchemaName       sysname       NULL,
    ObjectName       sysname       NULL,
    StatName         sysname       NULL,
    ModifyDateUtc    datetime2(3)  NULL,
    RowModCount      bigint        NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_SchemaActivity_SnapshotUtc_Id ON dbo.FR_SchemaActivity (SnapshotUtc, SchemaActivityId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_PlanCacheSummary (one bounded summary row per snapshot; D-055; no plan XML)
            IF OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_PlanCacheSummary (
    PlanCacheSummaryId       bigint       IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId               bigint       NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc              datetime2(3) NOT NULL,
    CachedPlanCount          bigint       NULL,
    CachedPlanSizeKb         bigint       NULL,
    AdHocSingleUsePlanCount  bigint       NULL,
    AdHocSingleUsePlanSizeKb bigint       NULL,
    CompilationsPerSec       bigint       NULL,
    ReCompilationsPerSec     bigint       NULL,
    BatchRequestsPerSec      bigint       NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_PlanCacheSummary_SnapshotUtc_Id ON dbo.FR_PlanCacheSummary (SnapshotUtc, PlanCacheSummaryId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- ===== v0.4 tables (advanced HA + buffer pool; D-051/D-056) =======

            -- FR_HaState (advanced AG context per replica/db per snapshot; queue + role-change signals)
            IF OBJECT_ID(N'dbo.FR_HaState', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_HaState (
    HaStateId               bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId              bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc             datetime2(3)  NOT NULL,
    AgName                  sysname       NULL,
    ReplicaServer           sysname       NULL,
    DatabaseName            sysname       NULL,
    IsLocalReplica          bit           NULL,
    IsPrimaryReplica        bit           NULL,
    RoleDesc                nvarchar(60)  NULL,
    OperationalStateDesc    nvarchar(60)  NULL,
    ConnectedStateDesc      nvarchar(60)  NULL,
    SynchronizationStateDesc nvarchar(60) NULL,
    SynchronizationHealthDesc nvarchar(60) NULL,
    AvailabilityModeDesc    nvarchar(60)  NULL,
    FailoverModeDesc        nvarchar(60)  NULL,
    LogSendQueueKb          bigint        NULL,
    LogSendRateKbPerSec     bigint        NULL,
    RedoQueueKb             bigint        NULL,
    RedoRateKbPerSec        bigint        NULL,
    LastCommitUtc           datetime2(3)  NULL,
    SecondaryLagSeconds     int           NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_HaState_SnapshotUtc_Id ON dbo.FR_HaState (SnapshotUtc, HaStateId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- FR_BufferPool (opt-in; bounded dm_os_buffer_descriptors summary; D-051; skipped >256 GB RAM)
            -- One row per database in the buffer pool; NO per-page rows, NO user-table scans.
            IF OBJECT_ID(N'dbo.FR_BufferPool', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_BufferPool (
    BufferPoolId        bigint        IDENTITY(1,1) NOT NULL PRIMARY KEY NONCLUSTERED,
    SnapshotId          bigint        NOT NULL FOREIGN KEY REFERENCES dbo.FR_Snapshot (SnapshotId),
    SnapshotUtc         datetime2(3)  NOT NULL,
    DatabaseId          int           NOT NULL,
    DatabaseName        sysname       NULL,
    CachedPageCount     bigint        NULL,
    CachedSizeKb        bigint        NULL,
    FreePageCount       bigint        NULL,
    ModifiedPageCount   bigint        NULL,
    TotalBufferPoolKb   bigint        NULL,
    PercentOfPool       decimal(5,2)  NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_BufferPool_SnapshotUtc_Id ON dbo.FR_BufferPool (SnapshotUtc, BufferPoolId)' + @IndexCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Create FR_Rules (D-029: metadata only; logic in code)
            IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Rules (
    RuleId              nvarchar(60)   NOT NULL PRIMARY KEY CLUSTERED,
    Category            nvarchar(30)   NOT NULL,
    Severity            nvarchar(20)   NOT NULL,
    Confidence          nvarchar(20)   NOT NULL,
    EvidenceType        nvarchar(20)   NOT NULL,
    LifecycleState      nvarchar(20)   NOT NULL DEFAULT N''Active'',
    ShortDescription    nvarchar(400)  NOT NULL,
    IntroducedInVersion nvarchar(20)   NOT NULL
)' + @TableCompressionClause;
                EXEC sys.sp_executesql @CreateSql;
            END;

            -- Seed FR_Config
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SchemaVersion')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'SchemaVersion', @SchemaVersion, N'Forward-only migration marker (D-038).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotIntervalSeconds')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'SnapshotIntervalSeconds', N'60', N'Default snapshot cadence (D-042).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotRetentionDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'SnapshotRetentionDays', N'7', N'Snapshot retention (7 days).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'RunLogRetentionDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'RunLogRetentionDays', N'28', N'Run-log retention is 4x snapshot retention (D-035).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'MaxRowsPerCollector')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'MaxRowsPerCollector', N'50', N'Default per-collector row cap (D-181).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'DisabledRules')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'DisabledRules', N'', N'Semicolon-delimited disabled rule IDs (D-099).');

            -- v0.2 config keys
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobHighWaterInstanceId')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'AgentJobHighWaterInstanceId', N'0', N'Last msdb sysjobhistory instance_id captured (delta read, D-050).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BackupHighWaterBackupSetId')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BackupHighWaterBackupSetId', N'0', N'Last msdb backupset backup_set_id captured (delta read, D-050).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'MaintenanceJobNamePatterns')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'MaintenanceJobNamePatterns',
                        N'%IndexOptimize%;%DatabaseBackup%;%DatabaseIntegrityCheck%;%Maintenance Plan%;%Reindex%;%Update Stats%;%CHECKDB%',
                        N'Semicolon-delimited LIKE patterns for maintenance jobs (D-094).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BlockingStormSessionThreshold')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BlockingStormSessionThreshold', N'5', N'Distinct blocked sessions in one snapshot to flag FR_R0007 (tentative).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'TempdbVersionStoreWarnKb')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'TempdbVersionStoreWarnKb', N'5242880', N'Version store size (KB) that escalates FR_R0008 (default 5 GB, tentative).');

            -- v0.3 config keys
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CollectQueryStore')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CollectQueryStore', N'1', N'1=collect bounded Query Store top-N where available (D-044). 0=skip.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreMaxDatabases')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'QueryStoreMaxDatabases', N'50', N'Max user DBs scanned by QS collector per snapshot (D-052).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreCapacityWarnPercent')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'QueryStoreCapacityWarnPercent', N'90', N'QS storage used %% that flags FR_R0019 (tentative).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreRegressionFactor')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'QueryStoreRegressionFactor', N'2', N'Avg duration multiple vs prior plan to flag FR_R0015 (tentative).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CollectErrorLog')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CollectErrorLog', N'0', N'OPT-IN. 1=collect bounded recent error log rows (D-020). 0=off (default).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'ErrorLogHighWaterUtc')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'ErrorLogHighWaterUtc', N'1900-01-01T00:00:00', N'Last error-log datetime captured (delta read).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CollectSchemaActivity')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CollectSchemaActivity', N'1', N'1=collect bounded schema/stats metadata (D-052). 0=skip.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SchemaActivityMaxDatabases')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'SchemaActivityMaxDatabases', N'50', N'Max user DBs scanned by schema-activity collector (D-052).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CollectPlanCacheSummary')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CollectPlanCacheSummary', N'1', N'1=collect bounded plan-cache summary (D-055). 0=skip. Never shreds plan XML.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CompilationsPerSecWarn')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CompilationsPerSecWarn', N'100', N'Compilations/sec that flags FR_R0020 (tentative).');

            -- v0.4 config keys
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'EnableBufferPoolCollector')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'EnableBufferPoolCollector', N'0', N'OPT-IN. 1=collect bounded buffer pool summary (D-051). 0=off (default).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BufferPoolCollectionMaxRows')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BufferPoolCollectionMaxRows', N'100', N'Max database rows captured by buffer pool collector per snapshot.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BufferPoolMaxMemoryGB')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BufferPoolMaxMemoryGB', N'256', N'Buffer pool collector is skipped when target server memory exceeds this many GB (D-051).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'EnableAdvancedHaCollector')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'EnableAdvancedHaCollector', N'1', N'1=collect advanced HA/AG context into FR_HaState where HADR is enabled. 0=skip.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BaselineLookbackHours')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BaselineLookbackHours', N'24', N'Hours of prior snapshots used for baseline-relative rules (D-092). 1-168.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'TimeZoneMode')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'TimeZoneMode', N'UTC', N'Display-only time mode for Report Markdown/Status: UTC or LOCAL (D-180). Storage stays UTC.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'TimeZoneName')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'TimeZoneName', N'', N'Optional Windows time zone id for LOCAL display when AT TIME ZONE is supported (SQL 2016+). Empty = server offset.');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'BackupWarnDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'BackupWarnDays', N'7', N'FULL backup age (days) that flags FR_R0025 Medium (D-097).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CheckDbWarnDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'CheckDbWarnDays', N'14', N'CHECKDB age (days) that flags FR_R0025 High (D-097).');

            -- v0.4.2 rule tunables (Tentative; revisable per D-181).
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'LongOpenTxnSeconds')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'LongOpenTxnSeconds', N'60', N'Open-transaction span (seconds) across snapshots that flags FR_R0002 (tentative).');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'FileIoLatencyWarnMs')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'FileIoLatencyWarnMs', N'20', N'Absolute per-file IO latency floor (ms) for FR_R0004 escalation over baseline (tentative).');

            -- v1.1 retention guardrail (D-199).
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'RepositoryTableWarnRows')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES (N'RepositoryTableWarnRows', N'5000000', N'Row count per FR_* table that raises a Status retention-health warning (D-199).');

            -- Forward-only migration marker maintenance: advance recorded SchemaVersion (D-038).
            UPDATE dbo.FR_Config
            SET ConfigValue = @SchemaVersion, ModifiedUtc = SYSUTCDATETIME()
            WHERE ConfigKey = N'SchemaVersion'
              AND ConfigValue <> @SchemaVersion;
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'WaitStatsIgnoreList')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES
                (
                    N'WaitStatsIgnoreList',
                    N'BROKER_EVENTHANDLER;BROKER_RECEIVE_WAITFOR;BROKER_TASK_STOP;BROKER_TO_FLUSH;BROKER_TRANSMITTER;CHECKPOINT_QUEUE;CHKPT;CLR_AUTO_EVENT;CLR_MANUAL_EVENT;CLR_SEMAPHORE;DBMIRROR_DBM_EVENT;DBMIRROR_EVENTS_QUEUE;DBMIRROR_WORKER_QUEUE;DBMIRRORING_CMD;DIRTY_PAGE_POLL;DISPATCHER_QUEUE_SEMAPHORE;EXECSYNC;FSAGENT;FT_IFTS_SCHEDULER_IDLE_WAIT;FT_IFTSHC_MUTEX;HADR_CLUSAPI_CALL;HADR_FILESTREAM_IOMGR_IOCOMPLETION;HADR_LOGCAPTURE_WAIT;HADR_NOTIFICATION_DEQUEUE;HADR_TIMER_TASK;HADR_WORK_QUEUE;KSOURCE_WAKEUP;LAZYWRITER_SLEEP;LOGMGR_QUEUE;MEMORY_ALLOCATION_EXT;ONDEMAND_TASK_QUEUE;PARALLEL_REDO_DRAIN_WORKER;PARALLEL_REDO_LOG_CACHE;PARALLEL_REDO_TRAN_LIST;PARALLEL_REDO_WORKER_SYNC;PARALLEL_REDO_WORKER_WAIT_WORK;PREEMPTIVE_HADR_LEASE_MECHANISM;PREEMPTIVE_OS_FLUSHFILEBUFFERS;PREEMPTIVE_XE_GETTARGETSTATE;PWAIT_ALL_COMPONENTS_INITIALIZED;PWAIT_DIRECTLOGCONSUMER_GETNEXT;QDS_PERSIST_TASK_MAIN_LOOP_SLEEP;QDS_ASYNC_QUEUE;QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP;QDS_SHUTDOWN_QUEUE;REDO_THREAD_PENDING_WORK;REQUEST_FOR_DEADLOCK_SEARCH;RESOURCE_QUEUE;SERVER_IDLE_CHECK;SLEEP_BPOOL_FLUSH;SLEEP_DBSTARTUP;SLEEP_MASTERDBREADY;SLEEP_MASTERMDREADY;SLEEP_MASTERUPGRADED;SLEEP_MSDBSTARTUP;SLEEP_SYSTEMTASK;SLEEP_TASK;SLEEP_TEMPDBSTARTUP;SNI_HTTP_ACCEPT;SP_SERVER_DIAGNOSTICS_SLEEP;SQLTRACE_BUFFER_FLUSH;SQLTRACE_INCREMENTAL_FLUSH_SLEEP;SQLTRACE_WAIT_ENTRIES;WAIT_FOR_RESULTS;WAITFOR;WAITFOR_TASKSHUTDOWN;WAIT_XTP_RECOVERY;WAIT_XTP_HOST_WAIT;WAIT_XTP_OFFLINE_CKPT_NEW_LOG;WAIT_XTP_CKPT_CLOSE;XE_DISPATCHER_JOIN;XE_DISPATCHER_WAIT;XE_TIMER_EVENT',
                    N'Wait types ignored by Collect wait-stats collector.'
                );

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CriticalWaitTypes')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                VALUES
                (
                    N'CriticalWaitTypes',
                    N'PAGEIOLATCH_*;WRITELOG;RESOURCE_SEMAPHORE;LCK_M_*;THREADPOOL;SOS_SCHEDULER_YIELD',
                    N'Critical wait-type patterns reserved for rule evaluation.'
                );

            -- Seed v0.1 rules
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0001_ActiveBlockingChain')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0001_ActiveBlockingChain', N'Blocking', N'High', N'High', N'Observed', N'Active', N'Active blocking chain observed', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0002_LongRunningOpenTransaction')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0002_LongRunningOpenTransaction', N'Blocking', N'Medium', N'High', N'Observed', N'Active', N'Long-running open transaction', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0003_TopWaitTypeSpike')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0003_TopWaitTypeSpike', N'Waits', N'Medium', N'Medium', N'Inferred', N'Active', N'Top wait type increased', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0004_FileIoLatencySpike')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0004_FileIoLatencySpike', N'IO', N'Medium', N'Medium', N'Inferred', N'Active', N'File I/O latency increased', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0005_MemoryGrantsPending')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0005_MemoryGrantsPending', N'Memory', N'High', N'High', N'Observed', N'Active', N'Memory grants pending', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0006_ServerRestartDuringWindow')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0006_ServerRestartDuringWindow', N'Configuration', N'Critical', N'High', N'Observed', N'Active', N'SQL Server restart detected', N'0.1');

            -- Coverage summary rule (always emits; previously emitted but unseeded) (D-098)
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0026_CoverageAndCapabilitySummary')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0026_CoverageAndCapabilitySummary', N'Coverage', N'Informational', N'High', N'Observed', N'Active', N'Coverage and capability summary', N'0.1');

            -- v0.2 rules (design §7.10)
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0007_BlockingStorm')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0007_BlockingStorm', N'Blocking', N'Critical', N'High', N'Observed', N'Active', N'Blocking storm observed', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0008_TempdbVersionStoreGrowth')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0008_TempdbVersionStoreGrowth', N'Tempdb', N'Medium', N'High', N'Observed', N'Active', N'Tempdb version store growth', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0009_TempdbFileImbalanceOrPressure')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0009_TempdbFileImbalanceOrPressure', N'Tempdb', N'Medium', N'Medium', N'Inferred', N'Active', N'Tempdb file imbalance or pressure', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0010_FailedSqlAgentJobNearIncident')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0010_FailedSqlAgentJobNearIncident', N'Maintenance', N'High', N'High', N'Observed', N'Active', N'Failed SQL Agent job near incident', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0011_MaintenanceJobOverlap')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0011_MaintenanceJobOverlap', N'Maintenance', N'Medium', N'Medium', N'Inferred', N'Active', N'Maintenance job overlap with incident', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0012_BackupOverlapWithIncident')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0012_BackupOverlapWithIncident', N'Maintenance', N'Medium', N'High', N'Observed', N'Active', N'Backup overlap with incident', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0013_DeadlocksObserved')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0013_DeadlocksObserved', N'Blocking', N'High', N'High', N'Observed', N'Active', N'Deadlocks observed in window', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0014_AlwaysOnRoleOrStateChange')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0014_AlwaysOnRoleOrStateChange', N'HA', N'Critical', N'High', N'Observed', N'Active', N'Always On role or state change', N'0.2');

            -- v0.3 rules (design §7.11)
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0015_QueryPlanRegression')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0015_QueryPlanRegression', N'QueryStore', N'High', N'Medium', N'Inferred', N'Active', N'Query plan regression (Query Store)', N'0.3');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0016_TopCpuConsumerInWindow')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0016_TopCpuConsumerInWindow', N'QueryStore', N'Medium', N'High', N'Observed', N'Active', N'Top CPU consumer in window (Query Store)', N'0.3');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0017_QueryStoreDisabledOnUserDbs')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0017_QueryStoreDisabledOnUserDbs', N'Coverage', N'Informational', N'High', N'Observed', N'Active', N'Query Store disabled on user databases', N'0.3');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0018_FailedPlanForcing')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0018_FailedPlanForcing', N'QueryStore', N'Medium', N'High', N'Observed', N'Active', N'Forced plan failure observed (Query Store)', N'0.3');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0019_QueryStoreNearingCapacity')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0019_QueryStoreNearingCapacity', N'QueryStore', N'Medium', N'High', N'Observed', N'Active', N'Query Store nearing capacity', N'0.3');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0020_HighCompilationRate')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0020_HighCompilationRate', N'PlanCache', N'Medium', N'Medium', N'Inferred', N'Active', N'High compilation/recompilation rate', N'0.3');

            -- v0.4 rules (FR_R0021–FR_R0026; design §7.12). RuleId stable; logic in code (D-029).
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0021_ConfigurationChangeInWindow')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0021_ConfigurationChangeInWindow', N'Configuration', N'Medium', N'High', N'Observed', N'Active', N'Server/database configuration changed during the window', N'0.4');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0022_LogReuseWaitElevated')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0022_LogReuseWaitElevated', N'IO', N'High', N'High', N'Observed', N'Active', N'Transaction log reuse wait elevated', N'0.4');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0023_ThreadpoolWaitsObserved')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0023_ThreadpoolWaitsObserved', N'Waits', N'Critical', N'High', N'Observed', N'Active', N'THREADPOOL waits observed (worker starvation)', N'0.4');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0024_ResourceSemaphoreWaits')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0024_ResourceSemaphoreWaits', N'Memory', N'High', N'High', N'Observed', N'Active', N'RESOURCE_SEMAPHORE waits (memory grant pressure)', N'0.4');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0025_RecentCheckDbOrBackupAge')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0025_RecentCheckDbOrBackupAge', N'Maintenance', N'Medium', N'High', N'Observed', N'Active', N'FULL backup or CHECKDB age exceeds threshold', N'0.4');

            -- FR_R0026 upgraded from the v0.1 skeleton to the full Coverage & Capability summary (D-098: always emits).
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0026_CoverageAndCapabilitySummary')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0026_CoverageAndCapabilitySummary', N'Coverage', N'Informational', N'High', N'Observed', N'Active', N'Coverage and capability summary (always emitted)', N'0.4');

            UPDATE dbo.FR_Rules
            SET Category = N'Coverage', Severity = N'Informational', Confidence = N'High', EvidenceType = N'Observed',
                ShortDescription = N'Coverage and capability summary (always emitted)', IntroducedInVersion = N'0.4'
            WHERE RuleId = N'FR_R0026_CoverageAndCapabilitySummary';

            -- Query-plan rules FR_R0030–FR_R0034: cataloged but DISABLED.
            -- Their original implementation shredded plan XML from
            -- sys.dm_exec_query_plan, which locked decisions D-015/D-046/
            -- D-082/D-136 forbid. RuleIds are never renamed or reused
            -- (D-089); lifecycle state carries the truth (D-090). They stay
            -- Disabled until a decision-log-approved plan analysis design
            -- exists.
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0030_PlanMissingIndex')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0030_PlanMissingIndex', N'QueryPlan', N'Medium', N'Medium', N'Inferred', N'Disabled', N'Plan shows missing-index evidence (no compliant implementation; disabled)', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0031_PlanImplicitConversion')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0031_PlanImplicitConversion', N'QueryPlan', N'Low', N'Medium', N'Inferred', N'Disabled', N'Plan shows implicit conversion evidence (no compliant implementation; disabled)', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0032_PlanSpillToTempDb')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0032_PlanSpillToTempDb', N'QueryPlan', N'Medium', N'Medium', N'Inferred', N'Disabled', N'Plan shows tempdb spill evidence (no compliant implementation; disabled)', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0033_PlanWarnings')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0033_PlanWarnings', N'QueryPlan', N'Low', N'Medium', N'Inferred', N'Disabled', N'Plan contains optimizer warnings (no compliant implementation; disabled)', N'0.2');
            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0034_PlanParallelism')
                INSERT INTO dbo.FR_Rules VALUES (N'FR_R0034_PlanParallelism', N'QueryPlan', N'Low', N'Low', N'Inferred', N'Disabled', N'Plan uses parallelism (no compliant implementation; disabled)', N'0.2');

            -- Forward-only migration for repositories seeded by earlier 0.x
            -- builds where these five rules were marked Active.
            UPDATE dbo.FR_Rules
            SET LifecycleState = N'Disabled'
            WHERE RuleId IN (N'FR_R0030_PlanMissingIndex', N'FR_R0031_PlanImplicitConversion',
                             N'FR_R0032_PlanSpillToTempDb', N'FR_R0033_PlanWarnings',
                             N'FR_R0034_PlanParallelism')
              AND LifecycleState <> N'Disabled';

            -- ===== v1.1 index hardening (D-199) ==============================
            -- Purge removes FR_Snapshot rows only after the engine checks every
            -- child FK; without a SnapshotId index each check is a child-table
            -- scan, which is what made purge (and window-first report reads)
            -- unusable on repositories that grew unpurged (35M+ row children).
            -- Idempotent; applies to fresh installs and upgrades (D-038).
            DECLARE @IndexDefs TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, TableName sysname NOT NULL, IndexName sysname NOT NULL, KeyColumn sysname NOT NULL);
            INSERT INTO @IndexDefs (TableName, IndexName, KeyColumn)
            VALUES
                  (N'FR_InstanceSnapshot', N'IX_FR_InstanceSnapshot_SnapshotId', N'SnapshotId')
                , (N'FR_Configuration',    N'IX_FR_Configuration_SnapshotId',    N'SnapshotId')
                , (N'FR_Request',          N'IX_FR_Request_SnapshotId',          N'SnapshotId')
                , (N'FR_Request',          N'IX_FR_Request_QueryHash',           N'QueryHash')
                , (N'FR_Wait',             N'IX_FR_Wait_SnapshotId',             N'SnapshotId')
                , (N'FR_FileStat',         N'IX_FR_FileStat_SnapshotId',         N'SnapshotId')
                , (N'FR_PerfCounter',      N'IX_FR_PerfCounter_SnapshotId',      N'SnapshotId')
                , (N'FR_Tempdb',           N'IX_FR_Tempdb_SnapshotId',           N'SnapshotId')
                , (N'FR_Memory',           N'IX_FR_Memory_SnapshotId',           N'SnapshotId')
                , (N'FR_AgentJob',         N'IX_FR_AgentJob_SnapshotId',         N'SnapshotId')
                , (N'FR_BackupHistory',    N'IX_FR_BackupHistory_SnapshotId',    N'SnapshotId')
                , (N'FR_AlwaysOnState',    N'IX_FR_AlwaysOnState_SnapshotId',    N'SnapshotId')
                , (N'FR_Deadlock',         N'IX_FR_Deadlock_SnapshotId',         N'SnapshotId')
                , (N'FR_QueryPlan',        N'IX_FR_QueryPlan_SnapshotId',        N'SnapshotId')
                , (N'FR_QueryStoreTopN',   N'IX_FR_QueryStoreTopN_SnapshotId',   N'SnapshotId')
                , (N'FR_ErrorLog',         N'IX_FR_ErrorLog_SnapshotId',         N'SnapshotId')
                , (N'FR_SchemaActivity',   N'IX_FR_SchemaActivity_SnapshotId',   N'SnapshotId')
                , (N'FR_PlanCacheSummary', N'IX_FR_PlanCacheSummary_SnapshotId', N'SnapshotId')
                , (N'FR_HaState',          N'IX_FR_HaState_SnapshotId',          N'SnapshotId')
                , (N'FR_BufferPool',       N'IX_FR_BufferPool_SnapshotId',       N'SnapshotId')
                , (N'FR_Snapshot',         N'IX_FR_Snapshot_RunId',              N'RunId')
                , (N'FR_RunLogStep',       N'IX_FR_RunLogStep_RunId',            N'RunId');

            DECLARE @IndexSeq int = 0;
            DECLARE @IndexTable sysname, @IndexName sysname, @IndexKey sysname;
            WHILE 1 = 1
            BEGIN
                SELECT TOP (1) @IndexSeq = Seq, @IndexTable = TableName, @IndexName = IndexName, @IndexKey = KeyColumn
                FROM @IndexDefs
                WHERE Seq > @IndexSeq
                ORDER BY Seq ASC;

                IF @@ROWCOUNT = 0 BREAK;

                IF OBJECT_ID(CONCAT(N'dbo.', @IndexTable), N'U') IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                                   WHERE object_id = OBJECT_ID(CONCAT(N'dbo.', @IndexTable))
                                     AND name = @IndexName)
                BEGIN
                    SET @CreateSql = CONCAT(N'CREATE NONCLUSTERED INDEX ', QUOTENAME(@IndexName),
                                            N' ON dbo.', QUOTENAME(@IndexTable),
                                            N' (', QUOTENAME(@IndexKey), N')', @IndexCompressionClause);
                    EXEC sys.sp_executesql @CreateSql;
                END;
            END;

            -- Optional SQL Agent job creation. Explicit opt-in only.
            -- v1.1 (D-199): ensures TWO jobs, idempotently (an existing job is
            -- completed in place; never duplicates a job, step, or schedule):
            --   1. 'SQLFlightRecorder Collect' — step 1 Collect, step 2 Purge
            --      (@WhatIf = 0) as post-collect cleanup, every minute.
            --   2. 'SQLFlightRecorder Purge' — daily 02:30 retention backstop
            --      in case the collector job is disabled, changed, or failing.
            IF @CreateAgentJob = 1
            BEGIN
                DECLARE @AgentJobName sysname = N'SQLFlightRecorder Collect';
                DECLARE @PurgeAgentJobName sysname = N'SQLFlightRecorder Purge';
                DECLARE @AgentSql nvarchar(max);
                DECLARE @AgentSupported bit = 1;

                IF TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) IN (4, 5)
                    SET @AgentSupported = 0;

                IF DB_ID(N'msdb') IS NULL
                    SET @AgentSupported = 0;

                IF OBJECT_ID(N'msdb.dbo.sp_add_job', N'P') IS NULL
                    SET @AgentSupported = 0;

                IF @AgentSupported = 0
                BEGIN
                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'AgentJobCreatedBySQLFlightRecorder', N'0', N'SQL Agent unavailable or unsupported; schedule Collect and Purge externally.');

                    -- Azure SQL Database / Express have no local SQL Agent:
                    -- surface the external-scheduling requirement in the
                    -- Install result instead of silently doing nothing.
                    SET @InstallAgentSummary = N' SQL Agent is not available on this platform, so no job was created. Schedule BOTH of these externally (Elastic Jobs, cron + sqlcmd, or another scheduler): EXEC dbo.sp_SQLFlightRecorder @Mode = N''Collect''; (every minute) and EXEC dbo.sp_SQLFlightRecorder @Mode = N''Purge'', @WhatIf = 0; (daily).';
                END;
                ELSE
                BEGIN
                    SET @AgentSql = N'
USE msdb;

DECLARE @collectJobId uniqueidentifier;
DECLARE @purgeJobId   uniqueidentifier;
DECLARE @collectStepId int;

-- Collector job: create when missing (idempotent).
SELECT @collectJobId = job_id FROM msdb.dbo.sysjobs WHERE name = N''SQLFlightRecorder Collect'';
IF @collectJobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
          @job_name = N''SQLFlightRecorder Collect''
        , @enabled = 1
        , @description = N''Runs dbo.sp_SQLFlightRecorder @Mode = Collect every minute, then @Mode = Purge as post-collect cleanup.'';
    SELECT @collectJobId = job_id FROM msdb.dbo.sysjobs WHERE name = N''SQLFlightRecorder Collect'';
END;

-- Step 1: Collect (added only when missing; never duplicated).
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = @collectJobId AND step_name = N''Collect'')
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
          @job_id = @collectJobId
        , @step_name = N''Collect''
        , @subsystem = N''TSQL''
        , @database_name = N''' + REPLACE(DB_NAME(), N'''', N'''''') + N'''
        , @command = N''EXEC dbo.sp_SQLFlightRecorder @Mode = N''''Collect'''';''
        , @on_success_action = 3
        , @on_fail_action = 2;
END;

-- Step 2: Purge after Collect (added only when missing; never duplicated).
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = @collectJobId AND step_name = N''Purge'')
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
          @job_id = @collectJobId
        , @step_name = N''Purge''
        , @subsystem = N''TSQL''
        , @database_name = N''' + REPLACE(DB_NAME(), N'''', N'''''') + N'''
        , @command = N''EXEC dbo.sp_SQLFlightRecorder @Mode = N''''Purge'''', @WhatIf = 0;''
        , @on_success_action = 1
        , @on_fail_action = 2;
END;

-- A pre-v1.1 collector job has its Collect step quitting on success; point it
-- at the next step so the Purge step actually runs.
SELECT @collectStepId = step_id
FROM msdb.dbo.sysjobsteps
WHERE job_id = @collectJobId AND step_name = N''Collect'' AND on_success_action <> 3;
IF @collectStepId IS NOT NULL
    EXEC msdb.dbo.sp_update_jobstep
          @job_id = @collectJobId
        , @step_id = @collectStepId
        , @on_success_action = 3;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N''SQLFlightRecorder Every Minute'')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
          @schedule_name = N''SQLFlightRecorder Every Minute''
        , @enabled = 1
        , @freq_type = 4
        , @freq_interval = 1
        , @freq_subday_type = 4
        , @freq_subday_interval = 1;
END;

IF NOT EXISTS (SELECT 1
               FROM msdb.dbo.sysjobschedules AS js
               INNER JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
               WHERE js.job_id = @collectJobId AND s.name = N''SQLFlightRecorder Every Minute'')
    EXEC msdb.dbo.sp_attach_schedule
          @job_id = @collectJobId
        , @schedule_name = N''SQLFlightRecorder Every Minute'';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = @collectJobId)
    EXEC msdb.dbo.sp_add_jobserver @job_id = @collectJobId;

-- Daily purge backstop job: create when missing (idempotent).
SELECT @purgeJobId = job_id FROM msdb.dbo.sysjobs WHERE name = N''SQLFlightRecorder Purge'';
IF @purgeJobId IS NULL
BEGIN
    EXEC msdb.dbo.sp_add_job
          @job_name = N''SQLFlightRecorder Purge''
        , @enabled = 1
        , @description = N''Runs dbo.sp_SQLFlightRecorder @Mode = Purge daily as a retention backstop, in case the collector job is disabled, changed, or failing.'';
    SELECT @purgeJobId = job_id FROM msdb.dbo.sysjobs WHERE name = N''SQLFlightRecorder Purge'';
END;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = @purgeJobId AND step_name = N''Purge'')
BEGIN
    EXEC msdb.dbo.sp_add_jobstep
          @job_id = @purgeJobId
        , @step_name = N''Purge''
        , @subsystem = N''TSQL''
        , @database_name = N''' + REPLACE(DB_NAME(), N'''', N'''''') + N'''
        , @command = N''EXEC dbo.sp_SQLFlightRecorder @Mode = N''''Purge'''', @WhatIf = 0;''
        , @on_success_action = 1
        , @on_fail_action = 2;
END;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N''SQLFlightRecorder Daily Purge'')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
          @schedule_name = N''SQLFlightRecorder Daily Purge''
        , @enabled = 1
        , @freq_type = 4
        , @freq_interval = 1
        , @freq_subday_type = 1
        , @active_start_time = 23000;
END;

IF NOT EXISTS (SELECT 1
               FROM msdb.dbo.sysjobschedules AS js
               INNER JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
               WHERE js.job_id = @purgeJobId AND s.name = N''SQLFlightRecorder Daily Purge'')
    EXEC msdb.dbo.sp_attach_schedule
          @job_id = @purgeJobId
        , @schedule_name = N''SQLFlightRecorder Daily Purge'';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = @purgeJobId)
    EXEC msdb.dbo.sp_add_jobserver @job_id = @purgeJobId;
';
                    EXEC sys.sp_executesql @AgentSql;

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobName')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'AgentJobName', @AgentJobName, N'SQL Agent collector job created by Install opt-in.');

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'AgentJobCreatedBySQLFlightRecorder', N'1', N'This procedure created the SQL Agent collector job.');

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'PurgeAgentJobName')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'PurgeAgentJobName', @PurgeAgentJobName, N'SQL Agent daily purge job created by Install opt-in (D-199).');

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'PurgeAgentJobCreatedBySQLFlightRecorder')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'PurgeAgentJobCreatedBySQLFlightRecorder', N'1', N'This procedure created the SQL Agent daily purge job.');

                    -- A pre-v1.1 unsupported-platform marker ('0') must not
                    -- mask jobs that were just created on a capable platform.
                    UPDATE dbo.FR_Config
                    SET ConfigValue = N'1', ModifiedUtc = SYSUTCDATETIME()
                    WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder'
                      AND ConfigValue <> N'1';

                    SET @InstallAgentSummary = N' SQL Agent jobs ensured: SQLFlightRecorder Collect (Collect then Purge, every minute) and SQLFlightRecorder Purge (daily 02:30 retention backstop).';
                END;
            END;
			
            -- v0.2 views (FR_v_*). Drop-then-create for 2012/2014 compatibility
            -- (no CREATE OR ALTER before 2016). Each view is bounded/simple.
            DECLARE @ViewSql nvarchar(max);

            IF OBJECT_ID(N'dbo.FR_v_RecentRuns', N'V') IS NOT NULL DROP VIEW dbo.FR_v_RecentRuns;
            SET @ViewSql = N'
CREATE VIEW dbo.FR_v_RecentRuns
AS
SELECT TOP (100)
      RunId, Mode, Status, StartUtc, EndUtc,
      DATEDIFF(millisecond, StartUtc, ISNULL(EndUtc, SYSUTCDATETIME())) AS DurationMs,
      Reason, LoginName, HostName
FROM dbo.FR_RunLog
ORDER BY RunId DESC;';
            EXEC sys.sp_executesql @ViewSql;

            IF OBJECT_ID(N'dbo.FR_v_LatestSnapshots', N'V') IS NOT NULL DROP VIEW dbo.FR_v_LatestSnapshots;
            SET @ViewSql = N'
CREATE VIEW dbo.FR_v_LatestSnapshots
AS
SELECT TOP (100)
      s.SnapshotId, s.SnapshotUtc, s.RunId, s.InstanceFingerprint
FROM dbo.FR_Snapshot AS s
ORDER BY s.SnapshotUtc DESC, s.SnapshotId DESC;';
            EXEC sys.sp_executesql @ViewSql;

            IF OBJECT_ID(N'dbo.FR_v_CollectorHealth', N'V') IS NOT NULL DROP VIEW dbo.FR_v_CollectorHealth;
            SET @ViewSql = N'
CREATE VIEW dbo.FR_v_CollectorHealth
AS
SELECT
      st.StepName,
      COUNT(1)                                            AS TotalSteps,
      SUM(CASE WHEN st.Status = N''Success'' THEN 1 ELSE 0 END) AS SuccessCount,
      SUM(CASE WHEN st.Status = N''Error''   THEN 1 ELSE 0 END) AS ErrorCount,
      SUM(CASE WHEN st.Status = N''Skipped'' THEN 1 ELSE 0 END) AS SkippedCount,
      MAX(st.StartUtc)                                    AS LastRunUtc
FROM dbo.FR_RunLogStep AS st
GROUP BY st.StepName;';
            EXEC sys.sp_executesql @ViewSql;

            IF OBJECT_ID(N'dbo.FR_v_RepositoryFootprint', N'V') IS NOT NULL DROP VIEW dbo.FR_v_RepositoryFootprint;
            SET @ViewSql = N'
CREATE VIEW dbo.FR_v_RepositoryFootprint
AS
SELECT
      t.name                          AS TableName,
      SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS [RowCount],
      SUM(ps.used_page_count) * 8     AS UsedKb
FROM sys.tables AS t
INNER JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N''dbo'')
  AND t.name LIKE N''FR\_%'' ESCAPE N''\''
GROUP BY t.name;';
            EXEC sys.sp_executesql @ViewSql;

            IF OBJECT_ID(N'dbo.FR_v_StatusSupport', N'V') IS NOT NULL DROP VIEW dbo.FR_v_StatusSupport;
            SET @ViewSql = N'
CREATE VIEW dbo.FR_v_StatusSupport
AS
SELECT
      (SELECT COUNT(1) FROM dbo.FR_Snapshot)                       AS SnapshotCount,
      (SELECT MAX(SnapshotUtc) FROM dbo.FR_Snapshot)               AS LatestSnapshotUtc,
      (SELECT COUNT(1) FROM dbo.FR_RunLog)                         AS RunCount,
      (SELECT COUNT(1) FROM dbo.FR_RunLog WHERE Status = N''Error'') AS RunErrorCount,
      (SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N''SchemaVersion'') AS SchemaVersion;';
            EXEC sys.sp_executesql @ViewSql;

            SELECT
                N'Success' AS Status,
                DB_NAME() AS DatabaseName,
                @SchemaVersion AS SchemaVersion,
                25 AS TableCount,
                CONCAT(N'Installation complete. 25 core FR_* tables + 5 FR_v_* views created (19 v0.1/v0.2 + 4 v0.3 + 2 v0.4).',
                       @InstallAgentSummary) AS Message;

				
				
            RETURN;

        END TRY
        BEGIN CATCH
            SELECT
                N'Error' AS Status,
                N'InstallFailed' AS ErrorCode,
                ERROR_MESSAGE() AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END CATCH;
    END;

    -- =========================================================================
    -- Mode: UNINSTALL (D-183)
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'UNINSTALL'
    BEGIN
        -- Nested IF on purpose: the inner statement must not bind dbo.FR_RunLog
        -- in the same statement as its existence guard, or Uninstall errors on
        -- a database where Install never ran (deferred name resolution binds
        -- per statement, not per predicate).
        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.FR_RunLog WHERE Mode = N'Collect' AND Status = N'InProgress')
            BEGIN
                SELECT N'Error' AS Status, N'CollectInProgress' AS ErrorCode,
                    N'Collect is in progress. Retry uninstall later.' AS Message,
                    @ToolVersion AS ToolVersion;
                RETURN;
            END;
        END;

        IF @WhatIf = 1
        BEGIN
            -- @WhatIf must be safe on a database where Install never ran:
            -- dbo.FR_Config is only referenced behind an existence check, in
            -- its own statement, staged through a table variable so the
            -- result stays a single result set.
            DECLARE @WhatIfAgentJob TABLE (ObjectName sysname NOT NULL);

            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
            BEGIN
                INSERT INTO @WhatIfAgentJob (ObjectName)
                SELECT TRY_CONVERT(sysname, c.ConfigValue)
                FROM dbo.FR_Config AS c
                WHERE c.ConfigKey = N'AgentJobName'
                  AND TRY_CONVERT(sysname, c.ConfigValue) IS NOT NULL
                  AND EXISTS
                  (
                      SELECT 1
                      FROM dbo.FR_Config AS c2
                      WHERE c2.ConfigKey = N'AgentJobCreatedBySQLFlightRecorder'
                        AND c2.ConfigValue = N'1'
                  );

                -- Daily purge backstop job (D-199), same created-by-us gate.
                INSERT INTO @WhatIfAgentJob (ObjectName)
                SELECT TRY_CONVERT(sysname, c.ConfigValue)
                FROM dbo.FR_Config AS c
                WHERE c.ConfigKey = N'PurgeAgentJobName'
                  AND TRY_CONVERT(sysname, c.ConfigValue) IS NOT NULL
                  AND EXISTS
                  (
                      SELECT 1
                      FROM dbo.FR_Config AS c2
                      WHERE c2.ConfigKey = N'PurgeAgentJobCreatedBySQLFlightRecorder'
                        AND c2.ConfigValue = N'1'
                  );
            END;
            SELECT
                N'WhatIf' AS Status,
                ObjectType,
                N'dbo' AS SchemaName,
                ObjectName,
                CASE WHEN @PreserveRunLog = 1 AND ObjectName IN (N'FR_RunLog', N'FR_RunLogStep')
                     THEN N'Rename' ELSE N'Drop' END AS Action
            FROM (
                SELECT N'VIEW' AS ObjectType, N'FR_v_RecentRuns' AS ObjectName
                UNION ALL SELECT N'VIEW', N'FR_v_LatestSnapshots'
                UNION ALL SELECT N'VIEW', N'FR_v_CollectorHealth'
                UNION ALL SELECT N'VIEW', N'FR_v_RepositoryFootprint'
                UNION ALL SELECT N'VIEW', N'FR_v_StatusSupport'
                UNION ALL SELECT N'TABLE', N'FR_InstanceSnapshot'
                UNION ALL SELECT N'TABLE', N'FR_Configuration'
                UNION ALL SELECT N'TABLE', N'FR_Request'
                UNION ALL SELECT N'TABLE', N'FR_Wait'
                UNION ALL SELECT N'TABLE', N'FR_FileStat'
                UNION ALL SELECT N'TABLE', N'FR_PerfCounter'
                UNION ALL SELECT N'TABLE', N'FR_Tempdb'
                UNION ALL SELECT N'TABLE', N'FR_Memory'
                UNION ALL SELECT N'TABLE', N'FR_AgentJob'
                UNION ALL SELECT N'TABLE', N'FR_BackupHistory'
                UNION ALL SELECT N'TABLE', N'FR_AlwaysOnState'
                UNION ALL SELECT N'TABLE', N'FR_Deadlock'
                UNION ALL SELECT N'TABLE', N'FR_QueryPlan'
                UNION ALL SELECT N'TABLE', N'FR_QueryStoreTopN'
                UNION ALL SELECT N'TABLE', N'FR_ErrorLog'
                UNION ALL SELECT N'TABLE', N'FR_SchemaActivity'
                UNION ALL SELECT N'TABLE', N'FR_PlanCacheSummary'
                UNION ALL SELECT N'TABLE', N'FR_QueryText'
                UNION ALL SELECT N'TABLE', N'FR_Snapshot'
                UNION ALL SELECT N'TABLE', N'FR_RunLogStep'
                UNION ALL SELECT N'TABLE', N'FR_RunLog'
                UNION ALL SELECT N'TABLE', N'FR_Rules'
                UNION ALL SELECT N'TABLE', N'FR_Config'
            ) AS Objects
            WHERE (ObjectType = N'TABLE' AND OBJECT_ID(CONCAT(N'dbo.', ObjectName), N'U') IS NOT NULL)
               OR (ObjectType = N'VIEW'  AND OBJECT_ID(CONCAT(N'dbo.', ObjectName), N'V') IS NOT NULL)

            UNION ALL

            SELECT
                N'WhatIf',
                N'SQL_AGENT_JOB',
                N'msdb',
                ObjectName,
                N'Drop'
            FROM @WhatIfAgentJob;

            RETURN;
        END;

        BEGIN TRY
            -- Drop v0.2 views first (no dependencies; safe in any order).
            IF OBJECT_ID(N'dbo.FR_v_RecentRuns', N'V') IS NOT NULL DROP VIEW dbo.FR_v_RecentRuns;
            IF OBJECT_ID(N'dbo.FR_v_LatestSnapshots', N'V') IS NOT NULL DROP VIEW dbo.FR_v_LatestSnapshots;
            IF OBJECT_ID(N'dbo.FR_v_CollectorHealth', N'V') IS NOT NULL DROP VIEW dbo.FR_v_CollectorHealth;
            IF OBJECT_ID(N'dbo.FR_v_RepositoryFootprint', N'V') IS NOT NULL DROP VIEW dbo.FR_v_RepositoryFootprint;
            IF OBJECT_ID(N'dbo.FR_v_StatusSupport', N'V') IS NOT NULL DROP VIEW dbo.FR_v_StatusSupport;
            IF OBJECT_ID(N'dbo.FR_HaState', N'U')    IS NOT NULL DROP TABLE dbo.FR_HaState;
            IF OBJECT_ID(N'dbo.FR_BufferPool', N'U') IS NOT NULL DROP TABLE dbo.FR_BufferPool;

            -- Remove SQL Agent jobs only if this procedure created them.
            -- Idempotent: each removal is guarded by an IF EXISTS in msdb, so
            -- an already-missing job never fails Uninstall (D-199).
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
            BEGIN
                DECLARE @UninstallAgentJobName sysname = NULL;
                DECLARE @UninstallAgentCreated nvarchar(10) = NULL;
                DECLARE @UninstallPurgeJobName sysname = NULL;
                DECLARE @UninstallPurgeCreated nvarchar(10) = NULL;
                DECLARE @UninstallAgentSql nvarchar(max);

                SELECT @UninstallAgentJobName = TRY_CONVERT(sysname, ConfigValue)
                FROM dbo.FR_Config
                WHERE ConfigKey = N'AgentJobName';

                SELECT @UninstallAgentCreated = ConfigValue
                FROM dbo.FR_Config
                WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder';

                SELECT @UninstallPurgeJobName = TRY_CONVERT(sysname, ConfigValue)
                FROM dbo.FR_Config
                WHERE ConfigKey = N'PurgeAgentJobName';

                SELECT @UninstallPurgeCreated = ConfigValue
                FROM dbo.FR_Config
                WHERE ConfigKey = N'PurgeAgentJobCreatedBySQLFlightRecorder';

                IF @UninstallAgentCreated = N'1'
                   AND @UninstallAgentJobName IS NOT NULL
                   AND DB_ID(N'msdb') IS NOT NULL
                   AND OBJECT_ID(N'msdb.dbo.sp_delete_job', N'P') IS NOT NULL
                BEGIN
                    SET @UninstallAgentSql = N'
USE msdb;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N''' + REPLACE(@UninstallAgentJobName, N'''', N'''''') + N''')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N''' + REPLACE(@UninstallAgentJobName, N'''', N'''''') + N''';
END;
';
                    EXEC sys.sp_executesql @UninstallAgentSql;
                END;

                IF @UninstallPurgeCreated = N'1'
                   AND @UninstallPurgeJobName IS NOT NULL
                   AND DB_ID(N'msdb') IS NOT NULL
                   AND OBJECT_ID(N'msdb.dbo.sp_delete_job', N'P') IS NOT NULL
                BEGIN
                    SET @UninstallAgentSql = N'
USE msdb;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N''' + REPLACE(@UninstallPurgeJobName, N'''', N'''''') + N''')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = N''' + REPLACE(@UninstallPurgeJobName, N'''', N'''''') + N''';
END;
';
                    EXEC sys.sp_executesql @UninstallAgentSql;
                END;
            END;

            -- Snapshot children first.
            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL DROP TABLE dbo.FR_InstanceSnapshot;
            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL DROP TABLE dbo.FR_Configuration;
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL DROP TABLE dbo.FR_Request;
            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL DROP TABLE dbo.FR_Wait;
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL DROP TABLE dbo.FR_FileStat;
            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL DROP TABLE dbo.FR_PerfCounter;
            IF OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL DROP TABLE dbo.FR_Tempdb;
            IF OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL DROP TABLE dbo.FR_Memory;
            IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL DROP TABLE dbo.FR_AgentJob;
            IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL DROP TABLE dbo.FR_BackupHistory;
            IF OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NOT NULL DROP TABLE dbo.FR_AlwaysOnState;
            IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL DROP TABLE dbo.FR_Deadlock;
            IF OBJECT_ID(N'dbo.FR_QueryPlan', N'U') IS NOT NULL DROP TABLE dbo.FR_QueryPlan;
            IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL DROP TABLE dbo.FR_QueryStoreTopN;
            IF OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL DROP TABLE dbo.FR_ErrorLog;
            IF OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NOT NULL DROP TABLE dbo.FR_SchemaActivity;
            IF OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL DROP TABLE dbo.FR_PlanCacheSummary;

            -- Independent / parent tables.
            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL DROP TABLE dbo.FR_QueryText;
            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL DROP TABLE dbo.FR_Snapshot;

            -- Run log archive or removal after FR_Snapshot is gone.
            IF @PreserveRunLog = 1
            BEGIN
                -- Each rename runs only when its table exists. The prior
                -- shape (IF <exists> DECLARE ...; EXEC sp_rename;) executed
                -- sp_rename unconditionally and failed with a NULL @newname
                -- whenever a run-log table was absent.
                DECLARE @UninstallArchiveSuffix nvarchar(32) = CONCAT(
                    CONVERT(nvarchar(8), SYSUTCDATETIME(), 112), N'_',
                    REPLACE(CONVERT(nvarchar(8), SYSUTCDATETIME(), 108), N':', N'')
                );
                DECLARE @RunLogStepNewname sysname = CONCAT(N'FR_RunLogStep_Archive_', @UninstallArchiveSuffix);
                DECLARE @RunLogNewname     sysname = CONCAT(N'FR_RunLog_Archive_', @UninstallArchiveSuffix);

                IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
                BEGIN
                    EXEC sys.sp_rename
                          @objname = N'dbo.FR_RunLogStep'
                        , @newname = @RunLogStepNewname
                        , @objtype = N'OBJECT';
                END;

                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                BEGIN
                    EXEC sys.sp_rename
                          @objname = N'dbo.FR_RunLog'
                        , @newname = @RunLogNewname
                        , @objtype = N'OBJECT';
                END;
            END
            ELSE
            BEGIN
                IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL DROP TABLE dbo.FR_RunLogStep;
                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL DROP TABLE dbo.FR_RunLog;
            END;

            IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL DROP TABLE dbo.FR_Rules;
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL DROP TABLE dbo.FR_Config;

            SELECT
                N'Success' AS Status,
                DB_NAME() AS DatabaseName,
                N'Uninstall completed.' AS Message;
            RETURN;
        END TRY
        BEGIN CATCH
            SELECT
                N'Error' AS Status,
                N'UninstallFailed' AS ErrorCode,
                ERROR_MESSAGE() AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END CATCH;
    END;
    -- =========================================================================
    -- Mode: STATUS
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'STATUS'
    BEGIN
        DECLARE @StatusIsInstalled bit =
            CASE WHEN OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL THEN 0 ELSE 1 END;

        DECLARE @StatusRepositorySchemaVersion nvarchar(4000) = NULL;

        IF @StatusIsInstalled = 1
        BEGIN
            SELECT @StatusRepositorySchemaVersion = ConfigValue
            FROM dbo.FR_Config
            WHERE ConfigKey = N'SchemaVersion';
        END;

        -- Result Set 1: Installation summary
        SELECT
              DB_NAME() AS DatabaseName
            , CASE WHEN @StatusIsInstalled = 1 THEN N'Installed' ELSE N'NotInstalled' END AS InstallStatus
            , @SchemaVersion AS ProcedureSchemaVersion
            , @StatusRepositorySchemaVersion AS RepositorySchemaVersion
            , @ToolVersion AS ToolVersion
            , CASE
                  WHEN @StatusIsInstalled = 1
                  THEN N'SQLFlightRecorder repository is installed.'
                  ELSE N'SQLFlightRecorder repository is not installed. Run Install mode first.'
              END AS Message;

        -- Result Set 2: Configuration
        IF @StatusIsInstalled = 1
        BEGIN
            SELECT ConfigKey, ConfigValue, Description, ModifiedUtc
            FROM dbo.FR_Config
            ORDER BY ConfigKey;
        END
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS sysname) AS ConfigKey
                , CAST(NULL AS nvarchar(4000)) AS ConfigValue
                , CAST(NULL AS nvarchar(400)) AS Description
                , CAST(NULL AS datetime2(3)) AS ModifiedUtc
            WHERE 1 = 0;
        END;

        -- Result Set 3: Rule catalog
        IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL
        BEGIN
            SELECT
                  RuleId
                , Category
                , Severity
                , Confidence
                , EvidenceType
                , LifecycleState
                , ShortDescription
                , IntroducedInVersion
            FROM dbo.FR_Rules
            ORDER BY RuleId;
        END
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS nvarchar(60)) AS RuleId
                , CAST(NULL AS nvarchar(30)) AS Category
                , CAST(NULL AS nvarchar(20)) AS Severity
                , CAST(NULL AS nvarchar(20)) AS Confidence
                , CAST(NULL AS nvarchar(20)) AS EvidenceType
                , CAST(NULL AS nvarchar(20)) AS LifecycleState
                , CAST(NULL AS nvarchar(400)) AS ShortDescription
                , CAST(NULL AS nvarchar(20)) AS IntroducedInVersion
            WHERE 1 = 0;
        END;

        -- Result Set 4: Recent runs
        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        BEGIN
            SELECT TOP (10)
                  RunId
                , StartUtc
                , EndUtc
                , Mode
                , Status
                , Reason
                , LoginName
                , HostName
            FROM dbo.FR_RunLog
            ORDER BY RunId DESC;
        END
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS bigint) AS RunId
                , CAST(NULL AS datetime2(3)) AS StartUtc
                , CAST(NULL AS datetime2(3)) AS EndUtc
                , CAST(NULL AS nvarchar(30)) AS Mode
                , CAST(NULL AS nvarchar(20)) AS Status
                , CAST(NULL AS nvarchar(400)) AS Reason
                , CAST(NULL AS sysname) AS LoginName
                , CAST(NULL AS sysname) AS HostName
            WHERE 1 = 0;
        END;

        -- Result Set 5: Repository size
        IF @StatusIsInstalled = 1
        BEGIN
            SELECT
                  t.name AS TableName
                , SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS [RowCount]
                , SUM(ps.used_page_count) * 8 AS UsedKb
            FROM sys.tables AS t
            INNER JOIN sys.dm_db_partition_stats AS ps
                ON t.object_id = ps.object_id
            WHERE t.schema_id = SCHEMA_ID(N'dbo')
              AND t.name LIKE N'FR\_%' ESCAPE N'\'
            GROUP BY t.name
            ORDER BY t.name;
        END
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS sysname) AS TableName
                , CAST(NULL AS bigint) AS [RowCount]
                , CAST(NULL AS bigint) AS UsedKb
            WHERE 1 = 0;
        END;

        -- Result Set 6: Capability snapshot (real probe data; closed key set, D-127)
        SELECT N'Tool-Version' AS CapabilityKey, @ToolVersion AS CapabilityValue
        UNION ALL SELECT N'Part-Number', CAST(@PartNumber AS nvarchar(10))
        UNION ALL SELECT N'Schema-Version', @SchemaVersion
        UNION ALL SELECT N'Installed', CASE WHEN @StatusIsInstalled = 1 THEN N'1' ELSE N'0' END
        UNION ALL SELECT N'EngineEdition', ISNULL(CONVERT(nvarchar(10), @EngineEditionProbe), N'')
        UNION ALL SELECT N'ProductMajorVersion', ISNULL(CONVERT(nvarchar(10), @ProductMajorProbe), N'')
        UNION ALL SELECT N'ProductLevel', ISNULL(@ProductLevelProbe, N'')
        UNION ALL SELECT N'Platform', @PlatformProbe
        UNION ALL SELECT N'IsAzureSqlDb', CONVERT(nvarchar(1), @IsAzureSqlDb)
        UNION ALL SELECT N'IsAzureManagedInstance', CONVERT(nvarchar(1), @IsAzureManagedInst)
        UNION ALL SELECT N'HasMsdb', CONVERT(nvarchar(1), @HasMsdb)
        UNION ALL SELECT N'HasAgent', CONVERT(nvarchar(1), @HasAgent)
        UNION ALL SELECT N'IsHadrEnabled', ISNULL(CONVERT(nvarchar(1), @IsHadrEnabledProbe), N'0')
        UNION ALL SELECT N'HasQueryStoreSupport', CONVERT(nvarchar(1), @HasQueryStoreSupport)
        UNION ALL SELECT N'CollectQueryStore', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'CollectQueryStore'), N'')
        UNION ALL SELECT N'CollectErrorLog', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'CollectErrorLog'), N'')
        UNION ALL SELECT N'CollectSchemaActivity', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'CollectSchemaActivity'), N'')
        UNION ALL SELECT N'CollectPlanCacheSummary', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'CollectPlanCacheSummary'), N'')
        -- v0.4 capability + config surfacing
        UNION ALL SELECT N'HasAdvancedHaSupport', CONVERT(nvarchar(1), @HasAdvancedHaSupport)
        UNION ALL SELECT N'HasBufferPoolSupport', CONVERT(nvarchar(1), @HasBufferPoolSupport)
        UNION ALL SELECT N'HasTimeZoneSupport', CONVERT(nvarchar(1), @HasTimeZoneSupport)
        -- Plan analysis is disabled by design (D-015/D-046/D-082); the key is
        -- kept in the closed set (D-127) and reports 0 in every build.
        UNION ALL SELECT N'PlanAnalysisSupport', N'0'
        UNION ALL SELECT N'EnableAdvancedHaCollector', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'EnableAdvancedHaCollector'), N'')
        UNION ALL SELECT N'EnableBufferPoolCollector', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'EnableBufferPoolCollector'), N'')
        UNION ALL SELECT N'BaselineLookbackHours', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'BaselineLookbackHours'), N'')
        UNION ALL SELECT N'TimeZoneMode', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'TimeZoneMode'), N'')
        UNION ALL SELECT N'FR_HaState'      AS TableName, NULL WHERE OBJECT_ID(N'dbo.FR_HaState', N'U')      IS NOT NULL
        UNION ALL SELECT N'FR_BufferPool'   AS TableName, NULL WHERE OBJECT_ID(N'dbo.FR_BufferPool', N'U')   IS NOT NULL;

        -- Result Set 7: Retention and purge health (additive per D-023; D-199).
        -- Six fixed checks so operators can see whether purge is keeping the
        -- repository bounded before Report performance degrades.
        DECLARE @HealthSnapRetention int = 7;
        DECLARE @HealthRunLogRetention int = 28;
        DECLARE @HealthTableWarnRows bigint = 5000000;
        DECLARE @HealthOldestSnapshotUtc datetime2(3) = NULL;
        DECLARE @HealthLastPurgeUtc datetime2(3) = NULL;
        DECLARE @HealthLastPurgeStatus nvarchar(20) = NULL;
        DECLARE @HealthCollectJobName sysname = N'SQLFlightRecorder Collect';
        DECLARE @HealthPurgeJobName sysname = N'SQLFlightRecorder Purge';
        DECLARE @HealthCollectJobExists bit = 0;
        DECLARE @HealthCollectJobHasPurgeStep bit = 0;
        DECLARE @HealthPurgeJobExists bit = 0;
        DECLARE @HealthMsdbReadable bit = 0;
        DECLARE @HealthBigTables nvarchar(1000) = N'';

        IF @StatusIsInstalled = 1
        BEGIN
            SELECT @HealthSnapRetention = ISNULL(TRY_CONVERT(int, ConfigValue), 7)
            FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotRetentionDays';

            SELECT @HealthRunLogRetention = ISNULL(TRY_CONVERT(int, ConfigValue), 28)
            FROM dbo.FR_Config WHERE ConfigKey = N'RunLogRetentionDays';

            SELECT @HealthTableWarnRows = ISNULL(TRY_CONVERT(bigint, ConfigValue), 5000000)
            FROM dbo.FR_Config WHERE ConfigKey = N'RepositoryTableWarnRows';
            IF @HealthTableWarnRows IS NULL OR @HealthTableWarnRows < 1 SET @HealthTableWarnRows = 5000000;

            SELECT @HealthCollectJobName = ISNULL(TRY_CONVERT(sysname, ConfigValue), @HealthCollectJobName)
            FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobName';

            SELECT @HealthPurgeJobName = ISNULL(TRY_CONVERT(sysname, ConfigValue), @HealthPurgeJobName)
            FROM dbo.FR_Config WHERE ConfigKey = N'PurgeAgentJobName';

            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL
                SELECT @HealthOldestSnapshotUtc = MIN(SnapshotUtc) FROM dbo.FR_Snapshot;

            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                SELECT TOP (1) @HealthLastPurgeUtc = StartUtc, @HealthLastPurgeStatus = Status
                FROM dbo.FR_RunLog
                WHERE Mode = N'Purge' AND Status IN (N'Success', N'PartialSuccess')
                ORDER BY RunId DESC;

            SELECT @HealthBigTables = ISNULL(STUFF((
                SELECT TOP (10) N'; ' + t.name + N'=' + CONVERT(nvarchar(20), SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END))
                FROM sys.tables AS t
                INNER JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = t.object_id
                WHERE t.schema_id = SCHEMA_ID(N'dbo')
                  AND t.name LIKE N'FR\_%' ESCAPE N'\'
                GROUP BY t.name
                HAVING SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) > @HealthTableWarnRows
                ORDER BY t.name
                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'');

            -- Job checks read msdb metadata via dynamic SQL (D-112) so the
            -- procedure still compiles and runs where msdb does not exist.
            IF @HasAgent = 1
            BEGIN
                BEGIN TRY
                    DECLARE @HealthAgentSql nvarchar(max) = N'
SELECT @jobExists = CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @collectJob) THEN 1 ELSE 0 END,
       @hasPurgeStep = CASE WHEN EXISTS (SELECT 1
                                         FROM msdb.dbo.sysjobs AS j
                                         INNER JOIN msdb.dbo.sysjobsteps AS st ON st.job_id = j.job_id
                                         WHERE j.name = @collectJob
                                           AND st.command LIKE N''%sp_SQLFlightRecorder%''
                                           AND st.command LIKE N''%Purge%'') THEN 1 ELSE 0 END,
       @purgeJobExists = CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @purgeJob) THEN 1 ELSE 0 END;';
                    EXEC sys.sp_executesql @HealthAgentSql,
                         N'@collectJob sysname, @purgeJob sysname, @jobExists bit OUTPUT, @hasPurgeStep bit OUTPUT, @purgeJobExists bit OUTPUT',
                         @collectJob = @HealthCollectJobName, @purgeJob = @HealthPurgeJobName,
                         @jobExists = @HealthCollectJobExists OUTPUT,
                         @hasPurgeStep = @HealthCollectJobHasPurgeStep OUTPUT,
                         @purgeJobExists = @HealthPurgeJobExists OUTPUT;
                    SET @HealthMsdbReadable = 1;
                END TRY
                BEGIN CATCH
                    SET @HealthMsdbReadable = 0;   -- msdb denied: report Unknown, never fail Status
                END CATCH;
            END;

            SELECT CheckName, CheckStatus, Detail
            FROM (
                SELECT 1 AS CheckOrdinal,
                    N'RetentionConfiguration' AS CheckName,
                    CASE WHEN @HealthSnapRetention NOT BETWEEN 1 AND 31
                              OR @HealthRunLogRetention NOT BETWEEN 1 AND 124
                         THEN N'Warning' ELSE N'OK' END AS CheckStatus,
                    CONCAT(N'SnapshotRetentionDays=', @HealthSnapRetention, N' (allowed 1-31); RunLogRetentionDays=',
                           @HealthRunLogRetention, N' (allowed 1-124).',
                           CASE WHEN @HealthSnapRetention NOT BETWEEN 1 AND 31
                                     OR @HealthRunLogRetention NOT BETWEEN 1 AND 124
                                THEN N' Value predates the v1.1 guardrails; reconfigure via Configure mode.'
                                ELSE N'' END) AS Detail

                UNION ALL
                SELECT 2,
                    N'OldestSnapshotVsRetention',
                    CASE WHEN @HealthOldestSnapshotUtc IS NULL THEN N'OK'
                         WHEN @HealthOldestSnapshotUtc < DATEADD(day, -@HealthSnapRetention, SYSUTCDATETIME()) THEN N'Warning'
                         ELSE N'OK' END,
                    CASE WHEN @HealthOldestSnapshotUtc IS NULL THEN N'No snapshots captured yet.'
                         ELSE CONCAT(N'Oldest snapshot ', CONVERT(nvarchar(30), @HealthOldestSnapshotUtc, 126), N'Z (age ',
                                     DATEDIFF(day, @HealthOldestSnapshotUtc, SYSUTCDATETIME()), N' day(s); retention ',
                                     @HealthSnapRetention, N' day(s)).',
                                     CASE WHEN @HealthOldestSnapshotUtc < DATEADD(day, -@HealthSnapRetention, SYSUTCDATETIME())
                                          THEN N' Rows older than retention exist; ensure Purge (@WhatIf = 0) is scheduled and running.'
                                          ELSE N'' END) END

                UNION ALL
                SELECT 3,
                    N'PurgeKeepingUp',
                    CASE WHEN @HealthOldestSnapshotUtc IS NOT NULL
                              AND @HealthOldestSnapshotUtc < DATEADD(day, -(@HealthSnapRetention + 2), SYSUTCDATETIME())
                         THEN N'Warning' ELSE N'OK' END,
                    CONCAT(N'Last completed Purge: ',
                           CASE WHEN @HealthLastPurgeUtc IS NULL THEN N'(never)'
                                ELSE CONCAT(CONVERT(nvarchar(30), @HealthLastPurgeUtc, 126), N'Z (', @HealthLastPurgeStatus, N')') END,
                           N'.',
                           CASE WHEN @HealthOldestSnapshotUtc IS NOT NULL
                                     AND @HealthOldestSnapshotUtc < DATEADD(day, -(@HealthSnapRetention + 2), SYSUTCDATETIME())
                                THEN N' Oldest data exceeds retention by more than 2 days; purge appears not to be keeping up. Large backlogs converge over repeated Purge runs.'
                                ELSE N'' END)

                UNION ALL
                SELECT 4,
                    N'CollectorJobPurgeStep',
                    CASE WHEN @HasAgent = 0 THEN N'NotApplicable'
                         WHEN @HealthMsdbReadable = 0 THEN N'Unknown'
                         WHEN @HealthCollectJobExists = 0 THEN N'NotApplicable'
                         WHEN @HealthCollectJobHasPurgeStep = 0 THEN N'Warning'
                         ELSE N'OK' END,
                    CASE WHEN @HasAgent = 0 THEN N'No SQL Agent on this platform; schedule Collect and Purge externally (see docs/operations/scheduling.md).'
                         WHEN @HealthMsdbReadable = 0 THEN N'msdb job metadata could not be read (permissions); job health unknown.'
                         WHEN @HealthCollectJobExists = 0 THEN CONCAT(N'Collector job ''', @HealthCollectJobName, N''' not found; if you schedule externally, ensure Purge also runs.')
                         WHEN @HealthCollectJobHasPurgeStep = 0 THEN CONCAT(N'Collector job ''', @HealthCollectJobName, N''' has no Purge step; re-run Install with @CreateAgentJob = 1 to add it.')
                         ELSE CONCAT(N'Collector job ''', @HealthCollectJobName, N''' includes a Purge step.') END

                UNION ALL
                SELECT 5,
                    N'DailyPurgeJob',
                    CASE WHEN @HasAgent = 0 THEN N'NotApplicable'
                         WHEN @HealthMsdbReadable = 0 THEN N'Unknown'
                         WHEN @HealthPurgeJobExists = 1 THEN N'OK'
                         WHEN @HealthCollectJobExists = 1 THEN N'Warning'
                         ELSE N'NotApplicable' END,
                    CASE WHEN @HasAgent = 0 THEN N'No SQL Agent on this platform; schedule a daily Purge externally.'
                         WHEN @HealthMsdbReadable = 0 THEN N'msdb job metadata could not be read (permissions); job health unknown.'
                         WHEN @HealthPurgeJobExists = 1 THEN CONCAT(N'Daily purge job ''', @HealthPurgeJobName, N''' exists.')
                         WHEN @HealthCollectJobExists = 1 THEN CONCAT(N'Daily purge job ''', @HealthPurgeJobName, N''' is missing; re-run Install with @CreateAgentJob = 1 to create the backstop.')
                         ELSE N'No SQLFlightRecorder Agent jobs found; if you schedule externally, ensure Purge also runs daily.' END

                UNION ALL
                SELECT 6,
                    N'RepositoryTableSize',
                    CASE WHEN @HealthBigTables <> N'' THEN N'Warning' ELSE N'OK' END,
                    CASE WHEN @HealthBigTables <> N''
                         THEN CONCAT(N'FR_* table(s) over ', @HealthTableWarnRows, N' rows: ', @HealthBigTables,
                                     N'. Run Purge, and consider lowering SnapshotRetentionDays; large tables raise Report cost.')
                         ELSE CONCAT(N'No FR_* table exceeds ', @HealthTableWarnRows, N' rows (RepositoryTableWarnRows).') END
            ) AS Checks
            ORDER BY CheckOrdinal;
        END
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS nvarchar(60)) AS CheckName
                , CAST(NULL AS nvarchar(20)) AS CheckStatus
                , CAST(NULL AS nvarchar(1000)) AS Detail
            WHERE 1 = 0;
        END;

        RETURN;
    END;
    -- =========================================================================
    -- Mode: CONFIGURE
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'CONFIGURE'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'Configure requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @ConfigKey IS NULL
        BEGIN
            SELECT ConfigKey, ConfigValue, Description, ModifiedUtc
            FROM dbo.FR_Config
            ORDER BY ConfigKey;
            RETURN;
        END;

        DECLARE @ConfigureKey sysname = LTRIM(RTRIM(@ConfigKey));
        DECLARE @ConfigureOldValue nvarchar(4000) = NULL;
        DECLARE @ConfigureRunId bigint = NULL;

        IF @ConfigureKey NOT IN
        (
              N'SnapshotIntervalSeconds'
            , N'SnapshotRetentionDays'
            , N'RunLogRetentionDays'
            , N'MaxRowsPerCollector'
            , N'WaitStatsIgnoreList'
            , N'DisabledRules'
            , N'CriticalWaitTypes'
            -- v0.2 tunables
            , N'MaintenanceJobNamePatterns'
            , N'BlockingStormSessionThreshold'
            , N'TempdbVersionStoreWarnKb'
            -- v0.3 tunables
            , N'CollectQueryStore'
            , N'QueryStoreMaxDatabases'
            , N'QueryStoreCapacityWarnPercent'
            , N'QueryStoreRegressionFactor'
            , N'CollectErrorLog'
            , N'CollectSchemaActivity'
            , N'SchemaActivityMaxDatabases'
            , N'CollectPlanCacheSummary'
            , N'CompilationsPerSecWarn'
            -- v0.4 tunables
            , N'CollectAdvancedHa'
            , N'CollectBufferPool'
            , N'SecondaryLagWarnSeconds'
            , N'RedoQueueWarnKb'
            , N'BackupWarnDays'
            , N'CheckDbWarnDays'
            , N'TimeZoneMode'
            , N'TimeZoneName'
            -- v0.4.2 rule tunables
            , N'LongOpenTxnSeconds'
            , N'FileIoLatencyWarnMs'
            -- v1.1 retention guardrail (D-199)
            , N'RepositoryTableWarnRows'
        )
        
        BEGIN
            SELECT N'Error' AS Status, N'UnknownConfigKey' AS ErrorCode,
                CONCAT(N'Unknown or read-only config key: ', @ConfigureKey) AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @ConfigValue IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'MissingConfigValue' AS ErrorCode,
                N'@ConfigValue is required when @ConfigKey is supplied.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @ConfigureKey IN (
               N'SnapshotIntervalSeconds', N'SnapshotRetentionDays', N'RunLogRetentionDays', N'MaxRowsPerCollector',
               N'BlockingStormSessionThreshold', N'TempdbVersionStoreWarnKb',
               N'CollectQueryStore', N'QueryStoreMaxDatabases', N'QueryStoreCapacityWarnPercent', N'QueryStoreRegressionFactor',
               N'CollectErrorLog', N'CollectSchemaActivity', N'SchemaActivityMaxDatabases', N'CollectPlanCacheSummary',
               N'CompilationsPerSecWarn',
               N'CollectAdvancedHa', N'CollectBufferPool', N'SecondaryLagWarnSeconds', N'RedoQueueWarnKb',
               N'BackupWarnDays', N'CheckDbWarnDays',
               N'LongOpenTxnSeconds', N'FileIoLatencyWarnMs',
               N'RepositoryTableWarnRows')
           AND TRY_CONVERT(int, @ConfigValue) IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'InvalidConfigValue' AS ErrorCode,
                CONCAT(N'Config key ', @ConfigureKey, N' requires an integer value.') AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        -- Retention guardrails (D-199): SQLFR is an operational diagnostic
        -- recorder, not a long-term warehouse. Out-of-range values are refused
        -- before anything is written, so FR_Config is never updated on error.
        IF @ConfigureKey = N'SnapshotRetentionDays'
           AND (TRY_CONVERT(int, @ConfigValue) < 1 OR TRY_CONVERT(int, @ConfigValue) > 31)
        BEGIN
            SELECT N'Error' AS Status, N'InvalidConfigValue' AS ErrorCode,
                N'SnapshotRetentionDays must be between 1 and 31. Longer retention grows the FR_* repository and raises Report cost; export data you must keep longer.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @ConfigureKey = N'RunLogRetentionDays'
           AND (TRY_CONVERT(int, @ConfigValue) < 1 OR TRY_CONVERT(int, @ConfigValue) > 124)
        BEGIN
            SELECT N'Error' AS Status, N'InvalidConfigValue' AS ErrorCode,
                N'RunLogRetentionDays must be between 1 and 124. Longer retention grows the FR_* repository and raises Report cost; export data you must keep longer.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @ConfigureKey = N'RepositoryTableWarnRows'
           AND TRY_CONVERT(int, @ConfigValue) < 1
        BEGIN
            SELECT N'Error' AS Status, N'InvalidConfigValue' AS ErrorCode,
                N'RepositoryTableWarnRows must be a positive integer.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        SELECT @ConfigureOldValue = ConfigValue
        FROM dbo.FR_Config
        WHERE ConfigKey = @ConfigureKey;

        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        BEGIN
            INSERT INTO dbo.FR_RunLog
            (
                StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName
            )
            VALUES
            (
                SYSUTCDATETIME(), NULL, N'Configure', N'InProgress',
                CONCAT(N'Updating config key ', @ConfigureKey),
                SUSER_SNAME(), HOST_NAME()
            );

            SET @ConfigureRunId = SCOPE_IDENTITY();
        END;

        IF EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = @ConfigureKey)
        BEGIN
            UPDATE dbo.FR_Config
            SET ConfigValue = @ConfigValue,
                ModifiedUtc = SYSUTCDATETIME()
            WHERE ConfigKey = @ConfigureKey;
        END;
        ELSE
        BEGIN
            INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
            VALUES (@ConfigureKey, @ConfigValue, N'Configured through Configure mode.', SYSUTCDATETIME());
        END;

        IF @ConfigureRunId IS NOT NULL
        BEGIN
            UPDATE dbo.FR_RunLog
            SET EndUtc = SYSUTCDATETIME(),
                Status = N'Success',
                Reason = CONCAT(N'Updated ', @ConfigureKey)
            WHERE RunId = @ConfigureRunId;
        END;

        SELECT
              N'Success' AS Status
            , @ConfigureKey AS ConfigKey
            , @ConfigureOldValue AS OldConfigValue
            , @ConfigValue AS NewConfigValue
            , N'Configuration updated.' AS Message;

        RETURN;
    END;

    -- =========================================================================
    -- Mode: COLLECTDEBUG
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'COLLECTDEBUG'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'CollectDebug requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        INSERT INTO dbo.FR_RunLog
        (
            StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName
        )
        VALUES
        (
            SYSUTCDATETIME(), SYSUTCDATETIME(), N'CollectDebug', N'Success',
            N'Debug mode only. No collector rows were written.',
            SUSER_SNAME(), HOST_NAME()
        );

        SELECT
              N'Success' AS Status
            , N'CollectDebug' AS Mode
            , N'No collector rows were written.' AS Message
            , @ToolVersion AS ToolVersion;

        SELECT
              N'FR_Snapshot' AS ObjectName, CASE WHEN OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL THEN N'Missing' ELSE N'Present' END AS Status
        UNION ALL SELECT N'FR_RunLog', CASE WHEN OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_RunLogStep', CASE WHEN OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_InstanceSnapshot', CASE WHEN OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_Configuration', CASE WHEN OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_Request', CASE WHEN OBJECT_ID(N'dbo.FR_Request', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_Wait', CASE WHEN OBJECT_ID(N'dbo.FR_Wait', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_FileStat', CASE WHEN OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NULL THEN N'Missing' ELSE N'Present' END
        UNION ALL SELECT N'FR_PerfCounter', CASE WHEN OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NULL THEN N'Missing' ELSE N'Present' END;

        RETURN;
    END;

    -- =========================================================================
    -- Mode: COLLECTANDREPORT (D-024: documented, non-recommended convenience)
    -- Runs a bounded Collect, then a Report, in the same session by re-invoking
    -- the procedure. Respects @DatabaseName, @MinSeverity, @MaxFindings, @TopN,
    -- @OutputFormat, @IncludeQueryPlans, @Debug. @Debug routes the inner Collect
    -- to CollectDebug (D-128); it is not forwarded to Report.
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'COLLECTANDREPORT'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
           OR OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'CollectAndReport requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        EXEC dbo.sp_SQLFlightRecorder
              @Mode = N'Collect'
            , @TopN = @TopN
            , @IncludeQueryPlans = @IncludeQueryPlans
            , @Debug = @Debug;

        EXEC dbo.sp_SQLFlightRecorder
              @Mode = N'Report'
            , @DatabaseName = @DatabaseName
            , @StartTime = @StartTime
            , @EndTime = @EndTime
            , @MinSeverity = @MinSeverity
            , @MaxFindings = @MaxFindings
            , @TopN = @TopN
            , @OutputFormat = @OutputFormat
            , @IncludeQueryPlans = @IncludeQueryPlans;

        RETURN;
    END;

    -- =========================================================================
    -- Mode: INSTALLDEMODATA (D-182)
    -- Clearly-synthetic, idempotent demo rows in dbo.FR_* so Report shows sample
    -- findings. NO production DMVs. Refuses if real (non-demo) snapshots exist.
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'INSTALLDEMODATA'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
           OR OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'InstallDemoData requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        DECLARE @DemoFingerprint nvarchar(200) = N'SQLFlightRecorder-DEMO';

        -- Safe-by-default refusal: never mix demo and real data. No force
        -- flag exists in the public surface, so refuse cleanly if real data exists.
        IF EXISTS (SELECT 1 FROM dbo.FR_Snapshot
                   WHERE ISNULL(InstanceFingerprint, N'') <> @DemoFingerprint)
        BEGIN
            SELECT N'Refused' AS Status, N'RealDataPresent' AS ErrorCode,
                N'Real captured snapshots exist. InstallDemoData will not mix demo and real data. Use a dedicated sandbox database.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        BEGIN TRY
            DECLARE @demoRunId bigint;
            DECLARE @demoEnd datetime2(3) = SYSUTCDATETIME();
            DECLARE @dt1 datetime2(3) = DATEADD(minute, -3, @demoEnd);
            DECLARE @dt2 datetime2(3) = DATEADD(minute, -2, @demoEnd);
            DECLARE @dt3 datetime2(3) = DATEADD(minute, -1, @demoEnd);
            DECLARE @s1 bigint, @s2 bigint, @s3 bigint;
            DECLARE @demoDbId int = DB_ID();
            DECLARE @demoDbName sysname = DB_NAME();

            BEGIN TRAN;  -- lint:allow FR-LINT-004 reason: atomic demo-data seed; ROLLBACK in CATCH; touches only FR_* rows

            -- Idempotent cleanup of any prior demo rows (children → snapshot → runlog).
            IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
                DELETE c FROM dbo.FR_QueryStoreTopN c
                    INNER JOIN dbo.FR_Snapshot s ON s.SnapshotId = c.SnapshotId
                    WHERE s.InstanceFingerprint = @DemoFingerprint;
            IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
                DELETE c FROM dbo.FR_Deadlock c
                    INNER JOIN dbo.FR_Snapshot s ON s.SnapshotId = c.SnapshotId
                    WHERE s.InstanceFingerprint = @DemoFingerprint;
            IF OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL
                DELETE c FROM dbo.FR_PlanCacheSummary c
                    INNER JOIN dbo.FR_Snapshot s ON s.SnapshotId = c.SnapshotId
                    WHERE s.InstanceFingerprint = @DemoFingerprint;
            -- v0.4.2 demo children (FR_R0001/2/4/5 sources) must be cleaned
            -- before FR_Snapshot, or the delete below fails the FK.
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
                DELETE c FROM dbo.FR_Request c
                    INNER JOIN dbo.FR_Snapshot s ON s.SnapshotId = c.SnapshotId
                    WHERE s.InstanceFingerprint = @DemoFingerprint;
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
                DELETE c FROM dbo.FR_FileStat c
                    INNER JOIN dbo.FR_Snapshot s ON s.SnapshotId = c.SnapshotId
                    WHERE s.InstanceFingerprint = @DemoFingerprint;

            DELETE FROM dbo.FR_Snapshot WHERE InstanceFingerprint = @DemoFingerprint;

            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
                DELETE st FROM dbo.FR_RunLogStep st
                    INNER JOIN dbo.FR_RunLog r ON r.RunId = st.RunId
                    WHERE r.Mode = N'InstallDemoData';
            DELETE FROM dbo.FR_RunLog WHERE Mode = N'InstallDemoData';

            -- Demo run-log row.
            INSERT INTO dbo.FR_RunLog
                (StartUtc, EndUtc, Mode, Status, Reason, InstanceFingerprint, LoginName, HostName)
            VALUES
                (@dt1, @demoEnd, N'InstallDemoData', N'Success', N'Synthetic demo data.',
                 @DemoFingerprint, SUSER_SNAME(), HOST_NAME());
            SET @demoRunId = SCOPE_IDENTITY();

            -- Three demo snapshots (1-minute cadence, in the default report window).
            INSERT INTO dbo.FR_Snapshot (SnapshotUtc, InstanceFingerprint, RunId)
                VALUES (@dt1, @DemoFingerprint, @demoRunId);
            SET @s1 = SCOPE_IDENTITY();
            INSERT INTO dbo.FR_Snapshot (SnapshotUtc, InstanceFingerprint, RunId)
                VALUES (@dt2, @DemoFingerprint, @demoRunId);
            SET @s2 = SCOPE_IDENTITY();
            INSERT INTO dbo.FR_Snapshot (SnapshotUtc, InstanceFingerprint, RunId)
                VALUES (@dt3, @DemoFingerprint, @demoRunId);
            SET @s3 = SCOPE_IDENTITY();

            -- Query Store demo rows → FR_R0015 (regression), FR_R0016 (top CPU),
            -- FR_R0018 (forced-plan failure).
            IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
                INSERT INTO dbo.FR_QueryStoreTopN
                (
                    SnapshotId, SnapshotUtc, DatabaseId, DatabaseName,
                    QsQueryId, QsPlanId, IsForcedPlan, ForceFailureCount, LastForceFailureReason,
                    ExecutionCount, TotalDurationUs, AvgDurationUs, TotalCpuUs, AvgCpuUs,
                    AvgLogicalReads, AvgPhysicalReads, AvgWrites, IntervalStartUtc, IntervalEndUtc
                )
                VALUES
                -- Query 1001: plan 1 baseline (s1, s2), plan 2 regressed (s3).
                (@s1, @dt1, @demoDbId, @demoDbName, 1001, 1, 0, 0, NULL, 100, 100000, 1000, 2000000, 20000, 5000, 50, 10, @dt1, @dt1),
                (@s2, @dt2, @demoDbId, @demoDbName, 1001, 1, 0, 0, NULL, 100, 100000, 1000, 2000000, 20000, 5000, 50, 10, @dt2, @dt2),
                (@s3, @dt3, @demoDbId, @demoDbName, 1001, 2, 0, 0, NULL, 100, 900000, 9000, 3000000, 30000, 9000, 90, 20, @dt3, @dt3),
                -- Query 1002: high cumulative CPU (top consumer).
                (@s3, @dt3, @demoDbId, @demoDbName, 1002, 10, 0, 0, NULL, 50, 250000, 5000, 5000000, 100000, 12000, 120, 5, @dt3, @dt3),
                -- Query 1003: forced plan with failures.
                (@s3, @dt3, @demoDbId, @demoDbName, 1003, 20, 1, 3, N'GENERAL_FAILURE', 10, 50000, 5000, 100000, 10000, 800, 8, 2, @dt3, @dt3);

            -- Deadlock demo row → FR_R0013.
            IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
                INSERT INTO dbo.FR_Deadlock
                    (SnapshotId, SnapshotUtc, GraphHash, DeadlockTimeUtc, ProcessCount, DeadlockGraph)
                VALUES
                    (@s2, @dt2, CONVERT(varbinary(32), HASHBYTES('SHA2_256', N'demo-deadlock-1')),
                     @dt2, 2, N'<deadlock>Synthetic demo deadlock graph (not a real event).</deadlock>');

            -- Plan-cache summary demo rows → FR_R0020 (compilation pressure).
            -- Raw cumulative counters rise across the window (D-007 delta math).
            IF OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL
                INSERT INTO dbo.FR_PlanCacheSummary
                (
                    SnapshotId, SnapshotUtc, CachedPlanCount, CachedPlanSizeKb,
                    AdHocSingleUsePlanCount, AdHocSingleUsePlanSizeKb,
                    CompilationsPerSec, ReCompilationsPerSec, BatchRequestsPerSec
                )
                VALUES
                    (@s1, @dt1, 20000, 512000, 12000, 96000, 1000000, 50000, 5000000),
                    (@s3, @dt3, 20500, 520000, 13000, 104000, 1060000, 53000, 5200000);

            -- v0.4.2 demo rows for the completed v0.1-family rules. Kept modest
            -- so they showcase individual findings (no restart, no storm, no
            -- gap — those would perturb the QS/plan-cache demo above and are
            -- covered by tests/fixtures/rules).
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
                INSERT INTO dbo.FR_Request
                    (SnapshotId, SnapshotUtc, SessionId, DatabaseId, BlockingSessionId,
                     OpenTransactionCount, RequestedMemoryKb, GrantedMemoryKb)
                VALUES
                    -- FR_R0001: sessions 71,72 blocked by head 70 (below the storm threshold)
                    (@s2, @dt2, 71, @demoDbId, 70, 0, NULL, NULL),
                    (@s2, @dt2, 72, @demoDbId, 70, 0, NULL, NULL),
                    (@s2, @dt2, 70, @demoDbId, 0, 1, NULL, NULL),
                    -- FR_R0002: session 80 holds an open transaction across the window (span ~2 min)
                    (@s1, @dt1, 80, @demoDbId, 0, 1, NULL, NULL),
                    (@s3, @dt3, 80, @demoDbId, 0, 1, NULL, NULL),
                    -- FR_R0005: session 90 requested a memory grant that was not granted
                    (@s3, @dt3, 90, @demoDbId, 0, 0, 500000, NULL);

            -- FR_R0004: one database file whose read+write stall per I/O rises
            -- across the window (no baseline in demo, so Confidence is Low).
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
                INSERT INTO dbo.FR_FileStat
                    (SnapshotId, SnapshotUtc, DatabaseId, FileId, NumOfReads, NumOfBytesRead,
                     IoStallReadMs, NumOfWrites, NumOfBytesWritten, IoStallWriteMs, SizeOnDiskBytes)
                VALUES
                    (@s1, @dt1, @demoDbId, 1, 1000, 8192000, 1000, 0, 0, 0, 0),
                    (@s3, @dt3, @demoDbId, 1, 1100, 9011200, 6000, 0, 0, 0, 0);

            COMMIT TRAN;

            SELECT
                  N'Success' AS Status
                , N'Synthetic demo data installed. Run @Mode = N''Report'' to see sample findings.' AS Message
                , 3 AS SnapshotsCreated
                , @DemoFingerprint AS DemoMarker
                , @ToolVersion AS ToolVersion;
            RETURN;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRAN;
            SELECT N'Error' AS Status, N'InstallDemoDataFailed' AS ErrorCode,
                ERROR_MESSAGE() AS Message, @ToolVersion AS ToolVersion;
            RETURN;
        END CATCH;
    END;

    -- =========================================================================
    -- Mode: COLLECT
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'COLLECT'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
           OR OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NULL
           OR OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'Collect requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        DECLARE @CollectLockResult int;
        DECLARE @CollectRunId bigint = NULL;
        DECLARE @CollectSnapshotId bigint = NULL;
        DECLARE @CollectSnapshotUtc datetime2(3) = SYSUTCDATETIME();
        DECLARE @CollectStepId bigint = NULL;
        DECLARE @CollectRows int = 0;
        DECLARE @CollectStatus nvarchar(20) = N'Success';
        DECLARE @CollectReason nvarchar(400) = N'Collect completed successfully.';
        DECLARE @CollectError nvarchar(max) = NULL;
        DECLARE @CollectMaxRows int = @TopN;
        DECLARE @CollectWaitIgnore nvarchar(4000) = N'';

        SELECT @CollectMaxRows = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config
        WHERE ConfigKey = N'MaxRowsPerCollector';

        IF @CollectMaxRows IS NULL OR @CollectMaxRows < 1
            SET @CollectMaxRows = @TopN;

        SELECT @CollectWaitIgnore = ISNULL(ConfigValue, N'')
        FROM dbo.FR_Config
        WHERE ConfigKey = N'WaitStatsIgnoreList';

        -- v0.3 collector gating (read once; bounded). Error log is OPT-IN (D-020).
        DECLARE @CollectQS         bit = 0;
        DECLARE @CollectErrLog     bit = 0;
        DECLARE @CollectSchemaAct  bit = 0;
        DECLARE @CollectPlanCache  bit = 0;
        DECLARE @QsMaxDb           int = 50;
        DECLARE @SchemaActMaxDb    int = 50;

        SELECT @CollectQS = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'CollectQueryStore';

        SELECT @CollectErrLog = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'CollectErrorLog';

        SELECT @CollectSchemaAct = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'CollectSchemaActivity';

        SELECT @CollectPlanCache = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'CollectPlanCacheSummary';

        SELECT @QsMaxDb = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreMaxDatabases';
        IF @QsMaxDb IS NULL OR @QsMaxDb < 1 SET @QsMaxDb = 50;

        SELECT @SchemaActMaxDb = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'SchemaActivityMaxDatabases';
        IF @SchemaActMaxDb IS NULL OR @SchemaActMaxDb < 1 SET @SchemaActMaxDb = 50;

        -- v0.4 collector gating (read once; bounded). Buffer pool is OPT-IN (D-051).
        DECLARE @CollectAdvHa      bit = 0;
        DECLARE @CollectBufferPool bit = 0;
        DECLARE @BpMaxRows         int = 100;
        DECLARE @BpMaxMemoryGB     int = 256;

        SELECT @CollectAdvHa = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'EnableAdvancedHaCollector';

        SELECT @CollectBufferPool = CASE WHEN TRY_CONVERT(int, ConfigValue) = 1 THEN 1 ELSE 0 END
        FROM dbo.FR_Config WHERE ConfigKey = N'EnableBufferPoolCollector';

        SELECT @BpMaxRows = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'BufferPoolCollectionMaxRows';
        IF @BpMaxRows IS NULL OR @BpMaxRows < 1 SET @BpMaxRows = 100;

        SELECT @BpMaxMemoryGB = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'BufferPoolMaxMemoryGB';
        IF @BpMaxMemoryGB IS NULL OR @BpMaxMemoryGB < 1 SET @BpMaxMemoryGB = 256;

        EXEC @CollectLockResult = sys.sp_getapplock
              @Resource = N'SQLFlightRecorder/Collect'
            , @LockMode = N'Exclusive'
            , @LockOwner = N'Session'
            , @LockTimeout = 1000;

        IF @CollectLockResult < 0
        BEGIN
            INSERT INTO dbo.FR_RunLog
            (
                StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName
            )
            VALUES
            (
                SYSUTCDATETIME(), SYSUTCDATETIME(), N'Collect', N'Skipped',
                N'Another Collect is already running.',
                SUSER_SNAME(), HOST_NAME()
            );

            SELECT N'Skipped' AS Status, N'Another Collect is already running.' AS Message;
            RETURN;
        END;

        BEGIN TRY
            INSERT INTO dbo.FR_RunLog
            (
                StartUtc, EndUtc, Mode, Status, Reason,
                InstanceFingerprint, CapabilitySnapshot, LoginName, HostName
            )
            VALUES
            (
                @CollectSnapshotUtc, NULL, N'Collect', N'InProgress',
                N'Collect started.',
                CONVERT(nvarchar(200), SERVERPROPERTY(N'ServerName')), @CapabilitySnapshot,
                SUSER_SNAME(), HOST_NAME()
            );

            SET @CollectRunId = SCOPE_IDENTITY();

            INSERT INTO dbo.FR_Snapshot
            (
                SnapshotUtc, InstanceFingerprint, RunId
            )
            VALUES
            (
                @CollectSnapshotUtc,
                CONVERT(nvarchar(200), SERVERPROPERTY(N'ServerName')),
                @CollectRunId
            );

            SET @CollectSnapshotId = SCOPE_IDENTITY();

            -- Instance collector
            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'InstanceSnapshot', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_InstanceSnapshot
                    (
                        SnapshotId, SnapshotUtc, ServerName, EngineEdition,
                        ProductVersion, ProductLevel, IsHadrEnabled,
                        Platform, CpuCount, PhysicalMemoryKb, SqlStartTimeUtc
                    )
                    SELECT TOP (1)
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        CONVERT(sysname, SERVERPROPERTY(N'ServerName')),
                        TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')),
                        CONVERT(nvarchar(50), SERVERPROPERTY(N'ProductVersion')),
                        CONVERT(nvarchar(20), SERVERPROPERTY(N'ProductLevel')),
                        TRY_CONVERT(bit, SERVERPROPERTY(N'IsHadrEnabled')),
                        @PlatformProbe,
                        cpu_count,
                        physical_memory_kb,
                        sqlserver_start_time
                    FROM sys.dm_os_sys_info;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Configuration collector
            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Configuration', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_Configuration
                    (
                        SnapshotId, SnapshotUtc, ConfigurationKind, Name, ValueText, IsDefault
                    )
                    SELECT
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        N'sys.configurations',
                        name,
                        CONVERT(nvarchar(400), value_in_use),
                        NULL
                    FROM sys.configurations;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Requests collector
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Requests', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_Request
                    (
                        SnapshotId, SnapshotUtc, SessionId, DatabaseId,
                        BlockingSessionId, WaitTypeAtCapture, WaitTimeMs,
                        CpuTimeMs, LogicalReads, Status, Command,
                        OpenTransactionCount, QueryHash, QueryPlanHash,
                        RequestedMemoryKb, GrantedMemoryKb, MemoryGrantTimeUtc
                    )
                    SELECT TOP (@CollectMaxRows)
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        r.session_id,
                        ISNULL(r.database_id, 0),
                        r.blocking_session_id,
                        r.wait_type,
                        r.wait_time,
                        r.cpu_time,
                        r.logical_reads,
                        r.status,
                        r.command,
                        r.open_transaction_count,
                        r.query_hash,
                        r.query_plan_hash,
                        mg.requested_memory_kb,
                        mg.granted_memory_kb,
                        mg.grant_time
                    FROM sys.dm_exec_requests AS r
                    LEFT JOIN sys.dm_exec_query_memory_grants AS mg
                        ON mg.session_id = r.session_id
                       AND mg.request_id = r.request_id
                    WHERE r.session_id <> @@SPID
                    ORDER BY r.cpu_time DESC, r.logical_reads DESC, r.session_id ASC;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Query text collector (bounded; dedup on QueryHash + SHA2_256(text), D-027)
            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'QueryText', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    ;WITH CapturedText AS
                    (
                        SELECT TOP (@CollectMaxRows)
                               r.query_hash AS QueryHash,
                               st.text      AS SqlText
                        FROM sys.dm_exec_requests AS r
                        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st  -- lint:allow FR-LINT-001 reason: bounded by sql_handle of TOP-capped active requests; one row per handle; never a cache scan (D-137). Unlike the plan DMVs (D-015/D-046), text-by-handle is sanctioned for v0.2+ per the forbidden-list note.
                        WHERE r.session_id <> @@SPID
                          AND r.query_hash IS NOT NULL
                          AND st.text IS NOT NULL
                        ORDER BY r.cpu_time DESC, r.logical_reads DESC, r.session_id ASC
                    ),
                    Deduped AS
                    (
                        SELECT DISTINCT
                               QueryHash,
                               HASHBYTES('SHA2_256', CONVERT(nvarchar(max), SqlText)) AS TextHash,
                               SqlText
                        FROM CapturedText
                    )
                    INSERT INTO dbo.FR_QueryText (QueryHash, TextHash, SqlText)
                    SELECT d.QueryHash, d.TextHash, d.SqlText
                    FROM Deduped AS d
                    WHERE NOT EXISTS (
                        SELECT 1 FROM dbo.FR_QueryText AS q
                        WHERE q.QueryHash = d.QueryHash AND q.TextHash = d.TextHash
                    );

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_QueryText
                    SET LastSeenUtc = SYSUTCDATETIME()
                    WHERE QueryHash IN (SELECT QueryHash FROM sys.dm_exec_requests WHERE session_id <> @@SPID AND query_hash IS NOT NULL);

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Wait collector
            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Waits', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_Wait
                    (
                        SnapshotId, SnapshotUtc, WaitType, WaitingTasksCount,
                        WaitTimeMs, MaxWaitTimeMs, SignalWaitTimeMs
                    )
                    SELECT TOP (@CollectMaxRows)
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        wait_type,
                        waiting_tasks_count,
                        wait_time_ms,
                        max_wait_time_ms,
                        signal_wait_time_ms
                    FROM sys.dm_os_wait_stats
                    WHERE CHARINDEX(N';' + wait_type + N';', N';' + @CollectWaitIgnore + N';') = 0
                    ORDER BY wait_time_ms DESC, wait_type ASC;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- File stats collector
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'FileStats', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_FileStat
                    (
                        SnapshotId, SnapshotUtc, DatabaseId, FileId,
                        NumOfReads, NumOfBytesRead, IoStallReadMs,
                        NumOfWrites, NumOfBytesWritten, IoStallWriteMs,
                        SizeOnDiskBytes
                    )
                    SELECT TOP (5000)
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        database_id,
                        file_id,
                        num_of_reads,
                        num_of_bytes_read,
                        io_stall_read_ms,
                        num_of_writes,
                        num_of_bytes_written,
                        io_stall_write_ms,
                        size_on_disk_bytes
                    FROM sys.dm_io_virtual_file_stats(NULL, NULL)
                    ORDER BY io_stall_read_ms + io_stall_write_ms DESC;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Perf counters collector
            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'PerfCounters', SYSUTCDATETIME(), N'InProgress');

                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    INSERT INTO dbo.FR_PerfCounter
                    (
                        SnapshotId, SnapshotUtc, ObjectName, CounterName,
                        InstanceName, CounterValue, CounterType
                    )
                    SELECT TOP (100)
                        @CollectSnapshotId,
                        @CollectSnapshotUtc,
                        object_name,
                        counter_name,
                        NULLIF(instance_name, N''),
                        cntr_value,
                        cntr_type
                    FROM sys.dm_os_performance_counters
                    WHERE counter_name IN
                    (
                        N'Batch Requests/sec',
                        N'SQL Compilations/sec',
                        N'SQL Re-Compilations/sec',
                        N'Page life expectancy',
                        N'Lazy writes/sec',
                        N'Checkpoint pages/sec',
                        N'User Connections',
                        N'Processes blocked'
                    )
                    ORDER BY object_name, counter_name, instance_name;

                    SET @CollectRows = @@ROWCOUNT;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- Query plan capture is DISABLED BY DESIGN. Locked decisions
            -- D-015 / D-046 / D-082 / D-136 forbid sys.dm_exec_query_plan and
            -- any plan-XML shredding in T-SQL, opt-in or not. Until a future
            -- decision-log-approved design exists, @IncludeQueryPlans = 1 is
            -- an honest no-op: one Skipped step (D-054) and one Informational
            -- coverage finding in Report. dbo.FR_QueryPlan remains for
            -- forward schema compatibility (D-038) and is never written.
            IF @IncludeQueryPlans = 1
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, EndUtc, Status, RowsCollected, Reason)
                VALUES (@CollectRunId, N'QueryPlans', SYSUTCDATETIME(), SYSUTCDATETIME(), N'Skipped', 0,
                        N'Plan capture disabled by design (D-015/D-046/D-082); @IncludeQueryPlans is reserved.');
            END;

            -- ============================================================
            -- v0.2 collector: Tempdb
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Tempdb', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    DECLARE @vsKb bigint, @uoKb bigint, @ioKb bigint, @unallocKb bigint, @mixedKb bigint;

                    SELECT
                        @vsKb     = SUM(CONVERT(bigint, version_store_reserved_page_count))  * 8,
                        @uoKb     = SUM(CONVERT(bigint, user_object_reserved_page_count))    * 8,
                        @ioKb     = SUM(CONVERT(bigint, internal_object_reserved_page_count))* 8,
                        @unallocKb= SUM(CONVERT(bigint, unallocated_extent_page_count))      * 8,
                        @mixedKb  = SUM(CONVERT(bigint, mixed_extent_page_count))            * 8
                    FROM tempdb.sys.dm_db_file_space_usage;

                    INSERT INTO dbo.FR_Tempdb
                    (
                        SnapshotId, SnapshotUtc, VersionStoreKb, UserObjectKb,
                        InternalObjectKb, UnallocatedExtentKb, MixedExtentKb,
                        DataFileCount, MinDataFileSizeKb, MaxDataFileSizeKb
                    )
                    SELECT
                        @CollectSnapshotId, @CollectSnapshotUtc, @vsKb, @uoKb,
                        @ioKb, @unallocKb, @mixedKb,
                        COUNT(1),
                        MIN(CONVERT(bigint, size) * 8),
                        MAX(CONVERT(bigint, size) * 8)
                    FROM tempdb.sys.database_files
                    WHERE type_desc = N'ROWS';

                    SET @CollectRows = @@ROWCOUNT;
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.2 collector: Memory
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Memory', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    DECLARE @totKb bigint, @tgtKb bigint, @stolenKb bigint,
                            @grPending bigint, @grOutstanding bigint, @ple bigint;

                    SELECT @totKb    = MAX(CASE WHEN counter_name LIKE N'Total Server Memory (KB)%' THEN cntr_value END),
                           @tgtKb    = MAX(CASE WHEN counter_name LIKE N'Target Server Memory (KB)%' THEN cntr_value END),
                           @stolenKb = MAX(CASE WHEN counter_name LIKE N'Stolen Server Memory (KB)%' THEN cntr_value END),
                           @grPending= MAX(CASE WHEN counter_name LIKE N'Memory Grants Pending%' THEN cntr_value END),
                           @grOutstanding = MAX(CASE WHEN counter_name LIKE N'Memory Grants Outstanding%' THEN cntr_value END),
                           @ple      = MAX(CASE WHEN counter_name LIKE N'Page life expectancy%' THEN cntr_value END)
                    FROM sys.dm_os_performance_counters
                    WHERE counter_name LIKE N'Total Server Memory (KB)%'
                       OR counter_name LIKE N'Target Server Memory (KB)%'
                       OR counter_name LIKE N'Stolen Server Memory (KB)%'
                       OR counter_name LIKE N'Memory Grants Pending%'
                       OR counter_name LIKE N'Memory Grants Outstanding%'
                       OR counter_name LIKE N'Page life expectancy%';

                    INSERT INTO dbo.FR_Memory
                    (
                        SnapshotId, SnapshotUtc, TotalServerMemoryKb, TargetServerMemoryKb,
                        StolenServerMemoryKb, MemoryGrantsPending, MemoryGrantsOutstanding, PageLifeExpectancy
                    )
                    VALUES
                    (
                        @CollectSnapshotId, @CollectSnapshotUtc, @totKb, @tgtKb,
                        @stolenKb, @grPending, @grOutstanding, @ple
                    );

                    SET @CollectRows = @@ROWCOUNT;
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.2 collector: SQL Agent jobs/history (delta read, D-050)
            -- Capability-gated: requires msdb + Agent history.
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'AgentJobs', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF @HasAgent = 0
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped',
                            Reason = N'msdb/Agent history unavailable on this edition (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @AgentHighWater int = 0;
                        SELECT @AgentHighWater = TRY_CONVERT(int, ConfigValue)
                        FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobHighWaterInstanceId';
                        SET @AgentHighWater = ISNULL(@AgentHighWater, 0);

                        DECLARE @AgentSqlCollect nvarchar(max) = N'
                        INSERT INTO dbo.FR_AgentJob
                        (
                            SnapshotId, SnapshotUtc, MsdbInstanceId, JobName, StepId, StepName,
                            RunStatus, RunOutcome, RunStartUtc, RunDurationSec, MessageText
                        )
                        SELECT TOP (@maxRows)
                            @sid, @sutc, h.instance_id, j.name, h.step_id, h.step_name,
                            h.run_status,
                            CASE h.run_status WHEN 0 THEN N''Failed'' WHEN 1 THEN N''Succeeded''
                                 WHEN 2 THEN N''Retry'' WHEN 3 THEN N''Canceled'' ELSE N''InProgress'' END,
                            msdb.dbo.agent_datetime(h.run_date, h.run_time),
                            (h.run_duration/10000)*3600 + ((h.run_duration%10000)/100)*60 + (h.run_duration%100),
                            LEFT(h.message, 400)
                        FROM msdb.dbo.sysjobhistory AS h
                        INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
                        WHERE h.instance_id > @hw
                        ORDER BY h.instance_id ASC;';

                        EXEC sys.sp_executesql @AgentSqlCollect,
                             N'@sid bigint, @sutc datetime2(3), @maxRows int, @hw int',
                             @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc,
                             @maxRows = @CollectMaxRows, @hw = @AgentHighWater;

                        SET @CollectRows = @@ROWCOUNT;

                        -- Advance high-water mark to the max instance_id we just stored.
                        DECLARE @newHW int;
                        SELECT @newHW = MAX(MsdbInstanceId) FROM dbo.FR_AgentJob WHERE SnapshotId = @CollectSnapshotId;
                        IF @newHW IS NOT NULL AND @newHW > @AgentHighWater
                            UPDATE dbo.FR_Config
                            SET ConfigValue = CONVERT(nvarchar(20), @newHW), ModifiedUtc = SYSUTCDATETIME()
                            WHERE ConfigKey = N'AgentJobHighWaterInstanceId';

                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.2 collector: Backup history (delta read, D-050)
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'BackupHistory', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF @HasMsdb = 0
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped',
                            Reason = N'msdb unavailable on this edition (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @BackupHighWater int = 0;
                        SELECT @BackupHighWater = TRY_CONVERT(int, ConfigValue)
                        FROM dbo.FR_Config WHERE ConfigKey = N'BackupHighWaterBackupSetId';
                        SET @BackupHighWater = ISNULL(@BackupHighWater, 0);

                        DECLARE @BackupSqlCollect nvarchar(max) = N'
                        INSERT INTO dbo.FR_BackupHistory
                        (
                            SnapshotId, SnapshotUtc, MsdbBackupSetId, DatabaseName, BackupType,
                            BackupStartUtc, BackupFinishUtc, BackupSizeBytes, IsCopyOnly
                        )
                        SELECT TOP (@maxRows)
                            @sid, @sutc, bs.backup_set_id, bs.database_name,
                            CASE bs.type WHEN N''D'' THEN N''Full'' WHEN N''I'' THEN N''Differential''
                                 WHEN N''L'' THEN N''Log'' WHEN N''F'' THEN N''FileOrFilegroup''
                                 WHEN N''G'' THEN N''DiffFile'' WHEN N''P'' THEN N''Partial''
                                 WHEN N''Q'' THEN N''DiffPartial'' ELSE bs.type END,
                            bs.backup_start_date, bs.backup_finish_date, bs.backup_size, bs.is_copy_only
                        FROM msdb.dbo.backupset AS bs
                        WHERE bs.backup_set_id > @hw
                        ORDER BY bs.backup_set_id ASC;';

                        EXEC sys.sp_executesql @BackupSqlCollect,
                             N'@sid bigint, @sutc datetime2(3), @maxRows int, @hw int',
                             @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc,
                             @maxRows = @CollectMaxRows, @hw = @BackupHighWater;

                        SET @CollectRows = @@ROWCOUNT;

                        DECLARE @newBHW int;
                        SELECT @newBHW = MAX(MsdbBackupSetId) FROM dbo.FR_BackupHistory WHERE SnapshotId = @CollectSnapshotId;
                        IF @newBHW IS NOT NULL AND @newBHW > @BackupHighWater
                            UPDATE dbo.FR_Config
                            SET ConfigValue = CONVERT(nvarchar(20), @newBHW), ModifiedUtc = SYSUTCDATETIME()
                            WHERE ConfigKey = N'BackupHighWaterBackupSetId';

                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.2 collector: Always On state
            -- Capability-gated on IsHadrEnabled.
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'AlwaysOnState', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF ISNULL(@IsHadrEnabledProbe, 0) = 0
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped',
                            Reason = N'Always On not enabled (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @AoSql nvarchar(max) = N'
                        INSERT INTO dbo.FR_AlwaysOnState
                        (
                            SnapshotId, SnapshotUtc, AgName, ReplicaServer, Role,
                            OperationalState, ConnectedState, SynchronizationHealth,
                            DatabaseName, SynchronizationState
                        )
                        SELECT TOP (@maxRows)
                            @sid, @sutc, ag.name, ar.replica_server_name,
                            ars.role_desc, ars.operational_state_desc, ars.connected_state_desc,
                            ars.synchronization_health_desc, DB_NAME(drs.database_id), drs.synchronization_state_desc
                        FROM sys.availability_groups AS ag
                        INNER JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
                        INNER JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
                        LEFT JOIN sys.dm_hadr_database_replica_states AS drs ON drs.replica_id = ar.replica_id
                        ORDER BY ag.name, ar.replica_server_name;';

                        EXEC sys.sp_executesql @AoSql,
                             N'@sid bigint, @sutc datetime2(3), @maxRows int',
                             @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc, @maxRows = @CollectMaxRows;

                        SET @CollectRows = @@ROWCOUNT;
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.2 collector: Deadlocks (system_health XE; dedup by graph hash, D-053)
            -- ============================================================
            IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'Deadlocks', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF @IsAzureSqlDb = 1
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped',
                            Reason = N'system_health ring buffer not available on Azure SQL DB (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN

                        ;WITH xe AS
                        (
                            SELECT CONVERT(xml, t.target_data) AS TargetData
                            FROM sys.dm_xe_session_targets AS t
                            INNER JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
                            WHERE s.name = N'system_health'
                              AND t.target_name = N'ring_buffer'
                        ),
                        graphs AS
                        (
                            SELECT TOP (@CollectMaxRows)
                                   n.value('(@timestamp)[1]', 'datetime2(3)') AS DeadlockTimeUtc,
                                   n.query('(data[@name="xml_report"]/value/deadlock)[1]') AS GraphXml
                            FROM xe
                            CROSS APPLY xe.TargetData.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS q(n)
                            ORDER BY n.value('(@timestamp)[1]', 'datetime2(3)') DESC
                        )
                        INSERT INTO dbo.FR_Deadlock
                        (
                            SnapshotId, SnapshotUtc, GraphHash, DeadlockTimeUtc, ProcessCount, DeadlockGraph
                        )
                        SELECT
                            @CollectSnapshotId, @CollectSnapshotUtc,
                            HASHBYTES('SHA2_256', CONVERT(nvarchar(max), g.GraphXml)),
                            g.DeadlockTimeUtc,
                            g.GraphXml.value('count(//process)', 'int'),
                            CONVERT(nvarchar(max), g.GraphXml)
                        FROM graphs AS g
                        WHERE NOT EXISTS (
                            SELECT 1 FROM dbo.FR_Deadlock AS d
                            WHERE d.GraphHash = HASHBYTES('SHA2_256', CONVERT(nvarchar(max), g.GraphXml))
                        );

                        SET @CollectRows = @@ROWCOUNT;
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.3 collector: Plan cache summary (bounded; D-055; NO plan XML)
            -- Aggregates plan-cache METADATA only. Does not call
            -- sys.dm_exec_query_plan and never shreds plans (D-046 preserved).
            -- ============================================================
            IF @CollectPlanCache = 1 AND OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'PlanCacheSummary', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    DECLARE @pcCount bigint, @pcSizeKb bigint, @pcAdHoc bigint, @pcAdHocKb bigint;
                    DECLARE @compRaw bigint, @recompRaw bigint, @batchRaw bigint;

                    SELECT
                        @pcCount   = COUNT_BIG(*),
                        @pcSizeKb  = SUM(CONVERT(bigint, size_in_bytes)) / 1024,
                        @pcAdHoc   = SUM(CASE WHEN objtype = N'Adhoc' AND usecounts = 1 THEN 1 ELSE 0 END),
                        @pcAdHocKb = SUM(CASE WHEN objtype = N'Adhoc' AND usecounts = 1
                                              THEN CONVERT(bigint, size_in_bytes) ELSE 0 END) / 1024
                    FROM sys.dm_exec_cached_plans;

                    -- Raw cumulative counters (D-007). Despite the *PerSec column
                    -- names, these store the raw counter; report derives the rate.
                    SELECT
                        @compRaw   = MAX(CASE WHEN counter_name LIKE N'SQL Compilations/sec%'    THEN cntr_value END),
                        @recompRaw = MAX(CASE WHEN counter_name LIKE N'SQL Re-Compilations/sec%' THEN cntr_value END),
                        @batchRaw  = MAX(CASE WHEN counter_name LIKE N'Batch Requests/sec%'       THEN cntr_value END)
                    FROM sys.dm_os_performance_counters
                    WHERE counter_name LIKE N'SQL Compilations/sec%'
                       OR counter_name LIKE N'SQL Re-Compilations/sec%'
                       OR counter_name LIKE N'Batch Requests/sec%';

                    INSERT INTO dbo.FR_PlanCacheSummary
                    (
                        SnapshotId, SnapshotUtc, CachedPlanCount, CachedPlanSizeKb,
                        AdHocSingleUsePlanCount, AdHocSingleUsePlanSizeKb,
                        CompilationsPerSec, ReCompilationsPerSec, BatchRequestsPerSec
                    )
                    VALUES
                    (
                        @CollectSnapshotId, @CollectSnapshotUtc, @pcCount, @pcSizeKb,
                        @pcAdHoc, @pcAdHocKb, @compRaw, @recompRaw, @batchRaw
                    );

                    SET @CollectRows = @@ROWCOUNT;
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                    WHERE RunStepId = @CollectStepId;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.3 collector: Error log (OPT-IN, off by default; D-020/D-060)
            -- Bounded: current log only, high-water + row cap. Skips on Azure SQL DB.
            -- Permission failure is caught and marked partial (never fails Collect).
            -- ============================================================
            IF @CollectErrLog = 1 AND OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'ErrorLog', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF @IsAzureSqlDb = 1
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped',
                            Reason = N'Error log not available on Azure SQL DB (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @ErrHighWater datetime2(3) = NULL;
                        SELECT @ErrHighWater = TRY_CONVERT(datetime2(3), ConfigValue)
                        FROM dbo.FR_Config WHERE ConfigKey = N'ErrorLogHighWaterUtc';
                        SET @ErrHighWater = ISNULL(@ErrHighWater, CONVERT(datetime2(3), '1900-01-01'));

                        DECLARE @ErrRaw TABLE (LogDate datetime, ProcessInfo nvarchar(64), LogText nvarchar(4000));

                        -- Read CURRENT error log only (file 0). If permission is
                        -- denied, the CATCH marks this step partial (D-060).
                        INSERT INTO @ErrRaw (LogDate, ProcessInfo, LogText)
                        EXEC sys.sp_readerrorlog 0;

                        INSERT INTO dbo.FR_ErrorLog
                        (
                            SnapshotId, SnapshotUtc, LogDateUtc, ProcessInfo, Category, LogText, TextHash
                        )
                        SELECT TOP (@CollectMaxRows)
                            @CollectSnapshotId, @CollectSnapshotUtc,
                            e.LogDate, e.ProcessInfo,
                            CASE
                                WHEN e.LogText LIKE N'%SQL Server is starting%'
                                  OR e.LogText LIKE N'%SQL Server is now ready for client connections%'
                                  OR e.LogText LIKE N'%Recovery is complete%'        THEN N'Restart'
                                WHEN e.LogText LIKE N'%Login failed%'                  THEN N'LoginFailure'
                                WHEN e.LogText LIKE N'%Error: 823%'
                                  OR e.LogText LIKE N'%Error: 824%'
                                  OR e.LogText LIKE N'%Error: 825%'                    THEN N'IO'
                                WHEN e.LogText LIKE N'%consistency errors%'
                                  OR e.LogText LIKE N'%found % errors and repaired%'
                                  OR e.LogText LIKE N'%marked suspect%'                THEN N'Corruption'
                                WHEN e.LogText LIKE N'%availability%group%'
                                  OR e.LogText LIKE N'%failover%'                      THEN N'Failover'
                                WHEN e.LogText LIKE N'%Failed Virtual Allocate%'
                                  OR e.LogText LIKE N'%memory%pressure%'               THEN N'Memory'
                                WHEN e.LogText LIKE N'%Severity: 1[789]%'
                                  OR e.LogText LIKE N'%Severity: 2[0-5]%'              THEN N'HighSeverity'
                                ELSE N'Other'
                            END,
                            LEFT(e.LogText, 2000),
                            HASHBYTES('SHA2_256', CONVERT(nvarchar(4000), e.LogText))
                        FROM @ErrRaw AS e
                        WHERE e.LogDate > @ErrHighWater
                        ORDER BY e.LogDate ASC;

                        SET @CollectRows = @@ROWCOUNT;

                        DECLARE @NewErrHW datetime2(3);
                        SELECT @NewErrHW = MAX(LogDateUtc)
                        FROM dbo.FR_ErrorLog WHERE SnapshotId = @CollectSnapshotId;

                        IF @NewErrHW IS NOT NULL AND @NewErrHW > @ErrHighWater
                            UPDATE dbo.FR_Config
                            SET ConfigValue = CONVERT(nvarchar(40), @NewErrHW, 126), ModifiedUtc = SYSUTCDATETIME()
                            WHERE ConfigKey = N'ErrorLogHighWaterUtc';

                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.3 collector: Query Store top-N (bounded; D-044/D-045/D-052/D-059)
            -- Latest closed interval per DB; first @QsMaxDb user DBs by id;
            -- TOP (@CollectMaxRows) per DB by CPU. Runtime stats only (no plan XML).
            -- All QS catalog access is dynamic SQL (D-112) so the file compiles
            -- on engines without Query Store (pre-2016).
            -- ============================================================
            IF @CollectQS = 1
               AND @HasQueryStoreSupport = 1
               AND OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'QueryStore', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    DECLARE @qsSql        nvarchar(max);
                    DECLARE @qsDbId       int = 0;
                    DECLARE @qsDbName     sysname;
                    DECLARE @qsStartMs    datetime2(3) = SYSUTCDATETIME();
                    DECLARE @qsBudgetMs   int = 15000;   -- ~50% of 30s run cap (D-045; tentative)
                    DECLARE @qsBudgetHit  bit = 0;
                    DECLARE @qsDbErrors   int = 0;
                    DECLARE @qsDbDone     int = 0;

                    IF OBJECT_ID(N'tempdb..#fr_qs_db') IS NOT NULL DROP TABLE #fr_qs_db;
                    CREATE TABLE #fr_qs_db (DatabaseId int NOT NULL PRIMARY KEY, DatabaseName sysname NOT NULL);

                    -- Candidate DBs: online, writable, user DBs with QS ON.
                    -- is_query_store_on is a 2016+ column → must be dynamic (D-112).
                    SET @qsSql = N'
SELECT TOP (@maxDb) database_id, name
FROM sys.databases
WHERE state_desc = N''ONLINE''
  AND database_id > 4
  AND is_read_only = 0
  AND is_query_store_on = 1
ORDER BY database_id ASC;';
                    INSERT INTO #fr_qs_db (DatabaseId, DatabaseName)
                    EXEC sys.sp_executesql @qsSql, N'@maxDb int', @maxDb = @QsMaxDb;

                    IF NOT EXISTS (SELECT 1 FROM #fr_qs_db)
                    BEGIN
                        -- No QS-enabled user DBs: Skipped (feeds FR_R0017 in Report).
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped', RowsCollected = 0,
                            Reason = N'Query Store not enabled on any eligible user database.'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        WHILE 1 = 1
                        BEGIN
                            SELECT TOP (1) @qsDbId = DatabaseId, @qsDbName = DatabaseName
                            FROM #fr_qs_db
                            WHERE DatabaseId > @qsDbId
                            ORDER BY DatabaseId ASC;

                            IF @@ROWCOUNT = 0 BREAK;

                            -- Cooperative budget guard (D-045/D-059): persist what we
                            -- have and stop scanning further databases.
                            IF DATEDIFF(millisecond, @qsStartMs, SYSUTCDATETIME()) > @qsBudgetMs
                            BEGIN
                                SET @qsBudgetHit = 1;
                                BREAK;
                            END;

                            BEGIN TRY
                                SET @qsSql = N'
INSERT INTO dbo.FR_QueryStoreTopN
(
    SnapshotId, SnapshotUtc, DatabaseId, DatabaseName,
    QsQueryId, QsPlanId, IsForcedPlan, ForceFailureCount, LastForceFailureReason,
    ExecutionCount, TotalDurationUs, AvgDurationUs, TotalCpuUs, AvgCpuUs,
    AvgLogicalReads, AvgPhysicalReads, AvgWrites, IntervalStartUtc, IntervalEndUtc
)
SELECT TOP (@maxRows)
    @sid, @sutc, @dbid, @dbname,
    p.query_id, p.plan_id, p.is_forced_plan, p.force_failure_count, p.last_force_failure_reason_desc,
    SUM(rs.count_executions),
    CONVERT(bigint, SUM(rs.avg_duration * rs.count_executions)),
    CONVERT(bigint, CASE WHEN SUM(rs.count_executions) > 0
                         THEN SUM(rs.avg_duration * rs.count_executions) / SUM(rs.count_executions) ELSE 0 END),
    CONVERT(bigint, SUM(rs.avg_cpu_time * rs.count_executions)),
    CONVERT(bigint, CASE WHEN SUM(rs.count_executions) > 0
                         THEN SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) ELSE 0 END),
    CONVERT(bigint, MAX(rs.avg_logical_io_reads)),
    CONVERT(bigint, MAX(rs.avg_physical_io_reads)),
    CONVERT(bigint, MAX(rs.avg_logical_io_writes)),
    CONVERT(datetime2(3), SWITCHOFFSET(lci.start_time, 0)),
    CONVERT(datetime2(3), SWITCHOFFSET(lci.end_time, 0))
FROM ' + QUOTENAME(@qsDbName) + N'.sys.query_store_runtime_stats AS rs
INNER JOIN (
    SELECT TOP (1) runtime_stats_interval_id, start_time, end_time
    FROM ' + QUOTENAME(@qsDbName) + N'.sys.query_store_runtime_stats_interval
    WHERE end_time <= SYSDATETIMEOFFSET()
    ORDER BY end_time DESC
) AS lci ON lci.runtime_stats_interval_id = rs.runtime_stats_interval_id
INNER JOIN ' + QUOTENAME(@qsDbName) + N'.sys.query_store_plan AS p ON p.plan_id = rs.plan_id
GROUP BY p.query_id, p.plan_id, p.is_forced_plan, p.force_failure_count,
         p.last_force_failure_reason_desc, lci.start_time, lci.end_time
ORDER BY SUM(rs.avg_cpu_time * rs.count_executions) DESC;';

                                EXEC sys.sp_executesql @qsSql,
                                     N'@sid bigint, @sutc datetime2(3), @maxRows int, @dbid int, @dbname sysname',
                                     @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc,
                                     @maxRows = @CollectMaxRows, @dbid = @qsDbId, @dbname = @qsDbName;

                                SET @qsDbDone = @qsDbDone + 1;
                            END TRY
                            BEGIN CATCH
                                -- One DB failing (e.g., readable secondary, QS read error)
                                -- must not stop the whole collector (D-009/D-150).
                                SET @qsDbErrors = @qsDbErrors + 1;
                            END CATCH;
                        END;

                        SELECT @CollectRows = COUNT(1)
                        FROM dbo.FR_QueryStoreTopN
                        WHERE SnapshotId = @CollectSnapshotId;

                        IF @qsBudgetHit = 1 OR @qsDbErrors > 0
                        BEGIN
                            SET @CollectStatus = N'PartialSuccess';
                            UPDATE dbo.FR_RunLogStep
                            SET EndUtc = SYSUTCDATETIME(), Status = N'PartialSuccess', RowsCollected = @CollectRows,
                                Reason = CONCAT(N'QS partial: dbsDone=', @qsDbDone,
                                                N'; dbErrors=', @qsDbErrors,
                                                N'; budgetHit=', @qsBudgetHit, N' (D-045/D-059).')
                            WHERE RunStepId = @CollectStepId;
                        END
                        ELSE
                        BEGIN
                            UPDATE dbo.FR_RunLogStep
                            SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows,
                                Reason = CONCAT(N'QS top-N captured for ', @qsDbDone, N' database(s).')
                            WHERE RunStepId = @CollectStepId;
                        END;
                    END;

                    IF OBJECT_ID(N'tempdb..#fr_qs_db') IS NOT NULL DROP TABLE #fr_qs_db;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                    IF OBJECT_ID(N'tempdb..#fr_qs_db') IS NOT NULL DROP TABLE #fr_qs_db;
                END CATCH;
            END;

            -- ============================================================
            -- v0.3 collector: Schema/stats activity (METADATA only; D-052/D-137)
            -- Recent object DDL + stats modification metadata per DB.
            -- Never scans user-table DATA. First @SchemaActMaxDb user DBs by id;
            -- TOP (@CollectMaxRows) rows per DB. Cross-DB access is dynamic SQL.
            -- ============================================================
            IF @CollectSchemaAct = 1 AND OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'SchemaActivity', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();

                BEGIN TRY
                    DECLARE @saSql       nvarchar(max);
                    DECLARE @saDbId      int = 0;
                    DECLARE @saDbName    sysname;
                    DECLARE @saStartMs   datetime2(3) = SYSUTCDATETIME();
                    DECLARE @saBudgetMs  int = 10000;   -- bounded; cheaper than QS
                    DECLARE @saBudgetHit bit = 0;
                    DECLARE @saDbErrors  int = 0;
                    DECLARE @saDbDone    int = 0;
                    DECLARE @saLookbackUtc datetime2(3) = DATEADD(day, -7, @CollectSnapshotUtc);

                    IF OBJECT_ID(N'tempdb..#fr_sa_db') IS NOT NULL DROP TABLE #fr_sa_db;
                    CREATE TABLE #fr_sa_db (DatabaseId int NOT NULL PRIMARY KEY, DatabaseName sysname NOT NULL);

                    -- Candidate DBs: online, writable, user DBs (D-052).
                    INSERT INTO #fr_sa_db (DatabaseId, DatabaseName)
                    SELECT TOP (@SchemaActMaxDb) database_id, name
                    FROM sys.databases
                    WHERE state_desc = N'ONLINE'
                      AND database_id > 4
                      AND is_read_only = 0
                      AND DATABASEPROPERTYEX(name, N'Updateability') = N'READ_WRITE'
                    ORDER BY database_id ASC;

                    IF NOT EXISTS (SELECT 1 FROM #fr_sa_db)
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped', RowsCollected = 0,
                            Reason = N'No eligible online read-write user database.'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        WHILE 1 = 1
                        BEGIN
                            SELECT TOP (1) @saDbId = DatabaseId, @saDbName = DatabaseName
                            FROM #fr_sa_db
                            WHERE DatabaseId > @saDbId
                            ORDER BY DatabaseId ASC;

                            IF @@ROWCOUNT = 0 BREAK;

                            IF DATEDIFF(millisecond, @saStartMs, SYSUTCDATETIME()) > @saBudgetMs
                            BEGIN
                                SET @saBudgetHit = 1;
                                BREAK;
                            END;

                            BEGIN TRY
                                -- Two metadata sources, UNION ALL, bounded TOP by recency:
                                --   ObjectChange : sys.objects.modify_date (recent DDL)
                                --   StatsUpdate  : sys.stats + dm_db_stats_properties.last_updated
                                -- dm_db_stats_properties takes object_id/stats_id only
                                -- (metadata), not a data scan.
                                SET @saSql = N'
INSERT INTO dbo.FR_SchemaActivity
(
    SnapshotId, SnapshotUtc, DatabaseId, DatabaseName,
    ActivityKind, SchemaName, ObjectName, StatName, ModifyDateUtc, RowModCount
)
SELECT TOP (@maxRows) *
FROM (
    SELECT
        @sid, @sutc, @dbid, @dbname,
        N''ObjectChange'',
        s.name, o.name, CAST(NULL AS sysname),
        o.modify_date, CAST(NULL AS bigint)
    FROM ' + QUOTENAME(@saDbName) + N'.sys.objects AS o
    INNER JOIN ' + QUOTENAME(@saDbName) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.modify_date >= @lookback

    UNION ALL

    SELECT
        @sid, @sutc, @dbid, @dbname,
        N''StatsUpdate'',
        s2.name, o2.name, st.name,
        sp.last_updated, sp.modification_counter
    FROM ' + QUOTENAME(@saDbName) + N'.sys.stats AS st
    INNER JOIN ' + QUOTENAME(@saDbName) + N'.sys.objects AS o2 ON o2.object_id = st.object_id
    INNER JOIN ' + QUOTENAME(@saDbName) + N'.sys.schemas AS s2 ON s2.schema_id = o2.schema_id
    CROSS APPLY ' + QUOTENAME(@saDbName) + N'.sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
    WHERE o2.is_ms_shipped = 0
      AND sp.last_updated >= @lookback
) AS act (SnapshotId, SnapshotUtc, DatabaseId, DatabaseName,
          ActivityKind, SchemaName, ObjectName, StatName, ModifyDateUtc, RowModCount)
ORDER BY act.ModifyDateUtc DESC;';

                                EXEC sys.sp_executesql @saSql,
                                     N'@sid bigint, @sutc datetime2(3), @maxRows int, @dbid int, @dbname sysname, @lookback datetime2(3)',
                                     @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc,
                                     @maxRows = @CollectMaxRows, @dbid = @saDbId, @dbname = @saDbName,
                                     @lookback = @saLookbackUtc;

                                SET @saDbDone = @saDbDone + 1;
                            END TRY
                            BEGIN CATCH
                                SET @saDbErrors = @saDbErrors + 1;
                            END CATCH;
                        END;

                        SELECT @CollectRows = COUNT(1)
                        FROM dbo.FR_SchemaActivity
                        WHERE SnapshotId = @CollectSnapshotId;

                        IF @saBudgetHit = 1 OR @saDbErrors > 0
                        BEGIN
                            SET @CollectStatus = N'PartialSuccess';
                            UPDATE dbo.FR_RunLogStep
                            SET EndUtc = SYSUTCDATETIME(), Status = N'PartialSuccess', RowsCollected = @CollectRows,
                                Reason = CONCAT(N'SchemaActivity partial: dbsDone=', @saDbDone,
                                                N'; dbErrors=', @saDbErrors,
                                                N'; budgetHit=', @saBudgetHit, N'.')
                            WHERE RunStepId = @CollectStepId;
                        END
                        ELSE
                        BEGIN
                            UPDATE dbo.FR_RunLogStep
                            SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows,
                                Reason = CONCAT(N'Schema/stats metadata captured for ', @saDbDone, N' database(s).')
                            WHERE RunStepId = @CollectStepId;
                        END;
                    END;

                    IF OBJECT_ID(N'tempdb..#fr_sa_db') IS NOT NULL DROP TABLE #fr_sa_db;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                    IF OBJECT_ID(N'tempdb..#fr_sa_db') IS NOT NULL DROP TABLE #fr_sa_db;
                END CATCH;
            END;
            -- ============================================================
            -- v0.3 collector: Query Store capacity probe (bounded; feeds FR_R0019)
            -- Per-DB dynamic read of sys.database_query_store_options (2016+).
            -- NO new table: max used percent is stored in FR_RunLogStep.RowsCollected
            -- (documented reuse), offending DB(s) in Reason. FR_R0019 reads this step.
            -- ============================================================
            IF @CollectQS = 1 AND @HasQueryStoreSupport = 1
               AND OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'QueryStoreCapacity', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    DECLARE @capSql    nvarchar(max);
                    DECLARE @capDbId   int = 0;
                    DECLARE @capDbName sysname;
                    DECLARE @capCur    float;
                    DECLARE @capMax    float;
                    DECLARE @capPct    int;
                    DECLARE @capMaxPct int = 0;
                    DECLARE @capDetail nvarchar(400) = N'';

                    IF OBJECT_ID(N'tempdb..#fr_qscap_db') IS NOT NULL DROP TABLE #fr_qscap_db;
                    CREATE TABLE #fr_qscap_db (DatabaseId int NOT NULL PRIMARY KEY, DatabaseName sysname NOT NULL);

                    SET @capSql = N'
SELECT TOP (@maxDb) database_id, name
FROM sys.databases
WHERE state_desc = N''ONLINE'' AND database_id > 4 AND is_read_only = 0
  AND is_query_store_on = 1
ORDER BY database_id ASC;';
                    INSERT INTO #fr_qscap_db (DatabaseId, DatabaseName)
                    EXEC sys.sp_executesql @capSql, N'@maxDb int', @maxDb = @QsMaxDb;

                    WHILE 1 = 1
                    BEGIN
                        SELECT TOP (1) @capDbId = DatabaseId, @capDbName = DatabaseName
                        FROM #fr_qscap_db WHERE DatabaseId > @capDbId ORDER BY DatabaseId ASC;
                        IF @@ROWCOUNT = 0 BREAK;

                        SET @capCur = NULL; SET @capMax = NULL;
                        BEGIN TRY
                            SET @capSql = N'SELECT @cur = CONVERT(float, current_storage_size_mb),
                                                   @max = CONVERT(float, max_storage_size_mb)
                                            FROM ' + QUOTENAME(@capDbName) + N'.sys.database_query_store_options
                                            WHERE actual_state IN (1, 2);';
                            EXEC sys.sp_executesql @capSql,
                                 N'@cur float OUTPUT, @max float OUTPUT',
                                 @cur = @capCur OUTPUT, @max = @capMax OUTPUT;

                            IF @capMax IS NOT NULL AND @capMax > 0 AND @capCur IS NOT NULL
                            BEGIN
                                SET @capPct = CONVERT(int, (@capCur * 100.0) / @capMax);
                                IF @capPct > @capMaxPct SET @capMaxPct = @capPct;
                                IF @capPct >= 80
                                    SET @capDetail = LEFT(@capDetail
                                        + CASE WHEN @capDetail = N'' THEN N'' ELSE N'; ' END
                                        + N'db=[' + @capDbName + N'] usedPct=' + CONVERT(nvarchar(10), @capPct), 400);
                            END;
                        END TRY
                        BEGIN CATCH
                            SET @capCur = NULL;   -- ignore a single DB capacity read failure
                        END CATCH;
                    END;

                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(),
                        Status = N'Success',
                        RowsCollected = @capMaxPct,
                        Reason = CASE WHEN @capDetail = N'' THEN N'No QS database at/over 80% used.' ELSE @capDetail END
                    WHERE RunStepId = @CollectStepId;

                    IF OBJECT_ID(N'tempdb..#fr_qscap_db') IS NOT NULL DROP TABLE #fr_qscap_db;
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                    IF OBJECT_ID(N'tempdb..#fr_qscap_db') IS NOT NULL DROP TABLE #fr_qscap_db;
                END CATCH;
            END;

            -- ============================================================
            -- v0.4 collector: Advanced HA / Availability Group context (D-056)
            -- Bounded; capability-gated on HADR + config (EnableAdvancedHaCollector).
            -- Adds queue + rate + lag signals beyond v0.2 FR_AlwaysOnState.
            -- All HADR DMV access is dynamic SQL (D-112) so the file compiles
            -- on engines/editions without Always On.
            -- ============================================================
            IF @CollectAdvHa = 1
               AND @HasAdvancedHaSupport = 1
               AND OBJECT_ID(N'dbo.FR_HaState', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'AdvancedHaState', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF ISNULL(@IsHadrEnabledProbe, 0) = 0
                    BEGIN
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped', RowsCollected = 0,
                            Reason = N'Always On not enabled (capability-gated).'
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @HaSql nvarchar(max) = N'
INSERT INTO dbo.FR_HaState
(
    SnapshotId, SnapshotUtc, AgName, ReplicaServer, DatabaseName,
    IsLocalReplica, IsPrimaryReplica, RoleDesc, OperationalStateDesc,
    ConnectedStateDesc, SynchronizationStateDesc, SynchronizationHealthDesc,
    AvailabilityModeDesc, FailoverModeDesc,
    LogSendQueueKb, LogSendRateKbPerSec, RedoQueueKb, RedoRateKbPerSec,
    LastCommitUtc, SecondaryLagSeconds
)
SELECT TOP (@maxRows)
    @sid, @sutc,
    ag.name, ar.replica_server_name, DB_NAME(drs.database_id),
    ars.is_local, ISNULL(ars.is_primary_replica, 0),
    ars.role_desc, ars.operational_state_desc,
    ars.connected_state_desc, drs.synchronization_state_desc, drs.synchronization_health_desc,
    ar.availability_mode_desc, ar.failover_mode_desc,
    drs.log_send_queue_size, drs.log_send_rate,
    drs.redo_queue_size, drs.redo_rate,
    drs.last_commit_time,
    CASE WHEN drs.last_commit_time IS NOT NULL
         THEN DATEDIFF(second, drs.last_commit_time, SYSUTCDATETIME()) END
FROM sys.availability_groups AS ag
INNER JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
INNER JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs ON drs.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name, drs.database_id;';

                        EXEC sys.sp_executesql @HaSql,
                             N'@sid bigint, @sutc datetime2(3), @maxRows int',
                             @sid = @CollectSnapshotId, @sutc = @CollectSnapshotUtc, @maxRows = @CollectMaxRows;

                        SET @CollectRows = @@ROWCOUNT;
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows,
                            Reason = CONCAT(N'Advanced HA context captured for ', @CollectRows, N' replica/database row(s).')
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    -- One HADR read failing (e.g., readable-secondary restriction) must not
                    -- fail the whole Collect (D-009/D-150).
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            -- ============================================================
            -- v0.4 collector: Buffer pool composition (OPT-IN; D-051/D-142)
            -- dm_os_buffer_descriptors AGGREGATED per database_id only.
            -- NO per-page rows. NO user-table access. Skipped when target server
            -- memory exceeds BufferPoolMaxMemoryGB (D-051) or unsupported.
            -- ============================================================
            IF @CollectBufferPool = 1
               AND @HasBufferPoolSupport = 1
               AND OBJECT_ID(N'dbo.FR_BufferPool', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLogStep (RunId, StepName, StartUtc, Status)
                VALUES (@CollectRunId, N'BufferPool', SYSUTCDATETIME(), N'InProgress');
                SET @CollectStepId = SCOPE_IDENTITY();
                BEGIN TRY
                    IF @TargetServerMemoryMb IS NOT NULL
                       AND @TargetServerMemoryMb > (CONVERT(bigint, @BpMaxMemoryGB) * 1024)
                    BEGIN
                        -- D-051: skip on large-memory instances until empirically validated.
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Skipped', RowsCollected = 0,
                            Reason = CONCAT(N'Skipped: target server memory ',
                                            CONVERT(nvarchar(20), @TargetServerMemoryMb),
                                            N' MB exceeds BufferPoolMaxMemoryGB=', CONVERT(nvarchar(10), @BpMaxMemoryGB),
                                            N' (D-051).')
                        WHERE RunStepId = @CollectStepId;
                    END
                    ELSE
                    BEGIN
                        DECLARE @BpTotalKb bigint = NULL;

                        SELECT @BpTotalKb = CONVERT(bigint, COUNT_BIG(*)) * 8
                        FROM sys.dm_os_buffer_descriptors
                        WHERE database_id <> 32767;   -- exclude Resource DB

                        ;WITH bp AS
                        (
                            SELECT
                                bd.database_id,
                                COUNT_BIG(*) AS CachedPageCount,
                                SUM(CASE WHEN bd.is_modified = 1 THEN 1 ELSE 0 END) AS ModifiedPageCount,
                                SUM(CASE WHEN bd.free_space_in_bytes >= 8000 THEN 1 ELSE 0 END) AS FreePageCount
                            FROM sys.dm_os_buffer_descriptors AS bd
                            WHERE bd.database_id <> 32767
                            GROUP BY bd.database_id
                        )
                        INSERT INTO dbo.FR_BufferPool
                        (
                            SnapshotId, SnapshotUtc, DatabaseId, DatabaseName,
                            CachedPageCount, CachedSizeKb, FreePageCount, ModifiedPageCount,
                            TotalBufferPoolKb, PercentOfPool
                        )
                        SELECT TOP (@BpMaxRows)
                            @CollectSnapshotId, @CollectSnapshotUtc,
                            bp.database_id,
                            CASE WHEN bp.database_id = 32767 THEN N'Resource' ELSE DB_NAME(bp.database_id) END,
                            bp.CachedPageCount,
                            bp.CachedPageCount * 8,
                            bp.FreePageCount,
                            bp.ModifiedPageCount,
                            @BpTotalKb,
                            CASE WHEN @BpTotalKb > 0
                                 THEN CONVERT(decimal(5,2), (bp.CachedPageCount * 8 * 100.0) / @BpTotalKb)
                                 ELSE NULL END
                        FROM bp
                        ORDER BY bp.CachedPageCount DESC;

                        SET @CollectRows = @@ROWCOUNT;
                        UPDATE dbo.FR_RunLogStep
                        SET EndUtc = SYSUTCDATETIME(), Status = N'Success', RowsCollected = @CollectRows,
                            Reason = CONCAT(N'Buffer pool summary captured for ', @CollectRows, N' database(s).')
                        WHERE RunStepId = @CollectStepId;
                    END
                END TRY
                BEGIN CATCH
                    SET @CollectStatus = N'PartialSuccess';
                    SET @CollectError = ERROR_MESSAGE();
                    UPDATE dbo.FR_RunLogStep
                    SET EndUtc = SYSUTCDATETIME(), Status = N'Error', ErrorMessage = @CollectError
                    WHERE RunStepId = @CollectStepId;
                END CATCH;
            END;

            IF @CollectStatus = N'PartialSuccess'
                SET @CollectReason = N'Collect completed with one or more collector failures. See FR_RunLogStep.';
            UPDATE dbo.FR_RunLog
            SET EndUtc = SYSUTCDATETIME(),
                Status = @CollectStatus,
                Reason = @CollectReason
            WHERE RunId = @CollectRunId;

            EXEC sys.sp_releaseapplock
                  @Resource = N'SQLFlightRecorder/Collect'
                , @LockOwner = N'Session';

            SELECT
                  @CollectStatus AS Status
                , @CollectRunId AS RunId
                , @CollectSnapshotId AS SnapshotId
                , @CollectSnapshotUtc AS SnapshotUtc
                , @CollectReason AS Message;

            RETURN;
        END TRY
        BEGIN CATCH
            SET @CollectError = ERROR_MESSAGE();

            IF @CollectRunId IS NOT NULL
            BEGIN
                UPDATE dbo.FR_RunLog
                SET EndUtc = SYSUTCDATETIME(),
                    Status = N'Error',
                    ErrorMessage = @CollectError,
                    Reason = N'Collect failed.'
                WHERE RunId = @CollectRunId;
            END;

            EXEC sys.sp_releaseapplock
                  @Resource = N'SQLFlightRecorder/Collect'
                , @LockOwner = N'Session';

            SELECT N'Error' AS Status, N'CollectFailed' AS ErrorCode,
                @CollectError AS Message, @ToolVersion AS ToolVersion;

            RETURN;
        END CATCH;
    END;
    -- =========================================================================
    -- Mode: PURGE
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'PURGE'
    BEGIN
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'NotInstalled' AS ErrorCode,
                N'Purge requires Install to be run first.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        DECLARE @PurgeLockResult int;
        DECLARE @PurgeRunId bigint = NULL;

        -- Concurrency control: Purge takes the same session applock as Collect (D-011).
        -- Only acquired for a real run; @WhatIf is read-only and remains lock-free.
        IF @WhatIf = 0
        BEGIN
            EXEC @PurgeLockResult = sys.sp_getapplock
                  @Resource = N'SQLFlightRecorder/Collect'
                , @LockMode = N'Exclusive'
                , @LockOwner = N'Session'
                , @LockTimeout = 1000;

            IF @PurgeLockResult < 0
            BEGIN
                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                    INSERT INTO dbo.FR_RunLog
                    (StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName)
                    VALUES
                    (SYSUTCDATETIME(), SYSUTCDATETIME(), N'Purge', N'Skipped',
                     N'Collect or Purge already running; applock not granted.',
                     SUSER_SNAME(), HOST_NAME());

                SELECT N'Skipped' AS Status, N'Collect or Purge already running.' AS Message;
                RETURN;
            END;

            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
            BEGIN
                INSERT INTO dbo.FR_RunLog
                (StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName)
                VALUES
                (SYSUTCDATETIME(), NULL, N'Purge', N'InProgress', N'Purge started.',
                 SUSER_SNAME(), HOST_NAME());
                SET @PurgeRunId = SCOPE_IDENTITY();
            END;
        END;

        DECLARE @PurgeSnapshotRetentionDays int = 7;
        DECLARE @PurgeRunLogRetentionDays int = 28;
        DECLARE @PurgeSnapshotCutoffUtc datetime2(3);
        DECLARE @PurgeRunLogCutoffUtc datetime2(3);
        DECLARE @PurgeRows int = 0;
        DECLARE @PurgeTotalRows int = 0;
        DECLARE @PurgeStatus nvarchar(20) = N'Success';
        DECLARE @PurgeErrors nvarchar(2000) = N'';

        SELECT @PurgeSnapshotRetentionDays = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config
        WHERE ConfigKey = N'SnapshotRetentionDays';

        IF @PurgeSnapshotRetentionDays IS NULL OR @PurgeSnapshotRetentionDays < 1
            SET @PurgeSnapshotRetentionDays = 7;

        SELECT @PurgeRunLogRetentionDays = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config
        WHERE ConfigKey = N'RunLogRetentionDays';

        IF @PurgeRunLogRetentionDays IS NULL OR @PurgeRunLogRetentionDays < @PurgeSnapshotRetentionDays
            SET @PurgeRunLogRetentionDays = @PurgeSnapshotRetentionDays * 4;

        SET @PurgeSnapshotCutoffUtc = DATEADD(day, -@PurgeSnapshotRetentionDays, SYSUTCDATETIME());
        SET @PurgeRunLogCutoffUtc = DATEADD(day, -@PurgeRunLogRetentionDays, SYSUTCDATETIME());

        IF @WhatIf = 1
        BEGIN
            SELECT N'WhatIf' AS Status, @PurgeSnapshotCutoffUtc AS SnapshotCutoffUtc, @PurgeRunLogCutoffUtc AS RunLogCutoffUtc;

            SELECT N'FR_Snapshot' AS TableName, COUNT(1) AS RowsEligible
            FROM dbo.FR_Snapshot
            WHERE OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL
              AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_Tempdb', COUNT(1) FROM dbo.FR_Tempdb
            WHERE OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_Memory', COUNT(1) FROM dbo.FR_Memory
            WHERE OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_AgentJob', COUNT(1) FROM dbo.FR_AgentJob
            WHERE OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_BackupHistory', COUNT(1) FROM dbo.FR_BackupHistory
            WHERE OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_AlwaysOnState', COUNT(1) FROM dbo.FR_AlwaysOnState
            WHERE OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_Deadlock', COUNT(1) FROM dbo.FR_Deadlock
            WHERE OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_QueryPlan', COUNT(1) FROM dbo.FR_QueryPlan
            WHERE OBJECT_ID(N'dbo.FR_QueryPlan', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_QueryStoreTopN', COUNT(1) FROM dbo.FR_QueryStoreTopN
            WHERE OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_ErrorLog', COUNT(1) FROM dbo.FR_ErrorLog
            WHERE OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_SchemaActivity', COUNT(1) FROM dbo.FR_SchemaActivity
            WHERE OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_PlanCacheSummary', COUNT(1) FROM dbo.FR_PlanCacheSummary
            WHERE OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_HaState', COUNT(1) FROM dbo.FR_HaState
            WHERE OBJECT_ID(N'dbo.FR_HaState', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_BufferPool', COUNT(1) FROM dbo.FR_BufferPool
            WHERE OBJECT_ID(N'dbo.FR_BufferPool', N'U') IS NOT NULL AND SnapshotUtc < @PurgeSnapshotCutoffUtc
            UNION ALL
            SELECT N'FR_RunLog', COUNT(1)
            FROM dbo.FR_RunLog
            WHERE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
              AND StartUtc < @PurgeRunLogCutoffUtc;

            RETURN;
        END;

        -- Children of FR_Snapshot first, strictly before the parent (D-141).
        -- Each table's batched loop is TRY/CATCH-wrapped (D-139): batches are
        -- autocommit, so a failing batch loses nothing already removed; the
        -- error lands in @PurgeErrors, the run closes as PartialSuccess, and
        -- the applock release at the end of this mode is always reached.
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_InstanceSnapshot WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_InstanceSnapshot] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Configuration WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Configuration] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Request WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Request] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Wait WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Wait] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_FileStat WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_FileStat] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_PerfCounter WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_PerfCounter] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Tempdb WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Tempdb] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Memory WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Memory] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_AgentJob WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_AgentJob] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_BackupHistory WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_BackupHistory] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_AlwaysOnState WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_AlwaysOnState] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Deadlock WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Deadlock] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_QueryPlan', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_QueryPlan WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_QueryPlan] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- FR_QueryStoreTopN previously had no purge loop at all (unbounded
        -- growth + FK failure on the FR_Snapshot delete). Fixed in v0.4.1.
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_QueryStoreTopN WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_QueryStoreTopN] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- v0.4 child tables (snapshot children; purge before FR_Snapshot, D-141).
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_HaState', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_HaState WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_HaState] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_BufferPool', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_BufferPool WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_BufferPool] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_ErrorLog WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_ErrorLog] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_SchemaActivity WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_SchemaActivity] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_PlanCacheSummary WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_PlanCacheSummary] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- Parent spine: only after every child table above (D-141).
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) FROM dbo.FR_Snapshot WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_Snapshot] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- FR_QueryText orphan cleanup (D-141): rows whose QueryHash is no
        -- longer referenced by any remaining FR_Request or FR_QueryPlan row.
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000) qt
                FROM dbo.FR_QueryText AS qt
                WHERE NOT EXISTS (SELECT 1 FROM dbo.FR_Request  AS r WHERE r.QueryHash = qt.QueryHash)
                  AND NOT EXISTS (SELECT 1 FROM dbo.FR_QueryPlan AS p WHERE p.QueryHash = qt.QueryHash);
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_QueryText] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- Run log last (D-141). FR_RunLogStep first (FK to FR_RunLog); the
        -- FR_RunLog delete additionally refuses rows still referenced by a
        -- surviving FR_Snapshot (defense in depth for non-default retention).
        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000)
                FROM dbo.FR_RunLogStep
                WHERE RunId IN
                (
                    SELECT RunId FROM dbo.FR_RunLog WHERE StartUtc < @PurgeRunLogCutoffUtc
                );

                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_RunLogStep] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        BEGIN TRY
            WHILE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
            BEGIN
                DELETE TOP (5000)
                FROM dbo.FR_RunLog
                WHERE StartUtc < @PurgeRunLogCutoffUtc
                  AND NOT EXISTS (SELECT 1 FROM dbo.FR_Snapshot AS s WHERE s.RunId = dbo.FR_RunLog.RunId);
                SET @PurgeRows = @@ROWCOUNT;
                SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
                IF @PurgeRows = 0 BREAK;
                WAITFOR DELAY '00:00:00.250';
            END;
        END TRY
        BEGIN CATCH
            SET @PurgeStatus = N'PartialSuccess';
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[FR_RunLog] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        -- Close the run-log row, then release the applock. The close is
        -- swallowed on error so the release below is always reached; the
        -- applock can no longer leak on a failed purge.
        BEGIN TRY
            IF @PurgeRunId IS NOT NULL
                UPDATE dbo.FR_RunLog
                SET EndUtc = SYSUTCDATETIME(),
                    Status = @PurgeStatus,
                    Reason = LEFT(CONCAT(N'Purge deleted ', @PurgeTotalRows, N' rows.',
                                         CASE WHEN @PurgeErrors = N'' THEN N''
                                              ELSE CONCAT(N' Errors: ', @PurgeErrors) END), 400)
                WHERE RunId = @PurgeRunId;
        END TRY
        BEGIN CATCH
            SET @PurgeErrors = LEFT(CONCAT(@PurgeErrors, N'[RunLogClose] ', ERROR_MESSAGE(), N' '), 2000);
        END CATCH;

        IF @WhatIf = 0
            EXEC sys.sp_releaseapplock
                  @Resource = N'SQLFlightRecorder/Collect'
                , @LockOwner = N'Session';

        SELECT
              @PurgeStatus AS Status
            , @PurgeTotalRows AS RowsDeleted
            , @PurgeSnapshotCutoffUtc AS SnapshotCutoffUtc
            , @PurgeRunLogCutoffUtc AS RunLogCutoffUtc
            , NULLIF(@PurgeErrors, N'') AS Errors;

        RETURN;
    END;

    -- =========================================================================
    -- Mode: REPORT
    -- =========================================================================
   IF UPPER(@ModeNormalized) = N'REPORT'
    BEGIN
        -- @DatabaseName scope validation (safe metadata lookup; no dynamic SQL).
        IF @DatabaseName IS NOT NULL AND DB_ID(@DatabaseName) IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'InvalidDatabaseName' AS ErrorCode,
                CONCAT(N'@DatabaseName does not exist on this instance: ''', @DatabaseName, N'''.') AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
        BEGIN
            SELECT
                  1 AS FindingOrdinal
                , N'Critical' AS Severity
                , N'High' AS Confidence
                , N'Observed' AS EvidenceType
                , N'Coverage' AS Category
                , N'FR_R0026_CoverageAndCapabilitySummary' AS RuleId
                , N'Repository is not installed' AS Title
                , N'Run Install before Report.' AS Summary
                , N'FR_Snapshot table was not found.' AS Evidence
                , N'Run EXEC dbo.sp_SQLFlightRecorder @Mode = N''Install''.' AS Recommendation
                , NULL AS DatabaseName
                , NULL AS ObjectName
                , NULL AS SessionId
                , SYSUTCDATETIME() AS StartTimeUtc
                , SYSUTCDATETIME() AS EndTimeUtc
                , N'Install required.' AS MoreInfo;

            SELECT
                  CAST(NULL AS datetime2(3)) AS EventUtc
                , CAST(NULL AS nvarchar(60)) AS EventType
                , CAST(NULL AS nvarchar(60)) AS Category
                , CAST(NULL AS nvarchar(20)) AS Severity
                , CAST(NULL AS nvarchar(400)) AS Summary
                , CAST(NULL AS sysname) AS DatabaseName
                , CAST(NULL AS nvarchar(200)) AS ObjectName
                , CAST(NULL AS int) AS SessionId
                , CAST(NULL AS nvarchar(60)) AS RuleId
                , CAST(NULL AS bigint) AS RunId
                , CAST(NULL AS bigint) AS SnapshotId
                , CAST(NULL AS nvarchar(1000)) AS MoreInfo
            WHERE 1 = 0;

            RETURN;
        END;

        DECLARE @ReportStartUtc datetime2(3);
        DECLARE @ReportEndUtc datetime2(3);
        DECLARE @ReportSnapshotCount int;

        SET @ReportEndUtc =
            CASE
                WHEN @EndTime IS NULL THEN SYSUTCDATETIME()
                ELSE DATEADD(minute, DATEDIFF(minute, GETDATE(), SYSUTCDATETIME()), @EndTime)
            END;

        SET @ReportStartUtc =
            CASE
                WHEN @StartTime IS NULL THEN DATEADD(hour, -1, @ReportEndUtc)
                ELSE DATEADD(minute, DATEDIFF(minute, GETDATE(), SYSUTCDATETIME()), @StartTime)
            END;

        -- Delta-anchor for cumulative-DMV rules (D-007). Defaults to the window
        -- start; the restart detection below advances it to the first
        -- post-restart snapshot so delta rules never span a counter reset.
        DECLARE @DeltaStartUtc datetime2(3) = @ReportStartUtc;

        -- Restart detection + window split (D-064, §6.2). A change in the
        -- captured SQL Server start time within the window means the cumulative
        -- DMVs reset; deltas across that boundary are meaningless. Detect it
        -- here, advance @DeltaStartUtc to the first post-restart snapshot, and
        -- remember it so FR_R0006 can be emitted later (where DisabledRules is
        -- in scope). The split always applies, even if the FR_R0006 finding is
        -- disabled, because it is delta-correctness, not a recommendation.
        DECLARE @RestartDetected bit = 0;
        DECLARE @RestartUtc datetime2(3) = NULL;
        IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL
        BEGIN
            -- Child SnapshotUtc always equals the parent FR_Snapshot value (both
            -- written from one @CollectSnapshotUtc), so the extra child-side
            -- range predicate is a clustered-index access path, not a filter
            -- change. Applied through Report per D-199 (window-first reads).
            DECLARE @DistinctStarts int = 0;
            SELECT @DistinctStarts = COUNT(DISTINCT i.SqlStartTimeUtc),
                   @RestartUtc = MAX(i.SqlStartTimeUtc)
            FROM dbo.FR_InstanceSnapshot AS i
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = i.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND i.SnapshotUtc >= @ReportStartUtc AND i.SnapshotUtc <= @ReportEndUtc
              AND i.SqlStartTimeUtc IS NOT NULL;

            IF @DistinctStarts > 1 OR (@RestartUtc IS NOT NULL AND @RestartUtc > @ReportStartUtc)
                SET @RestartDetected = 1;

            IF @RestartDetected = 1 AND @RestartUtc IS NOT NULL
            BEGIN
                DECLARE @PostRestartFirstUtc datetime2(3) = NULL;
                SELECT @PostRestartFirstUtc = MIN(s.SnapshotUtc)
                FROM dbo.FR_InstanceSnapshot AS i
                INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = i.SnapshotId
                WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
                  AND i.SnapshotUtc >= @ReportStartUtc AND i.SnapshotUtc <= @ReportEndUtc
                  AND i.SqlStartTimeUtc = @RestartUtc;
                IF @PostRestartFirstUtc IS NOT NULL
                    SET @DeltaStartUtc = @PostRestartFirstUtc;
            END;
        END;

        -- v0.4 display-time resolution (D-180). Storage + sort stay UTC.
        DECLARE @TzMode  nvarchar(10) = N'UTC';
        DECLARE @TzName  sysname = NULL;
        SELECT @TzMode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(ConfigValue)), N''), N'UTC'))
        FROM dbo.FR_Config WHERE ConfigKey = N'TimeZoneMode';
        SELECT @TzName = NULLIF(LTRIM(RTRIM(ConfigValue)), N'')
        FROM dbo.FR_Config WHERE ConfigKey = N'TimeZoneName';

        -- Parameter overrides config for this run (explicit beats stored).
        IF @TimeZone IS NOT NULL
        BEGIN
            SET @TzMode = N'LOCAL';
            SET @TzName = @TimeZone;
        END;

        -- AT TIME ZONE requires SQL 2016+/Azure; otherwise force UTC display (no error).
        IF @TzMode = N'LOCAL' AND @HasTimeZoneSupport = 0
            SET @TzMode = N'UTC';

        -- =====================================================================
        -- v0.4 baseline engine (D-092, D-103): materialize ONCE per report run.
        -- 24h (configurable) median/avg of prior snapshots, EXCLUDING the incident
        -- window. SampleCount drives Confidence downgrade (<5 => Low). Repository
        -- reads only (D-081); set-based; no cursor (D-138).
        -- =====================================================================
        DECLARE @BaselineLookbackHours int = 24;
        SELECT @BaselineLookbackHours = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'BaselineLookbackHours';
        IF @BaselineLookbackHours IS NULL OR @BaselineLookbackHours < 1 OR @BaselineLookbackHours > 168
            SET @BaselineLookbackHours = 24;

        DECLARE @BaselineStartUtc datetime2(3) = DATEADD(hour, -@BaselineLookbackHours, @ReportStartUtc);

        IF OBJECT_ID(N'tempdb..#fr_baseline') IS NOT NULL DROP TABLE #fr_baseline;
        CREATE TABLE #fr_baseline
        (
            MetricKey    nvarchar(200) NOT NULL,   -- e.g. 'Wait:PAGEIOLATCH_SH', 'FileIo:5:1', 'Perf:Batch Requests/sec', 'Memory:PLE'
            MetricGroup  nvarchar(40)  NOT NULL,    -- Wait | FileIo | Perf | Memory | Tempdb
            SampleCount  int           NOT NULL,
            BaselineAvg  decimal(38,3) NULL,
            BaselineMax  decimal(38,3) NULL,
            PRIMARY KEY (MetricKey)
        );

        BEGIN TRY
            -- Wait deltas are computed at report time (D-007); for a bounded baseline
            -- we use per-snapshot cumulative values averaged across the lookback. This
            -- is an approximation by design (documented; "above recent baseline").
            -- Child-side SnapshotUtc predicates mirror the parent join filter
            -- exactly (same stored value) and exist for the clustered-index
            -- access path (D-199 window-first reads).
            INSERT INTO #fr_baseline (MetricKey, MetricGroup, SampleCount, BaselineAvg, BaselineMax)
            SELECT
                CONCAT(N'Wait:', w.WaitType), N'Wait',
                COUNT(1),
                AVG(CONVERT(decimal(38,3), w.WaitTimeMs)),
                MAX(CONVERT(decimal(38,3), w.WaitTimeMs))
            FROM dbo.FR_Wait AS w
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = w.SnapshotId
            WHERE s.SnapshotUtc >= @BaselineStartUtc
              AND s.SnapshotUtc <  @ReportStartUtc            -- exclude incident window (D-092)
              AND w.SnapshotUtc >= @BaselineStartUtc
              AND w.SnapshotUtc <  @ReportStartUtc
            GROUP BY w.WaitType;

            INSERT INTO #fr_baseline (MetricKey, MetricGroup, SampleCount, BaselineAvg, BaselineMax)
            SELECT
                CONCAT(N'FileIo:', f.DatabaseId, N':', f.FileId), N'FileIo',
                COUNT(1),
                AVG(CONVERT(decimal(38,3),
                    CASE WHEN (f.NumOfReads + f.NumOfWrites) > 0
                         THEN (f.IoStallReadMs + f.IoStallWriteMs) * 1.0 / (f.NumOfReads + f.NumOfWrites)
                         ELSE 0 END)),
                MAX(CONVERT(decimal(38,3),
                    CASE WHEN (f.NumOfReads + f.NumOfWrites) > 0
                         THEN (f.IoStallReadMs + f.IoStallWriteMs) * 1.0 / (f.NumOfReads + f.NumOfWrites)
                         ELSE 0 END))
            FROM dbo.FR_FileStat AS f
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = f.SnapshotId
            WHERE s.SnapshotUtc >= @BaselineStartUtc
              AND s.SnapshotUtc <  @ReportStartUtc
              AND f.SnapshotUtc >= @BaselineStartUtc
              AND f.SnapshotUtc <  @ReportStartUtc
            GROUP BY f.DatabaseId, f.FileId;

            INSERT INTO #fr_baseline (MetricKey, MetricGroup, SampleCount, BaselineAvg, BaselineMax)
            SELECT
                CONCAT(N'Perf:', RTRIM(p.CounterName)), N'Perf',
                COUNT(1),
                AVG(CONVERT(decimal(38,3), p.CounterValue)),
                MAX(CONVERT(decimal(38,3), p.CounterValue))
            FROM dbo.FR_PerfCounter AS p
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = p.SnapshotId
            WHERE s.SnapshotUtc >= @BaselineStartUtc
              AND s.SnapshotUtc <  @ReportStartUtc
              AND p.SnapshotUtc >= @BaselineStartUtc
              AND p.SnapshotUtc <  @ReportStartUtc
            GROUP BY RTRIM(p.CounterName);

            IF OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL
            INSERT INTO #fr_baseline (MetricKey, MetricGroup, SampleCount, BaselineAvg, BaselineMax)
            SELECT N'Memory:PLE', N'Memory',
                COUNT(1),
                AVG(CONVERT(decimal(38,3), m.PageLifeExpectancy)),
                MAX(CONVERT(decimal(38,3), m.PageLifeExpectancy))
            FROM dbo.FR_Memory AS m
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = m.SnapshotId
            WHERE s.SnapshotUtc >= @BaselineStartUtc
              AND s.SnapshotUtc <  @ReportStartUtc
              AND m.SnapshotUtc >= @BaselineStartUtc
              AND m.SnapshotUtc <  @ReportStartUtc;
        END TRY
        BEGIN CATCH
            -- A baseline build failure must not fail Report; rules treat a missing
            -- row as "insufficient history" and downgrade to Low / skip escalation.
            IF OBJECT_ID(N'tempdb..#fr_baseline') IS NOT NULL DELETE FROM #fr_baseline;
        END CATCH;
        CREATE TABLE #fr_findings
        (
              FindingOrdinal int IDENTITY(1,1) NOT NULL
            , Severity nvarchar(20) NOT NULL
            , Confidence nvarchar(20) NOT NULL
            , EvidenceType nvarchar(20) NOT NULL
            , Category nvarchar(60) NOT NULL
            , RuleId nvarchar(60) NOT NULL
            , Title nvarchar(200) NOT NULL
            , Summary nvarchar(400) NOT NULL
            , Evidence nvarchar(1900) NULL
            , Recommendation nvarchar(400) NULL
            , DatabaseName sysname NULL
            , ObjectName nvarchar(200) NULL
            , SessionId int NULL
            , StartTimeUtc datetime2(3) NULL
            , EndTimeUtc datetime2(3) NULL
            , MoreInfo nvarchar(1000) NULL
            -- Internal only (D-074): carries query identity for query-scoped
            -- rules so dedup separates distinct queries. NOT part of the
            -- 16-column output contract (D-067); never selected in output.
            , AnchorKey nvarchar(300) NULL
        );

        CREATE TABLE #fr_timeline
        (
              EventUtc datetime2(3) NOT NULL
            , EventType nvarchar(60) NOT NULL
            , Category nvarchar(60) NOT NULL
            , Severity nvarchar(20) NULL
            , Summary nvarchar(400) NOT NULL
            , DatabaseName sysname NULL
            , ObjectName nvarchar(200) NULL
            , SessionId int NULL
            , RuleId nvarchar(60) NULL
            , RunId bigint NULL
            , SnapshotId bigint NULL
            , MoreInfo nvarchar(1000) NULL
        );

        SELECT @ReportSnapshotCount = COUNT(1)
        FROM dbo.FR_Snapshot
        WHERE SnapshotUtc >= @ReportStartUtc
          AND SnapshotUtc <= @ReportEndUtc;

        IF @ReportSnapshotCount < 2
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            VALUES
            (
                N'Critical',
                N'High',
                N'Observed',
                N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'Insufficient snapshot coverage',
                N'Report requires at least two snapshots in the selected window.',
                CONCAT(N'Snapshot count in window: ', @ReportSnapshotCount),
                N'Run Collect at least twice, separated by the configured collection interval.',
                @ReportStartUtc,
                @ReportEndUtc,
                N'Coverage finding emitted because fewer than two snapshots are available.'
            );
        END;
        ELSE
        BEGIN
            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary,
                RunId, SnapshotId, MoreInfo
            )
            SELECT
                SnapshotUtc,
                N'SnapshotCaptured',
                N'Collection',
                N'Informational',
                N'Snapshot captured.',
                RunId,
                SnapshotId,
                N'FR_Snapshot row exists in selected report window.'
            FROM dbo.FR_Snapshot
            WHERE SnapshotUtc >= @ReportStartUtc
              AND SnapshotUtc <= @ReportEndUtc
            ORDER BY SnapshotUtc;

            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL
            BEGIN
                -- Delta anchor at @DeltaStartUtc (D-064): post-restart when a
                -- restart split the window, else the window start.
                ;WITH FirstSnapshot AS
                (
                    SELECT TOP (1) SnapshotId
                    FROM dbo.FR_Snapshot
                    WHERE SnapshotUtc >= @DeltaStartUtc
                      AND SnapshotUtc <= @ReportEndUtc
                    ORDER BY SnapshotUtc ASC, SnapshotId ASC
                ),
                LastSnapshot AS
                (
                    SELECT TOP (1) SnapshotId
                    FROM dbo.FR_Snapshot
                    WHERE SnapshotUtc >= @ReportStartUtc
                      AND SnapshotUtc <= @ReportEndUtc
                    ORDER BY SnapshotUtc DESC, SnapshotId DESC
                ),
                WaitDelta AS
                (
                    SELECT TOP (1)
                          lw.WaitType
                        , lw.WaitTimeMs - ISNULL(fw.WaitTimeMs, 0) AS DeltaWaitMs
                    FROM dbo.FR_Wait AS lw
                    INNER JOIN LastSnapshot AS ls
                        ON ls.SnapshotId = lw.SnapshotId
                    CROSS JOIN FirstSnapshot AS fs
                    LEFT JOIN dbo.FR_Wait AS fw
                        ON fw.SnapshotId = fs.SnapshotId
                       AND fw.WaitType = lw.WaitType
                    WHERE lw.WaitTimeMs - ISNULL(fw.WaitTimeMs, 0) > 0
                    ORDER BY lw.WaitTimeMs - ISNULL(fw.WaitTimeMs, 0) DESC, lw.WaitType ASC
                )
                INSERT INTO #fr_findings
                (
                    Severity, Confidence, EvidenceType, Category, RuleId,
                    Title, Summary, Evidence, Recommendation,
                    StartTimeUtc, EndTimeUtc, MoreInfo
                )
                SELECT
                    -- §7.9: Medium, escalates High. Escalation is by wait class,
                    -- not row count (so D-069 is preserved): a spike in a
                    -- hard-coded critical wait type (D-093) is High; any other
                    -- wait spike is Medium. This uses the hard-coded list, not
                    -- the CriticalWaitTypes config key (honored from v1.1, D-105).
                    CASE WHEN WaitType LIKE N'PAGEIOLATCH[_]%'
                              OR WaitType = N'WRITELOG'
                              OR WaitType = N'RESOURCE_SEMAPHORE'
                              OR WaitType LIKE N'LCK[_]M[_]%'
                              OR WaitType = N'THREADPOOL'
                              OR WaitType = N'SOS_SCHEDULER_YIELD'
                         THEN N'High' ELSE N'Medium' END,
                    N'Medium',
                    N'Inferred',
                    N'Waits',
                    N'FR_R0003_TopWaitTypeSpike',
                    N'Top wait type increased during the window',
                    CONCAT(N'Wait type ', WaitType, N' had the largest observed wait-time delta.'),
                    LEFT(CONCAT(N'WaitType=', WaitType, N'; DeltaWaitMs=', DeltaWaitMs,
                                N'; Class=',
                                CASE WHEN WaitType LIKE N'PAGEIOLATCH[_]%'
                                          OR WaitType = N'WRITELOG'
                                          OR WaitType = N'RESOURCE_SEMAPHORE'
                                          OR WaitType LIKE N'LCK[_]M[_]%'
                                          OR WaitType = N'THREADPOOL'
                                          OR WaitType = N'SOS_SCHEDULER_YIELD'
                                     THEN N'Critical (escalated High)' ELSE N'Non-critical (Medium)' END), 1900),
                    N'Consider correlating this wait type with workload, blocking, IO, memory, and application changes before taking action.',
                    @ReportStartUtc,
                    @ReportEndUtc,
                    N'Computed from cumulative FR_Wait snapshots. Severity escalates to High for critical wait types (D-093).'
                FROM WaitDelta;
            END;
        END;

        -- Query plan analysis is DISABLED BY DESIGN (D-015/D-046/D-082/D-136):
        -- plan XML is never parsed or shredded in T-SQL. When the caller asks
        -- for plans, say so honestly with exactly one Informational coverage
        -- finding instead of silence. Rules FR_R0030-FR_R0034 are retained in
        -- the FR_Rules catalog as Disabled (D-089/D-090) and have no logic.
        IF @IncludeQueryPlans = 1
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            VALUES
            (
                N'Informational', N'High', N'Observed', N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'Query plan analysis is not available in this build',
                N'@IncludeQueryPlans = 1 was requested, but plan capture and plan-XML analysis are disabled by design.',
                N'Locked design decisions D-015, D-046, D-082, and D-136 forbid reading sys.dm_exec_query_plan and shredding plan XML in T-SQL.',
                N'For plan-level evidence, consider reviewing the query in Query Store, which retains plans without this tool parsing them.',
                @ReportStartUtc, @ReportEndUtc,
                N'Rules FR_R0030-FR_R0034 are cataloged as Disabled until a decision-log-approved plan analysis design exists.'
            );
        END;

        -- =====================================================================
        -- v0.2 rule evaluation (FR_R0007–FR_R0014). Bounded to the report window.
        -- Each rule is gated by table existence and honors DisabledRules (D-099).
        -- =====================================================================
        DECLARE @DisabledRules nvarchar(4000) = N'';
        SELECT @DisabledRules = ISNULL(ConfigValue, N'')
        FROM dbo.FR_Config WHERE ConfigKey = N'DisabledRules';
        SET @DisabledRules = N';' + @DisabledRules + N';';

        -- =====================================================================
        -- v0.1 rule evaluation (FR_R0001, FR_R0002; FR_R0004, FR_R0005 follow in
        -- their own sections). Repository-only reads (D-014/D-081); honors
        -- DisabledRules (D-099). FR_R0003 (wait spike) is emitted earlier in the
        -- >=2-snapshot block; FR_R0006 (restart) is handled in its own section.
        -- =====================================================================

        -- FR_R0001 ActiveBlockingChain (Blocking / High / High / Observed — §7.9)
        -- Head-of-chain = a session that blocks others but is not itself blocked
        -- in the same snapshot (D-074 session anchor). Point-in-time; full window.
        IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0001_ActiveBlockingChain;', @DisabledRules) = 0
        BEGIN
            ;WITH Blocked AS
            (
                SELECT r.SnapshotId, r.SnapshotUtc, r.SessionId, r.BlockingSessionId
                FROM dbo.FR_Request AS r
                WHERE r.SnapshotUtc >= @ReportStartUtc AND r.SnapshotUtc <= @ReportEndUtc
                  AND r.BlockingSessionId IS NOT NULL
                  AND r.BlockingSessionId <> 0
                  AND r.BlockingSessionId <> r.SessionId
            ),
            Leads AS
            (
                SELECT b.BlockingSessionId AS LeadSessionId, b.SnapshotUtc,
                       COUNT(1) AS BlockedCount
                FROM Blocked AS b
                WHERE NOT EXISTS
                (
                    SELECT 1 FROM dbo.FR_Request AS x
                    WHERE x.SnapshotId = b.SnapshotId
                      AND x.SessionId = b.BlockingSessionId
                      AND x.BlockingSessionId IS NOT NULL
                      AND x.BlockingSessionId <> 0
                )
                GROUP BY b.BlockingSessionId, b.SnapshotUtc
            ),
            LeadAgg AS
            (
                SELECT LeadSessionId, MIN(SnapshotUtc) AS FirstUtc,
                       MAX(SnapshotUtc) AS LastUtc, MAX(BlockedCount) AS MaxBlocked
                FROM Leads GROUP BY LeadSessionId
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                SessionId, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'High', N'High', N'Observed', N'Blocking',
                N'FR_R0001_ActiveBlockingChain',
                N'Active blocking chain observed',
                N'One or more sessions were blocked by a session at the head of a chain.',
                LEFT(CONCAT(N'LeadSessionId=', LeadSessionId,
                            N'; maxDirectlyBlockedSessions=', MaxBlocked), 1900),
                N'Consider reviewing the lead blocker''s transaction and what it holds only after validating it is the head of the chain.',
                LeadSessionId, FirstUtc, LastUtc,
                N'Head-of-chain = a blocker not itself blocked in the same snapshot (FR_Request.BlockingSessionId).'
            FROM LeadAgg
            ORDER BY MaxBlocked DESC, LeadSessionId ASC;
        END;

        -- FR_R0002 LongRunningOpenTransaction (Blocking / Medium / High / Observed
        -- — §7.9, D-048). No elapsed column is stored, so "long-running" = an
        -- open transaction persisting across snapshots spanning >= threshold.
        -- Anchored at @DeltaStartUtc so a restart (Group D) cannot inflate the
        -- span via session-id reuse.
        DECLARE @LongOpenTxnSeconds int = 60;
        SELECT @LongOpenTxnSeconds = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'LongOpenTxnSeconds';
        IF @LongOpenTxnSeconds IS NULL OR @LongOpenTxnSeconds < 1 SET @LongOpenTxnSeconds = 60;

        IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0002_LongRunningOpenTransaction;', @DisabledRules) = 0
        BEGIN
            ;WITH OpenTxn AS
            (
                SELECT r.SessionId, r.SnapshotUtc, r.OpenTransactionCount
                FROM dbo.FR_Request AS r
                WHERE r.SnapshotUtc >= @DeltaStartUtc AND r.SnapshotUtc <= @ReportEndUtc
                  AND r.OpenTransactionCount > 0
            ),
            Span AS
            (
                SELECT SessionId,
                       MIN(SnapshotUtc) AS FirstUtc, MAX(SnapshotUtc) AS LastUtc,
                       COUNT(DISTINCT SnapshotUtc) AS Observations,
                       MAX(OpenTransactionCount) AS MaxOpenTran
                FROM OpenTxn GROUP BY SessionId
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                SessionId, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'Medium', N'High', N'Observed', N'Blocking',
                N'FR_R0002_LongRunningOpenTransaction',
                N'Long-running open transaction observed',
                N'A session held an open transaction across multiple snapshots spanning a long interval.',
                LEFT(CONCAT(N'SessionId=', SessionId,
                            N'; openTxnSpanSeconds=', DATEDIFF(second, FirstUtc, LastUtc),
                            N'; observations=', Observations,
                            N'; maxOpenTranCount=', MaxOpenTran,
                            N'; thresholdSeconds=', @LongOpenTxnSeconds), 1900),
                N'Consider reviewing the session''s open transaction only after validating it is not an expected long-running batch.',
                SessionId, FirstUtc, LastUtc,
                N'Persistence-based: no elapsed column is stored; span computed from FR_Request across snapshots.'
            FROM Span
            WHERE Observations >= 2
              AND DATEDIFF(second, FirstUtc, LastUtc) >= @LongOpenTxnSeconds
            ORDER BY DATEDIFF(second, FirstUtc, LastUtc) DESC, SessionId ASC;
        END;

        -- FR_R0004 FileIoLatencySpike (IO / Medium->High / Medium / Inferred —
        -- §7.9, D-092/D-103). Window delta latency per (db, file) vs the recent
        -- baseline (#fr_baseline, group FileIo). Delta anchored at @DeltaStartUtc
        -- (D-007) so a restart's counter reset cannot register as a spike.
        -- Escalation to High is magnitude-based, which D-069 permits (it forbids
        -- promotion by row count, not by threshold; §7.9 lists "escalates High").
        IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0004_FileIoLatencySpike;', @DisabledRules) = 0
        BEGIN
            DECLARE @FileIoWarnMs int = 20;
            SELECT @FileIoWarnMs = TRY_CONVERT(int, ConfigValue)
            FROM dbo.FR_Config WHERE ConfigKey = N'FileIoLatencyWarnMs';
            IF @FileIoWarnMs IS NULL OR @FileIoWarnMs < 1 SET @FileIoWarnMs = 20;

            ;WITH Ranked AS
            (
                SELECT f.DatabaseId, f.FileId, f.SnapshotUtc,
                       CONVERT(bigint, f.IoStallReadMs) + f.IoStallWriteMs AS StallMs,
                       CONVERT(bigint, f.NumOfReads) + f.NumOfWrites AS Ops,
                       ROW_NUMBER() OVER (PARTITION BY f.DatabaseId, f.FileId ORDER BY f.SnapshotUtc ASC)  AS rnFirst,
                       ROW_NUMBER() OVER (PARTITION BY f.DatabaseId, f.FileId ORDER BY f.SnapshotUtc DESC) AS rnLast
                FROM dbo.FR_FileStat AS f
                WHERE f.SnapshotUtc >= @DeltaStartUtc AND f.SnapshotUtc <= @ReportEndUtc
            ),
            Lat AS
            (
                SELECT a.DatabaseId, a.FileId,
                       (l.StallMs - a.StallMs) AS DeltaStallMs,
                       (l.Ops - a.Ops) AS DeltaOps
                FROM Ranked AS a
                INNER JOIN Ranked AS l
                    ON l.DatabaseId = a.DatabaseId AND l.FileId = a.FileId AND l.rnLast = 1
                WHERE a.rnFirst = 1
            ),
            LatMs AS
            (
                -- NULLIF guards the division: SQL Server may evaluate the
                -- projection before the WHERE filter, so DeltaOps = 0 must not
                -- reach the divide. Rows with NULL latency are dropped by the
                -- WHERE below anyway.
                SELECT DatabaseId, FileId,
                       CONVERT(decimal(18,2), DeltaStallMs * 1.0 / NULLIF(DeltaOps, 0)) AS LatencyMs
                FROM Lat
                WHERE DeltaOps > 0 AND DeltaStallMs >= 0   -- exclude counter reset
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                CASE WHEN m.LatencyMs > @FileIoWarnMs * 4
                          AND (b.BaselineAvg IS NULL OR m.LatencyMs > b.BaselineAvg * 4)
                     THEN N'High' ELSE N'Medium' END,
                CASE WHEN b.SampleCount IS NULL OR b.SampleCount < 5 THEN N'Low' ELSE N'Medium' END,
                N'Inferred', N'IO',
                N'FR_R0004_FileIoLatencySpike',
                N'File I/O latency increased during the window',
                N'Average read+write stall per I/O for a database file is elevated over its recent baseline.',
                LEFT(CONCAT(N'DatabaseId=', m.DatabaseId, N'; FileId=', m.FileId,
                            N'; windowLatencyMs=', CONVERT(nvarchar(40), m.LatencyMs),
                            N'; baselineAvgMs=', ISNULL(CONVERT(nvarchar(40), b.BaselineAvg), N'(insufficient history)'),
                            N'; floorMs=', @FileIoWarnMs,
                            N'; baselineSamples=', ISNULL(CONVERT(nvarchar(10), b.SampleCount), N'0')), 1900),
                N'Consider correlating file latency with workload, storage, and backup activity only after validating the elevation is sustained.',
                DB_NAME(m.DatabaseId), @ReportStartUtc, @ReportEndUtc,
                N'Delta latency = change in IO stall divided by change in ops from @DeltaStartUtc (D-007); baseline-relative (D-092).'
            FROM LatMs AS m
            LEFT JOIN #fr_baseline AS b
                ON b.MetricKey = CONCAT(N'FileIo:', m.DatabaseId, N':', m.FileId)
            WHERE m.LatencyMs > @FileIoWarnMs
              AND (b.BaselineAvg IS NULL OR m.LatencyMs > b.BaselineAvg * 2)
            ORDER BY m.LatencyMs DESC;
        END;

        -- FR_R0005 MemoryGrantsPending (Memory / High / High / Observed — §7.9,
        -- D-048). Observed pending grant = FR_Request row with RequestedMemoryKb
        -- > 0 and no grant yet. Session anchored (for the R0005/R0024 fold).
        IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0005_MemoryGrantsPending;', @DisabledRules) = 0
        BEGIN
            DECLARE @MemGrantsPendingMax bigint = NULL;
            IF OBJECT_ID(N'dbo.FR_Memory', N'U') IS NOT NULL
                SELECT @MemGrantsPendingMax = MAX(m.MemoryGrantsPending)
                FROM dbo.FR_Memory AS m
                INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = m.SnapshotId
                WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
                  AND m.SnapshotUtc >= @ReportStartUtc AND m.SnapshotUtc <= @ReportEndUtc;

            ;WITH Pending AS
            (
                SELECT r.SessionId, r.DatabaseId,
                       MIN(r.SnapshotUtc) AS FirstUtc, MAX(r.SnapshotUtc) AS LastUtc,
                       MAX(r.RequestedMemoryKb) AS MaxRequestedKb
                FROM dbo.FR_Request AS r
                WHERE r.SnapshotUtc >= @ReportStartUtc AND r.SnapshotUtc <= @ReportEndUtc
                  AND r.RequestedMemoryKb > 0
                  AND (r.GrantedMemoryKb IS NULL OR r.GrantedMemoryKb = 0)
                GROUP BY r.SessionId, r.DatabaseId
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'High', N'High', N'Observed', N'Memory',
                N'FR_R0005_MemoryGrantsPending',
                N'Query memory grant pending',
                N'A request was waiting for a query memory grant (requested but not yet granted).',
                LEFT(CONCAT(N'SessionId=', p.SessionId,
                            N'; maxRequestedMemoryKb=', p.MaxRequestedKb,
                            N'; memoryGrantsPendingCounterMax=', ISNULL(CONVERT(nvarchar(20), @MemGrantsPendingMax), N'(n/a)')), 1900),
                N'Consider reviewing large memory-grant queries and concurrency only after validating the pending grants correlate with the incident.',
                DB_NAME(p.DatabaseId), p.SessionId, p.FirstUtc, p.LastUtc,
                N'Observed pending grant from FR_Request (RequestedMemoryKb > 0, GrantedMemoryKb NULL/0); FR_Memory counter for corroboration.'
            FROM Pending AS p
            ORDER BY p.MaxRequestedKb DESC, p.SessionId ASC;
        END;

        DECLARE @BlockingStormThreshold int = 5;
        SELECT @BlockingStormThreshold = TRY_CONVERT(int, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'BlockingStormSessionThreshold';
        IF @BlockingStormThreshold IS NULL OR @BlockingStormThreshold < 1 SET @BlockingStormThreshold = 5;

        DECLARE @TempdbVsWarnKb bigint = 5242880;
        SELECT @TempdbVsWarnKb = TRY_CONVERT(bigint, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'TempdbVersionStoreWarnKb';
        IF @TempdbVsWarnKb IS NULL OR @TempdbVsWarnKb < 1 SET @TempdbVsWarnKb = 5242880;

        -- FR_R0007 BlockingStorm (Blocking / Critical / High / Observed)
        IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0007_BlockingStorm;', @DisabledRules) = 0
        BEGIN
            ;WITH StormPerSnapshot AS
            (
                SELECT r.SnapshotId, r.SnapshotUtc,
                       COUNT(DISTINCT r.SessionId) AS BlockedSessions
                FROM dbo.FR_Request AS r
                WHERE r.SnapshotUtc >= @ReportStartUtc
                  AND r.SnapshotUtc <= @ReportEndUtc
                  AND r.BlockingSessionId IS NOT NULL
                  AND r.BlockingSessionId <> 0
                GROUP BY r.SnapshotId, r.SnapshotUtc
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Critical', N'High', N'Observed', N'Blocking',
                N'FR_R0007_BlockingStorm',
                N'Blocking storm observed',
                N'Multiple sessions were blocked within a single snapshot in the window.',
                CONCAT(N'Peak blocked sessions in one snapshot: ', MAX(BlockedSessions),
                       N'; threshold: ', @BlockingStormThreshold),
                N'Consider reviewing the lead blocker and the involved transactions only after validating which session is at the head of the chain.',
                MIN(SnapshotUtc), MAX(SnapshotUtc),
                N'Computed from FR_Request.BlockingSessionId per snapshot. Folds the same anchor as FR_R0001/FR_R0002.'
            FROM StormPerSnapshot
            HAVING MAX(BlockedSessions) >= @BlockingStormThreshold;
        END;

        -- FR_R0008 TempdbVersionStoreGrowth (Tempdb / Medium→High / High / Observed)
        IF OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0008_TempdbVersionStoreGrowth;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                CASE WHEN MAX(VersionStoreKb) >= @TempdbVsWarnKb THEN N'High' ELSE N'Medium' END,
                N'High', N'Observed', N'Tempdb',
                N'FR_R0008_TempdbVersionStoreGrowth',
                N'Tempdb version store growth observed',
                N'The tempdb version store grew during the report window.',
                CONCAT(N'Min version store: ', MIN(VersionStoreKb), N' KB; max: ', MAX(VersionStoreKb),
                       N' KB; escalation threshold: ', @TempdbVsWarnKb, N' KB'),
                N'Consider reviewing long-running or open transactions and snapshot-isolation usage only after validating which workload holds versions.',
                MIN(SnapshotUtc), MAX(SnapshotUtc),
                N'Computed from FR_Tempdb.VersionStoreKb across the window.'
            FROM dbo.FR_Tempdb
            WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
            HAVING MAX(VersionStoreKb) > MIN(VersionStoreKb)
               AND MAX(VersionStoreKb) > 0;
        END;

        -- FR_R0009 TempdbFileImbalanceOrPressure (Tempdb / Medium / Medium / Inferred)
        IF OBJECT_ID(N'dbo.FR_Tempdb', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0009_TempdbFileImbalanceOrPressure;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Medium', N'Medium', N'Inferred', N'Tempdb',
                N'FR_R0009_TempdbFileImbalanceOrPressure',
                N'Tempdb data file imbalance observed',
                N'Tempdb data files differ substantially in size during the window.',
                CONCAT(N'Data files: ', MAX(DataFileCount),
                       N'; min file: ', MIN(MinDataFileSizeKb), N' KB; max file: ', MAX(MaxDataFileSizeKb), N' KB'),
                N'Consider reviewing whether tempdb data files are equally sized only after validating allocation contention is relevant to this workload.',
                MIN(SnapshotUtc), MAX(SnapshotUtc),
                N'Computed from FR_Tempdb file size columns. Inferred signal; not a confirmed root cause.'
            FROM dbo.FR_Tempdb
            WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
            HAVING MAX(DataFileCount) > 1
               AND MAX(MaxDataFileSizeKb) > MIN(MinDataFileSizeKb) * 2
               AND MIN(MinDataFileSizeKb) > 0;
        END;

        -- FR_R0010 FailedSqlAgentJobNearIncident (Maintenance / High / High / Observed)
        -- Window = 15 minutes before @ReportStartUtc through @ReportEndUtc (D-095).
        IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0010_FailedSqlAgentJobNearIncident;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'High', N'High', N'Observed', N'Maintenance',
                N'FR_R0010_FailedSqlAgentJobNearIncident',
                N'Failed SQL Agent job near the incident window',
                CONCAT(N'Job ''', j.JobName, N''' reported a failed outcome near the window.'),
                CONCAT(N'RunStartUtc=', CONVERT(nvarchar(30), j.RunStartUtc, 126),
                       N'; Outcome=', j.RunOutcome, N'; Msg=', LEFT(ISNULL(j.MessageText, N''), 200)),
                N'Consider reviewing this job''s history and step output only after validating whether it correlates with the incident.',
                NULL,
                j.RunStartUtc, j.RunStartUtc,
                N'From FR_AgentJob delta read. Correlation by time, not confirmed causation.'
            FROM dbo.FR_AgentJob AS j
            WHERE j.RunOutcome = N'Failed'
              AND j.RunStartUtc >= DATEADD(minute, -15, @ReportStartUtc)
              AND j.RunStartUtc <= @ReportEndUtc
            ORDER BY j.RunStartUtc DESC;
        END;

        -- FR_R0011 MaintenanceJobOverlap (Maintenance / Medium / Medium / Inferred)
        IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0011_MaintenanceJobOverlap;', @DisabledRules) = 0
        BEGIN
            DECLARE @MaintPatterns nvarchar(4000) = N'';
            SELECT @MaintPatterns = ISNULL(ConfigValue, N'')
            FROM dbo.FR_Config WHERE ConfigKey = N'MaintenanceJobNamePatterns';

            ;WITH MaintJobs AS
            (
                SELECT DISTINCT j.JobName, j.RunStartUtc,
                       DATEADD(second, ISNULL(j.RunDurationSec, 0), j.RunStartUtc) AS RunEndUtc
                FROM dbo.FR_AgentJob AS j
                CROSS APPLY
                (
                    SELECT TRY_CONVERT(xml, N'<p>' + REPLACE(@MaintPatterns, N';', N'</p><p>') + N'</p>') AS x
                ) AS px
                WHERE j.RunStartUtc IS NOT NULL
                  AND EXISTS
                  (
                      SELECT 1
                      FROM px.x.nodes('/p') AS n(c)
                      WHERE LTRIM(RTRIM(n.c.value('.', 'nvarchar(200)'))) <> N''
                        AND j.JobName LIKE n.c.value('.', 'nvarchar(200)')
                  )
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'Medium', N'Medium', N'Inferred', N'Maintenance',
                N'FR_R0011_MaintenanceJobOverlap',
                N'Maintenance job overlapped the incident window',
                CONCAT(N'Maintenance job ''', JobName, N''' ran during or across the window.'),
                CONCAT(N'RunStartUtc=', CONVERT(nvarchar(30), RunStartUtc, 126),
                       N'; RunEndUtc=', CONVERT(nvarchar(30), RunEndUtc, 126)),
                N'Consider reviewing whether this maintenance activity coincided with the symptoms only after validating overlap is meaningful.',
                RunStartUtc, RunEndUtc,
                N'Job name matched MaintenanceJobNamePatterns (D-094). Inferred overlap.'
            FROM MaintJobs
            WHERE RunStartUtc <= @ReportEndUtc
              AND RunEndUtc   >= @ReportStartUtc
            ORDER BY RunStartUtc DESC;
        END;

        -- FR_R0012 BackupOverlapWithIncident (Maintenance / Medium / High / Observed)
        -- Log backups excluded (D-096).
        IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0012_BackupOverlapWithIncident;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'Medium', N'High', N'Observed', N'Maintenance',
                N'FR_R0012_BackupOverlapWithIncident',
                N'Backup overlapped the incident window',
                CONCAT(N'A ', b.BackupType, N' backup of [', b.DatabaseName, N'] overlapped the window.'),
                CONCAT(N'Start=', CONVERT(nvarchar(30), b.BackupStartUtc, 126),
                       N'; Finish=', CONVERT(nvarchar(30), b.BackupFinishUtc, 126),
                       N'; SizeBytes=', ISNULL(CONVERT(nvarchar(30), b.BackupSizeBytes), N'')),
                N'Consider reviewing whether backup I/O coincided with the symptoms only after validating the overlap is relevant.',
                b.DatabaseName,
                b.BackupStartUtc, b.BackupFinishUtc,
                N'From FR_BackupHistory. Log backups are excluded by design (D-096).'
            FROM dbo.FR_BackupHistory AS b
            WHERE b.BackupType <> N'Log'
              AND b.BackupStartUtc IS NOT NULL
              AND b.BackupStartUtc  <= @ReportEndUtc
              AND ISNULL(b.BackupFinishUtc, b.BackupStartUtc) >= @ReportStartUtc
            ORDER BY b.BackupStartUtc DESC;
        END;

        -- FR_R0013 DeadlocksObserved (Blocking / High / High / Observed)
        IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0013_DeadlocksObserved;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'High', N'High', N'Observed', N'Blocking',
                N'FR_R0013_DeadlocksObserved',
                N'Deadlocks observed in the window',
                N'One or more unique deadlock graphs were captured during the window.',
                CONCAT(N'Distinct deadlock graphs: ', COUNT(DISTINCT GraphHash),
                       N'; total captured: ', COUNT(1)),
                N'Consider reviewing the deadlock graphs and the participating queries only after validating the victims and resources.',
                MIN(ISNULL(DeadlockTimeUtc, SnapshotUtc)),
                MAX(ISNULL(DeadlockTimeUtc, SnapshotUtc)),
                N'From FR_Deadlock (deduped by graph hash, D-053). Graph XML stored for review.'
            FROM dbo.FR_Deadlock
            WHERE ISNULL(DeadlockTimeUtc, SnapshotUtc) >= @ReportStartUtc
              AND ISNULL(DeadlockTimeUtc, SnapshotUtc) <= @ReportEndUtc
            HAVING COUNT(1) > 0;
        END;

        -- FR_R0014 AlwaysOnRoleOrStateChange (HA / Critical / High / Observed)
        IF OBJECT_ID(N'dbo.FR_AlwaysOnState', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0014_AlwaysOnRoleOrStateChange;', @DisabledRules) = 0
        BEGIN
            ;WITH AoWindow AS
            (
                SELECT AgName, ReplicaServer,
                       COUNT(DISTINCT Role) AS DistinctRoles,
                       COUNT(DISTINCT SynchronizationHealth) AS DistinctHealth
                FROM dbo.FR_AlwaysOnState
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
                GROUP BY AgName, ReplicaServer
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                N'Critical', N'High', N'Observed', N'HA',
                N'FR_R0014_AlwaysOnRoleOrStateChange',
                N'Always On role or synchronization state changed',
                CONCAT(N'Replica [', ReplicaServer, N'] in AG [', AgName, N'] changed role or health during the window.'),
                CONCAT(N'DistinctRoles=', DistinctRoles, N'; DistinctHealthStates=', DistinctHealth),
                N'Consider reviewing the AG dashboard and cluster log for the timeframe only after validating the change correlates with the incident.',
                @ReportStartUtc, @ReportEndUtc,
                N'Computed from FR_AlwaysOnState across the window.'
            FROM AoWindow
            WHERE DistinctRoles > 1 OR DistinctHealth > 1;
        END;

        -- =====================================================================
        -- v0.3 rule evaluation (FR_R0015–FR_R0020, design §7.11). Bounded to the
        -- report window. Repository-only reads (D-014/D-081). Honors DisabledRules.
        -- FR_R0019 (QS capacity) ships in v0.3 chunk 3B with its collect-time
        -- capture; it is intentionally not emitted here (D-113: no dynamic SQL in
        -- rules), so it is not evaluated in this block.
        -- =====================================================================
        DECLARE @QsRegressionFactor decimal(5,2) = 2.0;
        SELECT @QsRegressionFactor = TRY_CONVERT(decimal(5,2), ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreRegressionFactor';
        IF @QsRegressionFactor IS NULL OR @QsRegressionFactor < 1 SET @QsRegressionFactor = 2.0;

        DECLARE @CompilationsWarn bigint = 100;
        SELECT @CompilationsWarn = TRY_CONVERT(bigint, ConfigValue)
        FROM dbo.FR_Config WHERE ConfigKey = N'CompilationsPerSecWarn';
        IF @CompilationsWarn IS NULL OR @CompilationsWarn < 1 SET @CompilationsWarn = 100;

        -- FR_R0015 QueryPlanRegression (QueryStore / High / Medium[Low on 2016] / Inferred)
        -- Latest captured plan for a query vs its best prior plan (D-107: 2016 = runtime stats only,
        -- Confidence forced down one level).
        IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0015_QueryPlanRegression;', @DisabledRules) = 0
        BEGIN
            ;WITH QsWin AS
            (
                SELECT DatabaseName, QsQueryId, QsPlanId,
                       MAX(AvgDurationUs) AS AvgDurationUs,
                       MAX(SnapshotUtc)   AS LastSeenUtc
                FROM dbo.FR_QueryStoreTopN
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
                  AND AvgDurationUs IS NOT NULL
                GROUP BY DatabaseName, QsQueryId, QsPlanId
            ),
            Ranked AS
            (
                SELECT DatabaseName, QsQueryId, QsPlanId, AvgDurationUs, LastSeenUtc,
                       ROW_NUMBER() OVER (PARTITION BY DatabaseName, QsQueryId
                                          ORDER BY LastSeenUtc DESC, QsPlanId DESC) AS rnLatest,
                       COUNT(*)           OVER (PARTITION BY DatabaseName, QsQueryId) AS PlanCount,
                       MIN(AvgDurationUs) OVER (PARTITION BY DatabaseName, QsQueryId) AS BestAvgUs
                FROM QsWin
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo, AnchorKey
            )
            SELECT TOP (@MaxFindings)
                N'High',
                CASE WHEN @ProductMajorProbe = 13 THEN N'Low' ELSE N'Medium' END,
                N'Inferred', N'QueryStore',
                N'FR_R0015_QueryPlanRegression',
                N'Query Store shows evidence consistent with a plan regression',
                N'A query has a recent plan whose average duration is materially higher than a prior plan.',
                LEFT(CONCAT(N'QsQueryId=', QsQueryId, N'; latestPlanId=', QsPlanId,
                            N'; latestAvgUs=', AvgDurationUs, N'; bestPriorAvgUs=', BestAvgUs,
                            N'; factor>=', @QsRegressionFactor), 1900),
                N'Consider reviewing this query in Query Store only after validating the regression is real and sustained. Do not force a plan automatically.',
                DatabaseName, @ReportStartUtc, @ReportEndUtc,
                CASE WHEN @ProductMajorProbe = 13
                     THEN N'SQL 2016: runtime-stats-only comparison; Confidence intentionally reduced (D-107).'
                     ELSE N'Compared latest captured plan vs best prior plan for the same query (Query Store).' END,
                CONCAT(ISNULL(DatabaseName, N''), N':', CONVERT(nvarchar(20), QsQueryId))
            FROM Ranked
            WHERE rnLatest = 1
              AND PlanCount > 1
              AND BestAvgUs > 0
              AND AvgDurationUs >= BestAvgUs * @QsRegressionFactor
            ORDER BY AvgDurationUs DESC;
        END;

        -- FR_R0016 TopCpuConsumerInWindow (QueryStore / Medium / High / Observed)
        -- Top-5 by total CPU; duration/reads carried as supplementary evidence.
        IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0016_TopCpuConsumerInWindow;', @DisabledRules) = 0
        BEGIN
            ;WITH QsAgg AS
            (
                SELECT DatabaseName, QsQueryId,
                       SUM(ISNULL(TotalCpuUs, 0))      AS TotalCpuUs,
                       SUM(ISNULL(TotalDurationUs, 0)) AS TotalDurationUs,
                       SUM(ISNULL(ExecutionCount, 0))  AS ExecutionCount,
                       MAX(ISNULL(AvgLogicalReads, 0)) AS AvgLogicalReads
                FROM dbo.FR_QueryStoreTopN
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
                GROUP BY DatabaseName, QsQueryId
            ),
            Ranked AS
            (
                SELECT DatabaseName, QsQueryId, TotalCpuUs, TotalDurationUs, ExecutionCount, AvgLogicalReads,
                       ROW_NUMBER() OVER (ORDER BY TotalCpuUs DESC, DatabaseName, QsQueryId) AS rn
                FROM QsAgg
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo, AnchorKey
            )
            SELECT TOP (5)
                N'Medium', N'High', N'Observed', N'QueryStore',
                N'FR_R0016_TopCpuConsumerInWindow',
                N'Top CPU consumer in the window (Query Store)',
                N'This query accumulated the most CPU in Query Store during the window.',
                LEFT(CONCAT(N'QsQueryId=', QsQueryId, N'; totalCpuUs=', TotalCpuUs,
                            N'; totalDurationUs=', TotalDurationUs, N'; execCount=', ExecutionCount,
                            N'; avgLogicalReads=', AvgLogicalReads), 1900),
                N'Consider reviewing this query for tuning opportunities only after validating it is representative of the incident.',
                DatabaseName, @ReportStartUtc, @ReportEndUtc,
                N'Aggregated from FR_QueryStoreTopN across the window (CPU-ranked).',
                CONCAT(ISNULL(DatabaseName, N''), N':', CONVERT(nvarchar(20), QsQueryId))
            FROM Ranked
            WHERE rn <= 5 AND TotalCpuUs > 0
            ORDER BY TotalCpuUs DESC;
        END;

        -- FR_R0017 QueryStoreDisabledOnUserDbs (Coverage / Informational / High / Observed)
        -- Repository-only: QueryStore collector step reported Skipped (no QS-enabled DB).
        IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0017_QueryStoreDisabledOnUserDbs;', @DisabledRules) = 0
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Informational', N'High', N'Observed', N'Coverage',
                N'FR_R0017_QueryStoreDisabledOnUserDbs',
                N'Query Store not enabled on eligible user databases',
                N'The Query Store collector ran but found no Query Store-enabled user database.',
                N'Most recent QueryStore collector step reported Skipped in the window.',
                N'Consider validating whether Query Store should be enabled on key databases to improve future plan-level evidence.',
                @ReportStartUtc, @ReportEndUtc,
                N'Repository-only signal: based on FR_RunLogStep StepName=QueryStore, Status=Skipped.'
            FROM dbo.FR_RunLogStep AS st
            WHERE st.StepName = N'QueryStore'
              AND st.Status = N'Skipped'
              AND st.StartUtc >= @ReportStartUtc AND st.StartUtc <= @ReportEndUtc;
        END;

        -- =====================================================================
        -- v0.4 rules (FR_R0021–FR_R0025). Evidence-based; repository-only (D-081).
        -- Each rule isolated; a rule error must not abort Report.
        -- =====================================================================

        -- FR_R0021 ConfigurationChangeInWindow (Configuration / Medium / High / Observed)
        -- Evidence: a tracked configuration value differs across snapshots in window.
        BEGIN TRY
            ;WITH cfg AS
            (
                SELECT
                    c.ConfigurationKind, c.Name, c.ValueText, s.SnapshotUtc,
                    LAG(c.ValueText) OVER (PARTITION BY c.ConfigurationKind, c.Name ORDER BY s.SnapshotUtc) AS PrevValue
                FROM dbo.FR_Configuration AS c
                INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = c.SnapshotId
                WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
                  AND c.SnapshotUtc >= @ReportStartUtc AND c.SnapshotUtc <= @ReportEndUtc
            )
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            SELECT TOP (200)
                N'Medium', N'High', N'Observed', N'Configuration',
                N'FR_R0021_ConfigurationChangeInWindow',
                N'Configuration changed during the window',
                CONCAT(N'Setting "', cfg.Name, N'" changed in the analysis window.'),
                LEFT(CONCAT(N'Kind=', cfg.ConfigurationKind, N'; Name=', cfg.Name,
                            N'; From=', ISNULL(cfg.PrevValue, N'(null)'), N'; To=', ISNULL(cfg.ValueText, N'(null)'),
                            N'; ChangedAtUtc=', CONVERT(nvarchar(30), cfg.SnapshotUtc, 126)), 1900),
                N'Correlate the change time with the incident window; consider reviewing the change only after validating intent.',
                NULL, cfg.Name, NULL, cfg.SnapshotUtc, cfg.SnapshotUtc,
                N'Source: FR_Configuration snapshot diff.'
            FROM cfg
            WHERE cfg.PrevValue IS NOT NULL AND cfg.PrevValue <> cfg.ValueText
              AND CHARINDEX(N';FR_R0021_ConfigurationChangeInWindow;', @DisabledRules) = 0
            ORDER BY cfg.SnapshotUtc DESC;
        END TRY
        BEGIN CATCH
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'Low', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Rule evaluation skipped', N'FR_R0021 could not be evaluated.',
                    LEFT(ERROR_MESSAGE(), 1900), NULL, NULL, NULL, NULL,
                    @ReportStartUtc, @ReportEndUtc, N'FR_R0021 error captured as coverage note.');
        END CATCH;

        -- FR_R0022 LogReuseWaitElevated (IO / High / High / Observed) — baseline-aware.
        -- Evidence: log_reuse_wait surfaced via FR_PerfCounter 'Percent Log Used' / 'Log Growths'
        -- elevated vs recent baseline (D-092). Uses #fr_baseline; downgrades when <5 samples.
        BEGIN TRY
            ;WITH cur AS
            (
                SELECT RTRIM(p.CounterName) AS CounterName,
                       MAX(CONVERT(decimal(38,3), p.CounterValue)) AS CurMax
                FROM dbo.FR_PerfCounter AS p
                INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = p.SnapshotId
                WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
                  AND p.SnapshotUtc >= @ReportStartUtc AND p.SnapshotUtc <= @ReportEndUtc
                  AND RTRIM(p.CounterName) IN (N'Log Growths', N'Percent Log Used')
                GROUP BY RTRIM(p.CounterName)
            )
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            SELECT TOP (50)
                N'High',
                CASE WHEN b.SampleCount IS NULL OR b.SampleCount < 5 THEN N'Low' ELSE N'High' END,
                N'Observed', N'IO',
                N'FR_R0022_LogReuseWaitElevated',
                N'Transaction log reuse/growth elevated',
                CONCAT(N'Counter "', cur.CounterName, N'" is elevated compared with observed history.'),
                LEFT(CONCAT(N'Counter=', cur.CounterName, N'; WindowMax=', CONVERT(nvarchar(40), cur.CurMax),
                            N'; BaselineAvg=', ISNULL(CONVERT(nvarchar(40), b.BaselineAvg), N'(insufficient history)'),
                            N'; Samples=', ISNULL(CONVERT(nvarchar(10), b.SampleCount), N'0')), 1900),
                N'Review log backup cadence and long-running transactions only after validating that the elevation correlates with the incident window.',
                NULL, NULL, NULL, @ReportStartUtc, @ReportEndUtc,
                N'Baseline-relative (D-092); above recent baseline.'
            FROM cur
            LEFT JOIN #fr_baseline AS b ON b.MetricKey = CONCAT(N'Perf:', cur.CounterName)
            WHERE cur.CounterName = N'Log Growths'         -- growth events in window are the strong signal
              AND cur.CurMax > 0
              AND CHARINDEX(N';FR_R0022_LogReuseWaitElevated;', @DisabledRules) = 0
              AND (b.BaselineAvg IS NULL OR cur.CurMax > (b.BaselineAvg + 1));
        END TRY
        BEGIN CATCH
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'Low', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Rule evaluation skipped', N'FR_R0022 could not be evaluated.',
                    LEFT(ERROR_MESSAGE(), 1900), NULL, NULL, NULL, NULL,
                    @ReportStartUtc, @ReportEndUtc, N'FR_R0022 error captured as coverage note.');
        END CATCH;

        -- FR_R0023 ThreadpoolWaitsObserved (Waits / Critical / High / Observed)
        -- Evidence: any THREADPOOL wait recorded in window = worker starvation.
        BEGIN TRY
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            SELECT TOP (1)
                N'Critical', N'High', N'Observed', N'Waits',
                N'FR_R0023_ThreadpoolWaitsObserved',
                N'THREADPOOL waits observed',
                N'THREADPOOL waits were recorded during the window (possible worker thread starvation).',
                LEFT(CONCAT(N'WaitType=THREADPOOL; SumWaitMs=', CONVERT(nvarchar(40), SUM(CONVERT(decimal(38,0), w.WaitTimeMs))),
                            N'; MaxWaitMs=', CONVERT(nvarchar(40), MAX(CONVERT(decimal(38,0), w.MaxWaitTimeMs)))), 1900),
                N'Investigate blocking chains and high session counts; consider reviewing max worker threads only after validating sustained starvation.',
                NULL, NULL, NULL, @ReportStartUtc, @ReportEndUtc,
                N'Source: FR_Wait (THREADPOOL).'
            FROM dbo.FR_Wait AS w
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = w.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND w.SnapshotUtc >= @ReportStartUtc AND w.SnapshotUtc <= @ReportEndUtc
              AND w.WaitType = N'THREADPOOL'
              AND w.WaitTimeMs > 0
              AND CHARINDEX(N';FR_R0023_ThreadpoolWaitsObserved;', @DisabledRules) = 0
            HAVING COUNT(1) > 0;
        END TRY
        BEGIN CATCH
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'Low', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Rule evaluation skipped', N'FR_R0023 could not be evaluated.',
                    LEFT(ERROR_MESSAGE(), 1900), NULL, NULL, NULL, NULL,
                    @ReportStartUtc, @ReportEndUtc, N'FR_R0023 error captured as coverage note.');
        END CATCH;

        -- FR_R0024 ResourceSemaphoreWaits (Memory / High / High / Observed)
        -- Evidence: RESOURCE_SEMAPHORE waits in window = memory grant pressure.
        BEGIN TRY
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            SELECT TOP (1)
                N'High', N'High', N'Observed', N'Memory',
                N'FR_R0024_ResourceSemaphoreWaits',
                N'RESOURCE_SEMAPHORE waits observed',
                N'Query memory grant waits (RESOURCE_SEMAPHORE) were recorded during the window.',
                LEFT(CONCAT(N'WaitType=RESOURCE_SEMAPHORE; SumWaitMs=', CONVERT(nvarchar(40), SUM(CONVERT(decimal(38,0), w.WaitTimeMs))),
                            N'; WaitingTasks=', CONVERT(nvarchar(40), SUM(CONVERT(decimal(38,0), w.WaitingTasksCount)))), 1900),
                N'Review large memory-grant queries and MAX_GRANT_PERCENT only after validating that grants correlate with the incident window.',
                NULL, NULL, NULL, @ReportStartUtc, @ReportEndUtc,
                N'Source: FR_Wait (RESOURCE_SEMAPHORE).'
            FROM dbo.FR_Wait AS w
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = w.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND w.SnapshotUtc >= @ReportStartUtc AND w.SnapshotUtc <= @ReportEndUtc
              AND w.WaitType = N'RESOURCE_SEMAPHORE'
              AND w.WaitTimeMs > 0
              AND CHARINDEX(N';FR_R0024_ResourceSemaphoreWaits;', @DisabledRules) = 0
            HAVING COUNT(1) > 0;
        END TRY
        BEGIN CATCH
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'Low', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Rule evaluation skipped', N'FR_R0024 could not be evaluated.',
                    LEFT(ERROR_MESSAGE(), 1900), NULL, NULL, NULL, NULL,
                    @ReportStartUtc, @ReportEndUtc, N'FR_R0024 error captured as coverage note.');
        END CATCH;

        -- FR_R0025 RecentCheckDbOrBackupAge (Maintenance / Medium|High / High / Observed)
        -- Evidence: latest FULL backup age > BackupWarnDays (Medium); thresholds via FR_Config (D-097).
        -- CHECKDB age is best-effort: only emitted if a CHECKDB signal exists in FR_AgentJob/FR_ErrorLog.
        BEGIN TRY
            DECLARE @BackupWarnDays int = 7, @CheckDbWarnDays int = 14;
            SELECT @BackupWarnDays  = ISNULL(TRY_CONVERT(int, ConfigValue), 7)
            FROM dbo.FR_Config WHERE ConfigKey = N'BackupWarnDays';
            SELECT @CheckDbWarnDays = ISNULL(TRY_CONVERT(int, ConfigValue), 14)
            FROM dbo.FR_Config WHERE ConfigKey = N'CheckDbWarnDays';

            IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            SELECT TOP (50)
                N'Medium', N'High', N'Observed', N'Maintenance',
                N'FR_R0025_RecentCheckDbOrBackupAge',
                N'FULL backup age exceeds threshold',
                CONCAT(N'Database "', lb.DatabaseName, N'" last FULL backup is older than ', @BackupWarnDays, N' day(s).'),
                LEFT(CONCAT(N'Database=', lb.DatabaseName,
                            N'; LastFullBackupUtc=', ISNULL(CONVERT(nvarchar(30), lb.LastFull, 126), N'(none observed)'),
                            N'; AgeDays=', ISNULL(CONVERT(nvarchar(10), DATEDIFF(day, lb.LastFull, @ReportEndUtc)), N'>retention'),
                            N'; ThresholdDays=', CONVERT(nvarchar(10), @BackupWarnDays)), 1900),
                N'Confirm the backup schedule and chain; consider a FULL backup only after validating RPO requirements.',
                lb.DatabaseName, NULL, NULL, @ReportStartUtc, @ReportEndUtc,
                N'Source: FR_BackupHistory (BackupType=D). Age limited by repository retention.'
            FROM (
                SELECT bh.DatabaseName, MAX(bh.BackupFinishUtc) AS LastFull
                FROM dbo.FR_BackupHistory AS bh
                WHERE bh.BackupType IN (N'D', N'Database', N'Full')
                GROUP BY bh.DatabaseName
            ) AS lb
            WHERE CHARINDEX(N';FR_R0025_RecentCheckDbOrBackupAge;', @DisabledRules) = 0
              AND (lb.LastFull IS NULL
                   OR DATEDIFF(day, lb.LastFull, @ReportEndUtc) > @BackupWarnDays);
        END TRY
        BEGIN CATCH
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'Low', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Rule evaluation skipped', N'FR_R0025 could not be evaluated.',
                    LEFT(ERROR_MESSAGE(), 1900), NULL, NULL, NULL, NULL,
                    @ReportStartUtc, @ReportEndUtc, N'FR_R0025 error captured as coverage note.');
        END CATCH;

        -- FR_R0018 FailedPlanForcing (QueryStore / Medium / High / Observed)
        -- Deduped by (db, query, plan) per D-074 intra-category anchor.
        IF OBJECT_ID(N'dbo.FR_QueryStoreTopN', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0018_FailedPlanForcing;', @DisabledRules) = 0
        BEGIN
            ;WITH Forced AS
            (
                SELECT DatabaseName, QsQueryId, QsPlanId,
                       MAX(ISNULL(ForceFailureCount, 0)) AS ForceFailureCount,
                       MAX(LastForceFailureReason)       AS LastForceFailureReason
                FROM dbo.FR_QueryStoreTopN
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
                  AND ISNULL(ForceFailureCount, 0) > 0
                GROUP BY DatabaseName, QsQueryId, QsPlanId
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                DatabaseName, StartTimeUtc, EndTimeUtc, MoreInfo, AnchorKey
            )
            SELECT TOP (@MaxFindings)
                N'Medium', N'High', N'Observed', N'QueryStore',
                N'FR_R0018_FailedPlanForcing',
                N'Query Store shows evidence consistent with a forced-plan failure',
                N'A forced plan reported one or more force failures in the window.',
                LEFT(CONCAT(N'QsQueryId=', QsQueryId, N'; PlanId=', QsPlanId,
                            N'; ForceFailureCount=', ForceFailureCount,
                            N'; Reason=', ISNULL(LastForceFailureReason, N'')), 1900),
                N'Consider reviewing why the forced plan is failing only after validating the forcing is still intended. Do not force or unforce plans automatically.',
                DatabaseName, @ReportStartUtc, @ReportEndUtc,
                N'From FR_QueryStoreTopN forced-plan columns (deduped by db/query/plan).',
                CONCAT(ISNULL(DatabaseName, N''), N':', CONVERT(nvarchar(20), QsQueryId), N':', CONVERT(nvarchar(20), QsPlanId))
            FROM Forced
            ORDER BY ForceFailureCount DESC;
        END;

        -- FR_R0020 HighCompilationRate (PlanCache / Medium / Medium / Inferred)
        -- Rate derived from raw cumulative counters via window delta (D-007).
        -- Negative deltas (counter reset on restart) are excluded by the threshold test.
        IF OBJECT_ID(N'dbo.FR_PlanCacheSummary', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0020_HighCompilationRate;', @DisabledRules) = 0
        BEGIN
            -- Delta anchor at @DeltaStartUtc (D-064): post-restart when a restart
            -- split the window (compilation counters reset on restart), else the
            -- window start.
            ;WITH FirstRow AS
            (
                SELECT TOP (1) SnapshotUtc, CompilationsPerSec
                FROM dbo.FR_PlanCacheSummary
                WHERE SnapshotUtc >= @DeltaStartUtc AND SnapshotUtc <= @ReportEndUtc
                  AND CompilationsPerSec IS NOT NULL
                ORDER BY SnapshotUtc ASC
            ),
            LastRow AS
            (
                SELECT TOP (1) SnapshotUtc, CompilationsPerSec, AdHocSingleUsePlanCount, CachedPlanCount
                FROM dbo.FR_PlanCacheSummary
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
                  AND CompilationsPerSec IS NOT NULL
                ORDER BY SnapshotUtc DESC
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Medium', N'Medium', N'Inferred', N'PlanCache',
                N'FR_R0020_HighCompilationRate',
                N'Plan cache shows evidence consistent with high compilation pressure',
                N'Average SQL compilations per second across the window exceeded the configured threshold.',
                LEFT(CONCAT(N'approxCompilationsPerSec=',
                       CONVERT(bigint, (l.CompilationsPerSec - f.CompilationsPerSec)
                                       / NULLIF(DATEDIFF(second, f.SnapshotUtc, l.SnapshotUtc), 0)),
                       N'; threshold=', @CompilationsWarn,
                       N'; singleUseAdhocPlans=', ISNULL(l.AdHocSingleUsePlanCount, 0),
                       N'; cachedPlanCount=', ISNULL(l.CachedPlanCount, 0)), 1900),
                N'Consider reviewing ad hoc workload and parameterization only after validating the compilation rate is sustained. Do not clear the plan cache reflexively.',
                f.SnapshotUtc, l.SnapshotUtc,
                N'Rate derived from raw cumulative SQL Compilations/sec counters across the window (D-007).'
            FROM FirstRow AS f
            CROSS JOIN LastRow AS l
            WHERE DATEDIFF(second, f.SnapshotUtc, l.SnapshotUtc) > 0
              AND (l.CompilationsPerSec - f.CompilationsPerSec)
                  / NULLIF(DATEDIFF(second, f.SnapshotUtc, l.SnapshotUtc), 0) >= @CompilationsWarn;
        END;

        -- FR_R0019 QueryStoreNearingCapacity (QueryStore / Medium / High / Observed)
        -- Reads the collect-time QueryStoreCapacity step (static SQL; D-113).
        IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0019_QueryStoreNearingCapacity;', @DisabledRules) = 0
        BEGIN
            DECLARE @QsCapWarn int = 90;
            SELECT @QsCapWarn = TRY_CONVERT(int, ConfigValue)
            FROM dbo.FR_Config WHERE ConfigKey = N'QueryStoreCapacityWarnPercent';
            IF @QsCapWarn IS NULL OR @QsCapWarn < 1 SET @QsCapWarn = 90;

            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Medium', N'High', N'Observed', N'QueryStore',
                N'FR_R0019_QueryStoreNearingCapacity',
                N'Query Store shows evidence consistent with nearing storage capacity',
                N'At least one database''s Query Store storage approached its configured maximum during the window.',
                LEFT(CONCAT(N'maxUsedPct=', st.RowsCollected, N'; threshold=', @QsCapWarn,
                            N'; detail=', ISNULL(st.Reason, N'')), 1900),
                N'Consider reviewing Query Store retention and max size settings only after validating capacity pressure is sustained.',
                @ReportStartUtc, @ReportEndUtc,
                N'From FR_RunLogStep StepName=QueryStoreCapacity; RowsCollected carries the max used percent (v0.3 reuse).'
            FROM dbo.FR_RunLogStep AS st
            WHERE st.StepName = N'QueryStoreCapacity'
              AND st.StartUtc >= @ReportStartUtc AND st.StartUtc <= @ReportEndUtc
              AND st.RowsCollected IS NOT NULL
              AND st.RowsCollected >= @QsCapWarn
            ORDER BY st.RowsCollected DESC;
        END;

        -- FR_R0006 ServerRestartDuringWindow (Configuration / Critical / High /
        -- Observed — §7.9, D-064). Primary detection from the instance-snapshot
        -- start-time change computed at window setup; the error-log block below
        -- only corroborates when this did not fire. Emitted before the error-log
        -- block so its NOT EXISTS guard sees this row (no intra-rule dup).
        IF @RestartDetected = 1
           AND CHARINDEX(N';FR_R0006_ServerRestartDuringWindow;', @DisabledRules) = 0
           AND NOT EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0006_ServerRestartDuringWindow')
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            VALUES
            (
                N'Critical', N'High', N'Observed', N'Configuration',
                N'FR_R0006_ServerRestartDuringWindow',
                N'SQL Server restart detected during the window',
                N'The captured SQL Server start time changed within the report window, consistent with a restart.',
                LEFT(CONCAT(N'RestartInstanceStartUtc=', CONVERT(nvarchar(30), @RestartUtc, 126), N'Z',
                            N'; deltaAnchorUtc=', CONVERT(nvarchar(30), @DeltaStartUtc, 126), N'Z'), 1900),
                N'Cross-restart cumulative deltas are not comparable; consider analyzing the pre- and post-restart segments separately.',
                @ReportStartUtc, @ReportEndUtc,
                N'Window split at the restart boundary (D-064): delta rules anchor at the first post-restart snapshot.'
            );
        END;

        -- Graded collection-gap findings (D-066, D-104). A gap between
        -- consecutive snapshots greater than 2x the configured interval is a
        -- Coverage finding scaled by magnitude. Dedup-exempt (D-075); coexists
        -- with the FR_R0026 summary (D-104). RuleId stays FR_R0026 (the rule
        -- pack is fixed at 26; no new ID). FR_R0026 cannot be disabled (D-098).
        IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL AND @ReportSnapshotCount >= 2
        BEGIN
            DECLARE @IntervalSec int = 60;
            SELECT @IntervalSec = TRY_CONVERT(int, ConfigValue)
            FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotIntervalSeconds';
            IF @IntervalSec IS NULL OR @IntervalSec < 1 SET @IntervalSec = 60;
            DECLARE @WindowSec int = DATEDIFF(second, @ReportStartUtc, @ReportEndUtc);

            ;WITH Snaps AS
            (
                SELECT SnapshotUtc,
                       LAG(SnapshotUtc) OVER (ORDER BY SnapshotUtc) AS PrevUtc
                FROM dbo.FR_Snapshot
                WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc
            ),
            Gaps AS
            (
                SELECT PrevUtc, SnapshotUtc, DATEDIFF(second, PrevUtc, SnapshotUtc) AS GapSec
                FROM Snaps WHERE PrevUtc IS NOT NULL
            )
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                CASE WHEN GapSec > @IntervalSec * 30
                          OR (@WindowSec > 0 AND GapSec * 2 >= @WindowSec) THEN N'Critical'
                     WHEN GapSec > @IntervalSec * 5 THEN N'High'
                     ELSE N'Medium' END,
                N'High', N'Observed', N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'Collection gap in the window',
                N'A gap between consecutive snapshots exceeded twice the configured collection interval.',
                LEFT(CONCAT(N'GapSeconds=', GapSec, N'; intervalSeconds=', @IntervalSec,
                            N'; from=', CONVERT(nvarchar(30), PrevUtc, 126), N'Z',
                            N'; to=', CONVERT(nvarchar(30), SnapshotUtc, 126), N'Z'), 1900),
                N'Collection gaps reduce confidence in absence-of-findings; investigate missed snapshots (Agent job, load, or restart).',
                PrevUtc, SnapshotUtc,
                N'Per-gap coverage finding (D-066); coexists with the FR_R0026 summary (D-104), never deduped against it (D-075).'
            FROM Gaps
            WHERE GapSec > @IntervalSec * 2
            ORDER BY GapSec DESC;
        END;

        -- FR_R0006 corroboration from the error log. Emitted only if the
        -- start-time detection above did not already emit FR_R0006 (no intra-rule dup).
        IF OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL
           AND CHARINDEX(N';FR_R0006_ServerRestartDuringWindow;', @DisabledRules) = 0
           AND NOT EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0006_ServerRestartDuringWindow')
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            SELECT TOP (1)
                N'Critical', N'High', N'Observed', N'Configuration',
                N'FR_R0006_ServerRestartDuringWindow',
                N'SQL Server restart evidence in the error log',
                N'The error log contains startup messages within the window, consistent with a restart.',
                LEFT(N'Restart log line: ' + ISNULL(e.LogText, N''), 1900),
                N'Consider correlating the restart time with the incident only after validating whether the restart was expected.',
                e.LogDateUtc, e.LogDateUtc,
                N'Corroborating evidence from FR_ErrorLog (Category=Restart); independent of snapshot start-time delta.'
            FROM dbo.FR_ErrorLog AS e
            WHERE e.Category = N'Restart'
              AND e.LogDateUtc >= @ReportStartUtc AND e.LogDateUtc <= @ReportEndUtc
            ORDER BY e.LogDateUtc ASC;
        END;

        -- =====================================================================
        -- v0.3 timeline events (additive EventType/Category per D-073):
        --   ErrorLogEvent  (from FR_ErrorLog; non-'Other' categories)
        --   SchemaChange / StatsUpdate (from FR_SchemaActivity)
        -- Output remains chronological; insertion order is irrelevant (D-071).
        -- =====================================================================
        IF OBJECT_ID(N'dbo.FR_ErrorLog', N'U') IS NOT NULL
            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary, SnapshotId, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                e.LogDateUtc,
                N'ErrorLogEvent',
                CASE e.Category
                    WHEN N'IO'         THEN N'IO'
                    WHEN N'Corruption' THEN N'IO'
                    WHEN N'Failover'   THEN N'HA'
                    WHEN N'Memory'     THEN N'Memory'
                    ELSE N'Configuration'
                END,
                CASE e.Category
                    WHEN N'Corruption'   THEN N'Critical'
                    WHEN N'Failover'     THEN N'High'
                    WHEN N'IO'           THEN N'High'
                    WHEN N'Restart'      THEN N'High'
                    WHEN N'HighSeverity' THEN N'High'
                    WHEN N'Memory'       THEN N'Medium'
                    ELSE N'Low'
                END,
                LEFT(N'[' + ISNULL(e.Category, N'Other') + N'] ' + ISNULL(e.LogText, N''), 400),
                e.SnapshotId,
                LEFT(N'ProcessInfo=' + ISNULL(e.ProcessInfo, N''), 1000)
            FROM dbo.FR_ErrorLog AS e
            WHERE e.LogDateUtc >= @ReportStartUtc AND e.LogDateUtc <= @ReportEndUtc
              AND ISNULL(e.Category, N'Other') <> N'Other'
            ORDER BY e.LogDateUtc ASC;

        -- Schema-activity timeline: window-first + dedup + cap (D-199).
        -- The collector re-captures the same DDL/stats event on every snapshot
        -- inside its 7-day lookback, so an unpurged repository fed this section
        -- millions of duplicate rows through a full-table scan on ModifyDateUtc.
        -- The SnapshotUtc bounds ride the clustered index: a capture of an
        -- in-window event can only carry SnapshotUtc at/after its ModifyDateUtc
        -- (1-day clock-skew margin) and within the lookback after the window.
        IF OBJECT_ID(N'dbo.FR_SchemaActivity', N'U') IS NOT NULL
        BEGIN
            IF OBJECT_ID(N'tempdb..#fr_sa_events') IS NOT NULL DROP TABLE #fr_sa_events;
            CREATE TABLE #fr_sa_events
            (
                ActivityKind  nvarchar(30) NOT NULL,
                DatabaseName  sysname      NULL,
                SchemaName    sysname      NULL,
                ObjectName    sysname      NULL,
                StatName      sysname      NULL,
                ModifyDateUtc datetime2(3) NOT NULL,
                SnapshotId    bigint       NULL,
                RowModCount   bigint       NULL
            );

            INSERT INTO #fr_sa_events
                (ActivityKind, DatabaseName, SchemaName, ObjectName, StatName, ModifyDateUtc, SnapshotId, RowModCount)
            SELECT TOP (@MaxFindings + 1)
                a.ActivityKind, a.DatabaseName, a.SchemaName, a.ObjectName, a.StatName,
                a.ModifyDateUtc, MIN(a.SnapshotId), MAX(a.RowModCount)
            FROM dbo.FR_SchemaActivity AS a
            WHERE a.ModifyDateUtc >= @ReportStartUtc AND a.ModifyDateUtc <= @ReportEndUtc
              AND a.SnapshotUtc >= DATEADD(day, -1, @ReportStartUtc)
              AND a.SnapshotUtc <= DATEADD(day, 8, @ReportEndUtc)
            GROUP BY a.ActivityKind, a.DatabaseName, a.SchemaName, a.ObjectName, a.StatName, a.ModifyDateUtc
            ORDER BY a.ModifyDateUtc ASC;

            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary,
                DatabaseName, ObjectName, SnapshotId, MoreInfo
            )
            SELECT TOP (@MaxFindings)
                e.ModifyDateUtc,
                CASE WHEN e.ActivityKind = N'StatsUpdate' THEN N'StatsUpdate' ELSE N'SchemaChange' END,
                N'Schema',
                N'Informational',
                LEFT(CASE WHEN e.ActivityKind = N'StatsUpdate'
                          THEN N'Statistics updated: ' + ISNULL(e.SchemaName, N'') + N'.' + ISNULL(e.ObjectName, N'')
                               + N' (' + ISNULL(e.StatName, N'') + N')'
                          ELSE N'Object changed: ' + ISNULL(e.SchemaName, N'') + N'.' + ISNULL(e.ObjectName, N'')
                     END, 400),
                e.DatabaseName,
                LEFT(ISNULL(e.ObjectName, N''), 200),
                e.SnapshotId,
                LEFT(N'Kind=' + e.ActivityKind + N'; rowMod=' + ISNULL(CONVERT(nvarchar(20), e.RowModCount), N''), 1000)
            FROM #fr_sa_events AS e
            ORDER BY e.ModifyDateUtc ASC;

            IF (SELECT COUNT(1) FROM #fr_sa_events) > @MaxFindings
                INSERT INTO #fr_findings
                (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, StartTimeUtc, EndTimeUtc, MoreInfo)
                VALUES
                (
                    N'Informational', N'High', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Schema-activity timeline evidence was capped',
                    CONCAT(N'More than ', @MaxFindings, N' distinct schema/stats events fall in the window; only the earliest ', @MaxFindings, N' are shown.'),
                    N'Schema-activity timeline events are capped at @MaxFindings to keep Report bounded on large repositories.',
                    N'Narrow the report window, raise @MaxFindings (max 2000), or reduce SnapshotRetentionDays so the repository stays smaller.',
                    @ReportStartUtc, @ReportEndUtc,
                    N'Evidence cap (D-199); full detail remains in dbo.FR_SchemaActivity.'
                );

            IF OBJECT_ID(N'tempdb..#fr_sa_events') IS NOT NULL DROP TABLE #fr_sa_events;
        END;

        -- =====================================================================
        -- v0.2 timeline events (chronological; D-071/D-073 closed-set EventType).
        -- =====================================================================
        IF OBJECT_ID(N'dbo.FR_Deadlock', N'U') IS NOT NULL
            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary,
                RunId, SnapshotId, MoreInfo
            )
            SELECT
                ISNULL(DeadlockTimeUtc, SnapshotUtc), N'DeadlockObserved', N'Blocking',
                N'High', N'Deadlock graph captured.',
                NULL, SnapshotId,
                CONCAT(N'ProcessCount=', ISNULL(CONVERT(nvarchar(10), ProcessCount), N''))
            FROM dbo.FR_Deadlock
            WHERE ISNULL(DeadlockTimeUtc, SnapshotUtc) >= @ReportStartUtc
              AND ISNULL(DeadlockTimeUtc, SnapshotUtc) <= @ReportEndUtc;

        IF OBJECT_ID(N'dbo.FR_AgentJob', N'U') IS NOT NULL
            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary,
                RunId, SnapshotId, MoreInfo
            )
            SELECT
                RunStartUtc, N'AgentJobFailed', N'Maintenance', N'High',
                CONCAT(N'Agent job failed: ', JobName),
                NULL, SnapshotId, LEFT(ISNULL(MessageText, N''), 400)
            FROM dbo.FR_AgentJob
            WHERE RunOutcome = N'Failed'
              AND RunStartUtc >= DATEADD(minute, -15, @ReportStartUtc)
              AND RunStartUtc <= @ReportEndUtc;

        IF OBJECT_ID(N'dbo.FR_BackupHistory', N'U') IS NOT NULL
            INSERT INTO #fr_timeline
            (
                EventUtc, EventType, Category, Severity, Summary,
                DatabaseName, RunId, SnapshotId, MoreInfo
            )
            SELECT
                BackupStartUtc, N'BackupStarted', N'Maintenance', N'Informational',
                CONCAT(BackupType, N' backup: ', DatabaseName),
                DatabaseName, NULL, SnapshotId,
                CONCAT(N'Finish=', CONVERT(nvarchar(30), BackupFinishUtc, 126))
            FROM dbo.FR_BackupHistory
            WHERE BackupType <> N'Log'
              AND BackupStartUtc IS NOT NULL
              AND BackupStartUtc <= @ReportEndUtc
              AND ISNULL(BackupFinishUtc, BackupStartUtc) >= @ReportStartUtc;

        IF NOT EXISTS (SELECT 1 FROM #fr_findings)
        BEGIN
            INSERT INTO #fr_findings
            (
                Severity, Confidence, EvidenceType, Category, RuleId,
                Title, Summary, Evidence, Recommendation,
                StartTimeUtc, EndTimeUtc, MoreInfo
            )
            VALUES
            (
                N'Informational',
                N'High',
                N'Observed',
                N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'No findings emitted',
                N'No rule produced a finding for the selected window.',
                CONCAT(N'Snapshot count: ', @ReportSnapshotCount),
                N'If symptoms persist, consider widening the report window or collecting more snapshots.',
                @ReportStartUtc,
                @ReportEndUtc,
                N'This explicit no-findings row avoids silent output.'
            );
        END;

        -- =====================================================================
        -- FR_R0026 Coverage & Capability summary (D-098: always emits; D-075: dedup-exempt).
        -- Aggregates skipped collectors, suppressed rules, coverage, and v0.4 capability.
        -- =====================================================================
        BEGIN TRY
            DECLARE @CovSkipped nvarchar(1000) = N'';
            DECLARE @CovSuppressed nvarchar(1000) = ISNULL(
                (SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'DisabledRules'), N'');
            DECLARE @CovSnapCount int = 0;

            SELECT @CovSnapCount = COUNT(1)
            FROM dbo.FR_Snapshot
            WHERE SnapshotUtc >= @ReportStartUtc AND SnapshotUtc <= @ReportEndUtc;

            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
            SELECT @CovSkipped = STUFF((
                SELECT TOP (50) N'; ' + rs.StepName + N'(' + ISNULL(rs.Reason, N'skipped') + N')'
                FROM dbo.FR_RunLogStep AS rs
                INNER JOIN dbo.FR_RunLog AS rl ON rl.RunId = rs.RunId
                WHERE rs.Status IN (N'Skipped', N'PartialSuccess', N'Error')
                  AND rs.StartUtc >= DATEADD(hour, -24, @ReportEndUtc)
                ORDER BY rs.StartUtc DESC
                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES
            (
                N'Informational', N'High', N'Observed', N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'Coverage and capability summary',
                CONCAT(N'Window had ', @CovSnapCount, N' snapshot(s). See Evidence for coverage gaps and capability.'),
                LEFT(CONCAT(
                    N'Snapshots=', @CovSnapCount,
                    N'; SkippedOrPartial=', CASE WHEN @CovSkipped = N'' THEN N'(none in last 24h)' ELSE @CovSkipped END,
                    N'; SuppressedRules=', CASE WHEN @CovSuppressed = N'' THEN N'(none)' ELSE @CovSuppressed END), 1900),
                N'Coverage gaps reduce confidence; address skipped collectors before relying on absence of findings.',
                NULL, NULL, NULL, @ReportStartUtc, @ReportEndUtc,
                LEFT(CONCAT(
                    N'Capability: QS=', CONVERT(nvarchar(1), @HasQueryStoreSupport),
                    N'; AdvHA=', CONVERT(nvarchar(1), @HasAdvancedHaSupport),
                    N'; BufferPool=', CONVERT(nvarchar(1), @HasBufferPoolSupport),
                    N'; TimeDisplay=', CONVERT(nvarchar(1), @HasTimeZoneSupport),
                    N'; PlanAnalysis=0',
                    N'; ErrorLog=', ISNULL((SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'CollectErrorLog'), N'0')), 1000)
            );
        END TRY
        BEGIN CATCH
            -- FR_R0026 must always appear; emit a minimal row even on failure (D-098).
            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES (N'Informational', N'High', N'Observed', N'Coverage',
                    N'FR_R0026_CoverageAndCapabilitySummary',
                    N'Coverage and capability summary',
                    N'Coverage summary emitted with reduced detail.',
                    LEFT(ERROR_MESSAGE(), 1900), N'Address the error before relying on coverage completeness.',
                    NULL, NULL, NULL, @ReportStartUtc, @ReportEndUtc, N'FR_R0026 degraded.');
        END CATCH;

        -- =====================================================================
        -- v0.4 dedup + ranking (D-074 intra-category only; D-075 Coverage exempt;
        -- D-069 severity is per-rule constant; D-068 sort order preserved).
        -- Keep one row per (Category, RuleId, anchor); highest severity wins,
        -- then earliest StartTimeUtc. Coverage rows are never deduped.
        -- =====================================================================
        ;WITH ranked AS
        (
            SELECT
                f.FindingOrdinal,
                ROW_NUMBER() OVER (
                    PARTITION BY f.Category, f.RuleId,
                                 ISNULL(f.DatabaseName, N''), ISNULL(f.ObjectName, N''),
                                 ISNULL(f.SessionId, -1), ISNULL(f.AnchorKey, N'')
                    ORDER BY
                        CASE f.Severity WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                        WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END,
                        f.StartTimeUtc ASC, f.FindingOrdinal ASC
                ) AS rn
            FROM #fr_findings AS f
            WHERE f.Category <> N'Coverage'      -- D-075
        )
        DELETE f
        FROM #fr_findings AS f
        INNER JOIN ranked AS r ON r.FindingOrdinal = f.FindingOrdinal
        WHERE r.rn > 1;

        -- =====================================================================
        -- §7.13 folds: a headline finding consolidates its contributor findings
        -- (D-106: headline keeps its RuleId; contributors move to MoreInfo;
        -- disabling a contributor never disables the headline). Runs AFTER
        -- per-rule dedup and BEFORE @DatabaseName/@MinSeverity filters, the
        -- @MaxFindings cap, sort, and display-rank. Window-wide fold for the
        -- window-level headlines FR_R0007/FR_R0024 (approved Option A); exact
        -- AnchorKey fold for the query-level pair FR_R0015/FR_R0016. Disabled
        -- contributors are already absent from #fr_findings, so they are never
        -- folded or resurrected. Contributor rows are deleted only after their
        -- detail is written into the headline MoreInfo.
        -- =====================================================================

        -- Pair 1 (Blocking): FR_R0007 folds FR_R0001 + FR_R0002, window-wide.
        IF EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0007_BlockingStorm')
           AND EXISTS (SELECT 1 FROM #fr_findings
                       WHERE RuleId IN (N'FR_R0001_ActiveBlockingChain', N'FR_R0002_LongRunningOpenTransaction'))
        BEGIN
            DECLARE @Fold1Count int =
                (SELECT COUNT(1) FROM #fr_findings
                 WHERE RuleId IN (N'FR_R0001_ActiveBlockingChain', N'FR_R0002_LongRunningOpenTransaction'));
            DECLARE @Fold1Detail nvarchar(600) = N'';
            SELECT @Fold1Detail = LEFT(STUFF((
                SELECT N'; ' + c.RuleId + N'(SessionId=' + ISNULL(CONVERT(nvarchar(12), c.SessionId), N'?') + N')'
                FROM #fr_findings AS c
                WHERE c.RuleId IN (N'FR_R0001_ActiveBlockingChain', N'FR_R0002_LongRunningOpenTransaction')
                ORDER BY c.RuleId, c.SessionId
                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), 600);

            UPDATE #fr_findings
            SET MoreInfo = LEFT(ISNULL(MoreInfo, N'') +
                    N' | Folded ' + CONVERT(nvarchar(12), @Fold1Count) +
                    N' blocking contributor(s): ' + @Fold1Detail, 1000)
            WHERE RuleId = N'FR_R0007_BlockingStorm';

            DELETE FROM #fr_findings
            WHERE RuleId IN (N'FR_R0001_ActiveBlockingChain', N'FR_R0002_LongRunningOpenTransaction');
        END;

        -- Pair 2 (Memory): FR_R0024 folds FR_R0005, window-wide.
        IF EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0024_ResourceSemaphoreWaits')
           AND EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0005_MemoryGrantsPending')
        BEGIN
            DECLARE @Fold2Count int =
                (SELECT COUNT(1) FROM #fr_findings WHERE RuleId = N'FR_R0005_MemoryGrantsPending');
            DECLARE @Fold2Detail nvarchar(600) = N'';
            SELECT @Fold2Detail = LEFT(STUFF((
                SELECT N'; FR_R0005_MemoryGrantsPending(SessionId=' + ISNULL(CONVERT(nvarchar(12), c.SessionId), N'?') + N')'
                FROM #fr_findings AS c
                WHERE c.RuleId = N'FR_R0005_MemoryGrantsPending'
                ORDER BY c.SessionId
                FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), 600);

            UPDATE #fr_findings
            SET MoreInfo = LEFT(ISNULL(MoreInfo, N'') +
                    N' | Folded ' + CONVERT(nvarchar(12), @Fold2Count) +
                    N' memory contributor(s): ' + @Fold2Detail, 1000)
            WHERE RuleId = N'FR_R0024_ResourceSemaphoreWaits';

            DELETE FROM #fr_findings WHERE RuleId = N'FR_R0005_MemoryGrantsPending';
        END;

        -- Pair 3 (QueryStore): FR_R0015 folds FR_R0016 only on exact AnchorKey
        -- (same db:query). FR_R0015 is the headline (higher severity).
        IF EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0015_QueryPlanRegression')
           AND EXISTS (SELECT 1 FROM #fr_findings WHERE RuleId = N'FR_R0016_TopCpuConsumerInWindow')
        BEGIN
            UPDATE h
            SET MoreInfo = LEFT(ISNULL(h.MoreInfo, N'') +
                    N' | Folded FR_R0016_TopCpuConsumerInWindow (same query): ' + ISNULL(c.Evidence, N''), 1000)
            FROM #fr_findings AS h
            INNER JOIN #fr_findings AS c
                ON h.RuleId = N'FR_R0015_QueryPlanRegression'
               AND c.RuleId = N'FR_R0016_TopCpuConsumerInWindow'
               AND c.AnchorKey IS NOT NULL
               AND c.AnchorKey = h.AnchorKey;

            DELETE c
            FROM #fr_findings AS c
            WHERE c.RuleId = N'FR_R0016_TopCpuConsumerInWindow'
              AND c.AnchorKey IS NOT NULL
              AND EXISTS (SELECT 1 FROM #fr_findings AS h
                          WHERE h.RuleId = N'FR_R0015_QueryPlanRegression'
                            AND h.AnchorKey = c.AnchorKey);
        END;

            -- v0.4 timeline events (additive; D-073). 12-col contract unchanged.
        BEGIN TRY
            -- ConfigurationChange
            INSERT INTO #fr_timeline
            (EventUtc, EventType, Category, Severity, Summary, DatabaseName, ObjectName, SessionId, RuleId, RunId, SnapshotId, MoreInfo)
            SELECT TOP (200)
                s.SnapshotUtc, N'ConfigurationChange', N'Configuration', N'Medium',
                CONCAT(N'Setting "', c.Name, N'" changed to ', ISNULL(c.ValueText, N'(null)'), N'.'),
                NULL, c.Name, NULL, N'FR_R0021_ConfigurationChangeInWindow', NULL, c.SnapshotId,
                N'Source: FR_Configuration diff.'
            FROM dbo.FR_Configuration AS c
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = c.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND c.SnapshotUtc >= @ReportStartUtc AND c.SnapshotUtc <= @ReportEndUtc
              AND EXISTS (
                    SELECT 1 FROM dbo.FR_Configuration AS c2
                    INNER JOIN dbo.FR_Snapshot AS s2 ON s2.SnapshotId = c2.SnapshotId
                    WHERE c2.ConfigurationKind = c.ConfigurationKind AND c2.Name = c.Name
                      AND s2.SnapshotUtc < s.SnapshotUtc
                      AND s2.SnapshotUtc >= @ReportStartUtc
                      AND c2.SnapshotUtc < s.SnapshotUtc
                      AND c2.SnapshotUtc >= @ReportStartUtc
                      AND ISNULL(c2.ValueText, N'') <> ISNULL(c.ValueText, N''));

            -- LogReuseWaitChanged (perf-counter-derived growth signal)
            INSERT INTO #fr_timeline
            (EventUtc, EventType, Category, Severity, Summary, DatabaseName, ObjectName, SessionId, RuleId, RunId, SnapshotId, MoreInfo)
            SELECT TOP (200)
                s.SnapshotUtc, N'LogReuseWaitChanged', N'IO', N'High',
                N'Transaction log growth/usage signal changed.',
                NULL, RTRIM(p.CounterName), NULL, N'FR_R0022_LogReuseWaitElevated', NULL, p.SnapshotId,
                CONCAT(N'Counter=', RTRIM(p.CounterName), N'; Value=', CONVERT(nvarchar(40), p.CounterValue))
            FROM dbo.FR_PerfCounter AS p
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = p.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND p.SnapshotUtc >= @ReportStartUtc AND p.SnapshotUtc <= @ReportEndUtc
              AND RTRIM(p.CounterName) = N'Log Growths'
              AND p.CounterValue > 0;

            -- AvailabilityStateChanged (advanced HA)
            IF OBJECT_ID(N'dbo.FR_HaState', N'U') IS NOT NULL
            INSERT INTO #fr_timeline
            (EventUtc, EventType, Category, Severity, Summary, DatabaseName, ObjectName, SessionId, RuleId, RunId, SnapshotId, MoreInfo)
            SELECT TOP (200)
                s.SnapshotUtc, N'AvailabilityStateChanged', N'HA',
                CASE WHEN h.SynchronizationHealthDesc = N'NOT_HEALTHY' THEN N'Critical'
                     WHEN h.SynchronizationHealthDesc = N'PARTIALLY_HEALTHY' THEN N'High'
                     ELSE N'Informational' END,
                CONCAT(N'AG "', ISNULL(h.AgName, N'?'), N'" replica ', ISNULL(h.ReplicaServer, N'?'),
                       N' health=', ISNULL(h.SynchronizationHealthDesc, N'?'), N'.'),
                h.DatabaseName, h.ReplicaServer, NULL, N'FR_R0014_AlwaysOnRoleOrStateChange', NULL, h.SnapshotId,
                CONCAT(N'Role=', ISNULL(h.RoleDesc, N'?'), N'; RedoQueueKb=', ISNULL(CONVERT(nvarchar(20), h.RedoQueueKb), N''))
            FROM dbo.FR_HaState AS h
            INNER JOIN dbo.FR_Snapshot AS s ON s.SnapshotId = h.SnapshotId
            WHERE s.SnapshotUtc >= @ReportStartUtc AND s.SnapshotUtc <= @ReportEndUtc
              AND h.SnapshotUtc >= @ReportStartUtc AND h.SnapshotUtc <= @ReportEndUtc
              AND h.SynchronizationHealthDesc IN (N'NOT_HEALTHY', N'PARTIALLY_HEALTHY');
        END TRY
        BEGIN CATCH
            -- Timeline enrichment failure must not fail Report (empty timeline allowed, D-078).
            SET @CollectError = NULL;  -- no-op; swallow
        END CATCH;


        -- @DatabaseName scope: drop DB-bound rows for other databases; keep
        -- instance-level/coverage rows (DatabaseName IS NULL).
        IF @DatabaseName IS NOT NULL
        BEGIN
            DELETE FROM #fr_findings
            WHERE DatabaseName IS NOT NULL AND DatabaseName <> @DatabaseName;
            DELETE FROM #fr_timeline
            WHERE DatabaseName IS NOT NULL AND DatabaseName <> @DatabaseName;
        END;

        -- @MinSeverity post-evaluation filter (D-070). Critical and Coverage are
        -- never hidden (D-083). Findings only; Timeline stays chronological.
        DELETE FROM #fr_findings
        WHERE Severity <> N'Critical'
          AND Category <> N'Coverage'
          AND CASE Severity
                  WHEN N'Informational' THEN 1 WHEN N'Low' THEN 2
                  WHEN N'Medium' THEN 3 WHEN N'High' THEN 4
                  WHEN N'Critical' THEN 5 ELSE 1 END
            < CASE UPPER(@MinSeverity)
                  WHEN N'INFORMATIONAL' THEN 1 WHEN N'LOW' THEN 2
                  WHEN N'MEDIUM' THEN 3 WHEN N'HIGH' THEN 4
                  WHEN N'CRITICAL' THEN 5 ELSE 2 END;

        -- =====================================================================
        -- @MaxFindings final-output enforcement + overflow finding (D-087).
        -- Applied after dedup/fold and the @MinSeverity filter, before output.
        -- Critical and Coverage rows are never truncated (D-070/D-083); one
        -- Informational Coverage row records the truncation. The lowest-ranked
        -- non-protected rows (by the D-068 order) are dropped first.
        -- =====================================================================
        DECLARE @FindingTotal int = (SELECT COUNT(1) FROM #fr_findings);
        IF @FindingTotal > @MaxFindings
        BEGIN
            DECLARE @ProtectedCount int =
                (SELECT COUNT(1) FROM #fr_findings
                 WHERE Severity = N'Critical' OR Category = N'Coverage');
            -- Reserve one slot for the overflow row itself.
            DECLARE @NonProtectedBudget int = @MaxFindings - @ProtectedCount - 1;
            IF @NonProtectedBudget < 0 SET @NonProtectedBudget = 0;

            ;WITH rankable AS
            (
                SELECT f.FindingOrdinal,
                    ROW_NUMBER() OVER (
                        ORDER BY
                            CASE f.Severity WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                            WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END,
                            CASE f.Confidence WHEN N'High' THEN 1 WHEN N'Medium' THEN 2
                                              WHEN N'Low' THEN 3 ELSE 4 END,
                            CASE f.EvidenceType WHEN N'Observed' THEN 1 WHEN N'Inferred' THEN 2 ELSE 3 END,
                            f.StartTimeUtc ASC, f.RuleId ASC, f.FindingOrdinal ASC
                    ) AS rnk
                FROM #fr_findings AS f
                WHERE f.Severity <> N'Critical' AND f.Category <> N'Coverage'
            )
            DELETE f
            FROM #fr_findings AS f
            INNER JOIN rankable AS r ON r.FindingOrdinal = f.FindingOrdinal
            WHERE r.rnk > @NonProtectedBudget;

            INSERT INTO #fr_findings
            (Severity, Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence, Recommendation, StartTimeUtc, EndTimeUtc, MoreInfo)
            VALUES
            (
                N'Informational', N'High', N'Observed', N'Coverage',
                N'FR_R0026_CoverageAndCapabilitySummary',
                N'Findings truncated to the @MaxFindings cap',
                CONCAT(N'The report produced ', @FindingTotal, N' findings; output was capped at ', @MaxFindings, N'.'),
                LEFT(CONCAT(N'TotalFindings=', @FindingTotal, N'; MaxFindings=', @MaxFindings,
                            N'; Critical and Coverage findings are never truncated (D-070/D-083).'), 1900),
                N'Raise @MaxFindings (max 2000), narrow the time window, or raise @MinSeverity to focus on higher-severity findings.',
                @ReportStartUtc, @ReportEndUtc,
                N'Overflow truncation per D-087.'
            );
        END;

        IF UPPER(@OutputFormat) = N'MARKDOWN'
        BEGIN
            DECLARE @ReportMarkdown nvarchar(max) = N'';

            -- D-085: the machine-parseable header block is a public contract
            -- of exactly these 14 keys, in this order. Counts are computed
            -- after filtering so they describe the emitted report.
            -- Report-Run-Id and Report-Generated-Utc vary per run by nature;
            -- golden-output tests must mask those two lines (D-122).
            DECLARE @MdFindingCount  int = 0;
            DECLARE @MdCoverageCount int = 0;
            DECLARE @MdTimelineCount int = 0;
            SELECT @MdFindingCount  = COUNT(*) FROM #fr_findings;
            SELECT @MdCoverageCount = COUNT(*) FROM #fr_findings WHERE Category = N'Coverage';
            SELECT @MdTimelineCount = COUNT(*) FROM #fr_timeline;

            SET @ReportMarkdown =
                N'# SQL Server Flight Recorder Report' + CHAR(13) + CHAR(10) +
                N'Tool-Version: ' + @ToolVersion + CHAR(13) + CHAR(10) +
                N'Schema-Version: ' + @SchemaVersion + CHAR(13) + CHAR(10) +
                N'Rule-Pack-Version: ' + @RulePackVersion + CHAR(13) + CHAR(10) +
                N'Report-Run-Id: ' + CONVERT(nvarchar(36), NEWID()) + CHAR(13) + CHAR(10) +
                N'Report-Generated-Utc: ' + CONVERT(nvarchar(30), SYSUTCDATETIME(), 126) + N'Z' + CHAR(13) + CHAR(10) +
                N'Window-Start-Utc: ' + CONVERT(nvarchar(30), @ReportStartUtc, 126) + N'Z' + CHAR(13) + CHAR(10) +
                N'Window-End-Utc: ' + CONVERT(nvarchar(30), @ReportEndUtc, 126) + N'Z' + CHAR(13) + CHAR(10) +
                N'Instance-Fingerprint: ' + ISNULL(CONVERT(nvarchar(200), SERVERPROPERTY(N'ServerName')), N'') + CHAR(13) + CHAR(10) +
                N'Database-Filter: ' + ISNULL(@DatabaseName, N'(all databases)') + CHAR(13) + CHAR(10) +
                N'Min-Severity: ' + @MinSeverity + CHAR(13) + CHAR(10) +
                N'Snapshot-Count: ' + CONVERT(nvarchar(20), @ReportSnapshotCount) + CHAR(13) + CHAR(10) +
                N'Coverage-Warning-Count: ' + CONVERT(nvarchar(20), @MdCoverageCount) + CHAR(13) + CHAR(10) +
                N'Finding-Count: ' + CONVERT(nvarchar(20), @MdFindingCount) + CHAR(13) + CHAR(10) +
                N'Timeline-Event-Count: ' + CONVERT(nvarchar(20), @MdTimelineCount) + CHAR(13) + CHAR(10) +
                CHAR(13) + CHAR(10) +
                N'## Findings' + CHAR(13) + CHAR(10);



            -- Same deterministic order as the result-set output (D-068).
            SELECT @ReportMarkdown = @ReportMarkdown +
                N'- **' + Severity + N'** [' + RuleId + N'] ' + Title + N': ' + Summary + CHAR(13) + CHAR(10)
            FROM #fr_findings
            ORDER BY
                CASE Severity WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END,
                CASE Confidence WHEN N'High' THEN 1 WHEN N'Medium' THEN 2
                                WHEN N'Low' THEN 3 ELSE 4 END,
                CASE EvidenceType WHEN N'Observed' THEN 1 WHEN N'Inferred' THEN 2 ELSE 3 END,
                StartTimeUtc ASC, RuleId ASC, FindingOrdinal ASC;

            SET @ReportMarkdown = @ReportMarkdown + CHAR(13) + CHAR(10) + N'## Timeline' + CHAR(13) + CHAR(10);

            SELECT @ReportMarkdown = @ReportMarkdown +
                N'- ' + CONVERT(nvarchar(50), EventUtc, 126) + N'Z — ' + EventType + N': ' + Summary + CHAR(13) + CHAR(10)
            FROM #fr_timeline
            ORDER BY EventUtc, EventType, SnapshotId;

            -- v0.4 Markdown enrichment (human-readable context; additive to
            -- the D-085 header block emitted above).
            DECLARE @MdWindowStart nvarchar(40);
            DECLARE @MdWindowEnd   nvarchar(40);

            IF @TzMode = N'LOCAL' AND @HasTimeZoneSupport = 1 AND @TzName IS NOT NULL
            BEGIN
                DECLARE @MdTzSql nvarchar(max) = N'
                    SELECT @s = CONVERT(nvarchar(30), @su AT TIME ZONE N''UTC'' AT TIME ZONE @tz, 120),
                           @e = CONVERT(nvarchar(30), @eu AT TIME ZONE N''UTC'' AT TIME ZONE @tz, 120);';
                BEGIN TRY
                    EXEC sys.sp_executesql @MdTzSql,
                         N'@su datetime2(3), @eu datetime2(3), @tz sysname, @s nvarchar(40) OUTPUT, @e nvarchar(40) OUTPUT',
                         @su = @ReportStartUtc, @eu = @ReportEndUtc, @tz = @TzName,
                         @s = @MdWindowStart OUTPUT, @e = @MdWindowEnd OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @MdWindowStart = NULL; SET @MdWindowEnd = NULL;   -- fall back to UTC below
                END CATCH;
            END;

            IF @MdWindowStart IS NULL SET @MdWindowStart = CONVERT(nvarchar(30), @ReportStartUtc, 126) + N'Z';
            IF @MdWindowEnd   IS NULL SET @MdWindowEnd   = CONVERT(nvarchar(30), @ReportEndUtc, 126) + N'Z';

            SET @ReportMarkdown = @ReportMarkdown + NCHAR(13) + NCHAR(10) +
                N'## Report Context' + NCHAR(13) + NCHAR(10) +
                N'- Tool / Schema: ' + @ToolVersion + N' / ' + @SchemaVersion + NCHAR(13) + NCHAR(10) +
                N'- Window (' + CASE WHEN @TzMode = N'LOCAL' AND @HasTimeZoneSupport = 1
                                     THEN N'local: ' + ISNULL(@TzName, N'server') ELSE N'UTC' END + N'): '
                    + @MdWindowStart + N' → ' + @MdWindowEnd + NCHAR(13) + NCHAR(10) +
                N'- Database filter: ' + ISNULL(@DatabaseName, N'(all databases)') + NCHAR(13) + NCHAR(10) +
                N'- Snapshots in window: ' + CONVERT(nvarchar(10), @ReportSnapshotCount) + NCHAR(13) + NCHAR(10) +
                N'- Min severity: ' + @MinSeverity + N'  |  Max findings: ' + CONVERT(nvarchar(10), @MaxFindings) + NCHAR(13) + NCHAR(10) +
                N'- Capability: QS=' + CONVERT(nvarchar(1), @HasQueryStoreSupport)
                    + N' AdvHA=' + CONVERT(nvarchar(1), @HasAdvancedHaSupport)
                    + N' BufferPool=' + CONVERT(nvarchar(1), @HasBufferPoolSupport)
                    + N' TimeDisplay=' + CONVERT(nvarchar(1), @HasTimeZoneSupport) + NCHAR(13) + NCHAR(10);
            -- v0.4 Markdown recommendation summary (counts by severity; honest, bounded).
            SET @ReportMarkdown = @ReportMarkdown + NCHAR(13) + NCHAR(10) +
                N'## Recommendation Summary' + NCHAR(13) + NCHAR(10) +
                ISNULL((
                    SELECT
                        N'- Critical: ' + CONVERT(nvarchar(10), SUM(CASE WHEN Severity = N'Critical' THEN 1 ELSE 0 END)) + NCHAR(13) + NCHAR(10) +
                        N'- High: '     + CONVERT(nvarchar(10), SUM(CASE WHEN Severity = N'High' THEN 1 ELSE 0 END)) + NCHAR(13) + NCHAR(10) +
                        N'- Medium: '   + CONVERT(nvarchar(10), SUM(CASE WHEN Severity = N'Medium' THEN 1 ELSE 0 END)) + NCHAR(13) + NCHAR(10) +
                        N'- Low/Info: ' + CONVERT(nvarchar(10), SUM(CASE WHEN Severity IN (N'Low', N'Informational') THEN 1 ELSE 0 END)) + NCHAR(13) + NCHAR(10)
                    FROM #fr_findings
                ), N'- (no findings)' + NCHAR(13) + NCHAR(10)) +
                N'> Findings are evidence-based and do not constitute automated remediation. ' +
                N'Validate against the incident window before acting.' + NCHAR(13) + NCHAR(10);

            SELECT @ReportMarkdown AS Report;
            RETURN;
        END;

        IF UPPER(@OutputFormat) IN (N'DEFAULT', N'FINDINGSONLY')
        BEGIN
            -- Deterministic order (D-068): Severity -> Confidence -> EvidenceType
            -- -> StartTimeUtc -> RuleId, with the internal FindingOrdinal as the
            -- final total-order tie-break. FindingOrdinal is re-sequenced as the
            -- display rank so the output reads 1..N top-to-bottom; the 16-column
            -- contract (D-067) is unchanged.
            SELECT
                  ROW_NUMBER() OVER (
                      ORDER BY
                          CASE Severity WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                                        WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END,
                          CASE Confidence WHEN N'High' THEN 1 WHEN N'Medium' THEN 2
                                          WHEN N'Low' THEN 3 ELSE 4 END,
                          CASE EvidenceType WHEN N'Observed' THEN 1 WHEN N'Inferred' THEN 2 ELSE 3 END,
                          StartTimeUtc ASC, RuleId ASC, FindingOrdinal ASC
                  ) AS FindingOrdinal
                , Severity
                , Confidence
                , EvidenceType
                , Category
                , RuleId
                , Title
                , Summary
                , Evidence
                , Recommendation
                , DatabaseName
                , ObjectName
                , SessionId
                , StartTimeUtc
                , EndTimeUtc
                , MoreInfo
            FROM #fr_findings
            ORDER BY
                CASE Severity WHEN N'Critical' THEN 1 WHEN N'High' THEN 2
                              WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END,
                CASE Confidence WHEN N'High' THEN 1 WHEN N'Medium' THEN 2
                                WHEN N'Low' THEN 3 ELSE 4 END,
                CASE EvidenceType WHEN N'Observed' THEN 1 WHEN N'Inferred' THEN 2 ELSE 3 END,
                StartTimeUtc ASC, RuleId ASC, FindingOrdinal ASC;
        END;

        IF UPPER(@OutputFormat) IN (N'DEFAULT', N'TIMELINEONLY')
        BEGIN
            SELECT
                  EventUtc
                , EventType
                , Category
                , Severity
                , Summary
                , DatabaseName
                , ObjectName
                , SessionId
                , RuleId
                , RunId
                , SnapshotId
                , MoreInfo
            FROM #fr_timeline
            ORDER BY EventUtc, EventType, SnapshotId;
        END;

        RETURN;
    END;

    -- =========================================================================
    -- Defensive default (unreachable in normal operation). Every documented mode
    -- has a handler above that RETURNs, and the closed-set @Mode validation near
    -- the top of the procedure rejects anything else. Reaching here would mean a
    -- mode passed validation but lost its handler — an internal inconsistency.
    -- =========================================================================
    SELECT
        N'Error' AS Status,
        N'UnhandledMode' AS ErrorCode,
        CONCAT(N'Internal: mode ''', @ModeNormalized, N''' passed validation but has no handler. Please report this.') AS Message,
        @ToolVersion AS ToolVersion;

END;
GO
