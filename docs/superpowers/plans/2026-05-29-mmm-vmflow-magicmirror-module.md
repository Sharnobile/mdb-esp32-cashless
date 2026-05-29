# MMM-VMflow MagicMirror Module — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, zero-dependency MagicMirror² module that displays VMflow vending data (revenue KPIs, live sales feed, refill status & products) in 7 configurable layouts, reading from the existing `/api/v1/` REST API.

**Architecture:** "Thin module, fat node_helper." A Node-side `node_helper.js` holds the API key (never exposed to the browser), polls `/api/v1/` on an interval, and runs pure logic in `lib/compute.js` to build a per-instance view model that it pushes to the browser module over MagicMirror's socket. The browser module (`MMM-VMflow.js`) dispatches the view model to one of 7 renderers. All numeric/stock logic is a faithful port of the management-frontend and is unit-tested in isolation.

**Tech Stack:** Plain JavaScript (no TypeScript, no build step). Node ≥18 (built-in `fetch`). Tests via Node's built-in `node:test` + `node:assert`. Browser side uses MagicMirror's module API. Zero runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-05-29-magicmirror-vmflow-module-design.md` (read it first).

**Skills:** Use @superpowers:test-driven-development for `lib/compute.js` and `lib/api-client.js`. Use @superpowers:verification-before-completion before claiming any task done.

---

## Repository & conventions

- Build the module at **`MMM-VMflow/`** in the current workspace, as its **own git repo** (`git init` inside it). It is NOT part of the monorepo — never `git add` it from the monorepo root. The user relocates/pushes it later and clones it into `~/MagicMirror/modules/`.
- All paths below are **relative to `MMM-VMflow/`** unless stated otherwise.
- Commit inside `MMM-VMflow/` after each task. Commit message trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Run all `node`/`git`/`npm` commands from inside `MMM-VMflow/`.

## File structure (target)

```
MMM-VMflow/
├─ MMM-VMflow.js          # browser module: defaults, start, getDom dispatch, sockets, states
├─ node_helper.js         # Node: poll loop (per backend), dedup, cache, errors → sockets
├─ lib/
│   ├─ api-client.js      # /api/v1/ fetch + pagination + 401/429 mapping  (Node)
│   └─ compute.js         # PURE logic: KPIs, trends, stock health, summaries, view model
├─ renderers/
│   ├─ _shared.js         # browser DOM helpers (window.VMflowShared)
│   ├─ combo.js kpi.js feed.js refillStatus.js refillProducts.js fleet.js ticker.js
├─ MMM-VMflow.css         # mirror aesthetic + exact semantic colors
├─ translations/ en.json de.json
├─ preview/ preview.html sample-data.js   # MagicMirror-free render harness (screenshots)
├─ screenshots/ *.png                       # committed, embedded in README
├─ test/ compute.test.js api-client.test.js
├─ README.md config.sample.js package.json LICENSE .gitignore
```

---

## Source-of-truth values (ported from management-frontend — DO NOT re-derive)

These are the exact rules the module must reproduce. Sources cited for traceability.

**KPI windows** (`app/pages/index.vue` `loadDashboard`, lines ~236-282):
- `today` / `yesterday` = **local calendar day** (frontend: `new Date(y,m,d)` midnight).
- `week` = **rolling 7 days** (`now − 7×24h`); `lastWeek` = `now − 14×24h … now − 7×24h`.
- `month` = **calendar month** (`new Date(y,m,1)`); `lastMonth` = previous calendar month.
- `revenue = Σ item_price` (EUR — **never ÷100**); `count = number of rows`.

> **Implementation note (intentional deviation):** we bucket by **calendar-key comparison in a timezone** (`dateKey`/`monthKey` via `Intl`), not by absolute ms boundaries. For all *historical* sales (every sale is ≤ now) this yields identical results to the frontend's `>=` boundary filters, but it is **DST-safe** and supports the `timezone` config override cleanly. Rolling week/lastWeek stay absolute-ms (duration-based, tz-independent).

**Trend %** (`app/components/SectionCards.vue` `pctChange`, lines 39-42):
```js
function pctChange(current, previous) {
  if (previous === 0) return current > 0 ? 100 : null
  return Math.round(((current - previous) / previous) * 100)
}
```
Display: green if `>= 0`, red if `< 0`, render `+N%`/`N%`; when `null`, show a period label instead of a percentage.

**Online status** (`app/pages/index.vue` line 372): `online = !!status && status !== 'offline'` where `status = embeddeds.status` (joined via `vendingMachine.embedded → embeddeds.id`).

**Stock health & summaries** (`app/composables/useMachines.ts` lines 264-405, `app/lib/stock-health.ts`):
- Per tray: `isLow = min_stock > 0 && current_stock <= min_stock`; `isEmpty = current_stock === 0`; `isFillBelow = !isLow && !isEmpty && fill_when_below > 0 && current_stock <= fill_when_below`.
- Unassigned trays (`product_id == null`) are skipped for refill.
- `refillable = product_id != null && (!hasWarehouses || warehouseMap.has(product_id))`. `hasWarehouses = (#batches with qty>0) > 0`. **No warehouses at all ⇒ every product refillable** (backward-compat).
- `deficit = capacity − current_stock`, **aggregated per product_id** across that machine's trays; severity upgrades to `critical` if any contributing tray is empty.
- **Pass 2 (fill):** only for machines with `refillableEmpty + refillableLow > 0`; add `fill_when_below` trays with `deficit = capacity − current_stock` (skip if `≤ 0`), severity `'fill'`, never downgrading an existing severity.
- `tray_summary` = refillable deficits (`in_stock:true`); `no_stock_summary` = non-refillable deficits (`in_stock:false`). Both sorted by `deficit` desc. Severity ∈ `critical|low|fill`.
- `low_trays = refillableEmpty + refillableLow`; `empty_trays = refillableEmpty`.
- `stock_health = refillableEmpty>0 ? 'critical' : refillableLow>0 ? 'low' : 'ok'`.
- `stock_percent = totalCapacity>0 ? round(totalStock/totalCapacity*100) : 0`.
- Machine sort: `critical(0) < low(1) < ok(2)`, tie-break `low_trays` desc.

**Product resolution for a sale** (`index.vue` top-products, lines 301-352): prefer `sale.product_id` (snapshot); else tray lookup keyed `${machine_id}:${item_number}` → product. Skip if unresolved.

**Semantic colors** (`app/pages/machines/index.vue` lines 203-359) — Tailwind hex:
| meaning | token | hex |
|---|---|---|
| critical / empty | red-500 | `#ef4444` |
| low | amber-500 | `#f59e0b` |
| fill / refillable normal | blue-400 | `#60a5fa` |
| in-stock tag / ok / trend up | green-500 | `#22c55e` |
| swap (no-stock, severity critical) | orange-400 | `#fb923c` |
| trend down | red-600/500 | `#ef4444` |
| fill bar | red `<20%`, amber `20–50%`, green `≥50%` | — |
| no-stock dimmed | opacity 0.45 + muted | — |

**Products column name:** the sell price column is **`sellprice`** (not `price`) — see `useMachines.ts:160`.

**Resources & columns to fetch from `/api/v1/`** (PostgREST returns all columns with no `select`):
| resource | columns used |
|---|---|
| `machines` (vendingMachine) | `id, name, embedded` |
| `devices` (api_embeddeds) | `id, status` |
| `sales` | `id, created_at, item_price, machine_id, item_number, product_id` |
| `trays` (machine_trays) | `machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below` |
| `stock-batches` | `product_id, quantity` (filter `quantity=gt.0`) |
| `products` | `id, name, image_path, sellprice, discontinued` |

---

## Chunk 1: Scaffold + pure logic (`lib/compute.js`) + tests

### Task 1.1: Repo scaffold

**Files:** Create `MMM-VMflow/package.json`, `.gitignore`, `LICENSE`, dir structure.

- [ ] **Step 1: Create the directory and init git**
```bash
mkdir -p MMM-VMflow/lib MMM-VMflow/renderers MMM-VMflow/translations MMM-VMflow/preview MMM-VMflow/screenshots MMM-VMflow/test
cd MMM-VMflow && git init
```

- [ ] **Step 2: Write `package.json`**
```json
{
  "name": "mmm-vmflow",
  "version": "1.0.0",
  "description": "MagicMirror² module for VMflow vending-machine data (sales, revenue, refill status).",
  "main": "MMM-VMflow.js",
  "scripts": {
    "test": "node --test"
  },
  "keywords": ["MagicMirror", "vending", "vmflow"],
  "license": "MIT",
  "engines": { "node": ">=18" }
}
```

- [ ] **Step 3: Write `.gitignore`**
```
node_modules/
*.log
.DS_Store
```

- [ ] **Step 4: Write `LICENSE`** (MIT, holder "Lucien Kerl", year 2026).

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "chore: scaffold MMM-VMflow module"
```

### Task 1.2: `dateKey` / `pctChange` helpers (TDD)

**Files:** Create `lib/compute.js`, `test/compute.test.js`.

- [ ] **Step 1: Write failing tests**
```js
// test/compute.test.js
const { test } = require('node:test')
const assert = require('node:assert')
const C = require('../lib/compute')

test('dateKey formats YYYY-MM-DD in the given tz', () => {
  // 2026-05-29T22:30:00Z is already 2026-05-30 00:30 in Berlin (UTC+2 summer)
  const ms = Date.parse('2026-05-29T22:30:00Z')
  assert.equal(C.dateKey(ms, 'Europe/Berlin'), '2026-05-30')
  assert.equal(C.dateKey(ms, 'UTC'), '2026-05-29')
})

test('prevDateKey / prevMonthKey do calendar arithmetic', () => {
  assert.equal(C.prevDateKey('2026-03-01'), '2026-02-28')
  assert.equal(C.prevMonthKey('2026-01'), '2025-12')
})

test('pctChange matches the frontend formula', () => {
  assert.equal(C.pctChange(120, 100), 20)
  assert.equal(C.pctChange(50, 100), -50)
  assert.equal(C.pctChange(5, 0), 100)   // prev 0, cur > 0
  assert.equal(C.pctChange(0, 0), null)  // prev 0, cur 0
})
```

- [ ] **Step 2: Run — expect FAIL**
Run: `node --test test/compute.test.js`
Expected: FAIL ("Cannot find module '../lib/compute'").

- [ ] **Step 3: Implement the helpers in `lib/compute.js`**
```js
'use strict'

const DAY_MS = 24 * 60 * 60 * 1000

function dateKey(ms, tz) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(ms)) // 'YYYY-MM-DD'
}
function monthKey(ms, tz) { return dateKey(ms, tz).slice(0, 7) }

