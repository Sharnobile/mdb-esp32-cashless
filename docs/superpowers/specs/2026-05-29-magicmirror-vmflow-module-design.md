# MMM-VMflow — MagicMirror² module for VMflow vending data

**Date:** 2026-05-29
**Status:** Approved design (pre-implementation)
**Author:** Lucien Kerl + Claude
**Deliverable:** A standalone MagicMirror² module (own git repo) that displays VMflow
vending-machine data on a smart mirror — sales/revenue, a live sales feed, and
refill status — in several configurable layouts.

---

## 1. Goal & context

The user runs a MagicMirror² (`https://docs.magicmirror.builders`). They want a module
that surfaces data from the VMflow / mdb-esp32-cashless backend, similar to the
management dashboard: recent sales, revenue, and a clear "do I need to refill?" signal.

Emphasis (explicit user request): significant effort on **information gathering** and on
**UI/UX logic**, with **multiple layouts** for different use cases.

### Data source — confirmed

The backend already exposes a finished public REST API at **`/api/v1/`** (Supabase edge
function `api-v1`, fronted by Kong). Auth is via the **`X-API-Key`** header; keys are
created in the management dashboard under `/api-keys`. The user confirmed this API is
**live on their production server** and that they can create a key. Therefore **no new
backend code is required.**

Relevant read endpoints (all support PostgREST query params `limit`, `offset`, `order`,
`select`, and filter operators `eq/neq/gt/gte/lt/lte/like/ilike/in/is`):

| Endpoint | PostgREST table | Used for |
|---|---|---|
| `GET /api/v1/sales` | `sales` (read-only) | KPIs, sales feed, top product |
| `GET /api/v1/machines` | `vendingMachine` | machine names, fleet list |
| `GET /api/v1/devices` | `api_embeddeds` (view) | online/offline status |
| `GET /api/v1/trays` | `machine_trays` | stock levels, refill logic |
| `GET /api/v1/stock-batches` | `warehouse_stock_batches` | warehouse availability |
| `GET /api/v1/products` | `products` | names, prices, images, discontinued |

Notes verified against source:
- The proxy forwards query params straight to PostgREST and does **not** restrict
  columns. With no `select`, PostgREST returns **all** columns — so `trays` returns
  `min_stock` and `fill_when_below` even though the OpenAPI doc schema omits them.
- `sales.item_price` is in **EUR, not cents** — never divide by 100.
- Rate limit: **100 requests/minute per key** (configurable per key); `429` with
  `retry_after` when exceeded.
- PostgREST enforces a **max-rows cap** (~1000); large reads must be paginated.

### Decisions captured during brainstorming

- **Scope:** show **all machines** of the company by default; an optional `machineIds`
  config filter is always available.
- **Data access:** use the live `/api/v1/` REST API + an API key.
- **Code location:** a **standalone repository** (`MMM-VMflow`), built inside this
  workspace and then relocated/pushed by the user. It is **not** committed into the
  monorepo (only this design doc and the implementation plan are).
- **Freshness:** polling (not websockets) — see §3.
- **Layout set:** confirmed in §4.

---

## 2. Architecture

**Pattern: "thin module, fat node_helper."** The MagicMirror frontend module stays
presentational; a Node-side `node_helper.js` does all network and computation. This is
the standard MagicMirror pattern for authenticated APIs and is chosen primarily for
**security**: the API key lives only in the `node_helper` (server side) and never reaches
the browser DOM.

```
Pi (Node, server side)                          Browser (mirror)
┌──────────────────────────────┐               ┌─────────────────────────┐
│ node_helper.js               │   socket      │ MMM-VMflow.js           │
│  ├─ poll timer (default 60s) │ ──VMFLOW_DATA▶ │  getDom() → renderer    │
│  ├─ lib/api-client.js        │               │  per `layout`           │
│  ├─ lib/compute.js  (logic)  │ ◀VMFLOW_CONFIG │  start(): send config   │
│  └─ last-good cache          │               │  graceful states        │
└──────────────────────────────┘               └─────────────────────────┘
        │ X-API-Key (secret, stays here)
        ▼
   /api/v1/{sales,machines,devices,trays,stock-batches,products}
```

### Considered alternatives

