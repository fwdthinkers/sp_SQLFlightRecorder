-- =============================================================================
-- sp_SQLFlightRecorder
-- -----------------------------------------------------------------------------
-- SQL Server DBA Flight Recorder
-- A single, pure-T-SQL stored procedure that captures SQL Server diagnostic
-- data on a schedule and produces honest, prioritized findings about server
-- health and recent incidents.
--
-- Part 3 of 9 (v0.1 Design Prototype):
--   * Repository schema (12 core FR_* tables)
--   * Functional Install / Uninstall / Status modes
--   * Part 1/2 safety + validation behavior preserved
--
-- Install / Uninstall / Status are functional in Part 3 and create, drop,
-- and read FR_* repository tables in the install database. They also read
-- a small allow-listed set of system catalogs (sys.tables, sys.partitions,
-- sys.allocation_units, sys.dm_db_partition_stats, sys.fn_my_permissions)
-- to verify install state and report repository footprint. No collectors,
-- no Report, no rules logic, no Agent job, and no DMV reads beyond the
-- allow-listed set are present in this part. All remaining documented
-- modes return a clear "not yet implemented" message naming the part of
-- the v0.1 implementation plan that will deliver them.
--
-- Tool-Version:   0.1.0-alpha.2 (Part 3)
-- Build-Date-Utc: 2026-06-02
-- License:        MIT
-- Repository:     https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder
-- Design doc:     docs/design.md
-- Decisions:      docs/decisions.md
-- Plan:           docs/implementation-plan.md (this is Part 3)
--
-- Supported SQL Server range: 2012 through 2025 (per D-108).
-- This file is SQL Server 2012-compatible. Anything version-conditional
-- that is added later will go through dynamic SQL per D-112.
--
-- Default @Mode is 'Help' (D-003). Accidentally executing this procedure
-- with no parameters cannot harm a server.
-- =============================================================================

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- -----------------------------------------------------------------------------
-- Idempotent stub: create an empty procedure if it does not exist, so the
-- ALTER below always succeeds. This pattern is SQL Server 2012-compatible
-- (DROP PROCEDURE IF EXISTS is 2016+ and intentionally not used here).
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.sp_SQLFlightRecorder', N'P') IS NULL
    EXEC sys.sp_executesql N'CREATE PROCEDURE dbo.sp_SQLFlightRecorder AS RETURN 0;';
GO

ALTER PROCEDURE dbo.sp_SQLFlightRecorder
    -- --------------------------------------------------------------------------
    -- Parameter surface (design doc §2.2). Every parameter is declared in
    -- Part 1 even when its implementing mode is not yet present. Defaults
    -- match the design exactly.
    -- --------------------------------------------------------------------------
      @Mode                 nvarchar(30)   = N'Help'        -- D-003
    , @DatabaseName         sysname        = NULL           -- D-070 (Report filter)
    , @StartTime            datetime2(3)   = NULL           -- D-180 (server local time in v1)
    , @EndTime              datetime2(3)   = NULL           -- D-180
    , @MinSeverity          nvarchar(20)   = N'Low'         -- D-070
    , @MaxFindings          int            = 200            -- D-087 (clamped 10..2000)
    , @TopN                 int            = 50             -- D-181 (configurable v1 default)
    , @OutputFormat         nvarchar(20)   = N'Default'     -- D-079
    , @IncludeQueryPlans    bit            = 0              -- D-082 (no-op in v0.1)
    , @WhatIf               bit            = 0              -- Uninstall/Purge
    , @PreserveRunLog       bit            = 0              -- D-183 (Uninstall opt-in)
    , @Debug                bit            = 0              -- D-114 / D-128
