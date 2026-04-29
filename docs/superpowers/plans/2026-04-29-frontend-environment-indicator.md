# Frontend Environment Indicator Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a sticky colored top banner on every page of the management-frontend in non-production deployments, configured at runtime so a single Docker image can deploy to dev / test / staging / prod without rebuilding.

**Architecture:** Three small units — a pure `useEnvironment()` composable, a self-contained `EnvironmentBanner.vue` component, and one mount point in `app.vue`. Configuration arrives via two `NUXT_PUBLIC_*` env vars (`ENV_NAME`, `ENV_COLOR`), wired through `runtimeConfig.public` in `nuxt.config.ts` and forwarded by `Docker/docker-compose.yml`. `setup.sh` gains an interactive prompt; `update.sh` only appends a documented but commented-out `.env` section so existing prod deployments keep their current behavior.

**Tech Stack:** Nuxt 4 (composables, components, runtimeConfig), Tailwind 4 (static class map for JIT), `@tabler/icons-vue` (`IconAlertTriangle`), Vitest + `@vue/test-utils` + `happy-dom` for tests, bash for setup/update scripts.

**Spec:** [docs/superpowers/specs/2026-04-29-frontend-environment-indicator-design.md](../specs/2026-04-29-frontend-environment-indicator-design.md)

**Working directory:** all paths below are relative to the repo root `/Users/lucienkerl/Development/mdb-esp32-cashless` unless noted.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `management-frontend/app/composables/useEnvironment.ts` | Create | Pure logic: read runtime config, decide if banner should show, validate color |
| `management-frontend/app/composables/__tests__/useEnvironment.test.ts` | Create | Unit tests for the composable |
| `management-frontend/app/components/EnvironmentBanner.vue` | Create | Renders nothing in prod; otherwise sticky colored top bar |
| `management-frontend/app/components/__tests__/EnvironmentBanner.test.ts` | Create | Component render tests |
| `management-frontend/app/app.vue` | Modify | Mount `<EnvironmentBanner />` above `<NuxtLayout>` |
| `management-frontend/app/components/SiteHeader.vue` | Modify | Accept `:hasBannerAbove` prop; suppress own safe-area padding when true |
| `management-frontend/app/layouts/default.vue` | Modify | Pass `:has-banner-above="showBanner"` from `useEnvironment()` to `SiteHeader` |
| `management-frontend/nuxt.config.ts` | Modify | Add `envName`, `envColor` to `runtimeConfig.public` |
| `management-frontend/.env.example` | Modify | Document the two new vars |
| `Docker/docker-compose.yml` | Modify | Forward `NUXT_PUBLIC_ENV_NAME` / `NUXT_PUBLIC_ENV_COLOR` to frontend service |
| `Docker/.env.example` | Modify | Document the two new vars |
| `Docker/setup.sh` | Modify | Interactive prompt in "Application Settings" + write to `.env` and `management-frontend/.env` |
| `Docker/update.sh` | Modify | Append commented-out section if `ENV_NAME` is missing from `.env` |

The banner's sticky placement and the `SiteHeader` `:hasBannerAbove` prop together implement spec Architecture/3 option 2 (prop-driven) — the most explicit of the three options the spec offers, and the easiest to reason about during code review.

**Color palette** (final, used in tests and code):

```ts
type ColorKey = 'red' | 'amber' | 'orange' | 'purple' | 'blue'

const COLOR_CLASSES: Record<ColorKey, string> = {
  red:    'bg-red-600 text-white',
  amber:  'bg-amber-500 text-amber-950',
  orange: 'bg-orange-500 text-white',
  purple: 'bg-purple-600 text-white',
  blue:   'bg-blue-600 text-white',
}
```

**Production-detection rule:** `isProduction = !envName || ['prod', 'production'].includes(envName.trim().toLowerCase())`. `envName` returned to consumers is `raw.trim().toUpperCase()` when shown, `''` otherwise.

---

## Chunk 1: Composable, component, and mount

### Task 1: `useEnvironment` composable — failing tests first

