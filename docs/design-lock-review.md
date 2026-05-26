# Design Lock / Compliance Review

**Date:** 2026-05-26
**Reviewer posture:** Skeptical, charter-literal, no benefit-of-the-doubt.
**Source of truth:** `docs/design.md`, `docs/decisions.md` (D-001 through D-187 at time of review).
**Outcome of review:** Design approved for v0.1 implementation planning. Three new tracking decisions added (D-188, D-189, D-190).

---

## Part 1 — Per-requirement compliance checklist

Each of the 18 Master Charter requirements is graded **PASS**, **RISK**, **MISSING**, or **NEEDS DECISION**.

### 1. Pure T-SQL only — **PASS**

Shipped artifact is a single `.sql` file (D-110, D-152). Rules read repository tables only (D-014). Dynamic SQL is the only branching mechanism for version-conditional code (D-112). External tooling (Python, PowerShell) is explicitly confined to the CI build pipeline and never required for install or use (D-148).

### 2. No required CLR, PowerShell, external tools, agents, or services — **PASS**

No CLR mentioned anywhere. SQL Agent job creation is opt-in (D-005). External CI tooling is build-pipeline-only (D-148). User install requires only SSMS/ADS + a writable instance (D-187). No webhook, no notification service, no GUI (D-019).

### 3. No permanent security/configuration changes by default — **PASS**

Charter pillar honored explicitly:
- No XE sessions in v1 (D-021)
- Agent job opt-in (D-005)
- `master` install opt-in (D-004)
- Error log scrape opt-in (D-020, D-060)
- Buffer-pool collector opt-in (D-051)
- CHECKDB capture opt-in
- `@IncludeQueryPlans` per-call opt-in (D-142)
- Sysadmin discouraged as baseline (D-118)
- No `sp_configure`, `ALTER SERVER`, `ALTER DATABASE`, or `KILL` in the safety checklist (D-176)

### 4. Optional changes are safe, documented, and reversible — **PASS**

- `Uninstall` drops everything by default (D-183); `@PreserveRunLog=1` opt-in archives rather than deleting silently
- `Install` is idempotent
- Forward-only schema migrations (D-038) preserve snapshot data
- Every opt-in surfaces in `Help` and `Status` with documented cost (D-142)
- Permission probes verified at both Configure-time and Collect-time (D-060)

### 5. Collection normally completes in 30 seconds or less — **PASS (with documented risk)**

Operating envelope codified (D-131, D-043): median 2–8 s, hard cap 30 s. Cooperative timeout (D-010); QS collector capped at 50% of budget (D-045). CI cost-regression test enforces ≤10 s on synthetic workload (D-143).

**Risk flag:** synthetic workloads do not capture pathological production cases (acknowledged in §9.10.4); validation relies on FR_R0026 and community feedback. Documented honestly per D-146. **Tracked by D-188.**

### 6. No blocking, no heavy workload, no user-table scans — **PASS**

- No reads from user-database tables anywhere (§9.3.3, D-137)
- `READ UNCOMMITTED` session-wide (D-017); `LOCK_TIMEOUT 5000` defense-in-depth (D-133); `DEADLOCK_PRIORITY LOW` (D-134)
- Forbidden DMV list enforced by CI static analysis (D-136, D-144)
- No `CROSS APPLY sys.dm_exec_query_plan` (D-046)
- `dm_tran_locks` only for known blockers, top-50 (D-047)
- No cursors, no `WITH RECOMPILE` (D-138)
- All external SELECTs must have explicit `TOP(N) ORDER BY` or be in the small-DMV allow-list (D-137)

### 7. Single-script model — **PASS**

D-110: one file identical for every target, no conditional compilation. D-152: if source ever splits for maintainability, build step concatenates into a single shipped artifact. User never sees more than one file.

### 8. Single entry point / stored procedure design — **PASS**