1. **(Chosen) node_helper fetches raw `/api/v1/` tables and computes everything**, the
   same way the frontend composables do. Pro: no backend change, key stays server-side,
   logic in one testable place. Con: replicates frontend logic (mitigated by tests);
   must paginate sales.
2. **New aggregation edge function** (`magicmirror-summary`) returning a ready summary.
   Pro: less data over the wire, server-side logic. Con: new backend code + prod
   deployment; contradicts the "API is live, no backend work" decision. Kept as a future
   option if fleet/sales volume ever makes polling heavy — the module side would not
   change.
3. **Frontend hits PostgREST directly with anon key.** Rejected: exposes keys in the
   browser, RLS complexity, not the API's intended use.

### Module structure decision

A **single module** with a `layout` config option (not one module per layout). Users
place multiple instances in different positions, each with its own `layout`. Each
instance renders exactly one layout.

---

## 3. Data flow, polling & resilience

- `MMM-VMflow.js` `start()` sends its `config` to `node_helper` via
  `sendSocketNotification('VMFLOW_CONFIG', config)`.
- `node_helper` keys work per **distinct (baseUrl + apiKey)**: it fetches the full
  dataset for that backend **once** per cycle, then each module instance receives a view
  model **filtered by its own `machineIds`**. Multiple instances on one mirror therefore
  cause one fetch cycle, not N — minimizing rate-limit pressure.
- Every `updateInterval` ms (default **60000**), the helper fetches the needed tables
  (~6 requests), runs `lib/compute.js`, and emits `VMFLOW_DATA` with a single view model.
- **Last-good cache:** the helper retains the previous successful view model. A transient
  failure does not blank the mirror; the frontend shows the cached data plus a subtle
  "as of <relative time>" note.
- **Error signalling:** `VMFLOW_ERROR` with a reason code (`unauthorized` / `rate_limited`
  / `network` / `unknown`) → the frontend shows a short, friendly message instead of
  crashing. On `429`, the helper backs off using `retry_after`.
- **Realtime vs polling:** polling chosen deliberately. `/api/v1/` is REST-only; true
  realtime would require the anon key + a websocket in the browser (insecure). 30–60 s
  polling reads as "live enough" on a mirror. `updateInterval` is configurable (e.g.
  20 s for a feed-only instance). Rate-limit headroom at 60 s with ~6 req/cycle is large.

### View model (shape emitted to the frontend)

```
{
  generatedAt: ISO string,                 // for "as of" display
  kpis: {
    today:     { revenue, count },
    yesterday: { revenue, count },
    week:      { revenue, count },          // rolling 7 days
    lastWeek:  { revenue, count },
    month:     { revenue, count },          // calendar month
    lastMonth: { revenue, count },
    trends:    { today, week, month },      // % vs previous period, null-safe
    topProductToday: { name, units } | null
  },
  feed: [ { id, productName, imagePath|null, price, machineName|null, createdAt } ],
  machines: [ {
    id, name, online: bool,
    stock_health: 'ok'|'low'|'critical',
    stock_percent: int,
    empty_trays, low_trays,
    today_revenue,
    tray_summary:     [ { product_id, product_name, image_path, severity:'critical'|'low'|'fill', deficit, sellprice, in_stock:true,  discontinued } ],
    no_stock_summary: [ { product_id, product_name, image_path, severity:'critical'|'low'|'fill', deficit, sellprice, in_stock:false, discontinued } ]  // machines page renders severity==='critical' as "swap", else dimmed
  } ],
  totals: { machinesOnline, machinesTotal, refillMachines }
}
```

---

## 4. Layout catalogue

One module, `layout` selects the renderer. Default `combo`.

| `layout` | Name | Content |
|---|---|---|
| `combo` *(default)* | **Cockpit (A+C)** | Today/week/month revenue, each with trend arrow + previous-period value; divider; then refill to-dos (only machines needing attention + "rest ok"). |
| `kpi` | **Revenue overview (A)** | Today/week/month + trends. A "🏆 Top today · <product> ·  ×N" line instead of a chart (the sparkline was rejected as not meaningful). |
| `feed` | **Sales feed (B)** | Live list of recent sales: product, price, relative time; optional image + machine name. |
| `refillStatus` | **Refill status (C)** | Machines sorted by urgency, fill-level bars, empty/low counts. |
| `refillProducts` | **Refill products (H)** | **Grouped per machine**, the products with a deficit — faithful to the `/machines` page (see §5.3). |
| `fleet` | **Fleet grid (D)** | All machines as tiles: online status dot, fill %, today revenue. |
| `ticker` | **Ticker bar (E)** | Single line for `top_bar`/`bottom_bar`: "€142.50 today · 37 sales · ⚠ 2 machines to refill". |

