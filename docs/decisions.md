# Decision Log — SQL Server DBA Flight Recorder

Complete, append-only decision log. Every decision ID from D-001 through D-198 appears below with its source section and status.

**Status legend:**
- **Locked** — Final; only changeable in a major release per project versioning (D-171, D-126).
- **Tentative** — Decision is committed but explicitly subject to revision based on user feedback (typically a default value or threshold).
- **Deferred** — Decision identifies an item that has been moved to a later release; the target version is named.
- **Superseded** — Replaced by a later decision; the superseding D-### is named. (Currently: D-185 routing target by D-191; D-108 range framing by D-195; D-184 status only by D-197; D-180 and D-182 status only by D-198.)
- **At Risk** — Locked, but the design lock review (`docs/design-lock-review.md`) flagged a residual risk that depends on post-launch validation. The decision stands; the risk is tracked.

---

## Section 1–3 — Charter, Surface, Architecture

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-001 | §1.3 | Locked | Name `dbo.sp_SQLFlightRecorder` with `sp_` prefix | Community convention; cross-DB exec from `master` | MS discourages `sp_` for user procs |
| D-002 | §1.3 | Locked | Single entry point, multiple `@Mode` values | One thing to memorize | Larger parameter surface |
| D-003 | §1.3 | Locked | Default `@Mode = 'Help'` | Cannot harm server by accident | Users must read help first |
| D-004 | §1.4 | Locked | Default install in user DB; `master` install opt-in | Some shops disallow `master` writes | Cross-DB ergonomics require opt-in |
| D-005 | §1.4 | Locked | Agent job creation opt-in | Charter: no permanent changes by default | DBA must opt in to schedule |
| D-006 | §1.5 | Locked | Max two result sets in Report mode | Charter explicit | Richness pushed to `MoreInfo` |
| D-007 | §3.1 | Locked | Cumulative DMVs raw; deltas at report time | Recoverable from missed snapshots | More compute and storage |
| D-008 | §3.2 | Locked | Capability probe per invocation; branch on flags | Span 2012→2025 + Azure | ~200 ms fixed cost |
| D-009 | §3.3 | Locked | Per-collector `TRY/CATCH` | A crashing recorder is worthless | Partial snapshots possible |
| D-010 | §3.3 | Locked | Cooperative timeout; cheapest+most-volatile first | T-SQL has no preemptive cancel | Late collectors skipped first |
| D-011 | §3.4 | Locked | Applock gates Collect/Purge; Report unlocked | Prevents pile-ups | Concurrent collects dropped (logged) |
| D-012 | §3.5, §1.2 | Locked | Deterministic rule pack, no ML | Charter forbids "AI magic" | No novel-pattern detection |
| D-013 | §1.5 | Locked | Severity + Confidence + EvidenceType per finding | Charter honesty | Authors must be disciplined |
| D-014 | §3.5 | Locked | Rules read repo only (+ bounded QS) | Reproducible reports | Cannot react to live state |
| D-015 | §3.6, §1.5 | Locked | Plans never shredded by default | #1 way these tools become unsafe | Plan analysis limited to QS XML |
| D-016 | §1.6 | Locked | UTC `datetime2(3)` storage | Avoids DST bugs | UTC parameters until Q-002 resolved |
| D-017 | §3.6, §1.5 | Locked | `READ UNCOMMITTED` session-wide; no `NOLOCK` hints | Charter forbids NOLOCK | Less obvious to readers |
| D-018 | §1.2 | Locked | No central/multi-instance repo in v1 | Avoids scope creep | Per-instance install only |
| D-019 | §1.2 | Locked | No notification/alerting/GUI | Charter: diagnose only | Users wrap own alerting |
| D-020 | §5.8 | Locked | Error log scrape opt-in, off by default | High platform variance | Some events degraded when off |
| D-021 | §1.4 | Locked | No XE session creation in v1 | Charter: no permanent server changes | Deeper analysis deferred |
| D-022 | §1.4 | Locked | Tables `dbo.FR_*`; schema flex deferred | Simple v1 discovery | Strict-schema shops accept `dbo` |
| D-023 | §3.7, §1.5 | Locked | Output contract semver-stable; additive in minors | Runbooks must not break | Slows output evolution |
| D-024 | §1.4 | Locked | `CollectAndReport` documented as non-recommended | Real value: scheduled Collect + on-demand Report | Risk of misuse |

## Section 4 — Repository Schema

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-025 | §4.1 | Locked | 15 tables in v1, snapshot-spine model | Narrow, readable | New collectors mean new tables |
| D-026 | §4.5 | Locked | Q-003 → config multi-values semicolon-delimited | Universal across 2012+ | Clunkier hand-editing |
| D-027 | §4.5 | Locked | Q-004 → `FR_QueryText` dedup on `(QueryHash, SHA2_256(SqlText))` | Handles collisions and NULL/ad-hoc | Two-column unique index |
| D-028 | §4.5 | Locked | Q-008 (storage) → `InstanceFingerprint` never in PK/FK | Repos restorable across instances | Small duplication |
| D-029 | §3.7 | Locked | Q-012 (storage) → `FR_Rules` catalog table; logic in code | Disable rules without code edits | Two sources for "what rules exist" |
| D-030 | §4.1 | Locked | `BIGINT IDENTITY` PK on every snapshot table | Stable joins, simple FKs | Minor storage overhead |
| D-031 | §4.1 | Locked | Clustered index `SnapshotUtc`-leading | Report is hot read path | Slightly hotter inserts |
| D-032 | §4.1 | Locked | Declared FKs, no cascades | Real RI, no surprise cascades | Purge code knows order |
| D-033 | §4.8 | Locked | Wait-stats ignore list at collect time | Bounds largest table | Discontinuity on list change |
| D-034 | §4.4 | At Risk | `PAGE` compression default, edition fallback | Big savings on cumulative tables | Express gets less. **Risk:** "Minimal storage" envelope (Charter §13) is modeled, not measured at scale; tracked by D-188. |
| D-035 | §4.7 | Locked | `FR_RunLog` retained 4× snapshot retention | Self-instrumentation outlives data | More run-log rows |
| D-036 | §4.6 | Locked | No Findings/Timeline persistence in v1 | Single source of truth | Cannot diff yesterday's findings |
| D-037 | §4.3 | Locked | Defer some tables to v0.2/v0.3 | MVP discipline | Some "obvious" tables missing in v0.1 |
| D-038 | §4.2 | Locked | Forward-only schema migrations | Snapshot data never lost | More installer code |
| D-039 | §4.2 | Locked | Downgrade unsupported | Prevents silent corruption | Roll forward only |
| D-040 | §4.4 | Locked | No `NVARCHAR(MAX)` on hot rows | Dense pages | Bounded fields can truncate |
| D-041 | §4.4 | Locked | `DatabaseId=0`, `SessionId=0` sentinels | Selective indexes | DBAs remember meaning |

