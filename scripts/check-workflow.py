#!/usr/bin/env python3
"""Assert the declarative workflow metadata agrees with the three-checkpoint design.

Nothing executes workflow/*.json, so a drifted edge, gate, checkpoint field,
schema default, or merge condition would otherwise fail silently. These are
direct assertions, not a workflow engine. Bad JSON or a failed assertion exits
nonzero. Run from the repository root: python3 scripts/check-workflow.py
"""

import hashlib, json, os, re, shutil, subprocess, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHASES = json.loads((ROOT / "workflow/phases.json").read_text())
GATES_RAW = (ROOT / "workflow/gates.json").read_text()
GATES = json.loads(GATES_RAW)
SCHEMA_RAW = (ROOT / "workflow/state-schema.json").read_text()
SCHEMA = json.loads(SCHEMA_RAW)
# Exact checkpoint and auto-advance metadata.
P = PHASES["phases"]
EXPECTED_CHECKPOINTS = {
    "brainstorming": "scope",
    "implementation": "implementation",
    "pr_submission": "delivery",
}
for name, phase in P.items():
    assert phase["checkpoint"] == EXPECTED_CHECKPOINTS.get(name), name
assert {name for name, phase in P.items() if phase["auto_advance"]} == {
    "prd_creation", "prd_splitting"
}
assert all(
    phase["auto_advance"] is False
    for name, phase in P.items()
    if name not in {"prd_creation", "prd_splitting"}
)

RULES = GATES["checkpoint_rules"]
AUTH_FIELDS = {
    "scope": "scope_approved",
    "implementation": "implementation_approved",
    "delivery": "delivery",
}
for phase, checkpoint in EXPECTED_CHECKPOINTS.items():
    assert RULES[checkpoint]["phase"] == phase
    assert RULES[checkpoint]["authorization_field"] == AUTH_FIELDS[checkpoint]
for option in ("local_test", "open_pr", "auto_merge"):
    assert option in RULES["delivery"]["satisfied_when"]
PREP_GATES = {
    "brainstorming_to_prd_creation",
    "prd_creation_to_prd_splitting",
    "prd_splitting_to_implementation",
}
G = GATES["gates"]
assert {gate for gate, value in G.items() if value.get("auto_after_scope")} == PREP_GATES
assert GATES["execution_mode_defaults"]["defaults"] == {
    "feature": "subagents",
    "improvement": "subagents",
    "bug": "main",
    "hotfix": "main",
}
assert GATES["execution_mode_defaults"]["state_field"] == "execution_mode"
# Next-edge, gate, and strategy references.
for source, phase in P.items():
    for target in phase["next"]:
        assert target in P, target
        gate = G[f"{source}_to_{target}"]
        assert (gate["from"], gate["to"]) == (source, target)
for gate_id, gate in G.items():
    assert gate_id == f"{gate['from']}_to_{gate['to']}", gate_id
    assert gate["to"] in P[gate["from"]]["next"], gate_id
    assert any(c["type"] == "phase_status_completed" for c in gate["conditions"]), gate_id
assert len({(g["from"], g["to"]) for g in G.values()}) == len(G)
for source, phase in P.items():
    if "next_strategy" in phase:
        assert set(phase["next_gates"]) == set(phase["next_strategy"]), source
        for key, target in phase["next_strategy"].items():
            gate = G[phase["next_gates"][key]]
            assert target in phase["next"] and (gate["from"], gate["to"]) == (source, target)

# Existing required fields preserved; new consent fields optional and safe.
FEATURE = SCHEMA["definitions"]["feature"]
REQUIRED = {
    "phase", "phase_status", "phase_entered", "type", "initial_request",
    "brainstorming", "prd_path", "branch", "service_prds", "pr_urls",
    "agent_state", "agent_state_reason",
}
assert set(FEATURE["required"]) == REQUIRED
assert FEATURE["additionalProperties"] is False
refs = set(re.findall(r'"\$ref":\s*"#/definitions/([^"]+)"', SCHEMA_RAW))
assert refs and refs <= set(SCHEMA["definitions"])
PROPS = FEATURE["properties"]
for field in ("scope_approved", "implementation_approved", "live_merge_approved"):
    assert PROPS[field]["type"] == "boolean" and PROPS[field]["default"] is False
    assert field not in REQUIRED
