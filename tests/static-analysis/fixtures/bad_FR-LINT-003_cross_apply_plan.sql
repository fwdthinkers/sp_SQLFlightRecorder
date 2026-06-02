-- Must trigger FR-LINT-003: CROSS APPLY against the plan DMV is the
-- specific anti-pattern called out by D-046 / D-015.
SELECT TOP (1) p.query_plan
FROM sys.dm_exec_cached_plans c
CROSS APPLY sys.dm_exec_text_query_plan(c.plan_handle, 0, -1) AS p
ORDER BY c.usecounts DESC;