## Section 5 — Collection Strategy

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-042 | §5.1 | Locked | Default cadence 1 snapshot/min | Cheap; dense enough for `LAG()` | Sub-minute spikes invisible |
| D-043 | §5.2 | At Risk | Target median ~2–8 s, hard cap 30 s | Explicit envelope | §9 enforces. **Risk:** Synthetic CI workload (D-143) cannot reproduce all pathological production cases; validation depends on early adopters. Tracked by D-188. |
| D-044 | §5.3 | Locked | QS collector reads only latest closed interval per DB | Bounds most expensive collector | No retroactive QS analysis |
| D-045 | §5.3 | Locked | QS collector capped at 50% of run budget | Protects rest of snapshot | End-of-iter DBs may be skipped |
| D-046 | §5.4 | Locked | No `CROSS APPLY dm_exec_query_plan` ever | Restates D-015 at collector level | Plan analysis limited to QS XML |
| D-047 | §5.4 | Locked | `dm_tran_locks` only for known blockers, top-50 | Largest DMV on busy boxes | "All locks" not supported |
| D-048 | §5.5 | Locked | Tempdb/memory data in `FR_Request`/`FR_FileStat` in v0.1 | High-signal data day one | Two storage shapes |
| D-049 | §5.1 | Locked | Cadence varies by collector class | Slow-changing data doesn't need minute resolution | More cadence rules |
| D-050 | §5.6 | Locked | Backup/Agent collectors use delta-only reads | Bounds msdb history reads | Needs high-water mark |
| D-051 | §5.4 | Locked | Buffer-pool collector opt-in, skipped >256 GB RAM | Highest-risk collector | Big-memory shops get less detail |
| D-052 | §5.4 | Locked | Stats/schema collector caps at first 50 user DBs | Bounds hundred-DB instances | Arbitrary ordering; configurable |
| D-053 | §5.7 | Locked | Deadlock collector dedups by graph hash | Each unique deadlock shredded once | Small hashing step |
| D-054 | §5.9 | Locked | Skipped collectors emit log rows; surfaced in Report | Clean ≠ nothing wrong | More informational rows |
| D-055 | §5.1 | Locked | Plan cache headlines every snap; top-N every 5th | Headlines cheap; top-N occasionally expensive | 5× coarser top-N |
| D-056 | §5.10 | Locked | 19 collectors at v1.0 (phased) | Schema/rules stabilize before complexity | Some day-one data in v0.2 |
| D-057 | §4.8 | Locked | Q-016 → wait-ignore-list seeded into `FR_Config`; hard-coded fallback | Edit without reinstall | Two sources of truth |
| D-058 | §5.1 | Locked | Q-017 → time-since-last from `FR_RunLogStep` gates lower-freq collectors | Survives restarts/missed runs | One extra small read per snapshot |
| D-059 | §5.3 | Locked | Q-018 → QS collector persists partial on budget hit; `PartialSuccess` | Partial > none, if visible | Per-DB inconsistency tolerance |
| D-060 | §5.8 | Locked | Q-019 → `xp_readerrorlog` perms verified at Configure AND Collect | Loud failure at config time | Two probes |
| D-061 | §3.4 | Locked | Q-020 → no force-snapshot/applock-bypass in v1 | Applock prevents pile-ups | No double-pumping in crisis |

## Section 6 — Reporting Strategy

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-062 | §6.1 | Locked | Deterministic report pipeline | Byte-identical output; testable | No side-effect tricks |
| D-063 | §6.1 | Locked | Window expanded by 1 snapshot interval internally for `LAG()` | Edge deltas computable | Slight extra read |
| D-064 | §6.2 | Locked | Restart detection splits window; Critical informational finding | Cross-restart deltas nonsense | More complex delta code |
| D-065 | §6.3 | Locked | Q-001 → <2 snapshots = Critical informational, report proceeds | Silence is worse | Synthetic finding on tiny windows |
| D-066 | §6.3 | Locked | Q-006 → gap >2× cadence informational; severity scales | Graded honesty | Three thresholds to tune |
| D-067 | §6.4 | Locked | Findings: 16-column public contract | Stable runbook integration | Cannot reshape in minors |
| D-068 | §6.4 | Locked | Findings sort: Severity → Confidence → EvidenceType → StartTime → RuleId | Deterministic; Info last | Tie-break complexity |
| D-069 | §6.4 | Locked | Severity per-rule, never auto-promoted | Prevents loudness inflation | Big/small incidents rank same |
| D-070 | §6.4 | Locked | `@MinSeverity`/`@DatabaseName` filter post-eval; `@TopN` collector-side | Filters can't hide Critical | More rows than expected |
| D-071 | §6.5 | Locked | Timeline: 12-column contract; chronological | Top-to-bottom tells a story | No "important first" view |
| D-072 | §6.5 | Locked | Durations as paired events | Clearer to read | More rows |
| D-073 | §6.5 | Locked | `EventType`/`Category` closed sets; additive in minors | Stable runbook integration | New types take minor release |
| D-074 | §6.6 | Locked | Cross-category dedup forbidden; intra-category by anchor | Avoids duplication; preserves attribution | More complex than no-dedup |
| D-075 | §6.6 | Locked | Coverage findings exempt from dedup | Absences must show | Extra rows |
| D-076 | §6.7 | At Risk | Wording rules enforced at code review | Operationalizes no-overclaiming | PR-review friction. **Risk:** No automated wording linter; relies on humans + checklist (D-157, D-158). Tracked by D-189. |
| D-077 | §6.4 | Locked | Empty Findings → synthetic Informational | Prevents post-mortem misreading | Cannot return truly empty |
| D-078 | §6.5 | Locked | Empty Timeline permitted | Honest when empty | Asymmetry intentional |
| D-079 | §6.8 | Locked | Q-010 → Markdown single `nvarchar(max)` col `Report`; stable markers | Paste ergonomics; greppable | Markdown quality on us |
| D-080 | §6.9 | Locked | Report runtime target ≤3 s median, hard cap 60 s | Bounded but human-paced | Large windows may truncate |
| D-081 | §6.9 | Locked | Report reads no live DMVs except bounded QS | Restates D-014 at engine level | Cannot reflect post-snapshot state |
| D-082 | §6.9 | Locked | `@IncludeQueryPlans=1` surfaces XML by handle; never parsed | SSMS renders | No plan-shape findings |
| D-083 | §6.4 | Locked | Q-021 → "no findings" row always appears, exempt from `@MinSeverity` | Prevents misreading | Cannot get truly empty result |
| D-084 | §6.4 | Locked | Q-022 → Evidence capped ~1900 chars with "(N more — see MoreInfo)"; full detail in MoreInfo (cap 1000) | Row-store-friendly; preserves attribution | Wide groups lose some detail |
| D-085 | §6.8 | Locked | Q-023 → Markdown header block (14 keys) part of public contract | Sanction inevitable automation | Cannot change key set in minors |
| D-086 | §6.10 | Locked | Q-024 → QS drilldown query in `MoreInfo` when `QueryId IS NOT NULL`: read-only, bounded, version-aware | 2 AM drill-down ergonomics | Two places generate QS SQL |
| D-087 | §6.9 | Locked | Q-025 → `@MaxFindings` default 200 (10–2000); overflow truncated with Informational | Safety against pathological output | Truncation visible to user |

