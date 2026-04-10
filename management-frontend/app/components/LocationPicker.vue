<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { useI18n } from '#imports'
import { useGeocoding, pickCity, type GeocodingResult } from '~/composables/useGeocoding'
// Type-only imports — erased at runtime, SSR-safe.
import type { Map as LMap, Marker as LMarker, LeafletMouseEvent } from 'leaflet'

export interface LocationModel {
  location_lat: number | null
  location_lon: number | null
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  country_code: string | null
}

const props = defineProps<{
  modelValue: LocationModel
}>()

const emit = defineEmits<{
  (e: 'update:modelValue', value: LocationModel): void
}>()

const { t } = useI18n()
const { search, reverse } = useGeocoding()

// Search state
const query = ref('')
const results = ref<GeocodingResult[]>([])
const searching = ref(false)
const searchError = ref<string | null>(null)
const hasSubmitted = ref(false)

// Shared AbortController — one in-flight request at a time across search/reverse
let abortController: AbortController | null = null

// Map state — populated in onMounted after dynamic Leaflet import
const mapContainer = ref<HTMLDivElement | null>(null)
let map: LMap | null = null
let marker: LMarker | null = null
// Holds the dynamically imported Leaflet default export so later functions can use it.
let L: typeof import('leaflet') | null = null
// Guard against unmount races: initMap has several await points (dynamic
// imports of leaflet, CSS, and 3 marker icon PNGs). If the component is
// destroyed mid-init, we must NOT create a map on a stale DOM node.
let destroyed = false

async function initMap() {
  if (!mapContainer.value) return

  // Dynamic imports — only run on the client, so SSR build won't touch window/document.
  const leaflet = await import('leaflet')
  if (destroyed) return
  await import('leaflet/dist/leaflet.css')
  if (destroyed) return
  L = leaflet.default ?? (leaflet as unknown as typeof import('leaflet'))

  // Fix for the well-known Leaflet + bundler marker-icon bug: the default icon URLs
  // reference relative paths that Vite can't resolve. Point them at the bundled assets.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  delete (L.Icon.Default.prototype as any)._getIconUrl
  L.Icon.Default.mergeOptions({
    iconRetinaUrl: (await import('leaflet/dist/images/marker-icon-2x.png')).default,
    iconUrl: (await import('leaflet/dist/images/marker-icon.png')).default,
    shadowUrl: (await import('leaflet/dist/images/marker-shadow.png')).default,
  })
  if (destroyed || !mapContainer.value) return

  // Default: mid-Europe wide view, no pin
  let initialCenter: [number, number] = [51.0, 10.0]
  let initialZoom = 4

  // If we already have coordinates, center on them with a close zoom and place a pin
  const hasCoords = props.modelValue.location_lat != null && props.modelValue.location_lon != null
  if (hasCoords) {
    initialCenter = [props.modelValue.location_lat!, props.modelValue.location_lon!]
    initialZoom = 17
  }

  map = L.map(mapContainer.value).setView(initialCenter, initialZoom)

  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>',
  }).addTo(map)

  if (hasCoords) {
    placePin(props.modelValue.location_lat!, props.modelValue.location_lon!)
  } else if (typeof navigator !== 'undefined' && navigator.geolocation) {
    // Try browser geolocation as a convenience (admin probably near the machine)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        if (map) map.setView([pos.coords.latitude, pos.coords.longitude], 15)
      },
      () => {
        // Silently ignore — user denied or timed out
      },
      { timeout: 5000 },
    )
  }

  // Click on empty map places a pin and triggers reverse geocoding
  map.on('click', (e: LeafletMouseEvent) => {
    const { lat, lng } = e.latlng
    placePin(lat, lng)
    updateCoords(lat, lng)
    void runReverseGeocoding(lat, lng)
  })
}

function placePin(lat: number, lng: number) {
  if (!map || !L) return
  if (marker) {
    marker.setLatLng([lat, lng])
  } else {
    marker = L.marker([lat, lng], { draggable: true }).addTo(map)
    // The dragend listener is registered only on initial creation — subsequent
    // placePin calls reuse the existing marker via setLatLng above and must NOT
    // re-register, or dragend would fire multiple times per user gesture.
    marker.on('dragend', () => {
      if (!marker) return
      const { lat: newLat, lng: newLng } = marker.getLatLng()
      updateCoords(newLat, newLng)
      void runReverseGeocoding(newLat, newLng)
    })
  }
}

function updateCoords(lat: number, lng: number) {
  emit('update:modelValue', {
    ...props.modelValue,
    location_lat: lat,
    location_lon: lng,
  })
}

async function runReverseGeocoding(lat: number, lng: number) {
  abortController?.abort()
  abortController = new AbortController()
  const result = await reverse(lat, lng, abortController.signal)
  if (!result) return
  applyGeocodingResult(result, { keepCoords: true })
}