function prevDateKey(key) {
  const [y, m, d] = key.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d)); dt.setUTCDate(dt.getUTCDate() - 1)
  return dt.toISOString().slice(0, 10)
}
function prevMonthKey(mkey) {
  const [y, m] = mkey.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, 1)); dt.setUTCMonth(dt.getUTCMonth() - 1)
  return dt.toISOString().slice(0, 7)
}

function pctChange(current, previous) {
  if (previous === 0) return current > 0 ? 100 : null
  return Math.round(((current - previous) / previous) * 100)
}

module.exports = { DAY_MS, dateKey, monthKey, prevDateKey, prevMonthKey, pctChange }
```

- [ ] **Step 4: Run — expect PASS**
Run: `node --test test/compute.test.js` → Expected: PASS (3 tests).

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "feat(compute): date-key + pctChange helpers"
```

### Task 1.3: `computeKpis` (TDD)

**Files:** Modify `lib/compute.js`, `test/compute.test.js`.

- [ ] **Step 1: Write failing test**
```js
test('computeKpis buckets revenue/count into the six windows', () => {
  const now = new Date('2026-05-29T12:00:00Z') // Berlin 14:00, key 2026-05-29
  const tz = 'Europe/Berlin'
  const sales = [
    { item_price: 2.5, created_at: '2026-05-29T08:00:00Z' }, // today
    { item_price: 1.5, created_at: '2026-05-29T06:00:00Z' }, // today
    { item_price: 3.0, created_at: '2026-05-28T08:00:00Z' }, // yesterday
    { item_price: 4.0, created_at: '2026-05-24T08:00:00Z' }, // within 7d (week)
    { item_price: 9.0, created_at: '2026-05-10T08:00:00Z' }, // 19d ago: month, not week
    { item_price: 5.0, created_at: '2026-04-15T08:00:00Z' }, // last month
  ]
  const k = C.computeKpis(sales, now, tz)
  assert.equal(k.today.revenue, 4.0); assert.equal(k.today.count, 2)
  assert.equal(k.yesterday.revenue, 3.0)
  assert.equal(k.week.revenue, 4.0 + 2.5 + 1.5 + 3.0) // last 7 days incl today+yesterday
  assert.equal(k.month.revenue, 2.5 + 1.5 + 3.0 + 4.0 + 9.0) // May sales
  assert.equal(k.lastMonth.revenue, 5.0)
  assert.equal(k.trends.today, C.pctChange(4.0, 3.0))
})
```

- [ ] **Step 2: Run — expect FAIL** (`C.computeKpis is not a function`).

- [ ] **Step 3: Implement**
```js
function computeKpis(sales, now, tz) {
  const nowMs = now.getTime()
  const todayK = dateKey(nowMs, tz), yK = prevDateKey(todayK)
  const monthK = monthKey(nowMs, tz), lastMonthK = prevMonthKey(monthK)
  const weekFrom = nowMs - 7 * DAY_MS, lastWeekFrom = nowMs - 14 * DAY_MS
  const z = () => ({ revenue: 0, count: 0 })
  const r = { today: z(), yesterday: z(), week: z(), lastWeek: z(), month: z(), lastMonth: z() }
  for (const s of sales) {
    const ms = new Date(s.created_at).getTime()
    const price = s.item_price || 0
    const dk = dateKey(ms, tz), mk = dk.slice(0, 7)
    if (dk === todayK) { r.today.revenue += price; r.today.count++ }
    else if (dk === yK) { r.yesterday.revenue += price; r.yesterday.count++ }
    if (ms >= weekFrom) { r.week.revenue += price; r.week.count++ }
    else if (ms >= lastWeekFrom) { r.lastWeek.revenue += price; r.lastWeek.count++ }
    if (mk === monthK) { r.month.revenue += price; r.month.count++ }
    else if (mk === lastMonthK) { r.lastMonth.revenue += price; r.lastMonth.count++ }
  }
  r.trends = {
    today: pctChange(r.today.revenue, r.yesterday.revenue),
    week: pctChange(r.week.revenue, r.lastWeek.revenue),
    month: pctChange(r.month.revenue, r.lastMonth.revenue),
  }
  return r
}
```
Add `computeKpis` to `module.exports`.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(compute): company-level KPI windows + trends`.

### Task 1.4: `resolveProduct` + `computeTopProductToday` (TDD)

**Files:** Modify `lib/compute.js`, `test/compute.test.js`.

- [ ] **Step 1: Write failing test**
```js
test('computeTopProductToday picks most-sold product today (snapshot + tray fallback)', () => {
  const now = new Date('2026-05-29T12:00:00Z')
  const tz = 'Europe/Berlin'
  const productMap = new Map([['p1', { name: 'Cola' }], ['p2', { name: 'Water' }]])
  const trayLookup = new Map([['m1:3', { product_id: 'p2', name: 'Water' }]])
  const sales = [
    { product_id: 'p1', created_at: '2026-05-29T08:00:00Z' },
    { product_id: 'p1', created_at: '2026-05-29T09:00:00Z' },
    { product_id: null, machine_id: 'm1', item_number: 3, created_at: '2026-05-29T10:00:00Z' },
    { product_id: 'p1', created_at: '2026-05-28T09:00:00Z' }, // yesterday, ignored
  ]
  const top = C.computeTopProductToday(sales, now, tz, productMap, trayLookup)
  assert.deepEqual(top, { name: 'Cola', units: 2 })
})
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**
```js
function resolveProduct(sale, productMap, trayLookup) {
  let id = sale.product_id || null
  let name = id ? (productMap.get(id) && productMap.get(id).name) || null : null
  if (!id && sale.machine_id != null) {
    const t = trayLookup.get(`${sale.machine_id}:${sale.item_number}`)
    if (t) { id = t.product_id; name = t.name }
  }
  return id && name ? { id, name } : null
}

function computeTopProductToday(sales, now, tz, productMap, trayLookup) {
  const todayK = dateKey(now.getTime(), tz)
  const agg = new Map()
  for (const s of sales) {
    if (dateKey(new Date(s.created_at).getTime(), tz) !== todayK) continue
    const p = resolveProduct(s, productMap, trayLookup)
    if (!p) continue
    const e = agg.get(p.id) || { name: p.name, units: 0 }
    e.units++; agg.set(p.id, e)
  }
  let top = null
  for (const v of agg.values()) if (!top || v.units > top.units) top = v
  return top ? { name: top.name, units: top.units } : null
}
```
Export both.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(compute): top product today`.

### Task 1.5: `computeMachineStock` (TDD — the core refill logic)

**Files:** Modify `lib/compute.js`, `test/compute.test.js`.

- [ ] **Step 1: Write failing tests** (cover empty=critical, low=amber, fill=blue, swap=no-warehouse, backward-compat, aggregation, sort)
```js
function pm() {
  return new Map([
    ['p1', { name: 'Cola', image_path: 'p1.jpg', sellprice: 2.5, discontinued: false }],
    ['p2', { name: 'Water', image_path: null, sellprice: 1.5, discontinued: false }],
    ['p3', { name: 'Old', image_path: null, sellprice: 1.0, discontinued: true }],
  ])
}

test('computeMachineStock: empty=critical, low, fill, with warehouse availability', () => {
  const trays = [
    { machine_id: 'm1', item_number: 1, product_id: 'p1', capacity: 10, current_stock: 0, min_stock: 2, fill_when_below: 0 }, // empty -> critical, refillable
    { machine_id: 'm1', item_number: 2, product_id: 'p2', capacity: 10, current_stock: 2, min_stock: 3, fill_when_below: 0 }, // low -> amber, refillable
    { machine_id: 'm1', item_number: 3, product_id: 'p1', capacity: 10, current_stock: 4, min_stock: 0, fill_when_below: 6 }, // fill (machine already has refillable) -> aggregates into p1
    { machine_id: 'm1', item_number: 4, product_id: 'p3', capacity: 10, current_stock: 0, min_stock: 1, fill_when_below: 0 }, // empty but NO warehouse -> swap
  ]
  const warehouse = new Map([['p1', 50], ['p2', 20]]) // p3 missing
  const out = C.computeMachineStock(trays, pm(), warehouse, true).get('m1')
  assert.equal(out.stock_health, 'critical')
  assert.equal(out.empty_trays, 1)
  assert.equal(out.low_trays, 2) // empty(p1) + low(p2)
  // p1 deficit aggregated: empty tray (10-0=10) + fill tray (10-4=6) = 16, severity critical
  const p1 = out.tray_summary.find(i => i.product_id === 'p1')
  assert.equal(p1.deficit, 16); assert.equal(p1.severity, 'critical'); assert.equal(p1.in_stock, true)
  // sorted by deficit desc
  assert.equal(out.tray_summary[0].product_id, 'p1')
  // p3 -> no_stock_summary, swap (severity critical), in_stock false
  const p3 = out.no_stock_summary.find(i => i.product_id === 'p3')
  assert.equal(p3.severity, 'critical'); assert.equal(p3.in_stock, false); assert.equal(p3.discontinued, true)
})

