---
name: visual-testing
description: Validate UI work with real browser or native-app evidence — true headless when headless is required, a shared bounded browser instance, resource preflight, one tab per task, and no pretending a browser screenshot proves a native desktop app.
---

# Visual Testing — evidence, not narration

The agent's visual truth comes from a real browser or the real native app. Anything claiming "it
renders" gets this treatment: the implementing subagent first, the orchestrator independently.

## Resource discipline (strict — this runs on the user's machine)

- **Preflight before spawning anything.** Run the resource check (`~/.agents/bin/res-ok`, or the
  equivalent CPU/memory check) before starting a browser, headless instance, cloud daemon, or dev
  server. It exits non-zero at 85% CPU or memory; if it fails, wait and retry, and **do not spawn**.
  The same check applies before a second browser process.
- **True headless only when the label is true.** A dedicated browser started with
  `--headless=new` (or a managed cloud browser) has no window and is headless. **Attaching to the
  user's already-running Chrome is background-tab testing, not headless testing** — it uses their
  browser process, profile, and memory, and can surface a window. Do not call it headless, and do
  not use it when the task requires headless. Use the user's Chrome only when the check genuinely
  needs their signed-in session; say so in the evidence.
- **One shared browser instance per testing round.** Start it once, then reuse it for the whole
  round. Subagents share the same instance/session and open their **own tabs**; never spawn a
  browser per subagent. One active tab per task/site. Reuse it via `current_tab()` /
  `switch_tab()`; never leave duplicate tabs on a URL and never close tabs you did not create.
- **Bound the round.** Default: one local browser instance, one tab per task, no recordings. If a
  parallel or isolated browser is genuinely required, ask before starting a cloud daemon — it bills
  per minute — and stop it the moment the check finishes. Do not start a second local instance while
  the first is in use.
- **Clean up only what you own.** Close your tabs, stop the browser/daemon **you** started when the
  round ends, remove any temporary profile directory, and stop a dev server started for this round —
  except when the user still needs it for a manual `local_test` pass. Hand them the URL/path, say
  what stays running, and stop it only after they confirm the pass is done. `local_test` is not
  completion: keep the branch/server available and do not clean up as if the task finished. Never
  close the user's browser or tabs, and never kill shared infrastructure (Postgres, Redis,
  ClickHouse, Prefect) — `run-all.sh` owns service ports; the registry owns the shared ones.
- **No recordings** unless the user explicitly asks for a demo/video (`browser-use recordings` is
  opt-in by request, never by default).
- **AX tree before screenshots.** Screenshots only when layout or imagery is itself the question;
  they cost memory and tokens. Prefer `cdp("Accessibility.getFullAXTree")` filtered before printing.
- **Dev servers:** start a service once, reuse it for the whole testing round, then stop it — unless
  it is the server the user needs for their manual `local_test`, in which case leave exactly that
  one running and record it as owned-but-deferred until they confirm. Never start duplicates —
  run-all/health commands live in the service registry. One visual-testing scenario at a time
  locally; parallel = cloud (ask first).

## Headless setup (local, no visible window)

When the task requires headless, use a dedicated headless browser and point browser-use at its CDP
endpoint. Do not reach for the default daemon — it attaches to the user's Chrome.

```bash
# 1. Preflight first. Abort if this fails.
~/.agents/bin/res-ok || exit 1

# 2. Start a private headless instance (temp profile, no window).
CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)/headless-profile"
"$CHROME" --headless=new --remote-debugging-port=9222 \
  --user-data-dir="$PROFILE" about:blank &
CHROME_PID=$!

# 3. Drive it through CDP; every task in the round reuses this endpoint.
BU_CDP_URL=http://127.0.0.1:9222 browser-use <<'PY'
new_tab("http://localhost:3000/<route>")
wait_for_load()
print(page_info())
PY
```

If a check needs the user's real session, the browser cannot be headless — switch deliberately to
their Chrome and label the evidence "user-session background tab", not "headless". If login is
required and no session exists, stop and ask; never enter credentials.

