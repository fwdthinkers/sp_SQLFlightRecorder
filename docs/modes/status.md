# Status mode

`Status` reports repository installation state and metadata.

## Result sets (always returned in this order)

1. **InstallationSummary** (1 row)
   - `DatabaseName`, `SchemaVersion`, `InstalledOnUtc`, `InstalledBy`, `TableCount`, `IsInstalled`, `Message`
2. **Configuration** (`FR_Config`, ordered by `ConfigKey`)
3. **RuleCatalog** (`FR_Rules`, ordered by `RuleId`)
4. **RepositorySize** (one row per existing Part 3 `FR_*` table)
   - `TableName`, `RowCount`, `ReservedKb`, `DataKb`, `IndexKb`
5. **RunLogSummary** (1 row)
   - `LastRunUtc`, `LastRunMode`, `LastRunStatus`, `RunsLast24h`, `ErrorsLast24h`
6. **CapabilitySnapshot** (shape-only placeholder in Part 3)
   - `KeyName`, `KeyValue`

If the tool is not installed (`FR_Config` missing), `InstallationSummary` reports `IsInstalled = 0` and the other result sets are returned as empty shape-compatible sets.

## Example

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```
