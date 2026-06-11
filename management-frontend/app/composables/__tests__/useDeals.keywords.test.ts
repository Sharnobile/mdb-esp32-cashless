import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef, computed as vueComputed } from 'vue'

const mockSupabase = {
  from: vi.fn(),
}

// useDeals.ts uses Nuxt auto-imports (`ref`, `computed`, `useState`,
// `useSupabaseClient`) as bare globals — there's no explicit `#imports`
// import at the top of the file. Expose them on `globalThis` so the module
// can evaluate at import time. Mirrors the `useWarehouse.test.ts` pattern.
;(globalThis as any).ref = vueRef
;(globalThis as any).computed = vueComputed
;(globalThis as any).useState = <T,>(_k: string, init?: () => T) => vueRef(init ? init() : undefined)
;(globalThis as any).useSupabaseClient = () => mockSupabase
;(globalThis as any).useSupabaseUser = () => vueRef({ id: 'user-1' })
;(globalThis as any).useOrganization = () => ({ organization: vueRef({ id: 'company-1' }) })

vi.mock('#imports', () => ({
  useSupabaseClient: () => mockSupabase,
  useSupabaseUser: () => ({ value: { id: 'user-1' } }),
  useState: (_key: string, init: () => unknown) => ({ value: init() }),
}))

// Nuxt auto-imports don't always route through the `#imports` alias at test
// time, so mock useOrganization directly as well. Mirrors the known-working
// pattern in `useWarehouse.test.ts`.
vi.mock('../useOrganization', () => ({
  useOrganization: () => ({ organization: { value: { id: 'company-1' } } }),
}))

import { useDeals } from '../useDeals'

function makeFromChain(overrides: Record<string, any> = {}) {
  const chain: any = {
    select: vi.fn(() => chain),
    insert: vi.fn(() => chain),
    update: vi.fn(() => chain),
    delete: vi.fn(() => chain),
    eq: vi.fn(() => chain),
    order: vi.fn(() => chain),
    single: vi.fn(() => Promise.resolve({ data: null, error: null })),
    ...overrides,
  }
  chain.then = (resolve: any) => resolve({ data: overrides.__data ?? [], error: null })
  return chain
}

describe('useDeals — keywords', () => {
  beforeEach(() => {
    mockSupabase.from.mockReset()
  })

  it('createKeyword inserts the group and links products', async () => {
    const insertedGroup = { id: 'kw-1', label: 'Haribo', terms: ['Haribo Fruchtgummis'], created_at: 't', updated_at: 't' }
    mockSupabase.from.mockImplementation((table: string) => {
      if (table === 'deal_keywords') {
        return makeFromChain({ single: () => Promise.resolve({ data: insertedGroup, error: null }), __data: [insertedGroup] })
      }
      if (table === 'deal_keyword_products') {
        return makeFromChain({ __data: [] })
      }
      return makeFromChain()
    })

    const { createKeyword } = useDeals()
    await createKeyword({ label: 'Haribo', terms: ['Haribo Fruchtgummis'], product_ids: ['p-1', 'p-2'] })

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    expect(tables).toContain('deal_keywords')
    expect(tables).toContain('deal_keyword_products')
  })

  it('deleteKeyword cascades via DB (just deletes the group)', async () => {
    mockSupabase.from.mockImplementation(() => makeFromChain({ __data: [] }))

    const { deleteKeyword } = useDeals()
    await deleteKeyword('kw-1')

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    expect(tables).toContain('deal_keywords')
  })

  it('setKeywordProducts deletes old links and inserts new ones', async () => {
    mockSupabase.from.mockImplementation(() => makeFromChain({ __data: [] }))

    const { setKeywordProducts } = useDeals()
    await setKeywordProducts('kw-1', ['p-3', 'p-4'])

    const tables = mockSupabase.from.mock.calls.map((c: any[]) => c[0])
    const linkCalls = tables.filter((t: string) => t === 'deal_keyword_products')
    expect(linkCalls.length).toBeGreaterThanOrEqual(2) // one delete + one insert
  })
})

describe('useDeals — enable toggle', () => {
  it('seeds the daily refresh hour to 06:00 when deals are first enabled', () => {
    const { dealsEnabled, dealsRefreshHour, setDealsEnabled } = useDeals()
    expect(dealsRefreshHour.value).toBeNull()

    setDealsEnabled(true)

    expect(dealsEnabled.value).toBe(true)
    expect(dealsRefreshHour.value).toBe(6)
  })

  it('never overwrites an auto-refresh hour the user already chose', () => {
    const { dealsRefreshHour, setDealsEnabled } = useDeals()
    dealsRefreshHour.value = 14 // user picked 14:00

    setDealsEnabled(true)

    expect(dealsRefreshHour.value).toBe(14)
  })

  it('leaves the hour untouched when disabling deals', () => {
    const { dealsRefreshHour, setDealsEnabled } = useDeals()
    dealsRefreshHour.value = 9

    setDealsEnabled(false)

    expect(dealsRefreshHour.value).toBe(9)
  })
})