`dbo.sp_SQLFlightRecorder` with `@Mode` dispatch (D-001, D-002). All eight v1 modes route through the single proc. Internal helper procs are namespaced (`sp_SQLFlightRecorder_<Phase>_<Area>`, D-154) but are implementation detail, not a second entry point.

### 9. Report mode returns no more than two result sets — **PASS**

D-006 explicit. Findings (16 cols, D-067) + Timeline (12 cols, D-071). Markdown output (D-079) is a single-column variant, still ≤2 result sets. `@IncludeQueryPlans=1` adds plan XML to existing rows, not a new result set (D-082).

### 10. SQL Server 2012 through 2025 compatibility — **PASS (with documented test-tier asymmetry)**

D-108 declares the range. Capability-driven branching (D-008, D-111). Dynamic SQL discipline (D-112). Tier 1 CI covers 2017/2019/2022/2025 (D-120); 2012/2014/2016 covered by Tier 2 manual attestation (D-121, D-164).

**Risk flag:** 2012/2014/2016 are not automated-tested. Honesty mechanism (matrix badge, D-165) makes this visible to users; staleness policy (D-164) prevents indefinite rot. Compliant with charter intent but materially weaker testing on the three oldest versions. **Tracked by D-190.**

### 11. Windows, Linux, cloud VM support — **PASS**

§8.1 supported list. Linux-specific perf-counter prefix normalization (D-117). Cloud VMs treated identically to on-prem (no cloud-vendor APIs called, per charter "no external collectors").

### 12. Azure SQL DB / Managed Instance graceful degradation — **PASS**

D-109 Azure SQL DB explicitly "heavily degraded but supported"; per-database install, honest declaration at Install time. MI fully supported with TRY/CATCH around msdb (§8.5). Tier 2 attestation includes both (D-121). FR_R0026 surfaces every capability gap.

### 13. Minimal storage — **PASS (with documented risk)**

- 15 tables (D-025), bounded by design
- `PAGE` compression default (D-034)
- No `NVARCHAR(MAX)` on hot rows (D-040)
- Wait-stats ignore list bounds the largest table (D-033, D-057)
- `MaxRowsPerCollector = 50` default (D-181)
- Retention configurable; default 7 days (§4.2)
- Batched purge with abort-safety (D-139)
- `Status` mode surfaces growth trend

**Risk flag:** "Minimal" is not defined numerically; §4.2 estimates 200 MB – 1.5 GB at default retention but this is modeled, not measured at scale. **Tracked by D-188.**

### 14. Clear findings, recommendations, severity, confidence, and evidence type — **PASS (with documented risk)**

D-013: every finding carries Severity + Confidence + EvidenceType. 16-column Findings contract (D-067). Severity is per-rule constant (D-069, D-091). Wording rules enforced at code review (D-076). Synthetic "no findings" row always appears (D-077, D-083). Evidence cap with attribution preservation (D-084).

**Risk flag:** Wording compliance is human-enforced (code review + PR template checklist D-157 + two-reviewer rule D-158). No automated wording linter. **Tracked by D-189.**

### 15. No automatic fixes or risky recommendations — **PASS**

Safety checklist (D-176) explicitly bans `KILL`, `sp_query_store_force_plan`, `DBCC FREEPROCCACHE`, NOLOCK recommendations, shrink, "root cause" claims. Wording rules (D-076) operationalize this. Drill-down queries in `MoreInfo` are read-only, bounded, and forbidden from including plan-forcing or mutation procs (D-086). FR_R0013 explicitly states "NOLOCK is not a remedy"; FR_R0022 explicitly states "shrinking the log is not a fix."

### 16. Deterministic rule engine, no AI magic — **PASS (with documented risk)**

D-012 explicit. Deterministic pipeline (D-062). Baselines are transparent 24h median, not ML (D-092). Rules read repo only, ordered by `RuleId` ascending, no inter-rule deps (D-100). Golden output tests assert byte-identical determinism (D-122). No anomaly detection, no prediction (§7.10).

