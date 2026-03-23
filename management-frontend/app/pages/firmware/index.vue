<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { timeAgo, formatDateTime } from '@/lib/utils'
import { Checkbox } from '@/components/ui/checkbox'
import { Badge } from '@/components/ui/badge'

const { t } = useI18n()
const { role } = useOrganization()
const {
  firmwareVersions, loading, fetchFirmwareVersions,
  uploadFirmware, triggerOta, triggerOtaBatch, deleteFirmwareVersion,
  githubRepo, githubReleases, githubLoading,
  fetchGitHubReleases, importGitHubRelease, isReleaseImported,
} = useFirmware()

import type { OtaDeviceStatus } from '@/composables/useFirmware'
const { machines, fetchMachines } = useMachines()

const isAdmin = computed(() => role.value === 'admin')

const { toggleSort: toggleFwSort, sortIcon: fwSortIcon, sortKey: fwSortKey, sortDir: fwSortDir } = useTableSort<'version' | 'size' | 'uploaded'>('uploaded', 'desc')

const sortedFirmwareVersions = computed(() => {
  const dir = fwSortDir.value === 'asc' ? 1 : -1
  return [...firmwareVersions.value].sort((a, b) => {
    if (fwSortKey.value === 'version') return dir * (a.version_label ?? '').localeCompare(b.version_label ?? '')
    if (fwSortKey.value === 'size') return dir * ((a.file_size ?? 0) - (b.file_size ?? 0))
    return dir * (a.created_at ?? '').localeCompare(b.created_at ?? '')
  })
})

onMounted(async () => {
  await Promise.all([
    fetchFirmwareVersions(),
    fetchMachines(),
    fetchGitHubReleases(),
  ])
})

// ── Upload modal ─────────────────────────────────────────────────────────────
const uploadFile = ref<File | null>(null)

const {
  open: showUploadModal,
  form: uploadForm,
  loading: uploadLoading,
  error: uploadError,
  openModal: openUploadModal,
  closeModal: closeUploadModal,
  submit: submitUploadForm,
} = useModalForm({ versionLabel: '', notes: '' })

function onFileChange(e: Event) {
  const input = e.target as HTMLInputElement
  uploadFile.value = input.files?.[0] ?? null
}

function handleOpenUploadModal() {
  uploadFile.value = null
  openUploadModal()
}

async function submitUpload() {
  if (!uploadFile.value) {
    uploadError.value = t('firmware.selectFile')
    return
  }
  if (!uploadForm.value.versionLabel.trim()) {
    uploadError.value = t('firmware.versionRequired')
    return
  }
  await submitUploadForm(async () => {
    await uploadFirmware(uploadFile.value!, uploadForm.value.versionLabel.trim(), uploadForm.value.notes.trim() || undefined)
  })
}

// ── OTA trigger modal ────────────────────────────────────────────────────────
const showOtaModal = ref(false)
const selectedFirmwareId = ref('')
const otaPhase = ref<'select' | 'progress'>('select')
const selectedDeviceIds = ref(new Set<string>())
const searchQuery = ref('')
const statusFilter = ref<'all' | 'online'>('all')
const deployProgress = ref(new Map<string, { status: OtaDeviceStatus; error?: string }>())
const otaDeploying = ref(false)

// Get devices (embeddeds) from machines
const availableDevices = computed(() => {
  return machines.value
    .filter((m: any) => m.embeddeds?.id)
    .map((m: any) => ({
      id: m.embeddeds.id,
      name: m.name ?? 'Unnamed',
      status: m.embeddeds.status,
      mac: m.embeddeds.mac_address,
      firmware_version: m.embeddeds.firmware_version ?? null,
      firmware_build_date: m.embeddeds.firmware_build_date ?? null,
    }))
})

const filteredDevices = computed(() => {
  let list = availableDevices.value
  if (statusFilter.value === 'online') {
    list = list.filter(d => d.status === 'online')
  }
  if (searchQuery.value.trim()) {
    const q = searchQuery.value.toLowerCase()
    list = list.filter(d =>
      d.name.toLowerCase().includes(q) ||
      (d.mac && d.mac.toLowerCase().includes(q))
    )
  }
  return list
})

