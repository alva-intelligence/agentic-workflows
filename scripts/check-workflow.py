#!/usr/bin/env python3
"""Assert the declarative workflow metadata agrees with the three-checkpoint design.

Nothing executes workflow/*.json, so a drifted edge, gate, checkpoint field,
schema default, or merge condition would otherwise fail silently. These are
direct assertions, not a workflow engine. Bad JSON or a failed assertion exits
nonzero. Run from the repository root: python3 scripts/check-workflow.py
"""

import json, re, shutil, subprocess, tempfile
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

print("workflow metadata OK — 3 checkpoints, refs, schema defaults, merge gates, generator version")
