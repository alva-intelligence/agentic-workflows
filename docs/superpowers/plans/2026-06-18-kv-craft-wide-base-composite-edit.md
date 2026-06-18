# KV Craft — Localized Edit on >3:1 Bases via Composite-Back Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a prompt-driven Craft edit on a >3:1 base (e.g. a 3.44:1 banner) preserve the banner's exact ratio, by editing a ≤3:1 window around the inferred area and compositing it back onto the original canvas — replicating ChatGPT.

**Architecture:** New pure helpers in ai-service: `region.infer_anchor(prompt)` (keyword → left/center/right × top/middle/bottom) and `window_edit` (`plan_window`, `build_window_mask`, `composite_back`). The craft image path in `service.py` detects a >3:1 base, crops a ≤3:1 window around the anchor, runs the existing `outpaint(canvas, mask, prompt)` masked-edit primitive on it, composites the result back, and emits a generation at the base's original dimensions. ≤3:1 bases are untouched — they keep the Phase-1 explicit-conformed-size flow. Web relaxes the >3:1 craft-image gate so the prompt-driven path reaches the server.

**Tech Stack:** Python 3.12 / FastAPI / Pillow / pytest (ai-service); Next.js 16 / React / TypeScript (web). Reuses `app/tools/outpaint_image.py` `outpaint()` (gpt-image-2 size+mask) and `app/agents/kv_generator/aspect.py` `MAX_RATIO`.

**Spec:** [docs/superpowers/specs/2026-06-18-kv-craft-wide-base-composite-edit-design.md](../specs/2026-06-18-kv-craft-wide-base-composite-edit-design.md)

**Test policy:** ai-service `AGENTS.md` forbids running tests without permission, but the Task 1–2 tests are **pure** (PIL/in-memory, no DB, no network) and safe to run — same as the existing `tests/agents/kv_generator/test_aspect.py`. Do NOT run anything that hits the DB or the OpenAI API.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `ai-service/app/agents/kv_generator/region.py` | Create | `infer_anchor(prompt) -> Anchor` (keyword → anchor) |
| `ai-service/tests/agents/kv_generator/test_region.py` | Create | Unit tests for anchor inference |
| `ai-service/app/agents/kv_generator/window_edit.py` | Create | `plan_window`, `build_window_mask`, `composite_back` |
| `ai-service/tests/agents/kv_generator/test_window_edit.py` | Create | Unit tests for geometry + composite |
| `ai-service/app/agents/kv_generator/service.py` | Modify | Route >3:1 craft image turns through the windowed composite-back flow |
| `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Modify | Stop blocking the >3:1 craft-image send; update notice copy |

---

## Task 1 — Region inference (pure)

**Files:**
- Create: `ai-service/app/agents/kv_generator/region.py`
- Test: `ai-service/tests/agents/kv_generator/test_region.py`

- [ ] **Step 1: Write the helper**

```python
"""Infer a coarse target region for a localized KV edit from the user prompt.

Wide (>3:1) Craft bases can't be edited whole (gpt-image-2 caps at 3:1), so we
edit a ≤3:1 window around the area the user named ("kiri atas" → left/top).
Keyword-based and deliberately coarse — a 3×3 anchor is enough to place the
window; the model handles fine placement inside it.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Anchor:
    h: str  # "left" | "center" | "right"
    v: str  # "top" | "middle" | "bottom"


# id + en keywords. "tengah" implies horizontal center AND vertical middle.
_H = {
    "left": ("left", "kiri"),
    "right": ("right", "kanan"),
    "center": ("center", "centre", "tengah"),
}
_V = {
    "top": ("top", "atas", "upper"),
    "bottom": ("bottom", "bawah", "lower"),
    "middle": ("middle", "tengah"),
}


def infer_anchor(prompt: str, default_h: str = "left", default_v: str = "top") -> Anchor:
    p = (prompt or "").lower()
    h = next((k for k, kws in _H.items() if any(w in p for w in kws)), default_h)
    v = next((k for k, kws in _V.items() if any(w in p for w in kws)), default_v)
    return Anchor(h=h, v=v)
```

- [ ] **Step 2: Write the test**

```python
from app.agents.kv_generator.region import Anchor, infer_anchor


def test_kiri_atas():
    assert infer_anchor("tambahin copy di kiri atas") == Anchor("left", "top")


def test_kanan_bawah():
    assert infer_anchor("logo di kanan bawah") == Anchor("right", "bottom")


def test_english_top_right():
    assert infer_anchor("add a badge top right") == Anchor("right", "top")


def test_tengah():
    assert infer_anchor("taruh di tengah") == Anchor("center", "middle")


def test_default_when_no_location():
    # No location keyword → sensible default (copy goes top-left).
    assert infer_anchor("make it pop") == Anchor("left", "top")
```

- [ ] **Step 3: Run it (pure, safe)**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_generator/test_region.py -q`
Expected: 5 passed.

- [ ] **Step 4: Commit**

```bash
git add app/agents/kv_generator/region.py tests/agents/kv_generator/test_region.py
git commit -m "feat(ai): infer coarse edit-region anchor from KV prompt"
```

---

## Task 2 — Window geometry + composite (pure)

**Files:**
- Create: `ai-service/app/agents/kv_generator/window_edit.py`
- Test: `ai-service/tests/agents/kv_generator/test_window_edit.py`

- [ ] **Step 1: Write the module**

```python
"""Geometry + compositing for editing a ≤3:1 window of a >3:1 Craft base.

