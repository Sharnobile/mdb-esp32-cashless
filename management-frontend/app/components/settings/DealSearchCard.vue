<script setup lang="ts">
import { IconTag } from '@tabler/icons-vue'
import { getDealsPreset } from '@/composables/useDeals'
import { Switch } from '~/components/ui/switch'

const { t } = useI18n()
const { organization, role } = useOrganization()

// ── Deal Search (admin only) ────────────────────────────────────────────────
const {
  dealsEnabled,
  dealsZipCode,
  dealsConfig,
  hasCustomConfig,
  settingsLoading: dealsSettingsLoading,
  settingsError: dealsSettingsError,
  settingsSuccess: dealsSettingsSuccess,
  loadSettings: loadDealsSettings,
  saveSettings: saveDealsSettings,
  resetConfig: resetDealsConfig,
} = useDeals()

// companyCountry comes from useTaxSettings (uses useState globally — shared with TaxCard)
const { companyCountry } = useTaxSettings()

// Keyword editing helpers — edit as comma-separated text
const editingKeywords = ref(false)
const genericTermsText = ref('')
const wildcardPhrasesText = ref('')
const appPatternsText = ref('')

function startEditingKeywords() {
  // Pre-fill with custom values if set, otherwise show the country defaults
  const preset = getDealsPreset(companyCountry.value)
  genericTermsText.value = (dealsConfig.value.generic_terms ?? preset.generic_terms).join(', ')
  wildcardPhrasesText.value = (dealsConfig.value.wildcard_phrases ?? preset.wildcard_phrases).join(', ')
  appPatternsText.value = (dealsConfig.value.app_detection_patterns ?? preset.app_detection_patterns).join(', ')
  editingKeywords.value = true
}

function applyKeywordEdits() {
  const parse = (s: string) => {
    const items = s.split(',').map((t) => t.trim().toLowerCase()).filter(Boolean)
    return items.length > 0 ? items : null
  }
  dealsConfig.value.generic_terms = parse(genericTermsText.value)
  dealsConfig.value.wildcard_phrases = parse(wildcardPhrasesText.value)
  dealsConfig.value.app_detection_patterns = parse(appPatternsText.value)
  editingKeywords.value = false
}

function resetToDefaults() {
  resetDealsConfig()
  // Refill textareas with country defaults so user sees the reset
  const preset = getDealsPreset(companyCountry.value)
  genericTermsText.value = preset.generic_terms.join(', ')
  wildcardPhrasesText.value = preset.wildcard_phrases.join(', ')
  appPatternsText.value = preset.app_detection_patterns.join(', ')
}

// Own watcher: only load this card's data
watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') loadDealsSettings()
}, { immediate: true })
</script>

<template>
  <!-- Deal Search (admin only) -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconTag class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.dealsSection') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.dealsDescription') }}</p>
      </div>
    </div>

    <form class="space-y-4" @submit.prevent="saveDealsSettings">
      <div class="flex items-center justify-between">
        <div class="space-y-0.5">
          <label class="text-sm font-medium">{{ t('settings.dealsEnable') }}</label>
          <p class="text-sm text-muted-foreground">{{ t('settings.dealsEnableHint') }}</p>
        </div>
        <Switch
          :checked="dealsEnabled"
          @update:checked="dealsEnabled = $event"
        />
      </div>

      <div v-if="dealsEnabled" class="space-y-1">
        <label class="text-sm font-medium" for="deals-zip">{{ t('settings.dealsZipCode') }}</label>
        <input
          id="deals-zip"
          v-model="dealsZipCode"
          type="text"
          inputmode="numeric"
          maxlength="5"
          placeholder="60487"
          class="flex h-9 w-full max-w-[200px] rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="text-xs text-muted-foreground">{{ t('settings.dealsZipCodeHint') }}</p>
      </div>

      <!-- Keyword configuration -->
      <div v-if="dealsEnabled" class="space-y-3 rounded-lg border p-4">
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm font-medium">{{ t('settings.dealsKeywords') }}</p>
            <p class="text-xs text-muted-foreground">
              {{ hasCustomConfig ? t('settings.dealsKeywordsCustom') : t('settings.dealsKeywordsDefault') }}
            </p>
          </div>
          <button
            v-if="!editingKeywords"
            type="button"
            class="inline-flex h-7 items-center rounded-md border px-2.5 text-xs font-medium transition-colors hover:bg-muted"
            @click="startEditingKeywords"
          >
            {{ t('common.edit') }}
          </button>
        </div>

        <template v-if="editingKeywords">
          <div class="space-y-1">
            <label class="text-xs font-medium">{{ t('settings.dealsGenericTerms') }}</label>
            <textarea
              v-model="genericTermsText"
              rows="3"
              :placeholder="t('settings.dealsGenericTermsHint')"
              class="flex w-full rounded-md border border-input bg-background px-3 py-2 text-xs shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>
          <div class="space-y-1">
            <label class="text-xs font-medium">{{ t('settings.dealsWildcardPhrases') }}</label>
            <textarea
              v-model="wildcardPhrasesText"
              rows="2"
              :placeholder="t('settings.dealsWildcardHint')"
              class="flex w-full rounded-md border border-input bg-background px-3 py-2 text-xs shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>
          <div class="space-y-1">
            <label class="text-xs font-medium">{{ t('settings.dealsAppPatterns') }}</label>
            <textarea
              v-model="appPatternsText"
              rows="2"
              :placeholder="t('settings.dealsAppPatternsHint')"
              class="flex w-full rounded-md border border-input bg-background px-3 py-2 text-xs shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            />
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              class="inline-flex h-7 items-center rounded-md bg-primary px-2.5 text-xs font-medium text-primary-foreground transition-colors hover:bg-primary/90"
              @click="applyKeywordEdits"
            >
              {{ t('settings.dealsApplyKeywords') }}
            </button>
            <button
              type="button"
              class="inline-flex h-7 items-center rounded-md border px-2.5 text-xs font-medium transition-colors hover:bg-muted"
              @click="resetToDefaults"
            >
              {{ t('settings.dealsResetDefaults') }}
            </button>
            <button
              type="button"
              class="inline-flex h-7 items-center rounded-md border px-2.5 text-xs font-medium transition-colors hover:bg-muted"
              @click="editingKeywords = false"
            >
              {{ t('common.cancel') }}
            </button>
          </div>
        </template>
      </div>

      <p v-if="dealsSettingsError" class="text-sm text-destructive">{{ dealsSettingsError }}</p>
      <p v-if="dealsSettingsSuccess" class="text-sm text-green-600">{{ t('settings.dealsSaved') }}</p>

      <button
        type="submit"
        :disabled="dealsSettingsLoading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <span v-if="dealsSettingsLoading">{{ t('common.saving') }}</span>
        <span v-else>{{ t('common.save') }}</span>
      </button>
    </form>
  </div>
</template>
