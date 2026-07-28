# Implementation Plan — sp_SQLFlightRecorder v1.0.0-rc

**Milestone type:** stabilization and release-readiness. **No new product features.**
**Base:** `main` at the `v0.4.2` tag, plus the `v0.4.3` FR_R0003 escalation patch.
**Source of truth:** `docs/design.md` (§11.6, §11.8), `docs/decisions.md` (D-001–D-190).

Per design §11.6, v1.0 delivers: bug fixes from the v0.4 RC; static-analysis
extensions; **documentation completeness** (every mode, rule, collector, config
key, capability flag); design doc published; runnable examples; full Tier-1
matrix green; Tier-2 attestation for **≥4 of 5** targets; release process
**dry-run twice**; hotfix rehearsed; **wording lock**; the "1.0 is forever"
promises. §11.6 **binding exclusion:** no new collectors, rules, modes,
parameters, capability flags, or view-layer expansion; **no behavior-changing
PRs.**

## Invariants (must not change in v1.0.x)
- `SchemaVersion` stays `0.4.0` (no DDL).
- 16-column Findings (D-067), 12-column Timeline (D-071), 14-key Markdown
  header (D-085) — frozen.
- Rule IDs frozen; none renamed, reused, or retired (D-089).
- No plan-XML shredding (D-015/046/082/136); `@IncludeQueryPlans=1` stays the
  honest reserved no-op.

## Already-complete technical base
- **v0.4.1**: decision-log compliance restored; plan-XML shredding removed;
  Purge/Uninstall bugs fixed; CI/linter/scripts repaired; six-target matrix green.
- **v0.4.2**: FR_R0001/0002/0004/0005/0006; restart window split (D-064) + gap
  findings (D-066); §7.13 folds; deterministic sort (D-068); `@MaxFindings`
  overflow (D-087); query-identity dedup (D-074); fixtures/golden; six-target
  matrix green.
- **v0.4.3** (this patch series, pre-RC): FR_R0003 escalation to High on
  hard-coded critical wait types (D-093), completing §7.9 before the v1.0 lock.

---

## Readiness scorecard

| Gate | Decision | Status | Group |
|---|---|---|---|
| Tier-1 matrix green | D-120 | done | — |
| Goldens exist / wired into CI | D-122 | exist; not wired | D |
| All 12 modes documented | §11.6 | 3 of 12, stale | A/B |
| All rules documented (`docs/rules/`) | D-161 | missing | B |
| Config keys + capability flags documented | §11.6 | missing | B |
| Compatibility matrix | D-165 | missing | B/D |
| Failure-mode catalog | D-147 | missing | C |
| Examples (CI-tested) | D-170 | missing | B/D |
| §12 security + SECURITY.md | Q-041 | missing | C |
| §13 appendices | Q-042 | missing | C |
| Contributing/support/CoC | D-151/179 | missing | C |
| 8 issue templates + CODEOWNERS | D-156/163 | 0/8, none | C |
| Release workflow + dry-run ×2 | D-173 | missing | D/F |
| Cost-regression + soak | D-143/145 | missing | D |
| Tier-2 attestation (≥4/5) | D-164/190 | undefined | E |
| Upgrade path 0.4.x → 1.0 | D-038 | untested | E |
| Wording lock (26 rules) | D-076/189 | not done | F |
| "1.0 is forever" promises | §11.8 | not written | F |

---

## Group A — Documentation inventory & stale-reference cleanup
**RC-required. Comment/message strings only; no artifact behavior change.**
- Fix 4 cosmetic `src/` strings: `.github/PULL_REQUEST_TEMPLATE.md`,
  `tests/sp_SQLFlightRecorderManualScenarios.sql` (RAISERROR text),
  `tests/static-analysis/allow_list_small_dmvs.txt`,
  `tests/static-analysis/fixtures/good_part1_shape.sql`.
- Confirm the `NotYetImplemented` fallthrough is unreachable; comment as the
  defensive default.