function applyGeocodingResult(r: GeocodingResult, opts: { keepCoords: boolean }) {
  emit('update:modelValue', {
    ...props.modelValue,
    location_lat: opts.keepCoords ? props.modelValue.location_lat : r.lat,
    location_lon: opts.keepCoords ? props.modelValue.location_lon : r.lon,
    address_street: r.address.road ?? null,
    address_house_number: r.address.house_number ?? null,
    address_postal_code: r.address.postcode ?? null,
    address_city: pickCity(r.address),
    formatted_address: r.display_name,
    country_code: r.address.country_code ? r.address.country_code.toUpperCase() : null,
  })
}

async function onSearchSubmit() {
  const q = query.value.trim()
  if (q.length < 2) {
    searchError.value = t('machineSettings.geocodingError')
    return
  }
  abortController?.abort()
  abortController = new AbortController()
  searching.value = true
  searchError.value = null
  hasSubmitted.value = true
  try {
    const found = await search(q, abortController.signal)
    results.value = found
    if (found.length === 0) {
      searchError.value = null // "no results" hint is rendered inline in template
    }
  } catch (err) {
    searchError.value = t('machineSettings.geocodingError')
    console.warn('[LocationPicker] search failed', err)
  } finally {
    searching.value = false
  }
}

function onPickResult(r: GeocodingResult) {
  // Place pin on the map and center on it
  if (map) {
    map.setView([r.lat, r.lon], 17)
    placePin(r.lat, r.lon)
  }
  // Apply all the fields, including fresh coordinates from the search result
  applyGeocodingResult(r, { keepCoords: false })
  // Clear the results list so the user can see the preview
  results.value = []
  hasSubmitted.value = false
}

// Lifecycle
onMounted(() => {
  void initMap()
})

onBeforeUnmount(() => {
  destroyed = true
  abortController?.abort()
  if (map) {
    map.remove()
    map = null
  }
  marker = null
})
</script>

<template>
  <div class="flex flex-col gap-3">
    <!-- Search input -->
    <div>
      <label class="text-xs font-medium text-muted-foreground">
        {{ t('machineSettings.addressLabel') }}
      </label>
      <div class="mt-1 flex gap-2">
        <input
          v-model="query"
          type="text"
          :placeholder="t('machineSettings.addressPlaceholder')"
          class="flex-1 h-9 rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          @keydown.enter.prevent="onSearchSubmit"
        />
        <button
          type="button"
          class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
          :disabled="searching || query.trim().length < 2"
          @click="onSearchSubmit"
        >
          {{ searching ? t('machineSettings.searching') : t('machineSettings.searchButton') }}
        </button>
      </div>
      <p v-if="searchError" class="mt-1 text-xs text-destructive">{{ searchError }}</p>

      <!-- Results list (only after submit) -->
      <ul v-if="results.length > 0" class="mt-2 max-h-48 overflow-y-auto rounded-md border border-input bg-popover shadow-sm">
        <li
          v-for="(r, i) in results"
          :key="i"
          class="cursor-pointer border-b border-border px-3 py-2 text-sm last:border-b-0 hover:bg-accent"
          @click="onPickResult(r)"
        >
          <div class="font-medium">{{ r.display_name }}</div>
          <div class="text-xs text-muted-foreground">
            {{ r.address.city ?? r.address.town ?? '' }}{{ r.address.country_code ? `, ${r.address.country_code.toUpperCase()}` : '' }}
          </div>
        </li>
      </ul>
      <p v-else-if="hasSubmitted && !searching" class="mt-1 text-xs text-muted-foreground">
        {{ t('machineSettings.noResults') }}
      </p>
    </div>

    <!-- Map -->
    <div ref="mapContainer" class="h-[200px] w-full rounded-md border border-input sm:h-[280px]" />
    <p v-if="modelValue.location_lat != null && modelValue.location_lon != null" class="text-xs text-muted-foreground">
      {{ t('machineSettings.pinHint') }}
    </p>

    <!-- Detected address preview -->
    <div
      v-if="modelValue.formatted_address || modelValue.address_street || modelValue.address_city"
      class="rounded-md border border-input bg-muted/30 p-3 text-xs"
    >
      <div class="mb-1 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
        {{ t('machineSettings.detectedAddress') }}
      </div>
      <div class="grid grid-cols-2 gap-x-3 gap-y-1">
        <div><span class="text-muted-foreground">{{ t('machineSettings.street') }}:</span> {{ modelValue.address_street ?? '—' }} {{ modelValue.address_house_number ?? '' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.postalCode') }}:</span> {{ modelValue.address_postal_code ?? '—' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.city') }}:</span> {{ modelValue.address_city ?? '—' }}</div>
        <div><span class="text-muted-foreground">{{ t('machineSettings.country') }}:</span> {{ modelValue.country_code ?? '—' }}</div>
      </div>
      <div v-if="modelValue.location_lat != null && modelValue.location_lon != null" class="mt-1 font-mono text-[10px] text-muted-foreground">
        {{ modelValue.location_lat.toFixed(5) }}, {{ modelValue.location_lon.toFixed(5) }}
      </div>
    </div>
  </div>
</template>
