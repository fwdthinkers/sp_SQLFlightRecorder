-- Must trigger FR-LINT-010: a long run of comment lines containing SQL keywords.
-- SELECT 1 AS one
-- SELECT 2 AS two
-- INSERT INTO t VALUES (1)
-- UPDATE t SET x = 1
-- DELETE FROM t
-- EXEC dbo.something
SELECT 1 AS live_code;