- New `docs/README.md` index mapping every mode/rule/collector/config-key/
  capability-flag to its doc page (drives B/C coverage).
- **Validation:** `grep -rn 'src/sp_SQLFlightRecorder' .` → 0; lint exit 0.
- **Risk:** trivial. **Code change:** cosmetic only.

## Group B — Rule / mode / compatibility docs
**RC-required. No artifact code.**
- `docs/rules/_template.md` (D-161: severity/confidence/evidence rationale, FP
  risks, drill-down, suppress instructions, baseline math per D-092).
- Per-rule pages `docs/rules/FR_R0001..FR_R0026.md` (26) + `FR_R0030..FR_R0034.md`
  (5, marked Disabled with the D-015/046/082/136 rationale). Auto-generated index.
- Complete `docs/modes/*.md` for all 12 modes; retire Part-3 language in the 3
  existing pages.
- `docs/configuration.md` (all 38 FR_Config keys incl. LongOpenTxnSeconds,
  FileIoLatencyWarnMs) and `docs/capability-snapshot.md` (closed key set D-127).
- `docs/compatibility/matrix.md` (D-165); README badge links to it.
- **Validation:** new `scripts/check-doc-coverage.sh` asserts a page for every
  mode/rule/config-key parsed from the artifact; 0 gaps.
- **Risk:** volume (~45 pages); generate stubs from FR_Rules seed + mode list.
  **Code change:** none to the artifact; one build-pipeline audit script.

## Group C — Security / support / release-process docs
**RC-required. No artifact code.**
- `docs/design.md` §12 security/threat model (Q-041): threat model (insider DBA
  with VSS; non-DBA repo reader; supply-chain on the single artifact),
  FR_QueryText data sensitivity, repo access-control recommendation; consolidates
  D-118/119/060/179.
- `docs/design.md` §13 appendices (Q-042): glossary, references, charter
  quotation, failure-mode catalog reprint.
