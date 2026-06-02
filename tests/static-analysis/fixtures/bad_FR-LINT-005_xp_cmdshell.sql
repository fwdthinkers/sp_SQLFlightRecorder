-- Must trigger FR-LINT-005 (and FR-LINT-001 also lists xp_cmdshell; either is fine).
EXEC xp_cmdshell 'dir';   -- lint:allow FR-LINT-006 reason: testing FR-LINT-005, not 006
