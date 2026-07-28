# Handoff — v1.0.0-rc.1

Full context for picking up the `sp_SQLFlightRecorder` v1.0.0 release candidate.
Written 2026-07-21. This is a hub; it links the authoritative docs rather than
duplicating them.

## Snapshot
| | |
|---|---|
| Branch | `v1.0.0-rc` (cut from `b9d4cd3` = the `v0.4.3` tag), tracking `origin/v1.0.0-rc` |
| HEAD | `504492e` — "handoff document for the completed RC branch" (before this cleanup commit) |
| Artifact version | `ToolVersion 1.0.0-rc.1`, `SchemaVersion 0.4.0`, `RulePackVersion 0.4.3` |
| Working tree | clean |
| Pushed? | **Yes** — pushed 2026-07-21; `origin/v1.0.0-rc` exists and is in sync |
| Tagged? | **No** `v1.0.0-rc.1` tag — tags are only `v0.4.1`, `v0.4.2`, `v0.4.3` |
| Published? | **No** — no GitHub Release, prerelease or otherwise |
| Status | **Tag-ready**; see [release-readiness-v1.0.0-rc.1.md](release-readiness-v1.0.0-rc.1.md) |

**Standing rule:** the owner authorizes every push, merge, tag, and publish. The
branch is pushed; nothing has been merged, tagged, or published.

## What this RC is
A **documentation, CI/release-process, and version-metadata** stabilization on
top of `v0.4.3`. It changes **no persisted schema, output contract, rule ID,
rule logic, collector, or mode**. The only artifact change across the whole RC is
the version metadata (Group F commit 1); everything else is docs, tests, CI, and
release tooling. Scope authority: `docs/decisions.md` (append-only, D-178) and
`docs/design.md`.

## RC commit inventory (18 group commits, `b9d4cd3..730af8f`)
Followed by `504492e` (this handoff doc) and one pre-RC documentation-cleanup
commit (stale pushed-state corrections + removal of the public `TODO` contact
placeholders). Neither touches the artifact.
- **Group A** `6872151` — doc inventory + stale-reference cleanup (also the one
  earlier artifact reword: unreachable fallthrough → `UnhandledMode` default).
- Samples `af1cacb` — documentation structure samples (approved before mass docs).
- **Group C** `358fc3e` — security/process docs + all 8 issue templates.
- **Group B** `be94679`, `f8c48a1`, `bc4ad22` — rule docs (31), mode docs (12),
  configuration/capability/compatibility + index.
- **Group D** `9babab0`, `03ff811`, `4a989bb`, `e1c366e`, `4c17fc6` —
  doc-coverage gate; rule fixtures + golden in CI; dry-runnable `release.yml`;
  compat-matrix generator; cost + soak harnesses (non-blocking).
- **Group E** `31500d2`, `956cb29`, `eb3d7e6` — upgrade-path harness; edition/
  compat matrix (6 verified targets); Tier-2 attestation process + helpers.
- **Group F** `4d6deca`, `3a10ce4`, `3e906b7`, `730af8f` — version `1.0.0-rc.1`
  + CHANGELOG; wording-lock review; §12/§13 fold + support policy; release
  dry-run + readiness report.

## Key decisions locked this cycle
- **`RulePackVersion` stays `0.4.3`** (owner-approved). Per D-085 it names the
  release that last changed rule logic/catalog; the RC changed no rules. It only
  coincidentally equalled `ToolVersion` before because every `0.4.x` patch
  touched rules. Divergence is intentional and documented in the artifact.
- **`SchemaVersion` stays `0.4.0`** — forward-only, no DDL (D-038).
- **Plan-XML analysis stays removed/disabled** (FR_R0030–34 reserved, disabled;
  D-015/046/082/136). Not a roadmap item.
- **Output contracts frozen** for v1.x: Findings 16-col (D-067), Timeline 12-col
  (D-071), Markdown 14-key header (D-085). See [compatibility/support-policy.md](compatibility/support-policy.md).
- Repo conventions: single-file artifact at repo root (D-110/D-152); LF endings
  via `.gitattributes`; `.gitignore` covers `dist/` + Python caches; `.claude/`
  excluded via `.git/info/exclude` (local, never committed).

## Validation status (all green, 2026-07-21)
Run on the completed RC branch:
- `check-doc-coverage.sh` — 12 modes / 31 rules / 36 config keys; no orphans.
- `lint.py sp_SQLFlightRecorder.sql` + `--self-test` (11 fixtures).
- `gen-rule-docs.py --check`, `gen-mode-docs.py --check`,
  `gen-compat-matrix.py --check` — all in sync.
- `build-release-artifact.sh --version 1.0.0-rc.1` — byte-identical 344,857-byte
  artifact, SHA256 `2ae4c475…` (reproducible across runs), 43-line notes.
- `run-upgrade.sh` — **21 passed, 0 failed, 1 unavailable**.
- Rule fixtures + demo golden — **19/19** on SQL 2022 (Group F commit 1).
- RC artifact re-verified on 2022 Developer/Express/Standard (EngineEdition 3/4/2).

