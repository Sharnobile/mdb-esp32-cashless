<script setup lang="ts">
definePageMeta({ layout: false })

const { t } = useI18n()
const route = useRoute()
const companyId = route.params.company_id as string

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const isValidUuid = UUID_RE.test(companyId)

interface Machine {
  id: string
  name: string | null
  location_lat: number | null
  location_lon: number | null
  company_name: string | null
  status: string | null
}

interface ApiResponse {
  machines: Machine[]
  company: { name: string | null } | null
}

const { data, error, pending } = isValidUuid
  ? await useFetch<ApiResponse>('/functions/v1/public-machines-list', {
      params: { company_id: companyId },
    })
  : { data: ref(null), error: ref(new Error('Invalid company ID')), pending: ref(false) }

const mapContainer = ref<HTMLElement | null>(null)
let mapInstance: any = null

async function loadLeaflet(): Promise<any> {
  if ((window as any).L) return (window as any).L
  if (!document.querySelector('link[href*="leaflet.css"]')) {
    const link = document.createElement('link')
    link.rel = 'stylesheet'
    link.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css'
    link.integrity = 'sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY='
    link.crossOrigin = ''
    document.head.appendChild(link)
  }
  return new Promise((resolve, reject) => {
    const existing = document.querySelector('script[src*="leaflet.js"]')
    if (existing) {
      existing.addEventListener('load', () => resolve((window as any).L))
      return
    }
    const script = document.createElement('script')
    script.src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
    script.integrity = 'sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo='
    script.crossOrigin = ''
    script.onload = () => resolve((window as any).L)
    script.onerror = reject
    document.head.appendChild(script)
  })
}

function escapeHtml(str: string): string {
  return str.replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c] || c))
}

async function initMap() {
  if (!mapContainer.value || !data.value?.machines || mapInstance) return

  const withCoords = data.value.machines.filter(
    (m) => m.location_lat !== null && m.location_lon !== null,
  )
  if (withCoords.length === 0) return

  const L = await loadLeaflet()

  mapInstance = L.map(mapContainer.value).setView([51.1657, 10.4515], 6)

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>',
    maxZoom: 18,
  }).addTo(mapInstance)

  const bounds: [number, number][] = []
  for (const machine of withCoords) {
    const isOnline = machine.status === 'online'
    const icon = L.divIcon({
      className: 'custom-marker',
      html: `<div style="width:24px;height:24px;border-radius:50%;border:2px solid white;box-shadow:0 2px 8px rgba(0,0,0,0.4);background-color:${isOnline ? '#10b981' : '#6b7280'};"></div>`,
      iconSize: [24, 24],
      iconAnchor: [12, 12],
    })

    const marker = L.marker([machine.location_lat!, machine.location_lon!], { icon }).addTo(mapInstance)

    const statusLabel = isOnline ? t('publicStorefront.online') : t('publicStorefront.offline')
    const statusColor = isOnline ? 'background:rgba(16,185,129,0.15);color:#059669' : 'background:rgba(107,114,128,0.15);color:#6b7280'

    const popupHtml = `
      <div style="min-width:160px;font-family:inherit">
        <div style="font-weight:600;margin-bottom:4px;font-size:14px">${escapeHtml(machine.name || '—')}</div>
        <div style="margin-bottom:8px"><span style="display:inline-block;border-radius:9999px;padding:2px 8px;font-size:10px;font-weight:600;text-transform:uppercase;${statusColor}">${statusLabel}</span></div>
        <a href="/m/${machine.id}" style="font-size:13px;font-weight:500;color:#3b82f6;text-decoration:none">${t('publicMap.viewDetails')} →</a>
      </div>
    `
    marker.bindPopup(popupHtml)
    bounds.push([machine.location_lat!, machine.location_lon!])
  }

  if (bounds.length > 1) {
    mapInstance.fitBounds(bounds, { padding: [40, 40] })
  } else if (bounds.length === 1) {
    mapInstance.setView(bounds[0], 15)
  }
}

onMounted(() => {
  initMap()
})

watch(data, () => {
  if (data.value && !mapInstance) initMap()
})

onUnmounted(() => {
  if (mapInstance) {
    mapInstance.remove()
    mapInstance = null
  }
})

