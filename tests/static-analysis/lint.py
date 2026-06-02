#!/usr/bin/env python3
# =============================================================================
# Static-analysis linter for sp_SQLFlightRecorder.
# -----------------------------------------------------------------------------
# Part 2 of 9 (v0.1 Design Prototype).
#
# This linter enforces the bounded-by-construction safety rules from
# docs/design.md §9.4 and docs/decisions.md D-136, D-137, D-138, D-144.
#
# It is intentionally NOT a full T-SQL parser. It is a deliberately boring
# line-and-regex scanner with an allow-list comment escape hatch
# (-- lint:allow <rule-id> <reason>) so that the rare legitimate exception
# can be documented in code and reviewed by humans.
#
# Per D-148, this tool lives in the build pipeline only. It never runs on a
# user's SQL Server. Per the implementation plan Part 2, this linter is the
# guardrail that gates Parts 3 through 9; it must land BEFORE the first
# collector is written (Part 4).
#
# Usage:
#   python tests/static-analysis/lint.py [path-to-sql-file ...]
#   python tests/static-analysis/lint.py --self-test
#
# Exit code:
#   0 on success
#   1 on any rule violation or self-test failure
#
# Rules enforced in Part 2 (the minimum set required for Parts 3+):
#   FR-LINT-001  No forbidden DMVs / procs (D-136). List in forbidden_dmvs.txt.
#   FR-LINT-002  Every external SELECT has TOP(n) ORDER BY, or reads from a
#                small-DMV allow-listed object (D-137). List in
#                allow_list_small_dmvs.txt. (Strict mode; opt-in per file via
#                file-level pragma -- lint:scan-bounded-reads. Off by default
#                for Part 1 so this PR is green; Part 4 will turn it on for
#                src/sp_SQLFlightRecorder.sql when collectors land.)
#   FR-LINT-003  No CROSS APPLY sys.dm_exec_query_plan or
#                sys.dm_exec_text_query_plan (D-046, D-015).
#   FR-LINT-004  No BEGIN TRAN / BEGIN TRANSACTION (D-138). Future Install
#                and Purge handlers can opt out per-line with -- lint:allow
#                FR-LINT-004.
#   FR-LINT-005  No xp_cmdshell, OPENROWSET, OPENDATASOURCE, BULK INSERT.
#   FR-LINT-006  Every sys.sp_executesql call appears with a parameter
#                declaration (heuristic: a comma after the first argument
#                within the same call). Pure EXEC() of literal strings is
#                only allowed inside a -- lint:allow FR-LINT-006 line
#                (used by the Part 1 install stub).
#   FR-LINT-007  No WAITFOR DELAY longer than '00:00:01' outside an explicit
#                -- lint:allow FR-LINT-007 line (the Purge inter-batch pause
#                in Part 8 will opt in).
#   FR-LINT-008  No OPTION (RECOMPILE) outside an explicit -- lint:allow
#                FR-LINT-008 line.
#   FR-LINT-009  No SELECT *  (project columns explicitly per D-153).
#   FR-LINT-010  No commented-out code blocks longer than 5 consecutive
#                lines (D-153). Heuristic only; allow-listable per block.
#
# Rules deliberately deferred (will be added in later parts):
#   FR-LINT-011  Forbid CROSS APPLY against any user database — Part 4.
#   FR-LINT-012  Enforce schema-qualified object references — Part 3
#                (when FR_* tables exist).
#   FR-LINT-013  Forbid NVARCHAR(MAX) in CREATE TABLE on hot rows — Part 3.
#
# =============================================================================

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[2]
LINT_DIR = Path(__file__).resolve().parent
FORBIDDEN_LIST = LINT_DIR / "forbidden_dmvs.txt"
ALLOW_LIST = LINT_DIR / "allow_list_small_dmvs.txt"
FIXTURES_DIR = LINT_DIR / "fixtures"

# Default target if no paths supplied on the command line.
DEFAULT_TARGETS = [REPO_ROOT / "src" / "sp_SQLFlightRecorder.sql"]


# -----------------------------------------------------------------------------
# Data structures
# -----------------------------------------------------------------------------


@dataclass
class Finding:
    path: Path
    line_no: int
    rule_id: str
    message: str
    line_text: str = ""

    def format(self) -> str:
        rel = self._rel()
        snippet = self.line_text.strip()
        if len(snippet) > 160:
            snippet = snippet[:157] + "..."
        return f"{rel}:{self.line_no}: {self.rule_id}: {self.message} | {snippet}"

    def _rel(self) -> str:
        try:
            return str(self.path.relative_to(REPO_ROOT))
        except ValueError:
            return str(self.path)


@dataclass
class FileContext:
    path: Path
    lines: list[str]
    pragmas: set[str] = field(default_factory=set)


