# Contributing — overview

This page orients a new contributor; [CONTRIBUTING.md](../../CONTRIBUTING.md) at
the repo root is the authoritative process. The project is deliberately small
and safety-first (design §1, §9); most rejections are about *staying boring and
safe*, not code quality.

## The shape of the project
- One shipped file: `sp_SQLFlightRecorder.sql` (single-script model, D-110/D-152).
- Authoritative context: [docs/design.md](../design.md),
  [docs/decisions.md](../decisions.md). Disputes resolve by quoting them (D-178).
- Phased roadmap (design §11) with **binding** exclusion lists per phase.

## How work flows
1. Open an issue with the matching template (blank issues are disabled).
2. Branch from `main`; one implementation-plan part per PR.
3. Run the linter + self-test, and the Docker matrix/fixtures if you have Docker.
4. Fill the PR template's charter-compliance checklist (D-157).
5. Review: two reviewers for the artifact, one for docs; maintainer for
   safety-checklist items (D-158). The
   [safety checklist](safety-checklist.md) is pasted into reviews when relevant.

## What CI enforces vs. what release validation adds
Hosted CI (`.github/workflows/ci-tier1.yml`) runs, on every push/PR to `main`:
- **static-analysis** — the linter + self-test.
- **doc-coverage** — a page/entry exists for every mode, rule, and config key,
  and the doc generators are in sync (`scripts/check-doc-coverage.sh`, §11.6).
- **Tier-1 SQL matrix** — install → lifecycle → uninstall smoke on SQL Server
  2017 / 2019 / 2022 / 2025 (Linux).
- **rule-fixtures** — the rule fixtures + `InstallDemoData` byte-exact golden
  (`tests/rules/run-rule-fixtures.sh`). Because the fixtures seed `FR_*` rows
  directly, they are engine-version-independent, so hosted CI runs them on
  **2022 only** to keep container minutes bounded.

**Before tagging a release**, run the fixtures/golden locally on the **oldest
and newest** supported engines — at minimum **2017 and 2022** — and ideally the
full six-target matrix (`scripts/run-local-tier1.sh`). This is the belt-and-
suspenders check that the version-independent hosted gate cannot give on its
own.

## Reading order for a first-timer
1. [README.md](../../README.md) → [docs/user-guide.md](../user-guide.md).
2. [coding-style.md](coding-style.md) and [safety-checklist.md](safety-checklist.md).
3. The area you want to touch: [docs/rules/](../rules/) for rules,
   [docs/modes/](../modes/) for modes.
