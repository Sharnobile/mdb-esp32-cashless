<script setup lang="ts">
definePageMeta({ middleware: 'auth' })
import { computed, onMounted, ref } from 'vue'
import { Switch } from '~/components/ui/switch'
import { Button } from '~/components/ui/button'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '~/components/ui/card'
import { IconPlus, IconPencil, IconTrash, IconArrowLeft } from '@tabler/icons-vue'
import AddWebhookDialog from '~/components/extensions/AddWebhookDialog.vue'
import WebhookTestButton from '~/components/extensions/WebhookTestButton.vue'
import { BUILTIN_PROVIDERS, useProviderSettings } from '~/composables/useProviderSettings'

const EXTENSION_POINT = 'deal-source' as const
const { t } = useI18n()
const { organization } = useOrganization()
// The auth middleware guarantees `organization.value` is populated before the
// page renders on client navigation; the wrapping `<template v-if>` below is
// belt-and-braces for SSR / hard-refresh races. Inside that guard, we know
// `organization.value!.id` is a non-empty string.
const companyId = computed(() => organization.value!.id)

const settings = useProviderSettings(companyId.value)
const { rows, load, setEnabled, addWebhook, updateWebhook, removeWebhook } = settings

const dialogOpen   = ref(false)
const editingRow   = ref<{ providerId: string; displayName: string; url: string; authToken: string; extraConfigJson: string } | undefined>(undefined)

onMounted(async () => { await load(EXTENSION_POINT) })

const builtinRows = computed(() =>
  BUILTIN_PROVIDERS[EXTENSION_POINT].map((meta) => {
    const row = rows.value.find((r) => r.provider_id === meta.id)
    return { meta, enabled: row?.enabled ?? false }
  }),
)
const webhookRows = computed(() => rows.value.filter((r) => r.provider_id.startsWith('webhook-')))

function openAddDialog() {
  editingRow.value = undefined
  dialogOpen.value = true
}

function openEditDialog(providerId: string) {
  const row = rows.value.find((r) => r.provider_id === providerId)
  if (!row) return
  const cfg = row.config as { url?: string; authToken?: string }
  const { url: _u, authToken: _t, ...extra } = cfg
  editingRow.value = {
    providerId,
    displayName: row.display_name ?? '',
    url: _u ?? '',
    authToken: _t ?? '',
    extraConfigJson: JSON.stringify(extra, null, 2),
  }
  dialogOpen.value = true
}

async function onSubmit(payload: {
  providerId?: string
  displayName: string
  url: string
  authToken: string
  extraConfig: Record<string, unknown>
}) {
  if (payload.providerId) {
    await updateWebhook(EXTENSION_POINT, payload.providerId, {
      displayName: payload.displayName,
      url: payload.url,
      authToken: payload.authToken,
      extraConfig: payload.extraConfig,
    })
  } else {
    await addWebhook(EXTENSION_POINT, payload.displayName, payload.url, payload.authToken, payload.extraConfig)
  }
}

async function onDelete(providerId: string) {
  if (!confirm(t('extensions.webhook.confirmDelete'))) return
  await removeWebhook(EXTENSION_POINT, providerId)
}
</script>

<template>
  <div v-if="organization?.id" class="container mx-auto max-w-3xl py-6 space-y-6">
    <div>
      <Button variant="ghost" size="sm" as-child class="mb-2">
        <NuxtLink to="/settings/extensions">
          <IconArrowLeft class="size-4" /> {{ t('extensions.backToList') }}
        </NuxtLink>
      </Button>
      <h1 class="text-2xl font-semibold">{{ t('extensions.dealSource.title') }}</h1>
      <p class="text-sm text-muted-foreground mt-1">{{ t('extensions.dealSource.description') }}</p>
    </div>

    <!-- Built-in providers -->
    <Card>
      <CardHeader>
        <CardTitle>{{ t('extensions.builtinProviders') }}</CardTitle>
        <CardDescription>{{ t('extensions.builtinDescription') }}</CardDescription>
      </CardHeader>
      <CardContent class="space-y-3">
        <div v-for="row in builtinRows" :key="row.meta.id" class="flex items-center justify-between border rounded-md px-3 py-2">
          <div>
            <div class="font-medium">{{ row.meta.label }}</div>
            <div class="text-xs text-muted-foreground">{{ row.meta.description }}</div>
          </div>
          <Switch
            :checked="row.enabled"
            @update:checked="(v: boolean) => setEnabled(EXTENSION_POINT, row.meta.id, v)"
          />
        </div>
      </CardContent>
    </Card>

    <!-- Webhook providers -->
    <Card>
      <CardHeader class="flex flex-row items-start justify-between space-y-0">
        <div>
          <CardTitle>{{ t('extensions.webhookProviders') }}</CardTitle>
          <CardDescription>{{ t('extensions.webhookDescription') }}</CardDescription>
        </div>
        <Button size="sm" @click="openAddDialog">
          <IconPlus class="size-4" /> {{ t('extensions.webhook.add') }}
        </Button>
      </CardHeader>
      <CardContent class="space-y-3">
        <div v-if="webhookRows.length === 0" class="text-sm text-muted-foreground italic">
          {{ t('extensions.webhook.empty') }}
        </div>
        <div v-for="row in webhookRows" :key="row.provider_id" class="border rounded-md px-3 py-2 space-y-2">
          <div class="flex items-center justify-between gap-2">
            <div class="min-w-0">
              <div class="font-medium truncate">{{ row.display_name ?? row.provider_id }}</div>
              <div class="text-xs text-muted-foreground truncate">{{ (row.config as { url?: string }).url }}</div>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <Switch
                :checked="row.enabled"
                @update:checked="(v: boolean) => setEnabled(EXTENSION_POINT, row.provider_id, v)"
              />
              <Button size="sm" variant="ghost" @click="openEditDialog(row.provider_id)"><IconPencil class="size-4" /></Button>
              <Button size="sm" variant="ghost" @click="onDelete(row.provider_id)"><IconTrash class="size-4 text-destructive" /></Button>
            </div>
          </div>
          <WebhookTestButton
            :extension-point="EXTENSION_POINT"
            :url="(row.config as { url?: string }).url ?? ''"
            :auth-token="(row.config as { authToken?: string }).authToken ?? ''"
          />
        </div>
      </CardContent>
    </Card>

    <AddWebhookDialog v-model:open="dialogOpen" :existing="editingRow" @submit="onSubmit" />
  </div>
</template>
