<script setup lang="ts">
import { IconMoon, IconSun } from '@tabler/icons-vue'

const { t } = useI18n()
const { isDark, toggleTheme } = useTheme()
</script>

<template>
  <!-- Appearance -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="mb-1 text-lg font-semibold">{{ t('settings.appearance') }}</h2>
    <p class="mb-5 text-sm text-muted-foreground">{{ t('settings.appearanceDescription') }}</p>

    <div class="flex items-center justify-between">
      <div class="space-y-0.5">
        <label class="text-sm font-medium">{{ t('settings.darkMode') }}</label>
        <p class="text-sm text-muted-foreground">
          {{ isDark ? t('settings.darkThemeActive') : t('settings.lightThemeActive') }}
        </p>
      </div>
      <button
        class="inline-flex h-9 w-9 items-center justify-center rounded-md border border-input bg-background shadow-sm transition-colors hover:bg-muted"
        @click="toggleTheme()"
      >
        <IconMoon v-if="isDark" class="size-4" />
        <IconSun v-else class="size-4" />
      </button>
    </div>
  </div>
</template>
