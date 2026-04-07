<script setup lang="ts">
definePageMeta({ middleware: 'auth', ssr: false })

import {
  IconCash,
  IconArrowDown,
  IconArrowsExchange,
  IconShieldCheck,
  IconPlus,
  IconDevices,
  IconDownload,
  IconTrash,
} from '@tabler/icons-vue'

import { Badge } from '@/components/ui/badge'
import {
  Card,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

import { formatCurrency, formatDateTime, formatDate } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const { t } = useI18n()
const { organization } = useOrganization()

const errorMessage = ref<string | null>(null)

const {
  cashBooks,
  selectedCashBook,
  entries,
  theoreticalCash,
  loading,
  entriesLoading,
  allMachines,
  fetchCashBooks,
  createCashBook,
  deleteCashBook,
  fetchEntries,
  createEntry,
  fetchTheoreticalCash,
  fetchAllMachines,
  assignMachine,
  unassignMachine,
  verifyIntegrity,
  getMemberName,
  currentBalance,
  totalWithdrawals,
  totalCorrections,
} = useCashBook()

// ── State ────────────────────────────────────────────────────────────────────

const dateFilter = ref<'30' | '90' | 'year' | 'all'>('30')
const integrityResult = ref<{ verified: number; total: number; valid: boolean } | null>(null)

// Modals
const showCreateModal = ref(false)
const createForm = ref({ name: '', initial_balance: 0 })
const creating = ref(false)

const showAssignModal = ref(false)
const assignLoading = ref(false)

// Delete (multi-step confirmation)
const showDeleteModal = ref(false)
const deleteStep = ref<1 | 2>(1)
const deleteConfirmName = ref('')
const deleting = ref(false)

function openDeleteModal() {
  deleteStep.value = 1
  deleteConfirmName.value = ''
  showDeleteModal.value = true
}

async function confirmDelete() {
  if (!selectedCashBook.value) return
  deleting.value = true
  try {
    await deleteCashBook(selectedCashBook.value.id)
    showDeleteModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    deleting.value = false
  }
}

// ── Date filter computation ──────────────────────────────────────────────────

const dateRange = computed(() => {
  const now = new Date()
  switch (dateFilter.value) {
    case '30': {
      const from = new Date(now)
      from.setDate(from.getDate() - 30)
      return { from: from.toISOString().split('T')[0] }
    }
    case '90': {
      const from = new Date(now)
      from.setDate(from.getDate() - 90)
      return { from: from.toISOString().split('T')[0] }
    }
    case 'year': {
      return { from: `${now.getFullYear()}-01-01` }
    }
    case 'all':
    default:
      return {}
  }
})

// ── Load data ────────────────────────────────────────────────────────────────

async function loadCashBookData() {
  if (!selectedCashBook.value) return
  const id = selectedCashBook.value.id

  await Promise.all([
    fetchEntries(id, dateRange.value),
    fetchTheoreticalCash(id),
  ])

  // Run integrity check on ALL entries (not filtered)
  const { data: allEntries } = await (useSupabaseClient() as any)
    .from('cash_book_entries')
    .select('*')
    .eq('cash_book_id', id)
    .order('entry_number', { ascending: true })

  if (allEntries) {
    integrityResult.value = await verifyIntegrity(allEntries as CashBookEntry[])
  }
}

onMounted(async () => {
  if (!import.meta.server && organization.value?.id) {
    await fetchCashBooks()
    if (selectedCashBook.value) {
      await loadCashBookData()
    }
  }
})

// Watch for cash book or date filter changes
watch([() => selectedCashBook.value?.id, dateFilter], async () => {
  if (selectedCashBook.value) {
    await loadCashBookData()
  }
})

usePullToRefresh(async () => {
  await fetchCashBooks()
  if (selectedCashBook.value) await loadCashBookData()
})

// ── Cash book selection ──────────────────────────────────────────────────────

function selectCashBook(id: string) {
  selectedCashBook.value = cashBooks.value.find(cb => cb.id === id) ?? null
}

// ── Create cash book ─────────────────────────────────────────────────────────

async function submitCreateCashBook() {
  if (!createForm.value.name.trim()) return
  creating.value = true
  try {
    await createCashBook(createForm.value.name.trim(), createForm.value.initial_balance)
    showCreateModal.value = false
    createForm.value = { name: '', initial_balance: 0 }
    if (selectedCashBook.value) {
      await loadCashBookData()
    }
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    creating.value = false
  }
}

// ── Machine assignment ───────────────────────────────────────────────────────

async function openAssignModal() {
  assignLoading.value = true
  showAssignModal.value = true
  await fetchAllMachines()
  assignLoading.value = false
}

async function toggleMachineAssignment(machineId: string, currentCashBookId: string | null) {
  if (!selectedCashBook.value) return
  try {
    if (currentCashBookId === selectedCashBook.value.id) {
      await unassignMachine(machineId)
    } else {
      await assignMachine(machineId, selectedCashBook.value.id)
    }
    await fetchTheoreticalCash(selectedCashBook.value.id)
  } catch (err: any) {
    errorMessage.value = err.message
  }
}

function getCashBookName(cashBookId: string | null): string | null {
  if (!cashBookId) return null
  const cb = cashBooks.value.find(c => c.id === cashBookId)
  return cb?.name ?? null
}

// ── Entry dialogs ────────────────────────────────────────────────────────────

// Withdrawal
const showWithdrawalModal = ref(false)
const withdrawalForm = ref({ counted_amount: 0, description: 'Geldentnahme - Bankeinzahlung', machine_id: '' as string | null })
const withdrawalLoading = ref(false)
const withdrawalDifference = computed(() => {
  if (!theoreticalCash.value) return 0
  // Difference = what was counted minus what was expected in the machines (cash sales since last collection)
  return withdrawalForm.value.counted_amount - theoreticalCash.value.cash_sales_since
})
async function openWithdrawalModal() {
  if (selectedCashBook.value) {
    await fetchTheoreticalCash(selectedCashBook.value.id)
  }
  withdrawalForm.value = { counted_amount: 0, description: 'Geldentnahme - Bankeinzahlung', machine_id: null }
  showWithdrawalModal.value = true
}

async function submitWithdrawal() {
  if (!selectedCashBook.value) return
  withdrawalLoading.value = true
  try {
    const counted = withdrawalForm.value.counted_amount
    const expected = theoreticalCash.value?.cash_sales_since ?? 0
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'withdrawal',
      amount: counted,
      description: withdrawalForm.value.description,
      machine_id: withdrawalForm.value.machine_id || null,
      counted_amount: counted,
      expected_amount: expected,
    })
    showWithdrawalModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    withdrawalLoading.value = false
  }
}

