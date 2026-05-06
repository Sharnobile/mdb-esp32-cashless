import { describe, it, expect, vi, beforeEach } from 'vitest'

// Drive supabase calls per-test via a mock builder.
type Row = { provider_id: string; enabled: boolean; config: Record<string, unknown>; display_name: string | null }
let mockRows: Row[] = []
let mockUpsertCalls: Row[] = []
let mockDeleteCalls: { provider_id: string }[] = []

vi.mock('#imports', () => ({
  useSupabaseClient: () => ({
    from(_table: string) {
      return {
        select() {
          return {
            eq() { return this },
            // last .eq() is awaited — stub via thenable.
            then: (cb: (v: unknown) => unknown) => Promise.resolve({ data: mockRows, error: null }).then(cb),
          }
        },
        upsert(rows: Row[]) {
          mockUpsertCalls.push(...rows)
          return Promise.resolve({ error: null })
        },
        delete() {
          return {
            eq(col: string, val: unknown) {
              if (col === 'provider_id') mockDeleteCalls.push({ provider_id: String(val) })
              return this
            },
            then: (cb: (v: unknown) => unknown) => Promise.resolve({ error: null }).then(cb),
          }
        },
      }
    },
  }),
  useState: <T,>(_key: string, init: () => T) => ({ value: init() }),
}))

import { useProviderSettings } from '../useProviderSettings'

beforeEach(() => {
  mockRows = []
  mockUpsertCalls = []
  mockDeleteCalls = []
})

describe('useProviderSettings', () => {
  it('loads rows for a given extension point', async () => {
    mockRows = [
      { provider_id: 'marktguru', enabled: true, config: {}, display_name: null },
      { provider_id: 'webhook-abc', enabled: false, config: { url: 'https://x', authToken: 't' }, display_name: 'Test' },
    ]
    const { rows, load } = useProviderSettings('co-1')
    await load('deal-source')
    expect(rows.value.length).toBe(2)
    expect(rows.value[0].provider_id).toBe('marktguru')
  })

  it('addWebhook upserts a new row with webhook- prefix', async () => {
    const { addWebhook } = useProviderSettings('co-1')
    await addWebhook('deal-source', 'My Source', 'https://hook/', 'tok', {})
    expect(mockUpsertCalls.length).toBe(1)
    expect(mockUpsertCalls[0].provider_id.startsWith('webhook-')).toBe(true)
    expect(mockUpsertCalls[0].config).toMatchObject({ url: 'https://hook/', authToken: 'tok' })
    expect(mockUpsertCalls[0].display_name).toBe('My Source')
    expect(mockUpsertCalls[0].enabled).toBe(true)
  })

  it('setEnabled upserts an existing row with new enabled flag', async () => {
    const { setEnabled } = useProviderSettings('co-1')
    await setEnabled('deal-source', 'marktguru', false)
    expect(mockUpsertCalls.length).toBe(1)
    expect(mockUpsertCalls[0].provider_id).toBe('marktguru')
    expect(mockUpsertCalls[0].enabled).toBe(false)
  })

  it('removeWebhook deletes by provider_id', async () => {
    const { removeWebhook } = useProviderSettings('co-1')
    await removeWebhook('deal-source', 'webhook-abc')
    expect(mockDeleteCalls).toEqual([{ provider_id: 'webhook-abc' }])
  })

  it('addWebhook rejects http:// URLs', async () => {
    const { addWebhook } = useProviderSettings('co-1')
    await expect(
      addWebhook('deal-source', 'My Source', 'http://insecure/', 'tok', {}),
    ).rejects.toThrow(/https/)
    expect(mockUpsertCalls.length).toBe(0)
  })
})
