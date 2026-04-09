<script setup lang="ts">
import { getProductImageUrl } from '@/composables/useProducts'

definePageMeta({ layout: false })

const { t } = useI18n()
const route = useRoute()
const subdomain = route.params.subdomain as string

interface Product {
  id: string
  name: string
  slot: number
  price: number | null
  stock: number
  capacity: number
  image_path: string | null
  available: boolean
}

interface Category {
  name: string
  products: Product[]
}

interface MachineData {
  machine: { name: string; location_lat: number | null; location_lon: number | null }
  machine_id: string
  status: string | null
  status_at: string | null
  categories: Category[]
}

const { data, error, refresh } = await useFetch<MachineData>('/functions/v1/public-machine-data', {
  params: { subdomain },
})

// --- Notify modal state ---
const notifyProductId = ref<string | null>(null)
const notifyProductName = ref('')
const notifyEmail = ref('')
const notifyLoading = ref(false)
const notifyDone = reactive(new Set<string>())
const notifyError = ref(false)

function openNotify(product: Product) {
  notifyProductId.value = product.id
  notifyProductName.value = product.name
  notifyEmail.value = ''
  notifyError.value = false
}

function closeNotify() {
  notifyProductId.value = null
}

async function subscribeRestock() {
  if (!notifyProductId.value || !notifyEmail.value) return
  notifyLoading.value = true
  notifyError.value = false
  try {
    await $fetch('/functions/v1/subscribe-restock', {
      method: 'POST',
      body: {
        machine_id: data.value!.machine_id,
        product_id: notifyProductId.value,
        email: notifyEmail.value,
      },
    })
    notifyDone.add(notifyProductId.value)
    closeNotify()
  } catch {
    notifyError.value = true
  } finally {
    notifyLoading.value = false
  }
}

// --- Wish modal state ---
const wishOpen = ref(false)
const wishText = ref('')
const wishEmail = ref('')
const wishLoading = ref(false)
const wishDone = ref(false)
const wishError = ref(false)

async function submitWish() {
  if (!wishText.value.trim()) return
  wishLoading.value = true
  wishError.value = false
  try {
    await $fetch('/functions/v1/submit-product-wish', {
      method: 'POST',
      body: {
        machine_id: data.value!.machine_id,
        wish_text: wishText.value.trim(),
        email: wishEmail.value || undefined,
      },
    })
    wishDone.value = true
    wishText.value = ''
    wishEmail.value = ''
    setTimeout(() => {
      wishDone.value = false
      wishOpen.value = false
    }, 2500)
  } catch {
    wishError.value = true
  } finally {
    wishLoading.value = false
  }
}

// --- Helpers ---
function stockPercent(stock: number, capacity: number) {
  return capacity > 0 ? (stock / capacity) * 100 : 0
}

function stockBarColor(percent: number) {
  if (percent > 50) return 'bg-emerald-500'
  if (percent > 25) return 'bg-amber-500'
  return 'bg-red-500'
}

function formatPrice(price: number | null) {
  if (price === null || price === undefined) return '–'
  return price.toLocaleString('de-DE', { style: 'currency', currency: 'EUR' })
}

function mapsUrl(lat: number, lon: number) {
  return `https://www.google.com/maps/dir/?api=1&destination=${lat},${lon}`
}

const isOnline = computed(() => data.value?.status === 'online')

// Dark mode is handled by the app-level head script that adds .dark to <html>
// based on localStorage/prefers-color-scheme. No manual handling needed here.
</script>