### Visual language (mirror aesthetic)

Black background, thin sans-serif (light weights), dim uppercase letter-spaced labels,
large thin white numbers. Trend up = green, down = red. The refill layouts (`combo`,
`refillStatus`, `refillProducts`, `fleet`) reuse the **exact** dashboard semantic colors
(see §5.3).

---

## 5. Logic — faithful replication (the core effort)

All pure computation lives in `lib/compute.js` (no I/O, fully unit-testable). It mirrors
the existing frontend logic so the mirror agrees with the dashboard.

### 5.1 KPI windows & trends

Day boundaries use **local time** (matching the frontend's use of the browser's local
time via `new Date(year, month, date)`). Windows:

- **today** = `[localMidnightToday, now]`
- **yesterday** = `[localMidnightToday − 1d, localMidnightToday)`
- **week** = rolling 7 days: `[now − 7d, now]`; **lastWeek** = `[now − 14d, now − 7d)`
- **month** = calendar month: `[firstOfThisMonth, now]`; **lastMonth** = previous calendar
  month `[firstOfLastMonth, firstOfThisMonth)`

Each window: `revenue = Σ item_price` (EUR), `count = rows`. Trend % vs previous period:
`(cur − prev) / prev × 100`, **null-safe** when `prev === 0` (render "—" / "new", never
`Infinity`/`NaN`). `topProductToday` = product with most units among today's sales
(resolved via `product_id`, falling back to tray lookup when null).

> Exact week/month semantics will be re-verified against `SectionCards.vue` /
> `index.vue` during implementation; if the dashboard uses a different boundary, the
> module matches the dashboard.

### 5.2 Stock health (from `app/lib/stock-health.ts`)

Per tray: `isEmpty = current_stock === 0`;
`isLow = !isEmpty && min_stock > 0 && current_stock <= min_stock`;
`isFillBelow = !isEmpty && !isLow && fill_when_below > 0 && current_stock <= fill_when_below`.
Unassigned trays (`product_id == null`) are ignored for refill.

Warehouse availability: build `warehouseStockMap` (product_id → Σ qty from
`stock-batches` with `quantity > 0`). `isProductRefillable = !hasWarehouses ||
warehouseStockMap.has(product_id)`. **Backward-compat:** when no warehouse batches exist
at all, every product counts as refillable.

Per machine: split low/empty trays into refillable vs no-stock.
`health = refillableEmpty > 0 ? 'critical' : refillableLow > 0 ? 'low' : 'ok'`.
`stock_percent = totalCapacity > 0 ? round(totalStock / totalCapacity × 100) : 100`.

### 5.3 Per-product refill rendering (from `app/pages/machines/index.vue`)

`refillProducts` (and the product rows inside `combo`) reproduce the machines-page list
**exactly**, including colors:

- Product-name color = severity: **critical → `red-500` (#ef4444)**, **low → `amber-500`
  (#f59e0b)**, **fill → `blue-400` (#60a5fa)** (dark) / `blue-600` (light).
- Right-side availability tag: **In Stock → `green-500` (#22c55e)**; **Swap → `orange-400`
  (#fb923c)** with a ⇄ icon (tray empty, no warehouse stock → must swap); **No Stock →
  muted/dimmed** (`opacity-50`).
- Deficit shown as `(-N)`; sell price in muted tabular figures; `discontinued` pill.
- Fill bar color: **red < 20% · amber 20–50% · green ≥ 50%**.
- Stock-health dot: red `critical` / amber `low` / green `ok`.

`tray_summary` (refillable deficits) and `no_stock_summary` (swap = `severity:'critical'`,
plus dimmed others) carry `severity`, `deficit`, `sellprice`, `discontinued`,
`product_name`, `image_path` — matching `useMachines.ts`.

### 5.4 Cross-table joins (in node_helper)

- Online status: join `machines` → `devices` on the embedded link; `online` derived from
  `devices.status` (exact field/threshold verified during implementation).
- Product names/prices/images for sales: prefer `sales.product_id` (stamped at insert),
  fall back to `(machine_id, item_number)` → tray → product.
- Product images: public `product-images` bucket → public URL; no auth needed.

---

## 6. File structure (standalone repo)

```
MMM-VMflow/
├─ MMM-VMflow.js          # Module.register(): defaults, start, getDom dispatch,
│                          #   getStyles, getTranslations, socketNotificationReceived,
│                          #   graceful loading/error/empty states, "as of" note
├─ node_helper.js         # NodeHelper.create(): per-config poll loop, dedup, cache,
│                          #   error/backoff, emits VMFLOW_DATA / VMFLOW_ERROR
├─ lib/
│   ├─ api-client.js      #   /api/v1/ fetch (X-API-Key), pagination (1000/page),
│   │                      #   429 retry_after handling
│   └─ compute.js         #   PURE: KPI windows, trends, stock health, summaries
├─ renderers/             # one focused renderer per layout — each a PURE function
│   │                      #   render(viewModel, ctx) => HTMLElement (ctx = {translate,
│   │                      #   formatCurrency, timeAgo, config}); no MagicMirror globals,
│   │                      #   so renderers are reused unchanged by the preview pages.
│   ├─ combo.js  kpi.js  feed.js  refillStatus.js  refillProducts.js  fleet.js  ticker.js
├─ MMM-VMflow.css         # mirror aesthetic + exact semantic colors
├─ translations/
│   ├─ en.json  de.json
├─ preview/               # standalone, MagicMirror-free render of each layout (see §8)
│   ├─ preview.html        #   loads MMM-VMflow.css + a renderer + SAMPLE_DATA, draws to
│   │                      #   a mirror-sized black canvas; ?layout=combo selects the mode
│   └─ sample-data.js      #   one realistic frozen view model shared by all previews/tests
├─ screenshots/           # PNGs generated from preview/, embedded in README (committed)
│   ├─ combo.png kpi.png feed.png refillStatus.png refillProducts.png fleet.png ticker.png
├─ test/
│   └─ compute.test.js    # node:test + node:assert against fixtures
├─ README.md              # install guide, config table, per-layout section + screenshot
├─ config.sample.js
├─ package.json           # name MMM-VMflow; zero runtime deps; test script = node --test
├─ LICENSE
└─ .gitignore
```

**Zero runtime dependencies** (Node built-in `fetch`, Node ≥18). **No build step** —
MagicMirror loads files directly. Tests use the built-in `node:test` runner. The
`preview/` pages and `screenshots/` exist so the README can show the **real** rendered
output (same CSS + renderers as the module), not throwaway mockups.

---

## 7. Configuration

```js
{
  module: "MMM-VMflow",
  position: "top_right",
  config: {
    baseUrl: "https://your-server:8000",   // without /api/v1
    apiKey: "vmf_…",                         // stays in node_helper, never in browser
    layout: "combo",                          // combo|kpi|feed|refillStatus|refillProducts|fleet|ticker
    machineIds: [],                           // [] = all machines; else filter to these IDs
    updateInterval: 60000,                    // ms; min enforced to respect rate limit
    showImages: false,                        // product thumbnails (often better off on real mirror glass)
    maxFeedItems: 8,
    timezone: null                            // null = Pi local time; else IANA override for day boundaries
  }
}
```

Config validation: missing `baseUrl`/`apiKey` → the module renders a clear setup message
instead of failing silently. `updateInterval` is floored to **15000 ms** to respect the
rate limit (values below are clamped up, with a `Log.warn`).

---

## 8. README & example screenshots

A polished `README.md` is a first-class deliverable (English; the module UI itself ships
en/de — a German section can be added on request). Structure, in order:

1. **Title + one-line description + hero screenshot** (the `combo` layout).
2. **What it shows** — short bullet list of the layouts.
3. **Screenshot gallery** — one image per layout, pulled from `screenshots/`.
4. **Prerequisites** — a running MagicMirror²; a reachable VMflow backend with `/api/v1/`
   live; an API key created in the dashboard under **`/api-keys`**.
5. **Installation** — `cd ~/MagicMirror/modules && git clone <repo>`; note that there is
   **no `npm install` needed** (zero runtime deps; `npm install` only pulls dev tooling
   for tests, and is optional).
6. **Configuration** — a minimal example plus a **full options table** (`option | type |
   default | description`) covering every key in §7; explicit note that `apiKey` stays in
   `node_helper` and never reaches the browser.
7. **Per-layout guide** — one subsection per layout, each with: its screenshot, what it
   shows, recommended `position`(s), and a copy-paste `config` snippet.
8. **Data freshness & rate limits** — explain `updateInterval`, the 100 req/min key limit,
   and multi-instance dedup.
9. **Troubleshooting** — setup message (missing `baseUrl`/`apiKey`), `401` (bad/revoked
   key), `429` (raise interval or per-key limit), empty screen (no machines/sales, or
   `machineIds` filter), off-by-a-day numbers (`timezone`), images not loading
   (`showImages`, public bucket, https/mixed-content).
10. **Security** — the key-stays-server-side property.
11. **Development** — `node --test`, and how to regenerate screenshots (below).
12. **License + credits** (VMflow, MagicMirror²).

### How the screenshots are produced (real output, not mockups)

- `preview/preview.html` is a standalone page (no MagicMirror, no backend). `?layout=<id>`
  selects the renderer. It imports the **real** `MMM-VMflow.css` and `renderers/<id>.js`,
  feeds the frozen `preview/sample-data.js` view model through lightweight `ctx` stubs
  (`translate` → en, `formatCurrency` → `Intl.NumberFormat` EUR, `timeAgo` → fixed
  strings), and draws onto a black, mirror-region-sized container.
- Each layout is captured to `screenshots/<layout>.png` at a fixed viewport and the PNGs
  are **committed**, so the README renders on GitHub without a live backend.
- This reuses the exact CSS + renderer the module ships, so the README images always match
  reality. `preview/` also serves as a fast manual-QA harness during development. The
  capture step is documented in the README's Development section; we generate the initial
  set during implementation via the browser/preview tooling.

---

## 9. Testing

- `lib/compute.js` is the primary test target (pure functions). `test/compute.test.js`
  uses `node:test`/`node:assert` against fixtures covering:
  - day-boundary edges (a sale at 23:59 local, a sale just after midnight);
  - rolling-week vs calendar-month windows;
  - `fill_when_below` severity vs `min_stock` low vs empty;
  - warehouse no-stock → `swap` vs dimmed; no-warehouse backward-compat (all refillable);
  - `discontinued` flag passthrough;
  - empty fleet / zero sales;
  - trend 0-division (prev = 0 → null, not NaN/Infinity);
  - `item_price` summed as EUR (no /100).
- `lib/api-client.js` pagination logic tested with a stubbed fetch (assembles >1000 rows
  across pages; stops correctly).
- Manual/integration: run against the live `/api/v1/` with a real key; verify each layout
  renders and matches the dashboard numbers.

---

## 10. Risks, assumptions & backward-compatibility

- **Read-only, no DB/API/MQTT changes** → zero risk to field devices or existing clients.
- **Timezone:** day boundaries follow the Pi's local time (frontend uses browser local
  time); if the Pi TZ differs from the operator's, numbers could shift by a day — hence
  the `timezone` override option.
- **`devices` online semantics** and **exact week/month boundaries** are the two spots to
  verify against source. The rule is "match the dashboard." This is the **explicit first
  implementation task**: read `SectionCards.vue` + `app/pages/index.vue` (KPI windows) and
  `useMachines.ts` (online-status field/threshold), pin the exact values, and encode them
  as constants/fixtures in `lib/compute.js` + `test/compute.test.js` before building the
  renderers — so the deferral cannot get lost.
- **Embedded `select` joins** through the proxy are treated as an optimization only; the
  baseline implementation fetches tables separately and joins in `compute.js`, which is
  robust regardless of FK/RLS embedding behavior.
- **Large fleets:** sales pagination prevents `max_rows` truncation; if volume ever makes
  polling heavy, switch to the §2 alternative (aggregation edge function) without changing
  the module side.
- **Mirror glass:** images and bright colors can wash out; `showImages` defaults off and
  the palette favors high-contrast text.

---

## 11. Out of scope (v1)

- Writing/mutating data from the mirror (no credit sends, no OTA — read-only display).
- Websocket/realtime streaming.
- A new backend aggregation endpoint (documented as a future option only).
- Single-machine focus layout (mode F) — not requested; `machineIds` filter covers the
  "one location" case for any layout.
```
