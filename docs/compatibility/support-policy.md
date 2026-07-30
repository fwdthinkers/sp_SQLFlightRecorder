# Support policy — "1.0 is forever"

What a v1.0.0 user can rely on, and for how long. The guiding promise (§11.8):
**once a contract ships in 1.0, it does not break within the 1.x line.** This
page states those promises precisely and — just as importantly — what is *not*
promised, so no one over-relies on an untested target.

## Compatibility promises (hold for all of v1.x)
- **Output contracts are frozen.** The Findings result set (16 columns, D-067),
  the Timeline result set (12 columns, D-071), and the Markdown report header
  (14 keys, D-085) do not change shape within v1.x. Columns are not removed,
  renamed, or reordered; new optional signals arrive only as *added* trailing
  content in a minor, never as a break.
- **Rule IDs are stable.** A `RuleId` (e.g. `FR_R0007`) is never renamed or
  reused, and a retired/disabled ID is reserved forever (D-089/D-090). The
  Disabled plan-analysis IDs `FR_R0030`–`FR_R0034` stay reserved and disabled by
  design (D-015/046/082/136) — they are not a roadmap item.
- **Schema is forward-only.** `SchemaVersion` advances only additively; upgrades
  never require a destructive migration and never drop existing `FR_*` data
  (D-038). Installing a newer artifact over an older repository is safe and
  in-place — validated by `tests/upgrade/run-upgrade.sh`.
- **The capability key set is closed and documented per release**, additive in
  minors (D-127) — old persisted snapshots keep rendering correctly.

## Versioning and cadence
Project-specific semver (D-171): **major** = a contract break, **minor** =
additive, **patch** = fixes. Cadence (D-172): patches as needed; minors target
quarterly (6-monthly floor); a major only every 18–24 months and only after at
least one minor of deprecation warnings.

## Supported range and platforms (D-195)
**Primary supported range: SQL Server 2014 through 2025.**

| Range | Platforms | What is promised |
|---|---|---|
| **2017–2025** | Linux **and** Windows | The supported core. Linux is verified per-push in automated Tier-1 CI. Windows runs the same capability-based code path — the tool branches on capability flags and `EngineEdition`, never on operating system — and is manually attested where evidence exists. |
| **2014 and 2016** | **Windows only** | Manual Tier-2 targets, both **verified against v1.0.0**. Supported, but on the strength of a single manual lifecycle run each, not continuous CI. |
| **2012** | **Windows only** | **Legacy best-effort — not a normally supported target.** It runs and the v1.0.0 lifecycle completed, but with a known `SchemaActivity` collector failure and `PartialSuccess` collect runs. Use it knowing schema-activity data will be incomplete. |

Older than 2012 is out of scope entirely, as are Synapse, Fabric, Big Data
Clusters, and Stretch (D-108).

> The released `v1.0.0` artifact reports `SupportedSqlServerRange` as
> "SQL Server 2012–2025". That statement is not false — 2012 is still supported
> on a best-effort basis — but it predates this policy and does not carry the
> qualification. The artifact is immutable; this page is authoritative.

## Verification posture
- **Tier 1 — automated, blocking (D-120).** The six verified targets in the
  [compatibility matrix](matrix.md): SQL Server 2017/2019/2022/2025 Developer and
  2022 Express/Standard, on Linux containers. Exercised on every push.
- **Tier 2 — manual attestation, best-effort (D-121/D-164).** SQL Server
  2014/2016 (Windows) are **Verified** on manual v1.0.0 evidence; SQL Server 2012
  (Windows) is **legacy best-effort** with a known limitation; Azure SQL Managed
  Instance and Azure SQL Database remain **Unverified until a real attestation
  lands** (see [tier2-attestation.md](tier2-attestation.md)). Tier 2 is a
  best-effort signal, **not a guarantee of support**, and its status can go stale
  (D-164).
- **Tier 3 — community reports (D-166).** Non-binding; no formal status.

**No Azure equivalence is claimed.** Azure SQL DB/MI are Tier-2 pending; expect
degraded behavior on Azure SQL DB (per-DB install, no Agent/msdb/error log,
D-109) until an attestation says otherwise.

## Experimental / pending
- Azure SQL Managed Instance and Azure SQL Database, until attested.
- SQL Server 2012 — permanently best-effort unless an attestation clears the
  `SchemaActivity` failure.
- `CriticalWaitTypes` config honoring is deferred to **v1.1** (D-105); FR_R0003
  uses the hard-coded critical-wait list until then.
- Plan-level analysis is **not** experimental-pending — it is permanently out of
  scope as plan-XML shredding (D-015/046/082/136).

## What can be deferred past v1.0
- Tier-2 attestations — never a release gate (D-192); remaining targets can
  attest later without blocking the line.
- The historical `v0.4.0` upgrade path (no public `v0.4.0` tag exists; supply
  `tests/upgrade/artifacts/v0.4.0.sql` to validate it — otherwise it is
  documented as pending, not claimed).
- Additional collectors and rules — they arrive in minors, additively.

## What is deliberately *not* promised (D-146)
Consistent with the charter's "skeptical and practical" stance, the tool does
**not** promise correct or bounded behavior under extreme workloads, nor
equivalence on any target that Tier 1 does not automatically verify. Those cases
degrade honestly (capability snapshot + coverage findings) rather than pretend.
