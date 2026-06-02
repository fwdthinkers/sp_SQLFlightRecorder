-- Models the shape of src/sp_SQLFlightRecorder.sql at Part 1: no DMV reads,
-- no BEGIN TRAN, only the install stub's EXEC(...) with an allow annotation,
-- and ordinary PRINT / SELECT-of-literals. Must produce zero findings.
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.sp_fake', N'P') IS NULL
    EXEC (N'CREATE PROCEDURE dbo.sp_fake AS RETURN 0;');  -- lint:allow FR-LINT-006 reason: install stub
GO

ALTER PROCEDURE dbo.sp_fake
    @Mode nvarchar(30) = N'Help'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET LOCK_TIMEOUT 5000;
    SET DEADLOCK_PRIORITY LOW;

    DECLARE @ToolVersion nvarchar(30) = N'0.0.0-fixture';

    IF UPPER(@Mode) = N'HELP'
    BEGIN
        PRINT N'help text';
        RETURN;
    END;

    SELECT @ToolVersion AS ToolVersion;
    RETURN;
END;
GO
