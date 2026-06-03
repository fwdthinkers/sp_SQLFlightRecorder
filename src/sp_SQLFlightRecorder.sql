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
  , @ConfigKey            sysname        = NULL
  , @ConfigValue          nvarchar(4000) = NULL
  , @CreateAgentJob       bit            = 0
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
        PRINT N'  Collect           Capture one diagnostic snapshot into FR_* tables.';
        PRINT N'  CollectDebug      Validate collector readiness without writing collector rows.';
        PRINT N'  Report            Read FR_* tables and return Findings + Timeline.';
        PRINT N'  Configure         Read or update known FR_Config keys.';
        PRINT N'  Purge             Batched retention cleanup. Supports @WhatIf.';
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

            -- Optional SQL Agent job creation. Explicit opt-in only.
            IF @CreateAgentJob = 1
            BEGIN
                DECLARE @AgentJobName sysname = N'SQLFlightRecorder Collect';
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
                        VALUES (N'AgentJobCreatedBySQLFlightRecorder', N'0', N'SQL Agent unavailable or unsupported.');
                END;
                ELSE
                BEGIN
                    SET @AgentSql = N'
USE msdb;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N''SQLFlightRecorder Collect'')
BEGIN
    EXEC msdb.dbo.sp_add_job
          @job_name = N''SQLFlightRecorder Collect''
        , @enabled = 1
        , @description = N''Runs dbo.sp_SQLFlightRecorder @Mode = Collect every minute.'';

    EXEC msdb.dbo.sp_add_jobstep
          @job_name = N''SQLFlightRecorder Collect''
        , @step_name = N''Collect''
        , @subsystem = N''TSQL''
        , @database_name = N''' + REPLACE(DB_NAME(), N'''', N'''''') + N'''
        , @command = N''EXEC dbo.sp_SQLFlightRecorder @Mode = N''''Collect'''';'';

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

    EXEC msdb.dbo.sp_attach_schedule
          @job_name = N''SQLFlightRecorder Collect''
        , @schedule_name = N''SQLFlightRecorder Every Minute'';

    EXEC msdb.dbo.sp_add_jobserver
          @job_name = N''SQLFlightRecorder Collect'';