AS
BEGIN
    -- ==========================================================================
    -- Session-level safety primitives (D-132).
    -- These are set unconditionally at the top of every mode handler so that
    -- the caller's session defaults can never make the procedure unsafe.
    -- ==========================================================================
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_NULLS ON;
    SET ANSI_WARNINGS ON;
    SET QUOTED_IDENTIFIER ON;
    SET ARITHABORT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- D-017
    SET LOCK_TIMEOUT 5000;                              -- D-133
    SET DEADLOCK_PRIORITY LOW;                          -- D-134

    -- --------------------------------------------------------------------------
    -- Local constants used by Help / About output.
    -- These string literals are the canonical source of "what version is this".
    -- They are also embedded in the file header comment above; keep both in
    -- sync when bumping the version.
    -- --------------------------------------------------------------------------
    DECLARE @ToolVersion             nvarchar(30)  = N'0.1.0-alpha.2';
    DECLARE @BuildDateUtc            datetime2(3)  = CONVERT(datetime2(3), '2026-06-02T00:00:00');
    DECLARE @SupportedSqlServerRange nvarchar(50)  = N'SQL Server 2012 through 2025';
    DECLARE @LicenseUrl              nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder/blob/main/LICENSE';
    DECLARE @RepositoryUrl           nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder';
    DECLARE @DesignDocUrl            nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder/blob/main/docs/design.md';
    DECLARE @PartNumber              int           = 3;
    DECLARE @PartTotal               int           = 9;

    -- --------------------------------------------------------------------------
    -- Closed set of documented v1 modes (design doc §2.1).
    -- Every entry either resolves below or returns a clean
    -- "not yet implemented" message. Anything outside this set is rejected
    -- as an unknown mode.
    -- --------------------------------------------------------------------------
    DECLARE @ModeNormalized nvarchar(30) = NULLIF(LTRIM(RTRIM(@Mode)), N'');
    IF @ModeNormalized IS NULL
        SET @ModeNormalized = N'Help';

    -- Accept 'Version' as an alias for 'About' so DBAs muscle-memory works.
    IF UPPER(@ModeNormalized) = N'VERSION'
        SET @ModeNormalized = N'About';

    -- ==========================================================================
    -- Parameter validation
    --
    -- Validation is performed BEFORE dispatch so that an out-of-range value
    -- is caught even for not-yet-implemented modes. Errors are returned as a
    -- single-row result set with a stable shape, not raised as exceptions
    -- (the procedure exists to help DBAs at 2 AM; surfacing a friendly row
    -- is more useful than a TRY/CATCH-able error number here).
    -- ==========================================================================

    -- @MinSeverity must be one of the closed set used by D-067 / D-070.
    IF UPPER(ISNULL(@MinSeverity, N'')) NOT IN (N'INFORMATIONAL', N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Invalid @MinSeverity'                               AS ErrorCode
            , CONCAT(
                  N'@MinSeverity must be one of: Informational, Low, Medium, High, Critical. '
                , N'You passed: '''
                , ISNULL(@MinSeverity, N'<NULL>')
                , N''''
              )                                                     AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- @MaxFindings must be in [10, 2000] per D-087.
    IF @MaxFindings IS NULL OR @MaxFindings < 10 OR @MaxFindings > 2000
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Invalid @MaxFindings'                               AS ErrorCode
            , CONCAT(
                  N'@MaxFindings must be between 10 and 2000 (default 200). You passed: '
                , ISNULL(CONVERT(nvarchar(20), @MaxFindings), N'<NULL>')
              )                                                     AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- @TopN sanity check. The configurable default is 50 per D-181; we accept
    -- 1..1000 here as the outer bound. Per-collector overrides will come via
    -- FR_Config in Part 8.
    IF @TopN IS NULL OR @TopN < 1 OR @TopN > 1000
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Invalid @TopN'                                      AS ErrorCode
            , CONCAT(
                  N'@TopN must be between 1 and 1000 (default 50). You passed: '
                , ISNULL(CONVERT(nvarchar(20), @TopN), N'<NULL>')
              )                                                     AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- @OutputFormat must be one of the closed set per D-079.
    IF UPPER(ISNULL(@OutputFormat, N'')) NOT IN (N'DEFAULT', N'FINDINGSONLY', N'TIMELINEONLY', N'MARKDOWN')
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Invalid @OutputFormat'                              AS ErrorCode
            , CONCAT(
                  N'@OutputFormat must be one of: Default, FindingsOnly, TimelineOnly, Markdown. '
                , N'You passed: '''
                , ISNULL(@OutputFormat, N'<NULL>')
                , N''''
              )                                                     AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- @StartTime / @EndTime ordering (only validated when both supplied).
    IF @StartTime IS NOT NULL AND @EndTime IS NOT NULL AND @StartTime >= @EndTime
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Invalid time window'                                AS ErrorCode
            , N'@StartTime must be strictly less than @EndTime. Times are interpreted as server local time in v1 (see D-180).' AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- Unknown @Mode rejection (closed set per §2.1, plus 'About' added in Part 1).
    IF UPPER(@ModeNormalized) NOT IN (
          N'HELP'
        , N'ABOUT'
        , N'INSTALL'
        , N'UNINSTALL'
        , N'COLLECT'
        , N'COLLECTDEBUG'
        , N'REPORT'
        , N'STATUS'
        , N'CONFIGURE'
        , N'PURGE'
        , N'COLLECTANDREPORT'
        , N'INSTALLDEMODATA'
    )
    BEGIN
        SELECT
              N'Error'                                              AS Status
            , N'Unknown @Mode'                                      AS ErrorCode
            , CONCAT(
                  N'@Mode must be one of: Help, About, Install, Uninstall, Collect, Report, Status, Configure, Purge, CollectAndReport, InstallDemoData. '
                , N'You passed: '''
                , ISNULL(@Mode, N'<NULL>')
                , N'''. Run EXEC dbo.sp_SQLFlightRecorder @Mode = ''Help'' for usage.'
              )                                                     AS Message
            , @ToolVersion                                          AS ToolVersion;
        RETURN;
    END;

    -- ==========================================================================
    -- Mode dispatch
    -- ==========================================================================

    -- --------------------------------------------------------------------------
    -- About mode (Part 1)
    --
    -- One result set, one row, fixed columns. Documented in design doc §2.1.
    -- The shape of this result is part of the public contract from v0.1
    -- onwards; columns may be added in minor releases but never removed
    -- or renamed (D-023, D-085 spirit).
    -- --------------------------------------------------------------------------
    IF UPPER(@ModeNormalized) = N'ABOUT'
    BEGIN
        SELECT
              @ToolVersion                                          AS ToolVersion
            , @BuildDateUtc                                         AS BuildDateUtc
            , @SupportedSqlServerRange                              AS SupportedSqlServerRange
            , CAST(@PartNumber AS nvarchar(10)) + N' of '
              + CAST(@PartTotal AS nvarchar(10))                    AS ImplementationPart
            , CONVERT(nvarchar(50), SYSUTCDATETIME(), 126) + N'Z'   AS InvocationUtc
            , @LicenseUrl                                           AS LicenseUrl
            , @RepositoryUrl                                        AS RepositoryUrl
            , @DesignDocUrl                                         AS DesignDocUrl;
        RETURN;
    END;

    -- --------------------------------------------------------------------------
    -- Help mode (Part 1 default)
    --
    -- All output goes through PRINT so a DBA running this in SSMS or Azure
    -- Data Studio sees readable text in the Messages tab without column
    -- truncation. Help intentionally does not return a result set.
    --
    -- PRINT is limited to ~8000 chars per call; we therefore split into
    -- several short PRINTs grouped by section.
    -- --------------------------------------------------------------------------
    IF UPPER(@ModeNormalized) = N'HELP'
    BEGIN
        PRINT N'';
        PRINT N'================================================================================';
        PRINT N' sp_SQLFlightRecorder';
        PRINT N' SQL Server DBA Flight Recorder';
        PRINT N'--------------------------------------------------------------------------------';
        PRINT N' Version : ' + @ToolVersion
              + N'   Build : ' + CONVERT(nvarchar(10), @BuildDateUtc, 23)
              + N'   Implementation part : '
              + CAST(@PartNumber AS nvarchar(10)) + N' of '
              + CAST(@PartTotal AS nvarchar(10));
        PRINT N' License : MIT';
        PRINT N' Repo    : ' + @RepositoryUrl;
        PRINT N' Design  : ' + @DesignDocUrl;
        PRINT N'================================================================================';
        PRINT N'';

        PRINT N' WHAT THIS IS';
        PRINT N' ------------';
        PRINT N' A single, pure-T-SQL stored procedure that captures SQL Server diagnostic';
        PRINT N' data on a schedule and produces honest, prioritized findings about server';
        PRINT N' health and recent incidents. It is a DBA''s flight recorder: cheap to run';
        PRINT N' continuously, useful after the fact.';
        PRINT N'';

        PRINT N' WHAT THIS IS *NOT*';
        PRINT N' ------------------';
        PRINT N'   * Not a monitoring platform (no alerting, no dashboards).';
        PRINT N'   * Not a notification system (no email, no webhooks).';
        PRINT N'   * Not an "AI" tool (no ML, no anomaly detection).';
        PRINT N'   * Not a multi-instance product (per-instance install only).';
        PRINT N'   * Not a remediation tool (diagnoses only; never takes corrective action).';
        PRINT N'';

        PRINT N' CHARTER PILLARS';
        PRINT N' ---------------';
        PRINT N'   * Boring, transparent, easy to test. Deterministic behavior; auditable evidence.';
        PRINT N'   * Honest. Severity / Confidence / EvidenceType on every finding;';
        PRINT N'     no overclaiming; coverage gaps are findings, not silence.';
        PRINT N'   * Safe on production. Bounded reads; no plan shredding; no user-table scans;';
        PRINT N'     cooperative timeout.';
        PRINT N'   * Compatible. SQL Server 2012 through 2025, on-prem and cloud;';
        PRINT N'     capability-driven branching.';
        PRINT N'   * Open source first. GitHub-native; DBA-friendly contribution model.';
        PRINT N'';

        PRINT N' MODES (full v1 surface; Part 3 implements Help/About/Install/Uninstall/Status)';
        PRINT N' -----------------------------------------------------------------------------';
        PRINT N'   Help              Default. Prints this text. Cannot harm a server.';
        PRINT N'   About             Returns version, build date, supported range, links.';
        PRINT N'                     (Alias: Version)';
        PRINT N'   Install           Creates the FR_* repository schema (v0.1 core).';
        PRINT N'                     Idempotent. Refuses system/read-only DBs and missing';
        PRINT N'                     VIEW SERVER STATE permission.';
        PRINT N'   Uninstall         Drops FR_* objects. @WhatIf previews; @PreserveRunLog = 1';
        PRINT N'                     archives FR_RunLog and FR_RunLogStep with timestamped names.';
        PRINT N'   Collect           [Not yet implemented in Part 3; arrives in Part 4 (first';
        PRINT N'                     collector) and Part 5 (remaining six v0.1 collectors).]';
        PRINT N'                     Takes one snapshot of bounded diagnostic data.';
        PRINT N'   Report            [Not yet implemented in Part 3; arrives in Part 6.]';
        PRINT N'                     Produces Findings + Timeline for a time window.';
        PRINT N'                     Returns at most two result sets.';
        PRINT N'   Status            Returns install summary, configuration, rules catalog,';
        PRINT N'                     repository size, run-log summary, and capability placeholder.';
        PRINT N'   Configure         [Not yet implemented in Part 3; arrives in Part 8.]';
        PRINT N'                     Reads/writes FR_Config entries with validation.';
        PRINT N'   Purge             [Not yet implemented in Part 3; arrives in Part 8.]';
        PRINT N'                     Batched retention cleanup. Honors @WhatIf.';
        PRINT N'   CollectAndReport  Documented as non-recommended; ad-hoc use only.';
        PRINT N'                     [Not yet implemented in Part 3.]';
        PRINT N'   InstallDemoData   [Not yet implemented in v0.1; deferred to v0.2/v0.3.]';
        PRINT N'';

        PRINT N' PARAMETERS';
        PRINT N' ----------';
        PRINT N'   @Mode                nvarchar(30)   Default: N''Help''';
        PRINT N'                        Which mode to run. See list above.';
        PRINT N'   @DatabaseName        sysname        Default: NULL';
        PRINT N'                        Restrict Report findings to one database.';
        PRINT N'   @StartTime           datetime2(3)   Default: NULL';
        PRINT N'                        Report window start. Interpreted as SERVER LOCAL TIME';
        PRINT N'                        in v1 (D-180). Explicit @TimeZone deferred to v0.4+.';
        PRINT N'   @EndTime             datetime2(3)   Default: NULL';
        PRINT N'                        Report window end. Server local time. Must be > @StartTime.';
        PRINT N'   @MinSeverity         nvarchar(20)   Default: N''Low''';
        PRINT N'                        Post-evaluation filter (D-070). Cannot hide Critical';
        PRINT N'                        coverage findings. Valid: Informational, Low, Medium,';
        PRINT N'                        High, Critical.';
        PRINT N'   @MaxFindings         int            Default: 200   (clamped 10..2000)';
        PRINT N'                        Safety cap on Findings result-set size (D-087).';
        PRINT N'                        Overflow truncates with one Informational row.';
        PRINT N'   @TopN                int            Default: 50    (clamped 1..1000)';
        PRINT N'                        Collector-side row cap per category (D-070, D-181).';
        PRINT N'                        Per-category override via FR_Config in Part 8.';
        PRINT N'   @OutputFormat        nvarchar(20)   Default: N''Default''';
        PRINT N'                        One of: Default, FindingsOnly, TimelineOnly, Markdown.';
        PRINT N'   @IncludeQueryPlans   bit            Default: 0';
        PRINT N'                        Surface Query Store plan XML by handle. Never parsed';
        PRINT N'                        in T-SQL (D-015, D-082). No-op in v0.1.';
        PRINT N'   @WhatIf              bit            Default: 0';
        PRINT N'                        Used by Uninstall and Purge to preview without acting.';
        PRINT N'   @PreserveRunLog      bit            Default: 0';
        PRINT N'                        Uninstall opt-in (D-183). When 1, FR_RunLog and';
        PRINT N'                        FR_RunLogStep are renamed to FR_RunLog_Archive_<ts>.';
        PRINT N'   @Debug               bit            Default: 0';
        PRINT N'                        PRINTs dynamic SQL without executing (D-114).';
        PRINT N'                        Collect runs as Mode=''CollectDebug'' with no rows';
        PRINT N'                        persisted (D-128). Arrives in Part 4.';
        PRINT N'';

        PRINT N' SAFETY';
        PRINT N' ------';
        PRINT N'   The procedure sets these session-level safety primitives at the top of';
        PRINT N'   every mode handler (D-132). Caller session defaults cannot make the tool';
        PRINT N'   unsafe:';
        PRINT N'     SET NOCOUNT ON';
        PRINT N'     SET XACT_ABORT ON';
        PRINT N'     SET ANSI_NULLS, ANSI_WARNINGS, QUOTED_IDENTIFIER, ARITHABORT ON';
        PRINT N'     SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED   -- D-017';
        PRINT N'     SET LOCK_TIMEOUT 5000                              -- D-133';
        PRINT N'     SET DEADLOCK_PRIORITY LOW                          -- D-134';
        PRINT N'';
        PRINT N'   Part 3 adds repository DDL in Install/Uninstall only. Help/About/Status';
        PRINT N'   are read-only, and no collector/report logic is active yet.';
        PRINT N'';

        PRINT N' EXAMPLES';
        PRINT N' --------';
        PRINT N'   -- Show this help text:';
        PRINT N'   EXEC dbo.sp_SQLFlightRecorder;';
        PRINT N'';
        PRINT N'   -- Show version metadata (one-row result set):';
        PRINT N'   EXEC dbo.sp_SQLFlightRecorder @Mode = N''About'';';
        PRINT N'';
        PRINT N'   -- Equivalent alias:';
        PRINT N'   EXEC dbo.sp_SQLFlightRecorder @Mode = N''Version'';';
        PRINT N'';

        PRINT N' STATUS OF THIS BUILD';
        PRINT N' --------------------';
        PRINT N'   This is implementation Part ' + CAST(@PartNumber AS nvarchar(10))
              + N' of ' + CAST(@PartTotal AS nvarchar(10))
              + N' on the v0.1 roadmap. Install, Uninstall, and Status now work.';
        PRINT N'   Collect / CollectDebug / Report / Configure / Purge remain not yet';
        PRINT N'   implemented and return explicit roadmap messages.';
        PRINT N'   See docs/implementation-plan.md for the full plan.';
        PRINT N'';
        PRINT N' TROUBLESHOOTING';
        PRINT N' ---------------';
        PRINT N'   The user-facing failure-mode catalog (D-147) lives at:';
        PRINT N'     docs/operations/troubleshooting.md';
        PRINT N'   It is intentionally not duplicated here so the canonical version cannot';
        PRINT N'   drift out of sync.';
        PRINT N'================================================================================';
        PRINT N'';
        RETURN;
    END;

    -- --------------------------------------------------------------------------
    -- Install mode (Part 3)
    -- --------------------------------------------------------------------------
    IF UPPER(@ModeNormalized) = N'INSTALL'
    BEGIN
        IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb', N'distribution')
        BEGIN
            SELECT
                  N'Error'                                                  AS Status
                , N'InstallRefusedSystemDatabase'                           AS ErrorCode
                , N'Install is allowed only in a user database in v0.1 (D-004).' AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END;

        IF ISNULL(CONVERT(nvarchar(20), DATABASEPROPERTYEX(DB_NAME(), N'Updateability')), N'') <> N'READ_WRITE'
        BEGIN
            SELECT
                  N'Error'                                                  AS Status
                , N'InstallRefusedReadOnlyDatabase'                         AS ErrorCode
                , N'Install requires a READ_WRITE database.'                AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END;

        IF NOT EXISTS (
            SELECT 1
            FROM sys.fn_my_permissions(NULL, N'SERVER') AS p
            WHERE p.permission_name = N'VIEW SERVER STATE'
        )
        BEGIN
            SELECT
                  N'Error'                                                  AS Status
                , N'MissingPermission'                                      AS ErrorCode
                , N'Install requires VIEW SERVER STATE permission (D-118).' AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END;

        DECLARE @ExistingSchemaVersion nvarchar(4000) = NULL;
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL
        BEGIN
            SELECT @ExistingSchemaVersion = c.ConfigValue
            FROM dbo.FR_Config AS c
            WHERE c.ConfigKey = N'SchemaVersion';
        END;

        IF @ExistingSchemaVersion IS NOT NULL
           AND @ExistingSchemaVersion > N'0.1.0-alpha.2'   -- D-038 / D-039 (forward-only, no downgrade)
        BEGIN
            SELECT
                  N'Error'                                                  AS Status
                , N'DowngradeBlocked'                                       AS ErrorCode
                , CONCAT(
                      N'Existing schema version '
                    , @ExistingSchemaVersion
                    , N' is newer than this build (0.1.0-alpha.2). Downgrade is not supported (D-039).'
                  )                                                         AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END;

        DECLARE @EngineEdition int = TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition'));
        DECLARE @ProductMajorVersion int = TRY_CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion'));
        DECLARE @UsePageCompression bit = 0;
        DECLARE @CreateSql nvarchar(max);
        DECLARE @TableCompressionClause nvarchar(64);
        DECLARE @IndexCompressionClause nvarchar(64);
        DECLARE @InstallRunId bigint = NULL;
        DECLARE @InstallStartedWithTableCount int;
        DECLARE @CurrentTableCount int;
        DECLARE @InstallStatus nvarchar(30);
        DECLARE @InstallMessage nvarchar(400);

        -- D-034: coarsened Standard support to major >= 13 (2016+), without SP-level branching.
        IF @EngineEdition IN (3, 5, 8)
            SET @UsePageCompression = 1;
        ELSE IF @EngineEdition = 2 AND ISNULL(@ProductMajorVersion, 0) >= 13
            SET @UsePageCompression = 1;

        SET @TableCompressionClause = CASE WHEN @UsePageCompression = 1 THEN N' WITH (DATA_COMPRESSION = PAGE)' ELSE N'' END;
        SET @IndexCompressionClause = @TableCompressionClause;

        SELECT @InstallStartedWithTableCount = COUNT(1)
        FROM sys.tables AS t
        WHERE t.schema_id = SCHEMA_ID(N'dbo')
          AND t.name IN (
                N'FR_Config', N'FR_RunLog', N'FR_RunLogStep', N'FR_Snapshot',
                N'FR_InstanceSnapshot', N'FR_Configuration', N'FR_Request', N'FR_Wait',
                N'FR_FileStat', N'FR_PerfCounter', N'FR_QueryText', N'FR_Rules'
          );

        BEGIN TRY
            IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Config
(
      ConfigKey    sysname         NOT NULL
    , ConfigValue  nvarchar(4000)  NULL
    , Description  nvarchar(400)   NULL
    , ModifiedUtc  datetime2(3)    NOT NULL CONSTRAINT DF_FR_Config_ModifiedUtc DEFAULT (SYSUTCDATETIME())
    , CONSTRAINT PK_FR_Config PRIMARY KEY CLUSTERED (ConfigKey)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_RunLog
(
      RunId                bigint         IDENTITY(1,1) NOT NULL
    , StartUtc             datetime2(3)   NOT NULL
    , EndUtc               datetime2(3)   NULL
    , Mode                 nvarchar(30)   NOT NULL
    , Status               nvarchar(20)   NULL
    , Reason               nvarchar(400)  NULL
    , InstanceFingerprint  nvarchar(200)  NULL
    , CapabilitySnapshot   nvarchar(max)  NULL
    , ErrorMessage         nvarchar(max)  NULL
    , LoginName            sysname        NULL
    , HostName             sysname        NULL
    , CONSTRAINT PK_FR_RunLog PRIMARY KEY NONCLUSTERED (RunId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_RunLog_StartUtc_RunId ON dbo.FR_RunLog (StartUtc, RunId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_RunLogStep
(
      RunStepId       bigint         IDENTITY(1,1) NOT NULL
    , RunId           bigint         NOT NULL
    , StepName        nvarchar(60)   NOT NULL
    , StartUtc        datetime2(3)   NOT NULL
    , EndUtc          datetime2(3)   NULL
    , Status          nvarchar(20)   NULL
    , RowsCollected   int            NULL
    , Reason          nvarchar(400)  NULL
    , ErrorMessage    nvarchar(max)  NULL
    , CONSTRAINT PK_FR_RunLogStep PRIMARY KEY NONCLUSTERED (RunStepId)
    , CONSTRAINT FK_FR_RunLogStep_RunLog FOREIGN KEY (RunId) REFERENCES dbo.FR_RunLog (RunId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_RunLogStep_StartUtc_RunStepId ON dbo.FR_RunLogStep (StartUtc, RunStepId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Snapshot
(
      SnapshotId            bigint         IDENTITY(1,1) NOT NULL
    , SnapshotUtc           datetime2(3)   NOT NULL
    , InstanceFingerprint   nvarchar(200)  NULL
    , RunId                 bigint         NULL
    , CONSTRAINT PK_FR_Snapshot PRIMARY KEY NONCLUSTERED (SnapshotId)
    , CONSTRAINT FK_FR_Snapshot_RunLog FOREIGN KEY (RunId) REFERENCES dbo.FR_RunLog (RunId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Snapshot_SnapshotUtc_SnapshotId ON dbo.FR_Snapshot (SnapshotUtc, SnapshotId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_InstanceSnapshot
(
      InstanceSnapshotId  bigint         IDENTITY(1,1) NOT NULL
    , SnapshotId          bigint         NOT NULL
    , SnapshotUtc         datetime2(3)   NOT NULL
    , ServerName          sysname        NULL
    , EngineEdition       int            NULL
    , ProductVersion      nvarchar(50)   NULL
    , ProductLevel        nvarchar(20)   NULL
    , IsHadrEnabled       bit            NULL
    , Platform            nvarchar(20)   NULL
    , CpuCount            int            NULL
    , PhysicalMemoryKb    bigint         NULL
    , SqlStartTimeUtc     datetime2(3)   NULL
    , CONSTRAINT PK_FR_InstanceSnapshot PRIMARY KEY NONCLUSTERED (InstanceSnapshotId)
    , CONSTRAINT FK_FR_InstanceSnapshot_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_InstanceSnapshot_SnapshotUtc_InstanceSnapshotId ON dbo.FR_InstanceSnapshot (SnapshotUtc, InstanceSnapshotId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Configuration
(
      ConfigurationId    bigint         IDENTITY(1,1) NOT NULL
    , SnapshotId         bigint         NOT NULL
    , SnapshotUtc        datetime2(3)   NOT NULL
    , ConfigurationKind  nvarchar(30)   NOT NULL
    , Name               nvarchar(200)  NOT NULL
    , ValueText          nvarchar(400)  NULL
    , IsDefault          bit            NULL
    , CONSTRAINT PK_FR_Configuration PRIMARY KEY NONCLUSTERED (ConfigurationId)
    , CONSTRAINT FK_FR_Configuration_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Configuration_SnapshotUtc_ConfigurationId ON dbo.FR_Configuration (SnapshotUtc, ConfigurationId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Request
(
      RequestId            bigint         IDENTITY(1,1) NOT NULL
    , SnapshotId           bigint         NOT NULL
    , SnapshotUtc          datetime2(3)   NOT NULL
    , SessionId            int            NOT NULL
    , DatabaseId           int            NOT NULL
    , BlockingSessionId    int            NULL
    , WaitTypeAtCapture    nvarchar(60)   NULL
    , WaitTimeMs           int            NULL
    , CpuTimeMs            int            NULL
    , LogicalReads         bigint         NULL
    , Status               nvarchar(30)   NULL
    , Command              nvarchar(60)   NULL
    , OpenTransactionCount int            NULL
    , QueryHash            binary(8)      NULL
    , QueryPlanHash        binary(8)      NULL
    , RequestedMemoryKb    bigint         NULL
    , GrantedMemoryKb      bigint         NULL
    , MemoryGrantTimeUtc   datetime2(3)   NULL
    , CONSTRAINT PK_FR_Request PRIMARY KEY NONCLUSTERED (RequestId)
    , CONSTRAINT FK_FR_Request_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Request_SnapshotUtc_RequestId ON dbo.FR_Request (SnapshotUtc, RequestId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Wait
(
      WaitId              bigint         IDENTITY(1,1) NOT NULL
    , SnapshotId          bigint         NOT NULL
    , SnapshotUtc         datetime2(3)   NOT NULL
    , WaitType            nvarchar(60)   NOT NULL
    , WaitingTasksCount   bigint         NOT NULL
    , WaitTimeMs          bigint         NOT NULL
    , MaxWaitTimeMs       bigint         NOT NULL
    , SignalWaitTimeMs    bigint         NOT NULL
    , CONSTRAINT PK_FR_Wait PRIMARY KEY NONCLUSTERED (WaitId)
    , CONSTRAINT FK_FR_Wait_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_Wait_SnapshotUtc_WaitType ON dbo.FR_Wait (SnapshotUtc, SnapshotId, WaitType)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_FileStat
(
      FileStatId          bigint         IDENTITY(1,1) NOT NULL
    , SnapshotId          bigint         NOT NULL
    , SnapshotUtc         datetime2(3)   NOT NULL
    , DatabaseId          int            NOT NULL
    , FileId              int            NOT NULL
    , NumOfReads          bigint         NOT NULL
    , NumOfBytesRead      bigint         NOT NULL
    , IoStallReadMs       bigint         NOT NULL
    , NumOfWrites         bigint         NOT NULL
    , NumOfBytesWritten   bigint         NOT NULL
    , IoStallWriteMs      bigint         NOT NULL
    , SizeOnDiskBytes     bigint         NULL
    , CONSTRAINT PK_FR_FileStat PRIMARY KEY NONCLUSTERED (FileStatId)
    , CONSTRAINT FK_FR_FileStat_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_FileStat_SnapshotUtc_DatabaseId_FileId ON dbo.FR_FileStat (SnapshotUtc, DatabaseId, FileId)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_PerfCounter
(
      PerfCounterId   bigint          IDENTITY(1,1) NOT NULL
    , SnapshotId      bigint          NOT NULL
    , SnapshotUtc     datetime2(3)    NOT NULL
    , ObjectName      nvarchar(128)   NOT NULL
    , CounterName     nvarchar(128)   NOT NULL
    , InstanceName    nvarchar(128)   NULL
    , CounterValue    bigint          NOT NULL
    , CounterType     int             NOT NULL
    , CONSTRAINT PK_FR_PerfCounter PRIMARY KEY NONCLUSTERED (PerfCounterId)
    , CONSTRAINT FK_FR_PerfCounter_Snapshot FOREIGN KEY (SnapshotId) REFERENCES dbo.FR_Snapshot (SnapshotId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE CLUSTERED INDEX CIX_FR_PerfCounter_SnapshotUtc_ObjectName_CounterName_InstanceName ON dbo.FR_PerfCounter (SnapshotUtc, ObjectName, CounterName, InstanceName)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_QueryText
(
      QueryTextId    bigint         IDENTITY(1,1) NOT NULL
    , QueryHash      binary(8)      NOT NULL
    , TextHash       binary(32)     NOT NULL
    , SqlText        nvarchar(max)  NULL
    , FirstSeenUtc   datetime2(3)   NOT NULL CONSTRAINT DF_FR_QueryText_FirstSeenUtc DEFAULT (SYSUTCDATETIME())
    , LastSeenUtc    datetime2(3)   NOT NULL CONSTRAINT DF_FR_QueryText_LastSeenUtc DEFAULT (SYSUTCDATETIME())
    , CONSTRAINT PK_FR_QueryText PRIMARY KEY CLUSTERED (QueryTextId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;

                SET @CreateSql = N'CREATE UNIQUE NONCLUSTERED INDEX UX_FR_QueryText_QueryHash_TextHash ON dbo.FR_QueryText (QueryHash, TextHash)' + @IndexCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NULL
            BEGIN
                SET @CreateSql = N'
CREATE TABLE dbo.FR_Rules
(
      RuleId                nvarchar(60)   NOT NULL
    , Category              nvarchar(30)   NOT NULL
    , Severity              nvarchar(20)   NOT NULL
    , Confidence            nvarchar(20)   NOT NULL
    , EvidenceType          nvarchar(20)   NOT NULL
    , LifecycleState        nvarchar(20)   NOT NULL CONSTRAINT DF_FR_Rules_LifecycleState DEFAULT (N''Active'')
    , ShortDescription      nvarchar(400)  NOT NULL
    , IntroducedInVersion   nvarchar(20)   NOT NULL
    , CONSTRAINT PK_FR_Rules PRIMARY KEY CLUSTERED (RuleId)
)' + @TableCompressionClause + N';';
                EXEC sys.sp_executesql @CreateSql;
            END;

            INSERT INTO dbo.FR_RunLog
            (
                  StartUtc
                , EndUtc
                , Mode
                , Status
                , Reason
                , InstanceFingerprint
                , CapabilitySnapshot
                , ErrorMessage
                , LoginName
                , HostName
            )
            VALUES
            (
                  SYSUTCDATETIME()
                , NULL
                , N'Install'
                , N'InProgress'
                , N'Installing Part 3 schema'
                , NULL      -- D-028: stored, never used as PK/FK
                , NULL      -- D-127: populated in Part 4
                , NULL
                , SUSER_SNAME()
                , HOST_NAME()
            );
            SET @InstallRunId = SCOPE_IDENTITY();

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SchemaVersion')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'SchemaVersion', N'0.1.0-alpha.2', N'Installed schema version (forward-only migration marker).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotIntervalSeconds')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'SnapshotIntervalSeconds', N'60', N'Default snapshot cadence in seconds (D-042).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'SnapshotRetentionDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'SnapshotRetentionDays', N'7', N'Default snapshot retention in days (v0.1 §11.2).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'RunLogRetentionDays')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'RunLogRetentionDays', N'28', N'Run-log retention (4x snapshot retention per D-035).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'MaxRowsPerCollector')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'MaxRowsPerCollector', N'50', N'Default collector-side row cap (D-181).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'WaitStatsIgnoreList')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'WaitStatsIgnoreList', N'BROKER_EVENTHANDLER;BROKER_RECEIVE_WAITFOR;BROKER_TASK_STOP;BROKER_TO_FLUSH;BROKER_TRANSMITTER;CHECKPOINT_QUEUE;CHKPT;CLR_AUTO_EVENT;CLR_MANUAL_EVENT;CLR_SEMAPHORE;DBMIRROR_DBM_EVENT;DBMIRROR_EVENTS_QUEUE;DBMIRROR_WORKER_QUEUE;DBMIRRORING_CMD;DIRTY_PAGE_POLL;DISPATCHER_QUEUE_SEMAPHORE;EXECSYNC;FSAGENT;FT_IFTS_SCHEDULER_IDLE_WAIT;FT_IFTSHC_MUTEX;HADR_CLUSAPI_CALL;HADR_FILESTREAM_IOMGR_IOCOMPLETION;HADR_LOGCAPTURE_WAIT;HADR_NOTIFICATION_DEQUEUE;HADR_TIMER_TASK;HADR_WORK_QUEUE;KSOURCE_WAKEUP;LAZYWRITER_SLEEP;LOGMGR_QUEUE;MEMORY_ALLOCATION_EXT;ONDEMAND_TASK_QUEUE;PARALLEL_REDO_DRAIN_WORKER;PARALLEL_REDO_LOG_CACHE;PARALLEL_REDO_TRAN_LIST;PARALLEL_REDO_WORKER_SYNC;PARALLEL_REDO_WORKER_WAIT_WORK;PREEMPTIVE_HADR_LEASE_MECHANISM;PREEMPTIVE_OS_FLUSHFILEBUFFERS;PREEMPTIVE_XE_GETTARGETSTATE;PWAIT_ALL_COMPONENTS_INITIALIZED;PWAIT_DIRECTLOGCONSUMER_GETNEXT;QDS_PERSIST_TASK_MAIN_LOOP_SLEEP;QDS_ASYNC_QUEUE;QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP;QDS_SHUTDOWN_QUEUE;REDO_THREAD_PENDING_WORK;REQUEST_FOR_DEADLOCK_SEARCH;RESOURCE_QUEUE;SERVER_IDLE_CHECK;SLEEP_BPOOL_FLUSH;SLEEP_DBSTARTUP;SLEEP_DCOMSTARTUP;SLEEP_MASTERDBREADY;SLEEP_MASTERMDREADY;SLEEP_MASTERUPGRADED;SLEEP_MSDBSTARTUP;SLEEP_SYSTEMTASK;SLEEP_TASK;SLEEP_TEMPDBSTARTUP;SNI_HTTP_ACCEPT;SP_SERVER_DIAGNOSTICS_SLEEP;SQLTRACE_BUFFER_FLUSH;SQLTRACE_INCREMENTAL_FLUSH_SLEEP;SQLTRACE_WAIT_ENTRIES;WAIT_FOR_RESULTS;WAITFOR;WAITFOR_TASKSHUTDOWN;WAIT_XTP_RECOVERY;WAIT_XTP_HOST_WAIT;WAIT_XTP_OFFLINE_CKPT_NEW_LOG;WAIT_XTP_CKPT_CLOSE;XE_DISPATCHER_JOIN;XE_DISPATCHER_WAIT;XE_TIMER_EVENT', N'Ignored waits at collect time (D-033, D-057).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'DisabledRules')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'DisabledRules', N'', N'Semicolon-delimited disabled rule IDs; empty means none (D-099).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'CriticalWaitTypes')
                -- D-105: key ships now; the rules engine starts honoring it in v1.1.
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'CriticalWaitTypes', N'PAGEIOLATCH_*;WRITELOG;RESOURCE_SEMAPHORE;LCK_M_*;THREADPOOL;SOS_SCHEDULER_YIELD', N'Critical wait-type patterns (defined now, honored starting v1.1).', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'InstallTimestampUtc')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'InstallTimestampUtc', CONVERT(nvarchar(50), SYSUTCDATETIME(), 126), N'Initial install timestamp in UTC.', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Config WHERE ConfigKey = N'InstallLogin')
                INSERT INTO dbo.FR_Config (ConfigKey, ConfigValue, Description, ModifiedUtc)
                VALUES (N'InstallLogin', SUSER_SNAME(), N'Login that executed initial install.', SYSUTCDATETIME());

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0001_ActiveBlockingChain')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0001_ActiveBlockingChain', N'Blocking', N'High', N'High', N'Observed', N'Active', N'Active blocking chain observed during incident window.', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0002_LongRunningOpenTransaction')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0002_LongRunningOpenTransaction', N'Blocking', N'Medium', N'High', N'Observed', N'Active', N'Long-running open transaction observed.', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0003_TopWaitTypeSpike')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0003_TopWaitTypeSpike', N'Waits', N'Medium', N'Medium', N'Inferred', N'Active', N'Top wait type increased sharply within the window.', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0004_FileIoLatencySpike')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0004_FileIoLatencySpike', N'IO', N'Medium', N'Medium', N'Inferred', N'Active', N'File I/O latency increased materially during the window.', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0005_MemoryGrantsPending')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0005_MemoryGrantsPending', N'Memory', N'High', N'High', N'Observed', N'Active', N'Memory grants pending was observed.', N'0.1');

            IF NOT EXISTS (SELECT 1 FROM dbo.FR_Rules WHERE RuleId = N'FR_R0006_ServerRestartDuringWindow')
                INSERT INTO dbo.FR_Rules (RuleId, Category, Severity, Confidence, EvidenceType, LifecycleState, ShortDescription, IntroducedInVersion)
                VALUES (N'FR_R0006_ServerRestartDuringWindow', N'Configuration', N'Critical', N'High', N'Observed', N'Active', N'SQL Server restart was detected within the analysis window.', N'0.1');

            UPDATE dbo.FR_RunLog
            SET
                  EndUtc = SYSUTCDATETIME()
                , Status = N'Success'
                , Reason = N'Install completed successfully'
            WHERE RunId = @InstallRunId;

            SELECT @CurrentTableCount = COUNT(1)
            FROM sys.tables AS t
            WHERE t.schema_id = SCHEMA_ID(N'dbo')
              AND t.name IN (
                    N'FR_Config', N'FR_RunLog', N'FR_RunLogStep', N'FR_Snapshot',
                    N'FR_InstanceSnapshot', N'FR_Configuration', N'FR_Request', N'FR_Wait',
                    N'FR_FileStat', N'FR_PerfCounter', N'FR_QueryText', N'FR_Rules'
              );

            SET @InstallStatus = CASE WHEN @InstallStartedWithTableCount = 12 THEN N'AlreadyInstalled' ELSE N'Installed' END;
            SET @InstallMessage =
                CASE WHEN @InstallStartedWithTableCount = 12
                     THEN N'Install completed; repository schema already existed and seed rows were preserved.'
                     ELSE N'Install completed; repository schema and seed rows are ready.'
                END;

            SELECT
                  @InstallStatus                                            AS Status
                , DB_NAME()                                                 AS DatabaseName
                , N'0.1.0-alpha.2'                                          AS SchemaVersion
                , @CurrentTableCount                                        AS TableCount
                , @InstallMessage                                           AS Message;
            RETURN;
        END TRY
        BEGIN CATCH
            DECLARE @InstallError nvarchar(max) = ERROR_MESSAGE();

            IF @InstallRunId IS NOT NULL AND OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
            BEGIN
                UPDATE dbo.FR_RunLog
                SET
                      EndUtc = SYSUTCDATETIME()
                    , Status = N'Error'
                    , ErrorMessage = @InstallError
                    , Reason = N'Install failed'
                WHERE RunId = @InstallRunId;
            END;

            SELECT
                  N'Error'                                                  AS Status
                , N'InstallFailed'                                          AS ErrorCode
                , @InstallError                                             AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END CATCH;
    END;

    -- --------------------------------------------------------------------------
    -- Uninstall mode (Part 3, D-183)
    -- --------------------------------------------------------------------------
    IF UPPER(@ModeNormalized) = N'UNINSTALL'
    BEGIN
        DECLARE @DroppedCount int = 0;
        DECLARE @RenamedCount int = 0;
        DECLARE @SurvivingCount int;
        DECLARE @ArchiveSuffix nvarchar(32);
        DECLARE @ArchiveRunLogName sysname;
        DECLARE @ArchiveRunLogStepName sysname;

        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
           AND EXISTS (
                SELECT 1
                FROM dbo.FR_RunLog AS rl
                WHERE rl.Mode = N'Collect'
                  AND rl.Status = N'InProgress'
           )
        BEGIN
            SELECT
                  N'Error'                                                  AS Status
                , N'UninstallBlockedCollectInProgress'                      AS ErrorCode
                , N'Uninstall refused because a Collect run is marked InProgress.' AS Message
                , @ToolVersion                                              AS ToolVersion;
            RETURN;
        END;

        IF @WhatIf = 1
        BEGIN
            SELECT
                  N'WhatIf'                                                 AS Status
                , N'TABLE'                                                  AS ObjectType
                , N'dbo'                                                    AS SchemaName
                , x.ObjectName                                              AS ObjectName
                , CASE
                      WHEN @PreserveRunLog = 1
                           AND x.ObjectName IN (N'FR_RunLog', N'FR_RunLogStep')
                      THEN N'Rename'
                      ELSE N'Drop'
                  END                                                       AS Action
            FROM
            (
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
            ) AS x
            WHERE OBJECT_ID(CONCAT(N'dbo.', x.ObjectName), N'U') IS NOT NULL
            ORDER BY x.ObjectName;
            RETURN;
        END;

        IF @PreserveRunLog = 1
        BEGIN
            SET @ArchiveSuffix =
                CONCAT(
                    CONVERT(nvarchar(8), SYSUTCDATETIME(), 112),
                    N'_',
                    REPLACE(CONVERT(nvarchar(8), SYSUTCDATETIME(), 108), N':', N'')
                );
            SET @ArchiveRunLogName = CONCAT(N'FR_RunLog_Archive_', @ArchiveSuffix);
            SET @ArchiveRunLogStepName = CONCAT(N'FR_RunLogStep_Archive_', @ArchiveSuffix);

            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL
            BEGIN
                EXEC sys.sp_rename @objname = N'dbo.FR_RunLogStep', @newname = @ArchiveRunLogStepName, @objtype = N'OBJECT';
                SET @RenamedCount = @RenamedCount + 1;
            END;

            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
            BEGIN
                EXEC sys.sp_rename @objname = N'dbo.FR_RunLog', @newname = @ArchiveRunLogName, @objtype = N'OBJECT';
                SET @RenamedCount = @RenamedCount + 1;
            END;
        END;

        IF OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_InstanceSnapshot; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_Configuration', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Configuration; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_Request', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Request; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_Wait', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Wait; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_FileStat', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_FileStat; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_PerfCounter', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_PerfCounter; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_QueryText', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_QueryText; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_Snapshot', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Snapshot; SET @DroppedCount = @DroppedCount + 1; END;

        IF @PreserveRunLog = 0
        BEGIN
            IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_RunLogStep; SET @DroppedCount = @DroppedCount + 1; END;
            IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_RunLog; SET @DroppedCount = @DroppedCount + 1; END;
        END;

        IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Rules; SET @DroppedCount = @DroppedCount + 1; END;
        IF OBJECT_ID(N'dbo.FR_Config', N'U') IS NOT NULL BEGIN DROP TABLE dbo.FR_Config; SET @DroppedCount = @DroppedCount + 1; END;

        SELECT @SurvivingCount = COUNT(1)
        FROM sys.tables AS t
        WHERE t.schema_id = SCHEMA_ID(N'dbo')
          AND t.name IN (
                N'FR_Config', N'FR_RunLog', N'FR_RunLogStep', N'FR_Snapshot',
                N'FR_InstanceSnapshot', N'FR_Configuration', N'FR_Request', N'FR_Wait',
                N'FR_FileStat', N'FR_PerfCounter', N'FR_QueryText', N'FR_Rules'
          );

        SELECT
              CASE WHEN @SurvivingCount = 0 THEN N'Uninstalled' ELSE N'PartiallyUninstalled' END AS Status
            , @DroppedCount                                                AS DroppedCount
            , @RenamedCount                                                AS RenamedCount
            , CASE
                  WHEN @SurvivingCount = 0 AND @PreserveRunLog = 1
                  THEN N'Uninstall completed; run-log tables were archived.'
                  WHEN @SurvivingCount = 0
                  THEN N'Uninstall completed; all FR_* objects were removed.'
                  ELSE N'Uninstall completed with surviving FR_* objects.'
              END                                                          AS Message;
        RETURN;
    END;

    -- --------------------------------------------------------------------------
    -- Status mode (Part 3)
    -- --------------------------------------------------------------------------
    IF UPPER(@ModeNormalized) = N'STATUS'
    BEGIN
        DECLARE @IsInstalled bit = CASE WHEN OBJECT_ID(N'dbo.FR_Config', N'U') IS NULL THEN 0 ELSE 1 END;
        DECLARE @InstalledSchemaVersion nvarchar(4000) = NULL;
        DECLARE @InstalledOnUtc nvarchar(50) = NULL;
        DECLARE @InstalledBy nvarchar(4000) = NULL;
        DECLARE @InstalledTableCount int;

        SELECT @InstalledTableCount = COUNT(1)
        FROM sys.tables AS t
        WHERE t.schema_id = SCHEMA_ID(N'dbo')
          AND t.name IN (
                N'FR_Config', N'FR_RunLog', N'FR_RunLogStep', N'FR_Snapshot',
                N'FR_InstanceSnapshot', N'FR_Configuration', N'FR_Request', N'FR_Wait',
                N'FR_FileStat', N'FR_PerfCounter', N'FR_QueryText', N'FR_Rules'
          );

        IF @IsInstalled = 1
        BEGIN
            SELECT @InstalledSchemaVersion = c.ConfigValue
            FROM dbo.FR_Config AS c
            WHERE c.ConfigKey = N'SchemaVersion';

            SELECT @InstalledOnUtc = c.ConfigValue
            FROM dbo.FR_Config AS c
            WHERE c.ConfigKey = N'InstallTimestampUtc';

            SELECT @InstalledBy = c.ConfigValue
            FROM dbo.FR_Config AS c
            WHERE c.ConfigKey = N'InstallLogin';
        END;

        -- Result set 1: InstallationSummary
        SELECT
              DB_NAME()                                                     AS DatabaseName
            , @InstalledSchemaVersion                                       AS SchemaVersion
            , @InstalledOnUtc                                               AS InstalledOnUtc
            , @InstalledBy                                                  AS InstalledBy
            , ISNULL(@InstalledTableCount, 0)                               AS TableCount
            , @IsInstalled                                                  AS IsInstalled
            , CASE WHEN @IsInstalled = 1
                   THEN N'Installed'
                   ELSE N'Not installed (FR_Config missing).'
              END                                                           AS Message;

        -- Result set 2: Configuration
        IF @IsInstalled = 1
        BEGIN
            SELECT
                  c.ConfigKey
                , c.ConfigValue
                , c.Description
                , c.ModifiedUtc
            FROM dbo.FR_Config AS c
            ORDER BY c.ConfigKey;
        END;
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS sysname)        AS ConfigKey
                , CAST(NULL AS nvarchar(4000)) AS ConfigValue
                , CAST(NULL AS nvarchar(400))  AS Description
                , CAST(NULL AS datetime2(3))   AS ModifiedUtc
            WHERE 1 = 0;
        END;

        -- Result set 3: RuleCatalog
        IF OBJECT_ID(N'dbo.FR_Rules', N'U') IS NOT NULL
        BEGIN
            SELECT
                  r.RuleId
                , r.Category
                , r.Severity
                , r.Confidence
                , r.EvidenceType
                , r.LifecycleState
                , r.ShortDescription
                , r.IntroducedInVersion
            FROM dbo.FR_Rules AS r
            ORDER BY r.RuleId;
        END;
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS nvarchar(60))   AS RuleId
                , CAST(NULL AS nvarchar(30))   AS Category
                , CAST(NULL AS nvarchar(20))   AS Severity
                , CAST(NULL AS nvarchar(20))   AS Confidence
                , CAST(NULL AS nvarchar(20))   AS EvidenceType
                , CAST(NULL AS nvarchar(20))   AS LifecycleState
                , CAST(NULL AS nvarchar(400))  AS ShortDescription
                , CAST(NULL AS nvarchar(20))   AS IntroducedInVersion
            WHERE 1 = 0;
        END;

        -- Result set 4: RepositorySize
        ;WITH FRTableList AS
        (
            SELECT N'FR_Config' AS TableName, OBJECT_ID(N'dbo.FR_Config', N'U') AS ObjectId
            UNION ALL SELECT N'FR_RunLog', OBJECT_ID(N'dbo.FR_RunLog', N'U')
            UNION ALL SELECT N'FR_RunLogStep', OBJECT_ID(N'dbo.FR_RunLogStep', N'U')
            UNION ALL SELECT N'FR_Snapshot', OBJECT_ID(N'dbo.FR_Snapshot', N'U')
            UNION ALL SELECT N'FR_InstanceSnapshot', OBJECT_ID(N'dbo.FR_InstanceSnapshot', N'U')
            UNION ALL SELECT N'FR_Configuration', OBJECT_ID(N'dbo.FR_Configuration', N'U')
            UNION ALL SELECT N'FR_Request', OBJECT_ID(N'dbo.FR_Request', N'U')
            UNION ALL SELECT N'FR_Wait', OBJECT_ID(N'dbo.FR_Wait', N'U')
            UNION ALL SELECT N'FR_FileStat', OBJECT_ID(N'dbo.FR_FileStat', N'U')
            UNION ALL SELECT N'FR_PerfCounter', OBJECT_ID(N'dbo.FR_PerfCounter', N'U')
            UNION ALL SELECT N'FR_QueryText', OBJECT_ID(N'dbo.FR_QueryText', N'U')
            UNION ALL SELECT N'FR_Rules', OBJECT_ID(N'dbo.FR_Rules', N'U')
        ),
        ExistingFRTable AS
        (
            SELECT f.TableName, f.ObjectId
            FROM FRTableList AS f
            WHERE f.ObjectId IS NOT NULL
        ),
        RowCounts AS
        (
            SELECT
                  ps.object_id
                , SUM(ps.row_count) AS RowCountValue
            FROM sys.dm_db_partition_stats AS ps
            WHERE ps.index_id IN (0, 1)
              AND OBJECT_NAME(ps.object_id) LIKE N'FR\_%' ESCAPE N'\'
            GROUP BY ps.object_id
        ),
        SizeStats AS
        (
            SELECT
                  p.object_id
                , SUM(au.total_pages) * 8 AS ReservedKb
                , SUM(au.data_pages) * 8  AS DataKb
                , (SUM(au.used_pages) - SUM(au.data_pages)) * 8 AS IndexKb
            FROM sys.partitions AS p
            INNER JOIN sys.allocation_units AS au
                ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
            WHERE OBJECT_NAME(p.object_id) LIKE N'FR\_%' ESCAPE N'\'
            GROUP BY p.object_id
        )
        SELECT
              e.TableName
            , ISNULL(rc.RowCountValue, 0)                                 AS [RowCount]
            , ISNULL(ss.ReservedKb, 0)                                    AS ReservedKb
            , ISNULL(ss.DataKb, 0)                                        AS DataKb
            , ISNULL(ss.IndexKb, 0)                                       AS IndexKb
        FROM ExistingFRTable AS e
        LEFT JOIN RowCounts AS rc
            ON rc.object_id = e.ObjectId
        LEFT JOIN SizeStats AS ss
            ON ss.object_id = e.ObjectId
        ORDER BY e.TableName;

        -- Result set 5: RunLogSummary
        IF OBJECT_ID(N'dbo.FR_RunLog', N'U') IS NOT NULL
        BEGIN
            DECLARE @LastRunUtc datetime2(3) = NULL;
            DECLARE @LastRunMode nvarchar(30) = NULL;
            DECLARE @LastRunStatus nvarchar(20) = NULL;
            DECLARE @RunsLast24h int = 0;
            DECLARE @ErrorsLast24h int = 0;

            SELECT TOP (1)
                  @LastRunUtc = rl.StartUtc
                , @LastRunMode = rl.Mode
                , @LastRunStatus = rl.Status
            FROM dbo.FR_RunLog AS rl
            ORDER BY rl.StartUtc DESC, rl.RunId DESC;

            SELECT @RunsLast24h = COUNT(1)
            FROM dbo.FR_RunLog AS rl
            WHERE rl.StartUtc >= DATEADD(hour, -24, SYSUTCDATETIME());

            SELECT @ErrorsLast24h = COUNT(1)
            FROM dbo.FR_RunLog AS rl
            WHERE rl.StartUtc >= DATEADD(hour, -24, SYSUTCDATETIME())
              AND rl.Status = N'Error';

            SELECT
                  @LastRunUtc                                                AS LastRunUtc
                , @LastRunMode                                               AS LastRunMode
                , @LastRunStatus                                             AS LastRunStatus
                , @RunsLast24h                                               AS RunsLast24h
                , @ErrorsLast24h                                             AS ErrorsLast24h;
        END;
        ELSE
        BEGIN
            SELECT
                  CAST(NULL AS datetime2(3))                                 AS LastRunUtc
                , CAST(NULL AS nvarchar(30))                                 AS LastRunMode
                , CAST(NULL AS nvarchar(20))                                 AS LastRunStatus
                , CAST(0 AS int)                                             AS RunsLast24h
                , CAST(0 AS int)                                             AS ErrorsLast24h;
        END;

        -- Result set 6: CapabilitySnapshot (Part 3 shape-only placeholder; D-127)
        SELECT
              CAST(NULL AS nvarchar(128))                                    AS KeyName
            , CAST(NULL AS nvarchar(4000))                                   AS KeyValue
        WHERE 1 = 0;

        RETURN;
    END;

    -- --------------------------------------------------------------------------
    -- Remaining documented modes: clean "not yet implemented" message.
    -- --------------------------------------------------------------------------
    DECLARE @TargetPart nvarchar(80);
    SET @TargetPart =
        CASE UPPER(@ModeNormalized)
            WHEN N'COLLECT'          THEN N'Part 4 (first collector) and Part 5'
            WHEN N'COLLECTDEBUG'     THEN N'Part 4'
            WHEN N'REPORT'           THEN N'Part 6'
            WHEN N'CONFIGURE'        THEN N'Part 8'
            WHEN N'PURGE'            THEN N'Part 8'
            WHEN N'COLLECTANDREPORT' THEN N'Part 6 (depends on Collect from Part 4/5)'
            WHEN N'INSTALLDEMODATA'  THEN N'deferred to v0.2/v0.3 (per D-182)'
            ELSE N'a later part'
        END;

    SELECT
          N'NotYetImplemented'                                              AS Status
        , @ModeNormalized                                                   AS RequestedMode
        , CONCAT(
              N'Mode '''
            , @ModeNormalized
            , N''' is documented but not yet implemented in this build. '
            , N'Scheduled to arrive in '
            , @TargetPart
            , N'. This build is implementation Part '
            , CAST(@PartNumber AS nvarchar(10))
            , N' of '
            , CAST(@PartTotal AS nvarchar(10))
            , N' on the v0.1 roadmap. Run EXEC dbo.sp_SQLFlightRecorder @Mode = N''Help'' for the full mode list.'
          )                                                                 AS Message
        , @ToolVersion                                                      AS ToolVersion
        , CAST(@PartNumber AS nvarchar(10)) + N' of '
          + CAST(@PartTotal AS nvarchar(10))                                AS ImplementationPart
        , @DesignDocUrl                                                     AS DesignDocUrl;

    RETURN;
END;
GO

-- =============================================================================
-- End of file. Re-run idempotency: this file may be re-executed in the same
-- database without error; the IF OBJECT_ID stub plus ALTER PROCEDURE pattern
-- handles both first-install and upgrade-in-place.
-- =============================================================================
