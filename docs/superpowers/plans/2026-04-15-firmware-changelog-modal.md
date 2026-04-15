# Firmware Changelog Modal Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rows in the Firmware Versions and GitHub Releases tables on `/firmware` clickable to open a modal showing the full changelog (rendered Markdown for GitHub-sourced content, plain text for manual uploads).

**Architecture:** Add a single reusable changelog modal to `app/pages/firmware/index.vue`. Extend `useFirmware` with a session cache + on-demand GitHub API fetch for tags that aren't in the already-loaded `githubReleases` array (covers imported firmware whose matching release is outside the default 30-release fetch window). Render Markdown via `marked` + sanitize with `dompurify`; style via `@tailwindcss/typography`'s `prose` utility. Graceful fallbacks at every layer: missing body → "no changelog", failed fetch → show stored `notes` + warning, missing repo config → show `notes` only.

**Tech Stack:** Nuxt 4 (Vue 3 Composition API, `<script setup lang="ts">`), TailwindCSS 4, existing `AppModal` (wraps reka-ui Dialog), `marked` (new dep), `dompurify` (new dep), `@tailwindcss/typography` (new dep), `@nuxtjs/i18n` (en/de).

**Scope boundaries:**
- Only the `/firmware` page is touched. No DB migrations. No edge function changes. No MQTT/firmware protocol changes.
- Admin-only `/firmware` route; no additional authz needed.
- Backward-compatible: rows without `source_tag` or where `githubRepo` is not configured fall back to showing `notes` verbatim.

---

## Chunk 1: Dependencies + Tailwind Typography

### Task 1: Install Markdown, sanitization, and typography dependencies

**Files:**
- Modify: `management-frontend/package.json`
- Modify: `management-frontend/package-lock.json` (via npm)
- Modify: `management-frontend/app/assets/css/tailwind.css`

- [ ] **Step 1: Install runtime deps**

Run (from `management-frontend/`):
```bash
npm install marked dompurify
npm install --save-dev @types/dompurify @tailwindcss/typography
```

Expected: three packages added to `dependencies`, two to `devDependencies`. `marked` v15+, `dompurify` v3+, `@tailwindcss/typography` v0.5+.

Note: `marked` ships its own TypeScript types; no `@types/marked` needed.

- [ ] **Step 2: Register the typography plugin in Tailwind CSS 4**

Tailwind 4 uses `@plugin` inside the CSS entry file (not `tailwind.config.js`). Edit `management-frontend/app/assets/css/tailwind.css` and add the plugin import near the top, right after the `tw-animate-css` import:

```css
@import "tailwindcss";
@import "tw-animate-css";
@plugin "@tailwindcss/typography";

@custom-variant dark (&:is(.dark *));
```

- [ ] **Step 3: Verify Nuxt dev server still builds**

Run (from `management-frontend/`):
```bash
npm run dev
```

Expected: dev server starts without error. Stop it once you see `Local:   http://localhost:3000/`.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/package.json management-frontend/package-lock.json management-frontend/app/assets/css/tailwind.css
git commit -m "feat(frontend): add marked, dompurify, and typography plugin for changelog rendering"
```

---

## Chunk 2: i18n keys

### Task 2: Add translation keys for the changelog modal

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 1: Add English keys**

Open `management-frontend/i18n/locales/en.json`, locate the `firmware` object (starts around line 689), and add these keys inside the existing `firmware` block (before the closing `}` of that block, comma-separating as needed):

```json
    "changelogTitle": "Changelog",
    "viewOnGitHub": "View on GitHub",
    "noChangelog": "No changelog provided.",
    "loadingChangelog": "Loading changelog…",
    "changelogFetchFailed": "Changelog could not be loaded from GitHub. Showing the stored notes instead.",
    "changelogReleaseName": "Release",
    "changelogPublished": "Published",
    "changelogManualUpload": "Manual upload — no changelog from GitHub. Showing stored notes.",
    "noNotes": "No notes."
