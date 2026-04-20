/**
 * Tests for notification-i18n helpers.
 * Run: deno test Docker/supabase/functions/_shared/notification-i18n.test.ts
 */

import { assertEquals, assert, assertStringIncludes } from 'jsr:@std/assert'
import { normalizeLocale, t, formatPrice } from './notification-i18n.ts'

// ── normalizeLocale ──────────────────────────────────────────────────────────

Deno.test('normalizeLocale: accepts "de" and "en" as-is', () => {
  assertEquals(normalizeLocale('de'), 'de')
  assertEquals(normalizeLocale('en'), 'en')
})

Deno.test('normalizeLocale: case-insensitive', () => {
  assertEquals(normalizeLocale('DE'), 'de')
  assertEquals(normalizeLocale('En'), 'en')
})

Deno.test('normalizeLocale: strips region tag', () => {
  assertEquals(normalizeLocale('de-DE'), 'de')
  assertEquals(normalizeLocale('en-US'), 'en')
  assertEquals(normalizeLocale('de_AT'), 'de')
})

Deno.test('normalizeLocale: unknown → en', () => {
  assertEquals(normalizeLocale('fr'), 'en')
  assertEquals(normalizeLocale('xx-YY'), 'en')
})

Deno.test('normalizeLocale: null / undefined / empty → en', () => {
  assertEquals(normalizeLocale(null), 'en')
  assertEquals(normalizeLocale(undefined), 'en')
  assertEquals(normalizeLocale(''), 'en')
})

// ── t() dictionary ───────────────────────────────────────────────────────────

Deno.test('t: all keys present for both locales', () => {
  const expectedKeys = [
    'sale', 'left', 'refillAt', 'noStockInfo',
    'lowStockTitle', 'remaining', 'testMachine', 'sampleProduct',
  ]
  for (const key of expectedKeys) {
    assert(key in t('en'), `'en' missing key "${key}"`)
    assert(key in t('de'), `'de' missing key "${key}"`)
  }
})

Deno.test('t: en strings', () => {
  const en = t('en')
  assertEquals(en.sale, 'Sale')
  assertEquals(en.left, 'left')
  assertEquals(en.refillAt(5), 'refill at 5')
  assertEquals(en.noStockInfo, 'No stock info')
  assertEquals(en.lowStockTitle, 'Low Stock Alert')
  assertEquals(en.remaining, 'remaining')
  assertEquals(en.testMachine, 'Test Machine')
  assertEquals(en.sampleProduct, 'Sample Product')
})

Deno.test('t: de strings', () => {
  const de = t('de')
  assertEquals(de.sale, 'Verkauf')
  assertEquals(de.left, 'übrig')
  assertEquals(de.refillAt(5), 'nachfüllen bei 5')
  assertEquals(de.noStockInfo, 'Kein Bestand')
  assertEquals(de.lowStockTitle, 'Bestandswarnung')
  assertEquals(de.remaining, 'übrig')
  assertEquals(de.testMachine, 'Testmaschine')
  assertEquals(de.sampleProduct, 'Beispielprodukt')
})

// ── formatPrice ──────────────────────────────────────────────────────────────

Deno.test('formatPrice: en uses dot decimal, € prefix', () => {
  const s = formatPrice(2.5, 'en')
  assertStringIncludes(s, '2.50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: de uses comma decimal, € suffix', () => {
  const s = formatPrice(2.5, 'de')
  assertStringIncludes(s, '2,50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: handles whole numbers', () => {
  assertStringIncludes(formatPrice(10, 'en'), '10.00')
  assertStringIncludes(formatPrice(10, 'de'), '10,00')
})
