<script setup lang="ts">
import { IconLanguage } from "@tabler/icons-vue"

const { locale, locales, setLocale } = useI18n()

const availableLocales = computed(() =>
  (locales.value as { code: string; name: string }[]).filter(l => l.code !== locale.value)
)

async function switchLocale(code: string) {
  await setLocale(code)

  // Persist to users.locale so edge-function pushes can read the
  // preference. Best-effort — if the DB write fails, the i18n cookie
  // is still set and the UI follows; pushes just fall back to 'en'.
  try {
    const supabase = useSupabaseClient()
    const user = useSupabaseUser()
    if (user.value?.id) {
      await supabase.from('users').update({ locale: code }).eq('id', user.value.id)
    }
  } catch (err) {
    console.warn('[LanguageSwitcher] persist failed:', err)
  }
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