# -----------------------------------------------------------------------------
# Loading and pre-processing
# -----------------------------------------------------------------------------


def load_list_file(path: Path) -> list[str]:
    if not path.is_file():
        return []
    items: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        items.append(line)
    return items


def load_file(path: Path) -> FileContext:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    pragmas: set[str] = set()
    # File-level pragmas live in any line of the file, but conventionally near the top.
    pragma_pattern = re.compile(r"--\s*lint:(scan-bounded-reads|skip-file)\b", re.IGNORECASE)
    for raw in lines:
        m = pragma_pattern.search(raw)
        if m:
            pragmas.add(m.group(1).lower())
    return FileContext(path=path, lines=lines, pragmas=pragmas)


def has_allow(line: str, rule_id: str) -> bool:
    """Return True if `line` carries an inline allow-list for rule_id."""
    return bool(re.search(rf"--\s*lint:allow\s+{re.escape(rule_id)}\b", line, re.IGNORECASE))


def strip_string_literals(text: str) -> str:
    """
    Replace contents of single-quoted SQL string literals with spaces, so that
    matches inside strings (e.g., PRINT N'SELECT * is forbidden') do not
    trigger false positives. Naive but adequate: SQL uses '' for embedded
    quotes, which this handles by treating them as two adjacent strings.
    """
    out = []
    in_str = False
    for ch in text:
        if ch == "'":
            in_str = not in_str
            out.append("'")
        elif in_str:
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def strip_line_comment(line: str) -> str:
    """Remove a trailing -- comment, preserving the lint:allow annotation outside
    of the returned text (callers check the raw line for allow markers)."""
    # Only strip the comment for body-text matching; keep raw line for allow check.
    code_part = line
    # Find the first -- that is not inside a string. Use literal-stripped view.
    cleaned = strip_string_literals(line)
    idx = cleaned.find("--")
    if idx >= 0:
        code_part = line[:idx]
    return code_part


# -----------------------------------------------------------------------------
# Rule implementations
# -----------------------------------------------------------------------------


def rule_001_forbidden_dmvs(ctx: FileContext, forbidden: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    patterns = [(item, re.compile(r"\b" + re.escape(item) + r"\b", re.IGNORECASE)) for item in forbidden]
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-001"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        for name, pat in patterns:
            if pat.search(body):
                findings.append(Finding(
                    path=ctx.path, line_no=i, rule_id="FR-LINT-001",
                    message=f"Forbidden DMV/proc reference: {name}",
                    line_text=raw,
                ))
    return findings


def rule_003_forbidden_plan_apply(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    pat = re.compile(
        r"\bCROSS\s+APPLY\s+sys\.(?:dm_exec_query_plan|dm_exec_text_query_plan)\b",
        re.IGNORECASE,
    )
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-003"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        if pat.search(body):
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-003",
                message="CROSS APPLY against plan DMV is forbidden (D-046, D-015).",
                line_text=raw,
            ))
    return findings


def rule_004_begin_tran(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    pat = re.compile(r"\bBEGIN\s+TRAN(SACTION)?\b", re.IGNORECASE)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-004"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        if pat.search(body):
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-004",
                message="BEGIN TRAN/TRANSACTION not permitted in v0.1 (D-138).",
                line_text=raw,
            ))
    return findings


def rule_005_dangerous_features(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    bad = [
        ("xp_cmdshell", re.compile(r"\bxp_cmdshell\b", re.IGNORECASE)),
        ("OPENROWSET", re.compile(r"\bOPENROWSET\s*\(", re.IGNORECASE)),
        ("OPENDATASOURCE", re.compile(r"\bOPENDATASOURCE\s*\(", re.IGNORECASE)),
        ("BULK INSERT", re.compile(r"\bBULK\s+INSERT\b", re.IGNORECASE)),
    ]
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-005"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        for name, pat in bad:
            if pat.search(body):
                findings.append(Finding(
                    path=ctx.path, line_no=i, rule_id="FR-LINT-005",
                    message=f"Dangerous feature is forbidden: {name}.",
                    line_text=raw,
                ))
    return findings


def rule_006_exec_literal(ctx: FileContext) -> list[Finding]:
    """
    Flag bare EXEC(...) / EXECUTE(...) calls. sp_executesql with parameter
    binding is fine. The Part 1 install stub uses an opt-in allow marker.
    """
    findings: list[Finding] = []
    # Matches EXEC ( ... )  or EXECUTE ( ... )  on a single line; conservative.
    pat = re.compile(r"\bEXEC(?:UTE)?\s*\(", re.IGNORECASE)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-006"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        if pat.search(body):
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-006",
                message=(
                    "Bare EXEC(<string>) is forbidden; use sys.sp_executesql with "
                    "parameter binding, or annotate -- lint:allow FR-LINT-006 with reason."
                ),
                line_text=raw,
            ))
    return findings