**Risk flag:** Baseline-relative rules (D-092) use a transparent 24h median. This is statistical, not ML, and is documented as such in the rule docs (D-161). Skeptics could mischaracterize this as anomaly detection. **Tracked by D-189.**

### 17. Open-source maintainability — **PASS**

Section 10 fully designed. Coding style codified (D-153). Rule contribution format requires positive + negative tests + docs + wording self-review (D-160, D-161). Safety checklist as standalone doc (D-176). Auto-generated compatibility matrix (D-165) and rules index (D-169). Two-reviewer rule for shipped artifact (D-158). Governance: lazy consensus + 14-day discussion for major decisions (D-177). MIT license, no CLA at v1 (D-179).

### 18. MVP does not overreach — **PASS**

§11.2 v0.1 scope is genuinely minimal: 7 collectors, 6 rules, 8 modes, single-DB install path. §11.2.3 binding exclusion list is long and concrete. §11.8 scope-creep prevention checklist requires "what gets removed to make room?" before any addition. §11.6.3 "no new anything" for v1.0 is binding.

---

## Part 2 — Compliance summary

| Requirement | Status |
|---|---|
| 1. Pure T-SQL only | **PASS** |
| 2. No required CLR/PS/external/agents/services | **PASS** |
| 3. No permanent security/config changes by default | **PASS** |
| 4. Optional changes safe, documented, reversible | **PASS** |
| 5. Collection normally ≤ 30 seconds | **PASS** (risk tracked by D-188) |
| 6. No blocking / heavy workload / user-table scans | **PASS** |
| 7. Single-script model | **PASS** |
| 8. Single entry point / stored procedure | **PASS** |
| 9. Report ≤ two result sets | **PASS** |
| 10. SQL Server 2012–2025 compatibility | **PASS** (risk tracked by D-190) |
| 11. Windows / Linux / cloud VM support | **PASS** |
| 12. Azure SQL DB / MI graceful degradation | **PASS** |
| 13. Minimal storage | **PASS** (risk tracked by D-188) |
| 14. Clear findings + severity + confidence + evidence | **PASS** (risk tracked by D-189) |
| 15. No automatic fixes or risky recommendations | **PASS** |
| 16. Deterministic rule engine, no AI magic | **PASS** (risk tracked by D-189) |
| 17. Open-source maintainability | **PASS** |
| 18. MVP does not overreach | **PASS** |

**No MISSING items. No NEEDS DECISION items.**

All 18 charter requirements pass. The design is **compliant in the charter-literal sense**.

---

## Part 3 — Required summaries

### 3.1 Requirements fully satisfied

All 18. No requirement is missing or unaddressed. Six are PASS-with-documented-risk; all six risks are now explicitly tracked by D-188, D-189, or D-190.

### 3.2 Requirements at risk (residual risks after lock)

| # | Requirement | Risk | Severity | Tracked by |
|---|---|---|---|---|
| 5 | 30-second collect cap | Synthetic CI workload cannot reach pathological production cases | Low | D-188 |
| 10 | 2012–2025 compatibility | Tier 1 CI does not cover 2012/2014/2016; relies on Tier 2 manual attestation | Medium | D-190 |
| 13 | Minimal storage | "Minimal" is undefined numerically; estimates are modeled, not measured | Low | D-188 |
| 14 | Clear findings (wording) | Wording compliance is human-enforced; no automated linter | Low | D-189 |
| 16 | No AI magic (baseline math) | 24h-median baselines could be mischaracterized as anomaly detection | Low | D-189 |

The mitigations are real (PR template, two-reviewer rule, FR_R0026 transparency, matrix badge). The risks are *residual*, not unaddressed.

### 3.3 Remaining open questions

**None at the time of review.** All 40 questions raised during design (Q-001 through Q-040) are resolved. See `docs/open-questions.md` for current state.

