# Creative Studio — Design Spec

**Date:** 2026-04-19
**Author:** Daffa Praramadhana (brainstormed with Claude)
**Status:** Draft — awaiting review
**Slug:** `creative-studio`
**Source material:** FigJam board "CIMB - KV Generator - Motion" (https://www.figma.com/board/15WNcfp3jJ1TSEQNS6T1TD/), node 518:4583
**Supersedes:** `creative-studio-home`, old `kv-generator` wireframe set (10 wireframes), old `kv-generator` service PRDs

---

## 1. Overview

Creative Studio is a per-project workspace for KV (Key Visual) creation in frndOS. It replaces the current ad-hoc KV Generator flow with a structured, reviewable, three-phase workflow:

```
Concept  →  Craft  →  Resize
```

Each phase is gated by an explicit Approval action. Approving a phase locks it, unlocks the next, and carries forward the chosen outputs as inputs to the next phase. The result is a creative process that mirrors how brand teams actually hand off work — from creative direction (Concept), to execution (Craft), to platform delivery (Resize).

For MVP, only the KV Generator tool runs through this Studio shell (per stakeholder decision: *"MVP Studio: hanya KV Generator"*). Resizer and Storyboard Generator remain separate tools in the existing Tools row.

### Why this exists

The current KV Generator is a single-screen tool: brief in, image out. There is no:
- Structured handoff between creative roles (Art Director → Designer → Studio resizer)
- Phase-level approval state
- Forward-flow of context (each generation re-prompts from scratch)
- Project-level dashboard with status visibility

Creative Studio fixes all four by introducing the gated 3-phase model and a per-tool dashboard (the KV Generator hub).

---

## 2. Scope

### In scope (this brainstorm → wireframe)

5 connected screens forming one wireframe (`creative-studio`):

1. **KV Generator Dashboard** — `/workflows/creative-studio/page.tsx` — list of all KV projects for the active brand
2. **Create Project** — `/workflows/creative-studio/projects/new/page.tsx` — full-page brief intake
3. **Studio: Concept** — `/workflows/creative-studio/projects/[id]/concept/page.tsx`
4. **Studio: Craft** — `/workflows/creative-studio/projects/[id]/craft/page.tsx`
5. **Studio: Resize** — `/workflows/creative-studio/projects/[id]/resize/page.tsx`

### Out of scope (deferred)

- Global Studio Homepage (`/studio`) — already exists in production as `Studiofrndos.tsx`; no redesign in this work
- Resizer and Storyboard Generator tools — out of MVP per stakeholder decision
- Designated-reviewer approval flow — MVP is self-serve approval; gating UI designed so this can be added later without layout changes
- Live-edit Templates with save (Overlays sub-flow from FigJam) — defer to v2
- Multi-user real-time collaboration on the canvas
- Skipping phases or re-ordering them

### Killed by this work

- `creative-studio-home` PRD and in-progress wireframe (was building a unified `/studio` redesign — superseded)
- `kv-generator` 10 approved wireframes (project-dashboard, asset-config, image-options-gallery, template-library, project-detail, route-selection, generation-progress, template-setup, platform-size-selection, export-preview)
- `kv-generator` service PRDs (50 api / 44 web / 20 ai-service tasks) — to be rebuilt under the new structure during `prd_splitting`

---

## 3. User Stories

- **US-01:** As a Creative Director, I want to see all my brand's KV projects on one dashboard, so that I can track production at a glance.
- **US-02:** As an Art Director, I want to brief a project once and have that brief carry through every phase, so that I don't repeat myself when handing off.
- **US-03:** As a Designer, I want to approve the Concept phase explicitly before moving to Craft, so that downstream work doesn't drift from the agreed concept.
- **US-04:** As a Designer, I want to revisit a previously-approved phase to make a change, with clear awareness that downstream phases will need re-syncing.
- **US-05:** As a Designer, I want to attach assets (moodboards, references) to my prompts using `@-mentions`, so that the AI knows exactly what I'm referring to.
- **US-06:** As a Studio resizer, I want the master KV from Craft to flow into Resize automatically, so that I don't re-upload or re-find files.
- **US-07:** As a Brand Manager, I want all phases to respect the Brand Guidelines toggle by default, so that generated work stays on-brand without me policing every prompt.
- **US-08:** As a teammate in the same brand, I want to see my colleagues' in-progress projects on the Dashboard, so that we have shared visibility (no siloed work).

---

## 4. Architecture

### Routes

```
web/src/app/(dashboard)/workflows/creative-studio/
├── page.tsx                              # KV Generator Dashboard
├── components/                           # Shared across all sub-pages
│   ├── BaseLayout.tsx                    # Wraps frndos BaseLayout + studio chrome
│   ├── PhaseStepper.tsx                  # Top stepper (states: active, approved, rejected, locked)
│   ├── StudioChassis.tsx                 # Three-pane shell (left rail / canvas / right rail)
│   ├── ApprovalCTA.tsx                   # Bottom-right Mark as Approved area + confirm modal
│   ├── CarriedForwardStrip.tsx           # Top-of-canvas "from previous phase" banner
│   ├── ChatPanel.tsx                     # Right-rail prompt with @-mentions
│   ├── HistoryPanel.tsx                  # Right-rail history above chat
│   └── FloatingToolbar.tsx               # Bottom-center canvas toolbar
├── metadata.json                         # Wireframe metadata
├── projects/
│   ├── new/
│   │   └── page.tsx                      # Create Project (full page)
│   └── [id]/
│       ├── concept/page.tsx              # Studio: Concept
│       ├── craft/page.tsx                # Studio: Craft
│       └── resize/page.tsx               # Studio: Resize
```

### Key architectural decisions

1. **Separate routes per phase** (chosen over tabs or wizard). Reasons:
   - Each phase is a substantial workspace (not a form step)
   - Deep-linking matters for handoffs and review (people share phase URLs)
   - Browser back/forward maps to user mental model
   - Locked phases still get a route — the route guards by checking phase state and renders a "🔒 Approve [previous] to unlock" empty state if accessed prematurely

2. **Three-pane chassis shared across phases** (Lovart-inspired). Reasons:
   - Creative-pro mental model (Figma, Lovart, Photoshop)
   - Build the chassis once, reuse three times
   - Phases differ only in left-rail tools, canvas content, and chat skill suggestions

3. **Self-serve approval for MVP** with confirmation modal. Reasons:
   - Simplest mechanic that still creates the gating discipline
   - Confirm modal makes the unlock action deliberate (not accidental)
   - Layout supports future "Submit for Review" without rework — same button, different handler

4. **Forward-flow context via "Carried from Concept/Craft" strip** at top of subsequent phases. Reasons:
   - Visual reinforcement of the gating model
   - Read-only by design — to change the carry, user goes back to the source phase
   - One-click peek-back without leaving current phase

---

## 5. Layout Chassis

The shared shell wrapping Concept, Craft, and Resize. Built once in `StudioChassis.tsx`, parameterized per phase.

### Anatomy

```
┌─────────────────────────────────────────────────────────────────┐
│ TOP BAR                                                         │
│ ◀ Back  ·  ① Concept ✓ → ② Craft ● → ③ Resize 🔒                │
│ Project name ▾  ·  Brand: ON  ·  Credits: 10  ·  Avatars        │
├──┬─────────────────────────────────────────────────┬────────────┤
│  │  CARRIED FORWARD STRIP (Craft & Resize only)    │ RIGHT RAIL │
│L │  [📌 From Concept: "Ramadan family warmth"]     │            │
│E │                                                 │ Skills     │
│F │                                                 │ ┌────────┐ │
│T │                                                 │ │ chips  │ │
│  │              CANVAS                             │ └────────┘ │
│R │      (phase-specific content)                   │            │
│A │                                                 │ History    │
│I │                                                 │  ─ thumb   │
│L │                                                 │  ─ thumb   │
│  │                                                 │            │
│  │  ┌── Floating bottom toolbar ──┐                │ ┌────────┐ │
│  │  │ ↗ ⊙ ▣ ▦ ▢ ✎ T 🖼 ✨        │                │ │ Type @ │ │
│  │  └─────────────────────────────┘                │ │ to     │ │
│  │  [zoom 100% · layers · snap]                    │ │ mention│ │
│  │                                                 │ └────────┘ │
├──┴─────────────────────────────────────────────────┴────────────┤
│                            Status: In Progress                  │
│         [More ▼] [Mark as Reviewed] [Mark as Approved →]        │
└─────────────────────────────────────────────────────────────────┘
```

### Region specs

| Region | Width | Behavior |
|---|---|---|
| **Top bar** | full | Sticky, ~56px tall. Stepper is left, project meta is right. |
| **Left rail** | 64px fixed | Vertical icon strip. Tooltips on hover. Collapsible to 0 (toggle in top bar). |
| **Canvas** | flex (fills) | Scrollable, zoomable. Background grid optional. |
| **Right rail** | 360px (default), drag-resize 280–480px, collapsible | Always shows: Skills (top, collapsible), History (middle, collapsible), Chat input (bottom, sticky). |
| **Carried strip** | full canvas width | Sticky to top of canvas region. ~48px tall. Click → modal preview of source phase. |
| **Floating toolbar** | auto, centered | Floats at bottom-center of canvas, ~60px above bottom edge. |
| **Approval bar** | full | Sticky bottom, ~64px tall. Status label + 3 actions. |

### Asset tokens via @-mentions

The Chat panel input supports `@-mentions` that insert structured asset tokens into the prompt:
- `@Moodboard 1` — references a moodboard attached in Concept
- `@SketchA` — references a sketch from Concept
- `@Brief` — references the project brief
- `@Logo`, `@BrandColors` — references brand assets (when Brand Guidelines: ON)
- `@PreviousVariant` — in Craft, references a previous generation from History

Mentions render as **chips** in the prompt input. On submit, they serialize as canonical references the AI service can resolve.

### Brand Guidelines toggle

Lives in the top bar as a pill: `Brand: ON` (green) / `Brand: OFF` (gray). When ON, every generation includes the active brand's guidelines (logo lockups, color palette, tone). When OFF, AI ignores brand context. Defaults to ON. Per-phase override is NOT supported in MVP — it's a project-level toggle.

---

## 6. Per-Phase Content

### Concept

**Purpose:** Define the creative direction. Outputs are textual concepts and/or sketch directions that will be executed in Craft.

**Empty state (first visit):**
```
       How would you like to start?

  [ ✏  Start with a Sketch ]
  [ 💡 Start with an Ideas ]
```

Both modes drop into the **same canvas** after picking — only the entry affordances differ:
- **Sketch mode** → pen tool pre-selected, blank artboard, prompt input pre-filled with template *"Refine this sketch into…"*
- **Ideas mode** → focus moves to chat input, canvas shows a moodboard slot ("drop image here") plus an empty concepts grid

**Working canvas:**
- Top: moodboard tiles (drag-drop to upload, or `@-mention` from brand library)
- Center: sketch artboard (if used)
- Bottom: concepts grid — each generation produces N concept cards (text + small visual hint). User selects one or more to carry forward.

**Left rail tools:**
- Brief (open the project brief in a side sheet)
- Moodboard
- Sketch
- Bounding Box (for area-specific prompts on the moodboard)
- Style Presets

**Right rail:**
- Skills suggestions: "Generate 3 concept directions", "Refine this concept", "Try a different mood"
- History: every generation as a thumb (text concept rendered as a card)
- Chat: prompt with `@Moodboard`, `@SketchA`, `@Brief` mentions

**On Approve, carries forward:** selected concept(s) + brief snapshot + moodboard

---

### Craft

**Purpose:** Generate the actual KV variants from the chosen Concept. User picks one (or a small set) as the master KV.

**Carried-forward strip (top of canvas):**
```
📌 From Concept: "Ramadan family warmth · golden hour · joyful"
   (chosen concept · click to peek)
```

**Working canvas:**
- Variants grid (2-4 columns) — each generation produces multiple KV variants
- Click a variant → focus mode (full-size preview, with Bounding Box overlay for region-specific edits)
- Selected variant gets a "✓ Master KV" badge

**Left rail tools:**
- Style Presets
- Bounding Box
- Text Overlay
- Layers
- Inpaint

**Right rail:**
- Skills suggestions: auto-generated based on current variant — "Try cooler tones", "Push the subject left", "Add a CTA"
- History: every generation as a thumb (full image preview, click to revert/duplicate)
- Chat: prompt with `@StylePreset`, `@Logo`, `@PreviousVariant` mentions

**On Approve, carries forward:** the chosen Master KV + original prompts (so Resize can regenerate-on-resize if needed)

---

### Resize

**Purpose:** Take the Master KV and produce platform/size variants for delivery.

**Carried-forward strip:**
```
📌 From Craft: Master KV (1 variant) · prompts available for re-gen
```

**Working canvas (split layout):**
- Left third: Master KV pinned (large preview)
- Right two-thirds: Multi-platform preview grid — one cell per selected platform/size, showing auto-resized + auto-cropped output. Each cell:
  - "🔒 Lock crop" toggle
  - "✨ Regenerate at this size" (uses original prompts adapted to new aspect ratio)
  - Per-cell download button

**Bottom of canvas (instead of floating toolbar):**
- Platform/Size picker — chips for common platforms (Instagram Story, Instagram Post, Facebook Cover, LinkedIn 1200×627, Twitter Card, etc.) plus "Custom size…" input. Toggling a chip adds/removes a preview cell.

**Left rail tools:**
- Crop
- Safe Area (overlay safe zones per platform)
- Logo Position (per-platform logo placement)
- Background Extend (for aspect-ratio fills)

**Right rail:**
- Skills suggestions: "Generate IG bundle", "Generate paid ads bundle", "Add safe areas for all"
- History: every resize attempt as a thumb (per-platform)
- Chat: less central — mostly "regenerate this size", "fix the crop on @InstagramStory"

**On Approve:** project status flips to **Exported**. Bulk download CTA becomes available. Approval is terminal for MVP (no further phases).

---

## 7. Outer Screens

### KV Generator Dashboard (`page.tsx`)

```
┌───────────────────────────────────────────────────────────┐
│ frndOS › KV Generator                                     │
├───────────────────────────────────────────────────────────┤
│ KV Generator                       [Use Template] [+ New] │
│ Create and manage Key Visual banners                      │
├───────────────────────────────────────────────────────────┤
│ ┌──────┐ ┌──────────┐ ┌──────────┐                        │
│ │ 8    │ │ 3        │ │ 3        │                        │
│ │Total │ │ In Prog. │ │ Exported │                        │
│ └──────┘ └──────────┘ └──────────┘                        │
├───────────────────────────────────────────────────────────┤
│ [🔍 Search…] [▼] [All] Draft  In Prog.  Exported          │
│                                [Segments ▼] [Funnels ▼]   │
├───────────────────────────────────────────────────────────┤
│ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                       │
│ │cover │ │cover │ │cover │ │cover │                       │
│ │Title │ │Title │ │Title │ │Title │                       │
│ │badge │ │badge │ │badge │ │badge │                       │
│ │tags  │ │tags  │ │tags  │ │tags  │                       │
│ │@user │ │@user │ │@user │ │@user │                       │
│ └──────┘ └──────┘ └──────┘ └──────┘                       │
└───────────────────────────────────────────────────────────┘
```

- **Cards** show: cover image, project title, status badge (Draft / In Progress · {Phase} / Exported), segment chip, funnel chip, owner avatar, last-active date, optional "Share link pending" sub-badge
- **Card hover:** lifts, "Open" + "⋯" menu (Duplicate, Share link, Archive)
- **Click:** routes to project's furthest in-progress phase (or Resize if Exported)
- **Empty state:** "No projects yet — start your first KV" + big "+ New Project" CTA
- **Brand-scoped:** list shows projects for the current active brand only, visible to all teammates in that brand
- **Stats cards:** counts derived client-side from the loaded list (no extra fetch)
- **"Use Template" button:** opens template gallery side drawer — defer interactive flow to v2 (just a placeholder in wireframe)

### Create Project (`projects/new/page.tsx`)

```
┌───────────────────────────────────────────────────────────┐
│ frndOS › KV Generator › New Project                       │
├───────────────────────────────────────────────────────────┤
│ New Project                                               │
│                                                           │
│ ── Basics ───────────────────────────────────────────     │
│   Project Name *  [______________________________]        │
│   Segment         [Youth / Mass / Premium ▼]              │
│   Funnel stage    [Awareness / Consideration / Convert ▼] │
│                                                           │
│ ── Brief ────────────────────────────────────────────     │
│   Tabs: [✍ Write] [📎 Upload]                             │
│                                                           │
│   (Write mode):                                           │
│   Campaign Background       [textarea]                    │
│   Product Knowledge         [textarea]                    │
│   Key Message (strategy)    [textarea]                    │
│   Big Idea (creative)       [textarea]                    │
│                                                           │
│   (Upload mode):                                          │
│   Drop a brief deck/PDF here, or [Choose file]            │
│   AI will extract: campaign · product · message · idea    │
│                                                           │
│ ── Brand context ────────────────────────────────────     │
│   Brand Guidelines:  [● ON]   "Active brand: CIMB"        │
│   Reference assets:  [drop / upload]                      │
│                                                           │
├───────────────────────────────────────────────────────────┤
│ [Cancel]                  [Save Draft] [Create & Open ▶]  │
└───────────────────────────────────────────────────────────┘
```

- **Validation:** only Project Name is required. Brief and references can be filled inside Concept later.
- **Write OR Upload tabs** for brief — Upload runs an AI extraction step that pre-fills Write fields (user can edit before creating). Mirrors the FigJam "OR divider" sticky.
- **Brand Guidelines:** defaults ON. Pill shows the active brand inline.
- **"Create & Open Studio" (primary):** creates project + immediately routes to `/projects/[id]/concept` (empty state)
- **"Save Draft":** creates without opening, returns to Dashboard
- **Sticky footer** so CTAs are always reachable on long forms

---

## 8. Phase Gating UX

The Approval mechanic is what makes this a Studio (not just KV Generator v2).

### Stepper states (in `PhaseStepper.tsx`, top bar)

| State | Visual | Interaction |
|---|---|---|
| **Active** | Number circle filled red (frndOS brand), label bold, pulse dot | Current phase, no nav action |
| **Approved** | Green check icon, label muted | Clickable — peek-back to that phase |
| **Rejected** | Amber/red exclamation, label "Concept · Rejected" | Clickable — returns user to that phase |
| **Locked** | Grayed, lock icon | NOT clickable, tooltip: "Approve [previous phase] to unlock" |

### Approval bar (in `ApprovalCTA.tsx`, sticky bottom)

**Default:**
```
Status: In Progress
[More ▼] [Mark as Reviewed] [Mark as Approved →]
```

**Confirm modal on Approve:**
```
┌──────────────────────────────────────┐
│ Approve this Concept?                │
│                                      │
│ Locks Concept, opens Craft.          │
│ You can revisit Concept any time —   │
│ changes will require re-approval.    │
│                                      │
│ Optional note (visible in History)   │
│ [_______________________________]    │
│                                      │
│      [Cancel]  [Approve & Open Craft ▶] │
└──────────────────────────────────────┘
```

**On Approve:**
- Phase status → Approved (green)
- Stepper updates: current phase ✓, next phase circle filled
- Auto-route to next phase
- Next phase opens with the Carried-forward strip already populated
- Toast: "{Phase} approved · Continue with {NextPhase}"

### Three approval actions

| Action | Effect |
|---|---|
| **Mark as Reviewed** | Soft mark, no unlock, no nav. For "looks good, sanity-check before locking." |
| **Mark as Approved** | Hard lock + unlock next phase + route forward. The gate. |
| **Mark as Rejected** *(under More ▼)* | Status → Rejected with required reason. Banner shows on canvas: "⚠ Rejected · {reason}". User revises and re-approves. |

### Re-approving an Approved phase

Clicking ✓ Concept while in Craft:
- Routes back to `/projects/[id]/concept`
- Banner at top of canvas: **"This phase was approved on {date}. Editing will require re-approval to update Craft & Resize."**
- All edits work normally
- Approval CTA changes to **"Re-approve & re-sync downstream"** — explicit about downstream impact

When user re-approves Concept, downstream phases get marked **stale** (yellow indicator on stepper). User reviews each downstream phase and either accepts the carry-forward as-is or regenerates.

### What carries forward between phases

| From | To | Carried |
|---|---|---|
| Concept → Craft | | Selected concept(s), brief snapshot, moodboard, brand state |
| Craft → Resize | | Master KV (1 or small set), original prompts |
| Re-approve Concept | Craft (stale) | Same payload, but downstream marked stale until user reconciles |

### Status surfaced on Dashboard cards

Cards show project's **furthest-Approved phase**:
- "Draft" — no phase Approved yet (Concept in progress)
- "In Progress · Craft" — Concept Approved, Craft in progress
- "In Progress · Resize" — Craft Approved, Resize in progress
- "Exported" — Resize Approved, downloads available

---

## 9. Components — frndos & new

### frndos components used (no new code)

Per CLAUDE.md, use `@/components/frndos/` first. Identified reuses:
- `BaseLayout` — wrapper for every page
- `Breadcrumbs` — top of every page
- `Button` — all CTAs
- `Input` — search, brief textareas, project name
- `BaseModal` — Approval confirm modal, share-link modal
- `Toggle` — Brand Guidelines toggle
- `BaseTable` — possibly the Dashboard if grid view doesn't suit (decide during wireframe)
- `TabsLine` or `TabsRounded` — Write/Upload tabs in Create Project
- `Avatar` — owner avatars on cards, top-bar collaborators
- `CardMetric` — the 3 stats cards on Dashboard
- `Toast` — Approval success notifications
- `Pagination` — Dashboard if list grows

### New custom wireframe components (in `creative-studio/components/`)

These are wireframe-local — not promoted to frndos until proven across multiple wireframes:
- `PhaseStepper` — top stepper with locked/active/approved/rejected states
- `StudioChassis` — three-pane shell wrapper
- `ApprovalCTA` — bottom-right approval bar + confirm modal
- `CarriedForwardStrip` — top-of-canvas "from previous phase" banner
- `ChatPanel` — right-rail prompt with `@-mention` picker (extends existing AskFRND patterns if any)
- `HistoryPanel` — right-rail history thumbs
- `FloatingToolbar` — bottom-center canvas toolbar
- `ConceptCard`, `KVVariantCard` — phase-specific result cards
- `PlatformPreviewCell` — Resize phase's per-platform preview cell
- `MentionChip` — token rendering inside prompt input

### New libraries (allowed per CLAUDE.md, prefer existing if possible)

- A mention/autocomplete library for the chat input — check `web/package.json` first; if `@tiptap/react` or similar is already installed, use it. Otherwise consider `react-mentions` (small, focused) for the wireframe.

---

## 10. Open Questions

These do not block the wireframe but should be resolved before implementation:

1. **Image model selection** — FigJam sticky says *"user tentukan image model"*. Where does the model picker live? Options: per-prompt dropdown in chat input, project-level setting in Create Project, or top-bar pill. **Punt to wireframe stage — try in chat input first.**
2. **Loveart benchmark** — Rafly's task to study Loveart for Concept-state details. The current design already adopts Lovart's layout. Any specific Concept-state pattern from Loveart we should mirror that's not in this spec? **Owner: Rafly. Non-blocking.**
3. **Brand Guidelines OFF behavior** — when OFF, do we still pass brand context to the AI but allow it to be ignored, or strip brand context entirely? **Default for wireframe: strip entirely.**
4. **History storage scope** — global to project (one history shared across phases) or per-phase? **Default for wireframe: per-phase, since each phase generates fundamentally different outputs.**
5. **"Use Template" button on Dashboard** — interactive in MVP or wireframe placeholder? **Default: placeholder for now, defer interaction.**
6. **Concept output type** — text-only ("Family · joyful · golden hour" tags) or visual (rough sketch outputs)? **Default for wireframe: both — text concepts as cards, optional sketch outputs.**
7. **Carried-forward editability** — strictly read-only, or allow tweaking inline (e.g., Craft user adjusts the chosen concept text without going back)? **Default: strictly read-only. To change, go back.**

---

## 11. Decisions Made During Brainstorm

| # | Decision | Source |
|---|---|---|
| D-01 | Drop `creative-studio-home` PRD and wireframe | Daffa, this brainstorm |
| D-02 | Drop old `kv-generator` 10 wireframes + service PRDs | Daffa, this brainstorm |
| D-03 | Scope = 5 screens (Dashboard, Create Project, Concept, Craft, Resize) | Daffa |
| D-04 | Skip global Studio Homepage redesign | Daffa |
| D-05 | Navigation = separate routes per phase | Recommended, accepted |
| D-06 | Create Project = full page route | Recommended, accepted |
| D-07 | Approval = self-serve for MVP | Recommended, accepted |
| D-08 | Layout chassis = three-pane (Lovart-inspired) | Recommended, accepted with Lovart reference |
| D-09 | MVP wraps only KV Generator | Stakeholder sticky from FigJam (Azizah) |
| D-10 | Asset tokens via `@-mentions` in chat input | Lovart pattern, accepted |
| D-11 | Brand Guidelines = project-level toggle, defaults ON | FigJam + this brainstorm |
| D-12 | Concept dual-mode entry (Sketch vs Ideas) collapses to same canvas | This brainstorm |
| D-13 | Brief in Create Project = Write OR Upload tabs | FigJam "OR divider" sticky |
| D-14 | "Mark as Approved" requires confirm modal | This brainstorm |
| D-15 | Re-approval marks downstream phases stale (not auto-regenerate) | This brainstorm |

---

## 12. Next Steps

After this spec is reviewed:

1. **`/workflow start creative-studio`** — initialize the workflow state
2. **PRD creation** — formalize this design into `frnd/docs/prd/creative-studio.md` with the required frontmatter and sections per CLAUDE.md
3. **Wireframe phase** — build the 5 pages in `web/src/app/(dashboard)/workflows/creative-studio/`
4. **Wireframe PR** — review by Jeff
5. **Implementation phase** — split PRD into per-service PRDs (api, web, ai-service), then implement
