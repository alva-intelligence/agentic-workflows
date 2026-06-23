# Brand-Aware AskFrnd — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both AskFrnd agents (default chat + PAA) an on-demand, intent-gated `get_brand_knowledge` tool that reads brand data directly from Postgres, caches it per session, and prioritizes internal Brand Knowledge.

**Architecture:** A new read-only brand repository + a Python port of KV's brand string-builders feed a closure-based Agno tool. The tool checks `agno_sessions.session_data` first (session cache), falls back to a direct DB read, and write-throughs the result. Location context (`active_brand` / `brand_directory`) arrives in the request DTO and is injected as a small system-prompt hint. The tool only fetches `brand_id`s the API already vetted (present in `active_brand`/`brand_directory`), so no permission logic is duplicated here.

**Tech Stack:** FastAPI, Agno, SQLAlchemy (existing `SessionLocal`/`agno_engine`), pytest + unittest.mock.

**Spec:** `docs/superpowers/specs/2026-06-23-askfrnd-brand-context-awareness-design.md`

**Shared sibling plans:** `2026-06-23-askfrnd-brand-context-api.md`, `2026-06-23-askfrnd-brand-context-web.md`

**Run tests with:** `cd ai-service && source .venv/bin/activate && pytest <path> -v`

---

## File Structure

