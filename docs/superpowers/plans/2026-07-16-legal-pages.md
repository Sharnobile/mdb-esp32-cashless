# Legal Pages Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publicly reachable privacy policy, support, terms and imprint pages at `https://lagerapp.kerl.io/legal/*` — the App Store's required URLs.

**Architecture:** Four Nuxt pages under `app/pages/legal/`, text in the existing `i18n/locales/{en,de}.json` under a `legal.*` tree, one shared minimal layout component. `/legal` added to the auth middleware's public routes — without that single line, Apple's reviewer is redirected to login and the mandatory URL counts as dead.

**Tech Stack:** Nuxt 4, @nuxtjs/i18n (`no_prefix`), TailwindCSS 4.

**Spec:** `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §5

**Phase 3 of 6.**

---

## Content ground rules

The privacy policy describes what the system **actually does** — nothing more.
Verified surface (from the phase-1/2 audits):

- Account: e-mail + password via Supabase Auth (GoTrue), self-hosted.
- Operational data: the operator's own machines, sales, stock, cash book.
- Push: APNs device tokens, stored in `push_subscriptions`.
- Camera: barcode scanning **on-device only**, no image ever uploaded.
- No tracking, no analytics, no third-party ad/analytics SDKs.
- Backend is self-hosted by the operator (or hosted by Kerl Handel for its
  own instance) — the policy must not claim a cloud provider it doesn't use.
- Account deletion: in-app (phase 2), erases the account; a sole admin's
  deletion erases the company data. Cash-book retention: **pending the user's
  tax advisor** — the policy text takes the safe line ("legal retention duties
  may require keeping accounting records") which is true under either outcome.

**Placeholders the user must fill** (marked `[AUSFÜLLEN: …]` in the de text and
`[FILL IN: …]` in en, loud enough that shipping them unfilled is embarrassing):
company legal name + address, represented-by, USt-IdNr./HRB if applicable,
contact e-mail for support and privacy requests.

**Not legal advice.** The texts are a structurally complete starting point
(GDPR Art. 13 items: controller, purposes, legal bases, recipients, retention,
data-subject rights incl. Art. 17, supervisory-authority complaint right; TMG §5
imprint items). The user should have them checked before submission — noted in
the final report, not silently assumed fine.

## Tasks

### Task 1: Pages + layout

**Files:**
- Create: `management-frontend/app/pages/legal/privacy.vue`
- Create: `management-frontend/app/pages/legal/support.vue`
- Create: `management-frontend/app/pages/legal/terms.vue`
- Create: `management-frontend/app/pages/legal/imprint.vue`
- Create: `management-frontend/app/components/legal/LegalPage.vue` (shared shell)

- [ ] Each page: `definePageMeta({ layout: false })` (pattern: `app/pages/install.vue:2`),
  wraps content in `LegalPage` (title, prose styling, footer links to the other
  three pages + a small language toggle via `useI18n().setLocale`).
- [ ] Content rendered from i18n keys; long passages as arrays of paragraphs
  (`t('legal.privacy.sections')` iterated), not one giant string.
- [ ] Support page: contact e-mail placeholder, link to the imprint, and a short
  FAQ (login problems, how to get an account — invite-only note, how to delete
  the account — points at the in-app path, matching 5.1.1(v)).

### Task 2: i18n text

**Files:**
- Modify: `management-frontend/i18n/locales/en.json` (add `legal.*`)
- Modify: `management-frontend/i18n/locales/de.json` (add `legal.*`)

- [ ] German first (authoritative for Impressum/DSGVO), English as faithful
  translation. Placeholders as specified above.
- [ ] JSON validity: `python3 -c "import json; json.load(open('i18n/locales/de.json'))"`
  for both files. Insert keys surgically; do not reformat the files.

### Task 3: Public routing — the one line that decides everything

**Files:**
- Modify: `management-frontend/app/middleware/auth.ts`

- [ ] Add to the prefix block (after the `/m` handling, matching its comment style):

```ts
  // Public legal pages (App Store privacy/support URLs — reviewers are not logged in)
  if (to.path.startsWith('/legal')) {
    return
  }
```

### Task 4: Verify

- [ ] `npm run dev` (or the existing preview server), then **logged out**:
  `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/legal/privacy`
  → `200` for all four pages. A redirect to `/auth/login` fails the task.
- [ ] Render check in the browser: both locales, dark + light, no missing-key
  warnings in the console.
- [ ] `npx vitest run` stays green.
- [ ] Commit (paths only, never `-A`): the four pages, `LegalPage.vue`, both
  locale files, `auth.ts`.

## Done when

- All four URLs return 200 logged-out on the dev server
- Privacy text contains every GDPR Art. 13 item and nothing the system doesn't do
- Placeholders are loud and listed in the report to the user
- `npx vitest run` green

## Out of scope

Deploying to `lagerapp.kerl.io` (the user's normal deploy flow does that);
having the texts legally reviewed (explicitly the user's job, flagged in the
report); linking the pages from the app UI (optional, later).
