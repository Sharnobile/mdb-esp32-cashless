/**
 * Tests for the deal-source provider resolver.
 *
 * Run: deno test Docker/supabase/functions/deal-search/resolve-providers.test.ts
 */

import { assertEquals } from 'jsr:@std/assert'
import { resolveProviders, type ProviderRow } from './resolve-providers.ts'

// ── Mock supabase admin client ────────────────────────────────────────────────

function mockAdminClient(rows: ProviderRow[]) {
  const calls: { table: string; filters: Record<string, unknown> }[] = []
  // deno-lint-ignore no-explicit-any
  const client: any = {
    from(table: string) {
      const filters: Record<string, unknown> = {}
      const builder = {
        select(_cols: string) { return builder },
        eq(col: string, val: unknown) { filters[col] = val; return builder },
        // PostgrestFilterBuilder is thenable on every link of an .eq() chain;
        // `await` invokes then() on whichever .eq() the resolver awaits. The
        // mock mirrors that by exposing then() on the same builder object.
        then(onFulfilled: (v: unknown) => unknown) {
          calls.push({ table, filters: { ...filters } })
          return Promise.resolve({ data: rows, error: null }).then(onFulfilled)
        },
      }
      return builder
    },
  }
  return { client, calls }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Deno.test('resolveProviders returns built-in for known provider_id', async () => {
  const { client, calls } = mockAdminClient([
    { provider_id: 'marktguru', config: {} },
  ])

  const result = await resolveProviders(client, 'co-1')

  assertEquals(result.length, 1)
  assertEquals(result[0].provider.id, 'marktguru')
  assertEquals(calls.length, 1)
  assertEquals(calls[0].table, 'provider_settings')
  assertEquals(calls[0].filters['company_id'], 'co-1')
  assertEquals(calls[0].filters['extension_point'], 'deal-source')
  assertEquals(calls[0].filters['enabled'], true)
})

Deno.test('resolveProviders wraps webhook-* provider_ids', async () => {
  const { client } = mockAdminClient([
    {
      provider_id: 'webhook-abc-123',
      config: { url: 'https://hook.example/deals', authToken: 't' },
    },
  ])

  const result = await resolveProviders(client, 'co-1')

  assertEquals(result.length, 1)
  assertEquals(result[0].provider.id, 'webhook-abc-123')
  assertEquals(typeof result[0].provider.fetchOffers, 'function')
})

Deno.test('resolveProviders skips webhook rows with missing url/authToken', async () => {
  // NOTE: IDs are intentionally non-overlapping (not substrings of each other)
  // so that .includes() filters produce exact, unambiguous counts.
  const { client } = mockAdminClient([
    { provider_id: 'webhook-no-token', config: { url: 'https://x' } },
    { provider_id: 'webhook-no-url', config: { authToken: 't' } },
    { provider_id: 'marktguru', config: {} },
  ])

  const warns: string[] = []
  const origWarn = console.warn
  console.warn = (...args: unknown[]) => { warns.push(args.map(String).join(' ')) }
  try {
    const result = await resolveProviders(client, 'co-1')
    assertEquals(result.length, 1)
    assertEquals(result[0].provider.id, 'marktguru')
    assertEquals(warns.filter((w) => w.includes('webhook-no-token')).length, 1)
    assertEquals(warns.filter((w) => w.includes('webhook-no-url')).length, 1)
  } finally {
    console.warn = origWarn
  }
})

Deno.test('resolveProviders warns and skips unknown provider_ids', async () => {
  const { client } = mockAdminClient([
    { provider_id: 'totally-made-up', config: {} },
    { provider_id: 'marktguru', config: {} },
  ])

  const warns: string[] = []
  const origWarn = console.warn
  console.warn = (...args: unknown[]) => { warns.push(args.map(String).join(' ')) }
  try {
    const result = await resolveProviders(client, 'co-1')
    assertEquals(result.length, 1)
    assertEquals(result[0].provider.id, 'marktguru')
    assertEquals(warns.filter((w) => w.includes('totally-made-up')).length, 1)
  } finally {
    console.warn = origWarn
  }
})

Deno.test('resolveProviders returns empty array when no rows enabled', async () => {
  const { client } = mockAdminClient([])
  const result = await resolveProviders(client, 'co-1')
  assertEquals(result, [])
})