## Section 7 — Recommendation Rules

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-088 | §7.1 | Locked | 26 rules at v1.0 (6+8+6+6, phased) | Covers high-signal patterns | Edge patterns via PRs |
| D-089 | §7.2 | Locked | `RuleId` format `FR_R####_ShortName`; never renamed/reused | Stable runbook references | Retired IDs permanently reserved |
| D-090 | §7.2 | Locked | Lifecycle: Active / Disabled / Deprecated / Retired | Graceful evolution | Deprecated rules consume cycles |
| D-091 | §7.3 | Locked | Severity per-rule constant in `FR_Rules` | Prevents loudness inflation | Big/small incidents rank same |
| D-092 | §7.4 | At Risk | Baselines: 24h median excluding incident; ≥5 samples or Confidence=Low | Transparent, no-ML | Seasonality false-positives. **Risk:** Could be mischaracterized as "anomaly detection" / "AI magic" (Charter §16); transparency in rule docs (D-161) is the mitigation. Tracked by D-189. |
| D-093 | §7.4 | Locked | "Critical wait types" allow-list hard-coded in v1 | Conservative community consensus | Not customizable in v1.0 |
| D-094 | §7.5 | Locked | Maintenance job-name patterns hard-coded (Ola + Maintenance Plans) | Catches 95% | Custom job names get less |
| D-095 | §7.6 | Locked | FR_R0010 window = 15 min before `@StartTime` through `@EndTime` | Catches triggering failures | Arbitrary; configurable later |
| D-096 | §7.6 | Locked | FR_R0012 excludes log backups | Log backup overlap is normal | Log-backup spikes not caught here |
| D-097 | §7.6 | Locked | FR_R0025 thresholds: FULL >7d Medium; CHECKDB >14d High | Conservative industry standard | Stricter SLAs need stricter rules |
| D-098 | §7.6 | Locked | FR_R0026 always emits; cannot be disabled | Honesty backbone | One guaranteed row even on clean runs |
| D-099 | §7.7 | Locked | Disabling rules via `FR_Config.DisabledRules` (delimited) | Consistent with D-026 | Rule IDs as strings |
| D-100 | §7.7 | Locked | Rule execution order fixed by `RuleId`; no inter-rule deps | Determinism | Cannot express "B only if A" |
| D-101 | §7.7 | Locked | Disabled rules in FR_R0026 "Suppressed" list | Suppression remains visible | Cannot fully silence existence |
| D-102 | §7.7 | Locked | Custom-rule plugin model out of scope for v1 | Security/gate-inheritance complexity | Community via PR |
| D-103 | §6.9 | Locked | Q-026 → shared baseline temps materialized once per Report | Bounds 26-rule cost; rules agree on "normal" | 100–500ms even when rules disabled |
| D-104 | §6.3 | Locked | Q-027 → per-gap and FR_R0026 both emit, never deduped | Different granularity/purpose | Verbose coverage section |
| D-105 | §7.4 | Locked | Q-028 → `CriticalWaitTypes` config key defined v1.0, honored v1.1 | Forward compatibility | Two versions, same key, different behavior |
| D-106 | §7.7 | Locked | Q-029 → headline rules keep own `RuleId`; disabling contributor ≠ disabling headline | Stable runbook refs | Users may be surprised |
| D-107 | §7.8 | Locked | Q-030 → QS regression fires on 2016 with runtime stats only; Confidence forced down | Charter graceful degradation | Rule has version branch |

## Section 8 — Version Compatibility

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-108 | §8.1 | Superseded by D-195 (range framing only) | Supported 2012→2025; Synapse/Fabric/BDC/Stretch out of scope | Single coherent engine family | Cannot expand without redesign |
| D-109 | §8.1 | Locked | Azure SQL DB supported with heavy degradation; honest at Install | Charter graceful degradation | Smaller rule set on Azure SQL DB |
| D-110 | §8.2 | Locked | No conditional compilation; one file identical for every target | Predictable; no preprocessor tricks | All branching pays runtime cost |
| D-111 | §8.2 | Locked | Capability probe is only branching mechanism; never `@@VERSION` parsing | Survives unknown future builds | Probe must be exhaustive |
| D-112 | §8.2 | Locked | Dynamic SQL discipline: not-everywhere-available code goes via `sp_executesql` with param binding | Avoids compile errors | More verbose code |
| D-113 | §8.2 | Locked | No nested dynamic SQL; no dynamic SQL in rules | Bounds complexity | Some collector logic elaborate |
| D-114 | §8.2 | Locked | `@Debug=1` PRINTs dynamic SQL without execution | Lets users/tests inspect per version | One branch per dynamic block |
| D-115 | §8.3 | Locked | Capability snapshot persisted per run | Old data renders correctly | Slight write per run |
| D-116 | §8.4 | Locked | Express: skip Agent install; compression cascades | Express has no Agent | Larger repo on Express |
| D-117 | §8.4 | Locked | Linux: perf counter prefix normalized at collect | Linux unprefixed differs | One normalization point |
| D-118 | §8.5 | Locked | Perm tiers: VSS required; VAD recommended; sysadmin discouraged | Charter "no security changes by default" | Some collectors degrade |
| D-119 | §8.5 | Locked | Missing perms reported in three places | At 2 AM users find one of three | Repetition by design |
| D-120 | §8.6 | Locked | Tier 1 CI: 2017/2019/2022/2025 Linux containers; blocking | Free, scriptable, fast | 2012/2014/2016 not automated |
| D-121 | §8.6 | At Risk | Tier 2 manual: 2012/2014/2016 Win + MI + Azure SQL DB; not merge-blocking | Cannot containerize for free | Release notes must declare gaps. **Risk:** Attestation process (D-164) is unproven; first 18 months post-launch are the real test. Tracked by D-190. |
| D-122 | §8.6 | Locked | Golden output tests per version; byte diff fails CI | Strongest determinism guarantee | Authors update goldens with rule changes |
| D-123 | §8.6 | Locked | Capability-flag unit tests with simulated `CapabilitySnapshot` | Fast; covers interpretation across matrix | Doesn't test dynamic SQL compile |
| D-124 | §8.7 | Locked | New majors evaluated within 90 days of GA | Forward-compat commitment | Some day-one lag |
| D-125 | §8.7 | Locked | Repo portability supported by design; no v1 cross-instance UI | Consultant workflow unblocked | UX deferred to v2 |
| D-126 | §8.7 | Locked | Major-version support never dropped in minors | Predictable for users | Slows ability to retire engines |
| D-127 | §8.3 | Locked | Q-031 → capability snapshot keys closed/documented set per release; additive in minors; rendered in Help/Status | Sanction the inevitable automation | Adding probe in v1.x = key-list bump |
| D-128 | §8.2 | Locked | Q-032 → `@Debug=1` writes RunLog as `Mode='CollectDebug'`; no collector rows | Debug visibility matters; distinct mode | One more Mode value |
| D-129 | §8.6 | Locked | Q-033 → compat matrix badge deferred to §10 | §10 owns repo presentation | Resolved in §10.7 by D-165 |
| D-130 | §8.6 | Locked | Q-034 → Tier 2 stale-validation deferred to §10 | §10 owns release workflow | Resolved in §10.7 by D-164 |

