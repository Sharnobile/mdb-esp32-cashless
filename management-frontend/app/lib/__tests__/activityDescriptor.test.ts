import { describe, it, expect } from 'vitest'
import {
  activityActionLabel,
  activityChips,
  activityIcon,
  activityProductRef,
  activitySummary,
} from '../activityDescriptor'
import type { ActivityChip } from '../activityDescriptor'

// Identity `t`: returns the key path so we can assert which i18n keys are used,
// and interpolates {named} params so pluralised labels are still checkable.
const t = (key: string, named?: Record<string, unknown>) => {
  if (!named) return key
  return key + '(' + Object.entries(named).map(([k, v]) => `${k}=${v}`).join(',') + ')'
}
// A machine-id → name lookup, as the /history page injects at runtime.
const machineName = (id: string) => (id === 'm-uuid-1234-5678' ? 'Getränkeautomat 1' : undefined)
// A device/embedded-id → machine name lookup (sale_recorded/credit_sent).
const machineNameByDevice = (id: string) => (id === 'dev-embedded-1' ? 'Snackautomat 3' : undefined)
const ctx = { t, formatDateTime: (iso: string) => `DT[${iso}]`, machineName, machineNameByDevice }

const byLabel = (chips: ActivityChip[], label: string) => chips.find(c => c.label === label)
const valueOf = (chips: ActivityChip[], label: string) => byLabel(chips, label)?.value

describe('activityActionLabel', () => {
  it('maps a known action to its i18n key', () => {
    expect(activityActionLabel('sale_deleted', t)).toBe('activity.actions.sale_deleted')
    expect(activityActionLabel('product_swapped', t)).toBe('activity.actions.product_swapped')
    expect(activityActionLabel('cash_book_entry_created', t)).toBe('activity.actions.cash_book_entry_created')
  })

  it('humanises an unknown action instead of showing raw snake_case', () => {
    expect(activityActionLabel('some_new_action', t)).toBe('some new action')
  })
})

describe('activityIcon', () => {
  it('gives each action a leading icon + colour bucket', () => {
    expect(activityIcon('sale_deleted')).toEqual({ icon: 'Trash2', tint: 'danger' })
    expect(activityIcon('sale_recorded')).toEqual({ icon: 'ShoppingCart', tint: 'sale' })
    expect(activityIcon('cash_book_entry_created')).toEqual({ icon: 'Coins', tint: 'cashbook' })
    expect(activityIcon('tour_started')).toEqual({ icon: 'Truck', tint: 'tour' })
  })

  it('falls back to a neutral generic icon for unknown actions', () => {
    expect(activityIcon('whatever')).toEqual({ icon: 'Activity', tint: 'neutral' })
  })
})

describe('activityProductRef — drives the row thumbnail', () => {
  it('returns the product for a sale deletion', () => {
    expect(activityProductRef({
      action: 'sale_deleted',
      metadata: { product_id: 'p1', product_name: 'Coca-Cola' },
    })).toEqual({ productId: 'p1', productName: 'Coca-Cola' })
  })

  it('returns null when the entry carries no product', () => {
    expect(activityProductRef({ action: 'sale_deleted', metadata: { item_number: 3 } })).toBeNull()
    expect(activityProductRef({ action: 'tour_started', metadata: { machine_count: 2 } })).toBeNull()
    expect(activityProductRef({ action: 'sale_recorded', metadata: { item_number: 1 } })).toBeNull()
  })

  it('returns the product for a real MDB sale (sale_recorded)', () => {
    expect(activityProductRef({
      action: 'sale_recorded',
      metadata: { product_id: 'p1', product_name: 'Coca-Cola', item_number: 12 },
    })).toEqual({ productId: 'p1', productName: 'Coca-Cola' })
  })

  it('returns null for a sale_recorded row predating this field (no product_id/name)', () => {
    expect(activityProductRef({
      action: 'sale_recorded',
      metadata: { item_number: 12, price: 2.5, channel: 'cash', device_id: 'dev-1' },
    })).toBeNull()
  })
})

