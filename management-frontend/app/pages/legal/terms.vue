<script setup lang="ts">
// PUBLIC page — must NOT declare `middleware: 'auth'`.
import LegalPage from '~/components/legal/LegalPage.vue'

definePageMeta({ layout: false })

const { t, tm, rt } = useI18n()

interface LegalSection {
  heading: string
  paragraphs: string[]
}
const sections = computed(() =>
  (tm('legal.terms.sections') as unknown[]).map((s) => {
    const sec = s as { heading: unknown; paragraphs: unknown[] }
    return {
      heading: rt(sec.heading as never),
      paragraphs: (sec.paragraphs ?? []).map((p) => rt(p as never)),
    } as LegalSection
  })
)
</script>

<template>
  <LegalPage :title="t('legal.terms.title')">
    <p class="font-medium">{{ t('legal.terms.intro') }}</p>
    <section v-for="(s, i) in sections" :key="i">
      <h2>{{ s.heading }}</h2>
      <p v-for="(p, j) in s.paragraphs" :key="j" class="mt-2">{{ p }}</p>
    </section>
  </LegalPage>
</template>