## Section 9 — Performance and Safety

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-131 | §9.1 | Locked | Operating envelope codified as testable contract | Specs without thresholds are aspirations | Conservative thresholds catch regressions later than tighter ones |
| D-132 | §9.2 | Locked | Session safety primitives set at top of every mode | Cannot rely on caller's defaults | Slight overhead per invocation |
| D-133 | §9.2 | Locked | `LOCK_TIMEOUT 5000` defense-in-depth | If we ever block, we give up | Some legitimate slow reads will fail |
| D-134 | §9.2 | Locked | `DEADLOCK_PRIORITY LOW` — diagnostic always loses | User work wins | Collector occasionally aborted |
| D-135 | §9.3 | Locked | Parent `FR_Snapshot` inserted after all children | Report cannot see orphaned children | Slightly more complex coordination |
| D-136 | §9.4 | Locked | Forbidden DMV list codified; enforced by CI static analysis | Cost of *not* using ≠ cost of using badly | New DMVs need explicit allow-listing |
| D-137 | §9.4 | Locked | Allow-list for bounded reads: explicit `TOP(N) ORDER BY` or small-DMV allow-list | Static-analyzable guarantee | Authors must bound every new query |
| D-138 | §9.4 | Locked | No cursors, no `WITH RECOMPILE`, set-based throughout | Charter pillar | Some logic less intuitive |
| D-139 | §9.5 | Locked | Purge batched 5,000/batch; 250 ms inter-batch; per-batch `TRY/CATCH` | Naive delete could fill log | Purge may take multiple invocations to catch up |
| D-140 | §9.5 | Locked | No `TRUNCATE`, no shrink, no index rebuild on repo | We don't practice what we forbid | Marginally slower purge |
| D-141 | §9.5 | Locked | Purge order: snapshot children → `FR_Snapshot` → `FR_QueryText` orphans → run-log | Honors FKs; orphan-driven for QueryText | Purge knows table deps |
| D-142 | §9.6 | Locked | Three opt-in expensive features + `@IncludeQueryPlans`; no "enable all" | Each surfaces in Help/Status with cost | Aggressive profiles need per-feature opt-in |
| D-143 | §9.7 | Locked | CI cost-regression test: workload + Collect; >2% throughput drop or >10 s collect fails PR | Specs without tests are aspirations | Thresholds may need recalibration |
| D-144 | §9.7 | Locked | CI static analysis: bounded reads, no forbidden DMVs, no stray TRAN, parameterized `sp_executesql`, bounded `WAITFOR` | Catches refactor mistakes | Some legit exceptions need allow-list comments |
| D-145 | §9.7 | Locked | 24 h CI soak (out-of-band) | Catches drift per-PR tests miss | Failures handled in release planning |
| D-146 | §9.8 | Locked | Documented limits we *will not* promise | Charter "skeptical and practical" | Users with extreme workloads accept degraded behavior |
| D-147 | §9.9 | Locked | Failure-mode catalog is user docs (in Help-extended and README) | At 2 AM users need one table | Must be kept in sync as failure modes evolve |
| D-148 | §9.7 | Locked | Q-035 → CI static analysis may be external (Python/PS); charter governs shipped artifact, not build pipeline | Don't confuse charter with build mechanics | Contributors running full validation locally must install toolchain |
| D-149 | §9.5 | Locked | Q-036 → `Purge @WhatIf` attempts exact counts under same time cap; falls back to `sys.partitions` estimates with `IsEstimated` flag | Exact when affordable; honest when not | `@WhatIf` no longer cheap on huge repos |
| D-150 | §9.10 | Locked | Q-037 → no in-run retry on collector failure; next snapshot is the retry | In-run retry breaks cooperative timeout | One snapshot's degraded data; visible in FR_R0026 |