```

- [ ] **Step 2: Add German keys**

Open `management-frontend/i18n/locales/de.json`, locate the same `firmware` object, add:

```json
    "changelogTitle": "Changelog",
    "viewOnGitHub": "Auf GitHub öffnen",
    "noChangelog": "Kein Changelog verfügbar.",
    "loadingChangelog": "Lade Changelog…",
    "changelogFetchFailed": "Changelog konnte nicht von GitHub geladen werden. Stattdessen werden die gespeicherten Notizen angezeigt.",
    "changelogReleaseName": "Release",
    "changelogPublished": "Veröffentlicht",
    "changelogManualUpload": "Manueller Upload — kein Changelog von GitHub. Gespeicherte Notizen werden angezeigt.",
    "noNotes": "Keine Notizen."
```

- [ ] **Step 3: Verify JSON is still valid**

Run (from repo root):
```bash
node -e "JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/en.json','utf8')); JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/de.json','utf8')); console.log('ok')"
```

Expected: `ok` printed. If a SyntaxError is thrown, fix the trailing comma / brace placement in whichever file failed.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(i18n): add firmware changelog modal translation keys"
```

---

## Chunk 3: useFirmware composable — changelog resolution

### Task 3: Add release-body cache and `fetchReleaseByTag` helper

**Files:**
- Modify: `management-frontend/app/composables/useFirmware.ts`

The current `useFirmware` composable already holds `githubReleases: Ref<GitHubRelease[]>` populated via `fetchGitHubReleases()`. We need:
1. A session-lifetime `Map<string, GitHubRelease | null>` cache keyed by tag name (stores `null` for known-missing tags to avoid repeat 404s).
2. A `fetchReleaseByTag(tag)` helper that returns a `GitHubRelease` if found in `githubReleases`, else in the cache, else fetches `GET https://api.github.com/repos/{repo}/releases/tags/{tag}` and caches the result.
3. A `getChangelogForFirmware(fw)` helper that returns a discriminated `ChangelogSource` object. This keeps markdown-vs-plaintext routing and fallback decisions in one place so the Vue template stays dumb.

- [ ] **Step 1: Add the `ChangelogSource` type + cache ref near the top of `useFirmware`**

Open `management-frontend/app/composables/useFirmware.ts`. After the existing `GitHubAsset` interface (ends around line 30), add this exported type:

```ts
export interface ChangelogSource {
  /** Which data source the body came from. */
  kind: 'github-release' | 'notes' | 'none'
  /** The raw markdown/plaintext body to render. Empty string when kind === 'none'. */
  body: string
  /** Whether to render as Markdown (true) or plain text with preserved whitespace (false). */
  isMarkdown: boolean
  /** Release name if different from tag (GitHub sources only). */
  releaseName?: string
  /** ISO timestamp the GitHub release was published (GitHub sources only). */
  publishedAt?: string
  /** Assets on the release (GitHub sources only). */
  assets?: GitHubAsset[]
  /** External URL (GitHub html_url for releases, null for manual uploads). */
  externalUrl?: string
  /** Populated when a GitHub fetch was attempted and failed; triggers a "fetch failed" banner. */
  fetchFailed?: boolean
}
```

Then inside the `useFirmware` function body, directly after the `githubLoading = ref(false)` line (currently line 43), add:

```ts
  // Session cache for individual release lookups by tag (covers tags outside the 30-release default window).
  // Stores `null` to remember 404s and avoid re-fetching known-missing releases.
  const releaseBodyCache = ref<Map<string, GitHubRelease | null>>(new Map())
```

- [ ] **Step 2: Add the `fetchReleaseByTag` helper**

Inside `useFirmware`, after the existing `fetchGitHubReleases` function (ends around line 156), add:

```ts
  /**
   * Return a GitHubRelease for the given tag, preferring:
   *   1. the already-loaded `githubReleases` array,
   *   2. the session cache,
   *   3. a single on-demand GitHub API call.
   *
   * Returns `null` if the repo is not configured, the tag does not exist on GitHub,
   * or the network fails. Null results are cached to avoid repeat 404s in the same session.
   */
  async function fetchReleaseByTag(tag: string): Promise<GitHubRelease | null> {
    if (!githubRepo.value || !tag) return null

    // 1) Already loaded via fetchGitHubReleases()
    const loaded = githubReleases.value.find(r => r.tag_name === tag)
    if (loaded) return loaded

    // 2) Cache hit (including negative cache)
    if (releaseBodyCache.value.has(tag)) {
      return releaseBodyCache.value.get(tag) ?? null
    }

    // 3) On-demand fetch
    try {
      const res = await $fetch<GitHubRelease>(
        `https://api.github.com/repos/${githubRepo.value}/releases/tags/${encodeURIComponent(tag)}`,
        { headers: { Accept: 'application/vnd.github.v3+json' } },
      )
      releaseBodyCache.value.set(tag, res)
      return res
    } catch (e) {
      console.warn(`[useFirmware] Failed to fetch GitHub release for tag "${tag}":`, e)
      releaseBodyCache.value.set(tag, null)
      return null
    }
  }
