<script setup lang="ts">
definePageMeta({ middleware: 'auth', ssr: false })

import { IconShoppingCart, IconDownload, IconAlertTriangle, IconRefresh } from '@tabler/icons-vue'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import { recalculateLine, recalculateGroupSubtotals, type SupplierOrderGroup } from '@/lib/supplierOrderList'

const { t, locale } = useI18n()
const { organization } = useOrganization()
const { warehouses, fetchWarehouses } = useWarehouse()
const { groups, loading, fetchOrderList } = useSupplierOrderList()

const selectedWarehouseId = ref<string | null>(null)
const editableGroups = ref<SupplierOrderGroup[]>([])

watch(groups, (g) => {
  editableGroups.value = g.map(group => ({ ...group, lines: group.lines.map(l => ({ ...l })) }))
}, { immediate: true })

async function loadForWarehouse(id: string) {
  await fetchOrderList(id)
}

onMounted(async () => {
  await fetchWarehouses()
  const first = warehouses.value[0]
  if (first) {
    selectedWarehouseId.value = first.id
    await loadForWarehouse(first.id)
  }
})

watch(selectedWarehouseId, async (id) => {
  if (id) await loadForWarehouse(id)
})

const itemCount = computed(() => editableGroups.value.reduce((sum, g) => sum + g.lines.length, 0))
const totalNet = computed(() => editableGroups.value.reduce((sum, g) => sum + (g.subtotal_net ?? 0), 0))
const totalGross = computed(() => editableGroups.value.reduce((sum, g) => sum + (g.subtotal_gross ?? 0), 0))
const unassignedGroup = computed(() => editableGroups.value.find(g => g.supplier_id === null && g.lines.length > 0) ?? null)
const assignedGroups = computed(() => editableGroups.value.filter(g => g.lines.length > 0 && g !== unassignedGroup.value))

function onQuantityChange(group: SupplierOrderGroup, lineIndex: number, raw: string) {
  const qty = Number(raw)
  group.lines[lineIndex] = recalculateLine(group.lines[lineIndex]!, Number.isFinite(qty) ? qty : 0)
  recalculateGroupSubtotals(group)
}

async function exportSupplierPdf(group: SupplierOrderGroup) {
  const { jsPDF } = await import('jspdf')
  const autoTable = (await import('jspdf-autotable')).default
  const doc = new jsPDF()
  const orgName = organization.value?.name || ''

  doc.setFontSize(18)
  doc.text(t('purchaseList.pdfTitle'), 14, 20)
  doc.setFontSize(12)
  doc.text(group.supplier_name || t('purchaseList.unassigned'), 14, 28)

  let y = 34
  if (orgName) { doc.text(t('purchaseList.pdfOrderer', { org: orgName }), 14, y); y += 6 }
  if (group.contact?.customer_number) { doc.text(t('purchaseList.pdfCustomerNumber', { number: group.contact.customer_number }), 14, y); y += 6 }
  if (group.contact?.email) { doc.text(group.contact.email, 14, y); y += 6 }
  if (group.contact?.phone) { doc.text(group.contact.phone, 14, y); y += 6 }
  y += 4

  autoTable(doc, {
    startY: y,
    head: [[
      t('purchaseList.productCol'),
      t('purchaseList.currentCol'),
      t('purchaseList.minCol'),
      t('purchaseList.qtyCol'),
      t('purchaseList.unitPriceCol'),
      t('purchaseList.lineTotalCol'),
    ]],
    body: group.lines.map(l => [
      l.product_name,
      String(l.current_quantity),
      String(l.min_stock),
      String(l.suggested_quantity),
      l.unit_price_gross != null ? formatCurrency(l.unit_price_gross, locale.value) : '—',
      l.line_total_gross != null ? formatCurrency(l.line_total_gross, locale.value) : '—',
    ]),
    styles: { fontSize: 9 },
    headStyles: { fillColor: [41, 128, 185] },
  })

  const finalY = (doc as any).lastAutoTable?.finalY ?? y + 20
  doc.setFontSize(10)
  doc.text(t('purchaseList.pdfTotal', { amount: formatCurrency(group.subtotal_gross, locale.value) }), 14, finalY + 10)

  const dateStr = new Date().toISOString().split('T')[0]
  const safeName = (group.supplier_name || 'unassigned').replace(/[^a-z0-9]+/gi, '_')
  doc.save(`Bestellung_${safeName}_${dateStr}.pdf`)
}
</script>