## Section 10 — Open Source Contribution Model

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-151 | §10.1 | Locked | Repository layout: `src/`, `docs/`, `examples/`, `tests/`, `.github/`, `scripts/` | Predictable; tests and contributing first-class | Some duplication between docs and design doc |
| D-152 | §10.1 | Locked | Shipped artifact is always single file; if source splits, `scripts/build-single-file.sh` concatenates | Honors D-110 at artifact level without forcing one giant source forever | Build step adds one indirection |
| D-153 | §10.2 | Locked | Coding style codified (UPPER keywords, original-case identifiers, 4 spaces, 120-char wrap, schema-qualified, no `SELECT *`, no commented-out code) | Consistency at code-review level | No auto-formatter in CI (none handle dynamic SQL well) |
| D-154 | §10.2 | Locked | Naming conventions: `FR_*` tables, `FR_v_*` views, `sp_SQLFlightRecorder_<Phase>_<Area>` helpers, `#fr_*` temps, `@has<Feature>` flags | One pattern across the codebase | Some names verbose |
| D-155 | §10.2 | Locked | TODO/FIXME must reference a GitHub issue; untracked TODOs fail review | No quiet rot in comments | Friction for quick notes |
| D-156 | §10.3 | Locked | Eight issue templates (bug, false-positive, false-negative, rule proposal, collector proposal, version compat, perf regression, config); blank issues disabled | Reports come pre-shaped for triage | New report types need a template added |
| D-157 | §10.4 | Locked | PR template includes charter-compliance checkbox list (no forbidden DMVs, no XML shred, no user-table reads, wording rules, etc.) | Checklist beats memory at 2 AM | Lengthy template |
| D-158 | §10.4 | Locked | Two-reviewer rule for shipped artifact; one for docs/examples; maintainer required for safety-checklist items | Defense in depth | Bottleneck on maintainer availability |
| D-159 | §10.4 | Locked | "Boring code" criterion is grounds to request changes | Tool readability at 2 AM > runtime micro-optimization | Sometimes rejects genuinely better algorithms |
| D-160 | §10.5 | Locked | Rule-contribution format requires: metadata row, T-SQL logic, docs page from template, positive + negative test, golden updates, wording self-review | Five-part bundle keeps the rule pack disciplined | High bar for rule PRs |
| D-161 | §10.5 | Locked | Rule docs use fixed template (`docs/rules/_template.md`) including Severity rationale, Confidence rationale, FP risks, drill-down, suppress instructions | Predictability is itself a feature | Rule authors fill in 9 sections |
| D-162 | §10.5 | Locked | Rule retirement: maintainer proposes; ≥30-day discussion; deprecated for ≥2 minors; retired only in major; `RuleId` reserved forever | Runbooks across years still work | Retirement is slow on purpose |
| D-163 | §10.6 | Locked | `CODEOWNERS` routes by area (core, rule pack, compatibility, docs) | Right reviewers see the right PRs | Requires maintainer teams to be staffed |
| D-164 | §10.7 | At Risk | Q-034 → Tier 2 attestation issues auto-open per RC; missing for 3 minors → Unverified; missing for 6 → deprecation discussion | Honest signal; not pretending to test what we don't | Old engines may show Unverified for a while. **Risk:** Process is unproven; tracked by D-190. |
| D-165 | §10.7 | Locked | Q-033 → compatibility matrix auto-generated from Tier 1 CI + Tier 2 attestations; README badge links to it; no manual edits to `matrix.md` | Users see true posture before installing | One generator script to maintain |
| D-166 | §10.7 | Locked | Tier 3 community reports via Discussions category (non-binding) | Useful signal without commitment | No formal status for Tier 3 |
| D-167 | §10.8 | Locked | Documentation rule: every page answers a user question in order asked; design doc published in `docs/design/` (no secret docs) | Contributors and maintainers share context | Design doc must be kept user-readable |
| D-168 | §10.8 | Locked | README structure aimed at 2 AM phone reading: one paragraph, badge, 30-second install, headline use case, links to ops docs | Not marketing; utility | Reads dry to outsiders |
| D-169 | §10.8 | Locked | Some docs auto-generated (`docs/rules/` index, compat matrix, modes parameter tables); hand-edits to generated files rejected | Single source of truth | Generator scripts must be maintained |
| D-170 | §10.9 | Locked | Examples are runnable, comprehensive, and CI-tested every PR (Tier 1) | Examples cannot bit-rot | Adding an example requires a Tier 1 fixture |
| D-171 | §10.10 | Locked | Semver with project-specific meanings: major = output contract/version drop/rule retirement; minor = additive (rules, collectors, probes, tables); patch = fixes | Clear contract for runbooks | Some judgement calls about "additive" |
| D-172 | §10.10 | Locked | Release cadence: patches as needed; minor target quarterly (floor 6-monthly); major every 18–24 months with ≥1 minor of deprecation warnings | Predictable for users; sustainable for maintainers | Aggressive features wait for minor |
| D-173 | §10.10 | Locked | Release process: RC branch → auto-open Tier 2 attestation issues → Tier 1 must be green → CHANGELOG entry mandatory → tag → release.yml builds artifact + regenerates matrix | Releases are repeatable | Each release has process overhead |
| D-174 | §10.10 | Locked | Hotfix process: branch from latest tag, minimal fix + regression test, Tier 1 green, ship within 72 h target; forward-merge | Don't sit on Sev 1 fixes | 72 h is aspirational, not contractual |
| D-175 | §10.11 | Locked | CHANGELOG follows Keep a Changelog 1.1.0 + tags affected `RuleId`s and Mode names | Greppable by runbook owners | More verbose entries |
| D-176 | §10.12 | Locked | Safety review checklist is its own doc, pasted verbatim into PR reviews when needed | Single source for "did we stay safe?" | Must be kept in sync with §9 forbidden lists |
| D-177 | §10.13 | Locked | Governance: small core + topic maintainer teams; lazy consensus (7-day silence = approval); major decisions require 14-day Discussion | Lightweight; doesn't require Robert's Rules | Slow on contentious changes (intentional) |
| D-178 | §10.13 | Locked | Charter is the project BDFL-equivalent; disputes resolved by quoting it | No single-person dependency | Charter language must remain crisp |
| D-179 | §10.13 | Locked | No CLA/DCO at v1; MIT license; no paid support tier; no vendor badges; no bounty program; no popularity-vote prioritization | Keeps project lean and vendor-neutral | Corporate contributions may face friction later |

## Section 11 — MVP Scope (resolves prior open questions)

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-180 | §1.6, §11.5 | Locked (Q-002 resolved); `@TimeZone` **Superseded by D-198 (status only — deferral discharged; the parameter ships in v1.0.0, display-only, storage still UTC)** | Q-002 → v1 interprets `@StartTime`/`@EndTime` as server local time; internal storage UTC; Markdown header shows offset; explicit `@TimeZone` deferred to v0.4+ | DBAs think in local time at 2 AM; UTC storage stays correct across DST | Server moves between time zones (rare) shift historical interpretation |
| D-181 | §5.11 | Tentative (subject to community feedback) | Q-005 → `MaxRowsPerCollector = 50` ships as configurable v1 default, per-category overridable; revisable in any minor based on user reports | Defensible MVP starting point; configurability protects unusual workloads | Long-tail offenders invisible at default; FR_R0026 surfaces when top-N caps may be hiding signal |
| D-182 | §11.4 | Superseded by D-198 (status only — deferral discharged; `InstallDemoData` ships in v1.0.0, isolated by synthetic `InstanceFingerprint` rather than the sketched `FRDemo` schema) | Q-007 → Demo data mode not required for v0.1; roadmap as `@Mode = 'InstallDemoData'`, writing into `FRDemo`-isolated schema, never enabled by default | Contributors need a way to exercise rules without a real incident; not blocking for first ship | v0.1 contributors must hand-build fixtures from `tests/fixtures/` |
| D-183 | §2.1 | Locked | Q-011 → `Uninstall` drops all `FR_*` objects by default; `@PreserveRunLog=1` opt-in renames `FR_RunLog*` to `FR_RunLog_Archive_<timestamp>` | Charter: fully removable with no permanent artifacts; audit use case satisfied without polluting default | Two more tables to consider during purge; rename collision risk handled with timestamp |
| D-184 | §11.3 | Superseded by D-197 (status only — the deferral was discharged; `FR_v_*` views ship in v1.0.0) | Q-013 → `FR_v_*` view layer deferred until v0.2, after Section 6 contracts have shipped and survived one release | Shipping views in v0.1 risks freezing them before we know how DBAs query the repo ad-hoc | v0.1 power users query base tables directly |
| D-185 | §10.6 | Superseded by D-191 (routing target only; topic-team intent retained) | Q-038 → At v1.0 launch, all `CODEOWNERS` paths route to single `@core-maintainers` team; topic-specific teams created when trusted maintainers with that focus exist | No bootstrapping problem from routing PRs to teams that don't have members | All early reviews fall on the core team |
| D-186 | §10.4 | Locked | Q-039 → "Boring code" rejection is appealable to a second maintainer; safety/compatibility/performance objections remain non-appealable | Style judgement is reviewer-subjective; safety isn't | Some boring-vs-clever debates take two maintainers' time |
| D-187 | §10.14 | Locked | Q-040 → Minimum local contributor environment is SSMS or Azure Data Studio + a writable SQL Server instance; Docker/CI parity recommended but not required for PR submission | DBA contributors are the target audience; many don't run Docker on workstations | First-pass CI failures may take an extra cycle when a maintainer relays results |

