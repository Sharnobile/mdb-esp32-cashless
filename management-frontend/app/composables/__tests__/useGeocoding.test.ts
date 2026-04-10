import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// Mock #imports before any import that might transitively touch it.
// vi.mock is hoisted, so the order here doesn't matter functionally, but keeping
// it at the top of the file is the convention the existing useMdbLog.test.ts follows.
vi.mock('#imports', () => ({
  useI18n: () => ({ locale: { value: 'de' } }),
}))

import { pickCity, NOMINATIM_BASE, useGeocoding } from '../useGeocoding'

// ── pickCity: pure helper ────────────────────────────────────────────────

describe('pickCity', () => {
  it('returns city when present', () => {
    expect(pickCity({ city: 'Berlin', town: 'Ignored' })).toBe('Berlin')
  })

  it('falls back to town when city missing', () => {
    expect(pickCity({ town: 'Musterstadt' })).toBe('Musterstadt')
  })

  it('falls back to village when city and town missing', () => {
    expect(pickCity({ village: 'Musterdorf' })).toBe('Musterdorf')
  })

  it('falls back to municipality when city, town, village all missing', () => {
    expect(pickCity({ municipality: 'Musterdistrikt' })).toBe('Musterdistrikt')
  })

  it('returns null when none of the fields are present', () => {
    expect(pickCity({})).toBeNull()
  })

  it('prefers order city > town > village > municipality', () => {
    expect(pickCity({
      city: 'A',
      town: 'B',
      village: 'C',
      municipality: 'D',
    })).toBe('A')
  })

  it('treats empty strings as missing', () => {
    expect(pickCity({ city: '', town: 'B' })).toBe('B')
  })
})

// ── search + reverse: mocked fetch ───────────────────────────────────────

const originalFetch = globalThis.fetch

describe('useGeocoding.search', () => {
  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('hits /search with q, format, addressdetails, limit params', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Berlin')
    const call = (globalThis.fetch as any).mock.calls[0]
    const url = call[0] as string
    expect(url.startsWith(`${NOMINATIM_BASE}/search?`)).toBe(true)
    expect(url).toContain('q=Berlin')
    expect(url).toContain('format=json')
    expect(url).toContain('addressdetails=1')
    expect(url).toContain('limit=5')
  })

  it('sends User-Agent and Accept-Language headers', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Berlin')
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    const headers = init.headers as Record<string, string>
    expect(headers['User-Agent']).toContain('MDBCashless-Management')
    expect(headers['Accept-Language']).toBe('de')
  })

  it('URL-encodes the query', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const { search } = useGeocoding()
    await search('Musterstraße 1, Berlin')
    const url = (globalThis.fetch as any).mock.calls[0][0] as string
    expect(url).toContain('Musterstra%C3%9Fe')
    expect(url).toContain('%2C') // comma
  })

  it('parses results into GeocodingResult[]', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [
        {
          lat: '52.53',
          lon: '13.38',
          display_name: 'Musterstraße 1, 10115 Berlin, Deutschland',
          address: {
            road: 'Musterstraße',
            house_number: '1',
            postcode: '10115',
            city: 'Berlin',
            country_code: 'de',
          },
        },
      ],
    })
    const { search } = useGeocoding()
    const results = await search('Berlin')
    expect(results).toHaveLength(1)
    expect(results[0].lat).toBe(52.53)
    expect(results[0].lon).toBe(13.38)
    expect(results[0].address.city).toBe('Berlin')
    expect(results[0].address.country_code).toBe('de')
  })

  it('returns [] when the response is not ok', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: false,
      status: 503,
      json: async () => [],
    })
    const { search } = useGeocoding()
    const results = await search('Berlin')
    expect(results).toEqual([])
  })

  it('passes through an AbortSignal', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const controller = new AbortController()
    const { search } = useGeocoding()
    await search('Berlin', controller.signal)
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    expect(init.signal).toBe(controller.signal)
  })

  it('returns [] for empty or too-short queries without fetching', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({ ok: true, json: async () => [] })
    const { search } = useGeocoding()
    expect(await search('')).toEqual([])
    expect(await search('a')).toEqual([])
    expect((globalThis.fetch as any).mock.calls).toHaveLength(0)
  })
})

describe('useGeocoding.reverse', () => {
  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })
  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('hits /reverse with lat, lon, format, addressdetails', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({
        lat: '52.53',
        lon: '13.38',
        display_name: 'Musterstraße 1, Berlin',
        address: { road: 'Musterstraße', city: 'Berlin', country_code: 'de' },
      }),
    })
    const { reverse } = useGeocoding()
    await reverse(52.53, 13.38)
    const url = (globalThis.fetch as any).mock.calls[0][0] as string
    expect(url.startsWith(`${NOMINATIM_BASE}/reverse?`)).toBe(true)
    expect(url).toContain('lat=52.53')
    expect(url).toContain('lon=13.38')
    expect(url).toContain('format=json')
    expect(url).toContain('addressdetails=1')
  })

  it('parses the response into a GeocodingResult', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({
        lat: '48.85',
        lon: '2.35',
        display_name: '1 Rue de Rivoli, 75004 Paris, France',
        address: { road: 'Rue de Rivoli', house_number: '1', postcode: '75004', city: 'Paris', country_code: 'fr' },
      }),
    })
    const { reverse } = useGeocoding()
    const result = await reverse(48.85, 2.35)
    expect(result).not.toBeNull()
    expect(result!.lat).toBe(48.85)
    expect(result!.address.city).toBe('Paris')
    expect(result!.address.country_code).toBe('fr')
  })

  it('returns null when the response is not ok', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: false,
      status: 503,
      json: async () => ({}),
    })
    const { reverse } = useGeocoding()
    expect(await reverse(0, 0)).toBeNull()
  })

  it('passes through an AbortSignal', async () => {
    ;(globalThis.fetch as any).mockResolvedValue({
      ok: true,
      json: async () => ({ lat: '0', lon: '0', display_name: '', address: {} }),
    })
    const controller = new AbortController()
    const { reverse } = useGeocoding()
    await reverse(0, 0, controller.signal)
    const init = (globalThis.fetch as any).mock.calls[0][1] as RequestInit
    expect(init.signal).toBe(controller.signal)
  })
})
