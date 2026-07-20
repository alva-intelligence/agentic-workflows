# Studio Storyboard → Video — Phase 3 (ai-service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` — execute each task as an isolated TDD unit (write the failing test, make it pass, commit), dispatching one subagent per task and reviewing its diff before moving on.

**Goal**

Ship the ai-service surface for Phase 3 of the Studio Storyboard tool: the **one net-new capability** in the whole feature — an **FFmpeg-based stitch** that concatenates the ordered per-scene clips into a single mp4. Add to the EXISTING `app/agents/storyboard/` package (created in Phase 1): a `RenderRequest` schema, an FFmpeg stitch utility (`stitch.py`), a background service (`process_render_generation`) that downloads the ordered clips → stitches (`cut` via the concat demuxer, `crossfade` via the `xfade` filter chain) → uploads the mp4 via the SAME S3 helper `generate_video.py` uses → posts a render callback, a router endpoint `POST /ai/storyboard/render` returning `202` + a `BackgroundTask`, and a `post_render_completed()` function added to the storyboard `api_client.py`.

**Stitch is UNMETERED in v1** — FFmpeg compute only, no model cost. The callback forwards no `token_usage` requirement (the field is optional and omitted).

Decompose / cast / frame (Phase 1) and clips (Phase 2) are already shipped; this plan only adds the render path. No new model integrations; the video clips already exist as S3 URLs.

**Architecture**

- The render step follows the codebase's proven async pattern verbatim (as cast-generate + scene-frame do in Phase 1): the router returns `202` immediately and dispatches a `BackgroundTasks` job; the job downloads the ordered clip URLs to a temp dir, runs FFmpeg to produce one mp4, uploads it to S3, then POSTs the result back to the api's internal callback controller with an `X-Internal-Token` header. The DB is the source of truth; the browser polls. Never persist from ai-service.
- **FFmpeg is invoked as a subprocess** through the `imageio-ffmpeg`-provided binary (Task 1 adds this dependency — see the FFmpeg-availability finding below). Two transition modes:
  - `cut` → the **concat demuxer** (`ffmpeg -f concat -safe 0 -i list.txt -c copy` when codecs match; re-encode fallback for safety) produces a hard-cut join.
  - `crossfade` → a chained `xfade` filter (`[0][1]xfade=transition=fade:duration=D:offset=O; …`) dissolves each clip into the next.
- Structure mirrors the Phase 1 storyboard package: the render path adds `stitch.py` (pure FFmpeg util, unit-testable with the subprocess mocked), extends `request_schema.py` (`RenderRequest`), `response_schema.py` (`RenderAccepted`), `service.py` (`process_render_generation`), `api_client.py` (`post_render_completed`), and `router.py` (`POST /ai/storyboard/render`).

**Tech Stack**

- FastAPI (`BackgroundTasks`), Pydantic v2 schemas.
- **FFmpeg** via `imageio-ffmpeg` (Python wheel bundling a static ffmpeg binary — Task 1). Invoked with `subprocess.run`.
- Existing helper reused verbatim for the upload: `app.services.aws.upload_file_to_s3` (the exact call `generate_video.py` makes — `source_path`, `destination_path=f"{settings.API_ENV}/…/{file_name}"`, `file_permission="public"`).
- `requests` for downloading clip URLs and for the internal callback POST; `pytest` + `unittest.mock` for tests (mirrors `tests/agents/storyboard/` from Phase 1).

## FFmpeg-availability finding (verified 2026-07-03)

FFmpeg is **NOT currently a dependency** of ai-service. Evidence:
- `ai-service/requirements.txt` — no `ffmpeg`, `ffmpeg-python`, `moviepy`, `imageio`, or `imageio-ffmpeg` entry (full file scanned). `opencv-python==4.12.0.88` is present but does **not** ship an ffmpeg CLI binary usable for concat/xfade.
- No `Dockerfile` exists anywhere in the repo (`find . -iname 'Dockerfile*'` → none), so there is no system-level `apt-get install ffmpeg` provisioning either.
- No existing ffmpeg / concat / subprocess-mp4 usage under `ai-service/app/` (grep → none).

**Therefore Task 1 MUST add the FFmpeg dependency.** The plan adds `imageio-ffmpeg` to `requirements.txt` (a pip-installable static ffmpeg binary, no system package needed) and resolves the binary path at runtime via `imageio_ffmpeg.get_ffmpeg_exe()`. Environment provisioning (`uv pip install -r requirements.txt` / `pip install imageio-ffmpeg`) is REQUIRED before the render path runs — noted in Task 1. If the deployment target prefers a system ffmpeg, the util also honors a `FFMPEG_BINARY` env override (falls back to the imageio binary), so ops can point at `apt-get install ffmpeg` instead without code changes.

## Global Constraints