<template>
  <div class="flex flex-col gap-4 p-4 md:p-6 overflow-x-hidden">
    <!-- Header -->
    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div class="flex items-center gap-2">
        <IconShoppingCart class="size-6" />
        <h1 class="text-2xl font-bold">{{ t('purchaseList.title') }}</h1>
      </div>
      <div class="flex items-center gap-2">
        <select
          v-if="warehouses.length > 0"
          v-model="selectedWarehouseId"
          class="h-9 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="wh in warehouses" :key="wh.id" :value="wh.id">{{ wh.name }}</option>
        </select>
        <button
          class="inline-flex h-9 items-center gap-1.5 rounded-md border px-3 text-sm font-medium hover:bg-muted"
          :disabled="loading || !selectedWarehouseId"
          @click="selectedWarehouseId && loadForWarehouse(selectedWarehouseId)"
        >
          <IconRefresh class="size-4" :class="loading ? 'animate-spin' : ''" />
          <span class="hidden sm:inline">{{ t('common.refresh') }}</span>
        </button>
      </div>
    </div>

    <p class="text-sm text-muted-foreground">{{ t('purchaseList.description') }}</p>

    <!-- KPI cards -->
    <div class="grid grid-cols-2 gap-3 lg:grid-cols-3">
      <Card>
        <CardHeader class="pb-2">
          <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('purchaseList.itemsToOrder') }}</CardTitle>
        </CardHeader>
        <CardContent>
          <div class="text-2xl font-bold">{{ itemCount }}</div>
        </CardContent>
      </Card>
      <Card>
        <CardHeader class="pb-2">
          <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('purchaseList.totalNet') }}</CardTitle>
        </CardHeader>
        <CardContent>
          <div class="text-2xl font-bold">{{ formatCurrency(totalNet, locale) }}</div>
        </CardContent>
      </Card>
      <Card>
        <CardHeader class="pb-2">
          <CardTitle class="text-sm font-medium text-muted-foreground">{{ t('purchaseList.totalGross') }}</CardTitle>
        </CardHeader>
        <CardContent>
          <div class="text-2xl font-bold">{{ formatCurrency(totalGross, locale) }}</div>
        </CardContent>
      </Card>
    </div>

    <!-- Empty state -->
    <div v-if="!loading && itemCount === 0" class="flex flex-col items-center gap-2 py-16 text-center">
      <IconShoppingCart class="size-8 text-muted-foreground" />
      <h2 class="text-lg font-semibold">{{ t('purchaseList.emptyTitle') }}</h2>
      <p class="text-sm text-muted-foreground">{{ t('purchaseList.emptyDescription') }}</p>
    </div>

    <!-- Supplier groups -->
    <div v-for="group in assignedGroups" :key="group.supplier_id ?? group.supplier_name" class="rounded-lg border">
      <div class="flex flex-col gap-2 border-b p-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h3 class="font-semibold">{{ group.supplier_name }}</h3>
          <div class="text-xs text-muted-foreground space-x-2">
            <span v-if="group.contact?.customer_number">{{ t('purchaseList.customerNumber') }}: {{ group.contact.customer_number }}</span>
            <span v-if="group.contact?.email">{{ group.contact.email }}</span>
            <span v-if="group.contact?.phone">{{ group.contact.phone }}</span>
          </div>
        </div>
        <button
          class="inline-flex h-8 items-center gap-1.5 rounded-md border px-3 text-xs font-medium hover:bg-muted"
          @click="exportSupplierPdf(group)"
        >
          <IconDownload class="size-3.5" />
          {{ t('purchaseList.exportPdf') }}
        </button>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/50 text-left">
              <th class="px-4 py-2 font-medium">{{ t('purchaseList.productCol') }}</th>
              <th class="px-4 py-2 font-medium text-right">{{ t('purchaseList.currentCol') }}</th>
              <th class="px-4 py-2 font-medium text-right">{{ t('purchaseList.minCol') }}</th>
              <th class="px-4 py-2 font-medium text-right">{{ t('purchaseList.qtyCol') }}</th>
              <th class="hidden px-4 py-2 font-medium text-right sm:table-cell">{{ t('purchaseList.unitPriceCol') }}</th>
              <th class="px-4 py-2 font-medium text-right">{{ t('purchaseList.lineTotalCol') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(line, idx) in group.lines" :key="line.product_id" class="border-b last:border-0">
              <td class="px-4 py-2">{{ line.product_name }}</td>
              <td class="px-4 py-2 text-right" :class="line.current_quantity === 0 ? 'text-red-600 dark:text-red-400 font-medium' : ''">{{ line.current_quantity }}</td>
              <td class="px-4 py-2 text-right text-muted-foreground">{{ line.min_stock }}</td>
              <td class="px-4 py-2 text-right">
                <input
                  type="number"
                  min="0"
                  class="h-8 w-20 rounded-md border border-input bg-background px-2 text-right text-sm"
                  :value="line.suggested_quantity"
                  @change="onQuantityChange(group, idx, ($event.target as HTMLInputElement).value)"
                >
              </td>
              <td class="hidden px-4 py-2 text-right sm:table-cell">{{ line.unit_price_gross != null ? formatCurrency(line.unit_price_gross, locale) : '—' }}</td>
              <td class="px-4 py-2 text-right font-medium">{{ line.line_total_gross != null ? formatCurrency(line.line_total_gross, locale) : '—' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="flex justify-end gap-4 border-t p-3 text-sm">
        <span class="text-muted-foreground">{{ t('purchaseList.subtotalNet') }}: {{ formatCurrency(group.subtotal_net, locale) }}</span>
        <span class="font-semibold">{{ t('purchaseList.subtotalGross') }}: {{ formatCurrency(group.subtotal_gross, locale) }}</span>
      </div>
    </div>

    <!-- Unassigned (no purchase price on file) -->
    <div v-if="unassignedGroup" class="rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/20">
      <div class="flex items-center gap-2 p-4 font-medium text-amber-800 dark:text-amber-300">
        <IconAlertTriangle class="size-5" />
        {{ t('purchaseList.unassignedTitle') }}
      </div>
      <p class="px-4 pb-2 text-sm text-amber-800/80 dark:text-amber-300/80">{{ t('purchaseList.unassignedDescription') }}</p>
      <ul class="px-4 pb-4 text-sm">
        <li v-for="line in unassignedGroup.lines" :key="line.product_id" class="flex justify-between border-b border-amber-200/60 py-1.5 last:border-0 dark:border-amber-700/40">
          <span>{{ line.product_name }}</span>
          <span class="text-muted-foreground">{{ line.current_quantity }} / {{ line.min_stock }}</span>
        </li>
      </ul>
      <div class="px-4 pb-4">
        <NuxtLink to="/products" class="text-sm font-medium underline underline-offset-2">{{ t('purchaseList.goToProducts') }}</NuxtLink>
      </div>
    </div>
  </div>
</template>
