# Implementation Plan — sp_SQLFlightRecorder v0.4.2

**Milestone type:** promised-scope rule completion + report-contract stabilization.
**Base:** `main` at the `v0.4.1` tag (commit `edae76e`).
**Source of truth:** `docs/design.md`, `docs/decisions.md` (D-001–D-190), `docs/design-lock-review.md`.
**No new features.** No plan-XML shredding. No rule-ID rename/reuse/delete.

This plan completes rule logic that was seeded `Active` in `FR_Rules` but never
implemented, and stabilizes the Report output contract. It is the second
hardening-class milestone after v0.4.1.

---

## Invariants (verified against `main` post-v0.4.1, not assumed)

| Constraint | Verdict | Evidence |
|---|---|---|
| `SchemaVersion` stays `0.4.0` | No DDL required by any item | All items read existing tables. `FR_Request` stores `BlockingSessionId`, `OpenTransactionCount`, `RequestedMemoryKb`/`GrantedMemoryKb`/`MemoryGrantTimeUtc` (requests collector populates them via `dm_exec_query_memory_grants`); `FR_InstanceSnapshot.SqlStartTimeUtc` exists; `FR_FileStat` has IO-stall columns. Query-identity dedup uses an internal `#fr_findings` temp column, not persisted schema. |
| Output contract shape unchanged (16-col Findings D-067, 12-col Timeline D-071, 14-key Markdown D-085) | New rules add rows, not columns | Sort (D-068) reorders rows only. No goldens exist yet, so none "break." |
| No rule IDs renamed/reused/deleted | Only new logic wired to already-seeded FR_R0001/0002/0004/0005/0006 | — |
| No plan-XML shredding | FR_R0030–34 remain `Disabled` | — |
| New `FR_Config` seed keys are data, not schema | At most 2 keys (`LongOpenTxnSeconds`, `FileIoLatencyWarnMs`) | Additive seeds honored idempotently by Install (D-038). Must also be whitelisted in Configure and surfaced in Status. |

`ToolVersion` bumps to `0.4.2` in **Group F only**. `SchemaVersion` stays `0.4.0`.

---

## Grouping

Refinement of the A–F request: query-identity dedup plumbing (item 7) and the
`@DeltaStartUtc` delta anchor move into **Group A** (pipeline-shape, and they
touch existing rules R0015/16/18 and R0003/R0020). Only the §7.13 headline folds
stay in **Group E**, because they require R0001/R0002/R0005 to exist first.
This locks the pipeline shape before rules are added, so goldens are baselined
once (Group F) rather than re-locked after every group.

| Group | Scope | Depends on |
|---|---|---|
| A | Deterministic sort (D-068), `@MaxFindings` + overflow finding (D-087), `AnchorKey` temp column + query-identity dedup (D-074), `@DeltaStartUtc` plumbing | — |
| B | FR_R0001 ActiveBlockingChain, FR_R0002 LongRunningOpenTransaction | A |
| C | FR_R0004 FileIoLatencySpike, FR_R0005 MemoryGrantsPending | A |
| D | FR_R0006 restart-delta + window split (D-064) + graded gap findings (D-066) | A |
| E | §7.13 folds (headline folds contributor, D-106) | A, B, C |
| F | Fixtures, goldens, `InstallDemoData` extension, docs/rule pages, CHANGELOG, ToolVersion → 0.4.2 | all |

Each group is one reviewable commit with its own six-target Docker matrix
re-run, mirroring the v0.4.1 cadence.

---

## Group A — Report-contract stabilization

### A1. Deterministic sort tie-breakers (D-068, §6.4)
- **Gap:** final output `ORDER BY` is `CASE Severity …, FindingOrdinal` only — missing Confidence → EvidenceType → StartTimeUtc → RuleId.
- **Sections:** both output `SELECT`s (Default/FindingsOnly) and the Markdown findings loop.
- **Logic:** order `Severity(rank) → Confidence(High>Medium>Low) → EvidenceType(Observed>Inferred) → StartTimeUtc ASC → RuleId ASC → FindingOrdinal ASC`. Informational always last.
- **Decision (recommended):** make `FindingOrdinal` the post-sort **display rank** (`ROW_NUMBER()` over the D-068 order) so it reads 1..N; column and contract unchanged.
- **Tests:** positive — two Medium findings of different Confidence assert High-confidence first; negative — single finding, byte-identical across two runs.
- **Docker:** all six.
- **Risk:** ties on all five keys fall back to FindingOrdinal (total order guaranteed).