- **Target branch:** `development` (ai-service default branch). Branch name `feature/<worker>/vc-studio-storyboard-video` off latest `development` (same branch as Phases 1/2 if continuing).
- **Add to the EXISTING `app/agents/storyboard/` package** created in Phase 1. Do NOT create a new package. Do NOT touch `app/tools/*`.
- **Reuse the S3 upload helper verbatim** — the same `upload_file_to_s3(source_path=…, destination_path=f"{settings.API_ENV}/…/{file_name}", file_permission="public")` call `generate_video.py` makes. Destination prefix: `f"{settings.API_ENV}/storyboard-renders/{storyboard_id}/{file_name}"`.
- **Callback via `X-Internal-Token`** to `settings.API_INTERNAL_URL`, `timeout=10`, `.raise_for_status()` — reuse the `_post_internal` helper already in `app/agents/storyboard/api_client.py` (Phase 1). Callback path: `/api/v1/internal/storyboard-renders/completed`.
- **Async job → 202 → callback.** The router returns `202` + a `BackgroundTasks` job; the job never raises out of the BackgroundTask.
- **Failure contract:** any FFmpeg non-zero exit, any download failure, an empty clip list, or any raised exception → a `status="failed"` callback with `error_message`. Only a fully-produced + uploaded mp4 yields `status="ready"` with `final_video_url`.
- **Stitch is UNMETERED** — the callback omits `token_usage`. No credit accounting anywhere in this plan.
- **Status vocab is exactly `"ready"` | `"failed"`** on the callback — matches the api `StoryboardRenderCompleteRequest` (`in:ready,failed`) and the web polling.
- **Transition vocab is exactly `"cut"` | `"crossfade"`.** `cut` is the default.
- **DRY / YAGNI / TDD.** No speculative fields. Every task writes the test first. `stitch.py` is written so the FFmpeg subprocess is patchable — tests mock `subprocess.run` and the downloads; they never invoke real ffmpeg.

## File Structure

```
ai-service/
├── requirements.txt                        # + imageio-ffmpeg  (Task 1)
├── app/agents/storyboard/
│   ├── request_schema.py                   # + RenderRequest, RenderClip  (Task 2)
│   ├── response_schema.py                  # + RenderAccepted  (Task 2)
│   ├── stitch.py                           # NEW — FFmpeg concat / xfade util  (Task 3)
│   ├── api_client.py                       # + post_render_completed()  (Task 4)
│   ├── service.py                          # + process_render_generation()  (Task 5)
│   └── router.py                           # + POST /ai/storyboard/render  (Task 6)
└── tests/agents/storyboard/
    ├── test_render_schema.py               # RenderRequest / RenderClip / RenderAccepted validation  (Task 2)
    ├── test_stitch.py                      # concat + xfade command construction (subprocess mocked)  (Task 3)
    ├── test_api_client_render.py           # render callback payload shape + header  (Task 4)
    ├── test_service_render.py              # render job: download -> stitch -> upload -> callback  (Task 5)
    └── test_router_render.py               # 202 dispatch + 422 validation  (Task 6)
```

No `main.py` change is needed — the storyboard router was registered in Phase 1; the new endpoint is an added route on the same router.

---

## Task 1 — Add the FFmpeg dependency

**Files**

- `ai-service/requirements.txt` (modify)

**Interfaces**

Produces: `imageio-ffmpeg` importable; `imageio_ffmpeg.get_ffmpeg_exe()` returns an absolute path to a runnable ffmpeg binary.

**Steps**

1. Add `imageio-ffmpeg` to `requirements.txt`. Insert it alphabetically near the other `i*` entries (e.g. after `idna==3.13`), pinned:

```
imageio-ffmpeg==0.5.1
```

2. Provision the environment (REQUIRED before the render path runs):

```bash
cd ai-service && source .venv/bin/activate && uv pip install -r requirements.txt
```

(or `pip install imageio-ffmpeg==0.5.1` if not using uv).

3. Verify the binary resolves:

```bash
cd ai-service && source .venv/bin/activate && python -c "import imageio_ffmpeg, os; p = imageio_ffmpeg.get_ffmpeg_exe(); print(p); assert os.path.exists(p)"
```

Expected: prints an absolute path to a bundled `ffmpeg` that exists. If the deployment prefers a system ffmpeg instead, set `FFMPEG_BINARY=/usr/bin/ffmpeg` (installed via `apt-get install -y ffmpeg`) — Task 3's util honors that override.

**Commit:** `chore(ai): add imageio-ffmpeg for storyboard stitch (phase 3)`

---

## Task 2 — RenderRequest / RenderClip schemas + RenderAccepted

**Files**

- `app/agents/storyboard/request_schema.py` (append)
- `app/agents/storyboard/response_schema.py` (append)
- `tests/agents/storyboard/test_render_schema.py`

**Interfaces**