**Files:**
- Create: `management-frontend/app/composables/__tests__/useEnvironment.test.ts`
- Will create next: `management-frontend/app/composables/useEnvironment.ts`

The composable is pure: it reads `useRuntimeConfig().public` (which is auto-imported from `#imports` in real Nuxt) and returns derived values. We mock `#imports` so we can drive the inputs directly.

- [ ] **Step 1.1: Write the failing tests**

Create `management-frontend/app/composables/__tests__/useEnvironment.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'

// Drive useRuntimeConfig() per-test so we can vary inputs.
let mockPublic: { envName?: string; envColor?: string } = {}
vi.mock('#imports', () => ({
  useRuntimeConfig: () => ({ public: mockPublic }),
}))

import { useEnvironment } from '../useEnvironment'

function withConfig(p: { envName?: string; envColor?: string }) {
  mockPublic = p
  return useEnvironment()
}

describe('useEnvironment', () => {
  describe('isProduction / showBanner', () => {
    it.each([
      [undefined],
      [''],
      ['  '],
      ['prod'],
      ['PROD'],
      ['Production'],
      ['production'],
    ])('treats %j as production', (envName) => {
      const env = withConfig({ envName })
      expect(env.isProduction).toBe(true)
      expect(env.showBanner).toBe(false)
      expect(env.envName).toBe('')
    })

    it.each(['dev', 'test', 'staging', 'qa', 'my-laptop'])(
      'treats %s as non-production',
      (envName) => {
        const env = withConfig({ envName })
        expect(env.isProduction).toBe(false)
        expect(env.showBanner).toBe(true)
      },
    )

    it('uppercases the env name when shown', () => {
      expect(withConfig({ envName: 'dev' }).envName).toBe('DEV')
      expect(withConfig({ envName: 'Test' }).envName).toBe('TEST')
      expect(withConfig({ envName: '  staging  ' }).envName).toBe('STAGING')
    })
  })

  describe('envColor', () => {
    it.each(['red', 'amber', 'orange', 'purple', 'blue'])(
      'accepts valid color %s',
      (color) => {
        expect(withConfig({ envName: 'dev', envColor: color }).envColor).toBe(color)
      },
    )

    it('falls back to amber for empty color', () => {
      expect(withConfig({ envName: 'dev', envColor: '' }).envColor).toBe('amber')
    })

    it('falls back to amber for missing color', () => {
      expect(withConfig({ envName: 'dev' }).envColor).toBe('amber')
    })

    it('falls back to amber for unknown color', () => {
      expect(withConfig({ envName: 'dev', envColor: 'neon' }).envColor).toBe('amber')
    })

    it('is case-insensitive on color input', () => {
      expect(withConfig({ envName: 'dev', envColor: 'RED' }).envColor).toBe('red')
    })
  })
})
```

- [ ] **Step 1.2: Run tests — expect failure (file does not exist)**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useEnvironment.test.ts
```

Expected: `FAIL` with module-not-found for `../useEnvironment`.

- [ ] **Step 1.3: Implement the composable**

Create `management-frontend/app/composables/useEnvironment.ts`:

```ts
import { useRuntimeConfig } from '#imports'

export type ColorKey = 'red' | 'amber' | 'orange' | 'purple' | 'blue'

const VALID_COLORS: readonly ColorKey[] = ['red', 'amber', 'orange', 'purple', 'blue'] as const
const PROD_ALIASES = new Set(['prod', 'production'])

export interface EnvironmentInfo {
  envName: string         // uppercased when shown, '' when production
  envColor: ColorKey      // validated, defaults to 'amber'
  isProduction: boolean
  showBanner: boolean
}

export function useEnvironment(): EnvironmentInfo {
  const config = useRuntimeConfig()
  const rawName = String(config.public.envName ?? '').trim()
  const rawColor = String(config.public.envColor ?? '').trim().toLowerCase()

  const isProduction = rawName === '' || PROD_ALIASES.has(rawName.toLowerCase())
  const envName = isProduction ? '' : rawName.toUpperCase()

  const envColor: ColorKey = (VALID_COLORS as readonly string[]).includes(rawColor)
    ? (rawColor as ColorKey)
    : 'amber'

  return {
    envName,
    envColor,
    isProduction,
    showBanner: !isProduction,
  }
}
```

- [ ] **Step 1.4: Run tests — expect all pass**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useEnvironment.test.ts
```

