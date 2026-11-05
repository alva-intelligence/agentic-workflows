## Verification Policy (lean, evidence-based)

Verification is how the agent proves a change works. It is not a separate test-authoring program.
No dependency, runner, fixture, or CI test step is added for verification.

### Default verification

Run the checks that already exist and are relevant to the touched behavior:

- lint / type check / static analysis on the changed files,
- targeted existing tests for the affected module,
- a build or command-level smoke check when the change affects a runnable path,
- a minimal regression check around the behavior that could have broken,
- manual reproduction for UI or local flows.

Risk scaling:

| Risk | Verification |
|---|---|
| Low | targeted lint/type check + smoke/manual check of the touched surface |
| Medium | targeted existing tests + lint + behavior check + minimal regression |
| High (auth, data, migrations, live estate, cross-service contract) | adversarial review + broader minimal regression + rollback/recovery check |

Record the command/action and the observed result as evidence in the track. A claim without an
observed result is not evidence.

### New tests are opt-in

- **Do not** create new test files, suites, fixtures, or test infrastructure unless the user
  explicitly asked for tests in the current task.
- **Do not** add test dependencies or change the test runner.
- **Do not** infer from an existing test suite that new tests are expected. Existing tests exist
  because a human chose to write them; that choice does not extend to your change.
- Running relevant **existing** tests is allowed and encouraged. Running an entire suite when a
  targeted check answers the question is waste, not diligence.

### If new tests would materially help

Ask once, default to **no new tests**. If the user says yes, scope the tests narrowly to exactly
what they approved. Silence or an ambiguous answer means no.

### What "explicitly asked" looks like

| User message | Interpretation |
|---|---|
| "Implement feature X" | No new tests. Run relevant existing checks. |
| "Add tests for feature X" | Write the specified tests. |
| "Make sure this works" | Not an ask for new tests. Verify with existing checks/manual proof. |
| "Run the tests" | Run existing tests only; do not write new ones. |
| "Fix the failing test" | Fix that specific test; do not add new ones. |

### Wording

Never call a passing build, lint run, test run, or manual check "formal verification" or a
"formal proof". Say what was run, what was observed, and what remains unverified.

### Delivery interaction

Automatic checks run before the delivery checkpoint regardless of the chosen delivery mode. For
`local_test`, the user tests the local flow manually first using the URL/path and steps the agent
provides; keep the requested server and branch in place until they finish, keep the task and
delivery pending, and do not mark completion or clean up. After the manual result, the user chooses
`open_pr` or `auto_merge` and the normal phases continue. For `open_pr`/`auto_merge`, the PR
pipeline uses the same evidence and does not require a new test suite.