## Procedure

1. **Navigate** with `new_tab` (first time) / `goto_url` (after), `wait_for_load()`.
2. **Structure first:** `cdp("Accessibility.getFullAXTree")["nodes"]` — filter for the roles/names
   the acceptance criteria demand (buttons, headings, tabs, empty states).
3. **Interact where behavior matters** — find the node, compute its box center, `click_at_xy`,
   then **verify the state changed** with a targeted `js(...)` or `page_info()` (URL, counter,
   toast text, data row count). A click without a post-check proves nothing.
4. **Data states:** exercise realistic data — valid entry, at least one realistic long/odd value,
   empty result, and the error path. Check loading UI actually resolves.
5. **Console errors:** capture `js` exceptions/errors near the interaction (page's own handlers or
   `window.onerror` hooks); any error that is *yours to own* (not the user's session quirks) is a
   finding, screenshot + note it.
6. **Evidence:** when layout matters, screenshot and keep the returned path. Reference it in the
   report ("verified `/brand-dashboard` renders 7 tabs — <path>").
7. **Viewport sanity:** check the main flow at a common desktop size; resize via the viewport skill
   when the task targets responsive behavior.
8. **Report claims like an evaluator, not a narrator:** what was expected, what was observed, file
   any mismatch as a must-fix with the reproduction click-path.

## Native desktop apps (frnd-desktop)

A browser screenshot of a SwiftUI app is **not** evidence. Browser-based proof is N/A for the
native app, and claiming it is a false pass. Verify the real app:

1. Build/launch the app from `desktop/` (Xcode or the committed build command) and keep the
   launched build for the whole check.
2. Capture the native window (for example `screencapture -l <window-id> <path>`), and keep the
   path as evidence. A screenshot of Chrome showing a web page is not a substitute.
3. Inspect the native accessibility hierarchy (`osascript` / System Events UI elements) for the
   controls and labels the acceptance criteria name; interact and re-read the state to prove the
   click changed it.
4. Read the app's own logs/console for errors near the interaction. An error in the app is a
   finding even if the screenshot looks right.
5. If a step can only be driven by a human (permission prompt, secure field, hardware interaction),
   record it as unverified and stop — do not imply it passed. Do not add UI-test infrastructure
   unless the user explicitly asked for tests.

## Division of labor

- **Implementation subagent:** visual-tests its own service UI before reporting done (same
  discipline; own tab on the shared instance, and native evidence for desktop).
- **Orchestrator:** independently re-tests the main paths of every UI claim — the same acceptance
  criteria, fresh eyes (fresh tab state where cheap). Acceptance = orchestrator's own observation,
  not the subagent's report.
- Subagents never start an extra browser/daemon of their own accord; if a second instance or a cloud
  session is truly needed, ask the user.

## Traps (hit in real sessions)

- **Calling a background tab of the user's Chrome "headless"** — it is not. It is their browser
  process; true headless means a dedicated `--headless=new`/cloud instance.
- **Spawning without the resource check** — a headless Chrome on a loaded machine can starve the
  session; check CPU/memory first and retry later, don't force it.
- **One browser per subagent** — duplicates memory, profiles, and tabs. Share one bounded instance;
  each task owns its tab.
- **Leaking tabs/processes** — close your own tabs; stop only the browser/daemon you started; never
  kill the user's Chrome or shared service ports.
- `scroll(...)` timing out on a *hidden* tab = the page needs visibility. Either `activate_tab()`
  once (visible — don't do it when the user forbids foreground changes) or test that path
  differently — do NOT hand-roll `Runtime.evaluate` scrollbar hacks.
- Omnibox popups are not work tabs; CDP target order ≠ tab-strip order.
- Login walls: stop and ask; SSO with Chrome already signed in is the only auto-pass.
- Remote daemons bill until stopped — closing the tab is not stopping the daemon.
- **Native desktop:** a browser check cannot prove a SwiftUI window; use native screenshots,
  accessibility inspection, and app logs, or report unverified.
