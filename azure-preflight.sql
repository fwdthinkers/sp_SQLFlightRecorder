SET NOCOUNT ON;

PRINT '=== Target classification ============================================';

SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS CurrentDatabase,
    @@VERSION AS VersionText,
    SERVERPROPERTY(N'EngineEdition') AS EngineEdition,
    SERVERPROPERTY(N'Edition') AS Edition,
    SERVERPROPERTY(N'ProductVersion') AS ProductVersion,
    SERVERPROPERTY(N'ProductLevel') AS ProductLevel,
    SERVERPROPERTY(N'ProductMajorVersion') AS ProductMajorVersion,
    CASE TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition'))
        WHEN 5 THEN N'Azure SQL Database'
        WHEN 8 THEN N'Azure SQL Managed Instance'
        WHEN 2 THEN N'SQL Server Standard/Web/Business Intelligence boxed engine'
        WHEN 3 THEN N'SQL Server Enterprise/Developer/Evaluation boxed engine'
        WHEN 4 THEN N'SQL Server Express boxed engine'
        ELSE N'Other / verify manually'
    END AS TargetClassification;

PRINT '=== Permission checks =================================================';

SELECT
    HAS_PERMS_BY_NAME(NULL, N'SERVER', N'VIEW SERVER STATE') AS HasViewServerState,
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE') AS HasViewDatabaseState,
    IS_MEMBER(N'db_owner') AS IsDbOwner;

PRINT '=== Platform feature probes ==========================================';

SELECT
    DB_ID(N'msdb') AS MsdbDatabaseId,
    OBJECT_ID(N'msdb.dbo.sysjobhistory', N'U') AS MsdbSysJobHistoryObjectId,
    TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) AS EngineEdition,
    CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) = 5 THEN 1 ELSE 0 END AS IsAzureSqlDb,
    CASE WHEN TRY_CONVERT(int, SERVERPROPERTY(N'EngineEdition')) = 8 THEN 1 ELSE 0 END AS IsAzureManagedInstance;