## Verified vs pending
- **Upgrades:** 0.4.1 / 0.4.2 / 0.4.3 → rc.1 verified (install-over Success,
  `SchemaVersion` stays 0.4.0, no DDL migration, no `FR_*` data dropped, Report
  works). **v0.4.0 pending** — no public `v0.4.0` tag exists (not faked).
- **Tier 1 verified:** 2017/2019/2022/2025 Developer + 2022 Express/Standard.
- **Tier 2 pending attestation:** 2012/2014/2016 Windows + Azure MI/DB.

## Tracked before FINAL v1.0.0 (none are code changes)
No public-facing `TODO` placeholders remain — `SECURITY.md` and
`CODE_OF_CONDUCT.md` now state the current channel honestly instead. The
underlying items are still open:

1. **Private security contact** — configure a dedicated one, or enable GitHub
   private vulnerability reporting. `SECURITY.md` currently says, without
   inventing an address, that the preferred channel is private vulnerability
   reporting *if enabled*, and that no dedicated contact exists otherwise.
2. **Conduct contact** — configure a dedicated one. `CODE_OF_CONDUCT.md`
   currently routes reports to the owner/maintainers via available GitHub
   channels and says no dedicated address is configured yet.
3. **CODEOWNERS owner** — `@forward-thinkers-lab/core-maintainers` is unverified
   and may resolve to nothing (GitHub ignores unresolvable owners silently, so
   the rules are likely a no-op). Create and grant the team, or replace it with
   real individual handles. See the header of `.github/CODEOWNERS`.
4. Two-maintainer §6.7 wording sign-off (D-076/D-158/D-189) — the systematic
   review is in [wording-lock-review.md](wording-lock-review.md); the human
   sign-off remains.
5. ≥ 4 of 5 Tier-2 attestations (§11.6).
6. Optional: `tests/upgrade/artifacts/v0.4.0.sql` to validate the v0.4.0 upgrade
   path. Not a public promise, so not an RC blocker.

## How to release (owner-authorized only)
1. (Optional) dry-run the release build: `bash scripts/build-release-artifact.sh
   --version 1.0.0-rc.1` — inspect `dist/` (git-ignored).
2. Push the branch — **already done** (2026-07-21). Re-push after any further
   commits: `git push origin v1.0.0-rc`. Each push triggers `ci-tier1`
   (static-analysis + doc-coverage + 4-target matrix + rule-fixtures); confirm
   it is green before tagging.
3. (Optional) run `release.yml` via `workflow_dispatch` for a full dry-run (gate
   + build; publishes nothing).
4. Tag and push: `git tag -a v1.0.0-rc.1 -m "…"` then `git push origin
   v1.0.0-rc.1`. The tag push runs `release.yml`: gate → build byte-identical
   artifact + `SHA256SUMS` + compat-matrix snapshot → publish a **prerelease**
   GitHub Release (the `-rc.1` suffix auto-marks prerelease).
   - `release.yml` asserts the tag equals the artifact `Tool-Version` header, so
     the tag must be `v1.0.0-rc.1`.
5. Before **final** `v1.0.0`: resolve the tracked items above, bump `ToolVersion`
   → `1.0.0`, add a CHANGELOG `1.0.0` entry, run this validation wave again.

## Repo map
- Artifact: `sp_SQLFlightRecorder.sql` (repo root).
- Generators: `scripts/gen-rule-docs.py`, `gen-mode-docs.py`,
  `gen-compat-matrix.py` (each `--check`-guarded in CI).
- Gates/build: `scripts/check-doc-coverage.sh`, `build-release-artifact.sh`,
  `run-static-analysis.sh`, `run-local-tier1.sh`.
- Tests: `tests/rules/` (fixtures+golden), `tests/static-analysis/` (linter),
  `tests/upgrade/`, `tests/perf/` (cost+soak), `tests/compat/` (attestation
  evidence).
- Workflows: `.github/workflows/ci-tier1.yml` (blocking), `release.yml` (tag/
  dispatch), `ci-cost.yml` + `ci-soak.yml` (nightly, non-blocking).
- Key docs: [design.md](design.md) (§1–§13), [decisions.md](decisions.md),
  [implementation-plan-v1.0.0-rc.md](implementation-plan-v1.0.0-rc.md),
  [release-readiness-v1.0.0-rc.1.md](release-readiness-v1.0.0-rc.1.md),
  [wording-lock-review.md](wording-lock-review.md),
  [compatibility/matrix.md](compatibility/matrix.md),
  [compatibility/tier2-attestation.md](compatibility/tier2-attestation.md),
  [compatibility/support-policy.md](compatibility/support-policy.md).

## Re-validate anytime
```bash
bash scripts/check-doc-coverage.sh
python tests/static-analysis/lint.py sp_SQLFlightRecorder.sql
python tests/static-analysis/lint.py --self-test
python scripts/gen-rule-docs.py --check
python scripts/gen-mode-docs.py --check
python scripts/gen-compat-matrix.py --check
bash scripts/build-release-artifact.sh --version 1.0.0-rc.1   # needs bash
bash tests/upgrade/run-upgrade.sh                             # needs Docker + git
```
