-- Must trigger FR-LINT-006: bare EXEC(<string>) without sp_executesql.
DECLARE @cmd nvarchar(200) = N'SELECT 1';
EXEC (@cmd);
