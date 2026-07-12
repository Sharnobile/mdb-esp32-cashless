import { describe, it, expect } from 'vitest'
import { activityActionLabel, activityChips, activitySummary } from '../activityDescriptor'
import type { ActivityChip } from '../activityDescriptor'

// Identity `t`: returns the key path so we can assert which i18n keys are used,
// and interpolates {named} params so pluralised labels are still checkable.
const t = (key: string, named?: Record<string, unknown>) => {
  if (!named) return key
  return key + '(' + Object.entries(named).map(([k, v]) => `${k}=${v}`).join(',') + ')'
}
const ctx = { t, formatDateTime: (iso: string) => `DT[${iso}]` }

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

describe('activityChips — sale_deleted (the reported gap)', () => {
  it('surfaces machine, product, price, channel and sale date from a full manual-delete entry', () => {
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
    expect(valueOf(chips, 'activity.field.product')).toBe('Coca-Cola')
    expect(valueOf(chips, 'activity.field.slot')).toBe('#14')
    expect(valueOf(chips, 'activity.field.price')).toBe('€1.50')
    expect(valueOf(chips, 'activity.field.channel')).toBe('cashless')
    expect(valueOf(chips, 'activity.field.saleDate')).toBe('DT[2026-07-10T09:30:00Z]')
  })

  it('falls back to slot + short machine id for old entries lacking product_name / machine_name', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: {
        machine_id: 'abcd1234-0000-0000',
        item_number: 7,
        item_price: 2,
        channel: 'cash',
        sale_created_at: '2026-06-01T12:00:00Z',
      },
    }, ctx)

    // no product chip when product unknown
    expect(byLabel(chips, 'activity.field.product')).toBeUndefined()
    // slot still shown
    expect(valueOf(chips, 'activity.field.slot')).toBe('#7')
    // machine falls back to a short id, not omitted
    expect(valueOf(chips, 'activity.field.machine')).toBe('abcd1234…')
    expect(valueOf(chips, 'activity.field.price')).toBe('€2.00')
  })

  it('shows the stock-restored flag and the Nayax source for a ghost delete', () => {
    const chips = activityChips({
      action: 'sale_deleted',
      metadata: {
        machine_id: 'm1',
        item_number: 3,
        item_price: 1.2,
        sale_created_at: '2026-06-02T08:00:00Z',
        stock_restored: true,
        source: 'nayax_reconciliation',
      },
    }, ctx)

    expect(valueOf(chips, 'activity.field.stockRestored')).toBe('activity.yes')
    expect(valueOf(chips, 'activity.source')).toBe('activity.sourceNayax')
  })
})

describe('activityChips — other previously-blank actions', () => {
  it('sale_inserted shows the sale facts', () => {
    const chips = activityChips({
      action: 'sale_inserted',
      metadata: { machine_name: 'M2', item_number: 5, item_price: 3, channel: 'cash', source: 'manual' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.machine')).toBe('M2')
    expect(valueOf(chips, 'activity.field.price')).toBe('€3.00')
    expect(valueOf(chips, 'activity.source')).toBe('activity.sourceManual')
  })

  it('product_swapped shows from/to products and slot', () => {
    const chips = activityChips({
      action: 'product_swapped',
      metadata: { machine_id: 'm', item_number: 12, old_product_name: 'Water', new_product_name: 'Cola' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.slot')).toBe('#12')
    expect(valueOf(chips, 'activity.field.fromProduct')).toBe('Water')
    expect(valueOf(chips, 'activity.field.toProduct')).toBe('Cola')
  })

  it('tour_started shows warehouse and machine count', () => {
    const chips = activityChips({
      action: 'tour_started',
      metadata: { warehouse_name: 'WH-1', machine_count: 3, machine_names: ['A', 'B', 'C'] },
    }, ctx)
    expect(valueOf(chips, 'activity.field.warehouse')).toBe('WH-1')
    expect(valueOf(chips, 'activity.field.machines')).toContain('3')
  })

  it('cash_book_entry_created shows type, amount and category', () => {
    const chips = activityChips({
      action: 'cash_book_entry_created',
      metadata: { type: 'expense', amount: 49.9, category: 'rent', description: 'Miete Juli' },
    }, ctx)
    expect(valueOf(chips, 'activity.field.amount')).toBe('€49.90')
    expect(valueOf(chips, 'activity.field.category')).toBe('rent')
  })
})

describe('activityChips — preserved behaviour', () => {
  it('stock_updated keeps the old→new stock-change chip', () => {
    const chips = activityChips({
      action: 'stock_updated',
      metadata: { machine_name: 'M', product_name: 'P', item_number: 1, old_stock: 2, new_stock: 8, source: 'manual' },
    }, ctx)
    const stock = byLabel(chips, 'activity.stockLabel')
    expect(stock?.value).toContain('2')
    expect(stock?.value).toContain('8')
    expect(stock?.variant).toBe('increase')
  })

  it('returns no chips for null metadata or unknown actions', () => {
    expect(activityChips({ action: 'sale_deleted', metadata: null }, ctx)).toEqual([])
    expect(activityChips({ action: 'totally_unknown', metadata: { x: 1 } }, ctx)).toEqual([])
  })
})

describe('activitySummary — compact dashboard line', () => {
  it('joins the most salient values with a middot', () => {
    const summary = activitySummary({
      action: 'sale_deleted',
      metadata: { machine_name: 'M1', product_name: 'Cola', item_price: 1.5, channel: 'cash' },
    }, ctx)
    expect(summary).toContain('M1')
    expect(summary).toContain('Cola')
    expect(summary).toContain(' · ')
  })

  it('is empty when there is nothing to show', () => {
    expect(activitySummary({ action: 'cash_book_deleted', metadata: {} }, ctx)).toBe('')
  })
})