### A2. `@MaxFindings` enforcement + overflow truncation finding (D-087, §6.9)
- **Gap:** `@MaxFindings` validated at input and used as per-rule `TOP` caps, but the final result set is never capped and no overflow row is emitted.
- **Section:** after the `@MinSeverity` filter, before output.
- **Logic:** after dedup+filter, if `COUNT(*) > @MaxFindings`, delete lowest-ranked (D-068 order) rows beyond `@MaxFindings − 1`, **never** deleting Critical or Coverage (D-070/D-083); insert one Informational Coverage row (RuleId FR_R0026) reporting the truncation, kept within the cap.
- **Tests:** positive — force >cap findings with `@MaxFindings=10`, assert ≤10 + truncation row; negative — under cap, no truncation row.
- **Docker:** all six.
- **Risk:** Critical/Coverage exemption may keep count slightly above cap when Criticals exceed it — the D-070 "cannot hide Critical" guarantee; document that the cap is safety-bounded, not a hard Critical truncation.

### A3. Query-identity dedup plumbing (D-074, §6.6)
- **Gap:** dedup partitions by `Category, RuleId, DatabaseName, ObjectName, SessionId` — no query identity, so R0016 top-5 collapses to 1 row.
- **Logic:** add internal `AnchorKey nvarchar(300) NULL` to `#fr_findings` (temp table, never output). Query-scoped rules (R0015/16/18) set `AnchorKey = CONCAT(DatabaseName, ':', QsQueryId)`. Dedup partition adds `ISNULL(AnchorKey, N'')`.
- **Tests:** positive — 3 distinct QsQueryIds yield 3 R0016 rows; negative — same QsQueryId dedups to 1.
- **Docker:** 2022/2025 (QS active); 2017/2019 exercise NULL-AnchorKey.
- **Risk:** per-(db+object) rules must leave `AnchorKey` NULL — enumerate them.

### A4. `@DeltaStartUtc` plumbing
- Introduce `@DeltaStartUtc datetime2(3) = @ReportStartUtc` at window setup. No behavior change in A. Group D populates it with the post-restart boundary; delta rules (R0003/R0004/R0020) read it as their "first snapshot" anchor. Keeps B–D independent.

---

## Group B — FR_R0001 / FR_R0002

### FR_R0001 ActiveBlockingChain (Blocking / High / High / Observed — §7.9)
- **Data:** `FR_Request.BlockingSessionId`. **Anchor:** lead-blocker `SessionId` (D-074).
- **Logic:** lead blocker = a `SessionId` that is another row's `BlockingSessionId` in the same snapshot and is not itself blocked. One finding per distinct lead blocker (`TOP (@MaxFindings)`). Wording per §6.7 (never "kill").
- **Tests:** positive — chain 60←55←51, one R0001 for the head; negative — all `BlockingSessionId=0`, none.
- **Docker:** all six.
- **Risk:** exclude self-blocking; folds with FR_R0007 (Group E).

### FR_R0002 LongRunningOpenTransaction (Blocking / Medium / High / Observed — §7.9, D-048)
- **Data:** `FR_Request.OpenTransactionCount`. No elapsed column ⇒ "long-running" = persistence across snapshots (D-081).
- **Logic:** a `SessionId` with `OpenTransactionCount > 0` in first and last of a consecutive-snapshot run spanning ≥ `LongOpenTxnSeconds` (new seed, default 60). One per session; Evidence = span + max open-txn count. Guard against session-id reuse across a restart (same `SqlStartTimeUtc`).
- **Config:** `LongOpenTxnSeconds` (Tentative, D-181-style) + Configure whitelist + Status surface.
- **Tests:** positive — open txn across 3-min span; negative — single snapshot or span < threshold.
- **Docker:** all six.

