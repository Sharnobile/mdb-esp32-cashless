<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { timeAgo, formatDate } from '@/lib/utils'
import { useClipboard } from '@vueuse/core'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { role } = useOrganization()

const isAdmin = computed(() => role.value === 'admin')

import { fuzzyFilter } from '@/lib/fuzzySearch'

const keySearch = ref('')
const { toggleSort: toggleKeySort, sortIcon: keySortIcon, sortKey: keySortKey, sortDir: keySortDir } = useTableSort<'name' | 'created' | 'lastUsed' | 'status'>('created', 'desc')

interface ApiKey {
  id: string
  name: string
  key_prefix: string
  created_at: string
  last_used_at: string | null
  revoked_at: string | null
}

const keys = ref<ApiKey[]>([])
const loading = ref(true)

async function fetchKeys() {
  loading.value = true
  const { data, error } = await supabase
    .from('api_keys')
    .select('id, name, key_prefix, created_at, last_used_at, revoked_at')
    .order('created_at', { ascending: false })
  if (!error) {
    keys.value = (data ?? []) as ApiKey[]
  }
  loading.value = false
}

const sortedKeys = computed(() => {
  const filtered = fuzzyFilter(keys.value, keySearch.value, [
    k => k.name,
    k => k.key_prefix,
  ])
  const dir = keySortDir.value === 'asc' ? 1 : -1
  return [...filtered].sort((a, b) => {
    if (keySortKey.value === 'name') return dir * a.name.localeCompare(b.name)
    if (keySortKey.value === 'created') return dir * a.created_at.localeCompare(b.created_at)
    if (keySortKey.value === 'lastUsed') {
      const aD = a.last_used_at ?? ''
      const bD = b.last_used_at ?? ''
      if (!aD && !bD) return 0
      if (!aD) return dir
      if (!bD) return -dir
      return dir * aD.localeCompare(bD)
    }
    // status: active (no revoked_at) first or last
    const aRevoked = a.revoked_at ? 1 : 0
    const bRevoked = b.revoked_at ? 1 : 0
    return dir * (aRevoked - bRevoked)
  })
})

onMounted(fetchKeys)

// Create key modal
const createdKey = ref('')
const { copy, copied } = useClipboard({ copiedDuring: 2000 })

// MCP server endpoint = same base as the API, with the /mcp Kong route.
const config = useRuntimeConfig()
const mcpUrl = computed(() => `${(config.public.supabase?.url as string) || 'https://your-supabase-url'}/mcp`)
const { copy: copyMcp, copied: copiedMcp } = useClipboard({ copiedDuring: 2000 })

const {
  open: showCreateModal,
  form: createForm,
  loading: createLoading,
  error: createError,
  openModal: openCreateModal,
  closeModal: closeCreateModal,
  submit,
} = useModalForm({ name: '' })

async function submitCreate() {
  const name = createForm.value.name.trim()
  if (!name) {
    createError.value = t('common.required', { field: t('common.name') })
    return
  }
  await submit(async () => {
    const { data, error } = await supabase.functions.invoke('create-api-key', {
      body: { name },
    })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    createdKey.value = data.key
    await fetchKeys()
  }, { closeOnSuccess: false })
}

function handleOpenCreateModal() {
  createdKey.value = ''
  openCreateModal()
}

async function revokeKey(id: string) {
  await supabase
    .from('api_keys')
    .update({ revoked_at: new Date().toISOString() })
    .eq('id', id)
  await fetchKeys()
}


