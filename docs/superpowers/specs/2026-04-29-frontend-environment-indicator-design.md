# Frontend Environment Indicator

**Date:** 2026-04-29
**Status:** Draft

## Problem

The management-frontend Docker image is generic and runtime-configured. Operators run multiple deployments — production plus one or more dev / test / staging instances. Once logged in, the UI gives no visual cue which environment is being viewed, creating a real risk of accidentally performing destructive actions (deleting sales, changing tray configuration, sending OTAs) on the live system while believing it to be a test instance.

We need an unmistakable, persistent visual indicator on every non-production deployment, with a sensible safe default (production unmarked when not configured).

## Goals

- Persistent visual marker on every page (including login / onboarding) for non-production deployments
- Configurable label (`dev`, `test`, `staging`, ...) and color via runtime env vars
- Production default is "no banner" — an unconfigured deployment is never falsely shown as dev
- No build-time coupling — one frontend image deploys to all environments
- Interactive prompt in `setup.sh` for fresh installs; no behavior change for existing prod installs on `update.sh`

## Non-Goals

- No environment-aware feature gating (the indicator is purely visual)
- No automatic environment detection from hostname / URL — explicit configuration only
- No dismissibility — defeating the indicator defeats its purpose
- No production-side marker (e.g. green "PROD" pill) — keeps the default footprint zero

## Configuration

Two new `NUXT_PUBLIC_*` env vars, following the existing pattern (placeholder build, runtime override via docker-compose `environment:`):

| Var | Values | Default | Effect |
|-----|--------|---------|--------|
| `NUXT_PUBLIC_ENV_NAME` | any string, or empty / `prod` / `production` | empty | Empty / `prod` / `production` (case-insensitive) → no banner. Anything else → banner with this name in uppercase. |
| `NUXT_PUBLIC_ENV_COLOR` | `red`, `amber`, `orange`, `purple`, `blue` | `amber` | Banner color. Unrecognized value → falls back to `amber`. |

Safe-default rationale: a fresh install or forgotten variable produces no banner (production-safe). The opposite failure mode — a real production instance falsely marked as dev — is impossible without explicit miscofiguration.

## Architecture

Three small, independent units. Each can be understood and tested in isolation.

### 1. Composable: `app/composables/useEnvironment.ts`

Pure-logic helper; reads `useRuntimeConfig().public` and exposes:

```ts
useEnvironment() → {
  envName: string         // e.g. "DEV", "TEST", or "" when not shown
  envColor: ColorKey      // validated, falls back to "amber"
  isProduction: boolean   // true when envName is empty / prod / production
  showBanner: boolean     // = !isProduction
}
```

`isProduction` test: `!raw || ['prod', 'production'].includes(raw.trim().toLowerCase())`. The composable does not mutate state and has no side effects, so it is fully unit-testable without mounting Nuxt.

### 2. Component: `app/components/EnvironmentBanner.vue`

Self-contained UI. Renders nothing when `!showBanner` (zero footprint in production). Otherwise:

- Thin full-width strip at the very top of the viewport
- `pt-[env(safe-area-inset-top)]` so iOS notch / status-bar area is also colored
- Centered content: warning icon (`IconAlertTriangle` from `@tabler/icons-vue`) + env name in uppercase, semibold
- Total content height ~28 px (plus safe-area padding when present)
- Color resolved through a static class map so Tailwind 4 JIT picks the literal class names:

  ```ts
  const COLOR_CLASSES: Record<ColorKey, string> = {
    red:    'bg-red-600 text-white',
    amber:  'bg-amber-500 text-amber-950',
    orange: 'bg-orange-500 text-white',
    purple: 'bg-purple-600 text-white',
    blue:   'bg-blue-600 text-white',
  }
  ```

- No dismiss button, no client-side state, no localization (env name is the user-supplied label)

### 3. Mounting: `app/app.vue`

Banner is rendered once at the top level, before `<NuxtLayout>`:

```vue
<template>
  <EnvironmentBanner />
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>
```

Single mount point covers every layout — `default.vue`, `blank.vue` (auth / onboarding), and any future layout — without per-layout edits. Because the banner is the first child, it occupies the top of the viewport in natural document flow; the existing layouts' internal scroll containers (`SidebarInset`, `<slot />`) live below it and behave unchanged.

### Runtime config wiring

`management-frontend/nuxt.config.ts` — add to `runtimeConfig.public`:

```ts
envName: process.env.ENV_NAME ?? '',
envColor: process.env.ENV_COLOR ?? 'amber',
```

Build-time defaults are placeholders; the real values arrive at runtime via `NUXT_PUBLIC_ENV_NAME` / `NUXT_PUBLIC_ENV_COLOR`.

## Docker integration

`Docker/docker-compose.yml`, frontend service `environment:` block — append:

```yaml
NUXT_PUBLIC_ENV_NAME: ${ENV_NAME:-}
NUXT_PUBLIC_ENV_COLOR: ${ENV_COLOR:-amber}
```

`Docker/.env.example` — append a documented section:

```env
##########
# Frontend Environment Indicator
# Empty / "prod" / "production" → no banner. Otherwise → banner with this name.
# Color: red, amber, orange, purple, blue (default: amber)
#########
ENV_NAME=
ENV_COLOR=
```

`management-frontend/.env.example` — same two lines for local dev.

`Dockerfile` — **no change**. Both vars are runtime-only; the build does not need them, so the generic image still deploys everywhere.

## Setup / Update scripts

### `setup.sh` — interactive prompt

New block in the existing "Application Settings" step (~line 252), styled to match the surrounding prompts:

```bash
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

The values are written to both `Docker/.env` (under a new `Frontend Environment Indicator` section in the `cat > .env << ENVEOF` heredoc) and `management-frontend/.env` (in the existing frontend env heredoc).

### `update.sh` — informational only

Existing prod installs must not change behavior. The default `ENV_NAME=` (empty) already means "no banner". We add a small documentation block analogous to the VAPID pattern: if `ENV_NAME` is not present in `.env`, append a commented section so admins discover the option during the next manual review:

```bash
if ! grep -q "^ENV_NAME=" .env; then
    info "ENV_NAME not set — adding commented section to .env"
    cat >> .env << ENVNAMEEOF

##########
# Frontend Environment Indicator (added by update.sh)
# Set ENV_NAME to "dev" / "test" / "staging" to show a colored banner.
# Leave empty / "prod" / "production" for production deployments.
# Color: red, amber, orange, purple, blue (default: amber)
#########

ENV_NAME=
ENV_COLOR=
ENVNAMEEOF
    success "ENV_NAME section appended"
fi
```

Operators of existing dev / test installs add `ENV_NAME=dev` manually and `docker compose up -d` to take effect.

## Edge cases & failure modes

| Scenario | Behavior |
|----------|----------|
| Vars unset on production | No banner (intended) |
| `ENV_NAME=prod` / `PROD` / `production` | No banner (case-insensitive) |
| `ENV_NAME=dev`, `ENV_COLOR=` (empty) | Banner shown in default `amber` |
| `ENV_NAME=dev`, `ENV_COLOR=neon` (invalid) | Banner shown in `amber` (silent fallback) |
| `ENV_NAME=` set explicitly to empty | No banner (intended) |
| `ENV_NAME=dev` on PWA / iOS | Notch / status-bar area is also colored via `pt-[env(safe-area-inset-top)]` |
| Logged-out (login / onboarding) | Banner still shown — exactly when accidental login to wrong env is most likely |
| Operator forgets to set on a fresh dev install | Banner missing; embarrassing but not dangerous (no false-prod marker) |

## Testing

Vitest, in line with the existing test setup (`management-frontend/vitest.config.ts`, helpers in `app/test-helpers/nuxt-stubs.ts`).

**`composables/__tests__/useEnvironment.test.ts`** — covers:
- Empty / unset → `isProduction = true`, `showBanner = false`
- `prod`, `PROD`, `production`, `Production` (case-insensitive) → `isProduction = true`
- `dev`, `test`, `staging` → `isProduction = false`, `envName` uppercased
- `envColor` invalid / empty → falls back to `amber`
- Whitespace-only `envName` (e.g. `"  "`) → treated as empty

**`components/__tests__/EnvironmentBanner.test.ts`** — covers:
- Renders nothing when `showBanner = false`
- Renders banner with uppercase env name when `showBanner = true`
- Applies the correct color class for each valid color key
- Falls back to `amber` class for invalid color

No E2E test needed — the banner has no interactivity.

## What this change does NOT touch

- No DB migrations
- No edge function changes
- No firmware changes
- No MQTT topics
- No production .env on existing servers (update.sh only appends a commented hint)

The change is fully additive on the frontend side and fully optional on the deployment side.
