## Verification Policy

Use reproducible evidence, not an unqualified claim of proof. Do not add dependencies, runners, or
test infrastructure for ordinary verification.

### Default checks

- Run relevant existing targeted tests, lint, type checks, and build/command smoke checks.
- For non-trivial logic, leave one small runnable regression check; reuse an existing check where
  sufficient. A trivial one-line change needs no new test.
- Exercise the changed behavior and its important failure paths; manually reproduce UI/local flows.
- Do not run a whole suite when a targeted check answers the question. New suites or frameworks are
  outside default verification; discuss them only when the task actually needs them.

| Risk | Evidence |
|---|---|
| Low | targeted lint/type check and smoke/manual check |
| Medium | targeted tests, behavior check, and minimal regression |
| High: auth, data, migrations, live estate, cross-service contract | adversarial review, broader targeted regression, rollback/recovery check |

Record exact commands/actions, expected and observed results, and unverified behavior in the track.
A passing build, test, or manual check is verification evidence, not mathematical formal verification
or an exhaustive proof. Never describe it as one.

### Delivery

Automatic checks happen before delivery regardless of mode. `local_test` then lets the user test
manually first: provide the URL/path and steps, keep the requested server and branch available, and
leave the delivery checkpoint pending. After the result, the user chooses `open_pr` or `auto_merge`.
Neither local testing nor a passing check grants publication or merge permission.
