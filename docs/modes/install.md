# Install mode

`Install` creates and seeds the Part 3 repository schema in the current database.

## Behavior

- Refuses installation in `master`, `model`, `msdb`, `tempdb`, or `distribution` (D-004 v0.1 constraint).
- Refuses when `DATABASEPROPERTYEX(DB_NAME(), 'Updateability') <> 'READ_WRITE'`.
- Refuses when caller lacks `VIEW SERVER STATE` (D-118).
- Enforces forward-only schema migration (D-038) and blocks downgrade attempts (D-039).
- Creates the 12 v0.1 core `dbo.FR_*` tables idempotently.
- Seeds `FR_Config` defaults and `FR_Rules` catalog rows idempotently.
- Writes one `FR_RunLog` row with `Mode = 'Install'` and terminal `Status` (`Success` / `Error`).
- Does **not** create SQL Agent jobs in Part 3.

## Success result shape

One row with:

- `Status` (`Installed` or `AlreadyInstalled`)
- `DatabaseName`
- `SchemaVersion`
- `TableCount`
- `Message`

## Example

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
```
