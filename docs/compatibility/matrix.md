# Compatibility matrix

Primary supported range: **SQL Server 2014 through 2025**, on-prem and cloud, with
capability-driven degradation (D-108 as amended by **D-195**). Synapse, Fabric,
Big Data Clusters, and Stretch are out of scope.

> The released `v1.0.0` artifact reports `SupportedSqlServerRange` as
> "SQL Server 2012–2025". That is not wrong — 2012 still runs, best-effort — but
> it predates this policy and is coarser than it. The artifact is immutable; this
> page carries the qualification.

## Version × platform grid
Every supported combination has its own row — no "2017+" shorthand — so checking
one version on one platform never requires inferring from a range.

| Version | Platform | Tier | Status | Evidence and caveats |
|---|---|---|---|---|
| SQL Server 2017 | Linux | Tier 1 | ✅ Verified (automated) | `ci-tier1` per-push + local six-target matrix. |
| SQL Server 2017 | Windows | — | Supported, capability-based | No attestation on file. Same code path as Linux — branching is on capability flags and `EngineEdition`, never on OS. |
| SQL Server 2017 | Azure VM (IaaS) | — | Supported as the matching row above | Inherits the Linux or Windows row for this version; not separately verified. |
| SQL Server 2019 | Linux | Tier 1 | ✅ Verified (automated) | `ci-tier1` per-push + local six-target matrix. |
| SQL Server 2019 | Windows | — | Supported, capability-based | No attestation on file. |
| SQL Server 2019 | Azure VM (IaaS) | — | Supported as the matching row above | Inherits the Linux or Windows row for this version. |
| SQL Server 2022 | Linux | Tier 1 | ✅ Verified (automated) | `ci-tier1` per-push + local six-target matrix; Developer, Express and Standard editions. |
| SQL Server 2022 | Windows | — | Supported, capability-based | No attestation on file. |
| SQL Server 2022 | Azure VM (IaaS) | — | Supported as the matching row above | Inherits the Linux or Windows row for this version. |
| SQL Server 2025 | Linux | Tier 1 | ✅ Verified (automated) | `ci-tier1` per-push + local six-target matrix. |
| SQL Server 2025 | Windows | — | Supported, capability-based | No attestation on file. |
| SQL Server 2025 | Azure VM (IaaS) | — | Supported as the matching row above | Inherits the Linux or Windows row for this version. |
| SQL Server 2016 | Windows **only** | Tier 2 | ✅ Verified (manual, v1.0.0) | See Tier 2 below. On Azure VM, treat as this row. |
| SQL Server 2014 | Windows **only** | Tier 2 | ✅ Verified (manual, v1.0.0) | See Tier 2 below. On Azure VM, treat as this row. |
| SQL Server 2012 | Windows **only** | Tier 2 | ⚠️ Legacy best-effort | Not a clean verified target — `SchemaActivity` fails, collects return `PartialSuccess` (D-195). |
| Azure SQL Managed Instance | Azure PaaS | Tier 2 | ✅ Verified (manual, v1.0.0) | `EngineEdition 8`. Full collector set; only `AlwaysOnState` skipped, capability-gated. |
| Azure SQL Database | Azure PaaS | Tier 2 | ✅ Verified (manual, v1.0.0) | `EngineEdition 5`. Verified **with expected capability-gated skips** — see Tier 2 below. |

**Hosting models are not interchangeable.** *SQL Server on Azure VM* is **IaaS**:
the ordinary engine on a VM you administer, so it behaves as the matching on-prem
row for its version and OS and is not verified separately. *Azure SQL Managed
Instance* and *Azure SQL Database* are **PaaS**, are different products with
different capability surfaces, and are attested individually below.

**No equivalence is claimed between Azure SQL Database and Managed Instance.**
They were attested separately and their evidence differs materially — MI reports
`HasMsdb 1` / `HasAgent 1` and runs the full collector set, while Azure SQL DB
reports `HasMsdb 0` / `HasAgent 0` and skips four collectors by design. Neither
result may be read across to the other, and neither may be read across to
on-prem.

> **Verification tiers.** **Tier 1** = automated CI on Linux containers, blocking
> (D-120). **Tier 2** = manual attestation for targets that cannot be
> containerized for free, not merge-blocking (D-121/D-164). **Tier 3** =
> community reports (non-binding, D-166). A target's status is only as strong as
> the tier that verified it.

## Tier 1 — verified (automated Linux containers)
The hosted `ci-tier1` workflow verifies the four Developer targets on every
push; the six-target Docker matrix (`run-local-tier1.sh`) additionally covers
the 2022 Express and Standard editions before each release (FAIL=0 through
v0.4.1 / v0.4.2 / v0.4.3). The v1.0.0-rc artifact was re-verified on the 2022
Developer, Express, and Standard editions, and its upgrade path from every
tagged release was validated (`tests/upgrade/run-upgrade.sh`).

| Version | Edition | EngineEdition | Platform | Verified by |
|---|---|---|---|---|
| SQL Server 2017 | Developer | 3 | Linux | ci-tier1 + local matrix |
| SQL Server 2019 | Developer | 3 | Linux | ci-tier1 + local matrix |
| SQL Server 2022 | Developer | 3 | Linux | ci-tier1 + local matrix |
| SQL Server 2022 | Express | 4 | Linux | local matrix |
| SQL Server 2022 | Standard | 2 | Linux | local matrix |
| SQL Server 2025 | Developer | 3 | Linux | ci-tier1 + local matrix |