// Correction
const showCorrectionModal = ref(false)
const correctionForm = ref({ amount: 0, description: '' })
const correctionLoading = ref(false)

async function submitCorrection() {
  if (!selectedCashBook.value || !correctionForm.value.description.trim()) return
  correctionLoading.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'correction',
      amount: correctionForm.value.amount,
      description: correctionForm.value.description,
    })
    showCorrectionModal.value = false
    correctionForm.value = { amount: 0, description: '' }
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    correctionLoading.value = false
  }
}

// Payout
const showPayoutModal = ref(false)
const payoutForm = ref({ amount: 0, description: 'Auszahlung auf Bankkonto' })
const payoutLoading = ref(false)

async function submitPayout() {
  if (!selectedCashBook.value || payoutForm.value.amount <= 0) return
  payoutLoading.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'payout',
      amount: -Math.abs(payoutForm.value.amount),
      description: payoutForm.value.description,
    })
    showPayoutModal.value = false
    payoutForm.value = { amount: 0, description: 'Auszahlung auf Bankkonto' }
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    payoutLoading.value = false
  }
}

// Reversal (Storno)
const showReversalConfirm = ref(false)
const reversalTarget = ref<CashBookEntry | null>(null)
const reversalLoading = ref(false)

function openReversalConfirm(entry: CashBookEntry) {
  reversalTarget.value = entry
  showReversalConfirm.value = true
}

async function submitReversal() {
  if (!selectedCashBook.value || !reversalTarget.value) return
  reversalLoading.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'reversal',
      amount: 0, // trigger auto-negates
      description: `${t('cashBook.reversalOf')} #${reversalTarget.value.entry_number}`,
      corrects_entry_id: reversalTarget.value.id,
    })
    showReversalConfirm.value = false
    reversalTarget.value = null
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    reversalLoading.value = false
  }
}

// Assigned machines for withdrawal machine selector
const assignedMachines = computed(() => {
  return allMachines.value.filter(m => m.cash_book_id === selectedCashBook.value?.id)
})

// ── Entry type helpers ───────────────────────────────────────────────────────

