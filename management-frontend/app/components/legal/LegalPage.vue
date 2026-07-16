<script setup lang="ts">
// Shared shell for the public legal pages (/legal/*).
// These pages are the App Store's privacy/support URLs — they MUST stay
// reachable logged-out, so no page using this shell may declare
// `middleware: 'auth'` (protection in this app is opt-in per page).
const props = defineProps<{
  title: string
}>()

const { t, locale, setLocale } = useI18n()

const otherLocale = computed(() => (locale.value === 'de' ? 'en' : 'de'))

const pages = [
  { path: '/legal/privacy', key: 'legal.privacy.title' },
  { path: '/legal/terms', key: 'legal.terms.title' },
  { path: '/legal/imprint', key: 'legal.imprint.title' },
  { path: '/legal/support', key: 'legal.support.title' },
]

useHead(() => ({ title: `${props.title} – VMflow` }))
</script>

<template>
  <div class="min-h-screen bg-white text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
    <div class="mx-auto max-w-3xl px-6 py-10">
      <header class="mb-8 flex items-start justify-between gap-4">
        <div>
          <p class="text-sm font-medium text-zinc-500">VMflow</p>
          <h1 class="mt-1 text-3xl font-bold tracking-tight">{{ title }}</h1>
        </div>
        <button
          class="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
          type="button"
          @click="setLocale(otherLocale)"
        >
          {{ otherLocale === 'de' ? 'Deutsch' : 'English' }}
        </button>
      </header>

      <main class="space-y-6 leading-relaxed [&_h2]:mt-8 [&_h2]:text-xl [&_h2]:font-semibold [&_p]:text-zinc-700 dark:[&_p]:text-zinc-300">
        <slot />
      </main>

      <footer class="mt-14 border-t border-zinc-200 pt-6 text-sm text-zinc-500 dark:border-zinc-800">
        <nav class="flex flex-wrap gap-x-5 gap-y-2">
          <NuxtLink
            v-for="p in pages"
            :key="p.path"
            :to="p.path"
            class="hover:text-zinc-900 dark:hover:text-zinc-100"
          >
            {{ t(p.key) }}
          </NuxtLink>
        </nav>
        <p class="mt-4">{{ t('legal.common.lastUpdated') }}</p>
      </footer>
    </div>
  </div>
</template>
