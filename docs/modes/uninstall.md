# Uninstall mode

`Uninstall` removes Part 3 repository objects from the current database.

## Behavior

- Refuses uninstall if an in-progress collect run exists (`FR_RunLog` row with `Mode='Collect'` and `Status='InProgress'`).
- `@WhatIf = 1` returns objects that would be changed and the action (`Drop` / `Rename`), with no changes applied.
- Default (`@PreserveRunLog = 0`): drops core `FR_*` tables in dependency-safe order.
- `@PreserveRunLog = 1` (D-183): renames `FR_RunLog` and `FR_RunLogStep` to timestamped archive names and drops the rest.
- Part 3 intentionally does **not** drop `FR_RunLog_Archive_*` tables.

## Result shape

One row with:

- `Status` (`Uninstalled` or `PartiallyUninstalled`)
- `DroppedCount`
- `RenamedCount`
- `Message`

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @WhatIf = 1;
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @PreserveRunLog = 1;
```