---

## Group C — FR_R0004 / FR_R0005

### FR_R0004 FileIoLatencySpike (IO / Medium→High / Medium / Inferred — §7.9, D-092/D-103)
- **Data:** `FR_FileStat` cumulative IO-stall; baseline `#fr_baseline` group `FileIo`.
- **Logic:** window delta latency per (DatabaseId, FileId) = `Δ(IoStallRead+IoStallWrite)/Δ(reads+writes)` from `@DeltaStartUtc` to last snapshot (D-007, restart-safe). Fire when > `max(baseline×2, FileIoLatencyWarnMs)`; **escalate High** when > `max(baseline×4, 4×floor)` (magnitude-based; D-069 forbids row-count promotion, not magnitude; §7.9 lists "escalates High"). Confidence Low when baseline <5 samples (D-092).
- **Config:** `FileIoLatencyWarnMs` (default 20).
- **Tests:** positive — rising IoStall delta ≫ baseline → High; negative — flat/low latency or <2 snapshots.
- **Docker:** all six.
- **Risk:** counter reset on restart excluded via `@DeltaStartUtc`. (Note: FR_R0003 currently emits fixed Medium — its documented escalation is also unimplemented; out of listed scope, flagged for optional parity.)

### FR_R0005 MemoryGrantsPending (Memory / High / High / Observed — §7.9, D-048)
- **Data:** `FR_Request.RequestedMemoryKb`/`GrantedMemoryKb`/`MemoryGrantTimeUtc`; `FR_Memory.MemoryGrantsPending` (v0.2) corroboration.
- **Logic (Observed):** request with `RequestedMemoryKb > 0 AND (GrantedMemoryKb IS NULL OR = 0)` = pending grant. Emit per session (anchor `SessionId`, for the R0005/R0024 fold). Include `FR_Memory.MemoryGrantsPending` in Evidence if present. Fixed High.
- **Tests:** positive — requested>0, granted NULL; negative — all grants satisfied.
- **Docker:** all six.
- **Risk:** Report-side over collected rows (no live-DMV risk); folds with FR_R0024 (Group E).

---

## Group D — FR_R0006 restart split + gap findings

### FR_R0006 ServerRestartDuringWindow (Configuration / Critical / High / Observed — §7.9, D-064, §6.2)
- **Gap:** only error-log corroboration exists; no snapshot-start-time delta and no window split.
- **Data:** `FR_InstanceSnapshot.SqlStartTimeUtc` across window snapshots.
- **Logic:** (1) detect restart = distinct `SqlStartTimeUtc` in window, or a value inside the window. (2) Emit FR_R0006 Critical/High/Observed with the boundary; keep the error-log corroboration only if distinct evidence (no intra-rule dup). (3) Window split (D-064): set `@DeltaStartUtc` to the first snapshot whose `SqlStartTimeUtc` equals the latest value, so delta rules stop computing cross-restart nonsense (also corrects R0003/R0004/R0020).
- **Tests:** positive — two `SqlStartTimeUtc` values → R0006 + post-restart delta anchor; negative — constant start time → none, `@DeltaStartUtc = @ReportStartUtc`.
- **Docker:** all six.
- **Risk:** multiple restarts → latest boundary; cross-restart counters otherwise inflate spikes.

### Graded gap findings (D-066, D-104, §6.3)
- **Gap:** only the `<2 snapshots` Critical exists; no per-gap findings.
- **Logic:** gap = `DATEDIFF(s, prev, cur)`. When > 2× `SnapshotIntervalSeconds`, emit Coverage finding scaled per D-066: Medium (2–5×), High (5–30×), Critical (>30× or ≥50% of window). Per-gap findings carry RuleId FR_R0026, dedup-exempt (D-075), coexisting with the FR_R0026 summary (D-104).
- **Tests:** positive — snapshots at 0/1/40 min → High/Critical gap; negative — 1-min cadence → none.
- **Docker:** all six.
- **Risk:** a gap that is a restart emits both the gap finding and R0006 (D-104); avoid double-firing Critical with the `<2 snapshots` case.