END;
';
                    EXEC sys.sp_executesql @AgentSql;

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobName')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'AgentJobName', @AgentJobName, N'SQL Agent job created by Install opt-in.');

                    IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder')
                        INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description)
                        VALUES (N'AgentJobCreatedBySQLFlightRecorder', N'1', N'This procedure created the SQL Agent job.');
                END;
            END;
			
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

            UNION ALL

            SELECT
                N'WhatIf',
                N'SQL_AGENT_JOB',
                N'msdb',
                ConfigValue,
                N'Drop'
            FROM dbo.FR_Config
            WHERE OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
              AND ConfigKey = N'AgentJobName'
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.FR_Config AS c2
                  WHERE c2.ConfigKey = N'AgentJobCreatedBySQLFlightRecorder'
                    AND c2.ConfigValue = N'1'
              );

            RETURN;
        END;

        BEGIN TRY
            -- Remove SQL Agent job only if this procedure created it.
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
            BEGIN
                DECLARE @UninstallAgentJobName sysname = NULL;
                DECLARE @UninstallAgentCreated nvarchar(10) = NULL;
                DECLARE @UninstallAgentSql nvarchar(max);

                SELECT @UninstallAgentJobName = TRY_CONVERT(sysname, ConfigValue)
                FROM dbo.FR_Config
                WHERE ConfigKey = N'AgentJobName';

                SELECT @UninstallAgentCreated = ConfigValue
                FROM dbo.FR_Config
                WHERE ConfigKey = N'AgentJobCreatedBySQLFlightRecorder';

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
            END;

            -- Snapshot children first.
            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL DROP TABLE dbo.FR_InstanceSnapshot;
            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL DROP TABLE dbo.FR_Configuration;
            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL DROP TABLE dbo.FR_Request;
            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL DROP TABLE dbo.FR_Wait;
            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL DROP TABLE dbo.FR_FileStat;
            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL DROP TABLE dbo.FR_PerfCounter;

            -- Independent / parent tables.
            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL DROP TABLE dbo.FR_QueryText;
            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL DROP TABLE dbo.FR_Snapshot;

            -- Run log archive or removal after FR_Snapshot is gone.
            IF @PreserveRunLog = 1
            BEGIN
                DECLARE @UninstallArchiveSuffix nvarchar(32) = CONCAT(
                    CONVERT(nvarchar(8), SYSUTCDATETIME(), 112), N'_',
                    REPLACE(CONVERT(nvarchar(8), SYSUTCDATETIME(), 108), N':', N'')
                );

                IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
                    EXEC sys.sp_rename
                          @objname = N'dbo.FR_RunLogStep'
                        , @newname = CONCAT(N'FR_RunLogStep_Archive_', @UninstallArchiveSuffix)
                        , @objtype = N'OBJECT';

                IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
                    EXEC sys.sp_rename
                          @objname = N'dbo.FR_RunLog'
                        , @newname = CONCAT(N'FR_RunLog_Archive_', @UninstallArchiveSuffix)
                        , @objtype = N'OBJECT';
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

        -- Result Set 1: Installation summary
        SELECT
              DB_NAME() AS DatabaseName
            , CASE WHEN @StatusIsInstalled = 1 THEN N'Installed' ELSE N'NotInstalled' END AS InstallStatus
            , @SchemaVersion AS ProcedureSchemaVersion
            , CASE WHEN @StatusIsInstalled = 1
                   THEN (SELECT ConfigValue FROM dbo.FR_Config WHERE ConfigKey = N'SchemaVersion')
                   ELSE NULL
              END AS RepositorySchemaVersion
            , @ToolVersion AS ToolVersion;

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
                , SUM(ps.row_count) AS RowCount
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
                , CAST(NULL AS bigint) AS RowCount
                , CAST(NULL AS bigint) AS UsedKb
            WHERE 1 = 0;
        END;

        -- Result Set 6: Capability placeholder
        SELECT
              N'Tool-Version' AS CapabilityKey
            , @ToolVersion AS CapabilityValue
        UNION ALL
        SELECT N'Part-Number', CAST(@PartNumber AS nvarchar(10))
        UNION ALL
        SELECT N'Schema-Version', @SchemaVersion
        UNION ALL
        SELECT N'Installed', CASE WHEN @StatusIsInstalled = 1 THEN N'1' ELSE N'0' END;

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

        IF @ConfigureKey IN (N'SnapshotIntervalSeconds', N'SnapshotRetentionDays', N'RunLogRetentionDays', N'MaxRowsPerCollector')
           AND TRY_CONVERT(int, @ConfigValue) IS NULL
        BEGIN
            SELECT N'Error' AS Status, N'InvalidConfigValue' AS ErrorCode,
                CONCAT(N'Config key ', @ConfigureKey, N' requires an integer value.') AS Message,
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
                StartUtc, EndUtc, Mode, Status, Reason, LoginName, HostName
            )
            VALUES
            (
                @CollectSnapshotUtc, NULL, N'Collect', N'InProgress',
                N'Collect started.',
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
                        NULL,
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
                        NULL,
                        NULL,
                        NULL,
                        NULL,
                        NULL
                    FROM sys.dm_exec_requests AS r
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

        DECLARE @PurgeSnapshotRetentionDays int = 7;
        DECLARE @PurgeRunLogRetentionDays int = 28;
        DECLARE @PurgeSnapshotCutoffUtc datetime2(3);
        DECLARE @PurgeRunLogCutoffUtc datetime2(3);
        DECLARE @PurgeRows int = 0;
        DECLARE @PurgeTotalRows int = 0;

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
            SELECT N'FR_RunLog', COUNT(1)
            FROM dbo.FR_RunLog
            WHERE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
              AND StartUtc < @PurgeRunLogCutoffUtc;

            RETURN;
        END;

        WHILE OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_InstanceSnapshot WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_Configuration WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_Request WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_Wait WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_FileStat WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_PerfCounter WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        WHILE OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_Snapshot WHERE SnapshotUtc < @PurgeSnapshotCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

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

        WHILE OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        BEGIN
            DELETE TOP (5000) FROM dbo.FR_RunLog WHERE StartUtc < @PurgeRunLogCutoffUtc;
            SET @PurgeRows = @@ROWCOUNT;
            SET @PurgeTotalRows = @PurgeTotalRows + @PurgeRows;
            IF @PurgeRows = 0 BREAK;
            WAITFOR DELAY '00:00:00.250';
        END;

        SELECT
              N'Success' AS Status
            , @PurgeTotalRows AS RowsDeleted
            , @PurgeSnapshotCutoffUtc AS SnapshotCutoffUtc
            , @PurgeRunLogCutoffUtc AS RunLogCutoffUtc;

        RETURN;
    END;

    -- =========================================================================
    -- Mode: REPORT
    -- =========================================================================
    IF UPPER(@ModeNormalized) = N'REPORT'
    BEGIN
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
                ;WITH FirstSnapshot AS
                (
                    SELECT TOP (1) SnapshotId
                    FROM dbo.FR_Snapshot
                    WHERE SnapshotUtc >= @ReportStartUtc
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
                    N'Medium',
                    N'Medium',
                    N'Inferred',
                    N'Waits',
                    N'FR_R0003_TopWaitTypeSpike',
                    N'Top wait type increased during the window',
                    CONCAT(N'Wait type ', WaitType, N' had the largest observed wait-time delta.'),
                    CONCAT(N'DeltaWaitMs=', DeltaWaitMs),
                    N'Consider correlating this wait type with workload, blocking, IO, memory, and application changes before taking action.',
                    @ReportStartUtc,
                    @ReportEndUtc,
                    N'Computed from cumulative FR_Wait snapshots.'
                FROM WaitDelta;
            END;
        END;

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

        IF UPPER(@OutputFormat) = N'MARKDOWN'
        BEGIN
            DECLARE @ReportMarkdown nvarchar(max) = N'';

            SET @ReportMarkdown =
                N'# SQL Server Flight Recorder Report' + CHAR(13) + CHAR(10) +
                N'Tool-Version: ' + @ToolVersion + CHAR(13) + CHAR(10) +
                N'Schema-Version: ' + @SchemaVersion + CHAR(13) + CHAR(10) +
                N'Snapshot-Count: ' + CONVERT(nvarchar(20), @ReportSnapshotCount) + CHAR(13) + CHAR(10) +
                CHAR(13) + CHAR(10) +
                N'## Findings' + CHAR(13) + CHAR(10);

            SELECT @ReportMarkdown = @ReportMarkdown +
                N'- **' + Severity + N'** [' + RuleId + N'] ' + Title + N': ' + Summary + CHAR(13) + CHAR(10)
            FROM #fr_findings
            ORDER BY FindingOrdinal;

            SET @ReportMarkdown = @ReportMarkdown + CHAR(13) + CHAR(10) + N'## Timeline' + CHAR(13) + CHAR(10);

            SELECT @ReportMarkdown = @ReportMarkdown +
                N'- ' + CONVERT(nvarchar(50), EventUtc, 126) + N'Z — ' + EventType + N': ' + Summary + CHAR(13) + CHAR(10)
            FROM #fr_timeline
            ORDER BY EventUtc, EventType, SnapshotId;

            SELECT @ReportMarkdown AS Report;
            RETURN;
        END;

        IF UPPER(@OutputFormat) IN (N'DEFAULT', N'FINDINGSONLY')
        BEGIN
            SELECT
                  FindingOrdinal
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
                CASE Severity
                    WHEN N'Critical' THEN 1
                    WHEN N'High' THEN 2
                    WHEN N'Medium' THEN 3
                    WHEN N'Low' THEN 4
                    ELSE 5
                END,
                FindingOrdinal;
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
    -- Remaining deferred modes
    -- =========================================================================
    SELECT
        N'NotYetImplemented' AS Status,
        CONCAT(@ModeNormalized, N' is deferred beyond this simplified build.') AS Message,
        @ToolVersion AS ToolVersion;

END;
GO
