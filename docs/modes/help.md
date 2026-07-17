# Help mode

Prints usage, the mode list, parameters, and the charter pillars to the Messages tab. This is the **default** mode, so accidentally executing the procedure does nothing harmful (D-003).

## Safety

Read-only and inert. No repository, no DMV reads. Output is via PRINT (Messages tab), not a result set.

## Parameters

| Parameter | Meaning |
|---|---|
| `(none)` | Help ignores other parameters. |

## Result set(s)

No result set; text on the Messages tab.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder;
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';
```

## Common failure modes

If your client suppresses PRINT output, use `About` for a machine-readable one-row result instead. See [operations/troubleshooting.md](../operations/troubleshooting.md).

