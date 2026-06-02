-- =============================================================================
-- sp_SQLFlightRecorder
-- -----------------------------------------------------------------------------
-- SQL Server DBA Flight Recorder
-- A single, pure-T-SQL stored procedure that captures SQL Server diagnostic
-- data on a schedule and produces honest, prioritized findings about server
-- health and recent incidents.
--
-- Part 1 of 9 (v0.1 Design Prototype):
--   * Procedure shell
--   * Approved parameter surface (per design doc §2.2)
--   * Help mode (default)
--   * About mode
--   * Defensive SET options (per D-132)
--
-- This part is intentionally inert. It reads no DMVs, creates no tables,
-- creates no Agent job, and writes nothing. All other documented modes
-- return a clear "not yet implemented" message pointing at the part of the
-- v0.1 implementation plan that will deliver them.
--
-- Tool-Version:   0.1.0-alpha.1 (Part 1)
-- Build-Date-Utc: 2026-06-02
-- License:        MIT
-- Repository:     https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder
-- Design doc:     docs/design.md
-- Decisions:      docs/decisions.md
-- Plan:           docs/implementation-plan.md (this is Part 1)
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
    EXEC (N'CREATE PROCEDURE dbo.sp_SQLFlightRecorder AS RETURN 0;');
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
    DECLARE @ToolVersion             nvarchar(30)  = N'0.1.0-alpha.1';
    DECLARE @BuildDateUtc            datetime2(3)  = CONVERT(datetime2(3), '2026-06-02T00:00:00');
    DECLARE @SupportedSqlServerRange nvarchar(50)  = N'SQL Server 2012 through 2025';
    DECLARE @LicenseUrl              nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder/blob/main/LICENSE';
    DECLARE @RepositoryUrl           nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder';
    DECLARE @DesignDocUrl            nvarchar(200) = N'https://github.com/forward-thinkers-lab/sp_SQLFlightRecorder/blob/main/docs/design.md';
    DECLARE @PartNumber              int           = 1;
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

        PRINT N' MODES (full v1 surface; Part 1 only implements Help and About)';
        PRINT N' --------------------------------------------------------------';
        PRINT N'   Help              Default. Prints this text. Cannot harm a server.';
        PRINT N'   About             Returns version, build date, supported range, links.';
        PRINT N'                     (Alias: Version)';
        PRINT N'   Install           [Not yet implemented in Part 1; arrives in Part 3.]';
        PRINT N'                     Creates the FR_* repository schema. Idempotent.';
        PRINT N'   Uninstall         [Not yet implemented in Part 1; arrives in Part 3.]';
        PRINT N'                     Drops all FR_* objects. Use @PreserveRunLog = 1 to keep';
        PRINT N'                     the run log archived under a timestamped rename.';
        PRINT N'   Collect           [Not yet implemented in Part 1; arrives in Part 4 (first';
        PRINT N'                     collector) and Part 5 (remaining six v0.1 collectors).]';
        PRINT N'                     Takes one snapshot of bounded diagnostic data.';
        PRINT N'   Report            [Not yet implemented in Part 1; arrives in Part 6.]';
        PRINT N'                     Produces Findings + Timeline for a time window.';
        PRINT N'                     Returns at most two result sets.';
        PRINT N'   Status            [Not yet implemented in Part 1; arrives in Part 3.]';
        PRINT N'                     Reports current configuration, capability snapshot,';
        PRINT N'                     run-log summary, and repository size.';
        PRINT N'   Configure         [Not yet implemented in Part 1; arrives in Part 8.]';
        PRINT N'                     Reads/writes FR_Config entries with validation.';
        PRINT N'   Purge             [Not yet implemented in Part 1; arrives in Part 8.]';
        PRINT N'                     Batched retention cleanup. Honors @WhatIf.';
        PRINT N'   CollectAndReport  Documented as non-recommended; ad-hoc use only.';
        PRINT N'                     [Not yet implemented in Part 1.]';
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
        PRINT N'                        persisted (D-128). No-op in Part 1.';
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
        PRINT N'   Part 1 does NOT read DMVs, does NOT create tables, does NOT create an';
        PRINT N'   Agent job, and does NOT write anywhere. Running this procedure with no';
        PRINT N'   parameters cannot harm a server.';
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
              + N' on the v0.1 roadmap. Only Help and';
        PRINT N'   About are functional. All other documented modes return a clear';
        PRINT N'   "not yet implemented" notice naming the part that will deliver them.';
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
    -- All other documented modes: clean "not yet implemented" message.
    --
    -- Per Part 1 acceptance criterion #5, every documented @Mode value must
    -- return either real output or a clear "not yet implemented" message --
    -- never an exception, never silence.
    --
    -- One result set, fixed shape, no side effects.
    -- --------------------------------------------------------------------------
    DECLARE @TargetPart nvarchar(40);
    SET @TargetPart =
        CASE UPPER(@ModeNormalized)
            WHEN N'INSTALL'          THEN N'Part 3'
            WHEN N'UNINSTALL'        THEN N'Part 3'
            WHEN N'STATUS'           THEN N'Part 3'
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
