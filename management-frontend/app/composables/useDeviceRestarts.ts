import { ref, useSupabaseClient } from '#imports'

export interface DeviceRestart {
  id: string
  created_at: string
  embedded_id: string
  reason: string
  uptime_sec: number | null
  firmware_version: string | null
  hw_reason: string | null
  raw: Record<string, unknown> | null
}

const PAGE_SIZE = 50

export function useDeviceRestarts() {
  const supabase = useSupabaseClient()

  const restarts = ref<DeviceRestart[]>([])
  const loading = ref(false)
  const hasMore = ref(true)

  async function fetchRestarts(embeddedId: string) {
    loading.value = true
    hasMore.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('device_restarts')
        .select('*')
        .eq('embedded_id', embeddedId)
        .order('created_at', { ascending: false })
        .limit(PAGE_SIZE)

      if (error) throw error
      restarts.value = (data ?? []) as DeviceRestart[]
      hasMore.value = restarts.value.length === PAGE_SIZE
    } finally {
      loading.value = false
    }
  }

  async function fetchMore(embeddedId: string) {
    if (!hasMore.value || loading.value) return
    const oldest = restarts.value[restarts.value.length - 1]?.created_at
    if (!oldest) return
    loading.value = true
    try {

      const { data, error } = await (supabase as any)
        .from('device_restarts')
        .select('*')
        .eq('embedded_id', embeddedId)
        .lt('created_at', oldest)
        .order('created_at', { ascending: false })
        .limit(PAGE_SIZE)

      if (error) throw error
      const next = (data ?? []) as DeviceRestart[]
      restarts.value.push(...next)
      hasMore.value = next.length === PAGE_SIZE
    } finally {
      loading.value = false
    }
  }

  function subscribe(embeddedId: string) {
    const channel = (supabase as any)
      .channel(`device-restarts-${embeddedId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'device_restarts',
          filter: `embedded_id=eq.${embeddedId}`,
        },
        (payload: { new: DeviceRestart }) => {
          restarts.value.unshift(payload.new)
        },
      )
      .subscribe()

    return () => (supabase as any).removeChannel(channel)
  }

  return {
    restarts,
    loading,
    hasMore,
    fetchRestarts,
    fetchMore,
    subscribe,
    reasonLabel,
    reasonVariant,
  }
}

// ── Exported helpers (pure functions) ──────────────────────────────────────────

export function reasonLabel(reason: string): string {
  const labels: Record<string, string> = {
    mqtt_watchdog: 'MQTT Watchdog',
    ota: 'OTA Update',
    config: 'Config Change',
    provision: 'Provisioning',
    factory_reset: 'Factory Reset',
    power_on: 'Power On',
    panic: 'Panic',
    brownout: 'Brownout',
    watchdog: 'HW Watchdog',
    unknown: 'Unknown',
  }
  return labels[reason] ?? reason
}

export function reasonVariant(reason: string): 'default' | 'secondary' | 'destructive' | 'outline' {
  const map: Record<string, 'default' | 'secondary' | 'destructive' | 'outline'> = {
    mqtt_watchdog: 'destructive',
    panic: 'destructive',
    brownout: 'destructive',
    watchdog: 'destructive',
    ota: 'secondary',
    config: 'secondary',
    provision: 'outline',
    factory_reset: 'outline',
    power_on: 'default',
  }
  return map[reason] ?? 'outline'
}

export function formatUptime(seconds: number | null): string {
  if (seconds == null) return '—'
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  const hours = Math.floor(seconds / 3600)
  const mins = Math.floor((seconds % 3600) / 60)
  if (hours < 24) return `${hours}h ${mins}m`
  const days = Math.floor(hours / 24)
  return `${days}d ${hours % 24}h`
}