AUTOMATION = PROPS["automation"]
assert AUTOMATION["type"] == "object" and AUTOMATION["additionalProperties"] is False
assert set(AUTOMATION["properties"]) == {"brainstorming", "implementation"}
assert "required" not in AUTOMATION and "automation" not in REQUIRED
for flag in ("brainstorming", "implementation"):
    assert AUTOMATION["properties"][flag]["type"] == "boolean"
    assert AUTOMATION["properties"][flag]["default"] is False
MODE = PROPS["execution_mode"]
assert set(MODE["type"]) == {"string", "null"}
assert set(MODE["enum"]) == {"main", "subagents", None}
assert MODE["default"] is None and "execution_mode" not in REQUIRED
DELIVERY = PROPS["delivery"]
assert set(DELIVERY["type"]) == {"string", "null"}
assert set(DELIVERY["enum"]) == {"local_test", "open_pr", "auto_merge", None}
assert DELIVERY["default"] is None and "delivery" not in REQUIRED
VERIFICATION = PROPS["verification"]
assert set(VERIFICATION["type"]) == {"object", "null"}
assert VERIFICATION["additionalProperties"]["type"] == "string"
# Auto-merge gate and the pinned-head safety snippet.
MERGE_TYPES = {
    "full_thread_inventory", "required_checks", "expected_review",
    "verification_clean", "mergeable_protected", "head_sha_recheck",
    "live_estate_extra_consent",
}
assert MERGE_TYPES <= {
    c["type"] for c in GATES["auto_merge_policy"]["required_conditions"]
}
WATCH = GATES["auto_merge_policy"]["watch_budget"]
assert WATCH["default_minutes"] == 30 and WATCH["default_fix_rounds"] == 3
assert "track" in WATCH["persist"]
assert "separate human work" in GATES["auto_merge_policy"]["production"]
FEEDBACK_SKILL = (ROOT / "skills/pr-feedback/SKILL.md").read_text()
assert "--match-head-commit" in GATES_RAW and "--match-head-commit" in FEEDBACK_SKILL
assert "$PROOF_SHA" in FEEDBACK_SKILL and "head moved" in FEEDBACK_SKILL
assert "max_rounds" in FEEDBACK_SKILL and "rounds_used" in FEEDBACK_SKILL
assert "last_checked_sha" in FEEDBACK_SKILL and "expired" in FEEDBACK_SKILL
# No implementation→completion or local_test→completion shortcut.
assert "completion" not in P["implementation"]["next"]
assert "implementation_to_completion" not in G
IMPLEMENTATION_GATE = G["implementation_to_pr_submission"]
assert "implementation_authorized" in {c["type"] for c in IMPLEMENTATION_GATE["conditions"]}
FEEDBACK_GATE = G["pr_submission_to_pr_review"]
FEEDBACK_AUTH = next(c for c in FEEDBACK_GATE["conditions"] if c["type"] == "feedback_action_authorized")
assert "auto_merge" in FEEDBACK_AUTH["check"] and "track" in FEEDBACK_AUTH["check"]
COMPLETION_GATES = [gate for gate in G.values() if gate["to"] == "completion"]
assert not any(gate["from"] == "implementation" for gate in COMPLETION_GATES)
for gate in COMPLETION_GATES:
    delivery_guards = [c for c in gate["conditions"] if c["type"] == "delivery_allows_pr"]
    assert delivery_guards, gate["from"]
    assert "local_test" not in delivery_guards[0]["check"]
    assert "open_pr" in delivery_guards[0]["check"]
    assert "auto_merge" in delivery_guards[0]["check"]