test('computeMachineStock: no warehouses => everything refillable (backward compat)', () => {
  const trays = [{ machine_id: 'm1', item_number: 1, product_id: 'p1', capacity: 5, current_stock: 0, min_stock: 1, fill_when_below: 0 }]
  const out = C.computeMachineStock(trays, pm(), new Map(), false).get('m1')
  assert.equal(out.tray_summary.length, 1)
  assert.equal(out.no_stock_summary.length, 0)
})

test('computeMachineStock: fill trays ignored when machine has no critical/low', () => {
  const trays = [{ machine_id: 'm1', item_number: 1, product_id: 'p1', capacity: 10, current_stock: 8, min_stock: 0, fill_when_below: 9 }]
  const out = C.computeMachineStock(trays, pm(), new Map([['p1', 5]]), true).get('m1')
  assert.equal(out.stock_health, 'ok')
  assert.equal(out.tray_summary.length, 0)
})
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** (faithful port of `useMachines.ts` pass 1 + pass 2)
```js
function computeMachineStock(trays, productMap, warehouseMap, hasWarehouses) {
  const refillable = (pid) => pid != null && (!hasWarehouses || warehouseMap.has(pid))
  const acc = new Map()
  const init = () => ({ total: 0, refillableEmpty: 0, refillableLow: 0, noStockCount: 0, totalStock: 0, totalCapacity: 0, deficits: new Map(), noStockDeficits: new Map(), fillPending: [] })
  const itemOf = (tray, deficit, in_stock, severity) => {
    const p = productMap.get(tray.product_id) || {}
    return { product_id: tray.product_id, product_name: p.name || `Slot ${tray.item_number}`, image_path: p.image_path || null, sellprice: p.sellprice == null ? null : p.sellprice, discontinued: p.discontinued || false, deficit, in_stock, severity }
  }
  // Pass 1
  for (const tray of trays) {
    if (!tray.machine_id) continue
    let e = acc.get(tray.machine_id); if (!e) { e = init(); acc.set(tray.machine_id, e) }
    e.total++; e.totalStock += tray.current_stock; e.totalCapacity += tray.capacity
    const isLow = tray.min_stock > 0 && tray.current_stock <= tray.min_stock
    const isEmpty = tray.current_stock === 0
    const isFill = !isLow && !isEmpty && tray.fill_when_below > 0 && tray.current_stock <= tray.fill_when_below
    if (isLow || isEmpty) {
      if (tray.product_id == null) continue
      const can = refillable(tray.product_id)
      const deficit = tray.capacity - tray.current_stock
      const severity = isEmpty ? 'critical' : 'low'
      const target = can ? e.deficits : e.noStockDeficits
      if (can) { if (isEmpty) e.refillableEmpty++; else e.refillableLow++ } else e.noStockCount++
      const ex = target.get(tray.product_id)
      if (ex) { ex.deficit += deficit; if (severity === 'critical') ex.severity = 'critical' }
      else target.set(tray.product_id, itemOf(tray, deficit, can, severity))
    }
    if (isFill) e.fillPending.push(tray)
  }
  // Pass 2
  for (const e of acc.values()) {
    if (e.refillableEmpty + e.refillableLow === 0) continue
    for (const tray of e.fillPending) {
      if (tray.product_id == null) continue
      const deficit = tray.capacity - tray.current_stock
      if (deficit <= 0) continue
      const can = refillable(tray.product_id)
      const target = can ? e.deficits : e.noStockDeficits
      const ex = target.get(tray.product_id)
      if (ex) ex.deficit += deficit
      else target.set(tray.product_id, itemOf(tray, deficit, can, 'fill'))
    }
  }
  // Finalize
  const out = new Map()
  for (const [mid, e] of acc) {
    out.set(mid, {
      total_trays: e.total,
      low_trays: e.refillableEmpty + e.refillableLow,
      empty_trays: e.refillableEmpty,
      no_stock_trays: e.noStockCount,
      stock_health: e.refillableEmpty > 0 ? 'critical' : (e.refillableLow > 0 ? 'low' : 'ok'),
      stock_percent: e.totalCapacity > 0 ? Math.round((e.totalStock / e.totalCapacity) * 100) : 0,
      tray_summary: [...e.deficits.values()].sort((a, b) => b.deficit - a.deficit),
      no_stock_summary: [...e.noStockDeficits.values()].sort((a, b) => b.deficit - a.deficit),
    })
  }
  return out
}
```
Export it.

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(compute): per-machine stock health + refill summaries`.

### Task 1.6: `buildViewModel` (TDD — assembles the full payload incl. machineIds filter)

**Files:** Modify `lib/compute.js`, `test/compute.test.js`.

- [ ] **Step 1: Write failing test**
```js
test('buildViewModel assembles kpis/machines/feed/totals and honors machineIds filter', () => {
  const now = new Date('2026-05-29T12:00:00Z')
  const raw = {
    machines: [{ id: 'm1', name: 'North', embedded: 'd1' }, { id: 'm2', name: 'South', embedded: 'd2' }],
    devices: [{ id: 'd1', status: 'online' }, { id: 'd2', status: 'offline' }],
    products: [{ id: 'p1', name: 'Cola', image_path: 'p1.jpg', sellprice: 2.5, discontinued: false }],
    trays: [{ machine_id: 'm1', item_number: 1, product_id: 'p1', capacity: 10, current_stock: 0, min_stock: 2, fill_when_below: 0 }],
    batches: [{ product_id: 'p1', quantity: 100 }],
    sales: [{ id: 's1', created_at: '2026-05-29T08:00:00Z', item_price: 2.5, machine_id: 'm1', item_number: 1, product_id: 'p1' }],
  }
  const vm = C.buildViewModel(raw, { machineIds: [], maxFeedItems: 5, timezone: 'Europe/Berlin' }, now)
  assert.equal(vm.machines.length, 2)
  assert.equal(vm.totals.machinesOnline, 1)
  assert.equal(vm.totals.refillMachines, 1)
  assert.equal(vm.kpis.today.revenue, 2.5)
  assert.equal(vm.feed[0].productName, 'Cola')
  assert.equal(vm.feed[0].machineName, 'North')
  // filter to m2 only -> no sales, m1 excluded
  const vm2 = C.buildViewModel(raw, { machineIds: ['m2'], maxFeedItems: 5, timezone: 'Europe/Berlin' }, now)
  assert.equal(vm2.machines.length, 1)
  assert.equal(vm2.kpis.today.revenue, 0)
})
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**
```js
function buildFeed(salesDesc, productMap, trayLookup, machineNameMap, max) {
  const out = []
  for (const s of salesDesc) {
    const p = resolveProduct(s, productMap, trayLookup)
    out.push({
      id: s.id,
      productName: p ? p.name : null,
      imagePath: p ? ((productMap.get(p.id) || {}).image_path || null) : null,
      price: s.item_price || 0,
      machineName: s.machine_id != null ? (machineNameMap.get(s.machine_id) || null) : null,
      createdAt: s.created_at,
    })
    if (out.length >= max) break
  }
  return out
}

function buildViewModel(raw, config, now) {
  const tz = config.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone
  const filter = Array.isArray(config.machineIds) && config.machineIds.length
    ? new Set(config.machineIds) : null
  const machines = filter ? raw.machines.filter(m => filter.has(m.id)) : raw.machines
  const allowed = new Set(machines.map(m => m.id))
  const sales = filter ? raw.sales.filter(s => allowed.has(s.machine_id)) : raw.sales
  const trays = filter ? raw.trays.filter(t => allowed.has(t.machine_id)) : raw.trays

  const productMap = new Map(raw.products.map(p => [p.id, p]))
  const deviceMap = new Map(raw.devices.map(d => [d.id, d]))
  const machineNameMap = new Map(machines.map(m => [m.id, m.name]))
  const trayLookup = new Map()
  for (const t of trays) if (t.product_id != null) trayLookup.set(`${t.machine_id}:${t.item_number}`, { product_id: t.product_id, name: (productMap.get(t.product_id) || {}).name || null })
  const warehouseMap = new Map()
  for (const b of raw.batches) if (b.product_id) warehouseMap.set(b.product_id, (warehouseMap.get(b.product_id) || 0) + b.quantity)
  const hasWarehouses = raw.batches.length > 0

  const kpis = computeKpis(sales, now, tz)
  kpis.topProductToday = computeTopProductToday(sales, now, tz, productMap, trayLookup)

  const stock = computeMachineStock(trays, productMap, warehouseMap, hasWarehouses)
  const todayK = dateKey(now.getTime(), tz)
  const todayRev = new Map()
  for (const s of sales) {
    if (s.machine_id == null) continue
    if (dateKey(new Date(s.created_at).getTime(), tz) === todayK)
      todayRev.set(s.machine_id, (todayRev.get(s.machine_id) || 0) + (s.item_price || 0))
  }

  const empty = { total_trays: 0, low_trays: 0, empty_trays: 0, no_stock_trays: 0, stock_health: 'ok', stock_percent: 0, tray_summary: [], no_stock_summary: [] }
  const order = { critical: 0, low: 1, ok: 2 }
  const machinesOut = machines.map(m => {
    const st = stock.get(m.id) || empty
    const dev = m.embedded ? deviceMap.get(m.embedded) : null
    const status = dev ? dev.status : null
    return Object.assign({ id: m.id, name: m.name, online: !!status && status !== 'offline', today_revenue: todayRev.get(m.id) || 0 }, st)
  }).sort((a, b) => {
    const d = (order[a.stock_health] != null ? order[a.stock_health] : 2) - (order[b.stock_health] != null ? order[b.stock_health] : 2)
    return d !== 0 ? d : (b.low_trays - a.low_trays)
  })

  const salesDesc = [...sales].sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
  const feed = buildFeed(salesDesc, productMap, trayLookup, machineNameMap, config.maxFeedItems || 8)

  return {
    generatedAt: new Date(now.getTime()).toISOString(),
    kpis, feed, machines: machinesOut,
    totals: {
      machinesOnline: machinesOut.filter(m => m.online).length,
      machinesTotal: machinesOut.length,
      refillMachines: machinesOut.filter(m => m.stock_health !== 'ok').length,
    },
  }
}
```
Export `buildFeed`, `buildViewModel`.

