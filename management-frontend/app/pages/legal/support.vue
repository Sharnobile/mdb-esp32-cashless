<script setup lang="ts">
// PUBLIC page (App Store support URL) — must NOT declare `middleware: 'auth'`.
import LegalPage from '~/components/legal/LegalPage.vue'

definePageMeta({ layout: false })

const { t, tm, rt } = useI18n()

interface FaqItem {
  q: string
  a: string
}
const faq = computed(() =>
  (tm('legal.support.faq') as unknown[]).map((f) => {
    const item = f as { q: unknown; a: unknown }
    return { q: rt(item.q as never), a: rt(item.a as never) } as FaqItem
  })
)
</script>

<template>
  <LegalPage :title="t('legal.support.title')">
    <p class="font-medium">{{ t('legal.support.intro') }}</p>

    <h2>{{ t('legal.support.contactHeading') }}</h2>
    <p class="mt-2">{{ t('legal.support.contactText') }}</p>

    <h2>{{ t('legal.support.faqHeading') }}</h2>
    <div v-for="(f, i) in faq" :key="i" class="mt-4">
      <p class="font-semibold !text-zinc-900 dark:!text-zinc-100">{{ f.q }}</p>
      <p class="mt-1">{{ f.a }}</p>
    </div>
  </LegalPage>
</template>