describe('activityChips — sale_deleted (the reported gap)', () => {
  it('surfaces machine, slot, price, channel and sale date; product is NOT a chip', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: {
        machine_id: 'm-uuid-1234-5678',
        machine_name: 'Getränkeautomat 1',
        item_number: 14,
        item_price: 1.5,
        channel: 'cashless',
        sale_created_at: '2026-07-10T09:30:00Z',
        product_name: 'Coca-Cola',
      },
    }, ctx)

    expect(valueOf(chips, 'activity.field.machine')).toBe('Getränkeautomat 1')
    expect(valueOf(chips, 'activity.field.slot')).toBe('#14')
    expect(valueOf(chips, 'activity.field.price')).toBe('€1.50')
    expect(valueOf(chips, 'activity.field.channel')).toBe('cashless')
    expect(valueOf(chips, 'activity.field.saleDate')).toBe('DT[2026-07-10T09:30:00Z]')
    // product is rendered as a thumbnail, not a chip
    expect(byLabel(chips, 'activity.field.product')).toBeUndefined()
    // chips carry icons for the new UI
    expect(byLabel(chips, 'activity.field.machine')?.icon).toBe('MapPin')
    expect(byLabel(chips, 'activity.field.price')?.icon).toBe('Euro')
  })

  it('resolves machine_id to a NAME via the injected lookup — never a raw UUID', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: { machine_id: 'm-uuid-1234-5678', item_number: 7, item_price: 2 },
    }, ctx)
    expect(valueOf(chips, 'activity.field.machine')).toBe('Getränkeautomat 1')
    // the raw id must not leak into any chip value
    expect(chips.every(c => !c.value.includes('m-uuid'))).toBe(true)
  })

  it('omits the machine chip entirely when the id cannot be resolved (no UUID fallback)', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: { machine_id: 'unknown-id-0000', item_number: 7, item_price: 2 },
    }, ctx)
    expect(byLabel(chips, 'activity.field.machine')).toBeUndefined()
  })

  it('shows the stock-restored flag and the Nayax source for a ghost delete', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: {
        machine_name: 'M', item_number: 3, item_price: 1.2,
        stock_restored: true, source: 'nayax_reconciliation',
      },
    }, ctx)
    expect(valueOf(chips, 'activity.field.stockRestored')).toBe('activity.yes')
    expect(valueOf(chips, 'activity.source')).toBe('activity.sourceNayax')
  })
})

describe('activityChips — sale_recorded resolves the device to a machine name', () => {
  it('shows the machine NAME (from device_id), never the embedded UUID', () => {
    const chips = activityChips({
      action: 'sale_recorded',
      metadata: { device_id: 'dev-embedded-1', item_number: 5, price: 2.5, channel: 'cash' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.machine')).toBe('Snackautomat 3')
    expect(valueOf(chips, 'activity.field.price')).toBe('€2.50')
    // the device id must not appear as a chip anywhere
    expect(byLabel(chips, 'activity.field.device')).toBeUndefined()
    expect(chips.every(c => !c.value.includes('dev-embedded'))).toBe(true)
  })

  it('omits the machine chip when the device cannot be resolved (no UUID fallback)', () => {
    const chips = activityChips({
      action: 'sale_recorded',
      metadata: { device_id: 'unknown-dev', item_number: 5, price: 2.5 },
    }, ctx)
    expect(byLabel(chips, 'activity.field.machine')).toBeUndefined()
    expect(chips.every(c => !c.value.includes('unknown-dev'))).toBe(true)
  })
})

describe('activityChips — other actions', () => {
  it('product_swapped shows from/to products and slot', () => {
    const chips = activityChips({
      action: 'product_swapped',
      metadata: { machine_name: 'M', item_number: 12, old_product_name: 'Water', new_product_name: 'Cola' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.slot')).toBe('#12')
    expect(valueOf(chips, 'activity.field.fromProduct')).toBe('Water')
    expect(valueOf(chips, 'activity.field.toProduct')).toBe('Cola')
  })

  it('cash_book_entry_created shows type, amount and category', () => {
    const chips = activityChips({
      action: 'cash_book_entry_created',
      metadata: { type: 'expense', amount: 49.9, category: 'rent', description: 'Miete Juli' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.amount')).toBe('€49.90')
    expect(valueOf(chips, 'activity.field.category')).toBe('rent')
  })

  it('stock_updated keeps the old→new stock-change chip with a directional icon', () => {
    const chips = activityChips({
      action: 'stock_updated',
      metadata: { machine_name: 'M', product_name: 'P', item_number: 1, old_stock: 2, new_stock: 8, source: 'manual' },
    }, ctx)
    const stock = byLabel(chips, 'activity.stockLabel')
    expect(stock?.value).toContain('2')
    expect(stock?.value).toContain('8')
    expect(stock?.variant).toBe('increase')
    expect(stock?.icon).toBe('ArrowUpRight')
    // product handled by thumbnail, not chip
    expect(byLabel(chips, 'activity.field.product')).toBeUndefined()
  })

  it('returns no chips for null metadata or unknown actions', () => {
    expect(activityChips({ action: 'sale_deleted', metadata: null }, ctx)).toEqual([])
    expect(activityChips({ action: 'totally_unknown', metadata: { x: 1 } }, ctx)).toEqual([])
  })
})

describe('activitySummary — compact dashboard line', () => {
  it('leads with the product name, then salient values', () => {
    const summary = activitySummary({
      action: 'sale_deleted',
      metadata: { machine_name: 'M1', product_name: 'Cola', item_price: 1.5, channel: 'cash' },
    }, ctx)
    expect(summary.startsWith('Cola')).toBe(true)
    expect(summary).toContain('M1')
    expect(summary).toContain(' · ')
  })

  it('is empty when there is nothing to show', () => {
    expect(activitySummary({ action: 'cash_book_deleted', metadata: {} }, ctx)).toBe('')
  })
})
