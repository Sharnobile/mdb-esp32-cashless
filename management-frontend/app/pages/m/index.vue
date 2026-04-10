<script setup lang="ts">
import type { Map as LMap } from 'leaflet'

definePageMeta({ layout: false })

const { t } = useI18n()

interface Machine {
  id: string
  name: string | null
  location_lat: number | null
  location_lon: number | null
  company_name: string | null
  status: string | null
}

const { data, pending } = await useFetch<{ machines: Machine[] }>(
  '/functions/v1/public-machines-list',
)

const mapContainer = ref<HTMLElement | null>(null)
let mapInstance: LMap | null = null
let L: typeof import('leaflet') | null = null
// Guards async initMap against component unmount while dynamic imports run.
let destroyed = false

function escapeHtml(str: string): string {
  return str.replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c] || c))
}

async function initMap() {
  if (mapInstance) return
  if (!mapContainer.value || !data.value?.machines) return

  const withCoords = data.value.machines.filter(
    (m) => m.location_lat !== null && m.location_lon !== null,
  )
  if (withCoords.length === 0) return

  // Vite-bundled Leaflet + CSS. More reliable than CDN (no HTTP-cache race,
  // no dangling <script> onload listeners on bfcache restore).
  const leaflet = await import('leaflet')
  if (destroyed) return
  await import('leaflet/dist/leaflet.css')
  if (destroyed || !mapContainer.value) return
  L = leaflet.default ?? (leaflet as unknown as typeof import('leaflet'))

  mapInstance = L.map(mapContainer.value).setView([51.1657, 10.4515], 6) // Germany center fallback

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
    const companyHtml = machine.company_name
      ? `<div style="font-size:11px;color:#6b7280;margin-bottom:6px">${escapeHtml(machine.company_name)}</div>`
      : ''

    const popupHtml = `
      <div style="min-width:160px;font-family:inherit">
        <div style="font-weight:600;margin-bottom:4px;font-size:14px">${escapeHtml(machine.name || '—')}</div>
        ${companyHtml}
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

  // Optional: show the visitor's current position. Silently bails on denial.
  addUserLocationMarker()
}

function addUserLocationMarker() {
  if (!mapInstance || !L) return
  if (typeof navigator === 'undefined' || !navigator.geolocation) return

  navigator.geolocation.getCurrentPosition(
    (pos) => {
      if (destroyed || !mapInstance || !L) return
      const { latitude, longitude, accuracy } = pos.coords

      const userIcon = L.divIcon({
        className: 'user-location-marker',
        html: `<div style="width:20px;height:20px;border-radius:50%;background:#3b82f6;border:3px solid white;box-shadow:0 0 0 2px rgba(59,130,246,0.35),0 2px 8px rgba(59,130,246,0.6)"></div>`,
        iconSize: [20, 20],
        iconAnchor: [10, 10],
      })

      L.marker([latitude, longitude], {
        icon: userIcon,
        keyboard: false,
        zIndexOffset: 1000,
      })
        .bindPopup(`<div style="font-weight:600;font-size:13px">${escapeHtml(t('publicMap.yourLocation'))}</div>`)
        .addTo(mapInstance)

      // Soft accuracy halo — skip for obviously-unreliable fixes (>2km).
      if (accuracy && accuracy > 0 && accuracy < 2000) {
        L.circle([latitude, longitude], {
          radius: accuracy,
          color: '#3b82f6',
          fillColor: '#3b82f6',
          fillOpacity: 0.1,
          weight: 1,
          interactive: false,
        }).addTo(mapInstance)
      }
    },
    () => {
      // Silently ignore — user denied or timed out
    },
    { enableHighAccuracy: false, timeout: 8000, maximumAge: 60000 },
  )
}

// Watch BOTH mapContainer and data with flush: 'post'.
//
// The map container lives inside <template v-else> and is only rendered once
// pending=false AND data has machines. Under Nuxt hydration paths where the
// client's useFetch starts with pending=true (no inlined SSR payload, bfcache
// restore, etc.), onMounted would fire while the spinner div was showing, so
// mapContainer.value was null and initMap bailed. The previous watch(data)
// ran with the default flush: 'pre' — BEFORE Vue updates the DOM — so the
// container ref was still null by the time the callback ran. Result: map
// never initialized until a hard reload made SSR data available on first
// render. flush: 'post' runs the callback AFTER the DOM mount, at which point
// the template ref is finally populated.
watch(
  [mapContainer, data],
  () => {
    void initMap()
  },
  { flush: 'post', immediate: true },
)

onUnmounted(() => {
  destroyed = true
  if (mapInstance) {
    mapInstance.remove()
    mapInstance = null
  }
})
</script>

<template>
  <div class="min-h-dvh bg-background text-foreground">
    <Head>
      <title>{{ t('publicMap.title') }}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    </Head>

    <!-- Header -->
    <header class="mx-auto max-w-5xl px-4 py-6">
      <h1 class="text-2xl font-bold tracking-tight">{{ t('publicMap.title') }}</h1>
      <p class="mt-1 text-sm text-muted-foreground">{{ t('publicMap.subtitle') }}</p>
    </header>

    <!-- Loading -->
    <div v-if="pending" class="flex min-h-[40vh] items-center justify-center">
      <div class="mx-auto size-8 animate-spin rounded-full border-2 border-muted-foreground border-t-primary" />
    </div>

    <!-- Empty state -->
    <div
      v-else-if="!data?.machines || data.machines.length === 0"
      class="mx-auto max-w-md px-4 py-16 text-center"
    >
      <div class="mx-auto mb-4 flex size-16 items-center justify-center rounded-full bg-muted">
        <svg class="size-8 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 11-6 0 3 3 0 016 0z" />
          <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z" />
        </svg>
      </div>
      <p class="text-muted-foreground">{{ t('publicMap.empty') }}</p>
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
            <p v-if="m.company_name" class="text-xs text-muted-foreground">{{ m.company_name }}</p>
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
  </div>
</template>

<style scoped>
:global(.leaflet-popup-content-wrapper) {
  border-radius: 8px;
}
</style>
