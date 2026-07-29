# About mode (alias: Version)

Returns tool version and build metadata as one row, so a DBA can answer "what version is this?" without opening the file.

## Safety

Read-only and inert.

## Parameters

| Parameter | Meaning |
|---|---|
| `@Mode` | `About` or its alias `Version`. |

## Result set(s)

One row: `ToolVersion, BuildDateUtc, SupportedSqlServerRange, ImplementationPart, InvocationUtc`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';
```

## Common failure modes

n/a. See [operations/troubleshooting.md](../operations/troubleshooting.md).