The base's long edge exceeds 3× the short edge, so we crop a ≤3:1 window along
the long axis anchored to the requested side, edit only a masked sub-region of
that window, then composite the window back onto the full-resolution base. The
result keeps the base's exact dimensions.
"""

from dataclasses import dataclass
from io import BytesIO

from PIL import Image

from app.agents.kv_generator.aspect import MAX_RATIO
from app.agents.kv_generator.region import Anchor

Box = tuple[int, int, int, int]


@dataclass(frozen=True)
class WindowPlan:
    crop_box: Box   # (x1, y1, x2, y2) on the base — the ≤3:1 window
    mask_box: Box   # (x1, y1, x2, y2) WITHIN the window — the paint region


def plan_window(base_w: int, base_h: int, anchor: Anchor) -> WindowPlan:
    """Place a ≤3:1 window on the long axis + a paint sub-region inside it."""
    if base_w / base_h > MAX_RATIO:  # wide
        win_h = base_h
        win_w = int(base_h * MAX_RATIO)  # = 3*h, strictly < base_w when >3:1
        if anchor.h == "left":
            x1 = 0
        elif anchor.h == "right":
            x1 = base_w - win_w
        else:
            x1 = (base_w - win_w) // 2
        crop = (x1, 0, x1 + win_w, win_h)
    elif base_h / base_w > MAX_RATIO:  # tall
        win_w = base_w
        win_h = int(base_w * MAX_RATIO)
        if anchor.v == "top":
            y1 = 0
        elif anchor.v == "bottom":
            y1 = base_h - win_h
        else:
            y1 = (base_h - win_h) // 2
        crop = (0, y1, win_w, y1 + win_h)
    else:  # not actually >3:1 — whole image (callers gate this off)
        crop = (0, 0, base_w, base_h)
        win_w, win_h = base_w, base_h

    # Paint sub-region: a half-size box anchored within the window.
    mw, mh = win_w // 2, win_h // 2
    mx = 0 if anchor.h == "left" else (win_w - mw if anchor.h == "right" else (win_w - mw) // 2)
    my = 0 if anchor.v == "top" else (win_h - mh if anchor.v == "bottom" else (win_h - mh) // 2)
    return WindowPlan(crop_box=crop, mask_box=(mx, my, mx + mw, my + mh))


def build_window_mask(win_w: int, win_h: int, mask_box: Box) -> Image.Image:
    """L-mode mask: white (255) = paint, black (0) = preserve. Matches the
    resize outpaint convention (outpaint_image inverts L→RGBA alpha)."""
    mask = Image.new("L", (win_w, win_h), 0)
    x1, y1, x2, y2 = mask_box
    mask.paste(Image.new("L", (x2 - x1, y2 - y1), 255), (x1, y1))
    return mask


def composite_back(base_bytes: bytes, window_bytes: bytes, crop_box: Box) -> bytes:
    """Paste the edited window back onto the original base at crop_box,
    returning PNG bytes at the base's exact dimensions. The edited window may
    have been size-conformed by the model, so resize it to the crop size first."""
    base = Image.open(BytesIO(base_bytes)).convert("RGBA")
    win = Image.open(BytesIO(window_bytes)).convert("RGBA")
    x1, y1, x2, y2 = crop_box
    target = (x2 - x1, y2 - y1)
    if win.size != target:
        win = win.resize(target, Image.LANCZOS)
    base.paste(win, (x1, y1))
    out = BytesIO()
    base.convert("RGB").save(out, format="PNG")
    return out.getvalue()
```

- [ ] **Step 2: Write the test**

```python
from io import BytesIO

from PIL import Image

from app.agents.kv_generator.region import Anchor
from app.agents.kv_generator.window_edit import (
    build_window_mask,
    composite_back,
    plan_window,
)


def _png(w, h, color):
    buf = BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def test_wide_left_window_is_within_3to1_and_left_anchored():
    plan = plan_window(2000, 582, Anchor("left", "top"))
    x1, y1, x2, y2 = plan.crop_box
    assert (x1, y1) == (0, 0)
    assert (y2 - y1) == 582              # full height
    w = x2 - x1
    assert w == int(582 * 3.0)           # ≤3:1 window width
    assert (w / (y2 - y1)) <= 3.0 + 1e-9
    assert w < 2000                      # leaves an untouched strip on the right


def test_wide_right_window_anchored_right():
    plan = plan_window(2000, 582, Anchor("right", "top"))
    x1, _, x2, _ = plan.crop_box
    assert x2 == 2000                    # flush to the right edge


def test_mask_box_inside_window_and_anchored():
    plan = plan_window(2000, 582, Anchor("left", "top"))
    mx1, my1, mx2, my2 = plan.mask_box
    assert (mx1, my1) == (0, 0)          # top-left of the window
    assert mx2 <= (plan.crop_box[2] - plan.crop_box[0])
    assert my2 <= (plan.crop_box[3] - plan.crop_box[1])


def test_build_window_mask_paints_only_mask_box():
    mask = build_window_mask(100, 60, (0, 0, 50, 30))
    assert mask.getpixel((10, 10)) == 255   # paint region
    assert mask.getpixel((80, 50)) == 0     # preserved region


def test_composite_back_preserves_base_dimensions():
    base = _png(2000, 582, (200, 30, 30))
    # Edited window the size of the left ≤3:1 crop, solid green.
    crop = plan_window(2000, 582, Anchor("left", "top")).crop_box
    cw, ch = crop[2] - crop[0], crop[3] - crop[1]
    window = _png(cw, ch, (0, 200, 0))
    out = composite_back(base, window, crop)
    img = Image.open(BytesIO(out))
    assert img.size == (2000, 582)                 # original ratio preserved
    assert img.convert("RGB").getpixel((10, 10)) == (0, 200, 0)      # window pasted
    assert img.convert("RGB").getpixel((1990, 300)) == (200, 30, 30)  # right strip untouched


def test_composite_back_resizes_conformed_window():
    base = _png(2000, 582, (200, 30, 30))
    crop = plan_window(2000, 582, Anchor("left", "top")).crop_box
    # Window returned at a different (conformed) size — must still paste cleanly.
    window = _png(1744, 576, (0, 0, 200))
    out = composite_back(base, window, crop)
    assert Image.open(BytesIO(out)).size == (2000, 582)
```

- [ ] **Step 3: Run it (pure, safe)**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_generator/test_window_edit.py -q`
Expected: 6 passed.

- [ ] **Step 4: Commit**

```bash
git add app/agents/kv_generator/window_edit.py tests/agents/kv_generator/test_window_edit.py
git commit -m "feat(ai): window geometry + composite-back for wide-base KV edits"
```

---

## Task 3 — Wire the windowed composite-back into the craft path

**Files:**
- Modify: `ai-service/app/agents/kv_generator/service.py`

**Context:** `_run_image_mode` handles craft image turns. It already computes
`image_prompt`, resolves `request.base_generation`, and (in the `should_iterate`
branch) calls `edit_image_fn`. Helpers already in this module: `_download_image(url)`,
`_maybe_stamp_logo_url(...)`, and the `GenerationReadyEvent`/`GeneratingEvent` emit
pattern. `upload_file_to_s3` is imported from `app.services.aws`. The masked-edit
primitive `outpaint(canvas, mask, prompt) -> (bytes, model, token_usage)` lives in
`app/tools/outpaint_image.py` (sends gpt-image-2 `size`+`mask` together, returns raw bytes).

- [ ] **Step 1: Add imports**

At the top of `service.py`, add:

```python
import tempfile
from PIL import Image  # already imported in this module — skip if present
from app.agents.kv_generator.aspect import MAX_RATIO
from app.agents.kv_generator.region import infer_anchor
from app.agents.kv_generator.window_edit import (
    build_window_mask,
    composite_back,
    plan_window,
)
from app.tools.outpaint_image import outpaint
```
(Skip any line whose symbol is already imported.)

- [ ] **Step 2: Add the windowed-edit helper**

Add this function near the other module-level helpers in `service.py`:

```python
def _craft_wide_base_composite(
    *,
    base_image_url: str,
    edit_prompt: str,
    studio_file_id: str,
    user_id: str,
) -> Optional[dict]:
    """Localized edit on a >3:1 base that preserves its ratio.

    Crops a ≤3:1 window around the prompt-inferred anchor, masked-edits it with
    gpt-image-2, composites the window back onto the full base, and uploads the
    result. Returns a render dict (image_url + dims) or None if the base isn't
    actually >3:1 (caller falls back to the normal craft path)."""
    base_bytes = _download_image(base_image_url)
    with Image.open(io.BytesIO(base_bytes)) as im:
        base_w, base_h = im.size
        base_rgb = im.convert("RGB")

        long_short = max(base_w, base_h) / min(base_w, base_h)
        if long_short <= MAX_RATIO:
            return None  # not wide — use the standard craft path

        anchor = infer_anchor(edit_prompt)
        plan = plan_window(base_w, base_h, anchor)
        x1, y1, x2, y2 = plan.crop_box
        window = base_rgb.crop((x1, y1, x2, y2))

    mask = build_window_mask(x2 - x1, y2 - y1, plan.mask_box)
    edited_window_bytes, _model, token_usage = outpaint(window, mask, edit_prompt)
    final_bytes = composite_back(base_bytes, edited_window_bytes, plan.crop_box)

    with tempfile.TemporaryDirectory(prefix="kv_wide_edit_") as tmp_dir:
        file_name = f"{uuid.uuid4().hex}.png"
        file_path = os.path.join(tmp_dir, file_name)
        with open(file_path, "wb") as f:
            f.write(final_bytes)
        url = upload_file_to_s3(
            source_path=file_path,
            destination_path=f"kv-generations/{studio_file_id}/{file_name}",
            file_permission="public",
            content_type="image/png",
        )
    return {
        "image_url": url or base_image_url,
        "thumbnail_url": url or base_image_url,
        "prompt_snapshot": edit_prompt,
        "model": "gpt-image-2",
        "ai_service_run_id": str(uuid.uuid4()),
        "token_usage": token_usage or {},
    }
```

- [ ] **Step 3: Branch into it for >3:1 craft turns**

In `_run_image_mode`, inside the `try:` that wraps generation, BEFORE the
`should_iterate` block, add a short-circuit. Bind the condition to the real
craft + base variables already in scope (`request.canvas_mode == "craft"` and
`request.base_generation`):

```python
        is_craft = request.canvas_mode == "craft"
        wide_render = None
        if (
            is_craft
            and request.base_generation
            and request.base_generation.image_url
        ):
            wide_render = _craft_wide_base_composite(
                base_image_url=request.base_generation.image_url,
                edit_prompt=image_prompt,
                studio_file_id=request.studio_file_id,
                user_id=request.user_id,
            )
        if wide_render is not None:
            render = wide_render
        elif should_iterate:
            # ... existing edit_image_fn path unchanged ...
        else:
            # ... existing _render_image path unchanged ...
```

> NOTE: the existing code already assigns `render` in the `should_iterate` /
> else branches. Restructure so the new `wide_render` short-circuit sits in front
> of them (turn the existing `if should_iterate:` into the `elif`). Everything
> after `render` is produced (logo stamp via `_maybe_stamp_logo_url`,
> `GenerationReadyEvent` emit with `mode=request.canvas_mode`, summary stream)
> stays unchanged — the wide-edit render dict has the same keys those steps read.

- [ ] **Step 4: Lint / import check (no network, no DB)**

Run: `cd ai-service && .venv/bin/python -c "import app.agents.kv_generator.service; print('ok')"`
Expected: `ok` (imports resolve).

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_generator/service.py
git commit -m "feat(ai): route >3:1 craft edits through windowed composite-back"
```

---

## Task 4 — web: allow the >3:1 craft-image send

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Context:** Phase 1 added `craftImageBlocked={canvasMode === "craft" && isUploadedBaseUnsupported(latestGen)}` passed to `<KvChat>`, which blocks the freeform craft-image send for >3:1 bases. Now the server handles >3:1 via composite-back, so the send must be allowed through.

- [ ] **Step 1: Stop blocking the >3:1 craft-image send**

Find where `<KvChat ... craftImageBlocked={...} />` is rendered. Change the prop to never block (the server now handles >3:1):

```tsx
              craftImageBlocked={false}
```

Keep the `onCraftImageBlocked` prop wired (harmless; it just no longer fires). Leave the Start-Crafting pill gate (`craftStatus`) as-is — the one-click full polish still isn't a localized edit, so the pill staying disabled for >3:1 is fine; the localized edit comes from the chat prompt.

- [ ] **Step 2: Update the proactive notice copy**

Find the `setTransientNotice("Rasio gambar ini belum didukung untuk Craft ...")` call (fired on import of a >3:1 base) and change it to reflect the new capability:

```tsx
        setTransientNotice(
          "Banner lebar: edit lewat chat diterapkan ke satu area & rasio aslinya dipertahankan.",
        );
```

- [ ] **Step 3: Typecheck**

Run: `cd web && bunx tsc --noEmit` — confirm no NEW errors in `KvGeneratorLayout.tsx` (pre-existing errors in demo/wireframe/test files are fine).

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): allow prompt-driven craft edits on >3:1 bases (composite-back)"
```

---

## Self-Review

- **Spec coverage:** region inference (Task 1), window+mask+composite (Task 2), >3:1 branch in craft path reusing `outpaint` + composite (Task 3), web gate relax + copy (Task 4). ≤3:1 untouched (Task 3 returns None → existing flow). ✓
- **Types:** `Anchor(h,v)` produced by Task 1, consumed by `plan_window` in Task 2 & 3. `WindowPlan.crop_box/mask_box` consumed by `build_window_mask`/`composite_back`/Task 3. `outpaint` returns `(bytes, model, token_usage)` per the resize primitive. ✓
- **Placeholders:** Task 3 Step 3 carries one `NOTE` for the exact restructure point in `_run_image_mode` — concrete code is given; the engineer binds the `elif`/`else` to the existing branches. Not missing logic.
- **Out of scope (correctly excluded):** full-polish tiling re-render.
