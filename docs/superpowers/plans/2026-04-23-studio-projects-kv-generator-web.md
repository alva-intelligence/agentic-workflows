# Studio Projects & KV Generator — Web (Next.js) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Studio Projects UI (home section, detail page with settings rail, create modal), the new full-screen KV Generator canvas with Chat/Image mode system and SSE-driven generation lifecycle, and the supporting hooks + services. Start with a wireframe to validate flows against the Figma, then build real pages.

**Architecture:** Two route groups — `(dashboard)` keeps current chrome for Studio home + projects, `(canvas)` owns the immersive KV canvas. One shared `useKvStream(fileId)` SSE hook feeds both canvas (versions) and chat (messages) — single source of truth. TanStack Query for server state; Zustand for transient canvas UI. Feature flag `NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED` gates the Projects section.

**Tech Stack:** Next.js 16 App Router, React 19, TypeScript, Tailwind CSS, Zustand, TanStack Query v5, existing frndos components, Playwright (smoke), Vitest (unit).

**Spec reference:** [docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md](docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md)

**Depends on:** API plan Tasks 12–14 (projects CRUD + KV file lifecycle) + Task 15 (callback happens server-side, transparent to web). Wireframe (Tasks 1–3 below) can ship first without API dependency.

---

## File Structure

### Wireframe (ships first — no API needed)
```
web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/
  page.tsx                                   feature index
  studio/
    page.tsx                                 Main: Studio home (Projects empty + populated)
    metadata.json
    components/                              Shared across sub-pages
      ProjectCardMock.tsx
      FileCardMock.tsx
      MockCanvas.tsx
      MockChat.tsx
      MockChatInput.tsx
      MockQuestionCard.tsx
      MockModeSuggestion.tsx
    projects/
      new/page.tsx                           Create project modal
      [id]/page.tsx                          Project detail (empty + populated + settings rail)
      [id]/kv-generator/page.tsx             KV canvas (all streaming states)
```

### Production
```
web/src/app/(dashboard)/studio/
  Studiofrndos.tsx                           (existing, modified)
  page.tsx                                   (existing, unchanged)
  projects/
    new/page.tsx                             NEW intercepting modal route
    [id]/page.tsx                            NEW project detail page

web/src/app/(canvas)/                        NEW route group
  layout.tsx
  studio/
    kv-generator/
      new/page.tsx
      [file_id]/page.tsx

web/src/components/studio/
  projects/
    StudioProjectsSection.tsx                NEW
    ProjectCard.tsx                          NEW
    NewProjectModal.tsx                      NEW
    ProjectDetailLayout.tsx                  NEW
    ProjectSettingsRail.tsx                  NEW
    FileCard.tsx                             NEW
    FileEmptyState.tsx                       NEW

web/src/components/studio/kv-generator/
  KvGeneratorLayout.tsx                      NEW
  KvCanvas.tsx                               NEW
  KvCanvasTopNav.tsx                         NEW
  KvCanvasBottomNav.tsx                      NEW
  KvVersionCard.tsx                          NEW
  KvVersionCardPlaceholder.tsx               NEW
  KvChat.tsx                                 NEW (wraps existing chat components)
  QuestionCardMessage.tsx                    NEW
  ModeSuggestionMessage.tsx                  NEW
  ChatInputModeDropdown.tsx                  NEW
  ChatInputStyleChip.tsx                     NEW

web/src/hooks/
  useStudioProjects.ts                       NEW
  useStudioProject.ts                        NEW
  useStudioProjectFiles.ts                   NEW
  useKvFile.ts                               NEW
  useKvGenerations.ts                        NEW
  useKvStream.ts                             NEW (SSE lifecycle)

web/src/services/
  query.ts                                   MODIFY (add studio project queries)
  mutate.ts                                  MODIFY (add project mutations + file move)

web/src/types/studio.ts                      MODIFY (rename StudioProject → StudioFile; add folder type)

web/src/store/
  useKvCanvasStore.ts                        NEW (Zustand; selected version, viewport)
```

---

## Task 1 — Wireframe index + metadata

**Files:**
- Create: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/page.tsx`
- Create: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/metadata.json`

- [ ] **Step 1: Write the failing test**

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/page.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import FeatureIndex from "./page";

