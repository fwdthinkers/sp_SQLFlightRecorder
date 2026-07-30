# Tier-2 attestation process

Tier 2 covers the supported targets that **cannot be containerized in free CI**,
so they are verified by human **attestation** instead of automation (D-121,
D-164).

**Clean Tier-2 targets** — all verified against `v1.0.0` by manual attestation:

- SQL Server 2016 (Windows) — ✅ Verified
- SQL Server 2014 (Windows) — ✅ Verified
- Azure SQL Managed Instance — ✅ Verified (D-196). `EngineEdition 8`,
  `ProductMajorVersion 17`, RTM; `HasMsdb 1`, `HasAgent 1`,
  `HasQueryStoreSupport 1`, `HasBufferPoolSupport 1`, `HasTimeZoneSupport 1`.
  Every core collector succeeded; only `AlwaysOnState` skipped, capability-gated.
- Azure SQL Database — ✅ Verified (D-196) **with expected capability-gated
  skips**. `EngineEdition 5`, `ProductMajorVersion 12`, RTM; `HasMsdb 0`,
  `HasAgent 0`, `HasQueryStoreSupport 1`, `HasBufferPoolSupport 0`,
  `HasTimeZoneSupport 1`; preflight `HasViewServerState` **NULL**,
  `HasViewDatabaseState 1`, `IsDbOwner 1`. `Collect` returned `Success` with
  `AgentJobs`, `BackupHistory`, `Deadlocks` and `AlwaysOnState` skipped by
  design, each reason carried in `FR_R0026`.

Both Azure targets installed 25 core `FR_*` tables plus 5 `FR_v_*` views,
previewed `Purge @WhatIf = 1`, uninstalled cleanly, and left
`RemainingFrObjects = 0`. Full evidence is recorded per target in
[matrix.md](matrix.md).

**No equivalence between them.** Azure SQL Database and Managed Instance are
separate products with materially different capability surfaces; each was
attested on its own and neither result may be read across to the other, or to
on-prem. *SQL Server on Azure VM* is IaaS and is not covered here at all — it
follows its matching on-prem version/platform row.

**Not a clean Tier-2 target — SQL Server 2012 (Windows), legacy best-effort
(D-195).** 2012 was manually exercised on `v1.0.0` and the lifecycle completed:
Install, Report (including `FR_R0026`), Purge `@WhatIf = 1`, and Uninstall all
succeeded. But **both `Collect` runs returned `PartialSuccess`** — the
`SchemaActivity` collector reported `dbsDone=0; dbErrors=1; budgetHit=0`. A
reproducible collector failure disqualifies a target from Verified, so 2012 is
tracked separately as legacy best-effort: expected to run, expected to degrade,
and **never to be described as verified**. A future attestation that clears the
`SchemaActivity` failure could promote it; a passing lifecycle *with* that
failure cannot.

An attestation is a report that the tool completed its lifecycle on one of these
targets, with enough evidence to trust it. **No Tier-2 target is marked Verified
without a real attestation** — the default is Pending, which is a statement of
"untested," not "works" and not "broken." A lifecycle that completes *with* a
collector failure does not earn Verified either; see SQL Server 2012 below. The
current state, with per-target evidence and caveats, is in [matrix.md](matrix.md).

## The vehicle
File a **Version compatibility / Tier-2 attestation** issue
([.github/ISSUE_TEMPLATE/version-compat.yml](../../.github/ISSUE_TEMPLATE/version-compat.yml)).
Blank issues are disabled; this template is the only intake. It doubles as the
compatibility-bug report, so a failed run is filed the same way.

## What an attester must provide
1. **Tool version** — the output of `EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';`.
2. **Target** — SQL Server version + edition + platform, or the Azure tier
   (e.g. "SQL Server 2014 SP3 Standard, Windows Server 2016"; "Azure SQL MI").
3. **Capability snapshot** — the `Status` capability result set (EngineEdition,
   ProductMajorVersion, Platform, HasQueryStoreSupport, HasAgent, …). This is
   what pins *which* target the evidence is for.
