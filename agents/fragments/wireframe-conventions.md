## Wireframe Conventions

### Location

Wireframes live at: `web/src/app/(dashboard)/wireframes/<feature-slug>/<wireframe-slug>/`

### What is a Wireframe?

In this project, "wireframe" does NOT mean a rough layout sketch. A wireframe is a **fully-built static frontend** — it should look and feel like a real, polished production page (think Canva, Adobe Firefly, or any modern SaaS UI). It uses real components, real interactions, proper visuals, and realistic mock data. The only difference from production code is that it uses static/dummy data instead of live API calls.

**A wireframe is the foundation that gets built on during implementation.** When the feature moves to the implementation phase, engineers wire up real API calls, state management, and business logic to the wireframe code that's already there. The UI should already be done.

A wireframe = **one feature page**. It represents the main entry point for a feature (e.g., a dashboard, a listing page, an AI image editor). Sub-views like create forms, detail pages, wizard steps, and modals are **sub-pages within the same wireframe**, not separate wireframes.

**Example:** A "Campaign Management" feature has ONE wireframe (`campaign-management`) containing:
- Main page: campaign listing with filters, search, and a polished data table
- Sub-page `create/`: multi-step campaign creation wizard with form validation UX
- Sub-page `[id]/`: campaign detail view with tabs, charts, and action buttons
- Sub-page `[id]/edit/`: campaign edit form pre-filled with mock data

These are all part of the same wireframe, not 4 separate wireframes.

### Directory Structure

```
wireframes/<feature-slug>/
├── page.tsx                        # Feature index: lists wireframes (usually just one)
└── <wireframe-slug>/
    ├── page.tsx                    # Main wireframe page (the feature's primary view)
    ├── components/                 # Shared components across all sub-pages
    │   ├── MetricCard.tsx
    │   └── DataTable.tsx
    ├── metadata.json               # Wireframe metadata
    ├── create/                     # Sub-page: create form / wizard
    │   └── page.tsx
    ├── [id]/                       # Sub-page: detail view (dynamic route)
    │   ├── page.tsx
    │   └── edit/                   # Sub-page: edit form
    │       └── page.tsx
    └── settings/                   # Sub-page: feature settings
        └── page.tsx
```

Not every wireframe needs sub-pages — simple features may only have a single `page.tsx`. Add sub-pages only when the PRD describes navigable views (create, detail, edit, wizard steps, etc.).

### metadata.json

```json
{
  "feature": "<feature-slug>",
  "wireframe": "<wireframe-slug>",
  "title": "Human-Readable Title",
  "prd": "docs/prd/<feature-slug>.md",
  "owner": "<person-name>",
  "status": "draft|under_review|approved|in_development|completed",
  "created": "YYYY-MM-DD",
  "approved_by": null,
  "approved_at": null
}
```

### Component Rules

- **MUST** use only components from `@/components/frndos/` and `@/components/base/`
- **MUST** wrap every page in `BaseLayout` from `@/components/frndos/layout/BaseLayout`
- **MUST** build pages that look production-ready — proper spacing, alignment, typography, visual hierarchy
- **MUST** include all interactive UI states: hover, active, selected, disabled, empty states, loading skeletons
- **MUST** use realistic placeholder data — real-looking names, dates, numbers, images (not "Lorem ipsum" or "Test 1")
- **MUST NOT** implement business logic, API calls, or server-side state management
- **CAN** use `useState` for local UI interactions (tabs, modals, toggles, dropdowns, search filtering)
- **CAN** create wireframe-specific components in `components/` for complex UI pieces
- **MUST NOT** install new packages

### Available frndos Components

| Component | Import | Purpose |
|-----------|--------|---------|
| BaseLayout | `@/components/frndos/layout/BaseLayout` | Page wrapper with sidebar + header |
| CardMetric | `@/components/frndos/CardMetric` | KPI/metric display card |
| BaseTable | `@/components/frndos/BaseTable` | Data table with sorting/pagination |
| TabsLine | `@/components/frndos/TabsLine` | Line-style tab navigation |
| TabsRounded | `@/components/frndos/TabsRounded` | Rounded tab navigation |
| Button | `@/components/frndos/Button` | Action button |
| Input | `@/components/frndos/Input` | Text input field |
| BaseModal | `@/components/frndos/BaseModal` | Modal dialog |
| Checkbox | `@/components/frndos/Checkbox` | Checkbox input |
| Toggle | `@/components/frndos/Toggle` | Toggle switch |
| Avatar | `@/components/frndos/Avatar` | User avatar |
| Breadcrumbs | `@/components/frndos/Breadcrumbs` | Breadcrumb navigation |
| Pagination | `@/components/frndos/Pagination` | Pagination controls |
| Label | `@/components/frndos/Label` | Form label |
| Stepper | `@/components/frndos/Stepper` | Step indicator |
| Toast | `@/components/frndos/Toast` | Toast notifications |
| CopyButton | `@/components/frndos/CopyButton` | Copy-to-clipboard button |
| RadioButton | `@/components/frndos/RadioButton` | Radio button input |
| CheckboxList | `@/components/frndos/CheckboxList` | Checkbox group |
| CardGeneratedKV | `@/components/frndos/CardGeneratedKV` | Key-value display card |

### Visibility

- Wireframes live on the `develop` branch permanently
- They are only visible in development/staging environments
- Gated by `NODE_ENV !== 'production'` in the layout
- The `/workflows` route is NOT included in production builds

### Sub-Pages

- Sub-pages are nested routes inside a wireframe directory (e.g., `create/page.tsx`, `[id]/page.tsx`)
- Sub-pages share the wireframe's `components/` directory
- Sub-pages follow the same rules as the main page: `BaseLayout`, frndos components only, no business logic
- Use Next.js dynamic routes for detail pages: `[id]/page.tsx`
- Use the `Stepper` component for wizard/multi-step flows within a sub-page

**Main `page.tsx` behavior depends on whether sub-pages interconnect:**

| Sub-pages | Main `page.tsx` role | Example |
|-----------|---------------------|---------|
| **Interconnecting** (listing → detail → edit) | The primary view itself (e.g., listing page). Navigation flows naturally via buttons, table row clicks, breadcrumbs. | Campaign listing → click row → detail → click edit → edit form |
| **Non-interconnecting** (independent views) | An **index page** that lists all sub-pages with links. Users pick which sub-page to view. | Feature with separate "Reports", "Settings", "Import" pages that don't link to each other |

When clicking a wireframe in the wireframe library, the main `page.tsx` is always what loads first. For non-interconnecting sub-pages, this index page is how reviewers discover and navigate to each sub-page.

### Ownership

- Each wireframe has an `owner` in metadata.json
- Only the owner (or unassigned wireframes) can be edited by an agent
- Multiple people can own different wireframes for the same PRD (rare — most PRDs have one wireframe)