Expected: all tests pass (≥15 cases).

- [ ] **Step 1.5: Commit**

```bash
git add management-frontend/app/composables/useEnvironment.ts management-frontend/app/composables/__tests__/useEnvironment.test.ts
git commit -m "feat(frontend): add useEnvironment composable for env-indicator banner"
```

---

### Task 2: `EnvironmentBanner` component — failing tests first

**Files:**
- Create: `management-frontend/app/components/__tests__/EnvironmentBanner.test.ts`
- Will create: `management-frontend/app/components/EnvironmentBanner.vue`

- [ ] **Step 2.1: Write the failing tests**

Create `management-frontend/app/components/__tests__/EnvironmentBanner.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'

let mockPublic: { envName?: string; envColor?: string } = {}
// useEnvironment imports useRuntimeConfig from '#imports', which the alias in
// vitest.config.ts resolves to app/test-helpers/nuxt-stubs.ts. Mocking '#imports'
// here intercepts that — so when the component imports useEnvironment from
// '@/composables/useEnvironment' (a real file), useEnvironment's call to
// useRuntimeConfig() hits the mock below.
vi.mock('#imports', () => ({
  useRuntimeConfig: () => ({ public: mockPublic }),
}))

import EnvironmentBanner from '../EnvironmentBanner.vue'

function mountWith(p: { envName?: string; envColor?: string }) {
  mockPublic = p
  return mount(EnvironmentBanner)
}

describe('EnvironmentBanner', () => {
  it('renders nothing in production (empty envName)', () => {
    const w = mountWith({})
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(false)
  })

  it('renders nothing when envName is "prod"', () => {
    const w = mountWith({ envName: 'prod' })
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(false)
  })

  it('renders the banner with uppercased env name for non-prod', () => {
    const w = mountWith({ envName: 'dev' })
    expect(w.text()).toContain('DEV')
    expect(w.find('[data-testid="env-banner"]').exists()).toBe(true)
  })

  it.each([
    ['red',    'bg-red-600'],
    ['amber',  'bg-amber-500'],
    ['orange', 'bg-orange-500'],
    ['purple', 'bg-purple-600'],
    ['blue',   'bg-blue-600'],
  ])('applies bg class for color %s', (color, cls) => {
    const w = mountWith({ envName: 'dev', envColor: color })
    expect(w.find('[data-testid="env-banner"]').classes()).toContain(cls)
  })

  it('falls back to amber for unknown color', () => {
    const w = mountWith({ envName: 'dev', envColor: 'neon' })
    expect(w.find('[data-testid="env-banner"]').classes()).toContain('bg-amber-500')
  })

  it('is sticky to the top of its scroll container', () => {
    const w = mountWith({ envName: 'dev' })
    const cls = w.find('[data-testid="env-banner"]').classes()
    expect(cls).toContain('sticky')
    expect(cls).toContain('top-0')
    expect(cls).toContain('z-50')
  })
})
```

- [ ] **Step 2.2: Run tests — expect failure**

```bash
cd management-frontend && npx vitest run app/components/__tests__/EnvironmentBanner.test.ts
```

Expected: `FAIL` with module-not-found for `../EnvironmentBanner.vue`.

- [ ] **Step 2.3: Implement the component**

Create `management-frontend/app/components/EnvironmentBanner.vue`:

