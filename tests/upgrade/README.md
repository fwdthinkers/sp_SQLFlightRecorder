# Upgrade-path validation

`run-upgrade.sh` proves that installing the current artifact **over** an older
installed repository is non-destructive and needs no schema migration — the
forward-only guarantee (D-038). Release-validation tooling, run with Docker
before tagging; not a per-push CI gate. Build-pipeline only (D-148).

## What it checks
For each prior release it installs the old artifact, seeds data with a
`Collect`, installs the current (working-tree) artifact over it, and asserts:

- install-over returns **Success** (idempotent, D-038);
- `SchemaVersion` is **0.4.0** before and after — i.e. **no persisted DDL
  migration is required**;
- no `FR_*` table is dropped;
- `FR_Snapshot` rows are preserved (count does not shrink);
- every config key a **fresh current install** creates is present afterwards
  (new keys are added by the `IF NOT EXISTS` seed; none are lost — the baseline
  is a fresh install, so agent-job keys that only exist under `@CreateAgentJob=1`
  are correctly not required);
- `Report` still runs against the upgraded repository.

Old artifacts are extracted from git tags at their historical path. A version
with **no tag** is reported `UNAVAILABLE` — never faked — and can be supplied
manually as `tests/upgrade/artifacts/v<version>.sql`. A tag that exists but
whose artifact cannot be extracted is an `ERROR` (fails the run), so a real
regression can never hide behind a skip.

## Run it
```bash
./tests/upgrade/run-upgrade.sh [image]      # default mcr.microsoft.com/mssql/server:2022-latest
```
Requires Docker and a git work tree (preflight fails loudly otherwise). One
container, one database per source version.

## Results — point-in-time record, not live status
Recorded 2026-07-17 against target 2022 with the artifact at
`ToolVersion 0.4.3`. This table is the record of **one past run**: nothing
refreshes it automatically, and it does not necessarily describe the artifact
currently in the working tree. Re-run the harness (above) for current results.

| Source | Result |
|---|---|
| v0.4.0 | **UNAVAILABLE** — no `v0.4.0` tag; pending historical artifact. Drop the file at `tests/upgrade/artifacts/v0.4.0.sql` to include it. |
| v0.4.1 | ✅ all checks pass |
| v0.4.2 | ✅ all checks pass |
| v0.4.3 | ✅ all checks pass |

`21 passed, 0 failed, 1 unavailable`. The upgrade path from every tagged release
to the RC is clean and migration-free; `v0.4.0` remains pending its historical
artifact.
