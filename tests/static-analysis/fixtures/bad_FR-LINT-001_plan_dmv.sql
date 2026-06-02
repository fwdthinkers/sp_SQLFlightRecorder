-- Must trigger FR-LINT-001 for sys.dm_exec_query_plan (also catchable by 003,
-- but 001 alone is enough to satisfy the bad_ fixture contract).
SELECT TOP (1) p.query_plan
FROM sys.dm_exec_cached_plans c
CROSS APPLY sys.dm_exec_query_plan(c.plan_handle) AS p
ORDER BY c.usecounts DESC;