```vue
<script setup lang="ts">
import { computed } from 'vue'
import { IconAlertTriangle } from '@tabler/icons-vue'
import { useEnvironment, type ColorKey } from '@/composables/useEnvironment'

const env = useEnvironment()

// Static map — Tailwind 4 JIT picks up these literal class names.
// Colors are intentionally identical in light and dark mode: a warning
// indicator must remain prominent regardless of theme.
const COLOR_CLASSES: Record<ColorKey, string> = {
  red:    'bg-red-600 text-white',
  amber:  'bg-amber-500 text-amber-950',
  orange: 'bg-orange-500 text-white',
  purple: 'bg-purple-600 text-white',
  blue:   'bg-blue-600 text-white',
}

const colorClass = computed(() => COLOR_CLASSES[env.envColor])
</script>

<template>
  <div
    v-if="env.showBanner"
    data-testid="env-banner"
    role="status"
    aria-live="polite"
    :class="[
      'sticky top-0 z-50 w-full pt-[env(safe-area-inset-top)]',
      colorClass,
    ]"
  >
    <div class="flex h-7 items-center justify-center gap-2 text-xs font-semibold uppercase tracking-wider">
      <IconAlertTriangle class="size-4 shrink-0" aria-hidden="true" />
      <span>{{ env.envName }}</span>
    </div>
  </div>
</template>
```

Notes for the implementer:
- We import `useEnvironment` directly via `@/composables/useEnvironment` (not via `#imports`) so the test only needs to mock `useRuntimeConfig`. The real composable file is then exercised by the component test, giving us end-to-end coverage of the validation logic too.
- `computed` is imported explicitly from `'vue'`, matching the existing pattern in `CellularHealthBadge.vue:2`.
- `aria-live="polite"` — the banner is informational, not an alert.

- [ ] **Step 2.4: Run tests — expect all pass**

```bash
cd management-frontend && npx vitest run app/components/__tests__/EnvironmentBanner.test.ts
```

Expected: all tests pass (≥10 cases).

- [ ] **Step 2.5: Commit**

```bash
git add management-frontend/app/components/EnvironmentBanner.vue management-frontend/app/components/__tests__/EnvironmentBanner.test.ts
git commit -m "feat(frontend): add EnvironmentBanner component"
```

---

### Task 3: Mount the banner and fix `SiteHeader` safe-area double-padding

**Files:**
- Modify: `management-frontend/app/app.vue`
- Modify: `management-frontend/app/components/SiteHeader.vue`
- Modify: `management-frontend/app/layouts/default.vue`

The banner is sticky at the top of the viewport. `SiteHeader.vue:11` currently uses `pt-[env(safe-area-inset-top)]` so that, on iOS PWA, the notch / status-bar area is not occluded. When the banner is rendered above the header and absorbs that same safe-area inset, the header would double-count it. We pass an explicit `:has-banner-above` prop and drop the header's padding in that case.

- [ ] **Step 3.1: Mount the banner in `app/app.vue`**

Replace the entire contents of `management-frontend/app/app.vue` with:

```vue
<template>
  <EnvironmentBanner />
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>
```

`<EnvironmentBanner />` resolves via Nuxt's auto-import for components. Vue 3 multi-root templates are supported; the banner is a sibling, not a wrapper, so it does not affect `<NuxtLayout>` slot resolution.

- [ ] **Step 3.2: Add `hasBannerAbove` prop to `SiteHeader`**

Modify `management-frontend/app/components/SiteHeader.vue` so the `<script setup>` declares the prop and the header's class drops the safe-area padding when set.

Replace the existing `<script setup lang="ts">` block:

```ts
import { IconMoon, IconSun } from '@tabler/icons-vue'
import { Button } from '@/components/ui/button'
import { Separator } from '@/components/ui/separator'
import { SidebarTrigger } from '@/components/ui/sidebar'

const { isDark, toggleTheme } = useTheme()

defineProps<{
  hasBannerAbove?: boolean
}>()
```

Replace the opening `<header>` tag class binding:

```html
<header
  :class="[
    'flex min-h-(--header-height) shrink-0 items-end gap-2 border-b transition-[width,height] ease-linear group-has-data-[collapsible=icon]/sidebar-wrapper:min-h-(--header-height)',
    hasBannerAbove ? 'pt-0' : 'pt-[env(safe-area-inset-top)]',
  ]"
>
```

Everything else in `SiteHeader.vue` is unchanged.

- [ ] **Step 3.3: Pass `:has-banner-above` from `default.vue`**

