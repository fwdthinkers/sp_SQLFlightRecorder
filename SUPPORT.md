# Support

`sp_SQLFlightRecorder` is a community-maintained, MIT-licensed open-source
project. There is **no paid support tier and no support SLA** (D-179). Help is
best-effort from maintainers and the community.

## Before asking

1. Read [docs/user-guide.md](docs/user-guide.md) and run
   `EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';`.
2. Check the [failure-mode catalog](docs/operations/troubleshooting.md) — most
   operational questions (install refused, collect skipped, no findings) are
   answered there.
3. Skim [docs/decisions.md](docs/decisions.md) — many "why does it do X?"
   questions are documented design decisions.

## Where to ask

| Need | Where |
|---|---|
| A bug, false positive/negative, perf regression, or config issue | Open an issue using the matching template (blank issues are disabled). |
| A "how do I…" / usage question | GitHub Discussions (Q&A), if enabled. |
| A security vulnerability | **Do not open a public issue** — see [SECURITY.md](SECURITY.md). |

## Diagnostics to include

- Tool version: `EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';`
- SQL Server version/edition, and whether on-prem / Azure SQL MI / Azure SQL DB.
- `EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';` output (redact anything
  sensitive — do not paste real query text).