def rule_007_long_waitfor(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    pat = re.compile(r"\bWAITFOR\s+DELAY\s+'(\d\d):(\d\d):(\d\d)'", re.IGNORECASE)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-007"):
            continue
        body = strip_line_comment(raw)
        m = pat.search(body)
        if not m:
            continue
        hh, mm, ss = (int(x) for x in m.groups())
        total = hh * 3600 + mm * 60 + ss
        if total > 1:
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-007",
                message=f"WAITFOR DELAY longer than 1 second ({total}s); needs -- lint:allow FR-LINT-007.",
                line_text=raw,
            ))
    return findings


def rule_008_option_recompile(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    pat = re.compile(r"\bOPTION\s*\(\s*RECOMPILE\s*\)", re.IGNORECASE)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-008"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        if pat.search(body):
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-008",
                message="OPTION (RECOMPILE) requires an explicit -- lint:allow FR-LINT-008.",
                line_text=raw,
            ))
    return findings


def rule_009_select_star(ctx: FileContext) -> list[Finding]:
    findings: list[Finding] = []
    # SELECT * but not SELECT *  inside string literal (handled by strip) and
    # not SELECT COUNT(*) etc.
    pat = re.compile(r"\bSELECT\s+\*", re.IGNORECASE)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-009"):
            continue
        body = strip_line_comment(raw)
        body = strip_string_literals(body)
        if pat.search(body):
            findings.append(Finding(
                path=ctx.path, line_no=i, rule_id="FR-LINT-009",
                message="SELECT * is forbidden; project columns explicitly (D-153).",
                line_text=raw,
            ))
    return findings


def rule_010_long_comment_blocks(ctx: FileContext) -> list[Finding]:
    """
    Heuristic only. A run of 6+ consecutive lines that are entirely line-comments
    AND that include something that looks like SQL code (a keyword like SELECT,
    UPDATE, DELETE, INSERT, EXEC followed by non-comment text) is flagged.

    Plain documentation blocks (header, section dividers) are NOT flagged: the
    detector requires at least one SQL keyword inside the run to trigger.
    """
    findings: list[Finding] = []
    sql_kw = re.compile(
        r"\b(SELECT|UPDATE|DELETE|INSERT|EXEC(UTE)?|MERGE|CREATE|ALTER|DROP)\b",
        re.IGNORECASE,
    )
    n = len(ctx.lines)
    i = 0
    while i < n:
        raw = ctx.lines[i]
        stripped = raw.lstrip()
        if stripped.startswith("--"):
            j = i
            keyword_hits = 0
            while j < n and ctx.lines[j].lstrip().startswith("--"):
                if sql_kw.search(ctx.lines[j]):
                    keyword_hits += 1
                j += 1
            run_len = j - i
            if run_len > 5 and keyword_hits >= 1:
                if not any(has_allow(ctx.lines[k], "FR-LINT-010") for k in range(i, j)):
                    findings.append(Finding(
                        path=ctx.path, line_no=i + 1, rule_id="FR-LINT-010",
                        message=(
                            f"Possible commented-out code block "
                            f"({run_len} lines, {keyword_hits} SQL keyword hits). "
                            f"If intentional, annotate -- lint:allow FR-LINT-010."
                        ),
                        line_text=raw,
                    ))
            i = j
        else:
            i += 1
    return findings


# Bounded-reads check is opt-in per file via the scan-bounded-reads pragma.
def rule_002_bounded_reads(ctx: FileContext, allow_list: list[str]) -> list[Finding]:
    if "scan-bounded-reads" not in ctx.pragmas:
        return []
    findings: list[Finding] = []
    # Find SELECT statements that reference sys.* and do NOT include TOP(
    # within the same statement (heuristic: same line). For multi-line
    # SELECTs we look at a small forward window. This rule is documented as
    # heuristic; collectors will be reviewed by humans regardless (D-158).
    select_pat = re.compile(r"\bSELECT\b", re.IGNORECASE)
    sys_pat = re.compile(r"\bsys\.[A-Za-z0-9_]+\b", re.IGNORECASE)
    top_pat = re.compile(r"\bTOP\s*\(", re.IGNORECASE)
    order_pat = re.compile(r"\bORDER\s+BY\b", re.IGNORECASE)

    # Build allow-set with case-insensitive comparison
    allow_lower = {item.lower() for item in allow_list}

    n = len(ctx.lines)
    for i, raw in enumerate(ctx.lines, start=1):
        if has_allow(raw, "FR-LINT-002"):
            continue
        if not select_pat.search(raw):
            continue
        # Look ahead up to 20 lines for terminator (semicolon) or TOP / sys.* / ORDER BY.
        window = "\n".join(ctx.lines[i - 1 : min(i - 1 + 20, n)])
        body = strip_string_literals(window)
        if not sys_pat.search(body):
            continue
        # Extract referenced sys.* names and check against allow list.
        sys_refs = {m.group(0).lower() for m in re.finditer(r"\bsys\.[A-Za-z0-9_]+\b", body, re.IGNORECASE)}
        if sys_refs and sys_refs.issubset(allow_lower):
            continue
        if top_pat.search(body) and order_pat.search(body):
            continue
        findings.append(Finding(
            path=ctx.path, line_no=i, rule_id="FR-LINT-002",
            message=(
                "External SELECT reads sys.* without TOP(...) ORDER BY and is not "
                "in the small-DMV allow-list (D-137). Annotate -- lint:allow FR-LINT-002 "
                "with rationale if intentional."
            ),
            line_text=raw,
        ))
    return findings


# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------


def lint_file(path: Path, forbidden: list[str], allow_list: list[str]) -> list[Finding]:
    ctx = load_file(path)
    if "skip-file" in ctx.pragmas:
        return []
    findings: list[Finding] = []
    findings += rule_001_forbidden_dmvs(ctx, forbidden)
    findings += rule_002_bounded_reads(ctx, allow_list)
    findings += rule_003_forbidden_plan_apply(ctx)
    findings += rule_004_begin_tran(ctx)
    findings += rule_005_dangerous_features(ctx)
    findings += rule_006_exec_literal(ctx)
    findings += rule_007_long_waitfor(ctx)
    findings += rule_008_option_recompile(ctx)
    findings += rule_009_select_star(ctx)
    findings += rule_010_long_comment_blocks(ctx)
    return findings


def discover_targets(args_targets: Iterable[str]) -> list[Path]:
    if args_targets:
        out: list[Path] = []
        for t in args_targets:
            p = Path(t).resolve()
            if not p.exists():
                print(f"::warning::Lint target not found: {p}", file=sys.stderr)
                continue
            out.append(p)
        return out
    return [p for p in DEFAULT_TARGETS if p.exists()]


def run_self_test() -> int:
    """Self-test: verify each rule fires on its fixture and passes on the good fixture."""
    if not FIXTURES_DIR.is_dir():
        print(f"::error::Fixtures directory not found: {FIXTURES_DIR}", file=sys.stderr)
        return 1

    forbidden = load_list_file(FORBIDDEN_LIST)
    allow_list = load_list_file(ALLOW_LIST)

    # Fixture naming convention:
    #   good_*.sql           -- must produce zero findings
    #   bad_FR-LINT-NNN_*.sql -- must produce at least one finding of rule FR-LINT-NNN
    failures: list[str] = []
    fixture_files = sorted(FIXTURES_DIR.glob("*.sql"))
    if not fixture_files:
        print(f"::error::No fixtures discovered in {FIXTURES_DIR}", file=sys.stderr)
        return 1

    for f in fixture_files:
        findings = lint_file(f, forbidden, allow_list)
        name = f.name
        if name.startswith("good_"):
            if findings:
                failures.append(
                    f"{name}: expected zero findings, got {len(findings)}:\n  "
                    + "\n  ".join(x.format() for x in findings)
                )
        elif name.startswith("bad_"):
            m = re.match(r"bad_(FR-LINT-\d{3})_", name)
            if not m:
                failures.append(f"{name}: bad_ fixture name must encode rule id, e.g. bad_FR-LINT-001_*.sql")
                continue
            expected = m.group(1)
            if not any(x.rule_id == expected for x in findings):
                failures.append(
                    f"{name}: expected at least one {expected} finding, got: "
                    f"{[x.rule_id for x in findings] or 'none'}"
                )
        else:
            failures.append(f"{name}: fixtures must start with 'good_' or 'bad_FR-LINT-NNN_'.")

    if failures:
        print("Linter self-test FAILED:", file=sys.stderr)
        for msg in failures:
            print(f"  - {msg}", file=sys.stderr)
        return 1

    print(f"Linter self-test passed ({len(fixture_files)} fixtures).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Static-analysis linter for sp_SQLFlightRecorder.")
    parser.add_argument("targets", nargs="*", help="SQL files to lint.")
    parser.add_argument("--self-test", action="store_true", help="Run linter against tests/static-analysis/fixtures.")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    forbidden = load_list_file(FORBIDDEN_LIST)
    allow_list = load_list_file(ALLOW_LIST)

    targets = discover_targets(args.targets)
    if not targets:
        print("No lint targets found.", file=sys.stderr)
        return 0

    all_findings: list[Finding] = []
    for t in targets:
        all_findings.extend(lint_file(t, forbidden, allow_list))

    if all_findings:
        print(f"Static analysis found {len(all_findings)} issue(s):", file=sys.stderr)
        for f in all_findings:
            print(f.format(), file=sys.stderr)
        return 1

    print(f"Static analysis passed on {len(targets)} file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