<template>
  <div :class="{ dark: isDark }" class="min-h-dvh bg-background text-foreground">
    <Head>
      <title>{{ data?.machine?.name || t('publicStorefront.loading') }}</title>
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    </Head>

    <!-- Loading -->
    <div v-if="!data && !error" class="flex min-h-dvh items-center justify-center">
      <div class="text-center">
        <div class="mx-auto mb-4 size-8 animate-spin rounded-full border-2 border-muted-foreground border-t-primary" />
        <p class="text-sm text-muted-foreground">{{ t('publicStorefront.loading') }}</p>
      </div>
    </div>

    <!-- Error / Not found -->
    <div v-else-if="error || !data" class="flex min-h-dvh items-center justify-center p-6">
      <div class="text-center">
        <div class="mx-auto mb-4 flex size-16 items-center justify-center rounded-full bg-muted">
          <svg class="size-8 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M15.182 16.318A4.486 4.486 0 0012.016 15a4.486 4.486 0 00-3.198 1.318M21 12a9 9 0 11-18 0 9 9 0 0118 0zM9.75 9.75c0 .414-.168.75-.375.75S9 10.164 9 9.75 9.168 9 9.375 9s.375.336.375.75zm-.375 0h.008v.015h-.008V9.75zm5.625 0c0 .414-.168.75-.375.75s-.375-.336-.375-.75.168-.75.375-.75.375.336.375.75zm-.375 0h.008v.015h-.008V9.75z" />
          </svg>
        </div>
        <h2 class="mb-2 text-lg font-semibold">{{ t('publicStorefront.machineNotFound') }}</h2>
        <p class="mb-6 text-sm text-muted-foreground">{{ t('publicStorefront.machineNotFoundDesc') }}</p>
        <button
          class="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          @click="refresh()"
        >
          {{ t('publicStorefront.retry') }}
        </button>
      </div>
    </div>

    <!-- Main content -->
    <div v-else class="mx-auto max-w-2xl px-4 py-6 pb-20">
      <!-- Machine header -->
      <header class="mb-6">
        <h1 class="text-2xl font-bold tracking-tight">{{ data.machine.name }}</h1>
        <div class="mt-2 flex flex-wrap items-center gap-3">
          <!-- Status badge -->
          <span
            class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium"
            :class="isOnline
              ? 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400'
              : 'bg-muted text-muted-foreground'"
          >
            <span class="size-1.5 rounded-full" :class="isOnline ? 'bg-emerald-500' : 'bg-muted-foreground'" />
            {{ isOnline ? t('publicStorefront.online') : t('publicStorefront.offline') }}
          </span>
          <!-- Route link -->
          <a
            v-if="data.machine.location_lat && data.machine.location_lon"
            :href="mapsUrl(data.machine.location_lat, data.machine.location_lon)"
            target="_blank"
            rel="noopener"
            class="inline-flex items-center gap-1.5 rounded-full bg-primary px-3 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90"
          >
            <svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 10.5a3 3 0 11-6 0 3 3 0 016 0z" />
              <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 1115 0z" />
            </svg>
            {{ t('publicStorefront.showRoute') }}
          </a>
        </div>
      </header>

      <!-- Action bar -->
      <div class="mb-6 flex gap-2">
        <button
          class="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-2 text-sm font-medium text-card-foreground hover:bg-accent"
          @click="wishOpen = true; wishDone = false; wishError = false"
        >
          <svg class="size-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 18v-5.25m0 0a6.01 6.01 0 001.5-.189m-1.5.189a6.01 6.01 0 01-1.5-.189m3.75 7.478a12.06 12.06 0 01-4.5 0m3.75 2.383a14.406 14.406 0 01-3 0M14.25 18v-.192c0-.983.658-1.823 1.508-2.316a7.5 7.5 0 10-7.517 0c.85.493 1.509 1.333 1.509 2.316V18" />
          </svg>
          {{ t('publicStorefront.productWish') }}
        </button>
      </div>

      <!-- No products -->
      <div v-if="data.categories.length === 0" class="py-12 text-center">
        <p class="text-muted-foreground">{{ t('publicStorefront.noProducts') }}</p>
      </div>

      <!-- Category sections -->
      <section v-for="category in data.categories" :key="category.name" class="mb-8">
        <h2 class="mb-3 text-lg font-semibold">
          {{ category.name }}
          <span class="text-sm font-normal text-muted-foreground">({{ category.products.length }})</span>
        </h2>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div
            v-for="product in category.products"
            :key="product.id"
            class="rounded-xl border border-border bg-card p-4"
          >
            <!-- Product image + info -->
            <div class="mb-3 flex items-start gap-3">
              <img
                v-if="product.image_path"
                :src="getProductImageUrl(product.image_path)"
                :alt="product.name"
                class="size-12 shrink-0 rounded-lg object-cover"
              />
              <div
                v-else
                class="flex size-12 shrink-0 items-center justify-center rounded-lg bg-muted"
              >
                <svg class="size-6 text-muted-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 01-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125z" />
                </svg>
              </div>
              <div class="min-w-0 flex-1">
                <div class="flex items-start justify-between gap-2">
                  <h3 class="text-sm font-semibold leading-tight">{{ product.name }}</h3>
                  <span
                    class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide"
                    :class="product.available
                      ? 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400'
                      : 'bg-red-500/15 text-red-600 dark:text-red-400'"
                  >
                    {{ product.available ? t('publicStorefront.available') : t('publicStorefront.soldOut') }}
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-muted-foreground">
                  {{ t('publicStorefront.slot', { slot: product.slot }) }}
                </p>
              </div>
            </div>

            <!-- Price + stock -->
            <div class="mb-2 flex items-end justify-between">
              <span class="text-xs text-muted-foreground">
                {{ t('publicStorefront.stock') }}: {{ product.stock }} / {{ product.capacity }}
              </span>
              <span class="text-lg font-bold tabular-nums">{{ formatPrice(product.price) }}</span>
            </div>

            <!-- Stock bar -->
            <div class="h-1.5 overflow-hidden rounded-full bg-muted">
              <div
                class="h-full rounded-full transition-all duration-300"
                :class="stockBarColor(stockPercent(product.stock, product.capacity))"
                :style="{ width: `${Math.min(stockPercent(product.stock, product.capacity), 100)}%` }"
              />
            </div>

            <!-- Notify button for sold-out products -->
            <button
              v-if="!product.available && !notifyDone.has(product.id)"
              class="mt-3 flex w-full items-center justify-center gap-1.5 rounded-lg border border-border py-2 text-xs font-medium text-muted-foreground hover:bg-accent hover:text-foreground"
              @click="openNotify(product)"
            >
              <svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75v-.7V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0" />
              </svg>
              {{ t('publicStorefront.notifyMe') }}
            </button>
            <p
              v-if="!product.available && notifyDone.has(product.id)"
              class="mt-3 text-center text-xs text-emerald-600 dark:text-emerald-400"
            >
              {{ t('publicStorefront.notifySuccess') }}
            </p>
          </div>
        </div>
      </section>

      <!-- Footer -->
      <footer class="mt-12 border-t border-border pt-4 text-center text-xs text-muted-foreground">
        {{ t('publicStorefront.poweredBy') }} VMflow
      </footer>
    </div>

    <!-- Notify modal overlay -->
    <Teleport to="body">
      <Transition name="fade">
        <div
          v-if="notifyProductId"
          class="fixed inset-0 z-50 flex items-end justify-center sm:items-center"
                  >
          <div class="fixed inset-0 bg-black/50" @click="closeNotify()" />
          <div class="relative w-full max-w-md rounded-t-2xl border border-border bg-card p-6 sm:rounded-2xl">
            <h3 class="mb-1 text-sm font-semibold text-card-foreground">
              {{ t('publicStorefront.notifyTitle', { product: notifyProductName }) }}
            </h3>
            <div class="mt-4 flex gap-2">
              <input
                v-model="notifyEmail"
                type="email"
                :placeholder="t('publicStorefront.notifyEmailPlaceholder')"
                class="flex-1 rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                @keyup.enter="subscribeRestock()"
              />
              <button
                :disabled="notifyLoading || !notifyEmail"
                class="shrink-0 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                @click="subscribeRestock()"
              >
                {{ notifyLoading ? '...' : t('publicStorefront.notifySubmit') }}
              </button>
            </div>
            <p v-if="notifyError" class="mt-2 text-xs text-red-500">
              {{ t('publicStorefront.notifyError') }}
            </p>
          </div>
        </div>
      </Transition>
    </Teleport>

    <!-- Wish modal overlay -->
    <Teleport to="body">
      <Transition name="fade">
        <div
          v-if="wishOpen"
          class="fixed inset-0 z-50 flex items-end justify-center sm:items-center"
                  >
          <div class="fixed inset-0 bg-black/50" @click="wishOpen = false" />
          <div class="relative w-full max-w-md rounded-t-2xl border border-border bg-card p-6 sm:rounded-2xl">
            <h3 class="mb-4 text-sm font-semibold text-card-foreground">
              {{ t('publicStorefront.wishTitle') }}
            </h3>

            <div v-if="wishDone" class="py-4 text-center">
              <div class="mx-auto mb-2 flex size-10 items-center justify-center rounded-full bg-emerald-500/15">
                <svg class="size-5 text-emerald-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                </svg>
              </div>
              <p class="text-sm text-emerald-600 dark:text-emerald-400">{{ t('publicStorefront.wishSuccess') }}</p>
            </div>

            <div v-else class="space-y-3">
              <input
                v-model="wishText"
                type="text"
                maxlength="500"
                :placeholder="t('publicStorefront.wishProductPlaceholder')"
                class="w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              />
              <input
                v-model="wishEmail"
                type="email"
                :placeholder="t('publicStorefront.wishEmailPlaceholder')"
                class="w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
              />
              <button
                :disabled="wishLoading || !wishText.trim()"
                class="w-full rounded-lg bg-primary py-2.5 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
                @click="submitWish()"
              >
                {{ wishLoading ? '...' : t('publicStorefront.wishSubmit') }}
              </button>
              <p v-if="wishError" class="text-xs text-red-500">
                {{ t('publicStorefront.wishError') }}
              </p>
            </div>
          </div>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
