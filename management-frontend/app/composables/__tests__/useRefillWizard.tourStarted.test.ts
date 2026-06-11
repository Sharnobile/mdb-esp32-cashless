import { describe, it, expect } from 'vitest'
import { ref as vueRef, computed as vueComputed } from 'vue'

// useRefillWizard.ts uses Nuxt auto-imports (`ref`, `computed`, `useState`)
// as bare globals (its `useSupabaseClient` import resolves via the vitest
// `#imports` alias). Expose the globals before the module import evaluates.
// Mirrors useDeals.keywords.test.ts / useWarehouse.test.ts.
;(globalThis as any).ref = vueRef
;(globalThis as any).computed = vueComputed
;(globalThis as any).useState = <T,>(_k: string, init?: () => T) => vueRef(init ? init() : undefined)
;(globalThis as any).useSupabaseClient = () => ({ from: () => ({}) })
;(globalThis as any).useSupabaseUser = () => vueRef({ id: 'user-1' })
;(globalThis as any).useOrganization = () => ({ organization: vueRef({ id: 'company-1' }) })

import { buildTourStartedEntry } from '../useRefillWizard'

describe('buildTourStartedEntry', () => {
  const machines = [
    { id: 'm-1', name: 'Automat Bahnhof' },
    { id: 'm-2', name: 'Automat Schule' },
  ]

  it('builds the full activity_log payload', () => {
    const entry = buildTourStartedEntry({
      companyId: 'company-1',
      user: {
        id: 'user-1',
        email: 'max@example.com',
        user_metadata: { first_name: 'Max', last_name: 'Muster' },
      },
      tourId: 'tour-123',
      machines,
      warehouseId: 'wh-1',
      warehouseName: 'Hauptlager',
    })

    expect(entry).toEqual({
      company_id: 'company-1',
      user_id: 'user-1',
      entity_type: 'stock',
      entity_id: 'tour-123',
      action: 'tour_started',
      metadata: {
        tour_id: 'tour-123',
        machine_count: 2,
        machine_ids: ['m-1', 'm-2'],
        machine_names: ['Automat Bahnhof', 'Automat Schule'],
        warehouse_id: 'wh-1',
        warehouse_name: 'Hauptlager',
        _user_email: 'max@example.com',
        _user_display: 'Max Muster',
      },
    })
  })

  it('falls back to email when no name is set', () => {
    const entry = buildTourStartedEntry({
      companyId: 'company-1',
      user: { id: 'user-1', email: 'max@example.com', user_metadata: {} },
      tourId: 't',
      machines: [],
      warehouseId: null,
      warehouseName: null,
    })
    expect(entry.metadata._user_display).toBe('max@example.com')
    expect(entry.metadata.machine_count).toBe(0)
    expect(entry.metadata.warehouse_id).toBeNull()
    expect(entry.metadata.warehouse_name).toBeNull()
  })

  it('handles a null user and missing company', () => {
    const entry = buildTourStartedEntry({
      companyId: undefined,
      user: null,
      tourId: 't',
      machines,
      warehouseId: 'wh-1',
      warehouseName: null,
    })
    expect(entry.company_id).toBeNull()
    expect(entry.user_id).toBeNull()
    expect(entry.metadata._user_email).toBeNull()
    expect(entry.metadata._user_display).toBeNull()
  })
})
