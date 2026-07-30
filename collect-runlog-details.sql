SET NOCOUNT ON;

PRINT '=== FR_RunLogStep details ============================================';

IF OBJECT_ID(N'dbo.FR_RunLogStep', N'U') IS NULL
BEGIN
    SELECT
        N'FR_RunLogStep does not exist; Install may not have completed.' AS Message;
    RETURN;
END;

SELECT
    rl.RunId,
    rl.Mode,
    rl.Status AS RunStatus,
    rls.StepName,
    rls.Status AS StepStatus,
    rls.RowsCollected,
    rls.Reason,
    rls.ErrorMessage,
    rls.StartUtc,
    rls.EndUtc
FROM dbo.FR_RunLog AS rl
JOIN dbo.FR_RunLogStep AS rls
    ON rls.RunId = rl.RunId
ORDER BY
    rl.RunId,
    rls.RunStepId;