- [ ] **Step 4: Run — expect PASS.** Then run the whole suite: `node --test` → all green.
- [ ] **Step 5: Commit** `feat(compute): assemble per-instance view model`.

---

## Chunk 2: API client + node_helper

### Task 2.1: `lib/api-client.js` with pagination (TDD)

**Files:** Create `lib/api-client.js`, `test/api-client.test.js`.

- [ ] **Step 1: Write failing test** (stub global fetch; assert pagination assembles all pages and 401/429 map to coded errors)
```js
const { test } = require('node:test')
const assert = require('node:assert')
const { apiGetAll, apiGet } = require('../lib/api-client')

function stubFetch(pages) {
  let call = 0
  global.fetch = async () => {
    const body = pages[call++] ?? []
    return { ok: true, status: 200, json: async () => body }
  }
}

test('apiGetAll paginates until a short page', async () => {
  const full = Array.from({ length: 1000 }, (_, i) => ({ i }))
  const half = Array.from({ length: 500 }, (_, i) => ({ i }))
  stubFetch([full, half])
  const rows = await apiGetAll('http://x:8000', 'k', 'sales')
  assert.equal(rows.length, 1500)
})

test('apiGet maps 401 and 429', async () => {
  global.fetch = async () => ({ ok: false, status: 401, json: async () => ({}) })
  await assert.rejects(() => apiGet('http://x:8000', 'k', 'sales'), /unauthorized/)
  global.fetch = async () => ({ ok: false, status: 429, json: async () => ({ retry_after: 7 }) })
  await assert.rejects(() => apiGet('http://x:8000', 'k', 'sales'), (e) => e.code === 'rate_limited' && e.retryAfter === 7)
})
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `lib/api-client.js`**
```js
'use strict'
const PAGE = 1000

async function apiGet(baseUrl, apiKey, resource, query) {
  const url = new URL(`${String(baseUrl).replace(/\/+$/, '')}/api/v1/${resource}`)
  for (const [k, v] of Object.entries(query || {})) if (v != null) url.searchParams.set(k, String(v))
  let res
  try { res = await fetch(url, { headers: { 'X-API-Key': apiKey } }) }
  catch (err) { const e = new Error('network'); e.code = 'network'; e.cause = err; throw e }
  if (res.status === 401) { const e = new Error('unauthorized'); e.code = 'unauthorized'; throw e }
  if (res.status === 429) {
    const body = await res.json().catch(() => ({}))
    const e = new Error('rate_limited'); e.code = 'rate_limited'; e.retryAfter = body.retry_after || 60; throw e
  }
  if (!res.ok) { const e = new Error(`http_${res.status}`); e.code = 'network'; throw e }
  return res.json()
}

async function apiGetAll(baseUrl, apiKey, resource, query) {
  const all = []
  let offset = 0
  for (;;) {
    const page = await apiGet(baseUrl, apiKey, resource, Object.assign({}, query, { limit: PAGE, offset }))
    all.push(...page)
    if (page.length < PAGE) break
    offset += PAGE
  }
  return all
}

module.exports = { apiGet, apiGetAll, PAGE }
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(api-client): paginated /api/v1 fetch with error mapping`.

### Task 2.2: `lib/fetch-all.js` — fetch the six resources for a backend

**Files:** Create `lib/fetch-all.js`, `test/fetch-all.test.js`.

Rationale: keep the "which resources + columns" knowledge in one tested place; `node_helper` stays orchestration-only.

- [ ] **Step 1: Write failing test** (stub api-client; assert it requests the right resources and returns the `raw` shape)
```js
const { test } = require('node:test')
const assert = require('node:assert')
const Module = require('module')

// Inject a stub for ./api-client used by fetch-all
const stub = {
  calls: [],
  apiGetAll: async (_b, _k, resource) => { stub.calls.push(resource); return [{ resource }] },
}
const orig = Module._load
Module._load = function (request, parent, isMain) {
  if (request === './api-client') return stub
  return orig(request, parent, isMain)
}
const { fetchAll } = require('../lib/fetch-all')
Module._load = orig

test('fetchAll requests all six resources and shapes raw', async () => {
  const raw = await fetchAll('http://x:8000', 'k')
  assert.deepEqual(new Set(stub.calls), new Set(['machines', 'devices', 'sales', 'trays', 'stock-batches', 'products']))
  assert.ok(raw.machines && raw.devices && raw.sales && raw.trays && raw.batches && raw.products)
})
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `lib/fetch-all.js`**
```js
'use strict'
const { apiGetAll } = require('./api-client')

// sales fetched since the start of the previous calendar month (covers today/yesterday/
// week/lastWeek/month/lastMonth in all cases). Computed in the helper's local tz — the
// ~30-60d headroom over the deepest window (14d) makes any tz mismatch with
// config.timezone harmless (intentional over-fetch).
function salesSinceIso(now) {
  const d = new Date(now.getFullYear(), now.getMonth() - 1, 1)
  return d.toISOString()
}

async function fetchAll(baseUrl, apiKey, now = new Date()) {
  const since = salesSinceIso(now)
  const [machines, devices, sales, trays, batches, products] = await Promise.all([
    apiGetAll(baseUrl, apiKey, 'machines', { select: 'id,name,embedded' }),
    apiGetAll(baseUrl, apiKey, 'devices', { select: 'id,status' }),
    apiGetAll(baseUrl, apiKey, 'sales', { select: 'id,created_at,item_price,machine_id,item_number,product_id', created_at: `gte.${since}` }),
    apiGetAll(baseUrl, apiKey, 'trays', { select: 'machine_id,item_number,product_id,capacity,current_stock,min_stock,fill_when_below' }),
    apiGetAll(baseUrl, apiKey, 'stock-batches', { select: 'product_id,quantity', quantity: 'gt.0' }),
    apiGetAll(baseUrl, apiKey, 'products', { select: 'id,name,image_path,sellprice,discontinued' }),
  ])
  return { machines, devices, sales, trays, batches, products }
}

module.exports = { fetchAll, salesSinceIso }
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** `feat(fetch-all): batch the six /api/v1 resources`.

### Task 2.3: `node_helper.js` — poll loop, per-backend dedup, cache, errors

**Files:** Create `node_helper.js`.

> No unit test here (it wires MagicMirror's `node_helper`/`logger` runtime). Verified during integration (Task 5.4). Keep it thin — all logic lives in the tested libs.

- [ ] **Step 1: Implement `node_helper.js`**
```js
'use strict'
const NodeHelper = require('node_helper')
const Log = require('logger')
const { fetchAll } = require('./lib/fetch-all')
const { buildViewModel } = require('./lib/compute')

const MIN_INTERVAL = 15000

