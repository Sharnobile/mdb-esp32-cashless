# STRUCTURE — management-frontend

> Directory layout, key locations, naming conventions

## Directory Layout

```
management-frontend/
├── nuxt.config.ts              # Nuxt 4 config (modules, runtime config)
├── vitest.config.ts            # Vitest test configuration
├── tsconfig.json               # TypeScript config
├── package.json                # Dependencies and scripts
├── Dockerfile                  # Docker container for production
├── .env / .env.example         # Environment variables
├── app/
│   ├── app.vue                 # Root Vue component
│   ├── assets/
│   │   └── css/tailwind.css    # Tailwind CSS imports
│   ├── layouts/
│   │   ├── default.vue         # Main layout (sidebar + header)
│   │   └── blank.vue           # Blank layout (auth pages)
│   ├── middleware/
│   │   └── auth.ts             # Auth guard middleware
│   ├── plugins/
│   │   ├── supabase-url.client.ts  # Client-side Supabase URL rewrite
│   │   └── register-sw.client.ts   # Service worker registration
│   ├── pages/                  # File-based routing (15 pages)
│   │   ├── index.vue           # Dashboard
│   │   ├── auth/
│   │   │   ├── login.vue
│   │   │   └── register.vue
│   │   ├── machines/
│   │   │   ├── index.vue       # Machine card grid
│   │   │   └── [id].vue        # Machine detail (chart, sales, trays)
│   │   ├── products/
│   │   │   └── index.vue       # Products + categories + import
│   │   ├── warehouse/
│   │   │   └── index.vue       # Inventory management
│   │   ├── devices/
│   │   │   └── index.vue       # Device provisioning + QR
│   │   ├── firmware/
│   │   │   └── index.vue       # Firmware + OTA
│   │   ├── api-keys/
│   │   │   └── index.vue       # API key management
│   │   ├── members/
│   │   │   └── index.vue       # Team + invitations
│   │   ├── settings/
│   │   │   └── index.vue       # App settings
│   │   ├── history/
│   │   │   └── index.vue       # Activity/audit log
│   │   └── onboarding/
│   │       ├── create-organization.vue
│   │       └── accept-invitation.vue
│   ├── composables/            # 16 composables
│   │   ├── useOrganization.ts
│   │   ├── useMachines.ts
│   │   ├── useMachineTrays.ts
│   │   ├── useProducts.ts
│   │   ├── useImportProducts.ts
│   │   ├── useProductImageSearch.ts
│   │   ├── useWarehouse.ts
│   │   ├── useFirmware.ts
│   │   ├── useNotifications.ts
│   │   ├── useMdbLog.ts
│   │   ├── useActivityLog.ts
│   │   ├── useTheme.ts
│   │   ├── usePullToRefresh.ts
│   │   ├── useAppResume.ts
│   │   ├── useAppUpdate.ts
│   │   ├── useInstallPrompt.ts
│   │   └── __tests__/
│   │       └── useMdbLog.test.ts
│   ├── components/
│   │   ├── AppSidebar.vue      # Main sidebar
│   │   ├── NavMain.vue         # Primary nav items
│   │   ├── NavSecondary.vue    # Secondary nav items
│   │   ├── NavUser.vue         # User dropdown
│   │   ├── SiteHeader.vue      # Top header bar
│   │   ├── BottomTabBar.vue    # Mobile bottom tabs
│   │   ├── PullToRefresh.vue   # Pull-to-refresh gesture
│   │   ├── LanguageSwitcher.vue # i18n switcher
│   │   ├── BarcodeScanner.vue  # Camera barcode scanning
│   │   ├── SectionCards.vue    # Reusable card sections
│   │   ├── ChartAreaInteractive.vue  # Unovis area chart
│   │   ├── DashboardActivityFeed.vue
│   │   ├── DashboardMachineList.vue
│   │   ├── DashboardRecentSales.vue
│   │   └── ui/                 # shadcn-nuxt component library
│   │       ├── avatar/         # Avatar, AvatarImage, AvatarFallback
│   │       ├── badge/          # Badge
│   │       ├── button/         # Button
│   │       ├── card/           # Card, CardHeader, CardTitle, etc.
│   │       ├── chart/          # ChartContainer, ChartTooltipContent, etc.
│   │       ├── checkbox/       # Checkbox
│   │       ├── dropdown-menu/  # DropdownMenu + 13 subcomponents
│   │       ├── input/          # Input
│   │       ├── label/          # Label
│   │       ├── select/         # Select + 11 subcomponents
│   │       ├── separator/      # Separator
│   │       ├── sheet/          # Sheet (drawer/modal) + 8 subcomponents
│   │       ├── sidebar/        # Sidebar + 20 subcomponents
│   │       ├── skeleton/       # Skeleton loader
│   │       ├── switch/         # Switch toggle
│   │       ├── table/          # Table + 8 subcomponents
│   │       ├── tabs/           # Tabs + 3 subcomponents
│   │       └── tooltip/        # Tooltip + 3 subcomponents
│   ├── lib/
│   │   └── utils.ts            # cn(), timeAgo(), formatCurrency()
│   ├── test-helpers/
│   │   └── nuxt-stubs.ts       # Vitest mock stubs
│   └── service-worker/
│       └── sw.ts               # PWA service worker
└── public/                     # Static assets
```

## Key Locations

| What | Where |
|------|-------|
| Entry point | `app/app.vue` |
| Nuxt config | `nuxt.config.ts` |
| Page routes | `app/pages/` (file-based routing) |
| Business logic | `app/composables/` (one per domain) |
| Custom components | `app/components/` (14 custom) |
| UI primitives | `app/components/ui/` (~100 shadcn components) |
| Auth middleware | `app/middleware/auth.ts` |
| Shared utilities | `app/lib/utils.ts` |
| Tests | `app/composables/__tests__/` |
| Test helpers | `app/test-helpers/nuxt-stubs.ts` |
| i18n translations | configured in `nuxt.config.ts` |

## Naming Conventions

### Files
- **Pages**: `kebab-case` directories, `index.vue` or `[param].vue` for dynamic routes
- **Composables**: `camelCase` with `use` prefix (e.g., `useMachineTrays.ts`)
- **Components**: `PascalCase` (e.g., `AppSidebar.vue`, `BarcodeScanner.vue`)
- **UI components**: `PascalCase` in `kebab-case` directories (e.g., `ui/dropdown-menu/DropdownMenuContent.vue`)
- **Plugins**: `kebab-case` with `.client.ts` suffix for client-only

### Code
- **Composables**: return reactive refs and functions, prefixed with `use`
- **Props/events**: Vue 3 `defineProps`/`defineEmits` with TypeScript
- **State**: `useState()` for cross-component state (Nuxt), `ref()` for local
- **Types**: inline casts (no generated DB types), e.g., `as { id: string }[]`

## Where to Add New Code

| Adding... | Location |
|-----------|----------|
| New page | `app/pages/<section>/index.vue` |
| New composable | `app/composables/use<Name>.ts` |
| New custom component | `app/components/<Name>.vue` |
| New UI primitive | `npx shadcn-vue add <component>` → `app/components/ui/` |
| New test | `app/composables/__tests__/<composable>.test.ts` |
| New middleware | `app/middleware/<name>.ts` |
| New plugin | `app/plugins/<name>.client.ts` or `<name>.ts` |

## Import Aliases

- `~/` or `@/` → `management-frontend/app/` (Nuxt 4 app directory)
- `#imports` → auto-imported Nuxt composables and utilities
