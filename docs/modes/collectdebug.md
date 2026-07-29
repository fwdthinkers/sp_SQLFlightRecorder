# CollectDebug mode

Validates collector readiness without writing collector rows; the safe way to check a new install.

## Safety

Writes a single `FR_RunLog` row with `Mode='CollectDebug'` and **no** collector/snapshot rows (D-128). Reached via `@Mode='CollectDebug'` or `@Mode='Collect', @Debug=1`.

## Parameters

| Parameter | Meaning |
|---|---|
| `@Debug` | With `@Mode='Collect'`, routes here. |

## Result set(s)

One status row plus a readiness result set listing which `FR_*` tables are present.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectDebug';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect', @Debug = 1;
```

## Common failure modes

Requires Install first. See [operations/troubleshooting.md](../operations/troubleshooting.md).