const selectedCount = computed(() => selectedDeviceIds.value.size)
const offlineSelectedCount = computed(() => {
  return availableDevices.value.filter(
    d => selectedDeviceIds.value.has(d.id) && d.status !== 'online'
  ).length
})
const allFilteredSelected = computed(() => {
  if (filteredDevices.value.length === 0) return false
  return filteredDevices.value.every(d => selectedDeviceIds.value.has(d.id))
})

const selectedFirmwareLabel = computed(() => {
  return firmwareVersions.value.find(fw => fw.id === selectedFirmwareId.value)?.version_label ?? ''
})

const progressSummary = computed(() => {
  let sent = 0, failed = 0, pending = 0, sending = 0
  for (const entry of deployProgress.value.values()) {
    if (entry.status === 'sent') sent++
    else if (entry.status === 'failed') failed++
    else if (entry.status === 'sending') sending++
    else pending++
  }
  return { sent, failed, pending, sending, total: deployProgress.value.size }
})

function openOtaModal(firmwareId: string) {
  selectedFirmwareId.value = firmwareId
  otaPhase.value = 'select'
  selectedDeviceIds.value = new Set()
  searchQuery.value = ''
  statusFilter.value = 'all'
  deployProgress.value = new Map()
  otaDeploying.value = false
  showOtaModal.value = true
}

function closeOtaModal() {
  showOtaModal.value = false
}

function toggleAll() {
  if (allFilteredSelected.value) {
    for (const d of filteredDevices.value) {
      selectedDeviceIds.value.delete(d.id)
    }
  } else {
    for (const d of filteredDevices.value) {
      selectedDeviceIds.value.add(d.id)
    }
  }
  // Trigger reactivity
  selectedDeviceIds.value = new Set(selectedDeviceIds.value)
}

function toggleDevice(id: string) {
  if (selectedDeviceIds.value.has(id)) {
    selectedDeviceIds.value.delete(id)
  } else {
    selectedDeviceIds.value.add(id)
  }
  selectedDeviceIds.value = new Set(selectedDeviceIds.value)
}

async function startDeploy() {
  otaPhase.value = 'progress'
  otaDeploying.value = true
  const ids = Array.from(selectedDeviceIds.value)

  // Init progress map
  const progress = new Map<string, { status: OtaDeviceStatus; error?: string }>()
  for (const id of ids) {
    progress.set(id, { status: 'pending' })
  }
  deployProgress.value = progress

  await triggerOtaBatch(ids, selectedFirmwareId.value, (deviceId, status, error) => {
    const newMap = new Map(deployProgress.value)
    newMap.set(deviceId, { status, error })
    deployProgress.value = newMap
  })

  otaDeploying.value = false
}

async function retryFailed() {
  const failedIds = Array.from(deployProgress.value.entries())
    .filter(([_, v]) => v.status === 'failed')
    .map(([id]) => id)

  if (failedIds.length === 0) return
  otaDeploying.value = true

  // Reset failed to pending
  const newMap = new Map(deployProgress.value)
  for (const id of failedIds) {
    newMap.set(id, { status: 'pending' })
  }
  deployProgress.value = newMap

  await triggerOtaBatch(failedIds, selectedFirmwareId.value, (deviceId, status, error) => {
    const updated = new Map(deployProgress.value)
    updated.set(deviceId, { status, error })
    deployProgress.value = updated
  })

  otaDeploying.value = false
}

// ── Delete ───────────────────────────────────────────────────────────────────
const deleteLoading = ref<string | null>(null)

async function handleDelete(fw: any) {
  deleteLoading.value = fw.id
  try {
    await deleteFirmwareVersion(fw.id, fw.file_path)
  } catch {
    // silent
  } finally {
    deleteLoading.value = null
  }
}

// ── GitHub import ────────────────────────────────────────────────────────────
const importLoading = ref<string | null>(null)
const importError = ref('')
const importSuccess = ref('')

