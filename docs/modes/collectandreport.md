# CollectAndReport mode

Runs a bounded Collect then a Report in one call. **Documented as non-recommended** (D-024): the real value is scheduled Collect + on-demand Report.

## Safety

Re-invokes the procedure for Collect then Report; `@Debug` routes the inner Collect to CollectDebug. Same safety as the two modes it chains.

## Parameters

| Parameter | Meaning |
|---|---|
| `@TopN / @IncludeQueryPlans / @Debug` | Forwarded to Collect. |
| `@DatabaseName / @StartTime / @EndTime / @MinSeverity / @MaxFindings / @OutputFormat` | Forwarded to Report. |

## Result set(s)

Collect's status row, then Report's result sets.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectAndReport';
```

## Common failure modes

Requires Install first. Prefer scheduled Collect + on-demand Report. See [operations/troubleshooting.md](../operations/troubleshooting.md).