const companyName = computed(() => data.value?.company?.name || t('publicMap.operatorNotFound'))
const hasMachines = computed(() => (data.value?.machines?.length || 0) > 0)
const hasError = computed(() => !isValidUuid || !!error.value || !data.value)
</script>

<template>
  <div class="min-h-dvh bg-background text-foreground">
    <Head>
      <title>{{ data?.company?.name || t('publicMap.operatorNotFound') }}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    </Head>

    <!-- Loading -->
    <div v-if="pending" class="flex min-h-dvh items-center justify-center">
      <div class="mx-auto size-8 animate-spin rounded-full border-2 border-muted-foreground border-t-primary" />
    </div>

    <!-- Not found -->
    <div v-else-if="hasError" class="flex min-h-dvh items-center justify-center p-6">
      <div class="text-center">
        <div class="mx-auto mb-4 flex size-16 items-center justify-center rounded-full bg-muted">
          <svg class="size-8 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M15.182 16.318A4.486 4.486 0 0012.016 15a4.486 4.486 0 00-3.198 1.318M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
        </div>
        <h2 class="mb-2 text-lg font-semibold">{{ t('publicMap.operatorNotFound') }}</h2>
        <NuxtLink
          to="/m"
          class="inline-flex items-center gap-1.5 text-sm font-medium text-primary hover:underline"
        >
          ← {{ t('publicMap.backToAll') }}
        </NuxtLink>
      </div>
    </div>

    <!-- Main content -->
    <template v-else>
      <!-- Header -->
      <header class="mx-auto max-w-5xl px-4 py-6">
        <NuxtLink
          to="/m"
          class="mb-3 inline-flex items-center gap-1.5 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground"
        >
          <svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M10.5 19.5L3 12m0 0l7.5-7.5M3 12h18" />
          </svg>
          {{ t('publicMap.backToAll') }}
        </NuxtLink>
        <h1 class="text-2xl font-bold tracking-tight">{{ companyName }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('publicMap.machinesBy', { name: companyName }) }}</p>
      </header>

      <!-- Empty state -->
      <div
        v-if="!hasMachines"
        class="mx-auto max-w-md px-4 py-12 text-center"
      >
        <div class="mx-auto mb-4 flex size-16 items-center justify-center rounded-full bg-muted">
          <svg class="size-8 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 11-6 0 3 3 0 016 0z" />
            <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z" />
          </svg>
        </div>
        <p class="text-muted-foreground">{{ t('publicMap.operatorEmpty') }}</p>
      </div>

      <!-- Map + List -->
      <template v-else>
        <!-- Map container -->
        <div class="mx-auto max-w-5xl px-4">
          <div
            ref="mapContainer"
            class="h-[60vh] w-full overflow-hidden rounded-xl border border-border bg-muted"
            style="min-height: 400px;"
          />
        </div>

        <!-- List -->
        <section class="mx-auto max-w-5xl px-4 py-8">
          <h2 class="mb-4 text-lg font-semibold">
            {{ t('publicMap.allMachines') }}
            <span class="text-sm font-normal text-muted-foreground">({{ data.machines.length }})</span>
          </h2>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <NuxtLink
              v-for="m in data.machines"
              :key="m.id"
              :to="`/m/${m.id}`"
              class="block rounded-xl border border-border bg-card p-4 transition hover:bg-accent"
            >
              <div class="mb-2 flex items-start justify-between gap-2">
                <h3 class="text-sm font-semibold leading-tight">{{ m.name || '—' }}</h3>
                <span
                  class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
                  :class="m.status === 'online'
                    ? 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400'
                    : 'bg-gray-500/15 text-gray-600 dark:text-gray-400'"
                >
                  {{ m.status === 'online' ? t('publicStorefront.online') : t('publicStorefront.offline') }}
                </span>
              </div>
              <p
                v-if="m.location_lat === null || m.location_lon === null"
                class="mt-1 text-[11px] text-amber-600 dark:text-amber-400"
              >
                {{ t('publicMap.noLocation') }}
              </p>
            </NuxtLink>
          </div>
        </section>
      </template>

      <!-- Footer -->
      <footer class="mx-auto max-w-5xl px-4 py-6 text-center text-xs text-muted-foreground">
        {{ t('publicStorefront.poweredBy') }} VMflow
      </footer>
    </template>
  </div>
</template>