4. **Lifecycle results** — the status row from each step of the minimum command
   set below, including any collector that reported **Skipped**/degraded and the
   reason.
5. **FR_R0026 coverage** — the coverage-and-capability summary finding from
   `Report`, which states what was and was not collected.
6. **No secrets** — real query text / server names / credentials removed (the
   template requires this checkbox).

The evidence can be produced in one pass with
[../../tests/compat/collect-attestation-evidence.sql](../../tests/compat/collect-attestation-evidence.sql).

## Minimum command set
Run in a **sandbox database** (Install and Uninstall are exercised). The
procedure itself is created by running `sp_SQLFlightRecorder.sql` first.

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';                 -- 1. version
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';               -- 2. install repo
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';                -- 3. capability snapshot
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';               -- 4. collect
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';               -- 5. collect again
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';                -- 6. report (see FR_R0026)
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;    -- 7. purge preview
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';             -- 8. clean removal
```

A run "counts" when steps 2–8 complete: Install `Success`, both Collects
`Success`/`PartialSuccess` with no `Error` step, Report returns its result sets
including `FR_R0026`, and Uninstall leaves zero `FR_*` objects. Degraded
collectors (e.g. Query Store off, no Agent on Express/Azure SQL DB) are expected
and do **not** fail an attestation — they are the point of the capability
snapshot.

## Status definitions
| Status | Meaning |
|---|---|
| **Verified** | A passing attestation for the current major, with all required evidence, has been received and recorded in the matrix. |
| **Pending** | No attestation received yet. The default for every Tier-2 target. Not a claim of breakage. |
| **Failed** | An attestation (or bug report) showed a lifecycle failure on that target. Tracked as an open compatibility bug; the matrix links it. |
| **Stale** | Previously Verified, but no re-attestation for 3 minor releases — downgraded to *Unverified* (see below). |

## Staleness and re-attestation (D-164, D-190)
- A fresh Tier-2 attestation issue is opened **each RC** (D-164), so every
  release cycle prompts re-attestation.
  - **Implementation status (2026-07-28):** this is a **manual maintainer step**
    today. D-164 describes it as auto-opening, but no workflow creates the
    issues — `release.yml` builds and publishes only. Until that is automated,
    a maintainer must open them by hand after each RC (use the `version-compat`
    issue template, D-164), or the cycle silently fails to prompt anyone.
- **Missing for 3 minors** → the target moves to **Unverified** (Stale).
- **Missing for 6 minors** → a **deprecation discussion** is opened for that
  target.
- The whole process is **on probation for the first 18 months post-1.0** (D-190):
  the maintainers will publicly review how many attestations arrived, which
  targets went Unverified, and whether the staleness cascade actually fired. If
  it produced no useful signal, it is replaced in a v1.x minor.

## v1.0 and Tier-2 status (D-192)
Tier-2 attestation is **not** a v1.0 release gate. The earlier rule — at least
4 of the 5 targets attested before v1.0.0 (§11.6) — is superseded by **D-192**:
final `v1.0.0` may ship with every Tier-2 target **Unverified**.

What that obliges in exchange:
- **The two tiers are never merged into one claim.** Tier-1 results come from
  automated CI evidence; Tier-2 targets with no attestation are *pending /
  unverified*. Any statement about compatibility must make clear which of the
  two it rests on.
- **No unattested target is described as verified** — not "verified", not
  "tested", not "supported (as tested)", not "equivalent to Tier 1". SQL Server
  2012, 2014 and 2016 in particular must not be presented as verified until a
  real attestation is recorded here and in the matrix.
- *Unverified* keeps its meaning throughout: **untested**, not "works" and not
  "broken".

Attestations remain welcome and wanted — they are ordinary post-1.0 work under
the D-164 cadence and the D-190 18-month review, not a blocked release gate.

## Not this process
Tier-3 community reports (via Discussions) are non-binding and carry **no**
formal status (D-166); they are useful signal, not attestation.