### 3.4 Decisions that must be locked before implementation

All 187 decisions are status **Locked** with the following exceptions, which are intentional and not blockers:

| ID | Status | Why it's not a blocker |
|---|---|---|
| D-181 | Tentative | `MaxRowsPerCollector = 50` is a runtime-configurable default; tuning is a v0.2+ concern based on telemetry. Ship with 50, revisit. |
| D-180 (partial) | `@TimeZone` parameter deferred to v0.4 | v0.1–v0.3 use server local time; the deferred parameter is a strict addition, not a redesign |
| D-182 | Deferred to v0.2/v0.3 | Demo data mode is contributor convenience, not user-facing MVP |
| D-184 | Deferred to v0.2 | `FR_v_*` view layer; deliberately held until base schema has shipped one release |

**Nothing additional needs to be locked before implementation begins.**

The review added three new decisions (D-188, D-189, D-190). These are tracking commitments that operationalize the residual risks above. They do not change v0.1 implementation scope.

### 3.5 Items deferred to later versions

Confirmed deferrals, per the phased roadmap (§11):

**Deferred to v0.2:**
- 6 collectors: tempdb, memory, Agent jobs, backup history, AG state, deadlocks
- 8 rules: FR_R0007–FR_R0014
- `FR_v_*` view layer (D-184)
- Tier 2 attestation activation (D-164)
- Compatibility matrix badge (D-165)
- Coverage rule FR_R0026 full form

**Deferred to v0.3:**
- 4 collectors: QS top-N, plan cache headlines, error log opt-in, schema/stats
- 6 rules: FR_R0015–FR_R0020
- QS drilldown emission (D-086)
- Demo data mode (D-182, latest possible)
- Per-DB capability probe

**Deferred to v0.4:**
- 2 collectors: HA-other, opt-in buffer pool
- 6 rules: FR_R0021–FR_R0026 (full)
- `@TimeZone` parameter (D-180)
- `CriticalWaitTypes` honoring (D-105) — actually slips to v1.1
- Two-maintainer wording review pass

**Deferred to v1.0:**
- Hardening, docs completeness, full Tier 1 matrix, Tier 2 closeout, wording lock

**Deferred to v1.0 (newly explicit from this review):**
- §12 Security/threat model
- §13 Appendices (glossary, references, charter quotation)

**Out of v1 entirely (§11.7):**
- Custom-rule plugin model (D-102), XE sessions (D-021), index/missing-index DMVs, login/connection auditing, Resource Governor, cross-instance reporting (D-018), live DMV reads from Report (D-014, D-081), HTML/charts/GUI/dashboards (D-019), notifications (D-019), "what changed since yesterday," automatic baseline profiles, predicted-next-incident features.

### 3.6 Scope creep to remove from v0.1

**None identified.** The v0.1 scope in §11.2.2 is already minimal. Specifically verified against the exclusion list (§11.2.3):

- ✓ No QS collector or QueryStore rules
- ✓ No Agent / backup / deadlock / AG / error log / buffer pool / schema-stats collectors
- ✓ No dedicated `FR_Tempdb` / `FR_Memory` / `FR_PlanCacheSummary` / `FR_Deadlock` / `FR_AlwaysOnState` tables
- ✓ No `FR_v_*` views
- ✓ No demo data
- ✓ No `@TimeZone`
- ✓ No Azure SQL DB/MI support *claimed*
- ✓ No Linux 2017 *verified* (it likely works; not promised)
- ✓ No Tier 2 attestation in v0.1 RC
- ✓ No multi-instance

However, one item in v0.1 acceptance criterion #12 ("at least one external DBA has installed v0.1 RC on a real instance and provided feedback") is a *process* dependency, not scope creep. It is correctly placed.

The full 16-column Findings + 12-column Timeline + 14-key Markdown header contracts shipping in v0.1 even though most rule categories don't fire yet (per §11.2.2) is **deliberate, not creep** — it locks the public contract before runbooks form. Keep it.

