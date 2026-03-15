<script setup lang="ts">
definePageMeta({ layout: false })

const { t } = useI18n()
const { fetchOrganization, fetchError } = useOrganization()

const checking = ref(false)
const retryCount = ref(0)
const maxAutoRetries = 20
const retryIntervalMs = 5000

let timer: ReturnType<typeof setInterval> | null = null

async function checkServer() {
  checking.value = true
  try {
    await fetchOrganization()
    // Success — server is up, navigate to home (middleware will re-run)
    await navigateTo('/')
  } catch {
    retryCount.value++
  } finally {
    checking.value = false
  }
}

function startAutoRetry() {
  if (timer) return
  timer = setInterval(async () => {
    if (checking.value) return
    if (retryCount.value >= maxAutoRetries) {
      stopAutoRetry()
      return
    }
    await checkServer()
  }, retryIntervalMs)
}

function stopAutoRetry() {
  if (timer) {
    clearInterval(timer)
    timer = null
  }
}

async function manualRetry() {
  retryCount.value = 0
  await checkServer()
  if (fetchError.value) {
    startAutoRetry()
  }
}

onMounted(() => {
  startAutoRetry()
})

onUnmounted(() => {
  stopAutoRetry()
})
</script>

<template>
  <div class="flex min-h-screen items-center justify-center bg-background">
    <div class="w-full max-w-sm text-center">
      <div class="mb-6 flex justify-center">
        <div class="relative">
          <div class="h-16 w-16 rounded-full border-4 border-muted" />
          <div
            v-if="checking || retryCount < maxAutoRetries"
            class="absolute inset-0 h-16 w-16 rounded-full border-4 border-t-primary animate-spin"
          />
        </div>
      </div>

      <h1 class="text-xl font-semibold mb-2">{{ t('serverLoading.title') }}</h1>
      <p class="text-sm text-muted-foreground mb-6">{{ t('serverLoading.description') }}</p>

      <div v-if="retryCount >= maxAutoRetries" class="mb-4">
        <p class="text-sm text-destructive mb-4">{{ t('serverLoading.timeout') }}</p>
      </div>

      <button
        class="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
        :disabled="checking"
        @click="manualRetry"
      >
        <span v-if="checking">{{ t('serverLoading.checking') }}</span>
        <span v-else>{{ t('serverLoading.retry') }}</span>
      </button>

      <p v-if="retryCount > 0 && retryCount < maxAutoRetries" class="mt-4 text-xs text-muted-foreground">
        {{ t('serverLoading.autoRetry') }}
      </p>
    </div>
  </div>
</template>