module.exports = NodeHelper.create({
  start() {
    this.backends = new Map() // key -> { baseUrl, apiKey, interval, timer, instances: Map<id, config>, lastRaw, fetching }
  },

  socketNotificationReceived(notification, payload) {
    if (notification !== 'VMFLOW_CONFIG') return
    const { identifier, config } = payload
    if (!config || !config.baseUrl || !config.apiKey) {
      this.sendSocketNotification('VMFLOW_ERROR', { identifier, reason: 'config' })
      return
    }
    const key = `${config.baseUrl}|${config.apiKey}`
    let b = this.backends.get(key)
    if (!b) {
      b = { baseUrl: config.baseUrl, apiKey: config.apiKey, interval: MIN_INTERVAL, timer: null, instances: new Map(), lastRaw: null, fetching: false }
      this.backends.set(key, b)
    }
    b.instances.set(identifier, config)
    b.interval = Math.max(MIN_INTERVAL, Math.min(...[...b.instances.values()].map(c => c.updateInterval || 60000)))

    // Serve cached data immediately to this new instance.
    if (b.lastRaw) this.emitInstance(b, identifier, config)

    // (Re)arm the timer and fetch now.
    if (b.timer) clearInterval(b.timer)
    b.timer = setInterval(() => this.poll(key), b.interval)
    this.poll(key)
  },

  async poll(key) {
    const b = this.backends.get(key)
    if (!b || b.fetching) return
    b.fetching = true
    try {
      const raw = await fetchAll(b.baseUrl, b.apiKey, new Date())
      b.lastRaw = raw
      for (const [identifier, config] of b.instances) this.emitInstance(b, identifier, config)
    } catch (err) {
      const reason = err && err.code ? err.code : 'unknown'
      Log.warn(`[MMM-VMflow] fetch failed: ${reason}`)
      for (const [identifier] of b.instances) this.sendSocketNotification('VMFLOW_ERROR', { identifier, reason })
      if (reason === 'rate_limited' && err.retryAfter) {
        // back off: re-arm timer at retryAfter (bounded to MIN_INTERVAL floor)
        clearInterval(b.timer)
        const backoff = Math.max(MIN_INTERVAL, err.retryAfter * 1000)
        b.timer = setTimeout(() => { b.timer = setInterval(() => this.poll(key), b.interval); this.poll(key) }, backoff)
      }
    } finally {
      b.fetching = false
    }
  },

  emitInstance(b, identifier, config) {
    try {
      const vm = buildViewModel(b.lastRaw, config, new Date())
      this.sendSocketNotification('VMFLOW_DATA', { identifier, payload: vm })
    } catch (err) {
      Log.error(`[MMM-VMflow] buildViewModel failed: ${err && err.message}`)
      this.sendSocketNotification('VMFLOW_ERROR', { identifier, reason: 'unknown' })
    }
  },
})
```

- [ ] **Step 2: Smoke-check it parses**
Run: `node -e "require('./node_helper.js')"`
Expected: an error about missing module `node_helper` IS acceptable only if MagicMirror isn't installed; if so, instead lint-parse: `node --check node_helper.js` → Expected: no output (syntax OK).

- [ ] **Step 3: Commit** `feat(node_helper): per-backend poll loop with cache + backoff`.

---

## Chunk 3: Browser module shell + CSS + shared render helpers + translations

### Task 3.1: Translations

**Files:** Create `translations/en.json`, `translations/de.json`.

- [ ] **Step 1: Write `translations/en.json`**
```json
{
  "TODAY": "Today", "YESTERDAY": "yesterday", "THIS_WEEK": "This week", "THIS_MONTH": "This month",
  "REVENUE_TODAY": "Revenue today", "SALES_N": "{n} sales", "VS": "vs",
  "TOP_TODAY": "Top today", "RECENT_SALES": "Recent sales", "REFILL_NEEDED": "Refill needed",
  "REFILL_PRODUCTS": "Refill products", "FLEET": "Machines", "ALL_OK": "all stocked",
  "REST_OK": "others ok", "OF": "of", "IN_STOCK": "In stock", "SWAP": "Swap", "NO_STOCK": "No stock",
  "OFFLINE": "offline", "ONLINE": "online", "EMPTY_N": "{n} empty", "LOW_N": "{n} low",
  "NO_DATA": "No data yet", "SETUP_NEEDED": "Set baseUrl + apiKey in config", "AS_OF": "as of {t}",
  "ERR_UNAUTHORIZED": "API key rejected", "ERR_RATE_LIMITED": "Rate limited", "ERR_NETWORK": "Backend unreachable", "ERR_UNKNOWN": "Temporary error", "ERR_CONFIG": "Set baseUrl + apiKey in config",
  "AGO_NOW": "now", "AGO_MIN": "{n}m", "AGO_HOUR": "{n}h", "AGO_DAY": "{n}d"
}
```

- [ ] **Step 2: Write `translations/de.json`**
```json
{
  "TODAY": "Heute", "YESTERDAY": "gestern", "THIS_WEEK": "Diese Woche", "THIS_MONTH": "Dieser Monat",
  "REVENUE_TODAY": "Umsatz heute", "SALES_N": "{n} Verkäufe", "VS": "ggü.",
  "TOP_TODAY": "Top heute", "RECENT_SALES": "Letzte Verkäufe", "REFILL_NEEDED": "Nachfüllen nötig",
  "REFILL_PRODUCTS": "Nachfüll-Produkte", "FLEET": "Automaten", "ALL_OK": "alles aufgefüllt",
  "REST_OK": "Rest ok", "OF": "von", "IN_STOCK": "Im Lager", "SWAP": "Tauschen", "NO_STOCK": "Kein Lager",
  "OFFLINE": "offline", "ONLINE": "online", "EMPTY_N": "{n} leer", "LOW_N": "{n} niedrig",
  "NO_DATA": "Noch keine Daten", "SETUP_NEEDED": "baseUrl + apiKey in der Config setzen", "AS_OF": "Stand {t}",
  "ERR_UNAUTHORIZED": "API-Key abgelehnt", "ERR_RATE_LIMITED": "Rate-Limit erreicht", "ERR_NETWORK": "Backend nicht erreichbar", "ERR_UNKNOWN": "Vorübergehender Fehler", "ERR_CONFIG": "baseUrl + apiKey in der Config setzen",
  "AGO_NOW": "jetzt", "AGO_MIN": "vor {n}m", "AGO_HOUR": "vor {n}h", "AGO_DAY": "vor {n}d"
}
```

- [ ] **Step 3: Commit** `feat(i18n): en + de translations`.

### Task 3.2: `MMM-VMflow.css` — mirror aesthetic + semantic colors

**Files:** Create `MMM-VMflow.css`.

- [ ] **Step 1: Write `MMM-VMflow.css`** (CSS variables hold the exact frontend hexes)
```css
.MMM-VMflow {
  --vmf-crit: #ef4444; --vmf-low: #f59e0b; --vmf-fill: #60a5fa;
  --vmf-ok: #22c55e; --vmf-swap: #fb923c;
  --vmf-up: #22c55e; --vmf-down: #ef4444;
  --vmf-dim: #8a8a8a; --vmf-dim2: #6b6b6b; --vmf-fg: #ffffff; --vmf-track: #2a2a2a; --vmf-off: #4a4a4a;
  font-weight: 300; line-height: 1.3;
}
.MMM-VMflow .vmf-label { color: var(--vmf-dim); font-size: 11px; letter-spacing: 2px; text-transform: uppercase; font-weight: 600; }
.MMM-VMflow .vmf-big { font-weight: 200; color: var(--vmf-fg); letter-spacing: -0.5px; }
.MMM-VMflow .vmf-row { display: flex; justify-content: space-between; align-items: baseline; gap: 10px; }
.MMM-VMflow .vmf-dim { color: var(--vmf-dim); }
.MMM-VMflow .vmf-up { color: var(--vmf-up); }
.MMM-VMflow .vmf-down { color: var(--vmf-down); }
.MMM-VMflow .vmf-dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 7px; vertical-align: middle; }
.MMM-VMflow .vmf-crit-bg { background: var(--vmf-crit); }
.MMM-VMflow .vmf-low-bg { background: var(--vmf-low); }
.MMM-VMflow .vmf-ok-bg { background: var(--vmf-ok); }
.MMM-VMflow .vmf-off-bg { background: var(--vmf-off); }
.MMM-VMflow .vmf-name-critical { color: var(--vmf-crit); }
.MMM-VMflow .vmf-name-low { color: var(--vmf-low); }
.MMM-VMflow .vmf-name-fill { color: var(--vmf-fill); }
.MMM-VMflow .vmf-name-swap { color: var(--vmf-swap); }
.MMM-VMflow .vmf-tag-in { color: var(--vmf-ok); font-size: 10px; }
.MMM-VMflow .vmf-tag-swap { color: var(--vmf-swap); font-size: 10px; }
.MMM-VMflow .vmf-tag-no { color: var(--vmf-dim2); font-size: 10px; }
.MMM-VMflow .vmf-dimmed { opacity: 0.45; }
.MMM-VMflow .vmf-bar { height: 5px; border-radius: 3px; background: var(--vmf-track); overflow: hidden; flex: 1; }
.MMM-VMflow .vmf-bar > span { display: block; height: 100%; }
.MMM-VMflow .vmf-prow { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin: 6px 0; font-size: 14px; }
.MMM-VMflow .vmf-pleft { display: flex; align-items: center; gap: 8px; min-width: 0; }
.MMM-VMflow .vmf-thumb { width: 22px; height: 22px; border-radius: 4px; object-fit: cover; flex: none; }
.MMM-VMflow .vmf-def { color: var(--vmf-dim2); }
.MMM-VMflow .vmf-price { color: var(--vmf-dim); font-variant-numeric: tabular-nums; }
.MMM-VMflow .vmf-divider { border: 0; border-top: 1px solid #232323; margin: 14px 0; }
.MMM-VMflow .vmf-disc { font-size: 9px; background: #2a2a2a; color: #9a9a9a; border-radius: 3px; padding: 0 4px; }
.MMM-VMflow .vmf-msg { color: var(--vmf-dim); font-size: 14px; }
.MMM-VMflow .vmf-asof { color: var(--vmf-dim2); font-size: 10px; margin-top: 8px; }
.MMM-VMflow.vmf-ticker { font-size: 16px; }
.MMM-VMflow .vmf-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px 18px; }
```

- [ ] **Step 2: Commit** `feat(css): mirror styling + semantic color tokens`.

### Task 3.3: `renderers/_shared.js` — reusable DOM builders

**Files:** Create `renderers/_shared.js`.

- [ ] **Step 1: Implement** (browser global `window.VMflowShared`; all renderers depend only on this + the view model + `ctx`)
```js
/* global window, document, Intl */
(function (root) {
  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e }
  function fmtCurrency(v, locale) { try { return new Intl.NumberFormat(locale, { style: 'currency', currency: 'EUR' }).format(v || 0) } catch (_) { return (v || 0).toFixed(2) + ' €' } }
  function fmtPct(n) { return (n >= 0 ? '+' : '') + n + '%' }

  function timeAgo(iso, ctx) {
    const diff = Math.max(0, (ctx.nowMs - new Date(iso).getTime()))
    const m = Math.floor(diff / 60000)
    if (m < 1) return ctx.t('AGO_NOW')
    if (m < 60) return ctx.t('AGO_MIN', { n: m })
    const h = Math.floor(m / 60)
    if (h < 24) return ctx.t('AGO_HOUR', { n: h })
    return ctx.t('AGO_DAY', { n: Math.floor(h / 24) })
  }

  function label(text) { return el('div', 'vmf-label', text) }

  // KPI block: big value + trend; trend null -> period label. `pct` is number|null.
  function kpiTrend(pct, fallbackLabel) {
    if (pct == null) return el('span', 'vmf-dim', fallbackLabel)
    const s = el('span', pct >= 0 ? 'vmf-up' : 'vmf-down', (pct >= 0 ? '▲ ' : '▼ ') + fmtPct(pct))
    return s
  }

  function fillBar(pct) {
    const w = el('div', 'vmf-bar'); const s = el('span')
    s.className = pct < 20 ? 'vmf-crit-bg' : pct < 50 ? 'vmf-low-bg' : 'vmf-ok-bg'
    s.style.width = Math.max(0, Math.min(100, pct)) + '%'
    w.appendChild(s); return w
  }

  function statusDot(health) {
    var bg = health === 'critical' ? 'vmf-crit-bg' : health === 'low' ? 'vmf-low-bg' : health === 'offline' ? 'vmf-off-bg' : 'vmf-ok-bg'
    return el('span', 'vmf-dot ' + bg)
  }

  // Period KPI block (week/month): label + value + trend + "vs <prev>". Used by combo + kpi.
  function periodBlock(ctx, title, value, trend, prev) {
    const box = el('div')
    box.appendChild(label(title))
    const v = el('span', 'vmf-big'); v.style.fontSize = '22px'; v.textContent = fmtCurrency(value, ctx.locale)
    box.appendChild(v); box.appendChild(document.createTextNode(' ')); box.appendChild(kpiTrend(trend, ''))
    box.appendChild(el('div', 'vmf-dim', `${ctx.t('VS')} ${fmtCurrency(prev, ctx.locale)}`))
    return box
  }

  // Faithful machines-page product row. `item` from tray_summary/no_stock_summary.
  function productRow(item, ctx) {
    const row = el('div', 'vmf-prow' + (item.in_stock ? '' : (item.severity === 'critical' ? '' : ' vmf-dimmed')))
    const left = el('div', 'vmf-pleft')
    if (ctx.config.showImages && item.image_path) {
      const img = el('img', 'vmf-thumb'); img.src = ctx.imageUrl(item.image_path); img.alt = ''; left.appendChild(img)
    }
    const nameCls = !item.in_stock && item.severity === 'critical' ? 'vmf-name-swap' : 'vmf-name-' + item.severity
    const name = el('span', nameCls)
    name.appendChild(document.createTextNode((!item.in_stock && item.severity === 'critical' ? '⇄ ' : '') + item.product_name + ' '))
    name.appendChild(el('span', 'vmf-def', `(-${item.deficit})`))
    left.appendChild(name)
    if (item.sellprice != null) left.appendChild(el('span', 'vmf-price', fmtCurrency(item.sellprice, ctx.locale)))
    if (item.discontinued) left.appendChild(el('span', 'vmf-disc', '×'))
    row.appendChild(left)
    const tag = item.in_stock ? el('span', 'vmf-tag-in', ctx.t('IN_STOCK'))
      : item.severity === 'critical' ? el('span', 'vmf-tag-swap', ctx.t('SWAP'))
        : el('span', 'vmf-tag-no', ctx.t('NO_STOCK'))
    row.appendChild(tag)
    return row
  }

  root.VMflowShared = { el, fmtCurrency, fmtPct, timeAgo, label, kpiTrend, fillBar, statusDot, productRow, periodBlock }
})(window)
```

- [ ] **Step 2: Parse-check** `node --check renderers/_shared.js` → no output.
- [ ] **Step 3: Commit** `feat(renderers): shared DOM builders`.

### Task 3.4: `MMM-VMflow.js` — module shell

**Files:** Create `MMM-VMflow.js`.

- [ ] **Step 1: Implement**
```js
/* global Module, Log */
Module.register('MMM-VMflow', {
  defaults: {
    baseUrl: '', apiKey: '', layout: 'combo', machineIds: [],
    updateInterval: 60000, showImages: false, maxFeedItems: 8, timezone: null,
    header: null,
  },

  getStyles() { return [this.file('MMM-VMflow.css')] },
  getTranslations() { return { en: 'translations/en.json', de: 'translations/de.json' } },
  getScripts() {
    return [
      this.file('renderers/_shared.js'),
      this.file('renderers/combo.js'), this.file('renderers/kpi.js'),
      this.file('renderers/feed.js'), this.file('renderers/refillStatus.js'),
      this.file('renderers/refillProducts.js'), this.file('renderers/fleet.js'),
      this.file('renderers/ticker.js'),
    ]
  },

  start() {
    this.viewModel = null
    this.errorReason = null
    this.lastGoodAt = null
    if (this.config.baseUrl && this.config.apiKey) {
      this.sendSocketNotification('VMFLOW_CONFIG', { identifier: this.identifier, config: this.config })
    }
  },

  socketNotificationReceived(notification, payload) {
    if (!payload || payload.identifier !== this.identifier) return
    if (notification === 'VMFLOW_DATA') {
      this.viewModel = payload.payload
      this.errorReason = null
      this.lastGoodAt = Date.now()
      this.updateDom(300)
    } else if (notification === 'VMFLOW_ERROR') {
      this.errorReason = payload.reason
      this.updateDom(300)
    }
  },

  ctx() {
    const self = this
    return {
      t: (k, v) => self.translate(k, v || {}),
      locale: (config.language || 'en'),
      config: this.config,
      nowMs: Date.now(),
      imageUrl: (path) => `${String(self.config.baseUrl).replace(/\/+$/, '')}/storage/v1/object/public/product-images/${path}`,
    }
  },

  getHeader() { return this.config.header || undefined },

  getDom() {
    const S = window.VMflowShared
    const wrap = document.createElement('div')
    wrap.className = 'MMM-VMflow' + (this.config.layout === 'ticker' ? ' vmf-ticker' : '')

    if (!this.config.baseUrl || !this.config.apiKey) { wrap.appendChild(S.el('div', 'vmf-msg', this.translate('SETUP_NEEDED'))); return wrap }
    if (!this.viewModel) {
      const msg = this.errorReason ? this.translate('ERR_' + String(this.errorReason).toUpperCase()) || this.translate('NO_DATA') : this.translate('NO_DATA')
      wrap.appendChild(S.el('div', 'vmf-msg', msg)); return wrap
    }

    const renderer = (window.VMflowRenderers || {})[this.config.layout] || window.VMflowRenderers.combo
    wrap.appendChild(renderer(this.viewModel, this.ctx()))

    // Stale/error footer when we are showing cached data after a failure.
    if (this.errorReason && this.lastGoodAt) {
      const ago = Math.round((Date.now() - this.lastGoodAt) / 60000)
      wrap.appendChild(S.el('div', 'vmf-asof', this.translate('AS_OF', { t: ago + 'm' })))
    }
    return wrap
  },
})
```
> Note: `config.language` is a MagicMirror global (the mirror's configured language). `this.translate` uses the module's loaded translations.

- [ ] **Step 2: Parse-check** `node --check MMM-VMflow.js` → no output.
- [ ] **Step 3: Commit** `feat(module): MMM-VMflow shell with socket wiring + states`.

---

## Chunk 4: Renderers

All renderers register into `window.VMflowRenderers[name]` and have the signature
`(vm, ctx) => HTMLElement`, using only `window.VMflowShared`. Verification for each is
visual (Chunk 5 preview + screenshot) plus a `node --check`.

### Task 4.1: `renderers/combo.js` (primary)

**Files:** Create `renderers/combo.js`.

- [ ] **Step 1: Implement**
```js
/* global window, document */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.combo = function (vm, ctx) {
    const S = window.VMflowShared, k = vm.kpis
    const root = S.el('div', 'vmf-combo')
    root.appendChild(S.label(ctx.t('REVENUE_TODAY')))

    const head = S.el('div', 'vmf-row')
    const big = S.el('span', 'vmf-big'); big.style.fontSize = '40px'; big.textContent = S.fmtCurrency(k.today.revenue, ctx.locale)
    head.appendChild(big)
    head.appendChild(S.kpiTrend(k.trends.today, ctx.t('TODAY')))
    root.appendChild(head)
    root.appendChild(S.el('div', 'vmf-dim', `${ctx.t('SALES_N', { n: k.today.count })} · ${ctx.t('YESTERDAY')} ${S.fmtCurrency(k.yesterday.revenue, ctx.locale)}`))

    const wk = S.el('div', 'vmf-row'); wk.style.marginTop = '14px'
    wk.appendChild(S.periodBlock(ctx, ctx.t('THIS_WEEK'), k.week.revenue, k.trends.week, k.lastWeek.revenue))
    wk.appendChild(S.periodBlock(ctx, ctx.t('THIS_MONTH'), k.month.revenue, k.trends.month, k.lastMonth.revenue))
    root.appendChild(wk)

    root.appendChild(S.el('hr', 'vmf-divider'))

    const need = vm.machines.filter(m => m.stock_health !== 'ok')
    root.appendChild(S.label(`${ctx.t('REFILL_NEEDED')} · ${need.length} ${ctx.t('OF')} ${vm.totals.machinesTotal}`))
    if (need.length === 0) {
      root.appendChild(S.el('div', 'vmf-dim', ctx.t('ALL_OK')))
    } else {
      need.slice(0, 4).forEach(m => {
        const row = S.el('div', 'vmf-row'); row.style.margin = '8px 0'
        const left = S.el('span'); left.appendChild(S.statusDot(m.stock_health)); left.appendChild(document.createTextNode(m.name))
        const right = S.el('span', 'vmf-dim')
        const parts = []
        if (m.empty_trays > 0) parts.push(ctx.t('EMPTY_N', { n: m.empty_trays }))
        if (m.low_trays - m.empty_trays > 0) parts.push(ctx.t('LOW_N', { n: m.low_trays - m.empty_trays }))
        right.textContent = parts.join(' · ') + `  ${m.stock_percent}%`
        row.appendChild(left); row.appendChild(right)
        root.appendChild(row)
      })
      const okCount = vm.totals.machinesTotal - need.length
      if (okCount > 0) root.appendChild(S.el('div', 'vmf-dim', `${ctx.t('REST_OK')} (${okCount})`))
    }
    return root
  }
})()
```

- [ ] **Step 2: Parse-check** `node --check renderers/combo.js`.
- [ ] **Step 3: Commit** `feat(renderers): combo (cockpit) layout`.

### Task 4.2: `renderers/kpi.js`

**Files:** Create `renderers/kpi.js`.

- [ ] **Step 1: Implement** (today big + week/month blocks + "Top today" line; reuses `periodBlock` pattern — duplicate the small helper locally or factor into `_shared`; prefer adding `periodBlock` to `_shared.js` and using it in both. If factoring, update Task 3.3 export and combo accordingly.)
```js
/* global window */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.kpi = function (vm, ctx) {
    const S = window.VMflowShared, k = vm.kpis
    const root = S.el('div', 'vmf-kpi')
    root.appendChild(S.label(ctx.t('REVENUE_TODAY')))
    const head = S.el('div', 'vmf-row')
    const big = S.el('span', 'vmf-big'); big.style.fontSize = '40px'; big.textContent = S.fmtCurrency(k.today.revenue, ctx.locale)
    head.appendChild(big); head.appendChild(S.kpiTrend(k.trends.today, ctx.t('TODAY')))
    root.appendChild(head)
    root.appendChild(S.el('div', 'vmf-dim', `${ctx.t('SALES_N', { n: k.today.count })} · ${ctx.t('YESTERDAY')} ${S.fmtCurrency(k.yesterday.revenue, ctx.locale)}`))
    const wk = S.el('div', 'vmf-row'); wk.style.marginTop = '16px'
    wk.appendChild(S.periodBlock(ctx, ctx.t('THIS_WEEK'), k.week.revenue, k.trends.week, k.lastWeek.revenue))
    wk.appendChild(S.periodBlock(ctx, ctx.t('THIS_MONTH'), k.month.revenue, k.trends.month, k.lastMonth.revenue))
    root.appendChild(wk)
    if (k.topProductToday) {
      root.appendChild(S.el('hr', 'vmf-divider'))
      const r = S.el('div', 'vmf-row')
      r.appendChild(S.el('span', 'vmf-dim', '🏆 ' + ctx.t('TOP_TODAY')))
      r.appendChild(S.el('span', null, `${k.topProductToday.name} · ${k.topProductToday.units}×`))
      root.appendChild(r)
    }
    return root
  }
})()
```
> `periodBlock(ctx, title, value, trend, prev)` is already provided by `_shared.js` (Task 3.3, `VMflowShared.periodBlock`) and used by both `combo` and `kpi` — DRY, no retrofit needed.

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): kpi layout`.

