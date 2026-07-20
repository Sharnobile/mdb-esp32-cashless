/**
 * Tests for notification-i18n helpers.
 * Run: deno test Docker/supabase/functions/_shared/notification-i18n.test.ts
 */

import { assertEquals, assert, assertStringIncludes } from 'jsr:@std/assert'
import { normalizeLocale, t, formatPrice } from './notification-i18n.ts'

// ── normalizeLocale ──────────────────────────────────────────────────────────

Deno.test('normalizeLocale: accepts "de", "en", "fr" and "nl" as-is', () => {
  assertEquals(normalizeLocale('de'), 'de')
  assertEquals(normalizeLocale('en'), 'en')
  assertEquals(normalizeLocale('fr'), 'fr')
  assertEquals(normalizeLocale('nl'), 'nl')
})

Deno.test('normalizeLocale: case-insensitive', () => {
  assertEquals(normalizeLocale('DE'), 'de')
  assertEquals(normalizeLocale('En'), 'en')
  assertEquals(normalizeLocale('Fr'), 'fr')
  assertEquals(normalizeLocale('Nl'), 'nl')
})

Deno.test('normalizeLocale: strips region tag', () => {
  assertEquals(normalizeLocale('de-DE'), 'de')
  assertEquals(normalizeLocale('en-US'), 'en')
  assertEquals(normalizeLocale('de_AT'), 'de')
  assertEquals(normalizeLocale('fr-FR'), 'fr')
  assertEquals(normalizeLocale('nl-BE'), 'nl')
})

Deno.test('normalizeLocale: unknown → en', () => {
  assertEquals(normalizeLocale('xx-YY'), 'en')
})

Deno.test('normalizeLocale: null / undefined / empty → en', () => {
  assertEquals(normalizeLocale(null), 'en')
  assertEquals(normalizeLocale(undefined), 'en')
  assertEquals(normalizeLocale(''), 'en')
})

// ── t() dictionary ───────────────────────────────────────────────────────────

Deno.test('t: all keys present for all locales', () => {
  const expectedKeys = [
    'sale', 'left', 'refillAt', 'noStockInfo',
    'lowStockTitle', 'remaining', 'testMachine', 'sampleProduct',
  ]
  for (const key of expectedKeys) {
    assert(key in t('en'), `'en' missing key "${key}"`)
    assert(key in t('de'), `'de' missing key "${key}"`)
    assert(key in t('fr'), `'fr' missing key "${key}"`)
    assert(key in t('nl'), `'nl' missing key "${key}"`)
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

Deno.test('t: fr strings', () => {
  const fr = t('fr')
  assertEquals(fr.sale, 'Vente')
  assertEquals(fr.left, 'restant')
  assertEquals(fr.refillAt(5), 'réapprovisionner à 5')
  assertEquals(fr.noStockInfo, 'Aucune info de stock')
  assertEquals(fr.lowStockTitle, 'Alerte stock bas')
  assertEquals(fr.remaining, 'restant')
  assertEquals(fr.testMachine, 'Machine de test')
  assertEquals(fr.sampleProduct, 'Produit exemple')
})

Deno.test('t: nl strings', () => {
  const nl = t('nl')
  assertEquals(nl.sale, 'Verkoop')
  assertEquals(nl.left, 'over')
  assertEquals(nl.refillAt(5), 'bijvullen bij 5')
  assertEquals(nl.noStockInfo, 'Geen voorraadinfo')
  assertEquals(nl.lowStockTitle, 'Lage voorraad melding')
  assertEquals(nl.remaining, 'over')
  assertEquals(nl.testMachine, 'Testmachine')
  assertEquals(nl.sampleProduct, 'Voorbeeldproduct')
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

Deno.test('formatPrice: fr uses comma decimal, € suffix', () => {
  const s = formatPrice(2.5, 'fr')
  assertStringIncludes(s, '2,50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: nl uses comma decimal, €', () => {
  const s = formatPrice(2.5, 'nl')
  assertStringIncludes(s, '2,50')
  assertStringIncludes(s, '€')
})

Deno.test('formatPrice: handles whole numbers', () => {
  assertStringIncludes(formatPrice(10, 'en'), '10.00')
  assertStringIncludes(formatPrice(10, 'de'), '10,00')
  assertStringIncludes(formatPrice(10, 'fr'), '10,00')
  assertStringIncludes(formatPrice(10, 'nl'), '10,00')
})