Consumes: nothing new (leaf schemas). Produces (append to the existing Phase 1 files):

```python
# request_schema.py  (append)
from typing import List, Literal
from pydantic import BaseModel, Field, model_validator


class RenderClip(BaseModel):
    position: int = Field(ge=1)
    video_url: str = Field(min_length=1)


class RenderRequest(BaseModel):
    storyboard_id: str                       # api-side row id; echoed in the callback (idempotency key)
    clips: List[RenderClip] = Field(min_length=1)
    transition: Literal["cut", "crossfade"] = "cut"
    ratio: str = "16:9"
    created_by: str

    @model_validator(mode="after")
    def _order_clips_by_position(self) -> "RenderRequest":
        # The api sends clips ordered by scene position ascending; sort
        # defensively so the concat order is always deterministic regardless
        # of wire order.
        self.clips = sorted(self.clips, key=lambda c: c.position)
        return self
```

```python
# response_schema.py  (append)
class RenderAccepted(BaseModel):
    storyboard_id: str
    status: str = "accepted"
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_render_schema.py` — assert:
   - a valid `RenderRequest` with two clips parses; defaults `transition="cut"`, `ratio="16:9"`.
   - clips passed out of order (`position` 2 then 1) come back sorted ascending (`clips[0].position == 1`).
   - an empty `clips` list raises `ValidationError`.
   - an unknown `transition` (`"wipe"`) raises `ValidationError`.
   - `RenderAccepted(storyboard_id="sb1").status == "accepted"`.

```python
import pytest
from pydantic import ValidationError

from app.agents.storyboard.request_schema import RenderClip, RenderRequest
from app.agents.storyboard.response_schema import RenderAccepted


def _req(**over):
    base = dict(
        storyboard_id="sb1",
        clips=[
            RenderClip(position=2, video_url="https://cdn/clip-2.mp4"),
            RenderClip(position=1, video_url="https://cdn/clip-1.mp4"),
        ],
        created_by="u1",
    )
    base.update(over)
    return RenderRequest(**base)


def test_defaults_and_sorting():
    req = _req()
    assert req.transition == "cut"
    assert req.ratio == "16:9"
    assert [c.position for c in req.clips] == [1, 2]
    assert req.clips[0].video_url == "https://cdn/clip-1.mp4"


def test_empty_clips_rejected():
    with pytest.raises(ValidationError):
        RenderRequest(storyboard_id="sb1", clips=[], created_by="u1")


def test_unknown_transition_rejected():
    with pytest.raises(ValidationError):
        _req(transition="wipe")


def test_render_accepted_default_status():
    assert RenderAccepted(storyboard_id="sb1").status == "accepted"
```

2. Run `pytest tests/agents/storyboard/test_render_schema.py -q` → **red** (schemas missing).
3. Append the schemas to `request_schema.py` and `response_schema.py`.
4. Re-run → **green** (expected: `4 passed`).

**Commit:** `feat(ai): storyboard render request/accepted schemas (phase 3)`

---

## Task 3 — FFmpeg stitch utility (`stitch.py`)

**Files**

- `app/agents/storyboard/stitch.py`
- `tests/agents/storyboard/test_stitch.py`

**Interfaces**

Consumes: `subprocess`, `os`, `imageio_ffmpeg`. Produces:

```python
# stitch.py
import os
import subprocess
from typing import List

import imageio_ffmpeg


def _ffmpeg_bin() -> str:
    """Resolve an ffmpeg binary: an explicit FFMPEG_BINARY env override wins
    (ops may install a system ffmpeg), else the imageio-ffmpeg bundled static
    binary (added to requirements.txt in phase 3 Task 1)."""
    override = os.environ.get("FFMPEG_BINARY")
    if override:
        return override
    return imageio_ffmpeg.get_ffmpeg_exe()


def _run(cmd: List[str]) -> None:
    """Run ffmpeg, raising RuntimeError with stderr tail on non-zero exit."""
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip()[-800:]
        raise RuntimeError(f"ffmpeg exited {proc.returncode}: {tail}")


def _probe_duration(path: str) -> float:
    """Read a clip's duration in seconds via ffmpeg (ffprobe-free — parse the
    stderr `Duration:` line). Best-effort; returns 0.0 if unparsable so the
    caller can fall back to a fixed crossfade offset."""
    proc = subprocess.run([_ffmpeg_bin(), "-i", path], capture_output=True, text=True)
    for line in (proc.stderr or "").splitlines():
        line = line.strip()
        if line.startswith("Duration:"):
            hms = line.split("Duration:", 1)[1].split(",", 1)[0].strip()
            try:
                h, m, s = hms.split(":")
                return int(h) * 3600 + int(m) * 60 + float(s)
            except (ValueError, IndexError):
                return 0.0
    return 0.0


def stitch_cut(clip_paths: List[str], output_path: str) -> str:
    """Hard-cut concatenation via the concat demuxer. Re-encodes to a uniform
    codec so clips with differing parameters still join cleanly."""
    if not clip_paths:
        raise ValueError("stitch_cut requires at least one clip")

    list_path = os.path.join(os.path.dirname(output_path), "concat_list.txt")
    with open(list_path, "w") as f:
        for p in clip_paths:
            escaped = p.replace("'", "'\\''")
            f.write(f"file '{escaped}'\n")

    cmd = [
        _ffmpeg_bin(), "-y",
        "-f", "concat", "-safe", "0",
        "-i", list_path,
        "-c:v", "libx264", "-preset", "veryfast",
        "-c:a", "aac",
        "-movflags", "+faststart",
        output_path,
    ]
    _run(cmd)
    return output_path


def stitch_crossfade(
    clip_paths: List[str], output_path: str, fade_duration: float = 0.5
) -> str:
    """Dissolve each clip into the next via a chained xfade filter. Each xfade
    offset is the running total of prior clip durations minus the accumulated
    fade overlaps."""
    if not clip_paths:
        raise ValueError("stitch_crossfade requires at least one clip")
    if len(clip_paths) == 1:
        # Nothing to cross-fade — a single clip is just re-encoded through.
        cmd = [
            _ffmpeg_bin(), "-y", "-i", clip_paths[0],
            "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac",
            "-movflags", "+faststart", output_path,
        ]
        _run(cmd)
        return output_path

    durations = [_probe_duration(p) or 4.0 for p in clip_paths]

    inputs: List[str] = []
    for p in clip_paths:
        inputs.extend(["-i", p])

    # Video xfade chain.
    v_filters: List[str] = []
    a_filters: List[str] = []
    prev_v = "[0:v]"
    prev_a = "[0:a]"
    running_offset = durations[0] - fade_duration
    for i in range(1, len(clip_paths)):
        out_v = f"[vx{i}]"
        out_a = f"[ax{i}]"
        v_filters.append(
            f"{prev_v}[{i}:v]xfade=transition=fade:duration={fade_duration}:"
            f"offset={max(running_offset, 0):.3f}{out_v}"
        )
        a_filters.append(
            f"{prev_a}[{i}:a]acrossfade=d={fade_duration}{out_a}"
        )
        prev_v = out_v
        prev_a = out_a
        if i < len(clip_paths) - 1:
            running_offset += durations[i] - fade_duration

    filter_complex = ";".join(v_filters + a_filters)
    cmd = [
        _ffmpeg_bin(), "-y",
        *inputs,
        "-filter_complex", filter_complex,
        "-map", prev_v, "-map", prev_a,
        "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac",
        "-movflags", "+faststart",
        output_path,
    ]
    _run(cmd)
    return output_path


def stitch(clip_paths: List[str], output_path: str, transition: str) -> str:
    """Dispatch on transition. `cut` (default) → concat demuxer; `crossfade`
    → xfade chain."""
    if transition == "crossfade":
        return stitch_crossfade(clip_paths, output_path)
    return stitch_cut(clip_paths, output_path)
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_stitch.py` — patch `app.agents.storyboard.stitch.subprocess.run` and `_ffmpeg_bin` so no real ffmpeg runs:
   - `stitch(["/tmp/a.mp4", "/tmp/b.mp4"], "/tmp/out.mp4", "cut")` → asserts `subprocess.run` was called once with a command containing `"-f", "concat"` and ending in `/tmp/out.mp4`; asserts the concat list file was written with two `file '…'` lines.
   - `stitch([...2 clips...], "/tmp/out.mp4", "crossfade")` → asserts the command contains `-filter_complex` and an `xfade=transition=fade` substring and `acrossfade`.
   - `stitch_crossfade(["/tmp/only.mp4"], "/tmp/out.mp4")` (single clip) → command has NO `xfade` (single-clip re-encode branch).
   - non-zero return code → `subprocess.run` returns `MagicMock(returncode=1, stderr="boom")` → `stitch(...)` raises `RuntimeError` containing `"boom"`.
   - empty list → `stitch_cut([], "/tmp/out.mp4")` raises `ValueError`.

