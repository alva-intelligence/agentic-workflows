---
name: wireframe
description: Build wireframe pages for features using frndos components
---

# Wireframe Builder

Builds wireframe pages under the `/workflows/` route using frndos components.

## Commands

### `/wireframe create <wireframe-slug>`
Create a new wireframe page for the active feature.

**Steps:**
1. Verify workflow state is in `wireframe` phase
2. Read the feature's PRD for UI/UX requirements
3. If Figma MCP is enabled and user provides Figma URL, fetch design specs
4. Plan the wireframe:
   - Which frndos components to use
   - Page layout structure
   - What placeholder data to include
5. Present the plan to user with component list and layout description
6. On approval:
   a. Create directory: `web/src/app/(dashboard)/workflows/<feature-slug>/<wireframe-slug>/`
   b. Create `page.tsx` wrapped in BaseLayout
   c. Create wireframe-specific components in `components/`
   d. Create `metadata.json` with feature, wireframe, title, prd, owner, status=draft
   e. If feature index page doesn't exist, create `workflows/<feature-slug>/page.tsx`
7. Update `.workflow-state.json` wireframes array

### `/wireframe edit <wireframe-slug>`
Edit an existing wireframe.

**Steps:**
1. Verify current user is the wireframe owner
2. Read existing wireframe files
3. Ask what to change
4. Present changes
5. On approval, apply changes

### `/wireframe preview`
List all wireframes for the active feature with their status.

### `/wireframe approve <wireframe-slug>`
Record approval for a wireframe (verbal confirmation from Jeff).

**Steps:**
1. Ask: "Has Jeff approved the wireframe `<wireframe-slug>`?"
2. On confirmation, update metadata.json: status=approved, approved_by, approved_at
3. Update `.workflow-state.json` wireframe approval
4. Check if ALL wireframes are approved → if yes, inform user they can proceed to next phase

## Component Reference

Available frndos components (from `@/components/frndos/`):
- BaseLayout — Page wrapper
- CardMetric — KPI cards
- BaseTable — Data tables
- TabsLine, TabsRounded — Tab navigation
- Button, Input, Checkbox, Toggle, RadioButton — Form controls
- BaseModal — Modal dialogs
- Avatar — User avatars
- Breadcrumbs — Navigation breadcrumbs
- Pagination — Pagination controls
- Label — Form labels
- Stepper — Step indicators
- Toast — Notifications
- CopyButton — Copy to clipboard
- CheckboxList — Checkbox groups
- CardGeneratedKV — Key-value cards

## Rules

- MUST use only frndos and base components
- MUST wrap in BaseLayout
- MUST NOT implement business logic or API calls
- CAN use useState for local UI state
- CAN hardcode realistic placeholder data
