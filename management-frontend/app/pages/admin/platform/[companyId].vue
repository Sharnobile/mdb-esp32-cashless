<script setup lang="ts">
definePageMeta({ middleware: ['auth', 'platform-admin'] })

import { ref, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { usePlatformAdmin, isDeviceOnline, type CompanyDetail } from '~/composables/usePlatformAdmin'
import { formatCurrency, timeAgo, formatDateTime } from '~/lib/utils'

const { t } = useI18n()
const route = useRoute()
const { fetchCompanyDetail } = usePlatformAdmin()

const detail = ref<CompanyDetail | null>(null)
const loading = ref(true)
const error = ref('')

onMounted(async () => {
  try {
    detail.value = await fetchCompanyDetail(route.params.companyId as string)
  } catch (err: any) {
    error.value = err?.message ?? 'failed to load company detail'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div class="p-4 space-y-6">
    <NuxtLink to="/admin/platform" class="text-sm text-muted-foreground hover:underline">
      ← {{ t('platformAdmin.detail.back') }}
    </NuxtLink>

    <p v-if="error" class="text-destructive">{{ error }}</p>
    <p v-if="loading" class="text-muted-foreground">…</p>

    <template v-if="detail">
      <h1 class="text-2xl font-semibold">{{ detail.company?.name }}</h1>

      <!-- Members -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.members') }}</h2>
        <p v-if="detail.members.length === 0" class="text-muted-foreground text-sm">
          {{ t('platformAdmin.detail.noMembers') }}
        </p>
        <div v-else class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.email') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.role') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.joined') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="m in detail.members" :key="m.user_id" class="border-t">
                <td class="p-2">{{ m.email }}</td>
                <td class="p-2">{{ m.role }}</td>
                <td class="p-2">{{ timeAgo(m.joined_at, t) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Devices -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.devices') }}</h2>
        <p v-if="detail.devices.length === 0" class="text-muted-foreground text-sm">
          {{ t('platformAdmin.detail.noDevices') }}
        </p>
        <div v-else class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.machine') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.status') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.lastSeen') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.firmware') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="d in detail.devices" :key="d.embedded_id" class="border-t">
                <td class="p-2">{{ d.machine_name ?? ('#' + d.subdomain) }}</td>
                <td class="p-2">
                  <span :class="isDeviceOnline(d.status) ? 'text-green-600' : 'text-muted-foreground'">
                    {{ isDeviceOnline(d.status) ? t('platformAdmin.detail.online') : t('platformAdmin.detail.offline') }}
                  </span>
                </td>
                <td class="p-2">{{ d.status_at ? timeAgo(d.status_at, t) : '—' }}</td>
                <td class="p-2">{{ d.firmware_version ?? '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Recent sales -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.recentSales') }}</h2>
        <p v-if="detail.recent_sales.length === 0" class="text-muted-foreground text-sm">
          {{ t('platformAdmin.detail.noSales') }}
        </p>
        <div v-else class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.time') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.machine') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.price') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.channel') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(s, i) in detail.recent_sales" :key="i" class="border-t">
                <td class="p-2">{{ formatDateTime(s.created_at) }}</td>
                <td class="p-2">{{ s.machine_name ?? '—' }}</td>
                <td class="p-2 tabular-nums">{{ formatCurrency(s.item_price) }}</td>
                <td class="p-2">{{ s.channel ?? '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </template>
  </div>
</template>