```python
from unittest.mock import MagicMock, patch

import pytest

from app.agents.storyboard import stitch as stitch_mod


def _ok_proc():
    return MagicMock(returncode=0, stderr="", stdout="")


@patch("app.agents.storyboard.stitch._ffmpeg_bin", return_value="/bin/ffmpeg")
@patch("app.agents.storyboard.stitch.subprocess.run", return_value=_ok_proc())
def test_cut_uses_concat_demuxer(run, _bin, tmp_path):
    out = str(tmp_path / "out.mp4")
    a, b = str(tmp_path / "a.mp4"), str(tmp_path / "b.mp4")
    result = stitch_mod.stitch([a, b], out, "cut")
    assert result == out
    cmd = run.call_args_list[-1].args[0]
    assert "concat" in cmd and "-f" in cmd
    assert cmd[-1] == out
    listing = (tmp_path / "concat_list.txt").read_text().splitlines()
    assert len(listing) == 2 and listing[0].startswith("file '")


@patch("app.agents.storyboard.stitch._ffmpeg_bin", return_value="/bin/ffmpeg")
@patch("app.agents.storyboard.stitch._probe_duration", return_value=4.0)
@patch("app.agents.storyboard.stitch.subprocess.run", return_value=_ok_proc())
def test_crossfade_uses_xfade_chain(run, _dur, _bin, tmp_path):
    out = str(tmp_path / "out.mp4")
    a, b = str(tmp_path / "a.mp4"), str(tmp_path / "b.mp4")
    stitch_mod.stitch([a, b], out, "crossfade")
    cmd = run.call_args_list[-1].args[0]
    assert "-filter_complex" in cmd
    fc = cmd[cmd.index("-filter_complex") + 1]
    assert "xfade=transition=fade" in fc
    assert "acrossfade" in fc


@patch("app.agents.storyboard.stitch._ffmpeg_bin", return_value="/bin/ffmpeg")
@patch("app.agents.storyboard.stitch.subprocess.run", return_value=_ok_proc())
def test_single_clip_crossfade_has_no_xfade(run, _bin, tmp_path):
    out = str(tmp_path / "out.mp4")
    stitch_mod.stitch_crossfade([str(tmp_path / "only.mp4")], out)
    cmd = run.call_args_list[-1].args[0]
    assert "xfade" not in " ".join(cmd)


@patch("app.agents.storyboard.stitch._ffmpeg_bin", return_value="/bin/ffmpeg")
@patch(
    "app.agents.storyboard.stitch.subprocess.run",
    return_value=MagicMock(returncode=1, stderr="boom", stdout=""),
)
def test_nonzero_exit_raises(run, _bin, tmp_path):
    with pytest.raises(RuntimeError, match="boom"):
        stitch_mod.stitch([str(tmp_path / "a.mp4")], str(tmp_path / "out.mp4"), "cut")


def test_empty_list_raises(tmp_path):
    with pytest.raises(ValueError):
        stitch_mod.stitch_cut([], str(tmp_path / "out.mp4"))
```

2. Run `pytest tests/agents/storyboard/test_stitch.py -q` → **red** (module missing).
3. Create `stitch.py`.
4. Re-run → **green** (expected: `5 passed`).

**Commit:** `feat(ai): storyboard FFmpeg stitch util (cut concat + crossfade xfade)`

---

## Task 4 — Render callback client (`api_client.post_render_completed`)

**Files**

- `app/agents/storyboard/api_client.py` (append)
- `tests/agents/storyboard/test_api_client_render.py`

**Interfaces**

Consumes: the existing `_post_internal` helper from Phase 1's `api_client.py`. Produces (append):

```python
# api_client.py  (append — reuses the existing _post_internal from phase 1)
def post_render_completed(
    *,
    storyboard_id: str,
    status: str,
    final_video_url: Optional[str] = None,
    error_message: Optional[str] = None,
    ai_service_run_id: Optional[str] = None,
) -> None:
    payload: dict = {
        "storyboard_id": storyboard_id,
        "status": status,
    }
    if final_video_url is not None:
        payload["final_video_url"] = final_video_url
    if error_message is not None:
        payload["error_message"] = error_message
    if ai_service_run_id is not None:
        payload["ai_service_run_id"] = ai_service_run_id
    _post_internal("/api/v1/internal/storyboard-renders/completed", payload)
```

> `Optional` is already imported at the top of `api_client.py` (Phase 1). If not, add `from typing import Optional`. Stitch is unmetered → no `token_usage` param.

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_api_client_render.py`, mirroring `test_api_client.py`:
   - `@patch("app.agents.storyboard.api_client.requests.post")` returning `MagicMock(status_code=200, raise_for_status=lambda: None)`.
   - `post_render_completed(storyboard_id="sb1", status="ready", final_video_url="https://cdn/final.mp4", ai_service_run_id="run-1")` → assert url ends with `/api/v1/internal/storyboard-renders/completed`, `json["final_video_url"] == "https://cdn/final.mp4"`, `json["status"] == "ready"`, `"X-Internal-Token" in headers`, and `"token_usage" not in json`.
   - `post_render_completed(storyboard_id="sb1", status="failed", error_message="ffmpeg exploded")` → `json["status"] == "failed"`, `json["error_message"] == "ffmpeg exploded"`, `"final_video_url" not in json`.

```python
from unittest.mock import MagicMock, patch

from app.agents.storyboard.api_client import post_render_completed


