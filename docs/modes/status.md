# Status mode

Reports installation state, configuration, the rule catalog, recent runs, repository footprint, and the capability snapshot.

## Safety

Read-only; reads only `FR_*` and allow-listed catalogs. Returns multiple result sets (Status is exempt from the two-result-set rule, which applies to Report).

## Parameters

| Parameter | Meaning |
|---|---|
| `(none)` | Status takes no tuning parameters. |

## Result set(s)

Six result sets: installation summary; configuration; rule catalog; recent runs; repository size; capability snapshot.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

## Common failure modes

On a not-installed database, result sets return empty shells (stable shape). See [operations/troubleshooting.md](../operations/troubleshooting.md).

