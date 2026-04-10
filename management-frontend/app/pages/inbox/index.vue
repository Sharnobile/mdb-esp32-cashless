<script setup lang="ts">
// Operator inbox — unified view of customer submissions from the public
// storefront (/m/[machine_id]). Merges two underlying tables:
//   • machine_feedback   (type: 'problem' | 'feedback')  — NEW in 20260410140000
//   • product_wishes                                     — pre-existing
// Both are company-scoped via RLS (my_company_id()), so the Supabase client
// only ever returns the current organisation's rows.
//
// Items can be marked reviewed/dismissed (admin only) or deleted (admin only).

definePageMeta({ middleware: 'auth' })

import { timeAgo, formatDateTime } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'

const { t, locale } = useI18n()
const supabase = useSupabaseClient()
const { role } = useOrganization()

// ─── Types ─────────────────────────────────────────────────────────────────
type FeedbackType = 'problem' | 'feedback' | 'wish'
type Status = 'new' | 'reviewed' | 'dismissed'
type SourceTable = 'machine_feedback' | 'product_wishes'

interface InboxItem {
  id: string
  source: SourceTable
  type: FeedbackType
  message: string
  email: string | null
  status: Status
  created_at: string
  machine_id: string
  machine_name: string | null
}

// ─── State ─────────────────────────────────────────────────────────────────
const items = ref<InboxItem[]>([])
const loading = ref(true)
const typeFilter = ref<'all' | FeedbackType>('all')
const statusFilter = ref<'open' | 'all'>('open')
const updatingId = ref<string | null>(null)

