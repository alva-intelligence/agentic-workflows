# Share Report: Public Link — Design Spec

**Date:** 2026-04-14
**Author:** Daffa Praramadhana
**Status:** Draft
**PRD Source:** [Lark Wiki — Share Report: Public Link](https://fcn.sg.larksuite.com/wiki/P18NwzDcPibR9AkM6g8lVpH8g0c)

---

## 1. Overview

A brand-level public link feature that allows internal users to generate a single shareable URL giving external viewers access to **all** Brand Insights tabs (Overview, Campaigns, Paid Media, Owned Media, Earned Media, ATL) with live data.

The system follows the same UX pattern as the existing RAFI share feature (toggle, slug, optional password) but operates at the brand level — one link covers all insight tabs.

### Key Principles

- Public view must be **indistinguishable in quality** from the internal dashboard
- **Zero ability** to query, export, or drill into raw data on the public view
- Live data served via proxy endpoints (no snapshots)
- Same data shape as internal endpoints — restrictions enforced on the FE

### Scope

**In scope (V1.0):**
- Brand-level public link with toggle on/off
- Optional password protection
- All insight tabs accessible via a single slug
- Share modal UX identical to RAFI share

**Out of scope (deferred):**
- Module-level access control / show-hide per tab (V2.0)
- Link expiry dates (V2.0)
- View analytics (V2.0)

---

## 2. Architecture

```
Public User → /share/brand/[slug] (Next.js public page)
  → GET /v1/share/brand/{slug}/overview (Laravel — no auth, slug validation only)
    → DataServiceClient → ClickHouse (same data pipeline as internal dashboard)
```

This is a standalone system, independent from the existing shared workspace mechanism. It mirrors the RAFI share architecture but scoped to brand-level insights with live data.

---

## 3. Database

### New Table: `brand_share_settings`

| Column | Type | Default | Notes |
|--------|------|---------|-------|
| id | ULID | auto | Primary key |
| brand_id | ULID | — | FK to brands, unique |
| link_slug | string(6) | auto-generated | Unique 6-char token |
| link_enabled | boolean | false | Toggle on/off |
| link_is_protected | boolean | false | Password protection flag |
| link_password | string, nullable | null | Encrypted password |
| created_by | ULID, nullable | null | FK to users |
| created_at | timestamp | auto | |
| updated_at | timestamp | auto | |

**Indexes:** unique on `link_slug`, unique on `brand_id`

No snapshot/report table needed — all data is served live from ClickHouse via the data-service.

---

## 4. Backend (Laravel API)

### 4.1 Settings Endpoints (Authenticated)

These endpoints manage the share configuration. Requires user auth + brand access permissions.

**GET** `/v1/brands/{brandId}/share/settings`
- Returns current share settings for the brand
- Auto-generates a 6-char slug if none exists
- Response:
  ```json
  {
    "link": {
      "enabled": false,
      "url": "https://app.frnd.io/share/brand/aw3pfu",
      "is_protected": false
    }
  }
  ```

**PATCH** `/v1/brands/{brandId}/share/settings`
- Updates share settings (enable/disable, set/reset password)
- Payload:
  ```json
  {
    "link": {
      "enable": true,
      "password": "optional-password"
    }
  }
  ```
- Password validation: min 8 chars, at least 1 uppercase, at least 1 digit (same as RAFI)
- Setting password to non-empty sets `link_is_protected = true`
- Setting password to null/empty sets `link_is_protected = false`

### 4.2 Public Share Endpoints (No Auth)

These endpoints serve the public share page. No user authentication required — validated by slug only.

**GET** `/v1/share/brand/{slug}`
- Looks up `brand_share_settings` by slug
- Returns 404 if slug not found or link disabled
- If protected: returns `{ "is_protected": true, "brand_name": "..." }`
- If not protected: returns `{ "is_protected": false, "brand_id": "...", "brand_name": "..." }`

**POST** `/v1/share/brand/{slug}`
- Password validation for protected links
- Payload: `{ "password": "user-input" }`
- Returns 403 if incorrect
- Returns `{ "brand_id": "...", "brand_name": "..." }` on success

### 4.3 Public Proxy Endpoints (No Auth)

These endpoints proxy data from the data-service. Each validates the slug, extracts brand_id, then delegates to the same data-service calls used by existing internal controllers.

| Method | Endpoint | Proxies To |
|--------|----------|-----------|
| GET | `/v1/share/brand/{slug}/overview` | DataService overview |
| GET | `/v1/share/brand/{slug}/campaign` | DataService campaign |
| GET | `/v1/share/brand/{slug}/campaign/filters` | DataService campaign filters |
| GET | `/v1/share/brand/{slug}/paid-media/overview` | DataService paid media overview |
| GET | `/v1/share/brand/{slug}/paid-media/detail` | DataService paid media detail |
| GET | `/v1/share/brand/{slug}/owned-media/overview` | DataService owned media overview |
| GET | `/v1/share/brand/{slug}/owned-media/detail` | DataService owned media detail |
| GET | `/v1/share/brand/{slug}/earned-media` | DataService earned media |
| GET | `/v1/share/brand/{slug}/earned-media/influencers` | DataService earned media influencers |
| GET | `/v1/share/brand/{slug}/atl/overview` | DataService ATL overview |
| GET | `/v1/share/brand/{slug}/atl/detail` | DataService ATL detail |

**Slug validation middleware:** A shared middleware or trait that:
1. Looks up `brand_share_settings` by slug
2. Verifies `link_enabled = true`
3. If `link_is_protected = true`, verifies session/token (set after password validation)
4. Extracts `brand_id` and passes it to the controller method

**Data shape:** Returns the exact same response format as the internal endpoints. No fields stripped or filtered.

**Query params:** All filter params (dates, campaign names, funnels, regions, etc.) are passed through to the data-service, same as internal endpoints.

---

## 5. Frontend (Next.js)

### 5.1 Public Share Page Routes

```
web/src/app/share/brand/[slug]/
├── layout.tsx                    # Public layout — no sidebar, no auth header
├── page.tsx                      # Overview (default tab)
├── campaigns/
│   └── page.tsx
├── paid-media/
│   └── page.tsx
├── owned-media/
│   └── page.tsx
├── earned-media/
│   └── page.tsx
└── atl/
    └── page.tsx
```

### 5.2 Layout (`layout.tsx`)

- No sidebar, no user menu, no auth-dependent UI
- Brand name displayed in header (fetched from `/v1/share/brand/{slug}`)
- Tab navigation matching internal dashboard (Overview, Campaigns, Paid Media, etc.)
- Password wall (WallAccess component) if link is protected — blocks all content until password validated
- Stores validated session in state/cookie to avoid re-entering password per tab

### 5.3 Tab Pages

Each tab page reuses the **existing internal components** (e.g., `BrandInsightsOverview`, `CampaignContent`, `PaidMediaContent`, etc.) but:

- Wrapped in a `PublicShareContext` provider that:
  - Provides the slug
  - Swaps API calls to use `/v1/share/brand/{slug}/...` base URL instead of `/v1/brands/{brandId}/insight/...`
  - Sets `isPublicView = true` flag
- Components check `isPublicView` to conditionally hide:
  - Export/download buttons
  - "Ask FRND" AI assistant
  - Settings gear icon
  - Edit/pencil icon
  - Share button
- Components keep visible:
  - All charts, tables, metrics
  - Filter controls (date range, campaign selector, etc.)
  - Tab navigation

### 5.4 Share Modal (Internal Dashboard)

Added to the Brand Insights layout, triggered by the existing share icon:

- Same UX as RAFI Settings modal "Share Reports" tab
- Toggle: "Share link publicly"
- Shareable link field with copy button
- Password field with set/reset
- "Save Changes" button
- Calls `GET/PATCH /v1/brands/{brandId}/share/settings`

### 5.5 API Service Layer

New functions in `web/src/services/`:

```typescript
// query.ts
getBrandShareSettings(brandId: string)      // GET /v1/brands/{brandId}/share/settings
getBrandShareInfo(slug: string)             // GET /v1/share/brand/{slug}
getBrandShareOverview(slug: string, params)  // GET /v1/share/brand/{slug}/overview
getBrandShareCampaign(slug: string, params)  // GET /v1/share/brand/{slug}/campaign
// ... one per tab endpoint

// mutate.ts
updateBrandShareSettings(brandId, payload)   // PATCH /v1/brands/{brandId}/share/settings
validateBrandSharePassword(slug, password)   // POST /v1/share/brand/{slug}
```

---

## 6. Security Considerations

- Public proxy endpoints have **no user auth** — slug is the only access control
- Password-protected links use encrypted storage (same as RAFI)
- Password session: after successful validation, the BE returns a short-lived token (or sets a session cookie) that the FE sends with subsequent proxy requests. The slug validation middleware checks this token for protected links, so users don't re-enter the password per tab.
- Rate limiting on password validation endpoint to prevent brute force
- Public endpoints must not expose internal IDs beyond what's needed for rendering
- No export/download capability on public view (FE-enforced)
- CORS configuration must allow public share page origin

---

## 7. Testing Strategy

**BE:**
- Unit tests for `BrandShareController` (slug lookup, password validation, 404/403 cases)
- Unit tests for proxy endpoints (slug validation, data passthrough)
- Integration test: full flow from slug → data-service → response

**FE:**
- Component tests: public layout renders without auth UI
- Component tests: `isPublicView` correctly hides export/Ask FRND/settings
- E2E: public share page loads, tabs navigate, filters work
- E2E: password wall blocks access, correct password grants access