function typeBadgeClass(type: string): string {
  switch (type) {
    case 'initial': return 'bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300 border-gray-200 dark:border-gray-700'
    case 'withdrawal': return 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400 border-red-200 dark:border-red-800'
    case 'correction': return 'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400 border-yellow-200 dark:border-yellow-800'
    case 'payout': return 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400 border-blue-200 dark:border-blue-800'
    case 'reversal': return 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400 border-orange-200 dark:border-orange-800'
    default: return ''
  }
}

function typeLabel(type: string): string {
  const map: Record<string, string> = {
    initial: t('cashBook.typeInitial'),
    withdrawal: t('cashBook.typeWithdrawal'),
    correction: t('cashBook.typeCorrection'),
    payout: t('cashBook.typePayout'),
    reversal: t('cashBook.typeReversal'),
  }
  return map[type] ?? type
}

function amountClass(amount: number): string {
  return amount >= 0
    ? 'text-green-600 dark:text-green-400 font-semibold'
    : 'text-red-600 dark:text-red-400 font-semibold'
}

function formatAmount(amount: number): string {
  const prefix = amount >= 0 ? '+' : ''
  return `${prefix}${formatCurrency(amount)}`
}

const hasCashSalesSinceLastEntry = computed(() => {
  return theoreticalCash.value && theoreticalCash.value.cash_sales_since > 0
})

// ── PDF Export ───────────────────────────────────────────────────────────────

async function exportPdf() {
  if (!selectedCashBook.value) return

  // Fetch ALL entries (not filtered)
  const { data: allEntries } = await (useSupabaseClient() as any)
    .from('cash_book_entries')
    .select('*')
    .eq('cash_book_id', selectedCashBook.value.id)
    .order('entry_number', { ascending: true })

  if (!allEntries || allEntries.length === 0) return

  // Dynamic import — client-only (jspdf crashes on SSR)
  const { jsPDF } = await import('jspdf')
  const autoTable = (await import('jspdf-autotable')).default
  const doc = new jsPDF()
  const cb = selectedCashBook.value
  const orgName = organization.value?.name || ''

  // Header
  doc.setFontSize(18)
  doc.text(t('cashBook.title'), 14, 20)
  doc.setFontSize(12)
  doc.text(cb.name, 14, 28)
  if (orgName) doc.text(orgName, 14, 34)

  // Summary
  const lastEntry = allEntries[allEntries.length - 1]
  const withdrawals = allEntries.filter((e: any) => e.type === 'withdrawal' && !e.is_reversed)
  const corrections = allEntries.filter((e: any) => e.type === 'correction' && !e.is_reversed)
  const totalW = withdrawals.reduce((s: number, e: any) => s + Math.abs(e.amount), 0)
  const totalC = corrections.reduce((s: number, e: any) => s + e.amount, 0)

  doc.setFontSize(10)
  let y = orgName ? 44 : 38
  doc.text(`${t('cashBook.currentBalance')}: ${formatCurrency(lastEntry.balance_after)}`, 14, y)
  doc.text(`${t('cashBook.totalWithdrawals')}: ${formatCurrency(totalW)} (${withdrawals.length})`, 14, y + 5)
  doc.text(`${t('cashBook.totalCorrections')}: ${formatCurrency(totalC)} (${corrections.length})`, 14, y + 10)
  y += 18

  // Entry table
  autoTable(doc, {
    startY: y,
    head: [[
      'Nr',
      t('cashBook.date'),
      t('cashBook.type'),
      t('cashBook.amount'),
      t('cashBook.balanceAfter'),
      t('cashBook.description'),
    ]],
    body: allEntries.map((e: any) => [
      e.entry_number,
      formatDateTime(e.created_at),
      typeLabel(e.type) + (e.is_reversed ? ` (${t('cashBook.reversed')})` : ''),
      formatAmount(e.amount),
      formatCurrency(e.balance_after),
      e.description || '—',
    ]),
    styles: { fontSize: 8 },
    headStyles: { fillColor: [41, 128, 185] },
  })

  // GoBD footer
  const finalY = (doc as any).lastAutoTable?.finalY ?? y + 20
  doc.setFontSize(9)
  doc.setTextColor(100)
  doc.text(t('cashBook.gobdCompliance'), 14, finalY + 10)
  doc.text(t('cashBook.gobdDescription'), 14, finalY + 15)
  doc.text(t('cashBook.activatedAt', { date: formatDateTime(cb.activated_at) }), 14, finalY + 20)
  doc.text(t('cashBook.totalEntries', { count: allEntries.length }), 14, finalY + 25)
  doc.text(`Hash: ${lastEntry.hash.slice(0, 32)}...`, 14, finalY + 30)

  // Download
  const dateStr = new Date().toISOString().split('T')[0]
  doc.save(`Kassenbuch_${cb.name}_${dateStr}.pdf`)
}
</script>

