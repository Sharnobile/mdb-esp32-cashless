<script setup lang="ts">
import { IconLanguage } from "@tabler/icons-vue"

const { locale, locales, setLocale } = useI18n()

const availableLocales = computed(() =>
  (locales.value as { code: string; name: string }[]).filter(l => l.code !== locale.value)
)

function switchLocale(code: string) {
  setLocale(code)
}
</script>

<template>
  <div class="flex items-center gap-1">
    <button
      v-for="loc in availableLocales"
      :key="loc.code"
      class="inline-flex items-center gap-1.5 rounded-md px-2 py-1.5 text-sm hover:bg-muted transition-colors w-full"
      @click="switchLocale(loc.code)"
    >
      <IconLanguage class="size-4" />
      {{ loc.name }}
    </button>
  </div>
</template>