</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold">{{ t('apiKeys.title') }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('apiKeys.description') }}</p>
      </div>
      <button
        v-if="isAdmin"
        class="shrink-0 inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
        @click="handleOpenCreateModal"
      >
        {{ t('apiKeys.createApiKey') }}
      </button>
    </div>

    <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>

    <template v-else>
      <div v-if="keys.length === 0" class="text-sm text-muted-foreground">{{ t('apiKeys.noKeysYet') }}</div>
      <div v-else class="flex flex-col gap-4">
      <SearchInput v-model="keySearch" :placeholder="t('common.search') + '...'" class="max-w-xs" />
      <div v-if="sortedKeys.length === 0" class="text-sm text-muted-foreground">{{ t('common.noResults') }}</div>
      <div v-else class="overflow-x-auto rounded-md border">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/50 text-left">
              <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleKeySort('name')">
                <SortHeader :icon="keySortIcon('name')">{{ t('apiKeys.nameCol') }}</SortHeader>
              </th>
              <th class="px-4 py-3 font-medium">{{ t('apiKeys.keyCol') }}</th>
              <th class="hidden sm:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleKeySort('created')">
                <SortHeader :icon="keySortIcon('created')">{{ t('apiKeys.createdCol') }}</SortHeader>
              </th>
              <th class="hidden sm:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleKeySort('lastUsed')">
                <SortHeader :icon="keySortIcon('lastUsed')">{{ t('apiKeys.lastUsedCol') }}</SortHeader>
              </th>
              <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleKeySort('status')">
                <SortHeader :icon="keySortIcon('status')">{{ t('apiKeys.statusCol') }}</SortHeader>
              </th>
              <th v-if="isAdmin" class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="key in sortedKeys"
              :key="key.id"
              class="border-b last:border-0 transition-colors hover:bg-muted/30"
              :class="key.revoked_at ? 'opacity-50' : ''"
            >
              <td class="px-4 py-3 font-medium">{{ key.name }}</td>
              <td class="px-4 py-3">
                <code class="rounded bg-muted px-1.5 py-0.5 text-xs">{{ key.key_prefix }}…</code>
              </td>
              <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">{{ formatDate(key.created_at) }}</td>
              <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">{{ timeAgo(key.last_used_at, t) }}</td>
              <td class="px-4 py-3">
                <span
                  class="rounded-full px-2 py-0.5 text-xs font-medium"
                  :class="key.revoked_at
                    ? 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400'
                    : 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'"
                >
                  {{ key.revoked_at ? t('apiKeys.revoked') : t('apiKeys.active') }}
                </span>
              </td>
              <td v-if="isAdmin" class="px-4 py-3">
                <button
                  v-if="!key.revoked_at"
                  class="text-xs text-destructive hover:underline"
                  @click="revokeKey(key.id)"
                >
                  {{ t('common.revoke') }}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      </div>

      <!-- Usage instructions -->
      <div class="rounded-xl border bg-card p-6">
        <h2 class="mb-2 text-base font-medium">{{ t('apiKeys.usage') }}</h2>
        <p class="mb-3 text-sm text-muted-foreground">
          {{ t('apiKeys.usageInstruction', { header: 'X-API-Key' }) }}
        </p>
        <div class="rounded-md bg-muted p-4">
          <pre class="overflow-x-auto text-xs"><code>curl -X POST {{ useRuntimeConfig().public.supabase?.url ?? 'https://your-supabase-url' }}/functions/v1/send-credit \
  -H "X-API-Key: vmf_your_api_key_here" \
  -H "Content-Type: application/json" \
  -d '{"device_id": "your-device-uuid", "amount": 1.50}'</code></pre>
        </div>
      </div>

      <!-- MCP server -->
      <div class="rounded-xl border bg-card p-6">
        <h2 class="mb-2 text-base font-medium">{{ t('apiKeys.mcpTitle') }}</h2>
        <p class="mb-3 text-sm text-muted-foreground">
          {{ t('apiKeys.mcpDescription') }}
        </p>
        <div class="mb-3 space-y-1">
          <label class="text-xs font-medium text-muted-foreground">{{ t('apiKeys.mcpUrlLabel') }}</label>
          <div class="flex items-stretch gap-2">
            <div class="flex-1 overflow-hidden rounded-md border border-input bg-muted/50 px-3 py-2">
              <p class="truncate font-mono text-xs">{{ mcpUrl }}</p>
            </div>
            <button
              class="inline-flex shrink-0 items-center justify-center rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
              @click="copyMcp(mcpUrl)"
            >
              {{ copiedMcp ? t('common.copied') : t('common.copy') }}
            </button>
          </div>
        </div>
        <p class="mb-3 text-sm text-muted-foreground">
          {{ t('apiKeys.mcpAuth', { header: 'X-API-Key' }) }}
        </p>
        <div class="rounded-md bg-muted p-4">
          <pre class="overflow-x-auto text-xs"><code># OpenClaw
openclaw mcp add vmflow --url {{ mcpUrl }} --transport streamable-http --header "X-API-Key: vmf_your_api_key_here"

# Claude Code
claude mcp add --transport http vmflow {{ mcpUrl }} --header "X-API-Key: vmf_your_api_key_here"</code></pre>
        </div>
      </div>
    </template>
  </div>

  <!-- Create API key modal -->
  <AppModal
    :open="showCreateModal"
    :title="createdKey ? t('apiKeys.apiKeyCreated') : t('apiKeys.createApiKey')"
    @update:open="(v) => { if (!v) { closeCreateModal(); createdKey = '' } }"
  >
    <!-- Step 1: Name form -->
    <template v-if="!createdKey">
      <form class="space-y-4" @submit.prevent="submitCreate">
        <div class="space-y-1">
          <label class="text-sm font-medium" for="key-name">{{ t('common.name') }}</label>
          <input
            id="key-name"
            v-model="createForm.name"
            type="text"
            required
            :placeholder="t('apiKeys.namePlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <FormError :message="createError" />
        <div class="flex gap-2">
          <button
            type="button"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
            @click="closeCreateModal(); createdKey = ''"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            type="submit"
            :disabled="createLoading"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
          >
            <span v-if="createLoading">{{ t('common.creating') }}</span>
            <span v-else>{{ t('common.create') }}</span>
          </button>
        </div>
      </form>
    </template>

    <!-- Step 2: Show key -->
    <template v-else>
      <p class="mb-4 text-sm text-destructive font-medium">
        {{ t('apiKeys.copyWarning') }}
      </p>

      <div class="mb-4 flex items-stretch gap-2">
        <div class="flex-1 overflow-hidden rounded-md border border-input bg-muted/50 px-3 py-2">
          <p class="truncate font-mono text-xs text-muted-foreground">{{ createdKey }}</p>
        </div>
        <button
          class="inline-flex shrink-0 items-center justify-center rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
          @click="copy(createdKey)"
        >
          {{ copied ? t('common.copied') : t('common.copy') }}
        </button>
      </div>

      <button
        class="inline-flex h-9 w-full items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
        @click="closeCreateModal(); createdKey = ''"
      >
        {{ t('common.done') }}
      </button>
    </template>
  </AppModal>
</template>