- `SECURITY.md`, `SUPPORT.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
  `docs/contributing/{overview,coding-style,safety-checklist}.md` (D-153/176/160/187).
- `docs/operations/troubleshooting.md` — failure-mode catalog (D-147); referenced
  from README.
- 8 issue templates `.github/ISSUE_TEMPLATE/*.yml` (D-156) + `.github/CODEOWNERS`
  → `@core-maintainers` (D-185). *Amended 2026-07-28:* the repo is a user
  account, not an org, so CODEOWNERS routes to `@forward-thinkers-lab` instead
  (D-191 supersedes D-185's routing target).
- **Validation:** markdown link-check; doc audit 0 gaps.
- **Risk:** §12 is genuinely new analysis (design-lock review did no threat
  modeling); dedicate a review pass. **Code change:** none.

## Group D — CI golden / cost / soak / release workflow wiring
**Mix RC/final. Build-pipeline only (YAML + harnesses); never the artifact (D-148).**
- Golden in CI (D-122): add a job running `tests/rules/run-rule-fixtures.sh` per
  matrix target; byte-diff fails CI. **RC.**
- Doc-coverage gate (`scripts/check-doc-coverage.sh`) in CI. **RC.**
- Cost-regression (D-143): `tests/perf/` + `ci-cost.yml`; fail >2% throughput
  drop or >10 s collect. Final (RC-time acceptable).
- Soak (D-145): nightly `ci-soak.yml`; repo growth, Purge keeps up, Report <5 s.
  Final.
- Release workflow `release.yml` (D-173): on tag, lint + Tier-1 gate, build
  versioned artifact, regenerate matrix, attach to Release. **RC** (dry-runnable).
- Compat-matrix generator `scripts/gen-compat-matrix.py` (D-165).
- **Validation:** CI green incl. golden + doc-coverage; release dry-run builds a
  byte-identical artifact.
- **Risk:** cost-regression harness stability; runner Docker limits for soak.
  **Code change:** CI/harness only.

## Group E — Upgrade / Tier-2 / compat validation
**RC + ongoing. Validation only.**
- Upgrade path `tests/upgrade/run-upgrade.sh` (D-038): for each of v0.4.0/0.4.1/
  0.4.2, install old → Collect → install v1.0 over it → assert Report works, new
  seeds present, SchemaVersion still 0.4.0, no data loss. **RC.**
- Six-target matrix + `run-rule-fixtures.sh` at the RC tag; oldest/newest
  fixtures on 2017 + 2025. **RC.**
- Edition validation: Developer/Standard/Express confirmed; document Enterprise ≡
  Developer engine; Azure-equivalent noted. On-prem **RC**; Azure Tier-2.
- Tier-2 attestation (D-164/190): author the `version-compat` attestation
  template + process (auto-open per RC; staleness→Unverified at 3 minors;
  deprecation at 6) for 2012/2014/2016 Win + Azure MI + Azure DB. RC: process
  live; **final: ≥4/5 attested**.
- **Risk:** Tier-2 depends on external attesters / real hardware (D-190 puts it
  on 18-month probation). **Code change:** none.

## Group F — Final RC polish, CHANGELOG, version bump, release checklist
**RC → final. Version metadata + docs only.**
- Version: `1.0.0-rc.1` at RC → `1.0.0` at GA; `@RulePackVersion` → `1.0.0`;
  SchemaVersion stays `0.4.0`.
- Wording lock (D-076/189): two-maintainer §6.7 review of all 26 active rules;
  lock afterwards.
- `docs/compatibility/support-policy.md` + README: "1.0 is forever" promises
  (§11.8) — no v1.x contract breaks, forward-only schema, IDs/columns frozen,
  ≥18-month support.
- CHANGELOG `1.0.0-rc.1` then `1.0.0` (D-175).
- Release dry-run ×2 (D-173) + hotfix rehearsal (D-174).
- `@TimeZone` display path documented + fixture; `CriticalWaitTypes` config
  honoring stays v1.1 (D-105) — not in scope.
- **Risk:** wording lock is human/subjective (D-189). **Code change:** version
  string only.

---

## Release criteria

**Green for `v1.0.0-rc` (the tag):**
1. Six-target Tier-1 matrix FAIL=0 + fixtures/golden green, wired into CI.
2. Doc completeness (modes/rules/config/capabilities); compat matrix (Tier-1
   half); doc-coverage gate green.
3. §12 + §13 + SECURITY/SUPPORT/CoC/CONTRIBUTING + failure-mode catalog + 8 issue
   templates + CODEOWNERS present.
4. `release.yml` dry-runs; upgrade paths 0.4.0/0.4.1/0.4.2 → 1.0 validated.
5. Tier-2 process live; wording-lock pass; ToolVersion `1.0.0-rc.1`; CHANGELOG.
6. Lint exit 0; SchemaVersion `0.4.0`; contracts + rule IDs unchanged.

**Additional gates before final `v1.0.0`:**
- Tier-2 attestation ≥4/5 (D-164, §11.6).
- Release dry-run twice + hotfix rehearsed (D-173/174).
- Cost-regression + soak green once (D-143/145).
- "1.0 is forever" promises published; wording locked.

**Deferrable past v1.0 (per decisions):**
- `CriticalWaitTypes` config honoring → v1.1 (D-105).
- Full Tier-2 coverage of all 5 targets (≥4/5 suffices; D-190 18-month review).
- `FR_v_*` expansion, new collectors/rules — permanently out of v1 (§11.7).

**Would block release:**
- Any matrix regression / non-deterministic output / golden drift.
- Reintroduced plan-XML / forbidden DMV (lint gate).
- Upgrade path that loses data or bumps SchemaVersion.
- FR_R0003 escalation left unresolved before the contract/wording lock (fixed in
  v0.4.3, ahead of RC).

## Sequencing
A → C → B → D → E → F. Groups B and C (≈45 doc pages + security authorship) are
the critical path; the rest is comparatively mechanical. Nearly all of
v1.0.0-rc is docs/CI/process with zero artifact-behavior change (§11.6).