### Task 4.3: `renderers/feed.js`

**Files:** Create `renderers/feed.js`.

- [ ] **Step 1: Implement**
```js
/* global window */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.feed = function (vm, ctx) {
    const S = window.VMflowShared
    const root = S.el('div', 'vmf-feed')
    root.appendChild(S.label(ctx.t('RECENT_SALES')))
    vm.feed.forEach(s => {
      const row = S.el('div', 'vmf-prow')
      const left = S.el('div', 'vmf-pleft')
      if (ctx.config.showImages && s.imagePath) { const img = S.el('img', 'vmf-thumb'); img.src = ctx.imageUrl(s.imagePath); left.appendChild(img) }
      const txt = S.el('span', null, s.productName || ('#' + (s.id || '')))
      left.appendChild(txt)
      if (s.machineName) left.appendChild(S.el('span', 'vmf-dim', s.machineName))
      const right = S.el('span', 'vmf-dim', `${S.fmtCurrency(s.price, ctx.locale)} · ${S.timeAgo(s.createdAt, ctx)}`)
      row.appendChild(left); row.appendChild(right)
      root.appendChild(row)
    })
    if (vm.feed.length === 0) root.appendChild(S.el('div', 'vmf-dim', ctx.t('NO_DATA')))
    return root
  }
})()
```

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): live sales feed`.

### Task 4.4: `renderers/refillStatus.js`

**Files:** Create `renderers/refillStatus.js`.

- [ ] **Step 1: Implement** (machines needing refill, urgency-sorted — vm.machines is already sorted; show bar + counts)
```js
/* global window, document */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.refillStatus = function (vm, ctx) {
    const S = window.VMflowShared
    const root = S.el('div', 'vmf-refill')
    root.appendChild(S.label(ctx.t('REFILL_NEEDED')))
    const need = vm.machines.filter(m => m.stock_health !== 'ok')
    if (need.length === 0) { root.appendChild(S.el('div', 'vmf-dim', ctx.t('ALL_OK'))); return root }
    need.forEach(m => {
      const block = S.el('div'); block.style.margin = '11px 0'
      const head = S.el('div', 'vmf-row')
      const left = S.el('span'); left.appendChild(S.statusDot(m.stock_health)); left.appendChild(document.createTextNode(m.name))
      const parts = []
      if (m.empty_trays > 0) parts.push(ctx.t('EMPTY_N', { n: m.empty_trays }))
      if (m.low_trays - m.empty_trays > 0) parts.push(ctx.t('LOW_N', { n: m.low_trays - m.empty_trays }))
      head.appendChild(left); head.appendChild(S.el('span', 'vmf-dim', parts.join(' · ')))
      block.appendChild(head)
      const barRow = S.el('div', 'vmf-row'); barRow.style.marginTop = '6px'
      barRow.appendChild(S.fillBar(m.stock_percent))
      barRow.appendChild(S.el('span', 'vmf-dim', m.stock_percent + '%'))
      block.appendChild(barRow)
      root.appendChild(block)
    })
    return root
  }
})()
```

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): refill status`.

