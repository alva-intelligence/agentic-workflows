## Testing Policy (STRICT — OPT-IN ONLY)

**Tests are not part of the default workflow.** Agents MUST NOT create tests, run tests, or add test infrastructure unless the user has explicitly asked for it for the current task.

### Hard Rules

- **MUST NOT** create any test files, test cases, or test suites in any service (no `*.test.ts`, `*.spec.ts`, `test_*.py`, `*Test.php`, `tests/` additions, Playwright specs, Vitest/Jest/Pest/pytest cases, etc.).
- **MUST NOT** scaffold test-related tooling the repo doesn't already use (new test runners, fixtures, CI test steps, coverage configs).
- **MUST NOT** run existing test suites (`bun test`, `pnpm test`, `pytest`, `php artisan test`, `vendor/bin/pest`, `npx playwright test`, etc.) unless the user explicitly asks for it in the current request.
- **MUST NOT** infer from a service's existing test files that "this service expects tests" — existing tests exist because a human chose to write them. That choice does not extend to your work.

### If You Believe Tests Would Help

1. **Ask the user first** via your ask tool (Claude Code: `AskUserQuestion`; Cursor: ask tool; OpenCode: question tool; Amp: ask as plain text and wait for a reply).
2. **Default the proposed answer to "No"** — require the user to explicitly opt in. Phrase the question so "no" is the easy choice (e.g., "Add tests for this change? [No (default) / Yes, unit tests / Yes, integration tests]").
3. **Do not write any test code before the user answers "yes."** Treat silence or ambiguous replies as "no."
4. If the user says yes, scope the tests narrowly to exactly what they approved — do not expand coverage on your own.

### What "Explicitly Asked" Looks Like

| User message | Interpretation |
|-------------|----------------|
| "Implement feature X" | No tests. Do not write, do not run. |
| "Add tests for feature X" | Write tests as specified. |
| "Make sure this works" | NOT an ask for tests. Ask a clarifying question if needed. |
| "Run the tests" | Run existing tests only — still do not write new ones. |
| "Fix the failing test" | Fix that specific test; do not add new ones. |

### Why

Auto-generated tests create maintenance debt, slow down iteration, and frequently test the wrong things. The team prefers to add tests deliberately when they're needed, not by default. Err on the side of **not writing tests.**