---

## Group E — §7.13 folds (headline folds contributor)

- **Refs:** §7.13, D-106 (headline keeps RuleId; contributors in `MoreInfo`; disabling a contributor ≠ disabling the headline), D-074.
- **Pairs:** (1) FR_R0007 folds FR_R0001/FR_R0002; (2) FR_R0005 ↔ FR_R0024; (3) FR_R0015 ↔ FR_R0016 only when same query_id.
- **Mechanism:** a fold pass after per-rule dedup, before filter/sort; static fold map `(category, headlineRuleId, [contributorRuleIds], anchor)`. Each present headline deletes contributor rows sharing the anchor and appends their identity to `MoreInfo` (D-106). Pair 3 anchors on `AnchorKey`.
- **DECISION NEEDED before coding E:** pairs 1 and 2 mix granularities (R0007/R0024 window-level; R0001/R0002/R0005 session-level), so "same anchor" is under-specified. Proposed conservative reading: a window-level headline folds its session-level contributors **window-wide**, recording folded session IDs in `MoreInfo`; pair 3 folds only on exact `AnchorKey`, keeping R0015 as headline. The strict alternative (literal session-anchor equality) makes §7.13 a no-op. **Sign off before Group E.**
- **Tests:** positive — storm + chain same window → one R0007, R0001 in MoreInfo; negative — R0016 query A + R0015 query B → both survive.
- **Docker:** all six; pair 3 needs QS (2022/2025).
- **Risk:** run after per-rule dedup; respect D-106; over-folding window-wide is the main risk (hence sign-off).

---

## Test strategy

| Layer | Approach |
|---|---|
| Static linter | `lint.py` exit 0 every group. New rules read only `FR_*` (D-014/D-081); no DMV/`SELECT *`/forbidden patterns. Self-test 11 fixtures unchanged. |
| Six-target Docker matrix | Re-run the `run-target` driver (extended with new-rule assertions) on 2017/2019/2022/2025 Dev + 2022 Express/Standard after each group; full green gate before Group F. |
| Targeted synthetic / demo | Extend `InstallDemoData` to seed rows triggering R0001/R0002/R0004/R0005/R0006 and a gap; one command exercises all new rules. Keep demo-fingerprint refusal. |
| Positive/negative fixtures (D-160) | One `.sql` fixture per new rule under `tests/fixtures/`: seed `FR_*` with fixed `SnapshotUtc`, run Report with explicit `@StartTime/@EndTime`, assert fire (positive) / no-fire on look-alike (negative). Ten fixtures. |
| Golden output (D-122) | Byte-exact `Default`/`FindingsOnly` from the deterministic demo fixture (fixed `SnapshotUtc` + explicit window ⇒ fixed times). Markdown goldens mask `Report-Run-Id`, `Report-Generated-Utc`, `Instance-Fingerprint`. New rules version-agnostic ⇒ one golden; QS-dependent goldens per-version. Baselined once in Group F. |
| Backward compatibility | (a) R0007–R0026 and all modes green on matrix. (b) Upgrade path: install v0.4.1 → Collect → install v0.4.2 over it → Report works, new seeds present, `SchemaVersion` still 0.4.0. (c) No-trigger report differs from v0.4.1 only in deterministic sort order — assert it. |
| Performance / cost | Rules are set-based Report-time reads bounded by window; dedup/fold/sort O(findings). No new Collect cost. Lightweight `Report < 5 s` driver assertion until the D-143/D-080 cost harness (deferred) exists. |

---

## Sequencing and sign-off

- Order: A → B, C, D → E → F. Each group independently mergeable and matrix-green.
- Sign-off items: (1) Group A — `FindingOrdinal` as display rank (recommended); (2) Group E — window-level fold anchor semantics (recommended conservative window-wide fold); (3) two Tentative config seeds vs. hard-coded.
- `ToolVersion` → `0.4.2` in Group F; `SchemaVersion` stays `0.4.0`.
