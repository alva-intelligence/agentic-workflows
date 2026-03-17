## Wireframe Conventions

### Location

Wireframes live at: `web/src/app/(dashboard)/workflows/<feature-slug>/<wireframe-slug>/`

### Directory Structure

```
workflows/<feature-slug>/
├── page.tsx                    # Feature index: lists all wireframes
└── <wireframe-slug>/
    ├── page.tsx                # The actual wireframe page
    ├── components/             # Wireframe-specific components
    │   ├── MetricCard.tsx
    │   └── DataTable.tsx
    └── metadata.json           # Wireframe metadata
```

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
- **MUST NOT** implement business logic, API calls, or server-side state management
- **CAN** use `useState` for local UI interactions (tabs, modals, toggles)
- **CAN** hardcode realistic placeholder data (mock data that looks real)
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

### Ownership

- Each wireframe has an `owner` in metadata.json
- Only the owner (or unassigned wireframes) can be edited by an agent
- Multiple people can own different wireframes for the same PRD