// ─── Load ───────────────────────────────────────────────────────────────────
async function load() {
  loading.value = true
  try {
    // Two parallel queries — RLS handles company scoping. Join with
    // vendingMachine for the display name so the operator sees WHICH machine
    // the customer was standing in front of.
    const [fbRes, wishRes] = await Promise.all([
      supabase
        .from('machine_feedback')
        .select('id, type, message, email, status, created_at, machine_id, vendingMachine(name)')
        .order('created_at', { ascending: false })
        .limit(200),
      supabase
        .from('product_wishes')
        .select('id, wish_text, email, status, created_at, machine_id, vendingMachine(name)')
        .order('created_at', { ascending: false })
        .limit(200),
    ])

    const fb: InboxItem[] = (fbRes.data as unknown as Array<{
      id: string
      type: 'problem' | 'feedback'
      message: string
      email: string | null
      status: Status
      created_at: string
      machine_id: string
      vendingMachine: { name: string | null } | null
    }> | null ?? []).map((r) => ({
      id: r.id,
      source: 'machine_feedback',
      type: r.type,
      message: r.message,
      email: r.email,
      status: r.status,
      created_at: r.created_at,
      machine_id: r.machine_id,
      machine_name: r.vendingMachine?.name ?? null,
    }))

    const wishes: InboxItem[] = (wishRes.data as unknown as Array<{
      id: string
      wish_text: string
      email: string | null
      status: Status
      created_at: string
      machine_id: string
      vendingMachine: { name: string | null } | null
    }> | null ?? []).map((r) => ({
      id: r.id,
      source: 'product_wishes',
      type: 'wish',
      message: r.wish_text,
      email: r.email,
      status: r.status,
      created_at: r.created_at,
      machine_id: r.machine_id,
      machine_name: r.vendingMachine?.name ?? null,
    }))

    items.value = [...fb, ...wishes].sort(
      (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
    )
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  load()
})

// ─── Derived ───────────────────────────────────────────────────────────────
const filtered = computed(() => {
  return items.value.filter((i) => {
    if (typeFilter.value !== 'all' && i.type !== typeFilter.value) return false
    if (statusFilter.value === 'open' && i.status !== 'new') return false
    return true
  })
})

const openCount = computed(() => items.value.filter((i) => i.status === 'new').length)
const openByType = computed(() => ({
  problem:  items.value.filter((i) => i.type === 'problem'  && i.status === 'new').length,
  feedback: items.value.filter((i) => i.type === 'feedback' && i.status === 'new').length,
  wish:     items.value.filter((i) => i.type === 'wish'     && i.status === 'new').length,
}))

// ─── Status mutations (admin only) ─────────────────────────────────────────
async function setStatus(item: InboxItem, status: Status) {
  if (role.value !== 'admin' || updatingId.value) return
  updatingId.value = item.id
  try {
    const { error } = await supabase
      .from(item.source)
      .update({ status })
      .eq('id', item.id)
    if (error) throw error
    // Optimistic local update — no full reload needed
    const local = items.value.find((x) => x.id === item.id && x.source === item.source)
    if (local) local.status = status
  } catch (err) {
    console.error('Failed to update status', err)
  } finally {
    updatingId.value = null
  }
}

async function deleteItem(item: InboxItem) {
  if (role.value !== 'admin' || updatingId.value) return
  if (!confirm(t('inbox.confirmDelete'))) return
  updatingId.value = item.id
  try {
    const { error } = await supabase
      .from(item.source)
      .delete()
      .eq('id', item.id)
    if (error) throw error
    items.value = items.value.filter((x) => !(x.id === item.id && x.source === item.source))
  } catch (err) {
    console.error('Failed to delete', err)
  } finally {
    updatingId.value = null
  }
}

// ─── Display helpers ───────────────────────────────────────────────────────
function typeLabel(type: FeedbackType): string {
  if (type === 'problem')  return t('inbox.typeProblem')
  if (type === 'feedback') return t('inbox.typeFeedback')
  return t('inbox.typeWish')
}

function typeBadgeClasses(type: FeedbackType): string {
  if (type === 'problem')
    return 'bg-red-500/15 text-red-600 dark:text-red-400 border-red-500/20'
  if (type === 'feedback')
    return 'bg-blue-500/15 text-blue-600 dark:text-blue-400 border-blue-500/20'
  return 'bg-amber-500/15 text-amber-600 dark:text-amber-400 border-amber-500/20'
}

function statusLabel(status: Status): string {
  return t(`inbox.status_${status}`)
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <!-- Header -->
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">{{ t('inbox.title') }}</h1>
        <p class="text-sm text-muted-foreground">{{ t('inbox.subtitle') }}</p>
      </div>
      <div v-if="openCount > 0" class="text-xs text-muted-foreground">
        {{ t('inbox.openCount', { n: openCount }) }}
      </div>
    </div>

    <!-- Type filter pills -->
    <div class="flex flex-wrap gap-2">
      <button
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors"
        :class="typeFilter === 'all'
          ? 'border-primary bg-primary text-primary-foreground'
          : 'border-input bg-background hover:bg-muted'"
        @click="typeFilter = 'all'"
      >
        {{ t('inbox.filterAll') }}
        <span class="rounded-full bg-background/20 px-1.5 text-xs tabular-nums">{{ items.length }}</span>
      </button>
      <button
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors"
        :class="typeFilter === 'problem'
          ? 'border-red-500 bg-red-500/10 text-red-700 dark:text-red-300'
          : 'border-input bg-background hover:bg-muted'"
        @click="typeFilter = 'problem'"
      >
        {{ t('inbox.typeProblem') }}
        <span v-if="openByType.problem > 0" class="rounded-full bg-red-500 px-1.5 text-xs tabular-nums text-white">{{ openByType.problem }}</span>
      </button>
      <button
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors"
        :class="typeFilter === 'feedback'
          ? 'border-blue-500 bg-blue-500/10 text-blue-700 dark:text-blue-300'
          : 'border-input bg-background hover:bg-muted'"
        @click="typeFilter = 'feedback'"
      >
        {{ t('inbox.typeFeedback') }}
        <span v-if="openByType.feedback > 0" class="rounded-full bg-blue-500 px-1.5 text-xs tabular-nums text-white">{{ openByType.feedback }}</span>
      </button>
      <button
        class="inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors"
        :class="typeFilter === 'wish'
          ? 'border-amber-500 bg-amber-500/10 text-amber-700 dark:text-amber-300'
          : 'border-input bg-background hover:bg-muted'"
        @click="typeFilter = 'wish'"
      >
        {{ t('inbox.typeWish') }}
        <span v-if="openByType.wish > 0" class="rounded-full bg-amber-500 px-1.5 text-xs tabular-nums text-white">{{ openByType.wish }}</span>
      </button>

      <div class="ml-auto flex items-center gap-2">
        <select
          v-model="statusFilter"
          class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
        >
          <option value="open">{{ t('inbox.showOpen') }}</option>
          <option value="all">{{ t('inbox.showAll') }}</option>
        </select>
      </div>
    </div>

    <!-- Loading skeleton -->
    <div v-if="loading && items.length === 0" class="space-y-2">
      <div
        v-for="i in 6"
        :key="i"
        class="h-24 animate-pulse rounded-lg bg-muted"
      />
    </div>

    <!-- Empty state -->
    <div
      v-else-if="filtered.length === 0"
      class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed py-16 text-center text-muted-foreground"
    >
      <svg class="size-10" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.25">
        <path stroke-linecap="round" stroke-linejoin="round" d="M21.75 6.75v10.5a2.25 2.25 0 01-2.25 2.25h-15a2.25 2.25 0 01-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0019.5 4.5h-15a2.25 2.25 0 00-2.25 2.25m19.5 0v.243a2.25 2.25 0 01-1.07 1.916l-7.5 4.615a2.25 2.25 0 01-2.36 0L3.32 8.91a2.25 2.25 0 01-1.07-1.916V6.75" />
      </svg>
      <p class="font-medium">{{ t('inbox.empty') }}</p>
      <p class="text-sm">{{ t('inbox.emptyHint') }}</p>
    </div>

    <!-- Items list -->
    <ul v-else class="flex flex-col gap-3">
      <li
        v-for="item in filtered"
        :key="`${item.source}-${item.id}`"
        class="rounded-lg border bg-card p-4 shadow-sm transition-opacity"
        :class="{ 'opacity-60': item.status !== 'new' }"
      >
        <!-- Top row: type + machine + status + timestamp -->
        <div class="mb-2 flex flex-wrap items-center gap-2">
          <span
            class="inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide"
            :class="typeBadgeClasses(item.type)"
          >
            {{ typeLabel(item.type) }}
          </span>
          <NuxtLink
            :to="`/machines/${item.machine_id}`"
            class="text-sm font-medium text-card-foreground hover:underline"
          >
            {{ item.machine_name || t('inbox.unknownMachine') }}
          </NuxtLink>
          <Badge v-if="item.status !== 'new'" variant="outline" class="capitalize">
            {{ statusLabel(item.status) }}
          </Badge>
          <span
            class="ml-auto shrink-0 text-xs tabular-nums text-muted-foreground"
            :title="formatDateTime(item.created_at, locale)"
          >
            {{ timeAgo(item.created_at, t) }}
          </span>
        </div>

        <!-- Message -->
        <p class="whitespace-pre-wrap text-sm text-card-foreground">{{ item.message }}</p>

        <!-- Email + actions -->
        <div class="mt-3 flex flex-wrap items-center gap-3 border-t pt-3">
          <a
            v-if="item.email"
            :href="`mailto:${item.email}?subject=${encodeURIComponent('Re: ' + typeLabel(item.type))}`"
            class="inline-flex items-center gap-1.5 text-xs text-primary hover:underline"
          >
            <svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M21.75 6.75v10.5a2.25 2.25 0 01-2.25 2.25h-15a2.25 2.25 0 01-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0019.5 4.5h-15a2.25 2.25 0 00-2.25 2.25m19.5 0v.243a2.25 2.25 0 01-1.07 1.916l-7.5 4.615a2.25 2.25 0 01-2.36 0L3.32 8.91a2.25 2.25 0 01-1.07-1.916V6.75" />
            </svg>
            {{ item.email }}
          </a>
          <span v-else class="text-xs text-muted-foreground">{{ t('inbox.noReplyAddress') }}</span>

          <div v-if="role === 'admin'" class="ml-auto flex gap-1.5">
            <button
              v-if="item.status === 'new'"
              :disabled="updatingId === item.id"
              class="inline-flex h-7 items-center gap-1 rounded-md border border-input px-2 text-xs font-medium hover:bg-muted disabled:opacity-50"
              @click="setStatus(item, 'reviewed')"
            >
              {{ t('inbox.markReviewed') }}
            </button>
            <button
              v-if="item.status === 'new'"
              :disabled="updatingId === item.id"
              class="inline-flex h-7 items-center gap-1 rounded-md border border-input px-2 text-xs font-medium hover:bg-muted disabled:opacity-50"
              @click="setStatus(item, 'dismissed')"
            >
              {{ t('inbox.markDismissed') }}
            </button>
            <button
              v-if="item.status !== 'new'"
              :disabled="updatingId === item.id"
              class="inline-flex h-7 items-center gap-1 rounded-md border border-input px-2 text-xs font-medium hover:bg-muted disabled:opacity-50"
              @click="setStatus(item, 'new')"
            >
              {{ t('inbox.reopen') }}
            </button>
            <button
              :disabled="updatingId === item.id"
              class="inline-flex h-7 items-center gap-1 rounded-md border border-destructive/30 px-2 text-xs font-medium text-destructive hover:bg-destructive/10 disabled:opacity-50"
              @click="deleteItem(item)"
            >
              {{ t('common.delete') }}
            </button>
          </div>
        </div>
      </li>
    </ul>
  </div>
</template>
