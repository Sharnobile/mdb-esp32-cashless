/**
 * Nominatim geocoding wrapper.
 *
 * Policy-compliant by design:
 * - No autocomplete (prohibited by Nominatim usage policy)
 * - All calls triggered by discrete user actions (Enter / click)
 * - Identifying User-Agent per policy
 * - Single in-flight request via caller-supplied AbortController
 *
 * Swap base URL to a self-hosted instance by changing NOMINATIM_BASE.
 */

import { useI18n } from '#imports'

export const NOMINATIM_BASE = 'https://nominatim.openstreetmap.org'

const USER_AGENT = 'MDBCashless-Management/1.0 (+https://github.com/LucienKerl/mdb-esp32-cashless)'

export interface GeocodingAddress {
  road?: string
  house_number?: string
  postcode?: string
  city?: string
  town?: string
  village?: string
  municipality?: string
  country_code?: string // lowercase ISO 3166-1 alpha-2
}

export interface GeocodingResult {
  lat: number
  lon: number
  display_name: string
  address: GeocodingAddress
}

/**
 * Pick the best city-like field from a Nominatim address object.
 * Preference: city > town > village > municipality. Treats empty strings as missing.
 */
export function pickCity(address: GeocodingAddress): string | null {
  if (address.city && address.city.length > 0) return address.city
  if (address.town && address.town.length > 0) return address.town
  if (address.village && address.village.length > 0) return address.village
  if (address.municipality && address.municipality.length > 0) return address.municipality
  return null
}

export function useGeocoding() {
  const { locale } = useI18n()

  function buildHeaders(): Record<string, string> {
    // Note: browsers treat 'User-Agent' as a "forbidden header name" and silently
    // drop it from fetch() requests — the browser's real UA is sent instead.
    // We set it anyway for (a) documentation intent, (b) correctness in non-browser
    // environments (Nuxt SSR, tests, a future Node-side caller), and (c) so the
    // unit test can verify the policy-required UA is present in the code path.
    // Nominatim's policy accepts browser-sent UAs for browser apps, so this is OK.
    return {
      'User-Agent': USER_AGENT,
      'Accept-Language': locale.value || 'en',
    }
  }

  /**
   * Forward geocoding. Called once per user action (Enter / Search button).
   * Returns [] for empty or too-short queries (no request sent).
   * Returns [] on non-2xx responses rather than throwing.
   */
  async function search(query: string, signal?: AbortSignal): Promise<GeocodingResult[]> {
    const q = query.trim()
    if (q.length < 2) return []
    // Truncate extremely long queries client-side (policy: keep requests small)
    const clipped = q.length > 200 ? q.slice(0, 200) : q
    const params = new URLSearchParams({
      q: clipped,
      format: 'json',
      addressdetails: '1',
      limit: '5',
    })
    const url = `${NOMINATIM_BASE}/search?${params.toString()}`
    try {
      const res = await fetch(url, { headers: buildHeaders(), signal })
      if (!res.ok) return []
      const data = (await res.json()) as Array<{
        lat: string
        lon: string
        display_name: string
        address?: GeocodingAddress
      }>
      return data.map(d => ({
        lat: Number(d.lat),
        lon: Number(d.lon),
        display_name: d.display_name,
        address: d.address ?? {},
      }))
    } catch (err) {
      // AbortError and network failures both surface as thrown errors;
      // callers only care about the result list, so swallow and return [].
      if ((err as Error).name === 'AbortError') return []
      console.warn('[useGeocoding.search] failed:', err)
      return []
    }
  }

  /**
   * Reverse geocoding. Called once per user action (pin dragend, map click).
   * Returns null on error or non-2xx.
   */
  async function reverse(lat: number, lon: number, signal?: AbortSignal): Promise<GeocodingResult | null> {
    const params = new URLSearchParams({
      lat: String(lat),
      lon: String(lon),
      format: 'json',
      addressdetails: '1',
    })
    const url = `${NOMINATIM_BASE}/reverse?${params.toString()}`
    try {
      const res = await fetch(url, { headers: buildHeaders(), signal })
      if (!res.ok) return null
      const d = (await res.json()) as {
        lat: string
        lon: string
        display_name: string
        address?: GeocodingAddress
      }
      return {
        lat: Number(d.lat),
        lon: Number(d.lon),
        display_name: d.display_name,
        address: d.address ?? {},
      }
    } catch (err) {
      if ((err as Error).name === 'AbortError') return null
      console.warn('[useGeocoding.reverse] failed:', err)
      return null
    }
  }

  return { search, reverse }
}
