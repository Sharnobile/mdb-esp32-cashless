// Central, data-driven descriptor for activity-log entries.
//
// One place that knows how to turn an `activity_log` row into (a) a human
// label and (b) a set of detail "chips". Consumed by the /history page and the
// dashboard activity feed so the two never drift apart again.
//
// Pure functions (they take an injected `t` and date formatter) so they are
// unit-testable without a Nuxt/i18n runtime. The thin `useActivityDescriptor`
// composable binds them to `useI18n()`.

export type ChipVariant = 'default' | 'increase' | 'decrease' | 'neutral'

export interface ActivityChip {
  label: string
  value: string
  variant?: ChipVariant
}

export interface ActivityEntryLike {
  action: string
  metadata: Record<string, unknown> | null
}

export type TFn = (key: string, named?: Record<string, unknown>) => string

export interface DescriptorCtx {
  t: TFn
  /** Locale-aware datetime formatter, e.g. `(iso) => formatDateTime(iso, locale)`. */
  formatDateTime?: (iso: string) => string
}

// Every action we render a proper (translated) label for. Anything not listed
// falls back to a humanised version of the raw action string.
const KNOWN_ACTIONS = new Set([
  'sale_recorded',
  'sale_deleted',
  'sale_inserted',
  'sale_restored',
  'credit_sent',
  'config_updated',
  'stock_updated',
  'stock_refill_all',
  'stock_refill_tour',
  'stock_refill_tour_skip',
  'tour_started',
  'product_swapped',
  'cash_book_created',
  'cash_book_deleted',
  'cash_book_entry_created',
  'machine_assigned_to_cash_book',
  'machine_unassigned_from_cash_book',
  'cash_book_settings_updated',
])

export function activityActionLabel(action: string, t: TFn): string {
  if (KNOWN_ACTIONS.has(action)) return t(`activity.actions.${action}`)
  return action.replace(/_/g, ' ')
}

// ── formatting helpers ──────────────────────────────────────────────────────

function euro(v: unknown): string {
  return `€${Number(v).toFixed(2)}`
}

function shortId(v: unknown): string {
  const s = String(v)
  return s.length > 8 ? s.slice(0, 8) + '…' : s
}

/** Map a `source:` provenance code to a translated label (null → no chip). */
function sourceLabel(source: unknown, t: TFn): string | null {
  switch (source) {
    case 'manual': return t('activity.sourceManual')
    case 'refill_wizard': return t('activity.sourceRefill')
    case 'refill_full': return t('activity.sourceRefillFull')
    case 'nayax_reconciliation': return t('activity.sourceNayax')
    case 'analysis_swap': return t('activity.sourceAnalysisSwap')
    case 'suppressed_restore': return t('activity.sourceSuppressedRestore')
    default: return null
  }
}

function stockChangeChip(label: string, oldVal: number, newVal: number): ActivityChip {
  const delta = newVal - oldVal
  const arrow = delta > 0 ? '↑' : delta < 0 ? '↓' : ''
  const sign = delta > 0 ? '+' : ''
  const variant: ChipVariant = delta > 0 ? 'increase' : delta < 0 ? 'decrease' : 'neutral'
  return { label, value: `${oldVal} ${arrow} ${newVal} (${sign}${delta})`, variant }
}

// ── chip builder ────────────────────────────────────────────────────────────