@patch("app.agents.storyboard.api_client.requests.post")
def test_render_ready_callback(post):
    post.return_value = MagicMock(status_code=200, raise_for_status=lambda: None)
    post_render_completed(
        storyboard_id="sb1",
        status="ready",
        final_video_url="https://cdn/final.mp4",
        ai_service_run_id="run-1",
    )
    args, kwargs = post.call_args
    assert args[0].endswith("/api/v1/internal/storyboard-renders/completed")
    assert kwargs["json"]["final_video_url"] == "https://cdn/final.mp4"
    assert kwargs["json"]["status"] == "ready"
    assert "token_usage" not in kwargs["json"]
    assert "X-Internal-Token" in kwargs["headers"]


@patch("app.agents.storyboard.api_client.requests.post")
def test_render_failed_callback(post):
    post.return_value = MagicMock(status_code=200, raise_for_status=lambda: None)
    post_render_completed(storyboard_id="sb1", status="failed", error_message="ffmpeg exploded")
    payload = post.call_args.kwargs["json"]
    assert payload["status"] == "failed"
    assert payload["error_message"] == "ffmpeg exploded"
    assert "final_video_url" not in payload
```

2. Run `pytest tests/agents/storyboard/test_api_client_render.py -q` → **red**.
3. Append `post_render_completed` to `api_client.py`.
4. Re-run → **green** (expected: `2 passed`).

**Commit:** `feat(ai): storyboard render internal callback client (post_render_completed)`

---

## Task 5 — Render background job (`service.process_render_generation`)

**Files**

- `app/agents/storyboard/service.py` (append `process_render_generation`)
- `tests/agents/storyboard/test_service_render.py`

**Interfaces**

Consumes: `RenderRequest`, `stitch` (Task 3), `post_render_completed` (Task 4), `upload_file_to_s3`, `settings`, `requests`. Produces (append to `service.py`):

```python
# service.py  (append)
import os
import tempfile
from uuid import uuid4

import requests

from app.agents.storyboard.api_client import post_render_completed
from app.agents.storyboard.request_schema import RenderRequest
from app.agents.storyboard.stitch import stitch
from app.services.aws import upload_file_to_s3
from app.utils.config import settings


def _download_clip(url: str, dest_path: str) -> str:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    with open(dest_path, "wb") as f:
        f.write(resp.content)
    return dest_path


def process_render_generation(req: RenderRequest) -> None:
    """Stitch the ordered scene clips into one mp4 and post the result back.
    Download -> FFmpeg stitch -> S3 upload -> callback. UNMETERED. Any failure
    yields a ``failed`` callback; the job never raises out of the BackgroundTask."""
    ai_service_run_id = str(uuid4())
    tmp_dir = tempfile.mkdtemp(prefix="storyboard_render_")
    try:
        # Clips arrive ordered by position (RenderRequest sorts defensively).
        local_paths = []
        for idx, clip in enumerate(req.clips):
            dest = os.path.join(tmp_dir, f"clip_{idx:03d}.mp4")
            local_paths.append(_download_clip(clip.video_url, dest))

        file_name = f"storyboard_{req.storyboard_id}_{uuid4().hex}.mp4"
        output_path = os.path.join(tmp_dir, file_name)
        stitch(local_paths, output_path, req.transition)

        destination_path = (
            f"{settings.API_ENV}/storyboard-renders/{req.storyboard_id}/{file_name}"
        )
        final_video_url = upload_file_to_s3(
            source_path=output_path,
            destination_path=destination_path,
            file_permission="public",
        )
        if not final_video_url:
            post_render_completed(
                storyboard_id=req.storyboard_id,
                status="failed",
                error_message="Stitched video upload returned no URL",
                ai_service_run_id=ai_service_run_id,
            )
            return

        post_render_completed(
            storyboard_id=req.storyboard_id,
            status="ready",
            final_video_url=final_video_url,
            ai_service_run_id=ai_service_run_id,
        )
    except Exception as exc:  # noqa: BLE001 — any failure must report back
        post_render_completed(
            storyboard_id=req.storyboard_id,
            status="failed",
            error_message=str(exc),
            ai_service_run_id=ai_service_run_id,
        )
    finally:
        try:
            import shutil

            shutil.rmtree(tmp_dir, ignore_errors=True)
        except Exception:  # noqa: BLE001 — cleanup must never mask the result
            pass
