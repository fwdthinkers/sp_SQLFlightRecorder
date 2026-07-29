-- =============================================================================
-- tests/compat/collect-attestation-evidence.sql
-- -----------------------------------------------------------------------------
-- Runs the Tier-2 minimum command set and prints section headers so the output
-- pastes cleanly into a "Version compatibility / Tier-2 attestation" issue.
-- See docs/compatibility/tier2-attestation.md.
--
-- PRECONDITION: first run sp_SQLFlightRecorder.sql in a SANDBOX database to
-- create the procedure, then run this script in that same database.
--
-- Non-invasive: it exercises Install through Uninstall and cleans up after
-- itself (the final Uninstall removes every FR_* object). Use a throwaway DB.
--
-- Azure SQL Database: connect directly to your sandbox database (install is
-- per-DB). Agent/msdb/error-log collectors will report Skipped — that is
-- expected and is exactly what the capability snapshot documents.
-- =============================================================================
SET NOCOUNT ON;
GO
PRINT '=== 1. About (paste this: tool version) ===============================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
GO
PRINT '=== 2. Install =======================================================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
GO
PRINT '=== 3. Status (paste this: capability snapshot result set) ============';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
GO
PRINT '=== 4. Collect #1 ====================================================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
GO
PRINT '=== 5. Collect #2 ====================================================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
GO
PRINT '=== 6. Report (paste this: note the FR_R0026 coverage finding) ========';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
GO
PRINT '=== 7. Purge @WhatIf (read-only preview) =============================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;
GO
PRINT '=== 8. Uninstall (clean removal) =====================================';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';
GO
PRINT '=== done: paste About + Status + each step status into the issue ======';
GO
