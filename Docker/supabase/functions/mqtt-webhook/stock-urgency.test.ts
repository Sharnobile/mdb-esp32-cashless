/**
 * Tests for the stockUrgency pure helper.
 * Run: deno test Docker/supabase/functions/mqtt-webhook/stock-urgency.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import { stockUrgency } from './stock-urgency.ts'

Deno.test('stockUrgency: empty tray returns 🚨', () => {
  assertEquals(stockUrgency(0, 5), '🚨 ')
  assertEquals(stockUrgency(0, 0), '🚨 ')
})

Deno.test('stockUrgency: current below threshold returns ⚠️', () => {
  assertEquals(stockUrgency(3, 5), '⚠️ ')
  assertEquals(stockUrgency(5, 5), '⚠️ ') // at threshold counts as critical
  assertEquals(stockUrgency(1, 5), '⚠️ ')
})

Deno.test('stockUrgency: current within 1.5× threshold returns 🟡', () => {
  assertEquals(stockUrgency(6, 5), '🟡 ')   // 6 ≤ 7.5
  assertEquals(stockUrgency(7, 5), '🟡 ')   // 7 ≤ 7.5
  // 8 > 7.5 → normal (no emoji)
})

Deno.test('stockUrgency: current well above threshold returns empty', () => {
  assertEquals(stockUrgency(10, 5), '')
  assertEquals(stockUrgency(8, 5), '')
})

Deno.test('stockUrgency: zero threshold disables warning, keeps empty marker', () => {
  // fill_when_below = 0 means "no threshold configured"
  // Only the empty-tray marker applies.
  assertEquals(stockUrgency(5, 0), '')
  assertEquals(stockUrgency(1, 0), '')
  assertEquals(stockUrgency(0, 0), '🚨 ')
})