**Other editions.** `Standard` (EngineEdition 2) and `Express` (EngineEdition 4)
are verified above on 2022; Express cascades compression off (D-034) and has no
SQL Agent, so job creation is skipped with a status row (D-116). **Enterprise**
reports `EngineEdition = 3`, the same value as Developer, and the tool branches
on capabilities and EngineEdition — never on edition name — so Developer
coverage is *expected* to carry to Enterprise. Enterprise is not separately
containerized, so it is not independently verified here; this is a compatibility
expectation, not a verified-equivalence claim.

## Tier 2 — manual attestation (Windows and Azure)
These cannot be containerized in CI; status comes from attestations filed via
the **version-compat** issue template (D-164) — see
[tier2-attestation.md](tier2-attestation.md) for the process. Until an
attestation arrives, status is **Unverified** — not a claim of breakage, only of
untested.

| Target | Status | Evidence and caveats |
|---|---|---|
| SQL Server 2016 (Windows) | ✅ Verified — manual, v1.0.0 | EngineEdition 2, ProductMajorVersion 13, ProductLevel SP2. Install, Collect ×2, Report (incl. `FR_R0026`), Purge `@WhatIf`, Uninstall all Success. Query Store supported but not enabled on the tested databases; Always On not enabled; ErrorLog and BufferPool collectors left disabled by default. |
| SQL Server 2014 (Windows) | ✅ Verified — manual, v1.0.0 | EngineEdition 3, ProductLevel RTM. Same lifecycle, all Success. Query Store unsupported and time-zone support unavailable, both as expected; Always On not enabled. Note: `ProductMajorVersion` came back **blank** in the capability snapshot, so keep external `ProductVersion` evidence for this target. |
| SQL Server 2012 (Windows) | ⚠️ Legacy best-effort — **not** a clean verified target | EngineEdition 3, ProductLevel RTM. Lifecycle completes — Install, Report (incl. `FR_R0026`), Purge `@WhatIf`, Uninstall all Success — but **both Collect runs returned `PartialSuccess`**: the `SchemaActivity` collector reported `dbsDone=0; dbErrors=1; budgetHit=0`. Expect degraded schema-activity data (D-195). |
| Azure SQL Managed Instance | ✅ Verified — manual, v1.0.0 | `EngineEdition 8`, `ProductMajorVersion 17`, `ProductLevel RTM`; `IsAzureManagedInstance 1`, `IsAzureSqlDb 0`. Capabilities: `HasMsdb 1`, `HasAgent 1`, `HasQueryStoreSupport 1`, `HasBufferPoolSupport 1`, `HasTimeZoneSupport 1`. Install Success (25 core `FR_*` tables + 5 `FR_v_*` views), Collect ×2 Success, Report incl. `FR_R0026`, Purge `@WhatIf` preview, Uninstall Success, `RemainingFrObjects = 0`. All core collectors succeeded; only `AlwaysOnState` skipped, capability-gated. Tested against database `SQLFR_Tier2_AzureMI`. |
| Azure SQL Database | ✅ Verified — manual, v1.0.0, **with expected capability-gated skips** | `EngineEdition 5`, `ProductMajorVersion 12`, `ProductLevel RTM`; `IsAzureSqlDb 1`, `IsAzureManagedInstance 0`. Capabilities: `HasMsdb 0`, `HasAgent 0`, `HasQueryStoreSupport 1`, `HasBufferPoolSupport 0`, `HasTimeZoneSupport 1`. Preflight: `HasViewServerState` **NULL**, `HasViewDatabaseState 1`, `IsDbOwner 1`. Install Success (25 core `FR_*` tables + 5 `FR_v_*` views), Collect ×2 Success, Report incl. `FR_R0026` carrying the skip reasons, Purge `@WhatIf` preview, Uninstall Success, `RemainingFrObjects = 0`. **Expected skips, all normal on this platform:** `AgentJobs` (no msdb/Agent), `BackupHistory` (no msdb), `Deadlocks` (no `system_health` ring buffer on Azure SQL DB), `AlwaysOnState` (not enabled). Tested against database `sqlfr`. |

**Tier-2 "Verified" is not Tier-1 verified — the difference matters.** Every
Tier-2 row rests on a **single manual lifecycle run**, recorded above: one run,
one machine, one point in time, performed by a human. Tier 1 is an automated gate
that re-runs on every push and blocks the build when it fails. A Tier-2 target
can regress silently and nothing will notice until someone runs it again
(D-164 staleness applies). The evidence is real and the targets are believed
good; they are not continuously guarded.

**No release gate (D-192).** Tier-2 attestation does not gate a release. `v1.0.0`
shipped with every Tier-2 target *Unverified*; 2014, 2016 (D-195) and then Azure
MI and Azure SQL DB (D-196) were attested afterwards and upgraded here on
evidence — exactly the path D-192 requires, where status improves only when
someone produces a run. Attestation collection continues: the staleness policy
(D-164) moves a target back to *Unverified* after 3 minors without a fresh
attestation and opens a deprecation discussion after 6; the process is on an
18-month post-1.0 review (D-190).

## How to contribute an attestation
Open a **Version compatibility / Tier-2 attestation** issue with your Install →
Collect → Report → Uninstall results and the capability snapshot. See
[tier2-attestation.md](tier2-attestation.md) and
[.github/ISSUE_TEMPLATE/version-compat.yml](../../.github/ISSUE_TEMPLATE/version-compat.yml).

---
*Generated by `scripts/gen-compat-matrix.py` (D-165/D-169) — edit the target
tables in that script (or let CI regenerate) rather than this file. The
doc-coverage job runs `--check` and fails if this page drifts from the generator.*