<template>
  <div class="flex flex-col gap-6 px-4 py-6 lg:px-6">
    <!-- Header -->
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div>
        <h1 class="text-2xl font-bold">{{ t('cashBook.title') }}</h1>
      </div>

      <div class="flex items-center gap-3">
        <!-- Cash book selector -->
        <select
          v-if="cashBooks.length > 0"
          :value="selectedCashBook?.id ?? ''"
          class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:w-64"
          @change="selectCashBook(($event.target as HTMLSelectElement).value)"
        >
          <option value="" disabled>{{ t('cashBook.selectCashBook') }}</option>
          <option v-for="cb in cashBooks" :key="cb.id" :value="cb.id">
            {{ cb.name }}
          </option>
        </select>

        <!-- PDF export -->
        <button
          v-if="selectedCashBook && entries.length > 0"
          class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          @click="exportPdf"
        >
          <IconDownload class="size-4" />
          <span class="hidden sm:inline">{{ t('cashBook.exportPdf') }}</span>
        </button>

        <!-- Create button -->
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          @click="showCreateModal = true"
        >
          <IconPlus class="size-4" />
          <span class="hidden sm:inline">{{ t('cashBook.newCashBook') }}</span>
        </button>
      </div>
    </div>

    <!-- Empty state -->
    <div v-if="cashBooks.length === 0 && !loading" class="flex flex-col items-center justify-center gap-4 rounded-xl border bg-card p-12 text-center">
      <IconCash class="size-12 text-muted-foreground" />
      <div>
        <h3 class="text-lg font-semibold">{{ t('cashBook.emptyState') }}</h3>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('cashBook.emptyStateDescription') }}</p>
      </div>
      <button
        class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
        @click="showCreateModal = true"
      >
        <IconPlus class="size-4" />
        {{ t('cashBook.createCashBook') }}
      </button>
    </div>

    <!-- Main content (when a cash book is selected) -->
    <template v-if="selectedCashBook">
      <!-- KPI Cards -->
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <!-- Current Balance -->
        <Card>
          <CardHeader>
            <CardDescription>{{ t('cashBook.currentBalance') }}</CardDescription>
            <CardTitle class="text-xl font-semibold tabular-nums">
              {{ formatCurrency(currentBalance) }}
            </CardTitle>
          </CardHeader>
          <CardFooter class="text-xs text-muted-foreground">
            {{ t('cashBook.initialBalanceLabel', { amount: formatCurrency(selectedCashBook.initial_balance) }) }}
          </CardFooter>
        </Card>

        <!-- Total Withdrawals (= cash collected from machines, positive) -->
        <Card>
          <CardHeader>
            <CardDescription>{{ t('cashBook.totalWithdrawals') }}</CardDescription>
            <CardTitle class="text-xl font-semibold tabular-nums text-green-600 dark:text-green-400">
              +{{ formatCurrency(totalWithdrawals.amount) }}
            </CardTitle>
          </CardHeader>
          <CardFooter class="text-xs text-muted-foreground">
            {{ t('cashBook.withdrawalCount', { count: totalWithdrawals.count }) }}
          </CardFooter>
        </Card>

        <!-- Total Corrections -->
        <Card>
          <CardHeader>
            <CardDescription>{{ t('cashBook.totalCorrections') }}</CardDescription>
            <CardTitle class="text-xl font-semibold tabular-nums" :class="totalCorrections.amount >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'">
              {{ totalCorrections.amount >= 0 ? '+' : '' }}{{ formatCurrency(totalCorrections.amount) }}
            </CardTitle>
          </CardHeader>
          <CardFooter class="text-xs text-muted-foreground">
            {{ t('cashBook.correctionCount', { count: totalCorrections.count }) }}
          </CardFooter>
        </Card>

        <!-- Integrity Check -->
        <Card>
          <CardHeader>
            <CardDescription>{{ t('cashBook.integrityCheck') }}</CardDescription>
            <CardTitle class="text-xl font-semibold tabular-nums" :class="integrityResult?.valid ? 'text-green-600 dark:text-green-400' : 'text-yellow-600 dark:text-yellow-400'">
              <template v-if="integrityResult">{{ integrityResult.verified }}/{{ integrityResult.total }}</template>
              <template v-else>--/--</template>
            </CardTitle>
          </CardHeader>
          <CardFooter class="text-xs text-muted-foreground">
            {{ t('cashBook.entriesVerified') }}
          </CardFooter>
        </Card>
      </div>

      <!-- Theoretical cash info banner -->
      <div
        v-if="hasCashSalesSinceLastEntry"
        class="rounded-lg border border-blue-200 bg-blue-50 p-4 dark:border-blue-800 dark:bg-blue-900/20"
      >
        <div class="flex items-center gap-2 font-medium text-blue-700 dark:text-blue-400">
          <IconCash class="size-5" />
          {{ t('cashBook.theoreticalBalance') }}: {{ formatCurrency(theoreticalCash!.theoretical_balance) }}
        </div>
        <p class="mt-1 text-sm text-blue-600 dark:text-blue-300">
          {{ t('cashBook.theoreticalBreakdown') }}:
        </p>
        <ul class="mt-1 space-y-0.5 text-sm text-blue-600 dark:text-blue-300">
          <li v-for="m in theoreticalCash!.machines" :key="m.machine_id">
            {{ m.machine_name || 'Automat' }}: +{{ formatCurrency(m.cash_sales) }}
          </li>
        </ul>
      </div>

      <!-- Error message -->
      <div v-if="errorMessage" class="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400">
        {{ errorMessage }}
        <button class="ml-2 underline" @click="errorMessage = null">x</button>
      </div>

      <!-- Action buttons -->
      <div class="flex flex-wrap gap-3">
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 dark:bg-green-700 dark:hover:bg-green-600"
          @click="openWithdrawalModal"
        >
          <IconArrowDown class="size-4" />
          {{ t('cashBook.recordWithdrawal') }}
        </button>
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          @click="showCorrectionModal = true; correctionForm = { amount: 0, description: '' }"
        >
          <IconArrowsExchange class="size-4" />
          {{ t('cashBook.recordCorrection') }}
        </button>
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          @click="showPayoutModal = true; payoutForm = { amount: 0, description: 'Auszahlung auf Bankkonto' }"
        >
          {{ t('cashBook.recordPayout') }}
        </button>
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent hover:text-accent-foreground"
          @click="openAssignModal"
        >
          <IconDevices class="size-4" />
          {{ t('cashBook.assignMachines') }}
        </button>
        <div class="flex-1" />
        <button
          class="inline-flex h-9 items-center gap-2 rounded-md border border-red-200 px-4 text-sm font-medium text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-900/20"
          @click="openDeleteModal"
        >
          <IconTrash class="size-4" />
          {{ t('cashBook.deleteCashBook') }}
        </button>
      </div>

      <!-- Entries section -->
      <div class="rounded-xl border bg-card">
        <div class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
          <div class="flex items-center gap-3">
            <h2 class="text-lg font-semibold">{{ t('cashBook.entries') }}</h2>
            <Badge variant="outline" class="text-green-600 dark:text-green-400">
              <IconShieldCheck class="size-3" />
              {{ t('cashBook.gobdCompliant') }}
            </Badge>
          </div>

          <select
            v-model="dateFilter"
            class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:w-48"
          >
            <option value="30">{{ t('cashBook.last30Days') }}</option>
            <option value="90">{{ t('cashBook.last90Days') }}</option>
            <option value="year">{{ t('cashBook.thisYear') }}</option>
            <option value="all">{{ t('cashBook.allTime') }}</option>
          </select>
        </div>

        <!-- Table -->
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-t text-left text-muted-foreground">
                <th class="px-4 py-2 font-medium">{{ t('cashBook.date') }}</th>
                <th class="px-4 py-2 font-medium">{{ t('cashBook.type') }}</th>
                <th class="px-4 py-2 font-medium text-right">{{ t('cashBook.amount') }}</th>
                <th class="px-4 py-2 font-medium text-right">{{ t('cashBook.balanceAfter') }}</th>
                <th class="px-4 py-2 font-medium">{{ t('cashBook.description') }}</th>
                <th class="px-4 py-2 font-medium">{{ t('cashBook.performedBy') }}</th>
                <th class="px-4 py-2 font-medium w-20"></th>
              </tr>
            </thead>
            <tbody>
              <template v-if="entriesLoading">
                <tr>
                  <td colspan="7" class="px-4 py-8 text-center text-muted-foreground">
                    {{ t('common.loading') }}
                  </td>
                </tr>
              </template>
              <template v-else-if="entries.length === 0">
                <tr>
                  <td colspan="7" class="px-4 py-8 text-center text-muted-foreground">
                    {{ t('cashBook.entries') }}: 0
                  </td>
                </tr>
              </template>
              <template v-else>
                <template v-for="entry in entries" :key="entry.id">
                  <!-- Main entry row -->
                  <tr
                    class="border-t"
                    :class="entry.is_reversed ? 'opacity-50 line-through' : ''"
                  >
                    <td class="px-4 py-2.5 whitespace-nowrap">
                      {{ formatDateTime(entry.created_at) }}
                    </td>
                    <td class="px-4 py-2.5">
                      <span
                        class="inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium"
                        :class="typeBadgeClass(entry.type)"
                      >
                        {{ typeLabel(entry.type) }}
                      </span>
                      <span v-if="entry.is_reversed" class="ml-1 text-xs text-muted-foreground">
                        ({{ t('cashBook.reversed') }})
                      </span>
                    </td>
                    <td class="px-4 py-2.5 text-right whitespace-nowrap" :class="amountClass(entry.amount)">
                      {{ formatAmount(entry.amount) }}
                    </td>
                    <td class="px-4 py-2.5 text-right whitespace-nowrap tabular-nums">
                      {{ formatCurrency(entry.balance_after) }}
                    </td>
                    <td class="px-4 py-2.5 max-w-xs truncate">
                      {{ entry.description || '—' }}
                    </td>
                    <td class="px-4 py-2.5 whitespace-nowrap">
                      {{ entry.user_display || getMemberName(entry.created_by) }}
                    </td>
                    <td class="px-4 py-2.5 text-right">
                      <button
                        v-if="!entry.is_reversed && entry.type !== 'reversal' && entry.type !== 'initial'"
                        class="text-xs text-muted-foreground hover:text-foreground"
                        @click="openReversalConfirm(entry)"
                      >
                        {{ t('cashBook.reverseEntry') }}
                      </button>
                    </td>
                  </tr>

                  <!-- Difference row (if counted differs from expected) -->
                  <tr
                    v-if="entry.counted_amount != null && entry.expected_amount != null && Math.abs(entry.counted_amount - entry.expected_amount) > 0.001"
                    class="bg-amber-50 dark:bg-amber-900/20"
                  >
                    <td colspan="7" class="px-4 py-1.5 text-sm text-amber-700 dark:text-amber-400">
                      <span class="inline-flex items-center gap-1">
                        &#9888;
                        {{ t('cashBook.difference', {
                          diff: formatCurrency(Math.abs(entry.counted_amount - entry.expected_amount)),
                          counted: formatCurrency(entry.counted_amount)
                        }) }}
                      </span>
                    </td>
                  </tr>
                </template>
              </template>
            </tbody>
          </table>
        </div>
      </div>

      <!-- GoBD compliance footer -->
      <div class="rounded-xl border bg-card p-4">
        <div class="flex items-start gap-3">
          <IconShieldCheck class="mt-0.5 size-5 text-green-600 dark:text-green-400 shrink-0" />
          <div>
            <h3 class="font-semibold">{{ t('cashBook.gobdCompliance') }}</h3>
            <p class="mt-1 text-sm text-muted-foreground">
              {{ t('cashBook.gobdDescription') }}
            </p>
            <div class="mt-2 space-y-0.5 text-sm text-muted-foreground">
              <div>{{ t('cashBook.activatedAt', { date: formatDateTime(selectedCashBook.activated_at) }) }}</div>
              <div>{{ t('cashBook.totalEntries', { count: integrityResult?.total ?? entries.length }) }}</div>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- Loading state -->
    <div v-if="loading" class="flex items-center justify-center py-12">
      <span class="text-muted-foreground">{{ t('common.loading') }}</span>
    </div>

    <!-- Create Cash Book Modal -->
    <AppModal
      v-model:open="showCreateModal"
      :title="t('cashBook.createCashBook')"
      size="sm"
    >
      <form class="space-y-4" @submit.prevent="submitCreateCashBook">
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.name') }}</label>
          <input
            v-model="createForm.name"
            type="text"
            required
            :placeholder="t('cashBook.name')"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.initialBalance') }} (EUR)</label>
          <input
            v-model.number="createForm.initial_balance"
            type="number"
            step="0.01"
            min="0"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent"
            @click="showCreateModal = false"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            type="submit"
            :disabled="creating"
            class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          >
            {{ creating ? t('common.loading') : t('cashBook.createCashBook') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Machine Assignment Modal -->
    <AppModal
      v-model:open="showAssignModal"
      :title="t('cashBook.machineAssignment')"
      size="sm"
    >
      <div v-if="assignLoading" class="py-8 text-center text-muted-foreground">
        {{ t('common.loading') }}
      </div>
      <div v-else class="space-y-2 max-h-80 overflow-y-auto">
        <div
          v-for="machine in allMachines"
          :key="machine.id"
          class="flex items-center gap-3 rounded-md px-3 py-2 hover:bg-muted/50"
        >
          <input
            type="checkbox"
            :checked="machine.cash_book_id === selectedCashBook?.id"
            :disabled="machine.cash_book_id != null && machine.cash_book_id !== selectedCashBook?.id"
            class="size-4 rounded border-input"
            @change="toggleMachineAssignment(machine.id, machine.cash_book_id)"
          />
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium truncate">{{ machine.name || machine.id.slice(0, 8) }}</div>
            <div
              v-if="machine.cash_book_id && machine.cash_book_id !== selectedCashBook?.id"
              class="text-xs text-muted-foreground"
            >
              {{ t('cashBook.assignedTo', { name: getCashBookName(machine.cash_book_id) }) }}
            </div>
          </div>
        </div>
        <div v-if="allMachines.length === 0" class="py-4 text-center text-sm text-muted-foreground">
          {{ t('cashBook.noMachinesAssigned') }}
        </div>
      </div>
    </AppModal>

    <!-- Withdrawal Modal -->
    <AppModal
      v-model:open="showWithdrawalModal"
      :title="t('cashBook.recordWithdrawal')"
      size="sm"
    >
      <form class="space-y-4" @submit.prevent="submitWithdrawal">
        <!-- Expected cash in machines -->
        <div class="rounded-lg border bg-muted/50 p-3">
          <div class="text-sm text-muted-foreground">{{ t('cashBook.expectedInMachines') }}</div>
          <div class="text-lg font-bold tabular-nums">
            {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
          </div>
          <div v-if="theoreticalCash?.machines?.length" class="mt-2 space-y-0.5">
            <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="text-xs text-muted-foreground">
              {{ m.machine_name || 'Automat' }}: +{{ formatCurrency(m.cash_sales) }}
            </div>
          </div>
        </div>

        <!-- Counted amount -->
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.countedAmount') }} (EUR)</label>
          <input
            v-model.number="withdrawalForm.counted_amount"
            type="number"
            step="0.01"
            min="0"
            required
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <!-- Difference display -->
        <div
          v-if="withdrawalForm.counted_amount > 0 && theoreticalCash"
          class="rounded-lg p-3 text-sm"
          :class="Math.abs(withdrawalDifference) > 0.001 ? 'border border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800 dark:bg-amber-900/20 dark:text-amber-400' : 'border border-green-200 bg-green-50 text-green-700 dark:border-green-800 dark:bg-green-900/20 dark:text-green-400'"
        >
          {{ t('cashBook.differenceLabel') }}: {{ formatCurrency(withdrawalDifference) }}
        </div>

        <!-- Machine selector -->
        <div v-if="assignedMachines.length > 0">
          <label class="text-sm font-medium">{{ t('cashBook.fromMachine') }}</label>
          <select
            v-model="withdrawalForm.machine_id"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option :value="null">—</option>
            <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
              {{ m.name || m.id.slice(0, 8) }}
            </option>
          </select>
        </div>

        <!-- Description -->
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
          <input
            v-model="withdrawalForm.description"
            type="text"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>

        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showWithdrawalModal = false">
            {{ t('common.cancel') }}
          </button>
          <button type="submit" :disabled="withdrawalLoading || withdrawalForm.counted_amount <= 0" class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
            {{ withdrawalLoading ? t('common.loading') : t('cashBook.recordWithdrawal') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Correction Modal -->
    <AppModal
      v-model:open="showCorrectionModal"
      :title="t('cashBook.recordCorrection')"
      size="sm"
    >
      <form class="space-y-4" @submit.prevent="submitCorrection">
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
          <input
            v-model.number="correctionForm.amount"
            type="number"
            step="0.01"
            required
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.correctionAmountHint') }}</p>
        </div>
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
          <input
            v-model="correctionForm.description"
            type="text"
            required
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showCorrectionModal = false">
            {{ t('common.cancel') }}
          </button>
          <button type="submit" :disabled="correctionLoading || correctionForm.amount === 0" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
            {{ correctionLoading ? t('common.loading') : t('cashBook.recordCorrection') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Payout Modal -->
    <AppModal
      v-model:open="showPayoutModal"
      :title="t('cashBook.recordPayout')"
      size="sm"
    >
      <form class="space-y-4" @submit.prevent="submitPayout">
        <div class="rounded-lg border bg-muted/50 p-3 text-sm">
          {{ t('cashBook.currentBalance') }}: <span class="font-semibold">{{ formatCurrency(currentBalance) }}</span>
        </div>
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
          <input
            v-model.number="payoutForm.amount"
            type="number"
            step="0.01"
            min="0.01"
            required
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div>
          <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
          <input
            v-model="payoutForm.description"
            type="text"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showPayoutModal = false">
            {{ t('common.cancel') }}
          </button>
          <button type="submit" :disabled="payoutLoading || payoutForm.amount <= 0" class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
            {{ payoutLoading ? t('common.loading') : t('cashBook.recordPayout') }}
          </button>
        </div>
      </form>
    </AppModal>

    <!-- Reversal Confirmation Modal -->
    <AppModal
      v-model:open="showReversalConfirm"
      :title="t('cashBook.reversalConfirmTitle')"
      size="sm"
    >
      <div class="space-y-4">
        <p class="text-sm">
          {{ t('cashBook.reversalConfirmMessage', { number: reversalTarget?.entry_number }) }}
        </p>
        <div v-if="reversalTarget" class="rounded-lg border bg-muted/50 p-3 text-sm space-y-1">
          <div>{{ t('cashBook.type') }}: {{ typeLabel(reversalTarget.type) }}</div>
          <div>{{ t('cashBook.amount') }}: {{ formatAmount(reversalTarget.amount) }}</div>
          <div>{{ t('cashBook.description') }}: {{ reversalTarget.description || '—' }}</div>
        </div>
        <div class="flex justify-end gap-2">
          <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showReversalConfirm = false">
            {{ t('common.cancel') }}
          </button>
          <button
            :disabled="reversalLoading"
            class="h-9 rounded-md bg-destructive px-4 text-sm font-medium text-white hover:bg-destructive/90 disabled:opacity-50"
            @click="submitReversal"
          >
            {{ reversalLoading ? t('common.loading') : t('cashBook.reverseEntry') }}
          </button>
        </div>
      </div>
    </AppModal>

    <!-- Delete Cash Book Modal (multi-step) -->
    <AppModal
      v-model:open="showDeleteModal"
      :title="t('cashBook.deleteCashBook')"
      size="sm"
    >
      <div class="space-y-4">
        <!-- Step 1: Warning -->
        <template v-if="deleteStep === 1">
          <div class="rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-800 dark:bg-red-900/20">
            <p class="text-sm font-medium text-red-700 dark:text-red-400">
              {{ t('cashBook.deleteWarning') }}
            </p>
            <ul class="mt-2 list-disc pl-5 text-sm text-red-600 dark:text-red-400 space-y-1">
              <li>{{ t('cashBook.deleteWarningEntries', { count: integrityResult?.total ?? entries.length }) }}</li>
              <li>{{ t('cashBook.deleteWarningMachines') }}</li>
              <li>{{ t('cashBook.deleteWarningIrreversible') }}</li>
            </ul>
          </div>
          <div class="flex justify-end gap-2">
            <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showDeleteModal = false">
              {{ t('common.cancel') }}
            </button>
            <button
              class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700"
              @click="deleteStep = 2"
            >
              {{ t('cashBook.deleteConfirmStep1') }}
            </button>
          </div>
        </template>

        <!-- Step 2: Type name to confirm -->
        <template v-if="deleteStep === 2">
          <p class="text-sm">
            {{ t('cashBook.deleteTypeName', { name: selectedCashBook?.name }) }}
          </p>
          <input
            v-model="deleteConfirmName"
            type="text"
            :placeholder="selectedCashBook?.name"
            class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <div class="flex justify-end gap-2">
            <button class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="showDeleteModal = false">
              {{ t('common.cancel') }}
            </button>
            <button
              :disabled="deleting || deleteConfirmName !== selectedCashBook?.name"
              class="h-9 rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              @click="confirmDelete"
            >
              {{ deleting ? t('common.loading') : t('cashBook.deleteConfirmFinal') }}
            </button>
          </div>
        </template>
      </div>
    </AppModal>
  </div>
</template>