stack, seen = ["implementation"], set()
while stack:
    current = stack.pop()
    assert current != "completion", "implementation reaches completion without delivery"
    if current != "pr_submission" and current not in seen:
        seen.add(current)
        stack.extend(P[current]["next"])
# The catalog is editable data, not a provider/model pin.
CATALOG = json.loads((ROOT / "workflow/model-catalog.json").read_text())
assert set(CATALOG) == {"roles"}
assert set(CATALOG["roles"]) == {"main", "subagents"}
for role in CATALOG["roles"].values():
    assert set(role) == {"strongly_recommended", "alternatives"}
    pairs = [role["strongly_recommended"], *role["alternatives"]]
    assert role["alternatives"] and len({p["model"] for p in pairs}) == len(pairs)
    for pair in pairs:
        assert set(pair) == {"model", "effort"}
        assert isinstance(pair["model"], str) and pair["model"].strip()
        assert "/" not in pair["model"], "use labels, not provider IDs"
        assert pair["effort"] in {"low", "medium", "high", "xhigh", "max"}
MANIFEST = json.loads((ROOT / "manifest.json").read_text())
assert MANIFEST["files"]["workflow/model-catalog.json"]["install_to"] == \
    ".agentic-workflows/workflow/model-catalog.json"

# Real generator regression: distributed VERSION beats cached .version.
with tempfile.TemporaryDirectory() as temp_dir:
    workspace = Path(temp_dir)
    cache = workspace / ".agentic-workflows"
    cache.mkdir()
    shutil.copy2(ROOT / "agents/AGENTS.md.template", cache / "AGENTS.md.template")
    shutil.copytree(ROOT / "agents/fragments", cache / "fragments")
    (cache / "scripts").mkdir()
    shutil.copy2(ROOT / "scripts/generate-agents.sh", cache / "scripts/generate-agents.sh")
    (cache / "VERSION").write_text("4.1.0\n")
    (cache / ".version").write_text("4.0.0\n")

    def regenerate():
        subprocess.run(
            ["bash", str(cache / "scripts/generate-agents.sh")],
            cwd=workspace, check=True, capture_output=True, text=True,
        )
        return (workspace / "AGENTS.md").read_text()

    # Upgrade: distributed VERSION must override the stale cached .version.
    assert "> **Version:** 4.1.0" in regenerate()
    # Fresh: no cached .version, still the distributed VERSION.
    (cache / ".version").unlink()
    (workspace / "AGENTS.md").unlink()
    assert "> **Version:** 4.1.0" in regenerate()

