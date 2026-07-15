-- Must trigger FR-LINT-004: BEGIN TRAN forbidden in v0.1 per D-138.
BEGIN TRAN;
SELECT 1 AS one;
COMMIT;