async function handleImport(tag: string, assetName: string) {
  importLoading.value = tag
  importError.value = ''
  importSuccess.value = ''
  try {
    await importGitHubRelease(tag, assetName)
    importSuccess.value = t('firmware.importedFrom', { asset: assetName, tag })
    // Refresh to pick up the new firmware version
    await fetchGitHubReleases()
  } catch (err: unknown) {
    importError.value = err instanceof Error ? err.message : t('firmware.importFailed')
  } finally {
    importLoading.value = null
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function formatSize(bytes: number | null) {
  if (bytes == null) return '—'
  if (bytes < 1024) return `${bytes} B`
  const kb = bytes / 1024
  if (kb < 1024) return `${kb.toFixed(1)} KB`
  return `${(kb / 1024).toFixed(2)} MB`
}


</script>

<template>
  <div class="flex flex-1 flex-col gap-4 p-4 md:p-6">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <h1 class="text-2xl font-semibold">{{ t('firmware.title') }}</h1>
      <button
        v-if="isAdmin"
        class="shrink-0 inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
        @click="handleOpenUploadModal"
      >
        {{ t('firmware.uploadFirmware') }}
      </button>
    </div>

    <div v-if="loading" class="text-muted-foreground">{{ t('firmware.loadingFirmware') }}</div>

    <div v-else-if="firmwareVersions.length === 0" class="text-muted-foreground">
      {{ t('firmware.noFirmwareYet') }}
    </div>

    <!-- Firmware versions table -->
    <div v-else class="overflow-x-auto rounded-md border">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/50 text-left">
            <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleFwSort('version')">
              <SortHeader :icon="fwSortIcon('version')">{{ t('firmware.versionCol') }}</SortHeader>
            </th>
            <th class="hidden sm:table-cell px-4 py-3 font-medium">{{ t('firmware.sourceCol') }}</th>
            <th class="hidden sm:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleFwSort('size')">
              <SortHeader :icon="fwSortIcon('size')">{{ t('firmware.sizeCol') }}</SortHeader>
            </th>
            <th class="hidden md:table-cell px-4 py-3 font-medium">{{ t('firmware.notesCol') }}</th>
            <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleFwSort('uploaded')">
              <SortHeader :icon="fwSortIcon('uploaded')">{{ t('firmware.uploadedCol') }}</SortHeader>
            </th>
            <th v-if="isAdmin" class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="fw in sortedFirmwareVersions"
            :key="fw.id"
            class="border-b last:border-0 hover:bg-muted/30 transition-colors"
          >
            <td class="px-4 py-3 font-mono font-medium whitespace-nowrap">{{ fw.version_label }}</td>
            <td class="hidden sm:table-cell px-4 py-3">
              <span
                v-if="fw.source_type === 'github'"
                class="inline-flex items-center gap-1 rounded-full bg-purple-100 px-2 py-0.5 text-xs font-medium text-purple-700 dark:bg-purple-900/30 dark:text-purple-300"
              >
                <svg class="h-3 w-3" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" /></svg>
                {{ t('firmware.github') }}
              </span>
              <span
                v-else
                class="inline-flex items-center rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700 dark:bg-blue-900/30 dark:text-blue-300"
              >
                {{ t('firmware.uploadSource') }}
              </span>
            </td>
            <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">{{ formatSize(fw.file_size) }}</td>
            <td class="hidden md:table-cell px-4 py-3 text-muted-foreground truncate max-w-xs">{{ fw.notes ?? '—' }}</td>
            <td class="px-4 py-3 text-muted-foreground">
              <span :title="formatDateTime(fw.created_at)">{{ timeAgo(fw.created_at, t) }}</span>
            </td>
            <td v-if="isAdmin" class="px-4 py-3">
              <div class="flex items-center gap-3">
                <button
                  class="text-xs text-primary hover:underline"
                  @click="openOtaModal(fw.id)"
                >
                  {{ t('common.deploy') }}
                </button>
                <button
                  class="text-xs text-destructive hover:underline"
                  :disabled="deleteLoading === fw.id"
                  @click="handleDelete(fw)"
                >
                  {{ deleteLoading === fw.id ? t('common.deleting') : t('common.delete') }}
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- GitHub Releases section -->
    <template v-if="githubRepo">
      <div class="flex flex-wrap items-center justify-between gap-2 pt-4">
        <div class="min-w-0">
          <h2 class="text-lg font-semibold">{{ t('firmware.githubReleases') }}</h2>
          <p class="text-sm text-muted-foreground">
            {{ t('firmware.importFrom') }}
            <a
              :href="`https://github.com/${githubRepo}/releases`"
              target="_blank"
              rel="noopener"
              class="text-primary hover:underline"
            >{{ githubRepo }}</a>
          </p>
        </div>
        <button
          class="inline-flex h-8 items-center justify-center rounded-md border px-3 text-xs font-medium shadow-sm transition-colors hover:bg-muted"
          :disabled="githubLoading"
          @click="fetchGitHubReleases"
        >
          {{ githubLoading ? t('common.loading') : t('common.refresh') }}
        </button>
      </div>

      <!-- Import status messages -->
      <FormError :message="importError" />
      <p v-if="importSuccess" class="text-sm text-green-600 dark:text-green-400">{{ importSuccess }}</p>

      <div v-if="githubLoading && githubReleases.length === 0" class="text-muted-foreground text-sm">
        {{ t('firmware.loadingReleases') }}
      </div>

      <div v-else-if="githubReleases.length === 0" class="text-muted-foreground text-sm">
        {{ t('firmware.noReleasesFound') }}
      </div>

      <div v-else class="overflow-x-auto rounded-md border">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/50 text-left">
              <th class="px-4 py-3 font-medium">{{ t('firmware.releaseCol') }}</th>
              <th class="hidden sm:table-cell px-4 py-3 font-medium">{{ t('firmware.assetCol') }}</th>
              <th class="hidden md:table-cell px-4 py-3 font-medium">{{ t('firmware.sizeCol') }}</th>
              <th class="px-4 py-3 font-medium">{{ t('firmware.publishedCol') }}</th>
              <th v-if="isAdmin" class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="release in githubReleases" :key="release.tag_name">
              <tr
                v-for="asset in release.assets.filter(a => a.name.endsWith('.bin'))"
                :key="`${release.tag_name}-${asset.name}`"
                class="border-b last:border-0 hover:bg-muted/30 transition-colors"
              >
                <td class="px-4 py-3">
                  <a
                    :href="release.html_url"
                    target="_blank"
                    rel="noopener"
                    class="font-mono font-medium text-primary hover:underline"
                  >{{ release.tag_name }}</a>
                  <p v-if="release.name && release.name !== release.tag_name" class="text-xs text-muted-foreground truncate max-w-[200px]">
                    {{ release.name }}
                  </p>
                </td>
                <td class="hidden sm:table-cell px-4 py-3 font-mono text-xs text-muted-foreground truncate max-w-[200px]">{{ asset.name }}</td>
                <td class="hidden md:table-cell px-4 py-3 text-muted-foreground">{{ formatSize(asset.size) }}</td>
                <td class="px-4 py-3 text-muted-foreground">
                  <span :title="formatDateTime(release.published_at)">{{ timeAgo(release.published_at, t) }}</span>
                </td>
                <td v-if="isAdmin" class="px-4 py-3">
                  <button
                    v-if="isReleaseImported(release.tag_name)"
                    disabled
                    class="inline-flex h-7 items-center rounded-md border px-3 text-xs font-medium text-muted-foreground opacity-60"
                  >
                    {{ t('firmware.imported') }}
                  </button>
                  <button
                    v-else
                    class="inline-flex h-7 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90 disabled:opacity-50"
                    :disabled="importLoading === release.tag_name"
                    @click="handleImport(release.tag_name, asset.name)"
                  >
                    {{ importLoading === release.tag_name ? t('firmware.importing') : t('common.import') }}
                  </button>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
    </template>
  </div>

  <!-- Upload firmware modal -->
  <AppModal
    :open="showUploadModal"
    :title="t('firmware.uploadFirmware')"
    :description="t('firmware.uploadDescription')"
    @update:open="(v) => { if (!v) closeUploadModal() }"
  >
    <form class="space-y-4" @submit.prevent="submitUpload">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="fw-version">{{ t('firmware.versionLabel') }}</label>
        <input
          id="fw-version"
          v-model="uploadForm.versionLabel"
          type="text"
          :placeholder="t('firmware.versionPlaceholder')"
          required
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="fw-file">{{ t('firmware.firmwareBinary') }}</label>
        <input
          id="fw-file"
          type="file"
          accept=".bin,application/octet-stream"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          @change="onFileChange"
        />
        <p class="text-xs text-muted-foreground">{{ t('firmware.maxSize') }}</p>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="fw-notes">{{ t('firmware.notesCol') }}</label>
        <input
          id="fw-notes"
          v-model="uploadForm.notes"
          type="text"
          :placeholder="t('firmware.notesPlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <FormError :message="uploadError" />
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="closeUploadModal"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="uploadLoading"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="uploadLoading">{{ t('firmware.uploading') }}</span>
          <span v-else>{{ t('common.upload') }}</span>
        </button>
      </div>
    </form>
  </AppModal>

  <!-- OTA trigger modal -->
  <AppModal
    :open="showOtaModal"
    :title="t('firmware.deployFirmware')"
    :description="otaPhase === 'select' ? t('firmware.deployDescription_multi') : undefined"
    size="lg"
    @update:open="(v: boolean) => { if (!v) closeOtaModal() }"
  >
    <!-- Phase: Select devices -->
    <template v-if="otaPhase === 'select'">
      <div class="space-y-3">
        <!-- Firmware version label -->
        <p v-if="selectedFirmwareLabel" class="text-sm text-muted-foreground">
          {{ t('firmware.versionCol') }}: <span class="font-mono font-medium text-foreground">{{ selectedFirmwareLabel }}</span>
        </p>

        <!-- Search + filter row -->
        <div class="flex gap-2">
          <input
            v-model="searchQuery"
            type="text"
            :placeholder="t('firmware.searchDevices')"
            class="flex h-9 flex-1 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <select
            v-model="statusFilter"
            class="flex h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option value="all">{{ t('firmware.filterAll') }}</option>
            <option value="online">{{ t('firmware.filterOnline') }}</option>
          </select>
        </div>

        <!-- Select all header -->
        <div
          class="flex items-center gap-3 rounded-md border bg-muted/50 px-3 py-2 cursor-pointer"
          @click="toggleAll"
        >
          <Checkbox
            :checked="allFilteredSelected && filteredDevices.length > 0"
            @update:checked="toggleAll"
          />
          <span class="text-sm font-medium">
            {{ t('firmware.selectAll') }}
            <span class="text-muted-foreground font-normal">({{ filteredDevices.length }})</span>
          </span>
          <span v-if="selectedCount > 0" class="ml-auto text-xs text-muted-foreground">
            {{ t('firmware.devicesSelected', { count: selectedCount }, selectedCount) }}
          </span>
        </div>

        <!-- Device list -->
        <div v-if="filteredDevices.length === 0" class="py-4 text-center text-sm text-muted-foreground">
          {{ t('firmware.noDevicesForDeploy') }}
        </div>
        <div v-else class="max-h-64 overflow-y-auto rounded-md border divide-y">
          <div
            v-for="d in filteredDevices"
            :key="d.id"
            class="flex items-center gap-3 px-3 py-2.5 cursor-pointer transition-colors hover:bg-muted/30"
            :class="{ 'opacity-60': d.status !== 'online' }"
            @click="toggleDevice(d.id)"
          >
            <Checkbox
              :checked="selectedDeviceIds.has(d.id)"
              @update:checked="toggleDevice(d.id)"
            />
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium truncate">{{ d.name }}</span>
                <Badge
                  :variant="d.status === 'online' ? 'default' : 'secondary'"
                  class="shrink-0"
                >
                  <span
                    class="mr-1 inline-block h-1.5 w-1.5 rounded-full"
                    :class="d.status === 'online' ? 'bg-green-400' : 'bg-muted-foreground/50'"
                  />
                  {{ d.status }}
                </Badge>
              </div>
              <div class="flex items-center gap-2 text-xs text-muted-foreground">
                <span class="font-mono">{{ d.mac ?? t('firmware.noMac') }}</span>
                <span v-if="d.firmware_version">v{{ d.firmware_version }}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Offline warning -->
        <div
          v-if="offlineSelectedCount > 0"
          class="flex items-start gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800 dark:border-amber-800/50 dark:bg-amber-950/30 dark:text-amber-200"
        >
          <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="mt-0.5 shrink-0"><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>
          <span>{{ t('firmware.offlineWarning', { count: offlineSelectedCount }, offlineSelectedCount) }}</span>
        </div>

        <!-- Footer -->
        <div class="flex gap-2 pt-1">
          <button
            type="button"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
            @click="closeOtaModal"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            type="button"
            :disabled="selectedCount === 0"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
            @click="startDeploy"
          >
            {{ t('firmware.updateDevices', { count: selectedCount }, selectedCount) }}
          </button>
        </div>
      </div>
    </template>

    <!-- Phase: Progress -->
    <template v-else>
      <div class="space-y-3">
        <!-- Progress bar -->
        <div>
          <div class="flex items-center justify-between text-sm mb-1.5">
            <span class="font-medium">{{ t('firmware.deploying_progress') }}</span>
            <span class="text-muted-foreground">{{ t('firmware.progressSummary', { sent: progressSummary.sent, total: progressSummary.total }) }}</span>
          </div>
          <div class="h-2 w-full rounded-full bg-muted overflow-hidden">
            <div
              class="h-full rounded-full transition-all duration-300"
              :class="progressSummary.failed > 0 ? 'bg-amber-500' : 'bg-primary'"
              :style="{ width: `${((progressSummary.sent + progressSummary.failed) / progressSummary.total) * 100}%` }"
            />
          </div>
        </div>

        <!-- Device progress list -->
        <div class="max-h-72 overflow-y-auto rounded-md border divide-y">
          <div
            v-for="d in availableDevices.filter(dev => deployProgress.has(dev.id))"
            :key="d.id"
            class="flex items-center gap-3 px-3 py-2.5"
          >
            <!-- Status icon -->
            <div class="shrink-0 flex items-center justify-center w-5 h-5">
              <!-- Pending -->
              <span
                v-if="deployProgress.get(d.id)?.status === 'pending'"
                class="inline-block h-2 w-2 rounded-full bg-muted-foreground/30"
              />
              <!-- Sending -->
              <svg
                v-else-if="deployProgress.get(d.id)?.status === 'sending'"
                class="h-4 w-4 animate-spin text-primary"
                xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"
              >
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
              </svg>
              <!-- Sent -->
              <svg
                v-else-if="deployProgress.get(d.id)?.status === 'sent'"
                class="h-4 w-4 text-green-600 dark:text-green-400"
                xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"
              >
                <polyline points="20 6 9 17 4 12" />
              </svg>
              <!-- Failed -->
              <svg
                v-else-if="deployProgress.get(d.id)?.status === 'failed'"
                class="h-4 w-4 text-destructive"
                xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"
              >
                <path d="M18 6 6 18" /><path d="m6 6 12 12" />
              </svg>
            </div>

            <!-- Device info -->
            <div class="flex-1 min-w-0">
              <span class="text-sm font-medium">{{ d.name }}</span>
              <span class="ml-2 text-xs text-muted-foreground font-mono">{{ d.mac ?? '' }}</span>
            </div>

            <!-- Status text -->
            <span
              class="shrink-0 text-xs font-medium"
              :class="{
                'text-muted-foreground': deployProgress.get(d.id)?.status === 'pending',
                'text-primary': deployProgress.get(d.id)?.status === 'sending',
                'text-green-600 dark:text-green-400': deployProgress.get(d.id)?.status === 'sent',
                'text-destructive': deployProgress.get(d.id)?.status === 'failed',
              }"
            >
              <template v-if="deployProgress.get(d.id)?.status === 'pending'">{{ t('firmware.pending') }}</template>
              <template v-else-if="deployProgress.get(d.id)?.status === 'sending'">{{ t('firmware.sending') }}</template>
              <template v-else-if="deployProgress.get(d.id)?.status === 'sent'">{{ t('firmware.sent') }}</template>
              <template v-else-if="deployProgress.get(d.id)?.status === 'failed'">{{ deployProgress.get(d.id)?.error ?? t('firmware.failed') }}</template>
            </span>
          </div>
        </div>

        <!-- Footer -->
        <div class="flex gap-2 pt-1">
          <button
            v-if="progressSummary.failed > 0 && !otaDeploying"
            type="button"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border border-amber-300 bg-amber-50 px-4 text-sm font-medium text-amber-800 shadow-sm transition-colors hover:bg-amber-100 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-200 dark:hover:bg-amber-950/50"
            @click="retryFailed"
          >
            {{ t('firmware.retryFailed') }} ({{ progressSummary.failed }})
          </button>
          <button
            type="button"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
            @click="closeOtaModal"
          >
            {{ t('common.close') }}
          </button>
        </div>
      </div>
    </template>
  </AppModal>
</template>