```

- [ ] **Step 3: Add the `getChangelogForFirmware` helper**

Right after `fetchReleaseByTag`, add:

```ts
  /**
   * Resolve the changelog to display for a given firmware_versions row.
   *
   *  - GitHub-sourced firmware → try to find/fetch the release; on success return Markdown.
   *    On failure (deleted release, rate-limited, offline), fall back to the stored `notes` field
   *    (500-char truncation is acceptable as a fallback) and set `fetchFailed: true` so the UI can
   *    render a banner above the body.
   *  - Manual uploads → always plaintext `notes`.
   */
  async function getChangelogForFirmware(fw: FirmwareVersion): Promise<ChangelogSource> {
    if (fw.source_type === 'github' && fw.source_tag) {
      const release = await fetchReleaseByTag(fw.source_tag)
      if (release) {
        return {
          kind: 'github-release',
          body: release.body ?? '',
          isMarkdown: true,
          releaseName: release.name && release.name !== release.tag_name ? release.name : undefined,
          publishedAt: release.published_at,
          assets: release.assets,
          externalUrl: release.html_url,
        }
      }
      // Fall back to stored notes with a "fetch failed" banner
      return {
        kind: fw.notes ? 'notes' : 'none',
        body: fw.notes ?? '',
        isMarkdown: false,
        fetchFailed: true,
        externalUrl: githubRepo.value
          ? `https://github.com/${githubRepo.value}/releases/tag/${encodeURIComponent(fw.source_tag)}`
          : undefined,
      }
    }

    // Manual upload (or anything else)
    return {
      kind: fw.notes ? 'notes' : 'none',
      body: fw.notes ?? '',
      isMarkdown: false,
    }
  }
```

- [ ] **Step 4: Export the new helpers from the composable**

Modify the `return` block at the end of `useFirmware` to also include `fetchReleaseByTag` and `getChangelogForFirmware`. The full updated return block:

```ts
  return {
    firmwareVersions,
    loading,
    fetchFirmwareVersions,
    uploadFirmware,
    triggerOta,
    triggerOtaBatch,
    deleteFirmwareVersion,
    // GitHub integration
    githubRepo,
    githubReleases,
    githubLoading,
    fetchGitHubReleases,
    importGitHubRelease,
    isReleaseImported,
    // Changelog
    fetchReleaseByTag,
    getChangelogForFirmware,
  }
```

- [ ] **Step 5: Typecheck the composable**

Run (from `management-frontend/`):
```bash
npx vue-tsc --noEmit
```

Expected: exits 0 with no new errors in `useFirmware.ts`. (If there are pre-existing errors elsewhere, note them but don't fix in this task.)

- [ ] **Step 6: Commit**

```bash
git add management-frontend/app/composables/useFirmware.ts
git commit -m "feat(firmware): add getChangelogForFirmware + on-demand release-by-tag fetch"
```

---

## Chunk 4: Markdown rendering utility

### Task 4: Create a small, sanitized Markdown renderer helper

**Files:**
- Create: `management-frontend/app/lib/markdown.ts`
- Create: `management-frontend/app/lib/__tests__/markdown.test.ts`

Keep the marked + DOMPurify wiring out of the page component so it can be reused and unit-tested. Configure `marked` with GitHub-like defaults (line breaks, GFM) and run everything through DOMPurify with the default profile, which strips `<script>`, event handlers, and javascript: URLs.

- [ ] **Step 1: Write the failing test**

Create `management-frontend/app/lib/__tests__/markdown.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { renderMarkdown } from '../markdown'

