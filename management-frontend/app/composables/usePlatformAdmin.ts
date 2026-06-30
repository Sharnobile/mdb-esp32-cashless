import { ref, useState, useSupabaseClient } from '#imports'

// ── Types (no generated DB types; cast manually) ──────────────────────────────
export interface PlatformTotals {
  company_count: number
  user_count: number
  machine_count: number
  device_count: number
  devices_online: number
}

export interface PlatformCompanyRow {
  company_id: string
  name: string
  user_count: number
  admin_count: number
  viewer_count: number
  machine_count: number
  device_count: number
  devices_online: number
  sales_today_count: number
  sales_today_revenue: number
  sales_7d_count: number
  sales_7d_revenue: number
  sales_window_count: number
  sales_window_revenue: number
  last_sale_at: string | null
  last_device_seen_at: string | null
}

export interface PlatformOverview {
  window_days: number
  totals: PlatformTotals
  companies: PlatformCompanyRow[]
}

export interface CompanyMember { user_id: string; email: string | null; role: string; joined_at: string }
export interface CompanyDevice {
  embedded_id: string; subdomain: number; mac_address: string | null
  status: string | null; status_at: string | null; online_since: string | null
  firmware_version: string | null; machine_name: string | null
}
export interface CompanySaleRow { created_at: string; item_price: number; item_number: number | null; channel: string | null; machine_name: string | null }
export interface CompanyDetail {
  company: { id: string; name: string; created_at: string } | null
  members: CompanyMember[]
  devices: CompanyDevice[]
  recent_sales: CompanySaleRow[]
}

export type ActivityLevel = 'active' | 'idle' | 'dead'

// ── Pure helpers (unit-tested) ────────────────────────────────────────────────
export function companyActivityLevel(lastSaleAt: string | null, now: Date = new Date()): ActivityLevel {
  if (!lastSaleAt) return 'dead'
  const ageMs = now.getTime() - new Date(lastSaleAt).getTime()
  const day = 86_400_000
  if (ageMs <= 7 * day) return 'active'
  if (ageMs <= 30 * day) return 'idle'
  return 'dead'
}

// Intentionally treats null/empty status as offline (defensive divergence from the
// backend predicate `status <> 'offline'`, which would treat empty/null as online).
export function isDeviceOnline(status: string | null | undefined): boolean {
  return status != null && status !== '' && status !== 'offline'
}

// ── Composable ────────────────────────────────────────────────────────────────
export function usePlatformAdmin() {
  const supabase = useSupabaseClient()

  const overview = useState<PlatformOverview | null>('platform-overview', () => null)
  const isPlatformAdmin = useState<boolean>('is-platform-admin', () => false)
  const loading = ref(false)
  const error = ref('')

  async function fetchOverview(days = 30) {
    loading.value = true
    error.value = ''
    try {
      const { data, error: rpcError } = await (supabase as any).rpc('get_platform_overview', { p_days: days })
      if (rpcError) throw rpcError
      overview.value = data as PlatformOverview
      isPlatformAdmin.value = true
    } catch (err: any) {
      // Only a "not authorized" raise (Postgres errcode 42501) means the caller is not a
      // platform admin. Transient failures (network/timeout) must NOT hide the admin UI.
      if (err?.code === '42501') isPlatformAdmin.value = false
      error.value = err?.message ?? 'failed to load platform overview'
      throw err
    } finally {
      loading.value = false
    }
  }

  async function checkIsPlatformAdmin(): Promise<boolean> {
    try {
      const { data, error: rpcError } = await (supabase as any).rpc('is_platform_admin')
      if (rpcError) throw rpcError
      isPlatformAdmin.value = data === true
    } catch {
      isPlatformAdmin.value = false
    }
    return isPlatformAdmin.value
  }

  async function fetchCompanyDetail(companyId: string): Promise<CompanyDetail> {
    const { data, error: rpcError } = await (supabase as any)
      .rpc('get_platform_company_detail', { p_company_id: companyId })
    if (rpcError) throw rpcError
    return data as CompanyDetail
  }

  return { overview, isPlatformAdmin, loading, error, fetchOverview, checkIsPlatformAdmin, fetchCompanyDetail }
}