```

> Reuse the single import block at the top of `service.py` (do not duplicate the Phase-1 `uuid4` / `os` / `tempfile` / `requests` imports; add only the new `stitch`, `RenderRequest`, `post_render_completed`, `upload_file_to_s3`, `settings` names as needed).

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_service_render.py` (mirror Phase 1's `test_service.py` mocking style):
   - `_render_req(**over)` helper building a valid `RenderRequest` (`storyboard_id="sb1"`, two `RenderClip`s, `created_by="u1"`).
   - happy path: `@patch("app.agents.storyboard.service.post_render_completed")`, `@patch("app.agents.storyboard.service.upload_file_to_s3", return_value="https://cdn/final.mp4")`, `@patch("app.agents.storyboard.service.stitch", return_value="/tmp/out.mp4")`, `@patch("app.agents.storyboard.service._download_clip", side_effect=lambda url, dest: dest)` → assert `stitch` called once with `transition="cut"` and a 2-element clip list; assert `upload_file_to_s3` called with a `destination_path` containing `storyboard-renders/sb1/`; assert `post_render_completed` called with `status="ready"`, `final_video_url="https://cdn/final.mp4"`.
   - upload-returns-None: `upload_file_to_s3` returns `None` → `post_render_completed` `status="failed"`, error contains `"no URL"`.
   - stitch-raises: `stitch` `side_effect=RuntimeError("ffmpeg exited 1")` → `status="failed"`, error contains `"ffmpeg exited 1"`.
   - download-raises: `_download_clip` `side_effect=RuntimeError("404")` → `status="failed"`, error contains `"404"`, and `stitch` NOT called (patch it as a `MagicMock`, assert `not called`).

```python
from unittest.mock import MagicMock, patch

from app.agents.storyboard.request_schema import RenderClip, RenderRequest
from app.agents.storyboard import service as svc


def _render_req(**over):
    base = dict(
        storyboard_id="sb1",
        clips=[
            RenderClip(position=1, video_url="https://cdn/clip-1.mp4"),
            RenderClip(position=2, video_url="https://cdn/clip-2.mp4"),
        ],
        transition="cut",
        created_by="u1",
    )
    base.update(over)
    return RenderRequest(**base)


@patch("app.agents.storyboard.service.post_render_completed")
@patch("app.agents.storyboard.service.upload_file_to_s3", return_value="https://cdn/final.mp4")
@patch("app.agents.storyboard.service.stitch", return_value="/tmp/out.mp4")
@patch("app.agents.storyboard.service._download_clip", side_effect=lambda url, dest: dest)
def test_render_happy_path(dl, stitch_fn, upload, cb):
    svc.process_render_generation(_render_req())
    assert stitch_fn.call_count == 1
    clip_paths = stitch_fn.call_args.args[0]
    assert len(clip_paths) == 2
    assert stitch_fn.call_args.args[2] == "cut"
    assert "storyboard-renders/sb1/" in upload.call_args.kwargs["destination_path"]
    cb.assert_called_once()
    assert cb.call_args.kwargs["status"] == "ready"
    assert cb.call_args.kwargs["final_video_url"] == "https://cdn/final.mp4"


@patch("app.agents.storyboard.service.post_render_completed")
@patch("app.agents.storyboard.service.upload_file_to_s3", return_value=None)
@patch("app.agents.storyboard.service.stitch", return_value="/tmp/out.mp4")
@patch("app.agents.storyboard.service._download_clip", side_effect=lambda url, dest: dest)
def test_render_upload_none_fails(dl, stitch_fn, upload, cb):
    svc.process_render_generation(_render_req())
    assert cb.call_args.kwargs["status"] == "failed"
    assert "no URL" in cb.call_args.kwargs["error_message"]


@patch("app.agents.storyboard.service.post_render_completed")
@patch("app.agents.storyboard.service.upload_file_to_s3", return_value="https://cdn/final.mp4")
@patch("app.agents.storyboard.service.stitch", side_effect=RuntimeError("ffmpeg exited 1"))
@patch("app.agents.storyboard.service._download_clip", side_effect=lambda url, dest: dest)
def test_render_stitch_raises_fails(dl, stitch_fn, upload, cb):
    svc.process_render_generation(_render_req())
    assert cb.call_args.kwargs["status"] == "failed"
    assert "ffmpeg exited 1" in cb.call_args.kwargs["error_message"]


@patch("app.agents.storyboard.service.post_render_completed")
@patch("app.agents.storyboard.service.stitch")
@patch("app.agents.storyboard.service._download_clip", side_effect=RuntimeError("404"))
def test_render_download_raises_fails(dl, stitch_fn, cb):
    svc.process_render_generation(_render_req())
    assert cb.call_args.kwargs["status"] == "failed"
    assert "404" in cb.call_args.kwargs["error_message"]
    stitch_fn.assert_not_called()
```

2. Run `pytest tests/agents/storyboard/test_service_render.py -q` → **red**.
3. Append `process_render_generation` + `_download_clip` to `service.py`.
4. Re-run → **green** (expected: `4 passed`).

**Commit:** `feat(ai): storyboard render job (download + stitch + upload + callback)`

---

## Task 6 — Router endpoint (`POST /ai/storyboard/render`)

**Files**

- `app/agents/storyboard/router.py` (append the render endpoint)
- `tests/agents/storyboard/test_router_render.py`

**Interfaces**

Consumes: `RenderRequest`, `RenderAccepted`, `process_render_generation`. Produces (append to the existing Phase 1 router):

```python
# router.py  (append imports + endpoint)
from app.agents.storyboard.request_schema import RenderRequest
from app.agents.storyboard.response_schema import RenderAccepted
from app.agents.storyboard.service import process_render_generation


@router.post("/render", response_model=RenderAccepted, status_code=202)
def render(req: RenderRequest, background: BackgroundTasks):
    background.add_task(process_render_generation, req)
    return JSONResponse(
        status_code=202,
        content=RenderAccepted(storyboard_id=req.storyboard_id).model_dump(),
    )
```

> `JSONResponse`, `BackgroundTasks`, and the `router` object are already imported/created in the Phase 1 `router.py`. Add only the three new symbol imports above. The storyboard router was registered on `main.py` in Phase 1 — no `main.py` change here.

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_router_render.py` (mirror Phase 1's `test_router.py`):
   - `from fastapi.testclient import TestClient; from main import app; client = TestClient(app)`.
   - `@patch("app.agents.storyboard.router.process_render_generation")` → POST `/ai/storyboard/render` with a valid body (`storyboard_id`, two clips, `transition="crossfade"`, `created_by`) → `status_code == 202`, `json() == {"storyboard_id": "sb1", "status": "accepted"}`, `mock.assert_called_once()`.
   - validation: POST `/ai/storyboard/render` with empty `clips` → `422`.
   - validation: POST with `transition="wipe"` → `422`.

```python
from unittest.mock import patch

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def _body(**over):
    base = {
        "storyboard_id": "sb1",
        "clips": [
            {"position": 1, "video_url": "https://cdn/clip-1.mp4"},
            {"position": 2, "video_url": "https://cdn/clip-2.mp4"},
        ],
        "transition": "crossfade",
        "created_by": "u1",
    }
    base.update(over)
    return base


@patch("app.agents.storyboard.router.process_render_generation")
def test_render_dispatches_202(proc):
    resp = client.post("/ai/storyboard/render", json=_body())
    assert resp.status_code == 202
    assert resp.json() == {"storyboard_id": "sb1", "status": "accepted"}
    proc.assert_called_once()


def test_render_empty_clips_422():
    resp = client.post("/ai/storyboard/render", json=_body(clips=[]))
    assert resp.status_code == 422


def test_render_bad_transition_422():
    resp = client.post("/ai/storyboard/render", json=_body(transition="wipe"))
    assert resp.status_code == 422
```

2. Run `pytest tests/agents/storyboard/test_router_render.py -q` → **red**.
3. Append the render endpoint + imports to `router.py`.
4. Re-run → **green** (expected: `3 passed`).
5. Full-package gate: `pytest tests/agents/storyboard/ -q` → all Phase 1 + Phase 3 tests green (Phase 3 adds render_schema 4 + stitch 5 + api_client_render 2 + service_render 4 + router_render 3 = `18 passed` on top of Phase 1; adjust to actual assertion count).

**Commit:** `feat(ai): register storyboard render endpoint (POST /ai/storyboard/render, 202)`

---

## Self-review checklist (run before opening the PR)

- [ ] `pytest tests/agents/storyboard/ -q` all green (Phase 1 + Phase 3).
- [ ] `imageio-ffmpeg` is in `requirements.txt` and `python -c "import imageio_ffmpeg; imageio_ffmpeg.get_ffmpeg_exe()"` resolves a binary in the provisioned env.
- [ ] `stitch.py` never runs real ffmpeg in tests — `subprocess.run` + `_ffmpeg_bin` are patched.
- [ ] `process_render_generation` has three exit paths (ready callback, upload-None failed callback, exception failed callback) and never raises out of the BackgroundTask; temp dir is cleaned up in `finally`.
- [ ] The render callback uses the SAME `_post_internal` + `X-Internal-Token` + `settings.API_INTERNAL_URL` helper as Phase 1; path is `/api/v1/internal/storyboard-renders/completed`; `status ∈ {ready, failed}`; NO `token_usage` (unmetered).
- [ ] S3 upload reuses `upload_file_to_s3(source_path, destination_path=f"{settings.API_ENV}/storyboard-renders/{storyboard_id}/{file_name}", file_permission="public")` — the same helper/pattern `generate_video.py` uses.
- [ ] `RenderRequest` sorts clips by `position` ascending; `transition` restricted to `cut|crossfade` (default `cut`); empty clip list rejected.
- [ ] Router returns `202` + `{"storyboard_id", "status": "accepted"}` and dispatches a BackgroundTask; the storyboard router was already registered in `main.py` (Phase 1) — no duplicate registration.
- [ ] Placeholder scan: no `TODO`, no `...`, no `pass`-only bodies (except the guarded cleanup `except`), no stub URLs left in shipped code.