### Task 4.5: `renderers/refillProducts.js`

**Files:** Create `renderers/refillProducts.js`.

- [ ] **Step 1: Implement** (per machine, faithful product rows via `S.productRow`; tray_summary then a divider then swap then dimmed no-stock — mirroring machines page ordering)
```js
/* global window, document */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.refillProducts = function (vm, ctx) {
    const S = window.VMflowShared
    const root = S.el('div', 'vmf-refill-products')
    root.appendChild(S.label(ctx.t('REFILL_PRODUCTS')))
    const need = vm.machines.filter(m => m.stock_health !== 'ok' || (m.no_stock_summary && m.no_stock_summary.length))
    if (need.length === 0) { root.appendChild(S.el('div', 'vmf-dim', ctx.t('ALL_OK'))); return root }
    need.forEach(m => {
      const head = S.el('div', 'vmf-row'); head.style.margin = '14px 0 6px'
      const left = S.el('span'); left.appendChild(S.statusDot(m.stock_health)); left.appendChild(document.createTextNode(m.name))
      head.appendChild(left); head.appendChild(S.el('span', 'vmf-dim', m.stock_percent + '%'))
      root.appendChild(head)
      m.tray_summary.forEach(item => root.appendChild(S.productRow(item, ctx)))
      const swaps = (m.no_stock_summary || []).filter(i => i.severity === 'critical')
      const dimmed = (m.no_stock_summary || []).filter(i => i.severity !== 'critical')
      if (m.tray_summary.length && swaps.length) root.appendChild(S.el('hr', 'vmf-divider'))
      swaps.forEach(item => root.appendChild(S.productRow(item, ctx)))
      dimmed.forEach(item => root.appendChild(S.productRow(item, ctx)))
    })
    return root
  }
})()
```

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): refill products (per machine)`.

### Task 4.6: `renderers/fleet.js`

**Files:** Create `renderers/fleet.js`.

- [ ] **Step 1: Implement** (2-col grid of machine tiles: dot+name, %, today revenue, offline label)
```js
/* global window, document */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.fleet = function (vm, ctx) {
    const S = window.VMflowShared
    const root = S.el('div', 'vmf-fleet')
    root.appendChild(S.label(ctx.t('FLEET')))
    const grid = S.el('div', 'vmf-grid'); grid.style.marginTop = '8px'
    vm.machines.forEach(m => {
      const cell = S.el('div')
      const head = S.el('div', 'vmf-row')
      const left = S.el('span'); left.appendChild(S.statusDot(m.online ? m.stock_health : 'offline')); left.appendChild(document.createTextNode(m.name))
      head.appendChild(left)
      head.appendChild(S.el('span', 'vmf-dim', m.online ? (m.stock_percent + '%') : '—'))
      cell.appendChild(head)
      cell.appendChild(S.el('div', 'vmf-dim', m.online ? `${S.fmtCurrency(m.today_revenue, ctx.locale)} ${ctx.t('TODAY').toLowerCase()}` : ctx.t('OFFLINE')))
      grid.appendChild(cell)
    })
    root.appendChild(grid)
    return root
  }
})()
```
> Note: `statusDot('offline')` is already handled by `_shared.js` (maps to `vmf-off-bg` = `#4a4a4a`, defined in Task 3.2) — no change needed here.

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): fleet grid`.

### Task 4.7: `renderers/ticker.js`

**Files:** Create `renderers/ticker.js`.

- [ ] **Step 1: Implement** (single line)
```js
/* global window */
(function () {
  window.VMflowRenderers = window.VMflowRenderers || {}
  window.VMflowRenderers.ticker = function (vm, ctx) {
    const S = window.VMflowShared, k = vm.kpis
    const parts = [
      `${S.fmtCurrency(k.today.revenue, ctx.locale)} ${ctx.t('TODAY').toLowerCase()}`,
      ctx.t('SALES_N', { n: k.today.count }),
    ]
    const root = S.el('div', 'vmf-ticker-line')
    root.appendChild(S.el('span', null, parts.join(' · ')))
    if (vm.totals.refillMachines > 0) {
      root.appendChild(document.createTextNode('  '))
      root.appendChild(S.el('span', 'vmf-name-low', `⚠ ${vm.totals.refillMachines} ${ctx.t('REFILL_NEEDED')}`))
    }
    return root
  }
})()
```

- [ ] **Step 2: Parse-check + Commit** `feat(renderers): ticker bar`.

---

## Chunk 5: Preview harness, screenshots, README, sample config

### Task 5.1: `preview/sample-data.js` — one realistic frozen view model

**Files:** Create `preview/sample-data.js`.

- [ ] **Step 1: Implement** a `window.VMFLOW_SAMPLE` object matching the view-model shape from the spec, with realistic data exercising every state: a critical machine with empty(red)/low(amber)/fill(blue) products + a swap(orange) + a dimmed no-stock product; an amber machine; two ok machines (one offline); a feed of ~6 sales; KPIs with up/down/null trends; `topProductToday`. (Mirror the numbers used in the approved mockups: today €142.50 ▲12%, week €890 ▲8%, month €3,240 ▲5%; Bürohaus Nord 18% 3 empty; Kantine West 34% 1 low.)

- [ ] **Step 2: Commit** `feat(preview): frozen sample view model`.

### Task 5.2: `preview/preview.html` — MagicMirror-free renderer

**Files:** Create `preview/preview.html`.

- [ ] **Step 1: Implement** a standalone page that:
  - loads `../MMM-VMflow.css`, `../renderers/_shared.js`, all `../renderers/*.js`, and `sample-data.js`;
  - reads `?layout=<id>` (default `combo`) and `?lang=de|en` (default `de`);
  - builds a `ctx` stub: `t` reads from an inline en/de map (paste the translations), `locale` from lang, `config` `{ showImages:false, baseUrl:'' }`, `nowMs` a FIXED timestamp (so `timeAgo` is stable for screenshots), `imageUrl` returns ''.
  - renders into a black, fixed-width (e.g. 380px) container with padding, font-family `'Helvetica Neue',Arial,sans-serif`, so it looks like a mirror region;
  - mounts `window.VMflowRenderers[layout](window.VMFLOW_SAMPLE, ctx)`.
```html
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>MMM-VMflow preview</title>
<link rel="stylesheet" href="../MMM-VMflow.css">
<style>
  body { margin:0; background:#000; color:#dcdcdc; font-family:'Helvetica Neue',Arial,sans-serif; }
  #stage { width:380px; padding:22px; }
  .MMM-VMflow.vmf-ticker #stageinner, .vmf-ticker-line { white-space:nowrap; }
</style></head>
<body>
  <div id="stage"><div id="mount" class="MMM-VMflow"></div></div>
  <script src="../renderers/_shared.js"></script>
  <script src="../renderers/combo.js"></script>
  <script src="../renderers/kpi.js"></script>
  <script src="../renderers/feed.js"></script>
  <script src="../renderers/refillStatus.js"></script>
  <script src="../renderers/refillProducts.js"></script>
  <script src="../renderers/fleet.js"></script>
  <script src="../renderers/ticker.js"></script>
  <script src="sample-data.js"></script>
  <script>
    const params = new URLSearchParams(location.search)
    const layout = params.get('layout') || 'combo'
    const lang = params.get('lang') || 'de'
    const STR = window.VMFLOW_STRINGS // { en:{...}, de:{...} } — paste both translation maps here
    function t(k, v) { let s = (STR[lang] && STR[lang][k]) || k; if (v) for (const kk in v) s = s.replace('{' + kk + '}', v[kk]); return s }
    const ctx = { t, locale: lang === 'de' ? 'de-DE' : 'en-US', config: { showImages: false, baseUrl: '' }, nowMs: Date.parse('2026-05-29T14:00:00+02:00'), imageUrl: () => '' }
    const mount = document.getElementById('mount')
    mount.className = 'MMM-VMflow' + (layout === 'ticker' ? ' vmf-ticker' : '')
    mount.appendChild(window.VMflowRenderers[layout](window.VMFLOW_SAMPLE, ctx))
  </script>
</body></html>
```
  - Paste both translation maps into a `window.VMFLOW_STRINGS` (inline `<script>` before the module scripts), or load the JSON via fetch (file:// may block fetch — inline is safer for screenshots).

- [ ] **Step 2: Manual check** — open `preview/preview.html?layout=combo` in a browser; confirm it matches the approved mockup (colors per §5.3).
- [ ] **Step 3: Commit** `feat(preview): standalone render harness`.

### Task 5.3: Generate screenshots

**Files:** Create `screenshots/*.png`.

- [ ] **Step 1:** Using the preview/browser tooling, capture each layout at a fixed viewport to `screenshots/<layout>.png` for: `combo, kpi, feed, refillStatus, refillProducts, fleet, ticker`. Use `?lang=de`. (During implementation in this harness, use the `mcp__Claude_Preview__*` tools or a headless screenshot of `preview/preview.html?layout=<id>`.)
- [ ] **Step 2: Verify** each PNG visually against §5.3 colors and the approved mockups (red/amber/blue/orange/green correct; trends green/red; fill bars colored by threshold).
- [ ] **Step 3: Commit** `docs: layout screenshots`.

### Task 5.4: Integration smoke test (real backend) — manual

- [ ] **Step 1:** In a real MagicMirror install (or a minimal harness), add the module with a real `baseUrl` + `apiKey`; confirm `node_helper` fetches and each layout renders. Compare the KPI numbers and refill list against the management dashboard for the same company — they must match.
- [ ] **Step 2:** Test failure handling: revoke the key → expect `ERR_UNAUTHORIZED` message; restore → recovers. Stop the backend → cached data stays with an "as of" note.
- [ ] (No commit unless fixes are needed.)

### Task 5.5: `config.sample.js` + `README.md`

**Files:** Create `config.sample.js`, `README.md`.

- [ ] **Step 1: Write `config.sample.js`** with one example per layout (positions: `combo`→`top_right`, `feed`→`top_left`, `refillProducts`→`top_left`, `fleet`→`bottom_bar`, `ticker`→`top_bar`).

- [ ] **Step 2: Write `README.md`** following spec §8 structure exactly:
  1. Title + one-liner + hero image `![combo](screenshots/combo.png)`.
  2. "What it shows" bullets.
  3. Screenshot gallery (all 7, with captions).
  4. Prerequisites (MagicMirror²; `/api/v1/` live; API key from dashboard `/api-keys`).
  5. Installation (`cd ~/MagicMirror/modules && git clone …`; no `npm install` needed).
  6. Configuration: minimal example + **full options table** (every key: `baseUrl, apiKey, layout, machineIds, updateInterval, showImages, maxFeedItems, timezone, header`); note `apiKey` stays server-side.
  7. Per-layout guide (screenshot + recommended position + config snippet each).
  8. Data freshness & rate limits (updateInterval, 100 req/min, multi-instance dedup).
  9. Troubleshooting (setup message, 401, 429, empty/`machineIds`, off-by-day/`timezone`, images/`showImages`+https).
  10. Security (key never reaches the browser).
  11. Development (`npm test` / `node --test`; regenerate screenshots from `preview/preview.html?layout=…`).
  12. License + credits.

- [ ] **Step 3: Commit** `docs: README + sample config`.

### Task 5.6: Final verification

- [ ] **Step 1:** Run `node --test` → all suites pass.
- [ ] **Step 2:** `git -C MMM-VMflow log --oneline` shows a clean, atomic history.
- [ ] **Step 3:** Confirm zero runtime deps (no `dependencies` block needed) and no build step.
- [ ] Use @superpowers:verification-before-completion before declaring done.

---

## Notes & decisions

- **Multi-instance:** `node_helper` fetches once per `(baseUrl, apiKey)` and builds a filtered view model per instance via `config.machineIds`. Confirmed safe with the `identifier` round-trip.
- **`periodBlock` lives in `_shared.js`** (used by `combo` + `kpi`) — DRY.
- **`statusDot('offline')`** maps to `vmf-off-bg` (#4a4a4a), defined in `_shared.js` + CSS (Task 3.2/3.3).
- **Timezone:** calendar-key bucketing (DST-safe) instead of a literal port of the ms-boundary filter; identical results for historical sales. Default tz = Pi local; `config.timezone` overrides.
- **Images:** off by default; URL built from `baseUrl` + public storage path. Requires the backend reachable over the same scheme (https) to avoid mixed-content on an https mirror.
- **What is NOT ported:** the 7-day sparkline (rejected during brainstorming), warehouse expiry alerts, and any write actions — all out of scope (spec §11).
```
