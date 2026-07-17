# Configure mode

Reads or updates a known `FR_Config` key.

## Safety

Writes only `FR_Config`; validates the key against the known set and integer keys against an integer value; audits the change in `FR_RunLog`. Unknown keys are refused.

## Parameters

| Parameter | Meaning |
|---|---|
| `@ConfigKey` | The key to update. NULL returns all config. |
| `@ConfigValue` | The new value (required when `@ConfigKey` is given). |

## Result set(s)

Read (no key): the full config. Write: one row `Status, ConfigKey, OldConfigValue, NewConfigValue, Message`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure', @ConfigKey = N'SnapshotRetentionDays', @ConfigValue = N'7';
```

## Common failure modes

Unknown key -> `UnknownConfigKey`; non-integer for an integer key -> `InvalidConfigValue`. See [configuration.md](../configuration.md). See [operations/troubleshooting.md](../operations/troubleshooting.md).

