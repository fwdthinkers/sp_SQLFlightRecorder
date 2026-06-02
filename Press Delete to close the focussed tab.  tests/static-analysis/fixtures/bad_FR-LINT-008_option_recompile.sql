-- Must trigger FR-LINT-008: OPTION (RECOMPILE) without allow marker.
SELECT TOP (1) name
FROM sys.databases
ORDER BY database_id
OPTION (RECOMPILE);