### 3.7 Final implementation readiness recommendation

**The design is ready for implementation planning.**

Specifically:

- All 18 charter requirements pass.
- All 40 design-time open questions are resolved.
- 186 of 187 decisions are Locked at review time (190 of 190 after this review, with 6 At Risk explicitly tracked); the one Tentative (D-181) is a runtime-tunable default.
- The phased roadmap is concrete, the v0.1 scope is genuinely minimal, and the exclusion lists are binding.
- The safety contract (§9) is testable, not aspirational.
- The compatibility strategy is honest about its weakest tier (manual attestation on 2012/2014/2016).
- The contribution model (§10) is staffed at minimum viable level (D-185).

**Two caveats** worth carrying into the implementation planning conversation, not blocking but worth surfacing early:

1. **Sections 12 and 13 of the design doc are deferred to v1.0.** They are not blocking v0.1 implementation. Section 12 (security/threat model) and Section 13 (appendices) should be written before v1.0 — not before v0.1.

2. **The Tier 2 attestation process (D-164, D-190) is unproven.** Its first real test is the v0.2 release. If no community attestations arrive, the matrix-badge mechanism (D-165) will honestly show degraded status, but the project will need to decide at v0.2-RC time whether to ship anyway. This is a v0.2 release-planning question, not a v0.1 implementation blocker.

**Proceed to implementation planning for v0.1.**

---

## Part 4 — New decisions added by this review

The review added three decisions to the decision log. None changes the design; each operationalizes a residual risk identified above.

| ID | Subject | Operational commitment |
|---|---|---|
| **D-188** | Empirical validation of operating + storage envelopes | v0.2 release notes must report observed Collect durations and repository growth from at least one external production-class install before tagging. Specs are not validation; production is. |
| **D-189** | Wording compliance + baseline transparency as ongoing maintainer responsibilities | Maintainers commit to re-reading the safety checklist (D-176) and §6.7 wording rules before approving any PR touching `FR_Rules` or rule logic. A maintainer who has not re-read in past 30 days is ineligible as second reviewer (D-158) for such PRs. |
| **D-190** | Tier 2 attestation process on probation for first 18 months post-v1.0 | Public review at v1.0 + 18 months: how many attestations per release, which targets went Unverified, whether staleness-to-deprecation cascade triggered correctly. If process produced no useful signal, replace or supplement in v1.x minor. |

See `docs/decisions.md` for the full entries.

---

## Part 5 — What this review did *not* cover

For honesty:

- **Not a security review.** No threat modeling was performed against the design. Section 12 of the design doc is deferred for exactly this purpose; this review only verified that deferral was acknowledged, not that the security posture is sound.
- **Not an empirical validation.** No code was run. No SQL Server instance was touched. The PASS verdicts on §5 (30-second cap), §6 (no blocking), and §13 (minimal storage) are *design-level* verdicts. They mean "the design, if implemented faithfully, will satisfy this requirement." They do not mean "this has been measured on a production system." D-188 makes that distinction explicit and binding.
- **Not a wording audit of the rule pack.** The six v0.1 rules (FR_R0001–FR_R0006) have not yet had their final recommendation text drafted (the wording polish pass is v0.4 per §11.5). This review verified the *process* for wording compliance (D-076, D-157, D-158, D-189), not the wording itself.
- **Not an audit of the contribution model in practice.** Section 10 designs the model; no PRs have been submitted under it. The model's effectiveness is unmeasured.

These gaps are intentional. They are deferred to later review checkpoints, not silently skipped.

---

## Part 6 — Sign-off

This design lock review approves `docs/design.md` (sections 1–11) for v0.1 implementation planning, subject to the residual risks and tracking decisions documented above.

**Status:** APPROVED for implementation planning.
**Next step:** Implementation planning for v0.1 may begin. No further design-level work is required before that step.

---

*End of design lock review.*
