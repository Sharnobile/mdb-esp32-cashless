import { describe, it, expect, vi, beforeEach } from 'vitest'

// Build a mock Supabase client with chainable from().update().eq() and
// a resolved error of null. We also capture the .update() payload.
const capturedUpdates: Array<Record<string, any>> = []
const mockFrom = {
  update: vi.fn((payload: Record<string, any>) => {
    capturedUpdates.push(payload)
    return mockFrom
  }),
  eq: vi.fn().mockResolvedValue({ error: null }),
  insert: vi.fn().mockResolvedValue({ error: null }),
  select: vi.fn().mockResolvedValue({ data: [], error: null }),
}
const mockSupabase = {
  from: vi.fn(() => mockFrom),
  channel: vi.fn().mockReturnValue({ on: vi.fn().mockReturnThis(), subscribe: vi.fn().mockReturnThis() }),
  removeChannel: vi.fn(),
}

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useState: <T>(_k: string, init?: () => T) => ref(init ? init() : undefined),
    useSupabaseClient: () => mockSupabase,
  }
})

import { useMachines } from '../useMachines'

describe('useMachines.updateMachineSettings', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    capturedUpdates.length = 0
    mockFrom.eq.mockResolvedValue({ error: null })
  })

  it('sends an UPDATE on vendingMachine with the full patch', async () => {
    const { updateMachineSettings } = useMachines()
    await updateMachineSettings('machine-123', {
      location_lat: 52.53,
      location_lon: 13.38,
      address_street: 'Musterstraße',
      address_house_number: '1',
      address_postal_code: '10115',
      address_city: 'Berlin',
      formatted_address: 'Musterstraße 1, 10115 Berlin, Deutschland',
      country_code: 'DE',
      nayax_machine_id: '92700604',
    })
    expect(mockSupabase.from).toHaveBeenCalledWith('vendingMachine')
    expect(capturedUpdates).toHaveLength(1)
    expect(capturedUpdates[0]).toMatchObject({
      location_lat: 52.53,
      location_lon: 13.38,
      address_city: 'Berlin',
      country_code: 'DE',
    })
    expect(mockFrom.eq).toHaveBeenCalledWith('id', 'machine-123')
  })

  it('sends nulls on clear', async () => {
    const { updateMachineSettings } = useMachines()
    await updateMachineSettings('machine-123', {
      location_lat: null,
      location_lon: null,
      address_street: null,
      address_house_number: null,
      address_postal_code: null,
      address_city: null,
      formatted_address: null,
      country_code: null,
      nayax_machine_id: null,
    })
    expect(capturedUpdates[0]).toMatchObject({
      location_lat: null,
      location_lon: null,
      address_city: null,
      country_code: null,
    })
  })

  it('throws when Supabase returns an error', async () => {
    mockFrom.eq.mockResolvedValueOnce({ error: { message: 'boom' } })
    const { updateMachineSettings } = useMachines()
    await expect(
      updateMachineSettings('machine-123', {
        location_lat: 0,
        location_lon: 0,
        address_street: null,
        address_house_number: null,
        address_postal_code: null,
        address_city: null,
        formatted_address: null,
        country_code: null,
        nayax_machine_id: null,
      }),
    ).rejects.toMatchObject({ message: 'boom' })
  })
})
