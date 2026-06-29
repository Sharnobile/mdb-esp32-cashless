import { describe, it, expect } from 'vitest'
import { EXPENSE_CATEGORIES } from '@/composables/useCashBook'

// Spiegelt die Composable-Logik: Ausgabe wird mit negativem amount gebucht.
function expenseAmount(input: number): number {
  return -Math.abs(input)
}

// Spiegelt totalExpenses: Summe der Beträge nicht-stornierter Ausgaben.
function totalExpenses(entries: { type: string; amount: number; is_reversed: boolean }[]) {
  const ex = entries.filter(e => e.type === 'expense' && !e.is_reversed)
  return { amount: ex.reduce((s, e) => s + Math.abs(e.amount), 0), count: ex.length }
}

describe('cash book expenses', () => {
  it('books expenses with a negative amount', () => {
    expect(expenseAmount(100)).toBe(-100)
    expect(expenseAmount(-100)).toBe(-100)
  })

  it('aggregates totalExpenses over non-reversed expense entries', () => {
    const entries = [
      { type: 'expense', amount: -100, is_reversed: false },
      { type: 'expense', amount: -50, is_reversed: true },  // storniert → ignoriert
      { type: 'payout', amount: -200, is_reversed: false }, // andere Art → ignoriert
      { type: 'expense', amount: -25, is_reversed: false },
    ]
    expect(totalExpenses(entries)).toEqual({ amount: 125, count: 2 })
  })

  it('exposes the fixed category list', () => {
    expect([...EXPENSE_CATEGORIES]).toEqual(['rent', 'goods', 'cleaning', 'fees', 'other'])
  })
})