export function activityChips(entry: ActivityEntryLike, ctx: DescriptorCtx): ActivityChip[] {
  const m = entry.metadata
  if (!m) return []

  const { t } = ctx
  const chips: ActivityChip[] = []
  const F = (k: string) => t(`activity.field.${k}`)
  const date = (v: unknown) => (ctx.formatDateTime ? ctx.formatDateTime(String(v)) : String(v))

  const push = (label: string, value: unknown, variant?: ChipVariant) => {
    if (value == null || value === '') return
    chips.push({ label, value: String(value), variant })
  }

  // Machine name if known, else a short machine id so "which machine" is never
  // fully lost on older entries that only captured machine_id.
  const pushMachine = () => {
    if (m.machine_name) push(F('machine'), m.machine_name)
    else if (m.machine_id) push(F('machine'), shortId(m.machine_id))
  }
  // Product name when known; slot number always adds context.
  const pushProductAndSlot = () => {
    if (m.product_name) push(F('product'), m.product_name)
    if (m.item_number != null) push(F('slot'), `#${m.item_number}`)
  }
  const pushSource = () => {
    const label = sourceLabel(m.source, t)
    if (label) push(t('activity.source'), label)
  }

  switch (entry.action) {
    case 'sale_recorded': {
      // From the MQTT webhook (service_role). Uses `price`, has no machine name.
      if (m.item_number != null) push(F('slot'), `#${m.item_number}`)
      if (m.price != null) push(F('price'), euro(m.price))
      if (m.channel) push(F('channel'), m.channel)
      if (m.device_id) push(F('device'), shortId(m.device_id))
      break
    }

    case 'sale_deleted':
    case 'sale_inserted':
    case 'sale_restored': {
      pushMachine()
      pushProductAndSlot()
      if (m.item_price != null) push(F('price'), euro(m.item_price))
      if (m.channel) push(F('channel'), m.channel)
      if (m.sale_created_at) push(F('saleDate'), date(m.sale_created_at))
      if (m.stock_restored != null) {
        push(F('stockRestored'), m.stock_restored ? t('activity.yes') : t('activity.no'))
      }
      pushSource()
      break
    }

    case 'credit_sent': {
      if (m.amount != null) push(F('amount'), euro(m.amount))
      if (m.device_id) push(F('device'), shortId(m.device_id))
      break
    }

    case 'config_updated': {
      const cfg = m.config
      if (cfg && typeof cfg === 'object') {
        for (const [k, v] of Object.entries(cfg as Record<string, unknown>)) {
          push(k, v)
        }
      }
      break
    }

    case 'stock_updated': {
      pushMachine()
      if (m.product_name) push(F('product'), m.product_name)
      if (m.item_number != null) push(F('slot'), `#${m.item_number}`)
      pushSource()
      if (m.old_stock != null && m.new_stock != null) {
        chips.push(stockChangeChip(t('activity.stockLabel'), Number(m.old_stock), Number(m.new_stock)))
      } else if (m.new_stock != null) {
        push(t('activity.stockLabel'), m.new_stock)
      }
      if (m.old_min_stock != null && m.new_min_stock != null) {
        chips.push(stockChangeChip(F('minStock'), Number(m.old_min_stock), Number(m.new_min_stock)))
      }
      if (m.old_capacity != null && m.new_capacity != null) {
        chips.push(stockChangeChip(F('capacity'), Number(m.old_capacity), Number(m.new_capacity)))
      }
      break
    }

    case 'stock_refill_all': {
      pushMachine()
      const trays = Array.isArray(m.trays_refilled) ? (m.trays_refilled as any[]) : []
      if (trays.length) {
        push(F('trays'), `${trays.length} ${t('activity.refilled')}`)
        for (const tr of trays) {
          const name = tr.product_name ? String(tr.product_name) : `#${tr.item_number}`
          chips.push(stockChangeChip(name, Number(tr.old_stock), Number(tr.new_stock)))
        }
      }
      break
    }

    case 'stock_refill_tour': {
      pushMachine()
      if (m.warehouse_name) push(F('warehouse'), m.warehouse_name)
      if (m.trays_refilled != null) {
        const n = Array.isArray(m.trays_refilled) ? m.trays_refilled.length : m.trays_refilled
        push(F('trays'), n)
      }
      if (m.total_added != null) push(F('totalAdded'), `+${m.total_added}`, 'increase')
      const products = Array.isArray(m.products) ? (m.products as any[]) : []
      for (const p of products.slice(0, 6)) {
        if (p?.product_name) push(String(p.product_name), `×${p.quantity ?? '?'}`)
      }
      break
    }

    case 'stock_refill_tour_skip': {
      pushMachine()
      break
    }

    case 'tour_started': {
      if (m.warehouse_name) push(F('warehouse'), m.warehouse_name)
      if (m.machine_count != null) push(F('machines'), String(m.machine_count))
      const names = Array.isArray(m.machine_names) ? (m.machine_names as unknown[]) : []
      if (names.length) {
        const shown = names.slice(0, 4).join(', ')
        push('', names.length > 4 ? `${shown}…` : shown)
      }
      break
    }

    case 'product_swapped': {
      pushMachine()
      if (m.item_number != null) push(F('slot'), `#${m.item_number}`)
      if (m.old_product_name) push(F('fromProduct'), m.old_product_name, 'decrease')
      if (m.new_product_name) push(F('toProduct'), m.new_product_name, 'increase')
      break
    }

    case 'cash_book_created': {
      if (m.name) push(F('cashBook'), m.name)
      if (m.initial_balance != null) push(F('initialBalance'), euro(m.initial_balance))
      if (m.threshold != null) push(F('threshold'), euro(m.threshold))
      if (m.track_per_machine != null) {
        push(F('perMachine'), m.track_per_machine ? t('activity.yes') : t('activity.no'))
      }
      break
    }

    case 'cash_book_entry_created': {
      if (m.type) push(F('type'), m.type)
      if (m.amount != null) push(F('amount'), euro(m.amount))
      if (m.category) push(F('category'), m.category)
      if (m.description) push(F('note'), m.description)
      break
    }

    case 'machine_assigned_to_cash_book':
    case 'machine_unassigned_from_cash_book': {
      pushMachine()
      if (m.cash_book_name) push(F('cashBook'), m.cash_book_name)
      else if (m.name) push(F('cashBook'), m.name)
      break
    }

    case 'cash_book_settings_updated': {
      const patch = m.patch
      if (patch && typeof patch === 'object') {
        for (const [k, v] of Object.entries(patch as Record<string, unknown>)) {
          push(k, typeof v === 'boolean' ? (v ? t('activity.yes') : t('activity.no')) : v)
        }
      }
      break
    }

    // cash_book_deleted and any other action → label only, no chips.
    default:
      break
  }

  return chips
}

// ── compact single-line summary (dashboard feed) ────────────────────────────

/** The most salient chip values joined with " · ", capped for a one-line feed. */
export function activitySummary(entry: ActivityEntryLike, ctx: DescriptorCtx): string {
  const chips = activityChips(entry, ctx)
  if (chips.length) {
    return chips.slice(0, 3).map(c => c.value).join(' · ')
  }
  // Fallback for entries whose action produces no chips.
  const m = entry.metadata
  if (!m) return ''
  const name = m.machine_name ?? m.product_name ?? m.device_name ?? m.name
  return name ? String(name) : ''
}
