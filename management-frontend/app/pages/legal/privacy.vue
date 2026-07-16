<script setup lang="ts">
// PUBLIC page (App Store privacy URL) — must NOT declare `middleware: 'auth'`.
import LegalPage from '~/components/legal/LegalPage.vue'

definePageMeta({ layout: false })

const { t, tm, rt } = useI18n()

// Message arrays need tm() + rt(): plain t() returns a string, not the array.
// tm() does not apply locale fallback — en/de MUST both carry the full
// legal.* tree (enforced by the key-parity check in the test suite).
interface LegalSection {
  heading: string
  paragraphs: string[]
}
const sections = computed(() =>
  (tm('legal.privacy.sections') as unknown[]).map((s) => {
    const sec = s as { heading: unknown; paragraphs: unknown[] }
    return {
      heading: rt(sec.heading as never),
      paragraphs: (sec.paragraphs ?? []).map((p) => rt(p as never)),
    } as LegalSection
  })
)
</script>

<template>
  <LegalPage :title="t('legal.privacy.title')">
    <p class="font-medium">{{ t('legal.privacy.intro') }}</p>
    <section v-for="(s, i) in sections" :key="i">
      <h2>{{ s.heading }}</h2>
      <p v-for="(p, j) in s.paragraphs" :key="j" class="mt-2">{{ p }}</p>
    </section>
  </LegalPage>
</template>