## Design Lock Review (new decisions raised by the compliance review)

These three decisions were created by the design lock / compliance review (see `docs/design-lock-review.md`). They acknowledge and operationalize risks that the review identified. None of them change the locked design; each is a tracking commitment.

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-188 | Design Lock Review §2 risk #1 + §13 (storage) | Locked | Operating envelope (D-043, D-131) and storage envelope (Charter §13) are **explicitly understood to require empirical validation in v0.1/v0.2 by real-world users**. The synthetic CI workload (D-143) is the floor, not the ceiling. Early-adopter feedback is treated as a release-process input, not a "nice to have." v0.2 release notes must report observed Collect durations and repository growth from at least one external production-class install before tagging. | Specifications are not validation; production is. Without an explicit commitment, the empirical-validation step can quietly slip. | v0.2 release may slip if no external production install has reported back. Acceptable cost to keep the "safe on production" claim honest. |
| D-189 | Design Lock Review §2 risk #4 + §16 (no AI magic) | Locked | The two human-enforced disciplines — **wording compliance (D-076) and baseline-transparency (D-092)** — are explicitly named as ongoing maintainer responsibilities, not one-time setup. The PR template (D-157) and rule docs template (D-161) carry the load, but maintainers commit to re-reading the safety checklist (D-176) and the §6.7 wording rules **before approving any PR that touches `FR_Rules` seed data or rule logic.** A maintainer who has not re-read those two documents in the past 30 days is not eligible to be the second reviewer (D-158) on such PRs. | The compliance review noted that wording compliance has no automated linter and baseline math could be mischaracterized as ML. The mitigation is human; making it an explicit ongoing commitment (not just a checklist item) is what keeps the commitment alive. | Adds friction to maintainer rotation; small. |
| D-190 | Design Lock Review §2 risk #2 + §10 (compat matrix process) | Locked | The Tier 2 attestation process (D-121, D-164) is **on probation for its first 18 months post-v1.0**. The maintainers commit to a public review of the attestation process at the v1.0 + 18 months point: how many attestations arrived per release, which targets went Unverified, whether the staleness-to-deprecation cascade (D-164) actually triggered when it should have. If the process produced no useful signal, it is replaced or supplemented in a v1.x minor (which is a process change, not a charter change). | The compliance review correctly noted that the attestation process is unproven and the first 18 months are the real test. An explicit review commitment prevents quiet erosion of the test matrix. | Maintainers must hold themselves to this review; nobody else will. |

---