it("links to the studio wireframe", () => {
  render(<FeatureIndex />);
  expect(screen.getByRole("link", { name: /studio/i })).toHaveAttribute(
    "href",
    "/wireframes/studio-projects-kv-generator/studio",
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/app/\(dashboard\)/wireframes/studio-projects-kv-generator/page.test.tsx`
Expected: FAIL — file doesn't exist.

- [ ] **Step 3: Create the files**

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/page.tsx`

```tsx
import Link from "next/link";

export default function FeatureIndex() {
  return (
    <div className="mx-auto max-w-2xl p-8">
      <h1 className="text-2xl font-semibold">Studio Projects & KV Generator</h1>
      <p className="mt-2 text-sm text-neutral-400">
        Wireframe for the new Projects layer + KV Generator canvas. One wireframe,
        multiple sub-pages.
      </p>

      <ul className="mt-6 space-y-2">
        <li>
          <Link
            href="/wireframes/studio-projects-kv-generator/studio"
            className="text-blue-400 hover:underline"
          >
            Open studio wireframe →
          </Link>
        </li>
      </ul>
    </div>
  );
}
```

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/metadata.json`

```json
{
  "feature": "studio-projects-kv-generator",
  "wireframe": "studio",
  "title": "Studio Projects & KV Generator",
  "prd": "docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md",
  "owner": "daffa",
  "status": "in_progress",
  "created": "2026-04-23",
  "approved_by": null,
  "approved_at": null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/app/\(dashboard\)/wireframes/studio-projects-kv-generator/page.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(dashboard\)/wireframes/studio-projects-kv-generator/
git commit -m "feat(web): scaffold studio-projects-kv-generator wireframe index"
```

---

## Task 2 — Wireframe Studio home + Projects empty/populated

**Files:**
- Create: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/page.tsx`
- Create: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/components/ProjectCardMock.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/page.test.tsx`

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import StudioWireframe from "./page";

it("toggles between empty and populated project states", () => {
  render(<StudioWireframe />);
  expect(screen.getByText(/No Studio projects yet/i)).toBeInTheDocument();

  fireEvent.click(screen.getByRole("button", { name: /show populated/i }));
  expect(screen.queryByText(/No Studio projects yet/i)).not.toBeInTheDocument();
  expect(screen.getByText(/CIMB × XG/i)).toBeInTheDocument();
});

it("shows tools section regardless of projects state", () => {
  render(<StudioWireframe />);
  expect(screen.getByText(/All Tools/i)).toBeInTheDocument();
  expect(screen.getByText(/KV Generator/i)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test .../studio/page.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create wireframe**

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/components/ProjectCardMock.tsx`

```tsx
"use client";

import Link from "next/link";

export function ProjectCardMock({
  id,
  name,
  subtitle,
  thumbnailUrl,
}: {
  id: string;
  name: string;
  subtitle: string;
  thumbnailUrl?: string;
}) {
  return (
    <Link
      href={`/wireframes/studio-projects-kv-generator/studio/projects/${id}`}
      className="group block w-[210px] shrink-0"
    >
      <div className="h-[150px] w-full overflow-hidden rounded-xl border border-white/10 bg-neutral-800">
        {thumbnailUrl ? (
          <img src={thumbnailUrl} alt={name} className="h-full w-full object-cover" />
        ) : (
          <div className="flex h-full w-full items-center justify-center text-neutral-500">
            {name}
          </div>
        )}
      </div>
      <div className="mt-3">
        <p className="text-sm font-medium text-white">{name}</p>
        <p className="text-xs text-neutral-400">{subtitle}</p>
      </div>
    </Link>
  );
}
```

File: `web/src/app/(dashboard)/wireframes/studio-projects-kv-generator/studio/page.tsx`

```tsx
"use client";

import { useState } from "react";
import Link from "next/link";
import { BaseLayout } from "@/components/frndos/layout/BaseLayout";
import { ProjectCardMock } from "./components/ProjectCardMock";

const MOCK_PROJECTS = [
  { id: "p1", name: "CIMB × XG Xtra Nabung", subtitle: "Updated today" },
  { id: "p2", name: "Panadol Collaboration", subtitle: "Updated yesterday" },
];

const TOOL_TILES = [
  { slug: "kv-generator", name: "KV Generator", desc: "Generate brand-safe key visuals" },
  { slug: "image-editor", name: "Image Editor", desc: "Canvas editing with mask + text" },
  { slug: "resizer", name: "Resizer", desc: "Resize to all ad platforms" },
];

export default function StudioWireframe() {
  const [populated, setPopulated] = useState(false);

  return (
    <BaseLayout>
      <div className="mx-auto w-full max-w-6xl px-8 py-10">
        <div className="mb-6 flex items-center gap-3">
          <h2 className="text-lg font-semibold">Projects</h2>
          <button
            className="rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-300 hover:bg-white/5"
            onClick={() => setPopulated((p) => !p)}
          >
            {populated ? "Show empty" : "Show populated"}
          </button>
        </div>

        {populated ? (
          <div className="flex gap-4 overflow-x-auto pb-4">
            <Link
              href="/wireframes/studio-projects-kv-generator/studio/projects/new"
              className="flex h-[150px] w-[210px] shrink-0 items-center justify-center rounded-xl border border-dashed border-white/20 text-neutral-400 hover:border-white/40"
            >
              + New Project
            </Link>
            {MOCK_PROJECTS.map((p) => (
              <ProjectCardMock key={p.id} {...p} />
            ))}
          </div>
        ) : (
          <div className="flex flex-col items-center justify-center py-20 text-center">
            <div className="text-5xl text-neutral-600">📁</div>
            <h3 className="mt-4 text-lg font-medium text-white">
              No Studio projects yet
            </h3>
            <p className="mt-1 max-w-md text-sm text-neutral-400">
              Create a Project to group KV visuals, image edits, and resizes with a
              shared brief.
            </p>
            <Link
              href="/wireframes/studio-projects-kv-generator/studio/projects/new"
              className="mt-6 rounded-full bg-white px-5 py-2 text-sm font-medium text-black hover:bg-white/90"
            >
              New Project
            </Link>
          </div>
        )}

        <section className="mt-16">
          <h2 className="text-lg font-semibold">All Tools</h2>
          <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-3">
            {TOOL_TILES.map((tile) => (
              <div
                key={tile.slug}
                className="rounded-xl border border-white/10 bg-neutral-900 p-4"
              >
                <p className="font-medium">{tile.name}</p>
                <p className="mt-1 text-xs text-neutral-400">{tile.desc}</p>
              </div>
            ))}
          </div>
        </section>
      </div>
    </BaseLayout>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test .../studio/page.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(dashboard\)/wireframes/studio-projects-kv-generator/studio/
git commit -m "feat(web): add studio wireframe home with projects empty/populated states"
```

---

## Task 3 — Wireframe: New Project modal + Project detail + KV canvas (all states)

**Files:**
- Create: `.../studio/projects/new/page.tsx`
- Create: `.../studio/projects/[id]/page.tsx`
- Create: `.../studio/projects/[id]/kv-generator/page.tsx`
- Create: shared mock components inside `studio/components/`

- [ ] **Step 1: Write the failing tests**

File: `.../studio/projects/[id]/page.test.tsx`

```tsx
import { render, screen, fireEvent } from "@testing-library/react";
import ProjectDetailWireframe from "./page";

it("renders project title, empty files state, and settings rail", () => {
  render(<ProjectDetailWireframe params={{ id: "p1" }} />);
  expect(screen.getByText(/CIMB × XG/i)).toBeInTheDocument();
  expect(screen.getByText(/Use Brand Knowledge/i)).toBeInTheDocument();
  expect(screen.getByText(/Create New/i)).toBeInTheDocument();
});

it("toggles to populated files state", () => {
  render(<ProjectDetailWireframe params={{ id: "p1" }} />);
  fireEvent.click(screen.getByRole("button", { name: /toggle files/i }));
  expect(screen.getByText(/Version 1/i)).toBeInTheDocument();
});
```

File: `.../studio/projects/[id]/kv-generator/page.test.tsx`

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import KvCanvasWireframe from "./page";

it("shows the canvas chrome and the chat input with mode dropdown", () => {
  render(<KvCanvasWireframe />);
  expect(screen.getByPlaceholderText(/What do you want to ask/i)).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /chat/i })).toBeInTheDocument();
});

it("cycles through streaming states via dev toggle", () => {
  render(<KvCanvasWireframe />);
  fireEvent.click(screen.getByRole("button", { name: /next state/i }));
  expect(screen.getByText(/thinking/i)).toBeInTheDocument();
});

it("renders a question card state", () => {
  render(<KvCanvasWireframe />);
  fireEvent.click(screen.getByRole("button", { name: /question card/i }));
  expect(screen.getByText(/Pick an aspect/i)).toBeInTheDocument();
});

it("renders a mode suggestion state", () => {
  render(<KvCanvasWireframe />);
  fireEvent.click(screen.getByRole("button", { name: /mode suggestion/i }));
  expect(screen.getByText(/Start generating/i)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bun test .../studio/projects`
Expected: FAIL — pages missing.

- [ ] **Step 3: Create the three pages + mock components**

File: `.../studio/projects/new/page.tsx`

```tsx
"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export default function NewProjectWireframe() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div className="w-full max-w-[600px] rounded-2xl border border-white/10 bg-neutral-900 p-6">
        <h2 className="text-xl font-semibold">New Project</h2>

        <div className="mt-4 space-y-3">
          <input
            aria-label="Project name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Name"
            className="w-full rounded-lg border border-white/10 bg-neutral-800 px-3 py-2 text-sm"
          />
          <textarea
            aria-label="Project description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Describe the brief"
            className="h-40 w-full rounded-lg border border-white/10 bg-neutral-800 px-3 py-2 text-sm"
          />
        </div>

        <div className="mt-6 flex justify-end gap-2">
          <button
            onClick={() => router.back()}
            className="rounded-full border border-white/10 px-4 py-2 text-sm"
          >
            Cancel
          </button>
          <button
            onClick={() =>
              router.push(
                "/wireframes/studio-projects-kv-generator/studio/projects/p1",
              )
            }
            className="rounded-full bg-white px-4 py-2 text-sm text-black"
          >
            Create Project
          </button>
        </div>
      </div>
    </div>
  );
}
```

File: `.../studio/projects/[id]/page.tsx`

```tsx
"use client";

import { useState } from "react";
import Link from "next/link";
import { BaseLayout } from "@/components/frndos/layout/BaseLayout";

export default function ProjectDetailWireframe({
  params,
}: {
  params: { id: string };
}) {
  const [description, setDescription] = useState(
    "Savings campaign for Gen Z audience with upbeat tone.",
  );
  const [useBrandKnowledge, setUseBrandKnowledge] = useState(true);
  const [hasFiles, setHasFiles] = useState(false);

  return (
    <BaseLayout>
      <div className="mx-auto grid w-full max-w-6xl grid-cols-[1fr_328px] gap-6 px-8 py-10">
        <div>
          <div className="mb-6 flex items-center gap-3">
            <Link
              href="/wireframes/studio-projects-kv-generator/studio"
              className="text-neutral-400 hover:text-white"
            >
              ←
            </Link>
            <h1 className="text-2xl font-semibold">CIMB × XG Xtra Nabung</h1>
            <button
              aria-label="Toggle files"
              className="ml-auto rounded-full border border-white/10 px-3 py-1 text-xs"
              onClick={() => setHasFiles((v) => !v)}
            >
              Toggle files
            </button>
          </div>

          {hasFiles ? (
            <div className="grid grid-cols-3 gap-4">
              {[1, 2, 3, 4].map((n) => (
                <div
                  key={n}
                  className="aspect-square rounded-xl bg-neutral-800 p-4 text-sm text-neutral-400"
                >
                  Version {n}
                </div>
              ))}
            </div>
          ) : (
            <div className="flex flex-col items-center justify-center py-24 text-center">
              <div className="text-5xl text-neutral-600">🖼️</div>
              <p className="mt-4 text-neutral-300">No files yet in this project</p>
              <Link
                href={`/wireframes/studio-projects-kv-generator/studio/projects/${params.id}/kv-generator`}
                className="mt-6 rounded-full bg-white px-5 py-2 text-sm text-black"
              >
                Create New
              </Link>
            </div>
          )}
        </div>

        <aside className="flex flex-col gap-6 rounded-2xl border border-white/10 bg-neutral-900 p-4">
          <div>
            <label className="text-sm font-medium">Description</label>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="mt-2 h-36 w-full rounded-lg border border-white/10 bg-neutral-800 p-2 text-sm"
            />
          </div>

          <div className="flex items-start justify-between">
            <div>
              <p className="text-sm font-medium">Use Brand Knowledge</p>
              <p className="mt-1 text-xs text-neutral-400">
                Include this brand&apos;s DNA, identity, and tonality as context for KV
                Gen.
              </p>
            </div>
            <button
              role="switch"
              aria-checked={useBrandKnowledge}
              onClick={() => setUseBrandKnowledge((v) => !v)}
              className={`h-6 w-10 rounded-full transition-colors ${
                useBrandKnowledge ? "bg-white" : "bg-neutral-700"
              }`}
            />
          </div>
        </aside>
      </div>
    </BaseLayout>
  );
}
```

File: `.../studio/projects/[id]/kv-generator/page.tsx`

```tsx
"use client";

import { useState } from "react";

type State =
  | "empty"
  | "thinking"
  | "question_card"
  | "mode_suggestion"
  | "generating"
  | "version_ready";

const ORDER: State[] = [
  "empty",
  "thinking",
  "question_card",
  "mode_suggestion",
  "generating",
  "version_ready",
];

export default function KvCanvasWireframe() {
  const [state, setState] = useState<State>("empty");
  const next = () => setState(ORDER[(ORDER.indexOf(state) + 1) % ORDER.length]);

  return (
    <div className="flex h-screen w-screen bg-black text-white">
      {/* Canvas */}
      <div className="flex flex-1 flex-col border-r border-white/10">
        <div className="flex items-center justify-between border-b border-white/10 px-6 py-4">
          <span className="text-sm text-neutral-400">← Back to CIMB × XG</span>
          <div className="flex gap-2">
            <button
              onClick={next}
              className="rounded-full border border-white/10 px-3 py-1 text-xs"
            >
              Next state
            </button>
            <button
              onClick={() => setState("question_card")}
              className="rounded-full border border-white/10 px-3 py-1 text-xs"
            >
              Question card
            </button>
            <button
              onClick={() => setState("mode_suggestion")}
              className="rounded-full border border-white/10 px-3 py-1 text-xs"
            >
              Mode suggestion
            </button>
          </div>
        </div>

        <div className="flex flex-1 items-center justify-center p-10">
          {state === "empty" && (
            <p className="max-w-md text-center text-neutral-400">
              Keep chatting to shape the brief, or switch to Image mode to generate
              your first KV.
            </p>
          )}
          {state === "generating" && (
            <div className="h-80 w-[600px] animate-pulse rounded-xl bg-neutral-800" />
          )}
          {state === "version_ready" && (
            <div className="flex h-80 w-[600px] items-center justify-center rounded-xl bg-neutral-700 text-sm">
              Generated KV — Version 1 (just now)
            </div>
          )}
        </div>
      </div>

      {/* Chat */}
      <div className="flex w-[468px] flex-col">
        <div className="border-b border-white/10 px-6 py-4">
          <h2 className="text-sm font-medium">CIMB × XG Savings Campaign</h2>
        </div>

        <div className="flex-1 overflow-y-auto p-6 text-sm">
          {state === "thinking" && (
            <p className="text-neutral-400">thinking about the brief…</p>
          )}
          {state === "question_card" && (
            <div className="space-y-2 rounded-xl border border-white/10 bg-neutral-900 p-4">
              <p className="font-medium">Pick an aspect ratio</p>
              <div className="flex flex-wrap gap-2">
                {["1:1", "16:9", "9:16"].map((opt) => (
                  <button
                    key={opt}
                    className="rounded-full border border-white/10 px-3 py-1 text-xs"
                  >
                    {opt}
                  </button>
                ))}
              </div>
            </div>
          )}
          {state === "mode_suggestion" && (
            <div className="rounded-xl border border-white/10 bg-neutral-900 p-4">
              <p className="text-sm">
                You&apos;ve got a clear direction — want me to start generating?
              </p>
              <div className="mt-3 flex gap-2">
                <button className="rounded-full bg-white px-3 py-1 text-xs text-black">
                  Start generating
                </button>
                <button className="rounded-full border border-white/10 px-3 py-1 text-xs">
                  Keep chatting
                </button>
              </div>
            </div>
          )}
        </div>

        <div className="border-t border-white/10 p-4">
          <textarea
            placeholder="What do you want to ask…"
            className="h-16 w-full resize-none rounded-xl border border-white/10 bg-neutral-900 p-3 text-sm"
          />
          <div className="mt-2 flex items-center gap-2 text-xs text-neutral-300">
            <button aria-label="Attach" className="px-2">+</button>
            <button
              className="rounded-full border border-white/10 px-3 py-1"
              role="button"
              name="Chat mode"
            >
              Chat ▾
            </button>
            <button className="rounded-full border border-white/10 px-3 py-1">
              Style
            </button>
            <div className="ml-auto rounded-full bg-white px-3 py-1 text-black">↑ Send</div>
          </div>
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test .../studio/projects`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(dashboard\)/wireframes/studio-projects-kv-generator/
git commit -m "feat(web): add project detail + KV canvas wireframes with all streaming states"
```

**Ship the wireframe to develop and get Jeff's approval (per the workflow phase gate) before proceeding to Task 4+.**

---

## Task 4 — Types: rename `StudioProject` → `StudioFile`; add folder type

**Files:**
- Modify: `web/src/types/studio.ts`

- [ ] **Step 1: Write the failing test**

File: `web/src/types/studio.test.ts`

```ts
import type { StudioFile, StudioProject, KvGeneration } from "./studio";

it("types compile", () => {
  const f: StudioFile = {
    id: "1", name: "n", status: "draft", thumbnail_url: null,
    tool: { id: "t", name: "KV", slug: "kv-generator" },
    last_edited_by: { id: "u", name: "u" },
    last_edited_at: "2026-04-23T00:00:00Z",
    created_by: { id: "u", name: "u" },
    created_at: "2026-04-23T00:00:00Z",
    project_id: null, thread_id: null,
  };
  const p: StudioProject = {
    id: "p", name: "N", description: null, use_brand_knowledge: false,
    brand_id: "b", thumbnail_url: null, files_count: 0,
    last_edited_at: "2026-04-23T00:00:00Z", created_at: "2026-04-23T00:00:00Z",
  };
  const g: KvGeneration = {
    id: "g", studio_file_id: "f", version_number: 1,
    image_url: "u", thumbnail_url: null, prompt_snapshot: "p", model: "m",
    parent_generation_id: null, metadata: null, created_at: "2026-04-23T00:00:00Z",
  };
  expect(f).toBeDefined();
  expect(p).toBeDefined();
  expect(g).toBeDefined();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/types/studio.test.ts`
Expected: FAIL — types don't exist yet.

- [ ] **Step 3: Modify types**

Edit: `web/src/types/studio.ts`:

1. Rename the existing `StudioProject` type (file-shaped) to `StudioFile`:

```ts
export type StudioFile = {
  id: string;
  name: string;
  status: StudioProjectStatusType;
  thumbnail_url: string | null;
  tool: StudioProjectTool;
  last_edited_by: StudioProjectUser;
  last_edited_at: string;
  created_by: StudioProjectUser;
  created_at: string;
  project_id: string | null;
  thread_id: string | null;
};
```

2. Add new `StudioProject` (folder):

```ts
export type StudioProject = {
  id: string;
  name: string;
  description: string | null;
  use_brand_knowledge: boolean;
  brand_id: string;
  thumbnail_url: string | null;
  files_count: number;
  last_edited_at: string;
  created_at: string;
};
```

3. Add `KvGeneration`:

```ts
export type KvGeneration = {
  id: string;
  studio_file_id: string;
  version_number: number;
  image_url: string;
  thumbnail_url: string | null;
  prompt_snapshot: string;
  model: string;
  parent_generation_id: string | null;
  metadata: Record<string, unknown> | null;
  created_at: string;
};
```

4. Add `StudioProjectsParams` and any collection shapes needed.

- [ ] **Step 4: Update every import that referenced the old `StudioProject` (file-shaped)**

Run:
```bash
cd web
grep -rln "StudioProject" src | xargs grep -l "tool" | # inspect each
```

Points of interest (repoint to `StudioFile`):
- `web/src/hooks/useStudioGallery.ts` — change return type from `StudioProject[]` to `StudioFile[]`
- `web/src/services/query.ts` — any `getStudioProjects(...)` call that returned file shape → update generic
- `web/src/app/(dashboard)/studio/all-files/page.tsx` — uses old `StudioProject` for listing; ensure still compiles

For each import:
```ts
// BEFORE
import type { StudioProject } from "@/types/studio";
const data: { data: StudioProject[] } = ...

// AFTER
import type { StudioFile } from "@/types/studio";
const data: { data: StudioFile[] } = ...
```

The new `StudioProject` type (folder) is introduced fresh; nothing existing used it.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd web && bun test src/types/studio.test.ts && bunx tsc --noEmit`
Expected: PASS and no TS errors.

- [ ] **Step 6: Commit**

```bash
cd web
git add src/types/studio.ts src/types/studio.test.ts
git add -u src
git commit -m "feat(web): rename StudioProject→StudioFile; add folder + KvGeneration types"
```

---

## Task 5 — Query + mutate services for projects, files, KV

**Files:**
- Modify: `web/src/services/query.ts`
- Modify: `web/src/services/mutate.ts`

- [ ] **Step 1: Write the failing test**

File: `web/src/services/studio-project-queries.test.ts`

```ts
import { getStudioFolderProjects, getStudioProject } from "./query";

it("exports studio folder query functions", () => {
  expect(typeof getStudioFolderProjects).toBe("function");
  expect(typeof getStudioProject).toBe("function");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/services/studio-project-queries.test.ts`
Expected: FAIL.

- [ ] **Step 3: Add query functions**

Edit: `web/src/services/query.ts` — add (match the existing API client pattern in this file):

```ts
import type {
  KvGeneration,
  PaginationMeta,
  StudioFile,
  StudioProject,
} from "@/types/studio";

export async function getStudioFolderProjects(params: {
  brandId?: string;
  search?: string;
  page?: number;
  limit?: number;
}): Promise<{ data: StudioProject[]; meta: PaginationMeta }> {
  const search = new URLSearchParams();
  if (params.brandId) search.set("brand_id", params.brandId);
  if (params.search) search.set("search", params.search);
  if (params.page) search.set("page", String(params.page));
  if (params.limit) search.set("limit", String(params.limit));
  return apiGet(`/api/studio/projects?${search}`);
}

export async function getStudioProject(id: string): Promise<{ data: StudioProject }> {
  return apiGet(`/api/studio/projects/${id}`);
}

export async function getStudioProjectFiles(
  projectId: string,
  params: { page?: number; limit?: number; toolSlug?: string },
): Promise<{ data: StudioFile[]; meta: PaginationMeta }> {
  const search = new URLSearchParams();
  if (params.page) search.set("page", String(params.page));
  if (params.limit) search.set("limit", String(params.limit));
  if (params.toolSlug) search.set("tool_slug", params.toolSlug);
  return apiGet(`/api/studio/projects/${projectId}/files?${search}`);
}

export async function getKvFile(id: string): Promise<{
  data: StudioFile & { generations: KvGeneration[] };
}> {
  return apiGet(`/api/studio/kv-generator/files/${id}`);
}

export async function getKvGenerations(
  fileId: string,
  params: { page?: number; limit?: number },
): Promise<{ data: KvGeneration[]; meta: PaginationMeta }> {
  const search = new URLSearchParams();
  if (params.page) search.set("page", String(params.page));
  if (params.limit) search.set("limit", String(params.limit));
  return apiGet(`/api/studio/kv-generator/files/${fileId}/generations?${search}`);
}
```

(`apiGet` is the existing fetch wrapper in this file. Use it verbatim — don't introduce a new client.)

Edit: `web/src/services/mutate.ts` — add:

```ts
import type { StudioFile, StudioProject } from "@/types/studio";

export async function createStudioProject(body: {
  name: string;
  description?: string;
  brand_id: string;
  use_brand_knowledge?: boolean;
}): Promise<{ data: StudioProject }> {
  return apiPost(`/api/studio/projects`, body);
}

export async function updateStudioProject(
  id: string,
  body: Partial<Pick<StudioProject, "name" | "description" | "use_brand_knowledge">>,
): Promise<{ data: StudioProject }> {
  return apiPatch(`/api/studio/projects/${id}`, body);
}

export async function deleteStudioProject(id: string): Promise<void> {
  return apiDelete(`/api/studio/projects/${id}`);
}

export async function moveStudioFile(
  id: string,
  projectId: string | null,
): Promise<{ data: StudioFile }> {
  return apiPatch(`/api/studio/files/${id}/move`, { project_id: projectId });
}

export async function createKvFile(body: {
  project_id?: string;
  initial_prompt?: string;
  brand_id: string;
}): Promise<{ data: StudioFile }> {
  return apiPost(`/api/studio/kv-generator/files`, body);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/services/studio-project-queries.test.ts && bunx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/services/query.ts src/services/mutate.ts src/services/studio-project-queries.test.ts
git commit -m "feat(web): add studio projects + KV file services"
```

---

## Task 6 — Hooks: `useStudioProjects` + `useStudioProject` + `useStudioProjectFiles`

**Files:**
- Create: `web/src/hooks/useStudioProjects.ts`
- Create: `web/src/hooks/useStudioProject.ts`
- Create: `web/src/hooks/useStudioProjectFiles.ts`

- [ ] **Step 1: Write the failing tests**

File: `web/src/hooks/useStudioProjects.test.ts`

```ts
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useStudioProjects } from "./useStudioProjects";

it("queries the projects endpoint with brand and search filters", async () => {
  const qc = new QueryClient();
  const wrapper = ({ children }: any) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  );

  const { result } = renderHook(
    () => useStudioProjects({ workspaceId: "w1", brandId: "b1" }),
    { wrapper },
  );

  await waitFor(() => expect(result.current.isSuccess || result.current.isError).toBe(true));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/hooks/useStudioProjects.test.ts`
Expected: FAIL.

- [ ] **Step 3: Create hooks**

File: `web/src/hooks/useStudioProjects.ts`

```ts
import { useQuery } from "@tanstack/react-query";
import { getStudioFolderProjects } from "@/services/query";

export function useStudioProjects(params: {
  workspaceId: string | undefined;
  brandId: string | undefined;
  search?: string;
  page?: number;
  limit?: number;
}) {
  return useQuery({
    queryKey: ["studio", "folder-projects", params],
    queryFn: () =>
      getStudioFolderProjects({
        brandId: params.brandId,
        search: params.search,
        page: params.page,
        limit: params.limit,
      }),
    enabled: !!params.workspaceId && !!params.brandId,
  });
}
```

File: `web/src/hooks/useStudioProject.ts`

```ts
import { useQuery } from "@tanstack/react-query";
import { getStudioProject } from "@/services/query";

export function useStudioProject(id: string | undefined) {
  return useQuery({
    queryKey: ["studio", "folder-project", id],
    queryFn: () => getStudioProject(id!),
    enabled: !!id,
  });
}
```

File: `web/src/hooks/useStudioProjectFiles.ts`

```ts
import { useQuery } from "@tanstack/react-query";
import { getStudioProjectFiles } from "@/services/query";

export function useStudioProjectFiles(
  projectId: string | undefined,
  params: { page?: number; limit?: number; toolSlug?: string } = {},
) {
  return useQuery({
    queryKey: ["studio", "folder-project-files", projectId, params],
    queryFn: () => getStudioProjectFiles(projectId!, params),
    enabled: !!projectId,
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/hooks/useStudioProjects.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/hooks/useStudioProjects.ts src/hooks/useStudioProject.ts \
       src/hooks/useStudioProjectFiles.ts src/hooks/useStudioProjects.test.ts
git commit -m "feat(web): add studio project data hooks"
```

---

## Task 7 — `StudioProjectsSection` on Studio home (feature-flagged)

**Files:**
- Create: `web/src/components/studio/projects/StudioProjectsSection.tsx`
- Create: `web/src/components/studio/projects/ProjectCard.tsx`
- Modify: `web/src/app/(dashboard)/studio/Studiofrndos.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/components/studio/projects/StudioProjectsSection.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StudioProjectsSection } from "./StudioProjectsSection";

it("renders empty state", () => {
  const qc = new QueryClient();
  render(
    <QueryClientProvider client={qc}>
      <StudioProjectsSection
        workspaceId="w1"
        brandId="b1"
        projectsOverride={[]}
      />
    </QueryClientProvider>,
  );
  expect(screen.getByText(/No Studio projects yet/i)).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /new project/i })).toBeInTheDocument();
});

it("renders cards when projects exist", () => {
  const qc = new QueryClient();
  render(
    <QueryClientProvider client={qc}>
      <StudioProjectsSection
        workspaceId="w1"
        brandId="b1"
        projectsOverride={[
          {
            id: "p1", name: "CIMB × XG", description: null,
            use_brand_knowledge: false, brand_id: "b1", thumbnail_url: null,
            files_count: 2,
            last_edited_at: "2026-04-23T00:00:00Z",
            created_at: "2026-04-23T00:00:00Z",
          },
        ]}
      />
    </QueryClientProvider>,
  );
  expect(screen.getByText(/CIMB × XG/i)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/projects/StudioProjectsSection.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create the components**

File: `web/src/components/studio/projects/ProjectCard.tsx`

```tsx
"use client";

import Link from "next/link";
import type { StudioProject } from "@/types/studio";

export function ProjectCard({ project }: { project: StudioProject }) {
  return (
    <Link
      href={`/studio/projects/${project.id}`}
      className="group block w-[210px] shrink-0"
    >
      <div className="h-[150px] w-full overflow-hidden rounded-xl border border-white/10 bg-neutral-800 transition-colors group-hover:border-white/20">
        {project.thumbnail_url ? (
          <img
            src={project.thumbnail_url}
            alt={project.name}
            className="h-full w-full object-cover"
          />
        ) : (
          <div className="flex h-full w-full items-center justify-center p-4 text-center text-sm text-neutral-500">
            {project.name}
          </div>
        )}
      </div>
      <div className="mt-3">
        <p className="text-sm font-medium text-white">{project.name}</p>
        <p className="text-xs text-neutral-400">
          {project.files_count} {project.files_count === 1 ? "file" : "files"}
        </p>
      </div>
    </Link>
  );
}
```

File: `web/src/components/studio/projects/StudioProjectsSection.tsx`

```tsx
"use client";

import Link from "next/link";
import { useStudioProjects } from "@/hooks/useStudioProjects";
import { ProjectCard } from "./ProjectCard";
import type { StudioProject } from "@/types/studio";

type Props = {
  workspaceId: string | undefined;
  brandId: string | undefined;
  projectsOverride?: StudioProject[];  // test-only
};

export function StudioProjectsSection({ workspaceId, brandId, projectsOverride }: Props) {
  const query = useStudioProjects({ workspaceId, brandId });
  const projects = projectsOverride ?? query.data?.data ?? [];

  if (projects.length === 0) {
    return (
      <section>
        <h2 className="text-lg font-semibold">Projects</h2>
        <div className="mt-6 flex flex-col items-center justify-center py-16 text-center">
          <div className="text-5xl text-neutral-600">📁</div>
          <h3 className="mt-4 text-lg font-medium text-white">
            No Studio projects yet
          </h3>
          <p className="mt-1 max-w-md text-sm text-neutral-400">
            Create a Project to group KV visuals, image edits, and resizes with a
            shared brief.
          </p>
          <Link
            href="/studio/projects/new"
            className="mt-6 rounded-full bg-white px-5 py-2 text-sm font-medium text-black"
            role="button"
          >
            New Project
          </Link>
        </div>
      </section>
    );
  }

  return (
    <section>
      <h2 className="text-lg font-semibold">Projects</h2>
      <div className="mt-6 flex gap-4 overflow-x-auto pb-4">
        <Link
          href="/studio/projects/new"
          className="flex h-[150px] w-[210px] shrink-0 items-center justify-center rounded-xl border border-dashed border-white/20 text-neutral-400 hover:border-white/40"
        >
          + New Project
        </Link>
        {projects.map((p) => (
          <ProjectCard key={p.id} project={p} />
        ))}
      </div>
    </section>
  );
}
```

- [ ] **Step 4: Wire into `Studiofrndos.tsx` behind feature flag**

Edit: `web/src/app/(dashboard)/studio/Studiofrndos.tsx` — find the existing "No Studio projects yet" placeholder section and replace it with:

```tsx
import { StudioProjectsSection } from "@/components/studio/projects/StudioProjectsSection";

const projectsEnabled = process.env.NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED === "true";

{projectsEnabled && (
  <StudioProjectsSection
    workspaceId={currentWorkspace?.id}
    brandId={currentBrandId}
  />
)}
```

(Keep the existing "All Tools" section unchanged below.)

Edit: `web/.env.example` — add `NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED=false`.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/projects/StudioProjectsSection.test.tsx`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd web
git add src/components/studio/projects/ src/app/\(dashboard\)/studio/Studiofrndos.tsx .env.example
git commit -m "feat(web): add StudioProjectsSection with feature flag wiring"
```

---

## Task 8 — New Project intercepting modal

**Files:**
- Create: `web/src/app/(dashboard)/studio/projects/new/page.tsx`
- Create: `web/src/components/studio/projects/NewProjectModal.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/components/studio/projects/NewProjectModal.test.tsx`

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { NewProjectModal } from "./NewProjectModal";

it("submits form with name + description to the create mutation", async () => {
  const onCreate = jest.fn().mockResolvedValue({ data: { id: "p1" } });
  const qc = new QueryClient();
  render(
    <QueryClientProvider client={qc}>
      <NewProjectModal
        brandId="b1"
        onCreate={onCreate}
        onClose={() => {}}
      />
    </QueryClientProvider>,
  );

  fireEvent.change(screen.getByLabelText(/name/i), { target: { value: "Test" } });
  fireEvent.change(screen.getByLabelText(/description/i), { target: { value: "A brief" } });
  fireEvent.click(screen.getByRole("button", { name: /create project/i }));

  expect(onCreate).toHaveBeenCalledWith({
    name: "Test",
    description: "A brief",
    brand_id: "b1",
  });
});

it("blocks submit with empty name", () => {
  const onCreate = jest.fn();
  render(
    <NewProjectModal brandId="b1" onCreate={onCreate} onClose={() => {}} />,
  );
  fireEvent.click(screen.getByRole("button", { name: /create project/i }));
  expect(onCreate).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/projects/NewProjectModal.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create the components**

File: `web/src/components/studio/projects/NewProjectModal.tsx`

```tsx
"use client";

import { useState } from "react";
import { BaseModal } from "@/components/frndos/BaseModal";
import { Input } from "@/components/frndos/Input";
import { Button } from "@/components/frndos/Button";

export type NewProjectInput = {
  name: string;
  description?: string;
  brand_id: string;
};

type Props = {
  brandId: string;
  onClose: () => void;
  onCreate: (data: NewProjectInput) => Promise<{ data: { id: string } }>;
};

export function NewProjectModal({ brandId, onClose, onCreate }: Props) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    if (name.trim().length === 0) {
      setError("Name is required");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      await onCreate({ name, description: description || undefined, brand_id: brandId });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <BaseModal onClose={onClose} size="lg">
      <div className="p-6">
        <h2 className="text-xl font-semibold">New Project</h2>

        <div className="mt-4 space-y-3">
          <Input
            aria-label="Name"
            placeholder="Project name"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <label className="block">
            <span className="sr-only">Description</span>
            <textarea
              aria-label="Description"
              placeholder="Describe the brief"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="h-40 w-full rounded-lg border border-white/10 bg-neutral-800 px-3 py-2 text-sm"
            />
          </label>
          {error && <p className="text-sm text-red-400">{error}</p>}
        </div>

        <div className="mt-6 flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>Cancel</Button>
          <Button onClick={submit} disabled={submitting}>
            {submitting ? "Creating…" : "Create Project"}
          </Button>
        </div>
      </div>
    </BaseModal>
  );
}
```

File: `web/src/app/(dashboard)/studio/projects/new/page.tsx`

```tsx
"use client";

import { useRouter } from "next/navigation";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/context/AuthContext";
import { createStudioProject } from "@/services/mutate";
import { NewProjectModal, type NewProjectInput } from "@/components/studio/projects/NewProjectModal";

export default function NewProjectPage() {
  const router = useRouter();
  const qc = useQueryClient();
  const authContext = useAuth();
  const brandId = (authContext?.user as any)?.current_brand_id;

  const mutation = useMutation({
    mutationFn: (body: NewProjectInput) => createStudioProject(body),
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: ["studio", "folder-projects"] });
      router.push(`/studio/projects/${res.data.id}`);
    },
  });

  return (
    <NewProjectModal
      brandId={brandId}
      onClose={() => router.back()}
      onCreate={async (body) => await mutation.mutateAsync(body)}
    />
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/projects/NewProjectModal.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(dashboard\)/studio/projects/new/ src/components/studio/projects/NewProjectModal.tsx \
       src/components/studio/projects/NewProjectModal.test.tsx
git commit -m "feat(web): add New Project modal route"
```

---

## Task 9 — Project detail page with settings rail (autosave)

**Files:**
- Create: `web/src/app/(dashboard)/studio/projects/[id]/page.tsx`
- Create: `web/src/components/studio/projects/ProjectDetailLayout.tsx`
- Create: `web/src/components/studio/projects/ProjectSettingsRail.tsx`
- Create: `web/src/components/studio/projects/FileCard.tsx`
- Create: `web/src/components/studio/projects/FileEmptyState.tsx`

- [ ] **Step 1: Write the failing tests**

File: `web/src/components/studio/projects/ProjectSettingsRail.test.tsx`

```tsx
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { ProjectSettingsRail } from "./ProjectSettingsRail";

it("calls onUpdate with debounced changes", async () => {
  jest.useFakeTimers();
  const onUpdate = jest.fn();
  render(
    <ProjectSettingsRail
      description="initial"
      useBrandKnowledge={false}
      onUpdate={onUpdate}
    />,
  );
  fireEvent.change(screen.getByLabelText(/description/i), { target: { value: "changed" } });
  await act(async () => { jest.advanceTimersByTime(500); });
  expect(onUpdate).toHaveBeenCalledWith({ description: "changed" });
});

it("toggles use_brand_knowledge", () => {
  const onUpdate = jest.fn();
  render(
    <ProjectSettingsRail
      description=""
      useBrandKnowledge={false}
      onUpdate={onUpdate}
    />,
  );
  fireEvent.click(screen.getByRole("switch"));
  expect(onUpdate).toHaveBeenCalledWith({ use_brand_knowledge: true });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/projects/ProjectSettingsRail.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create components**

File: `web/src/components/studio/projects/ProjectSettingsRail.tsx`

```tsx
"use client";

import { useEffect, useRef, useState } from "react";
import { Toggle } from "@/components/frndos/Toggle";

type Props = {
  description: string;
  useBrandKnowledge: boolean;
  onUpdate: (patch: { description?: string; use_brand_knowledge?: boolean }) => void;
};

export function ProjectSettingsRail({ description: initial, useBrandKnowledge, onUpdate }: Props) {
  const [description, setDescription] = useState(initial);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => setDescription(initial), [initial]);

  const onDescriptionChange = (v: string) => {
    setDescription(v);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      if (v !== initial) onUpdate({ description: v });
    }, 500);
  };

  return (
    <aside className="flex flex-col gap-6 rounded-2xl border border-white/10 bg-neutral-900 p-4">
      <div>
        <label className="text-sm font-medium" htmlFor="proj-desc">Description</label>
        <textarea
          id="proj-desc"
          aria-label="Description"
          value={description}
          onChange={(e) => onDescriptionChange(e.target.value)}
          className="mt-2 h-36 w-full rounded-lg border border-white/10 bg-neutral-800 p-2 text-sm"
        />
      </div>

      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm font-medium">Use Brand Knowledge</p>
          <p className="mt-1 text-xs text-neutral-400">
            Include this brand&apos;s DNA, identity, and tonality as context for KV Gen.
          </p>
        </div>
        <Toggle
          checked={useBrandKnowledge}
          onChange={(v) => onUpdate({ use_brand_knowledge: v })}
        />
      </div>
    </aside>
  );
}
```

File: `web/src/components/studio/projects/FileCard.tsx`

```tsx
"use client";

import Link from "next/link";
import type { StudioFile } from "@/types/studio";

const ROUTES: Record<string, (id: string) => string> = {
  "kv-generator": (id) => `/studio/kv-generator/${id}`,
  "image-editor": (id) => `/studio/image-editor?file_id=${id}`,
  "resizer": (id) => `/studio/resizer?file_id=${id}`,
};

export function FileCard({ file }: { file: StudioFile }) {
  const href = (ROUTES[file.tool.slug] ?? ((id) => `/studio/all-files#${id}`))(file.id);
  return (
    <Link
      href={href}
      className="group block overflow-hidden rounded-xl border border-white/10 bg-neutral-800"
    >
      <div className="aspect-square w-full bg-neutral-700">
        {file.thumbnail_url && (
          <img src={file.thumbnail_url} alt={file.name} className="h-full w-full object-cover" />
        )}
      </div>
      <div className="p-3">
        <p className="truncate text-sm font-medium">{file.name}</p>
        <p className="text-xs text-neutral-400">{file.tool.name}</p>
      </div>
    </Link>
  );
}
```

File: `web/src/components/studio/projects/FileEmptyState.tsx`

```tsx
"use client";

import Link from "next/link";

export function FileEmptyState({ projectId }: { projectId: string }) {
  return (
    <div className="flex flex-col items-center justify-center py-24 text-center">
      <div className="text-5xl text-neutral-600">🖼️</div>
      <p className="mt-4 text-neutral-300">No files yet in this project</p>
      <Link
        href={`/studio/kv-generator/new?project_id=${projectId}`}
        className="mt-6 rounded-full bg-white px-5 py-2 text-sm text-black"
        role="button"
      >
        Create New
      </Link>
    </div>
  );
}
```

File: `web/src/app/(dashboard)/studio/projects/[id]/page.tsx`

```tsx
"use client";

import { useMutation, useQueryClient } from "@tanstack/react-query";
import Link from "next/link";
import { useStudioProject } from "@/hooks/useStudioProject";
import { useStudioProjectFiles } from "@/hooks/useStudioProjectFiles";
import { updateStudioProject } from "@/services/mutate";
import { BaseLayout } from "@/components/frndos/layout/BaseLayout";
import { FileCard } from "@/components/studio/projects/FileCard";
import { FileEmptyState } from "@/components/studio/projects/FileEmptyState";
import { ProjectSettingsRail } from "@/components/studio/projects/ProjectSettingsRail";

export default function ProjectDetailPage({ params }: { params: { id: string } }) {
  const project = useStudioProject(params.id);
  const files = useStudioProjectFiles(params.id, { limit: 24 });
  const qc = useQueryClient();

  const mutation = useMutation({
    mutationFn: (patch: Parameters<typeof updateStudioProject>[1]) =>
      updateStudioProject(params.id, patch),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["studio", "folder-project", params.id] });
    },
  });

  if (!project.data) {
    return <BaseLayout><div className="p-10">Loading…</div></BaseLayout>;
  }

  const p = project.data.data;
  const f = files.data?.data ?? [];

  return (
    <BaseLayout>
      <div className="mx-auto grid w-full max-w-6xl grid-cols-[1fr_328px] gap-6 px-8 py-10">
        <div>
          <div className="mb-6 flex items-center gap-3">
            <Link href="/studio" className="text-neutral-400 hover:text-white">←</Link>
            <h1 className="text-2xl font-semibold">{p.name}</h1>
          </div>

          {f.length === 0 ? (
            <FileEmptyState projectId={params.id} />
          ) : (
            <div className="grid grid-cols-3 gap-4">
              {f.map((file) => (
                <FileCard key={file.id} file={file} />
              ))}
            </div>
          )}
        </div>

        <ProjectSettingsRail
          description={p.description ?? ""}
          useBrandKnowledge={p.use_brand_knowledge}
          onUpdate={(patch) => mutation.mutate(patch)}
        />
      </div>
    </BaseLayout>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/projects/ProjectSettingsRail.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(dashboard\)/studio/projects/\[id\]/ src/components/studio/projects/
git commit -m "feat(web): add project detail page with settings rail autosave"
```

---

## Task 10 — `(canvas)` route group + minimal layout

**Files:**
- Create: `web/src/app/(canvas)/layout.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/app/(canvas)/layout.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import Layout from "./layout";

it("renders children without dashboard chrome", () => {
  render(<Layout><div data-testid="child">hi</div></Layout>);
  expect(screen.getByTestId("child")).toBeInTheDocument();
  // No dashboard sidebar or bottom nav
  expect(screen.queryByRole("navigation", { name: /sidebar/i })).toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/app/\(canvas\)/layout.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create layout**

File: `web/src/app/(canvas)/layout.tsx`

```tsx
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Studio Canvas — frndOS",
};

export default function CanvasLayout({ children }: { children: React.ReactNode }) {
  // No dashboard chrome. Just a full-screen shell. Auth + providers come from the root layout.
  return <div className="min-h-screen bg-black text-white">{children}</div>;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/app/\(canvas\)/layout.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/app/\(canvas\)/
git commit -m "feat(web): add (canvas) route group with minimal layout"
```

---

## Task 11 — Canvas store + `KvVersionCard` + `KvVersionCardPlaceholder`

**Files:**
- Create: `web/src/store/useKvCanvasStore.ts`
- Create: `web/src/components/studio/kv-generator/KvVersionCard.tsx`
- Create: `web/src/components/studio/kv-generator/KvVersionCardPlaceholder.tsx`

- [ ] **Step 1: Write the failing tests**

File: `web/src/components/studio/kv-generator/KvVersionCard.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import { KvVersionCard } from "./KvVersionCard";

it("shows version number and image", () => {
  render(
    <KvVersionCard
      generation={{
        id: "g1", studio_file_id: "f", version_number: 3,
        image_url: "https://s/img.png", thumbnail_url: null,
        prompt_snapshot: "p", model: "m",
        parent_generation_id: null, metadata: null,
        created_at: "2026-04-23T00:00:00Z",
      }}
    />,
  );
  expect(screen.getByText(/Version 3/i)).toBeInTheDocument();
  expect(screen.getByAltText(/Version 3/i)).toHaveAttribute("src", "https://s/img.png");
});
```

File: `web/src/components/studio/kv-generator/KvVersionCardPlaceholder.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import { KvVersionCardPlaceholder } from "./KvVersionCardPlaceholder";

it("shows generating state with estimated time", () => {
  render(<KvVersionCardPlaceholder startedAt={Date.now()} estimatedMs={15000} />);
  expect(screen.getByText(/Generating/i)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bun test src/components/studio/kv-generator`
Expected: FAIL.

- [ ] **Step 3: Create the components + store**

File: `web/src/store/useKvCanvasStore.ts`

```ts
import { create } from "zustand";

type KvCanvasState = {
  selectedVersionId: string | null;
  select: (id: string | null) => void;
};

export const useKvCanvasStore = create<KvCanvasState>((set) => ({
  selectedVersionId: null,
  select: (id) => set({ selectedVersionId: id }),
}));
```

File: `web/src/components/studio/kv-generator/KvVersionCard.tsx`

```tsx
"use client";

import type { KvGeneration } from "@/types/studio";
import { useKvCanvasStore } from "@/store/useKvCanvasStore";

export function KvVersionCard({ generation }: { generation: KvGeneration }) {
  const selected = useKvCanvasStore((s) => s.selectedVersionId);
  const select = useKvCanvasStore((s) => s.select);

  return (
    <button
      onClick={() => select(generation.id)}
      className={`group relative w-full overflow-hidden rounded-xl border transition-colors ${
        selected === generation.id
          ? "border-white"
          : "border-white/10 hover:border-white/30"
      }`}
      aria-label={`Version ${generation.version_number}`}
    >
      <img
        src={generation.image_url}
        alt={`Version ${generation.version_number}`}
        className="h-auto w-full"
      />
      <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent p-3">
        <p className="text-sm font-medium text-white">
          Version {generation.version_number}
        </p>
      </div>
    </button>
  );
}
```

File: `web/src/components/studio/kv-generator/KvVersionCardPlaceholder.tsx`

```tsx
"use client";

import { useEffect, useState } from "react";

type Props = {
  startedAt: number;
  estimatedMs?: number;
};

export function KvVersionCardPlaceholder({ startedAt, estimatedMs }: Props) {
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    const id = setInterval(() => setElapsed(Date.now() - startedAt), 250);
    return () => clearInterval(id);
  }, [startedAt]);

  const remaining = estimatedMs ? Math.max(0, estimatedMs - elapsed) : undefined;

  return (
    <div className="flex aspect-square items-center justify-center rounded-xl border border-white/10 bg-neutral-900">
      <div className="text-center">
        <div className="mx-auto h-6 w-6 animate-spin rounded-full border-2 border-white/20 border-t-white/80" />
        <p className="mt-3 text-sm text-neutral-300">Generating…</p>
        <p className="text-xs text-neutral-500">
          {remaining ? `~${Math.round(remaining / 1000)}s left` : `${Math.round(elapsed / 1000)}s`}
        </p>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/store/useKvCanvasStore.ts src/components/studio/kv-generator/
git commit -m "feat(web): add KV canvas store + version card + placeholder"
```

---

## Task 12 — `useKvStream` SSE hook

**Files:**
- Create: `web/src/hooks/useKvStream.ts`

- [ ] **Step 1: Write the failing test**

File: `web/src/hooks/useKvStream.test.ts`

```ts
import { renderHook, act, waitFor } from "@testing-library/react";
import { useKvStream } from "./useKvStream";

// Minimal EventSource polyfill for tests
class MockEventSource {
  onmessage: ((e: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  addEventListener(event: string, cb: any) {
    (this as any)[`on${event}`] = cb;
  }
  close = jest.fn();
}

let mockSource: MockEventSource;

beforeEach(() => {
  mockSource = new MockEventSource();
  (globalThis as any).EventSource = jest.fn(() => mockSource);
});

it("appends a generation on generation_done event", async () => {
  const { result } = renderHook(() =>
    useKvStream({ fileId: "f1", enabled: true, initialGenerations: [] }),
  );

  act(() => {
    const ev = new MessageEvent("generation_done", {
      data: JSON.stringify({
        generation: {
          id: "g1", studio_file_id: "f1", version_number: 1,
          image_url: "https://s/img.png", thumbnail_url: null,
          prompt_snapshot: "p", model: "m",
          parent_generation_id: null, metadata: null,
          created_at: "2026-04-23T00:00:00Z",
        },
      }),
    });
    (mockSource as any).ongeneration_done?.(ev);
  });

  await waitFor(() => expect(result.current.generations).toHaveLength(1));
});

it("tracks a pending generation on generating image_rendering event", () => {
  const { result } = renderHook(() =>
    useKvStream({ fileId: "f1", enabled: true, initialGenerations: [] }),
  );

  act(() => {
    const ev = new MessageEvent("generating", {
      data: JSON.stringify({ stage: "image_rendering", estimated_ms: 15000 }),
    });
    (mockSource as any).ongenerating?.(ev);
  });

  expect(result.current.pendingGeneration).not.toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/hooks/useKvStream.test.ts`
Expected: FAIL.

- [ ] **Step 3: Create the hook**

File: `web/src/hooks/useKvStream.ts`

```ts
"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { KvGeneration } from "@/types/studio";

export type ChatStreamMessage = {
  id: string;
  role: "user" | "assistant";
  text: string;
  metadata?: Record<string, unknown>;
};

export type PendingGeneration = {
  placeholderId: string;
  startedAt: number;
  estimatedMs?: number;
};

type Props = {
  fileId: string | undefined;
  enabled: boolean;
  initialGenerations?: KvGeneration[];
};

export function useKvStream({ fileId, enabled, initialGenerations = [] }: Props) {
  const [messages, setMessages] = useState<ChatStreamMessage[]>([]);
  const [generations, setGenerations] = useState<KvGeneration[]>(initialGenerations);
  const [pendingGeneration, setPendingGeneration] = useState<PendingGeneration | null>(null);
  const [mode, setMode] = useState<"chat" | "image">("chat");
  const sourceRef = useRef<EventSource | null>(null);

  useEffect(() => {
    if (!enabled || !fileId) return;

    const source = new EventSource(`/api/studio/kv-generator/files/${fileId}/stream`);
    sourceRef.current = source;

    source.addEventListener("thinking", (e: MessageEvent) => {
      const payload = JSON.parse(e.data);
      setMessages((prev) => [
        ...prev,
        { id: crypto.randomUUID(), role: "assistant", text: payload.chunk },
      ]);
    });

    source.addEventListener("message", (e: MessageEvent) => {
      const payload = JSON.parse(e.data);
      setMessages((prev) => [
        ...prev,
        { id: payload.chat_message_id ?? crypto.randomUUID(), role: "assistant", text: payload.text },
      ]);
    });

    source.addEventListener("generating", (e: MessageEvent) => {
      const payload = JSON.parse(e.data);
      if (payload.stage === "image_rendering") {
        setPendingGeneration({
          placeholderId: crypto.randomUUID(),
          startedAt: Date.now(),
          estimatedMs: payload.estimated_ms,
        });
      }
    });

    source.addEventListener("generation_done", (e: MessageEvent) => {
      const payload = JSON.parse(e.data);
      setGenerations((prev) => [payload.generation, ...prev]);
      setPendingGeneration(null);
    });

    source.addEventListener("generation_failed", (e: MessageEvent) => {
      const payload = JSON.parse(e.data);
      setPendingGeneration(null);
      setMessages((prev) => [
        ...prev,
        {
          id: crypto.randomUUID(),
          role: "assistant",
          text: `Generation failed: ${payload.message}`,
          metadata: { error: true },
        },
      ]);
    });

    source.addEventListener("done", () => {
      source.close();
    });

    return () => {
      source.close();
      sourceRef.current = null;
    };
  }, [fileId, enabled]);

  const send = useCallback(
    async (prompt: string, opts?: { attachedGenerationId?: string }) => {
      if (!fileId) return;
      setMessages((prev) => [
        ...prev,
        { id: crypto.randomUUID(), role: "user", text: prompt },
      ]);
      await fetch("/api/chat/stream", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          thread_type: "kv_generator",
          studio_file_id: fileId,
          message: prompt,
          mode,
          attached_generation_id: opts?.attachedGenerationId,
        }),
      });
    },
    [fileId, mode],
  );

  const abort = useCallback(() => {
    sourceRef.current?.close();
    setPendingGeneration(null);
  }, []);

  return {
    messages,
    generations,
    pendingGeneration,
    mode,
    setMode,
    send,
    abort,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/hooks/useKvStream.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/hooks/useKvStream.ts src/hooks/useKvStream.test.ts
git commit -m "feat(web): add useKvStream SSE hook"
```

---

## Task 13 — `KvCanvas` + `KvGeneratorLayout` + routes

**Files:**
- Create: `web/src/components/studio/kv-generator/KvCanvas.tsx`
- Create: `web/src/components/studio/kv-generator/KvCanvasTopNav.tsx`
- Create: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Create: `web/src/app/(canvas)/studio/kv-generator/new/page.tsx`
- Create: `web/src/app/(canvas)/studio/kv-generator/[file_id]/page.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/components/studio/kv-generator/KvCanvas.test.tsx`

```tsx
import { render, screen } from "@testing-library/react";
import { KvCanvas } from "./KvCanvas";

it("renders empty state when no generations and no pending", () => {
  render(<KvCanvas generations={[]} pendingGeneration={null} />);
  expect(screen.getByText(/switch to Image mode/i)).toBeInTheDocument();
});

it("renders placeholder when pending", () => {
  render(
    <KvCanvas
      generations={[]}
      pendingGeneration={{
        placeholderId: "p",
        startedAt: Date.now(),
        estimatedMs: 15000,
      }}
    />,
  );
  expect(screen.getByText(/Generating/i)).toBeInTheDocument();
});

it("renders generations when provided", () => {
  render(
    <KvCanvas
      generations={[
        {
          id: "g1", studio_file_id: "f", version_number: 1,
          image_url: "https://s/img.png", thumbnail_url: null,
          prompt_snapshot: "p", model: "m",
          parent_generation_id: null, metadata: null,
          created_at: "2026-04-23T00:00:00Z",
        },
      ]}
      pendingGeneration={null}
    />,
  );
  expect(screen.getByAltText(/Version 1/i)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvCanvas.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Create the components + routes**

File: `web/src/components/studio/kv-generator/KvCanvas.tsx`

```tsx
"use client";

import { KvVersionCard } from "./KvVersionCard";
import { KvVersionCardPlaceholder } from "./KvVersionCardPlaceholder";
import type { KvGeneration } from "@/types/studio";
import type { PendingGeneration } from "@/hooks/useKvStream";

type Props = {
  generations: KvGeneration[];
  pendingGeneration: PendingGeneration | null;
};

export function KvCanvas({ generations, pendingGeneration }: Props) {
  const isEmpty = generations.length === 0 && !pendingGeneration;

  if (isEmpty) {
    return (
      <div className="flex flex-1 items-center justify-center p-10">
        <p className="max-w-md text-center text-neutral-400">
          Keep chatting to shape the brief, or switch to Image mode to generate your
          first KV.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col items-center gap-6 overflow-y-auto px-10 py-8">
      {pendingGeneration && (
        <div className="w-full max-w-[900px]">
          <KvVersionCardPlaceholder
            startedAt={pendingGeneration.startedAt}
            estimatedMs={pendingGeneration.estimatedMs}
          />
        </div>
      )}
      {generations.map((g) => (
        <div key={g.id} className="w-full max-w-[900px]">
          <KvVersionCard generation={g} />
        </div>
      ))}
    </div>
  );
}
```

File: `web/src/components/studio/kv-generator/KvCanvasTopNav.tsx`

```tsx
"use client";

import { useRouter } from "next/navigation";

export function KvCanvasTopNav({ title, onBack }: { title: string; onBack?: () => void }) {
  const router = useRouter();
  return (
    <div className="flex items-center justify-between border-b border-white/10 px-6 py-4">
      <button
        onClick={onBack ?? (() => router.back())}
        className="text-sm text-neutral-300 hover:text-white"
      >
        ← Back
      </button>
      <h1 className="text-sm font-medium">{title}</h1>
      <span className="w-16" />
    </div>
  );
}
```

File: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`

```tsx
"use client";

import { useKvFile } from "@/hooks/useKvFile";
import { useKvStream } from "@/hooks/useKvStream";
import { KvCanvas } from "./KvCanvas";
import { KvCanvasTopNav } from "./KvCanvasTopNav";
import { KvChat } from "./KvChat";

export function KvGeneratorLayout({ fileId }: { fileId: string }) {
  const fileQuery = useKvFile(fileId);
  const stream = useKvStream({
    fileId,
    enabled: true,
    initialGenerations: fileQuery.data?.data?.generations ?? [],
  });

  const title = fileQuery.data?.data?.name ?? "New KV";

  return (
    <div className="flex h-screen w-screen">
      <div className="flex flex-1 flex-col">
        <KvCanvasTopNav title={title} />
        <KvCanvas
          generations={stream.generations}
          pendingGeneration={stream.pendingGeneration}
        />
      </div>
      <div className="w-[468px] border-l border-white/10">
        <KvChat stream={stream} />
      </div>
    </div>
  );
}
```

File: `web/src/hooks/useKvFile.ts`

```ts
import { useQuery } from "@tanstack/react-query";
import { getKvFile } from "@/services/query";

export function useKvFile(id: string | undefined) {
  return useQuery({
    queryKey: ["studio", "kv-file", id],
    queryFn: () => getKvFile(id!),
    enabled: !!id,
  });
}
```

File: `web/src/app/(canvas)/studio/kv-generator/[file_id]/page.tsx`

```tsx
import { KvGeneratorLayout } from "@/components/studio/kv-generator/KvGeneratorLayout";

export default function KvGeneratorFilePage({ params }: { params: { file_id: string } }) {
  return <KvGeneratorLayout fileId={params.file_id} />;
}
```

File: `web/src/app/(canvas)/studio/kv-generator/new/page.tsx`

```tsx
"use client";

import { useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useMutation } from "@tanstack/react-query";
import { useAuth } from "@/context/AuthContext";
import { createKvFile } from "@/services/mutate";

export default function KvGeneratorNewPage() {
  const router = useRouter();
  const search = useSearchParams();
  const projectId = search.get("project_id") || undefined;
  const authContext = useAuth();
  const brandId = (authContext?.user as any)?.current_brand_id;

  const mutation = useMutation({
    mutationFn: () =>
      createKvFile({ project_id: projectId, brand_id: brandId }),
    onSuccess: (res) => {
      router.replace(`/studio/kv-generator/${res.data.id}`);
    },
  });

  useEffect(() => {
    if (brandId) mutation.mutate();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brandId]);

  return (
    <div className="flex min-h-screen items-center justify-center text-neutral-400">
      Creating new KV file…
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvCanvas.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/components/studio/kv-generator/ src/app/\(canvas\)/studio/ src/hooks/useKvFile.ts
git commit -m "feat(web): add KV canvas + layout + routes"
```

---

## Task 14 — `KvChat` + `QuestionCardMessage` + `ModeSuggestionMessage` + mode dropdown

**Files:**
- Create: `web/src/components/studio/kv-generator/KvChat.tsx`
- Create: `web/src/components/studio/kv-generator/QuestionCardMessage.tsx`
- Create: `web/src/components/studio/kv-generator/ModeSuggestionMessage.tsx`
- Create: `web/src/components/studio/kv-generator/ChatInputModeDropdown.tsx`
- Create: `web/src/components/studio/kv-generator/ChatInputStyleChip.tsx`

- [ ] **Step 1: Write the failing test**

File: `web/src/components/studio/kv-generator/ChatInputModeDropdown.test.tsx`

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { ChatInputModeDropdown } from "./ChatInputModeDropdown";

it("toggles between chat and image modes", () => {
  const onChange = jest.fn();
  render(<ChatInputModeDropdown mode="chat" onChange={onChange} />);

  fireEvent.click(screen.getByRole("button", { name: /chat/i }));
  fireEvent.click(screen.getByRole("menuitem", { name: /image/i }));

  expect(onChange).toHaveBeenCalledWith("image");
});
```

File: `web/src/components/studio/kv-generator/QuestionCardMessage.test.tsx`

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { QuestionCardMessage } from "./QuestionCardMessage";

it("calls onPick when an option is clicked", () => {
  const onPick = jest.fn();
  render(
    <QuestionCardMessage
      label="Pick aspect"
      options={[
        { id: "1:1", label: "Square" },
        { id: "16:9", label: "Wide" },
      ]}
      onPick={onPick}
    />,
  );
  fireEvent.click(screen.getByRole("button", { name: /square/i }));
  expect(onPick).toHaveBeenCalledWith("1:1");
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bun test src/components/studio/kv-generator`
Expected: FAIL.

- [ ] **Step 3: Create components**

File: `web/src/components/studio/kv-generator/ChatInputModeDropdown.tsx`

```tsx
"use client";

import { useState } from "react";

export function ChatInputModeDropdown({
  mode,
  onChange,
}: {
  mode: "chat" | "image";
  onChange: (m: "chat" | "image") => void;
}) {
  const [open, setOpen] = useState(false);

  return (
    <div className="relative">
      <button
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className="rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-300 hover:bg-white/5"
      >
        {mode === "chat" ? "Chat" : "Image"} ▾
      </button>
      {open && (
        <div className="absolute bottom-full z-10 mb-2 w-40 rounded-xl border border-white/10 bg-neutral-900 p-1">
          {(["chat", "image"] as const).map((m) => (
            <button
              key={m}
              role="menuitem"
              onClick={() => { onChange(m); setOpen(false); }}
              className={`flex w-full items-center justify-between rounded-lg px-3 py-2 text-left text-sm hover:bg-white/5 ${
                mode === m ? "text-white" : "text-neutral-300"
              }`}
            >
              {m === "chat" ? "Chat" : "Image"}
              {mode === m && <span>●</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
```

File: `web/src/components/studio/kv-generator/ChatInputStyleChip.tsx`

```tsx
"use client";

export function ChatInputStyleChip({ onOpen }: { onOpen: () => void }) {
  return (
    <button
      onClick={onOpen}
      className="rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-300 hover:bg-white/5"
    >
      Style
    </button>
  );
}
```

File: `web/src/components/studio/kv-generator/QuestionCardMessage.tsx`

```tsx
"use client";

export function QuestionCardMessage({
  label,
  options,
  onPick,
}: {
  label: string;
  options: Array<{ id: string; label: string; thumbnail_url?: string }>;
  onPick: (optionId: string) => void;
}) {
  return (
    <div className="rounded-xl border border-white/10 bg-neutral-900 p-4">
      <p className="text-sm font-medium">{label}</p>
      <div className="mt-3 flex flex-wrap gap-2">
        {options.map((opt) => (
          <button
            key={opt.id}
            onClick={() => onPick(opt.id)}
            className="rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-200 hover:bg-white/5"
          >
            {opt.label}
          </button>
        ))}
      </div>
    </div>
  );
}
```

File: `web/src/components/studio/kv-generator/ModeSuggestionMessage.tsx`

```tsx
"use client";

export function ModeSuggestionMessage({
  reason,
  onAccept,
  onDismiss,
}: {
  reason: string;
  onAccept: () => void;
  onDismiss: () => void;
}) {
  return (
    <div className="rounded-xl border border-white/10 bg-neutral-900 p-4">
      <p className="text-sm">{reason}</p>
      <div className="mt-3 flex gap-2">
        <button
          onClick={onAccept}
          className="rounded-full bg-white px-3 py-1 text-xs font-medium text-black"
        >
          Start generating
        </button>
        <button
          onClick={onDismiss}
          className="rounded-full border border-white/10 px-3 py-1 text-xs text-neutral-300"
        >
          Keep chatting
        </button>
      </div>
    </div>
  );
}
```

File: `web/src/components/studio/kv-generator/KvChat.tsx`

```tsx
"use client";

import { useState } from "react";
import type { useKvStream } from "@/hooks/useKvStream";
import { ChatInputModeDropdown } from "./ChatInputModeDropdown";
import { ChatInputStyleChip } from "./ChatInputStyleChip";

type Stream = ReturnType<typeof useKvStream>;

export function KvChat({ stream }: { stream: Stream }) {
  const [prompt, setPrompt] = useState("");

  const onSend = async () => {
    if (!prompt.trim()) return;
    const p = prompt;
    setPrompt("");
    await stream.send(p);
  };

  return (
    <div className="flex h-full flex-col">
      <div className="border-b border-white/10 px-6 py-4">
        <h2 className="text-sm font-medium">Chat</h2>
      </div>

      <div className="flex-1 overflow-y-auto p-6 text-sm">
        {stream.messages.map((m) => (
          <div
            key={m.id}
            className={`mb-3 whitespace-pre-wrap ${
              m.role === "user" ? "text-white" : "text-neutral-300"
            }`}
          >
            {m.text}
          </div>
        ))}
      </div>

      <div className="border-t border-white/10 p-4">
        <textarea
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="What do you want to ask..."
          className="h-16 w-full resize-none rounded-xl border border-white/10 bg-neutral-900 p-3 text-sm"
        />
        <div className="mt-2 flex items-center gap-2">
          <button className="text-neutral-300" aria-label="Attach">+</button>
          <ChatInputModeDropdown mode={stream.mode} onChange={stream.setMode} />
          <ChatInputStyleChip onOpen={() => {}} />
          <button
            onClick={onSend}
            className="ml-auto rounded-full bg-white px-3 py-1 text-sm text-black"
          >
            ↑ Send
          </button>
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/components/studio/kv-generator/
git commit -m "feat(web): add KV chat panel with mode dropdown + question card + suggestion"
```

---

## Task 15 — Playwright smoke test (end-to-end happy path)

**Files:**
- Create: `web/tests/e2e/studio-projects-kv-generator.spec.ts`

- [ ] **Step 1: Write the failing test**

File: `web/tests/e2e/studio-projects-kv-generator.spec.ts`

```ts
import { test, expect } from "@playwright/test";

test("create project → land on detail → launch KV canvas", async ({ page }) => {
  // Assumes dev server + mocked API are running or a seeded dev user is logged in.
  await page.goto("/studio");

  await page.getByRole("button", { name: /new project/i }).click();

  await page.getByLabel(/name/i).fill("Playwright Campaign");
  await page.getByLabel(/description/i).fill("E2E brief");
  await page.getByRole("button", { name: /create project/i }).click();

  // On detail
  await expect(page.getByText(/Playwright Campaign/i)).toBeVisible();
  await expect(page.getByText(/Use Brand Knowledge/i)).toBeVisible();

  // Launch KV canvas
  await page.getByRole("button", { name: /create new/i }).click();

  // Canvas route loaded
  await expect(page).toHaveURL(/\/studio\/kv-generator\//);
  await expect(page.getByPlaceholder(/What do you want to ask/i)).toBeVisible();
});
```

- [ ] **Step 2: Run test**

Run: `cd web && bunx playwright test studio-projects-kv-generator`
Expected: PASS against a dev server with the feature flag ON + seeded brand context. If you skip e2e infra, gate with `test.skip()` — but it should live in the repo for future runs.

- [ ] **Step 3: Commit**

```bash
cd web
git add tests/e2e/studio-projects-kv-generator.spec.ts
git commit -m "test(web): add e2e smoke for studio projects + KV canvas flow"
```

---

## Task 16 — Feature flag gating + final wiring

**Files:**
- Verify: `web/src/app/(dashboard)/studio/Studiofrndos.tsx` (Task 7 wiring)
- Verify: `web/.env.example` and `web/.env.local` for local dev

- [ ] **Step 1: Manual verification**

1. Set `NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED=false` in `.env.local` → `/studio` shows the old placeholder, no Projects section.
2. Set it to `true` → Projects section appears with empty state, then populated after creating a project.
3. Toggle back to `false` → Projects section hidden again (smoke test for correct flag gating).

- [ ] **Step 2: Commit** (if any adjustments made)

```bash
cd web
git add -u
git commit -m "chore(web): verify feature flag gating for studio projects"
```

---

## Final Verification

- [ ] **Unit tests**

```bash
cd web && bun test
```

Expected: all tests pass.

- [ ] **Type check**

```bash
cd web && bunx tsc --noEmit
```

Expected: 0 errors.

- [ ] **Dev server smoke**

```bash
cd web && bun dev
# open http://localhost:3000/studio — create a project, land on detail, launch KV canvas
```

Expected: full happy path works end-to-end against real API + ai-service.

---

## Self-Review Checklist

- Wireframe sub-pages: ✓ (Tasks 1–3)
- Type rename (StudioProject → StudioFile) + new folder type: ✓ (Task 4)
- Query + mutate services: ✓ (Task 5)
- Data hooks: ✓ (Task 6)
- Studio home Projects section with feature flag: ✓ (Task 7)
- New Project intercepting modal: ✓ (Task 8)
- Project detail + settings rail autosave: ✓ (Task 9)
- (canvas) route group: ✓ (Task 10)
- Canvas store + version card + placeholder: ✓ (Task 11)
- useKvStream SSE hook: ✓ (Task 12)
- KV canvas + layout + routes: ✓ (Task 13)
- Chat panel + question card + mode suggestion + mode dropdown: ✓ (Task 14)
- E2E smoke: ✓ (Task 15)
- Feature flag verification: ✓ (Task 16)

**Out of scope for this plan (in other plans):**
- API endpoints + migrations → see `-api.md` plan
- AI service agent → see `-ai-service.md` plan
- File move UI for cross-project reassignment beyond the detail page — deferred
- Image editor / resizer integration paths from KV canvas (opening a version in those tools) — noted in spec as "deferred"

**Open items (non-blocking):**
- Style preset catalog (popover content for `ChatInputStyleChip`)
- Frame / aspect ratio state persistence during mode switches
- Auto-scroll behavior of chat when new messages arrive (good defaults, optional polish)