In `management-frontend/app/layouts/default.vue`, update the `<script setup>` block to read `showBanner` and pass it through.

⚠️ **Name collision:** `default.vue:8` already destructures `showBanner` from `useInstallPrompt()` (used for the PWA install banner at line 69). Use an alias to avoid shadowing.

Add after the existing `useAppUpdate()` line:

```ts
const { showBanner: showEnvBanner } = useEnvironment()
```

Update the `<SiteHeader />` tag in the template to pass the prop:

```vue
<SiteHeader :has-banner-above="showEnvBanner" />
```

The existing `v-if="showBanner"` on the PWA install banner (line 69) is unchanged — it still references the `useInstallPrompt()` `showBanner`.

`blank.vue` does not contain a `SiteHeader`, so it needs no change — the banner just sits above the slotted page content there too.

- [ ] **Step 3.4: Run the full Vitest suite to confirm no regressions**

```bash
cd management-frontend && npx vitest run
```

Expected: existing tests still pass, plus the two new test files.

- [ ] **Step 3.5: Manual smoke test — production case (no banner)**

```bash
cd management-frontend
# Ensure ENV_NAME / ENV_COLOR are NOT set in .env
grep -E '^ENV_(NAME|COLOR)=' .env || echo "ok, not set"
npm run dev
```

Open `http://localhost:3000`. Verify:
- No banner appears on login, dashboard, or any other page
- `SiteHeader` looks identical to before this change

- [ ] **Step 3.6: Manual smoke test — non-production case (banner)**

```bash
cd management-frontend
# Add to .env:
echo 'ENV_NAME=dev' >> .env
echo 'ENV_COLOR=red' >> .env
npm run dev
```

Open `http://localhost:3000`. Verify:
- Red banner reading "DEV" with warning icon shown above the header on the login page
- Banner persists on dashboard, machines, and all other pages
- Banner stays at the top while the page content scrolls
- On a window narrow enough to show mobile layout: banner still spans full width, sits above `SiteHeader` (no double safe-area gap on iOS PWA — verify in Safari Responsive Design Mode → iPhone 14 Pro)

