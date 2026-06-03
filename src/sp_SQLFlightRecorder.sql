-- =============================================================================
-- sp_SQLFlightRecorder
-- SQL Server DBA Flight Recorder — Part 3 (Install, Uninstall, Status modes)
-- =============================================================================
-- A single pure-T-SQL stored procedure that captures SQL Server diagnostic
-- data on a schedule and produces prioritized findings about server health.
--
-- Part 3 scope (v0.1.0-alpha.3):
--   * Install mode: idempotent repository schema creation
--   * Uninstall mode: clean removal with optional archive
--   * Status mode: six result sets (config, rules, runs, footprint, etc.)
--   * Help mode: usage and parameter documentation
--   * About mode: version metadata
--   * All other modes: "not yet implemented" stubs
--
-- Tool-Version:   0.1.0-alpha.3
-- Build-Date-Utc: 2026-06-03
-- License:        MIT
-- Repository:     https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder
-- Design:         docs/design.md | Decisions: docs/decisions.md
--
-- SQL Server 2012–2025 compatible. Single file, no preprocessor.
-- Capability probe (D-008, D-127) and sp_executesql discipline (D-112)
-- enable single-source-of-truth deployment across all versions.
--
-- Default @Mode='Help' (D-003): safe to execute accidentally.
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
    DECLARE @ToolVersion             nvarchar(30)  = N'0.1.0-alpha.3';
    DECLARE @BuildDateUtc            datetime2(3)  = CONVERT(datetime2(3), '2026-06-03T00:00:00');
    DECLARE @SchemaVersion            nvarchar(20) = N'0.1.0-alpha.3';
    DECLARE @SupportedSqlServerRange nvarchar(50)  = N'SQL Server 2012–2025';
    DECLARE @PartNumber              int           = 3;
    DECLARE @PartTotal               int           = 9;

    -- =========================================================================
    -- Input normalization and validation
    -- =========================================================================
    DECLARE @ModeNormalized nvarchar(30) = LTRIM(RTRIM(ISNULL(@Mode, N'Help')));

    -- Alias 'Version' → 'About'
    IF UPPER(@ModeNormalized) = N'VERSION'
        SET @ModeNormalized = N'About';

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
        PRINT N'  Collect           Not yet implemented (Part 4–5).';
        PRINT N'  Report            Not yet implemented (Part 6).';
        PRINT N'  Configure, Purge  Not yet implemented (Part 8).';
        PRINT N'';
        PRINT N'PARAMETERS';
        PRINT N'----------';
        PRINT N'  @Mode             Which mode to run (default: Help).';
        PRINT N'  @MinSeverity      Report filter: Informational, Low, Medium, High, Critical (default: Low).';
        PRINT N'  @MaxFindings      Cap findings at 10–2000 rows (default: 200).';
        PRINT N'  @TopN             Collector-side row cap per category (default: 50).';
        PRINT N'  @OutputFormat     Default, FindingsOnly, TimelineOnly, or Markdown (default: Default).';
        PRINT N'  @WhatIf           Preview without executing (Uninstall, Purge modes).';
        PRINT N'  @PreserveRunLog   Uninstall: 1=archive FR_RunLog with timestamped name (default: 0).';
        PRINT N'  @Debug            Print dynamic SQL without executing (default: 0).';
        PRINT N'';
        PRINT N'CHARTER PILLARS';
        PRINT N'---------------';
        PRINT N'  * Boring, transparent, deterministic behavior.';
        PRINT N'  * Honest: every finding has Severity, Confidence, EvidenceType.';
        PRINT N'  * Safe on production: bounded reads, no plan shredding, READ UNCOMMITTED.';
        PRINT N'  * Compatible: SQL Server 2012–2025 (capability-driven branching, no string parsing).';
        PRINT N'  * Open source first: GitHub-native, DBA-friendly contribution model.';
        PRINT N'';
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

            SELECT
                N'Success' AS Status,
                DB_NAME() AS DatabaseName,
                @SchemaVersion AS SchemaVersion,
                12 AS TableCount,
                N'Installation complete. 12 core FR_* tables created.' AS Message;
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
        -- Check for in-progress Collect
        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.FR_RunLog WHERE Mode = N'Collect' AND Status = N'InProgress')
        BEGIN
            SELECT N'Error' AS Status, N'CollectInProgress' AS ErrorCode,
                N'Collect is in progress. Retry uninstall later.' AS Message,
                @ToolVersion AS ToolVersion;
            RETURN;
        END;

        IF @WhatIf = 1
        BEGIN
            SELECT
                N'WhatIf' AS Status,
                N'TABLE' AS ObjectType,
                N'dbo' AS SchemaName,
                ObjectName,
                CASE WHEN @PreserveRunLog = 1 AND ObjectName IN (N'FR_RunLog', N'FR_RunLogStep')
                     THEN N'Rename' ELSE N'Drop' END AS Action
            FROM (
                SELECT N'FR_InstanceSnapshot' AS ObjectName
                UNION ALL SELECT N'FR_Configuration'
                UNION ALL SELECT N'FR_Request'
                UNION ALL SELECT N'FR_Wait'
                UNION ALL SELECT N'FR_FileStat'
                UNION ALL SELECT N'FR_PerfCounter'
                UNION ALL SELECT N'FR_QueryText'
                UNION ALL SELECT N'FR_Snapshot'
                UNION ALL SELECT N'FR_RunLogStep'
                UNION ALL SELECT N'FR_RunLog'
                UNION ALL SELECT N'FR_Rules'
                UNION ALL SELECT N'FR_Config'
            ) AS Objects
            WHERE OBJECT_ID(CONCAT(N'dbo.', ObjectName), N'U') IS NOT NULL
            ORDER BY ObjectName;
            RETURN;
        END;

        BEGIN TRY
            -- Archive run log if requested (D-183)
            IF @PreserveRunLog = 1
            BEGIN
                DECLARE @ArchiveSuffix nvarchar(32) = CONCAT(
                    CONVERT(nvarchar(8), SYSUTCDATETIME(), 112), N'_',
                    REPLACE(CONVERT(nvarchar(8), SYSUTCDATETIME(), 108), N':', N'')
                );

                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                    EXEC sys.sp_executesql
                        CONCAT(N'EXEC sp_rename N''dbo.FR_RunLog'', N''FR_RunLog_Archive_', @ArchiveSuffix, N'''');

                IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
                    EXEC sys.sp_executesql
                        CONCAT(N'EXEC sp_rename N''dbo.FR_RunLogStep'', N''FR_RunLogStep_Archive_', @ArchiveSuffix, N'''');
            END
            ELSE
            BEGIN
                IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
                    DROP TABLE dbo.FR_RunLogStep;
                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                    DROP TABLE dbo.FR_RunLog;
            END;

            -- Drop remaining tables in dependency order (D-141)
            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL
                DROP TABLE dbo.FR_InstanceSnapshot;
            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Configuration;
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Request;
            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Wait;
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
                DROP TABLE dbo.FR_FileStat;
            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL
                DROP TABLE dbo.FR_PerfCounter;
            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL
                DROP TABLE dbo.FR_QueryText;
            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Snapshot;
            IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Rules;
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
                DROP TABLE dbo.FR_Config;

            SELECT
                N'Success' AS Status,
                DB_NAME() AS DatabaseName,
                N'Uninstall completed. All FR_* tables removed.' AS Message;
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
    -- Mode: STATUS (6 result sets per Part 3 spec)
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'STATUS'
    BEGIN
        -- Result Set 1: Configuration
        SELECT
            ConfigKey,
            ConfigValue,
            Description
        FROM dbo.FR_Config
        WHERE OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
        ORDER BY ConfigKey;

        -- Result Set 2: Rules Catalog
        SELECT
            RuleId,
            Category,
            Severity,
            Confidence,
            EvidenceType,
            LifecycleState,
            ShortDescription,
            IntroducedInVersion
        FROM dbo.FR_Rules
        WHERE OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL
        ORDER BY RuleId;

        -- Result Set 3: Recent Runs
        SELECT TOP (10)
            RunId,
            StartUtc,
            EndUtc,
            Mode,
            Status,
            Reason
        FROM dbo.FR_RunLog
        WHERE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        ORDER BY RunId DESC;

        -- Result Set 4: Repository Size (D-137: bounded query on allow-listed DMVs)
        SELECT
            t.name AS TableName,
            SUM(ps.row_count) AS RowCount,
            SUM(ps.used_page_count) * 8 AS UsedKb
        FROM sys.tables t
        INNER JOIN sys.dm_db_partition_stats ps ON t.object_id = ps.object_id
        WHERE t.schema_id = SCHEMA_ID(N'dbo')
          AND t.name LIKE N'FR\_%' ESCAPE N'\'
          AND OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
        GROUP BY t.name
        ORDER BY t.name;

        -- Result Set 5: Run-Log Summary
        SELECT
            N'Total Runs' AS Metric,
            CAST(COUNT(*) AS nvarchar(20)) AS Value
        FROM dbo.FR_RunLog
        WHERE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        UNION ALL
        SELECT N'Last Run', CONVERT(nvarchar(50), MAX(StartUtc), 126) + N'Z'
        FROM dbo.FR_RunLog
        WHERE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL;

        -- Result Set 6: Capability Placeholder (populated by Part 4 capability probe)
        SELECT
            N'Tool-Version' AS CapabilityKey,
            @ToolVersion AS CapabilityValue
        UNION ALL
        SELECT N'Part-Number', CAST(@PartNumber AS nvarchar(10))
        UNION ALL
        SELECT N'Schema-Version', @SchemaVersion;

        RETURN;
    END;

    -- =========================================================================
    -- Stubs: Modes not yet implemented
    -- =========================================================================
    SELECT
        N'NotYetImplemented' AS Status,
        CONCAT(@ModeNormalized, N' mode arrives in Part 4–8 (see docs/implementation-plan.md).') AS Message,
        @ToolVersion AS ToolVersion;

END;
GO