# Exercise the real updater without network or provider calls.
with tempfile.TemporaryDirectory() as temp_dir:
    fixture = Path(temp_dir)
    remote, bin_dir = fixture / "remote", fixture / "bin"
    remote.mkdir()
    bin_dir.mkdir()
    manifest = json.loads(json.dumps(MANIFEST))
    for source, entry in manifest["files"].items():
        target = remote / source
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / source, target)
        entry["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    (remote / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    curl = bin_dir / "curl"
    curl.write_text('''#!/usr/bin/env bash
set -eu
[[ "${OFFLINE:-0}" != 1 ]] || exit 7
for url in "$@"; do :; done
path=${url#https://raw.githubusercontent.com/alva-intelligence/agentic-workflows/main/}
[[ "$path" != "$url" && "$path" != *..* ]] || exit 22
/bin/cat "$FAKE_REMOTE/$path"
''')
    curl.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_REMOTE": str(remote)}
    env.pop("AW_BRANCH", None)
    env.pop("OFFLINE", None)
    notice = "Model catalog review pending (advisory)"
    for mode in ("fresh", "cached"):
        workspace = fixture / mode
        workspace.mkdir()
        (workspace / "hocuspocus").mkdir()
        preserved = {
            ".workflow-state.json": '{"active_feature":null,"features":{}}\n',
            ".onboard-state.json": '{"status":"completed","optional_services":{"desktop":"skipped"}}\n',
            ".claude/settings.local.json": '{"permissions":{"deny":["Bash(gh pr merge:*)"]}}\n',
        }
        for name, content in preserved.items():
            path = workspace / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        cache = workspace / ".agentic-workflows"
        if mode == "cached":
            (cache / "scripts").mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/update-check.sh", cache / "scripts/update-check.sh")
            (cache / ".version").write_text("0.0.0\n")
            (workspace / "AGENTS.md").write_text("Old instructions\n")

        def update(*args, offline=False):
            script = cache / "scripts/update-check.sh" if mode == "cached" else ROOT / "scripts/update-check.sh"
            result = subprocess.run(["bash", str(script), *args], cwd=workspace,
                                    env={**env, "OFFLINE": str(int(offline))},
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
            return result.stdout

        first = update("--bootstrap") if mode == "fresh" else update()
        assert notice in first and "This is a fresh workspace" not in first
        assert "Read regenerated AGENTS.md" in first
        catalog = cache / "workflow/model-catalog.json"
        marker = cache / ".model-catalog-reviewed"
        assert catalog.read_bytes() == (ROOT / "workflow/model-catalog.json").read_bytes()
        assert not marker.exists(), "updater must not acknowledge a review"
        assert notice in update(), "an interrupted review stays pending"
        marker.write_text(hashlib.sha256(catalog.read_bytes()).hexdigest() + "\n")
        assert notice not in update()
        assert notice not in update(offline=True)
        catalog.write_bytes(catalog.read_bytes() + b"\n")
        reviewed = marker.read_bytes()
        assert notice in update() and notice in update(offline=True)
        assert marker.read_bytes() == reviewed, "stale reviews must not be auto-acknowledged"
        catalog.unlink()
        assert notice not in update(offline=True)
        for name, content in preserved.items():
            assert (workspace / name).read_text() == content, name

# Node is the service's existing runtime; use its native env parser, never source .env.
RUN_ALL = (ROOT / "skills/onboard/references/run-all-template.sh").read_text()
owned = set(re.search(r"^OWNED_PORTS=\(([^)]*)\)", RUN_ALL, re.M)[1].split())
shared = set(re.search(r"^SHARED_PORTS=\(([^)]*)\)", RUN_ALL, re.M)[1].split())
assert not owned & shared
assert {"5432", "6379", "8123", "4200"} <= shared
LAUNCH = json.loads((ROOT / "skills/onboard/references/launch.json").read_text())
collab = next(c for c in LAUNCH["configurations"] if c["name"] == "hocuspocus")
assert collab["cwd"] == "hocuspocus" and collab["runtimeArgs"] == ["run", "dev"]
assert collab["port"] == 1234
with tempfile.TemporaryDirectory() as temp_dir:
    workspace = Path(temp_dir)
    script = workspace / "run-all.sh"
    script.write_text(RUN_ALL)
    bin_dir = workspace / "bin"
    bin_dir.mkdir()
    for name, body in {"curl": 'printf "200"', "pg_isready": 'exit 0', "redis-cli": 'printf "PONG"',
                       "php": 'exit 0', "bun": 'exit 0', "lsof": 'exit 1'}.items():
        stub = bin_dir / name
        stub.write_text("#!/bin/sh\n" + body + "\n")
        stub.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    env.pop("PORT", None)

    def status():
        return subprocess.run(["bash", str(script), "--status"], cwd=workspace, env=env,
                              capture_output=True, text=True, check=True).stdout

    assert "hocuspocus" not in status().lower(), "absent optional service should be skipped"
    (workspace / "hocuspocus").mkdir()
    missing = subprocess.run(["bash", str(script), "--check"], cwd=workspace, env=env,
                             capture_output=True, text=True, check=True).stdout
    assert "Skipping Hocuspocus" in missing and "collaboration unavailable" in missing
    for value, port in [("", 1234), ('PORT="1235" # custom\n', 1235),
                        ("export PORT='1236'\n", 1236)]:
        (workspace / "hocuspocus/.env").write_text(value)
        assert f"Hocuspocus ({port}) — HTTP 200" in status()
    for value in ("", "0", "65536", "invalid", *shared, "9191", "$(touch compromised)"):
        (workspace / "hocuspocus/.env").write_text(f"PORT={value}\n")
        assert "valid, non-reserved PORT" in status(), value
    assert not (workspace / "compromised").exists()
    (workspace / "hocuspocus/.env").write_text("PORT=1235\n")
    env["PORT"] = "1237"
    assert "Hocuspocus (1237) — HTTP 200" in status(), "ambient overrides match service behavior"
    env.pop("PORT")
    for name, body in {"npm": 'printf "%s" "$PORT" > resolved.port\nsleep 60 &\necho $! > child.pid\nwait',
                       "mailhog": 'exit 0', "docker": 'exit 0',
                       "lsof": 'case "$*" in *":1235") printf "%s\\n" "${UNTRACKED_PID:-}";; *) exit 1;; esac',
                       "php": 'exit 0', "bun": 'exit 0'}.items():
        stub = bin_dir / name
        stub.write_text("#!/bin/sh\n" + body + "\n")
        stub.chmod(0o755)
    with subprocess.Popen(["sleep", "60"], start_new_session=True) as unrelated:
        env["UNTRACKED_PID"] = str(unrelated.pid)
        try:
            for action in ("--kill-ports", "--stop"):
                subprocess.run(["bash", str(script), action], cwd=workspace, env=env,
                               capture_output=True, text=True, check=True)
                assert unrelated.poll() is None, "port alone is not ownership"
            (workspace / ".pids/hocuspocus.pid").write_text(str(unrelated.pid))
            (workspace / ".pids/hocuspocus.started").write_text("stale timestamp\n")
            subprocess.run(["bash", str(script), "--stop"], cwd=workspace, env=env,
                           capture_output=True, text=True, check=True)
            assert unrelated.poll() is None, "stale PID must not kill an unrelated group"
            skipped = subprocess.run(["bash", str(script)], cwd=workspace, env=env,
                                     capture_output=True, text=True, check=True).stdout
            assert "Skipping Hocuspocus" in skipped and not (workspace / ".pids/hocuspocus.pid").exists()
        finally:
            if unrelated.poll() is None:
                unrelated.terminate()
    env.pop("UNTRACKED_PID")
    (workspace / "hocuspocus/.env").write_text("PORT=invalid\n")
    invalid = subprocess.run(["bash", str(script)], cwd=workspace, env=env,
                             capture_output=True, text=True, check=True).stdout
    assert "Skipping Hocuspocus" in invalid and not (workspace / ".pids/hocuspocus.pid").exists()
    (workspace / "hocuspocus/.env").write_text("PORT=1235\n")
    subprocess.run(["bash", str(script)], cwd=workspace, env=env,
                   capture_output=True, text=True, check=True)
    pid = int((workspace / ".pids/hocuspocus.pid").read_text())
    child = None
    try:
        for _ in range(20):
            if (workspace / "hocuspocus/child.pid").exists():
                break
            time.sleep(0.05)
        child = int((workspace / "hocuspocus/child.pid").read_text())
        assert (workspace / "hocuspocus/resolved.port").read_text() == "1235"
        assert "hocuspocus — running" in status()
    finally:
        subprocess.run(["bash", str(script), "--stop"], cwd=workspace, env=env,
                       capture_output=True, text=True, check=True)
        for _ in range(20):
            states = subprocess.run(["ps", "-p", f"{pid},{child}" if child else str(pid), "-o", "stat="],
                                    capture_output=True, text=True).stdout.splitlines()
            if all(state.strip().startswith("Z") for state in states):
                break
            time.sleep(0.05)
        else:
            os.killpg(pid, 15)
            raise AssertionError("launcher did not stop its task-owned process group")

print("workflow metadata OK — checkpoints, catalog, updater preservation, native env/port regressions")