## v1.0.0-rc amendments

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-191 | §10.6 (supersedes the routing target of D-185) | Locked | `CODEOWNERS` owners are the repository owner account `@forward-thinkers-lab`, not an `@org/team`. Confirmed 2026-07-28: this repository is owned by a **GitHub user account, not an organization**, so team syntax cannot resolve and D-185's `@core-maintainers` routing was unachievable as written. D-185's *intent* — single default owner at v1.0, topic teams only when trusted maintainers with that focus exist — is retained and reactivated verbatim if the project later moves under an organization. | An owner that cannot resolve is silently ignored by GitHub: the rules read as review protection while enforcing nothing. A valid owner that actually resolves is safer than an aspirational one. | CODEOWNERS cannot request a review from the repository owner on their own PR, so it does not by itself enforce the two-reviewer rule (D-158); that still depends on a second human reviewer. Revisit if the project moves to an org. |
| D-192 | §11.6 (supersedes the "Tier 2 attestation complete for at least 4 of 5 targets" clause of §11.6) | Locked | Final `v1.0.0` **may ship with Tier-2 targets Unverified**. The ≥ 4-of-5 attestation count is no longer a release gate. In exchange, every compatibility claim must state its tier explicitly and keep the two separate: **Tier-1 verified** (automated CI evidence) versus **Tier-2 pending / unverified** (no attestation received). SQL Server 2012 / 2014 / 2016 and the Azure targets must never be described as verified, tested, supported-as-tested, or equivalent to Tier 1 until a real attestation is recorded in the matrix. Attestation collection continues as ordinary post-1.0 work under D-164's cadence and D-190's 18-month review; D-121, D-164 and D-190 are otherwise unchanged. | Owner decision, 2026-07-29. The three Windows targets need out-of-support SQL builds on dedicated hardware and the Azure targets need paid services; none are available. Holding v1.0 indefinitely for attestations that may never arrive serves no user. Shipping with an honest "untested" label is more truthful than either faking verification or blocking the release forever. | v1.0 ships without independent evidence on five targets. Users on 2012/2014/2016 or Azure get a documented *Unverified* status and must validate in their own environment. The compatibility matrix and release notes now carry the whole burden of not overstating — a wording slip there is the main risk this decision creates. |
| D-193 | §6.7, §10.4 (supersedes D-158's two-reviewer requirement and D-189's second-reviewer eligibility rule, **as applied to the v1.0.0 wording sign-off only**) | Locked | **Owner sign-off is sufficient for the final `v1.0.0` wording lock.** D-076/D-158/D-189 require a second maintainer to countersign wording review; this repository has exactly one maintainer (D-191: a personal user account, where GitHub will not even request review on the owner's own PRs), so the requirement cannot be met and would block v1.0.0 indefinitely. The systematic review recorded in `wording-lock-review.md` plus the owner's sign-off constitutes the v1.0.0 wording lock. **Two-maintainer review resumes automatically** the moment a second maintainer exists or the project moves to an organization/team model — at which point D-158 and D-189 apply again in full, unmodified, including the 30-day re-read eligibility rule. This decision narrows *who signs off*; it does not weaken *what §6.7 requires* of the wording itself. | The alternative was shipping with a permanently unmet gate or pretending a second reviewer existed. Naming the constraint and its expiry condition is more honest than either, and keeps the two-reviewer discipline alive as the default rather than quietly deleting it. | v1.0.0's wording lock has no independent second reader. The mitigation is that the review was systematic and is published in full, so any reader can audit it; and the discipline reinstates itself without further decision once the team grows. |
| D-194 | §9.7, §11.6 (supersedes the RC plan's "cost-regression + soak green once" gate) | Locked | The **cost-regression (D-143)** and **soak (D-145)** harnesses are **out-of-band and non-blocking, and are not a final-`v1.0.0` gate**. No green evidence exists for either, and none is claimed. Two mechanical facts make this the honest position rather than a concession: `ci-cost.yml` and `ci-soak.yml` are `schedule` + `workflow_dispatch` only and never run on push/PR *by their own design*; and GitHub runs scheduled workflows **only from the default branch**, where these two files do not exist — they live on `v1.0.0-rc`, so neither nightly has ever fired and neither can until the branch reaches `main`. D-143's own strict >2% throughput gate is already deferred to "a PR check at GA once thresholds are calibrated on stable infra", and D-145 already reads "failures handled in release planning". A manual `workflow_dispatch` run of each before GA is **recommended, not required**. | A gate that cannot physically produce evidence is not a gate; it is a stalled release. Recording the mechanism — scheduled runs need the default branch — turns "we never got round to it" into a known, fixable condition. | v1.0.0 ships without cost or soak evidence. The performance envelope (D-043, D-131) rests on the Tier-1 matrix, the local harnesses, and D-188's commitment to empirical validation by real installs. If a regression exists, the first signal will come from users rather than CI. |
| D-195 | §8.1, §8.6 (supersedes the range framing of **D-108**; D-120/D-121 tiers unchanged) | Locked | **Primary supported range is SQL Server 2014–2025.** SQL Server **2012 is demoted to legacy best-effort** — still expected to run, not presented as a normally supported target. Platform split, stated wherever compatibility is claimed: **2017+ on Linux *and* Windows**; **2014 and 2016 Windows-only** manual Tier-2 targets; **2012 Windows legacy best-effort only**. Grounded in manual v1.0.0 lifecycle attestations (2026-07-29): **2016 Windows** (EngineEdition 2, ProductLevel SP2) and **2014 Windows** (EngineEdition 3, RTM) completed Install → Collect ×2 → Report (incl. `FR_R0026`) → Purge `@WhatIf` → Uninstall all `Success`, so both move to **Verified (manual)**; **2012 Windows** completed the same lifecycle but with `Collect` = `PartialSuccess` on both runs, the `SchemaActivity` collector reporting `dbsDone=0; dbErrors=1; budgetHit=0`. A target with a reproducible collector failure is not a clean verified target, so 2012 is labelled legacy best-effort with the limitation named. | 2012 demonstrably does not deliver the full collector set, and listing it beside 2014–2025 implied a parity the evidence contradicts. Demoting it is more useful than either dropping support (it does run, and the lifecycle completes) or leaving the claim unqualified. Recording 2014/2016 as Verified is the first discharge of D-192's obligation to upgrade status only when real evidence exists. | The released `v1.0.0` artifact still reports `SupportedSqlServerRange = 'SQL Server 2012–2025'`. That string is **not** wrong — 2012 remains supported, best-effort — but it is coarser than this policy, and the artifact is immutable, so the divergence stands until a future release. Docs carry the qualification; anyone comparing the two must read this decision. Users on 2012 get degraded `SchemaActivity` collection with a `PartialSuccess` run status. |
| D-196 | §8.6 (applies D-192's evidence rule to the Azure targets; D-121/D-164 unchanged) | Locked | **Azure SQL Managed Instance and Azure SQL Database are certified as supported**, both **Verified by manual Tier-2 attestation against `v1.0.0`**. MI (`EngineEdition 8`, `ProductMajorVersion 17`, RTM) ran the full lifecycle with every core collector successful and only `AlwaysOnState` skipped, capability-gated. Azure SQL DB (`EngineEdition 5`, `ProductMajorVersion 12`, RTM) ran the full lifecycle with `Collect` returning `Success` while **four collectors skipped by design** — `AgentJobs` and `BackupHistory` (no msdb/Agent), `Deadlocks` (no `system_health` ring buffer), `AlwaysOnState` (not enabled) — each reason surfaced in the `FR_R0026` coverage finding. Both installed 25 core `FR_*` tables + 5 `FR_v_*` views, previewed `Purge @WhatIf`, uninstalled cleanly and left `RemainingFrObjects = 0`. **No equivalence is claimed between the two, nor between either and on-prem**: they are separate products with materially different capability surfaces, attested separately, and neither result may be read across. Docs must also distinguish **SQL Server on Azure VM (IaaS)** — the ordinary engine, inheriting its on-prem row — from these two **PaaS** products. | This is D-192 working as designed: status improves only when someone produces a real run, and both now have one. Certifying MI and Azure SQL DB together while explicitly refusing to generalize between them keeps the useful claim without the unsupported one — the Azure SQL DB evidence in particular is only meaningful *with* its four skips attached. | Both rest on a single manual run each, not a per-push gate, so either can regress silently until re-attested (D-164 staleness). Azure SQL DB users get four fewer collectors permanently; that is a platform limit, not a defect, and the coverage finding says so on every report. |
| D-197 | §11.3 (clarifies the **status** of **D-184**; its decision text stands unchanged) | Locked | **D-184's "Deferred to v0.2" status is obsolete as of `v1.0.0`.** The deferral was not overturned — it was **discharged**: the `FR_v_*` view layer shipped, and the released `v1.0.0` artifact creates exactly five views — `FR_v_RecentRuns`, `FR_v_LatestSnapshots`, `FR_v_CollectorHealth`, `FR_v_RepositoryFootprint`, `FR_v_StatusSupport` (five `CREATE VIEW` statements, verified against the tagged artifact). D-184's condition for shipping them — that the Section 6 contracts ship first and survive a release — was met before they appeared. The views are part of the installed footprint that Install creates and Uninstall removes, and both Azure Tier-2 attestations counted them (25 core `FR_*` tables + 5 `FR_v_*` views). D-184's status is therefore recorded as superseded-by-status only; **no view is added, renamed, or removed by this entry**, and the `FR_v_*` surface is not hereby promoted to a frozen v1.x output contract — the frozen contracts remain those named in D-067/D-071/D-085. | A decision log whose status column lies is worse than one with gaps: a reader checking whether views exist would have concluded they were still two releases away, while the shipped artifact creates them. Recording the discharge keeps the log's status column trustworthy without rewriting what was originally decided, which the log forbids. | Someone may read "the views shipped" as "the views are contractually frozen like the Findings and Timeline result sets". They are not — that is stated above and is the one misreading this entry has to guard against. |
| D-198 | §1.6, §11.4, §11.5 (clarifies the **status** of **D-180** and **D-182**; both decision texts stand unchanged) | Locked | **Two stale deferrals are discharged as of `v1.0.0`**, in the same manner as D-197 — fulfilled, not overturned. **(a) D-180's `@TimeZone` deferral to v0.4:** the parameter ships. It is declared in the artifact, documented in `Help` as *"Report: display-only IANA/Windows time zone for Markdown/Status output"*, and implemented for report rendering — an explicit `@TimeZone` overrides the stored `TimeZoneMode`/`TimeZoneName` config for that run, and falls back to UTC display without error where `HasTimeZoneSupport = 0`. **Storage is unchanged and remains UTC** (`datetime2(3)`, D-016): this is a display concern only, and D-180's other terms — `@StartTime`/`@EndTime` interpreted as server local time, UTC internal storage, offset shown in the Markdown header — are untouched. **(b) D-182's demo-data deferral to v0.2/v0.3:** the mode ships as `@Mode = 'InstallDemoData'`, is never enabled by default, and is guarded — it requires `Install` first and refuses to run where real captured snapshots exist, so demo and real data cannot mix. **One implementation detail differs from D-182's sketch and is recorded rather than glossed:** D-182 proposed an `FRDemo`-isolated schema; no such schema exists. The shipped mode isolates demo rows inside `dbo.FR_*` by a synthetic `InstanceFingerprint`, with the run recorded in `FR_RunLog` under `Mode = 'InstallDemoData'`. The isolation goal was met by a different mechanism than the one sketched. **Neither clause adds runtime behavior, and neither promotes `@TimeZone` or demo-data behavior beyond what the shipped artifact and its mode/parameter docs already describe.** | Same defect D-197 fixed: a Status column asserting something the artifact contradicts. A reader checking whether `@TimeZone` existed would have concluded it was a future release, while `v1.0.0` declares, documents and uses it. Recording the discharge keeps the status column trustworthy without rewriting what was originally decided. Naming the `FRDemo` divergence matters more than tidiness — a future reader comparing D-182 to the code would otherwise find a schema that was never built and reasonably suspect a regression. | Someone may read "the deferrals are discharged" as "these surfaces are now frozen v1.x contracts". They are not: the frozen contracts remain those in D-067/D-071/D-085. `@TimeZone` remains display-only, so any future expansion toward local-time *storage* would be a new decision and a contract change, not an extension of this one. |

---

## Post-1.0 hardening

| ID | Source | Status | Decision | Rationale | Tradeoff accepted |
|---|---|---|---|---|---|
| D-199 | §4 (schema), §5.1/§9.5 (cadence/purge), D-005 (Agent opt-in), D-035 (run-log retention), field evidence from a multi-week deployment | Locked | **Retention is operationally safe by default.** (a) `Install @CreateAgentJob = 1` ensures **two** Agent jobs idempotently: the collector job gains a **`Purge` step after `Collect`** (`@WhatIf = 0`, normal cleanup; pre-existing single-step jobs are upgraded in place), and a separate **`SQLFlightRecorder Purge` daily backstop job** (02:30 server time) protects retention when the collector job is disabled, changed, or failing. `Uninstall` removes both when this tool created them; `@WhatIf` previews both. Agent creation remains opt-in (D-005 unchanged) and capability-gated: on Azure SQL Database/Express the Install result states that both `Collect` and `Purge @WhatIf = 0` must be scheduled externally. (b) **Retention guardrails:** `Configure` accepts `SnapshotRetentionDays` 1–31 and `RunLogRetentionDays` 1–124 only; out-of-range values are refused without updating `FR_Config`. SQLFR is an operational diagnostic recorder, not a long-term warehouse. (c) **Index hardening** (`SchemaVersion` 0.5.0, index-only DDL, forward-only per D-038): nonclustered `SnapshotId` indexes on every `FR_Snapshot` child, `RunId` indexes on `FR_Snapshot`/`FR_RunLogStep`, and `QueryHash` on `FR_Request`, so purge FK verification and window-first report reads stop scanning child tables. (d) **Status result set 7** (additive per D-023) reports retention/purge health; new tunable `RepositoryTableWarnRows` (default 5,000,000). (e) **Report reads are window-first** with a deduplicated, `@MaxFindings`-capped schema-activity timeline and a Coverage warning when capped; output contracts (D-067/D-071/D-085) and rule behavior unchanged, so `RulePackVersion` stays 0.4.3. | A real multi-week deployment without scheduled purge grew `FR_SchemaActivity` past 35M rows and `FR_QueryStoreTopN` past 12M; `Report` ran for hours. A diagnostic tool that silently becomes its own performance problem is a deployment blocker. Purge existed but nothing enforced it; the FK-check scans made purge itself unusably slow once the tables had grown — exactly when it was most needed. | Collect pays for maintaining one extra nonclustered index per child insert (two on `FR_Request`), and the first Install over a grown repository pays a one-time index build. The collector job now reports failure if its purge step fails, which is noisier — and intended. Retention above 31/124 days is no longer expressible; users who need longer diagnostic history must export it. The 02:30 default purge time is a judgment call, adjustable in msdb like any job schedule. |
| D-200 | §7.4 (clarifies the release target of **D-105**; its decision text stands unchanged) | Locked | **D-105's "honored from v1.1" target is re-aimed at a later 1.x minor.** `v1.1.0` is the retention/purge hardening release (D-199) and intentionally changes no rule logic (`RulePackVersion` stays 0.4.3), so the `CriticalWaitTypes` config key remains defined-but-not-honored and `FR_R0003` continues to use the hard-coded D-093 critical-wait list. The key stays in the closed Configure set and is still settable, exactly as D-105 designed; only the release that starts honoring it moves. Live docs (`docs/configuration.md`, `docs/compatibility/support-policy.md`) now say "a later 1.x minor" instead of naming v1.1. | D-105 named a specific version for a rule-behavior change; shipping 1.1.0 without it would make the docs contradict the release. Re-aiming the target in a new entry keeps the log's status column truthful without rewriting D-105 — the same discharge pattern as D-197/D-198. Bundling rule-behavior work into a retention hardening release would also have forced a rule-pack review (D-189) unrelated to the release's purpose. | Users who read D-105's original text expect honoring in v1.1 and must follow this entry to learn it moved. No date is promised for the honoring; it lands when a minor takes it deliberately, with the D-189 rule-review discipline applied. |

---

## Summary

- **Total decisions:** 200 (D-001 through D-200)
- **Locked:** 193
- **Tentative:** 1 (D-181)
- **Deferred items inside otherwise-locked decisions:** 0 — the last one (D-180 `@TimeZone`) was discharged by D-198.
- **Deferred:** 0 — the last one (D-182 demo data) was discharged by D-198. Nothing in this log is now pending a future release.
- **At Risk:** 6 (D-034, D-043, D-076, D-092, D-121, D-164) — each tracked by one of D-188/D-189/D-190
- **Superseded:** 5 (D-185 routing target by D-191; D-108 range framing by D-195; D-184, D-180 and D-182 status only, by D-197/D-198)

No decisions have been silently merged, dropped, or simplified during reconciliation. If a future change supersedes a decision, append a new D-### entry and mark the superseded entry as `Superseded by D-###` rather than editing history.

The three new decisions from the design lock review (D-188, D-189, D-190) are tracking commitments, not redesigns. They do not change v0.1 implementation scope. They make explicit what the design already assumed: that empirical validation, wording discipline, and compatibility-matrix honesty are ongoing responsibilities, not one-time checks.