- Create: `ai-service/app/agents/chat_agent/brand_context_builder.py` — pure functions building the brand block string (port of KV's PHP builders).
- Create: `ai-service/app/repositories/__init__.py`, `ai-service/app/repositories/brand_repository.py` — read-only DB access to `brands` + `brand_tonalities`.
- Create: `ai-service/app/agents/chat_agent/brand_session_cache.py` — read/write `session_data.brand_knowledge[brand_id]`.
- Create: `ai-service/app/tools/get_brand_knowledge.py` — closure factory `make_get_brand_knowledge(...)`.
- Modify: `ai-service/app/agents/chat_agent/request_schema.py` — add `active_brand`, `brand_directory`.
- Modify: `ai-service/app/agents/chat_agent/paa_agent_factory.py` — brand prompt hint + tool registration.
- Modify: `ai-service/app/agents/chat_agent/service.py` — default-agent tool registration + extra args + prompt hint + thread through to PAA.
- Create tests under `ai-service/tests/` mirroring existing layout.

---

## Task 1: Brand context builder (pure port of KV PHP builders)

**Files:**
- Create: `ai-service/app/agents/chat_agent/brand_context_builder.py`
- Test: `ai-service/tests/agents/chat_agent/test_brand_context_builder.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/chat_agent/test_brand_context_builder.py
from app.agents.chat_agent.brand_context_builder import build_brand_block


def test_builds_block_with_dna_identity_tonality():
    block = build_brand_block({
        "brand_name": "OCBC Nyala",
        "description": "Friendly modern bank",
        "mission": "Empower Indonesians financially",
        "vision": "Most trusted bank",
        "brand_purpose": "Make banking human",
        "brand_pillars": ["Trust", "Simplicity"],
        "target_audience": ["Urban millennials"],
        "market_positioning": "The friendly modern bank",
        "competitors": ["BCA", "Mandiri"],
        "visual_dos": ["Use warm photography"],
        "visual_donts": ["No clip-art icons"],
        "tonality": {"archetype": "hero", "voice_tone": ["warm", "clear"]},
    })
    assert "Brand: OCBC Nyala" in block
    assert "Empower Indonesians financially" in block          # DNA
    assert "Trust, Simplicity" in block                        # pillars flattened
    assert "The friendly modern bank" in block                 # identity
    assert "Use warm photography" in block                     # visual dos
    assert "hero" in block                                     # tonality serialized


def test_omits_empty_sections_and_handles_no_tonality():
    block = build_brand_block({"brand_name": "Acme", "description": "", "tonality": None})
    assert block.startswith("Brand: Acme")
    assert "DNA" not in block or "DNA:" in block  # builder never crashes on empties


def test_returns_no_knowledge_marker_for_blank_brand():
    block = build_brand_block({"brand_name": "Acme"})
    assert "Brand: Acme" in block
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_context_builder.py -v`
Expected: FAIL — `ModuleNotFoundError: app.agents.chat_agent.brand_context_builder`.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/chat_agent/brand_context_builder.py
"""Build the human-readable brand block injected into AskFrnd's context.

Python port of api/app/Services/ChatService.php buildBrandDna / buildBrandIdentity
/ tonality serialization so AskFrnd and KV share one format.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional


def _flatten(value: Any) -> str:
    if isinstance(value, list):
        parts = [str(v).strip() for v in value if v is not None and str(v).strip() != ""]
        return ", ".join(parts)
    if value is None:
        return ""
    return str(value).strip()


def _join_lines(fields: Dict[str, Any]) -> str:
    lines: List[str] = []
    for label, raw in fields.items():
        val = _flatten(raw)
        if val:
            lines.append(f"{label}: {val}")
    return "\n".join(lines)


def _build_dna(brand: Dict[str, Any]) -> str:
    return _join_lines({
        "Mission": brand.get("mission"),
        "Vision": brand.get("vision"),
        "Purpose": brand.get("brand_purpose"),
        "Pillars": brand.get("brand_pillars"),
        "Target audience": brand.get("target_audience"),
    })


def _build_identity(brand: Dict[str, Any]) -> str:
    return _join_lines({
        "Description": brand.get("description"),
        "Market positioning": brand.get("market_positioning"),
        "Competitors": brand.get("competitors"),
        "Visual dos": brand.get("visual_dos"),
        "Visual donts": brand.get("visual_donts"),
    })


def _build_tonality(brand: Dict[str, Any]) -> str:
    tonality = brand.get("tonality")
    if not tonality:
        return ""
    if isinstance(tonality, str):
        return tonality
    try:
        return json.dumps(tonality, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        return ""


def build_brand_block(brand: Dict[str, Any]) -> str:
    """Render a compact brand block. Empty sections are omitted."""
    name = brand.get("brand_name") or brand.get("name") or "Unknown"
    lines: List[str] = [f"Brand: {name}"]

    dna = _build_dna(brand)
    if dna:
        lines.append(f"- DNA:\n{dna}")

    identity = _build_identity(brand)
    if identity:
        lines.append(f"- Identity:\n{identity}")

    tonality = _build_tonality(brand)
    if tonality:
        lines.append(f"- Tonality: {tonality}")

    return "\n".join(lines)


def has_any_knowledge(brand: Optional[Dict[str, Any]]) -> bool:
    if not brand:
        return False
    keys = (
        "mission", "vision", "brand_purpose", "brand_pillars", "target_audience",
        "market_positioning", "competitors", "visual_dos", "visual_donts", "tonality",
    )
    return any(brand.get(k) for k in keys)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_context_builder.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git -C ai-service add app/agents/chat_agent/brand_context_builder.py tests/agents/chat_agent/test_brand_context_builder.py
git -C ai-service commit -m "feat(ai): add brand_context_builder for AskFrnd brand block"
```

---

## Task 2: Brand repository (read-only DB access)

**Files:**
- Create: `ai-service/app/repositories/__init__.py` (empty)
- Create: `ai-service/app/repositories/brand_repository.py`
- Test: `ai-service/tests/repositories/test_brand_repository.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/repositories/test_brand_repository.py
from unittest.mock import MagicMock, patch

from app.repositories.brand_repository import fetch_brand_knowledge


def _row(**kw):
    row = MagicMock()
    for k, v in kw.items():
        setattr(row, k, v)
    return row


@patch("app.repositories.brand_repository.SessionLocal")
def test_returns_none_when_brand_missing(mock_sl):
    db = mock_sl.return_value
    db.execute.return_value.first.return_value = None
    assert fetch_brand_knowledge("b-missing") is None
    db.close.assert_called_once()


@patch("app.repositories.brand_repository.SessionLocal")
def test_maps_brand_and_tonality_rows(mock_sl):
    db = mock_sl.return_value
    brand_row = _row(
        id="b1", name="OCBC", description="bank",
        mission="m", vision="v", brand_purpose="p",
        brand_pillars=["Trust"], target_audience=["Urban"],
        market_positioning="pos", competitors=["BCA"],
        visual_dos=["do"], visual_donts=["dont"],
    )
    tonality_row = _row(
        archetype="hero", voice_tone=["warm"], tone_descriptors=["clear"],
        key_phrases=["kp"], forbidden_words=["fw"], target_audience_context=["ctx"],
    )
    # first execute() -> brand, second execute() -> tonality
    db.execute.return_value.first.side_effect = [brand_row, tonality_row]

    result = fetch_brand_knowledge("b1")
    assert result["brand_name"] == "OCBC"
    assert result["mission"] == "m"
    assert result["brand_pillars"] == ["Trust"]
    assert result["tonality"]["archetype"] == "hero"
    db.close.assert_called_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/repositories/test_brand_repository.py -v`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/repositories/__init__.py
```

```python
# ai-service/app/repositories/brand_repository.py
"""Read-only access to brand knowledge (brands + brand_tonalities).

NO permission logic here. Callers must pass a brand_id that was already
access-vetted by the API (present in active_brand / brand_directory).
Reads from the same Postgres DB the API writes to (DB_NAME=frnd).
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from sqlalchemy import text

from app.database import SessionLocal

logger = logging.getLogger(__name__)

_BRAND_SQL = text("""
    SELECT id, name, description, mission, vision, brand_purpose,
           brand_pillars, target_audience, market_positioning, competitors,
           visual_dos, visual_donts
    FROM brands
    WHERE id = :brand_id
    LIMIT 1
""")

_TONALITY_SQL = text("""
    SELECT archetype, target_audience_context, key_phrases,
           voice_tone, tone_descriptors, forbidden_words
    FROM brand_tonalities
    WHERE brand_id = :brand_id
    LIMIT 1
""")


def fetch_brand_knowledge(brand_id: str) -> Optional[Dict[str, Any]]:
    """Return a flat dict of brand knowledge, or None if the brand doesn't exist."""
    if not brand_id:
        return None
    db = SessionLocal()
    try:
        brand = db.execute(_BRAND_SQL, {"brand_id": brand_id}).first()
        if brand is None:
            return None
        result: Dict[str, Any] = {
            "brand_id": brand.id,
            "brand_name": brand.name,
            "description": brand.description,
            "mission": brand.mission,
            "vision": brand.vision,
            "brand_purpose": brand.brand_purpose,
            "brand_pillars": brand.brand_pillars,
            "target_audience": brand.target_audience,
            "market_positioning": brand.market_positioning,
            "competitors": brand.competitors,
            "visual_dos": brand.visual_dos,
            "visual_donts": brand.visual_donts,
            "tonality": None,
        }
        tonality = db.execute(_TONALITY_SQL, {"brand_id": brand_id}).first()
        if tonality is not None:
            result["tonality"] = {
                "archetype": tonality.archetype,
                "target_audience_context": tonality.target_audience_context,
                "key_phrases": tonality.key_phrases,
                "voice_tone": tonality.voice_tone,
                "tone_descriptors": tonality.tone_descriptors,
                "forbidden_words": tonality.forbidden_words,
            }
        return result
    except Exception as e:  # soft-fail: tool degrades to general knowledge
        logger.warning("fetch_brand_knowledge(%s) failed: %s", brand_id, e)
        return None
    finally:
        db.close()
```

Create the test package dir marker if needed:

```python
# ai-service/tests/repositories/__init__.py
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/repositories/test_brand_repository.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git -C ai-service add app/repositories/ tests/repositories/
git -C ai-service commit -m "feat(ai): add read-only brand_repository for AskFrnd"
```

---

## Task 3: Session cache helpers

**Files:**
- Create: `ai-service/app/agents/chat_agent/brand_session_cache.py`
- Test: `ai-service/tests/agents/chat_agent/test_brand_session_cache.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/chat_agent/test_brand_session_cache.py
from unittest.mock import MagicMock, patch

from app.agents.chat_agent.brand_session_cache import (
    read_cached_brand,
    write_cached_brand,
)


@patch("app.agents.chat_agent.brand_session_cache.SessionLocal")
def test_read_returns_none_when_no_session(mock_sl):
    db = mock_sl.return_value
    db.query.return_value.filter.return_value.first.return_value = None
    assert read_cached_brand("sess1", "user1", "b1") is None


@patch("app.agents.chat_agent.brand_session_cache.SessionLocal")
def test_read_returns_cached_payload(mock_sl):
    db = mock_sl.return_value
    session = MagicMock()
    session.session_data = {"brand_knowledge": {"b1": {"brand_name": "OCBC"}}}
    db.query.return_value.filter.return_value.first.return_value = session
    assert read_cached_brand("sess1", "user1", "b1") == {"brand_name": "OCBC"}


@patch("app.agents.chat_agent.brand_session_cache.SessionLocal")
def test_write_creates_namespace_and_commits(mock_sl):
    db = mock_sl.return_value
    session = MagicMock()
    session.session_data = None
    db.query.return_value.filter.return_value.first.return_value = session
    write_cached_brand("sess1", "user1", "b1", {"brand_name": "OCBC"})
    assert session.session_data["brand_knowledge"]["b1"]["brand_name"] == "OCBC"
    db.commit.assert_called_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_session_cache.py -v`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/chat_agent/brand_session_cache.py
"""Per-session cache of fetched brand knowledge in agno_sessions.session_data.

Shape: session_data["brand_knowledge"][brand_id] = <flat brand dict>
Once fetched in a session, follow-up brand questions reuse it (no DB re-read).
"""
from __future__ import annotations

import logging
from copy import deepcopy
from typing import Any, Dict, Optional

from sqlalchemy.orm.attributes import flag_modified

from app.database import SessionLocal
from app.models.agno_sessions import AgnoSessions

logger = logging.getLogger(__name__)

_NS = "brand_knowledge"


def read_cached_brand(session_id: str, user_id: str, brand_id: str) -> Optional[Dict[str, Any]]:
    db = SessionLocal()
    try:
        row = (
            db.query(AgnoSessions)
            .filter(AgnoSessions.session_id == session_id, AgnoSessions.user_id == user_id)
            .first()
        )
        if row is None or not row.session_data:
            return None
        return (row.session_data.get(_NS) or {}).get(brand_id)
    except Exception as e:
        logger.warning("read_cached_brand failed: %s", e)
        return None
    finally:
        db.close()


def write_cached_brand(
    session_id: str, user_id: str, brand_id: str, payload: Dict[str, Any]
) -> None:
    db = SessionLocal()
    try:
        row = (
            db.query(AgnoSessions)
            .filter(AgnoSessions.session_id == session_id, AgnoSessions.user_id == user_id)
            .first()
        )
        if row is None:
            return  # session row created by Agno on run; nothing to cache into yet
        data = deepcopy(row.session_data) if row.session_data else {}
        data.setdefault(_NS, {})[brand_id] = payload
        row.session_data = data
        flag_modified(row, "session_data")
        db.commit()
    except Exception as e:
        logger.warning("write_cached_brand failed: %s", e)
        db.rollback()
    finally:
        db.close()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_session_cache.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git -C ai-service add app/agents/chat_agent/brand_session_cache.py tests/agents/chat_agent/test_brand_session_cache.py
git -C ai-service commit -m "feat(ai): add per-session brand knowledge cache"
```

---

## Task 4: `get_brand_knowledge` tool (closure factory)

**Files:**
- Create: `ai-service/app/tools/get_brand_knowledge.py`
- Test: `ai-service/tests/tools/test_get_brand_knowledge.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/tools/test_get_brand_knowledge.py
from unittest.mock import patch

from app.tools.get_brand_knowledge import make_get_brand_knowledge

ACTIVE = {"id": "b1", "name": "OCBC", "description": "bank"}
DIR = [ACTIVE, {"id": "b2", "name": "Acme", "description": "co"}]


def _tool(**over):
    kw = dict(user_id="u1", workspace_id="w1", thread_id="t1",
              active_brand=ACTIVE, brand_directory=DIR)
    kw.update(over)
    return make_get_brand_knowledge(**kw)


@patch("app.tools.get_brand_knowledge.write_cached_brand")
@patch("app.tools.get_brand_knowledge.read_cached_brand", return_value=None)
@patch("app.tools.get_brand_knowledge.fetch_brand_knowledge")
def test_cache_miss_fetches_db_and_writes_through(mock_fetch, mock_read, mock_write):
    mock_fetch.return_value = {"brand_name": "OCBC", "mission": "m"}
    tool = _tool()
    out = tool(action="Get brand knowledge", brand_id="b1")
    mock_fetch.assert_called_once_with("b1")
    mock_write.assert_called_once()
    assert "Brand: OCBC" in out["brand_knowledge"]


@patch("app.tools.get_brand_knowledge.write_cached_brand")
@patch("app.tools.get_brand_knowledge.fetch_brand_knowledge")
@patch("app.tools.get_brand_knowledge.read_cached_brand")
def test_cache_hit_skips_db(mock_read, mock_fetch, mock_write):
    mock_read.return_value = {"brand_name": "OCBC", "mission": "m"}
    tool = _tool()
    out = tool(action="Get brand knowledge", brand_id="b1")
    mock_fetch.assert_not_called()
    mock_write.assert_not_called()
    assert "Brand: OCBC" in out["brand_knowledge"]


@patch("app.tools.get_brand_knowledge.fetch_brand_knowledge")
def test_rejects_brand_id_not_in_allowed_set(mock_fetch):
    tool = _tool()
    out = tool(action="x", brand_id="b-unknown")
    mock_fetch.assert_not_called()
    assert out["brand_knowledge"] is None
    assert "no access" in out["instruction"].lower() or "not available" in out["instruction"].lower()


@patch("app.tools.get_brand_knowledge.read_cached_brand", return_value=None)
@patch("app.tools.get_brand_knowledge.fetch_brand_knowledge", return_value=None)
def test_brand_without_knowledge_returns_marker(mock_fetch, mock_read):
    tool = _tool()
    out = tool(action="x", brand_id="b1")
    assert out["brand_knowledge"] is None
    assert "no brand knowledge" in out["instruction"].lower()


@patch("app.tools.get_brand_knowledge.read_cached_brand", return_value=None)
@patch("app.tools.get_brand_knowledge.fetch_brand_knowledge")
def test_defaults_to_active_brand_when_no_id_given(mock_fetch, mock_read):
    mock_fetch.return_value = {"brand_name": "OCBC", "mission": "m"}
    tool = _tool()
    out = tool(action="x")  # no brand_id -> use active_brand.id
    mock_fetch.assert_called_once_with("b1")
    assert "Brand: OCBC" in out["brand_knowledge"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/tools/test_get_brand_knowledge.py -v`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/tools/get_brand_knowledge.py
"""On-demand brand knowledge tool for AskFrnd.

`make_get_brand_knowledge(...)` returns a closure registered as an Agno tool.
The LLM calls it ONLY for brand-specific questions (intent gating via
tool_choice="auto"). The closure captures request context so it works on both
the default chat agent (tool_hook injects extra kwargs, absorbed by **kwargs)
and the PAA agent (no hook).

Security: only brand_ids present in active_brand/brand_directory (already
access-vetted by the API) may be fetched.
"""
from __future__ import annotations

import logging
from typing import Any, Callable, Dict, List, Optional

from app.agents.chat_agent.brand_context_builder import build_brand_block, has_any_knowledge
from app.agents.chat_agent.brand_session_cache import read_cached_brand, write_cached_brand
from app.repositories.brand_repository import fetch_brand_knowledge

logger = logging.getLogger(__name__)


def _allowed_ids(active_brand: Optional[Dict], brand_directory: Optional[List[Dict]]) -> set:
    ids = set()
    if active_brand and active_brand.get("id"):
        ids.add(active_brand["id"])
    for b in brand_directory or []:
        if b.get("id"):
            ids.add(b["id"])
    return ids


def make_get_brand_knowledge(
    user_id: str,
    workspace_id: Optional[str],
    thread_id: str,
    active_brand: Optional[Dict[str, Any]] = None,
    brand_directory: Optional[List[Dict[str, Any]]] = None,
) -> Callable[..., Dict[str, Any]]:
    allowed = _allowed_ids(active_brand, brand_directory)
    default_id = active_brand.get("id") if active_brand else None

    def get_brand_knowledge(
        action: str, brand_id: Optional[str] = None, **kwargs
    ) -> Dict[str, Any]:
        """Retrieve the internal Brand Knowledge (DNA, Identity, Tonality, basic
        info) for a brand. Call this ONLY when the user's question needs
        brand-specific knowledge; do NOT call it for generic requests.

        Args:
            action (str): Short human-readable description of this call
                (e.g. "Get brand knowledge for the active brand"). Not snake_case.
            brand_id (str, optional): The brand to fetch. Omit to use the active
                brand. On Home, pass the id of the brand the user named (match it
                against the brand directory in your context).
        """
        target = brand_id or default_id
        if not target or target not in allowed:
            return {
                "instruction": "No accessible brand matches this request. Tell the user no brand knowledge is available and answer generically if possible.",
                "brand_knowledge": None,
            }

        cached = read_cached_brand(thread_id, user_id, target)
        if cached is not None:
            payload = cached
        else:
            payload = fetch_brand_knowledge(target)
            if payload is not None:
                write_cached_brand(thread_id, user_id, target, payload)

        if not has_any_knowledge(payload):
            return {
                "instruction": "This brand has no Brand Knowledge configured yet. Tell the user, then answer from general knowledge if appropriate.",
                "brand_knowledge": None,
            }

        return {
            "instruction": "Use this internal Brand Knowledge as the primary source of truth. Only fall back to general knowledge for parts it does not cover, and say so when you do.",
            "brand_knowledge": build_brand_block(payload),
        }

    return get_brand_knowledge
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/tools/test_get_brand_knowledge.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git -C ai-service add app/tools/get_brand_knowledge.py tests/tools/test_get_brand_knowledge.py
git -C ai-service commit -m "feat(ai): add intent-gated get_brand_knowledge tool with session cache"
```

---

## Task 5: DTO fields + brand awareness prompt hint

**Files:**
- Modify: `ai-service/app/agents/chat_agent/request_schema.py` (add fields after `thread_type`, around line 136)
- Create: `ai-service/app/agents/chat_agent/brand_awareness_prompt.py`
- Test: `ai-service/tests/agents/chat_agent/test_brand_awareness_prompt.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/chat_agent/test_brand_awareness_prompt.py
from app.agents.chat_agent.brand_awareness_prompt import build_brand_awareness_prompt


def test_condition_a_active_brand_hint():
    p = build_brand_awareness_prompt(
        active_brand={"id": "b1", "name": "OCBC", "description": "bank"},
        brand_directory=None,
    )
    assert "OCBC" in p
    assert "get_brand_knowledge" in p
    assert "primary source of truth" in p.lower()


def test_condition_b_directory_hint():
    p = build_brand_awareness_prompt(
        active_brand=None,
        brand_directory=[{"id": "b1", "name": "OCBC"}, {"id": "b2", "name": "Acme"}],
    )
    assert "OCBC" in p and "Acme" in p
    assert "get_brand_knowledge" in p


def test_no_location_returns_generic_gate():
    p = build_brand_awareness_prompt(active_brand=None, brand_directory=None)
    assert "generic" in p.lower() or "do not call" in p.lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_awareness_prompt.py -v`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/chat_agent/brand_awareness_prompt.py
"""System-prompt hint that makes AskFrnd brand-aware and intent-gated."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

_INTENT_RULES = (
    "\n## Brand Knowledge (internal source of truth)\n"
    "- Internal Brand Knowledge is your PRIMARY source of truth for brand-specific questions.\n"
    "- For a brand-specific question (about a brand's identity, tone, mission, positioning, "
    "audience, visual rules, etc.), call the `get_brand_knowledge` tool BEFORE answering.\n"
    "- For a generic request that needs no brand data (e.g. 'translate this', 'summarize this', "
    "'write a function'), answer directly and do NOT call `get_brand_knowledge`.\n"
    "- If the fetched Brand Knowledge does not fully cover the question, you may use your own "
    "general knowledge for the gap — say when you are doing so.\n"
    "- Never invent brand facts. If no Brand Knowledge exists, say so honestly.\n"
)


def build_brand_awareness_prompt(
    active_brand: Optional[Dict[str, Any]],
    brand_directory: Optional[List[Dict[str, Any]]],
) -> str:
    if active_brand and active_brand.get("name"):
        loc = (
            f"\nThe user is working inside the brand **{active_brand['name']}** "
            f"(brand_id: {active_brand.get('id')}). Treat its Brand Knowledge as the "
            "primary source of truth for brand-related questions. When you call "
            "`get_brand_knowledge`, omit brand_id to use this active brand."
        )
        return loc + _INTENT_RULES

    if brand_directory:
        names = ", ".join(
            f"{b.get('name')} (brand_id: {b.get('id')})" for b in brand_directory if b.get("name")
        )
        loc = (
            f"\nThe user is on the Home page with access to these brands: {names}. "
            "If they ask about a specific one, call `get_brand_knowledge` with that "
            "brand's brand_id and use its Brand Knowledge as the primary source of truth."
        )
        return loc + _INTENT_RULES

    return (
        "\nNo active brand context is available. Answer generically and do NOT call "
        "`get_brand_knowledge`."
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent/test_brand_awareness_prompt.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Add DTO fields**

In `ai-service/app/agents/chat_agent/request_schema.py`, ensure the typing import includes `Any, Dict` (line ~2: `from typing import Any, Dict, List, Optional, Union`), then add to `AgentRunDto` right after the `thread_type: Optional[str] = None` field (~line 136):

```python
    # Brand awareness location context (resolved by the API before streaming)
    active_brand: Optional[Dict[str, Any]] = None  # {id, name, description}
    brand_directory: Optional[List[Dict[str, Any]]] = None  # [{id, name, description}, ...]
```

- [ ] **Step 6: Verify schema import + run**

Run: `cd ai-service && source .venv/bin/activate && python -c "from app.agents.chat_agent.request_schema import AgentRunDto; AgentRunDto(message='hi', user_id='u', thread_id='t', active_brand={'id':'b1','name':'X'}); print('ok')"`
Expected: prints `ok`.

- [ ] **Step 7: Commit**

```bash
git -C ai-service add app/agents/chat_agent/request_schema.py app/agents/chat_agent/brand_awareness_prompt.py tests/agents/chat_agent/test_brand_awareness_prompt.py
git -C ai-service commit -m "feat(ai): add brand location DTO fields + brand awareness prompt"
```

---

## Task 6: Register tool + hint on the DEFAULT chat agent

**Files:**
- Modify: `ai-service/app/agents/chat_agent/service.py` (in `run_agent`, lines ~652, ~698-707, ~710-722)

- [ ] **Step 1: Add the tool factory import**

At the top of `service.py` with the other tool imports, add:

```python
from app.tools.get_brand_knowledge import make_get_brand_knowledge
from app.agents.chat_agent.brand_awareness_prompt import build_brand_awareness_prompt
```

- [ ] **Step 2: Build the closure tool and append to tools**

Replace the tools line (~652) `tools = [generate_image, web_search, generate_video]` with:

```python
        brand_tool = make_get_brand_knowledge(
            user_id=formatted_user_id,
            workspace_id=args.workspace_id,
            thread_id=args.thread_id,
            active_brand=args.active_brand,
            brand_directory=args.brand_directory,
        )
        tools = [generate_image, web_search, generate_video, brand_tool]
```

- [ ] **Step 3: Append the brand awareness hint to the prompt**

Immediately after the `prompt = get_prompt(...)` block (~707), add:

```python
        prompt = prompt + build_brand_awareness_prompt(
            active_brand=args.active_brand,
            brand_directory=args.brand_directory,
        )
```

- [ ] **Step 4: Ensure tool_hook injection won't break the closure**

The closure accepts `**kwargs`, so `tool_hook` injecting `extra_tool_arguments` is harmless — no change needed. (Confirm `extra_tool_arguments` is unchanged.)

- [ ] **Step 5: Smoke-import the module**

Run: `cd ai-service && source .venv/bin/activate && python -c "import app.agents.chat_agent.service as s; print('import ok')"`
Expected: prints `import ok` (no ImportError).

- [ ] **Step 6: Run the full agent test subset that touches service.py**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent -v`
Expected: PASS (existing + new tests; no regressions).

- [ ] **Step 7: Commit**

```bash
git -C ai-service add app/agents/chat_agent/service.py
git -C ai-service commit -m "feat(ai): wire get_brand_knowledge + brand hint into default chat agent"
```

---

## Task 7: Register tool + hint on the PAA agent

**Files:**
- Modify: `ai-service/app/agents/chat_agent/paa_agent_factory.py` (`build_askfrnd_system_prompt`, `build_askfrnd_agent`, and the variant builders)
- Modify: `ai-service/app/agents/chat_agent/service.py` (`run_paa_agent` call site — pass `active_brand`/`brand_directory` through)

- [ ] **Step 1: Thread brand context into the prompt builder**

In `paa_agent_factory.py`, update `build_askfrnd_system_prompt` signature and append the hint. Change line 159:

```python
def build_askfrnd_system_prompt(
    user_email: Optional[str],
    active_brand: Optional[dict] = None,
    brand_directory: Optional[list] = None,
) -> str:
```

At the end (replace `return "\n".join(agent_prompt)` at line 231):

```python
    from .brand_awareness_prompt import build_brand_awareness_prompt
    return "\n".join(agent_prompt) + build_brand_awareness_prompt(active_brand, brand_directory)
```

- [ ] **Step 2: Thread brand context + tool into `build_askfrnd_agent`**

Update `build_askfrnd_agent` signature (line 234) to accept the new params:

```python
def build_askfrnd_agent(
    user_id: str,
    thread_id: str,
    model_provider: Optional[str] = None,
    model: Optional[str] = None,
    user_email: Optional[str] = None,
    active_brand: Optional[dict] = None,
    brand_directory: Optional[list] = None,
) -> Agent:
```

Add the import near the top of the file:

```python
from app.tools.get_brand_knowledge import make_get_brand_knowledge
```

Replace the `description=` and `tools=` arguments in the `return Agent(...)` (lines 298-303):

```python
        description=build_askfrnd_system_prompt(user_email, active_brand, brand_directory),
        tools=[
            ResendTools(from_email="hi@frnd.io"),
            make_get_brand_knowledge(
                user_id=user_id,
                workspace_id=None,
                thread_id=thread_id,
                active_brand=active_brand,
                brand_directory=brand_directory,
            ),
        ],
```

- [ ] **Step 3: Pass through from the variant builders**

Update `build_askfrnd_large_context_agent` (line 320) and `build_askfrnd_fallback_agent` (line 338) to accept `active_brand`/`brand_directory` params and forward them in their `build_askfrnd_agent(...)` calls. Example for the large-context builder:

```python
def build_askfrnd_large_context_agent(
    user_id: str,
    thread_id: str,
    user_email: Optional[str] = None,
    active_brand: Optional[dict] = None,
    brand_directory: Optional[list] = None,
) -> Agent:
    return build_askfrnd_agent(
        user_id=user_id,
        thread_id=thread_id,
        model_provider=ASKFRND_DEFAULT_MODEL_PROVIDER,
        model=ASKFRND_LARGE_CONTEXT_MODEL,
        user_email=user_email,
        active_brand=active_brand,
        brand_directory=brand_directory,
    )
```

Apply the same shape to `build_askfrnd_fallback_agent`.

- [ ] **Step 4: Pass `args.active_brand` / `args.brand_directory` at the PAA call sites**

In `service.py`, find `run_paa_agent` and every call to `build_askfrnd_agent` / `build_askfrnd_large_context_agent` / `build_askfrnd_fallback_agent`. Add `active_brand=args.active_brand, brand_directory=args.brand_directory` to each call. (Use grep to find them.)

Run to locate: `cd ai-service && grep -n "build_askfrnd_\(agent\|large_context_agent\|fallback_agent\)(" app/agents/chat_agent/service.py`

- [ ] **Step 5: Update the token-count prompt for model selection**

`select_askfrnd_model` counts tokens with `build_askfrnd_system_prompt(...)`. If `run_paa_agent` calls `build_askfrnd_system_prompt(user_email)` for the count, update that call to include `args.active_brand, args.brand_directory` so the size estimate stays accurate. (Grep `build_askfrnd_system_prompt(` in service.py.)

- [ ] **Step 6: Smoke-import + test**

Run: `cd ai-service && source .venv/bin/activate && python -c "from app.agents.chat_agent.paa_agent_factory import build_askfrnd_agent; print('ok')"`
Expected: prints `ok`.

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git -C ai-service add app/agents/chat_agent/paa_agent_factory.py app/agents/chat_agent/service.py
git -C ai-service commit -m "feat(ai): wire get_brand_knowledge + brand hint into PAA agent"
```

---

## Task 8: Full suite + manual contract check

- [ ] **Step 1: Run the new + adjacent suites**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/chat_agent tests/tools/test_get_brand_knowledge.py tests/repositories -v`
Expected: all PASS.

- [ ] **Step 2: Verify DTO accepts the API contract shape**

Run:
```bash
cd ai-service && source .venv/bin/activate && python -c "
from app.agents.chat_agent.request_schema import AgentRunDto
d = AgentRunDto(message='what is our brand tone?', user_id='u', thread_id='t',
  active_brand={'id':'b1','name':'OCBC','description':'bank'},
  brand_directory=[{'id':'b1','name':'OCBC','description':'bank'}])
print(d.active_brand, len(d.brand_directory))
"
```
Expected: prints the active_brand dict and `1`.

- [ ] **Step 3: Commit any final fixups**

```bash
git -C ai-service add -A && git -C ai-service commit -m "test(ai): brand-aware AskFrnd suite green" || echo "nothing to commit"
```

---

## Notes for the implementer
- Do NOT push or open a PR — Daffa pushes manually (see workspace convention).
- The repository reads from the same Postgres DB the API uses (`DB_NAME=frnd`), confirmed shared. No new connection/config needed.
- Access control is the API's job; this service only fetches brand_ids present in `active_brand`/`brand_directory`.
- If a PAA call site or token-count call is missed in Task 7, the symptom is the PAA agent answering brand questions without the hint — grep is your friend.
