import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

// The composable uses bare ref(...) via Nuxt auto-import.
;(globalThis as any).ref = vueRef

const rpc = vi.fn()

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useSupabaseClient: () => ({ rpc }),
  }
})

import { useSuppressedSales } from '../useSuppressedSales'

beforeEach(() => {
  vi.clearAllMocks()
})

describe('useSuppressedSales.restore', () => {
  it('calls the RPC with { p_suppressed_id } and removes the row on success', async () => {
    rpc.mockResolvedValueOnce({ data: { id: 's1' }, error: null })
    const s = useSuppressedSales()
    // seed two rows
    s.rows.value = [
      { id: 's1' } as any,
      { id: 's2' } as any,
    ]
    await s.restore('s1')
    expect(rpc).toHaveBeenCalledWith('restore_suppressed_sale', { p_suppressed_id: 's1' })
    expect(s.rows.value.map(r => r.id)).toEqual(['s2'])
  })

  it('throws and leaves rows untouched on RPC error', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'nope' } })
    const s = useSuppressedSales()
    s.rows.value = [{ id: 's1' } as any]
    await expect(s.restore('s1')).rejects.toBeTruthy()
    expect(s.rows.value.map(r => r.id)).toEqual(['s1'])
  })
})