describe('renderMarkdown', () => {
  it('renders basic markdown to HTML', () => {
    const html = renderMarkdown('# Hello\n\n**bold** and *italic*')
    expect(html).toContain('<h1')
    expect(html).toContain('Hello')
    expect(html).toContain('<strong>bold</strong>')
    expect(html).toContain('<em>italic</em>')
  })

  it('renders GitHub-style bullet lists', () => {
    const html = renderMarkdown('- first\n- second')
    expect(html).toContain('<ul>')
    expect(html).toContain('<li>first</li>')
    expect(html).toContain('<li>second</li>')
  })

  it('converts single newlines to <br> (GFM breaks)', () => {
    const html = renderMarkdown('line one\nline two')
    expect(html).toContain('<br>')
  })

  it('strips <script> tags', () => {
    const html = renderMarkdown('safe <script>alert(1)</script> text')
    expect(html).not.toContain('<script')
    expect(html).not.toContain('alert(1)')
  })

  it('strips inline event handlers', () => {
    const html = renderMarkdown('<a href="https://example.com" onclick="alert(1)">link</a>')
    expect(html).not.toContain('onclick')
  })

  it('strips javascript: URLs', () => {
    const html = renderMarkdown('[evil](javascript:alert(1))')
    expect(html).not.toMatch(/href=["']javascript:/)
  })

  it('returns empty string for empty input', () => {
    expect(renderMarkdown('')).toBe('')
    expect(renderMarkdown(null as unknown as string)).toBe('')
    expect(renderMarkdown(undefined as unknown as string)).toBe('')
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `management-frontend/`):
```bash
npx vitest run app/lib/__tests__/markdown.test.ts
```

Expected: FAIL — `Cannot find module '../markdown'`.

- [ ] **Step 3: Implement `renderMarkdown`**

Create `management-frontend/app/lib/markdown.ts`:

```ts
import { marked } from 'marked'
import DOMPurify from 'dompurify'

// Configure marked once at module load.
// - gfm: enable GitHub-flavored Markdown (tables, strikethrough, task lists)
// - breaks: treat single newlines as <br>, matching how GitHub renders release notes
// - async: false keeps parse synchronous so we can return a string
marked.setOptions({
  gfm: true,
  breaks: true,
  async: false,
})

/**
 * Render a Markdown string to sanitized HTML.
 * Safe to use with `v-html` — output is passed through DOMPurify's default profile,
 * which removes <script>, inline event handlers, and javascript: URLs.
 *
 * Returns an empty string for null/undefined/empty input.
 */
export function renderMarkdown(source: string | null | undefined): string {
  if (!source) return ''
  const raw = marked.parse(source) as string
  return DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } })
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from `management-frontend/`):
```bash
npx vitest run app/lib/__tests__/markdown.test.ts
```

Expected: all 7 tests pass.

**If happy-dom is missing a DOMPurify dependency:** DOMPurify needs a DOM window. The project's `vitest.config.ts` uses `environment: 'happy-dom'`, which provides one. If DOMPurify errors with "DOMPurify needs a Window object", add `import DOMPurify from 'dompurify'` and confirm happy-dom is active in the test config.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/lib/markdown.ts management-frontend/app/lib/__tests__/markdown.test.ts
git commit -m "feat(frontend): add sanitized renderMarkdown helper"
```

---

## Chunk 5: Changelog modal — structure + data plumbing

### Task 5: Add modal state and open/close handlers on the firmware page

**Files:**
- Modify: `management-frontend/app/pages/firmware/index.vue`

This task wires up state and handlers without any template changes yet — we want the JS to compile before we start refactoring the template.

- [ ] **Step 1: Import the helpers and types**

Open `management-frontend/app/pages/firmware/index.vue`. The existing imports section (lines ~3–6 of `<script setup>`) currently imports `timeAgo`, `formatDateTime`, `Checkbox`, `Badge`. Add:

```ts
import { renderMarkdown } from '@/lib/markdown'
import type { FirmwareVersion, GitHubRelease, ChangelogSource } from '@/composables/useFirmware'
```

- [ ] **Step 2: Pull the two new helpers out of `useFirmware`**

Find the `useFirmware()` destructure (around line 10–15). Add `getChangelogForFirmware` to the destructured list:

```ts
const {
  firmwareVersions, loading, fetchFirmwareVersions,
  uploadFirmware, triggerOta, triggerOtaBatch, deleteFirmwareVersion,
  githubRepo, githubReleases, githubLoading,
  fetchGitHubReleases, importGitHubRelease, isReleaseImported,
  getChangelogForFirmware,
} = useFirmware()
```

- [ ] **Step 3: Add modal state**

After the existing `const deleteLoading = ref<string | null>(null)` line (currently around line 234), add a new section — keep it below the OTA section and above the GitHub import section:

```ts
// ── Changelog modal ──────────────────────────────────────────────────────────
const showChangelogModal = ref(false)
const changelogTitle = ref('')
const changelogLoading = ref(false)
const changelog = ref<ChangelogSource | null>(null)

/** Open modal for an imported firmware row. */
async function openChangelogForFirmware(fw: FirmwareVersion) {
  changelogTitle.value = fw.version_label
  changelog.value = null
  changelogLoading.value = true
  showChangelogModal.value = true
  try {
    changelog.value = await getChangelogForFirmware(fw)
  } finally {
    changelogLoading.value = false
  }
}

/** Open modal for a GitHub release row (body already loaded in githubReleases). */
function openChangelogForRelease(release: GitHubRelease) {
  changelogTitle.value = release.tag_name
  changelogLoading.value = false
  showChangelogModal.value = true
  changelog.value = {
    kind: release.body ? 'github-release' : 'none',
    body: release.body ?? '',
    isMarkdown: true,
    releaseName: release.name && release.name !== release.tag_name ? release.name : undefined,
    publishedAt: release.published_at,
    assets: release.assets,
    externalUrl: release.html_url,
  }
}

function closeChangelogModal() {
  showChangelogModal.value = false
}

/** Rendered HTML of the changelog body, memoized per current body value. */
const changelogHtml = computed(() => {
  if (!changelog.value) return ''
  if (!changelog.value.isMarkdown) return ''
  return renderMarkdown(changelog.value.body)
})
```

- [ ] **Step 4: Typecheck**

Run (from `management-frontend/`):
```bash
npx vue-tsc --noEmit
```

Expected: no new errors in `firmware/index.vue`. (If `vue-tsc` reports issues unrelated to this change, flag but don't fix.)

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/pages/firmware/index.vue
git commit -m "feat(firmware): add changelog modal state and open/close handlers"
```

---

## Chunk 6: Wire click handlers into the two tables

### Task 6: Make Firmware Versions table rows clickable

**Files:**
- Modify: `management-frontend/app/pages/firmware/index.vue`

The rows currently live in the `sortedFirmwareVersions` `v-for` at roughly lines 323–367. We add `@click="openChangelogForFirmware(fw)"` to the `<tr>`, add `cursor-pointer`, and add `@click.stop` to the Deploy/Delete buttons so they don't also open the modal. We leave the Source badge, cells, etc. unchanged.

- [ ] **Step 1: Update the `<tr>` element**

Find the existing row (around line 323):

```vue
<tr
  v-for="fw in sortedFirmwareVersions"
  :key="fw.id"
  class="border-b last:border-0 hover:bg-muted/30 transition-colors"
>
```

Replace with:

```vue
<tr
  v-for="fw in sortedFirmwareVersions"
  :key="fw.id"
  class="border-b last:border-0 hover:bg-muted/30 transition-colors cursor-pointer"
  @click="openChangelogForFirmware(fw)"
>
```

- [ ] **Step 2: Add `@click.stop` to the action buttons**

Find the two admin action buttons inside this row (around lines 351–364). Change the handlers from `@click="..."` to `@click.stop="..."`:

```vue
<button
  class="text-xs text-primary hover:underline"
  @click.stop="openOtaModal(fw.id)"
>
  {{ t('common.deploy') }}
</button>
<button
  class="text-xs text-destructive hover:underline"
  :disabled="deleteLoading === fw.id"
  @click.stop="handleDelete(fw)"
>
  {{ deleteLoading === fw.id ? t('common.deleting') : t('common.delete') }}
</button>
```

- [ ] **Step 3: Manual smoke test**

Run (from `management-frontend/`):
```bash
npm run dev
```

Open `http://localhost:3000/firmware`. Log in as an admin. Click on any imported firmware row.

Expected: the existing console has no new errors. The modal isn't visible yet (no template in Chunk 7), but `showChangelogModal` should flip to `true` — you can verify by opening Vue devtools. Click the Deploy button on a row and confirm the OTA modal still opens *without* the changelog triggering. Click Delete and confirm the delete proceeds without the changelog triggering.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/firmware/index.vue
git commit -m "feat(firmware): make firmware version rows clickable for changelog"
```

### Task 7: Make GitHub Releases table rows clickable, move tag link into modal

**Files:**
- Modify: `management-frontend/app/pages/firmware/index.vue`

The releases rows currently live in the `v-for="release in githubReleases"` block at roughly lines 420–459. The `tag_name` is currently rendered as an `<a href=release.html_url target="_blank">` that would conflict with the row click. We change it to a plain span — the "View on GitHub" link moves into the modal.

- [ ] **Step 1: Update the `<tr>` element**

Find the row:

```vue
<tr
  v-for="asset in release.assets.filter(a => a.name.endsWith('.bin'))"
  :key="`${release.tag_name}-${asset.name}`"
  class="border-b last:border-0 hover:bg-muted/30 transition-colors"
>
```

Replace with:

```vue
<tr
  v-for="asset in release.assets.filter(a => a.name.endsWith('.bin'))"
  :key="`${release.tag_name}-${asset.name}`"
  class="border-b last:border-0 hover:bg-muted/30 transition-colors cursor-pointer"
  @click="openChangelogForRelease(release)"
>
```

- [ ] **Step 2: Replace the external tag link with a plain span**

Find the existing tag cell (around lines 426–436):

```vue
<td class="px-4 py-3">
  <a
    :href="release.html_url"
    target="_blank"
    rel="noopener"
    class="font-mono font-medium text-primary hover:underline"
  >{{ release.tag_name }}</a>
  <p v-if="release.name && release.name !== release.tag_name" class="text-xs text-muted-foreground truncate max-w-[200px]">
    {{ release.name }}
  </p>
</td>
```

Replace with:

```vue
<td class="px-4 py-3">
  <span class="font-mono font-medium">{{ release.tag_name }}</span>
  <p v-if="release.name && release.name !== release.tag_name" class="text-xs text-muted-foreground truncate max-w-[200px]">
    {{ release.name }}
  </p>
</td>
```

- [ ] **Step 3: Add `@click.stop` to the Import / Imported buttons**

Find the admin action buttons (around lines 443–457). The "Imported" button is `disabled` so doesn't need `.stop`, but we add it anyway for consistency. Update the Import button:

```vue
<button
  v-if="isReleaseImported(release.tag_name)"
  disabled
  class="inline-flex h-7 items-center rounded-md border px-3 text-xs font-medium text-muted-foreground opacity-60"
  @click.stop
>
  {{ t('firmware.imported') }}
</button>
<button
  v-else
  class="inline-flex h-7 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90 disabled:opacity-50"
  :disabled="importLoading === release.tag_name"
  @click.stop="handleImport(release.tag_name, asset.name)"
>
  {{ importLoading === release.tag_name ? t('firmware.importing') : t('common.import') }}
</button>
```

- [ ] **Step 4: Manual smoke test**

Run `npm run dev`, open `/firmware`. Click on a GitHub release row — `showChangelogModal` flips to `true`. Click Import — the import fires without opening the changelog. The tag name is no longer an external link.

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/pages/firmware/index.vue
git commit -m "feat(firmware): make GitHub release rows clickable; move tag link into modal"
```

---

## Chunk 7: Changelog modal template

### Task 8: Render the modal template

**Files:**
- Modify: `management-frontend/app/pages/firmware/index.vue`

Add the modal template after the closing `</AppModal>` of the OTA modal (the last modal in the file). The modal needs to handle four display states: loading spinner, fetch-failed banner + notes, empty state, and Markdown body. Use the existing `AppModal size="lg"` component. Render the body through `v-html="changelogHtml"` inside a `<div class="prose prose-sm dark:prose-invert max-w-none">` wrapper.

- [ ] **Step 1: Append the modal at the bottom of `<template>`**

Find the closing `</AppModal>` of the OTA modal (near the very end of the template block, just before the final `</template>`). Immediately after it (still inside the root `<template>` or root `<div>` — check the existing structure — the existing modals are placed outside the main content `<div>` but inside the top-level `<template>`), insert:

```vue
  <!-- Changelog modal -->
  <AppModal
    :open="showChangelogModal"
    :title="t('firmware.changelogTitle') + ': ' + changelogTitle"
    size="lg"
    @update:open="(v: boolean) => { if (!v) closeChangelogModal() }"
  >
    <div class="space-y-4">
      <!-- Loading state -->
      <div v-if="changelogLoading" class="py-8 text-center text-sm text-muted-foreground">
        {{ t('firmware.loadingChangelog') }}
      </div>

      <template v-else-if="changelog">
        <!-- Fetch-failed banner -->
        <div
          v-if="changelog.fetchFailed"
          class="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-700 dark:bg-amber-950/40 dark:text-amber-200"
        >
          {{ t('firmware.changelogFetchFailed') }}
        </div>

        <!-- Meta row: release name + published date + assets -->
        <div v-if="changelog.releaseName || changelog.publishedAt" class="space-y-1 text-xs text-muted-foreground">
          <p v-if="changelog.releaseName">
            <span class="font-medium">{{ t('firmware.changelogReleaseName') }}:</span>
            {{ changelog.releaseName }}
          </p>
          <p v-if="changelog.publishedAt">
            <span class="font-medium">{{ t('firmware.changelogPublished') }}:</span>
            <span :title="formatDateTime(changelog.publishedAt)">{{ timeAgo(changelog.publishedAt, t) }}</span>
          </p>
          <p v-if="changelog.assets && changelog.assets.length > 0" class="flex flex-wrap gap-1">
            <span
              v-for="asset in changelog.assets.filter(a => a.name.endsWith('.bin'))"
              :key="asset.name"
              class="inline-flex items-center rounded bg-muted px-1.5 py-0.5 font-mono"
            >
              {{ asset.name }} ({{ formatSize(asset.size) }})
            </span>
          </p>
        </div>

        <!-- Body -->
        <div v-if="changelog.kind === 'none'" class="py-4 text-sm italic text-muted-foreground">
          {{ t('firmware.noChangelog') }}
        </div>
        <div
          v-else-if="changelog.isMarkdown"
          class="prose prose-sm dark:prose-invert max-w-none"
          v-html="changelogHtml"
        />
        <div v-else class="whitespace-pre-wrap text-sm">{{ changelog.body }}</div>
      </template>
    </div>

    <template #footer>
      <a
        v-if="changelog?.externalUrl"
        :href="changelog.externalUrl"
        target="_blank"
        rel="noopener"
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
      >
        {{ t('firmware.viewOnGitHub') }} ↗
      </a>
      <button
        type="button"
        class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
        @click="closeChangelogModal"
      >
        {{ t('common.close') }}
      </button>
    </template>
  </AppModal>
```

- [ ] **Step 2: Verify `common.close` exists in i18n**

Run (from repo root):
```bash
grep -n '"close"' management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
```

Expected: at least one hit per file inside the `common` block. If missing, add `"close": "Close"` / `"close": "Schließen"` to the `common` section.

- [ ] **Step 3: Typecheck**

Run (from `management-frontend/`):
```bash
npx vue-tsc --noEmit
```

Expected: exits 0 with no new errors.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/firmware/index.vue management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(firmware): render changelog modal with loading, error, and markdown states"
```

---

## Chunk 8: Manual verification

### Task 9: End-to-end smoke test in the browser

**Files:**
- None modified (verification only)

The `/firmware` page is admin-only, requires a running Supabase backend, and needs at least one firmware row to exercise the changelog. Use the `preview_start` / `preview_*` tools per the `preview_tools` workflow baked into the harness — do NOT ask the user to click through manually.

- [ ] **Step 1: Create `.claude/launch.json` entry if missing**

Check for an existing launch config:
```bash
cat .claude/launch.json 2>/dev/null
```

If it lacks a management-frontend entry, create or update `.claude/launch.json`:
```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "management-frontend",
      "runtimeExecutable": "npm",
      "runtimeArgs": ["--prefix", "management-frontend", "run", "dev"],
      "port": 3000
    }
  ]
}
```

- [ ] **Step 2: Start the dev server**

Use `preview_start` with `name: "management-frontend"`.

Expected: server starts on `http://localhost:3000`. The local Supabase must already be running (`cd Docker/supabase && supabase start`) — if the page shows `/server-loading`, start Supabase first.

- [ ] **Step 3: Log in and navigate to /firmware**

Use `preview_eval` to set a session, or `preview_fill` to enter dev credentials on `/auth/login`. (Dev credentials are in the memory file `user_dev_credentials.md` — read that before this step.) Then navigate to `/firmware`.

Use `preview_console_logs { level: "error" }` to verify no errors during page load.

- [ ] **Step 4: Verify firmware row click → modal opens**

If there is at least one imported firmware:
- `preview_click` on the first row's version cell
- `preview_snapshot` and confirm the dialog with role="dialog" contains "Changelog: <version>"
- For a GitHub-sourced firmware, confirm the body is rendered HTML (look for `<h1>`, `<ul>` in the DOM via `preview_eval "document.querySelector('.prose')?.innerHTML"`) and the "View on GitHub" footer link is present
- For a manual upload, confirm `<div class="whitespace-pre-wrap">` contains the notes text

If there are no imported firmwares, skip this step and note it in the completion report.

- [ ] **Step 5: Verify GitHub release row click → modal opens**

If `githubFirmwareRepo` is configured and the releases table is non-empty:
- Use `preview_click` on the first release row
- Confirm the modal opens with the tag name in the title
- Confirm `<a href="...github.com...">View on GitHub</a>` is in the footer

- [ ] **Step 6: Verify action buttons don't open the changelog**

- `preview_click` on the Deploy button of an imported firmware row
- Confirm the OTA modal opens (not the changelog)
- Close it, `preview_click` the Import button on a not-yet-imported release row
- Confirm the import flow runs without the changelog modal opening

- [ ] **Step 7: Verify empty / missing states**

If possible, force a fetch failure by:
- Finding an imported firmware whose `source_tag` you can tweak in-memory via `preview_eval` to a non-existent tag, OR
- If no such firmware exists, fabricate one by calling `openChangelogForFirmware` on a mock — use `preview_eval` to call the exposed method

Confirm the amber "fetch failed" banner appears and the `notes` text is shown as fallback.

- [ ] **Step 8: Screenshot for the commit**

`preview_screenshot` the modal open against a GitHub-sourced firmware with a non-trivial body. This is for your own verification; the image is not committed.

- [ ] **Step 9: Mark verification complete**

No commit. Report in the task handoff: which rows you exercised, any issues found, and what, if anything, you couldn't verify (e.g. "no GitHub-sourced firmware present in dev DB").

---

## Implementation Checklist Summary

Order of tasks: **1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9**. Each task commits independently so the branch can be reviewed commit-by-commit.

- Task 1: deps + tailwind typography
- Task 2: i18n keys
- Task 3: `useFirmware` — cache + `fetchReleaseByTag` + `getChangelogForFirmware`
- Task 4: `renderMarkdown` helper + unit tests
- Task 5: modal state on `firmware/index.vue`
- Task 6: firmware versions table — row click + `.stop` on actions
- Task 7: GitHub releases table — row click + `.stop` on actions + remove external tag link
- Task 8: modal template
- Task 9: browser smoke test via `preview_*` tools

## Non-Goals (do not implement)

- Caching release bodies into the DB — the session-lifetime `Map` is enough; the page is admin-only and low-traffic.
- Extending the `import-github-release` function to store the full body — backward-compat concern, and the on-demand fetch covers the display need.
- Adding a "Refresh changelog" button — if the cache goes stale, reload the page.
- Rendering changelog on `/machines/[id]` or any other page — out of scope for this change.
- Adding the typography plugin's `@tailwindcss/typography` colors/prose-override theme — stock `prose` + `prose-sm` + `dark:prose-invert` is fine for this modal.