Then revert your local `.env` changes (or leave them set if you want the banner during dev — it's fine).

- [ ] **Step 3.7: Commit**

```bash
git add management-frontend/app/app.vue management-frontend/app/components/SiteHeader.vue management-frontend/app/layouts/default.vue
git commit -m "feat(frontend): mount EnvironmentBanner globally; fix SiteHeader safe-area"
```

---

## Chunk 2: Configuration wiring (runtime config, env files, Docker)

### Task 4: Add `envName` / `envColor` to `runtimeConfig.public`

**Files:**
- Modify: `management-frontend/nuxt.config.ts`

- [ ] **Step 4.1: Add the runtime config fields**

In `management-frontend/nuxt.config.ts`, the existing block is:

```ts
runtimeConfig: {
  public: {
    vapidPublicKey: process.env.VAPID_PUBLIC_KEY ?? '',
    githubFirmwareRepo: process.env.GITHUB_FIRMWARE_REPO ?? '',
    appVersion: pkg.version,
    gitHash: process.env.GIT_HASH ?? 'dev',
    buildDate: process.env.BUILD_DATE ?? '',
  },
},
```

Append two lines:

```ts
runtimeConfig: {
  public: {
    vapidPublicKey: process.env.VAPID_PUBLIC_KEY ?? '',
    githubFirmwareRepo: process.env.GITHUB_FIRMWARE_REPO ?? '',
    appVersion: pkg.version,
    gitHash: process.env.GIT_HASH ?? 'dev',
    buildDate: process.env.BUILD_DATE ?? '',
    envName: process.env.ENV_NAME ?? '',
    envColor: process.env.ENV_COLOR ?? 'amber',
  },
},
```

These are build-time placeholders. At runtime, `NUXT_PUBLIC_ENV_NAME` / `NUXT_PUBLIC_ENV_COLOR` override them — same convention as the existing four entries above them.

- [ ] **Step 4.2: Verify the build still passes**

```bash
cd management-frontend && npm run build
```

Expected: build succeeds; no new TypeScript errors.

- [ ] **Step 4.3: Commit**

```bash
git add management-frontend/nuxt.config.ts
git commit -m "feat(frontend): expose envName/envColor in runtimeConfig.public"
```

---

### Task 5: Forward env vars in `docker-compose.yml`

**Files:**
- Modify: `Docker/docker-compose.yml`

- [ ] **Step 5.1: Add the two environment forwards**

In `Docker/docker-compose.yml`, locate the **`frontend:` service** block (starts at `frontend:` ~line 15, NOT the `forwarder:` block ~line 50). Inside its `environment:` section (~lines 25–29), append two new lines so the block becomes:

```yaml
    environment:
      NUXT_PUBLIC_SUPABASE_URL: ${SUPABASE_PUBLIC_URL}
      NUXT_PUBLIC_SUPABASE_KEY: ${ANON_KEY}
      NUXT_PUBLIC_VAPID_PUBLIC_KEY: ${VAPID_PUBLIC_KEY:-}
      NUXT_PUBLIC_GITHUB_FIRMWARE_REPO: ${GITHUB_FIRMWARE_REPO:-}
      NUXT_PUBLIC_ENV_NAME: ${ENV_NAME:-}
      NUXT_PUBLIC_ENV_COLOR: ${ENV_COLOR:-amber}
```

The `:-amber` default ensures missing `ENV_COLOR` falls through to the same default the composable uses.

- [ ] **Step 5.2: Validate compose syntax**

```bash
cd Docker && docker compose config >/dev/null
```

Expected: no syntax errors.

- [ ] **Step 5.3: Commit**

```bash
git add Docker/docker-compose.yml
git commit -m "feat(docker): forward ENV_NAME / ENV_COLOR to frontend service"
```

---

### Task 6: Document the new vars in `.env.example` files

**Files:**
- Modify: `Docker/.env.example`
- Modify: `management-frontend/.env.example`

- [ ] **Step 6.1: Append section to `Docker/.env.example`**

Append to `Docker/.env.example` (after the existing `GITHUB_FIRMWARE_REPO=` block):

```env

##########
# Frontend Environment Indicator
# Empty / "prod" / "production" → no banner. Otherwise → banner with this name.
# Color: red, amber, orange, purple, blue (default: amber)
#########
ENV_NAME=
ENV_COLOR=
```

- [ ] **Step 6.2: Append to `management-frontend/.env.example`**

Append to `management-frontend/.env.example`:

```env

# Environment indicator banner. Empty / prod / production → no banner.
# Color: red, amber, orange, purple, blue (default: amber)
ENV_NAME=
ENV_COLOR=
```

- [ ] **Step 6.3: Commit**

```bash
git add Docker/.env.example management-frontend/.env.example
git commit -m "docs(env): document ENV_NAME / ENV_COLOR for env-indicator banner"
```

---

## Chunk 3: Setup / update scripts

### Task 7: Interactive prompt in `setup.sh`

**Files:**
- Modify: `Docker/setup.sh`

`setup.sh` already has a "Configuration → Application Settings" block (~line 252) that asks about disabling signup. We add a new block immediately after that, then plumb the values through to both `.env` writes.

- [ ] **Step 7.1: Insert the interactive prompt block**

In `Docker/setup.sh`, find:

```bash
DISABLE_SIGNUP="false"
if prompt_yes_no "Disable public signup? (Recommended for private deployments)" "n"; then
    DISABLE_SIGNUP="true"
fi
```

Immediately after that block (before the `# ═════` separator preceding "Generate Secrets"), insert:

```bash
# ─── Environment indicator ─────────────────────────────────────────────────────
echo
echo -e "${BOLD}Environment Indicator${NC}"
echo -e "${DIM}A colored banner can be shown at the top of the frontend on every page${NC}"
echo -e "${DIM}to clearly mark non-production environments (dev / test / staging).${NC}"
echo -e "${DIM}Production deployments should leave this disabled.${NC}"
echo

ENV_NAME=""
ENV_COLOR=""
if prompt_yes_no "Is this a non-production system (dev / test / staging)?" "n"; then
    ENV_NAME=$(prompt_with_default "Environment label (shown on banner, uppercase)" "test")
    echo
    echo -e "${DIM}Available colors:${NC}"
    echo -e "  ${RED}red${NC}     — strongest warning, use for unstable / dev"
    echo -e "  ${YELLOW}amber${NC}   — caution (default)"
    echo -e "  orange  — alternative warm tone"
    echo -e "  purple  — neutral attention, e.g. for staging"
    echo -e "  ${BLUE}blue${NC}    — informational, least alarming"
    echo
    ENV_COLOR=$(prompt_with_default "Banner color" "amber")
    case "$ENV_COLOR" in
        red|amber|orange|purple|blue) ;;
        *) warn "Unknown color '$ENV_COLOR' — falling back to 'amber'"; ENV_COLOR="amber" ;;
    esac
    success "Frontend will show '${ENV_NAME}' banner in ${ENV_COLOR}"
else
    info "Production mode — no environment banner will be shown"
fi
```

- [ ] **Step 7.2: Append the section to the `.env` heredoc**

In the same file, find the existing `.env` heredoc — specifically the trailing block:

```bash
##########
# GitHub Firmware Builds
# Set to your GitHub repo (owner/repo) to enable GitHub release imports on the firmware page.
# Leave empty to disable.
#########

GITHUB_FIRMWARE_REPO=
ENVEOF
```

Insert a new section between `GITHUB_FIRMWARE_REPO=` and `ENVEOF`:

```bash
##########
# GitHub Firmware Builds
# Set to your GitHub repo (owner/repo) to enable GitHub release imports on the firmware page.
# Leave empty to disable.
#########

GITHUB_FIRMWARE_REPO=

##########
# Frontend Environment Indicator
# Empty / "prod" / "production" → no banner. Otherwise → banner with this name.
# Color: red, amber, orange, purple, blue (default: amber)
#########

ENV_NAME=${ENV_NAME}
ENV_COLOR=${ENV_COLOR}
ENVEOF
```

- [ ] **Step 7.3: Append to `management-frontend/.env` heredoc**

Find the existing block:

```bash
    cat > "$FRONTEND_ENV" << FEENVEOF
SUPABASE_URL=${SUPABASE_PUBLIC_URL}
SUPABASE_KEY=${ANON_KEY}
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
FEENVEOF
```

Replace with:

```bash
    cat > "$FRONTEND_ENV" << FEENVEOF
SUPABASE_URL=${SUPABASE_PUBLIC_URL}
SUPABASE_KEY=${ANON_KEY}
VAPID_PUBLIC_KEY=${VAPID_PUBLIC_KEY}
ENV_NAME=${ENV_NAME}
ENV_COLOR=${ENV_COLOR}
FEENVEOF
```

- [ ] **Step 7.4: Smoke-test the script with `bash -n`**

```bash
cd Docker && bash -n setup.sh && echo "syntax ok"
```

Expected: `syntax ok`. We don't run the full setup (it expects a fresh environment).

- [ ] **Step 7.5: Commit**

```bash
git add Docker/setup.sh
git commit -m "feat(setup): prompt for environment indicator during fresh install"
```

---

### Task 8: Informational hint in `update.sh`

**Files:**
- Modify: `Docker/update.sh`

Existing prod installs must not change behavior on update. We append a commented-out section to `.env` if it isn't there yet, mirroring the VAPID-block pattern.

- [ ] **Step 8.1: Find the right insertion point**

`Docker/update.sh` has a series of `# ─── … ───` blocks for VAPID, MQTT, GITHUB_FIRMWARE_REPO. Find the `# ─── GITHUB_FIRMWARE_REPO (informational only) ───` block (~line 208). Insert the new block immediately after it.

- [ ] **Step 8.2: Insert the env-indicator block**

```bash
# ─── ENV_NAME / ENV_COLOR (informational only) ───────────────────────────────
if ! grep -q "^ENV_NAME=" .env; then
    info "ENV_NAME not set — adding commented section to .env"
    cat >> .env << ENVNAMEEOF

##########
# Frontend Environment Indicator
# Auto-generated by update.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Set ENV_NAME to "dev" / "test" / "staging" to show a colored banner.
# Leave empty / "prod" / "production" for production deployments.
# Color: red, amber, orange, purple, blue (default: amber)
#########

ENV_NAME=
ENV_COLOR=
ENVNAMEEOF
    success "ENV_NAME section appended to .env"
else
    success "ENV_NAME already configured in .env"
fi
```

- [ ] **Step 8.3: Smoke-test the script**

```bash
cd Docker && bash -n update.sh && echo "syntax ok"
```

Expected: `syntax ok`.

- [ ] **Step 8.4: Verify idempotence with a temp file**

```bash
cd /tmp && cp /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/.env /tmp/.env-test 2>/dev/null || echo "POSTGRES_PASSWORD=x" > /tmp/.env-test
# Simulate the grep guard
grep -q "^ENV_NAME=" /tmp/.env-test && echo "would skip" || echo "would append"
echo 'ENV_NAME=' >> /tmp/.env-test
grep -q "^ENV_NAME=" /tmp/.env-test && echo "second run: would skip"
rm /tmp/.env-test
```

Expected output: first call `would append`; second call `second run: would skip`. Confirms the guard prevents duplicate sections on repeated `update.sh` runs.

- [ ] **Step 8.5: Commit**

```bash
git add Docker/update.sh
git commit -m "feat(update): document ENV_NAME / ENV_COLOR in existing installs"
```

---

## Final verification

- [ ] **Step F.1: Run the full Vitest suite**

```bash
cd management-frontend && npx vitest run
```

Expected: all tests pass, including the two new files and existing suites.

- [ ] **Step F.2: Build the frontend cleanly**

```bash
cd management-frontend && npm run build
```

Expected: build succeeds; no new warnings about runtimeConfig keys.

- [ ] **Step F.3: Smoke-test against the Docker stack (optional, only if a local stack is running)**

If the Docker stack is up locally:

```bash
cd Docker
# Replace any existing ENV_NAME / ENV_COLOR (don't append duplicates that compose
# would silently take the LAST value of), then restart the frontend
sed -i.bak '/^ENV_NAME=/d;/^ENV_COLOR=/d' .env
echo 'ENV_NAME=dev' >> .env
echo 'ENV_COLOR=red' >> .env
docker compose up -d frontend
```

Open the frontend URL. Verify:
- Red "DEV" banner above `SiteHeader` on every page including login
- No regressions in any existing UI

Revert your `.env` changes when done if you don't want the banner persistently.

- [ ] **Step F.4: Validate `setup.sh` and `update.sh` syntax one more time**

```bash
bash -n Docker/setup.sh && bash -n Docker/update.sh && echo "all scripts ok"
```

Expected: `all scripts ok`.

---

## What this plan deliberately does NOT change

- `Dockerfile` — both vars are runtime-only; the build does not need them.
- `Docker/supabase/config.toml` — no edge functions touched.
- DB migrations — none needed.
- Any firmware, MQTT, or backend code — purely a frontend visual feature.
- `blank.vue` layout — banner mounts above it via `app.vue` already; the layout itself stays empty.
- PWA `theme-color` meta tags — out of scope per spec (future polish).

---

## References

- Spec: [docs/superpowers/specs/2026-04-29-frontend-environment-indicator-design.md](../specs/2026-04-29-frontend-environment-indicator-design.md)
- Existing runtime-config pattern: `management-frontend/nuxt.config.ts:44-52`
- Existing component test pattern: `management-frontend/app/components/__tests__/CellularHealthBadge.test.ts`
- Existing composable test pattern: `management-frontend/app/composables/__tests__/useGeocoding.test.ts`
- Existing `update.sh` informational-block pattern: `Docker/update.sh:115-155` (VAPID block) and `Docker/update.sh:208-212` (GITHUB_FIRMWARE_REPO block)
