import { ref, useSupabaseClient } from '#imports'

export interface DeviceSensor {
  id: string
  embedded_id: string
  bus: number
  rom: string
  family: number
  name: string | null
  last_celsius: number | null
  last_seen: string | null
  created_at: string
}

export function useDeviceSensors() {
  const supabase = useSupabaseClient()

  const sensors = ref<DeviceSensor[]>([])
  const loading = ref(false)

  async function fetchSensors(embeddedId: string) {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('device_sensors')
        .select('*')
        .eq('embedded_id', embeddedId)
        .order('bus', { ascending: true })
        .order('rom', { ascending: true })

      if (error) throw error
      sensors.value = (data ?? []) as DeviceSensor[]
    } finally {
      loading.value = false
    }
  }

  // Only the label is user-writable (RLS: company-scoped UPDATE). Device
  // telemetry never touches `name`.
  async function updateSensorName(id: string, name: string) {
    const trimmed = name.trim()
    const value = trimmed.length > 0 ? trimmed : null
    const row = sensors.value.find(s => s.id === id)
    const previous = row?.name ?? null
    if (row) row.name = value // optimistic
    const { error } = await (supabase as any)
      .from('device_sensors')
      .update({ name: value })
      .eq('id', id)
    if (error) {
      if (row) row.name = previous // rollback
      throw error
    }
  }

  function subscribe(embeddedId: string) {
    const channel = (supabase as any)
      .channel(`device-sensors-${embeddedId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'device_sensors',
          filter: `embedded_id=eq.${embeddedId}`,
        },
        (payload: { eventType: string; new: DeviceSensor; old: { id: string } }) => {
          if (payload.eventType === 'DELETE') {
            sensors.value = sensors.value.filter(s => s.id !== payload.old.id)
            return
          }
          const idx = sensors.value.findIndex(s => s.id === payload.new.id)
          if (idx === -1) {
            sensors.value.push(payload.new)
            sensors.value.sort((a, b) => a.bus - b.bus || a.rom.localeCompare(b.rom))
          } else {
            const cur = sensors.value[idx]!
            cur.bus = payload.new.bus
            cur.family = payload.new.family
            cur.last_celsius = payload.new.last_celsius
            cur.last_seen = payload.new.last_seen
            cur.name = payload.new.name
          }
        },
      )
      .subscribe()

    return () => (supabase as any).removeChannel(channel)
  }

  return { sensors, loading, fetchSensors, updateSensorName, subscribe }
}

// ── Pure helpers ──────────────────────────────────────────────────────────────

// 1-Wire family codes (low byte of the ROM). 0x28 = 40 = DS18B20.
export function sensorFamilyLabel(family: number): string {
  const known: Record<number, string> = {
    0x10: 'DS18S20',
    0x22: 'DS1822',
    0x28: 'DS18B20',
    0x3b: 'MAX31850',
  }
  return known[family] ?? `0x${family.toString(16).toUpperCase().padStart(2, '0')}`
}

// ROM as a colon-separated MAC-style string for display.
export function formatRom(rom: string): string {
  return (rom.match(/.{1,2}/g) ?? [rom]).join(':')
}
